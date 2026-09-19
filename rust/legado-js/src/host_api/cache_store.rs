//! 进程级缓存存储（内存 LRU + 本地磁盘文件）
//!
//! P2-9 ①：对齐上游 `help/CacheManager.kt`（put/get/putMemory/getFromMemory/
//! deleteMemory/delete，L60-98）与 WebCacheManager 的 JS 面
//! （`put/putMemory/getFromMemory/deleteMemory/get(onlyDisk)/putFile/getFile/delete`）。
//!
//! 语义对齐：
//! - `put(key, value, saveTime)` — saveTime 单位**秒**；0（或缺省）= 永久
//!   （deadline = 0）并同步写内存层；非零 → `deadline = now + saveTime*1000`
//!   且清除该 key 的内存层（对齐上游 put 后 deleteMemory）。
//! - `get(key, onlyDisk)` — 内存层优先（onlyDisk 跳过）；磁盘层按
//!   deadline 校验：0 = 永久（回写内存层），过期 → 删文件并返回 None。
//! - `putMemory/getFromMemory/deleteMemory` — 内存 LRU（容量 1024）。
//! - `putFile/getFile` — 纯磁盘（独立子目录 `file/`，不进内存层、不过期）。
//! - `delete(key)` — 磁盘 + 内存。
//!
//! QuickJS 引擎按 source_tag LRU 缓存、跨书源复用（engine_cache），
//! 故缓存实现为 **Rust 进程级存储**而非 JS 对象——同一进程内多书源共享
//! 同一份缓存，对齐上游单例 CacheManager 语义（JS 侧每次 eval 都能命中）。
//!
//! 磁盘目录解析优先级（P2-11 ②）：
//! 1. 环境变量 [`CACHE_DIR_ENV`]（非空，测试隔离用）
//! 2. 宿主注入目录（[`set_cache_dir`]，FFI/Android 宿主初始化时传入应用
//!    私有缓存目录）
//! 3. `<temp_dir>/legado-js-cache`（现状缺省，回落时一次性告警日志）
//!
//! 写盘失败（目录创建/序列化/`fs::write`）均记录失败原因并**保留内存层**
//! （新值晋升内存层：同进程 `get` 可读、无 deadline 强制、`onlyDisk` 读
//! 不受影响），返回值仍为 false——JS 侧 `cache.put` 忽略返回值，磁盘层
//! 静默降级为内存层，不再「put 后 get 永远 null」无声丢失。

use std::fs;
use std::num::NonZeroUsize;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use lru::LruCache;
use sha2::{Digest, Sha256};

/// 内存层 LRU 容量
const MEMORY_CACHE_CAPACITY: usize = 1024;

/// 磁盘缓存目录环境变量名
pub const CACHE_DIR_ENV: &str = "LEGADO_JS_CACHE_DIR";

/// 磁盘条目：`{"v": 值, "d": deadline(ms, 0=永久)}`
#[derive(serde::Serialize, serde::Deserialize)]
struct DiskCacheEntry {
    v: String,
    d: i64,
}

fn memory_cache() -> &'static Mutex<LruCache<String, String>> {
    static CACHE: OnceLock<Mutex<LruCache<String, String>>> = OnceLock::new();
    CACHE.get_or_init(|| {
        let cap =
            NonZeroUsize::new(MEMORY_CACHE_CAPACITY).unwrap_or(NonZeroUsize::new(16).unwrap());
        Mutex::new(LruCache::new(cap))
    })
}

/// 宿主注入的磁盘缓存目录（P2-11 ②）
static INJECTED_DIR: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 注入磁盘缓存目录（宿主注入点，P2-11 ②；P2-15 剩项经 frb 薄桥接通）
///
/// FFI/Android 宿主在初始化时调用，指向应用私有缓存目录（如 Android
/// `Context.getCacheDir()`，Dart path_provider `getApplicationCacheDirectory()`
/// 等价），使 `cache.put/get` 磁盘层落应用私有存储而非系统 temp 目录。
/// 后续全部磁盘层读写（put/get/putFile/getFile/delete）生效；内存层不受
/// 注入影响。
///
/// 目录解析优先级见模块文档：env [`CACHE_DIR_ENV`]（非空）> 注入目录 >
/// 缺省 temp 目录。Dart 侧经 flutter_rust_bridge 薄桥
/// `legado-ffi::ffi::set_cache_dir`（P2-15 剩项新增，生成 Dart 绑定
/// `setCacheDir`）在启动时注入应用私有缓存目录。
pub fn set_cache_dir(path: impl AsRef<std::path::Path>) {
    if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        *guard = Some(path.as_ref().to_path_buf());
    }
}

