//! 章节购买动作 FFI 层（Task #136 R6，API_CONTRACT §2.43.2）
//!
//! 对齐 Kotlin `ReadBookActivity.payAction`（app 模块 ui/book/read/ReadBookActivity.kt）语义：
//!
//! - 本地书（origin 为空/`loc_book` 或文件型 bookUrl）短路返回 `kind=none`（无购买概念）；
//! - 按书的 `origin` 取书源 `contentRule.payAction`，为空时报错 "no pay action"；
//! - `evalJS(payAction)` 注入绑定对齐 Kotlin：java（引擎全局命名空间）/
//!   book（Book JSON 对象）/ chapter（BookChapter JSON 对象）/ title（章节标题）/
//!   baseUrl = chapter.url / result = null / src = null；
//! - 结果判定：绝对 URL → `kind=url`（UI 打开支付页）；"true" → `kind=success`
//!   （清当前章正文缓存，对齐 Kotlin `BookHelp.delContent`；目录刷新由 UI 侧发起）；
//!   其他返回 → `kind=none`。
//!
//! 原版 payAction 亦支持「包含 `{{js}}` 的 url 模板」形态，语义依赖 Android WebView
//! 注入执行，此处不实现，仅按纯 JS 脚本执行并以注释标注（R6 留项）。
//!
//! 未启用 quickjs feature 时返回 `JsEngine` 错误（FFI 层转 BridgeError）。

use legado_core::models::book::book_type;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::book_chapter_repository::BookChapterRepository;
use legado_db::{BookRepository, BookSourceRepository, CacheBookRepository};

use crate::db_state::with_database;

/// 购买动作执行结果（camelCase 序列化）
#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PayActionResult {
    /// 结果类型：`url`（打开支付页）/ `success`（购买成功）/ `none`（无明确结果）
    pub kind: String,
    /// JS 返回原文（供 UI 展示/调试）
    pub value: String,
}

