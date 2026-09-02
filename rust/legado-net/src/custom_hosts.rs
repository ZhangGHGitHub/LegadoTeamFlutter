//! 自定义 hosts 映射（DNS 覆盖，契约 §2.20.3 `setCustomHosts`，Task #72/#73）
//!
//! 对齐原版 `AppConfig.customHosts` / `hostMap` 语义：
//! - 存储格式为 JSON **对象** `{"域名":"IP", "域名":["IP1","IP2"]}`，
//!   值支持单 IP 字符串（含逗号分隔多 IP，对齐原版 `parseIpsFromString`）
//!   或 IP 数组（对齐原版 `parseIpsFromList`）；
//! - 命中映射的域名直接连接映射 IP，未命中回落系统 DNS；
//! - 空串/空对象 = 清除映射、恢复系统 DNS。
//!
//! ## 即时生效机制
//!
//! 全局映射以 `OnceLock<RwLock<HashMap>>` 承载；[`CustomHostsResolver`]
//! 实现 reqwest 的 [`Resolve`] trait，**每次解析时实时读取全局映射**
//! （而非构建时快照），因此 `setCustomHosts` 后所有已构建的客户端
//! （经 [`crate::client::LegadoClient`] 构建时统一挂载本 resolver）
//! 的后续请求立即使用新映射。

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::{Arc, OnceLock, RwLock};
use std::time::{Duration, Instant};

use reqwest::dns::{Addrs, Name, Resolve, Resolving};

use legado_core::{LegadoError, LegadoResult};

/// 全局 hosts 映射：域名（小写归一化）→ IP 列表
static HOSTS: OnceLock<RwLock<HashMap<String, Vec<IpAddr>>>> = OnceLock::new();

/// 取全局映射槽位（惰性初始化）
fn hosts_map() -> &'static RwLock<HashMap<String, Vec<IpAddr>>> {
    HOSTS.get_or_init(|| RwLock::new(HashMap::new()))
}

/// 解析并应用 hosts 映射 JSON（即时生效）
///
/// - 空串/`{}`：清除全部映射（恢复系统 DNS）；
/// - 非合法 JSON 或非对象：返回 `LegadoError::Internal`（契约错误码）；
/// - 值解析（对齐原版 `parseIpsFromString` / `parseIpsFromList`）：
///   字符串按逗号分隔逐段取合法 IP；数组逐元素同法解析；
///   全部非法 IP 的域名不纳入映射（等同未命中回落系统 DNS）。
pub fn apply_custom_hosts(hosts_json: &str) -> LegadoResult<()> {
    let trimmed = hosts_json.trim();
    if trimmed.is_empty() {
        clear_custom_hosts();
        return Ok(());
    }

    let value: serde_json::Value = serde_json::from_str(trimmed).map_err(|e| {
        LegadoError::Internal(format!("hosts 映射 JSON 解析失败（需为 JSON 对象）: {e}"))
    })?;
    let obj = value.as_object().ok_or_else(|| {
        LegadoError::Internal(format!(
            "hosts 映射必须为 JSON 对象（域名 → IP/IP 数组），实际为: {}",
            json_type_name(&value)
        ))
    })?;

    let mut map = HashMap::new();
    for (domain, v) in obj {
        let ips = match v {
            serde_json::Value::String(s) => parse_ips_from_string(s),
            serde_json::Value::Array(arr) => arr
                .iter()
                .filter_map(|item| item.as_str())
                .flat_map(parse_ips_from_string)
                .collect(),
            // 其他类型（数字/对象等）无法解析为 IP，跳过该域名
            _ => Vec::new(),
        };
        if !ips.is_empty() {
            map.insert(domain.trim().to_lowercase(), ips);
        }
    }

    let mut guard = hosts_map()
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *guard = map;
    Ok(())
}

/// 清除全部 hosts 映射（恢复系统 DNS）
pub fn clear_custom_hosts() {
    let mut guard = hosts_map()
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    guard.clear();
}

/// 查询域名的映射 IP 列表（未命中返回 None）
///
/// 域名大小写不敏感（查询与存储均小写归一化）。
pub fn lookup_ips(domain: &str) -> Option<Vec<IpAddr>> {
    let guard = hosts_map()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    guard.get(&domain.trim().to_lowercase()).cloned()
}

