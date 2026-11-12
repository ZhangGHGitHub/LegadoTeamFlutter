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
        .dns_resolver(crate::custom_hosts::resolver())
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

/// 从订阅原文提取版本标识（FFI `ruleSubCheckUpdate` 与 Web
/// `/api/rule-update/check` 共用，单实现）
///
/// 订阅载荷有两种真实形态：
/// - **JSON 对象**（少数订阅源自带元信息）：取字符串字段 `version`；
/// - **JSON 数组**（书源/RSS 源/替换规则导出的标准形态）：没有顶层
///   `version`，此前的实现恒返回 `None`，导致 `hasUpdate` 恒为 true、
///   UI 每次检查都提示「发现新版本」。现改为：
///   1. 取全部条目 `lastUpdateTime` 的最大值（毫秒时间戳字符串，兼容数字与
///      数字字符串）——书源/RSS 源作者更新规则时会推进该字段，对齐上游
///      `RuleUpdate.kt` 按 `lastUpdateTime` 判新的口径；
///   2. 若没有任何非零时间戳（如替换规则订阅），退化为原文的稳定内容指纹
///      `content-<16 hex>`：内容不变 → 版本不变，内容变 → 版本变，保证
///      「已是最新」能正确显示。
///
/// 空数组 / 非法 JSON / 其他顶层类型返回 `None`（无可比较版本）。
pub fn extract_subscription_version(payload: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(payload).ok()?;
    match value {
        serde_json::Value::Object(map) => map
            .get("version")
            .and_then(|v| v.as_str())
            .map(str::to_string),
        serde_json::Value::Array(items) => {
            if items.is_empty() {
                return None;
            }
            let latest = items
                .iter()
                .filter_map(|item| item.get("lastUpdateTime"))
                .filter_map(json_i64)
                .max()
                .unwrap_or(0);
            if latest > 0 {
                Some(latest.to_string())
            } else {
                Some(content_fingerprint(payload))
            }
        }
        _ => None,
    }
}

/// JSON 数字或数字字符串 → i64（第三方订阅两种写法都存在）
fn json_i64(value: &serde_json::Value) -> Option<i64> {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|s| s.trim().parse::<i64>().ok()))
}

/// 稳定内容指纹：FNV-1a 64 位（跨进程/跨平台一致，无额外依赖）
///
/// 只用于「内容是否变化」的比较，不作为展示语义；外层原文先 trim，
/// 避免订阅端偶尔多一个换行被误判为新版本。
fn content_fingerprint(payload: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in payload.trim().as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("content-{hash:016x}")
}

/// 判断远程订阅相对本地版本是否有更新
///
/// 没有可比较版本（空数组 / 非法 JSON / 无 `version` 的对象）时返回 false：
/// 「无法判断」不应表现为「有新版本」，否则每次检查都会误报。
pub fn has_subscription_update(remote_json: &str, local_version: &str) -> bool {
    match extract_subscription_version(remote_json) {
        Some(remote_version) => remote_version != local_version,
        None => false,
    }
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

    // ─── 订阅版本提取（P1-3 相邻缺陷：数组订阅恒 hasUpdate）─────

    #[test]
    fn test_extract_version_from_object_payload() {
        assert_eq!(
            extract_subscription_version(r#"{"version":"1.2.3","data":[]}"#),
            Some("1.2.3".to_string())
        );
        // 对象但无 version → None
        assert_eq!(extract_subscription_version(r#"{"data":[]}"#), None);
        assert_eq!(extract_subscription_version("not json"), None);
    }

    #[test]
    fn test_extract_version_from_array_uses_latest_last_update_time() {
        // 订阅载荷是数组（书源/RSS 源导出形态），版本取最新 lastUpdateTime；
        // 兼容数字与数字字符串两种写法
        let payload = r#"[
            {"bookSourceUrl":"https://a.com","lastUpdateTime":1700000000000},
            {"bookSourceUrl":"https://b.com","lastUpdateTime":1700000500000},
            {"bookSourceUrl":"https://c.com","lastUpdateTime":"1700000300000"}
        ]"#;
        assert_eq!(
            extract_subscription_version(payload),
            Some("1700000500000".to_string())
        );
    }

    #[test]
    fn test_extract_version_array_without_timestamps_uses_stable_fingerprint() {
        // 替换规则订阅没有 lastUpdateTime：退化为内容指纹，
        // 保证「内容不变 → 版本不变」「内容变 → 版本变」
        let first = r#"[{"name":"规则A","pattern":"a"}]"#;
        let second = r#"[{"name":"规则A","pattern":"b"}]"#;
        let v1 = extract_subscription_version(first).expect("数组应给出内容指纹");
        let v1_again = extract_subscription_version(first).expect("同一原文指纹应稳定");
        let v2 = extract_subscription_version(second).expect("数组应给出内容指纹");
        assert_eq!(v1, v1_again);
        assert_ne!(v1, v2);
        assert!(v1.starts_with("content-"), "指纹格式: {v1}");
    }

    #[test]
    fn test_extract_version_empty_array_returns_none() {
        assert_eq!(extract_subscription_version("[]"), None);
        assert_eq!(extract_subscription_version("  [ ]  "), None);
    }

    #[test]
    fn test_has_subscription_update_semantics() {
        let payload = r#"[{"name":"规则A","lastUpdateTime":1700000000000}]"#;
        let version = extract_subscription_version(payload).unwrap();
        // 版本一致 → 已是最新（修复前数组恒 None → 恒 true）
        assert!(!has_subscription_update(payload, &version));
        assert!(has_subscription_update(payload, ""));
        // 时间戳推进 → 有更新
        assert!(has_subscription_update(
            r#"[{"name":"规则A","lastUpdateTime":1700000000001}]"#,
            &version
        ));
        // 空数组：无可比较版本，不提示更新
        assert!(!has_subscription_update("[]", ""));
    }
}
