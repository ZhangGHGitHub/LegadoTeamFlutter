//! 多源并行搜索引擎
//!
//! 提供多书源并行搜索 → 结果聚合 → 去重 → 排序的基础框架。
//! 网络请求部分预留接口，后续由 legado-net 实现填充。

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use serde::{Deserialize, Serialize};

use crate::models::BookSource;
use crate::source_matcher::{SearchCandidate, SourceMatcher};

// ─── 搜索结果 ─────────────────────────────────────────────

/// 搜索结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// 书籍名称
    pub book_name: String,
    /// 作者
    pub author: String,
    /// 封面 URL
    pub cover_url: Option<String>,
    /// 简介
    pub intro: Option<String>,
    /// 最新章节
    pub latest_chapter: Option<String>,
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 书籍在该源的详情页 URL
    pub book_url: String,
    /// 相关性评分（0.0 ~ 100.0，由 SourceMatcher 计算）
    pub relevance_score: f64,
}

impl SearchResult {
    /// 从 SearchCandidate 构造 SearchResult（无评分，需后续排序时填充）
    pub fn from_candidate(c: &SearchCandidate) -> Self {
        Self {
            book_name: c.book_name.clone(),
            author: c.author.clone(),
            cover_url: None,
            intro: None,
            latest_chapter: c.latest_chapter.clone(),
            source_url: c.source_url.clone(),
            source_name: c.source_name.clone(),
            book_url: c.book_url.clone(),
            relevance_score: 0.0,
        }
    }
}

// ─── 搜索配置 ─────────────────────────────────────────────

/// 搜索配置
#[derive(Debug, Clone)]
pub struct SearchConfig {
    /// 搜索关键词
    pub query: String,
    /// 单源超时（秒）
    pub timeout_secs: u64,
    /// 每源最大返回数
    pub max_results_per_source: usize,
}

impl Default for SearchConfig {
    fn default() -> Self {
        Self {
            query: String::new(),
            timeout_secs: 10,
            max_results_per_source: 20,
        }
    }
}

// ─── 单源搜索 trait（预留注入点）──────────────────────────

/// 单源搜索 trait
///
/// 网络请求实现由外部提供（legado-net 或测试 mock），
/// `MultiSourceSearcher` 通过此 trait 解耦具体实现。
pub trait SourceSearcher: Send + Sync {
    /// 对单个书源执行搜索，返回候选结果列表
    fn search(
        &self,
        source: &BookSource,
        query: &str,
        max_results: usize,
    ) -> impl std::future::Future<Output = Vec<SearchCandidate>> + Send;
}

/// 空实现：直接返回空列表（用于占位和测试）
#[derive(Debug, Clone)]
pub struct NoopSourceSearcher;

impl SourceSearcher for NoopSourceSearcher {
    async fn search(
        &self,
        _source: &BookSource,
        _query: &str,
        _max_results: usize,
    ) -> Vec<SearchCandidate> {
        Vec::new()
    }
}

// ─── 多源搜索引擎 ─────────────────────────────────────────

/// 多源并行搜索引擎
///
/// 通过泛型 `S: SourceSearcher` 注入具体网络实现，
/// 内部使用 tokio::spawn 并行搜索各书源，支持 AtomicBool 取消标志。
pub struct MultiSourceSearcher<S: SourceSearcher> {
    searcher: Arc<S>,
}

