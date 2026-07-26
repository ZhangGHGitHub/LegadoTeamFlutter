//! JS 上下文管理
//!
//! JsContext 是 JS 引擎运行上下文的封装，负责：
//! - 持有 JS 全局对象引用
//! - 管理变量绑定
//! - 在启用 quickjs 时桥接 rquickjs::Ctx
//!
//! 未启用 quickjs 时仅提供占位结构。

use std::collections::HashMap;

use crate::engine::JsValue;
use crate::sandbox::SandboxConfig;

/// JS 运行上下文
///
/// 封装了 JS 引擎的执行环境，包括全局变量、绑定参数和安全配置。
pub struct JsContext {
    /// 沙箱安全配置
    config: SandboxConfig,
    /// 全局变量绑定
    globals: HashMap<String, JsValue>,
    /// 是否已初始化
    initialized: bool,
    // 启用 quickjs 后可添加:
    // #[cfg(feature = "quickjs")]
    // rt: rquickjs::Runtime,
    // #[cfg(feature = "quickjs")]
    // ctx: rquickjs::Context,
}

impl JsContext {
    /// 创建新的 JS 上下文（使用默认沙箱配置）
    pub fn new() -> Self {
        Self {
            config: SandboxConfig::default(),
            globals: HashMap::new(),
            initialized: false,
        }
    }

    /// 创建指定沙箱配置的 JS 上下文
    pub fn with_config(config: SandboxConfig) -> Self {
        Self {
            config,
            globals: HashMap::new(),
            initialized: false,
        }
    }

    /// 获取沙箱配置
    pub fn config(&self) -> &SandboxConfig {
        &self.config
    }

    /// 设置全局变量
    pub fn set_global(&mut self, name: impl Into<String>, value: JsValue) {
        self.globals.insert(name.into(), value);
    }

    /// 获取全局变量
    pub fn get_global(&self, name: &str) -> Option<&JsValue> {
        self.globals.get(name)
    }

    /// 移除全局变量
    pub fn remove_global(&mut self, name: &str) -> Option<JsValue> {
        self.globals.remove(name)
    }

    /// 获取所有全局变量名
    pub fn global_names(&self) -> Vec<&String> {
        self.globals.keys().collect()
    }

    /// 批量设置绑定
    pub fn set_bindings(&mut self, bindings: &[(&str, JsValue)]) {
        for (name, value) in bindings {
            self.globals.insert(name.to_string(), value.clone());
        }
    }

    /// 标记上下文已初始化
    pub fn mark_initialized(&mut self) {
        self.initialized = true;
    }

    /// 检查上下文是否已初始化
    pub fn is_initialized(&self) -> bool {
        self.initialized
    }

    /// 清空所有全局变量
    pub fn clear_globals(&mut self) {
        self.globals.clear();
    }
}

impl Default for JsContext {
    fn default() -> Self {
        Self::new()
    }
}
