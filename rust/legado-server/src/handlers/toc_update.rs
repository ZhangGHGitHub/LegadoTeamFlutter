//! 书架目录更新处理器（单本 + 批量）
//!
//! 提供 REST 端点：
//! - POST /api/bookshelf/update-toc/single — 单本目录更新（对标 Kotlin TocUpdateRequests 单本流程）
//! - POST /api/bookshelf/update-toc — 批量更新目录（对标 Kotlin MainViewModel.upToc/upAllBookToc，#480）
//! - GET  /api/bookshelf/update-toc/progress — 获取更新进度（逐本回报）
//! - POST /api/bookshelf/update-toc/stop — 停止更新（对标 Kotlin cancelAll）
//!
//! 单本更新链路：读取书籍/书源 → （可选）刷新书籍详情 → 请求目录 → 落库（删旧插新 + 书籍统计字段）。
//! 批量更新链路：模块级全局 TocUpdater + `legado_core::toc_updater::run_batch` 调度器，
//! 限流并发、逐本回报进度、单本失败不中断整批。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use tokio::sync::Mutex;

use legado_core::models::BookChapter;
use legado_core::toc_updater::{run_batch, TocUpdateRequest, TocUpdater};
use legado_core::web_book::WebBookEngine;
use legado_db::repository::Repository;
use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

use super::web_book::{build_engine, RealBookSourceFetcher};
use crate::error::ApiError;
use crate::state::AppState;

/// 全局目录更新调度器实例（批量任务共享）
static TOC_UPDATER: LazyLock<Mutex<Arc<TocUpdater>>> =
    LazyLock::new(|| Mutex::new(Arc::new(TocUpdater::new(4))));

/// 批量更新停止标志（对标 Kotlin TocUpdateRequests.cancelAll 的取消语义）
static STOP_FLAG: AtomicBool = AtomicBool::new(false);

// ─── 请求/响应类型 ─────────────────────────────────────────────────────────────

/// 批量更新请求体
#[derive(Debug, Deserialize)]
pub struct BatchTocUpdateBody {
    pub books: Vec<BookTocEntry>,
    /// 最大并发数，默认 4（对标 Kotlin AppConfig.threadCount 限流）
    #[serde(default = "default_concurrent")]
    pub max_concurrent: usize,
}

fn default_concurrent() -> usize {
    4
}

#[derive(Debug, Deserialize)]
pub struct BookTocEntry {
    pub book_url: String,
    pub book_name: String,
    /// 书源 URL；为空时使用书籍自身 origin
    #[serde(default)]
    pub source_url: String,
    #[serde(default)]
    pub priority: i32,
    /// 是否强制刷新书籍详情（对标 Kotlin refreshBookInfo）
    #[serde(default)]
    pub refresh_book_info: bool,
}

/// 单本更新请求体
#[derive(Debug, Deserialize)]
pub struct SingleTocUpdateBody {
    pub book_url: String,
    /// 书源 URL；为空时使用书籍自身 origin
    #[serde(default)]
    pub source_url: String,
    /// 是否强制刷新书籍详情
    #[serde(default)]
    pub refresh_book_info: bool,
}

/// 单本更新结果
struct TocUpdateOutcome {
    /// 更新后的章节总数
    total_chapters: i32,
    /// 本次新发现的章节数
    new_chapters: i32,
}

// ─── 单本更新核心逻辑 ──────────────────────────────────────────────────────────

