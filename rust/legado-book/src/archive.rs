//! 压缩包导入模块
//!
//! 支持 ZIP/RAR/7z 格式压缩包中书籍文件的识别与提取。
//! 对应 Kotlin 原版 `ArchiveUtils` + `LocalBook.importArchiveFile` 逻辑。
//!
//! 处理流程：
//! 1. 打开压缩包（ZIP 使用 `zip` crate，RAR 使用 `unrar` crate，
//!    7z 使用 `sevenz-rust2`；7z 打开前先做 32 字节签名头预检，见 §2.34 批24b）
//! 2. 遍历压缩包条目，筛选书籍文件（.txt/.epub/.mobi/.pdf/.umd/.azw3/.azw）
//! 3. 提取书籍文件到指定输出目录（同名 basename 按序号去重，不互相覆盖）
//! 4. 返回提取后的文件路径列表

use std::collections::{HashMap, HashSet, VecDeque};
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use legado_core::{LegadoError, LegadoResult};

/// 支持的书籍文件扩展名列表
const BOOK_EXTENSIONS: &[&str] = &[".txt", ".epub", ".mobi", ".pdf", ".umd", ".azw3", ".azw"];

/// 判断文件名是否为支持的书籍格式
fn is_book_file(name: &str) -> bool {
    let lower = name.to_lowercase();
    BOOK_EXTENSIONS.iter().any(|ext| lower.ends_with(ext))
}

/// 从文件名中提取基础名称（去除路径前缀）
fn file_base_name(name: &str) -> &str {
    // 压缩包内路径可能使用 / 或 \ 分隔
    name.rsplit(['/', '\\']).next().unwrap_or(name)
}

/// 导入 ZIP 压缩包中的书籍文件
///
/// # 参数
/// - `zip_path`: ZIP 文件路径
/// - `output_dir`: 提取目标目录
///
/// # 返回
/// 提取的书籍文件路径列表
pub fn import_zip_file(zip_path: &str, output_dir: &str) -> LegadoResult<Vec<String>> {
    let file = File::open(zip_path)
        .map_err(|e| LegadoError::BookParse(format!("无法打开ZIP文件: {e}")))?;

    let mut archive = zip::ZipArchive::new(file)
        .map_err(|e| LegadoError::BookParse(format!("ZIP文件解析失败: {e}")))?;

    // 确保输出目录存在
    fs::create_dir_all(output_dir)?;

    let mut extracted_files = Vec::new();

    for i in 0..archive.len() {
        let mut entry = archive
            .by_index(i)
            .map_err(|e| LegadoError::BookParse(format!("读取ZIP条目失败: {e}")))?;

        // 跳过目录
        if entry.is_dir() {
            continue;
        }

        let entry_name = entry.name().to_string();
        let base_name = file_base_name(&entry_name);

        // 跳过隐藏文件
        if base_name.starts_with('.') {
            continue;
        }

        // 仅提取书籍文件
        if !is_book_file(base_name) {
            continue;
        }

        // 构造输出路径（使用基础文件名避免路径穿越）
        let out_path = safe_output_path(output_dir, base_name)?;

        // 提取文件内容
        let mut buf = Vec::new();
        entry
            .read_to_end(&mut buf)
            .map_err(|e| LegadoError::BookParse(format!("解压文件失败 [{base_name}]: {e}")))?;

        let mut out_file = File::create(&out_path)?;
        out_file.write_all(&buf)?;

        extracted_files.push(out_path.to_string_lossy().to_string());
    }

    Ok(extracted_files)
}

/// 导入 RAR 压缩包中的书籍文件
///
/// # 参数
/// - `rar_path`: RAR 文件路径
/// - `output_dir`: 提取目标目录
/// - `password`: 可选密码（用于加密 RAR 文件）
///
/// # 返回
/// 提取的书籍文件路径列表
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn import_rar_file(
    rar_path: &str,
    output_dir: &str,
    password: Option<&str>,
) -> LegadoResult<Vec<String>> {
    // 确保输出目录存在
    fs::create_dir_all(output_dir)?;

    // 根据是否有密码选择不同的打开方式
    let arc = match password {
        Some(pw) => unrar::Archive::with_password(rar_path, pw),
        None => unrar::Archive::new(rar_path),
    };

    let mut open_arc = arc
        .open_for_processing()
        .map_err(|e| LegadoError::BookParse(format!("无法打开RAR文件: {e}")))?;

    let mut extracted_files = Vec::new();

    // 逐条目处理 RAR 文件
    loop {
        let header_result = open_arc
            .read_header()
            .map_err(|e| LegadoError::BookParse(format!("读取RAR条目失败: {e}")))?;

        match header_result {
            Some(arc_with_file) => {
                let entry = arc_with_file.entry();

                // 跳过目录
                if entry.is_directory() {
                    open_arc = arc_with_file
                        .skip()
                        .map_err(|e| LegadoError::BookParse(format!("跳过RAR条目失败: {e}")))?;
                    continue;
                }

                let name = entry.filename.to_string_lossy().to_string();
                let base_name = file_base_name(&name).to_string();

                // 跳过隐藏文件和非书籍文件
                if base_name.starts_with('.') || !is_book_file(&base_name) {
                    open_arc = arc_with_file
                        .skip()
                        .map_err(|e| LegadoError::BookParse(format!("跳过RAR条目失败: {e}")))?;
                    continue;
                }

                // 读取文件内容到内存
                let (data, next_arc) = arc_with_file.read().map_err(|e| {
                    LegadoError::BookParse(format!("解压RAR文件失败 [{base_name}]: {e}"))
                })?;

                // 构造安全的输出路径并写入
                let out_path = safe_output_path(output_dir, &base_name)?;
                let mut out_file = File::create(&out_path)?;
                out_file.write_all(&data)?;

                extracted_files.push(out_path.to_string_lossy().to_string());
                open_arc = next_arc;
            }
            None => break, // 所有条目处理完毕
        }
    }

    Ok(extracted_files)
}

/// Android/iOS 平台不支持 RAR（unrar_sys 无法交叉编译）
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn import_rar_file(
    _rar_path: &str,
    _output_dir: &str,
    _password: Option<&str>,
) -> LegadoResult<Vec<String>> {
    Err(LegadoError::BookParse(
        "Android 平台暂不支持 RAR 解压".to_string(),
    ))
}

/// 列出 ZIP 压缩包中的书籍文件名（不解压）
///
/// # 参数
/// - `zip_path`: ZIP 文件路径
///
/// # 返回
/// 书籍文件名列表
pub fn list_zip_book_files(zip_path: &str) -> LegadoResult<Vec<String>> {
    let file = File::open(zip_path)
        .map_err(|e| LegadoError::BookParse(format!("无法打开ZIP文件: {e}")))?;

    let mut archive = zip::ZipArchive::new(file)
        .map_err(|e| LegadoError::BookParse(format!("ZIP文件解析失败: {e}")))?;

    let mut book_files = Vec::new();
    for i in 0..archive.len() {
        let entry = archive
            .by_index(i)
            .map_err(|e| LegadoError::BookParse(format!("读取ZIP条目失败: {e}")))?;

        if entry.is_dir() {
            continue;
        }

        let name = entry.name().to_string();
        let base_name = file_base_name(&name);
        if !base_name.starts_with('.') && is_book_file(base_name) {
            book_files.push(base_name.to_string());
        }
    }

    Ok(book_files)
}

/// 列出 RAR 压缩包中的书籍文件名（不解压）
///
/// # 参数
/// - `rar_path`: RAR 文件路径
/// - `password`: 可选密码
///
/// # 返回
/// 书籍文件名列表
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn list_rar_book_files(rar_path: &str, password: Option<&str>) -> LegadoResult<Vec<String>> {
    let arc = match password {
        Some(pw) => unrar::Archive::with_password(rar_path, pw),
        None => unrar::Archive::new(rar_path),
    };

    let open_arc = arc
        .open_for_listing()
        .map_err(|e| LegadoError::BookParse(format!("无法打开RAR文件: {e}")))?;

    let mut book_files = Vec::new();
    for entry_result in open_arc {
        let entry =
            entry_result.map_err(|e| LegadoError::BookParse(format!("读取RAR目录失败: {e}")))?;

        if entry.is_directory() {
            continue;
        }

        let name = entry.filename.to_string_lossy().to_string();
        let base = file_base_name(&name).to_string();
        if !base.starts_with('.') && is_book_file(&base) {
            book_files.push(base);
        }
    }

    Ok(book_files)
}

