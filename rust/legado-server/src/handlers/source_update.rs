//! 书源在线更新处理器
//!
//! 提供书源仓库管理与在线更新能力：
//! - GET /api/sources/repos — 获取书源仓库列表
//! - GET /api/sources/updates — 检查书源更新
//! - POST /api/sources/update — 执行更新

use axum::extract::State;
use axum::http::StatusCode;
use axum::Json;
use legado_core::models::BookSource;
use reqwest::dns::{Addrs, Name, Resolve, Resolving};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::future::Future;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use legado_db::repository::book_source_repository::BookSourceRepository;
use legado_db::repository::Repository;

use crate::error::ApiError;
use crate::state::AppState;

/// 书源仓库信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceRepo {
    /// 仓库名称
    pub name: String,
    /// 仓库 URL（指向书源 JSON 文件）
    pub url: String,
    /// 仓库描述
    pub description: String,
}

/// 默认书源仓库列表
fn default_repos() -> Vec<SourceRepo> {
    vec![
        SourceRepo {
            name: "Legado 官方书源".to_string(),
            url: "https://raw.githubusercontent.com/gedoor/legado/master/app/src/main/assets/defaultData/bookSource.json".to_string(),
            description: "Legado 官方默认书源集合".to_string(),
        },
        SourceRepo {
            name: "网络精品书源".to_string(),
            url: "https://cdn.jsdelivr.net/gh/XIU2/Yuedu@master/bookSource.json".to_string(),
            description: "社区维护的精品书源合集".to_string(),
        },
    ]
}

/// 书源更新信息
#[derive(Debug, Clone, Serialize)]
pub struct SourceUpdateInfo {
    /// 书源 URL
    pub source_url: String,
    /// 书源名称
    pub source_name: String,
    /// 本地最后更新时间
    pub local_update_time: i64,
    /// 远程最后更新时间
    pub remote_update_time: i64,
    /// 是否需要更新
    pub need_update: bool,
}

/// 更新检查结果
#[derive(Debug, Serialize)]
pub struct UpdateCheckResult {
    /// 仓库名称
    pub repo_name: String,
    /// 仓库 URL
    pub repo_url: String,
    /// 远程书源总数
    pub remote_total: usize,
    /// 需要更新的书源列表
    pub updates: Vec<SourceUpdateInfo>,
    /// 新增书源数（本地不存在）
    pub new_count: usize,
    /// 检查是否成功
    pub success: bool,
    /// 错误信息
    pub error: Option<String>,
}

/// 执行更新请求体
#[derive(Debug, Deserialize)]
pub struct UpdateRequest {
    /// 仓库 URL（从哪个仓库更新）
    pub repo_url: String,
    /// 是否仅更新已有书源（false 则同时导入新书源）
    #[serde(default)]
    pub only_update_existing: bool,
}

/// 更新执行结果
#[derive(Debug, Serialize)]
pub struct UpdateResult {
    /// 更新成功的书源数
    pub updated: usize,
    /// 新增的书源数
    pub added: usize,
    /// 跳过的书源数
    pub skipped: usize,
    /// 失败的书源数
    pub failed: usize,
    /// 错误信息列表
    pub errors: Vec<String>,
}

/// GET /api/sources/repos — 获取书源仓库列表
pub async fn list_repos() -> Json<Value> {
    let repos = default_repos();
    Json(json!({ "repos": repos, "total": repos.len() }))
}

/// 测试专用：`check_updates` 使用的仓库列表覆盖（离线化外部抓取）
///
/// 生产行为不变：未设置覆盖时 [`active_repos`] 返回 [`default_repos`]。
/// 测试经 [`set_test_repos`] 注入本地回环仓库（Drop 守卫自动还原，
/// panic 亦不泄漏到并行用例），把原本对 raw.githubusercontent.com /
/// cdn.jsdelivr.net 的真联网检查变成确定性回环检查。
#[cfg(test)]
static TEST_REPOS_OVERRIDE: std::sync::Mutex<Option<Vec<SourceRepo>>> = std::sync::Mutex::new(None);

/// 测试专用守卫：离开作用域（含 panic）自动还原仓库覆盖
#[cfg(test)]
struct TestReposGuard;

#[cfg(test)]
impl Drop for TestReposGuard {
    fn drop(&mut self) {
        *TEST_REPOS_OVERRIDE.lock().unwrap() = None;
    }
}

/// 测试专用：覆盖 `check_updates` 使用的仓库列表，返回 Drop 守卫
#[cfg(test)]
fn set_test_repos(repos: Vec<SourceRepo>) -> TestReposGuard {
    *TEST_REPOS_OVERRIDE.lock().unwrap() = Some(repos);
    TestReposGuard
}

/// `check_updates` 使用的仓库列表：测试覆盖优先，生产恒为默认仓库
fn active_repos() -> Vec<SourceRepo> {
    #[cfg(test)]
    if let Some(repos) = TEST_REPOS_OVERRIDE.lock().unwrap().clone() {
        return repos;
    }
    default_repos()
}

/// 仓库 URL 是否指向本地回环（127.0.0.1 / localhost，测试注入的本地 mock）
fn is_loopback_repo_url(url: &str) -> bool {
    url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost")
}

/// 校验 `/api/sources/update` 的 `repo_url` 字面量部分（审查批 P1-1）
///
/// 只允许 `http`/`https`；拒绝本机与内网/保留地址的字面量形态（`localhost`、
/// `127.0.0.1`、`10.x`、`172.16-31.x`、`192.168.x`、`169.254.x`、
/// `100.64.0.0/10`（含云元数据 `100.100.100.200`）、`192.0.0.0/24`、
/// `198.18.0.0/15`、`240.0.0.0/4`、`::1`、`fc00::/7`、`fe80::/10`、
/// IPv4-mapped 回环等）。
///
/// 本函数**不做** DNS 解析（同步、可在 reqwest 重定向策略里逐跳调用）；
/// 域名的解析级复核见 [`validate_repo_url`]，连接期的解析复核见
/// [`SsrfGuardResolver`]。
fn validate_repo_url_literal(raw: &str) -> Result<reqwest::Url, String> {
    let url = reqwest::Url::parse(raw).map_err(|e| format!("仓库地址无效: {e}"))?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(format!(
            "仓库地址仅支持 http/https，实际为 {}",
            url.scheme()
        ));
    }
    match url.host() {
        Some(url::Host::Domain(domain)) => {
            let lowered = normalize_host(domain);
            if lowered == "localhost" || lowered.ends_with(".localhost") {
                return Err(format!("仓库地址不允许指向本机: {domain}"));
            }
        }
        Some(url::Host::Ipv4(ip)) => {
            if is_disallowed_ip(IpAddr::V4(ip)) {
                return Err(format!("仓库地址不允许指向内网/保留地址: {ip}"));
            }
        }
        Some(url::Host::Ipv6(ip)) => {
            if is_disallowed_ip(IpAddr::V6(ip)) {
                return Err(format!("仓库地址不允许指向内网/保留地址: {ip}"));
            }
        }
        None => return Err("仓库地址缺少主机名".to_string()),
    }
    Ok(url)
}

/// 主机名归一化：小写 + 去掉末尾根域点（`EXAMPLE.COM.` → `example.com`）
fn normalize_host(domain: &str) -> String {
    domain
        .to_ascii_lowercase()
        .trim_end_matches('.')
        .to_string()
}

/// 校验 `/api/sources/update` 的 `repo_url`（R06：字面量 + DNS 解析级复核）
///
/// 在 [`validate_repo_url_literal`] 的字面量校验之上补一层解析级校验：
/// 域名的**每一条** A/AAAA 记录都必须通过 [`is_disallowed_ip`]，任一命中
/// 内网/保留地址即拒绝（防「公网域名解析到 127.0.0.1 / 192.168.x.x /
/// 169.254.169.254 云元数据」的 SSRF 与 DNS rebinding 前置探测）。
///
/// 解析失败与解析结果为空均**保守拒绝**（fail-closed）：无法证明目标不是
/// 内网，就不放行。
///
/// 本函数只负责「请求发起前」的早拒绝（返回 400）；真正阻止 TOCTOU 的是
/// 客户端挂载的 [`SsrfGuardResolver`]——它在每次建连时重新解析并复核，
/// 且校验用的 IP 就是实际连接的 IP，重定向的每一跳同样经过它。
async fn validate_repo_url(raw: &str) -> Result<reqwest::Url, String> {
    validate_repo_url_with(raw, &SystemDnsResolver).await
}

