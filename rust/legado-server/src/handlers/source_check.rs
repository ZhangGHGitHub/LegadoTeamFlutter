//! 书源有效性检查处理器
//!
//! 提供以下端点：
//! - POST /api/sources/check       — 检查单个书源有效性
//! - POST /api/sources/check-batch — 批量检查书源（并行）

use std::sync::Arc;

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::task;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::models::BookSource;
use legado_net::source_checker::{CheckResult, CheckerConfig, SourceChecker};
use legado_net::client::{LegadoClient, LegadoClientConfig};

/// 单个书源检查请求
#[derive(Debug, Deserialize)]
pub struct CheckSourceRequest {
    /// 完整书源对象
    pub source: BookSource,
    /// 可选搜索关键词
    pub keyword: Option<String>,
}

/// 批量检查请求
#[derive(Debug, Deserialize)]
pub struct CheckBatchRequest {
    /// 书源列表
    pub sources: Vec<BookSource>,
    /// 可选搜索关键词
    pub keyword: Option<String>,
    /// 最大并发数（默认 5）
    pub concurrency: Option<usize>,
}

/// 批量检查响应
#[derive(Debug, Serialize)]
pub struct CheckBatchResponse {
    pub results: Vec<CheckResult>,
    pub total: usize,
    pub passed: usize,
    pub failed: usize,
}

/// 创建 SourceChecker 实例
fn create_checker(keyword: Option<&str>) -> Result<SourceChecker, ApiError> {
    let client = LegadoClient::new(LegadoClientConfig::default())?;
    let config = CheckerConfig {
        keyword: keyword.unwrap_or("我的").to_string(),
        ..CheckerConfig::default()
    };
    Ok(SourceChecker::with_config(Arc::new(client), config))
}

/// POST /api/sources/check — 检查单个书源有效性
pub async fn check_source(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<CheckSourceRequest>,
) -> Result<Json<Value>, ApiError> {
    let checker = create_checker(req.keyword.as_deref())?;
    let result = checker.check_full(&req.source).await;
    Ok(Json(json!(result)))
}

/// POST /api/sources/check-batch — 批量检查书源（并行）
pub async fn check_batch(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<CheckBatchRequest>,
) -> Result<Json<Value>, ApiError> {
    let keyword = req.keyword.clone();
    let concurrency = req.concurrency.unwrap_or(5).max(1).min(20);

    // 使用信号量控制并发
    let semaphore = Arc::new(tokio::sync::Semaphore::new(concurrency));
    let mut handles = Vec::with_capacity(req.sources.len());

    for source in req.sources {
        let sem = Arc::clone(&semaphore);
        let kw = keyword.clone();
        let handle = task::spawn(async move {
            let _permit = sem.acquire().await;
            let checker = match create_checker(kw.as_deref()) {
                Ok(c) => c,
                Err(_) => {
                    return CheckResult {
                        source_url: source.book_source_url.clone(),
                        search_ok: false,
                        toc_ok: false,
                        content_ok: false,
                        search_error: Some("failed to create checker".to_string()),
                        toc_error: Some("skipped".to_string()),
                        content_error: Some("skipped".to_string()),
                        total_time_ms: 0,
                    };
                }
            };
            checker.check_full(&source).await
        });
        handles.push(handle);
    }

    let mut results = Vec::with_capacity(handles.len());
    for handle in handles {
        match handle.await {
            Ok(result) => results.push(result),
            Err(e) => {
                results.push(CheckResult {
                    source_url: "unknown".to_string(),
                    search_ok: false,
                    toc_ok: false,
                    content_ok: false,
                    search_error: Some(format!("task panicked: {}", e)),
                    toc_error: Some("skipped".to_string()),
                    content_error: Some("skipped".to_string()),
                    total_time_ms: 0,
                });
            }
        }
    }

    let total = results.len();
    let passed = results.iter().filter(|r| r.all_ok()).count();
    let failed = total - passed;

    let resp = CheckBatchResponse {
        results,
        total,
        passed,
        failed,
    };

    Ok(Json(json!(resp)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request, StatusCode};
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
    async fn test_check_source_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": {
                "bookSourceUrl": "https://example.com",
                "bookSourceName": "Test",
                "searchUrl": "https://example.com/search?q={key}"
            }
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/sources/check")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 请求应被接受处理（书源可能失败但端点本身正常）
        assert!(
            resp.status() == StatusCode::OK
                || resp.status() == StatusCode::BAD_GATEWAY
                || resp.status() == StatusCode::GATEWAY_TIMEOUT
        );
    }

    #[tokio::test]
    async fn test_check_batch_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "sources": [
                {
                    "bookSourceUrl": "https://example.com",
                    "bookSourceName": "Test",
                    "searchUrl": "https://example.com/search?q={key}"
                }
            ],
            "concurrency": 2
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/sources/check-batch")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert!(
            resp.status() == StatusCode::OK
                || resp.status() == StatusCode::BAD_GATEWAY
        );
    }

    #[test]
    fn test_create_checker_default() {
        let checker = create_checker(None);
        assert!(checker.is_ok());
    }

    #[test]
    fn test_create_checker_custom_keyword() {
        let checker = create_checker(Some("自定义"));
        assert!(checker.is_ok());
    }
}
