//! 配置管理 API
//!
//! 基于 caches 表实现应用配置的读写操作。

use std::sync::atomic::{AtomicBool, Ordering};

use legado_core::{LegadoError, LegadoResult};
use legado_db::CacheRepository;

use crate::db_state::with_database;

/// 配置键前缀
///
/// `pub(crate)`：备份模块（`backup_api`）读写 `directLinkUploadRule` 配置时复用
/// 同一前缀，避免键格式在两处漂移。
///
/// [批20-B] 别名到 `legado_db::app_config::CONFIG_PREFIX`：Web 进程直接读
/// 同一 caches 表，前缀常量只允许一处定义。
pub(crate) const CONFIG_PREFIX: &str = legado_db::app_config::CONFIG_PREFIX;

/// 隐私凭据键前缀（契约 §2.53）
///
/// 密码 salt/verifier 与预留的生物识别凭据只允许 `privacy_api` 直接经
/// `CacheRepository` 读写：通用 config 接口既不返回（getAllConfigs），
/// 也拒绝读写，防止绕过旧密码校验重置密码或读取校验值。
pub(crate) const PRIVATE_CONFIG_PREFIXES: &[&str] = &["private_password_", "private_biometric_"];

/// 短路名是否为隐私凭据键
pub(crate) fn is_private_config_key(short_key: &str) -> bool {
    PRIVATE_CONFIG_PREFIXES
        .iter()
        .any(|prefix| short_key.starts_with(prefix))
}

/// 通用 config 接口的私有键闸门（中文错误，明确拒绝而非静默）
fn ensure_public_config_key(short_key: &str) -> LegadoResult<()> {
    if is_private_config_key(short_key) {
        return Err(LegadoError::Internal(format!(
            "配置键「{short_key}」属于隐私凭据，禁止通过通用配置接口访问"
        )));
    }
    Ok(())
}

/// 全局 User-Agent 配置短键（批9b-4）
///
/// 与 Dart 偏好键 `userAgent`（`pref_keys.dart`）及原版 `PreferKey.userAgent`
/// 同名；`set_config` 落库成功后同步更新 `legado-net` 进程级默认 UA 覆盖。
pub const USER_AGENT_CONFIG_KEY: &str = "userAgent";

/// 线程数配置短键（批9b-2，契约 §2.10 / §2.4 / §2.43.3）
///
/// 与 Dart 偏好键 `threadCount`（`pref_keys.dart`）及原版 `PreferKey.threadCount`
/// 同名。搜索/批量下载在**每次入口**读取该键，故 `set_config` 保存后下一次
/// 任务即生效，无需额外的运行期缓存同步。
pub const THREAD_COUNT_CONFIG_KEY: &str = "threadCount";

/// 线程数缺省值（批9b-2 审查回修）
///
/// 对齐参考版 `DownloadCacheSettings.threadCount = 16`（多平台更稳）；
/// 原版 `AppConfig.threadCount` 默认 32 仅作历史语义参考。
pub(crate) const DEFAULT_THREAD_COUNT: usize = 16;

/// 解析线程数配置文本（批9b-2，审查回修补齐溢出/存量口径）
///
/// 口径（契约 §2.10 批9b-2）：
/// - 缺失 / 空串 / 纯空白 / 非整数 → 回落 `default`；
/// - 数值越界 → 夹逼 `1..=max`（`<1` → 1，含 0/负数）；
/// - **超出 i64 的纯数字**：正数按上限 `max` 夹逼、负数按下限 1
///   （避免超大值被误判为「非数字」而回落缺省）；
/// - 带前导 `+` 的纯数字按正数处理。
pub(crate) fn parse_thread_count(raw: &str, default: usize, max: usize) -> usize {
    let max = max.max(1);
    let default = default.clamp(1, max);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return default;
    }
    if let Ok(v) = trimmed.parse::<i64>() {
        return v.clamp(1, max as i64) as usize;
    }
    let (negative, digits) = if let Some(digits) = trimmed.strip_prefix('-') {
        (true, digits)
    } else if let Some(digits) = trimmed.strip_prefix('+') {
        (false, digits)
    } else {
        (false, trimmed)
    };
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        return if negative { 1 } else { max };
    }
    default
}

