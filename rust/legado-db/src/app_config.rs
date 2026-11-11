//! 跨进程共享的正文净化配置（caches 表 `config:` 键）
//!
//! App（`legado-ffi`）与 Web 服务（`legado-server`）打开同一个 SQLite 文件：
//! 设置页把净化相关配置写入 caches 表 `config:` 前缀，Web 进程直接读同一张
//! 表，因此两端正文净化使用**同一份真实配置**，而不是 Web 侧常量。
//!
//! 键名与 Kotlin 原版 `PreferKey` 同名，跨端备份可互通：
//! - `chineseConverterType`：0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t；
//! - `replaceEnableDefault`：缺省/非法 → `true`；`"false"`/`"0"` → `false`；
//! - `sameTitleRemoved:{bookUrl}:{chapterIndex}`：值 `"1"` = 该章 opt-out
//!   （保留原始标题），无键/其他值 = 去除重复标题（全局默认）。

use rusqlite::Connection;

use legado_core::LegadoResult;

use crate::repository::cache_repository::CacheRepository;

/// 配置键前缀（caches 表 KV，与 `legado-ffi::config_api` 同口径）
pub const CONFIG_PREFIX: &str = "config:";

/// 繁简转换类型配置短键（对齐 Kotlin `PreferKey.chineseConverterType`）
pub const CHINESE_CONVERT_TYPE_KEY: &str = "chineseConverterType";

/// 默认启用替换净化配置短键（对齐 Kotlin `PreferKey.replaceEnableDefault`）
pub const REPLACE_ENABLE_DEFAULT_KEY: &str = "replaceEnableDefault";

/// 章级「删除重复标题」开关存储键前缀（caches 表 KV，零迁移）
pub const SAME_TITLE_REMOVED_KEY_PREFIX: &str = "sameTitleRemoved:";

/// 拼接 `config:` 前缀的完整 caches 键
pub fn config_key(short_key: &str) -> String {
    format!("{CONFIG_PREFIX}{short_key}")
}

/// 章级「删除重复标题」开关的 caches 键
///
/// 键格式：`sameTitleRemoved:{book_url}:{chapter_index}`。
pub fn same_title_removed_key(book_url: &str, chapter_index: i32) -> String {
    format!("{SAME_TITLE_REMOVED_KEY_PREFIX}{book_url}:{chapter_index}")
}

/// 解析繁简转换类型：非数字/越界 → 0（不转换）
///
/// 与 `legado-ffi::reader::get_chinese_convert_type` 既有口径一致：
/// **不 trim**、只接受 `0..=2`。
pub fn parse_chinese_convert_type(raw: Option<&str>) -> i32 {
    raw.and_then(|v| v.parse::<i32>().ok())
        .filter(|t| (0..=2).contains(t))
        .unwrap_or(0)
}

/// 繁简转换类型 → 正文管线方向（`None` / `"t2s"` / `"s2t"`）
pub fn chinese_convert_direction(convert_type: i32) -> Option<String> {
    match convert_type {
        1 => Some("t2s".to_string()),
        2 => Some("s2t".to_string()),
        _ => None,
    }
}

/// 解析「默认启用替换净化」
///
/// 缺省/空串/非法 → `true`；`"false"` / `"0"`（忽略大小写与首尾空白）→ `false`；
/// 其余 → `true`。与 Android `AppConfig.replaceEnableDefault`
/// （`getPrefBoolean(PreferKey.replaceEnableDefault, true)`）语义一致。
pub fn parse_replace_enable_default(raw: Option<&str>) -> bool {
    match raw {
        Some(raw) => !matches!(raw.trim().to_lowercase().as_str(), "false" | "0"),
        None => true,
    }
}

/// 解析章级「删除重复标题」开关值
///
/// 值 `"1"` = 该章 opt-out（返回 `false`）；无键/其他值 = 去除（返回 `true`）。
pub fn parse_same_title_removed(raw: Option<&str>) -> bool {
    !matches!(raw, Some("1"))
}

/// 正文净化配置快照（caches 表来源的配置面）
///
/// `re_segment` 不在此结构内：它来自书籍行 `readConfig.reSegment`，
/// 由调用方从已加载的 `Book` 读取。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentPurifyConfig {
    /// 简繁转换方向（`None` / `"t2s"` / `"s2t"`）
    pub chinese_convert: Option<String>,
    /// 全局默认启用替换净化
    pub replace_enable_default: bool,
    /// 该章是否去除重复标题
    pub remove_duplicate_title: bool,
}

impl ContentPurifyConfig {
    /// 默认配置（与 App 缺省值一致，用于配置读取失败回退）
    pub fn defaults() -> Self {
        Self {
            chinese_convert: None,
            replace_enable_default: true,
            remove_duplicate_title: true,
        }
    }
}

