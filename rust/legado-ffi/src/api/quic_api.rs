//! QUIC/HTTP3 网络 API
//!
//! 提供 QUIC 客户端的创建、请求发送和性能测试功能。
//! 参考 Kotlin `CronetHelper.kt` 中的 Cronet QUIC 配置。
//!
//! 对应 FFI 接口：
//! - `create_quinn_client` — 创建 QUIC 客户端
//! - `quinn_get` — 发送 GET 请求
//! - `quinn_post` — 发送 POST 请求
//! - `quinn_performance_test` — 性能测试

use std::sync::OnceLock;

use tokio::runtime::Runtime;
use tokio::sync::Mutex;

use legado_core::{LegadoError, LegadoResult};
use legado_net::quic::{PerformanceMetrics, QuinnClient, QuinnConfig};

/// QUIC API 专用 runtime
static QUIC_RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// 全局 QUIC 客户端实例（单例，连接池复用）
static QUIC_CLIENT: OnceLock<Mutex<Option<QuinnClient>>> = OnceLock::new();

/// 获取或创建 QUIC runtime
fn get_quic_runtime() -> &'static Runtime {
    QUIC_RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("legado-quic")
            .build()
            .expect("创建 QUIC runtime 失败")
    })
}

/// 获取全局 QUIC 客户端槽位
fn get_client_slot() -> &'static Mutex<Option<QuinnClient>> {
    QUIC_CLIENT.get_or_init(|| Mutex::new(None))
}

/// 创建 QUIC 客户端
///
/// 初始化全局 QuinnClient 实例，配置连接池和 TLS。
/// 对应 Kotlin `cronetEngine` 的 lazy 初始化。
///
/// # 参数
/// - `config_json`: JSON 格式的 QuinnConfig，为空时使用默认配置
///
/// # 返回
/// 成功信息或错误
pub fn create_quinn_client(config_json: Option<String>) -> LegadoResult<String> {
    let config = if let Some(json) = config_json {
        serde_json::from_str::<QuinnConfigSerde>(&json)
            .map(|c| c.into_config())
            .map_err(|e| LegadoError::Network(format!("解析 QUIC 配置失败: {}", e)))?
    } else {
        QuinnConfig::default()
    };

    let client = QuinnClient::new(config)?;

    let runtime = get_quic_runtime();
    runtime.block_on(async {
        let slot = get_client_slot();
        let mut guard = slot.lock().await;
        *guard = Some(client);
    });

    Ok("QUIC 客户端创建成功".to_string())
}

/// 通过 QUIC 发送 GET 请求
///
/// 自动协议选择：优先 HTTP/3，失败时降级到 HTTP/2。
/// 对应 Kotlin CronetInterceptor 的 intercept 逻辑。
///
/// # 参数
/// - `url`: 请求 URL
/// - `headers_json`: 可选的请求头 JSON（HashMap<String, String>）
///
/// # 返回
/// JSON 格式的响应 { status, headers, body, url }
pub fn quinn_get(url: String, headers_json: Option<String>) -> LegadoResult<String> {
    let runtime = get_quic_runtime();
    runtime.block_on(async {
        let slot = get_client_slot();
        let guard = slot.lock().await;
        let client = guard
            .as_ref()
            .ok_or_else(|| LegadoError::Network("QUIC 客户端未初始化，请先调用 create_quinn_client".to_string()))?;

        let headers = parse_headers(headers_json)?;
        let response = client.get(&url, headers).await?;

        serde_json::to_string(&response)
            .map_err(LegadoError::Serialization)
    })
}

/// 通过 QUIC 发送 POST 请求
///
/// # 参数
/// - `url`: 请求 URL
/// - `body`: 请求体（字节序列的 base64 编码）
/// - `headers_json`: 可选的请求头 JSON
///
/// # 返回
/// JSON 格式的响应
pub fn quinn_post(url: String, body_base64: String, headers_json: Option<String>) -> LegadoResult<String> {
    let body = base64::Engine::decode(
        &base64::engine::general_purpose::STANDARD,
        &body_base64,
    )
    .map_err(|e| LegadoError::Network(format!("解码请求体失败: {}", e)))?;

    let runtime = get_quic_runtime();
    runtime.block_on(async {
        let slot = get_client_slot();
        let guard = slot.lock().await;
        let client = guard
            .as_ref()
            .ok_or_else(|| LegadoError::Network("QUIC 客户端未初始化，请先调用 create_quinn_client".to_string()))?;

        let headers = parse_headers(headers_json)?;
        let response = client.post(&url, &body, headers).await?;

        serde_json::to_string(&response)
            .map_err(LegadoError::Serialization)
    })
}

/// QUIC 性能测试
///
/// 对比 HTTP/3 vs HTTP/2 的连接速度、TTFB、下载速度。
/// 参考 Kotlin `CronetPerformanceTest.kt`。
///
/// # 参数
/// - `url`: 测试目标 URL
///
/// # 返回
/// JSON 格式的性能指标 PerformanceMetrics
pub fn quinn_performance_test(url: String) -> LegadoResult<String> {
    let runtime = get_quic_runtime();
    runtime.block_on(async {
        let slot = get_client_slot();
        let guard = slot.lock().await;
        let client = guard
            .as_ref()
            .ok_or_else(|| LegadoError::Network("QUIC 客户端未初始化，请先调用 create_quinn_client".to_string()))?;

        let metrics: PerformanceMetrics = client.performance_test(&url).await?;

        serde_json::to_string(&metrics)
            .map_err(LegadoError::Serialization)
    })
}

/// 检查 QUIC 客户端是否已初始化
pub fn quinn_is_initialized() -> bool {
    let runtime = get_quic_runtime();
    runtime.block_on(async {
        let slot = get_client_slot();
        let guard = slot.lock().await;
        guard.is_some()
    })
}