/// 清除注入目录（测试隔离用）
#[cfg(test)]
pub(crate) fn clear_cache_dir() {
    if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        *guard = None;
    }
}

/// 测试构建专用：显式磁盘目录覆盖槽（并行 UB 卫生）
///
/// 环境变量是进程级全局状态：并行测试（`--test-threads=N`）里
/// `set_var`/`remove_var` 与其他测试的 env 并发读属数据竞争（UB），
/// 故测试构建中 [`disk_dir`] 改走「测试覆盖槽 > 宿主注入（[`set_cache_dir`]）
/// > 缺省 temp 目录」并整体旁路 env 分支，行为与宿主环境完全无关。
/// 生产构建（`cfg(not(test))`）不含此槽，生产逻辑零改动。
#[cfg(test)]
static TEST_DISK_DIR_OVERRIDE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 设置（`Some`）或清除（`None`）测试构建的磁盘目录覆盖
#[cfg(test)]
pub(crate) fn set_test_disk_dir_override(dir: Option<PathBuf>) {
    if let Ok(mut guard) = TEST_DISK_DIR_OVERRIDE
        .get_or_init(|| Mutex::new(None))
        .lock()
    {
        *guard = dir;
    }
}

/// 回落系统 temp 目录时的一次性告警日志
static DEFAULT_DIR_WARNED: AtomicBool = AtomicBool::new(false);

/// `put` 磁盘写失败（目录创建/序列化/`fs::write`）一次性告警标志
/// （P2-15 剩项：目录不合法时每次 `cache.put` 都会失败，未限流前每次
/// 各打一条错误日志；现进程内仅首条失败记录，后续静默）
static PUT_WRITE_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// `putFile` 磁盘写失败一次性告警标志（同 [`PUT_WRITE_FAIL_WARNED`]）
static PUT_FILE_WRITE_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 一次性限流告警（P2-15 剩项，照抄 [`DEFAULT_DIR_WARNED`] 的
/// `compare_exchange` 模式）：首条告警实际执行 `log` 并返回 true，
/// 后续调用静默返回 false
fn warn_once(flag: &AtomicBool, log: impl FnOnce()) -> bool {
    if flag
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        log();
        true
    } else {
        false
    }
}

/// 重置写失败一次性告警标志（测试隔离用）
#[cfg(test)]
pub(crate) fn reset_write_fail_warned() {
    PUT_WRITE_FAIL_WARNED.store(false, Ordering::SeqCst);
    PUT_FILE_WRITE_FAIL_WARNED.store(false, Ordering::SeqCst);
}

/// 磁盘缓存根目录：env 覆盖 > 宿主注入（[`set_cache_dir`]）>
/// `<temp_dir>/legado-js-cache`（现状行为，回落时一次性告警）
///
/// 测试构建（`cfg(test)`）：优先查显式测试覆盖槽
/// （[`set_test_disk_dir_override`]）并整体旁路 env 分支——并行测试
/// 不得操作进程级环境变量（`set_var` 与并发 env 读是 UB）；生产
/// 构建不含该分支，生产解析链（env > 注入 > 缺省）逐字节不变。
pub fn disk_dir() -> PathBuf {
    #[cfg(test)]
    {
        if let Ok(guard) = TEST_DISK_DIR_OVERRIDE
            .get_or_init(|| Mutex::new(None))
            .lock()
        {
            if let Some(dir) = guard.clone() {
                return dir;
            }
        }
    }
    #[cfg(not(test))]
    {
        if let Ok(dir) = std::env::var(CACHE_DIR_ENV) {
            if !dir.trim().is_empty() {
                return PathBuf::from(dir);
            }
        }
    }
    if let Ok(guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        if let Some(dir) = guard.clone() {
            return dir;
        }
    }
    if DEFAULT_DIR_WARNED
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        eprintln!(
            "[cache_store] 未注入宿主缓存目录（set_cache_dir）且未设 env {CACHE_DIR_ENV}——回落系统临时目录 {:?}（磁盘缓存随系统 temp 清理而丢失，宿主应在初始化时注入应用私有缓存目录）",
            std::env::temp_dir().join("legado-js-cache")
        );
    }
    std::env::temp_dir().join("legado-js-cache")
}

