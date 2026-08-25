//! 搜索书源全量扫描诊断工具（真实网络，逐源记录成功/空/失败）
//!
//! 用法: cargo run --example scan_search_sources -- <db_copy_path> <query> <report_json_path>

use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("用法: scan_search_sources <db_copy_path> <query> <report_json_path>");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
    let query = args[2].clone();
    let report_path = args[3].clone();

    // 初始化数据库（与 App 启动同路径：record_db_path + init_database）
    legado_ffi::db_state::record_db_path(&db_path);
    let db = match legado_ffi::legado_db::init_database(&db_path) {
        Ok(d) => d,
        Err(e) => { eprintln!("DB 打开失败: {e}"); std::process::exit(1); }
    };
    if let Err(e) = legado_ffi::db_state::init_database(db) {
        eprintln!("全局 DB 初始化失败: {e}");
        std::process::exit(1);
    }
    // 恢复自定义 hosts（与 App 启动一致）
    legado_ffi::api::net_api::restore_custom_hosts();

    // 诊断：直接查询启用书源数量
    match legado_ffi::api::source::list_enabled_sources() {
        Ok(v) => println!("[diag] list_enabled_sources = {}", v.len()),
        Err(e) => eprintln!("[diag] list_enabled_sources ERR: {e}"),
    }

    #[derive(Default)]
    struct Rec {
        name: String,
        url: String,
        books: usize,
        error: Option<String>,
        elapsed_s: f64,
    }

    let t0 = Instant::now();
    let mut recs: Vec<Rec> = Vec::new();
    let mut ok_count = 0usize;
    let mut empty_count = 0usize;
    let mut err_count = 0usize;
    let mut total_books = 0usize;

    legado_ffi::runtime::block_on(async {
        legado_ffi::api::search::run_multi_stream(query, String::new(), 1, |batch_json| {
            let v: serde_json::Value = serde_json::from_str(&batch_json).unwrap_or_default();
            let name = v["source_name"].as_str().unwrap_or("").to_string();
            let url = v["source_url"].as_str().unwrap_or("").to_string();
            let err = v["error"].as_str().map(|s| s.to_string());
            let nbooks = v["books"].as_array().map(|a| a.len()).unwrap_or(0);
            let el = t0.elapsed().as_secs_f64();

            if err.is_none() {
                if nbooks > 0 { ok_count += 1; } else { empty_count += 1; }
            } else { err_count += 1; }
            total_books += nbooks;

            println!("[{:7.2}s] #{} {} books={} err={}",
                el,
                recs.len() + 1,
                name,
                nbooks,
                err.as_deref().unwrap_or("")
            );
            recs.push(Rec { name, url, books: nbooks, error: err, elapsed_s: el });
            Ok(())
        })
        .await;
    });

    let wall = t0.elapsed().as_secs_f64();
    println!("===== 汇总 ===== 总书源={} ok={} empty={} err={} 总书籍={} 墙钟={:.1}s",
        recs.len(), ok_count, empty_count, err_count, total_books, wall
    );

    let mut err_kinds: std::collections::BTreeMap<String, usize> = std::collections::BTreeMap::new();
    for r in &recs {
        if let Some(e) = &r.error {
            let key: String = e.chars().take(60).collect();
            *err_kinds.entry(key.clone()).or_default() += 1;
        }
    }
    println!("===== 错误分类（前 60 字符聚合，Top25）=====");
    for (k, c) in err_kinds.iter().take(25) {
        println!("{} x {}", c, k);
    }

    let report: Vec<serde_json::Value> = recs
        .iter()
        .map(|r| {
            serde_json::json!({
                "name": r.name,
                "url": r.url,
                "books": r.books,
                "error": r.error,
                "elapsed_s": r.elapsed_s,
            })
        })
        .collect();
    if let Err(e) = std::fs::write(&report_path, serde_json::to_string_pretty(&report).unwrap()) {
        eprintln!("报告写入失败: {e}");
    }
    println!("报告已写入: {}", report_path);
}