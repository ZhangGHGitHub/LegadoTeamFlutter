//! Source loginCheckJs check for legado-server (align FFI web_book::execute_login_check).
//!
//! Dual-path: NotLoggedIn -> errResponse re-eval -> LoginRequired (HTTP 401 / code 1012).

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};

#[derive(Debug)]
enum LoginCheckError {
    NotLoggedIn(String),
    JsFailed(String),
}

/// Run loginCheckJs; no-op when unset.
pub fn execute_login_check(
    source: &BookSource,
    response_body: &str,
    response_url: &str,
    response_code: u16,
) -> LegadoResult<()> {
    let login_check_js = match &source.login_check_js {
        Some(js) if !js.trim().is_empty() => js.as_str(),
        _ => return Ok(()),
    };

    match run_login_check_js(
        login_check_js,
        response_body,
        response_url,
        response_code,
        &source.book_source_url,
    ) {
        Ok(()) => Ok(()),
        Err(LoginCheckError::NotLoggedIn(msg)) => {
            let err_body = format!("HTTP/1.1 500 Internal Server Error\n\n{msg}");
            match run_login_check_js(
                login_check_js,
                &err_body,
                response_url,
                500,
                &source.book_source_url,
            ) {
                Ok(()) => Ok(()),
                Err(LoginCheckError::NotLoggedIn(_)) => Err(LegadoError::LoginRequired(
                    "书源需要登录，请先在书源菜单中登录后重试".into(),
                )),
                Err(LoginCheckError::JsFailed(e)) => {
                    eprintln!("[server login_check] errResponse failed (pass): {e}");
                    Ok(())
                }
            }
        }
        Err(LoginCheckError::JsFailed(e)) => {
            eprintln!("[server login_check] failed (pass): {e}");
            Ok(())
        }
    }
}

