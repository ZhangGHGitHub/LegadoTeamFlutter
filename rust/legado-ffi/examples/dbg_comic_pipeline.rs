//! 漫画/图片源全链路诊断（真实网络）：搜索 → 目录 → 正文，逐步打印真实 LegadoError。
//!
//! 用法: cargo run --features quickjs --example dbg_comic_pipeline \
//!     -- <sources_json> <书源名子串> <搜索词> [book_url]
//!
//! book_url 缺省时取搜索结果第一条；用于定位「大部分图片源目录/正文获取失败」的真实错误。

use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("用法: dbg_comic_pipeline <sources_json> <书源名子串> <搜索词> [book_url]");
        std::process::exit(2);
    }
    let sources_path = &args[1];
    let src_name = &args[2];
    let query = &args[3];
    let explicit_book_url = args.get(4).cloned();

    let raw = std::fs::read_to_string(sources_path).unwrap_or_else(|e| {
        eprintln!("读取书源文件失败: {e}");
        std::process::exit(2);
    });
    let arr: Vec<serde_json::Value> = serde_json::from_str(&raw).unwrap_or_else(|e| {
        eprintln!("书源 JSON 解析失败: {e}");
        std::process::exit(2);
    });
    let src = arr
        .iter()
        .find(|s| {
            s.get("bookSourceName")
                .and_then(|n| n.as_str())
                .is_some_and(|n| n.contains(src_name))
        })
        .unwrap_or_else(|| {
            eprintln!("未找到书源: {src_name}");
            std::process::exit(2);
        });
    let source_json = serde_json::to_string(src).unwrap();
    println!(
        "[diag] 书源: {} | type={} | main_js={}",
        src["bookSourceName"],
        src.get("bookSourceType").cloned().unwrap_or_default(),
        src.get("mainJs")
            .is_some_and(|m| m.as_str().is_some_and(|s| !s.trim().is_empty()))
    );

    // ── 1) 搜索 ──
    let t0 = Instant::now();
    let book_url = match legado_ffi::api::web_book::webbook_search(&source_json, query, 1) {
        Ok(json) => {
            println!(
                "[search] OK {}ms，结果 JSON 前 400 字: {}",
                t0.elapsed().as_millis(),
                json.chars().take(400).collect::<String>()
            );
            if explicit_book_url.is_some() {
                explicit_book_url.unwrap()
            } else {
                let results: Vec<serde_json::Value> =
                    serde_json::from_str(&json).unwrap_or_default();
                if results.is_empty() {
                    eprintln!("[search] 空结果（无书籍）");
                    std::process::exit(1);
                }
                results[0]["book_url"]
                    .as_str()
                    .or_else(|| results[0]["bookUrl"].as_str())
                    .unwrap_or("")
                    .to_string()
            }
        }
        Err(e) => {
            println!("[search] ERR ({}ms): {}", t0.elapsed().as_millis(), e);
            std::process::exit(1);
        }
    };
    if book_url.is_empty() {
        eprintln!("[search] 首条结果无 bookUrl");
        std::process::exit(1);
    }
    println!("[diag] bookUrl: {book_url}");

    // ── 2) 目录 ──
    let t0 = Instant::now();
    let chapters_json = match legado_ffi::api::web_book::webbook_chapters(
        &source_json,
        &book_url,
        "",
        "",
    ) {
        Ok(json) => {
            println!(
                "[toc] OK {}ms，章节数={}",
                t0.elapsed().as_millis(),
                serde_json::from_str::<Vec<serde_json::Value>>(&json)
                    .map(|v| v.len())
                    .unwrap_or(0)
            );
            json
        }
        Err(e) => {
            println!("[toc] ERR ({}ms): {}", t0.elapsed().as_millis(), e);
            std::process::exit(1);
        }
    };
    let chapters: Vec<serde_json::Value> =
        serde_json::from_str(&chapters_json).unwrap_or_default();
    if chapters.is_empty() {
        eprintln!("[toc] 空章节列表");
        std::process::exit(1);
    }

    // ── 3) 正文（第 2 章优先，首章常是目录页/公告）──
    let ch = if chapters.len() > 1 { &chapters[1] } else { &chapters[0] };
    println!(
        "[diag] 章节: {} | url={}",
        ch.get("title").and_then(|t| t.as_str()).unwrap_or("?"),
        ch.get("url").and_then(|u| u.as_str()).unwrap_or("")
    );
    let chapter_json = serde_json::to_string(ch).unwrap();
    let t0 = Instant::now();
    match legado_ffi::api::web_book::webbook_content(&source_json, &chapter_json) {
        Ok(content) => {
            println!(
                "[content] OK {}ms，长度={}，前 300 字: {}",
                t0.elapsed().as_millis(),
                content.len(),
                content.chars().take(300).collect::<String>()
            );
        }
        Err(e) => {
            println!("[content] ERR ({}ms): {}", t0.elapsed().as_millis(), e);
            std::process::exit(1);
        }
    }
}
