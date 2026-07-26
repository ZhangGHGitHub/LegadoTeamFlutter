//! EPUB 格式解析模块
//!
//! EPUB 本质是 ZIP 压缩包，内含 XHTML/HTML 章节、CSS、图片及元数据文件。
//! 解析流程：
//! 1. 读取 `META-INF/container.xml` 获取 OPF 文件路径
//! 2. 解析 OPF：获取元数据（metadata）、资源清单（manifest）、阅读顺序（spine）
//! 3. 解析 NCX（EPUB2）或 NAV（EPUB3）获取目录结构
//! 4. 按 spine 顺序提取各章节 HTML 并转换为纯文本

use std::collections::HashMap;
use std::fs::File;
use std::io::Read;

use quick_xml::events::Event;
use quick_xml::Reader;
use zip::ZipArchive;

use legado_core::{LegadoError, LegadoResult};

use crate::{BookFormat, BookMetadata, ChapterInfo};

/// EPUB 解析器
pub struct EpubParser;

// ---------------------------------------------------------------------------
// OPF / Manifest / Spine 内部结构
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
struct OpfData {
    /// metadata
    title: String,
    creator: String,
    description: String,
    /// manifest: id -> (href, media_type)
    manifest: HashMap<String, (String, String)>,
    /// spine: idref 列表（阅读顺序）
    spine: Vec<String>,
    /// toc id (NCX 文件在 manifest 中的 id)
    toc_id: Option<String>,
    /// OPF 文件在 ZIP 中的目录前缀（含尾部 '/'）
    base_path: String,
}

// ---------------------------------------------------------------------------
// 公开接口
// ---------------------------------------------------------------------------

impl EpubParser {
    /// 解析 EPUB 文件元数据
    pub fn parse(path: &str) -> LegadoResult<BookMetadata> {
        let file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;
        let mut archive = ZipArchive::new(file)
            .map_err(|e| LegadoError::BookParse(format!("ZIP 打开失败: {e}")))?;

        let opf = read_opf(&mut archive)?;
        Ok(BookMetadata {
            title: opf.title,
            author: opf.creator,
            description: opf.description,
            format: BookFormat::Epub,
            cover: None, // TODO: 提取封面图片
        })
    }

    /// 获取章节列表（按 spine 顺序）
    pub fn get_chapters(path: &str) -> LegadoResult<Vec<ChapterInfo>> {
        let file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;
        let mut archive = ZipArchive::new(file)
            .map_err(|e| LegadoError::BookParse(format!("ZIP 打开失败: {e}")))?;

        let opf = read_opf(&mut archive)?;

        // 尝试解析 NCX 获取带标题的目录
        let toc_titles = read_ncx_titles(&mut archive, &opf).unwrap_or_default();

        let mut chapters = Vec::new();
        let mut idx = 0i32;
        for idref in &opf.spine {
            if let Some((href, _)) = opf.manifest.get(idref) {
                let full_href = normalize_path(&opf.base_path, href);
                let title = toc_titles
                    .get(&strip_fragment(href))
                    .cloned()
                    .unwrap_or_else(|| format!("Chapter {}", idx + 1));
                chapters.push(ChapterInfo {
                    url: full_href,
                    title,
                    index: idx,
                    is_volume: false,
                    start: None,
                    end: None,
                });
                idx += 1;
            }
        }
        Ok(chapters)
    }

    /// 获取章节正文内容（HTML → 纯文本）
    pub fn get_chapter_content(path: &str, chapter: &ChapterInfo) -> LegadoResult<String> {
        let file =
            File::open(path).map_err(|e| LegadoError::BookParse(format!("无法打开文件: {e}")))?;
        let mut archive = ZipArchive::new(file)
            .map_err(|e| LegadoError::BookParse(format!("ZIP 打开失败: {e}")))?;

        let zip_path = chapter.url.replace('\\', "/");
        let html = read_zip_entry(&mut archive, &zip_path)?;
        Ok(html_to_text(&html))
    }
}

