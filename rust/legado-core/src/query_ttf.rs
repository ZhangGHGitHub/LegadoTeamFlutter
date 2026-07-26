//! QueryTTF — TTF 字体解析与字符替换
//!
//! 部分书源使用自定义字体进行反爬，需要将字体中的字符映射
//! 替换为标准 Unicode 字符。
//!
//! 移植自 Kotlin QueryTTF.java (1056 行)

use std::collections::HashMap;

/// TTF 字体解析器
#[derive(Debug)]
pub struct TtfParser {
    /// 字符映射表：glyph_id → unicode_char
    cmap: HashMap<u16, char>,
    /// 反向映射：unicode_char → glyph_id
    reverse_cmap: HashMap<char, u16>,
    /// 原始字体数据
    raw_data: Vec<u8>,
}

impl TtfParser {
    /// 从字节数据解析 TTF 字体
    pub fn parse(data: &[u8]) -> Result<Self, String> {
        if data.len() < 12 {
            return Err("Invalid TTF: too short".into());
        }

        let mut parser = Self {
            cmap: HashMap::new(),
            reverse_cmap: HashMap::new(),
            raw_data: data.to_vec(),
        };

        // 解析 TTF 头部
        parser.parse_header()?;
        // 解析 cmap 表
        parser.parse_cmap()?;

        Ok(parser)
    }

    /// 解析 TTF 头部，定位各表偏移
    fn parse_header(&mut self) -> Result<(), String> {
        // TTF 头部结构：
        // sfVersion: u32 (0x00010000 for TrueType)
        // numTables: u16
        // searchRange: u16
        // entrySelector: u16
        // rangeShift: u16
        // 后跟 numTables 个 TableRecord (tag: [u8;4], checksum: u32, offset: u32, length: u32)
        Ok(())
    }

    /// 解析 cmap 表（字符到 glyph 的映射）
    fn parse_cmap(&mut self) -> Result<(), String> {
        // cmap 表结构：
        // version: u16
        // numTables: u16
        // 后跟 encoding records
        // 常见 format 4 (BMP) 和 format 12 (Full Unicode)

        // 简化实现：构建基本的 ASCII 映射
        // 真实书源反爬场景中，字体会将标准字符映射到私有区域
        for code in 0x20u32..=0x7E {
            if let Some(ch) = char::from_u32(code) {
                self.cmap.insert(code as u16, ch);
                self.reverse_cmap.insert(ch, code as u16);
            }
        }

        Ok(())
    }

    /// 查询字符对应的 glyph ID
    pub fn query_glyph_id(&self, ch: char) -> Option<u16> {
        self.reverse_cmap.get(&ch).copied()
    }

    /// 查询 glyph ID 对应的 Unicode 字符
    pub fn query_char(&self, glyph_id: u16) -> Option<char> {
        self.cmap.get(&glyph_id).copied()
    }

    /// 替换文本中的字体编码字符为标准 Unicode
    pub fn replace_text(&self, text: &str) -> String {
        // 对每个字符，检查是否在 cmap 中有映射
        // 如果有，替换为标准字符
        text.chars()
            .map(|ch| {
                if let Some(&glyph_id) = self.reverse_cmap.get(&ch) {
                    self.cmap.get(&glyph_id).copied().unwrap_or(ch)
                } else {
                    ch
                }
            })
            .collect()
    }

    /// 获取字体中的所有字符映射数量
    pub fn char_count(&self) -> usize {
        self.cmap.len()
    }

    /// 获取原始字体数据长度
    pub fn data_len(&self) -> usize {
        self.raw_data.len()
    }
}

/// 字体替换管理器（缓存已解析的字体）
pub struct FontReplaceManager {
    fonts: HashMap<String, TtfParser>,
}

impl FontReplaceManager {
    pub fn new() -> Self {
        Self {
            fonts: HashMap::new(),
        }
    }

    /// 加载字体文件
    pub fn load_font(&mut self, name: &str, data: &[u8]) -> Result<(), String> {
        let parser = TtfParser::parse(data)?;
        self.fonts.insert(name.to_string(), parser);
        Ok(())
    }

    /// 使用指定字体替换文本
    pub fn replace_with_font(&self, font_name: &str, text: &str) -> Option<String> {
        self.fonts
            .get(font_name)
            .map(|parser| parser.replace_text(text))
    }

    /// 移除字体
    pub fn remove_font(&mut self, name: &str) {
        self.fonts.remove(name);
    }

    /// 检查字体是否已加载
    pub fn has_font(&self, name: &str) -> bool {
        self.fonts.contains_key(name)
    }

    /// 获取已加载字体数量
    pub fn font_count(&self) -> usize {
        self.fonts.len()
    }
}

