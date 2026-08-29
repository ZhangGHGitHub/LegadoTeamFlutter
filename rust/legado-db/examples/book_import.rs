//! 书籍数据导入示例：从 JSON 导入书源和书籍到数据库
//!
//! 运行方式：
//! ```bash
//! cd rust
//! cargo run --example book_import -p legado-db
//! ```

use legado_db::{init_in_memory_database, Database, RoomImporter};

fn main() {
    println!("=== Legado 书籍数据导入示例 ===\n");

    // === 1. 初始化数据库 ===
    println!("--- 初始化内存数据库 ---");
    let db = init_in_memory_database().expect("数据库初始化失败");
    println!("  数据库初始化成功（内存模式）");

    // === 2. 导入书源数据 ===
    println!("\n--- 导入书源 ---");
    let sources_json = r#"[
        {
            "bookSourceUrl": "https://www.example1.com",
            "bookSourceName": "示例书源一",
            "bookSourceGroup": "默认",
            "bookSourceType": 0,
            "enabled": 1,
            "enabledExplore": 1,
            "customOrder": 1
        },
        {
            "bookSourceUrl": "https://www.example2.com",
            "bookSourceName": "示例书源二",
            "bookSourceGroup": "精品",
            "bookSourceType": 0,
            "enabled": 1,
            "enabledExplore": 0,
            "customOrder": 2
        },
        {
            "bookSourceUrl": "https://www.example3.com",
            "bookSourceName": "示例书源三",
            "bookSourceGroup": "默认",
            "bookSourceType": 1,
            "enabled": 0,
            "enabledExplore": 0,
            "customOrder": 3
        }
    ]"#;

    let conn = db.connection();
    match RoomImporter::import_book_sources(conn, sources_json) {
        Ok(count) => println!("  成功导入 {} 个书源", count),
        Err(e) => println!("  导入失败: {}", e),
    }

    // === 3. 导入书籍数据 ===
    println!("\n--- 导入书籍 ---");
    let books_json = r#"[
        {
            "bookUrl": "https://www.example1.com/book/123",
            "name": "星辰大海",
            "author": "张三",
            "origin": "https://www.example1.com",
            "originName": "示例书源一",
            "kind": "科幻",
            "intro": "一个关于星际探索的故事",
            "wordCount": 1500000,
            "latestChapterTitle": "第500章 终点",
            "order": 1
        },
        {
            "bookUrl": "https://www.example2.com/book/456",
            "name": "江湖往事",
            "author": "李四",
            "origin": "https://www.example2.com",
            "originName": "示例书源二",
            "kind": "武侠",
            "intro": "一段江湖恩怨情仇",
            "wordCount": 800000,
            "latestChapterTitle": "第200章 归隐",
            "order": 2
        }
    ]"#;

    match RoomImporter::import_books(conn, books_json) {
        Ok(count) => println!("  成功导入 {} 本书籍", count),
        Err(e) => println!("  导入失败: {}", e),
    }

    // === 4. 验证导入结果 ===
    println!("\n--- 验证导入结果 ---");
    verify_import(&db);

    // === 5. 从文件导入（实际使用场景）===
    println!("\n--- 从文件导入（说明）---");
    println!("  实际使用时，可从以下来源导入：");
    println!("  1. Android 版 Legado 导出的 JSON 备份文件");
    println!("  2. 书源订阅链接（HTTP GET 获取 JSON）");
    println!("  3. 本地 JSON 文件（std::fs::read_to_string）");
    println!();
    println!("  示例代码：");
    println!("    let json = std::fs::read_to_string(\"backup.json\")?;");
    println!("    RoomImporter::import_book_sources(&conn, &json)?;");

    println!("\n=== 导入完成 ===");
}

/// 验证导入结果
fn verify_import(db: &Database) {
    let conn = db.connection();

    // 查询书源数量
    let source_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM book_sources", [], |row| row.get(0))
        .unwrap_or(0);
    println!("  书源总数: {}", source_count);

    // 查询书籍数量
    let book_count: i64 = conn
        .query_row("SELECT COUNT(*) FROM books", [], |row| row.get(0))
        .unwrap_or(0);
    println!("  书籍总数: {}", book_count);

    // 列出书源名称
    let mut stmt = conn
        .prepare(
            "SELECT book_source_name, book_source_group FROM book_sources ORDER BY custom_order",
        )
        .unwrap();
    let sources = stmt
        .query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .unwrap();

    println!("  书源列表:");
    for source in sources {
        let (name, group) = source.unwrap();
        println!("    - {} [{}]", name, group.unwrap_or_default());
    }
}
