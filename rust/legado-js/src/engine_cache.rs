//! 进程级 QuickJS 引擎缓存。
//!
//! 缓存引擎只用于非词法脚本；调用方通过 Mutex 串行化同一引擎的 eval。

#![cfg(feature = "quickjs")]

use crate::engine::{JsEngine, QuickJsEngine};
use crate::host_api::quickjs_impl::{JSOUP_BRIDGE_JS, RESPONSE_BRIDGE_JS};
use crate::sandbox::SandboxConfig;
use legado_core::{LegadoError, LegadoResult};
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, OnceLock};

// [体检 §三.14] 与 SEARCH_CONCURRENCY=32 对齐:多源跨源并发时避免 LRU 抖动
// (缓存外的源每次 eval 仍需重挂 587KB jsLib,批次 A 收益会被打折)
/// 进程级引擎缓存容量上限（LRU 驱逐阈值；pub 供 FFI 层回归测试断言不变式）
pub const MAX_ENTRIES: usize = 32;
type SharedEngine = Arc<Mutex<QuickJsEngine>>;
struct Entry {
    engine: SharedEngine,
    js_lib: String,
    setup_script: String,
    main_js: String,
    /// 构建时 mainJs eval 是否成功（None = 无 mainJs）；
    /// 失败时调用方可选择带 bindings 重评（旧路径语义自洽）。
    main_js_ok: Option<bool>,
}
struct Store {
    entries: HashMap<String, Entry>,
    order: VecDeque<String>,
}

static STORE: OnceLock<Mutex<Store>> = OnceLock::new();
fn store() -> &'static Mutex<Store> {
    STORE.get_or_init(|| {
        Mutex::new(Store {
            entries: HashMap::new(),
            order: VecDeque::new(),
        })
    })
}

fn init_engine(
    key: &str,
    js_lib: &str,
    setup_script: &str,
    main_js: &str,
) -> LegadoResult<(SharedEngine, Option<bool>)> {
    let engine = QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )?;
    let mut main_js_ok: Option<bool> = None;
    for (name, code) in [
        ("jsLib", js_lib),
        ("setup", setup_script),
        ("Response 桥", RESPONSE_BRIDGE_JS),
        ("Jsoup 桥", JSOUP_BRIDGE_JS),
        ("mainJs", main_js),
    ] {
        if code.is_empty() {
            continue;
        }
        match engine.eval(code) {
            Ok(_) => {
                if name == "mainJs" {
                    main_js_ok = Some(true);
                }
            }
            Err(first_err) => {
                // 区分语法错误与运行时错误：仅对语法错误尝试 Rhino 宽容语法归一化后重试一次
                // （对齐原版 corejs-Rhino 的宽松解析，如 B 站 jsLib 的 let 参数影子重声明、
                // data..item_null 双点笔误）；运行时错误按原样降级（原版 evaluateJsLib
                // 无 catch，语义一致）。
                let mut recovered = false;
                if engine.check_syntax(code).is_err() {
                    let (normalized, changed) = crate::jslib_normalize::normalize(code);
                    if changed {
                        match engine.eval(&normalized) {
                            Ok(_) => {
                                eprintln!(
                                    "[legado-js] 缓存引擎 {} {} 经 Rhino 宽容语法归一化后加载成功（原错误: {}）",
                                    key, name, first_err
                                );
                                recovered = true;
                            }
                            Err(e2) => eprintln!(
                                "[legado-js] 缓存引擎 {} {} 归一化后仍失败（降级继续）: {}",
                                key, name, e2
                            ),
                        }
                    }
                }
                if recovered {
                    if name == "mainJs" {
                        main_js_ok = Some(true);
                    }
                } else {
                    eprintln!(
                        "[legado-js] 缓存引擎 {} {} 加载失败（降级继续）: {}",
                        key, name, first_err
                    );
                    if name == "mainJs" {
                        main_js_ok = Some(false);
                    }
                }
            }
        }
    }
    Ok((Arc::new(Mutex::new(engine)), main_js_ok))
}

/// 获取带初始化上下文的缓存引擎；jsLib/setup 变化会重建对应条目。
pub fn get_or_create(
    key: &str,
    js_lib: Option<&str>,
    setup_script: Option<&str>,
    main_js: Option<&str>,
) -> LegadoResult<(SharedEngine, Option<bool>)> {
    let lib = js_lib.unwrap_or("");
    let setup = setup_script.unwrap_or("");
    let main = main_js.unwrap_or("");
    let mut guard = store()
        .lock()
        .map_err(|_| LegadoError::JsEngine("缓存锁中毒".into()))?;
    let same = guard
        .entries
        .get(key)
        .map(|e| e.js_lib == lib && e.setup_script == setup && e.main_js == main)
        .unwrap_or(false);
    if same {
        let entry = guard.entries.get(key).unwrap();
        let engine = entry.engine.clone();
        let main_ok = entry.main_js_ok;
        guard.order.retain(|k| k != key);
        guard.order.push_back(key.to_string());
        return Ok((engine, main_ok));
    }
    guard.entries.remove(key);
    guard.order.retain(|k| k != key);
    let (engine, main_ok) = init_engine(key, lib, setup, main)?;
    guard.entries.insert(
        key.to_string(),
        Entry {
            engine: engine.clone(),
            js_lib: lib.to_string(),
            setup_script: setup.to_string(),
            main_js: main.to_string(),
            main_js_ok: main_ok,
        },
    );
    guard.order.push_back(key.to_string());
    while guard.entries.len() > MAX_ENTRIES {
        if let Some(old) = guard.order.pop_front() {
            guard.entries.remove(&old);
        }
    }
    Ok((engine, main_ok))
}

/// 测试串行锁：进程级缓存被同一二进制的多个测试共享，
/// 凡调用 [clear_for_tests]/[len_for_tests] 的测试必须先持此锁，防止并发清空串扰。
pub static TEST_LOCK: Mutex<()> = Mutex::new(());

/// 清空缓存，供 FFI 回归测试隔离进程级状态。
pub fn clear_for_tests() {
    let mut guard = store().lock().unwrap();
    guard.entries.clear();
    guard.order.clear();
}

/// 返回当前缓存条目数，供回归测试确认 LRU 上限。
pub fn len_for_tests() -> usize {
    store().lock().unwrap().entries.len()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lru_never_exceeds_max() {
        let _guard = TEST_LOCK.lock().unwrap();
        clear_for_tests();
        // 插入量须超过上限才会触发 LRU 逐出（MAX_ENTRIES 8→32 后原 10 条不再越界）
        for i in 0..(MAX_ENTRIES + 2) {
            let _ = get_or_create(&format!("cache-test-{i}"), None, None, None).unwrap();
        }
        assert_eq!(len_for_tests(), MAX_ENTRIES);
    }

    #[test]
    fn changing_initialization_scripts_rebuilds_entry() {
        let _guard = TEST_LOCK.lock().unwrap();
        clear_for_tests();
        let (first, _) = get_or_create(
            "invalidate",
            Some("function marker(){ return 1; }"),
            None,
            None,
        )
        .unwrap();
        assert_eq!(first.lock().unwrap().eval("marker()").unwrap(), "1");
        let (second, _) = get_or_create(
            "invalidate",
            Some("function marker(){ return 2; }"),
            None,
            None,
        )
        .unwrap();
        assert_eq!(second.lock().unwrap().eval("marker()").unwrap(), "2");
    }
}