impl<S: SourceSearcher + 'static> MultiSourceSearcher<S> {
    /// 创建新的多源搜索引擎
    pub fn new(searcher: S) -> Self {
        Self {
            searcher: Arc::new(searcher),
        }
    }

    /// 并行搜索多个书源
    ///
    /// 1. 为每个书源 spawn 一个搜索任务
    /// 2. 等待所有任务完成（支持取消和超时）
    /// 3. 聚合结果 → 去重 → 排序
    pub async fn search(
        &self,
        config: SearchConfig,
        sources: Vec<BookSource>,
        cancel: Arc<AtomicBool>,
    ) -> Vec<SearchResult> {
        if sources.is_empty() || config.query.is_empty() {
            return Vec::new();
        }

        let timeout = std::time::Duration::from_secs(config.timeout_secs);
        let max_per_source = config.max_results_per_source;

        // 为每个书源 spawn 搜索任务
        let mut handles = Vec::with_capacity(sources.len());
        for source in sources {
            let searcher = Arc::clone(&self.searcher);
            let query = config.query.clone();
            let cancel_inner = Arc::clone(&cancel);

            let handle = tokio::spawn(async move {
                // 检查取消标志
                if cancel_inner.load(Ordering::SeqCst) {
                    return Vec::new();
                }
                searcher.search(&source, &query, max_per_source).await
            });
            handles.push(handle);
        }

        // 收集所有结果（带超时）
        let mut all_candidates: Vec<SearchCandidate> = Vec::new();
        let search_future = async {
            for handle in handles {
                if cancel.load(Ordering::SeqCst) {
                    break;
                }
                if let Ok(candidates) = handle.await {
                    all_candidates.extend(candidates);
                }
            }
        };

        let _ = tokio::time::timeout(timeout, search_future).await;

        // 去重
        let unique = Self::deduplicate(&all_candidates);

        // 转为 SearchResult 并排序
        let mut results: Vec<SearchResult> = unique
            .into_iter()
            .map(|c| SearchResult::from_candidate(&c))
            .collect();

        Self::rank_results(&mut results, &config.query);
        results
    }

    /// 搜索结果去重（按 书名 + 作者 组合键）
    ///
    /// 保留每个 (书名, 作者) 组合首次出现的结果。
    pub fn deduplicate(candidates: &[SearchCandidate]) -> Vec<SearchCandidate> {
        let mut seen: HashSet<String> = HashSet::new();
        let mut result = Vec::new();
        for c in candidates {
            let key = format!("{}|{}", c.book_name.trim(), c.author.trim());
            if seen.insert(key) {
                result.push(c.clone());
            }
        }
        result
    }

    /// 按相关性排序（使用 SourceMatcher 的评分逻辑）
    ///
    /// 以 query 作为目标书名，作者留空（搜索阶段不知道作者）。
    pub fn rank_results(results: &mut [SearchResult], query: &str) {
        // 利用 SourceMatcher::match_score 为每条结果打分
        for r in results.iter_mut() {
            r.relevance_score = SourceMatcher::match_score(&r.book_name, &r.author, query, "");
        }
        // 按评分降序排列
        results.sort_by(|a, b| {
            b.relevance_score
                .partial_cmp(&a.relevance_score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
    }
}

// ─── 测试 ─────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::source_matcher::SearchCandidate;

    fn make_candidate(name: &str, author: &str, source_url: &str) -> SearchCandidate {
        SearchCandidate {
            variable: None,
            source_url: source_url.to_string(),
            source_name: format!("源_{source_url}"),
            book_url: format!("{source_url}/book/{name}"),
            book_name: name.to_string(),
            author: author.to_string(),
            latest_chapter: None,
            word_count: None,
            chapter_word_count_text: None,
            chapter_word_count: -1,
            respond_time: -1,
            origin_order: 0,
            book_score: 0,
        }
    }

    #[test]
    fn test_deduplicate_removes_duplicates() {
        let candidates = vec![
            make_candidate("斗破苍穹", "天蚕土豆", "s1"),
            make_candidate("斗破苍穹", "天蚕土豆", "s2"), // 重复
            make_candidate("凡人修仙传", "忘语", "s1"),
        ];
        let unique = MultiSourceSearcher::<NoopSourceSearcher>::deduplicate(&candidates);
        assert_eq!(unique.len(), 2);
        assert_eq!(unique[0].source_url, "s1");
        assert_eq!(unique[1].book_name, "凡人修仙传");
    }

    #[test]
    fn test_deduplicate_empty_input() {
        let unique = MultiSourceSearcher::<NoopSourceSearcher>::deduplicate(&[]);
        assert!(unique.is_empty());
    }

    #[test]
    fn test_rank_results_orders_by_relevance() {
        let mut results = vec![
            SearchResult {
                book_name: "凡人修仙传".into(),
                author: "忘语".into(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
                source_url: "s1".into(),
                source_name: "源1".into(),
                book_url: "b1".into(),
                relevance_score: 0.0,
            },
            SearchResult {
                book_name: "斗破苍穹".into(),
                author: "天蚕土豆".into(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
                source_url: "s2".into(),
                source_name: "源2".into(),
                book_url: "b2".into(),
                relevance_score: 0.0,
            },
        ];

        MultiSourceSearcher::<NoopSourceSearcher>::rank_results(&mut results, "斗破苍穹");
        // "斗破苍穹" 完全匹配，应排第一
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert!(results[0].relevance_score >= results[1].relevance_score);
    }

    #[test]
    fn test_rank_results_partial_match() {
        let mut results = vec![
            SearchResult {
                book_name: "斗破苍穹全集".into(),
                author: "".into(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
                source_url: "s1".into(),
                source_name: "源1".into(),
                book_url: "b1".into(),
                relevance_score: 0.0,
            },
            SearchResult {
                book_name: "三体".into(),
                author: "".into(),
                cover_url: None,
                intro: None,
                latest_chapter: None,
                source_url: "s2".into(),
                source_name: "源2".into(),
                book_url: "b2".into(),
                relevance_score: 0.0,
            },
        ];

        MultiSourceSearcher::<NoopSourceSearcher>::rank_results(&mut results, "斗破苍穹");
        // 部分匹配应排在无匹配前面
        assert_eq!(results[0].book_name, "斗破苍穹全集");
        assert!(results[0].relevance_score > 0.0);
        assert_eq!(results[1].relevance_score, 0.0);
    }

    #[tokio::test]
    async fn test_search_with_noop_returns_empty() {
        let searcher = MultiSourceSearcher::new(NoopSourceSearcher);
        let config = SearchConfig {
            query: "斗破苍穹".into(),
            timeout_secs: 5,
            max_results_per_source: 10,
        };
        let sources = vec![BookSource {
            book_source_url: "https://example.com".into(),
            book_source_name: "测试源".into(),
            ..BookSource::default()
        }];
        let cancel = Arc::new(AtomicBool::new(false));
        let results = searcher.search(config, sources, cancel).await;
        // NoopSourceSearcher 返回空，所以结果应为空
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn test_search_empty_query_returns_empty() {
        let searcher = MultiSourceSearcher::new(NoopSourceSearcher);
        let config = SearchConfig {
            query: "".into(),
            timeout_secs: 5,
            max_results_per_source: 10,
        };
        let cancel = Arc::new(AtomicBool::new(false));
        let results = searcher.search(config, vec![], cancel).await;
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn test_search_cancellation() {
        let searcher = MultiSourceSearcher::new(NoopSourceSearcher);
        let config = SearchConfig {
            query: "斗破苍穹".into(),
            timeout_secs: 60,
            max_results_per_source: 10,
        };
        let sources = vec![BookSource {
            book_source_url: "s1".into(),
            book_source_name: "源1".into(),
            ..BookSource::default()
        }];
        let cancel = Arc::new(AtomicBool::new(true)); // 立即取消
        let results = searcher.search(config, sources, cancel).await;
        assert!(results.is_empty());
    }

    /// Mock searcher：返回预设候选结果
    struct MockSearcher {
        candidates: Vec<SearchCandidate>,
    }

    impl SourceSearcher for MockSearcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _max_results: usize,
        ) -> Vec<SearchCandidate> {
            self.candidates.clone()
        }
    }

    #[tokio::test]
    async fn test_search_with_mock_searcher() {
        let mock = MockSearcher {
            candidates: vec![
                make_candidate("斗破苍穹", "天蚕土豆", "s1"),
                make_candidate("凡人修仙传", "忘语", "s2"),
            ],
        };
        let searcher = MultiSourceSearcher::new(mock);
        let config = SearchConfig {
            query: "斗破苍穹".into(),
            timeout_secs: 5,
            max_results_per_source: 10,
        };
        let sources = vec![
            BookSource {
                book_source_url: "s1".into(),
                book_source_name: "源1".into(),
                ..BookSource::default()
            },
            BookSource {
                book_source_url: "s2".into(),
                book_source_name: "源2".into(),
                ..BookSource::default()
            },
        ];
        let cancel = Arc::new(AtomicBool::new(false));
        let results = searcher.search(config, sources, cancel).await;
        // 两个候选 → 去重后两条，"斗破苍穹" 排第一
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert!(results[0].relevance_score >= results[1].relevance_score);
    }

    #[test]
    fn test_search_result_from_candidate() {
        let c = make_candidate("斗破苍穹", "天蚕土豆", "https://example.com");
        let r = SearchResult::from_candidate(&c);
        assert_eq!(r.book_name, "斗破苍穹");
        assert_eq!(r.author, "天蚕土豆");
        assert_eq!(r.source_url, "https://example.com");
        assert_eq!(r.relevance_score, 0.0);
        assert!(r.cover_url.is_none());
        assert!(r.intro.is_none());
    }

    #[test]
    fn test_search_config_default() {
        let cfg = SearchConfig::default();
        assert!(cfg.query.is_empty());
        assert_eq!(cfg.timeout_secs, 10);
        assert_eq!(cfg.max_results_per_source, 20);
    }
}
