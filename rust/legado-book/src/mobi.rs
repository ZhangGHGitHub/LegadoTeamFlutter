//! MOBI 格式解析模块
//!
//! MOBI 基于 PalmDoc (PDB) 容器格式，结构如下：
//! 1. PDB 头（78 字节）：包含文档名称、类型标识、记录数量等
//! 2. 记录索引表：每条记录 8 字节（offset + attributes）
//! 3. Record 0：MOBI 头（含元数据、压缩方式、文本偏移等）
//! 4. Record 1..N：压缩的文本内容记录
//!
//! 本模块实现了（对照 Kotlin `app/.../lib/mobi` 移植）：
//! - PDB 头解析、MOBI 头解析（元数据提取）
//! - EXTH 扩展元数据解析（author/description/title/coverOffset/boundary 等）
//! - PalmDoc (LZ77 变种) 解压缩
//! - HUFF/CDIC 解压缩（compression=17480，移植自 HuffcdicDecompressor.kt）
//! - 文本记录尾部附加条目剥离（trailingFlags）
//! - INDX 索引体系（TAGX 位编码 + CNCX 字符串表，移植自 MobiBook.kt）
//! - NCX 目录树 → 章节列表
//! - KF8 (AZW3) 双格式解析：Skeleton/Fragment 拼装（移植自 KF8Book.kt）
//! - KF6 按 `<mbp:pagebreak/>` 分节（移植自 KF6Book.kt）
//! - EXTH coverOffset/thumbnailOffset → 封面图片提取
//!
//! 未实现：
//! - LZMA 压缩 (compression=17481)
//! - 加密内容 (encryption != 0)

use std::cell::UnsafeCell;
use std::collections::HashMap;
use std::fs::File;
use std::io::Read;

use legado_core::{LegadoError, LegadoResult};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// MOBI 解析器
pub struct MobiParser;

// ---------------------------------------------------------------------------
// 大端读取辅助
// ---------------------------------------------------------------------------

fn read_u16(buf: &[u8], pos: usize) -> u16 {
    u16::from_be_bytes([buf[pos], buf[pos + 1]])
}

fn read_u32(buf: &[u8], pos: usize) -> u32 {
    u32::from_be_bytes([buf[pos], buf[pos + 1], buf[pos + 2], buf[pos + 3]])
}

/// 读取 7-bit 变长整数（MOBI 索引通用编码）
///
/// 每字节低 7 位为数据，最高位为 1 表示该值为最后一个字节。
/// 对照 Kotlin：MobiBook.readIndexEntry / readCncx 中的内联实现。
fn read_varint(buf: &[u8], pos: &mut usize) -> u32 {
    let mut v: u32 = 0;
    let max = (*pos + 4).min(buf.len());
    while *pos < max {
        let b = buf[*pos];
        *pos += 1;
        v = (v << 7) | u32::from(b & 0x7F);
        if b & 0x80 != 0 {
            break;
        }
    }
    v
}

// ---------------------------------------------------------------------------
// PDB 容器
// ---------------------------------------------------------------------------

/// PDB 文件：全部记录读入内存，按索引随机访问
///
/// 对照 Kotlin：PDBFile.kt
struct Records {
    name: String,
    offsets: Vec<u32>,
    data: Vec<u8>,
}

impl Records {
    fn open(path: &str) -> LegadoResult<Records> {
        let mut file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;
        let mut data = Vec::new();
        file.read_to_end(&mut data)
            .map_err(|e| LegadoError::BookParse(format!("读取文件失败: {e}")))?;
        if data.len() < 78 {
            return Err(LegadoError::BookParse("文件过小，不是有效的 PDB 文件".into()));
        }
        let name = String::from_utf8_lossy(&data[0..32])
            .trim_end_matches('\0')
            .to_string();
        let num_records = read_u16(&data, 76) as usize;
        if data.len() < 78 + num_records * 8 {
            return Err(LegadoError::BookParse("PDB 记录索引表不完整".into()));
        }
        let mut offsets = Vec::with_capacity(num_records);
        for i in 0..num_records {
            offsets.push(read_u32(&data, 78 + i * 8));
        }
        Ok(Records {
            name,
            offsets,
            data,
        })
    }

    fn count(&self) -> usize {
        self.offsets.len()
    }

    /// 获取指定索引记录的原始字节
    fn record(&self, index: usize) -> LegadoResult<&[u8]> {
        if index >= self.offsets.len() {
            return Err(LegadoError::BookParse(format!(
                "记录索引越界: {index} / {}",
                self.offsets.len()
            )));
        }
        let start = self.offsets[index] as usize;
        let end = if index + 1 < self.offsets.len() {
            self.offsets[index + 1] as usize
        } else {
            self.data.len()
        };
        let start = start.min(self.data.len());
        let end = end.max(start).min(self.data.len());
        Ok(&self.data[start..end])
    }
}

// ---------------------------------------------------------------------------
// 各层头部结构
// ---------------------------------------------------------------------------

/// PalmDoc 头（Record 0 前 16 字节）
///
/// 对照 Kotlin：entities/PalmDocHeader.kt
#[derive(Debug)]
struct PalmDocHeader {
    compression: u16,
    num_text_records: u16,
    #[allow(dead_code)]
    record_size: u16,
    encryption: u16,
}

/// MOBI 头
///
/// 对照 Kotlin：entities/MobiHeader.kt + MobiReader.readMobiHeader
#[derive(Debug)]
struct MobiHeader {
    #[allow(dead_code)]
    length: u32,
    encoding: u32,
    version: u32,
    /// 完整书名
    title: String,
    /// 首个资源记录索引
    resource_start: i64,
    /// HUFF 码表记录索引（compression=17480 时有效）
    huffcdic: u32,
    /// HUFF/CDIC 记录数量
    num_huffcdic: u32,
    #[allow(dead_code)]
    exth_flag: u32,
    /// 文本记录尾部附加条目标志
    trailing_flags: u32,
    /// NCX 索引记录（0xFFFFFFFF 表示无）
    indx: i64,
}

/// KF8 专用头字段（仅 version >= 8 时存在）
///
/// 对照 Kotlin：entities/KF8Header.kt + MobiReader.readKF8Header
#[derive(Debug, Clone, Copy)]
struct Kf8Header {
    #[allow(dead_code)]
    fdst: i64,
    #[allow(dead_code)]
    num_fdst: u32,
    /// Fragment 索引记录
    frag: i64,
    /// Skeleton 索引记录
    skel: i64,
    #[allow(dead_code)]
    guide: i64,
}

/// EXTH 元数据
#[derive(Debug, Default)]
struct ExthData {
    title: Option<String>,
    /// creator 允许多值，取第一个作为作者
    creator: Option<String>,
    description: Option<String>,
    cover_offset: Option<u32>,
    thumbnail_offset: Option<u32>,
    /// KF6/KF8 双格式文件的分界记录索引
    boundary: Option<u32>,
}

/// Record 0 的全部头信息
struct EntryHeaders {
    palmdoc: PalmDocHeader,
    mobi: MobiHeader,
    exth: ExthData,
    kf8: Option<Kf8Header>,
}

/// EXTH 记录类型常量
const EXTH_CREATOR: u32 = 100;
const EXTH_DESCRIPTION: u32 = 103;
const EXTH_BOUNDARY: u32 = 121;
const EXTH_COVER_OFFSET: u32 = 201;
const EXTH_THUMBNAIL_OFFSET: u32 = 202;
const EXTH_TITLE: u32 = 503;

// ---------------------------------------------------------------------------
// 头部解析
// ---------------------------------------------------------------------------

/// 解析指定记录（通常是 Record 0 或 KF8 分界记录）中的全部头信息
///
/// 对照 Kotlin：MobiReader.readMobiEntryHeaders
fn parse_entry_headers(rec: &[u8]) -> LegadoResult<EntryHeaders> {
    if rec.len() < 16 {
        return Err(LegadoError::BookParse("Record 0 过小，无 PalmDoc 头".into()));
    }
    let palmdoc = PalmDocHeader {
        compression: read_u16(rec, 0),
        num_text_records: read_u16(rec, 8),
        record_size: read_u16(rec, 10),
        encryption: read_u16(rec, 12),
    };

    if rec.len() < 20 || &rec[16..20] != b"MOBI" {
        return Err(LegadoError::BookParse("缺少 MOBI 头标识".into()));
    }

    // 各字段偏移为 Record 内绝对偏移（对照 MobiReader.readMobiHeader）
    let length = read_u32(rec, 20);
    let encoding = read_u32(rec, 28);
    let version = read_u32(rec, 36);
    let title_offset = read_u32(rec, 84) as usize;
    let title_length = read_u32(rec, 88) as usize;
    let resource_start = i64::from(read_u32(rec, 108));
    let huffcdic = read_u32(rec, 112);
    let num_huffcdic = read_u32(rec, 116);
    let exth_flag = read_u32(rec, 128);

    // 尾部标志与 INDX 在扩展头区域（头长度 >= 248 才有）
    let trailing_flags = if rec.len() >= 248 { read_u32(rec, 240) } else { 0 };
    let indx_raw = if rec.len() >= 248 { read_u32(rec, 244) } else { u32::MAX };
    let indx = if indx_raw == u32::MAX { -1 } else { i64::from(indx_raw) };

    // 完整书名
    let mut title = String::new();
    if title_length > 0
        && title_length < 4096
        && title_offset + title_length <= rec.len()
    {
        title = decode_mobi_text(&rec[title_offset..title_offset + title_length], encoding);
    }

    // EXTH 紧跟 MOBI 头之后
    let mut exth = ExthData::default();
    if exth_flag & 0x40 != 0 {
        let exth_start = 16 + length as usize;
        if exth_start + 12 <= rec.len() {
            exth = parse_exth(&rec[exth_start..]).unwrap_or_default();
        }
    }

    // KF8 头（仅 version >= 8）
    let kf8 = if version >= 8 && rec.len() >= 264 {
        let to_i64 = |v: u32| -> i64 {
            if v == u32::MAX {
                -1
            } else {
                i64::from(v)
            }
        };
        Some(Kf8Header {
            fdst: to_i64(read_u32(rec, 192)),
            num_fdst: read_u32(rec, 196),
            frag: to_i64(read_u32(rec, 248)),
            skel: to_i64(read_u32(rec, 252)),
            guide: to_i64(read_u32(rec, 260)),
        })
    } else {
        None
    };

    Ok(EntryHeaders {
        palmdoc,
        mobi: MobiHeader {
            length,
            encoding,
            version,
            title,
            resource_start,
            huffcdic,
            num_huffcdic,
            exth_flag,
            trailing_flags,
            indx,
        },
        exth,
        kf8,
    })
}

/// 解析 EXTH 块
///
/// 结构：magic "EXTH" + 头长度 + 记录数 + N 条记录(type/length/data)。
/// 对照 Kotlin：MobiReader.readExth
fn parse_exth(data: &[u8]) -> LegadoResult<ExthData> {
    if data.len() < 12 || &data[0..4] != b"EXTH" {
        return Err(LegadoError::BookParse("EXTH 魔数不匹配".into()));
    }
    let record_count = read_u32(data, 8) as usize;
    let mut result = ExthData::default();
    let mut pos = 12usize;
    for _ in 0..record_count {
        if pos + 8 > data.len() {
            break;
        }
        let rec_type = read_u32(data, pos);
        let rec_len = read_u32(data, pos + 4) as usize;
        if rec_len < 8 || pos + rec_len > data.len() {
            break;
        }
        let payload = &data[pos + 8..pos + rec_len];
        match rec_type {
            EXTH_CREATOR => {
                if result.creator.is_none() {
                    result.creator = Some(String::from_utf8_lossy(payload).to_string());
                }
            }
            EXTH_DESCRIPTION => {
                result.description = Some(String::from_utf8_lossy(payload).to_string());
            }
            EXTH_TITLE => {
                result.title = Some(String::from_utf8_lossy(payload).to_string());
            }
            EXTH_BOUNDARY if payload.len() >= 4 => {
                result.boundary = Some(read_u32(payload, 0));
            }
            EXTH_COVER_OFFSET if payload.len() >= 4 => {
                result.cover_offset = Some(read_u32(payload, 0));
            }
            EXTH_THUMBNAIL_OFFSET if payload.len() >= 4 => {
                result.thumbnail_offset = Some(read_u32(payload, 0));
            }
            _ => {}
        }
        pos += rec_len;
    }
    Ok(result)
}

