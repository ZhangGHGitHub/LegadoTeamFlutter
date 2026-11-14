//! 本地路径访问策略（批21-B P2-5 收紧；P1-1 扩展到文件 API）
//!
//! # 背景
//!
//! 批20 审查发现：`allow_file_access=false` 只门控 `readFile` / `writeFile`
//! 等文件 API 的**注册**，而 `unzipFile` / `getZipStringContent` / `queryTTF`
//! 等 archive/font API 仍可读取调用方传入的**任意本地路径**（解压任意 ZIP、
//! 读任意字体文件）。本模块提供统一的路径白名单，供这几族 API 在注册期
//! 绑定策略。
//!
//! P1-1（2026-11-13）修正了门控本身的语义：**上游同名的 8 个文件 API**
//! （`readFile` / `getFile` / `readTxtFile` / `getTxtInFolder` / `deleteFile` /
//! `downloadFile` / `cacheFile` / `importScript`）**始终注册**——上游
//! `JsExtensions.kt` 是把这些操作限域在 `externalCache` 内，而非禁用；生产
//! `allow_file_access=false` 若直接不注册，随包帮助文档列出的
//! `downloadFile/cacheFile/importScript/...` 在 App 内全部 `undefined`。
//! 我方扩展（`writeFile` / `fileExists` / `downloadFile(url, fileName)`）
//! 在原版不存在，仍按 `allow_file_access` 门控、不进入生产注册面。
//! 受限模式下注册面内的全部文件 API 与 archive/font 共用本策略：
//!
//! # 边界
//!
//! - `allow_file_access=true`（permissive / 调试 / 可信脚本）→ 不做限制，
//!   与 archive/font 既有行为一致（[`FsPolicy::unrestricted`]）。
//! - `allow_file_access=false`（`SandboxConfig::default()`，书源生产路径）
//!   → 仅允许访问**引擎自建目录**内的路径（[`allowed_roots`]）：
//!   1. `file_utils::default_sandbox_root()`：`downloadFile` / `cacheFile` /
//!      `importScript` 的落盘根，也是 `readFile` / `writeFile` /
//!      `getFile` / `readTxtFile` / `getTxtInFolder` / `deleteFile` /
//!      `fileExists` 的限域根。默认
//!      `<系统临时目录>/legado_js_cache/<书源哈希>`（P2-2 按书源隔离；无
//!      tag 的调试入口用 `_shared`），宿主可经
//!      `file_utils::set_sandbox_root` 注入应用私有缓存父目录
//!      （与 `cache_store::set_cache_dir` 同型）；
//!   2. `font_api::font_cache_dir()`：URL 字体下载缓存目录
//!      （`<系统临时目录>/legado_font_cache`），由引擎自身写入。
//!
//! 原版 Kotlin 的口径更严格：`JsExtensions.getFile(path)` 把所有文件 API 的
//! 入参强制解析到 `appCtx.externalCache` 之下（越界抛 `SecurityException`），
//! 且 `getZipStringContent` 只接受 URL / 十六进制字符串、`queryTTF(String)`
//! 只接受 URL / Base64——**本地文件路径分支是我方扩展**。因此本白名单不会
//! 削减原版书源的能力（真实书源语料中 archive API 使用数为 0；字体仅见
//! Base64 + URL 形态，见批21-B 调研记录）。
//!
//! 相对路径在受限模式下按引擎沙箱根解析（对齐原版「相对路径相对缓存目录」
//! 的语义）；绝对路径必须落在允许根内。路径含 `..` 组件一律拒绝，防穿越。
//!
//! # 校验路径 = 使用路径（P2-1）
//!
//! 早期实现用 canonical 路径做白名单判断，却把**词法路径**交给 IO——校验与
//! 实际访问可能指向不同对象（TOCTOU：校验后把中间目录替换为符号链接/
//! junction，IO 就落到沙箱外）。现在：
//!
//! - 读取：返回 canonical 路径（存在段解析符号链接；缺失尾段取最近存在
//!   祖先的 canonical + 尾段），调用方直接用它做 IO；
//! - 写入：同上，并在返回前拒绝**已存在的符号链接/重解析点末段**
//!   （Windows `symlink_metadata` 的 `is_symlink` 同时覆盖符号链接与
//!   junction；Unix 覆盖符号链接），避免「写穿链接」。
//!
//! 残留风险：canonical 化与真正 IO 之间仍有极短窗口，若宿主其余进程把
//! 中间目录换成 junction，仍可能写到校验时的目标之外。彻底消除需要
//! `openat`/`O_NOFOLLOW` 逐段打开（跨平台不可用），当前以「路径唯一 + 末段
//! 拒绝链接」收敛，已在代码审查范围登记。
//!
//! # 失败语义
//!
//! 越界返回**明确错误文本**（不静默）：文件字符串 API 返回 `[ERROR] ...`，
//! 布尔/对象 API 抛 JS 异常；archive 系列由 JS 包装层加 `[ERROR]` 前缀返回；
//! `queryTTF` 返回带 `"valid": false` 与 `"error"` 字段的句柄 JSON。

