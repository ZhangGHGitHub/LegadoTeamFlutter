//! 文件工具 API（`FsPolicy` 限域）
//!
//! 提供文件操作函数，对应 Kotlin 端 `JsExtensions` 中的文件方法：
//! - readFile — 读取文件内容
//! - writeFile — 写入文件（我方扩展，**非原版能力**：仅
//!   `allow_file_access=true` 时注册）
//! - fileExists — 检查文件是否存在（我方扩展，同上仅 permissive 注册）
//! - deleteFile — 删除文件
//! - readTxtFile — 读取文本文件（支持编码）
//! - downloadFile — 下载文件到沙箱（`(url)` / `(contentHex, url)` 为原版
//!   形态；`(url, fileName)` 文件名重载是我方扩展，仅 permissive 注册）
//! - cacheFile — 缓存网络文件（URL hash 为文件名，返回文件内容）
//! - importScript — 读取本地/远端 JS 脚本（远端经 cacheFile）
//! - getTxtInFolder — 获取文件夹下所有文件内容
//!
//! # 路径边界（P1-1）
//!
//! 所有路径统一经 [`FsPolicy`] 校验，本模块**不再自带第二套沙箱判断**：
//! - `allow_file_access=false`（书源生产路径）：仅允许引擎沙箱根
//!   （[`default_sandbox_root`]，可经 [`set_sandbox_root`] 由宿主注入应用
//!   缓存目录）与字体缓存目录内的路径；相对路径按沙箱根解析，绝对路径也
//!   必须落在允许根内，`..` / UNC / 设备前缀一律拒绝；
//! - `allow_file_access=true`（调试 / 可信脚本）：不做限制。
//!
//! # 书源隔离（P2-2）
//!
//! 沙箱根按当前书源 tag 分子目录（`<注入根>/<SHA-256(tag) 前 16 字节>`），
//! 无 tag 时用 `_shared`：`getTxtInFolder(".")` 只能遍历当前书源自己的
//! 文件，`downloadFile` / `cacheFile` 的落盘也互不可见。同一书源内
//! `downloadFile` 返回的路径可被 `readTxtFile` / `getFile` 直接消费。
//!
//! # 资源上限（P2-6）
//!
//! 单文件读取/下载 32MB、`getTxtInFolder` 累计 64MB（与
//! `archive_utils` 的单条目 32MB 同口径），超限返回显式错误，不静默截断。
//!
//! 越界/超限由调用方转成明确错误（字符串 API 返回 `[ERROR] ...`，布尔/对象
//! API 抛 JS 异常），不静默返回空值。

// ============================================================
// quickjs feature 启用时的真实实现
// ============================================================
#[cfg(feature = "quickjs")]
mod impl_file_utils {
    use std::fs::{self, File};
    use std::io::Read;
    use std::path::{Path, PathBuf};
    use std::sync::{Mutex, OnceLock};

    use crate::host_api::cache_store;
    use crate::host_api::fs_policy::FsPolicy;

    /// 单文件读取/下载上限（32MB，对齐 `archive_utils` 单条目与主题包
    /// `maxEntryBytes`）
    const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;

    /// `getTxtInFolder` 单次累计上限（64MB）
    ///
    /// 取单文件上限的 2 倍：书源场景一次读取的目录远小于该值，同时避免
    /// 「多条 32MB」叠加成 GB 级内存峰值。
    const MAX_FOLDER_BYTES: u64 = 64 * 1024 * 1024;

    /// 宿主注入的引擎沙箱根（P1-1）
    ///
    /// 与 `cache_store::set_cache_dir` 同型的进程级注入点：宿主（FFI/Android）
    /// 初始化时传入应用私有缓存目录下的子目录，使 `downloadFile` /
    /// `cacheFile` / `importScript` 的落盘位置与 `readFile` / `readTxtFile`
    /// 等读取根一致，并避开系统临时目录被清理导致的缓存丢失。
    /// 未注入时回落 `<系统临时目录>/legado_js_cache`（既有行为）。注入的是
    /// 父目录，实际沙箱根再按书源 tag 分子目录（P2-2）。
    static INJECTED_SANDBOX_ROOT: OnceLock<Mutex<Option<PathBuf>>> = OnceLock::new();

