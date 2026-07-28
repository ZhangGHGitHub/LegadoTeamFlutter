//! User Repository - users 表 CRUD
//!
//! 提供用户账户管理的数据访问层，替代 SharedPreferences 存储。

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

/// 用户记录
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserRecord {
    pub id: i64,
    pub username: String,
    pub password_hash: String,
    pub source_url: String,
    pub token: String,
    pub is_logged_in: bool,
    pub created_at: i64,
    pub updated_at: i64,
}

/// 用户数据访问层
pub struct UserRepository<'a> {
    conn: &'a Connection,
}

impl<'a> UserRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入新用户，返回新记录 ID
    pub fn insert(
        &self,
        username: &str,
        password_hash: &str,
        source_url: &str,
    ) -> LegadoResult<i64> {
        let now = chrono_now();
        self.conn
            .execute(
                "INSERT INTO users (username, password_hash, source_url, token, is_logged_in, created_at, updated_at)
                 VALUES (?1, ?2, ?3, '', 0, ?4, ?4)",
                params![username, password_hash, source_url, now],
            )
            .map_err(|e| LegadoError::Database(format!("插入用户失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 按用户名查找用户
    pub fn find_by_username(&self, username: &str) -> LegadoResult<Option<UserRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, username, password_hash, source_url, token, is_logged_in, created_at, updated_at
                 FROM users WHERE username = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let result = stmt
            .query_row(params![username], |row| {
                Ok(UserRecord {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    password_hash: row.get(2)?,
                    source_url: row.get(3)?,
                    token: row.get(4)?,
                    is_logged_in: row.get::<_, i32>(5)? != 0,
                    created_at: row.get(6)?,
                    updated_at: row.get(7)?,
                })
            })
            .ok();
        Ok(result)
    }

    /// 更新登录状态
    pub fn update_login_status(
        &self,
        username: &str,
        is_logged_in: bool,
        token: &str,
    ) -> LegadoResult<()> {
        let now = chrono_now();
        let affected = self
            .conn
            .execute(
                "UPDATE users SET is_logged_in = ?1, token = ?2, updated_at = ?3 WHERE username = ?4",
                params![is_logged_in as i32, token, now, username],
            )
            .map_err(|e| LegadoError::Database(format!("更新登录状态失败: {e}")))?;
        if affected == 0 {
            return Err(LegadoError::Database(format!(
                "用户不存在: {username}"
            )));
        }
        Ok(())
    }

    /// 按用户名删除用户
    pub fn delete(&self, username: &str) -> LegadoResult<bool> {
        let affected = self
            .conn
            .execute("DELETE FROM users WHERE username = ?1", params![username])
            .map_err(|e| LegadoError::Database(format!("删除用户失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 获取所有用户
    pub fn get_all(&self) -> LegadoResult<Vec<UserRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, username, password_hash, source_url, token, is_logged_in, created_at, updated_at
                 FROM users ORDER BY id",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], |row| {
                Ok(UserRecord {
                    id: row.get(0)?,
                    username: row.get(1)?,
                    password_hash: row.get(2)?,
                    source_url: row.get(3)?,
                    token: row.get(4)?,
                    is_logged_in: row.get::<_, i32>(5)? != 0,
                    created_at: row.get(6)?,
                    updated_at: row.get(7)?,
                })
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }
}

/// 获取当前时间戳（毫秒）
fn chrono_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_insert_and_find() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = UserRepository::new(db.connection());

        let id = repo.insert("alice", "hash123", "https://src.com").unwrap();
        assert!(id > 0);

        let user = repo.find_by_username("alice").unwrap().unwrap();
        assert_eq!(user.username, "alice");
        assert_eq!(user.password_hash, "hash123");
        assert_eq!(user.source_url, "https://src.com");
        assert!(!user.is_logged_in);
    }

    #[test]
    fn test_find_nonexistent() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = UserRepository::new(db.connection());

        let result = repo.find_by_username("nobody").unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_update_login_status() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = UserRepository::new(db.connection());

        repo.insert("bob", "pass", "https://b.com").unwrap();
        repo.update_login_status("bob", true, "token_abc").unwrap();

        let user = repo.find_by_username("bob").unwrap().unwrap();
        assert!(user.is_logged_in);
        assert_eq!(user.token, "token_abc");
    }

    #[test]
    fn test_delete_user() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = UserRepository::new(db.connection());

        repo.insert("charlie", "pw", "").unwrap();
        assert!(repo.delete("charlie").unwrap());
        assert!(!repo.delete("charlie").unwrap()); // 第二次删除返回 false
        assert!(repo.find_by_username("charlie").unwrap().is_none());
    }

    #[test]
    fn test_get_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = UserRepository::new(db.connection());

        repo.insert("user1", "h1", "s1").unwrap();
        repo.insert("user2", "h2", "s2").unwrap();
        repo.insert("user3", "h3", "s3").unwrap();

        let all = repo.get_all().unwrap();
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].username, "user1");
        assert_eq!(all[2].username, "user3");
    }
}
