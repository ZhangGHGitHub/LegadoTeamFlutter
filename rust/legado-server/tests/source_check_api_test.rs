//! 批30 / 批42 / 批42b：书源检验状态 4 端点集成测试
//!
//! 覆盖：
//! - `GET /getBookSourcesForManagement`：全量 / 指定 urls / 坏 urls；
//! - `GET /getBookSourceCheckStates`：`{states, sessionToken}` 形状与键名；
//! - `POST /startBookSourceCheck`：令牌前置、参数校验、内容版本校验、
//!   排队状态重置、后台检验失败写回、完成后 sessionToken 清空；
//! - `POST /stopBookSourceCheck`：会话不匹配文案；请求真实到达 mock 后停止，
//!   在途结果不得写回（批42b P2-1/P2-3），未完成源保持 `NEEDS_CHECK`；
//! - 批42：发现页校验（规则为空/坏列表/正常/JS 求值失败）、并行检验
//!   （与串行耗时对比）、源地址 TCP 探测（可达/不可达，带请求计数）；
//! - 批42b P2-2：硬失败早退保留已累计失效分组（搜索失效 + 发现失败）。
//!
//! 原版依据见 `legado-server/src/legacy/source_check_api.rs` 模块文档。

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tower::ServiceExt;

use legado_core::download_manager::DownloadManager;
use legado_core::models::{BookSource, ExploreRule};
use legado_db::repository::cache_repository::CacheRepository;
use legado_db::BookSourceRepository;
use legado_server::routes::create_router;
use legado_server::server::attach_source_write_token_guard;
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

#[tokio::test]
async fn test_management_full_branch_reports_db_error() {
    let state = make_state();
    seed_source(&state, make_source("https://a.example.com")).await;
    // 制造查询失败（状态表缺失）：全量分支必须返回错误信封而非静默空列表
    {
        let db = state.db.lock().await;
        db.connection()
            .execute_batch("DROP TABLE book_source_check_states;")
            .unwrap();
    }
    let app = create_router(Arc::clone(&state));
    let (status, body) = get_json(app, "/getBookSourcesForManagement").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["isSuccess"], false, "{body}");
    assert!(
        body["errorMsg"].as_str().is_some_and(|msg| !msg.is_empty()),
        "应返回数据库错误文案: {body}"
    );
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
        final_state["detail"], "校验失败:搜索链接规则为空 | // Error: 搜索链接规则为空",
        "失败详情对齐原版组合：失效分组 | message | 本次异常（addErrorComment 前置首行）"
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
    let (port, _hits) = spawn_hanging_server_counting().await;
    port
}

/// 同 [`spawn_hanging_server`]，另返回「请求已到达」计数
///
/// 批42b P2-3：停止取消类用例必须先确认请求真实到达 mock 再 stop，
/// 否则 stop 可能发生在请求发出之前，用例近恒真（旧实现只等状态变为
/// `NEEDS_CHECK`，而该状态在后台任务开始前就已写入）。
async fn spawn_hanging_server_counting() -> (u16, Arc<AtomicUsize>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_srv = Arc::clone(&hits);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            hits_srv.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(async move {
                // 保持连接直到测试结束/任务被取消
                let _stream = stream;
                tokio::time::sleep(Duration::from_secs(120)).await;
            });
        }
    });
    (port, hits)
}

