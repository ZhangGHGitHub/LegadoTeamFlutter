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
/// 拉取远程订阅内容 → 按订阅类型真正落库 → 同事务回写版本号。
/// 与 FFI `ruleSubApplyUpdate` 共用 `legado_db::apply_rule_subscription`。
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

    // 与 FFI `ruleSubApplyUpdate` 共用 legado-db 单实现：按 sub_type 真正
    // 写入 book_sources / rssSources / replace_rules，版本号写在同一事务的
    // 最后一步；任一步失败整笔回滚且不推进版本号（P1-3）。
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64;
    let new_version = extract_version(&remote_json).unwrap_or_default();

    let applied = {
        let db = state.db.lock().await;
        legado_db::apply_rule_subscription(
            db.connection(),
            sub.id,
            &sub.sub_type,
            &remote_json,
            &new_version,
            now,
        )
    };

    let result = match applied {
        Ok(outcome) => ApplyUpdateResult {
            url: sub.url.clone(),
            success: true,
            items_added: outcome.added,
            items_updated: outcome.updated,
            items_removed: outcome.removed,
            error: None,
        },
        Err(e) => ApplyUpdateResult {
            url: sub.url.clone(),
            success: false,
            items_added: 0,
            items_updated: 0,
            items_removed: 0,
            error: Some(format!("应用订阅失败: {e}")),
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
            injected_paths: Default::default(),
            legacy_review: Default::default(),
            source_check: Default::default(),
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

    /// 启动一次性回环 JSON 服务器（返回固定 body），返回端口
    ///
    /// 与 legado-ffi 既有测试同款最小 HTTP/1.1 实现；`Connection: close`
    /// 让 reqwest 读完即断开，无需 keep-alive 循环。
    fn spawn_json_server(body: String) -> u16 {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while let Ok(1) = sock.read(&mut byte) {
                    head.push(byte[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(response.as_bytes());
                let _ = sock.flush();
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });
        port
    }

    /// P1-3：`POST /api/rule-update/apply` 必须真正落库（修复前只回写版本号）
    #[tokio::test]
    async fn test_apply_update_lands_book_sources_in_db() {
        use legado_db::repository::Repository;
        use legado_db::BookSourceRepository;

        let state = make_test_state();
        let body = r#"[
            {"bookSourceUrl":"https://web-p13-a.example.com","bookSourceName":"P13-A","searchUrl":"https://web-p13-a.example.com/s"},
            {"bookSourceUrl":"https://web-p13-b.example.com","bookSourceName":"P13-B","searchUrl":"https://web-p13-b.example.com/s"}
        ]"#;
        let port = spawn_json_server(body.to_string());
        let url = format!("http://127.0.0.1:{port}/sub.json");

        {
            let db = state.db.lock().await;
            RuleSubRepository::new(db.connection())
                .insert(&RuleSubRecord {
                    url: url.clone(),
                    name: "Web应用订阅".to_string(),
                    sub_type: "bookSource".to_string(),
                    version: "1.0".to_string(),
                    created_at: 1_700_000_000_000,
                    ..RuleSubRecord::default()
                })
                .unwrap();
        }

        let app = make_router(state.clone());
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rule-update/apply")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_string(&json!({"url": url})).unwrap(),
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
        assert_eq!(json["success"], true, "应用应成功: {json}");
        // Web 端点沿用既有 snake_case 响应字段（FFI 侧为 camelCase）
        assert_eq!(json["items_added"], 2, "计数应为真实落库变化: {json}");
        assert_eq!(json["items_updated"], 0);
        assert_eq!(json["items_removed"], 0);

        // DB 真有 2 行
        let db = state.db.lock().await;
        let sources = BookSourceRepository::new(db.connection())
            .find_all()
            .unwrap();
        assert_eq!(sources.len(), 2);
        assert!(sources
            .iter()
            .any(|s| s.book_source_url == "https://web-p13-b.example.com"));
        // 版本号（最后更新时间）已推进
        let sub = RuleSubRepository::new(db.connection())
            .find_by_url(&url)
            .unwrap()
            .unwrap();
        assert!(sub.last_update > 0);
    }

    /// P1-3：落库失败时返回 success=false，DB 零改动、版本号不推进
    #[tokio::test]
    async fn test_apply_update_rolls_back_on_invalid_item() {
        use legado_db::repository::Repository;
        use legado_db::BookSourceRepository;

        let state = make_test_state();
        let body = r#"[{"bookSourceName":"没有URL"}]"#;
        let port = spawn_json_server(body.to_string());
        let url = format!("http://127.0.0.1:{port}/sub.json");

        {
            let db = state.db.lock().await;
            RuleSubRepository::new(db.connection())
                .insert(&RuleSubRecord {
                    url: url.clone(),
                    name: "Web应用失败".to_string(),
                    sub_type: "bookSource".to_string(),
                    version: "1.0".to_string(),
                    created_at: 1_700_000_000_000,
                    ..RuleSubRecord::default()
                })
                .unwrap();
        }

        let app = make_router(state.clone());
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/rule-update/apply")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::to_string(&json!({"url": url})).unwrap(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(json["success"], false);
        assert!(json["error"]
            .as_str()
            .unwrap()
            .contains("缺少 bookSourceUrl"));

        let db = state.db.lock().await;
        assert_eq!(
            BookSourceRepository::new(db.connection())
                .find_all()
                .unwrap()
                .len(),
            0,
            "失败时不得留下任何条目"
        );
        let sub = RuleSubRepository::new(db.connection())
            .find_by_url(&url)
            .unwrap()
            .unwrap();
        assert_eq!(sub.version, "1.0", "失败时版本号不得推进");
        assert_eq!(sub.last_update, 0);
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
