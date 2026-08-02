//! AnalyzeUrl: URL 模板引擎
//!
//! 参考 Kotlin `AnalyzeUrl.kt`，实现完整的 URL 模板解析引擎。
//! 支持：
//! - `{key}` — 简单变量替换
//! - `<key>` — 另一种变量格式（分页列表等）
//! - `${key}` — JS 表达式变量（在此实现中作为变量查找）
//! - `{{expression}}` — 内嵌表达式替换
//! - 分页参数：`{page}` / `<page,N1,N2,...>` 自动递增
//! - 编码管道：`|urlencode`、`|base64`、`|md5`
//! - POST body 模板：JSON/Form body 中的变量替换
//! - 请求配置提取：`@Header:{key:value}`、`@Body:{json}` 格式
//! - URL 参数解析（method, headers, body, charset 等）
//! - 基础 URL 拼接与绝对路径解析

use std::collections::HashMap;

use base64::Engine;
use md5::{Digest, Md5};
use regex::Regex;

use legado_core::LegadoResult;

/// HTTP 请求方法
#[derive(Debug, Clone, PartialEq)]
pub enum RequestMethod {
    Get,
    Post,
    Head,
}

/// URL 配置选项（从 URL 尾部 JSON 中解析）
#[derive(Debug, Clone, Default)]
pub struct UrlOption {
    pub method: Option<RequestMethod>,
    pub headers: HashMap<String, String>,
    pub body: Option<String>,
    pub charset: Option<String>,
    pub content_type: Option<String>,
    pub retry: u32,
    pub timeout: Option<u64>,
    pub proxy: Option<String>,
    pub follow_redirects: Option<bool>,
}

/// URL 分析器
pub struct AnalyzeUrl {
    /// 原始 URL 规则
    rule_url: String,
    /// 处理后的最终 URL
    url: String,
    /// 基础 URL
    base_url: String,
    /// URL 不含查询参数的部分
    url_no_query: String,
    /// HTTP 方法
    method: RequestMethod,
    /// 请求头
    headers: HashMap<String, String>,
    /// 请求体
    body: Option<String>,
    /// 字符集
    charset: Option<String>,
    /// 内容类型
    content_type: Option<String>,
    /// 重试次数
    retry: u32,
    /// 超时（毫秒）
    timeout: Option<u64>,
    /// 代理
    proxy: Option<String>,
    /// 是否跟随重定向
    follow_redirects: Option<bool>,
    /// 查询参数
    query_params: HashMap<String, String>,
    /// 编码后的表单数据（POST form body）
    encoded_form: Option<String>,
    /// 编码后的查询字符串
    encoded_query: Option<String>,
}

impl AnalyzeUrl {
    /// 创建 URL 分析器（兼容旧 API）
    ///
    /// # 参数
    /// - `m_url`: URL 模板规则
    /// - `key`: 搜索关键字（可选）
    /// - `page`: 页码（可选，从1开始）
    /// - `base_url`: 基础 URL
    /// - `header_map`: 初始请求头
    pub fn new(
        m_url: &str,
        key: Option<&str>,
        page: Option<u32>,
        base_url: &str,
        header_map: Option<HashMap<String, String>>,
    ) -> Self {
        let mut instance = Self {
            rule_url: m_url.to_string(),
            url: String::new(),
            base_url: base_url.to_string(),
            url_no_query: String::new(),
            method: RequestMethod::Get,
            headers: header_map.unwrap_or_default(),
            body: None,
            charset: None,
            content_type: None,
            retry: 0,
            timeout: None,
            proxy: None,
            follow_redirects: None,
            query_params: HashMap::new(),
            encoded_form: None,
            encoded_query: None,
        };

        instance.init_url(key, page);
        instance
    }

