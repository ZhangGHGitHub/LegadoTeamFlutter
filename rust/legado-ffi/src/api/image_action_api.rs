//! 正文图片 `click`/`js` 动作执行（契约 §2.21 `evalImageAction`）
//!
//! 对齐参考版 `ReadBookController.kt:677-695`：正文 `<img>` 的复合 URL
//! （`src,{json}`）携带 `click`/`js` 动作源码；点击时以书源 `evalJS` 语义
//! 注入 `source`（书源 JSON 对象）、`book`（name/author/bookUrl）、
//! `chapter`（title/index/url/bookUrl）、`result`（=imgSrc）、`baseUrl`
//! （imgSrc 目录部分）与全局 `java` 命名空间（`log/t2s/s2t/get/put`）。
//!
//! 约定：
//! - 执行器复用 `legado-js::replace_rule_js` 的 QuickJS 线程引擎与
//!   IIFE + `eval` 绑定构造风格（不新增第二份执行器）；引擎按书源 URL
//!   进程内 LRU 缓存（批21-A，复用已加载的 `jsLib`）；
//! - 动作抛错/超时/非法 → 返回空串并 `log::debug!`，不上抛（避免打断阅读）；
//! - **UI 副作用回传（批21-A）**：动作期间产生的 `java.toast`/`java.longToast`/
//!   `java.showBrowser`/`java.startBrowser`/`java.openUrl` 等经
//!   `ui_action_queue` 收集；有 action 时返回值扩展为结构化 JSON
//!   `{"result":"...","actions":[{...}]}`，无 action 时保持纯结果字符串
//!   （向后兼容，Dart 侧据 `actions` 且非空判定信封）；
//! - 无 quickjs 构建 → 返回明确错误（不静默）；
//! - `bookUrl` 无对应书籍行 → `book` 字段留空、`source` 为空对象 `{}`；
//! - `chapterIndex < 0` 或章节行缺失 → `chapter` 字段为空串/0。

use legado_core::LegadoResult;

#[cfg(feature = "quickjs")]
use legado_core::models::{book_type, Book, BookChapter, BookSource};
#[cfg(feature = "quickjs")]
use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};
#[cfg(feature = "quickjs")]
use legado_js::replace_rule_js::{
    ImageActionBindings, ReplaceJsBook, ReplaceJsChapter, ReplaceRuleJsExecutor,
    IMAGE_ACTION_TIMEOUT,
};

#[cfg(feature = "quickjs")]
use crate::db_state::with_database;

/// 执行正文图片 `click`/`js` 动作（契约 §2.21）
///
/// - `book_url` — 书籍 URL（查 books 行 → origin → 书源 JSON）
/// - `chapter_index` — 章节序号（`< 0` 表示无章节上下文）
/// - `action` — 动作源码（复合 URL 的 `click` 或 `js`）
/// - `img_src` — 图片地址（绑定 `result`；目录部分绑定 `baseUrl`）
///
/// 成功返回动作结果字符串；动作抛错/超时/非法返回空串（记 warn 日志）。
///
/// 动作期间产生的 `java.toast`/`showBrowser` 等中途 UI 副作用经
/// `ui_action_queue` 收集：**有 action 时**返回结构化 JSON
/// `{"result":"...","actions":[{...}]}`（批21-A，返回值格式的向后兼容扩展，
/// 方法签名不变）；**无 action 时**仍返回纯结果字符串（旧调用方无需改动）。
#[cfg(feature = "quickjs")]
pub fn eval_image_action(
    book_url: &str,
    chapter_index: i32,
    action: &str,
    img_src: &str,
) -> LegadoResult<String> {
    eval_image_action_with_budget(
        book_url,
        chapter_index,
        action,
        img_src,
        IMAGE_ACTION_TIMEOUT,
    )
}

