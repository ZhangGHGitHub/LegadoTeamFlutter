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
        injected_paths: Default::default(),
        legacy_review: Default::default(),
        source_check: Default::default(),
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
    let (status, headers, body) = get(app, "/vue/assets/index-Bm4G1GTr.js").await;

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
    "isPrivate",
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
    "isPrivate",
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

// ---------------------------------------------------------------------------
// 批17：Web 阅读端 `@js:` 替换规则对齐（与 App 端共享 legado-js 执行器）
// ---------------------------------------------------------------------------

/// seed 一本书 + 一章 + 章节缓存正文（Web 正文净化测试基线）
async fn seed_cached_chapter(
    state: &Arc<AppState>,
    book_url: &str,
    book_name: &str,
    book_author: &str,
    chapter: &BookChapter,
    content: &str,
) {
    let db = state.db.lock().await;
    BookRepository::new(db.connection())
        .insert(&Book {
            book_url: book_url.to_string(),
            origin: "https://src.example.com".to_string(),
            origin_name: "测试书源".to_string(),
            name: book_name.to_string(),
            author: book_author.to_string(),
            ..Book::default()
        })
        .unwrap();
    BookChapterRepository::new(db.connection())
        .insert(chapter)
        .unwrap();
    CacheBookRepository::new(db.connection())
        .insert(&CachedChapter {
            id: 0,
            book_url: book_url.to_string(),
            chapter_index: chapter.index,
            chapter_title: chapter.title.clone(),
            chapter_url: chapter.url.clone(),
            content: content.to_string(),
            cached_at: 0,
            size_bytes: 0,
        })
        .unwrap();
}

/// 批17 先红后绿：Web `/getBookContent` 必须执行 `@js:` 替换规则
///
/// 修复前 `purify_content` 调用 `ContentProcessor::process(None)`，`@js:`
/// 规则被静默跳过（返回原文）；修复后与 App 端共享 legado-js 执行器。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_get_book_content_applies_js_replace_rule() {
    let state = make_test_state();
    let book_url = "https://b17.example.com/book/1";
    seed_cached_chapter(
        &state,
        book_url,
        "批十七书籍",
        "批十七作者",
        &BookChapter {
            url: "https://b17.example.com/ch/7".to_string(),
            title: "第七章 批十七".to_string(),
            book_url: book_url.to_string(),
            index: 7,
            ..BookChapter::default()
        },
        "前批十七标记后",
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_JS替换".to_string(),
            pattern: "批十七标记".to_string(),
            replacement: r#"@js: result + "!""#.to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    )
    .await;

    let app = create_router(state);
    let uri = format!("/getBookContent?url={}&index=7", enc(book_url));
    let (_, json) = get_json(app, &uri).await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"], "前批十七标记!后",
        "Web 阅读端必须执行 @js: 规则（修复前为原文）"
    );
}

/// 批17：Web 端 `@js:` 的 `chapter` / `book` 绑定来自章节行与书籍行
///
/// 对齐 App 端 `test_content_processing_js_bindings_chapter_and_book_visible`：
/// 字段全部断言，防止只绑 `result` 或绑定错行（如把第 0 章/其他书绑进来）。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_get_book_content_js_bindings_chapter_and_book_visible() {
    let state = make_test_state();
    let book_url = "https://b17.example.com/book/bind";
    seed_cached_chapter(
        &state,
        book_url,
        "批十七绑定书名",
        "批十七绑定作者",
        &BookChapter {
            url: "https://b17.example.com/ch/3".to_string(),
            title: "第三章 批十七绑定".to_string(),
            book_url: book_url.to_string(),
            index: 3,
            ..BookChapter::default()
        },
        "前批十七绑定标记后",
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_绑定可见".to_string(),
            pattern: "批十七绑定标记".to_string(),
            replacement: r#"@js: result + "|" + chapter.title + "|" + chapter.index + "|" + chapter.url + "|" + chapter.bookUrl + "|" + book.name + "|" + book.author + "|" + book.bookUrl"#.to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    )
    .await;

    let app = create_router(state);
    let uri = format!("/getBookContent?url={}&index=3", enc(book_url));
    let (_, json) = get_json(app, &uri).await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"],
        "前批十七绑定标记|第三章 批十七绑定|3|https://b17.example.com/ch/3|\
         https://b17.example.com/book/bind|批十七绑定书名|批十七绑定作者|\
         https://b17.example.com/book/bind后"
    );
}

/// 批17：`@js:` 抛错保留原文，且不阻断后续普通规则（与 App 端一致）
///
/// **覆盖性用例**：父提交（Web 跳过 `@js:`）同样保留原文，本用例防回归，
/// 不计入「修复前红」证据。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_get_book_content_js_rule_error_keeps_original_and_continues() {
    let state = make_test_state();
    let book_url = "https://b17.example.com/book/err";
    seed_cached_chapter(
        &state,
        book_url,
        "批十七抛错书",
        "作者",
        &BookChapter {
            url: "https://b17.example.com/ch/0".to_string(),
            title: "第一章".to_string(),
            book_url: book_url.to_string(),
            index: 0,
            ..BookChapter::default()
        },
        "前批十七抛错标记后 后续普通标记",
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_抛错".to_string(),
            pattern: "批十七抛错标记".to_string(),
            replacement: "@js:(function(){ throw new Error('boom'); })()".to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_后续普通".to_string(),
            pattern: "后续普通标记".to_string(),
            replacement: "已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    )
    .await;

    let app = create_router(state);
    let uri = format!("/getBookContent?url={}&index=0", enc(book_url));
    let (_, json) = get_json(app, &uri).await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"], "前批十七抛错标记后 已换",
        "@js: 抛错应保留原文，后续普通规则仍需执行"
    );
}

/// 批17：`@js:` 超时保留原文（规则级 timeoutMillisecond 生效）
///
/// **覆盖性用例**：父提交（Web 跳过 `@js:`）同样保留原文，本用例防回归，
/// 不计入「修复前红」证据。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_get_book_content_js_rule_timeout_keeps_original() {
    let state = make_test_state();
    let book_url = "https://b17.example.com/book/timeout";
    seed_cached_chapter(
        &state,
        book_url,
        "批十七超时书",
        "作者",
        &BookChapter {
            url: "https://b17.example.com/ch/0".to_string(),
            title: "第一章".to_string(),
            book_url: book_url.to_string(),
            index: 0,
            ..BookChapter::default()
        },
        "前批十七超时标记后",
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_超时".to_string(),
            pattern: "批十七超时标记".to_string(),
            replacement: "@js:while(true){}".to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            timeout_millisecond: 60,
            ..Default::default()
        },
    )
    .await;

    let app = create_router(state);
    let uri = format!("/getBookContent?url={}&index=0", enc(book_url));
    let (_, json) = get_json(app, &uri).await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"], "前批十七超时标记后",
        "@js: 超时应保留原文，不阻断正文返回"
    );
}

/// 批17：无 quickjs feature 时 Web 端明确不执行 `@js:`，其他规则仍生效
///
/// **覆盖性用例**：父提交旧管线同样不执行 `@js:`，本用例防回归，
/// 不计入「修复前红」证据。
#[cfg(not(feature = "quickjs"))]
#[tokio::test]
async fn test_get_book_content_js_rule_skipped_without_quickjs() {
    let state = make_test_state();
    let book_url = "https://b17.example.com/book/noqjs";
    seed_cached_chapter(
        &state,
        book_url,
        "批十七无JS书",
        "作者",
        &BookChapter {
            url: "https://b17.example.com/ch/0".to_string(),
            title: "第一章".to_string(),
            book_url: book_url.to_string(),
            index: 0,
            ..BookChapter::default()
        },
        "前批十七无JS标记后 普通标记",
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_无quickjs".to_string(),
            pattern: "批十七无JS标记".to_string(),
            replacement: r#"@js: result + "!""#.to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    )
    .await;
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "批17_普通".to_string(),
            pattern: "普通标记".to_string(),
            replacement: "已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            ..Default::default()
        },
    )
    .await;

    let app = create_router(state);
    let uri = format!("/getBookContent?url={}&index=0", enc(book_url));
    let (_, json) = get_json(app, &uri).await;
    assert_eq!(json["isSuccess"], true, "json={json}");
    assert_eq!(
        json["data"], "前批十七无JS标记后 已换",
        "无 quickjs 时 @js: 应保留原文，普通规则仍生效"
    );
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
        json["data"]
            .as_str()
            .unwrap_or_default()
            .contains("调研态2正文"),
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
        toc["data"]
            .as_array()
            .map(|a| !a.is_empty())
            .unwrap_or(false),
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
        json["data"]
            .as_str()
            .unwrap_or_default()
            .contains("调研态3本地正文"),
        "本地书正文应解析返回，json={json}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

// ---------------------------------------------------------------------------
// B3 写端点：POST /saveBook、/deleteBook、/addLocalBook + 图片缓存根白名单
// （原版依据：HttpServer.kt:88-94/246-258 + BookController.kt:251-330；
//   vue 请求形态：assets/web/uploadBook/js/html5_fun.js:137-139）
// ---------------------------------------------------------------------------

/// 带「任意字节体」的 POST（multipart 场景；响应一律为 ReturnData JSON）
async fn post_bytes(
    app: axum::Router,
    uri: &str,
    content_type: &str,
    body: Vec<u8>,
) -> (StatusCode, Value) {
    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(uri)
                .header("Content-Type", content_type)
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let status = resp.status();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

const MP_BOUNDARY: &str = "XLegadoTestBoundaryB3";

/// multipart 文本字段（对齐 vue `fd.append("fileName", file.name)`）
fn mp_text(name: &str, value: &str) -> Vec<u8> {
    format!("--{MP_BOUNDARY}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n")
        .into_bytes()
}

/// multipart 文件字段（对齐 vue `fd.append("fileData", file)`）
fn mp_file(name: &str, filename: &str, bytes: &[u8]) -> Vec<u8> {
    let mut v = format!(
        "--{MP_BOUNDARY}\r\nContent-Disposition: form-data; name=\"{name}\"; filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n"
    )
    .into_bytes();
    v.extend_from_slice(bytes);
    v.extend_from_slice(b"\r\n");
    v
}

fn mp_finish() -> Vec<u8> {
    format!("--{MP_BOUNDARY}--\r\n").into_bytes()
}

fn mp_content_type() -> String {
    format!("multipart/form-data; boundary={MP_BOUNDARY}")
}

/// 注入路径可配的测试状态（B3：图片缓存根 / 本地书保存根）
fn make_test_state_with_paths(
    image_cache_root: Option<std::path::PathBuf>,
    local_book_root: Option<std::path::PathBuf>,
) -> Arc<AppState> {
    let db = legado_db::init_in_memory_database().unwrap();
    Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
        injected_paths: legado_server::state::InjectedPaths {
            image_cache_root,
            local_book_root,
        },
        legacy_review: Default::default(),
        source_check: Default::default(),
    })
}

/// [批9a 审查 P2-4] Web `/saveBook` 缺 `isPrivate` 键时保留库内旧值：
/// vue 只改书名不得解除私密；显式 `isPrivate:false` 才清除。
#[tokio::test]
async fn test_save_book_without_is_private_preserves_flag() {
    let state = make_test_state();
    let app = create_router(state.clone());
    let book_url = "https://src.example.com/book/private";

    // 首次保存：显式标记私密
    let body = json!({
        "bookUrl": book_url,
        "origin": "https://src.example.com",
        "originName": "测试书源",
        "name": "私密书",
        "author": "作者甲",
        "isPrivate": true
    })
    .to_string();
    let (_, rd) = post_bytes(
        app.clone(),
        "/saveBook",
        "application/json",
        body.into_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");

    // Web 读取侧一致：LegacyBook 投影透出 isPrivate
    let (_, shelf) = get_json(app.clone(), "/getBookshelf").await;
    let arr = shelf["data"].as_array().unwrap();
    let row = arr.iter().find(|b| b["bookUrl"] == book_url).unwrap();
    assert_eq!(row["isPrivate"], true, "getBookshelf 应透出 isPrivate");

    // 只改书名、不带 isPrivate：库内私密标记必须保留
    let body2 = json!({
        "bookUrl": book_url,
        "name": "改名后的私密书",
        "author": "作者甲"
    })
    .to_string();
    let (_, rd2) = post_bytes(
        app.clone(),
        "/saveBook",
        "application/json",
        body2.into_bytes(),
    )
    .await;
    assert_eq!(rd2["isSuccess"], true, "rd2={rd2}");
    {
        let db = state.db.lock().await;
        let book = BookRepository::new(db.connection())
            .find_by_url(book_url)
            .unwrap()
            .unwrap();
        assert_eq!(book.name, "改名后的私密书");
        assert!(book.is_private, "缺 isPrivate 键不得清除私密标记");
    }

    // 显式 isPrivate:false 才解除私密
    let body3 = json!({
        "bookUrl": book_url,
        "name": "改名后的私密书",
        "author": "作者甲",
        "isPrivate": false
    })
    .to_string();
    let (_, rd3) = post_bytes(app, "/saveBook", "application/json", body3.into_bytes()).await;
    assert_eq!(rd3["isSuccess"], true, "rd3={rd3}");
    {
        let db = state.db.lock().await;
        let book = BookRepository::new(db.connection())
            .find_by_url(book_url)
            .unwrap()
            .unwrap();
        assert!(!book.is_private, "显式 false 应解除私密");
    }
}

/// vue 书架页保存书的正例 + upsert：整 Book 对象载荷（含 Book 未知的
/// `respondTime` 键，Gson/serde 均应忽略；BookShelf-*.js `respondTime in e` 判定）
#[tokio::test]
async fn test_save_book_upsert_and_bookshelf_visible() {
    let app = create_router(make_test_state());
    let body = json!({
        "bookUrl": "https://src.example.com/book/9",
        "origin": "https://src.example.com",
        "originName": "测试书源",
        "name": "网页保存书",
        "author": "作者甲",
        "respondTime": 123
    })
    .to_string();
    let (status, rd) = post_bytes(
        app.clone(),
        "/saveBook",
        "application/json",
        body.into_bytes(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "", "原版 setData(\"\")");

    // getBookshelf 立即可见（vue 保存后回书架刷新）
    let (_, shelf) = get_json(app.clone(), "/getBookshelf").await;
    assert_eq!(shelf["isSuccess"], true);
    let arr = shelf["data"].as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["bookUrl"], "https://src.example.com/book/9");
    assert_eq!(arr[0]["name"], "网页保存书");

    // upsert：同 bookUrl 改书名重存（对齐 Book.save() has→update else insert）
    let body2 = json!({
        "bookUrl": "https://src.example.com/book/9",
        "name": "改名后的书",
        "author": "作者甲"
    })
    .to_string();
    let (_, rd2) = post_bytes(
        app.clone(),
        "/saveBook",
        "application/json",
        body2.into_bytes(),
    )
    .await;
    assert_eq!(rd2["isSuccess"], true, "rd2={rd2}");
    let (_, shelf2) = get_json(app, "/getBookshelf").await;
    let arr2 = shelf2["data"].as_array().unwrap();
    assert_eq!(arr2.len(), 1, "同 bookUrl 重存不得重复成行");
    assert_eq!(arr2[0]["name"], "改名后的书");
}

/// [批31b P2-1] `/getBookshelf` 投影含 `readConfig.reverseTocDisplay`，
/// 且网页端整书回写（`/saveBook`）不还原该值
///
/// 缺陷背景：投影漏键时网页端拿到形状 → 编辑其他字段 → 整书写回，
/// serde 缺键按 `false` 解析，会把 App 侧已开启的「目录显示反转」静默
/// 还原（用户重开目录表现为反转丢失）。
#[tokio::test]
async fn test_bookshelf_projects_reverse_toc_display_and_save_roundtrip_keeps_it() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://example.com/book/rtd".to_string(),
                origin: "https://example.com".to_string(),
                name: "反转书".to_string(),
                author: "作者".to_string(),
                read_config: Some(legado_core::models::ReadConfig {
                    reverse_toc: true,
                    reverse_toc_display: true,
                    ..Default::default()
                }),
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state.clone());
    let (_, shelf) = get_json(app.clone(), "/getBookshelf").await;
    let book = &shelf["data"][0];
    assert_eq!(
        book["readConfig"]["reverseTocDisplay"], true,
        "投影必须输出 reverseTocDisplay（实际 readConfig={}）",
        book["readConfig"]
    );
    assert_eq!(book["readConfig"]["reverseToc"], true);

    // 模拟网页端把投影原样整书写回（只编辑其他字段）
    let (_, rd) = post_bytes(
        app.clone(),
        "/saveBook",
        "application/json",
        book.to_string().into_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");

    {
        let db = state.db.lock().await;
        let saved = BookRepository::new(db.connection())
            .find_by_url("https://example.com/book/rtd")
            .unwrap()
            .unwrap();
        let cfg = saved.read_config.expect("readConfig 应保留");
        assert!(cfg.reverse_toc_display, "回写后 DB 仍应为 true");
        assert!(cfg.reverse_toc);
    }
    // 再次投影仍为 true（网页端二次编辑/刷新不丢失）
    let (_, shelf2) = get_json(app, "/getBookshelf").await;
    assert_eq!(shelf2["data"][0]["readConfig"]["reverseTocDisplay"], true);
}

