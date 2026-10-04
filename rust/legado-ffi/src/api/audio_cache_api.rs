//! 音频章节文件缓存（B1，契约 §2.47，对齐原版 AudioCacheManager / AudioCachePolicy）
//!
//! 原版取证（`app/src/main/java/io/legado/app/`）：
//! - `model/AudioCacheKey.kt:20-23`：键 = `MD5Utils.md5Encode16(chapterUrl.ifBlank { chapterTitle })`
//!   —— 取**章节 URL**（为空才退回标题）的 MD5 小写 hex 中段 16 字符（`[8,24)`）；
//!   UTF-8 字节、**不 trim、大小写敏感**；**不含** url+title 拼接、**不含** bookUrl
//! - `help/audio/AudioCacheManager.kt:205-212,223-230`：书目录 =
//!   `{缓存根}/book_{md5Encode16(bookUrl)}`（原版缓存根为 SAF tree 下的 `LegadoAudioCache`、
//!   即时计算无映射表；本书缓存根为宿主注入的应用私有目录）
//! - `help/audio/AudioCacheManager.kt:201-203,358-373`：命中 = 文件名 key 匹配
//!   **且** `.complete` 标记存在 **且** 音频文件 `size > 0`；同名多条取 `lastModified` 最新
//! - `help/audio/AudioCachePolicy.kt:11-13,100-110`：五段式文件名
//!   `^([0-9]{5,})_([0-9a-f]{16})_.+_([0-9a-f]{16})_([0-9a-f]{8})\.([a-z0-9]{2,6})$`
//!   + 扩展名白名单（`audio` 或音频后缀，`:15-18`）；title / playUrlHash / rev 三段不参与命中
//! - `help/audio/AudioCacheManager.kt:338-356`：清理按 key 删数据文件与 `.complete` 标记
//!
//! 本书口径（契约 §2.47，用户 2026-10-04 裁决）：
//! - **只读面 + 清理面，不设写入面**：原版写入仅发生于预下载服务
//!   `AudioCacheService.kt:217`（全仓唯一 `cacheChapter` 调用方），播放链从不写
//!   （`AudioPlay.kt:388-413` 第一步查缓存、命中完全跳网络）
//! - 缓存根经 [`set_cache_dir`] 进程注入（FFI `set_audio_cache_dir`，与
//!   `image_cache_api` 同型）：env [`CACHE_DIR_ENV`]（非空，测试隔离用；`cfg(test)`
//!   下由显式测试槽整体旁路）> 宿主注入目录 > `<temp_dir>/legado-audio-cache`
//!   （回落时一次性告警）
//! - **失败一律降级**（查询 false、列举空数组、清理返回实际删除计数），不抛 FFI
//!   异常——缓存是加速器不是数据源（同 §2.46 口径）
//! - 旧键 `${bookUrl.hashCode}_$i.audio`（重构版自创、无读取方）不读不迁移：
//!   不匹配五段式正则且无 `.complete`，扫描时天然跳过

use std::collections::{BTreeSet, HashSet};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::SystemTime;

/// 音频缓存磁盘目录环境变量名（测试隔离用，非空即覆盖）
pub const CACHE_DIR_ENV: &str = "LEGADO_AUDIO_CACHE_DIR";

/// 缺省回落根目录（未注入且无 env 时）
const DEFAULT_ROOT: &str = "legado-audio-cache";

/// `.complete` 完成标记后缀（对齐原版 `AudioCacheManager.COMPLETE_SUFFIX`）
const COMPLETE_SUFFIX: &str = ".complete";

/// 五段式缓存文件名正则（对齐原版 `AudioCachePolicy.cacheFileRegex`；
/// 原版 Kotlin/Java `\d` 为 ASCII 数字，此处显式 `[0-9]` 防 Rust Unicode `\d` 语义偏差）
const CACHE_FILE_PATTERN: &str =
    r"^([0-9]{5,})_([0-9a-f]{16})_.+_([0-9a-f]{16})_([0-9a-f]{8})\.([a-z0-9]{2,6})$";

/// 音频扩展名白名单（对齐原版 `AudioCachePolicy.audioExtensions:15-18`；
/// `audio` 为原版 detectExtension 的兜底扩展名）
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac", "webm", "amr", "3gp",
];

