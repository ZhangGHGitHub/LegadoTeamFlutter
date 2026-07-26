//! 书籍导出模块
//!
//! 支持将书籍内容导出为 TXT、EPUB、HTML 三种格式。

use std::io::{Cursor, Write};

use zip::write::SimpleFileOptions;
use zip::ZipWriter;

/// 导出格式
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportFormat {
    Txt,
    Epub,
    Html,
}

impl ExportFormat {
    /// 从字符串解析导出格式
    pub fn from_str(s: &str) -> Option<Self> {
        match s.to_lowercase().as_str() {
            "txt" => Some(Self::Txt),
            "epub" => Some(Self::Epub),
            "html" => Some(Self::Html),
            _ => None,
        }
    }

    /// 获取文件扩展名
    pub fn extension(&self) -> &'static str {
        match self {
            Self::Txt => "txt",
            Self::Epub => "epub",
            Self::Html => "html",
        }
    }

    /// 获取 MIME 类型
    pub fn mime_type(&self) -> &'static str {
        match self {
            Self::Txt => "text/plain",
            Self::Epub => "application/epub+zip",
            Self::Html => "text/html",
        }
    }
}

/// 导出配置
#[derive(Debug, Clone)]
pub struct ExportConfig {
    pub format: ExportFormat,
    /// 是否包含目录
    pub include_toc: bool,
    /// 章节分隔符
    pub chapter_separator: String,
    /// 输出编码（UTF-8/GBK）
    pub encoding: String,
}

impl Default for ExportConfig {
    fn default() -> Self {
        Self {
            format: ExportFormat::Txt,
            include_toc: true,
            chapter_separator: String::new(),
            encoding: "UTF-8".to_string(),
        }
    }
}

/// 导出数据
#[derive(Debug, Clone)]
pub struct ExportData {
    pub title: String,
    pub author: String,
    pub intro: Option<String>,
    pub chapters: Vec<ExportChapter>,
}

/// 导出章节
#[derive(Debug, Clone)]
pub struct ExportChapter {
    pub index: i32,
    pub title: String,
    pub content: String,
}

/// 导出器
pub struct BookExporter;

impl BookExporter {
    /// 导出为 TXT
    pub fn export_txt(data: &ExportData, config: &ExportConfig) -> Result<Vec<u8>, String> {
        let mut output = String::new();
        // 标题 + 作者
        output.push_str(&format!("{}\n作者：{}\n\n", data.title, data.author));
        if let Some(intro) = &data.intro {
            output.push_str(&format!("简介：{}\n\n", intro));
        }
        if config.include_toc {
            output.push_str("目录\n");
            for ch in &data.chapters {
                output.push_str(&format!("  {}\n", ch.title));
            }
            output.push('\n');
        }
        for ch in &data.chapters {
            output.push_str(&format!("{}\n\n{}\n\n", ch.title, ch.content));
            if !config.chapter_separator.is_empty() {
                output.push_str(&config.chapter_separator);
                output.push('\n');
            }
        }
        Ok(output.into_bytes())
    }

    /// 导出为 EPUB
    pub fn export_epub(data: &ExportData, _config: &ExportConfig) -> Result<Vec<u8>, String> {
        let buf = Cursor::new(Vec::new());
        let mut zip = ZipWriter::new(buf);

        // 1. mimetype（不压缩，必须是第一个文件）
        let stored = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Stored);
        zip.start_file("mimetype", stored)
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;
        zip.write_all(b"application/epub+zip")
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;

        // 2. META-INF/container.xml
        let deflate = SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        zip.start_file("META-INF/container.xml", deflate)
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;
        zip.write_all(epub_container_xml().as_bytes())
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;

        // 3. OEBPS/content.opf
        zip.start_file("OEBPS/content.opf", deflate)
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;
        zip.write_all(epub_content_opf(data).as_bytes())
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;

        // 4. OEBPS/toc.ncx
        zip.start_file("OEBPS/toc.ncx", deflate)
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;
        zip.write_all(epub_toc_ncx(data).as_bytes())
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;

        // 5. OEBPS/style.css
        zip.start_file("OEBPS/style.css", deflate)
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;
        zip.write_all(epub_style_css().as_bytes())
            .map_err(|e| format!("EPUB 写入失败: {e}"))?;