fn sha256_hex(input: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(input.as_bytes());
    let bytes = hasher.finalize();
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

fn disk_path(key: &str) -> PathBuf {
    disk_dir().join(format!("{}.json", sha256_hex(key)))
}

fn file_path(key: &str) -> PathBuf {
    disk_dir().join("file").join(sha256_hex(key))
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 磁盘层测试串行锁（P2-11 ②）
///
/// 注入态（INJECTED_DIR）/ 环境变量（CACHE_DIR_ENV）/ 内存层均为进程级
/// 全局状态：所有触碰磁盘层的测试（本模块与 quickjs_impl 的 cache 全局
/// 测试）执行前取本锁，互不干扰目录切换/清理。
#[cfg(test)]
pub(crate) static CACHE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 取磁盘层测试串行锁（返回守卫；中毒时恢复而非 panic）
#[cfg(test)]
pub(crate) fn lock_cache_for_test() -> std::sync::MutexGuard<'static, ()> {
    CACHE_TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner())
}

/// 内存层写入（`putMemory`）
pub fn put_memory(key: &str, value: &str) {
    if let Ok(mut cache) = memory_cache().lock() {
        cache.put(key.to_string(), value.to_string());
    }
}

/// 内存层读取（`getFromMemory`）
pub fn get_from_memory(key: &str) -> Option<String> {
    memory_cache().lock().ok()?.get(key).cloned()
}

/// 内存层删除（`deleteMemory`）
pub fn delete_memory(key: &str) {
    if let Ok(mut cache) = memory_cache().lock() {
        cache.pop(key);
    }
}

/// 磁盘写入（`put`）：saveTime 秒，0=永久（同步内存层），非零 → 清内存层
///
/// P2-11 ②：写盘失败（目录创建 / 序列化 / `fs::write`）均记录失败原因，
/// 并把新值**晋升内存层**（保留内存层语义：不 `delete_memory` 旧值、
/// 直接写新值）——降级说明：同进程 `get` 仍可读该值、无 deadline 强制
/// （内存层不过期）、`onlyDisk` 读不受影响（磁盘层为空）。成功路径不变：
/// 先写盘，成功后再调内存层（deadline==0 → 同步内存；非零 → 清内存，
/// 对齐上游 put 后 deleteMemory）。
pub fn put(key: &str, value: &str, save_time_secs: i64) -> bool {
    let deadline = if save_time_secs <= 0 {
        0
    } else {
        now_millis() + save_time_secs * 1000
    };
    let path = disk_path(key);
    if let Some(parent) = path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            warn_once(&PUT_WRITE_FAIL_WARNED, || {
                eprintln!(
                    "[cache_store] 创建缓存目录失败 {:?}: {e}（降级保留内存层；同类失败后续不再逐条记日志）",
                    parent
                );
            });
            put_memory(key, value);
            return false;
        }
    }
    let json = match serde_json::to_string(&DiskCacheEntry {
        v: value.to_string(),
        d: deadline,
    }) {
        Ok(j) => j,
        Err(e) => {
            warn_once(&PUT_WRITE_FAIL_WARNED, || {
                eprintln!("[cache_store] 序列化失败 {key}: {e}（降级保留内存层；同类失败后续不再逐条记日志）");
            });
            put_memory(key, value);
            return false;
        }
    };
    if let Err(e) = fs::write(&path, json) {
        warn_once(&PUT_WRITE_FAIL_WARNED, || {
            eprintln!("[cache_store] 写盘失败 {key} ({path:?}): {e}（降级保留内存层；同类失败后续不再逐条记日志）");
        });
        put_memory(key, value);
        return false;
    }
    if deadline == 0 {
        put_memory(key, value);
    } else {
        delete_memory(key);
    }
    true
}

