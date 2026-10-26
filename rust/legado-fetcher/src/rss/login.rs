//! RSS `loginCheckJs` 执行（批15b）
//!
//! 逐行对齐原版 `Rss.getArticlesAwait`（`Rss.kt:57-81`）：
//!
//! ```text
//! res = analyzeUrl.getStrResponseAwait()
//!   ├─ 成功：checkJs 非空 → evalJS(checkJs, res) as StrResponse
//!   └─ 失败：checkJs 非空 → errResponse = getErrStrResponse(e)
//!          （code 500，body = 原始错误栈）→ 二次 evalJS
//!            ├─ 二次 code == 500 → throw 原始错误（登录失败）
//!            └─ 否则采用二次结果（自动登录等场景）
//! ```
//!
//! 与书源 `web_book::execute_login_check` 同语义，差异：RSS 的 `evalJS`
//! 经 `RssSource` 的 jsLib + `source`/`java` 绑定执行（原版
//! `BaseSource.evalJS`），故本模块自带执行器上下文；响应解析口径与
//! `legado-js::login_check` 完全一致（`result.body()/url()/code()` 方法形
//! 与纯数据对象两态；其余完成值 → cast 失败）。

use legado_core::models::RssSource;
use legado_core::{LegadoError, LegadoResult};
use legado_js::login_check::{LoginCheckEvalError, LoginCheckResponse};

use super::request::RssListResponse;

/// 源是否配置了非空白 `loginCheckJs`
///
/// 原版判定为 `!checkJs.isNullOrBlank()`（`Rss.kt:60/188`），列表与正文页
/// 共用同一入口。
pub fn has_login_check(source: &RssSource) -> bool {
    source
        .login_check_js
        .as_deref()
        .map(|js| !js.trim().is_empty())
        .unwrap_or(false)
}

/// 请求结果统一登录门控（列表与正文页共用，对齐 `Rss.kt:57-81 / 186-209`）
///
/// 输入是「已完成的一次请求」（`Ok` 成功响应 / `Err` 请求失败），输出是
/// 经 `loginCheckJs` 判定后的响应：
///
/// - 无 checkJs：`Ok` 直通、`Err` 直通；
/// - 成功响应：以响应三元组执行 checkJs，采用返回（可能被修改）的响应；
///   首检失败时按 `getErrStrResponse`（code 500）二次 eval，二次非 500 则
///   采用二次结果，仍 500 / 二次执行失败 → `LoginRequired`；
/// - 请求失败：以错误文本构造 code 500 的 errResponse 二次 eval，二次
///   非 500 则采用（自动登录等场景），否则重抛**原始请求错误**（对齐
///   `throw throwable`）。
///
/// 调用方负责在请求前完成同源门控与 header/setup 构造（见
/// [`super::request::source_headers_with_login`]）。
pub fn gate_login(
    source: &RssSource,
    request_url: &str,
    setup_script: Option<String>,
    fetched: LegadoResult<RssListResponse>,
) -> LegadoResult<RssListResponse> {
    if !has_login_check(source) {
        return fetched;
    }
    match fetched {
        Ok(resp) => match apply_success_check(source, &resp, setup_script.clone()) {
            Ok(checked) => Ok(checked),
            Err(first_err) => match apply_error_check(
                source,
                &first_err,
                request_url,
                setup_script.clone(),
            ) {
                Ok(Some(second)) => Ok(second),
                Ok(None) => Err(LegadoError::LoginRequired(format!(
                    "RSS 源需要登录，请先在订阅源菜单中登录后重试（{first_err}）"
                ))),
                Err(second_err) => Err(LegadoError::LoginRequired(format!(
                    "RSS 源需要登录，请先在订阅源菜单中登录后重试（{first_err}；二次检测失败: {second_err}）"
                ))),
            },
        },
        Err(fetch_err) => {
            // 原始请求失败：errResponse（code 500）交给 checkJs（自动登录场景）
            match apply_error_check(
                source,
                &fetch_err.to_string(),
                request_url,
                setup_script.clone(),
            ) {
                Ok(Some(second)) => Ok(second),
                // 二次仍 500 / 二次执行失败 → 重抛原始错误（对齐 throw throwable）
                Ok(None) | Err(_) => Err(fetch_err),
            }
        }
    }
}

/// 成功响应路径的登录检测
///
/// `check_js` 空白 → 原样返回；否则以成功响应三元组执行 checkJs，
/// 采用 JS 返回（可能被修改）的响应。
pub fn apply_success_check(
    source: &RssSource,
    response: &RssListResponse,
    setup_script: Option<String>,
) -> Result<RssListResponse, String> {
    let Some(check_js) = source
        .login_check_js
        .as_deref()
        .filter(|js| !js.trim().is_empty())
    else {
        return Ok(response.clone());
    };
    match eval_login_check(
        source,
        check_js,
        &response.body,
        &response.final_url,
        response.status,
        setup_script,
    ) {
        Ok(checked) => Ok(RssListResponse {
            body: checked.body,
            final_url: checked.url,
            status: checked.code,
        }),
        Err(e) => Err(e.to_string()),
    }
}

