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

/// Kotlin `Book.kt` 经项目 GSON 序列化的完整键集（`GsonExtensions.kt:28-51`
/// 未调 `serializeNulls()` → null 字段省略；本表为「全字段非空」上界）
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

/// Kotlin `Book.kt` 非空字段（GSON 恒输出；P1-1 后最小投影的键集）
const KOTLIN_BOOK_REQUIRED_KEYS: &[&str] = &[
    "bookUrl",
    "tocUrl",
    "origin",
    "originName",
    "name",
    "author",
    "type",
    "group",
    "latestChapterTime",
    "lastCheckTime",
    "lastCheckCount",
    "totalChapterNum",
    "durChapterIndex",
    "durVolumeIndex",
    "chapterInVolumeIndex",
    "durChapterPos",
    "durChapterTime",
    "canUpdate",
    "order",
    "originOrder",
    "syncTime",
];

/// Rust 侧无数据来源、恒 null 的 4 个 Room/私有字段（原版由库载入时同样为
/// null → GSON 省略）+ Rust 库缺失的 `persistedCoverUrl` 列（登记差异）
const KOTLIN_BOOK_ALWAYS_NULL_KEYS: &[&str] = &[
    "persistedCoverUrl",
    "infoHtml",
    "tocHtml",
    "downloadUrls",
    "folderName",
];

/// Kotlin `BookChapter.kt` 经项目 GSON 序列化的完整键集（同上，全字段非空上界）
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

/// Kotlin `BookChapter.kt` 非空字段（P1-1 后最小投影的键集）
const KOTLIN_CHAPTER_REQUIRED_KEYS: &[&str] = &[
    "url", "title", "isVolume", "baseUrl", "bookUrl", "index", "isVip", "isPay",
];

/// 可空字段全为 null 的 Book：键集必须等于非空字段集（GSON 省略 null）
fn assert_book_null_fields_omitted(book: &serde_json::Map<String, Value>) {
    for key in KOTLIN_BOOK_ALWAYS_NULL_KEYS {
        assert!(!book.contains_key(*key), "恒 null 字段 {key} 不应出现");
    }
}

#[tokio::test]
async fn test_get_bookshelf_empty_error_msg() {
    let app = create_router(make_test_state());
    let (status, json) = get_json(app, "/getBookshelf").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(json["isSuccess"], false);
    assert_eq!(json["errorMsg"], "还没有添加小说");
    assert!(json["data"].is_null());
}

/// 全字段非空书籍：键集必须与 Kotlin `Book.kt` 全字段集一致（除恒 null 的 5 键）
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
                kind: Some("玄幻".to_string()),
                custom_tag: Some("我的标签".to_string()),
                cover_url: Some("https://example.com/cover.jpg".to_string()),
                custom_cover_url: Some("https://example.com/my-cover.jpg".to_string()),
                intro: Some("简介".to_string()),
                custom_intro: Some("自定义简介".to_string()),
                charset: Some("UTF-8".to_string()),
                latest_chapter_title: Some("最新章".to_string()),
                dur_chapter_title: Some("第三章".to_string()),
                word_count: Some("10万字".to_string()),
                variable: Some("{}".to_string()),
                read_config: Some(legado_core::models::ReadConfig {
                    page_anim: Some(1),
                    image_style: Some("FULL".to_string()),
                    use_replace_rule: Some(true),
                    tts_engine: Some("engine".to_string()),
                    start_date: Some("2026-01-01".to_string()),
                    start_chapter: Some(2),
                    ..Default::default()
                }),
                dur_chapter_index: 3,
                dur_chapter_pos: 100,
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
    let mut expected: Vec<&str> = KOTLIN_BOOK_KEYS
        .iter()
        .filter(|k| !KOTLIN_BOOK_ALWAYS_NULL_KEYS.contains(k))
        .copied()
        .collect();
    expected.sort_unstable();
    assert_eq!(
        actual, expected,
        "全字段非空时键集应等于 Kotlin Book.kt 全字段集（GSON 省略 null）"
    );
    assert_book_null_fields_omitted(book);

    assert_eq!(book["bookUrl"], "https://example.com/book/1");
    assert_eq!(book["name"], "示例书");
    assert_eq!(book["author"], "示例作者");
    assert_eq!(book["durChapterIndex"], 3);
    assert_eq!(book["durChapterPos"], 100);
    assert_eq!(book["durChapterTitle"], "第三章");
    assert_eq!(book["totalChapterNum"], 10);
    assert_eq!(book["readConfig"]["useReplaceRule"], true);
    // Rust 侧额外列（originBookUrl/coverOrigin）不得出现在原版 JSON 形状中
    assert!(book.get("originBookUrl").is_none());
    assert!(book.get("coverOrigin").is_none());
}

