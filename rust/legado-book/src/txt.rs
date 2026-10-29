//! TXT 格式解析模块
//!
//! 处理流程：
//! 1. 编码检测：读取文件头字节，使用 `encoding_rs` 尝试识别 UTF-8/GBK/GB18030/BIG5 等
//! 2. 目录提取：使用正则匹配"第X章/第X回/第X节"等常见中文章节标题模式
//! 3. 章节内容：根据字节偏移范围提取对应段落

use std::fs::File;
use std::io::Read;

use encoding_rs::{Encoding, UTF_8};

use legado_core::regex_safe::compile_regex_safe;
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

    /// 获取章节列表（自动检测编码）
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        Self::get_chapters_with_charset(path, None)
    }

    /// 获取章节列表，可指定编码覆盖自动检测
    ///
    /// [批37b P1-1] 阅读器「设置编码」写入 `Book.charset` 后，目录/正文
    /// 都必须按该编码解码——只改正文会让目录偏移（按解码后文本字节数
    /// 计算）与正文解码结果失配。`charset` 为 `None`/空白时保持原有检测
    /// 逻辑；显式传入不支持的编码名直接报错（fail-closed，不静默回退）。
    pub fn get_chapters_with_charset(
        path: &str,
        charset: Option<&str>,
    ) -> LegadoResult<Vec<ChapterInfo>> {
        let text_bytes = read_file_bytes(path)?;
        let text = decode_with_charset(&text_bytes, path, charset)?;

        // 合并所有正则为一个（内置常量 pattern 拼接，仍走统一安全入口以命中全局编译缓存）
        let pattern = CHAPTER_PATTERNS.join("|");
        let re = compile_regex_safe(&pattern)
            .ok_or_else(|| LegadoError::BookParse("章节正则编译失败（非法或超限）".to_string()))?;

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

    /// 获取章节正文内容（自动检测编码）
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        Self::get_chapter_content_with_charset(path, chapter, None)
    }

    /// 获取章节正文内容，可指定编码覆盖自动检测
    ///
    /// `chapter.start/end` 是**解码后文本**的字节偏移（由
    /// [`Self::get_chapters_with_charset`] 在同一编码下生成），换编码后
    /// 必须重新解析目录才能保证偏移一致（调用方负责清目录）。
    pub fn get_chapter_content_with_charset(
        path: &str,
        chapter: &ChapterInfo,
        charset: Option<&str>,
    ) -> LegadoResult<String> {
        let text_bytes = read_file_bytes(path)?;
        let text = decode_with_charset(&text_bytes, path, charset)?;

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
///
/// `encoding_rs::Encoding` 的实例均为 `'static`（`name()` 要求 `&'static self`）
fn decode_text(bytes: &[u8], enc: &'static Encoding) -> String {
    // 仅跳过与所选编码匹配的 BOM：显式 GBK 覆盖时，开头 `EF BB BF`
    // 是真实文本而非 BOM，不能无条件丢弃
    let skip = if enc == UTF_8 && bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        3
    } else if (enc.name().eq_ignore_ascii_case("utf-16le") && bytes.starts_with(&[0xFF, 0xFE]))
        || (enc.name().eq_ignore_ascii_case("utf-16be") && bytes.starts_with(&[0xFE, 0xFF]))
    {
        2
    } else {
        0
    };
    let (cow, _, _) = enc.decode(&bytes[skip..]);
    cow.into_owned()
}

/// 解析编码名（`encoding_rs` 标签体系），不支持/空白一律报错
///
/// [批37b P1-1] 供 FFI 单列写入口做 fail-closed 校验：用户输入不支持的
/// 编码名时必须报错，不能落库一个「看起来成功但读正文仍乱码」的值。
pub fn encoding_for_label(label: &str) -> LegadoResult<&'static Encoding> {
    let label = label.trim();
    if label.is_empty() {
        return Err(LegadoError::BookParse("编码不能为空".to_string()));
    }
    Encoding::for_label(label.as_bytes())
        .ok_or_else(|| LegadoError::BookParse(format!("不支持的编码: {label}")))
}

/// 编码名归一化为 `encoding_rs` 标准名（如 `GB2312` → `GBK`）
pub fn normalize_charset(label: &str) -> LegadoResult<String> {
    Ok(encoding_for_label(label)?.name().to_string())
}

