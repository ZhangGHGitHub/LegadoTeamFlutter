//! 替换规则 `@js:` 执行器（预览 / 正文净化生产 / 书源导入共用）
//!
//! 对齐参考版 `RegexExtensions.kt:32-57`（`CharSequence.replace(regex, ...)`）：
//! 逐匹配执行 `@js:` 表达式，绑定 `result`（当前匹配文本）、`chapter`
//! （`BookChapter` 字段子集）与 `book`（`SearchBook` 字段子集）。
//!
//! 设计要点：
//! - legado-core 只定义 [`legado_core::content_processor::ReplaceJsExecutor`]
//!   契约（不依赖 legado-js），由本模块完成 QuickJS 对接；
//! - **执行器与绑定构造单一下沉点（批17）**：本模块位于 `legado-js`，App 端
//!   （`legado-ffi` 阅读/预览/书源导入）与 Web 阅读端（`legado-server` 正文
//!   净化）均依赖 `legado-js` 并复用同一份实现与绑定脚本构造，禁止复制第二份；
//! - **预览与生产共用同一绑定构造函数**（`ReplaceRuleJsExecutor::build_script`）：
//!   预览/书源导入用 [`ReplaceJsBindings::empty`]（空章节/书籍上下文），
//!   正文净化生产路径注入真实 `chapter`/`book`，消除「预览能跑、生产跳过」；
//! - **每条规则复用同一 QuickJS 引擎**（线程内 thread-local；规则在独立线程
//!   执行，线程结束即释放）：逐匹配用 IIFE + 直接 `eval` 建立新函数作用域，
//!   既避免顶层 `let`/`const` 重复声明，又避免每匹配新建 Runtime 的开销
//!   （回修 P1：2000 次匹配此前约 3s，会触发默认 3000ms 规则超时）；
//! - 逐匹配把规则剩余预算经 [`legado_core::content_processor::ReplaceJsExecutor
//!   ::eval_with_budget`] 下传给沙箱截止时间（回修 P2-1）；
//! - 非 quickjs 构建返回可读 `Err`：正文/导入管线按既有口径保留原文，
//!   其他规则不受影响，不 panic。

use legado_core::content_processor::ReplaceJsExecutor;

/// 替换规则 `@js:` 的章节绑定（对齐参考版 `BookChapter` 字段子集）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReplaceJsChapter {
    /// 章节标题（JS `chapter.title`；无则空串）
    pub title: String,
    /// 章节序号（JS `chapter.index`；无则 0）
    pub index: i32,
    /// 章节地址（JS `chapter.url`；无则空串）
    pub url: String,
    /// 所属书籍地址（JS `chapter.bookUrl`；无则空串）
    pub book_url: String,
}

/// 替换规则 `@js:` 的书籍绑定（对齐参考版 `SearchBook` 字段子集）
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReplaceJsBook {
    /// 书名（JS `book.name`；无则空串）
    pub name: String,
    /// 作者（JS `book.author`；无则空串）
    pub author: String,
    /// 书籍地址（JS `book.bookUrl`；无则空串）
    pub book_url: String,
}

/// 替换规则 `@js:` 绑定上下文
///
/// 参考版在 `RegexExtensions.kt` 中传入 `chapter` 与 `book`（书籍缺失时按
/// `chapter.bookUrl` 回查）；本结构承载 FFI 侧已取到的章节/书籍字段，
/// 空上下文用于预览与书源导入（参考版该两处同样没有书籍上下文）。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReplaceJsBindings {
    /// 章节上下文
    pub chapter: ReplaceJsChapter,
    /// 书籍上下文
    pub book: ReplaceJsBook,
}

impl ReplaceJsBindings {
    /// 空上下文（预览 / 书源导入：无章节、书籍上下文）
    pub fn empty() -> Self {
        Self::default()
    }

    /// 带章节/书籍上下文（正文净化生产路径）
    pub fn new(chapter: ReplaceJsChapter, book: ReplaceJsBook) -> Self {
        Self { chapter, book }
    }
}

