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
//! [P5 尾项] 宿主注入面 [`server_deps`] 全量接入 AppState DB（cookie 持久化
//! 与三宿主闭包，与 ffi `ffi_deps` 同语义、同缓存键口径，数据面为 server
//! 自身 DB 单例）：
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
//!
//! [cookie 批] 抓取链客户端接 DB cookie 存储（[`ServerCookiePersistence`]）：
//! 修复前 `server_deps` 每请求 `LegadoClient::new`（空 jar、无持久化）——
//! 响应 Set-Cookie 用完即弃、不落库，App 已登录书源（cookie 在 DB）到 Web
//! 书架抓取时丢登录态。修复后客户端经 `LegadoClient::with_cookie_persistence`
//! 构建：读侧构建时全量预载 `cookies` 表并按域附加，写侧响应 Set-Cookie
//! 合并写落库。对齐原版 WebService 与主进程同 CookieStore 的语义基线
//!（`WebService.kt:42,204`；审计 `docs/S28_DUAL_DB_AUDIT_20261004.md` §3.5）。

use std::sync::{Arc, OnceLock};

use axum::extract::State;
use axum::Json;
use serde::{Deserialize, Serialize};

use crate::error::ApiError;
use crate::state::AppState;
use legado_core::models::BookSource;
use legado_core::web_book::{WebBookEngine, WebBookInfo, WebChapter, WebSearchResult};
use legado_core::{LegadoError, LegadoResult};
use legado_db::{BookRepository, CacheRepository, CookieRepository};
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

// ─── Cookie 持久化（本批修复：Web 抓取链接通 DB cookie 存储）───────────────────

/// 合并两段 cookie 串（键集并集、同名 `incoming` 胜、按键名排序）
///
/// 与 ffi `http_state.rs::merge_cookie_strings`（legado-ffi）逐语义同款：
/// 同一 [`legado_net::CookieStore::cookie_string_to_map`] 解析口径；排序保证
/// 行内容稳定（HashMap 迭代序不保证，裸拼接会让同一内容产生不同行串）。
///
/// 为何不直接调用 ffi 同款函数：`legado-ffi → legado-server` 依赖方向
/// （server 是 ffi 的依赖）使 server 无法引用 ffi 模块；共享原语为
/// `legado_net::CookieStore` 的解析/合并 API（两侧同源）。
fn merge_cookie_strings(existing: &str, incoming: &str) -> String {
    let mut map = legado_net::CookieStore::cookie_string_to_map(existing);
    map.extend(legado_net::CookieStore::cookie_string_to_map(incoming));
    let mut parts: Vec<String> = map.iter().map(|(k, v)| format!("{k}={v}")).collect();
    parts.sort();
    parts.join("; ")
}

/// 基于 AppState DB `cookies` 表的 server Cookie 持久化后端
///
/// 对齐原版「同进程共享同一 CookieStore」（`WebService.kt:42,204` 控制器
/// 直查 Room 单例）：读侧——客户端构建时 `CookiePersistence::load_all`
/// 全量预载，请求按 URL 属域经 `apply_headers_and_cookies` 附加；写侧——
/// 响应 Set-Cookie 经 `CookiePersistence::save` 落库。
///
/// 与 ffi 路径 `http_state::DbCookiePersistence`（legado-ffi）语义对齐
/// （本批无法直接复用其类型，见 [`merge_cookie_strings`] 依赖方向说明）：
/// - `load_all` / 合并 `save` 均经 `legado_db::CookieRepository` 读写
///   `cookies` 表，行键为 ETLD+1 域键（与 ffi jar 写回 / JS 宿主下沉同表同键）；
/// - App 内嵌模式下 AppState DB 即 ffi `db_state` 全局池的同一 SQLite
///   单库（§二.8 单池修复），故读写与 App 登录态天然同存储；
/// - `save` 为**合并 upsert**（读现有行 → 按键并集、同名新值胜 → 落库）：
///   同一域行与 JS 宿主下沉（`legado-js` 全局 `CookieSink`，db_open 注册）
///   共享，裸 upsert 会以 server 侧视图抹掉 JS 侧已写入的键。
///
/// 失败策略：DB 未初始化 / 锁竞争降级 / 读写失败仅记日志，绝不向网络
/// 请求传播（与 net 层 `CookiePersistence` trait 文档的宽容失败一致）。
struct ServerCookiePersistence {
    state: Arc<AppState>,
}

