//! 替换规则管理 API
//!
//! 提供替换规则的增删改查操作，通过 ReplaceRuleRepository 访问数据库。

use legado_core::content_processor::{
    apply_source_replace_rules, preview_single_rule, ReplaceJsExecutor, ReplaceRuleEntry,
};
use legado_core::models::ReplaceRule;
use legado_core::{LegadoError, LegadoResult};
use legado_db::ReplaceRuleRepository;

use crate::api::replace_rule_js::ReplaceRuleJsExecutor;
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
///
/// [书源作用域 | 2026-09-13 加法式扩参] 末尾第 6 个可选参数：
/// - `scope_source`：None=false（默认不作用于书源，对齐原版 `ReplaceRule.scopeSource` 默认 0）
///
/// [排序值 | 2026-11-10 批12] `sortOrder` 由硬编码 0 改为 `max(sortOrder)+1`
/// （追加到列表末尾；重排后新增规则不再顶到最前）。
#[allow(clippy::too_many_arguments)] // 书源作用域加法式扩参后参数 >7，属对外 API 表面（对齐原版字段集）
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
    scope_source: Option<bool>,
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
        scope_source: scope_source.unwrap_or(false),
        exclude_scope: exclude_scope
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string()),
        is_enabled: true,
        is_regex,
        timeout_millisecond: timeout_millisecond.unwrap_or(3000),
        order: 0, // 占位，落库前按 max(sortOrder)+1 覆盖（批12）
    };

    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        let next = repo.next_order()?;
        let rule = ReplaceRule {
            order: next,
            ..rule
        };
        repo.insert(&rule)
    })
}

/// 更新替换规则
///
/// [A3 写链路补齐 | 2026-09-11 加法式扩参] 后 5 个可选参数：
/// None=保留既有值（向后兼容）；`group`/`exclude_scope` 传 Some("")=清除该字段
///
/// [书源作用域 | 2026-09-13 加法式扩参] 末尾第 6 个可选参数：
/// - `scope_source`：None=保留既有值；Some(b)=覆盖
///
/// [特定范围写链路 | 2026-11-10 批12 加法式扩参] 末尾第 7 个可选参数：
/// - `scope`：None=保留既有值；Some("")=清除；Some(s)=覆盖
///   （修复「特定范围编辑不落库」：原实现强制沿用 `existing.scope`）
#[allow(clippy::too_many_arguments)] // 同 add_replace_rule：对外 API 表面参数 >7
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
    scope_source: Option<bool>,
    scope: Option<&str>,
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
        // [批12] scope 与 group/exclude_scope 同语义：None=保留、Some("")=清除
        let merged_scope = match scope {
            Some(s) if !s.is_empty() => Some(s.to_string()),
            Some(_) => None,
            None => existing.scope.clone(),
        };

        let updated = ReplaceRule {
            id: rule_id,
            name: name.to_string(),
            group: merged_group,
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            scope: merged_scope,
            scope_title: scope_title.unwrap_or(existing.scope_title),
            scope_content: scope_content.unwrap_or(existing.scope_content),
            scope_source: scope_source.unwrap_or(existing.scope_source),
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

/// 按给定 ID 顺序全量重编号替换规则 `sortOrder`（0..n-1），返回重排条数
///
/// 契约 §2.8 `reorderReplaceRules`（批12）：`ids_json` 为 JSON 数组，表示
/// **全量**规则 id 顺序（如 `[3,1,2]`）。重复 id / 未知 id / 缺失 id 一律
/// 参数错误且零写入；空数组返回 0（不开事务）。
pub fn replace_rule_reorder(ids_json: &str) -> LegadoResult<i32> {
    let ids: Vec<i64> = serde_json::from_str(ids_json)
        .map_err(|e| LegadoError::Database(format!("解析 reorder IDs 失败: {e}")))?;
    with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        repo.reorder(&ids)
    })
}

