//! 诊断：对指定文件运行 jslib_normalize::normalize，写出结果
//
// 用法: cargo run --example dbg_norm --features quickjs -- <in.js> <out.js>

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("用法: dbg_norm <in.js> <out.js>");
        std::process::exit(2);
    }
    let src = std::fs::read_to_string(&args[1]).unwrap();
    let (out, changed) = legado_js::jslib_normalize::normalize(&src);
    println!("changed={}", changed);
    std::fs::write(&args[2], &out).unwrap();
}
