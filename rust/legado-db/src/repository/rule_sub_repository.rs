//! RuleSub Repository - rule_subs 表 CRUD
//!
//! 管理规则订阅源（书源/替换规则/RSS源订阅）的持久化操作。

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// 规则订阅记录（对应 rule_subs 表）
#[derive(Debug, Clone, PartialEq)]
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
                "INSERT OR REPLACE INTO rule_subs (url, name, sub_type, last_update, version, is_enabled, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    record.url,
                    record.name,
                    record.sub_type,
                    record.last_update,
                    record.version,
                    record.is_enabled,
                    record.created_at,
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
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at
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
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at
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

    /// 查询所有订阅
    pub fn find_all(&self) -> LegadoResult<Vec<RuleSubRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at
                 FROM rule_subs ORDER BY id ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let records = stmt
            .query_map([], row_to_rule_sub)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(records)
    }

    /// 获取所有已启用的订阅
    pub fn get_enabled_subs(&self) -> LegadoResult<Vec<RuleSubRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, url, name, sub_type, last_update, version, is_enabled, created_at
                 FROM rule_subs WHERE is_enabled = 1 ORDER BY id ASC",
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
                 last_update = ?4, version = ?5, is_enabled = ?6
                 WHERE id = ?7",
                params![
                    record.url,
                    record.name,
                    record.sub_type,
                    record.last_update,
                    record.version,
                    record.is_enabled,
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
}
