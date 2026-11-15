//! 宿主 API 注册框架
//!
//! 将所有宿主 API 按功能分类注册到 JS 上下文中，
//! 参考 Kotlin 端 `JsExtensions` 接口的方法分组。

#[cfg(feature = "quickjs")]
pub mod archive_utils;
#[cfg(feature = "quickjs")]
pub mod asymmetric_crypto;
pub mod cache_store;
/// 能力受限台账：未知 Java 符号 + jsLib 加载失败登记（队列④，无 feature 门控）
pub mod capability_ledger;
pub mod chinese_utils;
/// 宿主 API 入参的 Rhino LiveConnect 宽松转换（`RhinoStr` / `RhinoOptStr`）
#[cfg(feature = "quickjs")]
pub mod coerce;
pub mod concurrency_api;
pub mod config_api;
pub mod cookie_store;
pub mod crypto_api;
pub mod current_source;
pub mod device_id;
pub mod encoding;
pub mod env;
pub mod file_utils;
pub mod font_api;
/// archive / font 本地路径访问策略（`allow_file_access=false` 时仅允许
/// 引擎自建临时/缓存目录，见模块文档）
pub mod fs_policy;
pub mod global_headers;
pub mod html_format;
#[cfg(feature = "quickjs")]
pub mod html_parse;
/// 远程 jsLib 加载器（cap 3：URL 映射 jsLib 经共享客户端拉取 + 进程缓存
/// + 台账降级；随 quickjs feature 门控——依赖网络/引擎宿主面）
#[cfg(feature = "quickjs")]
pub mod jslib_loader;
pub mod json_utils;
/// java.security.MessageDigest 摘要核心（MD5/SHA-1/SHA-256/SHA-512，复用
/// md-5/sha1/sha2 既有依赖；随 quickjs feature 门控）
#[cfg(feature = "quickjs")]
pub mod message_digest;
pub mod misc_api;
#[cfg(feature = "quickjs")]
pub mod network;
pub mod platform;
pub mod pre_update_hooks;
pub mod query_ttf;
pub mod regex_utils;
#[cfg(feature = "quickjs")]
pub mod runtime_bridge;
pub mod source_callback;
pub mod string_utils;
#[cfg(feature = "quickjs")]
pub mod symmetric_crypto;
pub mod time_utils;
pub mod ui_action_queue;
pub mod variable_store;

#[cfg(feature = "quickjs")]
pub mod quickjs_impl;

#[cfg(feature = "quickjs")]
pub mod register;

pub use env::HostEnv;

/// 单文件读写/下载/字体解析的字节上限（32MB）
///
/// 与 `file_utils` 的单文件读取/下载上限、`archive_utils` 的单条目上限
/// 同口径。字体 API 的三条输入路径（URL 下载、本地文件读取、Base64 解码）
/// 与 `QueryTtf::parse` 共用该上限：`queryTTF(url)` 的响应体先经
/// `legado-net::get_bytes_capped` 有界下载，超限不落盘；缓存命中与本地字体
/// 文件按元数据 + 有界读取复核；Base64 在解码前按编码长度预估拒绝。字体
/// 缓存为跨源共享且书源不可删，若无上限，任意书源可用不同 URL 把任意大小
/// 响应永久写进共享缓存。
pub(crate) const MAX_FILE_BYTES: u64 = 32 * 1024 * 1024;

/// 将所有宿主 API 注册到 QuickJS 全局上下文
///
/// 转发至 `quickjs_impl::register_all_apis`。上游同名文件 API 始终注册
/// （P1-1），路径按沙箱配置派生的 `fs_policy` 限域；我方扩展
/// `writeFile`/`fileExists` 等仍按 `allow_file_access` 门控。
#[cfg(feature = "quickjs")]
pub fn register_all(
    ctx: &rquickjs::Ctx<'_>,
    config: &crate::sandbox::SandboxConfig,
) -> Result<(), legado_core::LegadoError> {
    quickjs_impl::register_all_apis(ctx, config)
}
