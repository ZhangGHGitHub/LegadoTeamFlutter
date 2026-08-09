//! TXT 书籍内容搜索模块
//!
//! 提供本地 TXT 文件内的全文搜索能力：
//! - 支持纯文本搜索（大小写可选）
//! - 支持正则表达式搜索
//! - 支持中文文本搜索（字符级匹配，无需分词）
//! - 章节感知：返回结果包含章节定位和上下文摘要
//! - 结果数量限制，避免大文件搜索时内存溢出

use std::fs::File;
use std::io::Read;

use encoding_rs::UTF_8;
use regex::Regex;
use serde::{Deserialize, Serialize};

use legado_core::regex_safe::compile_regex_safe;
use legado_core::{LegadoError, LegadoResult};

use crate::txt::TxtParser;
use crate::ChapterInfo;

/// 搜索结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtSearchResult {
    /// 匹配的章节信息
    pub chapter_index: i32,
    /// 章节标题
    pub chapter_title: String,
    /// 匹配在章节内的字符偏移
    pub char_offset: usize,
    /// 匹配文本
    pub matched_text: String,
    /// 上下文摘要（匹配前后各取若干字符）
    pub context: String,
    /// 匹配在上下文中的起始位置
    pub context_match_start: usize,
    /// 匹配在上下文中的结束位置
    pub context_match_end: usize,
}

/// 搜索模式
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SearchMode {
    /// 纯文本搜索
    PlainText,
    /// 正则表达式搜索
    Regex,
}

/// 搜索选项
#[derive(Debug, Clone)]
pub struct SearchOptions {
    /// 搜索模式
    pub mode: SearchMode,
    /// 是否区分大小写
    pub case_sensitive: bool,
    /// 每个章节最大返回结果数
    pub max_results_per_chapter: usize,
    /// 全局最大返回结果数
    pub max_total_results: usize,
    /// 上下文摘要半径（匹配前后各取多少字符）
    pub context_radius: usize,
}

impl Default for SearchOptions {
    fn default() -> Self {
        Self {
            mode: SearchMode::PlainText,
            case_sensitive: false,
            max_results_per_chapter: 50,
            max_total_results: 500,
            context_radius: 40,
        }
    }
}

/// TXT 搜索引擎
pub struct TxtSearch;

impl TxtSearch {
    /// 在 TXT 文件中搜索关键词
    ///
    /// # 参数
    /// - `path`: TXT 文件路径
    /// - `query`: 搜索关键词
    /// - `options`: 搜索选项
    ///
    /// # 返回
    /// 搜索结果列表，按章节序号和字符偏移排序
    pub fn search(
        path: &str,
        query: &str,
        options: &SearchOptions,
    ) -> LegadoResult<Vec<TxtSearchResult>> {
        if query.is_empty() {
            return Ok(Vec::new());
        }

        // 获取章节列表
        let chapters = TxtParser::get_chapters(path)?;

        // 读取文件内容
        let text = read_and_decode(path)?;

        // 构建搜索正则（用户查询可构造任意 pattern，一律走统一安全入口）
        let search_pattern = build_search_pattern(query, options)?;
        let re = compile_regex_safe(&search_pattern)
            .ok_or_else(|| LegadoError::BookParse("搜索正则编译失败（非法或超限）".to_string()))?;

        let mut results = Vec::new();

        for chapter in &chapters {
            if results.len() >= options.max_total_results {
                break;
            }

            let chapter_results = search_in_chapter(
                &text,
                chapter,
                re.as_ref(),
                query,
                options,
                options.max_total_results - results.len(),
            );
            results.extend(chapter_results);
        }

        Ok(results)
    }

    /// 在指定章节内搜索
    pub fn search_in_chapter(
        path: &str,
        query: &str,
        chapter_index: i32,
        options: &SearchOptions,
    ) -> LegadoResult<Vec<TxtSearchResult>> {
        if query.is_empty() {
            return Ok(Vec::new());
        }

        let chapters = TxtParser::get_chapters(path)?;
        let chapter = chapters
            .iter()
            .find(|c| c.index == chapter_index)
            .ok_or_else(|| LegadoError::BookParse(format!("章节 {} 不存在", chapter_index)))?;

        let text = read_and_decode(path)?;
        let search_pattern = build_search_pattern(query, options)?;
        let re = compile_regex_safe(&search_pattern)
            .ok_or_else(|| LegadoError::BookParse("搜索正则编译失败（非法或超限）".to_string()))?;

        Ok(search_in_chapter(
            &text,
            chapter,
            re.as_ref(),
            query,
            options,
            options.max_results_per_chapter,
        ))
    }

    /// 搜索并统计匹配总数（不返回全部结果，用于 UI 显示计数）
    pub fn count_matches(path: &str, query: &str, options: &SearchOptions) -> LegadoResult<usize> {
        if query.is_empty() {
            return Ok(0);
        }

        let text = read_and_decode(path)?;
        let search_pattern = build_search_pattern(query, options)?;
        let re = compile_regex_safe(&search_pattern)
            .ok_or_else(|| LegadoError::BookParse("搜索正则编译失败（非法或超限）".to_string()))?;

        Ok(re.find_iter(&text).count())
    }
}

