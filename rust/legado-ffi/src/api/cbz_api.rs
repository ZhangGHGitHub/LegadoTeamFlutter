//! CBZ 本地漫画页读取 FFI API（cbz 批 B，E9 参考版扩展，用户已授权）
//!
//! 与 [`crate::api::archive_import_api`] 的分工：后者处理 ZIP/RAR **压缩容器**
//! 的书籍文件导入与编码检测；本模块服务 `LocalBook` → `CbzFile` 链路的
//! **漫画页字节读取**（`.cbz` 整包 = 一本漫画，见 API_CONTRACT §2.6 / §2.34）。
//! 独立成模块：一模块一职责（与既有 `image_api`/`txt_search_api` 同布局），
//! 且不触碰 archive 导入路径（零回归面）。
//!
//! 契约惯例：返回 JSON `{base64, len}`，与 `fetchImageWithDecode` 同形态。

use base64::Engine as _;
use legado_book::cbz::CbzFile;
use legado_core::{LegadoError, LegadoResult};
use serde::{Deserialize, Serialize};

use crate::db_state::resolve_local_book_path;

/// CBZ 漫画页读取结果（JSON 形态对齐 `fetchImageWithDecode` 的 `{base64,len}`）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CbzPageData {
    /// 图片原始字节的 base64（标准字母表，含 padding）
    pub base64: String,
    /// 图片原始字节数
    pub len: usize,
}

/// 读取 CBZ 漫画单页图片字节（返回 JSON `{base64, len}`）
///
/// - `path`：本地书 `bookUrl` 形态——绝对路径原样；相对可迁移标识经
///   [`resolve_local_book_path`] 解析（与阅读链路同语义）。
/// - `entry`：ZIP 条目名；兼容带 `cbz://` 伪 URL 前缀（`CbzFile::read_entry`
///   自动剥离），中文/空格条目名原样匹配，不做 URL 编解码。
///
/// 错误：文件不存在 / ZIP 解析失败 / 条目不存在 / 包内无图片条目。
pub fn cbz_read_page(path: &str, entry: &str) -> LegadoResult<String> {
    let real_path = resolve_local_book_path(path);
    let cbz = CbzFile::open(&real_path)?;
    // 「无图片条目」是无效漫画包（与 CbzFile::get_chapters 同口径，消息一致）
    if cbz.image_entries().is_empty() {
        return Err(LegadoError::BookParse(format!(
            "CBZ 内未找到图片条目: {real_path}"
        )));
    }
    let bytes = cbz.read_entry(entry)?;
    let data = CbzPageData {
        base64: base64::engine::general_purpose::STANDARD.encode(&bytes),
        len: bytes.len(),
    };
    Ok(serde_json::to_string(&data)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    /// 在临时目录中程序化造一个 CBZ，返回文件路径
    fn make_cbz(dir_name: &str, file_name: &str, entries: &[(&str, &[u8])]) -> String {
        let dir = std::env::temp_dir().join(dir_name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let cbz_path = dir.join(file_name);
        let file = fs::File::create(&cbz_path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();
        for (name, data) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(data).unwrap();
        }
        writer.finish().unwrap();
        cbz_path.to_string_lossy().into_owned()
    }

    fn decode(json: &str) -> (Vec<u8>, usize) {
        let v: serde_json::Value = serde_json::from_str(json).unwrap();
        let len = v["len"].as_u64().unwrap() as usize;
        let b64 = v["base64"].as_str().unwrap();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .unwrap();
        (bytes, len)
    }

    /// b) 字节正确 + 带/不带 `cbz://` 前缀等价 + 中文/空格条目名 + 非图片条目可读
    #[test]
    fn cbz_read_page_bytes_and_prefix_compat() {
        let path = make_cbz(
            "legado_test_cbz_api_basic",
            "本地 漫画.cbz",
            &[
                ("01 封面.jpg", b"cover-bytes"),
                ("page2.png", b"page-two"),
                ("readme.txt", b"not-an-image"),
            ],
        );

        // 带 cbz:// 前缀（getChapterContent 产出的伪 URL 形态）
        let with_prefix = cbz_read_page(&path, "cbz://01 封面.jpg").unwrap();
        let (bytes, len) = decode(&with_prefix);
        assert_eq!(bytes, b"cover-bytes");
        assert_eq!(len, bytes.len());
        assert_eq!(len, 11);

        // 不带前缀（原始条目名）等价
        let without_prefix = cbz_read_page(&path, "01 封面.jpg").unwrap();
        assert_eq!(with_prefix, without_prefix);

        // 第二页（自然排序第 2 项）字节正确
        let (bytes2, len2) = decode(&cbz_read_page(&path, "cbz://page2.png").unwrap());
        assert_eq!(bytes2, b"page-two");
        assert_eq!(len2, 8);

        let _ = fs::remove_dir_all(std::env::temp_dir().join("legado_test_cbz_api_basic"));
    }

    /// d) 错误路径：不存在文件 / 不存在条目 / 无图片条目 / 非法 ZIP
    #[test]
    fn cbz_read_page_error_paths() {
        // 文件不存在
        let missing =
            cbz_read_page("/nonexistent/legado_missing_comic.cbz", "cbz://a.jpg").unwrap_err();
        let msg = missing.to_string();
        assert!(msg.contains("无法打开CBZ文件"), "msg={msg}");

        // 条目不存在（带前缀形态）
        let path = make_cbz(
            "legado_test_cbz_api_errors",
            "comic.cbz",
            &[("page1.jpg", b"one")],
        );
        let entry_missing = cbz_read_page(&path, "cbz://page-does-not-exist.jpg").unwrap_err();
        assert!(
            entry_missing.to_string().contains("条目不存在"),
            "msg={entry_missing}"
        );

        // 包内无图片条目（即使请求的普通条目存在也须报「无图片」）
        let no_img = make_cbz(
            "legado_test_cbz_api_noimg",
            "not_comic.cbz",
            &[("readme.txt", b"hello"), ("meta/info.json", b"{}")],
        );
        let no_image = cbz_read_page(&no_img, "readme.txt").unwrap_err();
        assert!(
            no_image.to_string().contains("未找到图片条目"),
            "msg={no_image}"
        );

        // 非法 ZIP（非压缩包内容）
        let dir = std::env::temp_dir().join("legado_test_cbz_api_invalid");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let bad = dir.join("bad.cbz");
        fs::write(&bad, b"this is not a zip").unwrap();
        assert!(cbz_read_page(bad.to_str().unwrap(), "a.jpg").is_err());

        let _ = fs::remove_dir_all(std::env::temp_dir().join("legado_test_cbz_api_errors"));
        let _ = fs::remove_dir_all(std::env::temp_dir().join("legado_test_cbz_api_noimg"));
        let _ = fs::remove_dir_all(&dir);
    }
}
