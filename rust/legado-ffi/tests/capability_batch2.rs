//! 书源引擎能力对账 · 批次 2（3b-3/3b-4/3b-5）e2e 测试
//!
//! 覆盖：
//!
//! - **3b-3 cookie 对象 8 方法**（上游 `CookieStore.kt` 全集；语料 #57 爱丽丝书屋
//!   `cookie.mapToCookie/replaceCookie`）：补齐 replaceCookie（现存域 cookie ∪
//!   新串，新值覆盖）/ cookieToMap（`;` 拆段 → 对象）/ mapToCookie（空 → null）。
//! - **3b-3 `cache.dev_id`**（语料 #25 听小说APP 设备标识）：属性式 getter/setter，
//!   后端全局 cache 存储永久键，未写入前读 null。
//! - **3b-4 `java.url` / `java.headerMap.put`**（语料 #286 刚够小说网；上游
//!   `AnalyzeUrl.evalJS` `bindings["java"] = this` 口径）：URL 选项 `{"js": ...}`
//!   窗口内 java.url = 已解析请求 URL（`java.ajax(java.url)` 可拉当前页）、
//!   headerMap.put 落入本次请求头；source 窗口回退 sourceUrl（上游
//!   `BaseSource.evalJS` java=source 的 getUrl() 语义）。
//! - **3b-5 `Packages.android.text.TextUtils.isEmpty`**（语料 #135 阅文；Kotlin
//!   语义 `null || length == 0`）。
//!
//! 引擎形态与生产同源（setup 脚本经 `book_source_js_setup_script` 生成）；
//! 全部离线自洽（回环 mock / 内存夹具，零真实联网）。
//!
//! 运行：`cargo test -p legado-ffi --features quickjs --test capability_batch2`

#![cfg(feature = "quickjs")]

use legado_ffi::api::source_js_bindings::book_source_js_setup_script;
use legado_ffi::js_executor::build_search_url_with_setup;
use legado_ffi::legado_core::models::BookSource;
use legado_ffi::legado_js::engine::JsEngine;
use legado_ffi::legado_js::sandbox::SandboxConfig;
use legado_ffi::legado_js::QuickJsEngine;
use legado_ffi::legado_parser::analyze_url::{
    current_url, set_current_url, take_pending_request_headers,
};

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

/// 建引擎 + 应用书源 setup 脚本（cookie / cache / java 全局即书源实际可见形态）
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
// 3b-3：cookie 对象 8 方法（上游 CookieStore 全集）
// ---------------------------------------------------------------------------

/// 面存在性：getCookie/getKey/setCookie/clearCookies/removeCookie（原有 5）
/// + replaceCookie/cookieToMap/mapToCookie（3b-3 补齐 3）= 上游 8 方法
#[test]
fn test_cookie_object_eight_methods() {
    let (engine, _s) = engine_with_source("https://capb2c1.example.com/", "cap2 cookie 面");
    for m in [
        "getCookie",
        "getKey",
        "setCookie",
        "clearCookies",
        "removeCookie",
        "replaceCookie",
        "cookieToMap",
        "mapToCookie",
    ] {
        assert_eq!(
            engine
                .eval(&format!("typeof cookie.{m}"))
                .expect("eval 失败"),
            "function",
            "cookie.{m} 应为函数（上游 CookieStore 全集）"
        );
    }
}

