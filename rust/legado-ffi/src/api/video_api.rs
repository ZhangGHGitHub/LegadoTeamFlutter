//! 视频弹幕数据链（V-B1，契约 §2.49）
//!
//! 把书源内容规则副内容（`contentRule.subContent`）从「抓到即丢」接通到
//! 「捕获 → 落库 → 查询」，对齐原版弹幕链：
//! - 写入侧（**不上 FFI**）：抓取链媒体分支经 `FetcherDeps` 的
//!   `media_sub_content` sink 调用 [`put_media_sub_content`]，
//!   按 Kotlin `RuleDataInterface.putVariable` 语义分流——
//!   `<10000` 字符进 `chapters.variable` 列（JSON 键 `danmaku`/`lyric`）、
//!   `≥10000` 走 `RuleBigDataHelp` 大数据文件（本项目复用
//!   `legado-db::rule_big_data::RuleBigDataManager`，与原版同根同构）；
//! - 查询面（FFI `ffi::get_video_danmaku`，契约 §2.49）：
//!   章节 variable 直读（Inline）→ 大数据文件读回（File）→ `null`（None），
//!   与 `video_state::DanmakuSource` 三态一一对应（休眠资产激活）。
//!
//! # 存储选型（与原版的对应关系）
//!
//! 原版 `BookChapter.putDanmaku` 落 Room `chapters.variable` 列（JSON
//! 字符串）；本项目 `chapters` 表同名同列（schema.rs `variable TEXT`），
//! 由 `BookChapterRepository::update_variable` 单列更新。原版 ≥10000 字符
//! 分支落 `externalFiles/ruleData/book/{md5_32(bookUrl)}/{md5_32(chapterUrl)}/
//! {md5_32("danmaku")}.txt`（`RuleBigDataHelp.kt:174-209`，`putChapterVariable`
//! 另写书级 `bookUrl.txt` 标记）；本项目 `RuleBigDataManager` 目录形状与
//! md5_32 口径逐行一致（`rule_big_data.rs` 移植自同文件），仅**根目录**
//! 解析不同：原版 `appCtx.externalFiles`，本项目未新增注入方法（契约冻结
//! 292 方法），按「env `LEGADO_RULE_DATA_DIR` > DB 文件父目录（App Documents）
//! /ruleData > 系统 temp 回落」解析——DB 父目录即 `legado.db` 所在持久目录，
//! 语义上对齐原版 externalFiles（非 cache 目录，不被系统清理）。
//!
//! # 失败语义
//!
//! 查询与写入一律**降级**：查询异常返回 `None` 不抛（弹幕是增强层不是数据源，
//! 对齐 §2.46 口径）；写入失败仅记日志不阻断正文返回（对齐原版 `runCatching`
//! 与 `putDanmaku` 的非致命语义）。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

use legado_core::models::BookChapter;
use legado_core::video_state::{DanmakuSource, VideoPlayerState};
use legado_core::LegadoError;
use legado_db::rule_big_data::RuleBigDataManager;
use legado_db::BookChapterRepository;

use crate::db_state::with_database;

/// 视频弹幕在章节 variable / 大数据文件名中的键（对齐原版 putDanmaku）
pub const DANMAKU_KEY: &str = "danmaku";
/// 音频歌词在章节 variable 中的键（对齐原版 putLyric，写侧与弹幕同链分流）
pub const LYRIC_KEY: &str = "lyric";

/// 规则数据根目录环境变量（测试隔离用；优先级最高）
pub const RULE_DATA_DIR_ENV: &str = "LEGADO_RULE_DATA_DIR";
/// 规则数据子目录名（对齐原版 `RuleBigDataHelp.ruleDataDir` 名）
const RULE_DATA_DIR_NAME: &str = "ruleData";
/// 大数据分流阈值（对齐 Kotlin `RuleDataInterface.putVariable` 的 10000）
const LARGE_VALUE_THRESHOLD: usize = 10000;

/// 系统 temp 回落一次性告警（对齐 image_cache / cache_store 先例）
static TEMP_FALLBACK_WARNED: AtomicBool = AtomicBool::new(false);

/// 解析规则数据根目录（写入侧与查询侧共用，同根同键）
///
/// 优先级：env [`RULE_DATA_DIR_ENV`] > DB 文件父目录（App Documents）
/// /ruleData > 系统 temp 目录（一次性告警；宿主未 `db_open` 时的测试/异常路径）。
pub fn rule_data_dir() -> PathBuf {
    if let Ok(dir) = std::env::var(RULE_DATA_DIR_ENV) {
        let dir = dir.trim();
        if !dir.is_empty() {
            return PathBuf::from(dir);
        }
    }
    if let Some(db_path) = crate::db_state::current_db_path() {
        if let Some(parent) = Path::new(&db_path).parent() {
            if !parent.as_os_str().is_empty() {
                return parent.join(RULE_DATA_DIR_NAME);
            }
        }
    }
    if !TEMP_FALLBACK_WARNED.swap(true, Ordering::Relaxed) {
        log::warn!(
            "[video_danmaku] 规则数据目录未解析到 DB 父目录（db_open 前调用？）——\
             回落系统临时目录 {:?}（弹幕大数据随系统 temp 清理而丢失）",
            std::env::temp_dir().join("legado-rule-data")
        );
    }
    std::env::temp_dir().join("legado-rule-data")
}

/// 按当前根目录构造大数据管理器（目录不存在时由管理器创建）
fn big_data_manager() -> RuleBigDataManager {
    RuleBigDataManager::new(&rule_data_dir())
}

/// Kotlin `String.length` 口径：UTF-16 码元数（`RuleDataInterface.putVariable`
/// 的 `< 10000` 判定原版按 UTF-16 计，含 CJK 时必须按此口径，不能按字节数）
fn kotlin_str_len(s: &str) -> usize {
    s.encode_utf16().count()
}

/// 从章节 variable JSON 中读取字符串键（非 JSON / 非字符串值 → None）
fn inline_variable_value(variable: Option<&str>, key: &str) -> Option<String> {
    let raw = variable?.trim();
    if raw.is_empty() {
        return None;
    }
    let map: serde_json::Value = serde_json::from_str(raw).ok()?;
    map.get(key)?.as_str().map(str::to_string)
}

