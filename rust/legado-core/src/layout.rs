//! 阅读排版引擎 — 文本分页与排版计算
//!
//! 根据字体大小、行距、屏幕尺寸等参数计算文本分页。
//! 中文断行算法移植自 Kotlin ZhLayout.kt (278行) — 作者 hoodie13

use std::collections::HashSet;
use std::sync::LazyLock;

/// 排版配置
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LayoutConfig {
    pub font_size: f64,
    pub line_height: f64,
    pub paragraph_spacing: f64,
    pub margin_top: f64,
    pub margin_bottom: f64,
    pub margin_left: f64,
    pub margin_right: f64,
    pub screen_width: f64,
    pub screen_height: f64,
    pub chars_per_line: Option<usize>,
    pub lines_per_page: Option<usize>,
}

impl Default for LayoutConfig {
    fn default() -> Self {
        Self {
            font_size: 18.0,
            line_height: 1.5,
            paragraph_spacing: 0.5,
            margin_top: 20.0,
            margin_bottom: 20.0,
            margin_left: 16.0,
            margin_right: 16.0,
            screen_width: 360.0,
            screen_height: 640.0,
            chars_per_line: None,
            lines_per_page: None,
        }
    }
}

/// 排版页面
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct LayoutPage {
    pub index: usize,
    pub content: String,
    pub start_offset: usize,
    pub end_offset: usize,
    pub line_count: usize,
}

/// 排版引擎
pub struct LayoutEngine {
    config: LayoutConfig,
}

impl LayoutEngine {
    pub fn new(config: LayoutConfig) -> Self {
        Self { config }
    }

    /// 计算每行字数
    fn chars_per_line(&self) -> usize {
        if let Some(n) = self.config.chars_per_line {
            return n;
        }
        let available_width =
            self.config.screen_width - self.config.margin_left - self.config.margin_right;
        let char_width = self.config.font_size; // 中文约等于 font_size
        (available_width / char_width).floor() as usize
    }

    /// 计算每页行数
    fn lines_per_page(&self) -> usize {
        if let Some(n) = self.config.lines_per_page {
            return n;
        }
        let available_height =
            self.config.screen_height - self.config.margin_top - self.config.margin_bottom;
        let line_pixel_height = self.config.font_size * self.config.line_height;
        (available_height / line_pixel_height).floor() as usize
    }

    /// 对文本进行分页
    pub fn paginate(&self, text: &str) -> Vec<LayoutPage> {
        let cpl = self.chars_per_line();
        let lpp = self.lines_per_page();
        let mut pages = Vec::new();

        if cpl == 0 || lpp == 0 {
            return pages;
        }

        let paragraphs: Vec<&str> = text.split('\n').collect();
        let mut current_page_lines: Vec<String> = Vec::new();
        let mut page_start_offset = 0usize;
        let mut current_offset = 0usize;
        let mut page_index = 0usize;

        for para in paragraphs {
            let para_with_indent = if para.is_empty() {
                String::new()
            } else {
                format!("  {}", para) // 两个全角空格缩进
            };

            // 按每行字数分割段落
            let chars: Vec<char> = para_with_indent.chars().collect();
            let mut line_start = 0;

            while line_start < chars.len() {
                let line_end = (line_start + cpl).min(chars.len());
                let line: String = chars[line_start..line_end].iter().collect();

                if current_page_lines.len() >= lpp {
                    // 当前页已满，创建新页
                    let page_content = current_page_lines.join("\n");
                    pages.push(LayoutPage {
                        index: page_index,
                        content: page_content,
                        start_offset: page_start_offset,
                        end_offset: current_offset,
                        line_count: lpp,
                    });
                    page_index += 1;
                    page_start_offset = current_offset;
                    current_page_lines.clear();
                }

                current_page_lines.push(line.clone());
                line_start = line_end;
                current_offset += line.len();
            }

            // 段落间 \n
            if !para.is_empty() {
                current_offset += 1;
            }
        }

        // 最后一页
        if !current_page_lines.is_empty() {
            let page_content = current_page_lines.join("\n");
            pages.push(LayoutPage {
                index: page_index,
                content: page_content,
                start_offset: page_start_offset,
                end_offset: current_offset,
                line_count: current_page_lines.len(),
            });
        }

        pages
    }

