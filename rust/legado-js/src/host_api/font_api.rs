//! 字体 API（字体反爬 cmap 真实替换）
//!
//! 对应 Kotlin 端 `JsExtensions` 中的 queryTTF / replaceFont / queryBase64TTF 方法，
//! 以及 `AppCacheManager` 的 QueryTTF LRU 缓存语义。
//!
//! # 实现说明（方案 A：Rust 侧解析）
//!
//! 1. [`query_ttf`] 接收 URL / 本地文件路径 / Base64 字符串：
//!    - URL：先查本地磁盘缓存（目录同 TTS 缓存模式，文件名 = SHA-256(data)），
//!      未命中时经 legado-net 下载并落盘；
//!    - 文件：直接读取；Base64：解码。
//!
//!    解析成功后得到 [`crate::host_api::query_ttf::QueryTtf`]（cmap 与 glyf 轮廓签名），
//!    存入内存 LRU 缓存，并返回结构化 JSON 字体句柄。
//! 2. [`replace_font`] 与 Kotlin `replaceFont` 逐行对齐：
//!    错误字体中每个字符经 cmap 取 glyphId → glyf 轮廓签名 →
//!    在正确字体中以轮廓签名反查 unicode → 逐码点替换正文。
//!
//! # JS 契约
//!
//! 入参 / 出参与桩化实现完全一致：`queryTTF` 返回
//! `{"fontId":"...","type":"url|file|base64","data":"...","valid":bool}`，
//! `replaceFont(text, errorHandle, correctHandle, filter?)` 返回替换后文本；
//! 书源 JS 调用方式无需任何改动。
//!
//! # 本地路径策略（批21-B）
//!
//! `type=file` 分支读取本地文件，受 [`FsPolicy`] 约束：JS 注册层把
//! `SandboxConfig.allow_file_access` 派生为策略传入 `*_with_policy` 入口。
//! `allow_file_access=false`（书源生产路径）时仅允许引擎自建目录内的字体
//! 路径，越界返回 `valid=false` 且附 `error` 字段的句柄（显式拒绝）；
//! URL / Base64 分支不受影响（原版 Kotlin 也只支持这两种字符串形态）。
//! 本模块的 `query_ttf` / `replace_font` / `query_base64_ttf` 是**不受限**
//! 核心实现（Rust 侧调用 / 单测用），安全边界在 JS 注册层。

use std::path::PathBuf;
use std::sync::{Mutex, RwLock};

use crate::host_api::fs_policy::FsPolicy;
use crate::host_api::query_ttf::QueryTtf;

/// 内存 LRU 缓存容量（对应 Kotlin `AppCacheManager.queryTTFMap = LruCache(4)`）
const FONT_LRU_CAPACITY: usize = 4;

/// 句柄缓存容量（同 [`FONT_LRU_CAPACITY`]，对齐上游 `LruCache(4)`）
///
/// P2-3：句柄 JSON 必须回显完整 `data`——[`resolve_font`] 在解析缓存
/// 未命中时依赖它重新加载字体（JS 侧句柄只是字符串，无法持有解析对象，
/// 这是与上游返回 `QueryTTF` 对象的实现差异）。旧实现用无界 `HashMap`
/// 缓存句柄，逐章换字体的书源（常见反爬）会让进程内累积 N 份字体串；
/// 改为容量 4 的 LRU 后与上游 `AppCacheManager.queryTTFMap` 的内存上界
/// 一致，也保证 `data` 回显不会无限累积。
const HANDLE_LRU_CAPACITY: usize = FONT_LRU_CAPACITY;

/// 全局字体句柄缓存（font_id → 字体元数据 JSON，最近使用在前，容量 4）
static HANDLE_CACHE: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());

/// 已解析字体 LRU 缓存（font_id → QueryTtf，最近使用在前）
static FONT_LRU: Mutex<Vec<(String, QueryTtf)>> = Mutex::new(Vec::new());

/// 磁盘字体缓存目录（默认系统临时目录下 `legado_font_cache`，同 TTS 缓存模式）
static FONT_CACHE_DIR: RwLock<Option<PathBuf>> = RwLock::new(None);

/// 句柄 LRU 查询（命中时移到队首）
fn handle_cache_get(cache: &mut Vec<(String, String)>, key: &str) -> Option<String> {
    let idx = cache.iter().position(|(k, _)| k == key)?;
    let (_, handle) = cache.remove(idx);
    cache.insert(0, (key.to_string(), handle.clone()));
    Some(handle)
}

/// 句柄 LRU 写入（超容量淘汰最久未用）
fn handle_cache_put(cache: &mut Vec<(String, String)>, key: String, handle: String) {
    cache.retain(|(k, _)| k != &key);
    cache.insert(0, (key, handle));
    cache.truncate(HANDLE_LRU_CAPACITY);
}

