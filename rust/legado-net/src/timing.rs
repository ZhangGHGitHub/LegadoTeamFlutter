//! 请求分段计时诊断（LEGADO_NET_TIMING 门控）
//!
//! 用于定位「搜索慢」的具体卡点：在 DNS 解析、TCP 连接、TLS 握手、TTFB
//! 各阶段埋计时点。逆向根因报告 docs/SEARCH_SPEED_COUNT_ROOT_CAUSE_2026-08-25.md
//! §二已判定我方 Rust 网络栈逐请求延迟偏高，本模块提供实测数据支撑下一步修复。
//!
//! 设计要点：
//! - 零开销默认：所有计时点先经 timing_enabled 判定（OnceLock 缓存环境变量给一次），
//!   未开启时几乎不产生额外开销；
//! - 分段时间来源：
//!   - DNS：custom_hosts::CustomHostsResolver::resolve 内部计时；
//!   - TCP（v4/v6 分族）：probe_tcp_connect 独立连接探针（仅诊断路径）；
//!   - TTFB / body / total：client::LegadoClient 请求发送与读体路径计时；
//!   - TLS：reqwest 未公开握手精确时刻，由 ttfb - dns - tcp 推算。
//! - 结构化输出：每请求一行 [timing] ... 打到 stderr（字段名 ASCII，避免 pwsh 5.1
//!   以 GBK 解码 stdout 的乱码），并同时放入进程内收集器，供诊断工具
//!   （如 timing_video_search）导出为 UTF-8 文件。

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use url::Url;

/// 是否开启分段计时（LEGADO_NET_TIMING=1 / true / on）
pub fn timing_enabled() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| {
        std::env::var("LEGADO_NET_TIMING")
            .map(|v| v == "1" || v.eq_ignore_ascii_case("true") || v.eq_ignore_ascii_case("on"))
            .unwrap_or(false)
    })
}

/// DNS 解析计时记录（按 host 保留最近一次）
#[derive(Debug, Clone)]
pub struct DnsRecord {
    /// 主机名（小写）
    pub host: String,
    /// DNS 解析耗时
    pub elapsed: Duration,
    /// 解析出的地址列表（端口可能为 0，待连接时按 URL 替换）
    pub addrs: Vec<SocketAddr>,
    /// IPv4 地址个数
    pub v4: usize,
    /// IPv6 地址个数
    pub v6: usize,
}

/// 单请求分段计时记录
#[derive(Debug, Clone)]
pub struct RequestTiming {
    /// 请求 URL（完整）
    pub url: String,
    /// 主机名
    pub host: String,
    /// DNS 解析耗时（最近一次该 host 的记录）
    pub dns_ms: Option<f64>,
    /// DNS 返回的 IPv4 地址数
    pub dns_v4: usize,
    /// DNS 返回的 IPv6 地址数
    pub dns_v6: usize,
    /// TTFB：发送到收到响应头（含 DNS + connect + TLS + 服务端首个响应头）
    pub ttfb_ms: f64,
    /// 读响应体耗时（收响应头 → 读完 body）
    pub body_ms: f64,
    /// 总耗时（TTFB + body）
    pub total_ms: f64,
    /// 实际连接的对端地址（reqwest Response::remote_addr）
    pub remote_ip: Option<SocketAddr>,
}

/// TCP 连接探针结果（v4/v6 分族）
#[derive(Debug, Clone, Default)]
pub struct TcpProbe {
    /// 主机名
    pub host: String,
    /// 端口
    pub port: u16,
    /// IPv4 连接耗时（超时或失败为 None）
    pub v4_ms: Option<f64>,
    /// IPv6 连接耗时（超时或失败为 None）
    pub v6_ms: Option<f64>,
}

// ─── 全局状态 ─────────────────────────────────────────────────────

fn dns_records() -> &'static Mutex<HashMap<String, DnsRecord>> {
    static M: OnceLock<Mutex<HashMap<String, DnsRecord>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(HashMap::new()))
}

fn request_records() -> &'static Mutex<Vec<RequestTiming>> {
    static M: OnceLock<Mutex<Vec<RequestTiming>>> = OnceLock::new();
    M.get_or_init(|| Mutex::new(Vec::new()))
}

// ─── DNS 计时 ─────────────────────────────────────────────────────

/// 记录一次 DNS 解析（host + 耗时 + 地址列表）。未开启计时时为无操作。
pub fn record_dns(host: &str, elapsed: Duration, addrs: Vec<SocketAddr>) {
    if !timing_enabled() {
        return;
    }
    let v4 = addrs.iter().filter(|a| a.is_ipv4()).count();
    let v6 = addrs.iter().filter(|a| a.is_ipv6()).count();
    let rec = DnsRecord {
        host: host.to_string(),
        elapsed,
        addrs,
        v4,
        v6,
    };
    dns_records()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .insert(host.to_string(), rec);
}

