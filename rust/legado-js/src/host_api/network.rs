//! JsExtensions 网络相关方法
//!
//! 书源规则中常用的网络请求方法，对应 Kotlin JsExtensions 中的 ajax/connect/get/post/head 等。
//! 使用 `legado-net::LegadoClient` 异步网络栈，通过 `runtime_bridge::block_on` 提供同步接口。

#![cfg(feature = "quickjs")]

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, OnceLock, RwLock};

use crate::host_api::runtime_bridge::block_on;
use legado_net::{CookiePersistence, LegadoClient, LegadoClientConfig, LegadoRequest, Method};

/// 默认请求超时（毫秒），与 Kotlin 端一致
const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// ajaxAll 有界并发数
const AJAX_ALL_CONCURRENCY: usize = 4;

/// body 反序列化：兼容字符串、对象/数组（书山聚合等源 `url,{json}` 的
/// body 是嵌套对象，须转 JSON 字符串，否则 serde 解析失败 → ajax 返回 [ERROR]）
fn de_body<'de, D>(de: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let v = Option::<serde_json::Value>::deserialize(de)?;
    Ok(v.map(|b| match b {
        serde_json::Value::String(s) => s,
        other => other.to_string(),
    }))
}

/// HTTP 请求选项（用于 `ajax` 通用接口）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct HttpOptions {
    /// HTTP 方法：GET / POST / HEAD / PUT / DELETE
    #[serde(default)]
    pub method: Option<String>,
    /// 请求 URL
    #[serde(default)]
    pub url: String,
    /// 请求头
    #[serde(default)]
    pub headers: Option<HashMap<String, String>>,
    /// 请求体（POST/PUT 时使用；兼容字符串或 JSON 对象/数组）
    #[serde(default, deserialize_with = "de_body")]
    pub body: Option<String>,
    /// 超时毫秒数
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

/// HTTP 响应（用于 `ajax` 通用接口返回）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HttpResponse {
    /// HTTP 状态码
    pub status_code: u16,
    /// 响应体文本
    pub body: String,
    /// 响应头
    pub headers: HashMap<String, String>,
    /// 最终 URL（connect/StrResponse raw.request.url 兼容）
    #[serde(default)]
    pub url: String,
}

/// 从 JSON 字符串解析请求头
fn parse_headers(headers_json: Option<&str>) -> Option<HashMap<String, String>> {
    headers_json.and_then(|s| serde_json::from_str::<HashMap<String, String>>(s).ok())
}

/// 请求前规范化 URL：去掉/纠正书源 `#tag` 后缀（对齐 Jsoup 忽略 fragment，
/// 并修复 `getKey()+path` 把 path/query 拼进 fragment 的假 URL）
fn sanitize_request_url(url: &str) -> String {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    // 复用 AnalyzeUrl 同一套规范化，避免 ajax/connectNR 与搜索主链路行为分叉
    legado_parser::AnalyzeUrl::normalize_book_source_tag_url(trimmed)
}

/// 判断 URL 是否指向本地回环地址（127.0.0.1 / ::1 / localhost，http/https）
///
/// 供 `connect_no_redirect` 决定 `no_proxy`：reqwest 默认客户端在
/// HTTP_PROXY/HTTPS_PROXY 存在时连回环地址也走代理，会把本地测试流量
/// 劫持到死代理；回环豁免对齐 legado-net 约定（cda70a0c54）。
fn is_loopback_url(url: &str) -> bool {
    let lower = url.to_ascii_lowercase();
    for scheme in ["http://", "https://"] {
        let Some(rest) = lower.strip_prefix(scheme) else {
            continue;
        };
        // host 段：到第一个 ':' 或 '/' 为止；[::1] 带方括号形式
        let host = rest.split([':', '/']).next().unwrap_or("");
        let host = host
            .strip_prefix('[')
            .unwrap_or(host)
            .strip_suffix(']')
            .unwrap_or(host);
        if host == "127.0.0.1" || host == "::1" || host == "localhost" {
            return true;
        }
    }
    false
}

/// POST 有 body 时若缺 Content-Type，补 form-urlencoded（对齐 Jsoup.requestBody）
fn ensure_form_content_type(headers: &mut HashMap<String, String>, has_body: bool) {
    if !has_body {
        return;
    }
    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if !has_ct {
        headers.insert(
            "Content-Type".to_string(),
            "application/x-www-form-urlencoded".to_string(),
        );
    }
}

/// 进程级共享客户端池（性能专项 2026-09-24）
///
/// 此前每次 JS 网络调用（ajax/get/post/head/connect/ajaxAll/connectNR/
/// downloadFile/字体下载…）都 `LegadoClient::new` 新建客户端——即新建
/// reqwest 连接池，每调用重复 TCP+TLS 握手（真实站点实测每页多 ~38ms；
/// 本地 HTTPS mock 实测新建 10/50 页分别多 10/50 次 TLS 握手）。
/// 现收敛为进程级单例池：`LegadoClient` 是 `Clone`（内部全 `Arc`），
/// clone 廉价且**共享同一连接池**（keep-alive 复用）。语义逐池保持等价：
///
/// - 默认池：默认配置（系统/环境变量代理、跟随重定向、60s 读超时）
/// - 回环池：`no_proxy` 直连（P2-17 约定 cda70a0c54：HTTP_PROXY 存在时
///   reqwest 连 127.0.0.1 也走代理，死代理环境下本地流量会被劫持）
/// - 不跟随重定向池：`follow_redirects=false`（connectNR 拦截 302 取
///   Location 头），回环/非回环分池（代理语义同前两条）
///
/// 读超时：各池统一用 `LegadoClientConfig::default()`（60s）；所有
/// `send(LegadoRequest)` 调用点均带**逐请求** `timeout`（reqwest 逐请求
/// 超时覆盖客户端级），有效超时与修复前逐客户端配置一致。
///
/// Cookie：共享池的内存 CookieStore 跨调用累积（按域 upsert），与 FFI
/// 主链路共享客户端、上游 OkHttp 单客户端 + cookieJar 语义一致（改进
/// 不回退）；JS 层 `merge_js_cookies` 按域合并注入不受影响。
///
/// **Cookie 持久化（设计项 A，2026-09-26）**：池支持注入
/// [`CookiePersistence`] 后端（[`set_client_cookie_persistence`]，
/// first-wins，由 `legado-ffi::ffi::db_open` 注入 DB 实现）——客户端
/// 构建/重建时从后端预载已持久化 cookie 进内存 jar，响应 Set-Cookie
/// 同步写回（按域 upsert，含无 Expires 的会话 cookie）。修复 x81zws
/// WAF 状态机跨进程断链（根因：JS 桥池客户端仅内存 jar，冷启动即失
/// Set-Cookie 种下的状态；见 `.tmp/engine_forensic_d/report_d.md` §2 /
/// `design_upstream_aligned.md` §3 项 A）。未注册后端时（CLI/测试路
/// 径）行为等价 `LegadoClient::new`（纯内存 jar，语义不变）。
///
/// **锁序不变式**（仿 `legado-ffi::http_state::shared_client`）：客户端
/// 构建（含持久化后端 `load_all` 的 DB I/O）在持有池槽位**写锁之前**
/// 完成——槽位锁临界区不做 DB/sink 调用；并发首建时各线程自建，槽位
/// 内先装者胜（败者构建直接丢弃——其 jar 是后端全新加载、无在途写
/// 入，丢弃无数据损失）。
///
/// 池槽位注册表：`OnceLock` 惰性创建 4 槽数组，每槽
/// `RwLock<Option<LegadoClient>>`（`Option` 供
/// [`reset_shared_client_pools`] 置空后下次访问按当前配置重建）
static POOL_SLOTS: OnceLock<[RwLock<Option<LegadoClient>>; 4]> = OnceLock::new();

/// 池标识（loopback/no_redirect 两配置轴的 4 种组合，语义逐池保持）
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PoolKind {
    /// 默认池：默认配置（系统/环境变量代理、跟随重定向、60s 读超时）
    Default,
    /// 回环池：`no_proxy` 直连（P2-17 约定 cda70a0c54）
    Loopback,
    /// 不跟随重定向池：`follow_redirects=false`（connectNR 拦截 302 取
    /// Location 头）
    NoRedirect,
    /// 不跟随重定向回环池：`no_proxy` + `follow_redirects=false`
    NoRedirectLoopback,
}

impl PoolKind {
    /// 全部池（reset 遍历顺序）
    const ALL: [PoolKind; 4] = [
        PoolKind::Default,
        PoolKind::Loopback,
        PoolKind::NoRedirect,
        PoolKind::NoRedirectLoopback,
    ];

    /// 标志 → 池标识
    fn from_flags(loopback: bool, no_redirect: bool) -> Self {
        match (loopback, no_redirect) {
            (false, false) => PoolKind::Default,
            (true, false) => PoolKind::Loopback,
            (false, true) => PoolKind::NoRedirect,
            (true, true) => PoolKind::NoRedirectLoopback,
        }
    }

    /// 池配置（与改造前四池配置逐项一致）
    fn config(&self) -> LegadoClientConfig {
        match self {
            PoolKind::Default => LegadoClientConfig::default(),
            PoolKind::Loopback => LegadoClientConfig {
                no_proxy: true,
                ..Default::default()
            },
            PoolKind::NoRedirect => LegadoClientConfig {
                follow_redirects: false,
                ..Default::default()
            },
            PoolKind::NoRedirectLoopback => LegadoClientConfig {
                follow_redirects: false,
                no_proxy: true,
                ..Default::default()
            },
        }
    }
}

/// 取池槽位引用
fn pool_slot(kind: PoolKind) -> &'static RwLock<Option<LegadoClient>> {
    let slots = POOL_SLOTS.get_or_init(|| {
        [
            RwLock::new(None),
            RwLock::new(None),
            RwLock::new(None),
            RwLock::new(None),
        ]
    });
    &slots[kind as usize]
}

