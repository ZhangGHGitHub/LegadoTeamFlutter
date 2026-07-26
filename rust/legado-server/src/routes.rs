//! 路由组装

use axum::routing::{get, post, put};
use axum::Router;
use std::sync::Arc;
use tower_http::services::ServeDir;

use crate::handlers;
use crate::state::AppState;

/// 创建完整的应用路由，注入共享状态
pub fn create_router(state: Arc<AppState>) -> Router {
    Router::new()
        .nest("/api", api_routes())
        // 静态文件服务 — 提供 Web 前端资源（fallback 处理非 API 请求）
        .fallback_service(ServeDir::new("web-dist"))
        .with_state(state)
}

/// 组装 /api 下的所有子路由
fn api_routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/health", get(handlers::health::health_check))
        .route(
            "/books",
            get(handlers::bookshelf::list_books).post(handlers::bookshelf::create_book),
        )
        .route(
            "/books/{id}",
            get(handlers::bookshelf::get_book)
                .put(handlers::bookshelf::update_book)
                .delete(handlers::bookshelf::delete_book),
        )
        .route("/books/{id}/chapters", get(handlers::reader::get_chapters))
        .route(
            "/books/{id}/chapters/{index}/content",
            get(handlers::reader::get_chapter_content),
        )
        // 书籍导出
        .route("/books/export", post(handlers::export::export_book))
        .route("/books/export/info", post(handlers::export::export_info))
        .route(
            "/sources",
            get(handlers::source::list_sources).post(handlers::source::create_source),
        )
        .route(
            "/sources/{id}",
            put(handlers::source::update_source).delete(handlers::source::delete_source),
        )
        .route("/sources/check", post(handlers::source_check::check_source))
        .route("/sources/check-batch", post(handlers::source_check::check_batch))
        .route("/sources/repos", get(handlers::source_update::list_repos))
        .route("/sources/updates", get(handlers::source_update::check_updates))
        .route("/sources/update", post(handlers::source_update::execute_update))
        .route("/search", post(handlers::search::search_books))
        .route("/search/multi", post(handlers::search::search_multi))
        .route("/search/cancel", post(handlers::search::cancel_search))
        // WebBook 书源规则驱动链路
        .route("/webbook/search", post(handlers::web_book::search_books))
        .route("/webbook/info", post(handlers::web_book::get_book_info))
        .route("/webbook/chapters", post(handlers::web_book::get_chapters))
        .route("/webbook/content", post(handlers::web_book::get_content))
        // TTS 文本转语音
        .route("/tts/speak", post(handlers::tts::speak))
        .route("/tts/engines", get(handlers::tts::list_engines))
        // 听书音频播放
        .route("/audio/chapters", post(handlers::audio::get_chapters))
        .route("/audio/speak", post(handlers::audio::speak))
        .route("/audio/play", post(handlers::audio::play_control))
        // RSS 订阅源
        .route("/rss/articles", post(handlers::rss::get_articles))
        .route(
            "/rss/{source_url}/articles",
            get(handlers::rss::get_articles_by_path),
        )
        // 离线缓存
        .route("/cache/chapters", post(handlers::cache::cache_chapters))
        .route("/cache/stats", get(handlers::cache::cache_stats))
        .route(
            "/cache/book/{book_url}",
            axum::routing::delete(handlers::cache::delete_book_cache),
        )
        // 段评/本章热评
        .route(
            "/reviews/{book_url}/{chapter}",
            get(handlers::review::get_reviews),
        )
        .route("/reviews", post(handlers::review::create_review))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::AppState;
    use axum::body::Body;
    use axum::http::Request;
    use axum::http::StatusCode;
    use tokio::sync::Mutex;
    use tower::ServiceExt;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        })
    }

    #[tokio::test]
    async fn test_health_route() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn test_unknown_route_404() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/nonexistent")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::NOT_FOUND);
    }

    #[tokio::test]
    async fn test_all_routes_registered() {
        let state = make_test_state();
        let app = create_router(state);

        // 验证各路由均能匹配（不返回 404）
        let routes = vec![
            "/api/health",
            "/api/books",
            "/api/sources",
            "/api/tts/engines",
        ];

        for uri in routes {
            let app_clone = app.clone();
            let resp = app_clone
                .oneshot(Request::builder().uri(uri).body(Body::empty()).unwrap())
                .await
                .unwrap();

            assert_ne!(
                resp.status(),
                StatusCode::NOT_FOUND,
                "Route {uri} should be registered"
            );
        }
    }
}
