//! 字符串工具 API
//!
//! 提供字符串处理函数，对应 Kotlin 端 `JsExtensions` 中的字符串方法：
//! - urlencode / urldecode — URL 编码/解码
//! - utf8ToGbk / gbkToUtf8 — 编码转换
//! - trimStart / trimEnd — 去除首尾空白
//! - substringBefore / substringAfter — 子字符串截取
//! - replaceFirst / replaceAll — 字符串替换

// ============================================================
// quickjs feature 启用时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_string_utils {
    use percent_encoding::{percent_decode_str, utf8_percent_encode, NON_ALPHANUMERIC};

    /// URL 编码
    ///
    /// 对应 Kotlin: `URLEncoder.encode(str, "UTF-8")`
    pub fn urlencode(input: &str) -> String {
        utf8_percent_encode(input, NON_ALPHANUMERIC).to_string()
    }

    /// URL 解码
    ///
    /// 对应 Kotlin: `URLDecoder.decode(str, "UTF-8")`
    pub fn urldecode(input: &str) -> String {
        percent_decode_str(input).decode_utf8_lossy().into_owned()
    }

    /// UTF-8 转 GBK 编码
    ///
    /// 返回 GBK 编码的字节数组（以 Vec<u8> 表示）
    pub fn utf8_to_gbk(input: &str) -> Result<Vec<u8>, String> {
        let (cow, _encoding_used, had_errors) = encoding_rs::GBK.encode(input);
        if had_errors {
            Err("Some characters cannot be encoded to GBK".to_string())
        } else {
            Ok(cow.into_owned())
        }
    }

    /// GBK 转 UTF-8 编码
    ///
    /// 输入为 GBK 字节数组，返回 UTF-8 字符串
    pub fn gbk_to_utf8(input: &[u8]) -> Result<String, String> {
        let (cow, _encoding_used, had_errors) = encoding_rs::GBK.decode(input);
        if had_errors {
            Err("Some bytes cannot be decoded from GBK".to_string())
        } else {
            Ok(cow.into_owned())
        }
    }

    /// 去除字符串开头空白
    pub fn trim_start(input: &str) -> String {
        input.trim_start().to_string()
    }

    /// 去除字符串末尾空白
    pub fn trim_end(input: &str) -> String {
        input.trim_end().to_string()
    }

    /// 返回第一个分隔符之前的子串
    ///
    /// 对应 Kotlin: `StringUtils.substringBefore(s, delimiter)`
    pub fn substring_before<'a>(input: &'a str, delimiter: &str) -> &'a str {
        match input.find(delimiter) {
            Some(pos) => &input[..pos],
            None => input,
        }
    }

    /// 返回第一个分隔符之后的子串
    ///
    /// 对应 Kotlin: `StringUtils.substringAfter(s, delimiter)`
    pub fn substring_after<'a>(input: &'a str, delimiter: &str) -> &'a str {
        match input.find(delimiter) {
            Some(pos) => &input[pos + delimiter.len()..],
            None => input,
        }
    }

    /// 替换第一个匹配项
    pub fn replace_first(input: &str, old: &str, new: &str) -> String {
        match input.find(old) {
            Some(pos) => {
                let mut result = String::with_capacity(input.len());
                result.push_str(&input[..pos]);
                result.push_str(new);
                result.push_str(&input[pos + old.len()..]);
                result
            }
            None => input.to_string(),
        }
    }

    /// 替换所有匹配项
    pub fn replace_all(input: &str, old: &str, new: &str) -> String {
        input.replace(old, new)
    }
}