/// Cookie 持久化后端钩子（设计项 A）
///
/// 由 `legado-ffi::ffi::db_open` 在 DB 初始化后、一切 JS 执行前注入
/// （具体类型 `legado-ffi::http_state::DbCookiePersistence`：DB 未就
/// 绪时 `load_all` 降级为空、`save` 仅记日志，不影响网络请求）。
static CLIENT_COOKIE_PERSISTENCE: OnceLock<Arc<dyn CookiePersistence>> = OnceLock::new();

/// 注册 Cookie 持久化后端（first-wins，仿
/// `legado-js::host_api::cookie_store::set_cookie_sink`）
///
/// 返回本次注册是否生效：重复注册忽略并返回 `false`（不覆盖首个实例）。
pub fn set_client_cookie_persistence(p: Arc<dyn CookiePersistence>) -> bool {
    CLIENT_COOKIE_PERSISTENCE.set(p).is_ok()
}

/// 重置全部 4 个池槽位（仿 `legado-ffi::http_state::reset_shared_client`）
///
/// 置空后下次 [`shared_client`] 调用按当前配置重建（构建时读取此刻已
/// 注册的持久化后端）。供 `db_open` 在注入钩子后兜底重建：正常时序
/// db_open 先于一切 JS 执行、池尚未构建（reset 为空操作）；若某路径
/// 已先行构建池，reset 保证重建后的客户端携带持久化后端。
pub fn reset_shared_client_pools() {
    for kind in PoolKind::ALL {
        *pool_slot(kind)
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    }
}

/// 以显式持久化后端构建池客户端（测试入口：不触碰全局钩子，确定性
/// 覆盖已注册/未注册两个分支）
fn build_pool_client_with(
    kind: PoolKind,
    persistence: Option<Arc<dyn CookiePersistence>>,
) -> Result<LegadoClient, String> {
    let config = kind.config();
    match persistence {
        // 已注册：构建即从后端预载已持久化 cookie 进内存 jar
        // （DB I/O；须在槽位写锁之前完成，见模块头锁序不变式）
        Some(p) => LegadoClient::with_cookie_persistence(config, p),
        // 未注册：等价改造前 `LegadoClient::new`（纯内存 jar）
        None => LegadoClient::new(config),
    }
    .map_err(|e| format!("build client error: {e}"))
}

/// 以当前已注册的持久化后端构建池客户端（未注册时为 `None`）
fn build_pool_client(kind: PoolKind) -> Result<LegadoClient, String> {
    build_pool_client_with(kind, CLIENT_COOKIE_PERSISTENCE.get().cloned())
}

/// 取进程级共享客户端（池由 `loopback`/`no_redirect` 选择）
///
/// 首次调用构建并安装（已注册持久化后端时构建即预载；未注册时等价
/// `LegadoClient::new`）；并发竞争时复用先装入者（同配置，无副作用）。
/// 锁序不变式：构建不持槽位写锁（见模块头说明）。
fn shared_client(loopback: bool, no_redirect: bool) -> Result<LegadoClient, String> {
    let kind = PoolKind::from_flags(loopback, no_redirect);
    // 快路径：已初始化则直接 clone 返回
    {
        let guard = pool_slot(kind)
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(client) = guard.as_ref() {
            return Ok(client.clone());
        }
    }
    // 慢路径：先构建（含持久化后端 load_all，不持槽位锁），再短暂持
    // 写锁装入
    let client = build_pool_client(kind)?;
    let mut guard = pool_slot(kind)
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    // 并发首次构建时再次检查：他线程已装入则返回其结果（自身构建丢弃）
    if let Some(existing) = guard.as_ref() {
        return Ok(existing.clone());
    }
    *guard = Some(client.clone());
    Ok(client)
}

/// 按 URL 取共享客户端：回环 URL（127.0.0.1/::1/localhost）用 `no_proxy`
/// 直连池（P2-17 约定 cda70a0c54），真实主机用默认池（系统/环境变量
/// 代理配置不变，生产行为不受影响）。
pub(crate) fn shared_client_for_url(url: &str) -> Result<LegadoClient, String> {
    shared_client(is_loopback_url(url), false)
}

/// 取不跟随重定向的共享客户端（connectNR 语义：拦截 302 取 Location 头），
/// 回环/非回环分池（代理语义同 `shared_client_for_url`）。
fn shared_client_no_redirect(url: &str) -> Result<LegadoClient, String> {
    shared_client(is_loopback_url(url), true)
}

/// httpGet(url, headers?) → 同步 HTTP GET，返回响应体文本
///
/// 对应 Kotlin 端 `ajax(url)` / `get(url, headers)` 的简化版本。
pub fn http_get(url: &str, headers: Option<&str>) -> Result<String, String> {
    block_on(async {
        // 回环 URL 直连豁免代理（P2-17 约定），真实主机行为不变；
        // 进程级共享池（2026-09-24 性能专项：不再每调用新建连接池）
        let client = shared_client_for_url(url)?;
        let header_map = parse_headers(headers);
        let resp = client
            .get(url, header_map)
            .await
            .map_err(|e| format!("httpGet error: {}", e))?;
        Ok(resp.body)
    })
}

/// httpPost(url, body, headers?) → 同步 HTTP POST，返回响应体文本
///
/// 对应 Kotlin 端 `post(url, body, headers)` 的简化版本。
pub fn http_post(url: &str, body: &str, headers: Option<&str>) -> Result<String, String> {
    block_on(async {
        // 回环 URL 直连豁免代理（P2-17 约定），真实主机行为不变；
        // 进程级共享池（2026-09-24 性能专项：不再每调用新建连接池）
        let client = shared_client_for_url(url)?;
        let header_map = parse_headers(headers);
        let resp = client
            .post(url, body, header_map)
            .await
            .map_err(|e| format!("httpPost error: {}", e))?;
        Ok(resp.body)
    })
}

/// httpHead(url) → HEAD 请求，返回响应头 JSON 字符串
///
/// 对应 Kotlin 端 `head(urlStr, headers)` 的简化版本。
pub fn http_head(url: &str) -> Result<String, String> {
    block_on(async {
        // 回环 URL 直连豁免代理（P2-17 约定），真实主机行为不变；
        // 进程级共享池（2026-09-24 性能专项：不再每调用新建连接池）
        let client = shared_client_for_url(url)?;
        let resp = client
            .head(url, None)
            .await
            .map_err(|e| format!("httpHead error: {}", e))?;
        serde_json::to_string(&resp.headers).map_err(|e| format!("httpHead serialize error: {}", e))
    })
}

/// ajax(options) → 通用 AJAX 请求
///
/// 支持两种输入（对齐原版 JsExtensions.ajax）：
/// 1. 标准 JSON：`{"url":..., "method":..., "headers":..., "body":...}` → 返回 HttpResponse JSON
/// 2. 原版「url,{json}」格式（七猫四合一等书源）：
///    `https://api?... ,{"method":"GET","headers":{...}}` → 返回**纯响应体文本**
///    （原版 ajax 返回 StrResponse.body；七猫 qmParse 直接 JSON.parse 响应体）
pub fn ajax(input: &str) -> Result<String, String> {
    let input = input.trim();
    // 原版「url,{json}」格式：不以 `{` 开头且含 `,{`，逗号前为 URL、逗号后为 option JSON
    if !input.starts_with('{') {
        if let Some(comma) = input.find(",{") {
            let url_part = input[..comma].trim();
            let option_part = &input[comma + 1..];
            if let Ok(mut v) = serde_json::from_str::<serde_json::Value>(option_part) {
                if let Some(obj) = v.as_object_mut() {
                    obj.insert(
                        "url".to_string(),
                        serde_json::Value::String(url_part.to_string()),
                    );
                    if let Ok(opts) = serde_json::from_value::<HttpOptions>(v) {
                        return ajax_request_body(&opts);
                    }
                }
            }
        }
    }
    // 普通 URL 输入（对齐原版 ajax(url) 语义）：不含 ",{" 的裸 URL
    // 直接 GET 并返回纯响应体文本（新落秋/笔趣阁zdzn 等源 @js: 块
    // java.ajax(source.key+"/user/search.html?q="+key) 依赖）
    // — 2026-08-17
    if !input.starts_with('{') {
        let opts = HttpOptions {
            url: input.to_string(),
            ..Default::default()
        };
        return ajax_request_body(&opts);
    }
    // 标准 JSON 输入
    let opts: HttpOptions =
        serde_json::from_str(input).map_err(|e| format!("ajax parse options error: {}", e))?;

    if opts.url.is_empty() {
        return Err("ajax: url is required".to_string());
    }
    let url = sanitize_request_url(&opts.url);
    if url.is_empty() {
        return Err("ajax: url is required".to_string());
    }

    let timeout = opts.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    let method_str = opts.method.as_deref().unwrap_or("GET").to_uppercase();

    // 验证方法是否受支持
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("ajax: unsupported method '{}'", other)),
    };

    block_on(async {
        // 共享池（有效超时由逐请求 timeout 决定，与修复前一致）
        let client = shared_client_for_url(&url)?;

        // Cookie 合并须在 url move 进 LegadoRequest 前完成（新签名按请求 URL 取 cookie）
        let headers = ensure_json_content_type(
            merge_global_cookie(opts.headers.clone().unwrap_or_default(), &url),
            &opts.body,
        );
        let request = LegadoRequest {
            url,
            method,
            headers,
            body: opts.body.clone(),
            timeout: Some(std::time::Duration::from_millis(timeout)),
        };

        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("ajax request error: {}", e))?;

        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };

        serde_json::to_string(&result).map_err(|e| format!("ajax serialize error: {}", e))
    })
}

#[cfg(test)]
mod http_options_tests {
    use super::*;