/// Android/iOS 平台不支持 RAR 列表
#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn list_rar_book_files(_rar_path: &str, _password: Option<&str>) -> LegadoResult<Vec<String>> {
    Err(LegadoError::BookParse(
        "Android 平台暂不支持 RAR 解压".to_string(),
    ))
}

// ============================================================
// 7z 导入（批24，§2.34）
// ============================================================

/// 7z 导入限额（fail-closed：任一项超限整包失败）
///
/// 默认值即生产限额；测试可构造更小的 `ArchiveLimits` 验证边界。
#[derive(Debug, Clone, Copy)]
pub struct ArchiveLimits {
    /// 输入 7z 文件大小上限（512 MiB）
    pub max_input_size: u64,
    /// 单条目解压字节上限（256 MiB，按实际读取字节计，不信任声明值）
    pub max_entry_size: u64,
    /// 全部条目解压总量上限（512 MiB，含非书籍条目的 drain 字节）
    pub max_total_size: u64,
    /// 条目数上限（10000）
    pub max_entries: usize,
    /// LZMA/LZMA2 字典大小上限（128 MiB）
    pub max_dict_size: u64,
}

impl Default for ArchiveLimits {
    fn default() -> Self {
        Self {
            max_input_size: 512 * 1024 * 1024,
            max_entry_size: 256 * 1024 * 1024,
            max_total_size: 512 * 1024 * 1024,
            max_entries: 10_000,
            max_dict_size: 128 * 1024 * 1024,
        }
    }
}

/// 判断路径是否为 7z 分卷首卷（`.001`）——分卷不在支持范围
fn is_multi_volume_7z_path(path: &str) -> bool {
    path.to_ascii_lowercase().ends_with(".001")
}

/// 7z 签名头固定长度（规范定义 32 字节）
const SEVEN_Z_SIGNATURE_HEADER_SIZE: usize = 32;
/// 7z 文件签名（"7z\xBC\xAF\x27\x1C"）
const SEVEN_Z_SIGNATURE: [u8; 6] = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];
/// 头部明文大小硬上限（64 MiB，纵深防御）
///
/// 上游 `init_archive` 已先拒绝 `next_header_size > reader_len`（声明值不得超过
/// 实际文件长度），因此该门槛**不是修复某个已知 OOM**，而是纵深防御：把明文
/// 头部缓冲区进一步限制在 64 MiB 内（书籍包头部实际只有几十 KiB）。
///
/// 未缓解向量（与 §2.34 批24c、`docs/RESIDUAL_RISKS_2026-08-13.md` 7Z-1 一致）：
/// 编码头（EncodedHeader）解码输出经 `take(unpack_size).read_to_end` 按实际解码
/// 字节增长，恶意流可声明超大 unpack size 解出海量明文；编码头内部的 LZMA 字典
/// 也在 `ArchiveReader::open` 期间按属性分配，而 `check_7z_archive` 的字典检查
/// 发生在其后。**仅头部明文缓冲区受限，解码内存未缓解**。
const SEVEN_Z_MAX_HEADER_SIZE: u64 = 64 * 1024 * 1024;

/// 自读 7z 32 字节签名头，做签名与头部大小预检（在 `ArchiveReader::open` 之前）
///
/// 签名头布局（7z 规范）：
/// - 0..6   签名 `37 7A BC AF 27 1C`
/// - 6..8   版本（major/minor）
/// - 8..12  StartHeaderCRC
/// - 12..20 NextHeaderOffset（LE u64）
/// - 20..28 NextHeaderSize（LE u64）
/// - 28..32 NextHeaderCRC
///
/// 只拒绝「签名错误 / 头部不足 / NextHeaderSize 超过 64 MiB」三类，
/// 其余结构问题仍交给上游给出精确错误。注意：该门槛限制的是头部声明长度，
/// 不能阻止编码头内部声明超大 LZMA 字典（上游解码期分配），该残余风险已登记。
fn precheck_7z_signature_header(path: &str) -> LegadoResult<()> {
    let mut file =
        File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开7z文件: {e}")))?;
    let mut head = [0u8; SEVEN_Z_SIGNATURE_HEADER_SIZE];
    let mut read = 0usize;
    while read < head.len() {
        match file.read(&mut head[read..]) {
            Ok(0) => break,
            Ok(n) => read += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                return Err(LegadoError::BookParse(format!("7z 头部读取失败: {e}")));
            }
        }
    }

    let signature_end = read.min(SEVEN_Z_SIGNATURE.len());
    if read < SEVEN_Z_SIGNATURE.len() || head[..SEVEN_Z_SIGNATURE.len()] != SEVEN_Z_SIGNATURE {
        return Err(LegadoError::BookParse(format!(
            "不是有效的 7z 文件（签名错误: {:02X?}）",
            &head[..signature_end]
        )));
    }
    if read < SEVEN_Z_SIGNATURE_HEADER_SIZE {
        return Err(LegadoError::BookParse(format!(
            "7z 文件头部不完整（{read} 字节，至少需要 {SEVEN_Z_SIGNATURE_HEADER_SIZE} 字节）"
        )));
    }

    let mut size_bytes = [0u8; 8];
    size_bytes.copy_from_slice(&head[20..28]);
    let next_header_size = u64::from_le_bytes(size_bytes);
    if next_header_size > SEVEN_Z_MAX_HEADER_SIZE {
        return Err(LegadoError::BookParse(format!(
            "7z 头部过大（声明 {next_header_size} 字节，上限 {SEVEN_Z_MAX_HEADER_SIZE} 字节）"
        )));
    }
    Ok(())
}

/// 输入大小与分卷前置检查
fn precheck_7z_input(path: &str, limits: &ArchiveLimits) -> LegadoResult<()> {
    if is_multi_volume_7z_path(path) {
        return Err(LegadoError::BookParse(
            "不支持分卷 7z（请使用单文件 7z 后重试）".to_string(),
        ));
    }
    let meta =
        fs::metadata(path).map_err(|e| LegadoError::BookParse(format!("无法打开7z文件: {e}")))?;
    if meta.len() > limits.max_input_size {
        return Err(LegadoError::BookParse(format!(
            "7z 文件过大（{} 字节，上限 {} 字节）",
            meta.len(),
            limits.max_input_size
        )));
    }
    precheck_7z_signature_header(path)?;
    Ok(())
}

/// 校验单个条目名（路径安全 fail-closed）
///
/// 规则：`\` 归一化为 `/` 后，逐组件拒绝 `..`；拒绝绝对路径（含 `//` 前缀）、
/// Windows 盘符（`X:`）、空字节。任一条目不安全 → 整包拒绝。
fn validate_7z_entry_name(raw: &str) -> LegadoResult<()> {
    if raw.is_empty() {
        return Err(LegadoError::BookParse("7z 条目名为空".to_string()));
    }
    if raw.contains('\0') {
        return Err(LegadoError::BookParse(format!(
            "非法 7z 条目名（含空字节）: {}",
            raw.escape_debug()
        )));
    }
    let normalized = raw.replace('\\', "/");
    if normalized.starts_with('/') {
        return Err(LegadoError::BookParse(format!(
            "非法 7z 条目名（绝对路径）: {raw}"
        )));
    }
    let bytes = normalized.as_bytes();
    if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
        return Err(LegadoError::BookParse(format!(
            "非法 7z 条目名（盘符路径）: {raw}"
        )));
    }
    if normalized.split('/').any(|component| component == "..") {
        return Err(LegadoError::BookParse(format!(
            "非法 7z 条目名（路径穿越）: {raw}"
        )));
    }
    // Windows 上冒号是备用数据流（ADS）分隔符：`ab:cd.txt` 会被解释为写入
    // `ab` 的 `cd.txt` 流，既不产生同名文件，也可能被安全软件拦截。
    // 非 Windows 平台冒号是合法文件名字符，故仅在 Windows 拒绝。
    #[cfg(windows)]
    if normalized.contains(':') {
        return Err(LegadoError::BookParse(format!(
            "非法 7z 条目名（Windows 不支持冒号，会写入备用数据流）: {raw}"
        )));
    }
    Ok(())
}

