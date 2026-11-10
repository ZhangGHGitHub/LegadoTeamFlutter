//! 替换规则 `@js:` 执行器（预览 / 正文净化生产 / 书源导入共用）
//!
//! 对齐参考版 `RegexExtensions.kt:32-57`（`CharSequence.replace(regex, ...)`）：
//! 逐匹配执行 `@js:` 表达式，绑定 `result`（当前匹配文本）、`chapter`
//! （`BookChapter` 字段子集）与 `book`（`SearchBook` 字段子集）。
//!
//! 设计要点：
//! - legado-core 只定义 [`legado_core::content_processor::ReplaceJsExecutor`]
//!   契约（不依赖 legado-js），由本模块完成 QuickJS 对接；
//! - **预览与生产共用同一绑定构造函数**（`ReplaceRuleJsExecutor::js_bindings`）：
//!   预览/书源导入用 [`ReplaceJsBindings::empty`]（空章节/书籍上下文），
//!   正文净化生产路径注入真实 `chapter`/`book`，消除「预览能跑、生产跳过」；
//! - 每次 eval 新建独立引擎（对齐既有预览策略与参考版「每次 eval 新作用域」，
//!   规避顶层 `let`/`const` 在引擎复用下的重复声明错误）；
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

    /// 构造 `result` / `chapter` / `book` 三个 JS 绑定（唯一绑定构造点）
    ///
    /// 对齐参考版 `RegexExtensions.kt:44-49`：
    /// `bindings["result"] = matcher.group()`、`bindings["chapter"] = chapter`、
    /// `bindings["book"] = book`。章节/书籍以对象注入，字段缺失时给空串/0，
    /// 避免 JS 侧读到 `undefined` 后拼出 `"undefined"`。
    #[cfg(feature = "quickjs")]
    fn js_bindings(&self, result: &str) -> [(&'static str, legado_js::JsValue); 3] {
        use legado_js::JsValue;
        [
            ("result", JsValue::String(result.to_string())),
            (
                "chapter",
                JsValue::Object(vec![
                    (
                        "title".to_string(),
                        JsValue::String(self.bindings.chapter.title.clone()),
                    ),
                    (
                        "index".to_string(),
                        JsValue::Int(i64::from(self.bindings.chapter.index)),
                    ),
                    (
                        "url".to_string(),
                        JsValue::String(self.bindings.chapter.url.clone()),
                    ),
                    (
                        "bookUrl".to_string(),
                        JsValue::String(self.bindings.chapter.book_url.clone()),
                    ),
                ]),
            ),
            (
                "book",
                JsValue::Object(vec![
                    (
                        "name".to_string(),
                        JsValue::String(self.bindings.book.name.clone()),
                    ),
                    (
                        "author".to_string(),
                        JsValue::String(self.bindings.book.author.clone()),
                    ),
                    (
                        "bookUrl".to_string(),
                        JsValue::String(self.bindings.book.book_url.clone()),
                    ),
                ]),
            ),
        ]
    }
}

impl ReplaceJsExecutor for ReplaceRuleJsExecutor {
    fn eval(&self, js_code: &str, result: &str) -> Result<String, String> {
        #[cfg(feature = "quickjs")]
        {
            let engine = crate::js_executor::fresh_engine("replace-rule")
                .map_err(|e| format!("JS 引擎创建失败: {e}"))?;
            let engine = engine.lock().map_err(|_| "JS 引擎锁中毒".to_string())?;
            let bindings = self.js_bindings(result);
            legado_js::JsEngine::eval_with_bindings(&*engine, js_code, &bindings)
                .map_err(|e| e.to_string())
        }
        #[cfg(not(feature = "quickjs"))]
        {
            // 显式读取字段：非 quickjs 构建也要让上下文结构参与编译（无死代码告警）
            let _ = (&self.bindings, js_code, result);
            Err("QuickJS 未启用，@js: 替换规则不执行（保留原文）".to_string())
        }
    }
}
