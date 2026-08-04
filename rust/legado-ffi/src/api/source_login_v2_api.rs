//! 登录 UI V2 动态状态协议 FFI 层（上游 #402/#488）
//!
//! 在 [`legado_core::login_ui_v2`] 协议实现之上接入 QuickJS 引擎池，
//! 对齐 Kotlin `BaseSource.evalLoginUiV2/evalLoginActionV2` 的执行链路：
//!
//! - JS 绑定上下文对齐：Kotlin `evalJS` 注入 java/source/sourceApi/baseUrl/cookie/cache；
//!   Rust 引擎已全局注册 `java` 命名空间与 cookie API（getCookie/setCookie/clearCookies），
//!   本层额外注入 `baseUrl`（书源 URL）与 `source`（书源 JSON 对象），
//!   脚本亦可通过 `getSource(baseUrl)` 读取书源完整字段。
//! - #488 登录前脚本阻塞：Rust 侧 V2 动作直接执行 `loginAction`，
//!   不前置遗留 `login()` 脚本，执行顺序无同类问题。
//!
//! 未启用 quickjs feature 时返回 `JsEngine` 错误（FFI 层转 BridgeError）。

use legado_core::models::BookSource;
use legado_core::{login_ui_v2, LegadoError, LegadoResult};

/// 判定书源登录 UI 是否为 V2 动态状态协议
///
/// `source_json` — BookSource JSON
pub fn is_login_ui_v2(source_json: &str) -> LegadoResult<bool> {
    let source: BookSource = serde_json::from_str(source_json)?;
    Ok(login_ui_v2::is_v2(source.login_ui.as_deref()))
}

/// 执行 loginUi v2 脚本，返回动态 UI 描述 JSON（`{ "rows": [...] }`）
///
/// - `source_json` — BookSource JSON
/// - `state_json` — 当前状态 JSON（首次渲染传 `"{}"`）
///
/// JS 返回 null/undefined 时返回空字符串（对齐 Kotlin 返回 null → 渲染失败提示）。
pub fn eval_login_ui_v2(source_json: &str, state_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let state = if state_json.trim().is_empty() { "{}" } else { state_json };
    let result = eval_with_quickjs(&source, |eval_js| {
        login_ui_v2::eval_login_ui_v2(&source, state, eval_js)
    })?;
    Ok(result.unwrap_or_default())
}

/// V2 登录动作请求（`source_login_action_v2` 的 `user_input_json` 契约）
///
/// - `action` — 按钮动作名（RowUi.action）
/// - `stateJson` — 当前状态（JSON 字符串或对象均可，对象会自动序列化）
/// - `formJson` — 表单键值（JSON 对象或字符串均可）
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoginActionV2Request {
    pub action: String,
    #[serde(default)]
    pub state_json: serde_json::Value,
    #[serde(default)]
    pub form_json: serde_json::Value,
}

/// 将请求字段规范化为 JSON 字符串：字符串原样使用，对象自动序列化，缺省为 `"{}"`
fn json_param_to_string(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Null => "{}".to_string(),
        serde_json::Value::String(s) => {
            if s.trim().is_empty() {
                "{}".to_string()
            } else {
                s.clone()
            }
        }
        other => other.to_string(),
    }
}

/// 执行 loginAction v2 动作，返回命令 JSON（state/error/login/close）
///
/// - `source_json` — BookSource JSON
/// - `user_input_json` — [`LoginActionV2Request`] JSON（action/stateJson/formJson）
///
/// JS 返回 null/undefined（无命令）时返回空字符串。
pub fn eval_login_action_v2(source_json: &str, user_input_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)?;
    let request: LoginActionV2Request = serde_json::from_str(user_input_json)?;
    let state = json_param_to_string(&request.state_json);
    let form = json_param_to_string(&request.form_json);
    let result = eval_with_quickjs(&source, |eval_js| {
        login_ui_v2::eval_login_action_v2(&source, &request.action, &state, &form, eval_js)
    })?;
    Ok(result.unwrap_or_default())
}

// ─── QuickJS 求值接入 ──────────────────────────────────────────