/// 先红后绿（P1-1）：GSON 默认省略 null —— 仅填非空字段的书籍，可空键不得出现
#[tokio::test]
async fn test_get_bookshelf_omits_null_fields_like_gson_default() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://example.com/book/1".to_string(),
                origin: "https://example.com".to_string(),
                name: "最小书".to_string(),
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let (_, json) = get_json(app, "/getBookshelf").await;
    let book = json["data"][0].as_object().unwrap();

    let mut actual: Vec<&str> = book.keys().map(|k| k.as_str()).collect();
    actual.sort_unstable();
    let mut expected: Vec<&str> = KOTLIN_BOOK_REQUIRED_KEYS.to_vec();
    expected.sort_unstable();
    assert_eq!(
        actual, expected,
        "可空字段为 null 时应按 GSON 默认省略（实际键集 {actual:?}）"
    );
    for key in [
        "kind",
        "customTag",
        "coverUrl",
        "intro",
        "readConfig",
        "persistedCoverUrl",
        "folderName",
    ] {
        assert!(
            !book.contains_key(key),
            "null 字段 {key} 不应出现在 JSON 中"
        );
    }
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
    let mut expected: Vec<&str> = KOTLIN_CHAPTER_REQUIRED_KEYS.to_vec();
    expected.sort_unstable();
    assert_eq!(
        actual, expected,
        "可空字段为 null 时应按 GSON 默认省略（实际键集 {actual:?}）"
    );
    // 有值的可空字段键必须出现（全字段上界减去本用例可空字段即可）
    assert!(KOTLIN_CHAPTER_KEYS.contains(&"titleMD5"));
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