    #[test]
    fn test_body_accepts_object() {
        // 书山目录：url,{"method":"POST","body":{...对象...}}
        let opts: HttpOptions = serde_json::from_str(
            r#"{"method":"POST","url":"https://v1.vossc.com/catalog","body":{"source":"书山","url":"x","name":"n","tab":"novel"}}"#,
        )
        .unwrap();
        assert!(opts.body.as_deref().unwrap().contains("source"));
        assert!(opts.body.as_deref().unwrap().contains("书山"));
    }

    #[test]
    fn test_body_accepts_string() {
        let opts: HttpOptions =
            serde_json::from_str(r#"{"method":"POST","body":"key=val"}"#).unwrap();
        assert_eq!(opts.body.as_deref(), Some("key=val"));
    }
}

/// 合并书源请求头与会话 Cookie（对齐 Android AnalyzeUrl(source).getHeaderMap）
///
/// - 全局请求头（GLOBAL_HEADERS）：setup 阶段执行书源 header @js 规则后经
///   java.putGlobalHeaders 写入（书山聚合固定 X-Novel-Token 等），按当前书源
///   tag 隔离；JS 显式传入的 headers 优先。
/// - 会话 Cookie（GLOBAL_COOKIES）：书山登录/`java.setCookie` 写入的
///   X-Novel-Token 等。**上游同步（2026-09-23 用户裁决）：按请求 URL 的属域
///   取**（`cookie_store::cookies_for_url`，写读两侧均归一为
///   `getSubDomain(url)` 等价域名键，单一真源
///   [`legado_net::cookie_store::cookie_domain_key`]），去掉书源 tag 维度——
///   cookie 属于域名而非书源，同域 cookie 跨书源共享（对齐上游
///   `CookieManager.loadRequest` 按请求 URL 取 cookie 的语义）。
///   **按键合并**进已有 Cookie 头（已有同名键胜、非冲突 JS 键追加；
///   键查找大小写不敏感）——对齐上游 `AnalyzeUrl.setCookie` →
///   `CookieManager.mergeCookies` 语义。
///   不变式保留：**不相关域名的 cookie 绝不携带**（P2-19 核心修复，不得回退）。
fn merge_global_cookie(mut headers: HashMap<String, String>, url: &str) -> HashMap<String, String> {
    let tag = crate::host_api::current_source::current_source_tag();
    if let Some(t) = tag.as_deref() {
        for (k, v) in crate::host_api::global_headers::headers_for(t) {
            headers.entry(k).or_insert(v);
        }
    }
    crate::host_api::cookie_store::merge_js_cookies(&mut headers, url);
    headers
}

/// 对齐原版 AnalyzeUrl POST 分支：body 非空且未显式指定 Content-Type 时按
/// JSON 发送（postJson(body)）——书山 /details、/catalog 等服务端校验
/// Content-Type，缺省返回「缺少必要参数」（curl 实测 application/json 必带）。
/// 仅当 body 是 JSON 形态（{/[ 开头）才设 JSON Content-Type：书山 /login 等
/// 表单接口（email=..&password=..）若被标 JSON 会解析出空字段（实测
/// 「邮箱和密码不能为空」），须保持默认 application/x-www-form-urlencoded。
fn ensure_json_content_type(
    mut headers: HashMap<String, String>,
    body: &Option<String>,
) -> HashMap<String, String> {
    let has_ct = headers
        .keys()
        .any(|k| k.eq_ignore_ascii_case("content-type"));
    if has_ct {
        return headers;
    }
    if let Some(b) = body {
        let t = b.trim_start();
        if t.starts_with('{') || t.starts_with('[') {
            // JSON 形态 body：对齐原版 postJson(body)
            headers.insert(
                "Content-Type".to_string(),
                "application/json;charset=UTF-8".to_string(),
            );
        } else if t.contains('=') && !t.contains(' ') {
            // 表单形态 body（email=..&password=..）：显式 form-urlencoded，
            // 避免 reqwest 自动 text/plain 导致服务端解析空字段
            headers.insert(
                "Content-Type".to_string(),
                "application/x-www-form-urlencoded".to_string(),
            );
        }
    }
    headers
}

/// 「url,{json}」格式请求，返回**纯响应体文本**（对齐原版 JsExtensions.ajax 返回
/// StrResponse.body；七猫 qmParse 等直接 JSON.parse 响应体）
fn ajax_request_body(opts: &HttpOptions) -> Result<String, String> {
    if opts.url.is_empty() {
        return Err("ajax: url is required".to_string());
    }
    let url = sanitize_request_url(&opts.url);
    if url.is_empty() {
        return Err("ajax: url is required".to_string());
    }
    let timeout = opts.timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    let method_str = opts.method.as_deref().unwrap_or("GET").to_uppercase();
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("ajax: unsupported method '{}'", other)),
    };
    block_on(async {
        // 共享池（有效超时由逐请求 timeout 决定，与修复前一致）
        let client = shared_client_for_url(&url)?;
        // Cookie 合并须在 url move 进 LegadoRequest 前完成（新签名按请求 URL 取 cookie）
        let headers = ensure_json_content_type(
            merge_global_cookie(opts.headers.clone().unwrap_or_default(), &url),
            &opts.body,
        );
        let request = LegadoRequest {
            url,
            method,
            headers,
            body: opts.body.clone(),
            timeout: Some(std::time::Duration::from_millis(timeout)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("ajax request error: {}", e))?;
        Ok(resp.body)
    })
}

/// ajaxAll(urls_json) → 批量并发请求（有界并发）
///
/// 输入为 JSON 数组（URL 列表），返回 JSON 数组（每个 URL 的响应体，失败为空字符串）。
/// 使用 `futures::stream::buffer_unordered` 实现有界并发（默认 4）。
pub fn ajax_all(urls_json: &str) -> Result<String, String> {
    block_on(async {
        let urls: Vec<String> =
            serde_json::from_str(urls_json).map_err(|e| format!("ajaxAll parse error: {}", e))?;

        let client = shared_client(false, false)?;
        // 回环 URL（本地书源/本地测试服务）须 no_proxy 直连（P2-17 约定
        // cda70a0c54：HTTP_PROXY 存在时 reqwest 连 127.0.0.1 也走代理）；
        // 真实主机 URL 沿用默认池（代理配置不变）
        let loopback_client = urls
            .iter()
            .any(|url| is_loopback_url(url))
            .then(|| shared_client(true, false))
            .transpose()?;

        use futures::stream::{self, StreamExt};

        let results: Vec<String> = stream::iter(urls)
            .map(|url| {
                let c = if is_loopback_url(&url) {
                    loopback_client
                        .as_ref()
                        .expect("loopback client built above")
                        .clone()
                } else {
                    client.clone()
                };
                async move {
                    c.get(&url, None)
                        .await
                        .map(|resp| resp.body)
                        .unwrap_or_default()
                }
            })
            .buffer_unordered(AJAX_ALL_CONCURRENCY)
            .collect()
            .await;

        serde_json::to_string(&results).map_err(|e| format!("ajaxAll serialize error: {}", e))
    })
}