/// 解码文本：显式 charset 覆盖自动检测
///
/// 显式覆盖优先于检测/默认；为空时回退 [`TxtParser::detect_encoding`]。
fn decode_with_charset(bytes: &[u8], path: &str, charset: Option<&str>) -> LegadoResult<String> {
    if let Some(label) = charset.map(str::trim).filter(|s| !s.is_empty()) {
        let enc = encoding_for_label(label)?;
        return Ok(decode_text(bytes, enc));
    }
    let detected = TxtParser::detect_encoding(path)?;
    let enc = Encoding::for_label(detected.as_bytes()).unwrap_or(UTF_8);
    Ok(decode_text(bytes, enc))
}

/// 判断标题是否为卷名（第X卷/第X部等）
fn is_volume_title(line: &str) -> bool {
    // 内置常量 pattern（非用户可控），直连编译；同样经安全入口以复用全局缓存
    compile_regex_safe(r"第[零一二三四五六七八九十百千万\d]+[卷部]")
        .is_some_and(|re| re.is_match(line))
}

#[cfg(test)]
mod tests {
    use super::*;
    // 测试内直连编译仅限内置常量 pattern（非用户可控）
    use regex::Regex;

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
        let result = decode_text(text, UTF_8);
        assert_eq!(result, "Hello World");
    }

    #[test]
    fn test_decode_text_utf8_bom() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice("BOM content".as_bytes());
        let result = decode_text(&bytes, UTF_8);
        assert_eq!(result, "BOM content");
    }

    #[test]
    fn test_normalize_charset_aliases_and_unknown() {
        assert_eq!(normalize_charset("utf-8").unwrap(), "UTF-8");
        assert_eq!(normalize_charset("GBK").unwrap(), "GBK");
        // GB2312 是 GBK 的标签别名，归一化后按 GBK 解码
        assert_eq!(normalize_charset("GB2312").unwrap(), "GBK");
        assert!(normalize_charset("  ").is_err(), "空白编码必须报错");
        assert!(
            normalize_charset("no-such-charset").is_err(),
            "不支持的编码必须 fail-closed"
        );
    }

    /// [批37b P1-1] 红→绿：GBK 正文 + 前 4KB 纯 ASCII（检测阶段误判 UTF-8）
    /// → 无覆盖时乱码；显式 charset=GBK 后目录与正文都正确解码。
    #[test]
    fn test_charset_override_decodes_gbk_after_ascii_prefix() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let dir =
            std::env::temp_dir().join(format!("legado_txt_charset_{}_{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("gbk.txt");

        // 前 4096 字节全 ASCII（末位换行）：detect_encoding 的 UTF-8 探测
        // 会成功，从而把后续 GBK 中文误判为 UTF-8
        let mut bytes = vec![b'A'; 4095];
        bytes.push(b'\n');
        let (gbk_body, _, _) = encoding_rs::GBK
            .encode("第一章 起始\r\n这是正文内容。\r\n第二章 继续\r\n更多正文内容。\r\n");
        bytes.extend_from_slice(&gbk_body);
        std::fs::write(&path, &bytes).unwrap();
        let path_str = path.to_str().unwrap();

        // 自动检测：前 4KB ASCII → utf-8，中文标题无法匹配 → 单章「全文」
        let auto = TxtParser::get_chapters(path_str).unwrap();
        assert_eq!(auto.len(), 1, "无覆盖时标题乱码，应回退单章");
        assert_eq!(auto[0].title, "全文");

        // 显式 GBK：目录按 GBK 解码后正确分章
        let chapters = TxtParser::get_chapters_with_charset(path_str, Some("GBK")).unwrap();
        assert_eq!(chapters.len(), 2, "GBK 覆盖后应识别出两章: {chapters:?}");
        assert_eq!(chapters[0].title, "第一章 起始");
        assert_eq!(chapters[1].title, "第二章 继续");

        // 显式 GBK：正文正确解码
        let content =
            TxtParser::get_chapter_content_with_charset(path_str, &chapters[1], Some("gbk"))
                .unwrap();
        assert!(
            content.contains("更多正文内容"),
            "GBK 覆盖后正文应正确解码: {content}"
        );
        // 对照：无覆盖（UTF-8）拿不到正确文本
        let auto_content = TxtParser::get_chapter_content(path_str, &chapters[1]).unwrap();
        assert!(
            !auto_content.contains("更多正文内容"),
            "无覆盖时应为乱码（红）: {auto_content}"
        );

        // 不支持的编码：fail-closed
        let err = TxtParser::get_chapters_with_charset(path_str, Some("no-such-charset"))
            .expect_err("不支持的编码必须报错");
        assert!(err.to_string().contains("不支持的编码"), "{err}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
