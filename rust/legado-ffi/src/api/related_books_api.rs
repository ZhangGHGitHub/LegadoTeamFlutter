//! 相关书（RelatedBooks）FFI API
//!
//! [R42 阶段 1 | 2026-11-21] 参考版独有功能，授权依据见
//! `docs/API_CONTRACT.md` 2026-11-21c 行与
//! `docs/过期文档/UI_ONE_TO_ONE_CLONE_PLAN_20260905.md` §〇。
//!
//! 数据源**不是**本地表、也不是 AI 生成：书源 `ruleBookInfo.relatedBooks`
//! 存一个 JSON 数组，每项 `{key, title, url}`；逐项按发现页规则抓取书籍列表，
//! 再过滤掉当前书本身。对齐参考版
//! `legado-with-MD3/app/src/main/java/io/legado/app/model/webBook/RelatedBooks.kt`：
//!
//! - 配置为空 / 解析失败 / 无书源 / 全部模块失败 / 过滤后全空 → `{"modules":[]}`
//!   （**不抛错**，UI 按「空数据隐藏」降级）；
//! - 单模块容错：某模块 `url` 为空或请求/解析失败 → 跳过该模块，其余照常；
//! - 每模块固定取第 1 页（参考版 `exploreBookWithResolvedUrl(source, url, 1, book)`）；
//! - 返回 `resolvedUrl`（变量替换 + 重定向后的最终 URL），对齐参考版返回的
//!   `Pair<String, List<SearchBook>>` 首元素。
//!
//! ## 与参考版的已知差异
//!
//! 参考版把 `book` 作为 `RuleDataInterface` 传入 `AnalyzeUrl`，因此模块 url 里的
//! `{{bookName}}` 等书籍变量可求值。我方可复用的发现链入口
//! [`crate::api::explore_api::explore_books_with_resolved_url_async`] 目前不接受
//! `Book` 上下文（签名与既有发现页一致），故本实现**不注入书籍变量**：
//! `{{bookName}}` 这类模板会求值为空串。绝大多数书源的相关书模块 url 是纯静态
//! 分类地址，不受影响；若后续需要，再为发现链增加可选 `Book` 形参。
//!
//! ## 并发
//!
//! 参考版 `coroutineScope + async + awaitAll` 并发请求各模块。本实现在
//! [`crate::runtime::block_on`] 驱动的同一异步任务内用
//! `buffered(RELATED_BOOKS_CONCURRENCY)` 并发推进各模块 future（HTTP 请求
//! 真并发、结果顺序与配置顺序一致），并用 [`RELATED_BOOKS_CONCURRENCY`]
//! 限制同时在途的请求数，避免模块数异常大时打爆进程级共享连接池。
//!
//! ## 流程作用域
//!
//! 本入口**不切** flow scope（不调用 `begin_book_flow`）：相关书在书籍信息页
//! 触发时，当前 flow scope 通常仍是该书的信息流程（`info:{bookUrl}`），
//! 切到 `explore:{书源 URL}` 会清掉信息流程的会话变量。规则/JS 解析路径不依赖
//! flow scope，保持现状副作用最小。

use futures::stream::{self, StreamExt};
use legado_core::models::{Book, BookSource};
use legado_core::web_book::WebSearchResult;
use legado_core::{LegadoError, LegadoResult};
use serde::{Deserialize, Serialize};

/// 同时在途的模块请求上限
///
/// 参考版不限并发；我方取 8 的理由：① 常见书源只配 1–4 个模块，8 已覆盖
/// 正常规模且不会形成额外排队；② 共享 HTTP 客户端与连接池是进程级单例，
/// 模块数异常大（如聚合源把整个分类表塞进 relatedBooks）时无上限会瞬间占满
/// 连接池并挤占同进程的搜索/阅读请求；③ 8 与既有「单源并发」量级一致。
const RELATED_BOOKS_CONCURRENCY: usize = 8;

/// 单个相关书模块（camelCase JSON，对齐契约 2026-11-21c）
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RelatedBooksModule {
    /// 模块标识（配置 `key`，缺省回退 `title`）
    pub key: String,
    /// 模块标题
    pub title: String,
    /// 配置里的原始 url（未做变量替换）
    pub url: String,
    /// 变量替换 + 重定向后的最终 url
    pub resolved_url: String,
    /// 过滤掉当前书之后的书籍列表
    pub books: Vec<WebSearchResult>,
}