use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, OnceLock};

/// 本地路径访问策略（由 `SandboxConfig.allow_file_access` 派生）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FsPolicy {
    /// 是否允许任意本地路径（= `allow_file_access`）
    allow_arbitrary_paths: bool,
}

impl FsPolicy {
    /// 不限制路径（`allow_file_access=true`，调试 / 可信脚本）
    pub const fn unrestricted() -> Self {
        Self {
            allow_arbitrary_paths: true,
        }
    }

    /// 仅允许引擎自建目录（`allow_file_access=false`，书源生产路径）
    pub const fn restricted() -> Self {
        Self {
            allow_arbitrary_paths: false,
        }
    }

    /// 从沙箱配置派生策略
    pub fn from_sandbox_config(config: &crate::sandbox::SandboxConfig) -> Self {
        if config.allow_file_access {
            Self::unrestricted()
        } else {
            Self::restricted()
        }
    }

    /// 是否允许任意路径（供文档/测试断言）
    pub fn allows_arbitrary_paths(&self) -> bool {
        self.allow_arbitrary_paths
    }

    /// 校验「读取」路径，返回实际可用于 IO 的路径
    ///
    /// 不受限模式原样返回（保持既有 cwd/绝对路径语义）；受限模式返回
    /// **canonical 路径**（相对路径按引擎沙箱根解析），或越界错误。
    pub fn resolve_read_path(&self, raw: &str) -> Result<PathBuf, String> {
        if self.allow_arbitrary_paths {
            return Ok(PathBuf::from(raw));
        }
        resolve_restricted(raw, PathUsage::Read)
    }

    /// 校验「写入/解压输出/删除」路径（语义同 [`Self::resolve_read_path`]）
    pub fn resolve_write_path(&self, raw: &str) -> Result<PathBuf, String> {
        if self.allow_arbitrary_paths {
            return Ok(PathBuf::from(raw));
        }
        resolve_restricted(raw, PathUsage::Write)
    }
}

/// 路径用途（决定末段是否为「已存在链接」的额外拒绝）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PathUsage {
    Read,
    Write,
}

impl PathUsage {
    fn action(self) -> &'static str {
        match self {
            Self::Read => "读取",
            Self::Write => "写入",
        }
    }
}

