//! 阅读相关处理器（章节列表、章节内容）

use axum::extract::{Path, State};
use axum::Json;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_db::repository::book_chapter_repository::BookChapterRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// GET /api/books/:id/chapters — 获取指定书籍的章节列表
pub async fn get_chapters(
    State(state): State<Arc<AppState>>,
    Path(book_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookChapterRepository::new(db.connection());
    let chapters = repo.find_by_book_url(&book_url)?;
    Ok(Json(json!({
        "chapters": chapters,
        "total": chapters.len(),
    })))
}

/// GET /api/books/:id/chapters/:index/content — 获取指定章节内容
///
/// 注意：章节正文内容需通过 legado-parser / legado-net 动态抓取，
/// 此处暂返回章节元数据，后续可对接内容解析逻辑。
pub async fn get_chapter_content(
    State(state): State<Arc<AppState>>,
    Path((book_url, index)): Path<(String, i32)>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookChapterRepository::new(db.connection());

    match repo.find_by_book_url_and_index(&book_url, index)? {
        Some(chapter) => Ok(Json(json!({
            "chapter": chapter,
            "content": null,
            "message": "内容解析暂未实现，返回章节元数据"
        }))),
        None => Ok(Json(json!({
            "error": "chapter not found",
            "book_url": book_url,
            "index": index,
        }))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use axum::http::StatusCode;
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;
    use legado_core::models::{Book, BookChapter};
    use legado_db::repository::book_chapter_repository::BookChapterRepository;
    use legado_db::repository::book_repository::BookRepository;
    use legado_db::repository::Repository;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    async fn seed_data(state: &Arc<AppState>) {
        let db = state.db.lock().await;
        let book_repo = BookRepository::new(db.connection());
        let book = Book {
            book_url: "book1".to_string(),
            name: "测试书".to_string(),
            author: "作者".to_string(),
            ..Book::default()
        };
        book_repo.insert(&book).unwrap();

        let ch_repo = BookChapterRepository::new(db.connection());
        ch_repo
            .insert(&BookChapter {
                url: "book1/ch0".to_string(),
                title: "第1章".to_string(),
                book_url: "book1".to_string(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
        ch_repo
            .insert(&BookChapter {
                url: "book1/ch1".to_string(),
                title: "第2章".to_string(),
                book_url: "book1".to_string(),
                index: 1,
                ..BookChapter::default()
            })
            .unwrap();
    }

    #[tokio::test]
    async fn test_get_chapters() {
        let state = make_test_state();
        seed_data(&state).await;
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books/book1/chapters")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_get_chapter_content() {
        let state = make_test_state();
        seed_data(&state).await;
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books/book1/chapters/0/content")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_get_chapter_content_not_found() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books/book1/chapters/99/content")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK); // 返回 200 但包含 error 字段
    }
}
