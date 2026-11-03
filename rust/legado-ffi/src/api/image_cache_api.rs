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

use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

use legado_core::cache_book::CachedChapter;
use legado_core::models::BookChapter;
use legado_db::{BookChapterRepository, BookRepository, CacheBookRepository};
use legado_parser::AnalyzeUrl;

use crate::db_state::with_database;

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

/// 保留清理删除失败一次性告警（单个文件失败不阻断后续清理）
static RETAIN_DELETE_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 保留清理 DB/整体失败一次性告警（避免逐章翻页刷屏）
static RETAIN_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

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

/// 读取宿主已注入的图片缓存根（未注入返回 `None`）
///
/// Web 服务接线（B3）专用最小读取入口：只返回 [`set_cache_dir`] 的注入值，
/// **不含** env 覆盖与 temp 回落——`legado-server` 的
/// `InjectedPaths::image_cache_root` 只应放行宿主明确注入的应用私有目录，
/// 不得把系统临时目录纳入本地图片白名单（未注入时白名单行为与既有完全一致）。
pub(crate) fn injected_cache_dir() -> Option<PathBuf> {
    INJECTED_DIR
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|guard| guard.clone())
}

/// 注入槽测试锁（`cfg(test)`）：`INJECTED_DIR` 为进程级全局状态，
/// 本模块测试与 `ffi` 层 Web 服务注入端到端测试须共享同一把锁串行，
/// 避免一方改写/清空注入值时另一方断言翻车
#[cfg(test)]
pub(crate) static INJECTED_DIR_TEST_LOCK: Mutex<()> = Mutex::new(());

/// 清空注入槽（`cfg(test)`：跨模块测试收尾复位进程级状态）
#[cfg(test)]
pub(crate) fn clear_cache_dir_for_test() {
    if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        *guard = None;
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
    image_dir(book_url).join(cache_file_name(url))
}

/// 图片缓存文件名（原版 `MD5Utils.md5Encode16(url) + "." + getImageSuffix(url)`）
///
/// 抽成单一构造器，保证「读/写路径」与「保留窗口保留集合」逐字节一致。
fn cache_file_name(url: &str) -> String {
    let hex = format!("{:x}", md5::compute(url));
    format!("{}.{}", &hex[8..24], image_suffix(url))
}

