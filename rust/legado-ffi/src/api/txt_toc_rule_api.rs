//! TXT 目录规则 CRUD（契约 §2.45 同族，B8）
//!
//! 背景：`TxtTocRulesNotifier` 此前把规则序列化进 `caches` 的
//! `config:txt_toc_rules`，而备份导出/恢复与目录解析读的是 `txtTocRules`
//! 表（`backup_api.rs` 的 `txtTocRules` 段、`reader.rs` 的规则应用）——
//! 用户自建规则既不参与备份（换机即丢），也不在真正的规则库里。
//!
//! 本模块提供 `txtTocRules` 表的 FFI CRUD，与 `dict_api` 的字典规则
//! 7 方法同构（列表/新增/更新/删除/启停/重排/导入），供 Flutter 侧
//! 把规则库统一落到表上。
//!
//! 语义对齐原版 `TxtTocRuleDao`：
//! - 排序按 `serialNumber` 升序；
//! - 默认规则（`id < 0`，来自内置 `txtTocRule.json`）由 `importDefault`
//!   删除后重新灌入（对齐 `DefaultData.importDefaultTocRules` 的
//!   `deleteDefault` + `insert`）；
//! - 导入按 `name` REPLACE（对齐原版 `importSelect`）。

use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};
use legado_db::{TxtTocRuleRecord, TxtTocRuleRepository};

use crate::db_state::with_database;

/// TXT 目录规则 DTO（serde 键对齐原版 `txtTocRule.json` 与 Dart `TxtTocRule`）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TxtTocRuleDto {
    pub id: i64,
    pub name: String,
    pub rule: String,
    #[serde(default)]
    pub replacement: String,
    #[serde(default, rename = "serialNumber")]
    pub serial_number: i32,
    #[serde(default = "default_enable")]
    pub enable: bool,
    #[serde(default)]
    pub example: Option<String>,
}

fn default_enable() -> bool {
    true
}

impl From<&TxtTocRuleRecord> for TxtTocRuleDto {
    fn from(r: &TxtTocRuleRecord) -> Self {
        Self {
            id: r.id,
            name: r.name.clone(),
            rule: r.rule.clone(),
            replacement: r.replacement.clone(),
            serial_number: r.serial_number,
            enable: r.enable,
            example: r.example.clone(),
        }
    }
}

/// 列出全部 TXT 目录规则（`ORDER BY serialNumber`）
pub fn txt_toc_rule_list() -> LegadoResult<Vec<TxtTocRuleDto>> {
    with_database(|db| {
        let repo = TxtTocRuleRepository::new(db.connection());
        Ok(repo.find_all()?.iter().map(TxtTocRuleDto::from).collect())
    })
}

/// 新增一条 TXT 目录规则，返回新行 id
///
/// `serial_number` 传 `< 0` 时取当前规则总数（追加到末尾）。
pub fn txt_toc_rule_add(
    name: &str,
    rule: &str,
    replacement: &str,
    enable: bool,
    example: Option<&str>,
    serial_number: i32,
) -> LegadoResult<i64> {
    with_database(|db| {
        let repo = TxtTocRuleRepository::new(db.connection());
        let order = if serial_number >= 0 {
            serial_number
        } else {
            repo.count()? as i32
        };
        let id = repo.insert_with_replacement(name, rule, replacement, order)?;
        // insert_with_replacement 不写 enable/example（历史签名固定），
        // 新增面需要这两列，补一次定向 UPDATE
        db.connection()
            .execute(
                "UPDATE txtTocRules SET enable = ?1, example = ?2 WHERE id = ?3",
                rusqlite::params![enable as i32, example, id],
            )
            .map_err(|e| LegadoError::Database(format!("补写 TXT 目录规则状态失败: {e}")))?;
        Ok(id)
    })
}

/// 更新一条 TXT 目录规则（全可变列），返回是否实际更新
pub fn txt_toc_rule_update(
    id: i64,
    name: &str,
    rule: &str,
    replacement: &str,
    enable: bool,
    example: Option<&str>,
    serial_number: i32,
) -> LegadoResult<bool> {
    with_database(|db| {
        let affected = db
            .connection()
            .execute(
                "UPDATE txtTocRules
                 SET name = ?1, rule = ?2, replacement = ?3,
                     enable = ?4, example = ?5, serialNumber = ?6
                 WHERE id = ?7",
                rusqlite::params![
                    name,
                    rule,
                    replacement,
                    enable as i32,
                    example,
                    serial_number,
                    id
                ],
            )
            .map_err(|e| LegadoError::Database(format!("更新 TXT 目录规则失败: {e}")))?;
        Ok(affected > 0)
    })
}