/// 宿主注入的音频缓存根目录（B1，FFI `set_audio_cache_dir` 目标）
static INJECTED_DIR: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// `cfg(test)` 显式测试覆盖槽（整体旁路 env 分支：并行测试不得操作
/// 进程级环境变量——对齐 image_cache_api 先例）
#[cfg(test)]
static TEST_DIR_OVERRIDE: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

/// 回落系统 temp 目录时的一次性告警（契约 §2.47，对齐 image_cache 先例）
static DEFAULT_DIR_WARNED: AtomicBool = AtomicBool::new(false);

/// 目录扫描失败一次性告警（权限/IO 错误降级为空结果）
static SCAN_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 注入音频磁盘缓存根目录（宿主注入点，B1）
///
/// 目录解析优先级见模块文档：env [`CACHE_DIR_ENV`] > 注入目录 > 缺省 temp 目录。
/// 后续全部查询/列举/清理以此根目录为准。
pub fn set_cache_dir(path: &str) {
    if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
        *guard = Some(PathBuf::from(path));
    }
}

/// 音频缓存根目录（env 覆盖 > 宿主注入 > 缺省 `<temp_dir>/legado-audio-cache`）
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
            "[audio_cache] 未注入宿主音频缓存目录（set_audio_cache_dir）且未设 env {CACHE_DIR_ENV}——回落系统临时目录 {root:?}（音频缓存随系统 temp 清理而丢失，宿主应在初始化时注入应用私有缓存目录，对齐 image_cache/cache_store 先例）"
        );
    }
    root
}

/// MD5 小写 hex 中段 16 字符（对齐原版 `MD5Utils.md5Encode16` = `hex[8..24)`，
/// 与 image_cache_api / legado-js `encoding::md5_encode_16` 同口径）
fn md5_mid16(input: &str) -> String {
    let hex = format!("{:x}", md5::compute(input));
    hex[8..24].to_string()
}

/// 对齐 Kotlin `Char.isWhitespace()`（Java `Character.isWhitespace`）：
/// Unicode 空白，但排除 NBSP 系（U+00A0 / U+2007 / U+202F）与 NEL U+0085
/// （后四者 Rust `char::is_whitespace()` 为 true 而 Java 为 false，逐字符纠偏）
fn kotlin_char_is_whitespace(c: char) -> bool {
    match c {
        '\u{00A0}' | '\u{2007}' | '\u{202F}' | '\u{0085}' => false,
        '\u{0009}'..='\u{000D}' | '\u{001C}'..='\u{001F}' => true,
        c => c.is_whitespace(),
    }
}

/// 对齐 Kotlin `String.isBlank()`（空串或全空白字符）
fn kotlin_is_blank(s: &str) -> bool {
    s.chars().all(kotlin_char_is_whitespace)
}

/// 章节缓存键（对齐原版 `AudioCacheKey.from(chapterUrl, chapterTitle)`）：
/// `md5Encode16(chapterUrl.ifBlank { chapterTitle })`——不 trim、大小写敏感。
/// 入参顺序便于与 FFI 面一致，`chapter_url` 为空/纯空白时退回标题。
pub fn cache_key16(chapter_url: &str, chapter_title: &str) -> String {
    let identity = if kotlin_is_blank(chapter_url) {
        chapter_title
    } else {
        chapter_url
    };
    md5_mid16(identity)
}

/// 书级缓存目录（对齐原版 `AudioCacheManager.getBookFolder` L210：
/// `book_{md5Encode16(bookUrl)}`，即时计算、无映射表）
fn book_dir(book_url: &str) -> PathBuf {
    cache_root().join(format!("book_{}", md5_mid16(book_url)))
}

/// 五段式缓存文件名解析结果（title / playUrlHash / rev 三段不参与命中判定）
#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedCacheFileName {
    /// 章节序号（正则第一段，`toIntOrNull` 溢出即视为不匹配）
    chapter_index: i32,
    /// 缓存键（正则第二段，小写 16 hex）
    key16: String,
}

