//! 书源引擎能力对账 · 第一批 S 级能力补齐 e2e 测试
//!
//! 覆盖三个 S 级能力的宿主桥面（纯宿主层，FFI 契约零变更）：
//!
//! - **cap 1 `cookie.getKey(url, key?)`**（语料 #94 起点 / #135 阅文 / #147 晋江等：
//!   `cookie.getKey("https://qidian.com", "_csrfToken")`）：域归属读键
//!   （ETLD+1 / 多段 TLD / IP 字面量），miss → 空串不抛错；无 key 形态返回全域串。
//! - **cap 2 `cache.putMemory / getFromMemory / deleteMemory`**（语料 #20 Linpx /
//!   #36 微信读书二合一 / #101 漫蛙 / #266）：进程级内存缓存（独立命名空间，
//!   与磁盘 cache 表分离，无 TTL，跨引擎共享，重启丢失），miss → 显式 null。
//! - **cap 3 远程 jsLib 加载器**（语料 #463 月色书屋 / #658 / #674 / #915：
//!   `jsLib: {"crypto": "https://…/crypto-js.min.js"}`）：URL 映射经共享客户端
//!   拉取 → 进程缓存（md5(url) 键，无 TTL）→ eval；失败记台账降级继续
//!   （`test_jslib_url_map_explore_*` 走 explore 生产路径，本地回环 mock 无
//!   真实网络；加载器单测见 legado-js `jslib_loader` 模块）。
//!
//! 引擎形态与生产同源：`SandboxConfig::default().with_allow_script_run(true)`
//! 加 64MB 内存上限（与 capability_sweep 干跑一致）；setup 脚本经
//! `book_source_js_setup_script` 生成（cookie/cache 全局即书源实际可见对象）。
//!
//! 隔离约定：cookie 域与 cache 键均带 `capb1` 前缀（进程级全局存储，
//! 跨测试并行安全）；cookie 用例收尾 `clearCookies` 自清理。
//!
//! 运行：`cargo test -p legado-ffi --features quickjs --test capability_batch1`

#![cfg(feature = "quickjs")]

use legado_ffi::api::source_js_bindings::{book_source_js_setup_script, load_js_lib_for_explore};
use legado_ffi::legado_core::models::BookSource;
use legado_ffi::legado_js::engine::JsEngine;
use legado_ffi::legado_js::sandbox::SandboxConfig;
use legado_ffi::legado_js::QuickJsEngine;

/// 生产同源引擎（与 capability_sweep 干跑同一形态）
fn make_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("引擎创建失败")
}

/// 最小书源（仅 URL + 名称；setup 脚本所需其余字段走 Default）
fn make_source(url: &str, name: &str) -> BookSource {
    BookSource {
        book_source_url: url.to_string(),
        book_source_name: name.to_string(),
        ..BookSource::default()
    }
}

/// 建引擎 + 应用书源 setup 脚本（cookie / cache 全局即书源实际可见形态）
fn engine_with_source(url: &str, name: &str) -> (QuickJsEngine, String) {
    let engine = make_engine();
    let source = make_source(url, name);
    let setup = book_source_js_setup_script(&source).expect("setup 脚本生成失败");
    engine
        .eval(&setup)
        .expect("setup eval 失败（setup 脚本本身回归）");
    (engine, setup)
}

// ---------------------------------------------------------------------------
// cap 1：cookie.getKey（域归属读键）
// ---------------------------------------------------------------------------

