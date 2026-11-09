//! 隐私密码与私密标记 FFI API（契约 §2.53，批9a）
//!
//! - 密码凭据：`legado-core::privacy` 派生 PBKDF2-HMAC-SHA256（210000 次 / 32B），
//!   salt 与 verifier 以 Base64 存 caches 表 `config:private_password_salt` /
//!   `config:private_password_verifier`，**不存明文密码**；
//! - 私密标记：`books.isPrivate`（单本）与 `book_groups.isPrivate`（分组）；
//! - 本模块只做数据层，不做 UI/路由/平台生物识别。

use legado_core::privacy as password_crypto;
use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookGroupRepository, BookRepository, CacheRepository};

use crate::api::config_api::CONFIG_PREFIX;
use crate::db_state::with_database;

/// caches 键短名：密码 salt（Base64）
const PASSWORD_SALT_KEY: &str = "private_password_salt";
/// caches 键短名：密码 verifier（Base64）
const PASSWORD_VERIFIER_KEY: &str = "private_password_verifier";
/// 新密码字符数上限（契约 §2.53）
const MAX_PASSWORD_CHARS: usize = 128;

fn config_key(short_key: &str) -> String {
    format!("{CONFIG_PREFIX}{short_key}")
}

/// 读取 caches 配置值（缺失/空串返回空串）
fn read_config(repo: &CacheRepository<'_>, short_key: &str) -> LegadoResult<String> {
    Ok(repo.get(&config_key(short_key))?.unwrap_or_default())
}

/// 是否已设置隐私密码：salt 与 verifier 均存在（非空）
pub fn privacy_has_password() -> LegadoResult<bool> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let salt = read_config(&repo, PASSWORD_SALT_KEY)?;
        let verifier = read_config(&repo, PASSWORD_VERIFIER_KEY)?;
        Ok(!salt.trim().is_empty() && !verifier.trim().is_empty())
    })
}

/// 设置/修改隐私密码
///
/// - 新密码 `trim()` 后必须非空且字符数 1..=128，否则返回 false（不落库）；
/// - 已有凭据时旧密码必须匹配（`old_password` 为 None 或错误 → false，不改库）；
/// - 无旧凭据时忽略 `old_password`；
/// - 成功生成新 16B salt + 32B verifier，事务内覆盖两键后返回 true。
pub fn privacy_set_password(password: &str, old_password: Option<&str>) -> LegadoResult<bool> {
    let trimmed = password.trim();
    if trimmed.is_empty() || trimmed.chars().count() > MAX_PASSWORD_CHARS {
        return Ok(false);
    }

    with_database(|db| {
        let conn = db.connection();
        let existing_salt = {
            let repo = CacheRepository::new(conn);
            read_config(&repo, PASSWORD_SALT_KEY)?
        };
        let existing_verifier = {
            let repo = CacheRepository::new(conn);
            read_config(&repo, PASSWORD_VERIFIER_KEY)?
        };
        let has_credentials =
            !existing_salt.trim().is_empty() && !existing_verifier.trim().is_empty();

        if has_credentials
            && !old_password
                .map(|old| {
                    password_crypto::verify_password(old, &existing_salt, &existing_verifier)
                })
                .unwrap_or(false)
        {
            return Ok(false);
        }

        let (salt_b64, verifier_b64) = password_crypto::hash_password(password);
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启隐私密码事务失败: {e}")))?;
        {
            let repo = CacheRepository::new(&tx);
            repo.put(&config_key(PASSWORD_SALT_KEY), &salt_b64, 0)?;
            repo.put(&config_key(PASSWORD_VERIFIER_KEY), &verifier_b64, 0)?;
        }
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交隐私密码事务失败: {e}")))?;
        Ok(true)
    })
}

/// 校验隐私密码
///
/// 无凭据或空密码返回 false；否则 PBKDF2 派生后常量时间比较。
pub fn privacy_verify_password(password: &str) -> LegadoResult<bool> {
    if password.is_empty() {
        return Ok(false);
    }
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let salt = read_config(&repo, PASSWORD_SALT_KEY)?;
        let verifier = read_config(&repo, PASSWORD_VERIFIER_KEY)?;
        if salt.trim().is_empty() || verifier.trim().is_empty() {
            return Ok(false);
        }
        Ok(password_crypto::verify_password(password, &salt, &verifier))
    })
}

