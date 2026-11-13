//! 解压缩宿主 API
//!
//! 对应 Kotlin `ArchiveUtils.kt`，提供 ZIP / 7z / RAR 解压能力。
//! - ZIP：使用 `zip` crate 完整实现
//! - 7z：使用 `sevenz-rust2` crate 纯 Rust 实现（需 quickjs feature）
//! - RAR：使用 `rar` crate 纯 Rust 实现（需 quickjs feature；当前仅实现
//!   RAR5 解压，RAR4 未实现，见 crate README）。解压/读取前统一预扫描条目名
//!   （只允许普通相对路径组件），防 `../` / 绝对路径条目写出输出目录
//! - raw-deflate：使用 `flate2` crate（需 quickjs feature），供
//!   `java.util.zip.Inflater` 语料面（`java.inflateRawBytes` 宿主桥）

use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Component, Path, PathBuf};

// ============================================================
// 解压资源上限（P3-1）
//
// 书源可控压缩包可以声明/展开任意大的内容：旧实现把每个 ZIP 条目
// `read_to_end` 到内存、`read_file_magic` 用 `fs::read` 读整包、`unrar_file`
// 预扫描也整包入内存，恶意「压缩炸弹」可造成数 GB 内存峰值。
//
// 限额取值与项目既有主题包解压口径一致（`theme_package_service.dart`：
// `maxEntryBytes = 32MB`、`maxTotalBytes = 512MB`）：
// - 单条目 32MB：书源场景的文本/图片条目远小于该值，与主题图单文件上限同口径；
// - 单次解压/读取总量 512MB：避免「多条 32MB」叠加耗尽内存/磁盘。
//
// 7z 整包解压（P2-1）同样纳入限额：逐条目流式写出，写盘前按头部声明的
// 条目大小与累计总量拒绝、写盘时按实际字节复核，不再走无上限的
// `decompress_file` 整包解压。
//
// 超限一律返回明确错误（`unzipFile` 经 JS 注册层加 `[ERROR]` 前缀），
// 不静默截断。
// ============================================================

/// 单条目解压后大小上限（32MB，对齐主题包 `maxEntryBytes`）
const ARCHIVE_MAX_ENTRY_BYTES: u64 = 32 * 1024 * 1024;

/// 单次解压/读取的总量上限（512MB，对齐主题包 `maxTotalBytes`）
const ARCHIVE_MAX_TOTAL_BYTES: u64 = 512 * 1024 * 1024;

/// 资源上限错误前缀（调用方/测试据此区分「超限」与「归档损坏」）
const ARCHIVE_LIMIT_ERROR_PREFIX: &str = "解压超出大小上限";

/// 读取文件 magic 的前缀字节数（只需覆盖 7z/RAR/ZIP 签名，512B 富余）
const MAGIC_PREFIX_BYTES: usize = 512;

/// RAR5 头部大小上限（1MB）
///
/// 头部含条目名与可选 extra area；RAR5 规范条目名上限 64KB，1MB 对合法
/// 归档足够富余，同时防止伪造超大 `HeaderSize` 触发巨额分配。
const RAR5_MAX_HEADER_BYTES: u64 = 1024 * 1024;

/// 单条目超限错误
fn entry_limit_error(entry: impl std::fmt::Display, size: u64) -> String {
    format!(
        "{ARCHIVE_LIMIT_ERROR_PREFIX}：条目 {entry} 解压后 {size} 字节，\
         超过单条目上限 {ARCHIVE_MAX_ENTRY_BYTES} 字节"
    )
}

/// 总量超限错误
fn total_limit_error(total: u64) -> String {
    format!(
        "{ARCHIVE_LIMIT_ERROR_PREFIX}：本次解压总量 {total} 字节，\
         超过总量上限 {ARCHIVE_MAX_TOTAL_BYTES} 字节"
    )
}

/// 解压产物清理守卫（P3-1）
///
/// 记录本次解压**实际创建**的文件与目录：
/// - 成功完成时调用 [`commit`](Self::commit) 跳过清理；
/// - 任何错误路径（含 `?` 早退）都在 `Drop` 中删除半成品，避免残留。
///
/// 目录只登记本次新建的最上层路径（其父目录已存在），因此绝不会删除用户
/// 已有的输出目录；文件在 `File::create` **成功之后**登记，避免创建失败时
/// 误删用户原有的同名只读文件。
struct ExtractionGuard {
    files: Vec<PathBuf>,
    dirs: Vec<PathBuf>,
    committed: bool,
}

impl ExtractionGuard {
    fn new() -> Self {
        Self {
            files: Vec::new(),
            dirs: Vec::new(),
            committed: false,
        }
    }

    /// 确保目录存在；仅登记本次新建目录（已存在则不动）
    fn ensure_dir(&mut self, dir: &Path) -> Result<(), String> {
        if dir.is_dir() {
            return Ok(());
        }
        if dir.exists() {
            // 同名文件占位：明确报错，避免后续写入错误难以定位
            return Err(format!(
                "Failed to create dir {}: 路径已存在且不是目录",
                dir.display()
            ));
        }
        // 找到本次新建的最上层目录（其父目录必须已存在），
        // 失败清理时 remove_dir_all 可一并删除其下所有产物
        let mut top = dir;
        while let Some(parent) = top.parent() {
            if parent.as_os_str().is_empty() || parent.exists() {
                break;
            }
            top = parent;
        }
        // 先创建并登记最上层目录，再补建其余层级：create_dir_all 中途失败时
        // 已创建的层级也必然被守卫清理
        match fs::create_dir(top) {
            Ok(()) => {
                if !self.dirs.iter().any(|recorded| recorded == top) {
                    self.dirs.push(top.to_path_buf());
                }
            }
            // 并发下被其他进程抢先创建：不登记，避免删除非本次创建的目录
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(e) => return Err(format!("Failed to create dir {}: {e}", top.display())),
        }
        fs::create_dir_all(dir)
            .map_err(|e| format!("Failed to create dir {}: {e}", dir.display()))?;
        Ok(())
    }

    /// 登记本次写出的文件（须在 `File::create` 成功后调用）
    fn track_file(&mut self, path: &Path) {
        self.files.push(path.to_path_buf());
    }

    /// 解压成功：交出产物，跳过清理
    fn commit(mut self) {
        self.committed = true;
    }
}

impl Drop for ExtractionGuard {
    fn drop(&mut self) {
        if self.committed {
            return;
        }
        for file in &self.files {
            let _ = fs::remove_file(file);
        }
        // 逆序删除本次新建目录（remove_dir_all 覆盖其下全部半成品）
        for dir in self.dirs.iter().rev() {
            let _ = fs::remove_dir_all(dir);
        }
    }
}

/// 流式拷贝单个条目到输出文件，按单条目/累计总量限额中途截止
///
/// 返回实际写入字节数；超限返回 [`ARCHIVE_LIMIT_ERROR_PREFIX`] 错误
/// （不静默截断）。`+1` 用于识别「恰好超过允许上限」。
fn copy_entry_capped<W: std::io::Write>(
    reader: &mut dyn Read,
    out: &mut W,
    total_written: u64,
    entry_name: &str,
) -> Result<u64, String> {
    let remaining_total = ARCHIVE_MAX_TOTAL_BYTES.saturating_sub(total_written);
    let allowed = ARCHIVE_MAX_ENTRY_BYTES.min(remaining_total);
    let mut limited = (&mut *reader).take(allowed + 1);
    let written = std::io::copy(&mut limited, out)
        .map_err(|e| format!("Failed to write {entry_name:?}: {e}"))?;

    if written > ARCHIVE_MAX_ENTRY_BYTES {
        return Err(entry_limit_error(entry_name, written));
    }
    let total = total_written.saturating_add(written);
    if total > ARCHIVE_MAX_TOTAL_BYTES {
        return Err(total_limit_error(total));
    }
    Ok(written)
}

/// 读取 ZIP 条目字节到内存（单条目限额，超限显式报错）
///
/// 先按中央目录声明的 `size()` 快速拒绝，再按实际读取字节复核——声明的
/// 大小可被伪造，不能只信元数据。
fn read_zip_entry_capped(
    entry: &mut zip::read::ZipFile<'_>,
    entry_name: &str,
) -> Result<Vec<u8>, String> {
    let declared = entry.size();
    if declared > ARCHIVE_MAX_ENTRY_BYTES {
        return Err(entry_limit_error(format!("{entry_name:?}"), declared));
    }
    let mut buf = Vec::new();
    // `+1` 用于识别「恰好超过上限」（read_to_end 在限额处停止）
    (&mut *entry)
        .take(ARCHIVE_MAX_ENTRY_BYTES + 1)
        .read_to_end(&mut buf)
        .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"))?;
    if buf.len() as u64 > ARCHIVE_MAX_ENTRY_BYTES {
        return Err(entry_limit_error(
            format!("{entry_name:?}"),
            buf.len() as u64,
        ));
    }
    Ok(buf)
}

