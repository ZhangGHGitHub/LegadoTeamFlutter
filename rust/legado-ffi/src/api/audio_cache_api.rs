//! 音频章节文件缓存（B1 契约 §2.47 只读/清理面 + B2 契约 §2.48 写入面，
//! 对齐原版 AudioCacheManager / AudioCachePolicy）
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
//! - `help/audio/AudioCacheManager.kt:338-356`：清理按 key 删数据文件与 `.complete` 标记，
//!   **返回计数只统计 dataTargets（数据文件，含 tmp 部分文件），不计标记**
//!
//! 本书口径（契约 §2.47，用户 2026-10-04 裁决）：
//! - 只读面 + 清理面，**写入面见契约 §2.48（B2）**：原版写入仅发生于预下载服务
//!   `AudioCacheService.kt:217`（全仓唯一 `cacheChapter` 调用方），播放链从不写
//!   （`AudioPlay.kt:388-413` 第一步查缓存、命中完全跳网络）
//! - 缓存根经 [`set_cache_dir`] 进程注入（FFI `set_audio_cache_dir`，与
//!   `image_cache_api` 同型）：env [`CACHE_DIR_ENV`]（非空，测试隔离用；`cfg(test)`
//!   下由显式测试槽整体旁路）> 宿主注入目录 > `<temp_dir>/legado-audio-cache`
//!   （回落时一次性告警）
//! - 只读/清理面**失败一律降级**（查询 false、列举空数组、清理返回实际删除计数），
//!   不抛 FFI 异常——缓存是加速器不是数据源（同 §2.46 口径）；**写入面（§2.48）
//!   有意相反**：失败上抛 BridgeError 不降级（显式用户动作，错误须驱动 Dart
//!   循环 failCount，契约 §2.48「失败语义」双向登记）
//! - 旧键 `${bookUrl.hashCode}_$i.audio`（重构版自创、无读取方）不读不迁移：
//!   不匹配五段式正则且无 `.complete`，扫描时天然跳过
//!
//! B2 写入面（契约 §2.48，逐条对齐 `AudioCacheManager.kt:132-199`）：
//! - [`audio_cache_download`]：单章下载安装（幂等；流式落盘，字节零穿越 FFI）；
//!   原版服务编排（ArrayDeque 队列/前台通知/START_NOT_STICKY）不上 FFI，由
//!   Dart 循环逐章调用自持进度（`AudioCacheService.kt:275-301` 计数等价）
//! - [`audio_cache_cancel`]：进程级取消代数单槽（对齐原版服务单 worker + stop，
//!   `AudioCacheService.kt:145-185,259-266`）；在途下载于每个流式块边界检查
//!   代数（对齐 `copyCancellable:397-412` 的 ensureActive），变更即中止并清理
//! - [`chapter_lock`]：同 `(bookUrl, key16)` 分片互斥（对齐原版
//!   `AudioCacheManager.chapterLocks:44` + `chapterLock:414-416`，16 片），
//!   覆盖下载幂等检查→失败清理整段（P1-1 修复，详见该函数文档）；
//!   `audio_cache_clear_chapter` 亦取此锁（对齐原版
//!   `removeCachedChapter:92-105` 的 `withLock`），FFI 侧 async 化
//!   （spawn_blocking）后清理可等比等待在途下载且不阻塞 UI isolate

use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};
use legado_net::{LegadoClient, LegadoRequest, Method};
use legado_parser::{AnalyzeUrl, TemplateContext};

use crate::db_state::with_database;

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

/// 陈旧未提交文件保留阈值（对齐原版 `AudioCacheManager.STALE_PARTIAL_AGE_MILLIS:43`）
const STALE_PARTIAL_AGE_MILLIS: u64 = 60 * 60 * 1000;

/// 暂存部分文件前缀/后缀（对齐原版 `isTemporaryFile:385-389`：
/// `tmp_{key16}_*.part`）
const TMP_PREFIX: &str = "tmp_";
const PART_SUFFIX: &str = ".part";

/// 进程级取消代数（B2，契约 §2.48）：[`audio_cache_cancel`] 递增，
/// 在途下载在每个流式块边界比对开局快照，不等即中止并清理部分文件
/// （对齐原版服务 stop → Job.cancel → copyCancellable ensureActive 路径）
static CANCEL_GEN: AtomicU64 = AtomicU64::new(0);

/// 进程级在途下载计数（B2）：>0 时 [`audio_cache_cancel`] 返回 true。
/// 与 [`CANCEL_GEN`] 无关联于既有 `_speakGeneration` 等 Dart 侧机制
/// （本取消为 Rust 进程级单槽，对齐原版「单 worker 至多一个在途下载」）
static IN_FLIGHT: AtomicUsize = AtomicUsize::new(0);

/// 随机十六进制串计数器（rev8 / tmp 文件名 token；非密码学随机，仅防并发同名）
static RANDOM_COUNTER: AtomicU64 = AtomicU64::new(0);

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

