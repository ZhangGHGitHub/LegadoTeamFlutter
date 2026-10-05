//! AnalyzeUrl 请求选项接线（HTTP P2-19 批3）：`followRedirects` / `retry`
//!
//! 上游语义（`app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt`
//! `getClient()` + `app/src/main/java/io/legado/app/help/http/OkHttpUtils.kt`
//! `newCallResponse`）：
//!
//! - `followRedirects == false`：本次请求改由**不跟随重定向**的派生客户端
//!   发送（上游 `buildRequestClient` 派生 OkHttpClient，连接池共享）；
//!   `true` / 缺省沿用现有共享客户端（跟随策略 `Policy::limited(20)` 不变）。
//! - `retry > 0`：响应**非 2xx 且非 3xx** 时重发，无退避、至多 `retry` 次
//!   （总尝试次数 = retry + 1）；2xx / 3xx 与传输错误立即返回/上抛。
//!   不得复用 `legado_net::retry::RetryExecutor`——后者是客户端配置级指数
//!   退避（且面向 I/O 错误），与 urlOption 的「响应码级即时重发」语义不等价。
//!
//! ## 覆盖范围（2026-10-01 批3 现状）
//!
//! 已接线（持 AnalyzeUrl 且经本模块发送，共享 followRedirects / retry 语义）：
//! - `web_book::RealBookSourceFetcher::fetch_page` 两分支（response_type/hex
//!   与普通正文，含 POST 派发）；
//! - `legado_ffi::api::search::search_single_source` 两分支（charset 原始字节
//!   与文本）；
//! - `legado_ffi::api::dict::fetch_body`（词典取体；封面 `searchCoverRules`
//!   经其复用）。
//!
//! 未接线（deferred，各自原因）：
//! - `legado_ffi::api::review_api` 三处段评/书评取数：发送 URL 是规则相对路径
//!   经 `AnalyzeUrl::get_absolute_url(chapter_url, _)` 改写后的 `final_url`，
//!   与 `analyze_url.url()` 可不同——需先为本模块 helper 增加 URL override
//!   参数，超出本批范围；
//! - `legado_ffi::api::explore_api::explore_books_async`：现状强制 GET（不看
//!   method），接线会顺带把 method 语义改为跟随 urlOption method，超本批；
//! - `web_book.rs:1017/:1060/:2772` 等裸 URL 直发点（`fetch_simple_cached` /
//!   `fetch_toc_page_optional` / 分页正文闭包）：不持 AnalyzeUrl，无 urlOption
//!   可消费，天然不属本汇聚点范围。
//!
//! ## 写侧 CookieJar 门控接线状态（批 2 尾批，2026-10-03）
//!
//! - `legado_ffi::api::dict_api::fetch_body`（`dict_api.rs:385`）及其复用方
//!   `cover_api`（契约 §2.4.8 `searchCoverRules`）：**已接线**——`fetch_body`
//!   新增 `cookie_jar_enabled: Option<bool>` 参数；封面规则按上游
//!   `BookCover.CoverRule.enabledCookieJar`（`BookCover.kt:215` 以 CoverRule
//!   作 `AnalyzeUrl(source = config)`，字段 :253 默认 false）传入；词典两处
//!   （`search_dict_rule` / 导入 `fetch_url_body`）恒 `None`——`DictRule` 无该
//!   字段，上游 `DictRule.search` 构造 `AnalyzeUrl` 亦不传 source。
//! - `legado_ffi::api::tts_speak_api::tts_speak`（`tts_speak_api.rs:74`）：
//!   **仍为残差**——上游 `HttpReadAloudService` 经 `AnalyzeUrl(source = httpTts)`
//!   门控写回，但本 FFI 入口仅接收 `engine_url`（不持 HttpTTS 对象/id），
//!   运行面 `legado_db::HttpTts` 亦未暴露 `enabledCookieJar` 列（列在 httpTTS
//!   表内、SELECT 不含）→ 无源上下文可判定，保持无标记；接线需先扩展 FFI
//!   入口签名（跨轨契约变更，未在本批范围）。
//!
//! ## data: URI 短路（P2-15，2026-10-06）
//!
//! 上游 `AnalyzeUrl.getByteArrayAwait`（AnalyzeUrl.kt:680-687）对 data: URI
//! 一律本地解码、不发请求；`getStrResponseAwait` 在 `type != null` 时返回
//! hex 编码正文（:442-444）。我方 `web_book::fetch_page` / `fetch_simple_cached`
//! / `dict_api` / `explore_api` 各自已有 data URI 分支，但**搜索路径
//! `search_single_source` 经本模块 `send_raw` 直发**，漏判空 mime 形态
//! `data:;base64,<b64>`（猫眼看书，实机 15 号 `builder error for url
//! (data:;base64,...)`——reqwest 不支持 data: 协议）。修复：`send_raw` /
//! `send_text` 入口统一短路本地解码（判定与解码仍由 `legado-parser`
//! `AnalyzeUrl::is_data_uri` / `get_byte_array_if_data_uri` 单一真源，
//! 空 mime 与原版 `^data:.*?;base64,(.*)` 同样命中）。

