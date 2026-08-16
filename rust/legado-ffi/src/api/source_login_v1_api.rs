//! 书源 V1 登录动作执行（对齐 Kotlin BaseSource.login()）
//!
//! V1 登录：书源 loginUrl 为 JS 脚本（定义 `login()` 函数），loginUi 为
//! 表单 JSON（按钮 action 如 `login()`）。原版 `BaseSource.login()` 在完整
//! 书源上下文（jsLib + source/cookie/java 绑定 + setup）执行
//! `loginJs + login.apply(this)`；书山聚合等源在 login() 内经
//! `java.ajax(/login)` 取 api_key 并 `source.putLoginHeader` 落库。
//!
//! 本层复用 [`crate::js_executor::construct_analyzer_with_source_context`]
//! 注入 sanitize 后 jsLib + setup（含 header 规则 → GLOBAL_COOKIES/全局请求头），
//! eval 登录脚本后经 `sync_login_cache_from_js` 把 JS 写入的
//! `loginHeader_<url>`/`userInfo_<url>` 同步到 source_login_cache，
//! 后续 java.ajax 请求自动携带书山 X-Api-Key（base64(api_key)）。

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};

/// 提取 loginUrl 中的 JS（对齐原版 getLoginJs：<js>/@js: 包裹则去壳，否则原样）
fn get_login_js(source: &BookSource) -> Option<String> {
    let rule = source.login_url.as_deref()?.trim();
    if rule.is_empty() {
        return None;
    }
    let lower = rule.to_lowercase();
    if lower.starts_with("<js>") {
        let end = rule.rfind('<').unwrap_or(rule.len());
        return Some(rule[4..end].to_string());
    }
    if lower.starts_with("@js:") {
        return Some(rule[4..].to_string());
    }
    Some(rule.to_string())
}

/// 执行书源 V1 登录动作（对齐原版 BaseSource.login()）
///
/// - `source_json` — BookSource JSON
/// - `action` — 按钮动作（默认 `login`；书山 loginUi 按钮 action 为 `login()`）
///
/// 执行后同步 JS 侧写入的登录缓存；返回执行结果（JSON 字符串或空）。
pub fn eval_login_v1(source_json: &str, action: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let login_js = get_login_js(&source).ok_or_else(|| {
        LegadoError::JsEngine("书源 loginUrl 缺失或为空".into())
    })?;

    // 对齐原版：`loginJs` + `if(typeof login=='function'){login.apply(this);}`
    // this 绑定为 {source, cookie, java}（setup 语义；书山 login() 内
    // `const {java, source, cookie} = this` 解构依赖）
    let action_name = if action.trim().is_empty() {
        "login"
    } else {
        action.trim().trim_end_matches('(').trim_end_matches(')')
    };
    let script = format!("{login_js}\n")
        + "if (typeof " + action_name + " == 'function') {"
        + "  " + action_name + ".apply({ source: source, cookie: cookie, java: java });"
        + "}";

    // 书源上下文：sanitize jsLib + setup（含 header 规则注入全局请求头）
    let js_lib_sanitized = source
        .js_lib
        .as_deref()
        .map(crate::api::source_js_bindings::sanitize_js_lib_for_quickjs);
    let analyzer = crate::js_executor::construct_analyzer_with_source_context(
        String::new(),
        source.book_source_url.clone(),
        &source.book_source_url,
        js_lib_sanitized.as_deref(),
        crate::api::source_js_bindings::book_source_js_setup_script(&source).ok(),
    );
    let _ = analyzer.get_string(&format!("@js:{script}"));

    // 同步 JS variable_store → source_login_cache（loginHeader/userInfo）
    crate::api::source_login_cache::sync_login_cache_from_js(&source.book_source_url);

    // 返回登录头状态（便于 UI 判定登录结果）
    let header = crate::api::source_login_cache::get_login_header(&source.book_source_url)
        .unwrap_or_default();
    if header.is_empty() || header == "null" {
        return Ok(String::new());
    }
    Ok(header)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_login_js_strips_wrappers() {
        let src = BookSource {
            book_source_url: "https://t.test".to_string(),
            login_url: Some("<js>function login(){ return 1; }</js>".to_string()),
            ..BookSource::default()
        };
        let js = get_login_js(&src).unwrap();
        assert!(js.contains("function login"));
        assert!(!js.contains("<js>"));
    }

    #[test]
    fn test_get_login_js_plain_kept() {
        let src = BookSource {
            book_source_url: "https://t.test".to_string(),
            login_url: Some("function login(){ return 1; }".to_string()),
            ..BookSource::default()
        };
        assert_eq!(
            get_login_js(&src).unwrap(),
            "function login(){ return 1; }"
        );
    }
}
