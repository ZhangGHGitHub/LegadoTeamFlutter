//! legado-book: 书籍格式解析器（EPUB/MOBI/TXT/PDF/UMD）
//!
//! 提供统一的本地书籍解析接口，支持多种格式：
//!
//! - [`epub`] — EPUB 格式解析（ZIP + OPF + NCX）
//! - [`txt`] — TXT 纯文本解析（自动检测编码 + 智能分章）
//! - [`mobi`] — MOBI/AZW 格式解析（PDB + EXTH 元数据）
//! - [`pdf`] — PDF 格式解析（基于 lopdf）
//! - [`umd`] — UMD 格式解析
//! - [`export`] — 书籍导出（TXT/EPUB/HTML）
//! - [`txt_search`] — 本地 TXT 分词搜索
//!
//! # Examples
//!
//! ```rust
//! use legado_book::{LocalBook, BookFormat};
//!
//! // 检测文件格式
//! let format = LocalBook::detect_format("novel.epub").unwrap();
//! assert_eq!(format, BookFormat::Epub);
//!
//! // 解析元数据（需要真实文件）
//! // let metadata = LocalBook::parse("path/to/book.epub").unwrap();
//! // println!("书名: {}", metadata.title);
//! ```

pub mod archive;
pub mod encoding;
pub mod epub;
pub mod export;
pub mod mobi;
pub mod pdf;
pub mod txt;
pub mod txt_search;
pub mod umd;

use legado_core::LegadoResult;
use serde::{Deserialize, Serialize};

/// 书籍元数据
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookMetadata {
    pub title: String,
    pub author: String,
    pub description: String,
    pub format: BookFormat,
    #[serde(skip)]
    pub cover: Option<Vec<u8>>,
}

/// 章节信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterInfo {
    /// 章节在文件内的定位标识（EPUB: href, TXT: 字节偏移）
    pub url: String,
    /// 章节标题
    pub title: String,
    /// 章节序号
    pub index: i32,
    /// 是否为卷名（非正文章节）
    pub is_volume: bool,
    /// 章节内容字节起始位置（TXT 专用）
    pub start: Option<i64>,
    /// 章节内容字节结束位置（TXT 专用）
    pub end: Option<i64>,
}

/// 书籍格式
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum BookFormat {
    Epub,
    Mobi,
    Txt,
    Pdf,
    Umd,
}

impl BookFormat {
    pub fn as_str(&self) -> &'static str {
        match self {
            BookFormat::Epub => "epub",
            BookFormat::Mobi => "mobi",
            BookFormat::Txt => "txt",
            BookFormat::Pdf => "pdf",
            BookFormat::Umd => "umd",
        }
    }
}

/// 书籍解析统一入口
pub struct LocalBook;

impl LocalBook {
    /// 根据文件扩展名检测格式
    pub fn detect_format(path: &str) -> LegadoResult<BookFormat> {
        let lower = path.to_lowercase();
        if lower.ends_with(".epub") {
            Ok(BookFormat::Epub)
        } else if lower.ends_with(".mobi") || lower.ends_with(".azw") || lower.ends_with(".azw3") {
            Ok(BookFormat::Mobi)
        } else if lower.ends_with(".pdf") {
            Ok(BookFormat::Pdf)
        } else if lower.ends_with(".txt") || lower.ends_with(".text") {
            Ok(BookFormat::Txt)
        } else if lower.ends_with(".umd") {
            Ok(BookFormat::Umd)
        } else {
            detect_format_by_magic(path)
        }
    }

    /// 解析书籍元数据
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let format = Self::detect_format(path)?;
        match format {
            BookFormat::Epub => epub::EpubParser::parse(path),
            BookFormat::Txt => txt::TxtParser::parse(path),
            BookFormat::Mobi => mobi::MobiParser::parse(path),
            BookFormat::Pdf => pdf::PdfParser::parse(path),
            BookFormat::Umd => umd::UmdParser::parse(path),
        }
    }

    /// 获取章节列表
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let format = Self::detect_format(path)?;
        match format {
            BookFormat::Epub => epub::EpubParser::get_chapters(path),
            BookFormat::Txt => txt::TxtParser::get_chapters(path),
            BookFormat::Mobi => mobi::MobiParser::get_chapters(path),
            BookFormat::Pdf => pdf::PdfParser::get_chapters(path),
            BookFormat::Umd => umd::UmdParser::get_chapters(path),
        }
    }

    /// 获取章节正文内容
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let format = Self::detect_format(path)?;
        match format {
            BookFormat::Epub => epub::EpubParser::get_chapter_content(path, chapter),
            BookFormat::Txt => txt::TxtParser::get_chapter_content(path, chapter),
            BookFormat::Mobi => mobi::MobiParser::get_chapter_content(path, chapter),
            BookFormat::Pdf => pdf::PdfParser::get_chapter_content(path, chapter),
            BookFormat::Umd => umd::UmdParser::get_chapter_content(path, chapter),
        }
    }
}

