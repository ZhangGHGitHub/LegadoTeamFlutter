//! 隐私密码与私密标记 FFI API（契约 §2.53，批9a / 批9d）
//!
//! - 密码凭据：`legado-core::privacy` 派生 PBKDF2-HMAC-SHA256（210000 次 / 32B），
//!   salt 与 verifier 以 Base64 存 caches 表 `config:private_password_salt` /
//!   `config:private_password_verifier`，**不存明文密码**；
//! - 私密标记：`books.isPrivate`（单本）与 `book_groups.isPrivate`（分组）；
//! - [批9d] 生物识别快捷解锁：平台层只封装 32B 随机令牌，Rust 保存令牌
//!   SHA-256 摘要与平台加密信封（`config:private_biometric_*`）；改密/清密
//!   在同一事务内清空三键；
//! - 本模块只做数据层，不做 UI/路由/平台生物识别。

use std::sync::{Mutex, MutexGuard};

use base64::Engine;
use legado_core::privacy as password_crypto;
use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookGroupRepository, BookRepository, CacheRepository};

use crate::api::config_api::CONFIG_PREFIX;
use crate::db_state::with_database;

/// caches 键短名：密码 salt（Base64）
const PASSWORD_SALT_KEY: &str = "private_password_salt";
/// caches 键短名：密码 verifier（Base64）
const PASSWORD_VERIFIER_KEY: &str = "private_password_verifier";
/// caches 键短名：生物识别令牌摘要（SHA-256 标准 Base64）
const BIOMETRIC_TOKEN_HASH_KEY: &str = "private_biometric_token_hash";
/// caches 键短名：生物识别信封（平台 Keystore/Keychain 密文，Base64）
const BIOMETRIC_ENVELOPE_KEY: &str = "private_biometric_envelope";
/// caches 键短名：生物识别 IV（AES-GCM 12 字节，Base64）
const BIOMETRIC_IV_KEY: &str = "private_biometric_iv";
/// 新密码字符数上限（契约 §2.53）
const MAX_PASSWORD_CHARS: usize = 128;
/// 生物识别 IV 长度（AES-GCM 标准 96 bit，契约 §2.53 批9d）
const BIOMETRIC_IV_LEN: usize = 12;
/// 生物识别信封长度上限（解码后 1..=4096 字节）
const MAX_BIOMETRIC_ENVELOPE_LEN: usize = 4096;

/// 密码/生物凭据改写的进程内串行锁
///
/// 「读旧凭据 → 校验旧密码 → 生成新凭据 → 写键」必须是原子步骤：两个并发
/// `privacySetPassword` 若交错执行，都会读到旧凭据并各自写入新密码，产生
/// 丢失更新（后写覆盖先写且两次都返回 true）。生物识别的 set/clear 与改密/
/// 清密共用同一把锁，保证「改密清空信封」与「写入新信封」不会交错。
/// DB 写入本身另用事务保证多键同成同败。
static PRIVACY_PASSWORD_LOCK: Mutex<()> = Mutex::new(());

fn lock_password_mutations() -> MutexGuard<'static, ()> {
    PRIVACY_PASSWORD_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn config_key(short_key: &str) -> String {
    format!("{CONFIG_PREFIX}{short_key}")
}

/// 读取 caches 配置值（缺失/空串返回空串）
fn read_config(repo: &CacheRepository<'_>, short_key: &str) -> LegadoResult<String> {
    Ok(repo.get(&config_key(short_key))?.unwrap_or_default())
}

/// 严格 Base64 解码并要求长度恰为 [expected]（失败返回 None）
fn decode_exact_len(value: &str, expected: usize) -> Option<Vec<u8>> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .ok()?;
    (bytes.len() == expected).then_some(bytes)
}

