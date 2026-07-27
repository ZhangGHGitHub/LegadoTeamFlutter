//! Cookie Repository - cookies 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// Cookie 数据访问层
pub struct CookieRepository<'a> {
    conn: &'a Connection,
}

impl<'a> CookieRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入或更新 Cookie（以 url 为主键 upsert）
    pub fn upsert(&self, url: &str, cookie: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO cookies (url, cookie) VALUES (?1, ?2)",
                params![url, cookie],
            )
            .map_err(|e| LegadoError::Database(format!("Upsert Cookie 失败: {e}")))?;
        Ok(())
    }

    /// 按 url（tag）获取 Cookie 值
    pub fn get_by_tag(&self, tag: &str) -> LegadoResult<Option<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT cookie FROM cookies WHERE url = ?1")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![tag], |row| row.get::<_, String>(0))
            .ok();
        Ok(result)
    }

    /// 按 url（tag）删除 Cookie
    pub fn delete_by_tag(&self, tag: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM cookies WHERE url = ?1", params![tag])
            .map_err(|e| LegadoError::Database(format!("删除 Cookie 失败: {e}")))?;
        Ok(())
    }

    /// 清空所有 Cookie
    pub fn clear_all(&self) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM cookies", [])
            .map_err(|e| LegadoError::Database(format!("清空 Cookie 失败: {e}")))?;
        Ok(())
    }

    /// 获取所有 Cookie，返回 (url, cookie) 列表
    pub fn find_all(&self) -> LegadoResult<Vec<(String, String)>> {
        let mut stmt = self
            .conn
            .prepare("SELECT url, cookie FROM cookies ORDER BY url")
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取 Cookie 总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM cookies", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_upsert_and_get() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CookieRepository::new(db.connection());
        repo.upsert("https://example.com", "session=abc123")
            .unwrap();

        let cookie = repo.get_by_tag("https://example.com").unwrap();
        assert_eq!(cookie, Some("session=abc123".to_string()));
    }

    #[test]
    fn test_upsert_overwrite() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CookieRepository::new(db.connection());
        repo.upsert("https://example.com", "old=value").unwrap();
        repo.upsert("https://example.com", "new=value").unwrap();

        let cookie = repo.get_by_tag("https://example.com").unwrap();
        assert_eq!(cookie, Some("new=value".to_string()));
        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_get_nonexistent() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CookieRepository::new(db.connection());

        let cookie = repo.get_by_tag("https://nonexist.com").unwrap();
        assert_eq!(cookie, None);
    }

    #[test]
    fn test_delete_by_tag() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CookieRepository::new(db.connection());
        repo.upsert("https://a.com", "cookie_a").unwrap();
        repo.upsert("https://b.com", "cookie_b").unwrap();
        repo.delete_by_tag("https://a.com").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        assert_eq!(repo.get_by_tag("https://a.com").unwrap(), None);
        assert_eq!(
            repo.get_by_tag("https://b.com").unwrap(),
            Some("cookie_b".to_string())
        );
    }

    #[test]
    fn test_clear_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CookieRepository::new(db.connection());
        repo.upsert("https://a.com", "c1").unwrap();
        repo.upsert("https://b.com", "c2").unwrap();
        repo.clear_all().unwrap();

        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = CookieRepository::new(db.connection());
        repo.upsert("https://b.com", "c2").unwrap();
        repo.upsert("https://a.com", "c1").unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        // 按 url 排序
        assert_eq!(all[0].0, "https://a.com");
        assert_eq!(all[1].0, "https://b.com");
    }
}