// ---------------------------------------------------------------------------
// 书籍对象：文本记录解压与资源访问
// ---------------------------------------------------------------------------

/// MOBI 书籍（对照 Kotlin：MobiBook.kt 抽象基类）
struct MobiBook {
    records: Records,
    headers: EntryHeaders,
    /// KF6/KF8 双格式时 KF8 部分的记录基址（单格式为 0）
    kf8_boundary: usize,
    /// 文本记录解压后的累计字节偏移
    text_offsets: Vec<usize>,
    huff: Option<HuffcdicDecompressor>,
}

impl MobiBook {
    /// 打开书籍：解析头部，处理 KF6/KF8 双格式分界
    ///
    /// 对照 Kotlin：MobiReader.readMobi
    fn open(path: &str) -> LegadoResult<MobiBook> {
        let records = Records::open(path)?;
        if records.count() == 0 {
            return Err(LegadoError::BookParse("MOBI 文件无记录".into()));
        }
        let rec0 = records.record(0)?.to_vec();
        let mut headers = parse_entry_headers(&rec0)?;
        let mut kf8_boundary = 0usize;

        // 双格式：KF6 部分的 EXTH boundary 指向 KF8 头部所在记录
        if headers.mobi.version < 8 {
            if let Some(boundary) = headers.exth.boundary {
                if boundary > 0 && (boundary as usize) < records.count() {
                    if let Ok(brec) = records.record(boundary as usize) {
                        if let Ok(kh) = parse_entry_headers(brec) {
                            if kh.mobi.version >= 8 {
                                // 资源记录以 KF6 部分声明的 resourceStart 为准
                                let resource_start = headers.mobi.resource_start;
                                headers = kh;
                                headers.mobi.resource_start = resource_start;
                                kf8_boundary = boundary as usize;
                            }
                        }
                    }
                }
            }
        }

        if headers.palmdoc.encryption != 0 && headers.palmdoc.encryption != 1 {
            return Err(LegadoError::BookParse(
                "该 MOBI 文件已加密，无法解析。".into(),
            ));
        }

        let huff = if headers.palmdoc.compression == 17480 {
            Some(HuffcdicDecompressor::new(&records, &headers.mobi, kf8_boundary)?)
        } else {
            None
        };

        let mut book = MobiBook {
            records,
            headers,
            kf8_boundary,
            text_offsets: Vec::new(),
            huff,
        };
        book.build_text_offsets()?;
        Ok(book)
    }

    /// 相对 KF8 分界的记录访问（对照 Kotlin：MobiBook.getRecord）
    fn record(&self, index: i64) -> LegadoResult<&[u8]> {
        self.records.record(self.kf8_boundary + index as usize)
    }

    /// 资源记录访问（对照 Kotlin：MobiBook.getResource）
    fn resource(&self, index: u32) -> LegadoResult<&[u8]> {
        let start = self.headers.mobi.resource_start;
        if start < 0 {
            return Err(LegadoError::BookParse("无资源记录".into()));
        }
        self.records.record(start as usize + index as usize)
    }

    /// 预解压全部文本记录并记录累计偏移
    ///
    /// 对照 Kotlin：MobiBook.buildTextRecordOffsets
    fn build_text_offsets(&mut self) -> LegadoResult<()> {
        let n = self.headers.palmdoc.num_text_records as usize;
        let mut offset = 0usize;
        for i in 0..n {
            let rec = self.text_record(i)?;
            offset += rec.len();
            self.text_offsets.push(offset);
        }
        Ok(())
    }

    fn total_text_len(&self) -> usize {
        self.text_offsets.last().copied().unwrap_or(0)
    }

    /// 解压单个文本记录（先剥离尾部附加条目）
    ///
    /// 对照 Kotlin：MobiBook.getTextRecord
    fn text_record(&self, index: usize) -> LegadoResult<Vec<u8>> {
        let raw = self.record(index as i64 + 1)?;
        let stripped = remove_trailing_entries(raw, self.headers.mobi.trailing_flags);
        self.decompress(&stripped)
    }

    /// 压缩分发（对照 Kotlin：MobiBook 的 decompressor 选择逻辑）
    fn decompress(&self, data: &[u8]) -> LegadoResult<Vec<u8>> {
        match self.headers.palmdoc.compression {
            1 => Ok(data.to_vec()),
            2 => Ok(palmdoc_decompress(data)),
            17480 => match &self.huff {
                Some(h) => h.decompress(data),
                None => Err(LegadoError::BookParse("HUFF/CDIC 码表未初始化".into())),
            },
            17481 => Err(LegadoError::BookParse(
                "不支持 LZMA 压缩格式 (compression=17481)。\
                 建议使用 Calibre 等工具将文件转换为 EPUB 格式。"
                    .into(),
            )),
            other => Err(LegadoError::BookParse(format!(
                "不支持的压缩方式: compression={other}"
            ))),
        }
    }

    /// 提取解压后文本的 [start, end) 字节区间
    fn text_bytes(&self, start: usize, end: usize) -> LegadoResult<Vec<u8>> {
        let end = end.min(self.total_text_len());
        let start = start.min(end);
        let mut out = Vec::with_capacity(end - start);
        for (i, &cum) in self.text_offsets.iter().enumerate() {
            let rec_start = if i == 0 { 0 } else { self.text_offsets[i - 1] };
            if rec_start >= end {
                break;
            }
            if cum <= start {
                continue;
            }
            let rec = self.text_record(i)?;
            let lo = start.saturating_sub(rec_start);
            let hi = (end - rec_start).min(rec.len());
            if lo < hi {
                out.extend_from_slice(&rec[lo..hi]);
            }
        }
        Ok(out)
    }

    /// 拼接全部解压文本
    fn full_text_bytes(&self) -> LegadoResult<Vec<u8>> {
        self.text_bytes(0, self.total_text_len())
    }

    /// 封面提取（对照 Kotlin：MobiBook.getCover）
    fn get_cover(&self) -> Option<Vec<u8>> {
        if let Some(off) = self.headers.exth.cover_offset {
            if off != u32::MAX {
                if let Ok(r) = self.resource(off) {
                    return Some(r.to_vec());
                }
            }
        }
        if let Some(off) = self.headers.exth.thumbnail_offset {
            if off != u32::MAX {
                if let Ok(r) = self.resource(off) {
                    return Some(r.to_vec());
                }
            }
        }
        None
    }
}

/// 剥离文本记录尾部的附加条目（多字节尾部 / 数据块）
///
/// 对照 Kotlin：MobiBook.removeTrailingEntries
fn remove_trailing_entries(data: &[u8], trailing_flags: u32) -> Vec<u8> {
    if trailing_flags == 0 || data.is_empty() {
        return data.to_vec();
    }
    let multibyte = trailing_flags & 1 != 0;
    let num_entries = ((trailing_flags >> 1).count_ones()) as usize;
    let size = data.len();
    let mut extra = 0usize;
    for _ in 0..num_entries {
        let mut value: usize = 0;
        let hi = size.saturating_sub(extra);
        let lo = hi.saturating_sub(5);
        for &b in &data[lo..hi] {
            if b & 0x80 != 0 {
                value = 0;
            }
            value = (value << 7) | usize::from(b & 0x7F);
        }
        extra += value;
    }
    if multibyte && extra < size {
        let b = data[size - 1 - extra];
        extra += usize::from(b & 0x03) + 1;
    }
    let keep = size.saturating_sub(extra);
    data[..keep].to_vec()
}

// ---------------------------------------------------------------------------
// HUFF/CDIC 解压器
// ---------------------------------------------------------------------------

/// CDIC 字典条目（对照 Kotlin：CDICData.kt）
struct CdicEntry {
    data: Vec<u8>,
    decompressed: bool,
}

/// HUFF/CDIC 解压器
///
/// 对照 Kotlin：decompress/HuffcdicDecompressor.kt 逐行移植。
/// HUFF 记录提供码表（table1 + mincode/maxcode 表），
/// CDIC 记录提供字典；解码为位级过程，字典条目可递归嵌套压缩。
struct HuffcdicDecompressor {
    table1: Vec<u32>,
    mincode_table: Vec<u64>,
    maxcode_table: Vec<u64>,
    /// UnsafeCell 用于递归解码时缓存展开结果（对照 Kotlin 原地更新 entry.data）
    dictionary: UnsafeCell<Vec<CdicEntry>>,
}

impl HuffcdicDecompressor {
    /// 从 HUFF + CDIC 记录构建解压器
    fn new(
        records: &Records,
        mobi: &MobiHeader,
        base: usize,
    ) -> LegadoResult<HuffcdicDecompressor> {
        let huff_idx = mobi.huffcdic as usize;
        let num = mobi.num_huffcdic as usize;
        if huff_idx == 0 || huff_idx == u32::MAX as usize || num == 0 {
            return Err(LegadoError::BookParse("无效的 HUFF/CDIC 记录声明".into()));
        }

        // ---- HUFF 码表 ----
        let huff = records.record(base + huff_idx)?;
        if huff.len() < 16 || &huff[0..4] != b"HUFF" {
            return Err(LegadoError::BookParse("无效的 HUFF 记录".into()));
        }
        let offset1 = read_u32(huff, 8) as usize;
        let offset2 = read_u32(huff, 12) as usize;

        if offset1 + 256 * 4 > huff.len() {
            return Err(LegadoError::BookParse("HUFF table1 越界".into()));
        }
        let mut table1 = Vec::with_capacity(256);
        for i in 0..256 {
            table1.push(read_u32(huff, offset1 + i * 4));
        }

        let mut mincode_table = vec![0u64; 33];
        let mut maxcode_table = vec![0u64; 33];
        if offset2 + 32 * 8 > huff.len() {
            return Err(LegadoError::BookParse("HUFF table2 越界".into()));
        }
        for i in 1..=32usize {
            let mincode = u64::from(read_u32(huff, offset2 + (i - 1) * 8));
            let maxcode = u64::from(read_u32(huff, offset2 + (i - 1) * 8 + 4));
            // 长度为 32 的码字需左移 0 位，checked_shl 防溢出
            mincode_table[i] = mincode.checked_shl((32 - i) as u32).unwrap_or(0);
            maxcode_table[i] = (maxcode + 1)
                .checked_shl((32 - i) as u32)
                .map(|v| v.wrapping_sub(1))
                .unwrap_or(u64::MAX);
        }

        // ---- CDIC 字典 ----
        let mut dictionary = Vec::new();
        for i in 1..num {
            let rec = records.record(base + huff_idx + i)?;
            if rec.len() < 16 || &rec[0..4] != b"CDIC" {
                return Err(LegadoError::BookParse("无效的 CDIC 记录".into()));
            }
            let header_len = read_u32(rec, 4) as usize;
            let num_entries = read_u32(rec, 8) as usize;
            let code_length = read_u32(rec, 12) as usize;

            let n = (1usize << code_length.min(30)).min(num_entries.saturating_sub(dictionary.len()));
            if header_len + n * 2 > rec.len() {
                return Err(LegadoError::BookParse("CDIC 指针表越界".into()));
            }
            for j in 0..n {
                // 指针表中的偏移相对于头后数据区（对照 Kotlin：
                // record.position(length); buffer = record.slice(); buffer.readUInt16(offset)）
                let ptr = read_u16(rec, header_len + j * 2) as usize;
                let pos = header_len + ptr;
                if pos + 2 > rec.len() {
                    return Err(LegadoError::BookParse("CDIC 条目越界".into()));
                }
                let x = read_u16(rec, pos);
                let len = (x & 0x7FFF) as usize;
                let decompressed = x & 0x8000 != 0;
                let start = pos + 2;
                let end = (start + len).min(rec.len());
                dictionary.push(CdicEntry {
                    data: rec[start..end].to_vec(),
                    decompressed,
                });
            }
        }

        Ok(HuffcdicDecompressor {
            table1,
            mincode_table,
            maxcode_table,
            dictionary: UnsafeCell::new(dictionary),
        })
    }

