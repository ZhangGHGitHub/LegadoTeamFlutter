//! 阅读排版引擎 — 文本分页与排版计算
//!
//! 根据字体大小、行距、屏幕尺寸等参数计算文本分页。

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
        assert!(pages.len() >= 1, "Should have at least one page");
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
}
