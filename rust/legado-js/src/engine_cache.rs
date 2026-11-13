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

/// per-key 构建闸门表（P2-1 single-flight）
///
/// 只保存「构建进行中/仍有等待者」的 key。同 key 的未命中构建经对应
/// `Mutex<()>` 串行化，异 key 使用不同闸门，构建仍在全局缓存锁外**并行**
/// 执行。表项清理见 [`FlightGuard::drop`]。
type FlightGate = Arc<Mutex<()>>;
static FLIGHTS: OnceLock<Mutex<HashMap<String, FlightGate>>> = OnceLock::new();

fn flights() -> &'static Mutex<HashMap<String, FlightGate>> {
    FLIGHTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn lock_flights() -> std::sync::MutexGuard<'static, HashMap<String, FlightGate>> {
    // 闸门表只做串行化簿记，不承载引擎状态；中毒（表操作中 panic）时
    // 取回内部表可能仍可用，继续服务比整表瘫痪更安全。
    flights()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 取得 key 对应的构建闸门（不存在则创建）
fn acquire_flight(key: &str) -> FlightGate {
    let mut map = lock_flights();
    map.entry(key.to_string())
        .or_insert_with(|| Arc::new(Mutex::new(())))
        .clone()
}

/// single-flight 闸门守卫：构建结束（含 panic 展开）时清理表项。
///
/// 清理策略：**仅当无其他等待者时移除**——`Arc::strong_count == 2`
/// （表内一份 + 本守卫一份）。等待者仍持有 `Arc` 时保留表项，最后由
/// 最后一个持有者退出时移除；互斥量由 `Arc` 保证存活到该时刻，等待者
/// 不会在阻塞中途被换锁。清理在表锁内完成，期间不会有新等待者克隆，
/// 因此不会误删正在被等待的闸门。
struct FlightGuard {
    key: String,
    gate: FlightGate,
}

impl FlightGuard {
    fn new(key: &str) -> Self {
        Self {
            key: key.to_string(),
            gate: acquire_flight(key),
        }
    }

    fn lock(&self) -> std::sync::LockResult<std::sync::MutexGuard<'_, ()>> {
        self.gate.lock()
    }
}

