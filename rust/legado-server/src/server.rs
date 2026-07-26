//! HTTP 服务启动逻辑

use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use tokio::sync::Mutex;

use crate::routes::create_router;
use crate::state::AppState;
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