    /// 解压一段 HUFF/CDIC 编码数据
    ///
    /// 对照 Kotlin：HuffcdicDecompressor.decompress
    fn decompress(&self, data: &[u8]) -> LegadoResult<Vec<u8>> {
        let mut out = Vec::new();
        self.decompress_into(data, &mut out, 0)?;
        Ok(out)
    }

    /// 嵌套解码最大深度护栏（Kotlin 无此保护，恶意/损坏文件的自引用字典
    /// 条目会导致无限递归栈溢出，此处改为受控报错）
    const MAX_NEST_DEPTH: usize = 32;

    /// 解压并追加到输出缓冲；字典条目递归解码时创建新缓冲避免混写
    fn decompress_into(&self, data: &[u8], out: &mut Vec<u8>, depth: usize) -> LegadoResult<()> {
        if depth > Self::MAX_NEST_DEPTH {
            return Err(LegadoError::BookParse(
                "HUFF/CDIC 字典嵌套解压超过最大深度，文件可能已损坏".into(),
            ));
        }
        if data.len() < 4 {
            return Ok(());
        }
        let mut bitsleft = (data.len() * 8) as i64;
        let mut pos = 0usize;
        let mut x = read_uintx(data, pos);
        let mut bitcount: i32 = 32;

        loop {
            if bitcount <= 0 {
                pos += 4;
                x = read_uintx(data, pos);
                bitcount += 32;
            }

            let code = (x >> bitcount) & 0xFFFF_FFFF;
            let t1 = self.table1[(code >> 24) as usize];
            let mut codelen = (t1 & 0x1F) as i32;
            if codelen <= 0 {
                return Err(LegadoError::BookParse("HUFF 码表损坏".into()));
            }
            let mut maxcode = ((((t1 as u64) >> 8) + 1) << (32 - codelen)) - 1;

            if t1 & 0x80 == 0 {
                while codelen < 33 && code < self.mincode_table[codelen as usize] {
                    codelen += 1;
                }
                if codelen >= 33 {
                    return Err(LegadoError::BookParse("HUFF 解码失败：码长越界".into()));
                }
                maxcode = self.maxcode_table[codelen as usize];
            }

            bitcount -= codelen;
            bitsleft -= i64::from(codelen);
            if bitsleft < 0 {
                break;
            }

            // 与 Kotlin 一致：按 Int 语义截取字典索引
            let index = ((maxcode - code) >> (32 - codelen)) as u32 as usize;
            // 第一阶段：短借字典读取条目状态（递归前必须结束借用，
            // 避免跨递归持有 &mut 造成别名 UB）
            enum Action {
                Direct(Vec<u8>),
                Nested(Vec<u8>),
            }
            let action = {
                let dict = unsafe { &*self.dictionary.get() };
                if index >= dict.len() {
                    return Err(LegadoError::BookParse("HUFF 字典索引越界".into()));
                }
                if dict[index].decompressed {
                    Action::Direct(dict[index].data.clone())
                } else {
                    Action::Nested(dict[index].data.clone())
                }
            };
            match action {
                Action::Direct(bytes) => out.extend_from_slice(&bytes),
                Action::Nested(nested) => {
                    // 嵌套压缩条目：递归解码后缓存结果
                    // （对照 Kotlin：entry.data = decompress(entry.data); entry.decompressed = true）
                    let mut buf = Vec::new();
                    self.decompress_into(&nested, &mut buf, depth + 1)?;
                    let dict = unsafe { &mut *self.dictionary.get() };
                    dict[index].data = buf.clone();
                    dict[index].decompressed = true;
                    out.extend_from_slice(&buf);
                }
            }
        }
        Ok(())
    }
}

/// 从 offset 处最多读 8 字节构成大端整数（不足补 0）
///
/// 对照 Kotlin：HuffcdicDecompressor.readUIntX
fn read_uintx(data: &[u8], offset: usize) -> u64 {
    let mut v: u64 = 0;
    let mut shift = 56i32;
    for i in 0..8 {
        if offset + i >= data.len() {
            break;
        }
        v |= u64::from(data[offset + i]) << shift;
        shift -= 8;
    }
    v
}

// ---------------------------------------------------------------------------
// PalmDoc 解压缩
// ---------------------------------------------------------------------------

/// PalmDoc LZ77 变种解压缩
fn palmdoc_decompress(input: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity(input.len() * 2);
    let mut i = 0;

    while i < input.len() {
        let c = input[i];
        i += 1;

        match c {
            0 => {
                // 字面 null 字节
                output.push(0);
            }
            1..=8 => {
                // 复制后续 c 个字面字节
                let count = c as usize;
                let end = (i + count).min(input.len());
                output.extend_from_slice(&input[i..end]);
                i = end;
            }
            9..=0x7F => {
                // 字面字节
                output.push(c);
            }
            0x80..=0xBF => {
                // 距离-长度对（2 字节编码）
                if i >= input.len() {
                    break;
                }
                let next = input[i] as u16;
                i += 1;
                let combined = ((c as u16) << 8) | next;
                let distance = ((combined >> 3) & 0x07FF) as usize;
                let length = ((combined & 0x07) + 3) as usize;

                if distance > 0 && distance <= output.len() {
                    let start = output.len() - distance;
                    for j in 0..length {
                        let idx = start + (j % distance);
                        let byte = output[idx];
                        output.push(byte);
                    }
                }
            }
            0xC0..=0xFF => {
                // 空格 + 字面字节
                output.push(b' ');
                output.push(c ^ 0x80);
            }
        }
    }
    output
}

/// 根据编码将字节解码为字符串
fn decode_mobi_text(bytes: &[u8], encoding: u32) -> String {
    let label: &[u8] = match encoding {
        65001 => b"utf-8",
        1252 => b"windows-1252",
        936 => b"gbk",
        950 => b"big5",
        _ => b"windows-1252",
    };
    let enc = encoding_rs::Encoding::for_label(label).unwrap_or(encoding_rs::WINDOWS_1252);
    let (cow, _, _) = enc.decode(bytes);
    cow.into_owned()
}

// ---------------------------------------------------------------------------
// INDX 索引体系
// ---------------------------------------------------------------------------

/// INDX 头（对照 Kotlin：entities/IndxHeader.kt）
struct IndxHeader {
    length: usize,
    idxt: usize,
    num_records: usize,
    num_cncx: usize,
}

/// TAGX 头（对照 Kotlin：entities/TagxHeader.kt）
struct TagxHeader {
    length: usize,
    num_control_bytes: usize,
}

/// TAGX 标签定义（对照 Kotlin：entities/TagxTag.kt）
#[derive(Debug, Clone, Copy)]
struct TagxTag {
    tag: u8,
    num_values: u8,
    bitmask: u8,
    control_byte: u8,
}

/// 索引标签值（对照 Kotlin：entities/IndexTag.kt）
#[derive(Debug, Default)]
struct IndexTag {
    values: Vec<u32>,
}

/// 索引条目（对照 Kotlin：entities/IndexEntry.kt）
struct IndexEntry {
    label: String,
    tag_map: HashMap<u8, IndexTag>,
}

/// 索引数据：条目表 + CNCX 字符串表（对照 Kotlin：entities/IndexData.kt）
struct IndexData {
    table: Vec<IndexEntry>,
    cncx: HashMap<u32, String>,
}

/// 解析 INDX 头（对照 Kotlin：MobiBook.readIndxHeader）
fn read_indx_header(buf: &[u8]) -> LegadoResult<IndxHeader> {
    if buf.len() < 56 || &buf[0..4] != b"INDX" {
        return Err(LegadoError::BookParse("无效的 INDX 记录".into()));
    }
    Ok(IndxHeader {
        length: read_u32(buf, 4) as usize,
        idxt: read_u32(buf, 20) as usize,
        num_records: read_u32(buf, 24) as usize,
        num_cncx: read_u32(buf, 52) as usize,
    })
}

/// 解析 TAGX 头（对照 Kotlin：MobiBook.readTagxHeader）
fn read_tagx_header(buf: &[u8]) -> LegadoResult<TagxHeader> {
    if buf.len() < 12 || &buf[0..4] != b"TAGX" {
        return Err(LegadoError::BookParse("无效的 TAGX 记录".into()));
    }
    Ok(TagxHeader {
        length: read_u32(buf, 4) as usize,
        num_control_bytes: read_u32(buf, 8) as usize,
    })
}

/// 解析 TAGX 标签定义表（对照 Kotlin：MobiBook.readTagxTags）
fn read_tagx_tags(tagx: &TagxHeader, buf: &[u8]) -> Vec<TagxTag> {
    let num_tags = tagx.length.saturating_sub(12) / 4;
    let mut tags = Vec::with_capacity(num_tags);
    let mut pos = 12usize;
    for _ in 0..num_tags {
        if pos + 4 > buf.len() {
            break;
        }
        tags.push(TagxTag {
            tag: buf[pos],
            num_values: buf[pos + 1],
            bitmask: buf[pos + 2],
            control_byte: buf[pos + 3],
        });
        pos += 4;
    }
    tags
}

