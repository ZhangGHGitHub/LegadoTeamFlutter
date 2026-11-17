//! 书源登录头 / 用户信息缓存（对标 Android `CacheManager` loginHeader_ / userInfo_）
//!
//! # P1-3（批10 审查）：内存真源唯一化
//!
//! 本模块此前自带一套 `HashMap` 内存层：`get_cached` 内存命中即返回、不回查
//! DB，而备份恢复链路的 `variable_store::clear_source_variables()` **清不到**
//! 这一层 → 恢复后登录头继续用旧值（静默使用过期凭据），直到进程重启。
//!
//! 现改为：**内存真源唯一 = [`legado_js::host_api::variable_store`]**（与
//! `source.putLoginHeader` / `source.getLoginHeader` 的 JS 读写同一张表），
//! 本模块只负责 DB 直写与 DB 兜底读：
//!
//! - 读：变量表内存 → 本模块 DB 读 → 回填变量表内存（对齐上游
//!   `CacheManager.get` 的「内存 → DB → 回填内存」三级读）；
//! - 写：回填变量表内存 + 写 DB（DB 写入不经 [`variable_store`] 下沉，
//!   保持「本模块是 DB 直写方」的既有单写口径）；
//! - 删：清变量表内存（不删 DB）+ 删 DB 行（`variable_store::remove_variable`
//!   会连带删 DB 行，故此处用 `remove_memory_only` 避免重复 DELETE）。
//!
//! 由此 `clear_source_variables()` / `clear_variables()` 天然覆盖登录缓存内存，
//! 且清后下一次读会自动从 DB 重载——备份恢复「立即生效」不再依赖重启。

use legado_core::LegadoResult;
use legado_db::CacheRepository;
use legado_js::host_api::variable_store;

fn login_header_key(source_url: &str) -> String {
    format!("loginHeader_{source_url}")
}

fn user_info_key(source_url: &str) -> String {
    format!("userInfo_{source_url}")
}

fn load_from_db(key: &str) -> Option<String> {
    crate::db_state::with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.get(key)
    })
    .ok()
    .flatten()
}

fn persist_db(key: &str, value: &str) -> LegadoResult<()> {
    if let Err(e) = crate::db_state::with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.put(key, value, 0)
    }) {
        eprintln!("[source_login_cache] 持久化降级（仅内存）: {e}");
    }
    Ok(())
}

fn delete_db(key: &str) -> LegadoResult<()> {
    if let Err(e) = crate::db_state::with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.delete(key)
    }) {
        eprintln!("[source_login_cache] 删除降级（仅内存）: {e}");
    }
    Ok(())
}

/// 读：变量表内存 → DB → 回填变量表内存
fn get_cached(key: &str) -> Option<String> {
    if let Ok(Some(v)) = variable_store::get_variable(key) {
        return Some(v);
    }
    let loaded = load_from_db(key)?;
    // 回填单一内存真源（不写 DB：值刚从 DB 读出）
    if let Err(e) = variable_store::prime_memory(key, &loaded) {
        eprintln!("[source_login_cache] 内存回填失败（仅影响本次读取缓存）: {e}");
    }
    Some(loaded)
}

/// 写：变量表内存 + DB（单写方，不经变量下沉避免重复写）
fn put_cached(key: &str, value: &str) -> LegadoResult<()> {
    if let Err(e) = variable_store::prime_memory(key, value) {
        eprintln!("[source_login_cache] 内存写入失败（继续落库）: {e}");
    }
    persist_db(key, value)
}

/// 删：变量表内存（仅内存，DB 由本函数删除）+ DB 行
fn delete_cached(key: &str) -> LegadoResult<()> {
    if let Err(e) = variable_store::remove_memory_only(key) {
        eprintln!("[source_login_cache] 内存删除失败（继续删库）: {e}");
    }
    delete_db(key)
}

pub fn get_login_header(source_url: &str) -> Option<String> {
    get_cached(&login_header_key(source_url))
}

pub fn put_login_header(source_url: &str, header: &str) -> LegadoResult<()> {
    put_cached(&login_header_key(source_url), header)
}

pub fn remove_login_header(source_url: &str) -> LegadoResult<()> {
    delete_cached(&login_header_key(source_url))
}

pub fn get_login_info(source_url: &str) -> Option<String> {
    get_cached(&user_info_key(source_url))
}

pub fn put_login_info(source_url: &str, info: &str) -> LegadoResult<()> {
    put_cached(&user_info_key(source_url), info)
}

pub fn remove_login_info(source_url: &str) -> LegadoResult<()> {
    delete_cached(&user_info_key(source_url))
}

