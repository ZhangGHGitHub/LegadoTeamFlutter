//! legado-server: 本地 HTTP 服务（基于 axum + tokio）
//!
//! 提供 REST API 端点：书架管理、章节阅读、书源管理、搜索等。

pub mod error;
pub mod handlers;
pub mod routes;
pub mod server;
pub mod state;
