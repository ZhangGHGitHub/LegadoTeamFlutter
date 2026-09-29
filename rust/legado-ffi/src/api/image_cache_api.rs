//! 图片磁盘缓存（P4-2a，契约 §2.46，对齐原版 BookHelp.saveImage/getImage）
//!
//! 原版取证（`app/src/main/java/io/legado/app/help/book/BookHelp.kt`）：
//! - `getImage(book, src)` L392：路径 =
//!   `downloadDir/book_cache/{book.getFolderName()}/images/{md5Encode16(src)}.{getImageSuffix(src)}`
//!   （`cacheFolderName = "book_cache"` L114、`cacheImageFolderName = "images"` L115）
//! - `MD5Utils.md5Encode16`：MD5 小写 hex 的 `substring(8, 24)`（中段 16 字符）
//! - `UrlUtil.getSuffix(src, "jpg")`：URL 末段（去 query/fragment）`.` 后后缀，
//!   须匹配 `[a-zA-Z0-9]` 且长度 ≤5，否则缺省 `jpg`
//! - `writeImage` L399：创建目录 + 写字节（失败抛 IO 异常）
//! - `saveImage` L347：`isImageExist` 命中即跳过；下载失败仅记 AppLog **不抛异常**
//! - `MangaVH.mangaImagePath` L31-34：本地优先——缓存文件存在取本地，否则走网络
//!
//! 本书加法式简化（主代理批准）：
//! - 缓存根目录经 [`set_cache_dir`] 进程注入（FFI `set_image_cache_dir`，§1.6.1，
//!   与 JS 缓存 `legado_js::host_api::cache_store::set_cache_dir` 同型；Dart 启动
//!   注入应用私有缓存目录下 `image_cache` 子目录）。解析优先级对齐 cache_store：
//!   env [`CACHE_DIR_ENV`]（非空，测试隔离用；`cfg(test)` 下由显式测试槽整体旁路）
//!   > 宿主注入目录 > `<temp_dir>/legado-image-cache`（回落时一次性告警）。
//! - 书目录以 `bookUrl` 为键（原版以 `book.getFolderName()` 为键）：非法文件名字符
//!   替换 `_`、截断 64 字符 + `_{md5_8(bookUrl)}` 防截断碰撞（不同书互不串缓存）。
//! - 写失败/读失败均**静默降级**（save 返回 false、get 返回 None，一次性日志），
//!   不抛异常——缓存是加速器不是数据源，失败必须不影响在线加载（对齐原版
//!   saveImage catch 仅记日志语义）。

use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

/// 图片缓存磁盘目录环境变量名（测试隔离用，非空即覆盖）
pub const CACHE_DIR_ENV: &str = "LEGADO_IMAGE_CACHE_DIR";

/// 缺省回落根目录（未注入且无 env 时）
const DEFAULT_ROOT: &str = "legado-image-cache";

/// 图片子目录名（对齐原版 `cacheImageFolderName = "images"`）
const IMAGES_DIR: &str = "images";

/// 书目录名最大字符数（截断后追加 md5_8 防碰撞）
const BOOK_DIR_MAX_CHARS: usize = 64;

/// 宿主注入的图片缓存根目录（P4-2a，FFI `set_image_cache_dir` 目标）
static INJECTED_DIR: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// `cfg(test)` 显式测试覆盖槽（整体旁路 env 分支：并行测试不得操作
/// 进程级环境变量——对齐 cache_store 的 [`crate`] 先例）
#[cfg(test)]
static TEST_DIR_OVERRIDE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 写盘失败一次性告警（避免逐条刷屏）
static WRITE_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 读盘失败一次性告警
static READ_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 回落系统 temp 目录时的一次性告警（对齐 cache_store [`DEFAULT_DIR_WARNED`] 先例，
/// 契约 §1.6.1/§2.46「未注入时回落 `<temp_dir>/legado-image-cache`（一次性告警）」）
static DEFAULT_DIR_WARNED: AtomicBool = AtomicBool::new(false);