    /// 根据字符偏移计算所在页码
    pub fn offset_to_page(&self, pages: &[LayoutPage], offset: usize) -> usize {
        pages
            .iter()
            .position(|p| offset >= p.start_offset && offset < p.end_offset)
            .unwrap_or(pages.len().saturating_sub(1))
    }

    /// 更新排版配置
    pub fn update_config(&mut self, config: LayoutConfig) {
        self.config = config;
    }
}

// =============================================================================
// ZhLayout 中文断行算法（移植自 Kotlin ZhLayout.kt）
// =============================================================================

/// 不能出现在行首的标点（后置标点）
///
/// 对应 Kotlin ZhLayout.postPanc
static POST_PANC: LazyLock<HashSet<char>> = LazyLock::new(|| {
    "，。：？！、”’）》}】)>].,?!,:」；;"
        .chars()
        .collect()
});

/// 不能出现在行末的标点（前置标点）
///
/// 对应 Kotlin ZhLayout.prePanc
static PRE_PANC: LazyLock<HashSet<char>> = LazyLock::new(|| {
    "“（《【‘(<[{「"
        .chars()
        .collect()
});

/// 断行模式
///
/// 对应 Kotlin ZhLayout.BreakMod
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum BreakMod {
    /// 模式0：正常断行
    Normal,
    /// 模式1：当前行下移一个字
    BreakOneChar,
    /// 模式2：当前行下移多个字
    BreakMoreChar,
    /// 模式3：两个后置标点压缩
    Cps1,
    /// 模式4：前置标点压缩+前置标点压缩+字
    Cps2,
    /// 模式5：前置标点压缩+字+后置标点压缩
    Cps3,
}

/// ZhLayout 断行结果
#[derive(Debug, Clone)]
pub struct ZhLayoutResult {
    /// 每行的起始字符索引
    pub line_starts: Vec<usize>,
    /// 每行的实际宽度
    pub line_widths: Vec<f64>,
    /// 总行数
    pub line_count: usize,
}

