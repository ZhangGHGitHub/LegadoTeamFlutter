//! 书源口令分享
//!
//! 移植自 Kotlin SourceSharePassphrase.kt
//! 将书源 JSON 编码为可读的中文口令字符串，支持反向解码。

use std::collections::HashMap;

use base64::Engine;

/// 中文混淆映射表（小写字母/数字/符号→中文词）
const CHAR_MAP: &[(&str, &str)] = &[
    ("0", "零"),
    ("1", "一"),
    ("2", "二"),
    ("3", "三"),
    ("4", "四"),
    ("5", "五"),
    ("6", "六"),
    ("7", "七"),
    ("8", "八"),
    ("9", "九"),
    ("a", "甲"),
    ("b", "乙"),
    ("c", "丙"),
    ("d", "丁"),
    ("e", "戊"),
    ("f", "己"),
    ("g", "庚"),
    ("h", "辛"),
    ("i", "壬"),
    ("j", "癸"),
    ("k", "子"),
    ("l", "丑"),
    ("m", "寅"),
    ("n", "卯"),
    ("o", "辰"),
    ("p", "巳"),
    ("q", "午"),
    ("r", "未"),
    ("s", "申"),
    ("t", "酉"),
    ("u", "戌"),
    ("v", "亥"),
    ("w", "乾"),
    ("x", "坤"),
    ("y", "震"),
    ("z", "巽"),
    ("{", "开"),
    ("}", "关"),
    ("[", "左"),
    ("]", "右"),
    (":", "曰"),
    (",", "顿"),
    ("\"", "引"),
];

/// 大写字母映射表（Base64 含大写 A-Z）
const UPPER_MAP: &[(&str, &str)] = &[
    ("A", "天"),
    ("B", "地"),
    ("C", "玄"),
    ("D", "黄"),
    ("E", "宇"),
    ("F", "宙"),
    ("G", "洪"),
    ("H", "荒"),
    ("I", "日"),
    ("J", "月"),
    ("K", "盈"),
    ("L", "昃"),
    ("M", "星"),
    ("N", "宿"),
    ("O", "列"),
    ("P", "张"),
    ("Q", "寒"),
    ("R", "来"),
    ("S", "暑"),
    ("T", "往"),
    ("U", "秋"),
    ("V", "收"),
    ("W", "冬"),
    ("X", "藏"),
    ("Y", "闰"),
    ("Z", "余"),
];

/// 口令前缀
const PREFIX: &str = "书源口令：";

/// 口令编码器
pub struct PassphraseEncoder;

impl PassphraseEncoder {
    /// 编码：书源 JSON → 口令字符串
    pub fn encode(source_json: &str) -> String {
        // 1. Base64 编码 JSON
        let b64 = base64_encode(source_json.as_bytes());
        // 2. 将 Base64 字符通过映射表转换为中文
        let mut result = String::new();
        result.push_str(PREFIX);
        for ch in b64.chars() {
            let ch_str = ch.to_string();
            if let Some((_, cn)) = UPPER_MAP.iter().find(|(k, _)| *k == ch_str.as_str()) {
                result.push_str(cn);
            } else if let Some((_, cn)) = CHAR_MAP.iter().find(|(k, _)| *k == ch_str.as_str()) {
                result.push_str(cn);
            } else if ch == '=' {
                result.push('等');
            } else if ch == '/' {
                result.push('隔');
            } else if ch == '+' {
                result.push('加');
            } else {
                result.push(ch);
            }
        }
        result
    }

    /// 解码：口令字符串 → 书源 JSON
    pub fn decode(passphrase: &str) -> Result<String, String> {
        // 1. 移除前缀 "书源口令："
        let text = passphrase.trim().trim_start_matches(PREFIX).trim();
        // 2. 反向映射：中文 → Base64 字符
        let reverse_map: HashMap<&str, &str> = CHAR_MAP
            .iter()
            .map(|(k, v)| (*v, *k))
            .chain(UPPER_MAP.iter().map(|(k, v)| (*v, *k)))
            .chain([("等", "="), ("隔", "/"), ("加", "+")].iter().copied())
            .collect();

        let mut b64 = String::new();
        // 按中文字符逐字查找
        for ch in text.chars() {
            let ch_str = ch.to_string();
            if let Some(orig) = reverse_map.get(ch_str.as_str()) {
                b64.push_str(orig);
            } else {
                b64.push(ch);
            }
        }
        // 3. Base64 解码
        let bytes = base64_decode(&b64)?;
        String::from_utf8(bytes).map_err(|e| e.to_string())
    }

    /// 检查字符串是否是口令格式
    pub fn is_passphrase(s: &str) -> bool {
        if s.starts_with(PREFIX) {
            return true;
        }
        // 检查是否包含多个映射中的中文字符
        const MARKERS: &[char] = &[
            '零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '甲', '乙', '丙', '丁',
            '戊', '己', '庚', '辛', '壬', '癸',
        ];
        let count = s.chars().filter(|c| MARKERS.contains(c)).count();
        count >= 3
    }
}

