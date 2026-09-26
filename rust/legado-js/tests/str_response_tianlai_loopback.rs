//! 天籁小说 `java.connect` StrResponse 桥回归测试（quickjs 档，本地回环 e2e）
//!
//! 根因（取证定稿）：`RESPONSE_BRIDGE_JS.__strResponse`（`java.connect` 返回值
//! 桥，`rust/legado-js/src/host_api/quickjs_impl.rs`）缺顶层 `code()` 方法，
//! 且 `body` 是普通属性——上游 `StrResponse`（Kotlin）两者均为方法
//! （`fun code(): Int` / `fun body() = body`）。天籁 searchUrl 的
//! `res.code() == 403` 分支与 `res = res.body()` 在本引擎上会抛
//! `not a function`，整条搜索规则失败。另 `raw().headers(name)` 不接受参数，
//! 403 分支 `res.raw().headers("Set-Cookie")[0]` 无法取 cookie 重连。
//!
//! 本批次红→绿（修复面）：
//! - 顶层 `code()` 方法（镜像 `__resp.statusCode` 与上游 L67）；
//! - `body` 属性 → `body()` 方法（镜像 `__resp.body` 与上游 L65）。**有意
//!   偏离**：爱丽丝书屋#61 语料以 `.body` 属性读取（该源在上游原版侧
//!   同样不兼容），双基线「功能=原版侧」取上游方法形态，已在提交说明登记；
//! - `raw().headers(name)`：带参 → `[值]` 数组（镜像 `__resp.headers`
//!   okhttp3 语义，天籁 `res.raw().headers("Set-Cookie")[0]` 取 cookie），
//!   无参 → 全量头 map；`raw()` 保留 `request().url()` / `code()` 面
//!   （上游 L53 `fun raw()` 返回 okhttp3 Response 语义）。
//!
//! Mock：本地回环 HTTP/1.1 单线程服务（`std::TcpListener`，无外网依赖、
//! 不加 `#[ignore]`，模式同 quickjs_impl.rs `spawn_search_loopback_server`）：
//! - `/direct302` → 302 + `Set-Cookie`（**无 Location**：reqwest 无 Location
//!   的 302 无从跟随、按原样返回——这是 `java.connect`（跟随池）下能字面
//!   断言 `res.code()===302` 的唯一形态；若 302 带 Location 必被跟随至终态）；
//! - `/redirect` → 302 + `Set-Cookie` + `Location: /page`，`/page` → 200 页面
//!   （回环池 `follow_redirects: true`，断言跟随至终态 200 的最终 URL/正文）。

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};

use legado_js::engine::{JsEngine, JsValue};
use legado_js::host_api::current_source;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;

// 注：Response 桥（RESPONSE_BRIDGE_JS）由引擎创建时自动注入
// （register_all_apis → inject_response_bridge）；本测试不得再次 eval
// 该桥——二次注入时 `__nativeConnectFull = java.connect` 会捕获首层
// 包装器的引用，其对象返回值进入 `JSON.parse` 必失败 → 全空响应
// （code 0 / 空 body / 空 URL），天籁 403 分支字面断言全部失真。

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// 按请求线路由的固定响应（天籁 403 分支语义的确定性替身）
fn route_response(request: &str) -> String {
    let line = request.lines().next().unwrap_or_default();
    if line.starts_with("GET /direct302") {
        // 302 无 Location：跟随池无从跳转，reqwest 原样返回 302
        let body = "302-body";
        format!(
            "HTTP/1.1 302 Found\r\nSet-Cookie: sid=direct456; Path=/\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
    } else if line.starts_with("GET /redirect") {
        // 302 带 Location：java.connect 必跟随至 /page 终态 200
        "HTTP/1.1 302 Found\r\nSet-Cookie: sid=redir789; Path=/\r\nLocation: /page\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            .to_string()
    } else if line.starts_with("GET /page") {
        let body = "<html><body><div id=\"post\">天籁页面</div></body></html>";
        format!(
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
    } else {
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
    }
}

/// 最小本地回环 HTTP/1.1 服务（逐字节读到 `\r\n\r\n` 头 + Content-Length body，
/// 每连接处理一个请求；`std::TcpListener` 单线程，legado-js 的 quickjs tokio
/// feature 无 net）
fn spawn_tianlai_loopback_server(max_conns: usize) -> std::net::SocketAddr {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        for stream in listener.incoming().take(max_conns) {
            let Ok(mut sock) = stream else { continue };
            let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
            let Some(request) = read_http_request(&mut sock) else {
                continue;
            };
            let resp = route_response(&request);
            let _ = sock.write_all(resp.as_bytes());
        }
    });
    addr
}