/// 磁盘读取（`get`）：内存优先（only_disk 跳过），磁盘按 deadline 校验
pub fn get(key: &str, only_disk: bool) -> Option<String> {
    if !only_disk {
        if let Some(v) = get_from_memory(key) {
            return Some(v);
        }
    }
    let raw = fs::read_to_string(disk_path(key)).ok()?;
    let entry: DiskCacheEntry = serde_json::from_str(&raw).ok()?;
    if entry.d == 0 || now_millis() <= entry.d {
        if entry.d == 0 {
            put_memory(key, &entry.v);
        }
        Some(entry.v)
    } else {
        let _ = fs::remove_file(disk_path(key));
        None
    }
}

/// 纯磁盘写入（`putFile`，无内存层、不过期）
pub fn put_file(key: &str, value: &str) -> bool {
    let path = file_path(key);
    if let Some(parent) = path.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {
                eprintln!(
                    "[cache_store] 创建缓存目录失败 {:?}: {e}（纯磁盘 API 无内存层可降级；同类失败后续不再逐条记日志）",
                    parent
                );
            });
            return false;
        }
    }
    // P2-11 ②：纯磁盘 API（file/ 子目录，不进内存层）——写失败无内存层
    // 可降级，仅记录失败原因（原 `.is_ok()` 静默吞错）；P2-15 剩项：
    // 限流为进程内首条（目录不合法时每次 `cache.putFile` 都会失败）
    match fs::write(&path, value) {
        Ok(()) => true,
        Err(e) => {
            warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {
                eprintln!(
                    "[cache_store] 写盘失败 {key} ({path:?}): {e}（同类失败后续不再逐条记日志）"
                );
            });
            false
        }
    }
}

/// 纯磁盘读取（`getFile`，不做 deadline 校验）
pub fn get_file(key: &str) -> Option<String> {
    fs::read_to_string(file_path(key)).ok()
}

/// 删除（磁盘 + 内存）
pub fn delete(key: &str) {
    let _ = fs::remove_file(disk_path(key));
    let _ = fs::remove_file(file_path(key));
    delete_memory(key);
}

