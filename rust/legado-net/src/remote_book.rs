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

    /// 解析 PROPFIND XML 响应
    ///
    /// [体检 §二.6] 命名空间前缀无关:真实 WebDAV 服务器的多_STATUS 前缀五花八门
    /// (`D:`/`d:`/无前缀/自定义前缀),字符串 `split("<D:response>")` 换一个
    /// 不按 `D:` 前缀返回的服务器会静默变空。改为按**本地名**扫描(大小写不敏感)。
    fn parse_propfind_response(xml: &str, base_path: &str) -> Vec<RemoteBook> {
        let mut books = Vec::new();
        for response_block in Self::split_blocks_ci(xml, "response") {
            let href = Self::find_tag_value_ci(&response_block, "href");
            let display_name = Self::find_tag_value_ci(&response_block, "displayname");
            let content_length = Self::find_tag_value_ci(&response_block, "getcontentlength")
                .and_then(|s| s.parse::<u64>().ok());
            let is_collection = Self::block_has_tag_ci(&response_block, "collection");

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

            let size = content_length.unwrap_or(0);

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

    /// [体检 §二.6] 在 XML 中按**本地名**(忽略命名空间前缀,大小写不敏感)查找
    /// 第一个匹配标签的文本值。`<D:href>`、`<d:href>`、`<href>` 等同价。
    fn find_tag_value_ci(xml: &str, local: &str) -> Option<String> {
        let lower = xml.to_ascii_lowercase();
        let local_l = local.to_ascii_lowercase();
        let bytes = lower.as_bytes();
        let mut i = 0;
        while i < lower.len() {
            if bytes[i] != b'<' {
                i += 1;
                continue;
            }
            // 解析标签名(跳过闭合 '/',容忍前缀 ':'),本地名 = 最后一段
            let name_start = i + 1;
            let mut j = name_start;
            while j < lower.len() {
                let c = bytes[j];
                if c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b':' {
                    j += 1;
                } else {
                    break;
                }
            }
            let full = &lower[name_start..j];
            let local_part = full.rsplit(':').next().unwrap_or("");
            if full.starts_with('/') || local_part != local_l {
                i += 1;
                continue;
            }
            // open 标签结束 '>'
            let gt = j + lower[j..].find('>')?;
            // 对应闭合标签 '</(原全名)>'
            let close_pat = format!("</{full}>");
            let close_rel = lower[gt..].find(&close_pat)?;
            let value = xml[gt + 1..gt + close_rel].trim().to_string();
            return Some(value);
        }
        None
    }

    /// [体检 §二.6] 按本地名把 XML 切分为各 open..close 块内容(前缀无关)。
    /// 仅要求块不嵌套同名标签(WebDAV multistatus 的 response 块满足)。
    fn split_blocks_ci(xml: &str, local: &str) -> Vec<String> {
        let mut blocks = Vec::new();
        let lower = xml.to_ascii_lowercase();
        let local_l = local.to_ascii_lowercase();
        let bytes = lower.as_bytes();
        let mut i = 0;
        while i < lower.len() {
            if bytes[i] != b'<' {
                i += 1;
                continue;
            }
            let name_start = i + 1;
            let mut j = name_start;
            while j < lower.len() {
                let c = bytes[j];
                if c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b':' {
                    j += 1;
                } else {
                    break;
                }
            }
            let full = &lower[name_start..j];
            let local_part = full.rsplit(':').next().unwrap_or("");
            if full.starts_with('/') || local_part != local_l {
                i += 1;
                continue;
            }
            let Some(gt) = lower[j..].find('>') else {
                break;
            };
            let gt_abs = j + gt;
            let close_pat = format!("</{full}>");
            let Some(close_rel) = lower[gt_abs..].find(&close_pat) else {
                i += 1;
                continue;
            };
            let close_start = gt_abs + close_rel;
            blocks.push(xml[gt_abs + 1..close_start].to_string());
            i = close_start;
        }
        blocks
    }

    /// [体检 §二.6] 块内是否存在以 local 为本地名的标签(前缀无关)
    fn block_has_tag_ci(block: &str, local: &str) -> bool {
        let lower = block.to_ascii_lowercase();
        let local_l = local.to_ascii_lowercase();
        let bytes = lower.as_bytes();
        let mut i = 0;
        while i < lower.len() {
            if bytes[i] != b'<' {
                i += 1;
                continue;
            }
            let name_start = i + 1;
            let mut j = name_start;
            while j < lower.len() {
                let c = bytes[j];
                if c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b':' {
                    j += 1;
                } else {
                    break;
                }
            }
            let full = &lower[name_start..j];
            let local_part = full.rsplit(':').next().unwrap_or("");
            if !full.starts_with('/') && local_part == local_l {
                return true;
            }
            i += 1;
        }
        false
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
    fn test_find_tag_value_ci_prefix_agnostic() {
        // [体检 §二.6] 三种前缀形态同价:D: / d: / 无前缀
        assert_eq!(
            RemoteBookManager::find_tag_value_ci("<D:href>/a</D:href>", "href"),
            Some("/a".to_string())
        );
        assert_eq!(
            RemoteBookManager::find_tag_value_ci("<d:href>/a</d:href>", "href"),
            Some("/a".to_string())
        );
        assert_eq!(
            RemoteBookManager::find_tag_value_ci("<href>/a</href>", "href"),
            Some("/a".to_string())
        );
    }

    #[test]
    fn test_parse_propfind_prefix_variants() {
        // [体检 §二.6] 同一多_STATUS 的 D:/无前缀/自定义前缀三种形态必须等价解析
        let d_form = r#"<?xml version="1.0"?><D:multistatus>
            <D:response><D:href>/dav/books/</D:href><D:propstat><D:prop><D:collection/></D:prop></D:propstat></D:response>
            <D:response><D:href>/dav/books/novel.epub</D:href><D:propstat><D:prop><D:getcontentlength>12345</D:getcontentlength></D:prop></D:propstat></D:response>
        </D:multistatus>"#;
        let plain_form = d_form.replace("D:", "");
        let custom_form = d_form.replace("D:", "oc:");

        for (name, xml) in [
            ("D:", d_form),
            ("无前缀", &plain_form),
            ("自定义", custom_form.as_str()),
        ] {
            let books = RemoteBookManager::parse_propfind_response(xml, "/dav/books/");
            assert_eq!(books.len(), 1, "{name}: 应解析出 1 个文件");
            assert_eq!(books[0].filename, "novel.epub", "{name}");
            assert_eq!(books[0].size, 12345, "{name}");
        }
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
