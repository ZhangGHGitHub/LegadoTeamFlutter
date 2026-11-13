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
use std::time::Duration;

// [体检 §三.14] 与搜索缺省并发 16（有效上限 32）对齐（config:threadCount，批9b-2）:
// 多源跨源并发时避免 LRU 抖动(缓存外的源每次 eval 仍需重挂 587KB jsLib,
// 批次 A 收益会被打折)
/// 进程级引擎缓存容量上限（LRU 驱逐阈值；pub 供 FFI 层回归测试断言不变式）
pub const MAX_ENTRIES: usize = 32;
type SharedEngine = Arc<Mutex<QuickJsEngine>>;
/// 缓存引擎句柄 +（构建时 mainJs eval 状态, 构建时 jsLib eval 状态）
type CachedEngine = (SharedEngine, Option<bool>, Option<bool>);
struct Entry {
    engine: SharedEngine,
    js_lib: String,
    setup_script: String,
    main_js: String,
    /// 单次求值中断预算（批21a：RSS WebView 宿主桥需 30s，宿主网络调用
    /// 可能长时间阻塞在原生函数内；`None` = 沿用 `SandboxConfig::default`）。
    timeout: Option<Duration>,
    /// 构建时 mainJs eval 是否成功（None = 无 mainJs）；
    /// 失败时调用方可选择带 bindings 重评（旧路径语义自洽）。
    main_js_ok: Option<bool>,
    /// 构建时 jsLib eval 是否成功（None = 无 jsLib）；
    /// 失败时台账已登记（`record_jslib_load_failure`），调用方据此
    /// **带原因上抛**（对齐原版 `SharedJsScope.evaluateJsLib` 失败直接抛，
    /// SharedJsScope.kt:251/:258；`validate_js_lib` / `QuickJsExecutor` 两处）。
    js_lib_ok: Option<bool>,
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
    timeout: Option<Duration>,
) -> LegadoResult<CachedEngine> {
    let mut config = SandboxConfig::default()
        .with_allow_script_run(true)
        .with_memory_limit(64 * 1024 * 1024);
    if let Some(t) = timeout {
        config = config.with_timeout(t);
    }
    let engine = QuickJsEngine::new(config)?;
    let mut main_js_ok: Option<bool> = None;
    let mut js_lib_ok: Option<bool> = None;
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
                if name == "jsLib" {
                    js_lib_ok = Some(true);
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
                    if name == "jsLib" {
                        js_lib_ok = Some(true);
                    }
                } else {
                    eprintln!(
                        "[legado-js] 缓存引擎 {} {} 加载失败（降级继续）: {}",
                        key, name, first_err
                    );
                    if name == "mainJs" {
                        main_js_ok = Some(false);
                    }
                    if name == "jsLib" {
                        js_lib_ok = Some(false);
                        // 队列④：jsLib 加载失败登记台账（进程可查询），
                        // 调用方据此上抛「书源脚本能力不可用」
                        crate::host_api::capability_ledger::record_jslib_load_failure(
                            key,
                            &first_err.to_string(),
                        );
                    }
                }
            }
        }
    }
    Ok((Arc::new(Mutex::new(engine)), main_js_ok, js_lib_ok))
}

/// 获取带初始化上下文的缓存引擎；jsLib/setup 变化会重建对应条目。
pub fn get_or_create(
    key: &str,
    js_lib: Option<&str>,
    setup_script: Option<&str>,
    main_js: Option<&str>,
) -> LegadoResult<CachedEngine> {
    get_or_create_with_timeout(key, js_lib, setup_script, main_js, None)
}

