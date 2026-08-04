//! JS 源完整生命周期子模块
//!
//! 移植自 Kotlin `model/jsSource/` 目录：
//! - **js_source_book** — 搜索/发现/书籍信息/目录/正文
//! - **js_source_marshaller** — JSON 序列化/反序列化
//! - **js_source_upsert** — 保存验证/冲突检测
//! - **js_source_review** — 书评摘要/详情
//! - **js_source_debug_formatter** — 调试日志格式化
//! - **js_source_config** — 配置提取/时间写回/语法检查

pub mod js_source_book;
pub mod js_source_config;
pub mod js_source_debug_formatter;
pub mod js_source_marshaller;
pub mod js_source_review;
pub mod js_source_upsert;
