//! ReplaceRule Repository - replace_rules 表 CRUD + 规则应用

use std::collections::HashSet;

use rusqlite::{params, Connection};

use legado_core::models::ReplaceRule;
use legado_core::{LegadoError, LegadoResult};

/// 替换规则数据访问层
pub struct ReplaceRuleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> ReplaceRuleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入替换规则，返回新插入行的 id
    pub fn insert(&self, rule: &ReplaceRule) -> LegadoResult<i64> {
        self.conn
            .execute(
                "INSERT INTO replace_rules
                 (name, \"group\", pattern, replacement, scope, scopeTitle, scopeContent,
                  excludeScope, isEnabled, isRegex, timeoutMillisecond, sortOrder,
                  scopeSource)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
                params![
                    rule.name,
                    rule.group,
                    rule.pattern,
                    rule.replacement,
                    rule.scope,
                    rule.scope_title,
                    rule.scope_content,
                    rule.exclude_scope,
                    rule.is_enabled,
                    rule.is_regex,
                    rule.timeout_millisecond,
                    rule.order,
                    rule.scope_source,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入替换规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 更新替换规则（**不写 `sortOrder`**，排序只经 [`Self::reorder`] 变更）
    ///
    /// 批12 P2：update 是「读-改-写」路径，调用方持有的 `rule.order` 可能是
    /// 排序前的旧快照；若一并写回会与 `reorder`（或 Web `/saveReplaceRule`）
    /// 交错，把新排序覆盖回旧值。故 SQL 不含 `sortOrder`，列值保持不变。
    pub fn update(&self, rule: &ReplaceRule) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE replace_rules SET name=?1, \"group\"=?2, pattern=?3, replacement=?4,
                 scope=?5, scopeTitle=?6, scopeContent=?7, excludeScope=?8, isEnabled=?9,
                 isRegex=?10, timeoutMillisecond=?11, scopeSource=?12
                 WHERE id=?13",
                params![
                    rule.name,
                    rule.group,
                    rule.pattern,
                    rule.replacement,
                    rule.scope,
                    rule.scope_title,
                    rule.scope_content,
                    rule.exclude_scope,
                    rule.is_enabled,
                    rule.is_regex,
                    rule.timeout_millisecond,
                    rule.scope_source,
                    rule.id,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新替换规则失败: {e}")))?;
        Ok(())
    }

    /// 按 id 删除替换规则
    pub fn delete(&self, id: i64) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM replace_rules WHERE id=?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除替换规则失败: {e}")))?;
        Ok(())
    }

    /// 获取所有替换规则
    pub fn find_all(&self) -> LegadoResult<Vec<ReplaceRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, \"group\", pattern, replacement, scope, scopeTitle,
                        scopeContent, excludeScope, isEnabled, isRegex, timeoutMillisecond,
                        sortOrder, scopeSource
                 FROM replace_rules ORDER BY sortOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_replace_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 获取所有启用的替换规则
    pub fn get_enabled_rules(&self) -> LegadoResult<Vec<ReplaceRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, \"group\", pattern, replacement, scope, scopeTitle,
                        scopeContent, excludeScope, isEnabled, isRegex, timeoutMillisecond,
                        sortOrder, scopeSource
                 FROM replace_rules WHERE isEnabled = 1
                 ORDER BY sortOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map([], row_to_replace_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 scope 获取替换规则
    pub fn get_by_scope(&self, scope: &str) -> LegadoResult<Vec<ReplaceRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, \"group\", pattern, replacement, scope, scopeTitle,
                        scopeContent, excludeScope, isEnabled, isRegex, timeoutMillisecond,
                        sortOrder, scopeSource
                 FROM replace_rules WHERE scope = ?1
                 ORDER BY sortOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![scope], row_to_replace_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 启用/禁用替换规则
    pub fn set_enabled(&self, id: i64, enabled: bool) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE replace_rules SET isEnabled=?1 WHERE id=?2",
                params![enabled, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新启用状态失败: {e}")))?;
        Ok(())
    }

    /// 下一个可用排序值（`max(sortOrder) + 1`，空表为 0）
    ///
    /// 供新增规则追加到列表末尾（契约 §2.8 批12：原实现硬编码 0，
    /// 重排后新规则会顶到最前）。
    pub fn next_order(&self) -> LegadoResult<i32> {
        let next: i32 = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM replace_rules",
                [],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询替换规则排序值失败: {e}")))?;
        Ok(next)
    }

    /// 按给定 ID 顺序全量重编号 `sortOrder`（0..n-1），返回重排条数
    ///
    /// 契约 §2.8 `reorderReplaceRules`（批12）：`ids` 必须是当前库中全部
    /// 规则 id 的一个排列——重复 id / 未知 id / 缺失 id 一律返回参数错误且
    /// **零写入**（防止筛选态只提交子集而打乱未展示规则的顺序）；空数组
    /// 返回 0 且不开启事务；合法集在单事务内逐行写 `sortOrder = 序号`。
    pub fn reorder(&self, ids: &[i64]) -> LegadoResult<i32> {
        if ids.is_empty() {
            return Ok(0);
        }

        let mut seen = HashSet::with_capacity(ids.len());
        for id in ids {
            if !seen.insert(*id) {
                return Err(LegadoError::Database(format!(
                    "重排替换规则参数错误: 重复 id {id}"
                )));
            }
        }

        let existing: HashSet<i64> = {
            let mut stmt = self
                .conn
                .prepare("SELECT id FROM replace_rules")
                .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
            let rows: HashSet<i64> = stmt
                .query_map([], |row| row.get::<_, i64>(0))
                .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
                .filter_map(|r| r.ok())
                .collect();
            rows
        };

        if let Some(unknown) = ids.iter().find(|id| !existing.contains(id)) {
            return Err(LegadoError::Database(format!(
                "重排替换规则参数错误: 未知 id {unknown}"
            )));
        }
        if existing.len() != ids.len() {
            let mut missing: Vec<i64> = existing
                .iter()
                .copied()
                .filter(|id| !seen.contains(id))
                .collect();
            missing.sort_unstable();
            return Err(LegadoError::Database(format!(
                "重排替换规则参数错误: 缺失 id {missing:?}"
            )));
        }

        let tx = self
            .conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启事务失败: {e}")))?;

        for (idx, id) in ids.iter().enumerate() {
            self.conn
                .execute(
                    "UPDATE replace_rules SET sortOrder = ?1 WHERE id = ?2",
                    params![idx as i32, id],
                )
                .map_err(|e| LegadoError::Database(format!("重排替换规则失败: {e}")))?;
        }

        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交事务失败: {e}")))?;
        Ok(ids.len() as i32)
    }

    /// 对文本应用匹配的替换规则
    ///
    /// `book_name` 用于过滤 scope 相关的规则，传入书籍名称以便匹配 book 范围的规则。
    pub fn apply_rules(&self, text: &str, book_name: &str) -> LegadoResult<String> {
        let rules = self.get_enabled_rules()?;
        let mut result = text.to_string();

        for rule in &rules {
            // 检查 scope 匹配：scope 为空或 "global" 时全局生效
            // scope 包含书籍名称时对特定书籍生效
            if let Some(scope) = &rule.scope {
                if !scope.is_empty() && scope != "global" && !scope.contains(book_name) {
                    continue;
                }
            }

            if rule.pattern.is_empty() {
                continue;
            }

            if rule.is_regex {
                // 正则替换：统一安全入口（1KB 上限 + nest_limit + 全局缓存/负缓存）
                match legado_core::regex_safe::compile_regex_safe(&rule.pattern) {
                    Some(re) => {
                        result = re
                            .replace_all(&result, rule.replacement.as_str())
                            .to_string();
                    }
                    None => {
                        // 正则表达式无效/超限，跳过此规则（对齐原版降级语义）
                        continue;
                    }
                }
            } else {
                // 简单字符串替换
                result = result.replace(&rule.pattern, &rule.replacement);
            }
        }

        Ok(result)
    }

    /// 获取替换规则总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM replace_rules", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

fn row_to_replace_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<ReplaceRule> {
    Ok(ReplaceRule {
        id: row.get(0)?,
        name: row.get(1)?,
        group: row.get(2)?,
        pattern: row.get(3)?,
        replacement: row.get(4)?,
        scope: row.get(5)?,
        scope_title: row.get(6)?,
        scope_content: row.get(7)?,
        exclude_scope: row.get(8)?,
        is_enabled: row.get(9)?,
        is_regex: row.get(10)?,
        timeout_millisecond: row.get(11)?,
        order: row.get(12)?,
        scope_source: row.get(13)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_rule(name: &str, pattern: &str, replacement: &str, is_regex: bool) -> ReplaceRule {
        ReplaceRule {
            name: name.to_string(),
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            is_regex,
            is_enabled: true,
            ..ReplaceRule::default()
        }
    }

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.insert(&make_rule("r1", "a", "b", false)).unwrap();
        repo.insert(&make_rule("r2", "c", "d", false)).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        assert!(all[0].id > 0);
    }

    #[test]
    fn test_insert_and_update_scope_source() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let mut rule = make_rule("ss", "a", "b", false);
        rule.scope_source = true;
        let id = repo.insert(&rule).unwrap();

        // 写入 scopeSource=true 可读出
        let all = repo.find_all().unwrap();
        assert!(
            all.iter().find(|r| r.id == id).unwrap().scope_source,
            "scopeSource=true 应落库并读出"
        );

        // 未设置 scopeSource 的插入按列默认值 false 读出
        repo.insert(&make_rule("ss2", "c", "d", false)).unwrap();
        let all = repo.find_all().unwrap();
        assert!(
            !all.iter().find(|r| r.name == "ss2").unwrap().scope_source,
            "未指定 scopeSource 应取列默认值 false"
        );

        // 更新可回切
        rule.id = id;
        rule.scope_source = false;
        repo.update(&rule).unwrap();
        let all = repo.find_all().unwrap();
        assert!(
            !all.iter().find(|r| r.id == id).unwrap().scope_source,
            "update 应覆盖 scopeSource"
        );
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let mut rule = make_rule("r1", "a", "b", false);
        let id = repo.insert(&rule).unwrap();
        rule.id = id;
        rule.name = "updated".to_string();
        repo.update(&rule).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all[0].name, "updated");
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id = repo.insert(&make_rule("r1", "a", "b", false)).unwrap();
        assert_eq!(repo.count().unwrap(), 1);
        repo.delete(id).unwrap();
        assert_eq!(repo.count().unwrap(), 0);
    }

    #[test]
    fn test_get_enabled_rules() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let r1 = make_rule("r1", "a", "b", false);
        let mut r2 = make_rule("r2", "c", "d", false);
        r2.is_enabled = false;
        repo.insert(&r1).unwrap();
        repo.insert(&r2).unwrap();
        let enabled = repo.get_enabled_rules().unwrap();
        assert_eq!(enabled.len(), 1);
        assert_eq!(enabled[0].name, "r1");
    }

    #[test]
    fn test_set_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id = repo.insert(&make_rule("r1", "a", "b", false)).unwrap();
        repo.set_enabled(id, false).unwrap();
        let enabled = repo.get_enabled_rules().unwrap();
        assert_eq!(enabled.len(), 0);
        repo.set_enabled(id, true).unwrap();
        let enabled = repo.get_enabled_rules().unwrap();
        assert_eq!(enabled.len(), 1);
    }

    #[test]
    fn test_apply_rules_simple() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.insert(&make_rule("r1", "hello", "hi", false)).unwrap();
        let result = repo.apply_rules("hello world", "").unwrap();
        assert_eq!(result, "hi world");
    }

    #[test]
    fn test_apply_rules_regex() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.insert(&make_rule("r1", r"\d+", "NUM", true)).unwrap();
        let result = repo.apply_rules("abc 123 def 456", "").unwrap();
        assert_eq!(result, "abc NUM def NUM");
    }

    #[test]
    fn test_apply_rules_scope_filter() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let mut rule = make_rule("r1", "a", "X", false);
        rule.scope = Some("特定书籍".to_string());
        repo.insert(&rule).unwrap();

        // 匹配范围
        let result = repo.apply_rules("abc", "特定书籍").unwrap();
        assert_eq!(result, "Xbc");

        // 不匹配范围
        let result = repo.apply_rules("abc", "其他书籍").unwrap();
        assert_eq!(result, "abc");
    }

    #[test]
    fn test_get_by_scope() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let mut r1 = make_rule("r1", "a", "b", false);
        r1.scope = Some("global".to_string());
        let mut r2 = make_rule("r2", "c", "d", false);
        r2.scope = Some("book".to_string());
        repo.insert(&r1).unwrap();
        repo.insert(&r2).unwrap();

        let global = repo.get_by_scope("global").unwrap();
        assert_eq!(global.len(), 1);
        assert_eq!(global[0].name, "r1");
    }

    // ─── 批12：全量重排 / next_order ───

    /// 指定 sortOrder 的规则构造器（重排断言用）
    fn make_rule_at(name: &str, order: i32) -> ReplaceRule {
        ReplaceRule {
            order,
            ..make_rule(name, "a", "b", false)
        }
    }

    /// id → sortOrder 快照（升序，逐条断言「零写入」用）
    fn orders_by_id(repo: &ReplaceRuleRepository<'_>) -> Vec<(i64, i32)> {
        let mut rows: Vec<(i64, i32)> = repo
            .find_all()
            .unwrap()
            .iter()
            .map(|r| (r.id, r.order))
            .collect();
        rows.sort_unstable_by_key(|(id, _)| *id);
        rows
    }

    #[test]
    fn test_reorder_renumbers_full_sequence() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();

        // 乱序重排：返回条数 + find_all 顺序 = 传入顺序、sortOrder = 0..n-1
        assert_eq!(repo.reorder(&[id3, id1, id2]).unwrap(), 3);
        let all = repo.find_all().unwrap();
        assert_eq!(
            all.iter().map(|r| r.id).collect::<Vec<_>>(),
            vec![id3, id1, id2]
        );
        assert_eq!(
            all.iter().map(|r| r.order).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn test_reorder_rejects_duplicate_id_without_writes() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let _id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();
        let before = orders_by_id(&repo);

        let err = repo.reorder(&[id1, id1, id2]).unwrap_err();
        assert!(
            err.to_string().contains("重复 id"),
            "重复 id 应报参数错误，实际: {err}"
        );
        assert_eq!(orders_by_id(&repo), before, "非法集必须零写入");
    }

    #[test]
    fn test_reorder_rejects_unknown_id_without_writes() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();
        let before = orders_by_id(&repo);

        let err = repo.reorder(&[id1, id2, id3, 999_999]).unwrap_err();
        assert!(
            err.to_string().contains("未知 id"),
            "未知 id 应报参数错误，实际: {err}"
        );
        assert_eq!(orders_by_id(&repo), before, "非法集必须零写入");
    }

    #[test]
    fn test_reorder_rejects_missing_id_without_writes() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let _id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();
        let before = orders_by_id(&repo);

        // 缺失 id3：DB 中存在但未出现在数组
        let err = repo.reorder(&[id1, id2]).unwrap_err();
        assert!(
            err.to_string().contains("缺失 id"),
            "缺失 id 应报参数错误，实际: {err}"
        );
        assert_eq!(orders_by_id(&repo), before, "非法集必须零写入");
    }

    #[test]
    fn test_reorder_empty_returns_zero() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.insert(&make_rule_at("r1", 0)).unwrap();
        let before = orders_by_id(&repo);

        assert_eq!(repo.reorder(&[]).unwrap(), 0);
        assert_eq!(orders_by_id(&repo), before, "空数组不应改动任何行");
    }

    #[test]
    fn test_reorder_single_rule() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id = repo.insert(&make_rule_at("only", 7)).unwrap();

        assert_eq!(repo.reorder(&[id]).unwrap(), 1);
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!((all[0].id, all[0].order), (id, 0));
    }

    #[test]
    fn test_reorder_rolls_back_on_mid_transaction_error() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();
        let before = orders_by_id(&repo);

        // 第二行更新即 ABORT：验证第一行写入被事务回滚
        db.connection()
            .execute_batch(&format!(
                "CREATE TRIGGER reorder_fail BEFORE UPDATE OF sortOrder ON replace_rules
                 WHEN NEW.id = {id3}
                 BEGIN SELECT RAISE(ABORT, 'reorder boom'); END;"
            ))
            .unwrap();

        let err = repo.reorder(&[id1, id3, id2]).unwrap_err();
        assert!(
            err.to_string().contains("重排替换规则失败"),
            "触发器 ABORT 应转换为重排错误，实际: {err}"
        );
        assert_eq!(orders_by_id(&repo), before, "事务失败必须整体回滚");
    }

    #[test]
    fn test_reorder_twice_is_idempotent() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();

        let order = [id2, id3, id1];
        assert_eq!(repo.reorder(&order).unwrap(), 3);
        let first = orders_by_id(&repo);
        assert_eq!(repo.reorder(&order).unwrap(), 3);
        assert_eq!(orders_by_id(&repo), first, "连续两次相同重排应幂等");
        assert_eq!(
            repo.find_all()
                .unwrap()
                .iter()
                .map(|r| r.order)
                .collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    /// 批12 P2：update 不写 sortOrder——重排后携带旧 order 快照的整行更新
    /// 不得覆盖新排序
    #[test]
    fn test_update_after_reorder_keeps_sort_order() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();

        repo.reorder(&[id3, id1, id2]).unwrap();
        let before: Vec<(i64, i32)> = repo
            .find_all()
            .unwrap()
            .iter()
            .map(|r| (r.id, r.order))
            .collect();

        // 调用方持有排序前旧快照（order=99），update 后顺序必须保持
        let mut stale = make_rule_at("r1_updated", 99);
        stale.id = id1;
        repo.update(&stale).unwrap();

        let after = repo.find_all().unwrap();
        assert_eq!(
            after.iter().map(|r| (r.id, r.order)).collect::<Vec<_>>(),
            before,
            "update 不得写回 sortOrder（即使传入旧 order 快照）"
        );
        assert_eq!(
            after.iter().find(|r| r.id == id1).unwrap().name,
            "r1_updated",
            "其余字段应正常更新"
        );
    }

    /// 批12 P2：先 update（含旧 order）再 reorder，排序结果仍以 reorder 为准
    #[test]
    fn test_update_then_reorder_applies_new_order() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        let id1 = repo.insert(&make_rule_at("r1", 0)).unwrap();
        let id2 = repo.insert(&make_rule_at("r2", 1)).unwrap();
        let id3 = repo.insert(&make_rule_at("r3", 2)).unwrap();

        let mut stale = make_rule_at("r1_updated", 99);
        stale.id = id1;
        repo.update(&stale).unwrap();

        assert_eq!(repo.reorder(&[id2, id3, id1]).unwrap(), 3);
        let all = repo.find_all().unwrap();
        assert_eq!(
            all.iter().map(|r| r.id).collect::<Vec<_>>(),
            vec![id2, id3, id1]
        );
        assert_eq!(
            all.iter().map(|r| r.order).collect::<Vec<_>>(),
            vec![0, 1, 2]
        );
    }

    #[test]
    fn test_next_order_is_max_plus_one() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = ReplaceRuleRepository::new(db.connection());
        assert_eq!(repo.next_order().unwrap(), 0, "空表下一个排序值为 0");

        repo.insert(&make_rule_at("r1", 0)).unwrap();
        assert_eq!(repo.next_order().unwrap(), 1);
        repo.insert(&make_rule_at("r2", 5)).unwrap();
        assert_eq!(
            repo.next_order().unwrap(),
            6,
            "应取 max(sortOrder)+1（允许重排后存在空洞）"
        );
    }
}