/// 单本目录更新（对标 Kotlin `MainViewModel.updateToc` 的单本流程）
///
/// 流程：
/// 1. 从 DB 读取书籍与书源（书源 URL 缺省时取 `book.origin`）
/// 2. `refresh_book_info` 或 `toc_url` 为空时先请求详情页补全信息
///    （对标 Kotlin `WebBook.getBookInfoAwait`）
/// 3. 请求目录页解析章节列表（对标 Kotlin `WebBook.getChapterListAwait`）
/// 4. 事务式落库：校验书源未变 → 删旧章节插新章节 → 更新书籍统计字段
///    （对标 Kotlin `appDb.runInTransaction` 中的 origin 校验与 book.sync）
async fn update_one_toc(
    state: Arc<AppState>,
    engine: &WebBookEngine<RealBookSourceFetcher>,
    book_url: &str,
    source_url_override: &str,
    refresh_book_info: bool,
) -> Result<TocUpdateOutcome, String> {
    // 1. 读取书籍与书源（短持锁，避免跨网络请求持锁）
    let (mut book, source, previous_total, need_info) = {
        let db = state.db.lock().await;
        let book_repo = BookRepository::new(db.connection());
        let book = book_repo
            .find_by_url(book_url)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "书籍不存在".to_string())?;
        let source_url = if source_url_override.trim().is_empty() {
            book.origin.clone()
        } else {
            source_url_override.to_string()
        };
        let source = BookSourceRepository::new(db.connection())
            .find_by_url(&source_url)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| format!("书源不存在: {source_url}"))?;
        let need_info = refresh_book_info || book.toc_url.trim().is_empty();
        let previous_total = book.total_chapter_num;
        (book, source, previous_total, need_info)
    };

    // 2. 按需刷新书籍详情（仅补空字段，避免覆盖用户本地数据）
    let mut info_update: Option<(Option<String>, Option<String>, String)> = None;
    if need_info {
        let info = engine
            .get_book_info(&source, book_url)
            .await
            .map_err(|e| format!("获取书籍详情失败: {e}"))?;
        if book.name.trim().is_empty() && !info.name.trim().is_empty() {
            book.name = info.name.clone();
        }
        if book.author.trim().is_empty() && !info.author.trim().is_empty() {
            book.author = info.author.clone();
        }
        if book.cover_url.is_none() {
            book.cover_url = info.cover_url.clone();
        }
        if book.intro.is_none() {
            book.intro = info.intro.clone();
        }
        book.toc_url = info.toc_url.clone();
        // 记录用于落库阶段合并的最新章节信息
        info_update = Some((
            info.last_chapter.clone(),
            info.word_count.clone(),
            info.toc_url,
        ));
    }

    // 3. 请求目录页解析章节列表
    let web_chapters = engine
        .get_chapters(&source, book_url)
        .await
        .map_err(|e| format!("获取目录失败: {e}"))?;
    if web_chapters.is_empty() {
        return Err("目录解析结果为空".to_string());
    }

    // 转换为 BookChapter（与 FFI reader_refresh_toc 保持一致）
    let book_chapters: Vec<BookChapter> = web_chapters
        .iter()
        .map(|wc| BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: wc.is_volume,
            base_url: book_url.to_string(),
            book_url: book_url.to_string(),
            index: wc.index,
            is_vip: wc.is_vip,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: None,
            start: None,
            end: None,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: None,
            img_url: None,
        })
        .collect();

    let now = now_millis();
    let new_chapters = (book_chapters.len() as i32 - previous_total).max(0);
    let last_title = web_chapters.last().map(|c| c.title.clone());

    // 4. 落库（对标 Kotlin 事务：重新读取当前书籍并校验书源未变）
    {
        let db = state.db.lock().await;
        let book_repo = BookRepository::new(db.connection());
        let current = book_repo
            .find_by_url(book_url)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "书籍已不存在".to_string())?;
        if current.origin != source.book_source_url {
            return Err("书籍书源已变更，放弃本次更新".to_string());
        }

        // 合并书籍统计字段（对标 Kotlin book.sync(currentBook, toc)）
        book.total_chapter_num = book_chapters.len() as i32;
        book.last_check_time = now;
        book.last_check_count = new_chapters;
        if new_chapters > 0 {
            book.latest_chapter_time = now;
        }
        if let Some(title) = last_title {
            book.latest_chapter_title = Some(title);
        }
        if let Some((last_chapter, word_count, _toc)) = info_update {
            if book.word_count.is_none() {
                book.word_count = word_count;
            }
            // 详情页给出的最新章节仅在目录解析缺尾时兜底
            if book.latest_chapter_title.is_none() {
                book.latest_chapter_title = last_chapter;
            }
        }

        let chapter_repo = BookChapterRepository::new(db.connection());
        chapter_repo
            .delete_by_book_url(book_url)
            .map_err(|e| e.to_string())?;
        chapter_repo
            .insert_batch(&book_chapters)
            .map_err(|e| e.to_string())?;
        book_repo.update(&book).map_err(|e| e.to_string())?;
    }

    Ok(TocUpdateOutcome {
        total_chapters: book_chapters.len() as i32,
        new_chapters,
    })
}

fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

// ─── HTTP 端点 ────────────────────────────────────────────────────────────────

/// POST /api/bookshelf/update-toc/single — 单本目录更新
pub async fn update_single_toc(
    State(state): State<Arc<AppState>>,
    Json(body): Json<SingleTocUpdateBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let engine = build_engine();
    match update_one_toc(
        state,
        &engine,
        &body.book_url,
        &body.source_url,
        body.refresh_book_info,
    )
    .await
    {
        Ok(outcome) => Ok((
            StatusCode::OK,
            Json(json!({
                "updated": true,
                "book_url": body.book_url,
                "total_chapters": outcome.total_chapters,
                "new_chapters": outcome.new_chapters,
            })),
        )),
        Err(err) => Ok((
            StatusCode::BAD_REQUEST,
            Json(json!({
                "updated": false,
                "book_url": body.book_url,
                "error": err,
            })),
        )),
    }
}

