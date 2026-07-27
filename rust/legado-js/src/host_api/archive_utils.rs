//! 解压缩宿主 API
//!
//! 对应 Kotlin `ArchiveUtils.kt`，提供 ZIP / 7z / RAR 解压能力。
//! - ZIP：使用 `zip` crate 完整实现
//! - 7z / RAR：Rust 生态暂无稳定方案，桩化返回错误

use std::fs;
use std::io::Read;
use std::path::Path;

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

    fs::create_dir_all(&out_dir).map_err(|e| format!("Failed to create output dir: {e}"))?;

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
            fs::create_dir_all(&target)
                .map_err(|e| format!("Failed to create dir {}: {e}", target.display()))?;
        } else {
            // 确保父目录存在
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create dir {}: {e}", parent.display()))?;
            }
            let mut buf = Vec::new();
            entry
                .read_to_end(&mut buf)
                .map_err(|e| format!("Failed to read entry {}: {e}", entry_name.display()))?;
            fs::write(&target, &buf)
                .map_err(|e| format!("Failed to write {}: {e}", target.display()))?;
        }
    }

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

    let mut buf = Vec::new();
    entry
        .read_to_end(&mut buf)
        .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"))?;

    Ok(buf)
}

/// un7zFile(7zPath, outputPath?) — 解压 7z 文件
///
/// 当前 Rust 生态中 sevenz-rust 尚不够成熟，桩化返回错误。
pub fn un7z_file(_seven_z_path: &str, _output_path: Option<&str>) -> Result<String, String> {
    Err("[ERROR] 7z decompression not supported in Rust runtime".to_string())
}

/// unrarFile(rarPath, outputPath?) — 解压 RAR 文件
///
/// 当前 Rust 生态中 unrar 绑定不够成熟，桩化返回错误。
pub fn unrar_file(_rar_path: &str, _output_path: Option<&str>) -> Result<String, String> {
    Err("[ERROR] RAR decompression not supported in Rust runtime".to_string())
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
fn read_file_magic(path: &str) -> Result<String, String> {
    let data = fs::read(path).map_err(|e| format!("Failed to read file '{path}': {e}"))?;
    if data.len() >= 4 {
        if &data[0..2] == b"PK" {
            return Ok("PK".to_string());
        }
        if &data[0..2] == b"7z" {
            return Ok("7z".to_string());
        }
        if &data[0..4] == b"Rar!" {
            return Ok("Rar".to_string());
        }
    } else if data.len() >= 2 {
        if &data[0..2] == b"PK" {
            return Ok("PK".to_string());
        }
        if &data[0..2] == b"7z" {
            return Ok("7z".to_string());
        }
    }
    Ok("unknown".to_string())
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

    /// 简单 UUID（避免测试依赖 uuid crate feature）
    fn uuid() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        format!("{:x}{:x}", std::process::id(), nanos)
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
    fn test_un7z_file_stub() {
        let result = un7z_file("some.7z", None);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("7z decompression not supported"));
    }

    #[test]
    fn test_unrar_file_stub() {
        let result = unrar_file("some.rar", None);
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .contains("RAR decompression not supported"));
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
        fs::write(&file_path, &[0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]).unwrap();

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
}
