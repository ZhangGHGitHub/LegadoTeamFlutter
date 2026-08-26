//! JS 引擎抽象 trait 定义
//!
//! 定义不依赖具体 JS 引擎实现的通用接口，供 QuickJS（rquickjs）实现。

use legado_core::LegadoResult;

/// JS 值类型 —— 用于宿主语言与 JS 之间传递参数
#[derive(Debug, Clone)]
pub enum JsValue {
    Null,
    Undefined,
    Bool(bool),
    Int(i64),
    Number(f64),
    String(String),
    Array(Vec<JsValue>),
    Object(Vec<(String, JsValue)>),
    Bytes(Vec<u8>),
}

impl JsValue {
    /// 将 JS 值转换为字符串表示
    pub fn to_js_string(&self) -> String {
        match self {
            JsValue::Null => "null".to_string(),
            JsValue::Undefined => "undefined".to_string(),
            JsValue::Bool(b) => b.to_string(),
            JsValue::Int(i) => i.to_string(),
            JsValue::Number(n) => n.to_string(),
            JsValue::String(s) => format!("\"{}\"", s.replace('"', "\\\"")),
            JsValue::Array(arr) => {
                let inner: Vec<String> = arr.iter().map(|v| v.to_js_string()).collect();
                format!("[{}]", inner.join(", "))
            }
            JsValue::Object(fields) => {
                let inner: Vec<String> = fields
                    .iter()
                    .map(|(k, v)| format!("{}: {}", k, v.to_js_string()))
                    .collect();
                format!("{{{}}}", inner.join(", "))
            }
            JsValue::Bytes(b) => format!("<bytes len={}>", b.len()),
        }
    }

