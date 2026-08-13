//! 书源事件回调 FFI（对齐 Kotlin `SourceCallBack.callBackBtn`）
//!
//! 详情页/听书/阅读菜单自定义按钮等入口：执行 `contentRule.callBackJs`，
//! 注入 `event` / `book` / `chapter` / `result` / `java`（含 SourceLoginJsExtensions
//! 中途 UI）。无头引擎无法同步弹 Activity，经 `ui_action_queue` 收集副作用，
//! 由 Flutter `PlatformBridgeService` 回放。

use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};
use serde::Serialize;

use crate::db_state::with_database;

/// callBackBtn 执行结果（camelCase）
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceCallBackBtnResult {
    /// 是否实际执行了 callBackJs（false 时 UI 应走 noCall 默认行为）
    pub invoked: bool,
    /// JS 返回值经 Kotlin `String?.isTrue()` 判定后是否为真
    /// （为假时 UI 同样应执行 noCall）
    pub js_true: bool,
    /// JS 返回原文
    pub raw: String,
    /// 中途 UI 副作用队列（openBrowser / refreshBookInfo / copyText …）
    pub actions: Vec<serde_json::Value>,
}

/// 对齐 Kotlin `String?.isTrue(nullIsTrue = false)`
fn is_js_true(raw: &str) -> bool {
    let t = raw.trim();
    if t.is_empty() || t.eq_ignore_ascii_case("null") {
        return false;
    }
    !regex_is_falsey(t)
}

fn regex_is_falsey(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    matches!(lower.as_str(), "false" | "no" | "not" | "0" | "0.0")
}

/// 执行书源 callBackBtn（对齐 `SourceCallBack.callBackBtn`）
///
/// - `event`：如 `clickCustomButton`
/// - `book_url`：书籍 URL
/// - `chapter_index`：可选章节索引（详情页传 null）
/// - `result`：可选附加结果（分享串等）
/// - `book_type`：对齐 SourceLoginJsExtensions 构造参数（保留字段，当前宿主未分流）
pub fn source_call_back_btn(
    event: &str,
    book_url: &str,
    chapter_index: Option<i32>,
    result: Option<&str>,
    _book_type: i32,
) -> LegadoResult<SourceCallBackBtnResult> {
    let book = with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))?
        .ok_or_else(|| LegadoError::Database(format!("书籍不存在: {book_url}")))?;

    let source = with_database(|db| {
        BookSourceRepository::new(db.connection()).find_by_url(&book.origin)
    })?;

    let Some(source) = source else {
        return Ok(SourceCallBackBtnResult {
            invoked: false,
            js_true: false,
            raw: String::new(),
            actions: vec![],
        });
    };

    if !source.event_listener {
        return Ok(SourceCallBackBtnResult {
            invoked: false,
            js_true: false,
            raw: String::new(),
            actions: vec![],
        });
    }

    let js_str = source
        .rule_content
        .as_ref()
        .and_then(|r| r.call_back_js.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty());

    let Some(js_str) = js_str else {
        return Ok(SourceCallBackBtnResult {
            invoked: false,
            js_true: false,
            raw: String::new(),
            actions: vec![],
        });
    };

    let chapter = match chapter_index {
        Some(idx) => with_database(|db| {
            BookChapterRepository::new(db.connection())
                .find_by_book_url_and_index(book_url, idx)
        })?,
        None => None,
    };

    let raw = eval_call_back_js(&source, &book, chapter.as_ref(), event, result, js_str)?;
    let actions = {
        #[cfg(feature = "quickjs")]
        {
            legado_js::host_api::ui_action_queue::end_collect()
        }
        #[cfg(not(feature = "quickjs"))]
        {
            Vec::new()
        }
    };

    Ok(SourceCallBackBtnResult {
        invoked: true,
        js_true: is_js_true(&raw),
        raw,
        actions,
    })
}

#[cfg(feature = "quickjs")]
fn eval_call_back_js(
    source: &legado_core::models::BookSource,
    book: &legado_core::models::Book,
    chapter: Option<&legado_core::models::BookChapter>,
    event: &str,
    result: Option<&str>,
    js_str: &str,
) -> LegadoResult<String> {
    use legado_js::{JsEngine, JsValue};

    legado_js::host_api::ui_action_queue::begin_collect();
    let engine = crate::js_executor::fresh_engine(&source.book_source_url).map_err(|e| {
        legado_js::host_api::ui_action_queue::discard_collect();
        e
    })?;
    let guard = engine.lock().map_err(|e| {
        legado_js::host_api::ui_action_queue::discard_collect();
        LegadoError::JsEngine(format!("JS 引擎加锁失败: {e}"))
    })?;

    let book_value: serde_json::Value = serde_json::to_value(book)?;
    let chapter_value = match chapter {
        Some(ch) => serde_json::to_value(ch)?,
        None => serde_json::Value::Null,
    };
    let result_value = match result {
        Some(r) => JsValue::String(r.to_string()),
        None => JsValue::Null,
    };

    let bindings: Vec<(&str, JsValue)> = vec![
        ("event", JsValue::String(event.to_string())),
        ("book", json_to_js_value(book_value)),
        ("chapter", json_to_js_value(chapter_value)),
        ("result", result_value),
    ];

    match guard.eval_with_bindings(js_str, &bindings) {
        Ok(raw) => Ok(raw),
        Err(e) => {
            legado_js::host_api::ui_action_queue::discard_collect();
            Err(e.into())
        }
    }
}

#[cfg(feature = "quickjs")]
fn json_to_js_value(value: serde_json::Value) -> legado_js::JsValue {
    use legado_js::JsValue;
    match value {
        serde_json::Value::Null => JsValue::Null,
        serde_json::Value::Bool(b) => JsValue::Bool(b),
        serde_json::Value::Number(n) => match n.as_i64() {
            Some(i) => JsValue::Int(i),
            None => JsValue::Number(n.as_f64().unwrap_or(0.0)),
        },
        serde_json::Value::String(s) => JsValue::String(s),
        serde_json::Value::Array(items) => {
            JsValue::Array(items.into_iter().map(json_to_js_value).collect())
        }
        serde_json::Value::Object(map) => JsValue::Object(
            map.into_iter()
                .map(|(k, v)| (k, json_to_js_value(v)))
                .collect(),
        ),
    }
}

#[cfg(not(feature = "quickjs"))]
fn eval_call_back_js(
    _source: &legado_core::models::BookSource,
    _book: &legado_core::models::Book,
    _chapter: Option<&legado_core::models::BookChapter>,
    _event: &str,
    _result: Option<&str>,
    _js_str: &str,
) -> LegadoResult<String> {
    Err(LegadoError::JsEngine(
        "QuickJS engine not enabled. Build with --features quickjs".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_js_true_aligns_kotlin() {
        assert!(!is_js_true(""));
        assert!(!is_js_true("null"));
        assert!(!is_js_true("false"));
        assert!(!is_js_true("0"));
        assert!(is_js_true("true"));
        assert!(is_js_true("yes"));
        assert!(is_js_true("1"));
    }

    /// F3：无书时 callBackBtn 应报错（副作用队列不泄漏）
    #[test]
    fn call_back_btn_missing_book_errors() {
        let err = source_call_back_btn("clickCustomButton", "missing://book", None, None, 0);
        assert!(err.is_err());
    }
}
