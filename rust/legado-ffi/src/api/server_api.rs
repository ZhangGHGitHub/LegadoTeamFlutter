//! 服务器管理 API
//!
//! 提供 legado-server 的启动、停止和状态查询功能。
//! 使用独立的 tokio Runtime 运行 HTTP 服务器。
//!
//! Task #73（契约 §2.22.5 `setMcpPort`）：独立 MCP 服务端口管理——
//! 对齐原版 `McpService.kt` 独立前台服务（默认 1236，合法区间
//! 1024..65530，≤0 停止），与 Web 服务并存、独立启停。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::OnceLock;

use tokio::runtime::Runtime;
use tokio::task::JoinHandle;

use legado_core::{LegadoError, LegadoResult};

/// 服务器运行时（独立于 FFI 主 runtime）
static SERVER_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// App 本地书保存子目录名（对齐 Dart `LocalBookStore.subDir = 'books'`）
///
/// App 的 DB 固定落在 `Documents/legado.db`（Dart `rust_api.dart::_defaultDbPath`），
/// 本地书持久化目录为 `Documents/books/`——两者同基目录，故本地书保存根可由
/// DB 路径父目录推导（[`local_book_root`]）。
const LOCAL_BOOK_SUB_DIR: &str = "books";

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
fn get_server_runtime() -> LegadoResult<&'static Runtime> {
    if let Some(rt) = SERVER_RUNTIME.get() {
        return Ok(rt);
    }
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .worker_threads(
            std::thread::available_parallelism()
                .map(|n| n.get())
                .unwrap_or(2)
                .clamp(2, 8),
        )
        // [批17 三审 P2] blocking 池上限：Web `/getBookContent` 与 `/mcp/call`
        // eval_js 等共享本 runtime 的 blocking 池；默认 512 线程会被并发请求
        // 拉满。设 8 槽，并给 Web 端口 `/mcp/call` 挂写源令牌守卫（未授权不能
        // 占用）；`/getBookContent` 内 `@js:` 另有信号量（4）限制。注意：本上限
        // 仅适用于 FFI `server_start` 创建的内嵌 runtime；独立 `start_server`
        // 使用调用方 runtime，需自行配置 blocking 上限。
        .max_blocking_threads(8)
        .thread_name("legado-server")
        .thread_stack_size(8 * 1024 * 1024)
        .build()
        .map_err(|e| LegadoError::Internal(format!("创建 server runtime 失败: {e}")))?;
    let _ = SERVER_RUNTIME.set(rt);
    SERVER_RUNTIME
        .get()
        .ok_or_else(|| LegadoError::Internal("server runtime 初始化失败".into()))
}

/// Mutex 中毒时恢复内部值（仅需串行语义）
fn lock_handle_slot(
    slot: &std::sync::Mutex<Option<JoinHandle<()>>>,
) -> std::sync::MutexGuard<'_, Option<JoinHandle<()>>> {
    slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// 中止服务器任务并等待其真正结束（W-1）
///
/// `abort` 是异步的：任务在其下一个 await 点才被取消，`abort()` 返回时
/// 任务栈帧（含 moved 进闭包的 `TcpListener`）可能尚未析构、OS 监听端口
/// 尚未释放。若 `server_stop` 只 abort 不等待，紧随其后的同端口
/// `server_start` 会在 spawn 前的同步 bind 处报 `AddrInUse`（审查报告
/// `docs/WEB_SERVICE_REACHABILITY_CODE_REVIEW_20261006.md` §W-1 探针实测：
/// 10 轮 stop→立即同端口 start 第 2 轮即 `os error 10048`；加 200ms 等待后
/// 10/10 过；本仓库新增集成测试在旧实现下第 1 轮即红）。此处对齐同文件
/// `mcp_stop_internal`（Task #76 M1）的既有解法：abort 后
/// `rt.block_on(handle)`——JoinHandle 在任务完全结束（栈帧析构）后才
/// resolve，返回即端口已释放。
///
/// 死锁分析（调用上下文核实）：本函数仅由 FFI 导出（`ffi_server_stop` /
/// FRB `server_stop`，运行在 Dart/FFI 调用线程）与测试线程进入，从不在
/// SERVER_RUNTIME 的任务内执行；即便未来从该 runtime 内部误调，tokio 的
/// `block_on` 会 panic（禁止 runtime 内嵌套阻塞，被 bridge 的
/// `catch_unwind` 捕获）而非静默死锁——依赖方向 legado-ffi → legado-server
/// 亦保证服务端代码不存在回调进本模块的路径。故无需 `block_in_place`。
fn abort_and_wait(handle: JoinHandle<()>) {
    handle.abort();
    if let Ok(rt) = get_server_runtime() {
        // 等待任务实际结束（JoinError::Cancelled 属预期，忽略）
        let _ = rt.block_on(handle);
    }
}

