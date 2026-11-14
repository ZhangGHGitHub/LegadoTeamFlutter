//! TXT 解码文本的有界缓存（审查 2026-11-13 P2-4）
//!
//! 背景：TXT 的章节区间（`ChapterInfo.start/end`）是**解码后文本**的
//! UTF-8 字节偏移（见 [`crate::txt::TxtParser::get_chapters_with_rule_config`]），
//! 不是原文件字节偏移；因此取正文必须先拿到「同一编码下的完整解码文本」。
//! 修复前每章都 `read_to_end` + 全量 decode，大文件翻页时重复 O(file) I/O
//! 与解码（内存峰值 ≈ 原文件 + 解码副本）。
//!
//! 本模块按 `(path, encoding)` 缓存最近若干本书的解码结果：命中时零文件
//! 正文读取、零解码，只做字符串切片。
//!
//! # 失效策略（正确性红线）
//!
//! 缓存条目绑定文件「戳」：字节数 + mtime + 首尾 4KB 内容指纹，三者任一
//! 不符即视为未命中并重新读取解码。指纹的用途是覆盖「同长度、同 mtime 的
//! 原地替换」——仅 mtime+size 在文件系统时间戳粒度（Windows 上系统时钟
//! 约 15ms）内可能漏判。
//!
//! 读取完成后会用**实际读到的字节**重算指纹与长度，与打开时的戳不符
//! （读取期间文件被改写）则不写入缓存，避免缓存撕裂内容；本次仍按原有
//! 语义返回已读内容。
//!
//! 残余风险（已评估）：指纹只采样首尾各 4KB，理论上「长度、mtime 完全
//! 不变且仅中部内容不同」的替换无法识别；常规写文件/替换（复制、重命名、
//! 下载落盘）都会改变长度或 mtime，因此不构成实际路径。不采用全文件哈希
//! 是因为那会重新引入 O(file) 读取，与本修复目标冲突。
//!
//! # 容量
//!
//! 条目数与解码文本总字节数双上限（生产：最近 4 本 / 64 MiB），按最近使用
//! 顺序淘汰。单条超过总上限的文本不缓存——大文件退化为修复前的逐次读取
//! 语义（正确但不提速），避免为提速引入 OOM 风险。
//!
//! 注意：受章节坐标系限制（解码后文本偏移），本修复只做整书缓存，不能按
//! 章节字节偏移做 seek 窗口读取；超大 TXT（解码后 > 64 MiB）仍逐章全文件
//! 读取。

use std::collections::hash_map::DefaultHasher;
use std::fs::File;
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::SystemTime;

use encoding_rs::{Encoding, UTF_8};

use legado_core::LegadoResult;

use crate::txt::{decode_text, detect_encoding_from_sample, encoding_for_label};

/// 文件首/尾采样长度（同时作为编码检测样本的上限，与
/// [`crate::txt::TxtParser::detect_encoding`] 的 4KB 口径一致）
const SAMPLE_LEN: usize = 4096;

/// 缓存条目数上限。
///
/// 生产取「最近 4 本」；测试档放宽，避免并行单测互相淘汰导致命中类断言
/// 不稳定（淘汰策略本身由本模块内的小容量实例单测覆盖）。
const MAX_ENTRIES: usize = if cfg!(test) { 1024 } else { 4 };

/// 解码文本总字节上限。
///
/// 生产 64 MiB（约 2~4 本常见网文）；测试档放宽到 1 GiB（实际占用 = 各
/// 单测夹具总和，远小于此）。
const MAX_BYTES: usize = if cfg!(test) {
    1024 * 1024 * 1024
} else {
    64 * 1024 * 1024
};

/// 文件内容戳：任一字段变化即视为缓存失效
#[derive(Clone, Debug, PartialEq, Eq)]
struct FileStamp {
    /// 文件字节数
    len: u64,
    /// 最后修改时间（平台不支持时为 `None`，此时依赖长度 + 指纹）
    modified: Option<SystemTime>,
    /// 首/尾采样指纹（见 [`fingerprint_bytes`]）
    fingerprint: u64,
}