/// 带显式预算的图片动作执行（测试注入短超时；生产走默认 3s）
///
/// UI action 信封格式（仅 `actions` 非空时）：
/// ```json
/// {"result": "动作返回值", "actions": [{"action": "toast", "message": "..."}]}
/// ```
/// `result` 与无 action 时的纯字符串返回值完全一致（`undefined` 已归一为
/// 空串），Dart 侧只需在检测到信封时拆包。
#[cfg(feature = "quickjs")]
pub fn eval_image_action_with_budget(
    book_url: &str,
    chapter_index: i32,
    action: &str,
    img_src: &str,
    budget: std::time::Duration,
) -> LegadoResult<String> {
    let (result, actions) =
        eval_image_action_collect_with_budget(book_url, chapter_index, action, img_src, budget)?;
    Ok(image_action_envelope(result, actions))
}

/// 组装返回值：无 UI action 保持纯字符串，有则返回结构化信封。
///
/// 信封只在 `actions` 非空时产生，避免把普通 JSON 字符串结果误判为信封；
/// `serde_json::to_string` 对 `Value` 数组不会失败，失败时按纯字符串返回
/// （不影响阅读主链路）。
#[cfg(feature = "quickjs")]
fn image_action_envelope(result: String, actions: Vec<serde_json::Value>) -> String {
    if actions.is_empty() {
        return result;
    }
    serde_json::to_string(&serde_json::json!({
        "result": result.clone(),
        "actions": actions,
    }))
    .unwrap_or(result)
}

/// 执行图片动作并返回收集到的 UI 副作用（测试可断言 action 未被丢弃）
///
/// 动作抛错/超时/非法/DB 错误均降级为空串（仅 warn 日志），与公开入口同语义。
#[cfg(feature = "quickjs")]
pub(crate) fn eval_image_action_collect_with_budget(
    book_url: &str,
    chapter_index: i32,
    action: &str,
    img_src: &str,
    budget: std::time::Duration,
) -> LegadoResult<(String, Vec<serde_json::Value>)> {
    // 空动作：按「非法动作」口径返回空串，不进入 JS 引擎
    if action.trim().is_empty() {
        log::warn!("图片动作执行跳过：动作源码为空（book={book_url}）");
        return Ok((String::new(), Vec::new()));
    }

    match eval_image_action_inner(book_url, chapter_index, action, img_src, budget) {
        Ok(pair) => Ok(pair),
        Err(err) => {
            // 契约：动作抛错/超时/非法不上抛，返回空串并记日志
            log::warn!("图片动作执行失败（book={book_url}, chapter={chapter_index}）：{err}");
            Ok((String::new(), Vec::new()))
        }
    }
}

/// 无 quickjs 构建：返回明确错误（不静默降级）
#[cfg(not(feature = "quickjs"))]
pub fn eval_image_action(
    _book_url: &str,
    _chapter_index: i32,
    _action: &str,
    _img_src: &str,
) -> LegadoResult<String> {
    Err(legado_core::LegadoError::JsEngine(
        "QuickJS 未启用，图片 action 不执行（evalImageAction 不可用）".to_string(),
    ))
}

/// 聚合查询、绑定构造、执行与 UI 副作用收集
#[cfg(feature = "quickjs")]
fn eval_image_action_inner(
    book_url: &str,
    chapter_index: i32,
    action: &str,
    img_src: &str,
    budget: std::time::Duration,
) -> LegadoResult<(String, Vec<serde_json::Value>)> {
    let book = with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))?;
    let source = load_source(book.as_ref())?;
    let chapter = load_chapter(book_url, chapter_index)?;

    let source_json = match source {
        Some(source) => serde_json::to_string(&source)?,
        None => "{}".to_string(),
    };
    let book_binding = match book.as_ref() {
        Some(book) => ReplaceJsBook {
            name: book.name.clone(),
            author: book.author.clone(),
            book_url: book.book_url.clone(),
        },
        // 契约：无书籍行时 book 字段留空
        None => ReplaceJsBook::default(),
    };
    let chapter_binding = match chapter.as_ref() {
        Some(chapter) => ReplaceJsChapter {
            title: chapter.title.clone(),
            index: chapter.index,
            url: chapter.url.clone(),
            book_url: if chapter.book_url.is_empty() {
                book_url.to_string()
            } else {
                chapter.book_url.clone()
            },
        },
        // 契约：无章节上下文时字段为空串/0
        None => ReplaceJsChapter::default(),
    };

    let bindings = ImageActionBindings::new(
        source_json,
        book_binding,
        chapter_binding,
        img_src,
        image_base_url(img_src),
    );
    // 复用替换规则执行器；UI 副作用按每次求值独立收集（P1-2）
    let (eval_result, collected) = legado_js::host_api::ui_action_queue::with_collect(|| {
        ReplaceRuleJsExecutor::without_context()
            .eval_image_action_with_budget(action, &bindings, budget)
    });
    let raw = match eval_result {
        Ok(raw) => raw,
        Err(err) => {
            log::warn!("图片动作执行失败（book={book_url}, chapter={chapter_index}）：{err}");
            String::new()
        }
    };
    Ok((raw, collected.actions))
}