/// 本地书保存根（由 DB 路径父目录推导 `{Documents}/books`，未记录 DB 路径时 `None`）
///
/// 来源调查（B3 接线批，防复发 #1「单一实现/不发明新语义」）：
/// - 原版 Web `/addLocalBook` 落在 `AppConfig.defaultBookTreeUri`（用户选择的
///   「默认书籍保存位置」，未设置时抛 `NoBooksDirException`）。
/// - 本仓该设置只存在于 Dart `PrefKeys.defaultBookTreeUri`（SharedPreferences），
///   FFI 无对应导出/配置镜像（rg 全仓确认），本批禁改 Dart 与导出面——故不复刻
///   SAF 预置目录语义，改取**本仓既有实现**的真实本地书目录：Dart
///   `LocalBookStore` 把本地书持久化到 `Documents/books/`，Rust
///   `db_state::resolve_local_book_path` 亦以 DB 父目录（Documents）为基解析
///   `books/*` 相对标识。
/// - **目录同源 + 身份同源（C1/O2）**：注入根恒为「DB 父目录/books」，故
///   `legacy/book_api.rs` 上传落库的 `bookUrl` 与 FFI `import_local_book` /
///   iOS 导入一致，均为相对可迁移标识 `books/<fileName>`（文件仍落本根下的
///   绝对路径）；读侧在 server 内以本注入根还原。这样上传书不再把 iOS 容器
///   UUID 固化进主键，重签名/重装后仍可读取。
/// - DB 未记录路径（未走 `db_open`）时返回 `None`，服务端保持既有
///   「没有设置书籍保存位置!」分支，行为不变。
fn local_book_root(db_path: Option<&str>) -> Option<PathBuf> {
    db_path
        .map(Path::new)
        .and_then(Path::parent)
        .map(|dir| dir.join(LOCAL_BOOK_SUB_DIR))
}

/// 构造 Web 服务宿主注入路径（纯函数，便于单测覆盖两来源的「已设置/未设置」）
///
/// - `image_cache_root`：`image_cache_api` 的宿主注入缓存根（未注入 `None`）；
/// - `local_book_root`：见 [`local_book_root`]。
fn build_injected_paths(
    image_cache_root: Option<PathBuf>,
    db_path: Option<&str>,
) -> legado_server::state::InjectedPaths {
    legado_server::state::InjectedPaths {
        image_cache_root,
        local_book_root: local_book_root(db_path),
    }
}

/// 当前进程可注入的宿主路径（`server_start` 调用时快照，注入后进程内不变）
fn current_injected_paths() -> legado_server::state::InjectedPaths {
    let db_path = crate::db_state::current_db_path();
    build_injected_paths(
        crate::api::image_cache_api::injected_cache_dir(),
        db_path.as_deref(),
    )
}

