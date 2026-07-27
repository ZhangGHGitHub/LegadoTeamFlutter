//! 书源调试 API 端点
//!
//! 提供以下端点：
//! - POST /api/debug/start          — 启动调试会话
//! - GET  /api/debug/log/:session_id — 获取调试日志
//! - GET  /api/debug/sessions       — 列出所有调试会话
//! - POST /api/debug/step           — 向会话添加调试步骤
//! - POST /api/debug/complete       — 完成调试会话

use std::sync::Arc;

use axum::extract::{Path, State};
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::state::AppState;
use legado_core::debug_session::{DebugStep, DebugStepStatus, DebugStepType, Debugger};

/// 全局调试器实例（通过 OnceLock 延迟初始化）
static DEBUGGER: std::sync::OnceLock<Debugger> = std::sync::OnceLock::new();

/// 获取全局调试器引用
pub fn get_debugger() -> &'static Debugger {
    DEBUGGER.get_or_init(Debugger::new)
}

/// 启动调试请求
#[derive(Debug, Deserialize)]
pub struct StartDebugRequest {
    pub source_url: String,
    pub source_name: String,
    pub search_key: String,
}

/// 调试响应
#[derive(Debug, Serialize)]
pub struct DebugResponse {
    pub session_id: String,
    pub status: String,
}

/// 添加步骤请求
#[derive(Debug, Deserialize)]
pub struct AddStepRequest {
    pub session_id: String,
    pub step_type: String,
    pub input: String,
    pub output: Option<String>,
    pub rule: Option<String>,
    pub duration_ms: Option<u64>,
    pub error: Option<String>,
}

/// 完成会话请求
#[derive(Debug, Deserialize)]
pub struct CompleteSessionRequest {
    pub session_id: String,
    pub status: String,
}

/// POST /api/debug/start — 启动调试会话
pub async fn start_debug(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<StartDebugRequest>,
) -> Json<Value> {
    let debugger = get_debugger();
    let session_id = debugger.create_session(&req.source_url, &req.source_name, &req.search_key);
    Json(json!({
        "session_id": session_id,
        "status": "started",
        "source_url": req.source_url,
        "source_name": req.source_name,
        "search_key": req.search_key,
    }))
}

/// GET /api/debug/log/:session_id — 获取调试日志
pub async fn get_debug_log(
    State(_state): State<Arc<AppState>>,
    Path(session_id): Path<String>,
) -> Json<Value> {
    let debugger = get_debugger();
    let log = debugger.get_log(&session_id);
    let session = debugger.get_session(&session_id);

    match session {
        Some(s) => Json(json!({
            "session_id": session_id,
            "source_name": s.source_name,
            "status": s.status,
            "log": log,
            "steps_count": s.steps.len(),
        })),
        None => Json(json!({
            "session_id": session_id,
            "error": "Session not found",
            "log": log,
        })),
    }
}

/// GET /api/debug/sessions — 列出所有调试会话
pub async fn list_sessions(State(_state): State<Arc<AppState>>) -> Json<Value> {
    let debugger = get_debugger();
    let sessions = debugger.list_sessions();
    let sessions_json: Vec<Value> = sessions
        .iter()
        .map(|s| {
            json!({
                "id": s.id,
                "source_url": s.source_url,
                "source_name": s.source_name,
                "search_key": s.search_key,
                "status": s.status,
                "steps_count": s.steps.len(),
                "started_at": s.started_at,
                "completed_at": s.completed_at,
            })
        })
        .collect();

    Json(json!({
        "sessions": sessions_json,
        "total": sessions_json.len(),
    }))
}

/// POST /api/debug/step — 向会话添加调试步骤
pub async fn add_step(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<AddStepRequest>,
) -> Json<Value> {
    let debugger = get_debugger();

    let step_type = match req.step_type.as_str() {
        "search" => DebugStepType::Search,
        "toc" => DebugStepType::Toc,
        "content" => DebugStepType::Content,
        "js_eval" => DebugStepType::JsEval,
        "http_get" => DebugStepType::HttpGet,
        "http_post" => DebugStepType::HttpPost,
        _ => {
            return Json(json!({
                "error": format!("Unknown step type: {}", req.step_type),
            }));
        }
    };

    let mut step = DebugStep::new(step_type, &req.input);
    if let Some(ref rule) = req.rule {
        step.rule = Some(rule.clone());
    }
    if let Some(ref error) = req.error {
        step.mark_failed(error, req.duration_ms.unwrap_or(0));
    } else if let Some(ref output) = req.output {
        step.mark_success(output, req.duration_ms.unwrap_or(0));
    } else {
        step.status = DebugStepStatus::Running;
    }

    debugger.add_step(&req.session_id, step);

    Json(json!({
        "session_id": req.session_id,
        "status": "step_added",
    }))
}

