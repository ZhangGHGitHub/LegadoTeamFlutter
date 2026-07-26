//! UMD 格式解析模块
//!
//! UMD (Unlimited Mobile Document) 是一种移动端电子书格式。
//! 结构：ZIP 文件包含 content.html + 元数据文件。
//!
//! 解析流程：
//! 1. 以 ZIP 归档方式打开文件
//! 2. 遍历内部条目：`.html`/`.htm` 视为章节正文，封面图片存入元数据
//! 3. 提取章节标题与内容，返回统一的 `BookMetadata` / `ChapterInfo`

use std::io::Read;

use zip::ZipArchive;

use legado_core::{LegadoError, LegadoResult};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// UMD 元数据
#[derive(Debug, Clone, Default)]
pub struct UmdMeta {
    pub title: String,
    pub author: String,
    pub description: String,
    /// 封面图片字节
    pub cover: Option<Vec<u8>>,
}

/// UMD 章节
#[derive(Debug, Clone)]
pub struct UmdChapter {
    pub title: String,
    pub content: String,
}

/// UMD 解析器
pub struct UmdParser;

impl UmdParser {
    /// 解析 UMD 文件元数据（统一入口，供 `LocalBook` 调用）
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let (meta, _chapters) = Self::parse_file(path)?;
        let title = if meta.title.is_empty() {
            std::path::Path::new(path)
                .file_stem()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| "Unknown".to_string())
        } else {
            meta.title
        };
        Ok(BookMetadata {
            title,
            author: meta.author,
            description: meta.description,
            format: BookFormat::Umd,
            cover: meta.cover,
        })
    }

    /// 获取章节列表（统一入口，供 `LocalBook` 调用）
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let (_meta, chapters) = Self::parse_file(path)?;
        Ok(chapters
            .iter()
            .enumerate()
            .map(|(i, ch)| ChapterInfo {
                url: format!("umd://chapter/{i}"),
                title: ch.title.clone(),
                index: i as i32,
                is_volume: false,
                start: Some(i as i64),
                end: None,
            })
            .collect())
    }

    /// 获取章节正文内容（统一入口，供 `LocalBook` 调用）
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let (_meta, chapters) = Self::parse_file(path)?;
        let index = chapter.index as usize;
        chapters
            .get(index)
            .map(|ch| ch.content.clone())
            .ok_or_else(|| LegadoError::BookParse(format!("UMDD 章节索引越界: {index}")))
    }

    /// 从文件路径解析 UMD，返回元数据与章节列表
    pub fn parse_file(path: &str) -> LegadoResult<(UmdMeta, Vec<UmdChapter>)> {
        let data = std::fs::read(path)?;
        Self::parse_bytes(&data)
    }

    /// 从字节解析 UMD
    ///
    /// UMD 文件是一个 ZIP 归档，内部结构通常为：
    /// - `content.html`（主内容，可能有多个 HTML 章节）
    /// - `cover.jpg` / `image/*`（封面）
    /// - 其它元数据相关文件
    pub fn parse_bytes(data: &[u8]) -> LegadoResult<(UmdMeta, Vec<UmdChapter>)> {
        let cursor = std::io::Cursor::new(data);
        let mut archive = ZipArchive::new(cursor)
            .map_err(|e| LegadoError::BookParse(format!("Invalid UMD ZIP: {e}")))?;

        let mut meta = UmdMeta::default();
        let mut chapters = Vec::new();

        for i in 0..archive.len() {
            let mut file = archive
                .by_index(i)
                .map_err(|e| LegadoError::BookParse(e.to_string()))?;
            let name = file.name().to_string();
            let lower = name.to_lowercase();

            if lower.ends_with(".html") || lower.ends_with(".htm") {
                let mut content = String::new();
                file.read_to_string(&mut content)?;
                let title = chapter_title_from_name(&name);
                chapters.push(UmdChapter { title, content });
            } else if lower.contains("cover") || lower.starts_with("image") {
                let mut img_data = Vec::new();
                file.read_to_end(&mut img_data)?;
                meta.cover = Some(img_data);
            }
        }

        if chapters.is_empty() {
            return Err(LegadoError::BookParse(
                "No content found in UMD".to_string(),
            ));
        }

        Ok((meta, chapters))
    }

    /// 获取章节标题列表（标题, 索引）
    pub fn get_chapter_titles(chapters: &[UmdChapter]) -> Vec<(String, usize)> {
        chapters
            .iter()
            .enumerate()
            .map(|(i, ch)| (ch.title.clone(), i))
            .collect()
    }

    /// 获取指定索引的章节内容
    pub fn get_chapter_content_by_index(chapters: &[UmdChapter], index: usize) -> Option<&str> {
        chapters.get(index).map(|ch| ch.content.as_str())
    }
}

