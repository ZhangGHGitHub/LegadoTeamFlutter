//! 自动任务 FFI API
//!
//! 包装 `legado_core::auto_task` 的自动任务逻辑，通过 JSON 序列化传参，
//! 遵循项目「复杂类型 FFI 用 JSON」决策。
//!
//! 对应 Kotlin 原版 `AutoTask` / `AutoTaskRunner` / `AutoTaskSchedulePolicy`。

use legado_core::auto_task::{
    build_book_update_task as core_build_book_update_task,
    can_refresh_book_toc as core_can_refresh_book_toc,
    find_book_update_task as core_find_book_update_task, normalize_script as core_normalize_script,
    update_cron_batch as core_update_cron_batch, AutoTaskExporter, AutoTaskRule, AutoTaskRunner,
    AutoTaskSchedulePolicy, TaskProtocol,
};
use legado_core::models::AutoTaskRule as AutoTaskRuleModel;
use legado_core::LegadoResult;

use crate::db_state::with_database;
use legado_db::repository::Repository;
use legado_db::AutoTaskRepository;

/// 构建书籍更新定时任务（对应 Kotlin `AutoTask.buildBookUpdateTask`）
///
/// 返回构建好的 `AutoTaskRule`。
pub fn build_book_update_task(
    book_url: &str,
    book_name: &str,
    book_author: &str,
    name: &str,
) -> AutoTaskRule {
    core_build_book_update_task(book_url, book_name, book_author, name)
}

/// 批量更新 cron 表达式（对应 Kotlin `AutoTask.updateCron`）
///
/// - `rules_json`: 现有规则数组（AutoTaskRule JSON 数组）
/// - `ids_json`: 待更新的任务 ID 数组（JSON 字符串数组）
/// - `cron`: 新的 cron 表达式
///
/// 返回更新后的完整规则数组。
pub fn update_cron_batch(
    rules_json: &str,
    ids_json: &str,
    cron: &str,
) -> LegadoResult<Vec<AutoTaskRule>> {
    let mut rules: Vec<AutoTaskRule> = serde_json::from_str(rules_json)?;
    let ids: Vec<String> = serde_json::from_str(ids_json)?;
    core_update_cron_batch(&mut rules, &ids, cron);
    Ok(rules)
}

/// 准备导入任务，合并本地运行时状态（对应 Kotlin `prepareImportedAutoTasks`）
///
/// - `local_tasks_json`: 本地任务数组（AutoTaskRule JSON 数组）
/// - `imported_json`: 导入数据（JSON 数组或单个对象）
///
/// 返回合并后的任务 JSON 数组。
pub fn prepare_imported_tasks(
    local_tasks_json: &str,
    imported_json: &str,
) -> LegadoResult<Vec<serde_json::Value>> {
    let local_tasks: Vec<AutoTaskRule> = serde_json::from_str(local_tasks_json)?;
    let imported = AutoTaskExporter::import_json(imported_json)
        .map_err(legado_core::LegadoError::Parser)?;
    Ok(AutoTaskExporter::prepare_imported_tasks(&local_tasks, imported))
}

/// 执行任务协议（对应 Kotlin `AutoTaskRunner.execute`）
///
/// - `protocol_json`: TaskProtocol JSON
/// - `task_id`: 可选任务 ID
///
/// 返回任务执行结果 `TaskResult`。
pub fn execute_task(
    protocol_json: &str,
    task_id: Option<&str>,
) -> LegadoResult<legado_core::auto_task::TaskResult> {
    let protocol = TaskProtocol::from_json(protocol_json)
        .map_err(legado_core::LegadoError::Parser)?;
    Ok(match task_id {
        Some(id) => AutoTaskRunner::execute_with_id(&protocol, id),
        None => AutoTaskRunner::execute(&protocol),
    })
}

/// 规范化脚本（去除 @js: 前缀或 <js></js> 包裹）
pub fn normalize_script(script: &str) -> String {
    core_normalize_script(script)
}

/// 判断书籍是否允许刷新目录（对应 Kotlin `canRefreshBookToc`）
pub fn can_refresh_book_toc(can_update: bool, respect_can_update: bool) -> bool {
    core_can_refresh_book_toc(can_update, respect_can_update)
}

/// 查找书籍更新任务（对应 Kotlin `AutoTask.findBookUpdateTask`）
///
/// 优先按 ID 精确匹配，其次按书名 + 作者匹配。未找到返回 None。
pub fn find_book_update_task(
    tasks_json: &str,
    book_url: &str,
    book_name: &str,
    book_author: &str,
) -> LegadoResult<Option<AutoTaskRule>> {
    let tasks: Vec<AutoTaskRule> = serde_json::from_str(tasks_json)?;
    Ok(core_find_book_update_task(&tasks, book_url, book_name, book_author).cloned())
}

/// 解析 cron 表达式，计算下次执行时间（Unix 毫秒）
///
/// 无法解析时返回 -1。
pub fn next_due_at(cron: &str, from_ms: i64) -> i64 {
    AutoTaskSchedulePolicy::next_due_at(cron, from_ms).unwrap_or(-1)
}

