//! 各版本迁移实现
//!
//! 基于 Room schema 差异分析：
//! - v90 → v91: book_sources 新增 `mainJs` 列
//! - v91 → v92: 无结构变化（Room identityHash 变更）
//! - v92 → v93: 无结构变化
//! - v93 → v94: 新增 `auto_task_rules` 表
//! - v94 → v95: 无结构变化

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{add_column_if_not_exists, table_exists, Migration};
use crate::schema::CREATE_AUTO_TASK_RULES;

// ---------------------------------------------------------------------------
// v90 → v91: book_sources 新增 mainJs 列
// ---------------------------------------------------------------------------

/// 从 v90 升级到 v91
///
/// 变更内容：book_sources 表新增 `mainJs` TEXT 列
pub struct Migration90To91;

impl Migration for Migration90To91 {
    fn from_version(&self) -> u32 {
        90
    }
    fn to_version(&self) -> u32 {
        91
    }
    fn description(&self) -> &str {
        "book_sources 新增 mainJs 列"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        add_column_if_not_exists(conn, "book_sources", "mainJs", "TEXT")?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        // SQLite 不支持 DROP COLUMN（旧版本），需重建表
        Err(LegadoError::Database(
            "Cannot safely rollback Migration90To91: DROP COLUMN not supported".into(),
        ))
    }
}

// ---------------------------------------------------------------------------
// v91 → v92: 无结构变化
// ---------------------------------------------------------------------------

/// 从 v91 升级到 v92
///
/// 变更内容：无表结构变化（Room 内部 identityHash 变更）
pub struct Migration91To92;

impl Migration for Migration91To92 {
    fn from_version(&self) -> u32 {
        91
    }
    fn to_version(&self) -> u32 {
        92
    }
    fn description(&self) -> &str {
        "无结构变化 (Room identityHash 更新)"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        // 无结构变化，仅更新版本号
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v92 → v93: 无结构变化
// ---------------------------------------------------------------------------

/// 从 v92 升级到 v93
///
/// 变更内容：无表结构变化
pub struct Migration92To93;

impl Migration for Migration92To93 {
    fn from_version(&self) -> u32 {
        92
    }
    fn to_version(&self) -> u32 {
        93
    }
    fn description(&self) -> &str {
        "无结构变化 (Room identityHash 更新)"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v93 → v94: 新增 auto_task_rules 表
// ---------------------------------------------------------------------------

/// 从 v93 升级到 v94
///
/// 变更内容：新增 `auto_task_rules` 表
pub struct Migration93To94;

impl Migration for Migration93To94 {
    fn from_version(&self) -> u32 {
        93
    }
    fn to_version(&self) -> u32 {
        94
    }
    fn description(&self) -> &str {
        "新增 auto_task_rules 表"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        if !table_exists(conn, "auto_task_rules")? {
            conn.execute_batch(CREATE_AUTO_TASK_RULES)
                .map_err(|e| LegadoError::Database(format!("创建 auto_task_rules 表失败: {e}")))?;
        }
        Ok(())
    }

    fn down(&self, conn: &Connection) -> LegadoResult<()> {
        conn.execute_batch("DROP TABLE IF EXISTS auto_task_rules;")
            .map_err(|e| LegadoError::Database(format!("删除 auto_task_rules 表失败: {e}")))?;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// v94 → v95: 无结构变化
// ---------------------------------------------------------------------------

/// 从 v94 升级到 v95
///
/// 变更内容：无表结构变化
pub struct Migration94To95;

impl Migration for Migration94To95 {
    fn from_version(&self) -> u32 {
        94
    }
    fn to_version(&self) -> u32 {
        95
    }
    fn description(&self) -> &str {
        "无结构变化 (Room identityHash 更新)"
    }

    fn up(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Ok(())
    }
}
