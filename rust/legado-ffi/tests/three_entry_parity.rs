//! [P1-1 项5 | 任务 B 2026-09-19] 三入口一致性测试
//!
//! 同一输入分别经过 `search_books` / `multi_source_search` / `run_multi_stream`
//! （全批次收集），断言最终结果集、origins、逐源内书籍顺序、originOrder 完全一致；
//! 流式入口只允许「批次到达顺序」不同（同一次运行内逐源推送，源内顺序不变）。
//!
//! 基建：
//! - 复用既有 s0 夹具（`tests/fixtures/search_s0/`），测试内启动 127.0.0.1 本地
//!   HTTP 夹具服务器投递（与 `src/api/s0_fixture_tests.rs` 同模式：单连接循环 +
//!   `{PORT}` 回填）；
//! - 书源经 `add_source` 写入内存 DB（`init_in_memory_database` + `db_state::init_database`
//!   全局池 first-wins）；
//! - 三入口均走进程共享 HTTP 客户端（默认配置），按 P2-17 经验先
//!   `NO_PROXY=127.0.0.1,localhost` + `reset_shared_client()`，防宿主代理劫持回环流量；
//! - `search_books` / `multi_source_search` 内部使用 `runtime::block_on`，本文件为
//!   普通 `#[test]`（非 `#[tokio::test]`），`run_multi_stream` 同样以
//!   `legado_ffi::runtime::block_on` 驱动并收集全部批次。
//!
//! originOrder 一致性仅在 `search_books` 与 `run_multi_stream` 之间断言：
//! `multi_source_search` 的输出 DTO（`AnnotatedCandidate`）契约上不带
//! originOrder 字段（加法式超集设计），属契约级已知差异而非语义差异
//! （随任务报告 §⑤ 披露）。
//!
//! 逐源错误八分类联动（P2 项1）：成功批次 `error_class == "ok"` 且无 `error`；
//! login 失败批次（quickjs 档）`error_class == "login_required"` 且保留 `error` 文案。
//!
//! 注意（P3-6 A 语义变更，2026-09-19，任务 A WIP）：loginCheckJs 语义对齐原版
//! `as StrResponse` 对象判定后，`login_check_pass` 夹具的旧谓词
//! `result.code() == 200` 返回裸布尔 → cast 失败 → 整源失败，夹具期望已由
//! kind=ok 改为 kind=login_required（见夹具 manifest 的 semantic_change_note）。
//! 本测试按夹具 `expected_original.json` 的 kind 分支断言，不硬依赖任务 A 的
//! 合入状态（ok / login_required 两分支均已覆盖）。

use std::collections::{BTreeMap, HashSet};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::{Arc, Mutex};

use serde::Deserialize;

const FIXTURE_ROOT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixtures/search_s0");

/// 全部测试串行：共享全局内存 DB、共享 HTTP 客户端单例与 `NO_PROXY` 环境变量，
/// 并行会互相污染（与 http_state / db_state 内部测试的串行锁同一动机）
static TEST_LOCK: Mutex<()> = Mutex::new(());

// ─── 夹具服务器（与 s0_fixture_tests.rs 同模式）──────────────────────────────

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Route {
    path: String,
    status: u16,
    #[serde(default)]
    body_from: Option<String>,
    #[serde(default)]
    redirect_location: Option<String>,
}

#[derive(Deserialize)]
struct RequestSpec {
    keyword: String,
    serve: Vec<Route>,
}

#[derive(Deserialize)]
struct ExpectedSpec {
    kind: String,
    #[serde(default)]
    count: usize,
}

/// 单连接夹具服务器：按 request.json 的 serve 表投递固定响应
fn spawn_fixture_server(routes: Vec<Route>, root: String) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 夹具服务器");
    let port = listener.local_addr().unwrap().port();
    // 绑定后回填路由中的 {PORT} 占位（绝对 Location 等）
    let port_str = port.to_string();
    let routes: Vec<Route> = routes
        .into_iter()
        .map(|mut r| {
            if let Some(loc) = r.redirect_location.take() {
                r.redirect_location = Some(loc.replace("{PORT}", &port_str));
            }
            r
        })
        .collect();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            handle_conn(&mut stream, &routes, &root);
        }
    });
    port
}

