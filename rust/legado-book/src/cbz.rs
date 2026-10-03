//! CBZ 漫画格式解析模块
//!
//! CBZ 本质是 ZIP 压缩包，内部按顺序存放漫画图片页。
//! 与 `.zip` 的双语义约定：扩展名为 `.cbz` 时整包视为一本漫画（本模块）；
//! `.zip` 仍保持压缩容器行为（`archive` 模块负责其中的书籍文件导入）。
//!
//! 映射约定（对齐参考版扩展）：
//! - 整包 = 一本漫画
//! - 目录 = 单章（首期不做多章分组），章节 `url` 置空，供漫画屏走本地 `getChapterContent` 分支
//! - 正文 = ZIP 内图片条目名列表，按 `cbz://<条目名>` 伪 URL 逐行返回，供 Dart 行式解析
//!
//! 图片后缀白名单：jpg/jpeg/png/webp/gif/bmp；忽略目录项与非图片条目。
//! 条目名可能包含空格/中文，伪 URL 直接原样输出，不做 URL 编码。

use std::cmp::Ordering;
use std::fs::File;
use std::io::Read;
use std::path::Path;

use zip::ZipArchive;

use legado_core::{LegadoError, LegadoResult};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// 支持的图片扩展名白名单（小写，含点）
pub const IMAGE_EXTENSIONS: &[&str] = &[".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp"];

/// 漫画正文行的伪 URL 前缀（与参考版 `cbz://` 形态对齐）
pub const CBZ_URL_SCHEME: &str = "cbz://";

/// CBZ 漫画文件
///
/// `open` 时一次性列举并排序图片条目，后续查询不再重复扫描目录。
#[derive(Debug, Clone)]
pub struct CbzFile {
    path: String,
    title: String,
    images: Vec<String>,
}

impl CbzFile {
    /// 打开 CBZ 文件并列举图片条目（自然排序，忽略目录项与非图片条目）
    pub fn open(path: &str) -> LegadoResult<Self> {
        let mut archive = open_archive(path)?;
        let mut images = Vec::new();
        for i in 0..archive.len() {
            let entry = archive
                .by_index(i)
                .map_err(|e| LegadoError::BookParse(format!("读取CBZ条目失败: {e}")))?;
            if entry.is_dir() {
                continue;
            }
            let name = entry.name();
            if is_image_entry(name) {
                images.push(name.to_string());
            }
        }
        images.sort_by(|a, b| natural_cmp(a, b));
        Ok(Self {
            path: path.to_string(),
            title: book_title(path),
            images,
        })
    }

    /// 元数据：书名 = 文件名去扩展名，作者为空
    pub fn metadata(&self) -> LegadoResult<BookMetadata> {
        Ok(BookMetadata {
            title: self.title.clone(),
            author: String::new(),
            description: String::new(),
            format: BookFormat::Cbz,
            cover: None,
        })
    }

    /// 章节列表：整包固定 1 章（index 0），`url` 置空
    ///
    /// ZIP 内无图片条目时报错（不是有效漫画包）。
    pub fn get_chapters(&self) -> LegadoResult<Vec<ChapterInfo>> {
        if self.images.is_empty() {
            return Err(no_image_error(&self.path));
        }
        Ok(vec![ChapterInfo {
            url: String::new(),
            title: self.title.clone(),
            index: 0,
            is_volume: false,
            start: None,
            end: None,
        }])
    }

    /// 章节正文：`index == 0` 返回 `cbz://<条目名>` 行分隔列表
    pub fn get_chapter_content(&self, index: i32) -> LegadoResult<String> {
        if index != 0 {
            return Err(LegadoError::BookParse(format!("CBZ 章节索引越界: {index}")));
        }
        if self.images.is_empty() {
            return Err(no_image_error(&self.path));
        }
        Ok(self
            .images
            .iter()
            .map(|name| format!("{CBZ_URL_SCHEME}{name}"))
            .collect::<Vec<_>>()
            .join("\n"))
    }

