//! 默认数据导入
//! 移植自 Kotlin DefaultData.kt (140行)
//!
//! 支持从 JSON 文件/字符串导入以下默认数据：
//! - HttpTTS: 在线朗读引擎
//! - TxtTocRule: TXT 目录规则
//! - RssSources: RSS 订阅源
//! - DictRules: 字典规则
//! - CoverRule: 封面规则
//! - KeyboardAssists: 键盘辅助

use serde::{Deserialize, Serialize};

/// 默认数据类型
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DefaultDataType {
    HttpTts,
    TxtTocRule,
    RssSources,
    DictRules,
    CoverRule,
    KeyboardAssists,
}

impl std::fmt::Display for DefaultDataType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::HttpTts => "HttpTts",
            Self::TxtTocRule => "TxtTocRule",
            Self::RssSources => "RssSources",
            Self::DictRules => "DictRules",
            Self::CoverRule => "CoverRule",
            Self::KeyboardAssists => "KeyboardAssists",
        };
        write!(f, "{s}")
    }
}

/// 导入结果
#[derive(Debug, Clone)]
pub struct ImportResult {
    pub data_type: DefaultDataType,
    pub imported: usize,
    pub skipped: usize,
    pub errors: Vec<String>,
}

impl ImportResult {
    /// 总处理条目数
    pub fn total(&self) -> usize {
        self.imported + self.skipped + self.errors.len()
    }

    /// 是否全部成功（无错误）
    pub fn is_success(&self) -> bool {
        self.errors.is_empty()
    }
}

/// 默认数据管理器
pub struct DefaultDataManager;

