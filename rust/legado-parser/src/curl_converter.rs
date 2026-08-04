//! cURL ↔ AnalyzeUrl 双向转换器
//!
//! 对齐 Kotlin 端 `app/src/main/java/io/legado/app/ui/code/CurlAnalyzeUrlConverter.kt`
//! （上游 #434），实现：
//!
//! - [`parse_curl`]：cURL 命令 → 结构化请求（url / method / headers / body）
//! - [`to_curl`]：结构化请求参数 → cURL 命令（POSIX shell 安全转义）
//! - [`curl_to_analyze_url`]：cURL 命令 → AnalyzeUrl 模板字符串（`url,{"method":...}`）
//! - [`analyze_url_to_curl`]：AnalyzeUrl 模板字符串 → cURL 命令
//!
//! 与 Kotlin 版的差异（扩展项）：
//! - 额外支持 `--data-urlencode`（Kotlin 版会拒绝该选项）
//! - 额外忽略 `--compressed`（对 AnalyzeUrl 无语义影响）
//!
//! 错误语义对齐 Kotlin `ConversionException(ErrorReason, detail)`，
//! 统一映射为 `LegadoError::Parser("[CURL_{REASON}] {detail}")`，
//! 便于上层按前缀识别错误类别。

use legado_core::{LegadoError, LegadoResult};

/// FORM 表单默认 Content-Type（对齐 Kotlin FORM_CONTENT_TYPE）
const FORM_CONTENT_TYPE: &str = "application/x-www-form-urlencoded";
/// JSON 默认 Content-Type（对齐 Kotlin JSON_CONTENT_TYPE）
const JSON_CONTENT_TYPE: &str = "application/json; charset=UTF-8";

/// AnalyzeUrl 选项 JSON 中允许出现的键（对齐 Kotlin analyzeOptionKeys）
const ANALYZE_OPTION_KEYS: [&str; 4] = ["method", "headers", "body", "followRedirects"];

/// 无副作用、直接忽略的选项（对齐 Kotlin ignoredOptions，扩展 --compressed）
const IGNORED_OPTIONS: [&str; 11] = [
    "-s",
    "--silent",
    "-S",
    "--show-error",
    "-sS",
    "-Ss",
    "-f",
    "--fail",
    "--fail-with-body",
    "--no-progress-meter",
    "--compressed",
];

/// 需要吞掉一个值的忽略选项（对齐 Kotlin ignoredOptionsWithValue）
const IGNORED_OPTIONS_WITH_VALUE: [&str; 4] = ["-o", "--output", "-w", "--write-out"];

// =====================================================================
// 错误模型
// =====================================================================

/// 转换错误原因（对齐 Kotlin ErrorReason 枚举）
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CurlErrorReason {
    /// 输入为空
    EmptyInput,
    /// 非法 cURL 命令（词法/结构错误）
    InvalidCurl,
    /// 缺少 URL
    MissingUrl,
    /// 非法 AnalyzeUrl 模板
    InvalidAnalyzeUrl,
    /// 不支持的 HTTP 方法
    UnsupportedMethod,
    /// 不支持的选项
    UnsupportedOption,
}

impl CurlErrorReason {
    /// 错误消息前缀（如 `CURL_EMPTY_INPUT`）
    fn tag(self) -> &'static str {
        match self {
            CurlErrorReason::EmptyInput => "CURL_EMPTY_INPUT",
            CurlErrorReason::InvalidCurl => "CURL_INVALID",
            CurlErrorReason::MissingUrl => "CURL_MISSING_URL",
            CurlErrorReason::InvalidAnalyzeUrl => "CURL_INVALID_ANALYZE_URL",
            CurlErrorReason::UnsupportedMethod => "CURL_UNSUPPORTED_METHOD",
            CurlErrorReason::UnsupportedOption => "CURL_UNSUPPORTED_OPTION",
        }
    }
}

/// 构造对齐 Kotlin ConversionException 语义的解析错误
fn conv_err(reason: CurlErrorReason, detail: impl Into<String>) -> LegadoError {
    let detail = detail.into();
    let msg = if detail.is_empty() {
        format!("[{}]", reason.tag())
    } else {
        format!("[{}] {}", reason.tag(), detail)
    };
    LegadoError::Parser(msg)
}

/// 判断错误消息是否属于指定错误原因（供测试与上层识别）
pub fn is_curl_error(err: &LegadoError, reason: CurlErrorReason) -> bool {
    matches!(err, LegadoError::Parser(msg) if msg.contains(reason.tag()))
}

// =====================================================================
// 数据结构
// =====================================================================

/// cURL 命令解析结果
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CurlParseResult {
    /// 请求 URL
    pub url: String,
    /// HTTP 方法（已推断：无 -X 时按有无 body 推断 GET/POST）
    pub method: String,
    /// 请求头（保持命令行出现顺序，含解析期补充的默认 Content-Type/Accept）
    pub headers: Vec<(String, String)>,
    /// 请求体（多个 -d 片段以 `&` 连接；无 body 时为 None）
    pub body: Option<String>,
    /// 是否跟随重定向（-L/--location）
    pub follow_redirects: bool,
    /// 是否关闭 URL 通配展开（-g/--globoff）
    pub glob_off: bool,
}

/// 结构化请求参数（to_curl 的输入）
#[derive(Debug, Clone, Default)]
pub struct CurlRequestParams {
    /// 请求 URL
    pub url: String,
    /// HTTP 方法（GET/POST/HEAD 等，大小写不敏感）
    pub method: String,
    /// 请求头（按顺序序列化）
    pub headers: Vec<(String, String)>,
    /// 请求体
    pub body: Option<String>,
    /// 是否跟随重定向（序列化时输出 -L）
    pub follow_redirects: bool,
}

impl From<&CurlParseResult> for CurlRequestParams {
    fn from(r: &CurlParseResult) -> Self {
        Self {
            url: r.url.clone(),
            method: r.method.clone(),
            headers: r.headers.clone(),
            body: r.body.clone(),
            follow_redirects: r.follow_redirects,
        }
    }
}

/// cURL 解析的中间状态（对齐 Kotlin CurlRequest）
#[derive(Debug, Default)]
struct CurlRequest {
    url: String,
    custom_method: Option<String>,
    headers: Vec<(String, String)>,
    body_parts: Vec<String>,
    head: bool,
    follow_redirects: bool,
    glob_off: bool,
    add_json_headers: bool,
}

impl CurlRequest {
    /// 按忽略大小写查找 header
    #[allow(dead_code)]
    fn find_header(&self, name: &str) -> Option<&String> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v)
    }
}

// =====================================================================
// 公共 API
// =====================================================================

/// 判断文本是否形似 cURL 命令（对齐 Kotlin looksLikeCurl）
pub fn looks_like_curl(text: &str) -> bool {
    let t = text.trim_start();
    let lower = t.to_ascii_lowercase();
    for prefix in ["curl.exe", "curl"] {
        if let Some(rest) = lower.strip_prefix(prefix) {
            return rest.is_empty() || rest.starts_with(|c: char| c.is_whitespace());
        }
    }
    false
}

