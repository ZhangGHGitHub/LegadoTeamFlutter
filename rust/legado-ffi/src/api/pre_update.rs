//! 目录更新前 JS 钩子（对齐原版 `WebBook.runPreUpdateJs`）
//!
//! 执行 `TocRule.preUpdateJs`：以书籍为 ruleData 注入 `book`/`source`，
//! 允许书源在拉目录前改写 bookUrl/tocUrl/变量。
//!
//! 宿主钩子（quickjs）：
//! - `java.reGetBook()` — preciseSearch + getBookInfo（仅本源）
//! - `java.refreshTocUrl()` — getBookInfo 刷新 tocUrl

use legado_core::models::{Book, BookSource};
use legado_core::LegadoResult;

/// 执行 preUpdateJs 并写回 `book`（空规则 / 无 quickjs 时为 no-op）
pub fn run_pre_update_js(source: &BookSource, book: &mut Book) -> LegadoResult<()> {
    let Some(js) = source
        .rule_toc
        .as_ref()
        .and_then(|t| t.pre_update_js.as_deref())
        .map(str::trim)
        .filter(|s| !s.is_empty())
    else {
        return Ok(());
    };

    #[cfg(feature = "quickjs")]
    {
        run_pre_update_js_inner(source, book, js)
    }

    #[cfg(not(feature = "quickjs"))]
    {
        let _ = (js, source, book);
        Ok(())
    }
}

#[cfg(feature = "quickjs")]
fn run_pre_update_js_inner(source: &BookSource, book: &mut Book, js: &str) -> LegadoResult<()> {
    use std::sync::{Arc, Mutex};

    use legado_core::LegadoError;
    use legado_parser::JsExecutor;

    let book_cell = Arc::new(Mutex::new(book.clone()));
    let source_owned = source.clone();

    let re_get: legado_js::host_api::pre_update_hooks::PreUpdateHook = {
        let book_cell = Arc::clone(&book_cell);
        let source = source_owned.clone();
        Arc::new(Mutex::new(move || {
            let mut b = book_cell
                .lock()
                .map_err(|_| "book 锁失败".to_string())?;
            re_get_book_native(&source, &mut b).map_err(|e| e.to_string())?;
            serde_json::to_string(&*b).map_err(|e| e.to_string())
        }))
    };

    let refresh: legado_js::host_api::pre_update_hooks::PreUpdateHook = {
        let book_cell = Arc::clone(&book_cell);
        let source = source_owned.clone();
        Arc::new(Mutex::new(move || {
            let mut b = book_cell
                .lock()
                .map_err(|_| "book 锁失败".to_string())?;
            refresh_toc_url_native(&source, &mut b).map_err(|e| e.to_string())?;
            serde_json::to_string(&*b).map_err(|e| e.to_string())
        }))
    };

    let book_json = serde_json::to_string(book).unwrap_or_else(|_| "{}".into());
    let source_json = serde_json::to_string(&source.book_source_url).unwrap_or_default();
    let wrapped = format!(
        "globalThis.book = {book_json};\n\
         globalThis.source = {source_json};\n\
         globalThis.fromBookInfo = false;\n\
         {js};\n\
         JSON.stringify(book);"
    );

    let executor = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
        .with_js_lib(source.js_lib.clone());

    let eval_out = legado_js::host_api::pre_update_hooks::with_hooks(re_get, refresh, || {
        executor.execute_js(&wrapped)
    })
    .map_err(|e| {
        LegadoError::JsEngine(format!(
            "执行preUpdateJs规则失败 书源:{}: {e}",
            source.book_source_name
        ))
    })?;

    // 优先采用 JS 侧最终 book；失败则回退钩子已写入的 book_cell
    if let Ok(updated) = serde_json::from_str::<Book>(&eval_out) {
        *book = updated;
    } else if let Ok(guard) = book_cell.lock() {
        *book = guard.clone();
    }
    Ok(())
}

/// 对齐 `AnalyzeRule.reGetBook`：本源精搜 + 拉详情
#[cfg(feature = "quickjs")]
fn re_get_book_native(source: &BookSource, book: &mut Book) -> LegadoResult<()> {
    let urls = serde_json::to_string(&vec![&source.book_source_url])?;
    let hit_json = crate::api::search::precise_search(&book.name, &book.author, &urls)?;
    let hit: serde_json::Value = serde_json::from_str(&hit_json)?;
    if let Some(url) = hit.get("bookUrl").and_then(|v| v.as_str()) {
        if !url.is_empty() {
            book.book_url = url.to_string();
        }
    }
    if let Some(var) = hit.get("variable").and_then(|v| v.as_str()) {
        if !var.is_empty() {
            book.variable = Some(var.to_string());
        }
    }
    refresh_toc_url_native(source, book)
}

/// 对齐 `AnalyzeRule.refreshTocUrl`：重新拉详情写 tocUrl 等
#[cfg(feature = "quickjs")]
fn refresh_toc_url_native(source: &BookSource, book: &mut Book) -> LegadoResult<()> {
    let engine = crate::api::web_book::build_engine();
    let info = crate::runtime::block_on(async {
        engine.get_book_info(source, &book.book_url).await
    })?;
    apply_web_info_to_book(book, &info);
    Ok(())
}

#[cfg(feature = "quickjs")]
fn apply_web_info_to_book(book: &mut Book, info: &legado_core::web_book::WebBookInfo) {
    if !info.toc_url.is_empty() {
        book.toc_url = info.toc_url.clone();
    }
    if !info.name.is_empty() {
        book.name = info.name.clone();
    }
    if !info.author.is_empty() {
        book.author = info.author.clone();
    }
    if let Some(ref cover) = info.cover_url {
        book.cover_url = Some(cover.clone());
    }
    if let Some(ref intro) = info.intro {
        book.intro = Some(intro.clone());
    }
    if let Some(ref kind) = info.kind {
        book.kind = Some(kind.clone());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::TocRule;

    #[test]
    fn test_run_pre_update_js_empty_is_ok() {
        let source = BookSource::default();
        let mut book = Book::default();
        assert!(run_pre_update_js(&source, &mut book).is_ok());
    }

    #[test]
    fn test_run_pre_update_js_mutates_book_fields() {
        let mut source = BookSource {
            book_source_url: "https://example.com".into(),
            book_source_name: "测试".into(),
            ..BookSource::default()
        };
        source.rule_toc = Some(TocRule {
            pre_update_js: Some(r#"book.tocUrl = "https://example.com/toc";"#.into()),
            ..TocRule::default()
        });
        let mut book = Book {
            name: "书".into(),
            book_url: "https://example.com/book".into(),
            ..Book::default()
        };
        let _ = run_pre_update_js(&source, &mut book);
        #[cfg(feature = "quickjs")]
        {
            assert_eq!(book.toc_url, "https://example.com/toc");
        }
    }

    #[cfg(feature = "quickjs")]
    #[test]
    fn test_apply_web_info_to_book() {
        let mut book = Book::default();
        let info = legado_core::web_book::WebBookInfo::new("名", "作", "https://b", "https://t");
        apply_web_info_to_book(&mut book, &info);
        assert_eq!(book.toc_url, "https://t");
        assert_eq!(book.name, "名");
    }
}