/// 解析五段式缓存文件名（对齐原版 `AudioCachePolicy.parseFileName`）：
/// 正则不匹配 / 扩展名不在白名单 / 章节序号溢出 → `None`（跳过该文件）
fn parse_cache_file_name(name: &str) -> Option<ParsedCacheFileName> {
    let regex = CACHE_FILE_REGEX
        .get_or_init(|| regex::Regex::new(CACHE_FILE_PATTERN).ok())
        .as_ref()?;
    let caps = regex.captures(name)?;
    let chapter_index = caps.get(1)?.as_str().parse::<i32>().ok()?;
    let key16 = caps.get(2)?.as_str().to_string();
    let extension = caps.get(5)?.as_str();
    if extension != "audio" && !AUDIO_EXTENSIONS.contains(&extension) {
        return None;
    }
    Some(ParsedCacheFileName {
        chapter_index,
        key16,
    })
}

/// 五段式正则（进程级编译一次；编译失败降级为不匹配——不可能失败，但避免 panic）
static CACHE_FILE_REGEX: OnceLock<Option<regex::Regex>> = OnceLock::new();

/// 一次性降级告警（目录扫描失败，不逐条刷屏）
fn warn_scan_fail_once(dir: &Path, err: &io::Error) {
    if SCAN_FAIL_WARNED
        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
        .is_ok()
    {
        log::warn!(
            "[audio_cache] 目录扫描失败 {dir:?}: {err}（降级：查询/列举按无缓存处理，不影响在线播放；同类失败后续不再逐条记日志）"
        );
    }
}

/// 列出目录内的普通文件 `(文件名, 元数据)`；目录不存在返回空；其他 IO 错误
/// 降级空列表 + 一次性告警（**不抛异常**）。非 UTF-8 文件名跳过（缓存文件名恒为 ASCII）。
fn read_dir_entries(dir: &Path) -> Vec<(String, fs::Metadata)> {
    let mut out = Vec::new();
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return out,
        Err(e) => {
            warn_scan_fail_once(dir, &e);
            return out;
        }
    };
    for entry in entries.flatten() {
        let Ok(meta) = entry.metadata() else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        if let Some(name) = entry.file_name().to_str() {
            out.push((name.to_string(), meta));
        }
    }
    out
}

/// 命中判定（对齐原版 `committedCacheFiles` L358-373）：
/// 音频文件 `size > 0` 且同名 `.complete` 标记存在
fn is_committed(names: &HashSet<&str>, name: &str, meta: &fs::Metadata) -> bool {
    if meta.len() == 0 {
        return false;
    }
    let marker = format!("{name}{COMPLETE_SUFFIX}");
    names.contains(marker.as_str())
}

/// 该书目录下指定 key 的最新已提交缓存数据文件名
/// （对齐原版 `findCachedFile` L201-203：`maxByOrNull { it.lastModified }`；
/// `lastModified` 不可得时按 UNIX_EPOCH 参与比较，不 panic）
fn latest_committed_file(dir: &Path, key16: &str) -> Option<String> {
    let files = read_dir_entries(dir);
    let names: HashSet<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
    let mut best: Option<(String, SystemTime)> = None;
    for (name, meta) in &files {
        let Some(parsed) = parse_cache_file_name(name) else {
            continue;
        };
        if parsed.key16 != key16 || !is_committed(&names, name, meta) {
            continue;
        }
        let modified = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        if best.as_ref().is_none_or(|(_, t)| modified > *t) {
            best = Some((name.clone(), modified));
        }
    }
    best.map(|(name, _)| name)
}

/// 查询某章是否已缓存（契约 §2.47 `audioCacheQuery`，只读、幂等）
///
/// `chapter_index` 不参与键计算（对齐原版：键只由 chapterUrl/title 决定），
/// 保留形参以对齐冻结的 FFI 签名。任何 IO/解析失败一律返回 `false`，不抛异常。
pub fn audio_cache_query(
    book_url: &str,
    _chapter_index: i32,
    chapter_url: &str,
    chapter_title: &str,
) -> bool {
    let key16 = cache_key16(chapter_url, chapter_title);
    latest_committed_file(&book_dir(book_url), &key16).is_some()
}

