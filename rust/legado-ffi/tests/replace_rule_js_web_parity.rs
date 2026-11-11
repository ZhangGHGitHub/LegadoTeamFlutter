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
//! 4. 无 quickjs feature → 两端都不执行 `@js:`，普通规则仍生效；
//! 5. [批17 回修 P1] App 构建下 Web `/testReplaceRule` 预览真实执行 `@js:`；
//! 6. [批20-B] 配置面/作用域面统一：简繁转换、`replaceEnableDefault=false`、
//!    章级 `sameTitleRemoved`、`scope`（拆分 + 书名精确匹配）与
//!    `excludeScope`（正文路径忽略）两端逐字一致。
//!
//! **修复前红/覆盖性口径（按基线版本）**：
//! - 批17 前基线 `217e2c3dcb` 红：Web 正文执行/绑定断言（旧 Web 跳过 `@js:`）；
//! - `feebd44f41` 起为绿：`/testReplaceRule` 预览用例（修复随该提交落地，
//!   当前仅防回归，不再标「父提交必红」）；
//! - 覆盖性（父提交亦绿）：抛错、超时、无 quickjs —— 旧 Web 跳过 `@js:`
//!   同样保留原文，故不能作为修复证据；
//! - [批20-B] 简繁/替换默认开关/scope/excludeScope/章级去重用例在统一前
//!   必红（Web 使用常量配置 + `ScopeContext` 子串匹配）。
//!
//! **parity 前提（批20-B 起）**：App 端与 Web 端读取**同一套 caches 配置键**
//! （测试中两侧 DB 分别 seed 相同值），因此非默认配置下也要求逐字相等。
//! 覆盖默认值（`chineseConverterType=0`、`replaceEnableDefault=true`、章级
//! 去重开启、`reSegment=false`）的既有用例继续保留。
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
//!   避免规则/书籍/配置交叉污染。

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
use legado_ffi::legado_db::app_config;
use legado_ffi::legado_db::repository::cache_repository::CacheRepository;
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
/// 默认配置（显式 seed）：`config:chineseConverterType=0`、
/// `config:replaceEnableDefault=true`、章级 `sameTitleRemoved:{bookUrl}:{index}`
/// 写 `"0"`（去除重复标题）。需要非默认配置的用例在调用本函数后用
/// [`seed_app_config`] 覆盖（caches 表 REPLACE 语义，后写胜出）。
///
/// 各用例使用唯一 bookUrl，且 DB 文件按进程号隔离，无需清理历史行。
fn seed_app(book: &Book, chapter: &BookChapter, rules: &[ReplaceRule]) {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.put(
            &format!("config:{}", app_config::CHINESE_CONVERT_TYPE_KEY),
            "0",
            0,
        )?;
        repo.put(
            &format!("config:{}", app_config::REPLACE_ENABLE_DEFAULT_KEY),
            "true",
            0,
        )?;
        repo.put(
            &app_config::same_title_removed_key(&book.book_url, chapter.index),
            "0",
            0,
        )
    })
    .unwrap();
    with_database(|db| BookRepository::new(db.connection()).insert(book)).unwrap();
    with_database(|db| BookChapterRepository::new(db.connection()).insert(chapter)).unwrap();
    for rule in rules {
        with_database(|db| ReplaceRuleRepository::new(db.connection()).insert(rule)).unwrap();
    }
}

/// 覆盖 App 端全局 caches 配置（在 [`seed_app`] 之后调用，后写胜出）
fn seed_app_config(pairs: &[(&str, &str)]) {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        for (key, value) in pairs {
            repo.put(&format!("config:{key}"), value, 0)?;
        }
        Ok(())
    })
    .unwrap();
}