struct CacheEntry {
    path: String,
    encoding: &'static str,
    stamp: FileStamp,
    text: Arc<String>,
    last_used: u64,
}

/// 有界 LRU 解码缓存（按 `(path, encoding)` 命中，按文件戳校验）
struct TextCache {
    entries: Vec<CacheEntry>,
    total_bytes: usize,
    tick: u64,
    max_entries: usize,
    max_bytes: usize,
}

impl TextCache {
    fn new(max_entries: usize, max_bytes: usize) -> Self {
        Self {
            entries: Vec::new(),
            total_bytes: 0,
            tick: 0,
            max_entries,
            max_bytes,
        }
    }

    fn next_tick(&mut self) -> u64 {
        self.tick = self.tick.wrapping_add(1);
        self.tick
    }

    /// 查找命中并刷新 LRU 时间戳
    fn get(
        &mut self,
        path: &str,
        encoding: &'static str,
        stamp: &FileStamp,
    ) -> Option<Arc<String>> {
        let tick = self.next_tick();
        let entry = self.entries.iter_mut().find(|entry| {
            entry.path == path && entry.encoding == encoding && entry.stamp == *stamp
        })?;
        entry.last_used = tick;
        Some(Arc::clone(&entry.text))
    }

    /// 写入缓存；超容量条目直接放弃缓存（不影响本次返回内容）
    fn insert(&mut self, path: &str, encoding: &'static str, stamp: FileStamp, text: Arc<String>) {
        if self.max_entries == 0 || self.max_bytes == 0 || text.len() > self.max_bytes {
            return;
        }
        // 同 key（同路径 + 同编码 + 同戳）直接替换，避免重复占额
        if let Some(pos) = self.entries.iter().position(|entry| {
            entry.path == path && entry.encoding == encoding && entry.stamp == stamp
        }) {
            let removed = self.entries.remove(pos);
            self.total_bytes = self.total_bytes.saturating_sub(removed.text.len());
        }
        let last_used = self.next_tick();
        self.total_bytes += text.len();
        self.entries.push(CacheEntry {
            path: path.to_string(),
            encoding,
            stamp,
            text,
            last_used,
        });
        self.evict();
    }

    /// 淘汰最久未使用的条目，直到条目数与总字节数均回到上限内
    fn evict(&mut self) {
        while self.entries.len() > self.max_entries || self.total_bytes > self.max_bytes {
            let Some((idx, _)) = self
                .entries
                .iter()
                .enumerate()
                .min_by_key(|(_, entry)| entry.last_used)
            else {
                break;
            };
            let removed = self.entries.remove(idx);
            self.total_bytes = self.total_bytes.saturating_sub(removed.text.len());
        }
    }
}

/// 进程级解码缓存（跨书、跨章节复用）
static TEXT_CACHE: LazyLock<Mutex<TextCache>> =
    LazyLock::new(|| Mutex::new(TextCache::new(MAX_ENTRIES, MAX_BYTES)));

/// 加锁（容忍中毒：缓存是纯派生数据，中毒后继续用原值即可）
fn with_cache<T>(f: impl FnOnce(&mut TextCache) -> T) -> T {
    let mut guard = TEXT_CACHE
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    f(&mut guard)
}

/// 打开文件并采集内容戳；`head` 为前 4KB 样本（编码检测复用）
struct OpenedText {
    file: File,
    stamp: FileStamp,
    head: Vec<u8>,
}

