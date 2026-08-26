//! JS 单文件书源配置 FFI 层
//!
//! 对齐 Kotlin `JsSourceConfig.kt`，暴露三项能力：
//! - [`js_source_extract`]：执行 JS 书源脚本并提取顶层 config/source 配置，
//!   返回 BookSource JSON（需 quickjs 构建，否则返回错误）
//! - [`js_source_syntax_check`]：JS 语法检查（#479），返回 SyntaxCheckResult JSON
//! - [`js_source_stamp_last_update_time`]：写回顶层配置对象的 lastUpdateTime
//!   （#208/#515），无可替换位置时返回空字符串

use legado_core::LegadoResult;

/// 提取 JS 单文件书源配置，返回 BookSource JSON
///
/// `content` — 完整 JS 书源脚本文本
pub fn js_source_extract(content: &str) -> LegadoResult<String> {
    let source = legado_js::js_source::js_source_config::extract(content)?;
    serde_json::to_string(&source).map_err(|e| {
        legado_core::LegadoError::JsEngine(format!("BookSource 序列化失败: {e}"))
    })
}

/// JS 语法检查，返回 SyntaxCheckResult JSON（valid/message/line）
///
/// `content` — 待检查的 JS 脚本文本
pub fn js_source_syntax_check(content: &str) -> LegadoResult<String> {
    let result = legado_js::js_source::js_source_config::syntax_check(content);
    serde_json::to_string(&result).map_err(|e| {
        legado_core::LegadoError::JsEngine(format!("语法检查结果序列化失败: {e}"))
    })
}

/// 写回顶层配置对象的 lastUpdateTime，返回替换后的脚本文本
///
/// `content` — JS 书源脚本文本；`stamp` — 新时间戳（毫秒）
/// 找不到可替换位置时返回空字符串（对齐 Kotlin 返回 null 的语义）
pub fn js_source_stamp_last_update_time(content: &str, stamp: i64) -> LegadoResult<String> {
    Ok(legado_js::js_source::js_source_config::stamp_last_update_time(content, stamp)
        .unwrap_or_default())
}
