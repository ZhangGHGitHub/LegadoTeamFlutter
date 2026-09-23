//! JS 源执行器
//!
//! 参考 Kotlin 端 `JsSourceEngine.kt`：
//! - 纯 JS 单文件源执行器
//! - 每次调用新建作用域（并发隔离）：绑定 → 挂共享原型 → eval 主脚本 → eval 调用表达式
//! - args 以绑定进 scope，既是函数参数也是环境绑定
//!
//! 未启用 quickjs feature 时仅提供占位结构。

use std::collections::HashMap;

use legado_core::{LegadoError, LegadoResult};

#[cfg(feature = "quickjs")]
use crate::engine::QuickJsEngine;
use crate::engine::{CompiledScript, JsEngine, JsValue, StubJsEngine};
#[cfg(feature = "quickjs")]
use crate::engine_pool::EnginePool;
#[cfg(feature = "quickjs")]
use crate::sandbox::SandboxConfig;
use crate::scope::SharedScopeManager;
#[cfg(feature = "quickjs")]
use std::sync::{Arc, Mutex};

/// JS 源执行器配置
#[derive(Debug, Clone)]
pub struct JsSourceConfig {
    /// JS 源的 URL（书源标识）
    pub source_url: String,
    /// 主 JS 脚本内容
    pub main_js: String,
    /// 可选的 jsLib（共享库代码）
    pub js_lib: Option<String>,
    /// 可选的 CryptoJS 注入开关
    pub inject_crypto: bool,
}

impl JsSourceConfig {
    pub fn new(source_url: String, main_js: String) -> Self {
        Self {
            source_url,
            main_js,
            js_lib: None,
            inject_crypto: false,
        }
    }

    pub fn with_js_lib(mut self, js_lib: String) -> Self {
        self.js_lib = Some(js_lib);
        self
    }

    pub fn with_crypto(mut self, inject: bool) -> Self {
        self.inject_crypto = inject;
        self
    }
}

/// 函数调用结果
#[derive(Debug, Clone)]
pub struct CallResult {
    /// 函数是否存在
    pub exists: bool,
    /// 函数返回值（null/undefined → None）
    pub value: Option<String>,
}

impl CallResult {
    pub fn not_found() -> Self {
        Self {
            exists: false,
            value: None,
        }
    }

    pub fn success(value: Option<String>) -> Self {
        Self {
            exists: true,
            value,
        }
    }
}

/// JS 源执行引擎
///
/// 管理一个 JS 源的完整执行生命周期：
/// 1. 编译并缓存主脚本
/// 2. 构建作用域（注入绑定 + 共享原型）
/// 3. 执行函数调用
/// 4. 归一化返回值
///
/// 支持两种引擎持有方式：
/// - 直接持有 `Box<dyn JsEngine>`（stub / with_engine）
/// - 通过 `EnginePool` 按 source_tag 共享引擎（池化模式）
pub struct JsSourceEngine {
    /// 源配置
    config: JsSourceConfig,
    /// JS 引擎实例（非池化模式）
    engine: Option<Box<dyn JsEngine>>,
    /// 引擎池（池化模式，启用 quickjs 时可用）
    #[cfg(feature = "quickjs")]
    #[allow(dead_code)]
    engine_pool: Option<Arc<EnginePool>>,
    /// 池化模式下缓存的引擎引用（避免每次调用都查池）
    #[cfg(feature = "quickjs")]
    pooled_engine: Option<Arc<Mutex<QuickJsEngine>>>,
    /// 书源标识（用于 Cookie/变量隔离，后续由 HostEnv 承载）
    source_tag: Option<String>,
    /// 共享作用域管理器（外部注入，多源共享）
    scope_manager: Option<SharedScopeManager>,
    /// 脚本编译缓存（函数名 → 编译结果）
    script_cache: HashMap<String, CompiledScript>,
    /// mainJs 是否已经 eval 过（求值缓存标记）
    main_js_loaded: bool,
}

impl JsSourceEngine {
    /// 使用占位引擎创建（未启用 quickjs 时）
    pub fn new_stub(config: JsSourceConfig) -> Self {
        let source_tag = Some(config.source_url.clone());
        Self {
            engine: Some(Box::new(StubJsEngine::new())),
            #[cfg(feature = "quickjs")]
            engine_pool: None,
            #[cfg(feature = "quickjs")]
            pooled_engine: None,
            config,
            source_tag,
            scope_manager: None,
            script_cache: HashMap::new(),
            main_js_loaded: false,
        }
    }