/// 等待 mock 收到至少一次请求（避免 stop 早于请求发出导致用例恒真）
async fn wait_mock_hit(hits: &AtomicUsize, timeout: Duration) {
    let started = std::time::Instant::now();
    while hits.load(Ordering::SeqCst) == 0 {
        assert!(
            started.elapsed() < timeout,
            "等待 mock 收到请求超时（{}ms）",
            timeout.as_millis()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

#[tokio::test]
async fn test_stop_aborts_running_check() {
    let state = make_state();
    disable_token_requirement(&state).await;
    let (port, hits) = spawn_hanging_server_counting().await;
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

    // 等待请求真实到达 mock（P2-3：不能只等 NEEDS_CHECK 状态，该状态在
    // 后台任务发出请求前就已写入，stop 可能先于请求到达 → 用例近恒真）
    wait_mock_hit(&hits, Duration::from_secs(5)).await;

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

/// 批42b P2-1：stop 后不得再把在途结果写回
///
/// 回归窗口：`check_one_source` 在 `check_source` 返回后、`finish_check` 前
/// 没有取消检查。取消（AbortHandle）只能打断 await 点，若请求刚好在 stop
/// 前后超时返回，结果会照常写回 FAILED，覆盖「停止后保持 NEEDS_CHECK」语义。
///
/// 设计区分力：挂起 mock 保证请求一直未响应；`config:checkSourceTimeout`
/// 写入 500ms，但实现把超时夹逼到下限 1000ms（`load_check_config`），故
/// 等待 1600ms（> 生效超时）后断言仍为 NEEDS_CHECK——若结果被写回则必为
/// FAILED。请求到达 mock 后才 stop（P2-3），避免 stop 早于请求发出。
#[tokio::test]
async fn test_stop_after_inflight_timeout_keeps_needs_check() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    let (port, hits) = spawn_hanging_server_counting().await;
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:checkSourceTimeout", "500", 0)
            .unwrap();
    }
    let source = discovery_source(
        "https://a.example.com",
        Some(format!("分类::http://127.0.0.1:{port}/list")),
    );
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let token = body["data"]["sessionToken"].as_str().unwrap().to_string();

    wait_mock_hit(&hits, Duration::from_secs(5)).await;

    let (_, body) = post_json(
        app.clone(),
        "/stopBookSourceCheck",
        &json!({ "sessionToken": token }).to_string(),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");

    // 生效超时 1000ms（500 被夹逼），再留 600ms 余量：在途结果若写回，
    // 此处必已是 FAILED「校验超时」
    tokio::time::sleep(Duration::from_millis(1_600)).await;
    let (_, body) = get_json(app, "/getBookSourceCheckStates").await;
    assert!(body["data"]["sessionToken"].is_null(), "停止后会话应清空");
    let state_json = state_of(&body["data"]["states"], "https://a.example.com").unwrap();
    assert_eq!(
        state_json["status"], "NEEDS_CHECK",
        "停止后在途结果不得写回（detail={}）",
        state_json["detail"]
    );
    assert_eq!(state_json["detail"], "", "未写回则 detail 仍为空");
}

// ─── 批42：发现页校验 ──────────────────────────────────────────────────────

/// 只开启发现校验（关闭搜索/详情/目录/正文），隔离发现项断言
async fn only_discovery_config(state: &Arc<AppState>) {
    let db = state.db.lock().await;
    let cache = CacheRepository::new(db.connection());
    cache.put("config:checkSearch", "false", 0).unwrap();
    cache.put("config:checkInfo", "false", 0).unwrap();
    cache.put("config:checkCategory", "false", 0).unwrap();
    cache.put("config:checkContent", "false", 0).unwrap();
}

/// 开启搜索 + 发现，关闭详情/目录/正文（批42b P2-2 用例隔离用）
async fn search_and_discovery_config(state: &Arc<AppState>) {
    let db = state.db.lock().await;
    let cache = CacheRepository::new(db.connection());
    cache.put("config:checkInfo", "false", 0).unwrap();
    cache.put("config:checkCategory", "false", 0).unwrap();
    cache.put("config:checkContent", "false", 0).unwrap();
}

/// 简单 HTML 列表页（`ruleExplore` 用 `class` 选择器解析）
const LIST_HTML: &str = r#"<html><body>
<div class="book"><a class="name" href="/book/1">发现书甲</a></div>
<div class="book"><a class="name" href="/book/2">发现书乙</a></div>
</body></html>"#;

/// 启动返回固定 HTML 的 mock 服务（可注入响应延迟，用于并发度断言）
async fn spawn_html_server(delay_ms: u64, body: &'static str) -> u16 {
    let (port, _hits) = spawn_html_server_counting(delay_ms, body).await;
    port
}

/// 同 [`spawn_html_server`]，另返回「收到的请求数」（批42b P3-8 区分力）
async fn spawn_html_server_counting(delay_ms: u64, body: &'static str) -> (u16, Arc<AtomicUsize>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let hits_srv = Arc::clone(&hits);
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let hits = Arc::clone(&hits_srv);
            tokio::spawn(async move {
                let mut buf = vec![0u8; 8192];
                let _ = stream.read(&mut buf).await;
                hits.fetch_add(1, Ordering::SeqCst);
                if delay_ms > 0 {
                    tokio::time::sleep(Duration::from_millis(delay_ms)).await;
                }
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(response.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });
    (port, hits)
}

/// 带发现规则的源：`explore_url` 指向 mock，列表规则命中 `class="book"`
fn discovery_source(url: &str, explore_url: Option<String>) -> BookSource {
    BookSource {
        book_source_url: url.to_string(),
        book_source_name: format!("发现检验源{url}"),
        explore_url,
        rule_explore: Some(ExploreRule {
            book_list: Some("@css:.book".to_string()),
            name: Some("@css:.name@text".to_string()),
            book_url: Some("@css:.name@href".to_string()),
            ..Default::default()
        }),
        ..BookSource::default()
    }
}

/// 等待指定书本源进入终态（PASSED/FAILED/UNCHECKABLE），超时 panic
async fn wait_terminal(app: axum::Router, url: &str, timeout: Duration) -> (Value, Duration) {
    let started = std::time::Instant::now();
    loop {
        let (_, body) = get_json(app.clone(), "/getBookSourceCheckStates").await;
        if let Some(state) = state_of(&body["data"]["states"], url) {
            let status = state["status"].as_str().unwrap_or("");
            if status != "NEEDS_CHECK" {
                return (state.clone(), started.elapsed());
            }
        }
        if started.elapsed() > timeout {
            panic!("等待 {url} 终态超时，最后状态: {body}");
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
}

#[tokio::test]
async fn test_discovery_rule_empty_fails() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    // exploreUrl 非空但只含分组标题（无分类 URL）→ 上游「发现规则为空」
    let source = discovery_source("https://a.example.com", Some("玄幻\n都市".to_string()));
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) =
        wait_terminal(app, "https://a.example.com", Duration::from_secs(10)).await;
    assert_eq!(final_state["status"], "FAILED", "{final_state}");
    assert_eq!(
        final_state["detail"],
        "发现规则为空 | 校验失败:发现规则为空 | // Error: 发现规则为空"
    );
}

#[tokio::test]
async fn test_discovery_empty_explore_url_passes() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    let source = discovery_source("https://a.example.com", None);
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) =
        wait_terminal(app, "https://a.example.com", Duration::from_secs(10)).await;
    assert_eq!(final_state["status"], "PASSED", "{final_state}");
    assert_eq!(final_state["detail"], "", "PASSED 详情恒为空");
}

#[tokio::test]
async fn test_discovery_bad_list_rule_fails() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    let port = spawn_html_server(0, LIST_HTML).await;
    let mut source = discovery_source(
        "https://a.example.com",
        Some(format!("分类::http://127.0.0.1:{port}/list")),
    );
    // 列表规则不命中任何元素 → 发现失效
    source.rule_explore = Some(ExploreRule {
        book_list: Some("@css:.missing".to_string()),
        name: Some("@css:.name@text".to_string()),
        book_url: Some("@css:.name@href".to_string()),
        ..Default::default()
    });
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) =
        wait_terminal(app, "https://a.example.com", Duration::from_secs(10)).await;
    assert_eq!(final_state["status"], "FAILED", "{final_state}");
    assert_eq!(
        final_state["detail"],
        "发现失效 | 校验失败:发现失效 | // Error: 发现失效"
    );
}