/// 列出该书已缓存章节下标（契约 §2.47 `audioCacheList`，只读、幂等）
///
/// 扫描书目录，按五段式正则解析章节序号与 key，仅收录通过
/// `.complete` + `size > 0` 校验的条目；下标去重、升序。无缓存/失败返回空数组。
pub fn audio_cache_list(book_url: &str) -> Vec<i32> {
    let dir = book_dir(book_url);
    let files = read_dir_entries(&dir);
    let names: HashSet<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
    let mut indexes = BTreeSet::new();
    let mut skipped = 0usize;
    for (name, meta) in &files {
        if name.ends_with(COMPLETE_SUFFIX) {
            continue; // 标记文件本身不是数据文件，不算「不匹配文件」
        }
        let Some(parsed) = parse_cache_file_name(name) else {
            skipped += 1;
            continue;
        };
        if is_committed(&names, name, meta) {
            indexes.insert(parsed.chapter_index);
        }
    }
    if skipped > 0 {
        log::debug!("[audio_cache] 目录 {dir:?} 跳过 {skipped} 个不匹配五段式命名的文件（旧键/残留文件不读不迁移）");
    }
    indexes.into_iter().collect()
}

/// 清理某章缓存（契约 §2.47 `audioCacheClearChapter`，幂等）
///
/// 只删该 `key16` 下的音频文件与 `.complete` 标记（不触碰同目录其他章节），
/// 返回实际删除的文件数（含标记）；不存在/已删返回 `0`，IO 失败按已删数返回，不抛异常。
pub fn audio_cache_clear_chapter(
    book_url: &str,
    _chapter_index: i32,
    chapter_url: &str,
    chapter_title: &str,
) -> i32 {
    let key16 = cache_key16(chapter_url, chapter_title);
    let dir = book_dir(book_url);
    let files = read_dir_entries(&dir);
    let mut deleted = 0i32;
    for (name, _meta) in &files {
        let is_data = parse_cache_file_name(name).is_some_and(|p| p.key16 == key16);
        let is_marker = name
            .strip_suffix(COMPLETE_SUFFIX)
            .and_then(parse_cache_file_name)
            .is_some_and(|p| p.key16 == key16);
        if (is_data || is_marker) && fs::remove_file(dir.join(name)).is_ok() {
            deleted += 1;
        }
    }
    deleted
}