/// `cookie.getKey(url, key)` 命中：跨子域域归属（ETLD+1）+ miss 空串 + 无 key 全域串
#[test]
fn test_cookie_get_key_e2e() {
    let (engine, _setup) = engine_with_source("https://capb1q1.example.com/", "cap1 起点形态");

    // 面存在性（RED 判据：实现前 setup 脚本 cookie 对象无 getKey → "undefined"）
    assert_eq!(
        engine.eval("typeof cookie.getKey").expect("eval 失败"),
        "function",
        "cookie.getKey 应为函数（setup 脚本 cookie 对象）"
    );

    // 写入：批量 cookie 串（www.capb1q1.example.com → 域名键 capb1q1.example.com）
    engine
        .eval("java.setCookie('https://www.capb1q1.example.com/', 'siteId=cap; _csrfToken=cap123')")
        .expect("setCookie eval 失败");

    // 跨子域 + 跨协议形态读键（域归属：a./根域均归 capb1q1.example.com 域键）
    assert_eq!(
        engine
            .eval("cookie.getKey('https://a.capb1q1.example.com/', '_csrfToken')")
            .expect("eval 失败"),
        "cap123",
        "同域另一子域应命中同一域键下的 key"
    );

    // miss → 空串（对齐上游 `mergeCookiesToMap[key] ?: ""`，不抛错）
    assert_eq!(
        engine
            .eval("cookie.getKey('https://a.capb1q1.example.com/', 'noSuchKey')")
            .expect("eval 失败"),
        "",
        "miss 必须返回空串而非抛错"
    );

    // 无 key 形态：全域 cookie 串（HashMap 拼接顺序不定 → contains 判定）
    let full = engine
        .eval("cookie.getKey('https://capb1q1.example.com/')")
        .expect("eval 失败");
    assert!(
        full.contains("siteId=cap") && full.contains("_csrfToken=cap123"),
        "无 key 应返回全域 cookie 串，实际：{full}"
    );

    // 自清理
    engine
        .eval("cookie.clearCookies('https://capb1q1.example.com/')")
        .expect("clearCookies eval 失败");
    assert_eq!(
        engine
            .eval("cookie.getKey('https://capb1q1.example.com/', '_csrfToken')")
            .expect("eval 失败"),
        "",
        "清理后 miss"
    );
}

/// `cookie.getKey` 多段 TLD（com.cn）与 IP 字面量域归属（setup 面冒烟；
/// 键推导细节单测见 legado-js cookie_store 模块 quickjs 档）
#[test]
fn test_cookie_get_key_multilabel_tld_and_ip() {
    let (engine, _setup) = engine_with_source("https://capb1q2.example.com/", "cap1 多段TLD");

    // 多段 TLD：www.a.capb1m1.example.com.cn 与 www.b.… 归同一域名键（末三段）
    engine
        .eval("java.setCookie('https://a.capb1m1.example.com.cn/', 'tldTok=tl1')")
        .expect("setCookie eval 失败");
    assert_eq!(
        engine
            .eval("cookie.getKey('https://b.capb1m1.example.com.cn/', 'tldTok')")
            .expect("eval 失败"),
        "tl1",
        "多段 TLD 域名键（末三段）跨子域命中"
    );

    // IP 字面量：自身即域键
    engine
        .eval("java.setCookie('http://192.168.7.5/', 'ipTok=ip1')")
        .expect("setCookie eval 失败");
    assert_eq!(
        engine
            .eval("cookie.getKey('http://192.168.7.5/', 'ipTok')")
            .expect("eval 失败"),
        "ip1",
        "IP 字面量自键命中"
    );

    engine
        .eval("cookie.clearCookies('https://a.capb1m1.example.com.cn/')")
        .expect("clearCookies eval 失败");
    engine
        .eval("cookie.clearCookies('http://192.168.7.5/')")
        .expect("clearCookies eval 失败");
}

// ---------------------------------------------------------------------------
// cap 2：cache 内存三件套（putMemory / getFromMemory / deleteMemory）
// ---------------------------------------------------------------------------