/// 相关书查询结果（顶层 `{"modules":[…]}`）
#[derive(Debug, Clone, Serialize)]
pub struct RelatedBooksResult {
    pub modules: Vec<RelatedBooksModule>,
}

/// 配置数组单项（对齐参考版 `RelatedBooks.Definition`）
///
/// 三个字段都是可选：参考版 `Definition` 用可空类型 + GSON 反序列化，
/// 缺键/显式 null 都按未配置处理。
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RelatedBooksDefinition {
    #[serde(default)]
    pub key: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
}

/// 查询相关书（同步入口，FFI 层经阻塞线程池调用）
///
/// `book_url` — 书籍稳定主键（`books.bookUrl`）
///
/// 任何「拿不到数据」的情形都返回 `{"modules":[]}` 而不是错误：
/// 书籍/书源不在库、无 `relatedBooks` 配置、配置非法 JSON、全部模块失败、
/// 过滤后全空。真正的编程错误（JSON 序列化失败）仍上抛。
pub fn get_related_books(book_url: &str) -> LegadoResult<String> {
    let (book, source) = match load_book_and_source(book_url) {
        Ok(Some(pair)) => pair,
        Ok(None) => return empty_modules_json(),
        Err(e) => {
            // DB 未初始化/读取异常：相关书是可选内容，降级为空而非阻断信息页
            log::warn!("相关书读取书籍或书源失败，按无数据处理: {e}");
            return empty_modules_json();
        }
    };

    let definitions = match parse_definitions(
        source
            .rule_book_info
            .as_ref()
            .and_then(|rule| rule.related_books.as_deref()),
    ) {
        Some(definitions) => definitions,
        None => return empty_modules_json(),
    };

    let modules = crate::runtime::block_on(load_modules(&source, &book, definitions));
    serde_json::to_string(&RelatedBooksResult { modules }).map_err(LegadoError::Serialization)
}

/// 空结果 JSON（`{"modules":[]}`）
fn empty_modules_json() -> LegadoResult<String> {
    serde_json::to_string(&RelatedBooksResult {
        modules: Vec::new(),
    })
    .map_err(LegadoError::Serialization)
}

/// 按 bookUrl 载入书籍与其书源
///
/// 书源的取法与阅读链一致：`book.origin` 即书源 URL（本地书为 `loc_book`，
/// 查不到书源 → 调用方按无数据处理）。
fn load_book_and_source(book_url: &str) -> LegadoResult<Option<(Book, BookSource)>> {
    crate::db_state::with_database(|db| {
        let book = legado_db::BookRepository::new(db.connection()).find_by_url(book_url)?;
        let Some(book) = book else {
            return Ok(None);
        };
        let origin = book.origin.trim();
        if origin.is_empty() {
            return Ok(None);
        }
        let source = legado_db::BookSourceRepository::new(db.connection()).find_by_url(origin)?;
        Ok(source.map(|source| (book, source)))
    })
}

/// 解析 `relatedBooks` 配置数组
///
/// `None`（未配置 / 全空白）与解析失败都返回 `None`（调用方返回空结果）；
/// 解析失败额外记日志，便于书源作者排查配置错误。
fn parse_definitions(raw: Option<&str>) -> Option<Vec<RelatedBooksDefinition>> {
    let raw = raw?;
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }
    match serde_json::from_str::<Vec<RelatedBooksDefinition>>(trimmed) {
        Ok(definitions) => Some(definitions),
        Err(e) => {
            log::warn!("相关书 relatedBooks 配置解析失败，按无配置处理: {e}");
            None
        }
    }
}

/// 并发抓取各模块并按配置顺序返回（跳过失败/空模块）
async fn load_modules(
    source: &BookSource,
    book: &Book,
    definitions: Vec<RelatedBooksDefinition>,
) -> Vec<RelatedBooksModule> {
    let current_book_url = book.book_url.clone();
    let outcomes: Vec<Option<RelatedBooksModule>> =
        stream::iter(definitions.into_iter().enumerate())
            .map(|(index, definition)| {
                let source = source.clone();
                let current_book_url = current_book_url.clone();
                async move { load_module(&source, &current_book_url, index, definition).await }
            })
            .buffered(RELATED_BOOKS_CONCURRENCY)
            .collect()
            .await;

    // 顺序由 `buffered` 保证与配置一致（对齐参考版 awaitAll）
    outcomes.into_iter().flatten().collect()
}

