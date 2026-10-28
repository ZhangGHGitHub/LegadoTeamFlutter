//! 原版 WebSocket 调试通道（独立端口 + 原版路径，B5）
//!
//! 对齐 upstream `io.legado.app.web.WebSocketServer` 及其 vue 调试页的实际
//! 连接形态。原版语义基线（逐条列出，便于复核）：
//!
//! | 语义 | 原版依据 |
//! |---|---|
//! | 独立端口 = 主服务端口 + 1（主服务默认 1122 → WS 1123；与主服务同启停） | `WebService.kt:214-219`（`WebSocketServer(port + 1)`、`stopServers()` 同时 stop 两者） |
//! | 路径 `/bookSourceDebug`、`/rssSourceDebug`、`/searchBook` | `WebSocketServer.kt:33-55` |
//! | 未知 WS 路径 → 404 `WebSocket route not found` + nosniff | `WebSocketServer.kt:11-18` |
//! | 鉴权：`Sec-WebSocket-Protocol` 必须含 `legado`；令牌必填时须恰为两项且第二项 = `legado.token.<base64url(token)>`；失败 403「Web 书源访问令牌未配置或不正确」+ no-store + nosniff | `WebSocketServer.kt:19-28`；`BookSourceController.kt:24-26,147-179` |
//! | 建连后 10s 内未收到合法首包 → close 1008「认证超时」 | `BookSourceDebugWebSocket.kt:29-39,177`（RSS 同构 `:29-39,175`） |
//! | 首包必须是 JSON 对象；非 JSON/非对象 → close 1008「认证数据格式错误」 | `BookSourceDebugWebSocket.kt:79-90` |
//! | 书源首包 `{tag,key}` 任一为空 → send「输入不能为空」+ close 1000「调试结束」 | `BookSourceDebugWebSocket.kt:92-96` |
//! | 书源不存在 → send「书源不存在」+ close 1000；RSS 为「订阅源不存在」 | `BookSourceDebugWebSocket.kt:97-102`；`RssSourceDebugWebSocket.kt:96-101` |
//! | 调试通道全局单槽被占用 → send「调试通道占用中，请稍后重试」+ close 1000 | `BookSourceDebugWebSocket.kt:103-110`（`Debug.tryAcquireCallback`） |
//! | 认证成功后每 30s 发一次 ping（payload `ping`） | `BookSourceDebugWebSocket.kt:42-52` |
//! | 调试结束（state 1000/-1）→ close 1000「调试结束」 | `BookSourceDebugWebSocket.kt:146-156` |
//! | 书源调试分派与链路：绝对 URL→详情→目录→正文；含 `::`→发现；`++`→目录→正文；`--`→正文；其余→搜索→详情→目录→正文 | `Debug.kt:452-505,507-614` |
//! | 日志行时间前缀 `[mm:ss.SSS] `，`showTime=false` 时原样 | `Debug.kt:80-95` |
//!
//! 端口+1 的前端推导（vue 打包产物 `assets/web/vue/assets/index-Bm4G1GTr.js`
//! 的 `Gt` 函数）：`new URL('bookSourceDebug', wsBase)`，其中
//! `wsBase = ws(s)://host:Number(httpPort)+1/<path>/`；无显式端口时原版取
//! `http`→81、`https`→444（本实现仅在显式端口下工作，主服务始终有端口）。
//!
//! 与自研通道的关系：`/ws/search`、`/ws/debug/book-source`、
//! `/ws/debug/rss-source`（同端口、`/api` 前缀）保持原样不动；本模块只在
//! 主服务 `port+1` 上新增原版路径，互不影响。
//!
//! # 日志层级（批13 起：阶段级 + 请求级；规则级如实登记未覆盖）
//!
//! 原版调试日志由 App 内 `Debug` 引擎（`Debug.kt:63-101`）在三个阶段层级
//! 逐条打印，全部经 `Debug.Callback.printLog`（WS 连接即回调宿主）推给
//! 前端。Rust server 的依赖方向（`legado-server → legado-fetcher`）可触达
//! 书源抓取四入口（search/info/chapters/content），但 fetcher 内部不暴露
//! `AnalyzeRule` 的逐规则求值回调，因此三层日志的覆盖如实划分：
//!
//! | 层级 | 原版依据 | 本实现 |
//! |---|---|---|
//! | 阶段标题 | `Debug.kt:456-493`（`⇒开始...`）、`:520-615`（`︾开始解析...`/`︽...解析完成`/空行） | **已覆盖**：真实执行链逐阶段输出同名标记 |
//! | 请求行 | `BookList.kt:53` / `BookInfo.kt:39` / `BookChapterList.kt:48` / `BookContent.kt:51`（`≡获取成功:<url>`） | **规则书源已覆盖**：每个真实 HTTP 请求完成时输出（URL 取自 `LegadoClient` 采集，非规则模板猜测；打印实际绝对 URL，上游打 `ruleUrl` 规则形态，登记差异）；**JS 书源无请求级日志**（登记：task-local 不跨 `runtime_bridge` 独立 runtime，见下） |
//! | 请求测量 | 原版无对应行（仅时间前缀体现耗时） | **已覆盖（自有格式）**：`≡请求 <method> <url> -> <status> <耗时>ms <字节数>B`，字段全部来自真实采集记录 |
//! | 规则字段行 | `BookInfo.kt:67-170` 的 `┌获取书名`/`└<值>` 族、`BookList.kt:219-285` 搜索首条字段族、`BookChapterList.kt:293-303` 首章信息族 | **部分覆盖**：字段名与**求值结果**来自 fetcher 返回结构（真实执行数据）；**逐条 AnalyzeRule 求值细节（单规则命中、合并规则分支、异常字段的 localizedMessage）不可得，登记未覆盖** |
//! | 结果摘要 | `◇书籍总数`/`◇目录总数`/`◇是否VIP` 等 | **已覆盖**：数量与首章信息取自真实结果 |
//! | 失败链 | `.onError { log(it.stackTraceStr, state=-1) }`（Kotlin 堆栈） | **已覆盖（降级）**：`LegadoError` 的 `Display`（部分变体附 `source()` 链），非 Kotlin 堆栈 |
//!
//! 请求级日志的机制：`legado_net::http_log::scope_debug_request_sink` 以
//! `tokio::task_local` 把观测回调注入**本调试任务**，`LegadoClient` 同一
//! 任务内同步调用故可读到；全局 `HttpLogStore` 是 `OnceLock` first-wins 单槽
//! （不能按会话切换），因此**不碰全局单槽**——调试会话观测与 `recordHttpLog`
//! 开关相互独立（开关关闭时调试仍可见请求；开关开启时两路各收一次）。
//! 局限（登记）：`tokio::spawn` 出的新任务不继承作用域；**JS 书源无请求级
//! 日志**——JS 搜索经 `spawn_blocking` 进入 `runtime_bridge` 的独立 tokio
//! runtime（`get_runtime()`），task-local 不跨 runtime，采集回调不可见。
//! 性能登记（可选）：当前每次请求把整包 `HttpLogEntry`（含响应体字符串）
//! clone 后推给调试前端；会话请求量大时可改为 `Arc`/字段投影，后续批次处理。
//!
//! # 未覆盖清单（fetcher 公共结果拿不到，禁止伪造）
//!
//! - 逐条 `AnalyzeRule` 求值行（单规则命中、合并规则分支、`@put` 变量落点）；
//! - `┌获取书籍列表`/`└列表大小:N`：`WebSearchResult` 不返回原始元素数
//!   （已用 `◇书籍总数:N` 给真实结果数）；
//! - 目录 `┌获取目录列表`/`└列表大小:N`：`WebChapter` 列表不返回逐页元素数；
//! - `≡链接为详情页`/`└列表为空,按详情页解析`：`bookUrlPattern` 直连与空列表
//!   回退分支的结果正确（fetcher 返回结果），但分支过程日志不可得；
//! - `◇章节列表为空`：目录空结果在 fetcher 层归为空列表/错误，无该行；
//! - `┌获取章节名称` 取 toc 章节标题（正文页 `title` 规则求值结果 fetcher
//!   未返回）；`└获取封面链接` 取绝对化后的 URL（上游打印规则原始值）；
//! - `◇目录总页数`/`◇并发解析目录,总页数`/`◇本章总页数`/`◇并发解析正文,总页数`：
//!   分页链与并发度在 fetcher 内部，不对外返回；
//! - `┌获取目录下一页列表`/`└…`、`┌获取正文下一页链接`/`└…`：`nextTocUrl`/
//!   `nextContentUrl` 的求值结果不随结果结构返回；
//! - `≡检测到重定向(<code>)`/`┌重定向后地址`：`LegadoResponse.url` 是最终 URL，
//!   中间跳数不可见（请求测量行给的是原始请求 URL + 最终状态）；
//!
//! # 订阅源调试（批15e：接 15a/15b/15c RSS 引擎）
//!
//! 原版语义逐条对照（`RssSourceDebugWebSocket.kt` / `Debug.kt:309-450` /
//! `RssParserByRule.kt:36-140`）：
//!
//! | 语义 | 原版依据 |
//! |---|---|
//! | 首包只读 `tag`（= `sourceUrl`；空/空白 → 「输入不能为空」）；`key` 字段不会被 RSS WS 读取 | `RssSourceDebugWebSocket.kt:87-101` |
//! | 首包通过后调用**两参** `Debug.startDebug(scope, rssSource)`：打印 `︾开始解析`，取 `sortUrls()` 首项（缺省 `("" to sourceUrl)`）请求第 1 页 | `RssSourceDebugWebSocket.kt:113`；`Debug.kt:309-343` |
//! | 列表为空 → `⇒列表页解析成功，为空` + `︽解析完成`(1000) | `Debug.kt:317-321` |
//! | `ruleArticles` 非空且 `ruleDescription` 空白 → `︽列表页解析完成` + 空行；`ruleContent` 空 → `⇒内容规则为空，默认获取整个网页`(1000)，否则解析首篇文章正文 | `Debug.kt:323-331` |
//! | 其余（含默认规则源）→ `⇒存在描述规则，不解析内容页` + `︽解析完成`(1000) | `Debug.kt:332-336` |
//! | 正文：`︾开始解析内容页` → 正文整段（带一次时间前缀）→ `︽内容页解析完成`(1000)；失败打印错误链(-1) | `Debug.kt:412-450` |
//! | 列表解析阶段行：默认规则 `⇒列表规则为空, 使用默认规则解析` **+ 默认解析结果首条字段族**（列表非空时 10 行，可空字段字面输出 `null`）；规则列表 `┌获取列表`/`└列表大小:N`、`┌获取下一页链接`/`└<url>`、首条字段族 `┌获取标题`/`┌获取时间`/`┌获取描述`/`┌获取图片url`/`┌获取文章链接` | `RssParserByRule.kt:36-92,95-140`；`RssParserDefault.kt:101-112` |
//! | 响应体行 state 10/20/30/40 由 WS 丢弃；`-1`/`1000` 打印后 close 1000「调试结束」 | `RssSourceDebugWebSocket.kt:24,144-156` |
//! | 三参 `Debug.startDebug(scope, rssSource, key)`：含 `::` → 分类页；绝对 URL → 正文页；其它 → 搜索页（`searchUrl` 空 → `⇒搜索URL为空`(-1)） | `Debug.kt:346-410` |
//!
//! 本实现的接线：
//!
//! - **无 `key`（原版 WS 首包形态）**逐行复刻两参流程：`︾开始解析` →
//!   `sortUrls()` 首项 → 列表（15a 默认解析 / 15b 规则列表+登录+分页）→
//!   空/描述规则/正文三分支；
//! - **带非空 `key`** 走原版 App 调试页三参分流（分类 / 绝对 URL 正文 /
//!   搜索）。这是**加法式超集**：原版 RSS WS 类不读取 `key`，但官方
//!   `api.md`「调试源」声明请求体为 `{key, tag}`，且三路都必须可达；
//!   `key` 空/缺省时行为与原版 WS 完全一致（服务端只在 key 非空时分流）；
//! - 引擎调用：`legado_fetcher::rss::fetch_articles`（列表/分类/登录/分页）与
//!   `legado_fetcher::rss::content::fetch_content`（正文/正文分页）；
//!   `sortUrls()` 的脚本求值与缓存复用 15b `sort_urls`（缓存键
//!   `rssSortUrl_<md5>` 与原版 ACache 同口径）；
//! - 请求级日志沿用批13 的 task-local 观测槽（`≡获取成功:<url>` + 测量行），
//!   RSS 列表/正文请求都在本调试任务内同步 `await`，可被观测（含正文分页每页，
//!   原版分页 `printLog = false` 抑制，差异见未覆盖清单）；
//! - 登录态：`loginHeader_<url>` / `userInfo_<url>` 由服务器 DB 读取后交给
//!   引擎（同源门控在引擎内完成，跨域 nextUrl 不外发凭据）。
//!
//! 未覆盖清单（fetcher 公共结果拿不到，禁止伪造）：
//!
//! - `└列表大小:N` 用真实**文章数**（原版打印 `getElements` 原始元素数，
//!   即标题为空被丢弃前的数量，差异登记）；
//! - 规则列表首条字段族的取值口径：原版固定对 `collections[0]`（**空标题过滤 /
//!   `-` 反转之前**的原始首元素）打印；本实现取 `page.items.first()`（过滤且
//!   反转之后的首条）。可观察差异两处：① 反转规则源原版展示原始首条（反转后
//!   成为末条），本实现展示原始末条；② 原始首条标题为空时原版照打字段族再丢弃，
//!   本实现展示第二条（全部标题为空时整组字段族不打印）。默认解析分支无过滤 /
//!   反转，按 `firstOrNull()` 打印（列表为空不打印、`null` 字面量），与原版一致；
//! - 正文分页每页的请求级行：原版第 2 页起以 `printLog = false` 调用
//!   （`Rss.kt:141,161`）抑制 `≡获取成功` 与 `┌获取正文下一页链接` 等行；本实现
//!   task-local 观测对每页真实 HTTP 请求都输出 `≡获取成功` + `≡请求`，属**额外
//!   行**（内容为真实请求，非伪造）；
//! - 请求行 URL 口径：列表页原版打印 `analyzeUrl.ruleUrl`（规则求值后的请求
//!   URL，`Rss.kt:83`），正文首页打印 `res.url`（重定向后的最终 URL，
//!   `Rss.kt:211`）；本实现统一打印 `LegadoClient` 采集的**请求 URL**（重定向前）。
//!   列表页两口径近似一致，正文在重定向场景与上游不同；
//! - `第N页完成` / `◇正文总页数` / `◇并发解析正文,总页数` /
//!   `┌获取正文下一页链接`/`└…`：正文分页与 nextUrl 求值在 fetcher 内部；
//! - 逐元素字段求值过程（单条规则命中/异常字段的 `localizedMessage`）；
//! - `≡检测到重定向(<code>)`：只拿得到最终 URL。
//!
//! 发现页调试（书源 `::`）同样无 Rust 发现规则引擎，显式说明后结束。
//! `/searchBook` 原版路径本批未挂载（我方 `/ws/search` 保留）。
//! 另：原版书源校验（`Debug.isChecking`）期间拒绝新调试（`tryAcquireCallback`
//! 返回 false）；Rust server 无该状态机，单槽仅覆盖 WS 调试连接本身。
//! JS 书源搜索结果若带 `tocUrl`，原版会跳过详情页；Rust `WebSearchResult`
//! 无该字段，统一按「搜索→详情→目录→正文」执行（登记差异）。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::extract::{FromRequestParts, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use base64::Engine as _;
use serde_json::Value;
use tokio::sync::mpsc;

