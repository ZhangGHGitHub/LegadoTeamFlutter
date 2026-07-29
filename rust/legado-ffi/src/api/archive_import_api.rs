//! 压缩包导入与编码检测 FFI API
//!
//! 提供 ZIP/RAR 压缩包导入、TXT 编码检测与转换的 FFI 接口。
//! 对应 Kotlin 原版 `ArchiveUtils` + `LocalBook.importArchiveFile` 逻辑。

use serde::{Deserialize, Serialize};

use legado_book::archive;
use legado_book::encoding;
use legado_core::LegadoResult;

/// 压缩包导入结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ArchiveImportResult {
    /// 是否成功
    pub success: bool,
    /// 提取的书籍文件路径列表
    pub extracted_files: Vec<String>,
    /// 错误信息（失败时）
    pub error: Option<String>,
}

/// 编码检测结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EncodingResult {
    /// 检测到的编码名称
    pub encoding: String,
    /// 是否通过 BOM 确定
    pub has_bom: bool,
    /// 置信度（high/medium/low）
    pub confidence: String,
}

/// 编码转换结果
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConvertResult {
    /// 是否成功
    pub success: bool,
    /// 输出文件路径（成功时）
    pub output_path: Option<String>,
    /// 错误信息（失败时）
    pub error: Option<String>,
}

/// 导入 ZIP 压缩包中的书籍文件
///
/// 解压 ZIP 文件，提取其中的书籍文件（.txt/.epub/.mobi/.pdf/.umd/.azw3/.azw）
/// 到指定输出目录。
///
/// # 参数
/// - `zip_path`: ZIP 文件路径
/// - `output_dir`: 提取目标目录
pub fn import_zip_file(zip_path: &str, output_dir: &str) -> ArchiveImportResult {
    match archive::import_zip_file(zip_path, output_dir) {
        Ok(files) => ArchiveImportResult {
            success: true,
            extracted_files: files,
            error: None,
        },
        Err(e) => ArchiveImportResult {
            success: false,
            extracted_files: Vec::new(),
            error: Some(format!("ZIP导入失败: {e}")),
        },
    }
}

/// 导入 RAR 压缩包中的书籍文件
///
/// 解压 RAR 文件（支持加密），提取其中的书籍文件到指定输出目录。
///
/// # 参数
/// - `rar_path`: RAR 文件路径
/// - `output_dir`: 提取目标目录
/// - `password`: 可选密码（用于加密 RAR 文件）
pub fn import_rar_file(
    rar_path: &str,
    output_dir: &str,
    password: Option<String>,
) -> ArchiveImportResult {
    match archive::import_rar_file(rar_path, output_dir, password.as_deref()) {
        Ok(files) => ArchiveImportResult {
            success: true,
            extracted_files: files,
            error: None,
        },
        Err(e) => ArchiveImportResult {
            success: false,
            extracted_files: Vec::new(),
            error: Some(format!("RAR导入失败: {e}")),
        },
    }
}

/// 列出 ZIP 压缩包中的书籍文件名（不解压）
///
/// # 参数
/// - `zip_path`: ZIP 文件路径
pub fn list_zip_book_files(zip_path: &str) -> LegadoResult<Vec<String>> {
    archive::list_zip_book_files(zip_path)
}

/// 列出 RAR 压缩包中的书籍文件名（不解压）
///
/// # 参数
/// - `rar_path`: RAR 文件路径
/// - `password`: 可选密码
pub fn list_rar_book_files(rar_path: &str, password: Option<String>) -> LegadoResult<Vec<String>> {
    archive::list_rar_book_files(rar_path, password.as_deref())
}

/// 检测 TXT 文件编码
///
/// 读取文件前 1024 字节，通过 BOM 和统计特征判断编码。
/// 支持 UTF-8/GBK/GB18030/Big5/Shift-JIS/EUC-KR。
///
/// # 参数
/// - `file_path`: 待检测文件路径
pub fn detect_txt_encoding(file_path: &str) -> LegadoResult<EncodingResult> {
    let result = encoding::detect_encoding(file_path)?;
    Ok(EncodingResult {
        encoding: result.encoding,
        has_bom: result.has_bom,
        confidence: result.confidence.to_string(),
    })
}

/// 转换 TXT 文件编码
///
/// 将文件从源编码转换为目标编码，输出为新文件。
///
/// # 参数
/// - `file_path`: 源文件路径
/// - `from_encoding`: 源编码名称（如 "gbk", "big5"）
/// - `to_encoding`: 目标编码名称（通常为 "utf-8"）
pub fn convert_txt_encoding(
    file_path: &str,
    from_encoding: &str,
    to_encoding: &str,
) -> ConvertResult {
    match encoding::convert_file_encoding(file_path, from_encoding, to_encoding) {
        Ok(output_path) => ConvertResult {
            success: true,
            output_path: Some(output_path),
            error: None,
        },
        Err(e) => ConvertResult {
            success: false,
            output_path: None,
            error: Some(format!("编码转换失败: {e}")),
        },
    }
}

/// 判断文件是否为压缩包格式
///
/// # 参数
/// - `file_path`: 文件路径
pub fn is_archive_file(file_path: &str) -> bool {
    archive::is_archive_file(file_path)
}
