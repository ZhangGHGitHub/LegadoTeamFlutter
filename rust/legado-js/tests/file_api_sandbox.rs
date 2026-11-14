//! P1-1 回归：生产沙箱下文件 API 可用性 + `FsPolicy` 路径限域（quickjs 档）
//!
//! 审查缺陷：`register_file_apis` 仅在 `allow_file_access=true` 时调用，而
//! 生产所有引擎配置均为 `SandboxConfig::default().with_allow_script_run(true)`
//! （`allow_file_access=false`），导致随包帮助文档列出的
//! `java.downloadFile/cacheFile/importScript/getFile/readTxtFile/
//! getTxtInFolder/deleteFile/readFile` 在生产全部 `undefined`。
//!
//! 修复口径（对齐上游 `JsExtensions.kt` 的「限域在 externalCache，而非
//! 禁用」）：
//! - **上游同名的 8 个文件 API 始终注册**；
//! - `allow_file_access=false` 时路径经 `FsPolicy` 限域到引擎沙箱根
//!   （`file_utils::default_sandbox_root()`，按书源 tag 分子目录），
//!   `..` / 沙箱外绝对路径 / UNC / 符号链接逃逸一律显式报错；
//! - `writeFile` / `fileExists` / `downloadFile(url, fileName)` 为**我方
//!   扩展（原版不存在）**，恢复 gated：仅 `allow_file_access=true` 注册；
//! - `allow_file_access=true` 时保持不受限（调试 / 可信脚本）。
//!
//! 本文件中的「生产配置」与 `engine_cache.rs` / `executor.rs` /
//! `capability_sweep.rs` 完全同源。

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use legado_js::engine::{JsEngine, QuickJsEngine};
use legado_js::host_api::current_source::with_current_source_tag;
use legado_js::host_api::file_utils;
use legado_js::sandbox::SandboxConfig;

/// 上游 `JsExtensions.kt` 同名的文件 API（生产必须始终可用）
const UPSTREAM_FILE_APIS: &[&str] = &[
    "downloadFile",
    "cacheFile",
    "importScript",
    "getFile",
    "readFile",
    "readTxtFile",
    "getTxtInFolder",
    "deleteFile",
];

/// 我方扩展（上游不存在；仅 `allow_file_access=true` 注册）
const EXTENSION_FILE_APIS: &[&str] = &["writeFile", "fileExists"];

fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

fn permissive_engine() -> QuickJsEngine {
    QuickJsEngine::new(SandboxConfig::permissive()).expect("permissive 引擎创建失败")
}

fn unique(tag: &str) -> String {
    static SEQ: AtomicUsize = AtomicUsize::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    format!(
        "{tag}_{}_{}_{}",
        std::process::id(),
        nanos,
        SEQ.fetch_add(1, Ordering::Relaxed)
    )
}

/// JS 字符串字面量（JSON 转义与 JS 兼容）
fn js_str(value: &str) -> String {
    serde_json::to_string(value).expect("JS 字符串序列化失败")
}

fn assert_throws(engine: &QuickJsEngine, expr: &str, needle: &str) {
    match engine.eval(expr) {
        Ok(value) => panic!("表达式应抛错但返回 {value:?}: {expr}"),
        Err(err) => {
            let msg = format!("{err}");
            assert!(
                msg.contains(needle),
                "错误信息应包含 {needle:?}，实际: {msg}（expr: {expr}）"
            );
        }
    }
}

fn assert_error_string(engine: &QuickJsEngine, expr: &str, needle: &str) -> String {
    let value = engine
        .eval(expr)
        .unwrap_or_else(|e| panic!("表达式执行失败: {expr}: {e}"));
    assert!(
        value.starts_with("[ERROR]"),
        "应返回明确 [ERROR]，实际: {value:?}（expr: {expr}）"
    );
    assert!(
        value.contains(needle),
        "错误信息应包含 {needle:?}，实际: {value:?}（expr: {expr}）"
    );
    value
}

