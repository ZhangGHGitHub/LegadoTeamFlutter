//! B1/B2 原版 Web 服务一致性集成测试（先红后绿）
//!
//! 断言目标（对齐 `app/src/main/java/io/legado/app/web/**` 与
//! `app/src/main/java/io/legado/app/api/controller/BookController.kt`）：
//!
//! 1. 静态资产：`GET /` 为原版 Forty 导航页（`app/src/main/assets/web/index.html`），
//!    `GET /vue/assets/<hash>.js` MIME 与原版 `AssetsWeb.kt` 一致（text/javascript），
//!    `/vue/*.html` 带 no-cache + CSP，未知路径 404（原版为 500，见实现注释）；
//! 2. 只读端点：`ReturnData{isSuccess,errorMsg,data}` 信封 + 原版路径 + 原版
//!    错误文案；Book/BookChapter 的 JSON 字段集按 Kotlin `Book.kt` /
//!    `BookChapter.kt` 逐字段硬编码断言（来源见 `legacy/book_json.rs`）。
//!
//! 先红证据：本文件在实施批次前运行 —— 全部端点 404、静态页为自制页。

use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use serde_json::{json, Value};
use tokio::sync::Mutex;
use tower::ServiceExt;

use legado_core::cache_book::CachedChapter;
use legado_core::download_manager::DownloadManager;
use legado_core::models::{Book, BookChapter};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::repository::cache_book_repository::CacheBookRepository;
use legado_db::repository::Repository;
use legado_server::routes::create_router;
use legado_server::state::AppState;

fn make_test_state() -> Arc<AppState> {
    let db = legado_db::init_in_memory_database().unwrap();
    Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
    })
}

async fn get(app: axum::Router, uri: &str) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let resp = app
        .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let headers = resp.headers().clone();
    let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec();
    (status, headers, body)
}

async fn get_json(app: axum::Router, uri: &str) -> (StatusCode, Value) {
    let (status, _, body) = get(app, uri).await;
    (status, serde_json::from_slice(&body).unwrap())
}

async fn post_body(
    app: axum::Router,
    uri: &str,
    content_type: &str,
    body: &str,
) -> (StatusCode, Value) {
    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(uri)
                .header("Content-Type", content_type)
                .body(Body::from(body.to_string()))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, serde_json::from_slice(&bytes).unwrap())
}

fn header_str<'a>(headers: &'a axum::http::HeaderMap, name: &str) -> &'a str {
    headers
        .get(name)
        .and_then(|v| v.to_str().ok())
        .unwrap_or_default()
}

/// 极简 percent-encode（仅测试用；避免为测试引入 urlencoding 依赖）
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

/// 无章节的在线书（origin 指向不存在的书源）
async fn seed_book_without_chapters(state: &Arc<AppState>) {
    let db = state.db.lock().await;
    BookRepository::new(db.connection())
        .insert(&Book {
            book_url: "https://src.example.com/book/1".to_string(),
            origin: "https://src.example.com".to_string(),
            origin_name: "测试书源".to_string(),
            name: "测试书".to_string(),
            author: "测试作者".to_string(),
            ..Book::default()
        })
        .unwrap();
}

// ---------------------------------------------------------------------------
// B1 静态资产
// ---------------------------------------------------------------------------

/// `GET /` 必须是原版导航页（特征标记取自 `app/src/main/assets/web/index.html`）
#[tokio::test]
async fn test_root_serves_legacy_navigation_page() {
    let app = create_router(make_test_state());
    let (status, headers, body) = get(app, "/").await;

    assert_eq!(status, StatusCode::OK);
    let ct = header_str(&headers, "content-type");
    assert!(
        ct.starts_with("text/html"),
        "根路径 Content-Type 应为 text/html，实际 {ct}"
    );
    let html = String::from_utf8(body).unwrap();
    assert!(
        html.contains("<title>Legado web 导航</title>"),
        "根路径应为原版导航页（含 <title>Legado web 导航</title>）"
    );
    assert!(
        html.contains("vue/index.html#/bookSource"),
        "导航页应含书源入口"
    );
    // 原版 addWebHeaders：nosniff 恒定
    assert_eq!(header_str(&headers, "x-content-type-options"), "nosniff");
}