/// 覆盖 Web 端内存 DB 的 caches 配置（与 App 端同键同值）
async fn seed_web_config(state: &Arc<AppState>, pairs: &[(&str, &str)]) {
    let db = state.db.lock().await;
    let repo = CacheRepository::new(db.connection());
    for (key, value) in pairs {
        repo.put(&format!("config:{key}"), value, 0).unwrap();
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

/// [批17 回修 P1] App 构建（`--features quickjs`）下 Web 预览
/// `/testReplaceRule` 必须真实执行 `@js:`
///
/// 修复前：批17 前基线 `217e2c3dcb` 上 `legado-ffi` 未透传
/// `legado-server/quickjs`，server 侧预览执行器缺失（返回「需要 JS 执行器」）；
/// `feebd44f41` 起修复并转绿，当前仅防回归。注意预览已改由 `legado-js`
/// 共享执行器门控，feature 透传只影响 server 独有 JS 路径（另有用例钉住）。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_web_test_replace_rule_executes_js_in_app_build() {
    let state = make_web_state();
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:jsSourceApiToken", "secret", 0)
            .unwrap();
    }
    let app = create_router(state);
    let body = serde_json::json!({
        "rule": {"pattern": "a", "replacement": "@js:result + '!'", "isRegex": true},
        "text": "a"
    })
    .to_string();
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/testReplaceRule")
                .header("Content-Type", "application/json")
                .header("x-legado-token", "secret")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let rd: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(rd["isSuccess"], true, "rd={rd}");
    assert_eq!(
        rd["data"], "a!",
        "App 内嵌 Web 的 /testReplaceRule 必须真实执行 @js:（rd={rd}）"
    );
}

/// [批17 三审 P2/P3] `legado-server/quickjs` 透传钉住 + `/mcp/call` 令牌守卫：
/// 走 server 独有 `#[cfg(feature = "quickjs")]` 路径的 `eval_js` 工具，
/// 同时按生产入口挂上写源令牌守卫。
///
/// `/testReplaceRule` 与正文 `@js:` 已改由 `legado-js` 共享执行器门控，
/// 无法证明 server feature 透传；MCP `eval_js` 仍由 `legado-server` 自身
/// 的 `quickjs` feature 分支实现。若 ffi 未透传，本用例返回
/// 「当前构建未启用 quickjs feature」→ 红；透传后返回求值结果 `2`。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_app_build_enables_server_only_quickjs_path() {
    let state = make_web_state();
    {
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .put("config:jsSourceApiToken", "secret", 0)
            .unwrap();
    }
    // 与生产入口一致：Web 路由挂写源令牌守卫
    let app = legado_ffi::legado_server::server::attach_source_write_token_guard(
        create_router(Arc::clone(&state)),
        state,
    );
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": "eval_js", "arguments": {"js": "1+1"}}
    })
    .to_string();
    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/mcp/call")
                .header("Content-Type", "application/json")
                .header("x-legado-token", "secret")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
        .await
        .unwrap();
    let rd: Value = serde_json::from_slice(&bytes).unwrap();
    let text = rd["result"]["content"][0]["text"]
        .as_str()
        .unwrap_or_default();
    assert!(
        !text.contains("未启用 quickjs feature"),
        "App 构建未透传 legado-server/quickjs（server 独有 JS 路径降级）: {rd}"
    );
    assert!(
        text.contains("-- 结果 --\n2"),
        "MCP eval_js 应返回 2（server quickjs 路径已启用）: {rd}"
    );
}

