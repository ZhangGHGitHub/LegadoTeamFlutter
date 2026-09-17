//! 真实书源「🏷松鹤庭沐·言璃」exploreUrl（@js: 脚本，返回发现页 UI JSON 数组）回归
//!
//! 用法：`cargo run -p legado-ffi --example dbg_songhe_explore --features quickjs -- legado-ffi/tmp_songhe.json`
//! （在 rust/ 目录下运行；不传参时默认读 cwd 下 tmp_songhe.json）

use legado_core::explore::ExploreCategory;
use legado_core::models::BookSource;
use legado_ffi::api::explore_api::explore_parse_url;
use std::fs;

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "tmp_songhe.json".to_string());
    let text = fs::read_to_string(&path).expect("read json");

    // 直接从导出 JSON 得到真实 BookSource（camelCase 键，与 Dart toJson 一致）
    let source: BookSource = serde_json::from_str(&text).expect("parse BookSource");
    eprintln!(
        "[dbg_songhe] source: {} | url: {}",
        source.book_source_name, source.book_source_url
    );
    eprintln!(
        "[dbg_songhe] explore_url 前缀: {}",
        source
            .explore_url
            .as_deref()
            .unwrap_or("<none>")
            .chars()
            .take(40)
            .collect::<String>()
    );
    eprintln!(
        "[dbg_songhe] jsLib: {}",
        if source.js_lib.as_ref().is_some_and(|s| !s.trim().is_empty()) {
            format!("present ({} bytes)", source.js_lib.as_ref().unwrap().len())
        } else {
            "absent".to_string()
        }
    );

    let explore_url = source.explore_url.clone().unwrap_or_default();
    let source_json = serde_json::to_string(&source).expect("serialize source");

    match explore_parse_url(&explore_url, &source_json) {
        Ok(json) => {
            println!("=== RAW (first 3000 chars) ===");
            let truncated: String = json.chars().take(3000).collect();
            println!("{truncated}");
            if json.len() > 3000 {
                println!("... (total {} chars)", json.len());
            }

            let cats: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap_or_default();
            println!("=== PARSED {} categories ===", cats.len());
            for (i, c) in cats.iter().enumerate() {
                println!(
                    "{i:>3} - title={:?} type={:?} url_len={}",
                    c.title,
                    c.r#type,
                    c.url.as_ref().map(|u| u.len()).unwrap_or(0)
                );
            }
            if let Some(err) = cats.iter().find(|c| c.title == "ERROR") {
                eprintln!("FAIL ERROR category: {}", err.url.as_deref().unwrap_or(""));
                std::process::exit(1);
            }
            if cats.is_empty() {
                eprintln!("FAIL empty: {json}");
                std::process::exit(1);
            }
            eprintln!("PASS {} categories", cats.len());
        }
        Err(e) => {
            eprintln!("FAIL explore_parse_url: {e}");
            std::process::exit(1);
        }
    }
}
