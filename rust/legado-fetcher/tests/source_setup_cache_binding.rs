//! 批37 P1 回归：书源 setup 脚本不得无条件覆盖引擎内置 `cache`
//!
//! 设备实测缺陷（两次复现一致）：书源规则 JS
//! `cache.get(java.md5Encode16(url))` 读不回 `java.cacheFile(url)` 写入的
//! 映射（返回 null），而 `java.downloadFile(url)` 正常返回相对名；
//! `cache.put` 的 `saveTime` 被丢弃（值永不过期）、`cache.putFile/getFile`
//! 为 undefined。根因：`book_source_js_setup_script` 无条件
//! `globalThis.cache = {...}`，把引擎内置的 `cache_store`（磁盘 + 内存 +
//! 文件缓存）覆盖成变量表镜像。RSS 分支已有同款守卫（批21c P2-7），书源
//! 分支漏加，属回归。
//!
//! 既有 `legado-js/tests/file_api_sandbox.rs` 在**裸引擎**上断言同一读回
//! 契约，绕过 setup，故门禁绿而线上坏。本文件在**执行了生产 setup 脚本**
//! 的引擎上复验（与 `QuickJsExecutor` / `construct_analyzer_with_source_context`
//! 注入的 setup 同源）。

#![cfg(feature = "quickjs")]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use legado_core::models::{BookSource, RssSource};
use legado_fetcher::source_setup::{book_source_js_setup_script, rss_source_js_setup_script};
use legado_js::engine::{JsEngine, QuickJsEngine};
use legado_js::host_api::current_source::with_current_source_tag;
use legado_js::host_api::{cache_store, variable_store};
use legado_js::sandbox::SandboxConfig;

/// 生产同源引擎（与 executor / engine_cache 干跑同形态）
fn production_engine() -> QuickJsEngine {
    QuickJsEngine::new(
        SandboxConfig::default()
            .with_allow_script_run(true)
            .with_memory_limit(64 * 1024 * 1024),
    )
    .expect("生产同源引擎创建失败")
}

fn book_source(url: &str) -> BookSource {
    BookSource {
        book_source_url: url.to_string(),
        book_source_name: "批37 setup cache 回归源".to_string(),
        ..BookSource::default()
    }
}

/// 建引擎并执行**生产 setup 脚本**（书源规则 JS 实际可见的 `cache` 对象）
fn engine_with_book_setup(source: &BookSource) -> QuickJsEngine {
    let engine = production_engine();
    let setup = book_source_js_setup_script(source, &HashMap::new(), None, None)
        .expect("setup 脚本生成失败");
    with_current_source_tag(&source.book_source_url, || engine.eval(&setup))
        .expect("setup eval 失败（setup 脚本本身回归）");
    engine
}