/// 受限模式下的路径解析与白名单校验
fn resolve_restricted(raw: &str, usage: PathUsage) -> Result<PathBuf, String> {
    let action = usage.action();
    if raw.is_empty() {
        return Err("文件访问被拒绝：路径为空".to_string());
    }

    let requested = Path::new(raw);
    // 词法层拒绝 `..` 与非盘符 Prefix：
    // - `..`：引擎生成/返回的路径不会包含它，拒绝可避免依赖 canonicalize
    //   的边界差异（不存在的尾段、符号链接等）；
    // - UNC / verbatim / 设备命名空间（`\\?\`、`\\server\share`、`\\.\`）：
    //   访问可能阻塞宿主且 JS 超时中断不了原生调用，一律拒绝（批21-B 回修
    //   P3）。普通盘符（`C:\...`，Prefix::Disk）保留——引擎沙箱根即盘符路径。
    for component in requested.components() {
        match component {
            Component::ParentDir => {
                return Err(format!("文件访问被拒绝：路径包含 `..`（{raw}）"));
            }
            Component::Prefix(prefix) if !matches!(prefix.kind(), std::path::Prefix::Disk(_)) => {
                return Err(format!(
                    "文件访问被拒绝：不支持 UNC/设备/verbatim 路径前缀（{raw}）"
                ));
            }
            _ => {}
        }
    }

    // 相对路径按引擎沙箱根解析（对齐原版「相对路径相对缓存目录」语义；
    // 沙箱根按书源 tag 分子目录，见 `file_utils::default_sandbox_root`）
    let resolved = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        crate::host_api::file_utils::default_sandbox_root().join(requested)
    };

    // 写路径：末段已存在且是符号链接/junction 时直接拒绝（不跟随后写入，
    // 防止「沙箱内链接 → 沙箱外文件」的写穿）。读取路径不做此限制：
    // canonicalize 会把链接解析到真实目标，随后仍按允许根校验。
    if usage == PathUsage::Write {
        if let Ok(meta) = std::fs::symlink_metadata(&resolved) {
            if meta.file_type().is_symlink() {
                return Err(format!(
                    "文件访问被拒绝：目标为符号链接/重解析点（{action} {}）",
                    resolved.display()
                ));
            }
        }
    }

    // 校验与 IO 使用同一路径：canonical（存在段解析链接，缺失尾段取最近
    // 存在祖先的 canonical + 尾段），不再返回词法 `resolved`。
    let canonical = canonicalize_allow_missing(&resolved).ok_or_else(|| {
        format!(
            "文件访问被拒绝：无法解析路径（{action} {}）",
            resolved.display()
        )
    })?;

    if allowed_roots()
        .iter()
        .any(|root| canonical.starts_with(root))
    {
        Ok(canonical)
    } else {
        Err(format!(
            "文件访问被拒绝：{} 不在引擎沙箱目录内\
             （allow_file_access=false；本地文件请先经 java.downloadFile/cacheFile 获取）",
            resolved.display()
        ))
    }
}

/// allowed_roots 缓存（canonical 根目录）
///
/// 每次文件 API 调用都 `create_dir_all` + `canonicalize` 两个根会带来固定
/// 系统调用开销；根目录在宿主注入（`set_sandbox_root` / `set_font_cache_dir`）
/// 之外不会变化。缓存键是**原始根路径**（含按书源 tag 派生的子目录），
/// 因此多书源交替调用时也能各自命中；注入点变更时经
/// [`invalidate_allowed_roots_cache`] 失效。
#[derive(Debug, Clone)]
struct CachedRoots {
    raw_sandbox: PathBuf,
    canonical_sandbox: PathBuf,
    raw_font: PathBuf,
    canonical_font: PathBuf,
}

static ROOT_CACHE: OnceLock<Mutex<Option<CachedRoots>>> = OnceLock::new();

fn root_cache() -> &'static Mutex<Option<CachedRoots>> {
    ROOT_CACHE.get_or_init(|| Mutex::new(None))
}

/// 清空允许根缓存（宿主注入沙箱根 / 字体缓存目录变更时调用）
pub fn invalidate_allowed_roots_cache() {
    if let Ok(mut guard) = root_cache().lock() {
        *guard = None;
    }
}

