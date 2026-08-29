//! 搜索处理器

use std::sync::atomic::Ordering;
use std::sync::Arc;

use crate::error::ApiError;
use crate::state::AppState;
use axum::extract::State;
use axum::Json;
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

    // 匹配语义委托共享服务（P2-2，与 MCP search_books 同一实现）；
    // 响应组装保持本入口原有字段与包装不变。
    let matched = legado_core::shelf_search::match_shelf_books(&all_books, &req.keyword);
    let results: Vec<Value> = matched
        .iter()
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

    /// P0-3：/api/search/multi 已下线（Noop 空实现），路由应返回 404 而非空成功。
    /// 防止 "生产路由 + Noop 实现 + 200 即通过" 回归。
    #[tokio::test]
    async fn test_search_multi_route_removed() {
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

        // 路由已下线：不再是 200 空成功。POST 落到静态文件 fallback 返回 405，
        // 无 fallback 时为 404；两者都满足"客户端错误、非成功"。断言 4xx 更稳健。
        assert!(
            resp.status().is_client_error(),
            "/api/search/multi 应已下线（4xx），实际 {}",
            resp.status()
        );
    }
}
