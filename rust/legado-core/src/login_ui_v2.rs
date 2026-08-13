//! 登录 UI V2 动态状态协议（上游 #402/#488）
//!
//! 移植自 Kotlin `model/login/LoginUiV2.kt` 与
//! `data/entities/BaseSource.kt` 的 `isLoginUiV2/evalLoginUiV2/evalLoginActionV2`。
//!
//! 协议要点：
//! - `loginUi` 字段为 `{"version":2}` 标记（[`MARKER`]）时启用 V2 动态协议；
//! - 登录脚本（JS 单文件书源取 `mainJs`，否则取 `loginUrl`）必须实现
//!   `loginUi(state)` 与 `loginAction(action, state, form)` 两个函数；
//! - `loginUi(state)` 返回 `{ rows: RowUi[] }` 描述当前状态下的动态表单；
//! - `loginAction(action, state, form)` 返回命令对象：
//!   `state`（进入新状态）/ `error`（字段错误）/ `login`（登录结果）/ `close`（关闭对话框）。
//!
//! 本模块不依赖具体 JS 引擎：执行入口 [`eval_login_ui_v2`] / [`eval_login_action_v2`]
//! 以闭包形式注入 JS 求值器，便于测试 mock；FFI 层（legado-ffi）注入 QuickJS 实现。

use regex::Regex;
use std::collections::HashMap;
use std::sync::OnceLock;

use crate::models::{row_ui_type, BookSource, RowUi};
use crate::{LegadoError, LegadoResult};

/// V2 协议标记：`loginUi` 等于该 JSON 时判定为 V2（对齐 Kotlin `LoginUiV2.MARKER`）
pub const MARKER: &str = r#"{"version":2}"#;

/// 动作命令已知键集合（对齐 Kotlin `LoginUiV2.knownCommands`）
const KNOWN_COMMANDS: [&str; 4] = ["state", "error", "login", "close"];

/// JS 求值器闭包：执行完整脚本并返回**已规范化为字符串**的结果。
///
/// `bindings` 为需要注入 JS 全局作用域的字符串变量（名称 → 值）。
/// 规范化语义对齐 Kotlin `JsSourceEngine.normalizeJsResult`：
/// JS 返回 null/undefined 时返回 `"null"`，对象返回 JSON.stringify 结果。
pub type EvalJs<'a> = &'a mut dyn FnMut(&str, &[(&str, &str)]) -> LegadoResult<String>;

// ─── 判定与解析 ────────────────────────────────────────────────

/// 判定 loginUi 是否为 V2 动态协议（对齐 Kotlin `LoginUiV2.isV2`）
///
/// 条件：trim 后以 `{` 开头、是合法 JSON 对象且 `version == 2`。
pub fn is_v2(login_ui: Option<&str>) -> bool {
    let text = match login_ui.map(str::trim) {
        Some(t) if !t.is_empty() => t,
        _ => return false,
    };
    if !text.starts_with('{') {
        return false;
    }
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return false;
    };
    value.get("version").and_then(|v| v.as_i64()) == Some(2)
}

