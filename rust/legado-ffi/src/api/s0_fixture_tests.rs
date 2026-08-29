//! [S0-B] 四类离线响应夹具消费测试
//!
//! 夹具位于 `tests/fixtures/search_s0/<scenario>/`（source.json / request.json /
//! response.bin / redirect_chain.json / expected_original.json / manifest.json），
//! 由本文件在测试内启动的本地 HTTP 夹具服务器投递，交由 **Flutter 主生产搜索单源
//! 执行器** `search_single_source` 消费，并以 expected_original.json（原版
//! WebBook.kt / BookList.kt 语义基准）断言。跨包验收（原版 App 导入同一夹具书源）
//! 见 S0-C 流程。
//!
//! 场景与审计依据（SEARCH_PARITY_S0_AUDIT_RESULT_20260828.md §四 S0-B）：
//! - login_check_pass / login_check_required（loginCheckJs 成功/失败，quickjs）
//! - redirect_final_url（3xx → 解析基准 = 最终 URL）
//! - book_url_pattern_hit / book_url_pattern_miss（详情直连 / 列表解析）
//! - empty_list_detail_fallback / empty_list_unparseable（空列表回退 / 明确空结果）

#![cfg(test)]

use super::search::search_single_source;
use crate::http_state::shared_client;
use legado_core::models::book_source::BookSource;
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

const FIXTURE_ROOT: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/search_s0"
);

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

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct ExpectedResult {
    name: String,
    #[serde(default)]
    author: String,
    #[serde(default)]
    book_url: String,
}

#[derive(Deserialize, Serialize)]
struct Expected {
    kind: String,
    #[serde(default)]
    count: usize,
    #[serde(default)]
    results: Vec<ExpectedResult>,
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
    let path = head
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string();
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
            (r.status, "Content-Type: text/html; charset=utf-8\r\n".to_string(), body)
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

/// 读夹具并跑一个场景：返回（期望, 主执行器实际输出）
async fn run_scenario(scenario: &str) -> (Expected, String, Expected) {
    let root_dir = format!("{FIXTURE_ROOT}/{scenario}");
    let request: RequestSpec = serde_json::from_str(
        &std::fs::read_to_string(format!("{root_dir}/request.json")).unwrap(),
    )
    .unwrap();
    let expected: Expected = serde_json::from_str(
        &std::fs::read_to_string(format!("{root_dir}/expected_original.json")).unwrap(),
    )
    .unwrap();

    let port = spawn_fixture_server(request.serve.clone(), root_dir.clone());

    // 书源：searchUrl 的 {PORT} 替换为测试服务器端口（双包消费时同理替换为其可达地址）
    let source_json = std::fs::read_to_string(format!("{root_dir}/source.json"))
        .unwrap()
        .replace("{PORT}", &port.to_string());
    let source: BookSource = serde_json::from_str(&source_json).unwrap();

    let client = shared_client().expect("共享 HTTP 客户端");
    let outcome = search_single_source(&client, &source, &request.keyword, 1, false).await;

    let base = format!("http://127.0.0.1:{port}");
    // 期望中的 {BASE} 占位替换为实际夹具服务器地址
    let expected_sub = serde_json::from_str::<Expected>(
        &serde_json::to_string(&expected).unwrap().replace(
            "{BASE}",
            &format!("http://127.0.0.1:{port}"),
        ),
    )
    .unwrap();

    let actual = match &outcome {
        Ok(items) => serde_json::json!({
            "kind": "ok",
            "count": items.len(),
            "results": items.iter().map(|r| serde_json::json!({
                "name": r.book_name,
                "author": r.author,
                "bookUrl": r.book_url,
            })).collect::<Vec<_>>(),
        }),
        Err(e) => serde_json::json!({
            "kind": if matches!(e, legado_core::LegadoError::LoginRequired(_)) {
                "login_required"
            } else {
                "error"
            },
            "error": e.to_string(),
        }),
    }
    .to_string();

    (expected_sub, actual, expected)
}

fn assert_matches_expected(expected: &Expected, actual_json: &str) {
    let actual: serde_json::Value = serde_json::from_str(actual_json).unwrap();
    assert_eq!(
        actual["kind"], expected.kind,
        "结果类别不一致: actual={actual}"
    );
    if expected.kind != "ok" {
        return;
    }
    assert_eq!(
        actual["count"].as_u64().map(|v| v as usize),
        Some(expected.count),
        "条数不一致: actual={actual}"
    );
    for (i, want) in expected.results.iter().enumerate() {
        assert_eq!(actual["results"][i]["name"], want.name, "第{i}条书名不一致");
        if !want.author.is_empty() {
            assert_eq!(actual["results"][i]["author"], want.author, "第{i}条作者不一致");
        }
        if !want.book_url.is_empty() {
            assert_eq!(
                actual["results"][i]["bookUrl"], want.book_url,
                "第{i}条 bookUrl 不一致"
            );
        }
    }
}


#[tokio::test]
async fn s0b_redirect_final_url() {
    let (expected, actual, _) = run_scenario("redirect_final_url").await;
    assert_matches_expected(&expected, &actual);
}

#[tokio::test]
async fn s0b_book_url_pattern_hit() {
    let (expected, actual, _) = run_scenario("book_url_pattern_hit").await;
    assert_matches_expected(&expected, &actual);
}

#[tokio::test]
async fn s0b_book_url_pattern_miss() {
    let (expected, actual, _) = run_scenario("book_url_pattern_miss").await;
    assert_matches_expected(&expected, &actual);
}

#[tokio::test]
async fn s0b_empty_list_detail_fallback() {
    let (expected, actual, _) = run_scenario("empty_list_detail_fallback").await;
    assert_matches_expected(&expected, &actual);
}

#[tokio::test]
async fn s0b_empty_list_unparseable() {
    let (expected, actual, _) = run_scenario("empty_list_unparseable").await;
    assert_matches_expected(&expected, &actual);
}

// ── loginCheckJs 双路径（需 quickjs）────────────────────────────────

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn s0b_login_check_pass() {
    let (expected, actual, _) = run_scenario("login_check_pass").await;
    assert_matches_expected(&expected, &actual);
}

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn s0b_login_check_required() {
    let (expected, actual, _) = run_scenario("login_check_required").await;
    assert_matches_expected(&expected, &actual);
}