/// P1-3 先红后绿：净化按 `Book.getUseReplaceRule()` 门控
///
/// 原版依据：`Book.kt:226-236`（readConfig.useReplaceRule 非空取该值；否则
/// 图片类 / epub 本地书返回 false；其余回退 `AppConfig.replaceEnableDefault`
/// 默认 true）→ `ContentProcessor.kt:116` `useReplace && book.getUseReplaceRule()`。
#[tokio::test]
async fn test_get_book_content_replace_rule_gated_by_use_replace_rule() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        let books = BookRepository::new(db.connection());
        // 普通在线文字书（未设置 useReplaceRule → 回退默认 true）
        books
            .insert(&Book {
                book_url: "text-book".to_string(),
                origin: "https://src.example.com".to_string(),
                name: "文字书".to_string(),
                book_type: legado_core::models::book_type::TEXT,
                ..Book::default()
            })
            .unwrap();
        // epub 本地书（未设置 → 默认关闭净化）
        books
            .insert(&Book {
                book_url: "epub-book".to_string(),
                origin: "loc_book".to_string(),
                origin_name: "book.epub".to_string(),
                name: "epub书".to_string(),
                book_type: legado_core::models::book_type::LOCAL,
                ..Book::default()
            })
            .unwrap();
        // 本地图片书（cbz，未设置 → 默认关闭净化）
        books
            .insert(&Book {
                book_url: "image-book".to_string(),
                origin: "loc_book".to_string(),
                origin_name: "book.cbz".to_string(),
                name: "图片书".to_string(),
                book_type: legado_core::models::book_type::LOCAL
                    | legado_core::models::book_type::IMAGE_BIT,
                ..Book::default()
            })
            .unwrap();
        // epub 本地书 + 显式开启净化（用户显式设置优先于类型默认）
        books
            .insert(&Book {
                book_url: "epub-book-forced".to_string(),
                origin: "loc_book".to_string(),
                origin_name: "forced.epub".to_string(),
                name: "epub显式".to_string(),
                book_type: legado_core::models::book_type::LOCAL,
                read_config: Some(legado_core::models::ReadConfig {
                    use_replace_rule: Some(true),
                    ..Default::default()
                }),
                ..Book::default()
            })
            .unwrap();

        let chapters = BookChapterRepository::new(db.connection());
        let cached = CacheBookRepository::new(db.connection());
        for book_url in ["text-book", "epub-book", "image-book", "epub-book-forced"] {
            chapters
                .insert(&BookChapter {
                    url: format!("{book_url}/ch0"),
                    title: "第一章".to_string(),
                    book_url: book_url.to_string(),
                    index: 0,
                    ..BookChapter::default()
                })
                .unwrap();
            cached
                .insert(&CachedChapter {
                    id: 0,
                    book_url: book_url.to_string(),
                    chapter_index: 0,
                    chapter_title: "第一章".to_string(),
                    chapter_url: format!("{book_url}/ch0"),
                    content: "正文广告内容".to_string(),
                    cached_at: 0,
                    size_bytes: 0,
                })
                .unwrap();
        }

        // 全局启用的正文替换规则：广告 → 空
        legado_db::ReplaceRuleRepository::new(db.connection())
            .insert(&legado_core::models::ReplaceRule {
                name: "去广告".to_string(),
                pattern: "广告".to_string(),
                replacement: String::new(),
                is_regex: false,
                scope_content: true,
                is_enabled: true,
                ..Default::default()
            })
            .unwrap();
    }

    let get_content = |book_url: &str| {
        let app = create_router(state.clone());
        let uri = format!("/getBookContent?url={book_url}&index=0");
        async move {
            let (_, json) = get_json(app, &uri).await;
            json
        }
    };

    // 普通文字书：净化生效
    let json = get_content("text-book").await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(json["data"], "正文内容");

    // epub 本地书：默认关闭净化（原版 getUseReplaceRule 回退 false）
    let json = get_content("epub-book").await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"], "正文广告内容",
        "epub 本地书默认不应应用替换规则（P1-3）"
    );

    // 本地图片书：默认关闭净化
    let json = get_content("image-book").await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"], "正文广告内容",
        "图片书默认不应应用替换规则（P1-3）"
    );

    // epub + 显式 useReplaceRule=true：按显式值净化
    let json = get_content("epub-book-forced").await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(json["data"], "正文内容");
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

// ---------------------------------------------------------------------------
// P1-2 本地图片读取白名单（/cover /image）
// ---------------------------------------------------------------------------

/// P1-2 测试夹具：独立临时目录（Drop 清理），目录内造「书库目录 / 登记封面 /
/// 白名单外敏感文件」三类素材
struct CoverFixture {
    root: std::path::PathBuf,
}