/// 启用 quickjs：以书源 URL 分桶复用全局引擎池执行 V2 脚本
#[cfg(feature = "quickjs")]
fn eval_with_quickjs<F>(source: &BookSource, eval: F) -> LegadoResult<Option<String>>
where
    F: for<'a> FnOnce(login_ui_v2::EvalJs<'a>) -> LegadoResult<Option<String>>,
{
    use legado_js::{JsEngine, JsValue};

    let engine = crate::js_executor::pool_engine(&source.book_source_url)?;
    let guard = engine
        .lock()
        .map_err(|e| LegadoError::JsEngine(format!("JS 引擎加锁失败: {e}")))?;

    // 对齐 Kotlin evalJS 绑定：baseUrl = getKey()；source = 书源对象
    let source_obj_json = serde_json::to_string(source)?;
    let base_url = source.book_source_url.clone();
    let mut eval_js = |code: &str, bindings: &[(&str, &str)]| -> LegadoResult<String> {
        let mut js_bindings: Vec<(&str, JsValue)> = Vec::with_capacity(bindings.len() + 2);
        js_bindings.push(("baseUrl", JsValue::String(base_url.clone())));
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&source_obj_json) {
            js_bindings.push(("source", json_to_js_value(value)));
        }
        for (name, value) in bindings {
            js_bindings.push((name, JsValue::String((*value).to_string())));
        }
        guard.eval_with_bindings(code, &js_bindings)
    };
    eval(&mut eval_js)
}

/// serde_json::Value → legado_js::JsValue（用于注入 `source` 绑定对象）
#[cfg(feature = "quickjs")]
fn json_to_js_value(value: serde_json::Value) -> legado_js::JsValue {
    use legado_js::JsValue;
    match value {
        serde_json::Value::Null => JsValue::Null,
        serde_json::Value::Bool(b) => JsValue::Bool(b),
        serde_json::Value::Number(n) => match n.as_i64() {
            Some(i) => JsValue::Int(i),
            None => JsValue::Number(n.as_f64().unwrap_or(0.0)),
        },
        serde_json::Value::String(s) => JsValue::String(s),
        serde_json::Value::Array(items) => {
            JsValue::Array(items.into_iter().map(json_to_js_value).collect())
        }
        serde_json::Value::Object(map) => JsValue::Object(
            map.into_iter()
                .map(|(k, v)| (k, json_to_js_value(v)))
                .collect(),
        ),
    }
}

/// 未启用 quickjs：无法执行 JS，返回引擎未启用错误
#[cfg(not(feature = "quickjs"))]
fn eval_with_quickjs<F>(_source: &BookSource, _eval: F) -> LegadoResult<Option<String>>
where
    F: for<'a> FnOnce(login_ui_v2::EvalJs<'a>) -> LegadoResult<Option<String>>,
{
    Err(LegadoError::JsEngine(
        "QuickJS engine not enabled. Build with --features quickjs".into(),
    ))
}

// ─── 测试 ──────────────────────────────────────────────────────

