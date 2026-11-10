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
//! 6. [批17 回修 P2] origin-only `scope` 的既有语义差异快照。
//!
//! **修复前红/覆盖性口径（按基线版本）**：
//! - 批17 前基线 `217e2c3dcb` 红：Web 正文执行/绑定断言（旧 Web 跳过 `@js:`）；
//! - `feebd44f41` 起为绿：`/testReplaceRule` 预览用例（修复随该提交落地，
//!   当前仅防回归，不再标「父提交必红」）；
//! - 覆盖性（父提交亦绿）：抛错、超时、无 quickjs —— 旧 Web 跳过 `@js:`
//!   同样保留原文，故不能作为修复证据。
//!
//! **parity 前提（P2-3）**：App 端与 Web 端均使用**默认正文净化配置**
//! （`chineseConverterType=0`、`replaceEnableDefault=true`、章级去重开启、
//! `reSegment=false`）且规则为全局作用域；非默认配置/scope 的差异见
//! `docs/API_CONTRACT.md` §2.8 批17 回修登记。
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
/// **parity 前提（显式 seed）**：App 端正文净化会读取
/// `config:chineseConverterType`（默认 0=不转换）、`config:replaceEnableDefault`
/// （默认 true）、章级 `sameTitleRemoved:{bookUrl}:{index}`（无键=去除，显式
/// 写 `"0"` 锁定）与 `readConfig.reSegment`（Book 行为空=关闭）。Web 端对应
/// 值固定为 None/true/true/false；仅当两端均为默认配置时「逐字相等」成立。
///
/// 各用例使用唯一 bookUrl，且 DB 文件按进程号隔离，无需清理历史行。
fn seed_app(book: &Book, chapter: &BookChapter, rules: &[ReplaceRule]) {
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.put("config:chineseConverterType", "0", 0)?;
        repo.put("config:replaceEnableDefault", "true", 0)?;
        repo.put(
            &format!("sameTitleRemoved:{}:{}", book.book_url, chapter.index),
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

/// [批17 回修 P2-3] `scope` 语义差异快照（已登记，非本批统一项）
///
/// - 书名精确命中（`scope` 恰为书名）：两端一致生效；
/// - **仅命中书籍来源**（`scope` 为完整 `origin`）：Web 走
///   `ContentProcessor` 的 `ScopeContext`（`scope.contains(book_name) ||
///   scope.contains(book_origin)`）→ 生效；App 正文路径先把 `scope` 按
///   `[,;，；]` 拆分后与**书名**精确比较（不看 origin、不处理
///   `excludeScope`）→ 不生效。
///
/// 该分叉为批前既有语义，已在 `docs/API_CONTRACT.md` §2.8 批17 回修登记；
/// 统一 scope 语义需另立批次并做设备验收，本用例锁定当前口径（改动时
/// 必须同步更新登记）。
#[cfg(feature = "quickjs")]
#[tokio::test]
async fn test_js_rule_scope_origin_only_known_divergence() {
    let _app_guard = ensure_app_db().await;
    let book_url = "https://batch17.example.com/book/parity-scope";
    let title = "第一章";
    let chapter_url = "https://batch17.example.com/ch/scope-0";
    let raw = "前A标记中B标记后";
    let rules = [
        // 书名精确命中：两端都生效
        ReplaceRule {
            name: "批17_书名作用域".to_string(),
            pattern: "A标记".to_string(),
            replacement: "A已换".to_string(),
            is_regex: false,
            is_enabled: true,
            scope_content: true,
            scope: Some("批十七作用域书".to_string()),
            ..Default::default()
        },
        // 仅书籍来源命中：Web 生效、App 不生效（既有差异）
        ReplaceRule {
            name: "批17_来源作用域".to_string(),
            pattern: "B标记".to_string(),
            replacement: r#"@js: result + "!""#.to_string(),
            is_regex: true,
            is_enabled: true,
            scope_content: true,
            scope: Some("https://batch17.example.com".to_string()),
            ..Default::default()
        },
    ];

    let book = test_book(book_url, "批十七作用域书");
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
        app, "前A已换中B标记后",
        "App：书名 scope 生效、origin-only scope 不生效（既有口径）"
    );
    assert_eq!(
        web, "前A已换中B标记!后",
        "Web：书名与 origin-only scope 均生效（原版 DAO 口径）"
    );
    assert_ne!(app, web, "该差异已登记，非本批修复范围");
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
