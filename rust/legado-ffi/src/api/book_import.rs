//! 书籍导入 API
//!
//! 提供本地书籍格式检测、元数据解析与导入书架的能力。

use serde::{Deserialize, Serialize};

use legado_book::{BookMetadata, LocalBook};
use legado_core::models::Book;
use legado_core::LegadoResult;
use legado_db::repository::Repository;
use legado_db::BookRepository;

use crate::db_state::{resolve_local_book_path, with_database};

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
///
/// [iOS 视角F C1] `file_path` 可以是「可迁移标识」（相对 Documents 的路径，
/// 如 `books/x.epub`）而非绝对路径：解析/检测时用 [`resolve_local_book_path`]
/// 还原为当前容器的真实路径，而 **`book_url` 原样存 `file_path`**（即标识），
/// 使本地书在重签名/重装（容器 UUID 变化）后仍可按相对标识重建读取。
/// 绝对路径（存量/非 iOS）经 resolver 原样透传，行为不变。
pub fn import_local_book(file_path: &str) -> LegadoResult<ImportResult> {
    // 还原为真实文件路径（相对标识 → 当前 Documents 拼接；绝对/Web 原样）
    let real_path = resolve_local_book_path(file_path);

    // 检测格式（用于验证文件是否为支持的格式）
    let _format = LocalBook::detect_format(&real_path)?;

    // 解析元数据
    let metadata = match LocalBook::parse(&real_path) {
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
