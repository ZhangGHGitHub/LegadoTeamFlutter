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

use legado_core::crypto::AesCrypto;
use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};
use legado_fetcher::web_book::{is_login_header_site, SourceHeaderSet};
use legado_net::{LegadoClient, LegadoRequest, LegadoStreamResponse, Method};
use legado_parser::{AnalyzeUrl, TemplateContext};

use crate::api::hls_playlist::{
    parse_playlist, select_playlist_uri, ByteRange, HlsKey, InitMap, MediaPlaylist, Playlist,
};
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
/// `audio` 为原版 detectExtension 的兜底扩展名）。
///
/// `ts` 为本仓扩展（批 2 线 B）：HLS 明文 TS 分片合并产物的扩展名，
/// 契约 §2.48「HLS 合并产物扩展名」登记；不加入白名单则产物无法被
/// 五段式正则识别，读面永远命中不到。
const AUDIO_EXTENSIONS: &[&str] = &[
    "mp3", "m4a", "m4b", "aac", "ogg", "oga", "opus", "wav", "flac", "webm", "amr", "3gp", "ts",
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

/// `cfg(test)` 合并体积上限覆盖槽（P2-5：2 GiB 无法实测，注入小上限）
#[cfg(test)]
static TEST_MERGE_MAX_BYTES: OnceLock<Mutex<Option<u64>>> = OnceLock::new();

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
///
/// 播放链读取面（[`audio_cache_get_file`]）与本模块其余读面共用此命中判定；
/// 可见性提到 `pub(crate)` 供后续批次的播放链复用，语义不变。
pub(crate) fn latest_committed_file(dir: &Path, key16: &str) -> Option<(String, fs::Metadata)> {
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

/// 取某章已缓存音频文件的本地绝对路径（契约 §2.47 `audioCacheGetFile`，只读、幂等）
///
/// **播放链读取面（P0，2026-11-18）**：对齐原版 `AudioPlay.kt:388-423` 播放第一步
/// `AudioCacheManager.getCachedAudio(...)`——命中即完全跳网络。此前本仓播放链
/// 只走「DB 文本缓存 → 网络取址」，预下载产物永远不会被播放使用。
///
/// 入参只给 `book_url + chapter_index`（Dart `AudioChapter` 不含 `chapterUrl`）：
/// 键所需的 `chapter.url / chapter.title` 由本函数自 DB 载入章节后按既有
/// [`cache_key16`] 规则计算，与 `audioCacheQuery` / `audioCacheDownload` 完全同源。
///
/// 命中判定与 [`audio_cache_query`] 完全一致（key 匹配 + `.complete` 存在 +
/// `size > 0`，同名多条取 `lastModified` 最新），命中返回数据文件**绝对路径**。
///
/// 失败一律降级 `None`（书/章不在 DB、目录不存在、无权限、解析异常）——
/// **不抛异常**：缓存是加速器不是数据源，调用方回落在线取流（同 §2.47 口径）。
/// **只读**：不改文件、不写 `.complete`（写入仍唯一发生于 §2.48 预下载）。
pub fn audio_cache_get_file(book_url: &str, chapter_index: i32) -> Option<String> {
    if kotlin_is_blank(book_url) {
        return None;
    }
    let chapter = with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, chapter_index)
    })
    .ok()??;
    let key16 = cache_key16(&chapter.url, &chapter.title);
    let dir = book_dir(book_url);
    let (name, _meta) = latest_committed_file(&dir, &key16)?;
    Some(dir.join(name).to_string_lossy().into_owned())
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
/// 空 / JSON 数组多段 → Err（原文案，写入面上抛不降级）。
///
/// **HLS 不再拒绝**（批 2 线 B，契约 §2.48 变更）：`.m3u8`/`.m3u` 走
/// [`download_hls_and_install`] 合并单文件路径。
///
/// **多段（JSON 数组）保持拒绝是「有意对齐原版」，不是待办缺口**
/// （2026-11-20 用户裁决）：原版 `AudioCachePolicy.kt:27-29` 对
/// `isJsonArray()` 直接 `throw UnsupportedOperationException("暂不支持缓存多段音频")`，
/// 参考版无此功能。注意区分——**多段播放**原版支持（`AudioPlayService.kt:312`
/// 走 `ExoPlayerHelper.getMediaSource` 拼接），我方播放侧亦已支持逐段串播
/// （`audio_segments.dart`），**只有缓存被拒**。后续请勿把此 Err 当作缺口去补。
fn require_cacheable_play_url(play_url: &str) -> LegadoResult<()> {
    if kotlin_is_blank(play_url) {
        return Err(LegadoError::Ffi("播放链接为空".into()));
    }
    if is_json_array(play_url) {
        return Err(LegadoError::Ffi("暂不支持缓存多段音频".into()));
    }
    Ok(())
}

/// HLS 判定（响应侧口径）：Content-Type 含 `mpegurl` 或最终 URL 以
/// `.m3u8`/`.m3u` 结尾——两条任一成立即按 HLS 合并路径处理
fn is_hls_response(content_type: Option<&str>, final_url: &str) -> bool {
    content_type
        .map(|ct| ct.split(';').next().unwrap_or("").trim().to_lowercase())
        .is_some_and(|ct| ct.contains("mpegurl"))
        || is_hls_url(final_url)
}

