//! QuickJS 执行器适配器（P5 下沉：原 `legado-ffi/src/js_executor.rs` 的
//! `quickjs_impl` 模块整体随迁）
//!
//! 在 legado-js 内把 QuickJS 引擎（[`crate::QuickJsEngine`] + 引擎缓存
//! [`crate::engine_cache`]）适配为 legado-parser 期望的
//! [`legado_parser::JsExecutor`]，供规则解析链路（ffi 侧经
//! `legado_ffi::js_executor::QuickJsExecutor` re-export 使用）与 loginCheckJs
//! 内核（本 crate `login_check`）共用同一实现，消除双副本手工同步。
//!
//! 设计要点：
//! - 持有所属 `source_tag` 与书源 jsLib；`execute_js` 时**每次创建独立
//!   新引擎**执行（对齐原版 Rhino 每次 evalJS 新作用域，规避书源规则顶层
//!   const/let 声明在引擎复用下的 redeclaration）；进程级引擎缓存仅服务
//!   非词法脚本，顶层声明触发重声明错误时登记并回退一次性新引擎。
//! - 实现 `Send + Sync`，满足 `Arc<dyn JsExecutor>`。

use legado_parser::JsExecutor;

/// QuickJS 执行器适配器
///
/// 持有所属 `source_tag` 与书源 jsLib；`execute_js` 时**每次创建
/// 独立新引擎**执行（对齐原版 Rhino 每次 evalJS 新作用域，规避
/// 书源规则顶层 const/let 声明在引擎复用下的 redeclaration）。
/// 实现 `Send + Sync`，满足 `Arc<dyn JsExecutor>`。
pub struct QuickJsExecutor {
    source_tag: String,
    /// 书源 jsLib（共享库代码，执行前先加载，对齐原版每次 eval 前注入）
    js_lib: Option<String>,
    /// 书源上下文 setup 脚本（source/cookie/__mountBookSourceApi 等，
    /// 供 URL 模板 {{js}} 里 jsLib 函数 `this.source`/`this.cookie`
    /// 访问）— 发现页修复（书山聚合书籍 URL session 缺失）
    setup_script: Option<String>,
}

impl QuickJsExecutor {
    /// 以指定 `source_tag` 创建执行器
    pub fn new(source_tag: &str) -> Self {
        Self {
            source_tag: source_tag.to_string(),
            js_lib: None,
            setup_script: None,
        }
    }

    /// 携带书源 jsLib 创建执行器
    ///
    /// [UI-fix 2026-08-10 | Reasonix] yckceo 书源（漫画/聚合源）模板
    /// 引用 jsLib 定义（Reload/getHosts 等），不注入则 URL 构建失败
    pub fn with_js_lib(mut self, js_lib: Option<String>) -> Self {
        self.js_lib = js_lib;
        self
    }

    /// 携带书源上下文 setup 脚本（source/cookie 绑定 + BookSource 方法）
    pub fn with_setup_script(mut self, setup_script: Option<String>) -> Self {
        self.setup_script = setup_script;
        self
    }
}

