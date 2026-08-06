//! legado-db 集成测试
//! 完整 CRUD 流程 + 迁移测试

use legado_core::models::{Book, BookChapter};
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::Repository;
use legado_db::{BookChapterRepository, Database, MigrationRegistry, SCHEMA_VERSION};

// ---------------------------------------------------------------------------
// 回归：更新书籍进度不得清空章节目录（ON DELETE CASCADE 级联删除缺陷）
// Task#125 P0：复现并守护 book.update() 曾用 INSERT OR REPLACE
// 删除 books 行 → 触发 chapters ON DELETE CASCADE → 翻章后目录被清空
// ---------------------------------------------------------------------------

#[test]
fn test_update_book_preserves_chapters() {
    let db = Database::open_in_memory().unwrap();
    let conn = db.connection();
    let repo = BookRepository::new(conn);
    let chapter_repo = BookChapterRepository::new(conn);

    let book_url = "https://example.com/online-book";

    // 1. 入库一本在线书
    let book = Book {
        book_url: book_url.to_string(),
        name: "灵气复苏".to_string(),
        author: "作者".to_string(),
        origin: "https://source.com".to_string(),
        total_chapter_num: 3,
        ..Book::default()
    };
    repo.insert(&book).unwrap();

    // 2. 写入目录（3 章）
    let chapters: Vec<BookChapter> = (0..3)
        .map(|i| BookChapter {
            url: format!("{book_url}/ch{i}"),
            title: format!("第{}章", i + 1),
            book_url: book_url.to_string(),
            index: i,
            ..BookChapter::default()
        })
        .collect();
    chapter_repo.insert_batch(&chapters).unwrap();
    assert_eq!(chapter_repo.count_by_book_url(book_url).unwrap(), 3);

    // 3. 模拟翻章保存进度 → repo.update()
    let mut progressed = repo.find_by_url(book_url).unwrap().unwrap();
    progressed.dur_chapter_index = 1;
    progressed.dur_chapter_pos = 42;
    repo.update(&progressed).unwrap();

    // 4. 关键断言：章节目录必须完整保留（修复前此处会变成 0）
    assert_eq!(
        chapter_repo.count_by_book_url(book_url).unwrap(),
        3,
        "update() 不得级联删除章节目录"
    );
    // 第 2 章仍可按 index 命中（对应“章节不存在”缺陷）
    assert!(chapter_repo
        .find_by_book_url_and_index(book_url, 1)
        .unwrap()
        .is_some());
    // 进度已写回
    let after = repo.find_by_url(book_url).unwrap().unwrap();
    assert_eq!(after.dur_chapter_index, 1);
    assert_eq!(after.dur_chapter_pos, 42);
}

// ---------------------------------------------------------------------------
// 完整书籍生命周期 CRUD
// ---------------------------------------------------------------------------