/// 解析 cURL 命令为结构化请求（对齐 Kotlin parseCurl + resolveCurlMethod）
pub fn parse_curl(text: &str) -> LegadoResult<CurlParseResult> {
    let tokens = tokenize(text)?;
    if tokens.is_empty()
        || (!tokens[0].eq_ignore_ascii_case("curl") && !tokens[0].eq_ignore_ascii_case("curl.exe"))
    {
        return Err(conv_err(CurlErrorReason::InvalidCurl, ""));
    }

    let mut request = CurlRequest::default();
    let mut end_of_options = false;
    let mut index: usize = 1;

    while index < tokens.len() {
        let token = tokens[index].clone();

        // 取下一个 token 作为当前选项的值（对齐 Kotlin nextValue）
        let next_value = |index: &mut usize| -> LegadoResult<String> {
            if *index + 1 >= tokens.len() {
                return Err(conv_err(CurlErrorReason::InvalidCurl, ""));
            }
            *index += 1;
            Ok(tokens[*index].clone())
        };

        if end_of_options {
            set_url(&mut request, &token)?;
        } else if token == "--" {
            end_of_options = true;
        } else if token == "-X" || token == "--request" {
            request.custom_method = Some(next_value(&mut index)?);
        } else if let Some(v) = token.strip_prefix("--request=") {
            request.custom_method = Some(v.to_string());
        } else if token.len() > 2 && token.starts_with("-X") {
            request.custom_method = Some(token[2..].to_string());
        } else if token == "-I" || token == "--head" {
            request.head = true;
        } else if token == "-H" || token == "--header" {
            add_header(&mut request, &next_value(&mut index)?)?;
        } else if let Some(v) = token.strip_prefix("--header=") {
            add_header(&mut request, v)?;
        } else if token.len() > 2 && token.starts_with("-H") {
            add_header(&mut request, &token[2..])?;
        } else if token == "-A" || token == "--user-agent" {
            add_user_agent(&mut request, &next_value(&mut index)?)?;
        } else if let Some(v) = token.strip_prefix("--user-agent=") {
            add_user_agent(&mut request, v)?;
        } else if token.len() > 2 && token.starts_with("-A") {
            add_user_agent(&mut request, &token[2..])?;
        } else if token == "-e" || token == "--referer" {
            add_referer(&mut request, &next_value(&mut index)?)?;
        } else if let Some(v) = token.strip_prefix("--referer=") {
            add_referer(&mut request, v)?;
        } else if token.len() > 2 && token.starts_with("-e") {
            add_referer(&mut request, &token[2..])?;
        } else if token == "-d" || token == "--data" || token == "--data-raw" || token == "--data-binary" {
            add_body(&mut request, &token, &next_value(&mut index)?)?;
        } else if let Some(v) = token.strip_prefix("--data=") {
            add_body(&mut request, "--data", v)?;
        } else if let Some(v) = token.strip_prefix("--data-raw=") {
            add_body(&mut request, "--data-raw", v)?;
        } else if let Some(v) = token.strip_prefix("--data-binary=") {
            add_body(&mut request, "--data-binary", v)?;
        } else if token.len() > 2 && token.starts_with("-d") {
            add_body(&mut request, "-d", &token[2..])?;
        } else if token == "--data-urlencode" {
            add_body_urlencode(&mut request, &next_value(&mut index)?)?;
        } else if let Some(v) = token.strip_prefix("--data-urlencode=") {
            add_body_urlencode(&mut request, v)?;
        } else if token == "--json" {
            add_body(&mut request, "--json", &next_value(&mut index)?)?;
            request.add_json_headers = true;
        } else if let Some(v) = token.strip_prefix("--json=") {
            add_body(&mut request, "--json", v)?;
            request.add_json_headers = true;
        } else if token == "-b" || token == "--cookie" {
            add_cookie(&mut request, &next_value(&mut index)?)?;
        } else if let Some(v) = token.strip_prefix("--cookie=") {
            add_cookie(&mut request, v)?;
        } else if token.len() > 2 && token.starts_with("-b") {
            add_cookie(&mut request, &token[2..])?;
        } else if token == "--url" {
            let v = next_value(&mut index)?;
            set_url(&mut request, &v)?;
        } else if let Some(v) = token.strip_prefix("--url=") {
            set_url(&mut request, v)?;
        } else if token == "-L" || token == "--location" {
            request.follow_redirects = true;
        } else if token == "--no-location" {
            request.follow_redirects = false;
        } else if token == "-g" || token == "--globoff" {
            request.glob_off = true;
        } else if token == "--no-globoff" {
            request.glob_off = false;
        } else if IGNORED_OPTIONS.contains(&token.as_str()) {
            // 静默忽略
        } else if IGNORED_OPTIONS_WITH_VALUE.contains(&token.as_str()) {
            next_value(&mut index)?;
        } else if IGNORED_OPTIONS_WITH_VALUE
            .iter()
            .any(|opt| token.starts_with(&format!("{}=", opt)))
        {
            // --output=xxx 形式，直接忽略
        } else if (token.starts_with("-o") || token.starts_with("-w")) && token.len() > 2 {
            // -oxxx / -wxxx 粘连形式，直接忽略
        } else if token.starts_with('-') {
            return Err(conv_err(CurlErrorReason::UnsupportedOption, option_name(&token)));
        } else {
            set_url(&mut request, &token)?;
        }
        index += 1;
    }

    // 补充默认 Content-Type（对齐 Kotlin parseCurl 尾部逻辑）
    if request.add_json_headers {
        put_default_header(&mut request, "Content-Type", "application/json");
        put_default_header(&mut request, "Accept", "application/json");
    } else if !request.body_parts.is_empty() {
        put_default_header(&mut request, "Content-Type", FORM_CONTENT_TYPE);
    }

    let method = resolve_curl_method(&request)?;
    // 缺少 URL 视为非法（对齐 Kotlin curlToAnalyzeUrl 的 MISSING_URL 语义）
    if request.url.trim().is_empty() {
        return Err(conv_err(CurlErrorReason::MissingUrl, ""));
    }
    let body = if request.body_parts.is_empty() {
        None
    } else {
        Some(request.body_parts.join("&"))
    };

    Ok(CurlParseResult {
        url: request.url,
        method,
        headers: request.headers,
        body,
        follow_redirects: request.follow_redirects,
        glob_off: request.glob_off,
    })
}

/// 将结构化请求参数序列化为 cURL 命令（正确的 POSIX shell 转义）
pub fn to_curl(params: &CurlRequestParams) -> String {
    let mut parts: Vec<String> = vec!["curl".to_string(), "-g".to_string()];
    if params.follow_redirects {
        parts.push("-L".to_string());
    }
    let method = params.method.to_ascii_uppercase();
    if method == "HEAD" {
        parts.push("-I".to_string());
    }
    parts.push(shell_quote(&params.url));
    for (name, value) in &params.headers {
        parts.push("-H".to_string());
        parts.push(shell_quote(&format!("{}: {}", name, value)));
    }
    if let Some(body) = &params.body {
        parts.push("--data-raw".to_string());
        parts.push(shell_quote(body));
    }
    parts.join(" ")
}

/// cURL 命令 → AnalyzeUrl 模板字符串（对齐 Kotlin curlToAnalyzeUrl）
///
/// 输出格式：`url,{"method":"POST","headers":{...},"body":"...","followRedirects":false}`
/// （字段顺序与 Kotlin GSON 序列化一致；纯 GET 无选项时仅输出 URL）
pub fn curl_to_analyze_url(text: &str) -> LegadoResult<String> {
    if text.trim().is_empty() {
        return Err(conv_err(CurlErrorReason::EmptyInput, ""));
    }
    let request = parse_curl(text)?;
    if request.url.trim().is_empty() {
        return Err(conv_err(CurlErrorReason::MissingUrl, ""));
    }
    validate_url(&request.url, request.glob_off)?;

    let method = request.method.clone();
    let body = request.body.clone();

    // 空白 body 校验（对齐 Kotlin：仅允许 `-d ''` 且 Content-Type 为 FORM 的情形）
    if let Some(b) = &body {
        if b.trim().is_empty() {
            let content_type = request
                .headers
                .iter()
                .find(|(k, _)| k == "Content-Type")
                .map(|(_, v)| v.as_str());
            if !b.is_empty() || content_type != Some(FORM_CONTENT_TYPE) {
                return Err(conv_err(CurlErrorReason::UnsupportedOption, "blank body"));
            }
        }
    }

    // 按 Kotlin 顺序组装选项 JSON：method → headers → body → followRedirects
    let mut fields: Vec<String> = Vec::new();
    if method != "GET" || body.is_some() {
        fields.push(format!("\"method\":{}", json_string(&method)));
    }
    if !request.headers.is_empty() {
        let inner: Vec<String> = request
            .headers
            .iter()
            .map(|(k, v)| format!("{}:{}", json_string(k), json_string(v)))
            .collect();
        fields.push(format!("\"headers\":{{{}}}", inner.join(",")));
    }
    if let Some(b) = &body {
        fields.push(format!("\"body\":{}", json_string(b)));
    }
    if !request.follow_redirects {
        fields.push("\"followRedirects\":false".to_string());
    }

    if fields.is_empty() {
        Ok(request.url)
    } else {
        Ok(format!("{},{{{}}}", request.url, fields.join(",")))
    }
}