/// 解析失败 → 「格式不对」（对齐 fromJsonObject getOrNull 失败分支）
#[tokio::test]
async fn test_save_book_bad_format() {
    let app = create_router(make_test_state());
    for body in ["", "not-json", "[1,2]", "null"] {
        let (_, rd) = post_bytes(
            app.clone(),
            "/saveBook",
            "application/json",
            body.as_bytes().to_vec(),
        )
        .await;
        assert_eq!(rd["isSuccess"], false, "body={body} rd={rd}");
        assert_eq!(rd["errorMsg"], "格式不对", "body={body}");
        assert!(rd["data"].is_null());
    }
}

/// B-3 登记：saveBook 更新分支不回滚进度列（我方 update 结构性排除进度四列；
/// 原版 Room @Update 全列覆盖——载荷为陈旧快照，覆盖会丢 App 侧新进度）
#[tokio::test]
async fn test_save_book_does_not_rollback_progress() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        let repo = BookRepository::new(db.connection());
        repo.insert(&Book {
            book_url: "https://src.example.com/book/7".to_string(),
            origin: "https://src.example.com".to_string(),
            name: "进度书".to_string(),
            author: "作者".to_string(),
            ..Book::default()
        })
        .unwrap();
        repo.update_progress(
            "https://src.example.com/book/7",
            3,
            15,
            Some("第三章"),
            1_700_000_000_000,
        )
        .unwrap();
    }
    let app = create_router(state.clone());
    let body = json!({
        "bookUrl": "https://src.example.com/book/7",
        "name": "进度书",
        "durChapterIndex": 0,
        "durChapterPos": 0
    })
    .to_string();
    let (_, rd) = post_bytes(app, "/saveBook", "application/json", body.into_bytes()).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");

    // 进度列保持库内值（App 侧新进度不被 web 陈旧快照覆盖）
    {
        let db = state.db.lock().await;
        let book = BookRepository::new(db.connection())
            .find_by_url("https://src.example.com/book/7")
            .unwrap()
            .unwrap();
        assert_eq!(book.dur_chapter_index, 3, "进度不得被快照回滚");
        assert_eq!(book.dur_chapter_pos, 15);
    }
}

/// POST /deleteBook：按主键删行 + 章节外键级联（对齐 Room onDelete=CASCADE）
#[tokio::test]
async fn test_delete_book_removes_row_and_cascades_chapters() {
    let state = make_test_state();
    {
        let db = state.db.lock().await;
        let repo = BookRepository::new(db.connection());
        repo.insert(&Book {
            book_url: "https://src.example.com/book/8".to_string(),
            origin: "https://src.example.com".to_string(),
            name: "待删书".to_string(),
            author: "作者".to_string(),
            ..Book::default()
        })
        .unwrap();
        let chapters: Vec<BookChapter> = (0..2)
            .map(|i| BookChapter {
                url: format!("u8/ch{i}"),
                title: format!("第{i}章"),
                book_url: "https://src.example.com/book/8".to_string(),
                base_url: "https://src.example.com/book/8".to_string(),
                index: i,
                ..BookChapter::default()
            })
            .collect();
        BookChapterRepository::new(db.connection())
            .insert_batch(&chapters)
            .unwrap();
    }
    let app = create_router(state.clone());
    let body = json!({ "bookUrl": "https://src.example.com/book/8" }).to_string();
    let (_, rd) = post_bytes(
        app.clone(),
        "/deleteBook",
        "application/json",
        body.into_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "");

    // 书架空（原版空书架文案）
    let (_, shelf) = get_json(app, "/getBookshelf").await;
    assert_eq!(shelf["isSuccess"], false);
    assert_eq!(shelf["errorMsg"], "还没有添加小说");
    // 章节级联清空（cached_chapters 无外键、原版文件缓存同样残留，不在此断言）
    {
        let db = state.db.lock().await;
        assert!(BookChapterRepository::new(db.connection())
            .find_by_book_url("https://src.example.com/book/8")
            .unwrap()
            .is_empty());
    }
}

/// POST /deleteBook 解析失败 → 「格式不对」
#[tokio::test]
async fn test_delete_book_bad_format() {
    let app = create_router(make_test_state());
    let (_, rd) = post_bytes(app, "/deleteBook", "application/json", b"not-json".to_vec()).await;
    assert_eq!(rd["isSuccess"], false);
    assert_eq!(rd["errorMsg"], "格式不对");
}

/// 鉴权对照（原版 HttpServer.kt:246-258）：三写端点不在
/// PROTECTED_SOURCE_WRITE_ROUTES，**无 X-Legado-Token 也必须成功**
/// （vue 客户端令牌集合亦不含三者；B4 的书源写端点才有令牌面）
#[tokio::test]
async fn test_write_endpoints_require_no_token() {
    let app = create_router(make_test_state());
    let save_body =
        json!({"bookUrl": "https://src.example.com/book/nt", "name": "无令牌书"}).to_string();
    let (_, rd) = post_bytes(
        app.clone(),
        "/saveBook",
        "application/json",
        save_body.into_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "无令牌 saveBook 应成功 rd={rd}");
    let del_body = json!({"bookUrl": "https://src.example.com/book/nt"}).to_string();
    let (_, rd2) = post_bytes(
        app,
        "/deleteBook",
        "application/json",
        del_body.into_bytes(),
    )
    .await;
    assert_eq!(rd2["isSuccess"], true, "无令牌 deleteBook 应成功 rd2={rd2}");
}

/// addLocalBook 正例（真实 vue 形态 multipart：fileName + fileData）→
/// 落盘 + 书架可见（书名来自文件名解析）+ 目录可解析
#[tokio::test]
async fn test_add_local_book_success_end_to_end() {
    let fx = CoverFixture::new("b3-upload-e2e");
    let state = make_test_state_with_paths(None, Some(fx.path("books")));
    let app = create_router(state);
    let txt = "第一章 开始\n这是正文内容。\n";
    let mut body = mp_text("fileName", "测试之书.txt");
    body.extend(mp_file("fileData", "测试之书.txt", txt.as_bytes()));
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app.clone(), "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], true, "原版 setData(true)");

    // 文件落盘（根目录/测试之书.txt，字节一致）
    let saved = fx.path("books").join("测试之书.txt");
    assert!(saved.exists(), "文件应落盘到保存根");
    assert_eq!(std::fs::read(&saved).unwrap(), txt.as_bytes());

    // 书架可见：bookUrl = 相对可迁移标识（C1/O2；文件仍落绝对保存根）、
    // 书名 = 文件名解析（analyzeNameAuthor）、order = minOrder-1 = -1
    let (_, shelf) = get_json(app.clone(), "/getBookshelf").await;
    let arr = shelf["data"].as_array().unwrap();
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["name"], "测试之书");
    assert_eq!(arr[0]["originName"], "测试之书.txt");
    assert_eq!(arr[0]["order"], -1, "minOrder(空表0)-1");
    assert_eq!(
        arr[0]["bookUrl"], "books/测试之书.txt",
        "bookUrl 应存相对可迁移标识（与 FFI/Dart 本地书身份同源）"
    );

    // 目录可解析（txt 本地解析链；相对标识经注入保存根还原真实路径）
    let book_url = arr[0]["bookUrl"].as_str().unwrap().to_string();
    let (_, toc) = get_json(app, &format!("/getChapterList?url={}", enc(&book_url))).await;
    assert_eq!(toc["isSuccess"], true, "toc={toc}");
    assert!(
        toc["data"]
            .as_array()
            .map(|a| !a.is_empty())
            .unwrap_or(false),
        "上传的 txt 应解析出章节"
    );
}

/// addLocalBook：fileName 缺失 → 「fileName 不能为空」（原版 :311-312）
#[tokio::test]
async fn test_add_local_book_requires_file_name() {
    let state = make_test_state_with_paths(None, Some(std::env::temp_dir()));
    let app = create_router(state);
    let mut body = mp_file("fileData", "x.txt", b"data");
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app, "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(rd["errorMsg"], "fileName 不能为空");
}

/// addLocalBook：fileName 走 query 参数回退（原版 session.parameters 双来源）
#[tokio::test]
async fn test_add_local_book_file_name_via_query_param() {
    let fx = CoverFixture::new("b3-upload-query");
    let state = make_test_state_with_paths(None, Some(fx.path("books")));
    let app = create_router(state);
    let mut body = mp_file("fileData", "查询书.txt", "第一章 q\n内容\n".as_bytes());
    body.extend(mp_finish());
    let uri = format!("/addLocalBook?fileName={}", enc("查询书.txt"));
    let (_, rd) = post_bytes(app, &uri, &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert!(fx.path("books").join("查询书.txt").exists());
}

/// addLocalBook：fileName 路径逃逸类形态 → 「fileName 格式不正确」
///（requireSafeUploadedBookFileName 对齐：分隔符/盘符/相对段）
#[tokio::test]
async fn test_add_local_book_rejects_unsafe_file_name() {
    let state = make_test_state_with_paths(None, Some(std::env::temp_dir()));
    let app = create_router(state);
    for name in [
        "../evil.txt",
        "..\\evil.txt",
        "a/b.txt",
        "a\\b.txt",
        "C:evil.txt",
        ".",
    ] {
        let mut body = mp_text("fileName", name);
        body.extend(mp_file("fileData", "x.txt", b"z"));
        body.extend(mp_finish());
        let (_, rd) = post_bytes(app.clone(), "/addLocalBook", &mp_content_type(), body).await;
        assert_eq!(rd["isSuccess"], false, "name={name} rd={rd}");
        assert_eq!(rd["errorMsg"], "fileName 格式不正确", "name={name}");
    }
}

/// addLocalBook：fileData 缺失 → 「fileData 不能为空」（原版 :318-319）
#[tokio::test]
async fn test_add_local_book_requires_file_data() {
    let state = make_test_state_with_paths(None, Some(std::env::temp_dir()));
    let app = create_router(state);
    let mut body = mp_text("fileName", "a.txt");
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app, "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(rd["errorMsg"], "fileData 不能为空");
}

/// addLocalBook：扩展名白名单（封堵口径：原版服务端无、按解析器支持集从严）
#[tokio::test]
async fn test_add_local_book_rejects_disallowed_ext() {
    let fx = CoverFixture::new("b3-upload-ext");
    let state = make_test_state_with_paths(None, Some(fx.path("books")));
    let app = create_router(state);
    let mut body = mp_text("fileName", "evil.exe");
    body.extend(mp_file("fileData", "evil.exe", b"MZ"));
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app, "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert!(
        rd["errorMsg"]
            .as_str()
            .unwrap_or_default()
            .starts_with("保存书籍错误"),
        "rd={rd}"
    );
    assert!(
        !fx.path("books").join("evil.exe").exists(),
        "白名单外不得落盘"
    );
}

/// addLocalBook：空文件 → 「保存书籍错误\nUnexpected empty File」
///（EmptyFileException，LocalBook.kt:287）
#[tokio::test]
async fn test_add_local_book_rejects_empty_file() {
    let fx = CoverFixture::new("b3-upload-empty");
    let state = make_test_state_with_paths(None, Some(fx.path("books")));
    let app = create_router(state);
    let mut body = mp_text("fileName", "empty.txt");
    body.extend(mp_file("fileData", "empty.txt", b""));
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app, "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(rd["errorMsg"], "保存书籍错误\nUnexpected empty File");
}

/// addLocalBook：未注入本地书保存根 → 对齐原版「未设置书籍保存位置」
///（NoBooksDirException 文案，values-zh strings.xml:1399）
#[tokio::test]
async fn test_add_local_book_without_root_errors() {
    let app = create_router(make_test_state());
    let mut body = mp_text("fileName", "a.txt");
    body.extend(mp_file("fileData", "a.txt", b"data"));
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app, "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(rd["errorMsg"], "保存书籍错误\n没有设置书籍保存位置!");
}

/// addLocalBook：同名文件重复上传 → 更新链（行不重复、文件覆盖、成功）
#[tokio::test]
async fn test_add_local_book_reupload_updates_existing() {
    let fx = CoverFixture::new("b3-upload-reup");
    let state = make_test_state_with_paths(None, Some(fx.path("books")));
    let app = create_router(state.clone());
    for (idx, content) in ["第一版第一章\n甲\n", "第二版第一章\n乙\n"]
        .iter()
        .enumerate()
    {
        let mut body = mp_text("fileName", "重传书.txt");
        body.extend(mp_file("fileData", "重传书.txt", content.as_bytes()));
        body.extend(mp_finish());
        let (_, rd) = post_bytes(app.clone(), "/addLocalBook", &mp_content_type(), body).await;
        assert_eq!(rd["isSuccess"], true, "第{}次上传 rd={rd}", idx + 1);
    }
    // 书仅一行（importFile 更新链：行保持不变、删旧目录）
    assert_eq!(
        {
            let db = state.db.lock().await;
            BookRepository::new(db.connection()).count().unwrap()
        },
        1
    );
    // 文件被第二次上传覆盖
    let saved = fx.path("books").join("重传书.txt");
    assert_eq!(
        std::fs::read(&saved).unwrap(),
        "第二版第一章\n乙\n".as_bytes()
    );
}

