//! JsExecutor 适配器（legado-ffi 层）
//!
//! 在 FFI 层把 legado-js 的 QuickJS 引擎池适配为 legado-parser 期望的
//! [`legado_parser::JsExecutor`]，从而打通书源 `@js:` 规则的执行链路。
//!
//! 设计要点：
//! - 保持 crate 依赖单向：legado-ffi 同时依赖 legado-js 与 legado-parser，
//!   由本层完成两者对接，避免 legado-parser ↔ legado-js 循环依赖。
//! - 复用 legado-js 的 [`EnginePool`]：按 `source_tag`（书源 URL）缓存
//!   `Arc<Mutex<QuickJsEngine>>`，避免每源重复创建 Runtime + Context。
//! - 全部以 `#[cfg(feature = "quickjs")]` 门控：feature 关闭时
//!   [`construct_analyzer`] 退化为 `AnalyzeRule::new`（不注入执行器，静默降级），
//!   默认构建仍走 stub 且编译通过。

use legado_parser::AnalyzeRule;
use legado_parser::AnalyzeUrl;
use std::collections::HashMap;

/// 构造规则解析器，并按构建特性决定是否注入 JS 执行器。
///
/// - 启用 `quickjs`：从全局引擎池按 `source_tag` 取执行器并注入，
///   使书源 `@js:` 规则真正被执行。
/// - 未启用：等价于 `AnalyzeRule::new`，`@js:` 规则降级返回空结果。
///
/// `source_tag` 一般传书源 URL（`book_source_url`），用于引擎池缓存分桶。
#[cfg(feature = "quickjs")]
pub fn construct_analyzer(content: String, base_url: String, source_tag: &str) -> AnalyzeRule {
    construct_analyzer_with_js_lib(content, base_url, source_tag, None)
}

/// 非 quickjs 构建下的降级实现：不注入执行器，保持原样。
#[cfg(not(feature = "quickjs"))]
pub fn construct_analyzer(content: String, base_url: String, _source_tag: &str) -> AnalyzeRule {
    AnalyzeRule::new(content, base_url)
}

/// 构造规则解析器并注入书源 jsLib（规则 `<js>`/`@js:` 模板执行前先加载库）
///
/// [UI-fix 2026-08-10 | Reasonix] yckceo 书源的 searchUrl/ruleContent 模板
/// 常引用 jsLib 定义（如 `<js>eval(String(Reload('...')))` 的 Reload、聚合源
/// 的 getHosts() 等），此前模板 JS 执行器不注入 jsLib → 这些书源搜索 URL
/// 构建失败 → 无结果。对齐原版：每次 JS 执行前先 eval 书源 jsLib。
#[cfg(feature = "quickjs")]
pub fn construct_analyzer_with_js_lib(
    content: String,
    base_url: String,
    source_tag: &str,
    js_lib: Option<&str>,
) -> AnalyzeRule {
    let executor = QuickJsExecutor::new(source_tag).with_js_lib(js_lib.map(|s| s.to_string()));
    AnalyzeRule::with_js_executor(content, base_url, std::sync::Arc::new(executor))
}

/// 非 quickjs 构建下的降级实现
#[cfg(not(feature = "quickjs"))]
pub fn construct_analyzer_with_js_lib(
    content: String,
    base_url: String,
    _source_tag: &str,
    _js_lib: Option<&str>,
) -> AnalyzeRule {
    AnalyzeRule::new(content, base_url)
}

/// 构造规则解析器：注入书源 jsLib + 书源上下文 setup（source/cookie 绑定）
///
/// 发现页书籍列表解析专用：聚合源（书山聚合等）的 ruleExplore.bookList
/// `<js>` 脚本无条件调用 jsLib 函数（getSessionId/getServerHost 等），
/// 且部分函数 `let { source, cookie } = this` 依赖书源上下文；此前
/// [`construct_analyzer`] 仅注入空 jsLib（无 setup），`getSessionId is
/// not defined` ReferenceError → 列表解析失败 →「暂无书籍」。
/// — DeepSeek Harness + Bridge（2026-08-14 发现页修复：书山空列表）
#[cfg(feature = "quickjs")]
pub fn construct_analyzer_with_source_context(
    content: String,
    base_url: String,
    source_tag: &str,
    js_lib: Option<&str>,
    setup_script: Option<String>,
) -> AnalyzeRule {
    let executor = QuickJsExecutor::new(source_tag)
        .with_js_lib(js_lib.map(|s| s.to_string()))
        .with_setup_script(setup_script);
    AnalyzeRule::with_js_executor(content, base_url, std::sync::Arc::new(executor))
}

/// 非 quickjs 构建下的降级实现
#[cfg(not(feature = "quickjs"))]
pub fn construct_analyzer_with_source_context(
    content: String,
    base_url: String,
    _source_tag: &str,
    _js_lib: Option<&str>,
    _setup_script: Option<String>,
) -> AnalyzeRule {
    AnalyzeRule::new(content, base_url)
}

/// 执行 loginCheckJs 登录检测脚本
///
/// 将 HTTP 响应上下文以 `result` 绑定注入 JS 环境，
/// loginCheckJs 检测结果分类（对齐 Kotlin WebBook 双路径语义：
/// 成功路径判定未登录 → errResponse 二次 eval；JS 环境不兼容 → 降级放行）
#[derive(Debug)]
pub enum LoginCheckError {
    /// 检测判定未登录（JS 返回 false/未登录/needLogin）
    NotLoggedIn(String),
    /// JS 执行失败（环境不兼容/脚本错误，非登录判定）
    JsFailed(String),
}

