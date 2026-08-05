//! 用户管理 API
//!
//! 提供用户 CRUD、登录/登出等操作，替代 Flutter 侧 SharedPreferences 存储。

use legado_core::LegadoResult;
use legado_db::UserRepository;

use crate::db_state::with_database;

/// 获取所有用户（JSON 数组）
pub fn get_users() -> LegadoResult<String> {
    with_database(|db| {
        let repo = UserRepository::new(db.connection());
        let users = repo.get_all()?;
        let json = serde_json::to_string(&users)
            .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))?;
        Ok(json)
    })
}

/// 保存用户（新增或更新），返回用户 ID
pub fn save_user(username: &str, password: &str, source_url: &str) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = UserRepository::new(db.connection());
        // 如果用户已存在，先删除再插入（简化 upsert）
        if repo.find_by_username(username)?.is_some() {
            repo.delete(username)?;
        }
        let id = repo.insert(username, password, source_url)?;
        Ok(id)
    })
}

/// 删除用户
pub fn delete_user(username: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = UserRepository::new(db.connection());
        repo.delete(username)
    })
}

/// 登录（更新登录状态和 token）
pub fn login(username: &str, password: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = UserRepository::new(db.connection());
        let user = repo.find_by_username(username)?;
        match user {
            Some(u) if u.password_hash == password => {
                // 生成简单 token（实际应使用更安全的方案）
                let token = format!(
                    "tk_{}_{}",
                    username,
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .unwrap_or_default()
                        .as_millis()
                );
                repo.update_login_status(username, true, &token)?;
                Ok(true)
            }
            _ => Ok(false),
        }
    })
}

/// 退出登录
pub fn logout(username: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = UserRepository::new(db.connection());
        match repo.find_by_username(username)? {
            Some(_) => {
                repo.update_login_status(username, false, "")?;
                Ok(true)
            }
            None => Ok(false),
        }
    })
}

/// 检查登录状态
pub fn check_login_status(username: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = UserRepository::new(db.connection());
        match repo.find_by_username(username)? {
            Some(u) => Ok(u.is_logged_in),
            None => Ok(false),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_user_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 保存用户
        let id = save_user("test_user", "pass123", "https://example.com").unwrap();
        assert!(id > 0);

        // 获取用户列表
        let json = get_users().unwrap();
        assert!(json.contains("test_user"));

        // 登录
        assert!(login("test_user", "pass123").unwrap());
        assert!(check_login_status("test_user").unwrap());

        // 错误密码
        assert!(!login("test_user", "wrong").unwrap());

        // 退出
        assert!(logout("test_user").unwrap());
        assert!(!check_login_status("test_user").unwrap());

        // 删除
        assert!(delete_user("test_user").unwrap());
        assert!(!delete_user("test_user").unwrap());
    }
}
