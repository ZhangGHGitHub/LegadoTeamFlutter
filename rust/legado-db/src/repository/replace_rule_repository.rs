//! ReplaceRule Repository - replace_rules 表 CRUD + 规则应用

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
                  excludeScope, isEnabled, isRegex, timeoutMillisecond, sortOrder)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
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
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入替换规则失败: {e}")))?;
        Ok(self.conn.last_insert_rowid())
    }

    /// 更新替换规则
    pub fn update(&self, rule: &ReplaceRule) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE replace_rules SET name=?1, \"group\"=?2, pattern=?3, replacement=?4,
                 scope=?5, scopeTitle=?6, scopeContent=?7, excludeScope=?8, isEnabled=?9,
                 isRegex=?10, timeoutMillisecond=?11, sortOrder=?12
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
                    rule.order,
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
                        scopeContent, excludeScope, isEnabled, isRegex, timeoutMillisecond, sortOrder
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
                        scopeContent, excludeScope, isEnabled, isRegex, timeoutMillisecond, sortOrder
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
                        scopeContent, excludeScope, isEnabled, isRegex, timeoutMillisecond, sortOrder
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
}
