//! 文件工具 API（沙箱化）
//!
//! 提供文件操作函数（沙箱内），对应 Kotlin 端 `JsExtensions` 中的文件方法：
//! - readFile — 读取文件内容
//! - writeFile — 写入文件
//! - fileExists — 检查文件是否存在
//! - deleteFile — 删除文件
//! - readTxtFile — 读取文本文件（支持编码）
//! - downloadFile — 下载文件到沙箱
//! - cacheFile — 缓存文件（URL hash 为文件名）
//! - importScript — 下载并读取 JS 脚本
//! - getTxtInFolder — 获取文件夹下文本文件内容
//!
//! 所有路径操作均限制在沙箱目录内，防止路径穿越攻击。

// ============================================================
// quickjs feature 启用时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_file_utils {
    use std::fs;
    use std::path::{Path, PathBuf};

    // 引入可选依赖 crate
    use encoding_rs;

    /// 默认沙箱根目录
    ///
    /// 对应 Kotlin: `appCtx.externalCache.absolutePath`
    /// 使用系统临时目录 + legado_js_cache 作为默认沙箱
    pub fn default_sandbox_root() -> PathBuf {
        std::env::temp_dir().join("legado_js_cache")
    }

    /// 兼容旧名称
    pub fn sandbox_root() -> PathBuf {
        default_sandbox_root()
    }

    /// 解析安全路径（沙箱校验：确保路径在沙箱目录内）
    ///
    /// - 相对路径：以沙箱根为基准拼接
    /// - 绝对路径：直接使用，但仍校验是否在沙箱内
    /// - 路径穿越（`..`）：检测并拒绝
    pub fn resolve_safe_path(path: &str) -> Result<PathBuf, String> {
        use std::path::Component;

        let sandbox_root = default_sandbox_root();
        if !sandbox_root.exists() {
            fs::create_dir_all(&sandbox_root)
                .map_err(|e| format!("Failed to create sandbox: {}", e))?;
        }

        // 词法检查：拒绝包含 .. 组件的路径（防止路径穿越）
        for component in Path::new(path).components() {
            if matches!(component, Component::ParentDir) {
                return Err(format!("Path traversal blocked: {}", path));
            }
        }

        let resolved = if Path::new(path).is_absolute() {
            PathBuf::from(path)
        } else {
            sandbox_root.join(path)
        };

        // 运行时检查：canonicalize 后确认路径在沙箱内
        if let Ok(canonical_sandbox) = sandbox_root.canonicalize() {
            if let Some(parent) = resolved.parent() {
                if parent.exists() {
                    if let Ok(canonical_parent) = parent.canonicalize() {
                        if !canonical_parent.starts_with(&canonical_sandbox) {
                            return Err(format!("Path traversal blocked: {}", path));
                        }
                    }
                }
            }
        }
        Ok(resolved)
    }

    /// 读取文件内容（文本）
    ///
    /// 对应 Kotlin: `readFile(path)`
    pub fn read_file(relative_path: &str) -> Result<String, String> {
        let path = resolve_safe_path(relative_path)?;
        if !path.exists() {
            return Ok(String::new());
        }
        fs::read_to_string(&path).map_err(|e| format!("Read error: {}", e))
    }

    /// 读取文件内容（字节）
    pub fn read_file_bytes(relative_path: &str) -> Result<Vec<u8>, String> {
        let path = resolve_safe_path(relative_path)?;
        if !path.exists() {
            return Ok(Vec::new());
        }
        fs::read(&path).map_err(|e| format!("Read error: {}", e))
    }

    /// 写入文件
    ///
    /// 对应 Kotlin: `writeFile(path, content)`
    pub fn write_file(relative_path: &str, content: &str) -> Result<(), String> {
        let path = resolve_safe_path(relative_path)?;
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create parent dir: {}", e))?;
        }
        fs::write(&path, content).map_err(|e| format!("Write error: {}", e))
    }

    /// 检查文件是否存在
    ///
    /// 对应 Kotlin: `getFile(path).exists()`
    pub fn file_exists(relative_path: &str) -> Result<bool, String> {
        let path = resolve_safe_path(relative_path)?;
        Ok(path.exists())
    }

    /// 删除文件
    ///
    /// 对应 Kotlin: `deleteFile(path)`
    pub fn delete_file(relative_path: &str) -> Result<bool, String> {
        let path = resolve_safe_path(relative_path)?;
        if path.exists() {
            fs::remove_file(&path).map_err(|e| format!("Delete error: {}", e))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// 列出目录下所有文件名
    pub fn list_files(relative_path: &str) -> Result<Vec<String>, String> {
        let path = resolve_safe_path(relative_path)?;
        if !path.is_dir() {
            return Ok(Vec::new());
        }
        let entries = fs::read_dir(&path).map_err(|e| format!("ReadDir error: {}", e))?;
        let mut names = Vec::new();
        for entry in entries {
            let entry = entry.map_err(|e| format!("Entry error: {}", e))?;
            if let Some(name) = entry.file_name().to_str() {
                names.push(name.to_string());
            }
        }
        Ok(names)
    }

    // ============================================================
    // 新增文件 API
    // ============================================================

    /// readTxtFile(path, charset?) — 读取文本文件（支持编码指定）
    ///
    /// 对应 Kotlin: `readTxtFile(path, charset)`
    /// charset 支持: utf-8(默认), gbk, gb2312, big5, utf-16le, utf-16be 等
    pub fn read_txt_file(path: &str, charset: Option<&str>) -> Result<String, String> {
        let resolved = resolve_safe_path(path)?;
        if !resolved.exists() {
            return Ok(String::new());
        }
        let bytes = fs::read(&resolved).map_err(|e| format!("Read error: {}", e))?;

        let encoding_name = charset.unwrap_or("utf-8");
        let encoding = encoding_rs::Encoding::for_label(encoding_name.as_bytes())
            .unwrap_or(encoding_rs::UTF_8);

        let (decoded, _, had_errors) = encoding.decode(&bytes);
        if had_errors {
            // 回退到 lossy UTF-8
            return Ok(String::from_utf8_lossy(&bytes).into_owned());
        }
        Ok(decoded.into_owned())
    }

    /// downloadFile(url, fileName?) — 下载文件到沙箱
    ///
    /// 对应 Kotlin: `downloadFile(url, fileName)`
    /// 返回沙箱内文件路径
    pub fn download_file(url: &str, file_name: Option<&str>) -> Result<String, String> {
        let name = match file_name {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => {
                // 从 URL 提取文件名
                url.rsplit('/')
                    .next()
                    .filter(|s| !s.is_empty())
                    .unwrap_or("download")
                    .to_string()
            }
        };

        let dest = resolve_safe_path(&name)?;
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create dir: {}", e))?;
        }

        // 使用 LegadoClient 异步下载（通过 block_on 桥接）
        let bytes = crate::host_api::runtime_bridge::block_on(async {
            let config = legado_net::LegadoClientConfig::default();
            let client = legado_net::LegadoClient::new(config)
                .map_err(|e| format!("Download client error: {}", e))?;
            client
                .get_bytes(url, None)
                .await
                .map_err(|e| format!("Download error: {}", e))
        })?;

        fs::write(&dest, &bytes).map_err(|e| format!("Write error: {}", e))?;
        Ok(dest.to_string_lossy().into_owned())
    }

    /// downloadFile(contentHex, url) — 废弃重载：十六进制内容按 url 类型落盘
    ///
    /// 对应 Kotlin: `@Deprecated downloadFile(content, url)`
    pub fn download_file_from_hex(content_hex: &str, url: &str) -> Result<String, String> {
        use md5::{Digest, Md5};

        // 从 url 猜扩展名（对齐 AnalyzeUrl.type / UrlUtil.getSuffix 的轻量近似）
        let type_hint = url
            .split(',')
            .next()
            .unwrap_or(url)
            .rsplit('.')
            .next()
            .filter(|s| s.len() <= 8 && s.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or("bin");

        let mut hasher = Md5::new();
        hasher.update(url.as_bytes());
        let hash16 = hex::encode(hasher.finalize());
        let hash16 = if hash16.len() >= 16 {
            &hash16[..16]
        } else {
            &hash16
        };
        let name = format!("{hash16}.{type_hint}");
        let dest = resolve_safe_path(&name)?;
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create dir: {}", e))?;
        }
        let bytes =
            hex::decode(content_hex.trim()).map_err(|e| format!("Hex decode error: {}", e))?;
        fs::write(&dest, &bytes).map_err(|e| format!("Write error: {}", e))?;
        // 返回相对路径（对齐 Kotlin substring(cachePath.length)）
        Ok(name)
    }

    /// cacheFile(url) — 缓存文件（URL MD5 hash 为文件名）
    ///
    /// 对应 Kotlin: `cacheFile(url)`
    /// 如果缓存已存在则直接返回路径，否则下载后缓存
    pub fn cache_file(url: &str) -> Result<String, String> {
        use md5::{Digest, Md5};

        // 计算 URL 的 MD5 作为缓存文件名
        let mut hasher = Md5::new();
        hasher.update(url.as_bytes());
        let hash_hex = hex::encode(hasher.finalize());

        // 保留原始扩展名
        let ext = url
            .rsplit('.')
            .next()
            .filter(|s| s.len() <= 5 && s.chars().all(|c| c.is_alphanumeric()))
            .unwrap_or("cache");
        let cache_name = format!("{}.{}", hash_hex, ext);

        let cache_path = resolve_safe_path(&cache_name)?;

        // 缓存命中
        if cache_path.exists() {
            return Ok(cache_path.to_string_lossy().into_owned());
        }

        // 下载并写入缓存
        download_file(url, Some(&cache_name))
    }

    /// importScript(url) — 下载并读取 JS 脚本内容
    ///
    /// 对应 Kotlin: `importScript(url)`
    /// 先检查沙箱缓存，若不存在则下载后读取
    pub fn import_script(url: &str) -> Result<String, String> {
        // 先尝试缓存
        let cached_path = cache_file(url)?;
        // 读取缓存文件内容
        let content = fs::read_to_string(&cached_path)
            .map_err(|e| format!("importScript read error: {}", e))?;
        Ok(content)
    }

    /// getTxtInFolder(folderPath) — 获取文件夹下所有文本文件内容（拼接）
    ///
    /// 对应 Kotlin: `getTxtInFolder(folderPath)`
    /// 读取文件夹内所有 .txt 文件内容并以换行拼接
    pub fn get_txt_in_folder(folder_path: &str) -> Result<String, String> {
        let resolved = resolve_safe_path(folder_path)?;
        if !resolved.exists() {
            return Err(format!("Folder not found: {}", folder_path));
        }
        if !resolved.is_dir() {
            return Err(format!("Not a directory: {}", folder_path));
        }

        let entries = fs::read_dir(&resolved).map_err(|e| format!("ReadDir error: {}", e))?;
        let mut contents = Vec::new();

        for entry in entries {
            let entry = entry.map_err(|e| format!("Entry error: {}", e))?;
            let path = entry.path();
            if path.is_file() {
                // 只读取 .txt 文件
                if let Some(ext) = path.extension() {
                    if ext.eq_ignore_ascii_case("txt") {
                        if let Ok(text) = fs::read_to_string(&path) {
                            contents.push(text);
                        }
                    }
                }
            }
        }

        Ok(contents.join("\n"))
    }
}