/// 删除一条 TXT 目录规则，返回是否实际删除
pub fn txt_toc_rule_delete(id: i64) -> LegadoResult<bool> {
    with_database(|db| {
        let affected = db
            .connection()
            .execute(
                "DELETE FROM txtTocRules WHERE id = ?1",
                rusqlite::params![id],
            )
            .map_err(|e| LegadoError::Database(format!("删除 TXT 目录规则失败: {e}")))?;
        Ok(affected > 0)
    })
}

/// 设置启用/禁用，返回是否实际更新
pub fn txt_toc_rule_set_enabled(id: i64, enabled: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let affected = db
            .connection()
            .execute(
                "UPDATE txtTocRules SET enable = ?1 WHERE id = ?2",
                rusqlite::params![enabled as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("更新 TXT 目录规则启用状态失败: {e}")))?;
        Ok(affected > 0)
    })
}

/// 按给定 ID 顺序重编号 `serialNumber`（0..n），返回重排条数
pub fn txt_toc_rule_reorder(ids_json: &str) -> LegadoResult<i32> {
    let ids: Vec<i64> = serde_json::from_str(ids_json)
        .map_err(|e| LegadoError::Database(format!("解析 reorder IDs 失败: {e}")))?;
    with_database(|db| {
        let conn = db.connection();
        for (index, id) in ids.iter().enumerate() {
            conn.execute(
                "UPDATE txtTocRules SET serialNumber = ?1 WHERE id = ?2",
                rusqlite::params![index as i32, id],
            )
            .map_err(|e| LegadoError::Database(format!("重排 TXT 目录规则失败: {e}")))?;
        }
        Ok(ids.len() as i32)
    })
}

/// 导入 TXT 目录规则（GSON 数组/单对象，REPLACE by name），返回导入条数
///
/// 与字典规则导入同语义：同名覆盖保留库内 id、异名插入。导入**不清空**
/// 既有规则（原版 `importSelect` 的合并语义）。
pub fn txt_toc_rule_import(json_or_url: &str, kind: &str) -> LegadoResult<i32> {
    let body = match kind {
        "url" => fetch_url_body(json_or_url)?,
        _ => json_or_url.to_string(),
    };
    let rules = parse_import_rules(&body)?;
    let count = rules.len() as i32;
    with_database(|db| {
        let repo = TxtTocRuleRepository::new(db.connection());
        for rule in &rules {
            let existing = find_by_name(db, &rule.name)?;
            let record = TxtTocRuleRecord {
                id: existing.as_ref().map(|r| r.id).unwrap_or(0),
                name: rule.name.clone(),
                rule: rule.rule.clone(),
                replacement: rule.replacement.clone(),
                serial_number: existing
                    .as_ref()
                    .map(|r| r.serial_number)
                    .unwrap_or(rule.serial_number),
                enable: rule.enable,
                example: rule.example.clone(),
            };
            repo.upsert(&record)?;
        }
        Ok(count)
    })
}

/// 导入原版默认规则：删除 `id < 0` 的默认行后按内置 `txtTocRule.json` 重灌
///
/// 对齐 Kotlin `DefaultData.importDefaultTocRules`（`deleteDefault` +
/// `insert`）；用户自建规则（`id > 0`）保留。
///
/// **显式写负数主键**：`TxtTocRuleRepository::upsert` 把 `id <= 0` 视为
/// 「交由 SQLite 自增」（备份恢复语义），而原版默认规则的 id 是 -1/-2/…，
/// 必须原样保留——否则下一次「导入默认」的 `DELETE WHERE id < 0` 找不到
/// 上一批默认行，会越导越多。
pub fn txt_toc_rule_import_default() -> LegadoResult<i32> {
    with_database(|db| {
        let conn = db.connection();
        conn.execute("DELETE FROM txtTocRules WHERE id < 0", [])
            .map_err(|e| LegadoError::Database(format!("删除旧默认 TXT 目录规则失败: {e}")))?;
        let defaults = default_txt_toc_rules()?;
        for rule in &defaults {
            conn.execute(
                "INSERT OR REPLACE INTO txtTocRules
                 (id, name, rule, replacement, serialNumber, enable, example)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                rusqlite::params![
                    rule.id,
                    rule.name,
                    rule.rule,
                    rule.replacement,
                    rule.serial_number,
                    rule.enable as i32,
                    rule.example,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("写入默认 TXT 目录规则失败: {e}")))?;
        }
        Ok(defaults.len() as i32)
    })
}

