//! 配置管理 API
//!
//! 基于 caches 表实现应用配置的读写操作。

use std::sync::atomic::{AtomicBool, Ordering};

use legado_core::LegadoResult;
use legado_db::CacheRepository;

use crate::db_state::with_database;

/// 配置键前缀
///
/// `pub(crate)`：备份模块（`backup_api`）读写 `directLinkUploadRule` 配置时复用
/// 同一前缀，避免键格式在两处漂移。
pub(crate) const CONFIG_PREFIX: &str = "config:";

/// 全局 User-Agent 配置短键（批9b-4）
///
/// 与 Dart 偏好键 `userAgent`（`pref_keys.dart`）及原版 `PreferKey.userAgent`
/// 同名；`set_config` 落库成功后同步更新 `legado-net` 进程级默认 UA 覆盖。
pub const USER_AGENT_CONFIG_KEY: &str = "userAgent";

/// 读配置行失败的一次性告警标记（高频路径，避免逐行刷屏）
static CONFIG_ROW_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 获取指定配置项的值（不存在返回空字符串）
pub fn get_config(key: &str) -> LegadoResult<String> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let full_key = format!("{}{}", CONFIG_PREFIX, key);
        Ok(repo.get(&full_key)?.unwrap_or_default())
    })
}

/// 设置配置项
///
/// 批9b-4：`userAgent` 键在落库成功后同步更新 `legado-net` 进程级默认
/// UA——非空值即时成为所有未显式设置 `User-Agent` 请求的默认，空/纯空白
/// 清除覆盖并回落内置默认。落库失败时**不改变**运行期值（避免 UI 显示
/// 与运行期分叉，同 `set_http_log_recording` 口径）。
pub fn set_config(key: &str, value: &str) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let full_key = format!("{}{}", CONFIG_PREFIX, key);
        repo.put(&full_key, value, 0)?; // ttl=0 永不过期
        Ok(true)
    })?;

    if key == USER_AGENT_CONFIG_KEY {
        legado_net::set_default_user_agent(Some(value));
    }

    Ok(true)
}

/// 启动时从 caches 回填进程级默认 User-Agent（由 `db_open` 调用，尽力而为）
///
/// 对齐原版 `AppConfig.userAgent = getPrefUserAgent()` 的启动初始化：
/// 空/纯空白清除覆盖（回落内置默认）；DB 未初始化/读失败仅记日志，
/// 不阻断启动。
pub fn restore_user_agent() {
    if !crate::db_state::is_initialized() {
        return;
    }
    match get_config(USER_AGENT_CONFIG_KEY) {
        Ok(value) => {
            let trimmed = value.trim();
            legado_net::set_default_user_agent(if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            });
            if !trimmed.is_empty() {
                log::info!("全局 User-Agent（config:userAgent）已从配置恢复");
            }
        }
        Err(e) => log::warn!("读取 config:userAgent 失败，默认 UA 保持内置值: {e}"),
    }
}

/// 获取所有配置项（JSON 对象）
pub fn get_all_config() -> LegadoResult<std::collections::HashMap<String, String>> {
    with_database(|db| {
        let conn = db.connection();
        let mut stmt = conn
            .prepare("SELECT key, value FROM caches WHERE key LIKE ?1")
            .map_err(|e| legado_core::LegadoError::Database(format!("准备查询失败: {e}")))?;
        let pattern = format!("{}%", CONFIG_PREFIX);
        let rows = stmt
            .query_map(rusqlite::params![pattern], |row| {
                let key: String = row.get(0)?;
                let value: String = row.get(1)?;
                Ok((key, value))
            })
            .map_err(|e| legado_core::LegadoError::Database(format!("查询失败: {e}")))?;

        let mut map = std::collections::HashMap::new();
        for row in rows {
            match row {
                Ok(row) => {
                    // 去掉前缀
                    let short_key = row.0.strip_prefix(CONFIG_PREFIX).unwrap_or(&row.0);
                    map.insert(short_key.to_string(), row.1);
                }
                Err(e) => {
                    // 坏行照旧跳过，仅首条告警一次（对齐 image_cache 一次性告警先例）
                    if CONFIG_ROW_FAIL_WARNED
                        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                        .is_ok()
                    {
                        log::warn!("读取配置行失败（仅告警一次，后续静默跳过）: {e}");
                    }
                }
            }
        }
        Ok(map)
    })
}

