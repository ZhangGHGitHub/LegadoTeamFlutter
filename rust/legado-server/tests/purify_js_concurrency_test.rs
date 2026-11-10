//! [批17 复审 P2] `/getBookContent` 的 `@js:` 净化并发上限
//!
//! `/getBookContent` 无鉴权，`@js:` 属 CPU 密集任务：`purify_content` 用
//! 进程级信号量（`PURIFY_JS_MAX_CONCURRENCY = 4`）**非阻塞**限流，超限请求
//! 不排队、直接保留原文；生产 server runtime 另设 `max_blocking_threads(8)`
//! （见 `legado-ffi/src/api/server_api.rs`）。
//!
//! 本文件独占一个集成测试进程：信号量为进程级 static，不能与
//! `legacy_web_test` 的其他 `@js:` 用例同进程并行，否则计数不确定。
//!
//! 运行：`cargo test -p legado-server --features quickjs --test purify_js_concurrency_test -- --nocapture`

#[cfg(feature = "quickjs")]
mod quickjs_concurrency {
    use std::sync::atomic::AtomicBool;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    use axum::body::Body;
    use axum::http::Request;
    use futures_util::future::join_all;
    use serde_json::Value;
    use tokio::sync::Mutex;
    use tower::ServiceExt;

    use legado_core::cache_book::CachedChapter;
    use legado_core::download_manager::DownloadManager;
    use legado_core::models::{Book, BookChapter, ReplaceRule};
    use legado_db::repository::book_chapter_repository::BookChapterRepository;
    use legado_db::repository::book_repository::BookRepository;
    use legado_db::repository::cache_book_repository::CacheBookRepository;
    use legado_db::repository::replace_rule_repository::ReplaceRuleRepository;
    use legado_db::repository::Repository;
    use legado_server::routes::create_router;
    use legado_server::state::AppState;

    /// 并发请求数（上限 4 → 预期 4 条执行 JS、4 条保留原文）
    const CONCURRENT_REQUESTS: usize = 8;

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

    /// 书籍 + 章节 + 缓存正文 + 启用中的 `@js:` 规则
    async fn seed(state: &Arc<AppState>, raw: &str) {
        let db = state.db.lock().await;
        BookRepository::new(db.connection())
            .insert(&Book {
                book_url: "https://b17-concurrency.example.com/book/1".to_string(),
                origin: "https://b17-concurrency.example.com".to_string(),
                name: "批十七并发书".to_string(),
                author: "作者".to_string(),
                ..Book::default()
            })
            .unwrap();
        BookChapterRepository::new(db.connection())
            .insert(&BookChapter {
                url: "https://b17-concurrency.example.com/ch/0".to_string(),
                title: "第一章".to_string(),
                book_url: "https://b17-concurrency.example.com/book/1".to_string(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
        CacheBookRepository::new(db.connection())
            .insert(&CachedChapter {
                id: 0,
                book_url: "https://b17-concurrency.example.com/book/1".to_string(),
                chapter_index: 0,
                chapter_title: "第一章".to_string(),
                chapter_url: "https://b17-concurrency.example.com/ch/0".to_string(),
                content: raw.to_string(),
                cached_at: 0,
                size_bytes: 0,
            })
            .unwrap();
        ReplaceRuleRepository::new(db.connection())
            .insert(&ReplaceRule {
                name: "批17_并发限流".to_string(),
                pattern: "标记".to_string(),
                // 约 500ms 的同步忙等，保证 8 个请求的限流判定发生在
                // 任一 JS 任务释放 permit 之前
                replacement:
                    r#"@js:(function(){var t=Date.now();while(Date.now()-t<500){}return result+"!";})()"#
                        .to_string(),
                is_regex: true,
                is_enabled: true,
                scope_content: true,
                timeout_millisecond: 3_000,
                ..Default::default()
            })
            .unwrap();
    }

    /// [批17 复审 P2] 并发 8 个含 `@js:` 的正文请求：
    /// - 4 条获得信号量 → 真实执行 JS（输出含 `!`）；
    /// - 4 条超限 → 非阻塞跳过、保留原文（不等待 JS 完成）；
    /// - 全部请求在合理时间内返回。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_purify_js_concurrency_limit_keeps_original_over_limit() {
        let state = make_test_state();
        let raw = "前标记后";
        let transformed = "前标记!后";
        seed(&state, raw).await;
        let app = create_router(state);
        let uri = format!(
            "/getBookContent?url={}&index=0",
            enc("https://b17-concurrency.example.com/book/1")
        );

        let started = Instant::now();
        let requests = (0..CONCURRENT_REQUESTS).map(|_| {
            let app = app.clone();
            let uri = uri.clone();
            async move {
                let request_started = Instant::now();
                let resp = app
                    .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
                    .await
                    .unwrap();
                let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
                    .await
                    .unwrap();
                let rd: Value = serde_json::from_slice(&bytes).unwrap();
                (request_started.elapsed(), rd)
            }
        });
        let results = join_all(requests).await;
        let elapsed = started.elapsed();

        let mut transformed_count = 0usize;
        let mut raw_count = 0usize;
        let mut raw_elapsed_min = Duration::MAX;
        let mut js_elapsed_max = Duration::ZERO;
        for (request_elapsed, rd) in &results {
            assert_eq!(rd["isSuccess"], true, "rd={rd}");
            match rd["data"].as_str().unwrap_or_default() {
                value if value == transformed => {
                    transformed_count += 1;
                    js_elapsed_max = js_elapsed_max.max(*request_elapsed);
                }
                value if value == raw => {
                    raw_count += 1;
                    raw_elapsed_min = raw_elapsed_min.min(*request_elapsed);
                }
                other => panic!("未预期的正文输出: {other:?}（rd={rd}）"),
            }
        }
        eprintln!(
            "[批17 并发] elapsed={elapsed:?} transformed={transformed_count} \
             raw={raw_count} min_raw_elapsed={raw_elapsed_min:?} \
             max_js_elapsed={js_elapsed_max:?}"
        );

        assert_eq!(
            transformed_count, 4,
            "信号量上限 4：应恰有 4 条执行 JS（实际 {transformed_count}）"
        );
        assert_eq!(raw_count, 4, "超限 4 条应保留原文（实际 {raw_count}）");
        assert!(
            raw_elapsed_min < Duration::from_millis(400),
            "超限请求不得等待 JS 完成（非阻塞限流），实际最短 {raw_elapsed_min:?}"
        );
        assert!(
            js_elapsed_max >= Duration::from_millis(450),
            "获得许可的请求应真实执行 JS 忙等，实际最长 {js_elapsed_max:?}"
        );
        assert!(
            elapsed < Duration::from_secs(10),
            "全部请求应在合理时间内返回，实际 {elapsed:?}"
        );
    }
}
