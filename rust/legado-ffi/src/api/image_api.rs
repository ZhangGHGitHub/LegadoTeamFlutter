//! 图片下载与 imageDecode 解码（对齐原版 ImageUtils.decodeImageStream）
//!
//! 原版语义（ImageUtils.kt:40-75）：漫画/图片站点的图片 bytes 往往经过站点
//! 专用加密，书源通过 `ruleContent.imageDecode`（如 `decode(result);`）配合
//! 书源 jsLib 定义解密函数，对图片 bytes 执行 JS 解密后才是可显示的数据。
//! 重构版此前仅有字段无执行 → 图片加载不解码 → 无法显示。
//!
//! 本模块：下载图片 → 若书源配置 imageDecode，则**每次新建引擎**注入
//! result(Uint8Array)/src(URL) 绑定执行 imageDecode JS，返回解密后 bytes。
//! jsLib 可选（失败降级继续，对齐规则路径 v2.0.24）；勿用 pool_engine
//!（同源第 2 张起 const/let redeclaration → 退回密文）。

use std::collections::HashMap;

use base64::Engine as _;
use legado_core::models::BookSource;
use legado_core::LegadoError;
use legado_core::LegadoResult;
#[cfg(feature = "quickjs")]
use legado_js::JsEngine;
#[cfg(feature = "quickjs")]
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
/// - 无 imageDecode → 原样返回
/// - 有 imageDecode：每次新建引擎执行（对齐规则路径 v2.0.24，不用 pool）
/// - jsLib 可选：有则先 eval，失败 eprintln 后仍尝试 decode（勿静默假成功掩盖）
/// - decode 失败/空结果 → eprintln 可观测，回退原图
pub fn decode_image_bytes(source: &BookSource, img_url: &str, bytes: &[u8]) -> Vec<u8> {
    let Some(rule) = source
        .rule_content
        .as_ref()
        .and_then(|c| c.image_decode.clone())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
    else {
        return bytes.to_vec();
    };

    let js_lib = source
        .js_lib
        .clone()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    #[cfg(feature = "quickjs")]
    {
        // 每次新建引擎：同源多图连续 decode 时顶层 const/let 不会 redeclaration
        let engine = match legado_js::QuickJsEngine::new(
            legado_js::sandbox::SandboxConfig::default().with_allow_script_run(true),
        ) {
            Ok(e) => e,
            Err(e) => {
                eprintln!("[legado-ffi] imageDecode 引擎创建失败（回退原图）: {e} url={img_url}");
                return bytes.to_vec();
            }
        };

        if let Some(lib) = js_lib.as_deref() {
            if let Err(e) = JsEngine::eval(&engine, lib) {
                // 降级继续：部分书源混淆 jsLib 依赖 Rhino Packages，但仍可能仅靠
                // imageDecode 内联逻辑；失败必须可观测，勿静默当成功
                eprintln!(
                    "[legado-ffi] imageDecode jsLib 加载失败（降级继续 decode）: {e} source={}",
                    source.book_source_url
                );
            }
        }

        match JsEngine::eval_bytes(
            &engine,
            &rule,
            &[
                ("result", JsValue::Bytes(bytes.to_vec())),
                ("src", JsValue::String(img_url.to_string())),
            ],
        ) {
            Ok(decoded) if !decoded.is_empty() => decoded,
            Ok(_) => {
                eprintln!("[legado-ffi] imageDecode 返回空字节（回退原图）url={img_url}");
                bytes.to_vec()
            }
            Err(e) => {
                eprintln!("[legado-ffi] imageDecode 执行失败（回退原图）: {e} url={img_url}");
                bytes.to_vec()
            }
        }
    }

    #[cfg(not(feature = "quickjs"))]
    {
        let _ = (rule, js_lib, img_url);
        eprintln!("[legado-ffi] imageDecode 需要 quickjs feature（回退原图）");
        bytes.to_vec()
    }
}

