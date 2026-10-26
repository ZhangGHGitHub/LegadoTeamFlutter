//! 直链上传 FFI（契约 §2.51，批16a）
//!
//! 流程（逐条对齐原版 `help/DirectLinkUpload.kt:26-71`）：
//!
//! 1. 解析 4 字段规则（`uploadUrl` / `downloadUrlRule` / `summary` / `compress`，
//!    字段集按参考版）；
//! 2. 读取文件载荷（`content` 文本或 `filePath` 本地文件，**二选一**；单文件
//!    上限 [`MAX_UPLOAD_BYTES`]）；
//! 3. 无 quickjs 构建且下载规则含 `@js:` / `<js>` → 明确错误（**上传前拦截**，
//!    避免白传一次后才发现无法求值）；
//! 4. 调用 `legado-net::direct_link_upload::upload`（压缩 + multipart 构造 +
//!    网络上传；复用进程共享 `LegadoClient` 的默认头/UA/Cookie/代理/限流/重试/
//!    HTTP 日志采集）；
//! 5. 以**响应体 + 响应最终 URL** 构造 `AnalyzeRule` 求值 `downloadUrlRule`
//!    （JSONPath / 正则 / `@js:` 级联；对齐原版 `AnalyzeRule().setContent(res.body,
//!    res.url)`），空结果 → 「上传失败,{响应体}」。
//!
//! 错误语义见契约 §2.51：上传/下载规则未配置、规则求值为空、JS 能力缺失、
//! 载荷二选一违规、文件超限、文件读取失败、网络错误均**上抛不降级**——上传是
//! 显式用户动作，错误必须驱动 UI 提示（区别于弹幕/图片缓存的降级风格）。

use std::path::Path;

use legado_core::{LegadoError, LegadoResult};
use legado_net::direct_link_upload::{self, UploadRule};

/// 单文件上传上限（100 MiB；文件由 Dart 传路径、Rust 读盘，字节不穿 FFI）
pub const MAX_UPLOAD_BYTES: u64 = 100 * 1024 * 1024;

/// 无 quickjs 构建对 JS 下载规则的明确错误文案（契约 §2.51）
pub const JS_UNSUPPORTED_ERROR: &str = "当前构建不支持 JS 下载规则";

/// 直链上传：返回下载直链 URL（契约 §2.51 `directLinkUpload`）
///
/// - `rule_json`：规则 JSON（camelCase，兼容 snake_case）；
/// - `file_name` / `content_type`：上传文件名与 MIME 类型；
/// - `content` / `file_path`：**二选一**（文本内容 / 本地文件绝对路径）。
pub fn direct_link_upload(
    rule_json: &str,
    file_name: &str,
    content_type: &str,
    content: Option<String>,
    file_path: Option<String>,
) -> LegadoResult<String> {
    let rule = UploadRule::from_json(rule_json)?;
    // 规则必填校验前置：配置错误不进入读盘/网络阶段
    direct_link_upload::validate_rule(&rule)?;

    // 无 quickjs 构建：含 JS 的下载规则**上传前**明确报错（不静默降级为空结果）
    #[cfg(not(feature = "quickjs"))]
    if rule_requires_js(&rule.download_url_rule) {
        return Err(LegadoError::Ffi(JS_UNSUPPORTED_ERROR.to_string()));
    }

    let payload = load_payload(content, file_path)?;
    let client = crate::http_state::shared_client()?;
    let outcome = crate::runtime::block_on(direct_link_upload::upload(
        &client,
        &rule,
        file_name,
        content_type,
        &payload,
    ))?;

    let download_url = evaluate_download_url(&rule.download_url_rule, &outcome.body, &outcome.url)?;
    if download_url.trim().is_empty() {
        // 对齐原版 `upLoad:67-69`：规则无结果即视为上传失败，附响应体便于排查
        return Err(LegadoError::Ffi(format!("上传失败,{}", outcome.body)));
    }
    Ok(download_url)
}

