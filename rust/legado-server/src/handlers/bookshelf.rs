//! 书架管理处理器

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::models::Book;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::Repository;

use crate::error::ApiError;
use crate::state::AppState;

/// 创建书籍请求体
#[derive(Debug, Deserialize)]
pub struct CreateBookRequest {
    pub book_url: String,
    pub name: String,
    pub author: Option<String>,
    pub origin: Option<String>,
    pub origin_name: Option<String>,
    pub cover_url: Option<String>,
    pub intro: Option<String>,
}

/// GET /api/books — 获取书架全部书籍
pub async fn list_books(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    let books = repo.find_all()?;
    Ok(Json(json!({ "books": books, "total": books.len() })))
}

/// GET /api/books/:id — 获取单本书籍详情（id 为 bookUrl）
pub async fn get_book(
    State(state): State<Arc<AppState>>,
    Path(book_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    match repo.find_by_url(&book_url)? {
        Some(book) => Ok(Json(json!(book))),
        None => Ok(Json(json!({ "error": "book not found" }))),
    }
}

/// POST /api/books — 添加书籍到书架
pub async fn create_book(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateBookRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let book = Book {
        book_url: req.book_url,
        name: req.name,
        author: req.author.unwrap_or_default(),
        origin: req.origin.unwrap_or_default(),
        origin_name: req.origin_name.unwrap_or_default(),
        cover_url: req.cover_url,
        intro: req.intro,
        ..Book::default()
    };

    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    repo.insert(&book)?;

    Ok((StatusCode::CREATED, Json(json!(book))))
}

/// PUT /api/books/:id — 更新书籍信息
pub async fn update_book(
    State(state): State<Arc<AppState>>,
    Path(book_url): Path<String>,
    Json(req): Json<CreateBookRequest>,
) -> Result<Json<Value>, ApiError> {
    let book = Book {
        book_url: req.book_url.clone(),
        name: req.name,
        author: req.author.unwrap_or_default(),
        origin: req.origin.unwrap_or_default(),
        origin_name: req.origin_name.unwrap_or_default(),
        cover_url: req.cover_url,
        intro: req.intro,
        ..Book::default()
    };

    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    // 先检查是否存在
    let _existing = repo.find_by_url(&book_url)?;
    repo.update(&book)?;

    Ok(Json(json!(book)))
}

/// DELETE /api/books/:id — 从书架删除书籍
pub async fn delete_book(
    State(state): State<Arc<AppState>>,
    Path(book_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    repo.delete(&book_url)?;
    Ok(Json(json!({ "deleted": true, "book_url": book_url })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;
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

    #[tokio::test]
    async fn test_list_books_empty() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_and_get_book() {
        let state = make_test_state();
        let app = create_router(state.clone());

        // 创建书籍
        let create_body = serde_json::to_string(&json!({
            "book_url": "https://example.com/book1",
            "name": "测试书籍",
            "author": "测试作者"
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/books")
                    .header("Content-Type", "application/json")
                    .body(Body::from(create_body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);

        // 查询书籍
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books/https%3A%2F%2Fexample.com%2Fbook1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_delete_book() {
        let state = make_test_state();

        // 先插入一本书
        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            let book = Book {
                book_url: "url1".to_string(),
                name: "test".to_string(),
                author: "author".to_string(),
                ..Book::default()
            };
            repo.insert(&book).unwrap();
        }

        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/books/url1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }
}
