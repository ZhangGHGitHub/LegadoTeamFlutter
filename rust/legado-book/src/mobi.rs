//! MOBI 格式解析模块
//!
//! MOBI 基于 PalmDoc (PDB) 容器格式，结构如下：
//! 1. PDB 头（78 字节）：包含文档名称、类型标识、记录数量等
//! 2. 记录索引表：每条记录 8 字节（offset + attributes）
//! 3. Record 0：MOBI 头（含元数据、压缩方式、文本偏移等）
//! 4. Record 1..N：PalmDoc 压缩的文本内容记录
//!
//! 本模块实现了：
//! - PDB 头解析
//! - MOBI 头解析（元数据提取）
//! - PalmDoc (LZ77 变种) 解压缩
//! - 基本章节提取（基于 INDX 记录或顺序分割）
//!
//! TODO: KF8 (AZW3) 格式支持、EXTH 扩展元数据完整解析

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use legado_core::{LegadoError, LegadoResult};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// MOBI 解析器
pub struct MobiParser;

// ---------------------------------------------------------------------------
// PDB / MOBI 头结构
// ---------------------------------------------------------------------------

/// PDB 文件头（78 字节）
#[derive(Debug)]
struct PdbHeader {
    name: String,
    num_records: u16,
}

/// Record 索引条目
#[derive(Debug)]
struct RecordEntry {
    offset: u32,
    #[allow(dead_code)]
    attributes: u8,
}

/// MOBI 头（Record 0 解析结果）
#[derive(Debug)]
struct MobiHeader {
    compression: u16,
    text_length: u32,
    record_count: u16,
    record_size: u16,
    encoding: u32,
    full_name: String,
    author: String,
    description: String,
}

// ---------------------------------------------------------------------------
// 公开接口
// ---------------------------------------------------------------------------

impl MobiParser {
    /// 解析 MOBI 文件元数据
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let mut file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;

        let pdb = read_pdb_header(&mut file)?;
        let records = read_record_entries(&mut file, pdb.num_records)?;
        let mobi = read_mobi_header(&mut file, &records)?;

        let title = if !mobi.full_name.is_empty() {
            mobi.full_name
        } else {
            pdb.name
        };

        Ok(BookMetadata {
            title,
            author: mobi.author,
            description: mobi.description,
            format: BookFormat::Mobi,
            cover: None,
        })
    }

    /// 获取章节列表
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let mut file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;

        let pdb = read_pdb_header(&mut file)?;
        let records = read_record_entries(&mut file, pdb.num_records)?;
        let mobi = read_mobi_header(&mut file, &records)?;

        // 基础实现：将文本按 record_count 等分为章节
        // TODO: 解析 INDX 记录获取真实章节结构
        let text = decompress_text(&mut file, &records, &mobi)?;
        Ok(split_into_chapters(&text))
    }

    /// 获取章节正文内容
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let mut file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;

        let pdb = read_pdb_header(&mut file)?;
        let records = read_record_entries(&mut file, pdb.num_records)?;
        let mobi = read_mobi_header(&mut file, &records)?;
        let text = decompress_text(&mut file, &records, &mobi)?;

        let start = chapter.start.unwrap_or(0) as usize;
        let end = chapter.end.unwrap_or(text.len() as i64) as usize;
        let start = start.min(text.len());
        let end = end.min(text.len());

        Ok(text[start..end].trim().to_string())
    }
}

// ---------------------------------------------------------------------------
// PDB 头解析
// ---------------------------------------------------------------------------

fn read_pdb_header(file: &mut File) -> LegadoResult<PdbHeader> {
    let mut buf = [0u8; 78];
    file.seek(SeekFrom::Start(0))?;
    file.read_exact(&mut buf)?;

    // 名称: bytes 0-31
    let name = String::from_utf8_lossy(&buf[0..32])
        .trim_end_matches('\0')
        .to_string();

    // 记录数: bytes 76-77 (big-endian)
    let num_records = u16::from_be_bytes([buf[76], buf[77]]);

    Ok(PdbHeader { name, num_records })
}

fn read_record_entries(file: &mut File, count: u16) -> LegadoResult<Vec<RecordEntry>> {
    // 记录索引紧跟 PDB 头（offset 78），每条 8 字节
    file.seek(SeekFrom::Start(78))?;
    let mut entries = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let mut buf = [0u8; 8];
        file.read_exact(&mut buf)?;
        let offset = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]);
        let attributes = buf[4];
        entries.push(RecordEntry { offset, attributes });
    }
    Ok(entries)
}

// ---------------------------------------------------------------------------
// MOBI 头解析
// ---------------------------------------------------------------------------

