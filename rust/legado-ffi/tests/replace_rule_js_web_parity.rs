//! [批17] 替换规则 `@js:` App / Web 一致性集成测试
//!
//! 核心断言：同一规则、同一输入下，App 阅读端（FFI
//! `apply_content_processing_chapter_with_context`）与 Web 阅读端
//! （`legado_server` 的 `/getBookContent`）输出**完全一致**。
//!
//! 覆盖：
//! 1. `@js:` 真实执行（含 `chapter`/`book` 全字段绑定）；
//! 2. `@js:` 抛错 → 两端保留原文，后续普通规则仍生效；
//! 3. `@js:` 超时 → 两端保留原文；
//! 4. 无 quickjs feature → 两端都不执行 `@js:`，普通规则仍生效。
//!
//! 修复前（批15 产物）：Web 端 `purify_content` 调用无执行器管线，`@js:`
//! 被静默跳过，输出原文 → 本文件在 `--features quickjs` 下红。
//!
//! 运行：
//! `cargo test -p legado-ffi --test replace_rule_js_web_parity --features quickjs`
//!
//! 说明：
//! - App 侧使用进程级文件 DB（`ffi_db_open`，与 `reading_flow_rust_defects`
//!   同款）承载全局连接池；
//! - Web 侧每次测试自建内存 DB 与独立 `AppState`，经真实路由 `/getBookContent`
//!   走生产请求链；
//! - App 全局 DB 在本文件内共享 → 用异步互斥锁串行，且各用例使用唯一标记，
//!   避免规则/书籍交叉污染。

use std::sync::atomic::AtomicBool;
use std::sync::{Arc, OnceLock};

use axum::body::Body;
use axum::http::Request;
use serde_json::Value;
use tokio::sync::{Mutex, MutexGuard};
use tower::ServiceExt;

use legado_ffi::db_state::with_database;
use legado_ffi::legado_core::cache_book::CachedChapter;
use legado_ffi::legado_core::download_manager::DownloadManager;
use legado_ffi::legado_core::models::{Book, BookChapter, ReplaceRule};
use legado_ffi::legado_db::repository::Repository;
use legado_ffi::legado_db::{
    BookChapterRepository, BookRepository, CacheBookRepository, ReplaceRuleRepository,
};
use legado_ffi::legado_server::routes::create_router;
use legado_ffi::legado_server::state::AppState;

/// 串行化 App 全局 DB 的用例，并确保 DB 只初始化一次
async fn ensure_app_db() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    static INIT: OnceLock<()> = OnceLock::new();
    let guard = LOCK.get_or_init(|| Mutex::new(())).lock().await;
    INIT.get_or_init(|| {
        let path = std::env::temp_dir().join(format!(
            "legado-batch17-js-parity-{}.db",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        legado_ffi::ffi::ffi::db_open(path.to_string_lossy().into_owned())
            .expect("打开批17 一致性测试文件 DB");
    });
    guard
}

/// 构造独立内存 DB 的 Web `AppState`（与 legacy_web_test 同款）
fn make_web_state() -> Arc<AppState> {
    let db = legado_ffi::legado_db::init_in_memory_database().expect("Web 内存 DB");
    Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
        injected_paths: Default::default(),
        legacy_review: Default::default(),
        source_check: Default::default(),
    })
}

