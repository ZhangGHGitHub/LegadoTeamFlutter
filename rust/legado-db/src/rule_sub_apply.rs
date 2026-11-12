//! 规则订阅「应用更新」落库实现（P1-3）
//!
//! 背景：`ruleSubApplyUpdate`（FFI）与 `POST /api/rule-update/apply`（Web）
//! 此前只把订阅版本号写回 `ruleSubs`，远程条目从未写入 `book_sources` /
//! `rssSources` / `replace_rules`，UI 却展示「新增/更新/移除」成功计数——
//! 版本号被推进后下次检查显示「已是最新」，形成静默功能失效
//! （`docs/REFACTORING_FULL_AUDIT_REPORT_20261113.md` P1-3）。
//!
//! 本模块是**唯一实现**：FFI 与 Web 两条路径都调用
//! [`apply_rule_subscription`]，禁止在调用方各写一份落库逻辑。
//!
//! ## 语义
//!
//! 1. 按订阅类型解析远程 JSON（必须是数组），以既有仓储单事务 **upsert**：
//!    - 书源：`book_sources`，主键 `bookSourceUrl`
//!      （`BookSourceRepository::insert_batch_with_check_state`，对齐原版
//!      `SourceHelp.insertBookSource` 的「写入 + 重建检验状态」）；
//!    - RSS 源：`rssSources`，主键 `sourceUrl`（`RssSourceRepository::insert`，
//!      `INSERT OR REPLACE` 全列）；
//!    - 替换规则：`replace_rules`，主键 `name`（与
//!      `legado_net::merge_subscription` 的键一致；原版 `RuleUpdate.kt` 按
//!      远程 `id` 匹配，但远程规则 id 与本库自增 id 无对应关系，按名称匹配
//!      才不会误插重复规则）。
//! 2. **只新增与更新，不删除本地条目**（对齐上游 `RuleUpdate.kt:26-117` 与
//!    参考版「勾选导入」的加法语义）：订阅通常只覆盖某一批规则，本地还有
//!    用户自行添加/其他订阅导入的同类条目；若按「远程即全量」删除，会把
//!    不在该订阅里的本地书源误删（100 个本地书源 + 2 条订阅 → 删 98 个），
//!    且自动更新会在后台静默执行。因此 `removed` 字段保留但**恒为 0**。
//! 3. 计数是**实际落库变化**：
//!    - `added`：本地不存在该键 → 已插入；
//!    - `updated`：本地存在且规则内容变化 → 已覆盖写入；
//!      书源用 `BookSource::check_content()` 判定（该函数会归一
//!      `customOrder` / `enabled` / `lastUpdateTime` / `respondTime` /
//!      `weight`，避免「仅本地运行态字段不同」被误计为更新并反复重写）；
//!    - `removed`：恒为 0（仅 upsert）；
//!    - `total`：远程去重后的条目数。
//! 4. 版本号与最后更新时间在**同事务内最后写入**：任一条目解析/写入失败或
//!    订阅行不存在时整笔回滚，版本号不推进（否则下次检查会显示「已是最新」
//!    但数据没进去）。
//! 5. 空远程列表直接报错、零写入：避免一次异常响应把本地规则清空。
//! 6. 书源 / RSS 源更新时保留本地分组（对齐原版 `RuleUpdate.cacheSource`
//!    静默更新分支 `list.bookSourceGroup = localSource.bookSourceGroup`），
//!    分组是用户的本地组织偏好，不属于远程规则内容。
//!
//! ## 与 `legado_net::merge_subscription` 的关系
//!
//! `merge_subscription` 是 JSON 值级别的通用合并工具（原样比较远程/本地
//! JSON 文本），没有模型归一能力：本地行从 DB 读出后序列化会带上
//! `respondTime` / `lastUpdateTime` / 默认值等，与远程 JSON 形态天然不同，
//! 直接用它做基线会把「未变化的条目」全部误判为更新。本模块改用
//! **typed diff**（先反序列化为模型、归一后再比较），计数才与真实落库
//! 变化一致。`merge_subscription` 保留为 net 层通用工具，不再参与 apply。