/// addLocalBook：同名同作者冲突 → 「书架中已存在同名同作者书籍：…」
///（insertIgnore -1 分支文案，values-zh strings.xml:519）
#[tokio::test]
async fn test_add_local_book_identity_conflict() {
    let fx = CoverFixture::new("b3-upload-conflict");
    let state = make_test_state_with_paths(None, Some(fx.path("books")));
    {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://elsewhere/book".to_string(),
                name: "同名书".to_string(),
                author: String::new(),
                ..Book::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let mut body = mp_text("fileName", "同名书.txt");
    body.extend(mp_file(
        "fileData",
        "同名书.txt",
        "第一章 x\ny\n".as_bytes(),
    ));
    body.extend(mp_finish());
    let (_, rd) = post_bytes(app, "/addLocalBook", &mp_content_type(), body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(
        rd["errorMsg"], "书架中已存在同名同作者书籍：同名书 / ",
        "rd={rd}"
    );
}

/// 图片缓存根注入白名单（B3 登记）：注入根内的缓存图片可经 /cover 读取；
/// 注入不改变白名单外路径的拒绝行为
#[tokio::test]
async fn test_cover_allows_injected_image_cache_root() {
    let fx = CoverFixture::new("b3-imgcache");
    let png = png_bytes(b"b3-cache-root-payload");
    let cached = fx.write("bookdir/images/abc.png", &png);
    let state = make_test_state_with_paths(Some(fx.root.clone()), None);
    let app = create_router(state);
    let uri = format!("/cover?path={}", enc(&cached));
    let (status, headers, body) = get(app.clone(), &uri).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(header_str(&headers, "content-type"), "image/png");
    assert_eq!(body, png, "注入缓存根内的图片应可读");

    // 白名单外目录（未登记、未注入）仍然拒绝
    let outside = CoverFixture::new("b3-imgcache-outside");
    let secret = outside.write("x.png", &png_bytes(b"secret"));
    let (_, _, body2) = get(app, &format!("/cover?path={}", enc(&secret))).await;
    assert_local_read_rejected(&body2, b"secret", "白名单外路径");
}

// ---------------------------------------------------------------------------
// B4：管理读 + 令牌 7 条 + 段评 legacy 6 条
// （原版依据：HttpServer.kt:128-180/:246-278、BookSourceController.kt:28-35/
//  :189-205、RssSourceController.kt:15-66、ReplaceRuleController.kt:14-20、
//  HttpLogController.kt:13-39、ReviewController.kt:181-456）
// ---------------------------------------------------------------------------

const B4_TOKEN_HEADER: &str = "x-legado-token";
const B4_TOKEN_ERROR: &str = "Web 书源访问令牌未配置或不正确";

async fn get_with_headers(
    app: axum::Router,
    uri: &str,
    headers: &[(&str, &str)],
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut builder = Request::builder().uri(uri);
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let resp = app
        .oneshot(builder.body(Body::empty()).unwrap())
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

async fn get_json_with_headers(
    app: axum::Router,
    uri: &str,
    headers: &[(&str, &str)],
) -> (StatusCode, axum::http::HeaderMap, Value) {
    let (status, headers, body) = get_with_headers(app, uri, headers).await;
    (status, headers, serde_json::from_slice(&body).unwrap())
}

async fn post_json_with_headers(
    app: axum::Router,
    uri: &str,
    headers: &[(&str, &str)],
    body: &str,
) -> (StatusCode, axum::http::HeaderMap, Value) {
    let mut builder = Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header("Content-Type", "application/json");
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let resp = app
        .oneshot(builder.body(Body::from(body.to_string())).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let headers = resp.headers().clone();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, headers, serde_json::from_slice(&bytes).unwrap())
}

async fn seed_config(state: &Arc<AppState>, key: &str, value: &str) {
    let db = state.db.lock().await;
    legado_db::repository::cache_repository::CacheRepository::new(db.connection())
        .put(key, value, 0)
        .unwrap();
}

async fn seed_book_source(state: &Arc<AppState>, source: legado_core::models::BookSource) {
    let db = state.db.lock().await;
    legado_db::BookSourceRepository::new(db.connection())
        .insert(&source)
        .unwrap();
}

/// 段评上下文：书源（origin）+ 书 + 第 0 章
async fn seed_review_context(
    state: &Arc<AppState>,
    source_url: &str,
    rule: Option<legado_core::models::ReviewRule>,
    main_js: Option<String>,
) -> (String, String) {
    let book_url = format!("{source_url}/book/1");
    let chapter_url = format!("{source_url}/chapter/0");
    {
        let db = state.db.lock().await;
        legado_db::BookSourceRepository::new(db.connection())
            .insert(&legado_core::models::BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "段评测试源".to_string(),
                rule_review: rule,
                main_js,
                ..Default::default()
            })
            .unwrap();
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: book_url.clone(),
                origin: source_url.to_string(),
                name: "段评测试书".to_string(),
                author: "作者".to_string(),
                ..Book::default()
            })
            .unwrap();
        BookChapterRepository::new(db.connection())
            .insert(&BookChapter {
                url: chapter_url.clone(),
                title: "第一章".to_string(),
                book_url: book_url.clone(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
    }
    (book_url, chapter_url)
}

/// 规则书源段评 fixture 源站：summary / detail（两页）/ reply
async fn start_mock_review_source() -> String {
    use axum::extract::Query;
    use axum::routing::get;

    async fn summary() -> axum::Json<Value> {
        axum::Json(json!({
            "data": [
                {"idx": 1, "cnt": 5, "token": "p1"},
                {"idx": 2, "cnt": 0, "token": "p2"},
                {"idx": 3, "cnt": 12, "token": "p3"}
            ]
        }))
    }

    async fn detail(
        Query(params): Query<std::collections::HashMap<String, String>>,
    ) -> axum::Json<Value> {
        if params.get("page").map(String::as_str) == Some("2") {
            axum::Json(json!({
                "comments": [{"id": "c2", "user": "乙", "text": "第二页", "tag": ""}]
            }))
        } else {
            axum::Json(json!({
                // content 为内容协议 JSON：对齐原版段评规则常见形态，
                // replyToName 由 ReviewRuleParser.parseContentProtocol 解析
                "comments": [{
                    "id": "c1", "user": "甲",
                    "text": "{\"text\":\"好看\",\"replyToName\":\"楼主\",\"time\":\"昨天\"}",
                    "tag": "作者"
                }],
                "next": "/review/detail?page=2"
            }))
        }
    }

    async fn reply() -> axum::Json<Value> {
        axum::Json(json!({
            "data": {"reply_list": [
                {"uid": "r1", "avatar": "/a/1.jpg", "nick": "读者甲", "tag": "沙发",
                 "text": "{\"text\":\"写得真好\",\"replyToName\":\"楼主\"}"},
                {"uid": "r2", "avatar": "https://img.com/2.jpg", "nick": "读者乙", "tag": "", "text": "同意楼上"}
            ]}
        }))
    }

    let app = axum::Router::new()
        .route("/review/summary", get(summary))
        .route("/review/detail", get(detail))
        .route("/review/reply", get(reply));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("mock 段评源站可绑定回环端口");
    let addr = listener.local_addr().expect("mock 段评源站地址");
    tokio::spawn(async move {
        let _ = axum::serve(listener, app).await;
    });
    format!("http://{addr}")
}

fn review_rule_for(base: &str) -> legado_core::models::ReviewRule {
    legado_core::models::ReviewRule {
        enabled: true,
        review_summary_url: Some(format!("{base}/review/summary")),
        summary_list_rule: Some("$.data".into()),
        summary_paragraph_index_rule: Some("$.idx".into()),
        summary_paragraph_data_rule: Some("$.token".into()),
        summary_count_rule: Some("$.cnt".into()),
        review_detail_url: Some(format!("{base}/review/detail")),
        review_detail_next_page_url: Some("$.next".into()),
        detail_list_rule: Some("$.comments".into()),
        detail_id_rule: Some("$.id".into()),
        detail_name_rule: Some("$.user".into()),
        detail_badge_rule: Some("$.tag".into()),
        detail_content_rule: Some("$.text".into()),
        review_quote_url: Some(format!("{base}/review/reply")),
        reply_list_rule: Some("$.data.reply_list".into()),
        reply_id_rule: Some("$.uid".into()),
        reply_avatar_rule: Some("$.avatar".into()),
        reply_name_rule: Some("$.nick".into()),
        reply_badge_rule: Some("$.tag".into()),
        reply_content_rule: Some("$.text".into()),
        ..Default::default()
    }
}

fn b4_review_query(book_url: &str, index: i32) -> String {
    format!("url={}&index={index}", enc(book_url))
}

// ─── A 组：getBookSource / getBookSources / getRssSource / getRssSources ────

#[tokio::test]
async fn test_b4_book_source_reads_and_empty_message() {
    let state = make_test_state();
    let app = create_router(state.clone());

    // 空列表 → 原版「设备源列表为空」
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getBookSources", &[]).await;
    assert_eq!(rd["isSuccess"], false);
    assert_eq!(rd["errorMsg"], "设备源列表为空");
    assert!(rd["data"].is_null());

    // url 缺失 / 未命中错误文案
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getBookSource", &[]).await;
    assert_eq!(rd["errorMsg"], "参数url不能为空，请指定源地址");
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        "/getBookSource?url=https%3A%2F%2Fno.example.com",
        &[],
    )
    .await;
    assert_eq!(rd["errorMsg"], "未找到源，请检查书源地址");

    // customOrder 升序（对齐 bookSourceDao.all）
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://b.example.com".into(),
            book_source_name: "后".into(),
            custom_order: 5,
            ..Default::default()
        },
    )
    .await;
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://a.example.com".into(),
            book_source_name: "前".into(),
            custom_order: 1,
            ..Default::default()
        },
    )
    .await;

    let (_, _, rd) = get_json_with_headers(app.clone(), "/getBookSources", &[]).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    let arr = rd["data"].as_array().unwrap();
    assert_eq!(arr.len(), 2);
    assert_eq!(arr[0]["bookSourceName"], "前", "应按 customOrder 升序");
    assert_eq!(arr[0]["customOrder"], 1);
    assert_eq!(arr[1]["bookSourceName"], "后");

    // 单源读取（字段为 Kotlin 实体 camelCase 名）
    let (_, _, rd) =
        get_json_with_headers(app, "/getBookSource?url=https%3A%2F%2Fa.example.com", &[]).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["bookSourceUrl"], "https://a.example.com");
    assert_eq!(rd["data"]["bookSourceName"], "前");
}

#[tokio::test]
async fn test_b4_rss_source_reads_and_empty_message() {
    let state = make_test_state();
    let (_, _, rd) =
        get_json_with_headers(create_router(state.clone()), "/getRssSources", &[]).await;
    assert_eq!(rd["isSuccess"], false);
    assert_eq!(rd["errorMsg"], "源列表为空");

    {
        let db = state.db.lock().await;
        legado_db::repository::rss_source_repository::RssSourceRepository::new(db.connection())
            .insert(&legado_core::models::RssSource {
                source_url: "https://rss.example.com/1".into(),
                source_name: "订阅一".into(),
                custom_order: 2,
                ..Default::default()
            })
            .unwrap();
        legado_db::repository::rss_source_repository::RssSourceRepository::new(db.connection())
            .insert(&legado_core::models::RssSource {
                source_url: "https://rss.example.com/0".into(),
                source_name: "订阅零".into(),
                custom_order: 1,
                // P1-2 parity：nextContentUrl 必须出现在 /getRssSources 响应
                next_content_url: Some(".next@href".into()),
                ..Default::default()
            })
            .unwrap();
    }
    let app = create_router(state);
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getRssSources", &[]).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"][0]["sourceName"], "订阅零", "customOrder 升序");
    assert_eq!(
        rd["data"][0]["nextContentUrl"], ".next@href",
        "RSS 源响应应含原版 nextContentUrl 键"
    );

    let (_, _, rd) = get_json_with_headers(app.clone(), "/getRssSource", &[]).await;
    assert_eq!(rd["errorMsg"], "参数url不能为空，请指定书源地址");
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        "/getRssSource?url=https%3A%2F%2Fnope.example.com",
        &[],
    )
    .await;
    assert_eq!(rd["errorMsg"], "未找到源，请检查源地址");
    let (_, _, rd) = get_json_with_headers(
        app,
        "/getRssSource?url=https%3A%2F%2Frss.example.com%2F1",
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["sourceName"], "订阅一");
}

// ─── A 组：getReplaceRules 双层编码 ─────────────────────────────────────────

#[tokio::test]
async fn test_b4_replace_rules_double_encoded() {
    let state = make_test_state();
    let app = create_router(state.clone());

    // 空列表 → data 为字符串 "[]"（原版 setData(GSON.toJson(emptyList))）
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getReplaceRules", &[]).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    let raw = rd["data"].as_str().expect("data 必须是 JSON 字符串");
    assert_eq!(raw, "[]");

    {
        let db = state.db.lock().await;
        legado_db::ReplaceRuleRepository::new(db.connection())
            .insert(&legado_core::models::ReplaceRule {
                name: "后".into(),
                pattern: "b".into(),
                replacement: "B".into(),
                order: 9,
                ..Default::default()
            })
            .unwrap();
        legado_db::ReplaceRuleRepository::new(db.connection())
            .insert(&legado_core::models::ReplaceRule {
                name: "前".into(),
                pattern: "a".into(),
                replacement: "A".into(),
                order: 1,
                ..Default::default()
            })
            .unwrap();
    }
    let (_, _, rd) = get_json_with_headers(app, "/getReplaceRules", &[]).await;
    let raw = rd["data"].as_str().expect("双层编码：data 为字符串");
    let rules: Value = serde_json::from_str(raw).expect("data 内层应为合法 JSON 数组");
    let arr = rules.as_array().unwrap();
    assert_eq!(arr.len(), 2);
    assert_eq!(arr[0]["name"], "前", "sortOrder 升序");
    assert_eq!(arr[0]["sortOrder"], 1);
    assert_eq!(arr[0]["pattern"], "a");
}

// ─── A 组：令牌保护（红绿对）+ limit clamp + getHttpLog ────────────────────

fn b4_http_log_record(id: i64) -> legado_server::legacy::http_log::HttpLogRecord {
    legado_server::legacy::http_log::HttpLogRecord {
        id,
        time: 1_700_000_000_000 + id,
        method: "GET".into(),
        path: "/p".into(),
        url: format!("https://log.example.com/{id}"),
        status_code: 200,
        duration: 5,
        request_headers: "Accept: */*".into(),
        request_body: String::new(),
        response_headers: "Content-Type: application/json".into(),
        response_body: "{}".into(),
        error: None,
    }
}

