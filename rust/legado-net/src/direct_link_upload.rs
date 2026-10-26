//! 直链上传（契约 §2.51，批16a 重写）
//!
//! 对齐原版 `help/DirectLinkUpload.kt:26-71`（`upLoad`）+ `model/analyzeRule/
//! AnalyzeUrl.kt:714-729`（`upload` 选项消费）+ `help/http/OkHttpUtils.kt:157-191`
//! （`postMultipart`）：
//!
//! 1. 规则对象 `UploadRule` **4 字段**（`uploadUrl` / `downloadUrlRule` /
//!    `summary` / `compress`）——**字段集按参考版**（`legado-with-MD3` 已删除
//!    口令与 `expiryDate`，用户裁决 2026-10-27）；序列化 camelCase，读取兼容
//!    snake_case alias 与未知键（原版 5 字段 JSON 可直接导入）。
//! 2. `uploadUrl` 支持逗号选项 `<url>,{"method":…,"headers":…,"body":…,"type":…}`
//!    （切分等价原版正则 `\s*,\s*(?=\{)`）。**上传链恒以 POST multipart 发送**
//!    ——原版 `AnalyzeUrl.upload` 固定 `postMultipart`，`method` 选项仅解析保留。
//! 3. `body` 中值为字符串 `"fileRequest"` 的键 → 文件部件（`fileName` /
//!    `contentType`），其余键 → 普通文本 form 字段（值字符串化，对齐
//!    `value.toString()`）。
//! 4. `compress=true` 且 `contentType != "application/zip"` → 内存打 zip
//!    （单条目名 = 原文件名、`Deflated`），上传文件名改为 `<fileName>.zip`、
//!    类型改为 `application/zip`（对齐 `ZipUtils.zipByteArray` + `upLoad:43-58`）。
//! 5. 网络出口走 [`LegadoClient::post_multipart`]（默认头 / UA / DB Cookie /
//!    代理 / 限流 / 重试 / HTTP 日志采集与其余统一出口一致）。
//!
//! **下载链接规则不在本模块求值**：原版用 `AnalyzeRule().setContent(res.body,
//! res.url)` 求值 `downloadUrlRule`（JSONPath / 正则 / `@js:` 级联），该能力
//! 属 `legado-parser`，由 FFI 层（`legado-ffi/src/api/direct_link_upload_api.rs`）
//! 消费本模块返回的 [`UploadOutcome`] 后求值——本模块只负责「上传」。
//!
//! 历史说明：此前自创的 `extract_download_url` / `DirectLinkUploader` 已删除
//! （原版无此函数，且只支持简单 JSONPath/正则，语义与规则引擎不一致）。

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use legado_core::{LegadoError, LegadoResult};

use crate::client::{LegadoClient, MultipartPart};

/// `body` 中的文件字段标记（对齐原版 `"fileRequest"` 字面量）
pub const FILE_REQUEST_MARKER: &str = "fileRequest";
/// 压缩产物的 MIME 类型（对齐原版 `application/zip`）
pub const ZIP_CONTENT_TYPE: &str = "application/zip";

/// 上传规则（对应参考版 `DirectLinkUpload.Rule`，4 字段）
///
/// 序列化为 camelCase（与上游/参考版 JSON 一致）；反序列化兼容 snake_case
/// 旧键（本仓历史规则配置）。`summary` / `compress` 缺省容错，`uploadUrl` 与
/// `downloadUrlRule` 必填（缺失即解析错误，对齐原版 data class 无默认值的两字段）。
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UploadRule {
    /// 上传接口 URL（可携带逗号选项，见 [`parse_upload_url`]）
    #[serde(alias = "upload_url")]
    pub upload_url: String,
    /// 下载链接规则（JSONPath / 正则 / `@js:` 级联，FFI 层求值）
    #[serde(alias = "download_url_rule")]
    pub download_url_rule: String,
    /// 注释/摘要（选择器展示用）
    #[serde(default)]
    pub summary: String,
    /// 是否压缩后上传（`contentType == application/zip` 时跳过）
    #[serde(default)]
    pub compress: bool,
}

impl std::fmt::Display for UploadRule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.summary)
    }
}