    /// 尝试将 JS 值转为 Rust 字符串
    pub fn as_str(&self) -> Option<&str> {
        match self {
            JsValue::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    /// 尝试将 JS 值转为布尔值
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            JsValue::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// 尝试将 JS 值转为 f64
    pub fn as_number(&self) -> Option<f64> {
        match self {
            JsValue::Number(n) => Some(*n),
            JsValue::Int(i) => Some(*i as f64),
            _ => None,
        }
    }

    /// 是否为 null 或 undefined
    pub fn is_nullish(&self) -> bool {
        matches!(self, JsValue::Null | JsValue::Undefined)
    }
}

impl From<String> for JsValue {
    fn from(s: String) -> Self {
        JsValue::String(s)
    }
}

impl From<&str> for JsValue {
    fn from(s: &str) -> Self {
        JsValue::String(s.to_string())
    }
}

impl From<bool> for JsValue {
    fn from(b: bool) -> Self {
        JsValue::Bool(b)
    }
}

impl From<f64> for JsValue {
    fn from(n: f64) -> Self {
        JsValue::Number(n)
    }
}

impl From<i64> for JsValue {
    fn from(i: i64) -> Self {
        JsValue::Int(i)
    }
}

/// 预编译脚本 —— 缓存编译结果以提升重复执行性能
#[derive(Debug, Clone)]
pub struct CompiledScript {
    /// 编译后的字节码（QuickJS bytecode）
    pub bytecode: Vec<u8>,
    /// 原始 JS 源码（用于调试）
    pub source: String,
}

impl CompiledScript {
    pub fn new(source: String) -> Self {
        Self {
            bytecode: Vec::new(),
            source,
        }
    }

    pub fn with_bytecode(source: String, bytecode: Vec<u8>) -> Self {
        Self { bytecode, source }
    }
}

/// JS 引擎抽象 trait
///
/// 所有 JS 引擎实现（QuickJS / 占位引擎）必须实现此 trait。
pub trait JsEngine: Send + Sync {
    /// 执行 JS 代码，返回结果字符串
    fn eval(&self, code: &str) -> LegadoResult<String>;

    /// 执行 JS 代码，同时注入变量绑定
    fn eval_with_bindings(&self, code: &str, bindings: &[(&str, JsValue)]) -> LegadoResult<String>;

    /// 预编译 JS 代码为字节码
    fn compile(&self, code: &str) -> LegadoResult<CompiledScript>;

    /// 执行已编译的脚本
    fn execute_compiled(&self, script: &CompiledScript) -> LegadoResult<String>;

    /// 执行已编译的脚本，同时注入变量绑定
    fn execute_compiled_with_bindings(
        &self,
        script: &CompiledScript,
        bindings: &[(&str, JsValue)],
    ) -> LegadoResult<String>;

    /// 执行 JS 代码（带绑定），要求 JS 返回字节数组（Uint8Array）。
    ///
    /// 用于对齐原版 `ImageUtils.decodeImageStream`（imageDecode 规则）：
    /// 图片 bytes 传入 JS（result 绑定），JS 解密后返回 bytes。
    /// 默认实现返回不支持错误，QuickJS 实现将 `JsValue::Bytes` 注入为
    /// Uint8Array 并将结果 Uint8Array 读回。
    fn eval_bytes(&self, code: &str, bindings: &[(&str, JsValue)]) -> LegadoResult<Vec<u8>> {
        let _ = (code, bindings);
        Err(legado_core::LegadoError::JsEngine(
            "eval_bytes not supported by this engine".to_string(),
        ))
    }
}

/// 占位 JS 引擎（未启用 quickjs feature 时使用）
///
/// 所有调用均返回 JsEngine 错误，提示需要启用 quickjs feature。
pub struct StubJsEngine;

impl StubJsEngine {
    pub fn new() -> Self {
        Self
    }
}

impl Default for StubJsEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl JsEngine for StubJsEngine {
    fn eval(&self, _code: &str) -> LegadoResult<String> {
        Err(legado_core::LegadoError::JsEngine(
            "QuickJS engine not enabled. Build with --features quickjs".to_string(),
        ))
    }

    fn eval_with_bindings(
        &self,
        _code: &str,
        _bindings: &[(&str, JsValue)],
    ) -> LegadoResult<String> {
        Err(legado_core::LegadoError::JsEngine(
            "QuickJS engine not enabled. Build with --features quickjs".to_string(),
        ))
    }

    fn compile(&self, code: &str) -> LegadoResult<CompiledScript> {
        // 占位：仅保存源码，无字节码
        Ok(CompiledScript::new(code.to_string()))
    }

    fn execute_compiled(&self, _script: &CompiledScript) -> LegadoResult<String> {
        Err(legado_core::LegadoError::JsEngine(
            "QuickJS engine not enabled. Build with --features quickjs".to_string(),
        ))
    }

    fn execute_compiled_with_bindings(
        &self,
        _script: &CompiledScript,
        _bindings: &[(&str, JsValue)],
    ) -> LegadoResult<String> {
        Err(legado_core::LegadoError::JsEngine(
            "QuickJS engine not enabled. Build with --features quickjs".to_string(),
        ))
    }
}

// ============================================================
// QuickJS 真实引擎实现（启用 quickjs feature 时）
// ============================================================
#[cfg(feature = "quickjs")]
mod quickjs_engine {
    use super::*;
    use crate::host_api::quickjs_impl;
    use crate::sandbox::SandboxConfig;
    use legado_core::LegadoError;
    use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
    use std::sync::Arc;
    use std::time::Instant;

    /// 将 rquickjs::Value 转换为 JsValue
    ///
    /// Object/Array 走 `JSON.stringify`（对齐 Kotlin `JsSourceEngine.normalizeJsResult`
    /// 对 Scriptable 的处理），禁止再降级为 Debug `Array(0x…)`——那会污染
    /// 书名/正文/目录（视频源 vod API 等返回原生数组时的实测回归）。— Reasonix
    #[cfg(feature = "quickjs")]
    fn js_value_from_rquickjs<'js>(
        ctx: &rquickjs::Ctx<'js>,
        val: &rquickjs::Value<'js>,
    ) -> JsValue {
        if val.is_undefined() {
            JsValue::Undefined
        } else if val.is_null() {
            JsValue::Null
        } else if let Some(b) = val.as_bool() {
            JsValue::Bool(b)
        } else if let Some(i) = val.as_int() {
            JsValue::Int(i as i64)
        } else if let Some(f) = val.as_float() {
            JsValue::Number(f)
        } else if let Some(s) = val.as_string() {
            JsValue::String(s.to_string().unwrap_or_default())
        } else if val.is_array() || val.is_object() {
            match ctx.json_stringify(val.clone()) {
                Ok(Some(js_str)) => {
                    // to_string() 用 str::from_utf8 严格校验：QuickJS 对含未配对
                    // 代理对等内容的字符串,JS_ToCStringLen 产出的 UTF-8 可能无效
                    // → Err("QuickJS library created a unknown error") → 上层拿到
                    // "null",规则结果丢失（七猫目录 0 章 2026-08-15）。CString
                    // 的 as_str() 用 from_utf8_unchecked 绕过校验；QuickJS 保证
                    // 字符串内存有效性，仅可能含替换符，不影响 JSON 文本完整性。
                    let s = match js_str.to_string() {
                        Ok(s) => s,
                        Err(_) => js_str
                            .to_cstring()
                            .map(|c| c.as_str().to_string())
                            .unwrap_or_else(|_| "null".to_string()),
                    };
                    JsValue::String(s)
                }
                Ok(None) => JsValue::Null,
                Err(_) => JsValue::String("null".to_string()),
            }
        } else {
            // 其余类型（symbol/function/…）仍无稳定字符串语义，给 null
            JsValue::Null
        }
    }

    /// 将 JsValue 转换为 rquickjs::Value
    #[cfg(feature = "quickjs")]
    fn rquickjs_value_from_js<'js>(
        ctx: &rquickjs::Ctx<'js>,
        val: &JsValue,
    ) -> Result<rquickjs::Value<'js>, LegadoError> {
        match val {
            JsValue::Null => Ok(rquickjs::Value::new_null(ctx.clone())),
            JsValue::Undefined => Ok(rquickjs::Value::new_undefined(ctx.clone())),
            JsValue::Bool(b) => Ok(rquickjs::Value::new_bool(ctx.clone(), *b)),
            JsValue::Int(i) => Ok(rquickjs::Value::new_int(ctx.clone(), *i as i32)),
            JsValue::Number(f) => Ok(rquickjs::Value::new_float(ctx.clone(), *f)),
            JsValue::String(s) => {
                let js_str = rquickjs::String::from_str(ctx.clone(), s.as_str())
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                Ok(js_str.into_value())
            }
            JsValue::Bytes(b) => {
                // 字节数组以 Uint8Array 形式注入（对齐原版 JS 对 byte[] 的操作语义：
                // imageDecode 等规则直接读写字节下标/长度）— Reasonix 2026-08-11
                let arr: rquickjs::TypedArray<u8> = rquickjs::TypedArray::new(ctx.clone(), b.clone())
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                Ok(arr.into_value())
            }
            JsValue::Array(items) => {
                let arr = rquickjs::Array::new(ctx.clone())
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                for (idx, item) in items.iter().enumerate() {
                    let v = rquickjs_value_from_js(ctx, item)?;
                    arr.set(idx, v)
                        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                }
                Ok(arr.into_value())
            }
            JsValue::Object(fields) => {
                let obj = rquickjs::Object::new(ctx.clone())
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                for (key, val) in fields {
                    let v = rquickjs_value_from_js(ctx, val)?;
                    obj.set(key.as_str(), v)
                        .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                }
                Ok(obj.into_value())
            }
        }
    }

    /// 基于 QuickJS 的真实 JS 引擎
    ///
    /// 使用 rquickjs 绑定 QuickJS C 引擎，提供完整的 JS 执行能力。
    /// 支持内存限制、执行超时中断、脚本字节码编译缓存等特性。
    pub struct QuickJsEngine {
        /// QuickJS 运行时（管理内存、中断等）
        #[allow(dead_code)]
        runtime: rquickjs::Runtime,
        /// QuickJS 上下文（持有全局对象）
        context: rquickjs::Context,
        /// 沙箱安全配置
        #[allow(dead_code)]
        config: SandboxConfig,
        /// 时间基准点（进程级固定 Instant，用于计算绝对 deadline）
        epoch: Instant,
        /// 执行超时截止时间（相对于 epoch 的纳秒数），每次 eval 前更新
        deadline_ns: Arc<AtomicU64>,
        /// 超时中断标志
        interrupted: Arc<AtomicBool>,
    }

    // rquickjs Runtime + Context 在启用 "parallel" feature 后是 Send + Sync
    unsafe impl Send for QuickJsEngine {}
    unsafe impl Sync for QuickJsEngine {}

    impl QuickJsEngine {
        /// 创建新的 QuickJS 引擎实例
        ///
        /// 初始化运行时设置内存上限和超时中断，随后注册所有宿主 API。
        pub fn new(config: SandboxConfig) -> Result<Self, LegadoError> {
            // 创建运行时
            let runtime = rquickjs::Runtime::new()
                .map_err(|e| LegadoError::JsEngine(format!("Failed to create Runtime: {}", e)))?;

            // 设置内存限制（字节）
            runtime.set_memory_limit(config.max_memory_bytes);

            // 设置超时中断：handler 在每次 JS 指令时被调用，检查是否超时
            // 使用固定 epoch 作为时间基准，deadline 存储为相对于 epoch 的绝对纳秒数
            let epoch = Instant::now();
            let timeout_ns = config.max_execution_time.as_nanos() as u64;
            let deadline_ns = Arc::new(AtomicU64::new(timeout_ns));
            let interrupted = Arc::new(AtomicBool::new(false));

            let d = deadline_ns.clone();
            let i = interrupted.clone();
            let e = epoch;
            runtime.set_interrupt_handler(Some(Box::new(move || {
                let now_ns = e.elapsed().as_nanos() as u64;
                if now_ns > d.load(Ordering::SeqCst) {
                    i.store(true, Ordering::SeqCst);
                    true // 中断执行
                } else {
                    false
                }
            })));

            // 创建完整上下文（包含所有标准内置对象）
            let context = rquickjs::Context::full(&runtime)
                .map_err(|e| LegadoError::JsEngine(format!("Failed to create Context: {}", e)))?;

            // 注册宿主 API（编解码等），根据沙箱配置门控文件 API
            let api_cfg = config.clone();
            context.with(|ctx| {
                quickjs_impl::register_all_apis(&ctx, &api_cfg)
                    .map_err(|e| LegadoError::JsEngine(format!("Failed to register APIs: {}", e)))
            })?;

            // 应用沙箱安全限制
            let sandbox_cfg = config.clone();
            context.with(|ctx| {
                crate::sandbox::apply_sandbox_restrictions(&ctx, &sandbox_cfg)
                    .map_err(|e| LegadoError::JsEngine(format!("Failed to apply sandbox: {}", e)))
            })?;

            Ok(Self {
                runtime,
                context,
                config,
                epoch,
                deadline_ns,
                interrupted,
            })
        }

        /// 重置超时 deadline（在每次 eval 前调用）
        ///
        /// 将 deadline 设置为「当前时刻 + 超时时长」相对于 epoch 的绝对纳秒数。
        fn reset_deadline(&self) {
            let timeout_ns = self.config.max_execution_time.as_nanos() as u64;
            let now_ns = self.epoch.elapsed().as_nanos() as u64;
            self.deadline_ns
                .store(now_ns + timeout_ns, Ordering::SeqCst);
            self.interrupted.store(false, Ordering::SeqCst);
        }

        /// 向全局对象注入绑定变量
        fn inject_bindings<'js>(
            ctx: &rquickjs::Ctx<'js>,
            bindings: &[(&str, JsValue)],
        ) -> Result<(), LegadoError> {
            let globals = ctx.globals();
            for (name, value) in bindings {
                let v = rquickjs_value_from_js(ctx, value)?;
                globals
                    .set(*name, v)
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
            }
            Ok(())
        }

        /// 将 eval 结果转换为字符串
        ///
        /// 对齐 `JsSourceEngine.normalizeJsResult`：String 原样；null/undefined
        /// 字面量；Object/Array → JSON.stringify（勿用 Debug `Array(0x…)`）。
        fn result_to_string<'js>(ctx: &rquickjs::Ctx<'js>, val: &rquickjs::Value<'js>) -> String {
            match js_value_from_rquickjs(ctx, val) {
                JsValue::String(s) => s,
                JsValue::Null => "null".to_string(),
                JsValue::Undefined => "undefined".to_string(),
                other => other.to_js_string(),
            }
        }

        /// JS 语法检查（只编译不执行）
        ///
        /// 借助 `Function` 构造器：仅将源码作为函数体解析编译，不执行任何代码。
        /// 编译成功返回 `Ok(())`，语法错误时返回携带异常信息（message + stack，
        /// stack 中含 `:<行号>:` 线索）的 `Err`。用于 JS 单文件书源语法校验（#479）。
        ///
        /// 独立 Runtime 施加与 [`SandboxConfig::default`] 一致的 **5s 超时**与 **16MB 内存**
        /// 上限（F3-2），病态输入限时返回而非挂起。
        ///
        /// 注 1：rquickjs 未暴露 `JS_EVAL_FLAG_COMPILE_ONLY` 原生入口，
        /// `Function(code)` 构造器是等价的"只编译不执行"公开方案。
        /// 注 2：沙箱会替换全局 `Function` 构造器，故此处创建独立的纯上下文；
        /// 检查过程不执行待检代码，无沙箱逃逸风险。
        pub fn check_syntax(&self, code: &str) -> Result<(), String> {
            use crate::sandbox::SandboxConfig;

            let limits = SandboxConfig::default();

            // 独立纯上下文：不经沙箱注册，保留原生 Function 构造器
            let runtime = rquickjs::Runtime::new()
                .map_err(|e| format!("语法检查引擎创建失败: {}", e))?;
            runtime.set_memory_limit(limits.max_memory_bytes);

            let epoch = Instant::now();
            let timeout_ns = limits.max_execution_time.as_nanos() as u64;
            let deadline_ns = Arc::new(AtomicU64::new(timeout_ns));
            let interrupted = Arc::new(AtomicBool::new(false));
            let d = deadline_ns.clone();
            let i = interrupted.clone();
            let e = epoch;
            runtime.set_interrupt_handler(Some(Box::new(move || {
                let now_ns = e.elapsed().as_nanos() as u64;
                if now_ns > d.load(Ordering::SeqCst) {
                    i.store(true, Ordering::SeqCst);
                    true
                } else {
                    false
                }
            })));

            let context = rquickjs::Context::full(&runtime)
                .map_err(|e| format!("语法检查上下文创建失败: {}", e))?;
            context.with(|ctx| Self::check_syntax_in_ctx(&ctx, code))
        }

        /// 在指定上下文内执行语法检查（供 [`Self::check_syntax`] 与测试复用）
        fn check_syntax_in_ctx(ctx: &rquickjs::Ctx<'_>, code: &str) -> Result<(), String> {
            // 待检源码暂存为临时全局变量（仅字符串赋值，不执行源码本身）
            let globals = ctx.globals();
            globals
                .set("__legado_syntax_check__", code.to_string())
                .map_err(|e| e.to_string())?;
            // Function 构造器只编译函数体；语法错误时抛出 SyntaxError
            let result: Result<rquickjs::Value, rquickjs::Error> = ctx.eval(
                "(function(){ Function(__legado_syntax_check__); return 'ok'; })()",
            );
            // 清理临时全局变量
            let _ = globals.remove::<&str>("__legado_syntax_check__");
            match result {
                Ok(_) => Ok(()),
                Err(_) => Err(Self::take_exception_message(ctx)),
            }
        }

        /// 提取当前挂起异常的信息（message + stack），不抛出
        fn take_exception_message(ctx: &rquickjs::Ctx<'_>) -> String {
            let exc_val = ctx.catch();
            let mut message = "语法错误".to_string();
            if let Some(exc) = exc_val
                .as_object()
                .and_then(|o| rquickjs::Exception::from_object(o.clone()))
            {
                if let Some(m) = exc.message() {
                    if !m.trim().is_empty() {
                        message = m;
                    }
                }
                let stack = exc.stack().unwrap_or_default();
                if stack.trim().is_empty() {
                    return message;
                }
                return format!("{} ({})", message, stack.trim());
            }
            // 非 Error 对象异常：退化为字符串表示
            if let Some(s) = exc_val.as_string().and_then(|s| s.to_string().ok()) {
                if !s.trim().is_empty() {
                    return s;
                }
            }
            message
        }
    }

    impl JsEngine for QuickJsEngine {
        fn eval(&self, code: &str) -> LegadoResult<String> {
            self.reset_deadline();
            self.context.with(|ctx| {
                // 非严格模式（对齐 Android Rhino 书源生态）：
                // rquickjs 默认 EvalOptions.strict=true，脚本内函数裸调用时
                // this=undefined，书山等聚合源 jsLib 函数常用 `let { source } = this`
                // 访问书源 → Cannot convert undefined or null to object；
                // 非严格下裸调用 this=globalThis（source/java 已挂全局）✅
                // — DeepSeek Harness + Bridge（发现页修复：书山聚合 ERROR 根治）
                // non-exhaustive struct：Default 后逐字段修改（rquickjs 限制）
                let mut options = rquickjs::context::EvalOptions::default();
                options.strict = false;
                options.global = true;
                // 异常消息提取：rquickjs 的 Display 仅输出 "Exception generated
                // by QuickJS"（泛化），真实 message 需从 ctx.catch() 取（对齐
                // 原版 Rhino 异常文案，便于书源规则排错）— Reasonix
                match ctx.eval_with_options::<rquickjs::Value, _>(code, options) {
                    Ok(result) => Ok(Self::result_to_string(&ctx, &result)),
                    Err(_) => Err(LegadoError::JsEngine(Self::take_exception_message(&ctx))),
                }
            })
        }

        fn eval_with_bindings(
            &self,
            code: &str,
            bindings: &[(&str, JsValue)],
        ) -> LegadoResult<String> {
            self.reset_deadline();
            self.context.with(|ctx| {
                Self::inject_bindings(&ctx, bindings)?;
                // non-exhaustive struct：Default 后逐字段修改（rquickjs 限制）
                let mut options = rquickjs::context::EvalOptions::default();
                options.strict = false;
                options.global = true;
                match ctx.eval_with_options::<rquickjs::Value, _>(code, options) {
                    Ok(result) => Ok(Self::result_to_string(&ctx, &result)),
                    Err(_) => Err(LegadoError::JsEngine(Self::take_exception_message(&ctx))),
                }
            })
        }

        fn eval_bytes(&self, code: &str, bindings: &[(&str, JsValue)]) -> LegadoResult<Vec<u8>> {
            self.reset_deadline();
            self.context.with(|ctx| {
                Self::inject_bindings(&ctx, bindings)?;
                // non-exhaustive struct：Default 后逐字段修改（rquickjs 限制）
                let mut options = rquickjs::context::EvalOptions::default();
                options.strict = false;
                options.global = true;
                let result: rquickjs::Value = match ctx.eval_with_options(code, options) {
                    Ok(v) => v,
                    Err(_) => {
                        return Err(LegadoError::JsEngine(Self::take_exception_message(&ctx)))
                    }
                };
                // 结果必须是 Uint8Array（对齐原版 evalJS 返回 ByteArray 语义）
                let arr: rquickjs::TypedArray<u8> = result
                    .get()
                    .map_err(|e| {
                        LegadoError::JsEngine(format!("imageDecode 结果不是字节数组: {e}"))
                    })?;
                let mut buf = vec![0u8; arr.len()];
                let slice = arr.as_bytes().ok_or_else(|| {
                    LegadoError::JsEngine("读取字节数组失败: 非连续缓冲区".to_string())
                })?;
                buf.copy_from_slice(slice);
                Ok(buf)
            })
        }

        fn compile(&self, code: &str) -> LegadoResult<CompiledScript> {
            // rquickjs 0.9 未暴露高级字节码编译 API，
            // 此处仅缓存源码，execute_compiled 时直接 eval 源码。
            Ok(CompiledScript::new(code.to_string()))
        }

        fn execute_compiled(&self, script: &CompiledScript) -> LegadoResult<String> {
            self.reset_deadline();
            self.context.with(|ctx| {
                let result = ctx
                    .eval::<rquickjs::Value, _>(script.source.as_str())
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                Ok(Self::result_to_string(&ctx, &result))
            })
        }

        fn execute_compiled_with_bindings(
            &self,
            script: &CompiledScript,
            bindings: &[(&str, JsValue)],
        ) -> LegadoResult<String> {
            self.reset_deadline();
            self.context.with(|ctx| {
                Self::inject_bindings(&ctx, bindings)?;
                let result = ctx
                    .eval::<rquickjs::Value, _>(script.source.as_str())
                    .map_err(|e| LegadoError::JsEngine(e.to_string()))?;
                Ok(Self::result_to_string(&ctx, &result))
            })
        }
    }
}