use legado_db::repository::cache_repository::CacheRepository;
use legado_db::repository::rss_source_repository::RssSourceRepository;
use legado_db::BookSourceRepository;
use legado_net::HttpLogEntry;

use legado_fetcher::rss::sort_urls::{
    evaluate_sort_script, is_sort_script, resolve_sort_urls_with_cache, sort_cache_key,
};
use legado_fetcher::rss::{RssArticleItem, RssListPage};

use crate::handlers::web_book::server_deps;
use crate::legacy::source_api::{load_js_source_api_config, JsSourceApiConfig};
use crate::state::AppState;

// ─── 原版常量 ───────────────────────────────────────────────────────────────

/// 原版 `JS_SOURCE_WEBSOCKET_PROTOCOL`（`BookSourceController.kt:25`）
const LEGADO_WS_PROTOCOL: &str = "legado";
/// 原版 `JS_SOURCE_WEBSOCKET_PROTOCOL_PREFIX`（`BookSourceController.kt:26`）
const LEGADO_WS_TOKEN_PREFIX: &str = "legado.token.";
/// 原版 `AUTH_TIMEOUT_MILLIS = 10_000L`（`BookSourceDebugWebSocket.kt:177`）
const AUTH_TIMEOUT: Duration = Duration::from_secs(10);
/// 原版心跳间隔 `delay(30_000)`（`BookSourceDebugWebSocket.kt:46`）
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
/// 原版关闭原因
const CLOSE_REASON_FINISH: &str = "调试结束";
const CLOSE_REASON_AUTH_TIMEOUT: &str = "认证超时";
const CLOSE_REASON_BAD_AUTH: &str = "认证数据格式错误";
const CLOSE_REASON_DEBUG_FAILED: &str = "调试失败";
/// 原版 `R.string.cannot_empty` 中文值（`values-zh/strings.xml:738`）
const MSG_CANNOT_EMPTY: &str = "输入不能为空";
/// 调试通道占用（`BookSourceDebugWebSocket.kt:104`）
pub(crate) const MSG_DEBUG_BUSY: &str = "调试通道占用中，请稍后重试";
/// 原版 RSS 调试 WS 丢弃的状态码（响应体行，`RssSourceDebugWebSocket.kt:24`）
///
/// state 语义：10 = 列表响应体、20 = 正文响应体、30 = 目录响应体、
/// 40 = 章节正文响应体（`RssParserByRule.kt:37`、`Rss.kt:212`、
/// `BookChapterList.kt:49`、`BookContent.kt:52`）。这些行原样推给前端会
/// 淹没阶段日志，故原版 WS 直接丢弃；本实现从不产生这些行，
/// [`DebugSink::log_state`] 仍按同一口径过滤，保持 state 语义可核对。
const RSS_NOT_PRINT_STATES: [i32; 4] = [10, 20, 30, 40];

/// WebSocket 关闭码（对齐 `NanoWSD.WebSocketFrame.CloseCode`）
const CLOSE_NORMAL: u16 = 1000;
const CLOSE_POLICY_VIOLATION: u16 = 1008;
const CLOSE_INTERNAL_ERROR: u16 = 1011;

// ─── 调试全局单槽（对齐 Debug.callback 单例语义）────────────────────────────

/// 当前调试占用者；`None` = 空闲。原版 `Debug.callback` 进程级单例。
static DEBUG_SLOT: Mutex<Option<u64>> = Mutex::new(None);
/// 连接自增 ID（仅用于区分占用者）
static NEXT_DEBUG_OWNER: AtomicU64 = AtomicU64::new(1);

/// 调试槽占用守卫（Drop 时释放；仅释放自己的槽）
pub(crate) struct DebugSlot {
    owner: u64,
}

impl DebugSlot {
    /// 尝试占用；已被他人占用返回 `None`（对齐 `Debug.tryAcquireCallback`）
    pub(crate) fn try_acquire() -> Option<Self> {
        let owner = NEXT_DEBUG_OWNER.fetch_add(1, Ordering::Relaxed);
        let mut slot = DEBUG_SLOT
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if slot.is_some() {
            return None;
        }
        *slot = Some(owner);
        Some(Self { owner })
    }
}

impl Drop for DebugSlot {
    fn drop(&mut self) {
        let mut slot = DEBUG_SLOT
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if *slot == Some(self.owner) {
            *slot = None;
        }
    }
}

