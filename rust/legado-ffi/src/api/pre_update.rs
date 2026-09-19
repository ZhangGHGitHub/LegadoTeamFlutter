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
            let mut b = book_cell.lock().map_err(|_| "book 锁失败".to_string())?;
            re_get_book_native(&source, &mut b).map_err(|e| e.to_string())?;
            serde_json::to_string(&*b).map_err(|e| e.to_string())
        }))
    };

    let refresh: legado_js::host_api::pre_update_hooks::PreUpdateHook = {
        let book_cell = Arc::clone(&book_cell);
        let source = source_owned.clone();
        Arc::new(Mutex::new(move || {
            let mut b = book_cell.lock().map_err(|_| "book 锁失败".to_string())?;
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
            // [P2-8] 精搜命中的详情页地址写入 originBookUrl（当前书源详情页），
            // 不再改写 book_url：bookUrl 是稳定主键（chapters/cached_chapters/
            // download_tasks 等多处持有者依赖其不变，P0 教训 da7b0d265f），
            // 下游「抓取书籍页」路径按 originBookUrl 优先、空则回退 bookUrl。
            book.origin_book_url = url.to_string();
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
///
/// [P2-8] 取址：优先 `origin_book_url`（当前书源详情页地址；该字段有两个
/// 写者——换源事务（`switch_book_source_with`）与本文件 preUpdateJs 钩子
/// reGetBook（`re_get_book_native`，经刷新流程落库），均只写 DB 列），为空
/// 回退 `book_url`（稳定主键；未换源书籍与存量库行为不变）。
#[cfg(feature = "quickjs")]
fn refresh_toc_url_native(source: &BookSource, book: &mut Book) -> LegadoResult<()> {
    // P1-2 入口收口：本钩子执行 ruleBookInfo（JS 变量桥读写）→ 先切
    // flow scope（键 = 书籍页取址点 originBookUrl 优先、回退 bookUrl，
    // 与 webbook_info 的 book_url 键同族），防上一流程残留 scope 串读/误清。
    // reGetBook 钩子（re_get_book_native）经 precise_search 后落到本函数
    // 收口；precise_search 自身不加 begin（mid-flow 调用方，见其文档）。
    crate::api::web_book::begin_book_flow(&book.book_page_fetch_url());
    let engine = crate::api::web_book::build_engine()?;
    // [P2-8] 取址：优先 originBookUrl（当前书源详情页），为空回退 bookUrl
    let fetch_url = book.book_page_fetch_url();
    let info = crate::runtime::block_on(async { engine.get_book_info(source, fetch_url).await })?;
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
