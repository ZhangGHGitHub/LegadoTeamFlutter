//! QUIC/HTTP3 客户端模块（桩实现）
//!
//! 提供 QUIC 客户端的基础类型定义。
//! 当前为桩实现，后续可接入 quinn 库实现真正的 HTTP/3 支持。

use std::collections::HashMap;
use std::time::Duration;

use legado_core::{LegadoError, LegadoResult};
use serde::Serialize;

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

/// QUIC 客户端（桩实现）
pub struct QuinnClient {
    #[allow(dead_code)]
    config: QuinnConfig,
}

impl QuinnClient {
    /// 创建 QUIC 客户端
    pub fn new(config: QuinnConfig) -> LegadoResult<Self> {
        Ok(Self { config })
    }

    /// 发送 GET 请求（桩实现，返回错误）
    pub async fn get(
        &self,
        url: &str,
        _headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<QuinnResponse> {
        Err(LegadoError::Network(format!(
            "QUIC 尚未实现，无法请求: {url}"
        )))
    }

    /// 发送 POST 请求（桩实现，返回错误）
    pub async fn post(
        &self,
        url: &str,
        _body: &[u8],
        _headers: Option<HashMap<String, String>>,
    ) -> LegadoResult<QuinnResponse> {
        Err(LegadoError::Network(format!(
            "QUIC 尚未实现，无法请求: {url}"
        )))
    }

    /// 性能测试（桩实现）
    pub async fn performance_test(&self, url: &str) -> LegadoResult<PerformanceMetrics> {
        Err(LegadoError::Network(format!(
            "QUIC 尚未实现，无法测试: {url}"
        )))
    }

    /// 清理连接池（桩实现）
    pub async fn cleanup_pool(&self) {
        // 桩实现：无需清理
    }
}