/// 导入策略
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ImportPolicy {
    /// 覆盖已有
    Overwrite,
    /// 跳过已存在
    SkipExisting,
    /// 合并
    Merge,
}

impl ImportPolicy {
    /// 从字符串解析导入策略
    pub fn parse(s: &str) -> Self {
        match s.to_lowercase().as_str() {
            "overwrite" | "覆盖" => Self::Overwrite,
            "skip" | "跳过" => Self::SkipExisting,
            _ => Self::Merge,
        }
    }
}

// Base64 辅助函数
fn base64_encode(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

fn base64_decode(s: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(s)
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_roundtrip_simple_json() {
        let json = r#"{"name":"测试书源","url":"https://example.com"}"#;
        let encoded = PassphraseEncoder::encode(json);
        let decoded = PassphraseEncoder::decode(&encoded).unwrap();
        assert_eq!(decoded, json);
    }

    #[test]
    fn test_roundtrip_empty_string() {
        let json = "";
        let encoded = PassphraseEncoder::encode(json);
        let decoded = PassphraseEncoder::decode(&encoded).unwrap();
        assert_eq!(decoded, json);
    }

    #[test]
    fn test_roundtrip_large_json() {
        let json = format!(
            r#"{{"sources":[{}]}}"#,
            (0..100)
                .map(|i| format!(
                    r#"{{"name":"source{}","url":"https://example{}.com"}}"#,
                    i, i
                ))
                .collect::<Vec<_>>()
                .join(",")
        );
        let encoded = PassphraseEncoder::encode(&json);
        let decoded = PassphraseEncoder::decode(&encoded).unwrap();
        assert_eq!(decoded, json);
    }

    #[test]
    fn test_roundtrip_special_characters() {
        let json = r#"{"name":"特殊字符!@#$%^&*()","desc":"包含中文、日文かな、emoji🎉"}"#;
        let encoded = PassphraseEncoder::encode(json);
        let decoded = PassphraseEncoder::decode(&encoded).unwrap();
        assert_eq!(decoded, json);
    }

    #[test]
    fn test_encode_has_prefix() {
        let json = r#"{"name":"test"}"#;
        let encoded = PassphraseEncoder::encode(json);
        assert!(encoded.starts_with("书源口令："));
    }

    #[test]
    fn test_decode_invalid_passphrase() {
        let result = PassphraseEncoder::decode("这不是有效口令");
        assert!(result.is_err());
    }

    #[test]
    fn test_decode_garbage_base64() {
        // 构造一个前缀正确但内容无法解码为 UTF-8 的口令
        let result = PassphraseEncoder::decode("书源口令：加加加加");
        // "加" maps to "+", so "++++" is valid base64 but decodes to non-UTF8 bytes
        assert!(result.is_err());
    }

    #[test]
    fn test_is_passphrase_with_prefix() {
        assert!(PassphraseEncoder::is_passphrase("书源口令：零一甲乙"));
    }

    #[test]
    fn test_is_passphrase_with_markers() {
        assert!(PassphraseEncoder::is_passphrase("一些文字零一甲乙丙"));
    }

    #[test]
    fn test_is_passphrase_negative() {
        assert!(!PassphraseEncoder::is_passphrase("普通文本"));
        assert!(!PassphraseEncoder::is_passphrase("https://example.com"));
        assert!(!PassphraseEncoder::is_passphrase("只有一个零"));
    }

    #[test]
    fn test_import_policy_overwrite() {
        assert_eq!(ImportPolicy::parse("overwrite"), ImportPolicy::Overwrite);
        assert_eq!(ImportPolicy::parse("覆盖"), ImportPolicy::Overwrite);
    }

    #[test]
    fn test_import_policy_skip() {
        assert_eq!(ImportPolicy::parse("skip"), ImportPolicy::SkipExisting);
        assert_eq!(ImportPolicy::parse("跳过"), ImportPolicy::SkipExisting);
    }

    #[test]
    fn test_import_policy_merge_default() {
        assert_eq!(ImportPolicy::parse("merge"), ImportPolicy::Merge);
        assert_eq!(ImportPolicy::parse("unknown"), ImportPolicy::Merge);
        assert_eq!(ImportPolicy::parse(""), ImportPolicy::Merge);
    }

    #[test]
    fn test_roundtrip_nested_json() {
        let json = r#"{"bookSource":{"name":"嵌套","rules":{"content":["//div[@class='read']","//p"]},"enabled":true}}"#;
        let encoded = PassphraseEncoder::encode(json);
        let decoded = PassphraseEncoder::decode(&encoded).unwrap();
        assert_eq!(decoded, json);
    }

    #[test]
    fn test_decode_with_whitespace_trim() {
        let json = r#"{"a":1}"#;
        let encoded = PassphraseEncoder::encode(json);
        let with_spaces = format!("  {}  ", encoded);
        let decoded = PassphraseEncoder::decode(&with_spaces).unwrap();
        assert_eq!(decoded, json);
    }
}
