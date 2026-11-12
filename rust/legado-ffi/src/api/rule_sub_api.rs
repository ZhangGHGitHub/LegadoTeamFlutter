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
use legado_db::{apply_rule_subscription, RuleSubRecord, RuleSubRepository};
use legado_net::{fetch_subscription, should_update, RuleSubscription};

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

/// 应用订阅更新（P1-3：拉取远程 → 真正落库 → 最后回写版本号）
///
/// 流程：
/// 1. 读取订阅记录并拉取远程内容；
/// 2. [`apply_remote_content`] 按 `sub_type` 把条目写进
///    `book_sources` / `rssSources` / `replace_rules`，与版本号更新在
///    **同一数据库事务**内完成（任一步失败整体回滚，版本号不推进）；
/// 3. 返回的 `itemsAdded` / `itemsUpdated` / `itemsRemoved` 是真实落库变化。
///
/// 落库实现与 Web `POST /api/rule-update/apply` 共用
/// `legado_db::apply_rule_subscription`（单实现，禁止两轨各写一份）。
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

    match apply_remote_content(&sub, &remote_json) {
        Ok(response) => Ok(response),
        Err(e) => Ok(ApplyUpdateResponse {
            id: sub.id,
            url: sub.url.clone(),
            success: false,
            items_added: 0,
            items_updated: 0,
            items_removed: 0,
            total_items: 0,
            error: Some(format!("应用订阅失败: {e}")),
        }),
    }
}

/// 应用已拉取的远程订阅内容（无网络）
///
/// 失败时返回 `Err`，此时数据库（含订阅版本号）零改动。
fn apply_remote_content(
    sub: &RuleSubRecord,
    remote_json: &str,
) -> LegadoResult<ApplyUpdateResponse> {
    with_database(|db| apply_remote_content_on(db, sub, remote_json))
}

/// [`apply_remote_content`] 的连接注入形态（生产用全局池；测试用隔离内存库）
///
/// 抽出该层是为了让「应用后 DB 真有数据 / 失败零写入」的断言能在
/// **独立内存库**上执行：共享测试库被大量用例并行复用（含未持串行锁的
/// 历史用例），在共享库上做「订阅镜像」写入既会抢写锁也会误删他例夹具。
fn apply_remote_content_on(
    db: &legado_db::Database,
    sub: &RuleSubRecord,
    remote_json: &str,
) -> LegadoResult<ApplyUpdateResponse> {
    let new_version = extract_version(remote_json).unwrap_or_default();
    let outcome = apply_rule_subscription(
        db.connection(),
        sub.id,
        &sub.sub_type,
        remote_json,
        &new_version,
        now_millis(),
    )?;

    Ok(ApplyUpdateResponse {
        id: sub.id,
        url: sub.url.clone(),
        success: true,
        items_added: outcome.added,
        items_updated: outcome.updated,
        items_removed: outcome.removed,
        total_items: outcome.total,
        error: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_rule_sub_crud_db() {
        let _db_guard = crate::db_state::ensure_test_db();

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
        let _db_guard = crate::db_state::ensure_test_db();

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
        let _db_guard = crate::db_state::ensure_test_db();
        let err = check_sub_update_db(999_999_999).unwrap_err();
        assert!(err.to_string().contains("未找到"));
    }

    #[test]
    fn test_apply_sub_update_not_found() {
        let _db_guard = crate::db_state::ensure_test_db();
        let err = apply_sub_update_db(999_999_999).unwrap_err();
        assert!(err.to_string().contains("未找到"));
    }

    #[test]
    fn test_check_sub_update_unreachable_url() {
        // 无效 URL：网络错误应体现在 error 字段而非抛出
        let _db_guard = crate::db_state::ensure_test_db();
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

    /// 建隔离内存库并写入一条订阅，返回 (db, 订阅快照)
    ///
    /// 不用共享测试库：`apply` 是「订阅镜像」写入，会删除本地不在远程列表里
    /// 的同类条目；共享库里有大量其他用例的并行夹具，既会抢写锁（database
    /// is locked）也会误删他例数据。隔离内存库与生产走同一
    /// `apply_remote_content_on` / `apply_rule_subscription` 代码路径。
    fn isolated_db_with_sub(sub_type: &str) -> (legado_db::Database, RuleSubRecord) {
        let db = legado_db::init_in_memory_database().unwrap();
        let id = RuleSubRepository::new(db.connection())
            .insert(&RuleSubRecord {
                url: format!("https://example.com/ffi_apply_{sub_type}.json"),
                name: format!("FFI应用订阅-{sub_type}"),
                sub_type: sub_type.to_string(),
                version: "1.0".to_string(),
                created_at: 1_700_000_000_000,
                ..RuleSubRecord::default()
            })
            .unwrap();
        let sub = RuleSubRepository::new(db.connection())
            .find_by_id(id)
            .unwrap()
            .unwrap();
        (db, sub)
    }

    /// P1-3：应用订阅必须真正落库（不是只回写版本号）
    #[test]
    fn test_apply_remote_content_lands_rows_and_bumps_version() {
        use legado_db::BookSourceRepository;

        let (db, sub) = isolated_db_with_sub("bookSource");
        let remote = r#"[
            {"bookSourceUrl":"https://ffi-p13-a.example.com","bookSourceName":"P13-A","searchUrl":"https://ffi-p13-a.example.com/s"},
            {"bookSourceUrl":"https://ffi-p13-b.example.com","bookSourceName":"P13-B","searchUrl":"https://ffi-p13-b.example.com/s"}
        ]"#;

        let resp = apply_remote_content_on(&db, &sub, remote).unwrap();
        assert!(resp.success, "应用应成功: {:?}", resp.error);
        assert_eq!(resp.items_added, 2, "新增数应为真实落库的 2 条");
        assert_eq!(resp.items_updated, 0);
        assert_eq!(resp.total_items, 2);

        // DB 真有 2 行，字段可读回
        let landed = BookSourceRepository::new(db.connection())
            .find_by_url("https://ffi-p13-a.example.com")
            .unwrap()
            .expect("书源应已落库");
        assert_eq!(landed.book_source_name, "P13-A");

        // 最后更新时间已推进（订阅内容是 JSON 数组，无 version 字段 → 版本串为空，
        // 与既有多数订阅源形态一致；此处断言版本号已随落库同事务回写）
        let after = RuleSubRepository::new(db.connection())
            .find_by_id(sub.id)
            .unwrap()
            .unwrap();
        assert!(after.last_update > 0);
    }

    /// P1-3：落库失败时数据库零改动、版本号不推进
    #[test]
    fn test_apply_remote_content_failure_keeps_db_and_version() {
        use legado_db::BookSourceRepository;

        let (db, sub) = isolated_db_with_sub("bookSource");

        // 缺 bookSourceUrl → 解析阶段失败，零写入
        let err =
            apply_remote_content_on(&db, &sub, r#"[{"bookSourceName":"无URL"}]"#).unwrap_err();
        assert!(err.to_string().contains("缺少 bookSourceUrl"));

        let version = RuleSubRepository::new(db.connection())
            .find_by_id(sub.id)
            .unwrap()
            .unwrap()
            .version;
        assert_eq!(version, "1.0", "失败时版本号不得推进");
        // 无效条目（空 URL）没有被写入
        assert!(
            BookSourceRepository::new(db.connection())
                .find_by_url("")
                .unwrap()
                .is_none(),
            "解析阶段失败时不得留下任何条目"
        );
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