/// 书源主页默认 Referer（对齐图片防盗链兜底）
///
/// 无尾斜杠纯域名（如 `https://site.com`）不得 `rsplitn('/')` 截成 `https:`。
fn default_referer_from_source_url(book_source_url: &str) -> Option<String> {
    let url = book_source_url.trim();
    if url.is_empty() {
        return None;
    }
    if url.ends_with('/') {
        return Some(url.to_string());
    }
    // 无路径：整段 URL + /
    if let Some(scheme_end) = url.find("://") {
        if !url[scheme_end + 3..].contains('/') {
            return Some(format!("{url}/"));
        }
    }
    // 有路径：去掉最后一段，保留目录尾斜杠
    if let Some(pos) = url.rfind('/') {
        let origin = &url[..=pos];
        if origin.contains("://") {
            return Some(origin.to_string());
        }
    }
    Some(format!("{}/", url.trim_end_matches('/')))
}

/// 解析复合图片 URL（`url,{json headers}`）：返回真实 URL 与内嵌 headers
///
/// 对齐原版 AnalyzeUrl.kt analyzeUrl 语义：切首个 `,` 前为 URL，后部
/// JSON（`{"headers":{...}}` 或扁平 `{...}`）解析为请求头。
/// 无 `,{` 复合段时原样返回 URL 与空 headers — Reasonix
fn split_composite_image_url(url: &str) -> (String, HashMap<String, String>) {
    if let Some(comma_pos) = url.find(',') {
        let after = url[comma_pos + 1..].trim();
        if after.starts_with('{') && after.ends_with('}') {
            let analyzed = legado_parser::AnalyzeUrl::new(url, None, None, "", None);
            let parsed_url = analyzed.url().to_string();
            if !parsed_url.is_empty() {
                let headers = analyzed
                    .headers()
                    .iter()
                    .map(|(k, v)| (k.clone(), v.clone()))
                    .collect::<HashMap<String, String>>();
                return (parsed_url, headers);
            }
        }
    }
    (url.to_string(), HashMap::new())
}

/// 下载图片（带书源 header 防盗链）并按 imageDecode 解码，返回 base64
///
/// source_json：书源 JSON（单对象）。无 imageDecode 时返回原始图片 base64。
///
/// 支持原版 `url,{json headers}` 复合格式（favcomic 等漫画站图片 URL 内嵌
/// 防盗链 header，对齐原版 AnalyzeUrl.kt analyzeUrl 切首个 `,` 前为 URL、
/// 后部解析为 headerMap）：URL 含 `,{...}` 时经 [`split_composite_image_url`]
/// 拆分，内嵌 headers 与书源 header 合并后请求 — Reasonix
pub fn fetch_image_with_decode(url: &str, source_json: &str) -> LegadoResult<String> {
    let source: BookSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("书源 JSON 解析失败: {e}")))?;

    // 解析复合 URL（url,{json headers}）：拆分出真实 URL 与内嵌 headers
    let (request_url, embedded_headers) = split_composite_image_url(url);

    // 构造请求头：书源 header（Referer 等）+ 内嵌 header + 默认 UA
    let mut headers: HashMap<String, String> = source
        .header
        .as_deref()
        .map(parse_header_map)
        .unwrap_or_default();
    // 内嵌 header 优先级最高（书源规则显式指定的防盗链）
    headers.extend(embedded_headers);
    if !headers.contains_key("User-Agent") && !headers.contains_key("user-agent") {
        headers.insert("User-Agent".to_string(), DEFAULT_UA.to_string());
    }
    // 图片防盗链：无 Referer 时以书源主页兜底（对齐原版 ImageLoader referer）
    if !headers.contains_key("Referer") && !headers.contains_key("referer") {
        if let Some(referer) = default_referer_from_source_url(&source.book_source_url) {
            headers.insert("Referer".to_string(), referer);
        }
    }

    let resp = crate::runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        client.get_raw(&request_url, Some(headers)).await
    })?;
    if !resp.is_success() {
        return Err(LegadoError::Network(format!(
            "图片下载失败: HTTP {}",
            resp.status
        )));
    }
    let bytes = resp.body;

    // src 绑定对齐原版：传入完整（可能含复合 header 段）原始 URL
    let decoded = decode_image_bytes(&source, url, &bytes);
    // 有 imageDecode 时：解密结果必须是可识别图片，禁止把密文当成功回传
    // （否则 Flutter Image.memory → Invalid image data / Decoder 刷屏）— Reasonix
    let has_decode_rule = source
        .rule_content
        .as_ref()
        .and_then(|c| c.image_decode.as_ref())
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    if has_decode_rule && !looks_like_image_bytes(&decoded) {
        return Err(LegadoError::Ffi(format!(
            "imageDecode 后仍非有效图片（len={} magic={:02X?}），请检查 java.createSymmetricCrypto/解密规则 url={request_url}",
            decoded.len(),
            decoded.iter().take(4).copied().collect::<Vec<_>>()
        )));
    }
    let b64 = base64::engine::general_purpose::STANDARD.encode(&decoded);
    Ok(serde_json::json!({ "base64": b64, "len": decoded.len() }).to_string())
}