/// 查询某章弹幕数据（契约 §2.49，**只读、幂等**）
///
/// 读章节 variable 列 `danmaku` 键（Inline）→ 大数据文件读回（File）→
/// `None`。书/章不在 DB、无记录、读失败一律降级 `None`（不抛）。
pub fn get_video_danmaku(book_url: &str, chapter_index: i32) -> Option<String> {
    if book_url.trim().is_empty() {
        return None;
    }
    let chapter = match with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, chapter_index)
    }) {
        Ok(Some(ch)) => ch,
        // 书不在 DB（FK 级联保证）或章不存在 → 无弹幕
        Ok(None) => return None,
        Err(e) => {
            log::warn!("[video_danmaku] 章节查询失败（降级 null）: {e}");
            return None;
        }
    };
    get_danmaku_for_chapter(book_url, &chapter)
}

/// 按章节实体解析弹幕（Inline 优先 → File → None），异常降级 `None`
fn get_danmaku_for_chapter(book_url: &str, chapter: &BookChapter) -> Option<String> {
    let inline = inline_variable_value(chapter.variable.as_deref(), DANMAKU_KEY);
    let file_path = {
        let path = big_data_manager().chapter_variable_path(book_url, &chapter.url, DANMAKU_KEY);
        if path.is_file() {
            Some(path.to_string_lossy().into_owned())
        } else {
            None
        }
    };
    // 休眠资产激活（`legado-core::video_state::DanmakuSource`）：
    // 三态归一与 `BookChapter.getDanmaku` 的 `variableMap["danmaku"] ?:
    // getDanmakuFile(bookUrl, url)` 一一对应
    let mut state = VideoPlayerState::new();
    state.resolve_danmaku(inline, file_path);
    match state.danmaku() {
        DanmakuSource::Inline(value) => Some(value.clone()),
        DanmakuSource::File(path) => match std::fs::read_to_string(path) {
            Ok(content) if !content.is_empty() => Some(content),
            Ok(_) => None,
            Err(e) => {
                log::warn!("[video_danmaku] 大数据弹幕文件读取失败（降级 null）: {e}");
                None
            }
        },
        DanmakuSource::None => None,
    }
}

// ─── §2.50 B 站弹幕 XML 解析（纯函数，无 IO） ──────────────────────────────
//
// 对齐原版 `help/gsyVideo/BiliDanmukuParser.kt`（SAX）：
// - `<d p="时间秒,类型,字号,颜色,时间戳,池,hash,id">文本</d>`（:80-89）；
// - `time = (p0.toFloat() * 1000).toLong()`（:95，f32 乘后截断）；
// - `color = ((0xFF000000 | p3) & 0xFFFFFFFF).toInt()`（:99，有符号 ARGB）；
// - 字号原值透传（density 换算归 Dart 渲染层，契约 §2.50）；
// - 文本先经 XML 实体解码（SAX characters），再套 `decodeXmlString` 四实体
//   （:257-272）——即 `&amp;quot;` 这类双重转义会被还原两层；
// - 类型映射（DanmakuFlameMaster 0.9.25 `DanmakuFactory` 字节码）：
//   1 右→左 / 4 底 / 5 顶 / 6 左→右 / 7 special；2/3/8 及范围外静默丢弃；
// - type7 高级弹幕：先校验文本为 JSON 数组且 `[4]` 为非空字符串（:136-253，
//   失败即丢弃），通过后**保留 JSON 原文**于 `text`（V-B2 渲染边界：数据保留、
//   不渲染，供后续批次消费）；
// - 失败语义：空 / 非 XML / XML 文档级错误（畸形、实体未定义、多根）→ None，
//   对齐原版 SAX 失败→null；合法 XML 但无有效弹幕 → `[]`（原版返回空 Danmakus）。
//
// 有意登记的安全偏离：原版对单行畸形 `p`（缺属性 / 字段＜4 / 非数字）会抛
// 运行时异常（SAX 回调未捕获，原版表现为崩溃/未定义）；我方宿主安全语义为
// **跳过该行并继续解析**，其余行不受影响（不 panic、不整体失败）。
// 结果按 timeMs 稳定升序（契约 §2.50；同刻保持文档序）。

/// 保留的弹幕类型（对齐 0.9.25 `DanmakuFactory.createDanmaku` 字节码）
const DANMAKU_TYPES_KEPT: [i32; 5] = [1, 4, 5, 6, 7];

/// 契约 §2.50 解析结果项（JSON 字段名与契约逐字对齐）
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
struct DanmakuItem {
    #[serde(rename = "timeMs")]
    time_ms: i64,
    #[serde(rename = "type")]
    danmaku_type: i32,
    #[serde(rename = "textSizeRaw")]
    text_size_raw: f64,
    color: i32,
    text: String,
}

/// 解析 `p` 属性 → (timeMs, type, textSizeRaw, color)；字段不足/非数字 → None
///
/// 数值口径对齐 Kotlin：浮点字段（p0/p2）允许首尾空白（Java parseFloat 语义），
/// 整型字段（p1/p3）不允许空白（Java parseInt/parseLong 语义）。
fn parse_p_attribute(p: &str) -> Option<(i64, i32, f64, i32)> {
    // Kotlin：split(",").dropLastWhile { it.isEmpty() }
    let mut parts: Vec<&str> = p.split(',').collect();
    while parts.last().is_some_and(|s| s.is_empty()) {
        parts.pop();
    }
    if parts.len() < 4 {
        return None;
    }
    let time = (parts[0].trim().parse::<f32>().ok()? * 1000.0) as i64;
    let danmaku_type = parts[1].parse::<i32>().ok()?;
    let text_size_raw = parts[2].trim().parse::<f32>().ok()? as f64;
    let raw_color = parts[3].parse::<i64>().ok()?;
    let color = ((0xFF00_0000_i64 | raw_color) & 0xFFFF_FFFF) as i32;
    Some((time, danmaku_type, text_size_raw, color))
}

/// 对齐原版 `decodeXmlString`（:257-272）：仅四实体、顺序 amp→quot→gt→lt
fn decode_xml_string(raw: &str) -> String {
    if !(raw.contains("&amp;")
        || raw.contains("&quot;")
        || raw.contains("&gt;")
        || raw.contains("&lt;"))
    {
        return raw.to_string();
    }
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&gt;", ">")
        .replace("&lt;", "<")
}

