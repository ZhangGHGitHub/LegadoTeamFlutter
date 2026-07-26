//! 宿主 API 注册框架
//!
//! 将所有宿主 API 按功能分类注册到 JS 上下文中，
//! 参考 Kotlin 端 `JsExtensions` 接口的方法分组。

pub mod chinese_utils;
pub mod cookie_store;
pub mod crypto_api;
pub mod encoding;
pub mod env;
pub mod file_utils;
pub mod html_format;
pub mod json_utils;
#[cfg(feature = "quickjs")]
pub mod network;
pub mod platform;
pub mod regex_utils;
#[cfg(feature = "quickjs")]
pub mod runtime_bridge;
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
/// 转发至 `quickjs_impl::register_all_apis`。
#[cfg(feature = "quickjs")]
pub fn register_all(ctx: &rquickjs::Ctx<'_>) -> Result<(), legado_core::LegadoError> {
    quickjs_impl::register_all_apis(ctx)
}
