//! 压缩包导入与编码检测 FFI API
//!
//! 提供 ZIP/RAR/7z 压缩包导入、TXT 编码检测与转换的 FFI 接口。
//! 对应 Kotlin 原版 `ArchiveUtils` + `LocalBook.importArchiveFile` 逻辑。

use serde::{Deserialize, Serialize};

use legado_book::archive;
use legado_book::encoding;
use legado_core::{LegadoError, LegadoResult};

/// 取 `LegadoError` 的内层文案（避免 `Book parsing error:` 前缀被重复包装）
fn inner_error_message(err: &LegadoError) -> String {
    match err {
        LegadoError::BookParse(message) => message.clone(),
        other => other.to_string(),
    }
}

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
/// [批32] 与 7z 同口径限额与路径安全（fail-closed）：输入 512 MiB /
/// 单条目 256 MiB / 总量 512 MiB / 条目数 10000；声明值与实际读取字节
/// 双计数；任一不安全条目名整包拒绝；先写 `.part`，失败清理临时文件。
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
/// [批32] 与 zip/7z 同口径限额与路径安全（fail-closed）；Android/iOS 仍为
/// 明确不支持（不做伪解压）。
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

/// 导入 7z 压缩包中的书籍文件（§2.34 批24）
///
/// 解压 7z 文件，提取其中的书籍文件到指定输出目录。
/// 不支持加密 7z / 分卷 / PPMd 等算法；限额与路径安全见
/// `legado_book::archive`（输入 512 MiB / 单条目 256 MiB / 总量 512 MiB /
/// 条目数 10000 / 字典 128 MiB）。
///
/// # 参数
/// - `seven_zip_path`: 7z 文件路径
/// - `output_dir`: 提取目标目录
pub fn import_7z_file(seven_zip_path: &str, output_dir: &str) -> ArchiveImportResult {
    match archive::import_7z_file(seven_zip_path, output_dir) {
        Ok(files) => ArchiveImportResult {
            success: true,
            extracted_files: files,
            error: None,
        },
        Err(e) => ArchiveImportResult {
            success: false,
            extracted_files: Vec::new(),
            error: Some(format!("7z导入失败: {}", inner_error_message(&e))),
        },
    }
}

/// 列出 7z 压缩包中的书籍文件名（不解压，§2.34 批24）
///
/// 契约 §2.34：本方法失败时抛 `BridgeError`（外层消息带 `Book parsing error:`
/// 前缀，内层为 `7z列表失败: …`），与 `archiveImport7z` 的信封返回不同。
///
/// # 参数
/// - `seven_zip_path`: 7z 文件路径
pub fn list_7z_book_files(seven_zip_path: &str) -> LegadoResult<Vec<String>> {
    archive::list_7z_book_files(seven_zip_path)
        .map_err(|e| LegadoError::BookParse(format!("7z列表失败: {}", inner_error_message(&e))))
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::book_import::import_local_book;
    use crate::db_state::{ensure_test_db, with_database};
    use legado_db::BookRepository;

    /// [回归] 批28 回修暴露的用户可见缺陷：压缩包导入选择「编码转换」后，
    /// 导入链拿转换产物路径建书，书名取 `file_stem()`——历史产物名
    /// `foo.txt.converted` 的 stem 是 `foo.txt`，书架书名被污染成 `foo.txt`。
    ///
    /// 端到端断言：转换 → 用 `output_path` 导入 → 书名恰为 `foo`（不含扩展名），
    /// 且转换产物位于同目录 `converted/` 子目录、文件名与原文件一致。
    /// 修复前该用例变红（导入成功但书名为 `foo.txt`）。
    #[test]
    fn test_converted_txt_import_keeps_clean_book_name() {
        let _db_guard = ensure_test_db();

        // 模拟 archive_import 解压目录：书籍文件直接落在输出目录根部
        let dir = std::env::temp_dir().join(format!(
            "legado_test_archive_convert_import_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let src_path = dir.join("foo.txt");
        // GBK 编码的「你好世界你好世界」（16 字节，满足魔数探测的 8 字节读取）
        std::fs::write(
            &src_path,
            [
                0xC4u8, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7, 0xC4, 0xE3, 0xBA, 0xC3, 0xCA,
                0xC0, 0xBD, 0xE7,
            ],
        )
        .unwrap();

        let converted = convert_txt_encoding(src_path.to_str().unwrap(), "gbk", "utf-8");
        assert!(converted.success, "转换失败: {:?}", converted.error);
        let out_path = converted.output_path.expect("成功时必须返回 output_path");

        assert_eq!(
            std::path::Path::new(&out_path)
                .file_stem()
                .map(|s| s.to_string_lossy().to_string()),
            Some("foo".to_string()),
            "转换产物的 file_stem 必须与原文件一致: {out_path}"
        );

        let res = import_local_book(&out_path).unwrap();
        assert!(res.success, "导入失败: {:?}", res.error);
        let book = res.book.expect("成功时应有 book");
        assert_eq!(book.name, "foo", "书名取 file_stem，不得带 .txt 扩展名");
        assert!(
            !book.name.contains(".txt"),
            "书名不得被转换产物命名污染: {}",
            book.name
        );
        assert_eq!(book.book_url, out_path, "book_url 应为传入的产物路径");

        with_database(|db| BookRepository::new(db.connection()).delete_by_url(&out_path)).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
