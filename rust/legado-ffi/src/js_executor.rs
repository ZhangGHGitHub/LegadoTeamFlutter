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
    fn global_pool() -> &'static EnginePool {
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
            let guard = engine
                .lock()
                .map_err(|e| format!("JS 引擎加锁失败: {e}"))?;
            // JsEngine::eval 返回 LegadoResult<String>，统一转为 Result<String, String>
            legado_js::JsEngine::eval(&*guard, js_code).map_err(|e| e.to_string())
        }
    }
}

#[cfg(feature = "quickjs")]
pub use quickjs_impl::QuickJsExecutor;

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
        let result = analyzer.get_string("@js:'legado' + '-' + 'js'").unwrap_or_default();
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
}