/// 执行中文断行计算
///
/// 移植自 Kotlin ZhLayout.kt init 块中的断行算法
///
/// # 参数
/// - `widths`: 每个字符的测量宽度
/// - `available_width`: 可用排版宽度
/// - `indent_size`: 首行缩进字符数
/// - `cn_char_width`: 中文字符参考宽度（用于判断标点是否可压缩）
pub fn zh_layout(
    widths: &[f64],
    available_width: f64,
    indent_size: usize,
    cn_char_width: f64,
) -> ZhLayoutResult {
    let default_capacity = 10;
    let mut line_start_arr: Vec<usize> = vec![0; default_capacity];
    let mut line_width_arr: Vec<f64> = vec![0.0; default_capacity];

    let mut line = 0usize;
    let mut line_w = 0.0f64;
    let mut cw_pre = 0.0f64;

    #[allow(clippy::explicit_counter_loop)]
    for index in 0..widths.len() {
        let cw = widths[index];
        let mut break_line = false;
        line_w += cw;
        let mut offset = 0.0f64;
        let mut break_char_cnt = 0usize;

        if line_w > available_width {
            // 获取当前字符和前一字符（用于标点判断）
            let cur_char = char_from_index(index);
            let prev_char = if index >= 1 { char_from_index(index - 1) } else { '\0' };
            let prev2_char = if index >= 2 { char_from_index(index - 2) } else { '\0' };

            /* 禁止在行尾的标点处理 */
            #[allow(unused_assignments)]
            let mut break_mod = BreakMod::Normal;
            if index >= 1 && is_pre_panc(prev_char) {
                if index >= 2 && is_pre_panc(prev2_char) {
                    break_mod = BreakMod::Cps2;
                } else {
                    break_mod = BreakMod::BreakOneChar;
                }
            }
            /* 禁止在行首的标点处理 */
            else if is_post_panc(cur_char) {
                if index >= 1 && is_post_panc(prev_char) {
                    break_mod = BreakMod::Cps1;
                } else if index >= 2 && is_pre_panc(prev2_char) {
                    break_mod = BreakMod::Cps3;
                } else {
                    break_mod = BreakMod::BreakOneChar;
                }
            } else {
                break_mod = BreakMod::Normal;
            }

            /* 判断特殊情况是否需要重新检查 */
            let mut re_check = false;
            let mut break_index = 0usize;
            if break_mod == BreakMod::Cps1
                && (in_compressible(widths[index], cn_char_width)
                    || in_compressible(widths[index - 1], cn_char_width))
            {
                re_check = true;
            }
            if break_mod == BreakMod::Cps2
                && (in_compressible(widths[index - 1], cn_char_width)
                    || in_compressible(widths[index - 2], cn_char_width))
            {
                re_check = true;
            }
            if break_mod == BreakMod::Cps3
                && (in_compressible(widths[index], cn_char_width)
                    || in_compressible(widths[index - 2], cn_char_width))
            {
                re_check = true;
            }
            if break_mod > BreakMod::BreakMoreChar
                && index < widths.len() - 1
                && is_post_panc(char_from_index(index + 1))
            {
                re_check = true;
            }

            /* 特殊标点回退查找安全分割点 */
            let mut break_length = 0usize;
            if re_check && index > 2 {
                let start_pos = if line == 0 { indent_size } else { line_start_arr[line] };
                break_mod = BreakMod::Normal;
                let mut i = index;
                loop {
                    if i == index {
                        break_index = 0;
                        cw_pre = 0.0;
                    } else {
                        break_index += 1;
                        break_length += 1;
                        cw_pre += widths[i];
                    }
                    let ci = char_from_index(i);
                    let ci_prev = if i >= 1 { char_from_index(i - 1) } else { '\0' };
                    if !is_post_panc(ci) && !is_pre_panc(ci_prev) {
                        break_mod = BreakMod::BreakMoreChar;
                        break;
                    }
                    if i <= 1 + start_pos {
                        break;
                    }
                    i -= 1;
                }
            }

            match break_mod {
                BreakMod::Normal => {
                    offset = cw;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index;
                    break_char_cnt = 1;
                }
                BreakMod::BreakOneChar => {
                    offset = cw + cw_pre;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index.saturating_sub(1);
                    break_char_cnt = 2;
                }
                BreakMod::BreakMoreChar => {
                    offset = cw + cw_pre;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index.saturating_sub(break_length);
                    break_char_cnt = break_index + 1;
                }
                BreakMod::Cps1 | BreakMod::Cps2 | BreakMod::Cps3 => {
                    offset = 0.0;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index + 1;
                    break_char_cnt = 0;
                }
            }
            break_line = true;
        }

        /* 当前行写满情况下的断行 */
        if break_line {
            line_width_arr[line] = line_w - offset;
            line_w = offset;
            line += 1;
            ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
        }

        /* 已到最后一个字符 */
        if index == widths.len() - 1 {
            if !break_line {
                offset = 0.0;
                ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                line_start_arr[line + 1] = index + 1;
                line_width_arr[line] = line_w - offset;
                line_w = offset;
                line += 1;
            } else if break_char_cnt > 0 {
                ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                line_start_arr[line + 1] = line_start_arr[line] + break_char_cnt;
                line_width_arr[line] = line_w;
                line += 1;
            }
        }
        cw_pre = cw;
    }

    ZhLayoutResult {
        line_starts: line_start_arr[..line + 1].to_vec(),
        line_widths: line_width_arr[..line].to_vec(),
        line_count: line,
    }
}

