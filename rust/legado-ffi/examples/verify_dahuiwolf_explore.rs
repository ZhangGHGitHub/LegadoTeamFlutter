//! 真实大灰狼聚合 exploreUrl 回归（从导出 JSON 读取 jsLib + exploreUrl）

use legado_core::explore::ExploreCategory;
use legado_core::models::BookSource;
use legado_ffi::api::explore_api::explore_parse_url;
use std::fs;

fn main() {
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "tmp_dahui_agg.json".to_string());
    let text = fs::read_to_string(&path).expect("read json");
    let arr: Vec<serde_json::Value> = serde_json::from_str(&text).expect("parse array");
    let raw = &arr[0];
    let mut source = BookSource::default();
    source.book_source_url = raw["bookSourceUrl"].as_str().unwrap_or("").to_string();
    source.book_source_name = raw["bookSourceName"].as_str().unwrap_or("").to_string();
    source.js_lib = raw["jsLib"].as_str().map(|s| s.to_string());
    source.explore_url = raw["exploreUrl"].as_str().map(|s| s.to_string());
    source.enabled = true;
    source.enabled_explore = true;

    let explore_url = source.explore_url.clone().unwrap_or_default();
    let source_json = serde_json::to_string(&source).expect("serialize source");
    let json = explore_parse_url(&explore_url, &source_json).unwrap_or_else(|e| {
        eprintln!("FAIL explore: {e}");
        std::process::exit(1);
    });
    if json.contains("host is not defined") {
        eprintln!("FAIL host error: {json}");
        std::process::exit(1);
    }
    let cats: Vec<ExploreCategory> = serde_json::from_str(&json).unwrap_or_default();
    if cats.is_empty() {
        eprintln!("FAIL empty: {json}");
        std::process::exit(1);
    }
    if let Some(err) = cats.iter().find(|c| c.title == "ERROR") {
        eprintln!("FAIL ERROR: {}", err.url.as_deref().unwrap_or(""));
        std::process::exit(1);
    }
    println!("PASS {} categories", cats.len());
    for c in cats.iter().take(12) {
        println!(
            " - {} [{}]",
            c.title,
            &c.r#type
        );
    }
}
