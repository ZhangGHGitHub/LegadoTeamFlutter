//! TXT 书籍内容搜索 FFI API
//!
//! 暴露 TxtSearch 功能给 Flutter 端，支持：
//! - 全文搜索（纯文本/正则）
//! - 章节内搜索
//! - 匹配计数

use legado_book::txt_search::{SearchMode, SearchOptions, TxtSearch};
use legado_core::LegadoResult;

/// 搜索 TXT 文件内容
///
/// # 参数
/// - `path`: TXT 文件路径
/// - `query`: 搜索关键词
/// - `case_sensitive`: 是否区分大小写
/// - `max_results`: 最大返回结果数
///
/// # 返回
/// JSON 序列化的 `Vec<TxtSearchResult>`
pub fn txt_search(
    path: &str,
    query: &str,
    case_sensitive: bool,
    max_results: i32,
) -> LegadoResult<String> {
    let options = SearchOptions {
        mode: SearchMode::PlainText,
        case_sensitive,
        max_total_results: max_results.max(1) as usize,
        ..Default::default()
    };

    let results = TxtSearch::search(path, query, &options)?;
    serde_json::to_string(&results)
        .map_err(|e| legado_core::LegadoError::Internal(format!("序列化搜索结果失败: {e}")))
}

/// 使用正则搜索 TXT 文件内容
pub fn txt_search_regex(
    path: &str,
    pattern: &str,
    case_sensitive: bool,
    max_results: i32,
) -> LegadoResult<String> {
    let options = SearchOptions {
        mode: SearchMode::Regex,
        case_sensitive,
        max_total_results: max_results.max(1) as usize,
        ..Default::default()
    };

    let results = TxtSearch::search(path, pattern, &options)?;
    serde_json::to_string(&results)
        .map_err(|e| legado_core::LegadoError::Internal(format!("序列化搜索结果失败: {e}")))
}

/// 在指定章节内搜索
pub fn txt_search_in_chapter(
    path: &str,
    query: &str,
    chapter_index: i32,
    case_sensitive: bool,
    max_results: i32,
) -> LegadoResult<String> {
    let options = SearchOptions {
        mode: SearchMode::PlainText,
        case_sensitive,
        max_results_per_chapter: max_results.max(1) as usize,
        ..Default::default()
    };

    let results = TxtSearch::search_in_chapter(path, query, chapter_index, &options)?;
    serde_json::to_string(&results)
        .map_err(|e| legado_core::LegadoError::Internal(format!("序列化搜索结果失败: {e}")))
}

/// 统计匹配总数（不返回完整结果）
pub fn txt_search_count(path: &str, query: &str, case_sensitive: bool) -> LegadoResult<i32> {
    let options = SearchOptions {
        mode: SearchMode::PlainText,
        case_sensitive,
        ..Default::default()
    };

    let count = TxtSearch::count_matches(path, query, &options)?;
    Ok(count as i32)
}
