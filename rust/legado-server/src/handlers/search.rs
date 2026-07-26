//! 搜索处理器

use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::error::ApiError;
use crate::state::AppState;
use axum::extract::State;
use axum::Json;
use legado_core::search_engine::{MultiSourceSearcher, NoopSourceSearcher, SearchConfig};
use legado_db::repository::Repository;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// 搜索请求体
#[derive(Debug, Deserialize)]
pub struct SearchRequest {
    pub keyword: String,
    /// 可选：限定搜索的书源 URL 列表
    pub source_urls: Option<Vec<String>>,
}

/// 搜索结果条目
#[derive(Debug, Serialize)]
pub struct SearchResultItem {
    pub book_url: String,
    pub name: String,
    pub author: String,
    pub source_url: String,
    pub source_name: String,
    pub intro: Option<String>,
    pub cover_url: Option<String>,
}

/// 多源搜索请求体
#[derive(Debug, Deserialize)]
pub struct MultiSearchRequest {
    pub keyword: String,
    /// 书源 URL 列表（为空则搜索所有启用源）
    pub source_urls: Option<Vec<String>>,
    /// 单源超时（秒），默认 10
    pub timeout_secs: Option<u64>,
    /// 每源最大结果数，默认 20
    pub max_results_per_source: Option<usize>,
}

/// 多源搜索结果
#[derive(Debug, Serialize)]
pub struct MultiSearchResult {
    pub results: Vec<legado_core::search_engine::SearchResult>,
    pub total: usize,
    pub keyword: String,
}

/// POST /api/search — 搜索书籍
///
/// 当前实现：在本地书架中按名称模糊匹配。
/// 后续可扩展为通过书源网络搜索。
pub async fn search_books(
    State(state): State<Arc<AppState>>,
    Json(req): Json<SearchRequest>,
) -> Result<Json<Value>, ApiError> {
    let db = state.db.lock().await;
    let repo = legado_db::repository::book_repository::BookRepository::new(db.connection());
    let all_books = repo.find_all()?;

    let keyword_lower = req.keyword.to_lowercase();
    let results: Vec<Value> = all_books
        .into_iter()
        .filter(|book| {
            book.name.to_lowercase().contains(&keyword_lower)
                || book.author.to_lowercase().contains(&keyword_lower)
        })
        .map(|book| {
            json!({
                "book_url": book.book_url,
                "name": book.name,
                "author": book.author,
                "intro": book.intro,
                "cover_url": book.cover_url,
            })
        })
        .collect();

    Ok(Json(json!({
        "results": results,
        "total": results.len(),
        "keyword": req.keyword,
    })))
}

/// POST /api/search/multi — 多源并行搜索
///
/// 使用 MultiSourceSearcher 框架并行搜索多个书源，返回聚合结果。
/// 当前使用 NoopSourceSearcher 占位，网络实现待 legado-net 完善后替换。
pub async fn search_multi(
    State(state): State<Arc<AppState>>,
    Json(req): Json<MultiSearchRequest>,
) -> Result<Json<MultiSearchResult>, ApiError> {
    // 重置取消标志
    state.search_cancelled.store(false, Ordering::SeqCst);

    let config = SearchConfig {
        query: req.keyword.clone(),
        timeout_secs: req.timeout_secs.unwrap_or(10),
        max_results_per_source: req.max_results_per_source.unwrap_or(20),
    };

    // 获取待搜索书源（简化：从数据库加载启用的书源）
    let sources = {
        let db = state.db.lock().await;
        let repo = legado_db::repository::book_source_repository::BookSourceRepository::new(
            db.connection(),
        );
        repo.find_enabled().unwrap_or_default()
    };

    // 使用 NoopSourceSearcher 占位（网络实现待 legado-net 完善后替换）
    let searcher = MultiSourceSearcher::new(NoopSourceSearcher);
    let cancel = Arc::clone(&state.search_cancelled);
    let results = searcher.search(config, sources, cancel).await;
    let total = results.len();

    Ok(Json(MultiSearchResult {
        results,
        total,
        keyword: req.keyword,
    }))
}

/// POST /api/search/cancel — 取消正在进行的搜索
pub async fn cancel_search(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    state.search_cancelled.store(true, Ordering::SeqCst);
    Ok(Json(json!({ "status": "cancelled" })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::StatusCode;
    use axum::http::{Method, Request};
    use std::sync::atomic::AtomicBool;
    use tokio::sync::Mutex;
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;
    use legado_core::models::Book;
    use legado_db::repository::book_repository::BookRepository;
    use legado_db::repository::Repository;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    #[tokio::test]
    async fn test_search_books() {
        let state = make_test_state();

        // 插入测试数据
        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            repo.insert(&Book {
                book_url: "u1".to_string(),
                name: "三体".to_string(),
                author: "刘慈欣".to_string(),
                ..Book::default()
            })
            .unwrap();
            repo.insert(&Book {
                book_url: "u2".to_string(),
                name: "活着".to_string(),
                author: "余华".to_string(),
                ..Book::default()
            })
            .unwrap();
        }

        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "keyword": "三体"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_search_no_results() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "keyword": "不存在的书"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_search_multi_returns_ok() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "keyword": "斗破苍穹"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/search/multi")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_search_multi_with_options() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "keyword": "凡人修仙传",
            "timeout_secs": 5,
            "max_results_per_source": 10
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/search/multi")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_cancel_search() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/search/cancel")
                    .header("Content-Type", "application/json")
                    .body(Body::from("{}"))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_cancel_then_check_flag() {
        let state = make_test_state();
        assert!(!state.search_cancelled.load(Ordering::SeqCst));

        // 触发取消
        state.search_cancelled.store(true, Ordering::SeqCst);
        assert!(state.search_cancelled.load(Ordering::SeqCst));
    }
}