/// 在书源上下文内执行规则 JS（与 QuickJsExecutor 同款 tag 护栏）
fn eval_as(engine: &QuickJsEngine, tag: &str, code: &str) -> String {
    with_current_source_tag(tag, || engine.eval(code))
        .unwrap_or_else(|e| panic!("eval 失败: {e}\n脚本: {code}"))
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

fn js_str(value: &str) -> String {
    serde_json::to_string(value).expect("JS 字符串序列化失败")
}

/// 回环 HTTP 服务：按路径返回固定内容，并统计命中次数。
fn spawn_loopback(hits: Arc<std::sync::Mutex<HashMap<String, usize>>>) -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
    let addr = listener.local_addr().expect("local_addr");
    std::thread::spawn(move || {
        for stream in listener.incoming().take(16) {
            let Ok(mut sock) = stream else { continue };
            let path = read_request_path(&mut sock);
            {
                let mut map = hits.lock().unwrap();
                *map.entry(path.clone()).or_insert(0) += 1;
            }
            let resp = match path.as_str() {
                "/a.jpg" => response(200, "image/jpeg", b"COVER-A-CONTENT"),
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

// ---------------------------------------------------------------------------
// 1. 生产路径端到端：setup 引擎上 cacheFile → cache.get(md5(url)) 读回
// ---------------------------------------------------------------------------

/// 设备实测同款用例：修复前 `cache.get` 为 null（规则 JS 的 cache 是变量表
/// 镜像），`typeof cache.putFile` 为 undefined。修复后必须与裸引擎
/// `file_api_sandbox.rs` 同一读回契约，且值等于 `downloadFile` 的相对名。
#[test]
fn setup_engine_cache_get_reads_back_cache_file_mapping() {
    let hits = Arc::new(std::sync::Mutex::new(HashMap::new()));
    let addr = spawn_loopback(hits.clone());
    let url = format!("http://{addr}/a.jpg");
    let source = book_source("https://cap37readback.example.com");
    let engine = engine_with_book_setup(&source);

    let script = format!(
        r#"
        var u = {u};
        var key = java.md5Encode16(u);
        var content = java.cacheFile(u);
        var mapped = cache.get(key);
        var downloaded = java.downloadFile(u);
        var text = (mapped === null || mapped === undefined) ? '[MISS]' : java.readTxtFile(mapped);
        [String(content), String(mapped), String(downloaded), String(text),
         typeof cache.putFile, typeof cache.getFile, typeof cache.remove].join('|')
        "#,
        u = js_str(&url)
    );
    let raw = eval_as(&engine, &source.book_source_url, &script);
    let parts: Vec<&str> = raw.split('|').collect();
    assert_eq!(parts.len(), 7, "readback = {raw}");

    // 载入内容正常（证明请求与落盘本身没坏）
    assert_eq!(parts[0], "COVER-A-CONTENT", "cacheFile 返回内容");
    // 核心 RED 判据：修复前 mapped = "null"。
    assert_eq!(
        parts[1], parts[2],
        "cache.get(md5Encode16(url)) 必须等于 downloadFile(url) 的相对名（修复前为 null）: {raw}"
    );
    assert_eq!(
        parts[3], "COVER-A-CONTENT",
        "readTxtFile(映射值) 应读回内容"
    );
    // 宿主 cache_store 面（修复前均 undefined）
    assert_eq!(parts[4], "function", "cache.putFile 必须是宿主实现");
    assert_eq!(parts[5], "function", "cache.getFile 必须是宿主实现");
    assert_eq!(parts[6], "function", "cache.remove 兼容别名应存在");

    // 收尾：删缓存键与沙箱文件
    let relative = parts[2].to_string();
    assert!(
        !relative.contains('/') && !relative.contains('\\'),
        "相对名不得含路径分隔符: {relative}"
    );
    let key = legado_js::host_api::encoding::md5_encode_16(&url);
    with_current_source_tag(&source.book_source_url, || {
        engine
            .eval(&format!("cache.delete({})", js_str(&key)))
            .unwrap();
        let base = legado_js::host_api::file_utils::default_sandbox_root();
        let _ = std::fs::remove_file(base.join(&relative));
    });
}

// ---------------------------------------------------------------------------
// 2. TTL / putFile / 持久化：全部走宿主 cache_store
// ---------------------------------------------------------------------------

/// `cache.put(k, v, 1)` 的 saveTime 必须生效（修复前变量表镜像忽略 TTL，
/// 值永不过期）。
#[test]
fn setup_engine_cache_put_honors_save_time() {
    let source = book_source("https://cap37ttl.example.com");
    let engine = engine_with_book_setup(&source);
    let key = unique("cap37ttl");
    let key_js = js_str(&key);

    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("cache.put({key_js}, 'ttl-value', 1); String(cache.get({key_js}))")
        ),
        "ttl-value",
        "TTL 生效期内应命中"
    );
    std::thread::sleep(std::time::Duration::from_millis(1150));
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "null",
        "saveTime=1 秒过期后 cache.get 必须为 null（修复前永不过期）"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.get({key_js}, true))")
        ),
        "null",
        "onlyDisk 读同样过期"
    );
    eval_as(
        &engine,
        &source.book_source_url,
        &format!("cache.delete({key_js})"),
    );
}

/// `cache.putFile/getFile` 必须是宿主的纯磁盘 API（修复前 undefined）。
#[test]
fn setup_engine_cache_put_file_is_available() {
    let source = book_source("https://cap37file.example.com");
    let engine = engine_with_book_setup(&source);
    let key = unique("cap37file");
    let key_js = js_str(&key);

    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.putFile({key_js}, 'file-value'))")
        ),
        "true",
        "putFile 应写入成功"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.getFile({key_js}))")
        ),
        "file-value",
        "getFile 应读回纯磁盘值"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "null",
        "putFile 不进入普通 cache 键空间"
    );
    eval_as(
        &engine,
        &source.book_source_url,
        &format!("cache.delete({key_js})"),
    );
}