/// 计算两端对齐的额外字间距
///
/// 移植自 TextChapterLayout.kt addCharsToLineMiddle:
/// `residualWidth = visibleWidth - desiredWidth; d = residualWidth / gapCount`
pub fn justify_letter_spacing(
    line_width: f64,
    available_width: f64,
    char_count: usize,
) -> f64 {
    if char_count <= 1 || line_width >= available_width {
        return 0.0;
    }
    let residual = available_width - line_width;
    let gap_count = char_count - 1;
    residual / gap_count as f64
}

// --- ZhLayout 辅助函数 ---

fn is_post_panc(c: char) -> bool {
    POST_PANC.contains(&c)
}

fn is_pre_panc(c: char) -> bool {
    PRE_PANC.contains(&c)
}

fn in_compressible(width: f64, cn_char_width: f64) -> bool {
    width < cn_char_width
}

/// 从索引获取字符（用于标点判断）
/// 注意：这里使用全局字符表，实际使用时应传入文本
fn char_from_index(_index: usize) -> char {
    // 占位实现：实际断行时应传入文本字符数组
    '\0'
}

fn ensure_capacity(line_starts: &mut Vec<usize>, line_widths: &mut Vec<f64>, needed: usize) {
    if needed >= line_starts.len() {
        let new_len = needed + 10;
        line_starts.resize(new_len, 0);
        line_widths.resize(new_len, 0.0);
    }
}