// ---------------------------------------------------------------------------
// 内部辅助函数
// ---------------------------------------------------------------------------

/// 从 META-INF/container.xml 获取 OPF 路径，并解析 OPF
fn read_opf<R: Read + std::io::Seek>(archive: &mut ZipArchive<R>) -> LegadoResult<OpfData> {
    // 1. 读取 container.xml
    let container_xml = read_zip_entry(archive, "META-INF/container.xml")?;
    let opf_path = parse_container_xml(&container_xml)?;

    // 2. 计算 OPF 所在目录
    let base_path = opf_path
        .rsplit_once('/')
        .map(|(dir, _)| format!("{dir}/"))
        .unwrap_or_default();

    // 3. 读取并解析 OPF
    let opf_xml = read_zip_entry(archive, &opf_path)?;
    parse_opf_xml(&opf_xml, base_path)
}

/// 解析 container.xml，返回 OPF 文件路径
fn parse_container_xml(xml: &str) -> LegadoResult<String> {
    let mut reader = Reader::from_str(xml);
    let mut buf = Vec::new();
    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Empty(ref e)) | Ok(Event::Start(ref e))
                if e.local_name().as_ref() == b"rootfile" =>
            {
                for attr in e.attributes().flatten() {
                    if attr.key.as_ref() == b"full-path" {
                        return Ok(String::from_utf8_lossy(&attr.value).to_string());
                    }
                }
            }
            Ok(Event::Eof) => break,
            _ => {}
        }
        buf.clear();
    }
    Err(LegadoError::BookParse(
        "container.xml 中未找到 rootfile".into(),
    ))
}

/// 解析 OPF XML，提取 metadata / manifest / spine
fn parse_opf_xml(xml: &str, base_path: String) -> LegadoResult<OpfData> {
    let mut reader = Reader::from_str(xml);
    let mut buf = Vec::new();
    let mut data = OpfData {
        base_path,
        ..Default::default()
    };

    // 状态机
    let mut in_metadata = false;
    let mut in_manifest = false;
    let mut in_spine = false;
    let mut current_tag: Option<String> = None;
    let mut text_buf = String::new();

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                match local.as_str() {
                    "metadata" => in_metadata = true,
                    "manifest" => in_manifest = true,
                    "spine" => {
                        in_spine = true;
                        // 获取 toc 属性（EPUB2 NCX 引用）
                        for attr in e.attributes().flatten() {
                            if attr.key.as_ref() == b"toc" {
                                data.toc_id =
                                    Some(String::from_utf8_lossy(&attr.value).to_string());
                            }
                        }
                    }
                    _ if in_metadata => {
                        current_tag = Some(local);
                        text_buf.clear();
                    }
                    _ => {}
                }
            }
            Ok(Event::Empty(ref e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if in_manifest && local == "item" {
                    let mut id = String::new();
                    let mut href = String::new();
                    let mut media_type = String::new();
                    for attr in e.attributes().flatten() {
                        match attr.key.as_ref() {
                            b"id" => id = String::from_utf8_lossy(&attr.value).to_string(),
                            b"href" => href = String::from_utf8_lossy(&attr.value).to_string(),
                            b"media-type" => {
                                media_type = String::from_utf8_lossy(&attr.value).to_string()
                            }
                            _ => {}
                        }
                    }
                    if !id.is_empty() {
                        data.manifest.insert(id, (href, media_type));
                    }
                } else if in_spine && local == "itemref" {
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == b"idref" {
                            data.spine
                                .push(String::from_utf8_lossy(&attr.value).to_string());
                        }
                    }
                }
            }
            Ok(Event::Text(ref e)) => {
                if current_tag.is_some() {
                    text_buf.push_str(&e.unescape().unwrap_or_default());
                }
            }
            Ok(Event::End(ref e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if in_metadata {
                    if let Some(ref tag) = current_tag {
                        match tag.as_str() {
                            "title" => data.title = text_buf.trim().to_string(),
                            "creator" => data.creator = text_buf.trim().to_string(),
                            "description" => data.description = text_buf.trim().to_string(),
                            _ => {}
                        }
                        current_tag = None;
                        text_buf.clear();
                    }
                    if local == "metadata" {
                        in_metadata = false;
                    }
                }
                if local == "manifest" {
                    in_manifest = false;
                }
                if local == "spine" {
                    in_spine = false;
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(LegadoError::BookParse(format!("OPF XML 解析错误: {e}")));
            }
            _ => {}
        }
        buf.clear();
    }
    Ok(data)
}

