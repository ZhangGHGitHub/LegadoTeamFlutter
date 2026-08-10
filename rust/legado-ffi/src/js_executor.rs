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
    let executor = QuickJsExecutor::new(source_tag);
    AnalyzeRule::with_js_executor(content, base_url, std::sync::Arc::new(executor))
}

/// 非 quickjs 构建下的降级实现：不注入执行器，保持原样。
#[cfg(not(feature = "quickjs"))]
pub fn construct_analyzer(content: String, base_url: String, _source_tag: &str) -> AnalyzeRule {
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
    let page_u32 = page.max(1) as u32;
    if template.contains("{{") && template.contains("}}") {
        // searchKey 字面替换（对齐旧版 init_url 行为）
        let pre = template.replace("searchKey", keyword);
        // 变量集对齐原版 AnalyzeUrl.kt evalJS 绑定：key/page/baseUrl
        // （searchKey 额外注入，使 `{{searchKey}}` 模板亦可渲染）
        let mut variables = HashMap::new();
        variables.insert("key".to_string(), keyword.to_string());
        variables.insert("page".to_string(), page.to_string());
        variables.insert("baseUrl".to_string(), source_tag.to_string());
        variables.insert("searchKey".to_string(), keyword.to_string());
        if let Ok(analyzed) = search_url_with_js(&pre, &variables, page, source_tag) {
            return analyzed;
        }
    }
    // 旧版路径：字面占位符替换 + AnalyzeUrl::new
    let url_with_key = template.replace("{{key}}", keyword).replace("{key}", keyword);
    AnalyzeUrl::new(&url_with_key, Some(keyword), Some(page_u32), source_tag, None)
}

/// quickjs 启用：用 QuickJS 引擎求值 `{{expression}}`
#[cfg(feature = "quickjs")]
fn search_url_with_js(
    template: &str,
    variables: &HashMap<String, String>,
    page: i32,
    source_tag: &str,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    let executor = QuickJsExecutor::new(source_tag);
    AnalyzeUrl::parse_with_js(template, variables, page, &executor)
}

/// 未启用 quickjs：降级为标准 parse（简单变量查找，复杂表达式保留原样）
#[cfg(not(feature = "quickjs"))]
fn search_url_with_js(
    template: &str,
    variables: &HashMap<String, String>,
    page: i32,
    _source_tag: &str,
) -> legado_core::LegadoResult<AnalyzeUrl> {
    AnalyzeUrl::parse(template, variables, page)
}

// ─── quickjs 启用时的适配器实现 ────────────────────────────────────────────────

#[cfg(feature = "quickjs")]
mod quickjs_impl {
    use std::sync::{Arc, Mutex, OnceLock};

    use legado_js::EnginePool;
    use legado_parser::JsExecutor;

    /// 全局引擎池容量（按书源 URL 缓存的上限）
    const POOL_MAX_SIZE: usize = 32;

    /// 进程级共享引擎池
    ///
    /// 使用 `OnceLock` 惰性初始化，保证多线程下仅创建一次；
    /// `EnginePool` 内部以 `Arc<Mutex<...>>` 保护，自身可安全共享。
    pub(super) fn global_pool() -> &'static EnginePool {
        static POOL: OnceLock<EnginePool> = OnceLock::new();
        POOL.get_or_init(|| EnginePool::new(POOL_MAX_SIZE))
    }

    /// QuickJS 执行器适配器
    ///
    /// 持有共享引擎池引用与所属 `source_tag`；`execute_js` 时按 tag 取
    /// （或创建）引擎并加锁执行。实现 `Send + Sync`，满足 `Arc<dyn JsExecutor>`。
    pub struct QuickJsExecutor {
        pool: &'static EnginePool,
        source_tag: String,
    }

    impl QuickJsExecutor {
        /// 以指定 `source_tag` 创建执行器（复用全局引擎池）
        pub fn new(source_tag: &str) -> Self {
            Self {
                pool: global_pool(),
                source_tag: source_tag.to_string(),
            }
        }
    }

    impl JsExecutor for QuickJsExecutor {
        fn execute_js(&self, js_code: &str) -> Result<String, String> {
            let engine: Arc<Mutex<legado_js::QuickJsEngine>> = self
                .pool
                .get_or_create(&self.source_tag)
                .map_err(|e| format!("JS 引擎获取/创建失败: {e}"))?;
            let guard = engine.lock().map_err(|e| format!("JS 引擎加锁失败: {e}"))?;
            // 绑定当前书源上下文（供 getVerificationCode 等宿主钩子识别书源，
            // 对齐 Kotlin JsExtensions.getSource()），eval 结束后恢复
            legado_js::host_api::current_source::with_current_source_tag(
                &self.source_tag,
                || {
                    // JsEngine::eval 返回 LegadoResult<String>，统一转为 Result<String, String>
                    legado_js::JsEngine::eval(&*guard, js_code).map_err(|e| e.to_string())
                },
            )
        }
    }
}

#[cfg(feature = "quickjs")]
pub use quickjs_impl::QuickJsExecutor;

/// 按 `source_tag` 从全局引擎池获取（或创建）QuickJS 引擎
///
/// 供需要直接操作引擎（如带绑定 eval）的模块复用，
/// 与 [`QuickJsExecutor`] 共享同一进程级引擎池。
#[cfg(feature = "quickjs")]
pub fn pool_engine(
    source_tag: &str,
) -> legado_core::LegadoResult<std::sync::Arc<std::sync::Mutex<legado_js::QuickJsEngine>>> {
    quickjs_impl::global_pool().get_or_create(source_tag)
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

    /// quickjs 启用时，同一 source_tag 复用引擎池（执行结果一致且不为空）。
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
}