fn cleanup_dir(path: &Path) {
    let _ = std::fs::remove_dir_all(path);
}

/// 沙箱内写夹具（生产档 `writeFile` 不可用，测试直接用 std::fs）
fn write_fixture(root: &Path, relative: &str, content: &str) -> PathBuf {
    let path = root.join(relative);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(&path, content).unwrap();
    path
}

/// 期望的 canonical 形式（与 `FsPolicy` 返回值同口径：剥离 Windows verbatim）
fn canonical_expected(path: &Path) -> PathBuf {
    let canonical = std::fs::canonicalize(path).expect("canonicalize 测试路径");
    #[cfg(windows)]
    {
        let text = canonical.to_string_lossy();
        if let Some(rest) = text.strip_prefix(r"\\?\") {
            if !rest.starts_with("UNC\\") {
                return PathBuf::from(rest);
            }
        }
    }
    canonical
}

// ---------------------------------------------------------------------------
// 1. 生产配置注册面（P1-1：上游同名可用；我方扩展不可用）
// ---------------------------------------------------------------------------

#[test]
fn production_config_registers_upstream_file_apis_only() {
    let engine = production_engine();
    for name in UPSTREAM_FILE_APIS {
        let via_java = engine.eval(&format!("typeof java.{name}")).unwrap();
        assert_eq!(
            via_java, "function",
            "生产配置（allow_file_access=false）下 java.{name} 应为函数"
        );
        let bare = engine.eval(&format!("typeof {name}")).unwrap();
        assert_eq!(
            bare, "function",
            "生产配置（allow_file_access=false）下裸全局 {name} 应为函数"
        );
    }

    // P1-1：原版不存在的写/探测能力不得进入生产注册面
    for name in EXTENSION_FILE_APIS {
        let via_java = engine.eval(&format!("typeof java.{name}")).unwrap();
        assert_eq!(
            via_java, "undefined",
            "生产配置下 java.{name} 应为 undefined（非原版能力）"
        );
        let bare = engine.eval(&format!("typeof {name}")).unwrap();
        assert_eq!(
            bare, "undefined",
            "生产配置下裸全局 {name} 应为 undefined（非原版能力）"
        );
    }

    // downloadFile(url, fileName) 文件名重载：生产拒绝，且不联网（回环端口 1）
    assert_error_string(
        &engine,
        &format!(
            "java.downloadFile({}, {})",
            js_str("http://127.0.0.1:1/never-reached.bin"),
            js_str("custom-name.bin")
        ),
        "非原版 API",
    );

    // permissive：扩展能力恢复可用（原版同名亦在）
    let permissive = permissive_engine();
    for name in EXTENSION_FILE_APIS {
        let via_java = permissive.eval(&format!("typeof java.{name}")).unwrap();
        assert_eq!(
            via_java, "function",
            "allow_file_access=true 时 java.{name} 应可用"
        );
    }
    let probe_dir = std::env::temp_dir().join(unique("file_api_permissive_probe"));
    std::fs::create_dir_all(&probe_dir).unwrap();
    let probe_file = probe_dir.join("probe.txt");
    let written = permissive
        .eval(&format!(
            "java.writeFile({}, 'x')",
            js_str(&probe_file.to_string_lossy())
        ))
        .unwrap();
    assert_eq!(written, "true");
    assert!(probe_file.is_file(), "permissive writeFile 应落盘");
    cleanup_dir(&probe_dir);
}

// ---------------------------------------------------------------------------
// 2. 沙箱根内读取 / 文本读取 / 文件夹读取 / 删除 / getFile 元数据
// ---------------------------------------------------------------------------

