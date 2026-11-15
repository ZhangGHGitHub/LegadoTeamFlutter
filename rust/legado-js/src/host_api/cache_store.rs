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
//! - `putFile(key, value, saveTime)` — 纯磁盘（独立子目录 `file/`，不进内存
//!   层）。saveTime 口径同 `put`：`<= 0` 永久；`> 0` 时在数据文件旁写
//!   `file/<hash>.meta.json`（`{"d": deadline}`），`getFile` 按 deadline
//!   校验并删除过期条目。无 meta 的旧文件（历史版本写入）按永久读取。
//! - `delete(key)` — 磁盘 + 文件缓存（含 meta）+ 内存。
//! - `clear_all()` — 进程级全清（P3-4）：内存 LRU + 根目录 KV 条目 +
//!   `file/` 数据与 meta；**只清本模块自己的产物**、保留注入根目录
//!   （根目录与 image_cache/audio_cache/js_files 等兄弟目录不受影响），
//!   供宿主「清理缓存」入口（FFI `cache_clear`）接线。
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
use std::sync::{Mutex, OnceLock, RwLock, RwLockReadGuard, RwLockWriteGuard};

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

/// 文件缓存旁路元数据：`{"d": deadline(ms)}`（仅 `saveTime > 0` 的
/// `putFile` 条目写 meta 文件；永久条目不写，历史裸文件按永久读取）
#[derive(serde::Serialize, serde::Deserialize)]
struct FileCacheMeta {
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
    // 与进行中的磁盘读写/清空互斥：目录切换不能让 clear_all 清到半新半旧目录
    let _guard = disk_write_guard();
    if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        *guard = Some(path.as_ref().to_path_buf());
    }
}

