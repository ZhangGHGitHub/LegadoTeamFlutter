//! 书源匹配器 — 用于换源功能
//!
//! 根据书名+作者在不同书源中搜索匹配的书籍，提供匹配度评分。

use serde::{Deserialize, Serialize};

/// 书源匹配结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceMatch {
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 书籍详情页 URL
    pub book_url: String,
    /// 书籍名称
    pub book_name: String,
    /// 作者
    pub author: String,
    /// 最新章节
    pub latest_chapter: Option<String>,
    /// 字数信息
    pub word_count: Option<String>,
    /// 匹配度评分（0.0 ~ 100.0）
    pub score: f64,
}

/// 搜索候选结果（来自单个书源的原始搜索结果）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchCandidate {
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 书籍详情页 URL
    pub book_url: String,
    /// 书籍名称
    pub book_name: String,
    /// 作者
    pub author: String,
    /// 最新章节
    pub latest_chapter: Option<String>,
    /// 字数信息
    pub word_count: Option<String>,
}

/// 书源匹配器
pub struct SourceMatcher;

impl SourceMatcher {
    /// 对搜索候选结果进行匹配评分，返回按评分降序排列的匹配结果
    pub fn rank_candidates(
        candidates: Vec<SearchCandidate>,
        target_name: &str,
        target_author: &str,
    ) -> Vec<SourceMatch> {
        let mut matches: Vec<SourceMatch> = candidates
            .into_iter()
            .map(|c| {
                let score = Self::match_score(&c.book_name, &c.author, target_name, target_author);
                SourceMatch {
                    source_url: c.source_url,
                    source_name: c.source_name,
                    book_url: c.book_url,
                    book_name: c.book_name,
                    author: c.author,
                    latest_chapter: c.latest_chapter,
                    word_count: c.word_count,
                    score,
                }
            })
            .collect();

        // 按评分降序排列
        matches.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        matches
    }

    /// 计算匹配度评分（0.0 ~ 100.0）
    ///
    /// - 书名完全匹配 +50 分
    /// - 书名包含匹配 +30 分
    /// - 作者匹配 +30 分
    /// - 字数信息可用 +20 分
    pub fn match_score(
        result_name: &str,
        result_author: &str,
        target_name: &str,
        target_author: &str,
    ) -> f64 {
        let mut score = 0.0;

        // 书名匹配
        let rn = result_name.trim();
        let tn = target_name.trim();
        if !rn.is_empty() && !tn.is_empty() {
            if rn == tn {
                score += 50.0;
            } else if rn.contains(tn) || tn.contains(rn) {
                score += 30.0;
            }
        }

        // 作者匹配
        let ra = result_author.trim();
        let ta = target_author.trim();
        if !ta.is_empty() && !ra.is_empty() {
            if ra == ta {
                score += 30.0;
            } else if ra.contains(ta) || ta.contains(ra) {
                score += 15.0;
            }
        }

        score
    }

    /// 判断匹配结果是否足够好（默认阈值 50 分）
    pub fn is_good_match(m: &SourceMatch) -> bool {
        m.score >= 50.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_exact_match_score() {
        let score = SourceMatcher::match_score("斗破苍穹", "天蚕土豆", "斗破苍穹", "天蚕土豆");
        assert_eq!(score, 80.0); // 50 + 30
    }

    #[test]
    fn test_partial_name_match() {
        let score = SourceMatcher::match_score("斗破苍穹全集", "天蚕土豆", "斗破苍穹", "天蚕土豆");
        assert_eq!(score, 60.0); // 30 + 30
    }

    #[test]
    fn test_no_match() {
        let score = SourceMatcher::match_score("凡人修仙传", "忘语", "斗破苍穹", "天蚕土豆");
        assert_eq!(score, 0.0);
    }

    #[test]
    fn test_empty_author() {
        let score = SourceMatcher::match_score("斗破苍穹", "", "斗破苍穹", "天蚕土豆");
        assert_eq!(score, 50.0); // 书名匹配，作者为空不计分
    }

    #[test]
    fn test_rank_candidates() {
        let candidates = vec![
            SearchCandidate {
                source_url: "s1".into(),
                source_name: "源1".into(),
                book_url: "b1".into(),
                book_name: "斗破苍穹".into(),
                author: "天蚕土豆".into(),
                latest_chapter: None,
                word_count: None,
            },
            SearchCandidate {
                source_url: "s2".into(),
                source_name: "源2".into(),
                book_url: "b2".into(),
                book_name: "凡人修仙传".into(),
                author: "忘语".into(),
                latest_chapter: None,
                word_count: None,
            },
        ];

        let results = SourceMatcher::rank_candidates(candidates, "斗破苍穹", "天蚕土豆");
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].book_name, "斗破苍穹");
        assert!(results[0].score > results[1].score);
    }

    #[test]
    fn test_is_good_match() {
        let good = SourceMatch {
            source_url: "s".into(),
            source_name: "n".into(),
            book_url: "b".into(),
            book_name: "斗破苍穹".into(),
            author: "天蚕土豆".into(),
            latest_chapter: None,
            word_count: None,
            score: 80.0,
        };
        assert!(SourceMatcher::is_good_match(&good));

        let bad = SourceMatch {
            score: 20.0,
            ..good.clone()
        };
        assert!(!SourceMatcher::is_good_match(&bad));
    }
}
