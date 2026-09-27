//! Source loginCheckJs check for legado-server (align FFI web_book::execute_login_check).
//!
//! [STAGE4-P36] 与 ffi 侧 F1（P3-6 A，WebBook.kt `evalJS(...) as StrResponse`
//! 强 cast 语义）逐点对齐的**最小本地副本**——server 与 ffi 不共享代码
//! （依赖方向 ffi → server，提取共享 crate 超出本任务范围）：
//! - 完成值按 StrResponse 对象解析（分叉点1：裸布尔/数字/字符串/null/
//!   undefined 不能 cast 为响应对象 → CastFailed 错误路径，不再按字符串
//!   内容判定）；
//! - 首检 JsFailed/CastFailed → errResponse(500) 二次 eval（分叉点2）：
//!   二次 code==500 或 cast/JS 失败 ⇒ `LoginRequired`（整源失败，HTTP 401 /
//!   code 1012）；二次 code≠500 ⇒ 放行并**采用二次结果**；
//! - JS 修改的响应（自动登录场景）被返回，调用方解析改用修改后的
//!   body/url（分叉点3，对齐原版 `analyzeBookList(baseUrl=res.url,
//!   body=res.body)`）；
//! - 非 quickjs 构建：静默直通原始响应三元组（短路在 cast 解析逻辑之前，
//!   v7a 无 JS 降级决策不变）。
//!
//! 引擎对等性：server 的 `eval_js` 与 ffi `QuickJsExecutor` 同包
//! `legado_js::QuickJsEngine` → 完成值序列化规则一致（对象 → JSON 文本、
//! 函数属性丢弃；字符串/布尔/null/undefined 原始文本），最小副本安全。

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};

/// loginCheckJs 检测响应结果（对齐原版 `StrResponse`：code/body/url；
/// 与 ffi `js_executor::LoginCheckResponse` 同形最小副本）
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginCheckResponse {
    /// 响应码（JS 修改值；缺失/类型不符时回退原响应码）
    pub code: u16,
    /// 响应体（JS 修改值；缺失/类型不符时回退原响应体）
    pub body: String,
    /// 响应 URL（JS 修改值；缺失/类型不符时回退原响应 URL）
    pub url: String,
}

// 非 quickjs 档：直通短路，变体从不构造（quickjs 档经
// parse_login_check_completion 构造）→ 按档 allow 防 clippy -D warnings
#[cfg_attr(not(feature = "quickjs"), allow(dead_code))]
#[derive(Debug)]
enum LoginCheckEvalError {
    /// JS 返回值无法解析为响应对象（原版 ClassCastException 语义）
    CastFailed(String),
    /// JS 执行失败（引擎/脚本错误）
    JsFailed(String),
}

impl std::fmt::Display for LoginCheckEvalError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::CastFailed(m) => write!(f, "{m}"),
            Self::JsFailed(m) => write!(f, "{m}"),
        }
    }
}

/// Run loginCheckJs; passthrough (original triple) when unset.
///
/// 返回值 = 解析应采用的响应（JS 修改值或原始值）；Err 上抛
/// `LoginRequired`（code 1012）。
pub fn execute_login_check(
    source: &BookSource,
    response_body: &str,
    response_url: &str,
    response_code: u16,
) -> LegadoResult<LoginCheckResponse> {
    let login_check_js = match &source.login_check_js {
        Some(js) if !js.trim().is_empty() => js.as_str(),
        // [WebBook.kt:77] checkJs 为空 → 原始响应直通
        _ => {
            return Ok(LoginCheckResponse {
                code: response_code,
                body: response_body.to_string(),
                url: response_url.to_string(),
            })
        }
    };

    // 首检（成功响应）：完成值按 StrResponse 对象解析
    let first = run_login_check_response(
        login_check_js,
        response_body,
        response_url,
        response_code,
        &source.book_source_url,
    );
    if let Ok(resp) = first {
        return Ok(resp);
    }
    let first_err = first.unwrap_err();

    // [WebBook.kt:84-87] 错误路径：构造 errResponse（code 500，
    // body = 首次失败原因，对齐 getErrStrResponse 的 body=stackTraceStr）
    let err_body = format!("HTTP/1.1 500 Internal Server Error\n\n{first_err}");
    match run_login_check_response(
        login_check_js,
        &err_body,
        response_url,
        500,
        &source.book_source_url,
    ) {
        // [WebBook.kt:88-90] 二次 code==500 → 整源失败（重抛原始 throwable）
        Ok(second) if second.code == 500 => {
            eprintln!(
                "[server login_check] second eval still code 500 (whole source fail): src={}",
                source.book_source_url
            );
            Err(LegadoError::LoginRequired(
                "书源需要登录，请先在书源菜单中登录后重试".into(),
            ))
        }
        // [WebBook.kt:88] 块值 = 二次返回值 res：放行并采用二次结果
        Ok(second) => Ok(second),
        // [WebBook.kt:91-94] 二次 eval 失败（cast/JS）→ 整源失败
        Err(second_err) => {
            eprintln!(
                "[server login_check] second eval failed (whole source fail): {second_err}: src={}",
                source.book_source_url
            );
            Err(LegadoError::LoginRequired(
                "书源需要登录，请先在书源菜单中登录后重试".into(),
            ))
        }
    }
}