/// [`validate_repo_url`] 的可注入版本（测试注入固定解析结果，不依赖外网）
async fn validate_repo_url_with<R: RepoDnsResolver>(
    raw: &str,
    resolver: &R,
) -> Result<reqwest::Url, String> {
    let url = validate_repo_url_literal(raw)?;
    if let Some(url::Host::Domain(domain)) = url.host() {
        let normalized = normalize_host(domain);
        let ips = resolver
            .resolve(&normalized)
            .await
            .map_err(|e| format!("仓库地址无法解析: {domain}（{e}）"))?;
        check_resolved_ips(&normalized, &ips)?;
    }
    Ok(url)
}

// ─── R06：DNS 解析抽象与 SSRF 连接期守卫 ─────────────────────────────

/// 域名解析抽象（可注入）
///
/// 生产实现 [`SystemDnsResolver`]：先查 `setCustomHosts` 映射，未命中回落
/// 系统 DNS。测试注入 `tests::FixedDnsResolver` 固定结果，用例不依赖外网。
trait RepoDnsResolver: Send + Sync {
    fn resolve<'a>(
        &'a self,
        domain: &'a str,
    ) -> std::pin::Pin<Box<dyn Future<Output = Result<Vec<IpAddr>, String>> + Send + 'a>>;
}

/// 生产解析器：`setCustomHosts` 覆盖优先，未命中回落系统 DNS
///
/// 系统解析带 5s 上限：本解析发生在请求发起**之前**（客户端的 60s 超时
/// 尚未生效），DNS 服务器无响应时不能让 handler 无限挂起。
struct SystemDnsResolver;

/// 系统 DNS 解析上限（解析级校验发生在客户端超时生效之前）
const DNS_RESOLVE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

impl RepoDnsResolver for SystemDnsResolver {
    fn resolve<'a>(
        &'a self,
        domain: &'a str,
    ) -> std::pin::Pin<Box<dyn Future<Output = Result<Vec<IpAddr>, String>> + Send + 'a>> {
        Box::pin(async move {
            // 与 `legado_net::custom_hosts::resolver()` 同一优先级：
            // 用户显式 hosts 映射（本地配置）优先于系统 DNS
            if let Some(ips) = legado_net::custom_hosts::lookup_ips(domain) {
                return Ok(ips);
            }
            let addrs =
                tokio::time::timeout(DNS_RESOLVE_TIMEOUT, tokio::net::lookup_host((domain, 0u16)))
                    .await
                    .map_err(|_| {
                        format!("系统 DNS 解析超时（{}s）", DNS_RESOLVE_TIMEOUT.as_secs())
                    })?
                    .map_err(|e| format!("系统 DNS 解析失败: {e}"))?;
            let mut ips: Vec<IpAddr> = Vec::new();
            for addr in addrs {
                let ip = addr.ip();
                if !ips.contains(&ip) {
                    ips.push(ip);
                }
            }
            Ok(ips)
        })
    }
}

/// 解析结果复核：非空且每条记录都必须不是内网/保留地址（fail-closed）
fn check_resolved_ips(domain: &str, ips: &[IpAddr]) -> Result<(), String> {
    if ips.is_empty() {
        return Err(format!("仓库地址无法解析: {domain}（解析结果为空）"));
    }
    // 测试专用：回环 mock 仓库域名（`map_mock_repo_host` 注册）显式放行。
    // 生产构建下 `is_test_trusted_host` 恒为 false，无旁路。
    if is_test_trusted_host(domain) {
        return Ok(());
    }
    for ip in ips {
        if is_disallowed_ip(*ip) {
            return Err(format!(
                "仓库地址不允许指向内网/保留地址: {domain} 解析为 {ip}"
            ));
        }
    }
    Ok(())
}

/// 测试专用：回环 mock 仓库域名判定（生产构建恒为 false）
///
/// 生产环境**没有**任何域名豁免：即便用户 `setCustomHosts` 把某域名映射到
/// 回环地址，解析级校验也照样拒绝（否则该配置本身就是 SSRF 旁路）。
/// 测试构建下，[`tests::map_mock_repo_host`] 在持
/// [`tests::MOCK_HOSTS_LOCK`] 期间登记 mock 域名，视为可信 seam——集成用例
/// 要真的把请求打到 `127.0.0.1` 的 mock 仓库，而生产语义必须拒绝回环，
/// 两者只能靠编译期开关区分。登记表为空时无任何豁免。
#[cfg(not(test))]
fn is_test_trusted_host(_domain: &str) -> bool {
    false
}

#[cfg(test)]
fn is_test_trusted_host(domain: &str) -> bool {
    TEST_TRUSTED_HOSTS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .iter()
        .any(|host| host == domain)
}

/// 测试专用可信域名登记表（生产构建不存在此符号）
#[cfg(test)]
static TEST_TRUSTED_HOSTS: std::sync::Mutex<Vec<String>> = std::sync::Mutex::new(Vec::new());

/// 连接期 SSRF 守卫（reqwest [`Resolve`] 实现）
///
/// 与「请求前解析一次」相比，本解析器在**每次建连**时解析并复核，且返回的
/// 地址就是 hyper 实际连接的地址——校验与连接使用同一次解析结果，堵住
/// 「第一次解析返回公网 IP 过校验、第二次返回内网 IP 实际连接」的
/// TOCTOU（DNS rebinding）。重定向的每一跳都会重新建连，因此逐跳覆盖。
///
/// 字面量形态（IP / `localhost`）不经过 DNS，由
/// [`validate_repo_url_literal`] 在重定向策略里逐跳拦截。
///
/// ## 已知残余（已登记，非本批可解）
///
/// 若运行环境配置了 HTTP(S) 代理（reqwest 默认读取 `HTTP_PROXY` 等环境
/// 变量），请求会交给代理转发，**本地不做目标域名解析**，本守卫因此不被
/// 调用；此时域名解析发生在代理侧，校验只覆盖请求发起前的那一次
/// [`validate_repo_url`]。要彻底闭合需要禁用代理或改为代理侧校验，属运维
/// 配置面，不在本批范围。
struct SsrfGuardResolver {
    inner: Arc<dyn RepoDnsResolver>,
}

impl SsrfGuardResolver {
    fn new(inner: Arc<dyn RepoDnsResolver>) -> Self {
        Self { inner }
    }
}

impl Resolve for SsrfGuardResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_string();
        // 先克隆 Arc：异步块需 `'static`，不能借用 `&self`
        let inner = Arc::clone(&self.inner);
        Box::pin(async move {
            let normalized = normalize_host(&host);
            let started = std::time::Instant::now();
            let ips = inner.resolve(&normalized).await.map_err(
                |e| -> Box<dyn std::error::Error + Send + Sync> {
                    format!("仓库地址无法解析: {host}（{e}）").into()
                },
            )?;
            // 保留原 `custom_hosts::resolver()` 的 DNS 计时埋点（未开启计时时无操作）
            legado_net::timing::record_dns(
                &normalized,
                started.elapsed(),
                ips.iter().map(|ip| SocketAddr::new(*ip, 0)).collect(),
            );
            check_resolved_ips(&normalized, &ips)
                .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;
            let addrs: Addrs = Box::new(ips.into_iter().map(|ip| SocketAddr::new(ip, 0)));
            Ok(addrs)
        })
    }
}

/// 展平 reqwest 错误链为可读文案（含 SSRF 守卫在解析器里给出的原因）
///
/// reqwest 顶层 `Display` 只有 `error sending request for url (...)`，DNS
/// 解析器返回的错误在其 `source()` 链上。这里沿链拼接，使「被 SSRF 守卫
/// 拦下」与「网络不可达」在错误消息里可区分。
fn describe_reqwest_error(err: &reqwest::Error) -> String {
    let mut parts: Vec<String> = vec![err.to_string()];
    let mut source = std::error::Error::source(err);
    while let Some(cause) = source {
        let text = cause.to_string();
        // 去重：reqwest 常把内层文案原样嵌在外层 Display 里
        if !parts.iter().any(|part| part.contains(&text)) {
            parts.push(text);
        }
        source = cause.source();
    }
    parts.join(": ")
}

/// 内网/保留地址判定（对齐审查批 P1-1 要求的最小集合 + 明显不可路由地址）
///
/// 批24 P2 补齐易被用作 SSRF 跳板/云元数据端点的保留网段：
/// - `100.64.0.0/10`（CGNAT；含腾讯云元数据 `100.100.100.200`）；
/// - `192.0.0.0/24`（IETF 协议保留）；
/// - `198.18.0.0/15`（基准测试保留）；
/// - `240.0.0.0/4`（保留，含 `255.255.255.255`）。
///
/// `Ipv4Addr::is_shared` / `is_benchmarking` / `is_reserved` 在本工具链
/// （1.97.1）仍是 nightly `ip` feature，故用 `(base, mask)` 手动判定。
fn ipv4_in_range(v4: std::net::Ipv4Addr, base: u32, mask: u32) -> bool {
    (u32::from(v4) & mask) == (base & mask)
}

