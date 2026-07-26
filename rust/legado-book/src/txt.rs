//! TXT 格式解析模块
//!
//! 处理流程：
//! 1. 编码检测：读取文件头字节，使用 `encoding_rs` 尝试识别 UTF-8/GBK/GB18030/BIG5 等
//! 2. 目录提取：使用正则匹配"第X章/第X回/第X节"等常见中文章节标题模式
//! 3. 章节内容：根据字节偏移范围提取对应段落

use std::fs::File;
use std::io::Read;

use encoding_rs::{Encoding, UTF_8};
use regex::Regex;

use legado_core::{LegadoError, LegadoResult};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// TXT 解析器
pub struct TxtParser;

/// 常见中文章节标题正则模式
/// 匹配：第X章、第X回、第X节、第X卷、第X集、Chapter X 等
const CHAPTER_PATTERNS: &[&str] = &[
    r"(?m)^\s{0,4}第[零一二三四五六七八九十百千万\d]+[章回节卷集部篇话]\s*.+$",
    r"(?m)^\s{0,4}Chapter\s+\d+.*$",
    r"(?m)^\s{0,4}CHAPTER\s+\d+.*$",
    r"(?m)^\s{0,4}Prologue\s*$",
    r"(?m)^\s{0,4}Epilogue\s*$",
    r"(?m)^\s{0,4}序\s*章?.*$",
    r"(?m)^\s{0,4}前言\s*$",
    r"(?m)^\s{0,4}后记\s*$",
    r"(?m)^\s{0,4}楔子\s*$",
    r"(?m)^\s{0,4}引子\s*$",
    r"(?m)^\s{0,4}尾声\s*$",
    r"(?m)^\s{0,4}附录\s*.+$",
];

impl TxtParser {
    /// 解析 TXT 文件元数据
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let file_name = std::path::Path::new(path)
            .file_stem()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "Unknown".to_string());

        Ok(BookMetadata {
            title: file_name,
            author: String::new(), // TXT 文件无法从内容自动提取作者
            description: String::new(),
            format: BookFormat::Txt,
            cover: None,
        })
    }

    /// 获取章节列表
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let encoding_name = Self::detect_encoding(path)?;
        let text_bytes = read_file_bytes(path)?;
        let text = decode_text(&text_bytes, &encoding_name);

        // 合并所有正则为一个
        let pattern = CHAPTER_PATTERNS.join("|");
        let re = Regex::new(&pattern)
            .map_err(|e| LegadoError::BookParse(format!("正则编译失败: {e}")))?;

        let mut chapters = Vec::new();
        let mut idx = 0i32;

        // 在文本中逐行查找章节标题，记录字节偏移
        let mut byte_offset: i64 = 0;
        for line in text.lines() {
            let line_byte_len = line.len() as i64 + 1; // +1 for '\n'
            if re.is_match(line) {
                let title = line.trim().to_string();
                if !title.is_empty() {
                    chapters.push(ChapterInfo {
                        url: format!("txt://chapter/{idx}"),
                        title,
                        index: idx,
                        is_volume: is_volume_title(line),
                        start: Some(byte_offset),
                        end: None, // 稍后回填
                    });
                    idx += 1;
                }
            }
            byte_offset += line_byte_len;
        }

        // 回填 end 偏移
        let total_len = text.len() as i64;
        for i in 0..chapters.len() {
            let next_start = if i + 1 < chapters.len() {
                chapters[i + 1].start.unwrap_or(total_len)
            } else {
                total_len
            };
            chapters[i].end = Some(next_start);
        }

        // 若未检测到任何章节，将整文件作为一个章节
        if chapters.is_empty() {
            chapters.push(ChapterInfo {
                url: "txt://chapter/0".to_string(),
                title: "全文".to_string(),
                index: 0,
                is_volume: false,
                start: Some(0),
                end: Some(total_len),
            });
        }

        Ok(chapters)
    }

    /// 获取章节正文内容
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let encoding_name = Self::detect_encoding(path)?;
        let text_bytes = read_file_bytes(path)?;
        let text = decode_text(&text_bytes, &encoding_name);

        let start = chapter.start.unwrap_or(0) as usize;
        let end = chapter.end.unwrap_or(text.len() as i64) as usize;
        let start = start.min(text.len());
        let end = end.min(text.len());

        // 确保在字符边界上切割
        let start = text.floor_char_boundary(start);
        let end = text.floor_char_boundary(end);

        Ok(text[start..end].trim().to_string())
    }

    /// 检测文件编码
    pub fn detect_encoding(path: &str) -> LegadoResult<String> {
        let mut file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;

        // 读取前 4KB 用于检测
        let mut buf = [0u8; 4096];
        let n = file.read(&mut buf)?;
        let sample = &buf[..n];

        // UTF-8 BOM
        if sample.starts_with(&[0xEF, 0xBB, 0xBF]) {
            return Ok("utf-8".to_string());
        }
        // UTF-16 LE BOM
        if sample.starts_with(&[0xFF, 0xFE]) {
            return Ok("utf-16le".to_string());
        }
        // UTF-16 BE BOM
        if sample.starts_with(&[0xFE, 0xFF]) {
            return Ok("utf-16be".to_string());
        }

        // 尝试 UTF-8 验证
        if std::str::from_utf8(sample).is_ok() {
            return Ok("utf-8".to_string());
        }

        // 使用 encoding_rs BOM 检测
        if let Some((enc, _bom_len)) = Encoding::for_bom(sample) {
            return Ok(enc.name().to_string());
        }

        // 尝试常见中文编码
        for name in &["gb18030", "gbk", "big5", "shift_jis", "euc-kr"] {
            if let Some(enc) = Encoding::for_label(name.as_bytes()) {
                let (_, _, had_errors) = enc.decode(sample);
                if !had_errors {
                    return Ok(name.to_string());
                }
            }
        }

        // 默认回退到 UTF-8
        Ok("utf-8".to_string())
    }
}

