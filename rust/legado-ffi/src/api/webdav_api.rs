//! WebDAV 云同步 FFI API
//!
//! 暴露 legado-net::webdav 的 WebDavClient + BookSyncManager 到 Flutter 端。
//! 支持：配置管理、目录列表、文件上传/下载、全量同步、增量同步。

use legado_core::{LegadoError, LegadoResult};
use legado_net::webdav::{BookSyncManager, WebDavClient, WebDavConfig};

/// 获取 WebDAV 异步运行时句柄（优先当前 tokio 运行时，否则惰性创建兜底 runtime）
fn webdav_runtime_handle() -> LegadoResult<tokio::runtime::Handle> {
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        return Ok(handle);
    }
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("legado-webdav-fallback")
        .thread_stack_size(8 * 1024 * 1024)
        .build()
        .map(|rt| rt.handle().clone())
        .map_err(|e| LegadoError::Internal(format!("创建 WebDAV 运行时失败: {e}")))
}

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

    let rt = webdav_runtime_handle()?;
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

    let rt = webdav_runtime_handle()?;
    rt.block_on(client.put(path, data.as_bytes()))
}

/// 从本地文件路径读取并上传到 WebDAV（Task #51，API_CONTRACT §2.28.6）
///
/// 区别于既有 [`webdav_upload`] 的 String data 直传，本方法面向大文件
/// 场景（如书籍上传至远程）：从 `local_file_path` 读取字节后复用既有
/// WebDAV 客户端 PUT。既有 `webdav_upload` 签名与行为保持不变。
///
/// 内存占用说明（Task #55 F3）：文件字节以所有权直传 `put_owned`，
/// 全程仅一份内存拷贝；但仍是整文件驻留内存后提交，超大文件
/// （超出可用内存）存在内存上限风险，完整流式上传改造另行立项。
///
/// # 错误码
/// - 配置解析失败 → Internal
/// - 文件不存在/读取失败 → Io
/// - 上传失败（含非 2xx 响应，Task #55 F1）→ Network
pub fn webdav_upload_file(
    config_json: &str,
    path: &str,
    local_file_path: &str,
) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;

    // 本地文件读取（不存在/无权限/读失败 → Io 错误）
    let bytes = std::fs::read(local_file_path).map_err(|e| {
        legado_core::LegadoError::Io(std::io::Error::new(
            e.kind(),
            format!("读取本地文件失败: {local_file_path}: {e}"),
        ))
    })?;

    let client = WebDavClient::new(config);
    let rt = webdav_runtime_handle()?;
    // 所有权直传，避免 put(&bytes) 内部的 to_vec 二次拷贝（Task #55 F3）
    rt.block_on(client.put_owned(path, bytes))
}

/// 从 WebDAV 下载文件
///
/// # 返回
/// 文件内容字符串
pub fn webdav_download(config_json: &str, path: &str) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = webdav_runtime_handle()?;
    let bytes = rt.block_on(client.get(path))?;
    String::from_utf8(bytes)
        .map_err(|e| legado_core::LegadoError::Internal(format!("Invalid UTF-8: {e}")))
}

/// 从 WebDAV 下载二进制到本地文件（API_CONTRACT §2.28，P1-5）
///
/// 镜像 [`webdav_upload_file`]：将远端字节写入 `local_file_path`。
pub fn webdav_download_file(
    config_json: &str,
    path: &str,
    local_file_path: &str,
) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = webdav_runtime_handle()?;
    let bytes = rt.block_on(client.get(path))?;

    if let Some(parent) = std::path::Path::new(local_file_path).parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| {
                legado_core::LegadoError::Io(std::io::Error::new(
                    e.kind(),
                    format!("创建父目录失败: {parent:?}: {e}"),
                ))
            })?;
        }
    }
    std::fs::write(local_file_path, bytes).map_err(|e| {
        legado_core::LegadoError::Io(std::io::Error::new(
            e.kind(),
            format!("写入本地文件失败: {local_file_path}: {e}"),
        ))
    })?;
    Ok(())
}

/// 删除 WebDAV 远程文件
pub fn webdav_delete(config_json: &str, path: &str) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = webdav_runtime_handle()?;
    rt.block_on(client.delete(path))
}

/// 创建 WebDAV 远程目录
pub fn webdav_mkdir(config_json: &str, path: &str) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let rt = webdav_runtime_handle()?;
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

    let rt = webdav_runtime_handle()?;
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

    let rt = webdav_runtime_handle()?;
    let (books, sources, sync_result) = rt.block_on(manager.incremental_sync(
        local_books_json,
        local_sources_json,
        last_sync_time,
    ))?;

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

#[cfg(test)]
mod tests {
    use super::*;

    /// Task #51：配置解析失败 → Internal 错误
    #[test]
    fn test_webdav_upload_file_bad_config() {
        let err = webdav_upload_file("{invalid json", "/remote/book.epub", "C:/tmp/x.epub")
            .expect_err("非法配置应报错");
        assert!(
            matches!(err, legado_core::LegadoError::Internal(_)),
            "配置解析失败应为 Internal 错误，实际: {err:?}"
        );
    }

    /// Task #51：本地文件不存在 → Io 错误
    #[test]
    fn test_webdav_upload_file_missing_file() {
        let config_json = serde_json::json!({
            "url": "https://dav.example.com",
            "username": "user",
            "password": "pass",
            "remote_dir": "/legado",
        })
        .to_string();
        let err = webdav_upload_file(
            &config_json,
            "/remote/book.epub",
            "__definitely_missing_file__.bin",
        )
        .expect_err("文件不存在应报错");
        assert!(
            matches!(err, legado_core::LegadoError::Io(_)),
            "文件不存在应为 Io 错误，实际: {err:?}"
        );
    }
}
