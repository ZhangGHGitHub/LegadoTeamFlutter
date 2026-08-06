//! HTTP TTS 语音合成管线（纯逻辑层）
//!
//! Task #113 批次 2 缺口②：对照 Kotlin 原版
//! `HttpReadAloudService.getSpeakStream` + `AnalyzeUrl(speakText/speakSpeed)` 模型：
//!
//! 1. url 模板占位符替换（`{{speakText}}` / `{{text}}`、`{{speakSpeed}}` / `{{speed}}`）
//! 2. 发起 HTTP 请求获取音频二进制（网络层通过闭包注入，便于单测 mock）
//! 3. Content-Type 校验：`application/json` / `text/*` 视为服务器报错（对齐原版抛响应体文本）
//! 4. 以「模板+文本+语速」MD5 命名缓存到本地目录，命中直接返回路径免重复请求
//!
//! 本模块不依赖网络 crate，HTTP 拉取由调用方（legado-ffi 层）注入。

use std::path::{Path, PathBuf};

use crate::error::{LegadoError, LegadoResult};

/// 合成音频缓存文件名前缀
pub const SPEAK_CACHE_PREFIX: &str = "tts_";

/// 音频拉取响应（由网络层适配填充）
#[derive(Debug, Clone)]
pub struct SpeakResponse {
    /// HTTP 状态码
    pub status: u16,
    /// 响应 Content-Type（可含参数，如 `audio/mpeg; charset=...`）
    pub content_type: String,
    /// 响应体原始字节
    pub body: Vec<u8>,
}

/// 合成结果
#[derive(Debug, Clone)]
pub struct SpeakResult {
    /// 本地音频文件绝对路径
    pub audio_path: PathBuf,
    /// 是否缓存命中（true 时未发起网络请求）
    pub from_cache: bool,
    /// 音频 MIME 类型（如 `audio/mpeg`）
    pub content_type: String,
}

/// 构建朗读请求 URL：替换模板中的占位符
///
/// 对照原版 `AnalyzeUrl` 的 `speakText` / `speakSpeed` 绑定。
/// 支持 `{{speakText}}` / `{{text}}`（朗读文本，URL 编码后替换）
/// 与 `{{speakSpeed}}` / `{{speed}}`（语速）；未识别占位符保留原样。
pub fn build_speak_url(template: &str, text: &str, speed: f64) -> String {
    let speed_str = format_speed(speed);
    let encoded = url_encoded(text);
    template
        .replace("{{speakText}}", &encoded)
        .replace("{{text}}", &encoded)
        .replace("{{speakSpeed}}", &speed_str)
        .replace("{{speed}}", &speed_str)
}

/// 语速格式化：整数不带小数点（对齐原版 speakSpeed 为 Int 的语义）
fn format_speed(speed: f64) -> String {
    if (speed - speed.round()).abs() < f64::EPSILON {
        format!("{}", speed.round() as i64)
    } else {
        format!("{:.1}", speed)
    }
}

/// 计算合成缓存键：MD5(模板)-MD5(文本)-语速
///
/// 同一模板同一文本同一语速命中同一缓存文件，对应原版 `md5SpeakFileName(text)`。
///
/// 评审修复（缓存键碰撞，低危）：原先拼接 `"模板|文本|语速"` 后整体 MD5，
/// 模板/文本内容含 `|` 时不同输入可产生同一拼接串（如 `a|b` + `c` 与
/// `a` + `b|c`）。现改为各段独立 MD5 后拼接：md5 段定长，分隔符不再
/// 引入歧义。分隔符取 `-` 而非 `|`，因键会嵌入缓存文件名，`|` 在
/// Windows 文件系统为非法字符。
pub fn speak_cache_key(template: &str, text: &str, speed: f64) -> String {
    format!(
        "{:x}-{:x}-{}",
        md5::compute(template.as_bytes()),
        md5::compute(text.as_bytes()),
        format_speed(speed)
    )
}

/// Content-Type → 音频文件扩展名映射（无法识别时回退 `mp3`）
pub fn ext_from_content_type(content_type: &str) -> &'static str {
    let ct = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    match ct.as_str() {
        "audio/mpeg" | "audio/mp3" => "mp3",
        "audio/wav" | "audio/x-wav" | "audio/wave" => "wav",
        "audio/aac" => "aac",
        "audio/mp4" | "audio/x-m4a" | "audio/m4a" => "m4a",
        "audio/ogg" | "application/ogg" => "ogg",
        "audio/amr" => "amr",
        "audio/flac" => "flac",
        _ => "mp3",
    }
}

