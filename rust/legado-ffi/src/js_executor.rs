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
    let eval_result = executor.execute_js(&wrapped_code).map_err(|e| {
        LoginCheckError::JsFailed(format!("loginCheckJs 执行失败: {e}"))
    })?;

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
pub fn build_search_url(
    template: &str,
    keyword: &str,
    page: i32,
    source_tag: &str,
) -> AnalyzeUrl {
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
        if let Ok(analyzed) =
            search_url_with_js(&pre, &variables, page, source_tag, js_lib, setup_script)
        {
            return analyzed;
        }
    }
    // 旧版路径：字面占位符替换 + AnalyzeUrl::new
    let url_with_key = template.replace("{{key}}", keyword).replace("{key}", keyword);
    AnalyzeUrl::new(&url_with_key, Some(keyword), Some(page_u32), source_tag, None)
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
    let info_json =
        serde_json::to_string(info_map).unwrap_or_else(|_| "{}".to_string());
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
    Ok(AnalyzeUrl::new(template, None, Some(page_u32), &source_tag, None))
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
            serde_json::to_string(&self.base_url)
                .unwrap_or_else(|_| "\"\"".to_string()),
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
            // 每次执行用**独立新引擎**（而非池复用）：书源规则常用顶层
            // `const/let` 声明（51漫画 `const scripts`），同一引擎第二次
            // 执行同一规则必报 "redeclaration of 'scripts'"（QuickJS 全局
            // 词法环境残留，实测 SECOND ERR）。原版 Rhino 每次 evalJS 用
            // 新作用域，重构版对齐：用完即弃，规避跨调用全局污染。
            // 代价：jsLib 每次重载（一般较小，可接受）— Reasonix
            let engine = legado_js::QuickJsEngine::new(
                legado_js::sandbox::SandboxConfig::default().with_allow_script_run(true),
            )
            .map_err(|e| format!("JS 引擎创建失败: {e}"))?;
            // 绑定当前书源上下文（供 getVerificationCode 等宿主钩子识别书源，
            // 对齐 Kotlin JsExtensions.getSource()），eval 结束后恢复
            legado_js::host_api::current_source::with_current_source_tag(
                &self.source_tag,
                || {
                    // 执行前先加载书源 jsLib（对齐原版 JsSource 每次调用前
                    // eval jsLib；jsLib 通常为纯函数定义，重复 eval 幂等）。
                    // jsLib 求值失败**降级为警告而非阻断**：部分书源（如
                    // favcomic 混淆 jsLib）依赖 Android Rhino 特有全局
                    //（Packages Java 桥等），QuickJS 无法完整执行；正文
                    // 规则多为不依赖 jsLib 的纯正则/CSS，阻断会致正文全空
                    //（2026-08-11 实测回归）。失败仅记日志，后续 JS 规则
                    // 引用缺失函数时自然报 ReferenceError 可排错 — Reasonix
                    if let Some(lib) = &self.js_lib {
                        if let Err(e) = legado_js::JsEngine::eval(&engine, lib) {
                            eprintln!("[legado-ffi] 书源 {} jsLib 加载失败（降级继续）: {e}", self.source_tag);
                        }
                    }
                    // 书源上下文 setup（source/cookie 绑定；URL 模板 jsLib
                    // 函数 this.source/this.cookie 依赖）— 发现页修复
                    if let Some(setup) = &self.setup_script {
                        if let Err(e) = legado_js::JsEngine::eval(&engine, setup) {
                            eprintln!("[legado-ffi] 书源 {} setup 加载失败（降级继续）: {e}", self.source_tag);
                        }
                    }
                    // JsEngine::eval 返回 LegadoResult<String>，统一转为 Result<String, String>
                    legado_js::JsEngine::eval(&engine, js_code).map_err(|e| e.to_string())
                },
            )
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
        legado_js::sandbox::SandboxConfig::default().with_allow_script_run(true),
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
        let u1 = build_search_url(template, "重生高考前99天", 1, "sto66_test").url().to_string();
        assert!(!u1.contains("{{"), "模板应被完整渲染: {u1}");
        assert!(
            u1.contains("%E9%87%8D%E7%94%9F%E9%AB%98%E8%80%83%E5%89%8D99%E5%A4%A9"),
            "关键词应被 URI 编码: {u1}"
        );
        assert!(u1.ends_with(".html"), "page=1 分页应渲染为空串: {u1}");

        let u2 = build_search_url(template, "99", 2, "sto66_test").url().to_string();
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
        let template =
            "<js>eval(String(Reload('https://api.example.com/search?q=test')))</js>";
        let u = build_search_url_with_lib(
            template,
            "都市",
            1,
            "lib_source_test",
            Some(lib),
        )
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
        let u = build_search_url(template, "k", 1, "jsblock_test").url().to_string();
        assert!(
            u.contains("novel-search"),
            "<js> 模板应被 JS 求值渲染: {u}"
        );
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
        let result = analyzer
            .get_string("@js:getHosts()")
            .unwrap_or_default();
        assert_eq!(result, "https://api.host.example");
    }

    /// 纯字面模板回归：`{key}`/`{{key}}`/`searchKey` 行为不变。
    #[test]
    fn test_build_search_url_literal_regression() {
        let u1 = build_search_url("https://example.com/search?q={key}", "斗破苍穹", 1, "lit_test")
            .url()
            .to_string();
        assert!(u1.contains("斗破苍穹") || u1.contains("%E6%96%97"), "{u1}");

        let u2 = build_search_url("https://example.com/search?q=searchKey", "rust", 1, "lit_test")
            .url()
            .to_string();
        assert!(u2.contains("rust"), "{u2}");

        let u3 = build_search_url("https://example.com/search?q={{key}}", "三体", 1, "lit_test")
            .url()
            .to_string();
        assert!(u3.contains("三体") || u3.contains("%E4%B8%89"), "{u3}");

        // `{{baseUrl}}` 简单变量直接查找（对齐原版 evalJS baseUrl 绑定）
        let u4 = build_search_url("https://example.com/r?u={{baseUrl}}", "k", 1, "https://src.example")
            .url()
            .to_string();
        assert!(u4.contains("https%3A%2F%2Fsrc.example") || u4.contains("https://src.example"), "{u4}");
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
        assert!(matches!(r3, Err(LoginCheckError::NotLoggedIn(_))), "实际: {r3:?}");
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn login_check_js_plain_false_and_error_classify() {
        // 纯 'false' 返回值判定未登录
        let r = execute_login_check_js("'false'", "body", "http://x", 200, "lit_test");
        assert!(matches!(r, Err(LoginCheckError::NotLoggedIn(_))), "实际: {r:?}");
        // 正常返回值通过
        let r2 = execute_login_check_js("'true'", "body", "http://x", 200, "lit_test");
        assert!(r2.is_ok(), "实际: {r2:?}");
        // 语法错误归类为 JsFailed（环境/脚本问题，非登录判定）
        let r3 = execute_login_check_js("function {{", "body", "http://x", 200, "lit_test");
        assert!(matches!(r3, Err(LoginCheckError::JsFailed(_))), "实际: {r3:?}");
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
        let source: legado_core::models::BookSource =
            serde_json::from_str(source_json).unwrap();
        let info_map = HashMap::new();
        let result = build_explore_url(
            "@js:\nvar out=lrtsUrl();out;",
            1,
            &source,
            &info_map,
        );
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
        let source: legado_core::models::BookSource =
            serde_json::from_str(source_json).unwrap();
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

}
