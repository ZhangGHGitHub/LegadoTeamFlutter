//! 规则订阅 FFI API（Task #89）
//!
//! 包装 `legado_db::RuleSubRepository` 的 CRUD 与
//! `legado_net::rule_update_client` 的更新检查/应用逻辑，
//! 通过 JSON 序列化传参，遵循项目「复杂类型 FFI 用 JSON」决策。
//!
//! 对应 Kotlin 原版 `RuleSub` 实体 + `RuleSubActivity`
//! （列表 CRUD / 拖拽排序 / 自动更新 / 静默更新 / 更新间隔）。

use serde::Serialize;

use legado_core::{LegadoError, LegadoResult};
use legado_db::{RuleSubRecord, RuleSubRepository};
use legado_net::{fetch_subscription, merge_subscription, should_update, RuleSubscription};

use crate::db_state::with_database;

// ─── 数据库 CRUD ─────────────────────────────────────────────

/// 列出所有规则订阅（按 customOrder 排序）
pub fn list_subs_db() -> LegadoResult<Vec<RuleSubRecord>> {
    with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        repo.find_all()
    })
}

/// 保存规则订阅（id > 0 且存在则更新，否则插入），返回是否成功
pub fn save_sub_db(record: &RuleSubRecord) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        if record.id > 0 && repo.find_by_id(record.id)?.is_some() {
            repo.update(record)?;
        } else {
            repo.insert(record)?;
        }
        Ok(true)
    })
}

/// 删除规则订阅，返回是否实际删除
pub fn delete_sub_db(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        let exists = repo.find_by_id(id)?.is_some();
        if exists {
            repo.delete(id)?;
        }
        Ok(exists)
    })
}

/// 切换订阅启用状态，返回记录是否存在
pub fn set_sub_enabled_db(id: i64, enabled: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        let exists = repo.find_by_id(id)?.is_some();
        if exists {
            repo.set_enabled(id, enabled)?;
        }
        Ok(exists)
    })
}

/// 批量更新自定义排序（拖拽排序），`ids` 为新顺序 ID 列表
pub fn update_sub_order_db(ids: &[i64]) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        repo.update_order(ids)?;
        Ok(true)
    })
}

// ─── 更新检查 / 应用（委托 legado_net::rule_update_client）──

/// 检查更新结果（JSON 序列化后返回 Dart 层）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CheckUpdateResponse {
    /// 订阅 ID
    pub id: i64,
    /// 订阅 URL
    pub url: String,
    /// 订阅名称
    pub name: String,
    /// 是否到达更新间隔（should_update 判定）
    pub due_for_update: bool,
    /// 远程是否有内容更新
    pub has_update: bool,
    /// 远程版本号（若能提取）
    pub remote_version: Option<String>,
    /// 错误信息
    pub error: Option<String>,
}

/// 应用更新结果（JSON 序列化后返回 Dart 层）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApplyUpdateResponse {
    /// 订阅 ID
    pub id: i64,
    /// 订阅 URL
    pub url: String,
    /// 是否成功
    pub success: bool,
    /// 新增条目数
    pub items_added: usize,
    /// 更新条目数
    pub items_updated: usize,
    /// 移除条目数
    pub items_removed: usize,
    /// 合并后的条目总数
    pub total_items: usize,
    /// 错误信息
    pub error: Option<String>,
}

/// 当前时间戳（毫秒）
fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

/// 从订阅 JSON 内容中提取版本信息（与 server 端 extract_version 语义一致）
fn extract_version(json_str: &str) -> Option<String> {
    if let Ok(obj) = serde_json::from_str::<serde_json::Value>(json_str) {
        if let Some(v) = obj.get("version").and_then(|v| v.as_str()) {
            return Some(v.to_string());
        }
    }
    None
}

