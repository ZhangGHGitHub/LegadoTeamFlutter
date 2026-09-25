//! 远程 jsLib 加载器（能力对账第一批 · cap 3）
//!
//! 语料实证（#463 月色书屋 / #658 / #674 / #915）：书源 `jsLib` 字段支持
//! **URL 映射形态**——`{"crypto": "https://cdn.bootcss.com/crypto-js/3.1.9-1/crypto-js.min.js"}`
//! （键为导出名，值为远程 JS 文件 URL）。
//!
//! 上游语义（`SharedJsScope.kt:103-280`）：URL 值经网络拉取后 eval 进引擎，
//! 进程内以 `md5(url)` 键缓存续命（aCache 内存缓存，重启丢失）；拉取失败
//! 抛 `NoStackTraceException("下载jsLib-${value}失败")`；非 URL 值按原始 JS
//! 直接 eval。
//!
//! 本实现（对齐 + 降级差异已文档化）：
//! - **URL 值** → 经共享客户端 [`network::shared_client_for_url`] 拉取
//!   （回环 URL 走 `no_proxy` 直连池，生产池不变；逐请求 30s 超时；内容
//!   上限 2MB）→ 进程级 LRU 缓存（`md5(url)` 键，容量 64，**无 TTL**，
//!   进程重启丢失，对齐上游 aCache 内存语义）→ 返回拼接脚本由调用方 eval；
//! - **拉取失败** → 可读错误（上游「下载jsLib-{url}失败」措辞）+
//!   [`capability_ledger::record_jslib_load_failure`] 台账登记，**跳过该
//!   条继续其余条目**（降级继续，仅依赖该 jsLib 的规则受影响——与上游
//!   的「整源抛错」差异为有意降级，见下方 `resolve_js_lib_url_map` 文档）；
//! - **非 URL 值** → 原样追加（上游非 URL 值即原始 JS，eval 行为一致）；
//! - **注入面**：fetcher 为 [`JsLibFetcher`] 闭包（`Fn(&str) ->
//!   Result<String, String> + Send + Sync`），生产传
//!   [`default_js_lib_fetcher`]，测试注入本地回环 mock（无真实网络）；
//!   加载器本身不递归（拉取内容仅拼接为脚本，不二次解析 URL 映射）。

#![cfg(feature = "quickjs")]

use std::num::NonZeroUsize;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use lru::LruCache;

use crate::host_api::capability_ledger;
use crate::host_api::encoding;
use crate::host_api::network::shared_client_for_url;
use crate::host_api::runtime_bridge::block_on;
use legado_net::LegadoRequest;

/// jsLib 拉取超时（逐请求，覆盖共享客户端池级 60s 默认）
const JSLIB_FETCH_TIMEOUT: Duration = Duration::from_millis(30_000);

/// jsLib 内容上限（2MB）：超限视为异常资源，按失败处理
const MAX_JSLIB_CONTENT_LEN: usize = 2 * 1024 * 1024;

/// 进程级 jsLib 内容缓存容量（按 `md5(url)` 键，无 TTL）
const JSLIB_CACHE_CAPACITY: usize = 64;

/// 可注入的 jsLib 拉取器：`url → 内容`；错误串须可读（进台账与日志）
pub type JsLibFetcher = dyn Fn(&str) -> Result<String, String> + Send + Sync;

/// 解析 URL 映射形态的 jsLib（`{"crypto":"https://…/crypto-js.min.js"}`）。
///
/// 输入 trim 后以 `{` 开头且能整体解析为「字符串 → 字符串」JSON 对象时
/// 返回 `Some(entries)`（保序，serde `Map` 即插入序）；其余形态（原始 JS
/// 脚本 / 含非字符串值的对象表达式等）返回 `None`——调用方回退既有
/// 原始 JS eval 级联，行为与 cap 3 引入前一致。
pub fn parse_js_lib_url_map(js_lib: &str) -> Option<Vec<(String, String)>> {
    let t = js_lib.trim();
    if !t.starts_with('{') {
        return None;
    }
    // 经 Value 解析（serde_json 仅对 Map<String, Value> 实现反序列化）：
    // 对象且全部值为字符串才视为 URL 映射；`as_object` 保插入序
    let v: serde_json::Value = serde_json::from_str(t).ok()?;
    let obj = v.as_object()?;
    let mut out = Vec::with_capacity(obj.len());
    for (k, val) in obj {
        let s = val.as_str()?;
        out.push((k.clone(), s.to_string()));
    }
    Some(out)
}