#[tokio::test]
async fn test_b4_http_logs_token_red_green_and_limit_clamp() {
    use legado_server::legacy::http_log::http_log_store;

    http_log_store().clear();
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state);

    // 红：无令牌 / 错令牌 → 原版文案 + Connection: close + no-store
    for headers in [vec![], vec![(B4_TOKEN_HEADER, "wrong")]] {
        let (status, resp_headers, rd) =
            get_json_with_headers(app.clone(), "/getHttpLogs", &headers).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(rd["isSuccess"], false, "rd={rd}");
        assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR);
        assert_eq!(header_str(&resp_headers, "connection"), "close");
        assert_eq!(header_str(&resp_headers, "cache-control"), "no-store");
    }
    // 绿：正确令牌 → 成功 + recording=false + no-store
    let (_, resp_headers, rd) =
        get_json_with_headers(app.clone(), "/getHttpLogs", &[(B4_TOKEN_HEADER, "secret")]).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["recording"], false);
    assert_eq!(rd["data"]["logs"].as_array().unwrap().len(), 0);
    assert_eq!(header_str(&resp_headers, "cache-control"), "no-store");

    // 灌入 60 条（环形容量 50）→ limit 语义逐档断言
    for id in 1..=60 {
        http_log_store().add(b4_http_log_record(id));
    }
    let auth = [(B4_TOKEN_HEADER, "secret")];
    let cases = [
        (None, 50usize, 60i64), // 缺省 → MAX_RECORDS
        (Some("0"), 1, 60),     // clamp 下界
        (Some("-5"), 1, 60),    // 负数 → 1（非缺省 50）
        (Some("999"), 50, 60),  // clamp 上界
        (Some("abc"), 50, 60),  // 非数字 → 缺省
        (Some("7"), 7, 60),     // 正常值
    ];
    for (limit, expected_len, expected_first_id) in cases {
        let uri = match limit {
            Some(limit) => format!("/getHttpLogs?limit={limit}"),
            None => "/getHttpLogs".to_string(),
        };
        let (_, _, rd) = get_json_with_headers(app.clone(), &uri, &auth).await;
        assert_eq!(rd["isSuccess"], true, "limit={limit:?} rd={rd}");
        let logs = rd["data"]["logs"].as_array().unwrap();
        assert_eq!(logs.len(), expected_len, "limit={limit:?}");
        assert_eq!(logs[0]["id"], expected_first_id, "队首应是最新记录");
        assert_eq!(logs[0]["statusCode"], 200);
        assert!(logs[0].get("path").is_none(), "summary 只含七键");
    }

    // getHttpLog：缺 id / 未命中 / 命中（camelCase 全字段）
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getHttpLog", &auth).await;
    assert_eq!(rd["errorMsg"], "参数id不能为空");
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getHttpLog?id=9999", &auth).await;
    assert_eq!(rd["errorMsg"], "未找到 HTTP 记录 #9999");
    let (_, _, rd) = get_json_with_headers(app.clone(), "/getHttpLog?id=60", &auth).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["id"], 60);
    assert_eq!(rd["data"]["statusCode"], 200);
    assert_eq!(rd["data"]["requestHeaders"], "Accept: */*");
    assert_eq!(
        rd["data"]["responseHeaders"],
        "Content-Type: application/json"
    );
    assert!(rd["data"].get("error").is_none(), "error=null 时 GSON 省略");

    // getHttpLog 亦为受保护面
    let (_, _, rd) = get_json_with_headers(app, "/getHttpLog?id=60", &[]).await;
    assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR);

    http_log_store().clear();
}

// ─── A 组：非保护读端点不因已配置令牌而拒绝（B3 P2-6 红绿对） ───────────────

#[tokio::test]
async fn test_b4_unprotected_reads_ignore_configured_token() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://a.example.com".into(),
            book_source_name: "源".into(),
            ..Default::default()
        },
    )
    .await;
    {
        let db = state.db.lock().await;
        legado_db::repository::rss_source_repository::RssSourceRepository::new(db.connection())
            .insert(&legado_core::models::RssSource {
                source_url: "https://rss.example.com/1".into(),
                source_name: "订阅".into(),
                ..Default::default()
            })
            .unwrap();
    }
    let app = create_router(state);

    for uri in [
        "/getBookSources",
        "/getRssSources",
        "/getReplaceRules",
        "/getJsSourceApiTokenRequired",
        "/getBookSource?url=https%3A%2F%2Fa.example.com",
    ] {
        let (_, _, rd) = get_json_with_headers(app.clone(), uri, &[]).await;
        assert_eq!(rd["isSuccess"], true, "无令牌应放行 {uri} rd={rd}");
    }
    // getJsSourceApiTokenRequired 恒放行且 data 为裸布尔（缺省 true）+ no-store
    let (_, headers, rd) =
        get_json_with_headers(app.clone(), "/getJsSourceApiTokenRequired", &[]).await;
    assert_eq!(rd["data"], Value::Bool(true));
    assert_eq!(header_str(&headers, "cache-control"), "no-store");

    // 段评只读端点同样无令牌面（非令牌错误文案）
    let (_, _, rd) = get_json_with_headers(
        app,
        "/getReviewSummary?url=https%3A%2F%2Fnone.example.com%2Fbook&index=0",
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], false);
    assert_eq!(rd["errorMsg"], "未找到书籍");
    assert_ne!(rd["errorMsg"], B4_TOKEN_ERROR);
}

#[tokio::test]
async fn test_b4_js_source_api_token_required_config_override() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiTokenRequired", "false").await;
    let (_, _, rd) =
        get_json_with_headers(create_router(state), "/getJsSourceApiTokenRequired", &[]).await;
    assert_eq!(rd["data"], Value::Bool(false));
}

// ─── B 组：段评规则书源 fixture 回环 ────────────────────────────────────────

#[tokio::test]
async fn test_b4_review_summary_rule_source_fixture() {
    let base = start_mock_review_source().await;
    let state = make_test_state();
    let (book_url, _) =
        seed_review_context(&state, &base, Some(review_rule_for(&base)), None).await;
    let app = create_router(state);
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!("/getReviewSummary?{}", b4_review_query(&book_url, 0)),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["counts"]["1"], 5);
    assert_eq!(rd["data"]["counts"]["3"], 12);
    assert!(rd["data"]["counts"].get("2").is_none(), "count=0 不入表");
    assert_eq!(rd["data"]["keys"]["1"], "p1");
    assert_eq!(rd["data"]["keys"]["3"], "p3");

    // 规则未启用 → 空摘要成功响应（非异常）
    let state2 = make_test_state();
    let mut rule = review_rule_for(&base);
    rule.enabled = false;
    let (book_url2, _) = seed_review_context(&state2, &base, Some(rule), None).await;
    let (_, _, rd) = get_json_with_headers(
        create_router(state2),
        &format!("/getReviewSummary?{}", b4_review_query(&book_url2, 0)),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["counts"], json!({}));
    assert_eq!(rd["data"]["keys"], json!({}));
}

#[tokio::test]
async fn test_b4_review_detail_cursor_roundtrip() {
    let base = start_mock_review_source().await;
    let state = make_test_state();
    let (book_url, _) =
        seed_review_context(&state, &base, Some(review_rule_for(&base)), None).await;
    let app = create_router(state);
    let base_query = format!("{}&paraIndex=1&paraData=1", b4_review_query(&book_url, 0));

    // 第一页：一条 + nextCursor + hasMore
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!("/getReviewDetail?{base_query}&page=1"),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["items"].as_array().unwrap().len(), 1);
    assert_eq!(rd["data"]["items"][0]["id"], "c1");
    assert_eq!(rd["data"]["items"][0]["content"], "好看");
    // P1-1 parity：内容协议 replyToName/time 必须出现在线上响应（原版 DetailItem 同名键）
    assert_eq!(rd["data"]["items"][0]["replyToName"], "楼主");
    assert_eq!(rd["data"]["items"][0]["time"], "昨天");
    assert_eq!(rd["data"]["items"][0]["badges"][0], "作者");
    assert_eq!(rd["data"]["hasMore"], true);
    let cursor = rd["data"]["nextCursor"]
        .as_str()
        .expect("第一页应返回 nextCursor")
        .to_string();

    // 第二页：带游标 → 第二页数据，无 nextCursor / hasMore=false
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!(
            "/getReviewDetail?{base_query}&page=2&cursor={}",
            enc(&cursor)
        ),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["items"][0]["id"], "c2");
    assert_eq!(rd["data"]["hasMore"], false);
    assert!(rd["data"]["nextCursor"].is_null());

    // 无效游标 / 首页带游标
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!("/getReviewDetail?{base_query}&page=2&cursor=bogus"),
        &[],
    )
    .await;
    assert_eq!(rd["errorMsg"], "段评分页面游标无效或已过期");
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!("/getReviewDetail?{base_query}&page=1&cursor=bogus"),
        &[],
    )
    .await;
    assert_eq!(rd["errorMsg"], "首段评页不能使用分页游标");

    // 规则缺失 → 原版文案
    let state2 = make_test_state();
    let (book_url2, _) = seed_review_context(&state2, &base, None, None).await;
    let (_, _, rd) = get_json_with_headers(
        create_router(state2),
        &format!(
            "/getReviewDetail?{}&paraIndex=1&page=1",
            b4_review_query(&book_url2, 0)
        ),
        &[],
    )
    .await;
    assert_eq!(rd["errorMsg"], "段评规则未配置");
}

#[tokio::test]
async fn test_b4_review_replies_rule_source_fixture() {
    let base = start_mock_review_source().await;
    let state = make_test_state();
    let (book_url, _) =
        seed_review_context(&state, &base, Some(review_rule_for(&base)), None).await;
    let app = create_router(state);
    let query = format!(
        "{}&paraIndex=1&paraData=1&reviewId=c1&page=1",
        b4_review_query(&book_url, 0)
    );

    let (_, _, rd) =
        get_json_with_headers(app.clone(), &format!("/getReviewReplies?{query}"), &[]).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    let items = rd["data"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert_eq!(items[0]["id"], "r1");
    assert_eq!(items[0]["name"], "读者甲");
    assert_eq!(items[0]["content"], "写得真好");
    // P1-1 parity：回复条目的内容协议 replyToName 同样透传
    assert_eq!(items[0]["replyToName"], "楼主");
    assert!(items[0]["avatar"].as_str().unwrap().ends_with("/a/1.jpg"));
    // 纯文本回复不携带 replyToName 键（skip_serializing_if）
    assert!(items[1].get("replyToName").is_none());
    assert_eq!(items[1]["avatar"], "https://img.com/2.jpg");
    assert_eq!(rd["data"]["hasMore"], true);

    // reviewId 缺失 → 原版文案
    let (_, _, rd) = get_json_with_headers(
        app,
        &format!(
            "/getReviewReplies?{}&paraIndex=1&page=1",
            b4_review_query(&book_url, 0)
        ),
        &[],
    )
    .await;
    assert_eq!(rd["errorMsg"], "参数 reviewId 不能为空");
}

#[tokio::test]
async fn test_b4_review_context_validation_errors() {
    let state = make_test_state();
    let (book_url, _) = seed_review_context(
        &state,
        "https://ctx.example.com",
        Some(review_rule_for("https://ctx.example.com")),
        None,
    )
    .await;
    let app = create_router(state);

    let cases = [
        ("/getReviewSummary?index=0".to_string(), "参数 url 不能为空"),
        (
            format!("/getReviewSummary?url={}", enc(&book_url)),
            "参数 index 不能为空",
        ),
        (
            format!("/getReviewSummary?url={}&index=-1", enc(&book_url)),
            "参数 index 无效",
        ),
        (
            format!(
                "/getReviewDetail?{}&paraIndex=0&page=1",
                b4_review_query(&book_url, 0)
            ),
            "参数 paraIndex 无效",
        ),
        (
            format!(
                "/getReviewDetail?{}&paraIndex=1&page=0",
                b4_review_query(&book_url, 0)
            ),
            "参数 page 无效",
        ),
        (
            format!(
                "/getReviewReplies?{}&paraIndex=1&reviewId=r&page=0",
                b4_review_query(&book_url, 0)
            ),
            "参数 page 无效",
        ),
        (
            format!("/getReviewSummary?url={}&index=9", enc(&book_url)),
            "未找到章节",
        ),
    ];
    for (uri, expected) in cases {
        let (_, _, rd) = get_json_with_headers(app.clone(), &uri, &[]).await;
        assert_eq!(rd["errorMsg"], expected, "uri={uri} rd={rd}");
    }
}

// ─── B 组：legacyReviewPage（404 / 注入 / CSP） ─────────────────────────────

#[tokio::test]
async fn test_b4_legacy_review_page_404_and_headers() {
    let app = create_router(make_test_state());
    let (status, headers, body) =
        get_with_headers(app, "/legacyReviewPage?id=x&nonce=y", &[]).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(String::from_utf8(body).unwrap(), "旧评论会话无效或已过期");
    assert_eq!(
        header_str(&headers, "content-type"),
        "text/plain; charset=utf-8"
    );
    assert_eq!(header_str(&headers, "x-content-type-options"), "nosniff");
    assert_eq!(header_str(&headers, "cache-control"), "no-store");
    assert_eq!(header_str(&headers, "referrer-policy"), "no-referrer");
    let csp = header_str(&headers, "content-security-policy");
    assert!(
        csp.contains("sandbox allow-scripts allow-modals"),
        "csp={csp}"
    );
    assert!(
        csp.contains("frame-ancestors 'self'"),
        "404 无 Origin → 'self'"
    );
}

#[tokio::test]
async fn test_b4_legacy_review_page_injected_session_csp() {
    use legado_server::legacy::review_api::LegacyReviewSession;

    let state = make_test_state();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    {
        let mut shared = state.legacy_review.lock().unwrap();
        shared.put_session(
            "sess-1".into(),
            LegacyReviewSession {
                book_url: "https://src.example.com/book/1".into(),
                chapter_index: 0,
                source_key: "https://src.example.com".into(),
                nonce: "n-1".into(),
                page_url: "https://src.example.com/review/1".into(),
                page_html:
                    "<html><head><title>旧评论</title></head><body><div id=\"viewer\"></div></body></html>"
                        .into(),
                preload_js: "window.__legadoPreload = true;".into(),
                frame_origin: Some("http://127.0.0.1:1122".into()),
                expires_at: now + 120_000,
            },
        );
        // 过期会话 → 404
        let expired = LegacyReviewSession {
            expires_at: now - 1,
            nonce: "n-old".into(),
            ..shared.get_session("sess-1").unwrap()
        };
        shared.put_session("sess-old".into(), expired);
    }
    let app = create_router(state);

    // 命中：桥接脚本 + base + preload + meta CSP；响应头 CSP 回显 Origin
    let (status, headers, body) = get_with_headers(
        app.clone(),
        "/legacyReviewPage?id=sess-1&nonce=n-1",
        &[("Origin", "http://127.0.0.1:1122")],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        header_str(&headers, "content-type"),
        "text/html; charset=utf-8"
    );
    let html = String::from_utf8(body).unwrap();
    assert!(html.contains("legado-legacy-review-run"), "缺少桥接脚本");
    assert!(html.contains("const nonce = \"n-1\""), "nonce 未注入");
    assert!(
        html.contains("<base href=\"https://src.example.com/review/1\">"),
        "base 未注入"
    );
    assert!(
        html.contains("window.__legadoPreload = true;"),
        "preload 未注入"
    );
    assert!(
        html.contains("<meta http-equiv=\"Content-Security-Policy\""),
        "meta CSP 未注入"
    );
    let csp = header_str(&headers, "content-security-policy");
    assert!(
        csp.contains("frame-ancestors http://127.0.0.1:1122"),
        "csp={csp}"
    );
    assert_eq!(
        header_str(&headers, "access-control-allow-origin"),
        "http://127.0.0.1:1122"
    );
    assert_eq!(header_str(&headers, "cache-control"), "no-store");
    assert_eq!(header_str(&headers, "referrer-policy"), "no-referrer");

    // nonce 不符 / 过期 / 缺 nonce → 404
    for uri in [
        "/legacyReviewPage?id=sess-1&nonce=wrong",
        "/legacyReviewPage?id=sess-old&nonce=n-old",
        "/legacyReviewPage?id=sess-1",
    ] {
        let (status, _, body) = get_with_headers(app.clone(), uri, &[]).await;
        assert_eq!(status, StatusCode::NOT_FOUND, "uri={uri}");
        assert_eq!(String::from_utf8(body).unwrap(), "旧评论会话无效或已过期");
    }
}

// ─── B 组：openLegacyReview / runLegacyReview（令牌 + 校验） ────────────────

#[tokio::test]
async fn test_b4_open_run_legacy_review_token_and_validation() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let (book_url, _) = seed_review_context(&state, "https://src.example.com", None, None).await;
    let app = create_router(state);
    let auth = [(B4_TOKEN_HEADER, "secret")];

    // 红：无令牌（两条均在 PROTECTED_SOURCE_WRITE_ROUTES）
    for (uri, body) in [("/openLegacyReview", "{}"), ("/runLegacyReview", "{}")] {
        let (_, headers, rd) = post_json_with_headers(app.clone(), uri, &[], body).await;
        assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "uri={uri} rd={rd}");
        assert_eq!(header_str(&headers, "connection"), "close");
    }

    // 绿：令牌通过后进入业务校验
    let (_, _, rd) =
        post_json_with_headers(app.clone(), "/openLegacyReview", &auth, "not-json").await;
    assert!(
        rd["errorMsg"]
            .as_str()
            .unwrap_or_default()
            .starts_with("数据格式错误"),
        "rd={rd}"
    );
    // 缺省 index = -1（原版默认）→ 参数 index 无效
    let body = json!({"url": book_url, "src": "cb(),{\"click\":\"getDP(1,2)\"}"}).to_string();
    let (_, _, rd) = post_json_with_headers(app.clone(), "/openLegacyReview", &auth, &body).await;
    assert_eq!(rd["errorMsg"], "参数 index 无效", "rd={rd}");
    // 非法 click 白名单 → 原版文案
    let body =
        json!({"url": book_url, "index": 0, "src": "cb(),{\"click\":\"alert(1)\"}"}).to_string();
    let (_, _, rd) = post_json_with_headers(app.clone(), "/openLegacyReview", &auth, &body).await;
    assert_eq!(rd["errorMsg"], "不是受支持的旧段评或章评链接", "rd={rd}");
    // 合法 click 但无 JS 引擎/函数：返回失败（不伪造成功）
    let body =
        json!({"url": book_url, "index": 0, "src": "cb(),{\"click\":\"getDP(1,2)\"}"}).to_string();
    let (_, _, rd) = post_json_with_headers(app.clone(), "/openLegacyReview", &auth, &body).await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");

    // run：空脚本 / 超长脚本 / 未知会话
    for script in ["", "   "] {
        let body = json!({"id": "x", "script": script}).to_string();
        let (_, _, rd) =
            post_json_with_headers(app.clone(), "/runLegacyReview", &auth, &body).await;
        assert_eq!(rd["errorMsg"], "旧评论脚本为空或过长", "script={script:?}");
    }
    let long_script = "a".repeat(64 * 1024 + 1);
    let body = json!({"id": "x", "script": long_script}).to_string();
    let (_, _, rd) = post_json_with_headers(app.clone(), "/runLegacyReview", &auth, &body).await;
    assert_eq!(rd["errorMsg"], "旧评论脚本为空或过长");
    let body = json!({"id": "no-such-session", "script": "1+1"}).to_string();
    let (_, _, rd) = post_json_with_headers(app, "/runLegacyReview", &auth, &body).await;
    assert_eq!(rd["errorMsg"], "旧评论会话无效或已过期");
}

