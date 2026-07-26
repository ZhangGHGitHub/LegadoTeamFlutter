//! 阅读 API
//!
//! 提供章节列表获取与章节内容读取能力，支持在线书源与本地书籍两种模式。

use serde::{Deserialize, Serialize};

use legado_core::models::BookChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::BookChapterRepository;

use crate::db_state::with_database;

/// 章节列表响应（包含章节概要信息）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterListResponse {
    /// 章节总数
    pub total: i32,
    /// 章节列表
    pub chapters: Vec<BookChapter>,
}

/// 获取指定书籍的章节列表（从数据库读取）
pub fn get_chapters(book_url: &str) -> LegadoResult<ChapterListResponse> {
    with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        let chapters = repo.find_by_book_url(book_url)?;
        let total = chapters.len() as i32;
        Ok(ChapterListResponse { total, chapters })
    })
}

/// 获取章节正文内容
///
/// 对于本地书籍（bookUrl 为文件路径），使用 legado-book 解析器读取。
/// 对于在线书籍，需配合书源规则通过网络获取（此处返回数据库缓存或空）。
pub fn get_chapter_content(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    // 查询章节信息
    let chapter = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url_and_index(book_url, chapter_index)
    })?
    .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;

    // 判断是否为本地书籍
    if is_local_book(book_url) {
        // 使用 legado-book 解析本地文件
        let content = legado_book::LocalBook::get_chapter_content(
            book_url,
            &chapter_to_local_info(&chapter),
        )?;
        Ok(content)
    } else {
        // 在线书籍：返回章节 URL 信息，由上层配合书源规则获取正文
        // 简化实现：返回章节 URL 供 Dart 侧进一步处理
        Ok(serde_json::to_string(&serde_json::json!({
            "chapter_url": chapter.url,
            "base_url": chapter.base_url,
            "title": chapter.title,
            "need_fetch": true,
        }))?)
    }
}

/// 判断是否为本地书籍
fn is_local_book(book_url: &str) -> bool {
    let lower = book_url.to_lowercase();
    lower.ends_with(".epub")
        || lower.ends_with(".txt")
        || lower.ends_with(".text")
        || lower.ends_with(".mobi")
        || lower.ends_with(".azw")
        || lower.ends_with(".azw3")
        || lower.ends_with(".pdf")
}

/// 将 BookChapter 转换为 legado-book 的 ChapterInfo
fn chapter_to_local_info(ch: &BookChapter) -> legado_book::ChapterInfo {
    legado_book::ChapterInfo {
        url: ch.url.clone(),
        title: ch.title.clone(),
        index: ch.index,
        is_volume: ch.is_volume,
        start: ch.start,
        end: ch.end,
    }
}