/// 进程级 jsLib 内容缓存（`md5(url)` 键，无 TTL；进程重启即失，
/// 对齐上游 aCache 内存缓存语义）
fn jslib_cache() -> &'static Mutex<LruCache<String, String>> {
    static CACHE: OnceLock<Mutex<LruCache<String, String>>> = OnceLock::new();
    CACHE.get_or_init(|| {
        let cap = NonZeroUsize::new(JSLIB_CACHE_CAPACITY).unwrap_or(NonZeroUsize::new(16).unwrap());
        Mutex::new(LruCache::new(cap))
    })
}

/// 测试用：清空进程级 jsLib 内容缓存（缓存为进程全局，跨测试并行安全须
/// 先清再断言命中计数）
#[doc(hidden)]
pub fn reset_jslib_cache_for_test() {
    if let Ok(mut c) = jslib_cache().lock() {
        c.clear();
    }
}

/// 生产默认 fetcher：共享客户端拉取（回环池/生产池按 URL 分流），
/// 逐请求 [`JSLIB_FETCH_TIMEOUT`]，非 2xx 与 [`MAX_JSLIB_CONTENT_LEN`]
/// 超限均按失败返回（错误串带上游「下载jsLib-{url}失败」措辞）。
///
/// 注：内容上限是**生产 fetcher 边界**——注入 fetcher（测试）按可信内容
/// 处理，不再复检尺寸。
pub fn default_js_lib_fetcher(url: &str) -> Result<String, String> {
    let client = shared_client_for_url(url).map_err(|e| format!("下载jsLib-{url}失败: {e}"))?;
    let mut req = LegadoRequest::get(url);
    req.timeout = Some(JSLIB_FETCH_TIMEOUT);
    let resp = block_on(client.send(&req)).map_err(|e| format!("下载jsLib-{url}失败: {e}"))?;
    if !resp.is_success() {
        return Err(format!("下载jsLib-{url}失败: HTTP {}", resp.status));
    }
    if resp.body.len() > MAX_JSLIB_CONTENT_LEN {
        return Err(format!(
            "下载jsLib-{url}失败: 内容 {} 字节超过 {MAX_JSLIB_CONTENT_LEN} 上限",
            resp.body.len()
        ));
    }
    Ok(resp.body)
}