/// 执行章节购买动作（Task #136 R6）
///
/// `book_url` — 书的 bookUrl；`chapter_index` — 待购买章节索引。
pub fn chapter_pay_action(book_url: &str, chapter_index: i32) -> LegadoResult<PayActionResult> {
    // 1. 取书 + 本地书短路（对齐 Kotlin `if (book.isLocalBook()) return`）
    let book = with_database(|db| {
        BookRepository::new(db.connection()).find_by_url(book_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书籍不存在: {book_url}")))?;

    let is_local = book.origin.is_empty()
        || book.origin == book_type::LOCAL_TAG
        || crate::api::reader::is_local_book(book_url);
    if is_local {
        return Ok(PayActionResult {
            kind: "none".into(),
            value: String::new(),
        });
    }

    // 2. 取章节（baseUrl 绑定与缓存清理键）
    let chapter = with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, chapter_index)
    })?
    .ok_or_else(|| {
        LegadoError::Database(format!("章节 {chapter_index} 不存在: {book_url}"))
    })?;

    // 3. 取书源 payAction
    let source = with_database(|db| {
        BookSourceRepository::new(db.connection()).find_by_url(&book.origin)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {}", book.origin)))?;

    let pay_action = source
        .rule_content
        .as_ref()
        .and_then(|r| r.pay_action.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .ok_or_else(|| LegadoError::Ffi("no pay action".into()))?;

    // 4. QuickJS 执行（复用登录 V2 同款引擎池分桶基础设施）
    let raw = eval_pay_action(&source, &book, &chapter, pay_action)?;

    // 5. 结果判定（对齐 Kotlin isAbsUrl / isTrue 分支）
    let kind = classify_pay_result(&raw);
    if kind == "success" {
        // 购买成功 → 清当前章正文缓存，强制下次重新抓取
        // 按 (book_url, chapter.url) 复合键精确清除（Task #19），避免误删其他书同 URL 缓存
        with_database(|db| {
            CacheBookRepository::new(db.connection())
                .delete_by_book_and_chapter_url(book_url, &chapter.url)
        })?;
    }
    Ok(PayActionResult {
        kind,
        value: raw,
    })
}

/// 判定 JS 返回原文的结果类型
///
/// - 绝对 URL（http:// 或 https:// 开头）→ `url`
/// - 字面量 "true"（忽略大小写/首尾空白）→ `success`
/// - 其他 → `none`
fn classify_pay_result(raw: &str) -> String {
    let trimmed = raw.trim();
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        "url".into()
    } else if lower == "true" {
        "success".into()
    } else {
        "none".into()
    }
}

// ─── QuickJS 求值接入 ──────────────────────────────────────────

/// 启用 quickjs：以书源 URL 分桶复用全局引擎池执行 payAction 脚本
#[cfg(feature = "quickjs")]
fn eval_pay_action(
    source: &legado_core::models::BookSource,
    book: &legado_core::models::Book,
    chapter: &legado_core::models::BookChapter,
    pay_action: &str,
) -> LegadoResult<String> {
    // JsEngine trait 提供 eval_with_bindings（对照 source_login_v2_api）
    use legado_js::{JsEngine, JsValue};

    let engine = crate::js_executor::fresh_engine(&source.book_source_url)?;
    let guard = engine
        .lock()
        .map_err(|e| LegadoError::JsEngine(format!("JS 引擎加锁失败: {e}")))?;

    // 绑定对齐 Kotlin evalJS：book/chapter/title/baseUrl/result=null/src=null
    let book_value: serde_json::Value = serde_json::to_value(book)?;
    let chapter_value: serde_json::Value = serde_json::to_value(chapter)?;
    let bindings: Vec<(&str, JsValue)> = vec![
        ("baseUrl", JsValue::String(chapter.url.clone())),
        ("title", JsValue::String(chapter.title.clone())),
        ("book", json_to_js_value(book_value)),
        ("chapter", json_to_js_value(chapter_value)),
        ("result", JsValue::Null),
        ("src", JsValue::Null),
    ];
    guard.eval_with_bindings(pay_action, &bindings)
}

/// serde_json::Value → legado_js::JsValue（用于注入 book/chapter 绑定对象）
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

/// 未启用 quickjs：无法执行 JS，返回引擎未启用错误
#[cfg(not(feature = "quickjs"))]
fn eval_pay_action(
    _source: &legado_core::models::BookSource,
    _book: &legado_core::models::Book,
    _chapter: &legado_core::models::BookChapter,
    _pay_action: &str,
) -> LegadoResult<String> {
    Err(LegadoError::JsEngine(
        "QuickJS engine not enabled. Build with --features quickjs".into(),
    ))
}

// ─── 测试 ──────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use legado_db::repository::Repository;

    /// 结果判定为纯函数，不依赖 DB/quickjs
    #[test]
    fn test_classify_pay_result() {
        assert_eq!(classify_pay_result("https://pay.example.com/order"), "url");
        assert_eq!(classify_pay_result("http://pay.example.com"), "url");
        assert_eq!(classify_pay_result(" TRUE "), "success");
        assert_eq!(classify_pay_result("true"), "success");
        assert_eq!(classify_pay_result(""), "none");
        assert_eq!(classify_pay_result("{\"msg\":\"已购买\"}"), "none");
    }

    /// 本地书短路：origin=loc_book → kind=none，不触碰 JS
    #[test]
    fn test_local_book_short_circuit() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "http://pay-action.example.com/local-book";
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "本地购买测试",
            "author": "",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        let result = chapter_pay_action(book_url, 0).unwrap();
        assert_eq!(result.kind, "none");
        assert!(result.value.is_empty());

        // 清理
        with_database(|db| BookRepository::new(db.connection()).delete_by_url(book_url))
            .unwrap();
    }

    /// 无 payAction 规则 → "no pay action" 错误（对齐 Kotlin）
    #[test]
    fn test_missing_pay_action_error() {
        let _db_guard = crate::db_state::ensure_test_db();
        let source_url = "https://pay-no-action.example.com";
        let book_url = "http://pay-action.example.com/book-no-action";

        let source_json = serde_json::json!({
            "bookSourceUrl": source_url,
            "bookSourceName": "无购买规则源"
        })
        .to_string();
        crate::api::source::add_source(&source_json).unwrap();

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "购买测试",
            "author": "",
            "origin": source_url
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        let chapter = legado_core::models::BookChapter {
            url: format!("{book_url}/chapter/0"),
            title: "第一章".into(),
            book_url: book_url.into(),
            index: 0,
            ..Default::default()
        };
        with_database(|db| {
            BookChapterRepository::new(db.connection()).insert_batch(&[chapter])
        })
        .unwrap();

        let err = chapter_pay_action(book_url, 0).unwrap_err();
        assert!(err.to_string().contains("no pay action"));

        // 清理
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(book_url)?;
            BookRepository::new(conn).delete_by_url(book_url)?;
            BookSourceRepository::new(conn).delete(source_url)
        })
        .unwrap();
    }
}

