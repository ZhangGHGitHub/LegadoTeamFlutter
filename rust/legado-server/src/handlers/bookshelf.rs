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
    /// 书籍级阅读记录开关（批35b P2-2）
    ///
    /// 缺键/`null`（`None`）时 PUT 更新保留库内既有值——本接口其余字段
    /// 缺省由 `Book::default()` 补齐，会把已开启的开关打回 `false`；
    /// 显式传 `true`/`false` 才覆盖。同时接受 camelCase 别名（对齐 Book JSON）。
    #[serde(default, alias = "disableReadRecord")]
    pub disable_read_record: Option<bool>,
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
        disable_read_record: req.disable_read_record.unwrap_or(false),
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
    let db = state.db.lock().await;
    let repo = BookRepository::new(db.connection());
    // [批35b P2-2] 先读库再 patch：请求体缺 `disable_read_record` 时保留库内
    // 既有值（整书构造用 `Book::default()` 会把用户已开启的开关覆盖为 false）。
    let existing = repo.find_by_url(&book_url)?;
    let disable_read_record = req
        .disable_read_record
        .or_else(|| existing.as_ref().map(|b| b.disable_read_record))
        .unwrap_or(false);
    let book = Book {
        book_url: req.book_url.clone(),
        name: req.name,
        author: req.author.unwrap_or_default(),
        origin: req.origin.unwrap_or_default(),
        origin_name: req.origin_name.unwrap_or_default(),
        cover_url: req.cover_url,
        intro: req.intro,
        disable_read_record,
        ..Book::default()
    };
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
            injected_paths: Default::default(),
            legacy_review: Default::default(),
            source_check: Default::default(),
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

    /// [批35b P2-2] PUT 请求体缺 `disableReadRecord`：保留库内 true。
    ///
    /// 红→绿：旧实现用 `Book::default()` 补齐（false）后整书 UPDATE，
    /// 一次无关的字段更新就会把用户已开启的书级阅读记录开关打回假。
    #[tokio::test]
    async fn test_update_book_preserves_disable_read_record_when_key_missing() {
        let state = make_test_state();
        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: "merge-url".to_string(),
                name: "开关书".to_string(),
                author: "作者".to_string(),
                disable_read_record: true,
                ..Book::default()
            })
            .unwrap();
        }

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "book_url": "merge-url",
            "name": "改名",
            "author": "作者"
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri("/api/books/merge-url")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            let saved = repo.find_by_url("merge-url").unwrap().unwrap();
            assert_eq!(saved.name, "改名", "其他字段应正常更新");
            assert!(
                saved.disable_read_record,
                "缺键 PUT 不得把库内 true 覆盖为 false"
            );
        }

        // 显式传 false：按入参覆盖（用户主动恢复记录）
        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "book_url": "merge-url",
            "name": "改名",
            "disableReadRecord": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri("/api/books/merge-url")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            let saved = repo.find_by_url("merge-url").unwrap().unwrap();
            assert!(
                !saved.disable_read_record,
                "显式携带的 false 应按入参落库（camelCase 别名亦生效）"
            );
        }
    }
}