/// AnalyzeUrl 模板字符串 → cURL 命令（对齐 Kotlin analyzeUrlToCurl）
pub fn analyze_url_to_curl(text: &str) -> LegadoResult<String> {
    if text.trim().is_empty() {
        return Err(conv_err(CurlErrorReason::EmptyInput, ""));
    }
    let raw = text.trim();

    // 按 Kotlin paramPattern `\s*,\s*(?=\{)` 拆分 URL 与选项 JSON
    let (url, option_json) = split_analyze_params(raw);
    if url.trim().is_empty() {
        return Err(conv_err(CurlErrorReason::MissingUrl, ""));
    }
    validate_url(url.trim(), true)?;

    let mut method = "GET".to_string();
    let mut headers: Vec<(String, String)> = Vec::new();
    let mut has_body = false;
    let mut body = String::new();
    let mut follow_redirects = true;

    if let Some(json) = option_json {
        let pairs = parse_object_pairs(json)
            .map_err(|_| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;

        // 不支持的选项键（非 null 值且不在允许列表中，对齐 Kotlin）
        let unsupported: Vec<String> = pairs
            .iter()
            .filter(|(k, v)| v.trim() != "null" && !ANALYZE_OPTION_KEYS.contains(&k.as_str()))
            .map(|(k, _)| k.clone())
            .collect();
        if !unsupported.is_empty() {
            return Err(conv_err(
                CurlErrorReason::UnsupportedOption,
                unsupported.join(", "),
            ));
        }

        for (key, value) in &pairs {
            let v = value.trim();
            match key.as_str() {
                "method" => {
                    if v != "null" {
                        let s = decode_json_string(v)
                            .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
                        method = s;
                    }
                }
                "headers" => {
                    if v != "null" {
                        headers = parse_analyze_headers(v)?;
                    }
                }
                "body" => {
                    if v != "null" {
                        // Kotlin UrlOption.body 为 String：非字符串值视为非法模板
                        body = decode_json_string(v)
                            .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
                        has_body = true;
                    }
                }
                "followRedirects" => {
                    if v != "null" {
                        follow_redirects = v
                            .parse::<bool>()
                            .ok()
                            .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
                    }
                }
                _ => {}
            }
        }
    }

    method = method.to_ascii_uppercase();
    if method.trim().is_empty() {
        method = "GET".to_string();
    }
    validate_method(&method)?;
    if has_body && method != "POST" {
        return Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            format!("{} body", method),
        ));
    }

    let content_type = headers
        .iter()
        .find(|(k, _)| k == "Content-Type")
        .map(|(_, v)| v.clone());
    let effective_post = if method == "POST" {
        Some(effective_analyze_post(
            if has_body { Some(&body) } else { None },
            content_type.as_deref(),
        ))
    } else {
        None
    };

    // 组装 cURL 命令（对齐 Kotlin 输出顺序）
    let mut parts: Vec<String> = vec!["curl".to_string(), "-g".to_string()];
    if follow_redirects {
        parts.push("-L".to_string());
    }
    if method == "HEAD" {
        parts.push("-I".to_string());
    }
    parts.push(shell_quote(url.trim()));

    for (name, value) in &headers {
        if name.eq_ignore_ascii_case("proxy") || name.eq_ignore_ascii_case("CookieJar") {
            return Err(conv_err(CurlErrorReason::UnsupportedOption, name.clone()));
        }
        if name.eq_ignore_ascii_case("Content-Length")
            || name.eq_ignore_ascii_case("Transfer-Encoding")
        {
            return Err(conv_err(CurlErrorReason::UnsupportedOption, name.clone()));
        }
        if method == "POST" && name.eq_ignore_ascii_case("Content-Type") {
            // POST 的 Content-Type 由 effective_post 统一输出
            continue;
        }
        if name.eq_ignore_ascii_case("User-Agent") && value == "null" {
            parts.push("-A".to_string());
            parts.push(shell_quote(""));
        } else {
            parts.push("-H".to_string());
            parts.push(shell_quote(&format!("{}: {}", name, value)));
        }
    }

    if let Some((post_body, ct)) = effective_post {
        parts.push("-H".to_string());
        parts.push(shell_quote(&format!("Content-Type: {}", ct)));
        parts.push("--data-raw".to_string());
        parts.push(shell_quote(&post_body));
    }

    Ok(parts.join(" "))
}

// =====================================================================
// cURL 词法分析（对齐 Kotlin tokenize）
// =====================================================================

/// 将 cURL 命令拆分为 token：
/// - 单引号内原样保留（无转义）
/// - 双引号内支持 `\\ \" \$ \`` 转义与续行
/// - 反斜杠转义任意字符；`\` + 换行为续行符
/// - 未加引号的 `$` / `` ` `` 视为 shell 展开，拒绝处理
fn tokenize(command: &str) -> LegadoResult<Vec<String>> {
    let chars: Vec<char> = command.chars().collect();
    let mut tokens: Vec<String> = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut token_started = false;
    let mut index: usize = 0;

    while index < chars.len() {
        let ch = chars[index];

        if let Some(q) = quote {
            if ch == q {
                quote = None;
                token_started = true;
                index += 1;
                continue;
            }
            if q == '"' && ch == '\\' && index + 1 < chars.len() {
                let next = chars[index + 1];
                if next == '\n' || next == '\r' {
                    // 双引号内的续行符
                    index += if next == '\r' && chars.get(index + 2) == Some(&'\n') {
                        3
                    } else {
                        2
                    };
                    continue;
                }
                if matches!(next, '\\' | '"' | '$' | '`') {
                    current.push(next);
                    token_started = true;
                    index += 2;
                    continue;
                }
            }
            if q == '"' && (ch == '$' || ch == '`') {
                return Err(conv_err(CurlErrorReason::UnsupportedOption, "shell expansion"));
            }
            current.push(ch);
            token_started = true;
            index += 1;
            continue;
        }

        if ch == '\'' || ch == '"' {
            quote = Some(ch);
            token_started = true;
            index += 1;
        } else if ch.is_whitespace() {
            if token_started {
                tokens.push(std::mem::take(&mut current));
                token_started = false;
            }
            index += 1;
        } else if ch == '\\' {
            if index + 1 >= chars.len() {
                return Err(conv_err(CurlErrorReason::InvalidCurl, ""));
            }
            let next = chars[index + 1];
            if next == '\n' || next == '\r' {
                // 续行符：跳过反斜杠与换行（含 CRLF）
                index += if next == '\r' && chars.get(index + 2) == Some(&'\n') {
                    3
                } else {
                    2
                };
            } else {
                current.push(next);
                token_started = true;
                index += 2;
            }
        } else if ch == '$' || ch == '`' {
            return Err(conv_err(CurlErrorReason::UnsupportedOption, "shell expansion"));
        } else {
            current.push(ch);
            token_started = true;
            index += 1;
        }
    }

    if quote.is_some() {
        return Err(conv_err(CurlErrorReason::InvalidCurl, ""));
    }
    if token_started {
        tokens.push(current);
    }
    Ok(tokens)
}

// =====================================================================
// cURL 选项处理（对齐 Kotlin 各私有方法）
// =====================================================================

/// 解析 `-H "Name: value"` 形式的 header
fn add_header(request: &mut CurlRequest, value: &str) -> LegadoResult<()> {
    if value.starts_with('@') {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "--header @file"));
    }
    let separator = value
        .find(':')
        .ok_or_else(|| conv_err(CurlErrorReason::InvalidCurl, ""))?;
    if separator == 0 {
        return Err(conv_err(CurlErrorReason::InvalidCurl, ""));
    }
    put_header(request, value[..separator].trim(), value[separator + 1..].trim())
}

fn add_user_agent(request: &mut CurlRequest, value: &str) -> LegadoResult<()> {
    put_header(request, "User-Agent", value)
}

