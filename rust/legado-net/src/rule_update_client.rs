//! 规则订阅更新客户端
//!
//! 对应 Kotlin `RuleUpdate.kt`，负责从远程 URL 拉取订阅内容，
//! 对比版本并合并变更（书源 / 替换规则 / RSS 源）。

use serde::{Deserialize, Serialize};

/// 订阅源
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleSubscription {
    /// 订阅 URL
    pub url: String,
    /// 订阅名称
    pub name: String,
    /// 订阅类型: "bookSource" / "replaceRule" / "rssSource"
    pub sub_type: String,
}

/// 更新结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UpdateResult {
    /// 订阅 URL
    pub subscription_url: String,
    /// 新版本号（如果有变化）
    pub new_version: Option<String>,
    /// 新增条目数
    pub items_added: usize,
    /// 更新条目数
    pub items_updated: usize,
    /// 移除条目数
    pub items_removed: usize,
    /// 错误信息
    pub error: Option<String>,
}

/// 合并结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MergeResult {
    /// 合并后的 JSON 内容
    pub merged_json: String,
    /// 新增条目数
    pub added: usize,
    /// 更新条目数
    pub updated: usize,
    /// 移除条目数
    pub removed: usize,
    /// 是否有变更
    pub has_changes: bool,
}

/// 从远程 URL 拉取订阅内容
///
/// 执行 HTTP GET 获取 JSON 文本。支持 `#requestWithoutUA` 后缀
/// （去除 User-Agent 头，与 Kotlin 端行为一致）。
pub async fn fetch_subscription(sub: &RuleSubscription) -> Result<String, String> {
    let (url, without_ua) = if sub.url.ends_with("#requestWithoutUA") {
        (
            sub.url.trim_end_matches("#requestWithoutUA").to_string(),
            true,
        )
    } else {
        (sub.url.clone(), false)
    };

    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .danger_accept_invalid_certs(true)
        .build()
        .map_err(|e| format!("创建 HTTP 客户端失败: {e}"))?;

    let mut request = client.get(&url);
    if without_ua {
        request = request.header("User-Agent", "null");
    }

    let response = request
        .send()
        .await
        .map_err(|e| format!("请求订阅失败 [{}]: {e}", sub.url))?;

    if !response.status().is_success() {
        return Err(format!(
            "订阅请求返回错误状态码: {} [{}]",
            response.status(),
            sub.url
        ));
    }

    let text = response
        .text()
        .await
        .map_err(|e| format!("读取订阅响应失败: {e}"))?;

    Ok(text)
}

/// 解析并合并订阅内容
///
/// 对比本地与远程 JSON 数组，根据主键字段判断新增/更新/移除：
/// - bookSource: 以 `bookSourceUrl` 为主键
/// - replaceRule: 以 `name` 为主键
/// - rssSource: 以 `sourceUrl` 为主键
pub fn merge_subscription(
    local_json: &str,
    remote_json: &str,
    sub_type: &str,
) -> Result<MergeResult, String> {
    let local_arr: Vec<serde_json::Value> =
        serde_json::from_str(local_json).map_err(|e| format!("解析本地 JSON 失败: {e}"))?;
    let remote_arr: Vec<serde_json::Value> =
        serde_json::from_str(remote_json).map_err(|e| format!("解析远程 JSON 失败: {e}"))?;

    let key_field = match sub_type {
        "bookSource" => "bookSourceUrl",
        "replaceRule" => "name",
        "rssSource" => "sourceUrl",
        _ => return Err(format!("不支持的订阅类型: {sub_type}")),
    };

    // 构建本地索引: key -> value
    let mut local_map = std::collections::HashMap::new();
    for item in &local_arr {
        if let Some(key) = item.get(key_field).and_then(|v| v.as_str()) {
            local_map.insert(key.to_string(), item.clone());
        }
    }

    // 构建远程索引
    let mut remote_map = std::collections::HashMap::new();
    for item in &remote_arr {
        if let Some(key) = item.get(key_field).and_then(|v| v.as_str()) {
            remote_map.insert(key.to_string(), item.clone());
        }
    }

    let mut added = 0usize;
    let mut updated = 0usize;
    let mut removed = 0usize;
    let mut merged: Vec<serde_json::Value> = Vec::new();

    // 遍历远程：判断新增或更新
    for (key, remote_item) in &remote_map {
        match local_map.get(key) {
            None => {
                // 本地不存在 → 新增
                added += 1;
                merged.push(remote_item.clone());
            }
            Some(local_item) => {
                if local_item != remote_item {
                    // 内容不同 → 更新
                    updated += 1;
                    merged.push(remote_item.clone());
                } else {
                    // 无变化 → 保留
                    merged.push(local_item.clone());
                }
            }
        }
    }

    // 本地有但远程没有 → 移除
    for key in local_map.keys() {
        if !remote_map.contains_key(key) {
            removed += 1;
        }
    }

    let has_changes = added > 0 || updated > 0 || removed > 0;
    let merged_json =
        serde_json::to_string_pretty(&merged).map_err(|e| format!("序列化合并结果失败: {e}"))?;

    Ok(MergeResult {
        merged_json,
        added,
        updated,
        removed,
        has_changes,
    })
}

