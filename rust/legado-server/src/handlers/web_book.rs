//! WebBook 处理器 — 书源规则驱动的完整搜索链路 API
//!
//! 提供以下端点：
//! - POST /api/webbook/search   — 搜索书籍
//! - POST /api/webbook/info     — 获取书籍详情
//! - POST /api/webbook/chapters — 获取章节列表
//! - POST /api/webbook/content  — 获取章节内容
//!
//! [P5-1 链 b] 抓取本体改用共享 crate `legado-fetcher`（与 App/ffi 主链路
//! 同一 `RealBookSourceFetcher` 实现）：本文件此前的本地阉割分叉版（无
//! rate limit 门控/webView 通道/charset 三级解码/重定向 final_url/data: URI
//! 等）已整体删除。宿主注入面经 [`server_deps`] 组装：进程级限速注册表
//! （REST 端点获得源级限速门控的关键）+ server 原构造语义的 HTTP 客户端。
//! `login_header`/`book_variable`/`source_context` 起步不注入（方案登记的
//! 「行为无损起点」）。
//!
//! [P5-1 链 b2] 四个 handler 改调共享 fetcher 的**自由入口**
//! （`legado_fetcher::web_book::webbook_search/info/chapters/content`），
//! 与 App/ffi 主链路完整对齐。引擎入口（[`build_engine`]）不可达的路径
//! 由此在 REST 上打通：
//! - mainJs JS 书源分派（JS 源经 REST 可用；quickjs 档真执行）；
//! - `begin_book_flow` 流程生命周期（flow scope 写入进程级单槽）与详情/
//!   目录阶段的 book 元信息、章节→book 缓存记录；
//! - 详情/目录的 DB `books.variable` `{{key}}` 变量链**落点**——但 server
//!   注入面 `book_variable` 保持 None（server 侧未接 DB 书籍变量缓存模块），
//!   该链在 server 无值可读，维持优雅降级（见 [`server_deps`] 边界说明）。
//!
//! [`build_engine`] 保留：reader/audio/toc_update 兄弟 handler 仍经引擎入口
//! 复用同一注入面。

use std::sync::{Arc, OnceLock};

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::models::BookSource;
use legado_core::web_book::{WebBookEngine, WebBookInfo, WebChapter, WebSearchResult};
use legado_core::{LegadoError, LegadoResult};
use legado_fetcher::deps::FetcherDeps;
use legado_fetcher::rate_limit::RateLimiterRegistry;
use legado_net::{LegadoClient, LegadoClientConfig};

/// 共享 fetcher 类型（P5-1 链 b）：`toc_update` 等兄弟模块经本路径引用
/// （与 ffi 侧 `pub use legado_fetcher::web_book::RealBookSourceFetcher` 同款收口）
pub(crate) use legado_fetcher::web_book::RealBookSourceFetcher;

// ─── 请求/响应类型 ─────────────────────────────────────────────────────────────

/// 搜索请求体
#[derive(Debug, Deserialize)]
pub struct WebBookSearchRequest {
    /// 书源 JSON（完整 BookSource 对象）
    pub source: BookSource,
    /// 搜索关键词
    pub query: String,
    /// 页码（从 1 开始），默认为 1
    pub page: Option<i32>,
}

/// 书籍详情请求体
#[derive(Debug, Deserialize)]
pub struct WebBookInfoRequest {
    /// 书源 JSON
    pub source: BookSource,
    /// 书籍详情页 URL
    pub book_url: String,
}

/// 章节列表请求体
#[derive(Debug, Deserialize)]
pub struct WebBookChaptersRequest {
    /// 书源 JSON
    pub source: BookSource,
    /// 书籍详情页 URL
    pub book_url: String,
}

/// 章节内容请求体
#[derive(Debug, Deserialize)]
pub struct WebBookContentRequest {
    /// 书源 JSON
    pub source: BookSource,
    /// 章节信息（至少需要 url 字段）
    pub chapter: WebChapter,
}

/// 搜索响应
#[derive(Debug, Serialize)]
pub struct WebBookSearchResponse {
    pub results: Vec<WebSearchResult>,
    pub total: usize,
    pub query: String,
    pub page: i32,
}

/// 章节列表响应
#[derive(Debug, Serialize)]
pub struct WebBookChaptersResponse {
    pub chapters: Vec<WebChapter>,
    pub total: usize,
}

/// 章节内容响应
#[derive(Debug, Serialize)]
pub struct WebBookContentResponse {
    pub content: String,
    pub chapter_url: String,
    pub chapter_title: String,
}

