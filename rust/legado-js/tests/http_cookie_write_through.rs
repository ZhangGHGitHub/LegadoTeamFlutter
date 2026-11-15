//! P2-2：HTTP 层写回 → JS 罐写穿（`java.getCookie` 同进程可见）
//!
//! 背景（`docs/audit_20261113/REPORT_Cookie双罐.md` §2.5）：`java.getCookie`
//! 读的是 `legado-js` 的 `GLOBAL_COOKIES`（罐③），与 HTTP 层 App 罐（罐②）
//! 在运行期没有任何自动同步——唯一自动路径是「启动时从 DB 回填」。因此
//! HTTP 层（含 3xx 逐跳）新写入的 cookie 在改造前要等下次重启才对 JS 可见，
//! 「登录成功后立刻在 JS 里 `getCookie` 取 token」的书源必然失败。
//!
//! 本文件验证：`network::set_client_cookie_store` 注册的写穿观察者使 HTTP
//! 写回（302 逐跳 + 同名替换）立即反映到 `getCookie` / `cookies_for_url`，
//! 且不覆盖 JS 侧独有键。
#![cfg(feature = "quickjs")]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, RwLock};

use legado_js::host_api::{cookie_store, network};
use legado_net::{CookieStore, LegadoClient, LegadoClientConfig, COOKIE_JAR_HEADER};

/// 最小回环服务器：`/login` → 302 + `Set-Cookie: sid=NEW` + `Location: /home`，
/// `/home` → 200
fn spawn_login_redirect_server() -> std::net::SocketAddr {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let mut head: Vec<u8> = Vec::new();
            let mut byte = [0u8; 1];
            while !head.ends_with(b"\r\n\r\n") {
                match sock.read(&mut byte) {
                    Ok(0) | Err(_) => break,
                    Ok(_) => head.push(byte[0]),
                }
                if head.len() > 65_536 {
                    break;
                }
            }
            let head_str = String::from_utf8_lossy(&head).to_string();
            let path = head_str
                .lines()
                .next()
                .and_then(|line| line.split_whitespace().nth(1))
                .unwrap_or("/")
                .to_string();
            let resp = if path == "/login" {
                "HTTP/1.1 302 Found\r\nLocation: /home\r\nSet-Cookie: sid=NEW; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string()
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nhome".to_string()
            };
            let _ = sock.write_all(resp.as_bytes());
            let _ = sock.shutdown(std::net::Shutdown::Both);
        }
    });
    addr
}

fn marker_headers() -> Option<HashMap<String, String>> {
    let mut headers = HashMap::new();
    headers.insert(COOKIE_JAR_HEADER.to_string(), "1".to_string());
    Some(headers)
}

#[test]
fn test_http_write_through_visible_to_get_cookie() {
    let addr = spawn_login_redirect_server();
    let base_url = format!("http://{addr}/");
    let login_url = format!("http://{addr}/login");

    // 注册共享 App 罐：顺带注册 HTTP→JS 罐写穿观察者（生产路径同款，
    // 由 FFI `register_js_client_cookie_persistence` 调用）
    let store = Arc::new(RwLock::new(CookieStore::new()));
    network::set_client_cookie_store(Arc::clone(&store));

    // 模拟 JS 侧先写入的 cookie（`java.setCookie`）：必须与 HTTP 写穿共存
    cookie_store::set_cookie(&base_url, "js_keep", "1");

    // HTTP 层：302 下 `sid=NEW`（逐跳写回 App 罐）
    let client = LegadoClient::with_cookie_store(
        LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        },
        store,
        None,
    )
    .expect("构建客户端");
    let resp = legado_js::host_api::runtime_bridge::block_on(async move {
        client.get(&login_url, marker_headers()).await
    })
    .expect("302 登录回环应成功");
    assert_eq!(resp.status, 200, "重定向应跟随到 /home");

    // `java.getCookie` 读罐③：必须立即看到 302 的新会话
    assert_eq!(
        cookie_store::get_cookie_by_key(&base_url, "sid"),
        "NEW",
        "HTTP 层 302 写入的 cookie 必须写穿到 JS 罐（修复前只有启动回填可见）"
    );
    assert_eq!(
        cookie_store::get_cookie_by_key(&base_url, "js_keep"),
        "1",
        "JS 侧独有键不得被 HTTP 写穿覆盖丢失"
    );

    // 下一次 JS 请求的合并串（`merge_js_cookies` / `cookies_for_url` 口径）
    let merged = cookie_store::cookies_for_url(&base_url);
    assert!(merged.contains("sid=NEW"), "请求合并串应含新会话: {merged}");
    assert!(
        merged.contains("js_keep=1"),
        "请求合并串应含 JS 键: {merged}"
    );
}
