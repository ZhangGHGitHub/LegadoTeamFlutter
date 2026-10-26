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
//! 端口+1 的前端推导（vue 打包产物 `assets/web/vue/assets/index-toG2697L.js`
//! 的 `Gt` 函数）：`new URL('bookSourceDebug', wsBase)`，其中
//! `wsBase = ws(s)://host:Number(httpPort)+1/<path>/`；无显式端口时原版取
//! `http`→81、`https`→444（本实现仅在显式端口下工作，主服务始终有端口）。
//!
//! 与自研通道的关系：`/ws/search`、`/ws/debug/book-source`、
//! `/ws/debug/rss-source`（同端口、`/api` 前缀）保持原样不动；本模块只在
//! 主服务 `port+1` 上新增原版路径，互不影响。
//!
//! # 能力降级（如实登记，不伪造响应）
//!
//! 原版调试日志由 App 内 `Debug` 引擎在规则级/请求级逐条打印。Rust server
//! 的依赖方向（`legado-server → legado-fetcher`）可触达书源抓取四入口
//! （search/info/chapters/content），但没有 `Debug.Callback` 式的规则级日志
//! 回调，因此书源调试按**阶段级**真实执行并输出原版同名阶段标记
//! （`⇒开始...`/`︾开始解析...`/`︽...解析完成`）；错误以 `LegadoError` 文本
//! 代替原版堆栈。RSS 规则解析（`RssParserByRule`）在 Rust 侧无等价实现，
//! 订阅源调试仅走完协议（校验/单槽/关闭码），随后显式发送能力缺失说明，
//! 不执行、不伪造解析结果。发现页调试（`::`）同样无 Rust 发现规则引擎，
//! 显式说明后结束。`/searchBook` 原版路径本批未挂载（我方 `/ws/search` 保留）。
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

use legado_db::repository::rss_source_repository::RssSourceRepository;
use legado_db::BookSourceRepository;

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
const MSG_DEBUG_BUSY: &str = "调试通道占用中，请稍后重试";

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
struct DebugSlot {
    owner: u64,
}

