//! 阅读相关处理器（章节列表、章节内容）

use axum::extract::{Path, State};
use axum::Json;
use serde_json::{json, Value};
use std::sync::Arc;

use legado_core::models::book::book_type;
use legado_core::web_book::WebChapter;
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::repository::book_repository::BookRepository;
use legado_db::BookSourceRepository;

use crate::error::ApiError;
use crate::state::AppState;

/// GET /api/books/:id/chapters — 获取指定书籍的章节列表
pub async fn get_chapters(
    State(state): State<Arc<AppState>>,
    Path(book_url): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = BookChapterRepository::new(db.connection());
    let chapters = repo.find_by_book_url(&book_url)?;
    Ok(Json(json!({
        "chapters": chapters,
        "total": chapters.len(),
    })))
}

/// GET /api/books/:id/chapters/:index/content — 获取指定章节内容
///
/// Task #135（R3 正文桩接线）：由元数据桩改为真实正文抓取——
/// 按 bookUrl + index 查章节，经书籍 origin 定位书源，复用
/// `web_book::build_engine`（RealBookSourceFetcher）同款正文抓取链路
/// （含 nextContentUrl 分页）。书源/章节缺失时返回 200 + error JSON
///（对齐本 crate bookshelf/rule_update 的 not-found 响应风格），
/// 抓取失败经 ApiError 映射为 5xx。
pub async fn get_chapter_content(
    State(state): State<Arc<AppState>>,
    Path((book_url, index)): Path<(String, i32)>,
) -> Result<Json<Value>, ApiError> {
    // 1. DB 查询（章节 → 书籍 → 书源），查完即释放锁，避免持锁发起网络抓取
    let (chapter, source) = {
        let db = state.db.lock().await;

        let ch_repo = BookChapterRepository::new(db.connection());
        let chapter = match ch_repo.find_by_book_url_and_index(&book_url, index)? {
            Some(c) => c,
            None => {
                return Ok(Json(json!({
                    "error": "chapter not found",
                    "book_url": book_url,
                    "index": index,
                })))
            }
        };

        let book_repo = BookRepository::new(db.connection());
        let book = match book_repo.find_by_url(&book_url)? {
            Some(b) => b,
            None => {
                return Ok(Json(json!({
                    "error": "book not found",
                    "book_url": book_url,
                })))
            }
        };

        // 本地书（origin 为空或 loc_book）无网络书源可抓
        if book.origin.is_empty() || book.origin == book_type::LOCAL_TAG {
            return Ok(Json(json!({
                "error": "book has no associated web source",
                "book_url": book_url,
                "origin": book.origin,
            })));
        }

        let src_repo = BookSourceRepository::new(db.connection());
        match src_repo.find_by_url(&book.origin)? {
            Some(s) => (chapter, s),
            None => {
                return Ok(Json(json!({
                    "error": "book source not found",
                    "book_url": book_url,
                    "origin": book.origin,
                })))
            }
        }
    };

    // 2. 复用 web_book 同款正文抓取链路（含分页）
    let engine = crate::handlers::web_book::build_engine();
    let web_chapter = WebChapter::new(chapter.index, chapter.title.clone(), chapter.url.clone());
    let content = engine
        .get_content(&source, &web_chapter)
        .await
        .map_err(ApiError::from)?;

    Ok(Json(json!({
        "chapter": chapter,
        "content": content,
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use axum::http::StatusCode;
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;
    use legado_core::models::rule::ContentRule;
    use legado_core::models::{Book, BookChapter, BookSource};
    use legado_db::repository::book_chapter_repository::BookChapterRepository;
    use legado_db::repository::book_repository::BookRepository;
    use legado_db::repository::Repository;
    use legado_db::BookSourceRepository;
    use tokio::sync::Mutex;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    async fn seed_data(state: &Arc<AppState>) {
        let db = state.db.lock().await;
        let book_repo = BookRepository::new(db.connection());
        let book = Book {
            book_url: "book1".to_string(),
            name: "测试书".to_string(),
            author: "作者".to_string(),
            ..Book::default()
        };
        book_repo.insert(&book).unwrap();

        let ch_repo = BookChapterRepository::new(db.connection());
        ch_repo
            .insert(&BookChapter {
                url: "book1/ch0".to_string(),
                title: "第1章".to_string(),
                book_url: "book1".to_string(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
        ch_repo
            .insert(&BookChapter {
                url: "book1/ch1".to_string(),
                title: "第2章".to_string(),
                book_url: "book1".to_string(),
                index: 1,
                ..BookChapter::default()
            })
            .unwrap();
    }

    /// Task #135：插入带书源的在线书（origin 指向已入库书源），章节 URL
    /// 指向不可达地址以便离线验证抓取失败路径（连接拒绝，不依赖外部网络）
    async fn seed_online_book(state: &Arc<AppState>) {
        let db = state.db.lock().await;

        let src_repo = BookSourceRepository::new(db.connection());
        src_repo
            .insert(&BookSource {
                book_source_url: "https://src.example.com".to_string(),
                book_source_name: "测试书源".to_string(),
                rule_content: Some(ContentRule {
                    content: Some(".content@html".to_string()),
                    ..ContentRule::default()
                }),
                ..BookSource::default()
            })
            .unwrap();

        let book_repo = BookRepository::new(db.connection());
        book_repo
            .insert(&Book {
                book_url: "book2".to_string(),
                origin: "https://src.example.com".to_string(),
                origin_name: "测试书源".to_string(),
                name: "在线书".to_string(),
                author: "作者".to_string(),
                ..Book::default()
            })
            .unwrap();

        let ch_repo = BookChapterRepository::new(db.connection());
        ch_repo
            .insert(&BookChapter {
                url: "http://127.0.0.1:1/ch0.html".to_string(),
                title: "第1章".to_string(),
                book_url: "book2".to_string(),
                index: 0,
                ..BookChapter::default()
            })
            .unwrap();
    }

    /// Task #135：发起 GET 请求并解析响应 JSON
    async fn get_json(app: axum::Router, uri: &str) -> (StatusCode, Value) {
        let resp = app
            .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
            .await
            .unwrap();
        let status = resp.status();
        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        (status, serde_json::from_slice(&body).unwrap())
    }

    #[tokio::test]
    async fn test_get_chapters() {
        let state = make_test_state();
        seed_data(&state).await;
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books/book1/chapters")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_get_chapter_content() {
        // Task #135：本地书（默认 origin = loc_book）无网络书源可抓，
        // 返回 200 + error JSON（对齐 crate 既有 not-found 风格）
        let state = make_test_state();
        seed_data(&state).await;
        let app = create_router(state);

        let (status, json) = get_json(app, "/api/books/book1/chapters/0/content").await;
        assert_eq!(status, StatusCode::OK);
        assert!(json["error"].as_str().unwrap().contains("source"));
    }

    #[tokio::test]
    async fn test_get_chapter_content_not_found() {
        let state = make_test_state();
        let app = create_router(state);

        let (status, json) = get_json(app, "/api/books/book1/chapters/99/content").await;
        assert_eq!(status, StatusCode::OK); // 返回 200 但包含 error 字段
        assert_eq!(json["error"].as_str().unwrap(), "chapter not found");
    }

    #[tokio::test]
    async fn test_get_chapter_content_source_not_found() {
        // Task #135：书籍 origin 指向未入库书源 → 200 + "book source not found"
        let state = make_test_state();
        {
            let db = state.db.lock().await;
            let book_repo = BookRepository::new(db.connection());
            book_repo
                .insert(&Book {
                    book_url: "book3".to_string(),
                    origin: "https://missing-src.example.com".to_string(),
                    name: "孤儿书".to_string(),
                    ..Book::default()
                })
                .unwrap();
            let ch_repo = BookChapterRepository::new(db.connection());
            ch_repo
                .insert(&BookChapter {
                    url: "book3/ch0".to_string(),
                    title: "第1章".to_string(),
                    book_url: "book3".to_string(),
                    index: 0,
                    ..BookChapter::default()
                })
                .unwrap();
        }
        let app = create_router(state);

        let (status, json) = get_json(app, "/api/books/book3/chapters/0/content").await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(json["error"].as_str().unwrap(), "book source not found");
    }

    #[tokio::test]
    async fn test_get_chapter_content_fetch_failure() {
        // Task #135：书源存在但章节 URL 不可达（127.0.0.1:1 连接拒绝）
        // → Network 错误经 ApiError 映射为 502（BAD_GATEWAY）
        let state = make_test_state();
        seed_online_book(&state).await;
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/books/book2/chapters/0/content")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert!(
            resp.status() == StatusCode::BAD_GATEWAY
                || resp.status() == StatusCode::GATEWAY_TIMEOUT,
            "expected upstream failure status, got: {}",
            resp.status()
        );
    }
}