        // 6. 各章节 XHTML
        for ch in &data.chapters {
            let path = format!("OEBPS/chapters/chapter_{}.xhtml", ch.index);
            zip.start_file(&path, deflate)
                .map_err(|e| format!("EPUB 写入失败: {e}"))?;
            zip.write_all(epub_chapter_xhtml(ch).as_bytes())
                .map_err(|e| format!("EPUB 写入失败: {e}"))?;
        }

        let cursor = zip
            .finish()
            .map_err(|e| format!("EPUB 完成写入失败: {e}"))?;
        Ok(cursor.into_inner())
    }

    /// 导出为 HTML
    pub fn export_html(data: &ExportData, config: &ExportConfig) -> Result<Vec<u8>, String> {
        let mut html = String::new();
        html.push_str("<!DOCTYPE html>\n<html lang=\"zh-CN\">\n<head>\n");
        html.push_str("<meta charset=\"UTF-8\">\n");
        html.push_str(&format!(
            "<title>{}</title>\n",
            html_escape(&data.title)
        ));
        html.push_str("<style>\n");
        html.push_str(HTML_CSS);
        html.push_str("</style>\n</head>\n<body>\n");

        // 标题区
        html.push_str("<div class=\"book-header\">\n");
        html.push_str(&format!("  <h1>{}</h1>\n", html_escape(&data.title)));
        html.push_str(&format!(
            "  <p class=\"author\">作者：{}</p>\n",
            html_escape(&data.author)
        ));
        if let Some(intro) = &data.intro {
            html.push_str(&format!(
                "  <p class=\"intro\">{}</p>\n",
                html_escape(intro)
            ));
        }
        html.push_str("</div>\n");

        // 目录
        if config.include_toc {
            html.push_str("<div class=\"toc\">\n  <h2>目录</h2>\n  <ul>\n");
            for ch in &data.chapters {
                html.push_str(&format!(
                    "    <li><a href=\"#chapter-{}\">{}</a></li>\n",
                    ch.index,
                    html_escape(&ch.title)
                ));
            }
            html.push_str("  </ul>\n</div>\n");
        }

        // 章节内容
        html.push_str("<div class=\"content\">\n");
        for ch in &data.chapters {
            html.push_str(&format!(
                "  <div class=\"chapter\" id=\"chapter-{}\">\n",
                ch.index
            ));
            html.push_str(&format!(
                "    <h2>{}</h2>\n",
                html_escape(&ch.title)
            ));
            // 将段落转换为 <p> 标签
            for para in ch.content.split('\n') {
                let trimmed = para.trim();
                if !trimmed.is_empty() {
                    html.push_str(&format!("    <p>{}</p>\n", html_escape(trimmed)));
                }
            }
            html.push_str("  </div>\n");
        }
        html.push_str("</div>\n</body>\n</html>\n");

        Ok(html.into_bytes())
    }

    /// 统一导出接口
    pub fn export(data: &ExportData, config: &ExportConfig) -> Result<Vec<u8>, String> {
        match config.format {
            ExportFormat::Txt => Self::export_txt(data, config),
            ExportFormat::Epub => Self::export_epub(data, config),
            ExportFormat::Html => Self::export_html(data, config),
        }
    }
}

// ---------------------------------------------------------------------------
// HTML CSS 样式
// ---------------------------------------------------------------------------