use std::collections::HashMap;

use rusqlite::Connection;
use serde::de::DeserializeOwned;
use serde_json::Value;

use legado_core::models::{BookSource, ReplaceRule, RssSource};
use legado_core::{LegadoError, LegadoResult};

use crate::connection::in_transaction;
use crate::repository::book_source_repository::BookSourceRepository;
use crate::repository::replace_rule_repository::ReplaceRuleRepository;
use crate::repository::rss_source_repository::RssSourceRepository;
use crate::repository::rule_sub_repository::RuleSubRepository;
use crate::repository::Repository;

/// 应用订阅更新后的真实落库统计
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RuleSubApplyOutcome {
    /// 新增条目数（远程有、本地无，已插入）
    pub added: usize,
    /// 更新条目数（本地有、规则内容变化，已覆盖写入）
    pub updated: usize,
    /// 移除条目数：**恒为 0**（仅 upsert，不删除本地条目；字段保留以维持
    /// FFI/Web 响应形态不变）
    pub removed: usize,
    /// 远程去重后的条目数（本次应用涉及的规则条数；不等于应用后本地总数）
    pub total: usize,
}

/// 应用规则订阅更新：按 `sub_type` upsert 落库并在同事务内推进订阅版本号
///
/// 只新增与更新，不删除本地条目（`removed` 恒 0），语义基准见模块文档。
///
/// # 参数
/// - `conn`：数据库连接（事务由本函数开启；调用方若已在外层事务内则复用）
/// - `sub_id`：`ruleSubs.id`，用于回写版本号；不存在时整笔回滚并返回错误
/// - `sub_type`：`bookSource` / `rssSource` / `replaceRule`
/// - `remote_json`：远程订阅原文（JSON 数组）
/// - `new_version`：本次应用后写入 `ruleSubs.version` 的版本号
/// - `now_millis`：本次应用时间戳（写入 `ruleSubs."update"`）
///
/// # 错误
/// 解析失败、键为空、类型不支持、条目写入失败、订阅行不存在均返回
/// `LegadoError::Database`，且库内零改动（含版本号）。
pub fn apply_rule_subscription(
    conn: &Connection,
    sub_id: i64,
    sub_type: &str,
    remote_json: &str,
    new_version: &str,
    now_millis: i64,
) -> LegadoResult<RuleSubApplyOutcome> {
    in_transaction(conn, "应用规则订阅更新", |conn| {
        let outcome = match sub_type {
            "bookSource" => apply_book_sources(conn, remote_json)?,
            "rssSource" => apply_rss_sources(conn, remote_json)?,
            "replaceRule" => apply_replace_rules(conn, remote_json)?,
            other => {
                return Err(LegadoError::Database(format!(
                    "不支持的订阅类型: {other}（仅支持 bookSource/rssSource/replaceRule）"
                )))
            }
        };

        // 版本号最后写：写在事务内，失败会连同上面的条目写入一起回滚
        RuleSubRepository::new(conn).update_version(sub_id, new_version, now_millis)?;

        Ok(outcome)
    })
}

// ─── 书源 ────────────────────────────────────────────────────

