//! 书架管理 API
//!
//! 提供书籍的增删改查操作，通过 BookRepository 访问数据库。

use legado_core::models::Book;
use legado_core::LegadoResult;
use legado_db::import::RoomImporter;
use legado_db::repository::Repository;
use legado_db::BookRepository;

use crate::db_state::with_database;

/// 获取书架上所有书籍
pub fn list_books() -> LegadoResult<Vec<Book>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        // Task#125 P0：仅返回已入书架的书，过滤 notShelf 临时书（搜索/发现打开的在线书）
        repo.find_all_in_shelf()
    })
}

/// 添加一本书（JSON 序列化传入）
pub fn add_book(book_json: &str) -> LegadoResult<Book> {
    let book: Book = serde_json::from_str(book_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("Book JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        // Task#125 P0：用原地 UPDATE 语义的 upsert，避免对已存在的临时书
        // 触发 INSERT OR REPLACE 级联删除其章节目录（转正/重复加入书架时安全）
        repo.update(&book)?;
        Ok(book)
    })
}

/// 更新书籍信息（JSON 序列化传入）
pub fn update_book(book_json: &str) -> LegadoResult<()> {
    let book: Book = serde_json::from_str(book_json)
        .map_err(|e| legado_core::LegadoError::Ffi(format!("Book JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.update(&book)
    })
}

/// 按 bookUrl 删除书籍
pub fn delete_book(book_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.delete_by_url(book_url)
    })
}

/// 按 bookUrl 获取单本书籍详情
pub fn get_book(book_url: &str) -> LegadoResult<Option<Book>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.find_by_url(book_url)
    })
}

/// 批量导入书籍（JSON 数组）
///
/// `json_array` 中每个元素为一本书的 JSON 对象，返回成功导入的数量。
pub fn import_books(json_array: &str) -> LegadoResult<i32> {
    with_database(|db| {
        let count = RoomImporter::import_books(db.connection(), json_array)?;
        Ok(count as i32)
    })
}

/// 更新阅读进度
pub fn update_reading_progress(
    book_url: &str,
    chapter_index: i32,
    chapter_pos: i32,
) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        let mut book = repo
            .find_by_url(book_url)?
            .ok_or_else(|| legado_core::LegadoError::Database("书籍不存在".into()))?;
        book.dur_chapter_index = chapter_index;
        book.dur_chapter_pos = chapter_pos;
        book.dur_chapter_time = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        // 更新章节标题
        let chapter_repo = legado_db::BookChapterRepository::new(db.connection());
        if let Some(ch) = chapter_repo.find_by_book_url_and_index(book_url, chapter_index)? {
            book.dur_chapter_title = Some(ch.title);
        }
        repo.update(&book)
    })
}