/// 解析单个索引条目（TAGX 位编码）
///
/// 对照 Kotlin：MobiBook.readIndexEntry
fn read_index_entry(
    buf: &[u8],
    tagx: &TagxHeader,
    tag_table: &[TagxTag],
    idxt_offset: usize,
) -> LegadoResult<IndexEntry> {
    if idxt_offset >= buf.len() {
        return Err(LegadoError::BookParse("INDX 条目偏移越界".into()));
    }
    let len = buf[idxt_offset] as usize;
    let label_start = idxt_offset + 1;
    if label_start + len > buf.len() {
        return Err(LegadoError::BookParse("INDX 条目标签越界".into()));
    }
    let label = String::from_utf8_lossy(&buf[label_start..label_start + len]).to_string();

    // ---- 第一遍：解析 ptagx 描述序列 ----
    let start_pos = label_start + len;
    let mut control_byte_index = 0usize;
    let mut pos = start_pos + tagx.num_control_bytes;

    /// 中间表示：与 Kotlin Ptagx 对应
    enum Ptagx {
        Counted { tag: u8, per_count: u32, value_count: u32 },
        Bytes { tag: u8, value_bytes: u32 },
    }

    let mut ptagxs: Vec<Ptagx> = Vec::new();
    for tag in tag_table {
        if tag.control_byte == 1 {
            control_byte_index += 1;
            continue;
        }
        let offset = start_pos + control_byte_index;
        if offset >= buf.len() {
            break;
        }
        let value = buf[offset] & tag.bitmask;
        if value == tag.bitmask {
            if tag.bitmask.count_ones() > 1 {
                // 多比特掩码：值以 7-bit 变长编码跟在数据区
                let v = read_varint(buf, &mut pos);
                ptagxs.push(Ptagx::Bytes {
                    tag: tag.tag,
                    value_bytes: v,
                });
            } else {
                // 单比特标志：表示"存在"，读取 numValues 个变长值
                // （对照 Kotlin：Ptagx(tag.tag, tag.numValues, 1, null)）
                ptagxs.push(Ptagx::Counted {
                    tag: tag.tag,
                    per_count: tag.num_values as u32,
                    value_count: 1,
                });
            }
        } else {
            // 值内嵌在控制字节的掩码位中，需右移对齐
            let mut mask = tag.bitmask as u32;
            let mut v = value as u32;
            while mask & 1 == 0 && mask != 0 {
                mask >>= 1;
                v >>= 1;
            }
            ptagxs.push(Ptagx::Counted {
                tag: tag.tag,
                per_count: tag.num_values as u32,
                value_count: v,
            });
        }
    }

    // ---- 第二遍：读取各标签的变长值 ----
    let mut tag_map: HashMap<u8, IndexTag> = HashMap::new();
    for ptagx in ptagxs {
        let mut values = Vec::new();
        match ptagx {
            Ptagx::Counted { tag, per_count, value_count } => {
                for _ in 0..(value_count * per_count) {
                    values.push(read_varint(buf, &mut pos));
                }
                tag_map.insert(tag, IndexTag { values });
            }
            Ptagx::Bytes { tag, value_bytes } => {
                let mut count = 0u32;
                while count < value_bytes {
                    values.push(read_varint(buf, &mut pos));
                    count += 1;
                }
                tag_map.insert(tag, IndexTag { values });
            }
        }
    }

    Ok(IndexEntry { label, tag_map })
}

/// CNCX 字符串表读取器（对照 Kotlin：MobiBook.readCncx）
///
/// CNCX 键为"记录内偏移 + 记录序号 * 0x10000"。
struct CncxReader<'a> {
    book: &'a MobiBook,
    encoding: u32,
}

impl<'a> CncxReader<'a> {
    fn read(&self, indx_index: i64, num_records: usize, num_cncx: usize) -> HashMap<u32, String> {
        let mut cncx = HashMap::new();
        let mut cncx_record_offset: u32 = 0;
        for i in 0..num_cncx {
            let Ok(record) = self.book.record(indx_index + (num_records + i + 1) as i64) else {
                break;
            };
            let mut pos = 0usize;
            while pos < record.len() {
                let index = pos;
                let value = read_varint(record, &mut pos) as usize;
                if value == 0 || pos + value > record.len() {
                    break;
                }
                let s = decode_mobi_text(&record[pos..pos + value], self.encoding);
                pos += value;
                cncx.insert(cncx_record_offset + index as u32, s);
            }
            cncx_record_offset += 0x10000;
        }
        cncx
    }
}

/// 解析完整索引数据（根记录 + 子记录 + CNCX）
///
/// 对照 Kotlin：MobiBook.getIndexData
fn get_index_data(book: &MobiBook, indx_index: i64) -> LegadoResult<IndexData> {
    let root = book.record(indx_index)?.to_vec();
    let indx = read_indx_header(&root)?;
    if indx.length + 12 > root.len() {
        return Err(LegadoError::BookParse("INDX 头长度异常".into()));
    }
    let tagx_slice = &root[indx.length..];
    let tagx = read_tagx_header(tagx_slice)?;
    let tag_table = read_tagx_tags(&tagx, tagx_slice);

    let cncx = CncxReader {
        book,
        encoding: book.headers.mobi.encoding,
    }
    .read(indx_index, indx.num_records, indx.num_cncx);

    let mut table = Vec::new();
    for i in 0..indx.num_records {
        let rec = book.record(indx_index + 1 + i as i64)?;
        let hdr = read_indx_header(rec)?;
        // IDXT 表：num_records 个 u16 条目偏移
        let idxt_start = hdr.idxt + 4;
        if idxt_start + hdr.num_records * 2 > rec.len() {
            return Err(LegadoError::BookParse("IDXT 表越界".into()));
        }
        for j in 0..hdr.num_records {
            let idxt_offset = read_u16(rec, idxt_start + j * 2) as usize;
            let entry = read_index_entry(rec, &tagx, &tag_table, idxt_offset)?;
            table.push(entry);
        }
    }

    Ok(IndexData { table, cncx })
}

// ---------------------------------------------------------------------------
// NCX 目录树
// ---------------------------------------------------------------------------

/// NCX 目录项（对照 Kotlin：entities/NCX.kt，展平字段）
struct NcxItem {
    label: String,
    /// KF6：正文内字节偏移（tag 1）
    offset: Option<u32>,
    /// KF8：kindle:pos 定位（tag 4 = fid, tag 5 = off）
    pos: Option<(u32, u32)>,
    #[allow(dead_code)]
    heading_level: Option<u32>,
    children: Vec<NcxItem>,
}

/// 从 INDX 构建 NCX 目录树
///
/// 对照 Kotlin：MobiBook.getNCX
fn get_ncx(book: &MobiBook) -> Option<Vec<NcxItem>> {
    let indx_index = book.headers.mobi.indx;
    if indx_index < 0 {
        return None;
    }
    let data = get_index_data(book, indx_index).ok()?;
    if data.table.is_empty() {
        return None;
    }

    struct Flat {
        label: String,
        offset: Option<u32>,
        pos: Option<(u32, u32)>,
        heading_level: Option<u32>,
        parent: Option<u32>,
        first_child: Option<u32>,
    }

    let mut items: Vec<Flat> = Vec::with_capacity(data.table.len());
    for entry in &data.table {
        let label = entry
            .tag_map
            .get(&3)
            .and_then(|t| t.values.first())
            .and_then(|k| data.cncx.get(k))
            .cloned()
            .unwrap_or_else(|| entry.label.clone());
        let offset = entry.tag_map.get(&1).and_then(|t| t.values.first()).copied();
        let pos = match entry.tag_map.get(&4) {
            Some(t) if t.values.len() >= 2 => Some((t.values[0], t.values[1])),
            _ => None,
        };
        let heading_level = entry.tag_map.get(&21).and_then(|t| t.values.first()).copied();
        let parent = entry.tag_map.get(&22).and_then(|t| t.values.first()).copied();
        let first_child = entry.tag_map.get(&23).and_then(|t| t.values.first()).copied();
        items.push(Flat {
            label,
            offset,
            pos,
            heading_level,
            parent,
            first_child,
        });
    }

    // 按 parent 分组构建子节点列表
    let mut children_map: HashMap<u32, Vec<usize>> = HashMap::new();
    for (idx, item) in items.iter().enumerate() {
        if let Some(p) = item.parent {
            children_map.entry(p).or_default().push(idx);
        }
    }

    fn build(idx: usize, items: &[Flat], children_map: &HashMap<u32, Vec<usize>>) -> NcxItem {
        let item = &items[idx];
        let mut children = Vec::new();
        if item.first_child.is_some() {
            if let Some(kids) = children_map.get(&(idx as u32)) {
                for &k in kids {
                    children.push(build(k, items, children_map));
                }
            }
        }
        NcxItem {
            label: item.label.clone(),
            offset: item.offset,
            pos: item.pos,
            heading_level: item.heading_level,
            children,
        }
    }

    // 对照 Kotlin：getNCX 以 headingLevel == 0 为根
    let roots: Vec<NcxItem> = items
        .iter()
        .enumerate()
        .filter(|(_, it)| it.heading_level == Some(0))
        .map(|(idx, _)| build(idx, &items, &children_map))
        .collect();

    if roots.is_empty() {
        None
    } else {
        Some(roots)
    }
}

// ---------------------------------------------------------------------------
// KF8 (AZW3) 结构：Skeleton / Fragment / Section
// ---------------------------------------------------------------------------

/// 骨架（对照 Kotlin：entities/Skeleton.kt）
#[derive(Debug, Clone)]
struct Skeleton {
    num_frag: u32,
    offset: u32,
    length: u32,
}

/// 碎片（对照 Kotlin：entities/Fragment.kt）
#[derive(Debug, Clone)]
struct Fragment {
    /// 在骨架中的插入位置（正文绝对偏移）
    insert_offset: u32,
    /// 碎片编号（FID）
    index: u32,
    /// 在文本流中的偏移
    offset: u32,
    length: u32,
}

/// KF8 章节段（对照 Kotlin：entities/KF8Section.kt）
struct Kf8Section {
    skeleton: Skeleton,
    frags: Vec<Fragment>,
    length: usize,
    /// 线性段（含碎片）在拼装全文中的起始字节
    text_start: Option<usize>,
}

impl Kf8Section {
    /// 对照 Kotlin：KF8Section.linear
    fn linear(&self) -> bool {
        !self.frags.is_empty()
    }
}

/// 读取 Skeleton 表（对照 Kotlin：KF8Book.readSkelTable）
fn read_skel_table(book: &MobiBook, skel_indx: i64) -> LegadoResult<Vec<Skeleton>> {
    let data = get_index_data(book, skel_indx)?;
    let mut skels = Vec::with_capacity(data.table.len());
    for entry in &data.table {
        let tag1 = entry
            .tag_map
            .get(&1)
            .and_then(|t| t.values.first())
            .copied()
            .unwrap_or(0);
        let tag6 = entry.tag_map.get(&6).map(|t| t.values.clone()).unwrap_or_default();
        skels.push(Skeleton {
            num_frag: tag1,
            offset: tag6.first().copied().unwrap_or(0),
            length: tag6.get(1).copied().unwrap_or(0),
        });
    }
    Ok(skels)
}

/// 读取 Fragment 表（对照 Kotlin：KF8Book.readFragTable）
fn read_frag_table(book: &MobiBook, frag_indx: i64) -> LegadoResult<Vec<Fragment>> {
    let data = get_index_data(book, frag_indx)?;
    let mut frags = Vec::with_capacity(data.table.len());
    for entry in &data.table {
        let insert_offset: u32 = entry.label.parse().unwrap_or(0);
        let tag4 = entry
            .tag_map
            .get(&4)
            .and_then(|t| t.values.first())
            .copied()
            .unwrap_or(0);
        let tag6 = entry.tag_map.get(&6).map(|t| t.values.clone()).unwrap_or_default();
        frags.push(Fragment {
            insert_offset,
            index: tag4,
            offset: tag6.first().copied().unwrap_or(0),
            length: tag6.get(1).copied().unwrap_or(0),
        });
    }
    Ok(frags)
}

/// 构建 KF8 章节段（对照 Kotlin：KF8Book.processSections）
fn process_kf8_sections(skels: &[Skeleton], frags: &[Fragment]) -> Vec<Kf8Section> {
    let mut sections = Vec::with_capacity(skels.len());
    let mut frag_cursor = 0usize;
    for skel in skels {
        let frag_end = frag_cursor + skel.num_frag as usize;
        let section_frags: Vec<Fragment> = frags[frag_cursor..frag_end.min(frags.len())].to_vec();
        let length = skel.length as usize + section_frags.iter().map(|f| f.length as usize).sum::<usize>();
        frag_cursor = frag_end;
        sections.push(Kf8Section {
            skeleton: skel.clone(),
            frags: section_frags,
            length,
            text_start: None,
        });
    }
    sections
}

