//! 统一错误类型

use thiserror::Error;

/// Legado 全局错误枚举
#[derive(Debug, Error)]
pub enum LegadoError {
    #[error("Parser error: {0}")]
    Parser(String),

    #[error("Network error: {0}")]
    Network(String),

    #[error("JS engine error: {0}")]
    JsEngine(String),

    #[error("Database error: {0}")]
    Database(String),

    #[error("Book parsing error: {0}")]
    BookParse(String),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Serialization error: {0}")]
    Serialization(#[from] serde_json::Error),

    #[error("FFI error: {0}")]
    Ffi(String),

    #[error("Timeout: {0}")]
    Timeout(String),

    #[error("TOC empty: {0}")]
    TocEmpty(String),

    #[error("Content empty: {0}")]
    ContentEmpty(String),

    /// 书源需要登录（loginCheckJs 检测判定未登录，对齐原版 LoginSourceException 语义）
    #[error("Login required: {0}")]
    LoginRequired(String),

    #[error("Internal error: {0}")]
    Internal(String),
}

/// 统一 Result 类型别名
pub type LegadoResult<T> = Result<T, LegadoError>;

impl LegadoError {
    /// 将错误转换为 FFI 错误码
    pub fn to_error_code(&self) -> i32 {
        match self {
            LegadoError::Parser(_) => 1001,
            LegadoError::Network(_) => 1002,
            LegadoError::JsEngine(_) => 1003,
            LegadoError::Database(_) => 1004,
            LegadoError::BookParse(_) => 1005,
            LegadoError::Io(_) => 1006,
            LegadoError::Serialization(_) => 1007,
            LegadoError::Ffi(_) => 1008,
            LegadoError::Timeout(_) => 1009,
            LegadoError::TocEmpty(_) => 1010,
            LegadoError::ContentEmpty(_) => 1011,
            LegadoError::LoginRequired(_) => 1012,
            LegadoError::Internal(_) => 1999,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_error_codes() {
        assert_eq!(LegadoError::Parser("x".into()).to_error_code(), 1001);
        assert_eq!(LegadoError::Network("x".into()).to_error_code(), 1002);
        assert_eq!(LegadoError::JsEngine("x".into()).to_error_code(), 1003);
        assert_eq!(LegadoError::Database("x".into()).to_error_code(), 1004);
        assert_eq!(LegadoError::BookParse("x".into()).to_error_code(), 1005);
        assert_eq!(LegadoError::Ffi("x".into()).to_error_code(), 1008);
        assert_eq!(LegadoError::Timeout("x".into()).to_error_code(), 1009);
        assert_eq!(LegadoError::Internal("x".into()).to_error_code(), 1999);
    }

    #[test]
    fn test_error_display() {
        let e = LegadoError::Parser("test error".into());
        assert!(e.to_string().contains("test error"));
        assert!(e.to_string().contains("Parser"));
    }

    #[test]
    fn test_io_error_conversion() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "file not found");
        let legado_err: LegadoError = io_err.into();
        assert_eq!(legado_err.to_error_code(), 1006);
    }

    #[test]
    fn test_serde_error_conversion() {
        let bad_json = "{invalid}";
        let serde_err = serde_json::from_str::<String>(bad_json).unwrap_err();
        let legado_err: LegadoError = serde_err.into();
        assert_eq!(legado_err.to_error_code(), 1007);
    }
}