/// 执行 loginCheckJs 并按 StrResponse 对象语义解析完成值（quickjs 档；
/// 最小副本自 ffi `js_executor::execute_login_check_response`）
#[cfg(feature = "quickjs")]
fn run_login_check_response(
    js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    source_tag: &str,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("body escape: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("url escape: {e}")))?;
    // [能力对账批次 2 | #702/#850] var → globalThis 属性注入（与 ffi 侧
    // js_executor 同款改造保持一致；本路径每次新建 QuickJsEngine 无池化，
    // 属性注入不改变行为，仅不注册全局 var 条目）
    let wrapped_code = format!(
        "globalThis.__result_body = {body_lit};\n\
         globalThis.__result_url = {url_lit};\n\
         globalThis.__result_code = {response_code};\n\
         globalThis.result = {{ body: function() {{ return __result_body; }},\n\
         url: function() {{ return __result_url; }},\n\
         code: function() {{ return __result_code; }} }};\n\
         {js_code}"
    );

    let eval_result = eval_js(&wrapped_code, source_tag)?;
    parse_login_check_completion(&eval_result, response_body, response_url, response_code)
}

/// 非 quickjs 构建：静默直通原始响应三元组（短路在 cast 解析逻辑之前——
/// 空完成值若走解析会 CastFailed 误判整源失败；v7a 无 JS 降级决策不变）
#[cfg(not(feature = "quickjs"))]
fn run_login_check_response(
    _js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    _source_tag: &str,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    Ok(LoginCheckResponse {
        code: response_code,
        body: response_body.to_string(),
        url: response_url.to_string(),
    })
}

/// 解析 loginCheckJs 完成值（纯函数，对齐原版 `as StrResponse` 语义；
/// 最小副本自 ffi `parse_login_check_completion`）：
/// - `{}`（方法形 result 直通：JSON.stringify 丢弃函数属性）→ 原始响应三元组；
/// - `{` 开头的 JSON 对象 → 修改后响应（body/url/code 字段缺失或类型不符
///   时逐项回退原值）；
/// - 其余文本（裸布尔/数字/字符串/null/undefined 的序列化结果）→
///   CastFailed（对齐原版 ClassCastException 错误路径）。
#[cfg(feature = "quickjs")]
fn parse_login_check_completion(
    completion: &str,
    body: &str,
    url: &str,
    code: u16,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    let trimmed = completion.trim();
    if !trimmed.starts_with('{') {
        // 完成值序列化：string 原始输出（无引号）、bool → true/false、
        // number 数值文本、null → "null"、undefined → "undefined"、
        // 对象/数组 → JSON 文本（函数属性被丢弃）。
        return Err(LoginCheckEvalError::CastFailed(format!(
            "loginCheckJs return value cannot be parsed as response object (original as StrResponse failed): {trimmed}"
        )));
    }
    let v: serde_json::Value = serde_json::from_str(trimmed).map_err(|e| {
        LoginCheckEvalError::CastFailed(format!("loginCheckJs object JSON parse failed: {e}"))
    })?;
    let obj = v.as_object().ok_or_else(|| {
        LoginCheckEvalError::CastFailed(format!(
            "loginCheckJs return value is not a response object: {trimmed}"
        ))
    })?;
    let resp_body = obj
        .get("body")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| body.to_string());
    let resp_url = obj
        .get("url")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .unwrap_or_else(|| url.to_string());
    let resp_code = obj
        .get("code")
        .and_then(|v| v.as_u64())
        .and_then(|c| u16::try_from(c).ok())
        .unwrap_or(code);
    Ok(LoginCheckResponse {
        code: resp_code,
        body: resp_body,
        url: resp_url,
    })
}

#[cfg(feature = "quickjs")]
fn eval_js(code: &str, source_tag: &str) -> Result<String, LoginCheckEvalError> {
    use legado_js::engine::JsEngine;
    use legado_js::host_api::current_source;
    use legado_js::sandbox::SandboxConfig;
    use legado_js::QuickJsEngine;

    let engine = QuickJsEngine::new(SandboxConfig::default())
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("js init: {e}")))?;
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
            .map_err(|e| LoginCheckEvalError::JsFailed(format!("loginCheckJs: {e}")))
    })
}