/// 注入图片磁盘缓存根目录（宿主注入点，P4-2a）
///
/// 目录解析优先级见模块文档：env [`CACHE_DIR_ENV`] > 注入目录 > 缺省 temp 目录。
/// 后续全部 `save_image_cache`/`get_image_cache` 读写生效。
pub fn set_cache_dir(path: &str) {
    if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        *guard = Some(PathBuf::from(path));
    }
}

/// 图片缓存根目录（env 覆盖 > 宿主注入 > 缺省 `<temp_dir>/legado-image-cache`）
fn cache_root() -> PathBuf {
    #[cfg(test)]
    {
        if let Ok(guard) = TEST_DIR_OVERRIDE.get_or_init(|| Mutex::new(None)).lock() {
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
    let root = std::env::temp_dir().join(DEFAULT_ROOT);
    if DEFAULT_DIR_WARNED
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        log::warn!(
            "[image_cache] 未注入宿主图片缓存目录（set_image_cache_dir）且未设 env {CACHE_DIR_ENV}——回落系统临时目录 {root:?}（图片缓存随系统 temp 清理而丢失，宿主应在初始化时注入应用私有缓存目录，对齐 cache_store 先例）"
        );
    }
    root
}

/// 书目录名（对齐原版 `book.getFolderName()` 的「书级隔离目录」语义，
/// 键由 folderName 换为 bookUrl）：非法文件名字符替换 `_`，截断
/// [`BOOK_DIR_MAX_CHARS`] 字符后追加 `_{md5_8(bookUrl)}` 防截断碰撞。
fn book_dir_name(book_url: &str) -> String {
    let sanitized: String = book_url
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let truncated: String = sanitized.chars().take(BOOK_DIR_MAX_CHARS).collect();
    let digest = format!("{:x}", md5::compute(book_url));
    format!("{truncated}_{}", &digest[0..8])
}

/// 图片文件后缀（对齐原版 `UrlUtil.getSuffix(src, "jpg")`）：
/// URL 去 query/fragment 后末段 `.` 之后部分，须匹配 `[a-zA-Z0-9]`
/// 且长度 ≤5，否则缺省 `jpg`。
fn image_suffix(url: &str) -> String {
    let without_query = url.split('?').next().unwrap_or("");
    let without_frag = without_query.split('#').next().unwrap_or("");
    let last_segment = without_frag.rsplit('/').next().unwrap_or("");
    let suffix = match last_segment.rfind('.') {
        Some(i) => &last_segment[i + 1..],
        None => "",
    };
    if suffix.is_empty() || suffix.len() > 5 || !suffix.chars().all(|c| c.is_ascii_alphanumeric()) {
        "jpg".to_string()
    } else {
        suffix.to_string()
    }
}

/// 图片缓存文件路径（对齐原版 `BookHelp.getImage` L392 路径结构）：
/// `{root}/{book_dir_name(bookUrl)}/images/{md5_mid16(url)}.{suffix}`
///
/// `md5_mid16` = MD5 小写 hex 的 `[8..24]` 中段 16 字符（原版
/// `MD5Utils.md5Encode16` = `substring(8, 24)`，逐字节对齐）。
fn image_file_path(book_url: &str, url: &str) -> PathBuf {
    let hex = format!("{:x}", md5::compute(url));
    let mid16 = &hex[8..24];
    cache_root()
        .join(book_dir_name(book_url))
        .join(IMAGES_DIR)
        .join(format!("{mid16}.{}", image_suffix(url)))
}

/// 写入图片缓存（对齐原版 `BookHelp.writeImage` L399）
///
/// 成功返回 `true`；目录创建失败/写盘失败返回 `false`（静默降级 +
/// 一次性日志，**不抛异常**——缓存失败不影响在线加载）。
pub fn save_image_cache(book_url: &str, url: &str, bytes: &[u8]) -> bool {
    let file = image_file_path(book_url, url);
    if let Some(parent) = file.parent() {
        if let Err(e) = fs::create_dir_all(parent) {
            if WRITE_FAIL_WARNED
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                log::warn!(
                    "[image_cache] 目录创建失败 {parent:?}: {e}（降级：本次不落盘，不影响在线加载；同类失败后续不再逐条记日志）"
                );
            }
            return false;
        }
    }
    match fs::write(&file, bytes) {
        Ok(()) => true,
        Err(e) => {
            if WRITE_FAIL_WARNED
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                log::warn!(
                    "[image_cache] 写盘失败 {file:?}: {e}（降级：本次不落盘，不影响在线加载；同类失败后续不再逐条记日志）"
                );
            }
            false
        }
    }
}

