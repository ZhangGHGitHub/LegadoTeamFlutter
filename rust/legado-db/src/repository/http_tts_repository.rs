//! HttpTts Repository - httpTTS 表 CRUD（对齐 Room v95 + isEnabled 超集）

use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// HTTP TTS 朗读源（全 14 列，对齐 httpTTS 表定义与原版 HttpTTS 实体）
///
/// 扩表说明（备份/恢复批 2026-10-26）：此前模型仅覆盖 6 列，
/// defaultData 种子会写入 header/loginUrl 等扩展列——6 列模型会造成
/// 备份恢复丢字段，故补齐全列（serde 键名对齐 Room 列 camelCase）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct HttpTts {
    pub id: i64,
    pub name: String,
    pub url: String,
    #[serde(default, rename = "contentType")]
    pub content_type: String,
    #[serde(default, rename = "isEnabled")]
    pub is_enabled: bool,
    #[serde(default, rename = "lastUpdateTime")]
    pub created_at: i64,
    /// 朗读停顿时长（毫秒）
    #[serde(default, rename = "pauseDuration")]
    pub pause_duration: i32,
    /// 并发率
    #[serde(default, rename = "concurrentRate")]
    pub concurrent_rate: Option<String>,
    /// 登录地址
    #[serde(default, rename = "loginUrl")]
    pub login_url: Option<String>,
    /// 登录界面 JSON
    #[serde(default, rename = "loginUi")]
    pub login_ui: Option<String>,
    /// 请求头
    #[serde(default)]
    pub header: Option<String>,
    /// js 库
    #[serde(default, rename = "jsLib")]
    pub js_lib: Option<String>,
    /// 是否启用 CookieJar（NULL 视为关）
    #[serde(default, rename = "enabledCookieJar")]
    pub enabled_cookie_jar: Option<bool>,
    /// 登录检测 js
    #[serde(default, rename = "loginCheckJs")]
    pub login_check_js: Option<String>,
}

/// 查询列（与 row_to_http_tts 的列索引一一对应，全 14 列）
const SELECT_COLUMNS: &str = "SELECT id, name, url, contentType, isEnabled, lastUpdateTime,
    pauseDuration, concurrentRate, loginUrl, loginUi, header, jsLib,
    enabledCookieJar, loginCheckJs FROM httpTTS";

/// HTTP TTS 数据访问层
pub struct HttpTtsRepository<'a> {
    conn: &'a Connection,
}

impl<'a> HttpTtsRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入一条 TTS 源，返回新 ID
    pub fn insert(&self, name: &str, url: &str) -> LegadoResult<i64> {
        let now = current_time_millis();
        // Room 主键非自增；取 MAX(id)+1（与 Android 导入正 id 共存）
        let next_id: i64 = self
            .conn
            .query_row("SELECT COALESCE(MAX(id), 0) + 1 FROM httpTTS", [], |row| {
                row.get(0)
            })
            .unwrap_or(1);
        self.conn
            .execute(
                "INSERT INTO httpTTS (id, name, url, contentType, pauseDuration, concurrentRate,
                 enabledCookieJar, lastUpdateTime, isEnabled)
                 VALUES (?1, ?2, ?3, '', 0, '0', 0, ?4, 1)",
                params![next_id, name, url, now],
            )
            .map_err(|e| LegadoError::Database(format!("插入 TTS 源失败: {e}")))?;
        Ok(next_id)
    }

    /// 全字段 upsert（INSERT OR REPLACE，显式携带主键 id，供备份恢复使用）
    ///
    /// 与 [`insert`](Self::insert)（扩展列落固定默认值）不同：恢复路径
    /// 需原样保留备份中的 header/loginUrl/concurrentRate 等全列值。
    /// id <= 0 时按 MAX(id)+1 分配（对齐 Room 非自增主键语义）。
    pub fn upsert(&self, tts: &HttpTts) -> LegadoResult<i64> {
        let id = if tts.id > 0 { tts.id } else { self.next_id()? };
        self.conn
            .execute(
                "INSERT OR REPLACE INTO httpTTS
                 (id, name, url, contentType, pauseDuration, concurrentRate,
                  loginUrl, loginUi, header, jsLib, enabledCookieJar, loginCheckJs,
                  lastUpdateTime, isEnabled)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    id,
                    tts.name,
                    tts.url,
                    tts.content_type,
                    tts.pause_duration,
                    tts.concurrent_rate,
                    tts.login_url,
                    tts.login_ui,
                    tts.header,
                    tts.js_lib,
                    tts.enabled_cookie_jar.map(|b| b as i32),
                    tts.login_check_js,
                    tts.created_at,
                    tts.is_enabled as i32,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("恢复 TTS 源失败: {e}")))?;
        Ok(id)
    }

    /// 计算下一个可用主键（MAX(id)+1）
    fn next_id(&self) -> LegadoResult<i64> {
        let next_id: i64 = self
            .conn
            .query_row("SELECT COALESCE(MAX(id), 0) + 1 FROM httpTTS", [], |row| {
                row.get(0)
            })
            .map_err(|e| LegadoError::Database(format!("查询 TTS 主键失败: {e}")))?;
        Ok(next_id)
    }

    /// 获取所有 TTS 源
    pub fn find_all(&self) -> LegadoResult<Vec<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} ORDER BY lastUpdateTime DESC"))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_http_tts)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 查询
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} WHERE id = ?1"))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![id], row_to_http_tts)
            .optional()
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        Ok(result)
    }

    /// 更新 TTS 源
    pub fn update(&self, id: i64, name: &str, url: &str) -> LegadoResult<bool> {
        let now = current_time_millis();
        let affected = self
            .conn
            .execute(
                "UPDATE httpTTS SET name = ?1, url = ?2, lastUpdateTime = ?3 WHERE id = ?4",
                params![name, url, now, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新 TTS 源失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除 TTS 源
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM httpTTS WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除 TTS 源失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 获取所有已启用的 TTS 源
    pub fn find_enabled(&self) -> LegadoResult<Vec<HttpTts>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS} WHERE isEnabled = 1 ORDER BY lastUpdateTime DESC"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_http_tts)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 设置启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute(
                "UPDATE httpTTS SET isEnabled = ?1 WHERE id = ?2",
                params![enabled as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("设置 TTS 启用状态失败: {e}")))?;
        Ok(affected > 0)
    }
}