fn add_referer(request: &mut CurlRequest, value: &str) -> LegadoResult<()> {
    if value.to_ascii_lowercase().ends_with(";auto") {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "--referer ;auto"));
    }
    if !value.is_empty() {
        put_header(request, "Referer", value)?;
    }
    Ok(())
}

fn add_cookie(request: &mut CurlRequest, value: &str) -> LegadoResult<()> {
    // 不含 `=` 的值视为 cookie 文件名，不支持
    if value.is_empty() || !value.contains('=') {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "--cookie file"));
    }
    put_header(request, "Cookie", value)
}

/// 写入 header（名称规范化 + 合法性校验 + 去重，对齐 Kotlin putHeader）
fn put_header(request: &mut CurlRequest, name: &str, value: &str) -> LegadoResult<()> {
    let normalized_name = normalize_header_name(name)?;
    let is_user_agent = normalized_name == "User-Agent";

    let bad_name = normalized_name.is_empty()
        || normalized_name
            .chars()
            .any(|c| c <= ' ' || c == ':' || (c as u32) >= 127);
    let bad_value = value.contains('\r') || value.contains('\n');
    if bad_name || bad_value || (value.is_empty() && !is_user_agent) {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "empty header"));
    }
    if is_user_agent && value == "null" {
        return Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            "User-Agent: null",
        ));
    }
    if request
        .headers
        .iter()
        .any(|(k, _)| k.eq_ignore_ascii_case(&normalized_name))
    {
        return Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            format!("duplicate header: {}", normalized_name),
        ));
    }
    let final_value = if is_user_agent && value.is_empty() {
        "null".to_string()
    } else {
        value.to_string()
    };
    request.headers.push((normalized_name, final_value));
    Ok(())
}

/// header 名称规范化（对齐 Kotlin normalizeHeaderName）
fn normalize_header_name(name: &str) -> LegadoResult<String> {
    Ok(match name.to_ascii_lowercase().as_str() {
        "content-type" => "Content-Type".to_string(),
        "cookie" => "Cookie".to_string(),
        "user-agent" => "User-Agent".to_string(),
        "referer" => "Referer".to_string(),
        "accept" => "Accept".to_string(),
        "proxy" | "cookiejar" | "content-length" | "transfer-encoding" => {
            return Err(conv_err(CurlErrorReason::UnsupportedOption, name.to_string()))
        }
        _ => name.to_string(),
    })
}

/// 补充默认 header（已存在同名时不覆盖，对齐 Kotlin putDefaultHeader）
fn put_default_header(request: &mut CurlRequest, name: &str, value: &str) {
    if !request
        .headers
        .iter()
        .any(|(k, _)| k.eq_ignore_ascii_case(name))
    {
        request.headers.push((name.to_string(), value.to_string()));
    }
}

/// 设置 URL（多 URL 不支持，对齐 Kotlin setUrl）
fn set_url(request: &mut CurlRequest, value: &str) -> LegadoResult<()> {
    if !request.url.is_empty() {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "multiple URLs"));
    }
    request.url = value.to_string();
    Ok(())
}

/// 追加 body 片段（`@file` 形式不支持，--data-raw 除外，对齐 Kotlin addBody）
fn add_body(request: &mut CurlRequest, option: &str, value: &str) -> LegadoResult<()> {
    if option != "--data-raw" && value.starts_with('@') {
        return Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            format!("{} @file", option),
        ));
    }
    request.body_parts.push(value.to_string());
    Ok(())
}

/// 处理 `--data-urlencode`（Kotlin 版不支持，此处为扩展实现）
///
/// 支持形式：`name=content`（仅编码值）、`=content`、`content`（整体编码）；
/// `@file` 形式不支持。
fn add_body_urlencode(request: &mut CurlRequest, value: &str) -> LegadoResult<()> {
    if value.is_empty() || value.starts_with('@') {
        return Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            "--data-urlencode @file",
        ));
    }
    let encoded = if let Some(rest) = value.strip_prefix('=') {
        urlencoding::encode(rest).into_owned()
    } else if let Some(eq) = value.find('=') {
        format!("{}={}", &value[..eq], urlencoding::encode(&value[eq + 1..]))
    } else {
        urlencoding::encode(value).into_owned()
    };
    request.body_parts.push(encoded);
    Ok(())
}

/// 推断最终 HTTP 方法（对齐 Kotlin resolveCurlMethod）
fn resolve_curl_method(request: &CurlRequest) -> LegadoResult<String> {
    let custom_method = request.custom_method.clone();
    if let Some(m) = &custom_method {
        validate_method(m)?;
    }
    if request.follow_redirects && custom_method.as_deref() == Some("POST") {
        return Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            "-X POST with -L",
        ));
    }
    if request.head {
        if !request.body_parts.is_empty()
            || custom_method
                .as_ref()
                .map(|m| m != "HEAD")
                .unwrap_or(false)
        {
            let detail = custom_method
                .as_ref()
                .map(|m| format!("-I with {}", m))
                .unwrap_or_else(|| "-I with null".to_string());
            return Err(conv_err(CurlErrorReason::UnsupportedOption, detail));
        }
        return Ok("HEAD".to_string());
    }
    if !request.body_parts.is_empty() {
        if custom_method
            .as_ref()
            .map(|m| m != "POST")
            .unwrap_or(false)
        {
            return Err(conv_err(
                CurlErrorReason::UnsupportedOption,
                format!("{} body", custom_method.as_deref().unwrap_or("")),
            ));
        }
        return Ok("POST".to_string());
    }
    match custom_method.as_deref() {
        None | Some("GET") => Ok("GET".to_string()),
        Some(m) => Err(conv_err(
            CurlErrorReason::UnsupportedOption,
            format!("{} without body", m),
        )),
    }
}

/// 校验 HTTP 方法是否受支持（GET/POST/HEAD，对齐 Kotlin validateMethod）
fn validate_method(method: &str) -> LegadoResult<()> {
    if !matches!(method, "GET" | "POST" | "HEAD") {
        return Err(conv_err(
            CurlErrorReason::UnsupportedMethod,
            method.to_string(),
        ));
    }
    Ok(())
}

/// 提取不支持选项的名称用于报错（对齐 Kotlin optionName）
fn option_name(token: &str) -> String {
    if token.starts_with("--") {
        token.split('=').next().unwrap_or(token).to_string()
    } else {
        token.chars().take(2).collect()
    }
}

// =====================================================================
// URL 校验（对齐 Kotlin validateUrl / hasCurlGlob）
// =====================================================================

/// 校验 URL 合法性：
/// - 未开 globoff 时禁止 cURL 通配符（`{}` / 非 IPv6 的 `[]`）
/// - 禁止 AnalyzeUrl 选项模式 `,{`
/// - 必须是 HTTP(S) URL，且不含 userinfo（对齐 Kotlin okhttp 校验语义）
fn validate_url(value: &str, glob_off: bool) -> LegadoResult<()> {
    if !glob_off && has_curl_glob(value) {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "URL glob"));
    }
    if has_analyze_param_marker(value) {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "URL ,{"));
    }
    let rest = if let Some(r) = value.strip_prefix("http://") {
        r
    } else if let Some(r) = value.strip_prefix("https://") {
        r
    } else {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "HTTP(S) URL"));
    };
    let authority_end = rest
        .find(|c| c == '/' || c == '?' || c == '#')
        .unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    if authority.is_empty() || authority.contains('@') {
        return Err(conv_err(CurlErrorReason::UnsupportedOption, "URL userinfo"));
    }
    Ok(())
}

/// 检测 cURL URL 通配符（对齐 Kotlin hasCurlGlob）
fn has_curl_glob(value: &str) -> bool {
    if value.contains('{') || value.contains('}') {
        return true;
    }
    if !value.contains('[') && !value.contains(']') {
        return false;
    }
    let authority_start = match value.find("://") {
        Some(i) => i + 3,
        None => return true,
    };
    let authority_end = value[authority_start..]
        .find(|c| c == '/' || c == '?' || c == '#')
        .map(|i| authority_start + i)
        .unwrap_or(value.len());
    let authority = &value[authority_start..authority_end];
    let ipv6 = regex::Regex::new(r"^(?:[^@]+@)?\[[0-9A-Fa-f:.%]+\](?::[0-9]+)?$").unwrap();
    !ipv6.is_match(authority) || value[authority_end..].contains(|c| c == '[' || c == ']')
}

