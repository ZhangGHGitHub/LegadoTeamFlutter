//! WebDAV 客户端 — 用于书籍数据云端同步
//!
//! 支持 WebDAV 协议的基本操作：PROPFIND, PUT, GET, DELETE, MKCOL

use legado_core::{LegadoError, LegadoResult};

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

impl BookSyncManager {
    pub fn new(client: WebDavClient) -> Self {
        Self { client }
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

    /// 完整同步（上传+下载合并）
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
            is_dir: false,
        };
        let json = serde_json::to_string(&info).unwrap();
        assert!(json.contains("test.json"));
        assert!(json.contains("2048"));
        let de: WebDavFileInfo = serde_json::from_str(&json).unwrap();
        assert_eq!(de.name, "test.json");
        assert_eq!(de.size, 2048);
        assert!(!de.is_dir);
    }
}
