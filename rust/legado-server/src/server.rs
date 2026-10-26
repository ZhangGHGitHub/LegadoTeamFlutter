//! HTTP 服务启动逻辑

use std::net::SocketAddr;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;

use axum::body::Body;
use axum::extract::Request;
use axum::http::{header::HeaderName, StatusCode};
use axum::middleware::{from_fn, from_fn_with_state, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use tokio::sync::Mutex;

use crate::handlers;
use crate::routes::create_router;
use crate::state::{AppState, InjectedPaths};
use legado_core::download_manager::DownloadManager;

/// 对齐原版 `McpAccess.TOKEN_HEADER`
const MCP_TOKEN_HEADER: &str = "x-legado-token";

/// 服务器配置
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
    pub db_path: String,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".to_string(),
            port: 8080,
            db_path: "legado.db".to_string(),
        }
    }
}

/// 启动 HTTP 服务器（自行打开数据库；供独立二进制/测试使用）
pub async fn start_server(config: ServerConfig) -> Result<(), Box<dyn std::error::Error>> {
    // 初始化数据库（含 schema 迁移）
    let db = legado_db::init_database(&config.db_path)?;
    start_server_with_db(&config.host, config.port, db).await
}

/// 启动 HTTP 服务器（复用调用方注入的数据库连接；§二.8 单池路径）
///
/// 与 [`start_server`] 的差异：不再按 `config.db_path` 自开第二连接池，
/// 数据面完全由注入的 `db` 决定——App 内 Web 服务与主应用复用同一
/// `db_state` 全局池（单池单文件身份，消除跨池 BUSY 面与启动重跑迁移）。
/// handler 侧零改动：注入结果仍是 `AppState.db: Mutex<Database>`。
///
/// 内部按 `host:port` 自行 bind 后委托 [`serve_web`]；FFI 路径不使用本
/// 函数（其改为 spawn 前预绑定以避免「假成功」），本函数保留给独立
/// 二进制/测试，签名与行为不变。
pub async fn start_server_with_db(
    host: &str,
    port: u16,
    db: legado_db::Database,
) -> Result<(), Box<dyn std::error::Error>> {
    let addr = format!("{host}:{port}").parse::<SocketAddr>()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    serve_web(listener, db).await
}

/// 在调用方预绑定的监听器上提供 Web 服务（与 [`start_server_with_db`] 同构）
///
/// 差异仅在监听器由调用方持有：FFI 路径在 spawn 前同步
/// `TcpListener::bind`（失败即同步 Err，消除「假成功」，对齐
/// `serve_mcp` 形态），成功后把已绑定的 listener 交给本函数 serve。
///
/// 本签名**保持不变**（FFI `server_start` 零改动），注入路径取
/// [`InjectedPaths::default`]（空）；需要注入图片缓存根 / 本地书保存根的
/// 调用方改用 [`serve_web_with_injected_paths`]（FFI 已改调该变体）。
pub async fn serve_web(
    listener: tokio::net::TcpListener,
    db: legado_db::Database,
) -> Result<(), Box<dyn std::error::Error>> {
    serve_web_with_injected_paths(listener, db, InjectedPaths::default()).await
}