/// 书源导入时应用「书源作用域」替换规则（对齐原版 `BookSourceImport`）
///
/// 语义（契约 §2.8 `applyReplaceRulesToSource`）：
/// - 取 `isEnabled && scopeSource && pattern 非空` 的启用规则；
/// - `scope`/`excludeScope` 按「源名称或源 URL」忽略大小写 contains 匹配
///   （独立源上下文，不复用书名 `ScopeContext`）；
/// - 对整源 JSON 顺序逐条应用；`@js:` 注入与正文/预览**同一** QuickJS 执行器
///   （无章节/书籍上下文，对齐参考版书源导入场景），逐匹配绑定 `result`；
/// - 未命中返回原文；单条规则的超时/执行错误保留原文，**任何错误都不上抛 FFI**
///   （返回原始 JSON），保证导入流程不中断。
pub fn apply_replace_rules_to_source(
    source_json: &str,
    source_name: &str,
    source_url: &str,
) -> String {
    let result = with_database(|db| {
        let repo = ReplaceRuleRepository::new(db.connection());
        let rules = repo.get_enabled_rules()?;
        let entries: Vec<ReplaceRuleEntry> = rules
            .iter()
            .map(ReplaceRuleEntry::from_replace_rule)
            .collect();
        // [批15] 注入生产执行器：@js: 真实执行（非 quickjs 构建返回 Err，
        // 由管线按既有口径保留原文，不阻断导入）
        let js_executor: Option<std::sync::Arc<dyn ReplaceJsExecutor>> =
            Some(std::sync::Arc::new(ReplaceRuleJsExecutor::without_context()));
        Ok(apply_source_replace_rules(
            source_json,
            &entries,
            source_name,
            source_url,
            js_executor,
        ))
    });
    // 数据库未就绪/查询失败等任何错误 → 保留原文，不中断导入
    match result {
        Ok(applied) => applied,
        Err(e) => {
            eprintln!("[replace-rule] apply_replace_rules_to_source failed, keep original: {e}");
            source_json.to_string()
        }
    }
}