/// 读取运行期线程数（caches `config:threadCount`，批9b-2）
///
/// 每次调用读库（一次索引主键查询），保证用户保存后下一次搜索/下载入口
/// 即取到新值；DB 未初始化/读失败同样回落 `default`（不阻断业务）。
pub(crate) fn resolve_thread_count(default: usize, max: usize) -> usize {
    match get_config(THREAD_COUNT_CONFIG_KEY) {
        Ok(raw) => parse_thread_count(&raw, default, max),
        Err(_) => default.clamp(1, max.max(1)),
    }
}

/// 读配置行失败的一次性告警标记（高频路径，避免逐行刷屏）
static CONFIG_ROW_FAIL_WARNED: AtomicBool = AtomicBool::new(false);

/// 获取指定配置项的值（不存在返回空字符串）
pub fn get_config(key: &str) -> LegadoResult<String> {
    ensure_public_config_key(key)?;
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
    ensure_public_config_key(key)?;
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let full_key = format!("{}{}", CONFIG_PREFIX, key);
        // ttl=0 永不过期
        repo.put(&full_key, value, 0)?;
        // 审查 P3-4：运行期更新放在 DB 闭包内——落库成功后才更新，
        // 且与 DB 写入同序（并发 setConfig 不会出现「库值 A、运行期值 B」
        // 的乱序分叉）
        if key == USER_AGENT_CONFIG_KEY {
            legado_net::set_default_user_agent(Some(value));
        }
        Ok(true)
    })
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
                    // [批9a 审查 P2-6] 隐私凭据不得出现在通用配置列表
                    if is_private_config_key(short_key) {
                        continue;
                    }
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

/// 批9b-2：`config:threadCount` 测试复位守卫
///
/// 在测试中声明于 DB 守卫**之后**（Drop 顺序反向：本守卫先于 DB 守卫释放），
/// panic 展开时也保证把共享测试库的 threadCount 复回缺省 16，避免污染后续用例。
#[cfg(test)]
pub(crate) struct ThreadCountResetGuard;

#[cfg(test)]
impl ThreadCountResetGuard {
    pub(crate) fn new() -> Self {
        Self
    }
}

