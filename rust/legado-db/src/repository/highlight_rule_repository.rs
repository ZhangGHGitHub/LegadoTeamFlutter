//! HighlightRule Repository — highlightRules 表数据访问层
//!
//! 对齐 Android 原版 `HighlightRuleDao` 方法清单：
//! all / findById / findEnabledByBook / minOrder / maxOrder /
//! insert / update / delete / deleteAll / replaceAll。

use rusqlite::{params, Connection};

use legado_core::models::HighlightRule;
use legado_core::{LegadoError, LegadoResult};

/// 高亮规则查询列（与 row_to_rule 的索引一一对应）
const SELECT_COLUMNS: &str = "SELECT id, name, pattern, isRegex, scope, isEnabled,
    style, sortOrder, timeoutMillisecond, applyToTitle FROM highlightRules";

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
                     (id, name, pattern, isRegex, scope, isEnabled, style,
                      sortOrder, timeoutMillisecond, applyToTitle)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                    params![
                        rule.id,
                        rule.name,
                        rule.pattern,
                        rule.isRegex,
                        rule.scope,
                        rule.isEnabled,
                        rule.style,
                        rule.sortOrder,
                        rule.timeoutMillisecond,
                        rule.applyToTitle,
                    ],
                )
                .map_err(|e| LegadoError::Database(format!("插入高亮规则失败: {e}")))?;
            Ok(rule.id)
        } else {
            self.conn
                .execute(
                    "INSERT INTO highlightRules
                     (name, pattern, isRegex, scope, isEnabled, style,
                      sortOrder, timeoutMillisecond, applyToTitle)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                    params![
                        rule.name,
                        rule.pattern,
                        rule.isRegex,
                        rule.scope,
                        rule.isEnabled,
                        rule.style,
                        rule.sortOrder,
                        rule.timeoutMillisecond,
                        rule.applyToTitle,
                    ],
                )
                .map_err(|e| LegadoError::Database(format!("插入高亮规则失败: {e}")))?;
            Ok(self.conn.last_insert_rowid() as i64)
        }
    }

    /// 更新高亮规则（对齐 DAO `@Update`）
    pub fn update(&self, rule: &HighlightRule) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE highlightRules SET name=?1, pattern=?2, isRegex=?3, scope=?4,
                 isEnabled=?5, style=?6, sortOrder=?7, timeoutMillisecond=?8, applyToTitle=?9
                 WHERE id=?10",
                params![
                    rule.name,
                    rule.pattern,
                    rule.isRegex,
                    rule.scope,
                    rule.isEnabled,
                    rule.style,
                    rule.sortOrder,
                    rule.timeoutMillisecond,
                    rule.applyToTitle,
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

    /// 全量替换规则（对齐 DAO `replaceAll`：先清空再批量插入）
    pub fn replace_all(&self, rules: &[HighlightRule]) -> LegadoResult<()> {
        let tx_err = |e: rusqlite::Error| LegadoError::Database(format!("事务失败: {e}"));
        let tx = self.conn.unchecked_transaction().map_err(tx_err)?;
        tx.execute("DELETE FROM highlightRules", [])
            .map_err(|e| LegadoError::Database(format!("清空高亮规则失败: {e}")))?;
        for rule in rules {
            // id <= 0 时传 NULL，SQLite 自动分配自增 ID（对齐 Room autoGenerate）
            let id: Option<i64> = if rule.id > 0 { Some(rule.id) } else { None };
            tx.execute(
                "INSERT OR REPLACE INTO highlightRules
                 (id, name, pattern, isRegex, scope, isEnabled, style,
                  sortOrder, timeoutMillisecond, applyToTitle)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)",
                params![
                    id,
                    rule.name,
                    rule.pattern,
                    rule.isRegex,
                    rule.scope,
                    rule.isEnabled,
                    rule.style,
                    rule.sortOrder,
                    rule.timeoutMillisecond,
                    rule.applyToTitle,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("批量插入高亮规则失败: {e}")))?;
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
    pub fn find_enabled_by_book(&self, name: &str, origin: &str) -> LegadoResult<Vec<HighlightRule>> {
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
        name: row.get(1)?,
        pattern: row.get(2)?,
        isRegex: row.get(3)?,
        scope: row.get(4)?,
        isEnabled: row.get(5)?,
        style: row.get(6)?,
        sortOrder: row.get(7)?,
        timeoutMillisecond: row.get(8)?,
        applyToTitle: row.get(9)?,
    })
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
    fn test_replace_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = HighlightRuleRepository::new(db.connection());
        repo.insert(&make_rule("旧规则", "old", 0)).unwrap();

        let new_rules = vec![
            make_rule("新规则1", "n1", 0),
            make_rule("新规则2", "n2", 1),
        ];
        repo.replace_all(&new_rules).unwrap();
        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
        assert!(all.iter().all(|r| r.name.starts_with("新规则")));
    }
}