impl DefaultDataManager {
    /// 确保所有默认数据表存在
    pub fn ensure_tables(conn: &rusqlite::Connection) -> Result<(), String> {
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS httpTTS (
                id INTEGER NOT NULL,
                name TEXT NOT NULL DEFAULT '',
                url TEXT NOT NULL DEFAULT '',
                contentType TEXT,
                pauseDuration INTEGER NOT NULL DEFAULT 0,
                concurrentRate TEXT DEFAULT '0',
                loginUrl TEXT,
                loginUi TEXT,
                loginCheckJs TEXT,
                header TEXT,
                jsLib TEXT,
                enabledCookieJar INTEGER DEFAULT 0,
                lastUpdateTime INTEGER NOT NULL DEFAULT 0,
                isEnabled INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY(id)
            );
            CREATE TABLE IF NOT EXISTS dictRules (
                name TEXT NOT NULL,
                urlRule TEXT NOT NULL DEFAULT '',
                showRule TEXT NOT NULL DEFAULT '',
                enabled INTEGER NOT NULL DEFAULT 1,
                sortNumber INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(name)
            );
            CREATE TABLE IF NOT EXISTS keyboardAssists (
                type INTEGER NOT NULL DEFAULT 0,
                key TEXT NOT NULL DEFAULT '',
                value TEXT NOT NULL DEFAULT '',
                serialNumber INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(type, key)
            );
            CREATE TABLE IF NOT EXISTS coverRules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL DEFAULT '',
                rule TEXT NOT NULL DEFAULT '',
                enable INTEGER NOT NULL DEFAULT 1
            );",
        )
        .map_err(|e| format!("创建默认数据表失败: {e}"))?;
        Ok(())
    }

    /// 从 JSON 文件导入默认数据
    pub fn import_from_file(
        conn: &rusqlite::Connection,
        data_type: DefaultDataType,
        json_path: &str,
    ) -> Result<ImportResult, String> {
        let content =
            std::fs::read_to_string(json_path).map_err(|e| format!("读取文件失败: {e}"))?;
        Self::import_from_json(conn, data_type, &content)
    }

    /// 从 JSON 字符串导入
    pub fn import_from_json(
        conn: &rusqlite::Connection,
        data_type: DefaultDataType,
        json_content: &str,
    ) -> Result<ImportResult, String> {
        Self::ensure_tables(conn)?;

        // CoverRule 可能是单个对象而非数组
        let items: Vec<serde_json::Value> = if data_type == DefaultDataType::CoverRule {
            let val: serde_json::Value =
                serde_json::from_str(json_content).map_err(|e| format!("JSON 解析失败: {e}"))?;
            if val.is_array() {
                val.as_array().unwrap().clone()
            } else {
                vec![val]
            }
        } else {
            serde_json::from_str(json_content).map_err(|e| format!("JSON 解析失败: {e}"))?
        };

        let mut imported = 0;
        let mut skipped = 0;
        let mut errors = Vec::new();

        for item in &items {
            match Self::insert_item(conn, data_type, item) {
                Ok(true) => imported += 1,
                Ok(false) => skipped += 1,
                Err(e) => errors.push(e),
            }
        }

        Ok(ImportResult {
            data_type,
            imported,
            skipped,
            errors,
        })
    }

    fn insert_item(
        conn: &rusqlite::Connection,
        data_type: DefaultDataType,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        match data_type {
            DefaultDataType::HttpTts => Self::insert_http_tts(conn, item),
            DefaultDataType::TxtTocRule => Self::insert_txt_toc_rule(conn, item),
            DefaultDataType::RssSources => Self::insert_rss_source(conn, item),
            DefaultDataType::DictRules => Self::insert_dict_rule(conn, item),
            DefaultDataType::CoverRule => Self::insert_cover_rule(conn, item),
            DefaultDataType::KeyboardAssists => Self::insert_keyboard_assist(conn, item),
        }
    }

    fn insert_http_tts(
        conn: &rusqlite::Connection,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        let id = item
            .get("id")
            .and_then(|v| v.as_i64())
            .ok_or("缺少 id 字段")?;

        // 检查是否已存在
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM httpTTS WHERE id = ?1",
                rusqlite::params![id],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| e.to_string())?;

        if exists {
            return Ok(false);
        }

        let name = item.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let url = item.get("url").and_then(|v| v.as_str()).unwrap_or("");
        let content_type = item.get("contentType").and_then(|v| v.as_str());
        let header = item.get("header").and_then(|v| v.as_str());
        let login_url = item.get("loginUrl").and_then(|v| v.as_str());

        conn.execute(
            "INSERT INTO httpTTS (id, name, url, contentType, header, loginUrl) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            rusqlite::params![id, name, url, content_type, header, login_url],
        )
        .map_err(|e| format!("插入 httpTTS 失败: {e}"))?;

        Ok(true)
    }

    fn insert_txt_toc_rule(
        conn: &rusqlite::Connection,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        let name = item
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or("缺少 name 字段")?;
        let rule = item
            .get("rule")
            .and_then(|v| v.as_str())
            .ok_or("缺少 rule 字段")?;

        // 检查是否已存在同名规则
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM txtTocRules WHERE name = ?1 AND rule = ?2",
                rusqlite::params![name, rule],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| e.to_string())?;

        if exists {
            return Ok(false);
        }

        let serial_number = item
            .get("serialNumber")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);
        let enable = item.get("enable").and_then(|v| v.as_i64()).unwrap_or(1);
        let example = item.get("example").and_then(|v| v.as_str());

        conn.execute(
            "INSERT INTO txtTocRules (name, rule, serialNumber, enable, example) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![name, rule, serial_number, enable, example],
        )
        .map_err(|e| format!("插入 txtTocRules 失败: {e}"))?;

        Ok(true)
    }

    fn insert_rss_source(
        conn: &rusqlite::Connection,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        let source_url = item
            .get("sourceUrl")
            .and_then(|v| v.as_str())
            .ok_or("缺少 sourceUrl 字段")?;

        // 检查是否已存在
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM rssSources WHERE sourceUrl = ?1",
                rusqlite::params![source_url],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| e.to_string())?;

        if exists {
            return Ok(false);
        }

        let source_name = item
            .get("sourceName")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let source_group = item.get("sourceGroup").and_then(|v| v.as_str());
        let enabled = item.get("enabled").and_then(|v| v.as_i64()).unwrap_or(1);

        conn.execute(
            "INSERT INTO rssSources (sourceUrl, sourceName, sourceGroup, enabled) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![source_url, source_name, source_group, enabled],
        )
        .map_err(|e| format!("插入 rssSources 失败: {e}"))?;

        Ok(true)
    }

    fn insert_dict_rule(
        conn: &rusqlite::Connection,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        let name = item
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or("缺少 name 字段")?;

        // 检查是否已存在
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM dictRules WHERE name = ?1",
                rusqlite::params![name],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| e.to_string())?;

        if exists {
            return Ok(false);
        }

        let url_rule = item.get("urlRule").and_then(|v| v.as_str()).unwrap_or("");
        let show_rule = item.get("showRule").and_then(|v| v.as_str()).unwrap_or("");
        let enabled = item.get("enabled").and_then(|v| v.as_i64()).unwrap_or(1);
        let sort_number = item.get("sortNumber").and_then(|v| v.as_i64()).unwrap_or(0);

        conn.execute(
            "INSERT INTO dictRules (name, urlRule, showRule, enabled, sortNumber) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![name, url_rule, show_rule, enabled, sort_number],
        )
        .map_err(|e| format!("插入 dictRules 失败: {e}"))?;

        Ok(true)
    }

    fn insert_cover_rule(
        conn: &rusqlite::Connection,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        let name = item
            .get("name")
            .and_then(|v| v.as_str())
            .ok_or("缺少 name 字段")?;
        let rule = item
            .get("rule")
            .and_then(|v| v.as_str())
            .ok_or("缺少 rule 字段")?;

        // 检查是否已存在
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM coverRules WHERE name = ?1 AND rule = ?2",
                rusqlite::params![name, rule],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| e.to_string())?;

        if exists {
            return Ok(false);
        }

        let enable = item.get("enable").and_then(|v| v.as_i64()).unwrap_or(1);

        conn.execute(
            "INSERT INTO coverRules (name, rule, enable) VALUES (?1, ?2, ?3)",
            rusqlite::params![name, rule, enable],
        )
        .map_err(|e| format!("插入 coverRules 失败: {e}"))?;

        Ok(true)
    }

    fn insert_keyboard_assist(
        conn: &rusqlite::Connection,
        item: &serde_json::Value,
    ) -> Result<bool, String> {
        let key = item
            .get("key")
            .and_then(|v| v.as_str())
            .ok_or("缺少 key 字段")?;
        let value = item
            .get("value")
            .and_then(|v| v.as_str())
            .ok_or("缺少 value 字段")?;
        let assist_type = item.get("type").and_then(|v| v.as_i64()).unwrap_or(0);

        // 检查是否已存在
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM keyboardAssists WHERE type = ?1 AND key = ?2",
                rusqlite::params![assist_type, key],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| e.to_string())?;

        if exists {
            return Ok(false);
        }

        let serial_number = item
            .get("serialNumber")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);

        conn.execute(
            "INSERT INTO keyboardAssists (type, key, value, serialNumber) VALUES (?1, ?2, ?3, ?4)",
            rusqlite::params![assist_type, key, value, serial_number],
        )
        .map_err(|e| format!("插入 keyboardAssists 失败: {e}"))?;

        Ok(true)
    }

    /// 删除指定类型的默认数据（id < 0 或 group == "legado"）
    pub fn delete_default(
        conn: &rusqlite::Connection,
        data_type: DefaultDataType,
    ) -> Result<usize, String> {
        let sql = match data_type {
            DefaultDataType::HttpTts => "DELETE FROM httpTTS WHERE id < 0",
            DefaultDataType::TxtTocRule => "DELETE FROM txtTocRules WHERE id < 0",
            DefaultDataType::RssSources => "DELETE FROM rssSources WHERE sourceGroup = 'legado'",
            DefaultDataType::DictRules => "DELETE FROM dictRules WHERE 0",
            DefaultDataType::CoverRule => "DELETE FROM coverRules WHERE 0",
            DefaultDataType::KeyboardAssists => "DELETE FROM keyboardAssists WHERE 0",
        };
        conn.execute(sql, [])
            .map_err(|e| format!("删除默认数据失败: {e}"))
    }

    /// 版本检查，按需更新
    ///
    /// 对应 Kotlin `DefaultData.upVersion()`：
    /// 当应用版本升级时，重新导入标记为需要更新的默认数据。
    pub fn up_version(
        conn: &rusqlite::Connection,
        flags: &UpgradeFlags,
        assets_dir: &str,
    ) -> Result<Vec<ImportResult>, String> {
        let mut results = Vec::new();
        let sep = std::path::MAIN_SEPARATOR;

        if flags.need_up_http_tts {
            let path = format!("{assets_dir}{sep}httpTTS.json");
            if let Ok(result) = Self::import_from_file(conn, DefaultDataType::HttpTts, &path) {
                results.push(result);
            }
        }
        if flags.need_up_txt_toc_rule {
            let path = format!("{assets_dir}{sep}txtTocRule.json");
            if let Ok(result) = Self::import_from_file(conn, DefaultDataType::TxtTocRule, &path) {
                results.push(result);
            }
        }
        if flags.need_up_rss_sources {
            let path = format!("{assets_dir}{sep}rssSources.json");
            if let Ok(result) = Self::import_from_file(conn, DefaultDataType::RssSources, &path) {
                results.push(result);
            }
        }
        if flags.need_up_dict_rule {
            let path = format!("{assets_dir}{sep}dictRules.json");
            if let Ok(result) = Self::import_from_file(conn, DefaultDataType::DictRules, &path) {
                results.push(result);
            }
        }

        Ok(results)
    }
}