/// 图片 `click`/`js` action 的绑定上下文（契约 §2.21 `evalImageAction`）
///
/// 对齐参考版 `ReadBookController.kt:677-695` / `BaseSource.evalJS`：
/// 图片动作可见 `source`（书源 JSON 对象）、`book`（name/author/bookUrl）、
/// `chapter`（title/index/url/bookUrl）、`result`（=imgSrc）与 `baseUrl`
/// （=imgSrc 的目录部分）。`java` 命名空间由引擎宿主 API 全局注册
/// （`log/t2s/s2t/get/put` 等），无需在此重复绑定。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImageActionBindings {
    /// 书源 JSON 对象文本（无书源上下文时传 `"{}"`，避免 JS 侧 undefined）
    pub source_json: String,
    /// 书籍上下文（缺失时字段为空串）
    pub book: ReplaceJsBook,
    /// 章节上下文（缺失时字段为空串/0）
    pub chapter: ReplaceJsChapter,
    /// 动作结果（=imgSrc）
    pub result: String,
    /// 图片地址目录部分（JS `baseUrl`）
    pub base_url: String,
}

impl ImageActionBindings {
    /// 构造图片动作绑定
    pub fn new(
        source_json: impl Into<String>,
        book: ReplaceJsBook,
        chapter: ReplaceJsChapter,
        result: impl Into<String>,
        base_url: impl Into<String>,
    ) -> Self {
        Self {
            source_json: source_json.into(),
            book,
            chapter,
            result: result.into(),
            base_url: base_url.into(),
        }
    }
}

/// 图片 action 默认执行预算（对齐替换规则默认超时 3000ms）
pub const IMAGE_ACTION_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

/// 替换规则 `@js:` 的 QuickJS 执行器
///
/// 实现 legado-core 的 [`ReplaceJsExecutor`] 契约；预览、正文净化与书源导入
/// 均复用本执行器（绑定构造只有一份）。正文图片 `click`/`js` action
/// （契约 §2.21）也复用同一 QuickJS 引擎与 IIFE + `eval` 绑定构造风格
/// （[`Self::eval_image_action`]），不新增第二份执行器。
pub struct ReplaceRuleJsExecutor {
    bindings: ReplaceJsBindings,
}

impl ReplaceRuleJsExecutor {
    /// 以章节/书籍上下文创建执行器（正文净化生产路径）
    pub fn new(bindings: ReplaceJsBindings) -> Self {
        Self { bindings }
    }

    /// 无章节/书籍上下文创建执行器（预览 / 书源导入 / 图片 action）
    pub fn without_context() -> Self {
        Self::new(ReplaceJsBindings::empty())
    }

    /// 执行正文图片 `click`/`js` action（契约 §2.21 `evalImageAction`）
    ///
    /// 默认预算 [`IMAGE_ACTION_TIMEOUT`]（3s）。脚本形如
    /// `(function(source, book, chapter, result, baseUrl){ return eval(<code>); })(…)`，
    /// 与替换规则共用 IIFE + 直接 `eval` 的作用域隔离方式，避免同一引擎
    /// 复用时的顶层重声明。动作抛错/超时/非法返回 `Err`，由调用方按契约
    /// 降级为空串（不 panic）。
    pub fn eval_image_action(
        &self,
        js_code: &str,
        image: &ImageActionBindings,
    ) -> Result<String, String> {
        self.eval_image_action_with_budget(js_code, image, IMAGE_ACTION_TIMEOUT)
    }

    /// 执行图片 action（显式预算；测试与后续配置化入口）
    ///
    /// 每次调用创建独立引擎（对齐参考版 Rhino 每次 `evalJS` 新作用域），
    /// 按书源 `jsLib` 预载共享库（复用 `executor::create_engine_with_js_lib`
    /// 的 URL 映射/归一化级联），再注入 `source`（含 `getKey/getTag/
    /// getVariable/put/get` 方法与按 source 作用域的 `java.get/put`）、
    /// `cookie`、`book/chapter/result/baseUrl` 后执行动作。
    #[cfg(feature = "quickjs")]
    pub fn eval_image_action_with_budget(
        &self,
        js_code: &str,
        image: &ImageActionBindings,
        budget: std::time::Duration,
    ) -> Result<String, String> {
        let budget = budget
            .min(MAX_JS_BUDGET)
            .max(std::time::Duration::from_millis(1));
        let (source_url, source_name, js_lib) = image_action_source_meta(image);
        let source_tag = if source_url.is_empty() {
            image.book.book_url.clone()
        } else {
            source_url.clone()
        };
        let (prelude, script) =
            build_image_action_scripts(image, js_code, &source_url, &source_name)?;
        let engine = crate::executor::create_engine_with_js_lib(
            &source_tag,
            js_lib.as_deref(),
            Some(&prelude),
            None,
            Some(budget),
        )?;
        engine.set_execution_timeout(budget);
        let raw = crate::host_api::current_source::with_current_source_tag(&source_tag, || {
            crate::JsEngine::eval(&engine, &script).map_err(|e| e.to_string())
        })?;
        // 契约：void 动作（java.toast/java.log 等）返回 "undefined" 时归一为空串
        Ok(if raw.trim() == "undefined" {
            String::new()
        } else {
            raw
        })
    }