#[cfg(feature = "quickjs")]
pub use impl_string_utils::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_string_utils {
    fn not_available() -> String {
        "string_utils not available: build with --features quickjs".to_string()
    }

    pub fn urlencode(_input: &str) -> String {
        not_available()
    }
    pub fn urldecode(_input: &str) -> String {
        not_available()
    }
    pub fn utf8_to_gbk(_input: &str) -> Result<Vec<u8>, String> {
        Err(not_available())
    }
    pub fn gbk_to_utf8(_input: &[u8]) -> Result<String, String> {
        Err(not_available())
    }
    pub fn trim_start(_input: &str) -> String {
        not_available()
    }
    pub fn trim_end(_input: &str) -> String {
        not_available()
    }
    pub fn substring_before<'a>(input: &'a str, _delimiter: &str) -> &'a str {
        input
    }
    pub fn substring_after<'a>(input: &'a str, _delimiter: &str) -> &'a str {
        input
    }
    pub fn replace_first(_input: &str, _old: &str, _new: &str) -> String {
        not_available()
    }
    pub fn replace_all(_input: &str, _old: &str, _new: &str) -> String {
        not_available()
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_string_utils::*;

// ============================================================
// 单元测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;

    #[test]
    fn test_urlencode_basic() {
        assert_eq!(urlencode("hello world"), "hello%20world");
    }

    #[test]
    fn test_urldecode_basic() {
        assert_eq!(urldecode("hello%20world"), "hello world");
    }

    #[test]
    fn test_urlencode_roundtrip() {
        let original = "https://example.com/path?q=测试&lang=zh";
        let encoded = urlencode(original);
        let decoded = urldecode(&encoded);
        assert_eq!(decoded, original);
    }

    #[test]
    fn test_utf8_gbk_roundtrip() {
        let original = "你好世界";
        let gbk_bytes = utf8_to_gbk(original).unwrap();
        let back = gbk_to_utf8(&gbk_bytes).unwrap();
        assert_eq!(back, original);
    }

    #[test]
    fn test_trim_start() {
        assert_eq!(trim_start("  hello"), "hello");
        assert_eq!(trim_start("\n\thello"), "hello");
    }

    #[test]
    fn test_trim_end() {
        assert_eq!(trim_end("hello  "), "hello");
        assert_eq!(trim_end("hello\n\t"), "hello");
    }

    #[test]
    fn test_substring_before() {
        assert_eq!(substring_before("hello-world-test", "-"), "hello");
        assert_eq!(substring_before("hello", "-"), "hello");
    }

    #[test]
    fn test_substring_after() {
        assert_eq!(substring_after("hello-world-test", "-"), "world-test");
        assert_eq!(substring_after("hello", "-"), "hello");
    }

    #[test]
    fn test_replace_first() {
        assert_eq!(replace_first("aabbcc", "b", "X"), "aaXbcc");
    }

    #[test]
    fn test_replace_all() {
        assert_eq!(replace_all("aabbcc", "b", "X"), "aaXXcc");
    }
}

// ============================================================
// toNumChapter — 中文数字章节号转阿拉伯数字（无外部依赖）
// ============================================================

/// 中文数字字符映射表
fn chinese_digit_value(c: char) -> Option<i64> {
    match c {
        '零' | '〇' => Some(0),
        '一' | '壹' | '幺' => Some(1),
        '二' | '贰' | '两' => Some(2),
        '三' | '叁' => Some(3),
        '四' | '肆' => Some(4),
        '五' | '伍' => Some(5),
        '六' | '陆' => Some(6),
        '七' | '柒' => Some(7),
        '八' | '捌' => Some(8),
        '九' | '玖' => Some(9),
        '十' | '拾' => Some(10),
        '百' | '佰' => Some(100),
        '千' | '仟' => Some(1000),
        '万' => Some(10000),
        '亿' => Some(100_000_000),
        _ => None,
    }
}

/// 将中文数字字符串转换为阿拉伯数字
///
/// 支持: "一零二五" 形式（逐位）和 "一千零二十五" 形式（权值）
fn chinese_num_to_int(s: &str) -> Option<i64> {
    let chars: Vec<char> = s.chars().collect();
    if chars.is_empty() {
        return None;
    }

    // 检查是否全部为基本数字字符（无十百千万亿），即 "一零二五" 形式
    let all_basic = chars.iter().all(|&c| {
        matches!(
            c,
            '零' | '〇'
                | '一'
                | '壹'
                | '幺'
                | '二'
                | '贰'
                | '两'
                | '三'
                | '叁'
                | '四'
                | '肆'
                | '五'
                | '伍'
                | '六'
                | '陆'
                | '七'
                | '柒'
                | '八'
                | '捌'
                | '九'
                | '玖'
        )
    });

    if all_basic && chars.len() > 1 {
        // 逐位拼接: "一零二五" → 1025
        let mut result: i64 = 0;
        for &c in &chars {
            result = result * 10 + chinese_digit_value(c)?;
        }
        return Some(result);
    }

    // 权值形式: "一千零二十五", "一百二十三", "十一", "二十" 等
    let mut result: i64 = 0;
    let mut tmp: i64 = 0;
    let mut billion: i64 = 0;

    for (i, &c) in chars.iter().enumerate() {
        let val = chinese_digit_value(c)?;
        if val == 100_000_000 {
            // 亿
            result += tmp;
            result *= val;
            billion = billion * 100_000_000 + result;
            result = 0;
            tmp = 0;
        } else if val == 10000 {
            // 万
            result += tmp;
            result *= val;
            tmp = 0;
        } else if val >= 10 {
            // 十、百、千
            if tmp == 0 {
                tmp = 1;
            }
            result += val * tmp;
            tmp = 0;
        } else {
            // 基本数字 0-9
            // 处理 "一千二" 省略形式：末位且前一位 > 10
            if i >= 2 && i == chars.len() - 1 {
                if let Some(prev_val) = chinese_digit_value(chars[i - 1]) {
                    if prev_val > 10 {
                        tmp = val * prev_val / 10;
                    } else {
                        tmp = tmp * 10 + val;
                    }
                } else {
                    tmp = tmp * 10 + val;
                }
            } else {
                tmp = tmp * 10 + val;
            }
        }
    }
    result += tmp + billion;
    Some(result)
}