fn open_and_stamp(path: &str) -> LegadoResult<OpenedText> {
    let mut file = File::open(path)?;
    let meta = file.metadata()?;
    let len = meta.len();

    let head_len = usize::try_from(len.min(SAMPLE_LEN as u64)).unwrap_or(0);
    let mut head = vec![0u8; head_len];
    let filled = read_up_to(&mut file, &mut head)?;
    head.truncate(filled);

    let mut hasher = DefaultHasher::new();
    head.hash(&mut hasher);
    if len > SAMPLE_LEN as u64 {
        file.seek(SeekFrom::Start(len - SAMPLE_LEN as u64))?;
        let mut tail = vec![0u8; SAMPLE_LEN];
        let filled = read_up_to(&mut file, &mut tail)?;
        tail.truncate(filled);
        tail.hash(&mut hasher);
    }

    let stamp = FileStamp {
        len,
        modified: meta.modified().ok(),
        fingerprint: hasher.finish(),
    };
    Ok(OpenedText { file, stamp, head })
}

/// 尽量填满缓冲区（容忍短读与 EINTR）
fn read_up_to(file: &mut File, buf: &mut [u8]) -> std::io::Result<usize> {
    let mut filled = 0usize;
    while filled < buf.len() {
        match file.read(&mut buf[filled..]) {
            Ok(0) => break,
            Ok(n) => filled += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(filled)
}

/// 按与 [`open_and_stamp`] 相同的规则计算内容指纹（用于读后一致性校验）
fn fingerprint_bytes(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    let head_len = bytes.len().min(SAMPLE_LEN);
    bytes[..head_len].hash(&mut hasher);
    if bytes.len() > SAMPLE_LEN {
        bytes[bytes.len() - SAMPLE_LEN..].hash(&mut hasher);
    }
    hasher.finish()
}

/// 解析目标编码：显式 charset 优先，否则按文件头样本自动检测
fn resolve_encoding(charset: Option<&str>, head: &[u8]) -> LegadoResult<&'static Encoding> {
    if let Some(label) = charset.map(str::trim).filter(|s| !s.is_empty()) {
        return encoding_for_label(label);
    }
    let detected = detect_encoding_from_sample(head);
    Ok(Encoding::for_label(detected.as_bytes()).unwrap_or(UTF_8))
}

/// 读取并缓存解码文本（`(path, charset)` 语义与修复前
/// `read_file_bytes` + `decode_with_charset` 完全一致）
pub(crate) fn load_decoded_text(path: &str, charset: Option<&str>) -> LegadoResult<Arc<String>> {
    let mut opened = open_and_stamp(path)?;
    let encoding = resolve_encoding(charset, &opened.head)?;

    if let Some(text) = with_cache(|cache| cache.get(path, encoding.name(), &opened.stamp)) {
        return Ok(text);
    }

    #[cfg(test)]
    test_counters::record_full_load(path);

    // 采样读取后文件位置不在起点（小文件已在 EOF），必须显式回到起点
    opened.file.seek(SeekFrom::Start(0))?;
    let mut bytes = Vec::with_capacity(usize::try_from(opened.stamp.len).unwrap_or(0));
    opened.file.read_to_end(&mut bytes)?;
    let text = Arc::new(decode_text(&bytes, encoding));

    // 读取期间文件被改写 → 本次内容可能撕裂，不写入缓存
    let unchanged = bytes.len() as u64 == opened.stamp.len
        && fingerprint_bytes(&bytes) == opened.stamp.fingerprint;
    if unchanged {
        with_cache(|cache| cache.insert(path, encoding.name(), opened.stamp, Arc::clone(&text)));
    }
    Ok(text)
}

/// 测试埋点：记录每个路径的「完整文件读取 + 解码」次数（生产禁用）
///
/// 按键独立计数，避免并行单测互相干扰；仅 `cfg(test)` 编译。
#[cfg(test)]
mod test_counters {
    use std::collections::HashMap;
    use std::sync::{LazyLock, Mutex};

    static FULL_LOADS: LazyLock<Mutex<HashMap<String, usize>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));

    pub(super) fn record_full_load(path: &str) {
        let mut guard = FULL_LOADS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        *guard.entry(path.to_string()).or_insert(0) += 1;
    }

    pub(super) fn full_loads(path: &str) -> usize {
        let guard = FULL_LOADS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        guard.get(path).copied().unwrap_or(0)
    }
}