/// 校验压缩方法：AES 视为加密包，未支持的算法提前失败
fn check_7z_method(
    method_id: &[u8],
    properties: &[u8],
    limits: &ArchiveLimits,
) -> LegadoResult<()> {
    use sevenz_rust2::EncoderMethod as M;

    if method_id == M::ID_AES256_SHA256 {
        return Err(LegadoError::BookParse(
            "暂不支持加密 7z（请先解密后再导入）".to_string(),
        ));
    }
    if method_id == M::ID_LZMA {
        if properties.len() < 5 {
            return Err(LegadoError::BookParse(
                "7z LZMA 编码属性损坏（长度不足）".to_string(),
            ));
        }
        let dict =
            u32::from_le_bytes([properties[1], properties[2], properties[3], properties[4]]) as u64;
        if dict > limits.max_dict_size {
            return Err(LegadoError::BookParse(format!(
                "7z LZMA 字典超限（{dict} 字节，上限 {} 字节）",
                limits.max_dict_size
            )));
        }
        return Ok(());
    }
    if method_id == M::ID_LZMA2 {
        let Some(&p) = properties.first() else {
            return Err(LegadoError::BookParse(
                "7z LZMA2 编码属性损坏（长度不足）".to_string(),
            ));
        };
        // 7z 规范：p > 40 无定义（视为 4 GiB+，超限）；p == 40 为 4 GiB。
        let dict = if p > 40 {
            u64::MAX
        } else if p == 40 {
            0xFFFF_FFFF
        } else {
            (2 | (p & 1) as u64) << (p as u32 / 2 + 11)
        };
        if dict > limits.max_dict_size {
            return Err(LegadoError::BookParse(format!(
                "7z LZMA2 字典超限（{dict} 字节，上限 {} 字节）",
                limits.max_dict_size
            )));
        }
        return Ok(());
    }

    // 允许清单：COPY / Delta / BCJ 系列（无额外内存风险）。
    const ALLOWED: &[&[u8]] = &[
        M::ID_COPY,
        M::ID_DELTA,
        M::ID_BCJ_X86,
        M::ID_BCJ_ARM,
        M::ID_BCJ_ARM64,
        M::ID_BCJ_ARM_THUMB,
        M::ID_BCJ_PPC,
        M::ID_BCJ_IA64,
        M::ID_BCJ_SPARC,
        M::ID_BCJ_RISCV,
        M::ID_BCJ2,
    ];
    if ALLOWED.contains(&method_id) {
        return Ok(());
    }

    // 已知但不支持的方法给出明确名称；其余按方法 ID 报错
    let known: &[(&[u8], &str)] = &[
        (M::ID_PPMD, "PPMd"),
        (M::ID_BZIP2, "BZip2"),
        (M::ID_DEFLATE, "Deflate"),
        (M::ID_DEFLATE64, "Deflate64"),
        (M::ID_LZ4, "LZ4"),
        (M::ID_ZSTD, "Zstd"),
        (M::ID_BROTLI, "Brotli"),
        (M::ID_LZS, "LZS"),
        (M::ID_LIZARD, "Lizard"),
    ];
    if let Some((_, name)) = known.iter().find(|(id, _)| *id == method_id) {
        return Err(LegadoError::BookParse(format!(
            "不支持的 7z 压缩算法：{name}"
        )));
    }
    Err(LegadoError::BookParse(format!(
        "不支持的 7z 压缩算法（方法 ID {method_id:02X?}）"
    )))
}

/// 校验整包：条目数 / 声明大小 / 编码器（AES/字典）
fn check_7z_archive(archive: &sevenz_rust2::Archive, limits: &ArchiveLimits) -> LegadoResult<()> {
    if archive.files.len() > limits.max_entries {
        return Err(LegadoError::BookParse(format!(
            "7z 条目数超限（{}，上限 {}）",
            archive.files.len(),
            limits.max_entries
        )));
    }
    let mut total_declared: u64 = 0;
    for entry in &archive.files {
        validate_7z_entry_name(&entry.name)?;
        if entry.is_directory {
            continue;
        }
        if entry.size > limits.max_entry_size {
            return Err(LegadoError::BookParse(format!(
                "7z 单条目过大 [{0}]（{1} 字节，上限 {2} 字节）",
                entry.name, entry.size, limits.max_entry_size
            )));
        }
        total_declared = total_declared.saturating_add(entry.size);
        if total_declared > limits.max_total_size {
            return Err(LegadoError::BookParse(format!(
                "7z 解压总量超限（声明合计超过 {} 字节）",
                limits.max_total_size
            )));
        }
    }
    for block in &archive.blocks {
        for coder in &block.coders {
            check_7z_method(coder.encoder_method_id(), coder.properties(), limits)?;
        }
    }
    Ok(())
}

/// 7z 错误 → 中文文案
fn format_7z_error(err: &sevenz_rust2::Error) -> String {
    use sevenz_rust2::Error as E;
    match err {
        E::BadSignature(sig) => {
            format!("不是有效的 7z 文件（签名错误: {sig:02X?}）")
        }
        E::UnsupportedVersion { major, minor } => {
            format!("不支持的 7z 版本: {major}.{minor}")
        }
        E::ChecksumVerificationFailed | E::NextHeaderCrcMismatch => {
            "7z 文件校验失败（CRC 错误，文件可能损坏）".to_string()
        }
        E::Io(e, ctx) => {
            if ctx.is_empty() {
                format!("7z 读取失败: {e}")
            } else {
                format!("7z 读取失败: {e}（{ctx}）")
            }
        }
        E::FileOpen(e, path) => format!("无法打开7z文件: {e}（{path}）"),
        E::Other(s) => format!("7z 解析失败: {s}"),
        E::BadTerminatedStreamsInfo(v) => {
            format!("7z 文件结构损坏（streams info: {v}）")
        }
        E::BadTerminatedUnpackInfo => "7z 文件结构损坏（unpack info）".to_string(),
        E::BadTerminatedPackInfo(v) => {
            format!("7z 文件结构损坏（pack info: {v}）")
        }
        E::BadTerminatedSubStreamsInfo => "7z 文件结构损坏（sub streams info）".to_string(),
        E::BadTerminatedHeader(v) => format!("7z 文件结构损坏（header: {v}）"),
        E::ExternalUnsupported => "7z 使用了不支持的外部压缩方法".to_string(),
        E::UnsupportedCompressionMethod(m) => format!("不支持的 7z 压缩算法: {m}"),
        E::MaxMemLimited { max_kb, actaul_kb } => {
            format!("7z 解码内存超限（上限 {max_kb} KB，需要 {actaul_kb} KB）")
        }
        E::PasswordRequired => "暂不支持加密 7z（请先解密后再导入）".to_string(),
        E::Unsupported(s) => format!("当前不支持的 7z 特性: {s}"),
        E::MaybeBadPassword(e) => {
            format!("加密 7z 不支持（密码缺失或错误: {e}）")
        }
        E::FileNotFound => "7z 条目不存在".to_string(),
    }
}

/// 7z 错误 → 中文 `LegadoError::BookParse`
fn map_7z_error(err: sevenz_rust2::Error) -> LegadoError {
    LegadoError::BookParse(format_7z_error(&err))
}

/// 解压流读取错误 → 中文错误（`Crc32VerifyingReader` 等以 io::Error 包装 7z 错误）
fn map_7z_stream_error(err: std::io::Error, context: &str) -> LegadoError {
    if let Some(inner) = err.get_ref() {
        if let Some(sevenz_err) = inner.downcast_ref::<sevenz_rust2::Error>() {
            return LegadoError::BookParse(format!("{context}: {}", format_7z_error(sevenz_err)));
        }
    }
    LegadoError::BookParse(format!("{context}: {err}"))
}

/// 打开 7z（统一映射打开期错误）
fn open_7z_reader(path: &str) -> LegadoResult<sevenz_rust2::ArchiveReader<File>> {
    sevenz_rust2::ArchiveReader::open(path, sevenz_rust2::Password::empty()).map_err(map_7z_error)
}

/// 输出名去重是否折叠大小写
///
/// Windows（NTFS）、macOS（APFS 默认）与 iOS 的默认文件系统均大小写不敏感：
/// `A.txt` 与 `a.txt` 指向同一目录项，若不折叠会相互覆盖且列表返回重复路径。
/// Linux/Android 默认大小写敏感，保持原名。
const FOLD_OUTPUT_NAME_CASE: bool = cfg!(any(windows, target_os = "macos", target_os = "ios"));

/// 拆分文件名与扩展名（保留点号），用于 `name_2.ext` 命名
fn split_name_ext(base: &str) -> (&str, &str) {
    match base.rfind('.') {
        Some(idx) if idx > 0 => (&base[..idx], &base[idx..]),
        _ => (base, ""),
    }
}