/// 丢弃登录缓存内存层，使后续读按需回查 DB（P1-3 方案 1）
///
/// 备份恢复写完 `caches` 行后调用：内存被清 → 下一次
/// `get_login_header` / `get_login_info`（以及 JS `source.getLoginHeader()`）
/// **无需重启**即从 DB 读到新值。
///
/// 因内存真源已统一到 [`variable_store`]（见模块文档），本函数的实现就是
/// 清该表五族键；与恢复链路已有的 `clear_source_variables()` 同义，保留独立
/// 入口是为了让恢复流程显式表达「登录缓存需重载」这一语义，并在未来登录缓存
/// 若引入独立缓存面时仍可在此收口。
pub fn reload_from_db() -> LegadoResult<()> {
    variable_store::clear_source_variables()
        .map_err(|e| legado_core::LegadoError::Internal(format!("清理登录缓存内存失败: {e}")))
}

/// 从 JS `variable_store` 同步登录缓存（对齐原版 `evalJS` 中
/// `putLoginHeader`/`putLoginInfo` 写 CacheManager 的语义）
///
/// 书源 JS 经 `java.putLoginHeader(x)`/`java.putLoginInfo(x)` 写入
/// `loginHeader_<url>`/`userInfo_<url>` 变量；本函数将其落库到
/// `source_login_cache`（内存 + DB），使请求路径可合并登录头。
/// 非 quickjs 构建下 variable_store 仍可用（模块无 feature 门控），
/// 只是 JS 侧不会写这些键。
///
/// 复用方：explore 分类 JS 执行后（explore_api）、登录 V2 动作执行后
/// （source_login_v2_api），保证 JS 侧登录结果不丢失。— DeepSeek Harness + Bridge
pub fn sync_login_cache_from_js(source_url: &str) {
    let header_key = format!("loginHeader_{source_url}");
    if let Ok(Some(v)) = variable_store::get_variable(&header_key) {
        let _ = put_login_header(source_url, &v);
    }
    let info_key = format!("userInfo_{source_url}");
    if let Ok(Some(v)) = variable_store::get_variable(&info_key) {
        let _ = put_login_info(source_url, &v);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_login_header_roundtrip() {
        // 登录缓存内存真源已统一到 variable_store（进程级全局表），
        // 与其他变量表测试串行防串表
        let _lock = crate::test_support::lock_global_store();
        let url = "https://login-cache.test";
        put_login_header(url, r#"{"Authorization":"Bearer t"}"#).unwrap();
        let got = get_login_header(url).unwrap();
        assert!(got.contains("Bearer"));
        remove_login_header(url).unwrap();
        assert!(get_login_header(url).is_none());
    }

    /// P1-3 第二层：内存层被 `clear_source_variables` 清掉后，读路径必须
    /// 回查 DB（而不是继续命中旧内存值），且新值立即生效。
    #[test]
    fn test_login_header_reloads_from_db_after_memory_clear() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let url = "https://p13-login-reload.example.com";

        // 旧值：DB + 内存（模拟上次会话遗留的过期凭据）
        put_login_header(url, r#"{"X-Token":"old"}"#).expect("写旧登录头");
        assert_eq!(
            get_login_header(url).as_deref(),
            Some(r#"{"X-Token":"old"}"#)
        );

        // 备份恢复：直接写 DB 新值（绕过内存），随后清内存（恢复链路动作）
        delete_db(&login_header_key(url)).expect("清旧行");
        persist_db(&login_header_key(url), r#"{"X-Token":"new"}"#).expect("写新行");
        reload_from_db().expect("清内存");

        // 不重启：下一次读必须命中 DB 新值
        assert_eq!(
            get_login_header(url).as_deref(),
            Some(r#"{"X-Token":"new"}"#),
            "恢复后立即读必须拿到新登录头（不是旧内存值）"
        );
        // 且同一真源对 JS 读路径可见（source.getLoginHeader 走 variable_store）
        assert_eq!(
            variable_store::get_flow_variable(&format!("loginHeader_{url}")).as_deref(),
            Some(r#"{"X-Token":"new"}"#),
            "登录缓存内存真源应与 variable_store 同源"
        );

        remove_login_header(url).expect("清理");
        assert!(get_login_header(url).is_none());
        // 删后 DB 行也不在（重启不复活）
        assert_eq!(load_from_db(&login_header_key(url)), None);
    }

    /// P2-2：内存无该键时 `remove_login_header` 仍必须删 DB 行
    #[test]
    fn test_remove_login_header_deletes_db_row_without_memory_hit() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let url = "https://p22-login-remove.example.com";
        let key = login_header_key(url);

        persist_db(&key, r#"{"X-Token":"stale"}"#).expect("直接写 DB 行");
        // 内存无该键（清内存后恢复链路/clear_variables 的形态）
        let _ = variable_store::remove_memory_only(&key);
        assert_eq!(variable_store::get_variable(&key).unwrap(), None);

        remove_login_header(url).expect("删登录头");
        assert_eq!(load_from_db(&key), None, "内存 miss 时也必须删 DB 行");
        // 回填不会复活
        variable_store::backfill_from_sink();
        assert_eq!(get_login_header(url), None, "重启回填不得复活已删登录头");
    }
}
