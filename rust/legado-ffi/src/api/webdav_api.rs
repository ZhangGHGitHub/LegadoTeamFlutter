//! WebDAV 云同步 FFI API
//!
//! 暴露 legado-net::webdav 的 WebDavClient + BookSyncManager 到 Flutter 端。
//! 支持：配置管理、目录列表、文件上传/下载、全量同步、增量同步。
//!
//! 批8（用户裁决②）追加 servers 表 CRUD：列表/保存/删除委托
//! `legado-db::ServerRepository`（单实现），配置 JSON 入参签名全部不变。

use legado_core::{LegadoError, LegadoResult};
use legado_net::webdav::{BookSyncManager, WebDavClient, WebDavConfig};

use crate::db_state::with_database;

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

    let files = crate::runtime::block_on(client.list_dir(path))?;
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

    crate::runtime::block_on(client.put(path, data.as_bytes()))
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
    // 所有权直传，避免 put(&bytes) 内部的 to_vec 二次拷贝（Task #55 F3）
    crate::runtime::block_on(client.put_owned(path, bytes))
}

/// 从 WebDAV 下载文件
///
/// # 返回
/// 文件内容字符串
pub fn webdav_download(config_json: &str, path: &str) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let bytes = crate::runtime::block_on(client.get(path))?;
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

    let bytes = crate::runtime::block_on(client.get(path))?;

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

    crate::runtime::block_on(client.delete(path))
}

/// 清理 WebDAV 上的历史备份（批40，契约 §2.28）
///
/// 对齐原版 `AppWebDav.pruneOldBackups`：上传成功后按「WebDAV 备份保留
/// 数量」清理 `backup*.json`，先排除本次刚上传的 `current_file_name`，
/// 再按文件名降序保留 `keep_count - 1` 份历史备份。
///
/// - `keep_count = 0`：不清理（默认口径），直接返回空结果、不发网络请求；
/// - `backup*.zip`（原版/参考版备份）不参与清理（差异已在契约登记）；
/// - 单文件删除失败只记日志并计入 `failed`，不使整个调用失败。
///
/// # 返回
/// JSON 序列化的 [`legado_net::webdav::BackupPruneResult`]：
/// `{"deleted":["..."],"failed":[{"name":"...","error":"..."}]}`
pub fn webdav_prune_backups(
    config_json: &str,
    current_file_name: &str,
    keep_count: u32,
) -> LegadoResult<String> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    let result = crate::runtime::block_on(
        client.prune_backup_files(current_file_name, keep_count as usize),
    )?;
    serde_json::to_string(&result)
        .map_err(|e| legado_core::LegadoError::Internal(format!("序列化失败: {e}")))
}

