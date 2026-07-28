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
//! - EXTH 扩展元数据解析（author/description/cover）
//! - PalmDoc (LZ77 变种) 解压缩
//! - 基本章节提取（基于正则检测章节标题）
//! - KF8 (AZW3) 格式检测与清晰错误提示
//!
//! 未实现（复杂度过高）：
//! - HUFF/CDIC 压缩算法 (compression=17480)
//! - INDX 记录解析获取真实章节结构

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
    /// 是否为 KF8 (AZW3) 格式
    is_kf8: bool,
}

/// EXTH 记录类型常量
const EXTH_AUTHOR: u32 = 100;
const EXTH_DESCRIPTION: u32 = 103;
#[allow(dead_code)]
const EXTH_COVER_OFFSET: u32 = 201;

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

        if mobi.is_kf8 {
            return Err(LegadoError::BookParse(
                "检测到 KF8 (AZW3) 格式，当前仅支持旧版 MOBI/PalmDoc 格式。\
                 建议将 AZW3 文件转换为 EPUB 或 MOBI 格式后重试。"
                    .into(),
            ));
        }

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

        if mobi.is_kf8 {
            return Err(LegadoError::BookParse(
                "检测到 KF8 (AZW3) 格式，当前仅支持旧版 MOBI 格式的章节提取。".into(),
            ));
        }

        // 基础实现：将文本按正则检测章节标题分割
        // 注：完整的 INDX 记录解析可获取更精确的章节结构，但复杂度过高暂不实现
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

        if mobi.is_kf8 {
            return Err(LegadoError::BookParse(
                "检测到 KF8 (AZW3) 格式，当前仅支持旧版 MOBI 格式的内容提取。".into(),
            ));
        }

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
    let rec0_offset = records[0].offset as u64;
    file.seek(SeekFrom::Start(rec0_offset))?;

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
    let mut author = String::new();
    let mut description = String::new();
    let mut is_kf8 = false;

    if &mobi_magic == b"MOBI" {
        // MOBI 头长度
        let mut hl_buf = [0u8; 4];
        file.read_exact(&mut hl_buf)?;
        let header_length = u32::from_be_bytes(hl_buf);

        // 读取更多 MOBI 头字段
        // 偏移（相对于 MOBI 头起始，即 Record 0 + 16）：
        //   +4:  mobi type (2=MOBI, 8=KF8)
        //   +8:  encoding
        //   +64: full name offset
        //   +68: full name length
        //   +124: EXTH flag
        let extra_len = (header_length as usize).saturating_sub(8).clamp(0, 256);
        let mut mobi_extra = vec![0u8; extra_len];
        file.read_exact(&mut mobi_extra)?;

        // 检测 KF8 格式：mobi type 字段在 extra[0..4]
        if mobi_extra.len() >= 4 {
            let mobi_type =
                u32::from_be_bytes([mobi_extra[0], mobi_extra[1], mobi_extra[2], mobi_extra[3]]);
            // type 8 = KF8 (AZW3)
            if mobi_type == 8 {
                is_kf8 = true;
            }
        }

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
                let abs_offset = rec0_offset + fn_offset;
                if file.seek(SeekFrom::Start(abs_offset)).is_ok() {
                    let mut name_buf = vec![0u8; fn_length];
                    if file.read_exact(&mut name_buf).is_ok() {
                        full_name = String::from_utf8_lossy(&name_buf).to_string();
                    }
                }
            }
        }

        // 解析 EXTH 记录获取 author/description
        // EXTH flag 在 header offset +128（即 mobi_extra[124..128]）
        let has_exth = if mobi_extra.len() >= 128 {
            let exth_flag = u32::from_be_bytes([
                mobi_extra[124],
                mobi_extra[125],
                mobi_extra[126],
                mobi_extra[127],
            ]);
            exth_flag & 0x40 != 0
        } else {
            false
        };

        if has_exth {
            // EXTH 头紧跟 MOBI 头之后
            let exth_offset = rec0_offset + 16 + header_length as u64;
            if let Ok(exth_data) = read_exth_header(file, exth_offset) {
                if author.is_empty() {
                    author = exth_data.author;
                }
                if description.is_empty() {
                    description = exth_data.description;
                }
            }
        }
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
        is_kf8,
    })
}