/// 字体磁盘缓存目录（可按 TTS 缓存同模式覆写）
pub fn font_cache_dir() -> PathBuf {
    FONT_CACHE_DIR
        .read()
        .unwrap()
        .clone()
        .unwrap_or_else(|| std::env::temp_dir().join("legado_font_cache"))
}

/// 覆写字体磁盘缓存目录（测试 / 宿主注入）
pub fn set_font_cache_dir(path: PathBuf) {
    *FONT_CACHE_DIR.write().unwrap() = Some(path);
}

/// SHA-256 十六进制摘要（缓存 key，对齐 Kotlin `MessageDigest("SHA-256").toHexString()`）
fn sha256_hex(data: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    format!("{:x}", Sha256::digest(data))
}

/// LRU 查询（命中时移到队首）
fn lru_get(key: &str) -> Option<QueryTtf> {
    // QueryTtf 内部均为 HashMap，Clone 成本可接受；LRU 容量仅 4
    let mut guard = FONT_LRU.lock().unwrap();
    if let Some(idx) = guard.iter().position(|(k, _)| k == key) {
        let (_, v) = guard.remove(idx);
        let cloned = clone_query_ttf(&v);
        guard.insert(0, (key.to_string(), v));
        return Some(cloned);
    }
    None
}

/// LRU 写入（超容量淘汰最久未用）
fn lru_put(key: String, value: QueryTtf) {
    let mut guard = FONT_LRU.lock().unwrap();
    guard.retain(|(k, _)| k != &key);
    guard.insert(0, (key, value));
    guard.truncate(FONT_LRU_CAPACITY);
}

/// QueryTtf 深拷贝（LRU 取出副本，避免持锁返回）
fn clone_query_ttf(ttf: &QueryTtf) -> QueryTtf {
    // QueryTtf 仅含三个 HashMap，克隆成本可接受（LRU 容量 4）
    ttf.clone()
}

/// 判断 data 类型（与原桩化实现一致的判定规则）
///
/// 注意：Windows 盘符判断用字节下标（`as_bytes().get(1)`），不能用
/// `data[1..]` 切片——首字符为多字节 UTF-8（如 `queryTTF("中文")`）时
/// 字节 1 不在字符边界上会 panic（批21-B 回修 P3）。
fn classify(data: &str) -> &'static str {
    let bytes = data.as_bytes();
    if data.starts_with("http://") || data.starts_with("https://") {
        "url"
    } else if data.starts_with('/')
        || data.starts_with("file://")
        || (bytes.get(1) == Some(&b':') && bytes.get(2) == Some(&b'\\'))
    {
        "file"
    } else {
        "base64"
    }
}

/// queryTTF(data, useCache?) → 字体查询句柄 JSON
///
/// 对应 Kotlin: `queryTTF(data: Any?, useCache: Boolean): QueryTTF?`
///
/// `data` 支持 URL / 本地文件路径 / Base64 字符串（自动判断）。
/// 返回 JSON 句柄，供 `replaceFont` 使用；若 data 为空则返回 "null"；
/// 字体获取或解析失败时返回 `valid=false` 的句柄（调用端 replaceFont 将降级返回原文）。
///
/// 返回格式：
/// ```json
/// {"fontId":"...","type":"url|file|base64","data":"...","valid":true}
/// ```
///
/// 本函数为**不受限**核心实现（Rust 侧调用 / 单测）；JS 注册层使用
/// [`query_ttf_with_policy`]，按 `allow_file_access` 收紧本地文件路径。
pub fn query_ttf(data: &str, use_cache: bool) -> String {
    query_ttf_with_policy(data, use_cache, FsPolicy::unrestricted())
}