/// 读取一个完整 HTTP/1.1 请求（头到 `\r\n\r\n` + Content-Length body）
fn read_http_request(sock: &mut std::net::TcpStream) -> Option<String> {
    let mut buf: Vec<u8> = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        sock.read_exact(&mut byte).ok()?;
        buf.push(byte[0]);
    }
    let head = String::from_utf8_lossy(&buf).into_owned();
    let content_length = head
        .lines()
        .find_map(|line| {
            line.to_ascii_uppercase()
                .strip_prefix("CONTENT-LENGTH:")?
                .trim()
                .parse::<usize>()
                .ok()
        })
        .unwrap_or(0);
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        sock.read_exact(&mut body).ok()?;
    }
    Some(format!("{head}{}", String::from_utf8_lossy(&body)))
}

/// 绿态：`res.code()===302` 字面断言 + `raw().headers('Set-Cookie')[0]` 命中
/// + `res.body` 是函数且 `res.body()` 返回响应体（天籁 403 分支同款用法）。
///
/// 无 Location 的 302 由跟随池原样返回（reqwest 无从跳转），故终态即 302。
#[test]
fn str_response_code_302_and_cookie_header_face() {
    let addr = spawn_tianlai_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/direct302");
    current_source::with_current_source_tag("e2e.str_response.tianlai.302", || {
        let script = r#"
var res = java.connect(url);
JSON.stringify({
  code: res.code(),
  cookie: res.raw().headers('Set-Cookie')[0],
  bodyType: typeof res.body,
  body: res.body(),
  finalUrl: res.raw().request().url()
})
"#;
        let out: String =
            JsEngine::eval_with_bindings(&engine, script, &[("url", JsValue::String(url.clone()))])
                .expect("java.connect 302 用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(v["code"], 302, "无 Location 的 302 应原样返回; 观测: {out}");
        assert_eq!(
            v["cookie"], "sid=direct456; Path=/",
            "raw().headers('Set-Cookie')[0] 应命中 302 响应头; 观测: {out}"
        );
        assert_eq!(v["bodyType"], "function", "body 应为方法; 观测: {out}");
        assert_eq!(
            v["body"], "302-body",
            "body() 应返回 302 响应体; 观测: {out}"
        );
        assert!(
            v["finalUrl"].as_str().unwrap().ends_with("/direct302"),
            "raw().request().url() 应为响应 URL; 观测: {out}"
        );
    });
}

/// 绿态：302 带可跟随 `Location` 时 `java.connect`（回环池
/// `follow_redirects: true`）必跟随至终态 200——最终 URL/正文跟随断言
/// （天籁搜索主流程「拿 cookie 重连」后的正常 200 形态）。
#[test]
fn str_response_follows_redirect_to_final_200() {
    let addr = spawn_tianlai_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/redirect");
    current_source::with_current_source_tag("e2e.str_response.tianlai.follow", || {
        let script = r#"
var res = java.connect(url);
JSON.stringify({
  code: res.code(),
  hasPage: res.body().indexOf('天籁页面') >= 0,
  finalUrl: res.raw().request().url()
})
"#;
        let out: String =
            JsEngine::eval_with_bindings(&engine, script, &[("url", JsValue::String(url.clone()))])
                .expect("java.connect 重定向用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(v["code"], 200, "跟随 Location 后终态应为 200; 观测: {out}");
        assert_eq!(v["hasPage"], true, "终态正文应为 /page 页面; 观测: {out}");
        assert!(
            v["finalUrl"].as_str().unwrap().ends_with("/page"),
            "最终 URL 应跟随至 /page; 观测: {out}"
        );
    });
}

/// 绿态（回归守护）：`raw().headers()` 无参形态保持全量头 map（镜像
/// `__resp.headers` 无参分支）——带参改数组后无参语义不得漂移。
/// map 键为小写（reqwest 头名规范化；带参 `headers(name)` 大小写不敏感）。
#[test]
fn str_response_headers_no_arg_returns_map() {
    let addr = spawn_tianlai_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/direct302");
    current_source::with_current_source_tag("e2e.str_response.tianlai.map", || {
        let script = r#"
var res = java.connect(url);
var h = res.raw().headers();
JSON.stringify({ cookie: h['set-cookie'], miss: (h['x-none'] === undefined) })
"#;
        let out: String =
            JsEngine::eval_with_bindings(&engine, script, &[("url", JsValue::String(url.clone()))])
                .expect("java.connect headers map 用例执行失败");
        let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
        assert_eq!(
            v["cookie"], "sid=direct456; Path=/",
            "无参 headers() 应为全量头 map（键小写规范化）; 观测: {out}"
        );
        assert_eq!(
            v["miss"], true,
            "map 形态下未命中键应为 undefined; 观测: {out}"
        );
    });
}