/// 失败路径的登录检测（对应原版 `getErrStrResponse` + 二次 eval）
///
/// 返回：
/// - `Ok(Some(response))`：二次 eval 得到非 500 响应 → 采用该响应继续解析
///   （自动登录场景）；
/// - `Ok(None)`：二次 eval 仍返回 code 500 → 判定登录失败，调用方重抛原始错误；
/// - `Err(msg)`：二次 eval 自身失败（cast/JS 错误）→ 调用方重抛原始错误。
pub fn apply_error_check(
    source: &RssSource,
    error_text: &str,
    url: &str,
    setup_script: Option<String>,
) -> Result<Option<RssListResponse>, String> {
    let Some(check_js) = source
        .login_check_js
        .as_deref()
        .filter(|js| !js.trim().is_empty())
    else {
        return Ok(None);
    };
    let err_body = format!("HTTP/1.1 500 Internal Server Error\n\n{error_text}");
    match eval_login_check(source, check_js, &err_body, url, 500, setup_script) {
        Ok(checked) if checked.code == 500 => Ok(None),
        Ok(checked) => Ok(Some(RssListResponse {
            body: checked.body,
            final_url: checked.url,
            status: checked.code,
        })),
        Err(e) => Err(e.to_string()),
    }
}

/// 执行 checkJs 并按 `StrResponse` 对象语义解析完成值
#[cfg(feature = "quickjs")]
pub fn eval_login_check(
    source: &RssSource,
    js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    setup_script: Option<String>,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    use legado_parser::JsExecutor;

    let js_lib = source
        .js_lib
        .as_deref()
        .map(crate::js_adapter::sanitize_js_lib_for_quickjs);
    let executor = legado_js::executor::QuickJsExecutor::new(&source.source_url)
        .with_js_lib(js_lib)
        .with_setup_script(setup_script);

    // 注入方法形 result 绑定（对齐 Kotlin StrResponse：result.body()/url()/code()）
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("响应体转义失败: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("响应 URL 转义失败: {e}")))?;
    let wrapped_code = format!(
        "globalThis.__result_body = {body_lit};\n\
         globalThis.__result_url = {url_lit};\n\
         globalThis.__result_code = {response_code};\n\
         globalThis.result = {{ body: function() {{ return __result_body; }},\n\
         url: function() {{ return __result_url; }},\n\
         code: function() {{ return __result_code; }} }};\n\
         {js_code}"
    );
    let completion = executor
        .execute_js(&wrapped_code)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("loginCheckJs 执行失败: {e}")))?;
    parse_completion(&completion, response_body, response_url, response_code)
}

/// 非 quickjs 构建：无 JS 执行器 → 静默直通原始响应（E7 已登记降级）
#[cfg(not(feature = "quickjs"))]
pub fn eval_login_check(
    _source: &RssSource,
    _js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    _setup_script: Option<String>,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    Ok(LoginCheckResponse {
        code: response_code,
        body: response_body.to_string(),
        url: response_url.to_string(),
    })
}