/// 检查订阅更新（委托 should_update + fetch_subscription）
///
/// 流程：
/// 1. `should_update(last_update, updateInterval, now)` 判断是否到达更新间隔
/// 2. 远程拉取订阅内容，对比版本号判断是否有内容更新
pub fn check_sub_update_db(id: i64) -> LegadoResult<CheckUpdateResponse> {
    let sub = with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        repo.find_by_id(id)
    })?
    .ok_or_else(|| LegadoError::Database(format!("未找到 id={id} 的订阅记录")))?;

    let due_for_update = should_update(sub.last_update, sub.update_interval, now_millis());

    let subscription = RuleSubscription {
        url: sub.url.clone(),
        name: sub.name.clone(),
        sub_type: sub.sub_type.clone(),
    };

    let response = match crate::runtime::block_on(fetch_subscription(&subscription)) {
        Ok(remote_json) => {
            let remote_version = extract_version(&remote_json);
            let has_update = match &remote_version {
                Some(rv) => rv != &sub.version,
                None => !remote_json.is_empty(),
            };
            CheckUpdateResponse {
                id: sub.id,
                url: sub.url.clone(),
                name: sub.name.clone(),
                due_for_update,
                has_update,
                remote_version,
                error: None,
            }
        }
        Err(e) => CheckUpdateResponse {
            id: sub.id,
            url: sub.url.clone(),
            name: sub.name.clone(),
            due_for_update,
            has_update: false,
            remote_version: None,
            error: Some(e),
        },
    };

    Ok(response)
}

