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

// ─── P5 子批 2a：分析器构造 / 搜索 URL / 错误 URL 适配下沉 legado-fetcher ───────
//
// 分析器构造（jsLib/setup 注入）、目录分页共享上下文、搜索 URL 构建与
// `legado-js-error://` 错误 URL 编解码已随迁 `legado_fetcher::js_adapter`
// （共享 crate 全栈单一实现）；本模块保留同名 re-export，调用方路径与签名
// 零改动（ffi 内 search/explore_api/source_login_v1_api/image_api 等与本模块
// 测试、tests/ 集成测试均不受影响）。
pub use legado_fetcher::js_adapter::{
    build_search_url_with_setup, build_toc_page_context, construct_analyzer_with_js_lib,
    construct_analyzer_with_source_context, construct_toc_page_analyzer, decode_js_error_url,
    TocPageContext,
};

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

// ─── loginCheckJs 内核（P5 下沉 legado-js，本模块薄壳 re-export）───────────────
//
// [P5-2 双副本消除] 响应解析内核（`LoginCheckResponse` / `LoginCheckEvalError` /
// `execute_login_check_response`）已整体下沉 `legado_js::login_check`；server
// `login_check.rs` 曾持有的最小本地副本同批删除，全栈单一实现。本模块保留
// 同名 re-export：调用方（dict_api/explore_api/search/web_book）路径与签名
// 零改动。解析语义与完整文档见 `legado_js::login_check`。
pub use legado_js::login_check::*;

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
        // [能力对账批次 2 | #702/#850] var → globalThis 属性注入（不注册全局
        // var 条目，与书源块顶层 let 声明不再冲突；读路径等价）
        let wrapped = format!(
            "globalThis.infoMap = {};\nglobalThis.page = {};\nglobalThis.baseUrl = {};\n{}",
            self.info_map_json,
            self.page,
            serde_json::to_string(&self.base_url).unwrap_or_else(|_| "\"\"".to_string()),
            js_code
        );
        self.inner.execute_js(&wrapped)
    }
}

// ─── QuickJS 执行器（P5 下沉 legado-js，本模块薄壳 re-export）──────────────────

/// QuickJS 执行器适配器：实现整体下沉 `legado_js::executor`（P5 随迁，
/// 与 loginCheckJs 内核同批；ffi 侧保留同名 re-export，调用方零改动）。
#[cfg(feature = "quickjs")]
pub use legado_js::executor::QuickJsExecutor;

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
    // P2-19 后续 #9：构造期绑定本源 tag（与 `execute_js` / `source_engine::new_quickjs`
    // 同款 save/restore 包裹，加法式不改签名）：`init_engine` 构造期 eval
    // jsLib/setup 时，顶层副作用（罕见 ajax）须携带本源 JS 宿主 cookie；
    // 不绑定则落入「未归属上下文」（回归面：连本源 cookie 也不带）。
    // 缓存键已含 source_tag：命中时 get_or_create 为 no-op，包裹恒正确。
    let result = legado_js::host_api::current_source::with_current_source_tag(source_tag, || {
        legado_js::engine_cache::get_or_create(&key, Some(js_lib), setup_script, None)
    });
    let (_, _, js_lib_ok) =
        result.map_err(|e| legado_core::LegadoError::JsEngine(e.to_string()))?;
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
    QuickJsExecutor::new("auto_task").execute_js(js_code)
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

    // 已随迁 legado-fetcher 的编解码工具（仅测试用）
    use legado_fetcher::js_adapter::{percent_decode, urlencoding_lite};

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

    /// 修复批 修2 端到端：jsLib 求值失败经 searchUrl 链路**带原因上抛**
    ///
    /// `@js:` searchUrl 模板 + 坏 jsLib → 求值错误应含「jsLib 求值失败: <原始
    /// 错误>」（经 `legado-js-error://` 占位 URL 编解码还原），而非静默降级后
    /// 由脚本引用点报误导性的 `source is not defined`（iOS 实机 1/2 号根因链）；
    /// 错误经 `LegadoError::JsEngine` 通道传递，仅该源失败、不影响 App。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_search_url_jslib_failure_surfaces_reason() {
        let _guard = legado_js::engine_cache::TEST_LOCK.lock().unwrap();
        legado_js::engine_cache::clear_for_tests();
        let bad_lib = "var __probe = __probe_missing_jslib__();";
        let analyzed = build_search_url_with_setup(
            "@js:'https://example.com/search?q=' + encodeURIComponent(key)",
            "斗破苍穹",
            1,
            "jslib_fail_search_tag",
            Some(bad_lib),
            None,
        );
        let rule = analyzed.rule_url();
        assert!(
            rule.starts_with("legado-js-error://"),
            "@js: 模板求值失败应编码为错误占位 URL: {rule}"
        );
        let detail = decode_js_error_url(rule).unwrap_or_default();
        assert!(
            detail.contains("jsLib 求值失败"),
            "错误详情应含「jsLib 求值失败」根因: {detail}"
        );
        assert!(
            detail.contains("__probe_missing_jslib__"),
            "错误详情应保留原始错误文本: {detail}"
        );
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

    /// P2-19 后续 #9（2026-09-23 上游同步改写）：`validate_js_lib` 构造期 jsLib
    /// 顶层 `java.ajax` 必须携带**请求 URL 属域**的 cookie（上游语义：cookie
    /// 属于域名而非书源，读侧按请求 URL 属域取 `cookie_store::cookies_for_url`；
    /// 书源 tag 不再承载 cookie scope）。回环 cookie 记录服务器（P2-17 同款
    /// 模式）；回环域名键（127.0.0.1，IP 自键）与 image_api P2-19 用例共享，
    /// 须持全局存储锁串行。专用缓存键（含 p219 前缀）不与其他用例串扰。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_validate_js_lib_construction_carries_request_domain_cookie() {
        use std::io::{Read, Write};
        use std::sync::{Arc, Mutex};

        use legado_js::host_api::cookie_store;

        // 回环域名键（127.0.0.1）为进程级共享键，与 image_api P2-19 用例串行
        let _lock = crate::test_support::GLOBAL_STORE_TEST_LOCK
            .lock()
            .unwrap_or_else(|p| p.into_inner());

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

        // 书源上下文仍传入（引擎分桶 / jsLib 缓存键），cookie 取用不再按 tag
        const TAG: &str = "https://p219-jslib.example.com/";
        // 上游同步：cookie 键 = 请求 URL 归一域名键（回环 IP 自键 127.0.0.1）
        let echo_url = format!("http://{addr}/echo");
        cookie_store::clear_cookies(&echo_url);
        cookie_store::set_cookie(&echo_url, "p219_lib_token", "lib-val-5f1c");

        // jsLib 顶层 `java.ajax`（入参为 JSON 字符串——java.ajax 桥接签名
        // 为 (options: String)，形态与 network.rs p219 用例一致）
        let js_lib = format!(r#"java.ajax('{{"url":"{echo_url}"}}')"#);
        let res = validate_js_lib(TAG, &js_lib, None);
        assert!(res.is_ok(), "jsLib 顶层 ajax 不应致校验失败: {res:?}");

        let got = seen.lock().unwrap().clone();
        assert!(
            got.as_deref()
                .unwrap_or_default()
                .contains("p219_lib_token=lib-val-5f1c"),
            "构造期 jsLib 顶层 ajax 必须携带请求 URL 属域（127.0.0.1）cookie，实际 Cookie 头: {got:?}"
        );
        cookie_store::clear_cookies(&echo_url);
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
