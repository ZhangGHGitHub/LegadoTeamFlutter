//! legado-js: JS 沙箱引擎（基于 QuickJS / rquickjs）
//!
//! 提供完整的 JS 脚本执行能力，包括：
//! - **engine** — JS 引擎抽象 trait（`JsEngine`、`JsValue`、`CompiledScript`）
//! - **context** — JS 运行上下文管理
//! - **sandbox** — 沙箱安全配置与状态监控
//! - **host_api** — 宿主 API 注册框架（网络、Cookie、编解码、加密、文件、工具）
//! - **scope** — 共享作用域 LRU 缓存管理
//! - **source_engine** — JS 源执行器（书源脚本调用）
//!
//! ## Feature Flags
//!
//! - `quickjs` — 启用 QuickJS 引擎（需编译 C 代码，耗时较长）
//!
//! ## 使用示例
//!
//! ```rust,ignore
//! use legado_js::engine::{JsEngine, StubJsEngine};
//!
//! let engine = StubJsEngine::new();
//! let result = engine.eval("1 + 1"); // 未启用 quickjs 时返回错误
//! ```

pub mod engine;
#[cfg(feature = "quickjs")]
pub mod engine_cache;
pub mod engine_pool;
pub mod host_api;
pub mod js_source;
pub mod jslib_normalize;
pub mod sandbox;
pub mod scope;
pub mod source_engine;

// 核心类型重导出
#[cfg(feature = "quickjs")]
pub use engine::QuickJsEngine;
pub use engine::{CompiledScript, JsEngine, JsValue, StubJsEngine};
#[cfg(feature = "quickjs")]
pub use engine_pool::EnginePool;
pub use host_api::HostEnv;
pub use sandbox::{SandboxConfig, SandboxState, SandboxStats};
pub use scope::{ScopeData, SharedScopeManager};
pub use source_engine::{CallResult, JsSourceConfig, JsSourceEngine};

/// 创建一个默认配置的 JS 源执行器（使用占位引擎）
pub fn new_stub_engine(source_url: &str, main_js: &str) -> JsSourceEngine {
    JsSourceEngine::new_stub(JsSourceConfig::new(
        source_url.to_string(),
        main_js.to_string(),
    ))
}

/// 创建一个默认配置的 JS 源执行器（使用 QuickJS 真实引擎）
///
/// 仅在启用 `quickjs` feature 时可用。
#[cfg(feature = "quickjs")]
pub fn new_quickjs_engine(
    source_url: &str,
    main_js: &str,
) -> Result<JsSourceEngine, legado_core::LegadoError> {
    JsSourceEngine::new_quickjs(JsSourceConfig::new(
        source_url.to_string(),
        main_js.to_string(),
    ))
}
