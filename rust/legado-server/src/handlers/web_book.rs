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
//! 等）已整体删除。
//!
//! [P5-1 链 b2] 四个 handler 改调共享 fetcher 的**自由入口**
//! （`legado_fetcher::web_book::webbook_search/info/chapters/content`），
//! 与 App/ffi 主链路完整对齐。引擎入口（[`build_engine`]）不可达的路径
//! 由此在 REST 上打通：
//! - mainJs JS 书源分派（JS 源经 REST 可用；quickjs 档真执行）；
//! - `begin_book_flow` 流程生命周期（flow scope 写入进程级单槽）与详情/
//!   目录阶段的 book 元信息、章节→book 缓存记录。
//!
//! [P5 尾项] 宿主注入面 [`server_deps`] 三闭包全量接入 AppState DB（与
//! ffi `ffi_deps` 同语义、同缓存键口径，数据面为 server 自身 DB 单例）：
//! - `login_header`：`caches` 表键 `loginHeader_<书源URL>`，请求经
//!   `parse_source_headers` 合并登录头；
//! - `book_variable`：`books.variable`（`find_by_url` → `originBookUrl`
//!   反查两路，同 ffi `db_book_variable`），详情/目录 `{{key}}` 变量链
//!   从「无值可读」变为可读用户持久化变量；
//! - `source_context`：setup 脚本（共享 [`legado_fetcher::source_setup`]
//!   生成），宿主数据取同一 DB 的 `infoMap_<书源URL>` / 登录缓存键，
//!   书源 JS 上下文（source/cookie/loginUrl/header 规则）对 REST 请求生效。
//!
//! [`build_engine`] 保留：reader/audio/toc_update 兄弟 handler 亦经引擎入口
//! 复用同一注入面（已接入 state）。

use std::sync::{Arc, OnceLock};

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::models::BookSource;
use legado_core::web_book::{WebBookEngine, WebBookInfo, WebChapter, WebSearchResult};
use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookRepository, CacheRepository};
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
/// 保存路径刷新各自 registry（server `handlers/source_update.rs` 批量导入与
/// REST `/api/sources` create/update；ffi `api/source.rs` add/update/import）。
/// REST/FFI 同时抓取同一源时窗口仍会分叉（弱于真单例）——收敛为单例（注册表
/// 句柄经共享 crate 静态化或宿主注入同一份 Arc）留待后续裁决。
static RATE_LIMITER: OnceLock<Arc<RateLimiterRegistry>> = OnceLock::new();

pub(crate) fn rate_limiter() -> Arc<RateLimiterRegistry> {
    Arc::clone(RATE_LIMITER.get_or_init(|| Arc::new(RateLimiterRegistry::new())))
}

/// 书源保存成功后的限速配置刷新入口（接线：`source_update` 批量导入与
/// REST `/api/sources` create/update）
///
/// 走 [`RateLimiterRegistry::refresh`] 的保存侧分发：空 / `"0"`（忽略首尾
/// 空白）→ 移除既有 limiter（对齐原版「空即不限流」）；合法 rate → 原位
/// 刷新既有 limiter；非法 rate 与未注册 key → 不改动/不预创建。写库成功后
/// 方可调用；写库失败不得调用（避免未落库的配置提前生效）。
pub(crate) fn refresh_source_rate_limit(source_url: &str, concurrent_rate: &str) {
    rate_limiter().refresh(source_url, concurrent_rate);
}

/// 同步读取 AppState DB（宿主注入闭包的执行面）
///
/// `FetcherDeps` 闭包是同步签名，不能 `.await` tokio Mutex。分级策略：
/// 1. 快路径 `try_lock`：REST handler 自身「查完即放」后才调 fetcher，绝大多数
///    调用零等待命中；
/// 2. 锁被并发 handler 持有时，多线程 runtime（生产 `#[tokio::main]` 默认档）
///    转入 `block_in_place` 阻塞等待——不阻塞其它 worker，语义=正确读到库值；
/// 3. current_thread runtime（`#[tokio::test]` 默认档）被持有时不等待
///    （持锁任务无法推进，等待即死锁），返回 `None` 优雅降级=无值可读。
///
/// 调用纪律（code-reviewer P2-1 禁令，违反会死锁/panic，勿移除）：
/// - **持有 `state.db` guard 的任务内不得进入 fetcher/webbook 链**——同任务
///   重入会经 `blocking_lock` 等待自己持有的锁，多线程档永久挂死；
/// - **不得在 `Runtime::block_on` 根 future 直调 webbook 链**——该线程无
///   worker ctx，`block_in_place` 直通不清 entered 标志，随后 `blocking_lock`
///   无法进入 blocking region → panic（tokio 1.53.1 `worker.rs`/`block_on.rs`）。
///   当前全部接线点均为 axum handler/MT worker/spawn_blocking，不可达此两态。
fn with_state_db<T>(
    state: &AppState,
    f: impl FnOnce(&legado_db::Database) -> Option<T>,
) -> Option<T> {
    if let Ok(guard) = state.db.try_lock() {
        return f(&guard);
    }
    let multi_thread = tokio::runtime::Handle::try_current()
        .map(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread)
        .unwrap_or(false);
    if multi_thread {
        return tokio::task::block_in_place(|| f(&state.db.blocking_lock()));
    }
    None
}

