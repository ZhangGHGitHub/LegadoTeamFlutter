//! 基础使用示例：书籍格式检测、元数据解析、章节读取
//!
//! 运行方式：
//! ```bash
//! cd rust
//! cargo run --example basic_usage -p legado-book
//! ```

use legado_book::{BookFormat, BookMetadata, ChapterInfo, LocalBook};

fn main() {
    // === 1. 格式检测 ===
    let test_files = [
        "novel.epub",
        "story.txt",
        "comic.mobi",
        "doc.pdf",
        "book.umd",
    ];

    println!("=== 书籍格式检测 ===");
    for file in &test_files {
        match LocalBook::detect_format(file) {
            Ok(format) => println!("  {} → {:?}", file, format),
            Err(e) => println!("  {} → 错误: {}", file, e),
        }
    }

    // === 2. 解析书籍元数据 ===
    // 注意：需要真实文件路径才能解析成功
    println!("\n=== 元数据解析 ===");
    let sample_path = "sample.epub"; // 替换为实际文件路径
    match LocalBook::parse(sample_path) {
        Ok(metadata) => {
            print_metadata(&metadata);
        }
        Err(e) => {
            println!("  解析失败（示例需要真实文件）: {}", e);
            // 展示元数据结构
            let demo = BookMetadata {
                title: "示例书籍".to_string(),
                author: "作者名".to_string(),
                description: "这是一本示例书籍的简介".to_string(),
                format: BookFormat::Epub,
                cover: None,
            };
            print_metadata(&demo);
        }
    }

    // === 3. 获取章节列表 ===
    println!("\n=== 章节列表 ===");
    match LocalBook::get_chapters(sample_path) {
        Ok(chapters) => {
            println!("  共 {} 章", chapters.len());
            for ch in chapters.iter().take(5) {
                print_chapter(ch);
            }
        }
        Err(e) => {
            println!("  获取失败（示例需要真实文件）: {}", e);
            // 展示章节结构
            let demo_chapters = vec![
                ChapterInfo {
                    url: "chapter1.xhtml".to_string(),
                    title: "第一章 起始".to_string(),
                    index: 0,
                    is_volume: false,
                    start: None,
                    end: None,
                },
                ChapterInfo {
                    url: "chapter2.xhtml".to_string(),
                    title: "第二章 旅途".to_string(),
                    index: 1,
                    is_volume: false,
                    start: None,
                    end: None,
                },
            ];
            for ch in &demo_chapters {
                print_chapter(ch);
            }
        }
    }

    // === 4. 读取章节内容 ===
    println!("\n=== 章节内容 ===");
    let chapter = ChapterInfo {
        url: "chapter1.xhtml".to_string(),
        title: "第一章".to_string(),
        index: 0,
        is_volume: false,
        start: Some(0),
        end: Some(1000),
    };
    match LocalBook::get_chapter_content(sample_path, &chapter) {
        Ok(content) => {
            let preview: String = content.chars().take(200).collect();
            println!("  内容预览: {}...", preview);
        }
        Err(e) => {
            println!("  读取失败（示例需要真实文件）: {}", e);
        }
    }

    println!("\n=== 支持的格式 ===");
    let formats = [
        BookFormat::Epub,
        BookFormat::Mobi,
        BookFormat::Txt,
        BookFormat::Pdf,
        BookFormat::Umd,
    ];
    for fmt in &formats {
        println!("  {}", fmt.as_str());
    }
}

/// 打印书籍元数据
fn print_metadata(meta: &BookMetadata) {
    println!("  书名: {}", meta.title);
    println!("  作者: {}", meta.author);
    println!("  格式: {:?}", meta.format);
    println!("  简介: {}", meta.description);
    println!("  封面: {}", if meta.cover.is_some() { "有" } else { "无" });
}

/// 打印章节信息
fn print_chapter(ch: &ChapterInfo) {
    let volume_tag = if ch.is_volume { " [卷]" } else { "" };
    println!("  #{} {}{}", ch.index, ch.title, volume_tag);
}
