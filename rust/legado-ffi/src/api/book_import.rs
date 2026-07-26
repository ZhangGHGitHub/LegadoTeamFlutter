//! 书籍导入 API
//!
//! 提供本地书籍格式检测、元数据解析与导入书架的能力。

use serde::{Deserialize, Serialize};

use legado_book::{BookMetadata, LocalBook};
use legado_core::models::Book;
use legado_core::LegadoResult;
use legado_db::repository::Repository;
use legado_db::BookRepository;

use crate::db_state::with_database;

/// 书籍格式检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectFormatResult {
    /// 检测到的格式
    pub format: String,
    /// 文件路径
    pub path: String,
}

/// 导入结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ImportResult {
    /// 是否成功
    pub success: bool,
    /// 导入的书籍信息（成功时）
    pub book: Option<Book>,
    /// 错误信息（失败时）
    pub error: Option<String>,
}

/// 检测书籍文件格式
pub fn detect_format(file_path: &str) -> LegadoResult<DetectFormatResult> {
    let format = LocalBook::detect_format(file_path)?;
    Ok(DetectFormatResult {
        format: format.as_str().to_string(),
        path: file_path.to_string(),
    })
}

/// 解析书籍元数据
pub fn parse_metadata(file_path: &str) -> LegadoResult<BookMetadata> {
    LocalBook::parse(file_path)
}

/// 导入本地书籍到书架
///
/// 1. 检测格式
/// 2. 解析元数据
/// 3. 构造 Book 实体
/// 4. 插入数据库
pub fn import_local_book(file_path: &str) -> LegadoResult<ImportResult> {
    // 检测格式（用于验证文件是否为支持的格式）
    let _format = LocalBook::detect_format(file_path)?;

    // 解析元数据
    let metadata = match LocalBook::parse(file_path) {
        Ok(m) => m,
        Err(e) => {
            return Ok(ImportResult {
                success: false,
                book: None,
                error: Some(format!("元数据解析失败: {e}")),
            });
        }
    };

    // 构造 Book 实体
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let mut book = Book::default();
    book.book_url = file_path.to_string();
    book.name = metadata.title;
    book.author = metadata.author;
    book.intro = Some(metadata.description);
    book.origin = legado_core::models::book::book_type::LOCAL_TAG.to_string();
    book.origin_name = std::path::Path::new(file_path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    book.book_type = legado_core::models::book::book_type::LOCAL;
    book.last_check_time = now;

    // 插入数据库
    let result = with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.insert(&book)
    });

    match result {
        Ok(()) => Ok(ImportResult {
            success: true,
            book: Some(book),
            error: None,
        }),
        Err(e) => Ok(ImportResult {
            success: false,
            book: None,
            error: Some(format!("导入数据库失败: {e}")),
        }),
    }
}
