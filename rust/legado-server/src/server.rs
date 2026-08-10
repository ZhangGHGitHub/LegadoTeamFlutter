//! HTTP 服务启动逻辑

use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::sync::Mutex;

use crate::routes::create_router;
use crate::state::AppState;
use crate::handlers;
use legado_core::download_manager::DownloadManager;

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

/// 独立 MCP 服务专用路由（Task #73/76，契约 §2.22.5）
///
/// 暴露面收敛：仅挂载 MCP 端点 `/mcp/tools`（GET）/ `/mcp/call`（POST）
/// 与健康检查 `/health`，**不复用** [`create_router`] 全量路由（避免
/// 完整 /api 写路由暴露在独立端口上）；与 Web 端口共用同一套
/// MCP handlers 实现，零新增工具。
fn create_mcp_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/mcp/tools", get(handlers::mcp::get_tools))
        .route("/mcp/call", post(handlers::mcp::call_tool))
        .route("/health", get(|| async { Json(serde_json::json!({"status":"ok"})) }))
        .with_state(state)
}

/// 启动独立 MCP 服务（Task #73，契约 §2.22.5 `setMcpPort` 独立端口方案）
///
/// 对齐原版 `McpService.kt` 独立前台服务形态：与 Web 服务完全分离，
/// 在调用方已绑定的监听器上服务。仅挂载专用 MCP 路由
/// （[`create_mcp_router`]：`/mcp/tools` + `/mcp/call` + `/health`），
/// 与 Web 端口挂载的 MCP 端点能力等价，零新增工具。
///
/// 安全边界（Task #76）：监听器由调用方绑定到 **本机回环地址
/// 127.0.0.1**（对齐既有 server_start 安全边界）；局域网可达与
/// token 鉴权属后续契约批次（契约 L323 已声明不在冻结范围）。
///
/// 监听器由调用方预先绑定，便于同步获得端口占用等绑定失败错误；
/// 数据库由调用方预先初始化（Task #76：初始化失败同步报错，
/// 不进入服务任务），与主应用同一 DB 文件（WAL 并发安全）。
pub async fn serve_mcp(
    listener: tokio::net::TcpListener,
    db: legado_db::Database,
) -> Result<(), Box<dyn std::error::Error>> {
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
    });

    let router = create_mcp_router(state);

    let addr = listener.local_addr()?;
    tracing::info!("Legado standalone MCP service listening on {}", addr);

    axum::serve(listener, router).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