#[cfg(test)]
impl DebugSlot {
    /// 测试用：读当前占用者
    fn current() -> Option<u64> {
        *DEBUG_SLOT
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}

// ─── 鉴权（对齐 BookSourceController.hasValidJsSourceWebSocketProtocol）──────

/// 读取 `Sec-WebSocket-Protocol`（多值按原版 Map 语义以逗号拼接）
fn websocket_protocol_header(headers: &HeaderMap) -> Option<String> {
    let values: Vec<&str> = headers
        .get_all(header::SEC_WEBSOCKET_PROTOCOL)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .collect();
    if values.is_empty() {
        None
    } else {
        Some(values.join(","))
    }
}

/// 常量时间字节比较（对齐 `MessageDigest.isEqual`）
fn constant_time_eq(expected: &[u8], actual: &[u8]) -> bool {
    if expected.len() != actual.len() {
        return false;
    }
    let mut diff = 0u8;
    for (a, b) in expected.iter().zip(actual.iter()) {
        diff |= a ^ b;
    }
    diff == 0
}

/// `legado.token.<base64url(trim(token))>`，base64url 去 padding
/// （`BookSourceController.kt:175-179`）
fn js_source_websocket_protocol(token: Option<&str>) -> Option<String> {
    let normalized = token?.trim();
    if normalized.is_empty() {
        return None;
    }
    let encoded = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(normalized);
    Some(format!("{LEGADO_WS_TOKEN_PREFIX}{encoded}"))
}

/// 校验 WS 子协议（`BookSourceController.kt:154-173`）
///
/// - `required=false`：首项为 `legado` 即通过；
/// - `required=true`：必须恰为两项，首项 `legado`，次项与期望令牌常量时间相等。
fn validate_websocket_protocol(headers: &HeaderMap, config: &JsSourceApiConfig) -> bool {
    let Some(raw) = websocket_protocol_header(headers) else {
        return false;
    };
    let protocols: Vec<&str> = raw.split(',').map(str::trim).collect();
    if !config.required {
        return protocols.first().copied() == Some(LEGADO_WS_PROTOCOL);
    }
    let Some(expected) = js_source_websocket_protocol(config.token.as_deref()) else {
        return false;
    };
    if protocols.len() != 2 || protocols[0] != LEGADO_WS_PROTOCOL {
        return false;
    }
    constant_time_eq(expected.as_bytes(), protocols[1].as_bytes())
}

/// 鉴权失败响应（`WebSocketServer.kt:19-28`）
fn forbidden_response() -> Response {
    (
        StatusCode::FORBIDDEN,
        [
            (header::CONTENT_TYPE, "text/plain; charset=utf-8"),
            (header::CACHE_CONTROL, "no-store"),
            (
                header::HeaderName::from_static("x-content-type-options"),
                "nosniff",
            ),
        ],
        "Web 书源访问令牌未配置或不正确",
    )
        .into_response()
}

/// 是否 WebSocket 升级请求（对齐 NanoHTTPD `isWebsocketRequested` 的
/// `Connection: Upgrade` + `Upgrade: websocket` 判定）
fn is_websocket_request(headers: &HeaderMap) -> bool {
    let connection_ok = headers
        .get_all(header::CONNECTION)
        .iter()
        .filter_map(|v| v.to_str().ok())
        .any(|v| {
            v.split(',')
                .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
        });
    let upgrade_ok = headers
        .get(header::UPGRADE)
        .and_then(|v| v.to_str().ok())
        .map(|v| v.trim().eq_ignore_ascii_case("websocket"))
        .unwrap_or(false);
    connection_ok && upgrade_ok
}

// ─── 路由 ───────────────────────────────────────────────────────────────────

/// 原版 WebSocket 监听路由（挂在 `port+1` 的独立 listener 上）
///
/// 仅包含原版两条调试路径；未知路径按原版返回 404
/// `WebSocket route not found`（非 WS 请求返回空 404，对齐 NanoHTTPD 默认）。
pub fn legacy_ws_routes(state: Arc<AppState>) -> Router {
    Router::new()
        .route(
            "/bookSourceDebug",
            get(book_source_debug_ws).with_state(Arc::clone(&state)),
        )
        .route(
            "/rssSourceDebug",
            get(rss_source_debug_ws).with_state(Arc::clone(&state)),
        )
        .fallback(ws_port_fallback)
        .with_state(state)
}

/// 未知 WS 路径（`WebSocketServer.kt:11-18`）
async fn ws_port_fallback(headers: HeaderMap) -> Response {
    if is_websocket_request(&headers) {
        (
            StatusCode::NOT_FOUND,
            [
                (header::CONTENT_TYPE, "text/plain; charset=utf-8"),
                (
                    header::HeaderName::from_static("x-content-type-options"),
                    "nosniff",
                ),
            ],
            "WebSocket route not found",
        )
            .into_response()
    } else {
        StatusCode::NOT_FOUND.into_response()
    }
}

/// 调试连接类型
#[derive(Clone, Copy)]
enum DebugKind {
    BookSource,
    RssSource,
}

/// `/bookSourceDebug`（`WebSocketServer.kt:36-38`）
pub async fn book_source_debug_ws(
    State(state): State<Arc<AppState>>,
    request: Request,
) -> Response {
    upgrade_debug(request, state, DebugKind::BookSource).await
}

/// `/rssSourceDebug`（`WebSocketServer.kt:39-41`）
pub async fn rss_source_debug_ws(State(state): State<Arc<AppState>>, request: Request) -> Response {
    upgrade_debug(request, state, DebugKind::RssSource).await
}

/// 握手前检查顺序：是否 WS 请求 → 子协议鉴权 → 升级
async fn upgrade_debug(request: Request, state: Arc<AppState>, kind: DebugKind) -> Response {
    let (mut parts, _body) = request.into_parts();
    if !is_websocket_request(&parts.headers) {
        // 原版非 WS 请求落到 NanoHTTPD 默认 404（无正文）
        return StatusCode::NOT_FOUND.into_response();
    }
    let config = load_js_source_api_config(&state).await;
    if !validate_websocket_protocol(&parts.headers, &config) {
        return forbidden_response();
    }
    let ws = match WebSocketUpgrade::from_request_parts(&mut parts, &state).await {
        Ok(ws) => ws,
        Err(rejection) => return rejection.into_response(),
    };
    // 回选 `legado`（客户端恰好提供时才设置响应头；浏览器/ws 客户端均接受）
    ws.protocols([LEGADO_WS_PROTOCOL])
        .on_upgrade(move |socket| async move {
            match kind {
                DebugKind::BookSource => handle_book_source_debug(socket, state).await,
                DebugKind::RssSource => handle_rss_source_debug(socket, state).await,
            }
        })
}

// ─── 首包（认证数据）────────────────────────────────────────────────────────

/// 首包解析结果
enum FirstMessage {
    /// JSON 对象：tag/key（缺省或 null 为 None）
    Parsed {
        tag: Option<String>,
        key: Option<String>,
    },
    /// 非 JSON 或 JSON 非对象/字段类型非法 → close 1008
    InvalidFormat,
}

/// Gson `Map<String, String>` 的宽松取值：字符串/数字/布尔转字符串，
/// null 与缺省为 None，对象/数组视为形态不符。
fn lenient_string(map: &serde_json::Map<String, Value>, field: &str) -> Result<Option<String>, ()> {
    match map.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(Value::Number(n)) => Ok(Some(n.to_string())),
        Some(Value::Bool(b)) => Ok(Some(b.to_string())),
        Some(Value::Array(_)) | Some(Value::Object(_)) => Err(()),
    }
}

/// 解析首包（`BookSourceDebugWebSocket.kt:79-90`）
fn parse_first_message(text: &str) -> FirstMessage {
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(map)) => {
            match (lenient_string(&map, "tag"), lenient_string(&map, "key")) {
                (Ok(tag), Ok(key)) => FirstMessage::Parsed { tag, key },
                _ => FirstMessage::InvalidFormat,
            }
        }
        _ => FirstMessage::InvalidFormat,
    }
}

/// 在 10s 认证窗口内读取首条文本消息
///
/// 返回 `None` 表示连接已关闭/读错误/超时（超时与格式错误已在此处回写关闭帧）。
async fn read_first_message(socket: &mut WebSocket) -> Option<String> {
    let deadline = tokio::time::Instant::now() + AUTH_TIMEOUT;
    loop {
        match tokio::time::timeout_at(deadline, socket.recv()).await {
            Err(_) => {
                close_with(socket, CLOSE_POLICY_VIOLATION, CLOSE_REASON_AUTH_TIMEOUT).await;
                return None;
            }
            Ok(None) => return None,
            Ok(Some(Err(_))) => return None,
            Ok(Some(Ok(Message::Text(text)))) => return Some(text.to_string()),
            Ok(Some(Ok(Message::Binary(_)))) => {
                close_with(socket, CLOSE_POLICY_VIOLATION, CLOSE_REASON_BAD_AUTH).await;
                return None;
            }
            Ok(Some(Ok(Message::Close(_)))) => return None,
            // Ping/Pong 由底层自动应答，认证窗口内继续等待
            Ok(Some(Ok(_))) => {}
        }
    }
}

// ─── 会话主循环 ─────────────────────────────────────────────────────────────

/// 调试任务 → 连接循环的事件
pub(crate) enum DebugEvent {
    /// 一条原版日志（已含时间前缀，或 `showTime=false` 的原样空行）
    Log(String),
    /// 失败行（原版 state=-1 的文本；原版通道按普通文本推送后关闭，
    /// 自研通道据此映射 `debug_error`）
    Error(String),
    /// 调试结束（state 1000 / -1）
    Done,
}

