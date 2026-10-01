//! loginCheckJs 响应解析内核（P5 下沉：ffi / server 共享单一实现）
//!
//! [P5-2 双副本消除] 本模块承接自 `legado-ffi/src/js_executor.rs` 的内核
//! （server `login_check.rs` 曾是其最小本地副本）：ffi 侧经
//! `pub use legado_js::login_check::*;` 薄壳 re-export（调用方
//! dict_api/explore_api/search/web_book 零改动），server 侧三叉点逻辑
//! （首检 → errResponse 二次 → LoginRequired）保留在 server，仅调用本模块
//! 的 [`execute_login_check_response`]。
//!
//! 语义（对齐原版 `evalJS(checkJs, it) as StrResponse`，WebBook.kt:74-99）：
//! - 注入方法形 `result` 绑定（body()/url()/code() 方法）；书源返回纯数据
//!   对象 `{ code, body, url }` 时采用修改后响应（缺字段回退原值）；
//! - 其余完成值（裸布尔/数字/字符串/null/undefined）→
//!   [`LoginCheckEvalError::CastFailed`]（对齐原版 ClassCastException）；
//! - 引擎沙箱档统一为 ffi 原版（`SandboxConfig::default()` +
//!   `with_allow_script_run(true)` + 64MB 内存，经 [`crate::executor::QuickJsExecutor`]）；
//! - 非 quickjs 构建：静默直通原始响应三元组（v7a 无 JS 降级决策不变）。

/// loginCheckJs 检测响应结果（对齐原版 `StrResponse`：code/body/url）
///
/// [P3-6 A | WebBook.kt:74-99] 原版 loginCheckJs 的 eval 结果按
/// `evalJS(checkJs, it) as StrResponse` 消费——JS 可以返回**修改后的响应**
/// （自动登录等场景），后续 `checkRedirect`/`analyzeBookList(baseUrl = res.url,
/// body = res.body)` 直接采用修改值。本结构承载该响应三元组。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginCheckResponse {
    /// 响应码（JS 修改值；缺失/类型不符时回退原响应码）
    pub code: u16,
    /// 响应体（JS 修改值；缺失/类型不符时回退原响应体）
    pub body: String,
    /// 响应 URL（JS 修改值；缺失/类型不符时回退原响应 URL）
    pub url: String,
}

/// loginCheckJs 执行/解析错误（对齐原版 `evalJS(checkJs, ...) as StrResponse`
/// 失败的错误路径语义，WebBook.kt:84-99）
#[derive(Debug, PartialEq, Eq)]
pub enum LoginCheckEvalError {
    /// JS 返回值无法解析为响应对象（等价原版 ClassCastException：
    /// 裸布尔/数字/字符串/null/undefined 完成值均不能 cast 为 StrResponse）
    CastFailed(String),
    /// JS 执行失败（引擎/脚本错误，如语法错误）
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

/// 执行 loginCheckJs 并按 StrResponse 对象语义解析完成值
/// （P3-6 A 分叉点1：取代旧谓词字符串判定，搜索/详情/explore 全链路
/// 统一走本函数——STAGE4-P36 后旧谓词 `execute_login_check_js` 已移除，
/// explore 链经 `web_book::RealBookSourceFetcher::execute_login_check`
/// 对齐同一三叉点语义）
///
/// - 注入方法形 `result` 绑定（body()/url()/code() 方法），
///   真实书源写法 `result.body()` 可用；
///   书源 `return result` 原样直通时，完成值为方法形对象，
///   `JSON.stringify` 丢弃函数属性 → 文本 `{}` → 解析回退原始响应三元组；
///   [能力对账批次 2 | #702/#850] 脚本空完成（末条为非空语句之前的
///   声明语句，如尾随 `var x = 1;`）时完成值同样回落为前导
///   `globalThis.result` 赋值 → `{}` 直通（规范语义，V8/Rhino 一致；
///   见 `login_check_response_method_form_passthrough` 测试注释）；
/// - 书源返回纯数据对象 `{ code, body, url }`（QuickJS 端口扩展，缺字段
///   回退原值）→ 修改后响应被采用；
/// - 其余完成值（裸布尔/数字/字符串/null/undefined，序列化文本不以 `{`
///   开头）→ [`LoginCheckEvalError::CastFailed`]（对齐原版 cast 失败）。
#[cfg(feature = "quickjs")]
pub fn execute_login_check_response(
    js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    source_tag: &str,
) -> Result<LoginCheckResponse, LoginCheckEvalError> {
    use legado_parser::JsExecutor;

    let executor = crate::executor::QuickJsExecutor::new(source_tag);

    // 注入方法形 result 绑定（对齐 Kotlin StrResponse 语义：
    // result.body()/url()/code() 方法调用）
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("响应体转义失败: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("响应 URL 转义失败: {e}")))?;
    // [能力对账批次 2 | #702/#850] var → globalThis 属性注入：不注册 QuickJS
    // 全局 var 条目，loginCheckJs 顶层 `let result` 等声明不再触发同脚本
    // redefinition（裸标识符读路径经全局属性等价）；跨 eval 的顶层 let
    // 持久化由 QuickJsExecutor 的 LEXICAL 新引擎回退兜底（既有机制）
    let wrapped_code = format!(
        "globalThis.__result_body = {body_lit};\n\
         globalThis.__result_url = {url_lit};\n\
         globalThis.__result_code = {response_code};\n\
         globalThis.result = {{ body: function() {{ return __result_body; }},\n\
         url: function() {{ return __result_url; }},\n\
         code: function() {{ return __result_code; }} }};\n\
         {js_code}"
    );
    let eval_result = executor
        .execute_js(&wrapped_code)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("loginCheckJs 执行失败: {e}")))?;

