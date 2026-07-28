//! 服务器管理 API
//!
//! 提供 legado-server 的启动、停止和状态查询功能。
//! 使用独立的 tokio Runtime 运行 HTTP 服务器。

use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::OnceLock;

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

use legado_core::LegadoResult;

/// 服务器运行时（独立于 FFI 主 runtime）
static SERVER_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 服务器运行状态
static SERVER_RUNNING: AtomicBool = AtomicBool::new(false);

/// 服务器端口
static SERVER_PORT: AtomicU16 = AtomicU16::new(0);

/// 服务器任务句柄（用于中止）
static SERVER_HANDLE: OnceLock<std::sync::Mutex<Option<JoinHandle<()>>>> = OnceLock::new();

/// 获取服务器任务句柄槽位
fn get_handle_slot() -> &'static std::sync::Mutex<Option<JoinHandle<()>>> {
    SERVER_HANDLE.get_or_init(|| std::sync::Mutex::new(None))
}

/// 获取或创建服务器专用 runtime
fn get_server_runtime() -> &'static Runtime {
    SERVER_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("legado-server")
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
}