/// 创建 WebDAV 远程目录
pub fn webdav_mkdir(config_json: &str, path: &str) -> LegadoResult<()> {
    let config: WebDavConfig = serde_json::from_str(config_json)
        .map_err(|e| legado_core::LegadoError::Internal(format!("WebDAV 配置解析失败: {e}")))?;
    let client = WebDavClient::new(config);

    crate::runtime::block_on(client.mkdir(path))
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

    let (books, sources) =
        crate::runtime::block_on(manager.full_sync(local_books_json, local_sources_json))?;

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

    let (books, sources, sync_result) = crate::runtime::block_on(manager.incremental_sync(
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

// ─── servers 表 CRUD（批8 用户裁决②，契约 §2.28）────────────────

/// 列出 servers 表全部服务器（`sortNumber` 升序），返回**裸 JSON 数组**
///
/// 元素形态对齐原版 `Server` 实体（`id`/`name`/`type`/`config`/`sortNumber`）。
/// 对齐原版 `ServerDao.all`（`order by sortNumber`）。
pub fn webdav_servers_list() -> LegadoResult<String> {
    let servers = with_database(|db| legado_db::ServerRepository::new(db.connection()).find_all())?;
    serde_json::to_string(&servers)
        .map_err(|e| LegadoError::Internal(format!("服务器列表序列化失败: {e}")))
}

/// 保存服务器配置（全字段 `INSERT OR REPLACE`），返回实际落库 id
///
/// 主键语义见 `ServerRepository::upsert`：id 为 0 时按当前毫秒分配；
/// 负数 id 原样保留（`-1` = 默认 WebDAV 同步账号固定身份）。
pub fn webdav_server_save(server_json: &str) -> LegadoResult<i64> {
    let server: legado_core::models::Server = serde_json::from_str(server_json)
        .map_err(|e| LegadoError::Internal(format!("服务器配置解析失败: {e}")))?;
    with_database(|db| legado_db::ServerRepository::new(db.connection()).upsert(&server))
}

/// 按 id 删除服务器配置；未命中返回 `false`（对齐 Room DELETE 静默语义）
pub fn webdav_server_delete(id: i64) -> LegadoResult<bool> {
    with_database(|db| legado_db::ServerRepository::new(db.connection()).delete(id))
}

#[cfg(test)]
mod tests {
    use super::*;

    // ─── 批40：多请求回环 WebDAV 夹具（上传/列目录/删除链路） ───────────

    /// 多请求回环 WebDAV 服务器（批40）
    ///
    /// 按 HTTP 方法返回固定响应，并记录 `(method, path)` 供断言：
    /// - `PROPFIND` → 207，返回目录自身 + [files] 列表（均为普通文件）；
    /// - `PUT` → 201 Created；
    /// - `DELETE` → [delete_fail] 命中返回 500，否则 204。
    ///
    /// 每个响应带 `Connection: close`，客户端会为下一次请求新建连接；
    /// 线程最多处理 [max_requests] 个请求后退出（避免测试挂死）。
    struct LoopbackDavServer {
        url: String,
        requests: std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>,
        handle: Option<std::thread::JoinHandle<()>>,
    }

    impl LoopbackDavServer {
        fn requests(&self) -> Vec<(String, String)> {
            self.requests.lock().unwrap().clone()
        }

        fn join(mut self) {
            if let Some(handle) = self.handle.take() {
                handle.join().ok();
            }
        }
    }

    fn spawn_loopback_dav(
        files: &[&str],
        delete_fail: &[&str],
        max_requests: usize,
    ) -> LoopbackDavServer {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        use std::sync::{Arc, Mutex};

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环 WebDAV");
        listener.set_nonblocking(true).expect("非阻塞监听");
        let port = listener.local_addr().unwrap().port();

        // 预生成 PROPFIND 响应体（目录自身 + files）
        let mut propfind_body = String::from(
            "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n",
        );
        propfind_body.push_str(
            "  <D:response><D:href>/dav/</D:href><D:propstat><D:prop>\
<D:displayname>dav</D:displayname><D:resourcetype><D:collection/></D:resourcetype>\
</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n",
        );
        for name in files {
            propfind_body.push_str(&format!(
                "  <D:response><D:href>/dav/{name}</D:href><D:propstat><D:prop>\
<D:displayname>{name}</D:displayname><D:getcontentlength>10</D:getcontentlength>\
</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"
            ));
        }
        propfind_body.push_str("</D:multistatus>");

        let requests = Arc::new(Mutex::new(Vec::new()));
        let requests_for_thread = Arc::clone(&requests);
        let delete_fail: Vec<String> = delete_fail.iter().map(|s| s.to_string()).collect();

        let handle = std::thread::spawn(move || {
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
            let mut handled = 0usize;
            while handled < max_requests && std::time::Instant::now() < deadline {
                let (mut stream, _) = match listener.accept() {
                    Ok(pair) => pair,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(5));
                        continue;
                    }
                    Err(_) => break,
                };
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(5)));

                // 读到请求头结束
                let mut head = Vec::new();
                let mut buf = [0u8; 4096];
                while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => head.extend_from_slice(&buf[..n]),
                        Err(_) => break,
                    }
                }
                let head_text = String::from_utf8_lossy(&head).to_string();
                let mut lines = head_text.split("\r\n");
                let request_line = lines.next().unwrap_or_default();
                let mut parts = request_line.split_whitespace();
                let method = parts.next().unwrap_or_default().to_string();
                let path = parts.next().unwrap_or_default().to_string();

                // 按 Content-Length 读完请求体（PUT 上传体）
                let mut content_length = 0usize;
                for line in lines {
                    let lower = line.to_ascii_lowercase();
                    if let Some(value) = lower.strip_prefix("content-length:") {
                        content_length = value.trim().parse().unwrap_or(0);
                    }
                }
                let body_start = head
                    .windows(4)
                    .position(|w| w == b"\r\n\r\n")
                    .map(|i| i + 4)
                    .unwrap_or(head.len());
                let mut remaining = content_length.saturating_sub(head.len() - body_start);
                while remaining > 0 {
                    match stream.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => remaining = remaining.saturating_sub(n),
                        Err(_) => break,
                    }
                }

                requests_for_thread
                    .lock()
                    .unwrap()
                    .push((method.clone(), path.clone()));

                let name = path.rsplit('/').next().unwrap_or_default();
                let response = match method.as_str() {
                    "PROPFIND" => format!(
                        "HTTP/1.1 207 Multi-Status\r\nContent-Type: application/xml; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                        propfind_body.len(),
                        propfind_body
                    ),
                    "PUT" => {
                        "HTTP/1.1 201 Created\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .to_string()
                    }
                    "DELETE" if delete_fail.iter().any(|n| n == name) => {
                        "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .to_string()
                    }
                    "DELETE" => {
                        "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .to_string()
                    }
                    _ => {
                        "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                            .to_string()
                    }
                };
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
                handled += 1;
            }
        });

        LoopbackDavServer {
            url: format!("http://127.0.0.1:{port}/dav/"),
            requests,
            handle: Some(handle),
        }
    }

    fn dav_config_json(url: &str) -> String {
        serde_json::json!({
            "url": url,
            "username": "u",
            "password": "p",
            "remote_dir": "",
        })
        .to_string()
    }

    /// 回环 WebDAV 服务器：接受一次 PROPFIND，返回固定 207 多状态响应。
    ///
    /// 返回 `(url, JoinHandle)`；url 形如 `http://127.0.0.1:<port>/dav/`。
    /// 仅用于验证「异步运行时可用」这一条链路（不校验请求体）。
    fn spawn_loopback_webdav() -> (String, std::thread::JoinHandle<()>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环 WebDAV");
        let port = listener.local_addr().unwrap().port();
        let body = r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:prop>
      <D:displayname>dav</D:displayname>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/books/</D:href>
    <D:propstat><D:prop>
      <D:displayname>books</D:displayname>
      <D:resourcetype><D:collection/></D:resourcetype>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/books/a.txt</D:href>
    <D:propstat><D:prop>
      <D:displayname>a.txt</D:displayname>
      <D:getcontentlength>3</D:getcontentlength>
    </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>"#;
        let response = format!(
            "HTTP/1.1 207 Multi-Status\r\nContent-Type: application/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let handle = std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                // 读请求头（PROPFIND 请求体不关心，读到空行为止）
                let mut buf = [0u8; 1024];
                let mut head = Vec::new();
                while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                    match stream.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => head.extend_from_slice(&buf[..n]),
                        Err(_) => break,
                    }
                }
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://127.0.0.1:{port}/dav/"), handle)
    }

    /// P0 回归（批18c）：WebDAV FFI 必须在可用的 tokio 运行时上 `block_on`。
    ///
    /// 旧实现 `webdav_runtime_handle()` 在函数内构建 `Runtime` 后只返回
    /// `rt.handle().clone()`，局部 `Runtime` 返回即 drop（IO driver 关闭），
    /// 后续 `Handle::block_on` 的请求在建立连接前失败：
    /// `error sending request for url (...)`。本用例用回环 WebDAV 服务器
    /// 覆盖真实网络 IO，旧实现必然失败，修复后必须拿到 3 个条目。
    #[test]
    fn test_webdav_list_dir_loopback_runtime_alive() {
        let (url, server) = spawn_loopback_webdav();
        let config_json = serde_json::json!({
            "url": url,
            "username": "u",
            "password": "p",
            "remote_dir": "",
        })
        .to_string();

        let raw = webdav_list_dir(&config_json, "").expect("回环 WebDAV 列目录应成功");
        let files: Vec<legado_net::webdav::WebDavFileInfo> =
            serde_json::from_str(&raw).expect("目录列表 JSON 可解析");
        server.join().ok();
        assert!(
            files.iter().any(|f| f.name == "a.txt"),
            "应列出子文件，实际: {files:?}"
        );
    }

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

    /// 清空 servers 表（共享测试库；调用方须持 ensure_test_db 串行锁）
    fn clear_servers() {
        with_database(|db| {
            db.connection()
                .execute("DELETE FROM servers", [])
                .map_err(|e| LegadoError::Database(format!("清空 servers 失败: {e}")))?;
            Ok(())
        })
        .unwrap();
    }

    /// [批8] 保存→列表→删除全链路（裸 JSON 数组 + 负数主键保留 + 全字段往返）
    #[test]
    fn test_servers_crud_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_servers();

        let seed = serde_json::json!({
            "id": -1,
            "name": "默认 WebDAV",
            "type": "WEBDAV",
            "config": "{\"url\":\"https://dav.example.com/\",\"username\":\"u\",\"password\":\"p\"}",
            "sortNumber": 1
        });
        let id = webdav_server_save(&seed.to_string()).unwrap();
        assert_eq!(id, -1, "负数主键应原样保留");

        let raw = webdav_servers_list().unwrap();
        let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert!(value.is_array(), "列表必须为裸 JSON 数组（§1.4 铁律）");
        let servers: Vec<legado_core::models::Server> = serde_json::from_str(&raw).unwrap();
        assert_eq!(servers.len(), 1);
        assert_eq!(servers[0].name, "默认 WebDAV");
        assert_eq!(servers[0].sort_number, 1);

        assert!(webdav_server_delete(-1).unwrap());
        assert!(!webdav_server_delete(-1).unwrap(), "重复删除应返回 false");
        assert_eq!(webdav_servers_list().unwrap(), "[]", "删除后列表应为空数组");
    }

    /// [批8] 非法 JSON / 未知 type 显式报错（不静默落库）
    #[test]
    fn test_server_save_rejects_invalid_shape() {
        let _db_guard = crate::db_state::ensure_test_db();
        clear_servers();

        let err = webdav_server_save("{invalid").expect_err("非法 JSON 应报错");
        assert!(matches!(err, LegadoError::Internal(_)));

        let err = webdav_server_save(r#"{"id":1,"type":"FTP"}"#).expect_err("未知 type 应报错");
        assert!(
            matches!(err, LegadoError::Internal(_)),
            "未知 type 应为 Internal（serde 解析失败），实际: {err:?}"
        );
    }

    // ─── 批40：WebDAV 备份上传 + 保留数清理（回环） ───────────────────

    /// [批40] 保留数清理：先排除本次上传文件，再按名称降序保留 N-1 份
    ///
    /// 夹具含 4 份 `backup_*.json`、1 份 `backup_*.zip`、1 份 `bookshelf.json`：
    /// 清理只处理 json 备份；keep=2 时保留最新历史 1 份 + 当前文件，
    /// 删除另外 2 份旧备份。
    #[test]
    fn test_webdav_prune_backups_keeps_latest_and_excludes_current() {
        let server = spawn_loopback_dav(
            &[
                "backup_20261001_000000.json",
                "backup_20261002_000000.json",
                "backup_20261003_000000.json",
                "backup_20261004_000000.json",
                "backup_20261001_000000.zip",
                "bookshelf.json",
            ],
            &[],
            3, // 1 次 PROPFIND + 2 次 DELETE
        );
        let raw = webdav_prune_backups(
            &dav_config_json(&server.url),
            "backup_20261004_000000.json",
            2,
        )
        .expect("清理应成功");
        server.join();

        let result: legado_net::webdav::BackupPruneResult =
            serde_json::from_str(&raw).expect("结果 JSON 可解析");
        assert_eq!(
            result.deleted,
            vec![
                "backup_20261002_000000.json".to_string(),
                "backup_20261001_000000.json".to_string()
            ],
            "应删除除当前文件与最新历史备份外的旧 JSON 备份"
        );
        assert!(result.failed.is_empty(), "不应有删除失败: {result:?}");
    }

    /// [批40] keep=0 不清理：不发任何网络请求（默认口径，保护存量备份）
    #[test]
    fn test_webdav_prune_backups_zero_does_nothing() {
        // URL 不可达也无妨：keep=0 在创建请求前就返回
        let raw = webdav_prune_backups(
            &dav_config_json("http://127.0.0.1:1/dav/"),
            "backup_20261004_000000.json",
            0,
        )
        .expect("keep=0 应直接成功");
        let result: legado_net::webdav::BackupPruneResult = serde_json::from_str(&raw).unwrap();
        assert!(result.deleted.is_empty());
        assert!(result.failed.is_empty());
    }

    /// [批40] 单个删除失败只记日志与失败清单，不影响其它删除
    #[test]
    fn test_webdav_prune_backups_delete_failure_recorded() {
        let server = spawn_loopback_dav(
            &[
                "backup_20261001_000000.json",
                "backup_20261002_000000.json",
                "backup_20261003_000000.json",
            ],
            &["backup_20261002_000000.json"],
            3, // 1 次 PROPFIND + 2 次 DELETE（其中一次 500）
        );
        let raw = webdav_prune_backups(
            &dav_config_json(&server.url),
            "backup_20261003_000000.json",
            1,
        )
        .expect("清理应成功（单文件失败不使整次失败）");
        server.join();

        let result: legado_net::webdav::BackupPruneResult = serde_json::from_str(&raw).unwrap();
        assert_eq!(
            result.deleted,
            vec!["backup_20261001_000000.json".to_string()]
        );
        assert_eq!(result.failed.len(), 1, "失败清单应记录 1 条: {result:?}");
        assert_eq!(result.failed[0].name, "backup_20261002_000000.json");
        assert!(
            result.failed[0].error.contains("500"),
            "失败原因应含状态码: {:?}",
            result.failed[0].error
        );
    }

    /// [批40] 上传（PUT）+ 清理（PROPFIND/DELETE）回环全链路
    #[test]
    fn test_webdav_upload_file_then_prune_loopback() {
        // 本地临时备份文件
        let dir = std::env::temp_dir().join("legado_webdav_backup_upload_prune");
        std::fs::create_dir_all(&dir).unwrap();
        let local_file = dir.join("legado_backup_local.json");
        std::fs::write(&local_file, br#"{"version":5}"#).unwrap();

        let server = spawn_loopback_dav(
            &[
                "backup_20261001_000000.json",
                "backup_20261002_000000.json",
                "backup_20261003_000000.json",
            ],
            &[],
            3, // 1 次 PUT + 1 次 PROPFIND + 1 次 DELETE
        );
        let config = dav_config_json(&server.url);
        webdav_upload_file(
            &config,
            "backup_20261003_120000.json",
            local_file.to_str().unwrap(),
        )
        .expect("上传应成功");

        let raw =
            webdav_prune_backups(&config, "backup_20261003_120000.json", 2).expect("清理应成功");
        let requests = server.requests();
        server.join();

        let result: legado_net::webdav::BackupPruneResult = serde_json::from_str(&raw).unwrap();
        assert_eq!(
            result.deleted,
            vec!["backup_20261002_000000.json".to_string()]
        );

        assert_eq!(requests.len(), 3, "请求序列: {requests:?}");
        assert_eq!(requests[0].0, "PUT");
        assert_eq!(requests[0].1, "/dav/backup_20261003_120000.json");
        assert_eq!(requests[1].0, "PROPFIND");
        assert_eq!(
            requests[2],
            (
                "DELETE".to_string(),
                "/dav/backup_20261002_000000.json".to_string()
            )
        );

        std::fs::remove_dir_all(&dir).ok();
    }
}