/// quickjs 全链路测试：payAction 返回 URL / true
#[cfg(all(test, feature = "quickjs"))]
mod quickjs_tests {
    use super::*;
    use legado_db::repository::Repository;

    fn setup(source_url: &str, book_url: &str, pay_action: &str) {
        let source_json = serde_json::json!({
            "bookSourceUrl": source_url,
            "bookSourceName": "购买测试源",
            "ruleContent": { "payAction": pay_action }
        })
        .to_string();
        crate::api::source::add_source(&source_json).unwrap();

        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "付费书",
            "author": "测试",
            "origin": source_url
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).unwrap();

        let chapter = legado_core::models::BookChapter {
            url: format!("{book_url}/chapter/1"),
            title: "付费章".into(),
            book_url: book_url.into(),
            index: 1,
            ..Default::default()
        };
        with_database(|db| {
            BookChapterRepository::new(db.connection()).insert_batch(&[chapter])
        })
        .unwrap();
    }

    fn teardown(source_url: &str, book_url: &str) {
        with_database(|db| {
            let conn = db.connection();
            BookChapterRepository::new(conn).delete_by_book_url(book_url)?;
            BookRepository::new(conn).delete_by_url(book_url)?;
            BookSourceRepository::new(conn).delete(source_url)
        })
        .unwrap();
    }

    /// payAction 返回绝对 URL → kind=url（UI 打开支付页）
    #[test]
    fn test_pay_action_returns_url() {
        let _db_guard = crate::db_state::ensure_test_db();
        let source_url = "https://pay-url.example.com";
        let book_url = "http://pay-action.example.com/book-url";
        setup(
            source_url,
            book_url,
            "'https://pay.example.com/order?chapter=' + chapter.index",
        );

        let result = chapter_pay_action(book_url, 1).unwrap();
        assert_eq!(result.kind, "url");
        assert_eq!(result.value, "https://pay.example.com/order?chapter=1");

        teardown(source_url, book_url);
    }

    /// payAction 返回 true → kind=success，且当前章缓存被清除
    #[test]
    fn test_pay_action_success_clears_cache() {
        let _db_guard = crate::db_state::ensure_test_db();
        let source_url = "https://pay-success.example.com";
        let book_url = "http://pay-action.example.com/book-success";
        setup(source_url, book_url, "true");

        // 预置该章缓存，验证购买成功后被清除（对齐 Kotlin BookHelp.delContent）
        let chapter_url = format!("{book_url}/chapter/1");
        crate::api::cache_api::save_chapter_content(
            book_url,
            1,
            "付费章",
            "付费正文",
            &chapter_url,
        )
        .unwrap();
        assert!(!crate::api::cache_api::get_chapter_cache(book_url, 1)
            .unwrap()
            .is_empty());

        let result = chapter_pay_action(book_url, 1).unwrap();
        assert_eq!(result.kind, "success");
        assert!(crate::api::cache_api::get_chapter_cache(book_url, 1)
            .unwrap()
            .is_empty());

        teardown(source_url, book_url);
    }
}
