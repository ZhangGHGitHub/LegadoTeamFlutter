//! 图片下载与 imageDecode 解码（对齐原版 ImageUtils.decodeImageStream）
//!
//! 原版语义（ImageUtils.kt:40-75）：漫画/图片站点的图片 bytes 往往经过站点
//! 专用加密，书源通过 `ruleContent.imageDecode`（如 `decode(result);`）配合
//! 书源 jsLib 定义解密函数，对图片 bytes 执行 JS 解密后才是可显示的数据。
//! 重构版此前仅有字段无执行 → 图片加载不解码 → 无法显示。
//!
//! 本模块：下载图片 → 若书源配置 imageDecode 且 jsLib，则注入
//! result(Uint8Array)/src(URL) 绑定执行 imageDecode JS，返回解密后 bytes。

use std::collections::HashMap;
use std::sync::Arc;

use base64::Engine as _;
use legado_core::models::BookSource;
use legado_core::LegadoError;
use legado_core::LegadoResult;
use legado_js::JsEngine;
use legado_js::JsValue;

/// 默认 Chrome UA（与搜索链路一致，避免图片 CDN 按 UA 拒请求）
const DEFAULT_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

/// 解析书源 header 字符串（JSON 对象 或 `key: value` 行）
/// 对齐原版 AnalyzeUrl.headerMap 语义
fn parse_header_map(header: &str) -> HashMap<String, String> {
    let mut map = HashMap::new();
    let trimmed = header.trim();
    if trimmed.is_empty() {
        return map;
    }
    if trimmed.starts_with('{') {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(trimmed) {
            if let Some(obj) = v.as_object() {
                for (k, val) in obj {
                    map.insert(k.clone(), val.as_str().unwrap_or_default().to_string());
                }
                return map;
            }
        }
    }
    for line in trimmed.lines() {
        if let Some(idx) = line.find(':') {
            let k = line[..idx].trim();
            let v = line[idx + 1..].trim();
            if !k.is_empty() {
                map.insert(k.to_string(), v.to_string());
            }
        }
    }
    map
}

/// 对图片 bytes 执行 imageDecode（若书源配置了该规则）
///
/// bindings 对齐原版 `source.evalJS(ruleJs) { put("result", inputStream); put("src", src) }`
/// result = 图片 bytes（Uint8Array），src = 图片 URL。
/// 无 imageDecode / 无 jsLib / 执行失败（规则不适用）→ 原样返回 bytes。
pub fn decode_image_bytes(
    source: &BookSource,
    img_url: &str,
    bytes: &[u8],
) -> Vec<u8> {
    let rule = source
        .rule_content
        .as_ref()
        .and_then(|c| c.image_decode.clone())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let js_lib = source
        .js_lib
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    match (rule, js_lib) {
        (Some(rule), Some(lib)) => {
            // 引擎池按书源 URL 隔离；每次调用先 eval jsLib（幂等）
            let engine: Arc<std::sync::Mutex<legado_js::QuickJsEngine>> =
                match crate::js_executor::pool_engine(&source.book_source_url) {
                    Ok(e) => e,
                    Err(_) => return bytes.to_vec(),
                };
            let guard = match engine.lock() {
                Ok(g) => g,
                Err(_) => return bytes.to_vec(),
            };
            if JsEngine::eval(&*guard, &lib).is_err() {
                return bytes.to_vec();
            }
            match JsEngine::eval_bytes(
                &*guard,
                &rule,
                &[
                    ("result", JsValue::Bytes(bytes.to_vec())),
                    ("src", JsValue::String(img_url.to_string())),
                ],
            ) {
                Ok(decoded) if !decoded.is_empty() => decoded,
                _ => bytes.to_vec(),
            }
        }
        _ => bytes.to_vec(),
    }
}