/// cookie.replaceCookie / cookieToMap / mapToCookie 走 setup 脚本对象全链路
#[test]
fn test_cookie_replace_map_roundtrip_e2e() {
    let (engine, _s) = engine_with_source("https://capb2c2.example.com/", "cap2 cookie 往返");

    engine
        .eval("cookie.setCookie('https://capb2c2.example.com/', 'old=1; keep=2')")
        .unwrap();
    // replaceCookie：现存域 cookie ∪ 新串（新值覆盖、旧键保留）
    engine
        .eval("cookie.replaceCookie('https://capb2c2.example.com/', 'old=9; new=x')")
        .unwrap();
    let full = engine
        .eval("cookie.getCookie('https://capb2c2.example.com/')")
        .unwrap();
    assert!(full.contains("old=9"), "新值覆盖: {full}");
    assert!(full.contains("keep=2"), "旧键保留: {full}");
    assert!(full.contains("new=x"), "新键写入: {full}");

    // cookieToMap → JS 对象（键下标访问 + 同名键后值覆盖）
    let x = engine
        .eval("var m = cookie.cookieToMap('a=1; b=2; a=3'); String(m.a) + '|' + String(m.b)")
        .unwrap();
    assert_eq!(x, "3|2", "cookieToMap 还原对象且同名键覆盖");

    // mapToCookie：对象 → 'k=v; …'；null/空表 → null（eval 字符串化为 "null"）
    let joined = engine.eval("cookie.mapToCookie({p: '1', q: '2'})").unwrap();
    assert_eq!(joined, "p=1; q=2");
    assert_eq!(
        engine.eval("cookie.mapToCookie(null)").unwrap(),
        "null",
        "上游 mapToCookie 空参返回 null"
    );
    assert_eq!(
        engine.eval("cookie.mapToCookie({})").unwrap(),
        "null",
        "空表返回 null（上游 mapToCookie 语义）"
    );

    // 收尾
    engine
        .eval("cookie.clearCookies('https://capb2c2.example.com/')")
        .unwrap();
}

// ---------------------------------------------------------------------------
// 3b-3：cache.dev_id（设备标识，属性式 getter/setter）
// ---------------------------------------------------------------------------

#[test]
fn test_cache_dev_id_roundtrip() {
    let (engine, _s) = engine_with_source("https://capb2d1.example.com/", "cap2 dev_id");
    // 未写入前读 null（eval 结果字符串化为 "null"，batch1 同口径）
    assert_eq!(
        engine.eval("cache.dev_id").unwrap(),
        "null",
        "未写入必须为 null"
    );
    // 写入（属性式 set）→ 读回（属性式 get，后端 put/get 永久键）
    engine
        .eval("cache.dev_id = 'capb2-dev-0001'")
        .expect("dev_id 写入失败");
    assert_eq!(
        engine.eval("cache.dev_id").unwrap(),
        "capb2-dev-0001",
        "dev_id 属性式读回（后端 saveTime=0 永久键）"
    );
    // 底层经全局 cache 存储可读（与 cache.get/put 同命名空间）
    assert_eq!(
        engine.eval("String(get('dev_id'))").unwrap(),
        "capb2-dev-0001"
    );
    // 收尾
    engine.eval("removeVariable('dev_id')").unwrap();
}

// ---------------------------------------------------------------------------
// 3b-4：java.url / java.headerMap.put（上游 AnalyzeUrl 口径）
// ---------------------------------------------------------------------------

/// java.url getter：URL 规则窗口内 = 线程局部当前 URL；窗口外回退 sourceUrl
#[test]
fn test_java_url_getter_states() {
    let (engine, _s) = engine_with_source("https://capb2u1.example.com/", "cap2 java.url 状态机");

    // 状态机复位保险（防并行残留）：显式 None 后断言回退
    set_current_url(None);
    // 窗口外（parse_with_js 未运行 / 已复位）→ sourceUrl（上游 java=source 语义）
    assert_eq!(
        engine.eval("java.url").unwrap(),
        "https://capb2u1.example.com/",
        "source 窗口 java.url 回退 sourceUrl"
    );

    // URL 规则窗口（模拟 parse_with_js 置值）→ 当前请求 URL
    set_current_url(Some("https://capb2u1.example.com/s?k=1".into()));
    assert_eq!(
        engine.eval("java.url").unwrap(),
        "https://capb2u1.example.com/s?k=1",
        "URL 规则窗口 java.url = 当前请求 URL"
    );
    set_current_url(None);
}

