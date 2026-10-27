//! 批21a：RSS WebView `preloadJs` 宿主桥回环端到端用例
//!
//! 独立测试二进制（独立进程，`db_open` 只初始化一次），全部网络请求打
//! `127.0.0.1` 回环 mock（P2-17 纪律）。覆盖：
//!
//! ```text
//! __prepare（源 preloadJs 非空）
//!   → script 含 IIFE/java/source/cache 垫片 + 拼接口径标记
//!   → snapshot 只读快照（sourceUrl/sourceName/loginHeader/userAgent）
//! __prepare（源 preloadJs 空）→ script 为空串（门控）
//! ajaxAwait → 回环响应体；服务端收到源静态 header + __prepare UA
//! getAwait  → 回环响应体；调用方 header 覆盖/追加源 header
//! run / getStringAwait / 加解密往返
//! downloadFileAwait → 明确不支持
//! run 超大结果 → ok:false「结果超限」
//! __cookieSet → cookies_for_url 可读 + cookies 表落库（先持久化）
//! __store loginHeaderSet → 登录头落库 + Cookie 键同步
//! __store cachePut/cacheGet/cacheRemove → cache_store 磁盘层
//! 未知方法 / 源不存在 → ok:false
//! ```

#![cfg(feature = "quickjs")]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};

/// 请求目标 → (状态行, 正文)
type Routes = Arc<dyn Fn(&str) -> (String, String) + Send + Sync>;

/// 回环服务器（循环 accept + 每连接独立线程 + 记录请求头 + Drop 关闭）
struct LoopbackServer {
    addr: SocketAddr,
    shutdown: Arc<AtomicBool>,
    heads: Arc<Mutex<Vec<String>>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl LoopbackServer {
    fn spawn(routes: Routes) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("绑定回环端口");
        let addr = listener.local_addr().expect("读取端口");
        let shutdown = Arc::new(AtomicBool::new(false));
        let heads = Arc::new(Mutex::new(Vec::new()));
        let shutdown_thread = Arc::clone(&shutdown);
        let heads_thread = Arc::clone(&heads);
        let handle = std::thread::spawn(move || {
            while !shutdown_thread.load(Ordering::SeqCst) {
                let Ok((mut stream, _)) = listener.accept() else {
                    break;
                };
                if shutdown_thread.load(Ordering::SeqCst) {
                    break;
                }
                let routes = Arc::clone(&routes);
                let heads = Arc::clone(&heads_thread);
                std::thread::spawn(move || {
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                    let head = read_request_head(&mut stream);
                    if head.is_empty() {
                        return;
                    }
                    let target = head
                        .lines()
                        .next()
                        .unwrap_or_default()
                        .split_whitespace()
                        .nth(1)
                        .unwrap_or_default()
                        .to_string();
                    heads.lock().unwrap().push(head.clone());
                    let (status, body) = routes(&target);
                    let response = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: text/plain; charset=utf-8\r\n\
                         Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(response.as_bytes());
                    let _ = stream.flush();
                });
            }
        });
        Self {
            addr,
            shutdown,
            heads,
            handle: Some(handle),
        }
    }

    fn base_url(&self) -> String {
        format!("http://{}", self.addr)
    }

    /// 取指定路径的请求头（第一个命中）
    fn head_for(&self, path: &str) -> String {
        let heads = self.heads.lock().unwrap();
        heads
            .iter()
            .find(|head| {
                head.lines()
                    .next()
                    .unwrap_or_default()
                    .split_whitespace()
                    .nth(1)
                    == Some(path)
            })
            .cloned()
            .unwrap_or_else(|| panic!("未捕获 {path} 请求；已捕获 {heads:?}"))
    }
}

impl Drop for LoopbackServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        let _ = TcpStream::connect(self.addr);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

fn read_request_head(stream: &mut TcpStream) -> String {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        match stream.read(&mut byte) {
            Ok(0) | Err(_) => break,
            Ok(_) => {
                head.push(byte[0]);
                if head.ends_with(b"\r\n\r\n") {
                    break;
                }
            }
        }
    }
    String::from_utf8_lossy(&head).into_owned()
}

fn temp_db_path() -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "legado-ffi-rss-web-bridge-{}.db",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn temp_cache_dir() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("legado-ffi-rss-web-cache-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&dir);
    dir
}

fn add_source(url: &str, extra: Value) {
    let mut source = json!({
        "sourceUrl": url,
        "sourceName": "宿主桥回环源",
        "enabled": true,
    });
    if let (Some(obj), Some(extra)) = (source.as_object_mut(), extra.as_object()) {
        for (k, v) in extra {
            obj.insert(k.clone(), v.clone());
        }
    }
    legado_ffi::api::rss::add_rss_source(&source.to_string()).expect("写入 RSS 源");
}