/// unzipFile(zipPath, outputPath?) — 解压 ZIP 文件
///
/// 将 `zip_path` 指向的 ZIP 文件解压到 `output_path`（默认为 ZIP 同目录下同名文件夹）。
/// 返回解压目标目录路径。
pub fn unzip_file(zip_path: &str, output_path: Option<&str>) -> Result<String, String> {
    let zip_path = Path::new(zip_path);
    if !zip_path.exists() {
        return Err(format!("ZIP file not found: {}", zip_path.display()));
    }

    let out_dir = match output_path {
        Some(p) => p.to_string(),
        None => {
            // 默认输出到同目录下去掉扩展名的文件夹
            let stem = zip_path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unzipped");
            let parent = zip_path.parent().unwrap_or(Path::new("."));
            parent.join(stem).to_string_lossy().to_string()
        }
    };

    let file = fs::File::open(zip_path).map_err(|e| format!("Failed to open ZIP: {e}"))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| format!("Invalid ZIP archive: {e}"))?;

    // P3-1：流式解压 + 单条目/总量限额 + 统一清理守卫（成功提交，失败自动
    // 删除本次写出的文件与新建目录，含输出根目录）
    let mut guard = ExtractionGuard::new();
    guard.ensure_dir(Path::new(&out_dir))?;

    let mut total_written: u64 = 0;

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| format!("Failed to read ZIP entry {i}: {e}"))?;

        // 使用 enclosed_name 防止路径穿越
        let entry_name = match entry.enclosed_name() {
            Some(name) => name.to_path_buf(),
            None => continue, // 跳过不安全路径
        };

        let target = Path::new(&out_dir).join(&entry_name);

        if entry.is_dir() {
            guard.ensure_dir(&target)?;
            continue;
        }

        // 声明大小快速拒绝（中央目录可伪造，实际写入字节由 copy_entry_capped 复核）
        let declared = entry.size();
        if declared > ARCHIVE_MAX_ENTRY_BYTES {
            return Err(entry_limit_error(entry_name.display(), declared));
        }
        if total_written.saturating_add(declared) > ARCHIVE_MAX_TOTAL_BYTES {
            return Err(total_limit_error(total_written.saturating_add(declared)));
        }

        // 确保父目录存在
        if let Some(parent) = target.parent() {
            guard.ensure_dir(parent)?;
        }

        let mut out = fs::File::create(&target)
            .map_err(|e| format!("Failed to write {}: {e}", target.display()))?;
        guard.track_file(&target);

        // 流式拷贝：整条目不再读入内存，超限即中止（半成品由守卫清理）
        total_written = copy_entry_capped(
            &mut entry,
            &mut out,
            total_written,
            &entry_name.to_string_lossy(),
        )?;
    }

    guard.commit();
    Ok(out_dir)
}

/// getZipStringContent(zipPath, entryName) — 读取 ZIP 中指定文件内容（UTF-8 字符串）
pub fn get_zip_string_content(zip_path: &str, entry_name: &str) -> Result<String, String> {
    let bytes = get_zip_byte_array_content(zip_path, entry_name)?;
    String::from_utf8(bytes).map_err(|e| format!("Entry is not valid UTF-8: {e}"))
}

/// getZipByteArrayContent(zipPath, entryName) — 读取 ZIP 中指定文件的字节
pub fn get_zip_byte_array_content(zip_path: &str, entry_name: &str) -> Result<Vec<u8>, String> {
    let zip_path = Path::new(zip_path);
    if !zip_path.exists() {
        return Err(format!("ZIP file not found: {}", zip_path.display()));
    }

    let file = fs::File::open(zip_path).map_err(|e| format!("Failed to open ZIP: {e}"))?;
    let mut archive =
        zip::ZipArchive::new(file).map_err(|e| format!("Invalid ZIP archive: {e}"))?;

    let mut entry = archive
        .by_name(entry_name)
        .map_err(|e| format!("Entry '{entry_name}' not found in ZIP: {e}"))?;

    // P3-1：单条目限额，超限显式报错（不静默截断）
    read_zip_entry_capped(&mut entry, entry_name)
}

/// zipEntryBytes(zipBytes, entryName) — 从内存中的 ZIP 字节数据读取指定条目
///
/// 对应 Kotlin `getZipByteArrayContent` 的 ZipInputStream 逻辑：
/// 用于网络 ZIP / 十六进制字符串等非本地文件场景。
pub fn zip_entry_bytes(zip_bytes: &[u8], entry_name: &str) -> Result<Vec<u8>, String> {
    let cursor = std::io::Cursor::new(zip_bytes);
    let mut archive =
        zip::ZipArchive::new(cursor).map_err(|e| format!("Invalid ZIP archive: {e}"))?;

    let mut entry = archive
        .by_name(entry_name)
        .map_err(|e| format!("Entry '{entry_name}' not found in ZIP: {e}"))?;

    // P3-1：单条目限额，超限显式报错（不静默截断）
    read_zip_entry_capped(&mut entry, entry_name)
}

/// 7z 条目名安全校验错误前缀
#[cfg(feature = "quickjs")]
const SEVEN_Z_ENTRY_NAME_ERROR_PREFIX: &str = "7z 条目名非法";

/// 7z 前置校验：条目名 + 声明解压大小（单条目 / 累计总量）
///
/// 7z 头部为每个条目声明 UnpackedSize，可在**任何写盘之前**整体拒绝超限
/// 归档（压缩炸弹的头部必然声明巨大的 UnpackedSize）。实际写入时仍按真实
/// 字节复核（见 [`copy_entry_capped`]），不信任可伪造的声明值。
#[cfg(feature = "quickjs")]
fn check_seven_z_declared_limits(archive: &sevenz_rust2::Archive) -> Result<(), String> {
    let mut total = 0u64;
    for entry in &archive.files {
        normalized_entry_name(SEVEN_Z_ENTRY_NAME_ERROR_PREFIX, &entry.name)?;
        if entry.is_directory {
            continue;
        }
        if entry.size > ARCHIVE_MAX_ENTRY_BYTES {
            return Err(entry_limit_error(&entry.name, entry.size));
        }
        total = total
            .checked_add(entry.size)
            .ok_or_else(|| total_limit_error(u64::MAX))?;
        if total > ARCHIVE_MAX_TOTAL_BYTES {
            return Err(total_limit_error(total));
        }
    }
    Ok(())
}

/// 解压单个 7z 条目到输出目录（逐条目流式，不整包入内存）
///
/// 调用前 [`check_seven_z_declared_limits`] 已按头部声明值整体校验；这里再
/// 按真实读取字节复核（声明值可被伪造），并按单条目/累计总量限额中止。
#[cfg(feature = "quickjs")]
fn extract_seven_z_entry(
    entry: &sevenz_rust2::ArchiveEntry,
    stream: &mut dyn Read,
    out_dir: &Path,
    guard: &mut ExtractionGuard,
    total_written: &mut u64,
) -> Result<(), String> {
    if entry.size > ARCHIVE_MAX_ENTRY_BYTES {
        return Err(entry_limit_error(&entry.name, entry.size));
    }
    let declared_total = total_written.saturating_add(entry.size);
    if declared_total > ARCHIVE_MAX_TOTAL_BYTES {
        return Err(total_limit_error(declared_total));
    }

    let rel = normalized_entry_name(SEVEN_Z_ENTRY_NAME_ERROR_PREFIX, &entry.name)?;
    let target = out_dir.join(&rel);

    if entry.is_directory {
        guard.ensure_dir(&target)?;
        return Ok(());
    }

    if let Some(parent) = target.parent() {
        guard.ensure_dir(parent)?;
    }
    let mut out = fs::File::create(&target)
        .map_err(|e| format!("Failed to write {}: {e}", target.display()))?;
    guard.track_file(&target);

    *total_written = copy_entry_capped(stream, &mut out, *total_written, &entry.name)?;
    Ok(())
}

/// un7zFile(7zPath, outputPath?) — 解压 7z 文件
///
/// 使用 `sevenz-rust2` 纯 Rust 实现解压 7z 格式文件。
/// 支持 LZMA/LZMA2/COPY 等编解码器。
/// 返回解压目标目录路径。
///
/// 安全：P2-1 起按 `ArchiveReader` 逐条目流式解压，写入前按头部声明大小与
/// 累计总量拒绝、写入时按实际字节复核（单条目 32MB / 总量 512MB），
/// 失败路径由 [`ExtractionGuard`] 统一清理半成品。
#[cfg(feature = "quickjs")]
pub fn un7z_file(seven_z_path: &str, output_path: Option<&str>) -> Result<String, String> {
    let src = Path::new(seven_z_path);
    if !src.exists() {
        return Err(format!("7z file not found: {}", src.display()));
    }

    let out_dir = match output_path {
        Some(p) => p.to_string(),
        None => {
            let stem = src
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("un7zipped");
            let parent = src.parent().unwrap_or(Path::new("."));
            parent.join(stem).to_string_lossy().to_string()
        }
    };

    let file = fs::File::open(src).map_err(|e| format!("Failed to open 7z: {e}"))?;
    let mut reader = sevenz_rust2::ArchiveReader::new(file, sevenz_rust2::Password::empty())
        .map_err(|e| format!("Invalid 7z archive: {e}"))?;

    // P2-1：先按头部声明大小整体校验（7z 头为每个条目声明 UnpackedSize），
    // 超限归档在创建输出目录/写盘之前直接拒绝
    check_seven_z_declared_limits(reader.archive())?;

    let mut guard = ExtractionGuard::new();
    guard.ensure_dir(Path::new(&out_dir))?;

    let mut total_written: u64 = 0;
    let mut failure: Option<String> = None;
    let result = reader.for_each_entries(|entry, stream| {
        match extract_seven_z_entry(
            entry,
            stream,
            Path::new(&out_dir),
            &mut guard,
            &mut total_written,
        ) {
            Ok(()) => Ok(true),
            Err(err) => {
                failure = Some(err);
                // 中止遍历；已写产物由守卫在返回后统一清理
                Ok(false)
            }
        }
    });

    if let Some(err) = failure {
        return Err(err);
    }
    result.map_err(|e| format!("7z decompression failed: {e}"))?;

    guard.commit();
    Ok(out_dir)
}