#[tokio::test]
async fn test_discovery_good_rule_passes() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    let (port, hits) = spawn_html_server_counting(0, LIST_HTML).await;
    let source = discovery_source(
        "https://a.example.com",
        Some(format!("分类::http://127.0.0.1:{port}/list")),
    );
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) =
        wait_terminal(app, "https://a.example.com", Duration::from_secs(10)).await;
    assert_eq!(final_state["status"], "PASSED", "{final_state}");
    assert_eq!(final_state["detail"], "");
    // 批42b P3-8：区分力——PASSED 必须来自真实执行过发现请求，而不是
    // 校验项被跳过/配置未生效
    assert!(
        hits.load(Ordering::SeqCst) >= 1,
        "发现校验应真实请求 mock（实际 {} 次）",
        hits.load(Ordering::SeqCst)
    );
}

// ─── 批42b P2-2：硬失败早退保留已累计失效分组 ──────────────────────────────

/// 搜索空（组「搜索失效」）+ 发现页请求失败 → detail 同时含两段
///
/// 修复前发现页请求失败走 `CheckOutcome::failed(...)` 早退，已累计的
/// 「搜索失效」分组被丢弃；修复后 detail 首段保留该分组。
#[tokio::test]
async fn test_hard_failure_keeps_search_group() {
    let state = make_state();
    disable_token_requirement(&state).await;
    search_and_discovery_config(&state).await;
    // 搜索请求成功但列表规则不命中 → 搜索失效
    let (search_port, search_hits) = spawn_html_server_counting(0, "<html></html>").await;
    // 发现分类指向已关闭端口 → 请求失败（硬失败早退）
    let closed_port = {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        listener.local_addr().unwrap().port()
    };
    let mut source = discovery_source(
        "https://a.example.com",
        Some(format!("分类::http://127.0.0.1:{closed_port}/list")),
    );
    source.search_url = Some(format!("http://127.0.0.1:{search_port}/search?q={{key}}"));
    source.rule_search = Some(legado_core::models::SearchRule {
        book_list: Some("@css:.missing".to_string()),
        ..Default::default()
    });
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) =
        wait_terminal(app, "https://a.example.com", Duration::from_secs(10)).await;
    assert_eq!(final_state["status"], "FAILED", "{final_state}");
    let detail = final_state["detail"].as_str().unwrap_or("");
    assert!(
        detail.contains("搜索失效"),
        "detail 必须保留已判「搜索失效」分组: {detail}"
    );
    assert!(
        detail.contains("发现页请求失败"),
        "detail 必须包含发现页硬失败消息: {detail}"
    );
    assert!(
        detail.starts_with("搜索失效 | "),
        "已判分组应位于 detail 首段: {detail}"
    );
    assert!(
        search_hits.load(Ordering::SeqCst) >= 1,
        "搜索校验应真实请求 mock（否则「搜索失效」来源不成立）"
    );
}