// ─── 数据库 CRUD（通过 with_database 访问 auto_task_rules 表）───────────

/// 列出所有自动任务规则（按 customOrder 排序）
pub fn list_rules_db() -> LegadoResult<Vec<AutoTaskRuleModel>> {
    with_database(|db| {
        let repo = AutoTaskRepository::new(db.connection());
        repo.find_all()
    })
}

/// 创建自动任务规则（INSERT OR REPLACE，返回任务 ID）
pub fn create_rule_db(rule: &AutoTaskRuleModel) -> LegadoResult<String> {
    with_database(|db| {
        let repo = AutoTaskRepository::new(db.connection());
        repo.insert(rule)?;
        Ok(rule.id.clone())
    })
}

/// 更新自动任务规则（按 ID 更新）
pub fn update_rule_db(rule: &AutoTaskRuleModel) -> LegadoResult<()> {
    with_database(|db| {
        let repo = AutoTaskRepository::new(db.connection());
        repo.update(rule)
    })
}

/// 删除自动任务规则（按 ID 删除）
pub fn delete_rule_db(id: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = AutoTaskRepository::new(db.connection());
        repo.delete(id)
    })
}

/// 根据 ID 查询自动任务规则
pub fn find_rule_by_id_db(id: &str) -> LegadoResult<Option<AutoTaskRuleModel>> {
    with_database(|db| {
        let repo = AutoTaskRepository::new(db.connection());
        repo.find_by_id(id)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_build_book_update_task() {
        let task = build_book_update_task("http://book/1", "测试", "作者", "更新测试");
        assert!(task.id.starts_with("book_update:"));
        assert_eq!(task.name, "更新测试");
    }

    #[test]
    fn test_update_cron_batch() {
        let task = build_book_update_task("http://book/1", "测试", "作者", "更新");
        let rules_json = serde_json::to_string(&vec![task.clone()]).unwrap();
        let ids_json = serde_json::to_string(&vec![task.id.clone()]).unwrap();
        let updated = update_cron_batch(&rules_json, &ids_json, "0 */6 * * *").unwrap();
        assert_eq!(updated.len(), 1);
        assert_eq!(updated[0].cron, Some("0 */6 * * *".to_string()));
    }

    #[test]
    fn test_prepare_imported_tasks() {
        let local = vec![build_book_update_task("http://book/1", "测试", "作者", "更新")];
        let local_json = serde_json::to_string(&local).unwrap();
        let imported = r#"[{"id":"new1","name":"新任务","script":"x"}]"#;
        let merged = prepare_imported_tasks(&local_json, imported).unwrap();
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0]["id"], "new1");
    }

    #[test]
    fn test_execute_task() {
        let protocol = TaskProtocol::refresh_toc("http://book/1");
        let json = protocol.to_json();
        let result = execute_task(&json, Some("t1")).unwrap();
        assert!(result.success);
        assert_eq!(result.task_id, "t1");
    }

    #[test]
    fn test_normalize_script() {
        assert_eq!(normalize_script("@js: var x=1;"), "var x=1;");
    }

    #[test]
    fn test_can_refresh_book_toc() {
        assert!(can_refresh_book_toc(true, true));
        assert!(!can_refresh_book_toc(false, true));
        assert!(can_refresh_book_toc(false, false));
    }

    #[test]
    fn test_find_book_update_task() {
        let task = build_book_update_task("http://book/1", "测试", "作者", "更新");
        let tasks_json = serde_json::to_string(&vec![task]).unwrap();
        let found =
            find_book_update_task(&tasks_json, "http://book/1", "测试", "作者").unwrap();
        assert!(found.is_some());
    }

    #[test]
    fn test_next_due_at() {
        let base: i64 = 1_000_000_000_000;
        assert_eq!(next_due_at("*/30 * * * *", base), base + 30 * 60_000);
        assert_eq!(next_due_at("invalid", base), -1);
    }

    #[test]
    fn test_auto_task_crud_db() {
        let _db_guard = crate::db_state::ensure_test_db();

        let rule = AutoTaskRuleModel {
            id: "test_crud_task_001".to_string(),
            name: "测试CRUD任务".to_string(),
            enable: true,
            cron: Some("0 */6 * * *".to_string()),
            script: "print('hello')".to_string(),
            ..AutoTaskRuleModel::default()
        };

        // Create
        create_rule_db(&rule).unwrap();

        // List
        let rules = list_rules_db().unwrap();
        assert!(rules.iter().any(|r| r.id == "test_crud_task_001"));

        // Find by ID
        let found = find_rule_by_id_db("test_crud_task_001").unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().name, "测试CRUD任务");

        // Update
        let updated_rule = AutoTaskRuleModel {
            name: "已更新任务".to_string(),
            ..rule.clone()
        };
        update_rule_db(&updated_rule).unwrap();
        let after_update = find_rule_by_id_db("test_crud_task_001").unwrap().unwrap();
        assert_eq!(after_update.name, "已更新任务");

        // Delete
        delete_rule_db("test_crud_task_001").unwrap();

        // Verify deleted
        assert!(find_rule_by_id_db("test_crud_task_001").unwrap().is_none());
    }
}
