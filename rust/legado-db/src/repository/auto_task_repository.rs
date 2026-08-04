//! AutoTask Repository - auto_task_rules 表 CRUD

use rusqlite::{params, Connection};

use legado_core::models::AutoTaskRule;
use legado_core::{LegadoError, LegadoResult};

use super::Repository;

/// 自动任务规则数据访问层
pub struct AutoTaskRepository<'a> {
    conn: &'a Connection,
}

impl<'a> AutoTaskRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 根据 ID 查询自动任务规则
    pub fn find_by_id(&self, id: &str) -> LegadoResult<Option<AutoTaskRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, enable, cron, loginUrl, loginUi, loginCheckJs,
                        comment, script, header, jsLib, concurrentRate,
                        enabledCookieJar, customOrder, lastRunAt,
                        lastResult, lastError, lastLog
                 FROM auto_task_rules WHERE id = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let mut rows = stmt
            .query_map(params![id], row_to_auto_task_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;

        match rows.next() {
            Some(Ok(rule)) => Ok(Some(rule)),
            Some(Err(e)) => Err(LegadoError::Database(format!("行解析失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 批量更新 cron 表达式（上游新增功能）
    ///
    /// 分批处理（每批 900 条）以避免 SQLite 参数数量限制。
    pub fn update_cron_batch(&self, ids: &[String], cron: &str) -> LegadoResult<usize> {
        if ids.is_empty() {
            return Ok(0);
        }

        let mut total_affected = 0usize;

        // SQLite 默认最大变量数 999，每批使用 900 个 ID 参数 + 1 个 cron 参数
        for chunk in ids.chunks(900) {
            let placeholders: Vec<String> = chunk
                .iter()
                .enumerate()
                .map(|(i, _)| format!("?{}", i + 2))
                .collect();
            let sql = format!(
                "UPDATE auto_task_rules SET cron = ?1 WHERE id IN ({})",
                placeholders.join(", ")
            );

            let mut stmt = self
                .conn
                .prepare(&sql)
                .map_err(|e| LegadoError::Database(format!("准备批量更新失败: {e}")))?;

            let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
            param_values.push(Box::new(cron.to_string()));
            for id in chunk {
                param_values.push(Box::new(id.clone()));
            }

            let param_refs: Vec<&dyn rusqlite::types::ToSql> =
                param_values.iter().map(|b| b.as_ref()).collect();

            let affected = stmt
                .execute(param_refs.as_slice())
                .map_err(|e| LegadoError::Database(format!("批量更新 cron 失败: {e}")))?;

            total_affected += affected;
        }

        Ok(total_affected)
    }

    /// 批量启用/禁用自动任务规则（对齐上游 `AutoTaskRuleDao.updateEnabled`）
    ///
    /// 上游签名 `updateEnabled(ids: Collection<String>, enabled: Boolean): Int`；
    /// id 为 TEXT 主键（上游为 String），返回受影响行数。
    /// 同样分批处理（每批 900 条）以避免 SQLite 参数数量限制。
    pub fn update_enabled(&self, ids: &[String], enabled: bool) -> LegadoResult<usize> {
        if ids.is_empty() {
            return Ok(0);
        }

        let mut total_affected = 0usize;

        for chunk in ids.chunks(900) {
            let placeholders: Vec<String> = chunk
                .iter()
                .enumerate()
                .map(|(i, _)| format!("?{}", i + 2))
                .collect();
            let sql = format!(
                "UPDATE auto_task_rules SET enable = ?1 WHERE id IN ({})",
                placeholders.join(", ")
            );

            let mut stmt = self
                .conn
                .prepare(&sql)
                .map_err(|e| LegadoError::Database(format!("准备批量更新失败: {e}")))?;

            let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
            param_values.push(Box::new(enabled));
            for id in chunk {
                param_values.push(Box::new(id.clone()));
            }

            let param_refs: Vec<&dyn rusqlite::types::ToSql> =
                param_values.iter().map(|b| b.as_ref()).collect();

            let affected = stmt
                .execute(param_refs.as_slice())
                .map_err(|e| LegadoError::Database(format!("批量更新 enable 失败: {e}")))?;

            total_affected += affected;
        }

        Ok(total_affected)
    }

    /// 清空指定规则的运行日志字段（对齐上游 `AutoTaskRuleDao.clearRunLog`）
    ///
    /// 将 lastResult/lastError/lastLog 置为 NULL（不动 lastRunAt），返回受影响行数。
    pub fn clear_run_log(&self, id: &str) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute(
                "UPDATE auto_task_rules
                 SET lastResult = NULL,
                     lastError = NULL,
                     lastLog = NULL
                 WHERE id = ?1",
                params![id],
            )
            .map_err(|e| LegadoError::Database(format!("清空运行日志失败: {e}")))?;
        Ok(affected)
    }
}

impl<'a> Repository<AutoTaskRule> for AutoTaskRepository<'a> {
    fn find_all(&self) -> LegadoResult<Vec<AutoTaskRule>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT id, name, enable, cron, loginUrl, loginUi, loginCheckJs,
                        comment, script, header, jsLib, concurrentRate,
                        enabledCookieJar, customOrder, lastRunAt,
                        lastResult, lastError, lastLog
                 FROM auto_task_rules ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rules = stmt
            .query_map([], row_to_auto_task_rule)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rules)
    }

    fn insert(&self, item: &AutoTaskRule) -> LegadoResult<()> {
        self.conn
            .execute(
                "INSERT OR REPLACE INTO auto_task_rules
                 (id, name, enable, cron, loginUrl, loginUi, loginCheckJs,
                  comment, script, header, jsLib, concurrentRate,
                  enabledCookieJar, customOrder, lastRunAt,
                  lastResult, lastError, lastLog)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)",
                params![
                    item.id,
                    item.name,
                    item.enable,
                    item.cron,
                    item.login_url,
                    item.login_ui,
                    item.login_check_js,
                    item.comment,
                    item.script,
                    item.header,
                    item.js_lib,
                    item.concurrent_rate,
                    item.enabled_cookie_jar,
                    item.custom_order,
                    item.last_run_at,
                    item.last_result,
                    item.last_error,
                    item.last_log,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入失败: {e}")))?;
        Ok(())
    }

    fn update(&self, item: &AutoTaskRule) -> LegadoResult<()> {
        self.insert(item)
    }

    fn delete(&self, id: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM auto_task_rules WHERE id = ?1", params![id])
            .map_err(|e| LegadoError::Database(format!("删除失败: {e}")))?;
        Ok(())
    }
}

fn row_to_auto_task_rule(row: &rusqlite::Row<'_>) -> rusqlite::Result<AutoTaskRule> {
    Ok(AutoTaskRule {
        id: row.get(0)?,
        name: row.get(1)?,
        enable: row.get::<_, bool>(2)?,
        cron: row.get(3)?,
        login_url: row.get(4)?,
        login_ui: row.get(5)?,
        login_check_js: row.get(6)?,
        comment: row.get(7)?,
        script: row.get::<_, String>(8)?,
        header: row.get(9)?,
        js_lib: row.get(10)?,
        concurrent_rate: row.get(11)?,
        enabled_cookie_jar: row.get::<_, bool>(12)?,
        custom_order: row.get(13)?,
        last_run_at: row.get(14)?,
        last_result: row.get(15)?,
        last_error: row.get(16)?,
        last_log: row.get(17)?,
    })
}

#[cfg(test)]
mod tests {
    use super::super::Repository;
    use super::*;

    fn make_task(id: &str, name: &str) -> AutoTaskRule {
        AutoTaskRule {
            id: id.to_string(),
            name: name.to_string(),
            ..AutoTaskRule::default()
        }
    }

    #[test]
    fn test_insert_and_find_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        repo.insert(&make_task("1", "task1")).unwrap();
        repo.insert(&make_task("2", "task2")).unwrap();

        let all = repo.find_all().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_find_by_id() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        repo.insert(&make_task("t1", "my_task")).unwrap();

        let found = repo.find_by_id("t1").unwrap().unwrap();
        assert_eq!(found.name, "my_task");
    }

    #[test]
    fn test_find_by_id_not_found() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        let found = repo.find_by_id("nonexistent").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn test_delete() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        repo.insert(&make_task("1", "task1")).unwrap();
        repo.delete("1").unwrap();

        let all = repo.find_all().unwrap();
        assert!(all.is_empty());
    }

    #[test]
    fn test_update() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        let mut task = make_task("1", "original");
        repo.insert(&task).unwrap();

        task.name = "updated".to_string();
        repo.update(&task).unwrap();

        let found = repo.find_by_id("1").unwrap().unwrap();
        assert_eq!(found.name, "updated");
    }

    #[test]
    fn test_update_cron_batch() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        repo.insert(&make_task("1", "t1")).unwrap();
        repo.insert(&make_task("2", "t2")).unwrap();
        repo.insert(&make_task("3", "t3")).unwrap();

        let ids = vec!["1".to_string(), "2".to_string()];
        let affected = repo.update_cron_batch(&ids, "0 * * * *").unwrap();
        assert_eq!(affected, 2);

        let t1 = repo.find_by_id("1").unwrap().unwrap();
        assert_eq!(t1.cron, Some("0 * * * *".to_string()));

        let t3 = repo.find_by_id("3").unwrap().unwrap();
        // t3 should still have the default cron
        assert_eq!(t3.cron, Some("*/30 * * * *".to_string()));
    }

    /// 批量启用/禁用：仅命中传入的 id，返回受影响行数
    #[test]
    fn test_update_enabled() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        let mut t1 = make_task("1", "t1");
        t1.enable = true;
        let mut t2 = make_task("2", "t2");
        t2.enable = true;
        let mut t3 = make_task("3", "t3");
        t3.enable = true;
        repo.insert(&t1).unwrap();
        repo.insert(&t2).unwrap();
        repo.insert(&t3).unwrap();

        let ids = vec!["1".to_string(), "2".to_string()];
        let affected = repo.update_enabled(&ids, false).unwrap();
        assert_eq!(affected, 2);

        assert!(!repo.find_by_id("1").unwrap().unwrap().enable);
        assert!(!repo.find_by_id("2").unwrap().unwrap().enable);
        // t3 未被传入，保持启用
        assert!(repo.find_by_id("3").unwrap().unwrap().enable);

        // 再次启用
        let affected = repo.update_enabled(&ids, true).unwrap();
        assert_eq!(affected, 2);
        assert!(repo.find_by_id("1").unwrap().unwrap().enable);
    }

    /// 空 ids 列表直接返回 0，不执行 SQL
    #[test]
    fn test_update_enabled_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());
        repo.insert(&make_task("1", "t1")).unwrap();
        assert_eq!(repo.update_enabled(&[], false).unwrap(), 0);
        assert!(repo.find_by_id("1").unwrap().unwrap().enable);
    }

    /// 清空运行日志：lastResult/lastError/lastLog 置 NULL，lastRunAt 保留
    #[test]
    fn test_clear_run_log() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());

        let mut task = make_task("1", "t1");
        task.last_run_at = 12345;
        task.last_result = Some("成功".to_string());
        task.last_error = Some("错误信息".to_string());
        task.last_log = Some("日志内容".to_string());
        repo.insert(&task).unwrap();

        let affected = repo.clear_run_log("1").unwrap();
        assert_eq!(affected, 1);

        let found = repo.find_by_id("1").unwrap().unwrap();
        assert_eq!(found.last_result, None);
        assert_eq!(found.last_error, None);
        assert_eq!(found.last_log, None);
        assert_eq!(found.last_run_at, 12345);
    }

    /// 不存在的 id 返回 0
    #[test]
    fn test_clear_run_log_not_found() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = AutoTaskRepository::new(db.connection());
        assert_eq!(repo.clear_run_log("nonexistent").unwrap(), 0);
    }
}