/// 组装 server 宿主注入面
///
/// - `client`：按 server 原构造语义新建 `LegadoClientConfig::default()`
///   客户端（原 P2-A 后为单次构造 + panic；本次保留单次构造语义但
///   改为错误上报 → handler 500，不 panic）；
/// - `rate_limiter`：进程级注册表（见 [`rate_limiter`]）；
/// - `login_header`：按书源 URL 查 `caches` 表 `loginHeader_<url>`（与 ffi
///   `source_login_cache::get_login_header` 同键口径）；
/// - `book_variable`：按书籍取址点查 `books.variable`（`find_by_url` 未命中
///   再按 `originBookUrl` 反查，与 ffi `db_book_variable` 逐行同语义）；
/// - `source_context`：按书源生成 JS setup 脚本（共享
///   [`legado_fetcher::source_setup`]），宿主数据取同一 DB 的
///   `infoMap_<url>` / `loginHeader_<url>` / `userInfo_<url>` 缓存键
///   （与 ffi `explore_info_map` / `source_login_cache` 同键）。
///
/// 三闭包经 [`with_state_db`] 同步读 AppState DB（`Arc<AppState>` 捕获，
/// 调用时点取库值而非装配时快照）。
fn server_deps(state: &Arc<AppState>) -> LegadoResult<FetcherDeps> {
    let client = LegadoClient::new(LegadoClientConfig::default())
        .map_err(|e| LegadoError::Internal(format!("LegadoClient init: {e}")))?;

    let login_header_state = Arc::clone(state);
    let book_variable_state = Arc::clone(state);
    let source_context_state = Arc::clone(state);

    Ok(FetcherDeps::new(client)
        .with_rate_limiter(rate_limiter())
        .with_login_header(Arc::new(move |source_url: &str| {
            let key = format!("loginHeader_{source_url}");
            with_state_db(&login_header_state, |db| {
                CacheRepository::new(db.connection())
                    .get(&key)
                    .ok()
                    .flatten()
            })
        }))
        .with_book_variable(Arc::new(move |book_url: &str| {
            with_state_db(&book_variable_state, |db| {
                let repo = BookRepository::new(db.connection());
                let found = match repo.find_by_url(book_url).ok()? {
                    Some(book) => Some(book),
                    None => repo.find_by_origin_book_url(book_url).ok()?,
                };
                found.and_then(|b| b.variable)
            })
        }))
        .with_source_context(Arc::new(move |source: &BookSource| {
            let tag = source.book_source_url.clone();
            with_state_db(&source_context_state, |db| {
                let repo = CacheRepository::new(db.connection());
                let info_map = repo
                    .get(&format!("infoMap_{tag}"))
                    .ok()
                    .flatten()
                    .and_then(|json| {
                        serde_json::from_str::<std::collections::HashMap<String, String>>(&json)
                            .ok()
                    })
                    .unwrap_or_default();
                let login_header = repo.get(&format!("loginHeader_{tag}")).ok().flatten();
                let login_info = repo.get(&format!("userInfo_{tag}")).ok().flatten();
                legado_fetcher::source_setup::book_source_js_setup_script(
                    source,
                    &info_map,
                    login_header.as_deref(),
                    login_info.as_deref(),
                )
                .ok()
            })
        })))
}

/// 构建 WebBookEngine（共享 fetcher + server 注入面）
///
/// [P5-1 链 b2] 保留给 reader/audio/toc_update 兄弟 handler 的引擎入口调用
/// （4 个 webbook handler 已改走自由入口，不经本函数）。
///
/// [P5 尾项] 注入面含 AppState DB 闭包 → 需传入请求级 state。
///
/// 出错上报（而非旧版 `expect` panic）：与 ffi 侧
/// `web_book::build_engine() -> LegadoResult<_>` 同形态，构造失败由
/// 调用方映射为 5xx。
pub(crate) fn build_engine(
    state: &Arc<AppState>,
) -> LegadoResult<WebBookEngine<RealBookSourceFetcher>> {
    Ok(legado_fetcher::web_book::build_engine(server_deps(state)?))
}