/// 扩展名 → MIME 类型反查（缓存命中时用于回填 contentType）
pub fn content_type_from_ext(ext: &str) -> &'static str {
    match ext {
        "wav" => "audio/wav",
        "aac" => "audio/aac",
        "m4a" => "audio/mp4",
        "ogg" => "audio/ogg",
        "amr" => "audio/amr",
        "flac" => "audio/flac",
        _ => "audio/mpeg",
    }
}

/// 判断 Content-Type 是否为错误内容（对齐原版：json/text 响应体即报错信息）
pub fn is_error_content_type(content_type: &str) -> bool {
    let ct = content_type
        .split(';')
        .next()
        .unwrap_or("")
        .trim()
        .to_lowercase();
    ct == "application/json" || ct.starts_with("text/")
}

/// 合成音频文件缓存：`{dir}/tts_{md5}.{ext}`
///
/// 文件系统即索引（对照原版 `hasSpeakFile` / `createSpeakFile` 目录扫描模式），
/// 进程重启后缓存仍然有效。
pub struct SpeakCache {
    dir: PathBuf,
}

impl SpeakCache {
    /// 创建缓存实例，目录不存在时自动创建
    pub fn new(dir: PathBuf) -> Self {
        if !dir.exists() {
            std::fs::create_dir_all(&dir).ok();
        }
        Self { dir }
    }

    /// 缓存目录
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// 查找缓存文件（扫描 `tts_{key}.*`），未命中返回 None；空文件视为未命中
    pub fn get(&self, key: &str) -> Option<PathBuf> {
        let prefix = format!("{}{}.", SPEAK_CACHE_PREFIX, key);
        let entries = std::fs::read_dir(&self.dir).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            // 评审修复（提前返回，低危）：原 `path.file_name()?` 遇 None
            // 会终止整个扫描循环，改为 continue 跳过该条目。
            let Some(file_name) = path.file_name() else {
                continue;
            };
            let name = file_name.to_string_lossy().to_string();
            if name.starts_with(&prefix) {
                if let Ok(meta) = std::fs::metadata(&path) {
                    if meta.len() > 0 {
                        return Some(path);
                    }
                }
            }
        }
        None
    }

    /// 写入缓存文件并返回路径（同键旧扩展名文件先清理，避免残留）
    pub fn put(&self, key: &str, ext: &str, bytes: &[u8]) -> LegadoResult<PathBuf> {
        std::fs::create_dir_all(&self.dir)?;
        if let Some(old) = self.get(key) {
            let new_name = format!("{}{}.{}", SPEAK_CACHE_PREFIX, key, ext);
            if old.file_name().map(|n| n.to_string_lossy().to_string()) != Some(new_name) {
                std::fs::remove_file(&old).ok();
            }
        }
        let path = self
            .dir
            .join(format!("{}{}.{}", SPEAK_CACHE_PREFIX, key, ext));
        std::fs::write(&path, bytes)?;
        Ok(path)
    }

    /// 清空全部合成缓存文件，返回删除数量
    pub fn clear(&self) -> usize {
        let mut removed = 0;
        let entries = match std::fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(_) => return 0,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                let name = path.file_name().map(|n| n.to_string_lossy().to_string());
                if name.is_some_and(|n| n.starts_with(SPEAK_CACHE_PREFIX)) {
                    if std::fs::remove_file(&path).is_ok() {
                        removed += 1;
                    }
                }
            }
        }
        removed
    }
}