/// 目录路径补 index.html（原版 HttpServer.kt:162-163 `/` 语义推广到 `/vue/`）
#[tokio::test]
async fn test_directory_path_falls_back_to_index_html() {
    let app = create_router(make_test_state());
    let (status, _, body) = get(app, "/vue/").await;
    assert_eq!(status, StatusCode::OK);
    let html = String::from_utf8(body).unwrap();
    assert!(html.contains("<div id=\"app\">"), "/vue/ 应返回 Vue 入口页");
}

/// 真实 Vue 产物：MIME 对齐原版 AssetsWeb.kt（.js → text/javascript）
#[tokio::test]
async fn test_vue_chunk_mime_matches_original_assets_web() {
    let app = create_router(make_test_state());
    let (status, headers, body) = get(app, "/vue/assets/index-toG2697L.js").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        header_str(&headers, "content-type"),
        "text/javascript",
        "原版 AssetsWeb.kt:38 对 .js 回 text/javascript"
    );
    assert!(!body.is_empty());
}

/// `/vue/*.html` 缓存与 CSP 头（原版 HttpServer.kt:274-277）
#[tokio::test]
async fn test_vue_html_cache_and_csp_headers() {
    let app = create_router(make_test_state());
    let (status, headers, _) = get(app, "/vue/index.html").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(header_str(&headers, "cache-control"), "no-cache");
    let csp = header_str(&headers, "content-security-policy");
    assert!(
        csp.contains("default-src 'self' data: blob:"),
        "CSP 应与 HttpServer.VUE_CONTENT_SECURITY_POLICY 一致，实际 {csp}"
    );
}

/// 未知静态路径：404（原版 assets.open 异常被 catch 成 500，见实现注释登记差异）
#[tokio::test]
async fn test_unknown_static_path_404() {
    let app = create_router(make_test_state());
    let (status, _, _) = get(app, "/no-such-asset.html").await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

/// OPTIONS 预检（原版 HttpServer.kt:45-56）
#[tokio::test]
async fn test_options_preflight() {
    let app = create_router(make_test_state());
    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::OPTIONS)
                .uri("/getBookshelf")
                .header("Origin", "http://192.168.1.5:1122")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        header_str(resp.headers(), "access-control-allow-methods"),
        "GET, POST"
    );
    assert_eq!(
        header_str(resp.headers(), "access-control-allow-headers"),
        "content-type, x-legado-token"
    );
    assert_eq!(
        header_str(resp.headers(), "access-control-allow-origin"),
        "http://192.168.1.5:1122"
    );
}

// ---------------------------------------------------------------------------
// B2 只读端点
// ---------------------------------------------------------------------------

/// Kotlin `Book.kt` 经项目 GSON（含 @Ignore 类体字段）序列化的完整键集
const KOTLIN_BOOK_KEYS: &[&str] = &[
    "bookUrl",
    "tocUrl",
    "origin",
    "originName",
    "name",
    "author",
    "kind",
    "customTag",
    "coverUrl",
    "customCoverUrl",
    "intro",
    "customIntro",
    "charset",
    "type",
    "group",
    "latestChapterTitle",
    "latestChapterTime",
    "lastCheckTime",
    "lastCheckCount",
    "totalChapterNum",
    "durChapterTitle",
    "durChapterIndex",
    "durVolumeIndex",
    "chapterInVolumeIndex",
    "durChapterPos",
    "durChapterTime",
    "wordCount",
    "canUpdate",
    "order",
    "originOrder",
    "variable",
    "readConfig",
    "syncTime",
    "persistedCoverUrl",
    "infoHtml",
    "tocHtml",
    "downloadUrls",
    "folderName",
];

/// Kotlin `BookChapter.kt` 经项目 GSON 序列化的完整键集
const KOTLIN_CHAPTER_KEYS: &[&str] = &[
    "url",
    "title",
    "isVolume",
    "baseUrl",
    "bookUrl",
    "index",
    "isVip",
    "isPay",
    "resourceUrl",
    "tag",
    "wordCount",
    "start",
    "end",
    "startFragmentId",
    "endFragmentId",
    "variable",
    "imgUrl",
    "titleMD5",
];

#[tokio::test]
async fn test_get_bookshelf_empty_error_msg() {
    let app = create_router(make_test_state());
    let (status, json) = get_json(app, "/getBookshelf").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "还没有添加小说");
    assert!(json["data"].is_null());
}