fn call(source_url: &str, method: &str, args: Value) -> Value {
    let raw = legado_ffi::api::rss_web_bridge::rss_web_view_host_call(
        source_url,
        method,
        &args.to_string(),
    )
    .expect("宿主桥调用返回信封");
    serde_json::from_str(&raw).expect("信封必须是合法 JSON")
}

/// 大小写不敏感地判断请求头里是否含 `name: value`
fn head_has(head: &str, name: &str, value: &str) -> bool {
    head.lines().any(|line| {
        let Some((k, v)) = line.split_once(':') else {
            return false;
        };
        k.trim().eq_ignore_ascii_case(name) && v.trim().contains(value)
    })
}

#[test]
fn rss_web_view_host_bridge_loopback_end_to_end() {
    let db_path = temp_db_path();
    legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned()).expect("db_open");
    // cache_store 磁盘层落独立临时目录（独立测试进程，无并发漂移）
    legado_js::host_api::cache_store::set_cache_dir(temp_cache_dir());

    let routes: Routes = Arc::new(|target: &str| match target {
        "/ajax" => ("200 OK".to_string(), "ajax-body-ok".to_string()),
        "/get" => ("200 OK".to_string(), "get-body-ok".to_string()),
        "/jslib.js" => (
            "200 OK".to_string(),
            "var __JSLIB_VALUE = 'jslib-ok';".to_string(),
        ),
        _ => ("404 Not Found".to_string(), String::new()),
    });
    let server = LoopbackServer::spawn(routes);
    let base = server.base_url();

    // ─── 1) 源 + __prepare ─────────────────────────────────────────────
    const SOURCE_URL: &str = "https://rss-web-bridge-e2e.test/feed";
    add_source(
        SOURCE_URL,
        json!({
            "preloadJs": "window.__probe = 1;",
            "header": "{\"X-Source\":\"src-v\"}",
        }),
    );
    let prepare = call(
        SOURCE_URL,
        "__prepare",
        json!([{ "channelName": "legadoChannel", "callbackName": "legadoCb", "ua": "UA-Prepare" }]),
    );
    assert_eq!(prepare["ok"], true, "{prepare}");
    let script = prepare["value"]["script"]
        .as_str()
        .expect("script 字符串")
        .to_string();
    for needle in [
        "(() => {",
        "delete window[__lgChannelName]",
        "Object.defineProperty(window, __lgCallbackName",
        "var source = {",
        "// __LEGADO_PRELOAD_JS__",
    ] {
        assert!(script.contains(needle), "脚本缺少 {needle}");
    }
    for forbidden in [
        "window.java = java",
        "window.source = source",
        "window.cache = cache",
    ] {
        assert!(
            !script.contains(forbidden),
            "桥对象不得残留全局：{forbidden}"
        );
    }
    assert_eq!(prepare["value"]["snapshot"]["sourceUrl"], SOURCE_URL);
    assert_eq!(prepare["value"]["snapshot"]["sourceName"], "宿主桥回环源");
    assert_eq!(prepare["value"]["snapshot"]["userAgent"], "UA-Prepare");

    // 门控：preloadJs 为空的源不返回桥
    const GATED_URL: &str = "https://rss-web-bridge-e2e-gated.test/feed";
    add_source(GATED_URL, json!({}));
    let gated = call(
        GATED_URL,
        "__prepare",
        json!([{ "channelName": "legadoChannel", "callbackName": "legadoCb" }]),
    );
    assert_eq!(gated["ok"], true, "{gated}");
    assert_eq!(gated["value"]["script"], "", "preloadJs 为空不得返回桥脚本");

    // ─── 2) ajaxAwait：响应体 + 源静态 header + __prepare UA ───────────
    let env = call(
        SOURCE_URL,
        "ajaxAwait",
        json!([format!("{base}/ajax"), "9000"]),
    );
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "ajax-body-ok", "{env}");
    let head = server.head_for("/ajax");
    assert!(
        head_has(&head, "X-Source", "src-v"),
        "ajaxAwait 必须携带源静态 header: {head}"
    );
    assert!(
        head_has(&head, "User-Agent", "UA-Prepare"),
        "ajaxAwait 必须携带 __prepare UA: {head}"
    );

    // ─── 3) getAwait：调用方 header 与源 header 合并 ───────────────────
    let env = call(
        SOURCE_URL,
        "getAwait",
        json!([format!("{base}/get"), "{\"X-Extra\":\"e1\"}", "9000"]),
    );
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "get-body-ok", "{env}");
    let head = server.head_for("/get");
    assert!(head_has(&head, "X-Source", "src-v"), "{head}");
    assert!(head_has(&head, "X-Extra", "e1"), "{head}");
    assert!(head_has(&head, "User-Agent", "UA-Prepare"), "{head}");

    // ─── 3.5) 源 concurrentRate 限流（网络类宿主调用每调用一许可） ─────
    const RATE_URL: &str = "https://rss-web-bridge-e2e-rate.test/feed";
    add_source(RATE_URL, json!({ "concurrentRate": "1/300" }));
    let started = std::time::Instant::now();
    for _ in 0..2 {
        let env = call(
            RATE_URL,
            "ajaxAwait",
            json!([format!("{base}/ajax"), "9000"]),
        );
        assert_eq!(env["ok"], true, "{env}");
    }
    let elapsed = started.elapsed();
    assert!(
        elapsed >= std::time::Duration::from_millis(250),
        "concurrentRate=1/300 时两次 ajaxAwait 应被限流（实际 {elapsed:?}）"
    );
    legado_ffi::api::rss::delete_rss_source(RATE_URL).ok();

    // ─── 4) run / getStringAwait / 加解密往返 ──────────────────────────
    // 批21d P2-3：先 seed 登录头再创建引擎（setup 种子），随后 set 覆盖
    legado_ffi::api::source_login_cache::put_login_header(SOURCE_URL, r#"{"Seed":"1"}"#)
        .expect("seed 登录头");
    let env = call(SOURCE_URL, "run", json!(["'run-ok'"]));
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "run-ok");

    let env = call(
        SOURCE_URL,
        "run",
        json!(["String(source.getLoginHeader())"]),
    );
    assert_eq!(
        env["value"], r#"{"Seed":"1"}"#,
        "引擎创建时 setup 必须预置 seed 登录头: {env}"
    );

    // 批21c P2-3：间接 eval 使 `var` 跨调用持久（原版 evalJS 全局语义）
    let env = call(
        SOURCE_URL,
        "run",
        json!(["var __lgLoopProbe = 41; __lgLoopProbe"]),
    );
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "41", "{env}");
    let env = call(SOURCE_URL, "run", json!(["__lgLoopProbe + 1"]));
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "42", "run 内 var 必须持久: {env}");

    // 批21c P2-2：URL 映射形态 jsLib 经 jslib_loader 拉取后加载
    const JSLIB_URL: &str = "https://rss-web-bridge-e2e-jslib.test/feed";
    add_source(
        JSLIB_URL,
        json!({ "jsLib": format!("{{\"lib\":\"{base}/jslib.js\"}}") }),
    );
    let env = call(JSLIB_URL, "run", json!(["__JSLIB_VALUE"]));
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "jslib-ok", "URL 映射 jsLib 未加载: {env}");
    legado_ffi::api::rss::delete_rss_source(JSLIB_URL).ok();

    let env = call(
        SOURCE_URL,
        "getStringAwait",
        json!([".title", "<html><div class=\"title\">T1</div></html>"]),
    );
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"], "T1", "{env}");

    let cipher = call(
        SOURCE_URL,
        "encryptBase64Await",
        json!([
            "AES/CBC/PKCS5Padding",
            "0123456789abcdef",
            "abcdef0123456789",
            "明文 round-trip"
        ]),
    );
    assert_eq!(cipher["ok"], true, "{cipher}");
    let cipher_text = cipher["value"].as_str().expect("密文串").to_string();
    assert!(!cipher_text.is_empty());
    let plain = call(
        SOURCE_URL,
        "decryptStrAwait",
        json!([
            "AES/CBC/PKCS5Padding",
            "0123456789abcdef",
            "abcdef0123456789",
            cipher_text
        ]),
    );
    assert_eq!(plain["ok"], true, "{plain}");
    assert_eq!(plain["value"], "明文 round-trip", "{plain}");

    // ─── 5) 未支持/超限/未知/源不存在 ──────────────────────────────────
    let env = call(
        SOURCE_URL,
        "downloadFileAwait",
        json!(["https://example.com/a.bin"]),
    );
    assert_eq!(env["ok"], false);
    assert!(
        env["error"].as_str().unwrap_or_default().contains("不支持"),
        "{env}"
    );

    let env = call(SOURCE_URL, "run", json!(["'x'.repeat(5 * 1024 * 1024)"]));
    assert_eq!(env["ok"], false, "超大结果必须被截断为错误: {env}");
    assert!(
        env["error"]
            .as_str()
            .unwrap_or_default()
            .contains("结果超限"),
        "{env}"
    );

    let env = call(SOURCE_URL, "notARealMethod", json!([]));
    assert_eq!(env["ok"], false);
    assert!(
        env["error"]
            .as_str()
            .unwrap_or_default()
            .contains("未知方法"),
        "{env}"
    );

    let env = call(
        "https://rss-web-bridge-e2e-missing.test/feed",
        "__prepare",
        json!([{ "channelName": "ch", "callbackName": "cb" }]),
    );
    assert_eq!(env["ok"], false);
    assert!(
        env["error"].as_str().unwrap_or_default().contains("不存在"),
        "{env}"
    );

    // ─── 6) __cookieSet：内存可读 + DB 落库 ────────────────────────────
    const COOKIE_URL: &str = "https://rss-web-bridge-e2e.test/page";
    let env = call(
        SOURCE_URL,
        "__cookieSet",
        json!([{ "url": COOKIE_URL, "cookie": "sid=abc123; t=1" }]),
    );
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(env["value"]["domainKey"], "rss-web-bridge-e2e.test");
    let cookies = legado_js::host_api::cookie_store::cookies_for_url(COOKIE_URL);
    assert!(cookies.contains("sid=abc123"), "{cookies}");
    let row = legado_db::CookieRepository::new(
        &rusqlite::Connection::open(&db_path).expect("直连临时 DB"),
    )
    .get_by_tag("rss-web-bridge-e2e.test")
    .expect("读 cookies 表");
    let row = row.expect("__cookieSet 必须落库");
    assert!(row.contains("sid=abc123"), "DB cookie 行: {row}");

    // ─── 7) __store：登录头落库 + Cookie 键同步 ────────────────────────
    let env = call(
        SOURCE_URL,
        "__store",
        json!([{
            "op": "loginHeaderSet",
            "value": "{\"Authorization\":\"Bearer T\",\"Cookie\":\"sid=login1\"}"
        }]),
    );
    assert_eq!(env["ok"], true, "{env}");
    let header = legado_ffi::api::source_login_cache::get_login_header(SOURCE_URL);
    assert!(header.unwrap_or_default().contains("Bearer T"));
    let cookies = legado_js::host_api::cookie_store::cookies_for_url(SOURCE_URL);
    assert!(
        cookies.contains("sid=login1"),
        "登录头 Cookie 键应同步到 Cookie 存储: {cookies}"
    );

    // 批21d P2-3：loginHeaderSet 同步变量表 → 已存在的引擎 run 内立即可读
    let env = call(
        SOURCE_URL,
        "run",
        json!(["String(source.getLoginHeader())"]),
    );
    assert_eq!(env["ok"], true, "{env}");
    assert_eq!(
        env["value"], "{\"Authorization\":\"Bearer T\",\"Cookie\":\"sid=login1\"}",
        "loginHeaderSet 后 run 必须读到新值: {env}"
    );

    // 批21c P2-8：loginHeaderRemove 同步变量表，run 内不得复活旧登录头
    let env = call(
        SOURCE_URL,
        "__store",
        json!([{ "op": "loginHeaderRemove" }]),
    );
    assert_eq!(env["ok"], true, "{env}");
    let env = call(
        SOURCE_URL,
        "run",
        json!(["String(source.getLoginHeader())"]),
    );
    assert_eq!(env["value"], "null", "登录头 remove 后不得复活: {env}");
    assert_eq!(
        legado_js::host_api::variable_store::get_variable(&format!("loginHeader_{SOURCE_URL}"))
            .unwrap(),
        None,
        "loginHeaderRemove 必须清除变量表"
    );

    // ─── 8) __store：cache 磁盘层 put/get/remove ──────────────────────
    let env = call(
        SOURCE_URL,
        "__store",
        json!([{ "op": "cachePut", "key": "rss-web-bridge-cache", "value": "cv" }]),
    );
    assert_eq!(env["ok"], true, "{env}");
    let env = call(
        SOURCE_URL,
        "__store",
        json!([{ "op": "cacheGet", "key": "rss-web-bridge-cache" }]),
    );
    assert_eq!(env["value"], "cv", "{env}");
    let env = call(
        SOURCE_URL,
        "__store",
        json!([{ "op": "cacheRemove", "key": "rss-web-bridge-cache" }]),
    );
    assert_eq!(env["value"], true, "{env}");
    let env = call(
        SOURCE_URL,
        "__store",
        json!([{ "op": "cacheGet", "key": "rss-web-bridge-cache" }]),
    );
    assert_eq!(env["value"], Value::Null, "{env}");

    // 收尾
    legado_ffi::api::rss::delete_rss_source(SOURCE_URL).ok();
    legado_ffi::api::rss::delete_rss_source(GATED_URL).ok();
    let _ = std::fs::remove_dir_all(temp_cache_dir());
}