/// 下载图片（带书源 header 防盗链）并按 imageDecode 解码，返回 base64
///
/// source_json：书源 JSON（单对象）。无 imageDecode 时返回原始图片 base64。
pub fn fetch_image_with_decode(url: &str, source_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("书源 JSON 解析失败: {e}")))?;

    // 构造请求头：书源 header（Referer 等）+ 默认 UA
    let mut headers: HashMap<String, String> = source
        .header
        .as_deref()
        .map(parse_header_map)
        .unwrap_or_default();
    if !headers.contains_key("User-Agent") && !headers.contains_key("user-agent") {
        headers.insert("User-Agent".to_string(), DEFAULT_UA.to_string());
    }
    // 图片防盗链：无 Referer 时以书源主页兜底（对齐原版 ImageLoader referer）
    if !headers.contains_key("Referer") && !headers.contains_key("referer") {
        if let Some(origin) = source.book_source_url.rsplitn(2, '/').nth(1) {
            headers.insert("Referer".to_string(), format!("{}/", origin));
        }
    }

    let resp = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client();
        client.get_raw(url, Some(headers)).await
    })?;
    if !resp.is_success() {
        return Err(LegadoError::Network(format!(
            "图片下载失败: HTTP {}",
            resp.status
        )));
    }
    let bytes = resp.body;

    let decoded = decode_image_bytes(&source, url, &bytes);
    let b64 = base64::engine::general_purpose::STANDARD.encode(&decoded);
    Ok(serde_json::json!({ "base64": b64, "len": decoded.len() }).to_string())
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 无 imageDecode 规则时原样返回
    #[test]
    fn test_decode_no_rule_returns_original() {
        let src: BookSource = serde_json::from_str(
            r#"{"bookSourceUrl":"https://a.example.com","bookSourceName":"t","bookSourceType":0,"searchUrl":"https://a.example.com/search?q={{key}}","ruleSearch":{"bookList":".x"}}"#,
        )
        .unwrap();
        let out = decode_image_bytes(&src, "https://a.example.com/1.jpg", &[1, 2, 3]);
        assert_eq!(out, vec![1, 2, 3]);
    }

    /// imageDecode 规则 + jsLib 解密：bytes 注入为 Uint8Array，JS 按位翻转后返回
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_decode_with_js_lib_xor() {
        let src: BookSource = serde_json::from_str(
            r#"{
              "bookSourceUrl":"https://b.example.com",
              "bookSourceName":"t",
              "bookSourceType":2,
              "searchUrl":"https://b.example.com/search?q={{key}}",
              "ruleSearch":{"bookList":".x"},
              "jsLib":"function decode(b){var o=new Uint8Array(b.length);for(var i=0;i<b.length;i++){o[i]=b[i]^0xFF;}return o;}",
              "ruleContent":{"content":".x","imageDecode":"decode(result);"}
            }"#,
        )
        .unwrap();
        let out = decode_image_bytes(&src, "https://b.example.com/1.jpg", &[0xAA, 0x00, 0x7F]);
        assert_eq!(out, vec![0x55, 0xFF, 0x80]);
    }

    /// 真实站点链路：favcomic 图片下载 → jsLib decode → JPEG 头（需网络）
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_favcomic_image_decode_real() {
        let _db_guard = crate::db_state::ensure_test_db();
        let sources_json =
            std::fs::read_to_string("tests/fixtures/comic_source.json").unwrap();
        let sources: Vec<serde_json::Value> =
            serde_json::from_str(&sources_json).expect("书源 JSON 数组解析失败");
        let source_json = sources[0].to_string();
        let src: BookSource =
            serde_json::from_str(&source_json).expect("书源反序列化失败");
        crate::api::source::import_sources(&sources_json).expect("导入书源失败");

        // 搜索 → 目录 → 正文提取第一张图片 URL
        let keyword = "少女過激";
        let urls_json = format!(
            r#"["{}"]"#,
            sources[0]["bookSourceUrl"].as_str().unwrap_or_default()
        );
        let results = crate::api::search::search_books(keyword, &urls_json).unwrap();
        println!("===== [search] total={}", results.len());
        let mut img_url = String::new();
        for (bi, first) in results.iter().enumerate().take(3) {
            println!("===== [book] {} {}", first.book_name, first.book_url);
            let toc = crate::api::reader::refresh_toc(&first.book_url, &first.source_url)
                .unwrap();
            println!("===== [toc] chapters={}", toc.chapters.len());
            let ch = toc.chapters.first().expect("无章节");
            println!("===== [chapter] {} {}", ch.title, ch.url);
            // 诊断：直接下载章节页，检查 images 数据形态
            let raw = crate::runtime::block_on(async {
                let client = crate::http_state::shared_client();
                client
                    .get_raw(&ch.url, None)
                    .await
                    .map(|r| String::from_utf8_lossy(&r.body).to_string())
            });
            let raw_html = match &raw {
                Ok(h) => h.clone(),
                Err(_) => String::new(),
            };
            if let Ok(html) = raw {
                if let Some(pos) = html.find("\"images\":") {
                    let end = html[pos..].find(']').map(|e| pos + e + 1).unwrap_or(pos + 20);
                    let after = html[end..].chars().take(8).collect::<String>();
                    println!(
                        "===== [images-ctx] webtoon={} after_arr={:?} head={:?}",
                        html.contains("\"webtoon\":1"),
                        after,
                        &html[pos..(pos + 90).min(html.len())]
                    );
                } else {
                    println!("===== [images-ctx] NOT FOUND len={}", html.len());
                }
            } else {
                println!("===== [raw-err]");
            }
            match crate::api::reader::get_chapter_content_full(&first.book_url, ch.index) {
                Ok(content) => {
                    println!(
                        "===== [content] len={} head={:?}",
                        content.len(),
                        &content[..content.len().min(120)]
                    );
                    // 取第一张图片 URL 做下载解码验证
                    if img_url.is_empty() {
                        for line in content.lines() {
                            if let Some(pos) = line.find("<img src=\"") {
                                let rest = &line[pos + 10..];
                                if let Some(end) = rest.find('"') {
                                    img_url = rest[..end].to_string();
                                    break;
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    println!("===== [content-err] {e}");
                    // 诊断：直接调 parse_content_page_with_js_lib 捕获真实错误
                    let rc = src.rule_content.as_ref();
                    let rule = rc.and_then(|r| r.content.as_deref()).unwrap_or("");
                    let diag = crate::js_executor::construct_analyzer_with_js_lib(
                        raw_html.clone(),
                        ch.url.clone(),
                        &first.source_url,
                        src.js_lib.as_deref(),
                    );
                    let list = diag.get_strings(rule);
                    println!(
                        "===== [parse-diag] {:?}",
                        list.as_ref()
                            .map(|v| (v.len(), v.first().map(|s| s.len())))
                    );
                }
            }
        }
        assert!(!img_url.is_empty(), "正文无 img URL");

        // 下载 + 解码
        let json = fetch_image_with_decode(&img_url, &source_json).unwrap();
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let b64 = v["base64"].as_str().unwrap_or_default();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(b64)
            .unwrap();
        println!(
            "===== [decoded] len={} head={:02X?} url={}",
            bytes.len(),
            &bytes[..bytes.len().min(8)],
            img_url
        );
        // 解码后应为有效图片（JPEG FFD8 / PNG 8950 / GIF 4749）
        let is_image = bytes.len() > 4
            && (bytes[0] == 0xFF && bytes[1] == 0xD8
                || bytes[0] == 0x89 && bytes[1] == 0x50
                || bytes[0] == 0x47 && bytes[1] == 0x49);
        assert!(is_image, "解码后不是有效图片头");
    }
}
