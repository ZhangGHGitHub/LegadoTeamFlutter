//! 批30：书源检验状态 4 端点集成测试
//!
//! 覆盖：
//! - `GET /getBookSourcesForManagement`：全量 / 指定 urls / 坏 urls；
//! - `GET /getBookSourceCheckStates`：`{states, sessionToken}` 形状与键名；
//! - `POST /startBookSourceCheck`：令牌前置、参数校验、内容版本校验、
//!   排队状态重置、后台检验失败写回、完成后 sessionToken 清空；
//! - `POST /stopBookSourceCheck`：会话不匹配文案；挂起请求时停止成功且
//!   未完成源保持 `NEEDS_CHECK`。
//!
//! 原版依据见 `legado-server/src/legacy/source_check_api.rs` 模块文档。

use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tower::ServiceExt;

use legado_core::download_manager::DownloadManager;
use legado_core::models::BookSource;
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::BookSourceRepository;
use legado_server::routes::create_router;
use legado_server::state::AppState;

fn make_state() -> Arc<AppState> {
    let db = legado_db::init_in_memory_database().unwrap();
    Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
        injected_paths: Default::default(),
        legacy_review: Default::default(),
        source_check: Default::default(),
    })
}

/// 关闭令牌要求（对齐 `config:jsSourceApiTokenRequired = false`）
async fn disable_token_requirement(state: &Arc<AppState>) {
    let db = state.db.lock().await;
    CacheRepository::new(db.connection())
        .put("config:jsSourceApiTokenRequired", "false", 0)
        .unwrap();
}

async fn seed_source(state: &Arc<AppState>, source: BookSource) {
    let db = state.db.lock().await;
    BookSourceRepository::new(db.connection())
        .insert_with_check_state(&source)
        .unwrap();
}

fn make_source(url: &str) -> BookSource {
    BookSource {
        book_source_url: url.to_string(),
        book_source_name: format!("检验源{url}"),
        ..BookSource::default()
    }
}

