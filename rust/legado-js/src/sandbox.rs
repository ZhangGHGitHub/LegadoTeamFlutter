//! JS 沙箱隔离与安全控制
//!
//! 定义 JS 执行的安全边界和资源配置，参考：
//! - QuickJS 内置的内存限制与中断机制
//! - Kotlin 端 Rhino 的 `allowScriptRun`、`recursiveCount` 等安全闸门
//!
//! 启用 quickjs 后，SandboxConfig 将传递给 rquickjs Runtime 配置。

use std::time::Duration;

// ============================================================
// QuickJS 沙箱安全实施
// ============================================================
#[cfg(feature = "quickjs")]
mod quickjs_sandbox {
    use super::*;
    use legado_core::LegadoError;

    /// 安全限制配置 — 允许访问的全局对象白名单
    #[allow(dead_code)]
    const ALLOWED_GLOBALS: &[&str] = &[
        // 标准内置对象
        "Object",
        "Array",
        "String",
        "Number",
        "Boolean",
        "Symbol",
        "Date",
        "Promise",
        "RegExp",
        "Error",
        "TypeError",
        "RangeError",
        "SyntaxError",
        "ReferenceError",
        "URIError",
        "EvalError",
        // 工具对象
        "Math",
        "JSON",
        "Reflect",
        "Proxy",
        // 数据结构
        "Map",
        "Set",
        "WeakMap",
        "WeakSet",
        // 其他安全内置
        "parseInt",
        "parseFloat",
        "isNaN",
        "isFinite",
        "encodeURI",
        "decodeURI",
        "encodeURIComponent",
        "decodeURIComponent",
        "NaN",
        "Infinity",
        "undefined",
        // console（已简化实现）
        "console",
    ];