/// 扩展名三级探测（对齐原版 `AudioCachePolicy.detectExtension:35-65`）：
/// Content-Type（截 `;`/trim/小写）→ 最终 URL 后缀 → playUrl 后缀 → 缺省
/// `"audio"`。
///
/// **HLS 分支已改**（批 2 线 B，契约 §2.48）：不再 Err，改为返回**合并产物**
/// 扩展名——调用方须已确认 playlist 是否含 `EXT-X-MAP`；`has_init_map=true`
/// （fMP4）返回 `m4a`，否则（MPEG-TS 分片直拼）返回 `ts`。
fn detect_extension(
    content_type: Option<&str>,
    final_url: &str,
    play_url: &str,
    has_init_map: bool,
) -> LegadoResult<String> {
    require_cacheable_play_url(play_url)?;
    if is_hls_response(content_type, final_url) || is_hls_url(play_url) {
        return Ok(hls_merged_extension(has_init_map).to_string());
    }
    let normalized =
        content_type.map(|ct| ct.split(';').next().unwrap_or("").trim().to_lowercase());
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
///    playUrl 空 / JSON 数组 / 书源不在 DB → Err）。
///    **HLS 不在此列**：`.m3u8`/`.m3u`（或响应 Content-Type / 内容嗅探判定为
///    HLS）改走 [`download_hls_and_install`] 合并路径，失败同样 Err 上抛。
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
    // 书源 header+登录头（parse_source_headers_for_url 按请求 URL 同站门控，
    // 已含 CookieJar 写侧标记）→ AnalyzeUrl 解析头 → 请求 URL 属域 JS cookie）
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
    // 书源 header 按音频请求最终 URL 门控登录头（原版 #1099：
    // 媒体资源常托管在第三方 CDN，跨域不携带认证信息；无法判定域名时保持旧行为）
    let base_url = analyze_url.base_url();
    let base_url = if base_url.trim().is_empty() {
        None
    } else {
        Some(base_url)
    };
    // 书源 header 保留「静态头 / 登录头」两份（P2-6）：登录头必须**逐请求**
    // 按目标 URL 同站门控，不能像此前那样在 playlist 上一次判定后原样复用给
    // 全部 segment/key（这些常在不同域名的 CDN 上 → 凭据外泄给第三方）。
    let header_set = fetcher.parse_source_header_set(&source);
    let source_url = source.book_source_url.clone();
    // playUrl 的 `,{options}` 显式声明的头：属于该媒体请求本身（非登录态），
    // 对 playlist 与全部 segment/key 一致发送。
    let extra_headers = analyze_url.headers().clone();
    let mut headers = header_set
        .for_request(&source_url, analyze_url.url(), base_url)
        .unwrap_or_default();
    headers.extend(extra_headers.clone());
    legado_js::host_api::cookie_store::merge_js_cookies(&mut headers, analyze_url.url());
    // 批29b 审查 P2-6：`proxy` 是源 header 的代理配置键而非 HTTP 头
    // （上游 AnalyzeUrl 提取后即删除），合并后发送前必须剔除，避免代理凭据
    // 随音频下载请求外泄。
    legado_fetcher::web_book::strip_proxy_header(&mut headers);

    let body = analyze_url.request_body();
    // 解析后的请求 URL（playUrl 原串可能带 `,{options}` 模板尾巴，HLS 后缀判定
    // 必须用解析后 URL）
    let request_url = analyze_url.url().to_string();
    let request = LegadoRequest {
        url: request_url.clone(),
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

    let final_url = response.url().to_string();
    let content_type = response.content_type().cloned();

    // ─── HLS 分支（批 2 线 B，契约 §2.48）：合并单文件路径 ───────────────
    // 判定三层（任一成立即按 HLS 处理）：
    // ① 解析后请求 URL 以 `.m3u8`/`.m3u` 结尾（用 `analyze_url.url()` 而非
    //    playUrl 原串——原串可能带 `,{options}` 模板尾巴）；
    // ② 响应 Content-Type 含 `mpegurl` 或最终 URL 为 HLS；
    // ③ **内容嗅探**：首块以 `#EXTM3U` 开头（无扩展名 m3u8，批 47 真机风险②——
    //    部分站点返回 `application/octet-stream`，仅靠 ①② 会误当二进制音频）。
    let meta_hls = is_hls_url(&request_url) || is_hls_response(content_type.as_deref(), &final_url);
    let mut first_chunk = next_chunk_checked(&mut response, cancel_snapshot)?;
    let sniff_hls = first_chunk.as_deref().is_some_and(looks_like_m3u8);
    if meta_hls || sniff_hls {
        let mut playlist_bytes = first_chunk.take().unwrap_or_default();
        let rest = read_stream_capped(&mut response, HLS_META_MAX_BYTES, cancel_snapshot)?;
        if playlist_bytes.len() as u64 + rest.len() as u64 > HLS_META_MAX_BYTES {
            return Err(LegadoError::Network(format!(
                "HLS 资源超出上限（>{} 字节）",
                HLS_META_MAX_BYTES
            )));
        }
        playlist_bytes.extend_from_slice(&rest);
        drop(response);
        return download_hls_and_install(
            &effective,
            &dir,
            &key16,
            chapter_index,
            chapter_title,
            play_url,
            &header_set,
            &source_url,
            &extra_headers,
            &final_url,
            playlist_bytes,
            cancel_snapshot,
        );
    }

    // 扩展名三级探测（非 HLS：Content-Type → 最终 URL → playUrl → audio）
    let extension = detect_extension(content_type.as_deref(), &final_url, play_url, false)?;
    let expected_size = response.content_length().filter(|n| *n > 0);
    // 嗅探已消费的首块必须写回（非 HLS 路径不得丢字节）
    let sniffed_head = first_chunk.take();

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
            // 嗅探阶段已消费的首块先写回（非 HLS 路径不得丢字节）
            if let Some(head) = sniffed_head.as_ref() {
                writer.write_all(head)?;
            }
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

// ─── HLS 合并下载路径（批 2 线 B，契约 §2.48）───────────────────────────────

/// HLS 元数据（playlist / key）单次读取上限：1MB（契约 §2.48）
const HLS_META_MAX_BYTES: u64 = 1024 * 1024;

/// HLS 单个分片读取上限：64MB。分片本身可达数 MB，但必须有界——无限上限
/// 会让坏 playlist（或恶意服务端）把内存/磁盘打满；超限如实报错而非静默截断。
const HLS_SEGMENT_MAX_BYTES: u64 = 64 * 1024 * 1024;

/// HLS 合并产物总体积上限：2 GiB（P2-5）
///
/// 单段 64MB 上限 + 段数无界，1MB playlist 可声明上万段 → 磁盘写满无提示。
/// 2 GiB 足以覆盖任何有声书单章（典型 20–200MB，超长章节亦远低于此），
/// 同时把「坏 playlist / 恶意服务端」的破坏面限制在可控范围。
const HLS_MERGE_MAX_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// 跨站请求必须剔除的 playUrl 显式头键（P2-1，大小写不敏感）
///
/// 这些键承载认证凭据：`Cookie` / `Authorization` / `Proxy-Authorization`。
/// 防盗链所需的 `Referer` / `User-Agent` 等**不**在此列（跨站照发）。
const SENSITIVE_EXTRA_HEADERS: &[&str] = &["cookie", "authorization", "proxy-authorization"];

/// playUrl 显式头键是否为敏感凭据键（P2-1，大小写不敏感）
fn is_sensitive_extra_header(name: &str) -> bool {
    SENSITIVE_EXTRA_HEADERS
        .iter()
        .any(|sensitive| name.eq_ignore_ascii_case(sensitive))
}

/// HLS 合并产物扩展名：fMP4（有 `EXT-X-MAP`）→ `m4a`；MPEG-TS 分片直拼 → `ts`
fn hls_merged_extension(has_init_map: bool) -> &'static str {
    if has_init_map {
        "m4a"
    } else {
        "ts"
    }
}

/// 读取下一块（块级取消检查；`None` 表示流结束）
fn next_chunk_checked(
    response: &mut LegadoStreamResponse,
    cancel_snapshot: u64,
) -> LegadoResult<Option<Vec<u8>>> {
    if cancel_generation_changed(cancel_snapshot) {
        return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
    }
    crate::runtime::block_on(response.next_chunk())
}

/// m3u8 内容嗅探：去掉 UTF-8 BOM 与前导空白后以 `#EXTM3U` 开头
///
/// 用于「无扩展名 + 无正确 Content-Type」的 HLS（批 47 真机风险②：
/// 部分站点对 `.m3u8` 返回 `application/octet-stream`）。只看首块即可判定——
/// RFC 8216 要求 `#EXTM3U` 为首行。
fn looks_like_m3u8(first_chunk: &[u8]) -> bool {
    let text = String::from_utf8_lossy(first_chunk);
    let trimmed = text.strip_prefix('\u{feff}').unwrap_or(&text);
    trimmed.trim_start().starts_with("#EXTM3U")
}

/// 流式读取响应至多 `max_bytes`（块级取消检查，对齐 `copyCancellable`）。
/// 声明长度超限 → 读 body 前快速拒绝；逐块累计超限 → 中止并报错。
fn read_stream_capped(
    response: &mut LegadoStreamResponse,
    max_bytes: u64,
    cancel_snapshot: u64,
) -> LegadoResult<Vec<u8>> {
    if let Some(declared) = response.content_length() {
        if declared > max_bytes {
            return Err(LegadoError::Network(format!(
                "HLS 资源超出上限（声明 {} 字节 > {} 字节）",
                declared, max_bytes
            )));
        }
    }
    let mut out = Vec::new();
    while let Some(chunk) = crate::runtime::block_on(response.next_chunk())? {
        if cancel_generation_changed(cancel_snapshot) {
            return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
        }
        if out.len() as u64 + chunk.len() as u64 > max_bytes {
            return Err(LegadoError::Network(format!(
                "HLS 资源超出上限（>{} 字节）",
                max_bytes
            )));
        }
        out.extend_from_slice(&chunk);
    }
    Ok(out)
}

/// 发起一次 GET 并读取有界响应体（key / segment / playlist 共用）
///
/// `byte_range` 有值时加 `Range: bytes=<offset>-<offset+length-1>` 头，并强制
/// 校验部分响应语义（P2-2，见 [`validate_partial_response`]）。
/// 非 2xx 返回 `LegadoError::Network`（调用方据此判定是否需要重拉 playlist）。
///
/// **完整性（P2-1）**：有 `Content-Length` 时按声明值校验实际字节数；
/// BYTERANGE 还要求实际字节数等于区间长度——任何截断/超发都报错，
/// 绝不把残缺字节交给调用方拼接。
fn fetch_bytes_capped(
    client: &LegadoClient,
    url: &str,
    headers: &HashMap<String, String>,
    byte_range: Option<ByteRange>,
    max_bytes: u64,
    cancel_snapshot: u64,
) -> LegadoResult<Vec<u8>> {
    let mut request_headers = headers.clone();
    if let Some(range) = byte_range {
        let end = range.offset.saturating_add(range.length).saturating_sub(1);
        request_headers.insert(
            "Range".to_string(),
            format!("bytes={}-{}", range.offset, end),
        );
    }
    let request = LegadoRequest {
        url: url.to_string(),
        method: Method::Get,
        headers: request_headers,
        body: None,
        timeout: None,
    };
    let mut response = crate::runtime::block_on(client.send_stream(&request))?;
    if !response.is_success() {
        return Err(LegadoError::Network(format!(
            "网络请求失败({})",
            response.status()
        )));
    }
    // P2-2：Range 请求必须得到 206 + 起点正确的 Content-Range，否则服务端
    // 很可能忽略了 Range（返回 200 全量体），拼进分片会让体积成倍且内容错乱
    if let Some(range) = byte_range {
        validate_partial_response(&response, range)?;
    }
    // 注意：reqwest 透明解压（Content-Encoding: gzip 等）时已移除 Content-Length，
    // 故此处 `None` 表示长度未知而非 0 字节，不做校验
    let declared = response.content_length();
    let bytes = read_stream_capped(&mut response, max_bytes, cancel_snapshot)?;
    if let Some(declared) = declared {
        if bytes.len() as u64 != declared {
            return Err(LegadoError::Network(format!(
                "HLS 资源长度与声明不符（声明 {} 字节，实际 {} 字节）: {url}",
                declared,
                bytes.len()
            )));
        }
    }
    if let Some(range) = byte_range {
        if bytes.len() as u64 != range.length {
            return Err(LegadoError::Network(format!(
                "HLS BYTERANGE 字节数不符（请求 {} 字节，实际 {} 字节）: {url}",
                range.length,
                bytes.len()
            )));
        }
    }
    Ok(bytes)
}

/// 校验 206 部分响应与请求区间一致（P2-2）
///
/// 只判 `is_success()` 时，对 Range 请求返回 200 全量体的 CDN 会把**整文件
/// 重复写入每一段**（体积成倍 + 内容错乱）且全程无错误。这里强制：
/// ① 状态码必须是 206；② `Content-Range` 起点必须等于请求 `offset`。
/// `Content-Range` 缺失时退化为调用方的「实际字节数 == 区间长度」校验。
fn validate_partial_response(
    response: &LegadoStreamResponse,
    range: ByteRange,
) -> LegadoResult<()> {
    let status = response.status();
    let expected_end = range.offset.saturating_add(range.length).saturating_sub(1);
    if status != 206 {
        return Err(LegadoError::Network(format!(
            "HLS BYTERANGE 请求未返回 206（实际 {status}，请求 bytes={}-{}）：服务端可能忽略 Range",
            range.offset, expected_end
        )));
    }
    let Some(content_range) = response.header("content-range") else {
        return Ok(());
    };
    let spec = content_range.trim();
    let spec = spec.strip_prefix("bytes ").unwrap_or(spec).trim();
    let parsed = spec
        .split_once('/')
        .and_then(|(span, _total)| span.split_once('-'))
        .and_then(|(start, _end)| start.trim().parse::<u64>().ok());
    match parsed {
        Some(start) if start == range.offset => Ok(()),
        _ => Err(LegadoError::Network(format!(
            "HLS BYTERANGE 响应区间不符（请求 bytes={}-{}，响应 Content-Range: {content_range}）",
            range.offset, expected_end
        ))),
    }
}

/// 分片/初始化段身份：URI 去掉查询串与片段 + BYTERANGE
///
/// 重拉 playlist 时签名 token 常放在查询串里并**合法刷新**，故查询串不参与
/// 身份判定；路径 + 区间才能识别「滑动窗口进 1 出 1」造成的分片位移（P2-7）。
fn part_identity(uri: &str, byte_range: Option<ByteRange>) -> String {
    let path = uri.split(['?', '#']).next().unwrap_or(uri);
    match byte_range {
        Some(range) => format!("{path}#{}@{}", range.length, range.offset),
        None => path.to_string(),
    }
}

/// 初始化段身份（`None` 表示无 `EXT-X-MAP`）
fn init_map_identity(init: Option<&InitMap>) -> Option<String> {
    init.map(|map| part_identity(&map.uri, map.byte_range))
}

/// 按 URI 缓存已拉取的 AES-128 密钥（同一 playlist 内多段共用同一 key URI，
/// 避免逐段重复拉取；契约 §2.48「按 uri 缓存避免重复拉」）
type KeyCache = HashMap<String, Vec<u8>>;

/// 取（必要时拉取）AES-128 密钥：长度必须为 16 字节（AES-128）
///
/// 请求头由调用方经 [`HlsFetchCtx::headers_for`] 按 **key URI** 单独组装
/// （P2-6：key 也常在异域 CDN 上，不得携带登录头），不复用分片的头。
fn resolve_key(
    client: &LegadoClient,
    key: &HlsKey,
    headers: &HashMap<String, String>,
    cache: &mut KeyCache,
    cancel_snapshot: u64,
) -> LegadoResult<Vec<u8>> {
    if let Some(bytes) = cache.get(&key.uri) {
        return Ok(bytes.clone());
    }
    let bytes = fetch_bytes_capped(
        client,
        &key.uri,
        headers,
        None,
        HLS_META_MAX_BYTES,
        cancel_snapshot,
    )?;
    if bytes.len() != 16 {
        return Err(LegadoError::Ffi(format!(
            "HLS AES-128 密钥长度非法（应为 16 字节，实际 {}）",
            bytes.len()
        )));
    }
    cache.insert(key.uri.clone(), bytes.clone());
    Ok(bytes)
}

/// 解密一段 AES-128 密文（`iv` 由解析器按 §5.2 序列号算好，恒为 `Some`）
fn decrypt_segment(key: &[u8], hls_key: &HlsKey, data: Vec<u8>) -> LegadoResult<Vec<u8>> {
    let iv = hls_key.iv.ok_or_else(|| {
        LegadoError::Ffi("HLS AES-128 段缺少 IV（解析器应已按序列号补全）".into())
    })?;
    AesCrypto::decrypt_cbc(key, &iv, &data)
}

/// HLS 分片拉取上下文（客户端 + 书源头原料 + 取消代数 + 密钥缓存），
/// 避免各辅助函数重复传同一批参数
///
/// **请求头按 URL 逐次组装（P2-6）**：登录头（`loginHeader_*`）只发给与书源
/// 同站的请求，而 HLS 的 segment / key 常托管在异域 CDN 上。若像旧实现那样
/// 在 playlist 处一次性判定后复用同一份 headers，认证凭据会随每个分片请求
/// 外泄给第三方（原版 #1099 要防的正是此场景——`AnalyzeUrl.isLoginHeaderSite`
/// 是**逐请求**判定的）。故此处只持有原料，由 [`Self::headers_for`] 按每个
/// 资源 URL 现组装。
struct HlsFetchCtx<'a> {
    client: &'a LegadoClient,
    /// 书源 header 集合（静态头 + 登录头，登录头由 `for_request` 同站门控）
    header_set: &'a SourceHeaderSet,
    /// 书源自身 URL（同站判定基准）
    source_url: &'a str,
    /// playUrl `,{options}` 显式声明的头（同站全量发送；跨站剔除敏感键）
    extra_headers: &'a HashMap<String, String>,
    /// 相对资源 URI 的解析基准（= 真正给出分片清单的 playlist URL）
    playlist_base: String,
    cancel_snapshot: u64,
    key_cache: KeyCache,
}

