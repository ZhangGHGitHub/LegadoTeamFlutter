//! WebDAV 客户端 — 用于书籍数据云端同步
//!
//! 支持 WebDAV 协议的基本操作：PROPFIND, PUT, GET, DELETE, MKCOL
//! 支持增量同步、冲突检测、冲突合并、断点续传

use legado_core::{LegadoError, LegadoResult};
use std::collections::HashMap;
use std::time::Duration;

/// WebDAV 客户端配置
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WebDavConfig {
    pub url: String,
    pub username: String,
    pub password: String,
    pub remote_dir: String,
}

/// WebDAV 文件信息
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WebDavFileInfo {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub last_modified: Option<String>,
    pub etag: Option<String>,
    pub is_dir: bool,
}

/// WebDAV 客户端
pub struct WebDavClient {
    config: WebDavConfig,
    client: reqwest::Client,
}

impl WebDavClient {
    pub fn new(config: WebDavConfig) -> Self {
        let client = reqwest::Client::builder()
            .dns_resolver(crate::custom_hosts::resolver())
            .build()
            .unwrap_or_else(|_| reqwest::Client::new());
        Self { config, client }
    }

    fn auth_header(&self) -> String {
        use base64::Engine;
        let credentials = format!("{}:{}", self.config.username, self.config.password);
        let encoded = base64::engine::general_purpose::STANDARD.encode(credentials);
        format!("Basic {}", encoded)
    }

    fn full_url(&self, path: &str) -> String {
        format!("{}{}{}", self.config.url, self.config.remote_dir, path)
    }

    /// PROPFIND — 列出目录内容
    pub async fn list_dir(&self, path: &str) -> LegadoResult<Vec<WebDavFileInfo>> {
        let url = self.full_url(path);
        let body = r#"<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:getetag/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>"#;

        let response = self
            .client
            .request(reqwest::Method::from_bytes(b"PROPFIND").unwrap(), &url)
            .header("Authorization", self.auth_header())
            .header("Depth", "1")
            .header("Content-Type", "application/xml")
            .body(body)
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;

        let xml = response
            .text()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;

        Self::parse_propfind_response(&xml)
    }

    /// PUT — 从本地文件流式上传（避免大文件整块驻留内存）
    ///
    /// 使用 `tokio::fs::File` + `ReaderStream` 边读边传；非 2xx 返回 Network。
    pub async fn put_file(&self, path: &str, local_file_path: &str) -> LegadoResult<()> {
        use tokio_util::io::ReaderStream;

        let url = self.full_url(path);
        let file = tokio::fs::File::open(local_file_path)
            .await
            .map_err(LegadoError::Io)?;
        let stream = ReaderStream::new(file);
        let body = reqwest::Body::wrap_stream(stream);
        let response = self
            .client
            .put(&url)
            .header("Authorization", self.auth_header())
            .body(body)
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        let status = response.status();
        if !status.is_success() {
            return Err(LegadoError::Network(format!(
                "WebDAV PUT 失败: HTTP {status}"
            )));
        }
        Ok(())
    }

    /// PUT — 上传文件（`&[u8]` 借用版，内部转交所有权版本）
    ///
    /// 响应状态码非 2xx 一律返回 Network 错误（Task #55 F1：修复
    /// 401/403/409/507 等被误报为成功）。
    pub async fn put(&self, path: &str, data: &[u8]) -> LegadoResult<()> {
        self.put_owned(path, data.to_vec()).await
    }

    /// PUT — 上传文件（接收 `Vec<u8>` 所有权，避免调用方数据二次拷贝；
    /// Task #55 F3）
    ///
    /// 请求完成后校验 HTTP 状态码，非 2xx 返回 Network 错误（Task #55 F1），
    /// 使既有 `webdav_upload` / `webdav_upload_file` 一并受益。
    ///
    /// 大文件上限风险：数据仍以整块 `Vec` 驻留内存后提交；大文件请改用
    /// [`put_file`] 流式读盘上传（`webdav_upload_file` 已走该路径）。
    pub async fn put_owned(&self, path: &str, data: Vec<u8>) -> LegadoResult<()> {
        let url = self.full_url(path);
        let response = self
            .client
            .put(&url)
            .header("Authorization", self.auth_header())
            .body(data)
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        let status = response.status();
        if !status.is_success() {
            return Err(LegadoError::Network(format!(
                "WebDAV PUT 失败: HTTP {status}"
            )));
        }
        Ok(())
    }