/// 替换规则预览：对单条规则在示例文本上执行真实替换管线
///
/// [替换规则预览 | 2026-09-13，契约 §2.8 `previewReplaceRule`] 语义：
/// - 从 [rule_json] 反序列化单条 [`ReplaceRule`]（JSON 解析失败 = `Err`，
///   唯一允许上抛 FFI 的输入侧异常路径）；
/// - 以真实管线执行（字面量 / 正则（regex 优先、fancy-regex 回退）/
///   `@js:` QuickJS），逐规则超时保护（`preview_single_rule` 独立线程 + recv_timeout）；
/// - **规则级错误（非法正则 / `@js:` JS 异常 / 执行超时）不上抛 FFI**：
///   返回 `⚠️ ` 前缀错误文本，可直接展示于编辑器预览区（单一语义源）；
/// - 成功 = 替换后文本（未命中时原样返回 [sample]）。
///
/// [批15] `@js:` 使用与正文净化/书源导入相同的 [`ReplaceRuleJsExecutor`]
/// 与绑定构造函数（空章节/书籍上下文），预览与生产不再各写一份绑定。
pub fn preview_replace_rule(rule_json: &str, sample: &str) -> LegadoResult<String> {
    let rule: ReplaceRule = serde_json::from_str(rule_json)
        .map_err(|e| LegadoError::Ffi(format!("替换规则 JSON 解析失败: {e}")))?;
    let entry = ReplaceRuleEntry::from_replace_rule(&rule);
    let js_executor: Option<std::sync::Arc<dyn ReplaceJsExecutor>> =
        Some(std::sync::Arc::new(ReplaceRuleJsExecutor::without_context()));
    match preview_single_rule(sample, &entry, &js_executor) {
        Ok(text) => Ok(text),
        Err(e) => Ok(format!("⚠️ {e}")),
    }
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
        add_replace_rule(
            "rr_r1_2", "a", "b", false, "", None, None, None, None, None, None,
        )
        .unwrap();
        add_replace_rule(
            "rr_r2_2", r"\d+", "NUM", true, "", None, None, None, None, None, None,
        )
        .unwrap();
        add_replace_rule(
            "rr_r3_2", "x", "y", false, "global", None, None, None, None, None, None,
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
        let id = add_replace_rule(
            "rr_r1_4", "a", "b", false, "", None, None, None, None, None, None,
        )
        .unwrap();
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
        let id1 = add_replace_rule(
            "rr_r1_5", "a", "b", false, "", None, None, None, None, None, None,
        )
        .unwrap();
        let _id2 = add_replace_rule(
            "rr_r2_5", "c", "d", false, "", None, None, None, None, None, None,
        )
        .unwrap();

        // 禁用第一条
        set_rule_enabled(id1, false).unwrap();

        let enabled = get_enabled_rules().unwrap();
        assert!(enabled.iter().any(|r| r.name == "rr_r2_5"));
        assert!(!enabled.iter().any(|r| r.name == "rr_r1_5"));
    }

    #[test]
    fn test_set_rule_enabled_toggle() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_r1_6", "a", "b", false, "", None, None, None, None, None, None,
        )
        .unwrap();

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
            None,
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
            None,
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
            None,
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

    /// [书源作用域 | 2026-09-13] add 显式 Some(true) 落库；缺省 None → false（对齐原版默认 0）
    #[test]
    fn test_add_rule_with_scope_source() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_ss_10",
            "旧站",
            "新站",
            false,
            "起点",
            None,
            None,
            None,
            None,
            None,
            Some(true),
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert!(rule.scope_source, "scopeSource=true 应持久化");

        // 缺省（None）→ 默认 false
        let id2 = add_replace_rule(
            "rr_ss_10b",
            "a",
            "b",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        let rule2 = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id2)
            .unwrap();
        assert!(!rule2.scope_source, "缺省 scopeSource 应为 false");
    }

    /// [书源作用域 | 2026-09-13] update：None=保留既有值；Some(false)=覆盖
    #[test]
    fn test_update_rule_scope_source_semantics() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_ss_11",
            "a",
            "b",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            Some(true),
        )
        .unwrap();

        // None → 保留 true
        update_replace_rule(
            id, "rr_ss_11", "a2", "b2", false, true, None, None, None, None, None, None, None,
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert!(rule.scope_source, "None 应保留既有 true");

        // Some(false) → 覆盖为 false
        update_replace_rule(
            id,
            "rr_ss_11",
            "a3",
            "b3",
            false,
            true,
            None,
            None,
            None,
            None,
            None,
            Some(false),
            None,
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert!(!rule.scope_source, "Some(false) 应覆盖为 false");
    }

    /// [书源作用域 | 2026-09-13] apply_replace_rules_to_source：
    /// scope 命中源名 → 整源 JSON 被替换；未命中 → 原样返回（不中断导入）
    ///
    /// 注：共享测试库中其他测试的 scopeSource 规则会持续存在（如 rr_ss_10
    /// pattern「旧站」/scope「起点」），故 scope/源名/URL/pattern 均用完全
    /// 独立的 ss12 词汇，避免跨测试污染（尤其「禁用后原样返回」断言）
    #[test]
    fn test_apply_replace_rules_to_source_hit_and_miss() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_ss_12",
            "ss12甲词",
            "ss12乙词",
            false,
            "ss12域A",
            None,
            None,
            None,
            None,
            None,
            Some(true),
        )
        .unwrap();

        // 命中：scope「ss12域A」包含于源名称 → 整源 JSON 中「ss12甲词」被替换
        let json = r#"{"bookSourceName":"ss12域A书库","ruleSearch":{"searchUrl":"https://www.ss12甲词.com/search/{{key}}"}}"#;
        let applied =
            apply_replace_rules_to_source(json, "ss12域A书库", "https://www.ss12甲词.com");
        assert!(
            applied.contains("ss12乙词"),
            "scope 命中源名后应替换整源 JSON"
        );
        assert!(!applied.contains("ss12甲词"));

        // 未命中：scope「ss12域A」不含于其他源 → 原样返回
        let other_json = r#"{"bookSourceName":"ss12域B书库","ruleSearch":{"searchUrl":"https://www.ss12甲词.com/search/{{key}}"}}"#;
        let original =
            apply_replace_rules_to_source(other_json, "ss12域B书库", "https://ss12域B.com");
        assert_eq!(original, other_json, "scope 未命中源名/源 URL 时应原样返回");

        // 禁用规则不生效（独立词汇确保无其他测试规则干扰）
        set_rule_enabled(id, false).unwrap();
        let disabled =
            apply_replace_rules_to_source(json, "ss12域A书库", "https://www.ss12甲词.com");
        assert_eq!(disabled, json, "禁用规则不应生效");
    }

    /// [书源作用域 | 2026-09-13] scope 命中源 URL（忽略大小写）→ 替换生效
    #[test]
    fn test_apply_replace_rules_to_source_url_match() {
        let _db_guard = setup_test_db();
        add_replace_rule(
            "rr_ss_13",
            "ss13旧域名",
            "ss13新域名",
            false,
            "ss13example.com",
            None,
            None,
            None,
            None,
            None,
            Some(true),
        )
        .unwrap();

        // 源名称不含 scope，但 URL 命中（忽略大小写）
        let json = r#"{"bookSourceName":"ss13某源","ruleContent":"访问 ss13旧域名 获取内容"}"#;
        let applied =
            apply_replace_rules_to_source(json, "ss13某源", "https://WWW.SS13EXAMPLE.COM/src");
        assert!(
            applied.contains("ss13新域名"),
            "scope 命中源 URL（忽略大小写）应替换"
        );
    }

    /// [批15] 书源导入路径同样执行 `@js:` 规则
    ///
    /// 修复前 `apply_replace_rules_to_source` 传 `None` 执行器 → `@js:` 被
    /// 安全跳过（红：原 token 保留）；修复后注入生产执行器 → 替换生效（绿）。
    /// 使用完全独立的 ss15 词汇与源作用域，避免共享测试库其他规则干扰。
    #[test]
    fn test_apply_replace_rules_to_source_executes_js_rule() {
        let _db_guard = setup_test_db();
        let rule_id = add_replace_rule(
            "rr_js15_source",
            "ss15源甲",
            r#"@js:"ss15源乙""#,
            true,
            "ss15甲域",
            None,
            None,
            None,
            None,
            None,
            Some(true),
        )
        .unwrap();

        let json = r#"{"bookSourceName":"ss15甲域书库","ruleSearch":{"searchUrl":"https://ss15源甲.example.com/search/{{key}}"}}"#;
        let applied =
            apply_replace_rules_to_source(json, "ss15甲域书库", "https://ss15甲域.example.com");
        if cfg!(feature = "quickjs") {
            // quickjs：@js: 真实执行 → 原 token 被替换
            assert!(
                applied.contains("ss15源乙"),
                "书源导入 @js: 规则应真实执行，实际: {applied}"
            );
            assert!(
                !applied.contains("ss15源甲"),
                "@js: 替换后原 token 不应保留，实际: {applied}"
            );
        } else {
            // 非 quickjs：@js: 不执行 → 原 token 保留（不阻断导入）
            assert_eq!(
                applied, json,
                "无 quickjs 构建 @js: 应保留原文，实际: {applied}"
            );
        }

        delete_replace_rule(rule_id).unwrap();
    }

    // ─── [替换规则预览 | 2026-09-13] previewReplaceRule 五类单测 ───
    // 预览为纯函数路径（不访问 DB），无需 setup_test_db。
    // ruleJson 字段与 Dart `ReplaceRule.toJson()` 对齐（camelCase）。

    /// 构造预览入参 JSON（仅填必要字段，其余走 serde 缺省值）
    fn preview_rule_json(
        pattern: &str,
        replacement: &str,
        is_regex: bool,
        timeout_ms: i64,
    ) -> String {
        serde_json::json!({
            "name": "rr_preview",
            "pattern": pattern,
            "replacement": replacement,
            "isRegex": is_regex,
            "isEnabled": true,
            "timeoutMillisecond": timeout_ms,
        })
        .to_string()
    }

    /// ① 字面量规则：非正则按字面替换（对标 String.replace）
    #[test]
    fn test_preview_literal_rule() {
        let json = preview_rule_json("hello", "hi", false, 3000);
        let out = preview_replace_rule(&json, "say hello world").unwrap();
        assert_eq!(out, "say hi world", "字面量替换应生效");
        // 未命中 → 原样返回
        let out = preview_replace_rule(&json, "no match here").unwrap();
        assert_eq!(out, "no match here", "未命中应原样返回");
    }

    /// ② 正则规则：组引用 $1（对标 java.util.Matcher.replaceAll 语义）
    #[test]
    fn test_preview_regex_rule() {
        let json = preview_rule_json(r"(\d+)", "NUM$1", true, 3000);
        let out = preview_replace_rule(&json, "a12b345c").unwrap();
        assert_eq!(out, "aNUM12bNUM345c", "正则组引用 $1 应展开");

        // 空 pattern → 原样返回（与 run_replace_rules 跳过语义一致）
        let empty = preview_rule_json("", "x", true, 3000);
        let out = preview_replace_rule(&empty, "anything").unwrap();
        assert_eq!(out, "anything", "空 pattern 应原样返回");
    }

    /// ③ `@js:` 规则（quickjs 构建：真实 QuickJS 执行；非 quickjs：⚠️ 降级提示）
    #[test]
    fn test_preview_js_rule() {
        let json = preview_rule_json(r"(\d+)", "@js:String(Number(result) * 2)", true, 3000);
        let out = preview_replace_rule(&json, "a12b").unwrap();
        #[cfg(feature = "quickjs")]
        {
            assert_eq!(
                out, "a24b",
                "QuickJS 应真实执行 @js: 表达式（result 绑定=匹配文本）"
            );
        }
        #[cfg(not(feature = "quickjs"))]
        {
            assert!(
                out.starts_with("⚠️") && out.contains("QuickJS 未启用"),
                "非 quickjs 构建应返回 ⚠️ 降级提示而非异常，实际: {out}"
            );
        }
    }

    /// ③b 预览与生产共用同一绑定构造点，chapter/book 字段可见
    ///
    /// 若预览只绑 `result`，`chapter.title` 会抛 TypeError → 返回 ⚠️；
    /// 断言预览与生产管线（`apply_replace_rules` + 同一执行器/空上下文）
    /// 输出相等，且缺失字段为空串/0（回修 P2-5）。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_preview_js_rule_binds_empty_chapter_and_book() {
        let replacement = r#"@js: result + "|" + chapter.title + "|" + chapter.index + "|" + book.name + "|" + book.author"#;
        let json = preview_rule_json("标记", replacement, true, 3000);
        let out = preview_replace_rule(&json, "标记").unwrap();
        assert_eq!(
            out, "标记||0||",
            "预览应绑定空 chapter/book 对象（缺失字段为空串/0）"
        );

        // 生产管线：同一规则、同一输入、同一执行器构造点（空上下文）
        let entry = ReplaceRuleEntry {
            pattern: "标记".to_string(),
            replacement: replacement.to_string(),
            is_regex: true,
            ..ReplaceRuleEntry::default()
        };
        let production = legado_core::content_processor::apply_replace_rules(
            "标记",
            std::slice::from_ref(&entry),
            Some(std::sync::Arc::new(ReplaceRuleJsExecutor::without_context())),
        );
        assert_eq!(
            production, out,
            "预览与生产（空上下文）应输出一致且 chapter/book 可见"
        );
    }

    /// ④ 超时保护：`@js:` 死循环 + 短超时 → ⚠️ 超时文本
    ///
    /// quickjs 构建：JS 线程在沙箱 5s 截止前空转，规则 50ms 超时先触发
    /// （孤儿线程由沙箱截止回收，不阻塞测试断言）。
    /// 非 quickjs 构建：执行器即时 Err，同样落 ⚠️ 路径（断言前缀即可）。
    #[test]
    fn test_preview_timeout() {
        let json = preview_rule_json(r"(\d+)", "@js:while(true){}", true, 50);
        let out = preview_replace_rule(&json, "a12b").unwrap();
        #[cfg(feature = "quickjs")]
        {
            assert!(
                out.starts_with("⚠️") && out.contains("规则执行超时（50ms）"),
                "短超时 + 死循环 JS 应返回 ⚠️ 超时文本，实际: {out}"
            );
        }
        #[cfg(not(feature = "quickjs"))]
        {
            assert!(
                out.starts_with("⚠️") && out.contains("QuickJS 未启用"),
                "非 quickjs 构建 @js: 应返回 ⚠️ 降级提示，实际: {out}"
            );
        }
    }

    /// ⑤ 非法 JSON 输入：MAY Err（唯一允许上抛 FFI 的路径）
    #[test]
    fn test_preview_invalid_json() {
        let err = preview_replace_rule("{not a json", "x").unwrap_err();
        let msg = err.to_string();
        assert!(
            msg.contains("替换规则 JSON 解析失败"),
            "非法 JSON 应上抛解析错误，实际: {msg}"
        );
    }

    // ─── 批12：排序与 scope 写链路 ───

    /// add：新规则 sortOrder = 既有 max+1（重排后不再顶到最前）
    #[test]
    fn test_add_rule_order_is_max_plus_one() {
        let _db_guard = setup_test_db();
        let expected = get_replace_rules()
            .unwrap()
            .iter()
            .map(|r| r.order)
            .max()
            .map_or(0, |max| max + 1);

        let id = add_replace_rule(
            "rr_order_14",
            "a",
            "b",
            false,
            "",
            None,
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
        assert_eq!(rule.order, expected, "add 的 sortOrder 应为 max+1");
    }

    /// update 扩参 scope：None=保留既有值；Some(s)=覆盖；Some("")=清除
    #[test]
    fn test_update_rule_scope_semantics() {
        let _db_guard = setup_test_db();
        let id = add_replace_rule(
            "rr_scope_15",
            "a",
            "b",
            false,
            "旧范围_15",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

        // None → 保留既有 scope
        update_replace_rule(
            id,
            "rr_scope_15",
            "a2",
            "b2",
            false,
            true,
            None,
            None,
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
        assert_eq!(
            rule.scope.as_deref(),
            Some("旧范围_15"),
            "None 应保留既有 scope"
        );

        // Some(非空) → 覆盖
        update_replace_rule(
            id,
            "rr_scope_15",
            "a3",
            "b3",
            false,
            true,
            None,
            None,
            None,
            None,
            None,
            None,
            Some("新范围_15"),
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert_eq!(
            rule.scope.as_deref(),
            Some("新范围_15"),
            "Some(非空) 应覆盖 scope"
        );

        // Some("") → 清除
        update_replace_rule(
            id,
            "rr_scope_15",
            "a4",
            "b4",
            false,
            true,
            None,
            None,
            None,
            None,
            None,
            None,
            Some(""),
        )
        .unwrap();
        let rule = get_replace_rules()
            .unwrap()
            .into_iter()
            .find(|r| r.id == id)
            .unwrap();
        assert!(rule.scope.is_none(), "Some(\"\") 应清除 scope");
    }

    /// reorder：全量逆序 → find_all 按新顺序返回且 sortOrder=0..n-1；连续两次幂等
    #[test]
    fn test_replace_rule_reorder_full_sequence() {
        let _db_guard = setup_test_db();
        // 共享测试库可能已有其他用例的规则：直接对全量 id 逆序（仍满足全量约束）
        add_replace_rule(
            "rr_reorder_16a",
            "a",
            "b",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        add_replace_rule(
            "rr_reorder_16b",
            "c",
            "d",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

        let mut target: Vec<i64> = get_replace_rules().unwrap().iter().map(|r| r.id).collect();
        assert!(target.len() >= 2, "共享库应至少包含两条规则");
        target.reverse();

        let ids_json = serde_json::to_string(&target).unwrap();
        let count = replace_rule_reorder(&ids_json).unwrap();
        assert_eq!(count as usize, target.len());

        let rules = get_replace_rules().unwrap();
        assert_eq!(
            rules.iter().map(|r| r.id).collect::<Vec<_>>(),
            target,
            "find_all 应按传入顺序返回"
        );
        assert_eq!(
            rules.iter().map(|r| r.order).collect::<Vec<_>>(),
            (0..target.len() as i32).collect::<Vec<_>>(),
            "sortOrder 应重编号为 0..n-1"
        );

        // 连续两次相同重排幂等
        assert_eq!(
            replace_rule_reorder(&ids_json).unwrap() as usize,
            target.len()
        );
        let rules_again = get_replace_rules().unwrap();
        assert_eq!(rules_again.iter().map(|r| r.id).collect::<Vec<_>>(), target);
    }

    /// reorder：重复/未知/缺失 id → Err 且零写入；空数组返回 0 不改动；非法 JSON Err
    #[test]
    fn test_replace_rule_reorder_rejects_illegal_sets() {
        let _db_guard = setup_test_db();
        add_replace_rule(
            "rr_reorder_17a",
            "a",
            "b",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        add_replace_rule(
            "rr_reorder_17b",
            "c",
            "d",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();
        add_replace_rule(
            "rr_reorder_17c",
            "e",
            "f",
            false,
            "",
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .unwrap();

        let snapshot = |rules: Vec<ReplaceRule>| {
            let mut rows: Vec<(i64, i32)> = rules.iter().map(|r| (r.id, r.order)).collect();
            rows.sort_unstable_by_key(|(id, _)| *id);
            rows
        };
        let before = snapshot(get_replace_rules().unwrap());
        let ids: Vec<i64> = before.iter().map(|(id, _)| *id).collect();
        assert!(ids.len() >= 3);

        // 重复 id
        let dup = serde_json::to_string(&[ids[0], ids[0], ids[1]]).unwrap();
        let err = replace_rule_reorder(&dup).unwrap_err();
        assert!(
            err.to_string().contains("重复 id"),
            "重复 id 应报参数错误，实际: {err}"
        );

        // 未知 id
        let mut unknown = ids.clone();
        unknown.push(9_999_999);
        let err = replace_rule_reorder(&serde_json::to_string(&unknown).unwrap()).unwrap_err();
        assert!(
            err.to_string().contains("未知 id"),
            "未知 id 应报参数错误，实际: {err}"
        );

        // 缺失 id（少提交最后一条）
        let missing = serde_json::to_string(&ids[..ids.len() - 1]).unwrap();
        let err = replace_rule_reorder(&missing).unwrap_err();
        assert!(
            err.to_string().contains("缺失 id"),
            "缺失 id 应报参数错误，实际: {err}"
        );

        // 非法 JSON
        assert!(replace_rule_reorder("not a json array").is_err());

        // 以上非法调用均零写入
        assert_eq!(
            snapshot(get_replace_rules().unwrap()),
            before,
            "非法集必须零写入"
        );

        // 空数组：返回 0 且不改动
        assert_eq!(replace_rule_reorder("[]").unwrap(), 0);
        assert_eq!(snapshot(get_replace_rules().unwrap()), before);
    }
}
