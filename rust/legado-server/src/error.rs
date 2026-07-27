//! API 错误类型，将 LegadoError 转换为 HTTP JSON 响应

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::json;

use legado_core::LegadoError;

/// API 错误包装类型，实现 `IntoResponse` 以便在 axum handler 中直接返回
#[derive(Debug)]
pub struct ApiError(pub LegadoError);

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, error_type) = match &self.0 {
            LegadoError::Parser(_) => (StatusCode::BAD_REQUEST, "parser"),
            LegadoError::Network(_) => (StatusCode::BAD_GATEWAY, "network"),
            LegadoError::JsEngine(_) => (StatusCode::INTERNAL_SERVER_ERROR, "js_engine"),
            LegadoError::Database(_) => (StatusCode::INTERNAL_SERVER_ERROR, "database"),
            LegadoError::BookParse(_) => (StatusCode::BAD_REQUEST, "book_parse"),
            LegadoError::Io(_) => (StatusCode::INTERNAL_SERVER_ERROR, "io"),
            LegadoError::Serialization(_) => (StatusCode::INTERNAL_SERVER_ERROR, "serialization"),
            LegadoError::Ffi(_) => (StatusCode::INTERNAL_SERVER_ERROR, "ffi"),
            LegadoError::Timeout(_) => (StatusCode::GATEWAY_TIMEOUT, "timeout"),
            LegadoError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
        };

        let body = json!({
            "error": {
                "type": error_type,
                "code": self.0.to_error_code(),
                "message": self.0.to_string(),
            }
        });

        (status, axum::Json(body)).into_response()
    }
}

/// 便于在 handler 中使用 `?` 运算符，将 `LegadoError` 自动转换为 `ApiError`
impl From<LegadoError> for ApiError {
    fn from(err: LegadoError) -> Self {
        ApiError(err)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::response::IntoResponse;

    #[tokio::test]
    async fn test_api_error_database() {
        let err = ApiError(LegadoError::Database("test error".into()));
        let resp = err.into_response();
        assert_eq!(resp.status(), StatusCode::INTERNAL_SERVER_ERROR);
    }

    #[tokio::test]
    async fn test_api_error_parser() {
        let err = ApiError(LegadoError::Parser("bad input".into()));
        let resp = err.into_response();
        assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn test_api_error_timeout() {
        let err = ApiError(LegadoError::Timeout("timed out".into()));
        let resp = err.into_response();
        assert_eq!(resp.status(), StatusCode::GATEWAY_TIMEOUT);
    }

    #[tokio::test]
    async fn test_api_error_network() {
        let err = ApiError(LegadoError::Network("connection refused".into()));
        let resp = err.into_response();
        assert_eq!(resp.status(), StatusCode::BAD_GATEWAY);
    }

    #[test]
    fn test_from_legado_error() {
        let legado_err = LegadoError::Internal("oops".into());
        let api_err: ApiError = legado_err.into();
        assert!(matches!(api_err.0, LegadoError::Internal(_)));
    }
}
