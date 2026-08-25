//! 速度诊断：仅搜索「影视频源」组，逐批记录墙钟时间（真实网络）
//!
//! 用法: cargo run --example timing_video_search -- <db_copy_path> <query> <urls_json_file>
//! urls_json_file：JSON 数组（书源 URL 列表），限定搜索范围

use std::time::Instant;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("用法: timing_video_search <db_copy_path> <query> <urls_json_file>");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
    let query = args[2].clone();
    let urls_json = std::fs::read_to_string(&args[3]).unwrap_or_else(|e| {
        eprintln!("读取 URL 列表失败: {e}");
        std::process::exit(1);
    });

    // 初始化数据库（与 App 启动一致）
    legado_ffi::db_state::record_db_path(&db_path);
    let db = match legado_ffi::legado_db::init_database(&db_path) {
        Ok(d) => d,
        Err(e) => {
            eprintln!("DB 打开失败: {e}");
            std::process::exit(1);
        }
    };
    if let Err(e) = legado_ffi::db_state::init_database(db) {
        eprintln!("全局 DB 初始化失败: {e}");
        std::process::exit(1);
    }
    legado_ffi::api::net_api::restore_custom_hosts();

    let t0 = Instant::now();
    let mut batches: Vec<(f64, String, usize, Option<String>)> = Vec::new();

    legado_ffi::runtime::block_on(async {
        legado_ffi::api::search::run_multi_stream(query.clone(), urls_json, 1, |batch_json| {
            let v: serde_json::Value = serde_json::from_str(&batch_json).unwrap_or_default();
            let name = v["source_name"].as_str().unwrap_or("").to_string();
            let err = v["error"].as_str().map(|s| s.to_string());
            let nbooks = v["books"].as_array().map(|a| a.len()).unwrap_or(0);
            let el = t0.elapsed().as_secs_f64();
            println!("[{el:7.3}s] {} books={} err={}", name, nbooks, err.as_deref().unwrap_or(""));
            batches.push((el, name, nbooks, err));
            Ok(())
        })
        .await;
    });

    let wall = t0.elapsed().as_secs_f64();
    println!("===== 汇总 ===== 批次={} 总墙钟={:.2}s", batches.len(), wall);
}