/// 解析 URL 映射 jsLib 为可 eval 脚本。
///
/// 逐条目：
/// - `http(s)://` 值 → `fetch(url)`（进程缓存命中则不拉取）；失败 →
///   记日志 + [`capability_ledger::record_jslib_load_failure`]（上游措辞
///   由 fetcher 错误串携带）+ **跳过该条**（降级继续：仅依赖该 jsLib 的
///   规则受影响，整源规则继续求值——与上游整源抛错的差异为有意降级，
///   对齐本仓库「失败记台账不炸源」的既有失败路径）；
/// - 其余值 → 原样追加（上游非 URL 值即原始 JS）。
///
/// 至少一条可解析返回 `Some(拼接脚本)`（各段间以换行分隔，段首附
/// `// {键名}` 注释便于排障）；全部失败/空映射返回 `None`（调用方按
/// 未提供 jsLib 处理）。
pub fn resolve_js_lib_url_map(
    js_lib: &str,
    source_tag: &str,
    fetch: &JsLibFetcher,
) -> Option<String> {
    let entries = parse_js_lib_url_map(js_lib)?;
    let mut parts: Vec<String> = Vec::new();
    for (name, value) in entries {
        let v = value.trim();
        if !(v.starts_with("http://") || v.starts_with("https://")) {
            // 非 URL 值：上游直接 eval 的原始 JS
            if !v.is_empty() {
                parts.push(format!("// {name}\n{v}"));
            }
            continue;
        }
        // 进程缓存（md5(url) 键，无 TTL）：命中不重拉——缓存属加载器
        // 职责，注入 fetcher 保持纯函数（测试可直接断言拉取计数）
        let key = encoding::md5_encode(v);
        let cached = jslib_cache()
            .lock()
            .ok()
            .and_then(|mut c| c.get(&key).cloned());
        match cached {
            Some(body) => parts.push(format!("// {name}\n{body}")),
            None => match (fetch)(v) {
                Ok(body) => {
                    if let Ok(mut c) = jslib_cache().lock() {
                        c.put(key, body.clone());
                    }
                    parts.push(format!("// {name}\n{body}"));
                }
                Err(e) => {
                    eprintln!(
                        "[jslib_loader] {source_tag}: {e}（降级继续，仅依赖 jsLib {name} 的规则受影响）"
                    );
                    capability_ledger::record_jslib_load_failure(source_tag, &e);
                }
            },
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::JsEngine;
    use crate::sandbox::SandboxConfig;
    use crate::QuickJsEngine;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// 本地回环 jsLib mock：固定返回一段 JS 文件（`Connection: close`，
    /// 逐请求新连接；accept 计数用于「缓存命中不重拉」断言）。
    fn spawn_jslib_mock(body: &str, counter: &Arc<AtomicUsize>) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let body = body.to_string();
        let counter = Arc::clone(counter);
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(Duration::from_secs(10)));
                // 读到请求头结束即响应（jsLib 仅 GET，无 body）
                let mut buf = [0u8; 1024];
                let mut req = Vec::new();
                loop {
                    match sock.read(&mut buf) {
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
                counter.fetch_add(1, Ordering::SeqCst);
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// parse：URL 映射 / 原始 JS / 非字符串值 三形态
    #[test]
    fn test_parse_js_lib_url_map() {
        let m = parse_js_lib_url_map(
            r#"{"crypto":"https://cdn.bootcss.com/crypto-js/3.1.9-1/crypto-js.min.js"}"#,
        )
        .expect("URL 映射应解析成功");
        assert_eq!(m.len(), 1);
        assert_eq!(m[0].0, "crypto");
        assert!(m[0].1.starts_with("https://"));

        assert!(
            parse_js_lib_url_map("var x = 1;").is_none(),
            "原始 JS 应 None"
        );
        assert!(
            parse_js_lib_url_map("  \n { \"a\" : \"http://x.y/z.js\" }  ").is_some(),
            "前后空白应容忍"
        );
        assert!(
            parse_js_lib_url_map(r#"{"a":1}"#).is_none(),
            "非字符串值不是 URL 映射（回退原始 JS 路径）"
        );
    }

    /// e2e（回环 mock，无真实网络）：URL 映射拉取 → eval → 导出可用；
    /// 第二次解析同 URL 命中进程缓存（mock 计数不变）
    #[test]
    fn test_jslib_url_map_fetch_eval_and_cache() {
        // 毒锁恢复（并行测试中另一用例 panic 持锁不致整组报废）
        let _ledger = capability_ledger::LEDGER_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        capability_ledger::reset_jslib_load_failures();
        reset_jslib_cache_for_test();

        let counter = Arc::new(AtomicUsize::new(0));
        let body =
            "var crypto = { version: '3.1.9', hexLen: function(s) { return String(s).length; } };";
        let addr = spawn_jslib_mock(body, &counter);
        let jslib = format!(r#"{{"crypto":"http://{addr}/crypto.js"}}"#);

        let script = resolve_js_lib_url_map(&jslib, "capb1_jslib", &default_js_lib_fetcher)
            .expect("URL 映射 jsLib 解析应成功");
        assert_eq!(counter.load(Ordering::SeqCst), 1, "首次应拉取一次");

        // eval 进裸引擎，导出可用
        let engine = QuickJsEngine::new(SandboxConfig::default()).expect("引擎创建");
        engine.eval(&script).expect("jsLib eval 应成功");
        assert_eq!(engine.eval("typeof crypto").expect("typeof"), "object");
        assert_eq!(engine.eval("crypto.hexLen('abcd')").expect("调用"), "4");

        // 缓存命中：同 URL 二次解析不重拉
        let script2 = resolve_js_lib_url_map(&jslib, "capb1_jslib", &default_js_lib_fetcher)
            .expect("缓存命中后解析仍应成功");
        assert_eq!(script, script2);
        assert_eq!(counter.load(Ordering::SeqCst), 1, "缓存命中不得重拉");
    }

    /// 失败语义：单条拉取失败 → 台账登记（上游措辞）+ 跳过该条，
    /// 非 URL 条目照常拼接（整源不炸）
    #[test]
    fn test_jslib_fetch_failure_ledger_and_partial() {
        let _ledger = capability_ledger::LEDGER_TEST_LOCK
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        capability_ledger::reset_jslib_load_failures();

        // 回环 127.0.0.1:1 必拒绝连接（无监听），不发真实外网请求
        let jslib = r#"{"bad":"http://127.0.0.1:1/never.js","good":"var ok42 = 42;"}"#;
        let script = resolve_js_lib_url_map(jslib, "capb1_jslib_fail", &default_js_lib_fetcher)
            .expect("单条失败不得阻断其余条目（降级继续）");
        assert!(
            script.contains("var ok42 = 42;"),
            "非 URL 条目应原样拼接: {script}"
        );
        assert!(
            !script.contains("never.js"),
            "失败 URL 不得进入解析后脚本: {script}"
        );
        let err = capability_ledger::last_jslib_error("capb1_jslib_fail").expect("失败必须记台账");
        assert!(err.contains("下载jsLib-"), "台账措辞须对齐上游: {err}");
    }
}
