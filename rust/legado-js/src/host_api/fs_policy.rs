//! archive / font 宿主 API 的本地路径访问策略（批21-B，P2-5 收紧）
//!
//! # 背景
//!
//! 批20 审查发现：`allow_file_access=false` 只门控 `readFile` / `writeFile`
//! 等文件 API 的**注册**，而 `unzipFile` / `getZipStringContent` / `queryTTF`
//! 等 archive/font API 仍可读取调用方传入的**任意本地路径**（解压任意 ZIP、
//! 读任意字体文件）。本模块提供统一的路径白名单，供这两族 API 在注册期
//! 绑定策略。
//!
//! # 边界
//!
//! - `allow_file_access=true`（permissive / 调试 / 可信脚本）→ 不做限制，
//!   与既有行为一致（[`FsPolicy::unrestricted`]）。
//! - `allow_file_access=false`（`SandboxConfig::default()`，书源生产路径）
//!   → 仅允许访问**引擎自建目录**内的路径（[`allowed_roots`]）：
//!   1. `file_utils::default_sandbox_root()`：`downloadFile` / `cacheFile` /
//!      `importScript` 的落盘根（`<系统临时目录>/legado_js_cache`），书源
//!      拿到的本地路径都由这些 API 生成（`getFile` 仅在
//!      `allow_file_access=true` 时注册，但同用该根）；
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
//! # 失败语义
//!
//! 越界返回**明确错误文本**（不静默）：archive 系列由 JS 包装层加
//! `[ERROR]` 前缀返回；`queryTTF` 返回带 `"valid": false` 与 `"error"`
//! 字段的句柄 JSON。

use std::path::{Component, Path, PathBuf};

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
    /// 「相对路径按引擎沙箱根解析」后的路径，或越界错误。
    pub fn resolve_read_path(&self, raw: &str) -> Result<PathBuf, String> {
        if self.allow_arbitrary_paths {
            return Ok(PathBuf::from(raw));
        }
        resolve_restricted(raw, "读取")
    }

    /// 校验「写入/解压输出」路径（语义同 [`Self::resolve_read_path`]）
    pub fn resolve_write_path(&self, raw: &str) -> Result<PathBuf, String> {
        if self.allow_arbitrary_paths {
            return Ok(PathBuf::from(raw));
        }
        resolve_restricted(raw, "写入")
    }
}

/// 受限模式下的路径解析与白名单校验
fn resolve_restricted(raw: &str, action: &str) -> Result<PathBuf, String> {
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

    // 相对路径按引擎沙箱根解析（对齐原版「相对路径相对缓存目录」语义）
    let resolved = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        crate::host_api::file_utils::default_sandbox_root().join(requested)
    };

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
        Ok(resolved)
    } else {
        Err(format!(
            "文件访问被拒绝：{} 不在引擎沙箱目录内\
             （allow_file_access=false；本地文件请先经 java.downloadFile/cacheFile 获取）",
            resolved.display()
        ))
    }
}

/// 允许访问的根目录（canonicalize 后用于前缀比较）
///
/// 仅含引擎自建目录：JS 沙箱根（downloadFile 等落盘处）与字体缓存目录。
/// 目录不存在时尝试创建（引擎自有目录，创建无副作用）；创建/规范化失败
/// 时退回词法路径（Windows 下可能因 `\\?\` 前缀不匹配而**失败即拒绝**，
/// 属有意的 fail-closed 方向）。
pub fn allowed_roots() -> Vec<PathBuf> {
    let roots = [
        crate::host_api::file_utils::default_sandbox_root(),
        crate::host_api::font_api::font_cache_dir(),
    ];
    let mut out = Vec::with_capacity(roots.len());
    for root in roots {
        let _ = std::fs::create_dir_all(&root);
        out.push(std::fs::canonicalize(&root).unwrap_or_else(|_| normalize_lexical(&root)));
    }
    out
}

/// 对可能存在缺失尾段的路径做「最近存在祖先 canonicalize + 尾段拼接」
///
/// - 读取场景路径通常已存在，直接 canonicalize（解析符号链接）；
/// - 写入场景（解压输出目录）可能尚不存在：向上找到最近存在的祖先做
///   canonicalize，再拼回缺失段。祖先经符号链接指向白名单外时会被识别；
///   悬空符号链接（`symlink_metadata` 存在但 canonicalize 失败）判为不可解析
///   → 拒绝。
fn canonicalize_allow_missing(path: &Path) -> Option<PathBuf> {
    let mut probe = path.to_path_buf();
    let mut tail: Vec<std::ffi::OsString> = Vec::new();
    loop {
        if std::fs::symlink_metadata(&probe).is_ok() {
            let mut canonical = std::fs::canonicalize(&probe).ok()?;
            for name in tail.iter().rev() {
                canonical.push(name);
            }
            return Some(canonical);
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

        let resolved = policy.resolve_read_path(&name).unwrap();
        assert_eq!(resolved, path);

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
        assert_eq!(resolved, path);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_restricted_allows_missing_output_inside_sandbox() {
        // 解压输出目录尚不存在：最近存在祖先在沙箱内 → 允许
        let policy = FsPolicy::restricted();
        let name = unique("fs_policy_out");
        let out = crate::host_api::file_utils::default_sandbox_root().join(&name);
        assert!(policy.resolve_write_path(out.to_str().unwrap()).is_ok());
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