/// 五段式缓存文件名解析结果（title / playUrlHash / rev 三段不参与命中判定；
/// extension 供 `already_cached` 返回与安装流程复用）
#[derive(Debug, Clone, PartialEq, Eq)]
struct ParsedCacheFileName {
    /// 章节序号（正则第一段，`toIntOrNull` 溢出即视为不匹配）
    chapter_index: i32,
    /// 缓存键（正则第二段，小写 16 hex）
    key16: String,
    /// 扩展名（正则第五段，白名单内）
    extension: String,
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
        extension: extension.to_string(),
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

/// 该书目录下指定 key 的最新已提交缓存数据文件（文件名 + 元数据）
/// （对齐原版 `findCachedFile` L201-203：`maxByOrNull { it.lastModified }`；
/// `lastModified` 不可得时按 UNIX_EPOCH 参与比较，不 panic）
fn latest_committed_file(dir: &Path, key16: &str) -> Option<(String, fs::Metadata)> {
    let files = read_dir_entries(dir);
    let names: HashSet<&str> = files.iter().map(|(n, _)| n.as_str()).collect();
    let mut best: Option<(String, SystemTime, fs::Metadata)> = None;
    for (name, meta) in &files {
        let Some(parsed) = parse_cache_file_name(name) else {
            continue;
        };
        if parsed.key16 != key16 || !is_committed(&names, name, meta) {
            continue;
        }
        let modified = meta.modified().unwrap_or(SystemTime::UNIX_EPOCH);
        if best.as_ref().is_none_or(|(_, t, _)| modified > *t) {
            best = Some((name.clone(), modified, meta.clone()));
        }
    }
    best.map(|(name, _, meta)| (name, meta))
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
/// 只删该 `key16` 下的音频文件、暂存部分文件与 `.complete` 标记（不触碰同目录
/// 其他章节），返回**实际删除的数据文件数**（仅统计 dataTargets——数据文件与
/// `tmp_*.part`，**不计 `.complete` 标记**，对齐原版 `removeCacheFiles:338-356`
/// 的 `return dataTargets.size`；标记照删）。不存在/已删返回 `0`，IO 失败按
/// 已删数返回，不抛异常。
///
/// 与下载共用同一把 `(bookUrl, key16)` 章节分片锁（对齐原版
/// `removeCachedChapter:92-105` 的 `chapterLock(bookUrl, key).withLock`——
/// 原版该函数为 `suspend`，清理与在途下载互斥，避免互删对方产物）。
/// 本函数为**阻塞实现**，FFI 侧经 spawn_blocking 包装为非阻塞
/// （`audio_cache_clear_chapter` async 导出）：清理等待在途下载完成
/// （最坏受下载自身时长约束），UI isolate 不被阻塞。
pub fn audio_cache_clear_chapter(
    book_url: &str,
    _chapter_index: i32,
    chapter_url: &str,
    chapter_title: &str,
) -> i32 {
    let key16 = cache_key16(chapter_url, chapter_title);
    let dir = book_dir(book_url);
    let chapter_shard = chapter_lock(book_url, &key16);
    let _chapter_guard = chapter_shard.lock().unwrap_or_else(|e| e.into_inner());
    remove_cache_files(&dir, &key16, None)
}

/// 清理该书全部缓存（契约 §2.47 `audioCacheClearBook`，幂等）
///
/// 删除书级目录内全部文件（含 `.complete`），返回实际删除数（**仅统计数据
/// 文件，`tmp_*.part` 计入、`.complete` 标记不计**——与单章清理同口径，对齐
/// 原版 `removeCacheFiles` 的 dataTargets 计数语义）；书目录一并尝试移除
/// （非空/被占用则忽略）。不跨书（目录按 `md5_16(bookUrl)` 隔离），不抛异常。
pub fn audio_cache_clear_book(book_url: &str) -> i32 {
    let dir = book_dir(book_url);
    let files = read_dir_entries(&dir);
    let mut deleted = 0i32;
    for (name, _meta) in &files {
        if name.ends_with(COMPLETE_SUFFIX) {
            continue; // 标记照删、不计入返回值
        }
        if fs::remove_file(dir.join(name)).is_ok() {
            deleted += 1;
        }
    }
    // 标记文件单独删（不计数）
    for (name, _meta) in &files {
        if name.ends_with(COMPLETE_SUFFIX) {
            let _ = fs::remove_file(dir.join(name));
        }
    }
    let _ = fs::remove_dir(&dir);
    deleted
}

// ─── B2 写入面（契约 §2.48，对齐 AudioCacheManager.cacheChapter 132-199） ──────

/// ISO 控制符判定（对齐 Kotlin `Char.isISOControl`）：C0（U+0000..=U+001F）
/// 与 C1（U+007F..=U+009F）
fn is_iso_control(c: char) -> bool {
    matches!(c, '\u{0000}'..='\u{001F}' | '\u{007F}'..='\u{009F}')
}

/// 标题 → 安全文件名段（对齐原版 `AudioCachePolicy.buildFileName:79-87`）：
/// 非法文件名字符（`[\\/:*?"<>|]`，对齐 `AppPattern.fileNameRegex2:35`
/// / `StringExtensions.normalizeFileName:162-164`）替换 `_` → 去 ISO 控制符 →
/// trim（Kotlin `Char.isWhitespace` 语义，NBSP 不算）→ 去首尾 `_` → 空则
/// `"chapter"` → 截 40 字符 → 去尾部 `.`/空格 → 空则 `"chapter"`。
///
/// 已知边界：Kotlin `take(40)` 按 UTF-16 code unit 截断（非 BMP 字符可截出
/// 孤立代理项）；本实现按 Unicode scalar（`chars()`）截断以避免产出非法
/// UTF-8/文件名——仅当标题前 40 个 UTF-16 单元内含非 BMP 字符时与 Kotlin
/// 结果不同（章标题场景极罕见），登记为有意差异。
fn safe_title(chapter_title: &str) -> String {
    let replaced: String = chapter_title
        .chars()
        .map(|c| match c {
            '\\' | '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '_',
            other => other,
        })
        .collect();
    let filtered: String = replaced.chars().filter(|c| !is_iso_control(*c)).collect();
    let trimmed = filtered
        .trim_matches(kotlin_char_is_whitespace)
        .trim_matches('_');
    let non_blank = if kotlin_is_blank(trimmed) {
        "chapter".to_string()
    } else {
        trimmed.to_string()
    };
    let limited: String = non_blank.chars().take(40).collect();
    let trimmed_end = limited.trim_end_matches(['.', ' ']);
    if kotlin_is_blank(trimmed_end) {
        "chapter".to_string()
    } else {
        trimmed_end.to_string()
    }
}

/// URL → 音频扩展名（对齐原版 `AudioCachePolicy.extensionFromUrl:121-128`）：
/// 截 `?`/`#` 后取最后一个 `.` 之后部分小写；须 ∈ 音频扩展名白名单，否则 None。
/// 注：Kotlin `substringAfterLast('.', "")` 无 `.` 时为空串（Rust `rsplit` 会
/// 返回整串，故此处显式用 `rfind` 对齐）
fn extension_from_url(url: &str) -> Option<String> {
    let path = url
        .split('?')
        .next()
        .unwrap_or("")
        .split('#')
        .next()
        .unwrap_or("");
    let idx = path.rfind('.')?;
    let ext = path[idx + 1..].to_lowercase();
    AUDIO_EXTENSIONS.contains(&ext.as_str()).then_some(ext)
}

/// HLS 判定（对齐原版 `AudioCachePolicy.isHlsUrl:116-119`）：截 `?`/`#` 后
/// 以 `.m3u8`/`.m3u` 结尾（大小写不敏感）
fn is_hls_url(url: &str) -> bool {
    let path = url
        .split('?')
        .next()
        .unwrap_or("")
        .split('#')
        .next()
        .unwrap_or("");
    let lower = path.to_lowercase();
    lower.ends_with(".m3u8") || lower.ends_with(".m3u")
}

/// JSON 数组形态判定（对齐原版 `StringExtensions.isJsonArray:64-68`：
/// `trim()` 后首 `[` 尾 `]`）
fn is_json_array(s: &str) -> bool {
    let t = s.trim();
    t.starts_with('[') && t.ends_with(']')
}

/// playUrl 可缓存性校验（对齐原版 `AudioCachePolicy.requireCacheablePlayUrl:25-33`）：
/// 空 / JSON 数组多段 / HLS → Err（原文案，写入面上抛不降级）
fn require_cacheable_play_url(play_url: &str) -> LegadoResult<()> {
    if kotlin_is_blank(play_url) {
        return Err(LegadoError::Ffi("播放链接为空".into()));
    }
    if is_json_array(play_url) {
        return Err(LegadoError::Ffi("暂不支持缓存多段音频".into()));
    }
    if is_hls_url(play_url) {
        return Err(LegadoError::Ffi("暂不支持缓存 HLS 音频".into()));
    }
    Ok(())
}

/// 扩展名三级探测（对齐原版 `AudioCachePolicy.detectExtension:35-65`）：
/// Content-Type（截 `;`/trim/小写）→ 最终 URL 后缀 → playUrl 后缀 → 缺省
/// `"audio"`；Content-Type 含 `mpegurl` 或最终 URL 为 HLS → Err「暂不支持
/// 缓存 HLS 音频」（`:45-47`）。
fn detect_extension(
    content_type: Option<&str>,
    final_url: &str,
    play_url: &str,
) -> LegadoResult<String> {
    require_cacheable_play_url(play_url)?;
    let normalized =
        content_type.map(|ct| ct.split(';').next().unwrap_or("").trim().to_lowercase());
    if normalized
        .as_deref()
        .is_some_and(|ct| ct.contains("mpegurl"))
        || is_hls_url(final_url)
    {
        return Err(LegadoError::Ffi("暂不支持缓存 HLS 音频".into()));
    }
    let ext = match normalized.as_deref() {
        // Content-Type 缺失（None）：直接由 URL 三级兜底（对齐 Kotlin when 第一支）
        None => extension_from_url(final_url)
            .or_else(|| extension_from_url(play_url))
            .unwrap_or_else(|| "audio".to_string()),
        Some(ct) => {
            if ct.contains("mpeg") || ct.contains("mp3") {
                "mp3".to_string()
            } else if ct.contains("m4a") || ct.contains("mp4") {
                "m4a".to_string()
            } else if ct.contains("aac") {
                "aac".to_string()
            } else if ct.contains("ogg") {
                "ogg".to_string()
            } else if ct.contains("opus") {
                "opus".to_string()
            } else if ct.contains("wav") {
                "wav".to_string()
            } else if ct.contains("flac") {
                "flac".to_string()
            } else if ct.contains("webm") {
                "webm".to_string()
            } else if ct.contains("amr") {
                "amr".to_string()
            } else if ct.contains("3gpp") {
                "3gp".to_string()
            } else {
                extension_from_url(final_url)
                    .or_else(|| extension_from_url(play_url))
                    .unwrap_or_else(|| "audio".to_string())
            }
        }
    };
    Ok(ext)
}

/// 五段式文件名生成（对齐原版 `AudioCachePolicy.buildFileName:67-98`）：
/// `%05d_{key16}_{safeTitle}_{playUrlHash16}_{rev8}.{ext}`；
/// 各段先决条件不满足 → Err（对齐 Kotlin `require`，服务按章计 fail）
fn build_file_name(
    chapter_index: i32,
    key16: &str,
    chapter_title: &str,
    play_url_hash: &str,
    revision: &str,
    extension: &str,
) -> LegadoResult<String> {
    let is_hex = |s: &str, len: usize| {
        s.len() == len
            && s.chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
    };
    if chapter_index < 0 {
        return Err(LegadoError::Ffi("章节序号非法".into()));
    }
    if !is_hex(play_url_hash, 16) {
        return Err(LegadoError::Ffi("playUrl 哈希非法".into()));
    }
    if !is_hex(revision, 8) {
        return Err(LegadoError::Ffi("修订号非法".into()));
    }
    if extension != "audio" && !AUDIO_EXTENSIONS.contains(&extension) {
        return Err(LegadoError::Ffi(format!("扩展名非法: {extension}")));
    }
    Ok(format!(
        "{:05}_{key16}_{safe_title}_{play_url_hash}_{revision}.{extension}",
        chapter_index,
        safe_title = safe_title(chapter_title),
    ))
}

/// `.complete` 元数据编码（对齐原版 `AudioCacheMetadata.encode:141-143`）：
/// UTF-8 三行 `1\n{md5_16(playUrl)}\n{playUrl}`
fn encode_metadata(play_url: &str) -> String {
    format!("1\n{}\n{}", md5_mid16(play_url), play_url)
}

/// `.complete` 元数据解码/校验（对齐原版 `AudioCacheMetadata.decode:145-152`）：
/// 恰好 3 行（limit=3，第 3 行保留含换行的 playUrl 原文）、版本为 `1`、
/// playUrl 非空白且 md5_16 匹配 → Some(playUrl)，否则 None
fn decode_metadata(metadata: &str) -> Option<String> {
    let parts: Vec<&str> = metadata.splitn(3, '\n').collect();
    if parts.len() != 3 || parts[0] != "1" {
        return None;
    }
    let play_url = parts[2];
    if !kotlin_is_blank(play_url) && md5_mid16(play_url) == parts[1] {
        Some(play_url.to_string())
    } else {
        None
    }
}

/// 完整文件判定（对齐原版 `AudioCachePolicy.isCompleteFile:112-114`）：
/// `actualSize > 0 && (expectedSize == None || actualSize == expectedSize)`
fn require_complete_size(actual: u64, expected: Option<u64>) -> LegadoResult<()> {
    if actual == 0 {
        return Err(LegadoError::Ffi("音频文件为空".into()));
    }
    if expected.is_some_and(|e| actual != e) {
        return Err(LegadoError::Ffi("音频文件不完整".into()));
    }
    Ok(())
}

/// 随机小写十六进制串（rev8 对齐原版 `UUID.randomUUID().toString()
/// .replace("-","").take(8)`；tmp 文件名 token 为 32 位）。用进程内计数器 +
/// 纳秒时钟 + 随机种子哈希合成——仅用于防并发同名，非密码学随机。
fn random_hex(len: usize) -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut out = String::with_capacity(len + 16);
    while out.len() < len {
        let n = RANDOM_COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
        hasher.write_u128(nanos);
        hasher.write_u64(n);
        out.push_str(&format!("{:016x}", hasher.finish()));
    }
    out.truncate(len);
    out
}

/// 暂存部分文件判定（对齐原版 `AudioCacheManager.isTemporaryFile:385-389`：
/// `!isDir && name.startsWith("tmp_{key}_") && name.endsWith(".part")`）
fn is_temporary_file(name: &str, key16: &str) -> bool {
    name.starts_with(&format!("{TMP_PREFIX}{key16}_")) && name.ends_with(PART_SUFFIX)
}

/// 五段式数据文件判定（对齐原版 `isCacheFile:391-395`）
fn is_cache_file_name(name: &str, key16: &str) -> bool {
    parse_cache_file_name(name).is_some_and(|p| p.key16 == key16)
}

/// 陈旧未提交文件清理（对齐原版 `cleanupUncommittedFiles:302-314`）：
/// 本 key 下的 `tmp_*.part` 与无 `.complete` 的五段式文件，`lastModified`
/// 位于 `[1, now - 1h]` 区间者删除（lastModified 为 0/不可得者不删）。
/// 失败静默（写入流程随后自会处理）。
fn cleanup_uncommitted_files(dir: &Path, key16: &str) {
    let files = read_dir_entries(dir);
    let complete_names: HashSet<&str> = files
        .iter()
        .filter(|(n, _)| n.ends_with(COMPLETE_SUFFIX))
        .map(|(n, _)| n.strip_suffix(COMPLETE_SUFFIX).unwrap_or(n.as_str()))
        .collect();
    let now = SystemTime::now();
    let stale_before_ms = now
        .checked_sub(Duration::from_millis(STALE_PARTIAL_AGE_MILLIS))
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis())
        .unwrap_or(0);
    for (name, meta) in &files {
        let uncommitted = is_temporary_file(name, key16)
            || (is_cache_file_name(name, key16) && !complete_names.contains(name.as_str()));
        if !uncommitted {
            continue;
        }
        let modified_ms = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| d.as_millis())
            .unwrap_or(0);
        if modified_ms >= 1 && modified_ms <= stale_before_ms {
            let _ = fs::remove_file(dir.join(name));
        }
    }
}

