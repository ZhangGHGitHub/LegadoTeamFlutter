//! 段评/本章热评 API 处理器

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::review::ChapterReview;
use legado_db::repository::review_repository::ReviewRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// 添加评论请求体
#[derive(Debug, Deserialize)]
pub struct CreateReviewRequest {
    pub book_url: String,
    pub chapter_index: i32,
    pub paragraph_index: Option<i32>, // 默认 -1（本章热评）
    pub content: String,
    pub author: Option<String>,
}

/// GET /api/reviews/:book_url/:chapter — 获取章节评论
pub async fn get_reviews(
    State(state): State<Arc<AppState>>,
    Path((book_url, chapter)): Path<(String, i32)>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = ReviewRepository::new(db.connection());
    let reviews = repo.get_by_chapter(&book_url, chapter)?;
    Ok(Json(json!({ "reviews": reviews, "total": reviews.len() })))
}

/// POST /api/reviews — 添加评论
pub async fn create_review(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateReviewRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let review = ChapterReview {
        id: 0,
        book_url: req.book_url,
        chapter_index: req.chapter_index,
        paragraph_index: req.paragraph_index.unwrap_or(-1),
        content: req.content,
        author: req.author.unwrap_or_default(),
        created_at: now,
        like_count: 0,
    };

    let db = state.db.lock().await;
    let repo = ReviewRepository::new(db.connection());
    let id = repo.insert(&review)?;

    Ok((
        StatusCode::CREATED,
        Json(json!({ "id": id, "review": review })),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use tower::ServiceExt;

    use crate::routes::create_router;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }

    #[tokio::test]
    async fn test_get_reviews_empty() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/reviews/book1/0")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_and_get_review() {
        let state = make_test_state();
        let app = create_router(state);

        // 创建评论
        let body = serde_json::to_string(&json!({
            "book_url": "book1",
            "chapter_index": 0,
            "paragraph_index": -1,
            "content": "Great chapter!",
            "author": "reader1"
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/reviews")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);

        // 获取评论
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/reviews/book1/0")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_paragraph_review() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "book_url": "book1",
            "chapter_index": 2,
            "paragraph_index": 5,
            "content": "This paragraph is interesting",
            "author": "reader2"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/reviews")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
    }
}