/// 拼装 KF8 完整正文（线性段按序合并，Skeleton 与 Fragment 交织还原）
///
/// 对照 Kotlin：KF8Book.getSectionText 的拼装算法，返回拼装全文
/// 以及每个线性段在全文中的起始偏移（写入 section.text_start）。
fn assemble_kf8_text(book: &MobiBook, sections: &mut [Kf8Section]) -> LegadoResult<Vec<u8>> {
    let total = book.total_text_len();
    let mut out: Vec<u8> = Vec::new();

    for section in sections.iter_mut() {
        if !section.linear() {
            // 非线性段（如资源/目录占位）不进入正文流
            section.text_start = None;
            continue;
        }
        section.text_start = Some(out.len());

        let skel = &section.skeleton;
        let start = skel.offset as usize;
        let len = section.length.min(total.saturating_sub(start));
        let raw = book.text_bytes(start, start + len)?;

        // 骨架在前
        let skel_len = (skel.length as usize).min(raw.len());
        let mut assembled = raw[..skel_len].to_vec();

        for frag in &section.frags {
            let insert = (frag.insert_offset as usize).saturating_sub(skel.offset as usize);
            let insert = insert.min(assembled.len());
            let src_start = skel_len + frag.offset as usize;
            let src_end = (src_start + frag.length as usize).min(raw.len());
            if src_start < src_end {
                let frag_bytes = raw[src_start..src_end].to_vec();
                assembled.splice(insert..insert, frag_bytes);
            }
        }
        out.extend_from_slice(&assembled);
    }
    Ok(out)
}

/// 读取 FDST 片段表（对照 Kotlin：KF8Book.readFdstTable）
///
/// FDST 记录正文在全文中的绝对区间，本实现采用 Section 拼装路线，
/// 仅做结构校验以保持格式兼容。
#[allow(dead_code)]
fn read_fdst_table(book: &MobiBook, fdst_index: i64) -> Option<(Vec<u32>, Vec<u32>)> {
    let rec = book.record(fdst_index).ok()?;
    if rec.len() < 12 || &rec[0..4] != b"FDST" {
        return None;
    }
    let num_entries = read_u32(rec, 8) as usize;
    if 12 + num_entries * 8 > rec.len() {
        return None;
    }
    let mut starts = Vec::with_capacity(num_entries);
    let mut ends = Vec::with_capacity(num_entries);
    for i in 0..num_entries {
        starts.push(read_u32(rec, 12 + i * 8));
        ends.push(read_u32(rec, 12 + i * 8 + 4));
    }
    Some((starts, ends))
}

/// 将整数编码为 base-32（对照 Kotlin：Int.toString(32)，用于 kindle:pos URI）
#[allow(dead_code)]
fn to_base32(mut n: u32) -> String {
    const DIGITS: &[u8; 32] = b"0123456789abcdefghijklmnopqrstuv";
    if n == 0 {
        return "0".to_string();
    }
    let mut s = Vec::new();
    while n > 0 {
        s.push(DIGITS[(n % 32) as usize]);
        n /= 32;
    }
    s.reverse();
    String::from_utf8(s).unwrap_or_default()
}

/// 解析 kindle:pos:fid:XXXX:off:YYYYYYY 定位（对照 Kotlin：KF8Book.parsePosURI）
#[allow(dead_code)]
fn parse_pos_uri(href: &str) -> Option<(u32, u32)> {
    let re = regex::Regex::new(r"kindle:pos:fid:([0-9A-Za-z]+):off:([0-9A-Za-z]+)").ok()?;
    let caps = re.captures(href)?;
    let fid = u32::from_str_radix(&caps[1], 32).ok()?;
    let off = u32::from_str_radix(&caps[2], 32).ok()?;
    Some((fid, off))
}

// ---------------------------------------------------------------------------
// 章节构建
// ---------------------------------------------------------------------------

/// KF6 分节正则（对照 Kotlin：KF6Book.mbpPagebreakRegex）
const MBP_PAGEBREAK_PATTERN: &str = r"(?i)<\s*(?:mbp:)?pagebreak[^>]*>";

/// 将 NCX 树展平为文档序列表
fn flatten_ncx<'a>(items: &'a [NcxItem], out: &mut Vec<&'a NcxItem>) {
    for item in items {
        out.push(item);
        flatten_ncx(&item.children, out);
    }
}

/// KF6（旧版 MOBI）章节：NCX 优先，退回 pagebreak 分节，再退回正则切分
fn chapters_kf6(book: &MobiBook) -> LegadoResult<Vec<ChapterInfo>> {
    let total = book.total_text_len() as i64;

    if let Some(ncx) = get_ncx(book) {
        let mut flat = Vec::new();
        flatten_ncx(&ncx, &mut flat);
        let mut chapters: Vec<ChapterInfo> = Vec::new();
        let mut idx = 0i32;
        for item in flat {
            if let Some(off) = item.offset {
                let start = i64::from(off).min(total);
                chapters.push(ChapterInfo {
                    url: format!("mobi://filepos/{off:010}"),
                    title: item.label.clone(),
                    index: idx,
                    is_volume: false,
                    start: Some(start),
                    end: None,
                });
                idx += 1;
            }
        }
        if !chapters.is_empty() {
            fill_chapter_ends(&mut chapters, total);
            return Ok(chapters);
        }
    }

    // 退回：按 <mbp:pagebreak/> 分节（对照 Kotlin：KF6Book.processSections，
    // 匹配位置为节边界，最后一个边界到文末构成末节）
    let bytes = book.full_text_bytes()?;
    let text = decode_mobi_text(&bytes, book.headers.mobi.encoding);
    let re = regex::Regex::new(MBP_PAGEBREAK_PATTERN).unwrap();
    if re.is_match(&text) {
        let mut starts: Vec<usize> = vec![0];
        for m in re.find_iter(&text) {
            starts.push(m.end());
        }
        let mut chapters = Vec::new();
        for (i, window) in starts.windows(2).enumerate() {
            // 字节边界按分段字符长度累加（UTF-8 下与字节一致）
            let start_byte: usize = text[..window[0]].len();
            let end_byte: usize = text[..window[1]].len();
            chapters.push(ChapterInfo {
                url: format!("mobi://section/{i}"),
                title: format!("章节 {}", i + 1),
                index: i as i32,
                is_volume: false,
                start: Some(start_byte as i64),
                end: Some(end_byte as i64),
            });
        }
        // 末节：最后一个边界 → 文末
        let last = *starts.last().unwrap();
        let last_byte: usize = text[..last].len();
        chapters.push(ChapterInfo {
            url: format!("mobi://section/{}", starts.len() - 1),
            title: format!("章节 {}", starts.len()),
            index: (starts.len() - 1) as i32,
            is_volume: false,
            start: Some(last_byte as i64),
            end: Some(bytes.len() as i64),
        });
        return Ok(chapters);
    }

    // 最后退回：中文/英文章节标题正则切分
    Ok(split_into_chapters(&text))
}

/// KF8（AZW3）章节：NCX 优先（kindle:pos 定位），退回 Skeleton 分段
fn chapters_kf8(book: &MobiBook, kf8: &Kf8Header) -> LegadoResult<Vec<ChapterInfo>> {
    if kf8.skel < 0 {
        // 无骨架索引：退回正则切分
        let bytes = book.full_text_bytes()?;
        let text = decode_mobi_text(&bytes, book.headers.mobi.encoding);
        return Ok(split_into_chapters(&text));
    }

    let skels = read_skel_table(book, kf8.skel)?;
    let frags = if kf8.frag >= 0 {
        read_frag_table(book, kf8.frag).unwrap_or_default()
    } else {
        Vec::new()
    };
    let mut sections = process_kf8_sections(&skels, &frags);
    let full = assemble_kf8_text(book, &mut sections)?;
    let total = full.len() as i64;

    // NCX 优先
    if let Some(ncx) = get_ncx(book) {
        let mut flat = Vec::new();
        flatten_ncx(&ncx, &mut flat);
        let mut chapters = Vec::new();
        let mut idx = 0i32;
        for item in &flat {
            let Some((fid, off)) = item.pos else { continue };
            // fid → section → 全文偏移
            let Some(sec) = sections.iter().find(|s| s.linear() && s.frags.iter().any(|f| f.index == fid)) else {
                continue;
            };
            let Some(text_start) = sec.text_start else { continue };
            let start = (text_start as i64 + i64::from(off)).min(total);
            let fid_s = format!("{:0>4}", to_base32(fid));
            let off_s = format!("{:0>10}", to_base32(off));
            chapters.push(ChapterInfo {
                url: format!("kindle:pos:fid:{fid_s}:off:{off_s}"),
                title: item.label.clone(),
                index: idx,
                is_volume: false,
                start: Some(start),
                end: None,
            });
            idx += 1;
        }
        if !chapters.is_empty() {
            fill_chapter_ends(&mut chapters, total);
            return Ok(chapters);
        }
    }

    // 退回：线性 Skeleton 段作为章节
    let mut chapters = Vec::new();
    let mut idx = 0i32;
    for (i, sec) in sections.iter().enumerate() {
        if let Some(start) = sec.text_start {
            let end = (start + sec.length).min(total as usize);
            chapters.push(ChapterInfo {
                url: format!("mobi://kf8section/{i}"),
                title: format!("章节 {}", idx + 1),
                index: idx,
                is_volume: false,
                start: Some(start as i64),
                end: Some(end as i64),
            });
            idx += 1;
        }
    }
    if chapters.is_empty() {
        chapters.push(ChapterInfo {
            url: "mobi://chapter/0".to_string(),
            title: "全文".to_string(),
            index: 0,
            is_volume: false,
            start: Some(0),
            end: Some(total),
        });
    }
    Ok(chapters)
}

/// 回填章节 end 偏移
fn fill_chapter_ends(chapters: &mut [ChapterInfo], total: i64) {
    for i in 0..chapters.len() {
        let next = if i + 1 < chapters.len() {
            chapters[i + 1].start.unwrap_or(total)
        } else {
            total
        };
        chapters[i].end = Some(next.max(chapters[i].start.unwrap_or(0)));
    }
}

/// HTML/XHTML → 纯文本（MOBI 正文均为 HTML 片段）
fn html_to_text(html: &str) -> String {
    let re_script = regex::Regex::new(r"(?is)<script[^>]*>.*?</script>").unwrap();
    let re_style = regex::Regex::new(r"(?is)<style[^>]*>.*?</style>").unwrap();
    let mut text = re_script.replace_all(html, "").to_string();
    text = re_style.replace_all(&text, "").to_string();

    let re_block = regex::Regex::new(r"(?i)</?(p|div|h[1-6]|br|hr|li|tr|blockquote|title)[^>]*>").unwrap();
    text = re_block.replace_all(&text, "\n").to_string();

    let re_tag = regex::Regex::new(r"<[^>]+>").unwrap();
    text = re_tag.replace_all(&text, "").to_string();

    text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");

    // 数字实体（&#NNN; / &#xHH;）
    let re_num = regex::Regex::new(r"&#(x?)([0-9A-Fa-f]+);").unwrap();
    text = re_num
        .replace_all(&text, |caps: &regex::Captures| {
            let radix = if &caps[1] == "x" { 16 } else { 10 };
            u32::from_str_radix(&caps[2], radix)
                .ok()
                .and_then(char::from_u32)
                .map(|c| c.to_string())
                .unwrap_or_default()
        })
        .to_string();

    let re_multi_nl = regex::Regex::new(r"\n{3,}").unwrap();
    text = re_multi_nl.replace_all(&text, "\n\n").to_string();
    text.trim().to_string()
}

