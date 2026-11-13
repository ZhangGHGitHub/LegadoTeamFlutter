//! SSL/TLS 配置
//!
//! 提供可选的 SSL 证书验证控制和自定义 CA 证书支持，
//! 对应 Kotlin 侧 `SSLHelper.unsafeSSLSocketFactory` 的功能。

use legado_core::{LegadoError, LegadoResult};
use reqwest::ClientBuilder;

/// SSL/TLS 配置
#[derive(Debug, Clone)]
pub struct SslConfig {
    /// 是否验证证书（默认 `true`）
    ///
    /// 设为 `false` 时等同于 Kotlin `SSLHelper.unsafeSSLSocketFactory`，
    /// 允许自签名证书或过期证书。
    pub verify: bool,
    /// 自定义 CA 证书（PEM 格式）
    ///
    /// 用于特定书源的私有 CA 场景。
    pub custom_ca: Option<String>,
}

impl Default for SslConfig {
    fn default() -> Self {
        Self {
            verify: true,
            custom_ca: None,
        }
    }
}

impl SslConfig {
    /// 创建跳过证书验证的配置（对应 Kotlin unsafeSSL）
    pub fn unsafe_ssl() -> Self {
        Self {
            verify: false,
            custom_ca: None,
        }
    }

    /// 创建带有自定义 CA 的配置
    pub fn with_ca(pem: impl Into<String>) -> Self {
        Self {
            verify: true,
            custom_ca: Some(pem.into()),
        }
    }

