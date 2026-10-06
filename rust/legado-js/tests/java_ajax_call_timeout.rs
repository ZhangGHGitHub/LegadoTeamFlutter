//! `java.ajax(url, callTimeout)` 第二参透传回归（quickjs 档，本地回环 e2e）
//!
//! 原版语义（`app/src/main/java/io/legado/app/help/JsExtensions.kt:130-137`）：
//! `ajax(url: Any, callTimeout: Long?)` 把 callTimeout 传给 `AnalyzeUrl`
//! （JsExtensions.kt:140），最终由 OkHttp `callTimeout(it, TimeUnit.MILLISECONDS)`
//! 生效（`AnalyzeUrlNetworkOptions.kt:117-119`）。单位毫秒；`null`/缺省 →
//! 全局默认；`0` → OkHttp 语义「不设 call timeout」；`< 0` 或
//! `> Integer.MAX_VALUE` → OkHttp `checkDuration` 抛 IllegalArgumentException，
//! 被 `ajax` 的 `runCatching` 捕获后返回 `stackTraceStr`（错误文本，非抛到 JS）。
//!
//! 我方改前：`java.ajax` 只有 `AjaxUrlStr` 单参闭包
//! （`host_api/quickjs_impl.rs` 注册处），rquickjs 对多余实参按 JS 语义忽略
//! ——双参调用不报错但 callTimeout 不生效。本文件
//! `java_ajax_call_timeout_aborts_slow_request` 在改前为红（慢请求照常返回），
//! 实现透传后转绿。
//!
//! Mock：本地回环 HTTP/1.1 单线程服务（`std::TcpListener`，模式同
//! `tests/str_response_tianlai_loopback.rs`，无外网依赖、不加 `#[ignore]`）：
//! - `/fast` → 立即 200 `FAST-OK`；
//! - `/slow` → sleep 1500ms 后 200 `SLOW-OK`（红态时 300ms 超时请求会拿到它）。

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::time::{Duration, Instant};

use legado_js::engine::{JsEngine, JsValue};
use legado_js::host_api::current_source;
use legado_js::sandbox::SandboxConfig;
use legado_js::QuickJsEngine;

/// 与生产 `QuickJsExecutor` fresh 路径同源的引擎配置
/// （同 tests/str_response_tianlai_loopback.rs）
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

/// 最小本地回环 HTTP/1.1 服务：`/slow` sleep 1500ms，其余立即响应。
fn spawn_loopback_server(max_conns: usize) -> std::net::SocketAddr {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        for stream in listener.incoming().take(max_conns) {
            let Ok(mut sock) = stream else { continue };
            let _ = sock.set_read_timeout(Some(Duration::from_secs(10)));
            let Some(head) = read_http_head(&mut sock) else {
                continue;
            };
            if head.starts_with("GET /slow") {
                // 故意慢于 300ms 测试超时；客户端超时后连接被丢弃，写失败忽略
                std::thread::sleep(Duration::from_millis(1500));
                let _ = sock.write_all(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nSLOW-OK"
                        .as_bytes(),
                );
            } else {
                let _ = sock.write_all(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 7\r\nConnection: close\r\n\r\nFAST-OK"
                        .as_bytes(),
                );
            }
        }
    });
    addr
}

/// 逐字节读到请求头 `\r\n\r\n`（GET 无 body，本 mock 够用）
fn read_http_head(sock: &mut std::net::TcpStream) -> Option<String> {
    let mut buf: Vec<u8> = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        sock.read_exact(&mut byte).ok()?;
        buf.push(byte[0]);
    }
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// 在给定 tag 下求值脚本并返回字符串结果（生产同源窗口）
fn eval_in_tag(engine: &QuickJsEngine, tag: &str, url: &str, script: &str) -> String {
    current_source::with_current_source_tag(tag, || {
        JsEngine::eval_with_bindings(engine, script, &[("url", JsValue::String(url.to_string()))])
            .expect("java.ajax 用例执行失败")
    })
}