    /// 使用 QuickJS 真实引擎创建（启用 quickjs feature 时）
    #[cfg(feature = "quickjs")]
    pub fn new_quickjs(config: JsSourceConfig) -> Result<Self, legado_core::LegadoError> {
        let source_tag = Some(config.source_url.clone());
        let cache_key = format!("mainjs:{}:{}", config.source_url, config.main_js);
        // P2-19 后续 #10：构造期绑定本源 tag（与 `call_function` 同款 save/restore
        // 包裹，不改签名）：`init_engine` 构造期 eval jsLib/setup/mainJs 时，顶层
        // 副作用（如 mainJs 顶层 `java.ajax`）须携带本源 JS 宿主 cookie；不绑定
        // 则落入「未归属上下文」，连本源自己的 cookie 也不携带（回归面）。
        // 缓存键含 source_url：命中时 get_or_create 为 no-op，包裹恒正确。
        let (pooled_engine, _js_lib_ok, main_js_status) =
            crate::host_api::current_source::with_current_source_tag(&config.source_url, || {
                crate::engine_cache::get_or_create(
                    &cache_key,
                    config.js_lib.as_deref(),
                    None,
                    Some(&config.main_js),
                )
            })?;
        // 构建时 mainJs eval 失败（如顶层引用注入变量）→ 不标记 loaded，
        // 首次 invoke 走既有带 bindings 重评路径（与旧实现错误语义一致）。
        let main_js_loaded = !matches!(main_js_status, Some(false));
        Ok(Self {
            engine: None,
            engine_pool: None,
            pooled_engine: Some(pooled_engine),
            config,
            source_tag,
            scope_manager: None,
            script_cache: HashMap::new(),
            main_js_loaded,
        })
    }

    /// 使用指定沙箱配置的 QuickJS 引擎创建
    #[cfg(feature = "quickjs")]
    pub fn new_quickjs_with_sandbox(
        config: JsSourceConfig,
        sandbox_config: SandboxConfig,
    ) -> Result<Self, legado_core::LegadoError> {
        let engine = QuickJsEngine::new(sandbox_config)?;
        let source_tag = Some(config.source_url.clone());
        Ok(Self {
            engine: Some(Box::new(engine)),
            engine_pool: None,
            pooled_engine: None,
            config,
            source_tag,
            scope_manager: None,
            script_cache: HashMap::new(),
            main_js_loaded: false,
        })
    }

    /// 使用引擎池创建（池化模式）
    ///
    /// 从共享引擎池中按 source_tag 获取或创建引擎，避免每源重复创建。
    /// 引擎创建失败时返回 `Err`（遵循 FFI 禁 panic 规范）。
    #[cfg(feature = "quickjs")]
    pub fn new_with_pool(
        config: JsSourceConfig,
        pool: Arc<EnginePool>,
    ) -> Result<Self, legado_core::LegadoError> {
        let source_tag = config.source_url.clone();
        let pooled_engine = pool.get_or_create(&source_tag)?;
        Ok(Self {
            engine: None,
            engine_pool: Some(pool),
            pooled_engine: Some(pooled_engine),
            source_tag: Some(source_tag),
            config,
            scope_manager: None,
            script_cache: HashMap::new(),
            main_js_loaded: false,
        })
    }

    /// 使用指定 JS 引擎创建
    pub fn with_engine(config: JsSourceConfig, engine: Box<dyn JsEngine>) -> Self {
        let source_tag = Some(config.source_url.clone());
        Self {
            engine: Some(engine),
            #[cfg(feature = "quickjs")]
            engine_pool: None,
            #[cfg(feature = "quickjs")]
            pooled_engine: None,
            config,
            source_tag,
            scope_manager: None,
            script_cache: HashMap::new(),
            main_js_loaded: false,
        }
    }

    /// 设置共享作用域管理器
    pub fn set_scope_manager(&mut self, manager: SharedScopeManager) {
        self.scope_manager = Some(manager);
    }

    /// 获取源 URL
    pub fn source_url(&self) -> &str {
        &self.config.source_url
    }