// ---------------------------------------------------------------------------
// 内部辅助函数
// ---------------------------------------------------------------------------

/// 读取文件并按编码解码为字符串
fn read_and_decode(path: &str) -> LegadoResult<String> {
    let encoding_name = TxtParser::detect_encoding(path)?;
    let mut file =
        File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;

    let enc = encoding_rs::Encoding::for_label(encoding_name.as_bytes()).unwrap_or(UTF_8);
    // 跳过 BOM
    let skip = if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        3
    } else if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
        2
    } else {
        0
    };
    let (cow, _, _) = enc.decode(&bytes[skip..]);
    Ok(cow.into_owned())
}

/// 构建搜索正则模式
fn build_search_pattern(query: &str, options: &SearchOptions) -> LegadoResult<String> {
    let pattern = match options.mode {
        SearchMode::PlainText => {
            // 转义正则特殊字符
            regex::escape(query)
        }
        SearchMode::Regex => {
            // 验证正则合法性（统一安全入口：1KB 上限 + nest_limit + 负缓存）
            compile_regex_safe(query)
                .ok_or_else(|| LegadoError::BookParse("无效正则表达式（非法或超限）".to_string()))?;
            query.to_string()
        }
    };

    // 添加大小写不敏感标志
    if !options.case_sensitive {
        Ok(format!("(?i){}", pattern))
    } else {
        Ok(pattern)
    }
}