    /// 非 quickjs 构建：显式返回可读错误（调用方按契约上抛，不静默）
    #[cfg(not(feature = "quickjs"))]
    pub fn eval_image_action_with_budget(
        &self,
        _js_code: &str,
        _image: &ImageActionBindings,
        _budget: std::time::Duration,
    ) -> Result<String, String> {
        Err("QuickJS 未启用，图片 action 不执行".to_string())
    }

    /// 构造 `result` / `chapter` / `book` 三个 JS 绑定并包成 IIFE（唯一绑定构造点）
    ///
    /// 对齐参考版 `RegexExtensions.kt:44-49`：
    /// `bindings["result"] = matcher.group()`、`bindings["chapter"] = chapter`、
    /// `bindings["book"] = book`。章节/书籍以对象注入，字段缺失时给空串/0，
    /// 避免 JS 侧读到 `undefined` 后拼出 `"undefined"`。
    ///
    /// 生成脚本形如：
    /// `(function(result, chapter, book){ return eval(<code>); })(...)`。
    /// 每次调用建立新的函数作用域 + 直接 eval 作用域，因此同一引擎复用不会
    /// 触发顶层 `let`/`const` 重复声明（回修 P1）。
    #[cfg(feature = "quickjs")]
    fn build_script(&self, js_code: &str, result: &str) -> Result<String, String> {
        let code = serde_json::to_string(js_code).map_err(|e| format!("JS 代码序列化失败: {e}"))?;
        let result_json =
            serde_json::to_string(result).map_err(|e| format!("JS result 序列化失败: {e}"))?;
        let chapter_json = serde_json::json!({
            "title": self.bindings.chapter.title,
            "index": self.bindings.chapter.index,
            "url": self.bindings.chapter.url,
            "bookUrl": self.bindings.chapter.book_url,
        });
        let book_json = serde_json::json!({
            "name": self.bindings.book.name,
            "author": self.bindings.book.author,
            "bookUrl": self.bindings.book.book_url,
        });
        Ok(format!(
            "(function(result, chapter, book) {{ return eval({code}); }})(\
             {result_json}, {chapter_json}, {book_json})"
        ))
    }
}

// 注：IIFE 依赖原生 `eval`。`fresh_engine` 以 `allow_script_run(true)` 创建
// 沙箱；若未来关闭该开关，`eval` 会被沙箱替换为返回提示字符串的函数，
// 直接拼进正文会静默污染。`thread_engine` 在引擎创建时探测 `eval('1+1')`，
// 非 "2" 即上抛 Err，由管线保留原文（回修三审 P3-4）。

/// 解析图片动作书源元信息（key/name/jsLib）
///
/// `source_json` 为 `BookSource` 序列化结果；缺失/非法时返回空 key/name 与
/// 无 jsLib（绑定仍为对象，动作按降级路径执行）。
#[cfg(feature = "quickjs")]
fn image_action_source_meta(image: &ImageActionBindings) -> (String, String, Option<String>) {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&image.source_json) else {
        return (String::new(), String::new(), None);
    };
    let url = value
        .get("bookSourceUrl")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let name = value
        .get("bookSourceName")
        .and_then(|v| v.as_str())
        .unwrap_or_default()
        .to_string();
    let js_lib = value
        .get("jsLib")
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .filter(|s| !s.trim().is_empty());
    (url, name, js_lib)
}