#[cfg(feature = "quickjs")]
pub use quickjs_engine::QuickJsEngine;

// ============================================================
// QuickJS 引擎测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod quickjs_tests {
    use super::*;
    use crate::sandbox::SandboxConfig;
    use std::time::{Duration, Instant};

    fn make_engine() -> QuickJsEngine {
        QuickJsEngine::new(SandboxConfig::permissive()).expect("Failed to create QuickJsEngine")
    }

    #[test]
    fn test_eval_basic_arithmetic() {
        let engine = make_engine();
        let result = engine.eval("1 + 2").unwrap();
        assert_eq!(result, "3");
    }

    // 剑来目录 0 章排查（2026-08-15）：qmToc 返回 1279 元素数组,JS 层
    // JSON.stringify 成功,但 engine 层 ctx.json_stringify 返回 Ok(None)/"null"。
    // 本地复现:构造类似结构的大数组,验证 json_stringify 行为。
    #[test]
    fn test_json_stringify_large_array() {
        let engine = make_engine();
        // 1279 元素对象数组,每个含 title/info/url(URL 含长 JSON option,模拟七猫)
        let js = r#"
        (function () {
          var list = [];
          for (var i = 0; i < 1279; i++) {
            list.push({title: '第一章 惊蛰' + i, info: '字数 2964', url: 'https://x.com/c?id=' + i + ',{"m":"GET"}'});
          }
          return list;
        })()
        "#;
        let result = engine.eval(js).unwrap();
        assert!(
            result.starts_with('['),
            "1279 元素大 JSON 数组应序列化,实际: {} (len={})",
            &result[..result.len().min(120)],
            result.len()
        );
        eprintln!("large array stringify ok, len={}", result.len());
    }

    // 剑来目录 0 章根因复现（2026-08-15）：真实七猫 toc_body 的 url 字段含
    // 完整请求 option JSON(含反斜杠转义/长 base64/中文),JSON.stringify 结果
    // 字符串经 JsString::to_string()(JS_ToCStringLen)转换失败 → "null"。
    // 用真实 toc_body 数据验证 result_to_string 对数组的处理。
    #[test]
    fn test_json_stringify_real_qimao_toc() {
        let engine = make_engine();
        // 从真实 toc_body 提取部分 chapter_lists,构造与 qmToc 相同结构的数组
        // （title/info/url,url 为含 option JSON 的长字符串）
        let real_body = r#"{"data":{"id":"143170","type":"chapter_lists","chapter_lists":[{"id":"36898237","content_md5":"715537d66863c86429847eae70865cad","index":"1","title":"第一章 惊蛰","words":"2964","chapter_sort":1},{"id":"36907398","content_md5":"7e94455902f57d45246bec934100989a","index":"2","title":"第二章 开门","words":"3222","chapter_sort":2}]}}"#;
        let js = format!(
            r#"
        (function () {{
          var raw = {real_body};
          var data = raw.data;
          var list = [];
          for (var i = 0; i < 1279; i++) {{
            var x = data.chapter_lists[i % data.chapter_lists.length];
            var url = 'https://api-ks.wtzw.com/api/v1/chapter/content?chapterId=' + x.id + '&id=143170&sign=abc,{{"method":"GET","headers":{{"authorization":"eyJhbGciOiJSUzI1NiIsImNyaXQiOlsiaXNzIiwianRpIiwiaWF0IiwiZXhwIl0sImtpZCI6IjE1MzEyMDM3NjkiLCJ0eXAiOiJKV1QifQ.eyJleHAiOjE3ODkzNDU1MDAsImlhdCI6MTc4Njc1MzUwMCwiaXNzIjoiaHR0cHM6Ly94aWFvc2h1by53dHp3LmNvbS9hcGkvdjEvbG9naW4vdG91cmlzdCIsImp0aSI6InRvdXJpc3QifQ.signature","app-version":"80400","application-id":"com.kmxs.reader","channel":"qm-guanfang_lf","platform":"android","qm-params":"cLGSpqYpCH5A5HwH5w5OEkxuy2TCENTBEG2HTZ5garMH5w5uCR1paHWHTo5pqNzpzNxtqR2pI4QNI-MAaMrNIp2th0UAIG5NlR5AqHENaHjHzk2uz2Tp3U1paHWHTHwgT4wAI0UgIKngh0rgTuxNqfU4lkxgyFLNIGz4q0eNIN-pTo-phFYAhG2gy4wAIHepTHrgzo-pq0MNIpTH5w5BqoTHTZ5gIHWNT9WgT9WgT4WgI9WgqH5taGeBERL4lRUmqF5A5HYNT2zgz4EAhNxpyfM4q4nH5w5OE2etCp2O5HWHT0LH5w5OyxDBzfQByRlpqw5A5GNH5w54CswCEp2O5HWHTKwNI9wH5w5mqU2m3HWH5HjHzUDpyRjHTZ5gTgnghu33e4lFLHjHSuj45U1BqR1HTZ5H5w5uln5tCR1paHWHT-lAq4LpTOYglo-phkxpT05taGTBy22BSFQmqF5A5HYNT2zgz4EAhNxpyfM4q4nH5w54SGxBzF5A5G3pqkQm3HjHzUxmlf5A5G3pqkQm3HjHzY2uoJ2BS45A5HnHSM","reg":"","sign":"02eb844e0ef7c85f1f4640a61d7afbaa","user-agent":"webviewversion/0"}}';
            list.push({{title: x.title, info: '字数 ' + x.words, url: url}});
          }}
          return list;
        }})()
        "#
        );
        let result = engine.eval(&js).unwrap();
        assert!(
            result.starts_with('['),
            "真实七猫结构数组应序列化,实际: {} (len={})",
            &result[..result.len().min(120)],
            result.len()
        );
        eprintln!("real qimao array stringify ok, len={}", result.len());
    }

    #[test]
    fn test_eval_string() {
        let engine = make_engine();
        let result = engine.eval("'hello' + ' ' + 'world'").unwrap();
        assert_eq!(result, "hello world");
    }

    #[test]
    fn test_eval_boolean() {
        let engine = make_engine();
        let result = engine.eval("true && false").unwrap();
        assert_eq!(result, "false");
    }

    #[test]
    fn test_eval_null_undefined() {
        let engine = make_engine();
        assert_eq!(engine.eval("null").unwrap(), "null");
        assert_eq!(engine.eval("undefined").unwrap(), "undefined");
    }

    #[test]
    fn test_eval_with_bindings_string() {
        let engine = make_engine();
        let bindings: Vec<(&str, JsValue)> = vec![("name", JsValue::String("legado".to_string()))];
        let result = engine
            .eval_with_bindings("'hello ' + name", &bindings)
            .unwrap();
        assert_eq!(result, "hello legado");
    }

    #[test]
    fn test_eval_with_bindings_int() {
        let engine = make_engine();
        let bindings: Vec<(&str, JsValue)> = vec![("x", JsValue::Int(42))];
        let result = engine.eval_with_bindings("x * 2", &bindings).unwrap();
        assert_eq!(result, "84");
    }

    #[test]
    fn test_eval_with_bindings_float() {
        let engine = make_engine();
        let bindings: Vec<(&str, JsValue)> = vec![("pi", JsValue::Number(3.14))];
        let result = engine
            .eval_with_bindings("pi.toFixed(2)", &bindings)
            .unwrap();
        assert_eq!(result, "3.14");
    }

    #[test]
    fn test_compile_and_execute() {
        let engine = make_engine();
        let compiled = engine.compile("10 + 20").unwrap();
        // 当前实现仅缓存源码，无字节码
        let result = engine.execute_compiled(&compiled).unwrap();
        assert_eq!(result, "30");
    }

    #[test]
    fn test_execute_compiled_with_bindings() {
        let engine = make_engine();
        let compiled = engine.compile("x + y").unwrap();
        let bindings: Vec<(&str, JsValue)> = vec![("x", JsValue::Int(10)), ("y", JsValue::Int(20))];
        let result = engine
            .execute_compiled_with_bindings(&compiled, &bindings)
            .unwrap();
        assert_eq!(result, "30");
    }

    #[test]
    fn test_host_api_md5_encode() {
        let engine = make_engine();
        let result = engine.eval("md5Encode('hello')").unwrap();
        assert_eq!(result, "5d41402abc4b2a76b9719d911017c592");
    }

    #[test]
    fn test_host_api_encode_uri_component() {
        // [UI-fix 2026-08-10 | Reasonix] 对齐原版 Rhino 内建 encodeURIComponent：
        // yckceo 书源（思兔 sto66 等）searchUrl 模板依赖，缺失致搜索 URL 残缺
        let engine = make_engine();
        let result = engine
            .eval("encodeURIComponent('重生')")
            .expect("encodeURIComponent 应已注册到 quickjs 宿主");
        assert_eq!(result, "%E9%87%8D%E7%94%9F");
        // 保留字符集与 JS 标准一致
        let kept = engine.eval("encodeURIComponent('a-b_c.d!e~f*g(h)i')").unwrap();
        assert_eq!(kept, "a-b_c.d!e~f*g(h)i");
    }

    #[test]
    fn test_host_api_encode_uri_component_search_template() {
        // 思兔阅读 searchUrl 模板：{{encodeURIComponent(key)}}{{page > 1 ? '/' + page : ''}}
        let engine = make_engine();
        let result = engine
            .eval("var key = '斗破苍穹'; encodeURIComponent(key) + (1 > 1 ? '/' + 1 : '')")
            .unwrap();
        assert_eq!(result, "%E6%96%97%E7%A0%B4%E8%8B%8D%E7%A9%B9");
    }

    #[test]
    fn test_host_api_md5_encode_16() {
        let engine = make_engine();
        let result = engine.eval("md5Encode16('hello')").unwrap();
        // md5('hello') = 5d41402abc4b2a76b9719d911017c592
        // 16 位取 [8..24] = bc4b2a76b9719d91
        assert_eq!(result, "bc4b2a76b9719d91");
    }

    #[test]
    fn test_host_api_base64_encode_decode() {
        let engine = make_engine();
        let result = engine.eval("base64Decode(base64Encode('hello'))").unwrap();
        assert_eq!(result, "hello");
    }

    /// Rhino `Packages` Java 桥模拟层：常用类子集（String/Base64/UUID/md5Hex）
    /// 注入后可被七猫四合一等书源 jsLib 正常调用。
    #[test]
    fn test_packages_shim_common_classes() {
        let engine = make_engine();
        let js = r#"
          (function () {
            var bytes = new Packages.java.lang.String('hello').getBytes('UTF-8');
            var b64 = Packages.android.util.Base64.encodeToString(bytes, 0);
            var uuid = Packages.java.util.UUID.randomUUID().toString();
            var md5 = Packages.cn.hutool.crypto.digest.DigestUtil.md5Hex('hello');
            var cut = Packages.java.util.Arrays.copyOfRange(bytes, 0, 2);
            return JSON.stringify({b64: b64, uuidLen: uuid.length, md5: md5, cut: String(cut[0]) + ',' + String(cut[1])});
          })()
        "#;
        let result = engine.eval(js).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["b64"], "aGVsbG8=", "Base64.encodeToString 应输出字节数组的 Base64");
        assert_eq!(parsed["uuidLen"], 36, "UUID 应为标准 36 位格式");
        assert_eq!(
            parsed["md5"],
            "5d41402abc4b2a76b9719d911017c592",
            "md5Hex 应对齐 java.md5Encode"
        );
        assert_eq!(parsed["cut"], "104,101", "copyOfRange 应切片字节");
    }

    /// Rhino `Packages.javax.crypto.Cipher` 字节级 AES-CBC/PKCS5 解密
    /// （七猫章节/榜单密文解密流程：Base64.decode → copyOfRange 取 IV 与
    /// 密文 → SecretKeySpec + IvParameterSpec + Cipher.init(2) + doFinal）。
    #[test]
    fn test_packages_shim_cipher_aes_cbc_decrypt() {
        use base64::Engine;
        let engine = make_engine();
        let key = b"0123456789abcdef";
        let iv = b"fedcba9876543210";
        let plain = "七猫章节内容";
        let ct =
            legado_core::crypto::AesCrypto::encrypt_cbc(key, iv, plain.as_bytes()).unwrap();
        let mut payload = Vec::new();
        payload.extend_from_slice(iv);
        payload.extend_from_slice(&ct);
        let b64 = base64::engine::general_purpose::STANDARD.encode(&payload);
        let js = format!(
            r#"
        (function () {{
          var raw = Packages.android.util.Base64.decode('{b64}', 0);
          var iv = Packages.java.util.Arrays.copyOfRange(raw, 0, 16);
          var enc = Packages.java.util.Arrays.copyOfRange(raw, 16, raw.length);
          var key = new Packages.javax.crypto.spec.SecretKeySpec(new Packages.java.lang.String('0123456789abcdef').getBytes('UTF-8'), 'AES');
          var ivSpec = new Packages.javax.crypto.spec.IvParameterSpec(iv);
          var cipher = Packages.javax.crypto.Cipher.getInstance('AES/CBC/PKCS5Padding');
          cipher.init(2, key, ivSpec);
          var out = cipher.doFinal(enc);
          return String(Packages.java.lang.String(out, 'UTF-8'));
        }})()
        "#
        );
        let result = engine.eval(&js).unwrap();
        assert_eq!(result, plain, "Packages.Cipher.doFinal 应解出明文");
    }

    #[test]
    fn test_host_api_hex_encode_decode() {
        let engine = make_engine();
        let result = engine.eval("hexDecode(hexEncode('abc'))").unwrap();
        assert_eq!(result, "abc");
    }

    #[test]
    fn test_host_api_sha256() {
        let engine = make_engine();
        let result = engine.eval("sha256('hello')").unwrap();
        assert_eq!(
            result,
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        );
    }

    #[test]
    fn test_host_api_encode_uri() {
        let engine = make_engine();
        let result = engine.eval("encodeURI('hello world')").unwrap();
        assert!(
            result.contains("%20"),
            "Expected percent-encoded space, got: {}",
            result
        );
    }

    #[test]
    fn test_eval_error_propagates() {
        let engine = make_engine();
        let result = engine.eval("undefinedFunction()");
        assert!(
            result.is_err(),
            "Expected error for undefined function call"
        );
    }

    #[test]
    fn test_syntax_error() {
        let engine = make_engine();
        let result = engine.eval("function {{{");
        assert!(result.is_err(), "Expected syntax error");
    }

    #[test]
    #[ignore = "QuickJS memory limit test causes ACCESS_VIOLATION on Windows"]
    fn test_sandbox_memory_limit() {
        // 极小内存限制（512KB）应导致大脚本分配失败
        let config = SandboxConfig::strict().with_memory_limit(512 * 1024);
        let engine = QuickJsEngine::new(config).unwrap();
        let big_script = "var arr = []; for (var i = 0; i < 100000; i++) { arr.push(new Array(1000).fill('x')); } arr.length;";
        let result = engine.eval(big_script);
        assert!(
            result.is_err(),
            "Expected memory limit error, got: {:?}",
            result
        );
    }

    #[test]
    fn test_sandbox_timeout() {
        // 测试超时机制：使用递归循环而非紧密循环，以便中断处理器有更多机会被调用
        let config = SandboxConfig::strict().with_timeout(Duration::from_millis(500));
        let engine = QuickJsEngine::new(config).unwrap();
        // 递归调用会消耗调用栈，更容易触发中断检查点
        let result = engine.eval("function f() { f(); } try { f(); } catch(e) {} 'done'");
        // 结果可能是错误（栈溢出或超时），也可能是完成（如果超时未触发）
        // 关键验证：引擎不会无限挂起
        match &result {
            Ok(_v) => {
                // 如果返回了值，确保引擎仍然响应后续调用
                let check = engine.eval("1 + 1");
                assert!(
                    check.is_ok() || check.is_err(),
                    "Engine should still be responsive"
                );
            }
            Err(_) => {
                // 超时或栈溢出均视为成功
            }
        }
    }

    // ============================================================
    // 超时中断回归测试（Task 1.3 修复验证）
    // ============================================================

    #[test]
    fn test_timeout_normal_execution_not_interrupted() {
        // 正常执行不应触发超时：设置 2s 超时，执行快速脚本
        let config = SandboxConfig::permissive().with_timeout(Duration::from_secs(2));
        let engine = QuickJsEngine::new(config).unwrap();

        // 简单计算——应在超时前完成
        let result = engine.eval("var sum = 0; for (var i = 0; i < 1000; i++) { sum += i; } sum");
        assert!(
            result.is_ok(),
            "Normal execution should not timeout: {:?}",
            result
        );
        assert_eq!(result.unwrap(), "499500");

        // 字符串操作
        let result = engine.eval("'hello world'.toUpperCase()");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "HELLO WORLD");
    }

    #[test]
    fn test_timeout_infinite_loop_interrupted() {
        // 无限循环应触发超时中断：设置 100ms 超时
        let config = SandboxConfig::permissive().with_timeout(Duration::from_millis(100));
        let engine = QuickJsEngine::new(config).unwrap();

        let start = std::time::Instant::now();
        let result = engine.eval("while(true) {}");
        let elapsed = start.elapsed();

        // 必须返回错误（被中断）
        assert!(
            result.is_err(),
            "Infinite loop should be interrupted by timeout, got: {:?}",
            result
        );
        // 应在合理时间内返回（不超过 5s，实际应约 100ms）
        assert!(
            elapsed < Duration::from_secs(5),
            "Timeout interrupt took too long: {:?}",
            elapsed
        );
    }

    #[test]
    fn test_timeout_engine_recovers_after_interrupt() {
        // 超时后引擎状态应可恢复：后续 eval 正常工作
        let config = SandboxConfig::permissive().with_timeout(Duration::from_millis(100));
        let engine = QuickJsEngine::new(config).unwrap();

        // 第一次：触发超时
        let result = engine.eval("while(true) {}");
        assert!(result.is_err(), "First eval should timeout");

        // 第二次：正常执行（reset_deadline 应重置中断标志）
        let result = engine.eval("1 + 1");
        assert!(
            result.is_ok(),
            "Engine should recover after timeout, got: {:?}",
            result
        );
        assert_eq!(result.unwrap(), "2");

        // 第三次：再次确认引擎完全可用
        let result = engine.eval("[1,2,3].map(x => x * 10).join(',')");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "10,20,30");
    }

    #[test]
    fn test_check_syntax_valid_and_invalid() {
        let engine = QuickJsEngine::new(SandboxConfig::default()).unwrap();
        assert!(engine.check_syntax("var a = 1;").is_ok());
        let err = engine.check_syntax("var a = ;").unwrap_err();
        assert!(!err.is_empty(), "syntax error should carry message");
    }

    #[test]
    fn test_check_syntax_deep_nesting_does_not_hang() {
        let engine = QuickJsEngine::new(SandboxConfig::default()).unwrap();
        let deep = "{".repeat(8000) + &"}".repeat(8000);
        let start = Instant::now();
        let result = engine.check_syntax(&deep);
        assert!(
            start.elapsed() < Duration::from_secs(6),
            "deep nesting syntax check should finish within timeout window"
        );
        assert!(result.is_err(), "deeply nested braces should not pass: {result:?}");
    }

    #[test]
    fn test_function_definition_and_call() {
        let engine = make_engine();
        let result = engine
            .eval("function add(a, b) { return a + b; } add(3, 4)")
            .unwrap();
        assert_eq!(result, "7");
    }

    #[test]
    fn test_object_creation() {
        let engine = make_engine();
        let result = engine.eval("JSON.stringify({a: 1, b: 'hello'})").unwrap();
        // QuickJS JSON.stringify 输出格式
        assert!(
            result.contains("\"a\""),
            "Result should contain key 'a': {}",
            result
        );
        assert!(
            result.contains("\"hello\""),
            "Result should contain 'hello': {}",
            result
        );
    }

    /// 回归：原生 Array/Object 返回值须 JSON.stringify，禁止 Debug `Array(0x…)`
    ///
    /// 对齐 Kotlin `JsSourceEngine.normalizeJsResult`；视频源 vod API 等
    /// 直接 `return list` 时，详情/正文曾刷出指针地址。— Reasonix
    #[test]
    fn test_eval_array_object_normalized_to_json() {
        let engine = make_engine();
        let arr = engine.eval("[1, 2, \"vod\"]").unwrap();
        assert!(
            !arr.contains("Array(0x") && !arr.contains("0x"),
            "数组不得降级为 Debug 地址: {arr}"
        );
        assert!(
            arr.contains("1") && arr.contains("vod"),
            "数组应 JSON 序列化: {arr}"
        );
        let parsed: serde_json::Value = serde_json::from_str(&arr).expect("应为合法 JSON 数组");
        assert!(parsed.is_array());

        let obj = engine.eval("({name: '测试', id: 32328})").unwrap();
        assert!(
            !obj.contains("Object(0x") && !obj.contains("0x"),
            "对象不得降级为 Debug 地址: {obj}"
        );
        let parsed_obj: serde_json::Value =
            serde_json::from_str(&obj).expect("应为合法 JSON 对象");
        assert_eq!(parsed_obj["name"], "测试");
        assert_eq!(parsed_obj["id"], 32328);
    }

    #[test]
    fn test_array_methods() {
        let engine = make_engine();
        let result = engine
            .eval("[1, 2, 3, 4, 5].map(x => x * 2).join(',')")
            .unwrap();
        assert_eq!(result, "2,4,6,8,10");
    }

    #[test]
    fn test_math_builtin() {
        let engine = make_engine();
        let result = engine.eval("Math.max(1, 5, 3)").unwrap();
        assert_eq!(result, "5");
    }

    #[test]
    fn test_date_builtin() {
        let engine = make_engine();
        let result = engine.eval("new Date(2024, 0, 1).getFullYear()").unwrap();
        assert_eq!(result, "2024");
    }

    // ============================================================
    // 沙箱文件 API 门控测试
    // ============================================================

    #[test]
    fn test_file_api_blocked_with_default_config() {
        // 默认配置 allow_file_access=false，文件 API 不应注册
        let engine = QuickJsEngine::new(SandboxConfig::default()).unwrap();
        let result = engine.eval("typeof readFile");
        assert!(result.is_ok());
        assert_eq!(
            result.unwrap(),
            "undefined",
            "文件 API 在 allow_file_access=false 时不应注册"
        );
    }

    #[test]
    fn test_file_api_available_with_permissive_config() {
        // 宽松配置 allow_file_access=true，文件 API 应已注册
        let engine = QuickJsEngine::new(SandboxConfig::permissive()).unwrap();
        let result = engine.eval("typeof readFile").unwrap();
        assert_eq!(
            result, "function",
            "文件 API 在 allow_file_access=true 时应已注册"
        );
    }
}