/// 允许访问的根目录（canonicalize 后用于前缀比较）
///
/// 仅含引擎自建目录：JS 沙箱根（`downloadFile` 等落盘处，可由宿主经
/// `file_utils::set_sandbox_root` 注入；按书源 tag 分子目录）与字体缓存目录。
/// 目录不存在时尝试创建（引擎自有目录，创建无副作用）；创建/规范化失败
/// 时退回词法路径（Windows 下可能因 `\\?\` 前缀不匹配而**失败即拒绝**，
/// 属有意的 fail-closed 方向）。
/// 结果按原始根路径缓存，见 [`CachedRoots`]。
pub fn allowed_roots() -> Vec<PathBuf> {
    let raw_sandbox = crate::host_api::file_utils::default_sandbox_root();
    let raw_font = crate::host_api::font_api::font_cache_dir();

    if let Ok(guard) = root_cache().lock() {
        if let Some(cached) = guard.as_ref() {
            if cached.raw_sandbox == raw_sandbox && cached.raw_font == raw_font {
                return vec![
                    cached.canonical_sandbox.clone(),
                    cached.canonical_font.clone(),
                ];
            }
        }
    }

    let canonical_sandbox = canonicalize_root(&raw_sandbox);
    let canonical_font = canonicalize_root(&raw_font);
    if let Ok(mut guard) = root_cache().lock() {
        *guard = Some(CachedRoots {
            raw_sandbox,
            canonical_sandbox: canonical_sandbox.clone(),
            raw_font,
            canonical_font: canonical_font.clone(),
        });
    }
    vec![canonical_sandbox, canonical_font]
}

/// 创建并规范化允许根（失败时退回词法路径）
fn canonicalize_root(root: &Path) -> PathBuf {
    let _ = std::fs::create_dir_all(root);
    match std::fs::canonicalize(root) {
        Ok(canonical) => strip_verbatim_disk_prefix(canonical),
        Err(_) => normalize_lexical(root),
    }
}

/// 剥离 Windows `canonicalize` 产生的逐字（verbatim）盘符前缀
///
/// `canonicalize` 在 Windows 返回 `\\?\C:\...`。逐字路径若原样回传 JS，
/// 会被本模块的词法校验（拒绝非 `Prefix::Disk`）再次拒绝，且对书源是
/// 无法识别的形式；项目既有先例（`backup_api::strip_verbatim_prefix`）
/// 同样在返回/落库前剥离。UNC 逐字形式（`\\?\UNC\...`）保持原样——它不是
/// 允许根形态，会自然被白名单拒绝。
///
/// 代价：极长路径（> MAX_PATH 且宿主未启用长路径支持）剥离后可能打开失败，
/// 表现为显式 IO 错误而非越界，方向安全；沙箱根是应用缓存目录，实际深度
/// 远小于该阈值。
fn strip_verbatim_disk_prefix(path: PathBuf) -> PathBuf {
    #[cfg(windows)]
    {
        let text = path.to_string_lossy();
        if let Some(rest) = text.strip_prefix(r"\\?\") {
            if !rest.starts_with("UNC\\") {
                return PathBuf::from(rest);
            }
        }
    }
    path
}

/// 对可能存在缺失尾段的路径做「最近存在祖先 canonicalize + 尾段拼接」
///
/// - 读取场景路径通常已存在，直接 canonicalize（解析符号链接）；
/// - 写入场景（解压输出目录）可能尚不存在：向上找到最近存在的祖先做
///   canonicalize，再拼回缺失段。祖先经符号链接指向白名单外时会被识别；
///   悬空符号链接（`symlink_metadata` 存在但 canonicalize 失败）判为不可解析
///   → 拒绝。
/// - 返回值剥离 Windows 逐字盘符前缀，可直接回传 JS 并再次通过词法校验。
fn canonicalize_allow_missing(path: &Path) -> Option<PathBuf> {
    let mut probe = path.to_path_buf();
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    loop {
        if std::fs::symlink_metadata(&probe).is_ok() {
            let mut canonical = std::fs::canonicalize(&probe).ok()?;
            for name in tail.iter().rev() {
                canonical.push(name);
            }
            return Some(strip_verbatim_disk_prefix(canonical));
        }
        let name = probe.file_name()?.to_os_string();
        tail.push(name);
        probe = probe.parent()?.to_path_buf();
    }
}