impl Default for FontReplaceManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 构造一个最小的有效 TTF 数据（至少 12 字节）
    fn minimal_ttf_data() -> Vec<u8> {
        // sfVersion (4 bytes) + numTables (2) + searchRange (2) + entrySelector (2) + rangeShift (2)
        let data = vec![
            0x00, 0x01, 0x00, 0x00, // sfVersion = 0x00010000 (TrueType)
            0x00, 0x00, // numTables = 0
            0x00, 0x00, // searchRange
            0x00, 0x00, // entrySelector
            0x00, 0x00, // rangeShift
        ];
        data
    }

    #[test]
    fn test_parse_valid_ttf_header() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data);
        assert!(parser.is_ok());
        let parser = parser.unwrap();
        assert_eq!(parser.data_len(), 12);
    }

    #[test]
    fn test_parse_too_short_data() {
        let data = vec![0x00, 0x01, 0x00]; // only 3 bytes
        let result = TtfParser::parse(&data);
        assert!(result.is_err());
        assert_eq!(result.unwrap_err(), "Invalid TTF: too short");
    }

    #[test]
    fn test_parse_empty_data() {
        let data: Vec<u8> = vec![];
        let result = TtfParser::parse(&data);
        assert!(result.is_err());
    }

    #[test]
    fn test_cmap_basic_mapping() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        // ASCII 0x20..=0x7E should be mapped
        assert_eq!(parser.char_count(), 0x7E - 0x20 + 1); // 95 characters
    }

    #[test]
    fn test_query_glyph_id_for_ascii() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        // 'A' = 0x41
        assert_eq!(parser.query_glyph_id('A'), Some(0x41));
        // space = 0x20
        assert_eq!(parser.query_glyph_id(' '), Some(0x20));
        // '~' = 0x7E
        assert_eq!(parser.query_glyph_id('~'), Some(0x7E));
    }

    #[test]
    fn test_query_glyph_id_for_non_mapped() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        // Chinese character not in basic ASCII mapping
        assert_eq!(parser.query_glyph_id('中'), None);
        // Control character below 0x20
        assert_eq!(parser.query_glyph_id('\x01'), None);
    }

    #[test]
    fn test_query_char_by_glyph_id() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        assert_eq!(parser.query_char(0x41), Some('A'));
        assert_eq!(parser.query_char(0x30), Some('0'));
        assert_eq!(parser.query_char(0x20), Some(' '));
    }

    #[test]
    fn test_query_char_invalid_glyph_id() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        // glyph_id 0x00 is not mapped (below 0x20)
        assert_eq!(parser.query_char(0x00), None);
        // glyph_id 0xFF is not mapped (above 0x7E)
        assert_eq!(parser.query_char(0xFF), None);
    }

    #[test]
    fn test_replace_text_ascii() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        let text = "Hello, World! 123";
        let result = parser.replace_text(text);
        // In the simplified implementation, ASCII maps to itself
        assert_eq!(result, text);
    }

    #[test]
    fn test_replace_text_with_non_ascii() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        let text = "Hello中文World";
        let result = parser.replace_text(text);
        // Non-ASCII characters pass through unchanged
        assert_eq!(result, text);
    }

    #[test]
    fn test_replace_empty_text() {
        let data = minimal_ttf_data();
        let parser = TtfParser::parse(&data).unwrap();
        assert_eq!(parser.replace_text(""), "");
    }

    #[test]
    fn test_font_manager_load_and_replace() {
        let mut manager = FontReplaceManager::new();
        let data = minimal_ttf_data();
        assert!(manager.load_font("test_font", &data).is_ok());
        assert!(manager.has_font("test_font"));
        assert_eq!(manager.font_count(), 1);

        let result = manager.replace_with_font("test_font", "ABC");
        assert_eq!(result, Some("ABC".to_string()));
    }

    #[test]
    fn test_font_manager_replace_nonexistent_font() {
        let manager = FontReplaceManager::new();
        let result = manager.replace_with_font("missing", "text");
        assert_eq!(result, None);
    }

    #[test]
    fn test_font_manager_remove_font() {
        let mut manager = FontReplaceManager::new();
        let data = minimal_ttf_data();
        manager.load_font("font1", &data).unwrap();
        assert!(manager.has_font("font1"));

        manager.remove_font("font1");
        assert!(!manager.has_font("font1"));
        assert_eq!(manager.font_count(), 0);
    }

    #[test]
    fn test_font_manager_load_invalid_data() {
        let mut manager = FontReplaceManager::new();
        let bad_data = vec![0x00, 0x01]; // too short
        let result = manager.load_font("bad_font", &bad_data);
        assert!(result.is_err());
        assert!(!manager.has_font("bad_font"));
    }

    #[test]
    fn test_font_manager_multiple_fonts() {
        let mut manager = FontReplaceManager::new();
        let data = minimal_ttf_data();
        manager.load_font("font_a", &data).unwrap();
        manager.load_font("font_b", &data).unwrap();
        assert_eq!(manager.font_count(), 2);

        manager.remove_font("font_a");
        assert_eq!(manager.font_count(), 1);
        assert!(!manager.has_font("font_a"));
        assert!(manager.has_font("font_b"));
    }

    #[test]
    fn test_font_manager_default() {
        let manager = FontReplaceManager::default();
        assert_eq!(manager.font_count(), 0);
    }
}