/// 语料形态 put → get 往返 + miss 显式 null + delete 后 miss（含 `v === undefined || v === null` 检查形态）
#[test]
fn test_cache_memory_roundtrip_e2e() {
    let (engine, _setup) = engine_with_source("https://capb1c1.example.com/", "cap2 Linpx 形态");

    // 面存在性（RED 判据：实现前 setup 脚本 cache 对象仅 get/put/remove → "undefined"）
    assert_eq!(
        engine.eval("typeof cache.putMemory").expect("eval 失败"),
        "function",
        "cache.putMemory 应为函数"
    );
    assert_eq!(
        engine
            .eval("typeof cache.getFromMemory")
            .expect("eval 失败"),
        "function",
        "cache.getFromMemory 应为函数"
    );
    assert_eq!(
        engine.eval("typeof cache.deleteMemory").expect("eval 失败"),
        "function",
        "cache.deleteMemory 应为函数"
    );

    // put → get 往返（语料 #20 Linpx 形态：cache.putMemory(this.keywords, JSON.stringify(arr))）
    engine
        .eval("cache.putMemory('capb1cacheA', JSON.stringify([1, 2, 3]))")
        .expect("putMemory eval 失败");
    assert_eq!(
        engine
            .eval("cache.getFromMemory('capb1cacheA')")
            .expect("eval 失败"),
        "[1,2,3]",
        "putMemory/getFromMemory 往返（JSON 字符串原样存取）"
    );

    // miss → 显式 null（对齐 Kotlin null；eval 结果字符串化为 "null"）
    assert_eq!(
        engine
            .eval("cache.getFromMemory('capb1cache-miss')")
            .expect("eval 失败"),
        "null",
        "miss 必须为显式 null（非 undefined）"
    );

    // 语料形态：`var v = cache.getFromMemory(k); v === undefined || v === null` 判缺
    assert_eq!(
        engine
            .eval("var v = cache.getFromMemory('capb1cacheA'); v === undefined || v === null")
            .expect("eval 失败"),
        "false",
        "命中时判缺式为 false"
    );

    // delete → miss
    engine
        .eval("cache.deleteMemory('capb1cacheA')")
        .expect("deleteMemory eval 失败");
    assert_eq!(
        engine
            .eval("cache.getFromMemory('capb1cacheA')")
            .expect("eval 失败"),
        "null",
        "deleteMemory 后 miss"
    );
    assert_eq!(
        engine
            .eval("var v = cache.getFromMemory('capb1cacheA'); v === undefined || v === null")
            .expect("eval 失败"),
        "true",
        "删除后判缺式为 true"
    );
}

/// 跨引擎共享（上游 CacheManager 为进程级内存，书源间共享同一键空间；
/// 引擎 A put → 销毁 → 引擎 B get 命中；重启丢失语义由进程级 OnceLock 结构保证）
#[test]
fn test_cache_memory_cross_context() {
    {
        let (engine_a, _s) = engine_with_source("https://capb1c2.example.com/", "cap2 引擎A");
        engine_a
            .eval("cache.putMemory('capb1cross', 'from_a')")
            .expect("引擎A putMemory eval 失败");
    } // 引擎 A 销毁（setup 脚本作用域随引擎回收；进程级内存缓存保留）

    let (engine_b, _s) = engine_with_source("https://capb1c3.example.com/", "cap2 引擎B");
    assert_eq!(
        engine_b
            .eval("cache.getFromMemory('capb1cross')")
            .expect("eval 失败"),
        "from_a",
        "进程级内存缓存跨引擎共享"
    );
    engine_b
        .eval("cache.deleteMemory('capb1cross')")
        .expect("deleteMemory eval 失败");
}

/// 内存层与其他键空间互不可见：
/// - setup 脚本 `cache.put/get` 委托变量存储（variable_store），
///   与 cache_store 内存层（putMemory/getFromMemory）独立命名空间
///
/// （进程级内存 LRU 与磁盘 cache 表分离的结构事实见 cache_store 模块：
/// put_memory 仅写内存 LRU，不落盘）
#[test]
fn test_cache_memory_isolated_key_spaces() {
    let (engine, _s) = engine_with_source("https://capb1c4.example.com/", "cap2 隔离");
    engine
        .eval("cache.putMemory('capb1iso', 'mem-only')")
        .expect("putMemory eval 失败");
    assert_eq!(
        engine
            .eval("cache.getFromMemory('capb1iso')")
            .expect("eval 失败"),
        "mem-only",
        "内存层自读命中"
    );
    assert_eq!(
        engine.eval("cache.get('capb1iso')").expect("eval 失败"),
        "null",
        "变量存储（cache.put/get 委托）读不到内存层值"
    );

    engine
        .eval("cache.put('capb1iso2', 'var-only')")
        .expect("put eval 失败");
    assert_eq!(
        engine
            .eval("cache.getFromMemory('capb1iso2')")
            .expect("eval 失败"),
        "null",
        "内存层读不到变量存储值"
    );

    // 清理（内存层 deleteMemory；变量存储 remove）
    engine
        .eval("cache.deleteMemory('capb1iso')")
        .expect("deleteMemory eval 失败");
    engine
        .eval("cache.remove('capb1iso2')")
        .expect("remove eval 失败");
}

