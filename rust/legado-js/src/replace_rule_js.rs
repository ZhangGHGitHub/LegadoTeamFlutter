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
//! - **图片动作引擎按书源 URL 进程内 LRU 缓存**（批21-A，容量
//!   [`IMAGE_ACTION_ENGINE_CACHE_CAPACITY`]）：同一书源连续点击复用已加载
//!   `jsLib` 的引擎，避免大 `jsLib`（数百 KB）每次点击重载；复用前重放
//!   幂等绑定脚本重置 `source/result/baseUrl/book/chapter`，动作仍以
//!   IIFE + 直接 `eval` 隔离（动作内 `let`/`const` 不泄漏到下一次点击）。
//!   书源更新路径经 [`invalidate_image_action_engine`] 主动失效；引擎实例
//!   另在缓存键中校验 `jsLib` 签名，书源改 jsLib 但未调用失效时也会重建；
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

/// 图片动作引擎缓存容量上限（按 `bookSourceUrl` 的进程内 LRU）
///
/// 只在缓存里保留最近点击的若干书源引擎：大 `jsLib` 重载开销被摊薄，
/// 又不至于让长期驻留的引擎无界增长（每引擎含 64MB 上限的 QuickJS 堆）。
pub const IMAGE_ACTION_ENGINE_CACHE_CAPACITY: usize = 4;

/// 图片动作引擎缓存：按 `bookSourceUrl` 的进程内 LRU（批21-A）
///
/// 设计取舍：
/// - **缓存命中直接复用** `Arc<Mutex<QuickJsEngine>>`，仅重新执行轻量绑定
///   脚本 + 动作脚本，不再重载 `jsLib`；
/// - **容量固定 4**（[`IMAGE_ACTION_ENGINE_CACHE_CAPACITY`]）：覆盖读者在
///   少数几本书之间切换的高频场景，同时限制常驻 QuickJS 堆数量；
/// - **并发**：创建在锁外进行（`jsLib` 可能含网络拉取的 URL 映射，持锁
///   会阻塞其他书源）；并发同键竞争时保留先入缓存者，本次新建实例丢弃；
/// - **失效**：书源更新路径调用 [`invalidate_image_action_engine`]；此外
///   缓存键同时校验 `jsLib` 字符串签名，签名变化即重建（防漏调用失效）。
#[cfg(feature = "quickjs")]
mod image_action_engine_cache {
    use std::collections::{HashMap, VecDeque};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

    /// 共享引擎句柄（调用方持锁求值；同一引擎不并发 eval）
    pub(super) type SharedEngine = Arc<Mutex<crate::QuickJsEngine>>;

    struct Entry {
        engine: SharedEngine,
        /// 创建该引擎时的 `jsLib` 源串；用于检测书源更新导致的 jsLib 变更
        js_lib: String,
    }

    struct Store {
        entries: HashMap<String, Entry>,
        /// LRU 顺序：队首最旧、队尾最新
        order: VecDeque<String>,
    }

    static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
    /// 图片动作引擎创建计数（测试/观测用）
    static CREATED: AtomicU64 = AtomicU64::new(0);

