//! 远程书籍管理（WebDAV）
//! 移植自 Kotlin model/remote/ (3个文件, 159行)
//! 扩展现有 webdav.rs，提供书籍级别的远程管理

use serde::{Deserialize, Serialize};

/// 支持的书籍文件扩展名
pub const BOOK_EXTENSIONS: &[&str] = &["epub", "txt", "mobi", "pdf", "azw3", "umd"];

/// 支持的压缩文件扩展名
pub const ARCHIVE_EXTENSIONS: &[&str] = &["zip", "rar", "7z"];

/// 远程书籍信息（对应 Kotlin RemoteBook）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteBook {
    /// 文件名
    pub filename: String,
    /// 远程路径
    pub path: String,
    /// 文件大小（字节）
    pub size: u64,
    /// 最后修改时间（Unix 时间戳）
    pub last_modify: Option<i64>,
    /// 内容类型（"folder" 或文件扩展名）
    #[serde(default = "default_content_type")]
    pub content_type: String,
    /// 是否已在书架
    #[serde(default)]
    pub is_on_book_shelf: bool,
}

fn default_content_type() -> String {
    "folder".to_string()
}

impl RemoteBook {
    /// 是否为目录
    pub fn is_dir(&self) -> bool {
        self.content_type == "folder"
    }

    /// 是否为书籍文件
    pub fn is_book_file(&self) -> bool {
        if self.is_dir() {
            return false;
        }
        let ext = self.extension();
        BOOK_EXTENSIONS.contains(&ext.as_str())
    }

    /// 是否为压缩文件
    pub fn is_archive(&self) -> bool {
        if self.is_dir() {
            return false;
        }
        let ext = self.extension();
        ARCHIVE_EXTENSIONS.contains(&ext.as_str())
    }

    /// 获取文件扩展名（小写）
    pub fn extension(&self) -> String {
        self.filename
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_lowercase()
    }

    /// 从文件名和路径构造（模拟 Kotlin 中从 WebDavFile 构造）
    pub fn from_file_info(filename: &str, path: &str, size: u64, last_modify: Option<i64>) -> Self {
        let content_type = if filename.contains('.') {
            filename
                .rsplit('.')
                .next()
                .unwrap_or("folder")
                .to_lowercase()
        } else {
            "folder".to_string()
        };
        Self {
            filename: filename.to_string(),
            path: path.to_string(),
            size,
            last_modify,
            content_type,
            is_on_book_shelf: false,
        }
    }
}

/// 远程书籍管理器（对应 Kotlin RemoteBookManager + RemoteBookWebDav）
pub struct RemoteBookManager {
    /// WebDAV 根目录 URL
    root_book_url: String,
    /// 认证用户名
    username: String,
    /// 认证密码
    password: String,
}

impl RemoteBookManager {
    pub fn new(root_book_url: &str, username: &str, password: &str) -> Self {
        Self {
            root_book_url: root_book_url.trim_end_matches('/').to_string(),
            username: username.to_string(),
            password: password.to_string(),
        }
    }

    /// 获取书籍列表（对应 Kotlin getRemoteBookList）
    ///
    /// 使用 WebDAV PROPFIND 列出指定路径下的文件，
    /// 过滤出书籍文件和目录。
    pub async fn get_remote_book_list(&self, path: &str) -> Result<Vec<RemoteBook>, String> {
        let client = reqwest::Client::new();
        let propfind_body = r#"<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:prop>
    <D:displayname/>
    <D:getcontentlength/>
    <D:getlastmodified/>
    <D:resourcetype/>
  </D:prop>
</D:propfind>"#;

        let resp = client
            .request(reqwest::Method::from_bytes(b"PROPFIND").unwrap(), path)
            .basic_auth(&self.username, Some(&self.password))
            .header("Depth", "1")
            .header("Content-Type", "application/xml")
            .body(propfind_body.to_string())
            .send()
            .await
            .map_err(|e| format!("PROPFIND 请求失败: {e}"))?;

        if !resp.status().is_success() && resp.status().as_u16() != 207 {
            return Err(format!("WebDAV 返回错误: {}", resp.status()));
        }

        let body = resp.text().await.map_err(|e| e.to_string())?;
        Ok(Self::parse_propfind_response(&body, path))
    }

    /// 根据路径获取单个书籍信息（对应 Kotlin getRemoteBook）
    pub async fn get_remote_book(&self, path: &str) -> Result<Option<RemoteBook>, String> {
        let books = self.get_remote_book_list(path).await?;
        Ok(books.into_iter().find(|b| b.path == path))
    }

    /// 下载远程书籍（对应 Kotlin downloadRemoteBook）
    pub async fn download_remote_book(&self, remote_book: &RemoteBook) -> Result<Vec<u8>, String> {
        let client = reqwest::Client::new();
        let resp = client
            .get(&remote_book.path)
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await
            .map_err(|e| format!("下载失败: {e}"))?;

        if !resp.status().is_success() {
            return Err(format!("下载返回错误: {}", resp.status()));
        }

        resp.bytes()
            .await
            .map(|b| b.to_vec())
            .map_err(|e| e.to_string())
    }

    /// 上传书籍到远程（对应 Kotlin upload）
    pub async fn upload_book(
        &self,
        local_content: &[u8],
        remote_name: &str,
    ) -> Result<String, String> {
        let put_url = format!("{}/{}", self.root_book_url, remote_name);
        let client = reqwest::Client::new();
        let resp = client
            .put(&put_url)
            .basic_auth(&self.username, Some(&self.password))
            .body(local_content.to_vec())
            .send()
            .await
            .map_err(|e| format!("上传失败: {e}"))?;

        if !resp.status().is_success() {
            return Err(format!("上传返回错误: {}", resp.status()));
        }

        Ok(put_url)
    }