// ---------------------------------------------------------------------------
// 辅助函数
// ---------------------------------------------------------------------------

/// 读取文件全部字节
fn read_file_bytes(path: &str) -> LegadoResult<Vec<u8>> {
    let mut file = File::open(path)?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)?;
    Ok(buf)
}

/// 将字节按指定编码解码为字符串
fn decode_text(bytes: &[u8], encoding_name: &str) -> String {
    let enc = Encoding::for_label(encoding_name.as_bytes()).unwrap_or(UTF_8);
    // 跳过 BOM（如有）
    let skip = if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        3
    } else if bytes.starts_with(&[0xFF, 0xFE]) || bytes.starts_with(&[0xFE, 0xFF]) {
        2
    } else {
        0
    };
    let (cow, _, _) = enc.decode(&bytes[skip..]);
    cow.into_owned()
}

/// 判断标题是否为卷名（第X卷/第X部等）
fn is_volume_title(line: &str) -> bool {
    let re = Regex::new(r"第[零一二三四五六七八九十百千万\d]+[卷部]").unwrap();
    re.is_match(line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_volume_title_true() {
        assert!(is_volume_title("第一卷"));
        assert!(is_volume_title("第三部"));
        assert!(is_volume_title("第10卷 初入江湖"));
        assert!(is_volume_title("第一百零一部"));
    }

    #[test]
    fn test_is_volume_title_false() {
        assert!(!is_volume_title("第一章"));
        assert!(!is_volume_title("第三回"));
        assert!(!is_volume_title("第五节"));
    }

    #[test]
    fn test_chapter_patterns_match_chinese() {
        let pattern = CHAPTER_PATTERNS.join("|");
        let re = Regex::new(&pattern).unwrap();
        assert!(re.is_match("第一章 开始"));
        assert!(re.is_match("第二回 江湖"));
        assert!(re.is_match("第三十节 新的开始"));
        assert!(re.is_match("第一百章 结束"));
        assert!(re.is_match("序章"));
        assert!(re.is_match("前言"));
        assert!(re.is_match("后记"));
        assert!(re.is_match("楔子"));
        assert!(re.is_match("引子"));
        assert!(re.is_match("尾声"));
        assert!(re.is_match("附录 参考资料"));
    }

    #[test]
    fn test_chapter_patterns_match_english() {
        let pattern = CHAPTER_PATTERNS.join("|");
        let re = Regex::new(&pattern).unwrap();
        assert!(re.is_match("Chapter 1"));
        assert!(re.is_match("Chapter 100 The End"));
        assert!(re.is_match("CHAPTER 1"));
        assert!(re.is_match("Prologue"));
        assert!(re.is_match("Epilogue"));
    }

    #[test]
    fn test_chapter_patterns_no_match() {
        let pattern = CHAPTER_PATTERNS.join("|");
        let re = Regex::new(&pattern).unwrap();
        assert!(!re.is_match("正文内容不是标题"));
        assert!(!re.is_match("Hello World"));
    }

    #[test]
    fn test_decode_text_utf8() {
        let text = "Hello World".as_bytes();
        let result = decode_text(text, "utf-8");
        assert_eq!(result, "Hello World");
    }

    #[test]
    fn test_decode_text_utf8_bom() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice("BOM content".as_bytes());
        let result = decode_text(&bytes, "utf-8");
        assert_eq!(result, "BOM content");
    }
}