/// quickjs 构建：`exploreUrl=@js:throw`（求值硬失败）同样保留「搜索失效」
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_js_eval_failure_keeps_search_group() {
    let state = make_state();
    disable_token_requirement(&state).await;
    search_and_discovery_config(&state).await;
    let (search_port, search_hits) = spawn_html_server_counting(0, "<html></html>").await;
    let mut source = discovery_source(
        "https://a.example.com",
        Some("@js:throw new Error('discovery-boom')".to_string()),
    );
    source.search_url = Some(format!("http://127.0.0.1:{search_port}/search?q={{key}}"));
    source.rule_search = Some(legado_core::models::SearchRule {
        book_list: Some("@css:.missing".to_string()),
        ..Default::default()
    });
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) =
        wait_terminal(app, "https://a.example.com", Duration::from_secs(10)).await;
    assert_eq!(final_state["status"], "FAILED", "{final_state}");
    let detail = final_state["detail"].as_str().unwrap_or("");
    assert!(
        detail.contains("搜索失效"),
        "detail 必须保留已判「搜索失效」分组: {detail}"
    );
    assert!(
        detail.contains("发现规则求值失败") && detail.contains("discovery-boom"),
        "detail 必须包含 JS 求值失败消息: {detail}"
    );
    assert!(
        detail.starts_with("搜索失效 | "),
        "已判分组应位于 detail 首段: {detail}"
    );
    assert!(
        search_hits.load(Ordering::SeqCst) >= 1,
        "搜索校验应真实请求 mock（否则「搜索失效」来源不成立）"
    );
}