    /// 解析 URL 模板，替换变量（新 API）
    ///
    /// # 参数
    /// - `template`: URL 模板字符串
    /// - `variables`: 变量映射表
    /// - `page`: 页码（从1开始）
    pub fn parse(
        template: &str,
        variables: &HashMap<String, String>,
        page: i32,
    ) -> LegadoResult<Self> {
        let mut instance = Self {
            rule_url: template.to_string(),
            url: String::new(),
            base_url: String::new(),
            url_no_query: String::new(),
            method: RequestMethod::Get,
            headers: HashMap::new(),
            body: None,
            charset: None,
            content_type: None,
            retry: 0,
            timeout: None,
            proxy: None,
            follow_redirects: None,
            query_params: HashMap::new(),
            encoded_form: None,
            encoded_query: None,
        };

        // 1. 提取 @Header 和 @Body 配置
        let (rule, extracted_headers, extracted_body) = Self::extract_config(&instance.rule_url);
        instance.rule_url = rule;
        instance.headers.extend(extracted_headers);
        if extracted_body.is_some() {
            instance.body = extracted_body;
        }

        // 2. 替换 {{expression}} 内嵌表达式
        instance.rule_url = Self::replace_inner_expressions(&instance.rule_url, variables);

        // 3. 替换 ${key} 变量
        instance.rule_url = Self::replace_dollar_vars(&instance.rule_url, variables);

        // 4. 替换 {key} 变量（含管道）
        instance.rule_url = Self::replace_brace_vars(&instance.rule_url, variables);

        // 5. 替换 <key> 变量
        instance.rule_url = Self::replace_angle_vars(&instance.rule_url, variables);

        // 6. 替换分页参数
        if page > 0 {
            instance.replace_page(page as u32);
        }

        // 7. 替换 body 中的变量
        if let Some(ref body) = instance.body {
            let body = Self::replace_body_vars(body, variables);
            instance.body = Some(body);
        }

        // 8. 解析 URL 和选项
        instance.analyze_url();

        Ok(instance)
    }

    /// 初始化 URL：替换参数 → 解析 URL → 解析选项
    fn init_url(&mut self, key: Option<&str>, page: Option<u32>) {
        // 0. 提取 @Header 和 @Body 配置
        let (rule, extracted_headers, extracted_body) = Self::extract_config(&self.rule_url);
        self.rule_url = rule;
        self.headers.extend(extracted_headers);
        if extracted_body.is_some() {
            self.body = extracted_body;
        }

        // 1. 替换关键字
        if let Some(k) = key {
            self.rule_url = self.rule_url.replace("searchKey", k);
        }

        // 2. 替换页码
        if let Some(p) = page {
            self.replace_page(p);
        }

        // 3. 解析 URL 和选项
        self.analyze_url();
    }

    // ========== 变量替换 ==========

    /// 替换 `{key}` 和 `{key|pipe}` 变量
    fn replace_brace_vars(template: &str, variables: &HashMap<String, String>) -> String {
        let re = Regex::new(r"\{([a-zA-Z_][a-zA-Z0-9_]*)(\|[^}]+)?\}").unwrap();
        re.replace_all(template, |caps: &regex::Captures| {
            let key = &caps[1];
            let pipes_str = caps.get(2).map_or("", |m| m.as_str());
            let value = variables.get(key).cloned().unwrap_or_default();

            if pipes_str.is_empty() {
                value
            } else {
                let pipes: Vec<&str> = pipes_str
                    .trim_start_matches('|')
                    .split('|')
                    .map(|s| s.trim())
                    .collect();
                Self::apply_pipes(&value, &pipes)
            }
        })
        .to_string()
    }

    /// 替换 `<key>` 角度括号变量
    fn replace_angle_vars(template: &str, variables: &HashMap<String, String>) -> String {
        // 注意：只替换单个单词形式的 <key>，不匹配分页列表 <page,N1,N2,...>
        let re = Regex::new(r"<([a-zA-Z_][a-zA-Z0-9_]*)>").unwrap();
        re.replace_all(template, |caps: &regex::Captures| {
            let key = &caps[1];
            variables.get(key).cloned().unwrap_or_default()
        })
        .to_string()
    }

    /// 替换 `${key}` 美元符号变量
    fn replace_dollar_vars(template: &str, variables: &HashMap<String, String>) -> String {
        let re = Regex::new(r"\$\{([a-zA-Z_][a-zA-Z0-9_.]*)\}").unwrap();
        re.replace_all(template, |caps: &regex::Captures| {
            let key = &caps[1];
            variables.get(key).cloned().unwrap_or_default()
        })
        .to_string()
    }