fn apply_book_sources(conn: &Connection, remote_json: &str) -> LegadoResult<RuleSubApplyOutcome> {
    let parsed: Vec<BookSource> = parse_remote_array(remote_json, "书源")?;
    if parsed.is_empty() {
        return Err(empty_remote_error("书源"));
    }

    let mut order: Vec<String> = Vec::with_capacity(parsed.len());
    let mut remote: HashMap<String, BookSource> = HashMap::with_capacity(parsed.len());
    for (index, item) in parsed.into_iter().enumerate() {
        if item.book_source_url.trim().is_empty() {
            return Err(LegadoError::Database(format!(
                "书源订阅第 {} 条缺少 bookSourceUrl（不是有效书源）",
                index + 1
            )));
        }
        let key = item.book_source_url.clone();
        if !remote.contains_key(&key) {
            order.push(key.clone());
        }
        // 同键重复条目后者覆盖：与原版全量导入语义一致
        remote.insert(key, item);
    }

    let repo = BookSourceRepository::new(conn);
    let local = repo.find_all()?;
    let local_map: HashMap<&str, &BookSource> = local
        .iter()
        .map(|source| (source.book_source_url.as_str(), source))
        .collect();

    let mut to_write: Vec<BookSource> = Vec::new();
    let mut added = 0usize;
    let mut updated = 0usize;

    for key in &order {
        let remote_item = &remote[key];
        match local_map.get(key.as_str()) {
            None => {
                added += 1;
                to_write.push(remote_item.clone());
            }
            Some(local_item) => {
                let mut candidate = remote_item.clone();
                // 分组是本地组织偏好，远程不覆盖（对齐原版静默更新语义）
                candidate.book_source_group = local_item.book_source_group.clone();
                if local_item.check_content() != candidate.check_content() {
                    updated += 1;
                    to_write.push(candidate);
                }
            }
        }
    }

    // 仅 upsert：远程缺失的本地书源原样保留（对齐上游 RuleUpdate.kt 与参考版
    // 「勾选导入」加法语义，`removed` 恒 0）。写入与版本号同事务。
    repo.insert_batch_with_check_state(&to_write)?;

    Ok(RuleSubApplyOutcome {
        added,
        updated,
        removed: 0,
        total: order.len(),
    })
}

// ─── RSS 源 ──────────────────────────────────────────────────

fn apply_rss_sources(conn: &Connection, remote_json: &str) -> LegadoResult<RuleSubApplyOutcome> {
    let parsed: Vec<RssSource> = parse_remote_array(remote_json, "RSS 源")?;
    if parsed.is_empty() {
        return Err(empty_remote_error("RSS 源"));
    }

    let mut order: Vec<String> = Vec::with_capacity(parsed.len());
    let mut remote: HashMap<String, RssSource> = HashMap::with_capacity(parsed.len());
    for (index, item) in parsed.into_iter().enumerate() {
        if item.source_url.trim().is_empty() {
            return Err(LegadoError::Database(format!(
                "RSS 源订阅第 {} 条缺少 sourceUrl（不是有效 RSS 源）",
                index + 1
            )));
        }
        let key = item.source_url.clone();
        if !remote.contains_key(&key) {
            order.push(key.clone());
        }
        remote.insert(key, item);
    }

    let repo = RssSourceRepository::new(conn);
    let local = repo.find_all().map_err(LegadoError::Database)?;
    let local_map: HashMap<&str, &RssSource> = local
        .iter()
        .map(|source| (source.source_url.as_str(), source))
        .collect();

    let mut to_write: Vec<RssSource> = Vec::new();
    let mut added = 0usize;
    let mut updated = 0usize;

    for key in &order {
        let remote_item = &remote[key];
        match local_map.get(key.as_str()) {
            None => {
                added += 1;
                to_write.push(remote_item.clone());
            }
            Some(local_item) => {
                let mut candidate = remote_item.clone();
                // 分组保留本地（同书源口径）
                candidate.source_group = local_item.source_group.clone();
                if rss_content_key(local_item) != rss_content_key(&candidate) {
                    updated += 1;
                    to_write.push(candidate);
                }
            }
        }
    }

    // 仅 upsert：远程缺失的本地 RSS 源原样保留（同书源口径，`removed` 恒 0）
    for item in &to_write {
        repo.insert(item).map_err(LegadoError::Database)?;
    }

    Ok(RuleSubApplyOutcome {
        added,
        updated,
        removed: 0,
        total: order.len(),
    })
}

/// RSS 源「规则内容」归一化键：剔除本地运行态字段，避免误判更新。
///
/// `RssSource` 没有像 `BookSource::check_content` 那样的既有归一函数，
/// 这里按同一口径处理 `customOrder` / `lastUpdateTime` / `enabled`
/// （本地启停与排序不属于远程规则内容）。
fn rss_content_key(source: &RssSource) -> String {
    let mut normalized = source.clone();
    normalized.custom_order = 0;
    normalized.last_update_time = 0;
    normalized.enabled = true;
    serde_json::to_string(&normalized).unwrap_or_default()
}