/// 批9b-4 测试串行守卫：全局 UA 为进程级状态，且本组用例改写共享配置库
///
/// 所有触碰 `config:userAgent` / 全局 UA 的 legado-ffi 用例（本模块与
/// `search.rs` 的 UA 兜底用例）必须持有本守卫；析构时清除覆盖，panic
/// 也不会把残留值留给后续用例。锁序：本守卫（UA）→ `ensure_test_db`
/// （DB），与既有 DB 用例不形成反向等待。
#[cfg(test)]
pub(crate) struct UserAgentTestGuard {
    _lock: std::sync::MutexGuard<'static, ()>,
}

#[cfg(test)]
impl UserAgentTestGuard {
    pub(crate) fn new() -> Self {
        static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
        let lock = LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        legado_net::set_default_user_agent(None);
        Self { _lock: lock }
    }
}

#[cfg(test)]
impl Drop for UserAgentTestGuard {
    fn drop(&mut self) {
        legado_net::set_default_user_agent(None);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_config_crud() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 设置配置
        assert!(set_config("theme", "dark").unwrap());
        assert!(set_config("font_size", "16").unwrap());

        // 获取配置
        assert_eq!(get_config("theme").unwrap(), "dark");
        assert_eq!(get_config("font_size").unwrap(), "16");
        assert_eq!(get_config("nonexistent").unwrap(), "");

        // 获取所有配置
        let all = get_all_config().unwrap();
        assert!(all.contains_key("theme"));
        assert!(all.contains_key("font_size"));
    }

    /// 批9b-4：`setConfig("userAgent", v)` 落库后即时更新运行期默认 UA；
    /// 空白清除覆盖并回落内置默认（对齐原版 `AppConfig.kt:918-925`）
    #[test]
    fn test_set_config_user_agent_updates_runtime_default() {
        let _ua_guard = UserAgentTestGuard::new();
        let _db_guard = crate::db_state::ensure_test_db();

        assert!(set_config(USER_AGENT_CONFIG_KEY, "ConfigUA/1.0").unwrap());
        assert_eq!(legado_net::default_user_agent(), "ConfigUA/1.0");
        assert_eq!(
            get_config(USER_AGENT_CONFIG_KEY).unwrap(),
            "ConfigUA/1.0",
            "运行期更新不得影响持久化真源"
        );

        // 空/纯空白：清除覆盖并回落内置默认
        assert!(set_config(USER_AGENT_CONFIG_KEY, "   ").unwrap());
        assert_eq!(
            legado_net::default_user_agent(),
            legado_net::client::DEFAULT_USER_AGENT
        );

        // 清理共享测试库，避免污染其他用例的启动恢复断言
        set_config(USER_AGENT_CONFIG_KEY, "").unwrap();
    }

    /// 批9b-4：`restore_user_agent` 从 caches 回填（模拟 `db_open` 冷启动）
    #[test]
    fn test_restore_user_agent_reads_config() {
        let _ua_guard = UserAgentTestGuard::new();
        let _db_guard = crate::db_state::ensure_test_db();

        set_config(USER_AGENT_CONFIG_KEY, "RestoreUA/2.0").unwrap();
        // 模拟重启：运行期覆盖为空，仅配置库有值
        legado_net::set_default_user_agent(None);
        assert_eq!(
            legado_net::default_user_agent(),
            legado_net::client::DEFAULT_USER_AGENT
        );

        restore_user_agent();
        assert_eq!(legado_net::default_user_agent(), "RestoreUA/2.0");

        // 空配置恢复 → 清除覆盖（不保留旧值）
        set_config(USER_AGENT_CONFIG_KEY, "").unwrap();
        legado_net::set_default_user_agent(Some("Stale/1.0"));
        restore_user_agent();
        assert_eq!(
            legado_net::default_user_agent(),
            legado_net::client::DEFAULT_USER_AGENT
        );
    }
}
