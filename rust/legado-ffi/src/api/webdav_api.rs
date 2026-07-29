//! WebDAV 云同步 FFI API
//!
//! 暴露 legado-net::webdav 的 WebDavClient + BookSyncManager 到 Flutter 端。
//! 支持：配置管理、目录列表、文件上传/下载、全量同步、增量同步。

use legado_core::LegadoResult;
use legado_net::webdav::{BookSyncManager, WebDavClient, WebDavConfig};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// 同步结果统计
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SyncResult {
    pub uploaded_count: usize,
    pub downloaded_count: usize,
    pub skipped_count: usize,
    pub conflict_count: usize,
    pub errors: Vec<String>,
    pub duration_ms: u64,
}

/// 冲突解决策略
#[derive(Debug, Clone, Copy, serde::Serialize, serde::Deserialize)]
pub enum ConflictResolution {
    /// 保留远端版本
    KeepRemote,
    /// 使用本地版本
    UseLocal,
    /// 合并两份内容
    Merge,
    /// 用户手动选择
    Manual,
}

/// 同步选项
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SyncOptions {
    pub max_concurrent_uploads: usize,
    pub chunk_size_bytes: usize,
    pub max_retry_attempts: u32,
    pub initial_retry_delay_ms: u64,
    pub max_retry_delay_ms: u64,
}

/// 列出 WebDAV 远程目录内容
///
/// # 参数
/// - `config_json`: WebDavConfig 的 JSON 序列化
/// - `path`: 远程目录路径（相对 remote_dir）
///
/// # 返回
/// JSON 序列化的 `Vec<WebDavFileInfo>`
pub fn webdav_list_dir(config_json: &str, path: &str) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    let files = rt.block_on(client.list_dir(path))?;
    serde_json::to_string(&files)
        .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))
}

/// 上传文件到 WebDAV
///
/// # 参数
/// - `config_json`: WebDavConfig JSON
/// - `path`: 远程文件路径
/// - `data`: 文件内容
pub fn webdav_upload(config_json: &str, path: &str, data: &str) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    rt.block_on(client.put(path, data.as_bytes()))
}

/// 从 WebDAV 下载文件
///
/// # 返回
/// 文件内容字符串
pub fn webdav_download(config_json: &str, path: &str) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    let bytes = rt.block_on(client.get(path))?;
    String::from_utf8(bytes)
        .map_err(|e| legado_core::LegadoError::Internal(format!("Invalid UTF-8: {e}")))
}

/// 删除 WebDAV 远程文件
pub fn webdav_delete(config_json: &str, path: &str) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    rt.block_on(client.delete(path))
}

/// 创建 WebDAV 远程目录
pub fn webdav_mkdir(config_json: &str, path: &str) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    rt.block_on(client.mkdir(path))
}

/// 全量同步（上传书架+书源，返回远端数据）
///
/// # 参数
/// - `config_json`: WebDavConfig JSON
/// - `local_books_json`: 本地书架数据 JSON
/// - `local_sources_json`: 本地书源数据 JSON
///
/// # 返回
/// JSON 对象 `{"books": "...", "sources": "..."}`
pub fn webdav_full_sync(
    config_json: &str,
    local_books_json: &str,
    local_sources_json: &str,
) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);
    let manager = BookSyncManager::new(client);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    let (books, sources) = rt.block_on(manager.full_sync(local_books_json, local_sources_json))?;

    serde_json::to_string(&serde_json::json!({
        "books": books,
        "sources": sources,
    }))
    .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败：{e}")))
}

/// 增量同步（上传书架 + 书源，返回远端数据及统计信息）
///
/// # 参数
/// - `config_json`: WebDavConfig JSON
/// - `local_books_json`: 本地书架数据 JSON
/// - `local_sources_json`: 本地书源数据 JSON
/// - `last_sync_time`: 上次同步时间戳 (秒)
///
/// # 返回
/// JSON 对象 `{"books": "...", "sources": "...", "result": {...}}`
pub fn webdav_incremental_sync(
    config_json: &str,
    local_books_json: &str,
    local_sources_json: &str,
    last_sync_time: Option<i64>,
) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败：{e}")))?;
    let client = WebDavClient::new(config);
    let manager = BookSyncManager::new(client);

    let rt = tokio::runtime::Handle::try_current()
        .unwrap_or_else(|_| tokio::runtime::Runtime::new().unwrap().handle().clone());
    let (books, sources, sync_result) = rt.block_on(
        manager.incremental_sync(local_books_json, local_sources_json, last_sync_time)
    )?;

    serde_json::to_string(&serde_json::json!({
        "books": books,
        "sources": sources,
        "result": {
            "uploaded_count": sync_result.uploaded_count,
            "downloaded_count": sync_result.downloaded_count,
            "skipped_count": sync_result.skipped_count,
            "conflict_count": sync_result.conflict_count,
            "errors": sync_result.errors,
            "duration_ms": sync_result.duration_ms,
        },
    }))
    .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败：{e}")))
}