impl Default for ContentPurifyConfig {
    fn default() -> Self {
        Self::defaults()
    }
}

/// 读取正文净化配置（Web 与 App 共用同一套键名与解析口径）
///
/// 任一配置行读取失败 → `Err`，由调用方回退 [`ContentPurifyConfig::defaults`]
/// 并记录告警；不把「读库失败」静默当成某项配置的合法值。
pub fn load_content_purify_config(
    conn: &Connection,
    book_url: &str,
    chapter_index: i32,
) -> LegadoResult<ContentPurifyConfig> {
    let repo = CacheRepository::new(conn);
    let chinese_raw = repo.get(&config_key(CHINESE_CONVERT_TYPE_KEY))?;
    let replace_raw = repo.get(&config_key(REPLACE_ENABLE_DEFAULT_KEY))?;
    let same_title_raw = repo.get(&same_title_removed_key(book_url, chapter_index))?;

    Ok(ContentPurifyConfig {
        chinese_convert: chinese_convert_direction(parse_chinese_convert_type(
            chinese_raw.as_deref(),
        )),
        replace_enable_default: parse_replace_enable_default(replace_raw.as_deref()),
        remove_duplicate_title: parse_same_title_removed(same_title_raw.as_deref()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init_in_memory_database;

    #[test]
    fn test_parse_chinese_convert_type() {
        assert_eq!(parse_chinese_convert_type(None), 0);
        assert_eq!(parse_chinese_convert_type(Some("")), 0);
        assert_eq!(parse_chinese_convert_type(Some("0")), 0);
        assert_eq!(parse_chinese_convert_type(Some("1")), 1);
        assert_eq!(parse_chinese_convert_type(Some("2")), 2);
        assert_eq!(parse_chinese_convert_type(Some("3")), 0);
        assert_eq!(parse_chinese_convert_type(Some("-1")), 0);
        assert_eq!(parse_chinese_convert_type(Some("abc")), 0);
        // 与 App 既有口径一致：不 trim
        assert_eq!(parse_chinese_convert_type(Some(" 1 ")), 0);
    }

    #[test]
    fn test_parse_replace_enable_default() {
        for raw in [
            None,
            Some(""),
            Some("true"),
            Some("TRUE"),
            Some("1"),
            Some("abc"),
        ] {
            assert!(
                parse_replace_enable_default(raw),
                "raw={raw:?} 应解析为 true"
            );
        }
        for raw in [
            Some("false"),
            Some("False"),
            Some("0"),
            Some(" false "),
            Some(" 0 "),
        ] {
            assert!(
                !parse_replace_enable_default(raw),
                "raw={raw:?} 应解析为 false"
            );
        }
    }

    #[test]
    fn test_parse_same_title_removed() {
        assert!(parse_same_title_removed(None));
        assert!(parse_same_title_removed(Some("0")));
        assert!(!parse_same_title_removed(Some("1")));
        // 仅精确 "1" 视为 opt-out
        assert!(parse_same_title_removed(Some(" 1")));
    }

    #[test]
    fn test_load_content_purify_config_defaults_when_absent() {
        let db = init_in_memory_database().unwrap();
        let loaded = load_content_purify_config(db.connection(), "https://a.book", 3).unwrap();
        assert_eq!(loaded, ContentPurifyConfig::defaults());
    }

    #[test]
    fn test_load_content_purify_config_reads_shared_keys() {
        let db = init_in_memory_database().unwrap();
        let repo = CacheRepository::new(db.connection());
        repo.put(&config_key(CHINESE_CONVERT_TYPE_KEY), "1", 0)
            .unwrap();
        repo.put(&config_key(REPLACE_ENABLE_DEFAULT_KEY), "false", 0)
            .unwrap();
        repo.put(&same_title_removed_key("https://a.book", 3), "1", 0)
            .unwrap();

        let loaded = load_content_purify_config(db.connection(), "https://a.book", 3).unwrap();
        assert_eq!(
            loaded,
            ContentPurifyConfig {
                chinese_convert: Some("t2s".to_string()),
                replace_enable_default: false,
                remove_duplicate_title: false,
            }
        );

        // 其他章节不受该章开关影响（默认去除）
        let other = load_content_purify_config(db.connection(), "https://a.book", 4).unwrap();
        assert!(other.remove_duplicate_title);
    }

    #[test]
    fn test_load_content_purify_config_errors_when_table_missing() {
        let db = init_in_memory_database().unwrap();
        db.connection()
            .execute("DROP TABLE caches", [])
            .expect("删除 caches 表");
        assert!(load_content_purify_config(db.connection(), "https://a.book", 0).is_err());
    }
}