// ─── 批42：并行检验 ────────────────────────────────────────────────────────

/// 批42b P3-9：并行耗时与串行基线对比（替代固定绝对上界）
///
/// 同一批 3 源、每个请求 500ms：`config:checkThreadCount=1` 串行 ≈1500ms，
/// 并发 3 ≈500ms。断言「并行显著快于串行」而不是固定 1200ms 绝对上界，
/// 降低 CI 负载抖动导致的偶发失败；同时保留放宽的绝对上界（2500ms）
/// 防止并行退化为串行。
#[tokio::test]
async fn test_checks_run_in_parallel() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    let port = spawn_html_server(500, LIST_HTML).await;
    let mut sources = Vec::new();
    for index in 0..3 {
        let source = discovery_source(
            &format!("https://source{index}.example.com"),
            Some(format!("分类::http://127.0.0.1:{port}/list")),
        );
        seed_source(&state, source.clone()).await;
        sources.push(source);
    }
    let app = create_router(Arc::clone(&state));

    // 串行基线：并发数=1
    set_check_thread_count(&state, "1").await;
    let serial = run_check_and_wait(app.clone(), &sources).await;
    assert!(
        serial >= Duration::from_millis(1_200),
        "串行基线应≈3×500ms，实际 {serial:?}"
    );

    // 并行：并发数=3
    set_check_thread_count(&state, "3").await;
    let parallel = run_check_and_wait(app.clone(), &sources).await;
    assert!(
        parallel < Duration::from_millis(2_500),
        "并行绝对上界（防退化为串行），实际 {parallel:?}"
    );
    assert!(
        parallel + Duration::from_millis(400) < serial,
        "有界并发应显著快于串行：parallel={parallel:?} serial={serial:?}"
    );
}

/// 写入检验线程数配置（会话开始时读取）
async fn set_check_thread_count(state: &Arc<AppState>, value: &str) {
    let db = state.db.lock().await;
    CacheRepository::new(db.connection())
        .put("config:checkThreadCount", value, 0)
        .unwrap();
}

/// 启动一次检验并等待全部源进入终态，返回总耗时
async fn run_check_and_wait(app: axum::Router, sources: &[BookSource]) -> Duration {
    let started = std::time::Instant::now();
    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(sources, ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    for source in sources {
        let (final_state, _) = wait_terminal(
            app.clone(),
            &source.book_source_url,
            Duration::from_secs(20),
        )
        .await;
        assert_eq!(final_state["status"], "PASSED", "{final_state}");
    }
    started.elapsed()
}

/// 多源在途时停止：会话清空、全部源保持 NEEDS_CHECK（取消在途工作线程）
#[tokio::test]
async fn test_stop_cancels_parallel_checks() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    let port = spawn_hanging_server().await;
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:checkSourceTimeout", "5000", 0)
            .unwrap();
    }
    let mut sources = Vec::new();
    for index in 0..3 {
        let source = discovery_source(
            &format!("https://source{index}.example.com"),
            Some(format!("分类::http://127.0.0.1:{port}/list")),
        );
        seed_source(&state, source.clone()).await;
        sources.push(source);
    }
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&sources, ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let token = body["data"]["sessionToken"].as_str().unwrap().to_string();

    // 等待全部源排队（NEEDS_CHECK）且会话仍占用
    let mut running = false;
    for _ in 0..60 {
        let (_, body) = get_json(app.clone(), "/getBookSourceCheckStates").await;
        if body["data"]["sessionToken"] == token {
            let states = body["data"]["states"].as_array().unwrap();
            if states.iter().all(|s| s["status"] == "NEEDS_CHECK") {
                running = true;
                break;
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

    tokio::time::sleep(Duration::from_millis(200)).await;
    let (_, body) = get_json(app, "/getBookSourceCheckStates").await;
    assert!(body["data"]["sessionToken"].is_null());
    for index in 0..3 {
        let state_json = state_of(
            &body["data"]["states"],
            &format!("https://source{index}.example.com"),
        )
        .unwrap();
        assert_eq!(
            state_json["status"], "NEEDS_CHECK",
            "停止后在途源保持 NEEDS_CHECK: {state_json}"
        );
    }
}

// ─── 批42：源地址 TCP 探测（checkDomain） ──────────────────────────────────

#[tokio::test]
async fn test_check_domain_unreachable_fails() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    // 取一个已关闭的本地端口（bind 后立刻释放，连接必然拒绝）
    let port = {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        listener.local_addr().unwrap().port()
    };
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:checkDomain", "true", 0)
            .unwrap();
    }
    let source = BookSource {
        book_source_url: format!("http://127.0.0.1:{port}"),
        book_source_name: "不可达源".to_string(),
        ..BookSource::default()
    };
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) = wait_terminal(
        app,
        &format!("http://127.0.0.1:{port}"),
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(final_state["status"], "FAILED", "{final_state}");
    assert_eq!(
        final_state["detail"],
        "域名失效 | 校验失败:源地址不可访问 | // Error: 源地址不可访问"
    );
}