    /// 注入引擎沙箱根（宿主注入点；须在文件 API 使用前调用）
    ///
    /// 注入根是**各书源共享的父目录**，实际使用的沙箱根仍按书源 tag 分子
    /// 目录（见 [`default_sandbox_root`]）。
    pub fn set_sandbox_root(path: impl AsRef<Path>) {
        if let Ok(mut guard) = INJECTED_SANDBOX_ROOT
            .get_or_init(|| Mutex::new(None))
            .lock()
        {
            *guard = Some(path.as_ref().to_path_buf());
        }
        // 允许根 canonical 缓存随注入点失效
        crate::host_api::fs_policy::invalidate_allowed_roots_cache();
    }

    /// 当前注入的沙箱根（未注入返回 `None`，供文档/测试断言）
    pub fn injected_sandbox_root() -> Option<PathBuf> {
        INJECTED_SANDBOX_ROOT
            .get_or_init(|| Mutex::new(None))
            .lock()
            .ok()
            .and_then(|guard| guard.clone())
    }

    /// 引擎沙箱根（按书源分子目录）
    ///
    /// 优先级：宿主注入的父目录（[`set_sandbox_root`]）> 系统临时目录
    /// `legado_js_cache`；再拼当前书源作用域子目录：
    /// - 有 tag（`current_source::current_source_tag`）→
    ///   `SHA-256(tag)` 前 16 字节的十六进制（32 字符）；
    /// - 无 tag（`js_eval` 调试、单测等未绑定书源的入口）→ `_shared`。
    ///
    /// 用哈希而非原始 tag：tag 通常是书源 URL，含 `/`/`:` 等非法路径字符，
    /// 且可被书源作者控制；SHA-256 截断避免了路径注入与跨源目录碰撞
    /// （P2-2：防止 `getTxtInFolder(".")` 遍历到其他书源下载的文件）。
    pub fn default_sandbox_root() -> PathBuf {
        base_sandbox_root().join(sandbox_scope_dir())
    }

    /// 宿主注入（或系统临时目录回落的）沙箱父目录
    fn base_sandbox_root() -> PathBuf {
        injected_sandbox_root().unwrap_or_else(|| std::env::temp_dir().join("legado_js_cache"))
    }

    /// 当前书源作用域目录名（无 tag 时 `_shared`）
    fn sandbox_scope_dir() -> String {
        match crate::host_api::current_source::current_source_tag() {
            Some(tag) if !tag.is_empty() => {
                use sha2::{Digest, Sha256};
                let digest = Sha256::digest(tag.as_bytes());
                hex::encode(&digest[..16])
            }
            _ => "_shared".to_string(),
        }
    }

    /// 兼容旧名称
    pub fn sandbox_root() -> PathBuf {
        default_sandbox_root()
    }

    /// 解析安全路径（受限策略的读取语义；保留给单测/旧调用）
    ///
    /// 等价于 `FsPolicy::restricted().resolve_read_path(path)`。生产注册路径
    /// 直接按操作区分读写策略，不经过本函数。
    pub fn resolve_safe_path(path: &str) -> Result<PathBuf, String> {
        FsPolicy::restricted().resolve_read_path(path)
    }

    /// 读取文件内容（文本）
    ///
    /// 对应 Kotlin: `readFile(path)`；文件不存在返回空串（上游返回 null，
    /// JS 侧空串与 null 的消费形态一致，保持既有行为）。超过单文件上限
    /// （32MB）显式报错（P2-6）。
    pub fn read_file(policy: &FsPolicy, relative_path: &str) -> Result<String, String> {
        let path = policy.resolve_read_path(relative_path)?;
        if !path.exists() {
            return Ok(String::new());
        }
        let bytes = read_bytes_capped(&path)?;
        String::from_utf8(bytes).map_err(|e| format!("Read error: {}", e))
    }