impl Drop for FlightGuard {
    fn drop(&mut self) {
        let mut map = lock_flights();
        if map
            .get(&self.key)
            .is_some_and(|gate| Arc::ptr_eq(gate, &self.gate))
            && Arc::strong_count(&self.gate) <= 2
        {
            map.remove(&self.key);
        }
    }
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
/// # 锁纪律（P2-6）与同 key single-flight（P2-1）
///
/// `init_engine` 会 eval 数百 KB jsLib，jsLib/setup 顶层可能出现
/// `java.ajax` 等宿主调用并阻塞到网络超时；该构建过程**不得**在全局缓存
/// 锁内执行，否则一个源的首次建引擎会拖住所有源（含已缓存 key 的快路径）。
/// 因此采用三段式（同 `host_api::network::shared_client` 的双检模式）：
///
/// 1. 短锁查表：命中且初始化上下文一致 → 克隆返回；
/// 2. 锁外构建：未命中/上下文变化 → 释放锁后执行 `init_engine`；
/// 3. 写锁复查：先装入者胜出，后到者丢弃本次构建结果并返回既有条目。
///
/// 步骤 2 的「锁外构建」单独存在时，同 key 并发未命中会让每个线程各建一个
/// QuickJS Runtime、各 eval 一遍 jsLib，并**重复执行 jsLib/setup/mainJs 顶层
/// 的宿主副作用**（`java.ajax`、`setCookie`、`putVariable` 等）——结果虽然
/// 等价，远端请求/登录侧效应却会 N 倍放大。因此未命中构建按 key 加
/// [`FlightGuard`] 闸门：同 key 同时只有一个线程构建，等待者在闸门内复查
/// 缓存并复用先到者结果；异 key 闸门不同，构建并发度不受影响。
///
/// 注意：闸门只覆盖「构建」阶段。`init_engine` 返回后的写锁复查仍保留，
/// 用于兜住闸门表清理竞态（极端时序下两个线程可能持不同闸门），保证
/// 缓存条目仍是「先装入者胜出」。
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
    // 2. 同 key single-flight：只允许一个线程进入构建；其余线程在此等待
    //    （闸门只影响同一 key，异 key 互不阻塞）。守卫在作用域结束或 panic
    //    展开时清理表项。
    let flight = FlightGuard::new(key);
    let _gate = flight
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    // 等待期间先到者可能已完成装入：复查命中则直接复用，不重复构建。
    if let Some(hit) = lookup_cached(key, lib, setup, main, timeout)? {
        return Ok(hit);
    }
    // 3. 锁外构建（持 per-key 闸门，但不持全局缓存锁）
    let (engine, main_ok, lib_ok) = init_engine(key, lib, setup, main, timeout)?;
    // 4. 写锁复查并装入
    let mut guard = store()
        .lock()
        .map_err(|_| LegadoError::JsEngine("缓存锁中毒".into()))?;
    // 极端竞态（闸门表清理后新建闸门）下仍可能并发构建同一 key：
    // 上下文一致则复用先装入者，丢弃本次构建结果。
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

/// 使指定缓存条目失效（P3-1：锁中毒等引擎不可复用场景）。
///
/// 与 [`clear_for_tests`] 不同，本函数是生产 API：只移除单个 key，下次
/// [`get_or_create`] 会重建全新引擎；key 不存在时为空操作。已克隆出去的
/// `Arc` 不受影响（引用计数归零后自然释放），因此不会与正在使用该引擎的
/// 调用方产生悬垂引用。
pub fn invalidate(key: &str) {
    let mut guard = store()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    if guard.entries.remove(key).is_some() {
        guard.order.retain(|k| k != key);
    }
}

/// 测试串行锁：进程级缓存被同一二进制的多个测试共享，
/// 凡调用 [clear_for_tests]/[len_for_tests] 的测试必须先持此锁，防止并发清空串扰。
pub static TEST_LOCK: Mutex<()> = Mutex::new(());

/// 测试用：取得 [`TEST_LOCK`]，中毒时取回内部值复用。
///
/// 直接用 `lock().unwrap()` 会让任一用例的断言失败毒化锁，进而把同二进制
/// 其余用例级联成 `PoisonError`（批29 回修：慢构建用例假红一次即连带 7 条
/// 失败，真实断言被掩盖）。本 helper 保证单个用例 panic 只影响自身。
#[cfg(test)]
pub(crate) fn lock_test() -> std::sync::MutexGuard<'static, ()> {
    TEST_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 清空缓存，供 FFI 回归测试隔离进程级状态。
pub fn clear_for_tests() {
    let mut guard = store().lock().unwrap();
    guard.entries.clear();
    guard.order.clear();
    // 闸门表同样清空（测试隔离；进行中的构建各自持有 Arc，清理不中断其构建）
    lock_flights().clear();
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
        let _guard = lock_test();
        clear_for_tests();
        // 插入量须超过上限才会触发 LRU 逐出（MAX_ENTRIES 8→32 后原 10 条不再越界）
        for i in 0..(MAX_ENTRIES + 2) {
            let _ = get_or_create(&format!("cache-test-{i}"), None, None, None).unwrap();
        }
        assert_eq!(len_for_tests(), MAX_ENTRIES);
    }