impl CoverFixture {
    fn new(tag: &str) -> Self {
        let root = std::env::temp_dir().join(format!(
            "legado-cover-p12-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        Self { root }
    }

    /// 写入文件（自动建父目录），返回路径字符串
    fn write(&self, rel: &str, bytes: &[u8]) -> String {
        let path = self.root.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, bytes).unwrap();
        path.to_string_lossy().into_owned()
    }

    fn path(&self, rel: &str) -> std::path::PathBuf {
        self.root.join(rel)
    }
}

impl Drop for CoverFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// 带 PNG 魔数的字节（内容含 payload，便于断言未泄漏）
fn png_bytes(payload: &[u8]) -> Vec<u8> {
    let mut v = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    v.extend_from_slice(payload);
    v
}

/// 断言响应不是「读取成功」（本地读取被拒时回 ReturnData 错误信封）
fn assert_local_read_rejected(body: &[u8], secret: &[u8], context: &str) {
    assert!(
        !body.windows(secret.len()).any(|w| w == secret),
        "{context}: 敏感文件内容泄漏"
    );
    let json: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    assert_eq!(
        json["isSuccess"], false,
        "{context}: 应回错误信封（实际 {json}）"
    );
}

/// 合法用例（修前修后均绿）：书籍登记的本地自定义封面文件（精确文件白名单）
#[tokio::test]
async fn test_cover_serves_registered_local_cover_file() {
    let fx = CoverFixture::new("registered-cover");
    let png = png_bytes(b"registered-cover-payload");
    let cover = fx.write("covers/c.png", &png);

    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://example.com/book/1".to_string(),
                origin: "https://example.com".to_string(),
                name: "书一".to_string(),
                custom_cover_url: Some(cover.clone()),
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let uri = format!("/cover?path={}", enc(&cover));
    let (status, headers, body) = get(app, &uri).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(header_str(&headers, "content-type"), "image/png");
    assert_eq!(body, png, "登记的本地封面应按原字节回传");
}

/// 合法用例（修前修后均绿）：本地书目录（书库正文目录）内的图片
#[tokio::test]
async fn test_cover_serves_image_in_registered_local_book_dir() {
    let fx = CoverFixture::new("local-book-dir");
    let book_file = fx.write("lib/book.txt", b"book body");
    let png = png_bytes(b"local-book-dir-payload");
    let image = fx.write("lib/images/a.png", &png);

    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: book_file.clone(),
                origin: "loc_book".to_string(),
                origin_name: "book.txt".to_string(),
                name: "本地书".to_string(),
                book_type: legado_core::models::book_type::LOCAL,
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let uri = format!("/cover?path={}", enc(&image));
    let (status, headers, body) = get(app, &uri).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(header_str(&headers, "content-type"), "image/png");
    assert_eq!(body, png);
}

/// 先红后绿（P1-2）：书库目录之外的本地图片必须拒绝（直读与 `../` 穿越、
/// URL 编码变体三形态同断言）
#[tokio::test]
async fn test_cover_rejects_local_paths_outside_whitelist() {
    let fx = CoverFixture::new("outside-whitelist");
    let book_file = fx.write("lib/book.txt", b"book body");
    let secret_payload = b"TOP-SECRET-OUTSIDE-WHITELIST";
    let secret = fx.write("secret.png", &png_bytes(secret_payload));

    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: book_file.clone(),
                origin: "loc_book".to_string(),
                origin_name: "book.txt".to_string(),
                name: "本地书".to_string(),
                book_type: legado_core::models::book_type::LOCAL,
                ..Book::default()
            })
            .unwrap();
    }

    // 直读白名单外文件（同格式 PNG：拒绝只可能来自目录白名单）
    let app = create_router(state.clone());
    let (_, _, body) = get(app, &format!("/cover?path={}", enc(&secret))).await;
    assert_local_read_rejected(&body, secret_payload, "直读白名单外图片");

    // `../` 穿越（原始形态）
    let traversal = fx.path("lib/../secret.png").to_string_lossy().into_owned();
    let app = create_router(state.clone());
    let (_, _, body) = get(app, &format!("/cover?path={}", enc(&traversal))).await;
    assert_local_read_rejected(&body, secret_payload, "../ 穿越");

    // `../` 穿越（URL 编码变体：%2E%2E%2F）
    let encoded_traversal = format!(
        "{}/lib/%2E%2E%2Fsecret%2Epng",
        enc(&fx.root.to_string_lossy())
    );
    let app = create_router(state.clone());
    let (_, _, body) = get(app, &format!("/cover?path={encoded_traversal}")).await;
    assert_local_read_rejected(&body, secret_payload, "URL 编码 ../ 穿越");

    // 空库（无任何登记书籍）→ 一律拒绝
    let app = create_router(make_test_state());
    let (_, _, body) = get(app, &format!("/cover?path={}", enc(&secret))).await;
    assert_local_read_rejected(&body, secret_payload, "空书库直读本地文件");
}