/// 检测文本中是否存在 AnalyzeUrl 参数模式 `\s*,\s*(?=\{)`
fn has_analyze_param_marker(value: &str) -> bool {
    regex::Regex::new(r"\s*,\s*\{").unwrap().is_match(value)
}

/// 按 Kotlin AnalyzeUrl.paramPattern（`\s*,\s*(?=\{)`）拆分 URL 与选项 JSON
///
/// 注：Rust `regex` crate 不支持前瞻，改用 `\s*,\s*\{`（吞掉 `{`），
/// 再从匹配末尾回退一位定位 `{` 作为选项 JSON 起点，语义与 Kotlin 一致。
fn split_analyze_params(raw: &str) -> (&str, Option<&str>) {
    let re = regex::Regex::new(r"\s*,\s*\{").unwrap();
    if let Some(m) = re.find(raw) {
        // m.start() = 首个前置空白/逗号位置；`{` 位于 m.end()-1
        (&raw[..m.start()], Some(raw[m.end() - 1..].trim()))
    } else {
        (raw, None)
    }
}

// =====================================================================
// AnalyzeUrl 选项 JSON 的保序扫描（对齐 Kotlin LinkedHashMap 语义）
// =====================================================================

/// 轻量 JSON 游标（仅用于保序提取顶层键值对）
struct JsonCursor<'a> {
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> JsonCursor<'a> {
    fn new(s: &'a str) -> Self {
        Self {
            bytes: s.as_bytes(),
            pos: 0,
        }
    }

    /// 前瞻当前字节（按字符推进，不会停在 UTF-8 中间）
    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    /// 推进一个 UTF-8 字符
    fn advance(&mut self) {
        let mut next = self.pos + 1;
        while next < self.bytes.len() && (self.bytes[next] & 0xC0) == 0x80 {
            next += 1;
        }
        self.pos = next;
    }

    fn skip_ws(&mut self) {
        while let Some(b) = self.peek() {
            if matches!(b, b' ' | b'\t' | b'\n' | b'\r') {
                self.pos += 1;
            } else {
                break;
            }
        }
    }

    /// 解析 JSON 字符串，返回解码后的值
    fn parse_string(&mut self) -> LegadoResult<String> {
        self.skip_ws();
        if self.peek() != Some(b'"') {
            return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
        }
        self.pos += 1;
        let mut out = String::new();
        while let Some(b) = self.peek() {
            match b {
                b'"' => {
                    self.pos += 1;
                    return Ok(out);
                }
                b'\\' => {
                    self.pos += 1;
                    let e = self
                        .peek()
                        .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
                    self.pos += 1;
                    match e {
                        b'"' => out.push('"'),
                        b'\\' => out.push('\\'),
                        b'/' => out.push('/'),
                        b'b' => out.push('\u{0008}'),
                        b'f' => out.push('\u{000C}'),
                        b'n' => out.push('\n'),
                        b'r' => out.push('\r'),
                        b't' => out.push('\t'),
                        b'u' => {
                            if self.pos + 4 > self.bytes.len() {
                                return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
                            }
                            let cp = std::str::from_utf8(&self.bytes[self.pos..self.pos + 4])
                                .ok()
                                .and_then(|h| u32::from_str_radix(h, 16).ok())
                                .and_then(char::from_u32)
                                .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
                            out.push(cp);
                            self.pos += 4;
                        }
                        _ => return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, "")),
                    }
                }
                _ => {
                    let start = self.pos;
                    self.advance();
                    out.push_str(std::str::from_utf8(&self.bytes[start..self.pos]).map_err(
                        |_| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""),
                    )?);
                }
            }
        }
        Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))
    }

    /// 扫描并跳过一个任意 JSON 值，返回其原文片段
    fn scan_value(&mut self) -> LegadoResult<&'a str> {
        self.skip_ws();
        let start = self.pos;
        match self.peek() {
            Some(b'"') => {
                self.parse_string()?;
            }
            Some(b'{') | Some(b'[') => {
                self.skip_container()?;
            }
            Some(_) => {
                // null / true / false / 数字：扫描到结构边界为止
                while let Some(b) = self.peek() {
                    if matches!(b, b',' | b'}' | b']') || b.is_ascii_whitespace() {
                        break;
                    }
                    self.pos += 1;
                }
                if self.pos == start {
                    return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
                }
            }
            None => {
                return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
            }
        }
        let end = self.pos;
        std::str::from_utf8(&self.bytes[start..end])
            .map_err(|_| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))
    }

    /// 跳过配对的 `{}` / `[]` 容器（正确处理字符串与转义）
    fn skip_container(&mut self) -> LegadoResult<()> {
        let open = self.peek().unwrap();
        let close = if open == b'{' { b'}' } else { b']' };
        let mut depth = 0usize;
        let mut in_str = false;
        let mut esc = false;
        while let Some(b) = self.peek() {
            if in_str {
                if esc {
                    esc = false;
                } else if b == b'\\' {
                    esc = true;
                } else if b == b'"' {
                    in_str = false;
                }
            } else {
                match b {
                    b'"' => in_str = true,
                    b if b == open => depth += 1,
                    b if b == close => {
                        depth -= 1;
                        if depth == 0 {
                            self.pos += 1;
                            return Ok(());
                        }
                    }
                    _ => {}
                }
            }
            self.pos += 1;
        }
        Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))
    }
}

/// 保序解析 JSON 对象顶层键值对（值为原文片段）
fn parse_object_pairs(json: &str) -> LegadoResult<Vec<(String, String)>> {
    let mut c = JsonCursor::new(json);
    c.skip_ws();
    if c.peek() != Some(b'{') {
        return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
    }
    c.pos += 1;
    let mut pairs = Vec::new();
    loop {
        c.skip_ws();
        match c.peek() {
            None => return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, "")),
            Some(b'}') => {
                return Ok(pairs);
            }
            Some(b'"') => {}
            Some(_) => return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, "")),
        }
        let key = c.parse_string()?;
        c.skip_ws();
        if c.peek() != Some(b':') {
            return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
        }
        c.pos += 1;
        let value = c.scan_value()?.trim().to_string();
        pairs.push((key, value));
        c.skip_ws();
        match c.peek() {
            Some(b',') => {
                c.pos += 1;
            }
            Some(b'}') => {
                return Ok(pairs);
            }
            _ => return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, "")),
        }
    }
}

/// 解码 JSON 字符串字面量（非字符串返回 None）
fn decode_json_string(raw: &str) -> Option<String> {
    let mut c = JsonCursor::new(raw);
    if c.peek() != Some(b'"') {
        return None;
    }
    c.parse_string().ok()
}

/// 将 JSON 标量值转为字符串表示（对齐 Kotlin value.toString()）
fn json_scalar_to_string(raw: &str) -> Option<String> {
    let v = raw.trim();
    if v.starts_with('"') {
        decode_json_string(v)
    } else if v == "null" {
        Some("null".to_string())
    } else if v
        .chars()
        .all(|c| c == '-' || c == '+' || c == '.' || c.is_ascii_alphanumeric())
    {
        Some(v.to_string())
    } else {
        None
    }
}

/// 解析 AnalyzeUrl 选项中的 headers（对象或 JSON 字符串形式，保序）
fn parse_analyze_headers(raw: &str) -> LegadoResult<Vec<(String, String)>> {
    let v = raw.trim();
    let inner;
    let object_src = if v.starts_with('"') {
        // headers 为 JSON 字符串：先解码再按对象解析
        inner = decode_json_string(v)
            .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
        inner.as_str()
    } else if v.starts_with('{') {
        v
    } else {
        return Err(conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""));
    };
    let pairs = parse_object_pairs(object_src)
        .map_err(|_| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))?;
    pairs
        .into_iter()
        .map(|(k, val)| {
            json_scalar_to_string(&val)
                .map(|s| (k, s))
                .ok_or_else(|| conv_err(CurlErrorReason::InvalidAnalyzeUrl, ""))
        })
        .collect()
}