    /// GET — 下载文件
    pub async fn get(&self, path: &str) -> LegadoResult<Vec<u8>> {
        let url = self.full_url(path);
        let response = self
            .client
            .get(&url)
            .header("Authorization", self.auth_header())
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        let bytes = response
            .bytes()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        Ok(bytes.to_vec())
    }

    /// DELETE — 删除文件
    pub async fn delete(&self, path: &str) -> LegadoResult<()> {
        let url = self.full_url(path);
        self.client
            .delete(&url)
            .header("Authorization", self.auth_header())
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        Ok(())
    }

    /// MKCOL — 创建目录
    pub async fn mkdir(&self, path: &str) -> LegadoResult<()> {
        let url = self.full_url(path);
        self.client
            .request(reqwest::Method::from_bytes(b"MKCOL").unwrap(), &url)
            .header("Authorization", self.auth_header())
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        Ok(())
    }

    /// 获取文件 ETag 和 Last-Modified 元数据
    pub async fn get_file_info(&self, path: &str) -> Option<(String, String)> {
        let url = self.full_url(path);
        let body = r#"<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:getetag/>
    <D:getlastmodified/>
  </D:prop>
</D:propfind>"#;

        let response = self
            .client
            .request(reqwest::Method::from_bytes(b"PROPFIND").unwrap(), &url)
            .header("Authorization", self.auth_header())
            .header("Depth", "0")
            .header("Content-Type", "application/xml")
            .body(body)
            .send()
            .await
            .ok()?;

        if !response.status().is_success() {
            return None;
        }

        let xml = response.text().await.ok()?;
        let files = Self::parse_propfind_response(&xml).ok()?;
        files
            .first()
            .and_then(|f| match (&f.etag, &f.last_modified) {
                (Some(etag), Some(modified)) => Some((etag.clone(), modified.clone())),
                _ => None,
            })
    }

    /// 条件 PUT：仅当远端 ETag 匹配时才上传（乐观锁）
    pub async fn conditional_put(
        &self,
        path: &str,
        data: &[u8],
        etag: Option<&str>,
    ) -> LegadoResult<bool> {
        let url = self.full_url(path);
        let mut request = self
            .client
            .put(&url)
            .header("Authorization", self.auth_header());
        if let Some(etag_value) = etag {
            request = request.header("If-Match", etag_value);
        }
        let response = request
            .body(data.to_vec())
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
        if response.status() == reqwest::StatusCode::PRECONDITION_FAILED {
            return Ok(false);
        }
        if !response.status().is_success() {
            return Err(LegadoError::Network(format!(
                "PUT failed with status: {}",
                response.status()
            )));
        }
        Ok(true)
    }

    /// 列出目录内容并返回 {文件名: (etag, last_modified)} 映射
    pub async fn list_dir_with_etag(
        &self,
        path: &str,
    ) -> LegadoResult<HashMap<String, (String, String)>> {
        let files = self.list_dir(path).await?;
        let mut result = HashMap::new();
        for file in files {
            if !file.is_dir {
                if let (Some(etag), Some(modified)) = (&file.etag, &file.last_modified) {
                    result.insert(file.name, (etag.clone(), modified.clone()));
                }
            }
        }
        Ok(result)
    }