/// 执行一次 TTS 合成：缓存优先，未命中时调用注入的 `fetch` 拉取音频
///
/// # 参数
/// - `template`: 引擎 URL 模板（含 `{{speakText}}` / `{{speakSpeed}}` 占位符）
/// - `text`: 朗读文本（空文本返回 ContentEmpty 错误，对齐原版空段落静音分支的前置判断）
/// - `speed`: 语速
/// - `cache_dir`: 音频缓存目录
/// - `fetch`: 网络拉取闭包（同步签名，FFI 层内部以 runtime block_on 适配）
pub fn speak_text<F>(
    template: &str,
    text: &str,
    speed: f64,
    cache_dir: &Path,
    fetch: F,
) -> LegadoResult<SpeakResult>
where
    F: FnOnce(&str) -> LegadoResult<SpeakResponse>,
{
    let text = text.trim();
    if text.is_empty() {
        return Err(LegadoError::ContentEmpty("朗读文本为空".into()));
    }

    let cache = SpeakCache::new(cache_dir.to_path_buf());
    let key = speak_cache_key(template, text, speed);

    // 1. 缓存命中：免网络请求直接返回（对照原版 hasSpeakFile 分支）
    if let Some(path) = cache.get(&key) {
        let ext = path
            .extension()
            .map(|e| e.to_string_lossy().to_string())
            .unwrap_or_else(|| "mp3".to_string());
        return Ok(SpeakResult {
            audio_path: path,
            from_cache: true,
            content_type: content_type_from_ext(&ext).to_string(),
        });
    }

    // 2. 模板替换 → HTTP 拉取
    let url = build_speak_url(template, text, speed);
    let resp = fetch(&url)?;

    if !(200..300).contains(&resp.status) {
        return Err(LegadoError::Network(format!(
            "TTS 服务器返回错误状态码: {}",
            resp.status
        )));
    }
    if resp.body.is_empty() {
        return Err(LegadoError::Network("TTS 服务器返回空音频".into()));
    }

    // 3. Content-Type 校验（对照原版 getSpeakStream：json/text 视为报错信息）
    if is_error_content_type(&resp.content_type) {
        let msg = String::from_utf8_lossy(&resp.body);
        let msg = msg.trim();
        let msg = if msg.chars().count() > 500 {
            msg.chars().take(500).collect::<String>()
        } else {
            msg.to_string()
        };
        return Err(LegadoError::Network(format!("TTS 服务器返回错误：{}", msg)));
    }

    // 4. 写入缓存并返回
    let ext = ext_from_content_type(&resp.content_type);
    let path = cache.put(&key, ext, &resp.body)?;
    let ct = resp
        .content_type
        .split(';')
        .next()
        .unwrap_or("audio/mpeg")
        .trim()
        .to_string();
    Ok(SpeakResult {
        audio_path: path,
        from_cache: false,
        content_type: ct,
    })
}

