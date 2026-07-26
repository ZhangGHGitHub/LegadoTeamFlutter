//! 书源管理处理器

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::models::BookSource;
use legado_db::repository::book_source_repository::BookSourceRepository;
use legado_db::repository::Repository;

use crate::error::ApiError;
use crate::state::AppState;

/// 创建/更新书源请求体
#[derive(Debug, Deserialize)]
pub struct CreateSourceRequest {
    pub book_source_url: String,
    pub book_source_name: String,
    pub book_source_group: Option<String>,
    pub book_source_type: Option<i32>,
    pub enabled: Option<bool>,
    pub search_url: Option<String>,
}

/// GET /api/sources — 获取全部书源
pub async fn list_sources(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookSourceRepository::new(db.connection());
    let sources = repo.find_all()?;
    Ok(Json(json!({ "sources": sources, "total": sources.len() })))
}

/// POST /api/sources — 创建书源
pub async fn create_source(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CreateSourceRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let source = BookSource {
        book_source_url: req.book_source_url,
        book_source_name: req.book_source_name,
        book_source_group: req.book_source_group,
        book_source_type: req.book_source_type.unwrap_or(0),
        enabled: req.enabled.unwrap_or(true),
        search_url: req.search_url,
        ..BookSource::default()
    };

    let db = state.db.lock().await;
    let repo = BookSourceRepository::new(db.connection());
    repo.insert(&source)?;

    Ok((StatusCode::CREATED, Json(json!(source))))
}

/// PUT /api/sources/:id — 更新书源
pub async fn update_source(
    State(state): State<Arc<AppState>>,
    Path(source_url): Path<String>,
    Json(req): Json<CreateSourceRequest>,
) -> Result<Json<Value>, ApiError> {
    let source = BookSource {
        book_source_url: req.book_source_url,
        book_source_name: req.book_source_name,
        book_source_group: req.book_source_group,
        book_source_type: req.book_source_type.unwrap_or(0),
        enabled: req.enabled.unwrap_or(true),
        search_url: req.search_url,
        ..BookSource::default()
    };

    let db = state.db.lock().await;
    let repo = BookSourceRepository::new(db.connection());
    let _existing = repo.find_by_url(&source_url)?;
    repo.update(&source)?;

    Ok(Json(json!(source)))
}

/// DELETE /api/sources/:id — 删除书源
pub async fn delete_source(
    State(state): State<Arc<AppState>>,
    Path(source_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookSourceRepository::new(db.connection());
    repo.delete(&source_url)?;
    Ok(Json(json!({ "deleted": true, "source_url": source_url })))
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
        })
    }

    #[tokio::test]
    async fn test_list_sources_empty() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/sources")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_create_source() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "book_source_url": "https://source.example.com",
            "book_source_name": "测试书源",
            "enabled": true
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/sources")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
    }

    #[tokio::test]
    async fn test_delete_source() {
        let state = make_test_state();

        // 先插入一个书源
        {
            let db = state.db.lock().await;
            let repo = BookSourceRepository::new(db.connection());
            let src = BookSource {
                book_source_url: "src1".to_string(),
                book_source_name: "test".to_string(),
                ..BookSource::default()
            };
            repo.insert(&src).unwrap();
        }

        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/sources/src1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }
}