/// 应用订阅更新（委托 fetch_subscription + merge_subscription）
///
/// 流程：拉取远程内容 → 合并（rule_subs 不存储条目内容，按全量导入合并）
/// → 更新订阅版本号与最后更新时间。
pub fn apply_sub_update_db(id: i64) -> LegadoResult<ApplyUpdateResponse> {
    let sub = with_database(|db| {
        let repo = RuleSubRepository::new(db.connection());
        repo.find_by_id(id)
    })?
    .ok_or_else(|| LegadoError::Database(format!("未找到 id={id} 的订阅记录")))?;

    let subscription = RuleSubscription {
        url: sub.url.clone(),
        name: sub.name.clone(),
        sub_type: sub.sub_type.clone(),
    };

    let remote_json = match crate::runtime::block_on(fetch_subscription(&subscription)) {
        Ok(content) => content,
        Err(e) => {
            return Ok(ApplyUpdateResponse {
                id: sub.id,
                url: sub.url.clone(),
                success: false,
                items_added: 0,
                items_updated: 0,
                items_removed: 0,
                total_items: 0,
                error: Some(format!("拉取订阅失败: {e}")),
            });
        }
    };

    // 与 server 端 apply_update 一致：本地无条目内容缓存，按全量导入合并
    match merge_subscription("[]", &remote_json, &sub.sub_type) {
        Ok(mr) => {
            let new_version = extract_version(&remote_json).unwrap_or_default();
            with_database(|db| {
                let repo = RuleSubRepository::new(db.connection());
                repo.update_version(sub.id, &new_version, now_millis())
            })?;

            let total_items = serde_json::from_str::<Vec<serde_json::Value>>(&mr.merged_json)
                .map(|v| v.len())
                .unwrap_or(0);

            Ok(ApplyUpdateResponse {
                id: sub.id,
                url: sub.url.clone(),
                success: true,
                items_added: mr.added,
                items_updated: mr.updated,
                items_removed: mr.removed,
                total_items,
                error: None,
            })
        }
        Err(e) => Ok(ApplyUpdateResponse {
            id: sub.id,
            url: sub.url.clone(),
            success: false,
            items_added: 0,
            items_updated: 0,
            items_removed: 0,
            total_items: 0,
            error: Some(e),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rule_sub_crud_db() {
        crate::db_state::ensure_test_db();

        let record = RuleSubRecord {
            url: "https://example.com/ffi_crud.json".to_string(),
            name: "FFI订阅".to_string(),
            sub_type: "bookSource".to_string(),
            created_at: 1700000000000,
            auto_update: true,
            update_interval: 12,
            ..RuleSubRecord::default()
        };

        // Save（新增）
        assert!(save_sub_db(&record).unwrap());
        let inserted = list_subs_db()
            .unwrap()
            .into_iter()
            .find(|r| r.url == "https://example.com/ffi_crud.json")
            .unwrap();
        assert!(inserted.id > 0);
        assert!(inserted.auto_update);
        assert_eq!(inserted.update_interval, 12);

        // Save（更新）
        let mut updated = inserted.clone();
        updated.name = "FFI订阅-改".to_string();
        updated.silent_update = true;
        assert!(save_sub_db(&updated).unwrap());
        let after = list_subs_db()
            .unwrap()
            .into_iter()
            .find(|r| r.id == inserted.id)
            .unwrap();
        assert_eq!(after.name, "FFI订阅-改");
        assert!(after.silent_update);

        // SetEnabled
        assert!(set_sub_enabled_db(inserted.id, false).unwrap());
        let disabled = list_subs_db()
            .unwrap()
            .into_iter()
            .find(|r| r.id == inserted.id)
            .unwrap();
        assert!(!disabled.is_enabled);
        assert!(!set_sub_enabled_db(999_999_999, true).unwrap());

        // Delete
        assert!(delete_sub_db(inserted.id).unwrap());
        assert!(!delete_sub_db(inserted.id).unwrap());
    }

    #[test]
    fn test_rule_sub_update_order_db() {
        crate::db_state::ensure_test_db();

        let mut ids = Vec::new();
        for i in 0..3 {
            let record = RuleSubRecord {
                url: format!("https://example.com/ffi_order_{i}.json"),
                name: format!("排序{i}"),
                created_at: 1700000000000,
                ..RuleSubRecord::default()
            };
            save_sub_db(&record).unwrap();
            let inserted = list_subs_db()
                .unwrap()
                .into_iter()
                .find(|r| r.url == record.url)
                .unwrap();
            ids.push(inserted.id);
        }

        // 反序拖拽
        ids.reverse();
        assert!(update_sub_order_db(&ids).unwrap());

        let all = list_subs_db().unwrap();
        let pos = |id: i64| all.iter().position(|r| r.id == id).unwrap();
        // ids[0] 应排在最前（按 custom_order）
        assert!(pos(ids[0]) < pos(ids[1]));
        assert!(pos(ids[1]) < pos(ids[2]));

        // 清理
        for id in &ids {
            delete_sub_db(*id).unwrap();
        }
    }

    #[test]
    fn test_check_sub_update_not_found() {
        crate::db_state::ensure_test_db();
        let err = check_sub_update_db(999_999_999).unwrap_err();
        assert!(err.to_string().contains("未找到"));
    }

    #[test]
    fn test_apply_sub_update_not_found() {
        crate::db_state::ensure_test_db();
        let err = apply_sub_update_db(999_999_999).unwrap_err();
        assert!(err.to_string().contains("未找到"));
    }

    #[test]
    fn test_check_sub_update_unreachable_url() {
        // 无效 URL：网络错误应体现在 error 字段而非抛出
        crate::db_state::ensure_test_db();
        let record = RuleSubRecord {
            url: "http://127.0.0.1:1/nonexistent.json".to_string(),
            name: "不可达订阅".to_string(),
            created_at: 1700000000000,
            ..RuleSubRecord::default()
        };
        save_sub_db(&record).unwrap();
        let inserted = list_subs_db()
            .unwrap()
            .into_iter()
            .find(|r| r.url == record.url)
            .unwrap();

        let resp = check_sub_update_db(inserted.id).unwrap();
        assert!(!resp.has_update);
        assert!(resp.error.is_some());

        let apply = apply_sub_update_db(inserted.id).unwrap();
        assert!(!apply.success);
        assert!(apply.error.is_some());

        delete_sub_db(inserted.id).unwrap();
    }

    #[test]
    fn test_response_serialization() {
        let check = CheckUpdateResponse {
            id: 1,
            url: "u".into(),
            name: "n".into(),
            due_for_update: true,
            has_update: false,
            remote_version: Some("1.0".into()),
            error: None,
        };
        let json = serde_json::to_string(&check).unwrap();
        assert!(json.contains("dueForUpdate"));
        assert!(json.contains("hasUpdate"));
        assert!(json.contains("remoteVersion"));

        let apply = ApplyUpdateResponse {
            id: 1,
            url: "u".into(),
            success: true,
            items_added: 2,
            items_updated: 1,
            items_removed: 0,
            total_items: 3,
            error: None,
        };
        let json = serde_json::to_string(&apply).unwrap();
        assert!(json.contains("itemsAdded"));
        assert!(json.contains("totalItems"));
    }
}