/// 按正则检测章节标题将文本分割为章节（无结构 MOBI 的兜底方案）
fn split_into_chapters(text: &str) -> Vec<ChapterInfo> {
    let re = regex::Regex::new(
        r"(?m)^\s{0,4}(?:第[零一二三四五六七八九十百千万\d]+[章回节卷集部篇话]|Chapter\s+\d+).*$",
    )
    .unwrap();

    let mut chapters = Vec::new();
    let mut idx = 0i32;
    let mut byte_offset: i64 = 0;

    for line in text.lines() {
        let line_byte_len = line.len() as i64 + 1;
        if re.is_match(line) {
            let title = line.trim().to_string();
            if !title.is_empty() {
                chapters.push(ChapterInfo {
                    url: format!("mobi://chapter/{idx}"),
                    title,
                    index: idx,
                    is_volume: false,
                    start: Some(byte_offset),
                    end: None,
                });
                idx += 1;
            }
        }
        byte_offset += line_byte_len;
    }

    let total = text.len() as i64;
    fill_chapter_ends(&mut chapters, total);

    // 无章节时整文件作为一章
    if chapters.is_empty() {
        chapters.push(ChapterInfo {
            url: "mobi://chapter/0".to_string(),
            title: "全文".to_string(),
            index: 0,
            is_volume: false,
            start: Some(0),
            end: Some(total),
        });
    }

    chapters
}

// ---------------------------------------------------------------------------
// 公开接口
// ---------------------------------------------------------------------------

impl MobiParser {
    /// 解析 MOBI/AZW3 文件元数据（含封面提取）
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let book = MobiBook::open(path)?;

        let exth = &book.headers.exth;
        let mobi = &book.headers.mobi;
        let title = exth
            .title
            .clone()
            .filter(|t| !t.is_empty())
            .unwrap_or_else(|| {
                if !mobi.title.is_empty() {
                    mobi.title.clone()
                } else {
                    book.records.name.clone()
                }
            });
        let author = exth.creator.clone().unwrap_or_default();
        let description = exth.description.clone().unwrap_or_default();
        let cover = book.get_cover();

        Ok(BookMetadata {
            title,
            author,
            description,
            format: BookFormat::Mobi,
            cover,
        })
    }

    /// 获取章节列表（NCX / INDX 结构优先，正则切分兜底）
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let book = MobiBook::open(path)?;
        if let Some(kf8) = book.headers.kf8 {
            chapters_kf8(&book, &kf8)
        } else {
            chapters_kf6(&book)
        }
    }

    /// 获取章节正文内容（HTML → 纯文本）
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let book = MobiBook::open(path)?;

        let html = if let Some(kf8) = book.headers.kf8 {
            // KF8：拼装全文后按偏移切片
            if kf8.skel < 0 {
                let bytes = book.full_text_bytes()?;
                decode_mobi_text(&bytes, book.headers.mobi.encoding)
            } else {
                let skels = read_skel_table(&book, kf8.skel)?;
                let frags = if kf8.frag >= 0 {
                    read_frag_table(&book, kf8.frag).unwrap_or_default()
                } else {
                    Vec::new()
                };
                let mut sections = process_kf8_sections(&skels, &frags);
                let full = assemble_kf8_text(&book, &mut sections)?;
                decode_mobi_text(&full, book.headers.mobi.encoding)
            }
        } else {
            // KF6：按记录级字节区间提取
            let bytes = book.full_text_bytes()?;
            decode_mobi_text(&bytes, book.headers.mobi.encoding)
        };

        // start/end 为拼装文本的字节偏移
        let start = chapter.start.unwrap_or(0) as usize;
        let end = chapter.end.unwrap_or(html.len() as i64) as usize;

        // 按 UTF-8 字符边界安全切片
        let start = clamp_char_boundary(&html, start);
        let end = clamp_char_boundary(&html, end.max(start));

        Ok(html_to_text(&html[start..end]))
    }
}

/// 将字节偏移收敛到 UTF-8 字符边界
fn clamp_char_boundary(s: &str, mut pos: usize) -> usize {
    if pos >= s.len() {
        return s.len();
    }
    while pos > 0 && !s.is_char_boundary(pos) {
        pos -= 1;
    }
    pos
}