#[cfg(test)]
impl Drop for ThreadCountResetGuard {
    fn drop(&mut self) {
        let _ = set_config(THREAD_COUNT_CONFIG_KEY, &DEFAULT_THREAD_COUNT.to_string());
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

    /// [批9a 审查 P2-6] 隐私凭据键：getAllConfigs 过滤、getConfig/setConfig
    /// 明确拒绝；直接经 CacheRepository 写入的凭据仍可被 privacy_api 使用。
    #[test]
    fn test_private_config_keys_are_guarded() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 直接落库（模拟 privacy_api 写入路径），并放一个普通公开配置
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            repo.put("config:private_password_salt", "salt-b64", 0)?;
            repo.put("config:private_password_verifier", "verifier-b64", 0)?;
            repo.put("config:private_biometric_envelope", "reserved-b64", 0)?;
            repo.put("config:private_biometric_token_hash", "hash-b64", 0)?;
            repo.put("config:private_biometric_iv", "iv-b64", 0)?;
            repo.put("config:theme", "dark", 0)?;
            Ok(())
        })
        .unwrap();

        // 列表过滤：五个私有键均不出现
        let all = get_all_config().unwrap();
        assert!(all.contains_key("theme"));
        assert!(!all.contains_key("private_password_salt"));
        assert!(!all.contains_key("private_password_verifier"));
        assert!(!all.contains_key("private_biometric_envelope"));
        assert!(!all.contains_key("private_biometric_token_hash"));
        assert!(!all.contains_key("private_biometric_iv"));

        // 读取拒绝
        for key in [
            "private_password_salt",
            "private_password_verifier",
            "private_biometric_envelope",
            "private_biometric_token_hash",
            "private_biometric_iv",
        ] {
            let err = get_config(key).unwrap_err();
            assert!(
                err.to_string().contains("属于隐私凭据"),
                "get_config({key}) 应拒绝: {err}"
            );
        }

        // 写入拒绝（含 Dart deleteConfig 的空串删除路径），原值不被覆盖
        let err = set_config("private_password_salt", "attacker").unwrap_err();
        assert!(err.to_string().contains("属于隐私凭据"), "{err}");
        let err = set_config("private_password_verifier", "").unwrap_err();
        assert!(err.to_string().contains("属于隐私凭据"), "{err}");
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            assert_eq!(
                repo.get("config:private_password_salt")?.as_deref(),
                Some("salt-b64"),
                "被拒绝的写入不得修改凭据"
            );
            Ok(())
        })
        .unwrap();

        // privacy_api 自己的读写路径不受影响：清掉模拟凭据后设置→校验→清除
        crate::api::privacy_api::privacy_clear_password().unwrap();
        crate::api::privacy_api::privacy_set_password("guard-pass", None).unwrap();
        assert!(crate::api::privacy_api::privacy_verify_password("guard-pass").unwrap());
        // 清除后恢复上面直接写入的测试值，避免污染其他用例
        crate::api::privacy_api::privacy_clear_password().unwrap();
        with_database(|db| {
            let repo = CacheRepository::new(db.connection());
            repo.delete("config:private_password_salt")?;
            repo.delete("config:private_password_verifier")?;
            repo.delete("config:private_biometric_envelope")?;
            repo.delete("config:private_biometric_token_hash")?;
            repo.delete("config:private_biometric_iv")?;
            repo.delete("config:theme")?;
            Ok(())
        })
        .unwrap();
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

    // ─── 批9b-2：线程数配置解析/夹逼 ─────────────────────────────────────

    /// 配置文本解析：缺省/空串/非整数回落缺省；数值夹逼 1..=max；
    /// 超出 i64 的纯数字正数按上限、负数按下限（批9b-2 审查回修）
    #[test]
    fn test_parse_thread_count_defaults_and_clamp() {
        // 搜索口径（缺省 16、上限 32）
        assert_eq!(parse_thread_count("", 16, 32), 16, "缺失回落缺省");
        assert_eq!(parse_thread_count("   ", 16, 32), 16, "纯空白回落缺省");
        assert_eq!(parse_thread_count("abc", 16, 32), 16, "非整数回落缺省");
        assert_eq!(parse_thread_count("1.5", 16, 32), 16, "小数非整数回落缺省");
        assert_eq!(parse_thread_count("0", 16, 32), 1, "0 夹逼到下限 1");
        assert_eq!(parse_thread_count("-9", 16, 32), 1, "负数夹逼到下限 1");
        assert_eq!(parse_thread_count("1", 16, 32), 1);
        assert_eq!(parse_thread_count("24", 16, 32), 24);
        assert_eq!(parse_thread_count("32", 16, 32), 32);
        assert_eq!(parse_thread_count("999", 16, 32), 32, "超上限夹逼到 32");
        // 超出 i64 的纯数字：正数按上限、负数按下限（不得回落缺省）
        assert_eq!(
            parse_thread_count("999999999999999999999999999", 16, 32),
            32,
            "超 i64 正数按上限"
        );
        assert_eq!(
            parse_thread_count("+999999999999999999999999999", 16, 32),
            32,
            "超 i64 带 + 正数按上限"
        );
        assert_eq!(
            parse_thread_count("-999999999999999999999999999", 16, 32),
            1,
            "超 i64 负数按下限"
        );

        // 下载口径（同一解析器，上限 8）：缺省 16 → 8
        assert_eq!(parse_thread_count("", 16, 8), 8);
        assert_eq!(parse_thread_count("5", 16, 8), 5);
        assert_eq!(parse_thread_count("100", 16, 8), 8);
        // max=0 防御：至少 1
        assert_eq!(parse_thread_count("5", 16, 0), 1);
    }

    /// `resolve_thread_count` 读取 caches `config:threadCount`：
    /// 保存后即时生效；非法/缺失回落缺省
    #[test]
    fn test_resolve_thread_count_reads_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _thread_guard = ThreadCountResetGuard::new();

        set_config(THREAD_COUNT_CONFIG_KEY, "12").unwrap();
        assert_eq!(resolve_thread_count(DEFAULT_THREAD_COUNT, 32), 12);

        set_config(THREAD_COUNT_CONFIG_KEY, "999").unwrap();
        assert_eq!(resolve_thread_count(DEFAULT_THREAD_COUNT, 32), 32);

        set_config(THREAD_COUNT_CONFIG_KEY, "not-a-number").unwrap();
        assert_eq!(resolve_thread_count(DEFAULT_THREAD_COUNT, 32), 16);

        set_config(THREAD_COUNT_CONFIG_KEY, "").unwrap();
        assert_eq!(resolve_thread_count(DEFAULT_THREAD_COUNT, 32), 16);

        // 下载口径：同一配置值 99 → 夹逼到 8
        set_config(THREAD_COUNT_CONFIG_KEY, "99").unwrap();
        assert_eq!(resolve_thread_count(DEFAULT_THREAD_COUNT, 8), 8);
    }
}
