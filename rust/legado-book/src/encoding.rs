//! 文本编码检测与转换模块
//!
//! 对应 Kotlin 原版中 TXT 文件导入时的自动编码识别逻辑。
//! 支持 UTF-8/GBK/GB18030/Big5/Shift-JIS/EUC-KR 等常见编码。
//!
//! 处理流程：
//! 1. 编码检测：读取文件前 1024 字节，通过 BOM 和统计特征判断编码
//! 2. 编码转换：将指定编码的文本转换为 UTF-8（或其他目标编码）
//! 3. 错误处理：转换失败时保留原始字节（以 replacement 字符标记）

use std::fs::{self, File};
use std::io::Read;
use std::path::Path;

use encoding_rs::{Encoding, GB18030, UTF_8};
use legado_core::{LegadoError, LegadoResult};

/// 编码检测结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncodingDetectResult {
    /// 检测到的编码名称（如 "utf-8", "gbk", "big5"）
    pub encoding: String,
    /// 是否通过 BOM 确定
    pub has_bom: bool,
    /// 置信度描述（high/medium/low）
    pub confidence: &'static str,
}

/// 检测文件编码
///
/// 读取文件前 1024 字节进行编码检测。
/// 检测优先级：BOM > UTF-8 验证 > 统计特征推断
///
/// # 参数
/// - `file_path`: 待检测文件路径
///
/// # 返回
/// 编码检测结果
pub fn detect_encoding(file_path: &str) -> LegadoResult<EncodingDetectResult> {
    let mut file = File::open(file_path)
        .map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;

    // 读取前 1024 字节用于检测
    let mut buf = [0u8; 1024];
    let n = file.read(&mut buf)?;
    let sample = &buf[..n];

    Ok(detect_encoding_from_bytes(sample))
}

/// 从字节数据检测编码（不依赖文件系统）
///
/// # 参数
/// - `data`: 待检测的字节切片
///
/// # 返回
/// 编码检测结果
pub fn detect_encoding_from_bytes(data: &[u8]) -> EncodingDetectResult {
    // 空数据默认 UTF-8
    if data.is_empty() {
        return EncodingDetectResult {
            encoding: "utf-8".to_string(),
            has_bom: false,
            confidence: "low",
        };
    }

    // 1. BOM 检测（最高优先级）
    if data.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return EncodingDetectResult {
            encoding: "utf-8".to_string(),
            has_bom: true,
            confidence: "high",
        };
    }
    if data.starts_with(&[0xFF, 0xFE, 0x00, 0x00]) {
        return EncodingDetectResult {
            encoding: "utf-32le".to_string(),
            has_bom: true,
            confidence: "high",
        };
    }
    if data.starts_with(&[0x00, 0x00, 0xFE, 0xFF]) {
        return EncodingDetectResult {
            encoding: "utf-32be".to_string(),
            has_bom: true,
            confidence: "high",
        };
    }
    if data.starts_with(&[0xFF, 0xFE]) {
        return EncodingDetectResult {
            encoding: "utf-16le".to_string(),
            has_bom: true,
            confidence: "high",
        };
    }
    if data.starts_with(&[0xFE, 0xFF]) {
        return EncodingDetectResult {
            encoding: "utf-16be".to_string(),
            has_bom: true,
            confidence: "high",
        };
    }

    // 2. 尝试 UTF-8 严格验证
    if std::str::from_utf8(data).is_ok() {
        return EncodingDetectResult {
            encoding: "utf-8".to_string(),
            has_bom: false,
            confidence: "high",
        };
    }

    // 3. 统计特征推断：尝试各编码解码，选择无错误且高字节比例合理的
    // 优先检测 GB18030（兼容 GBK），因为中文环境最常见
    let candidates: &[(&str, &Encoding)] = &[
        ("gb18030", GB18030),
        ("big5", encoding_rs::BIG5),
        ("shift_jis", encoding_rs::SHIFT_JIS),
        ("euc-kr", encoding_rs::EUC_KR),
    ];

    for (name, enc) in candidates {
        let (_, _, had_errors) = enc.decode(data);
        if !had_errors {
            return EncodingDetectResult {
                encoding: name.to_string(),
                has_bom: false,
                confidence: "medium",
            };
        }
    }

    // 4. 默认回退到 UTF-8（低置信度）
    EncodingDetectResult {
        encoding: "utf-8".to_string(),
        has_bom: false,
        confidence: "low",
    }
}

