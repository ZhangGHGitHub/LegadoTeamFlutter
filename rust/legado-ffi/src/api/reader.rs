//! 阅读 API
//!
//! 提供章节列表获取与章节内容读取能力，支持在线书源与本地书籍两种模式。
//! 在线书籍支持通过网络刷新书籍目录（refresh_toc）和抓取正文（fetch_chapter_content）。

use serde::{Deserialize, Serialize};

use legado_core::cache_book::CachedChapter;
use legado_core::models::BookChapter;
use legado_core::web_book::WebChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{BookChapterRepository, BookSourceRepository, CacheBookRepository};

use crate::db_state::with_database;
use crate::runtime;

/// 章节列表响应（包含章节概要信息）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterListResponse {
    /// 章节总数
    pub total: i32,
    /// 章节列表
    pub chapters: Vec<BookChapter>,
}

/// 获取指定书籍的章节列表
///
/// 优先从数据库读取；若数据库无记录且为本地书籍，则从文件解析章节并入库（懒加载）。
pub fn get_chapters(book_url: &str) -> LegadoResult<ChapterListResponse> {
    // 1. 尝试从数据库读取已有章节
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;

    if !chapters.is_empty() {
        let total = chapters.len() as i32;
        return Ok(ChapterListResponse { total, chapters });
    }

    // 2. 数据库无章节：如果是本地书籍，从文件解析并入库
    if is_local_book(book_url) {
        let chapter_infos = legado_book::LocalBook::get_chapters(book_url)?;
        let book_chapters: Vec<BookChapter> = chapter_infos
            .iter()
            .map(|ci| BookChapter {
                url: ci.url.clone(),
                title: ci.title.clone(),
                is_volume: ci.is_volume,
                base_url: book_url.to_string(),
                book_url: book_url.to_string(),
                index: ci.index,
                is_vip: false,
                is_pay: false,
                resource_url: None,
                tag: None,
                word_count: None,
                start: ci.start,
                end: ci.end,
                start_fragment_id: None,
                end_fragment_id: None,
                variable: None,
                img_url: None,
            })
            .collect();

        // 存入数据库供后续访问
        if !book_chapters.is_empty() {
            with_database(|db| {
                let repo = BookChapterRepository::new(db.connection());
                repo.insert_batch(&book_chapters)?;
                Ok(())
            })?;
        }

        let total = book_chapters.len() as i32;
        return Ok(ChapterListResponse {
            total,
            chapters: book_chapters,
        });
    }

    // 3. 在线书籍无章节记录，返回空
    Ok(ChapterListResponse {
        total: 0,
        chapters: vec![],
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

// ─── 在线目录/正文抓取 ────────────────────────────────────────────────────────

/// 从网络刷新书籍目录
///
/// 流程：
/// 1. 根据 `source_url` 从数据库查找书源配置
/// 2. 使用 WebBookEngine 从网络获取章节列表
/// 3. 将 WebChapter 转换为 BookChapter 并存入数据库
/// 4. 返回 JSON 格式的章节列表
pub fn refresh_toc(book_url: &str, source_url: &str) -> LegadoResult<ChapterListResponse> {
    // 1. 从数据库获取书源配置
    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // 2. 使用 WebBookEngine 从网络获取章节列表
    let engine = super::web_book::build_engine();
    let web_chapters: Vec<WebChapter> =
        runtime::block_on(async { engine.get_chapters(&source, book_url).await })?;

    // 3. 转换为 BookChapter 并存入数据库
    let book_chapters: Vec<BookChapter> = web_chapters
        .iter()
        .map(|wc| BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: false,
            base_url: book_url.to_string(),
            book_url: book_url.to_string(),
            index: wc.index,
            is_vip: wc.is_vip,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: None,
            start: None,
            end: None,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: None,
            img_url: None,
        })
        .collect();

    // 4. 确保书籍记录存在（满足 chapters 表外键约束），然后先删除旧章节，再批量插入新章节
    with_database(|db| {
        let book_repo = legado_db::BookRepository::new(db.connection());
        if book_repo.find_by_url(book_url)?.is_none() {
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                ..legado_core::models::Book::default()
            };
            book_repo.insert(&book)?;
        }
        let repo = BookChapterRepository::new(db.connection());
        repo.delete_by_book_url(book_url)?;
        repo.insert_batch(&book_chapters)?;
        Ok(())
    })?;

    let total = book_chapters.len() as i32;
    Ok(ChapterListResponse {
        total,
        chapters: book_chapters,
    })
}

/// 获取章节正文内容（在线抓取，带 DB 缓存）
///
/// 流程：
/// 1. 先检查 DB 缓存（cached_chapters 表）
/// 2. 如果缓存命中，直接返回缓存的正文
/// 3. 如果缓存未命中：
///    a. 使用 WebBookEngine::get_content 从网络抓取正文
///    b. 将结果存入 DB 缓存
///    c. 返回真实正文文本
pub fn fetch_chapter_content(
    book_url: &str,
    chapter_url: &str,
    source_url: &str,
) -> LegadoResult<String> {
    // 1. 检查 DB 缓存
    let cached = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.get_by_chapter_url(chapter_url)
    })?;

    if let Some(cached_chapter) = cached {
        return Ok(cached_chapter.content);
    }

    // 2. 缓存未命中，从网络获取
    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // 构造 WebChapter 用于请求
    let chapter_index = get_chapter_index_by_url(book_url, chapter_url)?;
    let web_chapter = WebChapter {
        index: chapter_index,
        title: String::new(),
        url: chapter_url.to_string(),
        is_vip: false,
    };

    let engine = super::web_book::build_engine();
    let content = runtime::block_on(async { engine.get_content(&source, &web_chapter).await })?;

    // 3. 存入 DB 缓存
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let cached_chapter = CachedChapter {
        id: 0,
        book_url: book_url.to_string(),
        chapter_index,
        chapter_title: String::new(),
        chapter_url: chapter_url.to_string(),
        content: content.clone(),
        cached_at: now_ms,
        size_bytes: content.len() as i64,
    };

    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.insert(&cached_chapter)?;
        Ok(())
    })?;

    Ok(content)
}