/// queryTTF 的带路径策略变体（JS 宿主绑定入口）
///
/// 策略先于缓存生效：受限引擎不会因宽松引擎（如测试/permissive 配置）
/// 先前缓存过同一路径的句柄而绕过白名单。
pub fn query_ttf_with_policy(data: &str, use_cache: bool, policy: FsPolicy) -> String {
    if data.is_empty() {
        return "null".to_string();
    }

    // 缓存 key：SHA-256(data)，对齐 Kotlin
    let cache_key = sha256_hex(data.as_bytes());
    let font_type = classify(data);

    // 本地文件路径先过白名单（在缓存命中之前，避免宽松引擎先缓存的同串
    // 句柄让受限引擎命中 valid=true）。
    // 必须先剥 `file://` 前缀再校验：`Path::new("file://C:/x")` 在 Windows
    // 不是绝对路径，会作为相对路径拼进沙箱而"恒通过"预检（批21-B 回修 P2）。
    if font_type == "file" {
        let path = data.strip_prefix("file://").unwrap_or(data);
        if let Err(e) = policy.resolve_read_path(path) {
            return policy_rejected_handle(&cache_key, font_type, data, e);
        }
    }

    // 检查句柄缓存（对齐 Kotlin AppCacheManager.getQueryTTF）
    if use_cache {
        let mut guard = HANDLE_CACHE.lock().unwrap();
        if let Some(cached) = handle_cache_get(&mut guard, &cache_key) {
            return cached;
        }
    }

    // 加载字体二进制：磁盘缓存 → 下载 / 读文件 / base64 解码
    let font_bytes = load_font_bytes(data, font_type, &cache_key, policy);
    let (font_bytes, valid) = match font_bytes {
        Ok(bytes) => (Some(bytes), true),
        Err(_) => (None, false),
    };

    // 解析字体（cmap + glyf 轮廓签名）
    let parsed = font_bytes
        .as_ref()
        .and_then(|bytes| QueryTtf::parse(bytes).ok());

    let handle = serde_json::json!({
        "fontId": cache_key,
        "type": font_type,
        "data": data,
        "valid": valid && parsed.is_some()
    })
    .to_string();

    // 写入缓存（对齐 Kotlin：key != null 时 put；句柄与解析结果同为容量 4 的 LRU）
    if use_cache && parsed.is_some() {
        if let Some(ttf) = parsed {
            lru_put(cache_key.clone(), ttf);
        }
        let mut guard = HANDLE_CACHE.lock().unwrap();
        handle_cache_put(&mut guard, cache_key, handle.clone());
    }

    handle
}

/// 路径策略拒绝时返回的句柄 JSON（显式错误，不静默）
///
/// 保持既有四字段形状并追加 `error`（additive，调用端可忽略）。
fn policy_rejected_handle(font_id: &str, font_type: &str, data: &str, error: String) -> String {
    eprintln!("[queryTTF] {error}");
    serde_json::json!({
        "fontId": font_id,
        "type": font_type,
        "data": data,
        "valid": false,
        "error": error
    })
    .to_string()
}

/// 加载字体二进制（URL 走磁盘缓存 + legado-net 下载，file 直接读取，base64 解码）
fn load_font_bytes(
    data: &str,
    font_type: &str,
    cache_key: &str,
    policy: FsPolicy,
) -> Result<Vec<u8>, String> {
    match font_type {
        "url" => {
            let cache_path = font_cache_dir().join(format!("{}.ttf", cache_key));
            // 已缓存直接用（对齐 TTS 缓存模式）
            if let Ok(bytes) = std::fs::read(&cache_path) {
                if !bytes.is_empty() {
                    return Ok(bytes);
                }
            }
            let bytes = download_font(data)?;
            // 下载成功落盘缓存（失败忽略）
            if !bytes.is_empty() {
                let _ = std::fs::create_dir_all(font_cache_dir());
                let _ = std::fs::write(&cache_path, &bytes);
            }
            Ok(bytes)
        }
        "file" => {
            let path = data.strip_prefix("file://").unwrap_or(data);
            // 受限模式：仅允许引擎沙箱/字体缓存目录内的路径
            let resolved = policy.resolve_read_path(path)?;
            std::fs::read(resolved).map_err(|e| format!("read font file error: {}", e))
        }
        _ => {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD
                .decode(data.trim())
                .map_err(|e| format!("base64 font decode error: {}", e))
        }
    }
}

/// 通过 legado-net 下载字体（仅 quickjs 构建可用；其余构建降级为失败）
#[cfg(feature = "quickjs")]
fn download_font(url: &str) -> Result<Vec<u8>, String> {
    use crate::host_api::runtime_bridge::block_on;

    block_on(async {
        // 进程级共享池（2026-09-24 性能专项：不再每下载新建客户端/连接池；
        // 回环 URL 经 no_proxy 直连池）
        let client = crate::host_api::network::shared_client_for_url(url)
            .map_err(|e| format!("build client error: {}", e))?;
        // 字体为二进制资源，用 get_raw 避免 UTF-8 有损转换
        let resp = client
            .get_raw(url, None)
            .await
            .map_err(|e| format!("download font error: {}", e))?;
        if !resp.is_success() {
            return Err(format!("download font http status {}", resp.status));
        }
        Ok(resp.body)
    })
}

#[cfg(not(feature = "quickjs"))]
fn download_font(_url: &str) -> Result<Vec<u8>, String> {
    Err("font download requires quickjs feature".to_string())
}