impl UploadRule {
    /// 从 JSON 文本解析规则（未知键忽略，snake_case 兼容）
    pub fn from_json(json: &str) -> LegadoResult<Self> {
        serde_json::from_str(json)
            .map_err(|e| LegadoError::Ffi(format!("直链上传规则解析失败: {e}")))
    }
}

/// `uploadUrl` 逗号后的选项（对齐上游 `UrlOption` 的上传子集）
///
/// 只声明上传链消费的四个键；其余键（charset/retry/js 等）按 serde 默认
/// 忽略未知字段语义丢弃——上传链不消费它们（原版 `upload` 同样只读
/// `type`/`body`，method 由 `postMultipart` 覆盖为 POST）。
#[derive(Debug, Clone, Default, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct UploadOptions {
    /// HTTP 方法（仅解析保留；上传链恒 POST，对齐原版）
    #[serde(default)]
    pub method: Option<String>,
    /// 额外请求头（值字符串化）
    #[serde(default)]
    pub headers: Option<HashMap<String, serde_json::Value>>,
    /// 表单字段表（值为 `"fileRequest"` 的键替换为文件部件）
    #[serde(default)]
    pub body: Option<HashMap<String, serde_json::Value>>,
    /// multipart 整体 Content-Type（原版 `MultipartBody.Builder.setType`）
    #[serde(rename = "type", default)]
    pub content_type: Option<String>,
}

/// 解析后的上传请求（URL + 选项 + 已构造的 multipart 部件）
#[derive(Debug, Clone)]
pub struct UploadRequest {
    /// 去选项后的上传 URL
    pub url: String,
    /// method 选项原文（仅留档/日志，不改派发）
    pub method: Option<String>,
    /// 额外请求头（已字符串化）
    pub headers: Option<HashMap<String, String>>,
    /// multipart 整体 Content-Type（None/`multipart/form-data` 时由实现补 boundary）
    pub media_type: Option<String>,
    /// multipart 部件（文本 + 文件）
    pub parts: Vec<MultipartPart>,
}

/// 上传结果（供 FFI 层以 `AnalyzeRule` 求值 `downloadUrlRule`）
#[derive(Debug, Clone)]
pub struct UploadOutcome {
    /// HTTP 状态码
    pub status: u16,
    /// 响应最终 URL（重定向后，绑定 `AnalyzeRule.baseUrl`）
    pub url: String,
    /// 响应体文本（绑定 `AnalyzeRule.content`）
    pub body: String,
}

/// 解析 `uploadUrl` 的逗号选项（等价原版 `\s*,\s*(?=\{)` 切分）
///
/// 返回 `(url, options)`；无选项时 `options` 为默认值。选项 JSON 形态非法 →
/// 明确错误（不静默按无选项处理：否则 `body` 缺失会在上传时以更晦涩的方式失败）。
pub fn parse_upload_url(raw: &str) -> LegadoResult<(String, UploadOptions)> {
    let mut split: Option<usize> = None;
    for (idx, ch) in raw.char_indices() {
        if ch == ',' {
            let rest = raw[idx + 1..].trim_start();
            if rest.starts_with('{') {
                split = Some(idx);
                break;
            }
        }
    }
    let Some(idx) = split else {
        return Ok((raw.trim().to_string(), UploadOptions::default()));
    };
    let url = raw[..idx].trim_end().to_string();
    let option_json = raw[idx + 1..].trim();
    let options: UploadOptions = serde_json::from_str(option_json)
        .map_err(|e| LegadoError::Ffi(format!("上传 URL 选项解析失败: {e}")))?;
    Ok((url, options))
}