// ─── 宿主注入面（P5-1 链 b：共享 fetcher 接入） ───────────────────────────────────

/// 进程级限速注册表（对齐 ffi `api::source_rate_limit::registry`）：
/// 跨请求保持各书源 `concurrentRate` 窗口状态。旧 server 本地分叉版
/// 零限速，切换后 REST 端点获得与 App 主链路一致的源级限速门控。
///
/// [P2 互认] ffi 侧另有一份同名 static（`api::source_rate_limit::REGISTRY`）。
/// ffi 与 server 可同进程并存（同一进程同时启用 ffi 抓取路径与 REST 端点），
/// 但两者各持独立 static registry，本批不做共享单例收敛；源编辑保存在各自
/// 保存路径刷新各自 registry（server `handlers/source_update.rs` 批量导入；
/// ffi `api/source.rs` add/update/import；REST create/update 请求体无
/// concurrentRate，未接线）。REST/FFI 同时抓取同一源时窗口仍会分叉（弱于
/// 真单例）——收敛为单例（注册表句柄经共享 crate 静态化或宿主注入同一份
/// Arc）留待后续裁决。
static RATE_LIMITER: OnceLock<Arc<RateLimiterRegistry>> = OnceLock::new();

pub(crate) fn rate_limiter() -> Arc<RateLimiterRegistry> {
    Arc::clone(RATE_LIMITER.get_or_init(|| Arc::new(RateLimiterRegistry::new())))
}

/// 书源保存成功后的限速配置刷新入口（当前接线：`source_update` 批量导入）
///
/// 只刷新既有 limiter（空/"0"/非法 rate 与未注册 key 均不改动），写库成功后
/// 方可调用；写库失败不得调用（避免未落库的配置提前生效）。
pub(crate) fn refresh_source_rate_limit(source_url: &str, concurrent_rate: &str) {
    rate_limiter().update(source_url, concurrent_rate);
}

/// 组装 server 宿主注入面
///
/// - `client`：按 server 原构造语义新建 `LegadoClientConfig::default()`
///   客户端（原 P2-A 后为单次构造 + panic；本次保留单次构造语义但
///   改为错误上报 → handler 500，不 panic）；
/// - `rate_limiter`：进程级注册表（见 [`rate_limiter`]）；
/// - `login_header` / `book_variable` / `source_context`：起步不注入
///   （方案登记的「行为无损起点」：server 侧无等价的登录头/书籍变量
///   DB 缓存模块与书源 JS setup 构造器），链 b2 改走自由入口后依旧保持：
///   - `login_header`（经 `parse_source_headers`）与 `source_context`
///     （经 setup 脚本）在共享 fetcher 路径即时生效——None 即不注入；
///   - `book_variable` 是自由入口详情/目录 `{{key}}` 变量链的落点：
///     **JS 书源分派已可用（mainJs 不依赖该闭包）**，而 DB 变量链因
///     server 未接书籍变量缓存模块保持 None（无值可读 → `@put` 导出
///     兜底，行为=不注入），后续接 DB 时在此补闭包即可。
fn server_deps() -> LegadoResult<FetcherDeps> {
    let client = LegadoClient::new(LegadoClientConfig::default())
        .map_err(|e| LegadoError::Internal(format!("LegadoClient init: {e}")))?;
    Ok(FetcherDeps::new(client).with_rate_limiter(rate_limiter()))
}

/// 构建 WebBookEngine（共享 fetcher + server 注入面）
///
/// [P5-1 链 b2] 保留给 reader/audio/toc_update 兄弟 handler 的引擎入口调用
/// （4 个 webbook handler 已改走自由入口，不经本函数）。
///
/// 出错上报（而非旧版 `expect` panic）：与 ffi 侧
/// `web_book::build_engine() -> LegadoResult<_>` 同形态，构造失败由
/// 调用方映射为 5xx。
pub(crate) fn build_engine() -> LegadoResult<WebBookEngine<RealBookSourceFetcher>> {
    Ok(legado_fetcher::web_book::build_engine(server_deps()?))
}

// ─── 处理器函数（P5-1 链 b2：自由入口直连） ────────────────────────────────────

