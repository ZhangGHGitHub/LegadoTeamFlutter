//! 下载管理 API 处理器

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::download_manager::{DownloadStatus, DownloadTask};

use crate::error::ApiError;
use crate::state::AppState;

/// 添加下载任务请求体
#[derive(Debug, Deserialize)]
pub struct AddDownloadRequest {
    pub book_url: String,
    pub chapter_url: String,
    pub chapter_title: String,
    pub chapter_index: i32,
    #[serde(default)]
    pub priority: i32,
}

/// POST /api/download/add — 添加下载任务
pub async fn add_download(
    State(state): State<Arc<AppState>>,
    Json(req): Json<AddDownloadRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let mut mgr = state.download_manager.lock().await;

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;

    let task_id = format!("dl_{}_{}", req.chapter_index, now);
    let task = DownloadTask {
        id: task_id.clone(),
        book_url: req.book_url,
        chapter_url: req.chapter_url,
        chapter_title: req.chapter_title,
        chapter_index: req.chapter_index,
        status: DownloadStatus::Pending,
        progress: 0.0,
        priority: req.priority,
        created_at: now,
        completed_at: None,
        error: None,
        fail_count: 0,
        last_retry_at: None,
        next_retry_at: None,
        downloaded_bytes: 0,
        max_retry_count: 3,
    };

    mgr.add_task(task);

    Ok((
        StatusCode::CREATED,
        Json(json!({ "task_id": task_id, "status": "pending" })),
    ))
}

/// POST /api/download/pause — 暂停所有下载
pub async fn pause_downloads(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let mut mgr = state.download_manager.lock().await;
    mgr.pause_all();
    Ok(Json(json!({ "paused": true })))
}

/// POST /api/download/resume — 恢复所有下载
pub async fn resume_downloads(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let mut mgr = state.download_manager.lock().await;
    mgr.resume_all();
    Ok(Json(json!({ "paused": false })))
}

/// GET /api/download/status — 查询下载状态
pub async fn download_status(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let mgr = state.download_manager.lock().await;
    let stats = mgr.stats();
    Ok(Json(json!({
        "total": stats.total,
        "pending": stats.pending,
        "downloading": stats.downloading,
        "completed": stats.completed,
        "failed": stats.failed,
        "paused": stats.paused,
    })))
}

/// DELETE /api/download/:id — 移除下载任务
pub async fn remove_download(
    State(state): State<Arc<AppState>>,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let mut mgr = state.download_manager.lock().await;
    let existed = mgr.get_task(&id).is_some();
    mgr.remove_task(&id);
    Ok(Json(json!({ "removed": existed, "task_id": id })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use tower::ServiceExt;

    use crate::routes::create_router;
    use legado_core::download_manager::DownloadManager;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: Mutex::new(DownloadManager::new(3)),
        })
    }

    #[tokio::test]
    async fn test_download_status_empty() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/download/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["total"], 0);
        assert_eq!(json["paused"], false);
    }

    #[tokio::test]
    async fn test_add_download() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "book_url": "http://example.com/book1",
            "chapter_url": "http://example.com/ch1",
            "chapter_title": "Chapter 1",
            "chapter_index": 0
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/download/add")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["status"], "pending");
        assert!(json["task_id"].as_str().unwrap().starts_with("dl_"));
    }

    #[tokio::test]
    async fn test_pause_and_resume() {
        let state = make_test_state();
        let app = create_router(state);

        // Pause
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/download/pause")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["paused"], true);

        // Check status shows paused
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/api/download/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["paused"], true);

        // Resume
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/download/resume")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["paused"], false);
    }

    #[tokio::test]
    async fn test_remove_download() {
        let state = make_test_state();

        // Add a task first
        {
            let mut mgr = state.download_manager.lock().await;
            let task = DownloadTask {
                id: "test_task_1".to_string(),
                book_url: "book1".to_string(),
                chapter_url: "http://ex.com/ch1".to_string(),
                chapter_title: "Ch1".to_string(),
                chapter_index: 0,
                status: DownloadStatus::Pending,
                progress: 0.0,
                priority: 0,
                created_at: 1000,
                completed_at: None,
                error: None,
                fail_count: 0,
                last_retry_at: None,
                next_retry_at: None,
                downloaded_bytes: 0,
                max_retry_count: 3,
            };
            mgr.add_task(task);
        }

        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/download/test_task_1")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["removed"], true);
        assert_eq!(json["task_id"], "test_task_1");
    }

    #[tokio::test]
    async fn test_remove_nonexistent_download() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/download/nonexistent")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["removed"], false);
    }

    #[tokio::test]
    async fn test_add_and_check_status() {
        let state = make_test_state();
        let app = create_router(state);

        // Add two tasks
        for i in 0..2 {
            let body = serde_json::to_string(&json!({
                "book_url": "http://example.com/book1",
                "chapter_url": format!("http://example.com/ch{}", i),
                "chapter_title": format!("Chapter {}", i),
                "chapter_index": i
            }))
            .unwrap();

            let resp = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method(Method::POST)
                        .uri("/api/download/add")
                        .header("Content-Type", "application/json")
                        .body(Body::from(body))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::CREATED);
        }

        // Check status
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/download/status")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["total"], 2);
        assert_eq!(json["pending"], 2);
    }
}
