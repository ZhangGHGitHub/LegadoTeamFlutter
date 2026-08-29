//! HTTP 服务启动逻辑

use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::Request;
use axum::http::{header::HeaderName, StatusCode};
use axum::middleware::{from_fn, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::sync::Mutex;

use crate::handlers;
use crate::routes::create_router;
use crate::state::AppState;
use legado_core::download_manager::DownloadManager;

/// 对齐原版 `McpAccess.TOKEN_HEADER`
const MCP_TOKEN_HEADER: &str = "x-legado-token";

/// 服务器配置
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub db_path: String,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 8080,
            db_path: "legado.db".to_string(),
        }
    }
}

/// 启动 HTTP 服务器
pub async fn start_server(config: ServerConfig) -> Result<(), Box<dyn std::error::Error>> {
    // 初始化数据库（含 schema 迁移）
    let db = legado_db::init_database(&config.db_path)?;
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
    });

    let router = create_router(state);

    let addr = format!("{}:{}", config.host, config.port).parse::<SocketAddr>()?;
    tracing::info!("Legado server listening on {}", addr);

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, router).await?;

    Ok(())
}

/// 独立 MCP 服务专用路由（Task #73/76 + F5，契约 §2.22.5）
///
/// 暴露面收敛：仅挂载 MCP 端点 `/mcp/tools`（GET）/ `/mcp/call`（POST）
/// 与健康检查 `/health`，**不复用** [`create_router`] 全量路由。
/// F5：`/mcp/*` 经 `X-Legado-Token` 鉴权（对齐原版）；`/health` 免鉴权便于探测。
fn create_mcp_router(state: Arc<AppState>, expected_token: Arc<String>) -> Router {
    let token_for_layer = Arc::clone(&expected_token);
    Router::new()
        .route("/mcp/tools", get(handlers::mcp::get_tools))
        .route("/mcp/call", post(handlers::mcp::call_tool))
        .route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "ok"})) }),
        )
        .layer(from_fn(move |req: Request<Body>, next: Next| {
            let token = Arc::clone(&token_for_layer);
            async move {
                // /health 免鉴权（探测）；/mcp/* 要求 X-Legado-Token
                if req.uri().path() == "/health" {
                    return next.run(req).await;
                }
                mcp_token_middleware(token, req, next).await
            }
        }))
        .with_state(state)
}

async fn mcp_token_middleware(
    expected: Arc<String>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let header_name = HeaderName::from_static(MCP_TOKEN_HEADER);
    let actual = request
        .headers()
        .get(&header_name)
        .and_then(|v| v.to_str().ok());
    if !matches_js_source_api_token(expected.as_str(), actual) {
        return (StatusCode::UNAUTHORIZED, "MCP token invalid or missing").into_response();
    }
    next.run(request).await
}

/// 对齐原版 `BookSourceController.matchesJsSourceApiToken`（字节级相等）
fn matches_js_source_api_token(expected: &str, actual: Option<&str>) -> bool {
    if expected.is_empty() {
        return false;
    }
    match actual {
        Some(a) => a.as_bytes() == expected.as_bytes(),
        None => false,
    }
}

/// 启动独立 MCP 服务（Task #73 / F5，契约 §2.22.5 `setMcpPort`）
///
/// 对齐原版 `McpService.kt`：调用方绑定 **0.0.0.0**；`expected_token` 非空
/// （由 `jsSourceApiToken` 注入）；`/mcp/*` 校验 `X-Legado-Token`。
pub async fn serve_mcp(
    listener: tokio::net::TcpListener,
    db: legado_db::Database,
    expected_token: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
    });

    let router = create_mcp_router(state, Arc::new(expected_token));

    let addr = listener.local_addr()?;
    tracing::info!("Legado standalone MCP service listening on {}", addr);

    axum::serve(listener, router).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_matches_js_source_api_token() {
        assert!(!matches_js_source_api_token("", Some("x")));
        assert!(!matches_js_source_api_token("secret", None));
        assert!(!matches_js_source_api_token("secret", Some("wrong")));
        assert!(matches_js_source_api_token("secret", Some("secret")));
    }

    #[test]
    fn test_default_config() {
        let config = ServerConfig::default();
        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.port, 8080);
        assert_eq!(config.db_path, "legado.db");
    }

    #[test]
    fn test_config_custom() {
        let config = ServerConfig {
            host: "0.0.0.0".to_string(),
            port: 3000,
            db_path: "/tmp/test.db".to_string(),
        };
        assert_eq!(config.host, "0.0.0.0");
        assert_eq!(config.port, 3000);
    }

    #[tokio::test]
    async fn test_server_bind_and_serve() {
        // 启动服务器后立刻关闭，验证绑定和路由构建无误
        let db = legado_db::init_in_memory_database().unwrap();
        let state = Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: Mutex::new(DownloadManager::new(3)),
        });
        let router = create_router(state);

        // 绑定到随机可用端口
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        // 异步启动，然后立刻 drop 取消任务
        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });

        // 验证能建立连接
        let _ = tokio::net::TcpStream::connect(addr).await.unwrap();

        handle.abort();
    }
}
