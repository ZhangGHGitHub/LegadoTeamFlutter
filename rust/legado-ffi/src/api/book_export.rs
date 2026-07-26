//! 书籍导出 API
//!
//! 提供书籍导出为 TXT/EPUB/HTML 的能力。

use serde::{Deserialize, Serialize};

use legado_book::export::{BookExporter, ExportChapter, ExportConfig, ExportData, ExportFormat};
use legado_core::LegadoResult;
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::cache_book_repository::CacheBookRepository;

use crate::db_state::with_database;

/// 导出结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ExportResult {
    /// 是否成功
    pub success: bool,
    /// 导出文件内容（base64 编码）
    pub data_base64: Option<String>,
    /// 文件名
    pub file_name: Option<String>,
    /// MIME 类型
    pub mime_type: Option<String>,
    /// 错误信息（失败时）
    pub error: Option<String>,
}

/// 导出书籍
///
/// # 参数
/// - `book_url`: 书籍 URL
/// - `format`: 导出格式（txt/epub/html）
/// - `include_toc`: 是否包含目录
///
/// # 返回
/// 导出结果，包含 base64 编码的文件内容
pub fn export_book(book_url: &str, format: &str, include_toc: bool) -> LegadoResult<ExportResult> {
    // 解析导出格式
    let export_format = match ExportFormat::from_str(format) {
        Some(f) => f,
        None => {
            return Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("不支持的导出格式: {format}，支持 txt/epub/html")),
            });
        }
    };

    // 从数据库获取书籍和章节数据
    let result = with_database(|db| {
        let book_repo = BookRepository::new(db.connection());
        let book = book_repo.find_by_url(book_url)?;

        let book = match book {
            Some(b) => b,
            None => {
                return Ok(ExportResult {
                    success: false,
                    data_base64: None,
                    file_name: None,
                    mime_type: None,
                    error: Some(format!("书籍不存在: {book_url}")),
                });
            }
        };

        let chapter_repo = BookChapterRepository::new(db.connection());
        let chapters = chapter_repo.find_by_book_url(book_url)?;

        let cache_repo = CacheBookRepository::new(db.connection());
        let cached = cache_repo.get_by_book(book_url).unwrap_or_default();

        // 构造导出数据
        let export_chapters: Vec<ExportChapter> = chapters
            .iter()
            .map(|ch| {
                let content = cached
                    .iter()
                    .find(|c| c.chapter_index == ch.index)
                    .map(|c| c.content.clone())
                    .unwrap_or_default();
                ExportChapter {
                    index: ch.index,
                    title: ch.title.clone(),
                    content,
                }
            })
            .collect();

        let export_data = ExportData {
            title: book.name.clone(),
            author: book.author.clone(),
            intro: book.intro.clone(),
            chapters: export_chapters,
        };

        let config = ExportConfig {
            format: export_format,
            include_toc,
            chapter_separator: String::new(),
            encoding: "UTF-8".to_string(),
        };

        // 执行导出
        match BookExporter::export(&export_data, &config) {
            Ok(bytes) => {
                use base64::Engine;
                let b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
                let file_name = format!("{}.{}", book.name, export_format.extension());
                Ok(ExportResult {
                    success: true,
                    data_base64: Some(b64),
                    file_name: Some(file_name),
                    mime_type: Some(export_format.mime_type().to_string()),
                    error: None,
                })
            }
            Err(e) => Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("导出失败: {e}")),
            }),
        }
    });

    result
}

/// 获取导出预览信息
pub fn export_info(book_url: &str, format: &str) -> LegadoResult<ExportResult> {
    let export_format = match ExportFormat::from_str(format) {
        Some(f) => f,
        None => {
            return Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("不支持的导出格式: {format}")),
            });
        }
    };

    with_database(|db| {
        let book_repo = BookRepository::new(db.connection());
        let book = book_repo.find_by_url(book_url)?;

        match book {
            Some(b) => {
                let chapter_repo = BookChapterRepository::new(db.connection());
                let chapters = chapter_repo.find_by_book_url(book_url)?;
                let file_name = format!("{}.{}", b.name, export_format.extension());
                Ok(ExportResult {
                    success: true,
                    data_base64: None,
                    file_name: Some(file_name),
                    mime_type: Some(export_format.mime_type().to_string()),
                    error: Some(format!("章节数: {}", chapters.len())),
                })
            }
            None => Ok(ExportResult {
                success: false,
                data_base64: None,
                file_name: None,
                mime_type: None,
                error: Some(format!("书籍不存在: {book_url}")),
            }),
        }
    })
}