/// 使书源 loginCheckJs 脚本可访问 `result`（**对象**语义，含 body/url/code 字段；
/// 2026-08-10 修复：原实现 to_string 后注入导致 result 为字符串，`result.body()`
/// 等真实书源写法全部失败）。
///
/// 参考 Kotlin `AnalyzeUrl.evalJS(checkJs, response)` 的双路径模式：
/// - 成功路径：response 正常时执行 loginCheckJs
/// - 失败路径：response 异常时构造 errResponse 再执行（由调用方 web_book.rs 处理）
///
/// 返回 Ok(()) 表示检测通过；Err 区分「判定未登录」（NotLoggedIn）与
/// 「JS 环境不兼容」（JsFailed），由调用方决定上抛或降级。
#[cfg(feature = "quickjs")]
pub fn execute_login_check_js(
    js_code: &str,
    response_body: &str,
    response_url: &str,
    response_code: u16,
    source_tag: &str,
) -> Result<(), LoginCheckError> {
    use legado_parser::JsExecutor;

    let executor = quickjs_impl::QuickJsExecutor::new(source_tag);

    // 构造响应上下文并注入为 **带方法语义的 JS 对象**（对齐 Kotlin
    // StrResponse 语义：result.body()/url()/code() 为方法调用）：
    // var result = { body: function(){...}, url: function(){...}, code: function(){...} };
    // 2026-08-10 修复：原实现 to_string 注入导致 result 为 JSON 字符串，
    // 真实书源 loginCheckJs 中 result.body() 等写法全部失败
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckError::JsFailed(format!("响应体转义失败: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckError::JsFailed(format!("响应 URL 转义失败: {e}")))?;
    let wrapped_code = format!(
        "var __result_body = {body_lit};\n\
         var __result_url = {url_lit};\n\
         var __result_code = {response_code};\n\
         var result = {{ body: function() {{ return __result_body; }},\n\
         url: function() {{ return __result_url; }},\n\
         code: function() {{ return __result_code; }} }};\n\
         {js_code}"
    );
    let eval_result = executor
        .execute_js(&wrapped_code)
        .map_err(|e| LoginCheckError::JsFailed(format!("loginCheckJs 执行失败: {e}")))?;

    // 检测返回值：如果 JS 返回明确的错误指示，视为登录失败
    //（eval 返回值经 JSON 序列化，字符串字面量会带引号如 "false"，
    // 剥除引号后再判定——2026-08-10 修复）
    let trimmed = eval_result.trim().trim_matches('"').trim();
    if trimmed == "false" || trimmed.contains("未登录") || trimmed.contains("needLogin") {
        return Err(LoginCheckError::NotLoggedIn(format!(
            "loginCheckJs 检测未登录: {trimmed}"
        )));
    }

    Ok(())
}

/// 非 quickjs 构建下 loginCheckJs 降级：静默跳过检测
#[cfg(not(feature = "quickjs"))]
pub fn execute_login_check_js(
    _js_code: &str,
    _response_body: &str,
    _response_url: &str,
    _response_code: u16,
    _source_tag: &str,
) -> Result<(), LoginCheckError> {
    // 未启用 quickjs 时无法执行 JS，静默跳过
    Ok(())
}

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
/// （P3-6 A 分叉点1：取代 `execute_login_check_js` 的谓词字符串判定，
/// 搜索/详情等主链路改走本函数；explore 链本期保留旧函数）
///
/// - 注入与 [`execute_login_check_js`] 相同的方法形 `result` 绑定
///   （body()/url()/code() 方法），真实书源写法 `result.body()` 可用；
///   书源 `return result` 原样直通时，完成值为方法形对象，
///   `JSON.stringify` 丢弃函数属性 → 文本 `{}` → 解析回退原始响应三元组；
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

    let executor = quickjs_impl::QuickJsExecutor::new(source_tag);

    // 注入与 execute_login_check_js 相同的方法形 result 绑定
    // （对齐 Kotlin StrResponse 语义：result.body()/url()/code() 方法调用）
    let body_lit = serde_json::to_string(response_body)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("响应体转义失败: {e}")))?;
    let url_lit = serde_json::to_string(response_url)
        .map_err(|e| LoginCheckEvalError::JsFailed(format!("响应 URL 转义失败: {e}")))?;
    let wrapped_code = format!(
        "var __result_body = {body_lit};\n\
         var __result_url = {url_lit};\n\
         var __result_code = {response_code};\n\
         var result = {{ body: function() {{ return __result_body; }},\n\
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
/// （与 `execute_login_check_js` 的静默跳过一致，v7a 无 JS 降级决策不变）
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

/// 构建搜索 URL 的 AnalyzeUrl（接线 `{{JS表达式}}` 模板渲染）
///
/// 对齐原版 AnalyzeUrl.kt `replaceKeyPageJs` 语义：
/// - 模板含 `{{...}}` 时走 `AnalyzeUrl::parse_with_js`，注入 `key`/`page`
///   变量并用 JS 引擎求值，支持 `{{encodeURIComponent(key)}}`、
///   `{{page > 1 ? '/' + page : ''}}` 等标准 legado 模板；
/// - 未启用 quickjs 或解析失败时降级：`AnalyzeUrl::parse`（简单变量查找）
///   或回退旧版字面替换路径，纯 `{key}`/`{page}`/`searchKey` 模板行为不变（回归保护）。
///
/// `source_tag` 传书源 URL，用于引擎池分桶与 base URL 拼接。
pub fn build_search_url(template: &str, keyword: &str, page: i32, source_tag: &str) -> AnalyzeUrl {
    build_search_url_with_lib(template, keyword, page, source_tag, None)
}

/// 构建搜索 URL（携带书源 jsLib）
///
/// [UI-fix 2026-08-10 | Reasonix] 与 [`build_search_url`] 相同，但模板
/// `<js>`/`{{JS表达式}}` 执行前先加载书源 jsLib（yckceo 漫画/聚合源依赖）。
pub fn build_search_url_with_lib(
    template: &str,
    keyword: &str,
    page: i32,
    source_tag: &str,
    js_lib: Option<&str>,
) -> AnalyzeUrl {
    build_search_url_with_setup(template, keyword, page, source_tag, js_lib, None)
}

/// 构建搜索 URL（携带书源 jsLib + 书源上下文 setup）
///
/// 对齐原版 AnalyzeUrl.kt evalJS：搜索模板 `{{source.getKey()}}` 等依赖
/// source/cookie 绑定（爱下电子等源 searchUrl 用 `{{source.getKey()}}/search`）；
/// 仅注入 jsLib 无 setup → source 未定义 → URL 构建失败 → 搜索结果为空。
/// — 聚合/上下文书源搜索修复（2026-08-17）
pub fn build_search_url_with_setup(
    template: &str,
    keyword: &str,
    page: i32,
    source_tag: &str,
    js_lib: Option<&str>,
    setup_script: Option<String>,
) -> AnalyzeUrl {
    let page_u32 = page.max(1) as u32;
    // 含任一 JS 语法（{{表达式}} / <js> 内嵌 / @js: 前缀）都走 JS 求值路径：
    // [UI-fix 2026-08-10 | Reasonix] <js>/@js: 模板此前落入旧版字面路径，
    // 而 AnalyzeUrl::new 不执行内嵌 JS → yckceo 漫画源 searchUrl 构建失败
    if template.contains("{{") || template.contains("<js>") || template.contains("@js:") {
        // searchKey 字面替换（对齐旧版 init_url 行为）
        let pre = template.replace("searchKey", keyword);
        // 变量集对齐原版 AnalyzeUrl.kt evalJS 绑定：key/page/baseUrl
        // （searchKey 额外注入，使 `{{searchKey}}` 模板亦可渲染）
        let mut variables = HashMap::new();
        variables.insert("key".to_string(), keyword.to_string());
        variables.insert("page".to_string(), page.to_string());
        variables.insert("baseUrl".to_string(), source_tag.to_string());
        variables.insert("searchKey".to_string(), keyword.to_string());
        match search_url_with_js(&pre, &variables, page, source_tag, js_lib, setup_script) {
            Ok(analyzed) => return analyzed,
            Err(e) => {
                // @js:/<js> 主模板失败时禁止字面回退（否则会把脚本文本当 URL
                // → HTTP 404/403，云霄小说/键盘小说/玄幻文学等实测）。
                // 对齐 explore_url_with_js：JS 失败上抛语义；此处返回类型仍为
                // AnalyzeUrl，用明确错误占位 URL 让上层 fetch 失败可辨。
                let trimmed = template.trim_start();
                let js_primary = trimmed.starts_with("@js:")
                    || trimmed.starts_with("<js>")
                    || template.contains("<js>");
                if js_primary {
                    eprintln!(
                        "[build_search_url] @js/<js> 求值失败，拒绝字面回退: {}",
                        e.to_string().chars().take(200).collect::<String>()
                    );
                    return AnalyzeUrl::new(
                        &format!(
                            "legado-js-error://search?e={}",
                            urlencoding_lite(&e.to_string())
                        ),
                        Some(keyword),
                        Some(page_u32),
                        source_tag,
                        None,
                    );
                }
                eprintln!(
                    "[build_search_url] JS 模板求值失败，回退字面路径: {}",
                    e.to_string().chars().take(160).collect::<String>()
                );
            }
        }
    }
    // 旧版路径：字面占位符替换 + AnalyzeUrl::new
    let url_with_key = template
        .replace("{{key}}", keyword)
        .replace("{key}", keyword);
    AnalyzeUrl::new(
        &url_with_key,
        Some(keyword),
        Some(page_u32),
        source_tag,
        None,
    )
}

/// 极简 URL 编码（仅错误消息占位，避免引入额外依赖）
fn urlencoding_lite(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes().take(180) {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// [`urlencoding_lite`] 的逆操作：解码 `%XX` 百分号转义
fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hi = (bytes[i + 1] as char).to_digit(16);
            let lo = (bytes[i + 2] as char).to_digit(16);
            if let (Some(h), Some(l)) = (hi, lo) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 解码 `legado-js-error://search?e=<百分号编码>` 错误 URL，还原 JS 错误文本
///
/// [`build_search_url`] 等在 JS 求值失败时以该错误 URL 携带真实错误文本
/// （避免把 @js: 脚本文本拼进请求 URL）；搜索路径据此还原、标注为
/// `LegadoError::JsEngine` 上抛（error_class 仍为 `js_error`，契约不变）。
pub fn decode_js_error_url(url: &str) -> Option<String> {
    const PREFIX: &str = "legado-js-error://";
    let rest = url.strip_prefix(PREFIX)?;
    let query = rest.split_once('?').map(|(_, q)| q).unwrap_or("");
    let e_val = query.split('&').find_map(|kv| kv.strip_prefix("e="))?;
    Some(percent_decode(e_val))
}

/// 构建发现分类 URL（对标 Android WebBook.exploreBookAwait + infoMap）
///
/// 携带书源 infoMap、jsLib 与**书源上下文 setup**（source/cookie 方法），
/// 支持 `{{infoMap['key']}}` / `{{page}}` / jsLib 函数（getSessionId 等
/// 依赖 `this.source`/`this.cookie`）等模板 — 发现页修复（书山书籍 URL）
pub fn build_explore_url(
    template: &str,
    page: i32,
    source: &legado_core::models::BookSource,
    info_map: &HashMap<String, String>,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    let source_tag = source.book_source_url.clone();
    let js_lib = source.js_lib.as_deref();
    let page_u32 = page.max(1) as u32;
    let mut variables = HashMap::new();
    variables.insert("page".to_string(), page.to_string());
    variables.insert("baseUrl".to_string(), source_tag.clone());
    for (k, v) in info_map {
        variables.insert(k.clone(), v.clone());
        variables.insert(format!("infoMap.{k}"), v.clone());
    }
    let info_json = serde_json::to_string(info_map).unwrap_or_else(|_| "{}".to_string());
    variables.insert("__infoMapJson".to_string(), info_json);

    // 书源上下文 setup 脚本（source/cookie 绑定 + BookSource 方法）
    let setup_script = crate::api::source_js_bindings::book_source_js_setup_script(source).ok();

    if template.contains("{{") || template.contains("<js>") || template.contains("@js:") {
        // JS 求值失败**上抛真实错误**（对齐原版：懒人听书等需登录会话的
        // 书源未配置时 lrtsResolveSession 抛「请先登录…」应原样提示用户；
        // 此前静默回退字面量 URL 会把 @js: 脚本文本拼进请求 → HTTP 404
        // 误导（2026-08-14 用户反馈懒人听书发现页 http404））
        return explore_url_with_js(
            template,
            &variables,
            page,
            &source_tag,
            js_lib,
            setup_script,
        );
    }
    Ok(AnalyzeUrl::new(
        template,
        None,
        Some(page_u32),
        &source_tag,
        None,
    ))
}

/// quickjs 启用：发现 URL 模板 JS 求值（注入 infoMap 对象 + page/baseUrl
/// 全局变量 + 书源 setup）
#[cfg(feature = "quickjs")]
fn explore_url_with_js(
    template: &str,
    variables: &HashMap<String, String>,
    page: i32,
    source_tag: &str,
    js_lib: Option<&str>,
    setup_script: Option<String>,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    let info_json = variables
        .get("__infoMapJson")
        .cloned()
        .unwrap_or_else(|| "{}".to_string());
    let executor = ExploreInfoMapJsExecutor::new(
        source_tag,
        js_lib.map(|s| s.to_string()),
        info_json,
        setup_script,
        page,
        source_tag,
    );
    AnalyzeUrl::parse_with_js(template, variables, page, &executor)
}

#[cfg(not(feature = "quickjs"))]
fn explore_url_with_js(
    template: &str,
    variables: &HashMap<String, String>,
    page: i32,
    _source_tag: &str,
    _js_lib: Option<&str>,
    _setup_script: Option<String>,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    AnalyzeUrl::parse(template, variables, page)
}

/// 发现 URL JS 执行器：每次求值前注入 `var infoMap = {...}`、`var page = N`、
/// `var baseUrl = '...'` 与书源上下文 setup（source/cookie 方法，
/// URL 模板 jsLib 函数依赖）。page/baseUrl 对齐原版 evalJS 注入的
/// 全局变量——懒人听书等分类 URL 脚本 `Number(page||1)` 直接引用 page，
/// 缺失会报 `page is not defined`（2026-08-14 懒人听书发现页报错）。
#[cfg(feature = "quickjs")]
struct ExploreInfoMapJsExecutor {
    inner: QuickJsExecutor,
    info_map_json: String,
    page: i32,
    base_url: String,
}

#[cfg(feature = "quickjs")]
impl ExploreInfoMapJsExecutor {
    fn new(
        source_tag: &str,
        js_lib: Option<String>,
        info_map_json: String,
        setup_script: Option<String>,
        page: i32,
        base_url: &str,
    ) -> Self {
        Self {
            inner: QuickJsExecutor::new(source_tag)
                .with_js_lib(js_lib)
                .with_setup_script(setup_script),
            info_map_json,
            page,
            base_url: base_url.to_string(),
        }
    }
}

#[cfg(feature = "quickjs")]
impl legado_parser::JsExecutor for ExploreInfoMapJsExecutor {
    fn execute_js(&self, js_code: &str) -> Result<String, String> {
        let wrapped = format!(
            "var infoMap = {};\nvar page = {};\nvar baseUrl = {};\n{}",
            self.info_map_json,
            self.page,
            serde_json::to_string(&self.base_url).unwrap_or_else(|_| "\"\"".to_string()),
            js_code
        );
        self.inner.execute_js(&wrapped)
    }
}

/// quickjs 启用：用 QuickJS 引擎求值 `{{expression}}`
///
/// 注入书源上下文 setup（source/cookie 绑定）——搜索模板 `{{source.getKey()}}`
/// 等依赖（爱下电子等源）；对齐原版 AnalyzeUrl.kt evalJS 的 source 绑定。
#[cfg(feature = "quickjs")]
fn search_url_with_js(
    template: &str,
    variables: &HashMap<String, String>,
    page: i32,
    source_tag: &str,
    js_lib: Option<&str>,
    setup_script: Option<String>,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    let executor = QuickJsExecutor::new(source_tag)
        .with_js_lib(js_lib.map(|s| s.to_string()))
        .with_setup_script(setup_script);
    AnalyzeUrl::parse_with_js(template, variables, page, &executor)
}

/// 未启用 quickjs：降级为标准 parse（简单变量查找，复杂表达式保留原样）
#[cfg(not(feature = "quickjs"))]
fn search_url_with_js(
    template: &str,
    variables: &HashMap<String, String>,
    page: i32,
    _source_tag: &str,
    _js_lib: Option<&str>,
    _setup_script: Option<String>,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    AnalyzeUrl::parse(template, variables, page)
}

// ─── quickjs 启用时的适配器实现 ────────────────────────────────────────────────

#[cfg(feature = "quickjs")]
mod quickjs_impl {
    use legado_parser::JsExecutor;

    /// QuickJS 执行器适配器
    ///
    /// 持有所属 `source_tag` 与书源 jsLib；`execute_js` 时**每次创建
    /// 独立新引擎**执行（对齐原版 Rhino 每次 evalJS 新作用域，规避
    /// 书源规则顶层 const/let 声明在引擎复用下的 redeclaration）。
    /// 实现 `Send + Sync`，满足 `Arc<dyn JsExecutor>`。
    pub struct QuickJsExecutor {
        source_tag: String,
        /// 书源 jsLib（共享库代码，执行前先加载，对齐原版每次 eval 前注入）
        js_lib: Option<String>,
        /// 书源上下文 setup 脚本（source/cookie/__mountBookSourceApi 等，
        /// 供 URL 模板 {{js}} 里 jsLib 函数 `this.source`/`this.cookie`
        /// 访问）— 发现页修复（书山聚合书籍 URL session 缺失）
        setup_script: Option<String>,
    }

    impl QuickJsExecutor {
        /// 以指定 `source_tag` 创建执行器
        pub fn new(source_tag: &str) -> Self {
            Self {
                source_tag: source_tag.to_string(),
                js_lib: None,
                setup_script: None,
            }
        }

        /// 携带书源 jsLib 创建执行器
        ///
        /// [UI-fix 2026-08-10 | Reasonix] yckceo 书源（漫画/聚合源）模板
        /// 引用 jsLib 定义（Reload/getHosts 等），不注入则 URL 构建失败
        pub fn with_js_lib(mut self, js_lib: Option<String>) -> Self {
            self.js_lib = js_lib;
            self
        }

        /// 携带书源上下文 setup 脚本（source/cookie 绑定 + BookSource 方法）
        pub fn with_setup_script(mut self, setup_script: Option<String>) -> Self {
            self.setup_script = setup_script;
            self
        }
    }

    impl JsExecutor for QuickJsExecutor {
        fn execute_js(&self, js_code: &str) -> Result<String, String> {
            use std::collections::hash_map::DefaultHasher;
            use std::hash::{Hash, Hasher};
            use std::sync::{Mutex, OnceLock};
            static LEXICAL: OnceLock<Mutex<std::collections::HashSet<u64>>> = OnceLock::new();
            let hash = {
                let mut h = DefaultHasher::new();
                js_code.hash(&mut h);
                h.finish()
            };
            let lexical = LEXICAL.get_or_init(|| Mutex::new(std::collections::HashSet::new()));
            let is_lexical = lexical.lock().map(|s| s.contains(&hash)).unwrap_or(false);
            let run_fresh = || -> Result<String, String> {
                let engine = legado_js::QuickJsEngine::new(
                    legado_js::sandbox::SandboxConfig::default()
                        .with_allow_script_run(true)
                        .with_memory_limit(64 * 1024 * 1024),
                )
                .map_err(|e| format!("JS 引擎创建失败: {e}"))?;
                legado_js::host_api::current_source::with_current_source_tag(
                    &self.source_tag,
                    || {
                        if let Some(lib) = &self.js_lib {
                            if let Err(e) = legado_js::JsEngine::eval(&engine, lib) {
                                // 仅对语法错误尝试 Rhino 宽容语法归一化后重试一次（与 engine_cache
                                // 缓存路径一致；对齐原版 corejs-Rhino 宽松解析——B 站 jsLib 的
                                // let 参数影子重声明、data..item_null 双点笔误等）；运行时错误按原样降级。
                                if engine.check_syntax(lib).is_err() {
                                    let (normalized, changed) =
                                        legado_js::jslib_normalize::normalize(lib);
                                    if changed
                                        && legado_js::JsEngine::eval(&engine, &normalized).is_ok()
                                    {
                                        eprintln!(
                                            "[legado-ffi] 书源 {} jsLib 经 Rhino 宽容语法归一化后加载成功（原错误: {e}）",
                                            self.source_tag
                                        );
                                    } else {
                                        eprintln!(
                                            "[legado-ffi] 书源 {} jsLib 加载失败（降级继续）: {e}",
                                            self.source_tag
                                        );
                                        // 队列④：jsLib 加载失败登记能力受限台账
                                        // （键与缓存路径一致：executor:<source_tag>）
                                        legado_js::host_api::capability_ledger::record_jslib_load_failure(
                                            &format!("executor:{}", self.source_tag),
                                            &e.to_string(),
                                        );
                                    }
                                } else {
                                    eprintln!(
                                        "[legado-ffi] 书源 {} jsLib 加载失败（降级继续）: {e}",
                                        self.source_tag
                                    );
                                    legado_js::host_api::capability_ledger::record_jslib_load_failure(
                                        &format!("executor:{}", self.source_tag),
                                        &e.to_string(),
                                    );
                                }
                            }
                        }
                        if let Some(setup) = &self.setup_script {
                            if let Err(e) = legado_js::JsEngine::eval(&engine, setup) {
                                eprintln!(
                                    "[legado-ffi] 书源 {} setup 加载失败（降级继续）: {e}",
                                    self.source_tag
                                );
                            }
                        }
                        if let Err(e) = legado_js::JsEngine::eval(
                            &engine,
                            legado_js::host_api::quickjs_impl::RESPONSE_BRIDGE_JS,
                        ) {
                            eprintln!(
                                "[legado-ffi] 书源 {} Response 桥重新注入失败（降级继续）: {e}",
                                self.source_tag
                            );
                        }
                        if let Err(e) = legado_js::JsEngine::eval(
                            &engine,
                            legado_js::host_api::quickjs_impl::JSOUP_BRIDGE_JS,
                        ) {
                            eprintln!(
                                "[legado-ffi] 书源 {} Jsoup 桥重新注入失败（降级继续）: {e}",
                                self.source_tag
                            );
                        }
                        legado_js::JsEngine::eval(&engine, js_code).map_err(|e| e.to_string())
                    },
                )
            };
            if is_lexical {
                return run_fresh();
            }
            let key = format!("executor:{}", self.source_tag);
            let (cached, _, _) = legado_js::engine_cache::get_or_create(
                &key,
                self.js_lib.as_deref(),
                self.setup_script.as_deref(),
                None,
            )
            .map_err(|e| e.to_string())?;
            let result = legado_js::host_api::current_source::with_current_source_tag(
                &self.source_tag,
                || {
                    cached
                        .lock()
                        .map_err(|_| "JS 引擎锁中毒".to_string())
                        .and_then(|engine| {
                            legado_js::JsEngine::eval(&*engine, js_code).map_err(|e| e.to_string())
                        })
                },
            );
            match result {
                Err(e) if e.contains("redeclaration") || e.contains("already declared") => {
                    if let Ok(mut set) = lexical.lock() {
                        set.insert(hash);
                    }
                    run_fresh()
                }
                other => other,
            }
        }
    }
}

#[cfg(feature = "quickjs")]
pub use quickjs_impl::QuickJsExecutor;

/// 创建独立 QuickJS 引擎（F3-6：payAction/login/explore/callback 等非主路径
/// 每次新建，对齐 QuickJsExecutor 主路径策略，规避引擎池全局残留串扰）
#[cfg(feature = "quickjs")]
pub fn fresh_engine(
    _source_tag: &str,
) -> legado_core::LegadoResult<std::sync::Arc<std::sync::Mutex<legado_js::QuickJsEngine>>> {
    let engine = legado_js::QuickJsEngine::new(
        legado_js::sandbox::SandboxConfig::default()
            .with_allow_script_run(true)
            // 同上：大 jsLib/大 JSON 结果需 64MB（七猫目录 2026-08-15）
            .with_memory_limit(64 * 1024 * 1024),
    )?;
    Ok(std::sync::Arc::new(std::sync::Mutex::new(engine)))
}

/// 获取书源 JS 引擎（F3-6 起等同 [`fresh_engine`]，不再复用进程级引擎池）
#[cfg(feature = "quickjs")]
pub fn pool_engine(
    source_tag: &str,
) -> legado_core::LegadoResult<std::sync::Arc<std::sync::Mutex<legado_js::QuickJsEngine>>> {
    fresh_engine(source_tag)
}

/// 预校验书源 jsLib 可加载性（队列④：能力受限提示 + 未知类告警）
///
/// quickjs 启用：走与执行路径**同一**引擎缓存键 `executor:<source_tag>`，
/// jsLib 加载失败（`js_lib_ok == Some(false)`）时——此时台账已由
/// [`legado_js::engine_cache`] 登记——上抛 `LegadoError::JsEngine`，
/// 文案形如「书源 jsLib 加载失败（decode is not defined）：书源脚本
/// 能力不可用」，经批次错误通道在搜索结果中显示原因（error_class
/// 仍为 `js_error`，契约不变）。
///
/// 未启用 quickjs：no-op（非 quickjs 构建本就不执行 JS，静默降级）。
#[cfg(feature = "quickjs")]
pub fn validate_js_lib(
    source_tag: &str,
    js_lib: &str,
    setup_script: Option<&str>,
) -> legado_core::LegadoResult<()> {
    let key = format!("executor:{}", source_tag);
    let (_, _, js_lib_ok) =
        legado_js::engine_cache::get_or_create(&key, Some(js_lib), setup_script, None)
            .map_err(|e| legado_core::LegadoError::JsEngine(e.to_string()))?;
    if js_lib_ok == Some(false) {
        let last_err =
            legado_js::host_api::capability_ledger::last_jslib_error(&key).unwrap_or_default();
        return Err(legado_core::LegadoError::JsEngine(format!(
            "书源 jsLib 加载失败({})：书源脚本能力不可用",
            last_err.chars().take(120).collect::<String>()
        )));
    }
    Ok(())
}

/// 非 quickjs 构建下的降级实现：无 JS 能力可校验，直接通过
#[cfg(not(feature = "quickjs"))]
pub fn validate_js_lib(
    _source_tag: &str,
    _js_lib: &str,
    _setup_script: Option<&str>,
) -> legado_core::LegadoResult<()> {
    Ok(())
}

/// [体检 §二.5 | P3-6] AutoTask Custom JS 真实执行入口
///
/// 对齐原版 `AutoTaskRunner`（`AutoTask.buildSource(task)` → `source.evalJS(script)`）:
/// 经 QuickJS 引擎（带引擎缓存与 Response/Jsoup 基础桥）真实求值并返回
/// 完成值/错误,取代"验证脚本非空即视为成功"的静默假成功。
/// 绑定面:基础桥(无书源 java/cookie 绑定——原版 AutoTask.buildSource
/// 亦为合成源,重度绑定场景待书源上下文注入后扩展)。
#[cfg(feature = "quickjs")]
use legado_parser::JsExecutor;
#[cfg(feature = "quickjs")]
pub fn execute_auto_task_js(js_code: &str) -> Result<String, String> {
    quickjs_impl::QuickJsExecutor::new("auto_task").execute_js(js_code)
}

/// 非 quickjs 构建:引擎不可用,如实报错(不再静默假成功)
#[cfg(not(feature = "quickjs"))]
pub fn execute_auto_task_js(_js_code: &str) -> Result<String, String> {
    Err("Custom JS 执行需要 quickjs feature(当前构建未启用 JS 引擎)".to_string())
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 非 quickjs 构建：`@js:` 规则降级返回空（stub 行为）。
    /// quickjs 构建：注入执行器后 `@js:` 规则被真正执行。
    #[test]
    fn test_construct_analyzer_js_rule() {
        let analyzer = construct_analyzer(
            "<html><body>hello</body></html>".to_string(),
            "http://example.com".to_string(),
            "test_source_tag",
        );

        let result = analyzer.get_string("@js:1 + 2").unwrap_or_default();

        #[cfg(feature = "quickjs")]
        assert_eq!(result, "3", "quickjs 启用时 @js: 规则应被执行");

        #[cfg(not(feature = "quickjs"))]
        assert_eq!(result, "", "未启用 quickjs 时 @js: 规则应降级为空");
    }

    /// 队列④ P2-C：`legado-js-error://` 错误 URL 编解码往返（死码 guard 修复）
    ///
    /// `build_search_url_with_setup` 把 JS 错误文本百分号编码进错误占位 URL
    /// （`urlencoding_lite`），搜索路径经 `decode_js_error_url` 还原（现基于
    /// `AnalyzeUrl::rule_url()` 判断/解码，见 analyze_url 单测
    /// `test_js_error_url_prefix_survives_in_rule_url`）。边界覆盖：
    /// 非 ASCII（多字节 UTF-8）、缺 `e=`（返回 None）、裸 `%`（原样保留、
    /// 不 panic/不误解码）。
    #[test]
    fn test_js_error_url_roundtrip() {
        // 1) 非 ASCII + 中文往返
        let msg = "searchUrl JS 求值失败: decode is not defined（书源：云霄小说）";
        let url = format!("legado-js-error://search?e={}", urlencoding_lite(msg));
        assert_eq!(decode_js_error_url(&url).as_deref(), Some(msg));

        // 2) 错误文本里的 `&` 被编码，不截断 query
        let url = format!("legado-js-error://search?e={}", urlencoding_lite("a&b"));
        assert_eq!(decode_js_error_url(&url).as_deref(), Some("a&b"));

        // 3) 缺 `e=` → None（URL 无该前缀 / query 里无 e= 键亦 None）
        assert_eq!(decode_js_error_url("legado-js-error://search"), None);
        assert_eq!(decode_js_error_url("legado-js-error://search?x=1"), None);
        assert_eq!(decode_js_error_url("https://h.com/search"), None);
        // `e=` 存在但值空 → Some("")（与「缺 e=」可区分）
        assert_eq!(
            decode_js_error_url("legado-js-error://search?e="),
            Some("".to_string())
        );

        // 4) 裸 `%`（后随非 hex 字符/串尾）原样保留；合法 %XX 正常解码
        assert_eq!(percent_decode("100%"), "100%");
        assert_eq!(percent_decode("a%zz"), "a%zz");
        assert_eq!(
            decode_js_error_url("legado-js-error://search?e=100%").as_deref(),
            Some("100%")
        );
        assert_eq!(percent_decode("%E4%B8%AD"), "中");
    }

    /// quickjs 启用时，验证字符串拼接类 JS 规则同样生效。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_construct_analyzer_js_string_concat() {
        let analyzer = construct_analyzer(
            "{}".to_string(),
            "http://example.com".to_string(),
            "concat_source",
        );
        let result = analyzer
            .get_string("@js:'legado' + '-' + 'js'")
            .unwrap_or_default();
        assert_eq!(result, "legado-js");
    }

    /// quickjs 启用时，同一 executor 可连续执行多条脚本（每次仍为新引擎）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_quickjs_executor_reuse() {
        use legado_parser::JsExecutor;

        let executor = QuickJsExecutor::new("reuse_tag");
        let r1 = executor.execute_js("10 * 10").unwrap();
        let r2 = executor.execute_js("100 + 1").unwrap();
        assert_eq!(r1, "100");
        assert_eq!(r2, "101");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_lib_persists_across_independent_executes() {
        use legado_parser::JsExecutor;
        let _guard = legado_js::engine_cache::TEST_LOCK.lock().unwrap();
        legado_js::engine_cache::clear_for_tests();
        let lib = Some("function persisted(){ return 'ok'; }".to_string());
        let first = QuickJsExecutor::new("persist_tag").with_js_lib(lib.clone());
        let second = QuickJsExecutor::new("persist_tag").with_js_lib(lib);
        assert_eq!(first.execute_js("persisted()").unwrap(), "ok");
        assert_eq!(second.execute_js("persisted()").unwrap(), "ok");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_redeclaration_falls_back_to_fresh_engine() {
        use legado_parser::JsExecutor;
        let _guard = legado_js::engine_cache::TEST_LOCK.lock().unwrap();
        legado_js::engine_cache::clear_for_tests();
        let executor = QuickJsExecutor::new("redeclaration_tag");
        let script = "const regression_value = 41; regression_value + 1";
        assert_eq!(executor.execute_js(script).unwrap(), "42");
        assert_eq!(executor.execute_js(script).unwrap(), "42");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_completion_value_is_preserved_on_fast_path() {
        use legado_parser::JsExecutor;
        let _guard = legado_js::engine_cache::TEST_LOCK.lock().unwrap();
        legado_js::engine_cache::clear_for_tests();
        let executor = QuickJsExecutor::new("completion_tag");
        assert_eq!(executor.execute_js("1 + 2").unwrap(), "3");
        assert_eq!(executor.execute_js("var x = 7; result = x").unwrap(), "7");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_cache_per_source_isolation_and_capacity() {
        use legado_parser::JsExecutor;
        let _guard = legado_js::engine_cache::TEST_LOCK.lock().unwrap();
        legado_js::engine_cache::clear_for_tests();
        for i in 0..8 {
            let tag = format!("lru_tag_{i}");
            let lib = format!("function marker(){{ return {i}; }}");
            let executor = QuickJsExecutor::new(&tag).with_js_lib(Some(lib));
            assert_eq!(executor.execute_js("marker()").unwrap(), i.to_string());
        }
        let newest = QuickJsExecutor::new("lru_tag_7")
            .with_js_lib(Some("function marker(){ return 7; }".into()));
        assert_eq!(newest.execute_js("marker()").unwrap(), "7");
        let oldest = QuickJsExecutor::new("lru_tag_0")
            .with_js_lib(Some("function marker(){ return 0; }".into()));
        assert_eq!(oldest.execute_js("marker()").unwrap(), "0");
        // 缓存容量不变式：并行套件中其他测试（search/analyzer 的 @js: 执行）会
        // 不持 TEST_LOCK 合法写入同一进程级缓存，故只能断言上限而非精确计数；
        // 驱逐语义（LRU 最旧淘汰）由 legado-js engine_cache 单测锁定。
        assert!(legado_js::engine_cache::len_for_tests() <= legado_js::engine_cache::MAX_ENTRIES);
    }

    /// F3-6：fresh_engine 每次独立，全局变量不跨调用串扰
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_fresh_engine_no_global_leak() {
        use legado_js::JsEngine;

        let e1 = fresh_engine("tag_a").unwrap();
        e1.lock()
            .unwrap()
            .eval("globalThis.__f3_6_flag = 42")
            .unwrap();

        let e2 = fresh_engine("tag_a").unwrap();
        let ty = e2
            .lock()
            .unwrap()
            .eval("typeof globalThis.__f3_6_flag")
            .unwrap();
        assert_eq!(ty, "undefined");
    }

    /// {{JS表达式}} 搜索模板渲染（sto66 真实模板回归）：
    /// `encodeURIComponent(key)` 产出百分号编码关键词、`page>1?...'` 分页求值。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_search_url_js_template_render() {
        let template = "https://www.sto66.com/search/{{encodeURIComponent(key)}}{{page > 1 ? '/' + page : ''}}.html";
        let u1 = build_search_url(template, "重生高考前99天", 1, "sto66_test")
            .url()
            .to_string();
        assert!(!u1.contains("{{"), "模板应被完整渲染: {u1}");
        assert!(
            u1.contains("%E9%87%8D%E7%94%9F%E9%AB%98%E8%80%83%E5%89%8D99%E5%A4%A9"),
            "关键词应被 URI 编码: {u1}"
        );
        assert!(u1.ends_with(".html"), "page=1 分页应渲染为空串: {u1}");

        let u2 = build_search_url(template, "99", 2, "sto66_test")
            .url()
            .to_string();
        assert!(!u2.contains("{{"), "模板应被完整渲染: {u2}");
        assert!(u2.contains("/2.html"), "page=2 分页应渲染为 '/2': {u2}");
    }

    /// [UI-fix 2026-08-10 | Reasonix] 书源 jsLib 注入：模板 `<js>` 内嵌 JS 引用
    /// jsLib 定义的函数（yckceo 漫画源 `<js>eval(String(Reload('...')))` 模式）
    /// 应能正常渲染；未注入 jsLib 时降级（URL 不含库调用结果）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_search_url_with_js_lib() {
        let lib = "function Reload(url) { return url; }";
        let template = "<js>eval(String(Reload('https://api.example.com/search?q=test')))</js>";
        let u = build_search_url_with_lib(template, "都市", 1, "lib_source_test", Some(lib))
            .url()
            .to_string();
        assert!(
            u.contains("https://api.example.com/search?q=test"),
            "jsLib 注入后 Reload 应可调用: {u}"
        );
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_search_url_js_block_template() {
        // <js> 内嵌 JS 模板（不含 {{}}）也应走 JS 求值路径（此前被当字面路径）
        let template = "<js>var q = 'novel'; q + '-search'</js>";
        let u = build_search_url(template, "k", 1, "jsblock_test")
            .url()
            .to_string();
        assert!(u.contains("novel-search"), "<js> 模板应被 JS 求值渲染: {u}");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_construct_analyzer_with_js_lib() {
        // 规则模板引用 jsLib 函数（聚合源 getHosts 模式）
        let lib = "function getHosts() { return 'https://api.host.example'; }";
        let analyzer = construct_analyzer_with_js_lib(
            "{}".to_string(),
            "http://example.com".to_string(),
            "lib_analyzer_test",
            Some(lib),
        );
        let result = analyzer.get_string("@js:getHosts()").unwrap_or_default();
        assert_eq!(result, "https://api.host.example");
    }

    /// 纯字面模板回归：`{key}`/`{{key}}`/`searchKey` 行为不变。
    #[test]
    fn test_build_search_url_literal_regression() {
        let u1 = build_search_url(
            "https://example.com/search?q={key}",
            "斗破苍穹",
            1,
            "lit_test",
        )
        .url()
        .to_string();
        assert!(u1.contains("斗破苍穹") || u1.contains("%E6%96%97"), "{u1}");

        let u2 = build_search_url(
            "https://example.com/search?q=searchKey",
            "rust",
            1,
            "lit_test",
        )
        .url()
        .to_string();
        assert!(u2.contains("rust"), "{u2}");

        let u3 = build_search_url(
            "https://example.com/search?q={{key}}",
            "三体",
            1,
            "lit_test",
        )
        .url()
        .to_string();
        assert!(u3.contains("三体") || u3.contains("%E4%B8%89"), "{u3}");

        // `{{baseUrl}}` 简单变量直接查找（对齐原版 evalJS baseUrl 绑定）
        let u4 = build_search_url(
            "https://example.com/r?u={{baseUrl}}",
            "k",
            1,
            "https://src.example",
        )
        .url()
        .to_string();
        assert!(
            u4.contains("https%3A%2F%2Fsrc.example") || u4.contains("https://src.example"),
            "{u4}"
        );
    }

    // [UI-fix v2.0.8 | 2026-08-10] loginCheckJs 对象语义与判定分类 — Reasonix
    //（quickjs 为非默认 feature：仅在本 feature 启用时运行，
    // 生产构建 build-android.ps1 已显式 --features quickjs）
    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_js_result_object_semantics() {
        // 对象注入验证：真实书源写法 result.body() 方法可调用且返回响应体
        let js = "if (result.body().indexOf('需要登录') >= 0) { 'false' } else { 'ok' }";
        let r = execute_login_check_js(js, "需要登录页面", "http://x", 200, "lit_test");
        assert!(
            matches!(r, Err(LoginCheckError::NotLoggedIn(_))),
            "应判定未登录，实际: {r:?}"
        );
        let r2 = execute_login_check_js(js, "正常内容", "http://x", 200, "lit_test");
        assert!(r2.is_ok(), "应通过检测，实际: {r2:?}");

        // url()/code() 方法同样可调用
        let js2 = "if (result.url().indexOf('login') >= 0 || result.code() === 200) { 'false' } else { 'ok' }";
        let r3 = execute_login_check_js(js2, "b", "http://login.example", 200, "lit_test");
        assert!(
            matches!(r3, Err(LoginCheckError::NotLoggedIn(_))),
            "实际: {r3:?}"
        );
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_js_plain_false_and_error_classify() {
        // 纯 'false' 返回值判定未登录
        let r = execute_login_check_js("'false'", "body", "http://x", 200, "lit_test");
        assert!(
            matches!(r, Err(LoginCheckError::NotLoggedIn(_))),
            "实际: {r:?}"
        );
        // 正常返回值通过
        let r2 = execute_login_check_js("'true'", "body", "http://x", 200, "lit_test");
        assert!(r2.is_ok(), "实际: {r2:?}");
        // 语法错误归类为 JsFailed（环境/脚本问题，非登录判定）
        let r3 = execute_login_check_js("function {{", "body", "http://x", 200, "lit_test");
        assert!(
            matches!(r3, Err(LoginCheckError::JsFailed(_))),
            "实际: {r3:?}"
        );
    }

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
        // 不带显式 return（脚本无完成值 → undefined → 文本 "undefined"）
        // 对齐原版 cast 失败 → CastFailed
        let r2 =
            execute_login_check_response("var x = 1;", "orig-body", "http://x/s", 200, "lit_test");
        assert!(
            matches!(r2, Err(LoginCheckEvalError::CastFailed(_))),
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

    #[test]
    fn test_relative_search_url_absolutized() {
        let u = build_search_url(
            "/api/search?type=mh&page={{page}}&pageSize=20&keyword={{key}}",
            "一人之下",
            1,
            "https://www.manwa.me",
        );
        assert!(
            u.url().starts_with("https://www.manwa.me/api/search?"),
            "url={}",
            u.url()
        );
        println!("absolutized={}", u.url());
    }

    #[test]
    fn test_relative_search_url_with_java_encode_uri() {
        let u = build_search_url(
            "statics/search.aspx?key={{java.encodeURI(key)}}&page={{page}}",
            "一人之下",
            1,
            "https://www.copymanga.site",
        );
        assert!(
            u.url().starts_with("https://www.copymanga.site/"),
            "url={}",
            u.url()
        );
        println!("encodeURI url={}", u.url());
    }

    /// 懒人听书场景回归（2026-08-14 用户反馈发现页 http404）：
    /// 分类 URL 为 `@js:` 脚本且 jsLib 抛错（未配置登录会话时
    /// lrtsResolveSession 抛「本书源不含内置账号，请先登录…」），
    /// build_explore_url 应**上抛真实 JS 错误**，而非静默回退字面量 URL
    /// （回退会把 @js: 脚本文本拼进请求 → https://host/@js:... → HTTP 404 误导）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_explore_url_js_error_propagates_not_fallback() {
        use std::collections::HashMap;
        let source_json = r#"{
            "bookSourceUrl": "https://m.lrts.me",
            "bookSourceName": "懒人听书",
            "jsLib": "function lrtsUrl(){ throw new Error('本书源不含内置账号，请先在书源登录中填写会话参数'); }",
            "exploreUrl": "[{title:'推荐',url:'@js:\\nvar out=lrtsUrl();out;'}]"
        }"#;
        let source: legado_core::models::BookSource = serde_json::from_str(source_json).unwrap();
        let info_map = HashMap::new();
        let result = build_explore_url("@js:\nvar out=lrtsUrl();out;", 1, &source, &info_map);
        let err = match result {
            Err(e) => e.to_string(),
            Ok(_) => panic!("JS 抛错应返回 Err 而非回退字面量 URL"),
        };
        assert!(
            err.contains("书源登录") || err.contains("请先"),
            "错误应包含 JS 抛出的真实信息（引导用户登录）: {err}"
        );
    }

    /// 懒人听书分类 URL 脚本 `Number(page||1)` 直接引用 `page` 全局变量：
    /// build_explore_url 执行 JS 前应注入 `var page = N`（对齐原版 evalJS
    /// put("page")），否则报 `page is not defined`（2026-08-14 实测）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_explore_url_js_page_variable_injected() {
        use std::collections::HashMap;
        let source_json = r#"{
            "bookSourceUrl": "https://m.lrts.me",
            "bookSourceName": "懒人听书",
            "jsLib": "function lrtsUrl(java,source,path,params){ return 'https://m.lrts.me'+path+'?p='+(page||1); }",
            "exploreUrl": "[]"
        }"#;
        let source: legado_core::models::BookSource = serde_json::from_str(source_json).unwrap();
        let result = build_explore_url(
            "@js:lrtsUrl(java,source,'/api',{})",
            2,
            &source,
            &HashMap::new(),
        );
        assert!(result.is_ok(), "page 变量注入后 JS 应成功执行");
        let url = result.unwrap().url().to_string();
        assert!(url.contains("p=2"), "page=2 应注入 JS 全局: {url}");
    }

    /// 队列④ favcomic 口径：`validate_js_lib`（quickjs 档）复用引擎缓存
    /// （key `executor:<source_tag>`），jsLib 求值失败时返回带可读文案的
    /// `LegadoError::JsEngine`（「书源 jsLib 加载失败(...)：书源脚本能力
    /// 不可用」），失败由 [`legado_js::engine_cache`] 登记能力台账
    /// （`record_jslib_load_failure`）；搜索批次通道将其归类 `js_error`，
    /// 搜索结果的 error 字段可见失败原因（队列④ P1-B 横幅呈现）。
    ///
    /// 四段验证（P2-E 哨兵语义落地后重校——哨兵使「读取未知类」不再抛错，
    /// 提示移到真正使用点，原「fixture 必失败」前提失效，逐段重钉；
    /// 队列末项 java.io 最小 shim 落地后再次重校 ③④——`java.io.
    /// InputStream` 由「未覆盖示例」变为已覆盖面，未知类示例改钉
    /// `java.io.PrintStream`）：
    /// ① favcomic 真实 fixture 回归：jsLib 为 16KB 混淆**纯 JS** polyfill
    ///    IIFE（`Function.prototype.bind` 等 polyfill，无 `Packages`/`decode`
    ///    等 Java 面引用）→ 必须校验通过——防 P2-E 哨兵对合法纯 JS jsLib
    ///    误伤（回归护栏）；
    /// ② 未定义全局引用失败：jsLib 调用不存在的运行时全局 → 加载失败，
    ///    JsEngine 文案 + jsLib 失败台账登记归因（台账 key
    ///    `executor:<source_tag>`，与缓存路径一致）；
    /// ③ java.io.InputStream 最小 shim 回归（队列末项新覆盖）：
    ///    `new Packages.java.io.InputStream(bytes)` + `read`/`close`
    ///    校验通过且未知符号台账不登记 `java.io.InputStream` 前缀键
    ///    （前缀匹配，审查修：实例/类级未覆盖成员登记键形如
    ///    `java.io.InputStream.<成员>`，精确等值会漏掉后缀键；已覆盖类
    ///    不得被哨兵误伤）；
    /// ④ 未知 Java 类调用告警：jsLib `new Packages.java.io.PrintStream()`
    ///    （916 语料 0 命中，依赖真实 JVM 文件 I/O，能力清单显式不实现）
    ///    → P2-E 哨兵 construct 陷阱抛「此书源需要 Java 脚本能力
    ///    （Packages.java.io.PrintStream），当前不支持」，经
    ///    validate_js_lib 文案上抛，未知符号 `java.io.PrintStream`
    ///    登记未知 Java 符号台账（「未知类调用要告警」经 jsLib 通道
    ///    端到端验证）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_validate_js_lib_favcomic_jslib_failure_surfaces_and_records() {
        use legado_js::host_api::capability_ledger;

        let _engine_guard = legado_js::engine_cache::TEST_LOCK.lock().unwrap();
        let _ledger_guard = capability_ledger::LEDGER_TEST_LOCK.lock().unwrap();
        legado_js::engine_cache::clear_for_tests();
        capability_ledger::reset_jslib_load_failures();
        capability_ledger::reset_unknown_java_symbols();

        // ① favcomic 真实书源 fixture：jsLib 为纯 JS 混淆 polyfill IIFE（无 Java 面）
        let fixture = std::fs::read_to_string("tests/fixtures/comic_source.json").unwrap();
        let sources: Vec<serde_json::Value> =
            serde_json::from_str(&fixture).expect("书源 JSON 数组解析失败");
        let source_json = sources[0].to_string();
        let source: legado_core::models::BookSource =
            serde_json::from_str(&source_json).expect("书源反序列化失败");
        let js_lib = source.js_lib.clone().expect("favcomic fixture 应带 jsLib");
        assert!(!js_lib.trim().is_empty());
        assert!(
            !js_lib.contains("Packages") && !js_lib.contains("Java."),
            "fixture 口径回归：favcomic jsLib 应无 Java 面引用（若变化需重校本测试口径）"
        );
        // P2-E 回归：纯 JS jsLib 不受未知类哨兵影响，校验通过且无失败登记
        assert!(
            validate_js_lib("favcomic.test", &js_lib, None).is_ok(),
            "纯 JS jsLib（无 Java 面）应校验通过（P2-E 哨兵不得误伤）"
        );
        assert_eq!(
            capability_ledger::last_jslib_error("executor:favcomic.test"),
            None,
            "成功路径不应登记失败"
        );

        // ② 未定义全局引用失败（确定性探针全局，不依赖引擎未定义某具体名称）
        let err = validate_js_lib(
            "favcomic-fail.test",
            "var x = __q4_probe_missing__();",
            None,
        )
        .unwrap_err();
        assert!(
            matches!(err, legado_core::LegadoError::JsEngine(_)),
            "jsLib 失败应归为 JsEngine（批次通道 js_error）: {err}"
        );
        let msg = err.to_string();
        assert!(
            msg.contains("书源 jsLib 加载失败") && msg.contains("书源脚本能力不可用"),
            "文案应明确告知能力不可用: {msg}"
        );
        let last_err = capability_ledger::last_jslib_error("executor:favcomic-fail.test")
            .expect("jsLib 失败应登记台账（key executor:<source_tag>）");
        assert!(
            last_err.contains("__q4_probe_missing__"),
            "台账应记录失败归因（未定义全局引用）: {last_err}"
        );
        assert!(
            capability_ledger::jslib_load_failures()
                .iter()
                .any(|(tag, _, _)| tag == "executor:favcomic-fail.test"),
            "台账快照应含本来源"
        );

        // ③ java.io.InputStream 最小 shim 回归（队列末项新覆盖）：
        //    构造 + 读 + close 校验通过，且不得登记未知符号台账
        assert!(
            validate_js_lib(
                "favcomic-is.test",
                "var s = new Packages.java.io.InputStream(new Uint8Array([1, 2, 3])); \
                 s.read(); s.read(new Uint8Array(2), 0, 2); s.close();",
                None,
            )
            .is_ok(),
            "已覆盖类 java.io.InputStream 应校验通过（队列末项最小 shim 回归）"
        );
        assert!(
            capability_ledger::unknown_java_symbols()
                .iter()
                .all(|(k, _)| !k.starts_with("java.io.InputStream")),
            "已覆盖类 java.io.InputStream 面不应登记未知符号台账（前缀匹配）: {:?}",
            capability_ledger::unknown_java_symbols()
        );

        // ④ 未知 Java 类调用（P2-E 哨兵）：告警文案 + 未知符号台账登记
        //    （java.io.PrintStream：916 语料 0 命中 + 依赖真实 JVM 文件 I/O，
        //    能力清单显式不实现——未知类示例自 InputStream 改钉至此）
        let err = validate_js_lib(
            "favcomic-unknown.test",
            "new Packages.java.io.PrintStream();",
            None,
        )
        .unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("Java 脚本能力（Packages.java.io.PrintStream）"),
            "未知类告警文案应经 jsLib 通道上抛: {msg}"
        );
        // 未知符号台账（contains 断言噪声免疫：同进程并行测试可能并发登记其他未知符号）
        assert!(
            capability_ledger::unknown_java_symbols()
                .iter()
                .any(|(k, _)| k == "java.io.PrintStream"),
            "未知类 java.io.PrintStream 应登记未知符号台账: {:?}",
            capability_ledger::unknown_java_symbols()
        );

        capability_ledger::reset_jslib_load_failures();
    }
}

#[cfg(test)]
#[cfg(feature = "quickjs")]
mod auto_task_js_tests {
    use super::*;

    /// 真实执行:完成值返回
    #[test]
    fn test_auto_task_js_evaluates() {
        let r = execute_auto_task_js("1 + 1").unwrap();
        assert!(r.contains('2'), "1+1 应返回 2,实际: {r}");
    }

    /// 真实执行:脚本错误如实上抛(不再假成功)
    #[test]
    fn test_auto_task_js_error_propagates() {
        assert!(execute_auto_task_js("throw new Error('boom')").is_err());
    }

    /// 真实执行:非空字符串返回
    #[test]
    fn test_auto_task_js_string_result() {
        let r = execute_auto_task_js("'result-ok'").unwrap();
        assert!(r.contains("result-ok"));
    }
}