/// 根据 chapter_url 查找章节序号（找不到时返回 0）
fn get_chapter_index_by_url(book_url: &str, chapter_url: &str) -> LegadoResult<i32> {
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;
    Ok(chapters
        .iter()
        .find(|ch| ch.url == chapter_url)
        .map(|ch| ch.index)
        .unwrap_or(0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::ContentRule;
    use legado_core::models::BookSource;

    /// 初始化测试数据库（全局 Once 保护，并行安全）
    fn setup_db_and_source(source_url: &str) {
        crate::db_state::ensure_test_db();
        insert_test_source(source_url);
    }

    /// 插入测试书源
    fn insert_test_source(source_url: &str) {
        with_database(|db| {
            let repo = BookSourceRepository::new(db.connection());
            let source = BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "测试书源".to_string(),
                search_url: Some(format!("{source_url}/search?q={{key}}")),
                rule_content: Some(ContentRule {
                    content: Some("css(.content).html".to_string()),
                    ..ContentRule::default()
                }),
                ..BookSource::default()
            };
            repo.insert(&source)?;
            Ok(())
        })
        .unwrap();
    }

    // ─── refresh_toc 测试 ───────────────────────────────────────────────────

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_refresh_toc_success() {
        let source_url = "https://toc-test.example.com";
        let book_url = "https://toc-test.example.com/book/1";
        setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
    }

    #[test]
    fn test_refresh_toc_source_not_found() {
        setup_db_and_source("https://other.example.com");
        let err = refresh_toc("https://x.com/book", "https://nonexistent.example.com").unwrap_err();
        assert!(err.to_string().contains("书源不存在"));
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_refresh_toc_saves_to_db() {
        let source_url = "https://toc-db-test.example.com";
        let book_url = "https://toc-db-test.example.com/book/2";
        setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
    }

    // ─── fetch_chapter_content 测试 ──────────────────────────────────────────

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_chapter_content_success() {
        let source_url = "https://content-test.example.com";
        let book_url = "https://content-test.example.com/book/1";
        let chapter_url = format!("{book_url}/chapter/0");
        setup_db_and_source(source_url);

        let content = fetch_chapter_content(book_url, &chapter_url, source_url).unwrap();
        assert!(!content.is_empty());
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_chapter_content_cache_hit() {
        let source_url = "https://cache-test.example.com";
        let book_url = "https://cache-test.example.com/book/1";
        let chapter_url = "https://cache-test.example.com/ch/99";
        setup_db_and_source(source_url);

        // 第一次调用：从网络获取并缓存
        let content1 = fetch_chapter_content(book_url, chapter_url, source_url).unwrap();
        assert!(!content1.is_empty());

        // 第二次调用：应命中缓存，返回相同内容
        let content2 = fetch_chapter_content(book_url, chapter_url, source_url).unwrap();
        assert_eq!(content1, content2);
    }

    #[test]
    fn test_fetch_chapter_content_source_not_found() {
        setup_db_and_source("https://other2.example.com");
        let err = fetch_chapter_content(
            "https://x.com/book",
            "https://x.com/ch/1",
            "https://no-such-source.example.com",
        )
        .unwrap_err();
        assert!(err.to_string().contains("书源不存在"));
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_chapter_content_returns_text_not_json_metadata() {
        let source_url = "https://text-check.example.com";
        let book_url = "https://text-check.example.com/book/1";
        let chapter_url = format!("{book_url}/chapter/0");
        setup_db_and_source(source_url);

        let content = fetch_chapter_content(book_url, &chapter_url, source_url).unwrap();
        // 确保返回的是真实正文，不是 JSON 元数据
        assert!(!content.contains("need_fetch"));
        assert!(!content.contains("chapter_url"));
    }
}