/// 转换文件编码
///
/// 将文件从源编码转换为目标编码，结果写入新文件（原文件名加 `.converted` 后缀）。
/// 若转换失败，保留原始字节不做修改。
///
/// # 参数
/// - `file_path`: 源文件路径
/// - `from_encoding`: 源编码名称（如 "gbk", "big5", "utf-8"）
/// - `to_encoding`: 目标编码名称（通常为 "utf-8"）
///
/// # 返回
/// 转换后的输出文件路径
pub fn convert_file_encoding(
    file_path: &str,
    from_encoding: &str,
    to_encoding: &str,
) -> LegadoResult<String> {
    let source_enc = Encoding::for_label(from_encoding.as_bytes())
        .ok_or_else(|| LegadoError::BookParse(format!("不支持的源编码: {from_encoding}")))?;

    let target_enc = Encoding::for_label(to_encoding.as_bytes())
        .ok_or_else(|| LegadoError::BookParse(format!("不支持的目标编码: {to_encoding}")))?;

    // 读取源文件
    let raw_bytes = fs::read(file_path)?;

    // 跳过 BOM（如有）
    let skip = detect_bom_length(&raw_bytes);
    let content_bytes = &raw_bytes[skip..];

    // 解码为 Unicode 字符串
    let (decoded, _, had_errors) = source_enc.decode(content_bytes);
    if had_errors {
        return Err(LegadoError::BookParse(format!(
            "编码转换失败：源文件包含无法以 {from_encoding} 解码的字节"
        )));
    }

    // 编码为目标格式
    let (encoded, _, enc_errors) = target_enc.encode(&decoded);
    if enc_errors {
        return Err(LegadoError::BookParse(format!(
            "编码转换失败：文本包含无法以 {to_encoding} 编码的字符"
        )));
    }

    // 构造输出路径
    let path = Path::new(file_path);
    let out_path = path.with_extension(format!(
        "{}.converted",
        path.extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_default()
    ));

    fs::write(&out_path, &*encoded)?;

    Ok(out_path.to_string_lossy().to_string())
}

/// 将字节数据从指定编码解码为 UTF-8 字符串
///
/// # 参数
/// - `data`: 原始字节数据
/// - `encoding_name`: 编码名称
///
/// # 返回
/// 解码后的 UTF-8 字符串
pub fn decode_to_utf8(data: &[u8], encoding_name: &str) -> String {
    let enc = Encoding::for_label(encoding_name.as_bytes()).unwrap_or(UTF_8);

    // 跳过 BOM
    let skip = detect_bom_length(data);
    let content = &data[skip..];

    let (cow, _, _) = enc.decode(content);
    cow.into_owned()
}

