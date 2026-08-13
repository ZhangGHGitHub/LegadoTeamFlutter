//! 服务器管理 API
//!
//! 提供 legado-server 的启动、停止和状态查询功能。
//! 使用独立的 tokio Runtime 运行 HTTP 服务器。
//!
//! Task #73（契约 §2.22.5 `setMcpPort`）：独立 MCP 服务端口管理——
//! 对齐原版 `McpService.kt` 独立前台服务（默认 1236，合法区间
//! 1024..65530，≤0 停止），与 Web 服务并存、独立启停。

use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::OnceLock;

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

use legado_core::{LegadoError, LegadoResult};

/// 服务器运行时（独立于 FFI 主 runtime）
static SERVER_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 服务器运行状态
static SERVER_RUNNING: AtomicBool = AtomicBool::new(false);

/// 服务器端口
static SERVER_PORT: AtomicU16 = AtomicU16::new(0);

/// 服务器任务句柄（用于中止）
static SERVER_HANDLE: OnceLock<std::sync::Mutex<Option<JoinHandle<()>>>> = OnceLock::new();

// ─── 独立 MCP 服务状态（Task #73） ────────────────────────

/// 独立 MCP 服务运行状态
static MCP_RUNNING: AtomicBool = AtomicBool::new(false);

/// 独立 MCP 服务端口
static MCP_PORT: AtomicU16 = AtomicU16::new(0);

/// 独立 MCP 服务任务句柄（用于中止）
static MCP_HANDLE: OnceLock<std::sync::Mutex<Option<JoinHandle<()>>>> = OnceLock::new();

/// 独立 MCP 服务默认端口（对齐原版 `AppConfig.mcpPort` 默认值）
pub const DEFAULT_MCP_PORT: u16 = 1236;

/// 独立 MCP 端口合法区间下限（对齐原版 NumberPicker）
const MCP_PORT_MIN: i32 = 1024;

/// 独立 MCP 端口合法区间上限（对齐原版 NumberPicker）
const MCP_PORT_MAX: i32 = 65530;

/// 配置持久化键（caches 表 `config:` 前缀，与既有 setConfig 同语义）
const MCP_PORT_CONFIG_KEY: &str = "mcpPort";

/// 获取服务器任务句柄槽位
fn get_handle_slot() -> &'static std::sync::Mutex<Option<JoinHandle<()>>> {
    SERVER_HANDLE.get_or_init(|| std::sync::Mutex::new(None))
}

/// 获取独立 MCP 服务任务句柄槽位
fn get_mcp_handle_slot() -> &'static std::sync::Mutex<Option<JoinHandle<()>>> {
    MCP_HANDLE.get_or_init(|| std::sync::Mutex::new(None))
}

/// 获取或创建服务器专用 runtime
///
/// worker 线程栈 8MB（任务 #60 ②）：与 FFI 主 runtime 同步扩栈，
/// 防 spawn_blocking 上 regex-syntax 深递归击穿默认 2MB 栈。
fn get_server_runtime() -> &'static Runtime {
    SERVER_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(
                std::thread::available_parallelism()
                    .map(|n| n.get())
                    .unwrap_or(2)
                    .clamp(2, 8),
            )
            .thread_name("legado-server")
            .thread_stack_size(8 * 1024 * 1024)
            .build()
            .expect("Failed to create server runtime")
    })
}

/// 启动 legado-server
///
/// 在独立 tokio runtime 中启动 HTTP 服务器。
/// 返回 "Server started on port {port}"。
pub fn server_start(port: u16) -> LegadoResult<String> {
    if SERVER_RUNNING.load(Ordering::SeqCst) {
        return Ok(format!(
            "Server already running on port {}",
            SERVER_PORT.load(Ordering::SeqCst)
        ));
    }

    let runtime = get_server_runtime();

    let handle = runtime.spawn(async move {
        let config = legado_server::server::ServerConfig {
            host: "127.0.0.1".to_string(),
            port,
            db_path: "legado.db".to_string(),
        };

        if let Err(e) = legado_server::server::start_server(config).await {
            eprintln!("Server error: {e}");
        }

        SERVER_RUNNING.store(false, Ordering::SeqCst);
    });

    // 保存句柄
    let slot = get_handle_slot();
    let mut guard = slot.lock().expect("Server handle mutex poisoned");
    *guard = Some(handle);

    SERVER_RUNNING.store(true, Ordering::SeqCst);
    SERVER_PORT.store(port, Ordering::SeqCst);

    Ok(format!("Server started on port {port}"))
}