/// queryBase64TTF(data) → 字体查询句柄 JSON（已废弃，等价于 queryTTF）
///
/// 对应 Kotlin: `@Deprecated queryBase64TTF(data: String?): QueryTTF?`
/// Kotlin 端已标注废弃，建议改用 `queryTTF`；此处保留兼容性。
pub fn query_base64_ttf(data: &str) -> String {
    query_ttf(data, true)
}

/// queryBase64TTF 的带路径策略变体（JS 宿主绑定入口）
pub fn query_base64_ttf_with_policy(data: &str, policy: FsPolicy) -> String {
    query_ttf_with_policy(data, true, policy)
}

/// replaceFont(text, errorFontData, correctFontData, filter?) → 替换后文本
///
/// 对应 Kotlin: `replaceFont(text, errorQueryTTF, correctQueryTTF, filter): String`
///
/// 逐码点处理（对齐 `text.toStringArray()` 的多字节码点语义）：
/// 1. 空白字符（`isBlankUnicode` 白名单）跳过；
/// 2. 取错误字体的轮廓签名；glyphId 为 0 时视为无轮廓；
/// 3. `filter=true` 且轮廓不存在 → 删除该字符；
/// 4. 以轮廓签名在正确字体反查 unicode，命中则替换。
pub fn replace_font(
    text: &str,
    error_font_data: &str,
    correct_font_data: &str,
    filter: bool,
) -> String {
    replace_font_with_policy(
        text,
        error_font_data,
        correct_font_data,
        filter,
        FsPolicy::unrestricted(),
    )
}

/// replaceFont 的带路径策略变体（JS 宿主绑定入口）
///
/// `filter` / 句柄语义与 [`replace_font`] 完全一致；额外约束：句柄
/// `type=file` 时按策略校验路径（防伪造句柄绕过 `queryTTF` 白名单再读文件）。
pub fn replace_font_with_policy(
    text: &str,
    error_font_data: &str,
    correct_font_data: &str,
    filter: bool,
    policy: FsPolicy,
) -> String {
    // 任一句柄为空或 null 时直接返回原文
    if error_font_data.is_empty()
        || error_font_data == "null"
        || correct_font_data.is_empty()
        || correct_font_data == "null"
    {
        return text.to_string();
    }

    // 尝试解析句柄 JSON，验证有效性
    let error_valid = serde_json::from_str::<serde_json::Value>(error_font_data)
        .map(|v| v.get("valid").and_then(|b| b.as_bool()).unwrap_or(false))
        .unwrap_or(false);

    let correct_valid = serde_json::from_str::<serde_json::Value>(correct_font_data)
        .map(|v| v.get("valid").and_then(|b| b.as_bool()).unwrap_or(false))
        .unwrap_or(false);

    if !error_valid || !correct_valid {
        return text.to_string();
    }

    // 取得两个已解析字体（LRU 命中优先，否则按句柄重新加载）
    let (Some(error_font), Some(correct_font)) = (
        resolve_font(error_font_data, policy),
        resolve_font(correct_font_data, policy),
    ) else {
        // 任一字体不可用：降级返回原文（对应 Kotlin 端 null 句柄分支）
        return text.to_string();
    };

    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        let code = ch as u32;
        // 忽略正常的空白字符
        if QueryTtf::is_blank_unicode(code) {
            out.push(ch);
            continue;
        }
        // 轮廓签名（错误字体）；glyphId 指向保留索引 0 时视为无轮廓
        let mut glyf = error_font.glyf_by_unicode(code).cloned();
        if error_font.glyf_id_by_unicode(code) == 0 {
            glyf = None;
        }
        if filter && glyf.is_none() {
            // 删除轮廓数据不存在的字符
            continue;
        }
        // 使用轮廓签名在正确字体反查 unicode
        if let Some(sig) = &glyf {
            let new_code = correct_font.unicode_by_glyf(sig);
            if new_code != 0 {
                if let Some(new_ch) = char::from_u32(new_code) {
                    out.push(new_ch);
                    continue;
                }
            }
        }
        // 无映射的字符保留原样
        out.push(ch);
    }
    out
}