    /// 解析 PROPFIND XML 响应
    fn parse_propfind_response(xml: &str) -> LegadoResult<Vec<WebDavFileInfo>> {
        use quick_xml::events::Event;
        use quick_xml::Reader;

        let mut reader = Reader::from_str(xml);
        let mut buf = Vec::new();
        let mut files = Vec::new();
        let mut current_href: Option<String> = None;
        let mut current_displayname: Option<String> = None;
        let mut current_size: u64 = 0;
        let mut current_last_modified: Option<String> = None;
        let mut current_etag: Option<String> = None;
        let mut current_is_dir = false;
        let mut in_response = false;
        let mut in_prop = false;
        let mut tag_local = String::new();

        loop {
            match reader.read_event_into(&mut buf) {
                Ok(Event::Start(ref e)) => {
                    let local = e.local_name().as_ref().to_string();
                    tag_local.clone_from(&local);
                    match local.as_str() {
                        "response" => {
                            in_response = true;
                            current_href = None;
                            current_displayname = None;
                            current_size = 0;
                            current_last_modified = None;
                            current_etag = None;
                            current_is_dir = false;
                        }
                        "propstat" | "prop" => in_prop = true,
                        _ => {}
                    }
                }
                Ok(Event::Empty(ref e)) => {
                    let local = e.local_name().as_ref().to_string();
                    if local == "collection" && in_prop {
                        current_is_dir = true;
                    }
                }
                Ok(Event::Text(ref e)) => {
                    if !tag_local.is_empty() && in_response {
                        let text = e.as_ref().to_string();
                        match tag_local.as_str() {
                            "href" => current_href = Some(text),
                            "displayname" if in_prop => current_displayname = Some(text),
                            "getcontentlength" if in_prop => {
                                current_size = text.parse().unwrap_or(0);
                            }
                            "getlastmodified" if in_prop => current_last_modified = Some(text),
                            "getetag" if in_prop => current_etag = Some(text),
                            _ => {}
                        }
                        tag_local.clear();
                    }
                }
                Ok(Event::End(ref e)) => {
                    let local = e.local_name().as_ref().to_string();
                    match local.as_str() {
                        "response" if in_response => {
                            let href = current_href.clone().unwrap_or_default();
                            let name = current_displayname.clone().unwrap_or_else(|| {
                                href.trim_end_matches('/')
                                    .rsplit('/')
                                    .next()
                                    .unwrap_or("")
                                    .to_string()
                            });
                            files.push(WebDavFileInfo {
                                name,
                                path: href,
                                size: current_size,
                                last_modified: current_last_modified.clone(),
                                etag: current_etag.clone(),
                                is_dir: current_is_dir,
                            });
                            in_response = false;
                        }
                        "propstat" | "prop" => in_prop = false,
                        _ => {}
                    }
                }
                Ok(Event::Eof) => break,
                Err(e) => {
                    return Err(LegadoError::Parser(format!("XML parse error: {}", e)));
                }
                _ => {}
            }
            buf.clear();
        }
        Ok(files)
    }
}

/// 同步结果统计
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SyncResult {
    pub uploaded_count: usize,
    pub downloaded_count: usize,
    pub skipped_count: usize,
    pub conflict_count: usize,
    /// 冲突文件列表
    pub conflict_files: Vec<ConflictFile>,
    pub errors: Vec<String>,
    pub duration_ms: u64,
}

/// 冲突文件信息
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConflictFile {
    pub path: String,
    pub local_modified: i64,
    pub remote_modified: i64,
    pub remote_etag: Option<String>,
}

/// 冲突解决策略
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ConflictResolution {
    /// 保留远端版本
    KeepRemote,
    /// 使用本地版本
    UseLocal,
    /// JSON 字段级合并（保留最新值）
    Merge,
    /// 用户手动选择
    Manual,
}

/// 冲突解决历史记录
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConflictResolutionRecord {
    pub path: String,
    pub strategy: ConflictResolution,
    pub resolved_at: i64,
    pub note: String,
}