/// 取最近一次某 host 的 DNS 记录
pub fn last_dns(host: &str) -> Option<DnsRecord> {
    dns_records()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .get(host)
        .cloned()
}

// ─── 请求计时 ─────────────────────────────────────────────────────

/// 记录一次请求的分段计时并输出一行结构化日志（stderr）。
///
/// ttfb：发送到收到响应头；body：收响应头到读完响应体。
pub fn emit_request(url: &str, ttfb: Duration, body: Duration, remote: Option<SocketAddr>) {
    if !timing_enabled() {
        return;
    }
    let host = host_of(url);
    let dns = last_dns(&host);
    let total = ttfb + body;
    let rt = RequestTiming {
        url: url.to_string(),
        host: host.clone(),
        dns_ms: dns.as_ref().map(|d| ms(&d.elapsed)),
        dns_v4: dns.as_ref().map(|d| d.v4).unwrap_or(0),
        dns_v6: dns.as_ref().map(|d| d.v6).unwrap_or(0),
        ttfb_ms: ms(&ttfb),
        body_ms: ms(&body),
        total_ms: ms(&total),
        remote_ip: remote,
    };

    let dns_txt = rt.dns_ms.map(|v| format!("{v:.3}")).unwrap_or_else(|| "na".into());
    let remote_txt = rt.remote_ip.map(|s| s.to_string()).unwrap_or_else(|| "na".into());
    eprintln!(
        "[timing] url={} host={} dns_ms={} dns_v4={} dns_v6={} ttfb_ms={:.3} body_ms={:.3} total_ms={:.3} remote={}",
        rt.url, rt.host, dns_txt, rt.dns_v4, rt.dns_v6, rt.ttfb_ms, rt.body_ms, rt.total_ms, remote_txt,
    );

    request_records()
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .push(rt);
}

/// 取出并清空全部请求计时记录
pub fn take_requests() -> Vec<RequestTiming> {
    let mut g = request_records().lock().unwrap_or_else(|p| p.into_inner());
    std::mem::take(&mut *g)
}

// ─── TCP 连接探针 ─────────────────────────────────────────────────

/// 独立探针：分族测量 host:port 的 TCP connect 耗时。
///
/// 优先命中自定义 hosts 映射，未命中回落系统 DNS；每个地址族（IPv4/IPv6）
/// 各测一次 TcpStream::connect，timeout 内未完成记为 None（黑洞）。
/// 用于区分「IPv6 黑洞等待」与「IPv4 正常连接」。
pub async fn probe_tcp_connect(host: &str, port: u16, timeout: Duration) -> TcpProbe {
    let mut probe = TcpProbe {
        host: host.to_string(),
        port,
        v4_ms: None,
        v6_ms: None,
    };

    let ips: Vec<IpAddr> = if let Some(ips) = crate::custom_hosts::lookup_ips(host) {
        ips
    } else {
        match tokio::net::lookup_host((host, port)).await {
            Ok(iter) => iter.map(|a| a.ip()).collect(),
            Err(_) => Vec::new(),
        }
    };

    for ip in ips {
        let dur = time_connect(SocketAddr::new(ip, port), timeout).await;
        match (ip, dur) {
            (IpAddr::V4(_), Some(d)) if probe.v4_ms.is_none() => probe.v4_ms = Some(ms(&d)),
            (IpAddr::V6(_), Some(d)) if probe.v6_ms.is_none() => probe.v6_ms = Some(ms(&d)),
            _ => {}
        }
    }
    probe
}

async fn time_connect(addr: SocketAddr, timeout: Duration) -> Option<Duration> {
    let t0 = Instant::now();
    match tokio::time::timeout(timeout, tokio::net::TcpStream::connect(addr)).await {
        Ok(Ok(_)) => Some(t0.elapsed()),
        _ => None,
    }
}

// ─── 工具函数 ─────────────────────────────────────────────────────

fn ms(d: &Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

fn host_of(url: &str) -> String {
    Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(|s| s.to_string()))
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_host_of_valid() {
        assert_eq!(host_of("https://example.com/a?b=1"), "example.com");
        assert_eq!(host_of("http://text.example.org:8080/x"), "text.example.org");
    }

    #[test]
    fn test_host_of_invalid() {
        assert_eq!(host_of("not-a-url"), "unknown");
    }

    #[test]
    fn test_ms_conversion() {
        assert_eq!(ms(&Duration::from_secs(2)), 2000.0);
        assert_eq!(ms(&Duration::from_millis(150)), 150.0);
    }

    #[test]
    fn test_tcp_probe_default() {
        let p = TcpProbe {
            host: "h".into(),
            ..Default::default()
        };
        assert!(p.v4_ms.is_none());
        assert!(p.v6_ms.is_none());
    }
}