/// 清理该书全部缓存（契约 §2.47 `audioCacheClearBook`，幂等）
///
/// 删除书级目录内全部文件（含 `.complete`），返回实际删除数；书目录一并尝试
/// 移除（非空/被占用则忽略）。不跨书（目录按 `md5_16(bookUrl)` 隔离），不抛异常。
pub fn audio_cache_clear_book(book_url: &str) -> i32 {
    let dir = book_dir(book_url);
    let files = read_dir_entries(&dir);
    let mut deleted = 0i32;
    for (name, _meta) in &files {
        if fs::remove_file(dir.join(name)).is_ok() {
            deleted += 1;
        }
    }
    let _ = fs::remove_dir(&dir);
    deleted
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    /// 测试串行锁：`INJECTED_DIR`/`TEST_DIR_OVERRIDE` 为进程级状态，
    /// 并行测试互踩 → 触碰进程级目录状态的测试先持锁（对齐 image_cache 先例）
    static TEST_LOCK: Mutex<()> = Mutex::new(());
    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    /// 进程级唯一临时根目录（测试收尾 remove_dir_all 清理）
    fn unique_root(tag: &str) -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "legado-audio-cache-test-{}-{}-{}",
            std::process::id(),
            n,
            tag
        ))
    }

    fn set_test_root(dir: &Path) {
        if let Ok(mut guard) = TEST_DIR_OVERRIDE.get_or_init(|| Mutex::new(None)).lock() {
            *guard = Some(dir.to_path_buf());
        }
    }

    fn clear_test_root() {
        if let Ok(mut guard) = TEST_DIR_OVERRIDE.get_or_init(|| Mutex::new(None)).lock() {
            *guard = None;
        }
    }

    /// 写一个五段式数据文件（可选 `.complete` 标记）
    fn write_cache_file(dir: &Path, name: &str, size: usize, marker: bool) -> PathBuf {
        fs::create_dir_all(dir).unwrap();
        let path = dir.join(name);
        fs::write(&path, vec![7u8; size]).unwrap();
        if marker {
            fs::write(dir.join(format!("{name}{COMPLETE_SUFFIX}")), b"1\nx\nx").unwrap();
        }
        path
    }

    /// 合法五段式文件名（key 为 hello 的 md5Encode16 向量）
    fn valid_name(index: i32, key: &str, ext: &str) -> String {
        format!("{index:05}_{key}_某章节_bc964d2a0c9c9bf9_9f8e7d6c.{ext}")
    }

    const KEY_HELLO: &str = "bc4b2a76b9719d91";

    // 键向量：与原版 MD5Utils.md5Encode16（hutool MD5 小写 hex [8,24)）逐字节对齐
    #[test]
    fn key_vectors() {
        assert_eq!(cache_key16("hello", "任意标题"), KEY_HELLO);
        assert_eq!(cache_key16("中文", "任意标题"), "9fcdcb3a067903d8");
        assert_eq!(
            cache_key16("https://example.com/ch/1.mp3", ""),
            "bc964d2a0c9c9bf9"
        );
        // 空串键 = md5("") 中段 16 字符（title 为空时 identity 为空串）
        assert_eq!(cache_key16("", ""), "8f00b204e9800998");
    }

    // ifBlank 语义：空白 URL 退回标题；不 trim、大小写敏感；NBSP 不算空白（Java 语义）
    #[test]
    fn key_if_blank_and_sensitivity() {
        assert_eq!(cache_key16("   ", "标题"), cache_key16("标题", "无关"));
        assert_eq!(cache_key16("\t\n", "标题"), cache_key16("标题", "无关"));
        // 不 trim：带空格的 URL 原样参与哈希
        assert_ne!(cache_key16(" abc ", "标题"), cache_key16("abc", "标题"));
        assert_ne!(cache_key16("ABC", "标题"), cache_key16("abc", "标题"));
        // NBSP（U+00A0）在 Kotlin/Java 中不是空白 → 不退回标题
        assert_ne!(cache_key16("\u{00A0}", "标题"), cache_key16("标题", "无关"));
        assert_eq!(cache_key16("\u{00A0}", "标题"), md5_mid16("\u{00A0}"));
    }

    // 五段式文件名解析（对齐原版 AudioCachePolicy.parseFileName）
    #[test]
    fn parse_five_segment_names() {
        let ok = parse_cache_file_name(&valid_name(42, KEY_HELLO, "mp3")).unwrap();
        assert_eq!(ok.chapter_index, 42);
        assert_eq!(ok.key16, KEY_HELLO);
        // 扩展名白名单：audio 与音频后缀均可
        assert!(parse_cache_file_name(&valid_name(1, KEY_HELLO, "audio")).is_some());
        assert!(parse_cache_file_name(&valid_name(1, KEY_HELLO, "flac")).is_some());
        // 章节序号 5 位起；4 位不匹配
        assert!(
            parse_cache_file_name("0042_bc4b2a76b9719d91_标题_bc964d2a0c9c9bf9_9f8e7d6c.mp3")
                .is_none()
        );
        // 非音频扩展名不匹配
        assert!(parse_cache_file_name(&valid_name(1, KEY_HELLO, "txt")).is_none());
        // 大写 hex 不匹配（正则要求小写）
        assert!(
            parse_cache_file_name("00042_BC4B2A76B9719D91_标题_bc964d2a0c9c9bf9_9f8e7d6c.mp3")
                .is_none()
        );
        // 段数不足不匹配
        assert!(parse_cache_file_name("00042_bc4b2a76b9719d91_标题.mp3").is_none());
        // 序号溢出 i32 → 跳过
        assert!(parse_cache_file_name(
            "99999999999_bc4b2a76b9719d91_标题_bc964d2a0c9c9bf9_9f8e7d6c.mp3"
        )
        .is_none());
        // 旧孤儿键命名不匹配（不读不迁移的天然屏障）
        assert!(parse_cache_file_name("-123456_0.audio").is_none());
    }

    // 命中三条件：key 匹配 + .complete 存在 + size > 0
    #[test]
    fn query_hit_requires_marker_and_nonzero_size() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("hit");
        set_test_root(&root);
        let dir = book_dir("https://a.com/book/1");
        let url = "hello";
        let title = "第一章";
        let name = valid_name(1, KEY_HELLO, "mp3");

        // 目录不存在 → false
        assert!(!audio_cache_query("https://a.com/book/1", 1, url, title));
        // 无标记 → false
        write_cache_file(&dir, &name, 16, false);
        assert!(!audio_cache_query("https://a.com/book/1", 1, url, title));
        // 有标记但 size=0 → false
        fs::remove_file(dir.join(&name)).unwrap();
        write_cache_file(&dir, &name, 0, true);
        assert!(!audio_cache_query("https://a.com/book/1", 1, url, title));
        // 有标记且 size>0 → true
        fs::remove_file(dir.join(&name)).unwrap();
        write_cache_file(&dir, &name, 16, true);
        assert!(audio_cache_query("https://a.com/book/1", 1, url, title));
        // 键不匹配（同 URL 不同章）→ false
        assert!(!audio_cache_query(
            "https://a.com/book/1",
            2,
            "hello2",
            title
        ));
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 同名多条：取 lastModified 最新者
    #[test]
    fn latest_committed_prefers_newest() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("latest");
        set_test_root(&root);
        let dir = book_dir("https://a.com/book/2");
        let old_name = valid_name(3, KEY_HELLO, "mp3");
        let new_name = valid_name(3, KEY_HELLO, "m4a");
        let old_path = write_cache_file(&dir, &old_name, 8, true);
        let new_path = write_cache_file(&dir, &new_name, 8, true);
        let old_time = SystemTime::UNIX_EPOCH + Duration::from_secs(1_000_000);
        let new_time = SystemTime::UNIX_EPOCH + Duration::from_secs(2_000_000);
        // Windows 下 SetFileTime 需写权限句柄，故以 write 打开设置 mtime
        fs::OpenOptions::new()
            .write(true)
            .open(&old_path)
            .unwrap()
            .set_modified(old_time)
            .unwrap();
        fs::OpenOptions::new()
            .write(true)
            .open(&new_path)
            .unwrap()
            .set_modified(new_time)
            .unwrap();
        assert_eq!(
            latest_committed_file(&dir, KEY_HELLO).as_deref(),
            Some(new_name.as_str())
        );
        assert!(audio_cache_query(
            "https://a.com/book/2",
            3,
            "hello",
            "第一章"
        ));
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 列举：仅已提交条目、下标去重升序；无标记/空文件/不匹配文件跳过
    #[test]
    fn list_sorted_unique_committed() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("list");
        set_test_root(&root);
        let dir = book_dir("https://a.com/book/3");
        write_cache_file(&dir, &valid_name(5, KEY_HELLO, "mp3"), 8, true);
        write_cache_file(&dir, &valid_name(2, KEY_HELLO, "mp3"), 8, true);
        write_cache_file(&dir, &valid_name(2, KEY_HELLO, "m4a"), 8, true); // 同章多版本 → 去重
        write_cache_file(&dir, &valid_name(7, KEY_HELLO, "mp3"), 8, false); // 无标记
        write_cache_file(&dir, &valid_name(9, KEY_HELLO, "mp3"), 0, true); // 空文件
        write_cache_file(&dir, "-123_legacy.audio", 8, false); // 旧键孤儿 → 跳过
        assert_eq!(audio_cache_list("https://a.com/book/3"), vec![2, 5]);
        // 无缓存的书 → 空
        assert!(audio_cache_list("https://a.com/book/other").is_empty());
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 清理单章：只删该 key 的数据文件与标记；幂等；不触碰其他章节
    #[test]
    fn clear_chapter_isolated_and_idempotent() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("clear-chapter");
        set_test_root(&root);
        let dir = book_dir("https://a.com/book/4");
        let hit = valid_name(1, KEY_HELLO, "mp3");
        let other_key = md5_mid16("other-url");
        let other = valid_name(2, &other_key, "mp3");
        write_cache_file(&dir, &hit, 8, true);
        write_cache_file(&dir, &other, 8, true);
        // 删除数 = 数据文件 + .complete 标记
        assert_eq!(
            audio_cache_clear_chapter("https://a.com/book/4", 1, "hello", "第一章"),
            2
        );
        assert!(!audio_cache_query(
            "https://a.com/book/4",
            1,
            "hello",
            "第一章"
        ));
        assert!(audio_cache_query(
            "https://a.com/book/4",
            2,
            "other-url",
            "第二章"
        ));
        // 幂等：再次清理返回 0
        assert_eq!(
            audio_cache_clear_chapter("https://a.com/book/4", 1, "hello", "第一章"),
            0
        );
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 清理整书：全删（含标记）、目录移除；幂等；不跨书
    #[test]
    fn clear_book_all_and_idempotent() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("clear-book");
        set_test_root(&root);
        let dir_a = book_dir("https://a.com/book/A");
        let dir_b = book_dir("https://a.com/book/B");
        write_cache_file(&dir_a, &valid_name(1, KEY_HELLO, "mp3"), 8, true);
        write_cache_file(&dir_a, &valid_name(2, KEY_HELLO, "mp3"), 8, true);
        write_cache_file(&dir_b, &valid_name(1, KEY_HELLO, "mp3"), 8, true);
        assert_eq!(audio_cache_clear_book("https://a.com/book/A"), 4);
        assert!(!dir_a.exists(), "书目录应一并移除");
        assert!(
            audio_cache_query("https://a.com/book/B", 1, "hello", "第一章"),
            "不得跨书清理"
        );
        assert_eq!(audio_cache_clear_book("https://a.com/book/A"), 0, "幂等");
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 书级隔离：不同 bookUrl 目录不同、互不串缓存
    #[test]
    fn book_isolation() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("isolation");
        set_test_root(&root);
        write_cache_file(
            &book_dir("https://a.com/book/X"),
            &valid_name(1, KEY_HELLO, "mp3"),
            8,
            true,
        );
        assert!(audio_cache_query(
            "https://a.com/book/X",
            1,
            "hello",
            "第一章"
        ));
        assert!(!audio_cache_query(
            "https://a.com/book/Y",
            1,
            "hello",
            "第一章"
        ));
        assert!(audio_cache_list("https://a.com/book/Y").is_empty());
        assert_ne!(
            book_dir("https://a.com/book/X"),
            book_dir("https://a.com/book/Y")
        );
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // 失败降级：根目录被普通文件占用（目录扫描/删除失败）→ 不 panic，按无缓存处理
    #[test]
    fn failures_degrade_without_panic() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("degrade");
        fs::create_dir_all(root.parent().unwrap()).unwrap();
        fs::write(&root, b"i-am-a-file").unwrap();
        set_test_root(&root);
        assert!(!audio_cache_query(
            "https://a.com/book/1",
            1,
            "hello",
            "第一章"
        ));
        assert!(audio_cache_list("https://a.com/book/1").is_empty());
        assert_eq!(
            audio_cache_clear_chapter("https://a.com/book/1", 1, "hello", "第一章"),
            0
        );
        assert_eq!(audio_cache_clear_book("https://a.com/book/1"), 0);
        fs::remove_file(&root).ok();
        clear_test_root();
    }

    // set_cache_dir 注入：查询/列举/清理落注入目录
    #[test]
    fn injected_dir_used() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("injected");
        clear_test_root();
        set_cache_dir(root.to_str().unwrap());
        write_cache_file(
            &book_dir("https://a.com/book/5"),
            &valid_name(4, KEY_HELLO, "mp3"),
            8,
            true,
        );
        assert!(audio_cache_query(
            "https://a.com/book/5",
            4,
            "hello",
            "第一章"
        ));
        assert_eq!(audio_cache_list("https://a.com/book/5"), vec![4]);
        assert!(root
            .join(format!("book_{}", md5_mid16("https://a.com/book/5")))
            .exists());
        assert_eq!(audio_cache_clear_book("https://a.com/book/5"), 2);
        // 复位注入槽为 None（不污染其他测试）
        if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
            *guard = None;
        }
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }
}