fn find_by_name(db: &legado_db::Database, name: &str) -> LegadoResult<Option<TxtTocRuleRecord>> {
    let mut stmt = db
        .connection()
        .prepare(
            "SELECT id, name, rule, replacement, serialNumber, enable, example
             FROM txtTocRules WHERE name = ?1 LIMIT 1",
        )
        .map_err(|e| LegadoError::Database(format!("查询 TXT 目录规则失败: {e}")))?;
    let mut rows = stmt
        .query_map(rusqlite::params![name], |row| {
            Ok(TxtTocRuleRecord {
                id: row.get(0)?,
                name: row.get(1)?,
                rule: row.get(2)?,
                replacement: row.get(3)?,
                serial_number: row.get(4)?,
                enable: row.get::<_, i32>(5)? != 0,
                example: row.get(6)?,
            })
        })
        .map_err(|e| LegadoError::Database(format!("查询 TXT 目录规则失败: {e}")))?;
    match rows.next() {
        Some(row) => row
            .map(Some)
            .map_err(|e| LegadoError::Database(format!("解析 TXT 目录规则行失败: {e}"))),
        None => Ok(None),
    }
}

/// 内置默认规则（与 Flutter `assets/default_data/txtTocRule.json` 同源）
fn default_txt_toc_rules() -> LegadoResult<Vec<TxtTocRuleRecord>> {
    const DEFAULT_JSON: &str = include_str!("../../../assets/defaultData/txtTocRule.json");
    serde_json::from_str(DEFAULT_JSON)
        .map_err(|e| LegadoError::Database(format!("解析内置 TXT 目录规则失败: {e}")))
}

/// 解析导入内容（GSON 数组或单对象）
fn parse_import_rules(body: &str) -> LegadoResult<Vec<TxtTocRuleRecord>> {
    let trimmed = body.trim();
    if trimmed.is_empty() {
        return Err(LegadoError::Database("导入内容为空".to_string()));
    }
    let mut rules: Vec<TxtTocRuleRecord> = if trimmed.starts_with('[') {
        serde_json::from_str(trimmed)
            .map_err(|e| LegadoError::Database(format!("解析导入 JSON 数组失败: {e}")))?
    } else {
        let single: TxtTocRuleRecord = serde_json::from_str(trimmed)
            .map_err(|e| LegadoError::Database(format!("解析导入 JSON 单对象失败: {e}")))?;
        vec![single]
    };
    rules.retain(|r| !r.name.trim().is_empty() && !r.rule.trim().is_empty());
    for rule in &mut rules {
        rule.name = rule.name.trim().to_string();
    }
    Ok(rules)
}