/// 书源调试连接（`BookSourceDebugWebSocket`）
async fn handle_book_source_debug(mut socket: WebSocket, state: Arc<AppState>) {
    let Some(text) = read_first_message(&mut socket).await else {
        return;
    };
    let (tag, key) = match parse_first_message(&text) {
        FirstMessage::Parsed { tag, key } => (tag, key),
        FirstMessage::InvalidFormat => {
            close_with(&mut socket, CLOSE_POLICY_VIOLATION, CLOSE_REASON_BAD_AUTH).await;
            return;
        }
    };
    if tag.as_deref().map(str::trim).unwrap_or("").is_empty()
        || key.as_deref().map(str::trim).unwrap_or("").is_empty()
    {
        send_then_close(
            &mut socket,
            MSG_CANNOT_EMPTY,
            CLOSE_NORMAL,
            CLOSE_REASON_FINISH,
        )
        .await;
        return;
    }
    let tag = tag.unwrap_or_default();
    let key = key.unwrap_or_default();

    let source = {
        let db = state.db.lock().await;
        let lookup = BookSourceRepository::new(db.connection()).find_by_url(&tag);
        // 显式结束 db guard / repository 的借用，避免非 Send 的
        // `rusqlite::Connection` 跨越后续 await（axum on_upgrade 要求 Send）
        drop(db);
        match lookup {
            Ok(Some(source)) => Some(source),
            Ok(None) => None,
            Err(e) => {
                tracing::warn!("WS 书源调试读取书源失败: {e}");
                close_with(&mut socket, CLOSE_INTERNAL_ERROR, CLOSE_REASON_DEBUG_FAILED).await;
                return;
            }
        }
    };
    let Some(source) = source else {
        send_then_close(&mut socket, "书源不存在", CLOSE_NORMAL, CLOSE_REASON_FINISH).await;
        return;
    };

    let Some(slot) = DebugSlot::try_acquire() else {
        send_then_close(
            &mut socket,
            MSG_DEBUG_BUSY,
            CLOSE_NORMAL,
            CLOSE_REASON_FINISH,
        )
        .await;
        return;
    };

    let (tx, rx) = mpsc::unbounded_channel();
    let sink = DebugSink::new(tx);
    // 请求级日志：把观测回调注入本调试任务的作用域（`legado_net` 任务局部
    // 槽，独立于全局 HttpLogStore 单槽），任务结束即失效
    let task = tokio::spawn(legado_net::scope_debug_request_sink(
        sink.request_sink(),
        run_book_source_debug(state, source, key, sink),
    ));
    pump_debug_session(&mut socket, rx, task).await;
    drop(slot);
}

/// 订阅源调试连接（`RssSourceDebugWebSocket`）
///
/// 首包只校验 `tag`（原版 RSS WS 不读取 `key`）；`key` 非空时按原版 App
/// 调试页三参分流执行（见 [`run_rss_source_debug`]），为空时复刻 WS 两参流程。
async fn handle_rss_source_debug(mut socket: WebSocket, state: Arc<AppState>) {
    let Some(text) = read_first_message(&mut socket).await else {
        return;
    };
    let (tag, key) = match parse_first_message(&text) {
        FirstMessage::Parsed { tag, key } => (tag, key),
        FirstMessage::InvalidFormat => {
            close_with(&mut socket, CLOSE_POLICY_VIOLATION, CLOSE_REASON_BAD_AUTH).await;
            return;
        }
    };
    if tag.as_deref().map(str::trim).unwrap_or("").is_empty() {
        send_then_close(
            &mut socket,
            MSG_CANNOT_EMPTY,
            CLOSE_NORMAL,
            CLOSE_REASON_FINISH,
        )
        .await;
        return;
    }
    let tag = tag.unwrap_or_default();

    let source = {
        let db = state.db.lock().await;
        let lookup = RssSourceRepository::new(db.connection()).find_by_url(&tag);
        drop(db);
        match lookup {
            Ok(Some(source)) => Some(source),
            Ok(None) => None,
            Err(e) => {
                tracing::warn!("WS 订阅源调试读取订阅源失败: {e}");
                close_with(&mut socket, CLOSE_INTERNAL_ERROR, CLOSE_REASON_DEBUG_FAILED).await;
                return;
            }
        }
    };
    let Some(source) = source else {
        send_then_close(
            &mut socket,
            "订阅源不存在",
            CLOSE_NORMAL,
            CLOSE_REASON_FINISH,
        )
        .await;
        return;
    };

    let Some(slot) = DebugSlot::try_acquire() else {
        send_then_close(
            &mut socket,
            MSG_DEBUG_BUSY,
            CLOSE_NORMAL,
            CLOSE_REASON_FINISH,
        )
        .await;
        return;
    };

    let (tx, rx) = mpsc::unbounded_channel();
    let sink = DebugSink::new(tx);
    // 与书源调试同一单槽 + 同一 task-local 请求观测面
    let task = tokio::spawn(legado_net::scope_debug_request_sink(
        sink.request_sink(),
        run_rss_source_debug(Arc::clone(&state), source, key, sink),
    ));
    pump_debug_session(&mut socket, rx, task).await;
    drop(slot);
}