/// 本书图片缓存目录 `{root}/{book_dir_name(bookUrl)}/images`
fn image_dir(book_url: &str) -> PathBuf {
    cache_root().join(book_dir_name(book_url)).join(IMAGES_DIR)
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

// ─── 漫画已读窗口图片保留（批9b-3，契约 §2.46）─────────────────────────────────

/// HTML `<img ...>` 标签（大小写不敏感；`[^>]*` 天然跨行）
static IMG_TAG_RE: OnceLock<regex::Regex> = OnceLock::new();

/// `<img>` 标签内图片地址属性（同时匹配 `src`/`data-src`/`data-original`；
/// 单/双引号与无引号三态）——与 Dart `comicImgSrcRegex` 的读取面保持超集，
/// 宁可多保留（不误删阅读器可能已缓存的图片）也不漏解析。
static IMG_SRC_ATTR_RE: OnceLock<regex::Regex> = OnceLock::new();

/// 从章节正文解析图片 URL（标签内地址原样；无 `<img>` 时回退图片 URL 行）
///
/// 不做 HTML 实体解码：阅读器缓存键使用正文原始 URL 字符串（含 `&amp;`），
/// 此处必须同源，否则 md5 文件名对不上。
fn extract_image_urls(content: &str) -> Vec<String> {
    if content.trim().is_empty() {
        return Vec::new();
    }
    let tag_re = IMG_TAG_RE
        .get_or_init(|| regex::Regex::new(r"(?is)<img\b[^>]*>").expect("img 标签正则必须合法"));
    let attr_re = IMG_SRC_ATTR_RE.get_or_init(|| {
        regex::Regex::new(
            r#"(?is)(?:^|[\s/])(?:src|data-src|data-original)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
        )
        .expect("img 地址属性正则必须合法")
    });

    let mut urls = Vec::new();
    for tag in tag_re.find_iter(content) {
        for caps in attr_re.captures_iter(tag.as_str()) {
            let value = caps
                .get(1)
                .or_else(|| caps.get(2))
                .or_else(|| caps.get(3))
                .map(|m| m.as_str().trim())
                .unwrap_or("");
            if !value.is_empty() {
                urls.push(value.to_string());
            }
        }
    }
    if urls.is_empty() {
        // 兜底：部分漫画源正文就是逐行图片 URL（与 Dart
        // `parseComicImageUrls` 的 line 回退同口径）
        urls.extend(
            content
                .lines()
                .map(str::trim)
                .filter(|line| line.starts_with("http"))
                .filter(|line| looks_like_image_url(line))
                .map(str::to_string),
        );
    }
    urls
}

/// 是否「像图片 URL」（对齐 Dart `looksLikeImageUrl` 的判定集合）
fn looks_like_image_url(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    if [".m3u8", ".mp4", ".flv", ".mkv", ".webm"]
        .iter()
        .any(|ext| lower.contains(ext))
    {
        return false;
    }
    if lower.contains("ffzy-plays") || lower.contains("ffzy-play") {
        return false;
    }
    [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"]
        .iter()
        .any(|ext| lower.ends_with(ext))
        || lower.contains("/image")
        || lower.contains("/img")
        || lower.contains("/pic")
}

/// 计算保留窗口内全部图片缓存文件名
///
/// 窗口 = `chapters` 表中 `index ∈ [start_index, end_index]` 的章节；
/// 每章必须能按 `(book_url, chapter.url)` 命中非空 `cached_chapters` 正文，
/// 否则返回 `None`（调用方整次跳过清理，避免误删未缓存章节图片——原版
/// `clearComicCache` 对缺失正文仅跳过该章，属已知差异）。
///
/// 返回 `Some(空集合)` 表示窗口内正文均无图片地址（由调用方再决定跳过）。
fn retained_names_for_window(
    chapters: &[BookChapter],
    cached: &[CachedChapter],
    start_index: i32,
    end_index: i32,
) -> Option<HashSet<String>> {
    let window: Vec<&BookChapter> = chapters
        .iter()
        .filter(|c| c.index >= start_index && c.index <= end_index)
        .collect();
    if window.is_empty() {
        return None;
    }
    let by_url: HashMap<&str, &CachedChapter> =
        cached.iter().map(|c| (c.chapter_url.as_str(), c)).collect();
    let mut names = HashSet::new();
    for chapter in window {
        let cached = by_url.get(chapter.url.as_str())?;
        if cached.content.trim().is_empty() {
            return None;
        }
        for url in extract_image_urls(&cached.content) {
            let absolute = AnalyzeUrl::get_absolute_url(&chapter.url, &url);
            names.insert(cache_file_name(&absolute));
        }
    }
    Some(names)
}

/// 删除本书 `images/` 下不在保留集合内的**直接普通文件**，返回删除数
///
/// 安全边界：目录或条目为符号链接一律跳过（`file_type()` 不跟随链接），
/// 不递归子目录；单个文件删除失败跳过并一次性告警。
fn delete_unreferenced_images(book_url: &str, keep: &HashSet<String>) -> usize {
    let dir = image_dir(book_url);
    let Ok(meta) = fs::symlink_metadata(&dir) else {
        return 0; // 目录不存在：无可清理
    };
    if !meta.file_type().is_dir() {
        return 0; // 非目录（含符号链接目录）：不进入、不删除
    }
    let entries = match fs::read_dir(&dir) {
        Ok(entries) => entries,
        Err(e) => {
            if RETAIN_DELETE_FAIL_WARNED
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                log::warn!("[image_cache] 清理目录读取失败 {dir:?}: {e}（降级：本次不清理）");
            }
            return 0;
        }
    };
    let mut deleted = 0usize;
    for entry in entries.flatten() {
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue; // 子目录/符号链接/其他特殊文件不碰
        }
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue; // 非 UTF-8 文件名不可能由本模块写出，跳过
        };
        if keep.contains(&name) {
            continue;
        }
        match fs::remove_file(entry.path()) {
            Ok(()) => deleted += 1,
            Err(e) => {
                if RETAIN_DELETE_FAIL_WARNED
                    .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                    .is_ok()
                {
                    log::warn!(
                        "[image_cache] 删除过期图片失败 {:?}: {e}（跳过该文件继续；同类失败后续不再逐条记日志）",
                        entry.path()
                    );
                }
            }
        }
    }
    deleted
}