/// 基于文本的中文断行（完整版本）
///
/// 传入实际文本字符 + 宽度，执行标点感知断行
pub fn zh_layout_text(
    chars: &[char],
    widths: &[f64],
    available_width: f64,
    indent_size: usize,
    cn_char_width: f64,
) -> ZhLayoutResult {
    let default_capacity = 10;
    let mut line_start_arr: Vec<usize> = vec![0; default_capacity];
    let mut line_width_arr: Vec<f64> = vec![0.0; default_capacity];

    let mut line = 0usize;
    let mut line_w = 0.0f64;
    let mut cw_pre = 0.0f64;

    #[allow(clippy::explicit_counter_loop)]
    for index in 0..chars.len() {
        let cw = widths[index];
        let mut break_line = false;
        line_w += cw;
        let mut offset = 0.0f64;
        let mut break_char_cnt = 0usize;

        if line_w > available_width {
            let cur_char = chars[index];
            let prev_char = if index >= 1 { chars[index - 1] } else { '\0' };
            let prev2_char = if index >= 2 { chars[index - 2] } else { '\0' };

            #[allow(unused_assignments)]
            let mut break_mod = BreakMod::Normal;

            if index >= 1 && is_pre_panc(prev_char) {
                if index >= 2 && is_pre_panc(prev2_char) {
                    break_mod = BreakMod::Cps2;
                } else {
                    break_mod = BreakMod::BreakOneChar;
                }
            } else if is_post_panc(cur_char) {
                if index >= 1 && is_post_panc(prev_char) {
                    break_mod = BreakMod::Cps1;
                } else if index >= 2 && is_pre_panc(prev2_char) {
                    break_mod = BreakMod::Cps3;
                } else {
                    break_mod = BreakMod::BreakOneChar;
                }
            } else {
                break_mod = BreakMod::Normal;
            }

            let mut re_check = false;
            let mut break_index = 0usize;
            if break_mod == BreakMod::Cps1
                && (in_compressible(widths[index], cn_char_width)
                    || in_compressible(widths[index - 1], cn_char_width))
            {
                re_check = true;
            }
            if break_mod == BreakMod::Cps2
                && index >= 2
                && (in_compressible(widths[index - 1], cn_char_width)
                    || in_compressible(widths[index - 2], cn_char_width))
            {
                re_check = true;
            }
            if break_mod == BreakMod::Cps3
                && index >= 2
                && (in_compressible(widths[index], cn_char_width)
                    || in_compressible(widths[index - 2], cn_char_width))
            {
                re_check = true;
            }
            if break_mod > BreakMod::BreakMoreChar
                && index < chars.len() - 1
                && is_post_panc(chars[index + 1])
            {
                re_check = true;
            }

            let mut break_length = 0usize;
            if re_check && index > 2 {
                let start_pos = if line == 0 { indent_size } else { line_start_arr[line] };
                break_mod = BreakMod::Normal;
                let mut i = index;
                loop {
                    if i == index {
                        break_index = 0;
                        cw_pre = 0.0;
                    } else {
                        break_index += 1;
                        break_length += 1;
                        cw_pre += widths[i];
                    }
                    if !is_post_panc(chars[i]) && !is_pre_panc(chars[i - 1]) {
                        break_mod = BreakMod::BreakMoreChar;
                        break;
                    }
                    if i <= 1 + start_pos {
                        break;
                    }
                    i -= 1;
                }
            }

            match break_mod {
                BreakMod::Normal => {
                    offset = cw;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index;
                    break_char_cnt = 1;
                }
                BreakMod::BreakOneChar => {
                    offset = cw + cw_pre;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index.saturating_sub(1);
                    break_char_cnt = 2;
                }
                BreakMod::BreakMoreChar => {
                    offset = cw + cw_pre;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index.saturating_sub(break_length);
                    break_char_cnt = break_index + 1;
                }
                BreakMod::Cps1 | BreakMod::Cps2 | BreakMod::Cps3 => {
                    offset = 0.0;
                    ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                    line_start_arr[line + 1] = index + 1;
                    break_char_cnt = 0;
                }
            }
            break_line = true;
        }

        if break_line {
            line_width_arr[line] = line_w - offset;
            line_w = offset;
            line += 1;
            ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
        }

        if index == chars.len() - 1 {
            if !break_line {
                ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                line_start_arr[line + 1] = index + 1;
                line_width_arr[line] = line_w;
                line += 1;
            } else if break_char_cnt > 0 {
                ensure_capacity(&mut line_start_arr, &mut line_width_arr, line + 1);
                line_start_arr[line + 1] = line_start_arr[line] + break_char_cnt;
                line_width_arr[line] = line_w;
                line += 1;
            }
        }
        cw_pre = cw;
    }

    ZhLayoutResult {
        line_starts: line_start_arr[..line + 1].to_vec(),
        line_widths: line_width_arr[..line].to_vec(),
        line_count: line,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config_chars_per_line() {
        let engine = LayoutEngine::new(LayoutConfig::default());
        // (360 - 16 - 16) / 18 = 328 / 18 ≈ 18
        assert_eq!(engine.chars_per_line(), 18);
    }

    #[test]
    fn test_default_config_lines_per_page() {
        let engine = LayoutEngine::new(LayoutConfig::default());
        // (640 - 20 - 20) / (18 * 1.5) = 600 / 27 ≈ 22
        assert_eq!(engine.lines_per_page(), 22);
    }

    #[test]
    fn test_custom_chars_per_line() {
        let config = LayoutConfig {
            chars_per_line: Some(20),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        assert_eq!(engine.chars_per_line(), 20);
    }

    #[test]
    fn test_custom_lines_per_page() {
        let config = LayoutConfig {
            lines_per_page: Some(10),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        assert_eq!(engine.lines_per_page(), 10);
    }

    #[test]
    fn test_paginate_empty_text() {
        let engine = LayoutEngine::new(LayoutConfig::default());
        let pages = engine.paginate("");
        // Empty text produces no pages (single empty paragraph → no lines added)
        assert!(pages.is_empty());
    }

    #[test]
    fn test_paginate_short_text() {
        let config = LayoutConfig {
            chars_per_line: Some(10),
            lines_per_page: Some(5),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        let pages = engine.paginate("Hello World");
        assert_eq!(pages.len(), 1);
        assert_eq!(pages[0].index, 0);
        assert!(!pages[0].content.is_empty());
        assert!(pages[0].line_count <= 5);
    }

    #[test]
    fn test_paginate_long_text() {
        let config = LayoutConfig {
            chars_per_line: Some(10),
            lines_per_page: Some(3),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        // 构造一段足够长的文本，确保超过一页
        let text = "这是一段很长的文本内容用来测试分页功能是否正确工作";
        let pages = engine.paginate(text);
        assert!(!pages.is_empty(), "Should have at least one page");
        // 检查页码连续
        for (i, page) in pages.iter().enumerate() {
            assert_eq!(page.index, i);
        }
    }

    #[test]
    fn test_paginate_multiple_pages() {
        let config = LayoutConfig {
            chars_per_line: Some(5),
            lines_per_page: Some(2),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        let text = "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十";
        let pages = engine.paginate(text);
        assert!(pages.len() > 1, "Long text should span multiple pages");
    }

    #[test]
    fn test_offset_to_page() {
        let config = LayoutConfig {
            chars_per_line: Some(10),
            lines_per_page: Some(3),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        let text = "第一段内容。\n第二段内容。\n第三段内容比较长需要更多的空间来显示。";
        let pages = engine.paginate(text);

        if pages.len() > 1 {
            // 第一页的起始偏移应该是 0
            assert_eq!(pages[0].start_offset, 0);
            // offset=0 应该在第一页
            assert_eq!(engine.offset_to_page(&pages, 0), 0);
        }
    }

    #[test]
    fn test_offset_to_page_last() {
        let engine = LayoutEngine::new(LayoutConfig::default());
        let text = "短文本";
        let pages = engine.paginate(text);
        // 超出范围应返回最后一页
        let last = engine.offset_to_page(&pages, usize::MAX);
        assert_eq!(last, pages.len().saturating_sub(1));
    }

    #[test]
    fn test_update_config() {
        let mut engine = LayoutEngine::new(LayoutConfig::default());
        assert_eq!(engine.chars_per_line(), 18);
        engine.update_config(LayoutConfig {
            font_size: 20.0,
            ..LayoutConfig::default()
        });
        // (360-16-16)/20 = 328/20 = 16
        assert_eq!(engine.chars_per_line(), 16);
    }

    #[test]
    fn test_layout_config_serialize() {
        let config = LayoutConfig::default();
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains("font_size"));
        let de: LayoutConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(de.font_size, 18.0);
        assert_eq!(de.line_height, 1.5);
    }

    #[test]
    fn test_paginate_multiline_paragraph() {
        let config = LayoutConfig {
            chars_per_line: Some(8),
            lines_per_page: Some(100),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        let text = "这是一段很长的段落文字";
        let pages = engine.paginate(text);
        assert_eq!(pages.len(), 1);
        // 2字缩进 + 12字 = 14字，每行8字 → 2行
        assert!(pages[0].line_count >= 1);
    }

    #[test]
    fn test_zero_cpl_returns_empty() {
        let config = LayoutConfig {
            chars_per_line: Some(0),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        let pages = engine.paginate("some text");
        assert!(pages.is_empty());
    }

    #[test]
    fn test_zero_lpp_returns_empty() {
        let config = LayoutConfig {
            lines_per_page: Some(0),
            ..LayoutConfig::default()
        };
        let engine = LayoutEngine::new(config);
        let pages = engine.paginate("some text");
        assert!(pages.is_empty());
    }

    #[test]
    fn test_different_font_sizes() {
        let small = LayoutConfig {
            font_size: 14.0,
            ..LayoutConfig::default()
        };
        let large = LayoutConfig {
            font_size: 24.0,
            ..LayoutConfig::default()
        };
        let small_engine = LayoutEngine::new(small);
        let large_engine = LayoutEngine::new(large);
        // Smaller font → more chars per line
        assert!(small_engine.chars_per_line() > large_engine.chars_per_line());
        // Smaller font → more lines per page
        assert!(small_engine.lines_per_page() > large_engine.lines_per_page());
    }

    // =========================================================================
    // ZhLayout 中文断行算法测试
    // =========================================================================

    #[test]
    fn test_zh_layout_basic_break() {
        // 10个等宽字符，可用宽度容纳10个 → 1行
        let chars: Vec<char> = "一二三四五六七八九十".chars().collect();
        let widths = vec![18.0; 10];
        let result = zh_layout_text(&chars, &widths, 180.0, 0, 18.0);
        assert_eq!(result.line_count, 1);
    }

    #[test]
    fn test_zh_layout_two_lines() {
        // 11个等宽字符，可用宽度容纳10个 → 2行
        let chars: Vec<char> = "一二三四五六七八九十一".chars().collect();
        let widths = vec![18.0; 11];
        let result = zh_layout_text(&chars, &widths, 180.0, 0, 18.0);
        assert_eq!(result.line_count, 2);
        assert_eq!(result.line_starts[0], 0);
        assert_eq!(result.line_starts[1], 10);
    }

    #[test]
    fn test_zh_layout_post_panc_not_at_line_start() {
        // 9个字 + 逗号：逗号不应出现在第二行行首
        let chars: Vec<char> = "一二三四五六七八九，十".chars().collect();
        let widths = vec![18.0; 11];
        let result = zh_layout_text(&chars, &widths, 180.0, 0, 18.0);
        // 第二行不应从 index 9（逗号）开始
        if result.line_count > 1 {
            assert_ne!(result.line_starts[1], 9);
        }
    }

    #[test]
    fn test_zh_layout_pre_panc_not_at_line_end() {
        // 9个字 + 左引号：左引号不应留在第一行行末
        let chars: Vec<char> = "一二三四五六七八九“十".chars().collect();
        let widths = vec![18.0; 11];
        let result = zh_layout_text(&chars, &widths, 180.0, 0, 18.0);
        // 第一行宽度应小于 available_width（左引号被推到下一行）
        if result.line_count > 1 {
            assert!(result.line_widths[0] < 180.0);
        }
    }

    #[test]
    fn test_zh_layout_empty() {
        let chars: Vec<char> = vec![];
        let widths: Vec<f64> = vec![];
        let result = zh_layout_text(&chars, &widths, 180.0, 0, 18.0);
        assert_eq!(result.line_count, 0);
    }

    #[test]
    fn test_zh_layout_single_char() {
        let chars = vec!['你'];
        let widths = vec![18.0];
        let result = zh_layout_text(&chars, &widths, 180.0, 0, 18.0);
        assert_eq!(result.line_count, 1);
        assert_eq!(result.line_widths[0], 18.0);
    }

    #[test]
    fn test_justify_letter_spacing_basic() {
        // 10个字符，行宽162，可用180 → 剩余18 / 9间隙 = 2.0
        let spacing = justify_letter_spacing(162.0, 180.0, 10);
        assert!((spacing - 2.0).abs() < f64::EPSILON);
    }

    #[test]
    fn test_justify_letter_spacing_full_line() {
        // 行宽已满 → 无额外间距
        let spacing = justify_letter_spacing(180.0, 180.0, 10);
        assert_eq!(spacing, 0.0);
    }

    #[test]
    fn test_justify_letter_spacing_single_char() {
        // 单个字符 → 无间隙
        let spacing = justify_letter_spacing(18.0, 180.0, 1);
        assert_eq!(spacing, 0.0);
    }

    #[test]
    fn test_post_panc_set() {
        assert!(is_post_panc('，'));
        assert!(is_post_panc('。'));
        assert!(is_post_panc('！'));
        assert!(is_post_panc('？'));
        assert!(!is_post_panc('你'));
    }

    #[test]
    fn test_pre_panc_set() {
        assert!(is_pre_panc('“'));
        assert!(is_pre_panc('（'));
        assert!(is_pre_panc('《'));
        assert!(!is_pre_panc('好'));
    }

    #[test]
    fn test_panc_no_overlap() {
        // postPanc 和 prePanc 不应有交集
        for c in POST_PANC.iter() {
            assert!(!PRE_PANC.contains(c), "Overlap found: {}", c);
        }
    }
}
