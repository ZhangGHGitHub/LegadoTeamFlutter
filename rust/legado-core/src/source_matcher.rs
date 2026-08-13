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
    /// 试读章节字数展示（对齐 SearchBook.chapterWordCountText）
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        rename = "chapter_word_count_text"
    )]
    pub chapter_word_count_text: Option<String>,
    /// 试读章节字数（-1=未知，对齐 SearchBook.chapterWordCount）
    #[serde(default = "default_neg_one")]
    pub chapter_word_count: i32,
    /// 取字耗时毫秒（-1=未知，对齐 SearchBook.respondTime）
    #[serde(default = "default_neg_one")]
    pub respond_time: i32,
    /// 书源排序权重（对齐 SearchBook.originOrder / BookSource.customOrder）
    #[serde(default)]
    pub origin_order: i32,
}

fn default_neg_one() -> i32 {
    -1
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
    /// 试读章节字数展示
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chapter_word_count_text: Option<String>,
    /// 试读章节字数（-1=未知）
    #[serde(default = "default_neg_one")]
    pub chapter_word_count: i32,
    /// 取字耗时毫秒（-1=未知）
    #[serde(default = "default_neg_one")]
    pub respond_time: i32,
    /// 书源 customOrder
    #[serde(default)]
    pub origin_order: i32,
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
        Self::rank_candidates_with_options(candidates, target_name, target_author, false)
    }

    /// 换源搜索排序；`use_word_count_sort=true` 时对齐原版 wordCountComparator
    pub fn rank_candidates_with_options(
        candidates: Vec<SearchCandidate>,
        target_name: &str,
        target_author: &str,
        use_word_count_sort: bool,
    ) -> Vec<SourceMatch> {
        let mut matches: Vec<SourceMatch> = candidates
            .into_iter()
            .map(|c| Self::candidate_to_match(c, target_name, target_author))
            .collect();

        if use_word_count_sort {
            Self::sort_by_word_count(&mut matches);
        } else {
            matches.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.origin_order.cmp(&b.origin_order))
            });
        }
        matches
    }

    fn candidate_to_match(
        c: SearchCandidate,
        target_name: &str,
        target_author: &str,
    ) -> SourceMatch {
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
            chapter_word_count_text: c.chapter_word_count_text,
            chapter_word_count: c.chapter_word_count,
            respond_time: c.respond_time,
            origin_order: c.origin_order,
        }
    }

    /// 对齐 ChangeBookSourceViewModel.wordCountComparator
    fn sort_by_word_count(matches: &mut [SourceMatch]) {
        matches.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| {
                    (b.chapter_word_count > 1000).cmp(&(a.chapter_word_count > 1000))
                })
                .then_with(|| {
                    chapter_num_from_text(b.chapter_word_count_text.as_deref())
                        .cmp(&chapter_num_from_text(a.chapter_word_count_text.as_deref()))
                })
                .then_with(|| b.chapter_word_count.cmp(&a.chapter_word_count))
                .then_with(|| a.origin_order.cmp(&b.origin_order))
        });
    }

    /// Task #25：书名规范化比较 — 对齐原版换源硬过滤的比较口径。
    ///
    /// 原版 `ChangeBookSourceViewModel.search` L268-269 的过滤条件为
    /// `fName == name`（Kotlin String equals），但不同书源返回的书名常带
    /// 首尾空白与整体包裹的装饰括号（如「《斗破苍穹》」「【斗破苍穹】」）。
    /// 为对齐原版「同名才进换源列表」语义且不过度发散：trim 空白后成对剥离
    /// 首尾包裹括号（后缀括号如「灵气复苏(全集)」不剥离），不做任何模糊/
    /// 相似度匹配。
    pub fn normalize_book_name(name: &str) -> String {
        const PAIRS: [(char, char); 7] = [
            ('(', ')'),
            ('（', '）'),
            ('[', ']'),
            ('【', '】'),
            ('〔', '〕'),
            ('《', '》'),
            ('〈', '〉'),
        ];
        let mut s = name.trim().to_string();
        loop {
            let mut changed = false;
            for (open, close) in PAIRS {
                let mut chars = s.chars();
                if let (Some(first), Some(last)) = (chars.next(), chars.next_back()) {
                    if first == open && last == close && s.chars().count() > 2 {
                        let inner: String = s
                            .chars()
                            .skip(1)
                            .take(s.chars().count() - 2)
                            .collect();
                        s = inner;
                        changed = true;
                        break;
                    }
                }
            }
            if !changed {
                break;
            }
        }
        s.trim().to_string()
    }

    /// Task #25：书名同名判定（换源硬过滤口径）：规范化后**精确相等**。
    /// 对齐原版 `fName == name`；书名任一为空视为不匹配。
    pub fn is_same_book_name(result_name: &str, target_name: &str) -> bool {
        let rn = Self::normalize_book_name(result_name);
        let tn = Self::normalize_book_name(target_name);
        !rn.is_empty() && !tn.is_empty() && rn == tn
    }

    /// Task #25：作者名规范化 — 对齐原版 `AppPattern.authorRegex`
    /// （`^\s*作\s*者[:：\s]+|\s+著`）：剥离前缀「作者：/作者:」与后缀「 著」，
    /// 使 DB 中「作者：STDe亦寒」与搜索结果「STDe亦寒」可精确相等计分。
    pub fn normalize_author(author: &str) -> String {
        let mut s = author.trim();
        if let Some(r) = s.strip_prefix('作') {
            let r = r.trim_start();
            if let Some(r2) = r.strip_prefix('者') {
                s = r2.trim_start_matches(|c: char| c == ':' || c == '：' || c.is_whitespace());
            }
        }
        if let Some(r) = s.strip_suffix('著') {
            s = r.trim_end();
        }
        s.to_string()
    }

    /// Task #25：作者校验判定 — 对齐原版 `fAuthor.contains(author)`
    /// （ChangeBookSourceViewModel L269；SQL 口径同为 `author like '%..%'`）。
    /// 目标作者为空（trim 后）= 不校验，恒通过。
    pub fn author_matches(result_author: &str, target_author: &str) -> bool {
        let ta = Self::normalize_author(target_author);
        if ta.is_empty() {
            return true;
        }
        Self::normalize_author(result_author).contains(&ta)
            || result_author.contains(&ta)
    }

    /// Task #25：换源候选硬过滤（对齐原版 ChangeBookSourceViewModel L266-270）。
    ///
    /// 原版换源搜索对每个书源的返回做 `filter { fName == name &&
    /// (!checkAuthor || fAuthor.contains(author)) }` — 只保留**同名书**，
    /// 书名不同（含毫不相关的错书）直接丢弃，不进入换源列表。此前 Rust 侧
    /// 只打分排序不过滤，match_score 为 0 的错书仍全部展示（Task #25 现象）。
    ///
    /// - `check_author = false`：仅按同名过滤；
    /// - `check_author = true`（原版「校验作者」开关，AppConfig.changeSourceCheckAuthor）：
    ///   额外要求候选作者包含目标作者。
    pub fn filter_for_change(
        candidates: Vec<SearchCandidate>,
        target_name: &str,
        target_author: &str,
        check_author: bool,
    ) -> Vec<SearchCandidate> {
        candidates
            .into_iter()
            .filter(|c| Self::is_same_book_name(&c.book_name, target_name))
            .filter(|c| !check_author || Self::author_matches(&c.author, target_author))
            .collect()
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

        // 作者匹配（Task #25：先规范化剥离「作者：」前缀/「 著」后缀，对齐原版 authorRegex）
        let ra = Self::normalize_author(result_author);
        let ta = Self::normalize_author(target_author);
        if !ta.is_empty() && !ra.is_empty() {
            if ra == ta {
                score += 30.0;
            } else if ra.contains(&ta) || ta.contains(&ra) {
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

/// 从 chapterWordCountText 提取 `[n]` 章节序号（对齐原版 chapterNumRegex）
fn chapter_num_from_text(text: Option<&str>) -> i32 {
    let Some(text) = text else {
        return -1;
    };
    text.trim_start()
        .strip_prefix('[')
        .and_then(|rest| rest.split(']').next())
        .and_then(|num| num.parse::<i32>().ok())
        .unwrap_or(-1)
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
                chapter_word_count_text: None,
                chapter_word_count: -1,
                respond_time: -1,
                origin_order: 0,
            },
            SearchCandidate {
                source_url: "s2".into(),
                source_name: "源2".into(),
                book_url: "b2".into(),
                book_name: "凡人修仙传".into(),
                author: "忘语".into(),
                latest_chapter: None,
                word_count: None,
                chapter_word_count_text: None,
                chapter_word_count: -1,
                respond_time: -1,
                origin_order: 0,
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
            chapter_word_count_text: None,
            chapter_word_count: -1,
            respond_time: -1,
            origin_order: 0,
        };
        assert!(SourceMatcher::is_good_match(&good));

        let bad = SourceMatch {
            score: 20.0,
            ..good.clone()
        };
        assert!(!SourceMatcher::is_good_match(&bad));
    }

    fn candidate(source_url: &str, book_name: &str, author: &str) -> SearchCandidate {
        SearchCandidate {
            source_url: source_url.into(),
            source_name: format!("源-{source_url}"),
            book_url: format!("{source_url}/book"),
            book_name: book_name.into(),
            author: author.into(),
            latest_chapter: None,
            word_count: None,
            chapter_word_count_text: None,
            chapter_word_count: -1,
            respond_time: -1,
            origin_order: 0,
        }
    }

    /// Task #25：作者规范化 — 剥离「作者：」前缀与「 著」后缀
    #[test]
    fn test_normalize_author() {
        assert_eq!(SourceMatcher::normalize_author("作者：STDe亦寒"), "STDe亦寒");
        assert_eq!(SourceMatcher::normalize_author("作者: STDe亦寒"), "STDe亦寒");
        assert_eq!(SourceMatcher::normalize_author("小桥老树 著"), "小桥老树");
        assert_eq!(SourceMatcher::normalize_author("天蚕土豆"), "天蚕土豆");
        assert_eq!(SourceMatcher::normalize_author("  "), "");
    }

    /// Task #25：带「作者：」前缀的目标作者与裸作者候选仍计同名同作者高分
    #[test]
    fn test_match_score_with_author_prefix() {
        let score = SourceMatcher::match_score("灵气复苏", "STDe亦寒", "灵气复苏", "作者：STDe亦寒");
        assert_eq!(score, 80.0);
    }

    /// Task #25：书名规范化 — trim + 成对剥离首尾括号，不做模糊匹配
    #[test]
    fn test_normalize_book_name() {
        assert_eq!(SourceMatcher::normalize_book_name("  灵气复苏 "), "灵气复苏");
        assert_eq!(SourceMatcher::normalize_book_name("(灵气复苏)"), "灵气复苏");
        assert_eq!(SourceMatcher::normalize_book_name("【灵气复苏】"), "灵气复苏");
        assert_eq!(SourceMatcher::normalize_book_name("（灵气复苏）"), "灵气复苏");
        // 括号不成对/内部括号/后缀括号不剥离（保守口径，对齐原版 equals）
        assert_eq!(SourceMatcher::normalize_book_name("灵气复苏("), "灵气复苏(");
        assert_eq!(SourceMatcher::normalize_book_name("灵气(复)苏"), "灵气(复)苏");
        assert_eq!(SourceMatcher::normalize_book_name("灵气复苏(全集)"), "灵气复苏(全集)");
    }

    /// Task #25：同名判定 — 规范化后精确相等；空名/异名均不匹配
    #[test]
    fn test_is_same_book_name() {
        assert!(SourceMatcher::is_same_book_name("灵气复苏", "灵气复苏"));
        assert!(SourceMatcher::is_same_book_name(" 【灵气复苏】 ", "灵气复苏"));
        assert!(!SourceMatcher::is_same_book_name("侯卫东官场笔记", "灵气复苏"));
        assert!(!SourceMatcher::is_same_book_name("", "灵气复苏"));
        assert!(!SourceMatcher::is_same_book_name("灵气复苏", ""));
        // 仅包含关系不算同名（原版 equals 口径）
        assert!(!SourceMatcher::is_same_book_name("灵气复苏之无敌", "灵气复苏"));
    }

    /// Task #25：作者校验 — 目标作者为空不校验；非空时 contains 判定
    #[test]
    fn test_author_matches() {
        assert!(SourceMatcher::author_matches("张三", ""));
        assert!(SourceMatcher::author_matches("张三", "  "));
        assert!(SourceMatcher::author_matches("作者：张三", "张三"));
        assert!(SourceMatcher::author_matches("张三", "张三"));
        assert!(!SourceMatcher::author_matches("李四", "张三"));
        assert!(!SourceMatcher::author_matches("", "张三"));
    }

    /// Task #25：换源硬过滤 — 同名书保留、毫不相关的错书被剔除；
    /// check_author=true 时作者不含目标作者的也被剔除
    #[test]
    fn test_filter_for_change_same_name_only() {
        let candidates = vec![
            candidate("s1", "灵气复苏", "甲作者"),
            candidate("s2", " 【灵气复苏】 ", "乙作者"),
            candidate("s3", "侯卫东官场笔记", "丙作者"),
            candidate("s4", "灵气复苏之无敌", "甲作者"),
        ];
        let kept = SourceMatcher::filter_for_change(candidates.clone(), "灵气复苏", "甲作者", false);
        let urls: Vec<&str> = kept.iter().map(|c| c.source_url.as_str()).collect();
        assert_eq!(urls, vec!["s1", "s2"], "仅同名书进入换源列表");

        // 校验作者：s2 作者不含目标作者被剔除
        let kept2 = SourceMatcher::filter_for_change(candidates, "灵气复苏", "甲作者", true);
        let urls2: Vec<&str> = kept2.iter().map(|c| c.source_url.as_str()).collect();
        assert_eq!(urls2, vec!["s1"], "check_author=true 时作者不含目标作者被剔除");
    }

    /// Task #25：过滤+排序全链 — 同名同作者高分排最前，无关书全部被过滤
    #[test]
    fn test_filter_then_rank_puts_best_match_first() {
        let candidates = vec![
            candidate("s-bad", "侯卫东官场笔记", "丙作者"),
            candidate("s-name-only", "灵气复苏", "王五"),
            candidate("s-full", "灵气复苏", "甲作者"),
        ];
        let filtered = SourceMatcher::filter_for_change(candidates, "灵气复苏", "甲作者", false);
        let ranked = SourceMatcher::rank_candidates(filtered, "灵气复苏", "甲作者");
        assert_eq!(ranked.len(), 2, "错书应被过滤");
        // 同名同作者 80 分 > 仅同名 50 分
        assert_eq!(ranked[0].source_url, "s-full");
        assert_eq!(ranked[0].score, 80.0);
        assert_eq!(ranked[1].source_url, "s-name-only");
        assert!(ranked[1].score < ranked[0].score);
    }

    /// Task #25：目标书名为空时不放行任何候选（防误匹配）
    #[test]
    fn test_filter_for_change_empty_target_name() {
        let candidates = vec![candidate("s1", "灵气复苏", "甲作者")];
        let kept = SourceMatcher::filter_for_change(candidates, "", "甲作者", false);
        assert!(kept.is_empty());
    }
}
