//! 书源并发原语
//!
//! 移植自 Kotlin SourceLock.kt (101行)
//! 提供 singleFlight（同 key 单次执行）、lock（带超时互斥）、tick（LRU 计数器）三个能力。

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

const MAX_WAIT_MS: u64 = 300_000;
const MAX_COUNTERS: usize = 4096;

// ---------------------------------------------------------------------------
// SingleFlight
// ---------------------------------------------------------------------------

/// 同 key 单次执行：后续等待者获取相同结果
pub struct SingleFlight {
    flights: Mutex<HashMap<String, Arc<FlightState>>>,
}

struct FlightState {
    /// epoch 用于判断结果是否已被消费
    epoch: Mutex<u64>,
    /// 执行结果
    result: Mutex<Option<String>>,
    /// 通知等待者
    notify: Condvar,
    /// 是否正在执行
    running: Mutex<bool>,
}

impl Default for SingleFlight {
    fn default() -> Self {
        Self::new()
    }
}

impl SingleFlight {
    pub fn new() -> Self {
        Self {
            flights: Mutex::new(HashMap::new()),
        }
    }

    /// 执行或等待
    ///
    /// 如果 key 已有 flight 在执行，等待其结果（最多 wait_ms 毫秒）。
    /// 否则创建新 flight 并执行 f。
    pub fn do_call(&self, key: &str, wait_ms: u64, f: impl FnOnce() -> String) -> Option<String> {
        assert!(
            wait_ms <= MAX_WAIT_MS,
            "wait_ms 必须在 0..={MAX_WAIT_MS} 之间"
        );

        let state = {
            let mut map = self.flights.lock().unwrap();
            map.entry(key.to_string())
                .or_insert_with(|| {
                    Arc::new(FlightState {
                        epoch: Mutex::new(0),
                        result: Mutex::new(None),
                        notify: Condvar::new(),
                        running: Mutex::new(false),
                    })
                })
                .clone()
        };

        let entry_epoch = { *state.epoch.lock().unwrap() };

        // 尝试成为执行者
        {
            let mut running = state.running.lock().unwrap();
            if *running {
                // 已有执行者，等待结果
                let deadline = Instant::now() + Duration::from_millis(wait_ms);
                let mut result_guard = state.result.lock().unwrap();
                loop {
                    if *state.epoch.lock().unwrap() != entry_epoch {
                        // 结果已更新
                        return result_guard.clone();
                    }
                    let now = Instant::now();
                    if now >= deadline {
                        return None; // 超时
                    }
                    let remaining = deadline - now;
                    let (guard, timeout) =
                        state.notify.wait_timeout(result_guard, remaining).unwrap();
                    result_guard = guard;
                    if timeout.timed_out() && *state.epoch.lock().unwrap() == entry_epoch {
                        return None;
                    }
                }
            } else {
                *running = true;
            }
        }

        // 执行
        let result = f();

        // 存储结果并通知
        {
            let mut result_guard = state.result.lock().unwrap();
            *result_guard = Some(result.clone());
        }
        {
            let mut epoch = state.epoch.lock().unwrap();
            *epoch += 1;
        }
        {
            let mut running = state.running.lock().unwrap();
            *running = false;
        }
        state.notify.notify_all();

        Some(result)
    }
}

// ---------------------------------------------------------------------------
// SourceLock
// ---------------------------------------------------------------------------

/// 带超时的按 key 互斥锁
pub struct SourceLock {
    locks: Mutex<HashMap<String, Arc<LockEntry>>>,
}

struct LockEntry {
    mutex: Mutex<()>,
}

impl Default for SourceLock {
    fn default() -> Self {
        Self::new()
    }
}

impl SourceLock {
    pub fn new() -> Self {
        Self {
            locks: Mutex::new(HashMap::new()),
        }
    }

