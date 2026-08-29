//! 发现页 infoMap 存储（对标 Android `InfoMap` + `exploreInfoMapList`）
//!
//! 发现分类的 toggle/select/text 控件会读写 infoMap；抓取书籍时
//! `AnalyzeUrl` 须携带同一 infoMap 才能与原版请求 URL 一致。

use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

use legado_core::{LegadoError, LegadoResult};
use legado_db::CacheRepository;

/// 内存缓存：source_url → (key → value)
fn memory_store() -> &'static RwLock<HashMap<String, HashMap<String, String>>> {
    static STORE: OnceLock<RwLock<HashMap<String, HashMap<String, String>>>> = OnceLock::new();
    STORE.get_or_init(|| RwLock::new(HashMap::new()))
}

fn cache_key(source_url: &str) -> String {
    format!("infoMap_{source_url}")
}

/// 从 DB 加载 infoMap 到内存（若内存尚无条目）
fn load_from_db(source_url: &str) -> HashMap<String, String> {
    let key = cache_key(source_url);
    let json = crate::db_state::with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.get(&key)
    })
    .ok()
    .flatten()
    .unwrap_or_default();

    if json.is_empty() {
        return HashMap::new();
    }
    serde_json::from_str(&json).unwrap_or_default()
}

/// 持久化 infoMap 到 DB（对标 Android InfoMap.saveNow；DB 未初始化时仅内存）
pub fn persist(source_url: &str, map: &HashMap<String, String>) -> LegadoResult<()> {
    let key = cache_key(source_url);
    let json = serde_json::to_string(map).map_err(LegadoError::Serialization)?;
    if let Err(e) = crate::db_state::with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.put(&key, &json, 0)
    }) {
        eprintln!("[explore] infoMap 持久化降级（仅内存）: {e}");
    }
    Ok(())
}

/// 获取书源 infoMap 快照（内存优先，回退 DB）
pub fn snapshot(source_url: &str) -> LegadoResult<HashMap<String, String>> {
    {
        let store = memory_store().read().unwrap_or_else(|p| p.into_inner());
        if let Some(map) = store.get(source_url) {
            return Ok(map.clone());
        }
    }

    let loaded = load_from_db(source_url);
    let mut store = memory_store().write().unwrap_or_else(|p| p.into_inner());
    store.insert(source_url.to_string(), loaded.clone());
    Ok(loaded)
}

/// 写入单个键（对标 Android infoMap[title] = value）
pub fn put(source_url: &str, key: &str, value: &str) -> LegadoResult<()> {
    let mut map = snapshot(source_url)?;
    map.insert(key.to_string(), value.to_string());
    {
        let mut store = memory_store().write().unwrap_or_else(|p| p.into_inner());
        store.insert(source_url.to_string(), map.clone());
    }
    persist(source_url, &map)
}

/// 若键不存在则写入默认值（toggle/select 初始化）
pub fn ensure_default(source_url: &str, key: &str, default: &str) -> LegadoResult<()> {
    let mut map = snapshot(source_url)?;
    if !map.contains_key(key) {
        map.insert(key.to_string(), default.to_string());
        let mut store = memory_store().write().unwrap_or_else(|p| p.into_inner());
        store.insert(source_url.to_string(), map.clone());
        persist(source_url, &map)?;
    }
    Ok(())
}

/// 将 infoMap 展平为 AnalyzeUrl 变量表（含 `infoMap.key` 点号键）
pub fn variables_for_url(
    source_url: &str,
    page: i32,
    base_url: &str,
) -> LegadoResult<HashMap<String, String>> {
    let info_map = snapshot(source_url)?;
    let mut variables = HashMap::new();
    variables.insert("page".to_string(), page.max(1).to_string());
    variables.insert("baseUrl".to_string(), base_url.to_string());
    for (k, v) in &info_map {
        variables.insert(k.clone(), v.clone());
        variables.insert(format!("infoMap.{k}"), v.clone());
    }
    // 供 JS 前缀注入完整 infoMap 对象
    let json = serde_json::to_string(&info_map).unwrap_or_else(|_| "{}".to_string());
    variables.insert("__infoMapJson".to_string(), json);
    Ok(variables)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_variables_for_url_includes_info_map_entries() {
        let source = "https://explore-info-map.test";
        put(source, "榜类", "推荐").unwrap();
        let vars = variables_for_url(source, 1, source).unwrap();
        assert_eq!(vars.get("榜类"), Some(&"推荐".to_string()));
        assert_eq!(vars.get("infoMap.榜类"), Some(&"推荐".to_string()));
        assert_eq!(vars.get("page"), Some(&"1".to_string()));
    }
}