/// 按 key 清理数据文件/暂存文件/标记（对齐原版
/// `removeCacheFiles:338-356`）：`except_name` 为本次新安装文件名（保留）；
/// 返回 **dataTargets 计数**——`tmp_*.part` 与五段式数据文件（不含 `.complete`），
/// 标记照删不计。
fn remove_cache_files(dir: &Path, key16: &str, except_name: Option<&str>) -> i32 {
    let files = read_dir_entries(dir);
    let mut data_targets: Vec<String> = Vec::new();
    let mut marker_targets: Vec<String> = Vec::new();
    for (name, _meta) in &files {
        let is_data = is_cache_file_name(name, key16) || is_temporary_file(name, key16);
        if is_data && except_name != Some(name.as_str()) {
            data_targets.push(name.clone());
        }
        if let Some(base) = name.strip_suffix(COMPLETE_SUFFIX) {
            if except_name != Some(base) && is_cache_file_name(base, key16) {
                marker_targets.push(name.clone());
            }
        }
    }
    let count = data_targets.len() as i32;
    for name in data_targets.into_iter().chain(marker_targets) {
        let _ = fs::remove_file(dir.join(name));
    }
    count
}

/// 在途下载 RAII 计数（进程级；drop 时递减，保证任何提前返回都复位）
struct InFlightGuard;

impl InFlightGuard {
    fn new() -> Self {
        IN_FLIGHT.fetch_add(1, Ordering::SeqCst);
        Self
    }
}

impl Drop for InFlightGuard {
    fn drop(&mut self) {
        IN_FLIGHT.fetch_sub(1, Ordering::SeqCst);
    }
}

/// 取消代数是否已变更（在途下载中止判据）
fn cancel_generation_changed(snapshot: u64) -> bool {
    CANCEL_GEN.load(Ordering::SeqCst) != snapshot
}

/// 章节锁分片数（对齐原版 `AudioCacheManager.chapterLocks:44`：`Array(16)`）
const CHAPTER_LOCK_SHARDS: usize = 16;

/// Java `String.hashCode()`（UTF-16 code unit 累加，`h = 31*h + c` 以 i32 截断），
/// 供分片索引与原版 `bookUrl.hashCode()` / `AudioCacheKey.hashCode()`
/// （即 16 hex 串的 `String.hashCode`）逐值对齐
fn java_string_hash(s: &str) -> i32 {
    let mut h: i32 = 0;
    for unit in s.encode_utf16() {
        h = h.wrapping_mul(31).wrapping_add(unit as i32);
    }
    h
}

/// 语义同 Java `Math.floorMod(x, m)`（m > 0，负值取非负余数）
fn java_floor_mod(x: i32, m: i32) -> i32 {
    x.rem_euclid(m)
}

/// 按 `(bookUrl, key16)` 取章节分片锁（对齐原版 `chapterLock:414-416`：
/// `chapterLocks[Math.floorMod(31 * bookUrl.hashCode() + key.hashCode(), 16)]`；
/// 同 key 同分片串行，异 key 最多 16 路并行——与原版碰撞粒度一致）。
///
/// 使用范围（原版对照）：
/// - 写入面：覆盖 `audio_cache_download_with_client` 的 ② 幂等检查 → ⑧ 失败
///   清理整段，对齐原版 `cacheChapter:117-118`
///   `chapterLock(...).withLock { cacheChapterLocked(...) }` 的临界区
///   （含 `cleanupUncommittedFiles` / 安装 / 写标记 / `removeCacheFiles`
///   步骤⑦，`AudioCacheManager.kt:139-199`）——修复同章并发两条下载互删
///   产物/在写 tmp 的静默缓存丢失。
/// - 清理面：覆盖 `audio_cache_clear_chapter` 整段（对齐原版
///   `removeCachedChapter:92-105` 同样取此锁的 `withLock`；原版为 suspend，
///   我方 FFI 经 spawn_blocking 异步化后语义等价：等待在途下载完成再清理，
///   不阻塞 UI isolate）。
fn chapter_lock(book_url: &str, key16: &str) -> &'static Mutex<()> {
    static CHAPTER_LOCKS: OnceLock<[Mutex<()>; CHAPTER_LOCK_SHARDS]> = OnceLock::new();
    let locks = CHAPTER_LOCKS.get_or_init(|| std::array::from_fn(|_| Mutex::new(())));
    let combined = 31i32
        .wrapping_mul(java_string_hash(book_url))
        .wrapping_add(java_string_hash(key16));
    &locks[java_floor_mod(combined, CHAPTER_LOCK_SHARDS as i32) as usize]
}

/// 取消当前在途下载（契约 §2.48 `audioCacheCancel`，对齐原版服务 stop 语义单槽化）
///
/// 原版单 worker 逐章处理（`AudioCacheService.kt:145-185`），全局同时至多一个
/// 在途下载；本方法将进程级取消代数 +1，在途下载在每个流式块边界检查代数
/// （对齐 `copyCancellable` 的 ensureActive），不匹配即中止拷贝并删除部分文件
/// （对齐原版 CancellationException 清理路径 `AudioCacheManager.kt:190-197`）。
/// 返回 `true` = 置位时快照到在途下载（尽力提示，不作同步保证）；`false` =
/// 当前无在途。同步立即返回。
pub fn audio_cache_cancel() -> LegadoResult<bool> {
    if IN_FLIGHT.load(Ordering::SeqCst) == 0 {
        return Ok(false);
    }
    CANCEL_GEN.fetch_add(1, Ordering::SeqCst);
    Ok(true)
}

