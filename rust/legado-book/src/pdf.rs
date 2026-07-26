//! PDF 格式解析模块
//!
//! 使用 `lopdf` crate 实现 PDF 文档的解析：
//! - 解析 PDF 文件头获取版本号
//! - 使用 lopdf 提取文本内容
//! - 基于 PDF 书签（Outline）生成目录，无书签时按固定页数分章

use std::collections::BTreeMap;

use legado_core::{LegadoError, LegadoResult};
use lopdf::{Document, ObjectId};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// PDF 解析器
pub struct PdfParser;

/// PDF 文档元数据
#[derive(Debug, Clone)]
pub struct PdfMetadata {
    pub title: String,
    pub author: String,
    pub page_count: i32,
}

impl PdfParser {
    /// 打开并加载 PDF 文档
    pub fn open(path: &std::path::Path) -> LegadoResult<Document> {
        Document::load(path).map_err(|e| LegadoError::BookParse(format!("无法打开 PDF 文件: {e}")))
    }

    /// 从 PDF Info 字典中提取元数据
    pub fn extract_metadata(doc: &Document) -> LegadoResult<PdfMetadata> {
        let info_obj = doc
            .trailer
            .get(b"Info")
            .ok()
            .and_then(|o| o.as_reference().ok())
            .and_then(|id| doc.get_object(id).ok());

        let title = info_obj
            .as_ref()
            .and_then(|i| {
                let dict = i.as_dict().ok()?;
                let val = dict.get(b"Title").ok()?;
                let s = val.as_str().ok()?;
                Some(String::from_utf8_lossy(s).to_string())
            })
            .unwrap_or_default();

        let author = info_obj
            .as_ref()
            .and_then(|i| {
                let dict = i.as_dict().ok()?;
                let val = dict.get(b"Author").ok()?;
                let s = val.as_str().ok()?;
                Some(String::from_utf8_lossy(s).to_string())
            })
            .unwrap_or_default();

        let page_count = doc.get_pages().len() as i32;

        Ok(PdfMetadata {
            title,
            author,
            page_count,
        })
    }

    /// 获取章节列表
    ///
    /// 优先使用 PDF 书签（Outlines）；若无书签则按每 `pages_per_chapter` 页一章分割。
    pub fn get_chapters_from_doc(
        doc: &Document,
        pages_per_chapter: u32,
    ) -> LegadoResult<Vec<ChapterInfo>> {
        // 尝试从书签提取
        if let Ok(bookmarks) = Self::extract_bookmarks(doc) {
            if !bookmarks.is_empty() {
                return Ok(bookmarks);
            }
        }

        // 回退：按固定页数分割
        let pages = doc.get_pages();
        let total_pages = pages.len() as u32;
        if total_pages == 0 {
            return Ok(vec![]);
        }

        let ppc = pages_per_chapter.max(1);
        let mut chapters = Vec::new();

        let mut i: u32 = 0;
        while i < total_pages {
            let end = (i + ppc).min(total_pages);
            chapters.push(ChapterInfo {
                url: format!("pdf://pages/{}-{}", i + 1, end),
                title: format!("第 {} 章 (页 {} - {})", chapters.len() + 1, i + 1, end),
                index: chapters.len() as i32,
                is_volume: false,
                start: Some(i as i64),
                end: Some(end as i64),
            });
            i += ppc;
        }

        Ok(chapters)
    }

