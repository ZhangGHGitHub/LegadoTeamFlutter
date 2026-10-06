//! 路由组装

use axum::http::header;
use axum::response::IntoResponse;
use axum::routing::{delete, get, post, put};
use axum::Router;
use std::sync::Arc;
use tower_http::services::ServeDir;

use crate::handlers;
use crate::state::AppState;
use crate::ws;

/// Web UI 首页内容（编译期嵌入）
///
/// 为何编译期嵌入：设备（Android/iOS）运行时没有仓库工作目录保证，`web-dist`
/// 这类相对路径资源目录在设备上并不存在 —— `GET /` 落到 [`ServeDir`] fallback
/// 只能得到 404（浏览器打开 Web 服务页面失败）。改用 `include_str!` 把首页 HTML
/// 打进二进制后，任何工作目录下都能返回页面。
///
/// 与 fallback 的关系：本路由只覆盖首页 `/`；`ServeDir::new("web-dist")` 的
/// fallback 继续保留，本机开发时其它静态资源仍从磁盘读取（改完刷新即可，无需
/// 重编译）。显式路由优先于 fallback，故 `/` 恒定走嵌入内容（设备与开发机一致）。
///
/// 路径基准：`include_str!` 相对本文件（`src/routes.rs`），`../web-dist/index.html`
/// 即 crate 根下的 `web-dist/index.html`；文件缺失会在编译期报错，而非运行时 404。
const INDEX_HTML: &str = include_str!("../web-dist/index.html");

/// `GET /` — 返回编译期嵌入的书架页面
///
/// `Content-Type` 显式带 `charset=utf-8`，与页面 `<meta charset="UTF-8">` 对齐
/// （磁盘 fallback 的 mime_guess 只给 `text/html`，中文可能被浏览器按错误编码解码）。
async fn web_index() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        INDEX_HTML,
    )
}

/// 创建完整的应用路由，注入共享状态
pub fn create_router(state: Arc<AppState>) -> Router {
    Router::new()
        .nest("/api", api_routes())
        // MCP API（顶层路径，不在 /api 前缀下）
        .route("/mcp/tools", get(handlers::mcp::get_tools))
        .route("/mcp/call", post(handlers::mcp::call_tool))
        // Web UI 首页（编译期嵌入；显式路由优先于下方 fallback）
        //
        // 不挂 SPA 通配回退：页面无 history API / hash 前端路由（视图切换纯内存），
        // 未知非 API 路径保持 404 语义即可，无需把 index 回给任意路径。
        .route("/", get(web_index))
        // 静态文件服务 — 开发机上的其它 Web 前端资源（fallback 处理非 API 请求）
        //
        // 目录不存在无噪音日志：tower-http 0.6 的 ServeDir 把 io::NotFound 直接映射为
        // 404 响应（services/fs/serve_dir/mod.rs 文档与 try_call），唯一的 tracing::error!
        // 在 `#[cfg(feature = "tracing")]` 下；本 crate 只启用 tower-http 的
        // ["cors", "fs"]，未启用该 feature，故设备侧不会刷日志。保留原样即可。
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
        .route("/search/cancel", post(handlers::search::cancel_search))
        // WebBook 书源规则驱动链路
        .route("/webbook/search", post(handlers::web_book::search_books))
        .route("/webbook/info", post(handlers::web_book::get_book_info))
        .route("/webbook/chapters", post(handlers::web_book::get_chapters))
        .route("/webbook/content", post(handlers::web_book::get_content))
        // TTS 文本转语音
        .route("/tts/speak", post(handlers::tts::speak))
        .route("/tts/engines", get(handlers::tts::list_engines))
        .route("/tts/synthesize", post(handlers::tts::synthesize_by_id))
        // 听书音频播放
        .route("/audio/chapters", post(handlers::audio::get_chapters))
        .route("/audio/speak", post(handlers::audio::speak))
        .route("/audio/play", post(handlers::audio::play_control))
        .route(
            "/audio/chapter-media",
            post(handlers::audio::get_chapter_media),
        )
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
            "/bookshelf/update-toc/single",
            post(handlers::toc_update::update_single_toc),
        )
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
            get(ws::book_source_debug::ws_book_source_debug),
        )
        .route(
            "/ws/debug/rss-source",
            get(ws::rss_source_debug::ws_rss_source_debug),
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

    /// Web UI 首页必须由编译期嵌入的 HTML 提供（设备端无 web-dist 目录也能访问）
    ///
    /// 断言三件事：HTTP 200；`Content-Type` 为 `text/html; charset=utf-8`
    /// （对齐页面 `<meta charset="UTF-8">`；磁盘 fallback 的 mime_guess 只给
    /// `text/html`，不带 charset）；正文含页面标记 `<title>Legado`。
    #[tokio::test]
    async fn test_index_route_serves_embedded_html() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(Request::builder().uri("/").body(Body::empty()).unwrap())
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let content_type = resp
            .headers()
            .get(axum::http::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or_default()
            .to_string();
        assert_eq!(
            content_type, "text/html; charset=utf-8",
            "首页 Content-Type 应为 text/html; charset=utf-8"
        );

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let html = String::from_utf8(body.to_vec()).unwrap();
        assert!(
            html.contains("<title>Legado"),
            "首页正文应含页面标记 <title>Legado"
        );
    }

    /// 未知非 API 路径仍返回 404（页面无 history/hash 前端路由，故不挂 SPA 通配回退）
    #[tokio::test]
    async fn test_unknown_non_api_path_404() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/no-such-page")
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