/// 从 ZIP 条目文件名推导章节标题
///
/// 例如 `chapter1.html` → `chapter1`，`content.htm` → `content`
fn chapter_title_from_name(name: &str) -> String {
    let base = name.rsplit_once('/').map(|(_, file)| file).unwrap_or(name);
    base.rsplit_once('.')
        .map(|(stem, _)| stem.to_string())
        .unwrap_or_else(|| base.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::SimpleFileOptions;
    use zip::ZipWriter;

    /// 构造一个内存中的 UMD（ZIP）测试文件
    fn build_umd_zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut buf = Vec::new();
        {
            let cursor = std::io::Cursor::new(&mut buf);
            let mut zip = ZipWriter::new(cursor);
            let options = SimpleFileOptions::default();
            for (name, data) in entries {
                zip.start_file(*name, options).unwrap();
                zip.write_all(data).unwrap();
            }
            zip.finish().unwrap();
        }
        buf
    }

    #[test]
    fn test_parse_bytes_single_html() {
        let html = b"<html><body><p>Hello UMD</p></body></html>";
        let data = build_umd_zip(&[("content.html", html.as_slice())]);

        let (meta, chapters) = UmdParser::parse_bytes(&data).unwrap();
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].title, "content");
        assert!(chapters[0].content.contains("Hello UMD"));
        assert!(meta.cover.is_none());
    }

    #[test]
    fn test_parse_bytes_multiple_chapters() {
        let ch1 = b"<html><body>Chapter One</body></html>";
        let ch2 = b"<html><body>Chapter Two</body></html>";
        let data = build_umd_zip(&[
            ("chapter1.html", ch1.as_slice()),
            ("chapter2.htm", ch2.as_slice()),
        ]);

        let (_meta, chapters) = UmdParser::parse_bytes(&data).unwrap();
        assert_eq!(chapters.len(), 2);
        assert_eq!(chapters[0].title, "chapter1");
        assert_eq!(chapters[1].title, "chapter2");
    }

    #[test]
    fn test_parse_bytes_with_cover() {
        let html = b"<html><body>text</body></html>";
        let img = [0xFFu8, 0xD8, 0xFF, 0xE0]; // 伪 JPEG 头
        let data = build_umd_zip(&[
            ("content.html", html.as_slice()),
            ("cover.jpg", img.as_slice()),
        ]);

        let (meta, chapters) = UmdParser::parse_bytes(&data).unwrap();
        assert_eq!(chapters.len(), 1);
        assert!(meta.cover.is_some());
        assert_eq!(meta.cover.as_ref().unwrap().len(), 4);
    }

    #[test]
    fn test_parse_bytes_empty_archive_errors() {
        // 仅含非 HTML 文件，应报错
        let data = build_umd_zip(&[("readme.txt", b"just text".as_slice())]);
        let result = UmdParser::parse_bytes(&data);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_bytes_invalid_zip_errors() {
        let garbage = b"this is not a zip file";
        let result = UmdParser::parse_bytes(garbage);
        assert!(result.is_err());
    }

    #[test]
    fn test_get_chapter_titles() {
        let chapters = vec![
            UmdChapter {
                title: "序章".to_string(),
                content: "a".to_string(),
            },
            UmdChapter {
                title: "第一章".to_string(),
                content: "b".to_string(),
            },
        ];
        let titles = UmdParser::get_chapter_titles(&chapters);
        assert_eq!(titles.len(), 2);
        assert_eq!(titles[0], ("序章".to_string(), 0));
        assert_eq!(titles[1], ("第一章".to_string(), 1));
    }

    #[test]
    fn test_get_chapter_content_by_index() {
        let chapters = vec![
            UmdChapter {
                title: "c0".to_string(),
                content: "content-zero".to_string(),
            },
            UmdChapter {
                title: "c1".to_string(),
                content: "content-one".to_string(),
            },
        ];
        assert_eq!(
            UmdParser::get_chapter_content_by_index(&chapters, 0),
            Some("content-zero")
        );
        assert_eq!(
            UmdParser::get_chapter_content_by_index(&chapters, 1),
            Some("content-one")
        );
        assert_eq!(UmdParser::get_chapter_content_by_index(&chapters, 5), None);
    }

    #[test]
    fn test_chapter_title_from_name() {
        assert_eq!(chapter_title_from_name("content.html"), "content");
        assert_eq!(chapter_title_from_name("dir/chapter1.htm"), "chapter1");
        assert_eq!(chapter_title_from_name("a/b/c.xhtml"), "c");
        assert_eq!(chapter_title_from_name("noext"), "noext");
    }
}