#[cfg(test)]
mod tests {
    use super::*;
    // Ordering 经 `use super::*` 引入（文件头 import），此处仅补 AtomicUsize
    use std::sync::atomic::AtomicUsize;

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    /// 进程级唯一临时根目录（注入目录测试用，测试收尾 remove_dir_all 清理）
    fn unique_root(tag: &str) -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "legado-js-cache-test-{}-{}-{}",
            std::process::id(),
            n,
            tag
        ))
    }

    fn unique_key(tag: &str) -> String {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        format!("{}-{}-{}", std::process::id(), n, tag)
    }

    #[test]
    fn test_memory_roundtrip() {
        let _lock = lock_cache_for_test();
        let k = unique_key("mem");
        assert!(get_from_memory(&k).is_none());
        put_memory(&k, "v1");
        assert_eq!(get_from_memory(&k).as_deref(), Some("v1"));
        // 数字值（语料 cache.putMemory(k, Date.now())）以字符串存储
        put_memory(&k, "1726540800000");
        assert_eq!(get_from_memory(&k).as_deref(), Some("1726540800000"));
        delete_memory(&k);
        assert!(get_from_memory(&k).is_none());
    }

    #[test]
    fn test_put_get_permanent() {
        let _lock = lock_cache_for_test();
        let k = unique_key("perm");
        assert!(put(&k, "perm-value", 0));
        assert_eq!(get(&k, false).as_deref(), Some("perm-value"));
        // 永久缓存命中后回写内存层
        assert_eq!(get_from_memory(&k).as_deref(), Some("perm-value"));
        // onlyDisk 跳过内存层，直接读磁盘
        assert_eq!(get(&k, true).as_deref(), Some("perm-value"));
        delete(&k);
        assert!(get(&k, false).is_none());
        assert!(get(&k, true).is_none());
        assert!(get_from_memory(&k).is_none());
    }

    #[test]
    fn test_put_get_expired() {
        let _lock = lock_cache_for_test();
        let k = unique_key("expired");
        // saveTime=1 秒；等待过期后磁盘读取应 None 且文件被清理
        assert!(put(&k, "short", 1));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert!(get(&k, true).is_none());
    }

    #[test]
    fn test_put_nonsync_clears_memory() {
        let _lock = lock_cache_for_test();
        let k = unique_key("memclear");
        put_memory(&k, "old");
        put(&k, "new", 3600);
        // 非永久 put 清除内存层（对齐上游 put 后 deleteMemory）
        assert!(get_from_memory(&k).is_none());
        // 磁盘层仍可读
        assert_eq!(get(&k, true).as_deref(), Some("new"));
        delete(&k);
    }

    #[test]
    fn test_file_roundtrip() {
        let _lock = lock_cache_for_test();
        let k = unique_key("file");
        assert!(put_file(&k, "file-value"));
        assert_eq!(get_file(&k).as_deref(), Some("file-value"));
        // putFile/getFile 不进内存层
        assert!(get_from_memory(&k).is_none());
        delete(&k);
        assert!(get_file(&k).is_none());
    }

    #[test]
    fn test_missing_key_returns_none() {
        let _lock = lock_cache_for_test();
        let k = unique_key("missing");
        assert!(get(&k, false).is_none());
        assert!(get(&k, true).is_none());
        assert!(get_file(&k).is_none());
        assert!(get_from_memory(&k).is_none());
    }

    /// P2-11 ②：注入目录 → put→get 命中（磁盘文件落注入目录，清理后回落缺省）
    ///
    /// 前置清理改用显式测试覆盖槽（[`set_test_disk_dir_override`]）而非
    /// `remove_var`：env 是进程级全局状态，并行测试中操作它是 UB。
    #[test]
    fn test_set_cache_dir_injected_hit() {
        let _lock = lock_cache_for_test();
        let root = unique_root("injected-hit");
        let injected = root.join("injected");
        let k = unique_key("inj");
        set_test_disk_dir_override(None);
        clear_cache_dir();
        set_cache_dir(&injected);
        assert_eq!(disk_dir(), injected);
        // 注入目录 → put→get 命中（永久值：内存/onlyDisk 双路）
        assert!(put(&k, "injected-value", 0));
        assert_eq!(get(&k, false).as_deref(), Some("injected-value"));
        // onlyDisk 跳过内存层，直接读注入目录下的磁盘文件
        assert_eq!(get(&k, true).as_deref(), Some("injected-value"));
        assert!(disk_path(&k).starts_with(&injected));
        delete(&k);
        clear_cache_dir();
        // 清除注入后回落缺省 temp 目录
        assert_eq!(disk_dir(), std::env::temp_dir().join("legado-js-cache"));
        let _ = fs::remove_dir_all(&root);
    }

    /// P2-11 ②：写盘失败 → 保留内存层（新值晋升内存层，同进程可读）
    ///
    /// 路径 A：注入目录指向普通文件 → `create_dir_all` 失败；
    /// 路径 B：注入目录存在但磁盘路径预建为目录 → `fs::write` 失败（EISDIR）；
    /// `put_file` 失败仅记日志（纯磁盘 API 无内存层可降级）。
    #[test]
    fn test_put_write_failure_keeps_memory() {
        let _lock = lock_cache_for_test();
        let root = unique_root("write-fail");
        let k1 = unique_key("wfail-a");
        let k2 = unique_key("wfail-b");
        let k3 = unique_key("wfail-c");
        set_test_disk_dir_override(None);
        fs::create_dir_all(&root).expect("临时根目录");

        // 路径 A：注入目录指向普通文件 → create_dir_all 失败
        let file_blocker = root.join("blocker.txt");
        fs::write(&file_blocker, "x").expect("blocker 文件");
        clear_cache_dir();
        set_cache_dir(&file_blocker);
        assert!(!put(&k1, "v1", 0));
        // 新值晋升内存层：同进程可读
        assert_eq!(get_from_memory(&k1).as_deref(), Some("v1"));
        assert_eq!(get(&k1, false).as_deref(), Some("v1"));
        // 磁盘层为空 → onlyDisk 读不受影响
        assert!(get(&k1, true).is_none());

        // 路径 B：注入目录存在，磁盘路径预建为目录 → fs::write 失败
        let injected = root.join("inj-b");
        clear_cache_dir();
        set_cache_dir(&injected);
        fs::create_dir_all(&disk_path(&k2)).expect("磁盘路径预建为目录");
        assert!(!put(&k2, "v2", 0));
        assert_eq!(get_from_memory(&k2).as_deref(), Some("v2"));
        assert!(get(&k2, true).is_none());

        // put_file 失败路径：file 路径预建为目录 → 仅记日志，无内存层
        fs::create_dir_all(&file_path(&k3)).expect("file 路径预建为目录");
        assert!(!put_file(&k3, "vf"));
        assert!(get_from_memory(&k3).is_none());
        assert!(get_file(&k3).is_none());

        // 收尾（P2-15 剩项：重置写失败告警标志，测试隔离）
        delete_memory(&k1);
        delete_memory(&k2);
        clear_cache_dir();
        reset_write_fail_warned();
        let _ = fs::remove_dir_all(&root);
    }

    /// P2-11 ②：目录解析优先级（测试构建：显式覆盖槽 > 注入 > 缺省 temp；
    /// 生产构建为 env > 注入 > 缺省，cfg(not(test)) 路径逐字节未动）
    ///
    /// 原用例经 `set_var`/`remove_var` 操作进程级 env 验证「env 优先级最高」，
    /// 现替换为测试覆盖槽（[`set_test_disk_dir_override`]）验证同构的
    /// 「显式覆盖 > 注入 > 缺省」优先级——消除并行测试的 env 全局状态污染。
    #[test]
    fn test_cache_dir_priority_and_default() {
        let _lock = lock_cache_for_test();
        let root = unique_root("priority");
        let env_dir = root.join("env-dir");
        let injected = root.join("injected-dir");
        let k = unique_key("prio");
        set_test_disk_dir_override(None);
        clear_cache_dir();

        // 未注入且未覆盖 → 现状行为：回落 <temp_dir>/legado-js-cache，往返仍可用
        assert_eq!(disk_dir(), std::env::temp_dir().join("legado-js-cache"));
        assert!(put(&k, "default-value", 0));
        assert_eq!(get(&k, false).as_deref(), Some("default-value"));
        delete(&k);

        // 显式覆盖槽优先级最高（同时存在注入时也优先覆盖槽）
        set_test_disk_dir_override(Some(env_dir.clone()));
        set_cache_dir(&injected);
        assert_eq!(disk_dir(), env_dir);

        // 清除覆盖槽后注入目录生效
        set_test_disk_dir_override(None);
        assert_eq!(disk_dir(), injected);

        set_test_disk_dir_override(None);
        clear_cache_dir();
        let _ = fs::remove_dir_all(&root);
    }

    /// P2-15 剩项 ④：写失败告警限流——进程内首条失败记录（返回 true），
    /// 后续同类失败静默（返回 false）；`put`/`putFile` 两标志互独立；
    /// 重置后（测试隔离）可再次首条触发
    #[test]
    fn test_write_fail_warned_once() {
        let _lock = lock_cache_for_test();
        reset_write_fail_warned();
        assert!(warn_once(&PUT_WRITE_FAIL_WARNED, || {}), "首条失败应记录");
        assert!(
            !warn_once(&PUT_WRITE_FAIL_WARNED, || {}),
            "后续同类失败应静默"
        );
        // putFile 标志与 put 标志互独立
        assert!(warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {}));
        assert!(!warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {}));
        // 重置后（测试隔离）可再次首条触发
        reset_write_fail_warned();
        assert!(warn_once(&PUT_WRITE_FAIL_WARNED, || {}));
        // 收尾：两标志保持已消费态（无其他测试依赖其首条语义）
    }
}
