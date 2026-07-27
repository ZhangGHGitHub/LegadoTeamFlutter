//! 路由组装

use axum::routing::{delete, get, post, put};
use axum::Router;
use std::sync::Arc;
use tower_http::services::ServeDir;

use crate::handlers;
use crate::state::AppState;
use crate::ws;

/// 创建完整的应用路由，注入共享状态
pub fn create_router(state: Arc<AppState>) -> Router {
    Router::new()
        .nest("/api", api_routes())
        // MCP API（顶层路径，不在 /api 前缀下）
        .route("/mcp/tools", get(handlers::mcp::get_tools))
        .route("/mcp/call", post(handlers::mcp::call_tool))
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
        .route(
            "/sources/check-batch",
            post(handlers::source_check::check_batch),
        )
        .route("/sources/repos", get(handlers::source_update::list_repos))
        .route(
            "/sources/updates",
            get(handlers::source_update::check_updates),
        )
        .route(
            "/sources/update",
            post(handlers::source_update::execute_update),
        )
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
            delete(handlers::cache::delete_book_cache),
        )
        // 下载管理
        .route("/download/add", post(handlers::download::add_download))
        .route("/download/pause", post(handlers::download::pause_downloads))
        .route(
            "/download/resume",
            post(handlers::download::resume_downloads),
        )
        .route("/download/status", get(handlers::download::download_status))
        .route(
            "/download/{id}",
            delete(handlers::download::remove_download),
        )
        // 段评/本章热评
        .route(
            "/reviews/{book_url}/{chapter}",
            get(handlers::review::get_reviews),
        )
        .route("/reviews", post(handlers::review::create_review))
        // Debug API
        .route("/debug/start", post(handlers::debug::start_debug))
        .route(
            "/debug/log/{session_id}",
            get(handlers::debug::get_debug_log),
        )
        .route("/debug/sessions", get(handlers::debug::list_sessions))
        .route("/debug/step", post(handlers::debug::add_step))
        .route("/debug/complete", post(handlers::debug::complete_session))
        // Read Aloud API
        .route(
            "/read-aloud/start",
            post(handlers::read_aloud_handler::start),
        )
        .route(
            "/read-aloud/pause",
            post(handlers::read_aloud_handler::pause),
        )
        .route(
            "/read-aloud/resume",
            post(handlers::read_aloud_handler::resume),
        )
        .route("/read-aloud/stop", post(handlers::read_aloud_handler::stop))
        .route(
            "/read-aloud/status",
            get(handlers::read_aloud_handler::status),
        )
        .route("/read-aloud/next", post(handlers::read_aloud_handler::next))
        .route("/read-aloud/seek", post(handlers::read_aloud_handler::seek))
        // Rule Update API
        .route("/rule-update/subs", get(handlers::rule_update::list_subs))
        .route(
            "/rule-update/check",
            post(handlers::rule_update::check_update),
        )
        .route(
            "/rule-update/apply",
            post(handlers::rule_update::apply_update),
        )
        // TOC Update API
        .route(
            "/bookshelf/update-toc",
            post(handlers::toc_update::start_toc_update),
        )
        .route(
            "/bookshelf/update-toc/progress",
            get(handlers::toc_update::get_toc_update_progress),
        )
        .route(
            "/bookshelf/update-toc/stop",
            post(handlers::toc_update::stop_toc_update),
        )
        // Auto Task API
        .route(
            "/auto-tasks",
            get(handlers::auto_task_handler::list_tasks)
                .post(handlers::auto_task_handler::create_task),
        )
        .route(
            "/auto-tasks/{id}",
            put(handlers::auto_task_handler::update_task)
                .delete(handlers::auto_task_handler::delete_task),
        )
        .route(
            "/auto-tasks/{id}/run",
            post(handlers::auto_task_handler::run_task),
        )
        .route(
            "/auto-tasks/import",
            post(handlers::auto_task_handler::import_tasks),
        )
        .route(
            "/auto-tasks/export",
            get(handlers::auto_task_handler::export_tasks),
        )
        // WebSocket 实时通道
        .route("/ws/search", get(ws::search_ws::ws_search))
        .route(
            "/ws/debug/book-source",
            get(ws::debug_ws::ws_debug_book_source),
        )
        .route(
            "/ws/debug/rss-source",
            get(ws::debug_ws::ws_debug_rss_source),
        )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::AppState;
    use axum::body::Body;
    use axum::http::Request;
    use axum::http::StatusCode;
    use legado_core::download_manager::DownloadManager;
    use tokio::sync::Mutex;
    use tower::ServiceExt;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: Mutex::new(DownloadManager::new(3)),
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