    fn store() -> &'static Mutex<Store> {
        STORE.get_or_init(|| {
            Mutex::new(Store {
                entries: HashMap::new(),
                order: VecDeque::new(),
            })
        })
    }

    fn lock_store() -> MutexGuard<'static, Store> {
        store()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn touch(order: &mut VecDeque<String>, key: &str) {
        order.retain(|item| item != key);
        order.push_back(key.to_string());
    }

    fn evict_overflow(store: &mut Store) {
        while store.entries.len() > super::IMAGE_ACTION_ENGINE_CACHE_CAPACITY {
            let Some(oldest) = store.order.pop_front() else {
                break;
            };
            store.entries.remove(&oldest);
        }
    }

    /// 取缓存引擎；返回 `(引擎, 是否本次新建)`
    ///
    /// `source_url` 为空白时不缓存（调用方原有「每次新建」语义）。
    /// 创建闭包返回的引擎视为已执行过初始化脚本（含绑定前置），
    /// 因而 `fresh=true` 时调用方无需再次重放绑定。
    pub(super) fn get_or_create(
        source_url: &str,
        js_lib: Option<&str>,
        create: impl FnOnce() -> Result<SharedEngine, String>,
    ) -> Result<(SharedEngine, bool), String> {
        if source_url.trim().is_empty() {
            let engine = create()?;
            CREATED.fetch_add(1, Ordering::Relaxed);
            return Ok((engine, true));
        }
        let js_lib = js_lib.unwrap_or("").to_string();
        {
            let mut store = lock_store();
            if let Some(entry) = store.entries.get(source_url) {
                if entry.js_lib == js_lib {
                    let engine = entry.engine.clone();
                    touch(&mut store.order, source_url);
                    return Ok((engine, false));
                }
                // jsLib 已变化（书源更新但未显式失效）：旧引擎按失效处理
                store.entries.remove(source_url);
                store.order.retain(|key| key != source_url);
            }
        }
        // 创建可能包含 jsLib 拉取/求值，不持全局锁，避免阻塞其他书源点击
        let engine = create()?;
        CREATED.fetch_add(1, Ordering::Relaxed);
        let mut store = lock_store();
        if let Some(existing) = store.entries.get(source_url) {
            if existing.js_lib == js_lib {
                // 并发同键创建：保留先入缓存者，本次实例随返回值释放
                let engine = existing.engine.clone();
                touch(&mut store.order, source_url);
                return Ok((engine, false));
            }
        }
        store.entries.insert(
            source_url.to_string(),
            Entry {
                engine: engine.clone(),
                js_lib,
            },
        );
        touch(&mut store.order, source_url);
        evict_overflow(&mut store);
        Ok((engine, true))
    }

    pub(super) fn invalidate(source_url: &str) {
        let mut store = lock_store();
        store.entries.remove(source_url);
        store.order.retain(|key| key != source_url);
    }

    pub(super) fn clear() {
        let mut store = lock_store();
        store.entries.clear();
        store.order.clear();
    }

    pub(super) fn len() -> usize {
        lock_store().entries.len()
    }

    pub(super) fn created_count() -> u64 {
        CREATED.load(Ordering::Relaxed)
    }

    pub(super) fn reset_created_count() {
        CREATED.store(0, Ordering::Relaxed);
    }
}

/// 使某书源的图片动作引擎缓存失效（书源新增/更新/删除/导入后调用）
///
/// 缓存本身也会比对 `jsLib` 签名，未调用本函数时改 `jsLib` 仍会重建；
/// 本函数用于书源更新后**立即**释放旧引擎（避免旧 jsLib 继续驻留），
/// 以及删除书源后的内存回收。非 quickjs 构建为空操作。
pub fn invalidate_image_action_engine(source_url: &str) {
    #[cfg(feature = "quickjs")]
    image_action_engine_cache::invalidate(source_url);
    #[cfg(not(feature = "quickjs"))]
    let _ = source_url;
}

/// 当前缓存的图片动作引擎数量（测试/观测用；非 quickjs 构建恒 0）
pub fn image_action_engine_cache_len() -> usize {
    #[cfg(feature = "quickjs")]
    {
        image_action_engine_cache::len()
    }
    #[cfg(not(feature = "quickjs"))]
    {
        0
    }
}

/// 图片动作引擎累计创建次数（测试/观测用；非 quickjs 构建恒 0）
///
/// 计数进程内累计、不随 LRU 淘汰回退；测试可经
/// [`reset_image_action_engine_created_count`] 归零。
pub fn image_action_engine_created_count() -> u64 {
    #[cfg(feature = "quickjs")]
    {
        image_action_engine_cache::created_count()
    }
    #[cfg(not(feature = "quickjs"))]
    {
        0
    }
}

/// 创建计数归零（测试隔离用；生产无副作用）
pub fn reset_image_action_engine_created_count() {
    #[cfg(feature = "quickjs")]
    image_action_engine_cache::reset_created_count();
}