    /// 将 SSL 配置应用到 `reqwest::ClientBuilder`
    ///
    /// [P3-5 引擎链审查 2026-11-13] 自定义 CA PEM 解析失败不再静默忽略：
    /// 原实现只 `log::warn` 后按默认根证书继续，用户配置私有 CA 后只会看到
    /// 无原因的 TLS 握手失败。现改为返回显式错误（调用方 `LegadoClient::build`
    /// 映射为 `LegadoError::Network` 上抛），由配置方 fail-fast 修正证书；
    /// 不采用「回退默认根证书 + 告警」是因为静默回退会重演「配置无效但无
    /// 可见原因」的原始缺陷。客户端构建是惰性的（`http_state::shared_client`
    /// 首次网络调用才构建），故坏 CA 不会阻止 App 启动。
    pub fn apply(&self, builder: ClientBuilder) -> LegadoResult<ClientBuilder> {
        let mut builder = if !self.verify {
            builder.danger_accept_invalid_certs(true)
        } else {
            builder
        };

        // 添加自定义 CA 证书
        if let Some(ref pem) = self.custom_ca {
            // 注：`Certificate::from_pem` 在 rustls 后端只缓存原始字节、不做
            // 解析（非法 PEM 要等到 ClientBuilder::build 才失败且错误无上下文），
            // 故用 `from_pem_bundle` 显式解析校验（支持单证书与证书包）。
            let certs = reqwest::Certificate::from_pem_bundle(pem.as_bytes()).map_err(|e| {
                log::error!("SslConfig: 自定义 CA 证书 PEM 解析失败: {e}");
                LegadoError::Network(format!(
                    "自定义 CA 证书 PEM 解析失败（证书未生效，请检查配置）: {e}"
                ))
            })?;
            if certs.is_empty() {
                log::error!("SslConfig: 自定义 CA 证书 PEM 不含任何证书");
                return Err(LegadoError::Network(
                    "自定义 CA 证书 PEM 解析失败（未找到证书块，请检查配置）".into(),
                ));
            }
            for cert in certs {
                builder = builder.add_root_certificate(cert);
            }
        }

        Ok(builder)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_ssl_config() {
        let cfg = SslConfig::default();
        assert!(cfg.verify);
        assert!(cfg.custom_ca.is_none());
    }

    #[test]
    fn test_unsafe_ssl_config() {
        let cfg = SslConfig::unsafe_ssl();
        assert!(!cfg.verify);
        assert!(cfg.custom_ca.is_none());
    }

    #[test]
    fn test_with_ca_config() {
        let pem = "-----BEGIN CERTIFICATE-----\nMIIBxx...\n-----END CERTIFICATE-----";
        let cfg = SslConfig::with_ca(pem);
        assert!(cfg.verify);
        assert_eq!(cfg.custom_ca.as_deref(), Some(pem));
    }

    /// 自签 EC P-256 证书（CN/SAN = 127.0.0.1，有效期至 2126 年）
    ///
    /// 测试专用固定证书（与 `rule_update_client` 回环 TLS 用例同源）：
    /// 仅用于验证合法 PEM 可被 reqwest 解析，不含任何生产密钥。
    const VALID_CERT_PEM: &str = "-----BEGIN CERTIFICATE-----
MIIBkDCCATagAwIBAgIUF0cdaE3svNVYJJvydEXIE2cfDMcwCgYIKoZIzj0EAwIw
FDESMBAGA1UEAwwJMTI3LjAuMC4xMCAXDTI2MTExMjIxMzMwN1oYDzIxMjYxMDE5
MjEzMzA3WjAUMRIwEAYDVQQDDAkxMjcuMC4wLjEwWTATBgcqhkjOPQIBBggqhkjO
PQMBBwNCAARDkRBd8tPc64lDWM6OuAqyKaMjGbMfVllgrBt9PFZyH7n/YB4MiPB3
9jz//Ymj4SGRVV/7F5/bxyYfakf79GRLo2QwYjAdBgNVHQ4EFgQUOBBox2NG23gm
kIyIgTLlQNdwXmUwHwYDVR0jBBgwFoAUOBBox2NG23gmkIyIgTLlQNdwXmUwDwYD
VR0TAQH/BAUwAwEB/zAPBgNVHREECDAGhwR/AAABMAoGCCqGSM49BAMCA0gAMEUC
ICdGnHNZWRLrd/zP/SdI9P+r9OJt7sOWrtMz3s4O126eAiEAh+Fsg91vOOBQ8a5N
7mLdDfiVX28FKtBzkiqOdDpy1DI=
-----END CERTIFICATE-----";

    #[test]
    fn test_apply_verify_false() {
        let cfg = SslConfig::unsafe_ssl();
        let builder = reqwest::ClientBuilder::new();
        // apply 不应 panic
        let _builder = cfg.apply(builder).expect("无自定义 CA 时 apply 应成功");
    }

    #[test]
    fn test_apply_verify_true() {
        let cfg = SslConfig::default();
        let builder = reqwest::ClientBuilder::new();
        let _builder = cfg.apply(builder).expect("默认配置 apply 应成功");
    }

    /// P3-5：坏 PEM 必须返回显式错误（不得静默按默认根证书继续）
    #[test]
    fn test_apply_invalid_ca_returns_error() {
        let cfg = SslConfig::with_ca("this is not a valid PEM");
        let builder = reqwest::ClientBuilder::new();
        let err = cfg
            .apply(builder)
            .expect_err("无效 PEM 应返回错误而不是静默忽略");
        let msg = err.to_string();
        assert!(
            msg.contains("自定义 CA") && msg.contains("PEM 解析失败"),
            "错误应明确指向自定义 CA 配置: {msg}"
        );
    }

    /// P3-5 对照组：合法 PEM 正常加载（不误伤有效配置）
    #[test]
    fn test_apply_valid_ca_loads() {
        let cfg = SslConfig::with_ca(VALID_CERT_PEM);
        let builder = reqwest::ClientBuilder::new();
        let _builder = cfg.apply(builder).expect("合法 PEM 应成功加入根证书");
    }

    #[test]
    fn test_ssl_config_clone() {
        let cfg = SslConfig {
            verify: false,
            custom_ca: Some("test-ca".to_string()),
        };
        let cloned = cfg.clone();
        assert!(!cloned.verify);
        assert_eq!(cloned.custom_ca, Some("test-ca".to_string()));
    }
}