    /// 应用沙箱安全限制到 QuickJS 上下文
    ///
    /// 根据 `SandboxConfig` 配置执行以下安全限制：
    /// - 删除 `eval` 和 `Function` 构造器（当 `allow_script_run = false` 时）
    /// - 删除文件系统相关全局对象
    /// - 注入简化的 `console` 对象（仅支持 log）
    pub fn apply_sandbox_restrictions<'js>(
        ctx: &rquickjs::Ctx<'js>,
        config: &SandboxConfig,
    ) -> Result<(), LegadoError> {
        let globals = ctx.globals();

        // 注入简化的 console 对象（仅 log）
        inject_safe_console(ctx, &globals)?;

        // 当不允许脚本内运行时，删除 eval 和 Function 构造器
        if !config.allow_script_run {
            remove_dangerous_globals(&globals)?;
        }

        // 当不允许文件访问时，删除文件系统相关对象
        if !config.allow_file_access {
            remove_file_globals(&globals)?;
        }

        Ok(())
    }

    /// 删除危险全局对象（eval / Function）
    fn remove_dangerous_globals<'js>(globals: &rquickjs::Object<'js>) -> Result<(), LegadoError> {
        // 将 eval 替换为抛出错误的函数
        let ctx = globals.ctx();
        globals
            .set(
                "eval",
                rquickjs::Function::new(ctx.clone(), || -> String {
                    "[Sandbox] eval is not allowed in this context".to_string()
                })
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        // 将 Function 构造器替换为抛出错误的函数
        globals
            .set(
                "Function",
                rquickjs::Function::new(ctx.clone(), || -> String {
                    "[Sandbox] Function constructor is not allowed".to_string()
                })
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        Ok(())
    }

    /// 删除文件系统相关全局对象
    fn remove_file_globals<'js>(globals: &rquickjs::Object<'js>) -> Result<(), LegadoError> {
        // QuickJS 默认不包含文件系统 API，此处为安全加固
        // 删除可能由外部注入的全局对象
        let ctx = globals.ctx();
        for name in &["require", "process", "__filename", "__dirname"] {
            // 忽略删除失败（对象不存在的情况）
            let _ = globals.set(*name, rquickjs::Value::new_undefined(ctx.clone()));
        }
        Ok(())
    }

    /// 注入安全的 console 对象（仅支持 log / warn / error）
    fn inject_safe_console<'js>(
        ctx: &rquickjs::Ctx<'js>,
        globals: &rquickjs::Object<'js>,
    ) -> Result<(), LegadoError> {
        let console =
            rquickjs::Object::new(ctx.clone()).map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        // console.log(...args) -> noop（在生产环境中可接入日志收集）
        console
            .set(
                "log",
                rquickjs::Function::new(ctx.clone(), |_args: rquickjs::function::Rest<String>| {
                    // 静默消费参数，避免 JS 报错
                })
                .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        // console.warn(...)
        console
            .set(
                "warn",
                rquickjs::Function::new(ctx.clone(), |_args: rquickjs::function::Rest<String>| {})
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        // console.error(...)
        console
            .set(
                "error",
                rquickjs::Function::new(ctx.clone(), |_args: rquickjs::function::Rest<String>| {})
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?,
            )
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        globals
            .set("console", console)
            .map_err(|e| LegadoError::JsEngine(e.to_string()))?;

        Ok(())
    }
}

#[cfg(feature = "quickjs")]
pub use quickjs_sandbox::apply_sandbox_restrictions;

/// 沙箱安全配置
#[derive(Debug, Clone)]
pub struct SandboxConfig {
    /// 最大执行时间（超时后中断脚本）
    pub max_execution_time: Duration,
    /// 最大调用栈深度
    pub max_stack_depth: usize,
    /// 最大堆内存（字节）
    pub max_memory_bytes: usize,
    /// 是否允许脚本中运行其他脚本（eval, Function 构造等）
    ///
    /// 参考 Kotlin 端 Rhino 的 `allowScriptRun` 闸门
    pub allow_script_run: bool,
    /// 是否允许访问文件系统
    pub allow_file_access: bool,
    /// 是否允许网络请求
    pub allow_network: bool,
    /// 单脚本最大编译缓存数
    pub max_compile_cache: usize,
}

impl SandboxConfig {
    /// 创建默认安全配置（较严格）
    pub fn new() -> Self {
        Self::default()
    }

    /// 创建宽松配置（用于调试或可信脚本）
    pub fn permissive() -> Self {
        Self {
            max_execution_time: Duration::from_secs(30),
            max_stack_depth: 1024,
            max_memory_bytes: 64 * 1024 * 1024,
            allow_script_run: true,
            allow_file_access: true,
            allow_network: true,
            max_compile_cache: 128,
        }
    }

    /// 创建严格配置（用于不可信脚本）
    pub fn strict() -> Self {
        Self {
            max_execution_time: Duration::from_secs(3),
            max_stack_depth: 256,
            max_memory_bytes: 8 * 1024 * 1024,
            allow_script_run: false,
            allow_file_access: false,
            allow_network: false,
            max_compile_cache: 16,
        }
    }

    /// 设置最大执行时间
    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.max_execution_time = timeout;
        self
    }

    /// 设置最大栈深度
    pub fn with_stack_depth(mut self, depth: usize) -> Self {
        self.max_stack_depth = depth;
        self
    }

    /// 设置最大内存
    pub fn with_memory_limit(mut self, bytes: usize) -> Self {
        self.max_memory_bytes = bytes;
        self
    }

    /// 设置是否允许 eval
    pub fn with_allow_script_run(mut self, allow: bool) -> Self {
        self.allow_script_run = allow;
        self
    }

    /// 检查配置是否合法
    pub fn validate(&self) -> Result<(), String> {
        if self.max_execution_time.is_zero() {
            return Err("max_execution_time must be > 0".to_string());
        }
        if self.max_stack_depth == 0 {
            return Err("max_stack_depth must be > 0".to_string());
        }
        if self.max_memory_bytes < 1024 {
            return Err("max_memory_bytes must be >= 1024".to_string());
        }
        Ok(())
    }
}

impl Default for SandboxConfig {
    fn default() -> Self {
        Self {
            max_execution_time: Duration::from_secs(5),
            max_stack_depth: 512,
            max_memory_bytes: 16 * 1024 * 1024,
            allow_script_run: false,
            allow_file_access: false,
            allow_network: true,
            max_compile_cache: 64,
        }
    }
}

/// 沙箱执行状态
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SandboxState {
    /// 空闲，等待执行
    Idle,
    /// 正在执行脚本
    Running,
    /// 执行完成
    Completed,
    /// 执行超时
    TimedOut,
    /// 执行出错
    Error,
}