/// 停止服务器
///
/// 中止服务器任务，返回 "Server stopped"。
pub fn server_stop() -> String {
    if !SERVER_RUNNING.load(Ordering::SeqCst) {
        return "Server not running".to_string();
    }

    let slot = get_handle_slot();
    let mut guard = slot.lock().expect("Server handle mutex poisoned");
    if let Some(handle) = guard.take() {
        handle.abort();
    }

    SERVER_RUNNING.store(false, Ordering::SeqCst);
    SERVER_PORT.store(0, Ordering::SeqCst);

    "Server stopped".to_string()
}

/// 获取服务器状态
///
/// 返回 JSON: { "running": bool, "port": u16 }
pub fn server_status() -> String {
    let running = SERVER_RUNNING.load(Ordering::SeqCst);
    let port = SERVER_PORT.load(Ordering::SeqCst);

    serde_json::json!({
        "running": running,
        "port": port,
    })
    .to_string()
}

// ─── 独立 MCP 服务（契约 §2.22.5 setMcpPort，Task #73） ───────

/// 独立 MCP 服务状态机互斥锁（Task #76 Med1）：
/// set_mcp_port 的 stop→初始化→bind→spawn→存句柄→置位全程持锁执行，
/// 防止并发调用造成状态不一致。
static MCP_STATE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// 设置独立 MCP 服务端口（启停状态机）
///
/// - `port <= 0`：停止独立 MCP 服务（Web 端口 /mcp/* 挂载不受影响），
///   并持久化该值；
/// - `port` 合法区间 `1024..=65530`（对齐原版 NumberPicker），
///   越界报 `Internal` 错误（可读消息）；
/// - 端口变更自动重启（先停旧再启新，abort 后等待旧监听器释放，
///   同端口重启不冲突，Task #76 M1）；端口绑定失败（如占用）
///   同步报 `Internal` 错误；
/// - F5：监听 `0.0.0.0`（LAN 可达，对齐原版 McpService）；启动前置要求
///   `config:jsSourceApiToken` 非空；独立端口 `/mcp/*` 校验 `X-Legado-Token`；
/// - 要求数据库已初始化（先 db_open），独立服务与主应用复用同一
///   DB 文件（WAL 并发安全）；DB 未初始化返回 `Internal` 可读错误；
/// - 成功后持久化到 caches 表 `config:mcpPort`。
pub fn set_mcp_port(port: i32) -> LegadoResult<()> {
    // port <= 0：停止独立 MCP 服务
    if port <= 0 {
        {
            let _guard = mcp_state_lock();
            mcp_stop_internal();
        }
        persist_mcp_port(port);
        return Ok(());
    }
    mcp_start_internal(port)?;
    persist_mcp_port(port);
    Ok(())
}

/// 获取 MCP 状态机锁（中毒时直接恢复：仅需串行语义）
fn mcp_state_lock() -> std::sync::MutexGuard<'static, ()> {
    MCP_STATE_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 启动独立 MCP 服务（内部实现，不持久化；Task #76 Min2：