    /// 获取书源标识（用于 Cookie/变量隔离）
    pub fn source_tag(&self) -> Option<&str> {
        self.source_tag.as_deref()
    }

    /// 调用 JS 函数并返回结果
    ///
    /// 参考 `JsSourceEngine.callFunction()`
    ///
    /// 流程：
    /// 1. 构建作用域（绑定参数 + 主脚本 eval）
    /// 2. 构造调用表达式 `funcName(arg1, arg2, ...)`
    /// 3. eval 调用表达式
    /// 4. 归一化返回值
    pub fn call_function(
        &mut self,
        name: &str,
        args: &[(&str, JsValue)],
    ) -> LegadoResult<Option<String>> {
        // 绑定当前书源上下文（供 getVerificationCode 等宿主钩子识别书源，
        // 对齐 Kotlin JsExtensions.getSource()），结束后恢复原值
        let tag = self.config.source_url.clone();
        crate::host_api::current_source::with_current_source_tag(&tag, || {
            self.call_function_inner(name, args)
        })
    }

    fn call_function_inner(
        &mut self,
        name: &str,
        args: &[(&str, JsValue)],
    ) -> LegadoResult<Option<String>> {
        if self.config.main_js.is_empty() {
            return Err(LegadoError::JsEngine("mainJs 为空，非 JS 源".to_string()));
        }

        // 构建绑定列表：包含标准绑定 + 用户参数
        let mut bindings: Vec<(&str, JsValue)> =
            vec![("baseUrl", JsValue::String(self.config.source_url.clone()))];
        bindings.extend_from_slice(args);

        // 构造调用表达式
        let call_expr = self.build_call_expression(name, args);

        // 根据引擎持有方式分发执行
        #[cfg(feature = "quickjs")]
        {
            // 克隆 Arc 以释放对 self 的借用
            let pooled_opt = self.pooled_engine.clone();
            if let Some(pooled) = pooled_opt {
                // 池化模式：通过 Arc<Mutex<QuickJsEngine>> 执行
                let engine_guard = pooled.lock().unwrap();

                // 首次调用时 eval 主脚本，后续跳过（mainJs 求值缓存）
                if !self.main_js_loaded {
                    let _ = engine_guard.eval_with_bindings(&self.config.main_js, &bindings)?;
                    self.main_js_loaded = true;
                }

                // 编译并执行调用表达式（内联缓存逻辑避免借用冲突）
                let compiled = if let Some(cached) = self.script_cache.get(&call_expr) {
                    cached.clone()
                } else {
                    let c = engine_guard.compile(&call_expr)?;
                    self.script_cache.insert(call_expr.clone(), c.clone());
                    c
                };
                let result = engine_guard.execute_compiled_with_bindings(&compiled, &bindings)?;

                return Ok(Self::normalize_result(&result));
            }
        }

        // 非池化模式：通过 Box<dyn JsEngine> 执行
        // 首次调用时 eval 主脚本，后续跳过（mainJs 求值缓存）
        if !self.main_js_loaded {
            let engine = self
                .engine
                .as_ref()
                .ok_or_else(|| LegadoError::JsEngine("引擎未初始化".to_string()))?;
            let _ = engine.eval_with_bindings(&self.config.main_js, &bindings)?;
            self.main_js_loaded = true;
        }

        // 编译并执行调用表达式
        let compiled = self.get_or_compile(&call_expr)?;
        let result = {
            let engine = self
                .engine
                .as_ref()
                .ok_or_else(|| LegadoError::JsEngine("引擎未初始化".to_string()))?;
            engine.execute_compiled_with_bindings(&compiled, &bindings)?
        };

        // 归一化结果
        Ok(Self::normalize_result(&result))
    }

    /// 调用可选函数：函数缺失时返回 CallResult::not_found() 而非报错
    ///
    /// 参考 `JsSourceEngine.callFunctionIfExists()`
    pub fn call_function_if_exists(
        &mut self,
        name: &str,
        args: &[(&str, JsValue)],
    ) -> LegadoResult<CallResult> {
        match self.call_function(name, args) {
            Ok(value) => Ok(CallResult::success(value)),
            Err(LegadoError::JsEngine(msg)) if msg.contains("缺少函数") => {
                Ok(CallResult::not_found())
            }
            Err(e) => Err(e),
        }
    }