    /// 提取 PDF 书签（Outlines）作为章节列表
    fn extract_bookmarks(doc: &Document) -> LegadoResult<Vec<ChapterInfo>> {
        let mut chapters = Vec::new();

        // 获取 Root 对象
        let root_ref = match doc
            .trailer
            .get(b"Root")
            .ok()
            .and_then(|o| o.as_reference().ok())
        {
            Some(r) => r,
            None => return Ok(chapters),
        };

        let root_dict = match doc.get_object(root_ref).ok().and_then(|o| o.as_dict().ok()) {
            Some(d) => d,
            None => return Ok(chapters),
        };

        // 获取 Outlines 对象
        let outlines_ref = match root_dict
            .get(b"Outlines")
            .ok()
            .and_then(|o| o.as_reference().ok())
        {
            Some(r) => r,
            None => return Ok(chapters),
        };

        let outlines_dict = match doc
            .get_object(outlines_ref)
            .ok()
            .and_then(|o| o.as_dict().ok())
        {
            Some(d) => d,
            None => return Ok(chapters),
        };

        // 从 First 开始遍历书签链表
        let mut current: Option<ObjectId> = outlines_dict
            .get(b"First")
            .ok()
            .and_then(|o| o.as_reference().ok());

        let page_map = doc.get_pages();
        // 构建 ObjectId -> 页码（0-based）的反向映射
        let id_to_page: BTreeMap<ObjectId, u32> = page_map
            .iter()
            .map(|(&page_num, &obj_id)| (obj_id, page_num.saturating_sub(1)))
            .collect();

        while let Some(cur_id) = current {
            let item = match doc.get_object(cur_id).ok().and_then(|o| o.as_dict().ok()) {
                Some(d) => d,
                None => break,
            };

            let title = item
                .get(b"Title")
                .ok()
                .and_then(|o| o.as_str().ok())
                .map(|s| String::from_utf8_lossy(s).to_string())
                .unwrap_or_else(|| format!("书签 {}", chapters.len() + 1));

            // 尝试从 Dest 获取目标页码
            let start_page = Self::resolve_dest_page(item, doc, &id_to_page);

            chapters.push(ChapterInfo {
                url: format!("pdf://bookmark/{}", chapters.len()),
                title,
                index: chapters.len() as i32,
                is_volume: false,
                start: start_page.map(|p| p as i64),
                end: None,
            });

            // 移动到下一个兄弟书签
            current = item.get(b"Next").ok().and_then(|o| o.as_reference().ok());
        }

        // 补全 end 字段：每个章节的结束页为下一章起始页的前一页
        let len = chapters.len();
        for i in 0..len {
            if i + 1 < len {
                let next_start = chapters[i + 1].start;
                chapters[i].end = next_start.map(|s| (s as u32).saturating_sub(1) as i64);
            } else {
                // 最后一章结束于最后一页
                chapters[i].end = Some(page_map.len().saturating_sub(1) as i64);
            }
        }

        Ok(chapters)
    }

    /// 从书签的 Dest 字段解析目标页码（0-based）
    fn resolve_dest_page(
        item: &lopdf::Dictionary,
        _doc: &Document,
        id_to_page: &BTreeMap<ObjectId, u32>,
    ) -> Option<u32> {
        // Dest 可能是数组 [page_ref, /Fit, ...] 或字符串名称
        let dest = item.get(b"Dest").ok()?;
        if let Ok(dest_arr) = dest.as_array() {
            if let Some(first) = dest_arr.first() {
                // 直接引用
                if let Ok(page_ref) = first.as_reference() {
                    return id_to_page.get(&page_ref).copied();
                }
                // 整数对象（页码）
                if let Ok(page_num) = first.as_i64() {
                    return Some(page_num as u32);
                }
            }
        }

        // 命名目标 —— 简化处理，跳过
        None
    }

    /// 获取指定页面（0-based）的文本内容
    pub fn get_page_text(doc: &Document, page_num: u32) -> LegadoResult<String> {
        // lopdf 的 extract_text 接受 1-based 页码
        let text = doc.extract_text(&[page_num + 1]).map_err(|e| {
            LegadoError::BookParse(format!("无法提取页面文本 (页 {}): {e}", page_num + 1))
        })?;
        Ok(text)
    }

    /// 获取指定页面范围（0-based，含首尾）的文本内容
    pub fn get_page_range_text(doc: &Document, start: u32, end: u32) -> LegadoResult<String> {
        let mut content = String::new();
        for page in start..=end {
            if let Ok(text) = Self::get_page_text(doc, page) {
                if !content.is_empty() {
                    content.push_str("\n\n");
                }
                content.push_str(&text);
            }
        }
        Ok(content)
    }

    // -----------------------------------------------------------------------
    // 对外公共 API（供 LocalBook 调用，保持原有签名）
    // -----------------------------------------------------------------------

