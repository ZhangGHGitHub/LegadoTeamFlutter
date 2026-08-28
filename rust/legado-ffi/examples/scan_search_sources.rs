//! 搜索书源全量扫描诊断工具（真实网络，逐源记录成功/空/失败）
//!
//! 用法: cargo run --example scan_search_sources -- <db_path> <query|@query_file> <report_json> [urls_json_file]

use std::time::Instant;

fn read_query_arg(arg: &str) -> String {
    if let Some(path) = arg.strip_prefix('@') {
        std::fs::read_to_string(path).unwrap_or_else(|e| {
            eprintln!("读取 query 文件失败: {e}");
            std::process::exit(2);
        })
    } else {
        arg.to_string()
    }
    .trim()
    .to_string()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("用法: scan_search_sources <db_path> <query|@query_file> <report_json> [urls_json_file]");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
    let query = read_query_arg(&args[2]);
    if query.is_empty() {
        eprintln!("query 为空");
        std::process::exit(2);
    }
    let report_path = args[3].clone();
    let urls_json = if args.len() >= 5 {
        std::fs::read_to_string(&args[4]).unwrap_or_else(|e| {
            eprintln!("读取 urls json 失败: {e}");
            String::new()
        })
    } else {
        String::new()
    };

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

    let query_for_stream = query.clone();
    legado_ffi::runtime::block_on(async {
        legado_ffi::api::search::run_multi_stream(query_for_stream, urls_json, 1, |batch_json| {
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
    let mut cat_ok = 0usize;
    let mut cat_empty = 0usize;
    let mut cat_http = 0usize;
    let mut cat_timeout = 0usize;
    let mut cat_js = 0usize;
    let mut cat_parser = 0usize;
    let mut cat_other = 0usize;

    fn classify_error(err: &str) -> &'static str {
        let e = err.to_lowercase();
        if e.contains("超时") || e.contains("timeout") {
            "timeout"
        } else if e.contains("http") || e.contains("403") || e.contains("404") || e.contains("500") {
            "http_error"
        } else if e.contains("js") || e.contains("quickjs") || e.contains("legado-js") {
            "js_error"
        } else if e.contains("解析") || e.contains("parser") || e.contains("规则") {
            "parser_error"
        } else {
            "other_error"
        }
    }

    for r in &recs {
        if let Some(e) = &r.error {
            let key: String = e.chars().take(60).collect();
            *err_kinds.entry(key.clone()).or_default() += 1;
            match classify_error(e) {
                "timeout" => cat_timeout += 1,
                "http_error" => cat_http += 1,
                "js_error" => cat_js += 1,
                "parser_error" => cat_parser += 1,
                _ => cat_other += 1,
            }
        } else if r.books == 0 {
            cat_empty += 1;
        } else {
            cat_ok += 1;
        }
    }
    cat_ok = ok_count; // 与流式计数一致
    cat_empty = empty_count;

    println!("===== 分类汇总 ===== ok={} empty={} http={} timeout={} js={} parser={} other={}",
        cat_ok, cat_empty, cat_http, cat_timeout, cat_js, cat_parser, cat_other);
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
    if let Err(e) = std::fs::write(&report_path, serde_json::to_string_pretty(&serde_json::json!({
        "query": query,
        "summary": {
            "total_sources": recs.len(),
            "ok": cat_ok,
            "empty": cat_empty,
            "http_error": cat_http,
            "timeout": cat_timeout,
            "js_error": cat_js,
            "parser_error": cat_parser,
            "other_error": cat_other,
            "total_books": total_books,
            "wall_s": wall,
        },
        "sources": report,
    })).unwrap()) {
        eprintln!("报告写入失败: {e}");
    }
    println!("报告已写入: {}", report_path);
}