/// 解析 `loginUi(state)` 返回的渲染结果 JSON（对齐 Kotlin `LoginUiV2.parseRender`）
///
/// 返回 `None` 的情况：空白/非法 JSON、缺少 `rows` 数组、rows 为空、
/// 存在非法行（见 [`is_row_valid`]）、text/password/select 的 key 重复、button 的 action 重复。
pub fn parse_render(json: Option<&str>) -> Option<Vec<RowUi>> {
    let json = json?.trim();
    if json.is_empty() {
        return None;
    }
    let obj: serde_json::Value = serde_json::from_str(json).ok()?;
    let rows_value = obj.get("rows").filter(|v| v.is_array())?;
    let rows: Vec<RowUi> = serde_json::from_value(rows_value.clone()).ok()?;
    if rows.is_empty() || rows.iter().any(|r| !is_row_valid(r)) {
        return None;
    }
    // 表单键与按钮动作必须唯一（对齐 Kotlin 去重校验）
    let keys: Vec<&str> = rows
        .iter()
        .filter(|r| {
            matches!(
                r.r#type.as_str(),
                row_ui_type::TEXT | row_ui_type::PASSWORD | row_ui_type::SELECT
            )
        })
        .filter_map(|r| r.key.as_deref())
        .collect();
    let actions: Vec<&str> = rows
        .iter()
        .filter(|r| r.r#type == row_ui_type::BUTTON)
        .filter_map(|r| r.action.as_deref())
        .collect();
    if !all_unique(&keys) || !all_unique(&actions) {
        return None;
    }
    Some(rows)
}

/// 单行合法性校验（对齐 Kotlin `LoginUiV2.RowUi.isValid`）
fn is_row_valid(row: &RowUi) -> bool {
    if row.name.trim().is_empty() {
        return false;
    }
    if row.countdown.is_some_and(|c| c < 0) {
        return false;
    }
    match row.r#type.as_str() {
        row_ui_type::TEXT | row_ui_type::PASSWORD => {
            row.key.as_deref().is_some_and(|k| !k.trim().is_empty())
        }
        row_ui_type::LABEL => true,
        row_ui_type::SELECT => {
            row.key.as_deref().is_some_and(|k| !k.trim().is_empty())
                && row.options.as_ref().is_some_and(|o| !o.is_empty())
        }
        row_ui_type::BUTTON => row.action.as_deref().is_some_and(|a| !a.trim().is_empty()),
        // toggle 等其余类型在 V2 渲染中视为非法（对齐 Kotlin else 分支）
        _ => false,
    }
}

fn all_unique(items: &[&str]) -> bool {
    let mut seen = std::collections::HashSet::new();
    items.iter().all(|item| seen.insert(*item))
}

/// `loginAction` 命令解析结果（对齐 Kotlin `LoginUiV2.ActionResult`）
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ActionResult {
    /// `state` 命令：进入新状态的 stateJson 原文
    pub state_json: Option<String>,
    /// `error` 命令：字段键 → 错误消息
    pub error: Option<HashMap<String, String>>,
    /// `login` 命令：登录结果 JSON 原文（供 putLoginInfo 保存）
    pub login_json: Option<String>,
    /// `close` 命令：是否关闭登录界面
    pub close: bool,
    /// 未识别的命令键（记录日志后忽略）
    pub unknown_keys: Vec<String>,
    /// 返回内容不是合法命令对象
    pub malformed: bool,
}

/// 解析 `loginAction(action, state, form)` 返回的命令 JSON
///（对齐 Kotlin `LoginUiV2.parseActionResult`）
///
/// 空/空白输入返回空 [`ActionResult`]（无命令）；非法 JSON 或
/// state/error/login 非对象、close 非布尔时置 `malformed = true`。
pub fn parse_action_result(json: Option<&str>) -> ActionResult {
    let json = match json.map(str::trim) {
        Some(t) if !t.is_empty() => t,
        _ => return ActionResult::default(),
    };
    let obj: serde_json::Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => return ActionResult { malformed: true, ..Default::default() },
    };
    let obj = match &obj {
        serde_json::Value::Object(map) => map,
        _ => return ActionResult { malformed: true, ..Default::default() },
    };

    let take = |key: &str| obj.get(key).filter(|v| !v.is_null());

    // state / error / login 必须是对象，close 必须是布尔，否则 malformed
    for key in ["state", "error", "login"] {
        if let Some(v) = take(key) {
            if !v.is_object() {
                return ActionResult { malformed: true, ..Default::default() };
            }
        }
    }
    let close_value = match take("close") {
        Some(v) => match v.as_bool() {
            Some(b) => b,
            None => return ActionResult { malformed: true, ..Default::default() },
        },
        None => false,
    };

    // error 对象值统一转字符串（对齐 Gson Map<String,String> 语义）
    let errors = take("error").map(|v| {
        v.as_object()
            .map(|map| {
                map.iter()
                    .map(|(k, val)| {
                        let s = match val {
                            serde_json::Value::String(s) => s.clone(),
                            serde_json::Value::Null => String::new(),
                            other => other.to_string(),
                        };
                        (k.clone(), s)
                    })
                    .collect::<HashMap<String, String>>()
            })
            .unwrap_or_default()
    });

    ActionResult {
        state_json: take("state").map(|v| v.to_string()),
        error: errors,
        login_json: take("login").map(|v| v.to_string()),
        close: close_value,
        unknown_keys: obj
            .keys()
            .filter(|k| !KNOWN_COMMANDS.contains(&k.as_str()))
            .cloned()
            .collect(),
        malformed: false,
    }
}