    /// 删除远程书籍（对应 Kotlin delete）
    pub async fn delete_remote_book(&self, remote_book_url: &str) -> Result<(), String> {
        let client = reqwest::Client::new();
        let resp = client
            .delete(remote_book_url)
            .basic_auth(&self.username, Some(&self.password))
            .send()
            .await
            .map_err(|e| format!("删除失败: {e}"))?;

        if !resp.status().is_success() {
            return Err(format!("删除返回错误: {}", resp.status()));
        }

        Ok(())
    }

    /// 同步远程书籍列表（过滤出书籍文件）
    pub async fn sync_book_list(&self, path: &str) -> Result<Vec<RemoteBook>, String> {
        let all = self.get_remote_book_list(path).await?;
        Ok(all
            .into_iter()
            .filter(|b| b.is_dir() || b.is_book_file() || b.is_archive())
            .collect())
    }

    /// 解析 PROPFIND XML 响应（简化实现）
    fn parse_propfind_response(xml: &str, base_path: &str) -> Vec<RemoteBook> {
        let mut books = Vec::new();
        // 简单解析：查找 <D:response> 块
        for response_block in xml.split("<D:response>").skip(1) {
            let href = Self::extract_xml_value(response_block, "D:href");
            let display_name = Self::extract_xml_value(response_block, "D:displayname");
            let content_length = Self::extract_xml_value(response_block, "D:getcontentlength");
            let is_collection = response_block.contains("<D:collection");

            let href = match href {
                Some(h) => h,
                None => continue,
            };

            // 跳过自身
            if href.trim_end_matches('/') == base_path.trim_end_matches('/') {
                continue;
            }

            let filename = display_name.unwrap_or_else(|| {
                href.trim_end_matches('/')
                    .rsplit('/')
                    .next()
                    .unwrap_or("")
                    .to_string()
            });

            let size = content_length
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(0);

            let content_type = if is_collection {
                "folder".to_string()
            } else {
                filename.rsplit('.').next().unwrap_or("").to_lowercase()
            };

            books.push(RemoteBook {
                filename,
                path: href,
                size,
                last_modify: None,
                content_type,
                is_on_book_shelf: false,
            });
        }
        books
    }

    /// 从 XML 片段中提取标签值
    fn extract_xml_value(xml: &str, tag: &str) -> Option<String> {
        let open = format!("<{tag}>");
        let close = format!("</{tag}>");
        let start = xml.find(&open)? + open.len();
        let end = xml[start..].find(&close)? + start;
        Some(xml[start..end].to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_remote_book_is_dir() {
        let book = RemoteBook {
            filename: "novels".to_string(),
            path: "/dav/books/novels".to_string(),
            size: 0,
            last_modify: None,
            content_type: "folder".to_string(),
            is_on_book_shelf: false,
        };
        assert!(book.is_dir());
        assert!(!book.is_book_file());
    }

    #[test]
    fn test_remote_book_is_book_file() {
        let book = RemoteBook::from_file_info("test.epub", "/dav/books/test.epub", 1024, None);
        assert!(!book.is_dir());
        assert!(book.is_book_file());
        assert!(!book.is_archive());
        assert_eq!(book.extension(), "epub");
    }

    #[test]
    fn test_remote_book_archive() {
        let book = RemoteBook::from_file_info("pack.zip", "/dav/books/pack.zip", 2048, None);
        assert!(book.is_archive());
        assert!(!book.is_book_file());
    }

    #[test]
    fn test_remote_book_txt() {
        let book = RemoteBook::from_file_info("小说.txt", "/dav/小说.txt", 512, Some(1700000000));
        assert!(book.is_book_file());
        assert_eq!(book.extension(), "txt");
        assert_eq!(book.last_modify, Some(1700000000));
    }

    #[test]
    fn test_from_file_info_no_extension() {
        let book = RemoteBook::from_file_info("README", "/dav/README", 100, None);
        assert!(book.is_dir()); // no extension → treated as folder
    }

    #[test]
    fn test_parse_propfind_response() {
        let xml = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/books/</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>books</D:displayname>
        <D:resourcetype><D:collection/></D:resourcetype>
      </D:prop>
    </D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/books/novel.epub</D:href>
    <D:propstat>
      <D:prop>
        <D:displayname>novel.epub</D:displayname>
        <D:getcontentlength>12345</D:getcontentlength>
        <D:resourcetype/>
      </D:prop>
    </D:propstat>
  </D:response>
</D:multistatus>"#;

        let books = RemoteBookManager::parse_propfind_response(xml, "/dav/books/");
        assert_eq!(books.len(), 1);
        assert_eq!(books[0].filename, "novel.epub");
        assert_eq!(books[0].size, 12345);
        assert!(books[0].is_book_file());
    }

    #[test]
    fn test_extract_xml_value() {
        let xml = "<D:href>/dav/test.txt</D:href>";
        let val = RemoteBookManager::extract_xml_value(xml, "D:href");
        assert_eq!(val, Some("/dav/test.txt".to_string()));
    }

    #[test]
    fn test_remote_book_serialization() {
        let book = RemoteBook::from_file_info("a.pdf", "/dav/a.pdf", 999, Some(123));
        let json = serde_json::to_string(&book).unwrap();
        let deserialized: RemoteBook = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.filename, "a.pdf");
        assert_eq!(deserialized.size, 999);
        assert_eq!(deserialized.content_type, "pdf");
    }

    #[test]
    fn test_manager_new_trims_slash() {
        let mgr = RemoteBookManager::new("https://dav.example.com/books/", "user", "pass");
        assert_eq!(mgr.root_book_url, "https://dav.example.com/books");
    }
}
