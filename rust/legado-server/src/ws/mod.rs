//! WebSocket 实时通道模块
//!
//! 两类通道并存、互不影响：
//!
//! 1. **自研通道**（主服务同端口，`/api/ws/*`）：搜索进度推送与
//!    书源/RSS 源调试日志流（[`search_ws`]、[`book_source_debug`]、
//!    [`rss_source_debug`]、[`debug_ws`]），既有消费者按原路径继续可用。
//! 2. **原版通道**（独立监听 `主服务端口 + 1`，原版路径）：[`original`]
//!    实现 upstream `WebSocketServer` 的 `/bookSourceDebug`、
//!    `/rssSourceDebug` 协议（子协议令牌鉴权、10s 认证窗口、30s 心跳、
//!    原版关闭码），供原版 vue 调试页直连；生命周期由
//!    [`crate::server::serve_web_with_injected_paths`] 与主服务同启停。

pub mod book_source_debug;
pub mod debug_ws;
pub mod original;
pub mod rss_source_debug;
pub mod search_ws;