/// POST /api/debug/complete — 完成调试会话
pub async fn complete_session(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<CompleteSessionRequest>,
) -> Json<Value> {
    let debugger = get_debugger();
    debugger.complete_session(&req.session_id, &req.status);

    Json(json!({
        "session_id": req.session_id,
        "status": req.status,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request, StatusCode};
    use axum::routing::{get, post};
    use axum::Router;
    use tower::ServiceExt;

    use crate::state::AppState;
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

    /// 创建测试路由（包含 debug 端点）
    fn debug_test_router(state: Arc<AppState>) -> Router {
        Router::new()
            .route("/api/debug/start", post(start_debug))
            .route("/api/debug/log/{session_id}", get(get_debug_log))
            .route("/api/debug/sessions", get(list_sessions))
            .route("/api/debug/step", post(add_step))
            .route("/api/debug/complete", post(complete_session))
            .with_state(state)
    }

    #[tokio::test]
    async fn test_start_debug_endpoint() {
        let state = make_test_state();
        let app = debug_test_router(state);

        let body = serde_json::to_string(&json!({
            "source_url": "https://example.com",
            "source_name": "TestSource",
            "search_key": "斗破苍穹"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/start")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(result["status"], "started");
        assert!(result["session_id"].as_str().unwrap().starts_with("debug_"));
    }

    #[tokio::test]
    async fn test_list_sessions_endpoint() {
        let state = make_test_state();
        let app = debug_test_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/debug/sessions")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert!(result["sessions"].is_array());
        assert!(result["total"].is_number());
    }

    #[tokio::test]
    async fn test_get_debug_log_not_found() {
        let state = make_test_state();
        let app = debug_test_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri("/api/debug/log/nonexistent_session")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(result["error"], "Session not found");
    }

    #[tokio::test]
    async fn test_add_step_endpoint() {
        let state = make_test_state();
        let app = debug_test_router(state);

        // First create a session
        let session_id = get_debugger().create_session("https://t.com", "T", "k");

        let body = serde_json::to_string(&json!({
            "session_id": session_id,
            "step_type": "search",
            "input": "https://t.com/search?q=k",
            "output": "<html>found</html>",
            "rule": "css:.result",
            "duration_ms": 120
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/step")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(result["status"], "step_added");
    }

    #[tokio::test]
    async fn test_add_step_invalid_type() {
        let state = make_test_state();
        let app = debug_test_router(state);

        let body = serde_json::to_string(&json!({
            "session_id": "some_id",
            "step_type": "invalid_type",
            "input": "data"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/step")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert!(result["error"]
            .as_str()
            .unwrap()
            .contains("Unknown step type"));
    }

    #[tokio::test]
    async fn test_complete_session_endpoint() {
        let state = make_test_state();
        let app = debug_test_router(state);

        let session_id = get_debugger().create_session("https://c.com", "C", "kw");

        let body = serde_json::to_string(&json!({
            "session_id": session_id,
            "status": "completed"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/complete")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(result["status"], "completed");

        // Verify session is actually completed
        let session = get_debugger().get_session(&session_id).unwrap();
        assert_eq!(session.status, "completed");
    }

    #[tokio::test]
    async fn test_full_debug_workflow() {
        let state = make_test_state();
        let app = debug_test_router(state.clone());

        // 1. Start session
        let body = serde_json::to_string(&json!({
            "source_url": "https://book.com",
            "source_name": "BookSrc",
            "search_key": "测试"
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/start")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        let session_id = result["session_id"].as_str().unwrap().to_string();

        // 2. Add a step
        let step_body = serde_json::to_string(&json!({
            "session_id": session_id,
            "step_type": "http_get",
            "input": "https://book.com/search?q=测试",
            "output": "200 OK",
            "duration_ms": 80
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/step")
                    .header("Content-Type", "application/json")
                    .body(Body::from(step_body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        // 3. Get log
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::GET)
                    .uri(format!("/api/debug/log/{}", session_id))
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let body_bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&body_bytes).unwrap();
        assert_eq!(result["steps_count"], 1);
        assert!(result["log"].as_str().unwrap().contains("BookSrc"));

        // 4. Complete session
        let complete_body = serde_json::to_string(&json!({
            "session_id": session_id,
            "status": "completed"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/debug/complete")
                    .header("Content-Type", "application/json")
                    .body(Body::from(complete_body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }
}