use std::collections::HashMap;
use std::future::Future;

use legado_core::{LegadoError, LegadoResult};
use legado_net::{LegadoClient, LegadoRawResponse, LegadoResponse};
use legado_parser::{AnalyzeUrl, RequestMethod};

/// 小写 hex 编码（对齐 Kotlin `HexUtil.encodeHexStr`；与
/// `web_book::hex_encode` 同实现，供 data: URI `type` 分支使用）
fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}

/// data: URI 本地解码（`None` = 非 data URI，调用方继续网络路径）
///
/// 单一真源 `legado-parser`：判定 `AnalyzeUrl::is_data_uri`、解码
/// `get_byte_array_if_data_uri`（空 mime `data:;base64,` 与原版
/// `^data:.*?;base64,(.*)` 同样命中）。正文口径：
/// - `urlOption.type` 非空 → hex 文本（上游 `getStrResponseAwait` 的
///   `type != null → HexUtil.encodeHexStr(getByteArrayAwait())`，AnalyzeUrl.kt:442-444）；
/// - 否则 → 解码原始字节（`send_raw` 无损；`send_text` 再按 lossy UTF-8 转文本）。
///
/// 解码失败维持 Internal（与 `web_book::fetch_page` 现状一致：非法 base64
/// 数据段报「data: URI 内容解码失败」，绝不退化为 reqwest builder error）。
fn data_uri_body(analyze_url: &AnalyzeUrl) -> Option<LegadoResult<Vec<u8>>> {
    if !analyze_url.is_data_uri() {
        return None;
    }
    let Some(bytes) = analyze_url.get_byte_array_if_data_uri() else {
        return Some(Err(LegadoError::Internal("data: URI 内容解码失败".into())));
    };
    let body = if analyze_url.response_type().is_some() {
        hex_encode(&bytes).into_bytes()
    } else {
        bytes
    };
    Some(Ok(body))
}

/// data: URI 的合成响应头（无网络响应，status 固定 200；headers 为空，
/// 交由调用方的四级解码兜底）
fn data_uri_headers() -> HashMap<String, String> {
    HashMap::new()
}

/// 响应是否已到「终态」（不再重发）：2xx 或 3xx
fn is_settled_status(status: u16) -> bool {
    (200..400).contains(&status)
}

/// 状态码提取（raw / text 两种响应形态共用重试循环）
trait StatusCode {
    fn status_code(&self) -> u16;
}

impl StatusCode for LegadoRawResponse {
    fn status_code(&self) -> u16 {
        self.status
    }
}

impl StatusCode for LegadoResponse {
    fn status_code(&self) -> u16 {
        self.status
    }
}

/// 发送并返回原始字节响应（无损，供 charset 检测 / hex 等场景）
pub async fn send_raw(
    client: &LegadoClient,
    analyze_url: &AnalyzeUrl,
    headers: Option<HashMap<String, String>>,
) -> LegadoResult<LegadoRawResponse> {
    // data: URI 短路：本地解码、绝不进 reqwest（P2-15，实机 builder error）
    if let Some(result) = data_uri_body(analyze_url) {
        return Ok(LegadoRawResponse {
            status: 200,
            headers: data_uri_headers(),
            body: result?,
            url: analyze_url.url().to_string(),
        });
    }
    let url = analyze_url.url().to_string();
    let body = analyze_url.request_body().to_string();
    let is_post = *analyze_url.method() == RequestMethod::Post;
    send_with_options(client, analyze_url, move |effective| {
        let url = url.clone();
        let body = body.clone();
        let headers = headers.clone();
        async move {
            if is_post {
                effective.post_raw(&url, &body, headers).await
            } else {
                // 现状口径：非 POST（含 HEAD/GET）一律按 GET 发送，与既有
                // 调用点逐字一致（HEAD 支持不在本批范围）
                effective.get_raw(&url, headers).await
            }
        }
    })
    .await
}