/// 获取带初始化上下文与**单次求值中断预算**的缓存引擎（批21a，加法式）
///
/// 与 [`get_or_create`] 的唯一差别：`timeout` 非空时覆盖
/// `SandboxConfig::default` 的 5s 预算。RSS 阅读 WebView 宿主桥的
/// `ajaxAwait` 等调用可能长时间阻塞在原生网络函数内（中断处理器只在
/// 字节码边界检查，原生调用期间不生效），5s 预算会在返回后立刻中断，
/// 故宿主桥按契约使用 30s。
///
/// 缓存键比较包含 `timeout`：同一 key 换预算会重建条目（与其他初始化
/// 脚本变化同语义）；`None` 与既有调用方逐字节等价。
///
/// # 锁纪律（P2-6）
///
/// `init_engine` 会 eval 数百 KB jsLib，jsLib/setup 顶层可能出现
/// `java.ajax` 等宿主调用并阻塞到网络超时；该构建过程**不得**在全局缓存
/// 锁内执行，否则一个源的首次建引擎会拖住所有源（含已缓存 key 的快路径）。
/// 因此采用三段式（同 `host_api::network::shared_client` 的双检模式）：
///
/// 1. 短锁查表：命中且初始化上下文一致 → 克隆返回；
/// 2. 锁外构建：未命中/上下文变化 → 释放锁后执行 `init_engine`；
/// 3. 写锁复查：并发构建同一 key 时先装入者胜出，后到者丢弃本次构建
///    结果并返回既有条目（两者语义等价，避免相互覆盖造成抖动）。
pub fn get_or_create_with_timeout(
    key: &str,
    js_lib: Option<&str>,
    setup_script: Option<&str>,
    main_js: Option<&str>,
    timeout: Option<Duration>,
) -> LegadoResult<CachedEngine> {
    let lib = js_lib.unwrap_or("");
    let setup = setup_script.unwrap_or("");
    let main = main_js.unwrap_or("");
    // 1. 快路径：短锁查表（无慢操作）
    if let Some(hit) = lookup_cached(key, lib, setup, main, timeout)? {
        return Ok(hit);
    }
    // 2. 慢路径：锁外构建（可能阻塞在 jsLib 顶层宿主调用上）
    let (engine, main_ok, lib_ok) = init_engine(key, lib, setup, main, timeout)?;
    // 3. 写锁复查并装入
    let mut guard = store()
        .lock()
        .map_err(|_| LegadoError::JsEngine("缓存锁中毒".into()))?;
    // 并发首次构建同一 key：他线程已装入且上下文一致 → 丢弃自身构建结果
    if let Some(entry) = guard.entries.get(key) {
        if entry.matches(lib, setup, main, timeout) {
            let result = (entry.engine.clone(), entry.main_js_ok, entry.js_lib_ok);
            touch_lru(&mut guard, key);
            return Ok(result);
        }
    }
    guard.entries.insert(
        key.to_string(),
        Entry {
            engine: engine.clone(),
            js_lib: lib.to_string(),
            setup_script: setup.to_string(),
            main_js: main.to_string(),
            timeout,
            main_js_ok: main_ok,
            js_lib_ok: lib_ok,
        },
    );
    touch_lru(&mut guard, key);
    while guard.entries.len() > MAX_ENTRIES {
        if let Some(old) = guard.order.pop_front() {
            guard.entries.remove(&old);
        }
    }
    Ok((engine, main_ok, lib_ok))
}

impl Entry {
    /// 初始化上下文是否与请求一致（缓存键之外的比较维度）
    fn matches(
        &self,
        js_lib: &str,
        setup_script: &str,
        main_js: &str,
        timeout: Option<Duration>,
    ) -> bool {
        self.js_lib == js_lib
            && self.setup_script == setup_script
            && self.main_js == main_js
            && self.timeout == timeout
    }
}

/// 快路径查表：命中且上下文一致时克隆引擎并更新 LRU 次序
fn lookup_cached(
    key: &str,
    js_lib: &str,
    setup_script: &str,
    main_js: &str,
    timeout: Option<Duration>,
) -> LegadoResult<Option<CachedEngine>> {
    let mut guard = store()
        .lock()
        .map_err(|_| LegadoError::JsEngine("缓存锁中毒".into()))?;
    let hit = guard
        .entries
        .get(key)
        .filter(|e| e.matches(js_lib, setup_script, main_js, timeout))
        .map(|e| (e.engine.clone(), e.main_js_ok, e.js_lib_ok));
    if hit.is_some() {
        touch_lru(&mut guard, key);
    }
    Ok(hit)
}