/// `serde_json::Value` → 表单字段字符串（对齐 Kotlin `value.toString()`）
///
/// 字符串取原文；数字/布尔/对象/数组取 JSON 紧凑串（如 `1`、`{"a":1}`）；
/// `null` 取 `"null"`（Gson `toString()` 同形）。
fn field_string(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// 选项 headers 字符串化（键原样，值按 [`field_string`]）
fn normalize_headers(
    headers: Option<HashMap<String, serde_json::Value>>,
) -> Option<HashMap<String, String>> {
    let headers = headers?;
    if headers.is_empty() {
        return None;
    }
    Some(
        headers
            .into_iter()
            .map(|(k, v)| (k, field_string(&v)))
            .collect(),
    )
}

/// 内存 zip 压缩单个条目（对齐 `ZipUtils.zipByteArray`：条目名 = 原文件名）
fn zip_single_entry(entry_name: &str, data: &[u8]) -> LegadoResult<Vec<u8>> {
    use std::io::{Cursor, Write};

    let mut writer = zip::ZipWriter::new(Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated);
    writer
        .start_file(entry_name, options)
        .map_err(|e| LegadoError::Ffi(format!("上传前压缩失败: {e}")))?;
    writer
        .write_all(data)
        .map_err(|e| LegadoError::Ffi(format!("上传前压缩失败: {e}")))?;
    let cursor = writer
        .finish()
        .map_err(|e| LegadoError::Ffi(format!("上传前压缩失败: {e}")))?;
    Ok(cursor.into_inner())
}

impl UploadRequest {
    /// 按规则 + 文件载荷构造 multipart 上传请求
    ///
    /// `file_name` / `content_type` 在 `compress` 生效时会被改写
    /// （`<fileName>.zip` / `application/zip`）。
    pub fn build(
        rule: &UploadRule,
        file_name: &str,
        content_type: &str,
        data: Vec<u8>,
    ) -> LegadoResult<Self> {
        validate_rule(rule)?;
        let (url, options) = parse_upload_url(&rule.upload_url)?;
        if url.is_empty() {
            return Err(LegadoError::Ffi("上传 URL 未配置".to_string()));
        }

        // 压缩（对齐原版 upLoad:43-58：仅非 zip 类型且 compress=true）
        let mut upload_name = file_name.to_string();
        let mut upload_type = content_type.to_string();
        // P1-2：直接接管调用方 Vec 所有权（不再 `to_vec()` 复制整包载荷）
        let mut payload = data;
        if rule.compress && content_type != ZIP_CONTENT_TYPE {
            upload_name = format!("{file_name}.zip");
            upload_type = ZIP_CONTENT_TYPE.to_string();
            payload = zip_single_entry(file_name, &payload)?;
        }

        let body = options.body.ok_or_else(|| {
            LegadoError::Ffi("上传 URL 选项缺少 body（无法定位 fileRequest 文件字段）".to_string())
        })?;
        if body.is_empty() {
            return Err(LegadoError::Ffi(
                "上传 URL 选项 body 为空（无法定位 fileRequest 文件字段）".to_string(),
            ));
        }

        // P1-2：整包转 `Bytes`，多个 fileRequest 部件共享同一缓冲（clone 仅
        // 增引用计数），不再逐部件 `payload.clone()` 全量复制。
        let payload = bytes::Bytes::from(payload);
        let mut parts = Vec::with_capacity(body.len());
        // 先按值是否为 fileRequest 分派（同一文件可占据多个标记键，对齐原版 forEach）
        let mut part_pairs: Vec<(String, MultipartPart)> = Vec::with_capacity(body.len());
        for (name, value) in body.iter() {
            if value.as_str() == Some(FILE_REQUEST_MARKER) {
                part_pairs.push((
                    name.clone(),
                    MultipartPart::File {
                        name: name.clone(),
                        file_name: upload_name.clone(),
                        content_type: Some(upload_type.clone()),
                        data: payload.clone(),
                    },
                ));
            } else {
                part_pairs.push((
                    name.clone(),
                    MultipartPart::Text {
                        name: name.clone(),
                        value: field_string(value),
                    },
                ));
            }
        }
        // HashMap 迭代顺序不稳定：按字段名排序保证请求体稳定（便于测试与排障；
        // multipart 字段顺序在语义上不敏感，原版 GSON LinkedTreeMap 为声明序）
        part_pairs.sort_by(|a, b| a.0.cmp(&b.0));
        parts.extend(part_pairs.into_iter().map(|(_, part)| part));

        if let Some(method) = options.method.as_deref() {
            if !method.trim().eq_ignore_ascii_case("POST") {
                log::debug!(
                    "直链上传 method 选项为 {method}，对齐原版 AnalyzeUrl.upload 仍以 POST multipart 发送"
                );
            }
        }

        Ok(Self {
            url,
            method: options.method,
            headers: normalize_headers(options.headers),
            media_type: options.content_type,
            parts,
        })
    }
}

/// 校验规则必填字段（对齐原版 `upLoad` 前置两处 blank 检查）
pub fn validate_rule(rule: &UploadRule) -> LegadoResult<()> {
    if rule.upload_url.trim().is_empty() {
        return Err(LegadoError::Ffi("上传 URL 未配置".to_string()));
    }
    if rule.download_url_rule.trim().is_empty() {
        return Err(LegadoError::Ffi("下载链接规则未配置".to_string()));
    }
    Ok(())
}

/// 执行直链上传（不负责下载链接规则求值）
///
/// - `rule`：4 字段规则（`uploadUrl` 中的选项在此解析）；
/// - `file_name` / `content_type` / `data`：待上传文件载荷（压缩开关见规则；
///   `data` 按所有权移交，避免整包复制——见 P1-2）；
/// - 返回响应状态/最终 URL/响应体，供上层 `AnalyzeRule` 求值下载链接。
///
/// 网络错误经 [`LegadoError::Network`] 上抛（不降级、不重试二次封装——重试
/// 由客户端配置决定，与其余统一出口一致）。
pub async fn upload(
    client: &LegadoClient,
    rule: &UploadRule,
    file_name: &str,
    content_type: &str,
    data: Vec<u8>,
) -> LegadoResult<UploadOutcome> {
    let request = UploadRequest::build(rule, file_name, content_type, data)?;
    let response = client
        .post_multipart(
            &request.url,
            &request.parts,
            request.media_type.as_deref(),
            request.headers,
        )
        .await?;
    Ok(UploadOutcome {
        status: response.status,
        url: response.url,
        body: response.body,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule_with(upload_url: &str, download_rule: &str) -> UploadRule {
        UploadRule {
            upload_url: upload_url.to_string(),
            download_url_rule: download_rule.to_string(),
            summary: "测试规则".to_string(),
            compress: false,
        }
    }

    #[test]
    fn test_rule_camel_case_and_snake_case() {
        let camel = r#"{
            "uploadUrl": "https://u.example.com/up",
            "downloadUrlRule": "$.data.url",
            "summary": "喵公子网盘①",
            "compress": true,
            "expiryDate": 30
        }"#;
        let rule = UploadRule::from_json(camel).expect("camelCase 规则应解析成功");
        assert_eq!(rule.upload_url, "https://u.example.com/up");
        assert_eq!(rule.download_url_rule, "$.data.url");
        assert_eq!(rule.summary, "喵公子网盘①");
        assert!(rule.compress);
        // 未知键 expiryDate 被忽略（参考版已删该字段）
        assert_eq!(serde_json::to_value(&rule).unwrap().get("expiryDate"), None);

        let snake = r#"{
            "upload_url": "https://u.example.com/up2",
            "download_url_rule": "$.msg",
            "summary": "旧配置",
            "compress": false
        }"#;
        let rule = UploadRule::from_json(snake).expect("snake_case 规则应解析成功");
        assert_eq!(rule.upload_url, "https://u.example.com/up2");
        assert_eq!(rule.download_url_rule, "$.msg");

        // 序列化输出 camelCase（写回配置与参考版同形）
        let json = serde_json::to_value(&rule).unwrap();
        assert_eq!(json["uploadUrl"], "https://u.example.com/up2");
        assert_eq!(json["downloadUrlRule"], "$.msg");
    }

    #[test]
    fn test_parse_upload_url_with_options() {
        let raw = "https://sy.mgz6.com/shuyuan, {\"method\":\"POST\",\"headers\":{\"X-Token\":\"t1\",\"N\":5},\"body\":{\"file\":\"fileRequest\",\"name\":\"abc\"},\"type\":\"multipart/form-data\"}";
        let (url, options) = parse_upload_url(raw).unwrap();
        assert_eq!(url, "https://sy.mgz6.com/shuyuan");
        assert_eq!(options.method.as_deref(), Some("POST"));
        assert_eq!(options.content_type.as_deref(), Some("multipart/form-data"));
        let headers = options.headers.unwrap();
        assert_eq!(headers.get("X-Token").and_then(|v| v.as_str()), Some("t1"));
        assert_eq!(headers.get("N").map(field_string), Some("5".to_string()));
        assert_eq!(
            options
                .body
                .as_ref()
                .unwrap()
                .get("file")
                .and_then(|v| v.as_str()),
            Some(FILE_REQUEST_MARKER)
        );
    }

    #[test]
    fn test_parse_upload_url_without_options() {
        let (url, options) = parse_upload_url("https://example.com/upload").unwrap();
        assert_eq!(url, "https://example.com/upload");
        assert!(options.body.is_none());
        assert!(options.headers.is_none());
    }

    #[test]
    fn test_parse_upload_url_invalid_options() {
        let err = parse_upload_url("https://example.com/up, {oops}").unwrap_err();
        assert!(err.to_string().contains("上传 URL 选项解析失败"), "{err}");
    }

    #[test]
    fn test_validate_rule_errors() {
        let mut rule = rule_with("", "$.x");
        let err = validate_rule(&rule).unwrap_err();
        assert!(err.to_string().contains("上传 URL 未配置"), "{err}");

        rule = rule_with("https://example.com/up", "");
        let err = validate_rule(&rule).unwrap_err();
        assert!(err.to_string().contains("下载链接规则未配置"), "{err}");
    }

    #[test]
    fn test_build_parts_file_request_and_text_fields() {
        let rule = rule_with(
            r#"https://example.com/up,{"body":{"file":"fileRequest","name":"测试","n":5},"type":"multipart/form-data"}"#,
            "$.url",
        );
        let request = UploadRequest::build(
            &rule,
            "book.json",
            "application/json",
            b"{\"a\":1}".to_vec(),
        )
        .expect("构造应成功");
        assert_eq!(request.parts.len(), 3);
        // 文本字段（按字段名排序：file < n < name → File/Text/Text）
        match &request.parts[0] {
            MultipartPart::File {
                name,
                file_name,
                content_type,
                data,
            } => {
                assert_eq!(name, "file");
                assert_eq!(file_name, "book.json");
                assert_eq!(content_type.as_deref(), Some("application/json"));
                assert_eq!(data.as_ref(), b"{\"a\":1}");
            }
            other => panic!("首个部件应为文件部件: {other:?}"),
        }
        assert_eq!(
            request.parts[1],
            MultipartPart::Text {
                name: "n".into(),
                value: "5".into()
            }
        );
        assert_eq!(
            request.parts[2],
            MultipartPart::Text {
                name: "name".into(),
                value: "测试".into()
            }
        );
    }

    #[test]
    fn test_build_parts_missing_body_errors() {
        let rule = rule_with("https://example.com/up", "$.url");
        let err = UploadRequest::build(&rule, "a.txt", "text/plain", b"x".to_vec()).unwrap_err();
        assert!(err.to_string().contains("缺少 body"), "{err}");
    }

    #[test]
    fn test_compress_produces_zip_and_renames() {
        let mut rule = rule_with(
            "https://example.com/up,{\"body\":{\"file\":\"fileRequest\"}}",
            "$.url",
        );
        rule.compress = true;
        let payload = "直链上传测试内容".as_bytes().to_vec();
        let expected = payload.clone();
        let request = UploadRequest::build(&rule, "source.json", "application/json", payload)
            .expect("压缩构造应成功");
        match &request.parts[0] {
            MultipartPart::File {
                file_name,
                content_type,
                data,
                ..
            } => {
                assert_eq!(file_name, "source.json.zip");
                assert_eq!(content_type.as_deref(), Some(ZIP_CONTENT_TYPE));
                // 解压校验：条目名 = 原文件名，内容一致
                let mut archive =
                    zip::ZipArchive::new(std::io::Cursor::new(data.clone())).expect("zip 应可读");
                assert_eq!(archive.len(), 1);
                let mut entry = archive.by_index(0).unwrap();
                assert_eq!(entry.name(), "source.json");
                let mut out = Vec::new();
                std::io::Read::read_to_end(&mut entry, &mut out).unwrap();
                assert_eq!(out, expected);
            }
            other => panic!("应为文件部件: {other:?}"),
        }
    }

    #[test]
    fn test_compress_skipped_when_already_zip() {
        let mut rule = rule_with(
            "https://example.com/up,{\"body\":{\"file\":\"fileRequest\"}}",
            "$.url",
        );
        rule.compress = true;
        let request =
            UploadRequest::build(&rule, "pack.zip", ZIP_CONTENT_TYPE, b"PK\x03\x04".to_vec())
                .expect("构造应成功");
        match &request.parts[0] {
            MultipartPart::File {
                file_name,
                content_type,
                data,
                ..
            } => {
                assert_eq!(file_name, "pack.zip");
                assert_eq!(content_type.as_deref(), Some(ZIP_CONTENT_TYPE));
                assert_eq!(data.as_ref(), b"PK\x03\x04", "已是 zip 不应二次压缩");
            }
            other => panic!("应为文件部件: {other:?}"),
        }
    }

    #[test]
    fn test_build_multipart_body_format() {
        let parts = vec![
            MultipartPart::Text {
                name: "name".into(),
                value: "a\"b".into(),
            },
            MultipartPart::File {
                name: "file".into(),
                file_name: "book.json".into(),
                content_type: Some("application/json".into()),
                data: b"{\"x\":1}".to_vec().into(),
            },
        ];
        let (body, content_type) =
            crate::client::build_multipart_body(&parts, Some("multipart/form-data"), "BOUND")
                .expect("合法部件应构造成功");
        let text = String::from_utf8(body).unwrap();
        assert_eq!(content_type, "multipart/form-data; boundary=BOUND");
        assert!(text.contains("--BOUND\r\n"));
        // 引号转义对齐 OkHttp（仅 name/filename 转义，字段值原样）
        assert!(text.contains("name=\"name\"\r\n\r\n"), "{text}");
        assert!(text.contains("a\"b"), "字段值不应被转义: {text}");
        assert!(text.contains("filename=\"book.json\""), "{text}");
        assert!(text.contains("Content-Type: application/json"), "{text}");
        assert!(text.ends_with("--BOUND--\r\n"), "{text}");
    }

    /// P2-10：部件 Content-Type 含 CR/LF（头注入）必须拒绝，整体 type 同样
    #[test]
    fn test_build_multipart_body_rejects_header_injection() {
        let parts = vec![MultipartPart::File {
            name: "file".into(),
            file_name: "a.txt".into(),
            content_type: Some("text/plain\r\nX-Evil: 1".into()),
            data: bytes::Bytes::from_static(b"x"),
        }];
        let err = crate::client::build_multipart_body(&parts, None, "B").unwrap_err();
        assert!(
            err.to_string().contains("multipart Content-Type 非法"),
            "{err}"
        );

        let err =
            crate::client::build_multipart_body(&[], Some("multipart/form-data\nX-Evil: 1"), "B")
                .unwrap_err();
        assert!(
            err.to_string().contains("multipart Content-Type 非法"),
            "{err}"
        );

        // 空部件 Content-Type 回退 octet-stream（不报错）
        let parts = vec![MultipartPart::File {
            name: "file".into(),
            file_name: "a.txt".into(),
            content_type: Some("   ".into()),
            data: bytes::Bytes::from_static(b"x"),
        }];
        let (body, _) = crate::client::build_multipart_body(&parts, None, "B").unwrap();
        assert!(String::from_utf8_lossy(&body).contains("Content-Type: application/octet-stream"));
    }

    /// 回环 mock HTTP 服务器：读取完整请求（头 + Content-Length body）后回固定 JSON
    async fn spawn_mock_upload_server(
        response_body: &'static str,
    ) -> (String, tokio::task::JoinHandle<(String, Vec<u8>)>) {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let handle = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.expect("accept");
            let mut raw = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end;
            loop {
                let n = sock.read(&mut buf).await.expect("read head");
                assert!(n > 0, "连接在请求头完成前关闭");
                raw.extend_from_slice(&buf[..n]);
                if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                    header_end = pos + 4;
                    break;
                }
            }
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
                let n = sock.read(&mut buf).await.expect("read body");
                assert!(n > 0, "连接在请求体完成前关闭");
                raw.extend_from_slice(&buf[..n]);
            }
            let body = raw[header_end..header_end + content_length].to_vec();
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            sock.write_all(resp.as_bytes()).await.expect("write resp");
            (head, body)
        });
        (format!("http://{addr}/upload"), handle)
    }

    /// 从 multipart 请求体中取出指定文件部件的字节
    ///
    /// 起点 = `Content-Disposition: form-data; name="<field>"; filename=` 之后的
    /// 第一个空行；终点 = 下一个 `\r\n--` 边界（文件内容本身可为任意字节）。
    fn extract_multipart_file<'a>(body: &'a [u8], field: &str) -> &'a [u8] {
        let marker = format!("Content-Disposition: form-data; name=\"{field}\"; filename=\"");
        let marker_pos = body
            .windows(marker.len())
            .position(|w| w == marker.as_bytes())
            .unwrap_or_else(|| panic!("未找到文件部件 {field}"));
        let after_marker = &body[marker_pos..];
        let head_end = after_marker
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .expect("文件部件缺少头部结束空行")
            + 4;
        let data = &after_marker[head_end..];
        let data_end = data
            .windows(4)
            .position(|w| w == b"\r\n--")
            .expect("文件部件缺少结束边界");
        &data[..data_end]
    }

    #[tokio::test]
    async fn test_upload_loopback_multipart_parts_and_fields() {
        let (url, server) =
            spawn_mock_upload_server(r#"{"code":0,"data":{"url":"https://dl.example/f/abc"}}"#)
                .await;
        let rule = rule_with(
            &format!(
                r#"{url},{{"method":"POST","headers":{{"X-Upload-Token":"tk-1","Content-Type":"text/plain"}},"body":{{"file":"fileRequest","title":"书源合集","n":7}},"type":"multipart/form-data"}}"#
            ),
            "$.data.url",
        );
        let client = LegadoClient::new(crate::LegadoClientConfig::default()).unwrap();
        let outcome = upload(
            &client,
            &rule,
            "sources.json",
            "application/json",
            b"[]".to_vec(),
        )
        .await
        .expect("上传应成功");

        assert_eq!(outcome.status, 200);
        assert_eq!(
            outcome.body,
            r#"{"code":0,"data":{"url":"https://dl.example/f/abc"}}"#
        );
        assert!(outcome.url.ends_with("/upload"), "{}", outcome.url);

        let (head, body) = server.await.expect("server task");
        let head_lower = head.to_lowercase();
        assert!(head.starts_with("POST /upload"), "{head}");
        assert!(
            head_lower.contains("content-type: multipart/form-data; boundary="),
            "整体 Content-Type 应带 boundary（选项同名头被请求体覆盖）: {head}"
        );
        assert!(
            !head_lower.contains("content-type: text/plain"),
            "选项里的 Content-Type 不应透传: {head}"
        );
        assert!(
            head_lower.contains("x-upload-token: tk-1"),
            "选项 headers 应透传: {head}"
        );
        let text = String::from_utf8(body).unwrap();
        // 文件部件：字段名 file、文件名 sources.json、类型 application/json、内容 []
        assert!(
            text.contains(
                "Content-Disposition: form-data; name=\"file\"; filename=\"sources.json\""
            ),
            "{text}"
        );
        assert!(
            text.contains("Content-Type: application/json\r\n\r\n[]"),
            "{text}"
        );
        // 普通字段（中文原样、数字字符串化）
        assert!(text.contains("name=\"title\"\r\n\r\n书源合集"), "{text}");
        assert!(text.contains("name=\"n\"\r\n\r\n7"), "{text}");
    }

    #[tokio::test]
    async fn test_upload_loopback_compress_produces_zip() {
        let (url, server) = spawn_mock_upload_server("{\"msg\":\"ok\"}").await;
        let mut rule = rule_with(
            &format!(r#"{url},{{"body":{{"file":"fileRequest"}}}}"#),
            "$.msg",
        );
        rule.compress = true;
        let client = LegadoClient::new(crate::LegadoClientConfig::default()).unwrap();
        let outcome = upload(
            &client,
            &rule,
            "rules.json",
            "application/json",
            b"[1,2,3]".to_vec(),
        )
        .await
        .expect("上传应成功");
        assert_eq!(outcome.body, "{\"msg\":\"ok\"}");

        let (_, body) = server.await.expect("server task");
        let text = String::from_utf8_lossy(&body);
        assert!(
            text.contains("filename=\"rules.json.zip\""),
            "压缩后文件名应加 .zip: {text}"
        );
        assert!(text.contains("Content-Type: application/zip"), "{text}");
        // 定位文件部件字节（从 Content-Disposition 后的空行到下一个 boundary）
        let file_bytes = extract_multipart_file(&body, "file");
        // 末尾含 multipart 追加的 CRLF，ZIP 解析器接受尾随数据
        let mut archive =
            zip::ZipArchive::new(std::io::Cursor::new(file_bytes.to_vec())).expect("zip 可读");
        let mut entry = archive.by_index(0).unwrap();
        assert_eq!(entry.name(), "rules.json");
        let mut out = Vec::new();
        std::io::Read::read_to_end(&mut entry, &mut out).unwrap();
        assert_eq!(out, b"[1,2,3]");
    }

    /// P1-1：大载荷上传覆写共享客户端 60s 总超时
    ///
    /// 客户端 `read_timeout` 刻意设 100ms、服务端延迟 500ms 响应：若未在
    /// `post_multipart` 内按载荷覆写单请求超时，请求会以客户端级 100ms 超时
    /// 失败；覆写后（4KB 载荷 → connect 15s + 传输 1s + 读 100ms）成功。
    #[tokio::test]
    async fn test_upload_overrides_client_total_timeout() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind 127.0.0.1:0");
        let addr = listener.local_addr().expect("local_addr");
        let server = tokio::spawn(async move {
            let (mut sock, _) = listener.accept().await.expect("accept");
            // 读掉完整请求（头 + body），再延迟响应，模拟慢速服务端
            let mut raw = Vec::new();
            let mut buf = [0u8; 4096];
            let header_end = loop {
                let n = sock.read(&mut buf).await.expect("read");
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
                let n = sock.read(&mut buf).await.expect("read body");
                assert!(n > 0, "请求体未完成即断开");
                raw.extend_from_slice(&buf[..n]);
            }
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let body = r#"{"url":"https://dl.example/f/slow"}"#;
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = sock.write_all(resp.as_bytes()).await;
        });
        let rule = rule_with(
            &format!("http://{addr}/upload,{{\"body\":{{\"file\":\"fileRequest\"}}}}"),
            "$.url",
        );
        let client = LegadoClient::new(crate::LegadoClientConfig {
            read_timeout: std::time::Duration::from_millis(100),
            no_proxy: true,
            ..crate::LegadoClientConfig::default()
        })
        .expect("构建客户端");
        // 4 KiB 载荷：客户端级 100ms 总超时必然失败，上传出口覆写后应成功
        let payload = vec![b'a'; 4 * 1024];
        let outcome = upload(&client, &rule, "big.txt", "text/plain", payload)
            .await
            .expect("上传出口应覆写客户端级总超时（P1-1）");
        assert_eq!(outcome.status, 200);
        assert_eq!(outcome.body, r#"{"url":"https://dl.example/f/slow"}"#);
        server.await.expect("server task");
    }

    #[tokio::test]
    async fn test_upload_network_error() {
        // 绑定后立刻释放，得到一个确定不可连接的端口
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        drop(listener);
        let rule = rule_with(
            &format!("http://{addr}/upload,{{\"body\":{{\"file\":\"fileRequest\"}}}}"),
            "$.url",
        );
        let client = LegadoClient::new(crate::LegadoClientConfig::default()).unwrap();
        let err = upload(&client, &rule, "a.txt", "text/plain", b"x".to_vec())
            .await
            .unwrap_err();
        assert!(
            matches!(err, LegadoError::Network(_)),
            "网络错误应为 Network 变体: {err}"
        );
    }
}