/// 通过文件头魔数检测格式
fn detect_format_by_magic(path: &str) -> LegadoResult<BookFormat> {
    use std::fs::File;
    use std::io::Read;

    let mut file = File::open(path)?;
    let mut header = [0u8; 8];
    file.read_exact(&mut header)?;

    // ZIP 文件头 (PK)：可能是 EPUB
    if header[0] == 0x50 && header[1] == 0x4B {
        return Ok(BookFormat::Epub);
    }
    // PDF 文件头
    if &header[0..5] == b"%PDF-" {
        return Ok(BookFormat::Pdf);
    }
    // 默认视为 TXT
    Ok(BookFormat::Txt)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_book_format_as_str() {
        assert_eq!(BookFormat::Epub.as_str(), "epub");
        assert_eq!(BookFormat::Mobi.as_str(), "mobi");
        assert_eq!(BookFormat::Txt.as_str(), "txt");
        assert_eq!(BookFormat::Pdf.as_str(), "pdf");
        assert_eq!(BookFormat::Umd.as_str(), "umd");
    }

    #[test]
    fn test_detect_format_umd() {
        assert_eq!(
            LocalBook::detect_format("book.umd").unwrap(),
            BookFormat::Umd
        );
        assert_eq!(
            LocalBook::detect_format("BOOK.UMD").unwrap(),
            BookFormat::Umd
        );
    }

    #[test]
    fn test_detect_format_epub() {
        let fmt = LocalBook::detect_format("test.epub").unwrap();
        assert_eq!(fmt, BookFormat::Epub);
    }

    #[test]
    fn test_detect_format_mobi() {
        assert_eq!(
            LocalBook::detect_format("book.mobi").unwrap(),
            BookFormat::Mobi
        );
        assert_eq!(
            LocalBook::detect_format("book.azw").unwrap(),
            BookFormat::Mobi
        );
        assert_eq!(
            LocalBook::detect_format("book.azw3").unwrap(),
            BookFormat::Mobi
        );
    }

    #[test]
    fn test_detect_format_pdf() {
        assert_eq!(
            LocalBook::detect_format("doc.pdf").unwrap(),
            BookFormat::Pdf
        );
    }

    #[test]
    fn test_detect_format_txt() {
        assert_eq!(
            LocalBook::detect_format("novel.txt").unwrap(),
            BookFormat::Txt
        );
        assert_eq!(
            LocalBook::detect_format("novel.text").unwrap(),
            BookFormat::Txt
        );
    }

    #[test]
    fn test_detect_format_case_insensitive() {
        assert_eq!(
            LocalBook::detect_format("Book.EPUB").unwrap(),
            BookFormat::Epub
        );
        assert_eq!(
            LocalBook::detect_format("BOOK.MOBI").unwrap(),
            BookFormat::Mobi
        );
        assert_eq!(
            LocalBook::detect_format("FILE.PDF").unwrap(),
            BookFormat::Pdf
        );
    }

    #[test]
    fn test_book_format_serde() {
        let fmt = BookFormat::Epub;
        let json = serde_json::to_string(&fmt).unwrap();
        let de: BookFormat = serde_json::from_str(&json).unwrap();
        assert_eq!(de, BookFormat::Epub);
    }

    #[test]
    fn test_book_metadata_serde() {
        let meta = BookMetadata {
            title: "测试".to_string(),
            author: "作者".to_string(),
            description: "简介".to_string(),
            format: BookFormat::Txt,
            cover: Some(vec![1, 2, 3]), // should be skipped by serde
        };
        let json = serde_json::to_string(&meta).unwrap();
        assert!(!json.contains("cover")); // skip field
        let de: BookMetadata = serde_json::from_str(&json).unwrap();
        assert_eq!(de.title, "测试");
        assert!(de.cover.is_none()); // not serialized
    }

    #[test]
    fn test_chapter_info_serde() {
        let ch = ChapterInfo {
            url: "ch1".to_string(),
            title: "第一章".to_string(),
            index: 0,
            is_volume: false,
            start: Some(0),
            end: Some(1000),
        };
        let json = serde_json::to_string(&ch).unwrap();
        let de: ChapterInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de.url, "ch1");
        assert_eq!(de.title, "第一章");
        assert_eq!(de.start, Some(0));
    }
}