fn handle_conn(stream: &mut TcpStream, routes: &[Route], root: &str) {
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    // 读请求头（到空行为止）
    while !buf.ends_with(b"\r\n\r\n") {
        match stream.read(&mut byte) {
            Ok(1) => buf.push(byte[0]),
            _ => return,
        }
        if buf.len() > 16 * 1024 {
            return;
        }
    }
    let head = String::from_utf8_lossy(&buf);
    let path = head.split_whitespace().nth(1).unwrap_or("/").to_string();
    let path_only = path.split('?').next().unwrap_or("/").to_string();

    let route = routes.iter().find(|r| r.path == path_only);
    let (status, headers, body) = match route {
        Some(r) if r.status == 302 || r.status == 301 => {
            let loc = r.redirect_location.clone().unwrap_or_default();
            (r.status, format!("Location: {loc}\r\n"), Vec::new())
        }
        Some(r) => {
            let body = match &r.body_from {
                Some(f) => std::fs::read(format!("{root}/{f}")).unwrap_or_default(),
                None => Vec::new(),
            };
            (
                r.status,
                "Content-Type: text/html; charset=utf-8\r\n".to_string(),
                body,
            )
        }
        None => (404, String::new(), b"not found".to_vec()),
    };
    let resp = format!(
        "HTTP/1.1 {status} OK\r\n{headers}Content-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.write_all(&body);
    let _ = stream.flush();
}

// ─── 环境装配 ─────────────────────────────────────────────────────────────────

/// 测试环境装配（幂等，全局池 first-wins）：
/// 内存 DB + 全局连接池 + `NO_PROXY` + 共享客户端重置
fn setup_env() {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("内存数据库初始化");
    // 仅首次调用生效（OnceLock first-wins），后续测试复用同一池
    legado_ffi::db_state::init_database(db).expect("全局连接池初始化");
    // P2-17 经验：夹具流量全走 127.0.0.1 回环，共享客户端（默认配置）会随宿主
    // env/系统代理路由；reqwest 构建时读取 NO_PROXY，重置单例令新客户端生效
    std::env::set_var("NO_PROXY", "127.0.0.1,localhost");
    legado_ffi::http_state::reset_shared_client();
}

/// 载入场景夹具并装配书源：启动服务器、回填 `{PORT}` 写入内存 DB
///
/// 返回（关键词、bookSourceUrl、期望条数、期望类别）
fn setup_scenario(scenario: &str) -> (String, String, usize, String) {
    let root_dir = format!("{FIXTURE_ROOT}/{scenario}");
    let request: RequestSpec =
        serde_json::from_str(&std::fs::read_to_string(format!("{root_dir}/request.json")).unwrap())
            .unwrap();
    let expected: ExpectedSpec = serde_json::from_str(
        &std::fs::read_to_string(format!("{root_dir}/expected_original.json")).unwrap(),
    )
    .unwrap();

    let port = spawn_fixture_server(request.serve, root_dir.clone());
    let source_json = std::fs::read_to_string(format!("{root_dir}/source.json"))
        .unwrap()
        .replace("{PORT}", &port.to_string());
    let source_url = serde_json::from_str::<serde_json::Value>(&source_json).unwrap()
        ["bookSourceUrl"]
        .as_str()
        .unwrap()
        .to_string();
    legado_ffi::api::source::add_source(&source_json).expect("夹具书源写入");

    (request.keyword, source_url, expected.count, expected.kind)
}

// ─── 三入口驱动 ───────────────────────────────────────────────────────────────

/// 归一化书籍标识：(书源 URL, 书名, 作者, bookUrl)
type BookKey = (String, String, String, String);

/// 流式入口的一个批次（解析自 `SearchSourceBatch` JSON）
#[derive(Debug)]
struct StreamBatch {
    source_url: String,
    /// 批次内书籍（源内顺序）：(书名, 作者, bookUrl, originOrder)
    books: Vec<(String, String, String, i32)>,
    error: Option<String>,
    error_class: String,
    is_last: bool,
    total_count: usize,
}

#[derive(Debug)]
struct EntryResults {
    /// `search_books`：(书籍标识, originOrder)，结果顺序
    sync: Vec<(BookKey, i32)>,
    /// `multi_source_search`：书籍标识，结果顺序（契约不带 originOrder）
    multi: Vec<BookKey>,
    /// `run_multi_stream`：按批次到达顺序
    stream_batches: Vec<StreamBatch>,
}

fn run_three_entries(keyword: &str, source_urls_json: &str) -> EntryResults {
    // 入口 1：search_books（同步包装，内部 block_on；逐源失败隔离不阻断整体）
    let r1 = legado_ffi::api::search::search_books(keyword, source_urls_json)
        .expect("search_books 执行失败");
    let sync: Vec<(BookKey, i32)> = r1
        .iter()
        .map(|r| {
            (
                (
                    r.source_url.clone(),
                    r.book_name.clone(),
                    r.author.clone(),
                    r.book_url.clone(),
                ),
                r.origin_order,
            )
        })
        .collect();

    // 入口 2：multi_source_search（同步包装，输出 AnnotatedCandidate JSON 数组）
    let r2 = legado_ffi::api::search::multi_source_search(keyword, source_urls_json)
        .expect("multi_source_search 执行失败");
    let multi: Vec<BookKey> = serde_json::from_str::<Vec<serde_json::Value>>(&r2)
        .unwrap_or_default()
        .into_iter()
        .map(|v| {
            (
                v["source_url"].as_str().unwrap_or_default().to_string(),
                v["book_name"].as_str().unwrap_or_default().to_string(),
                v["author"].as_str().unwrap_or_default().to_string(),
                v["book_url"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect();

    // 入口 3：run_multi_stream（async，block_on 驱动；收集全部批次 JSON）
    let batches = Arc::new(Mutex::new(Vec::new()));
    {
        let sink = Arc::clone(&batches);
        legado_ffi::runtime::block_on(async move {
            legado_ffi::api::search::run_multi_stream(
                keyword.to_string(),
                source_urls_json.to_string(),
                1,
                move |json| {
                    sink.lock().unwrap().push(json);
                    Ok(())
                },
            )
            .await;
        });
    }
    let raw_batches = batches.lock().unwrap().clone();
    let stream_batches: Vec<StreamBatch> = raw_batches
        .iter()
        .map(|json_str| {
            let v: serde_json::Value = serde_json::from_str(json_str).unwrap();
            StreamBatch {
                source_url: v["source_url"].as_str().unwrap_or_default().to_string(),
                books: v["books"]
                    .as_array()
                    .map(|arr| {
                        arr.iter()
                            .map(|b| {
                                (
                                    b["name"].as_str().unwrap_or_default().to_string(),
                                    b["author"].as_str().unwrap_or_default().to_string(),
                                    b["bookUrl"].as_str().unwrap_or_default().to_string(),
                                    b["originOrder"].as_i64().unwrap_or(0) as i32,
                                )
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                error: v["error"].as_str().map(|s| s.to_string()),
                error_class: v["error_class"].as_str().unwrap_or_default().to_string(),
                is_last: v["is_last"].as_bool().unwrap_or(false),
                total_count: v["total_count"].as_u64().unwrap_or(0) as usize,
            }
        })
        .collect();

    EntryResults {
        sync,
        multi,
        stream_batches,
    }
}

// ─── 一致性断言 ───────────────────────────────────────────────────────────────

/// 三入口最终结果集 / origins / 逐源内顺序 / originOrder 完全一致
fn assert_parity(out: &EntryResults, expected_count: usize) {
    // 最终结果集（三入口必须完全一致；流式只允许批次到达顺序不同）
    let set_sync: HashSet<BookKey> = out.sync.iter().map(|(k, _)| k.clone()).collect();
    let set_multi: HashSet<BookKey> = out.multi.iter().cloned().collect();
    let set_stream: HashSet<BookKey> = out
        .stream_batches
        .iter()
        .flat_map(|b| {
            b.books
                .iter()
                .map(|(n, a, u, _)| (b.source_url.clone(), n.clone(), a.clone(), u.clone()))
        })
        .collect();

    assert_eq!(
        set_sync.len(),
        expected_count,
        "search_books 条数与夹具期望不符: actual={set_sync:?} expected_count={expected_count}"
    );
    assert_eq!(
        set_sync, set_multi,
        "multi_source_search 最终集合与 search_books 不一致: sync={set_sync:?} multi={set_multi:?}"
    );
    assert_eq!(
        set_sync, set_stream,
        "run_multi_stream 最终集合与 search_books 不一致: sync={set_sync:?} stream={set_stream:?}"
    );

    // origins（书源 URL 集合）三入口一致
    let origins_sync: HashSet<String> = set_sync.iter().map(|k| k.0.clone()).collect();
    let origins_multi: HashSet<String> = set_multi.iter().map(|k| k.0.clone()).collect();
    let origins_stream: HashSet<String> = out
        .stream_batches
        .iter()
        .map(|b| b.source_url.clone())
        .collect();
    assert_eq!(
        origins_sync, origins_multi,
        "origins 不一致 (multi_source_search)"
    );
    assert_eq!(
        origins_sync, origins_stream,
        "origins 不一致 (run_multi_stream，含失败源批次)"
    );

    // 逐源内书籍顺序（夹具均为单源，故展平序列即逐源内顺序；
    // 多源时流式展平顺序为批次到达顺序，只允许跨源到达顺序不同）
    let order_sync: Vec<(String, String)> = out
        .sync
        .iter()
        .map(|(k, _)| (k.0.clone(), k.3.clone()))
        .collect();
    let order_multi: Vec<(String, String)> = out
        .multi
        .iter()
        .map(|k| (k.0.clone(), k.3.clone()))
        .collect();
    let order_stream: Vec<(String, String)> = out
        .stream_batches
        .iter()
        .flat_map(|b| {
            b.books
                .iter()
                .map(|(_, _, u, _)| (b.source_url.clone(), u.clone()))
        })
        .collect();
    assert_eq!(
        order_sync, order_multi,
        "逐源内书籍顺序不一致 (multi_source_search): sync={order_sync:?} multi={order_multi:?}"
    );
    assert_eq!(
        order_sync, order_stream,
        "逐源内书籍顺序不一致 (run_multi_stream): sync={order_sync:?} stream={order_stream:?}"
    );

    // originOrder 一致性（仅 search_books 与 run_multi_stream；
    // multi_source_search 契约不带该字段，见文件头说明）
    let oo_sync: BTreeMap<(String, String), i32> = out
        .sync
        .iter()
        .map(|(k, o)| ((k.0.clone(), k.3.clone()), *o))
        .collect();
    let oo_stream: BTreeMap<(String, String), i32> = out
        .stream_batches
        .iter()
        .flat_map(|b| {
            b.books
                .iter()
                .map(|(_, _, u, o)| ((b.source_url.clone(), u.clone()), *o))
        })
        .collect();
    assert_eq!(
        oo_sync, oo_stream,
        "originOrder 不一致: sync={oo_sync:?} stream={oo_stream:?}"
    );
}

// ─── 场景测试 ─────────────────────────────────────────────────────────────────

/// 3xx 重定向（解析基准 = 最终 URL）：三入口对 302 → 列表页 → 相对链接绝对化
/// 的完整链路结果必须完全一致
#[test]
fn three_entry_parity_redirect_final_url() {
    // 锁投毒容错：单个测试 panic 不级联污染其余测试（P2-16 WIP 冲突场景下更稳）
    let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    setup_env();
    let (keyword, source_url, count, kind) = setup_scenario("redirect_final_url");
    assert_eq!(kind, "ok");

    let out = run_three_entries(&keyword, &format!("[\"{source_url}\"]"));
    assert_parity(&out, count);

    // 成功批次：error_class == "ok" 且无 error（P2 项1 八分类联动）
    assert_eq!(out.stream_batches.len(), 1, "单源应恰好推送一个批次");
    let batch = &out.stream_batches[0];
    assert_eq!(
        batch.error_class, "ok",
        "成功批次 error_class 应为 ok: {batch:?}"
    );
    assert!(batch.error.is_none(), "成功批次不应携带 error: {batch:?}");
    assert!(batch.is_last, "唯一批次应为 is_last");
    assert_eq!(batch.total_count, 1);
}

/// bookUrlPattern 存在但不命中：列表解析路径（BookList.kt 后续）三入口一致
#[test]
fn three_entry_parity_book_url_pattern_miss() {
    let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    setup_env();
    let (keyword, source_url, count, kind) = setup_scenario("book_url_pattern_miss");
    assert_eq!(kind, "ok");

    let out = run_three_entries(&keyword, &format!("[\"{source_url}\"]"));
    assert_parity(&out, count);

    let batch = &out.stream_batches[0];
    assert_eq!(
        batch.error_class, "ok",
        "成功批次 error_class 应为 ok: {batch:?}"
    );
    assert!(batch.error.is_none());
}

// ─── loginCheckJs 双路径（需 quickjs）────────────────────────────────────────

#[cfg(feature = "quickjs")]
#[test]
fn three_entry_parity_login_check_pass() {
    let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    setup_env();
    let (keyword, source_url, count, kind) = setup_scenario("login_check_pass");

    // P3-6 A 语义变更后，本夹具期望可能是 kind=login_required（旧谓词返回裸布尔
    // → cast 失败 → 整源失败）；任务 A 若回退/合并旧谓词语义则回到 kind=ok。
    // 两种状态都断言「三入口一致 + 批次八分类与夹具期望一致」。
    let out = run_three_entries(&keyword, &format!("[\"{source_url}\"]"));
    match kind.as_str() {
        "ok" => {
            assert_parity(&out, count);
            assert_eq!(out.stream_batches.len(), 1, "单源应恰好推送一个批次");
            let batch = &out.stream_batches[0];
            assert_eq!(
                batch.error_class, "ok",
                "login 通过批次 error_class 应为 ok: {batch:?}"
            );
            assert!(batch.error.is_none());
        }
        "login_required" => {
            // 三入口最终书籍集合一致（均为空：失败源在任何入口都不贡献书籍）。
            // 注意：不做 origins 集合相等断言——失败批次仍携带 source_url
            // （批次级错误隔离语义），同步/多源入口的空结果无 origins 可言，
            // 这是流式入口契约上的合法差异（流式批次恒带源标识）。
            assert!(out.sync.is_empty(), "登录失败：search_books 应返回空集");
            assert!(
                out.multi.is_empty(),
                "登录失败：multi_source_search 应返回空数组"
            );
            assert!(
                out.stream_batches.iter().all(|b| b.books.is_empty()),
                "登录失败：流式批次不应携带书籍"
            );
            assert_eq!(
                out.stream_batches.len(),
                1,
                "失败源也推送批次（批次级错误隔离语义）"
            );
            let batch = &out.stream_batches[0];
            assert_eq!(
                batch.source_url, source_url,
                "失败批次应归属夹具书源（批次恒带源标识）"
            );
            assert_eq!(
                batch.error_class, "login_required",
                "P3-6 A 新语义：谓词返回裸布尔 → cast 失败 → 整源失败（实际文案: {:?}）",
                batch.error
            );
            assert!(
                batch.error.is_some(),
                "失败批次应携带 error 文案（现有字段语义保留）"
            );
            assert!(
                batch.is_last,
                "单源失败批次应为 is_last（finished=1 ≥ total=0）"
            );
        }
        other => panic!("夹具期望 kind 非 ok/login_required: {other}"),
    }
}

#[cfg(feature = "quickjs")]
#[test]
fn three_entry_parity_login_check_required() {
    let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    setup_env();
    let (keyword, source_url, _count, kind) = setup_scenario("login_check_required");
    assert_eq!(kind, "login_required");

    let out = run_three_entries(&keyword, &format!("[\"{source_url}\"]"));
    // 单源登录失败静默不中断整体：三入口最终集合一致（均为空）
    assert!(out.sync.is_empty(), "登录失败：search_books 应返回空集");
    assert!(
        out.multi.is_empty(),
        "登录失败：multi_source_search 应返回空数组"
    );
    assert_eq!(
        out.stream_batches.len(),
        1,
        "失败源也推送批次（批次级错误隔离语义）"
    );
    let batch = &out.stream_batches[0];
    assert_eq!(
        batch.source_url, source_url,
        "失败批次应归属夹具书源（批次恒带源标识）"
    );
    assert_eq!(
        batch.error_class, "login_required",
        "批次八分类应为 login_required（实际: {:?}）",
        batch.error
    );
    // 冻结约束：error 字段语义保留——失败批次携带错误文案
    assert!(
        batch.error.is_some(),
        "失败批次应携带 error 文案（现有字段语义保留）"
    );
    assert!(batch.books.is_empty());
    assert!(
        batch.is_last,
        "单源失败批次应为 is_last（finished=1 ≥ total=0）"
    );
}