/// 展开 quick-xml 0.42 的 GeneralRef 事件（SAX characters 已解码语义）
///
/// 支持十进制/十六进制字符引用与五个预定义实体；未定义实体返回 None
/// （原版 SAX 对未定义实体报致命错误 → 整体 null）。
fn resolve_general_ref(name: &str) -> Option<char> {
    if let Some(number) = name.strip_prefix('#') {
        let code = match number.strip_prefix(['x', 'X']) {
            Some(hex) => u32::from_str_radix(hex, 16).ok()?,
            None => number.parse::<u32>().ok()?,
        };
        return char::from_u32(code);
    }
    match name {
        "amp" => Some('&'),
        "lt" => Some('<'),
        "gt" => Some('>'),
        "quot" => Some('"'),
        "apos" => Some('\''),
        _ => None,
    }
}

/// 单条弹幕收尾：类型过滤 + type7 JSON 校验 + 文本二次实体解码
fn finalize_danmaku_item(
    p_fields: (i64, i32, f64, i32),
    text: Option<String>,
) -> Option<DanmakuItem> {
    let (time_ms, danmaku_type, text_size_raw, color) = p_fields;
    // 原版 endElement 要求 item.text != null（characters 至少触发一次）
    let text = decode_xml_string(&text?);
    if !DANMAKU_TYPES_KEPT.contains(&danmaku_type) {
        return None;
    }
    if danmaku_type == 7 {
        // 高级弹幕：文本须为 JSON 数组且 [4] 为非空字符串（对齐原版解析；失败丢弃）
        let trimmed = text.trim();
        if !(trimmed.starts_with('[') && trimmed.ends_with(']')) {
            return None;
        }
        let array: Vec<serde_json::Value> = serde_json::from_str(trimmed).ok()?;
        let display_text = array.get(4)?.as_str()?;
        if display_text.is_empty() {
            return None;
        }
        // 保留 JSON 属性原文（渲染边界：V-B2 不渲染 type7）
        return Some(DanmakuItem {
            time_ms,
            danmaku_type,
            text_size_raw,
            color,
            text: trimmed.to_string(),
        });
    }
    Some(DanmakuItem {
        time_ms,
        danmaku_type,
        text_size_raw,
        color,
        text,
    })
}

/// 解析 B 站弹幕 XML 为契约 §2.50 JSON 数组
///
/// 纯函数：无 IO、无 DB、无 panic 路径。`None` = 空/非 XML/文档级解析失败；
/// `Some("[]")` = 合法 XML 但无有效弹幕项。
pub fn parse_video_danmaku(raw: &str) -> Option<String> {
    // UTF-8 BOM（Android InputSource 可吞，quick-xml 视为内容 → 先剥离）
    let content = raw.strip_prefix('\u{feff}').unwrap_or(raw);
    if content.trim().is_empty() {
        return None;
    }

    let mut reader = quick_xml::Reader::from_str(content);
    let mut items: Vec<DanmakuItem> = Vec::new();
    let mut depth: usize = 0;
    let mut root_count: usize = 0;
    // 当前 <d> 的 p 字段与所在深度（None = 不在有效 d 内）
    let mut current_fields: Option<(i64, i32, f64, i32)> = None;
    let mut current_depth: usize = 0;
    let mut current_text: Option<String> = None;

    loop {
        match reader.read_event() {
            Err(_) => return None,
            Ok(quick_xml::events::Event::Eof) => break,
            Ok(quick_xml::events::Event::Start(e)) => {
                if depth == 0 {
                    root_count += 1;
                }
                depth += 1;
                let is_d = e.local_name().as_ref().eq_ignore_ascii_case("d");
                if is_d && current_fields.is_none() {
                    let mut p_value: Option<String> = None;
                    for attr in e.attributes() {
                        let Ok(attr) = attr else { return None };
                        if attr.key.as_ref() == "p" {
                            match attr.normalized_value(quick_xml::XmlVersion::Explicit1_0) {
                                Ok(v) => p_value = Some(v.into_owned()),
                                Err(_) => return None,
                            }
                        }
                    }
                    // 缺 p / p 畸形：原版抛异常（未定义）；我方跳过该行（登记偏离）
                    current_fields = p_value.as_deref().and_then(parse_p_attribute);
                    current_depth = depth;
                    current_text = None;
                }
            }
            Ok(quick_xml::events::Event::Empty(_)) => {
                if depth == 0 {
                    root_count += 1;
                }
                // <d .../>：无文本（原版 characters 未触发 → text==null → 丢弃）
            }
            Ok(quick_xml::events::Event::End(_)) => {
                if current_fields.is_some() && depth == current_depth {
                    let item =
                        finalize_danmaku_item(current_fields.take().unwrap(), current_text.take());
                    if let Some(item) = item {
                        items.push(item);
                    }
                }
                depth = depth.saturating_sub(1);
            }
            Ok(quick_xml::events::Event::Text(e)) => {
                if depth == 0 {
                    if !e.as_ref().trim().is_empty() {
                        return None;
                    }
                } else if current_fields.is_some() {
                    current_text
                        .get_or_insert_with(String::new)
                        .push_str(e.as_ref());
                }
            }
            Ok(quick_xml::events::Event::CData(e)) => {
                if depth == 0 {
                    if !e.as_ref().trim().is_empty() {
                        return None;
                    }
                } else if current_fields.is_some() {
                    current_text
                        .get_or_insert_with(String::new)
                        .push_str(e.as_ref());
                }
            }
            Ok(quick_xml::events::Event::GeneralRef(r)) => {
                // 未定义实体 = XML 文档级失败（对齐原版 SAX 致命错误 → null）
                let resolved = resolve_general_ref(r.as_ref())?;
                if current_fields.is_some() {
                    current_text.get_or_insert_with(String::new).push(resolved);
                }
            }
            Ok(_) => {}
        }
    }

    // 要求恰一个顶层元素：空文档 / 纯文本 / 多根 → None（对齐 SAX 文档语义）
    if root_count != 1 {
        return None;
    }
    // 契约 §2.50：按 timeMs 升序（稳定排序保持同刻文档序）
    items.sort_by_key(|item| item.time_ms);
    serde_json::to_string(&items).ok()
}