/// P2-1：`cache.putFile(k, v, saveTime)` 的第三参必须生效（修复前被静默
/// 丢弃、值永不过期）；缺省 saveTime 与 `saveTime = 0` 均为永久。
#[test]
fn setup_engine_cache_put_file_honors_save_time() {
    let source = book_source("https://cap37filettl.example.com");
    let engine = engine_with_book_setup(&source);
    let ttl = js_str(&unique("cap37filettl"));
    let perm = js_str(&unique("cap37fileperm"));
    let noarg = js_str(&unique("cap37filenoarg"));
    let rewrite = js_str(&unique("cap37filerewrite"));

    // 三参 TTL：生效期内可读
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.putFile({ttl}, 'ttl-file', 1))")
        ),
        "true",
        "putFile 带 saveTime 应写入成功"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.getFile({ttl}))")
        ),
        "ttl-file",
        "TTL 生效期内 getFile 应命中"
    );

    // 缺省 saveTime（两参）与 saveTime=0 均按永久处理
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.putFile({noarg}, 'noarg-file'))")
        ),
        "true"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.putFile({perm}, 'perm-file', 0))")
        ),
        "true"
    );

    // 同键 TTL → 永久重写：旧 deadline 必须清除，否则新值会被提前判过期
    eval_as(
        &engine,
        &source.book_source_url,
        &format!("cache.putFile({rewrite}, 'first', 1)"),
    );
    eval_as(
        &engine,
        &source.book_source_url,
        &format!("cache.putFile({rewrite}, 'second')"),
    );

    std::thread::sleep(std::time::Duration::from_millis(1150));

    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.getFile({ttl}))")
        ),
        "null",
        "saveTime=1 秒过期后 getFile 必须为 null（修复前永不过期）"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.getFile({noarg}))")
        ),
        "noarg-file",
        "缺省 saveTime 必须按永久处理"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.getFile({perm}))")
        ),
        "perm-file",
        "saveTime=0 必须按永久处理"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.getFile({rewrite}))")
        ),
        "second",
        "永久重写后旧 TTL deadline 不得生效"
    );

    for key in [&ttl, &perm, &noarg, &rewrite] {
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("cache.delete({key})"),
        );
    }
}

/// `cache.put` 的值必须落磁盘：清掉内存层与变量表（模拟进程重启）后，
/// 新引擎仍能从 cache_store 磁盘层读回。修复前值只在变量表，清掉即丢。
#[test]
fn setup_engine_cache_put_persists_after_memory_reset() {
    let source = book_source("https://cap37persist.example.com");
    let engine = engine_with_book_setup(&source);
    let key = unique("cap37persist");
    let key_js = js_str(&key);

    eval_as(
        &engine,
        &source.book_source_url,
        &format!("cache.put({key_js}, 'persisted-value')"),
    );

    // 模拟重启：内存 LRU 与变量表清掉，磁盘 cache 目录保留
    cache_store::delete_memory(&key);
    variable_store::remove_variable(&key).expect("变量表清理");

    let engine2 = engine_with_book_setup(&source);
    assert_eq!(
        eval_as(
            &engine2,
            &source.book_source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "persisted-value",
        "磁盘缓存应在内存/变量表清空后仍可读回（持久化）"
    );
    eval_as(
        &engine2,
        &source.book_source_url,
        &format!("cache.delete({key_js})"),
    );
}

/// `cache.remove`（setup 旧镜像的兼容别名）必须删除同一 cache_store 键，
/// 使 put/remove/get 同源。
#[test]
fn setup_engine_cache_remove_shares_put_key_space() {
    let source = book_source("https://cap37remove.example.com");
    let engine = engine_with_book_setup(&source);
    let key = unique("cap37remove");
    let key_js = js_str(&key);

    eval_as(
        &engine,
        &source.book_source_url,
        &format!("cache.put({key_js}, 'remove-me')"),
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "remove-me"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.remove({key_js}))")
        ),
        "true"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "null",
        "remove 后 get 必须 miss（与 put 同键空间）"
    );
}

