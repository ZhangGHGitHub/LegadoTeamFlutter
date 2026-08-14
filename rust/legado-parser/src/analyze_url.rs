//! AnalyzeUrl: URL 模板引擎
//!
//! 参考 Kotlin `AnalyzeUrl.kt`，实现完整的 URL 模板解析引擎。
//! 支持：
//! - `{key}` — 简单变量替换
//! - `<key>` — 另一种变量格式（分页列表等）
//! - `${key}` — JS 表达式变量（在此实现中作为变量查找）
//! - `{{expression}}` — 内嵌表达式替换（支持 JS 执行）
//! - `@js:...` / `<js>...</js>` — 内嵌 JS 执行并替换
//! - 分页参数：`{{page}}` / `{page}` / 原版 `<(.*?)>` 页码列表；兼容旧式 `{1}` / `{1,2,3}`
//! - 编码管道：`|urlencode`、`|base64`、`|md5`
//! - POST body 模板：JSON/Form body 中的变量替换
//! - 请求配置提取：`@Header:{key:value}`、`@Body:{json}` 格式
//! - URL 参数解析（method, headers, body, charset, webView, js 等）
//! - 基础 URL 拼接与绝对路径解析
//! - data: URI 解析（base64 编码内容提取）
//! - WebView 请求模式标记（由上层 Flutter 侧处理实际加载）
//! - bookName/title 等内置变量支持
//! - getByteArrayAwait 流式读取（data URI 直接解码）

use std::collections::HashMap;

use base64::Engine;
use md5::{Digest, Md5};
use regex::Regex;

use legado_core::{LegadoError, LegadoResult};

use crate::analyze_rule::JsExecutor;

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
    /// 是否使用 WebView 加载（由 Flutter 侧处理）
    pub use_web_view: bool,
    /// WebView 中执行的 JS 脚本
    pub web_js: Option<String>,
    /// WebView 等待页面加载完毕的延迟时间（毫秒）
    pub web_view_delay_time: u64,
    /// 解析完 URL 参数时执行的 JS（执行结果赋值给 url）
    pub js: Option<String>,
    /// 得到访问结果后执行的 JS（对结果进行二次处理，返回为 body）
    pub body_js: Option<String>,
    /// 自定义域名 IP
    pub dns_ip: Option<String>,
    /// 服务器 ID
    pub server_id: Option<i64>,
}

/// data: URI 解析结果
#[derive(Debug, Clone, PartialEq)]
pub struct DataUriContent {
    /// MIME 类型（如 text/html, image/png）
    pub mime_type: String,
    /// 字符集（如 utf-8），默认 utf-8
    pub charset: String,
    /// 是否为 base64 编码
    pub is_base64: bool,
    /// 解码后的原始内容字节
    pub data: Vec<u8>,
}

/// 模板上下文：提供 bookName/title 等内置变量
#[derive(Debug, Clone, Default)]
pub struct TemplateContext {
    /// 书名
    pub book_name: Option<String>,
    /// 章节标题
    pub title: Option<String>,
    /// 作者
    pub author: Option<String>,
    /// 额外变量
    pub extra: HashMap<String, String>,
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
    /// 是否使用 WebView 加载
    use_web_view: bool,
    /// WebView 中执行的 JS 脚本
    web_js: Option<String>,
    /// WebView 等待延迟时间（毫秒）
    web_view_delay_time: u64,
    /// 解析完 URL 后执行的 JS（结果赋值给 url）
    url_js: Option<String>,
    /// 得到访问结果后执行的 JS（对 body 二次处理）
    body_js: Option<String>,
    /// 自定义域名 IP
    dns_ip: Option<String>,
    /// 服务器 ID
    server_id: Option<i64>,
    /// 响应类型（如 hex 表示返回十六进制编码）
    response_type: Option<String>,
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
            use_web_view: false,
            web_js: None,
            web_view_delay_time: 0,
            url_js: None,
            body_js: None,
            dns_ip: None,
            server_id: None,
            response_type: None,
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
        // 对齐原版 AnalyzeUrl(baseUrl=书源 URL)：相对 searchUrl
        // （如 `/search?q={{key}}`、`statics/search.aspx?...`）必须拼到书源域名。
        // 变量 `baseUrl` 由 build_search_url 注入；缺省时保持空（绝对 URL 不受影响）。
        // 此前 base_url 恒空 → 相对路径原样发出 → 图片源约半数搜索空结果。— Reasonix
        let base_url = variables
            .get("baseUrl")
            .cloned()
            .unwrap_or_default();

        // 确保 {{page}} 在 replace_inner_expressions 阶段可解析（对齐原版 bindings["page"]）
        let owned_vars;
        let variables = if page > 0 && !variables.contains_key("page") {
            let mut merged = variables.clone();
            merged.insert("page".to_string(), page.to_string());
            owned_vars = merged;
            &owned_vars
        } else {
            variables
        };