// ---------------------------------------------------------------------------
// EXTH 元数据解析
// ---------------------------------------------------------------------------

/// EXTH 解析结果
#[derive(Debug, Default)]
struct ExthData {
    author: String,
    description: String,
}

/// 读取并解析 EXTH 头
///
/// EXTH 结构：
/// - 4 bytes: magic "EXTH"
/// - 4 bytes: header length (total)
/// - 4 bytes: record count
/// - N records: each (4 bytes type, 4 bytes length including 8-byte header, data)
fn read_exth_header(file: &mut File, offset: u64) -> LegadoResult<ExthData> {
    file.seek(SeekFrom::Start(offset))?;

    let mut magic = [0u8; 4];
    file.read_exact(&mut magic)?;
    if &magic != b"EXTH" {
        return Err(LegadoError::BookParse("EXTH 魔数不匹配".into()));
    }

    let mut len_buf = [0u8; 4];
    file.read_exact(&mut len_buf)?;
    let header_length = u32::from_be_bytes(len_buf) as usize;

    let mut count_buf = [0u8; 4];
    file.read_exact(&mut count_buf)?;
    let record_count = u32::from_be_bytes(count_buf);

    // 读取整个 EXTH 块（减去已读的 12 字节头）
    if !(12..=1024 * 1024).contains(&header_length) {
        return Err(LegadoError::BookParse("EXTH 头长度异常".into()));
    }
    let data_len = header_length - 12;
    let mut data = vec![0u8; data_len];
    file.read_exact(&mut data)?;

    let mut result = ExthData::default();
    let mut pos = 0;

    for _ in 0..record_count {
        if pos + 8 > data.len() {
            break;
        }
        let rec_type = u32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]);
        let rec_len =
            u32::from_be_bytes([data[pos + 4], data[pos + 5], data[pos + 6], data[pos + 7]])
                as usize;
        if rec_len < 8 || pos + rec_len > data.len() {
            break;
        }
        let rec_data = &data[pos + 8..pos + rec_len];
        match rec_type {
            EXTH_AUTHOR => {
                result.author = String::from_utf8_lossy(rec_data).to_string();
            }
            EXTH_DESCRIPTION => {
                result.description = String::from_utf8_lossy(rec_data).to_string();
            }
            _ => {}
        }
        pos += rec_len;
    }

    Ok(result)
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
            17480 => {
                // HUFF/CDIC 压缩：算法复杂度高，暂不支持
                return Err(LegadoError::BookParse(
                    "不支持 HUFF/CDIC 压缩格式 (compression=17480)。\
                     建议使用 Calibre 等工具将文件转换为无压缩或 PalmDoc 压缩格式。"
                        .into(),
                ));
            }
            17481 => {
                // LZMA 压缩：暂不支持
                return Err(LegadoError::BookParse(
                    "不支持 LZMA 压缩格式 (compression=17481)。\
                     建议使用 Calibre 等工具将文件转换为 EPUB 格式。"
                        .into(),
                ));
            }
            other => {
                return Err(LegadoError::BookParse(format!(
                    "不支持的压缩方式: compression={other}"
                )));
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

/// 按正则检测章节标题将文本分割为章节
/// 注：完整的 INDX 记录解析可获取更精确的章节结构，但复杂度过高暂不实现
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert_eq!(EXTH_AUTHOR, 100);
        assert_eq!(EXTH_DESCRIPTION, 103);
        assert_eq!(EXTH_COVER_OFFSET, 201);
    }
}