async fn get_json(app: axum::Router, uri: &str) -> (StatusCode, Value) {
    let resp = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

async fn post_json(app: axum::Router, uri: &str, body: &str) -> (StatusCode, Value) {
    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(uri)
                .header("Content-Type", "application/json")
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

async fn post_json_with_token(
    app: axum::Router,
    uri: &str,
    body: &str,
    token: &str,
) -> (StatusCode, Value) {
    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(uri)
                .header("Content-Type", "application/json")
                .header("x-legado-token", token)
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

/// 极简 percent-encode（仅测试用）
fn enc(input: &str) -> String {
    let mut out = String::new();
    for b in input.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn state_of<'a>(states: &'a Value, url: &str) -> Option<&'a Value> {
    states
        .as_array()?
        .iter()
        .find(|state| state["bookSourceUrl"] == url)
}

// ─── GET /getBookSourcesForManagement ──────────────────────────────────────

#[tokio::test]
async fn test_management_sources_full_and_filtered() {
    let state = make_state();
    seed_source(&state, make_source("https://b.example.com")).await;
    seed_source(&state, make_source("https://a.example.com")).await;
    let app = create_router(Arc::clone(&state));

    // 全量：sources + states 两组，状态由 insert 钩子创建
    let (status, body) = get_json(app.clone(), "/getBookSourcesForManagement").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["isSuccess"], true);
    assert_eq!(body["errorMsg"], "");
    let data = &body["data"];
    assert_eq!(data["sources"].as_array().unwrap().len(), 2);
    assert_eq!(data["states"].as_array().unwrap().len(), 2);
    let state_json = state_of(&data["states"], "https://a.example.com").unwrap();
    assert_eq!(state_json["status"], "NEEDS_CHECK");
    assert_eq!(state_json["checkedAt"], 0);
    assert_eq!(state_json["detail"], "");
    assert!(state_json["revision"]
        .as_str()
        .is_some_and(|s| !s.is_empty()));
    assert!(state_json["sourceRevision"]
        .as_str()
        .is_some_and(|s| !s.is_empty()));

    // 指定 urls：仅返回命中的源与状态
    let urls = json!(["https://a.example.com"]).to_string();
    let (status, body) = get_json(
        app.clone(),
        &format!("/getBookSourcesForManagement?urls={}", enc(&urls)),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["isSuccess"], true);
    assert_eq!(body["data"]["sources"].as_array().unwrap().len(), 1);
    assert_eq!(
        body["data"]["sources"][0]["bookSourceUrl"],
        "https://a.example.com"
    );
    assert_eq!(body["data"]["states"].as_array().unwrap().len(), 1);

    // 坏 JSON：原版文案
    let (status, body) = get_json(
        app,
        &format!(
            "/getBookSourcesForManagement?urls={}",
            enc("not-a-json-array")
        ),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["isSuccess"], false);
    assert_eq!(body["errorMsg"], "书源地址参数无效");
    assert!(body["data"].is_null());
}

// ─── GET /getBookSourceCheckStates ─────────────────────────────────────────

#[tokio::test]
async fn test_check_states_shape_and_session_token() {
    let state = make_state();
    seed_source(&state, make_source("https://a.example.com")).await;
    let app = create_router(Arc::clone(&state));

    let (status, body) = get_json(app, "/getBookSourceCheckStates").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["isSuccess"], true);
    assert!(body["data"]["sessionToken"].is_null());
    let states = body["data"]["states"].as_array().unwrap();
    assert_eq!(states.len(), 1);
    let keys: Vec<&str> = states[0]
        .as_object()
        .unwrap()
        .keys()
        .map(|k| k.as_str())
        .collect();
    for expected in [
        "bookSourceUrl",
        "revision",
        "sourceRevision",
        "status",
        "checkedAt",
        "detail",
    ] {
        assert!(keys.contains(&expected), "缺少键 {expected}: {keys:?}");
    }
    assert_eq!(states[0]["status"], "NEEDS_CHECK");
}

// ─── POST /startBookSourceCheck ────────────────────────────────────────────

fn start_body(sources: &[BookSource], keyword: &str) -> String {
    json!({ "sources": sources, "keyword": keyword }).to_string()
}

#[tokio::test]
async fn test_start_requires_token_by_default() {
    let state = make_state();
    seed_source(&state, make_source("https://a.example.com")).await;
    let app = create_router(Arc::clone(&state));

    let body = start_body(&[make_source("https://a.example.com")], "");
    let (status, body) = post_json(app, "/startBookSourceCheck", &body).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["isSuccess"], false);
    assert_eq!(body["errorMsg"], "Web 书源访问令牌未配置或不正确");
}

#[tokio::test]
async fn test_start_parameter_errors() {
    let state = make_state();
    disable_token_requirement(&state).await;
    let app = create_router(Arc::clone(&state));

    // 空 body → 检验参数无效
    let (_, body) = post_json(app.clone(), "/startBookSourceCheck", "   ").await;
    assert_eq!(body["isSuccess"], false);
    assert_eq!(body["errorMsg"], "检验参数无效");
    // 坏 JSON → 检验参数无效
    let (_, body) = post_json(app.clone(), "/startBookSourceCheck", "{oops").await;
    assert_eq!(body["errorMsg"], "检验参数无效");
    // 空 sources → 请选择需要检验的书源
    let (_, body) = post_json(app.clone(), "/startBookSourceCheck", "{}").await;
    assert_eq!(body["errorMsg"], "请选择需要检验的书源");
    let (_, body) = post_json(app, "/startBookSourceCheck", &start_body(&[], "")).await;
    assert_eq!(body["errorMsg"], "请选择需要检验的书源");
}

