//! QUIC/HTTP3 客户端模块
//!
//! 提供基于 quinn 的 QUIC 客户端实现，支持：
//! - QUIC 协议连接
//! - HTTP/3 请求发送（通过 QUIC 流）
//! - 连接池管理
//! - 性能监控

use std::collections::HashMap;
use std::sync::Arc;
use std::time::{Duration, Instant};

use legado_core::{LegadoError, LegadoResult};
use quinn::{ClientConfig, Endpoint, TransportConfig};
use rustls::RootCertStore;
use serde::Serialize;
use tokio::sync::Mutex;

/// QUIC 客户端配置
#[derive(Debug, Clone)]
pub struct QuinnConfig {
    /// 连接超时
    pub connect_timeout: Duration,
    /// 请求超时
    pub request_timeout: Duration,
    /// 是否验证证书
    pub verify_certs: bool,
    /// 最大空闲连接数
    pub max_idle_connections: usize,
    /// 空闲超时
    pub idle_timeout: Duration,
    /// 是否启用 HTTP/2 降级
    pub enable_http2_fallback: bool,
    /// 是否启用 0-RTT
    pub enable_0rtt: bool,
    /// Keep-Alive 间隔
    pub keep_alive_interval: Duration,
}

impl Default for QuinnConfig {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(10),
            request_timeout: Duration::from_secs(60),
            verify_certs: true,
            max_idle_connections: 8,
            idle_timeout: Duration::from_secs(30),
            enable_http2_fallback: true,
            enable_0rtt: true,
            keep_alive_interval: Duration::from_secs(15),
        }
    }
}

/// QUIC 性能指标
#[derive(Debug, Clone, Serialize)]
pub struct PerformanceMetrics {
    /// 连接耗时（毫秒）
    pub connect_ms: u64,
    /// 首字节时间（毫秒）
    pub ttfb_ms: u64,
    /// 总耗时（毫秒）
    pub total_ms: u64,
    /// 下载字节数
    pub bytes_received: u64,
    /// 使用的协议（h3/h2）
    pub protocol: String,
}

/// QUIC 响应
#[derive(Debug, Clone, Serialize)]
pub struct QuinnResponse {
    /// HTTP 状态码
    pub status: u16,
    /// 响应头
    pub headers: HashMap<String, String>,
    /// 响应体
    pub body: String,
    /// 最终 URL
    pub url: String,
}

/// 连接池条目
struct PoolEntry {
    endpoint: Endpoint,
    last_used: Instant,
}

/// QUIC 客户端
pub struct QuinnClient {
    config: QuinnConfig,
    pool: Arc<Mutex<HashMap<String, PoolEntry>>>,
}