/// 表单字段取值优先级（对齐 Kotlin `LoginUiV2.resolveFieldValue`）：
/// 渲染预填值 > 会话内输入 > 已存储登录信息
pub fn resolve_field_value(
    render_value: Option<&str>,
    session_input: Option<&str>,
    stored: Option<&str>,
) -> Option<String> {
    render_value
        .or(session_input)
        .or(stored)
        .map(|s| s.to_string())
}

// ─── 登录脚本提取（BaseSource 对齐） ───────────────────────────

/// 内联 JS 模式：`<js>...</js>` 或 `@js:...`（对齐 Kotlin `AppPattern.JS_PATTERN`，整串匹配、忽略大小写）
fn js_pattern() -> &'static Regex {
    static PATTERN: OnceLock<Regex> = OnceLock::new();
    PATTERN.get_or_init(|| {
        Regex::new(r"(?is)\A[ \t\r\n]*<js>([\s\S]*?)</js>[ \t\r\n]*\z|\A[ \t\r\n]*@js:([\s\S]*?)[ \t\r\n]*\z")
            .expect("JS_PATTERN 正则编译失败")
    })
}

/// 提取内联 JS（对齐 Kotlin `BaseSource.extractInlineJs`）
///
/// 规则 trim 后整体匹配 `<js>...</js>` 或 `@js:...` 时返回内部 JS；否则 `None`。
pub fn extract_inline_js(rule: Option<&str>) -> Option<String> {
    let text = rule.map(str::trim).filter(|t| !t.is_empty())?;
    let caps = js_pattern().captures(text)?;
    let js = caps.get(1).or_else(|| caps.get(2))?.as_str().trim();
    if js.is_empty() {
        None
    } else {
        Some(js.to_string())
    }
}

/// 获取登录脚本（对齐 Kotlin `BookSource.getLoginJs`）
///
/// JS 单文件书源（`mainJs` 非空）优先使用 `mainJs`；
/// 否则取 `loginUrl`：整体匹配内联 JS 模式时提取内部 JS，否则整段作为 JS。
pub fn get_login_js(source: &BookSource) -> Option<String> {
    if source.is_js_source() {
        return source.main_js.clone();
    }
    let login_rule = source.login_url.as_deref().map(str::trim).filter(|t| !t.is_empty())?;
    extract_inline_js(Some(login_rule)).or_else(|| Some(login_rule.to_string()))
}

// ─── 执行脚本构建与求值 ────────────────────────────────────────

/// JS 结果规范化包装（对齐 Kotlin `JsSourceEngine.normalizeJsResult`）
///
/// QuickJS 侧 eval 结果统一以字符串返回：null/undefined → `"null"`，
/// 字符串原样返回，对象经 `JSON.stringify` 序列化。
fn wrap_normalize(expr: &str) -> String {
    format!(
        "(function(){{var __r=({expr});\
         if(__r===null||__r===undefined)return null;\
         if(typeof __r==='string')return __r;\
         return JSON.stringify(__r);}})()",
        expr = expr
    )
}

/// 构建 `loginUi(state)` 执行脚本（对齐 Kotlin `BaseSource.evalLoginUiV2`）
///
/// 调用方需注入绑定 `__loginState`（state 的 JSON 字符串）。
pub fn build_login_ui_v2_script(login_js: &str) -> String {
    let expr = "loginUi(JSON.parse(String(__loginState)))";
    format!("{}\n{}", login_js, wrap_normalize(expr))
}