/// 清空图片动作引擎缓存（测试隔离/书源批量变更后用）
pub fn clear_image_action_engines() {
    #[cfg(feature = "quickjs")]
    image_action_engine_cache::clear();
}

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
    /// 引擎按书源 `bookSourceUrl` 进程内 LRU 缓存（批21-A）：首次点击创建
    /// 引擎并按书源 `jsLib` 预载共享库（复用 `executor::
    /// create_engine_with_js_lib` 的 URL 映射/归一化级联），后续点击命中
    /// 缓存直接复用。**每次点击都重放幂等绑定脚本**（`source` 含
    /// `getKey/getTag/getVariable/putVariable/put/get` 方法与按 source
    /// 作用域的 `java.get/put`、`cookie`、`baseUrl/result/book/chapter`），
    /// 因而上一次点击的绑定不会残留到本次；动作本身仍以 IIFE + 直接
    /// `eval` 执行，动作内 `let`/`const` 不进入全局作用域。
    ///
    /// 缓存不命中/被 [`invalidate_image_action_engine`] 清掉/`jsLib`
    /// 签名变化时重新创建；`bookSourceUrl` 为空（无书源上下文）时不缓存，
    /// 保持每次新建的原有语义。
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
        let (engine, fresh) =
            image_action_engine_cache::get_or_create(&source_url, js_lib.as_deref(), || {
                let engine = crate::executor::create_engine_with_js_lib(
                    &source_tag,
                    js_lib.as_deref(),
                    Some(&prelude),
                    None,
                    Some(budget),
                )?;
                Ok(std::sync::Arc::new(std::sync::Mutex::new(engine)))
            })?;
        let guard = engine.lock().map_err(|_| "JS 引擎锁中毒".to_string())?;
        guard.set_execution_timeout(budget);
        let raw = crate::host_api::current_source::with_current_source_tag(&source_tag, || {
            // 复用缓存引擎时重放绑定脚本：重置 source/result/baseUrl/book/
            // chapter 等全局，避免上一次点击的绑定残留（脚本幂等，重复执行
            // 不会重复捕获 java.get/put 原始实现）。
            if !fresh {
                crate::JsEngine::eval(&*guard, &prelude).map_err(|e| e.to_string())?;
            }
            crate::JsEngine::eval(&*guard, &script).map_err(|e| e.to_string())
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
/// **幂等**（批21-A）：前置脚本可在同一缓存引擎上重复求值——`java.get/put`
/// 的原始宿主实现只在首次安装时捕获，绑定全局每次重新赋值，因此复用引擎
/// 不会无限递归覆盖、也不会残留上一次点击的 `result/baseUrl/book/chapter`。
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
// [批21-A] 引擎按书源缓存复用，本脚本每次点击都会重放：
// - java.get/put 的原始实现只在首次安装时捕获，避免复用后把已被覆盖的
//   java.get 当作 raw 实现（会造成无限递归）；
// - source/result/baseUrl/book/chapter 每次重新赋值，点击间不残留。
if (!globalThis.__lgImageActionJavaInstalled) {{
  globalThis.__lgImageActionRawGet = java.get;
  globalThis.__lgImageActionRawPut = java.put;
  globalThis.__lgImageActionRawRemove = java.removeVariable;
  java.get = function(k) {{ return globalThis.source.get(k); }};
  java.put = function(k, v) {{ return globalThis.source.put(k, v); }};
  globalThis.__lgImageActionJavaInstalled = true;
}}
__lgActionSource.getKey = function() {{ return __lgSourceKey; }};
__lgActionSource.getTag = function() {{ return {source_name_json}; }};
__lgActionSource.getVariable = function() {{
  return globalThis.__lgImageActionRawGet('sourceVariable_' + __lgSourceKey) || '';
}};
__lgActionSource.putVariable = function(v) {{
  if (v === null || v === undefined) {{
    globalThis.__lgImageActionRawRemove('sourceVariable_' + __lgSourceKey);
  }} else {{
    globalThis.__lgImageActionRawPut('sourceVariable_' + __lgSourceKey, String(v));
  }}
  return v;
}};
__lgActionSource.get = function(k) {{
  return globalThis.__lgImageActionRawGet('v_' + __lgSourceKey + '_' + String(k)) || '';
}};
__lgActionSource.put = function(k, v) {{
  var s = (v === null || v === undefined) ? '' : String(v);
  globalThis.__lgImageActionRawPut('v_' + __lgSourceKey + '_' + String(k), s);
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

#[cfg(all(test, feature = "quickjs"))]
mod image_action_cache_tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    /// 缓存是进程级静态，模块内测试串行并复位
    static CACHE_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn guarded() -> MutexGuard<'static, ()> {
        let guard = CACHE_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        clear_image_action_engines();
        reset_image_action_engine_created_count();
        guard
    }

    fn source_url(tag: &str) -> String {
        format!("https://image-cache-{tag}.example.com/source")
    }

    /// 测试用目录截取（等价 FFI `image_base_url` 的绝对地址路径）
    fn dir_of(src: &str) -> String {
        let path_end = src.find(['?', '#']).unwrap_or(src.len());
        match src[..path_end].rfind('/') {
            Some(idx) => src[..idx + 1].to_string(),
            None => src.to_string(),
        }
    }

    fn bindings_with(
        url: &str,
        js_lib: Option<&str>,
        name: &str,
        result: &str,
    ) -> ImageActionBindings {
        let source = serde_json::json!({
            "bookSourceUrl": url,
            "bookSourceName": name,
            "jsLib": js_lib.unwrap_or(""),
        });
        ImageActionBindings::new(
            source.to_string(),
            ReplaceJsBook::default(),
            ReplaceJsChapter::default(),
            result,
            dir_of(result),
        )
    }

    fn bindings(url: &str, js_lib: Option<&str>) -> ImageActionBindings {
        bindings_with(
            url,
            js_lib,
            "缓存测试源",
            "https://cdn.example.com/a/pic.jpg",
        )
    }

    fn run(image: &ImageActionBindings, code: &str) -> String {
        ReplaceRuleJsExecutor::without_context()
            .eval_image_action(code, image)
            .unwrap()
    }

    /// 同一书源连续两次点击：引擎只创建一次，jsLib 函数两次都可见
    #[test]
    fn same_source_reuses_engine_and_js_lib() {
        let _guard = guarded();
        let url = source_url("same");
        let image = bindings(
            &url,
            Some("var __key = source.getKey(); function lib() { return __key; }"),
        );
        assert_eq!(run(&image, "lib()"), url);
        assert_eq!(run(&image, "lib()"), url);
        assert_eq!(
            image_action_engine_created_count(),
            1,
            "同一书源只应创建一次引擎"
        );
        assert_eq!(image_action_engine_cache_len(), 1);
    }

    /// 不同书源各自一个引擎（互不复用）
    #[test]
    fn different_sources_get_separate_engines() {
        let _guard = guarded();
        let a = bindings(&source_url("a"), None);
        let b = bindings(&source_url("b"), None);
        assert_eq!(run(&a, "'A'"), "A");
        assert_eq!(run(&b, "'B'"), "B");
        assert_eq!(image_action_engine_created_count(), 2);
        assert_eq!(image_action_engine_cache_len(), 2);
    }

    /// LRU 超限淘汰：容量 4，命中会刷新顺序，最久未用者被淘汰
    #[test]
    fn lru_evicts_least_recently_used() {
        let _guard = guarded();
        let a = bindings(&source_url("lru-a"), None);
        let b = bindings(&source_url("lru-b"), None);
        let c = bindings(&source_url("lru-c"), None);
        let d = bindings(&source_url("lru-d"), None);
        let e = bindings(&source_url("lru-e"), None);
        for image in [&a, &b, &c, &d] {
            let _ = run(image, "1");
        }
        assert_eq!(image_action_engine_created_count(), 4);
        // 触碰 a，使 b 成为最久未用
        let _ = run(&a, "1");
        assert_eq!(image_action_engine_created_count(), 4, "命中不得创建引擎");
        // 插入 e 触发淘汰（evict b）
        let _ = run(&e, "1");
        assert_eq!(image_action_engine_created_count(), 5);
        assert_eq!(image_action_engine_cache_len(), 4);
        // b 已被淘汰 → 重建；e/a 仍命中
        let _ = run(&b, "1");
        assert_eq!(image_action_engine_created_count(), 6);
        let _ = run(&e, "1");
        let _ = run(&a, "1");
        assert_eq!(image_action_engine_created_count(), 6, "e/a 不应被再次创建");
    }

    /// invalidate 后下次点击重新创建（书源更新/删除路径）
    #[test]
    fn invalidate_forces_recreate() {
        let _guard = guarded();
        let url = source_url("invalidate");
        let image = bindings(&url, None);
        let _ = run(&image, "1");
        assert_eq!(image_action_engine_created_count(), 1);
        invalidate_image_action_engine(&url);
        assert_eq!(image_action_engine_cache_len(), 0);
        let _ = run(&image, "2");
        assert_eq!(image_action_engine_created_count(), 2);
    }

    /// 动作内 `let`/`const` 不泄漏到下一次点击（IIFE + eval 作用域隔离）
    #[test]
    fn action_variables_do_not_leak_between_clicks() {
        let _guard = guarded();
        let image = bindings(&source_url("scope"), None);
        assert_eq!(run(&image, "let leaked = 1; 'first'"), "first");
        // 注：`typeof leaked` 的返回值是字符串 "undefined"，会被执行器按
        // void 归一为空串，故用三元表达式产出可区分的结果
        assert_eq!(
            run(
                &image,
                "typeof leaked === 'undefined' ? 'absent' : 'leaked'"
            ),
            "absent"
        );
        assert_eq!(image_action_engine_created_count(), 1);
    }

    /// 复用命中时重放绑定：result/baseUrl/source 均反映本次点击
    #[test]
    fn bindings_are_refreshed_on_cache_hit() {
        let _guard = guarded();
        let url = source_url("refresh");
        let first = bindings_with(&url, None, "旧源名", "https://cdn.example.com/first/a.jpg");
        let second = bindings_with(&url, None, "新源名", "https://cdn.example.com/second/b.jpg");
        assert_eq!(
            run(&first, "[result, baseUrl, source.getTag()].join('|')"),
            "https://cdn.example.com/first/a.jpg|https://cdn.example.com/first/|旧源名"
        );
        assert_eq!(
            run(&second, "[result, baseUrl, source.getTag()].join('|')"),
            "https://cdn.example.com/second/b.jpg|https://cdn.example.com/second/|新源名"
        );
        assert_eq!(image_action_engine_created_count(), 1);
    }

    /// 复用后源作用域 java.get/put 仍工作（原始宿主实现只捕获一次，不递归）
    #[test]
    fn scoped_java_get_put_survive_reuse_without_recursion() {
        let _guard = guarded();
        let url = source_url("javascope");
        let image = bindings(&url, None);
        let key = format!("v_{url}_k");
        assert_eq!(run(&image, "java.put('k', 'v1'); java.get('k')"), "v1");
        assert_eq!(run(&image, "java.get('k')"), "v1");
        assert_eq!(run(&image, "java.put('k', 'v2'); java.get('k')"), "v2");
        let _ = crate::host_api::variable_store::remove_variable(&key);
    }

    /// jsLib 签名变化（书源更新但未显式失效）也触发重建
    #[test]
    fn js_lib_change_rebuilds_engine_without_explicit_invalidate() {
        let _guard = guarded();
        let url = source_url("jslibchange");
        let old = bindings_with(&url, Some("function lib(){ return 'old'; }"), "源", "x");
        let new = bindings_with(&url, Some("function lib(){ return 'new'; }"), "源", "x");
        assert_eq!(run(&old, "lib()"), "old");
        assert_eq!(run(&new, "lib()"), "new");
        assert_eq!(image_action_engine_created_count(), 2);
    }
}
