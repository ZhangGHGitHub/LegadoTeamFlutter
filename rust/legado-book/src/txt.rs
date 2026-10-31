//! TXT 格式解析模块
//!
//! 处理流程：
//! 1. 编码检测：读取文件头字节，使用 `encoding_rs` 尝试识别 UTF-8/GBK/GB18030/BIG5 等
//! 2. 目录提取：使用正则匹配"第X章/第X回/第X节"等常见中文章节标题模式
//! 3. 章节内容：根据字节偏移范围提取对应段落

use std::fs::File;
use std::io::Read;

use encoding_rs::{Encoding, UTF_8};

use legado_core::regex_safe::{compile_fancy_regex_safe, compile_regex_safe};
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

/// 原版 `TextFile.spaceChars`：`Book.tocUrl` 中「目录正则」与「JS 替换片段」的
/// 分隔符（U+1FAC5 / U+1F233 / U+1F3FB，见 `TextFile.kt` 常量与
/// `TxtTocRuleDialog.kt` 的 `tocRule.rule + spaceChars + tocRule.replacement`）。
///
/// 沿用原版格式而非自定义 JSON：Android 备份/跨端数据库中的 `books.tocUrl`
/// 可直接消费，无需迁移；本批新增的显式规则写入也复用同一格式。
pub const TOC_RULE_SEPARATOR: &str = "🫅🈳🏻";

/// [批1b-3] 无目录规则时每章最大字数默认值（对齐参考版
/// `ReadSettings.maxLengthWithNoToc` 默认 3000；原版无此设置项，固定
/// `10 * 1024` 字节）
pub const DEFAULT_MAX_LENGTH_WITH_NO_TOC: u32 = 3000;

/// [批1b-3] 无目录规则时每章最大字数夹逼下限（对齐参考版
/// `ReadConfigViewModel.kt:134` `value.coerceIn(3000, 100000)`）
pub const MIN_MAX_LENGTH_WITH_NO_TOC: u32 = 3000;

/// [批1b-3] 无目录规则时每章最大字数夹逼上限（对齐参考版
/// `ReadConfigViewModel.kt:134` `value.coerceIn(3000, 100000)`）
pub const MAX_MAX_LENGTH_WITH_NO_TOC: u32 = 100_000;

/// [批1b-3] 无目录规则时每章最大字数夹逼（对齐参考版
/// `ReadConfigViewModel` 读入口径：非法/越界回落默认 3000、范围内原样保留）
pub fn clamp_max_length_with_no_toc(raw: Option<u32>) -> u32 {
    raw.map(|v| v.clamp(MIN_MAX_LENGTH_WITH_NO_TOC, MAX_MAX_LENGTH_WITH_NO_TOC))
        .unwrap_or(DEFAULT_MAX_LENGTH_WITH_NO_TOC)
}