/// [批20-B] `scope` 语义统一后的 App/Web 一致性
///
/// 统一目标（用户 2026-11-12 裁决：统一到 App 侧）：
/// - 书名精确命中（`scope` 恰为书名）→ 两端生效；
/// - `scope` 为完整 `origin`（仅命中书籍来源）→ 两端都**不**生效；
/// - `scope` 为书名子串 → 两端都不生效。
///
/// 修复前（批17 快照）：Web 走 `ContentProcessor` 的 `ScopeContext`
/// 子串匹配 → origin-only 规则生效，与 App 不一致；本用例在该实现下红。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_js_rule_scope_semantics_unified_app_and_web() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch20.example.com/book/parity-scope";
    let title = "第一章";
    let chapter_url = "https://batch20.example.com/ch/scope-0";
    let raw = "前A标记中B标记后C标记";
    let rules = [
        // 书名精确命中：两端都生效
        ReplaceRule {
            name: "批20_书名作用域".to_string(),
            pattern: "A标记".to_string(),
            replacement: "A已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("批二十作用域书".to_string()),
            ..Default::default()
        },
        // 仅书籍来源命中：统一后两端都不生效
        ReplaceRule {
            name: "批20_来源作用域".to_string(),
            pattern: "B标记".to_string(),
            replacement: r#"@js: result + "!""#.to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            scope: Some("https://batch20.example.com".to_string()),
            ..Default::default()
        },
        // 书名子串（非精确项）：两端都不生效
        ReplaceRule {
            name: "批20_子串作用域".to_string(),
            pattern: "C标记".to_string(),
            replacement: "C已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("批二十作用域".to_string()),
            ..Default::default()
        },
    ];
    let expected = "前A已换中B标记后C标记";

    let book = test_book(book_url, "批二十作用域书");
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

    assert_eq!(app, expected, "App：书名精确 scope 生效，来源/子串不生效");
    assert_eq!(web, expected, "Web：必须与 App 使用同一 scope 语义");
    assert_eq!(app, web, "App 与 Web 对同一 scope 判定必须一致");
}

/// 断言同一书/章/规则/配置下 App 与 Web 输出均为 `expected`
///
/// 调用方必须先持有 [`ensure_app_db`] 的守卫（本函数会写 App 全局 DB）。
async fn assert_app_web_parity(
    case: &str,
    book: &Book,
    chapter: &BookChapter,
    raw: &str,
    rules: &[ReplaceRule],
    config: &[(&str, &str)],
    expected: &str,
) {
    let web_state = make_web_state();
    seed_web(&web_state, book, chapter, raw, rules).await;
    seed_app(book, chapter, rules);
    // 两端 seed 相同配置（caches REPLACE 语义，覆盖 seed_app 的默认值）
    seed_web_config(&web_state, config).await;
    seed_app_config(config);

    let web_json = web_content(web_state, &book.book_url, chapter.index).await;
    assert_eq!(web_json["isSuccess"], true, "{case}: web={web_json}");
    let web = web_json["data"].as_str().expect("Web 正文应为字符串");
    let app = app_content(
        &book.book_url,
        raw,
        &chapter.title,
        chapter.index,
        &chapter.url,
    );

    assert_eq!(app, expected, "{case}: App 结果不符");
    assert_eq!(web, expected, "{case}: Web 结果不符");
    assert_eq!(app, web, "{case}: App 与 Web 必须逐字一致");
}

/// [批20-B] 简繁转换：Web 必须读取与 App 相同的 `chineseConverterType`
///
/// 修复前：Web 固定 `chinese_convert=None` → 原文不转换，与 App 不一致（红）。
#[tokio::test]
async fn test_chinese_convert_parity_from_shared_config() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch20.example.com/book/parity-convert";
    let book = test_book(book_url, "批二十简繁书");
    let chapter = test_chapter(
        book_url,
        0,
        "第一章",
        "https://batch20.example.com/ch/convert-0",
    );

    assert_app_web_parity(
        "简繁转换 t2s",
        &book,
        &chapter,
        "前測試內容后",
        &[],
        &[("chineseConverterType", "1")],
        "前测试内容后",
    )
    .await;
}

/// [批20-B] `replaceEnableDefault=false`：两端都不应用替换规则
///
/// 修复前：Web 固定默认 true → 仍替换，与 App 不一致（红）。
#[tokio::test]
async fn test_replace_enable_default_false_parity() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch20.example.com/book/parity-replace-off";
    let book = test_book(book_url, "批二十替换开关书");
    let chapter = test_chapter(
        book_url,
        0,
        "第一章",
        "https://batch20.example.com/ch/off-0",
    );
    let rule = ReplaceRule {
        name: "批20_替换开关".to_string(),
        pattern: "批二十替换标记".to_string(),
        replacement: "已换".to_string(),
        is_regex: false,
        is_enabled: true,
        scope_content: true,
        ..Default::default()
    };

    assert_app_web_parity(
        "替换总开关关闭",
        &book,
        &chapter,
        "前批二十替换标记后",
        std::slice::from_ref(&rule),
        &[("replaceEnableDefault", "false")],
        "前批二十替换标记后",
    )
    .await;
}

