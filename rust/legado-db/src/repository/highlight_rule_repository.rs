//! HighlightRule Repository — highlightRules 表数据访问层
//!
//! 对齐 Android 原版 `HighlightRuleDao` 方法清单：
//! all / findById / findEnabledByBook / minOrder / maxOrder / importRules /
//! insert / update / delete / deleteAll / replaceAll。

use std::collections::{HashMap, HashSet};

use rusqlite::{params, Connection};

use legado_core::models::HighlightRule;
use legado_core::{LegadoError, LegadoResult};

/// 高亮规则查询列（与 row_to_rule 的索引一一对应）
const SELECT_COLUMNS: &str = "SELECT id, uuid, name, pattern, isRegex, scope, isEnabled,
    style, sortOrder, timeoutMillisecond, applyToTitle, applyToBody FROM highlightRules";

/// 高亮规则数据访问层
pub struct HighlightRuleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> HighlightRuleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入高亮规则（INSERT OR REPLACE，对齐 DAO `@Insert(onConflict = REPLACE)`）
    ///
    /// id 为 0 时使用自增主键，返回实际的规则 ID。
    pub fn insert(&self, rule: &HighlightRule) -> LegadoResult<i64> {
        if rule.id > 0 {
            self.conn
                .execute(
                    "INSERT OR REPLACE INTO highlightRules
                     (id, uuid, name, pattern, isRegex, scope, isEnabled, style,
                      sortOrder, timeoutMillisecond, applyToTitle, applyToBody)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
                    params![
                        rule.id,
                        rule.uuid,
                        rule.name,
                        rule.pattern,
                        rule.isRegex,
                        rule.scope,
                        rule.isEnabled,
                        rule.style,
                        rule.sortOrder,
                        rule.timeoutMillisecond,
                        rule.applyToTitle,
                        rule.applyToBody,
                    ],
                )
                .map_err(|e| LegadoError::Database(format!("插入高亮规则失败: {e}")))?;
            Ok(rule.id)
        } else {
            self.conn
                .execute(
                    "INSERT INTO highlightRules
                     (uuid, name, pattern, isRegex, scope, isEnabled, style,
                      sortOrder, timeoutMillisecond, applyToTitle, applyToBody)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                    params![
                        rule.uuid,
                        rule.name,
                        rule.pattern,
                        rule.isRegex,
                        rule.scope,
                        rule.isEnabled,
                        rule.style,
                        rule.sortOrder,
                        rule.timeoutMillisecond,
                        rule.applyToTitle,
                        rule.applyToBody,
                    ],
                )
                .map_err(|e| LegadoError::Database(format!("插入高亮规则失败: {e}")))?;
            Ok(self.conn.last_insert_rowid())
        }
    }

    /// 更新高亮规则（对齐 DAO `@Update`）
    pub fn update(&self, rule: &HighlightRule) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE highlightRules SET uuid=?1, name=?2, pattern=?3, isRegex=?4, scope=?5,
                 isEnabled=?6, style=?7, sortOrder=?8, timeoutMillisecond=?9,
                 applyToTitle=?10, applyToBody=?11
                 WHERE id=?12",
                params![
                    rule.uuid,
                    rule.name,
                    rule.pattern,
                    rule.isRegex,
                    rule.scope,
                    rule.isEnabled,
                    rule.style,
                    rule.sortOrder,
                    rule.timeoutMillisecond,
                    rule.applyToTitle,
                    rule.applyToBody,
                    rule.id,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新高亮规则失败: {e}")))?;
        Ok(())
    }

    /// 按 ID 删除高亮规则（对齐 DAO `@Delete`），返回是否实际删除
    pub fn delete(&self, id: i64) -> LegadoResult<bool> {
        let rows = self
            .conn
            .execute("DELETE FROM highlightRules WHERE id=?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除高亮规则失败: {e}")))?;
        Ok(rows > 0)
    }

    /// 删除所有高亮规则（对齐 DAO `deleteAll`）
    pub fn delete_all(&self) -> LegadoResult<i64> {
        let rows = self
            .conn
            .execute("DELETE FROM highlightRules", [])
            .map_err(|e| LegadoError::Database(format!("清空高亮规则失败: {e}")))?;
        Ok(rows as i64)
    }

    /// 全量替换规则（对齐 DAO `replaceAll`：uuid 校验 + order 重排 + 先清空再插入）
    ///
    /// 原版语义（HighlightRuleDao.replaceAll）：先经 `mergeImportedHighlightRules`
    /// 校验 uuid 合法且集合内唯一、按传入顺序重排 sortOrder（0..n），
    /// 全部规则丢弃原 id 重新自增插入。
    pub fn replace_all(&self, rules: &[HighlightRule]) -> LegadoResult<()> {
        let merged = merge_imported_highlight_rules(&[], rules)?;
        let tx_err = |e: rusqlite::Error| LegadoError::Database(format!("事务失败: {e}"));
        let tx = self.conn.unchecked_transaction().map_err(tx_err)?;
        tx.execute("DELETE FROM highlightRules", [])
            .map_err(|e| LegadoError::Database(format!("清空高亮规则失败: {e}")))?;
        for rule in &merged {
            // 原版 replaceAll 走 added 分支 copy(id = 0)：全部重新自增分配
            tx.execute(
                "INSERT INTO highlightRules
                 (uuid, name, pattern, isRegex, scope, isEnabled, style,
                  sortOrder, timeoutMillisecond, applyToTitle, applyToBody)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
                params![
                    rule.uuid,
                    rule.name,
                    rule.pattern,
                    rule.isRegex,
                    rule.scope,
                    rule.isEnabled,
                    rule.style,
                    rule.sortOrder,
                    rule.timeoutMillisecond,
                    rule.applyToTitle,
                    rule.applyToBody,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("批量插入高亮规则失败: {e}")))?;
        }
        tx.commit().map_err(tx_err)?;
        Ok(())
    }

    /// 导入规则（对齐 DAO `importRules`：按 uuid 合并去重）
    ///
    /// 原版语义（HighlightRuleDao.importRules + mergeImportedHighlightRules）：
    /// 1. 校验导入集合 uuid 合法（可解析为 UUID）且互不重复，否则报错；
    /// 2. uuid（忽略大小写）已存在的本地规则：保留本地 id、内容替换为导入项（update）；
    /// 3. uuid 为新规则的导入项：id 归零自增插入（insert）；
    /// 4. 合并后的全部规则（existing + added）按顺序重排 sortOrder = 0..n。
    ///
    /// 调用方负责在导入前对每条规则执行 `normalize_for_restore`
    /// （对齐原版 ImportHighlightRuleViewModel:93），uuid 非法的规则
    /// 在 normalize 阶段会重新生成随机 UUID。
    pub fn import_rules(&self, rules: &[HighlightRule]) -> LegadoResult<()> {
        if rules.is_empty() {
            return Ok(());
        }
        let current = self.find_all()?;
        let merged = merge_imported_highlight_rules(&current, rules)?;
        let current_ids: HashSet<i64> = current.iter().map(|r| r.id).collect();
        let tx_err = |e: rusqlite::Error| LegadoError::Database(format!("事务失败: {e}"));
        let tx = self.conn.unchecked_transaction().map_err(tx_err)?;
        // 同一连接内，未提交事务中的写入对后续语句可见；update/insert 即写在事务里，
        // 最后 commit 原子生效（对齐原版 @Transaction importRules）
        for rule in &merged {
            if rule.id > 0 && current_ids.contains(&rule.id) {
                self.update(rule)?;
            } else {
                self.insert(rule)?;
            }
        }
        tx.commit().map_err(tx_err)?;
        Ok(())
    }

    /// 获取所有高亮规则（对齐 DAO `all`：按 sortOrder 升序）
    pub fn find_all(&self) -> LegadoResult<Vec<HighlightRule>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} ORDER BY sortOrder ASC"))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map([], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 ID 查询高亮规则（对齐 DAO `findById`）
    pub fn find_by_id(&self, id: i64) -> LegadoResult<Option<HighlightRule>> {
        let mut stmt = self
            .conn
            .prepare(&format!("{SELECT_COLUMNS} WHERE id = ?1"))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let mut rows = stmt
            .query_map(params![id], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        match rows.next() {
            Some(Ok(r)) => Ok(Some(r)),
            Some(Err(e)) => Err(LegadoError::Database(format!("查询失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 按书籍查找启用的规则（对齐 DAO `findEnabledByBook`）
    ///
    /// scope 为空/NULL 的规则全局生效；否则 scope 包含书名或书源名时生效。
    pub fn find_enabled_by_book(
        &self,
        name: &str,
        origin: &str,
    ) -> LegadoResult<Vec<HighlightRule>> {
        let mut stmt = self
            .conn
            .prepare(&format!(
                "{SELECT_COLUMNS}
                 WHERE isEnabled = 1
                 AND (scope IS NULL OR scope = ''
                     OR (?1 != '' AND instr(scope, ?1) > 0)
                     OR (?2 != '' AND instr(scope, ?2) > 0))
                 ORDER BY sortOrder ASC"
            ))
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![name, origin], row_to_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取最小 sortOrder（对齐 DAO `minOrder`，无数据时返回 0）
    pub fn min_order(&self) -> LegadoResult<i32> {
        let order: i32 = self
            .conn
            .query_row(
                "SELECT ifnull(min(sortOrder), 0) FROM highlightRules",
                [],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询最小排序值失败: {e}")))?;
        Ok(order)
    }

    /// 获取最大 sortOrder（对齐 DAO `maxOrder`，无数据时返回 0）
    pub fn max_order(&self) -> LegadoResult<i32> {
        let order: i32 = self
            .conn
            .query_row(
                "SELECT ifnull(max(sortOrder), 0) FROM highlightRules",
                [],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询最大排序值失败: {e}")))?;
        Ok(order)
    }

    /// 获取规则总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM highlightRules", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

/// 行数据映射为 HighlightRule（列顺序与 SELECT_COLUMNS 一致）
fn row_to_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<HighlightRule> {
    Ok(HighlightRule {
        id: row.get(0)?,
        uuid: row.get(1)?,
        name: row.get(2)?,
        pattern: row.get(3)?,
        isRegex: row.get(4)?,
        scope: row.get(5)?,
        isEnabled: row.get(6)?,
        style: row.get(7)?,
        sortOrder: row.get(8)?,
        timeoutMillisecond: row.get(9)?,
        applyToTitle: row.get(10)?,
        applyToBody: row.get(11)?,
    })
}

/// 校验规则集合 uuid 合法且互不重复（对齐原版 `requireUniqueHighlightRuleUuids`）
///
/// 原版（HighlightRuleDao.kt:104-113）：每条 uuid 须可被 `UUID.fromString`
/// 解析且与规范化形式忽略大小写相等；集合内 uuid（lowercase）不得重复。
pub(crate) fn require_unique_highlight_rule_uuids(rules: &[HighlightRule]) -> LegadoResult<()> {
    let mut seen: HashSet<String> = HashSet::with_capacity(rules.len());
    for rule in rules {
        let parsed = uuid::Uuid::parse_str(&rule.uuid).map_err(|_| {
            LegadoError::Parser(format!(
                "高亮规则 uuid 非法（须为合法 UUID）: {}",
                rule.uuid
            ))
        })?;
        if !parsed.to_string().eq_ignore_ascii_case(&rule.uuid) {
            return Err(LegadoError::Parser(format!(
                "高亮规则 uuid 与规范化形式不一致: {}",
                rule.uuid
            )));
        }
        if !seen.insert(rule.uuid.to_lowercase()) {
            return Err(LegadoError::Parser(format!(
                "高亮规则 uuid 在集合内重复: {}",
                rule.uuid
            )));
        }
    }
    Ok(())
}

/// 按 uuid 合并导入规则（对齐原版 `mergeImportedHighlightRules`）
///
/// 1. 两侧集合先过 uuid 唯一性校验；
/// 2. uuid（忽略大小写）匹配的本地规则保留本地 id、内容取导入项；
/// 3. uuid 为新的导入项 id 归零（自增插入）；
/// 4. 合并结果（existing + added）按顺序重排 sortOrder = 0..n。
pub(crate) fn merge_imported_highlight_rules(
    current: &[HighlightRule],
    imported: &[HighlightRule],
) -> LegadoResult<Vec<HighlightRule>> {
    require_unique_highlight_rule_uuids(current)?;
    require_unique_highlight_rule_uuids(imported)?;
    let imported_by_uuid: HashMap<String, &HighlightRule> = imported
        .iter()
        .map(|r| (r.uuid.to_lowercase(), r))
        .collect();
    let current_uuids: HashSet<String> = current.iter().map(|r| r.uuid.to_lowercase()).collect();

    let mut merged: Vec<HighlightRule> = Vec::with_capacity(current.len() + imported.len());
    // existing：uuid 匹配导入项时以导入内容替换（保留本地 id），否则原样保留
    for local in current {
        match imported_by_uuid.get(&local.uuid.to_lowercase()) {
            Some(incoming) => {
                let mut rule = (*incoming).clone();
                rule.id = local.id;
                merged.push(rule);
            }
            None => merged.push(local.clone()),
        }
    }
    // added：uuid 未命中的导入项 id 归零（对齐 copy(id = 0L)）
    for incoming in imported {
        if !current_uuids.contains(&incoming.uuid.to_lowercase()) {
            let mut rule = incoming.clone();
            rule.id = 0;
            merged.push(rule);
        }
    }
    // order 重排为连续索引（对齐 mapIndexed { index, rule -> rule.copy(order = index) }）
    for (index, rule) in merged.iter_mut().enumerate() {
        rule.sortOrder = index as i32;
    }
    Ok(merged)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_rule(name: &str, pattern: &str, order: i32) -> HighlightRule {
        HighlightRule {
            name: name.to_string(),
            pattern: pattern.to_string(),
            sortOrder: order,
            ..HighlightRule::default()
        }
    }

    #[test]
    fn test_insert_autoincrement_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule("规则1", "abc", 2)).unwrap();
        let id2 = repo.insert(&make_rule("规则2", "def", 1)).unwrap();
        assert!(id1 > 0);
        assert!(id2 > id1);
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        // 按 sortOrder 升序
        assert_eq!(all[0].name, "规则2");
    }

    #[test]
    fn test_insert_with_explicit_id_replaces() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let mut rule = make_rule("规则1", "abc", 0);
        let id = repo.insert(&rule).unwrap();
        rule.id = id;
        rule.name = "更新后".to_string();
        repo.insert(&rule).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        let found = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(found.name, "更新后");
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let id = repo.insert(&make_rule("规则1", "abc", 0)).unwrap();
        let mut rule = repo.find_by_id(id).unwrap().unwrap();
        rule.pattern = "新匹配".to_string();
        repo.update(&rule).unwrap();
        let found = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(found.pattern, "新匹配");
    }

    #[test]
    fn test_delete_and_delete_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule("r1", "a", 0)).unwrap();
        let _id2 = repo.insert(&make_rule("r2", "b", 1)).unwrap();
        assert!(repo.delete(id1).unwrap());
        assert!(!repo.delete(999).unwrap());
        assert_eq!(repo.count().unwrap(), 1);
        repo.delete_all().unwrap();
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_find_enabled_by_book() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        // 全局规则（scope 为空）
        repo.insert(&make_rule("全局", "g", 0)).unwrap();
        // 特定书籍规则
        let mut scoped = make_rule("书籍规则", "s", 1);
        scoped.scope = Some("书名A".to_string());
        repo.insert(&scoped).unwrap();
        // 禁用的全局规则
        let mut disabled = make_rule("禁用", "d", 2);
        disabled.isEnabled = false;
        repo.insert(&disabled).unwrap();

        let matched = repo.find_enabled_by_book("书名A", "").unwrap();
        assert_eq!(matched.len(), 2);
        let names: Vec<&str> = matched.iter().map(|r| r.name.as_str()).collect();
        assert!(names.contains(&"全局"));
        assert!(names.contains(&"书籍规则"));

        // 其他书籍只匹配全局规则
        let matched = repo.find_enabled_by_book("书名B", "").unwrap();
        assert_eq!(matched.len(), 1);
        assert_eq!(matched[0].name, "全局");
    }

    #[test]
    fn test_min_max_order() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        assert_eq!(repo.min_order().unwrap(), 0);
        assert_eq!(repo.max_order().unwrap(), 0);
        repo.insert(&make_rule("r1", "a", -5)).unwrap();
        repo.insert(&make_rule("r2", "b", 10)).unwrap();
        assert_eq!(repo.min_order().unwrap(), -5);
        assert_eq!(repo.max_order().unwrap(), 10);
    }

    #[test]
    fn test_replace_all_reassigns_ids_and_reorders() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        repo.insert(&make_rule("旧规则", "old", 0)).unwrap();

        // 传入 id=5/6 会被丢弃（对齐原版 replaceAll 的 copy(id = 0L) 语义），
        // 全部重新自增；sortOrder 重排为 0..n
        let mut r1 = make_rule("新规则1", "n1", 9);
        r1.id = 5;
        let mut r2 = make_rule("新规则2", "n2", 3);
        r2.id = 6;
        repo.replace_all(&[r1, r2]).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        assert_ne!(all[0].id, 5, "原版 replaceAll 丢弃传入 id 重新自增");
        assert_eq!(all[0].name, "新规则1");
        assert_eq!(all[0].sortOrder, 0, "sortOrder 重排为 0..n");
        assert_eq!(all[1].sortOrder, 1);
    }

    /// [P2-11] uuid/applyToBody 两列读写往返
    #[test]
    fn test_uuid_and_apply_to_body_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let mut rule = make_rule("身份规则", "p", 0);
        rule.uuid = "0b946e46-a08b-4c41-bc61-0c57c31c93f8".to_string();
        rule.applyToTitle = true;
        rule.applyToBody = false; // 仅标题
        let id = repo.insert(&rule).unwrap();

        let found = repo.find_by_id(id).unwrap().unwrap();
        assert_eq!(found.uuid, "0b946e46-a08b-4c41-bc61-0c57c31c93f8");
        assert!(found.applyToTitle);
        assert!(!found.applyToBody, "applyToBody 应落库并可读回");

        // update 通道同样覆盖两列
        let mut updated = found;
        updated.applyToTitle = false;
        updated.applyToBody = true; // 改为仅正文
        repo.update(&updated).unwrap();
        let found = repo.find_by_id(id).unwrap().unwrap();
        assert!(!found.applyToTitle);
        assert!(found.applyToBody);
    }

    /// [P2-11] 双开关四态持久化（仅标题/仅正文/都开/都关）：
    /// 防转换层 false/None 硬编码兜底复发（防复发规定 3），四态均须无损落库
    #[test]
    fn test_apply_flags_four_states_persist() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let states = [
            (true, false, "仅标题"),
            (false, true, "仅正文"),
            (true, true, "都开"),
            (false, false, "都关"),
        ];
        for (title, body, label) in states {
            let mut rule = make_rule(label, "p", 0);
            rule.uuid = uuid::Uuid::new_v4().to_string();
            rule.applyToTitle = title;
            rule.applyToBody = body;
            let id = repo.insert(&rule).unwrap();
            let found = repo.find_by_id(id).unwrap().unwrap();
            assert_eq!(
                (found.applyToTitle, found.applyToBody),
                (title, body),
                "{label} 落库往返应无损"
            );
        }
    }

    /// [P2-11] uuid 唯一索引：同 uuid 第二条插入被拒绝
    #[test]
    fn test_duplicate_uuid_rejected() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let mut rule = make_rule("r1", "a", 0);
        rule.uuid = "dup-uuid-value".to_string();
        repo.insert(&rule).unwrap();
        let mut rule2 = make_rule("r2", "b", 1);
        rule2.uuid = "dup-uuid-value".to_string();
        assert!(repo.insert(&rule2).is_err(), "uuid 唯一索引应拒绝重复 uuid");
    }

    /// [P2-11] import_rules：uuid 相同 → 本地保留 id 更新内容；uuid 新增 → 插入；
    /// 合并后 sortOrder 重排为 0..n（对齐原版 mergeImportedHighlightRules）
    #[test]
    fn test_import_rules_merges_by_uuid() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        let mut existing = make_rule("本地规则", "old", 0);
        existing.uuid = "11111111-1111-4111-8111-111111111111".to_string();
        let existing_id = repo.insert(&existing).unwrap();

        // 导入项 1：同 uuid，内容更新（大小写不同也应按同一身份合并）
        let mut incoming1 = make_rule("本地规则-更新", "new", 99);
        incoming1.uuid = "11111111-1111-4111-8111-111111111111".to_uppercase();
        // 导入项 2：新 uuid，应插入
        let mut incoming2 = make_rule("新增规则", "n2", 1);
        incoming2.uuid = "22222222-2222-4222-8222-222222222222".to_string();

        repo.import_rules(&[incoming1, incoming2.clone()]).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2, "同 uuid 合并后应为 2 条");
        let merged = all.iter().find(|r| r.uuid == existing.uuid).unwrap();
        assert_eq!(merged.id, existing_id, "同 uuid 保留本地 id");
        assert_eq!(merged.name, "本地规则-更新", "内容以导入项替换");
        assert_eq!(merged.pattern, "new");
        // order 重排为 0..n
        assert_eq!(all[0].sortOrder, 0);
        assert_eq!(all[1].sortOrder, 1);

        // 重复导入同一批：幂等（uuid 命中 → 内容更新不重复插入）
        repo.import_rules(&[incoming2.clone()]).unwrap();
        assert_eq!(repo.count().unwrap(), 2, "重复导入不应产生重复行");
    }

    /// [P2-11] import_rules：导入集合 uuid 非法或重复时报错（对齐原版 require 校验）
    #[test]
    fn test_import_rules_rejects_invalid_or_duplicate_uuids() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());

        let mut invalid = make_rule("非法", "p", 0);
        invalid.uuid = "not-a-uuid".to_string();
        assert!(repo.import_rules(&[invalid]).is_err(), "非法 uuid 应报错");

        let mut d1 = make_rule("d1", "p", 0);
        d1.uuid = "33333333-3333-4333-8333-333333333333".to_string();
        let mut d2 = make_rule("d2", "p", 1);
        d2.uuid = d1.uuid.clone();
        assert!(
            repo.import_rules(&[d1, d2]).is_err(),
            "导入集合内重复 uuid 应报错"
        );
    }
}