fn run_login_check_js(
    js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    source_tag: &str,
) -> Result<(), LoginCheckError> {
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckError::JsFailed(format!("body escape: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckError::JsFailed(format!("url escape: {e}")))?;
    let wrapped_code = format!(
        "var __result_body = {body_lit};\n         var __result_url = {url_lit};\n         var __result_code = {response_code};\n         var result = {{ body: function() {{ return __result_body; }},\n         url: function() {{ return __result_url; }},\n         code: function() {{ return __result_code; }} }};\n         {js_code}"
    );

    let eval_result = eval_js(&wrapped_code, source_tag)?;
    let trimmed = eval_result.trim().trim_matches('"').trim();
    if trimmed == "false" || trimmed.contains("未登录") || trimmed.contains("needLogin") {
        return Err(LoginCheckError::NotLoggedIn(format!(
            "loginCheckJs not logged in: {trimmed}"
        )));
    }
    Ok(())
}

#[cfg(feature = "quickjs")]
fn eval_js(code: &str, source_tag: &str) -> Result<String, LoginCheckError> {
    use legado_js::engine::JsEngine;
    use legado_js::host_api::current_source;
    use legado_js::sandbox::SandboxConfig;
    use legado_js::QuickJsEngine;

    let engine = QuickJsEngine::new(SandboxConfig::default())
        .map_err(|e| LoginCheckError::JsFailed(format!("js init: {e}")))?;
    // P2-19 后续 #7：执行期绑定本源 tag（save/restore 包裹，对齐
    // pay_action / image_api 同款模式，不改对外签名）：loginCheckJs 属书源所有，
    // 其顶层 `java.ajax`（会话复检等）应携带本源 JS 宿主 cookie；不绑定则落入
    // 「未归属上下文」（回归面：连本源 cookie 也不带）。
    // 备注：该 store 在 server 二进制当前**无生产写入方**（JS 宿主 cookie 存储
    // 由 legacy-ffi 进程写入；server 的 cookie 层是 DB 持久层 CookieRepository），
    // 今日实际影响 ≈ 0；绑定是为「未来引入源上下文时不缺本源 cookie」+ 语义正确性。
    current_source::with_current_source_tag(source_tag, || {
        engine
            .eval(code)
            .map_err(|e| LoginCheckError::JsFailed(format!("loginCheckJs: {e}")))
    })
}

#[cfg(not(feature = "quickjs"))]
fn eval_js(_code: &str, _source_tag: &str) -> Result<String, LoginCheckError> {
    Ok(String::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::BookSource;

    fn source_with_js(js: &str) -> BookSource {
        BookSource {
            book_source_url: "https://example.com".into(),
            login_check_js: Some(js.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn skip_when_no_login_check_js() {
        let s = BookSource::default();
        assert!(execute_login_check(&s, "body", "http://x", 200).is_ok());
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn not_logged_in_raises_login_required() {
        let s = source_with_js("false");
        let err = execute_login_check(&s, "need login", "http://x", 200).unwrap_err();
        assert!(matches!(err, LegadoError::LoginRequired(_)));
        assert_eq!(err.to_error_code(), 1012);
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn logged_in_passes() {
        let s = source_with_js("true");
        assert!(execute_login_check(&s, "ok body", "http://x", 200).is_ok());
    }

    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn without_quickjs_degrades_to_pass() {
        let s = source_with_js("false");
        assert!(execute_login_check(&s, "body", "http://x", 200).is_ok());
    }

    /// P2-19 后续 #7：loginCheckJs 顶层 `java.ajax` 必须携带**请求域**
    /// cookie（cookie 属于域名而非书源，按请求 URL 属域携带；回环 cookie
    /// 记录服务器，P2-17 同款模式；经公共入口 `execute_login_check` 验证
    /// 全链路贯通）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_login_check_js_carries_request_domain_cookie() {
        use std::io::{Read, Write};
        use std::sync::{Arc, Mutex};

        use legado_js::host_api::cookie_store;

        // 进程级锁：本用例写/清回环域名键 127.0.0.1（全局 cookie store），
        // 与同二进制内其他碰该键的测试串行（各 test 二进制独立进程，
        // 无跨 crate 嵌套死锁）
        let _lock = crate::test_support::lock_cookie_store_test();

        // 回环 cookie 记录服务器：记录收到的 Cookie 请求头（忽略请求 body）
        let seen: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let seen_srv = seen.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().take(2) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    if sock.read_exact(&mut byte).is_err() {
                        break;
                    }
                    head.push(byte[0]);
                    if head.len() > 65_536 {
                        break;
                    }
                }
                let head_str = String::from_utf8_lossy(&head);
                let cookie = head_str.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.trim()
                        .eq_ignore_ascii_case("cookie")
                        .then(|| value.trim().to_string())
                });
                *seen_srv.lock().unwrap() = cookie;
                let body = r#"{"ok":1}"#;
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });

        // 书源 tag（`with_current_source_tag` 绑定上下文，与 cookie 键无关）
        const TAG: &str = "https://p219-login.example.com/";
        // cookie 键 = **请求 URL 的属域键**（quickjs 档归一 IP 字面量为
        // 自键 127.0.0.1）：cookie 属于域名而非书源，写入键须与 loginCheckJs
        // 顶层 ajax 的请求域（echo_url 回环地址）一致，改前写 TAG 域键 →
        // 按请求 URL 属域取落空（新语义下红测试根因）
        let echo_url = format!("http://{addr}/echo");
        cookie_store::clear_cookies(&echo_url);
        cookie_store::set_cookie(&echo_url, "p219_lc_token", "lc-val-91de");

        // loginCheckJs 顶层 ajax（入参为 JSON 字符串——java.ajax 桥接签名
        // 为 (options: String)）+ 返回 "ok"（已登录语义）
        let js = format!(r#"java.ajax('{{"url":"http://{addr}/echo"}}'); "ok""#);
        let s = BookSource {
            book_source_url: TAG.into(),
            login_check_js: Some(js),
            ..Default::default()
        };
        let out = execute_login_check(&s, "body", "http://x", 200);
        assert!(out.is_ok(), "loginCheckJs 返回 ok 应判定已登录: {out:?}");

        let got = seen.lock().unwrap().clone();
        assert!(
            got.as_deref()
                .unwrap_or_default()
                .contains("p219_lc_token=lc-val-91de"),
            "loginCheckJs 顶层 ajax 必须携带请求域（127.0.0.1）cookie，实际 Cookie 头: {got:?}"
        );
        cookie_store::clear_cookies(&echo_url);
    }
}