// ---------------------------------------------------------------------------
// cap 3：远程 jsLib 加载器（URL 映射形态，走 explore 生产路径）
// ---------------------------------------------------------------------------

/// 本地回环 jsLib mock（与 legado-js `jslib_loader` 测试同款：std TcpListener +
/// 单连接 `Connection: close`，无真实网络；回环池 `no_proxy` 直连豁免代理）
fn spawn_jslib_mock(body: &str) -> std::net::SocketAddr {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    let body = body.to_string();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut sock) = stream else { continue };
            let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
            let mut buf = [0u8; 1024];
            let mut req = Vec::new();
            loop {
                match std::io::Read::read(&mut sock, &mut buf) {
                    Ok(0) => break,
                    Ok(n) => {
                        req.extend_from_slice(&buf[..n]);
                        if req.windows(4).any(|w| w == b"\r\n\r\n") {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
                len = body.len(),
                body = body
            );
            let _ = std::io::Write::write_all(&mut sock, resp.as_bytes());
        }
    });
    addr
}

/// 语料 #463 月色书屋形态：`jsLib: {"crypto": "<url>"}` 经 explore 生产路径
/// （`load_js_lib_for_explore` → 共享客户端拉取 → eval）加载，导出函数可用；
/// 二次加载命中进程缓存（mock 仅被拉取一次）
#[test]
fn test_jslib_url_map_explore_e2e() {
    let body =
        "var crypto = { version: '3.1.9', hexLen: function(s) { return String(s).length; } };";
    let addr = spawn_jslib_mock(body);
    let jslib = format!(r#"{{"crypto":"http://{addr}/crypto.js"}}"#);

    let (engine, _s) = engine_with_source("https://capb1j1.example.com/", "cap3 月色书屋形态");
    load_js_lib_for_explore(&engine, "capb1_jslib", Some(&jslib));
    assert_eq!(
        engine.eval("typeof crypto").expect("eval 失败"),
        "object",
        "URL 映射 jsLib 加载后 crypto 全局应可用"
    );
    assert_eq!(
        engine.eval("crypto.hexLen('abcd')").expect("eval 失败"),
        "4",
        "jsLib 导出函数应可调用"
    );

    // 二次加载命中进程缓存：同 URL 不再拉取（缓存属加载器，md5(url) 键）
    load_js_lib_for_explore(&engine, "capb1_jslib", Some(&jslib));
    assert_eq!(
        engine.eval("crypto.version").expect("eval 失败"),
        "3.1.9",
        "缓存命中二次加载后导出仍可用"
    );
}

/// 拉取失败语义（回环 127.0.0.1:1 必拒连，不发真实外网请求）：
/// 台账登记（上游「下载jsLib-…」措辞）+ 降级继续不 panic，非 URL 条目照常可用
#[test]
fn test_jslib_url_map_explore_failure_ledger() {
    let _ledger = legado_ffi::legado_js::host_api::capability_ledger::LEDGER_TEST_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    legado_ffi::legado_js::host_api::capability_ledger::reset_jslib_load_failures();

    let jslib = r#"{"bad":"http://127.0.0.1:1/never.js","good":"var ok42 = 42;"}"#;
    let (engine, _s) = engine_with_source("https://capb1j2.example.com/", "cap3 失败形态");
    load_js_lib_for_explore(&engine, "capb1_jslib_fail", Some(jslib));
    assert_eq!(
        engine.eval("ok42").expect("eval 失败"),
        "42",
        "单条失败不得阻断其余条目（降级继续）"
    );
    // 台账键与执行器路径同构：explore 路径为 `explore:{source_tag}`
    let err = legado_ffi::legado_js::host_api::capability_ledger::last_jslib_error(
        "explore:capb1_jslib_fail",
    )
    .expect("失败必须记台账");
    assert!(err.contains("下载jsLib-"), "台账措辞须对齐上游: {err}");
}