/// 启动 legado-server
///
/// 在独立 tokio runtime 中启动 HTTP 服务器。
/// 返回 "Server started on port {port}"。
///
/// DB 前置条件（§二.8 修复，审计 S28_DUAL_DB_AUDIT §五修法 A/B）：
/// Web 服务与主应用复用 `db_state` 全局连接池（单池）——不再硬编码相对
/// 路径 `"legado.db"`（Android 上会打不开或在 cwd 生成第二个空库），也
/// 不再二次建池。未初始化 / 取连接失败均**同步**返回 Err，不再 spawn 前
/// 返回「已启动」而把失败吞进任务内 eprintln。
///
/// 缺陷 A/B 修复（调研 IOS_WEB_SERVICE_ROOT_CAUSE_SURVEY_20261006 §一.3/4）：
/// - 绑定地址 `0.0.0.0`（全接口，LAN 可达）——对齐原版 `HttpServer.kt`
///   `NanoHTTPD(port)`（hostname=null → 绑全接口）与本文件 MCP 路径（F5）；
///   旧实现 `127.0.0.1` 使 PC 浏览器永远无法经 `http://<设备IP>:1122`
///   写源/看书（Android 侧此前靠 adb forward 掩蔽）。
/// - spawn **之前**同步 bind，端口占用等失败立即返回
///   `Internal("Web 服务端口 {port} 绑定失败: …")` 且不置运行态——
///   旧实现 spawn 后才 bind，失败仅任务内 eprintln，函数仍假成功返回 Ok。
///   成功后把已绑定 listener 交给 `serve_web`（对齐 mcp_start_internal）。
///
/// 宿主路径注入（B3 接线批，零 FFI 导出签名变更）：
/// - 改调 `legado_server::server::serve_web_with_injected_paths`，在构造
///   `AppState` 时注入 [`legado_server::state::InjectedPaths`]：
///   `image_cache_root` = Dart `set_image_cache_dir` 已注入的图片缓存根
///   （[`crate::api::image_cache_api::injected_cache_dir`]），使其进入
///   `/cover`、`/image` 本地图片读取白名单；
///   `local_book_root` = App 当前本地书目录 `{Documents}/books`（见
///   [`local_book_root`]），使 Web `/addLocalBook` 上传真正落盘。
/// - 两来源均未设置时注入 `None`，服务端行为与本批之前完全一致
///   （白名单不含缓存根、`/addLocalBook` 报「没有设置书籍保存位置!」）。
pub fn server_start(port: u16) -> LegadoResult<String> {
    if SERVER_RUNNING.load(Ordering::SeqCst) {
        return Ok(format!(
            "Server already running on port {}",
            SERVER_PORT.load(Ordering::SeqCst)
        ));
    }

    // DB 必须已初始化（与 mcp_start_internal 同型守卫）
    if !crate::db_state::is_initialized() {
        return Err(LegadoError::Internal(
            "Web 服务启动失败：数据库未初始化，请先调用 db_open".into(),
        ));
    }

    // 复用主应用全局池取连接（P2 单池，与独立 MCP 服务路径统一）；
    // 失败即 Err、不置 running
    let db = crate::db_state::database_from_pool()
        .map_err(|e| LegadoError::Internal(format!("Web 服务数据库连接失败: {e}")))?;

    let runtime = get_server_runtime()?;

    // 缺陷 A/B 修复：spawn 前同步绑定 0.0.0.0（全接口，LAN 可达；对齐
    // 原版 HttpServer.kt 的 NanoHTTPD(port) 与本文件 MCP 路径 F5），
    // 失败即 Err、不置 running——不再 spawn 后 bind 造成「假成功」
    let listener = runtime
        .block_on(tokio::net::TcpListener::bind(("0.0.0.0", port)))
        .map_err(|e| LegadoError::Internal(format!("Web 服务端口 {port} 绑定失败: {e}")))?;

    // B3 接线：spawn 前快照宿主路径（图片缓存根 / 本地书保存根），
    // 随任务 move 进 serve 构造期注入；导出签名与参数不变
    let injected_paths = current_injected_paths();

    let handle = runtime.spawn(async move {
        if let Err(e) =
            legado_server::server::serve_web_with_injected_paths(listener, db, injected_paths).await
        {
            eprintln!("Server error: {e}");
        }

        SERVER_RUNNING.store(false, Ordering::SeqCst);
    });

    // 保存句柄（W-2）：写槽前先清槽内陈值（异常路径残留，如任务自结束
    // 后无人 take、或上轮启动中途失败），take 出锁外 abort+等待，避免
    // 悬留旧句柄、也避免后续停止路径 block_on 一个语义含混的陈句柄
    let slot = get_handle_slot();
    let stale = {
        let mut guard = lock_handle_slot(slot);
        guard.take()
    };
    if let Some(stale) = stale {
        abort_and_wait(stale);
    }
    {
        let mut guard = lock_handle_slot(slot);
        *guard = Some(handle);
    }

    SERVER_RUNNING.store(true, Ordering::SeqCst);
    SERVER_PORT.store(port, Ordering::SeqCst);

    Ok(format!("Server started on port {port}"))
}