    parse_login_check_completion(&eval_result, response_body, response_url, response_code)
}

/// 解析 loginCheckJs 完成值（纯函数，对齐原版 `as StrResponse` 语义）：
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
        // 非 JSON 对象文本一律不能 cast 为 StrResponse → 错误路径。
        return Err(LoginCheckEvalError::CastFailed(format!(
            "loginCheckJs 返回值无法解析为响应对象（对齐原版 as StrResponse 失败）: {trimmed}"
        )));
    }
    let v: serde_json::Value = serde_json::from_str(trimmed).map_err(|e| {
        LoginCheckEvalError::CastFailed(format!("loginCheckJs 返回对象 JSON 解析失败: {e}"))
    })?;
    let obj = v.as_object().ok_or_else(|| {
        LoginCheckEvalError::CastFailed(format!("loginCheckJs 返回值不是响应对象: {trimmed}"))
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

/// 非 quickjs 构建下 loginCheckJs 对象解析降级：静默直通原始响应
/// （v7a 无 JS 降级决策不变——无引擎时原样返回响应三元组，短路在解析逻辑之前）
#[cfg(not(feature = "quickjs"))]
pub fn execute_login_check_response(
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

#[cfg(test)]
mod tests {
    use super::*;

    // [P3-6 A | WebBook.kt:74-99] loginCheckJs 按 StrResponse 对象解析完成值
    //（quickjs 为非默认 feature：仅在本 feature 启用时运行）
    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_response_method_form_passthrough() {
        // 方法形 result 原样直通（裸 `result` 完成值 → JSON.stringify 丢弃函数
        // 属性 → "{}"）→ 采用原始响应三元组。
        // 注意：QuickJS 顶层脚本禁 `return`（与原版 Rhino 容忍度差异，
        // 登记为端口已知差异），裸 `{...}` 在语句位置解析为块语句，
        // 故对象完成值一律用表达式形式（裸标识符/括号对象/三元）。
        let r = execute_login_check_response("result", "orig-body", "http://x/s", 200, "lit_test");
        assert_eq!(
            r,
            Ok(LoginCheckResponse {
                code: 200,
                body: "orig-body".into(),
                url: "http://x/s".into()
            }),
            "实际: {r:?}"
        );
        // [能力对账批次 2 | #702/#850] 尾随声明语句的完成值语义（var → globalThis
        // 属性注入的规范后果，V8/Rhino 同语义）：程序的完成值 = 最后一条
        // **非空**语句的值。`var x = 1;` 是空完成声明语句 → 程序完成值回落到
        // 前导最后一条非空语句 `globalThis.result = {...}`（表达式语句，值为
        // 方法形 result 对象）→ JSON.stringify 丢弃函数属性 → "{}" → 方法形
        // 直通分支 → 采用原始响应三元组。
        // 旧全 var 前导下同类脚本完成值 "undefined" → CastFailed，那是包装器
        // 自身空完成的附带产物；新包装器回落为 "{}" 直通对「loginCheckJs 未
        // 修改 result 且无完成值」更合理（= 未检出登录问题 → 放行原始响应，
        // 旧行为会误入 500 err 路径 → 二次 CastFailed → 整源失败）。
        // 现实形态（末条语句为表达式：result.body().contains(...)、裸 result、
        // ({...})）完成值不变，不受本差异影响。
        let r2 =
            execute_login_check_response("var x = 1;", "orig-body", "http://x/s", 200, "lit_test");
        assert_eq!(
            r2,
            Ok(LoginCheckResponse {
                code: 200,
                body: "orig-body".into(),
                url: "http://x/s".into()
            }),
            "实际: {r2:?}"
        );
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_response_modified_object_adopted() {
        // 纯数据对象（QuickJS 端口扩展）→ 修改后响应被采用；缺字段回退原值。
        // 括号对象表达式避免块语句解析（顶层禁 return，见上一测试注释）。
        let r = execute_login_check_response(
            "({ code: 403, body: 'new-body', url: 'http://alt/s2' })",
            "orig-body",
            "http://x/s",
            200,
            "lit_test",
        );
        assert_eq!(
            r,
            Ok(LoginCheckResponse {
                code: 403,
                body: "new-body".into(),
                url: "http://alt/s2".into()
            }),
            "实际: {r:?}"
        );
        // 只改 body，code/url 缺失 → 回退原值
        let r2 = execute_login_check_response(
            "({ body: 'patched' })",
            "orig-body",
            "http://x/s",
            302,
            "lit_test",
        );
        assert_eq!(
            r2,
            Ok(LoginCheckResponse {
                code: 302,
                body: "patched".into(),
                url: "http://x/s".into()
            }),
            "实际: {r2:?}"
        );
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_response_bare_values_cast_fail() {
        // 裸布尔/字符串/数字/null 完成值均非 StrResponse → CastFailed
        //（对齐原版 ClassCastException 错误路径）
        for js in ["false", "true", "'ok'", "42", "null", "undefined"] {
            let r = execute_login_check_response(js, "body", "http://x", 200, "lit_test");
            assert!(
                matches!(r, Err(LoginCheckEvalError::CastFailed(_))),
                "js={js} 应 CastFailed，实际: {r:?}"
            );
        }
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_response_js_error_classify() {
        // 语法/运行时错误归类为 JsFailed
        let r = execute_login_check_response("function {", "body", "http://x", 200, "lit_test");
        assert!(
            matches!(r, Err(LoginCheckEvalError::JsFailed(_))),
            "实际: {r:?}"
        );
        let r2 = execute_login_check_response(
            "throw new Error('boom');",
            "body",
            "http://x",
            200,
            "lit_test",
        );
        assert!(
            matches!(r2, Err(LoginCheckEvalError::JsFailed(_))),
            "实际: {r2:?}"
        );
    }

    /// 非 quickjs 构建：静默直通原始响应三元组（原 server 同名内核测试的
    /// 下沉版覆盖——无引擎时不得因空完成值误判 CastFailed）。
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn without_quickjs_passthrough_original_triple() {
        let r = execute_login_check_response("false", "orig-body", "http://x/s", 201, "t")
            .expect("无 JS 引擎应直通");
        assert_eq!(r.body, "orig-body");
        assert_eq!(r.url, "http://x/s");
        assert_eq!(r.code, 201);
    }
}