// ─── B 组：JS 书源（函数缺失 → 空页；非 quickjs → 引擎占位错误） ──────────

#[tokio::test]
async fn test_b4_review_js_source_degradation() {
    let base = start_mock_review_source().await;
    let state = make_test_state();
    let (book_url, _) = seed_review_context(
        &state,
        &base,
        None,
        Some("function getReviewSummary() { return []; }".into()),
    )
    .await;
    let app = create_router(state);

    // 摘要：JS 函数存在（或引擎不可用被吞）→ 空摘要成功
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!("/getReviewSummary?{}", b4_review_query(&book_url, 0)),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], json!({"counts": {}, "keys": {}}));

    // 详情：引擎/函数错误按错误返回（不伪造空页）
    let (_, _, rd) = get_json_with_headers(
        app.clone(),
        &format!(
            "/getReviewDetail?{}&paraIndex=1&page=1",
            b4_review_query(&book_url, 0)
        ),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");

    // 回复：脚本未定义 getReviewReplies → 原版 callOptionalFunction 缺失语义
    // （null → 空页）；非 quickjs 构建无 JS 引擎 → 引擎占位错误
    let (_, _, rd) = get_json_with_headers(
        app,
        &format!(
            "/getReviewReplies?{}&paraIndex=1&reviewId=r1&page=1",
            b4_review_query(&book_url, 0)
        ),
        &[],
    )
    .await;
    if cfg!(feature = "quickjs") {
        assert_eq!(rd["isSuccess"], true, "rd={rd}");
        assert_eq!(rd["data"], json!({"items": [], "hasMore": false}));
    } else {
        assert_eq!(rd["isSuccess"], false, "rd={rd}");
        assert!(
            rd["errorMsg"]
                .as_str()
                .unwrap_or_default()
                .contains("QuickJS"),
            "非 quickjs 构建应回引擎占位错误: {rd}"
        );
    }
}

/// JS 书源段评回复（批12）：QuickJS 下脚本实现 getReviewReplies → 扁平化列表 + hasMore
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_b4_review_replies_js_source_fixture() {
    let state = make_test_state();
    let main_js = r#"
function getReviewReplies(chapter, book, paraIndex, paraData, reviewId, page) {
    return JSON.stringify({items: [
        {id: reviewId, name: "读者甲", avatar: "/a/1.jpg",
         content: "{\"text\":\"写得真好\",\"replyToName\":\"楼主\"}",
         replies: [{id: "r2", content: "楼中楼"}]},
        {id: "r3", name: "读者乙", content: paraData + ":" + page}
    ]});
}
"#;
    let (book_url, _) = seed_review_context(
        &state,
        "https://js-replies.example.com",
        None,
        Some(main_js.into()),
    )
    .await;
    let app = create_router(state);

    let (_, _, rd) = get_json_with_headers(
        app,
        &format!(
            "/getReviewReplies?{}&paraIndex=2&paraData=p2&reviewId=c1&page=1",
            b4_review_query(&book_url, 0)
        ),
        &[],
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    let items = rd["data"]["items"].as_array().unwrap();
    // 顶层两条 + 嵌套一条（嵌套回复扁平化，紧随父级）
    assert_eq!(items.len(), 3, "rd={rd}");
    assert_eq!(items[0]["id"], "c1");
    assert_eq!(items[0]["name"], "读者甲");
    assert_eq!(items[0]["content"], "写得真好");
    assert_eq!(items[0]["replyToName"], "楼主");
    assert!(
        items[0]["avatar"].as_str().unwrap().ends_with("/a/1.jpg"),
        "相对 avatar 应绝对化: {rd}"
    );
    assert_eq!(items[1]["id"], "r2");
    assert_eq!(items[2]["content"], "p2:1");
    // hasMore 对齐原版 items.isNotEmpty()
    assert_eq!(rd["data"]["hasMore"], true);
    assert!(rd["data"]["nextCursor"].is_null());
}

// ─── B 组：legacy 脚本求值端到端（quickjs 门控；默认构建走占位错误分支） ─────

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_b4_legacy_review_js_end_to_end() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let main_js = "function getDP(a, b) { \
        java.showBrowser('http://legacy.example.com/page', \
        '<html><head><title>p</title></head><body><img src=\"https://a.com/1.heic\"></body></html>', \
        'window.__pre = 1;'); \
        return a + b; }";
    let (book_url, _) = seed_review_context(
        &state,
        "https://src.example.com",
        None,
        Some(main_js.into()),
    )
    .await;
    let app = create_router(state);
    let auth = [(B4_TOKEN_HEADER, "secret")];

    // open：click 白名单脚本 → java.showBrowser 载荷 → 会话
    let body = json!({
        "url": book_url,
        "index": 0,
        "src": "cb(),{\"click\":\"getDP(1,2)\"}"
    })
    .to_string();
    let (_, _, rd) = post_json_with_headers(app.clone(), "/openLegacyReview", &auth, &body).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    let id = rd["data"]["id"].as_str().expect("id").to_string();
    let nonce = rd["data"]["nonce"].as_str().expect("nonce").to_string();

    // 页面：桥接注入 + HEIF 已改写为 /image 代理
    let (status, _, html) = get_with_headers(
        app.clone(),
        &format!("/legacyReviewPage?id={}&nonce={}", enc(&id), enc(&nonce)),
        &[],
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let html = String::from_utf8(html).unwrap();
    assert!(html.contains("legado-legacy-review-run"));
    assert!(
        html.contains("/image?path=https%3A%2F%2Fa.com%2F1.heic"),
        "open 时应重写 HEIF 图片：{html}"
    );
    assert!(html.contains("window.__pre = 1;"));

    // run：脚本求值 → 结果（HEIF 重写链路对普通值原样返回）
    let body = json!({"id": id, "script": "1 + 1"}).to_string();
    let (_, _, rd) = post_json_with_headers(app, "/runLegacyReview", &auth, &body).await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "2");
}

// ---------------------------------------------------------------------------
// B6：源写端点 10 条 + 令牌红绿 + 批量事务回滚
// （原版依据：HttpServer.kt:58-110/:246-258、BookSourceController.kt:37-216、
//  RssSourceController.kt:24-76、ReplaceRuleController.kt:23-107、
//  JsSourceUpsert.kt:11-129）
// ---------------------------------------------------------------------------

const B6_TOKEN: &str = B4_TOKEN_HEADER;

async fn post_write_raw(
    app: axum::Router,
    uri: &str,
    content_type: Option<&str>,
    headers: &[(&str, &str)],
    body: &[u8],
) -> (StatusCode, axum::http::HeaderMap, Vec<u8>) {
    let mut builder = Request::builder().method(Method::POST).uri(uri);
    if let Some(content_type) = content_type {
        builder = builder.header("Content-Type", content_type);
    }
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    let resp = app
        .oneshot(builder.body(Body::from(body.to_vec())).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let headers = resp.headers().clone();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec();
    (status, headers, bytes)
}

async fn post_write_json(
    app: axum::Router,
    uri: &str,
    content_type: Option<&str>,
    headers: &[(&str, &str)],
    body: &[u8],
) -> (StatusCode, axum::http::HeaderMap, Value) {
    let (status, headers, bytes) = post_write_raw(app, uri, content_type, headers, body).await;
    (status, headers, serde_json::from_slice(&bytes).unwrap())
}

/// `saveJsSource` 专用：默认 `text/plain; charset=utf-8` + 自动 Content-Length
async fn post_js_source_with(
    app: axum::Router,
    uri: &str,
    token: Option<&str>,
    content_type: Option<&str>,
    content_length: Option<usize>,
    extra: &[(&str, &str)],
    body: &[u8],
) -> (StatusCode, axum::http::HeaderMap, Value) {
    let mut builder = Request::builder().method(Method::POST).uri(uri);
    builder = builder.header(
        "Content-Type",
        content_type.unwrap_or("text/plain; charset=utf-8"),
    );
    if let Some(content_length) = content_length {
        builder = builder.header("Content-Length", content_length.to_string());
    }
    if let Some(token) = token {
        builder = builder.header(B6_TOKEN, token);
    }
    for (name, value) in extra {
        builder = builder.header(*name, *value);
    }
    let resp = app
        .oneshot(builder.body(Body::from(body.to_vec())).unwrap())
        .await
        .unwrap();
    let status = resp.status();
    let headers = resp.headers().clone();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, headers, serde_json::from_slice(&bytes).unwrap())
}

async fn seed_rss_source(state: &Arc<AppState>, source_url: &str, source_name: &str) {
    let db = state.db.lock().await;
    legado_db::repository::rss_source_repository::RssSourceRepository::new(db.connection())
        .insert(&legado_core::models::RssSource {
            source_url: source_url.to_string(),
            source_name: source_name.to_string(),
            ..Default::default()
        })
        .unwrap();
}

async fn seed_replace_rule(state: &Arc<AppState>, rule: &legado_core::models::ReplaceRule) -> i64 {
    let db = state.db.lock().await;
    legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
        .insert(rule)
        .unwrap()
}

/// 10 条写端点全部在 `PROTECTED_SOURCE_WRITE_ROUTES`：无令牌一律拒绝
#[tokio::test]
async fn test_b6_all_write_routes_require_token() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state);

    for uri in [
        "/saveBookSource",
        "/saveBookSources",
        "/deleteBookSources",
        "/saveJsSource",
        "/saveRssSource",
        "/saveRssSources",
        "/deleteRssSources",
        "/saveReplaceRule",
        "/deleteReplaceRule",
        "/testReplaceRule",
    ] {
        let (status, headers, body) =
            post_write_raw(app.clone(), uri, Some("application/json"), &[], b"{}").await;
        assert_eq!(status, StatusCode::OK, "{uri}");
        let rd: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(rd["isSuccess"], false, "{uri} rd={rd}");
        assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "{uri}");
        assert_eq!(
            header_str(&headers, "connection"),
            "close",
            "{uri} 令牌失败应关闭连接（原版 shouldCloseConnection）"
        );
    }

    // 正确令牌通过令牌面（非令牌错误文案）
    let (_, headers, rd) = post_write_json(
        app,
        "/deleteBookSources",
        Some("application/json"),
        &[(B6_TOKEN, "secret")],
        b"[]",
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_ne!(header_str(&headers, "connection"), "close");
}

/// [批17 三审 P2] Web 端口 `/mcp/call` 与源写端点同级：无令牌必须被拒
///
/// `/mcp/call` 的 `eval_js` 可执行任意 JS（timeout 5..600s），此前未挂令牌
/// 守卫，可占满 server runtime 的 blocking 池；现纳入
/// `PROTECTED_SOURCE_WRITE_ROUTES`，生产入口
/// [`legado_server::server::attach_source_write_token_guard`] 在 body 提取前
/// 直接拒绝（此处按生产入口显式挂载；`create_router` 本体保持无状态）。
#[tokio::test]
async fn test_web_mcp_call_requires_source_write_token() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = legado_server::server::attach_source_write_token_guard(
        create_router(Arc::clone(&state)),
        state,
    );
    let body = json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": "eval_js", "arguments": {"js": "1+1"}}
    })
    .to_string();

    // 无令牌：前置守卫拒绝（原版失败信封 + Connection: close）
    let (status, headers, rd) = post_write_json(
        app.clone(),
        "/mcp/call",
        Some("application/json"),
        &[],
        body.as_bytes(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "rd={rd}");
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "rd={rd}");
    assert_eq!(
        header_str(&headers, "connection"),
        "close",
        "令牌失败应关闭连接（原版 shouldCloseConnection）"
    );

    // 正确令牌：进入 MCP handler（不再是令牌错误；quickjs 档/默认档均成立）
    let (_, _, rd) = post_write_json(
        app,
        "/mcp/call",
        Some("application/json"),
        &[(B6_TOKEN, "secret")],
        body.as_bytes(),
    )
    .await;
    assert_ne!(rd["errorMsg"], B4_TOKEN_ERROR, "rd={rd}");
}