/// 构造图片 action 的（前置绑定脚本, 动作脚本）
///
/// 前置脚本对齐参考版 `BaseSource.evalJS` 的绑定面：
/// - `source`（书源 JSON 对象）+ `getKey/getTag/getVariable/putVariable/
///   put/get` 方法；`put/get` 按 `v_{sourceKey}_{key}` 源作用域读写；
/// - `java.get/put` 覆盖为同一源作用域（避免裸键污染 `@get` 兜底层）；
/// - `cookie` 对象（getCookie/setCookie/clearCookies/removeCookie/
///   replaceCookie/cookieToMap/mapToCookie）；
/// - `baseUrl`/`result`/`book`/`chapter` 全局（jsLib 函数裸调用可见）。
///
/// 动作脚本仍用 IIFE + 直接 `eval`（与替换规则同一作用域隔离方式）。
#[cfg(feature = "quickjs")]
fn build_image_action_scripts(
    image: &ImageActionBindings,
    js_code: &str,
    source_url: &str,
    source_name: &str,
) -> Result<(String, String), String> {
    let code = serde_json::to_string(js_code).map_err(|e| format!("图片动作序列化失败: {e}"))?;
    let source = if image.source_json.trim().is_empty() {
        serde_json::json!({})
    } else {
        match serde_json::from_str::<serde_json::Value>(&image.source_json) {
            Ok(value @ serde_json::Value::Object(_)) => value,
            _ => serde_json::json!({}),
        }
    };
    let source_json =
        serde_json::to_string(&source).map_err(|e| format!("图片动作 source 序列化失败: {e}"))?;
    let source_url_json = serde_json::to_string(source_url)
        .map_err(|e| format!("图片动作 sourceKey 序列化失败: {e}"))?;
    let source_name_json = serde_json::to_string(source_name)
        .map_err(|e| format!("图片动作 sourceTag 序列化失败: {e}"))?;
    let result_json = serde_json::to_string(&image.result)
        .map_err(|e| format!("图片动作 result 序列化失败: {e}"))?;
    let base_url_json = serde_json::to_string(&image.base_url)
        .map_err(|e| format!("图片动作 baseUrl 序列化失败: {e}"))?;
    let chapter_json = serde_json::json!({
        "title": image.chapter.title,
        "index": image.chapter.index,
        "url": image.chapter.url,
        "bookUrl": image.chapter.book_url,
    });
    let book_json = serde_json::json!({
        "name": image.book.name,
        "author": image.book.author,
        "bookUrl": image.book.book_url,
    });

    let prelude = format!(
        r#"
var __lgActionSource = {source_json};
var __lgSourceKey = {source_url_json};
var __lgRawGet = java.get;
var __lgRawPut = java.put;
var __lgRawRemove = java.removeVariable;
__lgActionSource.getKey = function() {{ return __lgSourceKey; }};
__lgActionSource.getTag = function() {{ return {source_name_json}; }};
__lgActionSource.getVariable = function() {{
  return __lgRawGet('sourceVariable_' + __lgSourceKey) || '';
}};
__lgActionSource.putVariable = function(v) {{
  if (v === null || v === undefined) {{
    __lgRawRemove('sourceVariable_' + __lgSourceKey);
  }} else {{
    __lgRawPut('sourceVariable_' + __lgSourceKey, String(v));
  }}
  return v;
}};
__lgActionSource.get = function(k) {{
  return __lgRawGet('v_' + __lgSourceKey + '_' + String(k)) || '';
}};
__lgActionSource.put = function(k, v) {{
  var s = (v === null || v === undefined) ? '' : String(v);
  __lgRawPut('v_' + __lgSourceKey + '_' + String(k), s);
  return s;
}};
globalThis.source = __lgActionSource;
globalThis.sourceApi = __lgActionSource;
globalThis.baseUrl = {base_url_json};
globalThis.result = {result_json};
globalThis.book = {book_json};
globalThis.chapter = {chapter_json};
globalThis.cookie = {{
  getCookie: function(url, key) {{
    if (key === undefined || key === null || key === '') {{
      return java.getCookie(String(url));
    }}
    return java.getCookie(String(url), String(key));
  }},
  getKey: function(url, key) {{
    if (key === undefined || key === null || key === '') {{
      return java.getCookie(String(url));
    }}
    return java.getCookie(String(url), String(key));
  }},
  setCookie: function(url, value) {{ return java.setCookie(String(url), String(value)); }},
  clearCookies: function(url) {{ return java.clearCookies(String(url)); }},
  removeCookie: function(url) {{ return java.removeCookie(String(url)); }},
  replaceCookie: function(url, value) {{
    return java.replaceCookie(String(url), String(value == null ? '' : value));
  }},
  cookieToMap: function(str) {{
    try {{ return JSON.parse(java.cookieToMap(String(str == null ? '' : str))); }}
    catch (e) {{ return {{}}; }}
  }},
  mapToCookie: function(map) {{
    var json = (map === null || map === undefined)
      ? '' : (typeof map === 'string' ? map : JSON.stringify(map));
    if (!json) return null;
    var r = java.mapToCookie(json);
    return r === undefined ? null : r;
  }}
}};
java.get = function(k) {{ return __lgActionSource.get(k); }};
java.put = function(k, v) {{ return __lgActionSource.put(k, v); }};
"#
    );
    let script = format!(
        "(function(source, book, chapter, result, baseUrl, java) {{ return eval({code}); }})(\
         __lgActionSource, {book_json}, {chapter_json}, {result_json}, {base_url_json}, java)"
    );
    Ok((prelude, script))
}