/// 先红后绿（P1-2）：系统敏感路径必须拒绝（含 `../` 相对穿越与 URL 编码变体）
#[tokio::test]
async fn test_cover_rejects_system_file_paths() {
    for path in [
        "/etc/passwd",
        "/etc/shadow",
        "C:\\Windows\\win.ini",
        "../../../../etc/passwd",
        "..\\..\\..\\..\\Windows\\win.ini",
    ] {
        let app = create_router(make_test_state());
        let (_, _, body) = get(app, &format!("/cover?path={}", enc(path))).await;
        let json: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
        assert_eq!(
            json["isSuccess"], false,
            "系统路径 {path} 必须被拒绝（实际 {json}）"
        );
    }

    // URL 编码穿越变体（%2E%2E%2F 解码后仍是 `../`）
    let app = create_router(make_test_state());
    let (_, _, body) = get(app, "/cover?path=..%2F..%2F..%2F..%2Fetc%2Fpasswd").await;
    let json: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
    assert_eq!(json["isSuccess"], false, "URL 编码穿越必须被拒绝");
}

/// 先红后绿（P1-2）：扩展名白名单与魔数校验（防把任意文件当图片直读）
#[tokio::test]
async fn test_cover_rejects_non_image_extension_and_forged_magic() {
    let fx = CoverFixture::new("ext-magic");
    // 登记为封面但扩展名非图片 → 拒绝
    let txt = fx.write("note.txt", b"plain-text-secret");
    // 登记为封面、扩展名 .png 但内容非图片（魔数不匹配）→ 拒绝
    let forged = fx.write("forged.png", b"not-an-image-at-all");

    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://example.com/book/1".to_string(),
                origin: "https://example.com".to_string(),
                name: "书一".to_string(),
                custom_cover_url: Some(txt.clone()),
                ..Book::default()
            })
            .unwrap();
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://example.com/book/2".to_string(),
                origin: "https://example.com".to_string(),
                name: "书二".to_string(),
                custom_cover_url: Some(forged.clone()),
                ..Book::default()
            })
            .unwrap();
    }

    let app = create_router(state.clone());
    let (_, _, body) = get(app, &format!("/cover?path={}", enc(&txt))).await;
    assert_local_read_rejected(&body, b"plain-text-secret", "非图片扩展名");

    let app = create_router(state.clone());
    let (_, _, body) = get(app, &format!("/cover?path={}", enc(&forged))).await;
    assert_local_read_rejected(&body, b"not-an-image-at-all", "伪造图片扩展名");
}