impl JsExecutor for QuickJsExecutor {
    fn execute_js(&self, js_code: &str) -> Result<String, String> {
        use std::collections::hash_map::DefaultHasher;
        use std::hash::{Hash, Hasher};
        use std::sync::{Mutex, OnceLock};
        static LEXICAL: OnceLock<Mutex<std::collections::HashSet<u64>>> = OnceLock::new();
        let hash = {
            let mut h = DefaultHasher::new();
            js_code.hash(&mut h);
            h.finish()
        };
        let lexical = LEXICAL.get_or_init(|| Mutex::new(std::collections::HashSet::new()));
        let is_lexical = lexical.lock().map(|s| s.contains(&hash)).unwrap_or(false);
        let run_fresh = || -> Result<String, String> {
            let engine = crate::QuickJsEngine::new(
                crate::sandbox::SandboxConfig::default()
                    .with_allow_script_run(true)
                    .with_memory_limit(64 * 1024 * 1024),
            )
            .map_err(|e| format!("JS 引擎创建失败: {e}"))?;
            crate::host_api::current_source::with_current_source_tag(&self.source_tag, || {
                if let Some(lib) = &self.js_lib {
                    // cap 3（URL 映射 jsLib）：先探测 URL 映射形态（全字符串值
                    // 的 JSON 对象）→ 经加载器解析（共享客户端拉取 + 进程缓存 +
                    // 逐条降级台账登记），eval 拼接脚本；非 URL 映射形态照旧
                    // 走原始 eval 级联
                    let ledger_tag = format!("executor:{}", self.source_tag);
                    let is_url_map =
                        crate::host_api::jslib_loader::parse_js_lib_url_map(lib).is_some();
                    let url_map_script = crate::host_api::jslib_loader::resolve_js_lib_url_map(
                        lib,
                        &ledger_tag,
                        &crate::host_api::jslib_loader::default_js_lib_fetcher,
                    );
                    if is_url_map {
                        // 逐条拉取失败已在加载器内记台账（降级跳过该条，
                        // 仅依赖该 jsLib 的规则受影响）；全失败时脚本为 None，
                        // 直接跳过 eval（原始 JSON 非合法 JS，不回退原始级联）
                        if let Some(script) = &url_map_script {
                            if let Err(e) = crate::JsEngine::eval(&engine, script) {
                                // 队列④：登记台账后**带原因上抛**（对齐原版
                                // SharedJsScope.evaluateJsLib 失败直接抛，
                                // SharedJsScope.kt:251/:258）。此前静默降级会让
                                // 失败推迟到主脚本引用点，报出误导性
                                // `source is not defined`（iOS 实机 1/2 号根因链）
                                crate::host_api::capability_ledger::record_jslib_load_failure(
                                    &ledger_tag,
                                    &e.to_string(),
                                );
                                return Err(format!("jsLib 求值失败: {e}"));
                            }
                        }
                    } else if let Err(e) = crate::JsEngine::eval(&engine, lib) {
                        // 仅对语法错误尝试 Rhino 宽容语法归一化后重试一次（与 engine_cache
                        // 缓存路径一致；对齐原版 corejs-Rhino 宽松解析——B 站 jsLib 的
                        // let 参数影子重声明、data..item_null 双点笔误等）。
                        // 归一化仍失败 / 运行时错误：登记台账后带原因上抛（不再静默降级）
                        let recovered = if engine.check_syntax(lib).is_err() {
                            let (normalized, changed) = crate::jslib_normalize::normalize(lib);
                            if changed && crate::JsEngine::eval(&engine, &normalized).is_ok() {
                                eprintln!(
                                        "[legado-js] 书源 {} jsLib 经 Rhino 宽容语法归一化后加载成功（原错误: {e}）",
                                        self.source_tag
                                    );
                                true
                            } else {
                                false
                            }
                        } else {
                            false
                        };
                        if !recovered {
                            eprintln!(
                                "[legado-js] 书源 {} jsLib 加载失败（带原因上抛）: {e}",
                                self.source_tag
                            );
                            // 队列④：jsLib 加载失败登记能力受限台账
                            // （键与缓存路径一致：executor:<source_tag>）
                            crate::host_api::capability_ledger::record_jslib_load_failure(
                                &ledger_tag,
                                &e.to_string(),
                            );
                            return Err(format!("jsLib 求值失败: {e}"));
                        }
                    }
                }
                if let Some(setup) = &self.setup_script {
                    if let Err(e) = crate::JsEngine::eval(&engine, setup) {
                        eprintln!(
                            "[legado-js] 书源 {} setup 加载失败（降级继续）: {e}",
                            self.source_tag
                        );
                    }
                }
                if let Err(e) = crate::JsEngine::eval(
                    &engine,
                    crate::host_api::quickjs_impl::RESPONSE_BRIDGE_JS,
                ) {
                    eprintln!(
                        "[legado-js] 书源 {} Response 桥重新注入失败（降级继续）: {e}",
                        self.source_tag
                    );
                }
                if let Err(e) =
                    crate::JsEngine::eval(&engine, crate::host_api::quickjs_impl::JSOUP_BRIDGE_JS)
                {
                    eprintln!(
                        "[legado-js] 书源 {} Jsoup 桥重新注入失败（降级继续）: {e}",
                        self.source_tag
                    );
                }
                crate::JsEngine::eval(&engine, js_code).map_err(|e| e.to_string())
            })
        };
        // URL 映射形态 jsLib（值为 URL 的 JSON 对象）一律走 fresh 路径：
        // 缓存路径 `engine_cache::init_engine` 对 jsLib 原样 eval，而映射 JSON
        // 不是合法 JS，会误报「jsLib 求值失败」——B1 硬上抛后该误报会被放大成
        // 整源失败。上游语义是逐条拉取 URL 映射（SharedJsScope.parseJsLibMap），
        // 故映射形态必须交给 fresh 路径的加载器（jslib_loader：拉取 + 进程缓存
        // + 逐条降级台账）。非映射形态仍走缓存路径。
        let js_lib_is_url_map = self
            .js_lib
            .as_deref()
            .map(|lib| crate::host_api::jslib_loader::parse_js_lib_url_map(lib).is_some())
            .unwrap_or(false);
        if is_lexical || js_lib_is_url_map {
            return run_fresh();
        }
        let key = format!("executor:{}", self.source_tag);
        let (cached, _, js_lib_ok) = crate::engine_cache::get_or_create(
            &key,
            self.js_lib.as_deref(),
            self.setup_script.as_deref(),
            None,
        )
        .map_err(|e| e.to_string())?;
        // 缓存引擎构造期 jsLib 求值失败 → 带原因上抛（与 fresh 路径同一语义；
        // 原版 SharedJsScope.evaluateJsLib 失败直接抛）。原因取台账最后错误摘要
        // （engine_cache::init_engine 已登记 `record_jslib_load_failure`）。
        if js_lib_ok == Some(false) {
            let reason = crate::host_api::capability_ledger::last_jslib_error(&key)
                .filter(|s| !s.trim().is_empty())
                .unwrap_or_else(|| "原因未记录（见 capability_ledger）".to_string());
            return Err(format!("jsLib 求值失败: {reason}"));
        }
        let result =
            crate::host_api::current_source::with_current_source_tag(&self.source_tag, || {
                cached
                    .lock()
                    .map_err(|_| "JS 引擎锁中毒".to_string())
                    .and_then(|engine| {
                        crate::JsEngine::eval(&*engine, js_code).map_err(|e| e.to_string())
                    })
            });
        match result {
            Err(e) if e.contains("redeclaration") || e.contains("already declared") => {
                if let Ok(mut set) = lexical.lock() {
                    set.insert(hash);
                }
                run_fresh()
            }
            other => other,
        }
    }