/// 红→绿：`java.ajax(url, 300)` 对 1500ms 慢响应必须在 300ms 超时窗口内
/// 返回错误文本，且不得拿到 `SLOW-OK`。
///
/// 改前（单参闭包忽略第二参）：实测约 1500ms 后返回 `SLOW-OK` → 断言红；
/// 透传后：约 300ms 返回 `[ERROR] ... Timeout ...` → 绿。
#[test]
fn java_ajax_call_timeout_aborts_slow_request() {
    let addr = spawn_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/slow");
    let start = Instant::now();
    let out = eval_in_tag(
        &engine,
        "e2e.java.ajax.call_timeout",
        &url,
        "java.ajax(url, 300)",
    );
    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_millis(1200),
        "300ms callTimeout 应在 1.2s 内返回（实测 {elapsed:?}）; 观测: {out}"
    );
    assert!(
        !out.contains("SLOW-OK"),
        "超时请求不应返回慢响应体; 观测: {out}"
    );
    assert!(
        out.contains("[ERROR]"),
        "应返回超时错误文本（[ERROR] 惯例）; 观测: {out}"
    );
}

/// 零回归：单参形态、显式 null、显式正超时（快响应）、数组首参 + 第二参
/// 四种形态都必须正常返回响应体 `FAST-OK`。
#[test]
fn java_ajax_default_and_arity_forms_still_work() {
    let addr = spawn_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/fast");
    let out = eval_in_tag(
        &engine,
        "e2e.java.ajax.arity",
        &url,
        r#"
var a = java.ajax(url);            // 单参（不得回归）
var b = java.ajax(url, 5000);      // 双参正超时（快响应内正常返回）
var c = java.ajax(url, null);      // 显式 null = 缺省语义
var d = java.ajax([url], 5000);    // 首参仍按 AjaxUrlStr 取数组首元素
JSON.stringify({a:a, b:b, c:c, d:d})
"#,
    );
    let v: serde_json::Value = serde_json::from_str(&out).expect("结果应为 JSON 对象: {out}");
    for key in ["a", "b", "c", "d"] {
        assert_eq!(
            v[key], "FAST-OK",
            "形态 {key} 应正常返回响应体; 观测: {out}"
        );
    }
}

/// 边界：`callTimeout === 0` 在原版为 OkHttp「不设 call timeout」（0 合法且
/// 不立即超时）；我方最接近映射 = 沿用默认请求超时，绝不能变成 Duration::ZERO
/// 的立即超时（reqwest 对零时长 sleep 立即到期）。
#[test]
fn java_ajax_call_timeout_zero_does_not_expire_immediately() {
    let addr = spawn_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/fast");
    let out = eval_in_tag(&engine, "e2e.java.ajax.zero", &url, "java.ajax(url, 0)");
    assert_eq!(
        out, "FAST-OK",
        "callTimeout=0 不得立即超时（原版 0 = 不设 call timeout）; 观测: {out}"
    );
}

/// 边界：原版 OkHttp `checkDuration` 对 `< 0` / `> Integer.MAX_VALUE` 抛
/// IllegalArgumentException，被 `ajax` 的 runCatching 捕获 → 返回 stackTraceStr
/// （错误文本）。我方以既有 `[ERROR]` 惯例承载，且不得把负值经 u64 回绕成
/// 「永不超时」或发起请求。
#[test]
fn java_ajax_call_timeout_out_of_range_returns_error_text() {
    let addr = spawn_loopback_server(8);
    let engine = production_engine();
    let url = format!("http://{addr}/fast");
    for script in ["java.ajax(url, -1)", "java.ajax(url, 2147483648)"] {
        let out = eval_in_tag(&engine, "e2e.java.ajax.range", &url, script);
        assert!(
            out.contains("[ERROR]"),
            "{script} 应返回原版同义的错误文本; 观测: {out}"
        );
        assert!(
            !out.contains("FAST-OK"),
            "{script} 不应实际发起请求; 观测: {out}"
        );
    }
}