    /// 替换 `{{expression}}` 内嵌表达式
    ///
    /// 对于简单变量名直接替换，对于复杂表达式保留原样（需要 JS 引擎）。
    fn replace_inner_expressions(template: &str, variables: &HashMap<String, String>) -> String {
        if !template.contains("{{") || !template.contains("}}") {
            return template.to_string();
        }

        let re = Regex::new(r"\{\{(.+?)\}\}").unwrap();
        re.replace_all(template, |caps: &regex::Captures| {
            let expr = caps[1].trim();
            // 简单变量名直接替换
            if expr
                .chars()
                .all(|c| c.is_alphanumeric() || c == '_' || c == '.')
            {
                variables.get(expr).cloned().unwrap_or_default()
            } else {
                // 复杂表达式：尝试作为变量名查找
                variables
                    .get(expr)
                    .cloned()
                    .unwrap_or_else(|| caps[0].to_string())
            }
        })
        .to_string()
    }

    /// 替换 body 中的变量
    fn replace_body_vars(body: &str, variables: &HashMap<String, String>) -> String {
        let mut result = body.to_string();
        // 替换 {key} 变量
        result = Self::replace_brace_vars(&result, variables);
        // 替换 ${key} 变量
        result = Self::replace_dollar_vars(&result, variables);
        // 替换 {{expression}}
        result = Self::replace_inner_expressions(&result, variables);
        result
    }

    // ========== 分页参数 ==========

    /// 替换页码参数 `{page}` 和 `<page,N1,N2,...>`
    fn replace_page(&mut self, page: u32) {
        let rule = &self.rule_url;

        // 简单模式: {page} → 页码数字
        let rule = rule.replace("{page}", &page.to_string());

        // 列表模式: <page,N1,N2,...> → 根据页码选择对应值
        let rule = Self::replace_page_list_angle(&rule, page);

        // 列表模式: {page,N1,N2,...} → 根据页码选择对应值
        let rule = Self::replace_page_list_brace(&rule, page);

        self.rule_url = rule;
    }

    /// 替换 `<page,N1,N2,...>` 角度括号分页列表
    fn replace_page_list_angle(rule: &str, page: u32) -> String {
        let mut result = rule.to_string();
        let page_idx = page as usize;

        while let Some(start) = result.find("<page,") {
            if let Some(end) = result[start..].find('>') {
                let end = start + end;
                let params_str = &result[start + 6..end];
                let params: Vec<&str> = params_str.split(',').collect();

                let replacement = if page_idx > 0 && page_idx <= params.len() {
                    params[page_idx - 1].trim()
                } else if !params.is_empty() {
                    params.last().unwrap().trim()
                } else {
                    ""
                };

                result = format!("{}{}{}", &result[..start], replacement, &result[end + 1..]);
            } else {
                break;
            }
        }

        result
    }

    /// 替换 `{page,N1,N2,...}` 花括号分页列表
    fn replace_page_list_brace(rule: &str, page: u32) -> String {
        let mut result = rule.to_string();
        let page_idx = page as usize;

        while let Some(start) = result.find("{page,") {
            if let Some(end) = result[start..].find('}') {
                let end = start + end;
                let params_str = &result[start + 6..end];
                let params: Vec<&str> = params_str.split(',').collect();

                let replacement = if page_idx > 0 && page_idx <= params.len() {
                    params[page_idx - 1].trim()
                } else if !params.is_empty() {
                    params.last().unwrap().trim()
                } else {
                    ""
                };

                result = format!("{}{}{}", &result[..start], replacement, &result[end + 1..]);
            } else {
                break;
            }
        }

        result
    }

    // ========== 管道编码 ==========

    /// 处理管道编码
    ///
    /// 支持的管道：
    /// - `urlencode` — URL 编码
    /// - `base64` — Base64 编码
    /// - `md5` — MD5 哈希（32位十六进制）
    pub fn apply_pipes(value: &str, pipes: &[&str]) -> String {
        let mut result = value.to_string();
        for pipe in pipes {
            match pipe.trim() {
                "urlencode" => {
                    result = urlencoding::encode(&result).to_string();
                }
                "base64" => {
                    result = base64::engine::general_purpose::STANDARD.encode(result.as_bytes());
                }
                "md5" => {
                    let mut hasher = Md5::new();
                    hasher.update(result.as_bytes());
                    let hash = hasher.finalize();
                    result = format!("{:x}", hash);
                }
                _ => {
                    // 未知管道，保持不变
                }
            }
        }
        result
    }