/// 读取 NCX 文件，返回 href → title 映射
fn read_ncx_titles<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    opf: &OpfData,
) -> LegadoResult<HashMap<String, String>> {
    let ncx_href = opf
        .toc_id
        .as_ref()
        .and_then(|id| opf.manifest.get(id))
        .map(|(href, _)| normalize_path(&opf.base_path, href))
        .ok_or_else(|| LegadoError::BookParse("未找到 NCX 文件引用".into()))?;

    let ncx_xml = read_zip_entry(archive, &ncx_href)?;
    parse_ncx_xml(&ncx_xml)
}

/// 解析 NCX XML，提取 navPoint 标题与 src
fn parse_ncx_xml(xml: &str) -> LegadoResult<HashMap<String, String>> {
    let mut reader = Reader::from_str(xml);
    let mut buf = Vec::new();
    let mut map = HashMap::new();

    let mut in_nav_label = false;
    let mut in_text = false;
    let mut current_title = String::new();
    let mut current_src: Option<String> = None;

    loop {
        match reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if local == "navLabel" {
                    in_nav_label = true;
                } else if in_nav_label && local == "text" {
                    in_text = true;
                    current_title.clear();
                }
            }
            Ok(Event::Text(ref e)) if in_text => {
                current_title.push_str(&e.unescape().unwrap_or_default());
            }
            Ok(Event::Empty(ref e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if local == "content" {
                    for attr in e.attributes().flatten() {
                        if attr.key.as_ref() == b"src" {
                            current_src = Some(String::from_utf8_lossy(&attr.value).to_string());
                        }
                    }
                }
            }
            Ok(Event::End(ref e)) => {
                let local = String::from_utf8_lossy(e.local_name().as_ref()).to_string();
                if local == "text" {
                    in_text = false;
                } else if local == "navLabel" {
                    in_nav_label = false;
                } else if local == "navPoint" {
                    if let Some(ref src) = current_src {
                        let key = strip_fragment(src);
                        let title = current_title.trim().to_string();
                        if !title.is_empty() {
                            map.insert(key, title);
                        }
                    }
                    current_src = None;
                    current_title.clear();
                }
            }
            Ok(Event::Eof) => break,
            _ => {}
        }
        buf.clear();
    }
    Ok(map)
}

/// 读取 ZIP 中指定路径的文本内容
fn read_zip_entry<R: Read + std::io::Seek>(
    archive: &mut ZipArchive<R>,
    name: &str,
) -> LegadoResult<String> {
    let name_norm = name.replace('\\', "/");
    let mut entry = archive
        .by_name(&name_norm)
        .map_err(|_| LegadoError::BookParse(format!("ZIP 中未找到: {name_norm}")))?;
    let mut content = String::new();
    entry
        .read_to_string(&mut content)
        .map_err(|e| LegadoError::BookParse(format!("读取 ZIP 条目失败: {e}")))?;
    Ok(content)
}

/// HTML → 纯文本（简易转换，去除标签并解码常见实体）
fn html_to_text(html: &str) -> String {
    // 去除 <script> 和 <style> 块
    let re_script = regex::Regex::new(r"(?is)<script[^>]*>.*?</script>").unwrap();
    let re_style = regex::Regex::new(r"(?is)<style[^>]*>.*?</style>").unwrap();
    let mut text = re_script.replace_all(html, "").to_string();
    text = re_style.replace_all(&text, "").to_string();

    // 将 <br>, <p>, <div>, <h1>~<h6> 替换为换行
    let re_block = regex::Regex::new(r"(?i)</?(p|div|h[1-6]|br|hr|li|tr)[^>]*>").unwrap();
    text = re_block.replace_all(&text, "\n").to_string();

    // 去除所有剩余 HTML 标签
    let re_tag = regex::Regex::new(r"<[^>]+>").unwrap();
    text = re_tag.replace_all(&text, "").to_string();

    // 解码常见 HTML 实体
    text = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'");

    // 合并多个连续空行
    let re_multi_nl = regex::Regex::new(r"\n{3,}").unwrap();
    text = re_multi_nl.replace_all(&text, "\n\n").to_string();
    text.trim().to_string()
}