/// restore_mcp_port 复用本函数绕过 persist，避免启动时重复写配置）
fn mcp_start_internal(port: i32) -> LegadoResult<()> {
    // 合法区间校验（对齐原版 1024..65530 NumberPicker 取值）
    if port < MCP_PORT_MIN || port > MCP_PORT_MAX {
        return Err(LegadoError::Internal(format!(
            "MCP 端口 {} 越界：合法区间为 {MCP_PORT_MIN}..{MCP_PORT_MAX}（对齐原版）",
            port
        )));
    }

    // 状态机全程互斥（Task #76 Med1）
    let _guard = mcp_state_lock();

    // DB 必须已初始化：独立服务与主应用复用同一 DB 文件（Task #76 C2）
    if !crate::db_state::is_initialized() {
        return Err(LegadoError::Internal(
            "独立 MCP 服务启动失败：数据库未初始化，请先调用 db_open".into(),
        ));
    }
    let db_path = crate::db_state::current_db_path().ok_or_else(|| {
        LegadoError::Internal("独立 MCP 服务启动失败：DB 路径未记录，请先调用 db_open".into())
    })?;

    // F5：对齐原版 — jsSourceApiToken 非空才允许启动
    let token = crate::api::config_api::get_config("jsSourceApiToken")
        .unwrap_or_default()
        .trim()
        .to_string();
    if token.is_empty() {
        return Err(LegadoError::Internal(
            "独立 MCP 服务启动失败：请先在其他设置中配置 JS 书源 API Token（jsSourceApiToken）"
                .into(),
        ));
    }

    // 端口变更自动重启：先停旧服务（abort 后等待旧监听器释放）
    mcp_stop_internal();

    // 同步初始化数据库（同文件 WAL 并发安全，二次连接池可接受）；
    // 初始化失败风险同步化：失败即 Err、不置 running（Task #76 Med1）
    let db = legado_db::init_database(&db_path).map_err(|e| {
        LegadoError::Internal(format!("独立 MCP 服务数据库初始化失败（{db_path}）: {e}"))
    })?;

    let runtime = get_server_runtime();

    // F5：绑定 0.0.0.0（LAN 可达，对齐原版 McpService）
    let listener = runtime
        .block_on(tokio::net::TcpListener::bind(("0.0.0.0", port as u16)))
        .map_err(|e| {
            LegadoError::Internal(format!("独立 MCP 服务端口 {} 绑定失败: {e}", port))
        })?;

    // 复用既有 server 启动模式：同 runtime 内 spawn，句柄可中止
    let handle = runtime.spawn(async move {
        if let Err(e) = legado_server::server::serve_mcp(listener, db, token).await {
            eprintln!("MCP server error: {e}");
        }
        MCP_RUNNING.store(false, Ordering::SeqCst);
    });

    // 保存句柄
    let slot = get_mcp_handle_slot();
    let mut guard = slot.lock().expect("MCP handle mutex poisoned");
    *guard = Some(handle);
    drop(guard);

    MCP_RUNNING.store(true, Ordering::SeqCst);
    MCP_PORT.store(port as u16, Ordering::SeqCst);
    Ok(())
}

/// 停止独立 MCP 服务（内部实现，幂等）
///
/// abort 后等待任务实际结束（Task #76 M1：防止旧监听器未释放时
/// 同端口重新 bind 报 AddrInUse；abort 过的 JoinHandle 会快速 resolve）。
fn mcp_stop_internal() {
    let handle = {
        let slot = get_mcp_handle_slot();
        let mut guard = slot.lock().expect("MCP handle mutex poisoned");
        guard.take()
    };
    if let Some(handle) = handle {
        handle.abort();
        // 等待任务实际结束，确保旧监听器端口释放
        let _ = get_server_runtime().block_on(handle);
    }
    MCP_RUNNING.store(false, Ordering::SeqCst);
    MCP_PORT.store(0, Ordering::SeqCst);
}

/// 独立 MCP 服务状态（诊断/测试用）
///
/// 返回 JSON: { "running": bool, "port": u16 }
pub fn mcp_status() -> String {
    serde_json::json!({
        "running": MCP_RUNNING.load(Ordering::SeqCst),
        "port": MCP_PORT.load(Ordering::SeqCst),
    })
    .to_string()
}

