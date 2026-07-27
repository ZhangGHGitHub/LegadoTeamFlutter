//! 书架目录批量更新处理器
//!
//! 提供 REST 端点：
//! - POST /api/bookshelf/update-toc — 批量更新目录
//! - GET  /api/bookshelf/update-toc/progress — 获取更新进度
//! - POST /api/bookshelf/update-toc/stop — 停止更新
//!
//! 使用模块级全局 TocUpdater，无需修改 AppState。

use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::LazyLock;
use tokio::sync::Mutex;

use legado_core::toc_updater::{TocUpdateRequest, TocUpdater};

use crate::error::ApiError;

/// 全局目录更新调度器实例
static TOC_UPDATER: LazyLock<Mutex<TocUpdater>> = LazyLock::new(|| Mutex::new(TocUpdater::new(4)));

/// 批量更新请求体
#[derive(Debug, Deserialize)]
pub struct BatchTocUpdateBody {
    pub books: Vec<BookTocEntry>,
    /// 最大并发数，默认 4
    #[serde(default = "default_concurrent")]
    pub max_concurrent: usize,
}

fn default_concurrent() -> usize {
    4
}

#[derive(Debug, Deserialize)]
pub struct BookTocEntry {
    pub book_url: String,
    pub book_name: String,
    pub source_url: String,
    #[serde(default)]
    pub priority: i32,
}

/// POST /api/bookshelf/update-toc — 批量更新目录
pub async fn start_toc_update(
    Json(body): Json<BatchTocUpdateBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let mut updater = TOC_UPDATER.lock().await;

    if updater.get_progress().is_running {
        return Ok((
            StatusCode::CONFLICT,
            Json(json!({ "error": "batch update already running" })),
        ));
    }

    let requests: Vec<TocUpdateRequest> = body
        .books
        .into_iter()
        .map(|b| TocUpdateRequest {
            book_url: b.book_url,
            book_name: b.book_name,
            source_url: b.source_url,
            priority: b.priority,
        })
        .collect();

    let total = requests.len();
    let max_concurrent = body.max_concurrent;
    *updater = TocUpdater::new(max_concurrent);
    updater.start_batch(requests);

    Ok((
        StatusCode::OK,
        Json(json!({
            "started": true,
            "total": total,
            "max_concurrent": max_concurrent,
        })),
    ))
}

/// GET /api/bookshelf/update-toc/progress — 获取更新进度
pub async fn get_toc_update_progress() -> Result<Json<Value>, ApiError> {
    let updater = TOC_UPDATER.lock().await;
    let progress = updater.get_progress();
    Ok(Json(json!(progress)))
}

/// POST /api/bookshelf/update-toc/stop — 停止更新
pub async fn stop_toc_update() -> Result<Json<Value>, ApiError> {
    let updater = TOC_UPDATER.lock().await;
    let was_running = updater.get_progress().is_running;
    updater.finish_batch();
    Ok(Json(json!({
        "stopped": was_running,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use axum::routing::{get, post};
    use axum::Router;
    use tower::ServiceExt;

    /// 序列化测试，避免全局静态竞争
    static TEST_LOCK: std::sync::LazyLock<tokio::sync::Mutex<()>> =
        std::sync::LazyLock::new(|| tokio::sync::Mutex::new(()));

    fn test_router() -> Router {
        Router::new()
            .route("/api/bookshelf/update-toc", post(start_toc_update))
            .route(
                "/api/bookshelf/update-toc/progress",
                get(get_toc_update_progress),
            )
            .route("/api/bookshelf/update-toc/stop", post(stop_toc_update))
    }

    #[tokio::test]
    async fn test_start_toc_update() {
        let _guard = TEST_LOCK.lock().await;
        // 确保全局状态干净
        {
            let updater = TOC_UPDATER.lock().await;
            updater.reset();
        }

        let app = test_router();

        let body = serde_json::to_string(&json!({
            "books": [
                { "book_url": "url1", "book_name": "Book1", "source_url": "src1" },
                { "book_url": "url2", "book_name": "Book2", "source_url": "src2", "priority": 1 }
            ],
            "max_concurrent": 2
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json: Value = serde_json::from_slice(
            &axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(json["started"], true);
        assert_eq!(json["total"], 2);
    }

    #[tokio::test]
    async fn test_get_progress() {
        let _guard = TEST_LOCK.lock().await;
        // 确保全局状态干净
        {
            let updater = TOC_UPDATER.lock().await;
            updater.reset();
        }

        let app = test_router();

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/bookshelf/update-toc/progress")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json: Value = serde_json::from_slice(
            &axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(json["is_running"], false);
        assert_eq!(json["total"], 0);
    }

    #[tokio::test]
    async fn test_stop_update() {
        let _guard = TEST_LOCK.lock().await;
        let app = test_router();

        // 先通过 HTTP 启动一批更新
        let start_body = serde_json::to_string(&json!({
            "books": [
                { "book_url": "url1", "book_name": "Book1", "source_url": "src1" }
            ]
        }))
        .unwrap();

        let _ = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc")
                    .header("Content-Type", "application/json")
                    .body(Body::from(start_body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 然后停止
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc/stop")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json: Value = serde_json::from_slice(
            &axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap();
        assert_eq!(json["stopped"], true);
    }
}
