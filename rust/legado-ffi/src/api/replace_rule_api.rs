//! 替换规则管理 API
//!
//! 提供替换规则的增删改查操作，通过 ReplaceRuleRepository 访问数据库。

use legado_core::models::ReplaceRule;
use legado_core::LegadoResult;
use legado_db::ReplaceRuleRepository;

use crate::db_state::with_database;

/// 获取所有替换规则
pub fn get_replace_rules() -> LegadoResult<Vec<ReplaceRule>> {
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.find_all()
    })
}

/// 添加替换规则，返回新规则的 id
///
/// [A3 写链路补齐 | 2026-09-11 加法式扩参] 后 5 个可选参数缺省即旧行为：
/// - `group`：None=无分组
/// - `scope_title`：None=false（默认不作用于标题）
/// - `scope_content`：None=true（默认作用于正文）
/// - `exclude_scope`：None=不排除（空串归一为 None，与 scope 语义一致）
/// - `timeout_millisecond`：None=3000ms
pub fn add_replace_rule(
    name: &str,
    pattern: &str,
    replacement: &str,
    is_regex: bool,
    scope: &str,
    group: Option<&str>,
    scope_title: Option<bool>,
    scope_content: Option<bool>,
    exclude_scope: Option<&str>,
    timeout_millisecond: Option<i64>,
) -> LegadoResult<i64> {
    let rule = ReplaceRule {
        id: 0,
        name: name.to_string(),
        group: group.map(|s| s.to_string()),
        pattern: pattern.to_string(),
        replacement: replacement.to_string(),
        scope: if scope.is_empty() {
            None
        } else {
            Some(scope.to_string())
        },
        scope_title: scope_title.unwrap_or(false),
        scope_content: scope_content.unwrap_or(true),
        exclude_scope: exclude_scope
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string()),
        is_enabled: true,
        is_regex,
        timeout_millisecond: timeout_millisecond.unwrap_or(3000),
        order: 0,
    };

    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.insert(&rule)
    })
}

/// 更新替换规则
///
/// [A3 写链路补齐 | 2026-09-11 加法式扩参] 后 5 个可选参数：
/// None=保留既有值（向后兼容）；`group`/`exclude_scope` 传 Some("")=清除该字段
pub fn update_replace_rule(
    rule_id: i64,
    name: &str,
    pattern: &str,
    replacement: &str,
    is_regex: bool,
    is_enabled: bool,
    group: Option<&str>,
    scope_title: Option<bool>,
    scope_content: Option<bool>,
    exclude_scope: Option<&str>,
    timeout_millisecond: Option<i64>,
) -> LegadoResult<()> {
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        // 先获取现有规则以保留其他字段
        let all = repo.find_all()?;
        let existing = all
            .iter()
            .find(|r| r.id == rule_id)
            .ok_or_else(|| legado_core::LegadoError::Database("替换规则不存在".into()))?;

        // 可选参合并：None=保留既有值；Some("")=清除（group/exclude_scope）
        let merged_group = match group {
            Some(s) if !s.is_empty() => Some(s.to_string()),
            Some(_) => None,
            None => existing.group.clone(),
        };
        let merged_exclude = match exclude_scope {
            Some(s) if !s.is_empty() => Some(s.to_string()),
            Some(_) => None,
            None => existing.exclude_scope.clone(),
        };

        let updated = ReplaceRule {
            id: rule_id,
            name: name.to_string(),
            group: merged_group,
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            scope: existing.scope.clone(),
            scope_title: scope_title.unwrap_or(existing.scope_title),
            scope_content: scope_content.unwrap_or(existing.scope_content),
            exclude_scope: merged_exclude,
            is_enabled,
            is_regex,
            timeout_millisecond: timeout_millisecond.unwrap_or(existing.timeout_millisecond),
            order: existing.order,
        };
        repo.update(&updated)
    })
}

/// 删除替换规则
pub fn delete_replace_rule(rule_id: i64) -> LegadoResult<()> {
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.delete(rule_id)
    })
}

/// 获取所有启用的替换规则（用于阅读时应用）
pub fn get_enabled_rules() -> LegadoResult<Vec<ReplaceRule>> {
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.get_enabled_rules()
    })
}

