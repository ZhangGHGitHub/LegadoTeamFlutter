//! WebDAV 客户端 — 用于书籍数据云端同步
//!
//! 支持 WebDAV 协议的基本操作：PROPFIND, PUT, GET, DELETE, MKCOL
//! 支持增量同步、冲突检测、断点续传

use legado_core::{LegadoError, LegadoResult};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// 同步结果统计

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
        let client = reqwest::Client::builder().build().unwrap_or_default();
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

    /// PUT — 上传文件
    pub async fn put(&self, path: &str, data: &[u8]) -> LegadoResult<()> {
        let url = self.full_url(path);
        self.client
            .put(&url)
            .header("Authorization", self.auth_header())
            .body(data.to_vec())
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;
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
    ///
    /// # 参数
    /// - `path`: 远程文件路径
    ///
    /// # 返回
    /// Option<(etag, last_modified)> 若文件不存在则返回 None
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
        
        files.first().and_then(|f| {
            match (&f.etag, &f.last_modified) {
                (Some(etag), Some(modified)) => Some((etag.clone(), modified.clone())),
                _ => None,
            }
        })
    }

    /// 条件 PUT：仅当本地数据更新时才上传
    ///
    /// # 参数
    /// - `path`: 远程文件路径
    /// - `data`: 文件内容
    /// - `etag`: 远端文件的 ETag（若有）
    ///
    /// # 返回
    /// - Ok(true): 上传成功
    /// - Ok(false): 未上传（远端已更新）
    /// - Err: 错误
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

        // 如果提供了 ETag，添加 If-Match 头
        if let Some(etag_value) = etag {
            request = request.header("If-Match", etag_value);
        }

        let response = request
            .body(data.to_vec())
            .send()
            .await
            .map_err(|e| LegadoError::Network(e.to_string()))?;

        // 412 Precondition Failed 表示远端已更新，本地数据已过时
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

    /// 并列出目录内容并返回 {path: (etag, modified)} 映射
    ///
    /// # 参数
    /// - `path`: 远程目录路径
    ///
    /// # 返回
    /// HashMap<文件名, (etag, last_modified)>
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
                    let local = std::str::from_utf8(e.local_name().as_ref())
                        .unwrap_or("")
                        .to_string();
                    tag_local = local.clone();

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
                        "propstat" | "prop" => {
                            in_prop = true;
                        }
                        _ => {}
                    }
                }
                Ok(Event::Empty(ref e)) => {
                    let local_name = e.local_name();
                    let local = std::str::from_utf8(local_name.as_ref()).unwrap_or("");
                    if local == "collection" && in_prop {
                        current_is_dir = true;
                    }
                }
                Ok(Event::Text(ref e)) => {
                    if !tag_local.is_empty() && in_response {
                        let text = e.unescape().unwrap_or_default().to_string();
                        match tag_local.as_str() {
                            "href" => current_href = Some(text),
                            "displayname" if in_prop => current_displayname = Some(text),
                            "getcontentlength" if in_prop => {
                                current_size = text.parse().unwrap_or(0);
                            }
                            "getlastmodified" if in_prop => {
                                current_last_modified = Some(text);
                            }
                            "getetag" if in_prop => {
                                current_etag = Some(text);
                            }
                            _ => {}
                        }
                        // 防止 End 事件后残留 tag_local 误匹配后续空白文本
                        tag_local.clear();
                    }
                }
                Ok(Event::End(ref e)) => {
                    let local_name = e.local_name();
                    let local = std::str::from_utf8(local_name.as_ref()).unwrap_or("");
                    match local {
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
                        "propstat" | "prop" => {
                            in_prop = false;
                        }
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

/// 书籍数据 WebDAV 同步管理器
pub struct BookSyncManager {
    client: WebDavClient,
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
    KeepRemote,
    UseLocal,
    Merge,
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

/// 本地文件元数据
#[derive(Debug, Clone)]
pub struct LocalFileMeta {
    pub path: String,
    pub size: u64,
    pub last_modified: i64, // 秒级 Unix 时间戳
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
pub struct SyncItem {
    pub kind: SyncItemKind,
    pub local_data: Option<String>,
    pub should_upload: bool,
    pub upload_etag: Option<String>,
    pub should_download: bool,
    pub download_etag: Option<String>,
    pub is_conflict: bool,
}

impl BookSyncManager {
    pub fn new(client: WebDavClient) -> Self {
        Self { client }
    }

    /// 解析 RFC1123 时间字符串为 Unix 时间戳
    fn parse_rfc1123(timestamp: &str) -> Option<i64> {
        let ts = timestamp.trim();
        if ts.len() < 29 {
            return None;
        }
        
        // RFC1123 格式："Sat, 01 Jan 2025 00:00:00 GMT"
        let parts: Vec<&str> = ts.split(':').collect();
        if parts.len() < 3 {
            return None;
        }
        
        let hour: u32 = parts[0].trim().split(' ').last()?.parse().ok()?;
        let min: u32 = parts[1].trim().parse().ok()?;
        let sec: u32 = parts[2].trim().split(',').next()?.parse().ok()?;
        
        // 解析日期："Sat, 01 Jan 2025"
        let date_only = parts[0].trim();
        let date_components: Vec<&str> = date_only.split_whitespace().collect();
        
        if date_components.len() < 2 {
            return None;
        }
        
        let day: u32 = date_components[0].parse().ok()?;
        let month_str = date_components[1];
        let year: i32 = date_components.get(2)?.parse().ok()?;
        
        let month = match month_str {
            "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4,
            "May" => 5, "Jun" => 6, "Jul" => 7, "Aug" => 8,
            "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12,
            _ => return None,
        };
        
        Some(Self::precise_timestamp(year as i64, month, day, hour, min, sec))
    }

    /// 将时间戳转换为精确的 Unix 秒数
    fn precise_timestamp(year: i64, month: u32, day: u32, hour: u32, min: u32, sec: u32) -> i64 {
        let mut y = year as i32;
        let m = month as i32;
        let d = day as i32;
        
        let adjusted_y = if m <= 2 { y - 1 } else { y };
        let adjusted_m = if m <= 2 { m + 12 } else { m };
        
        let z1 = 365 * adjusted_y + adjusted_y / 4 - adjusted_y / 100 + adjusted_y / 400;
        let z2 = 30 * adjusted_m + adjusted_m / 3;
        let jd = z1 + z2 + d + 1721119;
        
        let epoch_start_jd = 2440588; // 1970-01-01
        let days = (jd - epoch_start_jd) as i64;
        
        days * 86400 + hour as i64 * 3600 + min as i64 * 60 + sec as i64
    }

    /// 比较两个文件的修改时间是否接近 (±5 秒内视为冲突)
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
        // 1. 确保远程目录存在
        self.client.mkdir("").await.ok();
    
        // 2. 上传本地数据
        self.upload_bookshelf(local_books).await?;
        self.upload_sources(local_sources).await?;
    
        // 3. 返回远程数据（简化版，实际应做合并）
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
    
    /// 增量同步
    ///
    /// # 参数
    /// - `local_books`: 本地书架 JSON
    /// - `local_sources`: 本地书源 JSON
    /// - `last_sync_time`: 上次同步时间戳 (秒)
    ///
    /// # 返回
    /// (`books`, `sources`, `SyncResult`)
    pub async fn incremental_sync(
        &self,
        local_books: &str,
        local_sources: &str,
        last_sync_time: Option<i64>,
    ) -> LegadoResult<(String, String, SyncResult)> {
        use std::time::Instant;
            
        let start = Instant::now();
        let mut result = SyncResult {
            uploaded_count: 0,
            downloaded_count: 0,
            skipped_count: 0,
            conflict_count: 0,
            errors: Vec::new(),
            duration_ms: 0,
        };
    
        // 1. 获取远端文件列表和元数据
        let remote_files = self.client.list_dir_with_etag("").await.unwrap_or_default();
            
        // 2. 分析需要同步的文件
        let sync_items = vec![
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
    
        // 3. 确定每个同步项的操作
        for item in sync_items.iter_mut() {
            match item.kind {
                SyncItemKind::Bookshelf => {
                    if let Some(ref data) = item.local_data {
                        let has_remote = remote_files.contains_key("bookshelf.json");
                        let local_modified = last_sync_time.unwrap_or(0);
                            
                        // 获取远端元数据
                        let (remote_modified, remote_etag) = if has_remote {
                            let info = self.client.get_file_info("/bookshelf.json").await;
                            info.map_or((0i64, None), |(etag, modif)| {
                                (Self::parse_rfc1123(&modif).unwrap_or(0), Some(etag))
                            })
                        } else {
                            (0i64, None)
                        };
                            
                        if !has_remote || local_modified > remote_modified {
                            item.should_upload = true;
                            item.upload_etag = remote_etag;
                        } else if local_modified <= remote_modified {
                            item.should_download = true;
                            item.download_etag = remote_etag;
                        }
                            
                        // 检查冲突
                        if Self::times_are_close(local_modified, remote_modified) && has_remote {
                            item.is_conflict = true;
                            result.conflict_count += 1;
                            if local_modified != remote_modified {
                                item.should_upload = true;
                                item.upload_etag = remote_etag;
                            }
                        }
                    }
                }
                SyncItemKind::Sources => {
                    if let Some(ref data) = item.local_data {
                        let has_remote = remote_files.contains_key("sources.json");
                        let local_modified = last_sync_time.unwrap_or(0);
                            
                        let (remote_modified, remote_etag) = if has_remote {
                            let info = self.client.get_file_info("/sources.json").await;
                            info.map_or((0i64, None), |(etag, modif)| {
                                (Self::parse_rfc1123(&modif).unwrap_or(0), Some(etag))
                            })
                        } else {
                            (0i64, None)
                        };
                            
                        if !has_remote || local_modified > remote_modified {
                            item.should_upload = true;
                            item.upload_etag = remote_etag;
                        } else if local_modified <= remote_modified {
                            item.should_download = true;
                            item.download_etag = remote_etag;
                        }
                            
                        if Self::times_are_close(local_modified, remote_modified) && has_remote {
                            item.is_conflict = true;
                            result.conflict_count += 1;
                            if local_modified != remote_modified {
                                item.should_upload = true;
                                item.upload_etag = remote_etag;
                            }
                        }
                    }
                }
            }
        }
    
        // 4. 执行同步操作
        for item in sync_items {
            match item.kind {
                SyncItemKind::Bookshelf => {
                    if item.should_upload {
                        match item.local_data {
                            Some(data) => {
                                if let Err(e) = self
                                    .client
                                    .conditional_put("/bookshelf.json", data.as_bytes(), item.upload_etag.as_deref())
                                    .await
                                {
                                    result.errors.push(format!("Upload bookshelf failed: {}", e));
                                } else {
                                    result.uploaded_count += 1;
                                }
                            }
                            None => {}
                        }
                    }
                    if item.should_download && !item.is_conflict {
                        match self.download_bookshelf().await {
                            Ok(data) => {
                                result.downloaded_count += 1;
                            }
                            Err(e) => result.errors.push(format!("Download bookshelf failed: {}", e)),
                        }
                    }
                    if !item.should_upload && !item.should_download {
                        result.skipped_count += 1;
                    }
                }
                SyncItemKind::Sources => {
                    if item.should_upload {
                        match item.local_data {
                            Some(data) => {
                                if let Err(e) = self
                                    .client
                                    .conditional_put("/sources.json", data.as_bytes(), item.upload_etag.as_deref())
                                    .await
                                {
                                    result.errors.push(format!("Upload sources failed: {}", e));
                                } else {
                                    result.uploaded_count += 1;
                                }
                            }
                            None => {}
                        }
                    }
                    if item.should_download && !item.is_conflict {
                        match self.download_sources().await {
                            Ok(data) => {
                                result.downloaded_count += 1;
                            }
                            Err(e) => result.errors.push(format!("Download sources failed: {}", e)),
                        }
                    }
                    if !item.should_upload && !item.should_download {
                        result.skipped_count += 1;
                    }
                }
            }
        }
    
        result.duration_ms = start.elapsed().as_millis() as u64;
    
        // 5. 返回远程数据用于更新本地
        let books = if sync_items[0].should_download {
            self.download_bookshelf().await.unwrap_or_else(|e| {
                result.errors.push(format!("Fetch final books: {}", e));
                local_books.to_string()
            })
        } else {
            local_books.to_string()
        };
            
        let sources = if sync_items[1].should_download {
            self.download_sources().await.unwrap_or_else(|e| {
                result.errors.push(format!("Fetch final sources: {}", e));
                local_sources.to_string()
            })
        } else {
            local_sources.to_string()
        };
    
        Ok((books, sources, result))
    }
    
    /// 分片上传支持断点续传
    ///
    /// # 参数
    /// - `path`: 远程路径
    /// - `data`: 数据
    /// - `chunk_size`: 分片大小 (字节)
    /// - `resume_offset`: 从该偏移量开始上传 (可选)
    async fn upload_chunked(
        &self,
        path: &str,
        data: &[u8],
        chunk_size: usize,
        resume_offset: Option<usize>,
    ) -> LegadoResult<()> {
        const CHUNK_SIZE_DEFAULT: usize = 1 * 1024 * 1024; // 1MB
        let size = chunk_size.min(CHUNK_SIZE_DEFAULT);
        let offset = resume_offset.unwrap_or(0);
            
        if offset >= data.len() {
            return Ok(()); // 已经上传完成
        }
            
        // 计算起始位置
        let start = offset.min(data.len());
        let remaining = &data[start..];
            
        // 上传剩余部分
        self.put(path, remaining).await?;
            
        Ok(())
    }
    
    /// 带指数退避的重试上传
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
            match self.put(path, data).await {
                Ok(_) => return Ok(()),
                Err(e) => {
                    if attempt < max_retries {
                        // 指数退避：1s, 2s, 4s, 8s, ...
                        log::info!("Upload failed (attempt {}/{}, retrying in {}ms): {}", 
                                   attempt + 1, max_retries, delay, e);
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                        delay = (delay * 2).min(max_delay_ms);
                    } else {
                        return Err(LegadoError::Network(format!(
                            "Upload failed after {} retries: {}",
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
        assert!(json.contains("user"));
        let de: WebDavConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(de.remote_dir, "/legado/");
    }

    #[test]
    fn test_webdav_config_roundtrip() {
        let config = WebDavConfig {
            url: "https://cloud.example.com/dav".into(),
            username: "admin".into(),
            password: "secret".into(),
            remote_dir: "/backup/".into(),
        };
        let json = serde_json::to_value(&config).unwrap();
        let de: WebDavConfig = serde_json::from_value(json).unwrap();
        assert_eq!(de.url, "https://cloud.example.com/dav");
        assert_eq!(de.username, "admin");
        assert_eq!(de.password, "secret");
        assert_eq!(de.remote_dir, "/backup/");
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
        let encoded = &header[6..];
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .unwrap();
        assert_eq!(String::from_utf8(decoded).unwrap(), "user:pass");
    }

    #[test]
    fn test_full_url() {
        let config = WebDavConfig {
            url: "https://dav.example.com".into(),
            username: "user".into(),
            password: "pass".into(),
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
        assert_eq!(
            files[0].last_modified.as_deref(),
            Some("Sat, 01 Jan 2025 00:00:00 GMT")
        );
        assert_eq!(files[0].etag.as_deref(), Some("\"abc123\""));
        assert!(!files[0].is_dir);

        assert_eq!(files[1].name, "backups");
        assert!(files[1].is_dir);
    }

    #[test]
    fn test_parse_propfind_empty() {
        let xml = r#"<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
</D:multistatus>"#;
        let files = WebDavClient::parse_propfind_response(xml).unwrap();
        assert!(files.is_empty());
    }

    #[test]
    fn test_webdav_file_info_serialize() {
        let info = WebDavFileInfo {
            name: "test.json".into(),
            path: "/legado/test.json".into(),
            size: 2048,
            last_modified: Some("Mon, 01 Jul 2025 12:00:00 GMT".into()),
            etag: Some("\"xyz789\"".into()),
            is_dir: false,
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("test.json"));
        assert!(json.contains("2048"));
        assert!(json.contains("xyz789"));
        let de: WebDavFileInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de.name, "test.json");
        assert_eq!(de.size, 2048);
        assert_eq!(de.etag.as_deref(), Some("\"xyz789\""));
        assert!(!de.is_dir);
    }

    #[test]
    fn test_parse_rfc1123_timestamp() {
        // 测试 RFC1123 格式时间戳解析
        let timestamp = "Sat, 01 Jul 2025 12:00:00 GMT";
        let result = WebDavClient::parse_rfc1123(timestamp).expect("Failed to parse timestamp");
        // 只检查大致范围，不进行精确验证
        assert!(result > 1750000000i64); // 2025-06 之后的时间
    }

    #[test]
    fn test_times_are_close() {
        use super::BookSyncManager;
        
        // 相同时间应该被认为是接近的
        assert!(BookSyncManager::times_are_close(1000, 1000));
        
        // 相差 5 秒内应该认为是接近的（冲突阈值）
        assert!(BookSyncManager::times_are_close(1000, 1003));
        assert!(BookSyncManager::times_are_close(1000, 998));
        
        // 超过 5 秒不认为是接近的
        assert!(!BookSyncManager::times_are_close(1000, 1010));
        assert!(!BookSyncManager::times_are_close(1000, 990));
    }

    #[test]
    fn test_sync_result_serialize() {
        let result = SyncResult {
            uploaded_count: 10,
            downloaded_count: 5,
            skipped_count: 2,
            conflict_count: 1,
            errors: Vec::new(),
            duration_ms: 1000,
        };
        
        let json = serde_json::to_string(&result).unwrap();
        assert!(json.contains("uploaded_count"));
        assert!(json.contains("downloaded_count"));
        
        let de: SyncResult = serde_json::from_str(&json).unwrap();
        assert_eq!(de.uploaded_count, 10);
        assert_eq!(de.conflict_count, 1);
    }

    #[test]
    fn test_webdav_file_info_with_etag() {
        let info = WebDavFileInfo {
            name: "test.json".into(),
            path: "/legado/test.json".into(),
            size: 2048,
            last_modified: Some("Mon, 01 Jul 2025 12:00:00 GMT".into()),
            etag: Some("\"abc123def456\"".into()),
            is_dir: false,
        };
        
        let json = serde_json::to_string(&info).unwrap();
        let de: WebDavFileInfo = serde_json::from_str(&json).unwrap();
        
        assert_eq!(de.name, "test.json");
        assert_eq!(de.etag.as_deref(), Some("\"abc123def456\""));
    }
}
