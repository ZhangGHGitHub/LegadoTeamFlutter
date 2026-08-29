//! 诊断：分阶段构建 @js: searchUrl（不发网络请求）
//!
//! 用法: cargo run --example dbg_build_url -- <db_copy_path> <query> <source_name_substring>

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 4 {
        eprintln!("用法: dbg_build_url <db_copy_path> <query> <source_name_substring>");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
    let query = args[2].clone();
    let name_filter = args[3].clone();

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

    let sources = match legado_ffi::api::source::list_enabled_sources() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("书源加载失败: {e}");
            std::process::exit(1);
        }
    };

    let mut found = 0usize;
    for source in &sources {
        if !source.book_source_name.contains(&name_filter) {
            continue;
        }
        found += 1;
        println!("===== {} =====", source.book_source_name);

        let template = match &source.search_url {
            Some(t) => t.clone(),
            None => continue,
        };
        let setup = legado_ffi::api::source_js_bindings::book_source_js_setup_script(source).ok();
        let js_lib = source.js_lib.clone();

        // ── 阶段 A：与 build_search_url_with_setup 相同的执行器 + 变量集 ──
        let executor = legado_ffi::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(js_lib.as_deref().map(|s| s.to_string()))
            .with_setup_script(setup.clone());

        let mut variables = std::collections::HashMap::new();
        variables.insert("key".to_string(), query.clone());
        variables.insert("page".to_string(), "1".to_string());
        variables.insert("baseUrl".to_string(), source.book_source_url.clone());
        variables.insert("searchKey".to_string(), query.clone());

        // 阶段 B：analyze_js_with_error（@js: 求值）
        let (processed, js_err) =
            legado_parser::AnalyzeUrl::analyze_js_with_error(&template, &executor, &variables);
        let b_err = js_err
            .as_ref()
            .map(|e| e.chars().take(300).collect::<String>())
            .unwrap_or_default();
        println!(
            "[B] js_err: {:?}",
            if b_err.is_empty() {
                "None".to_string()
            } else {
                b_err
            }
        );
        println!("[B] processed 尾600: {}", {
            let s: String = processed.chars().collect();
            s.char_indices()
                .skip(s.len().saturating_sub(600))
                .map(|(_, c)| c)
                .collect::<String>()
        });

        // 阶段 C：标准 parse
        match legado_parser::AnalyzeUrl::parse(&processed, &variables, 1) {
            Ok(analyzed) => {
                println!(
                    "[C] url(): {}",
                    analyzed.url().chars().take(200).collect::<String>()
                );
                println!(
                    "[C] method(): {:?} body: {}",
                    analyzed.method(),
                    analyzed
                        .request_body()
                        .chars()
                        .take(200)
                        .collect::<String>()
                );
            }
            Err(e) => println!("[C] parse 失败: {e}"),
        }

        // 阶段 D：完整 build_search_url_with_setup（生产路径）
        let full = legado_ffi::js_executor::build_search_url_with_setup(
            &template,
            &query,
            1,
            &source.book_source_url,
            js_lib.as_deref(),
            setup,
        );
        println!(
            "[D] full url(): {}",
            full.url().chars().take(200).collect::<String>()
        );
        println!(
            "[D] method(): {:?} body: {}",
            full.method(),
            full.request_body().chars().take(300).collect::<String>()
        );
    }
    if found == 0 {
        eprintln!("未找到匹配书源: {name_filter}");
        std::process::exit(1);
    }
}