/// 事件泵：转发调试日志、发送心跳、响应客户端关闭
async fn pump_debug_session(
    socket: &mut WebSocket,
    mut rx: mpsc::UnboundedReceiver<DebugEvent>,
    task: tokio::task::JoinHandle<()>,
) {
    // interval_at 的首个 tick 在 now + period，等价于原版「认证后 30s 才发首个 ping」
    let mut heartbeat = tokio::time::interval_at(
        tokio::time::Instant::now() + HEARTBEAT_INTERVAL,
        HEARTBEAT_INTERVAL,
    );
    loop {
        tokio::select! {
            biased;
            event = rx.recv() => match event {
                Some(DebugEvent::Log(line)) | Some(DebugEvent::Error(line)) => {
                    if send_text(socket, &line).await.is_err() {
                        break;
                    }
                }
                Some(DebugEvent::Done) | None => {
                    close_with(socket, CLOSE_NORMAL, CLOSE_REASON_FINISH).await;
                    break;
                }
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => break,
                // 认证后客户端消息按原版忽略
                Some(Ok(_)) => {}
            },
            _ = heartbeat.tick() => {
                if socket
                    .send(Message::Ping(axum::body::Bytes::from_static(b"ping")))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        }
    }
    task.abort();
}

// ─── 书源调试执行（阶段级 + 请求级真实日志）─────────────────────────────────

/// 调试日志发送器（负责原版时间前缀 + 请求级观测行）
///
/// `Clone` 是为了同时交给调试主流程与 `legado_net` 的任务局部请求观测回调
/// （同一 `tx`，两条写入路径按完成顺序交错，与真实执行顺序一致）。
#[derive(Clone)]
pub(crate) struct DebugSink {
    tx: mpsc::UnboundedSender<DebugEvent>,
    start: Instant,
}

impl DebugSink {
    pub(crate) fn new(tx: mpsc::UnboundedSender<DebugEvent>) -> Self {
        Self {
            tx,
            start: Instant::now(),
        }
    }

    /// `Debug.log(showTime = true)`
    pub(crate) fn log(&self, msg: impl AsRef<str>) {
        let line = format!("{} {}", format_elapsed(self.start.elapsed()), msg.as_ref());
        let _ = self.tx.send(DebugEvent::Log(line));
    }

    /// `Debug.log(showTime = false)`（原版用于阶段间空行）
    pub(crate) fn log_plain(&self, msg: impl AsRef<str>) {
        let _ = self.tx.send(DebugEvent::Log(msg.as_ref().to_string()));
    }

    pub(crate) fn done(&self) {
        let _ = self.tx.send(DebugEvent::Done);
    }

    /// 带 state 的原版日志（`Debug.Callback.printLog(state, msg)`）
    ///
    /// - state 10/20/30/40（响应体行）直接丢弃（原版 `notPrintState`）；
    /// - state -1 → 失败行（自研通道映射 `debug_error`）并结束；
    /// - state 1000 → 结束行（打印后 close 1000「调试结束」）。
    fn log_state(&self, state: i32, msg: impl AsRef<str>) {
        if RSS_NOT_PRINT_STATES.contains(&state) {
            return;
        }
        let line = format!("{} {}", format_elapsed(self.start.elapsed()), msg.as_ref());
        let event = if state == -1 {
            DebugEvent::Error(line)
        } else {
            DebugEvent::Log(line)
        };
        let _ = self.tx.send(event);
        if state == -1 || state == 1000 {
            self.done();
        }
    }

    /// 错误分支（原版 state = -1，随后 printLog 关闭连接）
    pub(crate) fn fail(&self, msg: impl AsRef<str>) {
        self.log_state(-1, msg);
    }

    /// 单条 HTTP 请求的观测输出（请求级日志）
    ///
    /// - 成功：先输出原版请求行 `≡获取成功:<url>`（`BookList.kt:53` 等四阶段
    ///   同款），再输出测量行（方法/状态/耗时/响应体字节数）；
    /// - 失败：输出 `≡请求失败 <method> <url> -> -1 <耗时>ms | <错误摘要>`，
    ///   随后由阶段错误链给出完整失败原因（对齐原版 `state = -1` 堆栈行）。
    fn request(&self, entry: &HttpLogEntry) {
        match entry.error.as_deref() {
            None => {
                self.log(success_request_line(&entry.url));
                self.log(request_measure_line(entry));
            }
            Some(_) => self.log(request_failure_line(entry)),
        }
    }

    /// 构造注入 `legado_net` 任务局部观测槽的回调（仅本调试任务内生效）
    pub(crate) fn request_sink(&self) -> legado_net::DebugRequestSink {
        let sink = self.clone();
        std::sync::Arc::new(move |entry: HttpLogEntry| sink.request(&entry))
    }
}

/// 原版请求行（四阶段解析入口逐请求打印，如 `BookList.kt:53`）
fn success_request_line(url: &str) -> String {
    format!("≡获取成功:{url}")
}

/// 请求测量行：`≡请求 <method> <url> -> <status> <duration>ms <bytes>B`
///
/// 全部字段取自 `LegadoClient` 的真实采集记录（重试/重定向链只记最终一次）；
/// 字节数为响应体文本长度（流式路径采集侧留空 → 0B，见 `legado_net::http_log`）。
fn request_measure_line(entry: &HttpLogEntry) -> String {
    format!(
        "≡请求 {} {} -> {} {}ms {}B",
        entry.method,
        entry.url,
        entry.status_code,
        entry.duration_ms,
        entry.response_body.len()
    )
}

/// 请求失败行（`statusCode = -1` 对齐 `HttpLogInterceptor` 异常分支）
fn request_failure_line(entry: &HttpLogEntry) -> String {
    let error = entry.error.as_deref().unwrap_or("");
    format!(
        "≡请求失败 {} {} -> -1 {}ms | {}",
        entry.method, entry.url, entry.duration_ms, error
    )
}

/// 失败错误链（`Display`，部分变体附逐层 `source()`；原版打印 Kotlin 堆栈）
fn format_error_chain(error: &legado_core::LegadoError) -> String {
    use std::error::Error as _;
    let mut out = error.to_string();
    let mut source = error.source();
    while let Some(inner) = source {
        out.push_str("\n原因: ");
        out.push_str(&inner.to_string());
        source = inner.source();
    }
    out
}

/// `[mm:ss.SSS]`（对齐 `SimpleDateFormat("[mm:ss.SSS]")` 的 elapsed 格式）
fn format_elapsed(elapsed: Duration) -> String {
    let total_ms = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
    // SimpleDateFormat 的 mm 是「分钟数对 60 取模」，超过 1 小时回绕
    let minutes = (total_ms / 60_000) % 60;
    let seconds = (total_ms / 1_000) % 60;
    let millis = total_ms % 1_000;
    format!("[{minutes:02}:{seconds:02}.{millis:03}]")
}

/// 原版 `String.isAbsUrl()`（`StringExtensions.kt:38-42`）
fn is_abs_url(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// 调试用书源上下文（fetcher 四入口入参 + 日志所需的规则存在性判定）
struct DebugSource {
    /// 序列化后的书源 JSON（`legado_fetcher::web_book` 四入口入参）
    json: String,
    /// 文件类书源（`bookSourceType & WEB_FILE != 0`，对齐原版 `book.isWebFile`）
    file_source: bool,
    /// 详情页初始化规则存在且非空白（对齐 `BookInfo.kt:59-62` 的
    /// `≡执行详情页初始化规则` 门控）
    has_init_rule: bool,
}

/// 书源调试主流程（`Debug.startDebug(bookSource, key)`，`Debug.kt:452-496`）
async fn run_book_source_debug(
    state: Arc<AppState>,
    source: legado_core::models::BookSource,
    key: String,
    sink: DebugSink,
) {
    let source_json = match serde_json::to_string(&source) {
        Ok(json) => json,
        Err(e) => {
            sink.fail(format!("书源序列化失败: {e}"));
            return;
        }
    };
    let deps = match server_deps(&state) {
        Ok(deps) => deps,
        Err(e) => {
            sink.fail(format!("抓取依赖初始化失败: {e}"));
            return;
        }
    };
    let ctx = DebugSource {
        json: source_json,
        file_source: legado_fetcher::book_type::book_type_of_source(source.book_source_type)
            & legado_fetcher::book_type::WEB_FILE
            != 0,
        has_init_rule: source
            .rule_book_info
            .as_ref()
            .and_then(|rule| rule.init.as_deref())
            .is_some_and(|init| !init.trim().is_empty()),
    };

    // 分派顺序与原版一致：绝对 URL → 发现 → 目录 → 正文 → 搜索
    if is_abs_url(&key) {
        sink.log(format!("⇒开始访问详情页:{key}"));
        info_stage(&sink, &deps, &ctx, &key).await;
    } else if key.contains("::") {
        let url = key.split_once("::").map(|(_, url)| url).unwrap_or("");
        sink.log(format!("⇒开始访问发现页:{url}"));
        sink.log("︾开始解析发现页");
        sink.fail("≡服务端未接入发现规则引擎，本次发现页调试未执行");
    } else if let Some(url) = key.strip_prefix("++") {
        sink.log(format!("⇒开始访目录页:{url}"));
        toc_stage(&sink, &deps, &ctx, url, url, "").await;
    } else if let Some(url) = key.strip_prefix("--") {
        sink.log(format!("⇒开始访正文页:{url}"));
        let chapter = serde_json::json!({
            "index": 0,
            "title": "调试",
            "url": url,
            "is_vip": false,
        });
        content_stage(&sink, &deps, &ctx, chapter).await;
    } else {
        sink.log(format!("⇒开始搜索关键字:{key}"));
        search_stage(&sink, &deps, &ctx, &key).await;
    }
}

/// 搜索阶段（`Debug.searchDebug`，`Debug.kt:520-540`）
async fn search_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source: &DebugSource,
    key: &str,
) {
    sink.log("︾开始解析搜索页");
    match legado_fetcher::web_book::webbook_search(deps.clone(), &source.json, key, 1).await {
        Ok(json) => {
            match serde_json::from_str::<Vec<legado_core::web_book::WebSearchResult>>(&json) {
                Ok(results) if results.is_empty() => sink.fail("︽未获取到书籍"),
                Ok(results) => {
                    // 原版 `BookList.getSearchItem` 只对首条打印字段行
                    // （`log = index == 0`，`BookList.kt:219-285`）
                    log_search_item(sink, &results[0]);
                    sink.log(format!("◇书籍总数:{}", results.len()));
                    sink.log("︽搜索页解析完成");
                    sink.log_plain("");
                    let first = &results[0];
                    info_stage(sink, deps, source, &first.book_url).await;
                }
                Err(e) => sink.fail(format!("搜索结果解析失败: {e}")),
            }
        }
        Err(e) => sink.fail(format_error_chain(&e)),
    }
}

/// 搜索首条结果的字段行（对齐 `BookList.kt:219-285`：`┌字段名`/`└求值结果`）
///
/// 值取自 fetcher 真实返回的 `WebSearchResult`（规则求值产物），缺失字段按
/// 原版 `?: ""` 口径输出空值行。
fn log_search_item(sink: &DebugSink, item: &legado_core::web_book::WebSearchResult) {
    for (title, value) in [
        ("┌获取书名", item.name.as_str()),
        ("┌获取作者", item.author.as_str()),
        ("┌获取分类", item.kind.as_deref().unwrap_or("")),
        ("┌获取字数", item.word_count.as_deref().unwrap_or("")),
        (
            "┌获取最新章节",
            item.latest_chapter.as_deref().unwrap_or(""),
        ),
        ("┌获取简介", item.intro.as_deref().unwrap_or("")),
        ("┌获取封面链接", item.cover_url.as_deref().unwrap_or("")),
        ("┌获取详情页链接", item.book_url.as_str()),
    ] {
        sink.log(title);
        sink.log(format!("└{value}"));
    }
}

/// 详情阶段（`Debug.infoDebug`，`Debug.kt:542-568`）
async fn info_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source: &DebugSource,
    book_url: &str,
) {
    sink.log("︾开始解析详情页");
    match legado_fetcher::web_book::webbook_info(deps.clone(), &source.json, book_url).await {
        Ok(json) => match serde_json::from_str::<legado_core::web_book::WebBookInfo>(&json) {
            Ok(info) => {
                log_info_fields(sink, source, &info);
                sink.log("︽详情页解析完成");
                sink.log_plain("");
                if source.file_source {
                    sink.log("≡文件类书源跳过解析目录");
                    sink.done();
                } else {
                    let toc_url = info.toc_url.clone();
                    toc_stage(sink, deps, source, &info.book_url, &toc_url, &info.name).await;
                }
            }
            Err(e) => sink.fail(format!("详情结果解析失败: {e}")),
        },
        Err(e) => sink.fail(format_error_chain(&e)),
    }
}

/// 详情字段行（对齐 `BookInfo.kt:59-170`）
///
/// 字段名与原版一致；值取自 fetcher 真实求值结果 `WebBookInfo`。逐规则
/// 求值过程（单规则命中/JS 分支/异常字段的 `localizedMessage`）不可得，
/// 已在模块文档登记为未覆盖。
fn log_info_fields(
    sink: &DebugSink,
    source: &DebugSource,
    info: &legado_core::web_book::WebBookInfo,
) {
    if source.has_init_rule {
        sink.log("≡执行详情页初始化规则");
    }
    for (title, value) in [
        ("┌获取书名", info.name.as_str()),
        ("┌获取作者", info.author.as_str()),
        ("┌获取分类", info.kind.as_deref().unwrap_or("")),
        ("┌获取字数", info.word_count.as_deref().unwrap_or("")),
        ("┌获取最新章节", info.last_chapter.as_deref().unwrap_or("")),
        ("┌获取简介", info.intro.as_deref().unwrap_or("")),
        ("┌获取封面链接", info.cover_url.as_deref().unwrap_or("")),
    ] {
        sink.log(title);
        sink.log(format!("└{value}"));
    }
    if source.file_source {
        // 原版文件类书源改打印下载链接（`BookInfo.kt:163-176`）
        sink.log("┌获取文件下载链接");
        match info.download_urls.as_deref() {
            Some(urls) if !urls.is_empty() => sink.log(format!("└{}", urls.join("，\n"))),
            _ => sink.log("└"),
        }
    } else {
        sink.log("┌获取目录链接");
        sink.log(format!("└{}", info.toc_url));
    }
}

/// 目录阶段（`Debug.tocDebug`，`Debug.kt:570-592`）
async fn toc_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source: &DebugSource,
    book_url: &str,
    toc_url: &str,
    book_name: &str,
) {
    sink.log("︾开始解析目录页");
    match legado_fetcher::web_book::webbook_chapters(
        deps.clone(),
        &source.json,
        book_url,
        toc_url,
        book_name,
    )
    .await
    {
        Ok(json) => match serde_json::from_str::<Vec<legado_core::web_book::WebChapter>>(&json) {
            Ok(chapters) => {
                // 原版列表解析尾段仅在有元素时输出（`BookChapterList.kt:227-289`）
                if !chapters.is_empty() {
                    sink.log("┌解析目录列表");
                    sink.log("└目录列表解析完成");
                }
                // `◇目录总数` 用 fetcher 去重后的长度（含卷章），对齐
                // `BookChapterList.kt:127-134` 的 LinkedHashSet 统计口径
                let total = chapters.len();
                // 原版过滤卷章：!(isVolume && url.startsWith(title))
                let toc: Vec<_> = chapters
                    .into_iter()
                    .filter(|c| !(c.is_volume && c.url.starts_with(&c.title)))
                    .collect();
                match toc.first() {
                    Some(first) => {
                        // 原版顺序：首章信息（列表解析尾段）→ 目录总数（外层统计）
                        log_first_chapter(sink, first);
                        sink.log(format!("◇目录总数:{total}"));
                        sink.log("︽目录页解析完成");
                        sink.log_plain("");
                        // 保留章节全字段（variable/tag 等），与原版 WebBook 入参一致
                        match serde_json::to_value(first) {
                            Ok(chapter) => content_stage(sink, deps, source, chapter).await,
                            Err(e) => sink.fail(format!("章节序列化失败: {e}")),
                        }
                    }
                    None => {
                        // 空目录：先补目录总数与阶段完成行，再报「没有正文章节」
                        // （对齐 `BookChapterList.kt:134` 与 `Debug.kt:570-592`）
                        sink.log(format!("◇目录总数:{total}"));
                        sink.log("︽目录页解析完成");
                        sink.log_plain("");
                        sink.fail("≡没有正文章节");
                    }
                }
            }
            Err(e) => sink.fail(format!("目录结果解析失败: {e}")),
        },
        Err(e) => sink.fail(format_error_chain(&e)),
    }
}