    /// 带 `result` 绑定的执行（上游 AnalyzeUrl.evalJS `bindings["result"]`
    /// 口径）：URL 选项 `{"js": ...}` / bodyJs 在 `result` 中拿到当前 URL。
    /// 非严格 eval 下裸 `result` 标识符经 globalThis 解析，前缀注入等价。
    fn execute_js_with_result(&self, js_code: &str, result_json: &str) -> Result<String, String> {
        let wrapped = format!("globalThis.result = {result_json};\n{js_code}");
        self.execute_js(&wrapped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 同一 executor 可连续执行多条脚本（每次仍为新引擎）。
    #[test]
    fn test_quickjs_executor_reuse() {
        let executor = QuickJsExecutor::new("reuse_tag");
        let r1 = executor.execute_js("10 * 10").unwrap();
        let r2 = executor.execute_js("100 + 1").unwrap();
        assert_eq!(r1, "100");
        assert_eq!(r2, "101");
    }

    #[test]
    fn test_js_lib_persists_across_independent_executes() {
        let _guard = crate::engine_cache::TEST_LOCK.lock().unwrap();
        crate::engine_cache::clear_for_tests();
        let lib = Some("function persisted(){ return 'ok'; }".to_string());
        let first = QuickJsExecutor::new("persist_tag").with_js_lib(lib.clone());
        let second = QuickJsExecutor::new("persist_tag").with_js_lib(lib);
        assert_eq!(first.execute_js("persisted()").unwrap(), "ok");
        assert_eq!(second.execute_js("persisted()").unwrap(), "ok");
    }

    /// [P5 迁移] 顶层 const 重声明 → 回退每次新建引擎（词法脚本路径）。
    #[test]
    fn test_redeclaration_falls_back_to_fresh_engine() {
        let _guard = crate::engine_cache::TEST_LOCK.lock().unwrap();
        crate::engine_cache::clear_for_tests();
        let executor = QuickJsExecutor::new("redeclaration_tag");
        let script = "const regression_value = 41; regression_value + 1";
        assert_eq!(executor.execute_js(script).unwrap(), "42");
        assert_eq!(executor.execute_js(script).unwrap(), "42");
    }

    /// jsLib 求值失败 → 带原因上抛（对齐原版 SharedJsScope.evaluateJsLib
    /// 失败直接抛，SharedJsScope.kt:251/:258），不得静默降级后由主脚本引用点
    /// 报误导性 `xxx is not defined`（iOS 实机 1/2 号 source 失真的根因链）。
    /// 契约与红绿证据由集成测试 `tests/jslib_failure_visible.rs` 锁定
    /// （覆盖缓存路径 / fresh 路径 / 不使用库函数场景）。
    #[test]
    fn test_valid_jslib_still_loads_and_runs() {
        let _guard = crate::engine_cache::TEST_LOCK.lock().unwrap();
        crate::engine_cache::clear_for_tests();
        let executor = QuickJsExecutor::new("jslib_ok_tag")
            .with_js_lib(Some("function marker(){ return 'ok'; }".to_string()));
        assert_eq!(executor.execute_js("marker()").unwrap(), "ok");
    }

    #[test]
    fn test_completion_value_is_preserved_on_fast_path() {
        let _guard = crate::engine_cache::TEST_LOCK.lock().unwrap();
        crate::engine_cache::clear_for_tests();
        let executor = QuickJsExecutor::new("completion_tag");
        assert_eq!(executor.execute_js("1 + 2").unwrap(), "3");
        assert_eq!(executor.execute_js("var x = 7; result = x").unwrap(), "7");
    }

    #[test]
    fn test_cache_per_source_isolation_and_capacity() {
        let _guard = crate::engine_cache::TEST_LOCK.lock().unwrap();
        crate::engine_cache::clear_for_tests();
        for i in 0..8 {
            let tag = format!("lru_tag_{i}");
            let lib = format!("function marker(){{ return {i}; }}");
            let executor = QuickJsExecutor::new(&tag).with_js_lib(Some(lib));
            assert_eq!(executor.execute_js("marker()").unwrap(), i.to_string());
        }
        let newest = QuickJsExecutor::new("lru_tag_7")
            .with_js_lib(Some("function marker(){ return 7; }".into()));
        assert_eq!(newest.execute_js("marker()").unwrap(), "7");
        let oldest = QuickJsExecutor::new("lru_tag_0")
            .with_js_lib(Some("function marker(){ return 0; }".into()));
        assert_eq!(oldest.execute_js("marker()").unwrap(), "0");
        // 缓存容量不变式：并行套件中其他测试（search/analyzer 的 @js: 执行）会
        // 不持 TEST_LOCK 合法写入同一进程级缓存，故只能断言上限而非精确计数；
        // 驱逐语义（LRU 最旧淘汰）由 legado-js engine_cache 单测锁定。
        assert!(crate::engine_cache::len_for_tests() <= crate::engine_cache::MAX_ENTRIES);
    }
}