/// 按书籍 `origin` 查书源；书籍或书源缺失时返回 `None`（绑定 `{}`）
#[cfg(feature = "quickjs")]
fn load_source(book: Option<&Book>) -> LegadoResult<Option<BookSource>> {
    let Some(book) = book else {
        return Ok(None);
    };
    if book.origin == book_type::LOCAL_TAG || book.origin.is_empty() {
        return Ok(None);
    }
    with_database(|db| BookSourceRepository::new(db.connection()).find_by_url(&book.origin))
}

/// 按 `(bookUrl, chapterIndex)` 查章节；index `< 0` 时不查询
#[cfg(feature = "quickjs")]
fn load_chapter(book_url: &str, chapter_index: i32) -> LegadoResult<Option<BookChapter>> {
    if chapter_index < 0 {
        return Ok(None);
    }
    with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, chapter_index)
    })
}

/// 取图片地址的目录部分（等价 Kotlin `Uri` 取目录；解析失败回退原串）
///
/// 仅处理 `scheme://` 绝对地址；`?`/`#` 之后不参与目录截取。无 scheme、
/// 无路径分隔符或其它异常形态一律原样返回（对齐契约「失败用 imgSrc 本身」）。
#[cfg(feature = "quickjs")]
fn image_base_url(img_src: &str) -> String {
    let src = img_src.trim();
    if src.is_empty() {
        return String::new();
    }
    let Some(scheme_end) = src.find("://").map(|idx| idx + 3) else {
        return src.to_string();
    };
    let path_end = src.find(['?', '#']).unwrap_or(src.len());
    let path = &src[..path_end];
    if path.len() <= scheme_end {
        return src.to_string();
    }
    match path[scheme_end..].rfind('/') {
        Some(relative) => {
            let dir_end = scheme_end + relative + 1;
            path[..dir_end].to_string()
        }
        None => src.to_string(),
    }
}

#[cfg(all(test, feature = "quickjs"))]
mod tests {
    use super::*;
    use crate::db_state::ensure_test_db;
    use legado_core::models::{Book, BookChapter, BookSource};
    use legado_db::repository::Repository;
    use legado_db::{BookChapterRepository, BookRepository, BookSourceRepository};

    struct Fixture {
        source_url: String,
        source_name: String,
        book_url: String,
        image: String,
    }

    /// 插入独立书源/书籍/章节（tag 唯一化，避免共享测试库互相污染）
    ///
    /// 返回串行锁守卫，调用方必须绑定到变量（如 `let (_g, fx) = ...`），
    /// 避免共享测试库上的并发读写交错。
    fn setup_fixture(tag: &str) -> (std::sync::MutexGuard<'static, ()>, Fixture) {
        setup_fixture_with(tag, None)
    }

    fn setup_fixture_with(
        tag: &str,
        js_lib: Option<&str>,
    ) -> (std::sync::MutexGuard<'static, ()>, Fixture) {
        let db_guard = ensure_test_db();
        let fixture = insert_fixture(tag, js_lib);
        (db_guard, fixture)
    }