#[test]
fn test_full_book_lifecycle() {
    // 1. 打开内存数据库（自动迁移到最新版本）
    let db = Database::open_in_memory().unwrap();
    assert_eq!(db.get_version().unwrap(), SCHEMA_VERSION);

    let conn = db.connection();
    let repo = BookRepository::new(conn);

    // 2. 初始为空
    assert_eq!(repo.count().unwrap(), 0);
    assert!(repo.find_all().unwrap().is_empty());

    // 3. 插入第一本书
    let book1 = Book {
        book_url: "https://example.com/book1".to_string(),
        name: "三体".to_string(),
        author: "刘慈欣".to_string(),
        origin: "loc_book".to_string(),
        ..Book::default()
    };
    repo.insert(&book1).unwrap();
    assert_eq!(repo.count().unwrap(), 1);

    // 4. 插入第二本书
    let book2 = Book {
        book_url: "https://example.com/book2".to_string(),
        name: "活着".to_string(),
        author: "余华".to_string(),
        origin: "loc_book".to_string(),
        ..Book::default()
    };
    repo.insert(&book2).unwrap();
    assert_eq!(repo.count().unwrap(), 2);

    // 5. 按 URL 查询单本书
    let found = repo.find_by_url("https://example.com/book1").unwrap();
    assert!(found.is_some());
    let found = found.unwrap();
    assert_eq!(found.name, "三体");
    assert_eq!(found.author, "刘慈欣");
    assert_eq!(found.book_url, "https://example.com/book1");

    // 6. 按名称+作者查询
    let found = repo.find_by_name_author("活着", "余华").unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().book_url, "https://example.com/book2");

    // 7. 获取全部书籍
    let all = repo.find_all().unwrap();
    assert_eq!(all.len(), 2);

    // 8. 更新第一本书（upsert）
    let updated_book1 = Book {
        book_url: "https://example.com/book1".to_string(),
        name: "三体（全集）".to_string(),
        author: "刘慈欣".to_string(),
        origin: "loc_book".to_string(),
        total_chapter_num: 100,
        ..Book::default()
    };
    repo.update(&updated_book1).unwrap();

    // 9. 验证更新后数据
    let found = repo
        .find_by_url("https://example.com/book1")
        .unwrap()
        .unwrap();
    assert_eq!(found.name, "三体（全集）");
    assert_eq!(found.total_chapter_num, 100);
    assert_eq!(repo.count().unwrap(), 2); // 总数不变

    // 10. 删除第一本书
    repo.delete("https://example.com/book1").unwrap();
    assert_eq!(repo.count().unwrap(), 1);
    assert!(repo
        .find_by_url("https://example.com/book1")
        .unwrap()
        .is_none());

    // 11. 删除第二本书
    repo.delete_by_url("https://example.com/book2").unwrap();
    assert_eq!(repo.count().unwrap(), 0);
    assert!(repo.find_all().unwrap().is_empty());
}

// ---------------------------------------------------------------------------
// 带 ReadConfig 的书籍 CRUD
// ---------------------------------------------------------------------------

#[test]
fn test_book_with_read_config_lifecycle() {
    let db = Database::open_in_memory().unwrap();
    let conn = db.connection();
    let repo = BookRepository::new(conn);

    // 插入带 readConfig 的书籍
    let mut book = Book {
        book_url: "config-book".to_string(),
        name: "配置测试".to_string(),
        author: "作者".to_string(),
        ..Book::default()
    };
    book.read_config = Some(legado_core::models::ReadConfig {
        reverse_toc: true,
        play_mode: 1,
        ..legado_core::models::ReadConfig::default()
    });
    repo.insert(&book).unwrap();

    // 查询并验证 readConfig
    let found = repo.find_by_url("config-book").unwrap().unwrap();
    assert!(found.read_config.is_some());
    let rc = found.read_config.unwrap();
    assert!(rc.reverse_toc);
    assert_eq!(rc.play_mode, 1);

    // 更新 readConfig 中的 playMode
    repo.update_audio_play_mode("config-book", 3).unwrap();
    let found = repo.find_by_url("config-book").unwrap().unwrap();
    assert_eq!(found.read_config.as_ref().unwrap().play_mode, 3);
    // reverse_toc 不受影响
    assert!(found.read_config.unwrap().reverse_toc);
}

// ---------------------------------------------------------------------------
// 从 v90 迁移到最新版本
// ---------------------------------------------------------------------------