/// 严格 Base64 解码并要求长度落在 [min_len]..=[max_len]（失败返回 None）
fn decode_len_range(value: &str, min_len: usize, max_len: usize) -> Option<Vec<u8>> {
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(value)
        .ok()?;
    (bytes.len() >= min_len && bytes.len() <= max_len).then_some(bytes)
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
/// - 读取旧凭据、校验与写入在同一进程内互斥窗口内完成；
/// - 成功生成新 16B salt + 32B verifier，事务内覆盖两键后返回 true。
pub fn privacy_set_password(password: &str, old_password: Option<&str>) -> LegadoResult<bool> {
    let trimmed = password.trim();
    if trimmed.is_empty() || trimmed.chars().count() > MAX_PASSWORD_CHARS {
        return Ok(false);
    }

    let _guard = lock_password_mutations();

    with_database(|db| {
        let conn = db.connection();
        // BEGIN IMMEDIATE：先拿写锁再读旧凭据，避免 DEFERRED 事务「先读后写」
        // 的 snapshot 升级冲突（SQLITE_BUSY_SNAPSHOT 不走 busy_timeout）。
        let tx =
            rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)
                .map_err(|e| LegadoError::Database(format!("开启隐私密码事务失败: {e}")))?;
        let (existing_salt, existing_verifier) = {
            let repo = CacheRepository::new(&tx);
            (
                read_config(&repo, PASSWORD_SALT_KEY)?,
                read_config(&repo, PASSWORD_VERIFIER_KEY)?,
            )
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
            // tx 随作用域 drop 回滚；凭据保持原值
            return Ok(false);
        }

        let (salt_b64, verifier_b64) = password_crypto::hash_password(password);
        {
            let repo = CacheRepository::new(&tx);
            repo.put(&config_key(PASSWORD_SALT_KEY), &salt_b64, 0)?;
            repo.put(&config_key(PASSWORD_VERIFIER_KEY), &verifier_b64, 0)?;
            // [批9d] 改密即失效生物快捷：与密码写入同事务清空三键
            //（含新密码与原密码相同的情况；令牌模型下「保留信封」会让旧
            // 令牌继续可用，比参考版更严格属登记差异）。
            repo.delete(&config_key(BIOMETRIC_TOKEN_HASH_KEY))?;
            repo.delete(&config_key(BIOMETRIC_ENVELOPE_KEY))?;
            repo.delete(&config_key(BIOMETRIC_IV_KEY))?;
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
///
/// [批9d] 同一事务内一并清空生物识别三键：清密后不能残留可用快捷入口。
pub fn privacy_clear_password() -> LegadoResult<()> {
    let _guard = lock_password_mutations();
    with_database(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启清除隐私密码事务失败: {e}")))?;
        {
            let repo = CacheRepository::new(&tx);
            repo.delete(&config_key(PASSWORD_SALT_KEY))?;
            repo.delete(&config_key(PASSWORD_VERIFIER_KEY))?;
            repo.delete(&config_key(BIOMETRIC_TOKEN_HASH_KEY))?;
            repo.delete(&config_key(BIOMETRIC_ENVELOPE_KEY))?;
            repo.delete(&config_key(BIOMETRIC_IV_KEY))?;
        }
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交清除隐私密码事务失败: {e}")))?;
        Ok(())
    })
}

/// 生物识别配置状态（不含摘要/令牌，契约 §2.53 批9d）
///
/// 返回裸 JSON `{"configured": bool, "envelope": String?, "iv": String?}`：
/// - `configured` 为三键齐备且摘要可解码为 32 字节；
/// - 仅在 configured 为 true 时返回信封/IV，避免未配置时泄露半套凭据。
pub fn privacy_biometric_state_get() -> LegadoResult<String> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let token_hash = read_config(&repo, BIOMETRIC_TOKEN_HASH_KEY)?;
        let envelope = read_config(&repo, BIOMETRIC_ENVELOPE_KEY)?;
        let iv = read_config(&repo, BIOMETRIC_IV_KEY)?;
        let configured = !token_hash.trim().is_empty()
            && !envelope.trim().is_empty()
            && !iv.trim().is_empty()
            && decode_exact_len(&token_hash, password_crypto::BIOMETRIC_TOKEN_HASH_LEN).is_some();
        let (envelope, iv) = if configured {
            (Some(envelope), Some(iv))
        } else {
            (None, None)
        };
        serde_json::to_string(&serde_json::json!({
            "configured": configured,
            "envelope": envelope,
            "iv": iv,
        }))
        .map_err(|e| LegadoError::Internal(format!("序列化生物识别状态失败: {e}")))
    })
}