    // ========== 配置提取 ==========

    /// 从 URL 中提取 `@Header:{key:value}` 和 `@Body:{json}` 配置
    ///
    /// 返回 (清理后的URL, 提取的headers, 提取的body)
    pub fn extract_config(url: &str) -> (String, HashMap<String, String>, Option<String>) {
        let mut result_url = url.to_string();
        let mut headers = HashMap::new();
        let mut body = None;

        // 提取 @Header:{key:value}
        let header_re = Regex::new(r"@Header:\{([^:}]+):([^}]*)\}").unwrap();
        for caps in header_re.captures_iter(url) {
            let key = caps[1].trim().to_string();
            let value = caps[2].trim().to_string();
            headers.insert(key, value);
        }
        result_url = header_re.replace_all(&result_url, "").to_string();

        // 提取 @Body:{json}
        let body_re = Regex::new(r"@Body:\{(.+)\}").unwrap();
        if let Some(caps) = body_re.captures(&result_url) {
            let json_body = caps[1].to_string();
            body = Some(json_body);
            result_url = body_re.replace_all(&result_url, "").to_string();
        }

        // 清理多余的空格
        result_url = result_url.trim().to_string();

        (result_url, headers, body)
    }

    // ========== URL 解析 ==========

    /// 解析 URL 和选项
    fn analyze_url(&mut self) {
        let rule_url = self.rule_url.trim().to_string();

        // 尝试从 URL 尾部分离 JSON 选项
        let (url_part, option_part) = Self::split_url_option(&rule_url);

        // 拼接绝对 URL
        self.url = Self::get_absolute_url(&self.base_url, &url_part);
        self.url_no_query = self.url.clone();

        // 解析 JSON 选项
        if let Some(opt_str) = option_part {
            if let Ok(option) = Self::parse_url_option(&opt_str) {
                self.apply_option(option);
            }
        }

        // 提取 proxy from headers
        if let Some(proxy) = self.headers.remove("proxy") {
            self.proxy = Some(proxy);
        }

        // 处理查询参数
        match self.method {
            RequestMethod::Post => {
                // POST: 处理 body
                if let Some(ref body) = self.body.clone() {
                    let is_json = body.trim().starts_with('{') || body.trim().starts_with('[');
                    let is_xml = body.trim().starts_with("<?xml") || body.trim().starts_with('<');
                    let has_content_type = self.headers.contains_key("Content-Type")
                        || self.headers.contains_key("content-type");
                    if !is_json && !is_xml && !has_content_type {
                        // Form body: 编码参数
                        self.encoded_form = Some(Self::encode_form_params(body));
                    }
                }
            }
            _ => {
                if let Some(pos) = self.url.find('?') {
                    let query = self.url[pos + 1..].to_string();
                    let encoded = Self::encode_query_params(&query);
                    self.encoded_query = Some(encoded.clone());
                    self.parse_query_params(&query);
                    self.url_no_query = self.url[..pos].to_string();
                    self.url = format!("{}?{}", self.url_no_query, encoded);
                }
            }
        }
    }

    /// 解析查询参数到 HashMap
    fn parse_query_params(&mut self, query: &str) {
        for pair in query.split('&') {
            if let Some(eq_pos) = pair.find('=') {
                let key = &pair[..eq_pos];
                let value = &pair[eq_pos + 1..];
                self.query_params.insert(key.to_string(), value.to_string());
            } else if !pair.is_empty() {
                self.query_params.insert(pair.to_string(), String::new());
            }
        }
    }

    /// 编码表单参数
    fn encode_form_params(body: &str) -> String {
        let mut result = String::new();
        for pair in body.split('&') {
            if !result.is_empty() {
                result.push('&');
            }
            if let Some(eq_pos) = pair.find('=') {
                let key = &pair[..eq_pos];
                let value = &pair[eq_pos + 1..];
                result.push_str(&urlencoding::encode(key));
                result.push('=');
                result.push_str(&urlencoding::encode(value));
            } else {
                result.push_str(&urlencoding::encode(pair));
            }
        }
        result
    }