/// 单章下载安装（契约 §2.48 `audioCacheDownload`，同步阻塞实现，FFI 侧经
/// spawn_blocking 包装为非阻塞）
///
/// 逐条对齐 `AudioCacheManager.cacheChapter:107-199`：
/// ① 前置校验（bookUrl 空白 / book 不在 DB / chapter 不在 DB / isVolume /
///    playUrl 空 / JSON 数组 / HLS / 书源不在 DB → Err）
/// ②–⑧ 在 `(bookUrl, key16)` 分片锁内串行（[`chapter_lock`]，对齐原版
///    `chapterLock(...).withLock`：`AudioCacheManager.kt:44,117,414-416`）：
/// ② 幂等：已提交缓存（key16 + `.complete` + size>0）→ `already_cached` JSON
/// ③ 清理本 key 陈旧未提交文件（1 小时阈值）
/// ④ AnalyzeUrl + 书源 headers/cookie 语义流式下载（块级取消检查）
/// ⑤ size 校验 → rename 安装（失败退整文件复制后复验）
/// ⑥ `.complete` 三行元数据写入并回读校验
/// ⑦ 清理同 key 其他文件与标记（保留新装文件）
/// ⑧ 任一步失败删除已安装文件 + 标记 + tmp
///
/// 返回 JSON：`{"status":"installed"|"already_cached","path":…,"sizeBytes":N,
/// "extension":…}`。失败 **Err 上抛不降级**（有意区别于 §2.47 读面）。
pub fn audio_cache_download(
    book_url: &str,
    chapter_index: i32,
    chapter_url: &str,
    chapter_title: &str,
    play_url: &str,
) -> LegadoResult<String> {
    let client = crate::http_state::shared_client()?;
    audio_cache_download_with_client(
        &client,
        book_url,
        chapter_index,
        chapter_url,
        chapter_title,
        play_url,
    )
}

/// [`audio_cache_download`] 的客户端注入版（测试经本地回环服务器驱动）
fn audio_cache_download_with_client(
    client: &LegadoClient,
    book_url: &str,
    chapter_index: i32,
    chapter_url: &str,
    chapter_title: &str,
    play_url: &str,
) -> LegadoResult<String> {
    // ① 前置校验
    if kotlin_is_blank(book_url) {
        return Err(LegadoError::Ffi("书籍 URL 为空".into()));
    }
    let book = with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))?
        .ok_or_else(|| LegadoError::Database(format!("书籍不存在: {book_url}")))?;
    let chapter = with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, chapter_index)
    })?
    .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;
    if chapter.is_volume {
        return Err(LegadoError::Ffi("分卷章节不支持缓存".into()));
    }
    let source =
        with_database(|db| BookSourceRepository::new(db.connection()).find_by_url(&book.origin))?
            .ok_or_else(|| LegadoError::Database(format!("书源不存在: {}", book.origin)))?;
    require_cacheable_play_url(play_url)?;

    let key16 = cache_key16(chapter_url, chapter_title);
    let dir = book_dir(book_url);

    // ②–⑧ 临界区：同 (bookUrl, key16) 分片锁串行（对齐原版 `chapterLock`
    // `AudioCacheManager.kt:44,117,414-416` 的 `withLock` 范围）。无锁时两条
    // 同章下载会互相删除对方在写 tmp / 已装文件与标记，双方均报 installed
    // 但缓存净丢失（P1-1）。
    let chapter_shard = chapter_lock(book_url, &key16);
    let _chapter_guard = chapter_shard.lock().unwrap_or_else(|e| e.into_inner());

    // ② 幂等：已提交缓存直接返回（对齐原版服务循环 `AudioCacheService.kt:216` 跳过语义）
    if let Some((name, meta)) = latest_committed_file(&dir, &key16) {
        let extension = parse_cache_file_name(&name)
            .map(|p| p.extension)
            .unwrap_or_else(|| "audio".to_string());
        return Ok(serde_json::json!({
            "status": "already_cached",
            "path": dir.join(&name).to_string_lossy(),
            "sizeBytes": meta.len(),
            "extension": extension,
        })
        .to_string());
    }

    // ③ 目录就绪 + 陈旧未提交文件清理
    fs::create_dir_all(&dir).map_err(|e| {
        LegadoError::Io(io::Error::new(
            e.kind(),
            format!("音频缓存目录不可用 {dir:?}: {e}"),
        ))
    })?;
    cleanup_uncommitted_files(&dir, &key16);

    // 取消代数快照 + 在途登记（覆盖从发起到清理的全部路径）
    let cancel_snapshot = CANCEL_GEN.load(Ordering::SeqCst);
    let _inflight = InFlightGuard::new();

    // ④ AnalyzeUrl 解析 + 书源请求头/Cookie 语义（对齐原版构造
    // `AnalyzeUrl(playUrl, source=bookSource, ruleData=book, chapter=chapter)`：
    // 变量表 = book.variable ⊕ chapter.variable（章节优先），内置书名/标题/作者
    // 经 parse_with_context 注入；headers 合并顺序复用 fetch_page 全链路——
    // 书源 header+登录头（parse_source_headers 已含 CookieJar 写侧标记）→
    // AnalyzeUrl 解析头 → 请求 URL 属域 JS cookie）
    let merged_variable = crate::api::web_book::merge_variables_json(
        book.variable.as_deref(),
        chapter.variable.as_deref(),
    );
    let variables = crate::api::web_book::chapter_url_variables(merged_variable.as_deref());
    let context = TemplateContext {
        book_name: Some(book.name.clone()),
        title: Some(chapter.title.clone()),
        author: Some(book.author.clone()),
        extra: HashMap::new(),
    };
    let analyze_url = AnalyzeUrl::parse_with_context(play_url, &variables, &context, 1)?;

    let fetcher = crate::api::web_book::real_fetcher()?;
    let mut headers = fetcher.parse_source_headers(&source).unwrap_or_default();
    headers.extend(analyze_url.headers().clone());
    legado_js::host_api::cookie_store::merge_js_cookies(&mut headers, analyze_url.url());

    let body = analyze_url.request_body();
    let request = LegadoRequest {
        url: analyze_url.url().to_string(),
        method: match analyze_url.method() {
            legado_parser::RequestMethod::Post => Method::Post,
            legado_parser::RequestMethod::Head => Method::Head,
            legado_parser::RequestMethod::Get => Method::Get,
        },
        headers,
        body: if body.is_empty() {
            None
        } else {
            Some(body.to_string())
        },
        timeout: analyze_url.timeout().map(Duration::from_millis),
    };

    // urlOption followRedirects/retry 语义（对齐 analyze_request::send_with_options：
    // 不跟随走派生客户端；非 2xx/3xx 且 retry>0 时立即重发，至多 retry 次）
    let effective = if analyze_url.follow_redirects() == Some(false) {
        client.no_redirect_variant()?
    } else {
        client.clone()
    };
    let mut retries_remaining = analyze_url.retry();
    let mut response = loop {
        let resp = crate::runtime::block_on(effective.send_stream(&request))?;
        if (200..400).contains(&resp.status()) || retries_remaining == 0 {
            break resp;
        }
        retries_remaining -= 1;
    };
    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "网络请求失败({})",
            response.status()
        )));
    }

    // 扩展名三级探测（下载响应 Content-Type/最终 URL 或 HLS → 拒绝）
    let final_url = response.url().to_string();
    let extension = detect_extension(
        response.content_type().map(|s| s.as_str()),
        &final_url,
        play_url,
    )?;
    let expected_size = response.content_length().filter(|n| *n > 0);

    let revision = random_hex(8);
    let final_name = build_file_name(
        chapter_index,
        &key16,
        chapter_title,
        &md5_mid16(play_url),
        &revision,
        &extension,
    )?;
    let staged_path = dir.join(format!("tmp_{key16}_{revision}_{}.part", random_hex(32)));
    let final_path = dir.join(&final_name);
    let marker_path = dir.join(format!("{final_name}{COMPLETE_SUFFIX}"));

    let result: LegadoResult<u64> = (|| {
        // ④ 流式落盘（字节直写盘；块级取消检查对齐 copyCancellable:397-412）
        {
            let file = fs::File::create(&staged_path)?;
            let mut writer = io::BufWriter::new(file);
            loop {
                if cancel_generation_changed(cancel_snapshot) {
                    return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
                }
                match crate::runtime::block_on(response.next_chunk())? {
                    None => break,
                    Some(chunk) => writer.write_all(&chunk)?,
                }
            }
            writer.flush()?;
            if cancel_generation_changed(cancel_snapshot) {
                return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
            }
        }

        // ⑤ size 校验 + 安装（优先 rename，失败退整文件复制后复验）
        let staged_len = fs::metadata(&staged_path)?.len();
        require_complete_size(staged_len, expected_size)?;
        let installed_len = install_staged_file(&staged_path, &final_path, expected_size)?;

        // ⑥ 写 `.complete` 并回读校验（校验失败删标记报错）
        if cancel_generation_changed(cancel_snapshot) {
            return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
        }
        write_complete_marker(&marker_path, play_url)?;

        // ⑦ 清理同 key 其他文件与标记（保留新安装文件；计数不参与返回值）
        let _ = remove_cache_files(&dir, &key16, Some(&final_name));

        Ok(installed_len)
    })();

    let installed_size = match result {
        Ok(size) => size,
        Err(e) => {
            // ⑧ 失败清理：已安装文件 + 标记 + tmp（对齐 :190-197）
            let _ = fs::remove_file(&final_path);
            let _ = fs::remove_file(&marker_path);
            let _ = fs::remove_file(&staged_path);
            return Err(e);
        }
    };
    Ok(serde_json::json!({
        "status": "installed",
        "path": final_path.to_string_lossy(),
        "sizeBytes": installed_size,
        "extension": extension,
    })
    .to_string())
}