/// 当前映射条目数（诊断/测试用）
pub fn mapping_count() -> usize {
    let guard = hosts_map()
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    guard.len()
}

/// 从字符串解析 IP 列表（对齐原版 `parseIpsFromString`：逗号分隔，
/// 非合法 IP 段跳过）
fn parse_ips_from_string(s: &str) -> Vec<IpAddr> {
    s.split(',')
        .filter_map(|part| part.trim().parse::<IpAddr>().ok())
        .collect()
}

/// JSON 值类型名（可读错误消息用）
fn json_type_name(v: &serde_json::Value) -> &'static str {
    match v {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "布尔",
        serde_json::Value::Number(_) => "数字",
        serde_json::Value::String(_) => "字符串",
        serde_json::Value::Array(_) => "数组",
        serde_json::Value::Object(_) => "对象",
    }
}

// ─── DNS resolver 挂钩 ──────────────────────────────────────────

/// 自定义 hosts DNS 解析器
///
/// 命中全局映射：直接返回映射 IP（端口填 0，hyper 连接时以请求 URL
/// 实际端口替换）；未命中：回落系统 DNS（`tokio::net::lookup_host`，
/// reqwest 0.12 未公开 `GaiResolver`，此处以等价系统解析实现）。
///
/// 每次 `resolve` 实时读取全局映射，保证 `setCustomHosts` 即时生效。
pub struct CustomHostsResolver;

impl CustomHostsResolver {
    pub fn new() -> Self {
        Self
    }
}

impl Default for CustomHostsResolver {
    fn default() -> Self {
        Self::new()
    }
}

impl Resolve for CustomHostsResolver {
    fn resolve(&self, name: Name) -> Resolving {
        let host = name.as_str().to_string();
        // 命中映射：直接返回 IP 列表
        if let Some(ips) = lookup_ips(name.as_str()) {
            // 命中 hosts 映射的解析为纯内存查表，耗时计 0
            crate::timing::record_dns(
                &host,
                Duration::ZERO,
                ips.iter().map(|ip| SocketAddr::new(*ip, 0)).collect(),
            );
            let addrs: Addrs = Box::new(ips.into_iter().map(|ip| SocketAddr::new(ip, 0)));
            return Box::pin(async move { Ok(addrs) });
        }
        // 未命中：回落系统 DNS（端口传 0，解析结果端口由 hyper 按 URL 替换）
        Box::pin(async move {
            let t0 = Instant::now();
            let resolved: Vec<SocketAddr> = tokio::net::lookup_host((host.as_str(), 0u16))
                .await
                .map_err(|e| format!("系统 DNS 解析失败: {host}: {e}"))?
                .collect();
            crate::timing::record_dns(&host, t0.elapsed(), resolved.clone());
            let addrs: Addrs = Box::new(resolved.into_iter());
            Ok(addrs)
        })
    }
}

/// 构造 resolver 实例（客户端构建处挂载）
pub fn resolver() -> Arc<CustomHostsResolver> {
    Arc::new(CustomHostsResolver::new())
}