    /// 按条目名读取原始字节（供 FFI 层读取图片）
    ///
    /// 兼容传入 `cbz://<条目名>` 伪 URL（自动剥离前缀）。
    pub fn read_entry(&self, entry_name: &str) -> LegadoResult<Vec<u8>> {
        let name = entry_name
            .strip_prefix(CBZ_URL_SCHEME)
            .unwrap_or(entry_name);
        let mut archive = open_archive(&self.path)?;
        let mut entry = archive
            .by_name(name)
            .map_err(|e| LegadoError::BookParse(format!("CBZ 条目不存在 [{name}]: {e}")))?;
        let mut buf = Vec::with_capacity(entry.size() as usize);
        entry
            .read_to_end(&mut buf)
            .map_err(|e| LegadoError::BookParse(format!("读取CBZ条目失败 [{name}]: {e}")))?;
        Ok(buf)
    }

    /// 图片条目名列表（自然排序）
    pub fn image_entries(&self) -> &[String] {
        &self.images
    }

    /// 书名（文件名去扩展名）
    pub fn title(&self) -> &str {
        &self.title
    }
}

/// 打开 ZIP 归档
fn open_archive(path: &str) -> LegadoResult<ZipArchive<File>> {
    let file =
        File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开CBZ文件: {e}")))?;
    ZipArchive::new(file).map_err(|e| LegadoError::BookParse(format!("CBZ文件解析失败: {e}")))
}

/// 无图片条目错误
fn no_image_error(path: &str) -> LegadoError {
    LegadoError::BookParse(format!("CBZ 内未找到图片条目: {path}"))
}

/// 判断条目名是否为白名单图片（扩展名大小写不敏感，忽略隐藏文件）
fn is_image_entry(name: &str) -> bool {
    let base = file_base_name(name);
    // 隐藏文件/资源分叉（如 ._page.jpg、.DS_Store）不作为漫画页
    if base.starts_with('.') {
        return false;
    }
    let lower = base.to_lowercase();
    IMAGE_EXTENSIONS.iter().any(|ext| lower.ends_with(ext))
}

/// 取路径中的基础文件名（ZIP 条目可能使用 / 或 \ 分隔）
fn file_base_name(name: &str) -> &str {
    name.rsplit(['/', '\\']).next().unwrap_or(name)
}

/// 书名 = 文件名去扩展名
fn book_title(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Unknown".to_string())
}