/// `100.64.0.0/10`
const CGNAT_BASE: u32 = 0x6440_0000;
const CGNAT_MASK: u32 = 0xFFC0_0000;
/// `192.0.0.0/24`
const IETF_PROTOCOL_BASE: u32 = 0xC000_0000;
const IETF_PROTOCOL_MASK: u32 = 0xFFFF_FF00;
/// `198.18.0.0/15`
const BENCHMARK_BASE: u32 = 0xC612_0000;
const BENCHMARK_MASK: u32 = 0xFFFE_0000;
/// `240.0.0.0/4`（含 255.255.255.255）
const RESERVED_BASE: u32 = 0xF000_0000;
const RESERVED_MASK: u32 = 0xF000_0000;

fn is_disallowed_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || v4.is_multicast()
                || ipv4_in_range(v4, CGNAT_BASE, CGNAT_MASK)
                || ipv4_in_range(v4, IETF_PROTOCOL_BASE, IETF_PROTOCOL_MASK)
                || ipv4_in_range(v4, BENCHMARK_BASE, BENCHMARK_MASK)
                || ipv4_in_range(v4, RESERVED_BASE, RESERVED_MASK)
        }
        IpAddr::V6(v6) => {
            v6.is_loopback()
                || v6.is_unspecified()
                || v6.is_unique_local()
                || v6.is_unicast_link_local()
                || v6
                    .to_ipv4_mapped()
                    .is_some_and(|v4| is_disallowed_ip(IpAddr::V4(v4)))
        }
    }
}

/// GET /api/sources/updates — 检查书源更新
///
/// 从所有仓库获取远程书源列表，与本地对比，返回需要更新的书源。
pub async fn check_updates(State(state): State<Arc<AppState>>) -> Result<Json<Value>, ApiError> {
    let repos = active_repos();
    // 回环仓库（本地测试服务）不经系统/环境变量代理路由：reqwest 默认客户端
    // 在 HTTP_PROXY 存在时连 127.0.0.1 也走代理，死代理环境下回环流量会被
    // 劫持（P2-17 约定 cda70a0c54）。真实仓库集合沿用默认客户端，生产行为不变。
    // 批24 P2：移除 `danger_accept_invalid_certs(true)`。该端点会对订阅仓库
    // 发起出站请求，放宽证书校验会让中间人用自签证书替换仓库内容。
    let builder = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .dns_resolver(legado_net::custom_hosts::resolver());
    let client = (if repos.iter().all(|r| is_loopback_repo_url(&r.url)) {
        builder.no_proxy()
    } else {
        builder
    })
    .build()
    .map_err(|e| legado_core::LegadoError::Network(format!("创建 HTTP 客户端失败: {e}")))?;

    // 获取本地书源列表
    let local_sources = {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        repo.find_all()?
    };

    let mut results: Vec<UpdateCheckResult> = Vec::new();

    for repo_info in &repos {
        let result = check_repo_updates(&client, repo_info, &local_sources).await;
        results.push(result);
    }

    let total_updates: usize = results.iter().map(|r| r.updates.len()).sum();
    let total_new: usize = results.iter().map(|r| r.new_count).sum();

    Ok(Json(json!({
        "results": results,
        "total_updates": total_updates,
        "total_new": total_new,
    })))
}

/// POST /api/sources/update — 执行更新
///
/// 从指定仓库下载书源并合并到本地数据库。
///
/// 安全约束（审查批 P1-1 + R06）：
/// - `repo_url` 只允许 `http`/`https`，且不得指向本机/内网/保留地址
///   （[`validate_repo_url`]：字面量 + DNS 解析级复核）；
/// - 重定向逐跳做字面量校验（[`validate_repo_url_literal`]），并在建连时
///   经 [`SsrfGuardResolver`] 做解析级复核——每跳都重新解析并校验，
///   校验所用 IP 即实际连接 IP，堵住 DNS rebinding 的 TOCTOU 窗口；
/// - 不再无条件 `danger_accept_invalid_certs(true)`（原实现会接受任意自签
///   证书，配合任意 `repo_url` 放大中间人攻击面）；证书校验恢复默认。
pub async fn execute_update(
    State(state): State<Arc<AppState>>,
    Json(req): Json<UpdateRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let repo_url = validate_repo_url(&req.repo_url)
        .await
        .map_err(|message| ApiError(legado_core::LegadoError::Parser(message)))?;
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        // 逐跳校验重定向目标：拒绝 302 到非 http(s)/本机/内网字面量的 SSRF 变形。
        // 域名解析到内网的形态由 SsrfGuardResolver 在建连时逐跳拦截
        // （重定向策略是同步闭包，无法 await DNS）。
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if validate_repo_url_literal(attempt.url().as_str()).is_ok() {
                attempt.follow()
            } else {
                attempt.error("重定向目标不被允许（仅 http/https 且不得指向内网）")
            }
        }))
        .dns_resolver(Arc::new(SsrfGuardResolver::new(Arc::new(
            SystemDnsResolver,
        ))))
        .build()
        .map_err(|e| legado_core::LegadoError::Network(format!("创建 HTTP 客户端失败: {e}")))?;

    // 下载远程书源
    //
    // `SsrfGuardResolver` 在建连期拒绝内网/保留地址时，reqwest 只保留顶层
    // 文案（`error sending request for url (...)`），底层原因在 source 链里。
    // 这里把它展平进错误消息，避免运维/测试只能看到「请求失败」而无法区分
    // 「网络不可达」与「被 SSRF 守卫拦下」。
    let response = client.get(repo_url).send().await.map_err(|e| {
        let detail = describe_reqwest_error(&e);
        legado_core::LegadoError::Network(format!("请求仓库失败: {detail}"))
    })?;

    if !response.status().is_success() {
        return Err(ApiError(legado_core::LegadoError::Network(format!(
            "仓库请求失败，状态码: {}",
            response.status()
        ))));
    }

    let body = response
        .text()
        .await
        .map_err(|e| legado_core::LegadoError::Network(format!("读取响应失败: {e}")))?;

    // 解析远程书源 JSON（审查批1 P0-1）：改走与 FFI `import_sources` 同一
    // serde 主链（`BookSource` 模型 lenient 反序列化，规则嵌套对象与
    // `variable` 全量透传），不再经 `RoomImporter::import_book_sources`——
    // 其按 Room 导出格式把规则字段当字符串读取（`as_str`），标准书源仓库
    // JSON 的嵌套对象规则必得 None 落 NULL，且 INSERT 列集不含 `variable`
    // （REPLACE 清空登录态）。证据：docs/REFACTORING_FULL_AUDIT_REPORT_20261026.md
    // §一 P0-1。形态不符在此显式报错（防复发规定 4），整批拒绝而非静默丢字段。
    let remote_sources: Vec<BookSource> = serde_json::from_str(&body)
        .map_err(|e| legado_core::LegadoError::Internal(format!("解析书源 JSON 失败: {e}")))?;

    // 获取本地书源 URL 集合
    let local_urls: std::collections::HashSet<String> = {
        let db = state.db.lock().await;
        let repo = BookSourceRepository::new(db.connection());
        let sources = repo.find_all()?;
        sources.into_iter().map(|s| s.book_source_url).collect()
    };

    let mut updated = 0usize;
    let mut added = 0usize;
    let mut skipped = 0usize;
    let mut failed = 0usize;
    let mut errors: Vec<String> = Vec::new();

    // 筛选需要导入的书源
    let sources_to_import: Vec<BookSource> = remote_sources
        .iter()
        .filter(|item| {
            if item.book_source_url.is_empty() {
                skipped += 1;
                return false;
            }
            let exists = local_urls.contains(&item.book_source_url);
            if exists {
                true // 更新已有
            } else if req.only_update_existing {
                skipped += 1;
                false // 跳过新增
            } else {
                true // 导入新增
            }
        })
        .cloned()
        .collect();

    if !sources_to_import.is_empty() {
        let db = state.db.lock().await;
        // 落库与 FFI import_sources 共用同一批量方法：`insert_batch_with_check_state`
        // 单事务原子写入，底层 `Repository::insert` 为 INSERT OR REPLACE 全列
        // upsert——**以导入为准覆盖**（含 `variable`），与 FFI 主路径、原版
        // Room REPLACE 语义一致；任一条失败整批回滚，调用方看到 Err 时库内
        // 零改动。不新增旁路写实现（防复发规定 1：单实现原则）。
        // 批30b P2-1：REPLACE 会触发外键级联删状态行，同事务逐条重建检验
        // 状态（对齐原版导入即 NEEDS_CHECK）。
        match BookSourceRepository::new(db.connection())
            .insert_batch_with_check_state(&sources_to_import)
        {
            Ok(()) => {
                // 整批写库成功后按本次实际导入书源（含 concurrentRate）刷新
                // server registry；写库失败不刷新（避免未落库配置提前生效）
                // ——43a5096376 引入的刷新语义原样保留
                for item in &sources_to_import {
                    crate::handlers::web_book::refresh_source_rate_limit(
                        &item.book_source_url,
                        item.concurrent_rate.as_deref().unwrap_or(""),
                    );
                }
                // 区分新增和更新
                for item in &sources_to_import {
                    if local_urls.contains(&item.book_source_url) {
                        updated += 1;
                    } else {
                        added += 1;
                    }
                }
            }
            Err(e) => {
                failed = sources_to_import.len();
                errors.push(format!("批量导入失败: {e}"));
            }
        }
    }

    let result = UpdateResult {
        updated,
        added,
        skipped,
        failed,
        errors,
    };

    Ok((StatusCode::OK, Json(json!(result))))
}

