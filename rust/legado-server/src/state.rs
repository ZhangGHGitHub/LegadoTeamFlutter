//! 共享应用状态

use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use tokio::sync::Mutex;

use legado_core::download_manager::DownloadManager;
use legado_db::Database;

/// 宿主注入的本地文件系统路径（B3，ACTIVE_PLAN「FFI 图片缓存根注入白名单」登记项）
///
/// 背景：`legado-ffi` 持有图片磁盘缓存根（`image_cache_api::cache_root`，Dart 经
/// `set_image_cache_dir` 注入）与本地书存储目录等运行时路径；依赖方向为
/// `legado-ffi → legado-server`，server 不可反向引用 FFI 全局（见
/// `legacy/book_api.rs` `local_read_allowlist` 文档注释的原始登记），故由
/// FFI 在构造 Web 服务时经 [`crate::server::serve_web_with_injected_paths`]
/// 注入本结构。
///
/// 未注入（`None`）时的行为与原版「未配置对应目录」状态一致：
/// - `image_cache_root` 为 `None`：`/cover`、`/image` 本地白名单仅含书库登记
///   目录（与既有行为相同）；
/// - `local_book_root` 为 `None`：`/addLocalBook` 报「保存书籍错误\n没有设置
///   书籍保存位置!」（对齐原版 `NoBooksDirException`，BookController.kt:320-328）。
#[derive(Debug, Clone, Default)]
pub struct InjectedPaths {
    /// 图片磁盘缓存根（`legado-ffi/src/api/image_cache_api.rs` 的缓存根目录，
    /// 目录结构 `{root}/{书目录}/images/{文件}`）：纳入 `/cover`、`/image`
    /// 本地图片读取白名单（目录前缀放行）。
    pub image_cache_root: Option<PathBuf>,
    /// 本地书保存根（原版 `AppConfig.defaultBookTreeUri` 的 Rust 侧对应物）：
    /// `/addLocalBook` 上传书籍文件的落盘根目录。
    pub local_book_root: Option<PathBuf>,
}

/// 全局共享状态，通过 `Arc<AppState>` 在 axum 路由间共享
pub struct AppState {
    /// 数据库实例（使用 Mutex 保护，因为 rusqlite::Connection 非 Sync）
    pub db: Mutex<Database>,
    /// 搜索取消标志（简化版，使用 AtomicBool）
    pub search_cancelled: Arc<AtomicBool>,
    /// 下载管理器
    pub download_manager: Mutex<DownloadManager>,
    /// 宿主注入的本地路径（图片缓存根 / 本地书保存根；未注入为空）
    pub injected_paths: InjectedPaths,
    /// 段评 legacy 共享状态（B4：详情分页游标 64 槽 + legacy 会话 16 槽；
    /// 对齐原版 ReviewController 的两个 LruCache 成员，进程内有效）
    pub legacy_review: std::sync::Mutex<crate::legacy::review_api::LegacyReviewShared>,
}

/// 状态类型别名，方便在 handler 签名中使用
pub type SharedState = Arc<AppState>;