// ─── 替换规则 ────────────────────────────────────────────────

fn apply_replace_rules(conn: &Connection, remote_json: &str) -> LegadoResult<RuleSubApplyOutcome> {
    let parsed: Vec<ReplaceRule> = parse_remote_array(remote_json, "替换规则")?;
    if parsed.is_empty() {
        return Err(empty_remote_error("替换规则"));
    }

    let mut order: Vec<String> = Vec::with_capacity(parsed.len());
    let mut remote: HashMap<String, ReplaceRule> = HashMap::with_capacity(parsed.len());
    for (index, item) in parsed.into_iter().enumerate() {
        if item.name.trim().is_empty() {
            return Err(LegadoError::Database(format!(
                "替换规则订阅第 {} 条缺少 name（不是有效替换规则）",
                index + 1
            )));
        }
        let key = item.name.clone();
        if !remote.contains_key(&key) {
            order.push(key.clone());
        }
        remote.insert(key, item);
    }

    let repo = ReplaceRuleRepository::new(conn);
    let local = repo.find_all()?;
    let local_map: HashMap<&str, &ReplaceRule> = local
        .iter()
        .map(|rule| (rule.name.as_str(), rule))
        .collect();

    let mut added = 0usize;
    let mut updated = 0usize;
    // 新规则追加到本地列表末尾（max(sortOrder)+1 起递增）。
    // 选择说明：远程 sortOrder 是导出方本地排序值，直接沿用会与本地已有
    // 规则撞序、打乱用户排序；而 `ReplaceRuleRepository::update` 也不写
    // sortOrder（排序只经 reorder 变更，契约 §2.8 批12），因此「新规则
    // 顺序尾插、已有规则排序不动」是唯一不破坏本地排序的语义。
    let mut next_order = repo.next_order()?;

    for key in &order {
        let remote_item = &remote[key];
        match local_map.get(key.as_str()) {
            None => {
                let mut rule = remote_item.clone();
                rule.id = 0;
                rule.order = next_order;
                next_order += 1;
                repo.insert(&rule)?;
                added += 1;
            }
            Some(local_item) => {
                if !replace_rule_content_eq(local_item, remote_item) {
                    let mut rule = remote_item.clone();
                    // 按本地 id 更新，保留本地排序值（update 不写 sortOrder）
                    rule.id = local_item.id;
                    rule.order = local_item.order;
                    repo.update(&rule)?;
                    updated += 1;
                }
            }
        }
    }

    // 仅 upsert：远程缺失的本地替换规则原样保留（`removed` 恒 0）
    Ok(RuleSubApplyOutcome {
        added,
        updated,
        removed: 0,
        total: order.len(),
    })
}

/// 替换规则「规则内容」比较：排除本地自增 id 与本地 sortOrder。
///
/// 远程规则的 `id` 与本库自增 id 无对应关系，`sortOrder` 属本地排序；
/// 其余业务字段任一变化即视为需要更新（对齐原版对 pattern/replacement
/// 等内容的变更判定，并覆盖范围/开关等全业务字段）。
fn replace_rule_content_eq(left: &ReplaceRule, right: &ReplaceRule) -> bool {
    left.name == right.name
        && left.group == right.group
        && left.pattern == right.pattern
        && left.replacement == right.replacement
        && left.scope == right.scope
        && left.scope_title == right.scope_title
        && left.scope_content == right.scope_content
        && left.scope_source == right.scope_source
        && left.exclude_scope == right.exclude_scope
        && left.is_enabled == right.is_enabled
        && left.is_regex == right.is_regex
        && left.timeout_millisecond == right.timeout_millisecond
}

// ─── 公共辅助 ────────────────────────────────────────────────