/// 暂存文件安装（对齐原版 `installStagedFile:232-264`）：优先同目录 rename，
/// 失败退整文件流式复制（块级取消检查）后复验 size；失败删除目标并上抛。
/// 返回安装后文件大小。
fn install_staged_file(
    staged_path: &Path,
    final_path: &Path,
    expected_size: Option<u64>,
) -> LegadoResult<u64> {
    match fs::rename(staged_path, final_path) {
        Ok(()) => {
            let len = fs::metadata(final_path)?.len();
            if let Err(e) = require_complete_size(len, expected_size) {
                let _ = fs::remove_file(final_path);
                return Err(e);
            }
            Ok(len)
        }
        Err(_) => {
            // SAF rename 失败（跨卷/被占用等）：整文件复制后复验
            let installed: LegadoResult<u64> = (|| {
                let mut input = fs::File::open(staged_path)?;
                let output = fs::File::create(final_path)?;
                let mut writer = io::BufWriter::new(output);
                io::copy(&mut input, &mut writer)?;
                writer.flush()?;
                let len = fs::metadata(final_path)?.len();
                require_complete_size(len, expected_size)?;
                Ok(len)
            })();
            match installed {
                Ok(len) => {
                    let _ = fs::remove_file(staged_path);
                    Ok(len)
                }
                Err(e) => {
                    let _ = fs::remove_file(final_path);
                    Err(e)
                }
            }
        }
    }
}

