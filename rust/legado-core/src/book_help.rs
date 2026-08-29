//! 书名/作者清洗（对齐原版 `BookHelp.formatBookName` / `formatBookAuthor`）
//!
//! 搜索列表解析后必须清洗，否则「作者：天蚕土豆」与「天蚕土豆」无法按
//! name+author 聚合，同源徽标会明显偏少。

use regex::Regex;
use std::sync::OnceLock;

/// 书名清洗：去「 作者xxx」「 xx 著」后缀并 trim
///
/// 对齐 `AppPattern.nameRegex = "\\s+作\\s*者.*|\\s+\\S+\\s+著"`。
pub fn format_book_name(name: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re =
        RE.get_or_init(|| Regex::new(r"\s+作\s*者.*|\s+\S+\s+著").expect("nameRegex 编译失败"));
    re.replace_all(name, "").trim().to_string()
}

/// 作者清洗：去「作者:xxx」前缀、「 xx 著」后缀并 trim
///
/// 对齐 `AppPattern.authorRegex = "^\\s*作\\s*者[:：\\s]+|\\s+著"`。
pub fn format_book_author(author: &str) -> String {
    static RE: OnceLock<Regex> = OnceLock::new();
    let re =
        RE.get_or_init(|| Regex::new(r"^\s*作\s*者[:：\s]+|\s+著").expect("authorRegex 编译失败"));
    re.replace_all(author, "").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_book_name_strips_author_suffix() {
        assert_eq!(format_book_name("斗破苍穹 作者天蚕土豆"), "斗破苍穹");
        assert_eq!(format_book_name("凡人修仙传 忘语 著"), "凡人修仙传");
        assert_eq!(format_book_name("  神墓  "), "神墓");
        assert_eq!(format_book_name("斗破苍穹"), "斗破苍穹");
    }

    #[test]
    fn test_format_book_author_strips_prefix_suffix() {
        assert_eq!(format_book_author("作者:天蚕土豆"), "天蚕土豆");
        assert_eq!(format_book_author("作者： 忘语"), "忘语");
        assert_eq!(format_book_author("天蚕土豆 著"), "天蚕土豆");
        assert_eq!(format_book_author("  猫腻  "), "猫腻");
        assert_eq!(format_book_author("天蚕土豆"), "天蚕土豆");
    }
}