/// POST /api/webbook/search — 搜索书籍
///
/// [P5-1 链 b2] 改走自由入口（`source` 序列化为 `source_json` 传入）：
/// JS 书源（mainJs）经编排器分派，规则书源在自由入口内委托
/// `WebBookEngine::search`（前置校验语义不变：空 searchUrl/空关键词
/// → Parser 400）。响应 schema 不变。
pub async fn search_books(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookSearchRequest>,
) -> Result<Json<WebBookSearchResponse>, ApiError> {
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    let page = req.page.unwrap_or(1);
    // 自由入口返回 `Vec<WebSearchResult>` JSON 数组字符串（与 ffi 同形态）
    let raw =
        legado_fetcher::web_book::webbook_search(server_deps()?, &source_json, &req.query, page)
            .await?;
    let results: Vec<WebSearchResult> =
        serde_json::from_str(&raw).map_err(LegadoError::Serialization)?;
    let total = results.len();
    Ok(Json(WebBookSearchResponse {
        results,
        total,
        query: req.query,
        page,
    }))
}

/// POST /api/webbook/info — 获取书籍详情
///
/// [P5-1 链 b2] 改走自由入口：JS 书源分派 + 规则源变量链落点
/// （`book_variable` 注入为 None → 变量表为空，见 [`server_deps`] 边界）。
/// 响应 schema 不变（`WebBookInfo`）。
pub async fn get_book_info(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookInfoRequest>,
) -> Result<Json<WebBookInfo>, ApiError> {
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    // 自由入口返回 `WebBookInfo` JSON 字符串（与 ffi 同形态）
    let raw =
        legado_fetcher::web_book::webbook_info(server_deps()?, &source_json, &req.book_url).await?;
    let info: WebBookInfo = serde_json::from_str(&raw).map_err(LegadoError::Serialization)?;
    Ok(Json(info))
}

/// POST /api/webbook/chapters — 获取章节列表
///
/// [P5-1 链 b2] 改走自由入口：JS 书源分派 + 规则源变量链/缓存记录。
/// REST 请求体无 `tocUrl`/`bookName` 字段 → 传空串（自由入口内部 trim
/// 空转 None，目录地址由 `book_url` 经详情/init→tocUrl 规则重推，与
/// 链 b 引擎入口语义一致）。响应 schema 不变（`WebBookChaptersResponse`）。
pub async fn get_chapters(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookChaptersRequest>,
) -> Result<Json<WebBookChaptersResponse>, ApiError> {
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    // 自由入口返回 `Vec<WebChapter>` JSON 数组字符串（与 ffi 同形态）
    let raw = legado_fetcher::web_book::webbook_chapters(
        server_deps()?,
        &source_json,
        &req.book_url,
        "",
        "",
    )
    .await?;
    let chapters: Vec<WebChapter> =
        serde_json::from_str(&raw).map_err(LegadoError::Serialization)?;
    let total = chapters.len();
    Ok(Json(WebBookChaptersResponse { chapters, total }))
}