#[tokio::test]
async fn test_check_domain_reachable_passes() {
    let state = make_state();
    disable_token_requirement(&state).await;
    only_discovery_config(&state).await;
    // 本地监听端口 = 可达端点；计数连接数以证明 TCP 探测真实发生（P3-8）
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let connects = Arc::new(AtomicUsize::new(0));
    let connects_srv = Arc::clone(&connects);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            connects_srv.fetch_add(1, Ordering::SeqCst);
            drop(stream);
        }
    });
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:checkDomain", "true", 0)
            .unwrap();
    }
    let source = BookSource {
        book_source_url: format!("http://127.0.0.1:{port}"),
        book_source_name: "可达源".to_string(),
        ..BookSource::default()
    };
    seed_source(&state, source.clone()).await;
    let app = create_router(Arc::clone(&state));

    let (_, body) = post_json(
        app.clone(),
        "/startBookSourceCheck",
        &start_body(&[source], ""),
    )
    .await;
    assert_eq!(body["isSuccess"], true, "{body}");
    let (final_state, _) = wait_terminal(
        app,
        &format!("http://127.0.0.1:{port}"),
        Duration::from_secs(10),
    )
    .await;
    assert_eq!(final_state["status"], "PASSED", "{final_state}");
    assert!(
        connects.load(Ordering::SeqCst) >= 1,
        "checkDomain=true 应真实发起 TCP 探测（实际 {} 次连接）",
        connects.load(Ordering::SeqCst)
    );
}

// ─── 令牌头路径（required=true 且令牌正确） ─────────────────────────────────

/// 批30b P3-6：路由级令牌守卫挂载后，大 body（> axum 默认 2MB）无令牌请求
/// 仍返回原版失败信封而非 413——证明 16MB 上限已随源写挂载组生效，且守卫
/// 在 body 提取前拒绝。
#[tokio::test]
async fn test_token_guard_rejects_large_body_without_reading() {
    let state = make_state();
    let app =
        attach_source_write_token_guard(create_router(Arc::clone(&state)), Arc::clone(&state));
    let big = format!(
        "{{\"sources\":[],\"padding\":\"{}\"}}",
        "x".repeat(3 * 1024 * 1024)
    );
    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/startBookSourceCheck")
                .header("Content-Type", "application/json")
                .body(Body::from(big))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK, "应走原版信封而非 413");
    assert_eq!(
        resp.headers()
            .get("connection")
            .and_then(|v| v.to_str().ok()),
        Some("close")
    );
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["isSuccess"], false);
    assert_eq!(body["errorMsg"], "Web 书源访问令牌未配置或不正确");
}

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