        let mut instance = Self {
            rule_url: template.to_string(),
            url: String::new(),
            base_url,
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
            use_web_view: false,
            web_js: None,
            web_view_delay_time: 0,
            url_js: None,
            body_js: None,
            dns_ip: None,
            server_id: None,
            response_type: None,
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

        // 5. 替换 <key> 变量（data: URI 载荷可含 HTML 标签，须豁免）
        if !Self::is_data_uri_rule(&instance.rule_url) {
            instance.rule_url = Self::replace_angle_vars(&instance.rule_url, variables);
        }

        // 6. 替换分页参数（data: URI 同理豁免 `<...>` 页码列表语义）
        if page > 0 && !Self::is_data_uri_rule(&instance.rule_url) {
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
    ///
    /// 对齐原版 `AnalyzeUrl.initUrl`：先处理 `{{key}}`/`{{page}}`，再处理 `<...>` 页码列表。
    /// 发现页（explore）走本路径，必须正确展开 `/list1/{{page}}.html`。
    fn init_url(&mut self, key: Option<&str>, page: Option<u32>) {
        // 0. 提取 @Header 和 @Body 配置
        let (rule, extracted_headers, extracted_body) = Self::extract_config(&self.rule_url);
        self.rule_url = rule;
        self.headers.extend(extracted_headers);
        if extracted_body.is_some() {
            self.body = extracted_body;
        }

        // 1. 替换关键字（`{{key}}` 须先于可能的 `{key}` 扩展）
        if let Some(k) = key {
            self.rule_url = self.rule_url.replace("{{key}}", k);
            self.rule_url = self.rule_url.replace("searchKey", k);
            self.rule_url = self.rule_url.replace("{key}", k);
        }

        // 2. 替换页码（含 {{page}} / 页码列表 / {page}）
        if let Some(p) = page {
            if !Self::is_data_uri_rule(&self.rule_url) {
                self.replace_page(p);
            }
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

    /// 替换页码参数，对齐原版 `AnalyzeUrl.replaceKeyPageJs` 中的 page 段：
    /// 1. 先展开 `{{page}}`（禁止用 `{page}` 子串误伤，否则 `{{page}}`→`{1}`）
    /// 2. 再按原版 `pagePattern = <(.*?)>` 做页码列表选取
    /// 3. 兼容未迁移旧源的 `{1}` / `{1,2,3}` 花括号页码列表
    /// 4. 最后替换独立 `{page}`
    fn replace_page(&mut self, page: u32) {
        let page_str = page.to_string();
        let mut rule = self.rule_url.clone();

        // 1. {{page}} 必须先于 {page}，否则 "{{page}}".replace("{page}","1") → "{1}"
        rule = rule.replace("{{page}}", &page_str);

        // 2. 原版角度括号页码列表 <a,b,c> / <1> / <,2.html>
        rule = Self::replace_page_list_angle(&rule, page);

        // 3. 旧式花括号页码列表 {1} / {1,2,3} / {index.html,p2.html}
        //    （不含 {page} 字母键；{page,a,b} 亦按列表处理）
        rule = Self::replace_page_list_brace(&rule, page);

        // 4. 独立 {page}（此时 {{page}} 已消除，可安全替换）
        rule = rule.replace("{page}", &page_str);

        self.rule_url = rule;
    }

    /// 按页码从逗号列表取值（对齐原版：`page < size` 用 `pages[page-1]`，否则用 last）
    fn pick_page_list_value(pages: &[&str], page: u32) -> String {
        if pages.is_empty() {
            return String::new();
        }
        let page_idx = page as usize;
        let value = if page_idx > 0 && page_idx < pages.len() {
            pages[page_idx - 1]
        } else {
            pages[pages.len() - 1]
        };
        value.trim().to_string()
    }

    /// 替换原版 `<(.*?)>` 角度括号分页列表
    fn replace_page_list_angle(rule: &str, page: u32) -> String {
        let re = Regex::new(r"<([^<>]*)>").unwrap();
        re.replace_all(rule, |caps: &regex::Captures| {
            let pages: Vec<&str> = caps[1].split(',').collect();
            Self::pick_page_list_value(&pages, page)
        })
        .to_string()
    }

    /// 替换花括号页码列表：
    /// - `{page,a,b,c}`：`page,` 为标记前缀，按页码从 a,b,c 取值（历史扩展）
    /// - `{1}` / `{1,2,3}`：旧源未迁移形态（导入后原版会变成 `<1>` / `<1,2,3>`）
    fn replace_page_list_brace(rule: &str, page: u32) -> String {
        // `{page,a,b,c}` 标记前缀列表
        let re_marked = Regex::new(r"\{page,([^}]*)\}").unwrap();
        let result = re_marked
            .replace_all(rule, |caps: &regex::Captures| {
                let pages: Vec<&str> = caps[1].split(',').collect();
                Self::pick_page_list_value(&pages, page)
            })
            .to_string();

        // 旧式 `{1}` / `{1,2,3}`（以数字开头的列表）
        let re_numeric = Regex::new(r"\{(\d+(?:\s*,\s*[^}]*)?)\}").unwrap();
        re_numeric
            .replace_all(&result, |caps: &regex::Captures| {
                let pages: Vec<&str> = caps[1].split(',').collect();
                Self::pick_page_list_value(&pages, page)
            })
            .to_string()
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
                        // Form body: 按 charset 编码参数（对齐原版 encodeParams + postForm）
                        self.encoded_form = Some(Self::encode_form_params(
                            body,
                            self.charset.as_deref(),
                        ));
                        // 原版 postForm 使用 application/x-www-form-urlencoded
                        self.headers
                            .entry("Content-Type".to_string())
                            .or_insert_with(|| {
                                "application/x-www-form-urlencoded".to_string()
                            });
                    }
                }
            }
            _ => {
                if let Some(pos) = self.url.find('?') {
                    let query = self.url[pos + 1..].to_string();
                    // 对齐原版 analyzeQuery：charset=gbk 时按 GBK 百分号编码关键词
                    let encoded =
                        Self::encode_query_params(&query, self.charset.as_deref());
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

    /// 编码表单参数（对齐原版 `URLEncoder.encode(value, charset)`）
    ///
    /// `charset` 为 `gbk`/`GBK`/`gb2312` 等时按该编码百分号编码；缺省/UTF-8 保持原行为。
    /// 空格编码为 `+`（application/x-www-form-urlencoded）。— Reasonix 2026-08-12
    fn encode_form_params(body: &str, charset: Option<&str>) -> String {
        let mut result = String::new();
        for pair in body.split('&') {
            if !result.is_empty() {
                result.push('&');
            }
            if let Some(eq_pos) = pair.find('=') {
                let key = &pair[..eq_pos];
                let value = &pair[eq_pos + 1..];
                result.push_str(&Self::percent_encode_form_component(key, charset));
                result.push('=');
                result.push_str(&Self::percent_encode_form_component(value, charset));
            } else {
                result.push_str(&Self::percent_encode_form_component(pair, charset));
            }
        }
        result
    }

    /// 编码查询参数
    ///
    /// 对齐原版 `analyzeQuery`：
    /// - 已含 `%XX` → 原样
    /// - 指定非 UTF-8 charset → 整段按该编码百分号编码，保留 `&`/`=` 等分隔符
    /// - 否则按 UTF-8 对每个 key/value 分别编码
    fn encode_query_params(query: &str, charset: Option<&str>) -> String {
        // 检查是否已经编码过（包含 %XX 形式）
        if query.contains('%') && Regex::new(r"%[0-9A-Fa-f]{2}").unwrap().is_match(query) {
            return query.to_string();
        }
        if Self::is_non_utf8_charset(charset) {
            return Self::percent_encode_query_whole(query, charset.unwrap());
        }
        // 对每个 key=value 对的 key 和 value 分别编码（UTF-8）
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

    fn is_non_utf8_charset(charset: Option<&str>) -> bool {
        match charset.map(|s| s.trim()) {
            None | Some("") => false,
            Some(cs) if cs.eq_ignore_ascii_case("utf-8") || cs.eq_ignore_ascii_case("utf8") => {
                false
            }
            Some(_) => true,
        }
    }

    /// 解析 charset 标签；未知标签回退 UTF-8
    fn encoding_for_label(charset: &str) -> &'static encoding_rs::Encoding {
        encoding_rs::Encoding::for_label(charset.trim().as_bytes())
            .unwrap_or(encoding_rs::UTF_8)
    }

    /// 表单分量编码（对齐 Java `URLEncoder`：字母数字 `.-*_` 原样，空格→`+`，其余 `%XX`）
    fn percent_encode_form_component(value: &str, charset: Option<&str>) -> String {
        let enc = match charset {
            Some(cs) if Self::is_non_utf8_charset(Some(cs)) => Self::encoding_for_label(cs),
            _ => encoding_rs::UTF_8,
        };
        if enc == encoding_rs::UTF_8 {
            // urlencoding 用 %20；表单惯例为空格→+
            return urlencoding::encode(value).replace("%20", "+");
        }
        let (bytes, _, _) = enc.encode(value);
        Self::percent_encode_bytes_form(&bytes)
    }

    /// 查询整段编码（对齐原版 queryEncoder：保留 `&` `=` 等分隔符）
    fn percent_encode_query_whole(query: &str, charset: &str) -> String {
        let enc = Self::encoding_for_label(charset);
        let (bytes, _, _) = enc.encode(query);
        let mut out = String::with_capacity(bytes.len() * 3);
        for &b in bytes.iter() {
            // RFC3986 unreserved + 原版额外放行的查询分隔符
            match b {
                b'A'..=b'Z'
                | b'a'..=b'z'
                | b'0'..=b'9'
                | b'-'
                | b'.'
                | b'_'
                | b'~'
                | b'!'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'('
                | b')'
                | b'*'
                | b'+'
                | b','
                | b'/'
                | b':'
                | b';'
                | b'='
                | b'?'
                | b'@'
                | b'['
                | b']'
                | b'^'
                | b'`'
                | b'{'
                | b'|'
                | b'}' => out.push(b as char),
                b' ' => out.push('+'),
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    }

    fn percent_encode_bytes_form(bytes: &[u8]) -> String {
        let mut out = String::with_capacity(bytes.len() * 3);
        for &b in bytes {
            match b {
                b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                    out.push(b as char);
                }
                b' ' => out.push('+'),
                _ => out.push_str(&format!("%{b:02X}")),
            }
        }
        out
    }

    /// data: URI 规则豁免分页/角度变量替换（载荷段可含 HTML 标签）
    fn is_data_uri_rule(rule: &str) -> bool {
        rule.trim().starts_with("data:")
    }

    /// 从 URL 中分离 URL 和 JSON 选项
    fn split_url_option(rule: &str) -> (String, Option<String>) {
        let rule = rule.trim();

        // data: URI 豁免：对齐原版 AnalyzeUrl.kt 先经 dataUriRegex 判定，
        // data 段本身可能以 `,{...}` 开头（如 JSON 内容），不可误判为请求选项
        if rule.starts_with("data:") {
            return (rule.to_string(), None);
        }

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

            // WebView 相关选项
            if let Some(wv) = obj.get("webView") {
                option.use_web_view = match wv {
                    serde_json::Value::Bool(b) => *b,
                    serde_json::Value::String(s) => {
                        !s.is_empty() && s != "false" && s != "0"
                    }
                    serde_json::Value::Null => false,
                    _ => true,
                };
            }

            if let Some(wj) = obj.get("webJs").and_then(|v| v.as_str()) {
                if !wj.is_empty() {
                    option.web_js = Some(wj.to_string());
                }
            }

            if let Some(dt) = obj.get("webViewDelayTime").and_then(|v| v.as_u64()) {
                option.web_view_delay_time = dt;
            }

            // 解析完 URL 后执行的 JS
            if let Some(js) = obj.get("js").and_then(|v| v.as_str()) {
                if !js.is_empty() {
                    option.js = Some(js.to_string());
                }
            }

            // 对响应 body 二次处理的 JS
            if let Some(bjs) = obj.get("bodyJs").and_then(|v| v.as_str()) {
                if !bjs.is_empty() {
                    option.body_js = Some(bjs.to_string());
                }
            }

            // 自定义域名 IP
            if let Some(dns) = obj.get("dnsIp").and_then(|v| v.as_str()) {
                if !dns.is_empty() {
                    option.dns_ip = Some(dns.trim().to_string());
                }
            }

            // 服务器 ID
            if let Some(sid) = obj.get("serverID").and_then(|v| v.as_i64()) {
                option.server_id = Some(sid);
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
        // WebView 相关
        self.use_web_view = option.use_web_view;
        if option.web_js.is_some() {
            self.web_js = option.web_js;
        }
        self.web_view_delay_time = option.web_view_delay_time;
        // JS 相关
        if option.js.is_some() {
            self.url_js = option.js;
        }
        if option.body_js.is_some() {
            self.body_js = option.body_js;
        }
        // 其他
        if option.dns_ip.is_some() {
            self.dns_ip = option.dns_ip;
        }
        if option.server_id.is_some() {
            self.server_id = option.server_id;
        }
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

        // 对齐原版 NetworkUtils.getAbsoluteURL(baseURL.substringBefore(","))：
        // 1) 去掉 JSON 选项尾巴；2) 去掉 #fragment（书源 URL 常用 #🎃/#pb1101
        // 作唯一后缀，Java URL 解析会忽略 fragment，Rust 若原样拼接会得到
        // `https://host#tag/path` 假 URL → 整批相对 searchUrl 失败）。— Reasonix
        let base = Self::normalize_base_url_for_join(base.trim());
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

        // 相对路径（无前导 /）：对齐 NetworkUtils.getAbsoluteURL
        // 注意：base 若仅为 `https://host.com`（无 path），`rfind('/')` 会命中
        // `://` 里的斜杠，拼出 `https://statics/...` 这种假域名（拷贝漫画
        // searchUrl=`statics/search.aspx?...` 实测）。须跳过 scheme 段。— Reasonix
        if let Some(scheme_end) = base.find("://") {
            let after_scheme = &base[scheme_end + 3..];
            if !after_scheme.contains('/') {
                return format!("{}/{}", base.trim_end_matches('/'), relative);
            }
        }
        if base.ends_with('/') {
            format!("{}{}", base, relative)
        } else if let Some(pos) = base.rfind('/') {
            format!("{}/{}", &base[..pos], relative)
        } else {
            format!("{}/{}", base, relative)
        }
    }

    /// 拼接用 base：去掉 `,JSON` 选项与 `#fragment`
    fn normalize_base_url_for_join(base: &str) -> &str {
        let without_opt = base.split(',').next().unwrap_or(base).trim();
        without_opt.split('#').next().unwrap_or(without_opt).trim()
    }

    // ========== JS 内嵌执行 ==========

    /// 处理 `@js:...` 和 `<js>...</js>` 内嵌 JS 执行
    ///
    /// 参考 Kotlin `analyzeJs()` 方法：
    /// - 匹配 `<js>...</js>` 或 `@js:...` 模式
    /// - 用 JS 引擎执行表达式，将结果替换回 URL
    /// - 支持 `@result` 引用上一步结果
    pub fn analyze_js(rule: &str, js_executor: &dyn JsExecutor) -> String {
        Self::analyze_js_with_error(rule, js_executor).0
    }

    /// [`Self::analyze_js`] 的错误感知版本：JS 执行失败时返回
    /// `(保留原始文本, Some(错误信息))`，供 `parse_with_js` 上抛
    /// 真实错误（懒人听书未配置登录会话时 lrtsResolveSession 抛
    /// 「请先登录…」；此前静默保留 `@js:` 文本会被当 URL 请求 →
    /// HTTP 404 误导）。
    pub fn analyze_js_with_error(
        rule: &str,
        js_executor: &dyn JsExecutor,
    ) -> (String, Option<String>) {
        // 匹配 <js>...</js> 或 @js:... 模式
        let js_re = Regex::new(r"(?i)<js>([\s\S]*?)</js>|@js:([\s\S]*)").unwrap();

        let mut result = rule.to_string();
        let mut first_err: Option<String> = None;
        let mut start = 0;
        let rule_chars = rule;

        for caps in js_re.captures_iter(rule_chars) {
            let full_match = caps.get(0).unwrap();
            let match_start = full_match.start();
            let match_end = full_match.end();

            // 处理 JS 块之前的文本
            if match_start > start {
                let prefix = rule[start..match_start].trim();
                if !prefix.is_empty() {
                    result = prefix.replace("@result", &result);
                }
            }

            // 提取 JS 代码（group(1) 是 <js>...</js>，group(2) 是 @js:...）
            let js_code = caps
                .get(1)
                .or_else(|| caps.get(2))
                .map(|m| m.as_str())
                .unwrap_or("");

            // 执行 JS 并获取结果
            match js_executor.execute_js(js_code) {
                Ok(js_result) => {
                    result = js_result;
                }
                Err(e) => {
                    // JS 执行失败：保留原始结果，但记录首个错误供上抛
                    if first_err.is_none() {
                        first_err = Some(e);
                    }
                }
            }

            start = match_end;
        }

        // 处理最后一个 JS 块之后的文本
        if rule.len() > start {
            let suffix = rule[start..].trim();
            if !suffix.is_empty() {
                result = suffix.replace("@result", &result);
            }
        }

        (result, first_err)
    }

    /// 使用 JS 执行器解析 URL 模板（增强版 parse）
    ///
    /// 在标准 parse 流程前，先执行 `@js:`/`<js>` 内嵌 JS，
    /// 并在 `{{expression}}` 中使用 JS 引擎执行复杂表达式。
    pub fn parse_with_js(
        template: &str,
        variables: &HashMap<String, String>,
        page: i32,
        js_executor: &dyn JsExecutor,
    ) -> LegadoResult<Self> {
        // 1. 先执行 @js:/<js> 内嵌 JS（失败上抛真实错误：懒人听书
        //    未配置登录会话时 lrtsResolveSession 抛「请先登录…」；
        //    静默保留 @js: 文本会被当 URL 请求 → HTTP 404 误导）
        let (processed, js_err) = Self::analyze_js_with_error(template, js_executor);
        if let Some(err) = js_err {
            return Err(LegadoError::Internal(format!(
                "URL 模板 JS 执行失败: {err}"
            )));
        }

        // 2. 处理 {{expression}} 内嵌表达式（用 JS 执行复杂表达式）
        let processed = Self::replace_inner_expressions_with_js(&processed, variables, js_executor);

        // 3. 调用标准 parse 流程
        Self::parse(&processed, variables, page)
    }

    /// 使用模板上下文解析 URL（支持 bookName/title 等内置变量）
    ///
    /// 将 TemplateContext 中的内置变量合并到 variables 中，
    /// 然后调用标准 parse 流程。
    pub fn parse_with_context(
        template: &str,
        variables: &HashMap<String, String>,
        context: &TemplateContext,
        page: i32,
    ) -> LegadoResult<Self> {
        // 合并内置变量到 variables
        let mut merged = variables.clone();
        if let Some(ref name) = context.book_name {
            merged.insert("bookName".to_string(), name.clone());
        }
        if let Some(ref title) = context.title {
            merged.insert("title".to_string(), title.clone());
        }
        if let Some(ref author) = context.author {
            merged.insert("author".to_string(), author.clone());
        }
        // 合并额外变量
        for (k, v) in &context.extra {
            merged.insert(k.clone(), v.clone());
        }

        Self::parse(template, &merged, page)
    }

    /// 使用 JS 执行器替换 `{{expression}}` 内嵌表达式
    ///
    /// 对于简单变量名直接查找替换，对于复杂表达式用 JS 引擎执行。
    fn replace_inner_expressions_with_js(
        template: &str,
        variables: &HashMap<String, String>,
        js_executor: &dyn JsExecutor,
    ) -> String {
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
                // 复杂表达式：用 JS 引擎执行
                // 先构建变量注入前缀（纯整数以数字注入，对齐原版 page 数值语义，
                // 保证 `page > 1` 等比较与算术表达式正确求值）
                let mut js_code = String::new();
                for (k, v) in variables {
                    if v.parse::<i64>().is_ok() {
                        js_code.push_str(&format!("var {} = {};\n", k, v));
                    } else {
                        // 转义单引号
                        let escaped = v.replace('\\', "\\\\").replace('\'', "\\'");
                        js_code.push_str(&format!("var {} = '{}';\n", k, escaped));
                    }
                }
                js_code.push_str(expr);

                // 对齐原版 AnalyzeUrl.kt replaceKeyPageJs：evalJS 失败/null → 空串，
                // 避免未渲染模板原样进入请求 URL
                js_executor.execute_js(&js_code).unwrap_or_default()
            }
        })
        .to_string()
    }

    // ========== data: URI 解析 ==========

    /// 解析 data: URI
    ///
    /// 支持格式：`data:[<mediatype>][;base64],<data>`
    /// 参考 Kotlin `getByteArrayIfDataUri()` 和 `AppPattern.dataUriRegex`
    ///
    /// # 示例
    /// - `data:text/html;base64,PGh0bWw+` → mime=text/html, base64 解码
    /// - `data:text/plain;charset=utf-8,hello` → mime=text/plain, 纯文本
    /// - `data:image/png;base64,iVBOR...` → mime=image/png, base64 解码
    pub fn parse_data_uri(uri: &str) -> Option<DataUriContent> {
        if !uri.starts_with("data:") {
            return None;
        }

        // 去掉 "data:" 前缀
        let rest = &uri[5..];

        // 查找数据分隔符 ','
        let comma_pos = rest.find(',')?;
        let meta = &rest[..comma_pos];
        let data_part = &rest[comma_pos + 1..];

        // 解析 meta 部分：[<mediatype>][;charset=xxx][;base64]
        let mut mime_type = "text/plain".to_string();
        let mut charset = "utf-8".to_string();
        let mut is_base64 = false;

        for segment in meta.split(';') {
            let segment = segment.trim();
            if segment == "base64" {
                is_base64 = true;
            } else if let Some(cs) = segment.strip_prefix("charset=") {
                charset = cs.to_string();
            } else if !segment.is_empty() && segment.contains('/') {
                mime_type = segment.to_string();
            }
        }

        // 解码数据
        let data = if is_base64 {
            base64::engine::general_purpose::STANDARD
                .decode(data_part.as_bytes())
                .ok()?
        } else {
            // URL 编码的纯文本
            urlencoding::decode(data_part)
                .map(|s| s.into_owned().into_bytes())
                .unwrap_or_else(|_| data_part.as_bytes().to_vec())
        };

        Some(DataUriContent {
            mime_type,
            charset,
            is_base64,
            data,
        })
    }

    /// 获取 URL 的字节内容（等价于 Kotlin `getByteArrayAwait`）
    ///
    /// 如果 URL 是 data: URI，直接解码返回内容；
    /// 否则返回 None，表示需要网络层处理。
    pub fn get_byte_array_if_data_uri(&self) -> Option<Vec<u8>> {
        if !self.url_no_query.starts_with("data:") {
            return None;
        }
        Self::parse_data_uri(&self.url_no_query).map(|c| c.data)
    }

    /// 判断当前 URL 是否为 data: URI
    pub fn is_data_uri(&self) -> bool {
        self.url_no_query.starts_with("data:")
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

    /// POST 请求体：优先已 charset 编码的 form，否则原始 body
    ///
    /// 对齐原版 `postForm(encodedForm)` / 非 form 时用原始 body。— Reasonix
    pub fn request_body(&self) -> &str {
        self.encoded_form
            .as_deref()
            .or(self.body.as_deref())
            .unwrap_or("")
    }

    /// 是否需要按 UrlOption.charset 手动解码响应体（非 UTF-8）
    pub fn needs_charset_decode(&self) -> bool {
        Self::is_non_utf8_charset(self.charset.as_deref())
    }

    /// 按 UrlOption.charset 解码响应字节（对齐原版搜索 GBK 站正确书名）
    pub fn decode_response_bytes(bytes: &[u8], charset: Option<&str>) -> String {
        match charset {
            Some(cs) if Self::is_non_utf8_charset(Some(cs)) => {
                let enc = Self::encoding_for_label(cs);
                let (cow, _, _) = enc.decode(bytes);
                cow.into_owned()
            }
            _ => String::from_utf8_lossy(bytes).into_owned(),
        }
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

    /// 是否使用 WebView 加载
    pub fn use_web_view(&self) -> bool {
        self.use_web_view
    }

    /// WebView 中执行的 JS 脚本
    pub fn web_js(&self) -> Option<&str> {
        self.web_js.as_deref()
    }

    /// WebView 等待延迟时间（毫秒）
    pub fn web_view_delay_time(&self) -> u64 {
        self.web_view_delay_time
    }

    /// 解析完 URL 后执行的 JS
    pub fn url_js(&self) -> Option<&str> {
        self.url_js.as_deref()
    }

    /// 对响应 body 二次处理的 JS
    pub fn body_js(&self) -> Option<&str> {
        self.body_js.as_deref()
    }

    /// 自定义域名 IP
    pub fn dns_ip(&self) -> Option<&str> {
        self.dns_ip.as_deref()
    }

    /// 服务器 ID
    pub fn server_id(&self) -> Option<i64> {
        self.server_id
    }

    /// 响应类型
    pub fn response_type(&self) -> Option<&str> {
        self.response_type.as_deref()
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

    /// 回归：思路客类 `/list1/{{page}}.html` 不得被 `{page}` 子串替换成 `/list1/{1}.html`
    #[test]
    fn test_double_brace_page_not_mangled_to_literal_brace() {
        let url = AnalyzeUrl::new(
            "http://www.silukezw.com/list1/{{page}}.html",
            None,
            Some(1),
            "http://www.silukezw.com",
            None,
        );
        assert_eq!(url.url(), "http://www.silukezw.com/list1/1.html");
        assert!(
            !url.url().contains("{1}"),
            "不得残留字面量 {{page}}→{{1}} 误替换产物: {}",
            url.url()
        );

        let url2 = AnalyzeUrl::new(
            "/list1/{{page}}.html",
            None,
            Some(2),
            "http://www.silukezw.com",
            None,
        );
        assert_eq!(url2.url(), "http://www.silukezw.com/list1/2.html");
    }

    /// 旧式 `{1}` 页码列表（导入迁移前形态，对齐转为 `<1>` 后的选取语义）
    #[test]
    fn test_legacy_brace_numeric_page_list() {
        let url = AnalyzeUrl::new(
            "http://www.silukezw.com/list1/{1}.html",
            None,
            Some(1),
            "",
            None,
        );
        assert_eq!(url.url(), "http://www.silukezw.com/list1/1.html");

        let url2 = AnalyzeUrl::new(
            "https://example.com/list/{1,2,3}.html",
            None,
            Some(2),
            "",
            None,
        );
        assert_eq!(url2.url(), "https://example.com/list/2.html");
    }

    #[test]
    fn test_page_list_angle_bracket() {
        // 对齐原版 pagePattern `<(.*?)>`：`<index.html,p2.html,p3.html>` page=2 → p2.html
        let url = AnalyzeUrl::new(
            "https://example.com/list/<index.html,p2.html,p3.html>",
            None,
            Some(2),
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/list/p2.html");
    }

    #[test]
    fn test_page_list_angle_first_empty() {
        // 常见写法：第一页无后缀 `<,_{{page}}>` → page=1 取空段
        let url = AnalyzeUrl::new(
            "https://example.com/index<,_{{page}}>.html",
            None,
            Some(1),
            "",
            None,
        );
        assert_eq!(url.url(), "https://example.com/index.html");

        let url2 = AnalyzeUrl::new(
            "https://example.com/index<,_{{page}}>.html",
            None,
            Some(2),
            "",
            None,
        );
        assert_eq!(url2.url(), "https://example.com/index_2.html");
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
            "https://example.com/<p1,p2,p3>",
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

    /// charset=gbk 查询编码（对齐原版 AnalyzeUrl.encodeParams + URLEncoder GBK）
    /// — Reasonix 2026-08-12
    #[test]
    fn test_charset_gbk_query_encoding() {
        let mut vars = HashMap::new();
        vars.insert("key".to_string(), "斗破苍穹".to_string());
        // 单花括号路径（parse 内 replace_brace_vars）；搜索主链路 {{key}} 经 parse_with_js
        let url = AnalyzeUrl::parse(
            r#"https://www.example.com/modules/article/search.php?searchkey={key},{"charset":"gbk"}"#,
            &vars,
            1,
        )
        .unwrap();
        // GBK("斗破苍穹") = B6B7 C6C6 B2D4 F1B7
        assert!(
            url.url().contains("searchkey=%B6%B7%C6%C6%B2%D4%F1%B7"),
            "expected GBK-encoded searchkey, got {}",
            url.url()
        );
        assert!(
            !url.url().contains("%E6%96%97"),
            "must not use UTF-8 percent encoding when charset=gbk: {}",
            url.url()
        );
    }

    /// charset=gbk POST form 编码 — Reasonix 2026-08-12
    #[test]
    fn test_charset_gbk_post_form_encoding() {
        let mut vars = HashMap::new();
        vars.insert("key".to_string(), "斗破苍穹".to_string());
        let url = AnalyzeUrl::parse(
            r#"https://m.example.com/s.php,{"charset":"gbk","method":"POST","body":"search_key={key}"}"#,
            &vars,
            1,
        )
        .unwrap();
        assert_eq!(url.method(), &RequestMethod::Post);
        let body = url.request_body();
        assert_eq!(body, "search_key=%B6%B7%C6%C6%B2%D4%F1%B7");
        assert_eq!(
            url.headers().get("Content-Type").map(|s| s.as_str()),
            Some("application/x-www-form-urlencoded")
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
        // 书源 URL 带 # 唯一后缀时，相对 path 不得拼进 fragment — Reasonix
        assert_eq!(
            AnalyzeUrl::get_absolute_url(
                "http://www.95dushu.info#wy18-1001",
                "/modules/article/search.php?ie=gbk&searchkey=x"
            ),
            "http://www.95dushu.info/modules/article/search.php?ie=gbk&searchkey=x"
        );
        assert_eq!(
            AnalyzeUrl::get_absolute_url("https://www.bookxuan.com#🎃", "modules/article/search.php"),
            "https://www.bookxuan.com/modules/article/search.php"
        );
        assert_eq!(
            AnalyzeUrl::get_absolute_url("http://www.dongtanxs.com##", "/search?q=1"),
            "http://www.dongtanxs.com/search?q=1"
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
        // 无 path 的 host + 无前导 / 的相对路径（拷贝漫画 statics/...）
        assert_eq!(
            AnalyzeUrl::get_absolute_url(
                "https://www.copymanga.site",
                "statics/search.aspx?key=x"
            ),
            "https://www.copymanga.site/statics/search.aspx?key=x"
        );
    }

    /// parse() 必须读取 variables.baseUrl，否则相对 searchUrl 原样发出
    #[test]
    fn test_parse_relative_url_uses_base_url_variable() {
        let mut vars = HashMap::new();
        vars.insert("key".to_string(), "一人之下".to_string());
        vars.insert("page".to_string(), "1".to_string());
        vars.insert("baseUrl".to_string(), "https://www.manwa.me".to_string());
        let url = AnalyzeUrl::parse("/api/search?keyword={key}&page={page}", &vars, 1).unwrap();
        assert!(
            url.url().starts_with("https://www.manwa.me/api/search?"),
            "url={}",
            url.url()
        );
        assert!(
            url.url().contains("一人之下") || url.url().contains("%E4%B8%80"),
            "url={}",
            url.url()
        );
    }

    // --- 15. Angle bracket variable ---
    #[test]
    fn test_angle_bracket_var() {
        let mut vars = HashMap::new();
        vars.insert("category".to_string(), "fiction".to_string());

        let url = AnalyzeUrl::parse("https://example.com/books/<category>/list", &vars, 1).unwrap();
        assert_eq!(url.url(), "https://example.com/books/fiction/list");
    }

    // --- 16. data: URI 解析 ---
    #[test]
    fn test_parse_data_uri_base64() {
        // "hello" 的 base64 编码是 "aGVsbG8="
        let uri = "data:text/plain;base64,aGVsbG8=";
        let result = AnalyzeUrl::parse_data_uri(uri).unwrap();
        assert_eq!(result.mime_type, "text/plain");
        assert_eq!(result.charset, "utf-8");
        assert!(result.is_base64);
        assert_eq!(result.data, b"hello");
    }

    #[test]
    fn test_parse_data_uri_html_base64() {
        // "<html>" 的 base64 编码是 "PGh0bWw+"
        let uri = "data:text/html;base64,PGh0bWw+";
        let result = AnalyzeUrl::parse_data_uri(uri).unwrap();
        assert_eq!(result.mime_type, "text/html");
        assert!(result.is_base64);
        assert_eq!(result.data, b"<html>");
    }

    #[test]
    fn test_parse_data_uri_plain_text() {
        let uri = "data:text/plain;charset=utf-8,hello%20world";
        let result = AnalyzeUrl::parse_data_uri(uri).unwrap();
        assert_eq!(result.mime_type, "text/plain");
        assert_eq!(result.charset, "utf-8");
        assert!(!result.is_base64);
        assert_eq!(result.data, b"hello world");
    }

    #[test]
    fn test_parse_data_uri_not_data() {
        assert!(AnalyzeUrl::parse_data_uri("https://example.com").is_none());
    }

    #[test]
    fn test_parse_data_uri_image_png() {
        // 1x1 像素 PNG 的 base64
        let uri = "data:image/png;base64,iVBORw0KGgo=";
        let result = AnalyzeUrl::parse_data_uri(uri).unwrap();
        assert_eq!(result.mime_type, "image/png");
        assert!(result.is_base64);
    }

    // --- 17. is_data_uri 和 get_byte_array_if_data_uri ---
    #[test]
    fn test_is_data_uri() {
        let url = AnalyzeUrl::new(
            "data:text/plain;base64,aGVsbG8=",
            None,
            None,
            "",
            None,
        );
        assert!(url.is_data_uri());
        let bytes = url.get_byte_array_if_data_uri().unwrap();
        assert_eq!(bytes, b"hello");
    }

    #[test]
    fn test_not_data_uri() {
        let url = AnalyzeUrl::new("https://example.com/page", None, None, "", None);
        assert!(!url.is_data_uri());
        assert!(url.get_byte_array_if_data_uri().is_none());
    }

    // --- 18. WebView 选项解析 ---
    #[test]
    fn test_webview_option_true() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/page,{"webView":true,"webJs":"document.body.innerHTML","webViewDelayTime":1000}"#,
            None,
            None,
            "",
            None,
        );
        assert!(url.use_web_view());
        assert_eq!(url.web_js(), Some("document.body.innerHTML"));
        assert_eq!(url.web_view_delay_time(), 1000);
    }

    #[test]
    fn test_webview_option_string() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/page,{"webView":"true"}"#,
            None,
            None,
            "",
            None,
        );
        assert!(url.use_web_view());
    }

    #[test]
    fn test_webview_option_false() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/page,{"webView":false}"#,
            None,
            None,
            "",
            None,
        );
        assert!(!url.use_web_view());
    }

    #[test]
    fn test_webview_option_string_false() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/page,{"webView":"false"}"#,
            None,
            None,
            "",
            None,
        );
        assert!(!url.use_web_view());
    }

    // --- 19. UrlOption 新增字段解析 ---
    #[test]
    fn test_url_option_js_field() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/api,{"js":"url + '/v2'"}"#,
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.url_js(), Some("url + '/v2'"));
    }

