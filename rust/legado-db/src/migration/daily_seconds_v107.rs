//! Migration106To107 — readRecordDaily 单位归一（毫秒 → 秒）

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{table_exists, Migration};

/// 从 v106 升级到 v107
///
/// 变更内容：`readRecordDaily.durationSeconds` 的存量值由「毫秒」归一为「秒」。
///
/// 2026-08-29 引入的写路径（`upsert_read_record`）把毫秒增量写进了契约声明为秒的
/// 列（`readRecordDailyList` 返回 `[{date, seconds}]`），导致当日聚合值放大 1000 倍
/// ——热力图「每日时长」配色全天饱和、首页今日目标表盘恒满、按天视图显示「75天」级
/// 时长。写路径已改为按整秒差值入账；本迁移对既有行做一次性整除 1000 归一。
///
/// 幂等性由 `user_version` 门禁保证（仅升级到 v107 时执行一次）；迁移在数据库打开、
/// 任何写路径之前运行，故此刻表内所有行必为旧写路径所写。表为懒建表，不存在时跳过。
pub struct Migration106To107;

impl Migration for Migration106To107 {
    fn from_version(&self) -> u32 {
        106
    }

    fn to_version(&self) -> u32 {
        107
    }

    fn description(&self) -> &str {
        "readRecordDaily 单位归一（毫秒→秒）"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if table_exists(conn, "readRecordDaily")? {
            conn.execute(
                "UPDATE readRecordDaily SET durationSeconds = durationSeconds / 1000",
                [],
            )
            .map_err(|e| LegadoError::Database(format!("归一每日阅读时长单位失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration106To107: 单位归一不可逆".into(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::migration::MigrationRegistry;

    /// 存量毫秒值（含典型 1 小时量级）在迁移后归一为秒；经注册表同样推进到 v107
    #[test]
    fn test_migration_106_to_107_normalizes_daily_seconds() {
        // 直接调用 up：归一为秒（6541627ms → 6541s，999ms → 0s）
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "CREATE TABLE readRecordDaily (\
             date TEXT PRIMARY KEY,\
             durationSeconds INTEGER NOT NULL DEFAULT 0);\
             INSERT INTO readRecordDaily (date, durationSeconds) VALUES ('2026-09-06', 6541627);\
             INSERT INTO readRecordDaily (date, durationSeconds) VALUES ('2026-09-07', 999);",
        )
        .unwrap();
        Migration106To107.up(&conn).unwrap();
        assert_eq!(
            daily_rows(&conn),
            vec![
                ("2026-09-06".to_string(), 6541),
                ("2026-09-07".to_string(), 0),
            ],
            "存量毫秒值应整除 1000 归一为秒"
        );

        // 经注册表从 v106 升级：仅归一一次（user_version 门禁），版本推进到 107
        let conn2 = Connection::open_in_memory().unwrap();
        conn2
            .execute_batch(
                "CREATE TABLE readRecordDaily (\
                 date TEXT PRIMARY KEY,\
                 durationSeconds INTEGER NOT NULL DEFAULT 0);\
                 INSERT INTO readRecordDaily (date, durationSeconds) VALUES ('2026-09-06', 6541627);",
            )
            .unwrap();
        conn2.pragma_update(None, "user_version", 106).unwrap();
        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(&conn2).unwrap();
        assert_eq!(MigrationRegistry::current_version(&conn2).unwrap(), 107);
        assert_eq!(
            daily_rows(&conn2),
            vec![("2026-09-06".to_string(), 6541)],
            "注册表路径只归一一次，不可二次整除"
        );
    }

    fn daily_rows(conn: &Connection) -> Vec<(String, i64)> {
        let mut stmt = conn
            .prepare("SELECT date, durationSeconds FROM readRecordDaily ORDER BY date")
            .unwrap();
        let rows = stmt
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap()
            .filter_map(|r| r.ok())
            .collect();
        rows
    }

    /// 懒建表尚未创建时迁移应跳过而不报错
    #[test]
    fn test_migration_106_to_107_skips_missing_table() {
        let conn = Connection::open_in_memory().unwrap();
        conn.pragma_update(None, "user_version", 106).unwrap();
        Migration106To107.up(&conn).unwrap();
    }
}