/// 替换规则单次 `@js:` 执行的沙箱预算上限
///
/// 与 `SandboxConfig::default().max_execution_time` 保持一致；规则剩余预算
/// 更大时不放大沙箱上限，更小时按剩余预算收紧（回修 P2-1）。
#[cfg(feature = "quickjs")]
const MAX_JS_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);

/// 创建替换规则专用沙箱引擎（允许原生 `eval`，内存上限 64MB）
///
/// 与 App 端正文执行的引擎构造口径一致：`allow_script_run(true)` 保证 IIFE
/// 内 `eval` 为原生实现；64MB 内存上限覆盖大 JSON/长正文的逐匹配结果。
#[cfg(feature = "quickjs")]
fn fresh_engine() -> Result<std::sync::Arc<std::sync::Mutex<crate::QuickJsEngine>>, String> {
    let engine = crate::QuickJsEngine::new(
        crate::SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .map_err(|e| format!("JS 引擎创建失败: {e}"))?;
    Ok(std::sync::Arc::new(std::sync::Mutex::new(engine)))
}

/// 取当前线程复用的替换规则引擎（首次调用创建，线程结束释放）
///
/// 规则在独立线程执行（`apply_rule_with_timeout`），因此 thread-local 天然
/// 限定「一条规则一个引擎」；逐匹配复用同一 Runtime/Context，避免每次匹配
/// 重建 Runtime（回修 P1）。每次 eval 用 IIFE + 直接 eval 建立新作用域。
#[cfg(feature = "quickjs")]
fn thread_engine() -> Result<std::sync::Arc<std::sync::Mutex<crate::QuickJsEngine>>, String> {
    use std::cell::RefCell;
    thread_local! {
        static ENGINE: RefCell<
            Option<std::sync::Arc<std::sync::Mutex<crate::QuickJsEngine>>>,
        > = const { RefCell::new(None) };
    }
    ENGINE.with(|slot| {
        let mut slot = slot.borrow_mut();
        if slot.is_none() {
            let engine = fresh_engine()?;
            // [批15 三审 P3-4] 断言沙箱允许原生 eval：IIFE 依赖直接 eval
            // 建立逐匹配作用域；若 allow_script_run=false，eval 被替换为返回
            // 提示字符串的函数，会把提示文本静默拼进正文。此处主动探测并
            // 上抛，管线按既有口径保留原文。
            {
                let guard = engine.lock().map_err(|_| "JS 引擎锁中毒".to_string())?;
                let probe = crate::JsEngine::eval(&*guard, "eval('1+1')")
                    .map_err(|e| format!("@js: 沙箱 eval 探测失败: {e}"))?;
                if probe != "2" {
                    return Err(format!(
                        "@js: 替换规则依赖原生 eval，当前沙箱禁用了 eval（allow_script_run=false）：{probe}"
                    ));
                }
            }
            *slot = Some(engine);
        }
        Ok(slot
            .as_ref()
            .expect("thread-local 引擎已在上方初始化")
            .clone())
    })
}

impl ReplaceJsExecutor for ReplaceRuleJsExecutor {
    #[cfg(feature = "quickjs")]
    fn eval(&self, js_code: &str, result: &str) -> Result<String, String> {
        self.eval_with_budget(js_code, result, MAX_JS_BUDGET)
    }

    #[cfg(not(feature = "quickjs"))]
    fn eval(&self, js_code: &str, result: &str) -> Result<String, String> {
        // 显式读取字段：非 quickjs 构建也要让上下文结构参与编译（无死代码告警）
        let _ = (&self.bindings, js_code, result);
        Err("QuickJS 未启用，@js: 替换规则不执行（保留原文）".to_string())
    }

    #[cfg(feature = "quickjs")]
    fn eval_with_budget(
        &self,
        js_code: &str,
        result: &str,
        remaining: std::time::Duration,
    ) -> Result<String, String> {
        let budget = remaining
            .min(MAX_JS_BUDGET)
            .max(std::time::Duration::from_millis(1));
        let script = self.build_script(js_code, result)?;
        let engine = thread_engine()?;
        let engine = engine.lock().map_err(|_| "JS 引擎锁中毒".to_string())?;
        engine.set_execution_timeout(budget);
        crate::JsEngine::eval(&*engine, &script).map_err(|e| e.to_string())
    }
}