#[test]
fn restricted_mode_reads_sandbox_files() {
    let engine = production_engine();
    let base = file_utils::default_sandbox_root();
    let sub = unique("file_api_rw");
    write_fixture(&base, &format!("{sub}/a.txt"), "hello");
    write_fixture(&base, &format!("{sub}/b.log"), "world");

    let result = engine
        .eval(&format!(
            r#"
            var r = java.readFile({a});
            var txt = java.readTxtFile({a});
            var missing = java.readFile({missing});
            var f = java.getFile({a});
            [r, txt, missing, String(f.exists()), f.getName()].join('|')
            "#,
            a = js_str(&format!("{sub}/a.txt")),
            missing = js_str(&format!("{sub}/nope.txt")),
        ))
        .unwrap();
    assert_eq!(result, "hello|hello||true|a.txt");

    // 文件夹读取（对齐上游 listFiles：不限扩展名）
    let folder = engine
        .eval(&format!("java.getTxtInFolder({})", js_str(&sub)))
        .unwrap();
    assert!(folder.contains("hello"), "folder = {folder}");
    assert!(folder.contains("world"), "folder = {folder}");

    // 删除 + 删除后元数据
    let deleted = engine
        .eval(&format!(
            "java.deleteFile({})",
            js_str(&format!("{sub}/a.txt"))
        ))
        .unwrap();
    assert_eq!(deleted, "true");
    assert!(
        !base.join(&sub).join("a.txt").exists(),
        "deleteFile 应删除文件"
    );
    let file_meta = engine
        .eval(&format!(
            r#"var f = java.getFile({}); [String(f.exists()), f.getName()].join('|')"#,
            js_str(&format!("{sub}/a.txt"))
        ))
        .unwrap();
    assert_eq!(file_meta, "false|a.txt");

    cleanup_dir(&base.join(&sub));
}

// ---------------------------------------------------------------------------
// 3. 越界路径全部显式拒绝（.. / 沙箱外绝对路径 / UNC / 设备前缀）
// ---------------------------------------------------------------------------

#[test]
fn restricted_mode_rejects_paths_outside_sandbox() {
    let engine = production_engine();

    for expr in [
        format!("java.readFile({})", js_str("../legado_p1_escape.txt")),
        format!("java.readTxtFile({})", js_str("../legado_p1_escape.txt")),
        format!("java.getFile({})", js_str("../legado_p1_escape.txt")),
        // deleteFile 走写策略（生产可用的写侧探针）
        format!("java.deleteFile({})", js_str("../legado_p1_escape.txt")),
    ] {
        assert_throws(&engine, &expr, "文件访问被拒绝");
    }

    // 沙箱外绝对路径（跨平台取系统文件）
    let outside = if cfg!(windows) {
        "C:\\Windows\\win.ini"
    } else {
        "/etc/passwd"
    };
    assert_throws(
        &engine,
        &format!("java.readFile({})", js_str(outside)),
        "文件访问被拒绝",
    );
    assert_throws(
        &engine,
        &format!("java.readTxtFile({})", js_str(outside)),
        "文件访问被拒绝",
    );

    // 字符串 API 返回 [ERROR]（不静默）
    assert_error_string(
        &engine,
        &format!("java.getTxtInFolder({})", js_str("..")),
        "文件访问被拒绝",
    );
    assert_error_string(
        &engine,
        &format!("java.importScript({})", js_str("../legado_p1_escape.js")),
        "文件访问被拒绝",
    );
    // downloadFile(url) 的 URL 尾段为 `..`：落盘路径越界，联网前即拒绝
    assert_error_string(
        &engine,
        &format!("java.downloadFile({})", js_str("http://127.0.0.1:1/..")),
        "文件访问被拒绝",
    );

    #[cfg(windows)]
    {
        for raw in [
            r"\\?\C:\Windows\win.ini",
            r"\\server\share\evil.txt",
            r"\\.\COM1",
        ] {
            assert_throws(
                &engine,
                &format!("java.readFile({})", js_str(raw)),
                "UNC/设备/verbatim",
            );
        }
    }
}

