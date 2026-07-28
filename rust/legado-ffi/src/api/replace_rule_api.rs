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
pub fn add_replace_rule(
    name: &str,
    pattern: &str,
    replacement: &str,
    is_regex: bool,
    scope: &str,
) -> LegadoResult<i64> {
    let rule = ReplaceRule {
        id: 0,
        name: name.to_string(),
        group: None,
        pattern: pattern.to_string(),
        replacement: replacement.to_string(),
        scope: if scope.is_empty() {
            None
        } else {
            Some(scope.to_string())
        },
        scope_title: false,
        scope_content: true,
        exclude_scope: None,
        is_enabled: true,
        is_regex,
        timeout_millisecond: 3000,
        order: 0,
    };

    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.insert(&rule)
    })
}

/// 更新替换规则
pub fn update_replace_rule(
    rule_id: i64,
    name: &str,
    pattern: &str,
    replacement: &str,
    is_regex: bool,
    is_enabled: bool,
) -> LegadoResult<()> {
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        // 先获取现有规则以保留其他字段
        let all = repo.find_all()?;
        let existing = all
            .iter()
            .find(|r| r.id == rule_id)
            .ok_or_else(|| legado_core::LegadoError::Database("替换规则不存在".into()))?;

        let updated = ReplaceRule {
            id: rule_id,
            name: name.to_string(),
            group: existing.group.clone(),
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            scope: existing.scope.clone(),
            scope_title: existing.scope_title,
            scope_content: existing.scope_content,
            exclude_scope: existing.exclude_scope.clone(),
            is_enabled,
            is_regex,
            timeout_millisecond: existing.timeout_millisecond,
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

    /// 辅助：初始化内存数据库并设置全局状态
    fn setup_test_db() {
        crate::db_state::ensure_test_db();
    }

    #[test]
    fn test_add_and_get_rules() {
        setup_test_db();
        let id = add_replace_rule("rr_规则1_1", "hello", "hi", false, "").unwrap();
        assert!(id > 0);

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.name == "rr_规则1_1").unwrap();
        assert_eq!(rule.pattern, "hello");
        assert_eq!(rule.replacement, "hi");
        assert!(!rule.is_regex);
    }

    #[test]
    fn test_add_multiple_rules() {
        setup_test_db();
        add_replace_rule("rr_r1_2", "a", "b", false, "").unwrap();
        add_replace_rule("rr_r2_2", r"\d+", "NUM", true, "").unwrap();
        add_replace_rule("rr_r3_2", "x", "y", false, "global").unwrap();

        let rules = get_replace_rules().unwrap();
        // 验证我们添加的规则都存在
        assert!(rules.iter().any(|r| r.name == "rr_r1_2"));
        assert!(rules.iter().any(|r| r.name == "rr_r2_2"));
        assert!(rules.iter().any(|r| r.name == "rr_r3_2"));
    }

    #[test]
    fn test_update_replace_rule() {
        setup_test_db();
        let id = add_replace_rule("rr_原名_3", "old", "new", false, "").unwrap();

        update_replace_rule(id, "rr_新名_3", "pattern2", "replace2", true, false).unwrap();

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.name == "rr_新名_3").unwrap();
        assert_eq!(rule.pattern, "pattern2");
        assert_eq!(rule.replacement, "replace2");
        assert!(rule.is_regex);
        assert!(!rule.is_enabled);
    }

    #[test]
    fn test_delete_replace_rule() {
        setup_test_db();
        let id = add_replace_rule("rr_r1_4", "a", "b", false, "").unwrap();
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
        setup_test_db();
        let id1 = add_replace_rule("rr_r1_5", "a", "b", false, "").unwrap();
        let _id2 = add_replace_rule("rr_r2_5", "c", "d", false, "").unwrap();

        // 禁用第一条
        set_rule_enabled(id1, false).unwrap();

        let enabled = get_enabled_rules().unwrap();
        assert!(enabled.iter().any(|r| r.name == "rr_r2_5"));
        assert!(!enabled.iter().any(|r| r.name == "rr_r1_5"));
    }

    #[test]
    fn test_set_rule_enabled_toggle() {
        setup_test_db();
        let id = add_replace_rule("rr_r1_6", "a", "b", false, "").unwrap();

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
        setup_test_db();
        add_replace_rule("rr_scoped_7", "a", "b", false, "特定书籍_7").unwrap();

        let rules = get_replace_rules().unwrap();
        let rule = rules.iter().find(|r| r.name == "rr_scoped_7").unwrap();
        assert_eq!(rule.scope, Some("特定书籍_7".to_string()));
    }
}
