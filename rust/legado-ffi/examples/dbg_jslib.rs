//! 诊断：哔哩哔哩 jsLib 加载问题定位
//!
//! 用法: cargo run --example dbg_jslib --features quickjs -- <db_copy_path>

fn main() {
    use legado_parser::JsExecutor;
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        eprintln!("用法: dbg_jslib <db_copy_path>");
        std::process::exit(2);
    }
    let db_path = args[1].clone();
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

    let bili = sources
        .iter()
        .find(|s| s.book_source_name.contains("哔哩哔哩"));
    let Some(bili) = bili else {
        eprintln!("未找到哔哩哔哩书源");
        std::process::exit(1);
    };
    let jslib = bili.js_lib.clone().unwrap_or_default();

    // 测试 A：原样求值
    match legado_ffi::js_executor::QuickJsExecutor::new("test-a")
        .with_js_lib(Some(jslib.clone()))
        .execute_js("1+1")
    {
        Ok(v) => println!("[A] 原样加载: OK ({v})"),
        Err(e) => println!("[A] 原样加载: ERR {e}"),
    }

    // 测试 B：最小复现 —— let 重声明参数名
    let minimal = "function f(bu){ let x,y = \"\"; let bu = 1; return bu; }\nf(2)";
    match legado_ffi::js_executor::QuickJsExecutor::new("test-b").execute_js(minimal) {
        Ok(v) => println!("[B] 最小复现(let重声明参数): OK ({v})"),
        Err(e) => println!("[B] 最小复现(let重声明参数): ERR {e}"),
    }

    // 测试 C：jsLib 挖掉 showCom（L94-L119）后求值
    let lines: Vec<&str> = jslib.lines().collect();
    let mut patched = String::new();
    for (i, line) in lines.iter().enumerate() {
        let ln = i + 1;
        // 注意：.tmp_bili_jslib.txt 首行是 JSLIB_LEN 头，实际 jsLib 中 showCom 位于 L93-L118
        if ln >= 93 && ln <= 118 {
            if ln == 93 {
                patched.push_str("function showCom(bu){ return 0; } // showCom 已挖空（诊断）\n");
            }
            continue;
        }
        patched.push_str(line);
        patched.push('\n');
    }
    match legado_ffi::js_executor::QuickJsExecutor::new("test-c")
        .with_js_lib(Some(patched.clone()))
        .execute_js("1+1")
    {
        Ok(v) => println!("[C] 挖空showCom后: OK ({v})"),
        Err(e) => println!("[C] 挖空showCom后: ERR {e}"),
    }

    // 测试 D：挖空 showCom 后，getWbiEnc 是否可用（模拟 searchUrl @js:）
    match legado_ffi::js_executor::QuickJsExecutor::new("test-d")
        .with_js_lib(Some(patched))
        .execute_js("typeof getWbiEnc + ' / ' + typeof getSearchOrder")
    {
        Ok(v) => println!("[D] WBI 函数可见性: {v}"),
        Err(e) => println!("[D] WBI 函数可见性: ERR {e}"),
    }

    // 测试 E：修补版 jsLib（let bu→bu_shim + 删孤立 }）
    if let Ok(patched_file) = std::fs::read_to_string(r"../.tmp_bili_jslib_final.js") {
        match legado_ffi::js_executor::QuickJsExecutor::new("test-e")
            .with_js_lib(Some(patched_file))
            .execute_js("typeof getWbiEnc + ' / ' + typeof showCom + ' / ' + typeof parseContent")
        {
            Ok(v) => println!("[E] 最终修补jsLib: OK ({v})"),
            Err(e) => println!("[E] 最终修补jsLib: ERR {e}"),
        }
    } else {
        eprintln!("[E] 未找到 .tmp_bili_jslib_final.js");
    }
}
