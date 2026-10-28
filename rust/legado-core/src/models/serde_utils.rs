//! 宽松反序列化辅助（第三方书源/旧备份 JSON 兼容）
//!
//! 原版 Legado 使用 Gson：数字字段容忍数字字符串（`"20"`）、布尔字段容忍
//! 0/1 与 `"true"`/`"false"`。serde 默认严格模式会直接报错；由于
//! `import_sources` / `import_rss_sources` 对整数组一次解析，单条字段类型
//! 不标准会击穿整批导入（批28 新增字段后暴露的失败模式，批28b 回修）。
//!
//! 本模块把 `book_source.rs` 内的既有先例（`lenient_i32` / `lenient_bool`）
//! 抽为共享实现，供 `ContentRule` / `RssSource` 复用，避免逐字段复制逻辑。
//!
//! 编写：全栈工程师（批28b） ｜ 2026-10-28

use serde::de::Error;
use serde::{Deserialize, Deserializer};

/// 宽松反序列化：兼容 JSON 数字与数字字符串（i64）
pub(crate) fn lenient_i64<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Number(n) => n
            .as_i64()
            .ok_or_else(|| D::Error::custom("数字超出 i64 范围")),
        serde_json::Value::String(s) => s
            .trim()
            .parse::<i64>()
            .map_err(|_| D::Error::custom(format!("无法解析数字: {s}"))),
        _ => Err(D::Error::custom("期望数字或数字字符串")),
    }
}

/// 宽松反序列化：兼容 JSON 数字与数字字符串（i32）
pub(crate) fn lenient_i32<'de, D: Deserializer<'de>>(d: D) -> Result<i32, D::Error> {
    let v = lenient_i64(d)?;
    i32::try_from(v).map_err(|_| D::Error::custom("数字超出 i32 范围"))
}

/// 宽松反序列化：兼容 bool、0/1 数字与 "true"/"false" 字符串
pub(crate) fn lenient_bool<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    lenient_bool_value(&v)
}

/// `Option<bool>` 版本：字段缺省时为 None，显式 null → None
pub(crate) fn lenient_opt_bool<'de, D: Deserializer<'de>>(d: D) -> Result<Option<bool>, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Null => Ok(None),
        other => lenient_bool_value(other).map(Some),
    }
}

/// 宽松反序列化：兼容 null / 数字 / 数字字符串（`Option<i32>`）
///
/// 语义：
/// - 缺键 → 由 serde `default` 给 `None`；
/// - 显式 null → `None`（原版 `Int?` 可空语义）；
/// - 数字 / 数字字符串 → `Some(i32)`（Gson 容忍 `"20"`，批28b 回归）。
pub(crate) fn lenient_opt_i32<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i32>, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    match &v {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::Number(n) => n
            .as_i64()
            .ok_or_else(|| D::Error::custom("数字超出 i64 范围"))
            .and_then(|v| i32::try_from(v).map_err(|_| D::Error::custom("数字超出 i32 范围")))
            .map(Some),
        serde_json::Value::String(s) => s
            .trim()
            .parse::<i32>()
            .map(Some)
            .map_err(|_| D::Error::custom(format!("无法解析数字: {s}"))),
        _ => Err(D::Error::custom("期望数字或数字字符串")),
    }
}

/// bool 宽松解析，口径与 [`lenient_bool`] 一致（供 null 特殊语义复用）
fn lenient_bool_value<E: serde::de::Error>(v: &serde_json::Value) -> Result<bool, E> {
    match v {
        serde_json::Value::Bool(b) => Ok(*b),
        serde_json::Value::Number(n) => Ok(n.as_i64() != Some(0)),
        serde_json::Value::String(s) => match s.trim() {
            "true" | "1" => Ok(true),
            "false" | "0" | "" => Ok(false),
            other => Err(E::custom(format!("无法解析布尔值: {other}"))),
        },
        _ => Err(E::custom("期望布尔值")),
    }
}

/// 宽松 bool，显式 null 视为 `true`
///
/// 用于缺键默认 `true` 的原版布尔字段（如 `RssSource.enableReadRecord`）。
/// `serde(default = "default_true")` 只覆盖缺键；显式 `"enableReadRecord": null`
/// 若走严格 bool 会报错并击穿整批导入。这里按 Kotlin 构造默认值语义取 `true`。
///
/// 与 Gson 的差异（登记于 `docs/API_CONTRACT.md` §2.5）：Gson 对原始类型
/// `boolean` 的显式 null 会跳过赋值（保留字段初值 false）；本实现选择语义
/// 默认值 `true`，与「缺键 = true」保持一致，避免 null 造成开关反转。
pub(crate) fn lenient_bool_default_true<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    let v = serde_json::Value::deserialize(d)?;
    if v.is_null() {
        return Ok(true);
    }
    lenient_bool_value(&v)
}