/// 检查单个仓库的更新
async fn check_repo_updates(
    client: &reqwest::Client,
    repo_info: &SourceRepo,
    local_sources: &[legado_core::models::BookSource],
) -> UpdateCheckResult {
    // 下载远程书源
    let response = match client.get(&repo_info.url).send().await {
        Ok(resp) => resp,
        Err(e) => {
            return UpdateCheckResult {
                repo_name: repo_info.name.clone(),
                repo_url: repo_info.url.clone(),
                remote_total: 0,
                updates: vec![],
                new_count: 0,
                success: false,
                error: Some(format!("请求失败: {e}")),
            };
        }
    };

    if !response.status().is_success() {
        return UpdateCheckResult {
            repo_name: repo_info.name.clone(),
            repo_url: repo_info.url.clone(),
            remote_total: 0,
            updates: vec![],
            new_count: 0,
            success: false,
            error: Some(format!("HTTP 状态码: {}", response.status())),
        };
    }

    let body = match response.text().await {
        Ok(b) => b,
        Err(e) => {
            return UpdateCheckResult {
                repo_name: repo_info.name.clone(),
                repo_url: repo_info.url.clone(),
                remote_total: 0,
                updates: vec![],
                new_count: 0,
                success: false,
                error: Some(format!("读取响应失败: {e}")),
            };
        }
    };

    // 解析远程书源
    let remote_sources: Vec<Value> = match serde_json::from_str(&body) {
        Ok(v) => v,
        Err(e) => {
            return UpdateCheckResult {
                repo_name: repo_info.name.clone(),
                repo_url: repo_info.url.clone(),
                remote_total: 0,
                updates: vec![],
                new_count: 0,
                success: false,
                error: Some(format!("解析 JSON 失败: {e}")),
            };
        }
    };

    // 构建本地书源 URL -> lastUpdateTime 映射
    let local_map: std::collections::HashMap<&str, i64> = local_sources
        .iter()
        .map(|s| (s.book_source_url.as_str(), s.last_update_time))
        .collect();

    let mut updates: Vec<SourceUpdateInfo> = Vec::new();
    let mut new_count = 0usize;

    for item in &remote_sources {
        let url = item
            .get("bookSourceUrl")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if url.is_empty() {
            continue;
        }

        let name = item
            .get("bookSourceName")
            .and_then(|v| v.as_str())
            .unwrap_or("未知书源")
            .to_string();
        let remote_time = item
            .get("lastUpdateTime")
            .and_then(|v| v.as_i64())
            .unwrap_or(0);

        match local_map.get(url) {
            Some(&local_time) => {
                // 本地存在，比较更新时间
                if remote_time > local_time {
                    updates.push(SourceUpdateInfo {
                        source_url: url.to_string(),
                        source_name: name,
                        local_update_time: local_time,
                        remote_update_time: remote_time,
                        need_update: true,
                    });
                }
            }
            None => {
                // 本地不存在，计为新增
                new_count += 1;
            }
        }
    }

    UpdateCheckResult {
        repo_name: repo_info.name.clone(),
        repo_url: repo_info.url.clone(),
        remote_total: remote_sources.len(),
        updates,
        new_count,
        success: true,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use axum::http::Request;
    use std::io::{Read, Write};
    use tower::ServiceExt;

    use crate::routes::create_router;
    use crate::server::attach_source_write_token_guard;
    use tokio::sync::Mutex;

    /// 令牌错误文案（对齐原版 `hasValidJsSourceApiToken` 失败文案）
    const TOKEN_ERROR: &str = "Web 书源访问令牌未配置或不正确";

    /// 测试仓库域名：生产校验拒绝回环字面量（127.0.0.1/localhost），
    /// 集成用例经自定义 hosts 把本域名映射到 127.0.0.1——仍走真实
    /// `validate_repo_url` + reqwest + DNS resolver 链路，不引入 test-only
    /// 校验旁路。
    const MOCK_REPO_HOST: &str = "source-repo.test";

    /// 串行锁：自定义 hosts 映射为进程级全局状态，避免并行用例互相清理
    static MOCK_HOSTS_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// 离开作用域清理 hosts 映射与可信域名登记（panic 亦不泄漏）
    struct MockHostsGuard;

    impl Drop for MockHostsGuard {
        fn drop(&mut self) {
            legado_net::custom_hosts::clear_custom_hosts();
            TEST_TRUSTED_HOSTS
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .clear();
        }
    }

    /// 注入 `MOCK_REPO_HOST → 127.0.0.1` 映射并登记为测试可信域名，返回清理守卫
    fn map_mock_repo_host() -> MockHostsGuard {
        legado_net::custom_hosts::apply_custom_hosts(
            &json!({ MOCK_REPO_HOST: "127.0.0.1" }).to_string(),
        )
        .expect("hosts 映射注入失败");
        let mut trusted = TEST_TRUSTED_HOSTS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if !trusted.iter().any(|host| host == MOCK_REPO_HOST) {
            trusted.push(MOCK_REPO_HOST.to_string());
        }
        drop(trusted);
        MockHostsGuard
    }

    /// 测试仓库 URL（域名为映射后的 `MOCK_REPO_HOST`，端口取 mock 实际端口）
    fn mock_repo_url(addr: std::net::SocketAddr, path: &str) -> String {
        format!("http://{MOCK_REPO_HOST}:{}{path}", addr.port())
    }

    /// 写入 caches 配置（令牌开关/令牌值）
    async fn seed_config(state: &Arc<AppState>, key: &str, value: &str) {
        let db = state.db.lock().await;
        legado_db::repository::cache_repository::CacheRepository::new(db.connection())
            .put(key, value, 0)
            .unwrap();
    }

    fn make_test_state() -> Arc<AppState> {
        let db = legado_db::init_in_memory_database().unwrap();
        Arc::new(AppState {
            db: Mutex::new(db),
            search_cancelled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            download_manager: tokio::sync::Mutex::new(
                legado_core::download_manager::DownloadManager::new(3),
            ),
            injected_paths: Default::default(),
            legacy_review: Default::default(),
            source_check: Default::default(),
        })
    }

    /// 测试播种：与 FFI `import_sources` / 生产 `execute_update` 同一 serde
    /// 链路写入书源（审查批1 P0-1 后本文件不再引用 RoomImporter，防复发
    /// 规定 1：测试与生产走同一写实现，杜绝种子旁路掩盖链路缺陷）。
    fn seed_book_sources(db: &legado_db::Database, json: &str) {
        let sources: Vec<BookSource> =
            serde_json::from_str(json).expect("测试种子应可解析为 BookSource 数组");
        BookSourceRepository::new(db.connection())
            .insert_batch(&sources)
            .expect("测试播种应写入成功");
    }

    /// 直读书源 TEXT 单列（断言落库值用）
    fn read_source_column(db: &legado_db::Database, url: &str, column: &str) -> Option<String> {
        // 列名由本文件测试常量传入（非外部输入），白名单校验防误用
        assert!(
            [
                "ruleSearch",
                "ruleToc",
                "ruleContent",
                "ruleBookInfo",
                "variable",
                "concurrentRate"
            ]
            .contains(&column),
            "不允许查询列: {column}"
        );
        db.connection()
            .query_row(
                &format!("SELECT {column} FROM book_sources WHERE bookSourceUrl = ?1"),
                [url],
                |row| row.get(0),
            )
            .unwrap_or_else(|e| panic!("读取 {url}.{column} 失败: {e}"))
    }

    #[tokio::test]
    async fn test_list_repos() {
        let state = make_test_state();
        let app = create_router(state);

        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/sources/repos")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(resp.status(), StatusCode::OK);

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        assert!(json["repos"].is_array());
        assert!(json["total"].as_u64().unwrap() > 0);
    }

    /// 测试专用：本地回环书源仓库 mock（`default_repos` 两个外部仓库的确定性替身）
    ///
    /// 在指定路径提供 bookSource JSON 数组（200），其余路径 404。
    /// std `TcpListener` 模式（与 legado-ffi/legado-js 的 cookie 回显服务器、
    /// legado-js 的 `spawn_httpbin_mock` 同款；测试不引入 tokio-net 依赖）。
    fn spawn_source_repo_mock(
        max_conns: usize,
        routes: Vec<(String, String)>,
    ) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        std::thread::spawn(move || {
            for stream in listener.incoming().take(max_conns) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
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
                let target = head_str
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/");
                let (status, body) = routes
                    .iter()
                    .find(|(path, _)| path.as_str() == target)
                    .map(|(_, body)| ("200 OK", body.as_str()))
                    .unwrap_or_else(|| ("404 Not Found", r#"{"error":"not found"}"#));
                let resp = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n{body}",
                    len = body.len()
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// `check_updates` 检查逻辑对本地回环仓库生效（确定性硬断言）
    ///
    /// 原本例真联网抓 raw.githubusercontent.com / cdn.jsdelivr.net（仅断言
    /// 「非 404」——外网断线/仓库变更时检查静默失败，用例假绿）。现改为：
    /// 本地库播种 + `set_test_repos` 注入两个本地回环仓库（Drop 守卫还原），
    /// 响应各字段（success / remote_total / updates / new_count / 总量）逐项硬断言。
    #[tokio::test]
    async fn test_check_updates_route_exists() {
        let state = make_test_state();

        // 本地库播种：Mock A lastUpdateTime=1000 < 远程 2000 → 应判定需更新；
        // Mock New1 / Mock New2 本地不存在 → 应计为新增
        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                r#"[{"bookSourceUrl":"https://mock-a.example/","bookSourceName":"Mock A","lastUpdateTime":1000}]"#,
            );
        }

        let repo1 = json!([
            {"bookSourceUrl": "https://mock-a.example/", "bookSourceName": "Mock A", "lastUpdateTime": 2000},
            {"bookSourceUrl": "https://mock-new1.example/", "bookSourceName": "Mock New1", "lastUpdateTime": 3000}
        ])
        .to_string();
        let repo2 = json!([
            {"bookSourceUrl": "https://mock-new2.example/", "bookSourceName": "Mock New2", "lastUpdateTime": 4000}
        ])
        .to_string();
        let addr = spawn_source_repo_mock(
            8,
            vec![
                ("/repo1.json".to_string(), repo1),
                ("/repo2.json".to_string(), repo2),
            ],
        );
        let _repos_guard = set_test_repos(vec![
            SourceRepo {
                name: "本地仓库一".to_string(),
                url: format!("http://{addr}/repo1.json"),
                description: "测试回环仓库".to_string(),
            },
            SourceRepo {
                name: "本地仓库二".to_string(),
                url: format!("http://{addr}/repo2.json"),
                description: "测试回环仓库".to_string(),
            },
        ]);

        let app = create_router(state);
        let resp = app
            .oneshot(
                Request::builder()
                    .uri("/api/sources/updates")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "本地回环仓库可达，检查应返回 200"
        );

        let body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let json: Value = serde_json::from_slice(&body).unwrap();
        let results = json["results"].as_array().expect("results 应为数组");
        assert_eq!(results.len(), 2, "应检查注入的两个仓库");
        for r in results {
            assert_eq!(
                r["success"], true,
                "仓库检查应成功（回环 mock 可达）: error={}",
                r["error"]
            );
            assert!(
                r["remote_total"].as_u64().expect("remote_total") > 0,
                "远程书源数应 > 0: {r}"
            );
        }
        let r1 = results
            .iter()
            .find(|r| r["repo_name"] == "本地仓库一")
            .expect("仓库一结果");
        let r2 = results
            .iter()
            .find(|r| r["repo_name"] == "本地仓库二")
            .expect("仓库二结果");
        // 仓库一：Mock A（本地 1000 < 远程 2000）需更新；Mock New1 本地不存在 → 新增
        assert_eq!(r1["remote_total"], 2);
        assert_eq!(r1["new_count"], 1);
        let updates = r1["updates"].as_array().expect("仓库一 updates 应为数组");
        assert_eq!(updates.len(), 1, "仅 Mock A 应判定需更新");
        assert_eq!(updates[0]["source_url"], "https://mock-a.example/");
        assert_eq!(updates[0]["need_update"], true);
        assert_eq!(updates[0]["local_update_time"], 1000);
        assert_eq!(updates[0]["remote_update_time"], 2000);
        // 仓库二：Mock New2 本地不存在 → 新增
        assert_eq!(r2["remote_total"], 1);
        assert_eq!(r2["new_count"], 1);
        assert_eq!(r2["updates"].as_array().expect("仓库二 updates").len(), 0);
        // 汇总量
        assert_eq!(json["total_updates"], 1);
        assert_eq!(json["total_new"], 2);
    }

    #[tokio::test]
    async fn test_execute_update_invalid_url() {
        let state = make_test_state();
        let app = create_router(state);

        let body = serde_json::to_string(&json!({
            "repo_url": "http://invalid.localhost.test/nonexistent.json",
            "only_update_existing": false
        }))
        .unwrap();

        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();

        // 应该返回错误（网络不可达），但不是 404
        assert_ne!(resp.status(), StatusCode::NOT_FOUND);
    }

    /// execute_update 批量导入后刷新本次书源：
    /// 既有 limiter 由旧率 1/10000 更新为远端新率 3/10000，旧快照 acquire 立即放行
    /// （未刷新会沿用旧率等满 10s 窗口 → 300ms 超时失败）
    #[tokio::test]
    async fn test_execute_update_refreshes_rate_limiter() {
        use std::time::Duration;

        use legado_core::models::BookSource;

        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        let _hosts = map_mock_repo_host();
        let url = "https://server-ratelimit-batch.example/";

        // 本地已有旧率书源（含嵌套规则的真实形态种子），并让 server registry
        // 对其建立 limiter（窗口已用 1 次）
        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                &json!([{
                    "bookSourceUrl": url,
                    "bookSourceName": "旧书源",
                    "concurrentRate": "1/10000",
                    "variable": "{\"old\":\"local\"}",
                    "ruleSearch": {"bookList": "class.old", "name": "tag.h3@text"}
                }])
                .to_string(),
            );
        }
        let stale = BookSource {
            book_source_url: url.to_string(),
            concurrent_rate: Some("1/10000".to_string()),
            ..BookSource::default()
        };
        crate::handlers::web_book::rate_limiter()
            .acquire(&stale)
            .await;

        // 回环仓库返回同 URL 新率 3/10000（只更新已有书源；真实形态含嵌套规则）
        let remote = json!([{
            "bookSourceUrl": url,
            "bookSourceName": "新书源",
            "concurrentRate": "3/10000",
            "variable": "{\"new\":\"remote\"}",
            "ruleSearch": {"bookList": "class.new", "name": "tag.h4@text"},
            "lastUpdateTime": 9999
        }])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state);
        let body = serde_json::to_string(&json!({
            "repo_url": mock_repo_url(addr, "/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "回环仓库可达，更新应成功");

        // 刷新后：旧快照 acquire 立即放行
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            crate::handlers::web_book::rate_limiter().acquire(&stale),
        )
        .await;
        assert!(
            passed.is_ok(),
            "execute_update 批量导入成功后必须刷新 server registry"
        );
    }

    /// 批30b P2-1：在线更新走 REPLACE 批量导入，必须重建检验状态行
    ///
    /// 修复前 `insert_batch`（INSERT OR REPLACE）触发外键级联删状态且不重建，
    /// 网页管理页更新后这些源会从 `getBookSourceCheckStates` 消失。
    #[tokio::test]
    async fn test_execute_update_creates_check_states() {
        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        let _hosts = map_mock_repo_host();
        let urls = [
            "https://update-state-a.example/",
            "https://update-state-b.example/",
        ];
        let remote = json!([
            { "bookSourceUrl": urls[0], "bookSourceName": "A" },
            { "bookSourceUrl": urls[1], "bookSourceName": "B" }
        ])
        .to_string();
        let addr = spawn_source_repo_mock(2, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(Arc::clone(&state));
        let body = serde_json::to_string(&json!({
            "repo_url": mock_repo_url(addr, "/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let db = state.db.lock().await;
        let repo = legado_db::BookSourceCheckStateRepository::new(db.connection());
        for url in urls {
            let state_row = repo
                .find_by_url(url)
                .unwrap()
                .unwrap_or_else(|| panic!("在线更新应建状态行: {url}"));
            assert_eq!(state_row.status, "NEEDS_CHECK");
            assert!(!state_row.revision.is_empty());
        }
    }

    /// 审查批1 P0-1 回归①：真实形态书源 JSON（规则为嵌套对象 + variable
    /// 非空 + enabledCookieJar 混合形态）经 /api/sources/update 落库后，
    /// ruleSearch/ruleToc/ruleContent/variable 非空且与种子一致——旧链路
    /// （RoomImporter `as_str()`）会把嵌套对象规则静默丢成 NULL。
    #[tokio::test]
    async fn test_execute_update_persists_nested_rules_and_variable() {
        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        let _hosts = map_mock_repo_host();

        let rule_search = json!({
            "bookList": "class.result||class.bookbox",
            "name": "tag.h3@text",
            "author": "tag.span.0@text",
            "bookUrl": "tag.a.0@href"
        });
        let rule_toc = json!({
            "chapterList": "class.chapter",
            "chapterName": "text",
            "chapterUrl": "href"
        });
        let rule_content = json!({"content": "id.content@textNodes"});
        let variable = "{\"token\":\"abc123\",\"user\":\"tester\"}";
        let remote = json!([
            {
                "bookSourceUrl": "https://real-form-a.example/",
                "bookSourceName": "真实形态A",
                "bookSourceGroup": "审查批1",
                "bookSourceType": 0,
                "enabled": true,
                "enabledCookieJar": true,
                "concurrentRate": "2/10000",
                "lastUpdateTime": 1729900000000i64,
                "respondTime": 180000,
                "variable": variable,
                "searchUrl": "https://real-form-a.example/search?q={{key}}",
                "ruleSearch": rule_search,
                "ruleToc": rule_toc,
                "ruleContent": rule_content
            },
            {
                "bookSourceUrl": "https://real-form-b.example/",
                "bookSourceName": "真实形态B",
                "enabledCookieJar": false
            }
        ])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "repo_url": mock_repo_url(addr, "/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "回环仓库可达，更新应成功");

        // 落库断言：规则为 JSON 字符串且与种子对象语义相等；variable 原样；
        // enabledCookieJar 混合形态（true/false）各自落对
        let db = state.db.lock().await;
        let stored_search = read_source_column(&db, "https://real-form-a.example/", "ruleSearch")
            .expect("ruleSearch 应落库（旧链路此处为 NULL）");
        assert_eq!(
            serde_json::from_str::<Value>(&stored_search).unwrap(),
            rule_search,
            "ruleSearch 落库值应与种子对象一致"
        );
        let stored_toc = read_source_column(&db, "https://real-form-a.example/", "ruleToc")
            .expect("ruleToc 应落库");
        assert_eq!(
            serde_json::from_str::<Value>(&stored_toc).unwrap(),
            rule_toc
        );
        let stored_content = read_source_column(&db, "https://real-form-a.example/", "ruleContent")
            .expect("ruleContent 应落库");
        assert_eq!(
            serde_json::from_str::<Value>(&stored_content).unwrap(),
            rule_content
        );
        assert_eq!(
            read_source_column(&db, "https://real-form-a.example/", "variable").unwrap(),
            variable,
            "variable（登录态）应原样落库"
        );
        let read_jar = |conn_url: &str| -> i64 {
            db.connection()
                .query_row(
                    "SELECT enabledCookieJar FROM book_sources WHERE bookSourceUrl = ?1",
                    [conn_url],
                    |row| row.get(0),
                )
                .unwrap()
        };
        assert_eq!(read_jar("https://real-form-a.example/"), 1, "显式 true → 1");
        assert_eq!(
            read_jar("https://real-form-b.example/"),
            0,
            "显式 false → 0"
        );
    }

    /// 审查批1 P0-1 回归②：对已存在书源（本地 variable/concurrentRate/规则）
    /// 重跑仓库更新——覆盖语义与 FFI `import_sources` 一致（`insert_batch`
    /// 全列 INSERT OR REPLACE：**以导入为准覆盖**，含 variable），且
    /// server registry 刷新发生（43a5096376 语义不回归）。
    #[tokio::test]
    async fn test_execute_update_reimport_overwrites_existing_like_ffi() {
        use std::time::Duration;

        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        let _hosts = map_mock_repo_host();
        let url = "https://reimport.example/";

        // 本地存量：登录态 variable + 旧限速 + 旧规则
        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                &json!([{
                    "bookSourceUrl": url,
                    "bookSourceName": "存量书源",
                    "concurrentRate": "1/10000",
                    "variable": "{\"token\":\"local-login\"}",
                    "ruleSearch": {"bookList": "class.old", "name": "tag.old@text"}
                }])
                .to_string(),
            );
        }

        // 预先在 registry 建立旧率 limiter 并用掉窗口（复用确定性断言模式：
        // 未刷新则旧快照 acquire 需等满 10s 窗口，300ms 内必超时）
        let stale = BookSource {
            book_source_url: url.to_string(),
            concurrent_rate: Some("1/10000".to_string()),
            ..BookSource::default()
        };
        crate::handlers::web_book::rate_limiter()
            .acquire(&stale)
            .await;

        // 远端同 URL：variable / concurrentRate / 规则全部为新值
        let rule_search_remote = json!({"bookList": "class.fresh", "name": "tag.fresh@text"});
        let remote = json!([{
            "bookSourceUrl": url,
            "bookSourceName": "更新书源",
            "concurrentRate": "2/5000",
            "variable": "{\"token\":\"remote-login\"}",
            "ruleSearch": rule_search_remote,
            "lastUpdateTime": 8888
        }])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "repo_url": mock_repo_url(addr, "/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK, "回环仓库可达，更新应成功");

        let resp_body = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let result: Value = serde_json::from_slice(&resp_body).unwrap();
        assert_eq!(result["updated"], 1, "同 URL 应回计为 updated");
        assert_eq!(result["failed"], 0);

        // 覆盖语义断言：以导入为准（与 FFI import_sources / 原版 Room REPLACE 同语义）
        let db = state.db.lock().await;
        assert_eq!(
            read_source_column(&db, url, "variable").unwrap(),
            "{\"token\":\"remote-login\"}",
            "远端带 variable 时应以导入为准覆盖本地登录态（FFI 同语义）"
        );
        assert_eq!(
            read_source_column(&db, url, "concurrentRate").unwrap(),
            "2/5000"
        );
        let stored = read_source_column(&db, url, "ruleSearch").unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&stored).unwrap(),
            rule_search_remote,
            "规则应整体被远端覆盖"
        );
        drop(db);

        // registry 刷新断言：旧率快照 acquire 立即放行（未刷新会等满旧窗口）
        let passed = tokio::time::timeout(
            Duration::from_millis(300),
            crate::handlers::web_book::rate_limiter().acquire(&stale),
        )
        .await;
        assert!(passed.is_ok(), "更新成功后必须刷新 server registry");
    }

    /// 审查批1 P0-1 语义锁定：远端 JSON 不带 variable 键时与 FFI
    /// `import_sources` 既有行为一致——反序列化缺键得空串（lenient_string），
    /// 全列覆盖后本地 variable 清空；不发明「保留本地登录态」的新语义。
    #[tokio::test]
    async fn test_execute_update_variable_absent_clears_local_like_ffi() {
        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        let _hosts = map_mock_repo_host();
        let url = "https://no-var.example/";

        {
            let db = state.db.lock().await;
            seed_book_sources(
                &db,
                &json!([{
                    "bookSourceUrl": url,
                    "bookSourceName": "有登录态",
                    "variable": "{\"token\":\"keep-me\"}"
                }])
                .to_string(),
            );
        }

        let remote = json!([{
            "bookSourceUrl": url,
            "bookSourceName": "无变量远端",
            "lastUpdateTime": 6666
        }])
        .to_string();
        let addr = spawn_source_repo_mock(4, vec![("/repo.json".to_string(), remote)]);

        let app = create_router(state.clone());
        let body = serde_json::to_string(&json!({
            "repo_url": mock_repo_url(addr, "/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);

        let db = state.db.lock().await;
        assert_eq!(
            read_source_column(&db, url, "variable").unwrap(),
            "",
            "远端缺 variable 键 → 清空（与 FFI import_sources 同语义）"
        );
    }

    #[test]
    fn test_default_repos_not_empty() {
        let repos = default_repos();
        assert!(!repos.is_empty());
        for repo in &repos {
            assert!(!repo.name.is_empty());
            assert!(!repo.url.is_empty());
        }
    }

    #[test]
    fn test_source_update_info_serialization() {
        let info = SourceUpdateInfo {
            source_url: "https://example.com".to_string(),
            source_name: "测试书源".to_string(),
            local_update_time: 1000,
            remote_update_time: 2000,
            need_update: true,
        };
        let json = serde_json::to_value(&info).unwrap();
        assert_eq!(json["source_url"], "https://example.com");
        assert_eq!(json["need_update"], true);
    }

    #[test]
    fn test_update_result_serialization() {
        let result = UpdateResult {
            updated: 5,
            added: 3,
            skipped: 2,
            failed: 0,
            errors: vec![],
        };
        let json = serde_json::to_value(&result).unwrap();
        assert_eq!(json["updated"], 5);
        assert_eq!(json["added"], 3);
    }

    // ── P1-1：repo_url 校验（协议/内网/保留地址） ─────────────────────────

    /// 字面量校验回归（同步路径）：协议与 IP/localhost 字面量判定不依赖 DNS，
    /// 是 R06 解析级校验之前的第一道闸。
    #[test]
    fn test_validate_repo_url_literal_rejects_non_http_and_private_hosts() {
        for raw in [
            "ftp://example.com/repo.json",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "http://127.0.0.1:8080/repo.json",
            "http://127.0.0.2/repo.json",
            "http://localhost/repo.json",
            "http://LOCALHOST./repo.json",
            "http://10.0.0.1/repo.json",
            "http://172.16.0.1/repo.json",
            "http://172.31.255.255/repo.json",
            "http://192.168.1.10/repo.json",
            "http://169.254.169.254/latest/meta-data",
            // 批24 P2：CGNAT 段（含腾讯云元数据 100.100.100.200）
            "http://100.64.0.1/repo.json",
            "http://100.100.100.200/latest/meta-data",
            "http://100.127.255.255/repo.json",
            // IETF 协议保留 192.0.0.0/24
            "http://192.0.0.1/repo.json",
            "http://192.0.0.255/repo.json",
            // 基准测试保留 198.18.0.0/15
            "http://198.18.0.1/repo.json",
            "http://198.19.255.255/repo.json",
            // 保留 240.0.0.0/4（含广播地址）
            "http://240.0.0.1/repo.json",
            "http://255.255.255.255/repo.json",
            "http://[::1]/repo.json",
            "http://0.0.0.0/repo.json",
            "http://[::ffff:127.0.0.1]/repo.json",
            "not-a-url",
            "http://",
        ] {
            assert!(validate_repo_url_literal(raw).is_err(), "应拒绝: {raw}");
        }
        for raw in [
            "https://raw.githubusercontent.com/gedoor/legado/master/x.json",
            "http://example.com/repo.json",
            // 私网边界外（172.32/192.169）是公网地址，不得误拒
            "http://172.32.0.1/repo.json",
            "http://192.169.0.1/repo.json",
            // 批24 P2 新增保留段的紧邻外侧同样是公网
            "http://100.128.0.1/repo.json",
            "http://192.0.1.1/repo.json",
            "http://198.20.0.1/repo.json",
        ] {
            assert!(validate_repo_url_literal(raw).is_ok(), "应接受: {raw}");
        }
    }

    /// 字面量拒绝在异步校验里同样生效，且**不触发 DNS 解析**
    /// （解析器注入为「任何域名都失败」，若字面量先拦下就不会走到解析）
    #[tokio::test]
    async fn test_validate_repo_url_literal_rejections_skip_dns() {
        let resolver = FixedDnsResolver::failing();
        for raw in [
            "ftp://example.com/repo.json",
            "http://127.0.0.1:8080/repo.json",
            "http://localhost/repo.json",
            "http://192.168.1.10/repo.json",
            "http://169.254.169.254/latest/meta-data",
        ] {
            let err = validate_repo_url_with(raw, &resolver).await.unwrap_err();
            assert!(
                !err.contains("无法解析"),
                "字面量拒绝不应走到 DNS 解析: {raw} → {err}"
            );
        }
    }

    // ── R06：DNS 解析级校验（可注入解析器，不依赖外网） ──────────────────

    /// 测试用固定结果解析器：域名 → 解析结果（Ok=IP 列表 / Err=解析失败）
    struct FixedDnsResolver {
        answers: std::collections::HashMap<String, Result<Vec<IpAddr>, String>>,
    }

    impl FixedDnsResolver {
        fn new(entries: &[(&str, Result<&[&str], &str>)]) -> Self {
            let answers = entries
                .iter()
                .map(|(domain, answer)| {
                    let value = match answer {
                        Ok(ips) => Ok(ips
                            .iter()
                            .map(|ip| ip.parse::<IpAddr>().expect("测试 IP 字面量应合法"))
                            .collect()),
                        Err(message) => Err((*message).to_string()),
                    };
                    ((*domain).to_string(), value)
                })
                .collect();
            Self { answers }
        }

        fn single(domain: &str, ip: &str) -> Self {
            let mut resolver = Self::new(&[]);
            resolver
                .answers
                .insert(domain.to_string(), Ok(vec![ip.parse().unwrap()]));
            resolver
        }

        fn failing() -> Self {
            Self::new(&[])
        }
    }

    impl RepoDnsResolver for FixedDnsResolver {
        fn resolve<'a>(
            &'a self,
            domain: &'a str,
        ) -> std::pin::Pin<
            Box<dyn std::future::Future<Output = Result<Vec<IpAddr>, String>> + Send + 'a>,
        > {
            let answer = self
                .answers
                .get(domain)
                .cloned()
                .unwrap_or_else(|| Err(format!("测试解析器未配置该域名: {domain}")));
            Box::pin(async move { answer })
        }
    }

    /// R06 ①：域名解析到回环地址 → 拒绝（修复前此 URL 通过校验）
    #[tokio::test]
    async fn test_validate_repo_url_rejects_domain_resolving_to_loopback() {
        for ip in ["127.0.0.1", "127.0.0.2", "::1"] {
            let resolver = FixedDnsResolver::single("rebind-loopback.test", ip);
            let err = validate_repo_url_with("http://rebind-loopback.test/repo.json", &resolver)
                .await
                .unwrap_err();
            assert!(err.contains("内网/保留"), "文案应指明内网/保留: {err}");
            assert!(err.contains(ip), "文案应含解析出的 IP: {err}");
        }
    }

    /// R06 ②：域名解析到云元数据地址 → 拒绝
    #[tokio::test]
    async fn test_validate_repo_url_rejects_domain_resolving_to_metadata() {
        for ip in ["169.254.169.254", "100.100.100.200"] {
            let resolver = FixedDnsResolver::single("rebind-metadata.test", ip);
            let err =
                validate_repo_url_with("http://rebind-metadata.test/latest/meta-data", &resolver)
                    .await
                    .unwrap_err();
            assert!(err.contains("内网/保留"), "{err}");
            assert!(err.contains(ip), "{err}");
        }
    }

    /// R06 ②b：多条 A 记录中**任一条**命中内网即拒绝（不得只看第一条）
    #[tokio::test]
    async fn test_validate_repo_url_rejects_mixed_public_and_private_records() {
        let resolver =
            FixedDnsResolver::new(&[("rebind-mixed.test", Ok(&["93.184.216.34", "192.168.1.10"]))]);
        let err = validate_repo_url_with("http://rebind-mixed.test/repo.json", &resolver)
            .await
            .unwrap_err();
        assert!(err.contains("192.168.1.10"), "{err}");
    }

    /// R06 ③：正常公网域名 → Ok（注入公网 IP，不依赖外网 DNS）
    #[tokio::test]
    async fn test_validate_repo_url_accepts_public_domain() {
        let resolver = FixedDnsResolver::new(&[(
            "example.com",
            Ok(&["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"]),
        )]);
        let url = validate_repo_url_with("http://example.com/repo.json", &resolver)
            .await
            .expect("公网域名应通过解析级校验");
        assert_eq!(url.host_str(), Some("example.com"));
    }

    /// R06 ④：解析失败 / 解析结果为空 → 保守拒绝（fail-closed）
    #[tokio::test]
    async fn test_validate_repo_url_fails_closed_on_resolution_error() {
        let resolver =
            FixedDnsResolver::new(&[("nxdomain.test", Err("系统 DNS 解析失败: 未找到记录"))]);
        let err = validate_repo_url_with("http://nxdomain.test/repo.json", &resolver)
            .await
            .unwrap_err();
        assert!(err.contains("无法解析"), "{err}");
        assert!(err.contains("nxdomain.test"), "文案应含域名: {err}");
        assert!(err.contains("未找到记录"), "文案应含底层原因: {err}");

        let empty = FixedDnsResolver::new(&[("empty-records.test", Ok(&[]))]);
        let err = validate_repo_url_with("http://empty-records.test/repo.json", &empty)
            .await
            .unwrap_err();
        assert!(err.contains("无法解析"), "{err}");
        assert!(err.contains("解析结果为空"), "{err}");
    }

    /// R06 ②c：连接期守卫独立于请求前校验——即便跳过早校验，建连时同样拦下
    /// （模拟 DNS rebinding 的第二次解析返回内网地址）
    #[tokio::test]
    async fn test_ssrf_guard_resolver_blocks_internal_on_connect() {
        use reqwest::dns::Resolve as _;

        let guard = SsrfGuardResolver::new(Arc::new(FixedDnsResolver::single(
            "rebind-connect.test",
            "10.0.0.7",
        )));
        let name: reqwest::dns::Name = "rebind-connect.test".parse().unwrap();
        let err = guard
            .resolve(name)
            .await
            .err()
            .expect("建连期应拒绝内网地址");
        assert!(err.to_string().contains("内网/保留"), "{err}");

        let ok_guard = SsrfGuardResolver::new(Arc::new(FixedDnsResolver::single(
            "public-connect.test",
            "93.184.216.34",
        )));
        let name: reqwest::dns::Name = "public-connect.test".parse().unwrap();
        let addrs: Vec<std::net::SocketAddr> = ok_guard.resolve(name).await.unwrap().collect();
        assert_eq!(addrs.len(), 1);
        assert_eq!(addrs[0].ip().to_string(), "93.184.216.34");
        assert_eq!(addrs[0].port(), 0, "端口由 hyper 按 URL 补齐");
    }

    /// 测试专用：返回 302 到指定 Location 的本地 mock（重定向用例）
    fn spawn_redirect_mock(location: String) -> std::net::SocketAddr {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        std::thread::spawn(move || {
            for stream in listener.incoming().take(4) {
                let Ok(mut sock) = stream else { continue };
                let _ = sock.set_read_timeout(Some(std::time::Duration::from_secs(10)));
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
                let resp = format!(
                    "HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                let _ = sock.write_all(resp.as_bytes());
            }
        });
        addr
    }

    /// R06 ⑤：重定向到「解析后是内网」的域名 → 被拦截
    ///
    /// 修复前：第一跳公网/回环 mock 返回 302 到 `rebind-redirect.test`
    /// （经自定义 hosts 指向 127.0.0.1 的同一 mock），重定向策略只做字面量
    /// 校验（该域名不是 localhost 字面量）→ 放行 → 请求成功 200。
    /// 修复后：建连期 `SsrfGuardResolver` 解析出 127.0.0.1 → 拒绝 → 502。
    #[tokio::test]
    async fn test_execute_update_blocks_redirect_to_internal_domain() {
        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        // 首跳用可信 mock 域名；重定向目标域名映射到回环但**不登记**为可信，
        // 因此解析级校验必须拦下（这正是 DNS rebinding 的形态）
        legado_net::custom_hosts::apply_custom_hosts(
            &json!({
                MOCK_REPO_HOST: "127.0.0.1",
                "rebind-redirect.test": "127.0.0.1",
            })
            .to_string(),
        )
        .expect("hosts 映射注入失败");
        TEST_TRUSTED_HOSTS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push(MOCK_REPO_HOST.to_string());
        let _hosts_guard = MockHostsGuard;

        let target_mock =
            spawn_source_repo_mock(4, vec![("/repo.json".to_string(), "[]".to_string())]);
        let redirect_addr = spawn_redirect_mock(format!(
            "http://rebind-redirect.test:{}/repo.json",
            target_mock.port()
        ));

        let app = create_router(state);
        let body = serde_json::to_string(&json!({
            "repo_url": mock_repo_url(redirect_addr, "/repo.json"),
            "only_update_existing": false
        }))
        .unwrap();
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(body))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::BAD_GATEWAY,
            "重定向到解析为内网的域名必须被建连期守卫拦下"
        );
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let rd: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(rd["error"]["type"], "network", "rd={rd}");
        let message = rd["error"]["message"].as_str().unwrap_or_default();
        assert!(message.contains("请求仓库失败"), "rd={rd}");
        // 必须是 SSRF 守卫给出的原因，而不是「连接被拒绝」之类的普通网络错误
        assert!(
            message.contains("内网/保留"),
            "重定向目标的内网解析应在错误文案里可见: {message}"
        );
        assert!(
            message.contains("rebind-redirect.test"),
            "文案应含被拦下的域名: {message}"
        );
    }

    /// 集成面（生产路径，不经测试注入的解析器）：经 `setCustomHosts` 把域名
    /// 映射到内网，请求在发起前即 400 —— 证明 `execute_update` 真实接的是
    /// `SystemDnsResolver` + 解析级复核，而不是只在单测里成立。
    ///
    /// 修复前该 URL 通过校验并尝试出站（响应为 502/网络错误而非 400）。
    #[tokio::test]
    async fn test_execute_update_rejects_domain_mapping_to_private_via_hosts() {
        let state = make_test_state();
        let _hosts_lock = MOCK_HOSTS_LOCK.lock().await;
        legado_net::custom_hosts::apply_custom_hosts(
            &json!({
                "ssrf-internal.test": "10.0.0.9",
                "ssrf-metadata.test": "169.254.169.254",
            })
            .to_string(),
        )
        .expect("hosts 映射注入失败");
        let _hosts_guard = MockHostsGuard;

        let app = create_router(state);
        for (repo_url, expected_ip) in [
            ("http://ssrf-internal.test/repo.json", "10.0.0.9"),
            (
                "http://ssrf-metadata.test/latest/meta-data",
                "169.254.169.254",
            ),
        ] {
            let body = json!({ "repo_url": repo_url, "only_update_existing": false }).to_string();
            let resp = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/sources/update")
                        .header("Content-Type", "application/json")
                        .body(Body::from(body))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                resp.status(),
                StatusCode::BAD_REQUEST,
                "{repo_url} 应在发起请求前被拒"
            );
            let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap();
            let rd: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(rd["error"]["type"], "parser", "{repo_url} rd={rd}");
            let message = rd["error"]["message"].as_str().unwrap_or_default();
            assert!(message.contains("内网/保留"), "{repo_url} rd={rd}");
            assert!(
                message.contains(expected_ip),
                "文案应含解析出的内网 IP {expected_ip}: {message}"
            );
        }
    }

    /// 集成面：内网/非 http 的 repo_url 在发起网络请求前即 400
    #[tokio::test]
    async fn test_execute_update_rejects_private_repo_url_before_network() {
        let state = make_test_state();
        let app = create_router(state);
        for repo_url in [
            "http://127.0.0.1:9/repo.json",
            "http://192.168.1.10/repo.json",
            "ftp://example.com/repo.json",
        ] {
            let body = json!({
                "repo_url": repo_url,
                "only_update_existing": false
            })
            .to_string();
            let resp = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("POST")
                        .uri("/api/sources/update")
                        .header("Content-Type", "application/json")
                        .body(Body::from(body))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(resp.status(), StatusCode::BAD_REQUEST, "{repo_url}");
            let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
                .await
                .unwrap();
            let rd: Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(rd["error"]["type"], "parser", "{repo_url} rd={rd}");
        }
    }

    /// 无令牌 `POST /api/sources/update` 在读取 body 前被拒（3 MiB 仍走令牌
    /// 失败信封而非 axum 413）
    #[tokio::test]
    async fn test_source_update_requires_token_before_reading_body() {
        let state = make_test_state();
        seed_config(&state, "config:jsSourceApiToken", "secret").await;
        let app =
            attach_source_write_token_guard(create_router(Arc::clone(&state)), Arc::clone(&state));
        let big = format!(
            "{{\"repo_url\":\"https://example.com/repo.json\",\"padding\":\"{}\"}}",
            "x".repeat(3 * 1024 * 1024)
        );
        let resp = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/api/sources/update")
                    .header("Content-Type", "application/json")
                    .body(Body::from(big))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(
            resp.status(),
            StatusCode::OK,
            "守卫应在 body 提取前拒绝（不能是 413）"
        );
        assert_eq!(
            resp.headers()
                .get("connection")
                .and_then(|v| v.to_str().ok()),
            Some("close")
        );
        let bytes = axum::body::to_bytes(resp.into_body(), usize::MAX)
            .await
            .unwrap();
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(body["isSuccess"], false, "{body}");
        assert_eq!(body["errorMsg"], TOKEN_ERROR, "{body}");
    }
}