/// 持久化 MCP 端口配置（宽容失败：DB 未初始化/写入失败仅记日志）
fn persist_mcp_port(port: i32) {
    if !crate::db_state::is_initialized() {
        log::debug!("数据库未初始化，mcpPort 配置不持久化");
        return;
    }
    if let Err(e) = crate::api::config_api::set_config(MCP_PORT_CONFIG_KEY, &port.to_string()) {
        log::warn!("持久化 mcpPort 配置失败: {e}");
    }
}

/// 启动时恢复独立 MCP 服务（由 db_open 调用，尽力而为）
///
/// 读回 `config:mcpPort`：>0 时尝试启动独立服务（失败仅记日志，
/// 如端口已被占用）；≤0/缺省不启动。
pub fn restore_mcp_port() {
    if !crate::db_state::is_initialized() {
        return;
    }
    let value = match crate::api::config_api::get_config(MCP_PORT_CONFIG_KEY) {
        Ok(v) => v,
        Err(e) => {
            log::warn!("读取 mcpPort 配置失败: {e}");
            return;
        }
    };
    let value = value.trim();
    if value.is_empty() {
        return;
    }
    match value.parse::<i32>() {
        Ok(port) if port > 0 => {
            // Task #76 Min2：恢复路径复用内部启动函数绕过 persist，
            // 避免每次启动重复写 config:mcpPort
            if let Err(e) = mcp_start_internal(port) {
                log::warn!("启动时恢复独立 MCP 服务（端口 {port}）失败: {e}");
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_server_status_initial() {
        // 初始状态应为未运行
        let status = server_status();
        let json: serde_json::Value = serde_json::from_str(&status).unwrap();
        // 注意：如果其他测试先启动了服务器，这里可能为 true
        assert!(json.get("running").is_some());
        assert!(json.get("port").is_some());
    }

    #[test]
    fn test_server_stop_when_not_running() {
        // 未运行时停止应返回提示
        let result = server_stop();
        assert!(result == "Server not running" || result == "Server stopped");
    }

    // ─── 独立 MCP 服务（Task #73） ────────────────────────

    /// 串行锁：MCP 测试共享全局启停状态，需串行执行
    static MCP_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 取一个空闲端口（先绑 :0 再释放，随机端口策略避免 CI 冲突）
    fn pick_free_port() -> u16 {
        let listener = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        port
    }

    /// F5：测试启动前写入 jsSourceApiToken
    fn ensure_mcp_token() {
        crate::api::config_api::set_config("jsSourceApiToken", "test-mcp-token")
            .expect("写入测试 token");
    }

    /// 为独立 MCP 服务设置临时 DB 文件路径（Task #76 C2：避免 cwd 残留
    /// 文件；serve_mcp 会自行在该路径初始化二次连接池）
    fn setup_temp_db_path() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("legado_mcp_test_{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = dir.join(format!("mcp_test_{nanos}.db"));
        crate::db_state::record_db_path(path.to_str().expect("DB 路径含非 UTF-8 字符"));
        path
    }

    /// 清理临时 DB 文件（尽力而为，含 WAL/SHM/journal 附属文件）
    fn cleanup_temp_db(path: &std::path::Path) {
        let base = path.to_string_lossy().to_string();
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let _ = std::fs::remove_file(format!("{base}{suffix}"));
        }
    }

    /// 越界校验：合法区间 1024..65530（对齐原版）
    #[test]
    fn test_mcp_port_out_of_range() {
        let _g = MCP_TEST_LOCK.lock().unwrap();
        let low = set_mcp_port(1023);
        assert!(low.is_err(), "端口 1023 应报越界错误");
        let high = set_mcp_port(65531);
        assert!(high.is_err(), "端口 65531 应报越界错误");
        // 错误消息可读（含区间提示）
        let msg = format!("{}", high.unwrap_err());
        assert!(msg.contains("越界"));
    }

    /// port ≤ 0 停止独立服务（未运行时亦幂等成功）
    #[test]
    fn test_mcp_port_stop_semantics() {
        let _g = MCP_TEST_LOCK.lock().unwrap();
        assert!(set_mcp_port(0).is_ok());
        let status: serde_json::Value = serde_json::from_str(&mcp_status()).unwrap();
        assert_eq!(status["running"], false);
        assert!(set_mcp_port(-1).is_ok());
    }

    /// F5：token 未设置时拒绝启动
    #[test]
    fn test_mcp_requires_js_source_api_token() {
        let _g = MCP_TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        let db_path = setup_temp_db_path();
        let _ = crate::api::config_api::set_config("jsSourceApiToken", "");
        let port = pick_free_port() as i32;
        let err = set_mcp_port(port).unwrap_err();
        assert!(
            err.to_string().contains("Token") || err.to_string().contains("token"),
            "应提示需配置 token: {err}"
        );
        cleanup_temp_db(&db_path);
    }

    /// 启停状态机 + 端口变更自动重启 + 持久化（随机端口避免 CI 冲突）
    #[test]
    fn test_mcp_start_restart_stop_state_machine() {
        let _g = MCP_TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        let db_path = setup_temp_db_path();
        ensure_mcp_token();

        let port1 = pick_free_port() as i32;
        set_mcp_port(port1).expect("首次启动应成功");
        let status: serde_json::Value = serde_json::from_str(&mcp_status()).unwrap();
        assert_eq!(status["running"], true);
        assert_eq!(status["port"].as_u64().unwrap(), port1 as u64);

        // 持久化：config:mcpPort 应为当前端口
        let persisted = crate::api::config_api::get_config("mcpPort").unwrap();
        assert_eq!(persisted, port1.to_string());

        // 端口变更自动重启（先停旧再启新）
        let port2 = pick_free_port() as i32;
        set_mcp_port(port2).expect("端口变更后重启应成功");
        let status: serde_json::Value = serde_json::from_str(&mcp_status()).unwrap();
        assert_eq!(status["running"], true);
        assert_eq!(status["port"].as_u64().unwrap(), port2 as u64);

        // port ≤ 0 停止
        set_mcp_port(0).unwrap();
        let status: serde_json::Value = serde_json::from_str(&mcp_status()).unwrap();
        assert_eq!(status["running"], false);

        cleanup_temp_db(&db_path);
    }

    /// 同端口重启循环（Task #76 M1）：set→stop→set 同端口成功，
    /// abort 后等待旧监听器释放，不再报 AddrInUse
    #[test]
    fn test_mcp_same_port_restart_cycle() {
        let _g = MCP_TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        let db_path = setup_temp_db_path();
        ensure_mcp_token();

        let port = pick_free_port() as i32;
        set_mcp_port(port).expect("首次启动应成功");
        set_mcp_port(0).expect("停止应成功");
        set_mcp_port(port).expect("同端口重启应成功（旧监听器已释放）");
        let status: serde_json::Value = serde_json::from_str(&mcp_status()).unwrap();
        assert_eq!(status["running"], true);
        assert_eq!(status["port"].as_u64().unwrap(), port as u64);
        set_mcp_port(0).unwrap();

        cleanup_temp_db(&db_path);
    }

    /// 端口被占用：绑定失败报 Internal（可读消息）
    #[test]
    fn test_mcp_port_bind_conflict() {
        let _g = MCP_TEST_LOCK.lock().unwrap();
        let _db_guard = crate::db_state::ensure_test_db();
        let db_path = setup_temp_db_path();
        ensure_mcp_token();
        // 占用 0.0.0.0 端口（与 set_mcp_port F5 绑定同地址族）
        let blocker = std::net::TcpListener::bind("0.0.0.0:0").unwrap();
        let port = blocker.local_addr().unwrap().port() as i32;

        let result = set_mcp_port(port);
        assert!(result.is_err(), "端口被占用时应报绑定失败");
        let msg = format!("{}", result.unwrap_err());
        assert!(msg.contains("绑定失败"));

        drop(blocker);
        cleanup_temp_db(&db_path);
    }
}