impl HlsFetchCtx<'_> {
    /// 按目标资源 URL 组装请求头（P2-6 核心门控）
    ///
    /// 顺序与主请求一致：书源静态头 + 同站登录头（[`SourceHeaderSet::for_request`]
    /// 逐请求判定 eTLD+1）→ playUrl 显式头 → 该 URL 属域 JS cookie
    /// （`cookies_for_url` 按域取，天然不跨域）→ 剔除代理配置键。
    ///
    /// - 同站资源：静态头 + 登录头（登录后才能听的源不受影响）
    /// - 跨站资源：仅静态头（UA/Referer）+ playUrl 显式头中的**非敏感键**
    ///   （`Referer`/`User-Agent` 等防盗链所需），**无**登录头
    ///
    /// **playUrl 显式头的跨站门控（P2-1）**：`extra_headers` 来自
    /// `AnalyzeUrl.headers()`，其中可能含 playUrl 尾部 `,{"headers":{"Cookie":…}}`
    /// 或模板 `@Header:{Authorization:…}` 声明的认证键（见
    /// `legado-parser/src/analyze_url.rs`）。这些是书源作者自带的凭据而非用户
    /// 登录态，但若随**每个** segment/key 请求发往任意 CDN 主机，仍属凭据外泄。
    /// 故对跨站目标剔除 [`SENSITIVE_EXTRA_HEADERS`] 中的键（大小写不敏感），
    /// 其余显式头（`Referer`/`User-Agent` 等防盗链所需）照常发送。
    fn headers_for(&self, url: &str) -> HashMap<String, String> {
        let mut h = self
            .header_set
            .for_request(self.source_url, url, Some(self.playlist_base.as_str()))
            .unwrap_or_default();
        // 跨站判定与登录头门控同一真源（`is_login_header_site`），避免两套口径漂移
        let same_site = is_login_header_site(self.source_url, url, Some(&self.playlist_base));
        for (name, value) in self.extra_headers {
            if !same_site && is_sensitive_extra_header(name) {
                continue;
            }
            h.insert(name.clone(), value.clone());
        }
        legado_js::host_api::cookie_store::merge_js_cookies(&mut h, url);
        legado_fetcher::web_book::strip_proxy_header(&mut h);
        h
    }

    /// 下载单个 HLS 资源（init map / segment）到写入器：处理 key 解密与 BYTERANGE
    ///
    /// **空体即错（P2-1）**：2xx + 0 字节是 CDN/回源的典型失败形态，静默跳过会
    /// 让整章仍报 `installed` 却产出残缺文件。`label` 用于错误文案定位是哪一段。
    fn download_part(
        &mut self,
        url: &str,
        byte_range: Option<ByteRange>,
        key: Option<&HlsKey>,
        writer: &mut impl Write,
        label: &str,
        written: u64,
    ) -> LegadoResult<u64> {
        let headers = self.headers_for(url);
        let raw = fetch_bytes_capped(
            self.client,
            url,
            &headers,
            byte_range,
            HLS_SEGMENT_MAX_BYTES,
            self.cancel_snapshot,
        )?;
        if raw.is_empty() {
            return Err(LegadoError::Network(format!(
                "HLS {label}为空（服务端返回 0 字节）: {url}"
            )));
        }
        let bytes = match key {
            Some(hls_key) => {
                // key 是独立资源（常在另一台 CDN 上）：按 key URI 重新门控，
                // 不复用分片头的判定结果（P2-6）
                let key_headers = self.headers_for(&hls_key.uri);
                let key_bytes = resolve_key(
                    self.client,
                    hls_key,
                    &key_headers,
                    &mut self.key_cache,
                    self.cancel_snapshot,
                )?;
                decrypt_segment(&key_bytes, hls_key, raw)?
            }
            None => raw,
        };
        if bytes.is_empty() {
            return Err(LegadoError::Network(format!(
                "HLS {label}解密后为空: {url}"
            )));
        }
        // P2-5：总体积预算必须在**写盘前**校验——超限即 Err（走既有失败清理路径），
        // 不把最后一段写进临时文件后再回头发现超限。
        let total = require_merge_budget(written, bytes.len() as u64, label)?;
        writer.write_all(&bytes)?;
        Ok(total)
    }

    /// 拉取并解析 playlist（`url` 为 playlist 自身 URL，用于相对路径绝对化）
    fn fetch_playlist(&self, url: &str) -> LegadoResult<Playlist> {
        let headers = self.headers_for(url);
        let bytes = fetch_bytes_capped(
            self.client,
            url,
            &headers,
            None,
            HLS_META_MAX_BYTES,
            self.cancel_snapshot,
        )?;
        let text = String::from_utf8_lossy(&bytes);
        parse_playlist(&text, url)
    }
}