/// 读取图片缓存（对齐原版 `BookHelp.getImage`/`isImageExist` 的本地优先语义）
///
/// 命中返回图片字节；未命中返回 `None`；读失败（非 NotFound 的 IO 错误）
/// 降级 `None`（静默 + 一次性日志）——调用方一律回落网络加载。
pub fn get_image_cache(book_url: &str, url: &str) -> Option<Vec<u8>> {
    let file = image_file_path(book_url, url);
    match fs::read(&file) {
        Ok(bytes) => Some(bytes),
        Err(e) if matches!(e.kind(), io::ErrorKind::NotFound) => None,
        Err(e) => {
            if READ_FAIL_WARNED
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                log::warn!(
                    "[image_cache] 读盘失败 {file:?}: {e}（降级：按未命中处理走网络加载；同类失败后续不再逐条记日志）"
                );
            }
            None
        }
    }
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use std::sync::atomic::AtomicUsize;

    /// 测试串行锁：`INJECTED_DIR`/`TEST_DIR_OVERRIDE` 为进程级状态，
    /// 并行测试互踩 → 触碰进程级目录状态的测试先持锁（对齐 cache_store 先例）
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    /// 进程级唯一临时根目录（测试收尾 remove_dir_all 清理）
    fn unique_root(tag: &str) -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "legado-image-cache-test-{}-{}-{}",
            std::process::id(),
            n,
            tag
        ))
    }

    /// 设置测试目录覆盖槽（`cfg(test)` 专属，旁路 env 分支）
    fn set_test_root(dir: &Path) {
        if let Ok(mut guard) = TEST_DIR_OVERRIDE.get_or_init(|| Mutex::new(None)).lock() {
            *guard = Some(dir.to_path_buf());
        }
    }

    /// 清空测试目录覆盖槽（复位进程级状态，避免串行测试互踩）
    fn clear_test_root() {
        if let Ok(mut guard) = TEST_DIR_OVERRIDE.get_or_init(|| Mutex::new(None)).lock() {
            *guard = None;
        }
    }

    // 存/取/命中：roundtrip
    #[test]
    fn save_get_roundtrip() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("roundtrip");
        set_test_root(&root);
        let bytes: Vec<u8> = (0..256u16).map(|i| (i % 251) as u8).collect();
        assert!(
            save_image_cache("https://a.com/book/1", "https://cdn.com/p1.webp", &bytes),
            "写入应成功"
        );
        let got = get_image_cache("https://a.com/book/1", "https://cdn.com/p1.webp");
        assert_eq!(got.as_deref(), Some(bytes.as_slice()), "命中应返回原字节");
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // 未命中：全新目录 get 返回 None
    #[test]
    fn get_miss_returns_none() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("miss");
        set_test_root(&root);
        assert!(
            get_image_cache("https://a.com/book/9", "https://cdn.com/x.jpg").is_none(),
            "未写入应未命中"
        );
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // MD5 命名：文件落在 {root}/{bookdir}/images/{md5_mid16(url)}.{suffix}
    #[test]
    fn md5_naming_layout() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("md5");
        set_test_root(&root);
        let url = "https://cdn.com/img/page-001.webp?v=2";
        assert!(save_image_cache("https://a.com/book/7", url, b"png-bytes"));
        let hex = format!("{:x}", md5::compute(url));
        let expected = root
            .join(book_dir_name("https://a.com/book/7"))
            .join(IMAGES_DIR)
            .join(format!("{}.webp", &hex[8..24]));
        assert!(
            expected.exists(),
            "文件应落在 MD5 中段 16 字符命名路径：{expected:?}"
        );
        assert_eq!(fs::read(&expected).unwrap(), b"png-bytes");
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // 后缀推导（对齐原版 UrlUtil.getSuffix(src, "jpg")）
    #[test]
    fn suffix_rules() {
        assert_eq!(image_suffix("https://x.com/a/b.webp?q=1"), "webp");
        assert_eq!(image_suffix("https://x.com/a/b.PNG"), "PNG");
        assert_eq!(image_suffix("https://x.com/a/b?sig=abc.def"), "jpg");
        assert_eq!(image_suffix("https://x.com/a/b"), "jpg");
        assert_eq!(image_suffix("https://x.com/a/b.gif#frag"), "gif");
        // 后缀 >5 字符（5 字符合法）或含非法字符 → 缺省 jpg
        assert_eq!(image_suffix("https://x.com/a/b.tiffy"), "tiffy");
        assert_eq!(image_suffix("https://x.com/a/b.tiffy6"), "jpg");
        assert_eq!(image_suffix("https://x.com/a/b.tar.gz"), "gz");
        assert_eq!(image_suffix("https://x.com/a/b.a_b"), "jpg");
        // 末段以 . 结尾（空后缀）→ 缺省 jpg
        assert_eq!(image_suffix("https://x.com/a/b."), "jpg");
    }

    // 写失败降级：根目录被普通文件占用 → create_dir_all 失败
    #[test]
    fn write_fail_degrades_to_false() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("writefail");
        fs::create_dir_all(root.parent().unwrap()).unwrap();
        fs::write(&root, b"i-am-a-file").unwrap();
        set_test_root(&root);
        assert!(
            !save_image_cache("https://a.com/book/2", "https://cdn.com/y.jpg", b"x"),
            "根目录被文件占用时写入应降级 false（不抛异常）"
        );
        assert!(
            get_image_cache("https://a.com/book/2", "https://cdn.com/y.jpg").is_none(),
            "写失败后读取应未命中"
        );
        fs::remove_file(&root).ok();
    }

    // 路径隔离：不同 bookUrl 互不串缓存
    #[test]
    fn path_isolation_by_book_url() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("isolation");
        set_test_root(&root);
        let url = "https://cdn.com/same.jpg";
        assert!(save_image_cache("https://a.com/book/A", url, b"bookA"));
        assert_eq!(
            get_image_cache("https://a.com/book/A", url).as_deref(),
            Some(b"bookA".as_slice()),
            "书 A 应命中自己的缓存"
        );
        assert!(
            get_image_cache("https://a.com/book/B", url).is_none(),
            "书 B 不得读到书 A 的缓存（目录按 bookUrl 隔离）"
        );
        // 两书目录名不同且各自含 md5_8 后缀
        assert_ne!(
            book_dir_name("https://a.com/book/A"),
            book_dir_name("https://a.com/book/B")
        );
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // 超长 bookUrl：截断 + md5_8 后缀保证不同 URL 不同目录
    #[test]
    fn long_book_url_truncation_isolated() {
        let long_a = "https://site.example/very/long/path/".to_string() + &"a".repeat(200);
        let long_b = long_a.replace('a', "b");
        assert_ne!(
            book_dir_name(&long_a),
            book_dir_name(&long_b),
            "截断后 md5_8 后缀必须区分仅尾部不同的 bookUrl"
        );
    }

    // set_cache_dir 注入：后续读写落注入目录
    #[test]
    fn injected_dir_used() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("injected");
        // 前置清空覆盖槽：`cfg(test)` 下覆盖槽优先于注入槽，
        // 若残留前序测试的目录将旁路本测试的断言
        clear_test_root();
        set_cache_dir(root.to_str().unwrap());
        assert!(save_image_cache(
            "https://a.com/book/3",
            "https://cdn.com/z.jpg",
            b"z"
        ));
        assert_eq!(
            get_image_cache("https://a.com/book/3", "https://cdn.com/z.jpg").as_deref(),
            Some(b"z".as_slice())
        );
        // 书目录名 = 净化+截断+md5_8 后缀（与 image_file_path 同一构造器）
        let book_dir = root
            .join(book_dir_name("https://a.com/book/3"))
            .join(IMAGES_DIR);
        assert!(
            book_dir.exists(),
            "文件应落在注入根目录下的书级目录：{book_dir:?}"
        );
        // 复位注入槽为 None（不污染其他测试）
        if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
            *guard = None;
        }
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }
}
