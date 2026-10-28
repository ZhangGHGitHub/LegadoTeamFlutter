//! Migration111To112 — 新增 `servers` 表（批8 用户裁决②）
//!
//! 语义对照原版 Room v104 `io.legado.app.data.AppDatabase/104.json` 的
//! `servers` 实体：`id` INTEGER NOT NULL 主键、`name` TEXT NOT NULL、
//! `type` TEXT NOT NULL、`config` TEXT、`sortNumber` INTEGER NOT NULL
//! （原版 `Server.kt`：id 默认 `System.currentTimeMillis()`，type 枚举
//! `WEBDAV`，config 为 WebDavConfig JSON 字符串）。我方此前无该表，
//! WebDAV 同步配置由 Flutter 偏好承载；本迁移只建表，不写任何种子行
//! （Flutter 侧一次性迁移负责把既有偏好落为 `id = -1` 的行）。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{table_exists, Migration};
use crate::schema::CREATE_SERVERS;

/// 从 v111 升级到 v112
///
/// 变更内容：创建 `servers` 表（逐列对齐原版 Room v104）。
///
/// 幂等：`user_version` 门禁（仅升级到 v112 时执行一次）+
/// `CREATE TABLE IF NOT EXISTS`；表已存在（全新库 init_schema 或重复执行）
/// 时为空操作。
pub struct Migration111To112;

impl Migration for Migration111To112 {
    fn from_version(&self) -> u32 {
        111
    }

    fn to_version(&self) -> u32 {
        112
    }

    fn description(&self) -> &str {
        "新增 servers 表（原版 Room v104 Server 实体：id/name/type/config/sortNumber）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        // 已存在则跳过（防御性：init_schema 已建表或重复执行）
        if table_exists(conn, "servers")? {
            return Ok(());
        }
        conn.execute_batch(CREATE_SERVERS)
            .map_err(|e| LegadoError::Database(format!("创建 servers 表失败: {e}")))?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration111To112: DROP TABLE not supported".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;
    use crate::schema;

    fn column_exists(conn: &Connection, column: &str) -> bool {
        conn.query_row(
            "SELECT COUNT(*) FROM pragma_table_info('servers') WHERE name = ?1",
            [column],
            |row| row.get::<_, i64>(0),
        )
        .map(|c| c > 0)
        .unwrap()
    }

    /// 建表后五列齐备，主键为 id（对齐原版 Room createSql）
    #[test]
    fn test_migration_111_to_112_creates_table() {
        let conn = Connection::open_in_memory().unwrap();
        Migration111To112.up(&conn).unwrap();

        for column in ["id", "name", "type", "config", "sortNumber"] {
            assert!(column_exists(&conn, column), "servers 表应含 {column} 列");
        }
        let pk: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('servers')
                 WHERE name = 'id' AND pk = 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(pk, 1, "id 应为唯一主键");
    }

    /// 重复执行幂等：不报错、既有行保留
    #[test]
    fn test_migration_111_to_112_idempotent() {
        let conn = Connection::open_in_memory().unwrap();
        Migration111To112.up(&conn).unwrap();
        conn.execute(
            "INSERT INTO servers (id, name, type, config, sortNumber)
             VALUES (-1, '默认', 'WEBDAV', '{\"url\":\"https://dav.example.com\"}', 0)",
            [],
        )
        .unwrap();
        Migration111To112.up(&conn).unwrap();
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM servers", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1, "幂等执行不应清空或重建既有数据");
    }

    /// 经注册表从 v111 升级到 v112：版本推进且只建一次
    #[test]
    fn test_migration_111_to_112_via_registry() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 111).unwrap();

        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn).unwrap();
        assert_eq!(
            MigrationRegistry::current_version(&conn).unwrap(),
            crate::schema::SCHEMA_VERSION,
            "注册表路径应推进版本到最新"
        );
        assert!(column_exists(&conn, "sortNumber"));
    }

    /// 全新库 init_schema 已建表，up 应为空操作
    #[test]
    fn test_migration_111_to_112_fresh_schema_is_noop() {
        let conn = Connection::open_in_memory().unwrap();
        schema::init_schema(&conn).unwrap();
        assert!(column_exists(&conn, "config"));
        Migration111To112.up(&conn).unwrap();
        assert!(column_exists(&conn, "config"));
    }
}