/// 读取上传载荷（`content` 与 `filePath` 二选一）
pub fn load_payload(content: Option<String>, file_path: Option<String>) -> LegadoResult<Vec<u8>> {
    match (content, file_path) {
        (Some(_), Some(_)) => Err(LegadoError::Ffi(
            "content 与 filePath 只能二选一".to_string(),
        )),
        (None, None) => Err(LegadoError::Ffi(
            "content 与 filePath 必须提供其一".to_string(),
        )),
        (Some(text), None) => Ok(text.into_bytes()),
        (None, Some(path)) => read_upload_file(&path, MAX_UPLOAD_BYTES),
    }
}

/// 读取本地文件并做单文件上限校验（超限明确报错，不截断）
pub fn read_upload_file(path: &str, max_bytes: u64) -> LegadoResult<Vec<u8>> {
    let path = path.trim();
    if path.is_empty() {
        return Err(LegadoError::Ffi("上传文件路径为空".to_string()));
    }
    let meta = std::fs::metadata(Path::new(path))
        .map_err(|e| LegadoError::Ffi(format!("读取上传文件失败: {e}")))?;
    if !meta.is_file() {
        return Err(LegadoError::Ffi(format!("上传路径不是文件: {path}")));
    }
    if meta.len() > max_bytes {
        return Err(LegadoError::Ffi(format!(
            "文件超过上传上限（{}）: {} 字节",
            human_size(max_bytes),
            meta.len()
        )));
    }
    std::fs::read(path).map_err(|e| LegadoError::Ffi(format!("读取上传文件失败: {e}")))
}

/// 上限的可读单位（整 MiB 用 MiB，否则用字节——测试以小数上限驱动）
fn human_size(bytes: u64) -> String {
    const MIB: u64 = 1024 * 1024;
    if bytes >= MIB && bytes.is_multiple_of(MIB) {
        format!("{} MiB", bytes / MIB)
    } else {
        format!("{bytes} 字节")
    }
}

/// 下载规则是否依赖 JS（`@js:` 链或 `<js>` 块；无 quickjs 构建据此明确报错）
#[cfg(not(feature = "quickjs"))]
fn rule_requires_js(rule: &str) -> bool {
    rule.contains("@js:") || rule.contains("<js>")
}

/// 求值下载链接规则（`AnalyzeRule` 自动路由 JSONPath / 正则 / `@js:` 级联）
fn evaluate_download_url(rule: &str, body: &str, url: &str) -> LegadoResult<String> {
    let analyzer = build_analyzer(body, url);
    analyzer
        .get_string(rule)
        .map_err(|e| LegadoError::Ffi(format!("下载链接规则求值失败: {e}")))
}

/// quickjs 构建：注入 QuickJS 执行器（`@js:` 规则以 `result` / `baseUrl` 绑定求值）
#[cfg(feature = "quickjs")]
fn build_analyzer(content: &str, base_url: &str) -> legado_parser::AnalyzeRule {
    legado_parser::AnalyzeRule::with_js_executor(
        content.to_string(),
        base_url.to_string(),
        std::sync::Arc::new(crate::js_executor::QuickJsExecutor::new(
            "direct_link_upload",
        )),
    )
}