/// 清除注入目录（测试隔离用；`test-support` 供跨 crate 测试二进制复用）
#[cfg(any(test, feature = "test-support"))]
pub fn clear_cache_dir() {
    let _guard = disk_write_guard();
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
/// > 生产构建（`cfg(not(test))`）不含此槽，生产逻辑零改动。
///
/// 门控（提示 1，批36 P3-4 扩）：`cfg(test)`（本 crate lib 单测）或
/// `test-support` feature（依赖 crate 的 `tests/`/lib 测试经 dev-dependency
/// 启用）——FFI 侧「清缓存接线」测试需要把清空范围钉在独立临时目录，
/// 避免清到开发机的 `%TEMP%/legado-js-cache`。生产构建永不启用该 feature。
#[cfg(any(test, feature = "test-support"))]
static TEST_DISK_DIR_OVERRIDE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 设置（`Some`）或清除（`None`）测试构建的磁盘目录覆盖
#[cfg(any(test, feature = "test-support"))]
pub fn set_test_disk_dir_override(dir: Option<PathBuf>) {
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

/// `clear_all` 单条删除/根目录补建失败一次性告警标志（P3-4）
///
/// 清空是逐条 best-effort：Windows 上可能有个别文件被外部进程短暂占用
/// （sharing violation），单条失败不应中断其余条目清理，也不该逐条刷日志。
static CLEAR_ALL_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 磁盘操作串行化锁（P3-4）
///
/// 常态读写（put/get/putFile/getFile/delete/目录注入）持**读锁**，
/// [`clear_all`] 持**写锁**：清空会等待已进入的单个磁盘操作完成，清空
/// 期间新的读写排队等待，保证「正在使用中的条目」不会被中途删除/写回；
/// 清空结束后新写入正常落盘。锁中毒（持锁线程 panic）经 `into_inner`
/// 恢复——缓存内容不承载一致性状态，继续提供服务优于整体失败。
static DISK_OP_LOCK: RwLock<()> = RwLock::new(());

fn disk_read_guard() -> RwLockReadGuard<'static, ()> {
    DISK_OP_LOCK.read().unwrap_or_else(|p| p.into_inner())
}

fn disk_write_guard() -> RwLockWriteGuard<'static, ()> {
    DISK_OP_LOCK.write().unwrap_or_else(|p| p.into_inner())
}

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
/// 测试构建（`cfg(test)` / `test-support`）：优先查显式测试覆盖槽
/// （[`set_test_disk_dir_override`]）并整体旁路 env 分支——并行测试
/// 不得操作进程级环境变量（`set_var` 与并发 env 读是 UB）；生产
/// 构建不含该分支，生产解析链（env > 注入 > 缺省）逐字节不变。
pub fn disk_dir() -> PathBuf {
    #[cfg(any(test, feature = "test-support"))]
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

/// 文件缓存旁路元数据路径（与数据文件同目录，`.meta.json` 后缀；
/// 仅带 TTL 的 `putFile` 条目存在）
fn file_meta_path(key: &str) -> PathBuf {
    disk_dir()
        .join("file")
        .join(format!("{}.meta.json", sha256_hex(key)))
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
///
/// 门控同 [`set_test_disk_dir_override`]：`cfg(test)` 或 `test-support`
/// feature（跨 crate 测试二进制共用同一把锁的语义约定）。
#[cfg(any(test, feature = "test-support"))]
pub static CACHE_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 取磁盘层测试串行锁（返回守卫；中毒时恢复而非 panic）
#[cfg(any(test, feature = "test-support"))]
pub fn lock_cache_for_test() -> std::sync::MutexGuard<'static, ()> {
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
    // 读锁覆盖「写盘 + 内存层同步」整体：clear_all 的写锁不会在两者之间切入
    let _guard = disk_read_guard();
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
    let _guard = disk_read_guard();
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

/// 纯磁盘写入（`putFile`）：saveTime 秒，`<= 0` 永久（不写 meta），
/// `> 0` 同目录旁路 meta 记录 deadline
///
/// 对齐上游 `CacheManager.putFile(key, value, saveTime = 0)` →
/// `ACache.put(key, value, saveTime)`（saveTime 为单位秒的 TTL）。永久
/// 条目重写时删除旧 meta，避免上一次 TTL 写入的 deadline 把新值提前判过期。
/// 元数据写失败时删除已写入的数据并返回 false——不能把带 TTL 的值静默
/// 降级成永久可读。
pub fn put_file(key: &str, value: &str, save_time_secs: i64) -> bool {
    let _guard = disk_read_guard();
    let deadline = if save_time_secs <= 0 {
        0
    } else {
        now_millis() + save_time_secs.saturating_mul(1000)
    };
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
        Ok(()) => {}
        Err(e) => {
            warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {
                eprintln!(
                    "[cache_store] 写盘失败 {key} ({path:?}): {e}（同类失败后续不再逐条记日志）"
                );
            });
            return false;
        }
    }
    if deadline == 0 {
        // 永久条目：清除上一次 TTL 写入遗留的 deadline（同键重写）
        let _ = fs::remove_file(file_meta_path(key));
        return true;
    }
    let meta_path = file_meta_path(key);
    let meta_json = match serde_json::to_string(&FileCacheMeta { d: deadline }) {
        Ok(j) => j,
        Err(e) => {
            let _ = fs::remove_file(&path);
            warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {
                eprintln!(
                    "[cache_store] 文件缓存元数据序列化失败 {key}: {e}（已删除数据，避免 TTL 值降级为永久）"
                );
            });
            return false;
        }
    };
    if let Err(e) = fs::write(&meta_path, meta_json) {
        let _ = fs::remove_file(&path);
        warn_once(&PUT_FILE_WRITE_FAIL_WARNED, || {
            eprintln!(
                "[cache_store] 文件缓存元数据写盘失败 {key} ({meta_path:?}): {e}（已删除数据，避免 TTL 值降级为永久；同类失败后续不再逐条记日志）"
            );
        });
        return false;
    }
    true
}

/// 纯磁盘读取（`getFile`）：按旁路 meta 的 deadline 校验
///
/// 无 meta（历史裸文件 / `saveTime <= 0` 写入）按永久读取；meta 损坏时
/// 同样按永久读取（保持旧数据可读，不因元数据异常丢用户缓存）。过期 →
/// 删除数据与 meta 并返回 None。
pub fn get_file(key: &str) -> Option<String> {
    let _guard = disk_read_guard();
    let meta_path = file_meta_path(key);
    if let Ok(raw) = fs::read_to_string(&meta_path) {
        if let Ok(meta) = serde_json::from_str::<FileCacheMeta>(&raw) {
            if meta.d != 0 && now_millis() > meta.d {
                let _ = fs::remove_file(file_path(key));
                let _ = fs::remove_file(&meta_path);
                return None;
            }
        }
    }
    fs::read_to_string(file_path(key)).ok()
}