#[cfg(feature = "quickjs")]
pub use impl_file_utils::*;

// ============================================================
// 未启用 quickjs feature 时的占位实现
// ============================================================
#[cfg(not(feature = "quickjs"))]
mod stub_file_utils {
    use std::path::PathBuf;

    fn not_available() -> String {
        "file_utils not available: build with --features quickjs".to_string()
    }

    pub fn default_sandbox_root() -> PathBuf {
        std::env::temp_dir().join("legado_js_cache")
    }
    pub fn sandbox_root() -> PathBuf {
        default_sandbox_root()
    }
    pub fn resolve_safe_path(_path: &str) -> Result<PathBuf, String> {
        Err(not_available())
    }
    pub fn read_file(_relative_path: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn read_file_bytes(_relative_path: &str) -> Result<Vec<u8>, String> {
        Err(not_available())
    }
    pub fn write_file(_relative_path: &str, _content: &str) -> Result<(), String> {
        Err(not_available())
    }
    pub fn file_exists(_relative_path: &str) -> Result<bool, String> {
        Err(not_available())
    }
    pub fn delete_file(_relative_path: &str) -> Result<bool, String> {
        Err(not_available())
    }
    pub fn list_files(_relative_path: &str) -> Result<Vec<String>, String> {
        Err(not_available())
    }
    pub fn read_txt_file(_path: &str, _charset: Option<&str>) -> Result<String, String> {
        Err(not_available())
    }
    pub fn download_file(_url: &str, _file_name: Option<&str>) -> Result<String, String> {
        Err(not_available())
    }
    pub fn download_file_from_hex(_content_hex: &str, _url: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn cache_file(_url: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn import_script(_url: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn get_txt_in_folder(_folder_path: &str) -> Result<String, String> {
        Err(not_available())
    }
}

#[cfg(not(feature = "quickjs"))]
pub use stub_file_utils::*;

// ============================================================
// 单元测试
// ============================================================
#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;
    use std::fs;

    fn setup_sandbox() {
        let root = sandbox_root();
        let _ = fs::create_dir_all(&root);
    }

    fn cleanup_test_file(name: &str) {
        let path = sandbox_root().join(name);
        let _ = fs::remove_file(&path);
    }

    fn cleanup_test_dir(name: &str) {
        let path = sandbox_root().join(name);
        let _ = fs::remove_dir_all(&path);
    }

    // ---- 基本文件操作测试 ----

    #[test]
    fn test_write_and_read_file() {
        setup_sandbox();
        cleanup_test_file("test_rw.txt");
        write_file("test_rw.txt", "hello world").unwrap();
        let content = read_file("test_rw.txt").unwrap();
        assert_eq!(content, "hello world");
        cleanup_test_file("test_rw.txt");
    }

    #[test]
    fn test_file_exists_true() {
        setup_sandbox();
        cleanup_test_file("test_exists.txt");
        write_file("test_exists.txt", "data").unwrap();
        assert!(file_exists("test_exists.txt").unwrap());
        cleanup_test_file("test_exists.txt");
    }

    #[test]
    fn test_file_exists_false() {
        setup_sandbox();
        assert!(!file_exists("nonexistent_file_xyz.txt").unwrap());
    }

    #[test]
    fn test_delete_file() {
        setup_sandbox();
        cleanup_test_file("test_delete.txt");
        write_file("test_delete.txt", "to delete").unwrap();
        assert!(delete_file("test_delete.txt").unwrap());
        assert!(!file_exists("test_delete.txt").unwrap());
    }

    #[test]
    fn test_delete_nonexistent() {
        setup_sandbox();
        assert!(!delete_file("no_such_file_xyz.txt").unwrap());
    }

    #[test]
    fn test_read_nonexistent_returns_empty() {
        setup_sandbox();
        let content = read_file("no_such_file.txt").unwrap();
        assert_eq!(content, "");
    }

    #[test]
    fn test_list_files_empty_dir() {
        setup_sandbox();
        let root = sandbox_root();
        let empty_subdir = root.join("empty_test_dir");
        let _ = fs::create_dir_all(&empty_subdir);
        let files = list_files("empty_test_dir").unwrap();
        assert!(files.is_empty());
        let _ = fs::remove_dir(&empty_subdir);
    }

    // ---- 沙箱安全测试 ----

    #[test]
    fn test_sandbox_path_traversal_blocked() {
        setup_sandbox();
        // 尝试通过 .. 逃逸沙箱
        let result = resolve_safe_path("../../etc/passwd");
        assert!(result.is_err(), "路径穿越应被阻止, got: {:?}", result);
        let err_msg = result.unwrap_err();
        assert!(
            err_msg.contains("Path traversal blocked"),
            "错误信息应包含 'Path traversal blocked', got: {}",
            err_msg
        );
    }

    #[test]
    fn test_sandbox_path_traversal_read_blocked() {
        setup_sandbox();
        // 通过 read_file 尝试路径穿越
        let result = read_file("../../../etc/passwd");
        assert!(
            result.is_err() || result.as_deref() == Ok(""),
            "路径穿越读取应被阻止或返回空"
        );
    }

    #[test]
    fn test_sandbox_valid_path() {
        setup_sandbox();
        // 正常相对路径应解析到沙箱内
        let result = resolve_safe_path("subdir/file.txt");
        assert!(result.is_ok());
        let resolved = result.unwrap();
        let sandbox = default_sandbox_root();
        assert!(
            resolved.starts_with(&sandbox),
            "解析路径应在沙箱内: {:?}",
            resolved
        );
    }

    #[test]
    fn test_sandbox_absolute_path_outside_blocked() {
        setup_sandbox();
        // 沙箱外的绝对路径应被阻止（如果其 parent 存在）
        let outside = if cfg!(windows) {
            "C:\\Windows\\System32\\cmd.exe"
        } else {
            "/etc/passwd"
        };
        let result = resolve_safe_path(outside);
        // 绝对路径在沙箱外，parent 存在且不在沙箱内 → 应被阻止
        assert!(result.is_err(), "沙箱外绝对路径应被阻止, got: {:?}", result);
    }

    #[test]
    fn test_sandbox_nested_traversal_blocked() {
        setup_sandbox();
        // 嵌套路径穿越
        let result = resolve_safe_path("subdir/../../..");
        assert!(result.is_err(), "嵌套路径穿越应被阻止, got: {:?}", result);
    }

    // ---- readTxtFile 编码测试 ----

    #[test]
    fn test_read_txt_file_utf8() {
        setup_sandbox();
        cleanup_test_file("test_utf8.txt");
        let content = "你好世界 Hello World";
        write_file("test_utf8.txt", content).unwrap();

        let result = read_txt_file("test_utf8.txt", Some("utf-8")).unwrap();
        assert_eq!(result, content);

        // 默认编码也是 UTF-8
        let result_default = read_txt_file("test_utf8.txt", None).unwrap();
        assert_eq!(result_default, content);
        cleanup_test_file("test_utf8.txt");
    }

    #[test]
    fn test_read_txt_file_gbk() {
        setup_sandbox();
        cleanup_test_file("test_gbk.txt");

        // 用 GBK 编码写入中文
        let text = "你好世界";
        let (encoded, _enc, _err) = encoding_rs::GBK.encode(text);
        let sandbox = default_sandbox_root();
        let file_path = sandbox.join("test_gbk.txt");
        fs::write(&file_path, &encoded[..]).unwrap();

        // 用 GBK 编码读取
        let result = read_txt_file("test_gbk.txt", Some("gbk")).unwrap();
        assert_eq!(result, text);
        cleanup_test_file("test_gbk.txt");
    }

    #[test]
    fn test_read_txt_file_nonexistent() {
        setup_sandbox();
        let result = read_txt_file("no_such_file.txt", None).unwrap();
        assert_eq!(result, "");
    }

    // ---- 文件操作综合测试 ----

    #[test]
    fn test_file_operations_in_sandbox() {
        setup_sandbox();
        let test_dir = "test_ops_dir";
        cleanup_test_dir(test_dir);

        // 写入子目录文件
        write_file("test_ops_dir/a.txt", "file a").unwrap();
        write_file("test_ops_dir/b.txt", "file b").unwrap();
        write_file("test_ops_dir/c.log", "log c").unwrap();

        // 验证文件存在
        assert!(file_exists("test_ops_dir/a.txt").unwrap());
        assert!(file_exists("test_ops_dir/b.txt").unwrap());

        // 列出目录
        let files = list_files(test_dir).unwrap();
        assert_eq!(files.len(), 3);

        // getTxtInFolder 只读取 .txt
        let txt_content = get_txt_in_folder(test_dir).unwrap();
        assert!(txt_content.contains("file a"));
        assert!(txt_content.contains("file b"));
        assert!(!txt_content.contains("log c"));

        // 删除文件
        assert!(delete_file("test_ops_dir/a.txt").unwrap());
        assert!(!file_exists("test_ops_dir/a.txt").unwrap());

        // 清理
        cleanup_test_dir(test_dir);
    }

    #[test]
    fn test_get_txt_in_folder_nonexistent() {
        setup_sandbox();
        let result = get_txt_in_folder("nonexistent_folder_xyz");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Folder not found"));
    }

    #[test]
    fn test_get_txt_in_folder_not_a_dir() {
        setup_sandbox();
        cleanup_test_file("not_a_dir.txt");
        write_file("not_a_dir.txt", "content").unwrap();
        let result = get_txt_in_folder("not_a_dir.txt");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Not a directory"));
        cleanup_test_file("not_a_dir.txt");
    }
}
