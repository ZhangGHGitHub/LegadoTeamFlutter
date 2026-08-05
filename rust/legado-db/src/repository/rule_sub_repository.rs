//! RuleSub Repository - rule_subs 表 CRUD
//!
//! 管理规则订阅源（书源/替换规则/RSS源订阅）的持久化操作。

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 规则订阅记录（对应 rule_subs 表）
///
/// 新增 7 个字段对齐 Kotlin `RuleSub` 实体（serde 字段名对齐 Kotlin）：
/// customOrder / autoUpdate / updateInterval / silentUpdate / js / showRule / sourceUrl
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuleSubRecord {
    /// 自增主键
    pub id: i64,
    /// 订阅 URL（唯一）
    pub url: String,
    /// 订阅名称
    pub name: String,
    /// 订阅类型: "bookSource" / "replaceRule" / "rssSource"
    pub sub_type: String,
    /// 最后更新时间戳（毫秒）
    pub last_update: i64,
    /// 版本号
    pub version: String,
    /// 是否启用
    pub is_enabled: bool,
    /// 创建时间戳（毫秒）
    pub created_at: i64,
    /// 自定义排序（拖拽排序依据，对应 Kotlin customOrder）
    #[serde(rename = "customOrder")]
    pub custom_order: i32,
    /// 是否自动更新（对应 Kotlin autoUpdate）
    #[serde(rename = "autoUpdate")]
    pub auto_update: bool,
    /// 更新间隔（小时，对应 Kotlin updateInterval）
    #[serde(rename = "updateInterval")]
    pub update_interval: i32,
    /// 是否静默更新（对应 Kotlin silentUpdate）
    #[serde(rename = "silentUpdate")]
    pub silent_update: bool,
    /// 访问链接前执行的 js 规则（对应 Kotlin js）
    pub js: Option<String>,
    /// 显示规则（对应 Kotlin showRule）
    #[serde(rename = "showRule")]
    pub show_rule: Option<String>,
    /// 绑定的源链接，能调用源的资源（对应 Kotlin sourceUrl）
    #[serde(rename = "sourceUrl")]
    pub source_url: Option<String>,
}

impl Default for RuleSubRecord {
    fn default() -> Self {
        Self {
            id: 0,
            url: String::new(),
            name: String::new(),
            sub_type: "bookSource".to_string(),
            last_update: 0,
            version: String::new(),
            is_enabled: true,
            created_at: 0,
            custom_order: 0,
            auto_update: false,
            update_interval: 0,
            silent_update: false,
            js: None,
            show_rule: None,
            source_url: None,
        }
    }
}