const HTML_CSS: &str = r#"body {
  font-family: "Noto Serif SC", "Source Han Serif CN", serif;
  max-width: 800px;
  margin: 0 auto;
  padding: 2rem;
  line-height: 1.8;
  color: #333;
}
.book-header { text-align: center; margin-bottom: 2rem; }
.book-header h1 { font-size: 2rem; margin-bottom: 0.5rem; }
.book-header .author { color: #666; font-size: 1.1rem; }
.book-header .intro { color: #555; font-size: 0.95rem; margin-top: 1rem; }
.toc { margin: 2rem 0; padding: 1rem; border: 1px solid #ddd; border-radius: 4px; }
.toc h2 { margin-top: 0; }
.toc ul { list-style: none; padding-left: 0; }
.toc li { margin: 0.3rem 0; }
.toc a { text-decoration: none; color: #2c5aa0; }
.toc a:hover { text-decoration: underline; }
.chapter { margin: 2rem 0; page-break-before: always; }
.chapter h2 { border-bottom: 1px solid #eee; padding-bottom: 0.5rem; }
.chapter p { text-indent: 2em; margin: 0.5rem 0; }
"#;

// ---------------------------------------------------------------------------
// EPUB 辅助函数
// ---------------------------------------------------------------------------

fn epub_container_xml() -> String {
    r#"<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
"#
    .to_string()
}

fn epub_content_opf(data: &ExportData) -> String {
    let mut opf = String::new();
    opf.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    opf.push_str("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"2.0\" unique-identifier=\"BookId\">\n");
    opf.push_str("  <metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:opf=\"http://www.idpf.org/2007/opf\">\n");
    opf.push_str(&format!(
        "    <dc:title>{}</dc:title>\n",
        xml_escape(&data.title)
    ));
    opf.push_str(&format!(
        "    <dc:creator>{}</dc:creator>\n",
        xml_escape(&data.author)
    ));
    opf.push_str("    <dc:language>zh-CN</dc:language>\n");
    opf.push_str("    <dc:identifier id=\"BookId\">urn:uuid:legado-export</dc:identifier>\n");
    if let Some(intro) = &data.intro {
        opf.push_str(&format!(
            "    <dc:description>{}</dc:description>\n",
            xml_escape(intro)
        ));
    }
    opf.push_str("  </metadata>\n");

    // manifest
    opf.push_str("  <manifest>\n");
    opf.push_str("    <item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\n");
    opf.push_str("    <item id=\"style\" href=\"style.css\" media-type=\"text/css\"/>\n");
    for ch in &data.chapters {
        opf.push_str(&format!(
            "    <item id=\"chapter_{}\" href=\"chapters/chapter_{}.xhtml\" media-type=\"application/xhtml+xml\"/>\n",
            ch.index, ch.index
        ));
    }
    opf.push_str("  </manifest>\n");

    // spine
    opf.push_str("  <spine toc=\"ncx\">\n");
    for ch in &data.chapters {
        opf.push_str(&format!(
            "    <itemref idref=\"chapter_{}\"/>\n",
            ch.index
        ));
    }
    opf.push_str("  </spine>\n");
    opf.push_str("</package>\n");
    opf
}

fn epub_toc_ncx(data: &ExportData) -> String {
    let mut ncx = String::new();
    ncx.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    ncx.push_str("<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\">\n");
    ncx.push_str("  <head>\n");
    ncx.push_str("    <meta name=\"dtb:uid\" content=\"urn:uuid:legado-export\"/>\n");
    ncx.push_str("    <meta name=\"dtb:depth\" content=\"1\"/>\n");
    ncx.push_str("    <meta name=\"dtb:totalPageCount\" content=\"0\"/>\n");
    ncx.push_str("    <meta name=\"dtb:maxPageNumber\" content=\"0\"/>\n");
    ncx.push_str("  </head>\n");
    ncx.push_str(&format!(
        "  <docTitle><text>{}</text></docTitle>\n",
        xml_escape(&data.title)
    ));
    ncx.push_str("  <navMap>\n");
    for (i, ch) in data.chapters.iter().enumerate() {
        ncx.push_str(&format!(
            "    <navPoint id=\"navPoint-{}\" playOrder=\"{}\">\n",
            i + 1,
            i + 1
        ));
        ncx.push_str(&format!(
            "      <navLabel><text>{}</text></navLabel>\n",
            xml_escape(&ch.title)
        ));
        ncx.push_str(&format!(
            "      <content src=\"chapters/chapter_{}.xhtml\"/>\n",
            ch.index
        ));
        ncx.push_str("    </navPoint>\n");
    }
    ncx.push_str("  </navMap>\n");
    ncx.push_str("</ncx>\n");
    ncx
}

fn epub_style_css() -> String {
    r#"body {
  font-family: "Noto Serif SC", serif;
  line-height: 1.8;
  padding: 1em;
}
h1 { text-align: center; }
p { text-indent: 2em; margin: 0.5em 0; }
"#
    .to_string()
}

fn epub_chapter_xhtml(chapter: &ExportChapter) -> String {
    let mut xhtml = String::new();
    xhtml.push_str("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    xhtml.push_str("<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.1//EN\" \"http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd\">\n");
    xhtml.push_str("<html xmlns=\"http://www.w3.org/1999/xhtml\">\n");
    xhtml.push_str("<head>\n");
    xhtml.push_str(&format!(
        "  <title>{}</title>\n",
        xml_escape(&chapter.title)
    ));
    xhtml.push_str("  <link rel=\"stylesheet\" type=\"text/css\" href=\"../style.css\"/>\n");
    xhtml.push_str("</head>\n<body>\n");
    xhtml.push_str(&format!("  <h1>{}</h1>\n", xml_escape(&chapter.title)));
    for para in chapter.content.split('\n') {
        let trimmed = para.trim();
        if !trimmed.is_empty() {
            xhtml.push_str(&format!("  <p>{}</p>\n", xml_escape(trimmed)));
        }
    }
    xhtml.push_str("</body>\n</html>\n");
    xhtml
}

// ---------------------------------------------------------------------------
// 转义辅助
// ---------------------------------------------------------------------------

/// HTML 转义
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// XML 转义
fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_data() -> ExportData {
        ExportData {
            title: "测试书籍".to_string(),
            author: "测试作者".to_string(),
            intro: Some("这是一本测试书籍的简介。".to_string()),
            chapters: vec![
                ExportChapter {
                    index: 0,
                    title: "第一章 开始".to_string(),
                    content: "这是第一章的内容。\n第二段文字。".to_string(),
                },
                ExportChapter {
                    index: 1,
                    title: "第二章 发展".to_string(),
                    content: "这是第二章的内容。".to_string(),
                },
                ExportChapter {
                    index: 2,
                    title: "第三章 结局".to_string(),
                    content: "这是第三章的内容。".to_string(),
                },
            ],
        }
    }

    fn default_config(format: ExportFormat) -> ExportConfig {
        ExportConfig {
            format,
            include_toc: true,
            chapter_separator: String::new(),
            encoding: "UTF-8".to_string(),
        }
    }

    #[test]
    fn test_export_txt_basic() {
        let data = sample_data();
        let config = default_config(ExportFormat::Txt);
        let result = BookExporter::export_txt(&data, &config).unwrap();
        let text = String::from_utf8(result).unwrap();

        assert!(text.contains("测试书籍"));
        assert!(text.contains("作者：测试作者"));
        assert!(text.contains("简介：这是一本测试书籍的简介。"));
        assert!(text.contains("第一章 开始"));
        assert!(text.contains("这是第一章的内容。"));
        assert!(text.contains("第二章 发展"));
        assert!(text.contains("第三章 结局"));
    }

    #[test]
    fn test_export_txt_with_toc() {
        let data = sample_data();
        let config = default_config(ExportFormat::Txt);
        let result = BookExporter::export_txt(&data, &config).unwrap();
        let text = String::from_utf8(result).unwrap();

        assert!(text.contains("目录"));
        assert!(text.contains("  第一章 开始"));
        assert!(text.contains("  第二章 发展"));
        assert!(text.contains("  第三章 结局"));
    }

    #[test]
    fn test_export_txt_without_toc() {
        let data = sample_data();
        let mut config = default_config(ExportFormat::Txt);
        config.include_toc = false;
        let result = BookExporter::export_txt(&data, &config).unwrap();
        let text = String::from_utf8(result).unwrap();

        assert!(!text.contains("目录\n"));
    }

    #[test]
    fn test_export_txt_with_separator() {
        let data = sample_data();
        let mut config = default_config(ExportFormat::Txt);
        config.chapter_separator = "---".to_string();
        let result = BookExporter::export_txt(&data, &config).unwrap();
        let text = String::from_utf8(result).unwrap();

        assert!(text.contains("---"));
    }

    #[test]
    fn test_export_txt_empty_chapters() {
        let data = ExportData {
            title: "空书".to_string(),
            author: "无名".to_string(),
            intro: None,
            chapters: vec![],
        };
        let config = default_config(ExportFormat::Txt);
        let result = BookExporter::export_txt(&data, &config).unwrap();
        let text = String::from_utf8(result).unwrap();

        assert!(text.contains("空书"));
        assert!(text.contains("作者：无名"));
        assert!(!text.contains("简介"));
    }

    #[test]
    fn test_export_txt_special_characters() {
        let data = ExportData {
            title: "特殊<字符>&\"测试\"".to_string(),
            author: "作者'甲'".to_string(),
            intro: Some("包含 <html> & 特殊字符".to_string()),
            chapters: vec![ExportChapter {
                index: 0,
                title: "章节<1>".to_string(),
                content: "内容包含 & < > \" ' 字符".to_string(),
            }],
        };
        let config = default_config(ExportFormat::Txt);
        let result = BookExporter::export_txt(&data, &config).unwrap();
        let text = String::from_utf8(result).unwrap();

        // TXT 不做转义，原样输出
        assert!(text.contains("特殊<字符>&\"测试\""));
        assert!(text.contains("内容包含 & < > \" ' 字符"));
    }

    #[test]
    fn test_export_epub_basic() {
        let data = sample_data();
        let config = default_config(ExportFormat::Epub);
        let result = BookExporter::export_epub(&data, &config).unwrap();

        // EPUB 是 ZIP 文件，以 PK 开头
        assert!(result.len() > 4);
        assert_eq!(result[0], 0x50); // 'P'
        assert_eq!(result[1], 0x4B); // 'K'

        // 验证 ZIP 内容
        let cursor = Cursor::new(result);
        let mut archive = zip::ZipArchive::new(cursor).unwrap();
        let names: Vec<String> = (0..archive.len())
            .map(|i| archive.by_index(i).unwrap().name().to_string())
            .collect();

        assert!(names.contains(&"mimetype".to_string()));
        assert!(names.contains(&"META-INF/container.xml".to_string()));
        assert!(names.contains(&"OEBPS/content.opf".to_string()));
        assert!(names.contains(&"OEBPS/toc.ncx".to_string()));
        assert!(names.contains(&"OEBPS/style.css".to_string()));
        assert!(names.contains(&"OEBPS/chapters/chapter_0.xhtml".to_string()));
        assert!(names.contains(&"OEBPS/chapters/chapter_1.xhtml".to_string()));
        assert!(names.contains(&"OEBPS/chapters/chapter_2.xhtml".to_string()));
    }

    #[test]
    fn test_export_epub_mimetype_first() {
        let data = sample_data();
        let config = default_config(ExportFormat::Epub);
        let result = BookExporter::export_epub(&data, &config).unwrap();

        let cursor = Cursor::new(result);
        let mut archive = zip::ZipArchive::new(cursor).unwrap();
        // 第一个文件必须是 mimetype
        let first = archive.by_index(0).unwrap();
        assert_eq!(first.name(), "mimetype");
    }

    #[test]
    fn test_export_epub_empty_chapters() {
        let data = ExportData {
            title: "空书".to_string(),
            author: "无名".to_string(),
            intro: None,
            chapters: vec![],
        };
        let config = default_config(ExportFormat::Epub);
        let result = BookExporter::export_epub(&data, &config).unwrap();

        // 仍然应该是有效的 ZIP
        let cursor = Cursor::new(result);
        let archive = zip::ZipArchive::new(cursor).unwrap();
        assert!(archive.len() >= 5); // mimetype + container + opf + ncx + css
    }

    #[test]
    fn test_export_html_basic() {
        let data = sample_data();
        let config = default_config(ExportFormat::Html);
        let result = BookExporter::export_html(&data, &config).unwrap();
        let html = String::from_utf8(result).unwrap();

        assert!(html.contains("<!DOCTYPE html>"));
        assert!(html.contains("<title>测试书籍</title>"));
        assert!(html.contains("<h1>测试书籍</h1>"));
        assert!(html.contains("作者：测试作者"));
        assert!(html.contains("第一章 开始"));
        assert!(html.contains("这是第一章的内容。"));
    }

    #[test]
    fn test_export_html_toc_links() {
        let data = sample_data();
        let config = default_config(ExportFormat::Html);
        let result = BookExporter::export_html(&data, &config).unwrap();
        let html = String::from_utf8(result).unwrap();

        assert!(html.contains("href=\"#chapter-0\""));
        assert!(html.contains("href=\"#chapter-1\""));
        assert!(html.contains("href=\"#chapter-2\""));
        assert!(html.contains("id=\"chapter-0\""));
        assert!(html.contains("id=\"chapter-1\""));
        assert!(html.contains("id=\"chapter-2\""));
    }

    #[test]
    fn test_export_html_special_characters_escaped() {
        let data = ExportData {
            title: "书<名>&\"引号\"".to_string(),
            author: "作者".to_string(),
            intro: None,
            chapters: vec![ExportChapter {
                index: 0,
                title: "章节<1>&测试".to_string(),
                content: "内容 <script>alert('xss')</script>".to_string(),
            }],
        };
        let config = default_config(ExportFormat::Html);
        let result = BookExporter::export_html(&data, &config).unwrap();
        let html = String::from_utf8(result).unwrap();

        // 特殊字符应被转义
        assert!(html.contains("书&lt;名&gt;&amp;&quot;引号&quot;"));
        assert!(html.contains("&lt;script&gt;"));
        // 不应有未转义的 script 标签
        assert!(!html.contains("<script>"));
    }

    #[test]
    fn test_export_html_no_toc() {
        let data = sample_data();
        let mut config = default_config(ExportFormat::Html);
        config.include_toc = false;
        let result = BookExporter::export_html(&data, &config).unwrap();
        let html = String::from_utf8(result).unwrap();

        assert!(!html.contains("class=\"toc\""));
    }

    #[test]
    fn test_export_large_text() {
        let large_content = "这是一段很长的文字。".repeat(10000);
        let data = ExportData {
            title: "大文本测试".to_string(),
            author: "作者".to_string(),
            intro: None,
            chapters: vec![ExportChapter {
                index: 0,
                title: "超长章节".to_string(),
                content: large_content,
            }],
        };

        // TXT
        let config = default_config(ExportFormat::Txt);
        let result = BookExporter::export_txt(&data, &config).unwrap();
        assert!(result.len() > 100_000);

        // HTML
        let config = default_config(ExportFormat::Html);
        let result = BookExporter::export_html(&data, &config).unwrap();
        assert!(result.len() > 100_000);

        // EPUB (compressed, so smaller)
        let config = default_config(ExportFormat::Epub);
        let result = BookExporter::export_epub(&data, &config).unwrap();
        assert!(result.len() > 1_000);
    }

    #[test]
    fn test_export_unified_interface() {
        let data = sample_data();

        let config = default_config(ExportFormat::Txt);
        let txt = BookExporter::export(&data, &config).unwrap();
        assert!(!txt.is_empty());

        let config = default_config(ExportFormat::Epub);
        let epub = BookExporter::export(&data, &config).unwrap();
        assert_eq!(epub[0], 0x50);

        let config = default_config(ExportFormat::Html);
        let html = BookExporter::export(&data, &config).unwrap();
        let html_str = String::from_utf8(html).unwrap();
        assert!(html_str.contains("<!DOCTYPE html>"));
    }

    #[test]
    fn test_export_format_from_str() {
        assert_eq!(ExportFormat::from_str("txt"), Some(ExportFormat::Txt));
        assert_eq!(ExportFormat::from_str("TXT"), Some(ExportFormat::Txt));
        assert_eq!(ExportFormat::from_str("epub"), Some(ExportFormat::Epub));
        assert_eq!(ExportFormat::from_str("EPUB"), Some(ExportFormat::Epub));
        assert_eq!(ExportFormat::from_str("html"), Some(ExportFormat::Html));
        assert_eq!(ExportFormat::from_str("HTML"), Some(ExportFormat::Html));
        assert_eq!(ExportFormat::from_str("pdf"), None);
        assert_eq!(ExportFormat::from_str(""), None);
    }

    #[test]
    fn test_export_format_extension_and_mime() {
        assert_eq!(ExportFormat::Txt.extension(), "txt");
        assert_eq!(ExportFormat::Epub.extension(), "epub");
        assert_eq!(ExportFormat::Html.extension(), "html");

        assert_eq!(ExportFormat::Txt.mime_type(), "text/plain");
        assert_eq!(ExportFormat::Epub.mime_type(), "application/epub+zip");
        assert_eq!(ExportFormat::Html.mime_type(), "text/html");
    }

    #[test]
    fn test_html_escape_function() {
        assert_eq!(html_escape("a & b"), "a &amp; b");
        assert_eq!(html_escape("<tag>"), "&lt;tag&gt;");
        assert_eq!(html_escape("\"quote\""), "&quot;quote&quot;");
        assert_eq!(html_escape("it's"), "it&#39;s");
    }

    #[test]
    fn test_xml_escape_function() {
        assert_eq!(xml_escape("a & b"), "a &amp; b");
        assert_eq!(xml_escape("<tag>"), "&lt;tag&gt;");
        assert_eq!(xml_escape("\"quote\""), "&quot;quote&quot;");
        assert_eq!(xml_escape("it's"), "it&apos;s");
    }
}