/// 发送并返回文本响应（沿用 reqwest 文本解码语义，供搜索/发现/词典等场景）
pub async fn send_text(
    client: &LegadoClient,
    analyze_url: &AnalyzeUrl,
    headers: Option<HashMap<String, String>>,
) -> LegadoResult<LegadoResponse> {
    // data: URI 短路：本地解码、绝不进 reqwest（P2-15，实机 builder error）
    if let Some(result) = data_uri_body(analyze_url) {
        return Ok(LegadoResponse {
            status: 200,
            headers: data_uri_headers(),
            body: String::from_utf8_lossy(&result?).to_string(),
            url: analyze_url.url().to_string(),
        });
    }
    let url = analyze_url.url().to_string();
    let body = analyze_url.request_body().to_string();
    let is_post = *analyze_url.method() == RequestMethod::Post;
    send_with_options(client, analyze_url, move |effective| {
        let url = url.clone();
        let body = body.clone();
        let headers = headers.clone();
        async move {
            if is_post {
                effective.post(&url, &body, headers).await
            } else {
                effective.get(&url, headers).await
            }
        }
    })
    .await
}

/// 按 urlOption 语义发送：选择客户端（跟随/不跟随）+ 非 2xx/3xx 重发
///
/// - `followRedirects == Some(false)` → [`LegadoClient::no_redirect_variant`]
///   （实例级缓存第二池）；`true`/缺省 → 现有客户端；
/// - `retry > 0` → 响应状态非 2xx 且非 3xx 时**立即**重发，无退避，至多
///   `retry` 次（总尝试 = retry + 1）；2xx/3xx 与 `Err`（传输错误）原样返回
///   /上抛，不重试（对齐上游 `newCallResponse`：`Err` 由 `await()` 直接上抛）。
///
/// 重试期间每次调用 `send` 都会复用已选定的客户端（组合语义正交：不跟随
/// 客户端在整条重试链上保持一致）。
async fn send_with_options<T, F, Fut>(
    client: &LegadoClient,
    analyze_url: &AnalyzeUrl,
    send: F,
) -> LegadoResult<T>
where
    T: StatusCode,
    F: Fn(LegadoClient) -> Fut,
    Fut: Future<Output = LegadoResult<T>>,
{
    let effective = if analyze_url.follow_redirects() == Some(false) {
        client.no_redirect_variant()?
    } else {
        client.clone()
    };

    let mut retries_remaining = analyze_url.retry();
    loop {
        let response = send(effective.clone()).await?;
        if is_settled_status(response.status_code()) || retries_remaining == 0 {
            return Ok(response);
        }
        retries_remaining -= 1;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_net::LegadoClientConfig;
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};

    /// 回环请求日志：总请求数 + 各路径命中数 + 各请求方法（顺序）
    #[derive(Default)]
    struct HitLog {
        total: AtomicUsize,
        by_path: Mutex<HashMap<String, usize>>,
        methods: Mutex<Vec<String>>,
    }

    impl HitLog {
        fn record(&self, path: &str, method: &str) {
            self.total.fetch_add(1, Ordering::SeqCst);
            *self
                .by_path
                .lock()
                .unwrap()
                .entry(path.to_string())
                .or_default() += 1;
            self.methods.lock().unwrap().push(method.to_string());
        }

        fn total(&self) -> usize {
            self.total.load(Ordering::SeqCst)
        }

        fn hits(&self, path: &str) -> usize {
            self.by_path.lock().unwrap().get(path).copied().unwrap_or(0)
        }

        fn methods(&self) -> Vec<String> {
            self.methods.lock().unwrap().clone()
        }
    }

    /// 状态码 → 原因短语（HTTP/1.1 状态行）
    fn reason(status: u16) -> &'static str {
        match status {
            200 => "OK",
            302 => "Found",
            404 => "Not Found",
            500 => "Internal Server Error",
            _ => "Status",
        }
    }

    /// 脚本回环服务器：`responder(请求序号, 路径)` → `(status, location, body)`。
    ///
    /// 请求序号为进程级递增（重定向/重试的每次实际请求各占一个序号）；
    /// 计数在响应写出**前**递增（客户端收到响应时计数必已更新，断言无竞态）。
    async fn spawn_server<F>(responder: F) -> (SocketAddr, Arc<HitLog>)
    where
        F: Fn(usize, &str) -> (u16, Option<String>, String) + Send + Sync + 'static,
    {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;

        let responder = Arc::new(responder);
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let log = Arc::new(HitLog::default());
        let log_srv = Arc::clone(&log);

        tokio::spawn(async move {
            let mut idx = 0usize;
            while let Ok((mut sock, _)) = listener.accept().await {
                let responder = Arc::clone(&responder);
                let log = Arc::clone(&log_srv);
                let i = idx;
                idx += 1;
                tokio::spawn(async move {
                    // 读请求头至 \r\n\r\n
                    let mut head: Vec<u8> = Vec::new();
                    loop {
                        let mut b = [0u8; 1];
                        match sock.read(&mut b).await {
                            Ok(0) | Err(_) => return,
                            Ok(_) => {}
                        }
                        head.push(b[0]);
                        if head.ends_with(b"\r\n\r\n") {
                            break;
                        }
                    }
                    let head_str = String::from_utf8_lossy(&head);
                    let (method, path) = head_str
                        .lines()
                        .next()
                        .map(|l| {
                            let mut parts = l.split_whitespace();
                            (
                                parts.next().unwrap_or("GET").to_string(),
                                parts.next().unwrap_or("/").to_string(),
                            )
                        })
                        .unwrap_or_else(|| ("GET".to_string(), "/".to_string()));

                    // 读 Content-Length 请求体（POST 兼容；GET 为 0）
                    let content_len = head_str
                        .lines()
                        .find_map(|l| {
                            let (k, v) = l.split_once(':')?;
                            if k.eq_ignore_ascii_case("content-length") {
                                v.trim().parse::<usize>().ok()
                            } else {
                                None
                            }
                        })
                        .unwrap_or(0);
                    if content_len > 0 {
                        let mut body = vec![0u8; content_len];
                        if sock.read_exact(&mut body).await.is_err() {
                            return;
                        }
                    }

                    let (status, location, body) = responder(i, &path);
                    log.record(&path, &method);

                    let mut resp = format!("HTTP/1.1 {status} {}\r\n", reason(status));
                    if let Some(loc) = location {
                        resp.push_str(&format!("Location: {loc}\r\n"));
                    }
                    resp.push_str(&format!(
                        "Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    ));
                    let _ = sock.write_all(resp.as_bytes()).await;
                    let _ = sock.shutdown().await;
                });
            }
        });

        (addr, log)
    }

    /// 回环测试客户端（no_proxy：测试流量不得经系统/环境代理路由）
    fn test_client() -> LegadoClient {
        LegadoClient::new(LegadoClientConfig {
            no_proxy: true,
            ..LegadoClientConfig::default()
        })
        .unwrap()
    }

    fn analyze(template: &str) -> AnalyzeUrl {
        AnalyzeUrl::parse(template, &HashMap::new(), 1).expect("解析测试模板")
    }

    /// 原始字节响应体 → 文本（测试断言用；服务端夹具均为 ASCII）
    fn raw_body(resp: &LegadoRawResponse) -> String {
        String::from_utf8_lossy(&resp.body).into_owned()
    }

    /// 重定向夹具响应：`/target` 200，其余 302 → `/target`
    fn redirect_responder(_i: usize, path: &str) -> (u16, Option<String>, String) {
        if path == "/target" {
            (200, None, "target-hit".to_string())
        } else {
            (
                302,
                Some("/target".to_string()),
                "redirect-body".to_string(),
            )
        }
    }

    // ─── (a) followRedirects ─────────────────────────────────────────────

    /// a1：`followRedirects=false` → 302 原样返回，不跟随（精确 1 次请求，
    /// 重定向目标零触达）
    #[tokio::test]
    async fn test_follow_redirects_false_returns_302_without_following() {
        let (addr, log) = spawn_server(redirect_responder).await;
        let client = test_client();
        let url = format!("http://{addr}/start,{{\"followRedirects\":false}}");

        let resp = send_raw(&client, &analyze(&url), None)
            .await
            .expect("followRedirects=false 下 302 应作为普通响应返回");

        assert_eq!(resp.status, 302, "应返回 302 原响应");
        assert_eq!(raw_body(&resp), "redirect-body");
        assert_eq!(log.total(), 1, "不得跟随重定向（仅 1 次请求）");
        assert_eq!(log.hits("/target"), 0, "重定向目标不得被触达");
    }

    /// a2 回归：缺省与显式 `true` 都走现有共享客户端并跟随重定向
    #[tokio::test]
    async fn test_follow_redirects_default_and_true_follow() {
        let (addr, log) = spawn_server(redirect_responder).await;
        let client = test_client();

        let default_resp = send_raw(&client, &analyze(&format!("http://{addr}/start")), None)
            .await
            .expect("缺省应跟随重定向");
        assert_eq!(default_resp.status, 200);
        assert_eq!(raw_body(&default_resp), "target-hit");

        let true_resp = send_raw(
            &client,
            &analyze(&format!("http://{addr}/start,{{\"followRedirects\":true}}")),
            None,
        )
        .await
        .expect("显式 true 应跟随重定向");
        assert_eq!(true_resp.status, 200);
        assert_eq!(raw_body(&true_resp), "target-hit");

        assert_eq!(log.total(), 4, "两次调用各 2 次请求（/start + /target）");
        assert_eq!(log.hits("/target"), 2);
    }

    // ─── (b) retry ───────────────────────────────────────────────────────

    /// b1：`retry=2` + 持续 500 → 首发送 + 2 次重发（精确 3 次），仍失败
    /// 返回最后一次响应（错误上报由调用方既有非 2xx 分支决定）
    #[tokio::test]
    async fn test_retry_resends_non_2xx_until_exhausted() {
        let (addr, log) = spawn_server(|_i, _p| (500, None, "boom".to_string())).await;
        let client = test_client();
        let url = format!("http://{addr}/x,{{\"retry\":2}}");

        let resp = send_raw(&client, &analyze(&url), None)
            .await
            .expect("重试耗尽后应返回最后一次响应而非传输错误");

        assert_eq!(resp.status, 500, "3 次尝试均失败 → 返回末次 500");
        assert_eq!(raw_body(&resp), "boom");
        assert_eq!(log.total(), 3, "retry=2 → 总尝试 3 次（首次 + 2 次重发）");
    }

    /// b2：中途 200 立即成功返回（500,500,200 → 3 次请求后停止）
    #[tokio::test]
    async fn test_retry_stops_on_2xx_after_failures() {
        let (addr, log) = spawn_server(|i, _p| {
            if i < 2 {
                (500, None, "boom".to_string())
            } else {
                (200, None, "ok".to_string())
            }
        })
        .await;
        let client = test_client();
        let url = format!("http://{addr}/x,{{\"retry\":2}}");

        let resp = send_raw(&client, &analyze(&url), None)
            .await
            .expect("第 3 次成功");

        assert_eq!(resp.status, 200);
        assert_eq!(raw_body(&resp), "ok");
        assert_eq!(log.total(), 3, "成功即停（不再多发第 4 次）");
    }

    /// b3：retry 缺省 / 显式 0 → 不重发（各精确 1 次请求）
    #[tokio::test]
    async fn test_retry_default_zero_does_not_resend() {
        let (addr, log) = spawn_server(|_i, _p| (500, None, "boom".to_string())).await;
        let client = test_client();

        let default_resp = send_raw(&client, &analyze(&format!("http://{addr}/x")), None)
            .await
            .unwrap();
        assert_eq!(default_resp.status, 500);
        assert_eq!(log.total(), 1, "retry 缺省 0 → 不重发");

        let zero_resp = send_raw(
            &client,
            &analyze(&format!("http://{addr}/x,{{\"retry\":0}}")),
            None,
        )
        .await
        .unwrap();
        assert_eq!(zero_resp.status, 500);
        assert_eq!(log.total(), 2, "显式 retry=0 → 不重发（累计仍 2 次）");
    }

    /// b4：3xx 不触发重试（即便 retry>0）——302 原样返回且仅 1 次请求
    #[tokio::test]
    async fn test_retry_does_not_trigger_on_3xx() {
        let (addr, log) = spawn_server(redirect_responder).await;
        let client = test_client();
        let url = format!("http://{addr}/start,{{\"followRedirects\":false,\"retry\":2}}");

        let resp = send_raw(&client, &analyze(&url), None).await.unwrap();

        assert_eq!(resp.status, 302);
        assert_eq!(log.total(), 1, "3xx 属终态，不触发重试");
        assert_eq!(log.hits("/target"), 0);
    }

    // ─── (c) followRedirects=false + retry 组合 ──────────────────────────

    /// c1：500 后重发命中 302 —— 重试链全程使用不跟随客户端
    /// （若第 2 次误用默认客户端，302 会被跟随并触达 /target，计数暴露）
    #[tokio::test]
    async fn test_follow_redirects_false_with_retry_keeps_no_redirect() {
        let (addr, log) = spawn_server(|i, path| {
            if path == "/target" {
                (200, None, "target-hit".to_string())
            } else if i == 0 {
                (500, None, "boom".to_string())
            } else {
                (
                    302,
                    Some("/target".to_string()),
                    "redirect-body".to_string(),
                )
            }
        })
        .await;
        let client = test_client();
        let url = format!("http://{addr}/start,{{\"followRedirects\":false,\"retry\":1}}");

        let resp = send_raw(&client, &analyze(&url), None).await.unwrap();

        assert_eq!(resp.status, 302, "重发命中 302 → 终态返回");
        assert_eq!(raw_body(&resp), "redirect-body");
        assert_eq!(log.total(), 2, "首次 500 + 1 次重发");
        assert_eq!(log.hits("/target"), 0, "重试链不得跟随重定向");
    }

    /// c2：followRedirects=true + retry —— 首次 500 后重发命中 302 并正常跟随
    #[tokio::test]
    async fn test_follow_redirects_true_with_retry_follows_after_resend() {
        let (addr, log) = spawn_server(|i, path| {
            if path == "/target" {
                (200, None, "target-hit".to_string())
            } else if i == 0 {
                (500, None, "boom".to_string())
            } else {
                (
                    302,
                    Some("/target".to_string()),
                    "redirect-body".to_string(),
                )
            }
        })
        .await;
        let client = test_client();
        let url = format!("http://{addr}/start,{{\"followRedirects\":true,\"retry\":2}}");

        let resp = send_raw(&client, &analyze(&url), None).await.unwrap();

        assert_eq!(resp.status, 200);
        assert_eq!(raw_body(&resp), "target-hit");
        assert_eq!(log.total(), 3, "500 一次 + 重发（302+跟随）两次");
        assert_eq!(log.hits("/target"), 1);
    }

    /// c3：POST + retry 组合（method 由 AnalyzeUrl 决定，重发生效）
    #[tokio::test]
    async fn test_post_with_retry_resends() {
        let (addr, log) = spawn_server(|i, _p| {
            if i == 0 {
                (500, None, "boom".to_string())
            } else {
                (200, None, "created".to_string())
            }
        })
        .await;
        let client = test_client();
        let url = format!("http://{addr}/api,{{\"method\":\"POST\",\"retry\":1}}");

        let resp = send_raw(&client, &analyze(&url), None).await.unwrap();

        assert_eq!(resp.status, 200);
        assert_eq!(raw_body(&resp), "created");
        assert_eq!(log.total(), 2, "POST 首次 500 + 1 次重发");
        assert_eq!(log.methods(), vec!["POST", "POST"], "沿用 POST 方法");
    }

    // ─── send_text 共用重试循环 ──────────────────────────────────────────

    /// 文本响应用同一重试循环（搜索/词典等文本路径接线回归）
    #[tokio::test]
    async fn test_send_text_retry_and_final_status() {
        let (addr, log) = spawn_server(|i, _p| {
            if i < 2 {
                (500, None, "boom".to_string())
            } else {
                (200, None, "ok".to_string())
            }
        })
        .await;
        let client = test_client();
        let url = format!("http://{addr}/t,{{\"retry\":2}}");

        let resp = send_text(&client, &analyze(&url), None).await.unwrap();

        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, "ok");
        assert_eq!(log.total(), 3);
    }

    // ─── P2-15：data: URI 不得进 reqwest（搜索路径经本汇聚点直发） ─────────
    //
    // 实机 15 号（猫眼看书）报 `builder error for url (data:;base64,...)`：
    // 搜索路径 `search_single_source` 不经 `web_book::fetch_page` 的 data URI
    // 分支，直接调用本模块 `send_raw` → reqwest 不支持 data: 协议 → builder
    // error。断言口径：空 mime（`data:;base64,`）与有 mime 形态都须本地解码、
    // 绝不发起请求；解码失败保持 Internal（与 fetch_page 现状一致）。

    /// base64 编码（测试夹具）
    fn b64(s: &str) -> String {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(s)
    }

    /// 空 mime（实机精确形态）：send_raw 本地解码，状态 200、url 为 data URI。
    #[tokio::test]
    async fn test_p2_15_send_raw_empty_mime_data_uri_decoded_locally() {
        let client = test_client();
        let url = format!("data:;base64,{}", b64(r#"{"name":"ok"}"#));

        let raw = send_raw(&client, &analyze(&url), None)
            .await
            .expect("空 mime data URI 应本地解码，不得进 reqwest（15 号 builder error）");

        assert_eq!(raw.status, 200);
        assert_eq!(raw.body, br#"{"name":"ok"}"#);
        assert_eq!(raw.url, url, "url 保持 data URI 原值");
    }

    /// 空 mime + `,{"type":...}` 选项 → hex 编码正文（对齐上游 type != null
    /// 分支 `HexUtil.encodeHexStr`，书源再 hexDecodeToString 还原）。
    #[tokio::test]
    async fn test_p2_15_send_raw_empty_mime_type_option_returns_hex() {
        let client = test_client();
        let payload = "/novel?sort=1&page=1";
        let url = format!(
            "data:;base64,{},{{\"type\":\"maoyankanshu\"}}",
            b64(payload)
        );

        let raw = send_raw(&client, &analyze(&url), None)
            .await
            .expect("带 type 选项的空 mime data URI 应本地解码");

        let hex: String = payload.bytes().map(|b| format!("{b:02x}")).collect();
        assert_eq!(String::from_utf8(raw.body).unwrap(), hex);
        // url 为分离选项后的 URL 本体（对齐上游 urlNoOption 语义）
        assert_eq!(raw.url, format!("data:;base64,{}", b64(payload)));
    }

    /// 有 mime（`data:application/json;base64,`）经 send_text 本地解码，不回归。
    #[tokio::test]
    async fn test_p2_15_send_text_mime_data_uri_decoded_locally() {
        let client = test_client();
        let url = format!("data:application/json;base64,{}", b64(r#"{"name":"ok"}"#));

        let resp = send_text(&client, &analyze(&url), None)
            .await
            .expect("有 mime data URI 应本地解码");

        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, r#"{"name":"ok"}"#);
        assert_eq!(resp.url, url);
    }

    /// 非 base64（`data:text/plain,hello`）与 parser 侧同口径：本地按 URL 编码
    /// 文本解码（已登记超集），同样不得进 reqwest（reqwest 对 data: 协议必失败）。
    #[tokio::test]
    async fn test_p2_15_send_text_non_base64_data_uri_decoded_locally() {
        let client = test_client();
        let url = "data:text/plain,hello";

        let resp = send_text(&client, &analyze(url), None)
            .await
            .expect("非 base64 data URI 应按已登记超集本地解码");

        assert_eq!(resp.body, "hello");
    }

    /// 非法 base64 数据段：保持 Internal 语义（与 fetch_page 现状一致），
    /// 不得退化成 reqwest builder error。
    #[tokio::test]
    async fn test_p2_15_invalid_base64_is_internal_not_reqwest() {
        let client = test_client();
        let url = "data:;base64,!!!!not-base64!!!!";

        let err = send_raw(&client, &analyze(url), None)
            .await
            .expect_err("非法 base64 应报解码失败");

        let msg = err.to_string();
        assert!(
            msg.contains("解码失败"),
            "解码失败应保持 Internal 文案: {msg}"
        );
        assert!(
            !msg.contains("builder error"),
            "不得把 data: URI 喂给 reqwest: {msg}"
        );
    }

    /// 回归：普通 http URL 不受 data URI 短路影响（仍走回环网络路径）。
    #[tokio::test]
    async fn test_p2_15_http_url_still_goes_through_client() {
        let (addr, log) = spawn_server(|_i, _p| (200, None, "http-ok".to_string())).await;
        let client = test_client();

        let raw = send_raw(&client, &analyze(&format!("http://{addr}/plain")), None)
            .await
            .unwrap();

        assert_eq!(String::from_utf8_lossy(&raw.body), "http-ok");
        assert_eq!(log.total(), 1, "http URL 仍走网络路径");
    }
}
