//! 书源管理 API
//!
//! 提供书源的增删改查、启用/禁用、批量导入/导出操作。

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::BookSourceRepository;

use crate::db_state::with_database;

/// 获取所有书源
pub fn list_sources() -> LegadoResult<Vec<BookSource>> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_all()
    })
}

/// 添加书源（JSON 序列化传入）
pub fn add_source(source_json: &str) -> LegadoResult<BookSource> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("BookSource JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.insert(&source)?;
        Ok(source)
    })
}

/// 更新书源
pub fn update_source(source_json: &str) -> LegadoResult<()> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("BookSource JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.update(&source)
    })
}

/// 按 URL 删除书源
pub fn delete_source(source_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.delete(source_url)
    })
}

/// 启用书源
pub fn enable_source(source_url: &str) -> LegadoResult<()> {
    set_source_enabled(source_url, true)
}

/// 禁用书源
pub fn disable_source(source_url: &str) -> LegadoResult<()> {
    set_source_enabled(source_url, false)
}

/// 设置书源启用状态
fn set_source_enabled(source_url: &str, enabled: bool) -> LegadoResult<()> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        let mut source = repo
            .find_by_url(source_url)?
            .ok_or_else(|| LegadoError::Database("书源不存在".into()))?;
        source.enabled = enabled;
        repo.update(&source)
    })
}

/// 批量导入书源（JSON 数组）
pub fn import_sources(json_array: &str) -> LegadoResult<i32> {
    let sources: Vec<BookSource> = serde_json::from_str(json_array)
        .map_err(|e| LegadoError::Ffi(format!("书源 JSON 数组解析失败: {e}")))?;
    let count = sources.len() as i32;
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        for source in &sources {
            repo.insert(source)?;
        }
        Ok(count)
    })
}

/// 导出所有书源为 JSON 数组
pub fn export_sources() -> LegadoResult<Vec<BookSource>> {
    list_sources()
}

/// 获取所有启用的书源
pub fn list_enabled_sources() -> LegadoResult<Vec<BookSource>> {
    with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_enabled()
    })
}