/// java.headerMap.put：写入经线程局部收集器可取走（parse_with_js 收尾并入
/// AnalyzeUrl.headers，此处直接断言收集器）
#[test]
fn test_java_header_map_put_collects() {
    let (engine, _s) = engine_with_source("https://capb2h1.example.com/", "cap2 headerMap");
    assert_eq!(engine.eval("typeof java.headerMap").unwrap(), "object");
    engine
        .eval("java.headerMap.put('Cookie', 'is_human=1')")
        .unwrap();
    engine.eval("java.headerMap.put('X-T', 'v')").unwrap();
    let pending = take_pending_request_headers();
    assert_eq!(
        pending,
        vec![
            ("Cookie".to_string(), "is_human=1".to_string()),
            ("X-T".to_string(), "v".to_string()),
        ],
        "headerMap.put 顺序写入收集器"
    );
}

// ---------------------------------------------------------------------------
// 3b-5：Packages.android.text.TextUtils.isEmpty（Kotlin 语义）
// ---------------------------------------------------------------------------

#[test]
fn test_packages_text_utils_is_empty_e2e() {
    let (engine, _s) = engine_with_source("https://capb2t1.example.com/", "cap2 TextUtils");
    assert_eq!(
        engine
            .eval("Packages.android.text.TextUtils.isEmpty('')")
            .unwrap(),
        "true"
    );
    assert_eq!(
        engine
            .eval("Packages.android.text.TextUtils.isEmpty(null)")
            .unwrap(),
        "true"
    );
    assert_eq!(
        engine
            .eval("Packages.android.text.TextUtils.isEmpty('abc')")
            .unwrap(),
        "false"
    );
}

// ---------------------------------------------------------------------------
// 3b-4 全链路：#286 刚够小说网 searchUrl 选项 js（java.ajax(java.url) +
// headerMap.put 注入 Cookie），回环 mock 零真实联网
// ---------------------------------------------------------------------------

/// 本地回环 mock（batch1 同款：std TcpListener + 单连接，无真实网络；
/// 回环池 `no_proxy` 直连豁免代理）
fn spawn_html_mock(body: &str) -> std::net::SocketAddr {
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
                "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
                len = body.len(),
                body = body
            );
            let _ = std::io::Write::write_all(&mut sock, resp.as_bytes());
        }
    });
    addr
}

/// 语料 #286 形态全链路：选项 js 内 `java.ajax(java.url)` 拉当前搜索页抓
/// 防爬 cookie 值 → `java.headerMap.put('Cookie', …)` 注入请求头 → js 返回
/// java.url（恒等改写）。断言：java.url 在窗口内 = 已解析 URL；注入的
/// Cookie 落入 AnalyzeUrl.headers（fetch_page 组头即生效）。
#[test]
fn test_search_url_option_js_full_flow_e2e() {
    let body = r#"<html><script>var encryptedCookieValue = "abc123";</script></html>"#;
    let addr = spawn_html_mock(body);

    // 选项 js（JSON 转义交由 serde_json 处理）：对齐 #286 searchUrl 的 js 字段
    let js = r#"var v = java.ajax(java.url).match(/encryptedCookieValue = "([^"]+)"/)[1]; java.headerMap.put('Cookie', 'is_human=' + v); java.url"#;
    let option = serde_json::to_string(&serde_json::json!({ "js": js })).unwrap();
    let template =
        format!("http://{addr}/modules/search.php?searchkey={{{{key}}}}&type=articlename,{option}");

    let source = make_source("https://capb2f1.example.com/", "cap2 刚够形态");
    let setup = book_source_js_setup_script(&source).expect("setup 生成失败");
    let parsed = build_search_url_with_setup(
        &template,
        "kw",
        1,
        "https://capb2f1.example.com/",
        None,
        Some(setup),
    );

    let expected = format!("http://{addr}/modules/search.php?searchkey=kw&type=articlename");
    assert_eq!(
        parsed.url(),
        expected,
        "java.url 恒等改写：选项 js 窗口内 java.url 必须为已解析请求 URL"
    );
    assert_eq!(
        parsed.headers().get("Cookie").map(String::as_str),
        Some("is_human=abc123"),
        "headerMap.put 注入的 Cookie 必须落入本次请求头（防爬放行）"
    );
    // 状态机复位：parse_with_js 退出后无残留
    assert_eq!(current_url(), None);
    assert!(take_pending_request_headers().is_empty());
}
