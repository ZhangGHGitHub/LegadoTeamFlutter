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
    let _ = source_tag;
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckError::JsFailed(format!("body escape: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckError::JsFailed(format!("url escape: {e}")))?;
    let wrapped_code = format!(
        "var __result_body = {body_lit};\n         var __result_url = {url_lit};\n         var __result_code = {response_code};\n         var result = {{ body: function() {{ return __result_body; }},\n         url: function() {{ return __result_url; }},\n         code: function() {{ return __result_code; }} }};\n         {js_code}"
    );

    let eval_result = eval_js(&wrapped_code)?;
    let trimmed = eval_result.trim().trim_matches('"').trim();
    if trimmed == "false" || trimmed.contains("未登录") || trimmed.contains("needLogin") {
        return Err(LoginCheckError::NotLoggedIn(format!(
            "loginCheckJs not logged in: {trimmed}"
        )));
    }
    Ok(())
}

#[cfg(feature = "quickjs")]
fn eval_js(code: &str) -> Result<String, LoginCheckError> {
    use legado_js::engine::JsEngine;
    use legado_js::sandbox::SandboxConfig;
    use legado_js::QuickJsEngine;

    let engine = QuickJsEngine::new(SandboxConfig::default())
        .map_err(|e| LoginCheckError::JsFailed(format!("js init: {e}")))?;
    engine
        .eval(code)
        .map_err(|e| LoginCheckError::JsFailed(format!("loginCheckJs: {e}")))
}

#[cfg(not(feature = "quickjs"))]
fn eval_js(_code: &str) -> Result<String, LoginCheckError> {
    Ok(String::new())
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::BookSource;

    fn source_with_js(js: &str) -> BookSource {
        let mut s = BookSource::default();
        s.book_source_url = "https://example.com".into();
        s.login_check_js = Some(js.to_string());
        s
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
}