fn retain_comic_images_inner(
    book_url: &str,
    dur_index: i32,
    retain: i32,
    pre_download: i32,
) -> legado_core::LegadoResult<usize> {
    if retain <= 0 {
        return Ok(0); // 0 = 不清理（对齐原版 AppConfig.imageRetainNum 默认 0）
    }
    let start_index = dur_index.saturating_sub(retain);
    let end_index = dur_index.saturating_add(pre_download);

    let keep = with_database(|db| {
        let conn = db.connection();
        let Some(book) = BookRepository::new(conn).find_by_url(book_url)? else {
            return Ok(None); // 书不在库：无从判定窗口
        };
        if book.book_type & legado_fetcher::book_type::IMAGE == 0 {
            return Ok(None); // 非图片书不清理（对齐原版 book.isImage 门）
        }
        let chapters = BookChapterRepository::new(conn).find_by_book_url(book_url)?;
        let cached = CacheBookRepository::new(conn).get_by_book(book_url)?;
        Ok(retained_names_for_window(
            &chapters,
            &cached,
            start_index,
            end_index,
        ))
    })?;

    let Some(keep) = keep else {
        return Ok(0);
    };
    if keep.is_empty() {
        // 窗口正文一个图片地址都没解析出来：视作解析/缓存异常，整次跳过，
        // 不把本书 images 目录清空（安全性加法式收紧）。
        return Ok(0);
    }
    Ok(delete_unreferenced_images(book_url, &keep))
}