/// 先红后绿（P1-2）：`/image` 的本地 path 分支同样受白名单约束
#[tokio::test]
async fn test_image_local_path_whitelist_enforced() {
    let fx = CoverFixture::new("image-endpoint");
    let secret_payload = b"IMAGE-ENDPOINT-SECRET";
    let secret = fx.write("secret.png", &png_bytes(secret_payload));
    let book_file = fx.write("lib/book.txt", b"book body");
    let legit = fx.write("lib/images/ok.png", &png_bytes(b"legit-image"));

    let state = make_test_state();
    {
        let db = state.db.lock().await;
        let repo = BookRepository::new(db.connection());
        repo.insert(&Book {
            book_url: "https://src.example.com/book/1".to_string(),
            origin: "https://src.example.com".to_string(),
            name: "在线书".to_string(),
            ..Book::default()
        })
        .unwrap();
        repo.insert(&Book {
            book_url: book_file.clone(),
            origin: "loc_book".to_string(),
            origin_name: "book.txt".to_string(),
            name: "本地书".to_string(),
            book_type: legado_core::models::book_type::LOCAL,
            ..Book::default()
        })
        .unwrap();
        // bookUrl 为无法解析的非 URL 垃圾串：解析失败后同样只能走白名单
        repo.insert(&Book {
            book_url: "not-a-valid-url".to_string(),
            origin: "junk".to_string(),
            name: "垃圾地址书".to_string(),
            ..Book::default()
        })
        .unwrap();
    }

    // 在线书籍 + 本地绝对路径（原审查实测的拖库形态）→ 必须拒绝
    let app = create_router(state.clone());
    let uri = format!(
        "/image?url={}&path={}",
        enc("https://src.example.com/book/1"),
        enc(&secret)
    );
    let (_, _, body) = get(app, &uri).await;
    assert_local_read_rejected(&body, secret_payload, "/image 本地绝对路径直读");

    // bookUrl 为垃圾串（解析必失败）+ 白名单外本地路径 → 仍必须拒绝（安全不降级）
    let app = create_router(state.clone());
    let uri = format!(
        "/image?url={}&path={}",
        enc("not-a-valid-url"),
        enc(&secret)
    );
    let (_, _, body) = get(app, &uri).await;
    assert_local_read_rejected(&body, secret_payload, "/image 垃圾 bookUrl + 白名单外路径");

    // 本地书目录内的图片 → 放行（保绿：不破坏正常图片代理）
    let app = create_router(state.clone());
    let uri = format!("/image?url={}&path={}", enc(&book_file), enc(&legit));
    let (status, _, body) = get(app, &uri).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, png_bytes(b"legit-image"));
}

#[tokio::test]
async fn test_image_requires_params() {
    let app = create_router(make_test_state());
    let (_, json) = get_json(app.clone(), "/image?path=https%3A%2F%2Fx%2F1.png").await;
    assert_eq!(json["errorMsg"], "bookUrl为空");

    let (_, json) = get_json(app, "/image?url=book1").await;
    assert_eq!(json["errorMsg"], "图片链接为空");
}

// ---------------------------------------------------------------------------
// 调研取证（2026-10-07）：Web 读正文「后端连接失败」失败面三态复现
//
// 背景：用户 iOS 实机 + PC 浏览器读正文弹红色横幅（原版 Vue 固有文案）。
// 前端该横幅仅在 axios reject（HTTP 非 2xx / 网络层失败 / 120s 超时）时出现，
// `isSuccess=false` 信封会正常落入页面错误位（errorMsg 可见）。本组用例
// 覆盖三种正文路径的响应形态，确认服务端信封语义与底层 errorMsg 可读性：
//
//   态1 在线书 + 书源缺失  → errorMsg「未找到书源」（与用户现象同型的
//       候选之一：书不在 server 端 DB / origin 不匹配时前端虽能显示
//       errorMsg，但根因不可读，只能看到笼统失败）；
//   态2 在线书 + 源可用（回环 mock 源站）→ 正文成功；
//   态3 本地书 → 文件解析正文成功。
//
// — 调研员 ｜ 2026-10-07
// ---------------------------------------------------------------------------