#[tokio::test]
async fn test_get_bookshelf_full_kotlin_field_shape() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://example.com/book/1".to_string(),
                toc_url: "https://example.com/book/1/toc".to_string(),
                origin: "https://example.com".to_string(),
                origin_name: "示例源".to_string(),
                name: "示例书".to_string(),
                author: "示例作者".to_string(),
                cover_url: Some("https://example.com/cover.jpg".to_string()),
                dur_chapter_index: 3,
                dur_chapter_pos: 100,
                dur_chapter_title: Some("第三章".to_string()),
                dur_chapter_time: 1_700_000_000_000,
                total_chapter_num: 10,
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let (status, json) = get_json(app, "/getBookshelf").await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["isSuccess"], true);
    assert_eq!(json["errorMsg"], "");

    let books = json["data"].as_array().unwrap();
    assert_eq!(books.len(), 1);
    let book = books[0].as_object().unwrap();

    let mut actual: Vec<&str> = book.keys().map(|k| k.as_str()).collect();
    actual.sort_unstable();
    let mut expected: Vec<&str> = KOTLIN_BOOK_KEYS.to_vec();
    expected.sort_unstable();
    assert_eq!(
        actual, expected,
        "getBookshelf data 元素键集必须与 Kotlin Book.kt 一致"
    );

    assert_eq!(book["bookUrl"], "https://example.com/book/1");
    assert_eq!(book["name"], "示例书");
    assert_eq!(book["author"], "示例作者");
    assert_eq!(book["durChapterIndex"], 3);
    assert_eq!(book["durChapterPos"], 100);
    assert_eq!(book["durChapterTitle"], "第三章");
    assert_eq!(book["totalChapterNum"], 10);
    // Rust 侧额外列（originBookUrl/coverOrigin）不得出现在原版 JSON 形状中
    assert!(book.get("originBookUrl").is_none());
    assert!(book.get("coverOrigin").is_none());
}

#[tokio::test]
async fn test_get_bookshelf_sorted_by_dur_chapter_time_desc() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        let repo = BookRepository::new(db.connection());
        repo.insert(&Book {
            book_url: "b-old".to_string(),
            name: "旧".to_string(),
            dur_chapter_time: 1000,
            ..Book::default()
        })
        .unwrap();
        repo.insert(&Book {
            book_url: "b-new".to_string(),
            name: "新".to_string(),
            dur_chapter_time: 2000,
            ..Book::default()
        })
        .unwrap();
    }
    let app = create_router(state);
    let (_, json) = get_json(app, "/getBookshelf").await;
    let books = json["data"].as_array().unwrap();
    assert_eq!(books[0]["bookUrl"], "b-new");
    assert_eq!(books[1]["bookUrl"], "b-old");
}

#[tokio::test]
async fn test_get_chapter_list_requires_url() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app, "/getChapterList").await;
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "参数url不能为空，请指定书籍地址");
}

#[tokio::test]
async fn test_get_chapter_list_full_kotlin_field_shape() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "book1".to_string(),
                name: "书一".to_string(),
                ..Book::default()
            })
            .unwrap();
        let repo = BookChapterRepository::new(db.connection());
        repo.insert(&BookChapter {
            url: "book1/ch0".to_string(),
            title: "第一章".to_string(),
            book_url: "book1".to_string(),
            index: 0,
            ..BookChapter::default()
        })
        .unwrap();
    }
    let app = create_router(state);
    let (_, json) = get_json(app, "/getChapterList?url=book1").await;

    assert_eq!(json["isSuccess"], true);
    let chapters = json["data"].as_array().unwrap();
    assert_eq!(chapters.len(), 1);
    let chapter = chapters[0].as_object().unwrap();
    let mut actual: Vec<&str> = chapter.keys().map(|k| k.as_str()).collect();
    actual.sort_unstable();
    let mut expected: Vec<&str> = KOTLIN_CHAPTER_KEYS.to_vec();
    expected.sort_unstable();
    assert_eq!(
        actual, expected,
        "getChapterList 元素键集必须与 Kotlin BookChapter.kt 一致"
    );
    assert_eq!(chapter["url"], "book1/ch0");
    assert_eq!(chapter["index"], 0);
}

#[tokio::test]
async fn test_get_chapter_list_book_not_found() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app, "/getChapterList?url=missing-book").await;
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "未在数据库找到对应书籍，请先添加");
}

#[tokio::test]
async fn test_get_chapter_list_missing_source() {
    let state = make_test_state();
    seed_book_without_chapters(&state).await;
    let app = create_router(state);
    let (_, json) = get_json(
        app,
        "/getChapterList?url=https%3A%2F%2Fsrc.example.com%2Fbook%2F1",
    )
    .await;
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "未找到对应书源,请换源");
}