/// 解析 checkJs 完成值（与 `legado_js::login_check` 私有解析同口径；
/// 因执行器上下文不同（jsLib/setup）无法直接复用私有函数，此处保持
/// 逐行等价并附同款注释）
#[cfg(feature = "quickjs")]
fn parse_completion(
    completion: &str,
    body: &str,
    url: &str,
    code: u16,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    let trimmed = completion.trim();
    if !trimmed.starts_with('{') {
        // 裸布尔/数字/字符串/null/undefined → 不能 cast 为 StrResponse
        return Err(LoginCheckEvalError::CastFailed(format!(
            "loginCheckJs 返回值无法解析为响应对象（对齐原版 as StrResponse 失败）: {trimmed}"
        )));
    }
    let value: serde_json::Value = serde_json::from_str(trimmed).map_err(|e| {
        LoginCheckEvalError::CastFailed(format!("loginCheckJs 返回对象 JSON 解析失败: {e}"))
    })?;
    let obj = value.as_object().ok_or_else(|| {
        LoginCheckEvalError::CastFailed(format!("loginCheckJs 返回值不是响应对象: {trimmed}"))
    })?;
    Ok(LoginCheckResponse {
        // 缺字段/类型不符 → 回退原值（方法形 result 直通时 JSON.stringify
        // 丢弃函数属性 → `{}` → 三元组原样回退）
        code: obj
            .get("code")
            .and_then(|v| v.as_u64())
            .and_then(|c| u16::try_from(c).ok())
            .unwrap_or(code),
        body: obj
            .get("body")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| body.to_string()),
        url: obj
            .get("url")
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .unwrap_or_else(|| url.to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(feature = "quickjs")]
    fn source_with_check(check_js: &str) -> RssSource {
        RssSource {
            source_url: "https://rss-login.example.com/feed".to_string(),
            login_check_js: Some(check_js.to_string()),
            ..RssSource::default()
        }
    }

    fn response() -> RssListResponse {
        RssListResponse {
            body: "<rss>原始响应</rss>".to_string(),
            final_url: "https://rss-login.example.com/list".to_string(),
            status: 200,
        }
    }

    /// 无 checkJs：成功/失败路径都直通
    #[test]
    fn no_check_js_passthrough() {
        let source = RssSource {
            source_url: "https://rss-login.example.com/feed".to_string(),
            ..RssSource::default()
        };
        let out = apply_success_check(&source, &response(), None).expect("直通");
        assert_eq!(out, response());
        assert_eq!(apply_error_check(&source, "boom", "u", None), Ok(None));
    }

    /// 成功响应：JS 返回纯数据对象 → 采用修改后的响应
    #[cfg(feature = "quickjs")]
    #[test]
    fn success_check_adopts_modified_response() {
        let source = source_with_check(
            "(function(){ if (result.body().indexOf('未登录') >= 0) return { code: 401, body: '需要登录', url: result.url() }; return result; })()",
        );
        let out =
            apply_success_check(&source, &response(), Some(rss_setup(&source))).expect("执行成功");
        assert_eq!(out.status, 200, "`return result` 方法形直通 → 原值");
        assert_eq!(out.body, "<rss>原始响应</rss>");

        let mut login_failed = response();
        login_failed.body = "未登录".to_string();
        let out = apply_success_check(&source, &login_failed, Some(rss_setup(&source)))
            .expect("执行成功");
        assert_eq!(out.status, 401);
        assert_eq!(out.body, "需要登录");
    }

    /// 成功响应：JS 返回裸布尔 → cast 失败 → 首个错误进入错误路径；
    /// 错误路径二次 eval 返回非 500 → 采用二次结果
    #[cfg(feature = "quickjs")]
    #[test]
    fn failed_cast_then_error_path_can_recover() {
        // 首检返回 true（cast 失败）；二次 eval 时 result.code()==500 → 返回
        // 修改后的响应（模拟自动登录）
        let source = source_with_check(
            "(function(){ if (result.code() === 500) return { code: 200, body: '自动登录后正文', url: result.url() }; return true; })()",
        );
        let first_err = apply_success_check(&source, &response(), Some(rss_setup(&source)))
            .expect_err("首检 cast 失败");
        assert!(first_err.contains("无法解析为响应对象"), "{first_err}");

        let second = apply_error_check(
            &source,
            &first_err,
            "https://rss-login.example.com/list",
            Some(rss_setup(&source)),
        )
        .expect("二次 eval 执行");
        let second = second.expect("非 500 应放行");
        assert_eq!(second.status, 200);
        assert_eq!(second.body, "自动登录后正文");
    }

    /// 错误路径二次 eval 仍 500 → 判定登录失败（返回 None）
    #[cfg(feature = "quickjs")]
    #[test]
    fn error_path_still_500_means_login_required() {
        let source = source_with_check(
            "(function(){ if (result.code() === 500) return result; return true; })()",
        );
        assert_eq!(
            apply_error_check(&source, "原始网络错误", "u", Some(rss_setup(&source))),
            Ok(None)
        );
    }

    /// 错误路径二次 eval 自身抛错 → Err（调用方重抛原始错误）
    #[cfg(feature = "quickjs")]
    #[test]
    fn error_path_js_failure_returns_err() {
        let source = source_with_check("throw new Error('脚本炸了')");
        assert!(apply_error_check(&source, "原始网络错误", "u", Some(rss_setup(&source))).is_err());
    }

    /// `source` 绑定可用于 loginCheckJs（原版 BaseSource.evalJS 语义）
    #[cfg(feature = "quickjs")]
    #[test]
    fn check_js_can_read_source_binding() {
        let source = source_with_check(
            "(function(){ return { code: 200, body: source.getKey(), url: result.url() }; })()",
        );
        let out = apply_success_check(&source, &response(), Some(rss_setup(&source)))
            .expect("source 绑定可用");
        assert_eq!(out.body, "https://rss-login.example.com/feed");
    }

    #[cfg(feature = "quickjs")]
    fn rss_setup(source: &RssSource) -> String {
        crate::source_setup::rss_source_js_setup_script(source, None, None).expect("setup")
    }
}