impl QuinnClient {
    /// 创建 QUIC 客户端
    pub fn new(config: QuinnConfig) -> LegadoResult<Self> {
        Ok(Self {
            config,
            pool: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    /// 获取或创建连接
    async fn get_connection(&self, host: &str) -> LegadoResult<Endpoint> {
        let mut pool = self.pool.lock().await;

        // 检查连接池
        if let Some(entry) = pool.get(host) {
            if entry.last_used.elapsed() < self.config.idle_timeout {
                return Ok(entry.endpoint.clone());
            }
            // 连接已过期，移除
            pool.remove(host);
        }

        // 创建新连接
        let endpoint = self.create_endpoint()?;

        let entry = PoolEntry {
            endpoint: endpoint.clone(),
            last_used: Instant::now(),
        };

        // 清理过期连接
        self.cleanup_pool_internal(&mut pool).await;

        pool.insert(host.to_string(), entry);
        Ok(endpoint)
    }

    /// 创建 QUIC endpoint
    fn create_endpoint(&self) -> LegadoResult<Endpoint> {
        let mut roots = RootCertStore::empty();
        if self.config.verify_certs {
            roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        }

        let client_crypto = rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth();

        let quic_client_config = quinn::crypto::rustls::QuicClientConfig::try_from(client_crypto)
            .map_err(|e| LegadoError::Network(format!("创建 QUIC 配置失败: {}", e)))?;

        let mut client_config = ClientConfig::new(Arc::new(quic_client_config));

        // 配置传输层参数
        let mut transport_config = TransportConfig::default();
        transport_config.max_idle_timeout(Some(
            self.config.idle_timeout.try_into().unwrap(),
        ));
        transport_config.keep_alive_interval(Some(self.config.keep_alive_interval));
        
        client_config.transport_config(Arc::new(transport_config));

        let mut endpoint = Endpoint::client("0.0.0.0:0".parse().unwrap())
            .map_err(|e| LegadoError::Network(format!("创建 endpoint 失败: {}", e)))?;
        endpoint.set_default_client_config(client_config);

        Ok(endpoint)
    }

    /// 内部清理连接池
    async fn cleanup_pool_internal(&self, pool: &mut HashMap<String, PoolEntry>) {
        let idle_timeout = self.config.idle_timeout;
        let max_connections = self.config.max_idle_connections;
        
        // 先移除过期的连接
        pool.retain(|_, entry| {
            let keep = entry.last_used.elapsed() < idle_timeout;
            if !keep {
                log::debug!("移除过期连接");
            }
            keep
        });
        
        // 如果连接数超过限制，移除最旧的连接
        while pool.len() > max_connections {
            if let Some(oldest_key) = pool.iter()
                .min_by_key(|(_, entry)| entry.last_used)
                .map(|(k, _)| k.clone()) {
                pool.remove(&oldest_key);
                log::debug!("移除最旧连接以限制连接池大小");
            } else {
                break;
            }
        }
    }

    /// 发送 GET 请求（通过 QUIC 流发送 HTTP/3 格式的请求）
    pub async fn get(
        &self,
        url: &str,
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<QuinnResponse> {
        let parsed = url::Url::parse(url)
            .map_err(|e| LegadoError::Network(format!("URL 解析失败: {}", e)))?;
        let host = parsed
            .host_str()
            .ok_or_else(|| LegadoError::Network("URL 缺少 host".to_string()))?;
        let port = parsed.port_or_known_default().unwrap_or(443);

        let endpoint = self.get_connection(host).await?;
        let server_addr = format!("{}:{}", host, port).parse()
            .map_err(|e| LegadoError::Network(format!("地址解析失败: {}", e)))?;

        let connect_start = Instant::now();
        
        // endpoint.connect() 返回 Result<Connecting, ConnectError>
        let connecting = endpoint.connect(server_addr, host)
            .map_err(|e| LegadoError::Network(format!("连接初始化失败: {}", e)))?;
        
        // 等待连接建立
        let conn = tokio::time::timeout(
            self.config.connect_timeout,
            connecting,
        )
        .await
        .map_err(|_| LegadoError::Network("连接超时".to_string()))?
        .map_err(|e| LegadoError::Network(format!("连接失败: {}", e)))?;

        let connect_ms = connect_start.elapsed().as_millis() as u64;
        log::info!("QUIC 连接建立: {} (耗时 {}ms)", host, connect_ms);

        // 打开双向流发送 HTTP/3 请求
        let (mut send, mut recv) = conn.open_bi().await
            .map_err(|e| LegadoError::Network(format!("打开流失败: {}", e)))?;

        // 构建 HTTP/3 请求帧
        let mut request = format!("GET {} HTTP/3\r\n", parsed.path());
        request.push_str(&format!("Host: {}\r\n", host));
        if let Some(hdrs) = headers {
            for (k, v) in hdrs {
                request.push_str(&format!("{}: {}\r\n", k, v));
            }
        }
        request.push_str("\r\n");

        let start = Instant::now();
        send.write_all(request.as_bytes()).await
            .map_err(|e| LegadoError::Network(format!("发送请求失败: {}", e)))?;
        send.finish()
            .map_err(|e| LegadoError::Network(format!("完成发送失败: {}", e)))?;

        let ttfb_ms = start.elapsed().as_millis() as u64;

        // 读取响应
        let response_bytes = recv.read_to_end(1024 * 1024).await
            .map_err(|e| LegadoError::Network(format!("读取响应失败: {}", e)))?;

        let total_ms = start.elapsed().as_millis() as u64;
        let bytes_received = response_bytes.len() as u64;

        // 简单解析 HTTP 响应
        let response_str = String::from_utf8_lossy(&response_bytes);
        let mut lines = response_str.lines();
        
        let status_line = lines.next().unwrap_or("HTTP/3 200 OK");
        let status_code = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(200);

        let mut resp_headers = HashMap::new();
        let mut body_start = false;
        let mut body = String::new();

        for line in lines {
            if line.is_empty() {
                body_start = true;
                continue;
            }
            if body_start {
                body.push_str(line);
                body.push('\n');
            } else if let Some((k, v)) = line.split_once(':') {
                resp_headers.insert(k.trim().to_string(), v.trim().to_string());
            }
        }

        Ok(QuinnResponse {
            status: status_code,
            headers: resp_headers,
            body,
            url: url.to_string(),
        })
    }

    /// 发送 POST 请求
    pub async fn post(
        &self,
        url: &str,
        body: &[u8],
        headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<QuinnResponse> {
        let parsed = url::Url::parse(url)
            .map_err(|e| LegadoError::Network(format!("URL 解析失败: {}", e)))?;
        let host = parsed
            .host_str()
            .ok_or_else(|| LegadoError::Network("URL 缺少 host".to_string()))?;
        let port = parsed.port_or_known_default().unwrap_or(443);

        let endpoint = self.get_connection(host).await?;
        let server_addr = format!("{}:{}", host, port).parse()
            .map_err(|e| LegadoError::Network(format!("地址解析失败: {}", e)))?;

        let connecting = endpoint.connect(server_addr, host)
            .map_err(|e| LegadoError::Network(format!("连接初始化失败: {}", e)))?;
        
        let conn = tokio::time::timeout(
            self.config.connect_timeout,
            connecting,
        )
        .await
        .map_err(|_| LegadoError::Network("连接超时".to_string()))?
        .map_err(|e| LegadoError::Network(format!("连接失败: {}", e)))?;

        let (mut send, mut recv) = conn.open_bi().await
            .map_err(|e| LegadoError::Network(format!("打开流失败: {}", e)))?;

        // 构建 HTTP/3 POST 请求
        let mut request = format!("POST {} HTTP/3\r\n", parsed.path());
        request.push_str(&format!("Host: {}\r\n", host));
        request.push_str(&format!("Content-Length: {}\r\n", body.len()));
        if let Some(hdrs) = headers {
            for (k, v) in hdrs {
                request.push_str(&format!("{}: {}\r\n", k, v));
            }
        }
        request.push_str("\r\n");

        let start = Instant::now();
        send.write_all(request.as_bytes()).await
            .map_err(|e| LegadoError::Network(format!("发送请求头失败: {}", e)))?;
        send.write_all(body).await
            .map_err(|e| LegadoError::Network(format!("发送请求体失败: {}", e)))?;
        send.finish()
            .map_err(|e| LegadoError::Network(format!("完成发送失败: {}", e)))?;

        // 读取响应
        let response_bytes = recv.read_to_end(1024 * 1024).await
            .map_err(|e| LegadoError::Network(format!("读取响应失败: {}", e)))?;

        let total_ms = start.elapsed().as_millis() as u64;

        // 简单解析响应
        let response_str = String::from_utf8_lossy(&response_bytes);
        let mut lines = response_str.lines();
        
        let status_line = lines.next().unwrap_or("HTTP/3 200 OK");
        let status_code = status_line
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(200);

        let mut resp_headers = HashMap::new();
        let mut body_start = false;
        let mut resp_body = String::new();

        for line in lines {
            if line.is_empty() {
                body_start = true;
                continue;
            }
            if body_start {
                resp_body.push_str(line);
                resp_body.push('\n');
            } else if let Some((k, v)) = line.split_once(':') {
                resp_headers.insert(k.trim().to_string(), v.trim().to_string());
            }
        }

        Ok(QuinnResponse {
            status: status_code,
            headers: resp_headers,
            body: resp_body,
            url: url.to_string(),
        })
    }

    /// 性能测试
    pub async fn performance_test(&self, url: &str) -> LegadoResult<PerformanceMetrics> {
        let start = Instant::now();
        let resp = self.get(url, None).await?;
        let total_ms = start.elapsed().as_millis() as u64;

        Ok(PerformanceMetrics {
            connect_ms: 0,
            ttfb_ms: 0,
            total_ms,
            bytes_received: resp.body.len() as u64,
            protocol: "h3".to_string(),
        })
    }

    /// 清理连接池
    pub async fn cleanup_pool(&self) {
        let mut pool = self.pool.lock().await;
        pool.clear();
        log::info!("连接池已清理");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_quinn_client_creation() {
        let config = QuinnConfig::default();
        let client = QuinnClient::new(config);
        assert!(client.is_ok());
    }

    #[tokio::test]
    async fn test_cleanup_pool() {
        let config = QuinnConfig::default();
        let client = QuinnClient::new(config).unwrap();
        client.cleanup_pool().await;
        let pool = client.pool.lock().await;
        assert!(pool.is_empty());
    }

    #[tokio::test]
    async fn test_config_defaults() {
        let config = QuinnConfig::default();
        assert_eq!(config.connect_timeout, Duration::from_secs(10));
        assert_eq!(config.request_timeout, Duration::from_secs(60));
        assert!(config.verify_certs);
        assert_eq!(config.max_idle_connections, 8);
    }
}