/// 拆分原版格式的 `Book.tocUrl`
///
/// 返回 `(目录正则, JS 替换片段)`：
/// - 含分隔符：前半为正则、后半为 replacement（可为空串，`split_once`
///   只按**第一个**分隔符切分，replacement 内含分隔符时原样保留）；
/// - 无分隔符：整串视为正则（兼容手工写入/旧数据）；
/// - 空白：`(None, "")`，表示走内置默认规则。
///
/// [批43b P3-2] **外部 `tocUrl` 保持原样**：原版 `TextFile.analyze` 直接取
/// `tocUrl.split(spaceChars, limit=2)[0]` 作为正则，不做 trim——正则首尾的
/// 空白（如 `^\s第.+章`）可能是用户语义的一部分。这里只对「整串空白」
/// 判默认，正则与 replacement 均按库内原样返回；仅当分隔符左侧**恰好为空**
/// 时按原版 `rr[0].isEmpty()` 回退默认。写入侧 [`crate::txt`] 的
/// `build_toc_rule_storage` 仍会规范化新写入的规则（UI 输入口径），两者
/// 不冲突：外部历史数据只读不改。
pub fn split_toc_rule(toc_url: &str) -> (Option<String>, String) {
    if toc_url.trim().is_empty() {
        return (None, String::new());
    }
    match toc_url.split_once(TOC_RULE_SEPARATOR) {
        Some((rule, replacement)) => {
            if rule.is_empty() {
                (None, replacement.to_string())
            } else {
                (Some(rule.to_string()), replacement.to_string())
            }
        }
        None => (Some(toc_url.to_string()), String::new()),
    }
}

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
        Ok(Self::get_chapters_with_rule(path, charset, None)?.chapters)
    }

    /// 获取章节列表，显式指定 TXT 目录规则（批43）
    ///
    /// 语义对齐 Android 原版 `TextFile`：
    /// - `rule` 为正则串（可空/空白 = 自动目录，即内置默认规则）；
    /// - 规则按 `Pattern.MULTILINE` 语义匹配整段解码后文本（原版
    ///   `book.tocUrl` 中 `rule` 部分，见 [`split_toc_rule`]）；
    /// - 规则编译失败或未匹配到任何标题时**回退内置默认规则**，返回值的
    ///   `used_custom_rule=false` 供调用方记日志/提示；
    /// - 内置默认规则也零命中时，按参考版默认档位（3000 字）长度分章
    ///   （见 [`Self::get_chapters_with_rule_config`]）；
    /// - `replacement`（原版 JS 替换片段）不参与解析（Rust 侧未内嵌 JS
    ///   引擎），标题保留正则命中原文。
    ///
    /// 返回 [`crate::TocParseOutcome`]：章节列表 + 是否真正使用了显式规则。
    pub fn get_chapters_with_rule(
        path: &str,
        charset: Option<&str>,
        rule: Option<&str>,
    ) -> LegadoResult<crate::TocParseOutcome> {
        Self::get_chapters_with_rule_config(path, charset, rule, DEFAULT_MAX_LENGTH_WITH_NO_TOC)
    }

    /// 获取章节列表（可指定无目录规则时每章最大字数，批1b-3）
    ///
    /// 与 [`Self::get_chapters_with_rule`] 相同，但「显式规则与内置默认规则
    /// 均零命中」时的长度分章档位由调用方传入（FFI 侧读
    /// `config:maxLengthWithNoToc`，缺省/非法回落 3000、越界夹逼
    /// 3000..100000）。切分语义逐条对齐参考版 `TextFile.kt` `analyze()`
    /// （L358-464）：超出上限处在最近的换行符截断（换行符归下一章行首，
    /// 与原版 `end = i` 口径一致）、无换行则到文本末尾硬切、尾段不足
    /// 最小档位（参考版 100 字节按编码换算为字符数）并入上一章。
    pub fn get_chapters_with_rule_config(
        path: &str,
        charset: Option<&str>,
        rule: Option<&str>,
        max_chars_with_no_toc: u32,
    ) -> LegadoResult<crate::TocParseOutcome> {
        let text_bytes = read_file_bytes(path)?;
        let text = decode_with_charset(&text_bytes, path, charset)?;

        let custom_rule = rule.map(str::trim).filter(|r| !r.is_empty());
        let mut used_custom_rule = false;
        let mut chapters = Vec::new();

        if let Some(rule) = custom_rule {
            match parse_with_custom_rule(&text, rule) {
                Some(mut matched) if !matched.is_empty() => {
                    used_custom_rule = true;
                    chapters.append(&mut matched);
                }
                // 规则不可编译 / 未命中 → 回退内置默认规则（调用方记 warn）
                _ => {}
            }
        }

        if chapters.is_empty() {
            chapters = parse_with_builtin_rule(&text)?;
        }

        // [批1b-3] 显式规则与内置默认规则均零命中：按字数长度分章（对齐
        // 参考版 `TextFile.analyze()` 无规则拆分）。仅非空文本参与切分；
        // 空文件保持既有「全文」单章兜底（不产生空章）。
        if chapters.is_empty() && !text.is_empty() {
            chapters = parse_by_length(&text, max_chars_with_no_toc);
        }

        // 若未检测到任何章节，将整文件作为一个章节
        if chapters.is_empty() {
            let total_len = text.len() as i64;
            chapters.push(ChapterInfo {
                url: "txt://chapter/0".to_string(),
                title: "全文".to_string(),
                index: 0,
                is_volume: false,
                start: Some(0),
                end: Some(total_len),
            });
        }

        // 回填 end 偏移（下一章起点 / 文件末尾）
        let total_len = text.len() as i64;
        for i in 0..chapters.len() {
            let next_start = if i + 1 < chapters.len() {
                chapters[i + 1].start.unwrap_or(total_len)
            } else {
                total_len
            };
            chapters[i].end = Some(next_start);
        }

        Ok(crate::TocParseOutcome {
            chapters,
            used_custom_rule,
        })
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

/// 内置默认规则解析（自动目录）
///
/// 逐行匹配内置 `CHAPTER_PATTERNS`。偏移按原始行字节数累加
/// （`split_inclusive('\n')` 保留行尾 `\n`/`\r\n` 的真实长度，避免 CRLF
/// 文件逐行少算 1 字节导致正文切片错位）。
fn parse_with_builtin_rule(text: &str) -> LegadoResult<Vec<ChapterInfo>> {
    // 合并所有正则为一个（内置常量 pattern 拼接，仍走统一安全入口以命中全局编译缓存）
    let pattern = CHAPTER_PATTERNS.join("|");
    let re = compile_regex_safe(&pattern)
        .ok_or_else(|| LegadoError::BookParse("章节正则编译失败（非法或超限）".to_string()))?;

    let mut chapters: Vec<ChapterInfo> = Vec::new();
    let mut byte_offset: i64 = 0;
    for raw_line in text.split_inclusive('\n') {
        let line_start = byte_offset;
        // 去掉行尾换行（含 CRLF 的 `\r`），标题与卷判定都按无换行文本
        let line = raw_line.strip_suffix('\n').unwrap_or(raw_line);
        let line = line.strip_suffix('\r').unwrap_or(line);
        if re.is_match(line) {
            let title = line.trim();
            if !title.is_empty() {
                let idx = chapters.len() as i32;
                chapters.push(ChapterInfo {
                    url: format!("txt://chapter/{idx}"),
                    title: title.to_string(),
                    index: idx,
                    is_volume: is_volume_title(line),
                    start: Some(line_start),
                    end: None, // 稍后回填
                });
            }
        }
        byte_offset += raw_line.len() as i64;
    }
    Ok(chapters)
}

/// 显式规则解析（对齐原版 `TextFile.analyze(rr)`）
///
/// 原版以 Java `Pattern.MULTILINE` 在**整段文本**上 `matcher.find()`；此处用
/// `fancy-regex`（支持原版默认规则大量使用的 lookbehind）按同样语义匹配，
/// 再把命中位置映射回所属行：章节起点取行首、标题取命中片段（trim）。
///
/// [批43b P3-3] 空标题口径对齐原版 `replacement(...).takeIf { it.isNotEmpty() }`：
/// 命中片段 trim 后为空（空匹配 / 纯空白）→ **跳过该命中**，不回退整行文本；
/// 零宽字符（U+200B 等）不属于 Unicode White_Space，trim 不会移除，标题按原版
/// 原样保留（这些字符常用于排版对齐，原版同样保留）。
///
/// 返回 `None` 表示规则不可编译（调用方回退默认规则）；返回空 `Vec`
/// 表示规则可编译但未命中任何标题。
fn parse_with_custom_rule(text: &str, rule: &str) -> Option<Vec<ChapterInfo>> {
    // 原版 `toPattern(Pattern.MULTILINE)`：统一前置 `(?m)`（用户自带
    // `(?-m)` 等后续 flag 仍可覆盖）
    let pattern = format!("(?m){rule}");
    let re = compile_fancy_regex_safe(&pattern)?;

    let line_spans = line_spans(text);
    let mut chapters: Vec<ChapterInfo> = Vec::new();
    let mut last_line: Option<usize> = None;

    for matched in re.find_iter(text) {
        // 回溯超限等运行时错误：停止匹配，由调用方按「未命中」回退默认规则
        let Ok(matched) = matched else { break };
        let line_idx = line_index_for(&line_spans, matched.start());
        // 同一行的多次命中只算一个标题（对齐原版逐 matcher.find() 的
        // 「匹配串即标题」语义中，同一行重复命中会得到重复章节的偏差）
        if last_line.is_some_and(|prev| line_idx <= prev) {
            continue;
        }
        let matched_title = matched.as_str().trim();
        // [批43b P3-3] 空/纯空白命中按原版 takeIf{isNotEmpty()} 跳过；
        // 只有真正入章后才占用该行（否则后续命中会被 last_line 误抑制）
        if matched_title.is_empty() {
            continue;
        }
        last_line = Some(line_idx);
        let title = matched_title;

        let span = line_spans[line_idx];
        let line = &text[span.start..span.end];
        let idx = chapters.len() as i32;
        chapters.push(ChapterInfo {
            url: format!("txt://chapter/{idx}"),
            title: title.to_string(),
            index: idx,
            is_volume: is_volume_title(line),
            start: Some(span.start as i64),
            end: None,
        });
    }
    Some(chapters)
}

/// 行区间（`end` 不含行尾 `\n`/`\r`），用于把整段匹配位置映射回行
#[derive(Clone, Copy)]
struct LineSpan {
    start: usize,
    end: usize,
}

/// [批1b-3] 无目录规则时按长度分章（对齐参考版 `TextFile.analyze()` L358-464）
///
/// - `max_chars`：每章最大**字符数**（调用方已夹逼 3000..100000；参考版经
///   `maxLengthWithNoTocBytes` 把字数换算为字节上限后按字节切分，编码/解码
///   已在调用方完成，此处直接按字符切分，切分结果字节数恒不超过参考版
///   `max_chars × 每字符最大字节数` 的预算，且不存在多字节截断）；
///
/// 算法（对齐参考版逐条）：
/// 1. 剩余字符数 > `max_chars` 时，从「起点后第 `max_chars` 个字符」的字节
///    偏移起向后找最近的 `\n` 作终止点（参考版 L445-449 找 `0x0a`；`\n` 字节
///    不在本章区间、归下一章行首，对齐参考版 `end = i` 与
///    `chapter.start = toc.lastOrNull()?.end`），无换行则切到文本末尾
///    （参考版 `end = length` 硬切口径）；
/// 2. 剩余 ≤ `max_chars` 时收尾：尾段**字节数** > 100（参考版 L457
///    `bufferStart > 100`，按原始字节比较）或尚无章节 → 自成一章，
///    否则并入上一章（上一章 `end` 由调用方回填循环覆盖到文件末尾）；
/// 3. 标题 `第{block}章({pos})`（参考版 L385 模板；整文件单缓冲处理
///    block 恒为 1，参考版多缓冲分块时 block 为缓冲序号，标题仅展示语义）；
/// 4. `start/end` 为解码后文本的**字节**偏移（与正文读取链同一坐标系），
///    切分点全部落在 UTF-8 字符边界（由字符迭代保证）。
///
/// 不丢字、不重复、不产生空章：每个字符恰好落入一个章节区间（含分隔
/// 换行），空文本由调用方排除。
fn parse_by_length(text: &str, max_chars: u32) -> Vec<ChapterInfo> {
    let max_chars = (max_chars as usize).max(1);
    let mut chapters: Vec<ChapterInfo> = Vec::new();
    // 参考版 blockPos 为缓冲块序号、chapterPos 为块内章节序；整段处理 block=1
    let mut pos = 0usize;
    let mut cursor = 0usize; // 当前切分起点（字节偏移，字符边界）
    let mut ahead = 0usize; // cursor 前移探测用的字节偏移（恒 ≥ cursor）

    // 单次前向扫描（每字节至多访问一次）：从 cursor 前进 max_chars 个字符
    // 得到超限点，再继续扫描到最近 `\n`（或文本末尾）。整段 O(n)。
    loop {
        // 1) 前进 max_chars 个字符 → 超限点（参考版 offset + max 的字节位）
        let mut stepped = 0usize;
        while stepped < max_chars {
            match text[ahead..].chars().next() {
                Some(ch) => {
                    ahead += ch.len_utf8();
                    stepped += 1;
                }
                None => break,
            }
        }
        // 剩余 ≤ max_chars：收尾
        if stepped < max_chars {
            break;
        }
        // 2) 超限点起向后找最近换行；`\n` 归下一章行首（参考版 L445-449）
        let end = match text[ahead..].find('\n') {
            Some(rel) => ahead + rel,
            None => text.len(),
        };
        pos += 1;
        chapters.push(ChapterInfo {
            url: format!("txt://chapter/{}", chapters.len()),
            title: format!("第1章({pos})"),
            index: chapters.len() as i32,
            is_volume: false,
            start: Some(cursor as i64),
            end: None,
        });
        cursor = end;
        ahead = end;
    }

    // 尾段：剩余字符全部归末章（>100 字节或尚无章节时自成一章，
    // 参考版 L457 `bufferStart > 100 || toc.isEmpty()`）
    pos += 1;
    if text.len() - cursor > 100 || chapters.is_empty() {
        chapters.push(ChapterInfo {
            url: format!("txt://chapter/{}", chapters.len()),
            title: format!("第1章({pos})"),
            index: chapters.len() as i32,
            is_volume: false,
            start: Some(cursor as i64),
            end: None,
        });
    }
    chapters
}

/// 构建行区间表（按字节；`\n` 分隔，兼容 `\r\n`）
fn line_spans(text: &str) -> Vec<LineSpan> {
    let bytes = text.as_bytes();
    let mut spans = Vec::new();
    let mut start = 0usize;
    for (i, byte) in bytes.iter().enumerate() {
        if *byte == b'\n' {
            let end = if i > start && bytes[i - 1] == b'\r' {
                i - 1
            } else {
                i
            };
            spans.push(LineSpan { start, end });
            start = i + 1;
        }
    }
    // 末尾无换行时补最后一行；文本以 `\n` 结尾时补一个空行，保证
    // `line_index_for(text.len())` 仍有合法区间
    spans.push(LineSpan {
        start,
        end: text.len(),
    });
    spans
}

/// 匹配位置所属行下标（文本末尾/空文本落在最后一个区间）
fn line_index_for(spans: &[LineSpan], offset: usize) -> usize {
    spans
        .partition_point(|span| span.start <= offset)
        .saturating_sub(1)
        .min(spans.len().saturating_sub(1))
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

        // 自动检测：前 4KB ASCII → utf-8，中文标题乱码 → 内置规则零命中 →
        // [批1b-3] 按长度分章：4096 ASCII + 38 个替换字符（共 4149 字符
        // > 3000）→ 超限点后最近 \n 在 4095 → 首章 0..4095；尾段 135 字节
        // > 100 → 自成末章（乱码内容按长度切成两章，无丢字）
        let auto = TxtParser::get_chapters(path_str).unwrap();
        assert_eq!(auto.len(), 2, "无覆盖时长文应按默认档位切章: {auto:?}");
        assert_ne!(auto[0].title, "全文");
        assert_eq!(auto[0].start, Some(0));

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

    // ─── [批43] 显式 TXT 目录规则 ─────────────────────────────────────────

    /// 临时目录 + 文件写入（测试内唯一路径，避免并行用例互踩）
    fn write_temp_txt(name: &str, bytes: &[u8]) -> std::path::PathBuf {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "legado_txt_rule_{}_{}_{}",
            std::process::id(),
            n,
            name
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("sample.txt");
        std::fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn test_split_toc_rule_matches_original_format() {
        let (rule, replacement) = split_toc_rule("^第.+章$🫅🈳🏻result");
        assert_eq!(rule.as_deref(), Some("^第.+章$"));
        assert_eq!(replacement, "result");

        // 无分隔符：整串视为规则（兼容手工/旧数据）
        let (rule, replacement) = split_toc_rule("^第.+章$");
        assert_eq!(rule.as_deref(), Some("^第.+章$"));
        assert_eq!(replacement, "");

        // 分隔符左侧为空：原版 rr[0].isEmpty() → 默认规则
        assert_eq!(
            split_toc_rule("🫅🈳🏻only-replacement"),
            (None, "only-replacement".to_string())
        );

        // 空白：默认规则
        assert_eq!(split_toc_rule("   "), (None, String::new()));
        assert_eq!(split_toc_rule(""), (None, String::new()));
    }

    /// [批43b P3-2] 外部 `tocUrl` 原样消费：正则首尾空白不 trim
    /// （原版 `tocUrl.split(spaceChars)[0]` 直接当正则），只按第一个
    /// 分隔符切分，replacement 内含分隔符时原样保留。
    #[test]
    fn test_split_toc_rule_preserves_external_format() {
        let (rule, replacement) = split_toc_rule(r"\s^第.+章$\s🫅🈳🏻x🫅🈳🏻y");
        assert_eq!(
            rule.as_deref(),
            Some(r"\s^第.+章$\s"),
            "外部 tocUrl 的正则首尾空白必须原样保留"
        );
        assert_eq!(
            replacement, "x🫅🈳🏻y",
            "split_once 只按第一个分隔符切分，replacement 内的分隔符原样保留"
        );

        // 无分隔符时整串（含首尾空白）原样作为正则
        let (rule, _) = split_toc_rule(" ^第.+章$ ");
        assert_eq!(rule.as_deref(), Some(" ^第.+章$ "));
    }

    /// 显式规则（含 lookbehind）同时覆盖 UTF-8 / GBK：
    /// 目录标题正确、`used_custom_rule=true`；正文按同一编码切片。
    #[test]
    fn test_custom_rule_parses_utf8_and_gbk() {
        // UTF-8：默认内置规则不认识的「【第X章】」标题
        // 首行留空：lookbehind `(?<=[　\s])` 需要标题前有空白（原版整段
        // 匹配时行首换行即空白，文件第一行则没有）
        let utf8 = "\n【第一章】 开端\n正文一。\n【第二章】 继续\n正文二。\n";
        let path = write_temp_txt("utf8", utf8.as_bytes());
        let outcome = TxtParser::get_chapters_with_rule(
            path.to_str().unwrap(),
            None,
            Some(r"^【第.+章】.*$"),
        )
        .unwrap();
        assert!(outcome.used_custom_rule, "显式规则应命中");
        assert_eq!(outcome.chapters.len(), 2);
        assert_eq!(outcome.chapters[0].title, "【第一章】 开端");
        assert_eq!(outcome.chapters[1].title, "【第二章】 继续");
        let content = TxtParser::get_chapter_content_with_charset(
            path.to_str().unwrap(),
            &outcome.chapters[1],
            None,
        )
        .unwrap();
        assert!(content.contains("正文二"), "{content}");

        // lookbehind（原版默认规则大量使用）在 fancy 引擎下可用
        let lookbehind = TxtParser::get_chapters_with_rule(
            path.to_str().unwrap(),
            None,
            Some(r"(?<=[　\s])【第.+章】.*$"),
        )
        .unwrap();
        assert_eq!(lookbehind.chapters.len(), 2, "{:?}", lookbehind.chapters);
        assert!(lookbehind.used_custom_rule);

        // GBK：显式编码 + 自定义规则
        let (gbk_body, _, _) =
            encoding_rs::GBK.encode("第一章 起始\n正文甲。\n第二章 继续\n正文乙。\n");
        let gbk_path = write_temp_txt("gbk", &gbk_body);
        let gbk = TxtParser::get_chapters_with_rule(
            gbk_path.to_str().unwrap(),
            Some("GBK"),
            Some("^第[一二]章.*$"),
        )
        .unwrap();
        assert!(gbk.used_custom_rule);
        assert_eq!(gbk.chapters.len(), 2, "{:?}", gbk.chapters);
        assert_eq!(gbk.chapters[0].title, "第一章 起始");
        assert_eq!(gbk.chapters[1].title, "第二章 继续");
        let gbk_content = TxtParser::get_chapter_content_with_charset(
            gbk_path.to_str().unwrap(),
            &gbk.chapters[1],
            Some("GBK"),
        )
        .unwrap();
        assert!(gbk_content.contains("正文乙"), "{gbk_content}");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
        let _ = std::fs::remove_dir_all(gbk_path.parent().unwrap());
    }

    /// 规则未命中 / 非法正则 → 回退内置默认规则并标记未使用显式规则
    #[test]
    fn test_custom_rule_falls_back_to_builtin() {
        let text = "第一章 起始\n正文一。\n第二章 继续\n正文二。\n";
        let path = write_temp_txt("fallback", text.as_bytes());
        let path_str = path.to_str().unwrap();

        let no_match =
            TxtParser::get_chapters_with_rule(path_str, None, Some(r"^不存在的标题$")).unwrap();
        assert!(!no_match.used_custom_rule, "未命中必须标记回退");
        assert_eq!(no_match.chapters.len(), 2, "{:?}", no_match.chapters);
        assert_eq!(no_match.chapters[0].title, "第一章 起始");

        let invalid =
            TxtParser::get_chapters_with_rule(path_str, None, Some(r"([unclosed")).unwrap();
        assert!(!invalid.used_custom_rule, "非法正则必须标记回退");
        assert_eq!(invalid.chapters.len(), 2);

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// [批43b P3-3] 零宽/空标题口径：空匹配与纯空白命中跳过（对齐原版
    /// `takeIf { it.isNotEmpty() }`），零宽字符（U+200B）按原版保留。
    #[test]
    fn test_custom_rule_skips_empty_titles_and_keeps_zero_width() {
        // 1) 规则可匹配空串：不得产生空标题章节，回退内置默认
        let text = "第一章 起始\n正文。\n第二章 继续\n正文二。\n";
        let path = write_temp_txt("empty_match", text.as_bytes());
        let path_str = path.to_str().unwrap();
        let empty = TxtParser::get_chapters_with_rule(path_str, None, Some(r"^")).unwrap();
        assert!(!empty.used_custom_rule, "空匹配不得算作有效自定义规则");
        assert_eq!(empty.chapters.len(), 2, "{:?}", empty.chapters);
        assert!(empty.chapters.iter().all(|c| !c.title.is_empty()));

        // 2) 零宽字符标题：trim 不移除 U+200B，按原版原样保留
        let zw = "\u{200B}标题A\n正文。\n\u{200B}标题B\n正文二。\n";
        let zw_path = write_temp_txt("zero_width", zw.as_bytes());
        let zw_outcome = TxtParser::get_chapters_with_rule(
            zw_path.to_str().unwrap(),
            None,
            Some("^\\u{200B}.+$"),
        )
        .unwrap();
        assert!(zw_outcome.used_custom_rule);
        assert_eq!(zw_outcome.chapters.len(), 2, "{:?}", zw_outcome.chapters);
        assert_eq!(zw_outcome.chapters[0].title, "\u{200B}标题A");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
        let _ = std::fs::remove_dir_all(zw_path.parent().unwrap());
    }

    /// CRLF 文件偏移按真实行宽累加：换规则后正文不串行
    #[test]
    fn test_custom_rule_crlf_offsets_are_exact() {
        let text = "第一章 起始\r\n正文一。\r\n第二章 继续\r\n正文二。\r\n";
        let path = write_temp_txt("crlf", text.as_bytes());
        let path_str = path.to_str().unwrap();
        let outcome =
            TxtParser::get_chapters_with_rule(path_str, None, Some(r"^第.+章.*$")).unwrap();
        assert_eq!(outcome.chapters.len(), 2);
        assert!(
            outcome.used_custom_rule,
            "CRLF 文件显式规则命中应标记 used_custom_rule"
        );

        let second_start = text.find("第二章").unwrap() as i64;
        assert_eq!(outcome.chapters[1].start, Some(second_start));
        let first =
            TxtParser::get_chapter_content_with_charset(path_str, &outcome.chapters[0], None)
                .unwrap();
        assert!(first.contains("正文一"), "{first}");
        assert!(!first.contains("正文二"), "首章不得串入下章: {first}");

        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    // ─── [批1b-3] 无目录规则时按长度分章 ─────────────────────────────────

    /// 夹逼口径：None → 3000；范围内原样；越界夹到边界（对齐参考版
    /// `coerceIn(3000, 100000)` 与默认 3000）
    #[test]
    fn test_clamp_max_length_with_no_toc() {
        assert_eq!(clamp_max_length_with_no_toc(None), 3000);
        assert_eq!(clamp_max_length_with_no_toc(Some(3000)), 3000);
        assert_eq!(clamp_max_length_with_no_toc(Some(42_000)), 42_000);
        assert_eq!(clamp_max_length_with_no_toc(Some(100_000)), 100_000);
        // 越界夹到边界
        assert_eq!(clamp_max_length_with_no_toc(Some(0)), 3000);
        assert_eq!(clamp_max_length_with_no_toc(Some(2999)), 3000);
        assert_eq!(clamp_max_length_with_no_toc(Some(100_001)), 100_000);
        assert_eq!(clamp_max_length_with_no_toc(Some(u32::MAX)), 100_000);
    }

    /// 无规则长文按 N 切分：正好 N（单章）、N+1（两章，尾段自成章）
    #[test]
    fn test_parse_by_length_exact_n_and_n_plus_one() {
        // 正好 N 字符（无换行）：单章（尾段 ≤ max，不触发切分）
        let text_n = "字".repeat(3000);
        let chapters = parse_by_length(&text_n, 3000);
        assert_eq!(chapters.len(), 1, "正好 3000 字应为单章: {chapters:?}");
        assert_eq!(chapters[0].start, Some(0));
        assert_eq!(chapters[0].end, None, "end 由调用方回填");

        // N+1 字符：切出首章 + 尾章（尾段 1 字符 > 100 字节？否——1 字符
        // UTF-8 3 字节 ≤ 100，应并入上一章……但首章已满 3000，尾段并入后
        // 首章区间扩为全文。参考版语义：剩余 < max 时不切，尾段并入 → 单章）
        let text_n1 = "字".repeat(3001);
        let chapters = parse_by_length(&text_n1, 3000);
        // 首轮：剩余 3001 > 3000 → 切首章（3000 字，换行不存在 → 硬切到
        // 文本末尾？否——超限点 3000 处无换行 → end = len(9000)）
        // ⚠ 参考版无换行时 end=length：首章吞下全部剩余，cursor=len，
        // 尾段 0 字节 → `text.len() - cursor = 0 > 100` 不成立、chapters
        // 非空 → 不补章。最终单章（区间=全文）。
        assert_eq!(
            chapters.len(),
            1,
            "无换行 N+1：超限点后无换行硬切到末尾，尾段 0 字节并入，应为单章: {chapters:?}"
        );
        assert_eq!(chapters[0].start, Some(0));
    }

    /// 无换行长文硬切：超限点后无换行 → 切到文本末尾（不丢字、不重复）
    #[test]
    fn test_parse_by_length_no_newline_hard_cut() {
        // 3×N 字符无换行：参考版首轮 end=length → 之后 cursor=len 剩余 0
        // → 单章吞全文。这与参考版一致（缓冲场景 end=length 只截断当前
        // 缓冲区，跨缓冲仍会继续；我方整段处理等价于「无换行全吞」）。
        let text = "a".repeat(9000);
        let chapters = parse_by_length(&text, 3000);
        assert_eq!(chapters.len(), 1, "无换行长文应单章吞全文: {chapters:?}");
        assert_eq!(chapters[0].start, Some(0));
    }

    /// 含换行长文：在最近换行处截断，标题/序号/区间正确，换行归下一章
    #[test]
    fn test_parse_by_length_splits_at_newline() {
        // 每行 2000 个汉字（UTF-8 3B/char = 6000 字节）+ \n（行区间 6001 字节）；
        // max=2000 字符：第 1 轮前进 2000 字符 = 行 1 末（6000 字节处），
        // 向后找最近 \n = 6000 → 首章 0..6000（\n 归下一章行首）；
        // 第 2 轮从 6000 起步进 2000 字符（\n+1999 甲）→ 超限点 11998，
        // 最近 \n = 行 2 末（12001）→ 次章 6000..12001；第 3 轮同理 →
        // 末章起点 12001（即行 2 末 \n 之后——该 \n 已计入次章字符预算，
        // 与参考版「\n 计入 strLength 字节预算」的口径一致）；尾段 1 字节
        // ≤ 100 → 并入末章
        let line = "甲".repeat(2000);
        let text = format!("{line}\n{line}\n{line}\n");
        assert_eq!(text.len(), 18003);
        let chapters = parse_by_length(&text, 2000);
        assert_eq!(
            chapters.len(),
            3,
            "3 行 × 2000 字、max 2000 应切 3 章: {chapters:?}"
        );
        // 标题：第1章(1)、第1章(2)、第1章(3)
        assert_eq!(chapters[0].title, "第1章(1)");
        assert_eq!(chapters[1].title, "第1章(2)");
        assert_eq!(chapters[2].title, "第1章(3)");
        assert_eq!(chapters[0].start, Some(0));
        assert_eq!(chapters[1].start, Some(6000));
        assert_eq!(chapters[2].start, Some(12001));
        assert_eq!(chapters[0].end, None, "end 由调用方回填");
    }

    /// 尾段 ≤100 字节并入上一章；>100 字节自成一章（参考版 L457 口径）
    #[test]
    fn test_parse_by_length_tail_merge_and_keep() {
        // 两行各 3000 字符（末行无换行）max=3000：
        // 第 1 轮剩余 6000+1 > 3000 → 超限点 3000 字符处（行 2 开头附近），
        // 向后找 \n = 行 1 末尾 → 首章 = 行 1；第 2 轮剩余 3000 ≤ 3000 → 收尾。
        // 尾段 3001 字节 > 100 → 自成末章。
        let line = "乙".repeat(3000);
        let text = format!("{line}\n{line}");
        let chapters = parse_by_length(&text, 3000);
        assert_eq!(chapters.len(), 2, "尾段 3001 字节应自成一章: {chapters:?}");
        assert_eq!(chapters[0].title, "第1章(1)");
        assert_eq!(chapters[1].title, "第1章(2)");

        // 尾段 ≤100 字节：行 3000 字符 + \n + 尾段 10 字符（30 字节）
        // 第 1 轮剩余 3011 > 3000 → 超限点 3000 → 最近 \n 在 3000 →
        // 首章 = 行 1；剩余 11 字符 ≤ 3000 → 尾段 33 字节 ≤ 100 → 并入首章
        let text2 = format!("{line}\n{}", "丙".repeat(10));
        let chapters2 = parse_by_length(&text2, 3000);
        assert_eq!(
            chapters2.len(),
            1,
            "尾段 ≤100 字节应并入上一章: {:?}",
            chapters2
                .iter()
                .map(|c| (&c.title, c.start))
                .collect::<Vec<_>>()
        );
    }

    /// 多字节中文按字符切分：切点落在字符边界，无 UTF-8 截断乱码
    #[test]
    fn test_parse_by_length_multibyte_char_boundary() {
        // 每行 100 个汉字（UTF-8 300 字节）+ \n；max=150 字符
        // 第 1 轮前进 150 字符 = 行 1（100）+ \n（1）+ 行 2 前 49 字符 →
        // 超限点 448 字节处，向后找最近 \n = 文本末尾 \n（601）→
        // 首章 = 0..601；第 2 轮剩余 1 字符 → 尾段 1 字节 ≤ 100 → 并入首章
        let han_line = "漢".repeat(100);
        let text = format!("{han_line}\n{han_line}\n");
        assert_eq!(text.len(), 602);
        let chapters = parse_by_length(&text, 150);
        assert_eq!(chapters.len(), 1, "尾段并入后应单章: {chapters:?}");
        // 切点必须落在字符边界：start 处可无 panic 地解出字符
        let s = chapters[0].start.unwrap() as usize;
        let c = text[s..].chars().next().unwrap();
        assert_eq!(c, '漢', "切点应落在字符边界: start={s}");
        // 逐章正文解码正确（经公开 API，小档位构造多章）
        let dir = write_temp_txt("len_multibyte", text.as_bytes());
        let outcome =
            TxtParser::get_chapters_with_rule_config(dir.to_str().unwrap(), None, None, 120)
                .unwrap();
        // max=120：第 1 轮前进 120 字符 = 行 1 + \n + 19 字符 → 最近 \n=601
        // → 首章 0..601；剩余 1 字符 → 并入。仍单章，但覆盖边界解码。
        assert_eq!(outcome.chapters.len(), 1);
        let c0 = TxtParser::get_chapter_content_with_charset(
            dir.to_str().unwrap(),
            &outcome.chapters[0],
            None,
        )
        .unwrap();
        assert!(c0.starts_with("漢"), "首章正文应为汉字开头: {c0:?}");
        // 正文仅含汉字与换行（无乱码、无丢字；行间 \n 属正文合法字符）
        assert!(
            !c0.is_empty() && c0.chars().all(|ch| ch == '漢' || ch == '\n'),
            "解码不得有乱码字符: {c0:?}"
        );
        assert_eq!(
            c0.chars().filter(|ch| *ch == '漢').count(),
            200,
            "200 字不丢"
        );
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }

    /// 多字节中文按字符切分（多章形态）：max 小于单行字符数时逐行成章
    #[test]
    fn test_parse_by_length_multibyte_multi_chapters() {
        // 每行 100 个汉字（300 字节）+ \n；max=90 字符（< 行长 100）
        // 第 1 轮前进 90 字符（行 1 中部 270 字节处）→ 最近 \n = 300 →
        // 首章 = 行 1（0..300）；第 2 轮从 \n 位置（300）起步 →
        // 次章起点 = 300（首字符为行 1 末的 \n，参考版 end=换行位、下一章
        // 从该字节起）；第 3 轮剩余 1 字符 → 尾段 ≤ 100 字节并入次章
        let han_line = "漢".repeat(100);
        let text = format!("{han_line}\n{han_line}\n");
        let chapters = parse_by_length(&text, 90);
        assert_eq!(chapters.len(), 2, "{chapters:?}");
        assert_eq!(chapters[0].start, Some(0));
        assert_eq!(chapters[1].start, Some(300), "次章自首章终止点（换行位）起");
        for ch in &chapters {
            let s = ch.start.unwrap() as usize;
            // 切点落在 UTF-8 字符边界（可无 panic 解码即可），首章以汉字开头
            text[s..].chars().next().unwrap();
        }
        assert_eq!(
            text[chapters[0].start.unwrap() as usize..].chars().next(),
            Some('漢')
        );
    }

    /// GBK 编码长文：显式编码 + 长度分章（解码在切分前完成，无 GBK 截断）
    #[test]
    fn test_parse_by_length_gbk_decoded_before_split() {
        // GBK 中文长文：1000 字/行 × 3 行，max=1200 字符（解码后 UTF-8
        // 3B/字：行 = 3000 字节）
        let line = "书".repeat(1000);
        let text = format!("{line}\n{line}\n{line}\n");
        let (bytes, _, _) = encoding_rs::GBK.encode(&text);
        let path = write_temp_txt("len_gbk", &bytes);
        let outcome = TxtParser::get_chapters_with_rule_config(
            path.to_str().unwrap(),
            Some("GBK"),
            None,
            1200,
        )
        .unwrap();
        // 解码后逐字节追踪：第 1 轮前进 1200 字符 = 行 1 + \n + 199 字符 →
        // 最近 \n = 行 2 末（6001）→ 首章 0..6001；第 2 轮剩 \n + 行 3
        // （1001 字符 ≤ 1200）→ 尾段 3002 字节 > 100 → 末章 6001..
        assert_eq!(outcome.chapters.len(), 2, "{:?}", outcome.chapters);
        assert_eq!(outcome.chapters[0].start, Some(0));
        assert_eq!(outcome.chapters[1].start, Some(6001));
        let c1 = TxtParser::get_chapter_content_with_charset(
            path.to_str().unwrap(),
            &outcome.chapters[1],
            Some("GBK"),
        )
        .unwrap();
        assert_eq!(c1.chars().count(), 1000, "末章应为整行 1000 字");
        assert!(c1.chars().all(|ch| ch == '书'), "GBK 解码不得有乱码字符");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// 规则命中时不得再按长度切：显式规则命中 → 长度参数被忽略
    #[test]
    fn test_rule_hit_skips_length_split() {
        // 文本含显式规则标题（内置规则不认识），且各章远超 10 字档位
        let text = "\n【第一篇】 开端\ncontent\n【第二篇】 继续\ncontent\n";
        let path = write_temp_txt("rule_hit", text.as_bytes());
        let outcome = TxtParser::get_chapters_with_rule_config(
            path.to_str().unwrap(),
            None,
            Some(r"^【第.+篇】.*$"),
            10, // 极小档位：命中规则时必须被忽略
        )
        .unwrap();
        assert!(outcome.used_custom_rule);
        assert_eq!(
            outcome.chapters.len(),
            2,
            "规则命中不得按长度切: {outcome:?}"
        );
        assert_eq!(outcome.chapters[0].title, "【第一篇】 开端");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// 内置规则命中时同样不按长度切（无显式规则路径）
    #[test]
    fn test_builtin_rule_hit_skips_length_split() {
        let text = "第一章 起始\ncontent\n第二章 继续\ncontent\n";
        let path = write_temp_txt("builtin_hit", text.as_bytes());
        let outcome = TxtParser::get_chapters_with_rule_config(
            path.to_str().unwrap(),
            None,
            None,
            10, // 极小档位：内置规则命中时必须被忽略
        )
        .unwrap();
        assert_eq!(outcome.chapters.len(), 2, "{:?}", outcome.chapters);
        assert_eq!(outcome.chapters[0].title, "第一章 起始");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// 公开链路：无规则长文按默认档位分章 + used_custom_rule=false +
    /// 区间覆盖全文（首章 start=0、相邻衔接、末章 end 由回填=文件末尾）
    #[test]
    fn test_get_chapters_no_rule_splits_by_length_default() {
        // 每行 1500 个汉字（UTF-8 4500 字节）× 6 行 + \n = 27006 字节；
        // 默认档位 3000 字符：第 1 轮前进 3000 字符 = 行 1+\n+1499 字符 →
        // 最近 \n = 行 2 末（9001）→ 首章 0..9001；依次推进 → 3 章后
        // 剩余 1 字符（\n）→ 尾段并入末章
        // 注：显式传 UTF-8——纯中文 UTF-8 文件前 4KB 采样会在字符中间截断，
        // 既有 detect_encoding 会误判 gb18030（批37b 之前既有口径，非本批
        // 引入），这里锚定「解码正确时的切分边界」而非编码检测。
        let line = "文".repeat(1500);
        let text = format!("{line}\n").repeat(6);
        assert_eq!(text.len(), 27006);
        let path = write_temp_txt("len_default", text.as_bytes());
        let outcome = TxtParser::get_chapters_with_rule_config(
            path.to_str().unwrap(),
            Some("UTF-8"),
            None,
            3000,
        )
        .unwrap();
        assert!(!outcome.used_custom_rule);
        assert_eq!(
            outcome.chapters.len(),
            3,
            "27006 字节默认 3000 字符档位应切 3 章: {:?}",
            outcome
                .chapters
                .iter()
                .map(|c| (&c.title, c.start))
                .collect::<Vec<_>>()
        );
        assert_eq!(outcome.chapters[0].start, Some(0));
        assert_eq!(outcome.chapters[1].start, Some(9001));
        assert_eq!(outcome.chapters[2].start, Some(18003));
        // 回填后区间无缝衔接：章 i 的 end == 章 i+1 的 start；末章 end = 文本末
        let total = text.len() as i64;
        for w in outcome.chapters.windows(2) {
            assert_eq!(w[0].end, w[1].start, "章节区间必须无缝衔接");
        }
        assert_eq!(outcome.chapters[0].start, Some(0));
        assert_eq!(outcome.chapters.last().unwrap().end, Some(total));
        // 全文无丢字：各章区间长度之和 = 总字节数
        let sum: i64 = outcome
            .chapters
            .iter()
            .map(|c| c.end.unwrap() - c.start.unwrap())
            .sum();
        assert_eq!(sum, total, "区间总长必须等于文本长度（不丢字不重复）");
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// 极短文件 / 空文件：不产生多章与空章（极短单章、空文件「全文」兜底）
    #[test]
    fn test_get_chapters_short_and_empty_files() {
        // 极短（< 100 字节）：单章（尾段并入语义下仍保底一章）
        let short = write_temp_txt("short", "短文内容".as_bytes());
        let out =
            TxtParser::get_chapters_with_rule_config(short.to_str().unwrap(), None, None, 3000)
                .unwrap();
        assert_eq!(out.chapters.len(), 1);
        assert_eq!(out.chapters[0].start, Some(0));
        let _ = std::fs::remove_dir_all(short.parent().unwrap());

        // 空文件：既有「全文」单章兜底（EmptyFile 由 FFI 导入层拦截，
        // 解析层保持历史行为）
        let empty = write_temp_txt("empty", b"");
        let out =
            TxtParser::get_chapters_with_rule_config(empty.to_str().unwrap(), None, None, 3000)
                .unwrap();
        assert_eq!(out.chapters.len(), 1);
        assert_eq!(out.chapters[0].title, "全文");
        let _ = std::fs::remove_dir_all(empty.parent().unwrap());
    }
}