fn row_to_http_tts(row: &rusqlite::Row<'_>) -> rusqlite::Result<HttpTts> {
    let is_enabled: i32 = row.get(4)?;
    let enabled_cookie_jar: Option<i32> = row.get(12)?;
    Ok(HttpTts {
        id: row.get(0)?,
        name: row.get(1)?,
        url: row.get(2)?,
        content_type: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
        is_enabled: is_enabled != 0,
        created_at: row.get(5)?,
        pause_duration: row.get::<_, Option<i32>>(6)?.unwrap_or(0),
        concurrent_rate: row.get(7)?,
        login_url: row.get(8)?,
        login_ui: row.get(9)?,
        header: row.get(10)?,
        js_lib: row.get(11)?,
        enabled_cookie_jar: enabled_cookie_jar.map(|v| v != 0),
        login_check_js: row.get(13)?,
    })
}

fn current_time_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("引擎A", "http://a.example/tts").unwrap();
        assert!(id > 0);
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].name, "引擎A");
        assert!(all[0].is_enabled);
    }

    #[test]
    fn test_update_delete_set_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let id = repo.insert("旧名", "http://old").unwrap();
        assert!(repo.update(id, "新名", "http://new").unwrap());
        let item = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(item.name, "新名");
        assert!(repo.set_enabled(id, false).unwrap());
        assert!(!repo.find_by_id(id).unwrap().unwrap().is_enabled);
        assert!(repo.find_enabled().unwrap().is_empty());
        assert!(repo.delete(id).unwrap());
        assert!(repo.find_by_id(id).unwrap().is_none());
    }

    /// 全列 upsert 往返（备份恢复路径）：扩展列（header/loginUrl 等）逐列读回
    #[test]
    fn test_upsert_full_columns_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let record = HttpTts {
            id: 7,
            name: "全列引擎".to_string(),
            url: "https://tts.example/?t={{speakText}}".to_string(),
            content_type: "audio/mpeg".to_string(),
            is_enabled: false,
            created_at: 1700000000000,
            pause_duration: 300,
            concurrent_rate: Some("2".to_string()),
            login_url: Some("https://login.example".to_string()),
            login_ui: Some("[{\"name\":\"u\"}]".to_string()),
            header: Some("{\"User-Agent\":\"UA\"}".to_string()),
            js_lib: Some("lib.js".to_string()),
            enabled_cookie_jar: Some(true),
            login_check_js: Some("return 1;".to_string()),
        };
        let id = repo.upsert(&record).unwrap();
        assert_eq!(id, 7);

        let found = repo.find_by_id(7).unwrap().unwrap();
        assert_eq!(found.name, "全列引擎");
        assert_eq!(found.content_type, "audio/mpeg");
        assert!(!found.is_enabled);
        assert_eq!(found.created_at, 1700000000000);
        assert_eq!(found.pause_duration, 300);
        assert_eq!(found.concurrent_rate.as_deref(), Some("2"));
        assert_eq!(found.login_url.as_deref(), Some("https://login.example"));
        assert_eq!(found.login_ui.as_deref(), Some("[{\"name\":\"u\"}]"));
        assert_eq!(found.header.as_deref(), Some("{\"User-Agent\":\"UA\"}"));
        assert_eq!(found.js_lib.as_deref(), Some("lib.js"));
        assert_eq!(found.enabled_cookie_jar, Some(true));
        assert_eq!(found.login_check_js.as_deref(), Some("return 1;"));

        // 同 id 重复恢复：整行替换，不产生重复行
        let mut updated = record.clone();
        updated.name = "改名".to_string();
        repo.upsert(&updated).unwrap();
        assert_eq!(repo.find_all().unwrap().len(), 1);
        assert_eq!(repo.find_by_id(7).unwrap().unwrap().name, "改名");
    }

    /// id <= 0 的恢复记录：主键按 MAX(id)+1 分配
    #[test]
    fn test_upsert_assigns_id_when_zero() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HttpTtsRepository::new(db.connection());
        let mut record = HttpTts {
            name: "自增引擎".to_string(),
            url: "https://tts.example/auto".to_string(),
            ..Default::default()
        };
        record.id = 0;
        let id = repo.upsert(&record).unwrap();
        assert!(id > 0);
        assert!(repo.find_by_id(id).unwrap().is_some());
    }
}