/// 极简 percent-encode（仅测试 URL 用）
fn enc(input: &str) -> String {
    let mut out = String::new();
    for b in input.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// 调用 Web 端 `/getBookContent`（真实路由 + 生产净化链）
async fn web_content(state: Arc<AppState>, book_url: &str, index: i32) -> Value {
    let app = create_router(state);
    let uri = format!("/getBookContent?url={}&index={index}", enc(book_url));
    let resp = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// 向 Web 端 State 写入书籍/章节/缓存正文/替换规则
async fn seed_web(
    state: &Arc<AppState>,
    book: &Book,
    chapter: &BookChapter,
    content: &str,
    rules: &[ReplaceRule],
) {
    let db = state.db.lock().await;
    BookRepository::new(db.connection()).insert(book).unwrap();
    BookChapterRepository::new(db.connection())
        .insert(chapter)
        .unwrap();
    CacheBookRepository::new(db.connection())
        .insert(&CachedChapter {
            id: 0,
            book_url: book.book_url.clone(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_url: chapter.url.clone(),
            content: content.to_string(),
            cached_at: 0,
            size_bytes: 0,
        })
        .unwrap();
    for rule in rules {
        ReplaceRuleRepository::new(db.connection())
            .insert(rule)
            .unwrap();
    }
}

/// 向 App 端全局 DB 写入书籍/章节/替换规则（App 不读 `cached_chapters`：
/// 净化入口直接接收原始正文）
///
/// 各用例使用唯一 bookUrl，且 DB 文件按进程号隔离，无需清理历史行。
fn seed_app(book: &Book, chapter: &BookChapter, rules: &[ReplaceRule]) {
    with_database(|db| BookRepository::new(db.connection()).insert(book)).unwrap();
    with_database(|db| BookChapterRepository::new(db.connection()).insert(chapter)).unwrap();
    for rule in rules {
        with_database(|db| ReplaceRuleRepository::new(db.connection()).insert(rule)).unwrap();
    }
}

/// 构造书籍行（`name`/`author` 供 JS `book.*` 绑定）
fn test_book(book_url: &str, name: &str) -> Book {
    Book {
        book_url: book_url.to_string(),
        origin: "https://batch17.example.com".to_string(),
        origin_name: "批17测试书源".to_string(),
        name: name.to_string(),
        author: "批十七作者".to_string(),
        ..Book::default()
    }
}

/// 构造章节行（`title`/`index`/`url` 供 JS `chapter.*` 绑定）
fn test_chapter(book_url: &str, index: i32, title: &str, url: &str) -> BookChapter {
    BookChapter {
        book_url: book_url.to_string(),
        index,
        title: title.to_string(),
        url: url.to_string(),
        ..BookChapter::default()
    }
}

/// App 净化入口（生产阅读链路，携带调用方已持有的 chapter_url 与命中标记）
fn app_content(book_url: &str, raw: &str, title: &str, index: i32, url: &str) -> String {
    legado_ffi::api::reader::apply_content_processing_chapter_with_context(
        book_url,
        raw,
        title,
        index,
        Some(url),
        true,
    )
}

/// 批17 核心：`@js:` 全字段绑定在两端一致执行
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_js_rule_parity_app_and_web_with_chapter_book_bindings() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch17.example.com/book/parity-1";
    let title = "第七章 批十七一致性";
    let chapter_url = "https://batch17.example.com/ch/7";
    let raw = "前批十七一致性标记后";
    let rule = ReplaceRule {
        name: "批17_一致性绑定".to_string(),
        pattern: "批十七一致性标记".to_string(),
        replacement: r#"@js: result + "|" + chapter.title + "|" + chapter.index + "|" + chapter.url + "|" + chapter.bookUrl + "|" + book.name + "|" + book.author + "|" + book.bookUrl"#.to_string(),
        is_regex: true,
        is_enabled: true,
        scope_content: true,
        ..Default::default()
    };
    let expected = "前批十七一致性标记|第七章 批十七一致性|7|\
        https://batch17.example.com/ch/7|https://batch17.example.com/book/parity-1|\
        批十七一致性书|批十七作者|https://batch17.example.com/book/parity-1后";

    let book = test_book(book_url, "批十七一致性书");
    let chapter = test_chapter(book_url, 7, title, chapter_url);
    let web_state = make_web_state();
    seed_web(
        &web_state,
        &book,
        &chapter,
        raw,
        std::slice::from_ref(&rule),
    )
    .await;
    seed_app(&book, &chapter, std::slice::from_ref(&rule));

    let web = web_content(web_state, book_url, 7).await;
    assert_eq!(web["isSuccess"], true, "web={web}");
    let web = web["data"]
        .as_str()
        .expect("Web 正文应为字符串")
        .to_string();
    let app = app_content(book_url, raw, title, 7, chapter_url);

    assert_eq!(app, expected, "App 端 @js: 绑定/执行结果不符");
    assert_eq!(
        web, expected,
        "Web 端 @js: 绑定/执行结果不符（修复前为原文）"
    );
    assert_eq!(app, web, "App 与 Web 对同一规则同一输入必须输出完全一致");
}

/// 批17：`@js:` 抛错两端都保留原文，且后续普通规则继续生效
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_js_rule_error_parity_app_and_web_keep_original() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch17.example.com/book/parity-err";
    let title = "第一章";
    let chapter_url = "https://batch17.example.com/ch/err-0";
    let raw = "前批十七抛错标记后 后续普通标记";
    let rules = [
        ReplaceRule {
            name: "批17_一致性抛错".to_string(),
            pattern: "批十七抛错标记".to_string(),
            replacement: "@js:(function(){ throw new Error('boom'); })()".to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
        ReplaceRule {
            name: "批17_一致性普通".to_string(),
            pattern: "后续普通标记".to_string(),
            replacement: "已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    ];
    let expected = "前批十七抛错标记后 已换";

    let book = test_book(book_url, "批十七抛错书");
    let chapter = test_chapter(book_url, 0, title, chapter_url);
    let web_state = make_web_state();
    seed_web(&web_state, &book, &chapter, raw, &rules).await;
    seed_app(&book, &chapter, &rules);

    let web = web_content(web_state, book_url, 0).await;
    assert_eq!(web["isSuccess"], true, "web={web}");
    let web = web["data"]
        .as_str()
        .expect("Web 正文应为字符串")
        .to_string();
    let app = app_content(book_url, raw, title, 0, chapter_url);

    assert_eq!(app, expected, "@js: 抛错 App 端应保留原文并继续后续规则");
    assert_eq!(web, expected, "@js: 抛错 Web 端应保留原文并继续后续规则");
    assert_eq!(app, web, "抛错场景 App 与 Web 输出必须一致");
}

/// 批17：`@js:` 超时两端都保留原文
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_js_rule_timeout_parity_app_and_web_keep_original() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch17.example.com/book/parity-timeout";
    let title = "第一章";
    let chapter_url = "https://batch17.example.com/ch/timeout-0";
    let raw = "前批十七超时标记后";
    let rule = ReplaceRule {
        name: "批17_一致性超时".to_string(),
        pattern: "批十七超时标记".to_string(),
        replacement: "@js:while(true){}".to_string(),
        is_regex: true,
        is_enabled: true,
        scope_content: true,
        timeout_millisecond: 60,
        ..Default::default()
    };

    let book = test_book(book_url, "批十七超时书");
    let chapter = test_chapter(book_url, 0, title, chapter_url);
    let web_state = make_web_state();
    seed_web(
        &web_state,
        &book,
        &chapter,
        raw,
        std::slice::from_ref(&rule),
    )
    .await;
    seed_app(&book, &chapter, std::slice::from_ref(&rule));

    let web = web_content(web_state, book_url, 0).await;
    assert_eq!(web["isSuccess"], true, "web={web}");
    let web = web["data"]
        .as_str()
        .expect("Web 正文应为字符串")
        .to_string();
    let app = app_content(book_url, raw, title, 0, chapter_url);

    assert_eq!(app, raw, "@js: 超时 App 端应保留原文");
    assert_eq!(web, raw, "@js: 超时 Web 端应保留原文");
    assert_eq!(app, web, "超时场景 App 与 Web 输出必须一致");
}

/// 批17：无 quickjs feature 两端都不执行 `@js:`，普通规则仍生效
#[cfg(not(feature = "quickjs"))]
#[tokio::test]
async fn test_js_rule_parity_without_quickjs_keeps_original() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch17.example.com/book/parity-noqjs";
    let title = "第一章";
    let chapter_url = "https://batch17.example.com/ch/noqjs-0";
    let raw = "前批十七无JS标记后 普通标记";
    let rules = [
        ReplaceRule {
            name: "批17_一致性无quickjs".to_string(),
            pattern: "批十七无JS标记".to_string(),
            replacement: r#"@js: result + "!""#.to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
        ReplaceRule {
            name: "批17_一致性普通".to_string(),
            pattern: "普通标记".to_string(),
            replacement: "已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    ];
    let expected = "前批十七无JS标记后 已换";

    let book = test_book(book_url, "批十七无JS书");
    let chapter = test_chapter(book_url, 0, title, chapter_url);
    let web_state = make_web_state();
    seed_web(&web_state, &book, &chapter, raw, &rules).await;
    seed_app(&book, &chapter, &rules);

    let web = web_content(web_state, book_url, 0).await;
    assert_eq!(web["isSuccess"], true, "web={web}");
    let web = web["data"]
        .as_str()
        .expect("Web 正文应为字符串")
        .to_string();
    let app = app_content(book_url, raw, title, 0, chapter_url);

    assert_eq!(
        app, expected,
        "无 quickjs 时 App 端 @js: 应保留原文，普通规则仍生效"
    );
    assert_eq!(
        web, expected,
        "无 quickjs 时 Web 端 @js: 应保留原文，普通规则仍生效"
    );
    assert_eq!(app, web, "无 quickjs 场景 App 与 Web 输出必须一致");
}
