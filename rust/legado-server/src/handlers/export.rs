//! 书籍导出处理器

use axum::extract::State;
use axum::http::header;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::Value;
use std::sync::Arc;

use legado_book::export::{BookExporter, ExportChapter, ExportConfig, ExportData, ExportFormat};
use legado_core::LegadoError;
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::cache_book_repository::CacheBookRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// 导出请求体
#[derive(Debug, Deserialize)]
pub struct ExportRequest {
    /// 书籍 URL（bookUrl）
    pub book_url: String,
    /// 导出格式：txt / epub / html / pdf
    pub format: String,
    /// 是否包含目录
    #[serde(default = "default_true")]
    pub include_toc: bool,
}

fn default_true() -> bool {
    true
}

/// POST /api/books/export — 导出书籍
pub async fn export_book(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ExportRequest>,
) -> Result<Response, ApiError> {
    // 解析导出格式
    let format = ExportFormat::from_str(&req.format).ok_or_else(|| {
        ApiError(LegadoError::Internal(format!(
            "不支持的导出格式: {}，支持 txt/epub/html/pdf",
            req.format
        )))
    })?;

    // 查询书籍
    let db = state.db.lock().await;
    let book_repo = BookRepository::new(db.connection());
    let book = book_repo.find_by_url(&req.book_url)?.ok_or_else(|| {
        ApiError(LegadoError::Internal(format!(
            "书籍不存在: {}",
            req.book_url
        )))
    })?;

    // 查询章节列表
    let chapter_repo = BookChapterRepository::new(db.connection());
    let chapters = chapter_repo.find_by_book_url(&req.book_url)?;

    // 查询缓存内容
    let cache_repo = CacheBookRepository::new(db.connection());
    let cached = cache_repo.get_by_book(&req.book_url).unwrap_or_default();

    // 构造导出数据（优先使用缓存内容）
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
        format,
        include_toc: req.include_toc,
        chapter_separator: String::new(),
        encoding: "UTF-8".to_string(),
    };

    // 执行导出
    let bytes = BookExporter::export(&export_data, &config)
        .map_err(|e| ApiError(LegadoError::Internal(format!("导出失败: {e}"))))?;

    // 构造文件名
    let file_name = format!("{}.{}", book.name, format.extension());

    // 返回文件下载响应
    let response = (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, format.mime_type().to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{file_name}\""),
            ),
        ],
        bytes,
    );

    Ok(response.into_response())
}

/// POST /api/books/export/info — 获取导出预览信息（不实际导出）
pub async fn export_info(
    State(state): State<Arc<AppState>>,
    Json(req): Json<ExportRequest>,
) -> Result<Json<Value>, ApiError> {
    let format = ExportFormat::from_str(&req.format).ok_or_else(|| {
        ApiError(LegadoError::Internal(format!(
            "不支持的导出格式: {}，支持 txt/epub/html/pdf",
            req.format
        )))
    })?;

    let db = state.db.lock().await;
    let book_repo = BookRepository::new(db.connection());
    let book = book_repo.find_by_url(&req.book_url)?.ok_or_else(|| {
        ApiError(LegadoError::Internal(format!(
            "书籍不存在: {}",
            req.book_url
        )))
    })?;

    let chapter_repo = BookChapterRepository::new(db.connection());
    let chapters = chapter_repo.find_by_book_url(&req.book_url)?;

    Ok(Json(serde_json::json!({
        "title": book.name,
        "author": book.author,
        "chapter_count": chapters.len(),
        "format": req.format,
        "extension": format.extension(),
        "mime_type": format.mime_type(),
    })))
}