/// 首章信息行（对齐 `BookChapterList.kt:293-303`）
fn log_first_chapter(sink: &DebugSink, chapter: &legado_core::web_book::WebChapter) {
    sink.log("≡首章信息");
    sink.log(format!("◇章节名称:{}", chapter.title));
    sink.log(format!("◇章节链接:{}", chapter.url));
    match chapter.word_count.as_deref() {
        Some(word_count) if !word_count.trim().is_empty() => {
            sink.log(format!(
                "◇章节信息:{} {word_count}",
                chapter.tag.as_deref().unwrap_or("")
            ));
            sink.log("⇒已识别到章节信息中的字数");
        }
        _ => sink.log(format!(
            "◇章节信息:{}",
            chapter.tag.as_deref().unwrap_or("")
        )),
    }
    sink.log(format!("◇是否VIP:{}", chapter.is_vip));
    sink.log(format!("◇是否购买:{}", chapter.is_pay));
}

/// 正文阶段（`Debug.contentDebug`，`Debug.kt:594-620`）
async fn content_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source: &DebugSource,
    chapter: Value,
) {
    sink.log("︾开始解析正文页");
    match legado_fetcher::web_book::webbook_content(
        deps.clone(),
        &source.json,
        &chapter.to_string(),
    )
    .await
    {
        Ok(content) => {
            // 原版 `BookContent.kt:199-203`：章节名称 + 正文全文
            let title = chapter
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or_default();
            sink.log("┌获取章节名称");
            sink.log(format!("└{title}"));
            sink.log("┌获取正文内容");
            sink.log(format!("└\n{content}"));
            sink.log("︽正文页解析完成");
            sink.done();
        }
        Err(e) => sink.fail(format_error_chain(&e)),
    }
}

// ─── 订阅源调试执行（批15e：15a/15b/15c RSS 引擎）────────────────────────────

/// RSS 调试执行上下文（引擎入参 + 宿主登录缓存快照）
struct RssDebugContext {
    /// 订阅源（含规则/分类/搜索配置）
    source: legado_core::models::RssSource,
    /// 抓取客户端（server_deps 注入：DB cookie 持久化）
    client: legado_net::LegadoClient,
    /// 源级限流注册表（与书源共享窗口语义）
    rate_limiter: Arc<legado_fetcher::rate_limit::RateLimiterRegistry>,
    /// `loginHeader_<url>`（同源门控在引擎内完成）
    login_header: Option<String>,
    /// `userInfo_<url>`
    login_info: Option<String>,
}

impl RssDebugContext {
    /// 组装调试上下文（DB 读在锁内完成，随后立即释放）
    async fn build(
        state: &Arc<AppState>,
        source: legado_core::models::RssSource,
    ) -> legado_core::LegadoResult<Self> {
        let legado_fetcher::deps::FetcherDeps {
            client,
            rate_limiter,
            login_header,
            ..
        } = server_deps(state)?;
        let login_header = login_header
            .as_ref()
            .and_then(|lookup| lookup(&source.source_url));
        let login_info = {
            let db = state.db.lock().await;
            CacheRepository::new(db.connection())
                .get(&format!("userInfo_{}", source.source_url))
                .ok()
                .flatten()
        };
        Ok(Self {
            source,
            client,
            rate_limiter,
            login_header,
            login_info,
        })
    }
}

/// `ruleArticles` 非空白（对齐 Kotlin `isNullOrBlank` 取反）
fn has_rule_articles(source: &legado_core::models::RssSource) -> bool {
    source
        .rule_articles
        .as_deref()
        .is_some_and(|rule| !rule.trim().is_empty())
}

/// 规则是否为空/空白（对齐 Kotlin `isNullOrBlank`）
fn rule_is_blank(rule: Option<&str>) -> bool {
    rule.map(str::trim).unwrap_or("").is_empty()
}

/// 订阅源调试执行入口（原版 WS 两参 / App 调试页三参共用，单实现）
///
/// - `key` 为空/缺省：`Debug.startDebug(scope, rssSource)`（`Debug.kt:309-343`），
///   即原版 `/rssSourceDebug` 首包只有 `tag` 时的真实行为；
/// - `key` 非空：`Debug.startDebug(scope, rssSource, key)`（`Debug.kt:346-410`）
///   三路分流（`::` 分类 / 绝对 URL 正文 / 其它搜索），供自研通道与
///   `api.md` 声明的 `{key, tag}` 请求体使用。
pub(crate) async fn run_rss_source_debug(
    state: Arc<AppState>,
    source: legado_core::models::RssSource,
    key: Option<String>,
    sink: DebugSink,
) {
    let ctx = match RssDebugContext::build(&state, source).await {
        Ok(ctx) => ctx,
        Err(e) => {
            sink.fail(format_error_chain(&e));
            return;
        }
    };
    let key = key.as_deref().map(str::trim).filter(|key| !key.is_empty());
    match key {
        None => rss_default_debug(&state, &sink, &ctx).await,
        Some(key) => rss_keyed_debug(&sink, &ctx, key).await,
    }
}

/// 原版两参入口（`Debug.kt:309-343`）：默认分类首项 → 列表 → 内容
async fn rss_default_debug(state: &Arc<AppState>, sink: &DebugSink, ctx: &RssDebugContext) {
    sink.log("︾开始解析");
    let sorts = resolve_rss_sort_urls(state, ctx).await;
    // `sortUrls().firstOrNull() ?: ("" to sourceUrl)`
    let (sort_name, sort_url) = sorts
        .first()
        .map(|entry| (entry.name.clone(), entry.url.clone()))
        .unwrap_or_else(|| (String::new(), ctx.source.source_url.clone()));
    rss_sort_debug(sink, ctx, &sort_name, &sort_url, None).await;
}

/// 原版三参入口（`Debug.kt:346-410`）：`::` 分类 / 绝对 URL 正文 / 其它搜索
async fn rss_keyed_debug(sink: &DebugSink, ctx: &RssDebugContext, key: &str) {
    if key.contains("::") {
        // `substringBefore/substringAfter("::")`：不 trim，与原版一致
        let (name, url) = key.split_once("::").unwrap_or(("", key));
        sink.log(format!("⇒开始访问分类页:{url}"));
        sink.log("︾开始解析分类页");
        rss_sort_debug(sink, ctx, name, url, None).await;
        return;
    }
    if is_abs_url(key) {
        rss_abs_url_debug(sink, ctx, key).await;
        return;
    }
    let search_url = ctx.source.search_url.as_deref().unwrap_or("");
    if search_url.is_empty() {
        // 原版 `⇒搜索URL为空`, state = -1（打印后关闭）
        sink.fail("⇒搜索URL为空");
        return;
    }
    sink.log(format!("⇒开始搜索关键字:{key}"));
    sink.log("︾开始解析搜索页");
    rss_sort_debug(sink, ctx, "搜索", search_url, Some(key)).await;
}

/// 绝对 URL 调试（`Debug.kt:353-373`）：仅「规则列表源 + 无描述规则」解析正文
async fn rss_abs_url_debug(sink: &DebugSink, ctx: &RssDebugContext, key: &str) {
    if !has_rule_articles(&ctx.source) || !rule_is_blank(ctx.source.rule_description.as_deref()) {
        sink.log("⇒存在描述规则，不解析内容页");
        sink.log_state(1000, "︽解析完成");
        return;
    }
    let rule_content = ctx.source.rule_content.as_deref().unwrap_or("");
    if rule_content.is_empty() {
        sink.log_state(1000, "⇒内容规则为空，默认获取整个网页");
        return;
    }
    sink.log(format!("⇒开始访问内容页:{key}"));
    // 原版 `RssArticle().apply { origin = sourceUrl; link = key }`（type 默认 0）
    let article = RssArticleItem {
        origin: ctx.source.source_url.clone(),
        link: key.to_string(),
        ..Default::default()
    };
    rss_content_debug(sink, ctx, &article).await;
}

/// 列表阶段（`Debug.sortDebug`，`Debug.kt:375-427`）
async fn rss_sort_debug(
    sink: &DebugSink,
    ctx: &RssDebugContext,
    sort_name: &str,
    sort_url: &str,
    key: Option<&str>,
) {
    let fetched = legado_fetcher::rss::fetch_articles(
        &ctx.client,
        ctx.rate_limiter.as_ref(),
        &ctx.source,
        sort_name,
        sort_url,
        Some(1),
        key,
        ctx.login_header.as_deref(),
        ctx.login_info.as_deref(),
    )
    .await;
    let page = match fetched {
        Ok(page) => page,
        Err(e) => {
            sink.fail(format_error_chain(&e));
            return;
        }
    };

    log_rss_list_parse(sink, ctx, &page);

    if page.items.is_empty() {
        sink.log("⇒列表页解析成功，为空");
        sink.log_state(1000, "︽解析完成");
        return;
    }
    if has_rule_articles(&ctx.source) && rule_is_blank(ctx.source.rule_description.as_deref()) {
        sink.log("︽列表页解析完成");
        // 原版 `log(debugSource, showTime = false)` 阶段间空行
        sink.log_plain("");
        let rule_content = ctx.source.rule_content.as_deref().unwrap_or("");
        if rule_content.is_empty() {
            sink.log_state(1000, "⇒内容规则为空，默认获取整个网页");
        } else {
            rss_content_debug(sink, ctx, &page.items[0]).await;
        }
    } else {
        sink.log("⇒存在描述规则，不解析内容页");
        sink.log_state(1000, "︽解析完成");
    }
}

