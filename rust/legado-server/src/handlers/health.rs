//! 健康检查端点

use axum::Json;
use serde_json::{json, Value};

/// GET /api/health — 服务健康检查
pub async fn health_check() -> Json<Value> {
    Json(json!({
        "status": "ok",
        "service": "legado-server",
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn test_health_check() {
        let resp = health_check().await;
        assert_eq!(resp.0["status"], "ok");
        assert_eq!(resp.0["service"], "legado-server");
    }
}
