//! 压缩包导入模块
//!
//! 支持 ZIP/RAR 格式压缩包中书籍文件的识别与提取。
//! 对应 Kotlin 原版 `ArchiveUtils` + `LocalBook.importArchiveFile` 逻辑。
//!
//! 处理流程：
//! 1. 打开压缩包（ZIP 使用 `zip` crate，RAR 使用 `unrar` crate）
//! 2. 遍历压缩包条目，筛选书籍文件（.txt/.epub/.mobi/.pdf/.umd/.azw3/.azw）
//! 3. 提取书籍文件到指定输出目录
//! 4. 返回提取后的文件路径列表

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
                let (data, next_arc) = arc_with_file
                    .read()
                    .map_err(|e| LegadoError::BookParse(format!("解压RAR文件失败 [{base_name}]: {e}")))?;

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
        let entry = entry_result
            .map_err(|e| LegadoError::BookParse(format!("读取RAR目录失败: {e}")))?;

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
}
