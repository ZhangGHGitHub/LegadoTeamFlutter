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
//! 缓存条目绑定文件「戳」：字节数 + mtime + 首/中/尾三段各 4KB 内容指纹，
//! 任一字段不符即视为未命中并重新读取解码。指纹的用途是覆盖「同长度、同
//! mtime 的原地替换」——仅 mtime+size 在文件系统时间戳粒度（Windows 上
//! 系统时钟约 15ms）内可能漏判；`cp -p` / `rsync -t` / 解压保留时间戳 /
//! 备份恢复还会把新文件 mtime 设为源文件时间戳。中段采样用于识别其中
//! 「仅中部修订」的替换（首尾未变时仍能失效）。
//!
//! 读取完成后会用**实际读到的字节**重算指纹与长度，与打开时的戳不符
//! （读取期间文件被改写）则不写入缓存，避免缓存撕裂内容；本次仍按原有
//! 语义返回已读内容。
//!
//! 残余风险（已评估）：指纹只采样首/中/尾三段 4KB，理论上「长度、mtime
//! 完全不变且三段内容均相同、仅其余位置不同」的替换无法识别；常规写文件/
//! 替换（复制、重命名、下载落盘）都会改变长度或 mtime，因此不构成实际
//! 路径。不采用全文件哈希是因为那会重新引入 O(file) 读取，与本修复目标
//! 冲突。
//!
//! # 容量
//!
//! 条目数与解码文本总字节数双上限（生产：最近 4 本 / 128 MiB），按最近使用
//! 顺序淘汰。单条超过总上限的文本不缓存——大文件退化为修复前的逐次读取
//! 语义（正确但不提速），避免为提速引入 OOM 风险。
//!
//! 注意：受章节坐标系限制（解码后文本偏移），本修复只做整书缓存，不能按
//! 章节字节偏移做 seek 窗口读取；解码后超过总上限的 TXT 仍逐章全文件读取。
//!
//! [R32] 上限由 64 MiB 提到 128 MiB 的实测依据见 [`PROD_MAX_BYTES`]。

use std::collections::hash_map::DefaultHasher;
use std::fs::File;
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::SystemTime;

use encoding_rs::{Encoding, UTF_8};

use legado_core::LegadoResult;

use crate::txt::{
    decode_text, detect_encoding_from_sample, encoding_for_label, read_up_to, ENCODING_SAMPLE_LEN,
};

/// 文件首/中/尾**指纹**采样长度（内容戳用）
///
/// 与编码检测样本长度（[`ENCODING_SAMPLE_LEN`]，B21 起 64KB）分离：指纹
/// 只需覆盖首尾中三段的字节内容，长度越大缓存命中时的 I/O 越贵。
const SAMPLE_LEN: usize = 4096;

/// 全文件读取的预分配上限：文件元数据长度不可信（稀疏/损坏/超大）时，
/// 避免按声明长度一次性大块分配；`read_to_end` 会按实际内容渐进扩容。
const READ_PREALLOC_LIMIT: u64 = 32 * 1024 * 1024;

/// 缓存条目数上限。
///
/// 生产取「最近 4 本」；测试档放宽，避免并行单测互相淘汰导致命中类断言
/// 不稳定（淘汰策略本身由本模块内的小容量实例单测覆盖）。
const MAX_ENTRIES: usize = if cfg!(test) { 1024 } else { 4 };

/// 解码文本总字节上限。
///
/// 生产 128 MiB（约 4~8 本常见网文）；测试档放宽到 1 GiB（实际占用 = 各
/// 单测夹具总和，远小于此）。
///
/// [R32] 由 64 MiB 提到 128 MiB（2026-11-23）。原 64 MiB 档下，解码后文本
/// 超限的 TXT 完全不缓存，退化为「每章读全文件 + 全量解码」：
///
/// - 59.6 MiB GBK（6000 章）实测 **98.5 ms/章**，而同书在 128 MiB 档下
///   **0.111 ms/章**（约 887×）；64 MiB 档命中时也是 0.09~0.11 ms/章，
///   即退化代价来自「未命中」而非容量档位本身。
/// - 触发退化的原始文件门槛：GBK ≈ 42.7 MiB（GBK→UTF-8 约 1.5×）、
///   UTF-8 ≈ 64 MiB、UTF-16 ≈ 32 MiB。批35 验收的 57.5 MiB 中文 TXT
///   正好落在 GBK 门槛之上，属真实用户规模。
/// - 内存代价**不升反略降**：峰值工作集由「原文件 + 解码副本」双份变为
///   单份解码文本常驻。59.6 MiB GBK 夹具实测峰值 161.5 MiB（64 MiB 档，
///   每章重复分配）→ 159.1 MiB（128 MiB 档，缓存命中后不再重复分配）。
///   UTF-8 89.4 MiB 夹具同为 184.3 MiB。
/// - 阅读器翻页还会对前后各 2 章做预载（`reader_screen.dart`
///   `_preloadAdjacentChapters`，本地书同样生效），未命中时单次翻页实际
///   触发 5 次全文件读取+解码（≈ 5 × 98 ms ≈ 0.5 s），放大退化影响。
///
/// 单条上限与总上限同值：单条超过总上限仍不缓存（`insert` 的守卫不变），
/// 因此 128 MiB 档覆盖「解码后 ≤ 128 MiB」的书，仍保留 OOM 兜底。
pub(crate) const PROD_MAX_BYTES: usize = 128 * 1024 * 1024;