/// 启用/禁用替换规则
pub fn set_rule_enabled(rule_id: i64, enabled: bool) -> LegadoResult<()> {
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.set_enabled(rule_id, enabled)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 辅助：初始化内存数据库并设置全局状态（返回串行锁守卫，测试必须绑定到变量）
    fn setup_test_db() -> std::sync::MutexGuard<'static, ()> {
        crate::db_state::ensure_test_db()
    }

    #[test]
    fn test_add_and_get_rules() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_规则1_1",
            "hello",
            "hi",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        assert!(id > 0);

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.name == "rr_规则1_1").unwrap();
        assert_eq!(rule.pattern, "hello");
        assert_eq!(rule.replacement, "hi");
        assert!(!rule.is_regex);
    }

    #[test]
    fn test_add_multiple_rules() {
        let _db_guard = setup_test_db();
        add_replace_rule("rr_r1_2", "a", "b", false, "", None, None, None, None, None).unwrap();
        add_replace_rule(
            "rr_r2_2", r"\d+", "NUM", true, "", None, None, None, None, None,
        )
        .unwrap();
        add_replace_rule(
            "rr_r3_2", "x", "y", false, "global", None, None, None, None, None,
        )
        .unwrap();

        let rules = get_replace_rules().unwrap();
        // 验证我们添加的规则都存在
        assert!(rules.iter().any(|r| r.name == "rr_r1_2"));
        assert!(rules.iter().any(|r| r.name == "rr_r2_2"));
        assert!(rules.iter().any(|r| r.name == "rr_r3_2"));
    }

    #[test]
    fn test_update_replace_rule() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_原名_3",
            "old",
            "new",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

        update_replace_rule(
            id,
            "rr_新名_3",
            "pattern2",
            "replace2",
            true,
            false,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.name == "rr_新名_3").unwrap();
        assert_eq!(rule.pattern, "pattern2");
        assert_eq!(rule.replacement, "replace2");
        assert!(rule.is_regex);
        assert!(!rule.is_enabled);
    }

    #[test]
    fn test_delete_replace_rule() {
        let _db_guard = setup_test_db();
        let id =
            add_replace_rule("rr_r1_4", "a", "b", false, "", None, None, None, None, None).unwrap();
        assert!(get_replace_rules()
            .unwrap()
            .iter()
            .any(|r| r.name == "rr_r1_4"));

        delete_replace_rule(id).unwrap();
        assert!(!get_replace_rules()
            .unwrap()
            .iter()
            .any(|r| r.name == "rr_r1_4"));
    }

    #[test]
    fn test_get_enabled_rules() {
        let _db_guard = setup_test_db();
        let id1 =
            add_replace_rule("rr_r1_5", "a", "b", false, "", None, None, None, None, None).unwrap();
        let _id2 =
            add_replace_rule("rr_r2_5", "c", "d", false, "", None, None, None, None, None).unwrap();

        // 禁用第一条
        set_rule_enabled(id1, false).unwrap();

        let enabled = get_enabled_rules().unwrap();
        assert!(enabled.iter().any(|r| r.name == "rr_r2_5"));
        assert!(!enabled.iter().any(|r| r.name == "rr_r1_5"));
    }

    #[test]
    fn test_set_rule_enabled_toggle() {
        let _db_guard = setup_test_db();
        let id =
            add_replace_rule("rr_r1_6", "a", "b", false, "", None, None, None, None, None).unwrap();

        // 默认启用
        assert!(get_enabled_rules()
            .unwrap()
            .iter()
            .any(|r| r.name == "rr_r1_6"));

        // 禁用
        set_rule_enabled(id, false).unwrap();
        assert!(!get_enabled_rules()
            .unwrap()
            .iter()
            .any(|r| r.name == "rr_r1_6"));

        // 重新启用
        set_rule_enabled(id, true).unwrap();
        assert!(get_enabled_rules()
            .unwrap()
            .iter()
            .any(|r| r.name == "rr_r1_6"));
    }

    #[test]
    fn test_add_rule_with_scope() {
        let _db_guard = setup_test_db();
        add_replace_rule(
            "rr_scoped_7",
            "a",
            "b",
            false,
            "特定书籍_7",
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.name == "rr_scoped_7").unwrap();
        assert_eq!(rule.scope, Some("特定书籍_7".to_string()));
    }

    /// [A3 写链路补齐 | 2026-09-11] add 带 group/scopeTitle/scopeContent/
    /// excludeScope/timeout 能持久化且 get 回读一致
    #[test]
    fn test_add_rule_with_group_scope_timeout() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_full_8",
            "a",
            "b",
            false,
            "",
            Some("净化组_8"),
            Some(true),
            Some(false),
            Some("排除书_8"),
            Some(5000),
        )
        .unwrap();
        assert!(id > 0);

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.id == id).unwrap();
        assert_eq!(rule.group.as_deref(), Some("净化组_8"));
        assert!(rule.scope_title);
        assert!(!rule.scope_content);
        assert_eq!(rule.exclude_scope.as_deref(), Some("排除书_8"));
        assert_eq!(rule.timeout_millisecond, 5000);
    }

    /// [A3 写链路补齐 | 2026-09-11] update 扩参落库：显式覆盖 + 保留既有值 +
    /// Some("") 清除，三类语义均须 get 回读一致
    #[test]
    fn test_update_rule_with_group_scope_timeout() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_full_9",
            "a",
            "b",
            false,
            "",
            Some("旧组_9"),
            Some(true),
            Some(false),
            Some("旧排除_9"),
            Some(7000),
        )
        .unwrap();

        // 1) 显式覆盖 5 个字段
        update_replace_rule(
            id,
            "rr_full_9",
            "p2",
            "r2",
            true,
            true,
            Some("新组_9"),
            Some(false),
            Some(true),
            Some("新排除_9"),
            Some(8000),
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert_eq!(rule.group.as_deref(), Some("新组_9"));
        assert!(!rule.scope_title);
        assert!(rule.scope_content);
        assert_eq!(rule.exclude_scope.as_deref(), Some("新排除_9"));
        assert_eq!(rule.timeout_millisecond, 8000);
        assert_eq!(rule.pattern, "p2");

        // 2) 全 None → 保留既有值（向后兼容路径）
        update_replace_rule(
            id,
            "rr_full_9",
            "p3",
            "r3",
            true,
            true,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert_eq!(rule.group.as_deref(), Some("新组_9"));
        assert!(!rule.scope_title);
        assert!(rule.scope_content);
        assert_eq!(rule.exclude_scope.as_deref(), Some("新排除_9"));
        assert_eq!(rule.timeout_millisecond, 8000);
        assert_eq!(rule.pattern, "p3");

        // 3) Some("") → 清除 group/exclude_scope
        update_replace_rule(
            id,
            "rr_full_9",
            "p4",
            "r4",
            true,
            true,
            Some(""),
            None,
            None,
            Some(""),
            None,
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert!(rule.group.is_none());
        assert!(rule.exclude_scope.is_none());
        // 未提供 scopeTitle/scopeContent/timeout → 仍保留上一步值
        assert!(!rule.scope_title);
        assert!(rule.scope_content);
        assert_eq!(rule.timeout_millisecond, 8000);
    }
}
