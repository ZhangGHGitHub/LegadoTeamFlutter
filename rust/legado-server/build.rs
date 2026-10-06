//! 构建脚本：把 `web-dist/` 下的原版 Web 资产编译期嵌入为静态表
//!
//! 为什么编译期嵌入：设备（Android/iOS）运行时没有仓库工作目录保证，
//! `web-dist` 这类相对路径资源目录在设备上并不存在 —— 只能靠 `include_bytes!`
//! 把整套资产打进二进制（与 Android 原版把 `app/src/main/assets/web/**`
//! 打进 assets 由 `AssetsWeb` 只读吐出的分发方式同构）。
//!
//! 生成物：`$OUT_DIR/web_assets_table.rs`，形如
//! `pub static ASSETS: &[(&str, &[u8], &str)]`（第三列 MIME），由
//! `src/web_assets.rs` 以 `include!` 引入。
//!
//! MIME 由扩展名映射；未知扩展名给 `application/octet-stream`。
//! 原版 `AssetsWeb.kt:33-44` 的 MIME 表只有 5 条且其余一律 `text/html`
//! （png/woff/ttf 都被误标），本表按「浏览器实际渲染结果一致」修正为正确
//! 类型（产品语义等价，非缺陷复刻）：`.js` 保持原版的 `text/javascript`。

use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir =
        PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let web_dist = manifest_dir.join("web-dist");

    // 资产变更触发重建（目录递归跟踪 + 逐文件显式声明，双保险）
    println!("cargo:rerun-if-changed=web-dist");
    println!("cargo:rerun-if-changed=build.rs");

    let mut assets: Vec<String> = Vec::new();
    walk(&web_dist, &web_dist, &mut assets).unwrap_or_else(|e| {
        panic!("遍历 web-dist 失败: {e}");
    });
    assets.sort();

    for rel in &assets {
        println!("cargo:rerun-if-changed=web-dist/{rel}");
    }

    let mut table = String::new();
    table.push_str("// 由 build.rs 生成，勿手改：web-dist/ 静态资产表（路径, 内容, MIME）\n");
    table.push_str("pub static ASSETS: &[(&str, &[u8], &str)] = &[\n");
    for rel in &assets {
        let mime = mime_for(rel);
        table.push_str(&format!(
            "    ({:?}, include_bytes!(concat!(env!(\"CARGO_MANIFEST_DIR\"), \"/web-dist/{}\")), {:?}),\n",
            rel, rel, mime
        ));
    }
    table.push_str("];\n");

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").expect("OUT_DIR"));
    fs::write(out_dir.join("web_assets_table.rs"), table).expect("写入 web_assets_table.rs 失败");
}

/// 递归收集相对路径（统一使用 `/` 分隔，作为资产表键）
fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) -> std::io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            walk(root, &path, out)?;
        } else {
            let rel = path
                .strip_prefix(root)
                .expect("路径应在 web-dist 下")
                .to_string_lossy()
                .replace('\\', "/");
            out.push(rel);
        }
    }
    Ok(())
}

/// 扩展名 → MIME（原版 5 条已知类型保持原值，其余按标准类型修正）
fn mime_for(rel: &str) -> &'static str {
    let ext = rel
        .rsplit('.')
        .next()
        .filter(|e| !e.contains('/'))
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
        // 原版 AssetsWeb.kt 已定义的类型（逐字保持）
        "html" | "htm" => "text/html",
        "js" => "text/javascript",
        "css" => "text/css",
        "ico" => "image/x-icon",
        "jpg" | "jpeg" => "image/jpg",
        // 原版未定义（原实现一律回 text/html，属缺陷）：按标准类型修正
        "png" => "image/png",
        "svg" => "image/svg+xml",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "json" | "map" => "application/json",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "otf" => "font/otf",
        "eot" => "application/vnd.ms-fontobject",
        "txt" => "text/plain",
        "md" => "text/markdown",
        "xml" => "application/xml",
        "wasm" => "application/wasm",
        // 未知扩展名
        _ => "application/octet-stream",
    }
}