/// un7zFile — 无 quickjs feature 时的回退桩
#[cfg(not(feature = "quickjs"))]
pub fn un7z_file(_seven_z_path: &str, _output_path: Option<&str>) -> Result<String, String> {
    Err("[ERROR] 7z decompression requires 'quickjs' feature (sevenz-rust2)".to_string())
}

// ============================================================
// RAR 条目名安全闸门（批21-B 回修 P0/P1）
//
// rar crate 0.4 在 `extract_all` 中用**未净化的原始条目名**落盘
// （`file_writer.rs: File::create(format!("{}/{}", path, file.name))`），
// 且仅提供「解析即解压」入口，无法先拿到条目列表。因此：
// - 解压前按 RAR5 头部格式预扫描全部条目名，发现任一非法即整体拒绝，
//   不创建输出目录、不写任何文件；
// - 读取单个条目时同样先校验条目名（`Path::join` 遇绝对路径会覆盖基准
//   目录，`..` 可穿越），再 canonicalize 确认最终路径仍在输出目录内。
// ============================================================

/// RAR 条目名安全校验错误前缀
///
/// JS 层据此区分「条目名越界（安全拒绝，需显式 `[ERROR]`）」与「条目不存在
/// / 归档损坏（沿用 Kotlin 的返回空串语义）」。
pub const RAR_ENTRY_NAME_ERROR_PREFIX: &str = "RAR 条目名非法";

/// 错误是否由 RAR 条目安全校验产生（条目名非法 / 解析后越界）
pub fn is_rar_security_error(err: &str) -> bool {
    err.starts_with(RAR_ENTRY_NAME_ERROR_PREFIX) || err.starts_with("RAR 条目读取被拒绝")
}

/// 校验并规范化 RAR 条目名（`\` → `/`）
///
/// 只允许 [`Component::Normal`] 组件：拒绝空名、绝对路径、盘符/UNC/verbatim
/// 前缀、根目录与 `..`。返回规范化后的相对路径（用于安全 `join`）。
fn normalized_rar_entry_name(name: &str) -> Result<String, String> {
    normalized_entry_name(RAR_ENTRY_NAME_ERROR_PREFIX, name)
}

/// 通用条目名校验：只允许普通相对路径组件（`prefix` 区分归档格式的错误语义）
fn normalized_entry_name(prefix: &str, name: &str) -> Result<String, String> {
    let normalized = name.replace('\\', "/");
    let path = Path::new(&normalized);
    if normalized.is_empty() || path.is_absolute() {
        return Err(format!("{prefix}（空或绝对路径）: {name:?}"));
    }
    let mut has_normal = false;
    for component in path.components() {
        match component {
            Component::Normal(_) => has_normal = true,
            _ => {
                return Err(format!(
                    "{prefix}（含非普通路径组件，疑似路径穿越）: {name:?}"
                ))
            }
        }
    }
    if !has_normal {
        return Err(format!("{prefix}（无有效文件名）: {name:?}"));
    }
    Ok(normalized)
}

/// 在输出目录内安全读取已解压的 RAR 条目
///
/// 条目名先过 [`normalized_rar_entry_name`]，再 canonicalize 双重确认
/// （防御解压产物中的符号链接把最终路径带出输出目录）。
/// P3-1：读取同样受单条目限额约束（超限显式报错，不把整条目读入内存）。
fn read_rar_entry_inside(out_dir: &Path, entry_name: &str) -> Result<Vec<u8>, String> {
    let safe_entry = normalized_rar_entry_name(entry_name)?;
    let target = out_dir.join(&safe_entry);
    if !target.is_file() {
        return Err(format!("Entry '{entry_name}' not found in RAR"));
    }
    let canonical_root =
        fs::canonicalize(out_dir).map_err(|e| format!("Failed to resolve RAR output dir: {e}"))?;
    let canonical_target =
        fs::canonicalize(&target).map_err(|e| format!("Failed to resolve entry path: {e}"))?;
    if !canonical_target.starts_with(&canonical_root) {
        return Err(format!("RAR 条目读取被拒绝（解析后越界）: {entry_name:?}"));
    }
    let file = fs::File::open(&canonical_target)
        .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"))?;
    let mut buf = Vec::new();
    file.take(ARCHIVE_MAX_ENTRY_BYTES + 1)
        .read_to_end(&mut buf)
        .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"))?;
    if buf.len() as u64 > ARCHIVE_MAX_ENTRY_BYTES {
        return Err(entry_limit_error(entry_name, buf.len() as u64));
    }
    Ok(buf)
}

/// RAR5 签名（`Rar!\x1a\x07\x01\x00`）；RAR4 签名 `...\x00` 不受支持
const RAR5_SIGNATURE: &[u8] = b"Rar!\x1a\x07\x01\x00";

/// 读取 RAR5 变长整数（base-128 little-endian，高位续传）
///
/// 与 rar-0.4.0 `vint.rs` 同构；`pos` 为起始偏移，返回（值, 新偏移）。
fn read_rar5_vint(data: &[u8], pos: usize) -> Result<(u64, usize), String> {
    if pos >= data.len() {
        return Err("RAR 预扫描失败：头部被截断".to_string());
    }
    let mut len = 0usize;
    let mut found_end = false;
    for (i, &byte) in data[pos..].iter().enumerate() {
        len = i + 1;
        if byte & 0x80 == 0 {
            found_end = true;
            break;
        }
        if i >= 8 {
            return Err("RAR 预扫描失败：变长整数过长".to_string());
        }
    }
    if !found_end {
        return Err("RAR 预扫描失败：变长整数不完整".to_string());
    }
    let mut out = data[pos + len - 1] as u64;
    for i in (0..len - 1).rev() {
        out = (out << 7) | (data[pos + i] & 0x7F) as u64;
    }
    Ok((out, pos + len))
}

/// 越界安全的偏移推进
fn advance_rar_offset(data_len: usize, pos: usize, amount: u64) -> Result<usize, String> {
    let amount =
        usize::try_from(amount).map_err(|_| "RAR 预扫描失败：长度超出地址空间".to_string())?;
    pos.checked_add(amount)
        .filter(|end| *end <= data_len)
        .ok_or_else(|| "RAR 预扫描失败：头部/数据区长度越界".to_string())
}

/// 从流中读取 RAR5 变长整数（base-128 little-endian，返回（值, 消耗字节数））
///
/// 与 [`read_rar5_vint`] 同语义/同长度上限（最多 9 字节），供流式预扫描使用。
fn read_rar5_vint_stream<R: Read>(reader: &mut R) -> Result<(u64, u64), String> {
    let mut value = 0u64;
    for i in 0..9u32 {
        let mut byte = [0u8; 1];
        reader
            .read_exact(&mut byte)
            .map_err(|_| "RAR 预扫描失败：头部被截断".to_string())?;
        let b = byte[0];
        if b & 0x80 == 0 {
            value |= (b as u64) << (7 * i);
            return Ok((value, u64::from(i) + 1));
        }
        value |= ((b & 0x7F) as u64) << (7 * i);
    }
    Err("RAR 预扫描失败：变长整数过长".to_string())
}

/// 校验 RAR5 条目声明的解压后大小（P3-1：单条目 + 累计总量）
///
/// RAR5 FileBlock 头部自带 UnpackedSize；rar crate 在 `extract_all` 前无法
/// 逐条目拦截，因此在预扫描阶段按声明值拒绝超限归档（不在解压后才复核）。
fn check_rar5_unpacked_size(
    entry_name: &str,
    unpacked: u64,
    total: &mut u64,
) -> Result<(), String> {
    if unpacked > ARCHIVE_MAX_ENTRY_BYTES {
        return Err(entry_limit_error(entry_name, unpacked));
    }
    *total = total
        .checked_add(unpacked)
        .ok_or_else(|| total_limit_error(u64::MAX))?;
    if *total > ARCHIVE_MAX_TOTAL_BYTES {
        return Err(total_limit_error(*total));
    }
    Ok(())
}

