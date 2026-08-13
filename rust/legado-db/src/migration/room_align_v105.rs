//! Migration104To105 — D1：rule_subs/dict_rules/keyboard_assists 对齐 Room 表名列名
//!
//! 目标表名：`ruleSubs` / `dictRules` / `keyboardAssists`（对齐 Android Room entity）。
//! 幂等：目标表已存在且主键/关键列已对齐则跳过；迁移后删除旧 snake_case 表。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{column_exists, primary_key_columns, table_exists, Migration};
use crate::schema::{CREATE_DICT_RULES, CREATE_KEYBOARD_ASSISTS, CREATE_RULE_SUBS};

/// 从 v104 升级到 v105（D1 Room 表名/列名对齐）
pub struct Migration104To105;

impl Migration for Migration104To105 {
    fn from_version(&self) -> u32 {
        104
    }
    fn to_version(&self) -> u32 {
        105
    }
    fn description(&self) -> &str {
        "D1：ruleSubs/dictRules/keyboardAssists 对齐 Room 表名列名"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        migrate_dict_rules(conn)?;
        migrate_keyboard_assists(conn)?;
        migrate_rule_subs(conn)?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration104To105: table rebuilds are one-way".into(),
        ))
    }
}

fn migrate_dict_rules(conn: &Connection) -> LegadoResult<()> {
    // 已对齐：存在 dictRules 且含 urlRule 列
    if table_exists(conn, "dictRules")? && column_exists(conn, "dictRules", "urlRule")? {
        if table_exists(conn, "dict_rules")? {
            conn.execute_batch("DROP TABLE IF EXISTS dict_rules")
                .map_err(|e| LegadoError::Database(format!("删除旧 dict_rules 失败: {e}")))?;
        }
        return Ok(());
    }

    conn.execute_batch(CREATE_DICT_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 dictRules 失败: {e}")))?;

    if table_exists(conn, "dict_rules")? {
        let has_url_rule = column_exists(conn, "dict_rules", "url_rule")?;
        let has_url_rule_camel = column_exists(conn, "dict_rules", "urlRule")?;
        let (url_e, show_e, en_e, sort_e) = if has_url_rule {
            (
                "COALESCE(url_rule, '')",
                "COALESCE(show_rule, '')",
                "COALESCE(is_enabled, 1)",
                "COALESCE(sort_order, 0)",
            )
        } else if has_url_rule_camel {
            (
                "COALESCE(urlRule, '')",
                "COALESCE(showRule, '')",
                "COALESCE(enabled, 1)",
                "COALESCE(sortNumber, 0)",
            )
        } else {
            ("''", "''", "1", "0")
        };

        let sql = if has_url_rule {
            format!(
                "INSERT OR IGNORE INTO dictRules (id, name, urlRule, showRule, enabled, sortNumber)
                 SELECT id, name, {url_e}, {show_e}, {en_e}, {sort_e}
                 FROM dict_rules
                 ORDER BY COALESCE(sort_order, 0) ASC, id ASC"
            )
        } else {
            format!(
                "INSERT OR IGNORE INTO dictRules (id, name, urlRule, showRule, enabled, sortNumber)
                 SELECT id, name, {url_e}, {show_e}, {en_e}, {sort_e}
                 FROM dict_rules
                 ORDER BY id ASC"
            )
        };
        conn.execute_batch(&sql)
            .map_err(|e| LegadoError::Database(format!("迁移 dict_rules→dictRules 失败: {e}")))?;
        conn.execute_batch("DROP TABLE IF EXISTS dict_rules")
            .map_err(|e| LegadoError::Database(format!("删除旧 dict_rules 失败: {e}")))?;
    }
    Ok(())
}

fn migrate_keyboard_assists(conn: &Connection) -> LegadoResult<()> {
    if table_exists(conn, "keyboardAssists")? {
        let pk = primary_key_columns(conn, "keyboardAssists")?;
        if pk == ["type", "key"] {
            if table_exists(conn, "keyboard_assists")? {
                conn.execute_batch("DROP TABLE IF EXISTS keyboard_assists")
                    .map_err(|e| {
                        LegadoError::Database(format!("删除旧 keyboard_assists 失败: {e}"))
                    })?;
            }
            return Ok(());
        }
        // 形态不对：重建
        conn.execute_batch("DROP TABLE IF EXISTS keyboardAssists")
            .map_err(|e| LegadoError::Database(format!("删除畸形 keyboardAssists 失败: {e}")))?;
    }

    conn.execute_batch(CREATE_KEYBOARD_ASSISTS)
        .map_err(|e| LegadoError::Database(format!("创建 keyboardAssists 失败: {e}")))?;

    if table_exists(conn, "keyboard_assists")? {
        // 旧表：name 存 type 字符串；sort_order → serialNo
        let has_name = column_exists(conn, "keyboard_assists", "name")?;
        let has_type = column_exists(conn, "keyboard_assists", "type")?;
        let type_e = if has_type {
            "COALESCE(type, 0)".to_string()
        } else if has_name {
            "CAST(COALESCE(name, '0') AS INTEGER)".to_string()
        } else {
            "0".to_string()
        };
        let serial_e = if column_exists(conn, "keyboard_assists", "sort_order")? {
            "COALESCE(sort_order, 0)".to_string()
        } else if column_exists(conn, "keyboard_assists", "serialNo")? {
            "COALESCE(serialNo, 0)".to_string()
        } else {
            "0".to_string()
        };
        let sql = format!(
            "INSERT OR IGNORE INTO keyboardAssists (type, key, value, serialNo)
             SELECT {type_e}, key, COALESCE(value, ''), {serial_e}
             FROM keyboard_assists
             ORDER BY {serial_e} ASC, rowid ASC"
        );
        conn.execute_batch(&sql).map_err(|e| {
            LegadoError::Database(format!("迁移 keyboard_assists→keyboardAssists 失败: {e}"))
        })?;
        conn.execute_batch("DROP TABLE IF EXISTS keyboard_assists")
            .map_err(|e| LegadoError::Database(format!("删除旧 keyboard_assists 失败: {e}")))?;
    }
    Ok(())
}

fn migrate_rule_subs(conn: &Connection) -> LegadoResult<()> {
    if table_exists(conn, "ruleSubs")? && column_exists(conn, "ruleSubs", "customOrder")? {
        if table_exists(conn, "rule_subs")? {
            conn.execute_batch("DROP TABLE IF EXISTS rule_subs")
                .map_err(|e| LegadoError::Database(format!("删除旧 rule_subs 失败: {e}")))?;
        }
        return Ok(());
    }

    conn.execute_batch(CREATE_RULE_SUBS)
        .map_err(|e| LegadoError::Database(format!("创建 ruleSubs 失败: {e}")))?;

    if table_exists(conn, "rule_subs")? {
        // sub_type TEXT → type Int（0 书源 / 1 订阅源 / 3 替换规则）
        let type_e = if column_exists(conn, "rule_subs", "type")? {
            "COALESCE(type, 0)".to_string()
        } else if column_exists(conn, "rule_subs", "sub_type")? {
            "CASE sub_type
                WHEN 'rssSource' THEN 1
                WHEN 'replaceRule' THEN 3
                ELSE 0
             END"
            .to_string()
        } else {
            "0".to_string()
        };

        let update_e = if column_exists(conn, "rule_subs", "update")? {
            "COALESCE(\"update\", 0)".to_string()
        } else if column_exists(conn, "rule_subs", "last_update")? {
            "COALESCE(last_update, 0)".to_string()
        } else {
            "0".to_string()
        };

        let custom_e = if column_exists(conn, "rule_subs", "customOrder")? {
            "COALESCE(customOrder, 0)".to_string()
        } else if column_exists(conn, "rule_subs", "custom_order")? {
            "COALESCE(custom_order, 0)".to_string()
        } else {
            "0".to_string()
        };

        let auto_e = col_bool(conn, "rule_subs", &["autoUpdate", "auto_update"], "0")?;
        let interval_e =
            col_int(conn, "rule_subs", &["updateInterval", "update_interval"], "0")?;
        let silent_e =
            col_bool(conn, "rule_subs", &["silentUpdate", "silent_update"], "0")?;
        let js_e = col_text(conn, "rule_subs", &["js"], "NULL")?;
        let show_e = col_text(conn, "rule_subs", &["showRule", "show_rule"], "NULL")?;
        let source_e = col_text(conn, "rule_subs", &["sourceUrl", "source_url"], "NULL")?;
        let version_e = col_text(conn, "rule_subs", &["version"], "''")?;
        let enabled_e =
            col_bool(conn, "rule_subs", &["isEnabled", "is_enabled"], "1")?;
        let created_e =
            col_int(conn, "rule_subs", &["createdAt", "created_at"], "0")?;

        let sql = format!(
            r#"INSERT OR IGNORE INTO ruleSubs (
                id, name, url, type, customOrder, autoUpdate, "update",
                updateInterval, silentUpdate, js, showRule, sourceUrl,
                version, isEnabled, createdAt
             )
             SELECT
                id,
                COALESCE(name, ''),
                COALESCE(url, ''),
                {type_e},
                {custom_e},
                {auto_e},
                {update_e},
                {interval_e},
                {silent_e},
                {js_e},
                {show_e},
                {source_e},
                {version_e},
                {enabled_e},
                {created_e}
             FROM rule_subs
             ORDER BY {custom_e} ASC, id ASC"#
        );
        conn.execute_batch(&sql)
            .map_err(|e| LegadoError::Database(format!("迁移 rule_subs→ruleSubs 失败: {e}")))?;
        conn.execute_batch("DROP TABLE IF EXISTS rule_subs")
            .map_err(|e| LegadoError::Database(format!("删除旧 rule_subs 失败: {e}")))?;
    }
    Ok(())
}