/// 简易 URL 编码（对齐 legado-net url_template::urlencoded 字符集）
fn url_encoded(s: &str) -> String {
    let mut result = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(b as char);
            }
            _ => {
                result.push_str(&format!("%{:02X}", b));
            }
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "legado_tts_speak_test_{}_{}_{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).ok();
        dir
    }

    // ─── URL 模板替换 ────────────────────────────────────────

    #[test]
    fn test_build_speak_url_speak_text_placeholders() {
        let url = build_speak_url(
            "https://tts.example.com/api?text={{speakText}}&speed={{speakSpeed}}",
            "你好世界",
            1.0,
        );
        assert!(!url.contains("{{speakText}}"));
        assert!(!url.contains("{{speakSpeed}}"));
        // 中文按 UTF-8 百分号编码
        assert!(url.contains("text=%E4%BD%A0%E5%A5%BD%E4%B8%96%E7%95%8C"));
        assert!(url.contains("speed=1"));
    }

    #[test]
    fn test_build_speak_url_short_placeholders() {
        let url = build_speak_url(
            "https://tts.example.com/api?a={{text}}&s={{speed}}",
            "hello world",
            1.5,
        );
        assert!(url.contains("a=hello%20world"));
        assert!(url.contains("s=1.5"));
    }

    #[test]
    fn test_build_speak_url_unknown_placeholder_preserved() {
        let url = build_speak_url("https://tts.example.com/{{voice}}", "x", 1.0);
        assert!(url.contains("{{voice}}"));
    }

    #[test]
    fn test_format_speed_int_and_decimal() {
        assert_eq!(format_speed(1.0), "1");
        assert_eq!(format_speed(2.0), "2");
        assert_eq!(format_speed(1.5), "1.5");
    }

    // ─── 缓存键 ──────────────────────────────────────────────

    #[test]
    fn test_cache_key_deterministic_and_unique() {
        let k1 = speak_cache_key("tpl", "text", 1.0);
        let k2 = speak_cache_key("tpl", "text", 1.0);
        assert_eq!(k1, k2);
        assert_ne!(k1, speak_cache_key("tpl", "text2", 1.0));
        assert_ne!(k1, speak_cache_key("tpl", "text", 2.0));
        assert_ne!(k1, speak_cache_key("tpl2", "text", 1.0));
    }

    #[test]
    fn test_cache_key_no_delimiter_collision() {
        // 评审修复回归：内容含分隔符时不同（模板，文本）组合不得同键
        //（旧实现 `a|b`+`c` 与 `a`+`b|c` 拼接同串导致碰撞）
        let k1 = speak_cache_key("a|b", "c", 1.0);
        let k2 = speak_cache_key("a", "b|c", 1.0);
        assert_ne!(k1, k2);
        // 键内不含 Windows 文件名非法字符
        assert!(!k1.contains('|'));
        assert!(!k2.contains('|'));
    }

    // ─── Content-Type 判定 ───────────────────────────────────

    #[test]
    fn test_ext_from_content_type() {
        assert_eq!(ext_from_content_type("audio/mpeg"), "mp3");
        assert_eq!(ext_from_content_type("audio/wav; charset=binary"), "wav");
        assert_eq!(ext_from_content_type("audio/x-m4a"), "m4a");
        assert_eq!(ext_from_content_type("application/octet-stream"), "mp3");
    }

    #[test]
    fn test_is_error_content_type() {
        assert!(is_error_content_type("application/json"));
        assert!(is_error_content_type("application/json; charset=utf-8"));
        assert!(is_error_content_type("text/html"));
        assert!(!is_error_content_type("audio/mpeg"));
        assert!(!is_error_content_type(""));
    }

    // ─── 缓存文件读写 ────────────────────────────────────────

    #[test]
    fn test_speak_cache_put_get_clear() {
        let dir = test_dir("cache");
        let cache = SpeakCache::new(dir.clone());
        assert!(cache.get("abc").is_none());

        let path = cache.put("abc", "mp3", b"ID3data").unwrap();
        assert!(path.exists());
        assert_eq!(cache.get("abc"), Some(path.clone()));

        // 空文件视为未命中
        let empty = dir.join("tts_emptykey.mp3");
        std::fs::write(&empty, b"").unwrap();
        assert!(cache.get("emptykey").is_none());

        // clear 删除所有 tts_ 前缀文件（含空文件）
        assert_eq!(cache.clear(), 2);
        assert!(cache.get("abc").is_none());
        std::fs::remove_dir_all(&dir).ok();
    }

    // ─── 合成管线（mock 网络）────────────────────────────────

    #[test]
    fn test_speak_text_fetch_and_cache_hit() {
        let dir = test_dir("pipeline");
        let template = "https://tts.example.com/api?text={{speakText}}";

        // 首次：缓存未命中，调用 fetch
        let mut fetched_url = String::new();
        let result = speak_text(template, "第一段", 1.0, &dir, |url| {
            fetched_url = url.to_string();
            Ok(SpeakResponse {
                status: 200,
                content_type: "audio/mpeg".into(),
                body: b"FAKE_MP3_BYTES".to_vec(),
            })
        })
        .unwrap();
        assert!(!result.from_cache);
        assert_eq!(result.content_type, "audio/mpeg");
        assert!(result.audio_path.exists());
        assert!(fetched_url.contains("text=%E7%AC%AC%E4%B8%80%E6%AE%B5"));
        assert_eq!(
            std::fs::read(&result.audio_path).unwrap(),
            b"FAKE_MP3_BYTES"
        );

        // 二次：缓存命中，fetch 不被调用（调用即 panic）
        let result2 = speak_text(template, "第一段", 1.0, &dir, |_| {
            panic!("缓存命中时不应发起网络请求");
        })
        .unwrap();
        assert!(result2.from_cache);
        assert_eq!(result2.audio_path, result.audio_path);
        assert_eq!(result2.content_type, "audio/mpeg");

        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_speak_text_json_error_body() {
        let dir = test_dir("json_err");
        let err = speak_text(
            "https://tts.example.com/{{speakText}}",
            "abc",
            1.0,
            &dir,
            |_| {
                Ok(SpeakResponse {
                    status: 200,
                    content_type: "application/json; charset=utf-8".into(),
                    body: r#"{"error":"余额不足"}"#.as_bytes().to_vec(),
                })
            },
        )
        .unwrap_err();
        let msg = err.to_string();
        assert!(msg.contains("余额不足"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_speak_text_bad_status_and_empty_body() {
        let dir = test_dir("bad_resp");
        let err = speak_text("tpl/{{text}}", "abc", 1.0, &dir, |_| {
            Ok(SpeakResponse {
                status: 500,
                content_type: "audio/mpeg".into(),
                body: vec![1, 2, 3],
            })
        })
        .unwrap_err();
        assert!(err.to_string().contains("500"));

        let err = speak_text("tpl/{{text}}", "abc", 1.0, &dir, |_| {
            Ok(SpeakResponse {
                status: 200,
                content_type: "audio/mpeg".into(),
                body: vec![],
            })
        })
        .unwrap_err();
        assert!(err.to_string().contains("空音频"));
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn test_speak_text_empty_text() {
        let dir = test_dir("empty_text");
        let err = speak_text("tpl/{{text}}", "   ", 1.0, &dir, |_| {
            panic!("空文本不应发起网络请求");
        })
        .unwrap_err();
        assert!(matches!(err, LegadoError::ContentEmpty(_)));
        std::fs::remove_dir_all(&dir).ok();
    }
}