#[tokio::test]
async fn test_b6_save_book_source_upsert_and_errors() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 缺参（空体 → NanoHTTPD postData=null）
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSource",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空", "rd={rd}");

    // 坏 JSON
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSource",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "转换源失败", "rd={rd}");

    // 名称缺失
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSource",
        Some("application/json"),
        &auth,
        br#"{"bookSourceUrl":"https://b6.book/1"}"#,
    )
    .await;
    assert_eq!(rd["errorMsg"], "源名称和URL不能为空", "rd={rd}");

    // 正例 + REPLACE upsert
    let body = r#"{"bookSourceUrl":"https://b6.book/1","bookSourceName":"B6书源"}"#.as_bytes();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSource",
        Some("application/json"),
        &auth,
        body,
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "");

    let body = r#"{"bookSourceUrl":"https://b6.book/1","bookSourceName":"B6书源改"}"#.as_bytes();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSource",
        Some("application/json"),
        &auth,
        body,
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");

    let (_, rd) = get_json(
        app,
        &format!("/getBookSource?url={}", enc("https://b6.book/1")),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["bookSourceName"], "B6书源改");

    let count = {
        let db = state.db.lock().await;
        legado_db::BookSourceRepository::new(db.connection())
            .count()
            .unwrap()
    };
    assert_eq!(count, 1, "REPLACE 语义：同 URL 只保留一行");
}

#[tokio::test]
async fn test_b6_save_book_sources_batch_and_rollback() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    {
        let db = state.db.lock().await;
        db.connection()
            .execute(
                "CREATE TRIGGER b6_fail_book BEFORE INSERT ON book_sources
                 WHEN NEW.bookSourceUrl = 'https://b6.batch/boom'
                 BEGIN SELECT RAISE(ABORT, 'b6 batch boom'); END",
                [],
            )
            .unwrap();
    }
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 缺参 / 坏 JSON / 空数组
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSources",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSources",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "转换源失败");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSources",
        Some("application/json"),
        &auth,
        b"[]",
    )
    .await;
    assert_eq!(rd["errorMsg"], "转换源失败");

    // 跳过空名/空 URL，返回成功数组
    let body = json!([
        {"bookSourceUrl": "https://b6.batch/1", "bookSourceName": "一"},
        {"bookSourceUrl": "https://b6.batch/2", "bookSourceName": "  "},
        {"bookSourceUrl": "https://b6.batch/3", "bookSourceName": "三"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"].as_array().unwrap().len(), 2);

    // 事务回滚：第二条触发 ABORT → 整批不落库
    let body = json!([
        {"bookSourceUrl": "https://b6.batch/roll-ok", "bookSourceName": "回滚好"},
        {"bookSourceUrl": "https://b6.batch/boom", "bookSourceName": "回滚炸"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert!(
        rd["errorMsg"]
            .as_str()
            .unwrap_or_default()
            .contains("b6 batch boom"),
        "rd={rd}"
    );
    let (_, rd) = get_json(
        app,
        &format!("/getBookSource?url={}", enc("https://b6.batch/roll-ok")),
    )
    .await;
    assert_eq!(
        rd["errorMsg"], "未找到源，请检查书源地址",
        "整批应回滚 rd={rd}"
    );
}

#[tokio::test]
async fn test_b6_delete_book_sources_and_errors() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://b6.del/1".into(),
            book_source_name: "删一".into(),
            ..Default::default()
        },
    )
    .await;
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://b6.del/2".into(),
            book_source_name: "删二".into(),
            ..Default::default()
        },
    )
    .await;
    {
        let db = state.db.lock().await;
        legado_db::repository::cache_repository::CacheRepository::new(db.connection())
            .put("sourceVariable_https://b6.del/1", "v", 0)
            .unwrap();
    }
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 缺参 / 坏 JSON
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "解析字符串为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据格式错误");

    // 正例：数组去重删除 + 缓存变量清理
    let body = json!([
        {"bookSourceUrl": "https://b6.del/1"},
        {"bookSourceUrl": "https://b6.del/2"},
        {"bookSourceUrl": "https://b6.del/1"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "已执行");

    {
        let db = state.db.lock().await;
        let count = legado_db::BookSourceRepository::new(db.connection())
            .count()
            .unwrap();
        assert_eq!(count, 0);
        let cache_left: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM caches WHERE key = 'sourceVariable_https://b6.del/1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(cache_left, 0, "删除源应清 sourceVariable_ 缓存");
    }

    // 空数组：原版同样成功「已执行」
    let (_, _, rd) = post_write_json(
        app,
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        b"[]",
    )
    .await;
    assert_eq!(rd["isSuccess"], true);
    assert_eq!(rd["data"], "已执行");
}

#[tokio::test]
async fn test_b6_save_rss_source_and_batch() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    {
        let db = state.db.lock().await;
        db.connection()
            .execute(
                "CREATE TRIGGER b6_fail_rss BEFORE INSERT ON rssSources
                 WHEN NEW.sourceUrl = 'https://b6.rss/boom'
                 BEGIN SELECT RAISE(ABORT, 'b6 rss boom'); END",
                [],
            )
            .unwrap();
    }
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 单条：缺参 / 坏 JSON / 缺名称 / 正例
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSource",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSource",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert!(
        rd["errorMsg"]
            .as_str()
            .unwrap_or_default()
            .starts_with("转换源失败"),
        "rd={rd}"
    );
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSource",
        Some("application/json"),
        &auth,
        br#"{"sourceUrl":"https://b6.rss/1"}"#,
    )
    .await;
    assert_eq!(rd["errorMsg"], "源名称和URL不能为空");

    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSource",
        Some("application/json"),
        &auth,
        r#"{"sourceUrl":"https://b6.rss/1","sourceName":"RSS一"}"#.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "");

    let (_, rd) = get_json(
        app.clone(),
        &format!("/getRssSource?url={}", enc("https://b6.rss/1")),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["sourceName"], "RSS一");

    // 批量：缺参 / 空数组 / 过滤空名 / 事务回滚
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSources",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSources",
        Some("application/json"),
        &auth,
        b"[]",
    )
    .await;
    assert_eq!(rd["errorMsg"], "转换源失败");

    let body = json!([
        {"sourceUrl": "https://b6.rss/b1", "sourceName": "批一"},
        {"sourceUrl": "https://b6.rss/b2", "sourceName": " "},
        {"sourceUrl": "https://b6.rss/b3", "sourceName": "批三"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"].as_array().unwrap().len(), 2);

    let body = json!([
        {"sourceUrl": "https://b6.rss/roll-ok", "sourceName": "回滚好"},
        {"sourceUrl": "https://b6.rss/boom", "sourceName": "回滚炸"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveRssSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert!(
        rd["errorMsg"]
            .as_str()
            .unwrap_or_default()
            .contains("b6 rss boom"),
        "rd={rd}"
    );
    let (_, rd) = get_json(
        app,
        &format!("/getRssSource?url={}", enc("https://b6.rss/roll-ok")),
    )
    .await;
    assert_eq!(
        rd["errorMsg"], "未找到源，请检查源地址",
        "整批应回滚 rd={rd}"
    );
}

#[tokio::test]
async fn test_b6_delete_rss_sources_side_effects_and_errors() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    seed_rss_source(&state, "https://b6.rssdel/1", "删RSS").await;
    {
        let db = state.db.lock().await;
        legado_db::repository::rss_article_repository::RssArticleRepository::new(db.connection())
            .insert(
                &legado_db::repository::rss_article_repository::RssArticleRecord {
                    origin: "https://b6.rssdel/1".to_string(),
                    title: "文章".to_string(),
                    link: Some("https://b6.rssdel/1/a".to_string()),
                    ..Default::default()
                },
            )
            .unwrap();
        legado_db::repository::cache_repository::CacheRepository::new(db.connection())
            .put("sourceVariable_https://b6.rssdel/1", "v", 0)
            .unwrap();
    }
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 缺参 / 坏 JSON
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteRssSources",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "没有传递数据");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteRssSources",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "格式不对");

    let body = json!([{"sourceUrl": "https://b6.rssdel/1"}]).to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteRssSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "已执行");

    {
        let db = state.db.lock().await;
        let sources =
            legado_db::repository::rss_source_repository::RssSourceRepository::new(db.connection())
                .count()
                .unwrap();
        let articles = legado_db::repository::rss_article_repository::RssArticleRepository::new(
            db.connection(),
        )
        .count()
        .unwrap();
        let cache_left: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM caches WHERE key = 'sourceVariable_https://b6.rssdel/1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(sources, 0);
        assert_eq!(
            articles, 0,
            "删除 RSS 源应级联删除文章（原版 rssArticleDao.delete）"
        );
        assert_eq!(cache_left, 0);
    }
}

#[tokio::test]
async fn test_b6_save_replace_rule_semantics() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 缺参 / 坏 JSON
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "格式不对");

    // 成功路径返回显式成功信封（批23：原版未 setData 导致前端误报未知错误）
    let first =
        json!({"name": "规则一", "pattern": "a", "replacement": "b", "isRegex": false}).to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        first.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "保存成功应返回显式成功信封 rd={rd}");
    assert_eq!(rd["errorMsg"], "", "成功不得携带错误文案 rd={rd}");
    assert_eq!(rd["data"], "", "成功 data 为空串（对齐 saveBookSource）");

    let second =
        json!({"name": "规则二", "pattern": "c", "replacement": "d", "isRegex": true}).to_string();
    post_write_json(
        app.clone(),
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        second.as_bytes(),
    )
    .await;

    let rules = {
        let db = state.db.lock().await;
        legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
            .find_all()
            .unwrap()
    };
    assert_eq!(rules.len(), 2);
    let first_rule = rules.iter().find(|r| r.name == "规则一").unwrap();
    let first_id = first_rule.id;
    assert_eq!(first_rule.order, 1, "sortOrder 缺省 → MAX(sortOrder)+1");
    assert_eq!(rules.iter().find(|r| r.name == "规则二").unwrap().order, 2);

    // 显式 Int.MIN_VALUE 同缺省
    let third = json!({
        "name": "规则三",
        "pattern": "e",
        "replacement": "f",
        "sortOrder": i32::MIN
    })
    .to_string();
    post_write_json(
        app.clone(),
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        third.as_bytes(),
    )
    .await;
    let rules = {
        let db = state.db.lock().await;
        legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
            .find_all()
            .unwrap()
    };
    assert_eq!(rules.iter().find(|r| r.name == "规则三").unwrap().order, 3);

    // id 命中 → 更新既有行（不新增）
    let update = json!({
        "id": first_id,
        "name": "规则一改",
        "pattern": "a2",
        "replacement": "b2",
        "isRegex": false,
        "sortOrder": 9
    })
    .to_string();
    post_write_json(
        app,
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        update.as_bytes(),
    )
    .await;
    let rules = {
        let db = state.db.lock().await;
        legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
            .find_all()
            .unwrap()
    };
    assert_eq!(rules.len(), 3, "id 命中应更新而非新增");
    let updated = rules.iter().find(|r| r.id == first_id).unwrap();
    assert_eq!(updated.name, "规则一改");
    // 批12 P2：update 不写 sortOrder——即使请求显式携带 sortOrder=9，
    // 既有行排序保持不变（排序只经 reorderReplaceRules 全量重排）
    assert_eq!(updated.order, 1, "既有行更新不得改写排序值");
}

#[tokio::test]
async fn test_b6_delete_replace_rule() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let id = seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "待删".to_string(),
            pattern: "x".to_string(),
            ..Default::default()
        },
    )
    .await;
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteReplaceRule",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteReplaceRule",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "格式不对");

    let body = json!({"id": id}).to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "删除成功应返回显式成功信封 rd={rd}");
    assert_eq!(rd["errorMsg"], "", "成功不得携带错误文案 rd={rd}");
    assert_eq!(rd["data"], "", "成功 data 为空串（对齐其它写端点）");

    let count = {
        let db = state.db.lock().await;
        legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
            .count()
            .unwrap()
    };
    assert_eq!(count, 0);

    // 不存在 id 亦成功（Room @Delete 语义）
    let (_, _, rd) = post_write_json(
        app,
        "/deleteReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(
        rd["isSuccess"], true,
        "不存在 id 亦成功且返回成功信封 rd={rd}"
    );
    assert_eq!(rd["errorMsg"], "", "rd={rd}");
}