/// 媒体副内容落库入口（抓取链 sink 专用；契约 §2.49 写入侧）
///
/// 落库书籍取址点解析（按优先级）：
/// 1. 抓取链 meta 给出的 `book_url`——**须在 DB 命中该 (bookUrl, chapterUrl)
///    章节**才采用（`refreshToc` 目录链把目录页 URL 当作 bookUrl 透传给
///    fetcher 的 book 绑定，meta 里的 bookUrl 可能是目录页地址而非书籍
///    主键，故必须校验）；
/// 2. 校验失败/为空 → 按 `(sourceUrl, chapterUrl)` 从 DB 兜底反查
///    （`books.origin` = 书源 URL，唯一命中才返回）。
///
/// 仍无法唯一确定时跳过并记日志（宁可不落库也不串书）；所有失败降级为日志。
pub fn put_media_sub_content_from_capture(
    book_url: Option<&str>,
    source_url: &str,
    chapter_url: &str,
    key: &str,
    value: &str,
) {
    let direct = book_url
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    if let Some(candidate) = direct {
        if chapter_exists(&candidate, chapter_url) {
            put_media_sub_content(&candidate, chapter_url, key, value);
            return;
        }
        // meta 的 bookUrl 未命中 DB（如 refreshToc 透传的目录页 URL）→ 兜底
    }
    if let Some(resolved) = resolve_book_url_by_source_chapter(source_url, chapter_url) {
        put_media_sub_content(&resolved, chapter_url, key, value);
        return;
    }
    log::warn!(
        "[video_danmaku] 副内容落库跳过：书籍取址点未解析到 DB 章节\
         （source={source_url} chapter={chapter_url} key={key}）"
    );
}

/// 该 (bookUrl, chapterUrl) 章节是否在 DB（落库前校验，防 meta 脏值串书）
fn chapter_exists(book_url: &str, chapter_url: &str) -> bool {
    with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_by_book_url_and_chapter_url(book_url, chapter_url)
            .map(|found| found.is_some())
    })
    .unwrap_or(false)
}

/// 按 (书源 URL, 章节 URL) 从 DB 反查书籍取址点（唯一命中才返回）
fn resolve_book_url_by_source_chapter(source_url: &str, chapter_url: &str) -> Option<String> {
    if source_url.trim().is_empty() || chapter_url.trim().is_empty() {
        return None;
    }
    match with_database(|db| {
        BookChapterRepository::new(db.connection())
            .find_book_url_by_source_and_chapter_url(source_url, chapter_url)
    }) {
        Ok(url) => url,
        Err(e) => {
            log::warn!("[video_danmaku] 书籍取址点兜底反查失败（降级跳过）: {e}");
            None
        }
    }
}

/// 媒体副内容落库（契约 §2.49 写入侧，由 `FetcherDeps` 捕获 sink 调用）
///
/// - `key`：视频源 `danmaku` / 音频源 `lyric`（对齐原版 `putDanmaku`/`putLyric`）
/// - `<10000` 字符（UTF-16 口径）→ 合并进章节 variable JSON 并删除同名大数据文件；
/// - `≥10000` 字符 → 写大数据文件并从 variable JSON 移除同名键；
/// - **任何失败仅记日志**（写入属抓取链内部增强行为，不得阻断正文返回）。
pub fn put_media_sub_content(book_url: &str, chapter_url: &str, key: &str, value: &str) {
    if book_url.trim().is_empty() || chapter_url.trim().is_empty() || key.trim().is_empty() {
        log::warn!("[video_danmaku] 副内容落库参数不完整，已忽略（key={key}）");
        return;
    }
    if value.is_empty() {
        return;
    }
    if let Err(e) = put_media_sub_content_inner(book_url, chapter_url, key, value) {
        log::warn!(
            "[video_danmaku] 副内容落库失败（已忽略，不影响正文）: \
             book={book_url} chapter={chapter_url} key={key}: {e}"
        );
    }
}