/// 写 `.complete` 标记并回读校验（对齐原版 `createCompleteMarker:266-281`）：
/// UTF-8 三行 `1\n{md5_16(playUrl)}\n{playUrl}`；写后 `decode == playUrl`
/// 否则删标记并 Err「音频缓存完成标记校验失败」
fn write_complete_marker(marker_path: &Path, play_url: &str) -> LegadoResult<()> {
    let write_result = (|| -> io::Result<()> {
        let mut file = fs::File::create(marker_path)?;
        file.write_all(encode_metadata(play_url).as_bytes())?;
        file.flush()
    })();
    if let Err(e) = write_result {
        let _ = fs::remove_file(marker_path);
        return Err(LegadoError::Io(e));
    }
    let read_back = fs::read_to_string(marker_path)
        .ok()
        .and_then(|s| decode_metadata(&s));
    if read_back.as_deref() != Some(play_url) {
        let _ = fs::remove_file(marker_path);
        return Err(LegadoError::Ffi("音频缓存完成标记校验失败".into()));
    }
    Ok(())
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::BookSource;
    use legado_db::repository::Repository;
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
            latest_committed_file(&dir, KEY_HELLO).map(|(n, _)| n),
            Some(new_name.clone())
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
        // 删除数 = 数据文件（**不含** .complete 标记，契约 §2.47 口径修正）
        assert_eq!(
            audio_cache_clear_chapter("https://a.com/book/4", 1, "hello", "第一章"),
            1
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
        // 删除数 = 两个数据文件（**不含** .complete 标记，契约 §2.47 口径修正）
        assert_eq!(audio_cache_clear_book("https://a.com/book/A"), 2);
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
        // 删除数 = 数据文件（不含 .complete 标记）
        assert_eq!(audio_cache_clear_book("https://a.com/book/5"), 1);
        // 复位注入槽为 None（不污染其他测试）
        if let Ok(mut guard) = INJECTED_DIR.get_or_init(|| Mutex::new(None)).lock() {
            *guard = None;
        }
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // ─── B2 写入面（契约 §2.48）─────────────────────────────────────────────

    /// 本地回环 HTTP 服务器（不联网）：按请求序号返回固定响应
    struct ServerReply {
        status: u16,
        content_type: &'static str,
        body: Vec<u8>,
        /// 覆盖 Content-Length 声明（默认实际 body 长度）
        declared_len: Option<u64>,
    }

    impl ServerReply {
        fn ok(content_type: &'static str, body: Vec<u8>) -> Self {
            Self {
                status: 200,
                content_type,
                body,
                declared_len: None,
            }
        }
    }

    /// 启动一次性回环服务器（请求序号从 0 起；线程随测试进程退出）
    fn spawn_server<F>(responder: F) -> (u16, std::sync::Arc<std::sync::atomic::AtomicUsize>)
    where
        F: Fn(usize) -> ServerReply + Send + Sync + 'static,
    {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::atomic::AtomicUsize;

        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
        let port = listener.local_addr().unwrap().port();
        let hits = std::sync::Arc::new(AtomicUsize::new(0));
        let hits_srv = std::sync::Arc::clone(&hits);
        let responder = std::sync::Arc::new(responder);
        std::thread::spawn(move || {
            let mut idx = 0usize;
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                let reply = responder(idx);
                idx += 1;
                hits_srv.fetch_add(1, Ordering::SeqCst);
                // 读请求头至 \r\n\r\n（不解析请求体；本路径均为 GET）
                let mut head = Vec::new();
                let mut b = [0u8; 1];
                while let Ok(1) = sock.read(&mut b) {
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let reason = if (200..300).contains(&reply.status) {
                    "OK"
                } else {
                    "Error"
                };
                let mut out = format!("HTTP/1.1 {} {reason}\r\n", reply.status);
                out.push_str(&format!("Content-Type: {}\r\n", reply.content_type));
                out.push_str(&format!(
                    "Content-Length: {}\r\n",
                    reply.declared_len.unwrap_or(reply.body.len() as u64)
                ));
                out.push_str("Connection: close\r\n\r\n");
                let _ = sock.write_all(out.as_bytes());
                let _ = sock.write_all(&reply.body);
                let _ = sock.flush();
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });
        (port, hits)
    }

    /// 回环测试客户端（no_proxy：测试流量不得经系统/环境代理路由）
    fn test_client() -> LegadoClient {
        LegadoClient::new(legado_net::LegadoClientConfig {
            no_proxy: true,
            ..legado_net::LegadoClientConfig::default()
        })
        .expect("构建测试 HTTP 客户端")
    }

    /// 插入音频书 + 书源 + 单章（测试 DB，唯一 bookUrl 隔离）
    fn insert_audio_book(
        book_url: &str,
        source_url: &str,
        chapter_url: &str,
        chapter_title: &str,
        is_volume: bool,
    ) {
        with_database(|db| {
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                // name 随 bookUrl 唯一：books 表有 (name, author) 唯一索引
                // （schema.rs:646），同名会被 INSERT OR REPLACE 顶掉
                name: format!("听书写入面测试-{book_url}"),
                author: String::new(),
                origin: source_url.to_string(),
                ..Default::default()
            };
            BookRepository::new(db.connection()).insert(&book)?;
            let source = BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "测试音频源".into(),
                ..BookSource::default()
            };
            BookSourceRepository::new(db.connection()).insert(&source)?;
            let chapter = legado_core::models::BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: chapter_title.to_string(),
                url: chapter_url.to_string(),
                is_volume,
                ..Default::default()
            };
            BookChapterRepository::new(db.connection()).insert(&chapter)?;
            Ok(())
        })
        .unwrap();
    }

    /// safeTitle 归一（对齐 AudioCachePolicy.kt:79-87 各边界）
    #[test]
    fn safe_title_normalization() {
        // 非法文件名字符替换 `_`（fileNameRegex2 不含 `.`，故 `.` 保留）；
        // 末尾 `?`→`_` 后被 trim('_') 去掉
        assert_eq!(safe_title("第一章:测试?"), "第一章_测试");
        assert_eq!(safe_title(r#"a\b/c*d"e<f>g|h"#), "a_b_c_d_e_f_g_h");
        assert_eq!(safe_title("第1.5章"), "第1.5章");
        // ISO 控制符去除（C0 + C1）
        assert_eq!(safe_title("a\u{0000}b\u{001F}c\u{007F}d\u{009F}e"), "abcde");
        // trim（Kotlin isWhitespace 语义）+ trim('_') 顺序
        assert_eq!(safe_title("  __标题__  "), "标题");
        assert_eq!(safe_title("__ 标题 __"), " 标题");
        // 空/全空白/全下划线 → chapter
        assert_eq!(safe_title(""), "chapter");
        assert_eq!(safe_title("   "), "chapter");
        assert_eq!(safe_title("___"), "chapter");
        // 截 40 字符后去尾部 `.`/空格；全被去除后回退 chapter
        let long = format!("{}..", "a".repeat(50));
        assert_eq!(safe_title(&long), "a".repeat(40));
        let dots = ".".repeat(45);
        assert_eq!(safe_title(&dots), "chapter");
        let mixed = format!("{}  ", "b".repeat(40));
        assert_eq!(safe_title(&mixed), "b".repeat(40));
        // NBSP 不属 Kotlin 空白 → 不被 trim 掉（Java 语义纠偏）
        assert_eq!(safe_title("\u{00A0}"), "\u{00A0}");
    }

    /// 扩展名三级探测与 HLS/多段拒绝（对齐 AudioCachePolicy.kt:25-65）
    #[test]
    fn extension_detection_and_rejections() {
        // playUrl 校验
        assert!(require_cacheable_play_url("")
            .unwrap_err()
            .to_string()
            .contains("播放链接为空"));
        assert!(require_cacheable_play_url("   ").is_err());
        assert!(require_cacheable_play_url("[{\"url\":\"a\"}]")
            .unwrap_err()
            .to_string()
            .contains("暂不支持缓存多段音频"));
        assert!(require_cacheable_play_url("https://x.com/a.M3U8?t=1")
            .unwrap_err()
            .to_string()
            .contains("暂不支持缓存 HLS 音频"));
        assert!(require_cacheable_play_url("https://x.com/a.m3u#frag").is_err());
        assert!(require_cacheable_play_url("https://x.com/a.mp3").is_ok());

        // Content-Type 优先映射
        assert_eq!(
            detect_extension(
                Some("audio/mpeg; charset=utf-8"),
                "https://x/a",
                "https://x/a"
            )
            .unwrap(),
            "mp3"
        );
        assert_eq!(
            detect_extension(Some("audio/mp4"), "https://x/a.m4b", "https://x/a.m4b").unwrap(),
            "m4a"
        );
        assert_eq!(
            detect_extension(Some("audio/x-flac"), "https://x/a", "https://x/a").unwrap(),
            "flac"
        );
        // Content-Type 缺失 → 最终 URL → playUrl → audio
        assert_eq!(
            detect_extension(None, "https://x.com/f.mp3?sign=1", "https://y/a").unwrap(),
            "mp3"
        );
        assert_eq!(
            detect_extension(None, "https://x.com/stream", "https://y.com/b.ogg#z").unwrap(),
            "ogg"
        );
        assert_eq!(
            detect_extension(None, "https://x.com/stream", "https://y/stream").unwrap(),
            "audio"
        );
        // Content-Type 存在但无已知子串（空串同）→ URL 兜底
        assert_eq!(
            detect_extension(Some(""), "https://x.com/f.aac", "https://y/a").unwrap(),
            "aac"
        );
        assert_eq!(
            detect_extension(
                Some("application/octet-stream"),
                "https://x.com/f",
                "https://y/a"
            )
            .unwrap(),
            "audio"
        );
        // HLS 拒绝：Content-Type 含 mpegurl / 最终 URL 为 m3u8
        assert!(detect_extension(
            Some("application/vnd.apple.mpegurl"),
            "https://x/a",
            "https://x/a"
        )
        .unwrap_err()
        .to_string()
        .contains("暂不支持缓存 HLS 音频"));
        assert!(detect_extension(None, "https://x/live.m3u8", "https://x/live").is_err());
        // URL 无点 → 不误判（substringAfterLast 缺省空串语义）
        assert_eq!(extension_from_url("https://x.com/stream"), None);
        assert_eq!(
            extension_from_url("https://x.com/a.MP3").as_deref(),
            Some("mp3")
        );
    }

    /// 五段式文件名与 `.complete` 元数据往返
    #[test]
    fn file_name_and_metadata_roundtrip() {
        let name = build_file_name(
            42,
            KEY_HELLO,
            "第一章",
            &md5_mid16("https://x/a.mp3"),
            "9f8e7d6c",
            "mp3",
        )
        .unwrap();
        assert!(name.starts_with("00042_bc4b2a76b9719d91_第一章_"));
        assert!(name.ends_with("_9f8e7d6c.mp3"));
        let parsed = parse_cache_file_name(&name).unwrap();
        assert_eq!(parsed.chapter_index, 42);
        assert_eq!(parsed.key16, KEY_HELLO);
        assert_eq!(parsed.extension, "mp3");
        // 先决条件不满足 → Err（对齐 Kotlin require）
        assert!(build_file_name(-1, KEY_HELLO, "t", &md5_mid16("x"), "9f8e7d6c", "mp3").is_err());
        assert!(build_file_name(1, KEY_HELLO, "t", "XYZ", "9f8e7d6c", "mp3").is_err());
        assert!(
            build_file_name(1, KEY_HELLO, "t", &md5_mid16("x"), "TOO_LONG_REV", "mp3").is_err()
        );
        assert!(build_file_name(1, KEY_HELLO, "t", &md5_mid16("x"), "9f8e7d6c", "txt").is_err());

        // 元数据编解码：三行、md5 校验、限 3 段（playUrl 可含换行）
        let url = "https://x.com/a.mp3?q=1";
        let encoded = encode_metadata(url);
        assert_eq!(encoded.lines().count(), 3);
        assert_eq!(decode_metadata(&encoded).as_deref(), Some(url));
        assert!(decode_metadata("1\nbad\nx").is_none());
        assert!(decode_metadata("2\nx\ny").is_none());
        assert!(decode_metadata("1\nx\n").is_none());
        let two_line_url = "https://x/a\nb";
        assert_eq!(
            decode_metadata(&encode_metadata(two_line_url)).as_deref(),
            Some(two_line_url)
        );
    }

    /// 陈旧未提交清理：1 小时阈值 + 已提交文件豁免
    #[test]
    fn cleanup_stale_threshold() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("stale");
        set_test_root(&root);
        let key = KEY_HELLO;
        let dir = book_dir("https://a.com/book/stale");
        fs::create_dir_all(&dir).unwrap();
        let old = UNIX_EPOCH + Duration::from_secs(1_000_000);
        let recent = SystemTime::now();

        let stale_tmp = format!("tmp_{key}_abc.part");
        let fresh_tmp = format!("tmp_{key}_def.part");
        let stale_uncommitted = valid_name(1, key, "mp3");
        let fresh_uncommitted = valid_name(2, key, "mp3");
        let stale_committed = valid_name(3, key, "mp3");
        for name in [
            &stale_tmp,
            &fresh_tmp,
            &stale_uncommitted,
            &fresh_uncommitted,
            &stale_committed,
        ] {
            fs::write(dir.join(name), vec![7u8; 8]).unwrap();
        }
        fs::write(
            dir.join(format!("{stale_committed}{COMPLETE_SUFFIX}")),
            b"1\nx\nx",
        )
        .unwrap();
        for (name, t) in [
            (&stale_tmp, old),
            (&stale_uncommitted, old),
            (&stale_committed, old),
            (&fresh_tmp, recent),
            (&fresh_uncommitted, recent),
        ] {
            fs::OpenOptions::new()
                .write(true)
                .open(dir.join(name))
                .unwrap()
                .set_modified(t)
                .unwrap();
        }

        cleanup_uncommitted_files(&dir, key);
        assert!(!dir.join(&stale_tmp).exists(), "陈旧 tmp 应删除");
        assert!(
            !dir.join(&stale_uncommitted).exists(),
            "陈旧未提交五段式应删除"
        );
        assert!(dir.join(&stale_committed).exists(), "已提交文件不得删除");
        assert!(dir.join(&fresh_tmp).exists(), "未到 1 小时的 tmp 保留");
        assert!(
            dir.join(&fresh_uncommitted).exists(),
            "未到 1 小时的未提交文件保留"
        );
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 前置校验：bookUrl/书籍/章节/分卷/书源/playUrl 全部门禁（不触网）
    #[test]
    fn download_validation_errors() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-validation");
        set_test_root(&root);
        let client = test_client();

        // bookUrl 空白
        assert!(
            audio_cache_download_with_client(&client, "  ", 0, "u", "t", "https://x/a.mp3")
                .unwrap_err()
                .to_string()
                .contains("书籍 URL 为空")
        );
        // 书籍不存在
        assert!(audio_cache_download_with_client(
            &client,
            "https://a.com/no-book",
            0,
            "u",
            "t",
            "https://x/a.mp3"
        )
        .unwrap_err()
        .to_string()
        .contains("书籍不存在"));
        // 章节不存在
        let book_url = "https://a.com/book/dl-val";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        assert!(audio_cache_download_with_client(
            &client,
            book_url,
            9,
            "hello",
            "第一章",
            "https://x/a.mp3"
        )
        .unwrap_err()
        .to_string()
        .contains("章节 9 不存在"));
        // 分卷章节拒绝（原版文案）
        let vol_url = "https://a.com/book/dl-vol";
        insert_audio_book(
            vol_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            true,
        );
        assert!(audio_cache_download_with_client(
            &client,
            vol_url,
            0,
            "hello",
            "第一章",
            "https://x/a.mp3"
        )
        .unwrap_err()
        .to_string()
        .contains("分卷章节不支持缓存"));
        // playUrl 空 / JSON 多段 / HLS
        for (play, msg) in [
            ("", "播放链接为空"),
            ("[{\"url\":\"x\"}]", "暂不支持缓存多段音频"),
            ("https://x/live.m3u8", "暂不支持缓存 HLS 音频"),
        ] {
            let err =
                audio_cache_download_with_client(&client, book_url, 0, "hello", "第一章", play)
                    .unwrap_err()
                    .to_string();
            assert!(err.contains(msg), "playUrl={play:?} 应报 {msg}: {err}");
        }
        // 书源不在 DB（origin 指向未入库的书源 URL；不入书源行）
        let no_src_url = "https://a.com/book/dl-nosrc";
        with_database(|db| {
            let book = legado_core::models::Book {
                book_url: no_src_url.to_string(),
                name: "无书源测试".into(),
                origin: "https://source.example/never-inserted".into(),
                ..Default::default()
            };
            BookRepository::new(db.connection()).insert(&book)?;
            let chapter = legado_core::models::BookChapter {
                book_url: no_src_url.to_string(),
                index: 0,
                title: "第一章".into(),
                url: "hello".into(),
                ..Default::default()
            };
            BookChapterRepository::new(db.connection()).insert(&chapter)?;
            Ok(())
        })
        .unwrap();
        assert!(audio_cache_download_with_client(
            &client,
            no_src_url,
            0,
            "hello",
            "第一章",
            "https://x/a.mp3"
        )
        .unwrap_err()
        .to_string()
        .contains("书源不存在"));

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 幂等：已提交缓存直接 already_cached（不发网络请求）
    #[test]
    fn download_idempotent_already_cached() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-idem");
        set_test_root(&root);
        let book_url = "https://a.com/book/dl-idem";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let dir = book_dir(book_url);
        write_cache_file(&dir, &valid_name(0, KEY_HELLO, "mp3"), 2048, true);

        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            "https://x/a.mp3",
        )
        .unwrap();
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["status"], "already_cached");
        assert_eq!(json["sizeBytes"], 2048);
        assert_eq!(json["extension"], "mp3");
        assert!(json["path"].as_str().unwrap().ends_with(".mp3"));
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 下载安装全链路：流式落盘 + rename 安装 + `.complete` 回读 + 旧版本清理 + 幂等
    #[test]
    fn download_installs_and_cleans_old_versions() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-install");
        set_test_root(&root);
        let body = vec![0xABu8; 64 * 1024];
        let (port, hits) =
            spawn_server(move |_i| ServerReply::ok("audio/mpeg; charset=utf-8", body.clone()));
        let book_url = "https://a.com/book/dl-install";
        let play_url = format!("http://127.0.0.1:{port}/media.mp3");
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        // 预置同 key 旧版本（未提交）+ tmp 残留：安装后应仅保留新文件
        let dir = book_dir(book_url);
        write_cache_file(&dir, &valid_name(0, KEY_HELLO, "m4a"), 8, false);
        fs::write(dir.join(format!("tmp_{KEY_HELLO}_old.part")), b"stale").unwrap();

        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap();
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["status"], "installed");
        assert_eq!(json["sizeBytes"], 64 * 1024);
        assert_eq!(json["extension"], "mp3");
        let path = json["path"].as_str().unwrap();
        assert!(path.ends_with(".mp3"));
        assert_eq!(fs::metadata(path).unwrap().len(), 64 * 1024);
        // `.complete` 三行元数据 + 回读校验
        let marker = format!("{path}{COMPLETE_SUFFIX}");
        let meta = fs::read_to_string(&marker).unwrap();
        assert_eq!(meta, encode_metadata(&play_url));
        assert_eq!(decode_metadata(&meta).as_deref(), Some(play_url.as_str()));
        // 旧版本与 tmp 已清理，仅剩 1 数据 + 1 标记
        let names: Vec<String> = super::read_dir_entries(&dir)
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert_eq!(names.len(), 2, "目录应只剩新文件与标记: {names:?}");
        assert!(audio_cache_query(book_url, 0, "hello", "第一章"));
        assert_eq!(audio_cache_list(book_url), vec![0]);
        // 幂等：二次调用不再发请求
        let out2 = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&out2).unwrap()["status"],
            "already_cached"
        );
        assert_eq!(hits.load(Ordering::SeqCst), 1, "已缓存不得重下");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 失败清理：HTTP 非 2xx / 空体 / 流中断后不留残file
    #[test]
    fn download_failures_leave_no_residue() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-fail");
        set_test_root(&root);
        let book_url = "https://a.com/book/dl-fail";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let dir = book_dir(book_url);

        // HTTP 500 → 网络请求失败(500)
        let (port_500, _) = spawn_server(|_i| ServerReply {
            status: 500,
            content_type: "text/plain",
            body: b"boom".to_vec(),
            declared_len: None,
        });
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &format!("http://127.0.0.1:{port_500}/x.mp3"),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("网络请求失败(500)"), "err={err}");

        // 空体（Content-Length: 0）→ 音频文件为空
        let (port_empty, _) = spawn_server(|_i| ServerReply::ok("audio/mpeg", Vec::new()));
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &format!("http://127.0.0.1:{port_empty}/x.mp3"),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("音频文件为空"), "err={err}");

        // 声明 100 但只发 10（连接关闭）→ 读流失败，且无任何残file
        let (port_short, _) = spawn_server(|_i| ServerReply {
            status: 200,
            content_type: "audio/mpeg",
            body: vec![1u8; 10],
            declared_len: Some(100),
        });
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &format!("http://127.0.0.1:{port_short}/x.mp3"),
        )
        .unwrap_err()
        .to_string();
        assert!(!err.is_empty());

        // 三次失败后目录不得有任何残留（tmp/数据/标记）
        let names: Vec<String> = super::read_dir_entries(&dir)
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败后不得残留文件: {names:?}");
        assert!(!audio_cache_query(book_url, 0, "hello", "第一章"));

        // 纯函数 size 校验分支（流中断以外的「不完整」判据）
        assert!(require_complete_size(0, None)
            .unwrap_err()
            .to_string()
            .contains("音频文件为空"));
        assert!(require_complete_size(10, Some(100))
            .unwrap_err()
            .to_string()
            .contains("音频文件不完整"));
        assert!(require_complete_size(100, Some(100)).is_ok());
        assert!(require_complete_size(10, None).is_ok());

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 取消：无在途返回 false；在途置位后流式拷贝中止并清理
    #[test]
    fn cancel_aborts_inflight_download() {
        use std::io::Read as _;
        use std::io::Write as _;
        use std::net::TcpListener;

        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-cancel");
        set_test_root(&root);

        // 慢速服务器：每 30ms 发 32KB，共 64 块（≈2MB）——足够长以观测取消
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                let mut head = Vec::new();
                let mut b = [0u8; 1];
                while let Ok(1) = sock.read(&mut b) {
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let total = 64 * 32 * 1024u64;
                let _ = sock.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
                    )
                    .as_bytes(),
                );
                let chunk = vec![9u8; 32 * 1024];
                for _ in 0..64 {
                    if sock.write_all(&chunk).is_err() {
                        break;
                    }
                    let _ = sock.flush();
                    std::thread::sleep(Duration::from_millis(30));
                }
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });

        // 无在途 → false（本测试持 TEST_LOCK，其他下载测试不会并发在途）
        assert!(!audio_cache_cancel().unwrap(), "无在途下载应返回 false");

        let book_url = "https://a.com/book/dl-cancel";
        let play_url = format!("http://127.0.0.1:{port}/slow.mp3");
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let dir = book_dir(book_url);
        let worker = std::thread::spawn(move || {
            let client = test_client();
            audio_cache_download_with_client(&client, book_url, 0, "hello", "第一章", &play_url)
        });

        // 等待在途登记（下载线程在发起网络前即 +1）
        let mut waited_ms = 0u32;
        while IN_FLIGHT.load(Ordering::SeqCst) == 0 && waited_ms < 3000 {
            std::thread::sleep(Duration::from_millis(10));
            waited_ms += 10;
        }
        assert_eq!(IN_FLIGHT.load(Ordering::SeqCst), 1, "在途计数应为 1");
        std::thread::sleep(Duration::from_millis(120));

        assert!(audio_cache_cancel().unwrap(), "置位时应快照到在途下载");
        let err = worker.join().unwrap().unwrap_err().to_string();
        assert!(err.contains("音频缓存下载已取消"), "err={err}");

        // 部分文件必须清理（无 tmp、无数据、无标记）
        let names: Vec<String> = super::read_dir_entries(&dir)
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "取消后不得残留部分文件: {names:?}");
        assert_eq!(IN_FLIGHT.load(Ordering::SeqCst), 0, "在途计数应复位");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// P1-1：同 `(bookUrl, key16)` 并发下载被分片锁串行化——恰好一个
    /// `installed`、一个 `already_cached`，最终缓存真实存在且可被读面命中，
    /// 无残留 tmp。修复前：两任务各自越过幂等检查（慢速服务器拉长窗口）互删
    /// 产物，双 `installed` 且第二个请求重下（hits=2）。
    #[test]
    fn concurrent_same_key_downloads_are_serialized() {
        use std::io::Read as _;
        use std::io::Write as _;
        use std::net::TcpListener;

        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-concurrent");
        set_test_root(&root);

        // 慢速服务器：32KB/块 × 64 块、每块 24ms（≈1.5s）——修复前第二个任务
        // 在第一个安装完成前即越过幂等检查并独立下载（互删对方 tmp/已装文件）；
        // 修复后第二个任务阻塞在分片锁上，解锁后幂等命中，全程仅 1 个请求
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let hits = std::sync::Arc::new(AtomicUsize::new(0));
        let hits_srv = std::sync::Arc::clone(&hits);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                hits_srv.fetch_add(1, Ordering::SeqCst);
                let mut head = Vec::new();
                let mut b = [0u8; 1];
                while let Ok(1) = sock.read(&mut b) {
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let total = 64 * 32 * 1024u64;
                let _ = sock.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
                    )
                    .as_bytes(),
                );
                let chunk = vec![5u8; 32 * 1024];
                for _ in 0..64 {
                    if sock.write_all(&chunk).is_err() {
                        break;
                    }
                    let _ = sock.flush();
                    std::thread::sleep(Duration::from_millis(24));
                }
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });

        let book_url = "https://a.com/book/dl-concurrent";
        let play_url = format!("http://127.0.0.1:{port}/same.mp3");
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );

        // 两个线程同时对同一 (bookUrl, 章节 key) 发起下载
        let handles: Vec<_> = (0..2)
            .map(|_| {
                let play = play_url.clone();
                std::thread::spawn(move || {
                    let client = test_client();
                    audio_cache_download_with_client(&client, book_url, 0, "hello", "第一章", &play)
                })
            })
            .collect();
        let results: Vec<LegadoResult<String>> =
            handles.into_iter().map(|h| h.join().unwrap()).collect();

        let mut statuses = Vec::new();
        let mut paths = Vec::new();
        for r in &results {
            let out = r.as_ref().expect("并发下载均应成功返回");
            let json: serde_json::Value = serde_json::from_str(out).unwrap();
            statuses.push(json["status"].as_str().unwrap().to_string());
            paths.push(json["path"].as_str().unwrap().to_string());
        }
        statuses.sort();
        assert_eq!(
            statuses,
            vec!["already_cached", "installed"],
            "同 key 并发应收敛为一次实装 + 一次幂等命中（修复前为双 installed）"
        );
        assert_eq!(
            hits.load(Ordering::SeqCst),
            1,
            "第二个任务应在锁内幂等命中，不得重复发请求"
        );
        // 实装结果与幂等命中指向同一份文件，且文件真实存在
        assert_eq!(paths[0], paths[1], "already_cached 应指向 installed 的文件");
        assert!(
            std::path::Path::new(&paths[0]).exists(),
            "installed 返回的 path 必须真实存在（修复前可能已被对方清理）"
        );
        // 缓存可被读面命中（无静默丢失），无残留 tmp
        assert!(audio_cache_query(book_url, 0, "hello", "第一章"));
        assert_eq!(audio_cache_list(book_url), vec![0]);
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert_eq!(
            names.len(),
            2,
            "并发结束后目录应只剩 1 数据 + 1 标记: {names:?}"
        );
        assert!(
            names.iter().all(|n| !n.ends_with(PART_SUFFIX)),
            "不得残留 tmp: {names:?}"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 任务一（清理面取锁）：下载在途时清理同章必须**等待下载完成**再删
    /// （对齐原版 `removeCachedChapter:92-105` 的 suspend + `chapterLock`
    /// `withLock`），两者结果自洽：下载 `installed`，清理随后删除其安装产物
    /// （返回 1），读面转为未命中，目录无残留 tmp/标记。
    ///
    /// 修复前（清理不取锁，实测取证）：清理在下载流式写入期间删除在写
    /// tmp（计数含 tmp 返回 1），下载随后安装 rename 失败报错 NotFound
    /// ——两者互删不自洽（红）；加锁后清理等比等待，下载完整安装后清理
    /// 再删除（绿）。
    #[test]
    fn clear_chapter_waits_inflight_download_and_wins() {
        use std::io::Read as _;
        use std::io::Write as _;
        use std::net::TcpListener;

        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("clear-concurrent");
        set_test_root(&root);

        // 慢速服务器：32KB/块 × 64 块、每块 24ms（≈1.5s）——给清理一个
        // 确定的「下载持锁在途」窗口
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                let mut head = Vec::new();
                let mut b = [0u8; 1];
                while let Ok(1) = sock.read(&mut b) {
                    head.push(b[0]);
                    if head.ends_with(b"\r\n\r\n") {
                        break;
                    }
                }
                let total = 64 * 32 * 1024u64;
                let _ = sock.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
                    )
                    .as_bytes(),
                );
                let chunk = vec![3u8; 32 * 1024];
                for _ in 0..64 {
                    if sock.write_all(&chunk).is_err() {
                        break;
                    }
                    let _ = sock.flush();
                    std::thread::sleep(Duration::from_millis(24));
                }
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });

        let book_url = "https://a.com/book/dl-clear-concurrent";
        let play_url = format!("http://127.0.0.1:{port}/slow.mp3");
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );

        let play = play_url.clone();
        let worker = std::thread::spawn(move || {
            let client = test_client();
            audio_cache_download_with_client(&client, book_url, 0, "hello", "第一章", &play)
        });

        // 等待在途登记：下载在锁内、发起网络前 +1 → 此刻锁已被下载持有
        let mut waited_ms = 0u32;
        while IN_FLIGHT.load(Ordering::SeqCst) == 0 && waited_ms < 3000 {
            std::thread::sleep(Duration::from_millis(10));
            waited_ms += 10;
        }
        assert_eq!(IN_FLIGHT.load(Ordering::SeqCst), 1, "下载应在途持锁");
        std::thread::sleep(Duration::from_millis(100));

        // 清理在分片锁上等待下载完成，随后删除其安装产物（返回数据文件数 1）
        let removed = audio_cache_clear_chapter(book_url, 0, "hello", "第一章");
        let out = worker.join().unwrap().expect("在途下载应成功完成");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["status"].as_str().unwrap(), "installed");
        assert_eq!(
            removed, 1,
            "清理应删除下载安装的 1 个数据文件（.complete 标记照删不计）"
        );
        assert!(
            !audio_cache_query(book_url, 0, "hello", "第一章"),
            "清理后读面应未命中（无互删残留）"
        );
        assert!(audio_cache_list(book_url).is_empty());
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "清理后不得残留 tmp/数据/标记: {names:?}");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// P2-5 残态取证：目录仅剩孤儿 `.complete`（无同名数据文件）时，
    /// `audio_cache_clear_chapter` 按冻结口径返回 `0`（仅统计数据文件），
    /// 但标记照删——对齐原版 `removeCacheFiles:338-356`（标记照删）与
    /// `hasCacheFiles:374-383`（含标记 → 原版 UI 报「已清除本章缓存」）。
    /// Dart 提示由返回值 0 驱动 → 与原文案相反，已登记待裁决。
    #[test]
    fn clear_chapter_removes_orphan_marker_with_zero_count() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let root = unique_root("clear-orphan-marker");
        set_test_root(&root);
        let dir = book_dir("https://a.com/book/orphan");
        let name = valid_name(1, KEY_HELLO, "mp3");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(format!("{name}{COMPLETE_SUFFIX}")), b"1\nx\nx").unwrap();

        assert_eq!(
            audio_cache_clear_chapter("https://a.com/book/orphan", 1, "hello", "第一章"),
            0,
            "冻结口径：返回值只统计数据文件（不含标记）"
        );
        assert!(
            !dir.join(format!("{name}{COMPLETE_SUFFIX}")).exists(),
            "孤儿标记应被删除（对齐原版 removeCacheFiles 标记照删）"
        );
        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }
}
