//! 诊断：哔哩哔哩搜索响应解析（bookList 复合规则分步求值）
//!
//! 用法: cargo run --example dbg_bili_parse -- <db_copy_path> <query>
//! 需要 --features quickjs

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("用法: dbg_bili_parse <db_copy_path> <query>");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
    let query = args[2].clone();

    let out_path = std::path::Path::new(&db_path)
        .parent()
        .map(|p| p.join("dbg_bili_parse_out.txt"))
        .unwrap_or_else(|| std::path::PathBuf::from("dbg_bili_parse_out.txt"));
    let mut out = String::new();

    let rt = tokio::runtime::Runtime::new().expect("tokio runtime");
    rt.block_on(async {
        run(&db_path, &query, &mut out).await;
    });
    let _ = std::fs::write(&out_path, &out);
    println!("done; wrote {}", out_path.display());
}

async fn run(db_path: &str, query: &str, out: &mut String) {
    macro_rules! w {
        ($($t:tt)*) => {{ let s = format!($($t)*); out.push_str(&s); out.push_str("\n"); }}
    }

    // 1. DB + bili 书源
    let _ = legado_ffi::db_state::record_db_path(db_path);
    let db = match legado_ffi::legado_db::init_database(db_path) {
        Ok(d) => d,
        Err(e) => {
            w!("DB open err: {e}");
            return;
        }
    };
    if let Err(e) = legado_ffi::db_state::init_database(db) {
        w!("db init err: {e}");
        return;
    }
    let sources = match legado_ffi::api::source::list_enabled_sources() {
        Ok(v) => v,
        Err(e) => {
            w!("sources err: {e}");
            return;
        }
    };
    let Some(source) = sources
        .iter()
        .find(|s| s.book_source_name.contains("哔哩哔哩"))
        .cloned()
    else {
        w!("bili source not found");
        return;
    };
    w!("source: {}", source.book_source_name);

    // 2. 构建搜索 URL（生产路径）
    let setup = legado_ffi::api::source_js_bindings::book_source_js_setup_script(&source).ok();
    let js_lib = source.js_lib.clone();
    let template = match &source.search_url {
        Some(t) => t.clone(),
        None => {
            w!("no searchUrl");
            return;
        }
    };
    let analyzed = legado_ffi::js_executor::build_search_url_with_setup(
        &template,
        query,
        1,
        &source.book_source_url,
        js_lib.as_deref(),
        setup,
    );
    w!("URL: {}", analyzed.url());

    // 3. HTTP GET
    let client = match legado_net::client::LegadoClient::new(Default::default()) {
        Ok(c) => c,
        Err(e) => {
            w!("client err: {e}");
            return;
        }
    };
    let resp = match client.get(analyzed.url(), None).await {
        Ok(r) => r,
        Err(e) => {
            w!("GET err: {e}");
            return;
        }
    };
    w!("HTTP {} body_len={}", resp.status, resp.body.len());
    let resp_path = std::path::Path::new(db_path)
        .parent()
        .map(|p| p.join("dbg_bili_response.json"))
        .unwrap_or_default();
    let _ = std::fs::write(&resp_path, &resp.body);

    // 4. AnalyzeRule：分步求值 bookList 复合规则
    let analyzer = legado_ffi::js_executor::construct_analyzer_with_js_lib(
        resp.body.clone(),
        analyzed.url().to_string(),
        &source.book_source_url,
        js_lib.as_deref(),
    );

    let sub_rules: Vec<&str> = vec![
        "$.data.result[*].data[*]",
        "$.data.result.live_user[*]",
        "$.data.result.live_room[*]",
        "$.data.result[*]",
    ];
    for sr in &sub_rules {
        match analyzer.get_elements(sr) {
            Ok(els) => w!("[{}] -> {} elements", sr, els.len()),
            Err(e) => w!("[{}] ERR: {e}", sr),
        }
    }

    let full = "$.data.result[*].data[*]&&$.data.result.live_user[*]&&$.data.result.live_room[*]||$.data.result[*]";
    match analyzer.get_elements(full) {
        Ok(els) => {
            w!("[FULL bookList] -> {} elements", els.len());
            for (i, el) in els.iter().take(3).enumerate() {
                let t: String = el.chars().take(120).collect();
                w!("  [{}] {}", i, t);
            }
        }
        Err(e) => w!("[FULL] ERR: {e}"),
    }

    // 5. 首个元素字段求值（name/author/bookUrl）
    if let Ok(els) = analyzer.get_elements(full) {
        if let Some(first_el) = els.first() {
            let mut item = legado_ffi::js_executor::construct_analyzer_with_js_lib(
                String::new(),
                analyzed.url().to_string(),
                &source.book_source_url,
                js_lib.as_deref(),
            );
            item.set_element_content(first_el.clone());
            let rules: Vec<(&str, &str)> = vec![
                ("name", "$.title||$.uname##</*em.*?>"),
                ("author", "$.author||$.uname##</*em.*?>"),
                (
                    "bookUrl-base",
                    "https://api.bilibili.com/x/web-interface/view?aid={{$.id}}",
                ),
            ];
            for (fname, rule) in &rules {
                match item.get_string(rule) {
                    Ok(s) => w!(
                        "[field {}] => {}",
                        fname,
                        s.chars().take(150).collect::<String>()
                    ),
                    Err(e) => w!("[field {}] ERR: {e}", fname),
                }
            }
        }
    }
}
