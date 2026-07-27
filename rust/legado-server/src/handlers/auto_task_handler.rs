//! 自动任务 REST 处理器
//!
//! 提供端点：
//! - GET    /api/auto-tasks          — 列表
//! - POST   /api/auto-tasks          — 创建
//! - PUT    /api/auto-tasks/:id      — 更新
//! - DELETE /api/auto-tasks/:id      — 删除
//! - POST   /api/auto-tasks/:id/run  — 立即执行
//! - POST   /api/auto-tasks/import   — 导入
//! - GET    /api/auto-tasks/export   — 导出

use axum::extract::Path;
use axum::http::StatusCode;
use axum::Json;
use serde_json::{json, Value};
use std::sync::LazyLock;
use tokio::sync::Mutex;

use legado_core::auto_task::{AutoTaskExporter, AutoTaskRunner, TaskProtocol};
use legado_core::models::AutoTaskRule;

use crate::error::ApiError;

/// 内存存储（简化实现，生产环境应使用 legado-db）
static TASK_STORE: LazyLock<Mutex<Vec<AutoTaskRule>>> = LazyLock::new(|| Mutex::new(Vec::new()));

/// GET /api/auto-tasks — 获取所有自动任务
pub async fn list_tasks() -> Result<Json<Value>, ApiError> {
    let store = TASK_STORE.lock().await;
    let tasks: Vec<Value> = store
        .iter()
        .map(|t| serde_json::to_value(t).unwrap_or_default())
        .collect();
    Ok(Json(json!({ "tasks": tasks, "total": tasks.len() })))
}

/// POST /api/auto-tasks — 创建自动任务
pub async fn create_task(Json(body): Json<Value>) -> Result<(StatusCode, Json<Value>), ApiError> {
    let mut store = TASK_STORE.lock().await;

    let mut rule: AutoTaskRule = serde_json::from_value(body.clone()).map_err(|e| {
        ApiError(legado_core::LegadoError::Parser(format!(
            "Invalid task body: {e}"
        )))
    })?;

    // 如果未提供 id，生成一个
    if rule.id.is_empty() {
        rule.id = format!("task-{}", store.len() + 1);
    }

    // 检查 id 唯一性
    if store.iter().any(|t| t.id == rule.id) {
        return Ok((
            StatusCode::CONFLICT,
            Json(json!({ "error": format!("Task with id '{}' already exists", rule.id) })),
        ));
    }

    let id = rule.id.clone();
    store.push(rule);

    Ok((
        StatusCode::CREATED,
        Json(json!({ "created": true, "id": id })),
    ))
}

/// PUT /api/auto-tasks/:id — 更新自动任务
pub async fn update_task(
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let mut store = TASK_STORE.lock().await;

    let existing = store.iter_mut().find(|t| t.id == id);
    match existing {
        Some(task) => {
            // 合并更新字段
            if let Some(name) = body.get("name").and_then(|v| v.as_str()) {
                task.name = name.to_string();
            }
            if let Some(enable) = body.get("enable").and_then(|v| v.as_bool()) {
                task.enable = enable;
            }
            if let Some(cron) = body.get("cron").and_then(|v| v.as_str()) {
                task.cron = Some(cron.to_string());
            }
            if let Some(script) = body.get("script").and_then(|v| v.as_str()) {
                task.script = script.to_string();
            }
            if let Some(comment) = body.get("comment").and_then(|v| v.as_str()) {
                task.comment = Some(comment.to_string());
            }
            Ok((StatusCode::OK, Json(json!({ "updated": true, "id": id }))))
        }
        None => Ok((
            StatusCode::NOT_FOUND,
            Json(json!({ "error": format!("Task '{}' not found", id) })),
        )),
    }
}

/// DELETE /api/auto-tasks/:id — 删除自动任务
pub async fn delete_task(Path(id): Path<String>) -> Result<(StatusCode, Json<Value>), ApiError> {
    let mut store = TASK_STORE.lock().await;
    let len_before = store.len();
    store.retain(|t| t.id != id);

    if store.len() < len_before {
        Ok((StatusCode::OK, Json(json!({ "deleted": true, "id": id }))))
    } else {
        Ok((
            StatusCode::NOT_FOUND,
            Json(json!({ "error": format!("Task '{}' not found", id) })),
        ))
    }
}

/// POST /api/auto-tasks/:id/run — 立即执行任务
pub async fn run_task(Path(id): Path<String>) -> Result<(StatusCode, Json<Value>), ApiError> {
    let mut store = TASK_STORE.lock().await;

    let task = store.iter_mut().find(|t| t.id == id);
    match task {
        Some(task) => {
            if task.script.trim().is_empty() {
                return Ok((
                    StatusCode::BAD_REQUEST,
                    Json(json!({ "error": "Task script is empty" })),
                ));
            }

            // 构建协议并执行
            let protocol = TaskProtocol::custom(&task.script);
            let result = AutoTaskRunner::execute_with_id(&protocol, &task.id);

            // 更新运行状态
            let now_ms = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;
            task.last_run_at = now_ms;
            if result.success {
                task.last_result = Some(result.message.clone());
                task.last_error = None;
            } else {
                task.last_error = Some(result.message.clone());
            }

            Ok((
                StatusCode::OK,
                Json(json!({
                    "task_id": result.task_id,
                    "success": result.success,
                    "message": result.message,
                    "duration_ms": result.duration_ms,
                })),
            ))
        }
        None => Ok((
            StatusCode::NOT_FOUND,
            Json(json!({ "error": format!("Task '{}' not found", id) })),
        )),
    }
}