/// 生成包内唯一的输出 basename
///
/// 首次出现原样返回；重名依次追加 `_2`/`_3`…（保留扩展名），避免同一包内
/// 多个同名条目在最终 rename 阶段互相覆盖（批24b P3-2，防数据丢失）。
///
/// `fold_case` 为真时按大小写不敏感比较（Windows/macOS/iOS），否则按原名精确
/// 比较；`next_seq` 缓存每个基名的下一个候选序号，避免重复线性扫描（批24c P3-5）。
fn dedupe_output_name(
    base: &str,
    used: &mut HashSet<String>,
    next_seq: &mut HashMap<String, usize>,
    fold_case: bool,
) -> String {
    let fold = |name: &str| {
        if fold_case {
            name.to_lowercase()
        } else {
            name.to_string()
        }
    };

    let base_key = fold(base);
    if used.insert(base_key.clone()) {
        next_seq.insert(base_key, 2);
        return base.to_string();
    }

    let (stem, ext) = split_name_ext(base);
    let seq = next_seq.entry(base_key).or_insert(2);
    loop {
        let candidate = format!("{stem}_{seq}{ext}");
        *seq += 1;
        if used.insert(fold(&candidate)) {
            return candidate;
        }
    }
}

/// 按 `archive.files` 文件序预计算书籍条目的输出名
///
/// 返回 `(与 files 索引对齐的输出名, basename → 文件序输出名队列)`。
/// `for_each_entries` 的访问顺序与文件序不同（有数据的条目先访问，零字节/无流
/// 条目最后统一访问）；若在解压回调里现场去重，同一 basename 的 `_2`/`_3` 归属
/// 会与列表不一致。解压时按 basename 队列取预计算结果，保证 list/import 输出名
/// 集合一致（重复项之间名称对应可互换，列表本就不区分同 basename 条目）。
fn plan_book_output_names(
    files: &[sevenz_rust2::ArchiveEntry],
    fold_case: bool,
) -> (Vec<Option<String>>, HashMap<String, VecDeque<String>>) {
    let mut used = HashSet::new();
    let mut next_seq = HashMap::new();
    let mut by_index = Vec::with_capacity(files.len());
    let mut by_base: HashMap<String, VecDeque<String>> = HashMap::new();
    for entry in files {
        let base = file_base_name(&entry.name);
        let is_book = !entry.is_directory && !base.starts_with('.') && is_book_file(base);
        if !is_book {
            by_index.push(None);
            continue;
        }
        let out_name = dedupe_output_name(base, &mut used, &mut next_seq, fold_case);
        by_base
            .entry(base.to_string())
            .or_default()
            .push_back(out_name.clone());
        by_index.push(Some(out_name));
    }
    (by_index, by_base)
}

/// 列出 7z 压缩包中的书籍文件名（不解压）
pub fn list_7z_book_files(seven_zip_path: &str) -> LegadoResult<Vec<String>> {
    list_7z_book_files_with_limits(seven_zip_path, &ArchiveLimits::default())
}

fn list_7z_book_files_with_limits(
    seven_zip_path: &str,
    limits: &ArchiveLimits,
) -> LegadoResult<Vec<String>> {
    precheck_7z_input(seven_zip_path, limits)?;
    let reader = open_7z_reader(seven_zip_path)?;
    check_7z_archive(reader.archive(), limits)?;

    // 与解压落盘使用同一套文件序去重规划，保证列表中的文件名可被选中导入
    let (planned, _) = plan_book_output_names(&reader.archive().files, FOLD_OUTPUT_NAME_CASE);
    Ok(planned.into_iter().flatten().collect())
}

/// 导入 7z 压缩包中的书籍文件
///
/// 解压后仅取书籍后缀条目，输出 basename 到 `output_dir`。
pub fn import_7z_file(seven_zip_path: &str, output_dir: &str) -> LegadoResult<Vec<String>> {
    import_7z_file_with_limits(seven_zip_path, output_dir, &ArchiveLimits::default())
}

fn import_7z_file_with_limits(
    seven_zip_path: &str,
    output_dir: &str,
    limits: &ArchiveLimits,
) -> LegadoResult<Vec<String>> {
    precheck_7z_input(seven_zip_path, limits)?;
    let mut reader = open_7z_reader(seven_zip_path)?;
    // 单线程：避免多线程 LZMA2 解码放大内存占用（限额已按单线程字典估算）
    reader.set_thread_count(1);
    check_7z_archive(reader.archive(), limits)?;

    fs::create_dir_all(output_dir)?;

    // 先写 `.part`，整包成功后再统一 rename：任一条目失败不触碰既有输出文件
    let mut pending: Vec<(PathBuf, PathBuf)> = Vec::new();
    let mut total_read: u64 = 0;
    let mut failure: Option<LegadoError> = None;
    let mut sequence: usize = 0;
    // 输出名按 archive.files 文件序预计算（解压回调的访问顺序与文件序不同）
    let (_, mut planned_names) =
        plan_book_output_names(&reader.archive().files, FOLD_OUTPUT_NAME_CASE);

    let result = reader.for_each_entries(|entry, stream| {
        let base = file_base_name(&entry.name);
        let is_book = !entry.is_directory && !base.starts_with('.') && is_book_file(base);

        // solid 7z 必须读尽每个条目（含非书籍条目）以触发 CRC；非书籍条目直接丢弃
        let mut chunk = [0u8; 64 * 1024];
        if !is_book {
            loop {
                let n = match stream.read(&mut chunk) {
                    Ok(n) => n,
                    Err(e) => {
                        failure = Some(map_7z_stream_error(
                            e,
                            &format!("读取7z条目失败 [{}]", entry.name),
                        ));
                        return Err(sevenz_rust2::Error::from(std::io::Error::other(
                            "legado:7z-read",
                        )));
                    }
                };
                if n == 0 {
                    break;
                }
                total_read = total_read.saturating_add(n as u64);
                if total_read > limits.max_total_size {
                    failure = Some(LegadoError::BookParse(format!(
                        "7z 解压总量超限（超过 {} 字节）",
                        limits.max_total_size
                    )));
                    return Err(sevenz_rust2::Error::from(std::io::Error::other(
                        "legado:7z-total-limit",
                    )));
                }
            }
            return Ok(true);
        }

        // 同名 basename 按序号去重（`novel.txt` / `novel_2.txt`），避免相互覆盖；
        // 具体名称取自文件序规划队列（见 `plan_book_output_names`）
        let Some(out_name) = planned_names.get_mut(base).and_then(VecDeque::pop_front) else {
            failure = Some(LegadoError::BookParse(format!(
                "7z 输出名规划缺失 [{base}]"
            )));
            return Err(sevenz_rust2::Error::from(std::io::Error::other(
                "legado:7z-plan",
            )));
        };
        let out_path = match safe_output_path(output_dir, &out_name) {
            Ok(path) => path,
            Err(e) => {
                failure = Some(e);
                return Err(sevenz_rust2::Error::from(std::io::Error::other(
                    "legado:7z-path",
                )));
            }
        };
        // 临时名带序号：解压期间互不覆盖，整包成功后再统一 rename
        let temp_path = out_path.with_file_name(format!(".legado_{sequence}.{out_name}.part"));
        sequence += 1;
        let _ = fs::remove_file(&temp_path);
        let mut out_file = match File::create(&temp_path) {
            Ok(file) => file,
            Err(e) => {
                failure = Some(LegadoError::BookParse(format!(
                    "创建7z输出文件失败 [{base}]: {e}"
                )));
                return Err(sevenz_rust2::Error::from(e));
            }
        };
        pending.push((temp_path, out_path));

        let mut entry_read: u64 = 0;
        loop {
            let n = match stream.read(&mut chunk) {
                Ok(n) => n,
                Err(e) => {
                    failure = Some(map_7z_stream_error(e, &format!("解压7z文件失败 [{base}]")));
                    return Err(sevenz_rust2::Error::from(std::io::Error::other(
                        "legado:7z-read",
                    )));
                }
            };
            if n == 0 {
                break;
            }
            entry_read = entry_read.saturating_add(n as u64);
            total_read = total_read.saturating_add(n as u64);
            if entry_read > limits.max_entry_size {
                failure = Some(LegadoError::BookParse(format!(
                    "7z 单条目超限 [{base}]（超过 {} 字节）",
                    limits.max_entry_size
                )));
                return Err(sevenz_rust2::Error::from(std::io::Error::other(
                    "legado:7z-entry-limit",
                )));
            }
            if total_read > limits.max_total_size {
                failure = Some(LegadoError::BookParse(format!(
                    "7z 解压总量超限（超过 {} 字节）",
                    limits.max_total_size
                )));
                return Err(sevenz_rust2::Error::from(std::io::Error::other(
                    "legado:7z-total-limit",
                )));
            }
            if let Err(e) = out_file.write_all(&chunk[..n]) {
                failure = Some(LegadoError::BookParse(format!(
                    "写入7z输出文件失败 [{base}]: {e}"
                )));
                return Err(sevenz_rust2::Error::from(e));
            }
        }
        if let Err(e) = out_file.flush() {
            failure = Some(LegadoError::BookParse(format!(
                "写入7z输出文件失败 [{base}]: {e}"
            )));
            return Err(sevenz_rust2::Error::from(e));
        }
        Ok(true)
    });

    if let Some(err) = failure {
        for (temp, _) in &pending {
            let _ = fs::remove_file(temp);
        }
        return Err(err);
    }
    if let Err(e) = result {
        for (temp, _) in &pending {
            let _ = fs::remove_file(temp);
        }
        return Err(map_7z_error(e));
    }

    // 整包读取成功后再落位；Windows rename 不覆盖既有目标，先删旧文件
    let mut extracted = Vec::with_capacity(pending.len());
    for (temp, out_path) in pending {
        #[cfg(windows)]
        {
            if out_path.exists() {
                if let Err(e) = fs::remove_file(&out_path) {
                    let _ = fs::remove_file(&temp);
                    return Err(LegadoError::BookParse(format!(
                        "覆盖既有7z输出文件失败 [{}]: {e}",
                        out_path.display()
                    )));
                }
            }
        }
        if let Err(e) = fs::rename(&temp, &out_path) {
            let _ = fs::remove_file(&temp);
            return Err(LegadoError::BookParse(format!(
                "写入7z输出文件失败 [{}]: {e}",
                out_path.display()
            )));
        }
        extracted.push(out_path.to_string_lossy().to_string());
    }

    Ok(extracted)
}

