//! WebDAV 云同步示例：配置、上传、下载、目录列表
//!
//! 运行方式：
//! ```bash
//! cd rust
//! cargo run --example webdav_sync -p legado-net
//! ```
//!
//! 注意：需要配置真实的 WebDAV 服务器地址才能执行同步操作。

use legado_net::webdav::{WebDavClient, WebDavConfig};

#[tokio::main]
async fn main() {
    println!("=== Legado WebDAV 云同步示例 ===\n");

    // === 1. 配置 WebDAV 连接 ===
    let config = WebDavConfig {
        url: "https://dav.example.com".to_string(),
        username: "user@example.com".to_string(),
        password: "your-password".to_string(),
        remote_dir: "/legado/backup/".to_string(),
    };

    println!("WebDAV 配置:");
    println!("  服务器: {}", config.url);
    println!("  用户: {}", config.username);
    println!("  远程目录: {}", config.remote_dir);

    let client = WebDavClient::new(config);

    // === 2. 列出远程目录 ===
    println!("\n--- 列出远程文件 ---");
    match client.list_dir("/").await {
        Ok(files) => {
            println!("  共 {} 个文件/目录:", files.len());
            for file in &files {
                let type_tag = if file.is_dir { "[目录]" } else { "[文件]" };
                println!("    {} {} ({} bytes)", type_tag, file.name, file.size);
            }
        }
        Err(e) => {
            println!("  列表失败（需要真实服务器）: {}", e);
            println!("  示例输出:");
            println!("    [目录] books/");
            println!("    [目录] sources/");
            println!("    [文件] backup_20260730.json (1024 bytes)");
        }
    }

    // === 3. 创建目录 ===
    println!("\n--- 创建远程目录 ---");
    match client.mkdir("books/imported/").await {
        Ok(_) => println!("  目录创建成功"),
        Err(e) => println!("  创建失败（需要真实服务器）: {}", e),
    }

    // === 4. 上传文件（备份数据）===
    println!("\n--- 上传备份文件 ---");
    let backup_data = r#"{
        "version": "2.0",
        "timestamp": "2026-07-30T12:00:00Z",
        "bookSources": [],
        "books": [],
        "rssSources": []
    }"#;

    match client
        .put("backup_20260730.json", backup_data.as_bytes())
        .await
    {
        Ok(_) => println!("  上传成功: backup_20260730.json"),
        Err(e) => println!("  上传失败（需要真实服务器）: {}", e),
    }

    // === 5. 下载文件（恢复数据）===
    println!("\n--- 下载备份文件 ---");
    match client.get("backup_20260730.json").await {
        Ok(data) => {
            let content = String::from_utf8_lossy(&data);
            println!("  下载成功，内容长度: {} bytes", data.len());
            println!("  预览: {}", &content[..content.len().min(100)]);
        }
        Err(e) => println!("  下载失败（需要真实服务器）: {}", e),
    }

    // === 6. 删除文件 ===
    println!("\n--- 删除远程文件 ---");
    match client.delete("old_backup.json").await {
        Ok(_) => println!("  删除成功"),
        Err(e) => println!("  删除失败（需要真实服务器）: {}", e),
    }

    println!("\n=== 同步流程说明 ===");
    println!("  1. 上传同步: 本地数据 → JSON 序列化 → PUT 到 WebDAV");
    println!("  2. 下载同步: GET 远程文件 → JSON 反序列化 → 写入本地数据库");
    println!("  3. 增量同步: 比较 ETag/Last-Modified → 仅传输变更文件");
    println!("  4. 冲突处理: 以时间戳较新的版本为准，旧版本重命名保留");
}