    /// 插入一套独立书源/书籍/章节（调用方必须已持有测试库串行锁）
    ///
    /// 拆出以便同一测试内插入多个书源（同线程重复 `ensure_test_db`
    /// 会自锁死）。
    fn insert_fixture(tag: &str, js_lib: Option<&str>) -> Fixture {
        let source_url = format!("https://image-action-{tag}.example.com/source");
        let source_name = format!("图片动作源{tag}");
        let book_url = format!("https://image-action-{tag}.example.com/book/1");
        let chapter_url = format!("https://image-action-{tag}.example.com/chapter/7");
        with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: source_url.clone(),
                book_source_name: source_name.clone(),
                js_lib: js_lib.map(str::to_string),
                ..BookSource::default()
            })?;
            BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.clone(),
                origin: source_url.clone(),
                name: format!("图片动作书{tag}"),
                author: format!("作者{tag}"),
                ..Book::default()
            })?;
            BookChapterRepository::new(db.connection()).insert_batch(&[BookChapter {
                url: chapter_url,
                title: format!("第{tag}章"),
                index: 7,
                book_url: book_url.clone(),
                ..BookChapter::default()
            }])
        })
        .unwrap();
        Fixture {
            source_url,
            source_name,
            book_url,
            image: format!("https://cdn-{tag}.example.com/dir/pic.jpg"),
        }
    }

    fn remove_keys(keys: &[String]) {
        for key in keys {
            let _ = legado_js::host_api::variable_store::remove_variable(key);
        }
    }

    /// 绑定字段可见：source/book/chapter/result/baseUrl/java 同时可读
    #[test]
    fn bindings_visible_to_action() {
        let (_g, fx) = setup_fixture("bindings");
        let action = "[source.bookSourceName, book.name, book.author, book.bookUrl, \
                      chapter.title, chapter.index, chapter.url, chapter.bookUrl, \
                      result, baseUrl, typeof java.log, typeof java.t2s, typeof java.s2t, \
                      typeof java.get, typeof java.put].join('|')";
        let out = eval_image_action(&fx.book_url, 7, action, &fx.image).unwrap();
        let expected = format!(
            "图片动作源bindings|图片动作书bindings|作者bindings|{}|第bindings章|7|\
             https://image-action-bindings.example.com/chapter/7|{}|{}|{}|\
             function|function|function|function|function",
            fx.book_url, fx.book_url, fx.image, "https://cdn-bindings.example.com/dir/",
        );
        assert_eq!(out, expected);
    }

    /// P1-1：书源 jsLib 在动作执行前预载（修复前 `getDP` ReferenceError → 空串）
    ///
    /// 同时验证 jsLib 顶层可读 `source.getKey()`（前置绑定先于 jsLib 求值）。
    #[test]
    fn js_lib_function_is_visible_to_action() {
        let (_g, fx) = setup_fixture_with(
            "jslib",
            Some(
                "var __libKey = source.getKey();\n\
                 function getDP(a, b) { return a + b; }\n\
                 function libKey() { return __libKey; }",
            ),
        );
        let out = eval_image_action(
            &fx.book_url,
            7,
            "[getDP(1, 37), libKey()].join('|')",
            &fx.image,
        )
        .unwrap();
        assert_eq!(out, format!("38|{}", fx.source_url));
    }

    /// P1-1：QuickJS 拒绝的 Rhino 宽容语法经 `jslib_normalize` 归一化后加载
    #[test]
    fn js_lib_normalized_when_quickjs_rejects_syntax() {
        let (_g, fx) = setup_fixture_with(
            "jslibnorm",
            Some("function libValue() { var data = {item: {v: 'ok'}}; return data..item.v; }"),
        );
        let out = eval_image_action(&fx.book_url, 7, "libValue()", &fx.image).unwrap();
        assert_eq!(out, "ok");
    }

    /// P2-4：source 方法面（getKey/getTag/getVariable/putVariable/put/get）
    /// 与 P2-3：java.get/put 按 `v_{sourceKey}_{key}` 源作用域读写（不碰裸键）
    #[test]
    fn source_methods_and_scoped_java_get_put() {
        let (_g, fx) = setup_fixture("srcmethods");
        let source_key = format!("v_{}_k", fx.source_url);
        let java_key = format!("v_{}_jk", fx.source_url);
        let var_key = format!("sourceVariable_{}", fx.source_url);
        let action = "[source.getKey(), source.getTag(), source.get('k'), \
                      source.put('k', 'v'), source.get('k'), source.getVariable(), \
                      source.putVariable('sv'), source.getVariable(), \
                      java.put('jk', 'jv'), java.get('jk')].join('|')";
        let out = eval_image_action(&fx.book_url, 7, action, &fx.image).unwrap();
        assert_eq!(
            out,
            format!("{}|{}||v|v||sv|sv|jv|jv", fx.source_url, fx.source_name)
        );
        assert_eq!(
            legado_js::host_api::variable_store::get_variable(&source_key).unwrap(),
            Some("v".to_string())
        );
        assert_eq!(
            legado_js::host_api::variable_store::get_variable(&java_key).unwrap(),
            Some("jv".to_string())
        );
        assert_eq!(
            legado_js::host_api::variable_store::get_variable(&var_key).unwrap(),
            Some("sv".to_string())
        );
        assert!(
            legado_js::host_api::variable_store::get_variable("k")
                .unwrap()
                .is_none(),
            "java.put 不得写裸键（会污染 @get 兜底层）"
        );
        remove_keys(&[source_key, java_key, var_key]);
    }

    /// P2-4：cookie 对象方法面可用（getCookie/setCookie/cookieToMap 等）
    #[test]
    fn cookie_object_methods_available() {
        let (_g, fx) = setup_fixture("cookieobj");
        let action = "[typeof cookie.getCookie, typeof cookie.setCookie, \
                      typeof cookie.cookieToMap, cookie.cookieToMap('a=1; b=2')['a']].join('|')";
        let out = eval_image_action(&fx.book_url, 7, action, &fx.image).unwrap();
        assert_eq!(out, "function|function|function|1");
    }

    /// `chapterIndex < 0`：chapter 绑定留空（title/url/bookUrl 空串、index 0）
    #[test]
    fn negative_chapter_index_leaves_chapter_empty() {
        let (_g, fx) = setup_fixture("nochapter");
        let action = "[chapter.title, chapter.index, chapter.url, chapter.bookUrl].join('|')";
        let out = eval_image_action(&fx.book_url, -1, action, &fx.image).unwrap();
        assert_eq!(out, "|0||");
    }

    /// `chapterIndex >= 0` 但章节行缺失：chapter 绑定留空（不误报其它章）
    #[test]
    fn missing_chapter_row_leaves_chapter_empty() {
        let (_g, fx) = setup_fixture("missingchapter");
        let action = "[chapter.title, chapter.index, chapter.url, chapter.bookUrl].join('|')";
        let out = eval_image_action(&fx.book_url, 8, action, &fx.image).unwrap();
        assert_eq!(out, "|0||");
    }

    /// 无书籍行：book 留空，source 仍为对象（含 6 个方法）、result/baseUrl 可用
    #[test]
    fn missing_book_leaves_book_empty_but_source_and_result_available() {
        let _db_guard = ensure_test_db();
        let out = eval_image_action(
            "https://image-action-no-such-book.example.com/book/1",
            -1,
            "[typeof source, Object.keys(source).length, typeof source.getKey, \
             book.name, book.author, book.bookUrl, result, baseUrl].join('|')",
            "https://cdn.example.com/a/b.jpg",
        )
        .unwrap();
        assert_eq!(
            out,
            "object|6|function||||https://cdn.example.com/a/b.jpg|https://cdn.example.com/a/"
        );
    }

    /// 动作抛错：返回空串（不上抛）
    #[test]
    fn action_throw_returns_empty_string() {
        let (_g, fx) = setup_fixture("throw");
        let out = eval_image_action(&fx.book_url, 7, "throw new Error('boom')", &fx.image).unwrap();
        assert_eq!(out, "");
    }

    /// 非法 JS：返回空串（不上抛）
    #[test]
    fn invalid_action_returns_empty_string() {
        let (_g, fx) = setup_fixture("invalid");
        let out = eval_image_action(&fx.book_url, 7, "(function(", &fx.image).unwrap();
        assert_eq!(out, "");
    }

    /// 空动作：直接返回空串
    #[test]
    fn blank_action_returns_empty_string() {
        let (_g, fx) = setup_fixture("blank");
        let out = eval_image_action(&fx.book_url, 7, "   ", &fx.image).unwrap();
        assert_eq!(out, "");
    }

    /// P3-8：void 动作返回 "undefined" → 归一空串
    #[test]
    fn void_action_returns_empty_string() {
        let (_g, fx) = setup_fixture("void");
        let out = eval_image_action(&fx.book_url, 7, "void 0", &fx.image).unwrap();
        assert_eq!(out, "");
    }

    /// P1-2：UI 副作用进入 `ui_action_queue` 收集（修复前无收集栈被静默丢弃）
    #[test]
    fn ui_actions_are_collected_not_dropped() {
        let (_g, fx) = setup_fixture("uiactions");
        let (out, actions) = eval_image_action_collect_with_budget(
            &fx.book_url,
            7,
            "java.toast('hi'); 'done'",
            &fx.image,
            IMAGE_ACTION_TIMEOUT,
        )
        .unwrap();
        assert_eq!(out, "done");
        assert_eq!(actions.len(), 1, "actions={actions:?}");
        assert_eq!(actions[0]["action"], "toast");
        assert_eq!(actions[0]["message"], "hi");
    }

    /// 批21-A：动态拼接的 java.toast 消息经返回值信封回传（修复前 Dart 不可见）
    ///
    /// `java.toast('a' + 'b')` 的静态字面量提取只能拿到 `'a' + 'b'` 片段
    /// （甚至提取不到），只有走动作队列回传才能拿到实际值 `ab`。
    #[test]
    fn dynamic_toast_message_is_returned_in_envelope() {
        let (_g, fx) = setup_fixture("uienvelope");
        let raw =
            eval_image_action(&fx.book_url, 7, "java.toast('a' + 'b'); 'done'", &fx.image).unwrap();
        let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(value["result"], "done");
        assert_eq!(value["actions"].as_array().map(Vec::len), Some(1));
        assert_eq!(value["actions"][0]["action"], "toast");
        assert_eq!(value["actions"][0]["message"], "ab");
    }

    /// 批21-A：无 UI action 时返回值仍是纯字符串（向后兼容）
    #[test]
    fn no_ui_action_returns_plain_string() {
        let (_g, fx) = setup_fixture("plainresult");
        let raw = eval_image_action(&fx.book_url, 7, "'plain'", &fx.image).unwrap();
        assert_eq!(raw, "plain");
    }

    /// 批21-A：同一书源连续两次点击只创建一次引擎（jsLib 只加载一次）
    #[test]
    fn repeated_clicks_reuse_engine_for_same_source() {
        let (_g, fx) = setup_fixture_with("cachecount", Some("function lib(){ return 'ok'; }"));
        legado_js::replace_rule_js::clear_image_action_engines();
        legado_js::replace_rule_js::reset_image_action_engine_created_count();
        assert_eq!(
            eval_image_action(&fx.book_url, 7, "lib()", &fx.image).unwrap(),
            "ok"
        );
        assert_eq!(
            eval_image_action(&fx.book_url, 7, "lib()", &fx.image).unwrap(),
            "ok"
        );
        assert_eq!(
            legado_js::replace_rule_js::image_action_engine_created_count(),
            1,
            "同一书源连续点击应复用缓存引擎"
        );
    }

    /// 批21-A：复用命中时 result/baseUrl 绑定按本次点击刷新（不残留）
    #[test]
    fn cache_hit_refreshes_result_binding() {
        let (_g, fx) = setup_fixture("cacherefresh");
        legado_js::replace_rule_js::clear_image_action_engines();
        legado_js::replace_rule_js::reset_image_action_engine_created_count();
        let first = eval_image_action(
            &fx.book_url,
            7,
            "[result, baseUrl].join('|')",
            "https://cdn-refresh.example.com/first/a.jpg",
        )
        .unwrap();
        let second = eval_image_action(
            &fx.book_url,
            7,
            "[result, baseUrl].join('|')",
            "https://cdn-refresh.example.com/second/b.jpg",
        )
        .unwrap();
        assert_eq!(
            first,
            "https://cdn-refresh.example.com/first/a.jpg|https://cdn-refresh.example.com/first/"
        );
        assert_eq!(
            second,
            "https://cdn-refresh.example.com/second/b.jpg|https://cdn-refresh.example.com/second/"
        );
        assert_eq!(
            legado_js::replace_rule_js::image_action_engine_created_count(),
            1
        );
    }

    /// 批21-A：invalidate 后同一书源重新创建引擎（书源更新路径）
    #[test]
    fn invalidate_recreates_engine_for_source() {
        let (_g, fx) = setup_fixture("cacheinvalidate");
        legado_js::replace_rule_js::clear_image_action_engines();
        legado_js::replace_rule_js::reset_image_action_engine_created_count();
        let _ = eval_image_action(&fx.book_url, 7, "'1'", &fx.image).unwrap();
        legado_js::replace_rule_js::invalidate_image_action_engine(&fx.source_url);
        let _ = eval_image_action(&fx.book_url, 7, "'2'", &fx.image).unwrap();
        assert_eq!(
            legado_js::replace_rule_js::image_action_engine_created_count(),
            2
        );
    }

    /// 批21-A：不同书源各自一个引擎（互不复用）
    #[test]
    fn different_sources_use_separate_engines() {
        let db_guard = ensure_test_db();
        let first = insert_fixture("cachesep-a", None);
        let second = insert_fixture("cachesep-b", None);
        legado_js::replace_rule_js::clear_image_action_engines();
        legado_js::replace_rule_js::reset_image_action_engine_created_count();
        let _ = eval_image_action(&first.book_url, 7, "'A'", &first.image).unwrap();
        let _ = eval_image_action(&second.book_url, 7, "'B'", &second.image).unwrap();
        assert_eq!(
            legado_js::replace_rule_js::image_action_engine_created_count(),
            2
        );
        drop(db_guard);
    }

    /// 超时：死循环在短预算内被中断，返回空串（不上抛）
    #[test]
    fn timeout_returns_empty_string() {
        let (_g, fx) = setup_fixture("timeout");
        let out = eval_image_action_with_budget(
            &fx.book_url,
            7,
            "while (true) {}",
            &fx.image,
            std::time::Duration::from_millis(50),
        )
        .unwrap();
        assert_eq!(out, "");
    }

    /// 目录提取：绝对地址取目录；无 scheme/无可截取目录回退原串
    #[test]
    fn base_url_is_directory_of_img_src() {
        assert_eq!(
            image_base_url("https://cdn.example.com/a/b.jpg"),
            "https://cdn.example.com/a/"
        );
        assert_eq!(
            image_base_url("https://cdn.example.com/a.jpg?token=/x/y"),
            "https://cdn.example.com/"
        );
        // P3-6：result 传完整复合 src 时目录仍正确剥离
        assert_eq!(
            image_base_url("https://cdn.example.com/a/b.jpg,{\"click\":\"act()\"}"),
            "https://cdn.example.com/a/"
        );
        assert_eq!(image_base_url("relative/path/a.jpg"), "relative/path/a.jpg");
        assert_eq!(
            image_base_url("https://cdn.example.com"),
            "https://cdn.example.com"
        );
        assert_eq!(image_base_url(""), "");
    }
}

#[cfg(all(test, not(feature = "quickjs")))]
mod no_quickjs_tests {
    use super::eval_image_action;

    /// 无 quickjs 构建：明确报错（不静默返回空串）
    #[test]
    fn without_quickjs_returns_explicit_error() {
        let err = eval_image_action(
            "https://book.example.com/1",
            0,
            "1 + 1",
            "https://img.example.com/a.jpg",
        )
        .unwrap_err();
        let message = err.to_string();
        assert!(message.contains("QuickJS"), "message={message}");
        assert!(message.contains("evalImageAction"), "message={message}");
    }
}
