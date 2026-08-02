//! 词典查询 API
//!
//! 提供本地内置词典查询（API_CONTRACT.md §3 需求 4：`dictLookup`）。
//!
//! 设计说明：
//! - 返回结构化释义 [`DictEntry`]（`word` / `phonetic` / `definitions`），
//!   字段对齐 Dart `DictEntry` freezed 模型与冻结契约。
//! - 数据源为 Rust 内置词典（静态数据，UI 占位词典的真超集），
//!   保证离线可用、测试结果确定。
//! - 在线词典规则（`dict_rules` 表 / `DictRuleRepository`）走 URL 模板 + showRule
//!   的原始文本查询（对齐 Kotlin `DictRule.search`），与本结构化本地查询正交，
//!   UI 侧经 `getConfig/setConfig` 持久化并以 URL 跳转呈现，不依赖本契约。
//! - 未收录词返回空 `definitions`（非异常），查询异常经 bridge 统一映射为 BridgeError。

use serde::Serialize;

use legado_core::LegadoResult;

/// 词典条目 DTO
///
/// 序列化字段对齐 Dart `DictEntry` 模型：`word` / `phonetic` / `definitions`。
#[derive(Debug, Clone, Serialize)]
pub struct DictEntry {
    /// 归一化后的单词（trim + 小写）
    pub word: String,
    /// 音标（未收录时为空字符串）
    pub phonetic: String,
    /// 释义条目列表（未收录时为空列表）
    pub definitions: Vec<String>,
}

/// 内置本地词典（UI 占位词典的真超集）
///
/// 每项结构：`(单词, 音标, 释义列表)`。单词均为小写，查询时按归一化键匹配。
static BUILTIN_DICT: &[(&str, &str, &[&str])] = &[
    // ── 与 UI 占位词典一致的 10 个词（保证切换后行为一致）──
    ("chapter", "/ˈtʃæptə(r)/", &["n. 章，章节", "n. （人生的）一段时期"]),
    ("novel", "/ˈnɒvl/", &["n. 长篇小说", "adj. 新奇的，异常的"]),
    ("author", "/ˈɔːθə(r)/", &["n. 作者，作家", "v. 编写，创作"]),
    ("bookmark", "/ˈbʊkmɑːk/", &["n. 书签", "v. 将…加入书签"]),
    ("library", "/ˈlaɪbrəri/", &["n. 图书馆，藏书室", "n. 文库，（软件）库"]),
    ("fiction", "/ˈfɪkʃn/", &["n. 小说，虚构作品", "n. 虚构，想象"]),
    ("prologue", "/ˈprəʊlɒɡ/", &["n. 序言，开场白"]),
    ("epilogue", "/ˈepɪlɒɡ/", &["n. 结语，尾声"]),
    ("paragraph", "/ˈpærəɡrɑːf/", &["n. 段落", "n. （报刊的）短讯"]),
    ("volume", "/ˈvɒljuːm/", &["n. 卷，册", "n. 音量", "n. 体积，容量"]),
    // ── 常见阅读词汇扩充 ──
    ("book", "/bʊk/", &["n. 书，书籍", "v. 预订"]),
    ("read", "/riːd/", &["v. 阅读，朗读", "v. 读懂，理解"]),
    ("story", "/ˈstɔːri/", &["n. 故事，小说", "n. 情节"]),
    ("word", "/wɜːd/", &["n. 单词，词语", "n. 话，言语"]),
    ("translate", "/trænsˈleɪt/", &["v. 翻译，译"]),
    ("dictionary", "/ˈdɪkʃənri/", &["n. 词典，字典"]),
    ("meaning", "/ˈmiːnɪŋ/", &["n. 意义，含义"]),
    ("pronunciation", "/prəˌnʌnsiˈeɪʃn/", &["n. 发音，读音"]),
];

/// 查询单词释义（本地内置词典）
///
/// - 入参 `word` 经 trim + 小写归一化后匹配内置词典。
/// - 命中返回结构化 [`DictEntry`]；未收录返回空 `definitions`（非异常）。
pub fn dict_lookup(word: &str) -> LegadoResult<DictEntry> {
    let key = word.trim().to_lowercase();

    for &(w, phonetic, defs) in BUILTIN_DICT {
        if w == key {
            return Ok(DictEntry {
                word: w.to_string(),
                phonetic: phonetic.to_string(),
                definitions: defs.iter().map(|s| s.to_string()).collect(),
            });
        }
    }

    // 未收录词：返回空 definitions（契约约定非异常）
    Ok(DictEntry {
        word: key,
        phonetic: String::new(),
        definitions: Vec::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_dict_lookup_hit() {
        let entry = dict_lookup("Chapter").unwrap();
        assert_eq!(entry.word, "chapter");
        assert_eq!(entry.phonetic, "/ˈtʃæptə(r)/");
        assert_eq!(entry.definitions.len(), 2);
        assert!(entry.definitions[0].contains("章"));
    }

    #[test]
    fn test_dict_lookup_trims_and_lowercases() {
        let entry = dict_lookup("  NOVEL  ").unwrap();
        assert_eq!(entry.word, "novel");
        assert!(!entry.definitions.is_empty());
    }

    #[test]
    fn test_dict_lookup_miss_returns_empty() {
        let entry = dict_lookup("zzz_unknown_word").unwrap();
        assert_eq!(entry.word, "zzz_unknown_word");
        assert!(entry.phonetic.is_empty());
        assert!(entry.definitions.is_empty());
    }

    #[test]
    fn test_dict_lookup_serialization_fields() {
        let entry = dict_lookup("book").unwrap();
        let json = serde_json::to_value(&entry).unwrap();
        // 字段名对齐 Dart DictEntry 模型
        assert!(json.get("word").is_some());
        assert!(json.get("phonetic").is_some());
        assert!(json.get("definitions").is_some());
        assert!(json["definitions"].is_array());
    }
}