fn col_int(
    conn: &Connection,
    table: &str,
    candidates: &[&str],
    default: &str,
) -> LegadoResult<String> {
    for c in candidates {
        if column_exists(conn, table, c)? {
            return Ok(format!("COALESCE(\"{c}\", {default})"));
        }
    }
    Ok(default.to_string())
}

fn col_bool(
    conn: &Connection,
    table: &str,
    candidates: &[&str],
    default: &str,
) -> LegadoResult<String> {
    col_int(conn, table, candidates, default)
}

fn col_text(
    conn: &Connection,
    table: &str,
    candidates: &[&str],
    default: &str,
) -> LegadoResult<String> {
    for c in candidates {
        if column_exists(conn, table, c)? {
            return Ok(c.to_string());
        }
    }
    Ok(default.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::Database;
    use crate::migration::{column_exists, primary_key_columns, table_exists};

    #[test]
    fn test_migration_104_to_105_room_align() {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            r#"
            CREATE TABLE dict_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                url_rule TEXT DEFAULT '',
                show_rule TEXT DEFAULT '',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE keyboard_assists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                key TEXT NOT NULL,
                value TEXT DEFAULT '',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                sort_order INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE rule_subs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                name TEXT NOT NULL DEFAULT '',
                sub_type TEXT NOT NULL DEFAULT 'bookSource',
                last_update INTEGER NOT NULL DEFAULT 0,
                version TEXT DEFAULT '',
                is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL,
                custom_order INTEGER NOT NULL DEFAULT 0,
                auto_update INTEGER NOT NULL DEFAULT 0,
                update_interval INTEGER NOT NULL DEFAULT 0,
                silent_update INTEGER NOT NULL DEFAULT 0,
                js TEXT,
                show_rule TEXT,
                source_url TEXT
            );
            "#,
        )
        .unwrap();

        conn.execute(
            "INSERT INTO dict_rules (name, url_rule, show_rule, is_enabled, sort_order)
             VALUES ('海词', 'https://h.any/{{key}}', 'tag.body', 1, 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO keyboard_assists (name, key, value, is_enabled, sort_order)
             VALUES ('0', '@css:', '@css:', 1, 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO rule_subs (url, name, sub_type, last_update, version, is_enabled, created_at, custom_order)
             VALUES ('https://ex.com/s.json', '书源', 'bookSource', 100, '1', 1, 50, 2),
                    ('https://ex.com/r.json', '替换', 'replaceRule', 200, '2', 1, 60, 1)",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 104).unwrap();

        let m = Migration104To105;
        m.up(conn).unwrap();
        m.up(conn).unwrap(); // 幂等

        assert!(table_exists(conn, "dictRules").unwrap());
        assert!(!table_exists(conn, "dict_rules").unwrap());
        assert!(column_exists(conn, "dictRules", "urlRule").unwrap());
        assert!(column_exists(conn, "dictRules", "sortNumber").unwrap());

        assert!(table_exists(conn, "keyboardAssists").unwrap());
        assert!(!table_exists(conn, "keyboard_assists").unwrap());
        assert_eq!(
            primary_key_columns(conn, "keyboardAssists").unwrap(),
            vec!["type", "key"]
        );

        assert!(table_exists(conn, "ruleSubs").unwrap());
        assert!(!table_exists(conn, "rule_subs").unwrap());
        assert!(column_exists(conn, "ruleSubs", "customOrder").unwrap());
        assert!(column_exists(conn, "ruleSubs", "showRule").unwrap());

        let dict_name: String = conn
            .query_row("SELECT name FROM dictRules", [], |r| r.get(0))
            .unwrap();
        assert_eq!(dict_name, "海词");

        let (k_type, k_key): (i32, String) = conn
            .query_row("SELECT type, key FROM keyboardAssists", [], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap();
        assert_eq!(k_type, 0);
        assert_eq!(k_key, "@css:");

        let (r_type, r_name): (i32, String) = conn
            .query_row(
                "SELECT type, name FROM ruleSubs WHERE url = 'https://ex.com/r.json'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .unwrap();
        assert_eq!(r_type, 3);
        assert_eq!(r_name, "替换");
    }
}