/// 全角转半角
fn full_to_half(input: &str) -> String {
    input
        .chars()
        .map(|c| {
            let code = c as u32;
            if code == 12288 {
                // 全角空格
                ' '
            } else if (65281..=65374).contains(&code) {
                // 全角字符转半角
                char::from_u32(code - 65248).unwrap_or(c)
            } else {
                c
            }
        })
        .collect()
}

/// 字符串转数字（先尝试直接解析，失败则尝试中文数字转换）
fn string_to_int(s: &str) -> i64 {
    let normalized = full_to_half(s).replace(|c: char| c.is_whitespace(), "");
    if let Ok(n) = normalized.parse::<i64>() {
        return n;
    }
    chinese_num_to_int(&normalized).unwrap_or(-1)
}

/// toNumChapter(s) — 中文数字章节号转阿拉伯数字
///
/// 对应 Kotlin: `JsExtensions.toNumChapter(s)`
/// 模式: 匹配 "第...章"，将中间部分转为阿拉伯数字
/// 例如: "第一百二十三章" → "第123章"
///       "第三卷 第一百章" → "第三卷 第100章"
pub fn to_num_chapter(s: &str) -> String {
    // 查找 "第" 和 "章" 的位置（非贪婪匹配第一对）
    let chars: Vec<(usize, char)> = s.char_indices().collect();
    let mut i = 0;
    while i < chars.len() {
        if chars[i].1 == '第' {
            // 从 "第" 之后寻找最近的 "章"
            let start = i + 1;
            let mut j = start;
            while j < chars.len() {
                if chars[j].1 == '章' {
                    // 提取中间部分
                    let byte_start = chars[start].0;
                    let byte_end = chars[j].0;
                    let middle = &s[byte_start..byte_end];
                    if !middle.is_empty() {
                        let num = string_to_int(middle);
                        if num >= 0 {
                            // 构建结果: 前缀 + "第" + 数字 + "章" + 后缀
                            let prefix = &s[..chars[i].0];
                            let suffix_byte = chars[j].0 + '章'.len_utf8();
                            let suffix = &s[suffix_byte..];
                            return format!("{}第{}章{}", prefix, num, suffix);
                        }
                    }
                    break;
                }
                j += 1;
            }
        }
        i += 1;
    }
    s.to_string()
}

#[cfg(test)]
mod tests_num_chapter {
    use super::*;

    #[test]
    fn test_to_num_chapter_basic() {
        assert_eq!(to_num_chapter("第一百二十三章"), "第123章");
    }

    #[test]
    fn test_to_num_chapter_simple() {
        assert_eq!(to_num_chapter("第一章"), "第1章");
        assert_eq!(to_num_chapter("第十章"), "第10章");
        assert_eq!(to_num_chapter("第十一章"), "第11章");
    }

    #[test]
    fn test_to_num_chapter_twenty() {
        assert_eq!(to_num_chapter("第二十章"), "第20章");
    }

    #[test]
    fn test_to_num_chapter_hundred() {
        assert_eq!(to_num_chapter("第一百章"), "第100章");
        assert_eq!(to_num_chapter("第三百零五章"), "第305章");
    }

    #[test]
    fn test_to_num_chapter_thousand() {
        assert_eq!(to_num_chapter("第一千零二十五章"), "第1025章");
        assert_eq!(to_num_chapter("第一千二百章"), "第1200章");
    }

    #[test]
    fn test_to_num_chapter_with_prefix() {
        assert_eq!(to_num_chapter("第三卷 第一百章"), "第三卷 第100章");
    }

    #[test]
    fn test_to_num_chapter_no_match() {
        assert_eq!(to_num_chapter("没有章节号"), "没有章节号");
        assert_eq!(to_num_chapter(""), "");
    }

    #[test]
    fn test_to_num_chapter_already_arabic() {
        assert_eq!(to_num_chapter("第123章"), "第123章");
    }

    #[test]
    fn test_chinese_num_to_int_sequence() {
        assert_eq!(chinese_num_to_int("一零二五"), Some(1025));
    }

    #[test]
    fn test_chinese_num_to_int_weighted() {
        assert_eq!(chinese_num_to_int("十一"), Some(11));
        assert_eq!(chinese_num_to_int("二十"), Some(20));
        assert_eq!(chinese_num_to_int("一百二十三"), Some(123));
        assert_eq!(chinese_num_to_int("一千零二十五"), Some(1025));
    }

    #[test]
    fn test_chinese_num_to_int_abbreviated() {
        // "一千二" = 1200 (省略形式)
        assert_eq!(chinese_num_to_int("一千二"), Some(1200));
    }
}
