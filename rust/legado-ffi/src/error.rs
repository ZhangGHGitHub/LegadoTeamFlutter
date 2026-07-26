//! FFI 错误类型
//!
//! 可序列化的 FfiError，用于跨 FFI 边界传递错误信息。

use serde::Serialize;

use legado_core::LegadoError;

/// FFI 层错误结构（可序列化为 JSON 传递给 Dart）
#[derive(Debug, Serialize)]
pub struct FfiError {
    /// 错误码，与 `LegadoError::to_error_code()` 一致
    pub code: i32,
    /// 错误描述
    pub message: String,
}

impl FfiError {
    /// 从错误码和消息构造
    pub fn new(code: i32, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl From<LegadoError> for FfiError {
    fn from(e: LegadoError) -> Self {
        let code = e.to_error_code();
        let message = e.to_string();
        Self { code, message }
    }
}

impl From<serde_json::Error> for FfiError {
    fn from(e: serde_json::Error) -> Self {
        Self {
            code: 1007,
            message: format!("JSON 序列化错误: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ffi_error_new() {
        let err = FfiError::new(42, "test error");
        assert_eq!(err.code, 42);
        assert_eq!(err.message, "test error");
    }

    #[test]
    fn test_ffi_error_serialize() {
        let err = FfiError::new(1001, "parse error");
        let json = serde_json::to_value(&err).unwrap();
        assert_eq!(json["code"], 1001);
        assert_eq!(json["message"], "parse error");
    }

    #[test]
    fn test_ffi_error_from_legado_error() {
        let legado_err = LegadoError::Parser("test".into());
        let ffi_err: FfiError = legado_err.into();
        assert_eq!(ffi_err.code, 1001);
        assert!(ffi_err.message.contains("test"));
    }

    #[test]
    fn test_ffi_error_from_serde() {
        let bad_json = "{invalid}";
        let serde_err = serde_json::from_str::<String>(bad_json).unwrap_err();
        let ffi_err: FfiError = serde_err.into();
        assert_eq!(ffi_err.code, 1007);
    }
}