// ---------------------------------------------------------------------------
// 4. 符号链接 / junction 逃逸被拒绝（读 + 写策略）
// ---------------------------------------------------------------------------

fn create_dir_link(link: &Path, target: &Path) -> bool {
    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link).is_ok()
    }
    #[cfg(windows)]
    {
        std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"])
            .arg(link)
            .arg(target)
            .output()
            .map(|out| out.status.success())
            .unwrap_or(false)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = (link, target);
        false
    }
}

#[test]
fn restricted_mode_rejects_symlink_escape() {
    let engine = production_engine();
    let base = file_utils::default_sandbox_root();
    let target = std::env::temp_dir().join(unique("file_api_link_target"));
    std::fs::create_dir_all(&target).unwrap();
    std::fs::write(target.join("secret.txt"), b"SECRET").unwrap();
    std::fs::write(target.join("victim.txt"), b"KEEP").unwrap();

    let link = base.join(unique("file_api_link"));
    std::fs::create_dir_all(&base).unwrap();
    if !create_dir_link(&link, &target) {
        eprintln!("skip: 当前环境无法创建目录链接（权限不足）");
        cleanup_dir(&target);
        return;
    }

    // 读：链接内文件真实路径在沙箱外 → 拒绝
    assert_throws(
        &engine,
        &format!(
            "java.readFile({})",
            js_str(&link.join("secret.txt").to_string_lossy())
        ),
        "文件访问被拒绝",
    );
    // 写策略（deleteFile）：链接内目标真实路径在沙箱外 → 拒绝且不得删除
    assert_throws(
        &engine,
        &format!(
            "java.deleteFile({})",
            js_str(&link.join("victim.txt").to_string_lossy())
        ),
        "文件访问被拒绝",
    );
    assert!(
        target.join("victim.txt").exists(),
        "越界写策略不得删除沙箱外文件"
    );

    let _ = std::fs::remove_dir(&link);
    cleanup_dir(&target);
}

// ---------------------------------------------------------------------------
// 5. 下载 / 缓存 / 脚本导入的落盘与内容语义（本地回环）
// ---------------------------------------------------------------------------

/// 回环 HTTP 服务：按路径返回固定内容，并统计每路径命中次数。
fn spawn_loopback(
    hits: Arc<std::sync::Mutex<std::collections::HashMap<String, usize>>>,
) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        for stream in listener.incoming().take(8) {
            let Ok(mut sock) = stream else { continue };
            let path = read_request_path(&mut sock);
            {
                let mut map = hits.lock().unwrap();
                *map.entry(path.clone()).or_insert(0) += 1;
            }
            let resp = match path.as_str() {
                "/download.bin" => response(200, "application/octet-stream", b"BINARY-DATA-123"),
                "/script.js" => response(200, "text/plain", b"1 + 1"),
                "/import.js" => response(200, "text/plain", b"globalThis.__imported_value = 42;"),
                _ => response(404, "text/plain", b"not found"),
            };
            let _ = sock.write_all(&resp);
        }
    });
    addr
}

fn read_request_path(sock: &mut TcpStream) -> String {
    let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let mut buf = Vec::new();
    let mut byte = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        if sock.read_exact(&mut byte).is_err() {
            break;
        }
        buf.push(byte[0]);
        if buf.len() > 64 * 1024 {
            break;
        }
    }
    String::from_utf8_lossy(&buf)
        .lines()
        .next()
        .unwrap_or_default()
        .split_whitespace()
        .nth(1)
        .unwrap_or("/")
        .to_string()
}

