//! 规则订阅更新处理器
//!
//! 提供规则订阅管理与更新能力：
//! - GET /api/rule-update/subs — 获取订阅列表
//! - POST /api/rule-update/check — 检查更新
//! - POST /api/rule-update/apply — 应用更新

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;

use legado_db::repository::rule_sub_repository::RuleSubRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// 订阅信息响应
#[derive(Debug, Clone, Serialize)]
pub struct SubInfo {
    pub id: i64,
    pub url: String,
    pub name: String,
    pub sub_type: String,
    pub last_update: i64,
    pub version: String,
    pub is_enabled: bool,
}

/// 检查更新请求体
#[derive(Debug, Deserialize)]
pub struct CheckUpdateRequest {
    /// 指定订阅 URL（为空则检查所有已启用订阅）
    #[serde(default)]
    pub url: Option<String>,
}

/// 检查更新结果
#[derive(Debug, Serialize)]
pub struct CheckUpdateResult {
    pub url: String,
    pub name: String,
    pub has_update: bool,
    pub remote_version: Option<String>,
    pub error: Option<String>,
}

/// 应用更新请求体
#[derive(Debug, Deserialize)]
pub struct ApplyUpdateRequest {
    /// 订阅 URL
    pub url: String,
    /// 是否静默更新
    #[serde(default)]
    pub silent: bool,
}

/// 应用更新结果
#[derive(Debug, Serialize)]
pub struct ApplyUpdateResult {
    pub url: String,
    pub success: bool,
    pub items_added: usize,
    pub items_updated: usize,
    pub items_removed: usize,
    pub error: Option<String>,
}

/// GET /api/rule-update/subs — 获取订阅列表
pub async fn list_subs(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let subs = {
        let db = state.db.lock().await;
        let repo = RuleSubRepository::new(db.connection());
        repo.find_all()?
    };

    let items: Vec<SubInfo> = subs
        .iter()
        .map(|s| SubInfo {
            id: s.id,
            url: s.url.clone(),
            name: s.name.clone(),
            sub_type: s.sub_type.clone(),
            last_update: s.last_update,
            version: s.version.clone(),
            is_enabled: s.is_enabled,
        })
        .collect();

    Ok(Json(json!({
        "subs": items,
        "total": items.len(),
    })))
}

/// POST /api/rule-update/check — 检查更新
///
/// 从远程拉取订阅内容，对比版本号判断是否有更新。
pub async fn check_update(
    State(state): State<Arc<AppState>>,
    Json(body): Json<CheckUpdateRequest>,
) -> Result<Json<Value>, ApiError> {
    let subs = {
        let db = state.db.lock().await;
        let repo = RuleSubRepository::new(db.connection());
        match &body.url {
            Some(url) => match repo.find_by_url(url)? {
                Some(s) => vec![s],
                None => {
                    return Ok(Json(json!({
                        "results": [],
                        "error": format!("未找到订阅: {url}"),
                    })))
                }
            },
            None => repo.get_enabled_subs()?,
        }
    };

    let mut results: Vec<CheckUpdateResult> = Vec::new();

    for sub in &subs {
        let subscription = legado_net::RuleSubscription {
            url: sub.url.clone(),
            name: sub.name.clone(),
            sub_type: sub.sub_type.clone(),
        };

        match legado_net::fetch_subscription(&subscription).await {
            Ok(remote_json) => {
                // 尝试从远程 JSON 中提取版本信息
                let remote_version = extract_version(&remote_json);
                let has_update = match &remote_version {
                    Some(rv) => rv != &sub.version,
                    None => !remote_json.is_empty(),
                };

                results.push(CheckUpdateResult {
                    url: sub.url.clone(),
                    name: sub.name.clone(),
                    has_update,
                    remote_version,
                    error: None,
                });
            }
            Err(e) => {
                results.push(CheckUpdateResult {
                    url: sub.url.clone(),
                    name: sub.name.clone(),
                    has_update: false,
                    remote_version: None,
                    error: Some(e),
                });
            }
        }
    }

    Ok(Json(json!({ "results": results })))
}