/// POST /api/bookshelf/update-toc — 批量更新目录（#480）
///
/// 对标 Kotlin `MainViewModel.upToc`：入队 → 限流并发执行 → 逐本回报进度。
/// 后台 tokio 任务执行，通过 progress 端点轮询进度。
pub async fn start_toc_update(
    State(state): State<Arc<AppState>>,
    Json(body): Json<BatchTocUpdateBody>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let updater = {
        let guard = TOC_UPDATER.lock().await;
        if guard.get_progress().is_running {
            return Ok((
                StatusCode::CONFLICT,
                Json(json!({ "error": "batch update already running" })),
            ));
        }
        // 重置停止标志并重建调度器（应用新的并发数）
        STOP_FLAG.store(false, Ordering::SeqCst);
        let new_updater = Arc::new(TocUpdater::new(body.max_concurrent.max(1)));
        drop(guard);
        let mut guard = TOC_UPDATER.lock().await;
        *guard = Arc::clone(&new_updater);
        new_updater
    };

    let requests: Vec<TocUpdateRequest> = body
        .books
        .into_iter()
        .map(|b| TocUpdateRequest {
            book_url: b.book_url,
            book_name: b.book_name,
            source_url: b.source_url,
            priority: b.priority,
            refresh_book_info: b.refresh_book_info,
        })
        .collect();
    let total = requests.len();

    // 后台执行批量调度（worker 闭包：每本书独立走单本更新链路）
    let engine = Arc::new(build_engine());
    let worker = move |req: TocUpdateRequest| {
        let state = Arc::clone(&state);
        let engine = Arc::clone(&engine);
        async move {
            update_one_toc(
                state,
                &engine,
                &req.book_url,
                &req.source_url,
                req.refresh_book_info,
            )
            .await
            .map(|o| o.new_chapters)
        }
    };
    tokio::spawn(run_batch(updater, requests, worker, || {
        STOP_FLAG.load(Ordering::SeqCst)
    }));

    Ok((
        StatusCode::OK,
        Json(json!({
            "started": true,
            "total": total,
            "max_concurrent": body.max_concurrent,
        })),
    ))
}

/// GET /api/bookshelf/update-toc/progress — 获取更新进度
pub async fn get_toc_update_progress() -> Result<Json<Value>, ApiError> {
    let updater = TOC_UPDATER.lock().await;
    let progress = updater.get_progress();
    Ok(Json(json!(progress)))
}