/// 检测 BOM 长度
fn detect_bom_length(data: &[u8]) -> usize {
    if data.starts_with(&[0xEF, 0xBB, 0xBF]) {
        3 // UTF-8 BOM
    } else if data.starts_with(&[0xFF, 0xFE, 0x00, 0x00])
        || data.starts_with(&[0x00, 0x00, 0xFE, 0xFF])
    {
        4 // UTF-32 BOM
    } else if data.starts_with(&[0xFF, 0xFE]) || data.starts_with(&[0xFE, 0xFF]) {
        2 // UTF-16 BOM
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn test_detect_utf8_bom() {
        let mut data = vec![0xEF, 0xBB, 0xBF];
        data.extend_from_slice("Hello".as_bytes());
        let result = detect_encoding_from_bytes(&data);
        assert_eq!(result.encoding, "utf-8");
        assert!(result.has_bom);
        assert_eq!(result.confidence, "high");
    }

    #[test]
    fn test_detect_utf16le_bom() {
        let data = [0xFF, 0xFE, 0x48, 0x00];
        let result = detect_encoding_from_bytes(&data);
        assert_eq!(result.encoding, "utf-16le");
        assert!(result.has_bom);
    }

    #[test]
    fn test_detect_utf16be_bom() {
        let data = [0xFE, 0xFF, 0x00, 0x48];
        let result = detect_encoding_from_bytes(&data);
        assert_eq!(result.encoding, "utf-16be");
        assert!(result.has_bom);
    }

    #[test]
    fn test_detect_plain_utf8() {
        let data = "Hello World 你好世界".as_bytes();
        let result = detect_encoding_from_bytes(data);
        assert_eq!(result.encoding, "utf-8");
        assert!(!result.has_bom);
        assert_eq!(result.confidence, "high");
    }

    #[test]
    fn test_detect_gbk_encoding() {
        // GBK 编码的 "你好" = [0xC4, 0xE3, 0xBA, 0xC3]
        let data = [0xC4, 0xE3, 0xBA, 0xC3];
        let result = detect_encoding_from_bytes(&data);
        // GBK 字节在 GB18030 下也能正确解码
        assert_eq!(result.encoding, "gb18030");
        assert_eq!(result.confidence, "medium");
    }

    #[test]
    fn test_detect_empty_data() {
        let result = detect_encoding_from_bytes(&[]);
        assert_eq!(result.encoding, "utf-8");
        assert_eq!(result.confidence, "low");
    }

    #[test]
    fn test_decode_to_utf8_from_gbk() {
        // GBK "你好" 字节
        let gbk_bytes = [0xC4, 0xE3, 0xBA, 0xC3];
        let result = decode_to_utf8(&gbk_bytes, "gbk");
        assert_eq!(result, "你好");
    }

    #[test]
    fn test_decode_to_utf8_with_bom() {
        let mut data = vec![0xEF, 0xBB, 0xBF];
        data.extend_from_slice("BOM test".as_bytes());
        let result = decode_to_utf8(&data, "utf-8");
        assert_eq!(result, "BOM test");
    }

    #[test]
    fn test_decode_to_utf8_unknown_encoding_fallback() {
        let data = b"Hello";
        let result = decode_to_utf8(data, "nonexistent-encoding");
        // 未知编码回退到 UTF-8
        assert_eq!(result, "Hello");
    }

    #[test]
    fn test_detect_bom_length() {
        assert_eq!(detect_bom_length(&[0xEF, 0xBB, 0xBF, 0x41]), 3);
        assert_eq!(detect_bom_length(&[0xFF, 0xFE, 0x41, 0x00]), 2);
        assert_eq!(detect_bom_length(&[0xFE, 0xFF, 0x00, 0x41]), 2);
        assert_eq!(detect_bom_length(&[0xFF, 0xFE, 0x00, 0x00]), 4);
        assert_eq!(detect_bom_length(&[0x00, 0x00, 0xFE, 0xFF]), 4);
        assert_eq!(detect_bom_length(&[0x41, 0x42]), 0);
    }

    #[test]
    fn test_convert_file_encoding_gbk_to_utf8() {
        let dir = std::env::temp_dir().join("legado_test_encoding_convert");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let src_path = dir.join("test.txt");
        // 写入 GBK 编码的 "你好世界"
        let gbk_bytes = [0xC4, 0xE3, 0xBA, 0xC3, 0xCA, 0xC0, 0xBD, 0xE7];
        {
            let mut f = File::create(&src_path).unwrap();
            f.write_all(&gbk_bytes).unwrap();
        }

        let out_path = convert_file_encoding(
            src_path.to_str().unwrap(),
            "gbk",
            "utf-8",
        )
        .unwrap();

        // 验证输出文件内容
        let content = fs::read_to_string(&out_path).unwrap();
        assert_eq!(content, "你好世界");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_convert_file_encoding_unsupported_source() {
        let result = convert_file_encoding("/tmp/test.txt", "fake-encoding", "utf-8");
        assert!(result.is_err());
    }

    #[test]
    fn test_convert_file_encoding_unsupported_target() {
        let result = convert_file_encoding("/tmp/test.txt", "utf-8", "fake-encoding");
        assert!(result.is_err());
    }

    #[test]
    fn test_detect_encoding_from_file() {
        let dir = std::env::temp_dir().join("legado_test_encoding_detect");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let file_path = dir.join("utf8.txt");
        {
            let mut f = File::create(&file_path).unwrap();
            f.write_all("Hello UTF-8 内容".as_bytes()).unwrap();
        }

        let result = detect_encoding(file_path.to_str().unwrap()).unwrap();
        assert_eq!(result.encoding, "utf-8");
        assert_eq!(result.confidence, "high");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_detect_encoding_file_not_found() {
        let result = detect_encoding("/nonexistent/file.txt");
        assert!(result.is_err());
    }
}