/// 清理 QUIC 连接池
pub fn quinn_cleanup() -> String {
    let runtime = get_quic_runtime();
    runtime.block_on(async {
        let slot = get_client_slot();
        let guard = slot.lock().await;
        if let Some(ref client) = *guard {
            client.cleanup_pool().await;
            "QUIC 连接池清理完成".to_string()
        } else {
            "QUIC 客户端未初始化".to_string()
        }
    })
}

// ---------- 内部辅助 ----------

/// 解析请求头 JSON
fn parse_headers(
    headers_json: Option<String>,
) -> LegadoResult<Option<std::collections::HashMap<String, String>>> {
    match headers_json {
        Some(json) if !json.is_empty() => {
            let map: std::collections::HashMap<String, String> =
                serde_json::from_str(&json)
                    .map_err(|e| LegadoError::Network(format!("解析请求头失败: {}", e)))?;
            Ok(Some(map))
        }
        _ => Ok(None),
    }
}

/// QuinnConfig 的 serde 反序列化辅助结构
///
/// 因为 QuinnConfig 包含 Duration 字段，需要自定义反序列化。
#[derive(serde::Deserialize)]
struct QuinnConfigSerde {
    /// 连接超时（秒）
    #[serde(default = "default_connect_timeout")]
    connect_timeout_secs: u64,
    /// 请求超时（秒）
    #[serde(default = "default_request_timeout")]
    request_timeout_secs: u64,
    /// 是否验证证书
    #[serde(default = "default_true")]
    verify_certs: bool,
    /// 最大空闲连接数
    #[serde(default = "default_max_idle")]
    max_idle_connections: usize,
    /// 空闲超时（秒）
    #[serde(default = "default_idle_timeout")]
    idle_timeout_secs: u64,
    /// 是否启用 HTTP/2 降级
    #[serde(default = "default_true")]
    enable_http2_fallback: bool,
    /// 是否启用 0-RTT
    #[serde(default = "default_true")]
    enable_0rtt: bool,
    /// Keep-Alive 间隔（秒）
    #[serde(default = "default_keep_alive")]
    keep_alive_interval_secs: u64,
}

impl QuinnConfigSerde {
    fn into_config(self) -> QuinnConfig {
        QuinnConfig {
            connect_timeout: std::time::Duration::from_secs(self.connect_timeout_secs),
            request_timeout: std::time::Duration::from_secs(self.request_timeout_secs),
            verify_certs: self.verify_certs,
            max_idle_connections: self.max_idle_connections,
            idle_timeout: std::time::Duration::from_secs(self.idle_timeout_secs),
            enable_http2_fallback: self.enable_http2_fallback,
            enable_0rtt: self.enable_0rtt,
            keep_alive_interval: std::time::Duration::from_secs(self.keep_alive_interval_secs),
        }
    }
}

fn default_connect_timeout() -> u64 { 10 }
fn default_request_timeout() -> u64 { 60 }
fn default_true() -> bool { true }
fn default_max_idle() -> usize { 8 }
fn default_idle_timeout() -> u64 { 30 }
fn default_keep_alive() -> u64 { 15 }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_quinn_not_initialized() {
        // 未初始化时 GET 应返回错误
        let result = quinn_get("https://example.com".to_string(), None);
        assert!(result.is_err());
    }

    #[test]
    fn test_create_client_default() {
        let result = create_quinn_client(None);
        assert!(result.is_ok());
        assert!(quinn_is_initialized());
    }

    #[test]
    fn test_create_client_with_config() {
        let config = r#"{"connect_timeout_secs": 5, "verify_certs": false, "max_idle_connections": 4}"#;
        let result = create_quinn_client(Some(config.to_string()));
        assert!(result.is_ok());
    }

    #[test]
    fn test_create_client_invalid_config() {
        let result = create_quinn_client(Some("invalid json".to_string()));
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_headers_none() {
        let result = parse_headers(None).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_headers_empty() {
        let result = parse_headers(Some(String::new())).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_parse_headers_valid() {
        let json = r#"{"Content-Type": "application/json", "Accept": "*/*"}"#;
        let result = parse_headers(Some(json.to_string())).unwrap();
        assert!(result.is_some());
        let map = result.unwrap();
        assert_eq!(map.len(), 2);
        assert_eq!(map.get("Content-Type").unwrap(), "application/json");
    }

    #[test]
    fn test_parse_headers_invalid() {
        let result = parse_headers(Some("not json".to_string()));
        assert!(result.is_err());
    }

    #[test]
    fn test_quinn_cleanup() {
        // 确保客户端已初始化
        let _ = create_quinn_client(None);
        let result = quinn_cleanup();
        assert!(result.contains("清理完成") || result.contains("未初始化"));
    }

    #[test]
    fn test_config_serde_deserialization() {
        let json = r#"{"connect_timeout_secs": 15, "request_timeout_secs": 30, "verify_certs": true, "max_idle_connections": 16, "idle_timeout_secs": 60, "enable_http2_fallback": false, "enable_0rtt": false, "keep_alive_interval_secs": 20}"#;
        let config: QuinnConfigSerde = serde_json::from_str(json).unwrap();
        let quic_config = config.into_config();
        assert_eq!(quic_config.connect_timeout, std::time::Duration::from_secs(15));
        assert_eq!(quic_config.request_timeout, std::time::Duration::from_secs(30));
        assert!(quic_config.verify_certs);
        assert_eq!(quic_config.max_idle_connections, 16);
        assert!(!quic_config.enable_http2_fallback);
        assert!(!quic_config.enable_0rtt);
    }
}
