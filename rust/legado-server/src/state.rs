//! 共享应用状态

use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use tokio::sync::Mutex;

use legado_db::Database;

/// 全局共享状态，通过 `Arc<AppState>` 在 axum 路由间共享
pub struct AppState {
    /// 数据库实例（使用 Mutex 保护，因为 rusqlite::Connection 非 Sync）
    pub db: Mutex<Database>,
    /// 搜索取消标志（简化版，使用 AtomicBool）
    pub search_cancelled: Arc<AtomicBool>,
}

/// 状态类型别名，方便在 handler 签名中使用
pub type SharedState = Arc<AppState>;