/// 语料 #25：`cache.dev_id` 属性式读写仍可用，且与 `cache.get('dev_id')`
/// 同一存储（守卫后 dev_id 单独挂到宿主 cache 上，不得因不覆盖而丢失）。
#[test]
fn setup_engine_cache_dev_id_still_roundtrips() {
    let source = book_source("https://cap37devid.example.com");
    let engine = engine_with_book_setup(&source);

    eval_as(&engine, &source.book_source_url, "cache.delete('dev_id')");
    assert_eq!(
        eval_as(&engine, &source.book_source_url, "cache.dev_id"),
        "null",
        "未写入前为 null"
    );
    eval_as(
        &engine,
        &source.book_source_url,
        "cache.dev_id = 'cap37-dev-0001'",
    );
    assert_eq!(
        eval_as(&engine, &source.book_source_url, "cache.dev_id"),
        "cap37-dev-0001",
        "属性式读回"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            "String(cache.get('dev_id'))"
        ),
        "cap37-dev-0001",
        "dev_id 与 cache.get/put 同一存储"
    );
    // P3-2：经别名访问时 getter/setter 以接收者（this）为准，读写不漂移
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            "var alias = cache; alias.dev_id = 'cap37-dev-0002'; String(cache.dev_id)"
        ),
        "cap37-dev-0002",
        "别名写入后本体读回（this 接收者语义）"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            "String(cache.get('dev_id'))"
        ),
        "cap37-dev-0002",
        "别名写入仍落同一 cache_store 键"
    );
    eval_as(&engine, &source.book_source_url, "cache.delete('dev_id')");
}

/// P3-2：`dev_id` 挂载用 own-property 判定——自定义引擎 cache 的原型链上
/// 已有同名属性时仍须为本对象挂 own 属性（不接受不可控的原型值）。
#[test]
fn setup_engine_dev_id_mounts_own_property_over_prototype() {
    let source = book_source("https://cap37devidproto.example.com");
    let engine = production_engine();
    // 预置自定义引擎 cache：原型链带 dev_id；实例 get/put 落私有 store
    engine
        .eval(
            r#"
            (function () {
              var store = {};
              var proto = { dev_id: 'proto-value' };
              var custom = Object.create(proto);
              custom.get = function (k) {
                return Object.prototype.hasOwnProperty.call(store, k) ? store[k] : null;
              };
              custom.put = function (k, v) { store[k] = String(v); };
              globalThis.cache = custom;
            })();
            "#,
        )
        .expect("预置自定义 cache 失败");
    let setup = book_source_js_setup_script(&source, &HashMap::new(), None, None)
        .expect("setup 脚本生成失败");
    with_current_source_tag(&source.book_source_url, || engine.eval(&setup))
        .expect("setup eval 失败");

    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            "String(Object.prototype.hasOwnProperty.call(cache, 'dev_id'))"
        ),
        "true",
        "原型链同名属性不得阻止 own 属性挂载"
    );
    assert_eq!(
        eval_as(&engine, &source.book_source_url, "String(cache.dev_id)"),
        "null",
        "own getter 读自定义 store（空）而非原型值"
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.book_source_url,
            "cache.dev_id = 'own-value'; String(cache.get('dev_id'))"
        ),
        "own-value",
        "own setter 写入接收者的 cache.put"
    );
}

// ---------------------------------------------------------------------------
// 3. RSS 分支不回归（批21c P2-7 守卫保持）
// ---------------------------------------------------------------------------

/// RSS setup 的 cache 仍是宿主 cache_store（不是变量表回落对象：
/// `putFile` 存在即可区分），读写/删除同源。
#[test]
fn rss_setup_cache_stays_on_host_store() {
    let source = RssSource {
        source_url: "https://cap37rss.example.com/feed".to_string(),
        source_name: "批37 RSS 回归源".to_string(),
        ..RssSource::default()
    };
    let engine = production_engine();
    let setup = rss_source_js_setup_script(&source, None, None).expect("RSS setup 生成失败");
    with_current_source_tag(&source.source_url, || engine.eval(&setup)).expect("RSS setup eval");

    assert_eq!(
        eval_as(&engine, &source.source_url, "typeof cache.putFile"),
        "function",
        "RSS cache 应是宿主实现（回落对象无 putFile）"
    );
    let key = unique("cap37rss");
    let key_js = js_str(&key);
    eval_as(
        &engine,
        &source.source_url,
        &format!("cache.put({key_js}, 'rss-value')"),
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "rss-value"
    );
    eval_as(
        &engine,
        &source.source_url,
        &format!("cache.remove({key_js})"),
    );
    assert_eq!(
        eval_as(
            &engine,
            &source.source_url,
            &format!("String(cache.get({key_js}))")
        ),
        "null",
        "RSS remove 后 miss"
    );
}