/// 流式预扫描 RAR5 归档的全部条目名与解压后大小（解压前安全闸门）
///
/// 只读取块头部（数据区经 `seek` 跳过，不读入内存）；遍历 File/Service 块
/// 并校验每个条目名与声明解压大小；任一非法立即返回错误，调用方在
/// `extract_all` 之前中止。非 RAR5 输入 fail-closed（rar crate 的 RAR4
/// 解压未实现，此前同样无法解压）。
fn scan_rar5_entry_names_reader<R: Read + Seek>(reader: &mut R) -> Result<Vec<String>, String> {
    // 先取归档总长，用于所有偏移/长度的越界校验（seek 越过 EOF 不会报错）
    let total_len = reader
        .seek(SeekFrom::End(0))
        .map_err(|e| format!("RAR 预扫描失败：无法定位归档末尾（{e}）"))?;
    reader
        .seek(SeekFrom::Start(0))
        .map_err(|e| format!("RAR 预扫描失败：无法回到归档开头（{e}）"))?;

    let mut signature = [0u8; 8];
    if reader.read_exact(&mut signature).is_err() || signature.as_slice() != RAR5_SIGNATURE {
        return Err("RAR 预扫描失败：仅支持 RAR5 归档（RAR4 解压未实现）".to_string());
    }

    let mut pos = RAR5_SIGNATURE.len() as u64;
    let mut names = Vec::new();
    let mut total_unpacked = 0u64;
    let mut block_count = 0usize;
    loop {
        block_count += 1;
        if block_count > 10_000 {
            return Err("RAR 预扫描失败：头部数量异常".to_string());
        }
        // HeadBlock：CRC32（4 字节，crate 亦不校验）+ vint(HeaderSize)
        let crc_end = pos
            .checked_add(4)
            .filter(|end| *end <= total_len)
            .ok_or_else(|| "RAR 预扫描失败：头部被截断".to_string())?;
        let mut crc = [0u8; 4];
        reader
            .read_exact(&mut crc)
            .map_err(|_| "RAR 预扫描失败：头部被截断".to_string())?;
        pos = crc_end;

        let (header_size, consumed) = read_rar5_vint_stream(reader)?;
        pos = pos
            .checked_add(consumed)
            .ok_or_else(|| "RAR 预扫描失败：长度超出地址空间".to_string())?;
        if header_size == 0 || header_size > RAR5_MAX_HEADER_BYTES {
            return Err("RAR 预扫描失败：头部长度异常".to_string());
        }
        let header_end = pos
            .checked_add(header_size)
            .filter(|end| *end <= total_len)
            .ok_or_else(|| "RAR 预扫描失败：头部/数据区长度越界".to_string())?;

        // HeaderSize 覆盖从 HeaderType 起的全部头部字段（含条目名），整块读入
        let mut header = vec![0u8; header_size as usize];
        reader
            .read_exact(&mut header)
            .map_err(|_| "RAR 预扫描失败：头部被截断".to_string())?;

        let header_len = header.len();
        let mut hpos = 0usize;
        let (typ, next) = read_rar5_vint(&header, hpos)?;
        hpos = next;
        let (flags, next) = read_rar5_vint(&header, hpos)?;
        hpos = next;
        if flags & 0x01 != 0 {
            // Extra area size（内容跳过，后面按 HeaderSize 对齐）
            let (_, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
        }
        let mut data_size = 0u64;
        if flags & 0x02 != 0 {
            let (size, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            data_size = size;
        }
        if typ == 2 || typ == 3 {
            // FileBlock：flags/unpacked/attrs/[mtime]/[crc]/compression/os/name
            let (file_flags, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            let (unpacked_size, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            let (_, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            if file_flags & 0x02 != 0 {
                hpos = advance_rar_offset(header_len, hpos, 4)?; // mtime u32
            }
            if file_flags & 0x04 != 0 {
                hpos = advance_rar_offset(header_len, hpos, 4)?; // data CRC32
            }
            let (_, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            let (_, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            let (name_len, next) = read_rar5_vint(&header, hpos)?;
            hpos = next;
            let name_end = advance_rar_offset(header_len, hpos, name_len)?;
            let name = std::str::from_utf8(&header[hpos..name_end])
                .map_err(|_| "RAR 预扫描失败：条目名非 UTF-8".to_string())?;
            normalized_rar_entry_name(name)?;
            check_rar5_unpacked_size(name, unpacked_size, &mut total_unpacked)?;
            names.push(name.to_string());
        }

        // 跳到数据区末尾（流式：只 seek，不读入内存）
        pos = header_end
            .checked_add(data_size)
            .filter(|end| *end <= total_len)
            .ok_or_else(|| "RAR 预扫描失败：头部/数据区长度越界".to_string())?;
        reader
            .seek(SeekFrom::Start(pos))
            .map_err(|e| format!("RAR 预扫描失败：无法跳过数据区（{e}）"))?;

        if typ == 5 {
            // 归档结束块
            return Ok(names);
        }
        if pos >= total_len {
            return Err("RAR 预扫描失败：缺少归档结束块".to_string());
        }
    }
}

/// 预扫描 RAR5 归档的全部条目名（内存字节入口，委托流式实现）
fn scan_rar5_entry_names(data: &[u8]) -> Result<Vec<String>, String> {
    scan_rar5_entry_names_reader(&mut std::io::Cursor::new(data))
}

/// unrarFile(rarPath, outputPath?) — 解压 RAR 文件
///
/// 使用 `rar` crate 纯 Rust 实现（需 quickjs feature；当前仅 RAR5，RAR4
/// 解压未实现）。
/// 返回解压目标目录路径。
///
/// 安全：解压前预扫描全部条目名（[`scan_rar5_entry_names`]），含绝对路径 /
/// `../` 等越界条目时整体拒绝且不创建输出目录（rar crate 直接以原始条目名
/// 落盘，不能等解压后再校验）。
///
/// Kotlin 原版走 libarchive（`ArchiveUtils.deCompress`），此处以纯 Rust 方案对等替代。
#[cfg(feature = "quickjs")]
pub fn unrar_file(rar_path: &str, output_path: Option<&str>) -> Result<String, String> {
    let src = Path::new(rar_path);
    if !src.exists() {
        return Err(format!("RAR file not found: {}", src.display()));
    }

    // 解压前预扫描：rar crate 边解析边落盘，必须在任何写入之前拒绝恶意条目。
    // P3-1：流式读头部（不再 `fs::read` 整包），数据区只 seek 跳过。
    let archive_file =
        fs::File::open(src).map_err(|e| format!("Failed to read RAR archive: {e}"))?;
    scan_rar5_entry_names_reader(&mut std::io::BufReader::new(archive_file))?;

    let out_dir = match output_path {
        Some(p) => p.to_string(),
        None => {
            let stem = src
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("unrarred");
            let parent = src.parent().unwrap_or(Path::new("."));
            parent.join(stem).to_string_lossy().to_string()
        }
    };

    fs::create_dir_all(&out_dir).map_err(|e| format!("Failed to create output dir: {e}"))?;

    // rar crate 仅支持文件路径入参；空密码表示无加密
    rar::Archive::extract_all(rar_path, &out_dir, "")
        .map_err(|e| format!("RAR decompression failed: {e}"))?;

    Ok(out_dir)
}

/// unrarFile — 无 quickjs feature 时的回退桩
#[cfg(not(feature = "quickjs"))]
pub fn unrar_file(_rar_path: &str, _output_path: Option<&str>) -> Result<String, String> {
    Err("[ERROR] RAR decompression requires 'quickjs' feature (rar crate)".to_string())
}

/// sevenZEntryBytes — 从内存中的 7z 字节数据读取指定条目
///
/// 对应 Kotlin `get7zByteArrayContent` 的流式读取逻辑：
/// 用于网络 7z / 十六进制字符串等非本地文件场景。
#[cfg(feature = "quickjs")]
pub fn seven_z_entry_bytes(seven_z_bytes: &[u8], entry_name: &str) -> Result<Vec<u8>, String> {
    let cursor = std::io::Cursor::new(seven_z_bytes);
    let mut reader = sevenz_rust2::ArchiveReader::new(cursor, sevenz_rust2::Password::empty())
        .map_err(|e| format!("Invalid 7z archive: {e}"))?;
    // P3-1：`read_file` 会把整条目读入 Vec，先按头部声明大小拒绝超大条目
    // （7z 头部 size 是解码器的输出上界，`BoundedReader` 不会超出该值）
    if let Some(entry) = reader
        .archive()
        .files
        .iter()
        .find(|entry| entry.name == entry_name)
    {
        if entry.size > ARCHIVE_MAX_ENTRY_BYTES {
            return Err(entry_limit_error(entry_name, entry.size));
        }
    }
    reader
        .read_file(entry_name)
        .map_err(|e| format!("Entry '{entry_name}' not found in 7z: {e}"))
}

/// sevenZEntryBytes — 无 quickjs feature 时的回退桩
#[cfg(not(feature = "quickjs"))]
pub fn seven_z_entry_bytes(_seven_z_bytes: &[u8], _entry_name: &str) -> Result<Vec<u8>, String> {
    Err("[ERROR] 7z entry reading requires 'quickjs' feature (sevenz-rust2)".to_string())
}

/// rarEntryBytes — 从内存中的 RAR 字节数据读取指定条目
///
/// 对应 Kotlin `getRarByteArrayContent` 的流式读取逻辑。
/// rar crate 仅支持文件路径，故经临时文件中转：写入临时 .rar → 解压到临时目录 → 读取条目。
///
/// 安全（批21-B 回修 P0）：`entry_name` 由书源控制，必须先校验（仅普通相对
/// 路径组件），否则 `out_dir.join(绝对路径)` 会覆盖基准目录、`..` 可穿越；
/// 归档本身也先预扫描条目名再解压（防恶意条目写到临时目录之外）。
#[cfg(feature = "quickjs")]
pub fn rar_entry_bytes(rar_bytes: &[u8], entry_name: &str) -> Result<Vec<u8>, String> {
    use std::time::{SystemTime, UNIX_EPOCH};

    // 1) 条目名先校验；2) 归档条目名预扫描（两者都在写临时文件/解压之前）
    normalized_rar_entry_name(entry_name)?;
    scan_rar5_entry_names(rar_bytes)?;

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let dir =
        std::env::temp_dir().join(format!("legado_rar_entry_{}_{}", std::process::id(), nanos));
    fs::create_dir_all(&dir).map_err(|e| format!("Failed to create temp dir: {e}"))?;

    let result = (|| -> Result<Vec<u8>, String> {
        let rar_file = dir.join("data.rar");
        fs::write(&rar_file, rar_bytes).map_err(|e| format!("Failed to write temp RAR: {e}"))?;

        let out_dir = dir.join("out");
        fs::create_dir_all(&out_dir).map_err(|e| format!("Failed to create extract dir: {e}"))?;

        let rar_path = rar_file
            .to_str()
            .ok_or_else(|| "Temp RAR path is not valid UTF-8".to_string())?;
        let out_path = out_dir
            .to_str()
            .ok_or_else(|| "Temp extract path is not valid UTF-8".to_string())?;
        rar::Archive::extract_all(rar_path, out_path, "")
            .map_err(|e| format!("Invalid RAR archive: {e}"))?;

        read_rar_entry_inside(&out_dir, entry_name)
    })();

    // 无论成败都清理临时目录
    let _ = fs::remove_dir_all(&dir);
    result
}

/// rarEntryBytes — 无 quickjs feature 时的回退桩
#[cfg(not(feature = "quickjs"))]
pub fn rar_entry_bytes(_rar_bytes: &[u8], _entry_name: &str) -> Result<Vec<u8>, String> {
    Err("[ERROR] RAR entry reading requires 'quickjs' feature (rar crate)".to_string())
}

/// unArchiveFile(archivePath, outputPath?) — 通用解压（自动检测格式）
///
/// 根据文件头 magic bytes 检测压缩格式，分派到对应解压函数。
pub fn un_archive_file(archive_path: &str, output_path: Option<&str>) -> Result<String, String> {
    let magic = read_file_magic(archive_path)?;
    match magic.as_str() {
        "PK" => unzip_file(archive_path, output_path),
        "7z" => un7z_file(archive_path, output_path),
        "Rar" => unrar_file(archive_path, output_path),
        _ => Err(format!(
            "Unknown archive format for file: {archive_path} (magic: {magic})"
        )),
    }
}

/// 读取文件头部 magic bytes 以判断压缩格式
///
/// P3-1：只读前 [`MAGIC_PREFIX_BYTES`] 字节（旧实现 `fs::read` 整包仅为判
/// 前 4 字节，GB 级压缩包会造成无谓的内存峰值）。
fn read_file_magic(path: &str) -> Result<String, String> {
    let mut head = Vec::new();
    fs::File::open(path)
        .map_err(|e| format!("Failed to read file '{path}': {e}"))?
        .take(MAGIC_PREFIX_BYTES as u64)
        .read_to_end(&mut head)
        .map_err(|e| format!("Failed to read file '{path}': {e}"))?;

    // 关键签名：ZIP "PK"、7z "7z"、RAR "Rar!"（与既有判定口径一致）
    if head.starts_with(b"PK") {
        return Ok("PK".to_string());
    }
    if head.starts_with(b"7z") {
        return Ok("7z".to_string());
    }
    if head.starts_with(b"Rar!") {
        return Ok("Rar".to_string());
    }
    Ok("unknown".to_string())
}

/// `java.inflateRawBytes(data)` — raw-deflate 解压（无 zlib/gzip 头）
///
/// P2-9 ①：语料 `java.util.zip.Inflater` 流程（2 个源）中
/// `new Inflater(true)` 的 `true` 即 no-wrap（raw deflate）。
/// 先按 raw deflate 解压；未完整消费输入时再按 zlib 封装
/// （windowBits=15，带 2 字节头 + adler32 尾）宽容重试；
/// 均失败 → 可捕获错误（JS 侧 try/catch 降级为空串，不炸整条规则）。
#[cfg(feature = "quickjs")]
pub fn inflate_raw_bytes(data: &[u8]) -> Result<Vec<u8>, String> {
    use flate2::{Decompress, FlushDecompress, Status};

    if data.is_empty() {
        return Ok(Vec::new());
    }
    // 单次尝试：全新 Decompress + 逐次扩容的输出缓冲（无状态机跨调用
    // 输出偏移语义，避免脏读）。flate2::Status：Ok/BufError = 需更多
    // 空间继续，StreamEnd = 流完整结束（对齐 Java Inflater：解到流尾即止，
    // 尾部多余字节忽略）。
    fn attempt(no_wrap: bool, data: &[u8]) -> Result<Vec<u8>, String> {
        for attempt in 0..8u32 {
            let cap = (data.len() as u64 * 2u64.saturating_pow(attempt) + 64)
                .clamp(1024, 64 * 1024 * 1024) as usize;
            let mut out = vec![0u8; cap];
            let mut d = Decompress::new(no_wrap);
            let status = match d.decompress(data, &mut out, FlushDecompress::Finish) {
                Ok(s) => s,
                Err(e) => return Err(format!("inflateRawBytes: 流损坏（{e}）")),
            };
            if status == Status::StreamEnd {
                out.truncate(d.total_out() as usize);
                return Ok(out);
            }
            // Ok / BufError：输出缓冲不足或流未结束 → 扩容重试
        }
        Err(format!(
            "inflateRawBytes: 解压未完成（{} 字节数据）",
            data.len()
        ))
    }

    // 1) zlib 封装优先：flate2 `Decompress::new(zlib_header=true)` 即 zlib 解码
    //    （等价 Java `Inflater(false)`）；P2-11 §197：原注释极性与实现相反，已更正
    if let Ok(v) = attempt(true, data) {
        return Ok(v);
    }
    // 2) 宽容重试：裸 deflate（`Decompress::new(false)`，等价 Java `Inflater(true)`
    //    的 nowrap 语义）
    if let Ok(v) = attempt(false, data) {
        return Ok(v);
    }
    Err(format!(
        "inflateRawBytes: 非合法 deflate/zlib 数据（{} 字节）",
        data.len()
    ))
}

// ============================================================
// 单元测试
// ============================================================
#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;
    use zip::ZipWriter;

    /// 辅助：创建包含指定条目的测试 ZIP 文件，返回 ZIP 路径
    fn create_test_zip(entries: &[(&str, &[u8])]) -> String {
        let dir = std::env::temp_dir().join(format!("legado_archive_test_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("test.zip");

        let file = fs::File::create(&zip_path).unwrap();
        let mut writer = ZipWriter::new(file);
        let options =
            SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);

        for (name, content) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(content).unwrap();
        }
        writer.finish().unwrap();

        zip_path.to_string_lossy().to_string()
    }

    /// 简单 UUID（避免测试依赖 uuid crate feature；进程内递增序号防并发撞刻）
    fn uuid() -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::time::{SystemTime, UNIX_EPOCH};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        // 进程内单调序号：防两次并发 create_test_zip 落在同一时钟刻（SystemTime
        // 粒度较粗）撞目录——共享 test.zip 被截断 / 目录被先结束者删掉的 flake
        let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
        format!("{:x}{:x}{:x}", std::process::id(), nanos, seq)
    }

    #[test]
    fn test_unzip_file_basic() {
        let zip_path = create_test_zip(&[
            ("hello.txt", b"Hello World"),
            ("sub/data.bin", &[0x01, 0x02, 0x03]),
        ]);

        let out_dir = std::env::temp_dir().join(format!("legado_unzip_out_{}", uuid()));
        let result = unzip_file(&zip_path, Some(out_dir.to_str().unwrap()));
        assert!(result.is_ok());

        let out = result.unwrap();
        assert!(Path::new(&out).join("hello.txt").exists());
        assert!(Path::new(&out).join("sub/data.bin").exists());

        let content = fs::read_to_string(Path::new(&out).join("hello.txt")).unwrap();
        assert_eq!(content, "Hello World");

        // 清理
        let _ = fs::remove_dir_all(&out);
        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_unzip_file_default_output() {
        let zip_path = create_test_zip(&[("a.txt", b"aaa")]);
        let result = unzip_file(&zip_path, None);
        assert!(result.is_ok());

        let out = result.unwrap();
        // 默认输出目录为 ZIP 同目录下 "test" 文件夹
        assert!(out.ends_with("test"));
        assert!(Path::new(&out).join("a.txt").exists());

        let _ = fs::remove_dir_all(&out);
        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_unzip_file_not_found() {
        let result = unzip_file("/nonexistent/path.zip", None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    #[test]
    fn test_get_zip_string_content() {
        let zip_path = create_test_zip(&[("readme.md", b"# Title\nContent here")]);
        let result = get_zip_string_content(&zip_path, "readme.md");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), "# Title\nContent here");

        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_get_zip_string_content_not_found_entry() {
        let zip_path = create_test_zip(&[("a.txt", b"data")]);
        let result = get_zip_string_content(&zip_path, "nonexistent.txt");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));

        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_get_zip_byte_array_content() {
        let data: &[u8] = &[0xDE, 0xAD, 0xBE, 0xEF];
        let zip_path = create_test_zip(&[("binary.bin", data)]);
        let result = get_zip_byte_array_content(&zip_path, "binary.bin");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), vec![0xDE, 0xAD, 0xBE, 0xEF]);

        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_get_zip_byte_array_content_zip_not_found() {
        let result = get_zip_byte_array_content("/no/such/file.zip", "entry");
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("not found"));
    }

    #[test]
    fn test_zip_entry_bytes_from_memory() {
        let content = "内存 ZIP 内容";
        let zip_path = create_test_zip(&[("inner.txt", content.as_bytes())]);
        let zip_bytes = fs::read(&zip_path).unwrap();

        let result = zip_entry_bytes(&zip_bytes, "inner.txt");
        assert!(result.is_ok());
        assert_eq!(result.unwrap(), content.as_bytes().to_vec());

        // 不存在的条目应报错
        assert!(zip_entry_bytes(&zip_bytes, "no-such.txt").is_err());
        // 非法 ZIP 数据应报错
        assert!(zip_entry_bytes(b"not a zip", "a").is_err());

        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_un7z_file_not_found() {
        let result = un7z_file("/nonexistent/path.7z", None);
        assert!(result.is_err());
        let err = result.unwrap_err();
        // quickjs feature 启用时报 "not found"，否则报 feature 提示
        assert!(err.contains("not found") || err.contains("quickjs"));
    }

    #[test]
    fn test_unrar_file_stub_or_not_found() {
        // quickjs feature 启用时：真实实现，不存在的文件报 "not found"；
        // 未启用时：回退桩，报 feature 提示
        let result = unrar_file("some.rar", None);
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.contains("not found") || err.contains("quickjs"));
    }

    #[test]
    fn test_rar_entry_bytes_invalid_data() {
        let result = rar_entry_bytes(b"not a rar archive", "a.txt");
        assert!(result.is_err());
    }

    /// 最小 RAR5 测试归档：单文件 hello.txt（STORE 无压缩），
    /// 内容为 "Hello RAR World!"（由 scripts/gen_rar5_fixture.py 按 RAR5 格式规范构造）
    #[cfg(feature = "quickjs")]
    const RAR5_HELLO: &[u8] = &[
        0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, 0xc5, 0x1a, 0x33, 0x32, 0x03, 0x01, 0x00,
        0x00, 0xe4, 0xf8, 0x02, 0x48, 0x16, 0x02, 0x02, 0x10, 0x04, 0x10, 0x20, 0xec, 0x68, 0x08,
        0x45, 0x00, 0x01, 0x09, 0x68, 0x65, 0x6c, 0x6c, 0x6f, 0x2e, 0x74, 0x78, 0x74, 0x48, 0x65,
        0x6c, 0x6c, 0x6f, 0x20, 0x52, 0x41, 0x52, 0x20, 0x57, 0x6f, 0x72, 0x6c, 0x64, 0x21, 0x19,
        0xb2, 0x3a, 0x35, 0x03, 0x05, 0x00, 0x00,
    ];

    /// 恶意 RAR5 测试归档：单文件条目名 `../legado_rar_traversal.txt`
    /// （由 `scripts/gen_rar5_fixture.py --name ../legado_rar_traversal.txt \`
    ///  `--content TRAVERSAL-PAYLOAD --const RAR5_TRAVERSAL` 构造）
    #[cfg(feature = "quickjs")]
    const RAR5_TRAVERSAL: &[u8] = &[
        0x52, 0x61, 0x72, 0x21, 0x1a, 0x07, 0x01, 0x00, 0xc5, 0x1a, 0x33, 0x32, 0x03, 0x01, 0x00,
        0x00, 0xeb, 0x19, 0x8f, 0x93, 0x28, 0x02, 0x02, 0x11, 0x04, 0x11, 0x20, 0x37, 0x1a, 0xd6,
        0x49, 0x00, 0x01, 0x1b, 0x2e, 0x2e, 0x2f, 0x6c, 0x65, 0x67, 0x61, 0x64, 0x6f, 0x5f, 0x72,
        0x61, 0x72, 0x5f, 0x74, 0x72, 0x61, 0x76, 0x65, 0x72, 0x73, 0x61, 0x6c, 0x2e, 0x74, 0x78,
        0x74, 0x54, 0x52, 0x41, 0x56, 0x45, 0x52, 0x53, 0x41, 0x4c, 0x2d, 0x50, 0x41, 0x59, 0x4c,
        0x4f, 0x41, 0x44, 0x19, 0xb2, 0x3a, 0x35, 0x03, 0x05, 0x00, 0x00,
    ];

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_rar_entry_bytes_rar5_basic() {
        let content = rar_entry_bytes(RAR5_HELLO, "hello.txt");
        assert!(
            content.is_ok(),
            "rar_entry_bytes failed: {:?}",
            content.err()
        );
        assert_eq!(content.unwrap(), b"Hello RAR World!");

        // 不存在的条目应报错
        assert!(rar_entry_bytes(RAR5_HELLO, "no-such.txt").is_err());
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_unrar_file_rar5_basic() {
        let dir = std::env::temp_dir().join(format!("legado_rar5_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let rar_path = dir.join("hello.rar");
        fs::write(&rar_path, RAR5_HELLO).unwrap();

        let out_dir = dir.join("out");
        let result = unrar_file(rar_path.to_str().unwrap(), Some(out_dir.to_str().unwrap()));
        assert!(result.is_ok(), "unrar_file failed: {:?}", result.err());

        let content = fs::read_to_string(out_dir.join("hello.txt")).unwrap();
        assert_eq!(content, "Hello RAR World!");

        // 默认输出目录：同目录下去掉扩展名的文件夹
        let result2 = unrar_file(rar_path.to_str().unwrap(), None);
        assert!(
            result2.is_ok(),
            "unrar_file default out failed: {:?}",
            result2.err()
        );
        assert!(Path::new(&result2.unwrap()).join("hello.txt").exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_rar_entry_bytes_rejects_absolute_entry() {
        // 回归锁 P0：绝对路径 entry 不得借 `Path::join` 覆盖解压基准目录。
        // 修复前 out_dir.join(绝对路径) 直接读回沙箱外文件。
        let dir = std::env::temp_dir().join(format!("legado_rar_abs_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let secret = dir.join("secret.txt");
        fs::write(&secret, b"TOP-SECRET").unwrap();

        let err = rar_entry_bytes(RAR5_HELLO, secret.to_str().unwrap()).unwrap_err();
        assert!(err.contains("条目名非法"), "err = {err}");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_rar_entry_bytes_rejects_parent_dir_entry() {
        // 回归锁 P0：`../..` entry 不得穿越出临时解压目录。
        // 解压目录为 <temp>/legado_rar_entry_<pid>_<nanos>/out，
        // 两级 `..` 正好回到 <temp>；修复前会读回该秘密文件。
        let name = format!("legado_rar_escape_{}.txt", uuid());
        let outside = std::env::temp_dir().join(&name);
        fs::write(&outside, b"ESCAPED-SECRET").unwrap();

        let err = rar_entry_bytes(RAR5_HELLO, &format!("../../{name}")).unwrap_err();
        assert!(err.contains("条目名非法"), "err = {err}");

        let _ = fs::remove_file(&outside);
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_unrar_file_rejects_traversal_entry() {
        // 回归锁 P1：rar crate 以原始条目名落盘（file_writer.rs:20），
        // `../` 条目必须在解压前整体拒绝，且不创建输出目录、不写出越界文件。
        let dir = std::env::temp_dir().join(format!("legado_rar_traversal_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let rar_path = dir.join("evil.rar");
        fs::write(&rar_path, RAR5_TRAVERSAL).unwrap();

        let out_dir = dir.join("out");
        let err =
            unrar_file(rar_path.to_str().unwrap(), Some(out_dir.to_str().unwrap())).unwrap_err();
        assert!(err.contains("条目名非法"), "err = {err}");
        assert!(!out_dir.exists(), "预扫描拒绝时不应创建输出目录");
        assert!(
            !dir.join("legado_rar_traversal.txt").exists(),
            "越界条目不得写出输出目录"
        );

        // 读取侧对同一恶意归档同样在解压前拒绝
        assert!(rar_entry_bytes(RAR5_TRAVERSAL, "legado_rar_traversal.txt").is_err());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_seven_z_entry_bytes_basic() {
        let seven_z_path = create_test_7z(&[
            ("chapter.txt", "第七章 内容文本".as_bytes()),
            ("sub/data.bin", &[0x11, 0x22]),
        ]);
        let bytes = fs::read(&seven_z_path).unwrap();

        // 读取存在的条目
        let content = seven_z_entry_bytes(&bytes, "chapter.txt");
        assert!(
            content.is_ok(),
            "seven_z_entry_bytes failed: {:?}",
            content.err()
        );
        assert_eq!(
            String::from_utf8(content.unwrap()).unwrap(),
            "第七章 内容文本"
        );

        // 子目录条目
        let bin = seven_z_entry_bytes(&bytes, "sub/data.bin").unwrap();
        assert_eq!(bin, vec![0x11, 0x22]);

        // 不存在的条目应报错
        assert!(seven_z_entry_bytes(&bytes, "no-such.txt").is_err());
        // 非法 7z 数据应报错
        assert!(seven_z_entry_bytes(b"not a 7z", "a").is_err());

        let _ = fs::remove_dir_all(Path::new(&seven_z_path).parent().unwrap());
    }

    #[test]
    fn test_un_archive_file_zip() {
        let zip_path = create_test_zip(&[("file.txt", b"archive content")]);
        let out_dir = std::env::temp_dir().join(format!("legado_unarchive_{}", uuid()));
        let result = un_archive_file(&zip_path, Some(out_dir.to_str().unwrap()));
        assert!(result.is_ok());
        assert!(Path::new(&result.unwrap()).join("file.txt").exists());

        let _ = fs::remove_dir_all(&out_dir);
        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_un_archive_file_unknown_format() {
        // 创建一个非压缩文件
        let dir = std::env::temp_dir().join(format!("legado_unknown_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("data.xyz");
        fs::write(&file_path, b"not an archive").unwrap();

        let result = un_archive_file(file_path.to_str().unwrap(), None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("Unknown archive format"));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_file_magic_zip() {
        let zip_path = create_test_zip(&[("x.txt", b"x")]);
        let magic = read_file_magic(&zip_path).unwrap();
        assert_eq!(magic, "PK");

        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    #[test]
    fn test_read_file_magic_7z() {
        let dir = std::env::temp_dir().join(format!("legado_magic7z_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("test.7z");
        // 7z magic: 37 7A BC AF 27 1C
        fs::write(&file_path, [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]).unwrap();

        let magic = read_file_magic(file_path.to_str().unwrap()).unwrap();
        assert_eq!(magic, "7z");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_file_magic_rar() {
        let dir = std::env::temp_dir().join(format!("legado_magicrar_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("test.rar");
        fs::write(&file_path, b"Rar!\x1a\x07\x00").unwrap();

        let magic = read_file_magic(file_path.to_str().unwrap()).unwrap();
        assert_eq!(magic, "Rar");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_read_file_magic_large_file_prefix() {
        // P3-1：magic 只需读前缀；大文件（此处 1MB）也应正常判定
        let dir = std::env::temp_dir().join(format!("legado_magiclarge_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let file_path = dir.join("big.zip");
        let mut data = b"PK\x03\x04".to_vec();
        data.resize(1024 * 1024, 0);
        fs::write(&file_path, &data).unwrap();

        let magic = read_file_magic(file_path.to_str().unwrap()).unwrap();
        assert_eq!(magic, "PK");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_unzip_file_rejects_oversized_entry() {
        // P3-1 回归锁：单条目超过 32MB 时解压应显式报错并清理半成品
        let dir = std::env::temp_dir().join(format!("legado_zip_bomb_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("bomb.zip");
        {
            let file = fs::File::create(&zip_path).unwrap();
            let mut writer = ZipWriter::new(file);
            // Deflated：源数据 33MB 全 0，压缩后仅数十 KB，避免测试落盘膨胀
            let options =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            writer.start_file("huge.bin", options).unwrap();
            writer
                .write_all(&vec![0u8; (ARCHIVE_MAX_ENTRY_BYTES + 1) as usize])
                .unwrap();
            writer.finish().unwrap();
        }

        let out_dir = dir.join("out");
        let err =
            unzip_file(zip_path.to_str().unwrap(), Some(out_dir.to_str().unwrap())).unwrap_err();
        assert!(err.contains(ARCHIVE_LIMIT_ERROR_PREFIX), "err = {err}");
        assert!(err.contains("单条目上限"), "err = {err}");
        assert!(!out_dir.join("huge.bin").exists(), "超限条目不得留下半成品");

        // 同样的条目经内存读取入口也应显式报错
        let err = get_zip_byte_array_content(zip_path.to_str().unwrap(), "huge.bin").unwrap_err();
        assert!(err.contains(ARCHIVE_LIMIT_ERROR_PREFIX), "err = {err}");

        let _ = fs::remove_dir_all(&dir);
    }

    /// P3-1 回归锁：第 2 个条目创建失败时，第 1 个已写文件必须清理
    ///
    /// 修复前 `by_index` / `File::create` 失败走 `?` 直接返回，已解压文件残留。
    #[test]
    fn test_unzip_file_cleans_up_when_entry_create_fails() {
        let zip_path = create_test_zip(&[
            ("a_first.txt", b"first entry"),
            ("z_blocked.txt", b"second entry"),
        ]);

        let dir = std::env::temp_dir().join(format!("legado_zip_cleanup_{}", uuid()));
        let out_dir = dir.join("out");
        fs::create_dir_all(&out_dir).unwrap();
        // 用同名目录占位，使第 2 个条目的 `File::create` 必然失败
        fs::create_dir_all(out_dir.join("z_blocked.txt")).unwrap();

        let err = unzip_file(&zip_path, Some(out_dir.to_str().unwrap())).unwrap_err();
        assert!(err.contains("Failed to write"), "err = {err}");
        assert!(
            !out_dir.join("a_first.txt").exists(),
            "第 1 个已写文件必须随失败清理"
        );
        assert!(
            out_dir.join("z_blocked.txt").is_dir(),
            "用户已有同名目录不得删除"
        );
        assert!(out_dir.exists(), "用户已有输出目录不得删除");

        let _ = fs::remove_dir_all(&dir);
        let _ = fs::remove_dir_all(Path::new(&zip_path).parent().unwrap());
    }

    /// P3-1 回归锁：限额失败时本次创建的输出根目录也不得残留
    #[test]
    fn test_unzip_file_removes_created_output_dir_on_limit_failure() {
        let dir = std::env::temp_dir().join(format!("legado_zip_root_cleanup_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let zip_path = dir.join("bomb.zip");
        {
            let file = fs::File::create(&zip_path).unwrap();
            let mut writer = ZipWriter::new(file);
            let stored =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
            writer.start_file("small.txt", stored).unwrap();
            writer.write_all(b"ok").unwrap();
            // 第 2 个条目超单条目上限；Deflated 压缩避免测试落盘膨胀
            let deflated =
                SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
            writer.start_file("huge.bin", deflated).unwrap();
            writer
                .write_all(&vec![0u8; (ARCHIVE_MAX_ENTRY_BYTES + 1) as usize])
                .unwrap();
            writer.finish().unwrap();
        }

        let out_dir = dir.join("out");
        let err =
            unzip_file(zip_path.to_str().unwrap(), Some(out_dir.to_str().unwrap())).unwrap_err();
        assert!(err.contains("单条目上限"), "err = {err}");
        assert!(!out_dir.exists(), "失败后本次创建的输出根目录必须清理");

        let _ = fs::remove_dir_all(&dir);
    }

    // ============================================================
    // RAR5 头部构造辅助（仅用于预扫描限额测试；CRC 不被预扫描校验）
    // ============================================================

    fn rar5_vint(mut n: u64) -> Vec<u8> {
        let mut out = Vec::new();
        loop {
            let b = (n & 0x7F) as u8;
            n >>= 7;
            if n != 0 {
                out.push(b | 0x80);
            } else {
                out.push(b);
                return out;
            }
        }
    }

    fn rar5_block(header_type: u64, flags: u64, body: &[u8], data_size: Option<u64>) -> Vec<u8> {
        let mut head = rar5_vint(header_type);
        head.extend_from_slice(&rar5_vint(flags));
        if let Some(size) = data_size {
            head.extend_from_slice(&rar5_vint(size));
        }
        head.extend_from_slice(body);
        let mut out = vec![0u8; 4]; // CRC32 置 0（预扫描不校验）
        out.extend_from_slice(&rar5_vint(head.len() as u64));
        out.extend_from_slice(&head);
        out
    }

    /// 构造最小 RAR5 归档：`entries` 为（条目名, 声明解压后大小），数据区长度为 0
    fn build_rar5_fixture(entries: &[(&str, u64)]) -> Vec<u8> {
        let mut out = RAR5_SIGNATURE.to_vec();
        out.extend_from_slice(&rar5_block(1, 0, &rar5_vint(0), None)); // 主头
        for (name, declared_unpacked) in entries {
            let mut body = rar5_vint(0); // file flags：无 mtime/CRC
            body.extend_from_slice(&rar5_vint(*declared_unpacked));
            body.extend_from_slice(&rar5_vint(0x20)); // attributes
            body.extend_from_slice(&rar5_vint(0)); // compression info（store）
            body.extend_from_slice(&rar5_vint(1)); // host os
            body.extend_from_slice(&rar5_vint(name.len() as u64));
            body.extend_from_slice(name.as_bytes());
            out.extend_from_slice(&rar5_block(2, 0x0002, &body, Some(0)));
        }
        out.extend_from_slice(&rar5_block(5, 0, &rar5_vint(0), None)); // 结束块
        out
    }

    #[test]
    fn test_scan_rar5_rejects_oversized_entry() {
        // P3-1 回归锁：声明解压后大小超过单条目上限 → 预扫描即拒绝
        let fixture = build_rar5_fixture(&[("big.bin", ARCHIVE_MAX_ENTRY_BYTES + 1)]);
        let err = scan_rar5_entry_names(&fixture).unwrap_err();
        assert!(err.contains("单条目上限"), "err = {err}");
    }

    #[test]
    fn test_scan_rar5_rejects_oversized_total() {
        // P3-1 回归锁：多条各自未超限、累计超过 512MB 总量 → 预扫描拒绝
        let per_entry = ARCHIVE_MAX_ENTRY_BYTES; // 恰好等于单条目上限（允许）
        let count = (ARCHIVE_MAX_TOTAL_BYTES / per_entry + 1) as usize;
        let entries: Vec<(String, u64)> = (0..count)
            .map(|i| (format!("part-{i}.bin"), per_entry))
            .collect();
        let refs: Vec<(&str, u64)> = entries
            .iter()
            .map(|(name, size)| (name.as_str(), *size))
            .collect();
        let fixture = build_rar5_fixture(&refs);
        let err = scan_rar5_entry_names(&fixture).unwrap_err();
        assert!(err.contains("总量上限"), "err = {err}");
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_unrar_file_streaming_scan_rejects_oversized_entry() {
        // P3-1：unrar_file 走流式预扫描，超限归档必须在创建输出目录前拒绝
        let dir = std::env::temp_dir().join(format!("legado_rar_bomb_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let rar_path = dir.join("bomb.rar");
        fs::write(
            &rar_path,
            build_rar5_fixture(&[("big.bin", ARCHIVE_MAX_ENTRY_BYTES + 1)]),
        )
        .unwrap();

        let out_dir = dir.join("out");
        let err =
            unrar_file(rar_path.to_str().unwrap(), Some(out_dir.to_str().unwrap())).unwrap_err();
        assert!(err.contains("单条目上限"), "err = {err}");
        assert!(!out_dir.exists(), "预扫描拒绝时不应创建输出目录");

        let _ = fs::remove_dir_all(&dir);
    }

    // ============================================================
    // 7z 解压测试（需要 quickjs feature 启用 sevenz-rust2）
    // ============================================================

    /// 辅助：按给定顺序创建 7z（条目顺序确定，用于「第 2 个条目失败」类测试）
    #[cfg(feature = "quickjs")]
    fn create_test_7z_ordered(entries: &[(&str, &[u8])]) -> String {
        let dir = std::env::temp_dir().join(format!("legado_7z_ordered_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let seven_z_path = dir.join("test.7z");

        let mut writer = sevenz_rust2::ArchiveWriter::create(&seven_z_path).unwrap();
        for (name, content) in entries {
            writer
                .push_archive_entry(
                    sevenz_rust2::ArchiveEntry::new_file(name),
                    Some(std::io::Cursor::new(content.to_vec())),
                )
                .unwrap();
        }
        writer.finish().unwrap();

        seven_z_path.to_string_lossy().to_string()
    }

    /// 辅助：创建包含指定文件的测试 7z 压缩包，返回 7z 文件路径
    #[cfg(feature = "quickjs")]
    fn create_test_7z(entries: &[(&str, &[u8])]) -> String {
        let dir = std::env::temp_dir().join(format!("legado_7z_src_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();

        // 先创建源文件
        for (name, content) in entries {
            let file_path = dir.join(name);
            if let Some(parent) = file_path.parent() {
                fs::create_dir_all(parent).unwrap();
            }
            fs::write(&file_path, content).unwrap();
        }

        // 压缩为 7z
        let seven_z_path = std::env::temp_dir()
            .join(format!("legado_7z_archive_{}", uuid()))
            .join("test.7z");
        if let Some(parent) = seven_z_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        sevenz_rust2::compress_to_path(&dir, &seven_z_path).unwrap();

        // 清理源文件目录
        let _ = fs::remove_dir_all(&dir);

        seven_z_path.to_string_lossy().to_string()
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_un7z_file_basic() {
        let seven_z_path = create_test_7z(&[
            ("hello.txt", b"Hello 7z World"),
            ("sub/data.bin", &[0xCA, 0xFE, 0xBA, 0xBE]),
        ]);

        let out_dir = std::env::temp_dir().join(format!("legado_7z_out_{}", uuid()));
        let result = un7z_file(&seven_z_path, Some(out_dir.to_str().unwrap()));
        assert!(result.is_ok(), "un7z_file failed: {:?}", result.err());

        let out = result.unwrap();
        assert!(Path::new(&out).join("hello.txt").exists());
        assert!(Path::new(&out).join("sub/data.bin").exists());

        let content = fs::read_to_string(Path::new(&out).join("hello.txt")).unwrap();
        assert_eq!(content, "Hello 7z World");

        let bin = fs::read(Path::new(&out).join("sub/data.bin")).unwrap();
        assert_eq!(bin, vec![0xCA, 0xFE, 0xBA, 0xBE]);

        // 清理
        let _ = fs::remove_dir_all(&out);
        let _ = fs::remove_dir_all(Path::new(&seven_z_path).parent().unwrap());
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_un7z_file_default_output() {
        let seven_z_path = create_test_7z(&[("readme.md", b"# 7z Test")]);
        let result = un7z_file(&seven_z_path, None);
        assert!(result.is_ok(), "un7z_file failed: {:?}", result.err());

        let out = result.unwrap();
        // 默认输出目录为 7z 同目录下 "test" 文件夹
        assert!(
            out.ends_with("test"),
            "output dir should end with 'test', got: {out}"
        );
        assert!(Path::new(&out).join("readme.md").exists());

        let content = fs::read_to_string(Path::new(&out).join("readme.md")).unwrap();
        assert_eq!(content, "# 7z Test");

        let _ = fs::remove_dir_all(&out);
        let _ = fs::remove_dir_all(Path::new(&seven_z_path).parent().unwrap());
    }

    #[test]
    #[cfg(feature = "quickjs")]
    fn test_un_archive_file_7z() {
        let seven_z_path = create_test_7z(&[("content.txt", b"auto detect 7z")]);
        let out_dir = std::env::temp_dir().join(format!("legado_unarchive7z_{}", uuid()));
        let result = un_archive_file(&seven_z_path, Some(out_dir.to_str().unwrap()));
        assert!(
            result.is_ok(),
            "un_archive_file 7z failed: {:?}",
            result.err()
        );

        let out = result.unwrap();
        assert!(Path::new(&out).join("content.txt").exists());
        let content = fs::read_to_string(Path::new(&out).join("content.txt")).unwrap();
        assert_eq!(content, "auto detect 7z");

        let _ = fs::remove_dir_all(&out);
        let _ = fs::remove_dir_all(Path::new(&seven_z_path).parent().unwrap());
    }

    /// P2-1 回归锁：7z 整包解压必须与 ZIP 同口径限额
    ///
    /// 修复前 `un7z_file` 直接 `sevenz_rust2::decompress_file`，对条目声明/实际
    /// 解压大小没有任何限制，书源可控的 7z 压缩炸弹可无限写盘。
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_un7z_file_rejects_oversized_entry() {
        let dir = std::env::temp_dir().join(format!("legado_7z_bomb_{}", uuid()));
        fs::create_dir_all(&dir).unwrap();
        let seven_z_path = dir.join("bomb.7z");
        // 33MB 全 0（高压缩比），压缩后仅数十 KB；流式生成，不占测试内存
        {
            let mut writer = sevenz_rust2::ArchiveWriter::create(&seven_z_path).unwrap();
            writer
                .push_archive_entry(
                    sevenz_rust2::ArchiveEntry::new_file("huge.bin"),
                    Some(std::io::repeat(0).take(ARCHIVE_MAX_ENTRY_BYTES + 1)),
                )
                .unwrap();
            writer.finish().unwrap();
        }

        let out_dir = dir.join("out");
        let err = un7z_file(
            seven_z_path.to_str().unwrap(),
            Some(out_dir.to_str().unwrap()),
        )
        .unwrap_err();
        assert!(err.contains(ARCHIVE_LIMIT_ERROR_PREFIX), "err = {err}");
        assert!(err.contains("单条目上限"), "err = {err}");
        assert!(!out_dir.exists(), "超限 7z 不得留下输出目录或半成品");

        // 通用入口按 magic 分派到 7z 时同样受限
        let err = un_archive_file(
            seven_z_path.to_str().unwrap(),
            Some(dir.join("out2").to_str().unwrap()),
        )
        .unwrap_err();
        assert!(err.contains(ARCHIVE_LIMIT_ERROR_PREFIX), "err = {err}");

        let _ = fs::remove_dir_all(&dir);
    }

    /// P2-1 回归锁：7z 条目声明大小之和超过总量上限时，解压前整体拒绝
    ///
    /// 用内存 `Archive` 构造声明值（无需真实 544MB 数据），验证前置校验
    /// 覆盖「多条各自合法、累计超限」的压缩炸弹。
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_check_seven_z_declared_limits_rejects_oversized_total() {
        let per_entry = ARCHIVE_MAX_ENTRY_BYTES; // 恰好等于单条目上限（允许）
        let count = (ARCHIVE_MAX_TOTAL_BYTES / per_entry + 1) as usize;
        let mut archive = sevenz_rust2::Archive::default();
        archive.files = (0..count)
            .map(|i| {
                let mut entry = sevenz_rust2::ArchiveEntry::new_file(&format!("part-{i}.bin"));
                entry.size = per_entry;
                entry
            })
            .collect();

        let err = check_seven_z_declared_limits(&archive).unwrap_err();
        assert!(err.contains("总量上限"), "err = {err}");

        // 单条目声明超限同样在前置校验拒绝
        let mut archive = sevenz_rust2::Archive::default();
        archive.files = vec![{
            let mut entry = sevenz_rust2::ArchiveEntry::new_file("big.bin");
            entry.size = ARCHIVE_MAX_ENTRY_BYTES + 1;
            entry
        }];
        let err = check_seven_z_declared_limits(&archive).unwrap_err();
        assert!(err.contains("单条目上限"), "err = {err}");
    }

    /// P3-1 回归锁：7z 解压中第 2 个条目创建失败时，第 1 个已写文件必须清理
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_un7z_file_cleans_up_when_entry_create_fails() {
        let seven_z_path = create_test_7z_ordered(&[
            ("a_first.txt", b"first entry"),
            ("z_blocked.txt", b"second entry"),
        ]);

        let out_dir = std::env::temp_dir().join(format!("legado_7z_cleanup_{}", uuid()));
        fs::create_dir_all(&out_dir).unwrap();
        // 用同名目录占位，使第 2 个条目的 `File::create` 必然失败
        fs::create_dir_all(out_dir.join("z_blocked.txt")).unwrap();

        let err = un7z_file(&seven_z_path, Some(out_dir.to_str().unwrap())).unwrap_err();
        assert!(err.contains("Failed to write"), "err = {err}");
        assert!(
            !out_dir.join("a_first.txt").exists(),
            "第 1 个已写文件必须随失败清理"
        );
        assert!(
            out_dir.join("z_blocked.txt").is_dir(),
            "用户已有同名目录不得删除"
        );
        assert!(out_dir.exists(), "用户已有输出目录不得删除");

        let _ = fs::remove_dir_all(&out_dir);
        let _ = fs::remove_dir_all(Path::new(&seven_z_path).parent().unwrap());
    }

    /// P2-9 ①：raw-deflate 解压（Inflater(true) 语料面）+ zlib 宽容回退
    #[test]
    #[cfg(feature = "quickjs")]
    fn test_inflate_raw_bytes() {
        use flate2::write::{DeflateEncoder, ZlibEncoder};
        use flate2::Compression;
        use std::io::Write as _;

        let payload = b"legado-inflate-raw-test-\xE6\x95\xB0\xE6\x8D\xAE-1234567890";
        // raw deflate（DeflateEncoder 输出即无 zlib 头）
        let mut raw = Vec::new();
        {
            let mut enc = DeflateEncoder::new(raw, Compression::fast());
            enc.write_all(payload).unwrap();
            raw = enc.finish().unwrap();
        }
        assert_eq!(inflate_raw_bytes(&raw).unwrap(), payload);

        // zlib 封装数据走宽容回退路径
        let mut zlib = Vec::new();
        {
            let mut enc = ZlibEncoder::new(zlib, Compression::fast());
            enc.write_all(payload).unwrap();
            zlib = enc.finish().unwrap();
        }
        assert_eq!(inflate_raw_bytes(&zlib).unwrap(), payload);

        // 垃圾数据 → 可捕获错误（不 panic）
        assert!(inflate_raw_bytes(b"not-deflate-garbage-data").is_err());
        // 空输入 → 空输出
        assert_eq!(inflate_raw_bytes(&[]).unwrap(), Vec::<u8>::new());
    }
}