/// 写入生物识别凭据：要求已有隐私密码，长度校验失败返回 false 且不落库
///
/// - token Base64 解码后必须恰为 32 字节；
/// - iv Base64 解码后必须恰为 12 字节；
/// - envelope Base64 解码后必须为 1..=4096 字节；
/// - 三键在同一事务内覆盖写入（均重编码为标准 Base64 后再存）。
pub fn privacy_biometric_set(
    token_b64: &str,
    envelope_b64: &str,
    iv_b64: &str,
) -> LegadoResult<bool> {
    let Some(token) = decode_exact_len(token_b64, password_crypto::BIOMETRIC_TOKEN_LEN) else {
        return Ok(false);
    };
    let Some(envelope) = decode_len_range(envelope_b64, 1, MAX_BIOMETRIC_ENVELOPE_LEN) else {
        return Ok(false);
    };
    let Some(iv) = decode_exact_len(iv_b64, BIOMETRIC_IV_LEN) else {
        return Ok(false);
    };

    let _guard = lock_password_mutations();
    let engine = base64::engine::general_purpose::STANDARD;
    with_database(|db| {
        let conn = db.connection();
        let tx =
            rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)
                .map_err(|e| LegadoError::Database(format!("开启生物识别事务失败: {e}")))?;
        {
            let repo = CacheRepository::new(&tx);
            // 必须已有隐私密码：无凭据时快捷解锁会绕过锁语义
            let salt = read_config(&repo, PASSWORD_SALT_KEY)?;
            let verifier = read_config(&repo, PASSWORD_VERIFIER_KEY)?;
            if salt.trim().is_empty() || verifier.trim().is_empty() {
                return Ok(false);
            }
            repo.put(
                &config_key(BIOMETRIC_TOKEN_HASH_KEY),
                &password_crypto::hash_biometric_token_base64(&token),
                0,
            )?;
            repo.put(
                &config_key(BIOMETRIC_ENVELOPE_KEY),
                &engine.encode(&envelope),
                0,
            )?;
            repo.put(&config_key(BIOMETRIC_IV_KEY), &engine.encode(&iv), 0)?;
        }
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交生物识别事务失败: {e}")))?;
        Ok(true)
    })
}

/// 校验生物识别令牌（摘要常量时间比较；无摘要/非法令牌返回 false）
///
/// 通过只代表「平台解封的令牌与登记一致」，授权范围由 Dart 按
/// `unlockScope` 决定，本函数不改变任何解锁状态。
pub fn privacy_biometric_verify(token_b64: &str) -> LegadoResult<bool> {
    let Some(token) = decode_exact_len(token_b64, password_crypto::BIOMETRIC_TOKEN_LEN) else {
        return Ok(false);
    };
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let token_hash = read_config(&repo, BIOMETRIC_TOKEN_HASH_KEY)?;
        if token_hash.trim().is_empty() {
            return Ok(false);
        }
        Ok(password_crypto::verify_biometric_token(&token, &token_hash))
    })
}