fn read_mobi_header(file: &mut File, records: &[RecordEntry]) -> LegadoResult<MobiHeader> {
    if records.is_empty() {
        return Err(LegadoError::BookParse("MOBI 文件无记录".into()));
    }

    // Record 0 起始位置
    file.seek(SeekFrom::Start(records[0].offset as u64))?;

    // PalmDoc 头（16 字节）
    let mut pdh = [0u8; 16];
    file.read_exact(&mut pdh)?;
    let compression = u16::from_be_bytes([pdh[0], pdh[1]]);
    let text_length = u32::from_be_bytes([pdh[4], pdh[5], pdh[6], pdh[7]]);
    let record_count = u16::from_be_bytes([pdh[8], pdh[9]]);
    let record_size = u16::from_be_bytes([pdh[10], pdh[11]]);

    // MOBI 头标识 'MOBI' 在 offset 16
    let mut mobi_magic = [0u8; 4];
    file.read_exact(&mut mobi_magic)?;

    let mut encoding: u32 = 1252; // 默认 Windows-1252
    let mut full_name = String::new();
    let author = String::new();
    let description = String::new();

    if &mobi_magic == b"MOBI" {
        // MOBI 头长度
        let mut hl_buf = [0u8; 4];
        file.read_exact(&mut hl_buf)?;
        let header_length = u32::from_be_bytes(hl_buf);

        // 读取更多 MOBI 头字段
        // 偏移（相对于 MOBI 头起始，即 Record 0 + 16）：
        //   +8:  mobi type
        //   +12: encoding
        //   +68: full name offset
        //   +72: full name length
        //   +128: EXTH flag
        let mut mobi_extra = vec![0u8; (header_length as usize).clamp(8, 256)];
        file.read_exact(&mut mobi_extra)?;

        if mobi_extra.len() >= 12 {
            encoding =
                u32::from_be_bytes([mobi_extra[8], mobi_extra[9], mobi_extra[10], mobi_extra[11]]);
        }

        // 读取 full name（如果有足够长度）
        if header_length >= 80 && mobi_extra.len() >= 72 {
            let fn_offset = u32::from_be_bytes([
                mobi_extra[64],
                mobi_extra[65],
                mobi_extra[66],
                mobi_extra[67],
            ]) as u64;
            let fn_length = u32::from_be_bytes([
                mobi_extra[68],
                mobi_extra[69],
                mobi_extra[70],
                mobi_extra[71],
            ]) as usize;
            if fn_offset > 0 && fn_length > 0 && fn_length < 1024 {
                let abs_offset = records[0].offset as u64 + fn_offset;
                if file.seek(SeekFrom::Start(abs_offset)).is_ok() {
                    let mut name_buf = vec![0u8; fn_length];
                    if file.read_exact(&mut name_buf).is_ok() {
                        full_name = String::from_utf8_lossy(&name_buf).to_string();
                    }
                }
            }
        }

        // TODO: 解析 EXTH 记录获取 author/description
    }

    Ok(MobiHeader {
        compression,
        text_length,
        record_count,
        record_size,
        encoding,
        full_name,
        author,
        description,
    })
}

// ---------------------------------------------------------------------------
// PalmDoc 解压缩
// ---------------------------------------------------------------------------

/// 解压所有文本记录
fn decompress_text(
    file: &mut File,
    records: &[RecordEntry],
    mobi: &MobiHeader,
) -> LegadoResult<String> {
    let mut result = Vec::with_capacity(mobi.text_length as usize);

    // 文本记录从 Record 1 开始
    let start = 1usize;
    let end = (mobi.record_count as usize + 1).min(records.len());

    for i in start..end {
        let rec_start = records[i].offset as u64;
        let rec_end = if i + 1 < records.len() {
            records[i + 1].offset as u64
        } else {
            // 估计最后一个记录结尾
            rec_start + mobi.record_size as u64
        };
        let rec_len = (rec_end - rec_start) as usize;

        file.seek(SeekFrom::Start(rec_start))?;
        let mut buf = vec![0u8; rec_len];
        file.read_exact(&mut buf)?;

        match mobi.compression {
            1 => {
                // 无压缩
                result.extend_from_slice(&buf);
            }
            2 => {
                // PalmDoc LZ77 压缩
                let decompressed = palmdoc_decompress(&buf);
                result.extend_from_slice(&decompressed);
            }
            _ => {
                // 其他压缩方式（HUFF/CDIC, LZMA 等）暂不支持
                // TODO: 实现 HUFF/CDIC (compression=17480) 和 LZMA (compression=17481)
                result.extend_from_slice(&buf);
            }
        }
    }

    // 截断到声明的文本长度
    result.truncate(mobi.text_length as usize);

    // 解码文本
    let text = decode_mobi_text(&result, mobi.encoding);
    Ok(text)
}

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
// 章节分割（简易实现）
// ---------------------------------------------------------------------------

/// 按固定段落数将文本分割为章节
/// TODO: 使用 INDX 记录或 HTML 标签解析真实章节结构
fn split_into_chapters(text: &str) -> Vec<ChapterInfo> {
    // 尝试用正则检测章节标题
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

    // 回填 end
    let total = text.len() as i64;
    for i in 0..chapters.len() {
        let next = if i + 1 < chapters.len() {
            chapters[i + 1].start.unwrap_or(total)
        } else {
            total
        };
        chapters[i].end = Some(next);
    }

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
