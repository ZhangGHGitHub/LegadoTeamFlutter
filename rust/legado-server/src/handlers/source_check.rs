//! 书源有效性检查处理器
//!
//! 提供以下端点：
//! - POST /api/sources/check       — 检查单个书源有效性
//! - POST /api/sources/check-batch — 批量检查书源（并行）
//!
//! 令牌面（审查批 P2）：两条均以「方法 + 路径」形式登记在
//! `legacy::source_write_api::PROTECTED_SOURCE_WRITE_ROUTES`，生产入口
//! （`server::attach_source_write_token_guard`）在 body 提取前校验
//! `x-legado-token`。请求体可携带任意 `BookSource`，`searchUrl` 会被直接
//! 出站请求；`check-batch` 并发上限 20。
//!
//! 已登记的残余（本批未改，避免范围膨胀）：`searchUrl`/`bookSourceUrl`
//! **没有**内网/保留地址校验，也不限制重定向跳数目标——持有令牌的调用方
//! 仍可把设备当作 SSRF 探针。后续批次建议复用
//! `handlers::source_update::{validate_repo_url, is_disallowed_ip}` 的字面量
//! 校验（含逐跳重定向）并补 DNS 解析级校验。

use std::sync::Arc;

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::task;

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::models::BookSource;
use legado_net::client::{LegadoClient, LegadoClientConfig};
use legado_net::source_checker::{CheckResult, CheckerConfig, SourceChecker};

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
///
/// 性能审查 P3-7 的结论：**有意保持逐源客户端**，不复用 FFI 侧
/// `legado_js::host_api::network` 的共享客户端池。依据：
/// 1. 共享池的配置（`PoolKind::Default`）与这里的
///    `LegadoClientConfig::default()` 逐项相同，差异只在**生命周期与
///    CookieStore 归属**——共享池是进程级单例，App 级 `CookieStore` 跨源共享；
/// 2. 我方 `LegadoClient` 的读侧 Cookie 注入是**无条件**的
///    （`apply_headers_and_cookies` 总会按域拼出 `Cookie` 头），写侧才受
///    `enabled_cookie_jar` 门控。共享客户端会让书源 A 的会话 Cookie 串到
///    同域的书源 B（上游 OkHttp 拦截器是读写都按 `CookieJar` 标记门控，
///    故上游共享客户端不构成同等风险），批量校验结果会随处理顺序/并发度
///    变化，失去确定性；
/// 3. 逐源客户端把 Cookie 生命周期限制在单次校验的 search/toc/content 三步
///    内，语义更贴切。并发上限 20 个连接池的成本低于跨源凭据串用与结果
///    不确定性的风险。
///
/// 若后续为 `LegadoClient` 提供「复用连接池但隔离 CookieStore」的构造入口，
/// 或把读侧 Cookie 注入改为按 `enabled_cookie_jar` 门控，可重新评估共享。
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
    let concurrency = req.concurrency.unwrap_or(5).clamp(1, 20);

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
                        captcha: None,
                        redirect: None,
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
                    captcha: None,
                    redirect: None,
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
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
            injected_paths: Default::default(),
            legacy_review: Default::default(),
            source_check: Default::default(),
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

        assert!(resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY);
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