/// 非 quickjs 构建：不注入执行器（JS 规则已在入口前置拒绝）
#[cfg(not(feature = "quickjs"))]
fn build_analyzer(content: &str, base_url: &str) -> legado_parser::AnalyzeRule {
    legado_parser::AnalyzeRule::new(content.to_string(), base_url.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::sync::mpsc;

    /// 回环 mock 上传服务：读取完整请求（头 + Content-Length body）后回固定响应
    ///
    /// 返回 `(url, 请求体接收端)`；请求体在测试断言时从 channel 取回。
    fn spawn_upload_server(
        response_body: &'static str,
    ) -> (String, mpsc::Receiver<(String, Vec<u8>)>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let (mut sock, _) = listener.accept().expect("accept");
            sock.set_read_timeout(Some(std::time::Duration::from_secs(10)))
                .ok();
            let mut raw = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end = loop {
                let n = sock.read(&mut buf).expect("read head");
                assert!(n > 0, "请求头未完成即断开");
                raw.extend_from_slice(&buf[..n]);
                if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                    break pos + 4;
                }
            };
            let head = String::from_utf8_lossy(&raw[..header_end]).to_string();
            let content_length = head
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.trim()
                        .eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())?
                })
                .unwrap_or(0);
            while raw.len() < header_end + content_length {
                let n = sock.read(&mut buf).expect("read body");
                assert!(n > 0, "请求体未完成即断开");
                raw.extend_from_slice(&buf[..n]);
            }
            let body = raw[header_end..header_end + content_length].to_vec();
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            sock.write_all(resp.as_bytes()).expect("write resp");
            let _ = tx.send((head, body));
        });
        (format!("http://{addr}/upload"), rx)
    }

    fn rule_json(upload_url: &str, download_rule: &str, compress: bool) -> String {
        serde_json::json!({
            "uploadUrl": upload_url,
            "downloadUrlRule": download_rule,
            "summary": "测试规则",
            "compress": compress
        })
        .to_string()
    }

    #[test]
    fn test_jsonpath_download_rule() {
        let (url, rx) =
            spawn_upload_server(r#"{"code":0,"data":{"url":"https://dl.example/f/1"}}"#);
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "$.data.url",
            false,
        );
        let result = direct_link_upload(
            &rule,
            "sources.json",
            "application/json",
            Some("[]".to_string()),
            None,
        )
        .expect("上传与 JSONPath 求值应成功");
        assert_eq!(result, "https://dl.example/f/1");

        let (head, body) = rx.recv().expect("应收到请求");
        assert!(head.starts_with("POST /upload"), "{head}");
        let text = String::from_utf8(body).expect("multipart 体应为文本");
        assert!(
            text.contains("filename=\"sources.json\"") && text.contains("[]"),
            "{text}"
        );
    }

    #[test]
    fn test_regex_download_rule() {
        let (url, _rx) =
            spawn_upload_server("上传成功，下载链接: https://dl.example.com/file/xyz 谢谢");
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            r"(https://dl\.example\.com/\S+)",
            false,
        );
        let result = direct_link_upload(&rule, "a.txt", "text/plain", Some("hi".into()), None)
            .expect("正则规则应求值成功");
        assert_eq!(result, "https://dl.example.com/file/xyz");
    }

    #[test]
    fn test_empty_result_reports_upload_failed_with_body() {
        let body = r#"{"code":1,"msg":"no link"}"#;
        let (url, _rx) = spawn_upload_server(body);
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "$.data.url",
            false,
        );
        let err =
            direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None).unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("上传失败"), "{msg}");
        assert!(msg.contains(body), "错误应附响应体: {msg}");
    }

    #[test]
    fn test_blank_rule_errors_before_network() {
        // 上传 URL 未配置（规则可解析但 url 为空）
        let rule = rule_json("", "$.url", false);
        let err =
            direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None).unwrap_err();
        assert!(err.to_string().contains("上传 URL 未配置"), "{err}");

        // 下载链接规则未配置
        let rule = rule_json(
            r#"http://127.0.0.1:9/upload,{"body":{"file":"fileRequest"}}"#,
            "",
            false,
        );
        let err =
            direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None).unwrap_err();
        assert!(err.to_string().contains("下载链接规则未配置"), "{err}");
    }

    #[test]
    fn test_payload_requires_exactly_one() {
        let rule = rule_json("http://127.0.0.1:9/upload", "$.url", false);
        let err = direct_link_upload(&rule, "a.txt", "text/plain", None, None).unwrap_err();
        assert!(err.to_string().contains("必须提供其一"), "{err}");

        let err = direct_link_upload(
            &rule,
            "a.txt",
            "text/plain",
            Some("x".into()),
            Some("C:/tmp/x.txt".into()),
        )
        .unwrap_err();
        assert!(err.to_string().contains("只能二选一"), "{err}");
    }

    #[test]
    fn test_file_path_payload_and_size_limit() {
        let path = std::env::temp_dir().join(format!(
            "legado_dlu_payload_{}_{}.json",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, b"0123456789").expect("写临时文件");
        let path_str = path.to_string_lossy().to_string();

        // 正常读取
        let data = read_upload_file(&path_str, 100).expect("读取应成功");
        assert_eq!(data, b"0123456789");

        // 超限：明确错误且不截断
        let err = read_upload_file(&path_str, 4).unwrap_err();
        assert!(err.to_string().contains("文件超过上传上限"), "{err}");

        // 不存在
        let err = read_upload_file(&format!("{path_str}.missing"), MAX_UPLOAD_BYTES).unwrap_err();
        assert!(err.to_string().contains("读取上传文件失败"), "{err}");

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_file_path_upload_flow() {
        let path = std::env::temp_dir().join(format!(
            "legado_dlu_upload_{}_{}.txt",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::write(&path, "file-payload").expect("写临时文件");
        let (url, rx) = spawn_upload_server(r#"{"url":"https://dl.example/f/file"}"#);
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "$.url",
            false,
        );
        let result = direct_link_upload(
            &rule,
            "note.txt",
            "text/plain",
            None,
            Some(path.to_string_lossy().to_string()),
        )
        .expect("filePath 上传应成功");
        assert_eq!(result, "https://dl.example/f/file");
        let (_, body) = rx.recv().expect("应收到请求");
        let text = String::from_utf8(body).unwrap();
        assert!(text.contains("filename=\"note.txt\""), "{text}");
        assert!(text.contains("file-payload"), "{text}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn test_compress_upload_requests_zip() {
        let (url, rx) = spawn_upload_server(r#"{"url":"https://dl.example/f/zip"}"#);
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "$.url",
            true,
        );
        let result = direct_link_upload(
            &rule,
            "rules.json",
            "application/json",
            Some("[1,2,3]".to_string()),
            None,
        )
        .expect("压缩上传应成功");
        assert_eq!(result, "https://dl.example/f/zip");
        let (_, body) = rx.recv().expect("应收到请求");
        let text = String::from_utf8_lossy(&body);
        assert!(text.contains("filename=\"rules.json.zip\""), "{text}");
        assert!(text.contains("Content-Type: application/zip"), "{text}");
    }

    #[test]
    fn test_network_error_upload() {
        // 绑定后立即释放，得到确定不可连接的端口
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let rule = rule_json(
            &format!("http://{addr}/upload,{{\"body\":{{\"file\":\"fileRequest\"}}}}"),
            "$.url",
            false,
        );
        let err =
            direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None).unwrap_err();
        assert!(
            matches!(err, LegadoError::Network(_)),
            "网络错误应为 Network 变体: {err}"
        );
    }

    /// 无 quickjs 构建：JS 下载规则**上传前**明确报错（不发起网络请求）
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn test_js_rule_rejected_without_quickjs() {
        let rule = rule_json(
            r#"http://127.0.0.1:9/upload,{"body":{"file":"fileRequest"}}"#,
            "$.data@js:'https://dl/' + result",
            false,
        );
        let err =
            direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None).unwrap_err();
        assert!(
            err.to_string().contains(JS_UNSUPPORTED_ERROR),
            "应明确提示 JS 能力缺失: {err}"
        );
    }

    /// quickjs 构建：默认规则同形 `$.data@js:` 级联真实执行
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_download_rule_with_quickjs() {
        let (url, _rx) = spawn_upload_server(r#"{"data":"abc123"}"#);
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "$.data@js:if (result == '') \n '' \n else \n 'https://shuyuan.example/' + result",
            false,
        );
        let result = direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None)
            .expect("@js 下载规则应执行成功");
        assert_eq!(result, "https://shuyuan.example/abc123");
    }

    /// quickjs 构建：`@js:` 规则中的 `baseUrl` 绑定响应最终 URL（对齐原版 setContent(body, url)）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_download_rule_base_url_binding() {
        let (url, _rx) = spawn_upload_server(r#"{"ok":1}"#);
        let rule = rule_json(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "@js:baseUrl",
            false,
        );
        let result = direct_link_upload(&rule, "a.txt", "text/plain", Some("x".into()), None)
            .expect("baseUrl 应可读取");
        assert!(result.ends_with("/upload"), "{result}");
    }
}