/// 解析远程订阅数组；非数组或任一条反序列化失败都整体报错（零写入）。
fn parse_remote_array<T: DeserializeOwned>(
    remote_json: &str,
    type_label: &str,
) -> LegadoResult<Vec<T>> {
    let value: Value = serde_json::from_str(remote_json)
        .map_err(|e| LegadoError::Database(format!("解析{type_label}订阅失败: {e}")))?;
    let array = value.as_array().ok_or_else(|| {
        LegadoError::Database(format!(
            "{type_label}订阅内容必须是 JSON 数组，实际为: {}",
            json_type_name(&value)
        ))
    })?;

    let mut items = Vec::with_capacity(array.len());
    for (index, item) in array.iter().enumerate() {
        let parsed = serde_json::from_value(item.clone()).map_err(|e| {
            LegadoError::Database(format!("解析{type_label}第 {} 条失败: {e}", index + 1))
        })?;
        items.push(parsed);
    }
    Ok(items)
}

/// 空远程列表拒绝应用：镜像式同步下空列表会清空本地全部同类规则，
/// 一次异常响应（如服务端返回 `[]`）就造成不可逆数据丢失。
fn empty_remote_error(type_label: &str) -> LegadoError {
    LegadoError::Database(format!(
        "{type_label}订阅内容为空（0 条），已拒绝应用以免清空本地{type_label}"
    ))
}