// ─── 测试 ────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// 串行锁：以下测试读写全局 hosts 映射，需串行执行避免相互干扰
    static TEST_LOCK: Mutex<()> = Mutex::new(());

    /// 单 IP 字符串值解析
    #[test]
    fn test_parse_single_ip() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        apply_custom_hosts(r#"{"a.example.com": "1.2.3.4"}"#).unwrap();
        assert_eq!(
            lookup_ips("a.example.com"),
            Some(vec!["1.2.3.4".parse().unwrap()])
        );
        // 大小写不敏感
        assert!(lookup_ips("A.EXAMPLE.COM").is_some());
        clear_custom_hosts();
    }

    /// IP 数组值解析（对齐原版 parseIpsFromList）
    #[test]
    fn test_parse_ip_array() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        apply_custom_hosts(r#"{"b.example.com": ["1.1.1.1", "2.2.2.2"]}"#).unwrap();
        let ips = lookup_ips("b.example.com").unwrap();
        assert_eq!(ips.len(), 2);
        clear_custom_hosts();
    }

    /// 逗号分隔多 IP 字符串（对齐原版 parseIpsFromString）
    #[test]
    fn test_parse_comma_separated_string() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        apply_custom_hosts(r#"{"c.example.com": "1.1.1.1, 2.2.2.2"}"#).unwrap();
        assert_eq!(lookup_ips("c.example.com").unwrap().len(), 2);
        clear_custom_hosts();
    }

    /// 非法输入：非 JSON / 非对象 → Internal 错误
    #[test]
    fn test_parse_invalid_json() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        assert!(apply_custom_hosts("not json").is_err());
        assert!(apply_custom_hosts(r#"["a.com"]"#).is_err()); // 数组非对象
        assert!(apply_custom_hosts(r#""1.2.3.4""#).is_err()); // 字符串非对象
        clear_custom_hosts();
    }

    /// 非法 IP 值：该域名不纳入映射（等同未命中回落系统 DNS）
    #[test]
    fn test_parse_invalid_ip_skipped() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        apply_custom_hosts(r#"{"d.example.com": "not-an-ip", "e.example.com": 42}"#).unwrap();
        assert!(lookup_ips("d.example.com").is_none());
        assert!(lookup_ips("e.example.com").is_none());
        assert_eq!(mapping_count(), 0);
        clear_custom_hosts();
    }

    /// 清除语义：空串 / 空对象均清空映射
    #[test]
    fn test_clear_semantics() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        apply_custom_hosts(r#"{"f.example.com": "9.9.9.9"}"#).unwrap();
        assert!(lookup_ips("f.example.com").is_some());

        apply_custom_hosts("").unwrap();
        assert!(lookup_ips("f.example.com").is_none());

        apply_custom_hosts(r#"{"f.example.com": "9.9.9.9"}"#).unwrap();
        apply_custom_hosts("{}").unwrap();
        assert!(lookup_ips("f.example.com").is_none());
        assert_eq!(mapping_count(), 0);
    }

    /// 映射覆盖后 resolver 命中（不依赖系统 DNS）
    #[test]
    fn test_lookup_hit_and_miss() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        apply_custom_hosts(r#"{"hit.example.com": "127.0.0.1"}"#).unwrap();
        assert!(lookup_ips("hit.example.com").is_some());
        // 未命中返回 None（resolver 内部回落系统 DNS）
        assert!(lookup_ips("miss.example.com").is_none());
        clear_custom_hosts();
    }

    /// 端到端：hosts 映射命中后请求打到映射 IP 的本地服务器
    #[tokio::test]
    async fn test_e2e_hosts_override_hit() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());

        // 启动一次性本地 HTTP 服务器
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let body = "hosts-ok";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes()).await;
                let _ = stream.flush().await;
            }
        });

        // 映射一个不存在的域名到 127.0.0.1
        apply_custom_hosts(r#"{"hosts-e2e.test": "127.0.0.1"}"#).unwrap();

        // no_proxy=true：hosts 覆盖的直连语义不应被系统代理架空
        //（缺省配置下系统代理会代理无法解析的假域名返回 502，2026-09-03 实测）
        let config = crate::client::LegadoClientConfig {
            no_proxy: true,
            ..crate::client::LegadoClientConfig::default()
        };
        let client = crate::client::LegadoClient::new(config).unwrap();
        let resp = client
            .get(&format!("http://hosts-e2e.test:{}/", addr.port()), None)
            .await
            .expect("hosts 映射命中后应能请求本地服务器");
        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, "hosts-ok");

        clear_custom_hosts();
    }

    /// 端到端：未命中域名回落系统 DNS（localhost 由系统解析）
    #[tokio::test]
    async fn test_e2e_fallback_system_dns() {
        let _g = TEST_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        clear_custom_hosts();

        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        use tokio::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 4096];
                let _ = stream.read(&mut buf).await;
                let body = "fallback-ok";
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                let _ = stream.write_all(resp.as_bytes()).await;
                let _ = stream.flush().await;
            }
        });

        let client =
            crate::client::LegadoClient::new(crate::client::LegadoClientConfig::default()).unwrap();
        let resp = client
            .get(&format!("http://localhost:{}/", addr.port()), None)
            .await
            .expect("未命中映射时应回落系统 DNS");
        assert_eq!(resp.status, 200);
        assert_eq!(resp.body, "fallback-ok");
    }
}