/// JPEG/PNG/GIF/WEBP 魔数探测（漫画页几乎只用这些）
fn looks_like_image_bytes(bytes: &[u8]) -> bool {
    if bytes.len() < 4 {
        return false;
    }
    if bytes.starts_with(&[0xFF, 0xD8]) {
        return true; // JPEG
    }
    if bytes.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        return true; // PNG
    }
    if bytes.starts_with(b"GIF8") {
        return true; // GIF
    }
    if bytes.len() >= 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return true; // WEBP
    }
    false
}

// ─── 测试 ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// 复合图片 URL（url,{json headers}）拆分：真实 URL + 内嵌 headers
    #[test]
    fn test_split_composite_image_url() {
        // favcomic 风格：内嵌 User-Agent/Referer/x-requested-with
        let (url, headers) = split_composite_image_url(
            r#"https://cdn.favcomic.net/file/e-media/image/comic/1/1.webp,{"headers":{"User-Agent":"Mozilla/5.0","Referer":"https://cdn.favcomic.net/","x-requested-with":"XBrowser"}}"#,
        );
        assert_eq!(
            url,
            "https://cdn.favcomic.net/file/e-media/image/comic/1/1.webp"
        );
        assert_eq!(
            headers.get("User-Agent").map(|s| s.as_str()),
            Some("Mozilla/5.0")
        );
        assert_eq!(
            headers.get("Referer").map(|s| s.as_str()),
            Some("https://cdn.favcomic.net/")
        );
        assert_eq!(
            headers.get("x-requested-with").map(|s| s.as_str()),
            Some("XBrowser")
        );

        // 扁平 JSON 若不包裹 headers 字段则按 AnalyzeUrl 语义不解析 headers
        //（favcomic 实际使用 {"headers":{...}} 包裹格式，上方已覆盖）
        let (url2, _headers2) = split_composite_image_url(
            r#"https://img.example.com/1.jpg,{"Referer":"https://img.example.com/"}"#,
        );
        assert_eq!(url2, "https://img.example.com/1.jpg");

        // 无复合段：原样返回
        let (url3, headers3) = split_composite_image_url("https://img.example.com/2.jpg");
        assert_eq!(url3, "https://img.example.com/2.jpg");
        assert!(headers3.is_empty());
    }

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

    /// 默认 Referer：无尾斜杠纯域名不得截成 https:
    #[test]
    fn test_default_referer_domain_only() {
        assert_eq!(
            default_referer_from_source_url("https://site.com"),
            Some("https://site.com/".to_string())
        );
        assert_eq!(
            default_referer_from_source_url("https://site.com/"),
            Some("https://site.com/".to_string())
        );
        assert_eq!(
            default_referer_from_source_url("https://site.com/path/page"),
            Some("https://site.com/path/".to_string())
        );
        assert_eq!(default_referer_from_source_url(""), None);
    }

    #[test]
    fn test_looks_like_image_bytes() {
        assert!(looks_like_image_bytes(&[0xFF, 0xD8, 0xFF, 0xE0]));
        assert!(looks_like_image_bytes(&[0x89, 0x50, 0x4E, 0x47]));
        assert!(!looks_like_image_bytes(&[1, 2, 3, 4]));
        assert!(!looks_like_image_bytes(&[]));
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

    /// 仅有 imageDecode、无 jsLib：规则内联仍应执行（不强制 jsLib）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_decode_rule_only_without_js_lib() {
        let src: BookSource = serde_json::from_str(
            r#"{
              "bookSourceUrl":"https://c.example.com",
              "bookSourceName":"t",
              "bookSourceType":2,
              "searchUrl":"https://c.example.com/search?q={{key}}",
              "ruleSearch":{"bookList":".x"},
              "ruleContent":{"content":".x","imageDecode":"var o=new Uint8Array(result.length);for(var i=0;i<result.length;i++){o[i]=result[i]^0x0F;}o;"}
            }"#,
        )
        .unwrap();
        let out = decode_image_bytes(&src, "https://c.example.com/1.jpg", &[0x10, 0x20]);
        assert_eq!(out, vec![0x1F, 0x2F]);
    }

    /// 设备取证回归：51漫画真实 CDN 密文（非自造最小 JPEG）经同款 imageDecode 出 JPEG
    ///
    /// 证据：`pic.xmbvxj.cn` 下载 len=346224 magic=4FE8…；桌面 AES/CBC/NoPadding
    /// 解密后 FFD8 + PIL 可开。若 Android jniLibs 未重编含 createSymmetricCrypto 对象
    /// 的 .so，实机仍会 FlutterImageDecoder 刷屏。— Reasonix
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_decode_51manga_real_ciphertext_fixture() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/51manga_page_cipher.bin");
        if !fixture.is_file() {
            eprintln!("skip: 无设备密文夹具 {}", fixture.display());
            return;
        }
        let cipher = std::fs::read(&fixture).expect("read fixture");
        assert_eq!(cipher.len() % 16, 0);
        assert!(
            !looks_like_image_bytes(&cipher),
            "夹具应为密文，got magic={:02X?}",
            &cipher[..cipher.len().min(4)]
        );
        let image_decode = r#"function decryptImage(src) {
    const key = "102_53_100_57_54_53_100_102_55_53_51_51_54_50_55_48"
        .split("_").map(n => String.fromCharCode(parseInt(n))).join("");
    const iv  = "57_55_98_54_48_51_57_52_97_98_99_50_102_98_101_49"
        .split("_").map(n => String.fromCharCode(parseInt(n))).join("");
    const cipher = java.createSymmetricCrypto("AES/CBC/NoPadding", key, iv)
    return cipher.decrypt(src);
}
decryptImage(result);"#;
        let src: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://51acgs.com",
            "bookSourceName": "51漫画",
            "bookSourceType": 2,
            "searchUrl": "https://51acgs.com/search",
            "ruleSearch": {"bookList": ".x"},
            "ruleContent": {"content": ".comics@img@html", "imageDecode": image_decode}
        }))
        .unwrap();
        let out = decode_image_bytes(&src, "https://pic.xmbvxj.cn/1.jpeg", &cipher);
        assert!(
            looks_like_image_bytes(&out),
            "真实密文解密后应有 JPEG 魔数，got {:02X?}",
            &out[..out.len().min(4)]
        );
        assert_eq!(&out[..2], &[0xFF, 0xD8]);
    }

    /// 离线对齐 51漫画 imageDecode：AES/CBC/NoPadding + createSymmetricCrypto.decrypt
    /// （规则片段来自设备书源 https://51acgs.com，密文由同 key/iv 加密最小 JPEG）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_decode_51manga_style_aes_nopadding_offline() {
        use legado_core::crypto::AesCrypto;

        // 最小 JPEG 头 + 填充到 16 字节对齐（NoPadding 要求）
        let plain = vec![
            0xFF, 0xD8, 0xFF, 0xD9, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
        ];
        assert_eq!(plain.len() % 16, 0);
        let key = b"f5d965df75336270"; // 书源 key 码点串还原
        let iv = b"97b60394abc2fbe1";
        let cipher = AesCrypto::encrypt_cbc_nopadding(key, iv, &plain).expect("encrypt");

        let image_decode = r#"function decryptImage(src) {
    const key = "102_53_100_57_54_53_100_102_55_53_51_51_54_50_55_48"
        .split("_").map(n => String.fromCharCode(parseInt(n))).join("");
    const iv  = "57_55_98_54_48_51_57_52_97_98_99_50_102_98_101_49"
        .split("_").map(n => String.fromCharCode(parseInt(n))).join("");
    const cipher = java.createSymmetricCrypto("AES/CBC/NoPadding", key, iv)
    return cipher.decrypt(src);
}
decryptImage(result);"#;

        let src: BookSource = serde_json::from_value(serde_json::json!({
            "bookSourceUrl": "https://51acgs.com",
            "bookSourceName": "51漫画",
            "bookSourceType": 2,
            "searchUrl": "https://51acgs.com/search/result/comics?keyword={{key}}&page={{page}}",
            "ruleSearch": {"bookList": ".x"},
            "ruleContent": {"content": ".comics@img@html", "imageDecode": image_decode}
        }))
        .unwrap();

        let out = decode_image_bytes(&src, "https://pic.example.com/1.jpeg", &cipher);
        assert!(
            looks_like_image_bytes(&out),
            "51 规则解密后应有 JPEG 魔数，got {:02X?}",
            &out[..out.len().min(4)]
        );
        assert_eq!(&out[..2], &[0xFF, 0xD8]);
        let _ = plain; // 明文长度与密文一致即可，尾部 padding 保留
    }

    /// 同源连续 decode 两次：每次新引擎，顶层 const 不 redeclaration
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_decode_twice_no_redeclaration() {
        let src: BookSource = serde_json::from_str(
            r#"{
              "bookSourceUrl":"https://d.example.com",
              "bookSourceName":"t",
              "bookSourceType":2,
              "searchUrl":"https://d.example.com/search?q={{key}}",
              "ruleSearch":{"bookList":".x"},
              "ruleContent":{"content":".x","imageDecode":"const k=1; result;"}
            }"#,
        )
        .unwrap();
        let a = decode_image_bytes(&src, "https://d.example.com/1.jpg", &[1, 2]);
        let b = decode_image_bytes(&src, "https://d.example.com/2.jpg", &[3, 4]);
        assert_eq!(a, vec![1, 2]);
        assert_eq!(b, vec![3, 4]);
    }

    /// 真实站点链路：favcomic 图片下载 → jsLib decode → JPEG 头（需网络）
    #[cfg(feature = "quickjs")]
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_favcomic_image_decode_real() {
        let _db_guard = crate::db_state::ensure_test_db();
        let sources_json = std::fs::read_to_string("tests/fixtures/comic_source.json").unwrap();
        let sources: Vec<serde_json::Value> =
            serde_json::from_str(&sources_json).expect("书源 JSON 数组解析失败");
        let source_json = sources[0].to_string();
        let src: BookSource = serde_json::from_str(&source_json).expect("书源反序列化失败");
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
        for (_bi, first) in results.iter().enumerate().take(3) {
            println!("===== [book] {} {}", first.book_name, first.book_url);
            let toc = crate::api::reader::refresh_toc(&first.book_url, &first.source_url).unwrap();
            println!("===== [toc] chapters={}", toc.chapters.len());
            let ch = toc.chapters.first().expect("无章节");
            println!("===== [chapter] {} {}", ch.title, ch.url);
            // 诊断：直接下载章节页，检查 images 数据形态
            let raw = crate::runtime::block_on(async {
                let client = crate::http_state::shared_client().expect("shared client");
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
                    let end = html[pos..]
                        .find(']')
                        .map(|e| pos + e + 1)
                        .unwrap_or(pos + 20);
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
                        list.as_ref().map(|v| (v.len(), v.first().map(|s| s.len())))
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