/// 升级标志（对应 Kotlin LocalConfig 中的 needUp* 字段）
#[derive(Debug, Clone, Default)]
pub struct UpgradeFlags {
    pub need_up_http_tts: bool,
    pub need_up_txt_toc_rule: bool,
    pub need_up_rss_sources: bool,
    pub need_up_dict_rule: bool,
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn setup_db() -> rusqlite::Connection {
        let conn = rusqlite::Connection::open_in_memory().unwrap();
        // 创建 txtTocRules 和 rssSources 表（模拟 schema 初始化）
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS txtTocRules (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL,
                rule TEXT NOT NULL,
                serialNumber INTEGER NOT NULL DEFAULT 0,
                enable INTEGER NOT NULL DEFAULT 1,
                example TEXT
            );
            CREATE TABLE IF NOT EXISTS rssSources (
                sourceUrl TEXT NOT NULL,
                sourceName TEXT NOT NULL,
                sourceIcon TEXT NOT NULL DEFAULT '',
                sourceGroup TEXT,
                sourceComment TEXT,
                enabled INTEGER NOT NULL DEFAULT 1,
                sortUrl TEXT,
                customOrder INTEGER NOT NULL DEFAULT 0,
                lastUpdateTime INTEGER NOT NULL DEFAULT 0,
                header TEXT,
                enableJs INTEGER NOT NULL DEFAULT 1,
                loadWithBaseUrl INTEGER NOT NULL DEFAULT 1,
                PRIMARY KEY(sourceUrl)
            );",
        )
        .unwrap();
        DefaultDataManager::ensure_tables(&conn).unwrap();
        conn
    }

    #[test]
    fn test_import_http_tts() {
        let conn = setup_db();
        let json = r#"[
            {"id": -1, "name": "测试TTS", "url": "http://example.com/tts"},
            {"id": -2, "name": "测试TTS2", "url": "http://example.com/tts2"}
        ]"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::HttpTts, json).unwrap();
        assert_eq!(result.imported, 2);
        assert_eq!(result.skipped, 0);
        assert!(result.is_success());
    }

    #[test]
    fn test_import_http_tts_skip_duplicate() {
        let conn = setup_db();
        let json = r#"[{"id": -1, "name": "测试TTS", "url": "http://example.com/tts"}]"#;
        DefaultDataManager::import_from_json(&conn, DefaultDataType::HttpTts, json).unwrap();
        // 再次导入相同数据
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::HttpTts, json).unwrap();
        assert_eq!(result.imported, 0);
        assert_eq!(result.skipped, 1);
    }

    #[test]
    fn test_import_txt_toc_rule() {
        let conn = setup_db();
        let json = r#"[
            {"name": "第一章", "rule": "^第\\s*\\S+\\s*章", "serialNumber": 0, "enable": 1},
            {"name": "Chapter", "rule": "^Chapter\\s+\\d+", "serialNumber": 1, "enable": 1}
        ]"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::TxtTocRule, json).unwrap();
        assert_eq!(result.imported, 2);
        assert!(result.is_success());
    }

    #[test]
    fn test_import_rss_source() {
        let conn = setup_db();
        let json = r#"[
            {"sourceUrl": "https://rss.example.com/feed1", "sourceName": "RSS源1", "sourceGroup": "legado"},
            {"sourceUrl": "https://rss.example.com/feed2", "sourceName": "RSS源2", "sourceGroup": "legado"}
        ]"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::RssSources, json).unwrap();
        assert_eq!(result.imported, 2);
        assert_eq!(result.total(), 2);
    }

    #[test]
    fn test_import_dict_rules() {
        let conn = setup_db();
        let json = r#"[
            {"name": "百度词典", "urlRule": "https://dict.baidu.com/s?wd={{key}}", "showRule": "@css:.content", "enabled": 1}
        ]"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::DictRules, json).unwrap();
        assert_eq!(result.imported, 1);
        assert!(result.is_success());
    }

    #[test]
    fn test_import_cover_rule_single_object() {
        let conn = setup_db();
        // CoverRule 可以是单个对象
        let json = r#"{"name": "默认封面", "rule": "https://example.com/cover.jpg", "enable": 1}"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::CoverRule, json).unwrap();
        assert_eq!(result.imported, 1);
    }

    #[test]
    fn test_import_keyboard_assists() {
        let conn = setup_db();
        let json = r#"[
            {"type": 0, "key": "tab", "value": "\\t", "serialNumber": 0},
            {"type": 0, "key": "enter", "value": "\\n", "serialNumber": 1}
        ]"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::KeyboardAssists, json)
                .unwrap();
        assert_eq!(result.imported, 2);
    }

    #[test]
    fn test_import_invalid_json() {
        let conn = setup_db();
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::HttpTts, "not json");
        assert!(result.is_err());
    }

    #[test]
    fn test_import_missing_required_field() {
        let conn = setup_db();
        // 缺少 id 字段
        let json = r#"[{"name": "无ID的TTS", "url": "http://example.com"}]"#;
        let result =
            DefaultDataManager::import_from_json(&conn, DefaultDataType::HttpTts, json).unwrap();
        assert_eq!(result.imported, 0);
        assert_eq!(result.errors.len(), 1);
    }

    #[test]
    fn test_delete_default_http_tts() {
        let conn = setup_db();
        let json = r#"[
            {"id": -1, "name": "默认TTS", "url": "http://a.com"},
            {"id": 100, "name": "用户TTS", "url": "http://b.com"}
        ]"#;
        DefaultDataManager::import_from_json(&conn, DefaultDataType::HttpTts, json).unwrap();
        let deleted = DefaultDataManager::delete_default(&conn, DefaultDataType::HttpTts).unwrap();
        assert_eq!(deleted, 1); // 只删除 id < 0 的
    }

    #[test]
    fn test_delete_default_rss_sources() {
        let conn = setup_db();
        let json = r#"[
            {"sourceUrl": "https://a.com", "sourceName": "A", "sourceGroup": "legado"},
            {"sourceUrl": "https://b.com", "sourceName": "B", "sourceGroup": "custom"}
        ]"#;
        DefaultDataManager::import_from_json(&conn, DefaultDataType::RssSources, json).unwrap();
        let deleted =
            DefaultDataManager::delete_default(&conn, DefaultDataType::RssSources).unwrap();
        assert_eq!(deleted, 1); // 只删除 group == "legado" 的
    }

    #[test]
    fn test_import_result_total() {
        let result = ImportResult {
            data_type: DefaultDataType::HttpTts,
            imported: 3,
            skipped: 2,
            errors: vec!["err1".to_string()],
        };
        assert_eq!(result.total(), 6);
        assert!(!result.is_success());
    }

    #[test]
    fn test_up_version_no_flags() {
        let conn = setup_db();
        let flags = UpgradeFlags::default();
        let results = DefaultDataManager::up_version(&conn, &flags, "/nonexistent").unwrap();
        assert!(results.is_empty());
    }
}