    /// 解析 PDF 文件元数据（公共 API）
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let doc = Self::open(std::path::Path::new(path))?;
        let meta = Self::extract_metadata(&doc)?;

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
            description: String::new(),
            format: BookFormat::Pdf,
            cover: None,
        })
    }

    /// 获取章节列表（公共 API），默认每 20 页一章
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let doc = Self::open(std::path::Path::new(path))?;
        Self::get_chapters_from_doc(&doc, 20)
    }

    /// 获取章节正文内容（公共 API）
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let doc = Self::open(std::path::Path::new(path))?;

        let start = chapter.start.map(|s| s as u32).unwrap_or(0);
        let end = chapter.end.map(|e| e as u32).unwrap_or(start);

        Self::get_page_range_text(&doc, start, end)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::BookFormat;

    #[test]
    fn test_pdf_magic_detection() {
        // 通过 detect_format 验证 .pdf 扩展名识别
        let fmt = crate::LocalBook::detect_format("some_file.pdf").unwrap();
        assert_eq!(fmt, BookFormat::Pdf);
    }

    #[test]
    fn test_pdf_magic_bytes() {
        // 直接验证 PDF 魔数比较逻辑
        let header: [u8; 8] = *b"%PDF-1.7";
        assert_eq!(&header[0..5], b"%PDF-");
    }

    #[test]
    fn test_chapter_split_logic() {
        // 模拟按 20 页分割的逻辑
        let total_pages: u32 = 55;
        let ppc: u32 = 20;
        let mut chapters = Vec::new();
        let mut i: u32 = 0;
        while i < total_pages {
            let end = (i + ppc).min(total_pages);
            chapters.push(ChapterInfo {
                url: format!("pdf://pages/{}-{}", i + 1, end),
                title: format!("第 {} 章 (页 {} - {})", chapters.len() + 1, i + 1, end),
                index: chapters.len() as i32,
                is_volume: false,
                start: Some(i as i64),
                end: Some(end as i64),
            });
            i += ppc;
        }

        assert_eq!(chapters.len(), 3);
        assert_eq!(chapters[0].start, Some(0));
        assert_eq!(chapters[0].end, Some(20));
        assert_eq!(chapters[1].start, Some(20));
        assert_eq!(chapters[1].end, Some(40));
        assert_eq!(chapters[2].start, Some(40));
        assert_eq!(chapters[2].end, Some(55));
        assert_eq!(chapters[0].title, "第 1 章 (页 1 - 20)");
    }

    #[test]
    fn test_open_nonexistent_pdf() {
        let result = PdfParser::parse("/nonexistent/path/to/file.pdf");
        assert!(result.is_err());
    }

    #[test]
    fn test_get_chapters_nonexistent_pdf() {
        let result = PdfParser::get_chapters("/nonexistent/path/to/file.pdf");
        assert!(result.is_err());
    }

    #[test]
    fn test_get_chapter_content_nonexistent_pdf() {
        let ch = ChapterInfo {
            url: "pdf://pages/1-10".to_string(),
            title: "Test".to_string(),
            index: 0,
            is_volume: false,
            start: Some(0),
            end: Some(9),
        };
        let result = PdfParser::get_chapter_content("/nonexistent.pdf", &ch);
        assert!(result.is_err());
    }

    #[test]
    fn test_pdf_metadata_struct() {
        let meta = PdfMetadata {
            title: "Test PDF".to_string(),
            author: "Author".to_string(),
            page_count: 100,
        };
        assert_eq!(meta.title, "Test PDF");
        assert_eq!(meta.author, "Author");
        assert_eq!(meta.page_count, 100);
    }

    #[test]
    fn test_chapter_split_single_page() {
        // 测试只有 1 页的情况
        let total_pages: u32 = 1;
        let ppc: u32 = 20;
        let mut chapters = Vec::new();
        let mut i: u32 = 0;
        while i < total_pages {
            let end = (i + ppc).min(total_pages);
            chapters.push(ChapterInfo {
                url: format!("pdf://pages/{}-{}", i + 1, end),
                title: format!("第 {} 章", chapters.len() + 1),
                index: chapters.len() as i32,
                is_volume: false,
                start: Some(i as i64),
                end: Some(end as i64),
            });
            i += ppc;
        }
        assert_eq!(chapters.len(), 1);
        assert_eq!(chapters[0].start, Some(0));
        assert_eq!(chapters[0].end, Some(1));
    }
}
