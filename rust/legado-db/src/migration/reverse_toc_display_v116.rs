//! Migration115To116 — 书籍阅读配置 `reverseTocDisplay`（批31）
//!
//! 对齐原版 `Book.ReadConfig.reverseTocDisplay`（`Book.kt:502`）与
//! `BookDao.updateReverseTocDisplay`：目录页「显示反转」开关，仅展示层
//! 反序，章节数据顺序与 `index` 身份不变。
//!
//! **无 DDL**：`books.readConfig` 为 JSON TEXT 列（与原版 Room 同构），
//! 新键随 `ReadConfig` 序列化写入；旧库缺键由 `serde(default)` 读为
//! `false`，无需改写存量行。本迁移仅推进 `user_version` 记录数据契约
//! 版本（空操作、幂等），不做任何表结构或行数据变更。
//!
//! 为什么仍需要本迁移：`MigrationRegistry::migrate_to_latest` 只按注册
//! 表推进版本号；`SCHEMA_VERSION` 提升后若缺少 115→116 节点，旧库将
//! 永远停留在 v115（每次开库重复检查），且版本断言类测试失败。

use rusqlite::Connection;

use legado_core::LegadoResult;

use crate::migration::Migration;

/// 从 v115 升级到 v116（版本登记，无结构/数据变更）
pub struct Migration115To116;

impl Migration for Migration115To116 {
    fn from_version(&self) -> u32 {
        115
    }

    fn to_version(&self) -> u32 {
        116
    }

    fn description(&self) -> &str {
        "ReadConfig.reverseTocDisplay 数据契约登记（readConfig 为 JSON 列，无 DDL）"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        // 空操作：新键存于 readConfig JSON，旧库缺键按 serde 默认 false 读取
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        // 纯版本登记，回退只需降低 user_version（由注册表负责）
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use legado_core::models::ReadConfig;

    #[test]
    fn test_migration_115_to_116_keeps_read_config_untouched() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        // 存量行：readConfig 无 reverseTocDisplay 键
        conn.execute(
            "INSERT INTO books (bookUrl, readConfig) VALUES (?1, ?2)",
            rusqlite::params!["https://a.com/1", r#"{"reverseToc":true}"#],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 115).unwrap();

        Migration115To116.up(&conn).unwrap();

        let raw: String = conn
            .query_row(
                "SELECT readConfig FROM books WHERE bookUrl = 'https://a.com/1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(raw, r#"{"reverseToc":true}"#, "迁移不得改写存量 readConfig");
        let cfg: ReadConfig = serde_json::from_str(&raw).unwrap();
        assert!(cfg.reverse_toc);
        assert!(!cfg.reverse_toc_display, "缺键默认 false（旧库兼容）");
    }

    #[test]
    fn test_migration_115_to_116_via_registry_advances_version() {
        let conn = Connection::open_in_memory().unwrap();
        crate::schema::init_schema(&conn).unwrap();
        conn.pragma_update(None, "user_version", 115).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION,
            "注册表路径应把 v115 推进到最新"
        );

        // 重复执行幂等（版本已是最新，无迁移可跑）
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION
        );
    }
}