const MAX_BYTES: usize = if cfg!(test) {
    1024 * 1024 * 1024
} else {
    PROD_MAX_BYTES
};

/// 文件内容戳：任一字段变化即视为缓存失效
#[derive(Clone, Debug, PartialEq, Eq)]
struct FileStamp {
    /// 文件字节数
    len: u64,
    /// 最后修改时间（平台不支持时为 `None`，此时依赖长度 + 指纹）
    modified: Option<SystemTime>,
    /// 首/中/尾采样指纹（见 [`fingerprint_bytes`]）
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
        // 同 (path, encoding) 直接替换旧条目：文件更新后旧戳条目不会再命中，
        // 若把戳纳入去重键，同一本书反复更新会堆积永不复用的死条目并挤掉
        // 其他书。
        if let Some(pos) = self
            .entries
            .iter()
            .position(|entry| entry.path == path && entry.encoding == encoding)
        {
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

    /// 解码前预留空间：按最久未使用顺序淘汰，直到「现有 + `need`」落回上限内。
    ///
    /// [R32] 动机：解码期间**原始字节与解码文本同时存在**，若缓存里已驻留
    /// 大条目，峰值 ≈ 缓存预算 + 本次原始字节 + 解码副本。以本次原始字节数
    /// 作为解码后大小的保守估计先淘汰，可把共存峰值压回「预算 + 单本解码」
    /// 量级。中文主场景 GBK→UTF-8 约 1.43×、UTF-8 为 1×，原始字节数是
    /// 解码后大小的**下界**，故此处预留偏保守（可能多淘汰，不影响正确性；
    /// 若解码后仍超预算，[`Self::insert`] 的 `evict` 兜底稳态）。
    ///
    /// `need >= max_bytes` 时**直接返回不清空**：原始字节已是解码后大小的
    /// 下界（GBK/UTF-8），这样的书解码后必然超预算、[`Self::insert`] 会放弃
    /// 写入；若在此清空缓存，超大书的每一章读取都会白丢其他书的命中，属
    /// 净损失。（UTF-16 的 ASCII 主体是唯一例外——解码后可能小于原始字节，
    /// 该编码的 TXT 极罕见，宁可少淘汰也不误伤。）
    ///
    /// 缓存未命中时才调用；若随后因文件被改写而放弃写入，淘汰属白做，但
    /// 仅影响命中率，不涉及正确性。
    fn reserve(&mut self, need: usize) {
        if self.max_bytes == 0 || need >= self.max_bytes {
            return;
        }
        while self.total_bytes > self.max_bytes - need {
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

/// 打开文件并采集内容戳；`head` 为前 [`ENCODING_SAMPLE_LEN`] 样本（编码检测复用）
///
/// 指纹采样首/中/尾三段各最多 [`SAMPLE_LEN`]；`head` 单独按编码检测口径
/// 读得更长（B21：4KB → 64KB），但**只有前 [`SAMPLE_LEN`] 参与指纹**，
/// 指纹语义与 [`fingerprint_bytes`] 保持一致。
///
/// 中段仅在 `len > 2 * SAMPLE_LEN`（首尾两段之间确实存在未覆盖区间）时读取，
/// 因此小文件不会重复读同一段字节。
fn open_and_stamp(path: &str) -> LegadoResult<OpenedText> {
    let mut file = File::open(path)?;
    let meta = file.metadata()?;
    let len = meta.len();

    // [B21] 编码检测样本扩大（与 TxtParser::detect_encoding 同口径），
    // 避免「前 4KB 纯 ASCII 前言」把后面的 GBK 正文误判成 UTF-8。
    let head_len = usize::try_from(len.min(ENCODING_SAMPLE_LEN as u64)).unwrap_or(0);
    let mut head = vec![0u8; head_len];
    let filled = read_up_to(&mut file, &mut head)?;
    head.truncate(filled);

    let mut hasher = DefaultHasher::new();
    // 指纹只取前 SAMPLE_LEN，保持与 fingerprint_bytes 一致
    head[..head.len().min(SAMPLE_LEN)].hash(&mut hasher);
    if len > SAMPLE_LEN as u64 {
        file.seek(SeekFrom::Start(len - SAMPLE_LEN as u64))?;
        let mut tail = vec![0u8; SAMPLE_LEN];
        let filled = read_up_to(&mut file, &mut tail)?;
        tail.truncate(filled);
        tail.hash(&mut hasher);
    }
    // 中段采样：覆盖「同长度同 mtime、仅中部修订」的替换。`len > 8KB` 时
    // `len/2 + 4KB <= len`，窗口不越过文件末尾。
    if len > 2 * SAMPLE_LEN as u64 {
        file.seek(SeekFrom::Start(len / 2))?;
        let mut middle = vec![0u8; SAMPLE_LEN];
        let filled = read_up_to(&mut file, &mut middle)?;
        middle.truncate(filled);
        middle.hash(&mut hasher);
    }

    let stamp = FileStamp {
        len,
        modified: meta.modified().ok(),
        fingerprint: hasher.finish(),
    };
    Ok(OpenedText { file, stamp, head })
}

/// 按与 [`open_and_stamp`] 相同的规则计算内容指纹（用于读后一致性校验）：
/// 首段 + 尾段 + 中段，顺序与打开时一致。
fn fingerprint_bytes(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    let head_len = bytes.len().min(SAMPLE_LEN);
    bytes[..head_len].hash(&mut hasher);
    if bytes.len() > SAMPLE_LEN {
        bytes[bytes.len() - SAMPLE_LEN..].hash(&mut hasher);
    }
    if bytes.len() > 2 * SAMPLE_LEN {
        let middle = bytes.len() / 2;
        bytes[middle..middle + SAMPLE_LEN].hash(&mut hasher);
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

    // [R32] 解码前先按本次原始字节数预留空间：解码期间原始字节与解码文本
    // 同时存在，缓存里若已有大条目会让峰值叠加（实测 3 本 120 MiB 解码文本
    // 的书交替时峰值 326.8 MiB；预留后 206.8 MiB）。以原始字节数作保守
    // 估计先行淘汰。原始字节数 ≥ 总上限的书（解码后必然更大、不会入缓存）
    // 由 `reserve` 内部直接跳过，避免每章白丢其他书的命中。
    with_cache(|cache| cache.reserve(opened.stamp.len as usize));

    // 采样读取后文件位置不在起点（小文件已在 EOF），必须显式回到起点
    opened.file.seek(SeekFrom::Start(0))?;
    // 元数据长度不可信：预分配封顶，剩余部分由 read_to_end 渐进扩容
    let mut bytes =
        Vec::with_capacity(usize::try_from(opened.stamp.len.min(READ_PREALLOC_LIMIT)).unwrap_or(0));
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

    /// 测试专用临时文件路径（进程号 + 自增值，避免并行用例互踩）
    fn temp_txt_path(name: &str) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "legado_txt_cache_{}_{}_{}",
            std::process::id(),
            n,
            name
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("sample.txt")
    }

    /// 覆盖文件 mtime（模拟 `cp -p` / `rsync -t` / 备份恢复保留源时间戳）
    fn set_mtime(path: &std::path::Path, mtime: std::time::SystemTime) {
        File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(mtime)
            .unwrap();
    }

    /// 把标记写入文件正中（落在中段 4KB 采样窗口 `[len/2, len/2+4KB)` 内）
    fn write_middle_marker(bytes: &mut [u8], marker: &[u8]) {
        let start = bytes.len() / 2;
        bytes[start..start + marker.len()].copy_from_slice(marker);
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

    /// [R32] 生产容量必须覆盖批35 验收规模的大 TXT，且 64 MiB 以上的单条
    /// 解码文本必须真的能进缓存。
    ///
    /// 回归保护点：若有人把 `PROD_MAX_BYTES` 调回 64 MiB，`test` 档的
    /// `MAX_BYTES`（1 GiB）不会暴露问题——只有这条断言能拦住。
    #[test]
    fn test_prod_capacity_covers_oversized_books() {
        // 批35 设备验收用的中文 TXT 为 57.5 MiB；GBK→UTF-8 约 1.43~1.5×，
        // 解码后 ≈ 82~86 MiB。128 MiB 档留有余量，64 MiB 档完全覆盖不到。
        // 用 const 断言（clippy::assertions_on_constants）：编译期即可失败。
        const {
            assert!(
                PROD_MAX_BYTES >= 96 * 1024 * 1024,
                "生产容量必须覆盖 57.5MiB GBK TXT 解码后的 ~86MiB"
            )
        };

        // 用生产上限构造实例，验证 >64 MiB 的单条能进缓存并命中
        let mut cache = TextCache::new(MAX_ENTRIES, PROD_MAX_BYTES);
        let big = text(&"a".repeat(64 * 1024 * 1024 + 1)); // 刚过 64 MiB
        assert!(big.len() > 64 * 1024 * 1024);
        let s = stamp(big.len() as u64, None, 1);
        cache.insert("big.txt", "UTF-8", s.clone(), Arc::clone(&big));
        assert!(
            cache.get("big.txt", "UTF-8", &s).is_some(),
            "刚过 64 MiB 的解码文本在生产容量下必须可缓存（R32 前会被直接放弃）"
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

    /// [R32] 解码前预留空间：按最久未使用顺序淘汰，腾出 `need` 字节。
    ///
    /// 动机是压低「解码期间原始字节 + 解码文本」与已驻留条目的叠加峰值。
    #[test]
    fn test_reserve_evicts_lru_until_space_available() {
        let mut cache = TextCache::new(10, 10);
        let s = stamp(1, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("1234"));
        cache.insert("b", "UTF-8", s.clone(), text("5678"));
        assert_eq!(cache.total_bytes, 8);

        // 需要 5 字节：总上限 10，必须淘汰最久未使用的 a（4 字节）
        cache.reserve(5);
        assert_eq!(cache.total_bytes, 4, "应只淘汰到刚好够用");
        assert!(
            cache.get("a", "UTF-8", &s).is_none(),
            "最久未使用的应被淘汰"
        );
        assert!(cache.get("b", "UTF-8", &s).is_some(), "较新的条目应保留");
    }

    /// [R32] `need >= 总上限` 时不得清空缓存：这种书解码后必然超预算、
    /// `insert` 会放弃写入，清空只会让超大书的每章读取白丢其他书的命中。
    #[test]
    fn test_reserve_skips_when_need_exceeds_capacity() {
        let mut cache = TextCache::new(10, 10);
        let s = stamp(1, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("1234"));
        cache.insert("b", "UTF-8", s.clone(), text("5678"));

        // need 远超上限（模拟超大书的原始字节数）
        cache.reserve(1000);
        assert_eq!(cache.total_bytes, 8, "超出上限的预留不得淘汰任何条目");
        assert!(
            cache.get("a", "UTF-8", &s).is_some(),
            "其他书的缓存命中不得被超大书白白挤掉"
        );
        assert!(cache.get("b", "UTF-8", &s).is_some());

        // 边界：need 恰等于上限同样跳过
        cache.reserve(10);
        assert_eq!(cache.total_bytes, 8, "need == max_bytes 也应跳过");
    }

    /// [R32] 预留后 `insert` 仍按原有语义处理超限条目（放弃缓存）。
    #[test]
    fn test_reserve_does_not_change_insert_oversize_guard() {
        let mut cache = TextCache::new(10, 10);
        let s = stamp(1, None, 1);
        cache.reserve(20); // 跳过，不清空
        cache.insert("big", "UTF-8", s.clone(), text("12345678901")); // 11 > 10
        assert!(
            cache.get("big", "UTF-8", &s).is_none(),
            "单条超上限仍不得缓存（reserve 不改变该守卫）"
        );
    }

    /// [R32] 预留不会影响后续插入：腾出空间后新条目正常缓存。
    #[test]
    fn test_reserve_then_insert_caches_new_entry() {
        let mut cache = TextCache::new(10, 10);
        let s = stamp(1, None, 1);
        cache.insert("a", "UTF-8", s.clone(), text("12345678"));
        cache.reserve(9);
        assert!(cache.entries.is_empty(), "需要 9 字节时应淘汰 8 字节条目");
        cache.insert("b", "UTF-8", s.clone(), text("123456789"));
        assert!(
            cache.get("b", "UTF-8", &s).is_some(),
            "预留腾出的空间应能被新条目使用"
        );
    }

    /// [审查 P3-1] 去重键必须是 `(path, encoding)`：文件更新后旧戳条目
    /// 永不命中，若按「路径 + 编码 + 戳」去重会在同一本书反复更新时堆积死条目。
    #[test]
    fn test_insert_replaces_stale_entry_for_same_path_and_encoding() {
        let mut cache = TextCache::new(10, 1024);
        cache.insert("a", "UTF-8", stamp(1, None, 1), text("old"));
        cache.insert("a", "UTF-8", stamp(1, None, 2), text("new"));
        assert_eq!(
            cache.entries.len(),
            1,
            "同路径同编码的新戳条目必须替换旧条目"
        );
        assert_eq!(cache.total_bytes, 3, "旧条目字节数必须扣回");
        assert!(
            cache.get("a", "UTF-8", &stamp(1, None, 1)).is_none(),
            "已被替换的旧戳不得命中"
        );
        assert_eq!(
            cache
                .get("a", "UTF-8", &stamp(1, None, 2))
                .as_deref()
                .map(String::as_str),
            Some("new")
        );

        // 编码不同是独立条目，不得互相替换
        cache.insert("a", "GBK", stamp(1, None, 2), text("gbk"));
        assert_eq!(cache.entries.len(), 2, "编码不同不得互相替换");
        assert_eq!(cache.total_bytes, 6);
    }

    /// [审查 P2-1] 同长度 + 同 mtime + 首尾 4KB 相同、仅中部 4KB 不同：
    /// 中段指纹必须使缓存失效（修复前只采样首尾会命中旧正文）。
    #[test]
    fn test_middle_sample_detects_middle_only_replacement() {
        // 20KB：首段 0..4096、中段 10000..14096、尾段 15904..20000 互不重叠
        const LEN: usize = 20_000;
        let path = temp_txt_path("middle_only");
        let path_str = path.to_str().unwrap();

        let mut v1 = vec![b'a'; LEN];
        write_middle_marker(&mut v1, b"OLD");
        std::fs::write(&path, &v1).unwrap();
        let original_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();

        let old = load_decoded_text(path_str, Some("UTF-8")).unwrap();
        assert!(old.contains("OLD"), "首次读取应包含旧正文");
        assert_eq!(full_file_loads(path_str), 1);

        // 替换成同长度、仅中段不同的新内容，并把 mtime 拨回原值
        let mut v2 = v1.clone();
        write_middle_marker(&mut v2, b"NEW");
        std::fs::write(&path, &v2).unwrap();
        set_mtime(&path, original_mtime);
        let tampered = std::fs::metadata(&path).unwrap();
        assert_eq!(tampered.len(), LEN as u64, "夹具必须同长度");
        assert_eq!(
            tampered.modified().unwrap(),
            original_mtime,
            "夹具必须同 mtime"
        );

        let new = load_decoded_text(path_str, Some("UTF-8")).unwrap();
        assert!(
            new.contains("NEW"),
            "仅中部变化的同长度同 mtime 替换必须失效并读到新内容"
        );
        assert!(!new.contains("OLD"), "不得返回缓存中的旧正文");
        assert_eq!(
            full_file_loads(path_str),
            2,
            "中段指纹不符必须触发一次重新读取"
        );

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// [审查 P3-5] mtime 单独变化（内容与长度不变）也必须失效。
    #[test]
    fn test_cache_invalidated_when_only_mtime_changes() {
        let path = temp_txt_path("mtime_only");
        let path_str = path.to_str().unwrap();
        std::fs::write(&path, b"alpha\nbeta\n").unwrap();
        let original_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();

        let first = load_decoded_text(path_str, Some("UTF-8")).unwrap();
        assert_eq!(full_file_loads(path_str), 1);

        // 选一个与当前时刻明确不同的时间（2020-09-13），避免文件系统粒度内相等
        let different_mtime =
            SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
        assert_ne!(different_mtime, original_mtime);
        set_mtime(&path, different_mtime);
        assert_eq!(
            std::fs::metadata(&path).unwrap().modified().unwrap(),
            different_mtime
        );

        let second = load_decoded_text(path_str, Some("UTF-8")).unwrap();
        assert_eq!(first, second, "内容未变时解码结果应一致");
        assert_eq!(
            full_file_loads(path_str),
            2,
            "mtime 变化必须使缓存失效（即使内容与长度未变）"
        );

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// [审查 P3-5] 仅尾部（>4KB 偏移）内容变化必须失效。
    #[test]
    fn test_tail_sample_detects_tail_only_change() {
        const LEN: usize = 20_000;
        let path = temp_txt_path("tail_only");
        let path_str = path.to_str().unwrap();

        let mut v1 = vec![b'a'; LEN];
        let marker_start = LEN - 100;
        v1[marker_start..marker_start + 3].copy_from_slice(b"OLD");
        std::fs::write(&path, &v1).unwrap();
        let original_mtime = std::fs::metadata(&path).unwrap().modified().unwrap();

        let old = load_decoded_text(path_str, Some("UTF-8")).unwrap();
        assert!(old.contains("OLD"), "首次读取应包含旧尾段");
        assert_eq!(full_file_loads(path_str), 1);

        let mut v2 = v1.clone();
        v2[marker_start..marker_start + 3].copy_from_slice(b"NEW");
        std::fs::write(&path, &v2).unwrap();
        set_mtime(&path, original_mtime);
        let tampered = std::fs::metadata(&path).unwrap();
        assert_eq!(tampered.len(), LEN as u64);
        assert_eq!(tampered.modified().unwrap(), original_mtime);

        let new = load_decoded_text(path_str, Some("UTF-8")).unwrap();
        assert!(new.contains("NEW"), "仅尾部变化必须使缓存失效并读到新内容");
        assert!(!new.contains("OLD"));
        assert_eq!(
            full_file_loads(path_str),
            2,
            "尾段指纹不符必须触发一次重新读取"
        );

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// [P1-1] 解码缓存路径同样复用 `detect_encoding_from_sample`：
    /// 超过 64KB 的 UTF-8/GBK 文件在采样边界落在字符内部时（pad=0..3）也必须
    /// 解出正确正文，不能因缓存路径绕开 `TxtParser::detect_encoding` 而漏修。
    ///
    /// 修复前 pad 非对齐时 `resolve_encoding` 拿到 windows-1252，正文整段乱码。
    #[test]
    fn test_load_decoded_text_large_sample_all_alignments() {
        let mut text = String::new();
        for i in 1..=40 {
            text.push_str(&format!("第{i}章 缓存编码对齐\n"));
            text.push_str(&"这是正文内容。".repeat(200));
            text.push('\n');
        }
        assert!(text.len() > 64 * 1024, "夹具必须超过 64KB 采样窗口");

        // UTF-8
        for pad in 0..4usize {
            let path = temp_txt_path(&format!("align_utf8_{pad}"));
            let mut content = vec![b'A'; pad];
            content.push(b'\n');
            content.extend_from_slice(text.as_bytes());
            std::fs::write(&path, &content).unwrap();

            let decoded = load_decoded_text(path.to_str().unwrap(), None).unwrap();
            assert!(
                !decoded.contains('\u{FFFD}'),
                "pad={pad} UTF-8 缓存路径不得产出替换字符"
            );
            assert!(
                decoded.contains("第1章 缓存编码对齐") && decoded.contains("这是正文内容。"),
                "pad={pad} UTF-8 缓存路径正文应正确解码"
            );
            let _ = std::fs::remove_dir_all(path.parent().unwrap());
        }

        // GBK
        let (gbk, _, had_errors) = encoding_rs::GBK.encode(&text);
        assert!(!had_errors);
        let gbk_bytes = gbk.into_owned();
        for pad in 0..4usize {
            let path = temp_txt_path(&format!("align_gbk_{pad}"));
            let mut content = vec![b'A'; pad];
            content.push(b'\n');
            content.extend_from_slice(&gbk_bytes);
            std::fs::write(&path, &content).unwrap();

            let decoded = load_decoded_text(path.to_str().unwrap(), None).unwrap();
            assert!(
                !decoded.contains('\u{FFFD}'),
                "pad={pad} GBK 缓存路径不得产出替换字符"
            );
            assert!(
                decoded.contains("第1章 缓存编码对齐") && decoded.contains("这是正文内容。"),
                "pad={pad} GBK 缓存路径正文应正确解码"
            );
            let _ = std::fs::remove_dir_all(path.parent().unwrap());
        }
    }
}