/// HLS 下载：解析 playlist → 下载全部 segment → 合并为单文件 → 走既有安装流程
///
/// 流程见契约 §2.48「HLS 合并下载路径」：
/// 1. 解析首响应（playlist 原文）；master → [`select_playlist_uri`] 选档
///    （优先独立音频轨，P2-3）后**再拉一次**
/// 2. **直播门禁**：playlist 无 `#EXT-X-ENDLIST` 即 Err（滑动窗口快照只能得到
///    半章，P2-5）；重拉后的 playlist 同样复检
/// 3. 有 `init_map` → 先写 init segment（同样支持 BYTERANGE + key，且与分片
///    共用同一「重拉 playlist 后重试一次」逻辑，P3-4）
/// 4. 逐 segment：key 解密 / BYTERANGE / **边下边拼**追加写临时文件
/// 5. 拼接完成 → 既有 size 校验 + 五段式安装 + `.complete` + 清理旧版本
///
/// **总体积预算（P2-5）**：单段 64MB 上限不足以约束合并总量——1MB playlist
/// 可声明上万段。拼接过程中累计已写字节，超过 [`HLS_MERGE_MAX_BYTES`]
/// （2 GiB）即 Err（写盘前判定），走既有失败清理路径。
///
/// **请求头（P2-6 / P2-1）**：不接收一份复用的 headers，而是接收书源头原料
/// （[`SourceHeaderSet`] + 源 URL + playUrl 显式头），由
/// [`HlsFetchCtx::headers_for`] 对每个 playlist/variant/init/segment/key URL
/// **逐请求**同站门控：登录头仅同站发送；playUrl 显式头中的敏感键
/// （`Cookie`/`Authorization`/`Proxy-Authorization`）跨站剔除。
///
/// **签名过期**：单段（或 init）失败时重拉一次 playlist（token 可能刷新）后
/// 重试；重拉目标是**媒体分片清单**的实际地址（master 源为其 variant URL，
/// P1-1），且要求该段位置的分片身份（路径 + BYTERANGE）与重拉前一致（P2-7）。
/// 仍失败则整章 Err（不产出残缺文件）。
/// **取消**：每个 segment 边界检查取消代数；失败删除临时文件与半成品。
#[allow(clippy::too_many_arguments)] // 入参为下载安装全链路所需（书/章标识 + 请求上下文 + playlist），拆结构体反而掩盖语义
fn download_hls_and_install(
    client: &LegadoClient,
    dir: &Path,
    key16: &str,
    chapter_index: i32,
    chapter_title: &str,
    play_url: &str,
    header_set: &SourceHeaderSet,
    source_url: &str,
    extra_headers: &HashMap<String, String>,
    playlist_url: &str,
    playlist_bytes: Vec<u8>,
    cancel_snapshot: u64,
) -> LegadoResult<String> {
    let mut ctx = HlsFetchCtx {
        client,
        header_set,
        source_url,
        extra_headers,
        // 首响应来自 playlist_url；master 选档成功后改写为 variant URL
        playlist_base: playlist_url.to_string(),
        cancel_snapshot,
        key_cache: HashMap::new(),
    };

    // ① 解析首响应；master → 选档后重拉
    //
    // `effective_playlist_url` 记录**真正给出媒体分片清单**的 playlist URL：
    // master 源是所选播放列表（音频轨优先）的 URL，media 源就是自身（P1-1）。
    // 重试时必须拉它——拉 master 只会再次拿到 master，重试逻辑形同死代码且
    // 错误文案误导。
    let text = String::from_utf8_lossy(&playlist_bytes);
    let first = parse_playlist(&text, playlist_url)?;
    let (media, effective_playlist_url): (MediaPlaylist, String) = match first {
        Playlist::Media(media) => (media, playlist_url.to_string()),
        Playlist::Master(master) => {
            // P2-3：优先 `#EXT-X-MEDIA:TYPE=AUDIO` 的独立音频轨——「视频档 +
            // 独立音频组」的标准 master 里纯音频内容只在音轨，任何 variant 都是
            // 视频档；无独立音轨才回落到 select_variant 选档。
            let variant_url = select_playlist_uri(&master)
                .ok_or_else(|| LegadoError::Parser("HLS master playlist 无可用档位".to_string()))?
                .to_string();
            let media = match ctx.fetch_playlist(&variant_url)? {
                Playlist::Media(media) => media,
                Playlist::Master(_) => {
                    return Err(LegadoError::Parser(format!(
                        "HLS 变体播放列表仍为 master（嵌套 master 不支持）: {variant_url}"
                    )))
                }
            };
            (media, variant_url)
        }
    };
    // 相对资源 URI 的基准 = 真正给出分片清单的 playlist（P2-6 headers_for 用）
    ctx.playlist_base = effective_playlist_url.clone();

    // 直播门禁（P2-5）：无 `EXT-X-ENDLIST` 的 playlist 只是当前滑动窗口快照，
    // 按窗口下载只能得到半章——必须在写盘前拒绝，且错误文案可诊断。
    if !media.is_vod() {
        return Err(LegadoError::Ffi(format!(
            "HLS 直播流不支持离线缓存（playlist 无 EXT-X-ENDLIST，只是当前滑动窗口快照，缓存只能得到半章）: {effective_playlist_url}"
        )));
    }

    if media.segments.is_empty() {
        return Err(LegadoError::Ffi("HLS 播放列表为空（无可用分片）".into()));
    }

    let has_init_map = media.init_map.is_some();
    let extension = hls_merged_extension(has_init_map);
    let revision = random_hex(8);
    let final_name = build_file_name(
        chapter_index,
        key16,
        chapter_title,
        &md5_mid16(play_url),
        &revision,
        extension,
    )?;
    let staged_path = dir.join(format!("tmp_{key16}_{revision}_{}.part", random_hex(32)));
    let final_path = dir.join(&final_name);
    let marker_path = dir.join(format!("{final_name}{COMPLETE_SUFFIX}"));

    // 期望大小未知（HLS 由多段拼接，无单一 Content-Length）→ None 仅校验非空
    let result: LegadoResult<u64> = (|| {
        let file = fs::File::create(&staged_path)?;
        let mut writer = io::BufWriter::new(file);
        // P2-5：已写入字节累计（总体积预算；超限即 Err 走失败清理）
        let mut written: u64 = 0;

        // ② init segment（fMP4）——与分片共用同一重试逻辑（P3-4）
        let mut current_media = media;
        if current_media.init_map.is_some() {
            let mut attempt = 0u32;
            loop {
                let init_map = current_media.init_map.clone().expect("已确认存在 init map");
                match ctx.download_part(
                    &init_map.uri,
                    init_map.byte_range,
                    init_map.key.as_ref(),
                    &mut writer,
                    "初始化段",
                    written,
                ) {
                    Ok(total) => {
                        written = total;
                        break;
                    }
                    Err(err) => {
                        // 签名过期同样会让 init 403（P3-4：旧实现 init 在重试循环外，
                        // 一次 403 就让整章直接失败）。仅网络类失败重拉 playlist 重试，
                        // 且 init 尚未写盘（download_part 整段取回后才写）。
                        let retryable = matches!(err, LegadoError::Network(_));
                        if !retryable || attempt >= 1 || cancel_generation_changed(cancel_snapshot)
                        {
                            return Err(LegadoError::Network(format!(
                                "HLS 初始化段下载失败: {err}"
                            )));
                        }
                        attempt += 1;
                        let refreshed = fetch_refreshed_media(&ctx, &effective_playlist_url)?;
                        // init 身份（路径 + BYTERANGE，忽略签名查询串）必须一致：
                        // 变化说明 init 换了内容，重试无意义（且会与已定档的 key 错配）
                        let before = init_map_identity(current_media.init_map.as_ref());
                        let after = init_map_identity(refreshed.init_map.as_ref());
                        if before != after {
                            return Err(LegadoError::Network(format!(
                                "HLS 初始化段下载失败: 重拉 playlist 后初始化段已变化（{before:?} → {after:?}）"
                            )));
                        }
                        current_media = refreshed;
                        // 重拉后 URI 可能已带新 token，重试 init
                    }
                }
            }
        }

        // ③ 逐段下载拼接（每段边界检查取消代数；每段至多重拉一次 playlist 后重试）
        let mut index = 0usize;
        while index < current_media.segments.len() {
            if cancel_generation_changed(cancel_snapshot) {
                return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
            }
            let mut attempt = 0u32;
            loop {
                let segment = current_media.segments[index].clone();
                let label = format!("分片（第 {} 段）", index + 1);
                match ctx.download_part(
                    &segment.uri,
                    segment.byte_range,
                    segment.key.as_ref(),
                    &mut writer,
                    &label,
                    written,
                ) {
                    Ok(total) => {
                        written = total;
                        break;
                    }
                    Err(err) => {
                        // 仅**网络类**失败才重拉 playlist 重试（签名过期/token 刷新）。
                        // 段字节先整段取回内存再一次性写盘（`download_part`），故网络
                        // 失败时本段尚未追加任何字节，重试不会重复拼接；而磁盘 IO /
                        // 解密 / 取消等失败重试无意义（且写入可能已部分生效）——直接上抛。
                        let retryable = matches!(err, LegadoError::Network(_));
                        // 签名过期（风险①）：本段重拉一次 playlist（token 可能已刷新）
                        if !retryable || attempt >= 1 || cancel_generation_changed(cancel_snapshot)
                        {
                            return Err(LegadoError::Network(format!(
                                "HLS {label}下载失败: {err}"
                            )));
                        }
                        attempt += 1;
                        let refreshed = fetch_refreshed_media(&ctx, &effective_playlist_url)?;
                        // P2-7：仅比段数不够——直播窗口「进 1 出 1」时数量不变但
                        // 内容整体位移，继续按下标拼接会产出错序文件。故要求该
                        // index 处的分片身份（路径 + BYTERANGE，忽略签名查询串）
                        // 与重拉前一致；不一致即 Err，绝不静默产出残缺文件。
                        if refreshed.segments.len() != current_media.segments.len() {
                            return Err(LegadoError::Network(format!(
                                "HLS {label}下载失败: 重拉 playlist 后分片数变化（{} → {}）",
                                current_media.segments.len(),
                                refreshed.segments.len()
                            )));
                        }
                        let before = part_identity(
                            &current_media.segments[index].uri,
                            current_media.segments[index].byte_range,
                        );
                        let after = part_identity(
                            &refreshed.segments[index].uri,
                            refreshed.segments[index].byte_range,
                        );
                        if before != after {
                            return Err(LegadoError::Network(format!(
                                "HLS {label}下载失败: 重拉 playlist 后第 {} 段位置已变化（{before} → {after}），可能是直播窗口滑动",
                                index + 1
                            )));
                        }
                        // 初始化段身份同样必须一致（否则已写入的 init 与新分片不配套）
                        let init_before = init_map_identity(current_media.init_map.as_ref());
                        let init_after = init_map_identity(refreshed.init_map.as_ref());
                        if init_before != init_after {
                            return Err(LegadoError::Network(format!(
                                "HLS {label}下载失败: 重拉 playlist 后初始化段已变化（{init_before:?} → {init_after:?}）"
                            )));
                        }
                        current_media = refreshed;
                        // 重拉后 URI 可能已带新 token，重试同一 index
                    }
                }
            }
            index += 1;
        }
        writer.flush()?;

        if cancel_generation_changed(cancel_snapshot) {
            return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
        }

        // ④ 既有安装流程：size 校验（无期望长度，仅非空）→ rename → 标记 → 清理
        let staged_len = fs::metadata(&staged_path)?.len();
        require_complete_size(staged_len, None)?;
        let installed_len = install_staged_file(&staged_path, &final_path, None)?;

        if cancel_generation_changed(cancel_snapshot) {
            return Err(LegadoError::Ffi("音频缓存下载已取消".into()));
        }
        write_complete_marker(&marker_path, play_url)?;

        let _ = remove_cache_files(dir, key16, Some(&final_name));

        Ok(installed_len)
    })();

    let installed_size = match result {
        Ok(size) => size,
        Err(e) => {
            // 失败清理：已安装文件 + 标记 + 临时文件（复用既有清理口径）
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

/// 重拉媒体分片清单 playlist（签名过期重试用，P3-4 抽公共）
///
/// 三处重试（init / segment）共用同一语义：
/// - 拉的是 [`effective_playlist_url`]（真正给出分片清单的地址，master 源为
///   所选 variant，P1-1），而非 master 源本身；
/// - 嵌套 master → Err（不支持）；
/// - **直播门禁复检**（P2-5）：重拉可能让 VOD 变 live（服务端切换直播态 /
///   `ENDLIST` 消失），此时继续拼接同样只能得到半章。
fn fetch_refreshed_media(ctx: &HlsFetchCtx<'_>, url: &str) -> LegadoResult<MediaPlaylist> {
    let refreshed = match ctx.fetch_playlist(url)? {
        Playlist::Media(m) => m,
        Playlist::Master(_) => {
            return Err(LegadoError::Parser(format!(
                "HLS 变体播放列表仍为 master（嵌套 master 不支持）: {url}"
            )))
        }
    };
    if !refreshed.is_vod() {
        return Err(LegadoError::Ffi(format!(
            "HLS 直播流不支持离线缓存（playlist 无 EXT-X-ENDLIST，只是当前滑动窗口快照，缓存只能得到半章）: {url}"
        )));
    }
    Ok(refreshed)
}

/// 合并体积上限（生产恒为 [`HLS_MERGE_MAX_BYTES`]）
///
/// `cfg(test)` 下可经 [`set_test_merge_max_bytes`] 注入小上限——真实 2 GiB
/// 无法在单元测试里实际下载，注入后可端到端验证「超限即 Err 且无残留」。
fn merge_max_bytes() -> u64 {
    #[cfg(test)]
    {
        if let Ok(guard) = TEST_MERGE_MAX_BYTES.get_or_init(|| Mutex::new(None)).lock() {
            if let Some(limit) = *guard {
                return limit;
            }
        }
    }
    HLS_MERGE_MAX_BYTES
}

/// 校验合并总体积预算并返回新的累计值（P2-5）
///
/// `written` 为已写盘字节数，`incoming` 为即将追加的字节数。超限返回
/// `LegadoError::Network`（文案含实际累计值与上限），调用方据此走既有失败清理。
fn require_merge_budget(written: u64, incoming: u64, label: &str) -> LegadoResult<u64> {
    let limit = merge_max_bytes();
    let total = written.saturating_add(incoming);
    if total > limit {
        return Err(LegadoError::Network(format!(
            "HLS 合并产物超出体积上限（{label}写入后累计 {} 字节 > 上限 {} 字节）",
            total, limit
        )));
    }
    Ok(total)
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

    /// 注入合并体积上限（`None` = 恢复生产 2 GiB；持 [`TEST_LOCK`] 使用）
    fn set_test_merge_max_bytes(limit: Option<u64>) {
        if let Ok(mut guard) = TEST_MERGE_MAX_BYTES.get_or_init(|| Mutex::new(None)).lock() {
            *guard = limit;
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

    // 播放链读取面（P0）：命中返回本地绝对路径；无 .complete / 被清理 / 章节不在 DB → None
    #[test]
    fn get_file_returns_committed_path_or_none() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("get-file");
        set_test_root(&root);
        let book_url = "https://a.com/book/get-file";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let dir = book_dir(book_url);
        let name = valid_name(0, KEY_HELLO, "mp3");

        // 目录不存在 / 无缓存文件 → None
        assert_eq!(audio_cache_get_file(book_url, 0), None);

        // 无 `.complete` 标记 → None（原版眼中即不存在）
        write_cache_file(&dir, &name, 16, false);
        assert_eq!(audio_cache_get_file(book_url, 0), None);

        // 补标记后 → 命中，返回绝对路径且指向该文件
        write_cache_file(&dir, &name, 16, true);
        let path = audio_cache_get_file(book_url, 0).expect("已提交缓存应命中");
        assert!(path.ends_with(&name), "返回路径应以文件名结尾: {path}");
        assert!(
            Path::new(&path).is_absolute(),
            "返回路径应为绝对路径: {path}"
        );
        assert!(Path::new(&path).is_file(), "返回路径应真实存在: {path}");

        // 清理后 → None（与 audio_cache_query 同步转假）
        audio_cache_clear_book(book_url);
        assert_eq!(audio_cache_get_file(book_url, 0), None);

        // 章节不在 DB → None（不 panic、不抛错）
        assert_eq!(audio_cache_get_file(book_url, 99), None);
        // 空白 bookUrl → None
        assert_eq!(audio_cache_get_file("  ", 0), None);

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

    /// 插入音频书 + 书源（可带静态 header）+ 单章（测试 DB，唯一 bookUrl 隔离）
    fn insert_audio_book_with_header(
        book_url: &str,
        source_url: &str,
        source_header: Option<&str>,
        chapter_url: &str,
        chapter_title: &str,
    ) {
        with_database(|db| {
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                name: format!("听书header测试-{book_url}"),
                author: String::new(),
                origin: source_url.to_string(),
                ..Default::default()
            };
            BookRepository::new(db.connection()).insert(&book)?;
            let source = BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "测试音频源".into(),
                header: source_header.map(str::to_string),
                ..BookSource::default()
            };
            BookSourceRepository::new(db.connection()).insert(&source)?;
            let chapter = legado_core::models::BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: chapter_title.to_string(),
                url: chapter_url.to_string(),
                is_volume: false,
                ..Default::default()
            };
            BookChapterRepository::new(db.connection()).insert(&chapter)?;
            Ok(())
        })
        .unwrap();
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

    /// 扩展名三级探测与多段拒绝（对齐 AudioCachePolicy.kt:25-65；
    /// HLS 自批 2 线 B 起返回合并产物扩展名，不再拒绝——契约 §2.48）
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
        // HLS 不再拒绝（行为变更：合并单文件路径）
        assert!(require_cacheable_play_url("https://x.com/a.M3U8?t=1").is_ok());
        assert!(require_cacheable_play_url("https://x.com/a.m3u#frag").is_ok());
        assert!(require_cacheable_play_url("https://x.com/a.mp3").is_ok());

        // Content-Type 优先映射
        assert_eq!(
            detect_extension(
                Some("audio/mpeg; charset=utf-8"),
                "https://x/a",
                "https://x/a",
                false
            )
            .unwrap(),
            "mp3"
        );
        assert_eq!(
            detect_extension(
                Some("audio/mp4"),
                "https://x/a.m4b",
                "https://x/a.m4b",
                false
            )
            .unwrap(),
            "m4a"
        );
        assert_eq!(
            detect_extension(Some("audio/x-flac"), "https://x/a", "https://x/a", false).unwrap(),
            "flac"
        );
        // Content-Type 缺失 → 最终 URL → playUrl → audio
        assert_eq!(
            detect_extension(None, "https://x.com/f.mp3?sign=1", "https://y/a", false).unwrap(),
            "mp3"
        );
        assert_eq!(
            detect_extension(None, "https://x.com/stream", "https://y.com/b.ogg#z", false).unwrap(),
            "ogg"
        );
        assert_eq!(
            detect_extension(None, "https://x.com/stream", "https://y/stream", false).unwrap(),
            "audio"
        );
        // Content-Type 存在但无已知子串（空串同）→ URL 兜底
        assert_eq!(
            detect_extension(Some(""), "https://x.com/f.aac", "https://y/a", false).unwrap(),
            "aac"
        );
        assert_eq!(
            detect_extension(
                Some("application/octet-stream"),
                "https://x.com/f",
                "https://y/a",
                false
            )
            .unwrap(),
            "audio"
        );
        // HLS → 合并产物扩展名：TS（无 EXT-X-MAP）→ ts；fMP4（有）→ m4a
        assert_eq!(
            detect_extension(
                Some("application/vnd.apple.mpegurl"),
                "https://x/a",
                "https://x/a",
                false
            )
            .unwrap(),
            "ts"
        );
        assert_eq!(
            detect_extension(
                Some("application/vnd.apple.mpegurl"),
                "https://x/a",
                "https://x/a",
                true
            )
            .unwrap(),
            "m4a"
        );
        assert_eq!(
            detect_extension(None, "https://x/live.m3u8", "https://x/live", false).unwrap(),
            "ts"
        );
        // playUrl 为 HLS 后缀即按 HLS 处理（即便响应 URL 无后缀）
        assert_eq!(
            detect_extension(
                Some("audio/mpeg"),
                "https://x/a",
                "https://x/live.m3u8",
                false
            )
            .unwrap(),
            "ts"
        );
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
        // playUrl 空 / JSON 多段（HLS 自批 2 线 B 起走合并路径，不再拒绝）
        for (play, msg) in [
            ("", "播放链接为空"),
            ("[{\"url\":\"x\"}]", "暂不支持缓存多段音频"),
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

    /// 批29b 审查 P2-6：音频缓存下载合并源 header（+登录头+AnalyzeUrl 头+
    /// JS cookie）后、发送前必须剔除 `proxy` 伪头——它是代理配置键而非
    /// HTTP 头，改前本路径直发 client → 代理凭据随下载请求外泄（本用例红）；
    /// 静态源 header 照常透传。
    #[test]
    fn download_strips_proxy_header_from_source_headers() {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;

        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("download-proxy-strip");
        set_test_root(&root);

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
        let seen_srv = std::sync::Arc::clone(&seen);
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
                if let Ok(mut guard) = seen_srv.lock() {
                    guard.push(String::from_utf8_lossy(&head).to_string());
                }
                let body = b"ID3fake-mp3-body".to_vec();
                let _ = sock.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    )
                    .as_bytes(),
                );
                let _ = sock.write_all(&body);
                let _ = sock.flush();
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });

        let book_url = "https://a.com/book/dl-proxy-strip";
        let source_url = "https://source.example/audio-proxy";
        insert_audio_book(book_url, source_url, "hello", "第一章", false);
        // 源 header 写入 proxy（代理配置键）+ 静态头（下载路径需读回该源）
        with_database(|db| {
            let repo = BookSourceRepository::new(db.connection());
            let mut source = repo.find_by_url(source_url)?.expect("插入的音频源应存在");
            source.header = Some(r#"{"proxy":"http://u:p@h:1","X-Static":"v"}"#.to_string());
            repo.insert(&source)
        })
        .unwrap();

        let play_url = format!("http://127.0.0.1:{port}/a.mp3");
        let client = test_client();
        let out =
            audio_cache_download_with_client(&client, book_url, 0, "hello", "第一章", &play_url)
                .expect("音频缓存下载应成功");
        assert!(out.contains("installed"), "应安装缓存文件: {out}");

        let seen = seen.lock().unwrap();
        let head = seen.first().expect("回环服务器应收到下载请求");
        let lower = head.to_ascii_lowercase();
        assert!(
            lower.contains("x-static: v"),
            "静态源 header 应透传: {head}"
        );
        assert!(
            !head
                .lines()
                .any(|line| line.to_ascii_lowercase().starts_with("proxy:")),
            "`proxy` 配置键不得作为 HTTP 头发送: {head}"
        );

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

    // ─── HLS 合并下载路径（批 2 线 B，契约 §2.48）──────────────────────────

    /// HLS 测试响应（按请求路由）
    struct HttpReply {
        status: u16,
        content_type: &'static str,
        body: Vec<u8>,
        declared_len: Option<u64>,
        /// 附加响应头（Content-Range 等）
        extra_headers: Vec<(String, String)>,
    }

    impl HttpReply {
        fn ok(content_type: &'static str, body: Vec<u8>) -> Self {
            Self {
                status: 200,
                content_type,
                body,
                declared_len: None,
                extra_headers: Vec::new(),
            }
        }

        /// 206 部分响应（`Content-Range` 按 RFC 9110 写作 `bytes <start>-<end>/<total>`）
        fn partial(content_type: &'static str, body: Vec<u8>, start: u64, total: u64) -> Self {
            let end = start.saturating_add(body.len() as u64).saturating_sub(1);
            Self {
                status: 206,
                content_type,
                body,
                declared_len: None,
                extra_headers: vec![(
                    "Content-Range".to_string(),
                    format!("bytes {start}-{end}/{total}"),
                )],
            }
        }

        fn status(status: u16) -> Self {
            Self {
                status,
                content_type: "text/plain",
                body: format!("error {status}").into_bytes(),
                declared_len: None,
                extra_headers: Vec::new(),
            }
        }

        /// 覆盖 `Content-Length` 声明值（用于构造「声明与实际不符」的坏响应）
        fn with_declared_len(mut self, len: u64) -> Self {
            self.declared_len = Some(len);
            self
        }
    }

    /// 已记录的请求头快照（每个请求一条）
    type SeenRequests = std::sync::Arc<std::sync::Mutex<Vec<String>>>;

    /// 启动按请求头路由的回环服务器（记录全部请求头便于断言 Range / 路径）
    fn spawn_router_server<F>(responder: F) -> (u16, SeenRequests)
    where
        F: Fn(&str) -> HttpReply + Send + Sync + 'static,
    {
        spawn_router_server_on("127.0.0.1", responder)
    }

    /// 同上，但可指定监听地址（P2-6 跨站用例用 `127.0.0.1` vs `127.0.0.2`
    /// 模拟两个不同 eTLD+1：`cookie_domain_key` 对 IP 字面量以自身为键，
    /// 故两个不同 IP 即判定为异站）
    fn spawn_router_server_on<F>(host: &str, responder: F) -> (u16, SeenRequests)
    where
        F: Fn(&str) -> HttpReply + Send + Sync + 'static,
    {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind((host, 0)).expect("绑定回环端口");
        let port = listener.local_addr().unwrap().port();
        let seen: SeenRequests = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let seen_srv = std::sync::Arc::clone(&seen);
        let responder = std::sync::Arc::new(responder);
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
                let head_text = String::from_utf8_lossy(&head).to_string();
                if let Ok(mut guard) = seen_srv.lock() {
                    guard.push(head_text.clone());
                }
                let reply = responder(&head_text);
                let reason = match reply.status {
                    200 => "OK",
                    206 => "Partial Content",
                    403 => "Forbidden",
                    404 => "Not Found",
                    _ if (200..300).contains(&reply.status) => "OK",
                    _ => "Error",
                };
                let mut out = format!("HTTP/1.1 {} {reason}\r\n", reply.status);
                out.push_str(&format!("Content-Type: {}\r\n", reply.content_type));
                out.push_str(&format!(
                    "Content-Length: {}\r\n",
                    reply.declared_len.unwrap_or(reply.body.len() as u64)
                ));
                for (name, value) in &reply.extra_headers {
                    out.push_str(&format!("{name}: {value}\r\n"));
                }
                out.push_str("Connection: close\r\n\r\n");
                let _ = sock.write_all(out.as_bytes());
                let _ = sock.write_all(&reply.body);
                let _ = sock.flush();
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });
        (port, seen)
    }

    /// 从请求头提取请求目标（path + query）
    fn request_target(head: &str) -> String {
        head.lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .unwrap_or("/")
            .to_string()
    }

    /// 从请求头提取某个头值（大小写不敏感）
    fn request_header(head: &str, name: &str) -> Option<String> {
        head.lines().skip(1).find_map(|line| {
            let (k, v) = line.split_once(':')?;
            k.trim()
                .eq_ignore_ascii_case(name)
                .then(|| v.trim().to_string())
        })
    }

    /// media playlist 文本（`entries` 为逐行原文，通常成对 `#EXTINF` + URI）
    fn media_playlist(entries: &[&str]) -> String {
        let mut text = String::from(
            "#EXTM3U\n#EXT-X-VERSION:4\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n",
        );
        for entry in entries {
            text.push_str(entry);
            text.push('\n');
        }
        text.push_str("#EXT-X-ENDLIST\n");
        text
    }

    /// 场景 1 + 9：明文 TS 四段合并 + `.complete` 三行内容（第三行存原始 m3u8 URL）
    #[test]
    fn hls_plain_ts_merges_segments_and_writes_marker() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-ts");
        set_test_root(&root);

        let segs: Vec<Vec<u8>> = (0..4u8).map(|i| vec![0x40 + i; 1024]).collect();
        let playlist = media_playlist(&[
            "#EXTINF:10,",
            "seg0.ts",
            "#EXTINF:10,",
            "seg1.ts",
            "#EXTINF:10,",
            "seg2.ts",
            "#EXTINF:10,",
            "seg3.ts",
        ]);
        let segs_for_srv = segs.clone();
        let (port, seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            for (i, bytes) in segs_for_srv.iter().enumerate() {
                if target.starts_with(&format!("/seg{i}.ts")) {
                    return HttpReply::ok("video/mp2t", bytes.clone());
                }
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-ts";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("明文 TS HLS 应合并成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["status"], "installed");
        assert_eq!(json["extension"], "ts", "无 EXT-X-MAP → ts");
        let expected: Vec<u8> = segs.concat();
        assert_eq!(json["sizeBytes"], expected.len(), "产物字节数 = 4 段之和");
        let path = json["path"].as_str().unwrap();
        assert!(path.ends_with(".ts"));
        assert_eq!(
            fs::read(path).unwrap(),
            expected,
            "合并顺序须与 playlist 一致"
        );

        // 场景 9：`.complete` 三行正确，第三行存原始 m3u8 URL
        let marker = fs::read_to_string(format!("{path}{COMPLETE_SUFFIX}")).unwrap();
        assert_eq!(marker, encode_metadata(&play_url));
        let lines: Vec<&str> = marker.split('\n').collect();
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0], "1");
        assert_eq!(lines[1], md5_mid16(&play_url));
        assert_eq!(lines[2], play_url);

        assert!(audio_cache_query(book_url, 0, "hello", "第一章"));
        assert_eq!(audio_cache_list(book_url), vec![0]);
        // 4 段各 1 次 + 1 次 playlist
        assert_eq!(seen.lock().unwrap().len(), 5);

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 2：AES-128 加密段 → 解密合并后等于明文之和
    #[test]
    fn hls_aes128_decrypts_and_merges() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-aes");
        set_test_root(&root);

        let key = *b"0123456789abcdef";
        let iv = [
            0x10u8, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab,
            0xcd, 0xef,
        ];
        let plain: Vec<Vec<u8>> = vec![
            b"first-segment-plaintext".to_vec(),
            b"second-segment-plaintext".to_vec(),
            b"third".to_vec(),
        ];
        let encrypted: Vec<Vec<u8>> = plain
            .iter()
            .map(|p| AesCrypto::encrypt_cbc(&key, &iv, p).expect("加密测试段"))
            .collect();
        let playlist = media_playlist(&[
            "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\",IV=0x1032547698BADCFE0123456789ABCDEF",
            "#EXTINF:10,",
            "enc0.ts",
            "#EXTINF:10,",
            "enc1.ts",
            "#EXTINF:10,",
            "enc2.ts",
        ]);
        let encrypted_for_srv = encrypted.clone();
        let (port, seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/key.bin") {
                return HttpReply::ok("application/octet-stream", key.to_vec());
            }
            for (i, bytes) in encrypted_for_srv.iter().enumerate() {
                if target.starts_with(&format!("/enc{i}.ts")) {
                    return HttpReply::ok("video/mp2t", bytes.clone());
                }
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-aes";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("AES-128 HLS 应解密合并成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["extension"], "ts");
        let expected: Vec<u8> = plain.concat();
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            expected,
            "解密后应等于明文之和"
        );
        // key 只拉一次（按 URI 缓存，3 段共用）
        let key_hits = seen
            .lock()
            .unwrap()
            .iter()
            .filter(|h| request_target(h).starts_with("/key.bin"))
            .count();
        assert_eq!(key_hits, 1, "同一 key URI 只应拉取一次");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 3：fMP4（EXT-X-MAP + 3 个 m4s）→ 产物以 init 开头，扩展名 m4a
    #[test]
    fn hls_fmp4_prepends_init_map() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-fmp4");
        set_test_root(&root);

        let init = b"INIT-SEGMENT-HEADER".to_vec();
        let parts: Vec<Vec<u8>> = vec![
            b"m4s-part-one".to_vec(),
            b"m4s-part-two".to_vec(),
            b"m4s-part-three".to_vec(),
        ];
        let playlist = media_playlist(&[
            "#EXT-X-MAP:URI=\"init.mp4\"",
            "#EXTINF:10,",
            "p0.m4s",
            "#EXTINF:10,",
            "p1.m4s",
            "#EXTINF:10,",
            "p2.m4s",
        ]);
        let parts_for_srv = parts.clone();
        let init_for_srv = init.clone();
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/init.mp4") {
                return HttpReply::ok("video/mp4", init_for_srv.clone());
            }
            for (i, bytes) in parts_for_srv.iter().enumerate() {
                if target.starts_with(&format!("/p{i}.m4s")) {
                    return HttpReply::ok("video/iso.segment", bytes.clone());
                }
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-fmp4";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("fMP4 HLS 应合并成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["extension"], "m4a", "有 EXT-X-MAP → m4a");
        let path = json["path"].as_str().unwrap();
        assert!(path.ends_with(".m4a"));
        let bytes = fs::read(path).unwrap();
        assert!(bytes.starts_with(&init), "产物必须以 init segment 开头");
        let mut expected = init.clone();
        for part in &parts {
            expected.extend_from_slice(part);
        }
        assert_eq!(bytes, expected);
        assert_eq!(json["sizeBytes"], expected.len());

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 4：master playlist（视频档 + 纯音频档）→ 选纯音频档下载
    #[test]
    fn hls_master_playlist_selects_audio_only_variant() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-master");
        set_test_root(&root);

        let master = concat!(
            "#EXTM3U\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"avc1.4d401f,mp4a.40.2\"\n",
            "video.m3u8\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.2\"\n",
            "audio.m3u8\n",
        )
        .to_string();
        let audio_playlist = media_playlist(&["#EXTINF:10,", "a0.ts", "#EXTINF:10,", "a1.ts"]);
        let video_playlist = media_playlist(&["#EXTINF:10,", "v0.ts"]);
        let (port, seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/master.m3u8") {
                return HttpReply::ok("application/vnd.apple.mpegurl", master.clone().into_bytes());
            }
            if target.starts_with("/audio.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    audio_playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/video.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    video_playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/a0.ts") {
                return HttpReply::ok("video/mp2t", b"AUDIO-0".to_vec());
            }
            if target.starts_with("/a1.ts") {
                return HttpReply::ok("video/mp2t", b"AUDIO-1".to_vec());
            }
            if target.starts_with("/v0.ts") {
                return HttpReply::ok("video/mp2t", b"VIDEO-0".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-master";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/master.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("master playlist 应选档成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["extension"], "ts");
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"AUDIO-0AUDIO-1".to_vec(),
            "应只下载纯音频档分片"
        );
        let targets: Vec<String> = seen
            .lock()
            .unwrap()
            .iter()
            .map(|h| request_target(h))
            .collect();
        assert!(
            !targets.iter().any(|t| t.starts_with("/v0.ts")),
            "视频档分片不得被请求: {targets:?}"
        );
        assert!(targets.iter().any(|t| t.starts_with("/audio.m3u8")));

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 5：BYTERANGE（单文件多区间）→ Range 请求头正确、产物为区间拼接
    #[test]
    fn hls_byterange_requests_ranges() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-byterange");
        set_test_root(&root);

        // 单文件 30 字节，按 3 个 10 字节区间切
        let whole: Vec<u8> = (0..30u8).collect();
        let playlist = media_playlist(&[
            "#EXTINF:10,",
            "#EXT-X-BYTERANGE:10@0",
            "all.ts",
            "#EXTINF:10,",
            "#EXT-X-BYTERANGE:10@10",
            "all.ts",
            "#EXTINF:10,",
            "#EXT-X-BYTERANGE:10",
            "all.ts",
        ]);
        let whole_for_srv = whole.clone();
        let (port, seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/all.ts") {
                let range = request_header(head, "Range");
                if let Some(range) = range {
                    let spec = range.trim_start_matches("bytes=");
                    let (start, end) = spec.split_once('-').expect("Range 形如 a-b");
                    let start: usize = start.parse().unwrap();
                    let end: usize = end.parse().unwrap();
                    return HttpReply::partial(
                        "video/mp2t",
                        whole_for_srv[start..=end].to_vec(),
                        start as u64,
                        whole_for_srv.len() as u64,
                    );
                }
                return HttpReply::ok("video/mp2t", whole_for_srv.clone());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-byterange";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("BYTERANGE HLS 应合并成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            whole,
            "三个区间拼接应还原完整文件"
        );

        let ranges: Vec<String> = seen
            .lock()
            .unwrap()
            .iter()
            .filter(|h| request_target(h).starts_with("/all.ts"))
            .filter_map(|h| request_header(h, "Range"))
            .collect();
        assert_eq!(
            ranges,
            vec![
                "bytes=0-9".to_string(),
                "bytes=10-19".to_string(),
                "bytes=20-29".to_string()
            ],
            "缺省 offset 段须续接上一区间末尾"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 6：签名过期——第 2 段首次 403 → 重拉 m3u8（新 token）→ 成功
    #[test]
    fn hls_expired_signature_refetches_playlist_once() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-expire");
        set_test_root(&root);

        let old_playlist = media_playlist(&[
            "#EXTINF:10,",
            "seg0.ts?token=old",
            "#EXTINF:10,",
            "seg1.ts?token=old",
            "#EXTINF:10,",
            "seg2.ts?token=old",
        ]);
        let new_playlist = media_playlist(&[
            "#EXTINF:10,",
            "seg0.ts?token=new",
            "#EXTINF:10,",
            "seg1.ts?token=new",
            "#EXTINF:10,",
            "seg2.ts?token=new",
        ]);
        let playlist_hits = std::sync::Arc::new(AtomicUsize::new(0));
        let playlist_hits_srv = std::sync::Arc::clone(&playlist_hits);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                let n = playlist_hits_srv.fetch_add(1, Ordering::SeqCst);
                let body = if n == 0 {
                    old_playlist.clone()
                } else {
                    new_playlist.clone()
                };
                return HttpReply::ok("application/vnd.apple.mpegurl", body.into_bytes());
            }
            if target.starts_with("/seg1.ts?token=old") {
                return HttpReply::status(403); // 旧 token 过期
            }
            if target.starts_with("/seg0.ts") {
                return HttpReply::ok("video/mp2t", b"SEG-0".to_vec());
            }
            if target.starts_with("/seg1.ts") {
                return HttpReply::ok("video/mp2t", b"SEG-1".to_vec());
            }
            if target.starts_with("/seg2.ts") {
                return HttpReply::ok("video/mp2t", b"SEG-2".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-expire";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("签名过期重拉 playlist 后应成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"SEG-0SEG-1SEG-2".to_vec()
        );
        assert_eq!(
            playlist_hits.load(Ordering::SeqCst),
            2,
            "只应重拉一次 playlist"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// P3-4：init segment 首次 403（签名过期），重拉 playlist 后成功 → 整章 installed
    ///
    /// 旧实现 init 下载在重试循环**之外**，一次 403 就让整章直接失败，而
    /// segment 却有重拉重试——同一章里 init 的容错等级不该低于分片。
    #[test]
    fn hls_init_segment_expired_signature_retries_after_refetch() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-init-expire");
        set_test_root(&root);

        let old_playlist = media_playlist(&[
            "#EXT-X-MAP:URI=\"init.mp4?token=old\"",
            "#EXTINF:10,",
            "seg0.ts?token=old",
        ]);
        let new_playlist = media_playlist(&[
            "#EXT-X-MAP:URI=\"init.mp4?token=new\"",
            "#EXTINF:10,",
            "seg0.ts?token=new",
        ]);
        let playlist_hits = std::sync::Arc::new(AtomicUsize::new(0));
        let playlist_hits_srv = std::sync::Arc::clone(&playlist_hits);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                let n = playlist_hits_srv.fetch_add(1, Ordering::SeqCst);
                let body = if n == 0 {
                    old_playlist.clone()
                } else {
                    new_playlist.clone()
                };
                return HttpReply::ok("application/vnd.apple.mpegurl", body.into_bytes());
            }
            // 旧 token 的 init 过期
            if target.starts_with("/init.mp4?token=old") {
                return HttpReply::status(403);
            }
            if target.starts_with("/init.mp4?token=new") {
                return HttpReply::ok("video/mp4", b"INIT".to_vec());
            }
            if target.starts_with("/seg0.ts") {
                return HttpReply::ok("video/mp2t", b"SEG0".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-init-expire";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("init 首次 403、重拉后应成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["extension"], "m4a");
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"INITSEG0".to_vec()
        );
        assert_eq!(
            playlist_hits.load(Ordering::SeqCst),
            2,
            "init 失败后只应重拉一次 playlist"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 6b（P1-1）：**master 源**签名过期——重试必须重拉 **variant** playlist，
    /// 而不是重拉 master（后者必然再次得到 master → 「嵌套 master」误报，重试死代码）
    #[test]
    fn hls_master_source_expired_signature_refetches_variant() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-master-expire");
        set_test_root(&root);

        let master = concat!(
            "#EXTM3U\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS=\"mp4a.40.2\"\n",
            "audio.m3u8\n",
        )
        .to_string();
        let old_audio = media_playlist(&[
            "#EXTINF:10,",
            "a0.ts?token=old",
            "#EXTINF:10,",
            "a1.ts?token=old",
        ]);
        let new_audio = media_playlist(&[
            "#EXTINF:10,",
            "a0.ts?token=new",
            "#EXTINF:10,",
            "a1.ts?token=new",
        ]);
        let master_hits = std::sync::Arc::new(AtomicUsize::new(0));
        let audio_hits = std::sync::Arc::new(AtomicUsize::new(0));
        let master_hits_srv = std::sync::Arc::clone(&master_hits);
        let audio_hits_srv = std::sync::Arc::clone(&audio_hits);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/master.m3u8") {
                master_hits_srv.fetch_add(1, Ordering::SeqCst);
                return HttpReply::ok("application/vnd.apple.mpegurl", master.clone().into_bytes());
            }
            if target.starts_with("/audio.m3u8") {
                let n = audio_hits_srv.fetch_add(1, Ordering::SeqCst);
                let body = if n == 0 {
                    old_audio.clone()
                } else {
                    new_audio.clone()
                };
                return HttpReply::ok("application/vnd.apple.mpegurl", body.into_bytes());
            }
            if target.starts_with("/a1.ts?token=old") {
                return HttpReply::status(403); // 旧 token 过期
            }
            if target.starts_with("/a0.ts") {
                return HttpReply::ok("video/mp2t", b"A0".to_vec());
            }
            if target.starts_with("/a1.ts") {
                return HttpReply::ok("video/mp2t", b"A1".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-master-expire";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/master.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("master 源签名过期重拉 variant 后应成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"A0A1".to_vec()
        );
        assert_eq!(
            master_hits.load(Ordering::SeqCst),
            1,
            "重试不得重拉 master（重拉 master 只会再得到 master）"
        );
        assert_eq!(
            audio_hits.load(Ordering::SeqCst),
            2,
            "重试应重拉 variant playlist"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 6c（P2-7）：重拉后分片数不变但内容位移（直播窗口「进 1 出 1」）→ Err
    #[test]
    fn hls_refetch_detects_shifted_segments_same_count() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-shift");
        set_test_root(&root);

        let old_playlist = media_playlist(&[
            "#EXTINF:10,",
            "seg0.ts",
            "#EXTINF:10,",
            "seg1.ts",
            "#EXTINF:10,",
            "seg2.ts",
        ]);
        // 同样 3 段，但整体前移一段：index 1 由 seg1 → seg2
        let shifted_playlist = media_playlist(&[
            "#EXTINF:10,",
            "seg1.ts",
            "#EXTINF:10,",
            "seg2.ts",
            "#EXTINF:10,",
            "seg3.ts",
        ]);
        let playlist_hits = std::sync::Arc::new(AtomicUsize::new(0));
        let playlist_hits_srv = std::sync::Arc::clone(&playlist_hits);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                let n = playlist_hits_srv.fetch_add(1, Ordering::SeqCst);
                let body = if n == 0 {
                    old_playlist.clone()
                } else {
                    shifted_playlist.clone()
                };
                return HttpReply::ok("application/vnd.apple.mpegurl", body.into_bytes());
            }
            if target.starts_with("/seg0.ts") {
                return HttpReply::ok("video/mp2t", b"S0".to_vec());
            }
            if target.starts_with("/seg1.ts") {
                return HttpReply::status(403);
            }
            // 位移后的新分片必须可取——否则失败原因是 404 而非「位置已变化」，
            // 掩盖了「静默产出错序文件」这一真实缺陷
            if target.starts_with("/seg2.ts") {
                return HttpReply::ok("video/mp2t", b"S2".to_vec());
            }
            if target.starts_with("/seg3.ts") {
                return HttpReply::ok("video/mp2t", b"S3".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-shift";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("位置已变化"), "应识别分片位移: {err}");
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败不得残留文件: {names:?}");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 6d（P2-1）：某段 200 + 0 字节 → 整章 Err、无 `.complete`、无残留
    #[test]
    fn hls_empty_segment_fails_instead_of_installing_truncated_file() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-empty-seg");
        set_test_root(&root);

        let playlist = media_playlist(&[
            "#EXTINF:10,",
            "seg0.ts",
            "#EXTINF:10,",
            "seg1.ts",
            "#EXTINF:10,",
            "seg2.ts",
        ]);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/seg0.ts") {
                return HttpReply::ok("video/mp2t", b"S0".to_vec());
            }
            if target.starts_with("/seg1.ts") {
                return HttpReply::ok("video/mp2t", Vec::new()); // 200 + 空体
            }
            if target.starts_with("/seg2.ts") {
                return HttpReply::ok("video/mp2t", b"S2".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-empty-seg";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("为空"), "应明确报空分片: {err}");
        assert!(err.contains("第 2 段"), "应定位到第 2 段: {err}");
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败不得残留文件: {names:?}");
        assert!(!audio_cache_query(book_url, 0, "hello", "第一章"));

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 6e（P2-2）：BYTERANGE 但服务端忽略 Range 返回 200 全量体 → 明确 Err
    #[test]
    fn hls_byterange_rejects_full_body_response() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-range-ignored");
        set_test_root(&root);

        let whole: Vec<u8> = (0..30u8).collect();
        let playlist = media_playlist(&[
            "#EXTINF:10,",
            "#EXT-X-BYTERANGE:10@0",
            "all.ts",
            "#EXTINF:10,",
            "#EXT-X-BYTERANGE:10@10",
            "all.ts",
        ]);
        let whole_for_srv = whole.clone();
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/all.ts") {
                // 忽略 Range：200 + 整文件
                return HttpReply::ok("video/mp2t", whole_for_srv.clone());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-range-ignored";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap_err()
        .to_string();
        assert!(
            err.contains("未返回 206"),
            "应拒绝忽略 Range 的 200 全量响应: {err}"
        );
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败不得残留文件: {names:?}");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 6f（P2-1）：分片响应体短于 `Content-Length` 声明 → 整章 Err、无残留
    #[test]
    fn hls_truncated_segment_body_fails() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-truncated");
        set_test_root(&root);

        let playlist = media_playlist(&["#EXTINF:10,", "seg0.ts", "#EXTINF:10,", "seg1.ts"]);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/seg0.ts") {
                return HttpReply::ok("video/mp2t", b"S0".to_vec());
            }
            if target.starts_with("/seg1.ts") {
                // 声明 100 字节，实际只发 5 字节（截断）
                return HttpReply::ok("video/mp2t", b"TRUNC".to_vec()).with_declared_len(100);
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-truncated";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("第 2 段"), "应定位到第 2 段: {err}");
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败不得残留文件: {names:?}");
        assert!(!audio_cache_query(book_url, 0, "hello", "第一章"));

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 7：SAMPLE-AES → 明确 Err（解析器直接上抛，不静默）
    #[test]
    fn hls_sample_aes_rejected() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-sample-aes");
        set_test_root(&root);

        let playlist = media_playlist(&[
            "#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://key\"",
            "#EXTINF:10,",
            "seg0.ts",
        ]);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-sample-aes";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("SAMPLE-AES"), "应明确报 SAMPLE-AES: {err}");
        // 不产出任何残file
        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败不得残留文件: {names:?}");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 场景 8：下载中途取消 → Err 且不产生 `.complete`、无残留
    #[test]
    fn hls_cancel_aborts_merge_without_complete_marker() {
        use std::io::Read as _;
        use std::io::Write as _;
        use std::net::TcpListener;

        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-cancel");
        set_test_root(&root);

        let mut entries: Vec<String> = Vec::new();
        for i in 0..20 {
            entries.push("#EXTINF:10,".to_string());
            entries.push(format!("slow{i}.ts"));
        }
        let entries: Vec<&str> = entries.iter().map(|s| s.as_str()).collect();
        let playlist = media_playlist(&entries);

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
                let head_text = String::from_utf8_lossy(&head).to_string();
                let target = request_target(&head_text);
                if target.starts_with("/playlist.m3u8") {
                    let body = playlist.as_bytes();
                    let _ = sock.write_all(
                        format!(
                            "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            body.len()
                        )
                        .as_bytes(),
                    );
                    let _ = sock.write_all(body);
                    let _ = sock.flush();
                    let _ = sock.shutdown(std::net::Shutdown::Both);
                    continue;
                }
                // 慢速分片：8KB，每 2KB 间隔 20ms
                let total = 8 * 1024usize;
                let _ = sock.write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
                    )
                    .as_bytes(),
                );
                let chunk = vec![0x5Au8; 2048];
                for _ in 0..4 {
                    if sock.write_all(&chunk).is_err() {
                        break;
                    }
                    let _ = sock.flush();
                    std::thread::sleep(Duration::from_millis(20));
                }
                let _ = sock.shutdown(std::net::Shutdown::Both);
            }
        });

        let book_url = "https://a.com/book/hls-cancel";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let worker = std::thread::spawn(move || {
            let client = test_client();
            audio_cache_download_with_client(&client, book_url, 0, "hello", "第一章", &play_url)
        });

        let mut waited_ms = 0u32;
        while IN_FLIGHT.load(Ordering::SeqCst) == 0 && waited_ms < 3000 {
            std::thread::sleep(Duration::from_millis(10));
            waited_ms += 10;
        }
        assert_eq!(IN_FLIGHT.load(Ordering::SeqCst), 1, "在途计数应为 1");
        std::thread::sleep(Duration::from_millis(150));
        assert!(audio_cache_cancel().unwrap(), "置位时应快照到在途下载");

        let err = worker.join().unwrap().unwrap_err().to_string();
        assert!(err.contains("音频缓存下载已取消"), "err={err}");

        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "取消后不得残留临时文件/半成品: {names:?}");
        assert!(
            !names.iter().any(|n| n.ends_with(COMPLETE_SUFFIX)),
            "取消后不得产生 .complete"
        );
        assert_eq!(IN_FLIGHT.load(Ordering::SeqCst), 0, "在途计数应复位");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 单段 media playlist（仅 1 个 segment）同样走合并路径（不跳过）
    #[test]
    fn hls_single_segment_playlist_works() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-single");
        set_test_root(&root);

        let playlist = media_playlist(&["#EXTINF:10,", "only.ts"]);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/only.ts") {
                return HttpReply::ok("video/mp2t", b"ONLY-SEGMENT".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-single";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("单段 playlist 应可缓存");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["sizeBytes"], 12);
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"ONLY-SEGMENT".to_vec()
        );
        assert!(audio_cache_query(book_url, 0, "hello", "第一章"));

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 无扩展名 + 错误 Content-Type 的 m3u8 → 内容嗅探识别为 HLS 并合并
    /// （批 47 真机风险②回归保护：只看后缀/Content-Type 会把它当二进制音频）
    #[test]
    fn hls_detected_by_content_sniffing_when_no_extension() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-sniff");
        set_test_root(&root);

        let playlist = media_playlist(&["#EXTINF:10,", "s0.ts", "#EXTINF:10,", "s1.ts"]);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            // 无后缀 + octet-stream：仅能靠内容嗅探
            if target.starts_with("/stream?id=42") {
                return HttpReply::ok("application/octet-stream", playlist.clone().into_bytes());
            }
            if target.starts_with("/s0.ts") {
                return HttpReply::ok("video/mp2t", b"S0".to_vec());
            }
            if target.starts_with("/s1.ts") {
                return HttpReply::ok("video/mp2t", b"S1".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-sniff";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/stream?id=42");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("无扩展名 m3u8 应经内容嗅探走 HLS 合并");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["extension"], "ts");
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"S0S1".to_vec()
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// 非 HLS 的普通音频经嗅探后不得丢首块（回归保护：嗅探消费首块须写回）
    #[test]
    fn non_hls_audio_keeps_sniffed_first_chunk() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("non-hls-sniff");
        set_test_root(&root);

        let body = vec![0x49u8; 5000]; // 非 #EXTM3U 开头
        let body_srv = body.clone();
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/plain.mp3") {
                return HttpReply::ok("audio/mpeg", body_srv.clone());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/non-hls-sniff";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/plain.mp3");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("普通音频应正常缓存");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(json["extension"], "mp3");
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            body,
            "嗅探消费的首块必须写回，字节不得丢失"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // ─── P2-6：跨域认证头门控（本线核心）──────────────────────────────────

    /// P2-6 核心：登录头只发同站资源，跨站 segment 必须收不到 `Authorization`
    ///
    /// 场景：书源 `https://source.example/audio`（登录头 `Authorization:
    /// Bearer secret`），playlist 在同站（`http://127.0.0.1:p1`），segment 在
    /// **异站**（`http://127.0.0.2:p2`）。改前：登录头在 playlist 处一次性判定
    /// 后原样复用给全部 segment → 异站 segment 收到凭据（红）；改后：逐 URL
    /// 门控 → 异站无登录头、同站有（绿）。
    ///
    /// 判定依据：`legado_net::cookie_store::cookie_domain_key` 对 IP 字面量
    /// 以**自身**为键（`127.0.0.1` ≠ `127.0.0.2`），故两个回环别名即异站。
    #[test]
    fn hls_login_header_not_leaked_to_cross_site_segments() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-cross-site");
        set_test_root(&root);

        // 异站服务器（127.0.0.2）：承载跨站 segment
        let (cdn_port, cdn_seen) = spawn_router_server_on("127.0.0.2", |head| {
            let target = request_target(head);
            if target.starts_with("/cdn-seg.ts") {
                return HttpReply::ok("video/mp2t", b"CDN-SEG".to_vec());
            }
            HttpReply::status(404)
        });

        // 同站服务器（127.0.0.1）：playlist + 同站 segment
        let (site_port, site_seen) = {
            let playlist = media_playlist(&[
                "#EXTINF:10,",
                "same-seg.ts",
                "#EXTINF:10,",
                &format!("http://127.0.0.2:{cdn_port}/cdn-seg.ts"),
            ]);
            spawn_router_server(move |head| {
                let target = request_target(head);
                if target.starts_with("/playlist.m3u8") {
                    return HttpReply::ok(
                        "application/vnd.apple.mpegurl",
                        playlist.clone().into_bytes(),
                    );
                }
                if target.starts_with("/same-seg.ts") {
                    return HttpReply::ok("video/mp2t", b"SAME-SEG".to_vec());
                }
                HttpReply::status(404)
            })
        };

        let book_url = "https://a.com/book/hls-cross-site";
        let source_url = "http://127.0.0.1";
        // 书源静态头（UA）+ 登录头（Authorization）分开：静态头跨站也发，
        // 登录头只在同站发
        insert_audio_book_with_header(
            book_url,
            source_url,
            Some(r#"{"User-Agent":"LegadoTest/1.0"}"#),
            "hello",
            "第一章",
        );
        crate::api::source_login_cache::put_login_header(
            source_url,
            r#"{"Authorization":"Bearer secret"}"#,
        )
        .expect("写登录头");

        let play_url = format!("http://127.0.0.1:{site_port}/playlist.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        );
        // 清理登录头（进程级内存真源，避免污染其他测试）
        let _ = crate::api::source_login_cache::remove_login_header(source_url);
        let out = out.expect("同站 playlist + 同站/跨站 segment 应合并成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"SAME-SEGCDN-SEG".to_vec()
        );

        // 同站资源（playlist / same-seg）必须带登录头
        let site_heads = site_seen.lock().unwrap().clone();
        assert_eq!(
            site_heads.len(),
            2,
            "playlist + 同站 segment: {site_heads:?}"
        );
        for head in &site_heads {
            assert_eq!(
                request_header(head, "authorization").as_deref(),
                Some("Bearer secret"),
                "同站请求必须带登录头（否则登录后才能听的源全废）: {head}"
            );
            assert_eq!(
                request_header(head, "user-agent").as_deref(),
                Some("LegadoTest/1.0"),
                "静态头同站必须发送: {head}"
            );
        }

        // 跨站 segment：不得带登录头，但静态头仍须发送
        let cdn_heads = cdn_seen.lock().unwrap().clone();
        assert_eq!(cdn_heads.len(), 1, "只应有 1 次跨站 segment 请求");
        let cdn_head = &cdn_heads[0];
        assert!(
            request_header(cdn_head, "authorization").is_none(),
            "跨站 segment 不得收到登录头（P2-6 凭据外泄）: {cdn_head}"
        );
        assert_eq!(
            request_header(cdn_head, "user-agent").as_deref(),
            Some("LegadoTest/1.0"),
            "跨站 segment 仍须带静态头 UA: {cdn_head}"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    /// P2-6 单元层：`HlsFetchCtx::headers_for` 的同站/跨站门控语义
    ///
    /// 不依赖网络：直接构造 `SourceHeaderSet`（静态头 + 登录头）与 ctx，
    /// 断言同站 URL 带登录头、跨站 URL 不带，且两站都带静态头与 playUrl 显式头。
    #[test]
    fn headers_for_gates_login_headers_per_request_url() {
        let mut static_headers = HashMap::new();
        static_headers.insert("User-Agent".to_string(), "LegadoTest/1.0".to_string());
        let mut login_headers = HashMap::new();
        login_headers.insert("Authorization".to_string(), "Bearer secret".to_string());
        let header_set = SourceHeaderSet {
            static_headers,
            login_headers,
        };
        let mut extra_headers = HashMap::new();
        extra_headers.insert("X-Play-Option".to_string(), "1".to_string());
        let client = test_client();
        let ctx = HlsFetchCtx {
            client: &client,
            header_set: &header_set,
            source_url: "https://www.example.com/book",
            extra_headers: &extra_headers,
            playlist_base: "https://www.example.com/media/playlist.m3u8".to_string(),
            cancel_snapshot: 0,
            key_cache: HashMap::new(),
        };

        // 同站（同 eTLD+1）：登录头 + 静态头 + playUrl 显式头
        let same = ctx.headers_for("https://cdn.example.com/media/seg0.ts");
        assert_eq!(
            same.get("Authorization").map(String::as_str),
            Some("Bearer secret"),
            "同 eTLD+1 必须带登录头"
        );
        assert_eq!(
            same.get("User-Agent").map(String::as_str),
            Some("LegadoTest/1.0")
        );
        assert_eq!(same.get("X-Play-Option").map(String::as_str), Some("1"));

        // 跨站（不同 eTLD+1）：无登录头，静态头 + playUrl 显式头仍在
        let cross = ctx.headers_for("https://cdn3.example-cdn.net/seg0.ts");
        assert!(
            !cross.contains_key("Authorization"),
            "跨站请求不得携带登录头: {cross:?}"
        );
        assert_eq!(
            cross.get("User-Agent").map(String::as_str),
            Some("LegadoTest/1.0"),
            "跨站仍须带静态头"
        );
        assert_eq!(
            cross.get("X-Play-Option").map(String::as_str),
            Some("1"),
            "playUrl 显式头属于该媒体请求本身，跨站也应发送"
        );

        // 相对 URI：按 playlist_base 绝对化后再判定（落在同站 → 带登录头）
        let relative = ctx.headers_for("/media/seg1.ts");
        assert_eq!(
            relative.get("Authorization").map(String::as_str),
            Some("Bearer secret"),
            "相对 URI 应经 playlist_base 绝对化为同站，故带登录头"
        );
    }

    /// P2-1：playUrl 显式头（`AnalyzeUrl.headers()`）里的敏感凭据键跨站必须剔除
    ///
    /// 这些键可能来自 playUrl 尾部 `,{"headers":{"Cookie":…}}` 或模板
    /// `@Header:{Authorization:…}`。书源作者自带而非用户登录态，但同样不该随
    /// 每个 segment/key 发往任意 CDN。防盗链所需的 `Referer`/`User-Agent`
    /// 跨站照发。
    #[test]
    fn headers_for_strips_sensitive_extra_headers_cross_site() {
        let header_set = SourceHeaderSet::default();
        let mut extra_headers = HashMap::new();
        extra_headers.insert("Cookie".to_string(), "sid=abc".to_string());
        extra_headers.insert("Authorization".to_string(), "Bearer extra".to_string());
        extra_headers.insert(
            "proxy-authorization".to_string(),
            "Basic cHJveHk=".to_string(),
        );
        extra_headers.insert(
            "Referer".to_string(),
            "https://www.example.com/player".to_string(),
        );
        extra_headers.insert("User-Agent".to_string(), "LegadoTest/2.0".to_string());
        let client = test_client();
        let ctx = HlsFetchCtx {
            client: &client,
            header_set: &header_set,
            source_url: "https://www.example.com/book",
            extra_headers: &extra_headers,
            playlist_base: "https://www.example.com/media/playlist.m3u8".to_string(),
            cancel_snapshot: 0,
            key_cache: HashMap::new(),
        };

        // 同站：全部显式头照发
        let same = ctx.headers_for("https://cdn.example.com/seg0.ts");
        assert_eq!(same.get("Cookie").map(String::as_str), Some("sid=abc"));
        assert_eq!(
            same.get("Authorization").map(String::as_str),
            Some("Bearer extra")
        );
        assert_eq!(
            same.get("proxy-authorization").map(String::as_str),
            Some("Basic cHJveHk=")
        );
        assert_eq!(
            same.get("Referer").map(String::as_str),
            Some("https://www.example.com/player")
        );

        // 跨站：敏感键全部剔除（大小写不敏感），防盗链头仍在
        let cross = ctx.headers_for("https://cdn3.example-cdn.net/seg0.ts");
        assert!(
            !cross.keys().any(|k| k.eq_ignore_ascii_case("cookie")),
            "跨站不得发送 Cookie: {cross:?}"
        );
        assert!(
            !cross
                .keys()
                .any(|k| k.eq_ignore_ascii_case("authorization")),
            "跨站不得发送 Authorization: {cross:?}"
        );
        assert!(
            !cross
                .keys()
                .any(|k| k.eq_ignore_ascii_case("proxy-authorization")),
            "跨站不得发送 Proxy-Authorization: {cross:?}"
        );
        assert_eq!(
            cross.get("Referer").map(String::as_str),
            Some("https://www.example.com/player"),
            "Referer 是防盗链所需，跨站仍须发送"
        );
        assert_eq!(
            cross.get("User-Agent").map(String::as_str),
            Some("LegadoTest/2.0")
        );
    }

    /// P2-5：HLS 合并总体积上限——超限 Err，且目录无残留文件/标记
    #[test]
    fn hls_merge_total_size_over_budget_fails_without_residue() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-budget");
        set_test_root(&root);
        // 注入小上限：每段 8 字节，上限 20 字节 → 第 3 段写入前超限
        set_test_merge_max_bytes(Some(20));

        let playlist = media_playlist(&[
            "#EXTINF:10,",
            "s0.ts",
            "#EXTINF:10,",
            "s1.ts",
            "#EXTINF:10,",
            "s2.ts",
        ]);
        let (port, _seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/playlist.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/s0.ts")
                || target.starts_with("/s1.ts")
                || target.starts_with("/s2.ts")
            {
                return HttpReply::ok("video/mp2t", b"12345678".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-budget";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/playlist.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("体积上限"), "应报体积上限: {err}");
        assert!(err.contains("20"), "文案应含上限值: {err}");

        // 恢复生产上限（进程级状态，必须复位）
        set_test_merge_max_bytes(None);

        let names: Vec<String> = super::read_dir_entries(&book_dir(book_url))
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        assert!(names.is_empty(), "失败不得残留文件: {names:?}");

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // ─── P2-5：直播 playlist 拒绝缓存 ──────────────────────────────────────

    /// 无 `#EXT-X-ENDLIST` 的 playlist（直播滑动窗口）必须拒绝缓存：
    /// Err 文案含「直播」，且不留残留文件与 `.complete` 标记
    #[test]
    fn live_playlist_is_rejected_without_residue() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-live");
        set_test_root(&root);

        // 直播 playlist：无 EXT-X-ENDLIST
        let live = concat!(
            "#EXTM3U\n",
            "#EXT-X-VERSION:4\n",
            "#EXT-X-TARGETDURATION:10\n",
            "#EXT-X-MEDIA-SEQUENCE:100\n",
            "#EXTINF:10,\n",
            "live0.ts\n",
            "#EXTINF:10,\n",
            "live1.ts\n",
        )
        .to_string();
        let (port, seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/live.m3u8") {
                return HttpReply::ok("application/vnd.apple.mpegurl", live.clone().into_bytes());
            }
            if target.starts_with("/live0.ts") {
                return HttpReply::ok("video/mp2t", b"LIVE-0".to_vec());
            }
            if target.starts_with("/live1.ts") {
                return HttpReply::ok("video/mp2t", b"LIVE-1".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-live";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/live.m3u8");
        let err = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect_err("直播 playlist 必须拒绝缓存");
        let msg = err.to_string();
        assert!(msg.contains("直播"), "错误文案须含「直播」: {msg}");
        assert!(
            msg.contains("EXT-X-ENDLIST"),
            "错误文案应说明缺 ENDLIST: {msg}"
        );

        // 只应请求了 playlist（门禁在写盘前），不得请求任何分片
        let targets: Vec<String> = seen
            .lock()
            .unwrap()
            .iter()
            .map(|h| request_target(h))
            .collect();
        assert_eq!(targets.len(), 1, "直播门禁应在拉分片前拒绝: {targets:?}");
        assert!(targets[0].starts_with("/live.m3u8"));

        // 无残留：目录里不得有数据文件或 .complete 标记
        let dir = book_dir(book_url);
        let leftovers: Vec<String> = if dir.exists() {
            fs::read_dir(&dir)
                .unwrap()
                .filter_map(|e| e.ok())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect()
        } else {
            Vec::new()
        };
        assert!(
            leftovers.is_empty(),
            "直播拒绝后不得留残留文件: {leftovers:?}"
        );
        assert!(!audio_cache_query(book_url, 0, "hello", "第一章"));

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }

    // ─── P2-3：音频轨优先选档 ─────────────────────────────────────────────

    /// master 含 `EXT-X-MEDIA:TYPE=AUDIO,URI="audio.m3u8"` + 视频 variant →
    /// 必须拉独立音频轨而非任何 variant（服务端记录请求路径断言）
    ///
    /// 改前（`select_variant`）：纯音频内容只在音轨里，选到的 variant 是视频档
    /// → 红；改后（`select_playlist_uri`）：优先音轨 → 绿。
    #[test]
    fn hls_master_prefers_audio_rendition_over_video_variant() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let root = unique_root("hls-audio-rendition");
        set_test_root(&root);

        // 标准形态：音轨独立声明，variant 全是视频档
        let master = concat!(
            "#EXTM3U\n",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"main\",DEFAULT=YES,URI=\"audio.m3u8\"\n",
            "#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS=\"avc1.4d401f,mp4a.40.2\",RESOLUTION=1280x720,AUDIO=\"aud\"\n",
            "video.m3u8\n",
        )
        .to_string();
        let audio_playlist = media_playlist(&["#EXTINF:10,", "ar0.ts", "#EXTINF:10,", "ar1.ts"]);
        let video_playlist = media_playlist(&["#EXTINF:10,", "vr0.ts"]);
        let (port, seen) = spawn_router_server(move |head| {
            let target = request_target(head);
            if target.starts_with("/master.m3u8") {
                return HttpReply::ok("application/vnd.apple.mpegurl", master.clone().into_bytes());
            }
            if target.starts_with("/audio.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    audio_playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/video.m3u8") {
                return HttpReply::ok(
                    "application/vnd.apple.mpegurl",
                    video_playlist.clone().into_bytes(),
                );
            }
            if target.starts_with("/ar0.ts") {
                return HttpReply::ok("video/mp2t", b"AR-0".to_vec());
            }
            if target.starts_with("/ar1.ts") {
                return HttpReply::ok("video/mp2t", b"AR-1".to_vec());
            }
            if target.starts_with("/vr0.ts") {
                return HttpReply::ok("video/mp2t", b"VR-0".to_vec());
            }
            HttpReply::status(404)
        });

        let book_url = "https://a.com/book/hls-audio-rendition";
        insert_audio_book(
            book_url,
            "https://source.example/audio",
            "hello",
            "第一章",
            false,
        );
        let play_url = format!("http://127.0.0.1:{port}/master.m3u8");
        let out = audio_cache_download_with_client(
            &test_client(),
            book_url,
            0,
            "hello",
            "第一章",
            &play_url,
        )
        .expect("master 应选独立音频轨并合并成功");
        let json: serde_json::Value = serde_json::from_str(&out).unwrap();
        assert_eq!(
            fs::read(json["path"].as_str().unwrap()).unwrap(),
            b"AR-0AR-1".to_vec(),
            "应只下载独立音频轨的分片"
        );

        let targets: Vec<String> = seen
            .lock()
            .unwrap()
            .iter()
            .map(|h| request_target(h))
            .collect();
        assert!(
            targets.iter().any(|t| t.starts_with("/audio.m3u8")),
            "必须拉独立音频轨 playlist: {targets:?}"
        );
        assert!(
            !targets.iter().any(|t| t.starts_with("/video.m3u8")),
            "视频 variant playlist 不得被请求: {targets:?}"
        );
        assert!(
            !targets.iter().any(|t| t.starts_with("/vr0.ts")),
            "视频 variant 分片不得被请求: {targets:?}"
        );

        clear_test_root();
        let _ = fs::remove_dir_all(&root);
    }
}