// =====================================================================
// AnalyzeUrl POST 生效逻辑与表单编码（对齐 Kotlin effectiveAnalyzePost 等）
// =====================================================================

/// 计算 POST 的生效 body 与 Content-Type（对齐 Kotlin effectiveAnalyzePost）
fn effective_analyze_post(body: Option<&str>, content_type: Option<&str>) -> (String, String) {
    let body_is_blank = body.map(|b| b.trim().is_empty()).unwrap_or(true);
    if body_is_blank {
        return (String::new(), FORM_CONTENT_TYPE.to_string());
    }
    let body = body.unwrap();
    if content_type.map(|c| !c.trim().is_empty()).unwrap_or(false) {
        return (body.to_string(), content_type.unwrap().to_string());
    }
    // Kotlin 的第三分支（isNullOrEmpty 且非 isNullOrBlank）为死代码，此处省略
    if is_json_like(body) || is_xml_like(body) {
        return (body.to_string(), JSON_CONTENT_TYPE.to_string());
    }
    (encode_analyze_form(body), FORM_CONTENT_TYPE.to_string())
}

/// 对齐 Kotlin String.isJson()：trim 后以 `{`/`}` 或 `[`/`]` 成对包裹
fn is_json_like(s: &str) -> bool {
    let t = s.trim();
    (t.starts_with('{') && t.ends_with('}')) || (t.starts_with('[') && t.ends_with(']'))
}

/// 对齐 Kotlin String.isXml()：trim 后以 `<` 开头 `>` 结尾
fn is_xml_like(s: &str) -> bool {
    let t = s.trim();
    t.starts_with('<') && t.ends_with('>')
}

/// 表单 body 编码（对齐 Kotlin encodeAnalyzeForm：按 `&` 拆分，`=` 两侧分别编码）
fn encode_analyze_form(params: &str) -> String {
    params
        .split('&')
        .map(|field| match field.find('=') {
            None => encode_form_part(field),
            Some(sep) => format!(
                "{}={}",
                encode_form_part(&field[..sep]),
                encode_form_part(&field[sep + 1..])
            ),
        })
        .collect::<Vec<_>>()
        .join("&")
}

/// 对齐 Kotlin encodeFormPart：已编码则保留，否则 URLEncoder 编码
fn encode_form_part(value: &str) -> String {
    if encoded_form(value) {
        value.to_string()
    } else {
        url_encoder_encode(value)
    }
}

/// 对齐 Kotlin NetworkUtils.encodedForm：字母数字与 `*-._` 免编码，`%XX` 视为已编码
fn encoded_form(s: &str) -> bool {
    let chars: Vec<char> = s.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if c.is_ascii_alphanumeric() || matches!(c, '*' | '-' | '.' | '_') {
            i += 1;
            continue;
        }
        if c == '%' && i + 2 < chars.len() {
            let c1 = chars[i + 1];
            let c2 = chars[i + 2];
            if c1.is_ascii_hexdigit() && c2.is_ascii_hexdigit() {
                i += 3;
                continue;
            }
        }
        return false;
    }
    true
}