    /// 获取锁，超时返回 None
    pub fn try_lock(&self, key: &str, wait_ms: u64) -> Option<SourceLockGuard> {
        assert!(
            wait_ms <= MAX_WAIT_MS,
            "wait_ms 必须在 0..={MAX_WAIT_MS} 之间"
        );

        let entry = {
            let mut map = self.locks.lock().unwrap();
            map.entry(key.to_string())
                .or_insert_with(|| {
                    Arc::new(LockEntry {
                        mutex: Mutex::new(()),
                    })
                })
                .clone()
        };

        let deadline = Instant::now() + Duration::from_millis(wait_ms);
        loop {
            // 将 try_lock 结果转为 enum，确保 MutexGuard 从 Result 临时值中移出，
            // 避免 Result drop 时仍持有 entry 借用。
            enum LockResult {
                Acquired(std::sync::MutexGuard<'static, ()>),
                WouldBlock,
                Poisoned(std::sync::MutexGuard<'static, ()>),
            }

            let result = match entry.mutex.try_lock() {
                Ok(g) => {
                    // SAFETY: MutexGuard 借用的 Mutex 存活于 Arc<LockEntry> 堆内存中，
                    // 只要 _entry (Arc) 存活，Mutex 就不会被释放，guard 就有效。
                    LockResult::Acquired(unsafe {
                        std::mem::transmute::<
                            std::sync::MutexGuard<'_, ()>,
                            std::sync::MutexGuard<'static, ()>,
                        >(g)
                    })
                }
                Err(std::sync::TryLockError::WouldBlock) => LockResult::WouldBlock,
                Err(std::sync::TryLockError::Poisoned(e)) => LockResult::Poisoned(unsafe {
                    std::mem::transmute::<
                        std::sync::MutexGuard<'_, ()>,
                        std::sync::MutexGuard<'static, ()>,
                    >(e.into_inner())
                }),
            };

            match result {
                LockResult::Acquired(guard) | LockResult::Poisoned(guard) => {
                    return Some(SourceLockGuard {
                        _entry: entry,
                        _guard: guard,
                    });
                }
                LockResult::WouldBlock => {
                    if Instant::now() >= deadline {
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }
    }

    /// 带闭包的锁操作（自动释放）
    pub fn with_lock<F, R>(&self, key: &str, wait_ms: u64, f: F) -> Option<R>
    where
        F: FnOnce() -> R,
    {
        let _guard = self.try_lock(key, wait_ms)?;
        Some(f())
    }
}

/// RAII 锁守卫
///
/// 持有 `Arc<LockEntry>` 保证 Mutex 存活，`MutexGuard<'static, ()>` 通过
/// unsafe transmute 扩展生命周期（实际由 Arc 引用计数保证安全）。
pub struct SourceLockGuard {
    /// 保持 Arc 引用使 Mutex 存活
    _entry: Arc<LockEntry>,
    _guard: std::sync::MutexGuard<'static, ()>,
}

// ---------------------------------------------------------------------------
// TickCounter
// ---------------------------------------------------------------------------

/// LRU 计数器（上限 4096 条）
pub struct TickCounter {
    counters: Mutex<HashMap<String, u64>>,
    /// 插入顺序追踪（用于 LRU 淘汰）
    order: Mutex<Vec<String>>,
    max_entries: usize,
}

impl Default for TickCounter {
    fn default() -> Self {
        Self::new()
    }
}

impl TickCounter {
    pub fn new() -> Self {
        Self {
            counters: Mutex::new(HashMap::new()),
            order: Mutex::new(Vec::new()),
            max_entries: MAX_COUNTERS,
        }
    }

    /// 自增计数并返回新值
    pub fn tick(&self, key: &str) -> u64 {
        let mut map = self.counters.lock().unwrap();
        let mut order = self.order.lock().unwrap();

        if !map.contains_key(key) && map.len() >= self.max_entries {
            // LRU 淘汰最早的 key
            if let Some(oldest_key) = order.first().cloned() {
                map.remove(&oldest_key);
                order.remove(0);
            }
        }

        // 更新访问顺序
        order.retain(|k| k != key);
        order.push(key.to_string());

        let counter = map.entry(key.to_string()).or_insert(0);
        *counter += 1;
        *counter
    }

    /// 获取当前计数值
    pub fn get(&self, key: &str) -> u64 {
        self.counters.lock().unwrap().get(key).copied().unwrap_or(0)
    }

    /// 当前条目数
    pub fn len(&self) -> usize {
        self.counters.lock().unwrap().len()
    }

    /// 是否为空
    pub fn is_empty(&self) -> bool {
        self.counters.lock().unwrap().is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::thread;

    // --- SingleFlight tests ---

    #[test]
    fn test_single_flight_basic() {
        let sf = SingleFlight::new();
        let result = sf.do_call("key1", 1000, || "hello".to_string());
        assert_eq!(result, Some("hello".to_string()));
    }

    #[test]
    fn test_single_flight_different_keys() {
        let sf = SingleFlight::new();
        let r1 = sf.do_call("a", 1000, || "result_a".to_string());
        let r2 = sf.do_call("b", 1000, || "result_b".to_string());
        assert_eq!(r1, Some("result_a".to_string()));
        assert_eq!(r2, Some("result_b".to_string()));
    }

    #[test]
    fn test_single_flight_concurrent() {
        let sf = Arc::new(SingleFlight::new());
        let call_count = Arc::new(AtomicUsize::new(0));
        let mut handles = vec![];

        for _ in 0..5 {
            let sf = Arc::clone(&sf);
            let cc = Arc::clone(&call_count);
            handles.push(thread::spawn(move || {
                sf.do_call("shared", 5000, || {
                    cc.fetch_add(1, Ordering::SeqCst);
                    thread::sleep(Duration::from_millis(50));
                    "computed".to_string()
                })
            }));
        }

        let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        // 所有线程都应获取到结果
        for r in &results {
            assert_eq!(r, &Some("computed".to_string()));
        }
    }

    #[test]
    fn test_single_flight_sequential_calls() {
        let sf = SingleFlight::new();
        let r1 = sf.do_call("k", 1000, || "first".to_string());
        let r2 = sf.do_call("k", 1000, || "second".to_string());
        assert_eq!(r1, Some("first".to_string()));
        assert_eq!(r2, Some("second".to_string()));
    }

    // --- SourceLock tests ---

    #[test]
    fn test_source_lock_basic() {
        let lock = SourceLock::new();
        let guard = lock.try_lock("res1", 1000);
        assert!(guard.is_some());
    }

    #[test]
    fn test_source_lock_with_lock() {
        let lock = SourceLock::new();
        let result = lock.with_lock("key", 1000, || 42);
        assert_eq!(result, Some(42));
    }

    #[test]
    fn test_source_lock_different_keys() {
        let lock = SourceLock::new();
        let g1 = lock.try_lock("a", 1000);
        let g2 = lock.try_lock("b", 1000);
        assert!(g1.is_some());
        assert!(g2.is_some());
    }

    #[test]
    fn test_source_lock_concurrent_access() {
        let lock = Arc::new(SourceLock::new());
        let counter = Arc::new(AtomicUsize::new(0));
        let mut handles = vec![];

        for _ in 0..10 {
            let lock = Arc::clone(&lock);
            let counter = Arc::clone(&counter);
            handles.push(thread::spawn(move || {
                let _guard = lock.try_lock("shared", 5000);
                counter.fetch_add(1, Ordering::SeqCst);
            }));
        }

        for h in handles {
            h.join().unwrap();
        }
        assert_eq!(counter.load(Ordering::SeqCst), 10);
    }

    // --- TickCounter tests ---

    #[test]
    fn test_tick_basic() {
        let tc = TickCounter::new();
        assert_eq!(tc.tick("a"), 1);
        assert_eq!(tc.tick("a"), 2);
        assert_eq!(tc.tick("a"), 3);
        assert_eq!(tc.get("a"), 3);
    }

    #[test]
    fn test_tick_different_keys() {
        let tc = TickCounter::new();
        assert_eq!(tc.tick("x"), 1);
        assert_eq!(tc.tick("y"), 1);
        assert_eq!(tc.tick("x"), 2);
        assert_eq!(tc.get("x"), 2);
        assert_eq!(tc.get("y"), 1);
    }

    #[test]
    fn test_tick_nonexistent_key() {
        let tc = TickCounter::new();
        assert_eq!(tc.get("missing"), 0);
    }

    #[test]
    fn test_tick_lru_eviction() {
        let tc = TickCounter {
            counters: Mutex::new(HashMap::new()),
            order: Mutex::new(Vec::new()),
            max_entries: 3,
        };
        tc.tick("a");
        tc.tick("b");
        tc.tick("c");
        assert_eq!(tc.len(), 3);
        // 插入第4个，应淘汰最早的 "a"
        tc.tick("d");
        assert_eq!(tc.len(), 3);
        assert_eq!(tc.get("a"), 0); // 已被淘汰
        assert_eq!(tc.get("d"), 1);
    }

    #[test]
    fn test_tick_counter_len_and_empty() {
        let tc = TickCounter::new();
        assert!(tc.is_empty());
        tc.tick("k");
        assert!(!tc.is_empty());
        assert_eq!(tc.len(), 1);
    }

    #[test]
    fn test_tick_concurrent() {
        let tc = Arc::new(TickCounter::new());
        let mut handles = vec![];

        for _ in 0..10 {
            let tc = Arc::clone(&tc);
            handles.push(thread::spawn(move || {
                for _ in 0..100 {
                    tc.tick("shared");
                }
            }));
        }

        for h in handles {
            h.join().unwrap();
        }
        assert_eq!(tc.get("shared"), 1000);
    }
}