#[tokio::test]
async fn test_get_book_content_requires_params() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app, "/getBookContent").await;
    assert_eq!(json["errorMsg"], "参数url不能为空，请指定书籍地址");

    let app = create_router(make_test_state());
    let (_, json) = get_json(app, "/getBookContent?url=book1").await;
    assert_eq!(json["errorMsg"], "参数index不能为空, 请指定目录序号");
}

#[tokio::test]
async fn test_get_book_content_not_found() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app, "/getBookContent?url=book1&index=0").await;
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "未找到");
}

#[tokio::test]
async fn test_get_book_content_from_cache() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "book1".to_string(),
                name: "书一".to_string(),
                ..Book::default()
            })
            .unwrap();
        BookChapterRepository::new(db.connection())
            .insert(&BookChapter {
                url: "book1/ch0".to_string(),
                title: "第一章".to_string(),
                book_url: "book1".to_string(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
        CacheBookRepository::new(db.connection())
            .insert(&CachedChapter {
                id: 0,
                book_url: "book1".to_string(),
                chapter_index: 0,
                chapter_title: "第一章".to_string(),
                chapter_url: "book1/ch0".to_string(),
                content: "正文第一段\n正文第二段".to_string(),
                cached_at: 0,
                size_bytes: 0,
            })
            .unwrap();
    }
    let app = create_router(state);
    let (_, json) = get_json(app, "/getBookContent?url=book1&index=0").await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(json["data"], "正文第一段\n正文第二段");
}

#[tokio::test]
async fn test_save_book_progress_beacon_text_plain() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "book1".to_string(),
                name: "书一".to_string(),
                author: "作者一".to_string(),
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state.clone());
    // sendBeacon 固定 text/plain（报告 §六 #5），服务端不得按 JSON Content-Type 拒收
    let (status, json) = post_body(
        app,
        "/saveBookProgress",
        "text/plain",
        &json!({
            "name": "书一",
            "author": "作者一",
            "durChapterIndex": 5,
            "durChapterPos": 42,
            "durChapterTime": 1700000000123i64,
            "durChapterTitle": "第五章"
        })
        .to_string(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(json["data"], "");

    let db = state.db.lock().await;
    let book = BookRepository::new(db.connection())
        .find_by_url("book1")
        .unwrap()
        .unwrap();
    assert_eq!(book.dur_chapter_index, 5);
    assert_eq!(book.dur_chapter_pos, 42);
    assert_eq!(book.dur_chapter_title.as_deref(), Some("第五章"));
    assert_eq!(book.dur_chapter_time, 1700000000123);
}

#[tokio::test]
async fn test_save_book_progress_bad_format() {
    let app = create_router(make_test_state());
    let (_, json) = post_body(app, "/saveBookProgress", "application/json", "not-json").await;
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "格式不对");
}

#[tokio::test]
async fn test_read_config_roundtrip() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app.clone(), "/getReadConfig").await;
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "没有配置");

    let payload = r#"{"fontSize":18,"theme":"dark"}"#;
    let (_, json) = post_body(app.clone(), "/saveReadConfig", "application/json", payload).await;
    assert_eq!(json["isSuccess"], true);
    assert_eq!(json["data"], "");

    let (_, json) = get_json(app, "/getReadConfig").await;
    assert_eq!(json["isSuccess"], true);
    assert_eq!(json["data"], payload);
}

#[tokio::test]
async fn test_cover_serves_local_file_bytes() {
    let png: Vec<u8> = {
        let mut v = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
        v.extend_from_slice(b"fake-png-payload");
        v
    };
    let path = std::env::temp_dir().join(format!("legado-cover-test-{}.png", std::process::id()));
    std::fs::write(&path, &png).unwrap();

    let app = create_router(make_test_state());
    let uri = format!("/cover?path={}", enc(&path.to_string_lossy()));
    let (status, headers, body) = get(app, &uri).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(header_str(&headers, "content-type"), "image/png");
    assert_eq!(body, png);

    let _ = std::fs::remove_file(&path);
}

#[tokio::test]
async fn test_image_requires_params() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app.clone(), "/image?path=https%3A%2F%2Fx%2F1.png").await;
    assert_eq!(json["errorMsg"], "bookUrl为空");

    let (_, json) = get_json(app, "/image?url=book1").await;
    assert_eq!(json["errorMsg"], "图片链接为空");
}
