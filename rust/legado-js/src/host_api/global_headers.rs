//! 全局请求头存储（按书源 tag 隔离）
//!
//! 对齐 Android AnalyzeUrl(source).getHeaderMap()：java.ajax 请求应携带
//! 书源 header 规则（@js 动态生成，如书山聚合的固定 X-Novel-Token）执行结果。
//! setup 阶段执行书源 header 规则后经 java.putGlobalHeaders(json) 写入，
//! java.ajax 发起请求时按当前书源 tag 合并。

use std::collections::HashMap;
use std::sync::{LazyLock, Mutex};

/// 全局请求头存储（tag -> header map）
static GLOBAL_HEADERS: LazyLock<Mutex<HashMap<String, HashMap<String, String>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 按书源 tag 写入请求头（整体替换该 tag 的头）
pub fn put_headers(tag: &str, headers: HashMap<String, String>) {
    let mut store = GLOBAL_HEADERS.lock().unwrap();
    if headers.is_empty() {
        store.remove(tag);
    } else {
        store.insert(tag.to_string(), headers);
    }
}

/// 按书源 tag 读取请求头
pub fn headers_for(tag: &str) -> HashMap<String, String> {
    let store = GLOBAL_HEADERS.lock().unwrap();
    store.get(tag).cloned().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_put_and_get_headers() {
        let tag = "https://shushan.test";
        let mut h = HashMap::new();
        h.insert("X-Novel-Token".to_string(), "SHUSAN_READ_2025".to_string());
        put_headers(tag, h);
        let got = headers_for(tag);
        assert_eq!(got.get("X-Novel-Token").map(|s| s.as_str()), Some("SHUSAN_READ_2025"));
    }

    #[test]
    fn test_isolated_by_tag() {
        let mut h1 = HashMap::new();
        h1.insert("X-A".to_string(), "1".to_string());
        put_headers("tag-a", h1);
        let mut h2 = HashMap::new();
        h2.insert("X-B".to_string(), "2".to_string());
        put_headers("tag-b", h2);
        assert!(headers_for("tag-a").contains_key("X-A"));
        assert!(!headers_for("tag-a").contains_key("X-B"));
    }
}
