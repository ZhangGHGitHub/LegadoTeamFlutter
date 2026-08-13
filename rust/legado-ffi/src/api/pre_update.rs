//! 目录更新前 JS 钩子（对齐原版 `WebBook.runPreUpdateJs`）
//!
//! 执行 `TocRule.preUpdateJs`：以书籍为 ruleData 注入 `book`/`source`，
//! 允许书源在拉目录前改写 bookUrl/tocUrl/变量。

use legado_core::models::{Book, BookSource};
use legado_core::{LegadoError, LegadoResult};
use legado_parser::JsExecutor;

/// 执行 preUpdateJs（空规则 / 无 quickjs 时为 no-op）
pub fn run_pre_update_js(source: &BookSource, book: &Book) -> LegadoResult<()> {
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
        let book_json = serde_json::to_string(book).unwrap_or_else(|_| "{}".into());
        let source_json = serde_json::to_string(&source.book_source_url).unwrap_or_default();
        let executor = crate::js_executor::QuickJsExecutor::new(&source.book_source_url)
            .with_js_lib(source.js_lib.clone());
        let wrapped = format!(
            "globalThis.book = {book_json};\n\
             globalThis.source = {source_json};\n\
             {js}"
        );
        match executor.execute_js(&wrapped) {
            Ok(_) => Ok(()),
            Err(e) => {
                // 对齐原版 onFailure：记录但不阻断目录刷新主路径时由调用方决定；
                // 此处返回错误以便 refresh_toc 可选择忽略。
                Err(LegadoError::JsEngine(format!(
                    "执行preUpdateJs规则失败 书源:{}: {e}",
                    source.book_source_name
                )))
            }
        }
    }

    #[cfg(not(feature = "quickjs"))]
    {
        let _ = (js, source, book);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::TocRule;

    #[test]
    fn test_run_pre_update_js_empty_is_ok() {
        let source = BookSource::default();
        let book = Book::default();
        assert!(run_pre_update_js(&source, &book).is_ok());
    }

    #[test]
    fn test_run_pre_update_js_simple() {
        let mut source = BookSource {
            book_source_url: "https://example.com".into(),
            book_source_name: "测试".into(),
            ..BookSource::default()
        };
        source.rule_toc = Some(TocRule {
            pre_update_js: Some("1+1".into()),
            ..TocRule::default()
        });
        let book = Book {
            name: "书".into(),
            ..Book::default()
        };
        // quickjs 开启时应成功；关闭时 no-op
        let _ = run_pre_update_js(&source, &book);
    }
}