/// 自然排序比较：数字串按数值比较（page2 < page10），其余按字节序
fn natural_cmp(a: &str, b: &str) -> Ordering {
    let a_bytes = a.as_bytes();
    let b_bytes = b.as_bytes();
    let (mut i, mut j) = (0usize, 0usize);

    while i < a_bytes.len() && j < b_bytes.len() {
        let ac = a_bytes[i];
        let bc = b_bytes[j];
        if ac.is_ascii_digit() && bc.is_ascii_digit() {
            let a_start = i;
            while i < a_bytes.len() && a_bytes[i].is_ascii_digit() {
                i += 1;
            }
            let b_start = j;
            while j < b_bytes.len() && b_bytes[j].is_ascii_digit() {
                j += 1;
            }
            let a_digits = &a[a_start..i];
            let b_digits = &b[b_start..j];
            // 忽略前导零后比较数值（按长度再按字典序，避免溢出）
            let a_num = a_digits.trim_start_matches('0');
            let b_num = b_digits.trim_start_matches('0');
            let ord = a_num
                .len()
                .cmp(&b_num.len())
                .then_with(|| a_num.cmp(b_num))
                .then_with(|| a_digits.len().cmp(&b_digits.len()));
            if ord != Ordering::Equal {
                return ord;
            }
        } else {
            let ord = ac.cmp(&bc);
            if ord != Ordering::Equal {
                return ord;
            }
            i += 1;
            j += 1;
        }
    }

    (a_bytes.len() - i).cmp(&(b_bytes.len() - j))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::Write;

    /// 在临时目录中程序化造一个 CBZ，返回文件路径
    ///
    /// 调用方负责在测试结束时清理 `std::env::temp_dir().join(dir_name)`。
    fn make_cbz(dir_name: &str, file_name: &str, entries: &[(&str, &[u8])]) -> String {
        let dir = std::env::temp_dir().join(dir_name);
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let cbz_path = dir.join(file_name);
        let file = File::create(&cbz_path).unwrap();
        let mut writer = zip::ZipWriter::new(file);
        let options = zip::write::SimpleFileOptions::default();

        for (name, data) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(data).unwrap();
        }
        writer.finish().unwrap();

        cbz_path.to_string_lossy().into_owned()
    }

    #[test]
    fn test_is_image_entry() {
        assert!(is_image_entry("page.jpg"));
        assert!(is_image_entry("page.JPEG"));
        assert!(is_image_entry("page.png"));
        assert!(is_image_entry("page.WebP"));
        assert!(is_image_entry("page.gif"));
        assert!(is_image_entry("page.bmp"));
        assert!(is_image_entry("dir/sub/page.jpg"));
        assert!(!is_image_entry("readme.txt"));
        assert!(!is_image_entry("data.json"));
        assert!(!is_image_entry("noext"));
        assert!(!is_image_entry("dir/"));
        assert!(!is_image_entry("._page.jpg"));
    }

    #[test]
    fn test_natural_cmp() {
        assert_eq!(natural_cmp("page1.jpg", "page2.jpg"), Ordering::Less);
        assert_eq!(natural_cmp("page2.jpg", "page10.jpg"), Ordering::Less);
        assert_eq!(natural_cmp("page10.jpg", "page10.jpg"), Ordering::Equal);
        // 数值相等时短前导零者在前（page1 < page01）
        assert_eq!(natural_cmp("page1.jpg", "page01.jpg"), Ordering::Less);
        assert_eq!(natural_cmp("abc", "abd"), Ordering::Less);
        assert_eq!(natural_cmp("a", "a0"), Ordering::Less);
    }

    #[test]
    fn test_cbz_metadata_chapters_and_content() {
        let path = make_cbz(
            "legado_test_cbz_basic",
            "漫画合集.cbz",
            &[
                ("漫画 第1页.jpg", b"page-one"),
                ("page10.webp", b"page-ten"),
                ("page2.png", b"page-two"),
                ("封面 终.PNG", b"cover-final"),
                ("readme.txt", b"not an image"),
                ("notes.json", b"{}"),
            ],
        );

        let cbz = CbzFile::open(&path).unwrap();

        // metadata：书名 = 文件名去扩展名，作者空
        let meta = cbz.metadata().unwrap();
        assert_eq!(meta.title, "漫画合集");
        assert_eq!(meta.author, "");
        assert_eq!(meta.format, BookFormat::Cbz);

        // get_chapters：固定 1 章，url 置空，title = 书名
        let chapters = cbz.get_chapters().unwrap();
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].index, 0);
        assert_eq!(chapters[0].title, "漫画合集");
        assert_eq!(chapters[0].url, "");
        assert!(!chapters[0].is_volume);

        // get_chapter_content：4 行 cbz:// 伪 URL，仅图片
        let content = cbz.get_chapter_content(0).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 4, "content={content}");
        assert!(lines.iter().all(|l| l.starts_with("cbz://")));
        assert!(lines.contains(&"cbz://漫画 第1页.jpg"));
        assert!(lines.contains(&"cbz://封面 终.PNG"));
        assert!(lines.contains(&"cbz://page2.png"));
        assert!(lines.contains(&"cbz://page10.webp"));
        assert!(!content.contains("readme.txt"));
        assert!(!content.contains("notes.json"));

        // 自然排序：page2 在 page10 之前
        let pos2 = lines.iter().position(|l| *l == "cbz://page2.png").unwrap();
        let pos10 = lines
            .iter()
            .position(|l| *l == "cbz://page10.webp")
            .unwrap();
        assert!(pos2 < pos10, "自然排序失败: {lines:?}");

        // read_entry：原始条目名与 cbz:// 伪 URL 均可读，字节正确
        assert_eq!(cbz.read_entry("漫画 第1页.jpg").unwrap(), b"page-one");
        assert_eq!(cbz.read_entry("cbz://漫画 第1页.jpg").unwrap(), b"page-one");
        assert_eq!(cbz.read_entry("page10.webp").unwrap(), b"page-ten");
        assert!(cbz.read_entry("not-exist.jpg").is_err());

        // 越界索引报错
        assert!(cbz.get_chapter_content(1).is_err());

        let _ = fs::remove_dir_all(std::env::temp_dir().join("legado_test_cbz_basic"));
    }

    #[test]
    fn test_cbz_without_images_errors() {
        let path = make_cbz(
            "legado_test_cbz_empty",
            "not_comic.cbz",
            &[("readme.txt", b"hello"), ("meta/info.json", b"{}")],
        );

        let cbz = CbzFile::open(&path).unwrap();
        assert!(cbz.image_entries().is_empty());
        assert!(cbz.get_chapters().is_err());
        assert!(cbz.get_chapter_content(0).is_err());

        let _ = fs::remove_dir_all(std::env::temp_dir().join("legado_test_cbz_empty"));
    }

    #[test]
    fn test_cbz_filters_dirs_non_images_and_hidden() {
        let dir = std::env::temp_dir().join("legado_test_cbz_filter");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();

        let cbz_path = dir.join("filter.cbz");
        {
            let file = File::create(&cbz_path).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();

            // 目录项应被跳过
            writer.add_directory("sub/", options).unwrap();
            writer.start_file("cover.jpg", options).unwrap();
            writer.write_all(b"cover").unwrap();
            writer.start_file("sub/a.jpg", options).unwrap();
            writer.write_all(b"nested").unwrap();
            writer.start_file("readme.md", options).unwrap();
            writer.write_all(b"text").unwrap();
            // 隐藏资源分叉不应作为漫画页
            writer.start_file("._cover.jpg", options).unwrap();
            writer.write_all(b"fork").unwrap();

            writer.finish().unwrap();
        }

        let cbz = CbzFile::open(cbz_path.to_str().unwrap()).unwrap();
        let entries = cbz.image_entries();
        assert_eq!(
            entries.to_vec(),
            vec!["cover.jpg".to_string(), "sub/a.jpg".to_string()]
        );

        let lines: Vec<String> = cbz
            .get_chapter_content(0)
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect();
        assert_eq!(lines, vec!["cbz://cover.jpg", "cbz://sub/a.jpg"]);

        let _ = fs::remove_dir_all(&dir);
    }

    /// 端到端：经 `LocalBook` 统一入口走通格式检测 → 元数据 → 章节 → 正文
    #[test]
    fn test_local_book_cbz_end_to_end() {
        let path = make_cbz(
            "legado_test_cbz_localbook",
            "系列 漫画.cbz",
            &[("02.jpg", b"page-two"), ("01 封面.jpg", b"page-one")],
        );

        let meta = crate::LocalBook::parse(&path).unwrap();
        assert_eq!(meta.title, "系列 漫画");
        assert_eq!(meta.format, BookFormat::Cbz);

        let chapters = crate::LocalBook::get_chapters(&path).unwrap();
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].url, "");

        let content = crate::LocalBook::get_chapter_content(&path, &chapters[0]).unwrap();
        assert_eq!(content, "cbz://01 封面.jpg\ncbz://02.jpg");

        let _ = fs::remove_dir_all(std::env::temp_dir().join("legado_test_cbz_localbook"));
    }

    #[test]
    fn test_cbz_open_invalid_file_errors() {
        let dir = std::env::temp_dir().join("legado_test_cbz_invalid");
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        let bad_path = dir.join("bad.cbz");
        fs::write(&bad_path, b"this is not a zip").unwrap();

        let result = CbzFile::open(bad_path.to_str().unwrap());
        assert!(result.is_err());

        assert!(CbzFile::open("/nonexistent/path.cbz").is_err());

        let _ = fs::remove_dir_all(&dir);
    }
}