/// 词法规范化（不访问文件系统）：消解 `.` 与 `..`，保留根/前缀
fn normalize_lexical(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn unique(tag: &str) -> String {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        format!("{tag}_{}_{}", std::process::id(), nanos)
    }

    /// 期望的 canonical 形式（与 `resolve_*` 返回值同口径：剥离 verbatim）
    fn expected_canonical(path: &Path) -> PathBuf {
        let canonical = std::fs::canonicalize(path).expect("canonicalize 测试路径");
        super::strip_verbatim_disk_prefix(canonical)
    }

    #[test]
    fn test_unrestricted_keeps_arbitrary_path() {
        let outside = std::env::temp_dir().join(unique("legado_fs_policy_outside"));
        let policy = FsPolicy::unrestricted();
        assert!(policy.allows_arbitrary_paths());
        assert_eq!(
            policy.resolve_read_path(outside.to_str().unwrap()).unwrap(),
            outside
        );
    }

    #[test]
    fn test_restricted_allows_relative_path_in_sandbox() {
        let policy = FsPolicy::restricted();
        assert!(!policy.allows_arbitrary_paths());
        let name = format!("{}.zip", unique("fs_policy_in"));
        let path = crate::host_api::file_utils::default_sandbox_root().join(&name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"PK").unwrap();

        // P2-1：读取返回 canonical（校验路径即 IO 路径）
        let resolved = policy.resolve_read_path(&name).unwrap();
        assert_eq!(resolved, expected_canonical(&path));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_restricted_rejects_outside_absolute_path() {
        let dir = std::env::temp_dir().join(unique("legado_fs_policy_deny"));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("book.zip");
        std::fs::write(&file, b"PK").unwrap();

        let err = FsPolicy::restricted()
            .resolve_read_path(file.to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("文件访问被拒绝"), "err = {err}");
        assert!(err.contains("引擎沙箱目录"), "err = {err}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_restricted_rejects_parent_dir_traversal() {
        let err = FsPolicy::restricted()
            .resolve_read_path("../outside.zip")
            .unwrap_err();
        assert!(err.contains("`..`"), "err = {err}");
    }

    #[test]
    fn test_restricted_allows_font_cache_dir() {
        let policy = FsPolicy::restricted();
        let name = format!("{}.ttf", unique("fs_policy_font"));
        let path = crate::host_api::font_api::font_cache_dir().join(&name);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"ttf").unwrap();

        let resolved = policy.resolve_read_path(path.to_str().unwrap()).unwrap();
        assert_eq!(resolved, expected_canonical(&path));

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_restricted_allows_missing_output_inside_sandbox() {
        // 解压输出目录尚不存在：最近存在祖先在沙箱内 → 允许，返回
        // 「canonical 祖先 + 尾段」（P2-1：写入也使用校验后的路径）
        let policy = FsPolicy::restricted();
        let name = unique("fs_policy_out");
        let root = crate::host_api::file_utils::default_sandbox_root();
        std::fs::create_dir_all(&root).unwrap();
        let out = root.join(&name);
        let resolved = policy.resolve_write_path(out.to_str().unwrap()).unwrap();
        let mut expected = expected_canonical(&root);
        expected.push(&name);
        assert_eq!(resolved, expected);
        assert!(!resolved.exists(), "校验不得创建目标");
    }

    /// 写入路径末段是沙箱内符号链接 → 拒绝（不写穿链接）
    #[cfg(unix)]
    #[test]
    fn test_write_path_rejects_final_symlink() {
        let root = crate::host_api::file_utils::default_sandbox_root();
        std::fs::create_dir_all(&root).unwrap();
        let target = root.join(unique("fs_policy_link_target"));
        std::fs::write(&target, b"orig").unwrap();
        let link = root.join(unique("fs_policy_link"));
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let err = FsPolicy::restricted()
            .resolve_write_path(link.to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("符号链接"), "err = {err}");
        // 读路径允许（canonical 解析到沙箱内目标）
        assert!(FsPolicy::restricted()
            .resolve_read_path(link.to_str().unwrap())
            .is_ok());

        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_file(&target);
    }

    #[test]
    fn test_restricted_rejects_empty_path() {
        let err = FsPolicy::restricted().resolve_read_path("").unwrap_err();
        assert!(err.contains("路径为空"), "err = {err}");
    }

    #[test]
    fn test_restricted_rejects_sibling_with_sandbox_prefix() {
        // 分隔符边界：`legado_js_cache_evil` 是沙箱根的兄弟目录，不能因
        // 字符串前缀相同而被 starts_with 放行（Path 组件级比较应拒绝）。
        let sandbox = crate::host_api::file_utils::default_sandbox_root();
        let sibling = sandbox.with_file_name(format!(
            "{}_evil",
            sandbox
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "legado_js_cache".to_string())
        ));
        std::fs::create_dir_all(&sibling).unwrap();
        let file = sibling.join("evil.zip");
        std::fs::write(&file, b"PK").unwrap();

        let err = FsPolicy::restricted()
            .resolve_read_path(file.to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("引擎沙箱目录"), "err = {err}");

        let _ = std::fs::remove_dir_all(&sibling);
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

    #[test]
    fn test_restricted_rejects_symlink_or_junction_escape() {
        // 目录链接指向沙箱外：canonicalize 后的真实路径越界必须拒绝
        let target = std::env::temp_dir().join(unique("legado_fs_policy_link_target"));
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("secret.txt"), b"SECRET").unwrap();

        let link =
            crate::host_api::file_utils::default_sandbox_root().join(unique("fs_policy_link"));
        if !create_dir_link(&link, &target) {
            eprintln!("skip: 当前环境无法创建目录链接（权限不足）");
            let _ = std::fs::remove_dir_all(&target);
            return;
        }

        let probe = link.join("secret.txt");
        let err = FsPolicy::restricted()
            .resolve_read_path(probe.to_str().unwrap())
            .unwrap_err();
        assert!(err.contains("引擎沙箱目录"), "err = {err}");

        // 先移除链接本身再清理目标目录（Windows junction 不应跟随删除）
        let _ = std::fs::remove_dir(&link);
        let _ = std::fs::remove_dir_all(&target);
    }

    /// P2-1 回归锁：读取返回 **canonical 目标**，不是用户给的词法路径
    ///
    /// 沙箱内的目录链接指向沙箱内另一目录：修复前 `resolve_restricted`
    /// 校验 canonical 却返回 `resolved`（词法链接路径），调用方 IO 用的
    /// 仍是链接路径——链接可在校验后被替换（TOCTOU）。修复后返回值必须是
    /// 链接指向的真实路径。
    #[test]
    fn test_read_path_returns_canonical_target_through_symlink() {
        let root = crate::host_api::file_utils::default_sandbox_root();
        std::fs::create_dir_all(&root).unwrap();
        let real_dir = root.join(unique("fs_policy_real"));
        std::fs::create_dir_all(&real_dir).unwrap();
        let real_file = real_dir.join("f.txt");
        std::fs::write(&real_file, b"x").unwrap();

        let link = root.join(unique("fs_policy_alias"));
        if !create_dir_link(&link, &real_dir) {
            eprintln!("skip: 当前环境无法创建目录链接（权限不足）");
            let _ = std::fs::remove_dir_all(&real_dir);
            return;
        }

        let probe = link.join("f.txt");
        let resolved = FsPolicy::restricted()
            .resolve_read_path(probe.to_str().unwrap())
            .unwrap();
        assert_eq!(resolved, expected_canonical(&real_file));
        assert_ne!(
            resolved, probe,
            "修复前（返回词法路径）此处为链接路径，校验与 IO 不一致"
        );

        let _ = std::fs::remove_dir(&link);
        let _ = std::fs::remove_dir_all(&real_dir);
    }

    #[cfg(windows)]
    #[test]
    fn test_restricted_rejects_verbatim_and_unc_prefix() {
        // P3：UNC / verbatim / 设备命名空间可能在原生调用中阻塞且无法被
        // JS 超时中断，词法层直接拒绝（普通盘符 Prefix::Disk 仍允许）。
        for raw in [
            r"\\?\C:\Windows\win.ini",
            r"\\server\share\x.zip",
            r"\\.\COM1",
        ] {
            let err = FsPolicy::restricted().resolve_read_path(raw).unwrap_err();
            assert!(
                err.contains("UNC/设备/verbatim"),
                "raw = {raw}, err = {err}"
            );
        }
    }

    #[test]
    fn test_normalize_lexical_resolves_dots() {
        let p = normalize_lexical(Path::new("a/b/../c/./d"));
        assert_eq!(p, PathBuf::from("a/c/d"));
    }
}