    /// 编码查询参数
    fn encode_query_params(query: &str) -> String {
        // 检查是否已经编码过（包含 %XX 形式）
        if query.contains('%') && Regex::new(r"%[0-9A-Fa-f]{2}").unwrap().is_match(query) {
            return query.to_string();
        }
        // 对每个 key=value 对的 key 和 value 分别编码
        let mut result = String::new();
        for pair in query.split('&') {
            if !result.is_empty() {
                result.push('&');
            }
            if let Some(eq_pos) = pair.find('=') {
                let key = &pair[..eq_pos];
                let value = &pair[eq_pos + 1..];
                result.push_str(&urlencoding::encode(key));
                result.push('=');
                result.push_str(&urlencoding::encode(value));
            } else {
                result.push_str(&urlencoding::encode(pair));
            }
        }
        result
    }

    /// 从 URL 中分离 URL 和 JSON 选项
    fn split_url_option(rule: &str) -> (String, Option<String>) {
        let rule = rule.trim();

        if let Some(comma_pos) = rule.find(',') {
            let after_comma = rule[comma_pos + 1..].trim();
            if after_comma.starts_with('{') && after_comma.ends_with('}') {
                return (rule[..comma_pos].to_string(), Some(after_comma.to_string()));
            }
        }

        (rule.to_string(), None)
    }

    /// 解析 URL 选项 JSON
    fn parse_url_option(json_str: &str) -> Result<UrlOption, serde_json::Error> {
        let value: serde_json::Value = serde_json::from_str(json_str)?;

        let mut option = UrlOption::default();

        if let Some(obj) = value.as_object() {
            if let Some(m) = obj.get("method").and_then(|v| v.as_str()) {
                option.method = match m.to_uppercase().as_str() {
                    "POST" => Some(RequestMethod::Post),
                    "HEAD" => Some(RequestMethod::Head),
                    _ => Some(RequestMethod::Get),
                };
            }

            if let Some(h) = obj.get("headers").and_then(|v| v.as_object()) {
                for (k, v) in h {
                    if let Some(s) = v.as_str() {
                        option.headers.insert(k.clone(), s.to_string());
                    }
                }
            }

            if let Some(b) = obj.get("body").and_then(|v| v.as_str()) {
                option.body = Some(b.to_string());
            } else if let Some(b) = obj.get("body") {
                // body 可能是 JSON 对象
                option.body = Some(b.to_string());
            }

            if let Some(c) = obj.get("charset").and_then(|v| v.as_str()) {
                option.charset = Some(c.to_string());
            }

            if let Some(t) = obj.get("type").and_then(|v| v.as_str()) {
                option.content_type = Some(t.to_string());
            }

            if let Some(r) = obj.get("retry").and_then(|v| v.as_u64()) {
                option.retry = r as u32;
            }

            if let Some(t) = obj.get("timeout").and_then(|v| v.as_u64()) {
                option.timeout = Some(t);
            }

            if let Some(p) = obj.get("proxy").and_then(|v| v.as_str()) {
                option.proxy = Some(p.to_string());
            }

            if let Some(f) = obj.get("followRedirects").and_then(|v| v.as_bool()) {
                option.follow_redirects = Some(f);
            }
        }

        Ok(option)
    }

    /// 应用 URL 选项
    fn apply_option(&mut self, option: UrlOption) {
        if let Some(m) = option.method {
            self.method = m;
        }
        self.headers.extend(option.headers);
        if option.body.is_some() {
            self.body = option.body;
        }
        self.charset = option.charset;
        if option.content_type.is_some() {
            self.content_type = option.content_type;
        }
        self.retry = option.retry;
        self.timeout = option.timeout;
        if option.proxy.is_some() {
            self.proxy = option.proxy;
        }
        self.follow_redirects = option.follow_redirects;
    }

