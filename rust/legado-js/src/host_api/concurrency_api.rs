//! 并发控制 API
//!
//! 对应 Kotlin 端 `JsExtensions` 中的 singleFlight / lock / tick 方法。
//! 使用全局 HashMap + Mutex 实现简单的并发控制原语。
//!
//! - `single_flight`: 合并相同 key 的并发调用，只执行一次
//! - `lock`: 互斥锁，等待指定时间
//! - `tick`: 原子计数器

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

/// 全局锁注册表
static LOCK_REGISTRY: OnceLock<Mutex<HashMap<String, LockEntry>>> = OnceLock::new();

/// 全局计数器注册表
static TICK_REGISTRY: OnceLock<Mutex<HashMap<String, i64>>> = OnceLock::new();

struct LockEntry {
    /// 锁是否被持有
    locked: bool,
    /// single_flight 结果缓存（key -> (result, expire_time)）
    flight_result: Option<(String, Instant)>,
}

fn get_lock_registry() -> &'static Mutex<HashMap<String, LockEntry>> {
    LOCK_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn get_tick_registry() -> &'static Mutex<HashMap<String, i64>> {
    TICK_REGISTRY.get_or_init(|| Mutex::new(HashMap::new()))
}

/// singleFlight - 合并并发调用
///
/// 对应 Kotlin: `singleFlight(name, action, timeoutMs)`
/// 在 wait_ms 内如果已有相同 key 的结果缓存，直接返回缓存结果。
/// 否则执行 f_js（此处简化为返回 key 标识），并缓存结果。
///
/// # 参数
/// - `key`: 并发标识键
/// - `wait_ms`: 等待超时（毫秒）
/// - `f_js`: JS 函数字符串（简化实现中作为标识）
///
/// # 返回
/// 执行结果字符串
pub fn single_flight(key: String, wait_ms: i64, f_js: String) -> String {
    let registry = get_lock_registry();
    let mut map = registry.lock().unwrap_or_else(|e| e.into_inner());

    let entry = map.entry(key.clone()).or_insert_with(|| LockEntry {
        locked: false,
        flight_result: None,
    });

    // 检查是否有未过期的缓存结果
    if let Some((ref result, expire)) = entry.flight_result {
        if Instant::now() < expire {
            return result.clone();
        }
    }

    // 执行"函数"（简化：返回 f_js 本身作为结果标识）
    let result = format!("[flight:{}]", f_js);
    let ttl = Duration::from_millis(wait_ms.max(0) as u64);
    entry.flight_result = Some((result.clone(), Instant::now() + ttl));

    result
}

/// lock - 尝试获取互斥锁
///
/// 对应 Kotlin: `lock(name, action, timeoutMs)`
/// 尝试在 wait_ms 内获取锁。
///
/// # 参数
/// - `key`: 锁标识键
/// - `wait_ms`: 等待超时（毫秒）
///
/// # 返回
/// 是否成功获取锁
pub fn lock(key: String, wait_ms: i64) -> bool {
    let registry = get_lock_registry();
    let deadline = Instant::now() + Duration::from_millis(wait_ms.max(0) as u64);

    loop {
        {
            let mut map = registry.lock().unwrap_or_else(|e| e.into_inner());
            let entry = map.entry(key.clone()).or_insert_with(|| LockEntry {
                locked: false,
                flight_result: None,
            });

            if !entry.locked {
                entry.locked = true;
                return true;
            }
        }

        if Instant::now() >= deadline {
            return false;
        }

        // 短暂等待后重试
        std::thread::sleep(Duration::from_millis(1));
    }
}

/// tick - 原子计数器递增
///
/// 对应 Kotlin: `tick(name)` -> SourceLock.tick(sourceConcurrencyKey(name))
/// 每次调用返回递增后的计数值。
///
/// # 参数
/// - `key`: 计数器标识键
///
/// # 返回
/// 递增后的计数值
pub fn tick(key: String) -> i64 {
    let registry = get_tick_registry();
    let mut map = registry.lock().unwrap_or_else(|e| e.into_inner());
    let counter = map.entry(key).or_insert(0);
    *counter += 1;
    *counter
}

/// 释放锁（辅助方法，供测试和外部调用）
pub fn unlock(key: &str) {
    let registry = get_lock_registry();
    let mut map = registry.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(entry) = map.get_mut(key) {
        entry.locked = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_single_flight_caches() {
        let r1 = single_flight("sf_test".into(), 5000, "action1".into());
        let r2 = single_flight("sf_test".into(), 5000, "action2".into());
        // 第二次应返回缓存结果
        assert_eq!(r1, r2);
        assert!(r1.contains("action1"));
    }

    #[test]
    fn test_lock_acquire_and_release() {
        assert!(lock("lock_test".into(), 100));
        // 锁已被持有，再次获取应超时失败
        assert!(!lock("lock_test".into(), 10));
        // 释放后可再次获取
        unlock("lock_test");
        assert!(lock("lock_test".into(), 100));
        unlock("lock_test");
    }

    #[test]
    fn test_tick_increments() {
        let v1 = tick("tick_test".into());
        let v2 = tick("tick_test".into());
        let v3 = tick("tick_test".into());
        assert_eq!(v1, 1);
        assert_eq!(v2, 2);
        assert_eq!(v3, 3);
    }

    #[test]
    fn test_different_keys_independent() {
        let a = tick("indep_a".into());
        let b = tick("indep_b".into());
        assert_eq!(a, 1);
        assert_eq!(b, 1);
    }
}