/// [`serve_web`] 的宿主路径注入变体（B3，ACTIVE_PLAN「FFI 图片缓存根注入
/// 白名单」登记项的接收端）
///
/// `injected_paths` 语义见 [`InjectedPaths`]：FFI 在 spawn 服务任务前把
/// 图片缓存根（`image_cache_api` 的缓存根）与本地书保存根一并传入
/// （接线提交 `ae444743eb`，`legado-ffi/src/api/server_api.rs::server_start`
/// 已改调本函数）。
///
/// B5（原版 WebSocket 语义）起同时提供**独立端口**上的原版调试通道：
/// - 监听地址 = 主 listener 的 IP + `port + 1`（对齐 upstream
///   `WebService.kt:214-219` 的 `WebSocketServer(port + 1)`；默认 1122→1123）；
/// - 两个服务用 `tokio::select!` 同生命周期运行：任一方结束即整体结束，
///   对齐原版 `stopServers()` 同时停止 HttpServer/WebSocketServer；
/// - **降级点（登记）**：`port+1` 绑定失败时原版 `stopSelf()` 会连主服务一起
///   停止；本实现因 FFI `server_start` 在 spawn 后立即返回（无法回传 WS 绑定
///   失败，FFI 属本批禁改范围）改为「主服务继续、原版 WS 不可用」并打印
///   ERROR 日志，避免主服务假成功后整任务退出。
///
/// 主服务 `listener` 已由调用方绑定（FFI 绑 `0.0.0.0`），WS 监听沿用同一
/// IP；测试/单进程场景主 listener 可能是 `127.0.0.1`，WS 亦只绑回环。
pub async fn serve_web_with_injected_paths(
    listener: tokio::net::TcpListener,
    db: legado_db::Database,
    injected_paths: InjectedPaths,
) -> Result<(), Box<dyn std::error::Error>> {
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
        injected_paths,
        legacy_review: Default::default(),
    });

    let router = create_router(Arc::clone(&state));
    // P2-2（批10 审查）：源写 10 条路由的令牌前置中间件——在 handler 提取
    // body 之前校验 `x-legado-token`，未授权请求不读取请求体。
    let router = attach_source_write_token_guard(router, Arc::clone(&state));

    let addr = listener.local_addr()?;

    // B5：原版 WebSocket 独立端口 = 主服务端口 + 1（同 IP 绑定）
    let ws_port = addr.port().checked_add(1).ok_or_else(|| {
        std::io::Error::new(
            std::io::ErrorKind::AddrNotAvailable,
            format!(
                "WebSocket 端口无法由主服务端口 {} 推导（+1 溢出）",
                addr.port()
            ),
        )
    })?;
    let ws_addr = SocketAddr::new(addr.ip(), ws_port);
    let ws_listener = match tokio::net::TcpListener::bind(ws_addr).await {
        Ok(listener) => Some(listener),
        Err(e) => {
            // 原版 `upWebServer()` 在 WS 启动失败时 `stopSelf()`（主服务一并停止）。
            // 本实现无法在 FFI `server_start` 返回前感知该失败（FFI 属本批禁改
            // 范围，启动返回语义变更需契约先行），故降级为「主服务继续、原版
            // WS 通道不可用」并显著告警，避免 spawn 后整任务退出造成主服务
            // 假成功/随即断连。该降级点已登记于 ws/original.rs 文档。
            tracing::error!(
                "原版 WebSocket 端口 {ws_addr} 绑定失败：{e}；主服务继续运行，原版 WS 调试通道不可用"
            );
            None
        }
    };

    match ws_listener {
        Some(ws_listener) => {
            let ws_router = crate::ws::original::legacy_ws_routes(Arc::clone(&state));
            tracing::info!(
                "Legado server listening on {} (legacy WebSocket on {})",
                addr,
                ws_addr
            );
            // 同启停：任一 serve 结束（错误或被取消）都会 drop 另一个
            tokio::select! {
                result = axum::serve(listener, router) => result?,
                result = axum::serve(ws_listener, ws_router) => result?,
            }
        }
        None => {
            tracing::warn!(
                "Legado server listening on {}（原版 WebSocket 通道未启动）",
                addr
            );
            axum::serve(listener, router).await?;
        }
    }

    Ok(())
}

/// 为 Web 路由挂上源写端点令牌前置中间件（P2-2，批10 审查）
///
/// 中间件实现见 [`crate::legacy::source_write_api::source_write_token_guard`]：
/// 仅对 10 条受保护源写路由生效，未授权时直接返回原版失败信封 +
/// `Connection: close`，**不读取请求体**。挂载点选在
/// [`serve_web_with_injected_paths`]（FFI / 独立二进制共用的生产入口），
/// `create_router` 本体保持无状态可测；handler 内令牌校验保留为纵深防御。
pub fn attach_source_write_token_guard(router: Router, state: Arc<AppState>) -> Router {
    router.layer(from_fn_with_state(
        state,
        crate::legacy::source_write_api::source_write_token_guard,
    ))
}

/// 独立 MCP 服务专用路由（Task #73/76 + F5，契约 §2.22.5）
///
/// 暴露面收敛：仅挂载 MCP 端点 `/mcp/tools`（GET）/ `/mcp/call`（POST）
/// 与健康检查 `/health`，**不复用** [`create_router`] 全量路由。
/// F5：`/mcp/*` 经 `X-Legado-Token` 鉴权（对齐原版）；`/health` 免鉴权便于探测。
fn create_mcp_router(state: Arc<AppState>, expected_token: Arc<String>) -> Router {
    let token_for_layer = Arc::clone(&expected_token);
    Router::new()
        .route("/mcp/tools", get(handlers::mcp::get_tools))
        .route("/mcp/call", post(handlers::mcp::call_tool))
        .route(
            "/health",
            get(|| async { Json(serde_json::json!({"status": "ok"})) }),
        )
        .layer(from_fn(move |req: Request<Body>, next: Next| {
            let token = Arc::clone(&token_for_layer);
            async move {
                // /health 免鉴权（探测）；/mcp/* 要求 X-Legado-Token
                if req.uri().path() == "/health" {
                    return next.run(req).await;
                }
                mcp_token_middleware(token, req, next).await
            }
        }))
        .with_state(state)
}

async fn mcp_token_middleware(
    expected: Arc<String>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let header_name = HeaderName::from_static(MCP_TOKEN_HEADER);
    let actual = request
        .headers()
        .get(&header_name)
        .and_then(|v| v.to_str().ok());
    if !matches_js_source_api_token(expected.as_str(), actual) {
        return (StatusCode::UNAUTHORIZED, "MCP token invalid or missing").into_response();
    }
    next.run(request).await
}