#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    /// 对齐 Kotlin `LoginUiV2EngineTest`：mainJs 提供 loginUi/loginAction 的 JS 单文件书源
    fn v2_source_json() -> String {
        serde_json::json!({
            "bookSourceUrl": "https://login-v2.example.com",
            "bookSourceName": "登录测试",
            "loginUi": login_ui_v2::MARKER,
            "mainJs": r#"
                function loginUi(state) {
                    if (!state.step) return { rows: [
                        { key: "phone", name: "手机号", type: "text" },
                        { name: "发送验证码", type: "button", action: "sendCode" }
                    ] };
                    return { rows: [
                        { key: "code", name: "验证码", type: "text" },
                        { name: "重新发码", type: "button", action: "sendCode", countdown: 60 }
                    ] };
                }
                function loginAction(action, state, form) {
                    if (action == "sendCode") {
                        if (!form.phone) return { error: { phone: "手机号必填" } };
                        return { state: { step: "code", phone: "+86" + form.phone } };
                    }
                    if (action == "noop") return;
                    return { login: { token: state.phone + "-tk" }, close: true };
                }
            "#
        })
        .to_string()
    }

    #[test]
    fn test_is_login_ui_v2() {
        assert!(is_login_ui_v2(&v2_source_json()).unwrap());
        let v1 = serde_json::json!({
            "bookSourceUrl": "https://v1.example.com",
            "loginUi": r#"[{"name":"账号","type":"text"}]"#
        })
        .to_string();
        assert!(!is_login_ui_v2(&v1).unwrap());
    }

    #[test]
    fn test_eval_login_ui_v2_render_states() {
        let source_json = v2_source_json();
        // 首次渲染（state = {}）
        let first = eval_login_ui_v2(&source_json, "{}").unwrap();
        let rows = login_ui_v2::parse_render(Some(&first)).expect("首次渲染应合法");
        assert_eq!(rows[0].key.as_deref(), Some("phone"));

        // 进入验证码步骤
        let second = eval_login_ui_v2(&source_json, r#"{"step":"code"}"#).unwrap();
        let rows = login_ui_v2::parse_render(Some(&second)).expect("二次渲染应合法");
        assert_eq!(rows[0].key.as_deref(), Some("code"));
        assert_eq!(rows[1].countdown, Some(60));
    }

    #[test]
    fn test_eval_login_action_v2_commands() {
        let source_json = v2_source_json();

        // sendCode 成功 → state 命令
        let raw = eval_login_action_v2(
            &source_json,
            r#"{"action":"sendCode","formJson":{"phone":"13800000000"}}"#,
        )
        .unwrap();
        let command = login_ui_v2::parse_action_result(Some(&raw));
        assert!(command.state_json.unwrap().contains("+8613800000000"));
        assert!(command.error.is_none());

        // sendCode 缺手机号 → error 命令
        let raw = eval_login_action_v2(&source_json, r#"{"action":"sendCode"}"#).unwrap();
        let command = login_ui_v2::parse_action_result(Some(&raw));
        assert_eq!(command.error.unwrap().get("phone").unwrap(), "手机号必填");

        // noop → 无命令（undefined 规范化为空）
        let raw = eval_login_action_v2(&source_json, r#"{"action":"noop"}"#).unwrap();
        let command = login_ui_v2::parse_action_result(Some(raw.as_str()).filter(|s| !s.is_empty()));
        assert!(command.state_json.is_none());
        assert!(!command.close);
        assert!(!command.malformed);

        // submit → login + close
        let raw = eval_login_action_v2(
            &source_json,
            r#"{"action":"submit","stateJson":{"phone":"+86138"},"formJson":{}}"#,
        )
        .unwrap();
        let command = login_ui_v2::parse_action_result(Some(&raw));
        assert!(command.login_json.unwrap().contains("+86138-tk"));
        assert!(command.close);
    }

    #[test]
    fn test_eval_login_ui_v2_declarative_login_url() {
        // 对齐 Kotlin：声明式脚本放 loginUrl
        let source_json = serde_json::json!({
            "bookSourceUrl": "https://declarative.example.com",
            "bookSourceName": "声明式登录测试",
            "loginUi": login_ui_v2::MARKER,
            "loginUrl": r#"
                function loginUi(state) {
                    return { rows: [{ key: "account", name: "账号", type: "text" }] };
                }
                function loginAction(action, state, form) {
                    return { login: { account: form.account }, close: true };
                }
            "#
        })
        .to_string();

        let raw = eval_login_ui_v2(&source_json, "{}").unwrap();
        let rows = login_ui_v2::parse_render(Some(&raw)).expect("声明式渲染应合法");
        assert_eq!(rows[0].key.as_deref(), Some("account"));

        let raw = eval_login_action_v2(
            &source_json,
            r#"{"action":"submit","formJson":{"account":"reader"}}"#,
        )
        .unwrap();
        let command = login_ui_v2::parse_action_result(Some(&raw));
        assert_eq!(command.login_json.as_deref(), Some(r#"{"account":"reader"}"#));
        assert!(command.close);
    }

    #[test]
    fn test_eval_login_ui_v2_source_binding() {
        // JS 绑定上下文：脚本可读取 source 对象与 baseUrl
        let source_json = serde_json::json!({
            "bookSourceUrl": "https://binding.example.com",
            "bookSourceName": "绑定测试",
            "loginUi": login_ui_v2::MARKER,
            "mainJs": r#"
                function loginUi(state) {
                    return { rows: [{ key: "n", name: source.bookSourceName + "@" + baseUrl, type: "text" }] };
                }
                function loginAction(action, state, form) { return { close: true }; }
            "#
        })
        .to_string();
        let raw = eval_login_ui_v2(&source_json, "{}").unwrap();
        assert!(raw.contains("绑定测试@https://binding.example.com"));
    }

    #[test]
    fn test_eval_missing_script_error() {
        let source_json = serde_json::json!({
            "bookSourceUrl": "https://missing.example.com",
            "loginUi": login_ui_v2::MARKER
        })
        .to_string();
        let err = eval_login_ui_v2(&source_json, "{}").unwrap_err();
        assert!(err.to_string().contains("缺少 loginUi/loginAction 脚本"));
    }
}