/// 判断文件是否为压缩包格式
pub fn is_archive_file(path: &str) -> bool {
    let lower = path.to_lowercase();
    lower.ends_with(".zip") || lower.ends_with(".rar") || lower.ends_with(".7z")
}

/// 构造安全的输出路径，防止路径穿越攻击
fn safe_output_path(output_dir: &str, file_name: &str) -> LegadoResult<PathBuf> {
    // 检查原始文件名是否包含路径穿越特征
    if file_name.contains("..") {
        return Err(LegadoError::BookParse(format!(
            "非法文件名（路径穿越）: {file_name}"
        )));
    }

    // 移除任何路径分隔符，仅保留文件名
    let sanitized = file_name.rsplit(['/', '\\']).next().unwrap_or(file_name);

    let out_dir = Path::new(output_dir);
    let out_path = out_dir.join(sanitized);

    // 验证最终路径在输出目录内
    if !out_path.starts_with(out_dir) {
        return Err(LegadoError::BookParse(format!(
            "输出路径越界: {}",
            out_path.display()
        )));
    }

    Ok(out_path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write as IoWrite;

    #[test]
    fn test_is_book_file() {
        assert!(is_book_file("novel.txt"));
        assert!(is_book_file("book.epub"));
        assert!(is_book_file("story.mobi"));
        assert!(is_book_file("doc.pdf"));
        assert!(is_book_file("book.umd"));
        assert!(is_book_file("kindle.azw3"));
        assert!(is_book_file("kindle.azw"));
        assert!(is_book_file("NOVEL.TXT"));
        assert!(is_book_file("Book.EPUB"));
        assert!(!is_book_file("readme.md"));
        assert!(!is_book_file("image.png"));
        assert!(!is_book_file("archive.zip"));
        assert!(!is_book_file("data.json"));
    }

    #[test]
    fn test_file_base_name() {
        assert_eq!(file_base_name("path/to/book.txt"), "book.txt");
        assert_eq!(file_base_name("path\\to\\book.txt"), "book.txt");
        assert_eq!(file_base_name("book.txt"), "book.txt");
        assert_eq!(file_base_name("dir/subdir/novel.epub"), "novel.epub");
    }

    #[test]
    fn test_is_archive_file() {
        assert!(is_archive_file("books.zip"));
        assert!(is_archive_file("books.rar"));
        assert!(is_archive_file("books.7z"));
        assert!(is_archive_file("BOOKS.ZIP"));
        assert!(!is_archive_file("book.txt"));
        assert!(!is_archive_file("book.epub"));
    }

    #[test]
    fn test_safe_output_path_normal() {
        let result = safe_output_path("/tmp/output", "book.txt").unwrap();
        assert_eq!(result, PathBuf::from("/tmp/output/book.txt"));
    }

    #[test]
    fn test_safe_output_path_strips_directory() {
        let result = safe_output_path("/tmp/output", "subdir/book.txt").unwrap();
        assert_eq!(result, PathBuf::from("/tmp/output/book.txt"));
    }

    #[test]
    fn test_safe_output_path_rejects_traversal() {
        let result = safe_output_path("/tmp/output", "../etc/passwd");
        assert!(result.is_err());
    }

    #[test]
    fn test_import_zip_file_basic() {
        // 创建一个临时 ZIP 文件用于测试
        let dir = std::env::temp_dir().join("legado_test_zip_import");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let zip_path = dir.join("test.zip");
        let output_dir = dir.join("output");

        // 创建包含书籍文件的 ZIP
        {
            let file = File::create(&zip_path).unwrap();
            let mut zip_writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();

            zip_writer.start_file("novel.txt", options).unwrap();
            zip_writer.write_all(b"Hello World").unwrap();

            zip_writer.start_file("subdir/book.epub", options).unwrap();
            zip_writer.write_all(b"EPUB content").unwrap();

            zip_writer.start_file("readme.md", options).unwrap();
            zip_writer.write_all(b"Not a book").unwrap();

            zip_writer.finish().unwrap();
        }

        // 执行导入
        let result =
            import_zip_file(zip_path.to_str().unwrap(), output_dir.to_str().unwrap()).unwrap();

        // 应只提取 .txt 和 .epub 文件
        assert_eq!(result.len(), 2);
        assert!(result.iter().any(|p| p.ends_with("novel.txt")));
        assert!(result.iter().any(|p| p.ends_with("book.epub")));

        // 验证文件内容
        let txt_content = fs::read_to_string(output_dir.join("novel.txt")).unwrap();
        assert_eq!(txt_content, "Hello World");

        // 清理
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_zip_file_not_found() {
        let result = import_zip_file("/nonexistent/path.zip", "/tmp/out");
        assert!(result.is_err());
    }

    #[test]
    fn test_list_zip_book_files() {
        let dir = std::env::temp_dir().join("legado_test_zip_list");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let zip_path = dir.join("test.zip");

        {
            let file = File::create(&zip_path).unwrap();
            let mut zip_writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();

            zip_writer.start_file("a.txt", options).unwrap();
            zip_writer.write_all(b"content").unwrap();
            zip_writer.start_file("b.epub", options).unwrap();
            zip_writer.write_all(b"content").unwrap();
            zip_writer.start_file("c.jpg", options).unwrap();
            zip_writer.write_all(b"content").unwrap();

            zip_writer.finish().unwrap();
        }

        let files = list_zip_book_files(zip_path.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 2);
        assert!(files.contains(&"a.txt".to_string()));
        assert!(files.contains(&"b.epub".to_string()));

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_zip_empty_archive() {
        let dir = std::env::temp_dir().join("legado_test_zip_empty");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let zip_path = dir.join("empty.zip");
        let output_dir = dir.join("output");

        {
            let file = File::create(&zip_path).unwrap();
            let zip_writer = zip::ZipWriter::new(file);
            zip_writer.finish().unwrap();
        }

        let result =
            import_zip_file(zip_path.to_str().unwrap(), output_dir.to_str().unwrap()).unwrap();
        assert!(result.is_empty());

        let _ = fs::remove_dir_all(&dir);
    }

    // ============================================================
    // 7z 导入测试（批24）
    // ============================================================

    use sevenz_rust2::{
        ArchiveEntry as SevenZEntry, ArchiveWriter, EncoderConfiguration, EncoderMethod,
        SourceReader,
    };
    use std::io::Cursor;

    /// 唯一临时目录（并发测试不撞名）
    fn unique_7z_dir(tag: &str) -> PathBuf {
        use std::sync::atomic::{AtomicU64, Ordering};
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let seq = COUNTER.fetch_add(1, Ordering::Relaxed);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let dir = std::env::temp_dir().join(format!(
            "legado_7z_{tag}_{}_{}_{}",
            std::process::id(),
            nanos,
            seq
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn lzma2_methods() -> Vec<EncoderConfiguration> {
        vec![EncoderConfiguration::new(EncoderMethod::LZMA2)]
    }

    /// 断言目录内无 `.part` 残留（失败回滚检查）
    fn assert_no_part_files(dir: &Path) {
        let parts: Vec<String> = fs::read_dir(dir)
            .map(|entries| {
                entries
                    .filter_map(|entry| entry.ok())
                    .map(|entry| entry.file_name().to_string_lossy().to_string())
                    .filter(|name| name.ends_with(".part"))
                    .collect()
            })
            .unwrap_or_default();
        assert!(parts.is_empty(), "失败回滚后残留 .part: {parts:?}");
    }

    /// 非 solid 7z 夹具
    fn create_test_7z(
        path: &Path,
        entries: &[(&str, &[u8])],
        methods: Vec<EncoderConfiguration>,
    ) -> PathBuf {
        let mut writer = ArchiveWriter::create(path).unwrap();
        writer.set_content_methods(methods);
        for (name, content) in entries {
            writer
                .push_archive_entry(SevenZEntry::new_file(name), Some(*content))
                .unwrap();
        }
        writer.finish().unwrap();
        path.to_path_buf()
    }

    /// 含「无流零字节」条目的 7z 夹具
    ///
    /// `for_each_entries` 先访问各压缩块内的条目，最后统一访问无流零字节条目；
    /// `None` 内容即生成无流条目，用于回归 list/import 去重命名一致性。
    fn create_test_7z_with_no_stream_entries(
        path: &Path,
        entries: &[(&str, Option<&[u8]>)],
        methods: Vec<EncoderConfiguration>,
    ) -> PathBuf {
        let mut writer = ArchiveWriter::create(path).unwrap();
        writer.set_content_methods(methods);
        for (name, content) in entries {
            match content {
                Some(bytes) => {
                    writer
                        .push_archive_entry(SevenZEntry::new_file(name), Some(*bytes))
                        .unwrap();
                }
                None => {
                    writer
                        .push_archive_entry::<Cursor<&[u8]>>(SevenZEntry::new_file(name), None)
                        .unwrap();
                }
            }
        }
        writer.finish().unwrap();
        path.to_path_buf()
    }

    /// solid 7z 夹具（所有条目共用一个压缩块，回归「非书籍条目必须 drain」）
    fn create_solid_test_7z(
        path: &Path,
        entries: &[(&str, &[u8])],
        methods: Vec<EncoderConfiguration>,
    ) -> PathBuf {
        let mut writer = ArchiveWriter::create(path).unwrap();
        writer.set_content_methods(methods);
        let archive_entries: Vec<SevenZEntry> = entries
            .iter()
            .map(|(name, _)| SevenZEntry::new_file(name))
            .collect();
        let readers: Vec<SourceReader<Cursor<Vec<u8>>>> = entries
            .iter()
            .map(|(_, content)| SourceReader::new(Cursor::new(content.to_vec())))
            .collect();
        writer
            .push_archive_entries(archive_entries, readers)
            .unwrap();
        writer.finish().unwrap();
        path.to_path_buf()
    }

    #[test]
    fn test_import_7z_lzma2_basic() {
        let dir = unique_7z_dir("lzma2");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[
                ("novel.txt", "Hello 7z World".as_bytes()),
                ("sub/book.epub", b"EPUB content"),
                ("readme.md", b"not a book"),
            ],
            lzma2_methods(),
        );
        let output = dir.join("out");

        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 2);
        assert!(output.join("novel.txt").exists());
        assert!(output.join("book.epub").exists());
        assert_eq!(
            fs::read_to_string(output.join("novel.txt")).unwrap(),
            "Hello 7z World"
        );
        assert!(!output.join("readme.md").exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_lzma_basic() {
        let dir = unique_7z_dir("lzma");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("novel.txt", "LZMA 内容".as_bytes())],
            vec![EncoderConfiguration::new(EncoderMethod::LZMA)],
        );
        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(
            fs::read_to_string(output.join("novel.txt")).unwrap(),
            "LZMA 内容"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_copy_basic() {
        let dir = unique_7z_dir("copy");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("novel.txt", b"COPY content")],
            vec![EncoderConfiguration::new(EncoderMethod::COPY)],
        );
        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(
            fs::read_to_string(output.join("novel.txt")).unwrap(),
            "COPY content"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_bcj_filter() {
        let dir = unique_7z_dir("bcj");
        let payload: Vec<u8> = (0..2048u32)
            .map(|i| if i % 5 == 0 { 0xE8 } else { (i % 251) as u8 })
            .collect();
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("novel.txt", payload.as_slice())],
            vec![
                EncoderConfiguration::new(EncoderMethod::BCJ_X86_FILTER),
                EncoderConfiguration::new(EncoderMethod::LZMA2),
            ],
        );
        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(fs::read(output.join("novel.txt")).unwrap(), payload);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_solid_mixed_entries() {
        let dir = unique_7z_dir("solid");
        let archive = create_solid_test_7z(
            &dir.join("books.7z"),
            &[
                ("notes.md", b"non-book payload that must be drained"),
                ("novel.txt", "solid 正文".as_bytes()),
                ("cover.png", b"\x89PNG\r\n\x1a\n"),
            ],
            lzma2_methods(),
        );
        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(
            fs::read_to_string(output.join("novel.txt")).unwrap(),
            "solid 正文"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_chinese_space_uppercase() {
        let dir = unique_7z_dir("names");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[
                ("中文 书名.TXT", "中文内容".as_bytes()),
                ("目录/Book.EPUB", b"EPUB"),
            ],
            lzma2_methods(),
        );
        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(
            fs::read_to_string(output.join("中文 书名.TXT")).unwrap(),
            "中文内容"
        );
        assert!(output.join("Book.EPUB").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_empty_archive() {
        let dir = unique_7z_dir("empty");
        let archive = create_test_7z(&dir.join("empty.7z"), &[], lzma2_methods());
        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert!(files.is_empty());
        assert!(output.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_list_7z_book_files() {
        let dir = unique_7z_dir("list");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[
                ("a.txt", b"a"),
                ("sub/b.epub", b"b"),
                ("c.jpg", b"c"),
                ("中文.txt", b"d"),
            ],
            lzma2_methods(),
        );
        let files = list_7z_book_files(archive.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 3);
        assert!(files.contains(&"a.txt".to_string()));
        assert!(files.contains(&"b.epub".to_string()));
        assert!(files.contains(&"中文.txt".to_string()));
        assert!(!files.contains(&"c.jpg".to_string()));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_rejects_traversal() {
        let dir = unique_7z_dir("traversal");
        let archive = create_test_7z(
            &dir.join("evil.7z"),
            &[("../evil.txt", b"evil")],
            lzma2_methods(),
        );
        let output = dir.join("out");
        let err = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("路径穿越"), "{err}");
        assert!(!dir.join("evil.txt").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_rejects_absolute_and_drive_paths() {
        let dir = unique_7z_dir("absolute");
        let absolute = create_test_7z(
            &dir.join("abs.7z"),
            &[("/tmp/evil.txt", b"evil")],
            lzma2_methods(),
        );
        let err = import_7z_file(
            absolute.to_str().unwrap(),
            dir.join("out1").to_str().unwrap(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("绝对路径"), "{err}");

        let drive = create_test_7z(
            &dir.join("drive.7z"),
            &[("C:\\evil.txt", b"evil")],
            lzma2_methods(),
        );
        let err = import_7z_file(drive.to_str().unwrap(), dir.join("out2").to_str().unwrap())
            .unwrap_err();
        assert!(err.to_string().contains("盘符路径"), "{err}");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_entry_count_limit() {
        let dir = unique_7z_dir("count");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("a.txt", b"a"), ("b.txt", b"b"), ("c.txt", b"c")],
            lzma2_methods(),
        );
        let limits = ArchiveLimits {
            max_entries: 2,
            ..ArchiveLimits::default()
        };
        let err = list_7z_book_files_with_limits(archive.to_str().unwrap(), &limits).unwrap_err();
        assert!(err.to_string().contains("条目数超限"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_entry_size_limit() {
        let dir = unique_7z_dir("entrysize");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("novel.txt", b"12345")],
            lzma2_methods(),
        );
        let limits = ArchiveLimits {
            max_entry_size: 4,
            ..ArchiveLimits::default()
        };
        let output = dir.join("out");
        fs::create_dir_all(&output).unwrap();
        fs::write(output.join("novel.txt"), b"keep existing").unwrap();
        let err = import_7z_file_with_limits(
            archive.to_str().unwrap(),
            output.to_str().unwrap(),
            &limits,
        )
        .unwrap_err();
        assert!(err.to_string().contains("单条目过大"), "{err}");
        // 失败回滚：既有输出文件不被触碰、无 .part、无半成品
        assert_eq!(
            fs::read(output.join("novel.txt")).unwrap(),
            b"keep existing"
        );
        assert_eq!(fs::read_dir(&output).unwrap().count(), 1);
        assert_no_part_files(&output);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_total_size_limit() {
        let dir = unique_7z_dir("totalsize");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("a.txt", b"123456"), ("b.txt", b"123456")],
            lzma2_methods(),
        );
        let limits = ArchiveLimits {
            max_total_size: 10,
            ..ArchiveLimits::default()
        };
        let output = dir.join("out");
        fs::create_dir_all(&output).unwrap();
        fs::write(output.join("a.txt"), b"keep existing").unwrap();
        let err = import_7z_file_with_limits(
            archive.to_str().unwrap(),
            output.to_str().unwrap(),
            &limits,
        )
        .unwrap_err();
        assert!(err.to_string().contains("解压总量超限"), "{err}");
        // 失败回滚：既有输出文件不被触碰、无 .part、无半成品
        assert_eq!(fs::read(output.join("a.txt")).unwrap(), b"keep existing");
        assert_eq!(fs::read_dir(&output).unwrap().count(), 1);
        assert_no_part_files(&output);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_dictionary_limit() {
        let dir = unique_7z_dir("dict");
        let mut options = sevenz_rust2::encoder_options::Lzma2Options::from_level(5);
        options.set_dictionary_size(1 << 20);
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("novel.txt", b"dictionary limit")],
            vec![options.into()],
        );
        let limits = ArchiveLimits {
            max_dict_size: 64 * 1024,
            ..ArchiveLimits::default()
        };
        let err = list_7z_book_files_with_limits(archive.to_str().unwrap(), &limits).unwrap_err();
        assert!(err.to_string().contains("字典超限"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    /// 内容加密 7z 夹具（header 明文，AES256-SHA256 + LZMA2，密码 "secret"）
    ///
    /// 由 sevenz-rust2 0.24 生成后内联，避免测试依赖 `aes256` feature
    /// （生产依赖保持 `default-features=false`，不引入重复 crypto 版本）。
    const ENCRYPTED_CONTENT_7Z: &[u8] = &[
        0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04, 0x63, 0x75, 0x68, 0xBB, 0x10, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x69, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x9A, 0x72,
        0x1D, 0xC0, 0x2E, 0x5C, 0x51, 0x2F, 0xD3, 0x5A, 0xCA, 0xDF, 0x39, 0xED, 0x87, 0x9F, 0x21,
        0xEE, 0x6E, 0xBB, 0x01, 0x04, 0x06, 0x00, 0x01, 0x09, 0x10, 0x0A, 0x01, 0xBE, 0x4F, 0x59,
        0x9F, 0x00, 0x07, 0x0B, 0x01, 0x00, 0x02, 0x24, 0x06, 0xF1, 0x07, 0x01, 0x22, 0xC8, 0xFF,
        0x4D, 0x57, 0x85, 0xA7, 0xDC, 0x5C, 0x73, 0x56, 0x92, 0x47, 0xB7, 0xFE, 0x2F, 0x70, 0x9A,
        0xD7, 0x6D, 0x6B, 0xC6, 0x0F, 0x91, 0x7E, 0xD8, 0x83, 0x96, 0x06, 0xFC, 0x7A, 0xF3, 0x65,
        0xDC, 0x38, 0x21, 0x21, 0x01, 0x16, 0x01, 0x00, 0x0C, 0x0A, 0x06, 0x00, 0x08, 0x0A, 0x01,
        0xE5, 0xE8, 0xA2, 0x5C, 0x00, 0x00, 0x05, 0x01, 0x11, 0x15, 0x00, 0x6E, 0x00, 0x6F, 0x00,
        0x76, 0x00, 0x65, 0x00, 0x6C, 0x00, 0x2E, 0x00, 0x74, 0x00, 0x78, 0x00, 0x74, 0x00, 0x00,
        0x00, 0x00, 0x00,
    ];

    #[test]
    fn test_import_7z_encrypted_content_rejected() {
        let dir = unique_7z_dir("encrypted");
        let path = dir.join("secret.7z");
        fs::write(&path, ENCRYPTED_CONTENT_7Z).unwrap();

        let err = list_7z_book_files(path.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("加密 7z"), "{err}");
        let err =
            import_7z_file(path.to_str().unwrap(), dir.join("out").to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("加密 7z"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_crc_corruption() {
        let dir = unique_7z_dir("crc");
        let path = dir.join("corrupt.7z");
        let content = vec![0x5Au8; 4096];
        create_test_7z(
            &path,
            &[("novel.txt", content.as_slice())],
            vec![EncoderConfiguration::new(EncoderMethod::COPY)],
        );
        let mut bytes = fs::read(&path).unwrap();
        // 签名头 32 字节之后即 packed stream；翻一个字节触发 CRC 校验失败
        assert!(bytes.len() > 64);
        bytes[40] ^= 0xFF;
        let corrupt = dir.join("corrupt2.7z");
        fs::write(&corrupt, &bytes).unwrap();

        let output = dir.join("out");
        fs::create_dir_all(&output).unwrap();
        fs::write(output.join("novel.txt"), b"keep existing").unwrap();
        let err = import_7z_file(corrupt.to_str().unwrap(), output.to_str().unwrap()).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("CRC") || msg.contains("校验"), "{msg}");
        // 失败回滚：既有输出文件不被触碰、无 .part、无半成品
        assert_eq!(
            fs::read(output.join("novel.txt")).unwrap(),
            b"keep existing"
        );
        assert_eq!(fs::read_dir(&output).unwrap().count(), 1);
        assert_no_part_files(&output);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_truncated_and_not_7z() {
        let dir = unique_7z_dir("truncated");
        let path = dir.join("books.7z");
        create_test_7z(&path, &[("novel.txt", b"truncate me")], lzma2_methods());
        let bytes = fs::read(&path).unwrap();
        let truncated = dir.join("truncated.7z");
        fs::write(&truncated, &bytes[..bytes.len() - 10]).unwrap();
        assert!(import_7z_file(
            truncated.to_str().unwrap(),
            dir.join("out1").to_str().unwrap()
        )
        .is_err());

        let not_7z = dir.join("fake.7z");
        fs::write(&not_7z, b"this is not a 7z archive").unwrap();
        let err = list_7z_book_files(not_7z.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("7z"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_overwrites_existing_output() {
        let dir = unique_7z_dir("overwrite");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("novel.txt", b"new content")],
            lzma2_methods(),
        );
        let output = dir.join("out");
        fs::create_dir_all(&output).unwrap();
        fs::write(output.join("novel.txt"), b"old content").unwrap();

        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 1);
        assert_eq!(
            fs::read_to_string(output.join("novel.txt")).unwrap(),
            "new content"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_multi_volume_rejected() {
        let dir = unique_7z_dir("volume");
        let path = dir.join("books.7z.001");
        fs::write(&path, b"7z\xBC\xAF\x27\x1C").unwrap();
        let err = list_7z_book_files(path.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("分卷"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_check_7z_method_unsupported_and_dict() {
        let limits = ArchiveLimits::default();
        let err = check_7z_method(EncoderMethod::ID_PPMD, &[], &limits).unwrap_err();
        assert!(err.to_string().contains("PPMd"), "{err}");
        let err = check_7z_method(EncoderMethod::ID_BZIP2, &[], &limits).unwrap_err();
        assert!(err.to_string().contains("BZip2"), "{err}");
        let err = check_7z_method(EncoderMethod::ID_AES256_SHA256, &[], &limits).unwrap_err();
        assert!(err.to_string().contains("加密"), "{err}");
        // LZMA props[1..5] = 256 MiB → 超过 128 MiB 默认上限
        let mut props = vec![0u8; 5];
        props[1..5].copy_from_slice(&(256u32 * 1024 * 1024).to_le_bytes());
        let err = check_7z_method(EncoderMethod::ID_LZMA, &props, &limits).unwrap_err();
        assert!(err.to_string().contains("字典超限"), "{err}");
        // LZMA2 p=31 → 192 MiB，超限；p=41 按无定义视为超限
        assert!(check_7z_method(EncoderMethod::ID_LZMA2, &[31], &limits).is_err());
        assert!(check_7z_method(EncoderMethod::ID_LZMA2, &[41], &limits).is_err());
        assert!(check_7z_method(EncoderMethod::ID_LZMA2, &[30], &limits).is_ok());
        assert!(check_7z_method(EncoderMethod::ID_COPY, &[], &limits).is_ok());
    }

    // ============================================================
    // 批24b：签名头预检（头解码 OOM 低成本缓解）
    // ============================================================

    /// 构造仅含 32 字节签名头的伪 7z（NextHeaderSize 可控）
    fn forged_7z_header(next_header_size: u64) -> Vec<u8> {
        let mut bytes = vec![0u8; SEVEN_Z_SIGNATURE_HEADER_SIZE];
        bytes[..SEVEN_Z_SIGNATURE.len()].copy_from_slice(&SEVEN_Z_SIGNATURE);
        bytes[6] = 0; // version major
        bytes[7] = 4; // version minor
        bytes[20..28].copy_from_slice(&next_header_size.to_le_bytes());
        bytes
    }

    #[test]
    fn test_precheck_7z_header_size_boundary() {
        let dir = unique_7z_dir("header-boundary");
        let at_limit = dir.join("at_limit.7z");
        fs::write(&at_limit, forged_7z_header(SEVEN_Z_MAX_HEADER_SIZE)).unwrap();
        assert!(precheck_7z_signature_header(at_limit.to_str().unwrap()).is_ok());

        let over_limit = dir.join("over_limit.7z");
        fs::write(&over_limit, forged_7z_header(SEVEN_Z_MAX_HEADER_SIZE + 1)).unwrap();
        let err = precheck_7z_signature_header(over_limit.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("头部过大"), "{err}");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_precheck_7z_header_rejects_bad_signature_and_short_file() {
        let dir = unique_7z_dir("header-bad");

        let bad_signature = dir.join("bad.7z");
        fs::write(&bad_signature, b"this is not a 7z archive").unwrap();
        let err = precheck_7z_signature_header(bad_signature.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("签名错误"), "{err}");

        let short = dir.join("short.7z");
        fs::write(&short, SEVEN_Z_SIGNATURE).unwrap();
        let err = precheck_7z_signature_header(short.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("头部不完整"), "{err}");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_rejects_oversized_header_before_open() {
        let dir = unique_7z_dir("header-oom");
        let path = dir.join("evil.7z");
        fs::write(&path, forged_7z_header(SEVEN_Z_MAX_HEADER_SIZE + 1)).unwrap();
        let output = dir.join("out");

        let err = list_7z_book_files(path.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("头部过大"), "{err}");

        let err = import_7z_file(path.to_str().unwrap(), output.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("头部过大"), "{err}");
        // 预检在创建输出目录之前完成，不产生任何落盘
        assert!(!output.exists());

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_same_basename_deduped() {
        let dir = unique_7z_dir("dedupe");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("a/novel.txt", b"first"), ("b/novel.txt", b"second")],
            lzma2_methods(),
        );

        let names = list_7z_book_files(archive.to_str().unwrap()).unwrap();
        assert_eq!(names, vec!["novel.txt", "novel_2.txt"]);

        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(
            fs::read_to_string(output.join("novel.txt")).unwrap(),
            "first"
        );
        assert_eq!(
            fs::read_to_string(output.join("novel_2.txt")).unwrap(),
            "second"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_dedupe_output_name_fold_case_policy() {
        // 折叠大小写（Windows/macOS/iOS）：A.txt 与 a.txt 视为同名
        let mut used = HashSet::new();
        let mut next_seq = HashMap::new();
        assert_eq!(
            dedupe_output_name("A.txt", &mut used, &mut next_seq, true),
            "A.txt"
        );
        assert_eq!(
            dedupe_output_name("a.txt", &mut used, &mut next_seq, true),
            "a_2.txt"
        );

        // 精确比较（Linux/Android）：大小写不同互不影响，原样保留
        let mut used = HashSet::new();
        let mut next_seq = HashMap::new();
        assert_eq!(
            dedupe_output_name("A.txt", &mut used, &mut next_seq, false),
            "A.txt"
        );
        assert_eq!(
            dedupe_output_name("a.txt", &mut used, &mut next_seq, false),
            "a.txt"
        );
    }

    #[test]
    fn test_dedupe_output_name_sequence_skips_real_names() {
        let mut used = HashSet::new();
        let mut next_seq = HashMap::new();
        assert_eq!(
            dedupe_output_name("n.txt", &mut used, &mut next_seq, false),
            "n.txt"
        );
        assert_eq!(
            dedupe_output_name("n.txt", &mut used, &mut next_seq, false),
            "n_2.txt"
        );
        assert_eq!(
            dedupe_output_name("n.txt", &mut used, &mut next_seq, false),
            "n_3.txt"
        );
        // 真实条目占用 `n_4.txt` 时跳过该序号（命名规则不变）
        assert_eq!(
            dedupe_output_name("n_4.txt", &mut used, &mut next_seq, false),
            "n_4.txt"
        );
        assert_eq!(
            dedupe_output_name("n.txt", &mut used, &mut next_seq, false),
            "n_5.txt"
        );
    }

    #[test]
    fn test_list_and_import_case_variant_names() {
        let dir = unique_7z_dir("case-name");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("A.txt", b"upper"), ("a.txt", b"lower")],
            lzma2_methods(),
        );

        let names = list_7z_book_files(archive.to_str().unwrap()).unwrap();
        if FOLD_OUTPUT_NAME_CASE {
            // Windows/macOS/iOS：大小写折叠，第二个条目落 `_2`
            assert_eq!(names, vec!["A.txt", "a_2.txt"]);
        } else {
            assert_eq!(names, vec!["A.txt", "a.txt"]);
        }

        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        let imported: Vec<String> = files
            .iter()
            .map(|path| file_base_name(path).to_string())
            .collect();
        assert_eq!(imported, names, "import 输出名须与 list 一致");
        assert_eq!(fs::read_dir(&output).unwrap().count(), 2);

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_import_7z_empty_and_nonempty_same_name() {
        let dir = unique_7z_dir("empty-same-name");
        // 文件序：无流零字节 a.txt、有流 a.txt、真实 a_2.txt。
        // `for_each_entries` 先访问有流条目、最后访问无流零字节条目；若在回调里
        // 现场去重，最后一个条目会得到列表外的 `a_3.txt`（而非 `a_2_2.txt`）。
        let archive = create_test_7z_with_no_stream_entries(
            &dir.join("books.7z"),
            &[
                ("a.txt", None),
                ("a.txt", Some(b"content")),
                ("a_2.txt", Some(b"real")),
            ],
            lzma2_methods(),
        );

        let names = list_7z_book_files(archive.to_str().unwrap()).unwrap();
        assert_eq!(names, vec!["a.txt", "a_2.txt", "a_2_2.txt"]);

        let output = dir.join("out");
        let files = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap();
        let mut imported: Vec<String> = files
            .iter()
            .map(|path| file_base_name(path).to_string())
            .collect();
        imported.sort();
        assert_eq!(imported, vec!["a.txt", "a_2.txt", "a_2_2.txt"]);
        // 名称集合与列表一致（非空条目优先进驻主名，零字节条目落 `_2`）
        assert_eq!(fs::read_to_string(output.join("a.txt")).unwrap(), "content");
        assert_eq!(fs::read(output.join("a_2.txt")).unwrap(), b"");
        assert_eq!(
            fs::read_to_string(output.join("a_2_2.txt")).unwrap(),
            "real"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(windows)]
    #[test]
    fn test_import_7z_rejects_windows_ads_name() {
        let dir = unique_7z_dir("ads");
        let archive = create_test_7z(
            &dir.join("books.7z"),
            &[("ab:cd.txt", b"ads payload")],
            lzma2_methods(),
        );

        let err = list_7z_book_files(archive.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("备用数据流"), "{err}");

        let output = dir.join("out");
        let err = import_7z_file(archive.to_str().unwrap(), output.to_str().unwrap()).unwrap_err();
        assert!(err.to_string().contains("备用数据流"), "{err}");
        // 条目名校验在创建输出目录之前完成，整包拒绝且不落盘
        assert!(!output.exists());

        let _ = fs::remove_dir_all(&dir);
    }
}