/// [批20-B] `scope` 语义两端一致：按 `[,;，；]` 拆分 + 书名精确匹配，
/// 不看 `origin`
///
/// 覆盖：多书名精确命中、origin-only、书名子串、`global`。
/// 修复前：Web 子串匹配 → origin-only 规则生效，与 App 不一致（红）。
#[tokio::test]
async fn test_content_scope_parity_split_exact_book_name() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch20.example.com/book/parity-scope-content";
    let book = test_book(book_url, "批二十作用域书");
    let chapter = test_chapter(book_url, 0, "第一章", "https://batch20.example.com/ch/sc-0");
    let rules = [
        ReplaceRule {
            name: "批20_多书名精确".to_string(),
            pattern: "A标记".to_string(),
            replacement: "A已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("批二十作用域书,另一本书".to_string()),
            ..Default::default()
        },
        ReplaceRule {
            name: "批20_仅来源".to_string(),
            pattern: "B标记".to_string(),
            replacement: "B已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("https://batch20.example.com".to_string()),
            ..Default::default()
        },
        ReplaceRule {
            name: "批20_书名子串".to_string(),
            pattern: "C标记".to_string(),
            replacement: "C已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("批二十作用域".to_string()),
            ..Default::default()
        },
        ReplaceRule {
            name: "批20_全局".to_string(),
            pattern: "D标记".to_string(),
            replacement: "D已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("global".to_string()),
            ..Default::default()
        },
    ];

    assert_app_web_parity(
        "scope 拆分精确匹配",
        &book,
        &chapter,
        "A标记B标记C标记D标记",
        &rules,
        &[],
        "A已换B标记C标记D已换",
    )
    .await;
}

/// [批20-B] 正文路径两端都忽略 `excludeScope`
///
/// 修复前：Web 走 `ScopeContext` 的 excludeScope 排除 → 规则不生效，
/// 与 App（正文路径不处理 excludeScope）不一致（红）。
#[tokio::test]
async fn test_exclude_scope_ignored_in_content_parity() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch20.example.com/book/parity-exclude";
    let book = test_book(book_url, "批二十排除书");
    let chapter = test_chapter(book_url, 0, "第一章", "https://batch20.example.com/ch/ex-0");
    let rule = ReplaceRule {
        name: "批20_excludeScope".to_string(),
        pattern: "E标记".to_string(),
        replacement: "E已换".to_string(),
        is_regex: false,
        is_enabled: true,
        scope_content: true,
        exclude_scope: Some("批二十排除书".to_string()),
        ..Default::default()
    };

    assert_app_web_parity(
        "excludeScope 正文忽略",
        &book,
        &chapter,
        "前E标记后",
        std::slice::from_ref(&rule),
        &[],
        "前E已换后",
    )
    .await;
}