/// POST /api/auto-tasks/import — 导入任务
pub async fn import_tasks(Json(body): Json<Value>) -> Result<(StatusCode, Json<Value>), ApiError> {
    let json_str = if let Some(s) = body.as_str() {
        s.to_string()
    } else {
        serde_json::to_string(&body).unwrap_or_default()
    };

    match AutoTaskExporter::import_json(&json_str) {
        Ok(imported) => {
            let mut store = TASK_STORE.lock().await;
            let mut count = 0;
            for val in &imported {
                if let Ok(mut rule) = serde_json::from_value::<AutoTaskRule>(val.clone()) {
                    if rule.id.is_empty() {
                        rule.id = format!("imported-{}", store.len() + 1);
                    }
                    // 覆盖同 id 任务
                    store.retain(|t| t.id != rule.id);
                    store.push(rule);
                    count += 1;
                }
            }
            Ok((StatusCode::OK, Json(json!({ "imported": count }))))
        }
        Err(e) => Ok((StatusCode::BAD_REQUEST, Json(json!({ "error": e })))),
    }
}

/// GET /api/auto-tasks/export — 导出任务
pub async fn export_tasks() -> Result<Json<Value>, ApiError> {
    let store = TASK_STORE.lock().await;
    let tasks: Vec<Value> = store
        .iter()
        .map(|t| serde_json::to_value(t).unwrap_or_default())
        .collect();
    let exported = AutoTaskExporter::export_json(&tasks);
    let parsed: Value = serde_json::from_str(&exported).unwrap_or(json!([]));
    Ok(Json(json!({ "tasks": parsed, "total": store.len() })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use axum::routing::{get, post, put};
    use axum::Router;
    use tower::ServiceExt;

    /// 序列化测试避免全局状态竞争
    static TEST_LOCK: std::sync::LazyLock<tokio::sync::Mutex<()>> =
        std::sync::LazyLock::new(|| tokio::sync::Mutex::new(()));

    fn test_router() -> Router {
        Router::new()
            .route("/api/auto-tasks", get(list_tasks).post(create_task))
            .route("/api/auto-tasks/{id}", put(update_task).delete(delete_task))
            .route("/api/auto-tasks/{id}/run", post(run_task))
            .route("/api/auto-tasks/import", post(import_tasks))
            .route("/api/auto-tasks/export", get(export_tasks))
    }

    async fn clear_store() {
        let mut store = TASK_STORE.lock().await;
        store.clear();
    }

    async fn body_json(resp: axum::response::Response) -> Value {
        serde_json::from_slice(
            &axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap(),
        )
        .unwrap()
    }

    #[tokio::test]
    async fn test_list_tasks_empty() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/auto-tasks")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp).await;
        assert_eq!(json["total"], 0);
    }

    #[tokio::test]
    async fn test_create_and_list() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        // 创建
        let body = serde_json::to_string(&json!({
            "id": "t1",
            "name": "My Task",
            "script": "var x = 1;"
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::CREATED);
        let json = body_json(resp).await;
        assert_eq!(json["created"], true);

        // 列表
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/auto-tasks")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        let json = body_json(resp).await;
        assert_eq!(json["total"], 1);
    }

    #[tokio::test]
    async fn test_update_task() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        // 先创建
        let body = serde_json::to_string(&json!({
            "id": "t2",
            "name": "Original",
            "script": "x"
        }))
        .unwrap();
        let _ = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 更新
        let update_body = serde_json::to_string(&json!({ "name": "Updated" })).unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::PUT)
                    .uri("/api/auto-tasks/t2")
                    .header("Content-Type", "application/json")
                    .body(Body::from(update_body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp).await;
        assert_eq!(json["updated"], true);
    }

    #[tokio::test]
    async fn test_delete_task() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        // 创建
        let body = serde_json::to_string(&json!({
            "id": "t3",
            "name": "ToDelete",
            "script": "y"
        }))
        .unwrap();
        let _ = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 删除
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::DELETE)
                    .uri("/api/auto-tasks/t3")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp).await;
        assert_eq!(json["deleted"], true);

        // 验证已删除
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/auto-tasks")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let json = body_json(resp).await;
        assert_eq!(json["total"], 0);
    }

    #[tokio::test]
    async fn test_run_task() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        // 创建
        let body = serde_json::to_string(&json!({
            "id": "t4",
            "name": "Runnable",
            "script": "console.log('hello');"
        }))
        .unwrap();
        let _ = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 执行
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks/t4/run")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp).await;
        assert_eq!(json["success"], true);
        assert_eq!(json["task_id"], "t4");
    }

    #[tokio::test]
    async fn test_run_task_not_found() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks/nonexistent/run")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_import_and_export() {
        let _guard = TEST_LOCK.lock().await;
        clear_store().await;
        let app = test_router();

        // 导入
        let import_data = serde_json::to_string(&json!([
            {"id": "imp1", "name": "Imported1", "script": "a"},
            {"id": "imp2", "name": "Imported2", "script": "b"}
        ]))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/auto-tasks/import")
                    .header("Content-Type", "application/json")
                    .body(Body::from(import_data))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp).await;
        assert_eq!(json["imported"], 2);

        // 导出
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/auto-tasks/export")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp).await;
        assert_eq!(json["total"], 2);
    }
}