/// 删除（磁盘 + 文件缓存 + 文件缓存 meta + 内存）
pub fn delete(key: &str) {
    let _guard = disk_read_guard();
    let _ = fs::remove_file(disk_path(key));
    let _ = fs::remove_file(file_path(key));
    let _ = fs::remove_file(file_meta_path(key));
    delete_memory(key);
}

/// 是否本模块的磁盘 KV 条目文件（`<sha256 小写 hex>.json`）
///
/// 注入缓存根是宿主应用缓存目录，同目录还可能有 image_cache / audio_cache /
/// js_files 等**其他模块**的子目录与文件：清空只认本模块的命名，绝不整目录
/// `remove_dir_all(root)`（那会越界清掉图片/音频/下载沙箱）。
fn is_kv_disk_entry(path: &std::path::Path) -> bool {
    let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
        return false;
    };
    let Some(stem) = name.strip_suffix(".json") else {
        return false;
    };
    stem.len() == 64
        && stem
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// 清空全部缓存（内存层 + 磁盘 KV 条目 + `file/` 数据与 meta）
///
/// # 语义（批36 P3-4）
///
/// 对齐上游「清理缓存」对缓存类存储的整体清理口径（`ConfigViewModel`
/// `clearCache` = `BookHelp.clearCache()` + `FileUtils.delete(context.cacheDir)`，
/// 后者删掉 `cacheDir/ACache`——`cache.putFile`/ByteArray 的落点）：我方书源
/// 的 `cache.put/putFile/cacheFile` 映射与内存层统一落在本模块，故宿主
/// 「清理缓存」必须同样清空，否则这些值（含 `dev_id`、登录相关缓存）会长期
/// 残留在 `js_cache` 磁盘目录、清理后磁盘占用不降。
///
/// # 范围
///
/// - **只清本模块产物**：根目录下 `<sha256>.json` KV 条目 + `file/` 子目录
///   （数据 + `.meta.json`）。根目录本身与 image_cache / audio_cache /
///   js_files 等兄弟目录不动（上游删的是 `cacheDir` 整体，我方注入根与
///   兄弟模块共享，不能照搬整目录删除）。
/// - **保留根目录**：清空后根目录仍存在（不存在则补建），可立即继续
///   `put/putFile`；单个条目删除失败（如 Windows 文件被占用）记一次性告警
///   并继续清理其余条目（best-effort，不因单条失败回滚）。
/// - **并发安全**：持 [`DISK_OP_LOCK`] 写锁，与进行中的单条读写互斥——
///   正在使用的条目要么在清空前完成、要么在清空后重新写入，不会出现
///   「写了一半被删/删了一半被写回」的中间态。
///
/// 注意：`clear_all` 是**进程级**入口（整机所有书源共享），不适用于书籍级
/// 清理——缓存键没有书籍维度，详见 `legado-ffi` `cache_api::clear_book_cache`
/// 的范围说明。
pub fn clear_all() {
    let _guard = disk_write_guard();

    // 1) 内存层：putMemory 的纯内存值与 put 的永久值副本一并清除
    match memory_cache().lock() {
        Ok(mut cache) => cache.clear(),
        Err(poisoned) => poisoned.into_inner().clear(),
    }

    let root = disk_dir();

    // 2) 根目录 KV 条目：只删本模块命名的 `<sha256>.json`
    match fs::read_dir(&root) {
        Ok(entries) => {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_file() && is_kv_disk_entry(&path) {
                    if let Err(e) = fs::remove_file(&path) {
                        warn_once(&CLEAR_ALL_FAIL_WARNED, || {
                            eprintln!(
                                "[cache_store] 清空缓存删除条目失败 {path:?}: {e}（继续清理其余条目）"
                            );
                        });
                    }
                }
            }
        }
        // 根目录尚未创建 = 无缓存可清（首次使用即清空的正常路径）
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            warn_once(&CLEAR_ALL_FAIL_WARNED, || {
                eprintln!("[cache_store] 清空缓存读取根目录失败 {root:?}: {e}");
            });
        }
    }

    // 3) file/ 子目录：数据文件与旁路 meta 一次性整体清除
    let file_dir = root.join("file");
    if let Err(e) = fs::remove_dir_all(&file_dir) {
        if e.kind() != std::io::ErrorKind::NotFound {
            warn_once(&CLEAR_ALL_FAIL_WARNED, || {
                eprintln!("[cache_store] 清空文件缓存目录失败 {file_dir:?}: {e}");
            });
        }
    }

    // 4) 根目录保留/补建：清空后仍可继续 put/putFile
    if let Err(e) = fs::create_dir_all(&root) {
        warn_once(&CLEAR_ALL_FAIL_WARNED, || {
            eprintln!("[cache_store] 清空后补建缓存根目录失败 {root:?}: {e}");
        });
    }
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
        assert!(put_file(&k, "file-value", 0));
        assert_eq!(get_file(&k).as_deref(), Some("file-value"));
        // putFile/getFile 不进内存层
        assert!(get_from_memory(&k).is_none());
        // 永久条目不写 meta（历史裸文件同一形态）
        assert!(!file_meta_path(&k).exists());
        delete(&k);
        assert!(get_file(&k).is_none());
    }

    /// P2-1：`putFile` 第三参 saveTime 必须生效（修复前被静默丢弃、永不过期）
    #[test]
    fn test_put_file_honors_save_time() {
        let _lock = lock_cache_for_test();
        let k = unique_key("filettl");
        assert!(put_file(&k, "ttl-file", 1));
        // TTL 条目写旁路 meta，生效期内可读
        assert!(file_meta_path(&k).exists());
        assert_eq!(get_file(&k).as_deref(), Some("ttl-file"));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert!(
            get_file(&k).is_none(),
            "saveTime=1 秒过期后 getFile 必须失效"
        );
        // 过期读取顺带清理数据与 meta
        assert!(!file_path(&k).exists());
        assert!(!file_meta_path(&k).exists());
    }

    /// P2-1：`saveTime <= 0` = 永久；同键永久重写须清除旧 TTL meta
    #[test]
    fn test_put_file_permanent_clears_stale_meta() {
        let _lock = lock_cache_for_test();
        let k = unique_key("fileperm");
        // 先写 TTL 条目（产生 meta），再用缺省 saveTime 重写为永久
        assert!(put_file(&k, "ttl-first", 1));
        assert!(file_meta_path(&k).exists());
        assert!(put_file(&k, "perm-second", 0));
        assert!(
            !file_meta_path(&k).exists(),
            "永久重写必须删除旧 TTL meta（否则新值会被旧 deadline 提前判过期）"
        );
        // 负数 saveTime 与 0 同口径：永久
        assert!(put_file(&k, "perm-third", -1));
        std::thread::sleep(std::time::Duration::from_millis(1100));
        assert_eq!(
            get_file(&k).as_deref(),
            Some("perm-third"),
            "永久条目不得受过期影响"
        );
        delete(&k);
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

    /// [批36 P3-4] `clear_all`：内存层 + 根目录 KV 条目全清；
    /// 根目录保留（清空后可立即继续写入）
    #[test]
    fn test_clear_all_clears_memory_and_disk_entries() {
        let _lock = lock_cache_for_test();
        let root = unique_root("clear-all-kv");
        set_test_disk_dir_override(Some(root.clone()));
        let k_perm = unique_key("clear-kv-perm");
        let k_ttl = unique_key("clear-kv-ttl");
        let k_mem = unique_key("clear-mem");

        assert!(put(&k_perm, "perm-value", 0));
        assert!(put(&k_ttl, "ttl-value", 3600));
        put_memory(&k_mem, "memory-only");
        assert!(disk_path(&k_perm).exists());
        assert!(disk_path(&k_ttl).exists());
        assert_eq!(get_from_memory(&k_perm).as_deref(), Some("perm-value"));

        clear_all();

        assert!(
            get(&k_perm, false).is_none(),
            "永久 KV（内存 + 磁盘）应被清空"
        );
        assert!(get(&k_perm, true).is_none(), "磁盘 KV 条目应被清空");
        assert!(get(&k_ttl, true).is_none(), "TTL 磁盘 KV 条目应被清空");
        assert!(get_from_memory(&k_mem).is_none(), "纯内存值应被清空");
        assert!(!disk_path(&k_perm).exists());
        assert!(!disk_path(&k_ttl).exists());
        assert!(root.is_dir(), "清空后缓存根目录必须保留");

        // 根目录保留 → 可立即继续写入
        assert!(put(&k_perm, "after-clear", 0));
        assert_eq!(get(&k_perm, false).as_deref(), Some("after-clear"));

        delete(&k_perm);
        set_test_disk_dir_override(None);
        let _ = fs::remove_dir_all(&root);
    }

    /// [批36 P3-4] `clear_all`：`file/` 数据文件与旁路 meta 一并清空，
    /// 清空后 `putFile` 可正常继续写
    #[test]
    fn test_clear_all_clears_file_cache_and_meta() {
        let _lock = lock_cache_for_test();
        let root = unique_root("clear-all-file");
        set_test_disk_dir_override(Some(root.clone()));
        let k_perm = unique_key("clear-file-perm");
        let k_ttl = unique_key("clear-file-ttl");

        assert!(put_file(&k_perm, "permanent-file", 0));
        assert!(put_file(&k_ttl, "ttl-file", 3600));
        assert!(file_path(&k_perm).exists());
        assert!(file_meta_path(&k_ttl).exists());
        assert!(!file_meta_path(&k_perm).exists(), "永久条目不应写旁路 meta");

        clear_all();

        assert!(get_file(&k_perm).is_none(), "永久文件缓存应被清空");
        assert!(get_file(&k_ttl).is_none(), "TTL 文件缓存应被清空");
        assert!(!file_path(&k_perm).exists());
        assert!(!file_path(&k_ttl).exists());
        assert!(!file_meta_path(&k_ttl).exists(), "旁路 meta 应一并清空");
        assert!(root.is_dir(), "清空后缓存根目录必须保留");

        assert!(put_file(&k_perm, "after-clear", 0));
        assert_eq!(get_file(&k_perm).as_deref(), Some("after-clear"));

        delete(&k_perm);
        set_test_disk_dir_override(None);
        let _ = fs::remove_dir_all(&root);
    }

    /// [批36 P3-4] `clear_all` 只清本模块产物：注入根是宿主应用缓存目录，
    /// 兄弟模块目录（image_cache / js_files）与根目录非缓存命名文件不得删除，
    /// 根目录本身也不得删除
    #[test]
    fn test_clear_all_preserves_root_and_sibling_cache_dirs() {
        let _lock = lock_cache_for_test();
        let root = unique_root("clear-all-scope");
        set_test_disk_dir_override(Some(root.clone()));
        let k = unique_key("clear-scope");

        let image_dir = root.join("image_cache");
        let js_files_dir = root.join("js_files");
        fs::create_dir_all(&image_dir).expect("image_cache 目录");
        fs::create_dir_all(&js_files_dir).expect("js_files 目录");
        fs::write(image_dir.join("cover.bin"), "IMG").expect("图片缓存文件");
        fs::write(js_files_dir.join("downloaded.js"), "JS").expect("下载沙箱文件");
        fs::write(root.join("not-a-cache-entry.json"), "KEEP").expect("非缓存文件");

        assert!(put(&k, "value", 0));

        clear_all();

        assert!(!disk_path(&k).exists(), "本模块 KV 条目应被清空");
        assert_eq!(
            fs::read_to_string(image_dir.join("cover.bin")).expect("图片缓存应保留"),
            "IMG"
        );
        assert_eq!(
            fs::read_to_string(js_files_dir.join("downloaded.js")).expect("下载沙箱应保留"),
            "JS"
        );
        assert_eq!(
            fs::read_to_string(root.join("not-a-cache-entry.json")).expect("非缓存文件应保留"),
            "KEEP"
        );
        assert!(root.is_dir(), "缓存根目录本身不得删除");

        set_test_disk_dir_override(None);
        let _ = fs::remove_dir_all(&root);
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
        fs::create_dir_all(disk_path(&k2)).expect("磁盘路径预建为目录");
        assert!(!put(&k2, "v2", 0));
        assert_eq!(get_from_memory(&k2).as_deref(), Some("v2"));
        assert!(get(&k2, true).is_none());

        // put_file 失败路径：file 路径预建为目录 → 仅记日志，无内存层
        fs::create_dir_all(file_path(&k3)).expect("file 路径预建为目录");
        assert!(!put_file(&k3, "vf", 0));
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