/// 清除生物识别凭据：删除摘要/信封/IV 三键（不存在为 no-op）
pub fn privacy_biometric_clear() -> LegadoResult<()> {
    let _guard = lock_password_mutations();
    with_database(|db| {
        let conn = db.connection();
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启清除生物识别事务失败: {e}")))?;
        {
            let repo = CacheRepository::new(&tx);
            repo.delete(&config_key(BIOMETRIC_TOKEN_HASH_KEY))?;
            repo.delete(&config_key(BIOMETRIC_ENVELOPE_KEY))?;
            repo.delete(&config_key(BIOMETRIC_IV_KEY))?;
        }
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交清除生物识别事务失败: {e}")))?;
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
///
/// `group_id` 使用 i64：存量分组可能是原版时间戳 ID（如 `1793904884364`），
/// 必须与既有分组 CRUD（`book_group_*` 均为 i64）保持一致，避免截断。
pub fn set_book_group_private(group_id: i64, is_private: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = BookGroupRepository::new(db.connection());
        repo.set_private(group_id, is_private)
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
        // 只断言本用例自己的 URL：共享测试库可能残留其他用例的私密行
        let private_own: Vec<String> = get_private_book_urls()
            .unwrap()
            .into_iter()
            .filter(|url| urls.contains(url))
            .collect();
        assert_eq!(private_own, vec![urls[0].clone(), urls[2].clone()]);

        // 取消一本
        let one = format!(r#"["{}"]"#, urls[2]);
        assert_eq!(set_books_private(&one, false).unwrap(), 1);
        let private_own: Vec<String> = get_private_book_urls()
            .unwrap()
            .into_iter()
            .filter(|url| urls.contains(url))
            .collect();
        assert_eq!(private_own, vec![urls[0].clone()]);

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

    /// 分组私密：命中 true / 未命中 false；私密 ID 升序；
    /// 存量时间戳 ID（超出 i32）不得截断
    #[test]
    fn test_set_book_group_private_and_get_private_group_ids() {
        let _db_guard = crate::db_state::ensure_test_db();
        /// 原版/参考版存量时间戳分组 ID（39 位，超出 i32 范围）
        const LEGACY_TIMESTAMP_ID: i64 = 1_793_904_884_364;
        let ids = [16_i64, LEGACY_TIMESTAMP_ID];
        let db = crate::db_state::database_from_pool().unwrap();
        let repo = BookGroupRepository::new(db.connection());
        for id in ids {
            repo.delete(id).unwrap();
            repo.insert(&legado_db::BookGroup {
                group_id: id,
                group_name: format!("隐私分组{id}"),
                order: 0,
                is_private: false,
                ..legado_db::BookGroup::default()
            })
            .unwrap();
        }

        assert!(set_book_group_private(16, true).unwrap());
        assert!(
            set_book_group_private(LEGACY_TIMESTAMP_ID, true).unwrap(),
            "i64 旧时间戳分组 ID 必须完整命中，不得截断"
        );
        assert!(!set_book_group_private(999_999, true).unwrap());

        let private_own: Vec<i64> = get_private_group_ids()
            .unwrap()
            .into_iter()
            .filter(|id| ids.contains(id))
            .collect();
        assert_eq!(private_own, vec![16, LEGACY_TIMESTAMP_ID]);

        assert!(set_book_group_private(LEGACY_TIMESTAMP_ID, false).unwrap());
        let private_own: Vec<i64> = get_private_group_ids()
            .unwrap()
            .into_iter()
            .filter(|id| ids.contains(id))
            .collect();
        assert_eq!(private_own, vec![16]);

        // 读回确认旧时间戳组确已取消
        let legacy = repo.find_by_id(LEGACY_TIMESTAMP_ID).unwrap().unwrap();
        assert!(!legacy.is_private);

        // 清理
        for id in ids {
            repo.delete(id).unwrap();
        }
    }

    /// [批9a 审查 P1-1] 清缓存不得删除隐私密码凭据
    #[test]
    fn test_cache_clear_preserves_private_password() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        assert!(privacy_set_password("cache-pass", None).unwrap());

        assert!(crate::api::cache_api::clear_cache().unwrap());

        assert!(
            privacy_has_password().unwrap(),
            "清缓存后仍应识别为已设置密码"
        );
        assert!(
            privacy_verify_password("cache-pass").unwrap(),
            "清缓存后原密码仍应校验通过（不得退化为可重设）"
        );
        privacy_clear_password().unwrap();
    }

    /// [批9a 审查 P3] 并发改密：进程内互斥 + 事务保证只有一次成功，
    /// 不出现「两次都 true 且后写覆盖先写」的丢失更新
    #[test]
    fn test_privacy_set_password_concurrent_serialized() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        assert!(privacy_set_password("initial-pass", None).unwrap());

        let results = std::thread::scope(|scope| {
            let a = scope.spawn(|| privacy_set_password("new-a", Some("initial-pass")).unwrap());
            let b = scope.spawn(|| privacy_set_password("new-b", Some("initial-pass")).unwrap());
            (a.join().unwrap(), b.join().unwrap())
        });
        assert_eq!(
            [results.0, results.1]
                .iter()
                .filter(|succeeded| **succeeded)
                .count(),
            1,
            "并发改密只允许一次成功"
        );
        assert!(
            privacy_verify_password("new-a").unwrap() || privacy_verify_password("new-b").unwrap(),
            "最终密码应为成功那一次写入的新密码"
        );
        privacy_clear_password().unwrap();
    }

    // ===== [批9d] 生物识别快捷解锁（随机令牌信封） =====

    use base64::Engine;

    /// 构造测试用标准 Base64 令牌/信封/IV
    fn b64(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn biometric_state_json() -> serde_json::Value {
        serde_json::from_str(&privacy_biometric_state_get().unwrap()).unwrap()
    }

    /// 状态往返：未配置 → 写入 → configured/envelope/iv（不含摘要/令牌）
    /// → 正确令牌 true / 错误令牌 false → 清除 → no-op
    #[test]
    fn test_privacy_biometric_lifecycle() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        privacy_biometric_clear().unwrap();
        assert!(privacy_set_password("bio-pass", None).unwrap());

        let state = biometric_state_json();
        assert_eq!(state["configured"], false);
        assert!(state["envelope"].is_null());
        assert!(state["iv"].is_null());
        assert!(state.get("token_hash").is_none(), "状态不得返回摘要");

        let token = b64(&[3u8; password_crypto::BIOMETRIC_TOKEN_LEN]);
        let envelope = b64(&[9u8; 64]);
        let iv = b64(&[5u8; BIOMETRIC_IV_LEN]);
        assert!(privacy_biometric_set(&token, &envelope, &iv).unwrap());

        let state = biometric_state_json();
        assert_eq!(state["configured"], true);
        assert_eq!(state["envelope"], envelope);
        assert_eq!(state["iv"], iv);
        assert!(state.get("token_hash").is_none(), "状态不得返回摘要");
        assert!(
            !privacy_biometric_state_get()
                .unwrap()
                .contains("token_hash"),
            "状态 JSON 不得包含摘要字段"
        );

        assert!(privacy_biometric_verify(&token).unwrap());
        assert!(!privacy_biometric_verify(&b64(&[4u8; 32])).unwrap());
        assert!(!privacy_biometric_verify("not-base64!!").unwrap());
        assert!(!privacy_biometric_verify(&b64(&[3u8; 31])).unwrap());

        privacy_biometric_clear().unwrap();
        assert_eq!(biometric_state_json()["configured"], false);
        assert!(!privacy_biometric_verify(&token).unwrap());
        privacy_biometric_clear().unwrap();

        privacy_clear_password().unwrap();
    }

    /// 长度/编码校验：token 31/33B、iv 11/13B、envelope 空/>4096B、
    /// 非 Base64 一律 false 且不落库；1B/4096B 为合法边界
    #[test]
    fn test_privacy_biometric_set_rejects_invalid_lengths() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        privacy_biometric_clear().unwrap();
        assert!(privacy_set_password("bio-pass", None).unwrap());

        let token = b64(&[3u8; password_crypto::BIOMETRIC_TOKEN_LEN]);
        let envelope = b64(&[9u8; 32]);
        let iv = b64(&[5u8; BIOMETRIC_IV_LEN]);

        let invalid: Vec<(String, String, String)> = vec![
            (b64(&[3u8; 31]), envelope.clone(), iv.clone()),
            (b64(&[3u8; 33]), envelope.clone(), iv.clone()),
            (token.clone(), envelope.clone(), b64(&[5u8; 11])),
            (token.clone(), envelope.clone(), b64(&[5u8; 13])),
            (token.clone(), String::new(), iv.clone()),
            (
                token.clone(),
                b64(&[9u8; MAX_BIOMETRIC_ENVELOPE_LEN + 1]),
                iv.clone(),
            ),
            (String::new(), envelope.clone(), iv.clone()),
            ("not-base64!!".into(), envelope.clone(), iv.clone()),
            (token.clone(), "not-base64!!".into(), iv.clone()),
            (token.clone(), envelope.clone(), "not-base64!!".into()),
        ];
        for (token, envelope, iv) in invalid {
            assert!(
                !privacy_biometric_set(&token, &envelope, &iv).unwrap(),
                "非法长度/编码必须返回 false: token={token} len(env)={}",
                envelope.len()
            );
        }
        assert_eq!(
            biometric_state_json()["configured"],
            false,
            "校验失败不得落库"
        );

        // 边界合法：信封 1B / 4096B
        assert!(privacy_biometric_set(&token, &b64(&[1u8]), &iv).unwrap());
        assert!(
            privacy_biometric_set(&token, &b64(&[9u8; MAX_BIOMETRIC_ENVELOPE_LEN]), &iv).unwrap()
        );
        assert_eq!(biometric_state_json()["configured"], true);

        privacy_biometric_clear().unwrap();
        privacy_clear_password().unwrap();
    }

    /// 必须已有隐私密码：无密码时 set 返回 false 且不落库
    #[test]
    fn test_privacy_biometric_set_requires_password() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        privacy_biometric_clear().unwrap();

        let token = b64(&[3u8; password_crypto::BIOMETRIC_TOKEN_LEN]);
        let envelope = b64(&[9u8; 32]);
        let iv = b64(&[5u8; BIOMETRIC_IV_LEN]);
        assert!(!privacy_biometric_set(&token, &envelope, &iv).unwrap());
        assert!(!privacy_has_password().unwrap());
        assert_eq!(biometric_state_json()["configured"], false);
        assert!(!privacy_biometric_verify(&token).unwrap());
    }

    /// 改密/清密在同一事务内清空三键（改密即失效生物快捷）
    #[test]
    fn test_privacy_password_mutation_clears_biometric() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        privacy_biometric_clear().unwrap();
        assert!(privacy_set_password("first-pass", None).unwrap());

        let token = b64(&[3u8; password_crypto::BIOMETRIC_TOKEN_LEN]);
        let envelope = b64(&[9u8; 32]);
        let iv = b64(&[5u8; BIOMETRIC_IV_LEN]);
        assert!(privacy_biometric_set(&token, &envelope, &iv).unwrap());
        assert!(privacy_biometric_verify(&token).unwrap());

        // 改密（旧密正确）→ 三键清空
        assert!(privacy_set_password("second-pass", Some("first-pass")).unwrap());
        assert_eq!(biometric_state_json()["configured"], false);
        assert!(
            !privacy_biometric_verify(&token).unwrap(),
            "改密后旧令牌必须失效"
        );
        // 三键真的删除（不是仅 configured 判定为 false）
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            assert_eq!(repo.get("config:private_biometric_token_hash")?, None);
            assert_eq!(repo.get("config:private_biometric_envelope")?, None);
            assert_eq!(repo.get("config:private_biometric_iv")?, None);
            Ok(())
        })
        .unwrap();

        // 重新配置后清密 → 三键清空
        assert!(privacy_biometric_set(&token, &envelope, &iv).unwrap());
        privacy_clear_password().unwrap();
        assert_eq!(biometric_state_json()["configured"], false);
        assert!(!privacy_biometric_verify(&token).unwrap());
    }

    /// 失败改密（旧密错误）不得清空已配置的生物凭据
    #[test]
    fn test_privacy_failed_password_change_keeps_biometric() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        privacy_biometric_clear().unwrap();
        assert!(privacy_set_password("first-pass", None).unwrap());

        let token = b64(&[3u8; password_crypto::BIOMETRIC_TOKEN_LEN]);
        assert!(privacy_biometric_set(&token, &b64(&[9u8; 32]), &b64(&[5u8; 12])).unwrap());

        assert!(!privacy_set_password("second-pass", Some("wrong")).unwrap());
        assert!(privacy_biometric_verify(&token).unwrap());
        assert_eq!(biometric_state_json()["configured"], true);

        privacy_biometric_clear().unwrap();
        privacy_clear_password().unwrap();
    }

    /// 清缓存保留生物识别三键（与密码凭据同口径）
    #[test]
    fn test_cache_clear_preserves_private_biometric() {
        let _db_guard = crate::db_state::ensure_test_db();
        privacy_clear_password().unwrap();
        privacy_biometric_clear().unwrap();
        assert!(privacy_set_password("cache-pass", None).unwrap());
        let token = b64(&[3u8; password_crypto::BIOMETRIC_TOKEN_LEN]);
        let envelope = b64(&[9u8; 32]);
        let iv = b64(&[5u8; BIOMETRIC_IV_LEN]);
        assert!(privacy_biometric_set(&token, &envelope, &iv).unwrap());

        assert!(crate::api::cache_api::clear_cache().unwrap());

        assert_eq!(biometric_state_json()["configured"], true);
        assert!(privacy_biometric_verify(&token).unwrap());

        privacy_biometric_clear().unwrap();
        privacy_clear_password().unwrap();
    }
}