/// 检查订阅是否需要更新（基于更新间隔）
///
/// `last_update` 为上次更新时间戳（毫秒），`interval_hours` 为更新间隔（小时）。
pub fn should_update(last_update: i64, interval_hours: i32, now_millis: i64) -> bool {
    if interval_hours <= 0 {
        return true;
    }
    let interval_millis = interval_hours as i64 * 3600 * 1000;
    last_update + interval_millis <= now_millis
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merge_book_source_add_new() {
        let local = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]"#;
        let remote = r#"[
            {"bookSourceUrl":"https://a.com","bookSourceName":"A"},
            {"bookSourceUrl":"https://b.com","bookSourceName":"B"}
        ]"#;

        let result = merge_subscription(local, remote, "bookSource").unwrap();
        assert_eq!(result.added, 1);
        assert_eq!(result.updated, 0);
        assert_eq!(result.removed, 0);
        assert!(result.has_changes);
    }

    #[test]
    fn test_merge_book_source_update() {
        let local = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"Old"}]"#;
        let remote = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"New"}]"#;

        let result = merge_subscription(local, remote, "bookSource").unwrap();
        assert_eq!(result.added, 0);
        assert_eq!(result.updated, 1);
        assert_eq!(result.removed, 0);
        assert!(result.has_changes);
        assert!(result.merged_json.contains("New"));
    }

    #[test]
    fn test_merge_book_source_remove() {
        let local = r#"[
            {"bookSourceUrl":"https://a.com","bookSourceName":"A"},
            {"bookSourceUrl":"https://b.com","bookSourceName":"B"}
        ]"#;
        let remote = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]"#;

        let result = merge_subscription(local, remote, "bookSource").unwrap();
        assert_eq!(result.added, 0);
        assert_eq!(result.updated, 0);
        assert_eq!(result.removed, 1);
        assert!(result.has_changes);
    }

    #[test]
    fn test_merge_no_changes() {
        let json = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"A"}]"#;

        let result = merge_subscription(json, json, "bookSource").unwrap();
        assert_eq!(result.added, 0);
        assert_eq!(result.updated, 0);
        assert_eq!(result.removed, 0);
        assert!(!result.has_changes);
    }

    #[test]
    fn test_merge_replace_rule() {
        let local = r#"[{"name":"rule1","pattern":"old"}]"#;
        let remote = r#"[{"name":"rule1","pattern":"new"},{"name":"rule2","pattern":"x"}]"#;

        let result = merge_subscription(local, remote, "replaceRule").unwrap();
        assert_eq!(result.added, 1);
        assert_eq!(result.updated, 1);
        assert_eq!(result.removed, 0);
    }

    #[test]
    fn test_merge_rss_source() {
        let local = r#"[]"#;
        let remote = r#"[{"sourceUrl":"https://rss.com","sourceName":"RSS"}]"#;

        let result = merge_subscription(local, remote, "rssSource").unwrap();
        assert_eq!(result.added, 1);
        assert!(result.has_changes);
    }

    #[test]
    fn test_merge_invalid_type() {
        let result = merge_subscription("[]", "[]", "unknownType");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("不支持的订阅类型"));
    }

    #[test]
    fn test_merge_invalid_json() {
        let result = merge_subscription("not json", "[]", "bookSource");
        assert!(result.is_err());
    }

    #[test]
    fn test_should_update() {
        let now = 1700000000000i64;
        // 间隔 12 小时
        let interval = 12;

        // 上次更新在 13 小时前 → 需要更新
        assert!(should_update(now - 13 * 3600 * 1000, interval, now));

        // 上次更新在 1 小时前 → 不需要
        assert!(!should_update(now - 3600 * 1000, interval, now));

        // interval <= 0 → 总是需要更新
        assert!(should_update(now, 0, now));
        assert!(should_update(now, -1, now));
    }

    #[test]
    fn test_update_result_serialization() {
        let result = UpdateResult {
            subscription_url: "https://example.com".to_string(),
            new_version: Some("1.2.0".to_string()),
            items_added: 3,
            items_updated: 1,
            items_removed: 0,
            error: None,
        };

        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("items_added"));
        assert!(json.contains("1.2.0"));
    }
}