/// 拼接 OPF 相对路径
fn normalize_path(base: &str, href: &str) -> String {
    if href.starts_with('/') || href.contains(':') {
        href.to_string()
    } else {
        format!("{base}{href}")
    }
}

/// 去除 URL 中的 fragment（# 后缀）
fn strip_fragment(href: &str) -> String {
    href.split('#').next().unwrap_or(href).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_html_to_text_basic() {
        let html = "<p>Hello <b>World</b></p>";
        let text = html_to_text(html);
        assert!(text.contains("Hello"));
        assert!(text.contains("World"));
    }

    #[test]
    fn test_html_to_text_removes_script_style() {
        let html = r#"<p>Content</p><script>alert('x')</script><style>body{}</style><p>More</p>"#;
        let text = html_to_text(html);
        assert!(text.contains("Content"));
        assert!(text.contains("More"));
        assert!(!text.contains("alert"));
        assert!(!text.contains("body"));
    }

    #[test]
    fn test_html_to_text_block_elements_to_newlines() {
        let html = "<p>First</p><p>Second</p><div>Third</div>";
        let text = html_to_text(html);
        assert!(text.contains("First"));
        assert!(text.contains("Second"));
        assert!(text.contains("Third"));
        // Should have newlines between blocks
        assert!(text.contains('\n'));
    }

    #[test]
    fn test_html_to_text_entities() {
        let html = "Hello&nbsp;World &amp; Friends &lt;tag&gt; &quot;quoted&quot; &#39;apos&#39;";
        let text = html_to_text(html);
        assert!(text.contains("Hello World"));
        assert!(text.contains("& Friends"));
        assert!(text.contains("<tag>"));
        assert!(text.contains("\"quoted\""));
    }

    #[test]
    fn test_html_to_text_collapses_blank_lines() {
        let html = "<p>A</p><br><br><br><br><p>B</p>";
        let text = html_to_text(html);
        // Should not have 3+ consecutive newlines
        assert!(!text.contains("\n\n\n"));
    }

    #[test]
    fn test_normalize_path_relative() {
        assert_eq!(
            normalize_path("OEBPS/", "chapter1.xhtml"),
            "OEBPS/chapter1.xhtml"
        );
    }

    #[test]
    fn test_normalize_path_absolute() {
        assert_eq!(
            normalize_path("OEBPS/", "/chapter1.xhtml"),
            "/chapter1.xhtml"
        );
    }

    #[test]
    fn test_normalize_path_with_scheme() {
        assert_eq!(
            normalize_path("OEBPS/", "https://example.com/ch1"),
            "https://example.com/ch1"
        );
    }

    #[test]
    fn test_strip_fragment_with_hash() {
        assert_eq!(strip_fragment("chapter1.xhtml#section1"), "chapter1.xhtml");
    }

    #[test]
    fn test_strip_fragment_without_hash() {
        assert_eq!(strip_fragment("chapter1.xhtml"), "chapter1.xhtml");
    }

    #[test]
    fn test_parse_container_xml_valid() {
        let xml = r#"<?xml version="1.0"?>
<container version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"#;
        let result = parse_container_xml(xml).unwrap();
        assert_eq!(result, "OEBPS/content.opf");
    }

    #[test]
    fn test_parse_container_xml_missing_rootfile() {
        let xml = r#"<?xml version="1.0"?><container version="1.0"></container>"#;
        assert!(parse_container_xml(xml).is_err());
    }
}