fn json_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "布尔值",
        Value::Number(_) => "数字",
        Value::String(_) => "字符串",
        Value::Array(_) => "数组",
        Value::Object(_) => "对象",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::init_in_memory_database;
    use crate::repository::rule_sub_repository::RuleSubRecord;

    /// 建一条订阅并返回 id（in-memory 库，测试隔离）
    fn seed_sub(conn: &Connection, sub_type: &str, version: &str) -> i64 {
        RuleSubRepository::new(conn)
            .insert(&RuleSubRecord {
                url: format!("https://example.com/{sub_type}.json"),
                name: format!("测试订阅-{sub_type}"),
                sub_type: sub_type.to_string(),
                version: version.to_string(),
                created_at: 1_700_000_000_000,
                ..RuleSubRecord::default()
            })
            .unwrap()
    }

    fn version_of(conn: &Connection, id: i64) -> (String, i64) {
        let record = RuleSubRepository::new(conn)
            .find_by_id(id)
            .unwrap()
            .expect("订阅应存在");
        (record.version, record.last_update)
    }

    fn book_source_json(url: &str, name: &str, search_url: &str) -> String {
        format!(
            r#"{{"bookSourceUrl":"{url}","bookSourceName":"{name}","bookSourceType":0,"searchUrl":"{search_url}","ruleSearch":{{"bookList":"x","name":"y","author":"z","bookUrl":"w"}}}}"#
        )
    }

    fn book_source(url: &str, name: &str, search_url: &str) -> BookSource {
        serde_json::from_str(&book_source_json(url, name, search_url)).unwrap()
    }

    // ─── 书源 ─────────────────────────────────────────────

    #[test]
    fn test_apply_book_sources_inserts_rows_and_updates_version() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");

        let remote = format!(
            "[{},{}]",
            book_source_json(
                "https://a.example.com",
                "A源",
                "https://a.example.com/s?q={key}"
            ),
            book_source_json(
                "https://b.example.com",
                "B源",
                "https://b.example.com/s?q={key}"
            )
        );

        let outcome = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            &remote,
            "2.0",
            1_700_000_100_000,
        )
        .unwrap();

        assert_eq!(
            outcome,
            RuleSubApplyOutcome {
                added: 2,
                updated: 0,
                removed: 0,
                total: 2
            }
        );
        // DB 真有 2 行（不是只回写版本号）
        let stored = BookSourceRepository::new(conn).find_all().unwrap();
        assert_eq!(stored.len(), 2);
        assert!(stored
            .iter()
            .any(|s| s.book_source_url == "https://a.example.com"));
        // 书源检验状态同事务写入
        let state = crate::repository::book_source_check_state_repository::BookSourceCheckStateRepository::new(conn)
            .find_by_url("https://a.example.com")
            .unwrap();
        assert!(state.is_some());
        // 版本号与最后更新时间
        let (version, last_update) = version_of(conn, sub_id);
        assert_eq!(version, "2.0");
        assert_eq!(last_update, 1_700_000_100_000);
    }

    #[test]
    fn test_apply_book_sources_updates_changed_row_and_keeps_group() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");

        let mut local = book_source(
            "https://a.example.com",
            "旧名",
            "https://old.example.com/s?q={key}",
        );
        local.book_source_group = Some("本地分组".to_string());
        BookSourceRepository::new(conn)
            .insert_with_check_state(&local)
            .unwrap();

        let remote = format!(
            "[{}]",
            book_source_json(
                "https://a.example.com",
                "新名",
                "https://new.example.com/s?q={key}"
            )
        );
        let outcome = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            &remote,
            "2.0",
            1_700_000_100_000,
        )
        .unwrap();
        assert_eq!(outcome.added, 0);
        assert_eq!(outcome.updated, 1);
        assert_eq!(outcome.removed, 0);

        let stored = BookSourceRepository::new(conn).find_all().unwrap();
        assert_eq!(stored.len(), 1);
        assert_eq!(stored[0].book_source_name, "新名");
        assert_eq!(
            stored[0].search_url.as_deref(),
            Some("https://new.example.com/s?q={key}")
        );
        // 分组保留本地
        assert_eq!(stored[0].book_source_group.as_deref(), Some("本地分组"));
    }

    #[test]
    fn test_apply_book_sources_keeps_rows_missing_from_remote() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");

        let repo = BookSourceRepository::new(conn);
        repo.insert_batch_with_check_state(&[
            book_source("https://a.example.com", "A", "https://a.example.com/s"),
            book_source("https://b.example.com", "B", "https://b.example.com/s"),
        ])
        .unwrap();

        // 远程只含 A：B 是本地其他来源的书源，应用订阅不得删除（仅 upsert，
        // 对齐上游 RuleUpdate.kt 与参考版「勾选导入」加法语义）
        let remote = format!(
            "[{}]",
            book_source_json("https://a.example.com", "A", "https://a.example.com/s")
        );
        let outcome = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            &remote,
            "2.0",
            1_700_000_100_000,
        )
        .unwrap();
        assert_eq!(
            outcome,
            RuleSubApplyOutcome {
                added: 0,
                updated: 0,
                removed: 0,
                total: 1
            }
        );

        // 本地 B 必须原样保留（含检验状态）
        let stored = repo.find_all().unwrap();
        assert_eq!(stored.len(), 2, "远程缺失的本地书源不得被删除");
        assert!(stored
            .iter()
            .any(|s| s.book_source_url == "https://b.example.com"));
        let kept_state = crate::repository::book_source_check_state_repository::BookSourceCheckStateRepository::new(conn)
            .find_by_url("https://b.example.com")
            .unwrap();
        assert!(kept_state.is_some(), "未删除条目的检验状态应保留");
    }

    #[test]
    fn test_apply_book_sources_is_idempotent() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");
        let remote = format!(
            "[{}]",
            book_source_json("https://a.example.com", "A", "https://a.example.com/s")
        );

        let first = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            &remote,
            "1.1",
            1_700_000_100_000,
        )
        .unwrap();
        assert_eq!(first.added, 1);

        // 远程内容未变：第二次应用零写入、计数全 0（不能每次都报「更新」）
        let second = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            &remote,
            "1.1",
            1_700_000_200_000,
        )
        .unwrap();
        assert_eq!(
            second,
            RuleSubApplyOutcome {
                added: 0,
                updated: 0,
                removed: 0,
                total: 1
            }
        );
    }

    // ─── RSS 源 ───────────────────────────────────────────

    fn rss_json(url: &str, name: &str, rule_title: &str) -> String {
        format!(
            r#"{{"sourceUrl":"{url}","sourceName":"{name}","ruleArticles":"{rule_title}","ruleTitle":"title","ruleLink":"link"}}"#
        )
    }

    #[test]
    fn test_apply_rss_sources_add_update_keeps_missing() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "rssSource", "1.0");
        let repo = RssSourceRepository::new(conn);

        // 本地已有 A（旧规则）与 B
        repo.insert(&RssSource {
            source_url: "https://a.example.com/rss".into(),
            source_name: "A源".into(),
            rule_articles: Some("old".into()),
            source_group: Some("本地分组".into()),
            ..RssSource::default()
        })
        .unwrap();
        repo.insert(&RssSource {
            source_url: "https://b.example.com/rss".into(),
            source_name: "B源".into(),
            ..RssSource::default()
        })
        .unwrap();

        // 远程：A 新规则 + C 新增；B 不在远程（仅 upsert，不得删除）
        let remote = format!(
            "[{},{}]",
            rss_json("https://a.example.com/rss", "A源", "new"),
            rss_json("https://c.example.com/rss", "C源", "c-rule")
        );
        let outcome =
            apply_rule_subscription(conn, sub_id, "rssSource", &remote, "2.0", 1_700_000_100_000)
                .unwrap();
        assert_eq!(
            outcome,
            RuleSubApplyOutcome {
                added: 1,
                updated: 1,
                removed: 0,
                total: 2
            }
        );

        let stored = repo.find_all().unwrap();
        assert_eq!(stored.len(), 3, "远程缺失的本地 RSS 源不得被删除");
        let a = stored
            .iter()
            .find(|s| s.source_url == "https://a.example.com/rss")
            .unwrap();
        assert_eq!(a.rule_articles.as_deref(), Some("new"));
        // 分组保留本地
        assert_eq!(a.source_group.as_deref(), Some("本地分组"));
        assert!(stored
            .iter()
            .any(|s| s.source_url == "https://c.example.com/rss"));
        assert!(
            stored
                .iter()
                .any(|s| s.source_url == "https://b.example.com/rss"),
            "B 应原样保留"
        );
        assert_eq!(version_of(conn, sub_id).0, "2.0");
    }

    // ─── 替换规则 ─────────────────────────────────────────

    fn replace_rule_json(name: &str, pattern: &str, replacement: &str) -> String {
        format!(
            r#"{{"id":99,"name":"{name}","pattern":"{pattern}","replacement":"{replacement}","scopeContent":true,"isEnabled":true,"isRegex":true,"timeoutMillisecond":3000,"sortOrder":0}}"#
        )
    }

    #[test]
    fn test_apply_replace_rules_add_update_keeps_missing_with_append_order() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "replaceRule", "1.0");
        let repo = ReplaceRuleRepository::new(conn);

        // 本地已有「旧规则」（order=5）与「远程缺失的本地规则」（order=6）
        let old_id = repo
            .insert(&ReplaceRule {
                name: "旧规则".into(),
                pattern: "a".into(),
                replacement: "b".into(),
                order: 5,
                ..ReplaceRule::default()
            })
            .unwrap();
        repo.insert(&ReplaceRule {
            name: "远程缺失的本地规则".into(),
            pattern: "x".into(),
            replacement: "y".into(),
            order: 6,
            ..ReplaceRule::default()
        })
        .unwrap();

        let remote = format!(
            "[{},{}]",
            replace_rule_json("旧规则", "a2", "b2"), // 内容变化 → 更新
            replace_rule_json("新规则", "c", "d")    // 新增 → 尾插
        );
        let outcome = apply_rule_subscription(
            conn,
            sub_id,
            "replaceRule",
            &remote,
            "2.0",
            1_700_000_100_000,
        )
        .unwrap();
        assert_eq!(
            outcome,
            RuleSubApplyOutcome {
                added: 1,
                updated: 1,
                removed: 0,
                total: 2
            }
        );

        let stored = repo.find_all().unwrap();
        assert_eq!(stored.len(), 3, "远程缺失的本地替换规则不得被删除");
        let old = stored.iter().find(|r| r.name == "旧规则").unwrap();
        assert_eq!(old.id, old_id, "按本地 id 更新，不新增重复行");
        assert_eq!(old.pattern, "a2");
        assert_eq!(old.replacement, "b2");
        assert_eq!(old.order, 5, "已有规则排序不变");
        let added = stored.iter().find(|r| r.name == "新规则").unwrap();
        assert_eq!(added.order, 7, "新规则按 max+1 尾插");
        let kept = stored
            .iter()
            .find(|r| r.name == "远程缺失的本地规则")
            .expect("本地其他规则应原样保留");
        assert_eq!(kept.order, 6, "未涉及规则的排序不变");
    }

    // ─── 回滚 / 错误 ──────────────────────────────────────

    #[test]
    fn test_apply_rolls_back_on_write_failure() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");

        // 注入落库失败：第二条书源插入时 ABORT，验证整批（含第一条）回滚
        conn.execute_batch(
            r#"CREATE TRIGGER fail_book_source_insert
               BEFORE INSERT ON book_sources
               WHEN NEW.bookSourceUrl = 'https://boom.example.com'
               BEGIN SELECT RAISE(ABORT, '注入的落库失败'); END;"#,
        )
        .unwrap();

        let remote = format!(
            "[{},{}]",
            book_source_json("https://ok.example.com", "OK", "https://ok.example.com/s"),
            book_source_json(
                "https://boom.example.com",
                "BOOM",
                "https://boom.example.com/s"
            )
        );
        let err = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            &remote,
            "2.0",
            1_700_000_100_000,
        )
        .unwrap_err();
        assert!(err.to_string().contains("落库失败") || err.to_string().contains("注入"));

        // 第一条也不能留下；版本号不推进
        let stored = BookSourceRepository::new(conn).find_all().unwrap();
        assert!(stored.is_empty(), "事务回滚后应零行，实际 {stored:?}");
        let (version, last_update) = version_of(conn, sub_id);
        assert_eq!(version, "1.0");
        assert_eq!(last_update, 0);
    }

    #[test]
    fn test_apply_rolls_back_when_version_write_fails() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        // 不存在的订阅 id：条目写完后 update_version 报错 → 整笔回滚
        let remote = format!(
            "[{}]",
            book_source_json("https://a.example.com", "A", "https://a.example.com/s")
        );
        let err = apply_rule_subscription(conn, 999_999_999, "bookSource", &remote, "2.0", 1)
            .unwrap_err();
        assert!(err.to_string().contains("未找到"));
        let stored = BookSourceRepository::new(conn).find_all().unwrap();
        assert!(stored.is_empty(), "版本号写入失败时条目必须回滚");
    }

    #[test]
    fn test_apply_rejects_empty_remote() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");
        BookSourceRepository::new(conn)
            .insert(&book_source(
                "https://a.example.com",
                "A",
                "https://a.example.com/s",
            ))
            .unwrap();

        let err = apply_rule_subscription(conn, sub_id, "bookSource", "[]", "2.0", 1).unwrap_err();
        assert!(err.to_string().contains("为空"));
        // 本地规则不能被清空，版本号不推进
        assert_eq!(BookSourceRepository::new(conn).find_all().unwrap().len(), 1);
        assert_eq!(version_of(conn, sub_id).0, "1.0");
    }

    #[test]
    fn test_apply_rejects_unknown_sub_type_and_invalid_payload() {
        let db = init_in_memory_database().unwrap();
        let conn = db.connection();
        let sub_id = seed_sub(conn, "bookSource", "1.0");

        let err = apply_rule_subscription(conn, sub_id, "unknown", "[]", "2.0", 1).unwrap_err();
        assert!(err.to_string().contains("不支持的订阅类型"));

        let err =
            apply_rule_subscription(conn, sub_id, "bookSource", "{\"a\":1}", "2.0", 1).unwrap_err();
        assert!(err.to_string().contains("必须是 JSON 数组"));

        let err = apply_rule_subscription(
            conn,
            sub_id,
            "bookSource",
            r#"[{"bookSourceName":"无URL"}]"#,
            "2.0",
            1,
        )
        .unwrap_err();
        assert!(err.to_string().contains("缺少 bookSourceUrl"));
        assert_eq!(version_of(conn, sub_id).0, "1.0");
    }
}