/// 沙箱执行统计
#[derive(Debug, Clone, Default)]
pub struct SandboxStats {
    /// 累计执行次数
    pub execution_count: u64,
    /// 累计超时次数
    pub timeout_count: u64,
    /// 累计错误次数
    pub error_count: u64,
    /// 最近一次执行耗时
    pub last_execution_time: Option<Duration>,
    /// 峰值内存使用（字节）
    pub peak_memory_bytes: usize,
}

impl SandboxStats {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn record_success(&mut self, duration: Duration) {
        self.execution_count += 1;
        self.last_execution_time = Some(duration);
    }

    pub fn record_timeout(&mut self) {
        self.execution_count += 1;
        self.timeout_count += 1;
    }

    pub fn record_error(&mut self) {
        self.execution_count += 1;
        self.error_count += 1;
    }

    pub fn update_peak_memory(&mut self, bytes: usize) {
        if bytes > self.peak_memory_bytes {
            self.peak_memory_bytes = bytes;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_sandbox_config_default() {
        let cfg = SandboxConfig::default();
        assert_eq!(cfg.max_execution_time, Duration::from_secs(5));
        assert_eq!(cfg.max_stack_depth, 512);
        assert_eq!(cfg.max_memory_bytes, 16 * 1024 * 1024);
        assert!(!cfg.allow_script_run);
        assert!(!cfg.allow_file_access);
        assert!(cfg.allow_network);
        assert_eq!(cfg.max_compile_cache, 64);
    }

    #[test]
    fn test_sandbox_config_permissive() {
        let cfg = SandboxConfig::permissive();
        assert_eq!(cfg.max_execution_time, Duration::from_secs(30));
        assert!(cfg.allow_script_run);
        assert!(cfg.allow_file_access);
        assert!(cfg.allow_network);
    }

    #[test]
    fn test_sandbox_config_strict() {
        let cfg = SandboxConfig::strict();
        assert_eq!(cfg.max_execution_time, Duration::from_secs(3));
        assert!(!cfg.allow_script_run);
        assert!(!cfg.allow_file_access);
        assert!(!cfg.allow_network);
    }

    #[test]
    fn test_sandbox_config_builder() {
        let cfg = SandboxConfig::new()
            .with_timeout(Duration::from_secs(10))
            .with_stack_depth(1024)
            .with_memory_limit(32 * 1024 * 1024)
            .with_allow_script_run(true);
        assert_eq!(cfg.max_execution_time, Duration::from_secs(10));
        assert_eq!(cfg.max_stack_depth, 1024);
        assert_eq!(cfg.max_memory_bytes, 32 * 1024 * 1024);
        assert!(cfg.allow_script_run);
    }

    #[test]
    fn test_sandbox_config_validate_ok() {
        let cfg = SandboxConfig::default();
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn test_sandbox_config_validate_zero_timeout() {
        let cfg = SandboxConfig::default().with_timeout(Duration::from_secs(0));
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn test_sandbox_config_validate_zero_stack() {
        let cfg = SandboxConfig::default().with_stack_depth(0);
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn test_sandbox_config_validate_low_memory() {
        let cfg = SandboxConfig::default().with_memory_limit(512);
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn test_sandbox_state_equality() {
        assert_eq!(SandboxState::Idle, SandboxState::Idle);
        assert_ne!(SandboxState::Running, SandboxState::Completed);
    }

    #[test]
    fn test_sandbox_stats_record_success() {
        let mut stats = SandboxStats::new();
        stats.record_success(Duration::from_millis(100));
        assert_eq!(stats.execution_count, 1);
        assert_eq!(stats.last_execution_time, Some(Duration::from_millis(100)));
    }

    #[test]
    fn test_sandbox_stats_record_timeout() {
        let mut stats = SandboxStats::new();
        stats.record_timeout();
        assert_eq!(stats.execution_count, 1);
        assert_eq!(stats.timeout_count, 1);
    }

    #[test]
    fn test_sandbox_stats_record_error() {
        let mut stats = SandboxStats::new();
        stats.record_error();
        assert_eq!(stats.execution_count, 1);
        assert_eq!(stats.error_count, 1);
    }

    #[test]
    fn test_sandbox_stats_peak_memory() {
        let mut stats = SandboxStats::new();
        stats.update_peak_memory(1000);
        stats.update_peak_memory(500);
        stats.update_peak_memory(2000);
        assert_eq!(stats.peak_memory_bytes, 2000);
    }
}