/// 列表解析阶段行（对齐 `RssParserByRule.kt:32-92` + `RssParserDefault.kt:101-112`）
///
/// 默认规则分支：`⇒列表规则为空, 使用默认规则解析`，随后在默认解析**列表非空**
/// 时按首条打印同款 10 行字段族（可空字段以 `null` 字面量输出）；规则列表分支
/// 打印列表大小、下一页链接与首条字段族。`└列表大小` 用真实文章数
/// （原版为去空标题前的原始元素数，已在模块文档登记差异）。
fn log_rss_list_parse(sink: &DebugSink, ctx: &RssDebugContext, page: &RssListPage) {
    if !has_rule_articles(&ctx.source) {
        sink.log("⇒列表规则为空, 使用默认规则解析");
        // `RssParserDefault.kt:101-112`：默认解析在 `parseXML` 返回前对
        // `firstOrNull()` 打印字段族；列表为空时整组不打印
        if let Some(first) = page.items.first() {
            log_rss_default_first_item(sink, first);
        }
        return;
    }
    sink.log("┌获取列表");
    sink.log(format!("└列表大小:{}", page.items.len()));
    if ctx
        .source
        .rule_next_page
        .as_deref()
        .is_some_and(|rule| !rule.is_empty())
    {
        sink.log("┌获取下一页链接");
        sink.log(format!("└{}", page.next_url.as_deref().unwrap_or("")));
    }
    if let Some(first) = page.items.first() {
        log_rss_first_item(sink, ctx, first);
    }
}

/// 首条文章字段族（`RssParserByRule.kt:95-140`，原版仅 `index == 0` 打印）
fn log_rss_first_item(sink: &DebugSink, ctx: &RssDebugContext, item: &RssArticleItem) {
    sink.log("┌获取标题");
    sink.log(format!("└{}", item.title));
    sink.log("┌获取时间");
    // 原版 `getString(rulePubDate)` 无规则/无匹配均返回空串（非 null）
    sink.log(format!("└{}", item.pub_date.as_deref().unwrap_or("")));
    sink.log("┌获取描述");
    if rule_is_blank(ctx.source.rule_description.as_deref()) {
        sink.log("└描述规则为空，将会解析内容页");
    } else {
        sink.log(format!("└{}", item.description.as_deref().unwrap_or("")));
    }
    sink.log("┌获取图片url");
    sink.log(format!("└{}", item.image.as_deref().unwrap_or("")));
    sink.log("┌获取文章链接");
    sink.log(format!("└{}", item.link));
}

/// 默认解析分支的首条字段族（`RssParserDefault.kt:101-112`）
///
/// 原版在 `parseXML` 返回前直接对 `RssArticle` 做 Kotlin 字符串插值：
/// 可空字段（`pubDate`/`description`/`image`）为 `null` 时字面输出 `null`；
/// 与规则列表分支的「描述规则为空，将会解析内容页」不同——默认解析不读规则，
/// 只打印解析结果本身。
fn log_rss_default_first_item(sink: &DebugSink, item: &RssArticleItem) {
    sink.log("┌获取标题");
    sink.log(format!("└{}", item.title));
    sink.log("┌获取时间");
    sink.log(format!("└{}", item.pub_date.as_deref().unwrap_or("null")));
    sink.log("┌获取描述");
    sink.log(format!(
        "└{}",
        item.description.as_deref().unwrap_or("null")
    ));
    sink.log("┌获取图片url");
    sink.log(format!("└{}", item.image.as_deref().unwrap_or("null")));
    sink.log("┌获取文章链接");
    sink.log(format!("└{}", item.link));
}

/// 正文阶段（`Debug.rssContentDebug`，`Debug.kt:412-450`）
async fn rss_content_debug(sink: &DebugSink, ctx: &RssDebugContext, article: &RssArticleItem) {
    sink.log("︾开始解析内容页");
    let article_json = rss_article_js_json(article);
    let fetched = legado_fetcher::rss::content::fetch_content(
        &ctx.client,
        ctx.rate_limiter.as_ref(),
        &ctx.source,
        &article.link,
        article.article_type,
        article.variable.as_deref(),
        Some(&article_json),
        ctx.login_header.as_deref(),
        ctx.login_info.as_deref(),
    )
    .await;
    match fetched {
        Ok(content) => {
            // 原版 `log(debugSource, it)`：正文整段带一次时间前缀（多行原样）
            sink.log(content);
            sink.log_state(1000, "︽内容页解析完成");
        }
        Err(e) => sink.fail(format_error_chain(&e)),
    }
}

/// 文章 → `rssArticle` JS 绑定 JSON（字段名对齐 Kotlin `RssArticle`）
fn rss_article_js_json(article: &RssArticleItem) -> String {
    serde_json::json!({
        "origin": article.origin,
        "sort": article.sort,
        "title": article.title,
        "link": article.link,
        "pubDate": article.pub_date,
        "description": article.description,
        "content": article.content,
        "image": article.image,
        "variable": article.variable,
        "type": article.article_type,
    })
    .to_string()
}

/// `sortUrls()` 解析（15b `sort_urls`）：脚本求值 + DB 缓存
///
/// 缓存键 `rssSortUrl_<md5(sourceUrl + configuredSortUrl)>` 与原版 ACache
/// 同口径；仅在脚本形态配置下读写缓存（同原版）。
async fn resolve_rss_sort_urls(
    state: &Arc<AppState>,
    ctx: &RssDebugContext,
) -> Vec<legado_fetcher::rss::sort_urls::RssSortUrl> {
    let configured = ctx.source.sort_url.as_deref();
    let setup_script = legado_fetcher::source_setup::rss_source_js_setup_script(
        &ctx.source,
        ctx.login_header.as_deref(),
        ctx.login_info.as_deref(),
    )
    .ok();
    let cached = if configured.is_some_and(is_sort_script) {
        let key = sort_cache_key(&ctx.source.source_url, configured);
        let db = state.db.lock().await;
        CacheRepository::new(db.connection())
            .get(&key)
            .ok()
            .flatten()
    } else {
        None
    };
    let mut pending_write: Option<(String, String)> = None;
    let entries = resolve_sort_urls_with_cache(
        &ctx.source.source_url,
        configured,
        |_key| cached.clone(),
        |key, value| pending_write = Some((key.to_string(), value.to_string())),
        |script| evaluate_sort_script(&ctx.source, script, setup_script.clone()),
    );
    if let Some((key, value)) = pending_write {
        let db = state.db.lock().await;
        if let Err(e) = CacheRepository::new(db.connection()).put(&key, &value, 0) {
            tracing::warn!("RSS sortUrl 缓存写入失败（{key}）: {e}");
        }
    }
    entries
}

// ─── 底层收发 ───────────────────────────────────────────────────────────────

/// 发送一条文本消息
async fn send_text(socket: &mut WebSocket, text: &str) -> Result<(), axum::Error> {
    socket.send(Message::Text(text.to_string().into())).await
}

/// 发送关闭帧（忽略发送失败：对端可能已断开）
async fn close_with(socket: &mut WebSocket, code: u16, reason: &str) {
    let _ = socket
        .send(Message::Close(Some(CloseFrame {
            code,
            reason: reason.to_string().into(),
        })))
        .await;
}

/// 先发一条消息，再以指定关闭码结束（对齐 `send(...)` 后 `close(...)`）
async fn send_then_close(socket: &mut WebSocket, text: &str, code: u16, reason: &str) {
    let _ = send_text(socket, text).await;
    close_with(socket, code, reason).await;
}

