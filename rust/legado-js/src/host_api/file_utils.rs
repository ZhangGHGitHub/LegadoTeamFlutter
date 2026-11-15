//! 文件工具 API（`FsPolicy` 限域）
//!
//! 提供文件操作函数，对应 Kotlin 端 `JsExtensions` 中的文件方法：
//! - readFile — 读取文件内容
//! - writeFile — 写入文件（我方扩展，**非原版能力**：仅
//!   `allow_file_access=true` 时注册）
//! - fileExists — 检查文件是否存在（我方扩展，同上仅 permissive 注册）
//! - deleteFile — 删除文件或目录（目录递归，对齐上游
//!   `FileUtils.delete(file, true)`）
//! - readTxtFile — 读取文本文件（支持编码）
//! - downloadFile — 下载文件到沙箱（`(url)` / `(contentHex, url)` 为原版
//!   形态；`(url, fileName)` 文件名重载是我方扩展，仅 permissive 注册），
//!   按**原始字节**落盘（二进制无损）；命名与返回值对齐上游
//!   `JsExtensions.kt:518-540`：`<md5Encode16(url)>.<type>`，返回源内
//!   **相对名**（上游返回相对缓存目录的路径）。URL 后的 `,{...}` 选项
//!   参与命名，网络请求前经 `split_url_option` 剥离（选项内
//!   `headers` / `method` 暂不支持，见 [`download_file`]）
//! - cacheFile — 缓存网络文件（`md5Encode16(url)` 为键与文件名，返回文件内容）
//! - importScript — 读取本地/远端 JS 脚本（远端经 cacheFile）
//! - getTxtInFolder — 获取文件夹下所有文件内容（读完删除该目录，对齐上游
//!   `JsExtensions.kt:917`）
//!
//! # 路径边界（P1-1）
//!
//! 所有路径统一经 [`FsPolicy`] 校验，本模块**不再自带第二套沙箱判断**：
//! - `allow_file_access=false`（书源生产路径）：仅允许引擎沙箱根
//!   （[`default_sandbox_root`]，可经 [`set_sandbox_root`] 由宿主注入应用
//!   缓存目录）与字体缓存目录内的路径；相对路径按沙箱根解析，绝对路径也
//!   必须落在允许根内，`..` / UNC / 设备前缀一律拒绝。**字体缓存为只读
//!   共享资源**：读取允许（复用），写入/删除/解压输出一律拒绝（批33 P2-2）；
//! - `allow_file_access=true`（调试 / 可信脚本）：不做限制。
//!
//! # 书源隔离（P2-2）
//!
//! 沙箱根按当前书源 tag 分子目录（`<注入根>/<SHA-256(tag) 前 16 字节>`），
//! 无 tag 时用 `_shared`：`getTxtInFolder(".")` 只能遍历当前书源自己的
//! 文件，`downloadFile` / `cacheFile` 的落盘也互不可见。同一书源内
//! `downloadFile` 返回的**相对名**可被 `readTxtFile` / `getFile` 直接消费
//! （两者相对路径按当前书源沙箱根解析）。
//! `cacheFile` 的 URL→文件映射同样收敛为**源内相对名**（见 [`cache_file`]）：
//! 命中按当前源沙箱解析，多源共享同一 URL 不再互相覆盖，
//! `cache.get(md5Encode16(url))` 也不会泄露其他源的绝对路径。
//!
//! # 目录删除（批33 偏差收口）
//!
//! 上游 `deleteFile` 对目录**递归删除**（`JsExtensions.kt:848` →
//! `FileUtils.delete(file, true)`）、`getTxtInFolder` 读完**删除目录**
//! （`JsExtensions.kt:917`），本模块同步该副作用。差异：我方沙箱根按书源
//! 隔离，删掉根目录会让本源后续 `downloadFile` / `cacheFile` /
//! `getTxtInFolder` 全部失效，因此两个入口都拒绝删除引擎根（沙箱根 /
//! 字体缓存根），返回明确错误或告警，不静默清空。
//!
//! 递归删除还有一层**与沙箱策略无关**的保护（P2-2）：`allow_file_access=true`
//! 时 `FsPolicy` 原样放行任意路径，若脚本对 `.` 调用 `deleteFile` /
//! `getTxtInFolder`，目标就是**进程 CWD**。Unix/Android 的
//! `remove_dir_all` 会先逐项删空 CWD 内容、再因无法删除 `.` 报错；
//! `getTxtInFolder` 只告警并照常返回，用户数据已丢。因此 [`remove_path`]
//! 对**目录递归删除**额外拒绝「当前工作目录及其祖先」（permissive 下同样
//! 生效）；引擎根内允许，引擎根外仅放行与 CWD 无关的目标。
//!
//! # 资源上限（P2-6 / P1-1）
//!
//! 单文件读取/下载 32MB、`getTxtInFolder` 累计 64MB（与
//! `archive_utils` 的单条目 32MB 同口径），超限返回显式错误，不静默截断。
//! 下载在 legado-net 侧**逐块累计**并在超限时立即中止（内存峰值不超过
//! 上限），不再「网络层完整缓冲后于落盘前判断」；`Content-Length` 声明值
//! 已超限时在读取响应体前快速拒绝。
//!
//! 下载内容按**原始字节**写盘（P1-2）：不经 UTF-8 文本解码，非 UTF-8
//! 二进制（图片/字体/压缩包）与源字节完全一致。`cacheFile` 因上游契约返回
//! 文本，读取时按 UTF-8 解码、非法序列回退 U+FFFD（对齐 Kotlin
//! `File.readText()`）；二进制内容应使用 `downloadFile` 取路径。
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
    // 单文件读取/下载上限（32MB）统一维护在 `host_api::MAX_FILE_BYTES`，
    // 字体 API 复用同一口径
    use crate::host_api::MAX_FILE_BYTES;

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

    /// 删除文件或目录
    ///
    /// 对应 Kotlin: `deleteFile(path)`（`JsExtensions.kt:848-851`：
    /// `FileUtils.delete(getFile(path), true)`）——**目录递归删除**，返回是否
    /// 存在并删除成功。差异（安全边界）：`path` 解析后等于引擎根（当前书源
    /// 沙箱根 / 字体缓存根）时拒绝并返回明确错误——我方沙箱按书源隔离，
    /// 根目录就是该源的整个存储空间，删掉会让本源后续文件 API 全部失效；
    /// 上游共享 `externalCache`，不存在这个「本源根」概念。目录递归删除
    /// 另拒绝当前工作目录及其祖先（P2-2，permissive 下同样生效）。
    ///
    /// 字体缓存为跨源共享的只读资源：其**内部文件**在 [`FsPolicy::resolve_write_path`]
    /// 阶段即被拒绝（不会走到删除）；引擎根保护只兜底 permissive 模式下
    /// 误删根目录的情形（批33 P2-2 残留面）。
    pub fn delete_file(policy: &FsPolicy, relative_path: &str) -> Result<bool, String> {
        let path = policy.resolve_write_path(relative_path)?;
        if !path.exists() {
            return Ok(false);
        }
        remove_path(&path)?;
        Ok(true)
    }

    /// 递归删除文件/目录（调用方已完成 `FsPolicy` 写策略校验）
    ///
    /// 保护顺序（P2-2 / P3-2）：
    /// 1. 目标必须先能 `canonicalize`——路径存在但解析失败时返回明确错误，
    ///    不再 `Ok(())` 放行（fail-closed）；
    /// 2. 目标等于引擎根（[`default_sandbox_root`] /
    ///    `font_api::font_cache_dir`）→ 拒绝；
    /// 3. **目录递归删除**时，目标等于当前工作目录或是 CWD 的祖先 → 拒绝
    ///    （`allow_file_access=true` 下同样生效，防止清空进程 CWD）；
    /// 4. 其余目录：引擎根内允许；引擎根外仅放行与 CWD 无关的目标
    ///    （permissive 的调试语义保留，但不能删除 CWD 及其祖先）。
    ///
    /// 删除单个文件不做 CWD 判定：删文件不可能清空目录。
    /// `getTxtInFolder` 侧把这里的错误降级为告警，返回内容不受影响。
    pub(crate) fn remove_path(path: &Path) -> Result<(), String> {
        remove_path_with_cwd(path, std::env::current_dir().ok().as_deref())
    }

    /// [`remove_path`] 的实现（`current_dir` 可注入，便于用临时目录模拟
    /// CWD 做保护测试，避免测试真正切换进程工作目录）
    pub(super) fn remove_path_with_cwd(
        path: &Path,
        current_dir: Option<&Path>,
    ) -> Result<(), String> {
        let metadata = fs::symlink_metadata(path).map_err(|e| format!("Delete error: {}", e))?;
        let target = canonicalize_existing(path)?;
        let roots = engine_roots_canonical();
        if roots.iter().any(|root| root == &target) {
            return Err(format!(
                "Delete error: 拒绝删除引擎沙箱根目录（{}）",
                path.display()
            ));
        }
        if metadata.is_dir() {
            let inside_engine_root = roots.iter().any(|root| target.starts_with(root));
            match current_dir {
                Some(dir) => match fs::canonicalize(dir) {
                    Ok(cwd) => {
                        if cwd.starts_with(&target) {
                            return Err(format!(
                                "Delete error: 拒绝删除当前工作目录或其祖先目录（{}）",
                                path.display()
                            ));
                        }
                    }
                    Err(error) => {
                        return Err(format!(
                            "Delete error: 无法解析当前工作目录（{}）：{error}",
                            dir.display()
                        ));
                    }
                },
                None if !inside_engine_root => {
                    return Err(format!(
                        "Delete error: 无法确定当前工作目录，拒绝递归删除（{}）",
                        path.display()
                    ));
                }
                None => {}
            }
            fs::remove_dir_all(path).map_err(|e| format!("Delete error: {}", e))
        } else {
            fs::remove_file(path).map_err(|e| format!("Delete error: {}", e))
        }
    }

    /// `canonicalize` 已存在目标（P3-2：失败即明确错误，不再 fail-open）
    fn canonicalize_existing(path: &Path) -> Result<PathBuf, String> {
        fs::canonicalize(path).map_err(|error| {
            format!(
                "Delete error: 无法解析目标路径（{}）：{error}",
                path.display()
            )
        })
    }

    /// 引擎根（canonical 形式；不存在/无法解析的根跳过）
    fn engine_roots_canonical() -> Vec<PathBuf> {
        [
            default_sandbox_root(),
            crate::host_api::font_api::font_cache_dir(),
        ]
        .into_iter()
        .filter_map(|root| fs::canonicalize(root).ok())
        .collect()
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

    /// 从 URL 中分离 `,{...}` 选项（对齐上游 `AnalyzeUrl.paramPattern`）
    ///
    /// 上游正则 `\s*,\s*(?=\{)`：第一个「逗号 + 可选空白 + `{`」处切分；
    /// 前半为实际请求 URL，后半为选项 JSON。`data:` URI 不属于下载场景，此处
    /// 不做 `legado-parser` 的 base64 特判。
    ///
    /// 与上游的逐条细节差异及保留理由见 [`download_file_name`] 的
    /// 「有意差异」清单（批37 收尾）。此处不复用 `legado-parser` 的私有
    /// 选项切分：其要求剩余串以 `}` 结尾，且绑定 `AnalyzeUrl` 的模板替换 /
    /// 请求构造语义，用作命名入口会改变现有行为。
    fn split_url_option(url: &str) -> (&str, Option<&str>) {
        let bytes = url.as_bytes();
        let mut index = 0;
        while index < bytes.len() {
            if bytes[index] == b',' {
                let mut probe = index + 1;
                while probe < bytes.len()
                    && matches!(bytes[probe], b' ' | b'\t' | b'\n' | b'\r' | 0x0b | 0x0c)
                {
                    probe += 1;
                }
                if probe < bytes.len() && bytes[probe] == b'{' {
                    return (&url[..index], Some(&url[probe..]));
                }
            }
            index += 1;
        }
        (url, None)
    }

    /// URL 选项 JSON 中的 `type`（对齐 `AnalyzeUrl.type` / `UrlOption.getType`）
    ///
    /// 仅接受字符串且非空白（`getType()` 对 blank 返回 null）；JSON 非法 /
    /// 非对象 / 无 `type` 均视为无选项类型。返回值未做文件名安全校验，由
    /// `download_file_name` 统一收敛。
    fn url_option_type(url: &str) -> Option<String> {
        let (_, option) = split_url_option(url);
        let value: serde_json::Value = serde_json::from_str(option?).ok()?;
        let type_hint = value.get("type")?.as_str()?;
        (!type_hint.trim().is_empty()).then(|| type_hint.to_string())
    }

    /// 扩展名（对齐上游 `UrlUtil.getSuffix`）
    ///
    /// `JsExtensions.kt:521` 在无选项 `type` 时调用
    /// `UrlUtil.getSuffix(url)`：取选项前 URL 的最后一段（`substringAfterLast
    /// ("/")`）→ 去 `?query` → 去 `#fragment` → 最后一个 `.` 之后；仅当
    /// 长度 ≤ 5 且全为 ASCII 字母数字时采用，否则回退 `"ext"`
    /// （`UrlUtil.kt:154-167` 的 `fileSuffixRegex` + `default "ext"`）。
    fn url_suffix(url: &str) -> &str {
        let (url, _) = split_url_option(url);
        let last_segment = url.rsplit('/').next().unwrap_or(url);
        let no_query = last_segment.split('?').next().unwrap_or(last_segment);
        let no_fragment = no_query.split('#').next().unwrap_or(no_query);
        // Kotlin substringAfterLast(".", "")：无 `.` 时为空串（→ ext），
        // 不能把整个末段当作后缀
        let suffix = match no_fragment.rsplit_once('.') {
            Some((_, suffix)) => suffix,
            None => "",
        };
        if !suffix.is_empty()
            && suffix.len() <= 5
            && suffix.chars().all(|c| c.is_ascii_alphanumeric())
        {
            suffix
        } else {
            "ext"
        }
    }

    /// downloadFile 落盘名（对齐上游 `JsExtensions.kt:518-540`）
    ///
    /// 上游：`type = AnalyzeUrl.type ?: UrlUtil.getSuffix(url)`，文件名 =
    /// `<MD5Utils.md5Encode16(url)>.<type>`。要点：
    /// - `md5Encode16` 是 MD5 小写 hex 的**中段 16 字符**（`[8, 24)`，
    ///   `MD5Utils.kt:29-33`），不是前 16 字符；
    /// - hash 覆盖**完整入参**（含 `,{...}` 选项），故同一资源的不同选项得到
    ///   不同文件，同名末段的不同 URL 不会互相覆盖；
    /// - 上游不读 Content-Type，扩展名只来自选项 `type` 或 URL 后缀。
    ///
    /// 与上游的安全差异：选项 `type` 直接拼进文件名（上游未校验），若含
    /// `/`/`..` 会改变落盘层级或触发我方 `FsPolicy` 拒绝；这里收敛为
    /// 「ASCII 字母数字才采用，否则回退 URL 后缀」。
    ///
    /// # 与上游的有意差异清单（批36 P3-3 登记，批37 收尾）
    ///
    /// 命名语义以 `AnalyzeUrl.type ?: UrlUtil.getSuffix(url)` 为基准，但
    /// **不复用 `legado-parser`**：`split_url_option` / `parse_url_option`
    /// 均为私有实现且绑定模板替换 / 请求构造（`AnalyzeUrl::parse` 会做
    /// `{{}}` 变量替换、绝对 URL 拼接与 query 编码），用作「只取扩展名」
    /// 的入口会引入无关语义；其切分还额外要求剩余串以 `}` 结尾，与上游
    /// GSON 宽松解析也不一致。以下差异经逐条核对后保留：
    ///
    /// 1. **逗号前空白**：上游 `paramPattern = \s*,\s*(?=\{)` 把逗号前空白
    ///    并入分隔符（`"a.jpg ,{...}"` 的上游 URL 段为 `"a.jpg"`，后缀
    ///    `jpg`）；我方从逗号处切分，URL 段保留尾随空白，后缀校验失败
    ///    回退 `ext`。不改：尾随空白不是合法 URL 内容，回退 `ext` 能保证
    ///    落盘名确定且不会把空白带进文件名；为对齐而裁剪会改变请求 URL
    ///    字节，超出命名收敛的范围。
    /// 2. **切分时机**：上游 `CustomUrl.kt:13-22` 与
    ///    `AnalyzeUrl.kt:250-256` 同样**无条件**按 `paramPattern` 剥离
    ///    （选项 JSON 解析失败只影响属性收集），与我方一致，不构成差异；
    ///    此处记录以澄清早期审查登记。
    /// 3. **非字符串 `type`**：上游 GSON 的 String 适配器会把
    ///    `{"type":1}` 强转为 `"1"` 并作为扩展名；我方 `as_str()` 视为
    ///    无 type 并回退 URL 后缀。不改：数字/布尔 `type` 在书源语料中
    ///    未观察到，GSON 隐式强转属宽松解析副作用；只接受字符串可避免
    ///    非预期值进入落盘名。
    /// 4. **含 `.` 的 `type`**（如 `tar.gz`）：上游直接采用得到
    ///    `<hash>.tar.gz`；我方 ASCII 字母数字收敛把 `.` 视为非法并回退
    ///    URL 后缀（`a.tar.gz` → `.gz`）。不改：`type` 来自书源可控的
    ///    选项 JSON，放行 `.` 会同时放行 `..` 与多级后缀，落盘名层级
    ///    不再可预测；批37 明确不为命名对齐放宽该安全收敛。
    pub(crate) fn download_file_name(url: &str) -> String {
        let type_hint = url_option_type(url)
            .filter(|raw| raw.chars().all(|c| c.is_ascii_alphanumeric()))
            .unwrap_or_else(|| url_suffix(url).to_string());
        format!(
            "{}.{}",
            crate::host_api::encoding::md5_encode_16(url),
            type_hint
        )
    }

    /// downloadFile(url, fileName?) — 下载文件到沙箱
    ///
    /// 对应 Kotlin: `downloadFile(url)`（**单参**）；`fileName` 第二参数是
    /// 我方扩展，注册层仅在 `allow_file_access=true` 时接受（P1-1：非原版
    /// 能力不进入生产注册面）。
    ///
    /// 返回**相对文件名**（上游返回相对缓存目录的路径；我方相对名按当前
    /// 书源沙箱根解析，`readTxtFile` / `getFile` 直接可用）。命名见
    /// `download_file_name`：`<md5Encode16(url)>.<type>`，不同 URL 同名
    /// 末段（`/a/cover.jpg` 与 `/b/cover.jpg`）落不同文件，不再互相覆盖。
    /// 我方扩展 `fileName` 存在时按调用方给定名落盘并原样返回该名（可为
    /// 绝对路径，permissive 调试场景保持既有行为）。
    ///
    /// 落盘为**原始字节**（P1-2）：下载走 legado-net 的
    /// `get_bytes_capped`（流式有上限、不经 UTF-8 解码），不再经
    /// `response.text()` 做文本转换，非 UTF-8 二进制（图片/字体/压缩包）
    /// 字节完全一致。
    ///
    /// 资源上限（P1-1）：单文件 32MB（与 archive 单条目同口径）。网络层按
    /// 块累计并在超限时立即中止（内存峰值 ≤ 上限），`Content-Length` 已
    /// 声明超限时在读取 body 前拒绝；超限错误发生在创建目标文件之前，不会
    /// 留下半成品。实现上选择「先累计有界字节、再一次写盘」而非「逐块写
    /// `.part` → rename」：上限已使内存可控，且当前契约是拿到完整内容才
    /// 落盘——流式写盘还需额外处理临时名、rename 与失败清理；二进制完整性
    /// 由网络层的无损字节读取保证。
    ///
    /// # `,{...}` 选项（P2-3）
    ///
    /// 命名覆盖**完整入参**（含选项），但网络请求只使用
    /// [`split_url_option`] 剥离后的 URL 部分（对齐上游 `AnalyzeUrl` 在
    /// 发请求前去掉 `paramPattern` 之后的选项）：
    /// `downloadFile("http://h/a.jpg,{"type":"jpg"}")` 请求 `/a.jpg`，
    /// 不会把 `,{...}` 字面量拼进请求路径导致 404。
    ///
    /// 选项中的 `headers` / `method` / `body` **暂不支持**（仅 GET）。完整
    /// 应用需要走 `AnalyzeUrl` 链路：书源级 headers、cookie jar 合并、
    /// 非 GET 方法的流式有界下载；当前 `get_bytes_capped` 只接受 GET +
    /// 显式 headers，只应用选项 headers 而不合并书源头/Cookie 会形成半套
    /// 语义，且可能改变现网下载行为，故留待后续专题。当前选项仅参与命名
    /// 与 URL 剥离，属已登记的已知差异。
    pub fn download_file(
        policy: &FsPolicy,
        url: &str,
        file_name: Option<&str>,
    ) -> Result<String, String> {
        download_file_capped(policy, url, file_name, MAX_FILE_BYTES)
    }

    /// [`download_file`] 的有界实现（`max_bytes` 供单测注入小上限，生产入口
    /// 固定 [`MAX_FILE_BYTES`]）
    fn download_file_capped(
        policy: &FsPolicy,
        url: &str,
        file_name: Option<&str>,
        max_bytes: u64,
    ) -> Result<String, String> {
        let name = match file_name {
            Some(n) if !n.is_empty() => n.to_string(),
            _ => download_file_name(url),
        };

        // 落盘路径必须先过写策略（越界在联网前即拒绝）
        let dest = policy.resolve_write_path(&name)?;

        // P2-3：`,{...}` 选项参与命名（hash 覆盖完整入参），但不属于请求
        // URL——上游 AnalyzeUrl 在发请求前剥离选项。去掉后
        // `downloadFile("http://h/a.jpg,{"type":"jpg"}")` 请求 `/a.jpg`，
        // 而不是把选项字面量拼进路径导致 404。
        let (request_url, _) = split_url_option(url);

        // 异步下载（通过 block_on 桥接）：进程级共享池（2026-09-24 性能专项：
        // 不再每下载新建客户端/连接池；回环 URL 经 no_proxy 直连池）
        let bytes = crate::host_api::runtime_bridge::block_on(async {
            let client = crate::host_api::network::shared_client_for_url(request_url)
                .map_err(|e| format!("Download client error: {}", e))?;
            client
                .get_bytes_capped(request_url, None, max_bytes)
                .await
                .map_err(|e| format!("Download error: {}", e))
        })?;

        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| format!("Cannot create dir: {}", e))?;
        }
        fs::write(&dest, &bytes).map_err(|e| format!("Write error: {}", e))?;
        // 返回相对名（对齐上游 `path.substring(getCachePath().length)` 的相对
        // 形态；上游含前导分隔符，我方 `FsPolicy` 相对路径按沙箱根拼接，
        // 前导 `/` 在 Windows 会被解释为「当前盘根」而越界，故省去）
        Ok(name)
    }

    /// downloadFile(contentHex, url) — 废弃重载：十六进制内容按 url 类型落盘
    ///
    /// 对应 Kotlin: `@Deprecated downloadFile(content, url)`
    /// （`JsExtensions.kt:549-570`）：`type = AnalyzeUrl.type ?: return ""`，
    /// 文件名 `<md5Encode16(url)>.<type>`，返回相对名。与单参形态的差异是
    /// **没有 URL 后缀回退**——选项未给出 `type` 时上游直接返回空串且不落盘，
    /// 这里保持一致（`type` 非法字符同样视为不可用，见 `download_file_name`
    /// 的安全说明）。
    pub fn download_file_from_hex(
        policy: &FsPolicy,
        content_hex: &str,
        url: &str,
    ) -> Result<String, String> {
        let Some(type_hint) =
            url_option_type(url).filter(|raw| raw.chars().all(|c| c.is_ascii_alphanumeric()))
        else {
            // 对齐上游 `?: return ""`：无合法 type 不写文件
            return Ok(String::new());
        };

        let name = format!(
            "{}.{type_hint}",
            crate::host_api::encoding::md5_encode_16(url)
        );
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
    /// 对应 Kotlin: `cacheFile(url)` / `cacheFile(url, saveTime)`：缓存键为
    /// `md5Encode16(url)`（MD5 小写 hex **中段 16 字符**），`saveTime` 秒
    /// （0 = 永久）写入 `cache_store`；缓存命中且文件仍存在时直接读取，
    /// 否则下载后读取。返回内容而非路径——上游与随包帮助
    /// `eval(String(java.cacheFile(url)))` 均按内容消费。
    ///
    /// 下载与落盘复用 [`download_file`]（流式有上限 + 原始字节，P1-1/P1-2）。
    /// 本 API 返回文本，读取时按 **UTF-8** 解码；非法序列回退
    /// `from_utf8_lossy`（U+FFFD），与上游 Kotlin `File.readText()` 的
    /// 「默认 UTF-8、解码失败替换」语义一致——二进制内容应改用
    /// `downloadFile` 取路径，而不是 `cacheFile` 取文本。
    ///
    /// # 缓存键值形态（P2-2：跨源隔离与缓存抖动）
    ///
    /// 键是上游可见的 `md5Encode16(url)`（MD5 小写 hex 中段 16 字符，对齐
    /// `MD5Utils.md5Encode16`，也是 JS 侧 `java.md5Encode16` 的返回值；书源
    /// `cache.get(md5Encode16(url))` 可直接读回）。值改为**源内相对文件名**
    /// `"<md5Encode16>.<type>"`，与 `download_file_name` 完全一致，而非
    /// 绝对路径：
    /// - 命中时 `resolve_read_path` 按当前书源的沙箱根解析 → 每个源只可能
    ///   命中自己目录下的文件，A 源的映射不会被 B 源当成命中；
    /// - 同一 URL 的相对文件名与源无关，多源共享同一 URL（公共 CDN jsLib
    ///   等）时写入的映射值一致，不会互相顶掉——旧实现存绝对路径，B 源命中
    ///   A 源路径后越界重下并覆盖键，A 源下次又 miss，`cacheFile` 的缓存
    ///   意义消失；
    /// - `cache.get(md5(url))` 不再返回任何源的绝对路径字符串（内容本来
    ///   就受 `FsPolicy` 跨源拦截，此处同时消除元数据泄露）。
    ///
    /// 兼容性：键从旧实现的「MD5 **前** 16 字符」改为中段 16 字符后，旧键
    /// 条目**不可能**被新键命中（两者是不同的字符串）；旧映射值（沙箱绝对
    /// 路径）与旧文件名（前 16 字符 + 后缀）同样是孤儿。首次调用会重新下载
    /// 并按新键/新文件名写入，旧条目不会被读取也不会造成数据损坏；无需迁移。
    pub fn cache_file(policy: &FsPolicy, url: &str, save_time_secs: i64) -> Result<String, String> {
        let key = crate::host_api::encoding::md5_encode_16(url);

        // 缓存记录里的路径同样要过读策略（防止 JS 先 cache.put 一个越界路径）。
        // 顺序：策略先行，再做存在性探测（越界路径不触发任何文件系统探测）。
        // P2-2：相对名在**当前书源**沙箱根下解析，跨源天然 miss（不会命中
        // 其他源目录里的同名文件）。
        if let Some(cached_name) = cache_store::get(&key, false) {
            if !cached_name.is_empty() {
                if let Ok(resolved) = policy.resolve_read_path(&cached_name) {
                    if resolved.is_file() {
                        return read_txt_file(policy, &cached_name, None);
                    }
                }
            }
        }

        // 与 downloadFile(url) 同一命名规则（md5Encode16 + 选项 type/URL 后缀）
        let cache_name = download_file_name(url);

        let path = download_file(policy, url, Some(&cache_name))?;
        // P2-2：只记相对名，不把沙箱绝对路径写进进程级缓存（跨源可读键）
        cache_store::put(&key, &cache_name, save_time_secs);
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
    /// 对应 Kotlin: `getTxtInFolder(path)`（`JsExtensions.kt:903-917`）：读取
    /// 文件夹内**所有文件**（不限扩展名）并以换行拼接，然后
    /// `FileUtils.delete(folder.absolutePath)` **递归删除该目录**。删除失败
    /// 只告警、不影响已读到的返回内容；删除前还要过**写策略**（字体缓存为
    /// 共享只读，可读但不可删），解析后等于引擎根（当前书源沙箱根 / 字体
    /// 缓存根）或等于/包含进程 CWD 时同样拒绝删除（见 [`remove_path`]）。
    /// 每个文件读取前单独过策略，防止目录内符号链接越界。
    ///
    /// 资源上限（P2-6）：先按元数据累计，超 64MB 直接拒绝（不读入）；读取
    /// 过程再按实际字节复核（元数据可被并发修改）。超限显式报错，且不删除
    /// 目录（与上游一致：读取异常发生在删除之前）。
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

        // 对齐上游 `FileUtils.delete(folder.absolutePath)`（deleteRootDir=true）：
        // 读完递归删除目录。删除是**写语义**，须再过写策略——字体缓存为共享
        // 只读资源，即便目录可读也不允许书源删除（批33 P2-2）。删除失败（含
        // 引擎根保护 / 写策略拒绝）只告警，不影响已读到的返回内容。
        match policy.resolve_write_path(&resolved.to_string_lossy()) {
            Ok(deletable) => {
                if let Err(error) = remove_path(&deletable) {
                    eprintln!(
                        "[getTxtInFolder] 删除目录失败（{}）：{error}",
                        resolved.display()
                    );
                }
            }
            Err(error) => eprintln!(
                "[getTxtInFolder] 跳过删除（{}）：{error}",
                resolved.display()
            ),
        }

        Ok(contents.join("\n"))
    }

    /// 下载上限单测（P1-1：超限在写盘前拒绝、无残留）
    ///
    /// 放在实现模块内以便注入小上限（`download_file_capped`），避免生产用例
    /// 推 32MB 级 body。
    #[cfg(test)]
    mod download_limit_tests {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;
        use std::time::{Duration, SystemTime, UNIX_EPOCH};

        use super::*;

        fn unique_name(tag: &str) -> String {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            format!("{tag}_{}_{}.bin", std::process::id(), nanos)
        }

        /// 一次性回环服务：声明 `declared_len` 的 Content-Length，但只发送
        /// `sent_len` 字节即关闭连接
        ///
        /// 用于区分「读取 body 前按声明值拒绝」与「读完整 body 再判上限」：
        /// 后者会因响应体不完整得到解码错误，而不是大小上限错误。
        fn spawn_truncated_oversize_server(declared_len: usize, sent_len: usize) -> String {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let addr = listener.local_addr().unwrap();
            std::thread::spawn(move || {
                let Ok((mut sock, _)) = listener.accept() else {
                    return;
                };
                let _ = sock.set_read_timeout(Some(Duration::from_secs(10)));
                let mut buf = [0u8; 4096];
                let _ = sock.read(&mut buf);
                let head = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                     Content-Length: {declared_len}\r\nConnection: close\r\n\r\n"
                );
                if sock.write_all(head.as_bytes()).is_err() {
                    return;
                }
                let _ = sock.write_all(&vec![0x5au8; sent_len]);
                let _ = sock.flush();
            });
            format!("http://{addr}/oversize.bin")
        }

        #[test]
        fn download_oversize_is_rejected_before_writing() {
            let name = unique_name("legado_js_oversize");
            let root = default_sandbox_root();
            let _ = fs::create_dir_all(&root);
            let dest = root.join(&name);
            let _ = fs::remove_file(&dest);
            let url = spawn_truncated_oversize_server(1024 * 1024, 4096);

            let err = download_file_capped(&FsPolicy::restricted(), &url, Some(&name), 1024)
                .expect_err("超限下载应报错");

            assert!(
                err.contains("下载超出大小上限"),
                "应在读取 body 前按 Content-Length 拒绝（读完整 body 会得到解码错误）: {err}"
            );
            assert!(!dest.exists(), "超限下载不得落盘: {}", dest.display());

            // 不得留下半成品/临时文件（文件名含唯一前缀的全部条目）
            let leftovers: Vec<String> = fs::read_dir(&root)
                .map(|entries| {
                    entries
                        .filter_map(|entry| entry.ok())
                        .map(|entry| entry.file_name().to_string_lossy().into_owned())
                        .filter(|entry_name| entry_name.contains(&name))
                        .collect()
                })
                .unwrap_or_default();
            assert!(leftovers.is_empty(), "不应留下残留文件: {leftovers:?}");
        }
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
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

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

    /// 测试侧取 cacheFile 键（对齐 `MD5Utils.md5Encode16`：MD5 小写 hex
    /// `[8, 24)` 中段 16 字符）
    ///
    /// 注意：本函数与被测生产实现同源，只能用于「文件名与键一致」类断言；
    /// 算法本身的回归由 `test_download_file_name_uses_md5_middle_16_hardcoded_vector`
    /// 的硬编码向量钉住（P3-4）。
    fn cache_key16(input: &str) -> String {
        crate::host_api::encoding::md5_encode_16(input)
    }

    fn unique_name(tag: &str) -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{tag}_{}_{nanos}", std::process::id())
    }

    fn unique_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(unique_name(tag))
    }

    /// 创建目录链接：Unix 用 symlink，Windows 用 junction（普通用户可建）
    fn create_dir_link(link: &Path, target: &Path) -> bool {
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(target, link).is_ok()
        }
        #[cfg(windows)]
        {
            std::process::Command::new("cmd")
                .args(["/C", "mklink", "/J"])
                .arg(link)
                .arg(target)
                .output()
                .map(|out| out.status.success())
                .unwrap_or(false)
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (link, target);
            false
        }
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

    /// P2-2（批33 残留面）：书源 deleteFile 不得删除共享字体缓存文件
    ///
    /// 修复前字体缓存目录在写允许根内，A 源可删除 B 源缓存字体；修复后由
    /// 写策略先行拒绝（错误文本明确指向字体缓存只读）。
    #[test]
    fn test_delete_file_rejects_font_cache_file() {
        // P2-B：字体缓存目录为进程级全局态，取测试锁避免被并行用例覆盖
        let _lock = crate::host_api::font_api::lock_font_cache_for_test();
        let dir = crate::host_api::font_api::font_cache_dir();
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join(unique_name("font_cache_delete_guard.ttf"));
        fs::write(&path, b"ttf").unwrap();

        let err = delete_file(&restricted(), path.to_str().unwrap()).unwrap_err();
        assert!(err.contains("字体缓存"), "err = {err}");
        assert!(path.is_file(), "书源不得删除共享字体缓存文件");

        // 读仍允许（queryTTF 复用共享缓存）
        assert!(restricted()
            .resolve_read_path(path.to_str().unwrap())
            .is_ok());

        let _ = fs::remove_file(&path);
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

        // getTxtInFolder 读取所有文件（对齐上游 listFiles，不限扩展名；
        // 读完删除目录——JsExtensions.kt:917）
        let txt_content = get_txt_in_folder(&restricted(), test_dir).unwrap();
        assert!(txt_content.contains("file a"));
        assert!(txt_content.contains("file b"));
        assert!(txt_content.contains("log c"));
        assert!(
            !sandbox_root().join(test_dir).exists(),
            "getTxtInFolder 读完应删除目录（对齐上游）"
        );

        // 重建目录，验证 deleteFile 删文件
        write_file(&restricted(), "test_ops_dir/a.txt", "file a").unwrap();
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

    // ---- 批33 偏差收口：downloadFile 命名/相对名、deleteFile 递归、
    // ---- getTxtInFolder 读完删除目录 ----

    /// `downloadFile(url)` 命名对齐上游：`md5Encode16(url)` + 类型后缀，
    /// 返回相对名；同名末段的不同 URL 不互相覆盖，返回值可被 readTxtFile 消费
    #[test]
    fn test_download_file_md5_name_relative_return_and_no_overwrite() {
        setup_sandbox();
        // 两个不同端口的回环服务，路径末段同为 `cover.jpg`（模拟
        // `/a/cover.jpg` 与 `/b/cover.jpg`）
        let (url_a, _) = spawn_counting_body_server("COVER_A", "cover.jpg");
        let (url_b, _) = spawn_counting_body_server("COVER_B", "cover.jpg");
        assert_eq!(
            url_a.rsplit('/').next(),
            url_b.rsplit('/').next(),
            "两个 URL 末段应相同（覆盖场景前提）"
        );

        let name_a = download_file(&restricted(), &url_a, None).unwrap();
        let name_b = download_file(&restricted(), &url_b, None).unwrap();

        // 命名 = md5Encode16(完整 URL) + `.jpg`（中段 16 字符）
        assert_eq!(name_a, format!("{}.jpg", cache_key16(&url_a)));
        assert_eq!(name_b, format!("{}.jpg", cache_key16(&url_b)));
        assert_ne!(name_a, name_b, "同名末段的不同 URL 不得互相覆盖");
        assert!(!Path::new(&name_a).is_absolute(), "应返回相对名: {name_a}");
        assert!(
            !name_a.contains('/') && !name_a.contains('\\'),
            "相对名不得含路径分隔符: {name_a}"
        );

        let root = sandbox_root();
        assert_eq!(fs::read(root.join(&name_a)).unwrap(), b"COVER_A");
        assert_eq!(fs::read(root.join(&name_b)).unwrap(), b"COVER_B");

        // 返回值可直接被 readTxtFile 消费（相对名按本源沙箱根解析）
        assert_eq!(
            read_txt_file(&restricted(), &name_a, None).unwrap(),
            "COVER_A"
        );

        let _ = fs::remove_file(root.join(&name_a));
        let _ = fs::remove_file(root.join(&name_b));
    }

    /// 命名规则细节（对齐 `UrlUtil.getSuffix` + `AnalyzeUrl.type`）：
    /// 后缀大小写保留、长度 >5 / 非字母数字回退 `ext`、无 `.` 回退 `ext`、
    /// 选项 `type` 优先；hash 覆盖完整入参（含选项）
    #[test]
    fn test_download_file_name_rules() {
        // 后缀取自选项前 URL 的最后一段，query/fragment 不参与
        assert!(download_file_name("https://h/p/a.JPG").ends_with(".JPG"));
        assert!(download_file_name("https://h/p/a.jpg?x=1#f").ends_with(".jpg"));
        // 长度 > 5 或非 ASCII 字母数字 → ext
        assert!(download_file_name("https://h/p/a.verylong").ends_with(".ext"));
        assert!(download_file_name("https://h/p/a.jp-g").ends_with(".ext"));
        assert!(download_file_name("https://h/p/no_suffix").ends_with(".ext"));
        // 选项 type 优先（大小写保留），hash 覆盖含选项的完整 URL
        let with_type = "https://h/p/a.jpg, {\"type\":\"webp\"}";
        let name = download_file_name(with_type);
        assert_eq!(name, format!("{}.webp", cache_key16(with_type)));
        // type 含路径字符（上游会直接拼接）→ 我方回退 URL 后缀，避免改变层级
        assert!(download_file_name("https://h/p/a.jpg,{\"type\":\"../evil\"}").ends_with(".jpg"));
        // type 存在但不是字符串 → 视为无类型
        assert!(download_file_name("https://h/p/a.jpg,{\"type\":1}").ends_with(".jpg"));
    }

    /// P3-4：`download_file_name` 的 MD5 段必须是**中段** 16 字符
    ///
    /// 硬编码向量（`md5("hello") = 5d41402abc4b2a76b9719d911017c592`）：
    /// 若实现退回旧口径「前 16 字符」（`5d41402abc4b2a76`），此断言立即
    /// 失败。只用 `cache_key16()`（直接调用生产 `md5_encode_16`）的断言会
    /// 随实现一起漂移，测不出该回归。
    #[test]
    fn test_download_file_name_uses_md5_middle_16_hardcoded_vector() {
        assert_eq!(
            download_file_name("hello"),
            "bc4b2a76b9719d91.ext",
            "md5Encode16 应取 MD5 hex 的 [8,24)，不是前 16 字符"
        );
        assert_eq!(
            crate::host_api::encoding::md5_encode_16("hello"),
            "bc4b2a76b9719d91"
        );
    }

    /// 记录请求路径的回环服务器（P2-3：请求 URL 不得包含 `,{...}` 选项）
    fn spawn_request_path_recorder(
        body: &'static str,
    ) -> (String, Arc<std::sync::Mutex<Vec<String>>>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
        let port = listener.local_addr().unwrap().port();
        let paths = Arc::new(std::sync::Mutex::new(Vec::new()));
        let server_paths = Arc::clone(&paths);
        std::thread::spawn(move || {
            for stream in listener.incoming().take(4) {
                let Ok(mut stream) = stream else { continue };
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut byte) {
                        Ok(1) => head.push(byte[0]),
                        _ => break,
                    }
                    if head.len() > 16 * 1024 {
                        break;
                    }
                }
                let text = String::from_utf8_lossy(&head).into_owned();
                let path = text
                    .lines()
                    .next()
                    .unwrap_or_default()
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .to_string();
                server_paths.lock().unwrap().push(path);
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.write_all(body.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://127.0.0.1:{port}"), paths)
    }

    /// P2-3：`,{...}` 只参与命名，网络请求使用剥离后的 URL
    ///
    /// 修复前请求路径字面含 `,{"type":"jpg"}`（服务端 404）；修复后请求
    /// `/a.jpg`，文件名仍按完整入参的 md5 生成。
    #[test]
    fn test_download_file_strips_url_option_from_request() {
        setup_sandbox();
        let (base, paths) = spawn_request_path_recorder("JPEG-BYTES");
        let url = format!("{base}/a.jpg,{{\"type\":\"jpg\"}}");

        let name = download_file(&restricted(), &url, None).unwrap();
        assert_eq!(name, format!("{}.jpg", cache_key16(&url)));
        assert_eq!(
            paths.lock().unwrap().clone(),
            vec!["/a.jpg".to_string()],
            "请求路径不得包含 ,{{...}} 选项字面量"
        );
        let dest = sandbox_root().join(&name);
        assert_eq!(fs::read(&dest).unwrap(), b"JPEG-BYTES");
        let _ = fs::remove_file(dest);
    }

    /// `deleteFile(dir)` 递归删除（对齐上游 `FileUtils.delete(file, true)`）
    #[test]
    fn test_delete_file_removes_directory_recursively() {
        setup_sandbox();
        let dir_name = "test_delete_tree";
        cleanup_test_dir(dir_name);
        write_file(&restricted(), "test_delete_tree/nested/a.txt", "a").unwrap();
        write_file(&restricted(), "test_delete_tree/b.txt", "b").unwrap();

        assert!(delete_file(&restricted(), dir_name).unwrap());
        assert!(
            !sandbox_root().join(dir_name).exists(),
            "目录及其内容应全部删除"
        );
        assert!(!file_exists(&restricted(), "test_delete_tree/nested/a.txt").unwrap());
    }

    /// 引擎根（沙箱根 / 字体缓存根）拒绝删除
    #[test]
    fn test_remove_path_rejects_engine_roots() {
        // P2-B：字体缓存根为进程级全局态，取测试锁避免被并行用例覆盖
        let _lock = crate::host_api::font_api::lock_font_cache_for_test();
        let checks = [
            default_sandbox_root(),
            crate::host_api::font_api::font_cache_dir(),
        ];
        for root in checks {
            fs::create_dir_all(&root).unwrap();
            // 删除步骤本身拒绝（deleteFile / getTxtInFolder 共用该守卫）
            let err = super::impl_file_utils::remove_path(&root).unwrap_err();
            assert!(
                err.contains("拒绝删除引擎沙箱根目录"),
                "{}: {err}",
                root.display()
            );
            assert!(root.exists(), "引擎根不得被删除: {}", root.display());
        }

        // deleteFile(".") 解析后等于当前书源沙箱根 → 明确错误
        let err = delete_file(&restricted(), ".").unwrap_err();
        assert!(err.contains("拒绝删除引擎沙箱根目录"), "err = {err}");

        // P3-5 ①（Windows）：`...` / `....` 经 Win32 规范化到目录自身，
        // 受限模式下解析到沙箱根 → 根保护拒绝（真实 CWD 内容不受影响）
        #[cfg(windows)]
        for raw in ["...", "...."] {
            let err = delete_file(&restricted(), raw).unwrap_err();
            assert!(
                err.contains("拒绝删除引擎沙箱根目录") || err.contains("当前工作目录"),
                "raw = {raw}, err = {err}"
            );
            assert!(default_sandbox_root().exists(), "沙箱根不得被删除");
        }
    }

    /// P2-2：目录递归删除拒绝 CWD 及其祖先（临时目录模拟 CWD）
    ///
    /// 通过 `remove_path_with_cwd` 注入模拟 CWD，不改进程工作目录——避免
    /// 并行测试互相干扰。真实 `deleteFile(".")` / `getTxtInFolder(".")`
    /// 路径另由子进程用例覆盖。
    #[test]
    fn test_remove_path_refuses_cwd_and_ancestors() {
        let base = unique_path("cwd_guard_dirs");
        let cwd = base.join("cwd");
        let child = cwd.join("child");
        fs::create_dir_all(&child).unwrap();
        fs::write(cwd.join("sentinel.txt"), "KEEP").unwrap();

        // 目标就是 CWD → 拒绝
        let err = super::impl_file_utils::remove_path_with_cwd(&cwd, Some(&cwd)).unwrap_err();
        assert!(err.contains("当前工作目录"), "err = {err}");
        assert!(cwd.join("sentinel.txt").is_file());

        // 目标是 CWD 的祖先 → 拒绝
        let err = super::impl_file_utils::remove_path_with_cwd(&base, Some(&cwd)).unwrap_err();
        assert!(err.contains("当前工作目录"), "err = {err}");
        assert!(cwd.join("sentinel.txt").is_file());

        // 与 CWD 无关的子目录仍可递归删除（permissive 调试语义保留）
        super::impl_file_utils::remove_path_with_cwd(&child, Some(&cwd)).unwrap();
        assert!(!child.exists());

        // 引擎根内的目录允许删除（目标在允许根内，不属于 CWD）
        let in_root = sandbox_root().join(unique_name("cwd_guard_in_root"));
        fs::create_dir_all(&in_root).unwrap();
        super::impl_file_utils::remove_path_with_cwd(&in_root, Some(&cwd)).unwrap();
        assert!(!in_root.exists());

        let _ = fs::remove_dir_all(&base);
    }

    /// P3-2：目标存在但 canonicalize 失败 → 明确错误（不再 fail-open）
    #[cfg(unix)]
    #[test]
    fn test_remove_path_fails_closed_on_unresolvable_target() {
        let base = unique_path("cwd_guard_dangling");
        fs::create_dir_all(&base).unwrap();
        let link = base.join("dangling");
        std::os::unix::fs::symlink(base.join("missing"), &link).unwrap();

        let err = super::impl_file_utils::remove_path_with_cwd(&link, Some(&base)).unwrap_err();
        assert!(err.contains("无法解析目标路径"), "err = {err}");
        assert!(
            fs::symlink_metadata(&link).is_ok(),
            "解析失败时不得删除目标"
        );

        let _ = fs::remove_file(&link);
        let _ = fs::remove_dir_all(&base);
    }

    /// P3-5 ②：沙箱内目录链接 → 引擎根，拒绝删除且根存活
    #[test]
    fn test_delete_file_rejects_link_to_engine_root() {
        setup_sandbox();
        let root = sandbox_root();
        let link = root.join(unique_name("link_to_root"));
        if !create_dir_link(&link, &root) {
            eprintln!("skip: 当前环境无法创建目录链接（权限不足）");
            return;
        }

        // 受限：写策略直接拒绝末段符号链接/重解析点
        let relative = link.file_name().unwrap().to_string_lossy().into_owned();
        let err = delete_file(&restricted(), &relative).unwrap_err();
        assert!(
            err.contains("符号链接") || err.contains("重解析点"),
            "err = {err}"
        );
        assert!(root.exists(), "引擎根不得被删除");

        // permissive：canonical 后等于引擎根 → 根保护拒绝
        let err = delete_file(&FsPolicy::unrestricted(), &link.to_string_lossy()).unwrap_err();
        assert!(err.contains("拒绝删除引擎沙箱根目录"), "err = {err}");
        assert!(root.exists(), "引擎根不得被删除");

        // 只移除链接本身，不跟随删除引擎根
        let _ = fs::remove_dir(&link);
        let _ = fs::remove_file(&link);
    }

    /// P3-5 ③：受限模式 `getTxtInFolder(".")` 返回内容且不删除引擎根
    #[test]
    fn test_get_txt_in_folder_dot_in_restricted_mode_keeps_engine_root() {
        use crate::host_api::current_source::with_current_source_tag;

        let tag = format!("https://p35-{}.example/", unique_name("tag"));
        with_current_source_tag(&tag, || {
            let root = sandbox_root();
            fs::create_dir_all(&root).unwrap();
            fs::write(root.join("keep.txt"), "KEEP").unwrap();

            let content = get_txt_in_folder(&restricted(), ".").unwrap();
            assert!(content.contains("KEEP"), "content = {content}");
            assert!(root.exists(), "引擎根不得被删除");

            let _ = fs::remove_file(root.join("keep.txt"));
            let _ = fs::remove_dir(&root);
        });
    }

    const CWD_GUARD_HELPER_ENV: &str = "LEGADO_JS_CWD_GUARD_HELPER";

    /// P2-2：permissive 下 `deleteFile(".")` / `getTxtInFolder(".")` 不得清空 CWD
    ///
    /// 在**子进程**里把工作目录设到临时目录后执行真实 API：若保护回归，
    /// 被删除的是临时目录而不是仓库工作区；同时不切换主测试进程的 CWD，
    /// 避免干扰并行用例。
    #[test]
    fn test_permissive_delete_dot_keeps_cwd_contents() {
        if std::env::var_os(CWD_GUARD_HELPER_ENV).is_some() {
            return;
        }
        let dir = unique_path("cwd_guard_actual");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("sentinel.txt"), "CWD-SENTINEL").unwrap();
        let exe = std::env::current_exe().expect("current_exe");
        let output = std::process::Command::new(exe)
            .args([
                "--exact",
                "--nocapture",
                "host_api::file_utils::tests::cwd_guard_subprocess_helper",
            ])
            .current_dir(&dir)
            .env(CWD_GUARD_HELPER_ENV, "1")
            .output()
            .expect("启动 CWD 保护子进程");
        assert!(
            output.status.success(),
            "CWD 保护子进程失败\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(dir.join("sentinel.txt").is_file(), "CWD 内容必须保留");
        let _ = fs::remove_dir_all(&dir);
    }

    /// 子进程侧：真实 CWD 下调用 permissive 文件 API（见上一个用例）
    #[test]
    fn cwd_guard_subprocess_helper() {
        if std::env::var_os(CWD_GUARD_HELPER_ENV).is_none() {
            return;
        }
        let cwd = std::env::current_dir().expect("current_dir");
        assert!(cwd.join("sentinel.txt").is_file(), "子进程 CWD 夹具缺失");
        let policy = FsPolicy::unrestricted();

        let err = delete_file(&policy, ".").unwrap_err();
        assert!(err.contains("当前工作目录"), "err = {err}");
        assert!(
            cwd.join("sentinel.txt").is_file(),
            "deleteFile(\".\") 不得删除 CWD 内容"
        );

        // P3-5 ①（Windows）：`...` / `....` 经 Win32 规范化到目录自身
        #[cfg(windows)]
        for raw in ["...", "...."] {
            let error = delete_file(&policy, raw)
                .expect_err("Windows 下 `...`/`....` 应解析到 CWD 并被拒绝");
            assert!(
                error.contains("当前工作目录") || error.contains("引擎沙箱根目录"),
                "raw = {raw}, err = {error}"
            );
            assert!(
                cwd.join("sentinel.txt").is_file(),
                "raw = {raw} 不得删除 CWD 内容"
            );
        }

        let content =
            get_txt_in_folder(&policy, ".").expect("getTxtInFolder(\".\") 应返回内容而非报错");
        assert!(
            content.contains("CWD-SENTINEL"),
            "应返回 CWD 文件内容: {content}"
        );
        assert!(
            cwd.join("sentinel.txt").is_file(),
            "getTxtInFolder(\".\") 不得删除 CWD 内容"
        );
    }

    /// `getTxtInFolder` 读完删除目录（内容不受影响；子目录被递归清理）
    #[test]
    fn test_get_txt_in_folder_deletes_directory_after_read() {
        setup_sandbox();
        let dir_name = "test_txt_folder_delete";
        cleanup_test_dir(dir_name);
        write_file(&restricted(), "test_txt_folder_delete/one.txt", "ONE").unwrap();
        write_file(
            &restricted(),
            "test_txt_folder_delete/nested/two.txt",
            "TWO",
        )
        .unwrap();

        let content = get_txt_in_folder(&restricted(), dir_name).unwrap();
        assert_eq!(content, "ONE", "只拼接直接文件，内容不受删除影响");
        assert!(
            !sandbox_root().join(dir_name).exists(),
            "读完应删除目录（含子目录）"
        );
    }

    /// P2-A：`getTxtInFolder` 对字体缓存子目录必须「读得到、删不掉」
    ///
    /// 锁定 `get_txt_in_folder` 的删除步骤走 **写策略**（`resolve_write_path`）：
    /// 若有人改回 `resolve_read_path` 或删掉该次校验，`remove_path` 只保护
    /// 字体缓存**根**，子目录会被递归删除——A 源可借此删光 B 源字体缓存。
    #[test]
    fn test_get_txt_in_folder_font_cache_subdir_is_read_only() {
        // P2-B：字体缓存目录为进程级全局态，取测试锁
        let _lock = crate::host_api::font_api::lock_font_cache_for_test();
        let dir = crate::host_api::font_api::font_cache_dir()
            .join(unique_name("get_txt_in_folder_font_cache"));
        fs::create_dir_all(&dir).unwrap();
        let file = dir.join("cached.ttf");
        fs::write(&file, "FONT-CACHE-FIXTURE").unwrap();

        let content =
            get_txt_in_folder(&restricted(), dir.to_str().unwrap()).expect("字体缓存目录应可读取");
        assert_eq!(content, "FONT-CACHE-FIXTURE", "返回内容不得受删除保护影响");
        assert!(dir.is_dir(), "字体缓存子目录不得被删除: {}", dir.display());
        assert!(file.is_file(), "字体缓存文件不得被删除: {}", file.display());

        let _ = fs::remove_file(&file);
        let _ = fs::remove_dir_all(&dir);
    }

    // ---- cacheFile 跨源隔离（P2-2） ----

    /// 计数回环服务器：所有请求固定返回 `body`，返回 (URL, 请求计数)
    fn spawn_counting_body_server(body: &'static str, name: &str) -> (String, Arc<AtomicUsize>) {
        use std::io::{Read, Write};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
        let port = listener.local_addr().unwrap().port();
        let hits = Arc::new(AtomicUsize::new(0));
        let server_hits = Arc::clone(&hits);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut byte) {
                        Ok(1) => head.push(byte[0]),
                        _ => break,
                    }
                    if head.len() > 16 * 1024 {
                        break;
                    }
                }
                server_hits.fetch_add(1, Ordering::SeqCst);
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\
                     Content-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.write_all(body.as_bytes());
                let _ = stream.flush();
            }
        });
        (format!("http://127.0.0.1:{port}/{name}"), hits)
    }

    /// P2-2：同一 URL 在两个书源下各自缓存、互不覆盖（无抖动），且
    /// 缓存映射值不携带任何源的绝对路径。
    ///
    /// 旧实现把绝对路径写进全局裸 `md5(url)` 键：B 源命中 A 源路径 → 策略
    /// 拒绝 → 重下并覆盖键 → A 源下次再 miss（多源共享公共 CDN jsLib 时
    /// `cacheFile` 缓存意义消失）；同时 `cache.get(md5(url))` 会泄露 A 源
    /// 沙箱绝对路径。现值为源内相对文件名，按当前源沙箱解析。
    #[test]
    fn test_cache_file_shared_url_is_isolated_per_source() {
        use std::time::{SystemTime, UNIX_EPOCH};

        use crate::host_api::cache_store;
        use crate::host_api::current_source::with_current_source_tag;

        let _lock = cache_store::lock_cache_for_test();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let cache_root = std::env::temp_dir().join(format!(
            "legado-js-cache-p22-{}-{nanos}",
            std::process::id()
        ));
        cache_store::set_test_disk_dir_override(Some(cache_root.clone()));

        let body = "P2-2 shared public jsLib";
        let (url, hits) = spawn_counting_body_server(body, &format!("p22-{nanos}.js"));
        let tag_a = format!("https://p22-a.example.com/{nanos}");
        let tag_b = format!("https://p22-b.example.com/{nanos}");
        let key = cache_key16(&url);

        // A 首次：下载到 A 源沙箱目录，映射写相对名
        let a_first = with_current_source_tag(&tag_a, || cache_file(&restricted(), &url, 0))
            .expect("A 首次 cacheFile");
        assert_eq!(a_first, body);
        assert_eq!(hits.load(Ordering::SeqCst), 1, "A 首次应发起下载");
        let mapping = cache_store::get(&key, false).expect("缓存映射应存在");
        assert_eq!(
            mapping,
            format!("{key}.js"),
            "键值应为源内相对文件名（P2-2）"
        );
        assert!(
            !mapping.contains('/') && !mapping.contains('\\'),
            "键值不得包含路径分隔符: {mapping}"
        );

        // B 首次：同 URL 不得命中 A 的文件，下载到 B 自己的目录
        let b_first = with_current_source_tag(&tag_b, || cache_file(&restricted(), &url, 0))
            .expect("B 首次 cacheFile");
        assert_eq!(b_first, body);
        assert_eq!(hits.load(Ordering::SeqCst), 2, "B 首次应各自下载");

        // A/B 再次调用：各自命中自己的文件（映射值相同，不互相顶掉）
        let a_second = with_current_source_tag(&tag_a, || cache_file(&restricted(), &url, 0))
            .expect("A 二次 cacheFile");
        let b_second = with_current_source_tag(&tag_b, || cache_file(&restricted(), &url, 0))
            .expect("B 二次 cacheFile");
        assert_eq!(a_second, body);
        assert_eq!(b_second, body);
        assert_eq!(
            hits.load(Ordering::SeqCst),
            2,
            "两源二次调用均应命中各自缓存（旧实现会因跨源覆盖反复重下）"
        );

        // 跨源隔离：A 的绝对路径在 B 源策略下不可解析/不可读
        let a_path = with_current_source_tag(&tag_a, || default_sandbox_root().join(&mapping));
        assert!(a_path.is_file(), "A 源缓存文件应存在: {}", a_path.display());
        let cross = with_current_source_tag(&tag_b, || {
            restricted().resolve_read_path(&a_path.to_string_lossy())
        });
        assert!(
            cross.is_err(),
            "B 源不得解析 A 源缓存文件（跨源隔离）: {}",
            a_path.display()
        );

        // 缓存映射不携带任何沙箱绝对路径（书源 cache.get 只能看到相对名）
        let cache_root_text = cache_root.to_string_lossy().into_owned();
        assert!(
            !mapping.contains(&cache_root_text),
            "缓存映射泄露了缓存目录绝对路径: {mapping}"
        );

        // 收尾
        cache_store::delete(&key);
        cache_store::set_test_disk_dir_override(None);
        let _ = fs::remove_dir_all(&cache_root);
        for tag in [&tag_a, &tag_b] {
            let _ = with_current_source_tag(tag, || {
                let dir = default_sandbox_root();
                std::fs::remove_file(dir.join(&mapping)).and_then(|_| std::fs::remove_dir(dir))
            });
        }
    }

    /// [批36 P3-4] `clear_all` 清空 cacheFile 映射后，下次调用重新下载
    /// （不是使用已删除文件的旧映射），且缓存根目录仍可继续写入
    #[test]
    fn test_cache_file_redownloads_after_clear_all() {
        use std::time::{SystemTime, UNIX_EPOCH};

        use crate::host_api::cache_store;
        use crate::host_api::current_source::with_current_source_tag;

        let _lock = cache_store::lock_cache_for_test();
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let cache_root = std::env::temp_dir().join(format!(
            "legado-js-cache-clear-all-{}-{nanos}",
            std::process::id()
        ));
        cache_store::set_test_disk_dir_override(Some(cache_root.clone()));
        setup_sandbox();

        let body = "P3-4 clear_all cacheFile";
        let (url, hits) = spawn_counting_body_server(body, &format!("p34-{nanos}.js"));
        let tag = format!("https://p34-clear.example.com/{nanos}");
        let key = cache_key16(&url);

        // 首次：下载 + 写映射
        let first = with_current_source_tag(&tag, || cache_file(&restricted(), &url, 0))
            .expect("首次 cacheFile");
        assert_eq!(first, body);
        assert_eq!(hits.load(Ordering::SeqCst), 1, "首次应发起下载");
        assert!(
            cache_store::get(&key, false).is_some(),
            "cacheFile 映射应已写入 cache_store"
        );

        cache_store::clear_all();
        assert!(
            cache_store::get(&key, false).is_none(),
            "清空后 cacheFile 映射必须失效"
        );

        // 映射失效 → 重新联网下载，而非使用旧映射指向的残留文件
        let second = with_current_source_tag(&tag, || cache_file(&restricted(), &url, 0))
            .expect("清空后再次 cacheFile");
        assert_eq!(second, body);
        assert_eq!(
            hits.load(Ordering::SeqCst),
            2,
            "映射清空后应重新下载（命中旧文件则不增加请求数）"
        );
        assert!(
            cache_store::get(&key, false).is_some(),
            "重新下载后映射应恢复"
        );
        assert!(
            cache_root.is_dir(),
            "清空后缓存根目录仍应存在（可继续写入）"
        );

        // 收尾
        cache_store::delete(&key);
        cache_store::set_test_disk_dir_override(None);
        let _ = fs::remove_dir_all(&cache_root);
        let _ = with_current_source_tag(&tag, || {
            let dir = default_sandbox_root();
            fs::remove_file(dir.join(format!("{key}.js"))).and_then(|_| fs::remove_dir(dir))
        });
    }
}