/// 清除隐私密码：删除 salt 与 verifier 两键（不存在为 no-op）
pub fn privacy_clear_password() -> LegadoResult<()> {
    with_database(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启清除隐私密码事务失败: {e}")))?;
        {
            let repo = CacheRepository::new(&tx);
            repo.delete(&config_key(PASSWORD_SALT_KEY))?;
            repo.delete(&config_key(PASSWORD_VERIFIER_KEY))?;
        }
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交清除隐私密码事务失败: {e}")))?;
        Ok(())
    })
}

/// 严格解析书籍 URL JSON 数组（非数组 / 元素非字符串 → 参数错误）
fn parse_book_urls(book_urls_json: &str) -> LegadoResult<Vec<String>> {
    let value: serde_json::Value = serde_json::from_str(book_urls_json)
        .map_err(|e| LegadoError::Parser(format!("解析书籍 URL 列表 JSON 失败: {e}")))?;
    let array = value
        .as_array()
        .ok_or_else(|| LegadoError::Parser("书籍 URL 列表必须是 JSON 数组".into()))?;
    let mut urls = Vec::with_capacity(array.len());
    for item in array {
        let url = item
            .as_str()
            .ok_or_else(|| LegadoError::Parser("书籍 URL 数组元素必须是字符串".into()))?;
        urls.push(url.to_string());
    }
    Ok(urls)
}

/// 批量设置书籍私密标记，返回实际更新行数（空数组 0）
pub fn set_books_private(book_urls_json: &str, is_private: bool) -> LegadoResult<usize> {
    let urls = parse_book_urls(book_urls_json)?;
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.set_private(&urls, is_private)
    })
}

/// 全部私密书籍 URL（按 bookUrl 升序）
pub fn get_private_book_urls() -> LegadoResult<Vec<String>> {
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.private_book_urls()
    })
}

/// 设置分组私密标记，返回是否命中行
pub fn set_book_group_private(group_id: i32, is_private: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        repo.set_private(i64::from(group_id), is_private)
    })
}