#[tokio::test]
async fn test_b6_test_replace_rule_semantics() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state);
    let auth = [(B6_TOKEN, "secret")];

    // 缺参 / 坏 JSON / 缺 rule
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        b"not-json",
    )
    .await;
    assert_eq!(rd["errorMsg"], "格式不对");
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        br#"{"text":"abc"}"#,
    )
    .await;
    assert_eq!(rd["errorMsg"], "格式不对");

    // 字面量替换
    let body = json!({
        "rule": {"pattern": "abc", "replacement": "X", "isRegex": false},
        "text": "abcabc"
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "XX");

    // 正则分组替换
    let body = json!({
        "rule": {"pattern": "a(b+)c", "replacement": "$1", "isRegex": true},
        "text": "abbbc"
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "bbb");

    // rule 以 JSON 字符串传入（原版 `it is String` 分支）
    let rule_json = r#"{"pattern":"a","replacement":"b","isRegex":false}"#;
    let body = json!({"rule": rule_json, "text": "aa"}).to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "bb");

    // 空 pattern：批23 用户裁决改为只返回错误、不执行替换（原版错误被
    // setData 覆盖，前端看不到「替换规则不能为空」）
    let body = json!({
        "rule": {"pattern": "", "replacement": "X", "isRegex": false},
        "text": "ab"
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], false, "空 pattern 应为错误 rd={rd}");
    assert_eq!(rd["errorMsg"], "替换规则不能为空", "rd={rd}");
    assert!(
        rd["data"].is_null(),
        "错误时不得写结果区（原版被 setData 覆盖）: rd={rd}"
    );

    // 批23b 边界（审查 P3）：空 pattern 检查先于 text 类型校验。
    // text 缺失/非字符串与空 pattern 同时出现时，应返回「替换规则不能为空」
    // 的 JSON 错误信封（HTTP 200），而不是 text 校验对应的未捕获异常 500。
    for body in [
        json!({"rule": {"pattern": "", "replacement": "X", "isRegex": false}}).to_string(),
        json!({
            "rule": {"pattern": "", "replacement": "X", "isRegex": false},
            "text": 123
        })
        .to_string(),
    ] {
        let (status, _, rd) = post_write_json(
            app.clone(),
            "/testReplaceRule",
            Some("application/json"),
            &auth,
            body.as_bytes(),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::OK,
            "空 pattern 不得走 500 路径: rd={rd}"
        );
        assert_eq!(rd["isSuccess"], false, "rd={rd}");
        assert_eq!(
            rd["errorMsg"], "替换规则不能为空",
            "空规则优先于坏 text 报告: rd={rd}"
        );
        assert!(rd["data"].is_null(), "rd={rd}");
    }

    // 非法正则：错误文本作为成功数据返回（原版 catch → stackTraceStr）
    let body = json!({
        "rule": {"pattern": "(", "replacement": "x", "isRegex": true},
        "text": "text"
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert!(rd["data"].is_string(), "rd={rd}");
    assert_ne!(rd["data"], "text");

    // text 缺失/类型不符：原版未捕获异常 → 500 text/plain + close
    let (status, headers, bytes) = post_write_raw(
        app,
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        br#"{"rule":{"pattern":"a","replacement":"b"},"text":123}"#,
    )
    .await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
    assert!(
        header_str(&headers, "content-type").starts_with("text/plain"),
        "500 应为 text/plain"
    );
    assert_eq!(header_str(&headers, "connection"), "close");
    assert!(!bytes.is_empty());
}

#[tokio::test]
async fn test_b6_save_js_source_validation_chain() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state);
    let script = b"var config = { bookSourceUrl: 'https://b6.js/1', bookSourceName: 'JS' };";

    // 错误令牌（先于专项校验链）
    let (_, headers, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("wrong"),
        None,
        Some(script.len()),
        &[],
        script,
    )
    .await;
    assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "rd={rd}");
    assert_eq!(header_str(&headers, "connection"), "close");

    // Content-Type 必须 text/plain
    let (_, headers, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        Some("application/json"),
        Some(script.len()),
        &[],
        script,
    )
    .await;
    assert_eq!(rd["errorMsg"], "JS源请求 Content-Type 必须为 text/plain");
    assert_eq!(header_str(&headers, "connection"), "close");

    // Content-Length 必须提供 / 可解析
    let (_, headers, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        None,
        None,
        &[],
        script,
    )
    .await;
    assert_eq!(rd["errorMsg"], "JS源请求必须提供 Content-Length");
    assert_eq!(header_str(&headers, "connection"), "close");

    // 超限
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        None,
        Some(1024 * 1024 + 1),
        &[],
        script,
    )
    .await;
    assert_eq!(rd["errorMsg"], "JS源脚本不能超过 1 MiB");

    // Transfer-Encoding 在 Content-Type 之前拒绝
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        Some("application/json"),
        Some(script.len()),
        &[("Transfer-Encoding", "chunked")],
        script,
    )
    .await;
    assert_eq!(rd["errorMsg"], "JS源请求不支持 Transfer-Encoding");

    // 空体（Content-Length: 0）→ 数据不能为空（控制器错误，不关连接）
    let (_, headers, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        None,
        Some(0),
        &[],
        b"",
    )
    .await;
    assert_eq!(rd["errorMsg"], "数据不能为空", "rd={rd}");
    assert_ne!(header_str(&headers, "connection"), "close");

    // 非法脚本：提取失败文案（非令牌错误）
    let (_, _, rd) = post_js_source_with(
        app,
        "/saveJsSource",
        Some("secret"),
        None,
        Some(script.len()),
        &[],
        script,
    )
    .await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_ne!(rd["errorMsg"], B4_TOKEN_ERROR);
    assert!(
        !rd["errorMsg"].as_str().unwrap_or_default().is_empty(),
        "rd={rd}"
    );
}

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_b6_save_js_source_success_and_upsert_semantics() {
    const SCRIPT: &str = "var config = {\n  bookSourceUrl: 'https://b6.js/1',\n  bookSourceName: 'JS一'\n};\nfunction search(k){ return k; }\nfunction getChapters(){ return []; }\nfunction getContent(){ return ''; }";

    fn script_for(url: &str, name: &str) -> String {
        format!(
            "var config = {{\n  bookSourceUrl: '{url}',\n  bookSourceName: '{name}'\n}};\nfunction search(k){{ return k; }}\nfunction getChapters(){{ return []; }}\nfunction getContent(){{ return ''; }}"
        )
    }

    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state.clone());

    // 正例：提取 → 落库 → 返回保存后的源
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        None,
        Some(SCRIPT.len()),
        &[],
        SCRIPT.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["bookSourceUrl"], "https://b6.js/1");
    assert_eq!(rd["data"]["bookSourceName"], "JS一");
    assert_eq!(rd["data"]["mainJs"], SCRIPT);
    let saved_last_update = rd["data"]["lastUpdateTime"].as_i64().unwrap();
    assert!(saved_last_update > 0, "prepareForSave 应写入时间戳");

    // 同内容再次保存：未变化 → 返回旧对象、时间戳不变
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        None,
        Some(SCRIPT.len()),
        &[],
        SCRIPT.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["lastUpdateTime"], saved_last_update);

    // openedSourceUrl 不存在 → 原版异常文案
    let script_two = script_for("https://b6.js/2", "JS二");
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource?openedSourceUrl=https%3A%2F%2Fb6.js%2Fmissing",
        Some("secret"),
        None,
        Some(script_two.len()),
        &[],
        script_two.as_bytes(),
    )
    .await;
    assert_eq!(rd["errorMsg"], "原书源已不存在，请重新打开后保存");

    // 目标冲突：打开 A、保存目标 B（B 已存在）
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://b6.js/a".into(),
            book_source_name: "A".into(),
            ..Default::default()
        },
    )
    .await;
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://b6.js/b".into(),
            book_source_name: "B".into(),
            ..Default::default()
        },
    )
    .await;
    let script_b = script_for("https://b6.js/b", "B改");
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource?openedSourceUrl=https%3A%2F%2Fb6.js%2Fa",
        Some("secret"),
        None,
        Some(script_b.len()),
        &[],
        script_b.as_bytes(),
    )
    .await;
    assert_eq!(rd["errorMsg"], "目标书源URL已存在，请先删除目标书源");

    // URL 变更：删除旧行、写入新 URL
    let script_c = script_for("https://b6.js/c", "C");
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource?openedSourceUrl=https%3A%2F%2Fb6.js%2Fa",
        Some("secret"),
        None,
        Some(script_c.len()),
        &[],
        script_c.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["bookSourceUrl"], "https://b6.js/c");
    let (_, rd) = get_json(
        app.clone(),
        &format!("/getBookSource?url={}", enc("https://b6.js/a")),
    )
    .await;
    assert_eq!(
        rd["errorMsg"], "未找到源，请检查书源地址",
        "旧 URL 应删除 rd={rd}"
    );

    // 保留用户状态：enabled/customOrder/weight/respondTime
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: "https://b6.js/d".into(),
            book_source_name: "D旧".into(),
            enabled: false,
            enabled_explore: false,
            custom_order: 7,
            weight: 9,
            respond_time: 123,
            ..Default::default()
        },
    )
    .await;
    let script_d = script_for("https://b6.js/d", "D新");
    let (_, _, rd) = post_js_source_with(
        app.clone(),
        "/saveJsSource",
        Some("secret"),
        None,
        Some(script_d.len()),
        &[],
        script_d.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["bookSourceName"], "D新");
    assert_eq!(rd["data"]["enabled"], false);
    assert_eq!(rd["data"]["enabledExplore"], false);
    assert_eq!(rd["data"]["customOrder"], 7);
    assert_eq!(rd["data"]["weight"], 9);
    assert_eq!(rd["data"]["respondTime"], 123);

    // 落库校验
    let (_, rd) = get_json(
        app,
        &format!("/getBookSource?url={}", enc("https://b6.js/1")),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"]["mainJs"], SCRIPT);
}