/// POST /api/bookshelf/update-toc/stop — 停止更新
///
/// 设置停止标志：已在飞的书本会自然完成，尚未开始的书目标记为失败。
pub async fn stop_toc_update() -> Result<Json<Value>, ApiError> {
    let was_running = {
        let updater = TOC_UPDATER.lock().await;
        updater.get_progress().is_running
    };
    STOP_FLAG.store(true, Ordering::SeqCst);
    if was_running {
        let updater = TOC_UPDATER.lock().await;
        updater.finish_batch();
    }
    Ok(Json(json!({
        "stopped": was_running,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request};
    use axum::routing::{get, post};
    use axum::Router;
    use legado_core::download_manager::DownloadManager;
    use legado_core::models::Book;
    use legado_db::repository::Repository;
    use tower::ServiceExt;

    /// 序列化测试，避免全局静态竞争
    static TEST_LOCK: std::sync::LazyLock<tokio::sync::Mutex<()>> =
        std::sync::LazyLock::new(|| tokio::sync::Mutex::new(()));

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: Mutex::new(DownloadManager::new(3)),
        })
    }

    fn test_router(state: Arc<AppState>) -> Router {
        Router::new()
            .route("/api/bookshelf/update-toc/single", post(update_single_toc))
            .route("/api/bookshelf/update-toc", post(start_toc_update))
            .route(
                "/api/bookshelf/update-toc/progress",
                get(get_toc_update_progress),
            )
            .route("/api/bookshelf/update-toc/stop", post(stop_toc_update))
            .with_state(state)
    }

    async fn reset_global() {
        STOP_FLAG.store(false, Ordering::SeqCst);
        let updater = TOC_UPDATER.lock().await;
        updater.reset();
    }

    async fn body_json(body: Body) -> Value {
        serde_json::from_slice(&axum::body::to_bytes(body, usize::MAX).await.unwrap()).unwrap()
    }

    #[tokio::test]
    async fn test_start_toc_update() {
        let _guard = TEST_LOCK.lock().await;
        reset_global().await;

        let app = test_router(make_test_state());

        let body = serde_json::to_string(&json!({
            "books": [
                { "book_url": "url1", "book_name": "Book1", "source_url": "src1" },
                { "book_url": "url2", "book_name": "Book2", "source_url": "src2", "priority": 1 }
            ],
            "max_concurrent": 2
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp.into_body()).await;
        assert_eq!(json["started"], true);
        assert_eq!(json["total"], 2);

        // 等待后台任务结束（书籍不在库中，会立即失败），避免污染后续测试
        wait_batch_done(2).await;
    }

    /// 两阶段等待批量任务结束：
    /// 先等到批次真正启动（total 达到预期，避免读到启动前的旧空闲态提前退出），
    /// 再等到运行结束。
    async fn wait_batch_done(expected_total: usize) {
        // 阶段 1：等待批次启动
        for _ in 0..250 {
            let p = TOC_UPDATER.lock().await.get_progress();
            if p.total == expected_total {
                break;
            }
            drop(p);
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        // 阶段 2：等待运行结束
        for _ in 0..250 {
            let p = TOC_UPDATER.lock().await.get_progress();
            if !p.is_running && p.updating == 0 {
                return;
            }
            drop(p);
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    }

    /// 批量执行集成：书籍不在库中时逐本失败回报，不阻塞端点
    #[tokio::test]
    async fn test_batch_reports_failures_for_missing_books() {
        let _guard = TEST_LOCK.lock().await;
        reset_global().await;

        let app = test_router(make_test_state());

        let body = serde_json::to_string(&json!({
            "books": [
                { "book_url": "missing1", "book_name": "M1", "source_url": "s" },
                { "book_url": "missing2", "book_name": "M2", "source_url": "s" }
            ],
            "max_concurrent": 2
        }))
        .unwrap();

        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        wait_batch_done(2).await;

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/bookshelf/update-toc/progress")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let json = body_json(resp.into_body()).await;
        assert_eq!(json["is_running"], false);
        assert_eq!(json["total"], 2);
        assert_eq!(json["failed"], 2);
        // 错误信息逐本回报
        assert!(json["results"][0]["error"]
            .as_str()
            .unwrap()
            .contains("书籍不存在"));
    }

    #[tokio::test]
    async fn test_get_progress() {
        let _guard = TEST_LOCK.lock().await;
        reset_global().await;

        let app = test_router(make_test_state());

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/bookshelf/update-toc/progress")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp.into_body()).await;
        assert_eq!(json["is_running"], false);
        assert_eq!(json["total"], 0);
    }

    #[tokio::test]
    async fn test_stop_update() {
        let _guard = TEST_LOCK.lock().await;
        reset_global().await;
        let app = test_router(make_test_state());

        // 直接预置一个运行中的批次（确定性验证停止端点语义，不依赖后台调度时序）
        {
            let running = Arc::new(TocUpdater::new(2));
            running.start_batch(vec![legado_core::toc_updater::TocUpdateRequest {
                book_url: "url1".into(),
                book_name: "Book1".into(),
                source_url: "src1".into(),
                priority: 0,
                refresh_book_info: false,
            }]);
            let mut guard = TOC_UPDATER.lock().await;
            *guard = running;
        }

        // 然后停止
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc/stop")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
        let json = body_json(resp.into_body()).await;
        assert_eq!(json["stopped"], true);
        // 停止标志已置位，进度不再处于运行态
        assert!(!TOC_UPDATER.lock().await.get_progress().is_running);
    }

    /// 单本更新端点：书籍不在库中时返回 400 与错误描述
    #[tokio::test]
    async fn test_single_update_missing_book() {
        let _guard = TEST_LOCK.lock().await;
        reset_global().await;

        let app = test_router(make_test_state());

        let body = serde_json::to_string(&json!({
            "book_url": "https://example.com/no-such-book"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc/single")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
        let json = body_json(resp.into_body()).await;
        assert_eq!(json["updated"], false);
        assert_eq!(json["error"], "书籍不存在");
    }

    /// 单本更新端点：书籍在库但书源缺失时返回书源错误
    #[tokio::test]
    async fn test_single_update_missing_source() {
        let _guard = TEST_LOCK.lock().await;
        reset_global().await;

        let state = make_test_state();
        // 插入一本网络书（origin 指向不存在的书源）
        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            let book = Book {
                book_url: "https://example.com/book-x".to_string(),
                name: "测试书".to_string(),
                origin: "https://example.com/no-such-source".to_string(),
                ..Book::default()
            };
            repo.insert(&book).unwrap();
        }

        let app = test_router(state);

        let body = serde_json::to_string(&json!({
            "book_url": "https://example.com/book-x"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/bookshelf/update-toc/single")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
        let json = body_json(resp.into_body()).await;
        assert_eq!(json["updated"], false);
        assert!(json["error"].as_str().unwrap().contains("书源不存在"));
    }
}