/// 停止服务器
///
/// 中止服务器任务并**等待任务真正结束**（listener 随之 drop、监听端口
/// 释放）后再返回（W-1，对齐 `mcp_stop_internal`）——否则紧随其后的
/// 同端口 `server_start` 会因 `AddrInUse` 同步失败（UI「关闭后马上重开」
/// 场景用户可见；审查报告 §W-1 探针实测确证）。返回 "Server stopped"。
pub fn server_stop() -> String {
    if !SERVER_RUNNING.load(Ordering::SeqCst) {
        return "Server not running".to_string();
    }

    // 先 take 出句柄、释放锁，再 abort+等待（持锁等待会阻塞其它持锁方）
    let handle = {
        let slot = get_handle_slot();
        let mut guard = lock_handle_slot(slot);
        guard.take()
    };
    if let Some(handle) = handle {
        abort_and_wait(handle);
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
/// - `port <= 0`：停止独立 MCP 服务（Web 端口挂载保持存在；其中
///   `/mcp/call` 需 `x-legado-token`，`/mcp/tools` 免令牌），并持久化该值；
/// - `port` 合法区间 `1024..=65530`（对齐原版 NumberPicker），
///   越界报 `Internal` 错误（可读消息）；
/// - 端口变更自动重启（先停旧再启新，abort 后等待旧监听器释放，
///   同端口重启不冲突，Task #76 M1）；端口绑定失败（如占用）
///   同步报 `Internal` 错误；
/// - F5：监听 `0.0.0.0`（LAN 可达，对齐原版 McpService）；启动前置要求
///   `config:jsSourceApiToken` 非空；独立端口 `/mcp/*` 校验 `X-Legado-Token`；
/// - 要求数据库已初始化（先 db_open），独立服务与主应用复用同一
///   全局连接池（P2 单池，与 Web 服务路径统一）；DB 未初始化返回
///   `Internal` 可读错误；
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
    if !(MCP_PORT_MIN..=MCP_PORT_MAX).contains(&port) {
        return Err(LegadoError::Internal(format!(
            "MCP 端口 {} 越界：合法区间为 {MCP_PORT_MIN}..{MCP_PORT_MAX}（对齐原版）",
            port
        )));
    }

    // 状态机全程互斥（Task #76 Med1）
    let _guard = mcp_state_lock();

    // DB 必须已初始化：独立服务与主应用复用同一全局连接池（Task #76 C2；
    // P2 单池化后与 Web 服务路径统一，不再二次建池/重跑迁移）
    if !crate::db_state::is_initialized() {
        return Err(LegadoError::Internal(
            "独立 MCP 服务启动失败：数据库未初始化，请先调用 db_open".into(),
        ));
    }

    // F5：对齐原版 — jsSourceApiToken 非空才允许启动
    //
    // [2026-10-06 iOS 实测修复] 文案只改可读性（指向 App 内可见的条目名
    // 「Web 书源访问令牌」，路径对齐设置页：设置 → 高级 → 其他设置），
    // 校验语义与行为不变。
    let token = crate::api::config_api::get_config("jsSourceApiToken")
        .unwrap_or_default()
        .trim()
        .to_string();
    if token.is_empty() {
        return Err(LegadoError::Internal(
            "独立 MCP 服务启动失败：请先在「设置 → 高级 → 其他设置」配置「Web 书源访问令牌」（config:jsSourceApiToken）"
                .into(),
        ));
    }

    // 端口变更自动重启：先停旧服务（abort 后等待旧监听器释放）
    mcp_stop_internal();

    // 从全局池取连接（P2 单池）；失败风险同步化：失败即 Err、不置 running
    // （Task #76 Med1）
    let db = crate::db_state::database_from_pool()
        .map_err(|e| LegadoError::Internal(format!("独立 MCP 服务数据库连接失败: {e}")))?;

    let runtime = get_server_runtime()?;

    // F5：绑定 0.0.0.0（LAN 可达，对齐原版 McpService）
    let listener = runtime
        .block_on(tokio::net::TcpListener::bind(("0.0.0.0", port as u16)))
        .map_err(|e| LegadoError::Internal(format!("独立 MCP 服务端口 {} 绑定失败: {e}", port)))?;

    // 复用既有 server 启动模式：同 runtime 内 spawn，句柄可中止
    let handle = runtime.spawn(async move {
        if let Err(e) = legado_server::server::serve_mcp(listener, db, token).await {
            eprintln!("MCP server error: {e}");
        }
        MCP_RUNNING.store(false, Ordering::SeqCst);
    });

    // 保存句柄
    let slot = get_mcp_handle_slot();
    let mut guard = lock_handle_slot(slot);
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
        let mut guard = lock_handle_slot(slot);
        guard.take()
    };
    if let Some(handle) = handle {
        handle.abort();
        // 等待任务实际结束，确保旧监听器端口释放
        if let Ok(rt) = get_server_runtime() {
            let _ = rt.block_on(handle);
        }
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

    /// Web 服务启停测试串行锁（`SERVER_RUNNING`/`SERVER_PORT` 为进程级状态，
    /// 与 MCP 测试的 `MCP_TEST_LOCK` 同型）
    static SERVER_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 取 Web 服务测试串行锁（中毒时恢复：仅需串行语义）
    fn server_test_lock() -> std::sync::MutexGuard<'static, ()> {
        SERVER_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn test_server_stop_when_not_running() {
        // 与注入端到端测试共享启停状态：先持锁，避免并行停掉对方服务
        let _g = server_test_lock();
        // 未运行时停止应返回提示
        let result = server_stop();
        assert!(result == "Server not running" || result == "Server stopped");
    }

    // ─── B3 宿主路径注入（图片缓存根 / 本地书保存根） ────────────

    /// 注入映射：图片缓存根原样透传；本地书根 = DB 父目录 + `books`
    #[test]
    fn test_build_injected_paths_maps_roots() {
        let image = PathBuf::from("/tmp/legado-inject/image_cache");
        let paths = build_injected_paths(Some(image.clone()), Some("/tmp/legado-inject/legado.db"));
        assert_eq!(paths.image_cache_root, Some(image), "图片缓存根应原样注入");
        assert_eq!(
            paths.local_book_root,
            Some(Path::new("/tmp/legado-inject").join(LOCAL_BOOK_SUB_DIR)),
            "本地书根应为 DB 父目录下 books 子目录"
        );
    }

    /// 未设置回退：两来源均未设置 → 双 None；仅一来源可用时另一侧保持 None
    #[test]
    fn test_build_injected_paths_none_fallbacks() {
        let empty = build_injected_paths(None, None);
        assert!(
            empty.image_cache_root.is_none(),
            "未注入图片缓存根时必须回退 None"
        );
        assert!(
            empty.local_book_root.is_none(),
            "未记录 DB 路径时本地书根必须回退 None"
        );

        // 仅 DB 路径已知：只推导本地书根，不伪造图片缓存根
        let only_db = build_injected_paths(None, Some("/tmp/legado-inject/legado.db"));
        assert!(only_db.image_cache_root.is_none());
        assert_eq!(
            only_db.local_book_root,
            Some(Path::new("/tmp/legado-inject").join(LOCAL_BOOK_SUB_DIR))
        );

        // 仅图片缓存根已注入：本地书根仍 None
        let only_img = build_injected_paths(Some(PathBuf::from("/tmp/legado-inject/img")), None);
        assert_eq!(
            only_img.image_cache_root,
            Some(PathBuf::from("/tmp/legado-inject/img"))
        );
        assert!(only_img.local_book_root.is_none());
    }

    /// 端到端传递：`server_start` 注入图片缓存根 → 注入根内图片可经
    /// `/cover` 读取（白名单生效），证明 InjectedPaths 真正传到 AppState
    #[test]
    fn test_server_start_injects_image_cache_root_whitelist() {
        let _server_lock = server_test_lock();
        // 注入槽为进程级状态：与 image_cache_api 测试共享锁串行
        let _image_lock = crate::api::image_cache_api::INJECTED_DIR_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let _db_guard = crate::db_state::ensure_test_db();

        // 夹具：注入根下按 image_cache 目录结构放一张 PNG（魔数即可通过校验）
        let root = std::env::temp_dir().join(format!(
            "legado_ffi_server_inject_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let cached = root.join("bookdir").join("images").join("cover.png");
        std::fs::create_dir_all(cached.parent().expect("缓存文件父目录")).unwrap();
        let png: Vec<u8> = [
            vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A],
            b"b3-injected-proof".to_vec(),
        ]
        .concat();
        std::fs::write(&cached, &png).unwrap();
        crate::api::image_cache_api::set_cache_dir(
            root.to_str().expect("图片缓存根路径含非 UTF-8 字符"),
        );

        // 收尾守卫：即使断言失败也停服并复位注入槽（Drop 顺序 = 声明逆序，
        // 本守卫最后声明 → 最先析构，仍持有 DB 锁）
        struct Cleanup {
            root: PathBuf,
        }
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = server_stop();
                crate::api::image_cache_api::clear_cache_dir_for_test();
                let _ = std::fs::remove_dir_all(&self.root);
            }
        }
        let _cleanup = Cleanup { root: root.clone() };

        let port = pick_free_port();
        let msg = server_start(port).expect("Web 服务应启动成功");
        assert!(msg.contains("Server started"), "启动返回: {msg}");

        let query = format!(
            "/cover?path={}",
            percent_encode(cached.to_str().expect("缓存文件路径含非 UTF-8 字符"))
        );
        let (status, head, body) = http_get_raw(port, &query);
        assert_eq!(status, 200, "响应头: {head}");
        assert!(
            head.to_ascii_lowercase()
                .contains("content-type: image/png"),
            "响应头: {head}"
        );
        assert!(
            body.windows(png.len()).any(|w| w == png.as_slice()),
            "响应体应含注入缓存根内的图片字节"
        );
    }

    /// 极简 HTTP/1.1 GET（避免为单测引入 HTTP 客户端依赖）
    fn http_get_raw(port: u16, path_and_query: &str) -> (u16, String, Vec<u8>) {
        use std::io::{Read, Write};
        let mut stream =
            std::net::TcpStream::connect(("127.0.0.1", port)).expect("连接本机 Web 服务");
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .expect("设置读超时");
        let request = format!(
            "GET {path_and_query} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n"
        );
        stream.write_all(request.as_bytes()).expect("发送请求");
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).expect("读取响应");
        let split = raw
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("响应头缺少结束标记");
        let head = String::from_utf8_lossy(&raw[..split]).to_string();
        let status = head
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .expect("响应行缺少状态码");
        (status, head, raw[split + 4..].to_vec())
    }

    /// URL 查询值百分号编码（仅保留 unreserved 字符，路径分隔符/盘符全编码）
    fn percent_encode(value: &str) -> String {
        let mut out = String::new();
        for byte in value.bytes() {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~') {
                out.push(byte as char);
            } else {
                out.push_str(&format!("%{byte:02X}"));
            }
        }
        out
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

    /// 记录一个临时 DB 文件路径（Task #76 C2；P2 单池化后连接来自
    /// `db_state` 全局池，此路径仅保留「db_open 已记录路径」的真实时序，
    /// 不再用于二次建池——文件本身不会被创建）
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
        // [2026-10-06] 文案须指向 App 内可见条目名，用户照做即可配置
        assert!(
            err.to_string().contains("Web 书源访问令牌"),
            "应提示 App 内配置入口「Web 书源访问令牌」: {err}"
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