/// 对齐 Java `URLEncoder.encode(value, UTF-8)`：
/// 字母数字与 `*-._` 保留，空格转 `+`，其余按 UTF-8 字节转 `%XX`（大写）
fn url_encoder_encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'*' | b'-' | b'.' | b'_' => {
                out.push(b as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// =====================================================================
// Shell 转义与 JSON 转义
// =====================================================================

/// POSIX shell 安全引用（对齐 Kotlin shellQuote）：
/// 安全字符直接输出，否则单引号包裹并将内部单引号转义为 `'"'"'`
fn shell_quote(value: &str) -> String {
    if !value.is_empty()
        && value.chars().all(|c| {
            c.is_ascii_alphanumeric()
                || matches!(c, '_' | '@' | '%' | '+' | '=' | ':' | ',' | '.' | '/' | '-')
        })
    {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}

/// JSON 字符串字面量转义（标准 JSON，不做 HTML 转义，对齐 Gson disableHtmlEscaping）
fn json_string(value: &str) -> String {
    let mut out = String::with_capacity(value.len() + 2);
    out.push('"');
    for c in value.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

// =====================================================================
// 测试
// =====================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// 断言错误属于指定原因
    fn assert_reason(err: &LegadoError, reason: CurlErrorReason) {
        assert!(is_curl_error(err, reason), "错误 {:?} 不属于 {:?}", err, reason);
    }

    /// 按名称查找 header（忽略大小写，测试辅助）
    fn header_of<'a>(r: &'a CurlParseResult, name: &str) -> Option<&'a String> {
        r.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v)
    }

    // ---------- 解析测试 ----------

    #[test]
    fn parse_simple_get() {
        let r = parse_curl("curl https://example.com/book?id=1").unwrap();
        assert_eq!(r.url, "https://example.com/book?id=1");
        assert_eq!(r.method, "GET");
        assert!(r.headers.is_empty());
        assert!(r.body.is_none());
        // 对齐 Kotlin：无 -L 时 followRedirects 默认 false
        assert!(!r.follow_redirects);
    }

    #[test]
    fn parse_simple_get_with_flags() {
        let r = parse_curl("curl.exe -sS -g -L 'https://example.com/p'").unwrap();
        assert_eq!(r.url, "https://example.com/p");
        assert_eq!(r.method, "GET");
        assert!(r.glob_off);
        assert!(r.follow_redirects);
    }

    #[test]
    fn parse_post_json_body() {
        let r = parse_curl(
            r#"curl -X POST 'https://api.example.com/search' -H 'Content-Type: application/json' -d '{"key":"value","n":1}'"#,
        )
        .unwrap();
        assert_eq!(r.method, "POST");
        assert_eq!(r.body.as_deref(), Some(r#"{"key":"value","n":1}"#));
        assert_eq!(
            r.headers,
            vec![("Content-Type".to_string(), "application/json".to_string())]
        );
    }

    #[test]
    fn parse_post_inferred_without_x() {
        // 无 -X 时按 body 推断为 POST，并补充默认 Content-Type
        let r = parse_curl("curl https://example.com/api -d 'a=1&b=2'").unwrap();
        assert_eq!(r.method, "POST");
        assert_eq!(r.body.as_deref(), Some("a=1&b=2"));
        assert_eq!(
            r.headers,
            vec![("Content-Type".to_string(), FORM_CONTENT_TYPE.to_string())]
        );
    }

    #[test]
    fn parse_multiple_headers() {
        let r = parse_curl(
            "curl https://example.com -H 'X-One: 1' --header 'X-Two: 2' -HX-Three:3 \
             -A 'MyAgent/1.0' -b 'a=1; b=2' -e 'https://ref.example.com'",
        )
        .unwrap();
        assert_eq!(
            r.headers,
            vec![
                ("X-One".to_string(), "1".to_string()),
                ("X-Two".to_string(), "2".to_string()),
                ("X-Three".to_string(), "3".to_string()),
                ("User-Agent".to_string(), "MyAgent/1.0".to_string()),
                ("Cookie".to_string(), "a=1; b=2".to_string()),
                ("Referer".to_string(), "https://ref.example.com".to_string()),
            ]
        );
    }

    #[test]
    fn parse_header_normalization_and_unicode() {
        // 注：对齐 Kotlin，header 名含非 ASCII 字符会被拒绝（putHeader 校验），
        // 但 header 值支持中文/Unicode
        let r = parse_curl(
            "curl https://example.com -H 'content-type: application/json' \
             -H 'Accept: text/html' -H 'X-CN: 中文值'",
        )
        .unwrap();
        assert_eq!(
            r.headers,
            vec![
                ("Content-Type".to_string(), "application/json".to_string()),
                ("Accept".to_string(), "text/html".to_string()),
                ("X-CN".to_string(), "中文值".to_string()),
            ]
        );
        // 非 ASCII header 名被拒绝
        assert_reason(
            &parse_curl("curl https://example.com -H '自定义: v'").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
    }

    #[test]
    fn parse_special_chars_quotes_and_escapes() {
        // 单引号内含双引号；双引号内转义 \" 与 \\；含中文
        let r = parse_curl(
            r#"curl https://example.com -H 'Cookie: s="a b"; t=x' -d "中文 \"引号\" \\end""#,
        )
        .unwrap();
        assert_eq!(
            header_of(&r, "Cookie").map(|s| s.as_str()),
            Some("s=\"a b\"; t=x")
        );
        assert_eq!(r.body.as_deref(), Some("中文 \"引号\" \\end"));
    }

    #[test]
    fn parse_multiline_continuation() {
        let cmd = "curl 'https://example.com/api' \\\n  -H 'X-A: 1' \\\r\n  -d 'x=1'";
        let r = parse_curl(cmd).unwrap();
        assert_eq!(r.url, "https://example.com/api");
        assert_eq!(r.method, "POST");
        assert_eq!(r.body.as_deref(), Some("x=1"));
        assert_eq!(r.headers.len(), 2);
    }

    #[test]
    fn parse_data_urlencode() {
        let r = parse_curl("curl https://example.com/s --data-urlencode 'q=你好 world'").unwrap();
        assert_eq!(r.body.as_deref(), Some("q=%E4%BD%A0%E5%A5%BD%20world"));
        assert_eq!(r.method, "POST");
    }

    #[test]
    fn parse_data_urlencode_forms() {
        // =content 形式：整体编码
        let r = parse_curl("curl https://example.com/s --data-urlencode '=a&b'").unwrap();
        assert_eq!(r.body.as_deref(), Some("a%26b"));
        // content 形式（无 =）：整体编码；粘连形式同样支持
        let r2 = parse_curl("curl https://example.com/s --data-urlencode='a b'").unwrap();
        assert_eq!(r2.body.as_deref(), Some("a%20b"));
    }

    #[test]
    fn parse_multiple_data_joined() {
        let r = parse_curl("curl https://example.com -d a=1 -d b=2").unwrap();
        assert_eq!(r.body.as_deref(), Some("a=1&b=2"));
    }

    #[test]
    fn parse_json_option_adds_headers() {
        let r = parse_curl("curl https://example.com --json '{\"a\":1}'").unwrap();
        assert_eq!(r.method, "POST");
        assert_eq!(r.body.as_deref(), Some("{\"a\":1}"));
        assert!(r
            .headers
            .contains(&("Content-Type".to_string(), "application/json".to_string())));
        assert!(r
            .headers
            .contains(&("Accept".to_string(), "application/json".to_string())));
    }

    #[test]
    fn parse_url_option_and_end_of_options() {
        let r = parse_curl("curl --url https://example.com/a").unwrap();
        assert_eq!(r.url, "https://example.com/a");
        let r2 = parse_curl("curl -H 'X: 1' -- https://example.com/b").unwrap();
        assert_eq!(r2.url, "https://example.com/b");
    }

    #[test]
    fn parse_head_method() {
        let r = parse_curl("curl -I https://example.com").unwrap();
        assert_eq!(r.method, "HEAD");
        assert!(r.body.is_none());
    }

    #[test]
    fn parse_user_agent_null_marker() {
        // -A '' 表示清除 UA，序列化为 "null" 标记（对齐 Kotlin）
        let r = parse_curl("curl https://example.com -A ''").unwrap();
        assert_eq!(r.headers, vec![("User-Agent".to_string(), "null".to_string())]);
    }

    // ---------- 解析错误测试 ----------

    #[test]
    fn parse_errors() {
        // 空输入由 curl_to_analyze_url 判定
        assert_reason(
            &curl_to_analyze_url("   ").unwrap_err(),
            CurlErrorReason::EmptyInput,
        );
        // 非法命令
        assert_reason(
            &parse_curl("wget https://example.com").unwrap_err(),
            CurlErrorReason::InvalidCurl,
        );
        // 缺少 URL
        assert_reason(
            &parse_curl("curl -H 'X: 1'").unwrap_err(),
            CurlErrorReason::MissingUrl,
        );
        // 不支持的选项
        assert_reason(
            &parse_curl("curl https://example.com --http2").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // shell 展开拒绝
        assert_reason(
            &parse_curl("curl https://example.com -d $VAR").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // 引号不闭合
        assert_reason(
            &parse_curl("curl 'https://example.com").unwrap_err(),
            CurlErrorReason::InvalidCurl,
        );
        // 多 URL
        assert_reason(
            &parse_curl("curl https://a.com https://b.com").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // URL 通配符（校验发生在 curl_to_analyze_url，对齐 Kotlin）
        assert_reason(
            &curl_to_analyze_url("curl https://example.com/page[1-3].html").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // 不支持的方法
        assert_reason(
            &parse_curl("curl -X DELETE https://example.com -d x").unwrap_err(),
            CurlErrorReason::UnsupportedMethod,
        );
        // -X PUT：方法不在 GET/POST/HEAD 支持列表中
        assert_reason(
            &parse_curl("curl -X PUT https://example.com").unwrap_err(),
            CurlErrorReason::UnsupportedMethod,
        );
        // -X POST 与 -L 冲突
        assert_reason(
            &parse_curl("curl -L -X POST https://example.com -d x").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // 重复 header
        assert_reason(
            &parse_curl("curl https://example.com -H 'A: 1' -H 'a: 2'").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // cookie 文件名形式
        assert_reason(
            &parse_curl("curl https://example.com -b cookies.txt").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // @file 形式
        assert_reason(
            &parse_curl("curl https://example.com -d @body.txt").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // header 缺分隔符
        assert_reason(
            &parse_curl("curl https://example.com -H 'NoColon'").unwrap_err(),
            CurlErrorReason::InvalidCurl,
        );
    }

    #[test]
    fn looks_like_curl_check() {
        assert!(looks_like_curl("curl https://example.com"));
        assert!(looks_like_curl("  curl.exe -s https://example.com"));
        assert!(looks_like_curl("CURL"));
        assert!(!looks_like_curl("curling https://example.com"));
        assert!(!looks_like_curl("wget https://example.com"));
    }

    // ---------- curl → AnalyzeUrl 模板 ----------

    #[test]
    fn curl_to_analyze_url_get_plain() {
        // 无 -L → 输出 followRedirects:false（对齐 Kotlin）
        let out = curl_to_analyze_url("curl https://example.com/book?id=1").unwrap();
        assert_eq!(
            out,
            "https://example.com/book?id=1,{\"followRedirects\":false}"
        );
        // 带 -L 时不输出 followRedirects
        let out = curl_to_analyze_url("curl -L https://example.com/book?id=1").unwrap();
        assert_eq!(out, "https://example.com/book?id=1");
    }

    #[test]
    fn curl_to_analyze_url_post_with_options() {
        let out = curl_to_analyze_url(
            r#"curl -X POST 'https://api.example.com/s' -H 'Content-Type: application/json' -H 'X-T: it'"'"'s' -d '{"q":"书"}'"#,
        )
        .unwrap();
        assert_eq!(
            out,
            "https://api.example.com/s,{\"method\":\"POST\",\"headers\":{\"Content-Type\":\"application/json\",\"X-T\":\"it's\"},\"body\":\"{\\\"q\\\":\\\"书\\\"}\",\"followRedirects\":false}"
        );
    }

    #[test]
    fn curl_to_analyze_url_follow_redirects_false() {
        let out = curl_to_analyze_url("curl -I https://example.com/h").unwrap();
        assert_eq!(
            out,
            "https://example.com/h,{\"method\":\"HEAD\",\"followRedirects\":false}"
        );
    }

    #[test]
    fn curl_to_analyze_url_blank_body_rejected() {
        // 空白 body（非空字符串）被拒绝
        assert_reason(
            &curl_to_analyze_url("curl https://example.com -d '  '").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // `-d ''` + FORM Content-Type 允许通过（对齐 Kotlin）
        let out = curl_to_analyze_url(
            "curl https://example.com -d '' -H 'Content-Type: application/x-www-form-urlencoded'",
        )
        .unwrap();
        assert!(out.contains("\"body\":\"\""));
    }

    // ---------- AnalyzeUrl 模板 → curl ----------

    #[test]
    fn analyze_url_to_curl_get() {
        // URL 含 `?` 不在安全字符集内，需单引号包裹（对齐 Kotlin shellQuote）
        let out = analyze_url_to_curl("https://example.com/book?id=1").unwrap();
        assert_eq!(out, "curl -g -L 'https://example.com/book?id=1'");
        // 纯安全字符 URL 不加引号
        let out = analyze_url_to_curl("https://example.com/book").unwrap();
        assert_eq!(out, "curl -g -L https://example.com/book");
    }

    #[test]
    fn analyze_url_to_curl_get_with_headers_no_redirect() {
        let out = analyze_url_to_curl(
            "https://example.com,{\"headers\":{\"User-Agent\":\"legado\"},\"followRedirects\":false}",
        )
        .unwrap();
        assert_eq!(out, "curl -g https://example.com -H 'User-Agent: legado'");
    }

    #[test]
    fn analyze_url_to_curl_user_agent_null() {
        let out =
            analyze_url_to_curl("https://example.com,{\"headers\":{\"User-Agent\":\"null\"}}")
                .unwrap();
        assert_eq!(out, "curl -g -L https://example.com -A ''");
    }

    #[test]
    fn analyze_url_to_curl_post_json_body() {
        let out = analyze_url_to_curl(
            "https://api.example.com/s,{\"method\":\"POST\",\"headers\":{\"Content-Type\":\"application/json\",\"X-T\":\"it's\"},\"body\":\"{\\\"q\\\":\\\"书\\\"}\"}",
        )
        .unwrap();
        assert_eq!(
            out,
            r#"curl -g -L https://api.example.com/s -H 'X-T: it'"'"'s' -H 'Content-Type: application/json' --data-raw '{"q":"书"}'"#
        );
    }

    #[test]
    fn analyze_url_to_curl_post_form_encoded() {
        // 非 JSON/XML body 且无 Content-Type → 表单编码 + FORM Content-Type
        let out = analyze_url_to_curl(
            "https://example.com/s,{\"method\":\"POST\",\"body\":\"wd=你好&p=2\"}",
        )
        .unwrap();
        assert_eq!(
            out,
            "curl -g -L https://example.com/s -H 'Content-Type: application/x-www-form-urlencoded' --data-raw 'wd=%E4%BD%A0%E5%A5%BD&p=2'"
        );
    }

    #[test]
    fn analyze_url_to_curl_head() {
        let out = analyze_url_to_curl(
            "https://example.com/h,{\"method\":\"HEAD\",\"followRedirects\":false}",
        )
        .unwrap();
        assert_eq!(out, "curl -g -I https://example.com/h");
    }

    #[test]
    fn analyze_url_to_curl_errors() {
        // 空输入
        assert_reason(
            &analyze_url_to_curl("  ").unwrap_err(),
            CurlErrorReason::EmptyInput,
        );
        // 缺 URL
        assert_reason(
            &analyze_url_to_curl(",{\"method\":\"GET\"}").unwrap_err(),
            CurlErrorReason::MissingUrl,
        );
        // 不支持的选项键
        let err =
            analyze_url_to_curl("https://example.com,{\"charset\":\"utf-8\"}").unwrap_err();
        assert_reason(&err, CurlErrorReason::UnsupportedOption);
        // 不支持的方法
        assert_reason(
            &analyze_url_to_curl("https://example.com,{\"method\":\"PUT\"}").unwrap_err(),
            CurlErrorReason::UnsupportedMethod,
        );
        // GET 带 body
        assert_reason(
            &analyze_url_to_curl("https://example.com,{\"body\":\"x\"}").unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
        // body 非字符串
        assert_reason(
            &analyze_url_to_curl("https://example.com,{\"method\":\"POST\",\"body\":{\"a\":1}}")
                .unwrap_err(),
            CurlErrorReason::InvalidAnalyzeUrl,
        );
        // 非法 JSON
        assert_reason(
            &analyze_url_to_curl("https://example.com,{\"method\":").unwrap_err(),
            CurlErrorReason::InvalidAnalyzeUrl,
        );
        // 不支持的 header 键
        assert_reason(
            &analyze_url_to_curl(
                "https://example.com,{\"headers\":{\"proxy\":\"http://127.0.0.1\"}}",
            )
            .unwrap_err(),
            CurlErrorReason::UnsupportedOption,
        );
    }

    // ---------- to_curl 序列化 ----------

    #[test]
    fn to_curl_basic() {
        let params = CurlRequestParams {
            url: "https://example.com/s?q=a b".to_string(),
            method: "POST".to_string(),
            headers: vec![("X-Token".to_string(), "abc'123".to_string())],
            body: Some("{\"k\":\"v\"}".to_string()),
            follow_redirects: true,
        };
        assert_eq!(
            to_curl(&params),
            r#"curl -g -L 'https://example.com/s?q=a b' -H 'X-Token: abc'"'"'123' --data-raw '{"k":"v"}'"#
        );
    }

    #[test]
    fn to_curl_head_get() {
        let params = CurlRequestParams {
            url: "https://example.com/".to_string(),
            method: "HEAD".to_string(),
            ..Default::default()
        };
        assert_eq!(to_curl(&params), "curl -g -I https://example.com/");
    }

    // ---------- 往返测试 ----------

    #[test]
    fn roundtrip_curl_struct_curl() {
        // cURL → 结构 → cURL → 结构，两次结构必须一致
        let src = "curl -X POST 'https://api.example.com/s?a=1' -H 'Content-Type: application/json' \
                   -H 'X-T: v' --data-raw '{\"q\":\"书\"}'";
        let r1 = parse_curl(src).unwrap();
        let cmd = to_curl(&CurlRequestParams::from(&r1));
        let r2 = parse_curl(&cmd).unwrap();
        assert_eq!(r1.url, r2.url);
        assert_eq!(r1.method, r2.method);
        assert_eq!(r1.headers, r2.headers);
        assert_eq!(r1.body, r2.body);
    }

    #[test]
    fn roundtrip_curl_analyze_url_curl() {
        // cURL → AnalyzeUrl 模板 → cURL → 结构，与原始结构一致
        let src = "curl -X POST 'https://api.example.com/s' -H 'Content-Type: application/json' -d '{\"q\":\"书\"}'";
        let r1 = parse_curl(src).unwrap();
        let template = curl_to_analyze_url(src).unwrap();
        let cmd = analyze_url_to_curl(&template).unwrap();
        let r2 = parse_curl(&cmd).unwrap();
        assert_eq!(r1.url, r2.url);
        assert_eq!(r1.method, r2.method);
        assert_eq!(r1.headers, r2.headers);
        assert_eq!(r1.body, r2.body);
    }

    #[test]
    fn roundtrip_analyze_url_curl_analyze_url() {
        // AnalyzeUrl 模板 → cURL → AnalyzeUrl 模板（GET 头部场景）
        let template = "https://example.com/list,{\"headers\":{\"User-Agent\":\"legado\",\"X-From\":\"app\"},\"followRedirects\":false}";
        let cmd = analyze_url_to_curl(template).unwrap();
        let template2 = curl_to_analyze_url(&cmd).unwrap();
        assert_eq!(template, template2);
    }

    #[test]
    fn roundtrip_get_plain() {
        let src = "curl -g 'https://example.com/page?x=1&y=中文'";
        let template = curl_to_analyze_url(src).unwrap();
        // 无 -L → 模板携带 followRedirects:false
        assert_eq!(
            template,
            "https://example.com/page?x=1&y=中文,{\"followRedirects\":false}"
        );
        let cmd = analyze_url_to_curl(&template).unwrap();
        let r = parse_curl(&cmd).unwrap();
        assert_eq!(r.url, "https://example.com/page?x=1&y=中文");
        assert_eq!(r.method, "GET");
        assert!(!r.follow_redirects);
    }
}