impl legado_net::CookiePersistence for ServerCookiePersistence {
    fn load_all(&self) -> Vec<(String, String)> {
        with_state_db(&self.state, |db| {
            CookieRepository::new(db.connection()).find_all().ok()
        })
        .unwrap_or_default()
    }

    fn save(&self, tag: &str, cookie: &str) {
        if cookie.is_empty() {
            return;
        }
        let tag_owned = tag.to_string();
        let incoming = cookie.to_string();
        let outcome = with_state_db(&self.state, |db| -> Option<()> {
            let repo = CookieRepository::new(db.connection());
            let merged = match repo.get_by_tag(&tag_owned).ok().flatten() {
                Some(existing) if existing != incoming => {
                    merge_cookie_strings(&existing, &incoming)
                }
                _ => incoming.clone(),
            };
            if merged.is_empty() {
                return Some(()); // 防御分支：空串不产生行（与 ffi 同款跳过）
            }
            repo.upsert(&tag_owned, &merged).ok()?;
            Some(())
        });
        if outcome.is_none() {
            // DB 不可用 / 锁竞争降级 / 写失败：仅记日志（持久化失败不得阻断请求）
            tracing::warn!("server cookie 持久化 '{tag}' 写入跳过或失败（降级为内存态）");
        }
    }
}