/// 落库本体：章节 variable 的读-改-写包进单事务（BEGIN IMMEDIATE），
/// 同章并发捕获在写锁上排队、依次读到最新 JSON，避免后写覆盖前写；
/// 返回错误由调用方降级为日志
///
/// 事务选择（P2-1 收口）：项目 DB 层为 r2d2 连接池、连接以 `&Connection`
/// 共享，沿用既有 `unchecked_transaction` 先例；但本处是「先读后写」的
/// 读-改-写，DEFERRED 起事务会在快照过期时触发 `SQLITE_BUSY_SNAPSHOT`
/// （busy_timeout 不重试），故用 `TransactionBehavior::Immediate`
/// （BEGIN IMMEDIATE）在事务起点即取写锁，并在 busy_timeout(5s) 内排队。
/// 大数据文件同步在事务提交后执行（文件系统不参与 DB 事务，与原版
/// `putVariable` 的「先更新列、后写/删文件」顺序一致）。
fn put_media_sub_content_inner(
    book_url: &str,
    chapter_url: &str,
    key: &str,
    value: &str,
) -> Result<(), String> {
    let is_small = kotlin_str_len(value) < LARGE_VALUE_THRESHOLD;

    with_database(|db| {
        let conn = db.connection();
        let tx =
            rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)
                .map_err(|e| {
                    LegadoError::Database(format!("副内容写事务开启失败（BEGIN IMMEDIATE）: {e}"))
                })?;

        let chapter = BookChapterRepository::new(conn)
            .find_by_book_url_and_chapter_url(book_url, chapter_url)?
            .ok_or_else(|| LegadoError::Database("章节不在 DB（无法落库副内容）".to_string()))?;

        let mut map: serde_json::Map<String, serde_json::Value> = match chapter.variable.as_deref()
        {
            Some(raw) if !raw.trim().is_empty() => serde_json::from_str(raw).unwrap_or_default(),
            _ => serde_json::Map::new(),
        };

        if is_small {
            // 小数据分支（对齐 putVariable：value.length < 10000）
            // variableMap[key] = value；putBigVariable(key, null) 删除文件
            map.insert(
                key.to_string(),
                serde_json::Value::String(value.to_string()),
            );
            let serialized = serde_json::Value::Object(map).to_string();
            BookChapterRepository::new(conn).update_variable(book_url, chapter_url, &serialized)?;
        } else if map.remove(key).is_some() {
            // 大数据分支（对齐 putVariable：else 分支，仅键存在时重写列）
            let serialized = serde_json::Value::Object(map).to_string();
            BookChapterRepository::new(conn).update_variable(book_url, chapter_url, &serialized)?;
        }

        tx.commit()
            .map_err(|e| LegadoError::Database(format!("副内容写事务提交失败: {e}")))?;
        Ok(())
    })
    .map_err(|e| e.to_string())?;

    // 事务提交后再同步大数据文件（与原版「先更新列、后写/删文件」顺序一致）
    if is_small {
        big_data_manager().put_chapter_variable(book_url, chapter_url, key, None)?;
    } else {
        big_data_manager().put_chapter_variable(book_url, chapter_url, key, Some(value))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::Book;
    use legado_db::repository::Repository;

    /// 模块级串行锁（env 目录 + 共享测试库为进程级状态，防并行互踩；
    /// 锁序：本锁先取、DB 守卫后取，遵循 test_support 全局锁序不变式）
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// 临时规则数据目录 + env 注入守卫（Drop 恢复原值）
    struct RuleDataDirGuard {
        dir: PathBuf,
        prev: Option<String>,
    }

    impl RuleDataDirGuard {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "legado_video_danmaku_test_{}_{}",
                std::process::id(),
                tag
            ));
            let _ = std::fs::remove_dir_all(&dir);
            let prev = std::env::var(RULE_DATA_DIR_ENV).ok();
            std::env::set_var(RULE_DATA_DIR_ENV, &dir);
            Self { dir, prev }
        }
    }

    impl Drop for RuleDataDirGuard {
        fn drop(&mut self) {
            match &self.prev {
                Some(v) => std::env::set_var(RULE_DATA_DIR_ENV, v),
                None => std::env::remove_var(RULE_DATA_DIR_ENV),
            }
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    /// 插入父书 + 章节（唯一书 URL 防共享测试库串本）
    fn seed_chapter(book_url: &str, chapter_url: &str, variable: Option<&str>) {
        with_database(|db| {
            let book = Book {
                book_url: book_url.to_string(),
                name: format!("弹幕测试书 {book_url}"),
                author: "测试作者".to_string(),
                ..Book::default()
            };
            legado_db::BookRepository::new(db.connection()).insert(&book)?;
            let chapter = BookChapter {
                url: chapter_url.to_string(),
                title: "第1集".to_string(),
                book_url: book_url.to_string(),
                index: 0,
                variable: variable.map(str::to_string),
                ..BookChapter::default()
            };
            BookChapterRepository::new(db.connection()).insert(&chapter)
        })
        .expect("播种父书与章节");
    }

    fn chapter_variable(book_url: &str, chapter_url: &str) -> Option<String> {
        with_database(|db| {
            Ok(BookChapterRepository::new(db.connection())
                .find_by_book_url_and_chapter_url(book_url, chapter_url)?
                .and_then(|c| c.variable))
        })
        .unwrap()
    }

    /// `<10000`：章节 variable 直存直读（B 站 XML 原文往返不变）
    #[test]
    fn test_get_video_danmaku_inline_roundtrip() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let book_url = "https://v-b1-inline.example/book";
        let chapter_url = "https://v-b1-inline.example/ch/1";
        let xml = "<i><d p=\"0.5,1,25,16777215\">弹幕</d></i>";
        seed_chapter(book_url, chapter_url, None);

        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, xml);
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(xml),
            "小数据应经章节 variable 直存直读"
        );
        // 幂等：重复查询读同一落库值
        assert_eq!(get_video_danmaku(book_url, 0).as_deref(), Some(xml));
        // variable 列确为 JSON（键 danmaku），未落大数据文件
        let variable = chapter_variable(book_url, chapter_url).unwrap();
        assert!(variable.contains("\"danmaku\""), "variable 应含 danmaku 键");
        assert!(!big_data_manager()
            .chapter_variable_path(book_url, chapter_url, DANMAKU_KEY)
            .exists());
    }

    /// `≥10000`：大数据文件落点往返（读回原样）；variable 列不含该键
    #[test]
    fn test_get_video_danmaku_large_file_roundtrip() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("large");
        let book_url = "https://v-b1-large.example/book";
        let chapter_url = "https://v-b1-large.example/ch/1";
        seed_chapter(book_url, chapter_url, Some(r#"{"other":"keep"}"#));

        // 10000 个 CJK 字符（UTF-16 口径 = 10000，字节数 30000）
        let big = "弹".repeat(10000);
        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, &big);

        let file = big_data_manager().chapter_variable_path(book_url, chapter_url, DANMAKU_KEY);
        assert!(file.is_file(), "大数据应落文件: {file:?}");
        assert_eq!(
            std::fs::read_to_string(&file).unwrap(),
            big,
            "文件内容应为副内容原文（读回原样）"
        );
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(big.as_str()),
            "查询应读回大数据文件原文"
        );
        let variable = chapter_variable(book_url, chapter_url).unwrap();
        assert!(
            !variable.contains("\"danmaku\""),
            "大数据分支 variable 不应含 danmaku 键: {variable}"
        );
        assert!(variable.contains("\"other\""), "其他变量键应保留");
    }

    /// 阈值口径：Kotlin `String.length`（UTF-16 码元），非字节数——
    /// 9999 个 CJK 字符（30000 字节）仍进 variable；10000 个才走文件
    #[test]
    fn test_threshold_uses_kotlin_utf16_length() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("threshold");
        let book_url = "https://v-b1-threshold.example/book";
        let chapter_url = "https://v-b1-threshold.example/ch/1";
        seed_chapter(book_url, chapter_url, None);

        let almost = "弹".repeat(9999);
        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, &almost);
        assert!(
            !big_data_manager()
                .chapter_variable_path(book_url, chapter_url, DANMAKU_KEY)
                .exists(),
            "UTF-16 长度 9999 < 10000 应进 variable（按字节数 29997 会误判）"
        );
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(almost.as_str())
        );

        let exact = "弹".repeat(10000);
        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, &exact);
        assert!(
            big_data_manager()
                .chapter_variable_path(book_url, chapter_url, DANMAKU_KEY)
                .is_file(),
            "UTF-16 长度 10000 ≥ 10000 应走文件存储"
        );
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(exact.as_str())
        );
    }

    /// none 三面降级：书/章不在 DB → None；章在但无记录 → None；
    /// 大数据文件丢失（读失败）→ None；非法 variable JSON → None
    #[test]
    fn test_get_video_danmaku_none_degradation() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("none");
        let book_url = "https://v-b1-none.example/book";
        let chapter_url = "https://v-b1-none.example/ch/1";

        // 书/章均不在 DB → None
        assert_eq!(
            get_video_danmaku("https://v-b1-none.example/ghost", 0),
            None
        );
        // 空 bookUrl 短路 → None
        assert_eq!(get_video_danmaku("   ", 0), None);

        seed_chapter(book_url, chapter_url, None);
        // 章在但无任何弹幕记录 → None
        assert_eq!(get_video_danmaku(book_url, 0), None);
        // 章 index 不匹配 → None
        assert_eq!(get_video_danmaku(book_url, 9), None);

        // 非法 variable JSON → None（解析失败降级）
        seed_chapter(
            "https://v-b1-none.example/bad",
            "https://v-b1-none.example/bad/1",
            Some("not-json"),
        );
        assert_eq!(get_video_danmaku("https://v-b1-none.example/bad", 0), None);

        // 大数据文件被删（读失败面）→ None
        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, &"弹".repeat(10000));
        let file = big_data_manager().chapter_variable_path(book_url, chapter_url, DANMAKU_KEY);
        assert!(file.is_file());
        std::fs::remove_file(&file).unwrap();
        assert_eq!(get_video_danmaku(book_url, 0), None);
    }

    /// 写失败不阻断：章不在 DB / 空值 / 空参数均仅日志，不 panic
    #[test]
    fn test_put_media_sub_content_write_failure_degrades() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("write_degrade");
        // 章不在 DB → 内部 Err → 仅日志
        put_media_sub_content(
            "https://v-b1-write.example/ghost",
            "https://v-b1-write.example/ch/1",
            DANMAKU_KEY,
            "<i/>",
        );
        // 空值 / 空参数 → no-op
        put_media_sub_content(
            "https://v-b1-write.example/ghost",
            "https://v-b1-write.example/ch/1",
            DANMAKU_KEY,
            "",
        );
        put_media_sub_content("", "", DANMAKU_KEY, "<i/>");
    }

    /// [V-B1 §2.49 兜底链] bookUrl 未知（refreshToc 目录链 meta 未登记）→
    /// 按 (sourceUrl, chapterUrl) DB 反查落库；查询同键读回
    #[test]
    fn test_capture_fallback_resolves_book_by_source_and_chapter() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("fallback");
        let source_url = "https://v-b1-fallback.example";
        let book_url = "https://v-b1-fallback.example/book";
        let chapter_url = "https://v-b1-fallback.example/ch/1";
        with_database(|db| {
            legado_db::BookRepository::new(db.connection()).insert(&Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                name: "兜底测试书".to_string(),
                ..Book::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                url: chapter_url.to_string(),
                title: "第1集".to_string(),
                book_url: book_url.to_string(),
                index: 0,
                ..BookChapter::default()
            })
        })
        .expect("播种兜底测试书/章");

        let xml = "<i><d p=\"0.5,1,25,16777215\">兜底弹幕</d></i>";
        put_media_sub_content_from_capture(None, source_url, chapter_url, DANMAKU_KEY, xml);
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(xml),
            "bookUrl 未知时应经 DB 兜底反查后落库并可查询"
        );

        // 抓取链 meta 脏值（refreshToc 透传目录页 URL 作 bookUrl）→ 校验失败后兜底
        let toc_like = format!("{source_url}/toc");
        let xml2 = "<i><d p=\"1,1,25,16777215\">脏值兜底弹幕</d></i>";
        put_media_sub_content_from_capture(
            Some(&toc_like),
            source_url,
            chapter_url,
            DANMAKU_KEY,
            xml2,
        );
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(xml2),
            "meta bookUrl 未命中 DB 章节时应兜底到正确书籍并覆盖落库"
        );

        // 反查不到（source 不匹配）→ 跳过落库，不 panic
        put_media_sub_content_from_capture(
            None,
            "https://v-b1-fallback.example/other-source",
            chapter_url,
            DANMAKU_KEY,
            "不应落库",
        );
        assert_eq!(get_video_danmaku(book_url, 0).as_deref(), Some(xml2));
    }

    /// [P2-1] 同章并发落库不得丢键：variable 读-改-写须包进单事务
    ///
    /// 确定性交错构造：测试侧连接先 `BEGIN IMMEDIATE` 独占写锁，再放行 N 个
    /// 并发捕获线程（各写不同键；WAL 下 SELECT 不阻塞，持锁 500ms 保证各线程
    /// 读阶段全部完成）——
    /// - 旧实现（读-改-写无事务）：N 个线程各自读到同一旧状态，UPDATE 排队
    ///   后互相覆盖（后写赢），最终只剩最后一个键 → 断言必败（红）；
    /// - 事务化后：各线程 `BEGIN IMMEDIATE` 先排队，锁释放后依次读到前者
    ///   已提交的最新 variable，全部键保留 → 断言通过（绿）。
    #[test]
    fn test_concurrent_same_chapter_capture_keeps_all_keys() {
        use std::sync::mpsc;
        use std::time::Duration;

        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("concurrent");
        let book_url = "https://v-b1-concurrent.example/book";
        let chapter_url = "https://v-b1-concurrent.example/ch/1";
        seed_chapter(book_url, chapter_url, Some(r#"{"keep":"base"}"#));

        const N: usize = 8;
        let (started_tx, started_rx) = mpsc::channel::<()>();

        with_database(|db| {
            let conn = db.connection();
            // 测试侧先占据写锁：保证并发线程的「读」全部先于任何一个「写」
            let tx = rusqlite::Transaction::new_unchecked(
                conn,
                rusqlite::TransactionBehavior::Immediate,
            )
            .map_err(|e| legado_core::LegadoError::Database(format!("测试持锁失败: {e}")))?;

            let handles: Vec<std::thread::JoinHandle<()>> = (0..N)
                .map(|i| {
                    let ready = started_tx.clone();
                    let book = book_url.to_string();
                    let chapter = chapter_url.to_string();
                    std::thread::spawn(move || {
                        let _ = ready.send(());
                        put_media_sub_content(&book, &chapter, &format!("k{i}"), &format!("v{i}"));
                    })
                })
                .collect();
            drop(started_tx);

            for _ in 0..N {
                started_rx.recv().map_err(|e| {
                    legado_core::LegadoError::Database(format!("并发线程就绪失败: {e}"))
                })?;
            }
            // 持锁期间留足时间让各线程完成 SELECT（旧实现此刻阻塞在 UPDATE）
            std::thread::sleep(Duration::from_millis(500));
            tx.commit().map_err(|e| {
                legado_core::LegadoError::Database(format!("释放测试写锁失败: {e}"))
            })?;

            for h in handles {
                h.join().map_err(|_| {
                    legado_core::LegadoError::Database("并发落库线程 panic".to_string())
                })?;
            }
            Ok(())
        })
        .expect("并发落库编排失败");

        let variable = chapter_variable(book_url, chapter_url).expect("variable 应存在");
        let map: serde_json::Map<String, serde_json::Value> =
            serde_json::from_str(&variable).expect("variable 应为 JSON 对象");
        for i in 0..N {
            assert!(
                map.contains_key(&format!("k{i}")),
                "并发落库键 k{i} 丢失（读-改-写未串行化）: {variable}"
            );
        }
        assert!(
            map.contains_key("keep"),
            "原有变量键不得被并发写覆盖: {variable}"
        );
    }

    /// [P0-1 附注] 阈值口径增补平面钉死：emoji（UTF-16 代理对，1 字符 = 2 码元）
    /// - 4999 个 emoji = 9998 UTF-16 码元 < 10000 → 不触发文件分支；
    /// - 5000 个 emoji = 10000 UTF-16 码元 → 必须走文件分支
    ///   （若实现误用 `chars().count()`，5000 < 10000 会误进 variable → 红）。
    #[test]
    fn test_threshold_counts_supplementary_plane_by_utf16_units() {
        let _lock = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let _db = crate::db_state::ensure_test_db();
        let _dir = RuleDataDirGuard::new("threshold_emoji");
        let book_url = "https://v-b1-threshold-emoji.example/book";
        let chapter_url = "https://v-b1-threshold-emoji.example/ch/1";
        seed_chapter(book_url, chapter_url, None);

        let file = big_data_manager().chapter_variable_path(book_url, chapter_url, DANMAKU_KEY);

        // 4999 个 emoji（UTF-16 = 9998 < 10000）→ 进 variable
        let under = "😀".repeat(4999);
        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, &under);
        assert!(!file.exists(), "9998 UTF-16 码元不应触发文件分支: {file:?}");
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(under.as_str())
        );

        // 5000 个 emoji（UTF-16 = 10000 ≥ 10000）→ 走文件分支
        let exact = "😀".repeat(5000);
        put_media_sub_content(book_url, chapter_url, DANMAKU_KEY, &exact);
        assert!(file.is_file(), "10000 UTF-16 码元应走文件分支: {file:?}");
        assert_eq!(std::fs::read_to_string(&file).unwrap(), exact);
        assert_eq!(
            get_video_danmaku(book_url, 0).as_deref(),
            Some(exact.as_str())
        );
        let variable = chapter_variable(book_url, chapter_url).unwrap_or_default();
        assert!(
            !variable.contains("\"danmaku\""),
            "文件分支 variable 不应含 danmaku 键: {variable}"
        );
    }

    // ─── §2.50 parse_video_danmaku（纯函数）测试 ────────────────────────

    /// 解析输出 → JSON 数组（测试断言辅助）
    fn parse_items(raw: &str) -> Vec<serde_json::Value> {
        let json = parse_video_danmaku(raw).expect("应为可解析 XML");
        serde_json::from_str(&json).expect("输出应为 JSON 数组")
    }

    /// 四类弹幕（1 右→左 / 5 顶 / 4 底 / 6 左→右）字段逐项 + 按 timeMs 升序
    #[test]
    fn test_parse_video_danmaku_four_types() {
        // 文档序故意乱序：5(2s) / 6(1s) / 1(0.5s) / 4(3s)
        let xml = r#"<i>
            <d p="2.0,5,25,16711680">顶部</d>
            <d p="1.0,6,18,65280">左到右</d>
            <d p="0.5,1,25,16777215">右到左</d>
            <d p="3.0,4,36,255">底部</d>
        </i>"#;
        let items = parse_items(xml);
        assert_eq!(items.len(), 4, "四类弹幕均应保留: {items:?}");
        // 升序：0.5s(右到左) / 1s(左到右) / 2s(顶部) / 3s(底部)
        assert_eq!(items[0]["timeMs"], 500);
        assert_eq!(items[0]["type"], 1);
        assert_eq!(items[0]["textSizeRaw"], 25.0);
        assert_eq!(items[0]["color"], -1); // 0xFFFFFFFF as i32
        assert_eq!(items[0]["text"], "右到左");

        assert_eq!(items[1]["timeMs"], 1000);
        assert_eq!(items[1]["type"], 6);
        assert_eq!(items[1]["textSizeRaw"], 18.0);
        assert_eq!(items[1]["color"], 0xFF00FF00u32 as i32);
        assert_eq!(items[1]["text"], "左到右");

        assert_eq!(items[2]["type"], 5);
        assert_eq!(items[2]["color"], 0xFFFF0000u32 as i32);
        assert_eq!(items[2]["text"], "顶部");
        assert_eq!(items[3]["type"], 4);
        assert_eq!(items[3]["color"], 0xFF0000FFu32 as i32);
        assert_eq!(items[3]["text"], "底部");
    }

    /// p 属性各段口径：f32 乘 1000 截断、颜色有符号 ARGB、字号原值透传
    #[test]
    fn test_parse_video_danmaku_p_attribute_segments() {
        // 0.001 的 f32 表示略大于 0.001 → *1000 截断为 1（Kotlin Float 同口径）
        let xml = r#"<i><d p="0.001,1,25.5,0">a</d><d p="2.5,1,25,-1">b</d></i>"#;
        let items = parse_items(xml);
        assert_eq!(items.len(), 2, "{items:?}");
        assert_eq!(items[0]["timeMs"], 1);
        assert_eq!(items[0]["textSizeRaw"], 25.5);
        assert_eq!(items[0]["color"], -16777216); // p3=0 → 0xFF000000 as i32
        assert_eq!(items[1]["timeMs"], 2500);
        assert_eq!(items[1]["color"], -1); // p3=-1 → 0xFFFFFFFF as i32
                                           // 尾部空段（p 以逗号结尾）按 Kotlin dropLastWhile 丢弃
        let xml_tail = r#"<i><d p="1.5,1,25,16777215,1422201084,0,hash,id,">尾部逗号</d></i>"#;
        let items = parse_items(xml_tail);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["timeMs"], 1500);
    }

    /// type 2/3/8 及范围外类型静默丢弃（对齐 DanmakuFactory 字节码）
    #[test]
    fn test_parse_video_danmaku_drops_unsupported_types() {
        let xml = r#"<i>
            <d p="1,2,25,0">类型2</d>
            <d p="2,3,25,0">类型3</d>
            <d p="3,8,25,0">类型8</d>
            <d p="4,0,25,0">类型0</d>
            <d p="5,9,25,0">类型9</d>
            <d p="6,1,25,0">类型1保留</d>
        </i>"#;
        let items = parse_items(xml);
        assert_eq!(items.len(), 1, "仅 type1 应保留: {items:?}");
        assert_eq!(items[0]["type"], 1);
        assert_eq!(items[0]["text"], "类型1保留");
    }

    /// type7 高级弹幕：合法 JSON 数组且 [4] 非空 → 保留 JSON 原文；
    /// 非数组 / JSON 非法 / 元素不足 / [4] 空 → 丢弃（对齐原版 :136-253）
    #[test]
    fn test_parse_video_danmaku_type7_json() {
        // 合法高级弹幕（B 站格式为字符串数组，alpha 为 "起-止" 形式）
        let valid =
            r#"<i><d p="1,7,25,16777215">["0.1","0.2","0.8-1","4.5","高级文本","0","0"]</d></i>"#;
        let items = parse_items(valid);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["type"], 7);
        assert_eq!(
            items[0]["text"], "[\"0.1\",\"0.2\",\"0.8-1\",\"4.5\",\"高级文本\",\"0\",\"0\"]",
            "type7 应保留 JSON 属性原文（V-B2 不渲染，登记边界）"
        );

        // 非法用例：非 JSON 数组 / 元素不足 5 / [4] 为空串 / [4] 非字符串
        for bad in [
            r#"<i><d p="1,7,25,0">高级弹幕不是JSON</d></i>"#,
            r#"<i><d p="1,7,25,0">["0.1","0.2","0.8","4.5"]</d></i>"#,
            r#"<i><d p="1,7,25,0">["0.1","0.2","0.8","4.5","","0","0"]</d></i>"#,
            r#"<i><d p="1,7,25,0">["0.1","0.2","0.8","4.5",42,"0","0"]</d></i>"#,
            r#"<i><d p="1,7,25,0">[0.1,0.2,0.8-1,4.5,42]</d></i>"#,
        ] {
            assert!(parse_items(bad).is_empty(), "非法 type7 应丢弃: {bad}");
        }
    }

    /// 畸形行容错（登记的安全偏离）：缺 p / 字段＜4 / 非数字 → 跳过该行，
    /// 其余行继续解析；文档级 XML 错误才整体 null
    #[test]
    fn test_parse_video_danmaku_malformed_rows_skipped() {
        let xml = r#"<i>
            <d>缺p属性</d>
            <d p="1,1">字段不足</d>
            <d p="abc,1,25,0">时间非数字</d>
            <d p="1,abc,25,0">类型非数字</d>
            <d p="1,1,abc,0">字号非数字</d>
            <d p="1,1,25,abc">颜色非数字</d>
            <d p="2,1,25,0"></d>
            <d p="3,1,25,0"/>
            <d p="4,1,25,0">有效行</d>
        </i>"#;
        let items = parse_items(xml);
        assert_eq!(items.len(), 1, "仅有效行应保留: {items:?}");
        assert_eq!(items[0]["timeMs"], 4000);
        assert_eq!(items[0]["text"], "有效行");
    }

    /// XML 实体解码：SAX 一层 + decodeXmlString 四实体第二层（双重转义还原）
    #[test]
    fn test_parse_video_danmaku_entity_decoding() {
        let xml = r#"<i>
            <d p="1,1,25,0">A&amp;B</d>
            <d p="2,1,25,0">&lt;tag&gt; &quot;q&quot;</d>
            <d p="3,1,25,0">&#65;&#x42;</d>
            <d p="4,1,25,0">&amp;quot;双重转义&amp;quot;</d>
            <d p="5,1,25,0">apos保持&apos;原样</d>
        </i>"#;
        let items = parse_items(xml);
        assert_eq!(items.len(), 5, "{items:?}");
        assert_eq!(items[0]["text"], "A&B");
        assert_eq!(items[1]["text"], "<tag> \"q\"");
        assert_eq!(items[2]["text"], "AB");
        // 原版：SAX 解码 &amp;quot; → &quot;，decodeXmlString 再解 → "
        assert_eq!(items[3]["text"], "\"双重转义\"");
        // 原版 decodeXmlString 不含 apos：SAX 解为 ' 后不再处理 → 保持 '
        assert_eq!(items[4]["text"], "apos保持'原样");
    }

    /// 非法文档 / 空 / 多根 / 未闭合 / 未定义实体 → None；合法空 XML → "[]"
    #[test]
    fn test_parse_video_danmaku_invalid_documents() {
        assert_eq!(parse_video_danmaku(""), None, "空串应 None");
        assert_eq!(parse_video_danmaku("   \n"), None, "空白应 None");
        assert_eq!(parse_video_danmaku("not xml"), None, "纯文本应 None");
        assert_eq!(
            parse_video_danmaku("hello<d p=\"1,1,25,0\">a</d>"),
            None,
            "根前非空白文本应 None"
        );
        assert_eq!(
            parse_video_danmaku("<d p=\"1,1,25,0\">a</d><d p=\"2,1,25,0\">b</d>"),
            None,
            "多根应 None"
        );
        assert_eq!(
            parse_video_danmaku("<i><d p=\"1,1,25,0\">a</i>"),
            None,
            "未闭合应 None"
        );
        assert_eq!(
            parse_video_danmaku("<i><d p=\"1,1,25,0\">a&foo;b</d></i>"),
            None,
            "未定义实体应 None（对齐 SAX 致命错误）"
        );
        assert_eq!(
            parse_video_danmaku("<i/>").as_deref(),
            Some("[]"),
            "合法空 XML 应返回空数组（原版返回空 Danmakus）"
        );
        assert_eq!(
            parse_video_danmaku("<i><chatserver>xx</chatserver></i>").as_deref(),
            Some("[]"),
            "无 d 元素应返回空数组"
        );
        // BOM 前缀（Android InputSource 可吞）应可解析
        let with_bom = "\u{feff}<i><d p=\"1,1,25,0\">bom</d></i>";
        assert_eq!(parse_items(with_bom).len(), 1);
    }

    /// 同刻稳定序：timeMs 相同保持文档序；CDATA 与注释不影响文本拼接
    #[test]
    fn test_parse_video_danmaku_order_and_cdata() {
        let xml = r#"<i>
            <d p="2.0,1,25,0">后</d>
            <d p="1.0,1,25,0">A<!--注释-->B</d>
            <d p="1.0,1,25,0"><![CDATA[CD&ATA]]></d>
        </i>"#;
        let items = parse_items(xml);
        assert_eq!(items.len(), 3);
        assert_eq!(items[0]["text"], "AB");
        assert_eq!(items[1]["text"], "CD&ATA");
        assert_eq!(items[2]["text"], "后");
        assert_eq!(items[0]["timeMs"], items[1]["timeMs"]);
    }
}