/// 构建 `loginAction(action, state, form)` 执行脚本（对齐 Kotlin `BaseSource.evalLoginActionV2`）
///
/// 调用方需注入绑定 `__loginAction` / `__loginState` / `__loginForm`（均为 JSON 字符串）。
pub fn build_login_action_v2_script(login_js: &str) -> String {
    let expr = "loginAction(String(__loginAction), JSON.parse(String(__loginState)), \
                JSON.parse(String(__loginForm)))";
    format!("{}\n{}", login_js, wrap_normalize(expr))
}

/// 将 JS 求值结果映射为 `Option<String>`：
/// `"null"`/`"undefined"`/空白 视为无结果（对齐 Kotlin 返回 null）
fn normalize_optional(raw: String) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed == "null" || trimmed == "undefined" {
        None
    } else {
        Some(raw)
    }
}

/// 执行登录 UI V2 动态渲染脚本（对齐 Kotlin `BaseSource.evalLoginUiV2`）
///
/// - `source`：书源（提供 mainJs/loginUrl 登录脚本）
/// - `state_json`：当前状态 JSON（首次渲染传 `"{}"`）
/// - `eval_js`：JS 求值器闭包，接收（脚本, 绑定变量）
///
/// 缺少登录脚本时返回错误（对齐 Kotlin 抛出"缺少 loginUi/loginAction 脚本"）。
pub fn eval_login_ui_v2(
    source: &BookSource,
    state_json: &str,
    eval_js: EvalJs,
) -> LegadoResult<Option<String>> {
    let login_js = get_login_js(source)
        .ok_or_else(|| LegadoError::JsEngine("登录UI v2 缺少 loginUi/loginAction 脚本".into()))?;
    let script = build_login_ui_v2_script(&login_js);
    let bindings = [("__loginState", state_json)];
    let raw = eval_js(&script, &bindings)?;
    Ok(normalize_optional(raw))
}

/// 执行登录 UI V2 动作脚本（对齐 Kotlin `BaseSource.evalLoginActionV2`）
///
/// - `action`：按钮动作名；`state_json`：当前状态 JSON；`form_json`：表单 JSON
/// - `eval_js`：JS 求值器闭包
///
/// 返回命令 JSON 原文（用 [`parse_action_result`] 解析）。
///
/// 注：#488 上游修复的"登录前脚本阻塞"源于 Kotlin 侧旧版确认按钮
/// 在 V2 流程前串行执行遗留 `login()` 脚本；Rust 侧 V2 动作直接执行
/// `loginAction`，不前置任何遗留登录脚本，执行顺序天然无该问题。
pub fn eval_login_action_v2(
    source: &BookSource,
    action: &str,
    state_json: &str,
    form_json: &str,
    eval_js: EvalJs,
) -> LegadoResult<Option<String>> {
    let login_js = get_login_js(source)
        .ok_or_else(|| LegadoError::JsEngine("登录UI v2 缺少 loginUi/loginAction 脚本".into()))?;
    let script = build_login_action_v2_script(&login_js);
    let bindings = [
        ("__loginAction", action),
        ("__loginState", state_json),
        ("__loginForm", form_json),
    ];
    let raw = eval_js(&script, &bindings)?;
    Ok(normalize_optional(raw))
}

// ============================================================
// 测试
// ============================================================
#[cfg(test)]
mod tests {
    use super::*;