    /// 构造 JS 函数调用表达式
    fn build_call_expression(&self, name: &str, args: &[(&str, JsValue)]) -> String {
        let arg_names: Vec<&str> = args.iter().map(|(k, _)| *k).collect();
        format!("{}({})", name, arg_names.join(", "))
    }

    /// 获取或编译脚本（带缓存，非池化模式）
    fn get_or_compile(&mut self, code: &str) -> LegadoResult<CompiledScript> {
        if let Some(cached) = self.script_cache.get(code) {
            return Ok(cached.clone());
        }
        let engine = self
            .engine
            .as_ref()
            .ok_or_else(|| LegadoError::JsEngine("引擎未初始化".to_string()))?;
        let compiled = engine.compile(code)?;
        self.script_cache.insert(code.to_string(), compiled.clone());
        Ok(compiled)
    }

    /// 归一化 JS 返回值
    ///
    /// 参考 `JsSourceEngine.normalizeJsResult()`：
    /// - "null" / "undefined" → None
    /// - 其他字符串 → Some(String)
    pub fn normalize_result(result: &str) -> Option<String> {
        let trimmed = result.trim();
        if trimmed.is_empty() || trimmed == "null" || trimmed == "undefined" {
            None
        } else {
            Some(trimmed.to_string())
        }
    }

    /// 查询 mainJs 是否已经被 eval 过（求值缓存状态）
    pub fn is_main_js_loaded(&self) -> bool {
        self.main_js_loaded
    }

