//! legado-server: 本地 HTTP 服务（基于 axum + tokio）
//!
//! 提供完整的 REST API 服务，包括：
//!
//! - [`server`] — 服务器启动与生命周期管理
//! - [`routes`] — 路由注册（53+ REST 端点 + 5 WS 端点）
//! - [`handlers`] — 请求处理器（书架/章节/书源/搜索/下载/任务等）
//! - [`ws`] — WebSocket 实时通道（搜索进度/调试日志）
//! - [`state`] — 共享应用状态（数据库/配置）
//! - [`error`] — HTTP 错误响应映射
//!
//! # 主要端点
//!
//! | 方法 | 路径 | 功能 |
//! |------|------|------|
//! | GET | `/api/books` | 获取书架列表 |
//! | GET | `/api/chapters` | 获取章节列表 |
//! | GET | `/api/content` | 获取章节正文 |
//! | POST | `/api/search` | 多源搜索 |
//! | GET | `/api/sources` | 获取书源列表 |
//! | WS | `/ws/search` | 搜索进度推送 |
//!
//! # Examples
//!
//! ```rust,ignore
//! use legado_server::server::Server;
//!
//! #[tokio::main]
//! async fn main() {
//!     let server = Server::new("127.0.0.1:9527", "legado.db");
//!     server.run().await.unwrap();
//! }
//! ```

pub mod error;
pub mod handlers;
pub mod login_check;
pub mod routes;
pub mod server;
pub mod state;
pub mod ws;
