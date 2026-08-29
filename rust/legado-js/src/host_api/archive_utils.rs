//! 解压缩宿主 API
//!
//! 对应 Kotlin `ArchiveUtils.kt`，提供 ZIP / 7z / RAR 解压能力。
//! - ZIP：使用 `zip` crate 完整实现
//! - 7z：使用 `sevenz-rust2` crate 纯 Rust 实现（需 quickjs feature）
//! - RAR：使用 `rar` crate 纯 Rust 实现（RAR4/RAR5，含加密档案；需 quickjs feature）

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

    let mut buf = Vec::new();
    entry
        .read_to_end(&mut buf)
        .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"))?;

    Ok(buf)
}

/// un7zFile(7zPath, outputPath?) — 解压 7z 文件
///
/// 使用 `sevenz-rust2` 纯 Rust 实现解压 7z 格式文件。
/// 支持 LZMA/LZMA2/COPY 等编解码器。
/// 返回解压目标目录路径。
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

    sevenz_rust2::decompress_file(src, &out_dir)
        .map_err(|e| format!("7z decompression failed: {e}"))?;

    Ok(out_dir)
}

/// un7zFile — 无 quickjs feature 时的回退桩
#[cfg(not(feature = "quickjs"))]
pub fn un7z_file(_seven_z_path: &str, _output_path: Option<&str>) -> Result<String, String> {
    Err("[ERROR] 7z decompression requires 'quickjs' feature (sevenz-rust2)".to_string())
}

/// unrarFile(rarPath, outputPath?) — 解压 RAR 文件
///
/// 使用 `rar` crate 纯 Rust 实现（RAR4/RAR5 全压缩级别 + 加密档案，无 C 依赖）。
/// 返回解压目标目录路径。
///
/// Kotlin 原版走 libarchive（`ArchiveUtils.deCompress`），此处以纯 Rust 方案对等替代。
#[cfg(feature = "quickjs")]
pub fn unrar_file(rar_path: &str, output_path: Option<&str>) -> Result<String, String> {
    let src = Path::new(rar_path);
    if !src.exists() {
        return Err(format!("RAR file not found: {}", src.display()));
    }

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
    let mut reader = sevenz_rust2::SevenZReader::new(cursor, sevenz_rust2::Password::empty())
        .map_err(|e| format!("Invalid 7z archive: {e}"))?;
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
#[cfg(feature = "quickjs")]
pub fn rar_entry_bytes(rar_bytes: &[u8], entry_name: &str) -> Result<Vec<u8>, String> {
    use std::time::{SystemTime, UNIX_EPOCH};

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

        // 条目路径兼容：先按原样查找，再尝试反斜杠归一化（RAR 内路径分隔符可能为 \）
        let target = out_dir.join(entry_name);
        if target.is_file() {
            return fs::read(&target)
                .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"));
        }
        let normalized = entry_name.replace('\\', "/");
        if normalized != entry_name {
            let target = out_dir.join(&normalized);
            if target.is_file() {
                return fs::read(&target)
                    .map_err(|e| format!("Failed to read entry '{entry_name}': {e}"));
            }
        }
        Err(format!("Entry '{entry_name}' not found in RAR"))
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

    // ============================================================
    // 7z 解压测试（需要 quickjs feature 启用 sevenz-rust2）
    // ============================================================

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
}