/// 在单个章节内搜索
fn search_in_chapter(
    full_text: &str,
    chapter: &ChapterInfo,
    re: &Regex,
    _query: &str,
    options: &SearchOptions,
    max_results: usize,
) -> Vec<TxtSearchResult> {
    let start = chapter.start.unwrap_or(0) as usize;
    let end = chapter.end.unwrap_or(full_text.len() as i64) as usize;
    let start = start.min(full_text.len());
    let end = end.min(full_text.len());

    // 确保在字符边界上
    let start = full_text.floor_char_boundary(start);
    let end = full_text.floor_char_boundary(end);

    let chapter_text = &full_text[start..end];
    let mut results = Vec::new();

    for mat in re.find_iter(chapter_text) {
        if results.len() >= max_results {
            break;
        }

        let match_start = mat.start();
        let match_end = mat.end();
        let matched_text = mat.as_str().to_string();

        // 构建上下文摘要
        let ctx_start = match_start.saturating_sub(options.context_radius);
        let ctx_end = (match_end + options.context_radius).min(chapter_text.len());

        // 确保在字符边界
        let ctx_start = chapter_text.floor_char_boundary(ctx_start);
        let ctx_end = chapter_text.ceil_char_boundary(ctx_end);

        let context = chapter_text[ctx_start..ctx_end].to_string();

        // 计算字符偏移（非字节偏移）
        let char_offset = chapter_text[..match_start].chars().count();

        results.push(TxtSearchResult {
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            char_offset,
            matched_text,
            context,
            context_match_start: chapter_text[ctx_start..match_start].chars().count(),
            context_match_end: chapter_text[ctx_start..match_end].chars().count(),
        });
    }

    results
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// 创建临时 TXT 文件用于测试
    fn create_temp_txt(content: &str) -> String {
        let dir = std::env::temp_dir().join("legado_test_search");
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("test_{}.txt", uuid_v4()));
        let mut file = File::create(&path).unwrap();
        file.write_all(content.as_bytes()).unwrap();
        path.to_string_lossy().to_string()
    }

    /// 简单的 UUID v4 生成（仅用于测试文件名唯一性）
    fn uuid_v4() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{:x}", ts)
    }

    #[test]
    fn test_search_plain_text_basic() {
        let content = "第一章 开始\n这是第一章的内容。\n第二章 继续\n这是第二章的内容。";
        let path = create_temp_txt(content);

        let results = TxtSearch::search(&path, "第一章", &SearchOptions::default()).unwrap();
        // “第一章”在标题行和正文中各出现一次
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].matched_text, "第一章");
    }

    #[test]
    fn test_search_plain_text_multiple_matches() {
        let content = "第一章 开始\n测试内容测试。\n第二章 测试\n更多测试内容。";
        let path = create_temp_txt(content);

        let results = TxtSearch::search(&path, "测试", &SearchOptions::default()).unwrap();
        assert!(
            results.len() >= 3,
            "应找到至少3个'测试'匹配，实际: {}",
            results.len()
        );
    }

    #[test]
    fn test_search_case_insensitive() {
        let content = "第一章 Hello World\n第二章 hello world\n";
        let path = create_temp_txt(content);

        let opts = SearchOptions {
            case_sensitive: false,
            ..Default::default()
        };
        let results = TxtSearch::search(&path, "hello", &opts).unwrap();
        assert_eq!(results.len(), 2, "大小写不敏感应匹配2处");
    }

    #[test]
    fn test_search_case_sensitive() {
        let content = "第一章 Hello World\n第二章 hello world\n";
        let path = create_temp_txt(content);

        let opts = SearchOptions {
            case_sensitive: true,
            ..Default::default()
        };
        let results = TxtSearch::search(&path, "Hello", &opts).unwrap();
        assert_eq!(results.len(), 1, "大小写敏感应只匹配1处");
    }

    #[test]
    fn test_search_regex_mode() {
        let content = "第一章 2026年\n第二章 2025年\n第三章 二零二四年\n";
        let path = create_temp_txt(content);

        let opts = SearchOptions {
            mode: SearchMode::Regex,
            ..Default::default()
        };
        let results = TxtSearch::search(&path, r"\d{4}年", &opts).unwrap();
        assert_eq!(results.len(), 2, "正则应匹配2处年份");
    }

    #[test]
    fn test_search_empty_query() {
        let content = "第一章 内容\n";
        let path = create_temp_txt(content);

        let results = TxtSearch::search(&path, "", &SearchOptions::default()).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_no_match() {
        let content = "第一章 开始\n这是内容。\n";
        let path = create_temp_txt(content);

        let results = TxtSearch::search(&path, "不存在的内容", &SearchOptions::default()).unwrap();
        assert!(results.is_empty());
    }

    #[test]
    fn test_search_chinese_text() {
        let content = "第一章 江湖\n侠客行走江湖之中。\n第二章 武林\n江湖传闻很多。";
        let path = create_temp_txt(content);

        let results = TxtSearch::search(&path, "江湖", &SearchOptions::default()).unwrap();
        assert!(results.len() >= 3, "应在多处匹配'江湖'");
    }

    #[test]
    fn test_search_context_snippet() {
        let content = "第一章 开始\n前文内容。匹配关键词在这里。后文内容。\n";
        let path = create_temp_txt(content);

        let results = TxtSearch::search(&path, "匹配关键词", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].context.contains("匹配关键词"));
        assert!(results[0].context_match_start < results[0].context_match_end);
    }

    #[test]
    fn test_search_max_results_limit() {
        // 创建大量重复内容
        let mut content = String::from("第一章 开始\n");
        for _ in 0..100 {
            content.push_str("测试测试测试测试\n");
        }
        let path = create_temp_txt(&content);

        let opts = SearchOptions {
            max_total_results: 10,
            ..Default::default()
        };
        let results = TxtSearch::search(&path, "测试", &opts).unwrap();
        assert!(results.len() <= 10, "结果数不应超过 max_total_results");
    }

    #[test]
    fn test_count_matches() {
        let content = "第一章 测试\n第二章 测试测试\n第三章 无匹配\n";
        let path = create_temp_txt(content);

        let count = TxtSearch::count_matches(&path, "测试", &SearchOptions::default()).unwrap();
        assert_eq!(count, 3);
    }

    #[test]
    fn test_count_matches_empty_query() {
        let content = "内容\n";
        let path = create_temp_txt(content);

        let count = TxtSearch::count_matches(&path, "", &SearchOptions::default()).unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn test_search_in_specific_chapter() {
        let content = "第一章 开始\n这里有测试。\n第二章 继续\n这里也有测试。\n";
        let path = create_temp_txt(content);

        let results =
            TxtSearch::search_in_chapter(&path, "测试", 0, &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].chapter_index, 0);
    }

    #[test]
    fn test_search_result_serialization() {
        let result = TxtSearchResult {
            chapter_index: 0,
            chapter_title: "第一章".to_string(),
            char_offset: 10,
            matched_text: "测试".to_string(),
            context: "上下文测试内容".to_string(),
            context_match_start: 3,
            context_match_end: 5,
        };
        let json = serde_json::to_string(&result).unwrap();
        let de: TxtSearchResult = serde_json::from_str(&json).unwrap();
        assert_eq!(de.chapter_title, "第一章");
        assert_eq!(de.matched_text, "测试");
    }

    #[test]
    fn test_search_options_default() {
        let opts = SearchOptions::default();
        assert_eq!(opts.max_results_per_chapter, 50);
        assert_eq!(opts.max_total_results, 500);
        assert_eq!(opts.context_radius, 40);
        assert!(!opts.case_sensitive);
        assert!(matches!(opts.mode, SearchMode::PlainText));
    }

    #[test]
    fn test_build_search_pattern_plain() {
        let opts = SearchOptions::default();
        let pattern = build_search_pattern("hello.world", &opts).unwrap();
        assert!(pattern.contains(r"\.")); // dot should be escaped
    }

    #[test]
    fn test_build_search_pattern_regex_invalid() {
        let opts = SearchOptions {
            mode: SearchMode::Regex,
            ..Default::default()
        };
        let result = build_search_pattern("[invalid", &opts);
        assert!(result.is_err());
    }

    #[test]
    fn test_search_special_regex_chars_escaped() {
        let content = "第一章 (测试)\n第二章 [内容]\n";
        let path = create_temp_txt(content);

        // 纯文本模式下，括号应被转义
        let results = TxtSearch::search(&path, "(测试)", &SearchOptions::default()).unwrap();
        assert_eq!(results.len(), 1);
    }
}