    /// 重置 mainJs 求值缓存状态（强制下次调用重新 eval mainJs）
    pub fn reset_main_js_state(&mut self) {
        self.main_js_loaded = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{CompiledScript, JsEngine, JsValue};
    use legado_core::LegadoResult;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// 测试用引擎：记录 eval 调用次数
    struct CountingEngine {
        eval_count: Arc<AtomicUsize>,
    }

    impl CountingEngine {
        fn new() -> (Self, Arc<AtomicUsize>) {
            let counter = Arc::new(AtomicUsize::new(0));
            (
                Self {
                    eval_count: counter.clone(),
                },
                counter,
            )
        }
    }

    impl JsEngine for CountingEngine {
        fn eval(&self, _code: &str) -> LegadoResult<String> {
            self.eval_count.fetch_add(1, Ordering::SeqCst);
            Ok("ok".to_string())
        }

        fn eval_with_bindings(
            &self,
            _code: &str,
            _bindings: &[(&str, JsValue)],
        ) -> LegadoResult<String> {
            self.eval_count.fetch_add(1, Ordering::SeqCst);
            Ok("ok".to_string())
        }

        fn compile(&self, code: &str) -> LegadoResult<CompiledScript> {
            Ok(CompiledScript::new(code.to_string()))
        }

        fn execute_compiled(&self, _script: &CompiledScript) -> LegadoResult<String> {
            Ok("result".to_string())
        }

        fn execute_compiled_with_bindings(
            &self,
            _script: &CompiledScript,
            _bindings: &[(&str, JsValue)],
        ) -> LegadoResult<String> {
            Ok("result".to_string())
        }
    }

    fn make_test_engine() -> (JsSourceEngine, Arc<AtomicUsize>) {
        let config = JsSourceConfig::new(
            "http://test.com".to_string(),
            "function hello(name) { return 'hi ' + name; }".to_string(),
        );
        let (engine, counter) = CountingEngine::new();
        let source_engine = JsSourceEngine::with_engine(config, Box::new(engine));
        (source_engine, counter)
    }

    #[test]
    fn test_main_js_eval_only_once() {
        let (mut se, counter) = make_test_engine();

        // 第一次调用：eval mainJs + execute call_expr
        let _ = se.call_function("hello", &[("name", JsValue::String("world".to_string()))]);
        assert!(se.is_main_js_loaded());
        let count_after_first = counter.load(Ordering::SeqCst);
        assert_eq!(count_after_first, 1); // mainJs eval 只发生一次

        // 第二次调用：不再 eval mainJs
        let _ = se.call_function("hello", &[("name", JsValue::String("again".to_string()))]);
        let count_after_second = counter.load(Ordering::SeqCst);
        assert_eq!(count_after_second, 1); // 未增加，证明 mainJs 未重新 eval
    }

    #[test]
    fn test_main_js_not_loaded_initially() {
        let (se, _) = make_test_engine();
        assert!(!se.is_main_js_loaded());
    }

    #[test]
    fn test_reset_main_js_state() {
        let (mut se, counter) = make_test_engine();

        let _ = se.call_function("hello", &[("name", JsValue::String("a".to_string()))]);
        assert!(se.is_main_js_loaded());

        // 重置后再次调用应重新 eval mainJs
        se.reset_main_js_state();
        assert!(!se.is_main_js_loaded());

        let _ = se.call_function("hello", &[("name", JsValue::String("b".to_string()))]);
        assert!(se.is_main_js_loaded());
        assert_eq!(counter.load(Ordering::SeqCst), 2); // eval 发生了两次
    }

    #[test]
    fn test_call_function_empty_main_js_error() {
        let config = JsSourceConfig::new("http://test.com".to_string(), "".to_string());
        let mut se = JsSourceEngine::new_stub(config);
        let result = se.call_function("foo", &[]);
        assert!(result.is_err());
    }

    #[test]
    fn test_normalize_result() {
        assert_eq!(JsSourceEngine::normalize_result("null"), None);
        assert_eq!(JsSourceEngine::normalize_result("undefined"), None);
        assert_eq!(JsSourceEngine::normalize_result("  "), None);
        assert_eq!(
            JsSourceEngine::normalize_result("hello"),
            Some("hello".to_string())
        );
        assert_eq!(
            JsSourceEngine::normalize_result(" 42 "),
            Some("42".to_string())
        );
    }

    /// P2-19 后续 #10（2026-09-23 上游同步改写）：`new_quickjs` 构造期 mainJs
    /// 顶层 `java.ajax` 必须携带**请求 URL 属域**的 cookie（上游语义：cookie
    /// 属于域名而非书源，读侧按请求 URL 属域取；P2-19「未归属不携带」收紧已
    /// 随用户裁决取消——书源 tag 绑定不再承载 cookie scope，保留供引擎分桶）。
    ///
    /// 机制：`new_quickjs` → `engine_cache::get_or_create("mainjs:{url}:{mainJs}")`
    /// → `init_engine` 在构造期 eval mainJs（顶层 `java.ajax` 即发起真实请求）。
    /// 请求目标为回环 cookie 记录服务器（P2-17 同款 std TcpListener 模式）；
    /// 回环域名键（127.0.0.1，IP 自键）与 network.rs 回环用例共享，须持
    /// `cookie_store::COOKIE_STORE_TEST_LOCK` 串行；缓存键含随机端口，用例间不串扰。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_p219_new_quickjs_construction_carries_request_domain_cookie() {
        use crate::host_api::cookie_store;
        use std::io::{Read, Write};
        use std::sync::Mutex;

        // 回环域名键（127.0.0.1）为进程级共享键，与 network.rs 回环用例串行
        let _lock = cookie_store::lock_cookie_store_test();

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

        // 书源上下文仍传入（引擎分桶 / 缓存键），cookie 取用不再按 tag
        const TAG: &str = "https://p219-mainjs.example.com/";
        // 上游同步：cookie 键 = 请求 URL 归一域名键（回环 IP 自键 127.0.0.1）
        let echo_url = format!("http://{addr}/echo");
        cookie_store::clear_cookies(&echo_url);
        cookie_store::set_cookie(&echo_url, "p219_mainjs_token", "mainjs-val-4a7b");

        // mainJs 顶层 `java.ajax`（入参为 JSON 字符串——java.ajax 桥接签名
        // 为 (options: String)，形态与 network.rs p219 用例一致）
        let main_js = format!(
            r#"java.ajax('{{"url":"{echo_url}"}}');
function search(q) {{ return q; }}"#
        );
        let config = JsSourceConfig::new(TAG.to_string(), main_js);
        let _engine = JsSourceEngine::new_quickjs(config).expect("new_quickjs 构造");

        let got = seen.lock().unwrap().clone();
        assert!(
            got.as_deref()
                .unwrap_or_default()
                .contains("p219_mainjs_token=mainjs-val-4a7b"),
            "构造期 mainJs 顶层 ajax 必须携带请求 URL 属域（127.0.0.1）cookie，实际 Cookie 头: {got:?}"
        );
        cookie_store::clear_cookies(&echo_url);
        drop(_lock);
    }
}