/// 辅助函数：创建 v90 状态的内存数据库（最小化 schema）
fn create_v90_database() -> Database {
    let db = Database::open_in_memory_raw().unwrap();
    let conn = db.connection();

    // v90 的 book_sources 表（不含 mainJs 列）
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS book_sources (
            bookSourceUrl TEXT NOT NULL,
            bookSourceName TEXT NOT NULL,
            bookSourceGroup TEXT,
            bookSourceType INTEGER NOT NULL,
            bookUrlPattern TEXT,
            customOrder INTEGER NOT NULL DEFAULT 0,
            enabled INTEGER NOT NULL DEFAULT 1,
            enabledExplore INTEGER NOT NULL DEFAULT 1,
            jsLib TEXT,
            enabledCookieJar INTEGER DEFAULT 0,
            concurrentRate TEXT,
            header TEXT,
            loginUrl TEXT,
            loginUi TEXT,
            loginCheckJs TEXT,
            coverDecodeJs TEXT,
            bookSourceComment TEXT,
            variableComment TEXT,
            lastUpdateTime INTEGER NOT NULL,
            respondTime INTEGER NOT NULL,
            weight INTEGER NOT NULL,
            exploreUrl TEXT,
            exploreScreen TEXT,
            ruleExplore TEXT,
            searchUrl TEXT,
            ruleSearch TEXT,
            ruleBookInfo TEXT,
            ruleToc TEXT,
            ruleContent TEXT,
            ruleReview TEXT,
            eventListener INTEGER NOT NULL DEFAULT 0,
            customButton INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(bookSourceUrl)
        );",
    )
    .unwrap();

    // v90 的 books 表（最小化）
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS books (
            bookUrl TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            PRIMARY KEY(bookUrl)
        );",
    )
    .unwrap();

    // 设置版本为 v90
    conn.pragma_update(None, "user_version", 90).unwrap();
    db
}

/// 辅助函数：检查列是否存在
fn column_exists(conn: &rusqlite::Connection, table: &str, column: &str) -> bool {
    let sql = format!("PRAGMA table_info({table})");
    let mut stmt = conn.prepare(&sql).unwrap();
    let result = stmt
        .query_map([], |row| {
            let name: String = row.get(1)?;
            Ok(name == column)
        })
        .unwrap()
        .filter_map(|r| r.ok())
        .any(|b| b);
    result
}

/// 辅助函数：检查表是否存在
fn table_exists(conn: &rusqlite::Connection, table: &str) -> bool {
    let count: i32 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?",
            [table],
            |row| row.get(0),
        )
        .unwrap();
    count > 0
}

#[test]
fn test_migration_from_v90() {
    let db = create_v90_database();
    let conn = db.connection();

    // 验证 v90 状态
    let version = MigrationRegistry::current_version(conn).unwrap();
    assert_eq!(version, 90);
    assert!(!column_exists(conn, "book_sources", "mainJs"));
    assert!(!table_exists(conn, "auto_task_rules"));

    // 执行迁移到最新版本
    let registry = MigrationRegistry::new();
    registry.migrate_to_latest(conn).unwrap();

    // 验证版本号
    let new_version = MigrationRegistry::current_version(conn).unwrap();
    assert_eq!(new_version, SCHEMA_VERSION);

    // 验证 v91 新增的 mainJs 列
    assert!(column_exists(conn, "book_sources", "mainJs"));

    // 验证 v94 新增的 auto_task_rules 表
    assert!(table_exists(conn, "auto_task_rules"));
}

#[test]
fn test_migration_preserves_existing_data() {
    let db = create_v90_database();
    let conn = db.connection();

    // 在 v90 状态下插入数据
    conn.execute(
        "INSERT INTO book_sources (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        rusqlite::params!["https://source1.com", "测试书源", 0, 0, 0, 0],
    )
    .unwrap();

    let count: i32 = conn
        .query_row("SELECT COUNT(*) FROM book_sources", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 1);

    // 执行迁移
    let registry = MigrationRegistry::new();
    registry.migrate_to_latest(conn).unwrap();

    // 验证数据保留
    let count_after: i32 = conn
        .query_row("SELECT COUNT(*) FROM book_sources", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count_after, 1);

    // 验证新增列可以使用
    let name: String = conn
        .query_row(
            "SELECT bookSourceName FROM book_sources WHERE bookSourceUrl = ?1",
            ["https://source1.com"],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(name, "测试书源");
}