/// connectFull(url, method?, headers?, body?, timeoutMs?) → 完整 HTTP 响应 JSON
///
/// 对应 Kotlin: `connect(urlStr, header, callTimeout): StrResponse`
/// 增强版：支持指定 HTTP 方法（GET/POST/HEAD/PUT/DELETE），返回完整响应。
///
/// 返回 JSON：`{"statusCode":200,"body":"...","headers":{...}}`
pub fn connect_full(
    url: &str,
    method: Option<&str>,
    headers_json: Option<&str>,
    body: Option<&str>,
    timeout_ms: Option<u64>,
) -> Result<String, String> {
    let timeout = timeout_ms.unwrap_or(DEFAULT_TIMEOUT_MS);
    let method_str = method.unwrap_or("GET").to_uppercase();
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("connect: unsupported method '{}'", other)),
    };
    let headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    block_on(async {
        // 回环 URL 直连豁免代理（P2-17 约定），真实主机行为不变；
        // 共享池（有效超时由逐请求 timeout 决定，与修复前一致）
        let client = shared_client_for_url(url)?;
        let request = LegadoRequest {
            url: url.to_string(),
            method,
            headers,
            body: body.map(|s| s.to_string()),
            timeout: Some(std::time::Duration::from_millis(timeout)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("connect request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("connect serialize error: {}", e))
    })
}

/// connectNR(url, method?, headers?, body?) → 完整响应 JSON（不跟随重定向）
///
/// 对齐原版 JsExtensions.get/post/head 的 jsoup 语义（.followRedirects(false)）：
/// 拦截重定向场景（天悦小说 java.post(...).header("Location")）必须拿到
/// 302 响应的 Location 头；跟随重定向后头信息丢失 → header 返回 null。
/// — 2026-08-17
pub fn connect_no_redirect(
    url: &str,
    method: Option<&str>,
    headers_json: Option<&str>,
    body: Option<&str>,
) -> Result<String, String> {
    let method_str = method.unwrap_or("GET").to_uppercase();
    let method = match method_str.as_str() {
        "GET" | "POST" | "HEAD" | "PUT" | "DELETE" => Method::from_str_loose(&method_str),
        other => return Err(format!("connectNR: unsupported method '{}'", other)),
    };
    let url = sanitize_request_url(url);
    let mut headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    let body_owned = body.map(|s| s.to_string());
    ensure_form_content_type(
        &mut headers,
        body_owned.as_ref().is_some_and(|b| !b.is_empty()),
    );
    block_on(async {
        // 不跟随重定向共享池（回环/非回环分池）：
        // - `follow_redirects=false`：拦截 302 取 Location 头（jsoup 语义）
        // - 回环流量（本地测试服务/本地源）不得经系统/环境变量代理路由：
        //   reqwest 默认客户端在 HTTP_PROXY 存在时连 127.0.0.1 也走代理，
        //   死代理环境下回环用例会被劫持（cda70a0c54 约定）。仅回环 URL
        //   豁免代理；真实主机仍走用户代理配置，不改变生产行为。
        let client = shared_client_no_redirect(&url)
            .map_err(|e| format!("connectNR client error: {}", e))?;
        let request = LegadoRequest {
            url,
            method,
            headers,
            body: body_owned,
            timeout: Some(std::time::Duration::from_millis(DEFAULT_TIMEOUT_MS)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("connectNR request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("connectNR serialize error: {}", e))
    })
}

/// headFull(url, headers?) → HEAD 请求完整响应 JSON
///
/// 对应 Kotlin: `head(urlStr, headers): Connection.Response`
/// 返回包含 statusCode / body / headers 的完整响应 JSON。
pub fn head_full(url: &str, headers_json: Option<&str>) -> Result<String, String> {
    let headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    block_on(async {
        // 回环 URL 直连豁免代理（P2-17 约定），真实主机行为不变；
        // 进程级共享池（2026-09-24 性能专项：不再每调用新建连接池）
        let client = shared_client_for_url(url)?;
        let request = LegadoRequest {
            url: url.to_string(),
            method: Method::Head,
            headers,
            body: None,
            timeout: Some(std::time::Duration::from_millis(DEFAULT_TIMEOUT_MS)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("head request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("head serialize error: {}", e))
    })
}

/// postFull(url, body, headers?) → POST 请求完整响应 JSON
///
/// 对应 Kotlin: `post(urlStr, body, headers): Connection.Response`
/// 返回包含 statusCode / body / headers 的完整响应 JSON。
pub fn post_full(url: &str, body: &str, headers_json: Option<&str>) -> Result<String, String> {
    let headers: HashMap<String, String> = headers_json
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();

    block_on(async {
        // 回环 URL 直连豁免代理（P2-17 约定），真实主机行为不变；
        // 进程级共享池（2026-09-24 性能专项：不再每调用新建连接池）
        let client = shared_client_for_url(url)?;
        let request = LegadoRequest {
            url: url.to_string(),
            method: Method::Post,
            headers,
            body: Some(body.to_string()),
            timeout: Some(std::time::Duration::from_millis(DEFAULT_TIMEOUT_MS)),
        };
        let resp = client
            .send(&request)
            .await
            .map_err(|e| format!("post request error: {}", e))?;
        let result = HttpResponse {
            status_code: resp.status,
            body: resp.body,
            headers: resp.headers,
            url: resp.url,
        };
        serde_json::to_string(&result).map_err(|e| format!("post serialize error: {}", e))
    })
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};

    use super::*;

    /// 判断响应体是否为有效 JSON 对象（httpbin 风格回显；区分 404/错误页）
    fn is_valid_response(body: &str) -> bool {
        !body.is_empty() && body.trim_start().starts_with('{')
    }

    /// 本地回环 mock 服务器读到的一个 HTTP/1.1 请求
    struct MockRequest {
        method: String,
        path: String,
        query: String,
        headers: Vec<(String, String)>,
        body: String,
    }

    impl MockRequest {
        /// 请求头 → JSON 对象（/get、/headers 回显用；键保持服务器收到时的大小写）
        fn headers_json(&self) -> serde_json::Value {
            let mut map = serde_json::Map::new();
            for (k, v) in &self.headers {
                map.insert(k.clone(), serde_json::Value::String(v.clone()));
            }
            serde_json::Value::Object(map)
        }

        /// query 串 → args 映射（httpbin /get 回显用；值保持 URL 编码原样）
        fn args_json(&self) -> serde_json::Value {
            let mut map = serde_json::Map::new();
            for kv in self.query.split('&').filter(|s| !s.is_empty()) {
                let (k, v) = kv.split_once('=').unwrap_or((kv, ""));
                map.insert(k.to_string(), serde_json::Value::String(v.to_string()));
            }
            serde_json::Value::Object(map)
        }
    }

    /// 逐字节读取一个完整 HTTP/1.1 请求（头到 `\r\n\r\n` + Content-Length body）
    fn read_mock_http_request(sock: &mut std::net::TcpStream) -> Option<MockRequest> {
        let mut head: Vec<u8> = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            if sock.read_exact(&mut byte).is_err() {
                return None;
            }
            head.push(byte[0]);
            if head.len() > 65_536 {
                return None;
            }
        }
        let head_str = String::from_utf8_lossy(&head).into_owned();
        let mut lines = head_str.lines();
        let request_line = lines.next().unwrap_or_default();
        let mut parts = request_line.split_whitespace();
        let method = parts.next().unwrap_or("GET").to_uppercase();
        let target = parts.next().unwrap_or("/");
        let (path, query) = match target.split_once('?') {
            Some((p, q)) => (p, q),
            None => (target, ""),
        };
        let mut headers = Vec::new();
        for line in lines {
            if line.is_empty() {
                continue;
            }
            if let Some((k, v)) = line.split_once(':') {
                headers.push((k.trim().to_string(), v.trim().to_string()));
            }
        }
        let content_length = headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
            .and_then(|(_, v)| v.parse::<usize>().ok())
            .unwrap_or(0);
        let mut body_buf = vec![0u8; content_length];
        if content_length > 0 && sock.read_exact(&mut body_buf).is_err() {
            return None;
        }
        Some(MockRequest {
            method,
            path: path.to_string(),
            query: query.to_string(),
            headers,
            body: String::from_utf8_lossy(&body_buf).into_owned(),
        })
    }

    /// 最小本地回环 httpbin 风格 mock 服务器（本模块 10 例真联网用例的确定性替身，
    /// 替代 `https://httpbin.org/...`——外部 503/验证页/断网会让软断言用例静默通过）。
    ///
    /// 按用例实际断言逐一核对，复刻所需 httpbin 行为子集：
    /// - `GET /get`     → `{"url","args","headers","origin"}`（回显 query/请求头，httpbin 签名）
    /// - `GET /headers` → `{"headers":{...}}`（回显请求头）
    /// - `POST /post`   → `{"data","json","headers","url"}`（回显 body；body 为 JSON 时附解析结果）
    /// - HEAD 任意路由  → 200（仅响应头、无 body）
    /// - 其他路由       → 404 `{"error":"not found"}`（「故意破坏」对照用）
    ///
    /// std `TcpListener` + 单线程模式（与 `spawn_search_loopback_server` /
    /// `spawn_cookie_echo_server` 同款；legado-js 的 quickjs tokio feature 无 net）；
    /// 回环流量经 `no_proxy` 豁免系统/环境变量代理（P2-17 约定，见
    /// 回环共享池 `PoolKind::Loopback` / `PoolKind::NoRedirectLoopback`）。
    fn spawn_httpbin_mock(max_conns: usize) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let origin = addr.to_string();
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                let Some(req) = read_mock_http_request(&mut sock) else {
                    continue;
                };
                let (status, body) = if req.method == "HEAD" {
                    ("200 OK", String::new())
                } else if req.path == "/get" {
                    // httpbin /get 回显：url 为完整请求 URL，origin 为 host（去端口）
                    let host = origin.split_once(':').map_or(origin.as_str(), |(h, _)| h);
                    (
                        "200 OK",
                        serde_json::json!({
                            "url": format!("http://{origin}{path}", path = req.path),
                            "args": req.args_json(),
                            "headers": req.headers_json(),
                            "origin": host,
                        })
                        .to_string(),
                    )
                } else if req.path == "/headers" {
                    (
                        "200 OK",
                        serde_json::json!({ "headers": req.headers_json() }).to_string(),
                    )
                } else if req.path == "/post" {
                    let mut v = serde_json::json!({
                        "data": req.body,
                        "headers": req.headers_json(),
                        "url": format!("http://{origin}{}", req.path),
                    });
                    if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&req.body) {
                        v["json"] = parsed;
                    }
                    ("200 OK", v.to_string())
                } else {
                    ("404 Not Found", r#"{"error":"not found"}"#.to_string())
                };
                let resp = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
                    len = body.len()
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// 测试 http_get 基本请求（本地回环 mock：`/get` 回显 url/args/headers）
    #[test]
    fn test_http_get_basic() {
        let addr = spawn_httpbin_mock(4);
        let body =
            http_get(&format!("http://{addr}/get"), None).expect("http_get 到本地回环 mock 应成功");
        assert!(is_valid_response(&body), "响应应为 JSON 对象: {body}");
        assert!(body.contains("/get"), "回显 URL 应含请求路径: {body}");
        assert!(
            body.contains("\"url\""),
            "响应应含 httpbin 风格回显 url 字段: {body}"
        );
    }

    /// 测试 http_get 带自定义 headers（本地回环 mock：`/headers` 回显请求头）
    ///
    /// 头名大小写不敏感比对：reqwest 在 wire 上把请求头名小写化发送（hyper
    /// `HeaderName` 规范），mock 忠实回显 wire 形态（`x-custom-header`）；
    /// 原 httpbin 用例的客户端保留原始大小写，此处按 HTTP 头语义等价放宽。
    #[test]
    fn test_http_get_with_headers() {
        let addr = spawn_httpbin_mock(4);
        let headers = r#"{"X-Custom-Header": "test-value"}"#;
        let body = http_get(&format!("http://{addr}/headers"), Some(headers))
            .expect("http_get 到本地回环 mock 应成功");
        assert!(is_valid_response(&body), "响应应为 JSON 对象: {body}");
        let lower = body.to_ascii_lowercase();
        assert!(
            lower.contains("x-custom-header"),
            "响应应包含自定义请求头（大小写不敏感）: {body}"
        );
        assert!(
            lower.contains("test-value"),
            "响应应包含自定义请求头的值: {body}"
        );
    }

    /// 测试 http_post 基本请求（本地回环 mock：`/post` 回显 data/json）
    #[test]
    fn test_http_post_basic() {
        let addr = spawn_httpbin_mock(4);
        let body = http_post(
            &format!("http://{addr}/post"),
            r#"{"key": "value"}"#,
            Some(r#"{"Content-Type": "application/json"}"#),
        )
        .expect("http_post 到本地回环 mock 应成功");
        assert!(is_valid_response(&body), "响应应为 JSON 对象: {body}");
        assert!(!body.is_empty(), "POST 响应体不应为空");
        assert!(body.contains("key"), "响应应包含请求体中的 key: {body}");
        assert!(body.contains("value"), "响应应包含请求体中的 value: {body}");
    }

    /// 测试 http_head 返回 headers JSON（本地回环 mock：HEAD `/get`）
    #[test]
    fn test_http_head() {
        let addr = spawn_httpbin_mock(4);
        let headers_json =
            http_head(&format!("http://{addr}/get")).expect("http_head 到本地回环 mock 应成功");
        let parsed: HashMap<String, String> =
            serde_json::from_str(&headers_json).expect("httpHead 应返回有效 JSON");
        assert!(!parsed.is_empty(), "HEAD 响应应含响应头: {parsed:?}");
        assert!(
            parsed
                .keys()
                .any(|k| k.eq_ignore_ascii_case("content-type")),
            "应含 mock 服务器返回的 Content-Type 响应头: {parsed:?}"
        );
    }

    /// 测试 ajax 通用接口（GET，本地回环 mock：`/get` 回显）
    #[test]
    fn test_ajax_get() {
        let addr = spawn_httpbin_mock(4);
        let opts = serde_json::json!({
            "method": "GET",
            "url": format!("http://{addr}/get"),
            "headers": {"Accept": "application/json"}
        });
        let resp_json = ajax(&opts.to_string()).expect("ajax GET 到本地回环 mock 应成功");
        let resp: HttpResponse = serde_json::from_str(&resp_json).expect("ajax 响应应可解析");
        assert_eq!(
            resp.status_code, 200,
            "mock 服务器应返回 200: {}",
            resp.body
        );
        assert!(!resp.body.is_empty(), "GET 响应体不应为空");
        assert!(
            is_valid_response(&resp.body),
            "响应应为 JSON 对象: {}",
            resp.body
        );
        assert!(
            resp.body.contains("/get"),
            "回显 URL 应含请求路径: {}",
            resp.body
        );
    }

    /// 原版「url,{json}」格式外网诊断：依赖 httpbin.org，不能作为离线 CI 门禁。
    /// URL option 解析由本地 AnalyzeUrl/JS bridge 回归覆盖。
    #[test]
    #[ignore = "依赖 httpbin.org，外部 503/验证页会改变响应体格式"]
    fn test_ajax_url_option_format_returns_body() {
        let input =
            r#"https://httpbin.org/get,{"method":"GET","headers":{"Accept":"application/json"}}"#;
        let result = ajax(input);
        if let Ok(body) = result {
            let head: String = body.chars().take(80).collect();
            assert!(
                body.trim_start().starts_with('{'),
                "应返回纯响应体文本(JSON)，而非 HttpResponse 包装: {}",
                head
            );
        }
    }

    /// 测试 ajax 通用接口（POST，本地回环 mock：`/post` 回显 data/json）
    #[test]
    fn test_ajax_post() {
        let addr = spawn_httpbin_mock(4);
        let opts = serde_json::json!({
            "method": "POST",
            "url": format!("http://{addr}/post"),
            "body": "{\"hello\": \"world\"}",
            "headers": {"Content-Type": "application/json"},
            "timeout_ms": 10000
        });
        let resp_json = ajax(&opts.to_string()).expect("ajax POST 到本地回环 mock 应成功");
        let resp: HttpResponse = serde_json::from_str(&resp_json).expect("ajax 响应应可解析");
        assert_eq!(
            resp.status_code, 200,
            "mock 服务器应返回 200: {}",
            resp.body
        );
        assert!(
            resp.body.contains("hello"),
            "回显体应含请求字段 hello: {}",
            resp.body
        );
        assert!(
            resp.body.contains("world"),
            "回显体应含请求值 world: {}",
            resp.body
        );
    }

    /// 测试 ajax 空 URL 应报错
    #[test]
    fn test_ajax_empty_url() {
        let opts = r#"{"method": "GET", "url": ""}"#;
        let result = ajax(opts);
        assert!(result.is_err(), "空 URL 应返回错误");
        assert!(result.unwrap_err().contains("url is required"));
    }

    /// 测试 ajax 不支持的 HTTP 方法
    #[test]
    fn test_ajax_unsupported_method() {
        let opts = r#"{"method": "PATCH", "url": "https://httpbin.org/patch"}"#;
        let result = ajax(opts);
        assert!(result.is_err(), "PATCH 方法应返回错误");
        assert!(result.unwrap_err().contains("unsupported method"));
    }

    /// 测试 ajaxAll 批量并发请求（本地回环 mock：3 个并发 `/get` 回显）
    #[test]
    fn test_ajax_all() {
        let addr = spawn_httpbin_mock(8);
        let urls = serde_json::json!([
            format!("http://{addr}/get"),
            format!("http://{addr}/get"),
            format!("http://{addr}/get")
        ]);
        let results_json = ajax_all(&urls.to_string()).expect("ajaxAll 到本地回环 mock 应成功");
        let results: Vec<String> = serde_json::from_str(&results_json).expect("结果应可解析");
        assert_eq!(results.len(), 3, "应返回 3 个结果");
        for body in &results {
            assert!(
                is_valid_response(body),
                "每个响应体都应为 JSON 对象: {body}"
            );
            assert!(
                body.contains("/get"),
                "回显 URL 应含请求路径（httpbin 标识的本地等价物）: {body}"
            );
        }
    }

    /// 测试 ajaxAll 无效 JSON 输入
    #[test]
    fn test_ajax_all_invalid_json() {
        let result = ajax_all("not a json array");
        assert!(result.is_err(), "无效 JSON 应返回错误");
        assert!(result.unwrap_err().contains("parse error"));
    }

    /// 测试 parse_headers 解析正确 / 异常输入
    #[test]
    fn test_parse_headers() {
        let valid = r#"{"Authorization": "Bearer token123"}"#;
        let map = parse_headers(Some(valid));
        assert!(map.is_some());
        assert_eq!(
            map.unwrap().get("Authorization").unwrap(),
            "Bearer token123"
        );

        // 无效 JSON 返回 None
        let map = parse_headers(Some("not json"));
        assert!(map.is_none());

        // None 返回 None
        let map = parse_headers(None);
        assert!(map.is_none());
    }

    /// 四个进程级共享池均可构建，且重复取回同一实例（槽位注册表幂等，
    /// 2026-09-24 性能专项：不再每调用新建客户端/连接池）；reset 后四池
    /// 全部可重建（设计项 A）
    #[test]
    fn test_shared_client_pools() {
        let _lock = lock_pool_test();
        register_test_persistence();
        reset_shared_client_pools();
        for (loopback, no_redirect) in [(false, false), (true, false), (false, true), (true, true)]
        {
            assert!(
                shared_client(loopback, no_redirect).is_ok(),
                "共享池 (loopback={loopback}, no_redirect={no_redirect}) 应构建成功"
            );
        }
        // 幂等：两次取回共享同一实例（cookie_store 内部分配指针一致）
        let a = shared_client(false, false).expect("默认池");
        let b = shared_client(false, false).expect("默认池");
        assert!(
            std::ptr::eq(
                std::sync::Arc::as_ptr(a.cookie_store()),
                std::sync::Arc::as_ptr(b.cookie_store())
            ),
            "同一池两次取回应为同一实例（连接池复用前提）"
        );
        // 不同池互不相同
        let c = shared_client(true, false).expect("回环池");
        assert!(
            !std::ptr::eq(
                std::sync::Arc::as_ptr(a.cookie_store()),
                std::sync::Arc::as_ptr(c.cookie_store())
            ),
            "回环池与默认池应为不同实例"
        );
        // reset 后四池全部可重建（设计项 A：重建走当前持久化钩子）
        reset_shared_client_pools();
        for (loopback, no_redirect) in [(false, false), (true, false), (false, true), (true, true)]
        {
            assert!(
                shared_client(loopback, no_redirect).is_ok(),
                "reset 后共享池 (loopback={loopback}, no_redirect={no_redirect}) 应重建成功"
            );
        }
    }

    /// 共享池 keep-alive 复用证明（2026-09-24 性能专项）：
    /// 同一共享客户端连发 N 次 → 服务端仅 1 次 accept（池内 keep-alive 复用）；
    /// 每请求新建 LegadoClient → N 次 accept（修复前行为，回归对照）。
    /// HTTP 层计数等价反映 TLS 层成本：每新建连接 = 1 次 TCP + 1 次 TLS 握手。
    #[test]
    fn test_shared_pool_reuses_keep_alive() {
        let _lock = lock_pool_test();
        register_test_persistence();
        const N: usize = 5;
        let (addr, accepts) = spawn_counting_keep_alive_server(N + N + 2);
        let base = format!("http://{addr}/");

        // ① 共享客户端（回环池）连发 N 次：应仅 1 次 accept
        let client = shared_client_for_url(&base).expect("共享池");
        block_on(async {
            for _ in 0..N {
                let resp = client.get(&base, None).await.expect("共享池 GET 应成功");
                assert!(resp.status == 200, "状态码应为 200: {}", resp.status);
            }
        });
        let shared_accepts = accepts.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            shared_accepts, 1,
            "共享池 {N} 次请求应复用同一连接（1 次 accept），实测 {shared_accepts}"
        );

        // ② 每请求新建客户端（修复前行为）连发 N 次：应 N 次 accept
        block_on(async {
            for _ in 0..N {
                let fresh = LegadoClient::new(LegadoClientConfig {
                    no_proxy: true,
                    ..Default::default()
                })
                .expect("新建客户端");
                let resp = fresh.get(&base, None).await.expect("新建客户端 GET 应成功");
                assert!(resp.status == 200, "状态码应为 200: {}", resp.status);
            }
        });
        let total_accepts = accepts.load(std::sync::atomic::Ordering::SeqCst);
        assert_eq!(
            total_accepts,
            1 + N,
            "新建客户端 {N} 次请求应新建 {N} 连接（共 {N}+1 次 accept）"
        );
    }

    /// 最小 keep-alive 计数服务器：统计 accept 次数（连接数证据），
    /// 同一连接循环处理多个请求（HTTP/1.1 keep-alive）
    fn spawn_counting_keep_alive_server(
        max_conns: usize,
    ) -> (
        std::net::SocketAddr,
        std::sync::Arc<std::sync::atomic::AtomicUsize>,
    ) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let accepts = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counter = std::sync::Arc::clone(&accepts);
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                // keep-alive：同一连接循环处理请求，直到客户端关闭
                while let Some(req) = read_mock_http_request(&mut sock) {
                    let _body = if req.method == "HEAD" {
                        String::new()
                    } else {
                        "ok".to_string()
                    };
                    let resp = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: keep-alive\r\n\r\n{}",
                        _body.len(),
                        _body
                    );
                    if sock.write_all(resp.as_bytes()).is_err() {
                        break;
                    }
                }
            }
        });
        (addr, accepts)
    }

    // ── Cookie 持久化共享池（设计项 A，2026-09-26）─────────────────────
    //
    // 根因（`.tmp/engine_forensic_d/report_d.md` §2）：JS 桥池客户端此前
    // 仅内存 jar，冷启动即失 Set-Cookie 种下的 WAF 状态机 cookie，状态机
    // 跨进程断链（x81zws.com）。修复：池构建路径注入 CookiePersistence
    // 后端（first-wins），构建/重建时预载 + 写回。以下用例触碰进程级
    // 全局状态（池槽位 + 持久化钩子），统一持 POOL_TEST_LOCK 串行。

    /// 池用例串行锁（池槽位 + 持久化钩子为进程级共享）：串行化
    /// 「注册 → 请求 → 断言 → 重置」段，避免并行用例互相清掉对方的槽/行
    static POOL_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn lock_pool_test() -> std::sync::MutexGuard<'static, ()> {
        POOL_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// 内存版 CookiePersistence 测试替身（模拟 `legado-ffi::http_state::DbCookiePersistence`
    /// 的 DB 写回，不涉真实数据库）
    #[derive(Default)]
    struct RecordingPersistence {
        rows: std::sync::Mutex<HashMap<String, String>>,
    }

    impl RecordingPersistence {
        /// 预置一条持久化行（域键 → cookie 串）
        fn seed(&self, domain: &str, cookie: &str) {
            self.rows
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(domain.to_string(), cookie.to_string());
        }

        /// 读一条持久化行
        fn get(&self, domain: &str) -> Option<String> {
            self.rows
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .get(domain)
                .cloned()
        }

        /// 清空全部持久化行
        fn clear(&self) {
            self.rows.lock().unwrap_or_else(|p| p.into_inner()).clear();
        }
    }

    impl CookiePersistence for RecordingPersistence {
        fn load_all(&self) -> Vec<(String, String)> {
            self.rows
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .clone()
                .into_iter()
                .collect()
        }

        fn save(&self, tag: &str, cookie: &str) {
            self.rows
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(tag.to_string(), cookie.to_string());
        }
    }

    /// 进程级共享测试持久化实例：`set_client_cookie_persistence` 为
    /// first-wins，所有触碰池的用例必须共享同一实例（首注册胜者恒为该
    /// 共享实例，而非某用例的临时实例）
    static TEST_PERSISTENCE: OnceLock<Arc<RecordingPersistence>> = OnceLock::new();

    fn test_persistence() -> Arc<RecordingPersistence> {
        Arc::clone(TEST_PERSISTENCE.get_or_init(|| Arc::new(RecordingPersistence::default())))
    }

    /// 把共享测试实例注册进全局钩子（幂等；first-wins 返回值忽略）
    ///
    /// 传入的是 `test_persistence()` 克隆出的新 `Arc`（不独占 `OnceLock`
    /// 内实例的所有权），由参数位完成到 `Arc<dyn CookiePersistence>`
    /// 的 unsized 收敛。
    fn register_test_persistence() {
        let _ = set_client_cookie_persistence(test_persistence());
    }

    /// 最小 WAF 403 状态机 mock（设计项 A：模拟 x81zws 的 403+Set-Cookie
    /// 挑战；与 `spawn_cookie_echo_on` 同款 std `TcpListener` 模式）
    ///
    /// 行为：请求**不含** `p219_cold=WAF-VAL-7f3b` Cookie 时判为 WAF
    /// 挑战 → 403 + `Set-Cookie: p219_cold=WAF-VAL-7f3b; Path=/`（种下
    /// 状态机会话键，会话 cookie 无 Expires，照常被持久化）；含该
    /// Cookie 时判为状态机通过 → 200，并把 Cookie 请求头原样回显到
    /// `{"cookie":"<原值>"}`。
    fn spawn_waf_403_echo_server(max_conns: usize) -> std::net::SocketAddr {
        const WAF_COOKIE: &str = "p219_cold=WAF-VAL-7f3b";
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                // GET 请求无 body：读到 \r\n\r\n 即请求头结束
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    if sock.read_exact(&mut byte).is_err() {
                        break;
                    }
                    head.push(byte[0]);
                    if head.len() > 65_536 {
                        break;
                    }
                }
                let head_str = String::from_utf8_lossy(&head);
                let cookie_value = head_str.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.trim()
                        .eq_ignore_ascii_case("cookie")
                        .then(|| value.trim().to_string())
                });
                let (status, set_cookie_line, body) = match cookie_value {
                    Some(v) if v.contains(WAF_COOKIE) => (
                        "200 OK",
                        String::new(),
                        format!(
                            r#"{{"cookie":{}}}"#,
                            serde_json::to_string(&v).expect("cookie value 序列化")
                        ),
                    ),
                    _ => (
                        "403 Forbidden",
                        format!("Set-Cookie: {WAF_COOKIE}; Path=/\r\n"),
                        r#"{"error":"waf"}"#.to_string(),
                    ),
                };
                let resp = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\n{set_cookie_line}Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// 设计项 A 钩子 first-wins 语义：二次注册返回 false 且不覆盖首实例；
    /// reset 重建后装入的客户端仍指向首注册实例
    #[test]
    fn test_set_client_cookie_persistence_first_wins() {
        let _lock = lock_pool_test();
        register_test_persistence();
        // 二次注册（临时实例）必须被忽略
        assert!(
            !set_client_cookie_persistence(Arc::new(RecordingPersistence::default())),
            "二次注册应返回 false（first-wins，不覆盖）"
        );
        // reset 重建：装入的客户端仍指向首注册实例
        let before = shared_client(true, false).expect("回环池（首次构建）");
        reset_shared_client_pools();
        let after = shared_client(true, false).expect("回环池（reset 后重建）");
        assert!(
            !std::ptr::eq(
                std::sync::Arc::as_ptr(before.cookie_store()),
                std::sync::Arc::as_ptr(after.cookie_store())
            ),
            "reset 后池应重建新客户端"
        );
        let bound = after
            .cookie_persistence()
            .expect("注册持久化后，池客户端必须携带持久化后端");
        let shared: Arc<dyn CookiePersistence> = test_persistence();
        assert!(
            Arc::ptr_eq(bound, &shared),
            "客户端应指向首注册实例（未被二次注册覆盖）"
        );
    }

    /// 设计项 A 冷启动恢复：403+Set-Cookie 种下状态机 cookie → 写回持久化
    /// 后端 → reset 重建（冷启动模拟）→ 新客户端同域请求携带该 cookie
    /// 通过状态机（200）；P2-19 反例：不相关域（::1 自键 ≠ 127.0.0.1）
    /// 请求头绝不携带
    #[test]
    fn test_persistence_cold_start_same_domain_carried_foreign_never() {
        let _lock = lock_pool_test();
        let fake = test_persistence();
        register_test_persistence();
        fake.clear();
        reset_shared_client_pools();

        let addr = spawn_waf_403_echo_server(4);
        let url = format!("http://{addr}/waf");

        // ① 初始态（无 cookie）：WAF 挑战 403 + Set-Cookie 种状态机
        let client1 = shared_client(true, false).expect("回环池（首次构建）");
        let resp1 =
            block_on(async { client1.get(&url, None).await }).expect("首请求应成功（403 非错误）");
        assert_eq!(
            resp1.status, 403,
            "无状态机 cookie 时 WAF 应回 403 挑战: {}",
            resp1.status
        );

        // 写回证据：持久化后端必须持有该域 cookie 行（含会话 cookie）
        let row = fake
            .get("127.0.0.1")
            .expect("Set-Cookie 写回必须进持久化后端（会话 cookie 也持久化）");
        assert!(
            row.contains("p219_cold=WAF-VAL-7f3b"),
            "持久化行必须含 WAF 状态机键: {row}"
        );

        // ② 冷启动模拟：重置池 → 重建（新客户端 jar 从持久化后端预载）
        reset_shared_client_pools();
        let client2 = shared_client(true, false).expect("回环池（冷启动重建）");

        // 同域（127.0.0.1）请求必须携带重载的 cookie → 状态机通过 200
        let resp2 =
            block_on(async { client2.get(&url, None).await }).expect("第二请求（冷启动后）应成功");
        assert_eq!(
            resp2.status, 200,
            "冷启动重建后应携带重载 cookie 通过状态机（200）: {}",
            resp2.status
        );
        assert!(
            resp2.body.contains("p219_cold=WAF-VAL-7f3b"),
            "回显 Cookie 头必须含 WAF 状态机键（同域携带证据）: {}",
            resp2.body
        );

        // P2-19 反例（真实请求）：不相关域 ::1（IP 字面量自键 ≠ 127.0.0.1）
        // 请求头不携带该域 cookie
        let foreign_addr = spawn_ipv6_cookie_echo_server(1);
        let foreign_url = format!("http://{foreign_addr}/echo");
        let resp_foreign =
            block_on(async { client2.get(&foreign_url, None).await }).expect("不相关域请求应成功");
        let echoed: serde_json::Value =
            serde_json::from_str(&resp_foreign.body).expect("回显体 JSON");
        let foreign_cookie = echoed
            .get("cookie")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        assert!(
            !foreign_cookie.contains("p219_cold"),
            "不相关域（::1）请求头不携带 127.0.0.1 域 cookie（P2-19 不变式：\
             cookie 持久化与取用一律走 ETLD+1 归一域键，禁止整包跨域注入）: {foreign_cookie}"
        );

        // P2-19 反例（jar 层）：重建后客户端 jar 在不相关域不可见该 cookie
        let foreign_view = client2
            .cookie_store()
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .get_cookie_string("http://[::1]:1/");
        assert!(
            !foreign_view.contains("p219_cold"),
            "重建 jar 的不相关域 cookie 应为空（IP 字面量自键 ::1 ≠ 127.0.0.1）: {foreign_view}"
        );

        // 收尾：清共享实例并重置池（不留残留给后续用例）
        fake.clear();
        reset_shared_client_pools();
    }

    /// 未注册路径回归：不触碰全局钩子时，显式 `None` 构建等价改造前
    /// `LegadoClient::new`（无持久化后端、jar 为空）；注册路径则预载后端行
    #[test]
    fn test_pool_build_without_persistence_is_plain_new() {
        let client = build_pool_client_with(PoolKind::Default, None).expect("未注册路径构建应成功");
        assert!(
            client.cookie_persistence().is_none(),
            "未注册路径不得携带持久化后端（等价改造前 LegadoClient::new）"
        );
        let store = client
            .cookie_store()
            .read()
            .unwrap_or_else(|p| p.into_inner());
        assert_eq!(
            store.get_cookie_string("http://127.0.0.1:1/"),
            "",
            "未注册路径 jar 应为空"
        );
        drop(store);

        let fake = RecordingPersistence::default();
        fake.seed("127.0.0.1", "legacy_check=OK-1");
        let persistence: Arc<dyn CookiePersistence> = Arc::new(fake);
        let client2 = build_pool_client_with(PoolKind::Loopback, Some(persistence))
            .expect("注册路径构建应成功");
        assert!(
            client2.cookie_persistence().is_some(),
            "注册路径必须携带持久化后端"
        );
        let store = client2
            .cookie_store()
            .read()
            .unwrap_or_else(|p| p.into_inner());
        assert!(
            store
                .get_cookie_string("http://127.0.0.1:1/")
                .contains("legacy_check=OK-1"),
            "注册路径构建必须预载持久化 cookie 进 jar"
        );
    }

    /// 测试 connect_full 不支持的 HTTP 方法
    #[test]
    fn test_connect_full_unsupported_method() {
        let result = connect_full("https://httpbin.org/get", Some("PATCH"), None, None, None);
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("unsupported method"));
    }

    /// 测试 connect_full GET 请求（返回完整响应 JSON，本地回环 mock：`/get` 回显）
    #[test]
    fn test_connect_full_get() {
        let addr = spawn_httpbin_mock(4);
        let resp_json = connect_full(
            &format!("http://{addr}/get"),
            Some("GET"),
            None,
            None,
            Some(10000),
        )
        .expect("connect_full GET 到本地回环 mock 应成功");
        let resp: HttpResponse = serde_json::from_str(&resp_json).expect("响应应可解析");
        assert_eq!(
            resp.status_code, 200,
            "mock 服务器应返回 200: {}",
            resp.body
        );
        assert!(!resp.body.is_empty(), "GET 响应体不应为空");
        assert!(
            is_valid_response(&resp.body),
            "响应应为 JSON 对象: {}",
            resp.body
        );
    }

    /// 测试 head_full 返回完整响应 JSON（本地回环 mock：HEAD `/get`）
    #[test]
    fn test_head_full() {
        let addr = spawn_httpbin_mock(4);
        let resp_json = head_full(&format!("http://{addr}/get"), None)
            .expect("head_full 到本地回环 mock 应成功");
        let resp: HttpResponse = serde_json::from_str(&resp_json).expect("响应应可解析");
        assert_eq!(
            resp.status_code, 200,
            "HEAD 请求应得到 200 状态码（mock 服务器行为）"
        );
    }

    /// 测试 post_full 返回完整响应 JSON
    ///
    /// 目标必须是 httpbin `/post`（POST `/get` 返回 405，200 守卫恒不成立，
    /// 断言空转——P2-19 审查发现）；本地 mock 同样只对 `/post` 回显。
    #[test]
    fn test_post_full() {
        let addr = spawn_httpbin_mock(4);
        let resp_json = post_full(
            &format!("http://{addr}/post"),
            r#"{"key":"value"}"#,
            Some(r#"{"Content-Type":"application/json"}"#),
        )
        .expect("post_full 到本地回环 mock 应成功");
        let resp: HttpResponse = serde_json::from_str(&resp_json).expect("响应应可解析");
        assert_eq!(
            resp.status_code, 200,
            "mock 服务器应返回 200: {}",
            resp.body
        );
        // mock /post 回显请求 JSON（`data`/`json` 字段），`key` 必须出现
        assert!(
            resp.body.contains("key"),
            "回显体应含请求字段 key: {}",
            resp.body
        );
    }

    /// 最小本地回环 Cookie 回显服务器（P2-19 泄漏复现的确定性替身）
    ///
    /// 行为：把收到的 `Cookie` **请求头**原样回显到 200 响应体的
    /// `{"cookie":"<原值>"}`；请求不带 Cookie 头时回显 `{"cookie":null}`。
    ///
    /// 与 P2-17 的 `spawn_search_loopback_server` 同款 std `TcpListener` 模式
    /// （legado-js 的 quickjs tokio feature 无 net）；回环流量经 `no_proxy`
    /// 豁免系统/环境变量代理（见回环共享池 `PoolKind::Loopback` /
    /// connectNR 约定）。
    fn spawn_cookie_echo_server(max_conns: usize) -> std::net::SocketAddr {
        spawn_cookie_echo_on("127.0.0.1:0", max_conns)
    }

    /// IPv6 回环 `[::1]` 版 Cookie 回显服务器（设计项 A 的 P2-19 反例
    /// 用：`::1` 的 IP 字面量自键 ≠ `127.0.0.1`，为真正的不相关域）
    fn spawn_ipv6_cookie_echo_server(max_conns: usize) -> std::net::SocketAddr {
        spawn_cookie_echo_on("[::1]:0", max_conns)
    }

    /// 回显服务器通用实现（绑定地址参数化：`127.0.0.1:0` / `[::1]:0`）
    fn spawn_cookie_echo_on(bind_addr: &str, max_conns: usize) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind(bind_addr)
            .unwrap_or_else(|_| panic!("bind {bind_addr} 失败"));
        let addr = listener.local_addr().expect("local_addr");
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
                // GET 请求无 body：读到 \r\n\r\n 即请求头结束
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    if sock.read_exact(&mut byte).is_err() {
                        break;
                    }
                    head.push(byte[0]);
                    if head.len() > 65_536 {
                        break;
                    }
                }
                let head_str = String::from_utf8_lossy(&head);
                // 头名忽略大小写匹配，但**保留 Cookie 值原样**（回显必须逐字节忠实，
                // 否则断言会因大小写失真误判）
                let cookie_value = head_str.lines().find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.trim()
                        .eq_ignore_ascii_case("cookie")
                        .then(|| value.trim().to_string())
                });
                let body = match cookie_value {
                    Some(value) => format!(
                        r#"{{"cookie":{}}}"#,
                        serde_json::to_string(&value).expect("cookie value 序列化")
                    ),
                    None => r#"{"cookie":null}"#.to_string(),
                };
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// 回环回显用例共享的串行锁（跨测试模块——回环域名键 `127.0.0.1` 同时被
    /// source_engine.rs 等模块的回环用例共用）：cookie 全局存储为进程级共享，
    /// 锁串行化「写 → 请求 → 断言 → 清理」段，避免并行用例互相清掉对方的键
    ///（中毒恢复语义同 `legado-ffi::test_support::GLOBAL_STORE_TEST_LOCK`）。
    fn lock_cookie_echo_test() -> std::sync::MutexGuard<'static, ()> {
        crate::host_api::cookie_store::lock_cookie_store_test()
    }

    /// P2-19「跨源不泄漏」用例**改写为上游语义**（2026-09-23 用户裁决：同步上游
    /// 「cookie 属于域名，不属于书源」）：
    /// - 同域共享：向回环域（IP 字面量自键 `127.0.0.1`）写一次 cookie，
    ///   在**不同书源上下文**（TAG_A / TAG_B）发同一回环请求，均必须携带——
    ///   cookie 取用口径是「请求 URL 属域」，与书源 tag 无关（原「tag 维度」
    ///   语义已废）；
    /// - P2-19 不变式保留：异域（`f.book.com.cn`）写入的 cookie **绝不携带**
    ///   进回环请求。
    ///
    /// 原用例断言「源 B 的 cookie 不得出现在源 A 的请求头」；新口径下源 A/B 的
    /// book.com.cn 域 cookie 本就不属回环域，故改写为「异域不携带」+「同域共享」。
    #[test]
    fn test_p219_ajax_cookie_same_domain_shared_foreign_never_carried() {
        use crate::host_api::{cookie_store, current_source};

        const TAG_A: &str = "https://www.a.book.com.cn/";
        const TAG_B: &str = "https://www.b.book.com.cn/";
        const FOREIGN_URL: &str = "https://www.f.book.com.cn/";
        const FOREIGN_KEY: &str = "f.book.com.cn"; // com.cn 多段 TLD → 末三段

        let addr = spawn_cookie_echo_server(4);
        let loopback_key = format!("http://{addr}/"); // 归一后域名键 = "127.0.0.1"
        let _lock = lock_cookie_echo_test();
        cookie_store::clear_cookies(&loopback_key);
        cookie_store::clear_cookies(FOREIGN_URL);
        cookie_store::clear_cookies(FOREIGN_KEY);
        cookie_store::set_cookie(&loopback_key, "p219_sync", "SYNC-VAL-1f8a");
        // 异域 cookie：绝不泄漏进回环请求（P2-19 不变式）
        cookie_store::set_cookie(FOREIGN_URL, "p219_foreign", "F-VAL-6c2e");

        // 书源 A 上下文
        let resp_a = current_source::with_current_source_tag(TAG_A, || {
            ajax(&format!(r#"{{"url":"http://{addr}/echo"}}"#))
                .expect("ajax to loopback cookie-echo server (tag A)")
        });
        // 书源 B 上下文：同一请求 URL → 同域 cookie 跨书源共享
        let resp_b = current_source::with_current_source_tag(TAG_B, || {
            ajax(&format!(r#"{{"url":"http://{addr}/echo"}}"#))
                .expect("ajax to loopback cookie-echo server (tag B)")
        });

        cookie_store::clear_cookies(&loopback_key);
        cookie_store::clear_cookies(FOREIGN_URL);
        cookie_store::clear_cookies(FOREIGN_KEY);
        drop(_lock);

        for (ctx, resp_json) in [("A", resp_a), ("B", resp_b)] {
            let resp: HttpResponse = serde_json::from_str(&resp_json).expect("ajax 响应 JSON");
            assert_eq!(resp.status_code, 200, "回显服务器应返回 200: {}", resp.body);
            let echoed: serde_json::Value = serde_json::from_str(&resp.body).expect("回显体 JSON");
            let cookie_str = echoed
                .get("cookie")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            assert!(
                cookie_str.contains("p219_sync=SYNC-VAL-1f8a"),
                "同域（回环）cookie 必须跨书源共享（上游语义：cookie 属于域名），\
                 书源 {ctx} 上下文实际 Cookie 为: {cookie_str}"
            );
            assert!(
                !cookie_str.contains("p219_foreign"),
                "异域 cookie 绝不携带（P2-19 不变式），书源 {ctx} 上下文实际 Cookie 为: {cookie_str}"
            );
        }
    }

    /// P2-19「未归属不携带」用例**改写为上游语义**（2026-09-23 用户裁决：同步上游，
    /// 本批取消 P2-19 的「未归属不携带」收紧）：未归属上下文（字典规则/自动任务
    /// 等无书源绑定的 JS 执行路径）向某域发请求时，**仍必须携带该域 cookie**——
    /// 上游 `CookieManager.loadRequest` 按**请求 URL** 取 cookie，与书源上下文无关。
    /// 异域（x/y.book.com.cn）cookie 依旧绝不携带（P2-19 不变式保留）。
    #[test]
    fn test_p219_ajax_cookie_unowned_carries_request_domain_cookie() {
        use crate::host_api::{cookie_store, current_source};

        const TAG_X: &str = "https://www.x.book.com.cn/";
        const TAG_Y: &str = "https://www.y.book.com.cn/";
        const DK_X: &str = "x.book.com.cn"; // com.cn 多段 TLD → 末三段
        const DK_Y: &str = "y.book.com.cn";

        let addr = spawn_cookie_echo_server(2);
        let loopback_key = format!("http://{addr}/"); // 归一后域名键 = "127.0.0.1"
        let _lock = lock_cookie_echo_test();
        cookie_store::clear_cookies(&loopback_key);
        cookie_store::clear_cookies(TAG_X);
        cookie_store::clear_cookies(TAG_Y);
        cookie_store::clear_cookies(DK_X);
        cookie_store::clear_cookies(DK_Y);
        cookie_store::set_cookie(&loopback_key, "p219_unowned", "UN-VAL-3d9e");
        // 异域 cookie：未归属请求异域时依旧绝不携带
        cookie_store::set_cookie(TAG_X, "p219_tokenX", "X-VAL-5e2b");
        cookie_store::set_cookie(TAG_Y, "p219_tokenY", "Y-VAL-c44a");

        current_source::clear_current_source_tag(); // 确保未归属
        let resp_json = ajax(&format!(r#"{{"url":"http://{addr}/echo"}}"#))
            .expect("ajax to loopback cookie-echo server");

        cookie_store::clear_cookies(&loopback_key);
        cookie_store::clear_cookies(TAG_X);
        cookie_store::clear_cookies(TAG_Y);
        cookie_store::clear_cookies(DK_X);
        cookie_store::clear_cookies(DK_Y);
        drop(_lock);

        let resp: HttpResponse = serde_json::from_str(&resp_json).expect("ajax 响应 JSON");
        assert_eq!(resp.status_code, 200, "回显服务器应返回 200: {}", resp.body);
        let echoed: serde_json::Value = serde_json::from_str(&resp.body).expect("回显体 JSON");
        let cookie_str = echoed
            .get("cookie")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        assert!(
            cookie_str.contains("p219_unowned=UN-VAL-3d9e"),
            "未归属上下文请求回环域时必须携带该域 cookie（上游语义，本批取消收紧），实际: {cookie_str}"
        );
        assert!(
            !cookie_str.contains("p219_tokenX") && !cookie_str.contains("p219_tokenY"),
            "异域 cookie 绝不携带（P2-19 不变式），实际: {cookie_str}"
        );
    }

    /// `merge_global_cookie` 单元口径（上游同步改写）：Cookie 头按**请求 URL** 的
    /// 属域取（不再按当前书源 tag）——请求 URL 属域写过的 cookie 必须携带，
    /// 不相关域名的 cookie 绝不注入（P2-19 不变式）。不走真实网络，确定性快。
    #[test]
    fn test_merge_global_cookie_keyed_by_request_url() {
        use crate::host_api::{cookie_store, current_source};

        let _lock = cookie_store::lock_cookie_store_test();

        // book.com.cn（com.cn 多段 TLD → 末三段）与 other-site.com（.com 末两段）
        const REQ_URL: &str = "https://unit-a.book.com.cn/page";
        const OTHER_URL: &str = "https://unit-b.other-site.com/page";
        const DK_A: &str = "book.com.cn";
        const DK_B: &str = "other-site.com";

        cookie_store::clear_cookies(REQ_URL);
        cookie_store::clear_cookies(OTHER_URL);
        cookie_store::clear_cookies(DK_A);
        cookie_store::clear_cookies(DK_B);
        cookie_store::set_cookie(REQ_URL, "p219_uA", "uA-val");
        cookie_store::set_cookie(OTHER_URL, "p219_uB", "uB-val");

        current_source::clear_current_source_tag();
        let headers_a = merge_global_cookie(HashMap::new(), REQ_URL);
        let headers_b = merge_global_cookie(HashMap::new(), OTHER_URL);

        cookie_store::clear_cookies(REQ_URL);
        cookie_store::clear_cookies(OTHER_URL);
        cookie_store::clear_cookies(DK_A);
        cookie_store::clear_cookies(DK_B);

        let cookie_a = headers_a.get("Cookie").cloned().unwrap_or_default();
        assert!(
            cookie_a.contains("p219_uA=uA-val"),
            "请求 URL 属域写过的 cookie 必须携带: {cookie_a}"
        );
        assert!(
            !cookie_a.contains("p219_uB"),
            "不相关域名的 cookie 绝不携带（P2-19 不变式）: {cookie_a}"
        );
        let cookie_b = headers_b.get("Cookie").cloned().unwrap_or_default();
        assert!(
            cookie_b.contains("p219_uB=uB-val"),
            "请求 URL 属域写过的 cookie 必须携带: {cookie_b}"
        );
        assert!(
            !cookie_b.contains("p219_uA"),
            "不相关域名的 cookie 绝不携带（P2-19 不变式）: {cookie_b}"
        );
    }

    /// 未归属上下文单元口径（上游同步改写）：Cookie 头按**请求 URL** 属域取——
    /// 请求 URL 属域未写过 cookie 时不注入 Cookie 头（异域已写入的 cookie
    /// 绝不注入，P2-19 不变式）。用例域为独有域名，避免与并行用例共享键。
    #[test]
    fn test_merge_global_cookie_unowned_no_cookie_for_unwritten_domain() {
        use crate::host_api::{cookie_store, current_source};

        let _lock = cookie_store::lock_cookie_store_test();

        // 独有域名（本用例专用，不与其它并行用例共享键）
        const WRITE_URL: &str = "https://unitz.unitzeta.com/"; // → 域名键 unitzeta.com
        const REQ_URL: &str = "https://unitq.uniteta.com/x"; // → 域名键 uniteta.com
        const DK_WRITE: &str = "unitzeta.com";
        const DK_REQ: &str = "uniteta.com";

        cookie_store::clear_cookies(WRITE_URL);
        cookie_store::clear_cookies(DK_WRITE);
        cookie_store::clear_cookies(DK_REQ);
        cookie_store::set_cookie(WRITE_URL, "p219_uZ", "uZ-val");

        current_source::clear_current_source_tag(); // 确保未归属
        let headers = merge_global_cookie(HashMap::new(), REQ_URL);
        cookie_store::clear_cookies(WRITE_URL);
        cookie_store::clear_cookies(DK_WRITE);
        cookie_store::clear_cookies(DK_REQ);

        assert!(
            !headers.contains_key("Cookie"),
            "请求 URL 属域未写过 cookie 时不得注入 Cookie 头（异域 cookie 绝不注入）: {:?}",
            headers.get("Cookie")
        );
    }
}