/// 全部私密分组 ID（升序）
pub fn get_private_group_ids() -> LegadoResult<Vec<i64>> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        repo.private_group_ids()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_db::repository::Repository;

    fn unique(prefix: &str, suffix: &str) -> String {
        format!("https://privacy.test/{prefix}/{suffix}")
    }

    /// 密码全生命周期：无凭据 → 设置 → 校验 → 错误旧密拒绝 → 改密 → 清除
    #[test]
    fn test_privacy_password_lifecycle() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();

        assert!(!privacy_has_password().unwrap());
        assert!(!privacy_verify_password("anything").unwrap());
        assert!(!privacy_verify_password("").unwrap());

        // 无旧凭据：忽略 oldPassword
        assert!(privacy_set_password("first-pass", Some("ignored")).unwrap());
        assert!(privacy_has_password().unwrap());
        assert!(privacy_verify_password("first-pass").unwrap());
        assert!(!privacy_verify_password("wrong").unwrap());

        // 已有凭据：旧密码缺失/错误 → false 且不改库
        assert!(!privacy_set_password("second-pass", None).unwrap());
        assert!(!privacy_set_password("second-pass", Some("wrong-old")).unwrap());
        assert!(
            privacy_verify_password("first-pass").unwrap(),
            "失败改密不得覆盖原凭据"
        );

        // 正确旧密码 → 改密成功，新旧密码切换
        assert!(privacy_set_password("second-pass", Some("first-pass")).unwrap());
        assert!(privacy_verify_password("second-pass").unwrap());
        assert!(!privacy_verify_password("first-pass").unwrap());

        // 清除：两键删除，之后 has/verify 均 false；重复清除 no-op
        privacy_clear_password().unwrap();
        assert!(!privacy_has_password().unwrap());
        assert!(!privacy_verify_password("second-pass").unwrap());
        privacy_clear_password().unwrap();
    }

    /// 新密码长度/空白校验：trim 后空或超过 128 字符一律 false
    #[test]
    fn test_privacy_set_password_validation() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();

        assert!(!privacy_set_password("", None).unwrap());
        assert!(!privacy_set_password("   ", None).unwrap());
        assert!(!privacy_set_password(&"x".repeat(129), None).unwrap());
        assert!(!privacy_has_password().unwrap(), "非法密码不得落库");

        // 128 字符是允许的上界（含首尾空白的 128 字符密码也合法）
        let max_password = format!(" {} ", "x".repeat(126));
        assert!(privacy_set_password(&max_password, None).unwrap());
        assert!(privacy_verify_password(&max_password).unwrap());
        privacy_clear_password().unwrap();
    }

    /// 批量私密标记：多本命中/不存在不计数/空数组 0/重复 URL 去重/稳定排序
    #[test]
    fn test_set_books_private_and_get_private_book_urls() {
        let _db_guard = crate::db_state::ensure_test_db();
        let urls = [
            unique("books", "a"),
            unique("books", "b"),
            unique("books", "c"),
        ];
        {
            let db = crate::db_state::database_from_pool().unwrap();
            let repo = BookRepository::new(db.connection());
            for (i, url) in urls.iter().enumerate() {
                repo.delete_by_url(url).unwrap();
                repo.insert(&legado_core::models::Book {
                    book_url: url.clone(),
                    name: format!("隐私测试书{i}"),
                    author: "批9a".to_string(),
                    ..legado_core::models::Book::default()
                })
                .unwrap();
            }
        }

        let json = format!(
            r#"["{}","{}","{}","{}"]"#,
            urls[2],
            urls[0],
            urls[2],
            unique("books", "missing")
        );
        assert_eq!(set_books_private(&json, true).unwrap(), 2);
        assert_eq!(
            get_private_book_urls().unwrap(),
            vec![urls[0].clone(), urls[2].clone()],
            "私密 URL 升序"
        );

        // 取消一本
        let one = format!(r#"["{}"]"#, urls[2]);
        assert_eq!(set_books_private(&one, false).unwrap(), 1);
        assert_eq!(get_private_book_urls().unwrap(), vec![urls[0].clone()]);

        // 空数组
        assert_eq!(set_books_private("[]", true).unwrap(), 0);

        // 清理
        {
            let db = crate::db_state::database_from_pool().unwrap();
            let repo = BookRepository::new(db.connection());
            for url in &urls {
                repo.delete_by_url(url).unwrap();
            }
        }
    }

    /// JSON 入参严格校验：非法 / 非数组 / 元素非字符串 → 参数错误
    #[test]
    fn test_set_books_private_rejects_invalid_json() {
        let _db_guard = crate::db_state::ensure_test_db();

        let err = set_books_private("not-json", true).unwrap_err();
        assert!(
            err.to_string().contains("解析书籍 URL 列表 JSON 失败"),
            "{err}"
        );

        let err = set_books_private(r#"{"bookUrl":"x"}"#, true).unwrap_err();
        assert!(err.to_string().contains("必须是 JSON 数组"), "{err}");

        let err = set_books_private(r#"["ok", 42]"#, true).unwrap_err();
        assert!(err.to_string().contains("元素必须是字符串"), "{err}");
    }

    /// 分组私密：命中 true / 未命中 false；私密 ID 升序
    #[test]
    fn test_set_book_group_private_and_get_private_group_ids() {
        let _db_guard = crate::db_state::ensure_test_db();
        let db = crate::db_state::database_from_pool().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        for id in [1_i64, 4, 16] {
            repo.delete(id).unwrap();
            repo.insert(&legado_db::BookGroup {
                group_id: id,
                group_name: format!("隐私分组{id}"),
                order: id as i32,
                ..legado_db::BookGroup::default()
            })
            .unwrap();
        }

        assert!(set_book_group_private(4, true).unwrap());
        assert!(set_book_group_private(16, true).unwrap());
        assert!(!set_book_group_private(999_999, true).unwrap());
        assert_eq!(get_private_group_ids().unwrap(), vec![4, 16]);

        assert!(set_book_group_private(4, false).unwrap());
        assert_eq!(get_private_group_ids().unwrap(), vec![16]);

        // 清理
        for id in [1_i64, 4, 16] {
            repo.delete(id).unwrap();
        }
    }
}