/// [批20-B] 章级 `sameTitleRemoved` 开关两端一致
///
/// 默认（无键）= 去除重复标题；章级 opt-out（值 `"1"`）= 保留原始标题。
/// 修复前：Web 固定 `remove_duplicate_title=true` → opt-out 章仍去除（红）。
#[tokio::test]
async fn test_same_title_removed_toggle_parity() {
    let _app_guard = ensure_app_db().await;

    // 场景 a：默认（去除重复标题）
    let book_default = test_book(
        "https://batch20.example.com/book/parity-title-default",
        "批二十去重书A",
    );
    let chapter_default = test_chapter(
        &book_default.book_url,
        0,
        "第一章 同名标题",
        "https://batch20.example.com/ch/title-a-0",
    );
    let raw = "第一章 同名标题\n正文标记";
    let rule = ReplaceRule {
        name: "批20_去重标题".to_string(),
        pattern: "正文标记".to_string(),
        replacement: "已换".to_string(),
        is_regex: false,
        is_enabled: true,
        scope_content: true,
        ..Default::default()
    };

    assert_app_web_parity(
        "默认去除重复标题",
        &book_default,
        &chapter_default,
        raw,
        std::slice::from_ref(&rule),
        &[],
        "已换",
    )
    .await;

    // 场景 b：章级 opt-out（保留标题）
    let book_keep = test_book(
        "https://batch20.example.com/book/parity-title-keep",
        "批二十去重书B",
    );
    let chapter_keep = test_chapter(
        &book_keep.book_url,
        0,
        "第一章 同名标题",
        "https://batch20.example.com/ch/title-b-0",
    );

    let web_state = make_web_state();
    seed_web(
        &web_state,
        &book_keep,
        &chapter_keep,
        raw,
        std::slice::from_ref(&rule),
    )
    .await;
    seed_app(&book_keep, &chapter_keep, std::slice::from_ref(&rule));
    {
        let db = web_state.db.lock().await;
        CacheRepository::new(db.connection())
            .put(
                &app_config::same_title_removed_key(&book_keep.book_url, 0),
                "1",
                0,
            )
            .unwrap();
    }
    with_database(|db| {
        CacheRepository::new(db.connection()).put(
            &app_config::same_title_removed_key(&book_keep.book_url, 0),
            "1",
            0,
        )
    })
    .unwrap();

    let web_json = web_content(web_state, &book_keep.book_url, 0).await;
    assert_eq!(web_json["isSuccess"], true, "web={web_json}");
    let web = web_json["data"].as_str().expect("Web 正文应为字符串");
    let app = app_content(
        &book_keep.book_url,
        raw,
        &chapter_keep.title,
        chapter_keep.index,
        &chapter_keep.url,
    );
    let expected = "第一章 同名标题\n已换";
    assert_eq!(app, expected, "App：章级 opt-out 应保留标题");
    assert_eq!(web, expected, "Web：必须读取同一章级开关");
    assert_eq!(app, web);
}

/// [批20-B] Web 配置读取失败 → 回退默认值（不崩、不返回原文）
///
/// 删除 `caches` 表模拟读库失败：净化仍按默认配置执行（去重标题开、
/// 替换默认开），而不是把配置读取失败误当成「关闭所有净化」。
#[tokio::test]
async fn test_web_purify_config_read_failure_falls_back_to_defaults() {
    let web_state = make_web_state();
    let book_url = "https://batch20.example.com/book/parity-config-fail";
    let book = test_book(book_url, "批二十配置失败书");
    let chapter = test_chapter(
        book_url,
        0,
        "第一章 同名标题",
        "https://batch20.example.com/ch/cf-0",
    );
    let raw = "第一章 同名标题\n正文标记";
    let rule = ReplaceRule {
        name: "批20_配置失败回退".to_string(),
        pattern: "正文标记".to_string(),
        replacement: "已换".to_string(),
        is_regex: false,
        is_enabled: true,
        scope_content: true,
        ..Default::default()
    };
    seed_web(
        &web_state,
        &book,
        &chapter,
        raw,
        std::slice::from_ref(&rule),
    )
    .await;
    {
        let db = web_state.db.lock().await;
        db.connection()
            .execute("DROP TABLE caches", [])
            .expect("删除 caches 表以模拟配置读取失败");
    }

    let web_json = web_content(web_state, book_url, 0).await;
    assert_eq!(web_json["isSuccess"], true, "web={web_json}");
    assert_eq!(
        web_json["data"], "已换",
        "配置读取失败应回退默认值（去重标题开 + 替换默认开）"
    );
}

/// 批17：`@js:` 抛错两端都保留原文，且后续普通规则继续生效
///
/// **覆盖性用例**：父提交（Web 跳过 `@js:`）同样保留原文，本用例防回归，
/// 不计入「修复前红」证据。
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
///
/// **覆盖性用例**：父提交（Web 跳过 `@js:`）同样保留原文，本用例防回归，
/// 不计入「修复前红」证据。
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
///
/// **覆盖性用例**：父提交同样不执行（Web 旧管线直接跳过），本用例防回归，
/// 不计入「修复前红」证据。
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