    #[test]
    fn test_url_option_body_js_field() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/api,{"bodyJs":"result.replace('old','new')"}"#,
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.body_js(), Some("result.replace('old','new')"));
    }

    #[test]
    fn test_url_option_dns_ip_field() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/api,{"dnsIp":"1.2.3.4"}"#,
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.dns_ip(), Some("1.2.3.4"));
    }

    #[test]
    fn test_url_option_server_id_field() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/api,{"serverID":42}"#,
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.server_id(), Some(42));
    }

    // --- 20. JS 内嵌执行 (analyze_js) ---

    /// 测试用 Mock JS 执行器
    struct MockJsExecutor;

    impl crate::analyze_rule::JsExecutor for MockJsExecutor {
        fn execute_js(&self, js_code: &str) -> Result<String, String> {
            // 简单模拟：如果包含 "1+1" 返回 "2"
            if js_code.contains("1+1") {
                Ok("2".to_string())
            } else if js_code.contains("'hello'+' world'") {
                Ok("hello world".to_string())
            } else if js_code.contains("url") {
                Ok("https://result.example.com".to_string())
            } else {
                Ok(js_code.to_string())
            }
        }
    }

    #[test]
    fn test_analyze_js_at_js_syntax() {
        let executor = MockJsExecutor;
        // @js: 语法：整个 URL 是 JS 表达式
        let result = AnalyzeUrl::analyze_js("@js:1+1", &executor);
        assert_eq!(result, "2");
    }

    #[test]
    fn test_analyze_js_tag_syntax() {
        let executor = MockJsExecutor;
        // <js>...</js> 语法
        let result = AnalyzeUrl::analyze_js("<js>1+1</js>", &executor);
        assert_eq!(result, "2");
    }

    #[test]
    fn test_analyze_js_with_result_ref() {
        let executor = MockJsExecutor;
        // <js>...</js> 之间的文本中的 @result 会被替换为上一步 JS 执行结果
        // 第一个 <js>1+1</js> 执行得到 "2"
        // 中间文本 "https://@result.com" 中的 @result 被替换为 "2"
        let result = AnalyzeUrl::analyze_js("<js>1+1</js>https://@result.com", &executor);
        assert_eq!(result, "https://2.com");
    }

    #[test]
    fn test_analyze_js_no_js() {
        let executor = MockJsExecutor;
        // 没有 JS 标记，原样返回
        let result = AnalyzeUrl::analyze_js("https://example.com/page", &executor);
        assert_eq!(result, "https://example.com/page");
    }

    // --- 21. parse_with_js ---
    #[test]
    fn test_parse_with_js() {
        let executor = MockJsExecutor;
        let vars = HashMap::new();
        let url = AnalyzeUrl::parse_with_js("@js:1+1", &vars, 1, &executor).unwrap();
        // JS 执行结果 "2" 作为 URL
        assert_eq!(url.url(), "2");
    }

    /// 原样返回收到的 JS 代码，用于断言变量注入形态
    struct EchoJsExecutor;

    impl crate::analyze_rule::JsExecutor for EchoJsExecutor {
        fn execute_js(&self, js_code: &str) -> Result<String, String> {
            Ok(js_code.to_string())
        }
    }

    /// 总是失败，用于断言求值失败空串回退
    struct FailJsExecutor;

    impl crate::analyze_rule::JsExecutor for FailJsExecutor {
        fn execute_js(&self, _js_code: &str) -> Result<String, String> {
            Err("模拟执行失败".to_string())
        }
    }

    // --- 21.1 {{expression}} 变量注入：纯整数以数字注入（对齐原版 page 数值语义） ---
    #[test]
    fn test_inner_expression_numeric_injection() {
        let mut vars = HashMap::new();
        vars.insert("key".to_string(), "重生".to_string());
        vars.insert("page".to_string(), "2".to_string());
        let out = AnalyzeUrl::replace_inner_expressions_with_js(
            "{{key}}|{{page}}|{{page > 1 ? '/' + page : ''}}",
            &vars,
            &EchoJsExecutor,
        );
        // 简单变量名直接查找（不经过 JS）
        assert!(out.starts_with("重生|2|"), "简单变量应直接替换: {out}");
        let code = &out["重生|2|".len()..];
        assert!(code.contains("var page = 2;"), "page 应以数字注入: {code}");
        assert!(code.contains("var key = '重生';"), "key 应以字符串注入: {code}");
    }

    // --- 21.2 {{expression}} 求值失败 → 空串（对齐原版 evalJS null → ""） ---
    #[test]
    fn test_inner_expression_fail_to_empty() {
        let vars = HashMap::new();
        let out =
            AnalyzeUrl::replace_inner_expressions_with_js("pre{{someFn()}}post", &vars, &FailJsExecutor);
        assert_eq!(out, "prepost");
    }

    // --- 22. parse_with_context (bookName/title 内置变量) ---
    #[test]
    fn test_parse_with_context_book_name() {
        let vars = HashMap::new();
        let ctx = TemplateContext {
            book_name: Some("Rust编程指南".to_string()),
            title: None,
            author: None,
            extra: HashMap::new(),
        };

        let url =
            AnalyzeUrl::parse_with_context("https://example.com/search?q={bookName}", &vars, &ctx, 1)
                .unwrap();
        assert!(url.url().contains("Rust%E7%BC%96%E7%A8%8B%E6%8C%87%E5%8D%97"));
    }

    #[test]
    fn test_parse_with_context_title() {
        let vars = HashMap::new();
        let ctx = TemplateContext {
            book_name: None,
            title: Some("第一章".to_string()),
            author: None,
            extra: HashMap::new(),
        };

        let url =
            AnalyzeUrl::parse_with_context("https://example.com/chapter?t={title}", &vars, &ctx, 1)
                .unwrap();
        assert!(url.url().contains("%E7%AC%AC%E4%B8%80%E7%AB%A0"));
    }

    #[test]
    fn test_parse_with_context_author() {
        let vars = HashMap::new();
        let ctx = TemplateContext {
            book_name: None,
            title: None,
            author: Some("张三".to_string()),
            extra: HashMap::new(),
        };

        let url =
            AnalyzeUrl::parse_with_context("https://example.com/author?a={author}", &vars, &ctx, 1)
                .unwrap();
        assert!(url.url().contains("%E5%BC%A0%E4%B8%89"));
    }

    #[test]
    fn test_parse_with_context_extra_vars() {
        let vars = HashMap::new();
        let mut extra = HashMap::new();
        extra.insert("customKey".to_string(), "customValue".to_string());
        let ctx = TemplateContext {
            book_name: None,
            title: None,
            author: None,
            extra,
        };

        let url = AnalyzeUrl::parse_with_context(
            "https://example.com/api?k={customKey}",
            &vars,
            &ctx,
            1,
        )
        .unwrap();
        assert!(url.url().contains("k=customValue"));
    }

    #[test]
    fn test_parse_with_context_merges_variables() {
        let mut vars = HashMap::new();
        vars.insert("page_size".to_string(), "20".to_string());
        let ctx = TemplateContext {
            book_name: Some("测试书".to_string()),
            title: None,
            author: None,
            extra: HashMap::new(),
        };

        let url = AnalyzeUrl::parse_with_context(
            "https://example.com/search?q={bookName}&size={page_size}",
            &vars,
            &ctx,
            1,
        )
        .unwrap();
        assert!(url.url().contains("size=20"));
        assert!(url.url().contains("q="));
    }

    // --- 23. 综合场景：WebView + POST ---
    #[test]
    fn test_webview_post_combined() {
        let url = AnalyzeUrl::new(
            r#"https://example.com/api,{"method":"POST","body":"key=val","webView":true,"webJs":"document.querySelector('#content').innerHTML","webViewDelayTime":500}"#,
            None,
            None,
            "",
            None,
        );
        assert_eq!(url.method(), &RequestMethod::Post);
        assert!(url.use_web_view());
        assert_eq!(
            url.web_js(),
            Some("document.querySelector('#content').innerHTML")
        );
        assert_eq!(url.web_view_delay_time(), 500);
        assert_eq!(url.body(), Some("key=val"));
    }

    // --- 24. data: URI 在 parse 流程中的处理 ---
    #[test]
    fn test_data_uri_in_parse() {
        let vars = HashMap::new();
        let url = AnalyzeUrl::parse("data:text/html;base64,PGh0bWw+", &vars, 1).unwrap();
        assert!(url.is_data_uri());
        let bytes = url.get_byte_array_if_data_uri().unwrap();
        assert_eq!(bytes, b"<html>");
    }

    /// data: URI 含 HTML 标签时，page=1 不得误走 `<...>` 页码列表替换
    #[test]
    fn test_data_uri_html_payload_not_mangled_by_page_replace() {
        let vars = HashMap::new();
        let template = "data:text/html;charset=utf-8,<html><body><p id='def'>n. 测试释义</p></body></html>";
        let url = AnalyzeUrl::parse(template, &vars, 1).unwrap();
        let bytes = url.get_byte_array_if_data_uri().unwrap();
        let body = String::from_utf8_lossy(&bytes);
        assert_eq!(
            body,
            "<html><body><p id='def'>n. 测试释义</p></body></html>"
        );
    }
}