#[tokio::test]
async fn test_start_rejects_unsaved_or_changed_source() {
    let state = make_state();
    disable_token_requirement(&state).await;
    let app = create_router(Arc::clone(&state));

    // 未保存
    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[make_source("https://missing.example.com")], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], false);
    assert_eq!(
        body["errorMsg"],
        "书源尚未保存或设备版本已变更，请先保存或重新拉取"
    );

    // 库内存在但提交内容已变（searchUrl 不同）
    seed_source(&state, make_source("https://a.example.com")).await;
    let mut changed = make_source("https://a.example.com");
    changed.search_url = Some("https://a.example.com/search?q={key}".to_string());
    let (_, body) = post_json(app, "/startBookSourceCheck", &start_body(&[changed], "")).await;
    assert_eq!(
        body["errorMsg"],
        "书源尚未保存或设备版本已变更，请先保存或重新拉取"
    );
}

#[tokio::test]
async fn test_start_queues_and_writes_back_failure() {
    let state = make_state();
    disable_token_requirement(&state).await;
    // 无 searchUrl 的规则源：校验立即失败（不发网络请求）
    seed_source(&state, make_source("https://a.example.com")).await;
    let db = state.db.lock().await;
    let stored = BookSourceRepository::new(db.connection())
        .find_by_url("https://a.example.com")
        .unwrap()
        .unwrap();
    drop(db);
    let previous_revision = {
        let db = state.db.lock().await;
        legado_db::BookSourceCheckStateRepository::new(db.connection())
            .find_by_url("https://a.example.com")
            .unwrap()
            .unwrap()
            .revision
    };
    let app = create_router(Arc::clone(&state));

    let (status, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(std::slice::from_ref(&stored), ""),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    assert_eq!(body["isSuccess"], true, "{body}");
    let session_token = body["data"]["sessionToken"].as_str().unwrap().to_string();
    assert!(session_token.contains(':'), "processToken:sessionId");
    let source_revision = body["data"]["sourceRevisions"]["https://a.example.com"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(!source_revision.is_empty());

    // 后台任务迅速失败写回
    let mut final_state = Value::Null;
    for _ in 0..40 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        let (_, body) = get_json(app.clone(), "/getBookSourceCheckStates").await;
        if let Some(state) = state_of(&body["data"]["states"], "https://a.example.com") {
            if state["status"] == "FAILED" {
                final_state = state.clone();
                assert!(body["data"]["sessionToken"].is_null(), "会话应已结束");
                break;
            }
        }
    }
    assert_eq!(final_state["status"], "FAILED", "校验失败应写回");
    assert_eq!(
        final_state["detail"], "校验失败:搜索链接规则为空",
        "失败详情对齐原版 message 组合"
    );
    assert!(final_state["checkedAt"].as_i64().unwrap() > 0);
    assert_ne!(
        final_state["revision"], previous_revision,
        "排队应生成新 revision"
    );
    assert_eq!(
        final_state["sourceRevision"], source_revision,
        "sourceRevision 在排队时保留"
    );

    // 会话已结束 → stop 文案
    let (_, body) = post_json(
        app,
        "/stopBookSourceCheck",
        &json!({ "sessionToken": session_token }).to_string(),
    )
    .await;
    assert_eq!(body["isSuccess"], false);
    assert_eq!(body["errorMsg"], "检验会话已结束或已更换");
}

// ─── POST /stopBookSourceCheck ─────────────────────────────────────────────

#[tokio::test]
async fn test_stop_with_invalid_token() {
    let state = make_state();
    disable_token_requirement(&state).await;
    let app = create_router(Arc::clone(&state));
    let (_, body) = post_json(
        app,
        "/stopBookSourceCheck",
        &json!({ "sessionToken": "nope" }).to_string(),
    )
    .await;
    assert_eq!(body["isSuccess"], false);
    assert_eq!(body["errorMsg"], "检验会话已结束或已更换");
}

/// 挂起请求（本地 TCP 只 accept 不响应）以稳定命中「检验进行中」
async fn spawn_hanging_server() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            tokio::spawn(async move {
                // 保持连接直到测试结束/任务被取消
                let _stream = stream;
                tokio::time::sleep(Duration::from_secs(120)).await;
            });
        }
    });
    port
}