    /// 将相对 URL 转为绝对 URL
    ///
    /// 参考 Kotlin `NetworkUtils.getAbsoluteURL`
    pub fn get_absolute_url(base: &str, relative: &str) -> String {
        let relative = relative.trim();

        if relative.starts_with("http://") || relative.starts_with("https://") {
            return relative.to_string();
        }

        if relative.starts_with("data:") {
            return relative.to_string();
        }

        let base = base.trim();
        if base.is_empty() {
            return relative.to_string();
        }

        // 协议相对路径
        if relative.starts_with("//") {
            if let Some(pos) = base.find("://") {
                return format!("{}:{}", &base[..pos], relative);
            }
            return format!("https:{}", relative);
        }

        // 绝对路径
        if relative.starts_with('/') {
            if let Some(pos) = base.find("://") {
                if let Some(slash_pos) = base[pos + 3..].find('/') {
                    let domain = &base[..pos + 3 + slash_pos];
                    return format!("{}{}", domain, relative);
                } else {
                    return format!("{}{}", base, relative);
                }
            }
            return format!("{}/{}", base.trim_end_matches('/'), relative);
        }

        // 相对路径
        if base.ends_with('/') {
            format!("{}{}", base, relative)
        } else if let Some(pos) = base.rfind('/') {
            format!("{}/{}", &base[..pos], relative)
        } else {
            format!("{}/{}", base, relative)
        }
    }

    // ========== 公共访问器 ==========

    pub fn url(&self) -> &str {
        &self.url
    }

    pub fn url_no_query(&self) -> &str {
        &self.url_no_query
    }