/// 抓取 URL body（与字典规则导入同一链路）
fn fetch_url_body(url: &str) -> LegadoResult<String> {
    if url.trim().is_empty() {
        return Err(LegadoError::Database("导入 URL 为空".to_string()));
    }
    let analyze_url = legado_parser::AnalyzeUrl::parse(url, &std::collections::HashMap::new(), 1)
        .map_err(|e| LegadoError::Database(format!("解析导入 URL 失败: {e}")))?;
    crate::runtime::block_on(async {
        match tokio::time::timeout(
            std::time::Duration::from_secs(15),
            crate::api::dict_api::fetch_body(&analyze_url, None),
        )
        .await
        {
            Ok(result) => result.map_err(LegadoError::Database),
            Err(_) => Err(LegadoError::Database("导入 URL 请求超时".to_string())),
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn clear_rules() {
        let _ = with_database(|db| {
            db.connection()
                .execute("DELETE FROM txtTocRules", [])
                .map_err(|e| LegadoError::Database(format!("清空 txtTocRules 失败: {e}")))?;
            Ok(())
        });
    }

    #[test]
    fn test_txt_toc_rule_crud_roundtrip() {
        let _guard = crate::db_state::ensure_test_db();
        clear_rules();

        let id =
            txt_toc_rule_add("测试规则", "^第.+章", "第", true, Some("第一章 开端"), -1).unwrap();
        let rows = txt_toc_rule_list().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, id);
        assert_eq!(rows[0].name, "测试规则");
        assert!(rows[0].enable);
        assert_eq!(rows[0].example.as_deref(), Some("第一章 开端"));

        assert!(txt_toc_rule_update(id, "改名规则", "^卷.+", "", false, None, 3).unwrap());
        let rows = txt_toc_rule_list().unwrap();
        assert_eq!(rows[0].name, "改名规则");
        assert_eq!(rows[0].rule, "^卷.+");
        assert!(!rows[0].enable);
        assert_eq!(rows[0].serial_number, 3);

        assert!(txt_toc_rule_set_enabled(id, true).unwrap());
        assert!(txt_toc_rule_list().unwrap()[0].enable);

        assert!(txt_toc_rule_delete(id).unwrap());
        assert!(txt_toc_rule_list().unwrap().is_empty());
        assert!(!txt_toc_rule_delete(id).unwrap(), "重复删除返回 false");
        clear_rules();
    }

    #[test]
    fn test_txt_toc_rule_import_replaces_by_name() {
        let _guard = crate::db_state::ensure_test_db();
        clear_rules();

        let payload =
            r#"[{"name":"导入规则","rule":"^第","replacement":"","enable":true,"serialNumber":0}]"#;
        assert_eq!(txt_toc_rule_import(payload, "text").unwrap(), 1);
        let first = txt_toc_rule_list().unwrap();
        assert_eq!(first.len(), 1);
        let original_id = first[0].id;

        // 同名再导入：REPLACE 保留 id
        let payload2 = r#"[{"name":"导入规则","rule":"^卷","replacement":"x","enable":false,"serialNumber":5}]"#;
        assert_eq!(txt_toc_rule_import(payload2, "text").unwrap(), 1);
        let second = txt_toc_rule_list().unwrap();
        assert_eq!(second.len(), 1, "同名导入不得产生第二行");
        assert_eq!(second[0].id, original_id, "同名导入应保留原 id");
        assert_eq!(second[0].rule, "^卷");
        assert_eq!(second[0].replacement, "x");
        assert!(!second[0].enable);

        clear_rules();
    }

    #[test]
    fn test_txt_toc_rule_import_default_replaces_negative_ids() {
        let _guard = crate::db_state::ensure_test_db();
        clear_rules();

        // 用户自建规则（正 id）必须保留
        let user_id = txt_toc_rule_add("用户规则", "^用户", "", true, None, 99).unwrap();

        let n = txt_toc_rule_import_default().unwrap();
        assert!(n > 0, "内置默认规则不应为空");
        let rows = txt_toc_rule_list().unwrap();
        assert!(rows.iter().any(|r| r.id == user_id), "用户规则必须保留");
        assert!(rows.iter().any(|r| r.id < 0), "默认规则应保留负数 id");

        // 再次导入默认：负数 id 行数不增（deleteDefault + insert 幂等）
        let before = rows.len();
        txt_toc_rule_import_default().unwrap();
        assert_eq!(txt_toc_rule_list().unwrap().len(), before);

        clear_rules();
    }

    #[test]
    fn test_txt_toc_rule_reorder_rewrites_serial_numbers() {
        let _guard = crate::db_state::ensure_test_db();
        clear_rules();

        let a = txt_toc_rule_add("A", "^a", "", true, None, 0).unwrap();
        let b = txt_toc_rule_add("B", "^b", "", true, None, 1).unwrap();
        let ids = format!("[{b},{a}]");
        assert_eq!(txt_toc_rule_reorder(&ids).unwrap(), 2);

        let rows = txt_toc_rule_list().unwrap();
        assert_eq!(rows[0].id, b, "排序按 serialNumber：B 在前");
        assert_eq!(rows[0].serial_number, 0);
        assert_eq!(rows[1].id, a);
        assert_eq!(rows[1].serial_number, 1);

        clear_rules();
    }
}