#[tokio::test]
async fn test_stop_aborts_running_check() {
    let state = make_state();
    disable_token_requirement(&state).await;
    let port = spawn_hanging_server().await;
    let mut source = make_source("https://a.example.com");
    source.search_url = Some(format!("http://127.0.0.1:{port}/search?q={{key}}"));
    seed_source(&state, source.clone()).await;
    // 缩短超时，避免测试尾部等待
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:checkSourceTimeout", "5000", 0)
            .unwrap();
    }
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let token = body["data"]["sessionToken"].as_str().unwrap().to_string();

    // 等待进入 NEEDS_CHECK（已排队）且会话仍在
    let mut running = false;
    for _ in 0..40 {
        let (_, body) = get_json(app.clone(), "/getBookSourceCheckStates").await;
        if body["data"]["sessionToken"] == token {
            if let Some(state) = state_of(&body["data"]["states"], "https://a.example.com") {
                if state["status"] == "NEEDS_CHECK" {
                    running = true;
                    break;
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(running, "应进入检验中状态");

    let (_, body) = post_json(
        app.clone(),
        "/stopBookSourceCheck",
        &json!({ "sessionToken": token }).to_string(),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    assert_eq!(body["data"], "");

    // 停止后：会话清空；未完成源保持 NEEDS_CHECK
    tokio::time::sleep(Duration::from_millis(200)).await;
    let (_, body) = get_json(app, "/getBookSourceCheckStates").await;
    assert!(body["data"]["sessionToken"].is_null());
    let state_json = state_of(&body["data"]["states"], "https://a.example.com").unwrap();
    assert_eq!(state_json["status"], "NEEDS_CHECK");
}

// ─── 令牌头路径（required=true 且令牌正确） ─────────────────────────────────

#[tokio::test]
async fn test_start_accepts_matching_token_header() {
    let state = make_state();
    {
        let db = state.db.lock().await;
        let cache = CacheRepository::new(db.connection());
        cache
            .put("config:jsSourceApiTokenRequired", "true", 0)
            .unwrap();
        cache
            .put("config:jsSourceApiToken", "secret-token", 0)
            .unwrap();
    }
    seed_source(&state, make_source("https://a.example.com")).await;
    let db = state.db.lock().await;
    let stored = BookSourceRepository::new(db.connection())
        .find_by_url("https://a.example.com")
        .unwrap()
        .unwrap();
    drop(db);
    let app = create_router(Arc::clone(&state));

    let body = start_body(&[stored], "");
    let (_, without) = post_json(app.clone(), "/startBookSourceCheck", &body).await;
    assert_eq!(without["isSuccess"], false);
    assert_eq!(without["errorMsg"], "Web 书源访问令牌未配置或不正确");

    let (_, with) =
        post_json_with_token(app.clone(), "/startBookSourceCheck", &body, "secret-token").await;
    assert_eq!(with["isSuccess"], true, "{with}");

    // 清理运行中的会话（无 searchUrl 的规则源会立即失败，这里仍兜底停止）
    if let Some(token) = with["data"]["sessionToken"].as_str() {
        let (_, stopped) = post_json_with_token(
            app,
            "/stopBookSourceCheck",
            &json!({ "sessionToken": token }).to_string(),
            "secret-token",
        )
        .await;
        // 任务可能已自然结束 → 允许「会话已结束」或成功
        assert!(
            stopped["isSuccess"] == true || stopped["errorMsg"] == "检验会话已结束或已更换",
            "{stopped}"
        );
    }
}

// ─── 旧路径不被破坏 ────────────────────────────────────────────────────────

#[tokio::test]
async fn test_unknown_path_still_404() {
    let state = make_state();
    let app = create_router(Arc::clone(&state));
    let resp = app
        .oneshot(
            Request::builder()
                .uri("/definitely-not-an-endpoint")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