    pub fn rule_url(&self) -> &str {
        &self.rule_url
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub fn method(&self) -> &RequestMethod {
        &self.method
    }

    pub fn headers(&self) -> &HashMap<String, String> {
        &self.headers
    }

    pub fn headers_mut(&mut self) -> &mut HashMap<String, String> {
        &mut self.headers
    }

    pub fn body(&self) -> Option<&str> {
        self.body.as_deref()
    }

    pub fn charset(&self) -> Option<&str> {
        self.charset.as_deref()
    }

    pub fn content_type(&self) -> Option<&str> {
        self.content_type.as_deref()
    }

    pub fn retry(&self) -> u32 {
        self.retry
    }

    pub fn timeout(&self) -> Option<u64> {
        self.timeout
    }

    pub fn proxy(&self) -> Option<&str> {
        self.proxy.as_deref()
    }

    pub fn follow_redirects(&self) -> Option<bool> {
        self.follow_redirects
    }

    pub fn query_params(&self) -> &HashMap<String, String> {
        &self.query_params
    }

    pub fn encoded_form(&self) -> Option<&str> {
        self.encoded_form.as_deref()
    }

    pub fn encoded_query(&self) -> Option<&str> {
        self.encoded_query.as_deref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // --- 1. 简单变量替换 ---
    #[test]
    fn test_simple_brace_var_replacement() {
        let mut vars = HashMap::new();
        vars.insert("keyword".to_string(), "rust编程".to_string());
        vars.insert("type".to_string(), "book".to_string());

        let url =
            AnalyzeUrl::parse("https://example.com/search?q={keyword}&t={type}", &vars, 1).unwrap();
        assert_eq!(
            url.url(),
            "https://example.com/search?q=rust%E7%BC%96%E7%A8%8B&t=book"
        );
    }

    // --- 2. 分页参数 ---
    #[test]
    fn test_page_replacement_simple() {
        let url = AnalyzeUrl::new(
            "https://example.com/list?page={page}",
            None,
            Some(3),
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/list?page=3");
    }

    #[test]
    fn test_page_list_angle_bracket() {
        let url = AnalyzeUrl::new(
            "https://example.com/list/<page,1,page/2,page/3>",
            None,
            Some(2),
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/list/page/2");
    }

    #[test]
    fn test_page_list_brace() {
        let url = AnalyzeUrl::new(
            "https://example.com/list/{page,index.html,p2.html,p3.html}",
            None,
            Some(1),
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/list/index.html");
    }

    #[test]
    fn test_page_overflow_uses_last() {
        let url = AnalyzeUrl::new(
            "https://example.com/<page,p1,p2,p3>",
            None,
            Some(10),
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/p3");
    }

    // --- 3. URL 编码管道 ---
    #[test]
    fn test_urlencode_pipe() {
        let mut vars = HashMap::new();
        vars.insert("q".to_string(), "hello world".to_string());

        let url =
            AnalyzeUrl::parse("https://example.com/search?q={q|urlencode}", &vars, 1).unwrap();
        assert_eq!(url.url(), "https://example.com/search?q=hello%20world");
    }

    #[test]
    fn test_base64_pipe() {
        let mut vars = HashMap::new();
        vars.insert("data".to_string(), "hello".to_string());

        let url = AnalyzeUrl::parse("https://example.com/api?d={data|base64}", &vars, 1).unwrap();
        assert_eq!(url.url(), "https://example.com/api?d=aGVsbG8%3D");
    }

    #[test]
    fn test_md5_pipe() {
        let mut vars = HashMap::new();
        vars.insert("pwd".to_string(), "123456".to_string());

        let url = AnalyzeUrl::parse("https://example.com/api?h={pwd|md5}", &vars, 1).unwrap();
        assert_eq!(
            url.url(),
            "https://example.com/api?h=e10adc3949ba59abbe56e057f20f883e"
        );
    }

    #[test]
    fn test_chained_pipes() {
        let mut vars = HashMap::new();
        vars.insert("val".to_string(), "test value".to_string());

        let url = AnalyzeUrl::parse("https://example.com/api?v={val|base64|urlencode}", &vars, 1)
            .unwrap();
        // base64("test value") = "dGVzdCB2YWx1ZQ=="
        // urlencode("dGVzdCB2YWx1ZQ==") = "dGVzdCB2YWx1ZQ%3D%3D"
        assert_eq!(url.url(), "https://example.com/api?v=dGVzdCB2YWx1ZQ%3D%3D");
    }

    // --- 4. POST body 模板 ---
    #[test]
    fn test_post_body_with_json_option() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/api,{"method":"POST","body":"key=value&foo=bar"}"#,
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/api");
        assert_eq!(url.method(), &RequestMethod::Post);
        assert_eq!(url.body(), Some("key=value&foo=bar"));
    }

    #[test]
    fn test_post_body_template_with_vars() {
        let mut vars = HashMap::new();
        vars.insert("user".to_string(), "admin".to_string());
        vars.insert("pass".to_string(), "secret".to_string());

        let url = AnalyzeUrl::parse(
            r#"https://example.com/login,{"method":"POST","body":"{\"username\":\"{user}\",\"password\":\"{pass}\"}"}"#,
            &vars,
            1,
        )
        .unwrap();
        assert_eq!(url.method(), &RequestMethod::Post);
        let body = url.body().unwrap();
        assert!(body.contains("admin"));
        assert!(body.contains("secret"));
    }

    // --- 5. Header 提取 ---
    #[test]
    fn test_header_extraction() {
        let url = AnalyzeUrl::new(
            "https://example.com/api @Header:{Authorization:Bearer token123} @Header:{Accept:application/json}",
            None,
            None,
            "",
            None,
        );
        assert_eq!(
            url.headers().get("Authorization"),
            Some(&"Bearer token123".to_string())
        );
        assert_eq!(
            url.headers().get("Accept"),
            Some(&"application/json".to_string())
        );
    }

    // --- 6. 复杂嵌套模板 ---
    #[test]
    fn test_complex_template() {
        let mut vars = HashMap::new();
        vars.insert("host".to_string(), "api.example.com".to_string());
        vars.insert("token".to_string(), "abc123".to_string());
        vars.insert("q".to_string(), "rust lang".to_string());

        let url = AnalyzeUrl::parse("https://${host}/search?q={q|urlencode}&t={token}", &vars, 1)
            .unwrap();
        assert_eq!(
            url.url(),
            "https://api.example.com/search?q=rust%20lang&t=abc123"
        );
    }

    // --- 7. Inner expression {{}} ---
    #[test]
    fn test_inner_expression() {
        let mut vars = HashMap::new();
        vars.insert("bookName".to_string(), "Rust编程".to_string());

        let url = AnalyzeUrl::parse("https://example.com/search?q={{bookName}}", &vars, 1).unwrap();
        assert_eq!(
            url.url(),
            "https://example.com/search?q=Rust%E7%BC%96%E7%A8%8B"
        );
    }

    // --- 8. 绝对 URL 拼接 ---
    #[test]
    fn test_absolute_url() {
        assert_eq!(
            AnalyzeUrl::get_absolute_url("https://example.com/path/", "page.html"),
            "https://example.com/path/page.html"
        );
        assert_eq!(
            AnalyzeUrl::get_absolute_url("https://example.com/path/", "/absolute.html"),
            "https://example.com/absolute.html"
        );
        assert_eq!(
            AnalyzeUrl::get_absolute_url("https://example.com", "//cdn.example.com/file"),
            "https://cdn.example.com/file"
        );
        assert_eq!(
            AnalyzeUrl::get_absolute_url("", "https://other.com/page"),
            "https://other.com/page"
        );
    }

    // --- 9. URL 与 JSON 选项分离 ---
    #[test]
    fn test_split_url_option() {
        let (url, opt) = AnalyzeUrl::split_url_option(r#"https://example.com,{"method":"POST"}"#);
        assert_eq!(url, "https://example.com");
        assert!(opt.is_some());
        assert_eq!(opt.unwrap(), r#"{"method":"POST"}"#);

        let (url2, opt2) = AnalyzeUrl::split_url_option("https://example.com/path");
        assert_eq!(url2, "https://example.com/path");
        assert!(opt2.is_none());
    }

    // --- 10. 关键字替换 ---
    #[test]
    fn test_keyword_replacement() {
        let url = AnalyzeUrl::new(
            "https://example.com/search?q=searchKey",
            Some("rust"),
            None,
            "",
            None,
        );
        assert!(url.url().contains("q=rust"));
    }

    // --- 11. @Body 提取 ---
    #[test]
    fn test_body_extraction() {
        let (url, headers, body) =
            AnalyzeUrl::extract_config(r#"https://example.com/api @Body:{"key":"value"}"#);
        assert_eq!(url, "https://example.com/api");
        assert!(headers.is_empty());
        assert_eq!(body.unwrap(), r#""key":"value""#);
    }

    // --- 12. 查询参数解析 ---
    #[test]
    fn test_query_params() {
        let url = AnalyzeUrl::new(
            "https://example.com/search?q=test&page=1&sort=desc",
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.url_no_query(), "https://example.com/search");
        assert_eq!(url.query_params().get("q"), Some(&"test".to_string()));
        assert_eq!(url.query_params().get("page"), Some(&"1".to_string()));
        assert_eq!(url.query_params().get("sort"), Some(&"desc".to_string()));
    }

    // --- 13. apply_pipes 静态方法 ---
    #[test]
    fn test_apply_pipes_empty() {
        assert_eq!(AnalyzeUrl::apply_pipes("hello", &[]), "hello");
    }

    #[test]
    fn test_apply_pipes_urlencode() {
        assert_eq!(
            AnalyzeUrl::apply_pipes("hello world", &["urlencode"]),
            "hello%20world"
        );
    }

    #[test]
    fn test_apply_pipes_base64() {
        assert_eq!(AnalyzeUrl::apply_pipes("hello", &["base64"]), "aGVsbG8=");
    }

    #[test]
    fn test_apply_pipes_md5() {
        assert_eq!(
            AnalyzeUrl::apply_pipes("123456", &["md5"]),
            "e10adc3949ba59abbe56e057f20f883e"
        );
    }

    // --- 14. 相对路径拼接 ---
    #[test]
    fn test_relative_url_with_base() {
        let url = AnalyzeUrl::new(
            "/api/search?q=test",
            None,
            None,
            "https://example.com/path/",
            None,
        );
        assert_eq!(url.url(), "https://example.com/api/search?q=test");
    }

    // --- 15. Angle bracket variable ---
    #[test]
    fn test_angle_bracket_var() {
        let mut vars = HashMap::new();
        vars.insert("category".to_string(), "fiction".to_string());

        let url = AnalyzeUrl::parse("https://example.com/books/<category>/list", &vars, 1).unwrap();
        assert_eq!(url.url(), "https://example.com/books/fiction/list");
    }
}