// ─── 单元测试 ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::HeaderValue;

    fn headers_with_protocol(value: &str) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::SEC_WEBSOCKET_PROTOCOL,
            HeaderValue::from_str(value).unwrap(),
        );
        headers
    }

    #[test]
    fn token_protocol_is_base64url_without_padding() {
        // "secret" -> "c2VjcmV0"（base64url 无 padding）
        assert_eq!(
            js_source_websocket_protocol(Some("secret")).as_deref(),
            Some("legado.token.c2VjcmV0")
        );
        // 需要 URL-safe 替换与去 padding：base64("abcd") = "YWJjZA=="
        assert_eq!(
            js_source_websocket_protocol(Some("abcd")).as_deref(),
            Some("legado.token.YWJjZA")
        );
        assert_eq!(js_source_websocket_protocol(Some("   ")), None);
        assert_eq!(js_source_websocket_protocol(None), None);
    }

    #[test]
    fn validate_protocol_matches_upstream_rules() {
        let not_required = JsSourceApiConfig {
            required: false,
            token: None,
        };
        assert!(validate_websocket_protocol(
            &headers_with_protocol("legado"),
            &not_required
        ));
        assert!(validate_websocket_protocol(
            &headers_with_protocol("legado, legado.token.anything"),
            &not_required
        ));
        assert!(!validate_websocket_protocol(
            &headers_with_protocol("other"),
            &not_required
        ));
        assert!(!validate_websocket_protocol(
            &HeaderMap::new(),
            &not_required
        ));

        let required = JsSourceApiConfig {
            required: true,
            token: Some("secret".to_string()),
        };
        assert!(validate_websocket_protocol(
            &headers_with_protocol("legado,legado.token.c2VjcmV0"),
            &required
        ));
        assert!(!validate_websocket_protocol(
            &headers_with_protocol("legado"),
            &required
        ));
        assert!(!validate_websocket_protocol(
            &headers_with_protocol("legado,legado.token.wrong"),
            &required
        ));
        assert!(!validate_websocket_protocol(
            &headers_with_protocol("legado,legado.token.c2VjcmV0,extra"),
            &required
        ));
        let missing_token = JsSourceApiConfig {
            required: true,
            token: None,
        };
        assert!(!validate_websocket_protocol(
            &headers_with_protocol("legado,legado.token.c2VjcmV0"),
            &missing_token
        ));
    }

    #[test]
    fn constant_time_eq_checks_length_and_bytes() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"ab"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn parse_first_message_accepts_object_and_lenient_scalars() {
        match parse_first_message(r#"{"tag":"https://a","key":"kw"}"#) {
            FirstMessage::Parsed { tag, key } => {
                assert_eq!(tag.as_deref(), Some("https://a"));
                assert_eq!(key.as_deref(), Some("kw"));
            }
            FirstMessage::InvalidFormat => panic!("合法对象被判为格式错误"),
        }
        // Gson Map<String,String> 对数字/布尔的宽松转换
        match parse_first_message(r#"{"tag":123,"key":true}"#) {
            FirstMessage::Parsed { tag, key } => {
                assert_eq!(tag.as_deref(), Some("123"));
                assert_eq!(key.as_deref(), Some("true"));
            }
            FirstMessage::InvalidFormat => panic!("标量应被宽松转字符串"),
        }
        // 缺字段 → None（由调用方判空）
        match parse_first_message(r#"{"tag":"x"}"#) {
            FirstMessage::Parsed { tag, key } => {
                assert_eq!(tag.as_deref(), Some("x"));
                assert!(key.is_none());
            }
            FirstMessage::InvalidFormat => panic!("缺字段不应判为格式错误"),
        }
    }

    #[test]
    fn parse_first_message_rejects_non_object_and_nested_values() {
        assert!(matches!(
            parse_first_message("not json"),
            FirstMessage::InvalidFormat
        ));
        assert!(matches!(
            parse_first_message("[1,2]"),
            FirstMessage::InvalidFormat
        ));
        assert!(matches!(
            parse_first_message(r#"{"tag":{"a":1},"key":"x"}"#),
            FirstMessage::InvalidFormat
        ));
    }

    #[test]
    fn format_elapsed_matches_simple_date_format_minute_wrap() {
        assert_eq!(format_elapsed(Duration::from_millis(0)), "[00:00.000]");
        assert_eq!(format_elapsed(Duration::from_millis(1_234)), "[00:01.234]");
        assert_eq!(format_elapsed(Duration::from_secs(61)), "[01:01.000]");
        // 超过 1 小时按 mm 回绕（SimpleDateFormat 的分钟字段）
        assert_eq!(format_elapsed(Duration::from_secs(3_661)), "[01:01.000]");
    }

    #[test]
    fn is_abs_url_matches_upstream_case_insensitive() {
        assert!(is_abs_url("http://a"));
        assert!(is_abs_url("HTTPS://a"));
        assert!(!is_abs_url("++http://a"));
        assert!(!is_abs_url("https:/a"));
    }

    /// 构造一条真实形态的采集记录（请求级日志用例）
    fn log_entry(url: &str, status: i32, duration_ms: i64, body: &str) -> HttpLogEntry {
        HttpLogEntry {
            method: "GET".to_string(),
            url: url.to_string(),
            request_headers: std::collections::HashMap::new(),
            request_body: String::new(),
            status_code: status,
            response_headers: std::collections::HashMap::new(),
            response_body: body.to_string(),
            response_content_type: Some("text/html".to_string()),
            duration_ms,
            error: None,
        }
    }

    #[test]
    fn request_lines_match_original_text_and_real_measurements() {
        // 原版请求行逐字一致（`BookList.kt:53` 等四阶段同款）
        assert_eq!(
            success_request_line("https://a.example/search?kw=x"),
            "≡获取成功:https://a.example/search?kw=x"
        );
        // 测量行：方法/URL/状态/耗时/响应体字节数全部来自采集记录
        let entry = log_entry("https://a.example/search?kw=x", 200, 12, "hello");
        assert_eq!(
            request_measure_line(&entry),
            "≡请求 GET https://a.example/search?kw=x -> 200 12ms 5B"
        );
        // 失败行：statusCode=-1（对齐 HttpLogInterceptor 异常分支）+ 错误摘要
        let mut failure = log_entry("https://a.example/fail", -1, 30, "");
        failure.error = Some("Connection refused".to_string());
        assert_eq!(
            request_failure_line(&failure),
            "≡请求失败 GET https://a.example/fail -> -1 30ms | Connection refused"
        );
    }

    /// 请求级日志：成功请求两行（原版请求行 + 测量行），失败请求一行
    #[test]
    fn debug_sink_request_emits_expected_line_sequence() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let sink = DebugSink::new(tx);
        sink.request(&log_entry("https://a.example/x", 200, 7, "abc"));
        let mut failed = log_entry("https://a.example/y", -1, 9, "");
        failed.error = Some("boom".to_string());
        sink.request(&failed);

        let lines: Vec<String> = std::iter::from_fn(|| rx.try_recv().ok())
            .map(|event| match event {
                DebugEvent::Log(line) => line,
                DebugEvent::Error(line) => panic!("请求观测不应产生失败事件: {line}"),
                DebugEvent::Done => panic!("不应有结束事件"),
            })
            .collect();
        assert_eq!(lines.len(), 3, "成功两行 + 失败一行: {lines:?}");
        for line in &lines {
            // 每行都带原版时间前缀 `[mm:ss.SSS] `
            assert!(
                line.starts_with('[')
                    && line.get(3..4) == Some(":")
                    && line.get(6..7) == Some(".")
                    && line.get(10..12) == Some("] "),
                "时间前缀格式不符: {line}"
            );
        }
        assert!(lines[0].contains("≡获取成功:https://a.example/x"));
        assert!(lines[1].contains("≡请求 GET https://a.example/x -> 200 7ms 3B"));
        assert!(lines[2].contains("≡请求失败 GET https://a.example/y -> -1 9ms | boom"));
    }

    #[test]
    fn error_chain_appends_source_layers() {
        use std::error::Error as _;
        // 无底层 source 的变体：只输出一层
        let plain = legado_core::LegadoError::Network("boom".to_string());
        assert_eq!(format_error_chain(&plain), "Network error: boom");
        // Io 变体带 `#[from]` 的 source：必须追加「原因」层
        let io = std::io::Error::new(std::io::ErrorKind::ConnectionRefused, "连接被拒绝");
        let err: legado_core::LegadoError = io.into();
        assert!(
            err.source().is_some(),
            "Io 变体应保留底层 source（错误链前提）"
        );
        let chain = format_error_chain(&err);
        assert!(chain.starts_with("IO error: "), "首层应为 Display: {chain}");
        assert!(
            chain.contains("\n原因: 连接被拒绝"),
            "应追加原因层: {chain}"
        );
    }

    #[test]
    fn debug_slot_is_exclusive_and_released_on_drop() {
        let first = DebugSlot::try_acquire().expect("空闲槽应可占用");
        assert!(DebugSlot::try_acquire().is_none(), "占用期间应拒绝第二者");
        let owner = DebugSlot::current();
        assert_eq!(owner, Some(first.owner));
        drop(first);
        assert_eq!(DebugSlot::current(), None);
        let second = DebugSlot::try_acquire().expect("释放后应可再次占用");
        drop(second);
    }

    /// 原版 `notPrintState = [10,20,30,40]`：响应体行丢弃；1000 打印后结束
    #[test]
    fn rss_debug_state_semantics_drop_body_lines_and_close_on_terminal() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let sink = DebugSink::new(tx);
        for state in [10, 20, 30, 40] {
            sink.log_state(state, "响应体");
        }
        assert!(rx.try_recv().is_err(), "响应体行必须被丢弃");

        sink.log_state(1, "阶段行");
        match rx.try_recv().expect("阶段行应推送") {
            DebugEvent::Log(line) => assert!(line.contains("阶段行"), "{line}"),
            _ => panic!("state=1 应为普通日志"),
        }

        sink.log_state(1000, "︽解析完成");
        match rx.try_recv().expect("结束行应推送") {
            DebugEvent::Log(line) => assert!(line.contains("︽解析完成"), "{line}"),
            _ => panic!("state=1000 应打印为普通日志"),
        }
        assert!(
            matches!(rx.try_recv().expect("1000 后应结束"), DebugEvent::Done),
            "state=1000 打印后必须结束"
        );
    }

    /// state=-1：失败行（自研通道映射 debug_error）+ 结束
    #[test]
    fn rss_debug_failure_emits_error_then_done() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let sink = DebugSink::new(tx);
        sink.fail("错误链");
        match rx.try_recv().expect("失败行应推送") {
            DebugEvent::Error(line) => assert!(line.contains("错误链"), "{line}"),
            _ => panic!("state=-1 应为失败事件"),
        }
        assert!(
            matches!(rx.try_recv().expect("-1 后应结束"), DebugEvent::Done),
            "state=-1 后必须结束"
        );
    }

    #[test]
    fn rss_rule_presence_helpers_match_kotlin_blank_semantics() {
        let mut source = legado_core::models::RssSource::default();
        assert!(!has_rule_articles(&source), "None 视为空");
        source.rule_articles = Some("   ".to_string());
        assert!(!has_rule_articles(&source), "空白规则视为空");
        source.rule_articles = Some("-class.item".to_string());
        assert!(has_rule_articles(&source));
        assert!(rule_is_blank(None));
        assert!(rule_is_blank(Some(" \r\n")));
        assert!(!rule_is_blank(Some("class.desc@text")));
    }

    #[test]
    fn rss_article_js_json_uses_kotlin_field_names() {
        let article = RssArticleItem {
            origin: "https://rss.example.com/feed".to_string(),
            sort: "科技".to_string(),
            title: "标题".to_string(),
            link: "https://rss.example.com/a/1".to_string(),
            pub_date: Some("2026-10-26".to_string()),
            article_type: 1,
            ..Default::default()
        };
        let value: Value = serde_json::from_str(&rss_article_js_json(&article)).unwrap();
        assert_eq!(value["origin"], "https://rss.example.com/feed");
        assert_eq!(value["sort"], "科技");
        assert_eq!(value["pubDate"], "2026-10-26");
        assert_eq!(value["type"], 1, "type 字段名需对齐 Kotlin RssArticle");
        assert!(value.get("articleType").is_none());
    }
}