/// 从句柄 JSON 还原已解析字体：LRU 命中优先，否则按 type/data 重新加载解析
fn resolve_font(handle_json: &str, policy: FsPolicy) -> Option<QueryTtf> {
    let handle: serde_json::Value = serde_json::from_str(handle_json).ok()?;
    let font_id = handle.get("fontId")?.as_str()?;

    if let Some(ttf) = lru_get(font_id) {
        return Some(ttf);
    }

    let data = handle.get("data")?.as_str()?;
    let font_type = handle.get("type")?.as_str()?;
    let bytes = load_font_bytes(data, font_type, font_id, policy).ok()?;
    let ttf = QueryTtf::parse(&bytes).ok()?;
    lru_put(font_id.to_string(), clone_query_ttf(&ttf));
    Some(ttf)
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// cmap format 4 段描述（测试夹具用）
    pub struct Segment {
        pub start: u16,
        pub end: u16,
        pub id_delta: i16,
    }

    fn be16(v: u16) -> [u8; 2] {
        v.to_be_bytes()
    }

    fn be32(v: u32) -> [u8; 4] {
        v.to_be_bytes()
    }

    /// 构造 cmap 表（format 4，单平台记录）
    pub fn build_format4_cmap(segments: &[Segment]) -> Vec<u8> {
        let seg_count = segments.len() + 1; // 附加终止段 [0xFFFF, 0xFFFF]
        let mut sub = Vec::new();
        sub.extend_from_slice(&be16(4)); // format
        let length = 16 + seg_count * 8;
        sub.extend_from_slice(&be16(length as u16));
        sub.extend_from_slice(&be16(0)); // language
        sub.extend_from_slice(&be16((seg_count * 2) as u16)); // segCountX2
        sub.extend_from_slice(&be16(0)); // searchRange
        sub.extend_from_slice(&be16(0)); // entrySelector
        sub.extend_from_slice(&be16(0)); // rangeShift
        for seg in segments {
            sub.extend_from_slice(&be16(seg.end));
        }
        sub.extend_from_slice(&be16(0xFFFF));
        sub.extend_from_slice(&be16(0)); // reservedPad
        for seg in segments {
            sub.extend_from_slice(&be16(seg.start));
        }
        sub.extend_from_slice(&be16(0xFFFF));
        for seg in segments {
            sub.extend_from_slice(&seg.id_delta.to_be_bytes());
        }
        sub.extend_from_slice(&be16(1)); // 终止段 delta
        for _ in 0..seg_count {
            sub.extend_from_slice(&be16(0)); // idRangeOffset 全 0
        }

        let mut cmap = Vec::new();
        cmap.extend_from_slice(&be16(0)); // version
        cmap.extend_from_slice(&be16(1)); // numTables
        cmap.extend_from_slice(&be16(3)); // platformID = Windows
        cmap.extend_from_slice(&be16(1)); // encodingID = Unicode BMP
        cmap.extend_from_slice(&be32(12)); // subtable offset
        cmap.extend_from_slice(&sub);
        cmap
    }

    /// 简单字形轮廓数据（3 点三角，坐标随变体区分）
    fn simple_glyph_bytes(variant: u8) -> Vec<u8> {
        let mut g = Vec::new();
        g.extend_from_slice(&be16(1)); // numberOfContours
        g.extend_from_slice(&be16(0)); // xMin
        g.extend_from_slice(&be16(0)); // yMin
        g.extend_from_slice(&be16(10)); // xMax
        g.extend_from_slice(&be16(10)); // yMax
        g.extend_from_slice(&be16(2)); // endPtsOfContours = [2]
        g.extend_from_slice(&be16(0)); // instructionLength
                                       // flags：3 点，短向量正号（x: 0x12, y: 0x24）
        g.extend_from_slice(&[0x12 | 0x24, 0x12 | 0x24, 0x12 | 0x24]);
        let d = variant;
        g.extend_from_slice(&[1 + d, 2 + d, 3 + d]); // x 增量
        g.extend_from_slice(&[4 + d, 5 + d, 6 + d]); // y 增量
        g
    }

    /// 复合字形数据（引用 glyph 3，单组件无缩放）
    fn composite_glyph_bytes() -> Vec<u8> {
        let mut g = Vec::new();
        g.extend_from_slice(&0xFFFFu16.to_be_bytes()); // numberOfContours = -1
        g.extend_from_slice(&be16(0)); // xMin
        g.extend_from_slice(&be16(0)); // yMin
        g.extend_from_slice(&be16(10)); // xMax
        g.extend_from_slice(&be16(10)); // yMax
        g.extend_from_slice(&be16(0b01)); // flags：16 位无符号参数，无后续组件
        g.extend_from_slice(&be16(3)); // glyphIndex
        g.extend_from_slice(&be16(2)); // arg1
        g.extend_from_slice(&be16(3)); // arg2
        g
    }

    /// 构造最小可用 TTF（head / maxp / cmap / loca / glyf / name）
    ///
    /// - glyph 0：.notdef（空）
    /// - glyph 1：`composite=true` 时为复合字形，否则为变体 0 简单字形
    /// - glyph 2/3：变体 1/2 简单字形（glyph 3 同时作为复合组件引用目标）
    /// - cmap 段由 `segments` 指定
    pub fn build_minimal_ttf(segments: &[Segment], composite: bool) -> Vec<u8> {
        let cmap = build_format4_cmap(segments);

        // glyf：glyph0 空、glyph1、glyph2、glyph3（字形数据需偶数对齐，loca Offset16 才不截断）
        let g1 = if composite {
            composite_glyph_bytes()
        } else {
            let mut g = simple_glyph_bytes(0);
            if !g.len().is_multiple_of(2) {
                g.push(0);
            }
            g
        };
        let mut g2 = simple_glyph_bytes(1);
        if !g2.len().is_multiple_of(2) {
            g2.push(0);
        }
        let mut g3 = simple_glyph_bytes(2);
        if !g3.len().is_multiple_of(2) {
            g3.push(0);
        }
        let off1 = 0usize;
        let off2 = off1 + g1.len();
        let off3 = off2 + g2.len();
        let off_end = off3 + g3.len();
        let mut glyf = Vec::new();
        glyf.extend_from_slice(&g1);
        glyf.extend_from_slice(&g2);
        glyf.extend_from_slice(&g3);

        // loca（Offset16，值需 /2 存储；glyph0 无数据：0,0）
        let mut loca = Vec::new();
        for &off in &[0usize, off1 / 2, off2 / 2, off3 / 2, off_end / 2] {
            loca.extend_from_slice(&be16(off as u16));
        }

        // head（54 字节）
        let mut head = vec![0u8; 54];
        head[0..4].copy_from_slice(&be32(0x00010000)); // sfntVersion
        head[12..16].copy_from_slice(&be32(0x5F0F3CF5)); // magicNumber
        head[16..18].copy_from_slice(&be16(0)); // flags
        head[18..20].copy_from_slice(&be16(1000)); // unitsPerEm
        head[36..38].copy_from_slice(&be16(10)); // xMax
        head[38..40].copy_from_slice(&be16(10)); // yMax
        head[50..52].copy_from_slice(&be16(0)); // indexToLocFormat = Offset16

        // maxp
        let mut maxp = Vec::new();
        maxp.extend_from_slice(&be32(0x00010000)); // version
        maxp.extend_from_slice(&be16(4)); // numGlyphs
        maxp.extend_from_slice(&be16(3)); // maxPoints
        maxp.extend_from_slice(&be16(1)); // maxContours
        maxp.extend_from_slice(&[0u8; 22]); // 其余字段置 0

        // name（空记录）
        let mut name = Vec::new();
        name.extend_from_slice(&be16(0)); // format
        name.extend_from_slice(&be16(0)); // count
        name.extend_from_slice(&be16(6)); // stringOffset

        // 组装：表按 tag 字母序（cmap, glyf, head, loca, maxp, name）
        let entries: [(&[u8; 4], &Vec<u8>); 6] = [
            (b"cmap", &cmap),
            (b"glyf", &glyf),
            (b"head", &head),
            (b"loca", &loca),
            (b"maxp", &maxp),
            (b"name", &name),
        ];
        let header_len = 12 + entries.len() * 16;
        let mut offset = header_len;
        let mut offsets: Vec<usize> = Vec::new();
        for (_, data) in &entries {
            offsets.push(offset);
            offset += (data.len() + 3) & !3; // 4 字节对齐
        }

        let mut out = Vec::new();
        out.extend_from_slice(&be32(0x00010000)); // sfntVersion
        out.extend_from_slice(&be16(entries.len() as u16)); // numTables
        out.extend_from_slice(&be16(0)); // searchRange
        out.extend_from_slice(&be16(0)); // entrySelector
        out.extend_from_slice(&be16(0)); // rangeShift
        for (i, (tag, data)) in entries.iter().enumerate() {
            out.extend_from_slice(*tag);
            out.extend_from_slice(&be32(0)); // checkSum（解析不校验）
            out.extend_from_slice(&be32(offsets[i] as u32));
            out.extend_from_slice(&be32(data.len() as u32));
        }
        for (i, (_, data)) in entries.iter().enumerate() {
            out.extend_from_slice(data);
            let pad = (4 - (data.len() % 4)) % 4;
            out.extend_from_slice(&vec![0u8; pad]);
            debug_assert_eq!(out.len(), offsets[i] + ((data.len() + 3) & !3));
        }
        out
    }

    /// 错误字体 base64（PUA E001..E003 → glyph 1..3，delta 取模运算正值）
    fn error_font_b64() -> String {
        use base64::Engine;
        let font = build_minimal_ttf(
            &[Segment {
                start: 0xE001,
                end: 0xE003,
                id_delta: 0x2000, // E001 + 0x2000 = 0x10001，& 0xFFFF = 1
            }],
            false,
        );
        base64::engine::general_purpose::STANDARD.encode(&font)
    }

    /// 正确字体 base64（'A'..='C' → glyph 1..3）
    fn correct_font_b64() -> String {
        use base64::Engine;
        let font = build_minimal_ttf(
            &[Segment {
                start: 0x41,
                end: 0x43,
                id_delta: -0x40,
            }],
            false,
        );
        base64::engine::general_purpose::STANDARD.encode(&font)
    }

    #[test]
    fn test_query_ttf_empty() {
        assert_eq!(query_ttf("", true), "null");
    }

    #[test]
    fn test_query_ttf_base64_real_font() {
        let result = query_ttf(&error_font_b64(), false);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "base64");
        assert_eq!(parsed["valid"], true);
    }

    #[test]
    fn test_query_ttf_base64_invalid() {
        let result = query_ttf("AAECAwQF", false);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "base64");
        assert_eq!(parsed["valid"], false);
    }

    #[test]
    fn test_query_ttf_file_real_font() {
        // 写入临时文件后以路径加载
        let dir = std::env::temp_dir().join(format!("legado_font_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fixture.ttf");
        std::fs::write(
            &path,
            build_minimal_ttf(
                &[Segment {
                    start: 0x41,
                    end: 0x41,
                    id_delta: -0x40,
                }],
                false,
            ),
        )
        .unwrap();
        let result = query_ttf(path.to_str().unwrap(), false);
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["type"], "file");
        assert_eq!(parsed["valid"], true);
    }

    #[test]
    fn test_query_ttf_cache_hit() {
        // 相同 data 使用缓存应返回相同句柄且不重复解析
        let b64 = error_font_b64();
        let r1 = query_ttf(&b64, true);
        let r2 = query_ttf(&b64, true);
        assert_eq!(r1, r2);
        let parsed: serde_json::Value = serde_json::from_str(&r1).unwrap();
        assert_eq!(parsed["valid"], true);
    }

    #[test]
    fn test_handle_cache_lru_capacity() {
        // P2-3 回归锁：句柄缓存必须与上游 LruCache(4) 同容量，逐章换字体
        // 不得让进程内累积任意多份句柄（含完整 data 回显）。
        let mut cache = Vec::new();
        for i in 0..6 {
            handle_cache_put(&mut cache, format!("k{i}"), format!("handle-{i}"));
        }
        assert_eq!(cache.len(), HANDLE_LRU_CAPACITY);
        // 最近写入的在前，最久未用的 k0/k1 被淘汰
        assert_eq!(cache[0].0, "k5");
        assert!(cache.iter().all(|(k, _)| k != "k0" && k != "k1"));

        // 命中刷新顺序：k2 命中后移到队首，再写入 k6 淘汰队尾 k3
        assert_eq!(
            handle_cache_get(&mut cache, "k2"),
            Some("handle-2".to_string())
        );
        assert_eq!(cache[0].0, "k2");
        handle_cache_put(&mut cache, "k6".to_string(), "handle-6".to_string());
        assert_eq!(cache.len(), HANDLE_LRU_CAPACITY);
        assert!(cache.iter().all(|(k, _)| k != "k3"));
        assert_eq!(cache[0].0, "k6");

        // 未命中不改变缓存
        assert_eq!(handle_cache_get(&mut cache, "missing"), None);
        assert_eq!(cache.len(), HANDLE_LRU_CAPACITY);
    }

    #[test]
    fn test_query_base64_ttf() {
        let result = query_base64_ttf(&correct_font_b64());
        let parsed: serde_json::Value = serde_json::from_str(&result).unwrap();
        assert_eq!(parsed["valid"], true);
    }

    #[test]
    fn test_replace_font_null_handles() {
        assert_eq!(replace_font("hello", "null", "null", false), "hello");
        assert_eq!(replace_font("hello", "", "", false), "hello");
    }

    #[test]
    fn test_replace_font_real_mapping() {
        // \uE001\uE002\uE003 → ABC（轮廓签名跨字体对齐）
        let err = query_ttf(&error_font_b64(), true);
        let ok = query_ttf(&correct_font_b64(), true);
        let text = "\u{E001}\u{E002}\u{E003}尾部";
        assert_eq!(replace_font(text, &err, &ok, false), "ABC尾部");
    }

    #[test]
    fn test_replace_font_multi_char_codepoint() {
        // 多字节码点（中文）不参与映射时保留原样，验证逐码点而非逐字节处理
        let err = query_ttf(&error_font_b64(), true);
        let ok = query_ttf(&correct_font_b64(), true);
        assert_eq!(replace_font("第一章\u{E001}", &err, &ok, false), "第一章A");
    }

    #[test]
    fn test_replace_font_unmapped_kept() {
        // 错误字体中不存在的字符保留原样
        let err = query_ttf(&error_font_b64(), true);
        let ok = query_ttf(&correct_font_b64(), true);
        assert_eq!(replace_font("XYZ", &err, &ok, false), "XYZ");
    }

    #[test]
    fn test_replace_font_filter_removes_unmapped() {
        // filter=true：错误字体中无轮廓的字符被删除
        let err = query_ttf(&error_font_b64(), true);
        let ok = query_ttf(&correct_font_b64(), true);
        let text = "\u{E001}杂\u{E002}";
        assert_eq!(replace_font(text, &err, &ok, true), "AB");
    }

    #[test]
    fn test_replace_font_blank_kept() {
        // 空白字符原样保留（不参与替换/filter）
        let err = query_ttf(&error_font_b64(), true);
        let ok = query_ttf(&correct_font_b64(), true);
        let text = "\u{E001} \u{E002}";
        assert_eq!(replace_font(text, &err, &ok, true), "A B");
    }

    #[test]
    fn test_replace_font_invalid_handle_degrades() {
        // 无效句柄（valid=false）降级返回原文
        let err = query_ttf("AAECAwQF", false);
        let ok = query_ttf(&correct_font_b64(), true);
        assert_eq!(replace_font("hello", &err, &ok, false), "hello");
    }

    #[test]
    fn test_font_disk_cache_roundtrip() {
        // URL 分支的磁盘缓存逻辑（直接调用 load_font_bytes 的缓存路径）
        let dir =
            std::env::temp_dir().join(format!("legado_font_cache_test_{}", std::process::id()));
        set_font_cache_dir(dir.clone());
        let key = sha256_hex(b"https://cached.example.com/font.ttf");
        let cache_path = dir.join(format!("{}.ttf", key));
        std::fs::create_dir_all(&dir).unwrap();
        let font = build_minimal_ttf(
            &[Segment {
                start: 0x41,
                end: 0x43,
                id_delta: -0x40,
            }],
            false,
        );
        std::fs::write(&cache_path, &font).unwrap();
        // 磁盘缓存命中：不触发网络下载
        let bytes = load_font_bytes(
            "https://cached.example.com/font.ttf",
            "url",
            &key,
            FsPolicy::unrestricted(),
        )
        .unwrap();
        assert_eq!(bytes, font);
        // 清理
        let _ = std::fs::remove_file(&cache_path);
    }

    #[test]
    fn test_classify_multibyte_first_char_no_panic() {
        // P3：首字符为多字节 UTF-8 时不得因 `data[1..]` 非字符边界 panic
        assert_eq!(classify("中文"), "base64");
        assert_eq!(classify("é"), "base64");
        let handle = query_ttf("中文", false);
        let parsed: serde_json::Value = serde_json::from_str(&handle).unwrap();
        assert_eq!(parsed["type"], "base64");
        assert_eq!(parsed["valid"], false);
    }

    #[test]
    fn test_classify_file_forms() {
        assert_eq!(classify("file:///tmp/x.ttf"), "file");
        assert_eq!(classify("/tmp/x.ttf"), "file");
        assert_eq!(classify(r"C:\fonts\x.ttf"), "file");
        assert_eq!(classify("https://e.com/x.ttf"), "url");
    }

    #[test]
    fn test_query_ttf_restricted_rejects_outside_file() {
        // 受限策略：沙箱外字体路径 → valid=false + error（显式拒绝，不静默）
        let dir = std::env::temp_dir().join(format!(
            "legado_font_policy_deny_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("demoted.ttf");
        std::fs::write(&path, b"not-a-real-font").unwrap();

        let handle = query_ttf_with_policy(path.to_str().unwrap(), false, FsPolicy::restricted());
        let parsed: serde_json::Value = serde_json::from_str(&handle).unwrap();
        assert_eq!(parsed["type"], "file");
        assert_eq!(parsed["valid"], false);
        assert!(
            parsed["error"]
                .as_str()
                .unwrap_or("")
                .contains("文件访问被拒绝"),
            "handle = {handle}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn test_query_ttf_restricted_allows_font_cache_file() {
        // 受限策略：引擎字体缓存目录内的字体仍可读（能力保留）
        let dir = font_cache_dir().join(format!(
            "policy_allow_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fixture.ttf");
        std::fs::write(
            &path,
            build_minimal_ttf(
                &[Segment {
                    start: 0x41,
                    end: 0x41,
                    id_delta: -0x40,
                }],
                false,
            ),
        )
        .unwrap();

        let handle = query_ttf_with_policy(path.to_str().unwrap(), false, FsPolicy::restricted());
        let parsed: serde_json::Value = serde_json::from_str(&handle).unwrap();
        assert_eq!(parsed["type"], "file");
        assert_eq!(parsed["valid"], true);
        assert!(parsed.get("error").is_none(), "handle = {handle}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