// ─── 处理器函数（P5-1 链 b2：自由入口直连） ────────────────────────────────────

/// POST /api/webbook/search — 搜索书籍
///
/// [P5-1 链 b2] 改走自由入口（`source` 序列化为 `source_json` 传入）：
/// JS 书源（mainJs）经编排器分派，规则书源在自由入口内委托
/// `WebBookEngine::search`（前置校验语义不变：空 searchUrl/空关键词
/// → Parser 400）。响应 schema 不变。
pub async fn search_books(
    State(state): State<Arc<AppState>>,
    Json(req): Json<WebBookSearchRequest>,
) -> Result<Json<WebBookSearchResponse>, ApiError> {
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    let page = req.page.unwrap_or(1);
    // 自由入口返回 `Vec<WebSearchResult>` JSON 数组字符串（与 ffi 同形态）
    let raw = legado_fetcher::web_book::webbook_search(
        server_deps(&state)?,
        &source_json,
        &req.query,
        page,
    )
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
/// （[P5 尾项] `book_variable` 已接 AppState DB，用户持久化变量可读；
/// 无书行/空值仍回退 `@put` 导出兜底）。
/// 响应 schema 不变（`WebBookInfo`）。
pub async fn get_book_info(
    State(state): State<Arc<AppState>>,
    Json(req): Json<WebBookInfoRequest>,
) -> Result<Json<WebBookInfo>, ApiError> {
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    // 自由入口返回 `WebBookInfo` JSON 字符串（与 ffi 同形态）
    let raw =
        legado_fetcher::web_book::webbook_info(server_deps(&state)?, &source_json, &req.book_url)
            .await?;
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
    State(state): State<Arc<AppState>>,
    Json(req): Json<WebBookChaptersRequest>,
) -> Result<Json<WebBookChaptersResponse>, ApiError> {
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    // 自由入口返回 `Vec<WebChapter>` JSON 数组字符串（与 ffi 同形态）
    let raw = legado_fetcher::web_book::webbook_chapters(
        server_deps(&state)?,
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
    State(state): State<Arc<AppState>>,
    Json(req): Json<WebBookContentRequest>,
) -> Result<Json<WebBookContentResponse>, ApiError> {
    let chapter_url = req.chapter.url.clone();
    let chapter_title = req.chapter.title.clone();
    let source_json = serde_json::to_string(&req.source).map_err(LegadoError::Serialization)?;
    let chapter_json = serde_json::to_string(&req.chapter).map_err(LegadoError::Serialization)?;
    let content = legado_fetcher::web_book::webbook_content(
        server_deps(&state)?,
        &source_json,
        &chapter_json,
    )
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

    /// [P5-1 链 b + P5 尾项] 注入面装配钉死：client 可构造（不 panic）、
    /// 限速注册表进程级共享（跨 build/每请求调用同一 Arc——限速窗口状态跨
    /// 请求保持的关键）、三宿主闭包全量接入（AppState DB 读）。
    #[test]
    fn test_server_deps_shares_process_rate_limiter_and_injects_host_closures() {
        let state = make_test_state();
        let a = server_deps(&state).expect("server deps 可构造（默认客户端）");
        let b = server_deps(&state).expect("server deps 可构造（默认客户端）");
        assert!(
            Arc::ptr_eq(&a.rate_limiter, &b.rate_limiter),
            "限速注册表必须进程级共享（否则每个请求重置窗口 = 无限速）"
        );
        assert!(a.login_header.is_some(), "登录头闭包应已注入（DB 读）");
        assert!(a.book_variable.is_some(), "书籍变量闭包应已注入（DB 读）");
        assert!(a.source_context.is_some(), "书源 setup 闭包应已注入");
    }

    /// [P5 尾项] `login_header_for`：读 DB `caches` 表 `loginHeader_<url>`
    /// 键（与 ffi `source_login_cache::get_login_header` 同键）；未命中 →
    /// None 优雅降级。闭包按调用时点读库（装配后播种也可读到）。
    #[tokio::test]
    async fn test_server_deps_login_header_from_db() {
        let state = make_test_state();
        let deps = server_deps(&state).expect("server deps");
        assert!(
            deps.login_header_for("https://login-unseeded.example.com")
                .is_none(),
            "未种数据的书源应无登录头（优雅降级）"
        );
        {
            let db = state.db.lock().await;
            CacheRepository::new(db.connection())
                .put(
                    "loginHeader_https://login.example.com",
                    r#"{"X-Login-Token":"secret"}"#,
                    0,
                )
                .expect("种登录头");
        }
        assert_eq!(
            deps.login_header_for("https://login.example.com")
                .as_deref(),
            Some(r#"{"X-Login-Token":"secret"}"#),
            "闭包应读到装配后种入的登录头（调用时点取库，非装配快照）"
        );
    }

    /// [P5 尾项] `book_variable_for`：读 `books.variable`；未换源书直查
    /// bookUrl，换源书按 `originBookUrl` 反查（与 ffi `db_book_variable`
    /// 两路逐行同语义）；无行/空值 → None（deps 层再过滤空白串）。
    #[tokio::test]
    async fn test_server_deps_book_variable_from_db() {
        use legado_db::repository::Repository;

        let state = make_test_state();
        let deps = server_deps(&state).expect("server deps");
        {
            let db = state.db.lock().await;
            let repo = BookRepository::new(db.connection());
            repo.insert(&legado_core::models::Book {
                book_url: "https://book-variable.example.com/1".to_string(),
                name: "变量书".to_string(),
                author: "作者".to_string(),
                variable: Some(r#"{"custom":"db-val"}"#.to_string()),
                ..legado_core::models::Book::default()
            })
            .expect("插入未换源书");
            repo.insert(&legado_core::models::Book {
                book_url: "https://old-source.example.com/1".to_string(),
                name: "换源书".to_string(),
                author: "作者".to_string(),
                variable: Some(r#"{"custom":"switched"}"#.to_string()),
                origin_book_url: "https://book-variable.example.com/switched".to_string(),
                ..legado_core::models::Book::default()
            })
            .expect("插入换源书");
            repo.insert(&legado_core::models::Book {
                book_url: "https://book-variable.example.com/empty".to_string(),
                name: "空变量书".to_string(),
                author: "作者".to_string(),
                variable: Some("   ".to_string()),
                ..legado_core::models::Book::default()
            })
            .expect("插入空变量书");
        }
        assert_eq!(
            deps.book_variable_for("https://book-variable.example.com/1")
                .as_deref(),
            Some(r#"{"custom":"db-val"}"#),
            "未换源书直查 bookUrl"
        );
        assert_eq!(
            deps.book_variable_for("https://book-variable.example.com/switched")
                .as_deref(),
            Some(r#"{"custom":"switched"}"#),
            "换源书按 originBookUrl 反查"
        );
        assert!(
            deps.book_variable_for("https://book-variable.example.com/empty")
                .is_none(),
            "空白变量应过滤（对齐 ffi db_book_variable）"
        );
        assert!(
            deps.book_variable_for("https://book-variable.example.com/missing")
                .is_none(),
            "无书行 → None"
        );
    }

    /// [P5 尾项] `setup_script_for`：宿主数据取 DB `infoMap_<url>` /
    /// `loginHeader_<url>` / `userInfo_<url>`（与 ffi 同键），生成脚本含
    /// source/baseUrl/loginUrl 绑定、infoMap 快照与登录缓存预置。
    #[tokio::test]
    async fn test_server_deps_source_context_from_db() {
        let state = make_test_state();
        let deps = server_deps(&state).expect("server deps");
        let source = BookSource {
            book_source_url: "https://setup.example.com".to_string(),
            book_source_name: "setup 源".to_string(),
            login_url: Some("https://setup.example.com/login".to_string()),
            ..BookSource::default()
        };
        {
            let db = state.db.lock().await;
            let repo = CacheRepository::new(db.connection());
            repo.put("infoMap_https://setup.example.com", r#"{"榜类":"推荐"}"#, 0)
                .expect("种 infoMap");
            repo.put(
                "loginHeader_https://setup.example.com",
                r#"{"X-Token":"abc"}"#,
                0,
            )
            .expect("种登录头");
            repo.put(
                "userInfo_https://setup.example.com",
                r#"{"邮箱":"a@b.c"}"#,
                0,
            )
            .expect("种用户信息");
        }
        let script = deps
            .setup_script_for(&source)
            .expect("setup 脚本应生成（DB 闭包已注入）");
        assert!(
            script.contains(r#"globalThis.baseUrl = "https://setup.example.com";"#),
            "脚本应绑定书源 baseUrl"
        );
        assert!(
            script.contains(r#"globalThis.loginUrl = "https://setup.example.com/login";"#),
            "脚本应绑定书源 loginUrl"
        );
        assert!(
            script.contains(r#"__infoData = {"榜类":"推荐"}"#),
            "infoMap 快照应入脚本（DB infoMap_<url> 键）"
        );
        assert!(
            script.contains("__loginHeaderSeed") && script.contains("X-Token"),
            "登录头预置应入脚本（DB loginHeader_<url> 键）"
        );
        assert!(
            script.contains("__loginInfoSeed") && script.contains("邮箱"),
            "用户信息预置应入脚本（DB userInfo_<url> 键）"
        );
        assert!(
            script.contains("__mountBookSourceApi"),
            "脚本应挂载 BookSource API"
        );
        // 未命中任何缓存键的书源：仍生成基础脚本（宿主数据为空值，不报错）
        let bare = deps
            .setup_script_for(&BookSource {
                book_source_url: "https://setup-bare.example.com".to_string(),
                ..BookSource::default()
            })
            .expect("无缓存数据也应生成基础 setup");
        assert!(bare.contains("https://setup-bare.example.com"));
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

    /// [P5 尾项] REST 端到端：登录头经 DB 注入并发往源站。
    ///
    /// mock 源站仅在请求携带 `X-Login-Token: secret` 时返回 1 条结果。状态
    /// DB 种入 `loginHeader_<bookSourceUrl>` 后请求得结果，未种数据的同构
    /// 书源得 0 条——证明 `server_deps` 的 login_header 闭包在 REST webbook
    /// 链路真实被调用且生效（装配断言之外的链路可达证明）。
    async fn start_mock_login_gated_server() -> String {
        use axum::extract::Query;
        use axum::http::HeaderMap;
        use axum::response::Html;
        use axum::routing::get;
        use std::collections::HashMap;

        async fn mock_search(
            Query(params): Query<HashMap<String, String>>,
            headers: HeaderMap,
        ) -> Html<String> {
            let key = params.get("q").cloned().unwrap_or_default();
            let authed =
                headers.get("X-Login-Token").and_then(|v| v.to_str().ok()) == Some("secret");
            if authed {
                Html(format!(
                    "<html><body>\
                     <div class=\"result\">\
                     <span class=\"name\">已登录-{key}</span>\
                     <span class=\"author\">作者</span>\
                     <a class=\"book\" href=\"/book/1\">详情</a>\
                     </div></body></html>"
                ))
            } else {
                Html("<html><body></body></html>".to_string())
            }
        }

        let app = axum::Router::new().route("/search", get(mock_search));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("mock 登录门控服务可绑定回环端口");
        let addr = listener.local_addr().expect("mock 服务地址");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        format!("http://{addr}")
    }

    #[tokio::test]
    async fn test_webbook_search_rest_injects_login_header_from_db() {
        let base = start_mock_login_gated_server().await;
        let state = make_test_state();
        {
            let db = state.db.lock().await;
            CacheRepository::new(db.connection())
                .put(
                    &format!("loginHeader_{base}"),
                    r#"{"X-Login-Token":"secret"}"#,
                    0,
                )
                .expect("种登录头");
        }
        let app = create_router(state);

        // 已种登录头：mock 源站放行 → 1 条结果
        let seeded_body = serde_json::to_string(&json!({
            "source": {
                "bookSourceUrl": base,
                "bookSourceName": "登录门控源",
                "searchUrl": format!("{base}/search?q={{key}}"),
                "ruleSearch": {
                    "bookList": "class.result",
                    "name": "class.name@text",
                    "author": "class.author@text",
                    "bookUrl": "class.book@href"
                }
            },
            "query": "三体",
            "page": 1
        }))
        .unwrap();
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .body(Body::from(seeded_body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "搜索应 200");
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("读取响应体");
        let body: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
        assert_eq!(body["total"], 1, "携带登录头应得 1 条结果");
        assert_eq!(body["results"][0]["name"], "已登录-三体");

        // 未种登录头的同构书源：mock 源站拒绝 → 0 条（差异来自 DB 登录头注入）
        let unseeded_body = serde_json::to_string(&json!({
            "source": {
                "bookSourceUrl": format!("{base}/unseeded"),
                "bookSourceName": "未登录源",
                "searchUrl": format!("{base}/search?q={{key}}"),
                "ruleSearch": {
                    "bookList": "class.result",
                    "name": "class.name@text",
                    "author": "class.author@text",
                    "bookUrl": "class.book@href"
                }
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
                    .body(Body::from(unseeded_body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "未种源搜索也应 200");
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("读取响应体");
        let body: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
        assert_eq!(body["total"], 0, "无登录头应 0 条（mock 未放行）");
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
            body["results"][0]["source_url"], "https://js-rest.example.com",
            "JS 结果 source_url 应回填书源 URL"
        );
    }
}