// 非 quickjs 档：直通短路不调 eval_js（quickjs 档经
// run_login_check_response 调用）→ allow 防 clippy -D warnings
#[cfg(not(feature = "quickjs"))]
#[allow(dead_code)]
fn eval_js(_code: &str, _source_tag: &str) -> Result<String, LoginCheckEvalError> {
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

    /// [STAGE4-P36] 裸布尔 `false` 完成值 → cast 失败 → 二次 errResponse(500)
    /// eval 仍 cast 失败 → 整源 LoginRequired（新语义经 cast 失败机制成立；
    /// 旧谓词语义下该用例同样绿，判定路径不同）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn not_logged_in_raises_login_required() {
        let s = source_with_js("false");
        let err = execute_login_check(&s, "need login", "http://x", 200).unwrap_err();
        assert!(matches!(err, LegadoError::LoginRequired(_)));
        assert_eq!(err.to_error_code(), 1012);
    }

    /// [STAGE4-P36] 三叉点 2（二次 eval code≠500 → 放行并采用二次结果）：
    /// 正常响应（code 200）下 JS 返回裸字符串 `"false"` → cast 失败走错误
    /// 路径；errResponse(500) 二次 eval 时 JS 自动登录并返回修改响应
    /// `{code: 200, body: ...}`（code≠500）→ 放行且采用二次结果（对齐
    /// 原版 WebBook.kt:88「块值 = 二次返回值 res」，url 缺失回退原值）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn second_adopt_modified_response() {
        let js = r#"result.code() === 500 ? {code: 200, body: "auto-login-ok"} : "false""#;
        let s = source_with_js(js);
        let r = execute_login_check(&s, "<html>登录页</html>", "http://x", 200)
            .expect("二次 eval code≠500 应放行");
        assert_eq!(r.body, "auto-login-ok", "应采用二次修改响应体");
        assert_eq!(r.code, 200);
        assert_eq!(r.url, "http://x", "缺失字段应回退原 URL");
    }

    /// [STAGE4-P36] 三叉点 3（JS 修改的响应首检采纳）：正常响应下 JS 直接
    /// 返回修改响应对象（自动登录场景）→ 首检成功即采用修改值（对齐原版
    /// `analyzeBookList(baseUrl = res.url, body = res.body)`）。注意：QuickJS
    /// 顶层禁 `return`，对象完成值一律用括号表达式形式（见 ffi
    /// `login_check_response_method_form_passthrough` 同注）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn modified_response_adopted() {
        let js = r#"({code: 200, body: "modified-body", url: "http://y/new"})"#;
        let s = source_with_js(js);
        let r = execute_login_check(&s, "body", "http://x", 200).expect("JS 修改响应应首检成功");
        assert_eq!(r.body, "modified-body", "应采用 JS 修改的响应体");
        assert_eq!(r.url, "http://y/new", "应采用 JS 修改的 URL");
        assert_eq!(r.code, 200);
    }

    /// 无 loginCheckJs 配置 → 原始响应三元组直通（对齐 WebBook.kt:77
    /// checkJs 为空直通；两档均成立——非 quickjs 档经直通短路）。
    #[test]
    fn no_config_passthrough_original_triple() {
        let s = BookSource::default();
        let r = execute_login_check(&s, "orig body", "http://orig", 201).expect("直通");
        assert_eq!(r.body, "orig body");
        assert_eq!(r.url, "http://orig");
        assert_eq!(r.code, 201);
    }

    /// [STAGE4-P36] 新语义（对齐原版 WebBook.kt `evalJS(...) as StrResponse` cast
    /// 语义 + ffi F1 三叉点）：裸布尔完成值 `true` 无法 cast 为响应对象 →
    /// cast 失败 → 二次 errResponse(500) eval 仍失败 → 整源 LoginRequired
    /// （旧谓词语义会把 `true` 当「已登录」放行——红测试证明该差异）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn bare_true_whole_source_fail() {
        let s = source_with_js("true");
        let err = execute_login_check(&s, "ok body", "http://x", 200).unwrap_err();
        assert!(matches!(err, LegadoError::LoginRequired(_)));
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
        // 为 (options: String)）+ 方法形 `result` 直通完成值（[STAGE4-P36]
        // 新 StrResponse cast 语义下裸字符串完成值会 cast 失败整源失败，
        // 方法形 result → JSON.stringify 丢弃函数属性 → `{}` → 回退原始
        // 响应三元组放行，与 ffi F1 `login_check_response_method_form_passthrough`
        // 同语义）
        let js = format!(r#"java.ajax('{{"url":"http://{addr}/echo"}}'); result"#);
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