    #[test]
    fn changing_initialization_scripts_rebuilds_entry() {
        let _guard = lock_test();
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
    ///
    /// P2-2（批29 审查）：同步点必须是「mock 收到慢构建请求」，而不是固定
    /// `sleep(150ms)`。后者在 CI 调度延迟下可能让探针先拿到缓存锁，旧实现
    /// 也快速返回 → 假绿。收到请求时：旧实现必然正持全局缓存锁（构建在锁内）
    /// → 探针必阻塞；新实现必然已释放全局锁（构建在锁外）→ 探针立即返回。
    ///
    /// 批29 回修：原断言 `fast_elapsed < 500ms` 是**绝对耗时**，并行跑多个
    /// 测试二进制（高 CPU 负载）时会假红；且 panic 时持 [`TEST_LOCK`] 毒化
    /// 锁 → 同二进制其余用例级联失败。现改为**相对先后**：以慢构建起点为
    /// 基准记录探针返回时刻 `slow_start.elapsed()`，要求探针在 mock 回响应
    /// 之前返回（mock 收到请求后延迟 3000ms 才回，阈值 2000ms 留 1000ms
    /// 余量吸收 CPU 竞争）。探针若真被慢构建阻塞，最早也要等 mock 响应之后
    /// 才能返回（`>= 3000ms`），仍会被稳定判红；`slow_elapsed >= 2500ms`
    /// 保留为「慢构建确实被拖住」的前提校验。
    #[test]
    fn cached_key_fast_path_not_blocked_by_slow_build() {
        use std::io::{Read, Write};
        use std::sync::mpsc;
        use std::time::Instant;

        let _guard = lock_test();
        clear_for_tests();

        // 预热快路径 key（无初始化脚本，构建瞬时）
        let (warm, _, _) = get_or_create("fast-key", None, None, None).unwrap();

        // 最小回环服务：读到请求后先通知测试线程（同步点），再延迟 3000ms
        // 回响应，拖住慢构建。非阻塞 accept + 5s 上限，保证构建未发起请求
        // 时测试线程不会永久挂起。
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let (req_tx, req_rx) = mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                match listener.accept() {
                    Ok((mut sock, _)) => {
                        let mut buf = [0u8; 1024];
                        let _ = sock.read(&mut buf);
                        // 慢构建已进入 init_engine 并发出宿主请求
                        let _ = req_tx.send(());
                        std::thread::sleep(Duration::from_millis(3000));
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
        // 以「mock 收到请求」为同步点（替代固定 sleep）：此刻旧实现必然
        // 持全局缓存锁，新实现必然已释放。
        req_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("慢构建未在 5s 内发起 jsLib 顶层请求，测试前提不成立");

        let probe_start = Instant::now();
        let (fast, _, _) = get_or_create("fast-key", None, None, None).unwrap();
        let probe_elapsed = probe_start.elapsed();
        // 相对慢构建起点的返回时刻：mock 收到请求后 3000ms 才回响应，探针
        // 若未被阻塞必远早于此（阈值 2000ms）返回。
        let probe_return_at = slow_start.elapsed();

        let slow_elapsed = builder.join().unwrap();
        let _ = server.join();

        assert!(Arc::ptr_eq(&fast, &warm), "快路径必须命中既有引擎");
        assert!(
            slow_elapsed >= Duration::from_millis(2500),
            "慢构建未被拖住（{slow_elapsed:?}），测试前提不成立"
        );
        assert!(
            probe_return_at < Duration::from_millis(2000),
            "已缓存 key 的快路径被慢构建阻塞：探针于慢构建起点后 {probe_return_at:?} 才返回\
             （mock 收请求后 3000ms 才回响应；探针自身耗时 {probe_elapsed:?}）"
        );
    }

    /// P2-1：同 key 并发未命中只构建一次（per-key single-flight）。
    ///
    /// 修复前：每个线程都完整执行 `init_engine`（各建 QuickJS Runtime、
    /// 各 eval jsLib、重复执行 jsLib 顶层宿主副作用），mock 收到 N 次请求；
    /// 修复后只有先到者构建，等待者在闸门内复查缓存复用其结果，mock 只
    /// 收到 1 次。计数用 mock 请求数（直接锁定「远端/登录副作用不重复」）。
    #[test]
    fn same_key_concurrent_misses_build_engine_once() {
        use std::io::{Read, Write};
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Barrier;

        const THREADS: usize = 4;

        let _guard = lock_test();
        clear_for_tests();

        // 慢响应 mock（每连接独立线程）：延迟 400ms 保证修复前所有线程都
        // 已完成快路径未命中并进入 init_engine，请求计数稳定为 N。
        let requests = Arc::new(AtomicUsize::new(0));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let requests_srv = Arc::clone(&requests);
        let (stop_tx, stop_rx) = std::sync::mpsc::channel::<()>();
        let server = std::thread::spawn(move || {
            listener.set_nonblocking(true).unwrap();
            loop {
                // 测试结束通知后退出，避免测试进程残留阻塞线程
                if stop_rx.try_recv().is_ok() {
                    return;
                }
                match listener.accept() {
                    Ok((mut sock, _)) => {
                        let requests_conn = Arc::clone(&requests_srv);
                        std::thread::spawn(move || {
                            let mut buf = [0u8; 1024];
                            let _ = sock.read(&mut buf);
                            requests_conn.fetch_add(1, Ordering::SeqCst);
                            std::thread::sleep(Duration::from_millis(400));
                            let _ = sock.write_all(
                                b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok",
                            );
                        });
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(_) => return,
                }
            }
        });

        let js_lib = format!("java.ajax('http://{addr}/slow');");
        let barrier = Arc::new(Barrier::new(THREADS));
        let handles: Vec<_> = (0..THREADS)
            .map(|_| {
                let js_lib = js_lib.clone();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    // Barrier：让所有线程同时越过快路径查表，放大并发未命中
                    barrier.wait();
                    get_or_create("single-flight-key", Some(&js_lib), None, None)
                        .expect("并发构建应成功")
                        .0
                })
            })
            .collect();
        let engines: Vec<_> = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect();

        let observed = requests.load(Ordering::SeqCst);
        let _ = stop_tx.send(());
        let _ = server.join();

        assert_eq!(
            observed, 1,
            "同 key 并发未命中必须只构建一次（修复前每线程各建一次 → N 次请求）"
        );
        for engine in &engines {
            assert!(
                Arc::ptr_eq(engine, &engines[0]),
                "所有等待者必须复用先到者装入的同一引擎实例"
            );
        }
        // 同 key 只装入一个条目（len 断言受并行测试影响，故用 key 定位）
        assert_eq!(
            store()
                .lock()
                .unwrap()
                .entries
                .get("single-flight-key")
                .map(|entry| Arc::strong_count(&entry.engine))
                .unwrap_or(0),
            THREADS + 1,
            "缓存条目应只被各线程的返回句柄 + 缓存表引用"
        );
        assert!(
            !lock_flights().contains_key("single-flight-key"),
            "single-flight 表项必须在无等待者后清理（防内存泄漏）"
        );
    }

    /// P3-1 配套：`invalidate` 移除条目后，下次获取会重建全新引擎。
    #[test]
    fn invalidate_forces_rebuild() {
        let _guard = lock_test();
        clear_for_tests();
        let (first, _, _) = get_or_create("invalidate-key", None, None, None).unwrap();
        invalidate("invalidate-key");
        assert_eq!(len_for_tests(), 0, "失效后条目必须移除");
        let (second, _, _) = get_or_create("invalidate-key", None, None, None).unwrap();
        assert!(
            !Arc::ptr_eq(&first, &second),
            "失效后必须重建引擎，不得复用旧句柄"
        );
    }

    /// 批21a：单次求值预算参与缓存键比较——同预算复用同一引擎，
    /// 换预算（None ↔ 30s）必须重建，既有 `get_or_create` 语义逐字不变。
    #[test]
    fn timeout_participates_in_cache_key() {
        let _guard = lock_test();
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