/// 组装 server 宿主注入面
///
/// - `client`：`LegadoClientConfig::default()` + **DB-backed cookie 持久化**
///   （[`ServerCookiePersistence`]，本批修复）：构建时从 AppState DB
///   `cookies` 表全量预载（读侧按域附加），响应 Set-Cookie 合并写落库
///   （写侧）。每请求一次构造 = 每请求取库内最新 cookie（App 登录态对
///   Web 抓取立即可见）；本次调用内多请求共享同一客户端 jar（同源内
///   Set-Cookie 续命，对齐原版单 CookieStore 语义）；
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
/// 四闭包（cookie 持久化 + 三宿主注入）经 [`with_state_db`] 同步读 AppState
/// DB（`Arc<AppState>` 捕获，调用时点取库值而非装配时快照）。
///
/// **未做进程级客户端复用（如实登记）**：复用会冻结构建时的 cookie 预载
/// 快照（App 后续登录对 Web 不可见），且进程级槽位无法安全绑定可重启/
/// 多实例的 AppState（测试多库、服务重启场景）；本批只修 cookie 语义，
/// 连接池开销维持现状（每请求一池），留待后续裁决。
pub(crate) fn server_deps(state: &Arc<AppState>) -> LegadoResult<FetcherDeps> {
    let client = LegadoClient::with_cookie_persistence(
        LegadoClientConfig::default(),
        Arc::new(ServerCookiePersistence {
            state: Arc::clone(state),
        }),
    )
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
    use legado_net::CookiePersistence;
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
            injected_paths: Default::default(),
            legacy_review: Default::default(),
            source_check: Default::default(),
        })
    }

    /// 测试令牌（种子到 `config:jsSourceApiToken`，与请求头字节级相等）
    const TEST_TOKEN: &str = "webbook-test-token-p0-1";
    const CONFIG_JS_SOURCE_API_TOKEN: &str = "config:jsSourceApiToken";
    const CONFIG_JS_SOURCE_API_TOKEN_REQUIRED: &str = "config:jsSourceApiTokenRequired";

    /// 种令牌配置并返回挂载生产令牌前置守卫的路由（与
    /// `serve_web_with_injected_paths` 同组装顺序：create_router →
    /// attach_source_write_token_guard）
    async fn make_guarded_app(state: Arc<AppState>) -> axum::Router {
        seed_token_config(&state, true, Some(TEST_TOKEN)).await;
        crate::server::attach_source_write_token_guard(create_router(Arc::clone(&state)), state)
    }

    /// 种 `config:jsSourceApiToken` / `config:jsSourceApiTokenRequired`
    async fn seed_token_config(state: &Arc<AppState>, required: bool, token: Option<&str>) {
        let db = state.db.lock().await;
        let repo = CacheRepository::new(db.connection());
        if let Some(token) = token {
            repo.put(CONFIG_JS_SOURCE_API_TOKEN, token, 0)
                .expect("种令牌");
        }
        repo.put(
            CONFIG_JS_SOURCE_API_TOKEN_REQUIRED,
            if required { "true" } else { "false" },
            0,
        )
        .expect("种令牌开关");
    }

    /// 构造 JSON POST 请求（`token` 为 None 时不带 `x-legado-token`）
    fn post_json(uri: &str, body: String, token: Option<&str>) -> Request<Body> {
        let mut builder = Request::builder()
            .method(Method::POST)
            .uri(uri)
            .header("Content-Type", "application/json");
        if let Some(token) = token {
            builder = builder.header("x-legado-token", token);
        }
        builder.body(Body::from(body)).expect("请求构建失败")
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
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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

    /// [缺陷回归 2026-11-15] REST 正文入口（`WebBookContentRequest.chapter`）
    /// 是 `WebChapter` 的另一处外部 JSON 构造路径：调用方不提供 `is_vip`
    /// 时必须可反序列化且按 false 处理（此前 `missing field 'is_vip'` → 422，
    /// 与书源调试同源的必填字段缺陷）。
    #[test]
    fn test_content_request_accepts_chapter_without_is_vip() {
        let body = json!({
            "source": serde_json::from_str::<Value>(&make_source_json()).unwrap(),
            "chapter": {
                "index": 0,
                "title": "第一章",
                "url": "https://example.com/ch/1"
            }
        });
        let req: WebBookContentRequest =
            serde_json::from_value(body).expect("缺失 is_vip 的章节 JSON 必须可反序列化");
        assert!(!req.chapter.is_vip, "is_vip 缺省必须为 false");
    }

    #[tokio::test]
    async fn test_webbook_content_endpoint() {
        let state = make_test_state();
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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
        let app = make_guarded_app(state).await;

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
                            .header("x-legado-token", TEST_TOKEN)
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
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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
                    .header("x-legado-token", TEST_TOKEN)
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
    ///
    /// [P0-1] 经生产令牌守卫路由并携带正确 `x-legado-token`：钉死「合法
    /// 令牌 → JS 正常执行」的绿径（相对路径见同模块无令牌拒绝用例）。
    #[cfg(feature = "quickjs")]
    #[tokio::test]
    async fn test_webbook_search_js_source_dispatch_via_rest() {
        let state = make_test_state();
        let app = make_guarded_app(state).await;

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
                    .header("x-legado-token", TEST_TOKEN)
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

    // ─── [P0-1 审查修复] /api/webbook/* 令牌面 ────────────────────────────────

    /// 回环标记服务：统计收到的 TCP 连接数（用于证明被拒绝的请求未执行 JS）
    fn start_marker_server() -> (std::net::SocketAddr, Arc<std::sync::atomic::AtomicUsize>) {
        use std::io::{Read, Write};

        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("标记服务可绑定回环端口");
        let addr = listener.local_addr().expect("标记服务地址");
        let hits = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let hits_srv = Arc::clone(&hits);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                hits_srv.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(2)));
                let mut buf = [0u8; 4096];
                let _ = sock.read(&mut buf);
                let _ = sock.write_all(
                    b"HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                );
            }
        });
        (addr, hits)
    }

    /// P0-1：四条 `/api/webbook/*` 无令牌一律拒绝（原版失败信封 +
    /// `Connection: close`），且被拒绝请求**不得执行**请求体中的 JS。
    ///
    /// 「未执行 JS」证明方式：`mainJs` 顶层执行 `java.ajax` 打回环标记服务
    /// 并计数。守卫在 body 提取前拒绝 → 连接数必须为 0。quickjs 档为真执行
    /// 证明（若守卫漏挂，JS 在 handler 内同步执行并命中标记服务）；默认档
    /// JS 引擎为 stub，连接数恒 0，本用例仍验证拒绝层。
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_webbook_endpoints_reject_without_token_and_do_not_execute_js() {
        let (addr, hits) = start_marker_server();
        let state = make_test_state();
        let app = make_guarded_app(state).await;

        let main_js = format!(
            r#"java.ajax('{{"url":"http://{addr}/marker"}}');
function search(key, page) {{ return JSON.stringify([{{name: 'executed', author: 'x', bookUrl: 'https://no-token.example.com/1'}}]); }}"#
        );
        let source = json!({
            "bookSourceUrl": "https://no-token.example.com",
            "bookSourceName": "无令牌测试源",
            "mainJs": main_js,
        });
        let cases = [
            (
                "/api/webbook/search",
                json!({ "source": source, "query": "三体", "page": 1 }),
            ),
            (
                "/api/webbook/info",
                json!({ "source": source, "book_url": "https://no-token.example.com/book/1" }),
            ),
            (
                "/api/webbook/chapters",
                json!({ "source": source, "book_url": "https://no-token.example.com/book/1" }),
            ),
            (
                "/api/webbook/content",
                json!({
                    "source": source,
                    "chapter": {
                        "index": 0,
                        "title": "第一章",
                        "url": "https://no-token.example.com/ch/1",
                        "is_vip": false
                    }
                }),
            ),
        ];

        for (uri, payload) in cases {
            let resp = app
                .clone()
                .oneshot(post_json(uri, payload.to_string(), None))
                .await
                .expect("oneshot 调用成功");
            assert_eq!(
                resp.status(),
                StatusCode::OK,
                "{uri} 令牌拒绝沿用原版 200 信封"
            );
            assert_eq!(
                resp.headers()
                    .get(axum::http::header::CONNECTION)
                    .and_then(|v| v.to_str().ok()),
                Some("close"),
                "{uri} 失败响应必须 Connection: close"
            );
            let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .expect("读取响应体");
            let body: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
            assert_eq!(body["isSuccess"], false, "{uri} 必须返回失败信封");
            assert_eq!(
                body["errorMsg"], "Web 书源访问令牌未配置或不正确",
                "{uri} 错误文案"
            );
            assert_eq!(body["data"], Value::Null, "{uri} data 应为 null");
        }

        // 给潜在的异步 JS 执行留观察窗口（守卫有效时应恒 0）
        tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        assert_eq!(
            hits.load(std::sync::atomic::Ordering::SeqCst),
            0,
            "未授权请求不得执行请求体中的 mainJs（java.ajax 标记服务不得收到连接）"
        );
    }

    /// P0-1 语义：`config:jsSourceApiTokenRequired=false`（显式关闭）时按
    /// 既有全局语义免令牌放行，`token_rejection` 记一次性 warn。
    ///
    /// 与源写端点 / `/mcp/call` 保持同一语义：显式关闭是用户 opt-out；
    /// 关闭后 `/testReplaceRule`、`/saveJsSource` 同样可执行 JS，单独收紧
    /// webbook 不增加实际安全收益。恢复防护：删除该配置键（缺省 true）或
    /// 置 true。quickjs 档同时证明「放行即真执行」（标记服务命中）。
    ///
    /// `multi_thread` 必需：mainJs 顶层 `java.ajax` 经
    /// `host_api::runtime_bridge::block_on` 的 `block_in_place` 分支驱动，
    /// current_thread runtime 会 panic。
    #[cfg(feature = "quickjs")]
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn test_webbook_required_false_allows_without_token_and_executes_js() {
        let (addr, hits) = start_marker_server();
        let state = make_test_state();
        seed_token_config(&state, false, None).await;
        let app = crate::server::attach_source_write_token_guard(
            create_router(Arc::clone(&state)),
            state,
        );

        let main_js = format!(
            r#"java.ajax('{{"url":"http://{addr}/marker"}}');
function search(key, page) {{ return JSON.stringify([{{name: 'executed-' + key, author: 'x', bookUrl: 'https://required-false.example.com/1'}}]); }}"#
        );
        let body = json!({
            "source": {
                "bookSourceUrl": "https://required-false.example.com",
                "bookSourceName": "关闭令牌源",
                "mainJs": main_js
            },
            "query": "三体",
            "page": 1
        })
        .to_string();

        let resp = app
            .oneshot(post_json("/api/webbook/search", body, None))
            .await
            .expect("oneshot 调用成功");
        assert_eq!(resp.status(), StatusCode::OK, "显式关闭令牌后应免令牌放行");
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("读取响应体");
        let body: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
        assert_eq!(body["total"], 1, "关闭令牌时搜索正常执行");
        assert_eq!(body["results"][0]["name"], "executed-三体");
        assert!(
            hits.load(std::sync::atomic::Ordering::SeqCst) >= 1,
            "关闭令牌时 mainJs 真实执行（顶层 java.ajax 应命中标记服务）"
        );
    }

    // ─── [本批修复] server 抓取链 cookie 存储接线（对齐原版同进程同存储） ─────

    /// 回环 mock 源站：记录每个请求的 `Cookie` 头；`require_cookie` 非空时
    /// 仅当 Cookie 头包含该子串才返回结果（模拟登录门控）；`set_cookie`
    /// 非空时在响应附带该 `Set-Cookie`（写回落库断言用）。
    ///
    /// 返回 `(base URL, 已见 Cookie 头列表)`；源站绑定随机回环端口，
    /// 测试结束随进程/任务回收。
    async fn start_mock_cookie_source(
        require_cookie: Option<&'static str>,
        set_cookie: Option<&'static str>,
    ) -> (String, Arc<std::sync::Mutex<Vec<Option<String>>>>) {
        use axum::extract::Query;
        use axum::http::HeaderMap;
        use axum::routing::get;
        use std::collections::HashMap;

        type Seen = Arc<std::sync::Mutex<Vec<Option<String>>>>;

        async fn mock_search(
            State((seen, require_cookie, set_cookie)): State<(
                Seen,
                Option<&'static str>,
                Option<&'static str>,
            )>,
            Query(params): Query<HashMap<String, String>>,
            headers: HeaderMap,
        ) -> axum::response::Response {
            let cookie = headers
                .get("cookie")
                .and_then(|v| v.to_str().ok())
                .map(str::to_string);
            let pass = require_cookie
                .map(|needle| cookie.as_deref().is_some_and(|c| c.contains(needle)))
                .unwrap_or(true);
            seen.lock().unwrap().push(cookie);
            let key = params.get("q").cloned().unwrap_or_default();
            let html = if pass {
                format!(
                    "<html><body>\
                     <div class=\"result\">\
                     <span class=\"name\">cookie-{key}</span>\
                     <span class=\"author\">作者</span>\
                     <a class=\"book\" href=\"/book/1\">详情</a>\
                     </div></body></html>"
                )
            } else {
                "<html><body></body></html>".to_string()
            };
            let mut builder = axum::response::Response::builder()
                .header("content-type", "text/html; charset=utf-8");
            if let Some(sc) = set_cookie {
                builder = builder.header("set-cookie", sc);
            }
            builder
                .body(axum::body::Body::from(html))
                .expect("mock 响应构造")
        }

        let seen: Seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let app = axum::Router::new()
            .route("/search", get(mock_search))
            .with_state((Arc::clone(&seen), require_cookie, set_cookie));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("mock cookie 源站可绑定回环端口");
        let addr = listener.local_addr().expect("mock 服务地址");
        tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        (format!("http://{addr}"), seen)
    }

    /// mock 源站域名键：IP 字面量以自身为键（对齐
    /// `legado_net::cookie_store::cookie_domain_key` 与 ffi 行键口径）
    const MOCK_COOKIE_DOMAIN: &str = "127.0.0.1";

    /// 构造指向 mock 源站的规则书源（bookSourceUrl = base；`enabledCookieJar`
    /// 缺键 → serde 默认 `Some(true)`，写侧 CookieJar 门控开启）
    fn make_cookie_mock_source(base: &str) -> Value {
        json!({
            "bookSourceUrl": base,
            "bookSourceName": "cookie 存储测试源",
            "searchUrl": format!("{base}/search?q={{key}}"),
            "ruleSearch": {
                "bookList": "class.result",
                "name": "class.name@text",
                "author": "class.author@text",
                "bookUrl": "class.book@href"
            }
        })
    }

    /// [本批修复] 读侧：DB 已有该书源域 cookie → server 抓取请求头携带。
    /// 修复前 `server_deps` 每请求 `LegadoClient::new`（空 jar）→ 请求无
    /// Cookie 头 → mock 门控返回空 → 0 条（红）；修复后 DB cookie 预载入
    /// 客户端 jar → 请求带 `session=dbval` → 1 条（绿）。
    #[tokio::test]
    async fn test_webbook_search_rest_sends_db_cookie_to_source() {
        let (base, seen) = start_mock_cookie_source(Some("session=dbval"), None).await;
        let state = make_test_state();
        {
            let db = state.db.lock().await;
            legado_db::CookieRepository::new(db.connection())
                .upsert(MOCK_COOKIE_DOMAIN, "session=dbval")
                .expect("种 DB cookie（App 登录态）");
        }
        let app = make_guarded_app(state).await;

        let body = serde_json::to_string(&json!({
            "source": make_cookie_mock_source(&base),
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
                    .header("x-legado-token", TEST_TOKEN)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "搜索应 200");
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .expect("读取响应体");
        let parsed: Value = serde_json::from_slice(&bytes).expect("响应为 JSON");
        assert_eq!(
            parsed["total"], 1,
            "DB 会话 cookie 必须随 server 抓取请求发出（mock 登录门控放行）"
        );
        let cookies = seen.lock().unwrap().clone();
        assert_eq!(cookies.len(), 1, "应恰好发出一次搜索请求");
        let sent = cookies[0].as_deref().unwrap_or("");
        assert!(
            sent.contains("session=dbval"),
            "请求头 Cookie 必须包含 DB 中的会话 cookie，实际: {sent:?}"
        );
    }

    /// [本批修复] 写侧：server 抓取响应 Set-Cookie → 落库；下一次请求
    /// 经 DB 预载回读携带（对齐原版「同一存储」：App 与 Web 共享
    /// CookieStore 读写）。同时钉死合并写语义：不得抹除 App 侧既有键。
    #[tokio::test]
    async fn test_webbook_search_rest_persists_set_cookie_to_db() {
        let (base, seen) = start_mock_cookie_source(None, Some("srv=1; Path=/")).await;
        let state = make_test_state();
        {
            let db = state.db.lock().await;
            legado_db::CookieRepository::new(db.connection())
                .upsert(MOCK_COOKIE_DOMAIN, "app=1")
                .expect("预置 App 侧既有 cookie 行（合并写不得抹除）");
        }
        let app = make_guarded_app(state.clone()).await;

        let body = serde_json::to_string(&json!({
            "source": make_cookie_mock_source(&base),
            "query": "三体",
            "page": 1
        }))
        .unwrap();
        // 第一次请求：响应 Set-Cookie 应合并落库（App 既有键保留）
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .header("x-legado-token", TEST_TOKEN)
                    .body(Body::from(body.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "第一次搜索应 200");
        {
            let db = state.db.lock().await;
            let row = legado_db::CookieRepository::new(db.connection())
                .get_by_tag(MOCK_COOKIE_DOMAIN)
                .expect("读 DB cookie 行")
                .unwrap_or_default();
            assert!(
                row.contains("srv=1"),
                "响应 Set-Cookie 必须落库，实际行: {row:?}"
            );
            assert!(
                row.contains("app=1"),
                "合并写不得抹除既有键，实际行: {row:?}"
            );
        }
        // 第二次请求：新客户端经 DB 预载 → 携带上一轮响应 cookie
        let resp = app
            .oneshot(
                Request::builder()
                    .method(Method::POST)
                    .uri("/api/webbook/search")
                    .header("Content-Type", "application/json")
                    .header("x-legado-token", TEST_TOKEN)
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "第二次搜索应 200");
        let cookies = seen.lock().unwrap().clone();
        assert_eq!(cookies.len(), 2, "应发出两次搜索请求");
        let second = cookies[1].as_deref().unwrap_or("");
        assert!(
            second.contains("srv=1"),
            "第二次请求必须携带上一轮落库的 cookie，实际: {second:?}"
        );
    }

    /// [本批修复] 合并写钉死：既有键保留、同名键新值胜（与 ffi
    /// `persist_cookie_row_merged` 同语义；防 server 写回抹掉 JS/App 键）。
    #[test]
    fn test_server_cookie_persistence_merged_upsert() {
        let state = make_test_state();
        let persistence = ServerCookiePersistence {
            state: Arc::clone(&state),
        };
        {
            let db = state.db.try_lock().expect("测试无并发持锁");
            CookieRepository::new(db.connection())
                .upsert(MOCK_COOKIE_DOMAIN, "a=1; keep=1")
                .expect("预置既有行");
        }
        persistence.save(MOCK_COOKIE_DOMAIN, "a=9; b=2");

        let row = {
            let db = state.db.try_lock().expect("测试无并发持锁");
            CookieRepository::new(db.connection())
                .get_by_tag(MOCK_COOKIE_DOMAIN)
                .expect("读行")
                .unwrap_or_default()
        };
        let map = legado_net::CookieStore::cookie_string_to_map(&row);
        assert_eq!(map.get("a").map(String::as_str), Some("9"), "同名键新值胜");
        assert_eq!(map.get("b").map(String::as_str), Some("2"), "新键写入");
        assert_eq!(
            map.get("keep").map(String::as_str),
            Some("1"),
            "既有键保留（合并写不得覆盖）"
        );
    }
}
