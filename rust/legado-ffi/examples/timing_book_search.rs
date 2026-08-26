//! 速度诊断：书源（快速分组）搜索逐请求分段计时（真实网络）
//!
//! 用法: cargo run --example timing_book_search -- <db_copy_path> [urls_json_file]
//! - urls_json_file 可选：JSON 数组（书源 URL 列表）限定搜索范围；缺省搜全部启用源
//! - 关键词硬编码为「斗破苍穹」（规避 pwsh CLI 中文编码问题），与原版 App 对比基准一致
//! - 结果写 UTF-8 文件 timing_book_out.txt（stdout 仅 ASCII 摘要，避免 pwsh 5.1 乱码）

use std::time::{Duration, Instant};

const QUERY: &str = "斗破苍穹";

fn main() {
    // 必须先于任何 legado-net 请求设置环境变量（timing_enabled 内部 OnceLock 缓存）
    std::env::set_var("LEGADO_NET_TIMING", "1");

    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: timing_book_search <db_copy_path> [urls_json_file]");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
    let urls_json = if args.len() >= 3 {
        std::fs::read_to_string(&args[2]).unwrap_or_else(|e| {
            eprintln!("read urls list failed: {e}");
            String::new()
        })
    } else {
        String::new()
    };
    // 关键词：第 3 个参数为 UTF-8 文本文件路径（规避 pwsh CLI 中文编码问题）；缺省「斗破苍穹」
    let query: String = if args.len() >= 4 {
        std::fs::read_to_string(&args[3]).unwrap_or_else(|e| {
            eprintln!("read query file failed: {e}");
            String::new()
        })
    } else {
        "斗破苍穹".to_string()
    };
    if query.trim().is_empty() {
        eprintln!("query is empty; abort");
        std::process::exit(2);
    }

    // 初始化数据库（与 App 启动一致）
    legado_ffi::db_state::record_db_path(&db_path);
    let db = match legado_ffi::legado_db::init_database(&db_path) {
        Ok(d) => d,
        Err(e) => { eprintln!("DB open failed: {e}"); std::process::exit(1); }
    };
    if let Err(e) = legado_ffi::db_state::init_database(db) {
        eprintln!("global DB init failed: {e}");
        std::process::exit(1);
    }
    legado_ffi::api::net_api::restore_custom_hosts();

    let t0 = Instant::now();
    let mut batch_lines: Vec<String> = Vec::new();

    legado_ffi::runtime::block_on(async {
        legado_ffi::api::search::run_multi_stream(query.clone(), urls_json, 1, |batch_json| {
            let v: serde_json::Value = serde_json::from_str(&batch_json).unwrap_or_default();
            let name = v["source_name"].as_str().unwrap_or("").to_string();
            let url = v["source_url"].as_str().unwrap_or("").to_string();
            let err = v["error"].as_str().map(|s| s.to_string());
            let nbooks = v["books"].as_array().map(|a| a.len()).unwrap_or(0);
            let el = t0.elapsed().as_secs_f64();
            batch_lines.push(format!("{:08.3}\t{}\t{}\tbooks={}\terr={}", el, name, url, nbooks, err.as_deref().unwrap_or("")));
            // 实时进度（ASCII，避免控制台乱码）：elapsed/books/err/url
            eprintln!("[batch] t={:.2}s books={} err={} url={}", el, nbooks, err.as_deref().unwrap_or(""), url);
            Ok(())
        })
        .await;
    });

    let wall = t0.elapsed().as_secs_f64();

    // 取请求计时记录（take 后清空）
    let reqs = legado_net::timing::take_requests();

    // 去重 host（含 scheme → 端口），用于 TCP 探针
    let mut hosts: Vec<(String, u16)> = Vec::new();
    for r in &reqs {
        let port = if r.url.starts_with("https://") { 443 } else { 80 };
        let key = (r.host.clone(), port);
        if !hosts.contains(&key) {
            hosts.push(key);
        }
    }

    // TCP v4/v6 分族连接探针（独立于搜索，仅诊断）；LEGADO_NET_TIMING_PROBES=1 才执行
    let mut probe_lines: Vec<String> = Vec::new();
    let do_probes = std::env::var("LEGADO_NET_TIMING_PROBES").map(|v| v == "1").unwrap_or(false);
    if do_probes {
    legado_ffi::runtime::block_on(async {
        for (host, port) in &hosts {
            let p = legado_net::timing::probe_tcp_connect(host, *port, Duration::from_secs(5)).await;
            probe_lines.push(format!("{}\t{}\tv4_ms={}\tv6_ms={}",
                host, port,
                p.v4_ms.map(|v| format!("{v:.1}")).unwrap_or_else(|| "none".into()),
                p.v6_ms.map(|v| format!("{v:.1}")).unwrap_or_else(|| "none".into())));
        }
    });
    }

    // 汇总到 UTF-8 文件
    let mut out = String::new();
    out.push_str(&format!("==== BATCHES ({:.2}s) ====\n", wall));
    for l in &batch_lines { out.push_str(l); out.push('\n'); }
    out.push_str("\n==== REQUEST_TIMING ====\n");
    out.push_str("host\tdns_ms\tdns_v4\tdns_v6\tttfb_ms\tbody_ms\ttotal_ms\tremote\turl\n");
    for r in &reqs {
        out.push_str(&format!("{}\t{}\t{}\t{}\t{:.3}\t{:.3}\t{:.3}\t{}\t{}\n",
            r.host,
            r.dns_ms.map(|v| format!("{v:.3}")).unwrap_or_else(|| "na".into()),
            r.dns_v4, r.dns_v6, r.ttfb_ms, r.body_ms, r.total_ms,
            r.remote_ip.map(|s| s.to_string()).unwrap_or_else(|| "na".into()),
            r.url));
    }
    out.push_str("\n==== TCP_PROBE ====\n");
    out.push_str("host\tport\tv4_ms\tv6_ms\n");
    for l in &probe_lines { out.push_str(l); out.push('\n'); }

    let out_path = "timing_book_out.txt";
    if let Err(e) = std::fs::write(out_path, &out) {
        eprintln!("write output failed: {e}");
        std::process::exit(1);
    }

    // stdout 仅 ASCII 摘要
    println!("wall={:.2}s batches={} requests={} hosts={} -> {}",
        wall, batch_lines.len(), reqs.len(), hosts.len(), out_path);
}