/// POST /api/webbook/content — 获取章节内容
///
/// [P5-1 链 b2] 改走自由入口：JS 书源分派（`chapter` 整体序列化为
/// `chapter_json`，含 index/title/url/is_vip；规则源仍经
/// `WebBookEngine::get_content` 的正文规则/空 URL 校验）。响应 schema
/// 不变（`WebBookContentResponse`）。
pub async fn get_content(
    State(_state): State<Arc<AppState>>,
    Json(req): Json<WebBookContentRequest>,
) -> Result<Json<WebBookContentResponse>, ApiError> {
    let chapter_url = req.chapter.url.clone();
    let chapter_title = req.chapter.title.clone();
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    let chapter_json = serde_json::to_string(&req.chapter).map_err(LegadoError::Serialization)?;
    let content =
        legado_fetcher::web_book::webbook_content(server_deps()?, &source_json, &chapter_json)
            .await?;
    Ok(Json(WebBookContentResponse {
        content,
        chapter_url,
        chapter_title,
    }))
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::{Method, Request, StatusCode};
    use serde_json::{json, Value};
    use std::sync::atomic::AtomicBool;
    use tokio::sync::Mutex;
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::state::AppState;

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
        })
    }

    fn make_source_json() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: Some("https://example.com/search?q={key}".to_string()),
            rule_content: Some(legado_core::models::rule::ContentRule {
                content: Some("css(.content).html".to_string()),
                ..legado_core::models::rule::ContentRule::default()
            }),
            ..BookSource::default()
        })
        .unwrap()
    }

    /// 无 searchUrl 的书源 → 引擎前置校验触发 Parser 错误（400）
    fn make_source_no_search_url() -> String {
        serde_json::to_string(&BookSource {
            book_source_url: "https://example.com".to_string(),
            book_source_name: "测试书源".to_string(),
            search_url: None,
            ..BookSource::default()
        })
        .unwrap()
    }

    /// [P5-1 链 b] 注入面装配钉死：client 可构造（不 panic）、限速注册表
    /// 进程级共享（跨 build/每请求调用同一 Arc——限速窗口状态跨请求保持的
    /// 关键）、启动期未注入的宿主闭包保持 None（行为无损起点）。
    #[test]
    fn test_server_deps_shares_process_rate_limiter() {
        let a = server_deps().expect("server deps 可构造（默认客户端）");
        let b = server_deps().expect("server deps 可构造（默认客户端）");
        assert!(
            Arc::ptr_eq(&a.rate_limiter, &b.rate_limiter),
            "限速注册表必须进程级共享（否则每个请求重置窗口 = 无限速）"
        );
        assert!(a.login_header.is_none(), "启动期登录头闭包应为 None");
        assert!(a.book_variable.is_none(), "启动期书籍变量闭包应为 None");
        assert!(a.source_context.is_none(), "启动期书源 setup 闭包应为 None");
    }

    #[tokio::test]
    async fn test_webbook_search_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        // 使用真实书源配置发起搜索（可能因网络不可达返回 502）
        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "query": "三体",
            "page": 1
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502 (BAD_GATEWAY)
        assert!(
            resp.status() == StatusCode::OK
                || resp.status() == StatusCode::BAD_GATEWAY
                || resp.status() == StatusCode::INTERNAL_SERVER_ERROR,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_search_no_search_url() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_no_search_url()).unwrap(),
            "query": "测试",
            "page": 1
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // [P5-1 链 b2 期望对齐] 自由入口路径下仍为 400：该源无 mainJs
        // （build_js_orchestrator 返回 None）→ 规则源分支委托
        // `WebBookEngine::search`，空 searchUrl 由引擎前置校验拦截
        // （`LegadoError::Parser("搜索url不能为空")` → 400）。链 b 引擎入口
        // 与链 b2 自由入口的该校验语义一致，断言无需翻转、继续钉死。
        assert_eq!(
            resp.status(),
            StatusCode::BAD_REQUEST,
            "无 searchUrl 应返回 400 Parser（自由入口规则分支委托引擎前置校验）"
        );
    }

    #[tokio::test]
    async fn test_webbook_info_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "book_url": "https://example.com/book/1"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/info")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_chapters_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "book_url": "https://example.com/book/1"
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/chapters")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_content_endpoint() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "chapter": {
                "index": 0,
                "title": "第一章",
                "url": "https://example.com/ch/1",
                "is_vip": false
            }
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/content")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 真实实现：网络可达时 200，不可达时 502
        assert!(
            resp.status() == StatusCode::OK || resp.status() == StatusCode::BAD_GATEWAY,
            "unexpected status: {}",
            resp.status()
        );
    }

    #[tokio::test]
    async fn test_webbook_search_missing_query_returns_bad_request() {
        let state = make_test_state();
        let app = create_router(state);

        // 发送不合法 JSON（缺少 query 字段）
        let body = serde_json::to_string(&json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap()
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // Axum 反序列化失败 → 422 Unprocessable Entity
        assert_eq!(resp.status(), StatusCode::UNPROCESSABLE_ENTITY);
    }

    // ─── [P5-1 链 b2] 自由入口接入的行为/并发回归 ─────────────────────────────

    /// 并发探测用回环 mock 搜索服务：`/search/{src}?q=…` 返回该源独有的
    /// 书名「{src}-{key}」，供「并发请求结果不串源」断言。返回 base URL
    /// （随机端口，测试结束随进程/任务回收）。
    async fn start_mock_search_server() -> String {
        use axum::extract::{Path, Query};
        use axum::response::Html;
        use axum::routing::get;
        use std::collections::HashMap;

        async fn mock_search(
            Path(src): Path<String>,
            Query(params): Query<HashMap<String, String>>,
        ) -> Html<String> {
            let key = params.get("q").cloned().unwrap_or_default();
            Html(format!(
                "<html><body>\
                 <div class=\"result\">\
                 <span class=\"name\">{src}-{key}</span>\
                 <span class=\"author\">作者{src}</span>\
                 <a class=\"book\" href=\"/book/{src}\">详情</a>\
                 </div></body></html>"
            ))
        }

        let app = axum::Router::new().route("/search/{src}", get(mock_search));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("mock 搜索服务可绑定回环端口");
        let addr = listener.local_addr().expect("mock 服务地址");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        format!("http://{addr}")
    }

    /// 构造指向 mock 服务的规则书源（src_id 决定 mock 响应中的专属标记）
    fn make_mock_source(base: &str, src_id: u32) -> Value {
        json!({
            "bookSourceUrl": format!("{base}/src{src_id}"),
            "bookSourceName": format!("并发源{src_id}"),
            "searchUrl": format!("{base}/search/{src_id}?q={{key}}"),
            "ruleSearch": {
                "bookList": "class.result",
                "name": "class.name@text",
                "author": "class.author@text",
                "bookUrl": "class.book@href"
            }
        })
    }

    /// [P5-1 链 b2] flow scope 并发风险探测：4 路并发（不同书源）调 REST
    /// `/api/webbook/search`。自由入口每请求执行 `begin_book_flow`（写入
    /// 进程级单槽 flow scope：后启动者清先启动者的会话键前缀），本用例在
    /// 单槽竞态下断言各请求仍**各自完整可达**：
    /// - 全部 200，且各响应 results[0].name = 本源专属标记（无跨源串数据）、
    ///   total 与本源 mock 响应一致；
    /// - 无 panic（tokio 任务 join 成功）。
    ///
    /// 竞态结论说明：`set_flow_scope` 为进程级单槽（与上游 WebBook.kt 全局
    /// 流程键同构，server 多源搜索此前即以警告接受）。两流程真并行且都用
    /// 会话变量（`lgflow::*`）时，后启动者会清掉先启动者的会话键——本测试
    /// 的规则源不写会话变量，故竞态不产生跨源数据串扰；断言不做放宽
    /// （不允许结果缺失/串名），仅以此钉死「单槽竞态下 REST 结果完整性」。
    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn test_webbook_search_concurrent_requests_flow_scope_no_crosstalk() {
        let base = start_mock_search_server().await;
        let state = make_test_state();
        let app = create_router(state);

        let mut handles = Vec::new();
        for src_id in 0..4u32 {
            let app = app.clone();
            let base = base.clone();
            handles.push(tokio::spawn(async move {
                let body = serde_json::to_string(&json!({
                    "source": make_mock_source(&base, src_id),
                    "query": "并发",
                    "page": 1
                }))
                .unwrap();
                let resp = app
                    .oneshot(
                        Request::builder()
                            .method(Method::POST)
                            .uri("/api/webbook/search")
                            .header("Content-Type", "application/json")
                            .body(Body::from(body))
                            .unwrap(),
                    )
                    .await
                    .expect("oneshot 调用成功");
                (src_id, resp)
            }));
        }

        for handle in handles {
            let (src_id, resp) = handle.await.expect("并发搜索任务不得 panic");
            assert_eq!(
                resp.status(),
                StatusCode::OK,
                "源 {src_id} 并发搜索应 200（flow scope 单槽竞态下仍完整可达）"
            );
            let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .expect("读取响应体");
            let body: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
            assert_eq!(body["total"], 1, "源 {src_id} 结果数");
            // 响应 schema 契约（链 b2 后未变）：results/total/query/page 字段齐备
            assert_eq!(body["query"], "并发", "源 {src_id} 响应回显 query");
            assert_eq!(body["page"], 1, "源 {src_id} 响应回显 page");
            assert_eq!(
                body["results"][0]["name"],
                format!("{src_id}-并发"),
                "源 {src_id} 结果必须来自本源 mock 响应（无跨源串数据）"
            );
        }
    }

    /// [P5-1 链 b2] REST 端点获得 mainJs JS 书源分派（链 b 引擎入口不可达）：
    /// JS 源（searchUrl 为空、仅 mainJs）经 `/api/webbook/search` 返回脚本
    /// 结果，证明自由入口的 JS 分支在 server 侧可用。仅 quickjs 档真执行
    /// （默认档 JsSourceEngine 为 stub，不产生结果）。
    #[cfg(feature = "quickjs")]
    #[tokio::test]
    async fn test_webbook_search_js_source_dispatch_via_rest() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "source": {
                "bookSourceUrl": "https://js-rest.example.com",
                "bookSourceName": "JS 分派测试源",
                "mainJs": "function search(key, page) { return JSON.stringify([{name: 'js-' + key, author: '作者', bookUrl: 'https://js-rest.example.com/book/1'}]); }"
            },
            "query": "三体",
            "page": 1
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "JS 书源经 REST 应走 mainJs 分派并成功"
        );
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("读取响应体");
        let body: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
        assert_eq!(body["total"], 1, "JS 源搜索结果数");
        assert_eq!(body["results"][0]["name"], "js-三体", "JS mainJs 返回值");
        assert_eq!(
            body["results"][0]["source_url"],
            "https://js-rest.example.com",
            "JS 结果 source_url 应回填书源 URL"
        );
    }
}