impl DebugSlot {
    /// 尝试占用；已被他人占用返回 `None`（对齐 `Debug.tryAcquireCallback`）
    fn try_acquire() -> Option<Self> {
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
enum DebugEvent {
    /// 一条原版日志（已含时间前缀，或 `showTime=false` 的原样空行）
    Log(String),
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
    let task = tokio::spawn(run_book_source_debug(state, source, key, tx));
    pump_debug_session(&mut socket, rx, task).await;
    drop(slot);
}

/// 订阅源调试连接（`RssSourceDebugWebSocket`）
async fn handle_rss_source_debug(mut socket: WebSocket, state: Arc<AppState>) {
    let Some(text) = read_first_message(&mut socket).await else {
        return;
    };
    let tag = match parse_first_message(&text) {
        FirstMessage::Parsed { tag, key: _ } => tag,
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

    let exists = {
        let db = state.db.lock().await;
        let lookup = RssSourceRepository::new(db.connection()).find_by_url(&tag);
        drop(db);
        match lookup {
            Ok(Some(_)) => true,
            Ok(None) => false,
            Err(e) => {
                tracing::warn!("WS 订阅源调试读取订阅源失败: {e}");
                close_with(&mut socket, CLOSE_INTERNAL_ERROR, CLOSE_REASON_DEBUG_FAILED).await;
                return;
            }
        }
    };
    if !exists {
        send_then_close(
            &mut socket,
            "订阅源不存在",
            CLOSE_NORMAL,
            CLOSE_REASON_FINISH,
        )
        .await;
        return;
    }

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
    let task = tokio::spawn(async move {
        // RSS 规则解析引擎（RssParserByRule）在 Rust server 无可达实现：
        // 不伪造解析结果，只显式说明能力缺失后结束。
        let _ = tx.send(DebugEvent::Log(
            "≡服务端未接入订阅源规则解析引擎（RssParserByRule 无 Rust 等价实现），本次调试未执行"
                .to_string(),
        ));
        let _ = tx.send(DebugEvent::Done);
    });
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
                Some(DebugEvent::Log(line)) => {
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

// ─── 书源调试执行（可达层级：legado-fetcher 四入口，阶段级日志）─────────────

/// 调试日志发送器（负责原版时间前缀）
struct DebugSink {
    tx: mpsc::UnboundedSender<DebugEvent>,
    start: Instant,
}

impl DebugSink {
    fn new(tx: mpsc::UnboundedSender<DebugEvent>) -> Self {
        Self {
            tx,
            start: Instant::now(),
        }
    }

    /// `Debug.log(showTime = true)`
    fn log(&self, msg: impl AsRef<str>) {
        let line = format!("{} {}", format_elapsed(self.start.elapsed()), msg.as_ref());
        let _ = self.tx.send(DebugEvent::Log(line));
    }

    /// `Debug.log(showTime = false)`（原版用于阶段间空行）
    fn log_plain(&self, msg: impl AsRef<str>) {
        let _ = self.tx.send(DebugEvent::Log(msg.as_ref().to_string()));
    }

    fn done(&self) {
        let _ = self.tx.send(DebugEvent::Done);
    }

    /// 错误分支（原版 state = -1，随后 printLog 关闭连接）
    fn fail(&self, msg: impl AsRef<str>) {
        self.log(msg);
        self.done();
    }
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

/// 书源调试主流程（`Debug.startDebug(bookSource, key)`，`Debug.kt:452-493`）
async fn run_book_source_debug(
    state: Arc<AppState>,
    source: legado_core::models::BookSource,
    key: String,
    tx: mpsc::UnboundedSender<DebugEvent>,
) {
    let sink = DebugSink::new(tx);
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
    let file_source = legado_fetcher::book_type::book_type_of_source(source.book_source_type)
        & legado_fetcher::book_type::WEB_FILE
        != 0;

    // 分派顺序与原版一致：绝对 URL → 发现 → 目录 → 正文 → 搜索
    if is_abs_url(&key) {
        sink.log(format!("⇒开始访问详情页:{key}"));
        info_stage(&sink, &deps, &source_json, &key, file_source).await;
    } else if key.contains("::") {
        let url = key.split_once("::").map(|(_, url)| url).unwrap_or("");
        sink.log(format!("⇒开始访问发现页:{url}"));
        sink.log("︾开始解析发现页");
        sink.fail("≡服务端未接入发现规则引擎，本次发现页调试未执行");
    } else if let Some(url) = key.strip_prefix("++") {
        sink.log(format!("⇒开始访目录页:{url}"));
        toc_stage(&sink, &deps, &source_json, url, url, "").await;
    } else if let Some(url) = key.strip_prefix("--") {
        sink.log(format!("⇒开始访正文页:{url}"));
        let chapter = serde_json::json!({
            "index": 0,
            "title": "调试",
            "url": url,
            "is_vip": false,
        });
        content_stage(&sink, &deps, &source_json, chapter).await;
    } else {
        sink.log(format!("⇒开始搜索关键字:{key}"));
        search_stage(&sink, &deps, &source_json, &key, file_source).await;
    }
}

/// 搜索阶段（`Debug.searchDebug`，`Debug.kt:530-552`）
async fn search_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source_json: &str,
    key: &str,
    file_source: bool,
) {
    sink.log("︾开始解析搜索页");
    match legado_fetcher::web_book::webbook_search(deps.clone(), source_json, key, 1).await {
        Ok(json) => {
            match serde_json::from_str::<Vec<legado_core::web_book::WebSearchResult>>(&json) {
                Ok(results) if results.is_empty() => sink.fail("︽未获取到书籍"),
                Ok(results) => {
                    sink.log("︽搜索页解析完成");
                    sink.log_plain("");
                    let first = &results[0];
                    info_stage(sink, deps, source_json, &first.book_url, file_source).await;
                }
                Err(e) => sink.fail(format!("搜索结果解析失败: {e}")),
            }
        }
        Err(e) => sink.fail(e.to_string()),
    }
}

/// 详情阶段（`Debug.infoDebug`，`Debug.kt:534-565`）
async fn info_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source_json: &str,
    book_url: &str,
    file_source: bool,
) {
    sink.log("︾开始解析详情页");
    match legado_fetcher::web_book::webbook_info(deps.clone(), source_json, book_url).await {
        Ok(json) => match serde_json::from_str::<legado_core::web_book::WebBookInfo>(&json) {
            Ok(info) => {
                sink.log("︽详情页解析完成");
                sink.log_plain("");
                if file_source {
                    sink.log("≡文件类书源跳过解析目录");
                    sink.done();
                } else {
                    let toc_url = info.toc_url.clone();
                    toc_stage(
                        sink,
                        deps,
                        source_json,
                        &info.book_url,
                        &toc_url,
                        &info.name,
                    )
                    .await;
                }
            }
            Err(e) => sink.fail(format!("详情结果解析失败: {e}")),
        },
        Err(e) => sink.fail(e.to_string()),
    }
}

/// 目录阶段（`Debug.tocDebug`，`Debug.kt:567-595`）
async fn toc_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source_json: &str,
    book_url: &str,
    toc_url: &str,
    book_name: &str,
) {
    sink.log("︾开始解析目录页");
    match legado_fetcher::web_book::webbook_chapters(
        deps.clone(),
        source_json,
        book_url,
        toc_url,
        book_name,
    )
    .await
    {
        Ok(json) => match serde_json::from_str::<Vec<legado_core::web_book::WebChapter>>(&json) {
            Ok(chapters) => {
                sink.log("︽目录页解析完成");
                sink.log_plain("");
                // 原版过滤卷章：!(isVolume && url.startsWith(title))
                let toc: Vec<_> = chapters
                    .into_iter()
                    .filter(|c| !(c.is_volume && c.url.starts_with(&c.title)))
                    .collect();
                match toc.first() {
                    Some(first) => {
                        // 保留章节全字段（variable/tag 等），与原版 WebBook 入参一致
                        match serde_json::to_value(first) {
                            Ok(chapter) => content_stage(sink, deps, source_json, chapter).await,
                            Err(e) => sink.fail(format!("章节序列化失败: {e}")),
                        }
                    }
                    None => sink.fail("≡没有正文章节"),
                }
            }
            Err(e) => sink.fail(format!("目录结果解析失败: {e}")),
        },
        Err(e) => sink.fail(e.to_string()),
    }
}

/// 正文阶段（`Debug.contentDebug`，`Debug.kt:597-615`）
async fn content_stage(
    sink: &DebugSink,
    deps: &legado_fetcher::deps::FetcherDeps,
    source_json: &str,
    chapter: Value,
) {
    sink.log("︾开始解析正文页");
    match legado_fetcher::web_book::webbook_content(deps.clone(), source_json, &chapter.to_string())
        .await
    {
        Ok(_content) => {
            sink.log("︽正文页解析完成");
            sink.done();
        }
        Err(e) => sink.fail(e.to_string()),
    }
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
}