#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_b6_test_replace_rule_js_expression() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state);
    let auth = [(B6_TOKEN, "secret")];

    let body = json!({
        "rule": {"pattern": "a", "replacement": "@js:result + '!'", "isRegex": true},
        "text": "a"
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app,
        "/testReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "a!");
}

// ---------------------------------------------------------------------------
// 批10 审查回修（2026-10-26）：P1-1 / P1-2 / P1-3 / P2-2 / P2-14
// ---------------------------------------------------------------------------

/// P1-1：原版契约键 `order` 的排序值必须保留，不得被改写为 MAX+1。
///
/// 原版 `ReplaceRule.kt:63` 的实体字段名是 `order`（Gson 序列化键），
/// 修复前按原版契约提交 `{"order":5}` 会被忽略并按 MAX+1 落库。
#[tokio::test]
async fn test_b6_save_replace_rule_upstream_order_key() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    // 既有 order=7 → 若 `order` 被误判缺省，新行会被写成 8
    seed_replace_rule(
        &state,
        &legado_core::models::ReplaceRule {
            name: "既有规则".to_string(),
            order: 7,
            ..Default::default()
        },
    )
    .await;
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    let body = json!({
        "id": 9,
        "name": "order键规则",
        "pattern": "a",
        "replacement": "b",
        "isRegex": false,
        "order": 5
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    // 批23：成功路径返回显式成功信封
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["errorMsg"], "", "rd={rd}");

    let rules = {
        let db = state.db.lock().await;
        legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
            .find_all()
            .unwrap()
    };
    let saved = rules.iter().find(|r| r.name == "order键规则").unwrap();
    assert_eq!(saved.order, 5, "order 键输入必须保留排序（P1-1）");

    // 对照：`sortOrder` 键（本轨既有契约）仍生效
    let body = json!({
        "name": "sortOrder键规则",
        "pattern": "c",
        "replacement": "d",
        "isRegex": false,
        "sortOrder": 3
    })
    .to_string();
    let (_, _, rd) = post_write_json(
        app,
        "/saveReplaceRule",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["errorMsg"], "", "rd={rd}");
    let rules = {
        let db = state.db.lock().await;
        legado_db::repository::replace_rule_repository::ReplaceRuleRepository::new(db.connection())
            .find_all()
            .unwrap()
    };
    assert_eq!(
        rules
            .iter()
            .find(|r| r.name == "sortOrder键规则")
            .unwrap()
            .order,
        3
    );
}

/// P1-2：删除书源必须清 5 族缓存（对齐 `CacheDao.deleteSourceVariables`），
/// 且同源重导入不继承旧登录头 / 变量。
#[tokio::test]
async fn test_b6_delete_book_sources_clears_five_cache_families() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let url = "https://b6.cache-family/1";
    let family_keys = |url: &str| {
        [
            format!("v_{url}_token"),
            format!("userInfo_{url}"),
            format!("loginHeader_{url}"),
            format!("sourceVariable_{url}"),
            format!("infoMap_{url}"),
        ]
    };
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: url.to_string(),
            book_source_name: "五族缓存源".to_string(),
            ..Default::default()
        },
    )
    .await;
    {
        let db = state.db.lock().await;
        let cache = legado_db::repository::cache_repository::CacheRepository::new(db.connection());
        for key in family_keys(url) {
            cache.put(&key, "stale", 0).unwrap();
        }
        // 对照键：其他源与无关键不得被误删
        cache
            .put("v_https://b6.cache-family/other_x", "keep", 0)
            .unwrap();
        cache
            .put("userInfo_https://b6.cache-family/other", "keep", 0)
            .unwrap();
        cache.put("cache_unrelated", "keep", 0).unwrap();
    }
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    let body = json!([{"bookSourceUrl": url}]).to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "已执行");

    {
        let db = state.db.lock().await;
        let conn = db.connection();
        for key in family_keys(url) {
            let left: i64 = conn
                .query_row(
                    &format!("SELECT COUNT(*) FROM caches WHERE key = '{key}'"),
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(left, 0, "删除书源应清空 5 族缓存：{key}");
        }
        let kept: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM caches WHERE key IN
                 ('v_https://b6.cache-family/other_x',
                  'userInfo_https://b6.cache-family/other',
                  'cache_unrelated')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(kept, 3, "其他源/无关缓存不得误删");
    }

    // 同源重导入：不得继承旧登录头 / 变量
    let body = json!({"bookSourceUrl": url, "bookSourceName": "重导入"}).to_string();
    let (_, _, rd) = post_write_json(
        app,
        "/saveBookSource",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    let db = state.db.lock().await;
    let conn = db.connection();
    for key in family_keys(url) {
        let left: i64 = conn
            .query_row(
                &format!("SELECT COUNT(*) FROM caches WHERE key = '{key}'"),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(left, 0, "同源重导入不得继承旧缓存：{key}");
    }
}

/// P1-2（第三处调用点）：`saveJsSource` 换 URL 保存时清旧 URL 的 5 族缓存。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_b6_save_js_source_url_change_clears_old_cache_families() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let old_url = "https://b6.js-old/1";
    seed_book_source(
        &state,
        legado_core::models::BookSource {
            book_source_url: old_url.to_string(),
            book_source_name: "旧源".to_string(),
            ..Default::default()
        },
    )
    .await;
    let family_keys = [
        format!("v_{old_url}_token"),
        format!("userInfo_{old_url}"),
        format!("loginHeader_{old_url}"),
        format!("sourceVariable_{old_url}"),
        format!("infoMap_{old_url}"),
    ];
    {
        let db = state.db.lock().await;
        let cache = legado_db::repository::cache_repository::CacheRepository::new(db.connection());
        for key in &family_keys {
            cache.put(key, "stale", 0).unwrap();
        }
    }
    let app = create_router(state.clone());

    let script = "var config = {\n  bookSourceUrl: 'https://b6.js-new/1',\n  bookSourceName: '新源'\n};\nfunction search(k){ return k; }\nfunction getChapters(){ return []; }\nfunction getContent(){ return ''; }";
    let uri = format!("/saveJsSource?openedSourceUrl={}", enc(old_url));
    let (_, _, rd) = post_js_source_with(
        app,
        &uri,
        Some("secret"),
        None,
        Some(script.len()),
        &[],
        script.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");

    let db = state.db.lock().await;
    let conn = db.connection();
    for key in &family_keys {
        let left: i64 = conn
            .query_row(
                &format!("SELECT COUNT(*) FROM caches WHERE key = '{key}'"),
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(left, 0, "换 URL 保存应清旧源 5 族缓存：{key}");
    }
}

/// P2-14：`deleteBookSources` 同 URL 去重（只删一次）+ 批量删除事务回滚。
#[tokio::test]
async fn test_b6_delete_book_sources_dedup_and_rollback() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    for (url, name) in [
        ("https://b6.dedup/1", "去重一"),
        ("https://b6.dedup/2", "去重二"),
        ("https://b6.rollback/1", "回滚一"),
        ("https://b6.rollback/2", "回滚二"),
    ] {
        seed_book_source(
            &state,
            legado_core::models::BookSource {
                book_source_url: url.to_string(),
                book_source_name: name.to_string(),
                ..Default::default()
            },
        )
        .await;
    }
    {
        let db = state.db.lock().await;
        let conn = db.connection();
        // 删除计数表 + AFTER DELETE 触发器：观察同一 URL 实际执行了几次删除
        conn.execute("CREATE TABLE b6_delete_log (url TEXT NOT NULL)", [])
            .unwrap();
        conn.execute(
            "CREATE TRIGGER b6_log_book_delete AFTER DELETE ON book_sources
             BEGIN INSERT INTO b6_delete_log(url) VALUES (OLD.bookSourceUrl); END",
            [],
        )
        .unwrap();
        // 回滚触发器：删到 rollback/2 时 ABORT
        conn.execute(
            "CREATE TRIGGER b6_fail_book_delete BEFORE DELETE ON book_sources
             WHEN OLD.bookSourceUrl = 'https://b6.rollback/2'
             BEGIN SELECT RAISE(ABORT, 'b6 delete boom'); END",
            [],
        )
        .unwrap();
    }
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    // 去重：同一 URL 在数组中出现两次 → 触发器只记 1 行
    let body = json!([
        {"bookSourceUrl": "https://b6.dedup/1"},
        {"bookSourceUrl": "https://b6.dedup/1"},
        {"bookSourceUrl": "https://b6.dedup/2"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    {
        let db = state.db.lock().await;
        let deleted_once: i64 = db
            .connection()
            .query_row(
                "SELECT COUNT(*) FROM b6_delete_log WHERE url = 'https://b6.dedup/1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(deleted_once, 1, "同 URL 只应删除一次（去重）");
    }

    // 回滚：第二条删除触发 ABORT → 第一条的删除也应回滚
    let body = json!([
        {"bookSourceUrl": "https://b6.rollback/1"},
        {"bookSourceUrl": "https://b6.rollback/2"}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app,
        "/deleteBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert!(
        rd["errorMsg"]
            .as_str()
            .unwrap_or_default()
            .contains("b6 delete boom"),
        "rd={rd}"
    );
    let db = state.db.lock().await;
    let survived: i64 = db
        .connection()
        .query_row(
            "SELECT COUNT(*) FROM book_sources WHERE bookSourceUrl = 'https://b6.rollback/1'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(survived, 1, "批量删除失败应整批回滚");
}

/// P2-14：`saveBookSources` / `saveRssSources` 跳过空 URL 条目。
#[tokio::test]
async fn test_b6_batch_save_skips_empty_url() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app = create_router(state.clone());
    let auth = [(B6_TOKEN, "secret")];

    let body = json!([
        {"bookSourceUrl": "https://b6.empty-book/1", "bookSourceName": "有效"},
        {"bookSourceUrl": "", "bookSourceName": "空URL"},
        {"bookSourceUrl": "https://b6.empty-book/2", "bookSourceName": "  "}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app.clone(),
        "/saveBookSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"].as_array().unwrap().len(), 1, "空 URL/空名应跳过");

    let body = json!([
        {"sourceUrl": "https://b6.empty-rss/1", "sourceName": "有效"},
        {"sourceUrl": "", "sourceName": "空URL"},
        {"sourceUrl": "https://b6.empty-rss/2", "sourceName": "  "}
    ])
    .to_string();
    let (_, _, rd) = post_write_json(
        app,
        "/saveRssSources",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"].as_array().unwrap().len(), 1, "空 URL/空名应跳过");

    let db = state.db.lock().await;
    let book_count = legado_db::BookSourceRepository::new(db.connection())
        .count()
        .unwrap();
    let rss_count =
        legado_db::repository::rss_source_repository::RssSourceRepository::new(db.connection())
            .count()
            .unwrap();
    assert_eq!(book_count, 1, "只落库有效书源");
    assert_eq!(rss_count, 1, "只落库有效 RSS 源");
}

/// P2-2：路由级令牌前置中间件——未授权请求在 body 提取前被拒绝。
///
/// body 流一旦被轮询就 panic，用于证明中间件拒绝路径**不读取请求体**；
/// 同时用 1 GiB 的 `Content-Length` 声明验证响应是令牌错误而非 413
/// （即守卫先于 body 限额/提取执行）。
#[tokio::test]
async fn test_b6_token_guard_rejects_before_body_read() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app =
        legado_server::server::attach_source_write_token_guard(create_router(state.clone()), state);

    let body_stream = futures_util::stream::once(async {
        if std::hint::black_box(true) {
            panic!("令牌前置中间件失效：未授权请求读取了请求体");
        }
        Ok::<axum::body::Bytes, std::io::Error>(axum::body::Bytes::new())
    });
    let request = Request::builder()
        .method(Method::POST)
        .uri("/saveReplaceRule")
        .header("Content-Type", "application/json")
        .header("Content-Length", "1073741824")
        .body(Body::from_stream(body_stream))
        .unwrap();
    let resp = app.clone().oneshot(request).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let connection = header_str(resp.headers(), "connection").to_string();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let rd: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(rd["isSuccess"], false, "rd={rd}");
    assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "rd={rd}");
    assert_eq!(connection, "close", "令牌失败应关闭连接");

    // 对照：正确令牌 + 正常 body → 中间件放行，handler 正常执行
    let (_, _, rd) = post_write_json(
        app,
        "/deleteBookSources",
        Some("application/json"),
        &[(B6_TOKEN, "secret")],
        b"[]",
    )
    .await;
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(rd["data"], "已执行");
}

/// [审查批 P2] `POST /api/sources/check|check-batch` 纳入路由级令牌前置：
/// 无令牌时在 body 提取前拒绝。
///
/// 两条端点接受请求体中的任意 `BookSource` 并对 `searchUrl` 发起出站请求
/// （`check-batch` 最多 20 并发），是同 LAN 可达时的无鉴权 SSRF/出站放大器
/// （审计报告 P1-1「同组旁路」）。与其余源写端点同型取证：body 流一旦被
/// 轮询就 panic，证明守卫未读取请求体；1 GiB `Content-Length` 声明验证响应
/// 是令牌失败信封（200 + `Connection: close`）而非 body 限额的 413。
///
/// 带令牌时放行到 handler：`check-batch` 空数组返回零结果（不发网络请求）；
/// 单条 `check` 用缺 `searchUrl` 的源（`check_full` 在首个出站点前即返回
/// `no searchUrl defined`），证明守卫不是无条件拒绝，且用例不依赖外网。
#[tokio::test]
async fn test_source_check_routes_token_guard_rejects_before_body_read() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app =
        legado_server::server::attach_source_write_token_guard(create_router(state.clone()), state);

    for uri in ["/api/sources/check", "/api/sources/check-batch"] {
        let body_stream = futures_util::stream::once(async move {
            if std::hint::black_box(true) {
                panic!("令牌前置中间件失效：{uri} 未授权请求读取了请求体");
            }
            Ok::<axum::body::Bytes, std::io::Error>(axum::body::Bytes::new())
        });
        let request = Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header("Content-Type", "application/json")
            .header("Content-Length", "1073741824")
            .body(Body::from_stream(body_stream))
            .unwrap();
        let resp = app.clone().oneshot(request).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "{uri}");
        let connection = header_str(resp.headers(), "connection").to_string();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let rd: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(rd["isSuccess"], false, "{uri} rd={rd}");
        assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "{uri} rd={rd}");
        assert_eq!(connection, "close", "{uri} 令牌失败应关闭连接");
    }

    let auth = [(B6_TOKEN, "secret")];

    // 带令牌：check-batch 空数组 → handler 正常返回零结果（非令牌错误）
    let (status, headers, rd) = post_write_json(
        app.clone(),
        "/api/sources/check-batch",
        Some("application/json"),
        &auth,
        br#"{"sources":[]}"#,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "rd={rd}");
    assert_eq!(rd["total"], 0, "rd={rd}");
    assert_eq!(rd["passed"], 0, "rd={rd}");
    assert_eq!(rd["failed"], 0, "rd={rd}");
    assert_ne!(header_str(&headers, "connection"), "close");

    // 带令牌：check 缺 searchUrl 的源 → handler 正常返回检查结果（出站前失败）
    let body = json!({
        "source": {
            "bookSourceUrl": "https://p2.example.com",
            "bookSourceName": "P2 无搜索源"
        }
    })
    .to_string();
    let (status, headers, rd) = post_write_json(
        app,
        "/api/sources/check",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "rd={rd}");
    assert_eq!(rd["source_url"], "https://p2.example.com", "rd={rd}");
    assert_eq!(rd["search_ok"], false, "rd={rd}");
    assert_eq!(rd["search_error"], "no searchUrl defined", "rd={rd}");
    assert_ne!(header_str(&headers, "connection"), "close");
}

/// [审查批 P2-1] 段评两条写端点（`/openLegacyReview`、`/runLegacyReview`）
/// 纳入路由级令牌前置：无令牌时在 body 提取前拒绝。
///
/// 与源写端点同型取证：body 流一旦被轮询就 panic，证明守卫未读取请求体；
/// 1 GiB `Content-Length` 声明验证响应是令牌失败信封（200 + `Connection:
/// close`）而非 body 限额的 413。带令牌时放行到 handler（坏 JSON → 原版
/// 「数据格式错误: …」文案），证明守卫不是无条件拒绝。
#[tokio::test]
async fn test_review_routes_token_guard_rejects_before_body_read() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app =
        legado_server::server::attach_source_write_token_guard(create_router(state.clone()), state);

    for uri in ["/openLegacyReview", "/runLegacyReview"] {
        let body_stream = futures_util::stream::once(async move {
            if std::hint::black_box(true) {
                panic!("令牌前置中间件失效：{uri} 未授权请求读取了请求体");
            }
            Ok::<axum::body::Bytes, std::io::Error>(axum::body::Bytes::new())
        });
        let request = Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header("Content-Type", "application/json")
            .header("Content-Length", "1073741824")
            .body(Body::from_stream(body_stream))
            .unwrap();
        let resp = app.clone().oneshot(request).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "{uri}");
        let connection = header_str(resp.headers(), "connection").to_string();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let rd: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(rd["isSuccess"], false, "{uri} rd={rd}");
        assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "{uri} rd={rd}");
        assert_eq!(connection, "close", "{uri} 令牌失败应关闭连接");

        // 带令牌：放行到 handler（坏 JSON → 「数据格式错误」，非令牌错误）
        let (status, headers, rd) = post_write_json(
            app.clone(),
            uri,
            Some("application/json"),
            &[(B6_TOKEN, "secret")],
            b"not-json",
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{uri} rd={rd}");
        assert!(
            rd["errorMsg"]
                .as_str()
                .unwrap_or_default()
                .starts_with("数据格式错误"),
            "{uri} rd={rd}"
        );
        assert_ne!(header_str(&headers, "connection"), "close", "{uri}");
    }
}

/// [审查批 P1/P2] 同组无鉴权任意 URL 出站面 6 条路由纳入路由级令牌前置：
/// 无令牌时在 body 提取前拒绝，带令牌可进入 handler。
///
/// 覆盖（按 routes.rs 实际注册方法）：
/// - `POST /api/rss/articles`（body `{url}` → `fetch_feed`）；
/// - `GET /api/rss/{source_url}/articles`（路径参数解码 → `fetch_feed`）；
/// - `POST /api/tts/speak` / `POST /api/audio/speak`（body `engine_url` →
///   任意出站，响应体原样回传）；
/// - `POST /api/bookshelf/update-toc/single` / `POST /api/bookshelf/update-toc`
///   （body URL → 库内书源 → 出站；批量面 `max_concurrent` 另收敛到 9）。
///
/// body 类沿用 `5a458fd04a` 的取证法：body 流一旦被轮询就 panic，证明守卫
/// 未读取请求体；1 GiB `Content-Length` 声明验证响应是令牌失败信封
///（200 + `Connection: close`）而非 body 限额的 413。带令牌用例均走
///「缺参 / 空批次 / 非法 URL」提前返回路径，不依赖外网。
#[tokio::test]
async fn test_outbound_surface_routes_token_guard_rejects_before_body_read() {
    let state = make_test_state();
    seed_config(&state, "config:jsSourceApiToken", "secret").await;
    let app =
        legado_server::server::attach_source_write_token_guard(create_router(state.clone()), state);

    // ── body 类 5 条：无令牌必须在提取 body 前拒绝 ──────────────────────
    for uri in [
        "/api/rss/articles",
        "/api/tts/speak",
        "/api/audio/speak",
        "/api/bookshelf/update-toc/single",
        "/api/bookshelf/update-toc",
    ] {
        let body_stream = futures_util::stream::once(async move {
            if std::hint::black_box(true) {
                panic!("令牌前置中间件失效：{uri} 未授权请求读取了请求体");
            }
            Ok::<axum::body::Bytes, std::io::Error>(axum::body::Bytes::new())
        });
        let request = Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header("Content-Type", "application/json")
            .header("Content-Length", "1073741824")
            .body(Body::from_stream(body_stream))
            .unwrap();
        let resp = app.clone().oneshot(request).await.unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "{uri}");
        let connection = header_str(resp.headers(), "connection").to_string();
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let rd: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(rd["isSuccess"], false, "{uri} rd={rd}");
        assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "{uri} rd={rd}");
        assert_eq!(connection, "close", "{uri} 令牌失败应关闭连接");
    }

    // ── 路径参数类 1 条（GET）：无令牌同样拒绝 ──────────────────────────
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/rss/https%3A%2F%2F127.0.0.1%3A1%2Ffeed/articles")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let connection = header_str(resp.headers(), "connection").to_string();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let rd: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(rd["isSuccess"], false, "rss GET rd={rd}");
    assert_eq!(rd["errorMsg"], B4_TOKEN_ERROR, "rss GET rd={rd}");
    assert_eq!(connection, "close", "rss GET 令牌失败应关闭连接");

    // ── 带令牌：守卫放行到 handler ──────────────────────────────────────
    let auth = [(B6_TOKEN, "secret")];

    // body 类三件：空 JSON → Json 提取器缺字段 422（早于任何出站调用），
    // 证明守卫放行且不是无条件拒绝。
    for uri in ["/api/rss/articles", "/api/tts/speak", "/api/audio/speak"] {
        let (status, headers, bytes) =
            post_write_raw(app.clone(), uri, Some("application/json"), &auth, b"{}").await;
        assert_eq!(status, StatusCode::UNPROCESSABLE_ENTITY, "{uri}");
        assert_ne!(header_str(&headers, "connection"), "close", "{uri}");
        assert!(
            !String::from_utf8_lossy(&bytes).contains(B4_TOKEN_ERROR),
            "{uri} 不应返回令牌错误"
        );
    }

    // GET rss：非法 URL 在 URL 解析阶段失败（502 network），不发起 DNS/连接。
    let resp = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/rss/not-a-valid-url/articles")
                .header(B6_TOKEN, "secret")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["error"]["type"], "network", "value={value}");

    // update-toc/single：书籍不在库 → 400「书籍不存在」（纯 DB，不出站）
    let body = json!({ "book_url": "https://no-such-book.example.com/1" }).to_string();
    let (status, headers, rd) = post_write_json(
        app.clone(),
        "/api/bookshelf/update-toc/single",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "rd={rd}");
    assert_eq!(rd["updated"], false, "rd={rd}");
    assert_eq!(rd["error"], "书籍不存在", "rd={rd}");
    assert_ne!(header_str(&headers, "connection"), "close");

    // update-toc 批量：空批次 → 200 started，且 max_concurrent 收敛到 9
    let body = json!({ "books": [], "max_concurrent": 1000 }).to_string();
    let (status, headers, rd) = post_write_json(
        app.clone(),
        "/api/bookshelf/update-toc",
        Some("application/json"),
        &auth,
        body.as_bytes(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "rd={rd}");
    assert_eq!(rd["started"], true, "rd={rd}");
    assert_eq!(rd["total"], 0, "rd={rd}");
    assert_eq!(
        rd["max_concurrent"], 9,
        "请求 1000 并发必须收敛到 9 rd={rd}"
    );
    assert_ne!(header_str(&headers, "connection"), "close");
}
