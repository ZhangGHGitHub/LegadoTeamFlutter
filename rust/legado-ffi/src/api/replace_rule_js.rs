//! 替换规则 `@js:` 执行器（预览 / 正文净化生产 / 书源导入共用）
//!
//! 对齐参考版 `RegexExtensions.kt:32-57`（`CharSequence.replace(regex, ...)`）：
//! 逐匹配执行 `@js:` 表达式，绑定 `result`（当前匹配文本）、`chapter`
//! （`BookChapter` 字段子集）与 `book`（`SearchBook` 字段子集）。
//!
//! 设计要点：
//! - legado-core 只定义 [`legado_core::content_processor::ReplaceJsExecutor`]
//!   契约（不依赖 legado-js），由本模块完成 QuickJS 对接；
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

/// 替换规则 `@js:` 的 QuickJS 执行器
///
/// 实现 legado-core 的 [`ReplaceJsExecutor`] 契约；预览、正文净化与书源导入
/// 均复用本执行器（绑定构造只有一份）。
pub struct ReplaceRuleJsExecutor {
    bindings: ReplaceJsBindings,
}

impl ReplaceRuleJsExecutor {
    /// 以章节/书籍上下文创建执行器（正文净化生产路径）
    pub fn new(bindings: ReplaceJsBindings) -> Self {
        Self { bindings }
    }

    /// 无章节/书籍上下文创建执行器（预览 / 书源导入）
    pub fn without_context() -> Self {
        Self::new(ReplaceJsBindings::empty())
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

/// 替换规则单次 `@js:` 执行的沙箱预算上限
///
/// 与 `SandboxConfig::default().max_execution_time` 保持一致；规则剩余预算
/// 更大时不放大沙箱上限，更小时按剩余预算收紧（回修 P2-1）。
#[cfg(feature = "quickjs")]
const MAX_JS_BUDGET: std::time::Duration = std::time::Duration::from_secs(5);

/// 取当前线程复用的替换规则引擎（首次调用创建，线程结束释放）
///
/// 规则在独立线程执行（`apply_rule_with_timeout`），因此 thread-local 天然
/// 限定「一条规则一个引擎」；逐匹配复用同一 Runtime/Context，避免每次匹配
/// 重建 Runtime（回修 P1）。每次 eval 用 IIFE + 直接 eval 建立新作用域。
#[cfg(feature = "quickjs")]
fn thread_engine() -> Result<std::sync::Arc<std::sync::Mutex<legado_js::QuickJsEngine>>, String> {
    use std::cell::RefCell;
    thread_local! {
        static ENGINE: RefCell<
            Option<std::sync::Arc<std::sync::Mutex<legado_js::QuickJsEngine>>>,
        > = const { RefCell::new(None) };
    }
    ENGINE.with(|slot| {
        let mut slot = slot.borrow_mut();
        if slot.is_none() {
            *slot = Some(
                crate::js_executor::fresh_engine("replace-rule")
                    .map_err(|e| format!("JS 引擎创建失败: {e}"))?,
            );
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
        legado_js::JsEngine::eval(&*engine, &script).map_err(|e| e.to_string())
    }
}
