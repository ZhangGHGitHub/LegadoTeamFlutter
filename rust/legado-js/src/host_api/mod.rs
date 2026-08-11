//! 宿主 API 注册框架
//!
//! 将所有宿主 API 按功能分类注册到 JS 上下文中，
//! 参考 Kotlin 端 `JsExtensions` 接口的方法分组。

#[cfg(feature = "quickjs")]
pub mod archive_utils;
#[cfg(feature = "quickjs")]
pub mod asymmetric_crypto;
pub mod chinese_utils;
pub mod concurrency_api;
pub mod config_api;
pub mod cookie_store;
pub mod crypto_api;
pub mod current_source;
pub mod encoding;
pub mod env;
pub mod file_utils;
pub mod font_api;
pub mod html_format;
#[cfg(feature = "quickjs")]
pub mod html_parse;
pub mod json_utils;
pub mod misc_api;
#[cfg(feature = "quickjs")]
pub mod network;
pub mod platform;
pub mod query_ttf;
pub mod regex_utils;
#[cfg(feature = "quickjs")]
pub mod runtime_bridge;
pub mod source_callback;
pub mod string_utils;
pub mod time_utils;
pub mod variable_store;

#[cfg(feature = "quickjs")]
pub mod quickjs_impl;

#[cfg(feature = "quickjs")]
pub mod register;

pub use env::HostEnv;

/// 将所有宿主 API 注册到 QuickJS 全局上下文
///
/// 转发至 `quickjs_impl::register_all_apis`，根据沙箱配置门控文件 API。
#[cfg(feature = "quickjs")]
pub fn register_all(
    ctx: &rquickjs::Ctx<'_>,
    config: &crate::sandbox::SandboxConfig,
) -> Result<(), legado_core::LegadoError> {
    quickjs_impl::register_all_apis(ctx, config)
}