/// 抓取单个模块；任何失败/空结果都返回 `None`（不中断其他模块）
async fn load_module(
    source: &BookSource,
    current_book_url: &str,
    index: usize,
    definition: RelatedBooksDefinition,
) -> Option<RelatedBooksModule> {
    let title = definition.title.clone().unwrap_or_default();
    let label = format!("相关书 relatedBooks[{}] {title}", index + 1);

    // 仅去首尾空白：不能删掉 JS 字符串/关键字之间的空格（对齐参考版注释）
    let url = definition.url.as_deref().map(str::trim).unwrap_or("");
    if url.is_empty() {
        log::warn!("{label}: url 为空，跳过");
        return None;
    }

    let (resolved_url, books) =
        match crate::api::explore_api::explore_books_with_resolved_url_async(source, url, 1).await {
            Ok(result) => result,
            Err(e) => {
                log::warn!("{label}: 请求或解析失败，跳过: {e}");
                return None;
            }
        };

    let filtered: Vec<WebSearchResult> = books
        .into_iter()
        .filter(|candidate| candidate.book_url != current_book_url)
        .collect();
    if filtered.is_empty() {
        // 对齐参考版 `takeIf { filtered.isNotEmpty() }`：空模块不返回
        log::info!("{label}: 过滤当前书后无结果，隐藏该模块");
        return None;
    }

    // key 缺省回退 title（参考版 `def.key ?: def.title.orEmpty()`：
    // 仅 null 才回退，空串保持空串）
    let key = definition.key.unwrap_or_else(|| title.clone());

    Some(RelatedBooksModule {
        key,
        title,
        url: url.to_string(),
        resolved_url,
        books: filtered,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_db::repository::Repository;
    use serde_json::{json, Value};
    use std::collections::HashMap;
    use std::io::{Read, Write};
    use std::sync::Arc;

    /// 回环夹具服务器：按路径返回固定 JSON 书单
    ///
    /// 未登记路径统一 404（用于「单模块失败」用例）。
    fn spawn_books_server(routes: Vec<(String, String)>) -> u16 {
        let routes: Arc<HashMap<String, String>> = Arc::new(routes.into_iter().collect());
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 相关书夹具服务器");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut buf: Vec<u8> = Vec::new();
                let mut one = [0u8; 1];
                while !buf.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut one) {
                        Ok(1) => buf.push(one[0]),
                        _ => break,
                    }
                    if buf.len() > 16 * 1024 {
                        break;
                    }
                }
                let head = String::from_utf8_lossy(&buf).to_string();
                let target = head
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .to_string();
                let path_only = target.split('?').next().unwrap_or("/").to_string();
                let (status, status_text, body) = match routes.get(&path_only) {
                    Some(body) => (200, "OK", body.clone()),
                    None => (404, "Not Found", "not found".to_string()),
                };
                let resp = format!(
                    "HTTP/1.1 {status} {status_text}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.write_all(body.as_bytes());
                let _ = stream.flush();
            }
        });
        port
    }

    /// 书单 JSON：`[{name,author,url}]`，配合 `$.books[*]` 规则解析
    fn books_body(entries: &[(&str, &str, &str)]) -> String {
        let books: Vec<Value> = entries
            .iter()
            .map(|(name, author, url)| json!({ "name": name, "author": author, "url": url }))
            .collect();
        json!({ "books": books }).to_string()
    }

    /// 播种「书源（带 relatedBooks）+ 书籍」并返回当前书 bookUrl
    fn seed(port: u16, related_books: Option<&str>, current_book_path: &str) -> String {
        seed_with_explore_url(port, related_books, None, current_book_path)
    }

    /// 同 [`seed`]，可额外配置书源 `exploreUrl`（用于证明「无配置不回退发现页」）
    fn seed_with_explore_url(
        port: u16,
        related_books: Option<&str>,
        explore_url: Option<&str>,
        current_book_path: &str,
    ) -> String {
        let source_url = format!("http://127.0.0.1:{port}");
        let book_url = format!("{source_url}{current_book_path}");

        let mut source_value = json!({
            "bookSourceUrl": source_url,
            "bookSourceName": "相关书测试源",
            "bookSourceType": 0,
            "ruleExplore": {
                "bookList": "$.books[*]",
                "name": "$.name",
                "author": "$.author",
                "bookUrl": "$.url"
            }
        });
        if let Some(related) = related_books {
            source_value["ruleBookInfo"] = json!({ "relatedBooks": related });
        }
        if let Some(explore) = explore_url {
            source_value["exploreUrl"] = json!(explore);
        }
        let source: BookSource = serde_json::from_value(source_value).expect("书源 JSON 应可解析");

        crate::db_state::with_database(|db| {
            legado_db::BookSourceRepository::new(db.connection()).insert(&source)?;
            legado_db::BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.clone(),
                name: "当前书".to_string(),
                origin: source_url.clone(),
                ..Default::default()
            })
        })
        .expect("播种书源与书籍");

        book_url
    }

    /// 调用入口并解析 JSON
    fn call(book_url: &str) -> Value {
        let raw = get_related_books(book_url).expect("入口不应抛错");
        serde_json::from_str(&raw).expect("返回应是合法 JSON")
    }

    /// 用例 1：正常路径——2 个模块各返回 3 本（含当前书），过滤后各 2 本
    #[test]
    fn returns_two_modules_with_current_book_filtered() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let current = "/book/current";
        // 先起服务器（端口确定后再播种），书单里包含当前书
        let port = spawn_books_server(vec![
            (
                "/m1/1.html".to_string(),
                books_body(&[
                    ("甲一", "作者甲", current),
                    ("甲二", "作者甲", "/book/a2"),
                    ("甲三", "作者甲", "/book/a3"),
                ]),
            ),
            (
                "/m2/1.html".to_string(),
                books_body(&[
                    ("乙一", "作者乙", "/book/b1"),
                    ("乙二", "作者乙", current),
                    ("乙三", "作者乙", "/book/b3"),
                ]),
            ),
        ]);
        let related = json!([
            { "key": "mod1", "title": "模块一", "url": "/m1/1.html" },
            // 模块二刻意省略 key：验证 key 缺省回退 title（参考版 `def.key ?: def.title`）
            { "title": "模块二", "url": "/m2/1.html" }
        ])
        .to_string();
        let book_url = seed(port, Some(&related), current);

        let value = call(&book_url);
        let modules = value["modules"].as_array().expect("modules 应是数组");
        assert_eq!(modules.len(), 2, "两个模块都应返回: {value}");

        // 顺序与配置一致
        assert_eq!(modules[0]["key"], "mod1");
        assert_eq!(modules[0]["title"], "模块一");
        assert_eq!(modules[0]["url"], "/m1/1.html");
        assert_eq!(
            modules[0]["resolvedUrl"],
            format!("http://127.0.0.1:{port}/m1/1.html"),
            "resolvedUrl 应是请求后的最终 URL"
        );
        assert_eq!(modules[1]["key"], "模块二", "缺省 key 应回退 title");

        let current_absolute = format!("http://127.0.0.1:{port}{current}");
        for module in modules {
            let books = module["books"].as_array().expect("books 应是数组");
            assert_eq!(books.len(), 2, "应过滤掉当前书: {module}");
            for book in books {
                assert_ne!(
                    book["book_url"].as_str().unwrap_or(""),
                    current_absolute,
                    "结果不得包含当前书: {module}"
                );
            }
        }
    }

    /// 用例 2：无配置（relatedBooks 为 None）→ `{"modules":[]}`
    ///
    /// 书源同时配了可用的 `exploreUrl` 且夹具能返回书：证明「无 relatedBooks
    /// 配置」不会回退到发现页（参考版语义：无配置即无相关书区块）。
    #[test]
    fn returns_empty_when_related_books_not_configured() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let port = spawn_books_server(vec![(
            "/explore/1.html".to_string(),
            books_body(&[
                ("发现书一", "作者庚", "/book/e1"),
                ("发现书二", "作者庚", "/book/e2"),
            ]),
        )]);
        let book_url = seed_with_explore_url(
            port,
            None,
            Some("/explore/{{page}}.html"),
            "/book/no-config",
        );

        let value = call(&book_url);
        assert_eq!(value["modules"].as_array().unwrap().len(), 0, "{value}");
    }

    /// 用例 3：模块 1 请求失败（404）、模块 2 正常 → 只返回模块 2
    #[test]
    fn skips_failed_module_and_keeps_others() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let port = spawn_books_server(vec![(
            "/ok/1.html".to_string(),
            books_body(&[
                ("好一", "作者丙", "/book/ok1"),
                ("好二", "作者丙", "/book/ok2"),
            ]),
        )]);
        let related = json!([
            { "key": "broken", "title": "坏模块", "url": "/missing/1.html" },
            { "key": "ok", "title": "好模块", "url": "/ok/1.html" }
        ])
        .to_string();
        let book_url = seed(port, Some(&related), "/book/failed-module");

        let value = call(&book_url);
        let modules = value["modules"].as_array().unwrap();
        assert_eq!(modules.len(), 1, "失败模块应被跳过: {value}");
        assert_eq!(modules[0]["key"], "ok");
        assert_eq!(modules[0]["books"].as_array().unwrap().len(), 2);
    }

    /// 用例 4：模块只返回当前书 → 该模块不出现
    #[test]
    fn hides_module_whose_books_are_all_current_book() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let current = "/book/self-only";
        let port = spawn_books_server(vec![(
            "/self/1.html".to_string(),
            books_body(&[("只有当前书", "作者丁", current)]),
        )]);
        let related =
            json!([{ "key": "self", "title": "自指模块", "url": "/self/1.html" }]).to_string();
        let book_url = seed(port, Some(&related), current);

        let value = call(&book_url);
        assert_eq!(
            value["modules"].as_array().unwrap().len(),
            0,
            "过滤后为空的模块不应返回: {value}"
        );
    }

    /// 用例 5：配置里有 url 为空的项 → 跳过该项，其余照常
    ///
    /// 夹具额外注册 `/`（书源根地址）：空 url 若不被显式跳过，`AnalyzeUrl`
    /// 会把它解析成书源根地址并真的发出请求、拿到书籍——本用例据此区分
    /// 「显式跳过」与「碰巧请求失败」。
    #[test]
    fn skips_definition_with_blank_url() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let port = spawn_books_server(vec![
            (
                "/".to_string(),
                books_body(&[
                    ("根一", "作者己", "/book/root1"),
                    ("根二", "作者己", "/book/root2"),
                ]),
            ),
            (
                "/valid/1.html".to_string(),
                books_body(&[("有效一", "作者戊", "/book/v1")]),
            ),
        ]);
        let related = json!([
            { "key": "blank", "title": "空 url", "url": "" },
            { "key": "valid", "title": "有效模块", "url": "/valid/1.html" }
        ])
        .to_string();
        let book_url = seed(port, Some(&related), "/book/blank-url");

        let value = call(&book_url);
        let modules = value["modules"].as_array().unwrap();
        assert_eq!(modules.len(), 1, "空 url 项应被跳过: {value}");
        assert_eq!(modules[0]["key"], "valid");
    }

    /// 用例 6：`relatedBooks` 是非法 JSON → `{"modules":[]}`，不 panic
    #[test]
    fn returns_empty_on_invalid_json_configuration() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let port = spawn_books_server(Vec::new());
        let book_url = seed(port, Some("{not-a-json-array"), "/book/bad-json");

        let value = call(&book_url);
        assert_eq!(value["modules"].as_array().unwrap().len(), 0, "{value}");
    }

    /// 用例 7（补充）：书不在库 → `{"modules":[]}`，不抛错
    #[test]
    fn returns_empty_when_book_missing() {
        let _lock = crate::test_support::lock_global_store();
        let _db = crate::db_state::ensure_test_db();

        let value = call("http://127.0.0.1:9/book/not-in-db");
        assert_eq!(value["modules"].as_array().unwrap().len(), 0, "{value}");
    }
}