/// 对齐原版 `BookSourceController.matchesJsSourceApiToken`（字节级相等）
///
/// B4 起亦为 legacy 域令牌校验（`legacy/source_api.rs`）的单一比较实现。
///
/// P2-3（批10 审查）：改为**常量时间**比较——长度与逐字节差异用 XOR/OR
/// 累积，不在首个不等字节处提前返回，避免远程计时侧信道（不引入新依赖）。
/// `expected` 为空（未配置令牌）恒拒绝；`actual` 缺失恒拒绝。
pub(crate) fn matches_js_source_api_token(expected: &str, actual: Option<&str>) -> bool {
    if expected.is_empty() {
        return false;
    }
    let Some(actual) = actual else {
        return false;
    };
    let expected = expected.as_bytes();
    let actual = actual.as_bytes();
    // 长度差异先并入累积器（长度不等时结果必非 0）
    let mut diff = expected.len() ^ actual.len();
    let max_len = expected.len().max(actual.len());
    for index in 0..max_len {
        // 越界按 0 补齐：短串也走满 max_len 次比较，耗时与内容无关
        let left = expected.get(index).copied().unwrap_or(0);
        let right = actual.get(index).copied().unwrap_or(0);
        diff |= usize::from(left ^ right);
    }
    diff == 0
}

/// 启动独立 MCP 服务（Task #73 / F5，契约 §2.22.5 `setMcpPort`）
///
/// 对齐原版 `McpService.kt`：调用方绑定 **0.0.0.0**；`expected_token` 非空
/// （由 `jsSourceApiToken` 注入）；`/mcp/*` 校验 `X-Legado-Token`。
pub async fn serve_mcp(
    listener: tokio::net::TcpListener,
    db: legado_db::Database,
    expected_token: String,
) -> Result<(), Box<dyn std::error::Error>> {
    let state = Arc::new(AppState {
        db: Mutex::new(db),
        search_cancelled: Arc::new(AtomicBool::new(false)),
        download_manager: Mutex::new(DownloadManager::new(3)),
        injected_paths: Default::default(),
        legacy_review: Default::default(),
    });

    let router = create_mcp_router(state, Arc::new(expected_token));

    let addr = listener.local_addr()?;
    tracing::info!("Legado standalone MCP service listening on {}", addr);

    axum::serve(listener, router).await?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_matches_js_source_api_token() {
        assert!(!matches_js_source_api_token("", Some("x")));
        assert!(!matches_js_source_api_token("secret", None));
        assert!(!matches_js_source_api_token("secret", Some("wrong")));
        assert!(matches_js_source_api_token("secret", Some("secret")));
    }

    /// P2-3：常量时间比较的边界形态（长度差 / 末字节差 / 空值）
    #[test]
    fn test_matches_js_source_api_token_constant_time_edges() {
        assert!(!matches_js_source_api_token("secret", Some("secretx")));
        assert!(!matches_js_source_api_token("secretx", Some("secret")));
        assert!(!matches_js_source_api_token("secret", Some("secreu")));
        assert!(!matches_js_source_api_token("secret", Some("xecret")));
        assert!(!matches_js_source_api_token("", Some("")));
        assert!(!matches_js_source_api_token("", None));
        // 长度相同且逐字节相同 → 通过
        assert!(matches_js_source_api_token("中文令牌", Some("中文令牌")));
        assert!(!matches_js_source_api_token("中文令牌", Some("中文令排")));
    }

    #[test]
    fn test_default_config() {
        let config = ServerConfig::default();
        assert_eq!(config.host, "127.0.0.1");
        assert_eq!(config.port, 8080);
        assert_eq!(config.db_path, "legado.db");
    }

    #[test]
    fn test_config_custom() {
        let config = ServerConfig {
            host: "0.0.0.0".to_string(),
            port: 3000,
            db_path: "/tmp/test.db".to_string(),
        };
        assert_eq!(config.host, "0.0.0.0");
        assert_eq!(config.port, 3000);
    }

    #[tokio::test]
    async fn test_server_bind_and_serve() {
        // 启动服务器后立刻关闭，验证绑定和路由构建无误
        let db = legado_db::init_in_memory_database().unwrap();
        let state = Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(AtomicBool::new(false)),
            download_manager: Mutex::new(DownloadManager::new(3)),
            injected_paths: Default::default(),
            legacy_review: Default::default(),
        });
        let router = create_router(state);

        // 绑定到随机可用端口
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();

        // 异步启动，然后立刻 drop 取消任务
        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, router).await;
        });

        // 验证能建立连接
        let _ = tokio::net::TcpStream::connect(addr).await.unwrap();

        handle.abort();
    }
}
