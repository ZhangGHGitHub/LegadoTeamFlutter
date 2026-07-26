//! HTTP 请求封装
//!
//! 参考 Kotlin `AnalyzeUrl.kt` 构建请求的字段设计。

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

/// HTTP 方法
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "UPPERCASE")]
pub enum Method {
    #[default]
    Get,
    Post,
    Head,
    Put,
    Delete,
    Patch,
    Options,
}

impl Method {
    /// 从字符串解析方法（不区分大小写）
    pub fn from_str_loose(s: &str) -> Self {
        match s.to_uppercase().as_str() {
            "POST" => Method::Post,
            "HEAD" => Method::Head,
            "PUT" => Method::Put,
            "DELETE" => Method::Delete,
            "PATCH" => Method::Patch,
            "OPTIONS" => Method::Options,
            _ => Method::Get,
        }
    }

    /// 转换为 reqwest 的 Method
    pub fn to_reqwest(&self) -> reqwest::Method {
        match self {
            Method::Get => reqwest::Method::GET,
            Method::Post => reqwest::Method::POST,
            Method::Head => reqwest::Method::HEAD,
            Method::Put => reqwest::Method::PUT,
            Method::Delete => reqwest::Method::DELETE,
            Method::Patch => reqwest::Method::PATCH,
            Method::Options => reqwest::Method::OPTIONS,
        }
    }
}

/// HTTP 请求结构
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LegadoRequest {
    /// 目标 URL
    pub url: String,
    /// HTTP 方法
    pub method: Method,
    /// 请求头
    pub headers: HashMap<String, String>,
    /// 请求体（仅 POST/PUT 等使用）
    pub body: Option<String>,
    /// 请求超时（覆盖客户端默认值）
    #[serde(skip)]
    pub timeout: Option<Duration>,
}

impl LegadoRequest {
    /// 创建一个简单的 GET 请求
    pub fn get(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            method: Method::Get,
            headers: HashMap::new(),
            body: None,
            timeout: None,
        }
    }

    /// 创建一个 POST 请求
    pub fn post(url: impl Into<String>, body: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            method: Method::Post,
            headers: HashMap::new(),
            body: Some(body.into()),
            timeout: None,
        }
    }
}