    /// 按单文件上限读取字节（P2-6）
    ///
    /// 先看元数据快速拒绝，再以 `take(上限 + 1)` 复核——元数据可被并发修改，
    /// 不能只信声明大小；超限明确报错，不静默截断。
    fn read_bytes_capped(path: &Path) -> Result<Vec<u8>, String> {
        let meta = fs::metadata(path).map_err(|e| format!("Read error: {}", e))?;
        if meta.len() > MAX_FILE_BYTES {
            return Err(file_limit_error(path, meta.len()));
        }
        let file = File::open(path).map_err(|e| format!("Read error: {}", e))?;
        let mut bytes = Vec::with_capacity(meta.len() as usize);
        file.take(MAX_FILE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| format!("Read error: {}", e))?;
        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(file_limit_error(path, bytes.len() as u64));
        }
        Ok(bytes)
    }

    /// 单文件超限错误
    fn file_limit_error(path: &Path, size: u64) -> String {
        format!(
            "文件超出大小上限：{} {} 字节，超过单文件上限 {MAX_FILE_BYTES} 字节",
            path.display(),
            size
        )
    }

    /// 写入文件
    ///
    /// 对应 Kotlin: 无同名方法（我方扩展）；写入路径必须通过写策略校验。
    pub fn write_file(policy: &FsPolicy, relative_path: &str, content: &str) -> Result<(), String> {
        let path = policy.resolve_write_path(relative_path)?;
        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create parent dir: {}", e))?;
        }
        fs::write(&path, content).map_err(|e| format!("Write error: {}", e))
    }

    /// 检查文件是否存在
    ///
    /// 对应 Kotlin: `getFile(path).exists()`；越界抛错（上游 `getFile` 抛
    /// `SecurityException`），不静默返回 false。
    pub fn file_exists(policy: &FsPolicy, relative_path: &str) -> Result<bool, String> {
        let path = policy.resolve_read_path(relative_path)?;
        Ok(path.exists())
    }

    /// 删除文件
    ///
    /// 对应 Kotlin: `deleteFile(path)`；仅删除普通文件（不递归删目录，
    /// 避免 JS 侧误删沙箱目录树）。
    pub fn delete_file(policy: &FsPolicy, relative_path: &str) -> Result<bool, String> {
        let path = policy.resolve_write_path(relative_path)?;
        if path.exists() {
            fs::remove_file(&path).map_err(|e| format!("Delete error: {}", e))?;
            Ok(true)
        } else {
            Ok(false)
        }
    }

    /// 列出目录下所有文件名
    ///
    /// 仅单测/诊断使用，生产注册面不暴露该能力（上游无同名 API）。
    #[allow(dead_code)]
    pub fn list_files(policy: &FsPolicy, relative_path: &str) -> Result<Vec<String>, String> {
        let path = policy.resolve_read_path(relative_path)?;
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
    /// charset 支持: utf-8(默认), gbk, gb2312, big5, utf-16le, utf-16be 等；
    /// 超单文件上限（32MB）显式报错（P2-6）。
    pub fn read_txt_file(
        policy: &FsPolicy,
        path: &str,
        charset: Option<&str>,
    ) -> Result<String, String> {
        let resolved = policy.resolve_read_path(path)?;
        if !resolved.exists() {
            return Ok(String::new());
        }
        let bytes = read_bytes_capped(&resolved)?;

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

    /// 去掉 URL 的 query/fragment，便于取扩展名与文件名
    fn url_path_part(url: &str) -> &str {
        let no_fragment = url.split('#').next().unwrap_or(url);
        no_fragment.split('?').next().unwrap_or(no_fragment)
    }

    /// MD5 前 16 位（对齐 Kotlin `md5Encode16`）
    fn md5_hex16(input: &str) -> String {
        use md5::{Digest, Md5};

        let mut hasher = Md5::new();
        hasher.update(input.as_bytes());
        let hash_hex = hex::encode(hasher.finalize());
        hash_hex[..16].to_string()
    }

    /// downloadFile(url, fileName?) — 下载文件到沙箱
    ///
    /// 对应 Kotlin: `downloadFile(url)`（**单参**）；`fileName` 第二参数是
    /// 我方扩展，注册层仅在 `allow_file_access=true` 时接受（P1-1：非原版
    /// 能力不进入生产注册面）。返回沙箱内**绝对路径**（上游返回相对路径，
    /// 我方既有实现返回绝对路径，书源把返回值直接交给
    /// readTxtFile/getFile/解压 API 时两者等价）。
    ///
    /// 下载内容超过单文件上限（32MB，与 archive 单条目同口径）显式报错，
    /// 且在写盘**之前**拒绝（P2-6）。受 `get_bytes` 接口限制，内存峰值由
    /// 网络层完整缓冲决定，本函数只保证不把超大内容落盘。
    pub fn download_file(
        policy: &FsPolicy,
        url: &str,
        file_name: Option<&str>,
    ) -> Result<String, String> {
        let name = match file_name {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => url_path_part(url)
                .rsplit('/')
                .find(|s| !s.is_empty())
                .unwrap_or("download")
                .to_string(),
        };

        // 落盘路径必须先过写策略（越界在联网前即拒绝）
        let dest = policy.resolve_write_path(&name)?;

        // 异步下载（通过 block_on 桥接）：进程级共享池（2026-09-24 性能专项：
        // 不再每下载新建客户端/连接池；回环 URL 经 no_proxy 直连池）
        let bytes = crate::host_api::runtime_bridge::block_on(async {
            let client = crate::host_api::network::shared_client_for_url(url)
                .map_err(|e| format!("Download client error: {}", e))?;
            client
                .get_bytes(url, None)
                .await
                .map_err(|e| format!("Download error: {}", e))
        })?;

        if bytes.len() as u64 > MAX_FILE_BYTES {
            return Err(format!(
                "下载超出大小上限：{url} {} 字节，超过单文件上限 {MAX_FILE_BYTES} 字节",
                bytes.len()
            ));
        }

        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create dir: {}", e))?;
        }
        fs::write(&dest, &bytes).map_err(|e| format!("Write error: {}", e))?;
        Ok(dest.to_string_lossy().into_owned())
    }

    /// downloadFile(contentHex, url) — 废弃重载：十六进制内容按 url 类型落盘
    ///
    /// 对应 Kotlin: `@Deprecated downloadFile(content, url)`；返回相对文件名。
    pub fn download_file_from_hex(
        policy: &FsPolicy,
        content_hex: &str,
        url: &str,
    ) -> Result<String, String> {
        // 从 url 猜扩展名（对齐 AnalyzeUrl.type / UrlUtil.getSuffix 的轻量近似）
        let type_hint = url_path_part(url)
            .rsplit('.')
            .next()
            .filter(|s| s.len() <= 8 && s.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or("bin");

        let name = format!("{}.{type_hint}", md5_hex16(url));
        let dest = policy.resolve_write_path(&name)?;
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create dir: {}", e))?;
        }
        let bytes =
            hex::decode(content_hex.trim()).map_err(|e| format!("Hex decode error: {}", e))?;
        fs::write(&dest, &bytes).map_err(|e| format!("Write error: {}", e))?;
        // 返回相对路径（对齐 Kotlin substring(cachePath.length)）
        Ok(name)
    }

    /// cacheFile(url, saveTime?) — 缓存网络文件并返回**文件内容**
    ///
    /// 对应 Kotlin: `cacheFile(url)` / `cacheFile(url, saveTime)`：URL MD5
    /// 前 16 位为缓存键，`saveTime` 秒（0 = 永久）写入 `cache_store`；缓存
    /// 命中且文件仍存在时直接读取，否则下载后读取。返回内容而非路径——上游
    /// 与随包帮助 `eval(String(java.cacheFile(url)))` 均按内容消费。
    pub fn cache_file(policy: &FsPolicy, url: &str, save_time_secs: i64) -> Result<String, String> {
        let key = md5_hex16(url);

        // 缓存记录里的路径同样要过读策略（防止 JS 先 cache.put 一个越界路径）
        if let Some(cached_path) = cache_store::get(&key, false) {
            if !cached_path.is_empty()
                && Path::new(&cached_path).is_file()
                && policy.resolve_read_path(&cached_path).is_ok()
            {
                return read_txt_file(policy, &cached_path, None);
            }
        }

        // 保留原始扩展名（去掉 query/fragment 后取最后一段）
        let ext = url_path_part(url)
            .rsplit('.')
            .next()
            .filter(|s| s.len() <= 5 && s.chars().all(|c| c.is_alphanumeric()))
            .unwrap_or("cache");
        let cache_name = format!("{key}.{ext}");

        let path = download_file(policy, url, Some(&cache_name))?;
        cache_store::put(&key, &path, save_time_secs);
        read_txt_file(policy, &path, None)
    }

    /// importScript(urlOrPath) — 读取 JS 脚本内容（不自动 eval）
    ///
    /// 对应 Kotlin: `importScript(path)`：`http` 前缀经 [`cache_file`] 拉取，
    /// 其余按沙箱内本地路径读取；内容为空时返回明确错误（上游抛
    /// `NoStackTraceException`）。与 `allow_script_run` 的关系：本 API 只
    /// 返回脚本文本，是否执行由调用方 `eval(...)` 决定；书源生产引擎
    /// `allow_script_run=true`（对齐 Rhino 信任模型），严格调试引擎会替换
    /// 全局 `eval`——此时远端脚本不会被本 API 自动执行。
    pub fn import_script(policy: &FsPolicy, path: &str) -> Result<String, String> {
        let content = if path.starts_with("http") {
            cache_file(policy, path, 0)?
        } else {
            read_txt_file(policy, path, None)?
        };
        if content.trim().is_empty() {
            return Err(format!("{path} 内容获取失败或者为空"));
        }
        Ok(content)
    }

    /// getTxtInFolder(folderPath) — 获取文件夹下所有文件内容（换行拼接）
    ///
    /// 对应 Kotlin: `getTxtInFolder(path)`：读取文件夹内**所有文件**（不限
    /// 扩展名）并以换行拼接。有意偏差：上游读取后递归删除该文件夹，我方
    /// 不删除（避免 JS 侧对沙箱内容做破坏性清理；沙箱本身由系统临时目录
    /// 管理）。每个文件读取前单独过策略，防止目录内符号链接越界。
    ///
    /// 资源上限（P2-6）：先按元数据累计，超 64MB 直接拒绝（不读入）；读取
    /// 过程再按实际字节复核（元数据可被并发修改）。超限显式报错。
    pub fn get_txt_in_folder(policy: &FsPolicy, folder_path: &str) -> Result<String, String> {
        let resolved = policy.resolve_read_path(folder_path)?;
        if !resolved.exists() {
            return Err(format!("Folder not found: {}", folder_path));
        }
        if !resolved.is_dir() {
            return Err(format!("Not a directory: {}", folder_path));
        }

        // 第一遍：收集普通文件并按元数据累计，超限在读入前拒绝
        let entries = fs::read_dir(&resolved).map_err(|e| format!("ReadDir error: {}", e))?;
        let mut files = Vec::new();
        let mut declared_total = 0u64;
        for entry in entries {
            let entry = entry.map_err(|e| format!("Entry error: {}", e))?;
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let len = entry
                .metadata()
                .map_err(|e| format!("Entry metadata error: {}", e))?
                .len();
            declared_total = declared_total.saturating_add(len);
            if declared_total > MAX_FOLDER_BYTES {
                return Err(format!(
                    "文件夹累计超出大小上限：{}（{} 字节，上限 {MAX_FOLDER_BYTES} 字节）",
                    folder_path, declared_total
                ));
            }
            files.push(path);
        }

        // 第二遍：逐条校验策略并读取（目录内符号链接/junction 指向允许根
        // 之外时显式拒绝），实际累计再复核一次
        let mut contents = Vec::with_capacity(files.len());
        let mut read_total = 0u64;
        for path in files {
            let raw = path.to_string_lossy();
            let text = read_txt_file(policy, &raw, None)?;
            read_total = read_total.saturating_add(text.len() as u64);
            if read_total > MAX_FOLDER_BYTES {
                return Err(format!(
                    "文件夹累计超出大小上限：{}（实际读取 {read_total} 字节，\
                     上限 {MAX_FOLDER_BYTES} 字节）",
                    folder_path
                ));
            }
            contents.push(text);
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

    use crate::host_api::fs_policy::FsPolicy;

    fn not_available() -> String {
        "file_utils not available: build with --features quickjs".to_string()
    }

    pub fn set_sandbox_root(_path: impl AsRef<std::path::Path>) {}
    pub fn injected_sandbox_root() -> Option<PathBuf> {
        None
    }
    /// 未启用 quickjs 时没有书源执行上下文，固定 `_shared` 作用域目录
    pub fn default_sandbox_root() -> PathBuf {
        std::env::temp_dir().join("legado_js_cache").join("_shared")
    }
    pub fn sandbox_root() -> PathBuf {
        default_sandbox_root()
    }
    pub fn resolve_safe_path(_path: &str) -> Result<PathBuf, String> {
        Err(not_available())
    }
    pub fn read_file(_policy: &FsPolicy, _relative_path: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn write_file(
        _policy: &FsPolicy,
        _relative_path: &str,
        _content: &str,
    ) -> Result<(), String> {
        Err(not_available())
    }
    pub fn file_exists(_policy: &FsPolicy, _relative_path: &str) -> Result<bool, String> {
        Err(not_available())
    }
    pub fn delete_file(_policy: &FsPolicy, _relative_path: &str) -> Result<bool, String> {
        Err(not_available())
    }
    pub fn list_files(_policy: &FsPolicy, _relative_path: &str) -> Result<Vec<String>, String> {
        Err(not_available())
    }
    pub fn read_txt_file(
        _policy: &FsPolicy,
        _path: &str,
        _charset: Option<&str>,
    ) -> Result<String, String> {
        Err(not_available())
    }
    pub fn download_file(
        _policy: &FsPolicy,
        _url: &str,
        _file_name: Option<&str>,
    ) -> Result<String, String> {
        Err(not_available())
    }
    pub fn download_file_from_hex(
        _policy: &FsPolicy,
        _content_hex: &str,
        _url: &str,
    ) -> Result<String, String> {
        Err(not_available())
    }
    pub fn cache_file(
        _policy: &FsPolicy,
        _url: &str,
        _save_time_secs: i64,
    ) -> Result<String, String> {
        Err(not_available())
    }
    pub fn import_script(_policy: &FsPolicy, _path: &str) -> Result<String, String> {
        Err(not_available())
    }
    pub fn get_txt_in_folder(_policy: &FsPolicy, _folder_path: &str) -> Result<String, String> {
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
    use crate::host_api::fs_policy::FsPolicy;
    use std::fs;
    use std::path::PathBuf;

    fn restricted() -> FsPolicy {
        FsPolicy::restricted()
    }

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
        write_file(&restricted(), "test_rw.txt", "hello world").unwrap();
        let content = read_file(&restricted(), "test_rw.txt").unwrap();
        assert_eq!(content, "hello world");
        cleanup_test_file("test_rw.txt");
    }

    #[test]
    fn test_file_exists_true() {
        setup_sandbox();
        cleanup_test_file("test_exists.txt");
        write_file(&restricted(), "test_exists.txt", "data").unwrap();
        assert!(file_exists(&restricted(), "test_exists.txt").unwrap());
        cleanup_test_file("test_exists.txt");
    }

    #[test]
    fn test_file_exists_false() {
        setup_sandbox();
        assert!(!file_exists(&restricted(), "nonexistent_file_xyz.txt").unwrap());
    }

    #[test]
    fn test_delete_file() {
        setup_sandbox();
        cleanup_test_file("test_delete.txt");
        write_file(&restricted(), "test_delete.txt", "to delete").unwrap();
        assert!(delete_file(&restricted(), "test_delete.txt").unwrap());
        assert!(!file_exists(&restricted(), "test_delete.txt").unwrap());
    }

    #[test]
    fn test_delete_nonexistent() {
        setup_sandbox();
        assert!(!delete_file(&restricted(), "no_such_file_xyz.txt").unwrap());
    }

    #[test]
    fn test_read_nonexistent_returns_empty() {
        setup_sandbox();
        let content = read_file(&restricted(), "no_such_file.txt").unwrap();
        assert_eq!(content, "");
    }

    #[test]
    fn test_list_files_empty_dir() {
        setup_sandbox();
        let root = sandbox_root();
        let empty_subdir = root.join("empty_test_dir");
        let _ = fs::create_dir_all(&empty_subdir);
        let files = list_files(&restricted(), "empty_test_dir").unwrap();
        assert!(files.is_empty());
        let _ = fs::remove_dir(&empty_subdir);
    }

    // ---- 沙箱安全测试 ----

    #[test]
    fn test_sandbox_path_traversal_blocked() {
        setup_sandbox();
        // 尝试通过 .. 逃逸沙箱
        let result = restricted().resolve_read_path("../../etc/passwd");
        assert!(result.is_err(), "路径穿越应被阻止, got: {:?}", result);
        let err_msg = result.unwrap_err();
        assert!(
            err_msg.contains("文件访问被拒绝") && err_msg.contains("`..`"),
            "错误信息应说明路径穿越被拒绝, got: {}",
            err_msg
        );
    }

    #[test]
    fn test_sandbox_path_traversal_read_blocked() {
        setup_sandbox();
        // 通过 read_file 尝试路径穿越
        let result = read_file(&restricted(), "../../../etc/passwd");
        assert!(result.is_err(), "路径穿越读取应被阻止");
    }

    #[test]
    fn test_sandbox_valid_path() {
        setup_sandbox();
        // 正常相对路径应解析到沙箱内（P2-1：返回 canonical，比较也用 canonical）
        let result = restricted().resolve_read_path("subdir/file.txt");
        assert!(result.is_ok());
        let resolved = result.unwrap();
        let sandbox = fs::canonicalize(default_sandbox_root()).unwrap();
        let sandbox = {
            #[cfg(windows)]
            {
                let text = sandbox.to_string_lossy();
                match text.strip_prefix(r"\\?\") {
                    Some(rest) if !rest.starts_with("UNC\\") => PathBuf::from(rest),
                    _ => sandbox,
                }
            }
            #[cfg(not(windows))]
            {
                sandbox
            }
        };
        assert!(
            resolved.starts_with(&sandbox),
            "解析路径应在沙箱内: {:?}",
            resolved
        );
    }

    #[test]
    fn test_sandbox_absolute_path_outside_blocked() {
        setup_sandbox();
        // 沙箱外的绝对路径应被阻止
        let outside = if cfg!(windows) {
            "C:\\Windows\\System32\\cmd.exe"
        } else {
            "/etc/passwd"
        };
        let result = restricted().resolve_read_path(outside);
        assert!(result.is_err(), "沙箱外绝对路径应被阻止, got: {:?}", result);
    }

    #[test]
    fn test_sandbox_nested_traversal_blocked() {
        setup_sandbox();
        // 嵌套路径穿越
        let result = restricted().resolve_read_path("subdir/../../..");
        assert!(result.is_err(), "嵌套路径穿越应被阻止, got: {:?}", result);
    }

    // ---- readTxtFile 编码测试 ----

    #[test]
    fn test_read_txt_file_utf8() {
        setup_sandbox();
        cleanup_test_file("test_utf8.txt");
        let content = "你好世界 Hello World";
        write_file(&restricted(), "test_utf8.txt", content).unwrap();

        let result = read_txt_file(&restricted(), "test_utf8.txt", Some("utf-8")).unwrap();
        assert_eq!(result, content);

        // 默认编码也是 UTF-8
        let result_default = read_txt_file(&restricted(), "test_utf8.txt", None).unwrap();
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
        let result = read_txt_file(&restricted(), "test_gbk.txt", Some("gbk")).unwrap();
        assert_eq!(result, text);
        cleanup_test_file("test_gbk.txt");
    }

    #[test]
    fn test_read_txt_file_nonexistent() {
        setup_sandbox();
        let result = read_txt_file(&restricted(), "no_such_file.txt", None).unwrap();
        assert_eq!(result, "");
    }

    // ---- 文件操作综合测试 ----

    #[test]
    fn test_file_operations_in_sandbox() {
        setup_sandbox();
        let test_dir = "test_ops_dir";
        cleanup_test_dir(test_dir);

        // 写入子目录文件
        write_file(&restricted(), "test_ops_dir/a.txt", "file a").unwrap();
        write_file(&restricted(), "test_ops_dir/b.txt", "file b").unwrap();
        write_file(&restricted(), "test_ops_dir/c.log", "log c").unwrap();

        // 验证文件存在
        assert!(file_exists(&restricted(), "test_ops_dir/a.txt").unwrap());
        assert!(file_exists(&restricted(), "test_ops_dir/b.txt").unwrap());

        // 列出目录
        let files = list_files(&restricted(), test_dir).unwrap();
        assert_eq!(files.len(), 3);

        // getTxtInFolder 读取所有文件（对齐上游 listFiles，不限扩展名）
        let txt_content = get_txt_in_folder(&restricted(), test_dir).unwrap();
        assert!(txt_content.contains("file a"));
        assert!(txt_content.contains("file b"));
        assert!(txt_content.contains("log c"));

        // 删除文件
        assert!(delete_file(&restricted(), "test_ops_dir/a.txt").unwrap());
        assert!(!file_exists(&restricted(), "test_ops_dir/a.txt").unwrap());

        // 清理
        cleanup_test_dir(test_dir);
    }

    #[test]
    fn test_get_txt_in_folder_nonexistent() {
        setup_sandbox();
        let result = get_txt_in_folder(&restricted(), "nonexistent_folder_xyz");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Folder not found"));
    }

    #[test]
    fn test_get_txt_in_folder_not_a_dir() {
        setup_sandbox();
        cleanup_test_file("not_a_dir.txt");
        write_file(&restricted(), "not_a_dir.txt", "content").unwrap();
        let result = get_txt_in_folder(&restricted(), "not_a_dir.txt");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Not a directory"));
        cleanup_test_file("not_a_dir.txt");
    }
}