/// POST /api/rule-update/apply — 应用更新
///
/// 拉取远程订阅内容并合并到本地。
pub async fn apply_update(
    State(state): State<Arc<AppState>>,
    Json(body): Json<ApplyUpdateRequest>,
) -> Result<Json<Value>, ApiError> {
    let sub = {
        let db = state.db.lock().await;
        let repo = RuleSubRepository::new(db.connection());
        repo.find_by_url(&body.url)?
    };

    let sub = match sub {
        Some(s) => s,
        None => {
            return Ok(Json(json!({
                "success": false,
                "error": format!("未找到订阅: {}", body.url),
            })))
        }
    };

    let subscription = legado_net::RuleSubscription {
        url: sub.url.clone(),
        name: sub.name.clone(),
        sub_type: sub.sub_type.clone(),
    };

    let remote_json = match legado_net::fetch_subscription(&subscription).await {
        Ok(content) => content,
        Err(e) => {
            return Ok(Json(json!({
                "success": false,
                "error": format!("拉取订阅失败: {e}"),
            })))
        }
    };

    // 使用空本地 JSON 进行合并（简化版：全量导入）
    let merge_result = legado_net::merge_subscription("[]", &remote_json, &sub.sub_type);

    let result = match merge_result {
        Ok(mr) => {
            // 更新订阅版本和时间
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis() as i64;

            let new_version = extract_version(&remote_json).unwrap_or_default();
            {
                let db = state.db.lock().await;
                let repo = RuleSubRepository::new(db.connection());
                let _ = repo.update_version(sub.id, &new_version, now);
            }

            ApplyUpdateResult {
                url: sub.url.clone(),
                success: true,
                items_added: mr.added,
                items_updated: mr.updated,
                items_removed: mr.removed,
                error: None,
            }
        }
        Err(e) => ApplyUpdateResult {
            url: sub.url.clone(),
            success: false,
            items_added: 0,
            items_updated: 0,
            items_removed: 0,
            error: Some(e),
        },
    };

    Ok(Json(json!(result)))
}

/// 尝试从 JSON 内容中提取版本信息
fn extract_version(json_str: &str) -> Option<String> {
    // 尝试解析为对象并查找 version 字段
    if let Ok(obj) = serde_json::from_str::<Value>(json_str) {
        if let Some(v) = obj.get("version").and_then(|v| v.as_str()) {
            return Some(v.to_string());
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use axum::routing::{get, post};
    use axum::Router;
    use tower::ServiceExt;

    use legado_db::repository::rule_sub_repository::RuleSubRecord;
    use legado_db::Database;

    fn make_test_state() -> Arc<AppState> {
        let db = Database::open_in_memory().unwrap();
        Arc::new(AppState {
            db: tokio::sync::Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    fn make_router(state: Arc<AppState>) -> Router {
        Router::new()
            .route("/api/rule-update/subs", get(list_subs))
            .route("/api/rule-update/check", post(check_update))
            .route("/api/rule-update/apply", post(apply_update))
            .with_state(state)
    }

    #[tokio::test]
    async fn test_list_subs_empty() {
        let state = make_test_state();
        let app = make_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/rule-update/subs")
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
    }

    #[tokio::test]
    async fn test_list_subs_with_data() {
        let state = make_test_state();

        // 插入测试数据
        {
            let db = state.db.lock().await;
            let repo = RuleSubRepository::new(db.connection());
            repo.insert(&RuleSubRecord {
                url: "https://example.com/sub.json".to_string(),
                name: "测试订阅".to_string(),
                sub_type: "bookSource".to_string(),
                created_at: 1700000000000,
                ..RuleSubRecord::default()
            })
            .unwrap();
        }

        let app = make_router(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/rule-update/subs")
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
        assert_eq!(json["total"], 1);
        assert_eq!(json["subs"][0]["name"], "测试订阅");
    }

    #[tokio::test]
    async fn test_check_update_not_found() {
        let state = make_test_state();
        let app = make_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rule-update/check")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_string(&json!({"url": "https://nonexist.com"})).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert!(json["error"].as_str().unwrap().contains("未找到订阅"));
    }

    #[tokio::test]
    async fn test_apply_update_not_found() {
        let state = make_test_state();
        let app = make_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rule-update/apply")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_string(&json!({"url": "https://nonexist.com"})).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["success"], false);
    }

    #[test]
    fn test_extract_version() {
        assert_eq!(
            extract_version(r#"{"version": "1.2.3", "data": []}"#),
            Some("1.2.3".to_string())
        );
        assert_eq!(extract_version(r#"[{"a": 1}]"#), None);
        assert_eq!(extract_version("not json"), None);
    }
}