    fn source_with(login_ui: Option<&str>, login_url: Option<&str>, main_js: Option<&str>) -> BookSource {
        BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "登录测试".to_string(),
            login_ui: login_ui.map(String::from),
            login_url: login_url.map(String::from),
            main_js: main_js.map(String::from),
            ..Default::default()
        }
    }

    // ─── is_v2 判定 ──────────────────────────────

    #[test]
    fn test_is_v2_marker() {
        assert!(is_v2(Some(MARKER)));
        assert!(is_v2(Some(r#"  {"version":2}  "#)));
        assert!(is_v2(Some(r#"{"version": 2, "extra": 1}"#)));
    }

    #[test]
    fn test_is_v2_negative() {
        assert!(!is_v2(None));
        assert!(!is_v2(Some("")));
        assert!(!is_v2(Some("[]")));
        assert!(!is_v2(Some(r#"{"version":1}"#)));
        assert!(!is_v2(Some(r#"[{"name":"用户名"}]"#)));
        assert!(!is_v2(Some("{not json")));
        assert!(!is_v2(Some("https://example.com/login")));
    }

    // ─── extract_inline_js / get_login_js ─────────

    #[test]
    fn test_extract_inline_js() {
        assert_eq!(
            extract_inline_js(Some("<js>function login(){} </js>")),
            Some("function login(){}".to_string())
        );
        assert_eq!(
            extract_inline_js(Some("@js:function login(){}")),
            Some("function login(){}".to_string())
        );
        // 忽略大小写（对齐 Kotlin CASE_INSENSITIVE）
        assert_eq!(
            extract_inline_js(Some("<JS>abc</JS>")),
            Some("abc".to_string())
        );
        // 非整串匹配 → None
        assert_eq!(extract_inline_js(Some("https://a.com@js:x")), None);
        assert_eq!(extract_inline_js(Some("plain url")), None);
        assert_eq!(extract_inline_js(None), None);
    }

    #[test]
    fn test_get_login_js_main_js_priority() {
        // JS 单文件书源：mainJs 优先
        let src = source_with(Some(MARKER), Some("https://login.url"), Some("function loginUi(){}"));
        assert_eq!(get_login_js(&src), Some("function loginUi(){}".to_string()));
    }

    #[test]
    fn test_get_login_js_login_url_inline() {
        let src = source_with(Some(MARKER), Some("@js:function loginUi(){}"), None);
        assert_eq!(get_login_js(&src), Some("function loginUi(){}".to_string()));
    }

    #[test]
    fn test_get_login_js_login_url_plain() {
        // 非内联模式时整段作为 JS
        let src = source_with(Some(MARKER), Some("function loginUi(){}"), None);
        assert_eq!(get_login_js(&src), Some("function loginUi(){}".to_string()));
        // 无脚本 → None
        let empty = source_with(Some(MARKER), None, None);
        assert_eq!(get_login_js(&empty), None);
    }

    // ─── parse_render ─────────────────────────────

    #[test]
    fn test_parse_render_ok() {
        let json = r#"{"rows":[
            {"key":"phone","name":"手机号","type":"text","hint":"请输入手机号"},
            {"name":"提示","type":"label"},
            {"key":"area","name":"区号","type":"select","options":["+86","+1"],"value":"+86"},
            {"name":"发送验证码","type":"button","action":"sendCode","countdown":60}
        ]}"#;
        let rows = parse_render(Some(json)).expect("应解析成功");
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].key.as_deref(), Some("phone"));
        assert_eq!(rows[0].hint.as_deref(), Some("请输入手机号"));
        assert_eq!(rows[2].options, Some(vec!["+86".to_string(), "+1".to_string()]));
        assert_eq!(rows[2].value.as_deref(), Some("+86"));
        assert_eq!(rows[3].countdown, Some(60));
    }

    #[test]
    fn test_parse_render_invalid_inputs() {
        assert_eq!(parse_render(None), None);
        assert_eq!(parse_render(Some("")), None);
        assert_eq!(parse_render(Some("not json")), None);
        // 缺少 rows
        assert_eq!(parse_render(Some(r#"{"foo":1}"#)), None);
        // rows 非数组
        assert_eq!(parse_render(Some(r#"{"rows":{}}"#)), None);
        // rows 为空
        assert_eq!(parse_render(Some(r#"{"rows":[]}"#)), None);
    }

    #[test]
    fn test_parse_render_row_validation() {
        // name 为空 → 非法
        assert!(parse_render(Some(r#"{"rows":[{"key":"a","name":"","type":"text"}]}"#)).is_none());
        // countdown 为负 → 非法
        assert!(parse_render(Some(
            r#"{"rows":[{"name":"x","type":"button","action":"a","countdown":-1}]}"#
        ))
        .is_none());
        // text 缺 key → 非法
        assert!(parse_render(Some(r#"{"rows":[{"name":"a","type":"text"}]}"#)).is_none());
        // select 缺 options → 非法
        assert!(parse_render(Some(r#"{"rows":[{"key":"a","name":"a","type":"select"}]}"#)).is_none());
        // button 缺 action → 非法
        assert!(parse_render(Some(r#"{"rows":[{"name":"b","type":"button"}]}"#)).is_none());
        // toggle 类型在 V2 中不支持 → 非法
        assert!(parse_render(Some(r#"{"rows":[{"key":"a","name":"a","type":"toggle"}]}"#)).is_none());
    }

    #[test]
    fn test_parse_render_duplicate_keys_and_actions() {
        // key 重复 → 非法
        assert!(parse_render(Some(
            r#"{"rows":[{"key":"a","name":"1","type":"text"},{"key":"a","name":"2","type":"password"}]}"#
        ))
        .is_none());
        // action 重复 → 非法
        assert!(parse_render(Some(
            r#"{"rows":[{"name":"1","type":"button","action":"go"},{"name":"2","type":"button","action":"go"}]}"#
        ))
        .is_none());
    }

    // ─── parse_action_result ──────────────────────

    #[test]
    fn test_parse_action_result_empty() {
        let r = parse_action_result(None);
        assert!(!r.malformed);
        assert!(!r.close);
        assert!(r.state_json.is_none());

        // JS 返回 undefined 时经规范化为 null，eval 层已映射为 None（无命令）；
        // 字面量 "null" 字符串本身不是合法命令对象（对齐 Kotlin GSON 解析失败）
        assert!(parse_action_result(Some("null")).malformed);
    }

    #[test]
    fn test_parse_action_result_state() {
        let r = parse_action_result(Some(r#"{"state":{"step":"code","phone":"+86138"}}"#));
        assert!(!r.malformed);
        let state = r.state_json.unwrap();
        assert!(state.contains("code"));
        assert!(state.contains("+86138"));
    }

    #[test]
    fn test_parse_action_result_error_login_close() {
        let r = parse_action_result(Some(
            r#"{"error":{"phone":"手机号必填"},"login":{"token":"tk"},"close":true}"#,
        ));
        assert!(!r.malformed);
        assert_eq!(r.error.as_ref().unwrap().get("phone").unwrap(), "手机号必填");
        assert_eq!(r.login_json.as_deref(), Some(r#"{"token":"tk"}"#));
        assert!(r.close);
    }

    #[test]
    fn test_parse_action_result_malformed() {
        // 非法 JSON
        assert!(parse_action_result(Some("{bad")).malformed);
        // state 非对象
        assert!(parse_action_result(Some(r#"{"state":"x"}"#)).malformed);
        // error 非对象
        assert!(parse_action_result(Some(r#"{"error":[1]}"#)).malformed);
        // close 非布尔
        assert!(parse_action_result(Some(r#"{"close":"yes"}"#)).malformed);
        // 顶层非对象
        assert!(parse_action_result(Some("[1,2]")).malformed);
    }

    #[test]
    fn test_parse_action_result_unknown_keys() {
        let r = parse_action_result(Some(r#"{"close":true,"fly":1}"#));
        assert!(!r.malformed);
        assert_eq!(r.unknown_keys, vec!["fly".to_string()]);
    }

    // ─── resolve_field_value ──────────────────────

    #[test]
    fn test_resolve_field_value_priority() {
        assert_eq!(
            resolve_field_value(Some("render"), Some("session"), Some("stored")),
            Some("render".to_string())
        );
        assert_eq!(
            resolve_field_value(None, Some("session"), Some("stored")),
            Some("session".to_string())
        );
        assert_eq!(resolve_field_value(None, None, Some("stored")), Some("stored".to_string()));
        assert_eq!(resolve_field_value(None, None, None), None);
    }

    // ─── eval（mock JS 引擎） ─────────────────────

    /// mock 求值器：按脚本是否含 loginAction 区分两种调用，返回固定结果
    #[test]
    fn test_eval_login_ui_v2_mock() {
        let src = source_with(Some(MARKER), Some("function loginUi(s){}"), None);
        let mut calls: Vec<(String, Vec<(String, String)>)> = Vec::new();
        let result = eval_login_ui_v2(&src, "{}", &mut |script, bindings| {
            calls.push((
                script.to_string(),
                bindings.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect(),
            ));
            Ok(r#"{"rows":[{"key":"account","name":"账号","type":"text"}]}"#.to_string())
        })
        .unwrap();
        assert!(result.unwrap().contains("account"));
        // 脚本必须包含登录 JS 与 loginUi 调用表达式
        assert!(calls[0].0.starts_with("function loginUi(s){}"));
        assert!(calls[0].0.contains("loginUi(JSON.parse(String(__loginState)))"));
        // 绑定必须携带 __loginState
        assert_eq!(calls[0].1, vec![("__loginState".to_string(), "{}".to_string())]);
    }

    #[test]
    fn test_eval_login_action_v2_mock() {
        let src = source_with(Some(MARKER), None, Some("function loginAction(a,s,f){}"));
        let mut captured: Vec<(String, String)> = Vec::new();
        let result = eval_login_action_v2(&src, "sendCode", r#"{"step":1}"#, r#"{"phone":"138"}"#, &mut |script, bindings| {
            captured = bindings.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
            assert!(script.contains("loginAction(String(__loginAction)"));
            Ok(r#"{"close":true}"#.to_string())
        })
        .unwrap();
        assert_eq!(result.as_deref(), Some(r#"{"close":true}"#));
        assert_eq!(
            captured,
            vec![
                ("__loginAction".to_string(), "sendCode".to_string()),
                ("__loginState".to_string(), r#"{"step":1}"#.to_string()),
                ("__loginForm".to_string(), r#"{"phone":"138"}"#.to_string()),
            ]
        );
    }

    #[test]
    fn test_eval_login_ui_v2_missing_script() {
        let src = source_with(Some(MARKER), None, None);
        let err = eval_login_ui_v2(&src, "{}", &mut |_, _| Ok("null".to_string())).unwrap_err();
        assert!(err.to_string().contains("缺少 loginUi/loginAction 脚本"));
    }

    #[test]
    fn test_eval_returns_none_for_null_result() {
        let src = source_with(Some(MARKER), Some("function loginUi(s){}"), None);
        let result = eval_login_ui_v2(&src, "{}", &mut |_, _| Ok("null".to_string())).unwrap();
        assert!(result.is_none());
    }

    // ─── RowUi 扩展字段序列化 ──────────────────────

    #[test]
    fn test_row_ui_v2_fields_serde() {
        let json = r#"{"name":"验证码","type":"text","key":"code","hint":"6位数字","value":"123456","countdown":60}"#;
        let row: RowUi = serde_json::from_str(json).unwrap();
        assert_eq!(row.key.as_deref(), Some("code"));
        assert_eq!(row.hint.as_deref(), Some("6位数字"));
        assert_eq!(row.value.as_deref(), Some("123456"));
        assert_eq!(row.countdown, Some(60));
        // 回序列保持 camelCase 字段名
        let out = serde_json::to_string(&row).unwrap();
        assert!(out.contains("\"key\":\"code\""));
        assert!(out.contains("\"countdown\":60"));
    }

    #[test]
    fn test_row_ui_select_options_serde() {
        let json = r#"{"name":"区号","type":"select","key":"area","options":["+86","+1"]}"#;
        let row: RowUi = serde_json::from_str(json).unwrap();
        assert_eq!(row.options.unwrap(), vec!["+86".to_string(), "+1".to_string()]);
    }

    #[test]
    fn test_row_ui_equals_kotlin_semantics() {
        // Kotlin equals 仅比较 name/type/action/default
        let a: RowUi = serde_json::from_str(r#"{"name":"a","type":"text","key":"k1"}"#).unwrap();
        let b: RowUi = serde_json::from_str(r#"{"name":"a","type":"text","key":"k2"}"#).unwrap();
        assert_eq!(a, b);
    }
}