// ---------------------------------------------------------------------------
// 单元测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as IoWrite;
    use std::path::PathBuf;

    // ---- 基础解压/解码测试 ----

    #[test]
    fn test_palmdoc_decompress_literal() {
        // 字节 9..=0x7F 为字面量
        let input = vec![b'H', b'e', b'l', b'l', b'o'];
        let output = palmdoc_decompress(&input);
        assert_eq!(output, b"Hello");
    }

    #[test]
    fn test_palmdoc_decompress_space_prefix() {
        // 0xC0..=0xFF: 空格 + (c ^ 0x80)
        let input = vec![0xC0 | b'a']; // 0xE1 -> ' ' + 'a'
        let output = palmdoc_decompress(&input);
        assert_eq!(output, b" a");
    }

    #[test]
    fn test_palmdoc_decompress_copy_literal() {
        // 1..=8: 复制后续 N 个字面字节
        let input = vec![3, b'A', b'B', b'C'];
        let output = palmdoc_decompress(&input);
        assert_eq!(output, b"ABC");
    }

    #[test]
    fn test_palmdoc_decompress_null() {
        let input = vec![0u8];
        let output = palmdoc_decompress(&input);
        assert_eq!(output, vec![0u8]);
    }

    #[test]
    fn test_decode_mobi_text_utf8() {
        let bytes = "你好世界".as_bytes();
        let text = decode_mobi_text(bytes, 65001);
        assert_eq!(text, "你好世界");
    }

    #[test]
    fn test_decode_mobi_text_default() {
        let bytes = b"Hello";
        let text = decode_mobi_text(bytes, 1252);
        assert_eq!(text, "Hello");
    }

    #[test]
    fn test_split_into_chapters_with_titles() {
        let text = "第一章 开始\n内容一\n第二章 继续\n内容二\n";
        let chapters = split_into_chapters(text);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "第一章 开始");
        assert_eq!(chapters[1].title, "第二章 继续");
        assert!(chapters[0].start.unwrap() < chapters[1].start.unwrap());
    }

    #[test]
    fn test_split_into_chapters_english() {
        let text = "Chapter 1\nContent here\nChapter 2\nMore content\n";
        let chapters = split_into_chapters(text);
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "Chapter 1");
        assert_eq!(chapters[1].title, "Chapter 2");
    }

    #[test]
    fn test_split_into_chapters_no_match() {
        let text = "没有章节标题的纯文本\n只有内容\n";
        let chapters = split_into_chapters(text);
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "全文");
        assert_eq!(chapters[0].start, Some(0));
    }

    #[test]
    fn test_exth_constants() {
        assert_eq!(EXTH_CREATOR, 100);
        assert_eq!(EXTH_DESCRIPTION, 103);
        assert_eq!(EXTH_COVER_OFFSET, 201);
        assert_eq!(EXTH_BOUNDARY, 121);
    }

    #[test]
    fn test_remove_trailing_multibyte() {
        // trailingFlags=1（multibyte）：尾字节低 2 位 + 1 为附加长度
        let data = vec![b'A', b'B', b'C', 0x02]; // (2 & 3) + 1 = 3 字节附加
        let out = remove_trailing_entries(&data, 1);
        assert_eq!(out, vec![b'A']);
    }

    #[test]
    fn test_remove_trailing_none() {
        let data = vec![b'A', b'B'];
        assert_eq!(remove_trailing_entries(&data, 0), data);
    }

    #[test]
    fn test_varint() {
        // 单字节：0x88 = 8（最高位为结束标志）
        let mut pos = 0;
        assert_eq!(read_varint(&[0x88], &mut pos), 8);
        // 多字节：0x01 0x82 = (1<<7) | 2 = 130
        let mut pos = 0;
        assert_eq!(read_varint(&[0x01, 0x82], &mut pos), 130);
    }

    #[test]
    fn test_parse_pos_uri_and_base32() {
        assert_eq!(to_base32(0), "0");
        assert_eq!(to_base32(31), "v");
        assert_eq!(to_base32(32), "10");
        let (fid, off) = parse_pos_uri("kindle:pos:fid:0001:off:000000000a").unwrap();
        assert_eq!(fid, 1);
        assert_eq!(off, 10);
    }

    #[test]
    fn test_html_to_text() {
        let html = "<html><body><p>段落一</p><br/>段落二&nbsp;&amp;</body></html>";
        let text = html_to_text(html);
        assert!(text.contains("段落一"));
        assert!(text.contains("段落二 &"));
        assert!(!text.contains('<'));
    }

    // ---- PDB / MOBI 构造辅助 ----

    fn w16(buf: &mut [u8], pos: usize, v: u16) {
        buf[pos..pos + 2].copy_from_slice(&v.to_be_bytes());
    }

    fn w32(buf: &mut [u8], pos: usize, v: u32) {
        buf[pos..pos + 4].copy_from_slice(&v.to_be_bytes());
    }

    /// 构建最小 PDB 文件字节
    fn build_pdb(records: &[Vec<u8>]) -> Vec<u8> {
        let n = records.len();
        let mut offsets = Vec::with_capacity(n);
        let mut cur = 78u32 + (n as u32) * 8 + 2;
        for r in records {
            offsets.push(cur);
            cur += r.len() as u32;
        }
        let mut out = vec![0u8; 78];
        out[0..8].copy_from_slice(b"TestBook");
        w16(&mut out, 76, n as u16);
        for off in &offsets {
            out.extend_from_slice(&off.to_be_bytes());
            out.extend_from_slice(&[0u8; 4]);
        }
        out.extend_from_slice(&[0u8, 0u8]); // gap
        for r in records {
            out.extend_from_slice(r);
        }
        out
    }

    /// Record 0 构造参数
    struct Rec0Spec {
        compression: u16,
        num_records: u16,
        record_size: u16,
        version: u32,
        encoding: u32,
        trailing: u32,
        indx: u32,
        resource_start: u32,
        huffcdic: u32,
        num_huffcdic: u32,
        name: String,
        exth_records: Vec<(u32, Vec<u8>)>,
        /// (fdst, num_fdst, frag, skel, guide)
        kf8: Option<(u32, u32, u32, u32, u32)>,
    }

    impl Default for Rec0Spec {
        fn default() -> Self {
            Rec0Spec {
                compression: 1,
                num_records: 1,
                record_size: 4096,
                version: 6,
                encoding: 65001,
                trailing: 0,
                indx: u32::MAX,
                resource_start: u32::MAX,
                huffcdic: u32::MAX,
                num_huffcdic: 0,
                name: String::new(),
                exth_records: Vec::new(),
                kf8: None,
            }
        }
    }

    fn build_exth(records: &[(u32, Vec<u8>)]) -> Vec<u8> {
        if records.is_empty() {
            return Vec::new();
        }
        let body: usize = records.iter().map(|(_, d)| 8 + d.len()).sum();
        let len = 12 + body;
        let mut out = Vec::new();
        out.extend_from_slice(b"EXTH");
        out.extend_from_slice(&(len as u32).to_be_bytes());
        out.extend_from_slice(&(records.len() as u32).to_be_bytes());
        for (t, d) in records {
            out.extend_from_slice(&t.to_be_bytes());
            out.extend_from_slice(&((8 + d.len()) as u32).to_be_bytes());
            out.extend_from_slice(d);
        }
        out
    }

    /// 构建 Record 0（PalmDoc 头 + MOBI 头 264 字节 + EXTH + 书名）
    fn build_rec0(spec: &Rec0Spec) -> Vec<u8> {
        let header_len = 264u32;
        let mut rec = vec![0u8; 16 + header_len as usize];
        w16(&mut rec, 0, spec.compression);
        w16(&mut rec, 8, spec.num_records);
        w16(&mut rec, 10, spec.record_size);
        rec[16..20].copy_from_slice(b"MOBI");
        w32(&mut rec, 20, header_len);
        w32(&mut rec, 24, 2); // type = MOBIbook
        w32(&mut rec, 28, spec.encoding);
        w32(&mut rec, 36, spec.version);
        let exth_block = build_exth(&spec.exth_records);
        let name_offset = 16 + header_len as usize + exth_block.len();
        w32(&mut rec, 84, name_offset as u32);
        w32(&mut rec, 88, spec.name.len() as u32);
        w32(&mut rec, 108, spec.resource_start);
        w32(&mut rec, 112, spec.huffcdic);
        w32(&mut rec, 116, spec.num_huffcdic);
        if !spec.exth_records.is_empty() {
            w32(&mut rec, 128, 0x40); // exthFlag
        }
        w32(&mut rec, 240, spec.trailing);
        w32(&mut rec, 244, spec.indx);
        if let Some((fdst, nf, frag, skel, guide)) = spec.kf8 {
            w32(&mut rec, 192, fdst);
            w32(&mut rec, 196, nf);
            w32(&mut rec, 248, frag);
            w32(&mut rec, 252, skel);
            w32(&mut rec, 260, guide);
        }
        rec.extend_from_slice(&exth_block);
        rec.extend_from_slice(spec.name.as_bytes());
        rec
    }

    /// 将 PDB 字节写入临时文件
    fn write_temp(name: &str, data: &[u8]) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("legado_mobi_test_{name}"));
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(data).unwrap();
        path
    }

    // ---- HUFF/CDIC 解码测试 ----

    /// 构建最小 HUFF + CDIC 记录对：单符号字典，码长 1，码字 0
    fn build_huff_cdic_records() -> (Vec<u8>, Vec<u8>) {
        let offset1 = 16u32;
        let offset2 = 16 + 256 * 4; // table2 紧随 table1
        let mut huff = vec![0u8; 16];
        huff[0..4].copy_from_slice(b"HUFF");
        w32(&mut huff, 4, 16);
        w32(&mut huff, 8, offset1);
        w32(&mut huff, 12, offset2);
        // table1[0]：codelen=1，maxcode=0，bit7 清零（走 mincode 分支）
        for i in 0..256 {
            huff.extend_from_slice(&0u32.to_be_bytes());
            let _ = i;
        }
        w32(&mut huff, 16, 1); // table1[0] = 1
        // table2：32 对 (mincode, maxcode)，码长 1 为 (0,0)
        for _ in 0..32 {
            huff.extend_from_slice(&0u32.to_be_bytes());
            huff.extend_from_slice(&0u32.to_be_bytes());
        }

        // CDIC：1 个已解压条目 'a'（指针偏移相对头后数据区）
        let mut cdic = vec![0u8; 16];
        cdic[0..4].copy_from_slice(b"CDIC");
        w32(&mut cdic, 4, 16); // 头长度（指针表起点）
        w32(&mut cdic, 8, 1); // numEntries
        w32(&mut cdic, 12, 0); // codeLength → n = min(1, 1) = 1
        cdic.extend_from_slice(&2u16.to_be_bytes()); // 指针 → 数据区偏移 2（指针表后）
        cdic.extend_from_slice(&0x8001u16.to_be_bytes()); // len=1, decompressed=1
        cdic.push(b'a');
        (huff, cdic)
    }

    #[test]
    fn test_huffcdic_decompress_basic() {
        // 全零比特流：每次解码 1 位 → 字典条目 0（'a'）
        // 8 字节 = 64 位 → 输出 64 个 'a'（最后一位耗尽后退出）
        let (huff, cdic) = build_huff_cdic_records();
        let spec = Rec0Spec {
            compression: 17480,
            num_records: 1,
            huffcdic: 2,
            num_huffcdic: 2,
            ..Default::default()
        };
        let data = vec![0u8; 8];
        let pdb = build_pdb(&[build_rec0(&spec), data, huff, cdic]);
        let path = write_temp("huff_basic.mobi", &pdb);
        let book = MobiBook::open(path.to_str().unwrap()).unwrap();
        let text = book.full_text_bytes().unwrap();
        assert_eq!(text.len(), 64);
        assert!(text.iter().all(|&b| b == b'a'));
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_huffcdic_decompress_nested() {
        // 合法嵌套：字典条目 1 未解压，其内容是解码到条目 0（'a'）的 HUFF 流。
        // 码表设计（快路径，t1=0x181 → codelen=1、maxcode=0xFFFFFFFF）：
        //   比特 0 → code=0        → index=(0xFFFFFFFF-0)>>31=1 → 条目 1（嵌套）
        //   比特 1 → code=0xFF…F   → index=(0xFFFFFFFF-code)>>31=0 → 条目 0（'a'）
        let offset1 = 16u32;
        let offset2 = 16 + 256 * 4;
        let mut huff = vec![0u8; 16];
        huff[0..4].copy_from_slice(b"HUFF");
        w32(&mut huff, 4, 16);
        w32(&mut huff, 8, offset1);
        w32(&mut huff, 12, offset2);
        for _ in 0..256 {
            huff.extend_from_slice(&0x181u32.to_be_bytes());
        }
        for _ in 0..32 {
            huff.extend_from_slice(&0u32.to_be_bytes());
            huff.extend_from_slice(&0u32.to_be_bytes());
        }

        // CDIC：codeLength=1 → n=2 条目
        // 条目 0：已解压 'a'；条目 1：未解压，数据为 8 字节全 1 流（解码成 64 个 'a'）
        let mut cdic = vec![0u8; 16];
        cdic[0..4].copy_from_slice(b"CDIC");
        w32(&mut cdic, 4, 16); // 头长度
        w32(&mut cdic, 8, 2); // numEntries
        w32(&mut cdic, 12, 1); // codeLength → n = min(2, 2) = 2
        // 指针表（相对数据区）：条目 0 在偏移 4，条目 1 在偏移 7
        cdic.extend_from_slice(&4u16.to_be_bytes());
        cdic.extend_from_slice(&7u16.to_be_bytes());
        cdic.extend_from_slice(&0x8001u16.to_be_bytes()); // len=1, decompressed=1
        cdic.push(b'a');
        cdic.extend_from_slice(&0x0008u16.to_be_bytes()); // len=8, decompressed=0
        cdic.extend_from_slice(&[0xFFu8; 8]);

        let spec = Rec0Spec {
            compression: 17480,
            num_records: 1,
            huffcdic: 2,
            num_huffcdic: 2,
            ..Default::default()
        };
        // 外层：4 字节全 0 = 32 个比特 0 → 32 次命中条目 1（首次递归展开后缓存）
        let data = vec![0u8; 4];
        let pdb = build_pdb(&[build_rec0(&spec), data, huff, cdic]);
        let path = write_temp("huff_nested.mobi", &pdb);
        let book = MobiBook::open(path.to_str().unwrap()).unwrap();
        let text = book.full_text_bytes().unwrap();
        assert_eq!(text.len(), 32 * 64);
        assert!(text.iter().all(|&b| b == b'a'));
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_huffcdic_self_reference_guard() {
        // 自引用字典条目（条目解码后仍命中自身）：Kotlin 原版无限递归栈溢出，
        // Rust 版以深度护栏受控报错。
        let (huff, mut cdic) = build_huff_cdic_records();
        // 重写 CDIC 条目：未解压，数据为全零流（解码后仍命中条目 0）
        cdic.truncate(16);
        cdic.extend_from_slice(&2u16.to_be_bytes());
        cdic.extend_from_slice(&0x0008u16.to_be_bytes()); // len=8, decompressed=0
        cdic.extend_from_slice(&[0u8; 8]);

        let spec = Rec0Spec {
            compression: 17480,
            num_records: 1,
            huffcdic: 2,
            num_huffcdic: 2,
            ..Default::default()
        };
        let data = vec![0u8; 4];
        let pdb = build_pdb(&[build_rec0(&spec), data, huff, cdic]);
        let path = write_temp("huff_selfref.mobi", &pdb);
        // 错误可能在 open（预计算文本偏移）或解压阶段报出，两者均可接受
        let res = MobiBook::open(path.to_str().unwrap())
            .and_then(|b| b.full_text_bytes());
        let err = res.unwrap_err();
        let msg = format!("{err}");
        assert!(msg.contains("嵌套"), "应为深度护栏报错，实际: {msg}");
        std::fs::remove_file(&path).ok();
    }

    // ---- KF6 端到端测试（pagebreak 分节 + 封面） ----

    #[test]
    fn test_kf6_pagebreak_chapters_and_cover() {
        let spec = Rec0Spec {
            compression: 1,
            num_records: 1,
            resource_start: 2,
            name: "KF6 测试书".into(),
            exth_records: vec![
                (EXTH_CREATOR, "测试作者".as_bytes().to_vec()),
                (EXTH_DESCRIPTION, "测试简介".as_bytes().to_vec()),
                (EXTH_COVER_OFFSET, 0u32.to_be_bytes().to_vec()),
            ],
            ..Default::default()
        };
        let text = b"AAA<mbp:pagebreak/>BBB".to_vec();
        let cover = vec![0xFFu8, 0xD8, 0xFF, 0xE0];
        let pdb = build_pdb(&[build_rec0(&spec), text, cover.clone()]);
        let path = write_temp("kf6_pagebreak.mobi", &pdb);
        let path_str = path.to_str().unwrap();

        // 元数据
        let meta = MobiParser::parse(path_str).unwrap();
        assert_eq!(meta.title, "KF6 测试书");
        assert_eq!(meta.author, "测试作者");
        assert_eq!(meta.description, "测试简介");
        assert_eq!(meta.cover.as_deref(), Some(&cover[..]));

        // 章节：pagebreak 切出 2 节
        let chapters = MobiParser::get_chapters(path_str).unwrap();
        assert_eq!(chapters.len(), 2);

        // 正文
        let c0 = MobiParser::get_chapter_content(path_str, &chapters[0]).unwrap();
        let c1 = MobiParser::get_chapter_content(path_str, &chapters[1]).unwrap();
        assert_eq!(c0, "AAA");
        assert_eq!(c1, "BBB");

        std::fs::remove_file(&path).ok();
    }

    // ---- INDX / TAGX 构造辅助 ----

    /// 构建 INDX 根记录（头 + TAGX）
    fn build_indx_root(
        tag_defs: &[(u8, u8, u8, u8)],
        num_records: u32,
        num_cncx: u32,
        num_control_bytes: u32,
    ) -> Vec<u8> {
        let header_len = 60usize;
        let mut rec = vec![0u8; header_len];
        rec[0..4].copy_from_slice(b"INDX");
        w32(&mut rec, 4, header_len as u32); // length
        w32(&mut rec, 24, num_records);
        w32(&mut rec, 52, num_cncx);
        // TAGX
        let tagx_len = 12 + tag_defs.len() * 4;
        rec.extend_from_slice(b"TAGX");
        rec.extend_from_slice(&(tagx_len as u32).to_be_bytes());
        rec.extend_from_slice(&num_control_bytes.to_be_bytes());
        for (tag, num_values, bitmask, control) in tag_defs {
            rec.push(*tag);
            rec.push(*num_values);
            rec.push(*bitmask);
            rec.push(*control);
        }
        rec
    }

    /// 构建 INDX 子记录（头 + IDXT + 条目）
    fn build_indx_child(entries: &[Vec<u8>]) -> Vec<u8> {
        let header_len = 60usize;
        let mut rec = vec![0u8; header_len];
        rec[0..4].copy_from_slice(b"INDX");
        w32(&mut rec, 4, header_len as u32);
        w32(&mut rec, 20, header_len as u32); // idxt
        w32(&mut rec, 24, entries.len() as u32);
        // IDXT 块
        rec.extend_from_slice(b"IDXT");
        let mut entry_offset = header_len + 4 + entries.len() * 2;
        for e in entries {
            rec.extend_from_slice(&(entry_offset as u16).to_be_bytes());
            entry_offset += e.len();
        }
        for e in entries {
            rec.extend_from_slice(e);
        }
        rec
    }

    /// 构建 CNCX 记录（变长前缀字符串序列）
    fn build_cncx(strings: &[&str]) -> Vec<u8> {
        let mut rec = Vec::new();
        for s in strings {
            let b = s.as_bytes();
            assert!(b.len() < 128);
            rec.push(0x80 | b.len() as u8);
            rec.extend_from_slice(b);
        }
        rec
    }

    // ---- KF6 + NCX 目录测试 ----

    #[test]
    fn test_kf6_ncx_chapters() {
        // 文本 12 字节，NCX 指向 offset=5
        let spec = Rec0Spec {
            compression: 1,
            num_records: 1,
            indx: 2,
            resource_start: 5,
            name: "NCX 测试".into(),
            exth_records: vec![(EXTH_COVER_OFFSET, 0u32.to_be_bytes().to_vec())],
            ..Default::default()
        };
        // TAGX：tag1(offset) / tag3(label cncx 键) / tag21(headingLevel)，1 个控制字节
        let root = build_indx_root(
            &[(1, 1, 0x01, 0), (3, 1, 0x02, 0), (21, 1, 0x04, 0)],
            1,
            1,
            1,
        );
        // 条目：label "A"；控制字节 0x07（tag1/tag3/tag21 均置位），
        // 数据区：tag1=5，tag3=0，tag21=0
        let entry = vec![0x01, b'A', 0x07, 0x85, 0x80, 0x80];
        let child = build_indx_child(&[entry]);
        let cncx = build_cncx(&["Chapter1"]);
        let text = b"Hello World!".to_vec();
        let cover = vec![1u8, 2, 3];

        let pdb = build_pdb(&[
            build_rec0(&spec),
            text,
            root,
            child,
            cncx,
            cover.clone(),
        ]);
        let path = write_temp("kf6_ncx.mobi", &pdb);
        let path_str = path.to_str().unwrap();

        // IndexData 直接校验
        let book = MobiBook::open(path_str).unwrap();
        let data = get_index_data(&book, 2).unwrap();
        assert_eq!(data.table.len(), 1);
        assert_eq!(data.table[0].label, "A");
        assert_eq!(data.table[0].tag_map.get(&1).unwrap().values, vec![5]);
        assert_eq!(data.cncx.get(&0).unwrap(), "Chapter1");

        // 章节来自 NCX
        let chapters = MobiParser::get_chapters(path_str).unwrap();
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "Chapter1");
        assert_eq!(chapters[0].start, Some(5));

        // 内容从 offset 5 开始
        let content = MobiParser::get_chapter_content(path_str, &chapters[0]).unwrap();
        assert_eq!(content, "World!");

        // 封面
        let meta = MobiParser::parse(path_str).unwrap();
        assert_eq!(meta.cover.as_deref(), Some(&cover[..]));

        std::fs::remove_file(&path).ok();
    }

    // ---- KF8 (AZW3) 双格式端到端测试 ----

    #[test]
    fn test_kf8_dual_format_assembly() {
        // KF6 rec0：EXTH boundary=1 指向 KF8 头
        let kf6_spec = Rec0Spec {
            compression: 1,
            num_records: 0,
            resource_start: 7,
            name: "KF6 层".into(),
            exth_records: vec![(EXTH_BOUNDARY, 1u32.to_be_bytes().to_vec())],
            ..Default::default()
        };
        // KF8 rec0：skel 索引 = 2（相对分界记录，绝对 3），frag 索引 = 4（绝对 5）
        let kf8_spec = Rec0Spec {
            compression: 1,
            num_records: 1,
            version: 8,
            resource_start: 2,
            name: "KF8 测试书".into(),
            exth_records: vec![(EXTH_CREATOR, "KF8 作者".as_bytes().to_vec())],
            kf8: Some((u32::MAX, 1, 4, 2, u32::MAX)),
            ..Default::default()
        };

        // 文本流：骨架 14 字节 + 碎片 8 字节 + 尾部 7 字节
        // 骨架 "<html>SKELHEAD"，碎片 "FRAGTAIL" 插入到绝对偏移 6
        let text = b"<html>SKELHEADFRAGTAIL</html>".to_vec();

        // Skeleton 索引：tag1(numFrag) / tag6(offset,length)，1 个控制字节
        let skel_root = build_indx_root(&[(1, 1, 0x01, 0), (6, 2, 0x02, 0)], 1, 0, 1);
        // 条目：label "s1"；控制字节 0x03；数据区：tag1=1，tag6=[0, 14]
        let skel_entry = vec![0x02, b's', b'1', 0x03, 0x81, 0x80, 0x8E];
        let skel_child = build_indx_child(&[skel_entry]);

        // Fragment 索引：tag4(index) / tag6(offset,length)
        let frag_root = build_indx_root(&[(4, 1, 0x01, 0), (6, 2, 0x02, 0)], 1, 0, 1);
        // 条目：label "6"（insertOffset）；控制字节 0x03；数据区：tag4=0，tag6=[0, 8]
        // （tag6[0] 为碎片在段内 raw 中相对骨架末尾的偏移，对照 Kotlin getSectionText）
        let frag_entry = vec![0x01, b'6', 0x03, 0x80, 0x80, 0x88];
        let frag_child = build_indx_child(&[frag_entry]);

        let pdb = build_pdb(&[
            build_rec0(&kf6_spec), // 0: KF6 头
            build_rec0(&kf8_spec), // 1: KF8 头（boundary）
            text,                  // 2: 文本记录（相对 KF8 分界为 record 1）
            skel_root,             // 3
            skel_child,            // 4
            frag_root,             // 5
            frag_child,            // 6
        ]);
        let path = write_temp("kf8_dual.mobi", &pdb);
        let path_str = path.to_str().unwrap();

        // 元数据：双格式时书名/作者取自 KF8 部分
        let meta = MobiParser::parse(path_str).unwrap();
        assert_eq!(meta.title, "KF8 测试书");
        assert_eq!(meta.author, "KF8 作者");

        // 章节：无 NCX → 骨架段兜底，1 章
        let chapters = MobiParser::get_chapters(path_str).unwrap();
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].start, Some(0));

        // 正文：碎片插入骨架 → "<html>FRAGTAILSKELHEAD</html>" → 纯文本
        let content = MobiParser::get_chapter_content(path_str, &chapters[0]).unwrap();
        assert_eq!(content, "FRAGTAILSKELHEAD");

        std::fs::remove_file(&path).ok();
    }

    // ---- KF8 + NCX（kindle:pos 定位）测试 ----

    #[test]
    fn test_kf8_ncx_chapters() {
        let kf6_spec = Rec0Spec {
            compression: 1,
            num_records: 0,
            encoding: 65001,
            resource_start: 9,
            name: "KF6".into(),
            exth_records: vec![(EXTH_BOUNDARY, 1u32.to_be_bytes().to_vec())],
            ..Default::default()
        };
        // KF8：indx(NCX)=6（相对，绝对 7），skel=2，frag=4
        let kf8_spec = Rec0Spec {
            compression: 1,
            num_records: 1,
            version: 8,
            encoding: 65001,
            indx: 6,
            resource_start: 2,
            name: "KF8NCX".into(),
            kf8: Some((u32::MAX, 1, 4, 2, u32::MAX)),
            ..Default::default()
        };

        let text = b"<html>SKELHEADFRAGTAIL</html>".to_vec();

        let skel_root = build_indx_root(&[(1, 1, 0x01, 0), (6, 2, 0x02, 0)], 1, 0, 1);
        let skel_child = build_indx_child(&[vec![0x02, b's', b'1', 0x03, 0x81, 0x80, 0x8E]]);
        let frag_root = build_indx_root(&[(4, 1, 0x01, 0), (6, 2, 0x02, 0)], 1, 0, 1);
        let frag_child = build_indx_child(&[vec![0x01, b'6', 0x03, 0x80, 0x80, 0x88]]);

        // NCX 索引：tag1(offset) / tag3(label) / tag4(pos fid,off) / tag21(level)
        let ncx_root = build_indx_root(
            &[
                (1, 1, 0x01, 0),
                (3, 1, 0x02, 0),
                (4, 2, 0x04, 0),
                (21, 1, 0x08, 0),
            ],
            1,
            1,
            1,
        );
        // 条目：label "C"；控制字节 0x0E（tag3/tag4/tag21 置位）；
        // 数据区依 tag 序：tag3=0(cncx 键)，tag4=[0(fid), 14(off)]，tag21=0
        let ncx_entry = vec![0x01, b'C', 0x0E, 0x80, 0x80, 0x8E, 0x80];
        let ncx_child = build_indx_child(&[ncx_entry]);
        let cncx = build_cncx(&["第一章"]);

        let pdb = build_pdb(&[
            build_rec0(&kf6_spec),
            build_rec0(&kf8_spec),
            text,
            skel_root,
            skel_child,
            frag_root,
            frag_child,
            ncx_root,  // 7
            ncx_child, // 8
            cncx,      // 9 = indx(6) + numRecords(1) + 1 + boundary(1)
        ]);
        let path = write_temp("kf8_ncx.mobi", &pdb);
        let path_str = path.to_str().unwrap();

        let chapters = MobiParser::get_chapters(path_str).unwrap();
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "第一章");
        // fid=0, off=14 → 拼装全文偏移 14（"SKELHEAD" 起点）
        assert_eq!(chapters[0].start, Some(14));
        assert!(chapters[0].url.starts_with("kindle:pos:fid:"));

        let content = MobiParser::get_chapter_content(path_str, &chapters[0]).unwrap();
        assert_eq!(content, "SKELHEAD");

        std::fs::remove_file(&path).ok();
    }

    // ---- FDST 表测试 ----

    #[test]
    fn test_read_fdst_table() {
        let mut fdst = vec![0u8; 12];
        fdst[0..4].copy_from_slice(b"FDST");
        w32(&mut fdst, 8, 2);
        fdst.extend_from_slice(&0u32.to_be_bytes());
        fdst.extend_from_slice(&100u32.to_be_bytes());
        fdst.extend_from_slice(&100u32.to_be_bytes());
        fdst.extend_from_slice(&200u32.to_be_bytes());

        let spec = Rec0Spec::default();
        let text = b"X".to_vec();
        let pdb = build_pdb(&[build_rec0(&spec), text, fdst]);
        let path = write_temp("fdst.mobi", &pdb);
        let book = MobiBook::open(path.to_str().unwrap()).unwrap();
        let (starts, ends) = read_fdst_table(&book, 2).unwrap();
        assert_eq!(starts, vec![0, 100]);
        assert_eq!(ends, vec![100, 200]);
        std::fs::remove_file(&path).ok();
    }

    // ---- LZMA / 加密拦截测试 ----

    #[test]
    fn test_lzma_rejected() {
        let spec = Rec0Spec {
            compression: 17481,
            ..Default::default()
        };
        let pdb = build_pdb(&[build_rec0(&spec), b"data".to_vec()]);
        let path = write_temp("lzma.mobi", &pdb);
        let err = MobiParser::parse(path.to_str().unwrap()).unwrap_err();
        let msg = format!("{err:?}");
        assert!(msg.contains("LZMA"));
        std::fs::remove_file(&path).ok();
    }
}