fn response(status: u16, content_type: &str, body: &[u8]) -> Vec<u8> {
    let mut out = format!(
        "HTTP/1.1 {status} OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    )
    .into_bytes();
    out.extend_from_slice(body);
    out
}

fn hit_count(
    hits: &Arc<std::sync::Mutex<std::collections::HashMap<String, usize>>>,
    path: &str,
) -> usize {
    hits.lock().unwrap().get(path).copied().unwrap_or(0)
}

#[test]
fn restricted_mode_download_cache_import_script() {
    let hits = Arc::new(std::sync::Mutex::new(std::collections::HashMap::new()));
    let addr = spawn_loopback(hits.clone());
    let engine = production_engine();
    let base = file_utils::default_sandbox_root();
    let sub = unique("file_api_dl");

    // downloadFile(url) → 沙箱内落盘（文件名由 URL 尾段生成），返回绝对路径
    let downloaded = engine
        .eval(&format!(
            "java.downloadFile({})",
            js_str(&format!("http://{addr}/download.bin"))
        ))
        .unwrap();
    assert!(
        !downloaded.starts_with("[ERROR]"),
        "downloadFile 失败: {downloaded}"
    );
    let downloaded_path = PathBuf::from(&downloaded);
    // P2-1：返回路径即 canonical（校验路径 = IO 路径）
    assert_eq!(downloaded_path, canonical_expected(&downloaded_path));
    assert!(
        downloaded_path.starts_with(canonical_expected(&base)),
        "落盘路径应在沙箱内: {downloaded}（沙箱根 {}）",
        base.display()
    );
    assert_eq!(std::fs::read(&downloaded_path).unwrap(), b"BINARY-DATA-123");
    let _ = std::fs::remove_file(&downloaded_path);

    // cacheFile(url) 返回**内容**；二次调用命中缓存不再请求
    let url = format!("http://{addr}/script.js");
    let first = engine
        .eval(&format!("java.cacheFile({})", js_str(&url)))
        .unwrap();
    assert_eq!(first, "1 + 1");
    let second = engine
        .eval(&format!("java.cacheFile({}, 60)", js_str(&url)))
        .unwrap();
    assert_eq!(second, "1 + 1");
    assert_eq!(
        hit_count(&hits, "/script.js"),
        1,
        "cacheFile 二次调用应命中缓存（saveTime 生效期内）"
    );

    // importScript(URL) 返回脚本内容，且 eval 后可在生产引擎执行
    let import_url = format!("http://{addr}/import.js");
    let code = engine
        .eval(&format!(
            "eval(String(java.importScript({}))); String(globalThis.__imported_value)",
            js_str(&import_url)
        ))
        .unwrap();
    assert_eq!(code, "42");

    // importScript(本地相对路径) 读取沙箱内脚本文本
    write_fixture(&base, &format!("{sub}/local.js"), "2 + 2");
    let local = engine
        .eval(&format!(
            "java.importScript({})",
            js_str(&format!("{sub}/local.js"))
        ))
        .unwrap();
    assert_eq!(local, "2 + 2");

    cleanup_dir(&base.join(&sub));
}

// ---------------------------------------------------------------------------
// 6. 书源隔离（P2-2）：沙箱根按 tag 分子目录，跨源不可见
// ---------------------------------------------------------------------------

#[test]
fn per_source_sandbox_is_isolated() {
    let engine = production_engine();
    let tag_a = "https://source-a.example/";
    let tag_b = "https://source-b.example/";

    let root_a = with_current_source_tag(tag_a, file_utils::default_sandbox_root);
    let root_b = with_current_source_tag(tag_b, file_utils::default_sandbox_root);
    let shared = file_utils::default_sandbox_root();
    assert_ne!(root_a, root_b, "不同书源必须使用不同沙箱子目录");
    assert_ne!(root_a, shared, "带 tag 的书源不得落在 _shared");
    assert!(
        shared.ends_with("_shared"),
        "无 tag 入口应落在 _shared: {}",
        shared.display()
    );

    let name = unique("secret.txt");
    std::fs::create_dir_all(&root_a).unwrap();
    std::fs::write(root_a.join(&name), "SOURCE_A").unwrap();

    // 同源可读
    let read_a = with_current_source_tag(tag_a, || {
        engine.eval(&format!("java.readFile({})", js_str(&name)))
    })
    .unwrap();
    assert_eq!(read_a, "SOURCE_A");

    // 其他书源：同名相对路径解析到**自己的**沙箱根，读不到 A 的文件
    // （P2-2 的语义是按目录隔离，不是拒绝该相对路径）
    let read_b = with_current_source_tag(tag_b, || {
        engine.eval(&format!("java.readFile({})", js_str(&name)))
    })
    .unwrap();
    assert_eq!(read_b, "", "跨书源不得读到 A 的文件");
    let exists_b = with_current_source_tag(tag_b, || {
        engine.eval(&format!("java.getFile({}).exists()", js_str(&name)))
    })
    .unwrap();
    assert_eq!(exists_b, "false", "B 的沙箱根内不应看到 A 的文件");

    // 无 tag（调试 / js_eval）使用 _shared，同样读不到书源文件
    let read_shared = engine
        .eval(&format!("java.readFile({})", js_str(&name)))
        .unwrap();
    assert_eq!(read_shared, "", "无 tag 入口应落在 _shared，不得读书源文件");

    let _ = std::fs::remove_file(root_a.join(&name));
    cleanup_dir(&root_a);
    cleanup_dir(&root_b);
}

// ---------------------------------------------------------------------------
// 7. 资源上限（P2-6）：单文件 32MB / 文件夹累计 64MB
// ---------------------------------------------------------------------------

#[test]
fn restricted_mode_enforces_size_limits() {
    const MAX_FILE: u64 = 32 * 1024 * 1024;
    let engine = production_engine();
    let base = file_utils::default_sandbox_root();
    let sub = unique("file_api_size");
    let dir = base.join(&sub);
    std::fs::create_dir_all(&dir).unwrap();

    // 单文件超限（稀疏文件，不实际写入 33MB 数据）
    let big = dir.join("big.txt");
    let file = std::fs::File::create(&big).unwrap();
    file.set_len(MAX_FILE + 1).unwrap();
    drop(file);
    assert_throws(
        &engine,
        &format!("java.readFile({})", js_str(&big.to_string_lossy())),
        "超出大小上限",
    );
    assert_throws(
        &engine,
        &format!("java.readTxtFile({})", js_str(&big.to_string_lossy())),
        "超出大小上限",
    );

    // 文件夹累计超限：3 × 24MB = 72MB > 64MB，读入前按元数据拒绝
    let folder = dir.join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    for index in 0..3 {
        let file = std::fs::File::create(folder.join(format!("part{index}.txt"))).unwrap();
        file.set_len(24 * 1024 * 1024).unwrap();
    }
    assert_error_string(
        &engine,
        &format!("java.getTxtInFolder({})", js_str(&folder.to_string_lossy())),
        "累计超出大小上限",
    );

    cleanup_dir(&dir);
}

// ---------------------------------------------------------------------------
// 8. allow_file_access=true 保持不受限（既有调试/可信脚本行为）
// ---------------------------------------------------------------------------

#[test]
fn permissive_mode_keeps_arbitrary_paths() {
    let engine = permissive_engine();
    let dir = std::env::temp_dir().join(unique("file_api_permissive"));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("outside.txt");

    let written = engine
        .eval(&format!(
            "java.writeFile({}, 'outside-content')",
            js_str(&file.to_string_lossy())
        ))
        .unwrap();
    assert_eq!(written, "true");
    assert_eq!(std::fs::read_to_string(&file).unwrap(), "outside-content");

    let read = engine
        .eval(&format!(
            "java.readFile({})",
            js_str(&file.to_string_lossy())
        ))
        .unwrap();
    assert_eq!(read, "outside-content");

    let exists = engine
        .eval(&format!(
            "java.fileExists({})",
            js_str(&file.to_string_lossy())
        ))
        .unwrap();
    assert_eq!(exists, "true");

    cleanup_dir(&dir);
}