/// 把 key 移到 LRU 队尾（最近使用）
fn touch_lru(guard: &mut Store, key: &str) {
    guard.order.retain(|k| k != key);
    guard.order.push_back(key.to_string());
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
        let (first, _, _) = get_or_create(
            "invalidate",
            Some("function marker(){ return 1; }"),
            None,
            None,
        )
        .unwrap();
        assert_eq!(first.lock().unwrap().eval("marker()").unwrap(), "1");
        let (second, _, _) = get_or_create(
            "invalidate",
            Some("function marker(){ return 2; }"),
            None,
            None,
        )
        .unwrap();
        assert_eq!(second.lock().unwrap().eval("marker()").unwrap(), "2");
    }

    /// P2-6：慢构建（jsLib 顶层 `java.ajax` 阻塞在原生网络调用）不得阻塞
    /// 已缓存 key 的快路径。
    ///
    /// 改前 `get_or_create_with_timeout` 在持有全局缓存 Mutex 期间执行
    /// `init_engine`，本用例的快路径查询会被慢构建拖住（红）；改为
    /// 「快路径短锁 → 锁外构建 → 写锁复查」后快路径应立即返回（绿）。
    #[test]
    fn cached_key_fast_path_not_blocked_by_slow_build() {
        use std::io::{Read, Write};
        use std::time::Instant;

        let _guard = TEST_LOCK.lock().unwrap();
        clear_for_tests();

        // 预热快路径 key（无初始化脚本，构建瞬时）
        let (warm, _, _) = get_or_create("fast-key", None, None, None).unwrap();

        // 最小回环服务：读到请求后延迟 1200ms 再回响应，拖住慢构建。
        // 非阻塞 accept + 5s 上限，保证构建未发起请求时测试线程不会永久挂起。
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                match listener.accept() {
                    Ok((mut sock, _)) => {
                        let mut buf = [0u8; 1024];
                        let _ = sock.read(&mut buf);
                        std::thread::sleep(Duration::from_millis(1200));
                        let _ = sock.write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                        );
                        return;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        if Instant::now() >= deadline {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(_) => return,
                }
            }
        });

        let slow_lib = format!("java.ajax('http://{addr}/slow');");
        let slow_start = Instant::now();
        let builder = std::thread::spawn(move || {
            let _ = get_or_create("slow-build-key", Some(&slow_lib), None, None);
            slow_start.elapsed()
        });
        // 等慢构建进入 init_engine（构建在锁外，此时全局锁已释放）
        std::thread::sleep(Duration::from_millis(150));

        let probe_start = Instant::now();
        let (fast, _, _) = get_or_create("fast-key", None, None, None).unwrap();
        let fast_elapsed = probe_start.elapsed();

        let slow_elapsed = builder.join().unwrap();
        let _ = server.join();

        assert!(Arc::ptr_eq(&fast, &warm), "快路径必须命中既有引擎");
        assert!(
            slow_elapsed >= Duration::from_millis(1000),
            "慢构建未被拖住（{slow_elapsed:?}），测试前提不成立"
        );
        assert!(
            fast_elapsed < Duration::from_millis(500),
            "已缓存 key 的快路径被慢构建阻塞：{fast_elapsed:?}（慢构建 {slow_elapsed:?}）"
        );
    }

    /// 批21a：单次求值预算参与缓存键比较——同预算复用同一引擎，
    /// 换预算（None ↔ 30s）必须重建，既有 `get_or_create` 语义逐字不变。
    #[test]
    fn timeout_participates_in_cache_key() {
        let _guard = TEST_LOCK.lock().unwrap();
        clear_for_tests();
        let (a, _, _) = get_or_create_with_timeout(
            "timeout-key",
            None,
            None,
            None,
            Some(Duration::from_secs(30)),
        )
        .unwrap();
        let (b, _, _) = get_or_create_with_timeout(
            "timeout-key",
            None,
            None,
            None,
            Some(Duration::from_secs(30)),
        )
        .unwrap();
        assert!(Arc::ptr_eq(&a, &b), "同预算必须复用同一引擎");
        assert_eq!(a.lock().unwrap().eval("1 + 1").unwrap(), "2");

        let (c, _, _) = get_or_create_with_timeout("timeout-key", None, None, None, None).unwrap();
        assert!(!Arc::ptr_eq(&a, &c), "换预算必须重建引擎");
        assert_eq!(c.lock().unwrap().eval("2 + 2").unwrap(), "4");
    }
}