/// 态1：在线书 + 书源缺失（server 端 DB 无 `book.origin` 对应书源行）
///
/// 前端行为推演（BookChapter-DRyeLtSm.js:45199 附近）：`getBookContent`
/// HTTP 200 + `isSuccess=false` → 页面错误位显示 errorMsg「未找到书源」，
/// 不触发红色横幅。若用户横幅出现，说明失败发生在更早的 HTTP 层
/// （或 /getChapterList 阶段），需实机 F12 定位。
#[tokio::test]
async fn test_survey_content_online_book_source_missing_error_shape() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://src.example.com/book/1".to_string(),
                origin: "https://src.example.com".to_string(),
                name: "在线书".to_string(),
                ..Book::default()
            })
            .unwrap();
        BookChapterRepository::new(db.connection())
            .insert(&BookChapter {
                url: "https://src.example.com/book/1/ch0".to_string(),
                title: "第一章".to_string(),
                book_url: "https://src.example.com/book/1".to_string(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let (_, json) = get_json(
        app,
        "/getBookContent?url=https%3A%2F%2Fsrc.example.com%2Fbook%2F1&index=0",
    )
    .await;
    assert_eq!(json["isSuccess"], false, "json={json}");
    assert_eq!(json["errorMsg"], "未找到书源", "json={json}");
    assert!(json["data"].is_null());
}

/// 回环 mock 源站：正文页 `div.content` 内含可提取文本（态2 用）
async fn start_mock_content_source() -> String {
    use axum::response::Html;
    use axum::routing::get;

    async fn chapter() -> Html<String> {
        Html(
            "<html><body>\
             <div class=\"content\">调研态2正文第一段</div>\
             </body></html>"
                .to_string(),
        )
    }

    let app = axum::Router::new().route("/chapter/0", get(chapter));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock 正文源站可绑定回环端口");
    let addr = listener.local_addr().expect("mock 源站地址");
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

/// 态2：在线书 + 源可用（回环 mock 源站，规则源 css 正文规则）→ 正文成功
///
/// 证明 server 端 getBookContent 的网络抓取链（书源 DB 读取 → build_engine
/// → legado-fetcher get_content → 净化）在本机环境下完整可用；结合态1，
/// 若用户实测三态同型均正常，则失败面收敛到用户侧书源/网络环境。
#[tokio::test]
async fn test_survey_content_online_book_with_mock_source_succeeds() {
    let base = start_mock_content_source().await;
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        legado_db::BookSourceRepository::new(db.connection())
            .insert(&legado_core::models::BookSource {
                book_source_url: base.clone(),
                book_source_name: "调研 mock 源".to_string(),
                rule_content: Some(legado_core::models::rule::ContentRule {
                    content: Some("class.content@html".to_string()),
                    ..Default::default()
                }),
                ..Default::default()
            })
            .unwrap();
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: format!("{base}/book/1"),
                origin: base.clone(),
                name: "在线书可用源".to_string(),
                ..Book::default()
            })
            .unwrap();
        BookChapterRepository::new(db.connection())
            .insert(&BookChapter {
                url: format!("{base}/chapter/0"),
                title: "第一章".to_string(),
                book_url: format!("{base}/book/1"),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let (_, json) = get_json(
        app,
        &format!(
            "/getBookContent?url={}&index=0",
            enc(&format!("{base}/book/1"))
        ),
    )
    .await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert!(
        json["data"].as_str().unwrap_or_default().contains("调研态2正文"),
        "mock 源正文应经规则提取返回，json={json}"
    );
}

/// 态3：本地书 → 文件解析正文成功（不走书源与网络）
#[tokio::test]
async fn test_survey_content_local_book_succeeds() {
    let dir = std::env::temp_dir().join(format!("legado-survey-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("创建临时书库目录");
    let book_file = dir.join("survey-book.txt");
    std::fs::write(&book_file, "调研态3本地正文第一段\n\n调研态3本地正文第二段")
        .expect("写临时本地书");

    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: book_file.to_string_lossy().to_string(),
                origin: "loc_book".to_string(),
                origin_name: "survey-book.txt".to_string(),
                name: "本地书".to_string(),
                author: "作者".to_string(),
                book_type: legado_core::models::book_type::LOCAL,
                ..Book::default()
            })
            .unwrap();
    }
    // 本地书目录为空 → getChapterList 回退 refresh_local_toc 解析文件落库
    let app = create_router(state);
    let (_, toc) = get_json(
        app.clone(),
        &format!("/getChapterList?url={}", enc(&book_file.to_string_lossy())),
    )
    .await;
    assert_eq!(toc["isSuccess"], true, "toc={toc}");
    assert!(
        toc["data"].as_array().map(|a| !a.is_empty()).unwrap_or(false),
        "本地书目录应解析出章节，toc={toc}"
    );

    let (_, json) = get_json(
        app,
        &format!(
            "/getBookContent?url={}&index=0",
            enc(&book_file.to_string_lossy())
        ),
    )
    .await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert!(
        json["data"].as_str().unwrap_or_default().contains("调研态3本地正文"),
        "本地书正文应解析返回，json={json}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}
