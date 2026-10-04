//! HTTP 响应封装

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

use legado_core::{LegadoError, LegadoResult};

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

/// 流式二进制 HTTP 响应（大文件下载：字节流边到边写盘，禁止整文件入内存）
///
/// 由 [`crate::LegadoClient::send_stream`] 返回：响应头/状态码/最终 URL 在
/// 返回前已收集，响应体经 [`Self::next_chunk`] 逐块消费。请求语义
/// （cookie 注入与写侧门控、客户端级重试、按域名限流、UA 轮换/代理中间件）
/// 与 `get_raw` 完全一致；差异仅在响应体不在网络层收集。
///
/// 域名限流许可（[`tokio::sync::OwnedSemaphorePermit`]）随本结构持有，
/// 直至流结束或结构被丢弃——与 `get_raw` 在响应体读完后释放许可等价。
pub struct LegadoStreamResponse {
    status: u16,
    headers: HashMap<String, String>,
    url: String,
    response: reqwest::Response,
    /// 域名限流许可（随响应体消费结束/结构丢弃释放）
    _permit: Option<tokio::sync::OwnedSemaphorePermit>,
}

impl LegadoStreamResponse {
    /// 由已发送的 reqwest 响应构造（收集响应头/状态/最终 URL；body 保持未读）
    pub(crate) fn new(
        response: reqwest::Response,
        permit: Option<tokio::sync::OwnedSemaphorePermit>,
    ) -> Self {
        let final_url = response.url().to_string();
        let status = response.status().as_u16();
        let mut headers = HashMap::new();
        for (name, value) in response.headers() {
            if let Ok(v) = value.to_str() {
                headers.insert(name.as_str().to_string(), v.to_string());
            }
        }
        Self {
            status,
            headers,
            url: final_url,
            response,
            _permit: permit,
        }
    }

    /// 状态码
    pub fn status(&self) -> u16 {
        self.status
    }

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

    /// 响应头全量（供 cookie 写回等复用）
    pub fn headers(&self) -> &HashMap<String, String> {
        &self.headers
    }

    /// 获取 Content-Type
    pub fn content_type(&self) -> Option<&String> {
        self.header("content-type")
    }

    /// `Content-Length` 声明值（缺失/非法/负数返回 None）
    ///
    /// 对齐 OkHttp `ResponseBody.contentLength()` 的「未知为 -1」语义：
    /// 调用方按 `> 0` 判定预期大小，`None` 表示未知而非 0 字节。
    pub fn content_length(&self) -> Option<u64> {
        self.header("content-length")
            .and_then(|v| v.trim().parse::<u64>().ok())
    }

    /// 重定向后的最终 URL
    pub fn url(&self) -> &str {
        &self.url
    }

    /// 读取下一块响应体字节；流结束返回 `None`
    ///
    /// 传输错误映射为 [`LegadoError::Network`]（调用方负责清理半成品文件）。
    pub async fn next_chunk(&mut self) -> LegadoResult<Option<Vec<u8>>> {
        self.response
            .chunk()
            .await
            .map(|opt| opt.map(|b| b.to_vec()))
            .map_err(|e| LegadoError::Network(format!("读取响应流失败: {e}")))
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