/// 规则订阅数据访问层
pub struct RuleSubRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RuleSubRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入新订阅，返回自增 ID
    pub fn insert(&self, record: &RuleSubRecord) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO rule_subs (url, name, sub_type, last_update, version, is_enabled, created_at,
                 custom_order, auto_update, update_interval, silent_update, js, show_rule, source_url)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
                params![
                    record.url,
                    record.name,
                    record.sub_type,
                    record.last_update,
                    record.version,
                    record.is_enabled,
                    record.created_at,
                    record.custom_order,
                    record.auto_update,
                    record.update_interval,
                    record.silent_update,
                    record.js,
                    record.show_rule,
                    record.source_url,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入 rule_subs 失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 根据 ID 查询
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<RuleSubRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at,
                 custom_order, auto_update, update_interval, silent_update, js, show_rule, source_url
                 FROM rule_subs WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![id], row_to_rule_sub)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(record)) => Ok(Some(record)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 根据 URL 查询
    pub fn find_by_url(&self, url: &str) -> LegadoResult<Option<RuleSubRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at,
                 custom_order, auto_update, update_interval, silent_update, js, show_rule, source_url
                 FROM rule_subs WHERE url = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![url], row_to_rule_sub)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(record)) => Ok(Some(record)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 查询所有订阅（按 custom_order 升序，同序按 id 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<RuleSubRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at,
                 custom_order, auto_update, update_interval, silent_update, js, show_rule, source_url
                 FROM rule_subs ORDER BY custom_order ASC, id ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let records = stmt
            .query_map([], row_to_rule_sub)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(records)
    }

    /// 获取所有已启用的订阅（按 custom_order 升序，同序按 id 升序）
    pub fn get_enabled_subs(&self) -> LegadoResult<Vec<RuleSubRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at,
                 custom_order, auto_update, update_interval, silent_update, js, show_rule, source_url
                 FROM rule_subs WHERE is_enabled = 1 ORDER BY custom_order ASC, id ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let records = stmt
            .query_map([], row_to_rule_sub)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(records)
    }

    /// 更新订阅记录
    pub fn update(&self, record: &RuleSubRecord) -> LegadoResult<()> {
        let affected = self
            .conn
            .execute(
                "UPDATE rule_subs SET url = ?1, name = ?2, sub_type = ?3,
                 last_update = ?4, version = ?5, is_enabled = ?6,
                 custom_order = ?7, auto_update = ?8, update_interval = ?9,
                 silent_update = ?10, js = ?11, show_rule = ?12, source_url = ?13
                 WHERE id = ?14",
                params![
                    record.url,
                    record.name,
                    record.sub_type,
                    record.last_update,
                    record.version,
                    record.is_enabled,
                    record.custom_order,
                    record.auto_update,
                    record.update_interval,
                    record.silent_update,
                    record.js,
                    record.show_rule,
                    record.source_url,
                    record.id,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新 rule_subs 失败: {e}")))?;

        if affected == 0 {
            return Err(LegadoError::Database(format!(
                "未找到 id={} 的订阅记录",
                record.id
            )));
        }
        Ok(())
    }

    /// 更新版本号
    pub fn update_version(&self, id: i64, version: &str, last_update: i64) -> LegadoResult<()> {
        let affected = self
            .conn
            .execute(
                "UPDATE rule_subs SET version = ?1, last_update = ?2 WHERE id = ?3",
                params![version, last_update, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新版本失败: {e}")))?;

        if affected == 0 {
            return Err(LegadoError::Database(format!(
                "未找到 id={} 的订阅记录",
                id
            )));
        }
        Ok(())
    }

    /// 删除订阅
    pub fn delete(&self, id: i64) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM rule_subs WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除 rule_subs 失败: {e}")))?;
        Ok(())
    }

    /// 切换启用/禁用状态
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE rule_subs SET is_enabled = ?1 WHERE id = ?2",
                params![enabled, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新启用状态失败: {e}")))?;
        Ok(())
    }

    /// 批量更新自定义排序（拖拽排序）
    ///
    /// `ids` 为拖拽后的新顺序 ID 列表，按索引依次写入 custom_order（0 起）。
    pub fn update_order(&self, ids: &[i64]) -> LegadoResult<()> {
        for (index, id) in ids.iter().enumerate() {
            self.conn
                .execute(
                    "UPDATE rule_subs SET custom_order = ?1 WHERE id = ?2",
                    params![index as i32, id],
                )
                .map_err(|e| LegadoError::Database(format!("更新排序失败: {e}")))?;
        }
        Ok(())
    }
}

fn row_to_rule_sub(row: &rusqlite::Row<'_>) -> rusqlite::Result<RuleSubRecord> {
    Ok(RuleSubRecord {
        id: row.get(0)?,
        url: row.get(1)?,
        name: row.get(2)?,
        sub_type: row.get(3)?,
        last_update: row.get(4)?,
        version: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
        is_enabled: row.get(6)?,
        created_at: row.get(7)?,
        custom_order: row.get(8)?,
        auto_update: row.get(9)?,
        update_interval: row.get(10)?,
        silent_update: row.get(11)?,
        js: row.get(12)?,
        show_rule: row.get(13)?,
        source_url: row.get(14)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_sub(url: &str, name: &str, sub_type: &str) -> RuleSubRecord {
        RuleSubRecord {
            url: url.to_string(),
            name: name.to_string(),
            sub_type: sub_type.to_string(),
            created_at: 1700000000000,
            ..RuleSubRecord::default()
        }
    }

    #[test]
    fn test_rule_sub_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        repo.insert(&make_sub(
            "https://example.com/bs.json",
            "书源订阅",
            "bookSource",
        ))
        .unwrap();
        repo.insert(&make_sub(
            "https://example.com/rr.json",
            "替换规则",
            "replaceRule",
        ))
        .unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        assert_eq!(all[0].name, "书源订阅");
        assert_eq!(all[1].sub_type, "replaceRule");
    }

    #[test]
    fn test_rule_sub_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let id = repo
            .insert(&make_sub(
                "https://example.com/sub.json",
                "测试",
                "bookSource",
            ))
            .unwrap();

        let found = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(found.url, "https://example.com/sub.json");
        assert_eq!(found.name, "测试");
    }

    #[test]
    fn test_rule_sub_find_by_url() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        repo.insert(&make_sub("https://example.com/a.json", "A", "bookSource"))
            .unwrap();

        let found = repo.find_by_url("https://example.com/a.json").unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().name, "A");

        let not_found = repo.find_by_url("https://nonexist.com").unwrap();
        assert!(not_found.is_none());
    }

    #[test]
    fn test_rule_sub_get_enabled_subs() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let id1 = repo
            .insert(&make_sub(
                "https://example.com/1.json",
                "启用",
                "bookSource",
            ))
            .unwrap();
        repo.insert(&make_sub("https://example.com/2.json", "禁用", "rssSource"))
            .unwrap();

        // 禁用第二个
        let all = repo.find_all().unwrap();
        let id2 = all[1].id;
        repo.set_enabled(id2, false).unwrap();

        let enabled = repo.get_enabled_subs().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].id, id1);
    }

    #[test]
    fn test_rule_sub_update_version() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let id = repo
            .insert(&make_sub(
                "https://example.com/v.json",
                "版本测试",
                "bookSource",
            ))
            .unwrap();

        repo.update_version(id, "2.0.1", 1700001000000).unwrap();

        let found = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(found.version, "2.0.1");
        assert_eq!(found.last_update, 1700001000000);
    }

    #[test]
    fn test_rule_sub_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let id = repo
            .insert(&make_sub(
                "https://example.com/u.json",
                "原始",
                "bookSource",
            ))
            .unwrap();

        let mut record = repo.find_by_id(id).unwrap().unwrap();
        record.name = "已更新".to_string();
        record.sub_type = "replaceRule".to_string();
        repo.update(&record).unwrap();

        let updated = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(updated.name, "已更新");
        assert_eq!(updated.sub_type, "replaceRule");
    }

    #[test]
    fn test_rule_sub_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let id = repo
            .insert(&make_sub(
                "https://example.com/d.json",
                "待删除",
                "bookSource",
            ))
            .unwrap();

        repo.delete(id).unwrap();

        let found = repo.find_by_id(id).unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn test_rule_sub_new_fields_roundtrip() {
        // 新增 7 字段（对齐 Kotlin RuleSub）读写覆盖
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let record = RuleSubRecord {
            url: "https://example.com/full.json".to_string(),
            name: "全字段订阅".to_string(),
            sub_type: "bookSource".to_string(),
            created_at: 1700000000000,
            custom_order: 5,
            auto_update: true,
            update_interval: 12,
            silent_update: true,
            js: "return url;".to_string().into(),
            show_rule: "$.items".to_string().into(),
            source_url: "https://example.com/source.json".to_string().into(),
            ..RuleSubRecord::default()
        };

        let id = repo.insert(&record).unwrap();
        let found = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(found.custom_order, 5);
        assert!(found.auto_update);
        assert_eq!(found.update_interval, 12);
        assert!(found.silent_update);
        assert_eq!(found.js.as_deref(), Some("return url;"));
        assert_eq!(found.show_rule.as_deref(), Some("$.items"));
        assert_eq!(found.source_url.as_deref(), Some("https://example.com/source.json"));

        // update 覆盖新字段
        let mut updated = found.clone();
        updated.auto_update = false;
        updated.update_interval = 24;
        updated.js = None;
        repo.update(&updated).unwrap();

        let after = repo.find_by_id(id).unwrap().unwrap();
        assert!(!after.auto_update);
        assert_eq!(after.update_interval, 24);
        assert!(after.js.is_none());
        assert_eq!(after.show_rule.as_deref(), Some("$.items"));
    }

    #[test]
    fn test_rule_sub_find_all_ordered_by_custom_order() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        // 插入时乱序，查询应按 custom_order 排序
        repo.insert(&RuleSubRecord {
            url: "https://example.com/c.json".to_string(),
            name: "C".to_string(),
            custom_order: 2,
            ..make_sub("", "", "bookSource")
        })
        .unwrap();
        repo.insert(&RuleSubRecord {
            url: "https://example.com/a.json".to_string(),
            name: "A".to_string(),
            custom_order: 0,
            ..make_sub("", "", "bookSource")
        })
        .unwrap();
        repo.insert(&RuleSubRecord {
            url: "https://example.com/b.json".to_string(),
            name: "B".to_string(),
            custom_order: 1,
            ..make_sub("", "", "bookSource")
        })
        .unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].name, "A");
        assert_eq!(all[1].name, "B");
        assert_eq!(all[2].name, "C");
    }

    #[test]
    fn test_rule_sub_update_order() {
        // 拖拽排序：按新顺序 ID 列表重写 custom_order
        let db = crate::init_in_memory_database().unwrap();
        let repo = RuleSubRepository::new(db.connection());

        let id1 = repo
            .insert(&make_sub("https://example.com/1.json", "一", "bookSource"))
            .unwrap();
        let id2 = repo
            .insert(&make_sub("https://example.com/2.json", "二", "bookSource"))
            .unwrap();
        let id3 = repo
            .insert(&make_sub("https://example.com/3.json", "三", "bookSource"))
            .unwrap();

        // 拖拽后新顺序：三、一、二
        repo.update_order(&[id3, id1, id2]).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all[0].id, id3);
        assert_eq!(all[0].custom_order, 0);
        assert_eq!(all[1].id, id1);
        assert_eq!(all[1].custom_order, 1);
        assert_eq!(all[2].id, id2);
        assert_eq!(all[2].custom_order, 2);
    }

    #[test]
    fn test_rule_sub_serde_kotlin_field_names() {
        // serde 字段名对齐 Kotlin RuleSub
        let json = r#"{"id":1,"url":"https://example.com/x.json","name":"订阅",
            "sub_type":"bookSource","last_update":0,"version":"",
            "is_enabled":true,"created_at":0,
            "customOrder":3,"autoUpdate":true,"updateInterval":6,
            "silentUpdate":false,"js":null,"showRule":"$.list","sourceUrl":null}"#;

        let record: RuleSubRecord = serde_json::from_str(json).unwrap();
        assert_eq!(record.custom_order, 3);
        assert!(record.auto_update);
        assert_eq!(record.update_interval, 6);
        assert!(!record.silent_update);
        assert_eq!(record.show_rule.as_deref(), Some("$.list"));

        let out = serde_json::to_string(&record).unwrap();
        assert!(out.contains("\"customOrder\":3"));
        assert!(out.contains("\"autoUpdate\":true"));
        assert!(out.contains("\"updateInterval\":6"));
        assert!(out.contains("\"silentUpdate\":false"));
        assert!(out.contains("\"showRule\":\"$.list\""));
    }
}
