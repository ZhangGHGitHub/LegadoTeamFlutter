//! SSL/TLS 配置
//!
//! 提供可选的 SSL 证书验证控制和自定义 CA 证书支持，
//! 对应 Kotlin 侧 `SSLHelper.unsafeSSLSocketFactory` 的功能。

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
    pub fn apply(&self, builder: ClientBuilder) -> ClientBuilder {
        let mut builder = if !self.verify {
            builder.danger_accept_invalid_certs(true)
        } else {
            builder
        };

        // 添加自定义 CA 证书
        if let Some(ref pem) = self.custom_ca {
            if let Ok(cert) = reqwest::Certificate::from_pem(pem.as_bytes()) {
                builder = builder.add_root_certificate(cert);
            } else {
                log::warn!("SslConfig: failed to parse custom CA PEM, ignoring");
            }
        }

        builder
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

    #[test]
    fn test_apply_verify_false() {
        let cfg = SslConfig::unsafe_ssl();
        let builder = reqwest::ClientBuilder::new();
        // apply 不应 panic
        let _builder = cfg.apply(builder);
    }

    #[test]
    fn test_apply_verify_true() {
        let cfg = SslConfig::default();
        let builder = reqwest::ClientBuilder::new();
        let _builder = cfg.apply(builder);
    }

    #[test]
    fn test_apply_invalid_ca_does_not_panic() {
        let cfg = SslConfig::with_ca("this is not a valid PEM");
        let builder = reqwest::ClientBuilder::new();
        // 无效 PEM 应被忽略而不是 panic
        let _builder = cfg.apply(builder);
    }

    #[test]
    fn test_ssl_config_clone() {
        let cfg = SslConfig {
            verify: false,
            custom_ca: Some("test-ca".to_string()),
        };
        let cloned = cfg.clone();
        assert_eq!(cloned.verify, false);
        assert_eq!(cloned.custom_ca, Some("test-ca".to_string()));
    }
}