/// 冲突解决结果
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ConflictResolveResult {
    /// 合并后的文件内容映射 {路径: 内容}
    pub resolved_files: HashMap<String, String>,
    /// 解决历史
    pub history: Vec<ConflictResolutionRecord>,
    /// 仍需手动处理的文件
    pub pending_manual: Vec<String>,
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

/// 本地文件元数据
#[derive(Debug, Clone)]
pub struct LocalFileMeta {
    pub path: String,
    pub size: u64,
    pub last_modified: i64,
    pub data: Vec<u8>,
}

/// 同步项类型
#[derive(Debug, Clone)]
pub enum SyncItemKind {
    Bookshelf,
    Sources,
}

/// 需要同步的文件
#[derive(Debug)]
struct SyncItem {
    kind: SyncItemKind,
    local_data: Option<String>,
    should_upload: bool,
    upload_etag: Option<String>,
    should_download: bool,
    download_etag: Option<String>,
    is_conflict: bool,
}

/// 书籍数据 WebDAV 同步管理器
pub struct BookSyncManager {
    client: WebDavClient,
}

impl BookSyncManager {
    pub fn new(client: WebDavClient) -> Self {
        Self { client }
    }

    /// 解析 RFC1123 时间字符串为 Unix 时间戳
    pub fn parse_rfc1123(timestamp: &str) -> Option<i64> {
        let ts = timestamp.trim();
        if ts.len() < 29 {
            return None;
        }
        let comma_pos = ts.find(',')?;
        let after_comma = ts[comma_pos + 1..].trim();
        let parts: Vec<&str> = after_comma.splitn(4, ' ').collect();
        if parts.len() < 4 {
            return None;
        }
        let day: u32 = parts[0].parse().ok()?;
        let month = match parts[1] {
            "Jan" => 1u32,
            "Feb" => 2,
            "Mar" => 3,
            "Apr" => 4,
            "May" => 5,
            "Jun" => 6,
            "Jul" => 7,
            "Aug" => 8,
            "Sep" => 9,
            "Oct" => 10,
            "Nov" => 11,
            "Dec" => 12,
            _ => return None,
        };
        let year: i64 = parts[2].parse().ok()?;
        let time_part = parts[3].split(' ').next()?;
        let tc: Vec<&str> = time_part.split(':').collect();
        if tc.len() < 3 {
            return None;
        }
        let hour: i64 = tc[0].parse().ok()?;
        let min: i64 = tc[1].parse().ok()?;
        let sec: i64 = tc[2].parse().ok()?;
        Some(Self::days_since_epoch(year, month, day) * 86400 + hour * 3600 + min * 60 + sec)
    }

    /// 计算自 Unix 纪元以来的天数
    fn days_since_epoch(year: i64, month: u32, day: u32) -> i64 {
        let y = if month <= 2 { year - 1 } else { year };
        let m = if month <= 2 { month + 9 } else { month - 3 };
        let era = if y >= 0 { y } else { y - 399 } / 400;
        let yoe = y - era * 400;
        let doy = (153 * m as i64 + 2) / 5 + day as i64 - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146097 + doe - 719468
    }

    /// 比较两个时间戳是否接近（±5 秒内视为冲突）
    fn times_are_close(local_ts: i64, remote_ts: i64) -> bool {
        (local_ts - remote_ts).abs() <= 5
    }

    /// 上传书架数据
    pub async fn upload_bookshelf(&self, json_data: &str) -> LegadoResult<()> {
        self.client
            .put("bookshelf.json", json_data.as_bytes())
            .await
    }

    /// 下载书架数据
    pub async fn download_bookshelf(&self) -> LegadoResult<String> {
        let data = self.client.get("bookshelf.json").await?;
        String::from_utf8(data).map_err(|e| LegadoError::Parser(format!("Invalid UTF-8: {}", e)))
    }

    /// 上传书源数据
    pub async fn upload_sources(&self, json_data: &str) -> LegadoResult<()> {
        self.client.put("sources.json", json_data.as_bytes()).await
    }

    /// 下载书源数据
    pub async fn download_sources(&self) -> LegadoResult<String> {
        let data = self.client.get("sources.json").await?;
        String::from_utf8(data).map_err(|e| LegadoError::Parser(format!("Invalid UTF-8: {}", e)))
    }

    /// 完整同步（上传 + 下载合并）
    pub async fn full_sync(
        &self,
        local_books: &str,
        local_sources: &str,
    ) -> LegadoResult<(String, String)> {
        self.client.mkdir("").await.ok();
        self.upload_bookshelf(local_books).await?;
        self.upload_sources(local_sources).await?;
        let remote_books = self
            .download_bookshelf()
            .await
            .unwrap_or_else(|_| local_books.to_string());
        let remote_sources = self
            .download_sources()
            .await
            .unwrap_or_else(|_| local_sources.to_string());
        Ok((remote_books, remote_sources))
    }

    /// 增量同步：仅同步自上次同步后修改的文件，检测冲突
    pub async fn incremental_sync(
        &self,
        local_books: &str,
        local_sources: &str,
        last_sync_time: Option<i64>,
    ) -> LegadoResult<(String, String, SyncResult)> {
        let start = std::time::Instant::now();
        let mut result = SyncResult {
            uploaded_count: 0,
            downloaded_count: 0,
            skipped_count: 0,
            conflict_count: 0,
            conflict_files: Vec::new(),
            errors: Vec::new(),
            duration_ms: 0,
        };

        let remote_files = self.client.list_dir_with_etag("").await.unwrap_or_default();

        let mut sync_items = vec![
            SyncItem {
                kind: SyncItemKind::Bookshelf,
                local_data: Some(local_books.to_string()),
                should_upload: false,
                upload_etag: None,
                should_download: false,
                download_etag: None,
                is_conflict: false,
            },
            SyncItem {
                kind: SyncItemKind::Sources,
                local_data: Some(local_sources.to_string()),
                should_upload: false,
                upload_etag: None,
                should_download: false,
                download_etag: None,
                is_conflict: false,
            },
        ];

        // 增量判断：比较本地/远端修改时间
        for item in sync_items.iter_mut() {
            let (file_name, remote_path) = match item.kind {
                SyncItemKind::Bookshelf => ("bookshelf.json", "/bookshelf.json"),
                SyncItemKind::Sources => ("sources.json", "/sources.json"),
            };
            let has_remote = remote_files.contains_key(file_name);
            let local_modified = last_sync_time.unwrap_or(0);
            let (remote_modified, remote_etag) = if has_remote {
                self.client
                    .get_file_info(remote_path)
                    .await
                    .map_or((0i64, None), |(etag, modif)| {
                        (Self::parse_rfc1123(&modif).unwrap_or(0), Some(etag))
                    })
            } else {
                (0i64, None)
            };

            // 远端不存在或本地更新 → 上传；远端更新 → 下载；相同 → 跳过
            if !has_remote || local_modified > remote_modified {
                item.should_upload = true;
                item.upload_etag = remote_etag;
            } else if remote_modified > local_modified {
                item.should_download = true;
                item.download_etag = remote_etag;
            }

            // 冲突检测：时间接近但不同
            if has_remote
                && Self::times_are_close(local_modified, remote_modified)
                && local_modified != remote_modified
            {
                item.is_conflict = true;
                result.conflict_count += 1;
                result.conflict_files.push(ConflictFile {
                    path: file_name.to_string(),
                    local_modified,
                    remote_modified,
                    remote_etag: item
                        .upload_etag
                        .clone()
                        .or_else(|| item.download_etag.clone()),
                });
            }
        }

        // 执行同步
        let mut books_result = local_books.to_string();
        let mut sources_result = local_sources.to_string();

        for item in &sync_items {
            let (upload_path, dl_err_msg) = match item.kind {
                SyncItemKind::Bookshelf => ("/bookshelf.json", "书架"),
                SyncItemKind::Sources => ("/sources.json", "书源"),
            };
            if item.should_upload {
                if let Some(ref data) = item.local_data {
                    match self
                        .client
                        .conditional_put(upload_path, data.as_bytes(), item.upload_etag.as_deref())
                        .await
                    {
                        Ok(_) => result.uploaded_count += 1,
                        Err(e) => result.errors.push(format!("上传{}失败: {}", dl_err_msg, e)),
                    }
                }
            } else if item.should_download && !item.is_conflict {
                let dl_result = match item.kind {
                    SyncItemKind::Bookshelf => self.download_bookshelf().await,
                    SyncItemKind::Sources => self.download_sources().await,
                };
                match dl_result {
                    Ok(data) => {
                        result.downloaded_count += 1;
                        match item.kind {
                            SyncItemKind::Bookshelf => books_result = data,
                            SyncItemKind::Sources => sources_result = data,
                        }
                    }
                    Err(e) => result.errors.push(format!("下载{}失败: {}", dl_err_msg, e)),
                }
            } else if !item.should_upload && !item.should_download {
                result.skipped_count += 1;
            }
        }

        result.duration_ms = start.elapsed().as_millis() as u64;
        Ok((books_result, sources_result, result))
    }

    /// 解决冲突文件
    ///
    /// - JSON 文件：字段级合并（保留最新值）
    /// - 其他文件：按策略选择本地/远端版本
    pub async fn resolve_conflicts(
        &self,
        conflict_files: &[String],
        strategy: ConflictResolution,
        local_contents: &HashMap<String, String>,
    ) -> LegadoResult<ConflictResolveResult> {
        let mut resolved_files = HashMap::new();
        let mut history = Vec::new();
        let mut pending_manual = Vec::new();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as i64;

        for path in conflict_files {
            let local_content = local_contents.get(path).cloned().unwrap_or_default();
            let remote_content = match self.client.get(path).await {
                Ok(bytes) => String::from_utf8(bytes).unwrap_or_default(),
                Err(e) => {
                    resolved_files.insert(path.clone(), local_content);
                    history.push(ConflictResolutionRecord {
                        path: path.clone(),
                        strategy: ConflictResolution::UseLocal,
                        resolved_at: now,
                        note: format!("远端获取失败，保留本地: {}", e),
                    });
                    continue;
                }
            };

            let is_json = path.ends_with(".json");
            match strategy {
                ConflictResolution::KeepRemote => {
                    resolved_files.insert(path.clone(), remote_content);
                    history.push(ConflictResolutionRecord {
                        path: path.clone(),
                        strategy,
                        resolved_at: now,
                        note: "保留远端版本".to_string(),
                    });
                }
                ConflictResolution::UseLocal => {
                    resolved_files.insert(path.clone(), local_content);
                    history.push(ConflictResolutionRecord {
                        path: path.clone(),
                        strategy,
                        resolved_at: now,
                        note: "使用本地版本".to_string(),
                    });
                }
                ConflictResolution::Merge if is_json => {
                    let merged = Self::merge_json(&local_content, &remote_content);
                    resolved_files.insert(path.clone(), merged);
                    history.push(ConflictResolutionRecord {
                        path: path.clone(),
                        strategy,
                        resolved_at: now,
                        note: "JSON 字段级合并".to_string(),
                    });
                }
                ConflictResolution::Merge | ConflictResolution::Manual => {
                    pending_manual.push(path.clone());
                    history.push(ConflictResolutionRecord {
                        path: path.clone(),
                        strategy: ConflictResolution::Manual,
                        resolved_at: now,
                        note: "需手动处理".to_string(),
                    });
                }
            }
        }

        Ok(ConflictResolveResult {
            resolved_files,
            history,
            pending_manual,
        })
    }

    /// JSON 字段级合并：对象逐字段合并，数组合并去重，其他类型远端优先
    fn merge_json(local: &str, remote: &str) -> String {
        let local_val: serde_json::Value = match serde_json::from_str(local) {
            Ok(v) => v,
            Err(_) => return remote.to_string(),
        };
        let remote_val: serde_json::Value = match serde_json::from_str(remote) {
            Ok(v) => v,
            Err(_) => return local.to_string(),
        };
        let merged = Self::merge_values(&local_val, &remote_val);
        serde_json::to_string_pretty(&merged).unwrap_or_else(|_| remote.to_string())
    }

    /// 递归合并两个 JSON 值
    fn merge_values(local: &serde_json::Value, remote: &serde_json::Value) -> serde_json::Value {
        use serde_json::Value;
        match (local, remote) {
            (Value::Object(lm), Value::Object(rm)) => {
                let mut merged = lm.clone();
                for (key, rv) in rm {
                    if let Some(lv) = merged.get(key) {
                        merged.insert(key.clone(), Self::merge_values(lv, rv));
                    } else {
                        merged.insert(key.clone(), rv.clone());
                    }
                }
                Value::Object(merged)
            }
            (Value::Array(la), Value::Array(ra)) => {
                let mut merged = la.clone();
                for item in ra {
                    if !merged.contains(item) {
                        merged.push(item.clone());
                    }
                }
                Value::Array(merged)
            }
            (_, rv) => rv.clone(),
        }
    }

    /// 带指数退避的重试上传
    #[allow(dead_code)]
    async fn upload_with_retry(
        &self,
        path: &str,
        data: &[u8],
        max_retries: u32,
        initial_delay_ms: u64,
        max_delay_ms: u64,
    ) -> LegadoResult<()> {
        let mut delay = initial_delay_ms;
        for attempt in 0..=max_retries {
            match self.client.put(path, data).await {
                Ok(_) => return Ok(()),
                Err(e) => {
                    if attempt < max_retries {
                        log::info!(
                            "上传失败 (第 {}/{} 次, {}ms 后重试): {}",
                            attempt + 1,
                            max_retries,
                            delay,
                            e
                        );
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                        delay = (delay * 2).min(max_delay_ms);
                    } else {
                        return Err(LegadoError::Network(format!(
                            "上传失败，已重试 {} 次: {}",
                            max_retries, e
                        )));
                    }
                }
            }
        }
        unreachable!()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_webdav_config_serialize() {
        let config = WebDavConfig {
            url: "https://dav.example.com".into(),
            username: "user".into(),
            password: "pass".into(),
            remote_dir: "/legado/".into(),
        };
        let json = serde_json::to_string(&config).unwrap();
        assert!(json.contains("dav.example.com"));
        let de: WebDavConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(de.remote_dir, "/legado/");
    }

    #[test]
    fn test_auth_header() {
        use base64::Engine;
        let config = WebDavConfig {
            url: "https://example.com".into(),
            username: "user".into(),
            password: "pass".into(),
            remote_dir: "/".into(),
        };
        let client = WebDavClient::new(config);
        let header = client.auth_header();
        assert!(header.starts_with("Basic "));
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(&header[6..])
            .unwrap();
        assert_eq!(String::from_utf8(decoded).unwrap(), "user:pass");
    }

    #[test]
    fn test_full_url() {
        let config = WebDavConfig {
            url: "https://dav.example.com".into(),
            username: "u".into(),
            password: "p".into(),
            remote_dir: "/legado/".into(),
        };
        let client = WebDavClient::new(config);
        assert_eq!(
            client.full_url("bookshelf.json"),
            "https://dav.example.com/legado/bookshelf.json"
        );
        assert_eq!(client.full_url(""), "https://dav.example.com/legado/");
    }

    #[test]
    fn test_parse_propfind_response() {
        let xml = r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/legado/bookshelf.json</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>bookshelf.json</D:displayname>
        <D:getcontentlength>1024</D:getcontentlength>
        <D:getlastmodified>Sat, 01 Jan 2025 00:00:00 GMT</D:getlastmodified>
        <D:getetag>"abc123"</D:getetag>
        <D:resourcetype/>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/legado/backups/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>backups</D:displayname>
        <D:getcontentlength>0</D:getcontentlength>
        <D:resourcetype><D:collection/></D:resourcetype>
      </D:prop>
      <D:status>HTTP/1.1 200 OK</D:status>
    </D:propstat>
  </D:response>
</D:multistatus>"#;
        let files = WebDavClient::parse_propfind_response(xml).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0].name, "bookshelf.json");
        assert_eq!(files[0].size, 1024);
        assert!(!files[0].is_dir);
        assert_eq!(files[1].name, "backups");
        assert!(files[1].is_dir);
    }

    #[test]
    fn test_parse_propfind_empty() {
        let xml = r#"<D:multistatus xmlns:D="DAV:"></D:multistatus>"#;
        let files = WebDavClient::parse_propfind_response(xml).unwrap();
        assert!(files.is_empty());
    }

    #[test]
    fn test_parse_rfc1123_timestamp() {
        let result = BookSyncManager::parse_rfc1123("Sat, 01 Jul 2025 12:00:00 GMT").unwrap();
        assert_eq!(result, 1751371200);
    }

    #[test]
    fn test_parse_rfc1123_epoch() {
        let result = BookSyncManager::parse_rfc1123("Thu, 01 Jan 1970 00:00:00 GMT").unwrap();
        assert_eq!(result, 0);
    }

    #[test]
    fn test_parse_rfc1123_invalid() {
        assert!(BookSyncManager::parse_rfc1123("").is_none());
        assert!(BookSyncManager::parse_rfc1123("invalid").is_none());
        assert!(BookSyncManager::parse_rfc1123("Sat, 01 Xyz 2025 12:00:00 GMT").is_none());
    }

    #[test]
    fn test_times_are_close() {
        assert!(BookSyncManager::times_are_close(1000, 1000));
        assert!(BookSyncManager::times_are_close(1000, 1003));
        assert!(!BookSyncManager::times_are_close(1000, 1010));
    }

    #[test]
    fn test_sync_result_serialize() {
        let result = SyncResult {
            uploaded_count: 10,
            downloaded_count: 5,
            skipped_count: 2,
            conflict_count: 1,
            conflict_files: vec![ConflictFile {
                path: "bookshelf.json".into(),
                local_modified: 1000,
                remote_modified: 1003,
                remote_etag: Some("\"abc\"".into()),
            }],
            errors: Vec::new(),
            duration_ms: 1000,
        };
        let json = serde_json::to_string(&result).unwrap();
        let de: SyncResult = serde_json::from_str(&json).unwrap();
        assert_eq!(de.uploaded_count, 10);
        assert_eq!(de.conflict_files.len(), 1);
    }

    #[test]
    fn test_merge_json_objects() {
        let local = r#"{"name": "本地", "chapter": 5, "local_only": true}"#;
        let remote = r#"{"name": "远端", "chapter": 10, "remote_only": "yes"}"#;
        let merged = BookSyncManager::merge_json(local, remote);
        let val: serde_json::Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(val["name"], "远端");
        assert_eq!(val["chapter"], 10);
        assert_eq!(val["local_only"], true);
        assert_eq!(val["remote_only"], "yes");
    }

    #[test]
    fn test_merge_json_arrays() {
        let local = r#"{"sources": ["a", "b"]}"#;
        let remote = r#"{"sources": ["b", "c"]}"#;
        let merged = BookSyncManager::merge_json(local, remote);
        let val: serde_json::Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(val["sources"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn test_merge_json_invalid() {
        assert_eq!(
            BookSyncManager::merge_json("bad", r#"{"k":"v"}"#),
            r#"{"k":"v"}"#
        );
        assert_eq!(
            BookSyncManager::merge_json(r#"{"k":"v"}"#, "bad"),
            r#"{"k":"v"}"#
        );
    }

    #[test]
    fn test_conflict_resolution_serialize() {
        let json = serde_json::to_string(&ConflictResolution::Merge).unwrap();
        let de: ConflictResolution = serde_json::from_str(&json).unwrap();
        assert_eq!(de, ConflictResolution::Merge);
    }

    #[test]
    fn test_conflict_resolve_result_serialize() {
        let mut resolved = HashMap::new();
        resolved.insert("a.json".to_string(), "{}".to_string());
        let result = ConflictResolveResult {
            resolved_files: resolved,
            history: vec![ConflictResolutionRecord {
                path: "a.json".into(),
                strategy: ConflictResolution::Merge,
                resolved_at: 100,
                note: "合并".into(),
            }],
            pending_manual: vec!["b.txt".into()],
        };
        let json = serde_json::to_string(&result).unwrap();
        let de: ConflictResolveResult = serde_json::from_str(&json).unwrap();
        assert_eq!(de.resolved_files.len(), 1);
        assert_eq!(de.pending_manual.len(), 1);
    }

    #[test]
    fn test_days_since_epoch() {
        assert_eq!(BookSyncManager::days_since_epoch(1970, 1, 1), 0);
        assert_eq!(BookSyncManager::days_since_epoch(2000, 1, 1), 10957);
        assert_eq!(BookSyncManager::days_since_epoch(2025, 7, 1), 20270);
    }
}
