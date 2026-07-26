//! 离线缓存 API 处理器

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::cache_book::CachedChapter;
use legado_db::repository::cache_book_repository::CacheBookRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// 缓存章节请求体
#[derive(Debug, Deserialize)]
pub struct CacheChapterRequest {
    pub book_url: String,
    pub chapter_index: i32,
    pub chapter_title: String,
    pub chapter_url: String,
    pub content: String,
}

/// POST /api/cache/chapters — 缓存章节（支持批量）
pub async fn cache_chapters(
    State(state): State<Arc<AppState>>,
    Json(req): Json<Value>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let db = state.db.lock().await;
    let repo = CacheBookRepository::new(db.connection());

    // 支持单个对象或数组
    let chapters: Vec<CacheChapterRequest> = if let Some(arr) = req.as_array() {
        arr.iter()
            .filter_map(|v| serde_json::from_value(v.clone()).ok())
            .collect()
    } else {
        match serde_json::from_value::<CacheChapterRequest>(req) {
            Ok(single) => vec![single],
            Err(_) => vec![],
        }
    };

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let mut cached_count = 0;
    for ch_req in &chapters {
        let chapter = CachedChapter {
            id: 0,
            book_url: ch_req.book_url.clone(),
            chapter_index: ch_req.chapter_index,
            chapter_title: ch_req.chapter_title.clone(),
            chapter_url: ch_req.chapter_url.clone(),
            content: ch_req.content.clone(),
            cached_at: now,
            size_bytes: ch_req.content.len() as i64,
        };
        repo.insert(&chapter)?;
        cached_count += 1;
    }

    Ok((
        StatusCode::CREATED,
        Json(json!({ "cached": cached_count })),
    ))
}

/// GET /api/cache/stats — 缓存统计
pub async fn cache_stats(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = CacheBookRepository::new(db.connection());
    let stats = repo.get_stats()?;
    Ok(Json(json!(stats)))
}

/// DELETE /api/cache/book/:book_url — 清理某书缓存
pub async fn delete_book_cache(
    State(state): State<Arc<AppState>>,
    Path(book_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = CacheBookRepository::new(db.connection());
    let deleted = repo.delete_by_book(&book_url)?;
    Ok(Json(json!({ "deleted": deleted, "book_url": book_url })))
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
    async fn test_cache_stats_empty() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/cache/stats")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_cache_chapters_and_stats() {
        let state = make_test_state();
        let app = create_router(state);

        // 缓存一个章节
        let body = serde_json::to_string(&json!({
            "book_url": "book1",
            "chapter_index": 0,
            "chapter_title": "Chapter 1",
            "chapter_url": "http://ex.com/ch1",
            "content": "Hello world"
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/cache/chapters")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);

        // 查看统计
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/cache/stats")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_delete_book_cache() {
        let state = make_test_state();

        // 先插入缓存
        {
            let db = state.db.lock().await;
            let repo = CacheBookRepository::new(db.connection());
            let ch = CachedChapter {
                id: 0,
                book_url: "book1".to_string(),
                chapter_index: 0,
                chapter_title: "Ch1".to_string(),
                chapter_url: "http://ex.com/ch1".to_string(),
                content: "content".to_string(),
                cached_at: 1000,
                size_bytes: 7,
            };
            repo.insert(&ch).unwrap();
        }

        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/cache/book/book1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }
}
