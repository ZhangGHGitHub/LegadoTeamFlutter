//! HTTP 响应封装

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// HTTP 响应结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LegadoResponse {
    /// HTTP 状态码
    pub status: u16,
    /// 响应头（每个头取最后一个值）
    pub headers: HashMap<String, String>,
    /// 响应体（字符串形式）
    pub body: String,
    /// 最终 URL（可能经过重定向）
    pub url: String,
}

impl LegadoResponse {
    /// 判断请求是否成功（2xx 状态码）
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    /// 获取指定响应头的值（不区分大小写）
    pub fn header(&self, name: &str) -> Option<&String> {
        let lower = name.to_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.to_lowercase() == lower)
            .map(|(_, v)| v)
    }

    /// 获取 Content-Type
    pub fn content_type(&self) -> Option<&String> {
        self.header("content-type")
    }
}

/// 二进制 HTTP 响应结构（Task #113：TTS 音频等二进制资源，避免 UTF-8 有损转换）
#[derive(Debug, Clone)]
pub struct LegadoRawResponse {
    /// HTTP 状态码
    pub status: u16,
    /// 响应头（每个头取最后一个值）
    pub headers: HashMap<String, String>,
    /// 响应体原始字节
    pub body: Vec<u8>,
    /// 最终 URL（可能经过重定向）
    pub url: String,
}

impl LegadoRawResponse {
    /// 判断请求是否成功（2xx 状态码）
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status)
    }

    /// 获取指定响应头的值（不区分大小写）
    pub fn header(&self, name: &str) -> Option<&String> {
        let lower = name.to_lowercase();
        self.headers
            .iter()
            .find(|(k, _)| k.to_lowercase() == lower)
            .map(|(_, v)| v)
    }

    /// 获取 Content-Type
    pub fn content_type(&self) -> Option<&String> {
        self.header("content-type")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_response(status: u16, headers: HashMap<String, String>, body: &str) -> LegadoResponse {
        LegadoResponse {
            status,
            headers,
            body: body.to_string(),
            url: "https://example.com".to_string(),
        }
    }

    #[test]
    fn test_is_success_2xx() {
        let r = make_response(200, HashMap::new(), "ok");
        assert!(r.is_success());
        let r2 = make_response(299, HashMap::new(), "ok");
        assert!(r2.is_success());
    }

    #[test]
    fn test_is_not_success() {
        let r = make_response(404, HashMap::new(), "not found");
        assert!(!r.is_success());
        let r2 = make_response(500, HashMap::new(), "error");
        assert!(!r2.is_success());
        let r3 = make_response(301, HashMap::new(), "redirect");
        assert!(!r3.is_success());
    }

    #[test]
    fn test_header_case_insensitive() {
        let mut headers = HashMap::new();
        headers.insert("Content-Type".to_string(), "text/html".to_string());
        headers.insert("X-Custom".to_string(), "value".to_string());
        let r = make_response(200, headers, "");
        assert_eq!(r.header("content-type"), Some(&"text/html".to_string()));
        assert_eq!(r.header("CONTENT-TYPE"), Some(&"text/html".to_string()));
        assert_eq!(r.header("x-custom"), Some(&"value".to_string()));
    }

    #[test]
    fn test_content_type() {
        let mut headers = HashMap::new();
        headers.insert("Content-Type".to_string(), "application/json".to_string());
        let r = make_response(200, headers, "");
        assert_eq!(r.content_type(), Some(&"application/json".to_string()));
    }

    #[test]
    fn test_missing_header() {
        let r = make_response(200, HashMap::new(), "");
        assert_eq!(r.header("X-Missing"), None);
        assert_eq!(r.content_type(), None);
    }

    #[test]
    fn test_response_serde() {
        let r = make_response(200, HashMap::new(), "body");
        let json = serde_json::to_string(&r).unwrap();
        let de: LegadoResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(de.status, 200);
        assert_eq!(de.body, "body");
        assert_eq!(de.url, "https://example.com");
    }

    #[test]
    fn test_raw_response_helpers() {
        let mut headers = HashMap::new();
        headers.insert("Content-Type".to_string(), "audio/mpeg".to_string());
        let r = LegadoRawResponse {
            status: 200,
            headers,
            body: vec![0xFF, 0xFB, 0x90, 0x00],
            url: "https://example.com/tts.mp3".to_string(),
        };
        assert!(r.is_success());
        assert_eq!(r.content_type(), Some(&"audio/mpeg".to_string()));
        assert_eq!(r.body.len(), 4);
    }
}