/// 删除漫画书不在「已读保留窗口」内的图片缓存（对齐原版
/// `BookHelp.clearComicCache` L204-235；契约 §2.46 `retainComicImages`）
///
/// - `retain <= 0` → 不清理，返回 0（原版 `imageRetainNum == 0` 语义）；
/// - 非图片书 → 返回 0；
/// - 窗口 `[dur_index - retain, dur_index + pre_download]`（start 夹 0）；
///   窗口内任一章节缺 `cached_chapters` 正文或正文空白 → 整次跳过返回 0；
/// - 正文 `<img src>`（含 `data-src`/`data-original` 与 URL 行回退）按章节
///   URL 绝对化，保留名 = `md5_16(url).suffix`（与读写路径同一构造器）；
/// - 仅删除本书 `images/` 下的直接普通文件，不递归、不跟随符号链接；
/// - DB/IO 失败降级返回 0（一次性日志），不抛异常——缓存是加速器不是数据源。
pub fn retain_comic_images(
    book_url: &str,
    dur_index: i32,
    retain: i32,
    pre_download: i32,
) -> usize {
    match retain_comic_images_inner(book_url, dur_index, retain, pre_download) {
        Ok(deleted) => deleted,
        Err(e) => {
            if RETAIN_FAIL_WARNED
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_ok()
            {
                log::warn!(
                    "[image_cache] 漫画图片保留清理失败 book={book_url:?} dur={dur_index} retain={retain} pre={pre_download}: {e}（降级：本次不删除；同类失败后续不再逐条记日志）"
                );
            }
            0
        }
    }
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use std::sync::atomic::AtomicUsize;
    use std::sync::MutexGuard;

    /// 进程级唯一临时目录计数器
    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    /// 测试串行锁：`INJECTED_DIR`/`TEST_DIR_OVERRIDE` 为进程级状态，
    /// 并行测试互踩 → 触碰进程级目录状态的测试先持锁（对齐 cache_store 先例；
    /// 锁提升到模块级与 ffi 层 Web 注入端到端测试共享）
    fn test_lock() -> MutexGuard<'static, ()> {
        INJECTED_DIR_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner())
    }

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
        let _lock = test_lock();
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
        let _lock = test_lock();
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
        let _lock = test_lock();
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
        let _lock = test_lock();
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
        let _lock = test_lock();
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
        let _lock = test_lock();
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
        clear_cache_dir_for_test();
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 读取入口（Web 服务注入用）：已注入时返回注入值
    #[test]
    fn injected_cache_dir_returns_injected_value() {
        let _lock = test_lock();
        clear_cache_dir_for_test();
        let root = unique_root("getter");
        set_cache_dir(root.to_str().unwrap());
        assert_eq!(
            injected_cache_dir(),
            Some(root.clone()),
            "读取入口应返回宿主注入的图片缓存根"
        );
        clear_cache_dir_for_test();
    }

    // 读取入口：未注入时回退 None（不得回落 temp 目录，避免白名单放大）
    #[test]
    fn injected_cache_dir_none_when_unset() {
        let _lock = test_lock();
        clear_cache_dir_for_test();
        assert_eq!(
            injected_cache_dir(),
            None,
            "未注入时读取入口必须返回 None（不由 temp 回落伪造注入值）"
        );
    }

    // ─── 批9b-3：漫画图片保留窗口 ─────────────────────────────────────────────

    fn chapter(index: i32, url: &str) -> BookChapter {
        BookChapter {
            index,
            url: url.to_string(),
            book_url: "https://a.com/book".to_string(),
            ..BookChapter::default()
        }
    }

    fn cached(book_url: &str, index: i32, url: &str, content: &str) -> CachedChapter {
        CachedChapter {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index: index,
            chapter_title: format!("第{}章", index + 1),
            chapter_url: url.to_string(),
            content: content.to_string(),
            cached_at: 0,
            size_bytes: content.len() as i64,
        }
    }

    // 标签解析：双/单/无引号 + data-src/data-original 超集
    #[test]
    fn extract_image_urls_supports_quote_variants() {
        let content = r#"<p><img src="/a/1.webp"><img data-src='https://cdn/2.jpg'><img data-original=3.gif></p>"#;
        assert_eq!(
            extract_image_urls(content),
            vec!["/a/1.webp", "https://cdn/2.jpg", "3.gif"],
            "img src/data-src/data-original（单/双/无引号）均应解析"
        );
    }

    // 无 <img> 时回退逐行图片 URL（与 Dart parseComicImageUrls 同口径）
    #[test]
    fn extract_image_urls_line_fallback() {
        let content = "https://cdn.example.com/a/b.jpg\nhttps://cdn.example.com/v.mp4\nnot-a-url";
        assert_eq!(
            extract_image_urls(content),
            vec!["https://cdn.example.com/a/b.jpg"],
            "URL 行回退应识别图片后缀并排除视频"
        );
    }

    // 窗口内保留/窗口外删：保留集合只含窗口章图片
    #[test]
    fn retained_names_only_cover_window() {
        let book = "https://a.com/book";
        let chapters = vec![
            chapter(0, "https://h.com/ch/0"),
            chapter(1, "https://h.com/ch/1"),
            chapter(2, "https://h.com/ch/2"),
            chapter(3, "https://h.com/ch/3"),
        ];
        let cached_rows = (0..4)
            .map(|i| {
                cached(
                    book,
                    i,
                    &format!("https://h.com/ch/{i}"),
                    &format!("<img src=\"https://cdn.com/{i}.jpg\">"),
                )
            })
            .collect::<Vec<_>>();
        let keep = retained_names_for_window(&chapters, &cached_rows, 1, 2)
            .expect("窗口内章节均有正文，应返回保留集合");
        assert_eq!(keep.len(), 2, "窗口 [1,2] 只保留两章图片");
        assert!(keep.contains(&cache_file_name("https://cdn.com/1.jpg")));
        assert!(keep.contains(&cache_file_name("https://cdn.com/2.jpg")));
        assert!(!keep.contains(&cache_file_name("https://cdn.com/0.jpg")));
        assert!(!keep.contains(&cache_file_name("https://cdn.com/3.jpg")));
    }

    // 窗口内任一章节无缓存行 → 整次跳过（None）
    #[test]
    fn retained_names_skip_when_window_content_missing() {
        let book = "https://a.com/book";
        let chapters = vec![
            chapter(1, "https://h.com/ch/1"),
            chapter(2, "https://h.com/ch/2"),
        ];
        let cached_rows = vec![cached(
            book,
            1,
            "https://h.com/ch/1",
            "<img src=\"https://cdn.com/1.jpg\">",
        )];
        assert_eq!(
            retained_names_for_window(&chapters, &cached_rows, 1, 2),
            None,
            "窗口章缺正文时必须整次跳过（避免误删未缓存章节图片）"
        );
    }

    // 窗口内正文空白 → 整次跳过（None）
    #[test]
    fn retained_names_skip_when_content_blank() {
        let book = "https://a.com/book";
        let chapters = vec![chapter(2, "https://h.com/ch/2")];
        let cached_rows = vec![cached(book, 2, "https://h.com/ch/2", "  \n\t ")];
        assert_eq!(
            retained_names_for_window(&chapters, &cached_rows, 1, 2),
            None,
            "空白正文视为缺失内容，必须整次跳过"
        );
    }

    // 窗口无章节 → None（dur 越界/目录为空时不清）
    #[test]
    fn retained_names_empty_window_skips() {
        let chapters = vec![chapter(0, "https://h.com/ch/0")];
        assert_eq!(retained_names_for_window(&chapters, &[], 5, 9), None);
    }

    // 相对/协议相对/绝对 URL 绝对化后参与 md5 命名
    #[test]
    fn retained_names_absolutize_urls() {
        let book = "https://a.com/book";
        let chapters = vec![chapter(0, "https://site.com/manga/ch/5.html")];
        let cached_rows = vec![cached(
            book,
            0,
            "https://site.com/manga/ch/5.html",
            "<img src=\"/img/a.png\"><img src=\"https://cdn.com/b.webp?x=1\"><img src=\"//cdn.com/c.jpg\">",
        )];
        let keep = retained_names_for_window(&chapters, &cached_rows, 0, 0)
            .expect("单章窗口应返回保留集合");
        assert_eq!(keep.len(), 3);
        assert!(keep.contains(&cache_file_name("https://site.com/img/a.png")));
        assert!(keep.contains(&cache_file_name("https://cdn.com/b.webp?x=1")));
        assert!(keep.contains(&cache_file_name("https://cdn.com/c.jpg")));
    }

    // 保留名构造器与真实落盘文件名逐字节一致（md5_16 + suffix）
    #[test]
    fn cache_file_name_matches_image_file_path() {
        let url = "https://cdn.com/img/page-001.WEBP?v=2";
        let path = image_file_path("https://a.com/book/7", url);
        assert_eq!(
            path.file_name().and_then(|n| n.to_str()),
            Some(cache_file_name(url).as_str()),
            "保留集合文件名必须与读写路径同名"
        );
        assert!(
            cache_file_name(url).ends_with(".WEBP"),
            "后缀沿用原版 UrlUtil.getSuffix 规则（大小写保留）"
        );
    }

    // 删除只作用于 images 下直接普通文件：保留名留下、子目录不递归
    #[test]
    fn delete_unreferenced_only_direct_files() {
        let _lock = test_lock();
        let root = unique_root("retain-delete");
        set_test_root(&root);
        let book = "https://a.com/book/retain";
        let dir = image_dir(book);
        fs::create_dir_all(dir.join("nested")).unwrap();
        fs::write(dir.join("keep.jpg"), b"keep").unwrap();
        fs::write(dir.join("drop.jpg"), b"drop").unwrap();
        fs::write(dir.join("nested").join("inner.jpg"), b"inner").unwrap();

        let keep = HashSet::from(["keep.jpg".to_string()]);
        assert_eq!(delete_unreferenced_images(book, &keep), 1);
        assert!(dir.join("keep.jpg").exists(), "保留集合内文件不得删除");
        assert!(!dir.join("drop.jpg").exists(), "集合外文件应删除");
        assert!(
            dir.join("nested").join("inner.jpg").exists(),
            "子目录内容不得递归删除"
        );
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // 目录不存在 → 0（幂等、不报错）
    #[test]
    fn delete_unreferenced_missing_dir_returns_zero() {
        let _lock = test_lock();
        let root = unique_root("retain-missing");
        set_test_root(&root);
        assert_eq!(
            delete_unreferenced_images("https://a.com/book/none", &HashSet::new()),
            0
        );
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // retain=0 不清理（且不触碰 DB），文件保持
    #[test]
    fn retain_zero_keeps_files() {
        let _lock = test_lock();
        let root = unique_root("retain-zero");
        set_test_root(&root);
        let book = "https://a.com/book/zero";
        let dir = image_dir(book);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("old.jpg"), b"old").unwrap();
        assert_eq!(
            retain_comic_images(book, 10, 0, 20),
            0,
            "retain=0 必须直接返回 0（不清理）"
        );
        assert!(dir.join("old.jpg").exists());
        let _ = fs::remove_dir_all(&root);
        clear_test_root();
    }

    // 路径安全：bookUrl 净化后始终是单层安全目录名（无分隔符/父目录）
    #[test]
    fn book_dir_name_is_single_safe_component() {
        let name = book_dir_name("../../etc/passwd");
        assert!(!name.contains('/'), "不得含路径分隔符: {name}");
        assert!(!name.contains('\\'), "不得含 Windows 分隔符: {name}");
        assert!(!name.contains(':'), "不得含盘符/ADS 分隔符: {name}");
        assert_eq!(
            std::path::Path::new(&name).components().count(),
            1,
            "净化后必须为单层目录名: {name}"
        );
    }
}
