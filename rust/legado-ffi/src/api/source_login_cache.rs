//! 书源登录头 / 用户信息缓存（对标 Android `CacheManager` loginHeader_ / userInfo_）

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

use legado_core::LegadoResult;
use legado_db::CacheRepository;

fn memory_store() -> &'static RwLock<HashMap<String, String>> {
    static STORE: OnceLock<RwLock<HashMap<String, String>>> = OnceLock::new();
    STORE.get_or_init(|| RwLock::new(HashMap::new()))
}

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

fn get_cached(key: &str) -> Option<String> {
    {
        let store = memory_store().read().unwrap_or_else(|p| p.into_inner());
        if let Some(v) = store.get(key) {
            return Some(v.clone());
        }
    }
    let loaded = load_from_db(key);
    if let Some(v) = loaded {
        let mut store = memory_store().write().unwrap_or_else(|p| p.into_inner());
        store.insert(key.to_string(), v.clone());
        return Some(v);
    }
    None
}

fn put_cached(key: &str, value: &str) -> LegadoResult<()> {
    {
        let mut store = memory_store().write().unwrap_or_else(|p| p.into_inner());
        store.insert(key.to_string(), value.to_string());
    }
    persist_db(key, value)
}

fn delete_cached(key: &str) -> LegadoResult<()> {
    {
        let mut store = memory_store().write().unwrap_or_else(|p| p.into_inner());
        store.remove(key);
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

/// 从 JS `variable_store` 同步登录缓存（对齐原版 `evalJS` 中
/// `putLoginHeader`/`putLoginInfo` 写 CacheManager 的语义）
///
/// 书源 JS 经 `java.putLoginHeader(x)`/`java.putLoginInfo(x)` 写入
/// `loginHeader_<url>`/`userInfo_<url>` 变量；本函数将其落库到
/// `source_login_cache`（内存 + DB），使请求路径可合并登录头。
/// 非 quickjs 构建下 variable_store 不可用，静默跳过。
///
/// 复用方：explore 分类 JS 执行后（explore_api）、登录 V2 动作执行后
/// （source_login_v2_api），保证 JS 侧登录结果不丢失。— DeepSeek Harness + Bridge
pub fn sync_login_cache_from_js(_source_url: &str) {
    #[cfg(feature = "quickjs")]
    {
        use legado_js::host_api::variable_store;
        let source_url = _source_url;
        let header_key = format!("loginHeader_{source_url}");
        if let Ok(Some(v)) = variable_store::get_variable(&header_key) {
            let _ = put_login_header(source_url, &v);
        }
        let info_key = format!("userInfo_{source_url}");
        if let Ok(Some(v)) = variable_store::get_variable(&info_key) {
            let _ = put_login_info(source_url, &v);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_login_header_roundtrip() {
        let url = "https://login-cache.test";
        put_login_header(url, r#"{"Authorization":"Bearer t"}"#).unwrap();
        let got = get_login_header(url).unwrap();
        assert!(got.contains("Bearer"));
        remove_login_header(url).unwrap();
        assert!(get_login_header(url).is_none());
    }
}