/// 测试埋点读取入口：指定路径触发过多少次全文件读取+解码
#[cfg(test)]
pub(crate) fn full_file_loads(path: &str) -> usize {
    test_counters::full_loads(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stamp(len: u64, modified: Option<SystemTime>, fingerprint: u64) -> FileStamp {
        FileStamp {
            len,
            modified,
            fingerprint,
        }
    }

    fn text(value: &str) -> Arc<String> {
        Arc::new(value.to_string())
    }

    #[test]
    fn test_get_requires_exact_path_encoding_and_stamp() {
        let mut cache = TextCache::new(4, 1024);
        let s = stamp(3, None, 7);
        cache.insert("a.txt", "UTF-8", s.clone(), text("abc"));
        assert!(cache.get("a.txt", "UTF-8", &s).is_some());
        assert!(
            cache.get("b.txt", "UTF-8", &s).is_none(),
            "路径不同不得命中"
        );
        assert!(
            cache.get("a.txt", "GBK", &s).is_none(),
            "编码不同不得串内容"
        );
        assert!(
            cache.get("a.txt", "UTF-8", &stamp(4, None, 7)).is_none(),
            "长度变化必须失效"
        );
        assert!(
            cache.get("a.txt", "UTF-8", &stamp(3, None, 8)).is_none(),
            "指纹变化必须失效"
        );
    }

    #[test]
    fn test_evicts_least_recently_used_when_entry_cap_reached() {
        let mut cache = TextCache::new(2, 1024);
        let s = stamp(1, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("a"));
        cache.insert("b", "UTF-8", s.clone(), text("b"));
        // 访问 a，使 b 成为最久未使用
        assert!(cache.get("a", "UTF-8", &s).is_some());
        cache.insert("c", "UTF-8", s.clone(), text("c"));
        assert!(cache.get("a", "UTF-8", &s).is_some(), "a 应保留");
        assert!(cache.get("b", "UTF-8", &s).is_none(), "b 应被淘汰");
        assert!(cache.get("c", "UTF-8", &s).is_some(), "c 应保留");
    }

    #[test]
    fn test_evicts_by_total_byte_cap() {
        let mut cache = TextCache::new(10, 10);
        let s = stamp(6, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("123456"));
        cache.insert("b", "UTF-8", s.clone(), text("abcdef"));
        assert!(cache.get("b", "UTF-8", &s).is_some(), "新条目应保留");
        assert!(
            cache.get("a", "UTF-8", &s).is_none(),
            "总字节超限应淘汰旧条目"
        );
    }

    #[test]
    fn test_oversized_entry_is_not_cached() {
        let mut cache = TextCache::new(10, 4);
        let s = stamp(5, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("12345"));
        assert!(
            cache.get("a", "UTF-8", &s).is_none(),
            "单条超过总容量上限时不得缓存（避免为提速引入 OOM）"
        );
    }

    #[test]
    fn test_same_key_replaces_without_double_accounting() {
        let mut cache = TextCache::new(1, 1024);
        let s = stamp(1, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("x"));
        cache.insert("a", "UTF-8", s.clone(), text("yy"));
        assert_eq!(cache.entries.len(), 1, "同 key 应替换而非重复");
        assert_eq!(cache.total_bytes, 2);
        assert_eq!(
            cache.get("a", "UTF-8", &s).as_deref().map(String::as_str),
            Some("yy")
        );
    }

    #[test]
    fn test_insert_is_noop_when_capacity_zero() {
        let mut cache = TextCache::new(0, 0);
        let s = stamp(1, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("x"));
        assert!(cache.entries.is_empty());
        assert!(cache.get("a", "UTF-8", &s).is_none());
    }
}
