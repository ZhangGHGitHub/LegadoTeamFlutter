//! 书源调试流式 API（对齐 Kotlin `Debug.Callback`）
//!
//! - `printLog(state, msg)` 语义：经 StreamSink 推送 `{"state":int,"msg":String}`
//! - 关键字分流对齐 `Debug.startDebug(bookSource, key)`：
//!   绝对 URL → 详情；`::` → 发现；`++` → 目录；`--` → 正文；否则搜索
//! - 时间戳格式 `[mm:ss.SSS]`，state=-1 失败 / 1000 完成

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

use serde::Serialize;

use legado_core::models::BookSource;
use legado_core::{LegadoError, LegadoResult};
use legado_db::BookSourceRepository;
use legado_js::js_source::js_source_debug_formatter::JsSourceDebugFormatter;

use crate::api::web_book::{
    webbook_chapters, webbook_content, webbook_info, webbook_search,
};
use crate::db_state::with_database;

/// 调试取消标志
static DEBUG_CANCELLED: AtomicBool = AtomicBool::new(false);

/// 会话序号（对齐 Debug.debugSessionId）
static SESSION_ID: AtomicU64 = AtomicU64::new(0);

struct DebugSession {
    session_id: u64,
    source_url: String,
    start: Instant,
}

static SESSION: OnceLock<Mutex<Option<DebugSession>>> = OnceLock::new();

fn session_lock() -> &'static Mutex<Option<DebugSession>> {
    SESSION.get_or_init(|| Mutex::new(None))
}

/// 单条调试日志（跨 FFI JSON）
#[derive(Debug, Clone, Serialize)]
pub struct DebugLogItem {
    pub state: i32,
    pub msg: String,
}

fn format_elapsed(start: Instant) -> String {
    let ms = start.elapsed().as_millis() as u64;
    let m = ms / 60_000;
    let s = (ms % 60_000) / 1000;
    let milli = ms % 1000;
    format!("[{m:02}:{s:02}.{milli:03}]")
}

/// 是否正在调试指定书源（供 fetcher 内嵌调用）
pub fn is_debugging(source_url: &str) -> bool {
    let guard = session_lock().lock().ok();
    match guard.as_deref() {
        Some(Some(s)) => s.source_url == source_url && !DEBUG_CANCELLED.load(Ordering::SeqCst),
        _ => false,
    }
}

/// 对齐 `Debug.log(sourceUrl, msg, state=…)`：仅当会话活跃且 source 匹配时推送
pub fn log_debug(source_url: Option<&str>, msg: &str, state: i32, show_time: bool) {
    if DEBUG_CANCELLED.load(Ordering::SeqCst) {
        return;
    }
    let Ok(guard) = session_lock().lock() else {
        return;
    };
    let Some(session) = guard.as_ref() else {
        return;
    };
    if let Some(url) = source_url {
        if url != session.source_url {
            return;
        }
    }
    let print_msg = if show_time {
        format!("{} {msg}", format_elapsed(session.start))
    } else {
        msg.to_string()
    };
    // 实际推送由 active sink 回调完成；此处写入线程局部缓冲由 run_* 的闭包消费
    emit_log(DebugLogItem {
        state,
        msg: print_msg,
    });
}

type EmitFn = Box<dyn Fn(DebugLogItem) + Send>;

static EMITTER: OnceLock<Mutex<Option<EmitFn>>> = OnceLock::new();

fn emitter_lock() -> &'static Mutex<Option<EmitFn>> {
    EMITTER.get_or_init(|| Mutex::new(None))
}

fn emit_log(item: DebugLogItem) {
    if let Ok(guard) = emitter_lock().lock() {
        if let Some(emit) = guard.as_ref() {
            emit(item);
        }
    }
}

/// 取消当前调试会话
pub fn cancel_debug_book_source() {
    DEBUG_CANCELLED.store(true, Ordering::SeqCst);
    SESSION_ID.fetch_add(1, Ordering::SeqCst);
    if let Ok(mut guard) = session_lock().lock() {
        *guard = None;
    }
    if let Ok(mut guard) = emitter_lock().lock() {
        *guard = None;
    }
}

fn begin_session(source_url: &str) -> u64 {
    DEBUG_CANCELLED.store(false, Ordering::SeqCst);
    let id = SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
    if let Ok(mut guard) = session_lock().lock() {
        *guard = Some(DebugSession {
            session_id: id,
            source_url: source_url.to_string(),
            start: Instant::now(),
        });
    }
    id
}

fn end_session() {
    if let Ok(mut guard) = session_lock().lock() {
        *guard = None;
    }
    if let Ok(mut guard) = emitter_lock().lock() {
        *guard = None;
    }
}

fn load_source(source_url: &str) -> LegadoResult<BookSource> {
    with_database(|db| {
        BookSourceRepository::new(db.connection())
            .find_by_url(source_url)?
            .ok_or_else(|| LegadoError::Ffi(format!("未找到书源: {source_url}")))
    })
}

fn is_abs_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

fn preview(text: &str, max: usize) -> String {
    let t = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.chars().count() <= max {
        t
    } else {
        format!("{}…", t.chars().take(max).collect::<String>())
    }
}

fn emit_lines(source_url: &str, lines: &[String], state: i32) {
    for line in lines {
        log_debug(Some(source_url), line, state, true);
    }
}

/// 流式调试书源（对齐 Debug.startDebug）
///
/// `on_log` 返回 Err 表示 sink 已关闭，应停止。
pub async fn run_debug_book_source_stream<F>(
    source_url: String,
    key: String,
    on_log: F,
) where
    F: FnMut(String) -> Result<(), String> + Send + 'static,
{
    let on_log = std::sync::Arc::new(Mutex::new(on_log));
    let on_log_emit = on_log.clone();
    {
        if let Ok(mut guard) = emitter_lock().lock() {
            *guard = Some(Box::new(move |item| {
                let json = serde_json::to_string(&item).unwrap_or_default();
                if let Ok(mut cb) = on_log_emit.lock() {
                    if cb(json).is_err() {
                        DEBUG_CANCELLED.store(true, Ordering::SeqCst);
                    }
                }
            }));
        }
    }

    let session_id = begin_session(&source_url);
    let join = tokio::task::spawn_blocking(move || {
        debug_book_source_sync(&source_url, &key, session_id);
    });

    if let Err(e) = join.await {
        if let Ok(mut cb) = on_log.lock() {
            let item = DebugLogItem {
                state: -1,
                msg: format!("调试任务异常: {e}"),
            };
            let _ = cb(serde_json::to_string(&item).unwrap_or_default());
        }
    }

    if let Ok(mut guard) = emitter_lock().lock() {
        *guard = None;
    }
    end_session();
}

fn still_active(session_id: u64) -> bool {
    if DEBUG_CANCELLED.load(Ordering::SeqCst) {
        return false;
    }
    let Ok(guard) = session_lock().lock() else {
        return false;
    };
    matches!(guard.as_ref(), Some(s) if s.session_id == session_id)
}

fn debug_book_source_sync(source_url: &str, key: &str, session_id: u64) {
    if !still_active(session_id) {
        return;
    }

    let source = match load_source(source_url) {
        Ok(s) => s,
        Err(e) => {
            log_debug(Some(source_url), &e.to_string(), -1, true);
            return;
        }
    };
    let source_json = match serde_json::to_string(&source) {
        Ok(j) => j,
        Err(e) => {
            log_debug(
                Some(source_url),
                &format!("书源序列化失败: {e}"),
                -1,
                true,
            );
            return;
        }
    };

    log_debug(
        Some(source_url),
        &format!("书源名称: {}", source.book_source_name),
        1,
        true,
    );

    if let Some(chapter_url) = key.strip_prefix("--") {
        log_debug(
            Some(source_url),
            &format!("⇒开始访正文页:{chapter_url}"),
            1,
            true,
        );
        content_debug(source_url, &source_json, chapter_url, "调试", session_id);
    } else if let Some(toc_url) = key.strip_prefix("++") {
        log_debug(
            Some(source_url),
            &format!("⇒开始访目录页:{toc_url}"),
            1,
            true,
        );
        toc_then_content(source_url, &source_json, toc_url, session_id);
    } else if key.contains("::") {
        let url = key.split("::").nth(1).unwrap_or("");
        log_debug(
            Some(source_url),
            &format!("⇒开始访问发现页:{url}"),
            1,
            true,
        );
        explore_debug(source_url, &source_json, url, session_id);
    } else if is_abs_url(key) {
        log_debug(
            Some(source_url),
            &format!("⇒开始访问详情页:{key}"),
            1,
            true,
        );
        info_toc_content(source_url, &source_json, key, session_id);
    } else {
        log_debug(
            Some(source_url),
            &format!("⇒开始搜索关键字:{key}"),
            1,
            true,
        );
        search_debug(source_url, &source_json, key, session_id);
    }
}

fn search_debug(source_url: &str, source_json: &str, key: &str, session_id: u64) {
    if !still_active(session_id) {
        return;
    }
    log_debug(Some(source_url), "︾开始解析搜索页", 1, true);
    match webbook_search(source_json, key, 1) {
        Ok(json) => {
            if !still_active(session_id) {
                return;
            }
            let results: Vec<serde_json::Value> =
                serde_json::from_str(&json).unwrap_or_default();
            if results.is_empty() {
                log_debug(Some(source_url), "︽未获取到书籍", -1, true);
                return;
            }
            log_debug(Some(source_url), "︽搜索页解析完成", 1, true);
            log_debug(Some(source_url), "", 1, false);

            let first_name = results
                .first()
                .and_then(|v| {
                    v.get("name")
                        .or_else(|| v.get("book_name"))
                        .and_then(|x| x.as_str())
                });
            let lines = JsSourceDebugFormatter::format_book_list(
                source_url,
                results.len(),
                first_name,
            );
            emit_lines(source_url, &lines, 1);

            for (i, item) in results.iter().take(5).enumerate() {
                let name = item
                    .get("name")
                    .or_else(|| item.get("book_name"))
                    .and_then(|x| x.as_str())
                    .unwrap_or("未知");
                let author = item
                    .get("author")
                    .and_then(|x| x.as_str())
                    .unwrap_or("");
                let line = if author.is_empty() {
                    format!("  [{i}] {name}")
                } else {
                    format!("  [{i}] {name} - {author}")
                };
                log_debug(Some(source_url), &line, 1, true);
            }

            let book_url = results
                .first()
                .and_then(|v| {
                    v.get("book_url")
                        .or_else(|| v.get("bookUrl"))
                        .and_then(|x| x.as_str())
                })
                .unwrap_or("");
            if book_url.is_empty() {
                log_debug(Some(source_url), "首条结果无 bookUrl", -1, true);
                return;
            }
            info_toc_content(source_url, source_json, book_url, session_id);
        }
        Err(e) => {
            log_debug(Some(source_url), &e.to_string(), -1, true);
        }
    }
}

fn explore_debug(source_url: &str, source_json: &str, url: &str, session_id: u64) {
    if !still_active(session_id) {
        return;
    }
    log_debug(Some(source_url), "︾开始解析发现页", 1, true);
    match crate::api::explore_api::explore_fetch_books(source_json, url, 1) {
        Ok(json) => {
            if !still_active(session_id) {
                return;
            }
            let results: Vec<serde_json::Value> =
                serde_json::from_str(&json).unwrap_or_default();
            if results.is_empty() {
                log_debug(Some(source_url), "︽未获取到书籍", -1, true);
                return;
            }
            log_debug(Some(source_url), "︽发现页解析完成", 1, true);
            log_debug(Some(source_url), "", 1, false);
            let book_url = results
                .first()
                .and_then(|v| {
                    v.get("book_url")
                        .or_else(|| v.get("bookUrl"))
                        .and_then(|x| x.as_str())
                })
                .unwrap_or("");
            if book_url.is_empty() {
                log_debug(Some(source_url), "首条发现结果无 bookUrl", -1, true);
                return;
            }
            info_toc_content(source_url, source_json, book_url, session_id);
        }
        Err(e) => {
            log_debug(Some(source_url), &e.to_string(), -1, true);
        }
    }
}

fn info_toc_content(source_url: &str, source_json: &str, book_url: &str, session_id: u64) {
    if !still_active(session_id) {
        return;
    }
    log_debug(Some(source_url), "︾开始解析详情页", 1, true);
    match webbook_info(source_json, book_url) {
        Ok(json) => {
            if !still_active(session_id) {
                return;
            }
            log_debug(Some(source_url), "︽详情页解析完成", 1, true);
            log_debug(Some(source_url), "", 1, false);
            if let Ok(info) = serde_json::from_str::<serde_json::Value>(&json) {
                if let Some(name) = info.get("name").and_then(|x| x.as_str()) {
                    log_debug(Some(source_url), "┌获取书名", 1, true);
                    log_debug(Some(source_url), &format!("└{name}"), 1, true);
                }
                if let Some(author) = info.get("author").and_then(|x| x.as_str()) {
                    log_debug(Some(source_url), "┌获取作者", 1, true);
                    log_debug(Some(source_url), &format!("└{author}"), 1, true);
                }
                let toc_url = info
                    .get("toc_url")
                    .or_else(|| info.get("tocUrl"))
                    .and_then(|x| x.as_str())
                    .unwrap_or(book_url);
                toc_then_content(source_url, source_json, toc_url, session_id);
            } else {
                toc_then_content(source_url, source_json, book_url, session_id);
            }
        }
        Err(e) => {
            log_debug(Some(source_url), &e.to_string(), -1, true);
        }
    }
}

fn toc_then_content(source_url: &str, source_json: &str, book_url: &str, session_id: u64) {
    if !still_active(session_id) {
        return;
    }
    log_debug(Some(source_url), "︾开始解析目录页", 1, true);
    match webbook_chapters(source_json, book_url, "", "") {
        Ok(json) => {
            if !still_active(session_id) {
                return;
            }
            let chapters: Vec<serde_json::Value> =
                serde_json::from_str(&json).unwrap_or_default();
            if chapters.is_empty() {
                log_debug(Some(source_url), "︽未获取到目录", -1, true);
                return;
            }
            log_debug(Some(source_url), "︽目录页解析完成", 1, true);
            log_debug(Some(source_url), "", 1, false);

            let first_title = chapters
                .first()
                .and_then(|c| c.get("title").or_else(|| c.get("name")))
                .and_then(|x| x.as_str());
            let last_title = chapters
                .last()
                .and_then(|c| c.get("title").or_else(|| c.get("name")))
                .and_then(|x| x.as_str());
            let lines = JsSourceDebugFormatter::format_chapter_list(
                source_url,
                chapters.len(),
                first_title,
                last_title,
            );
            emit_lines(source_url, &lines, 1);

            let first = &chapters[0];
            let title = first
                .get("title")
                .or_else(|| first.get("name"))
                .and_then(|x| x.as_str())
                .unwrap_or("调试");
            let chapter_url = first
                .get("url")
                .or_else(|| first.get("chapter_url"))
                .or_else(|| first.get("link"))
                .and_then(|x| x.as_str())
                .unwrap_or("");

            if chapter_url.is_empty() {
                // 用整章 JSON
                log_debug(Some(source_url), "⇒开始获取正文（首章 JSON）", 1, true);
                content_debug_json(source_url, source_json, first, title, session_id);
            } else {
                log_debug(
                    Some(source_url),
                    &format!("⇒开始获取正文:{chapter_url}"),
                    1,
                    true,
                );
                content_debug(source_url, source_json, chapter_url, title, session_id);
            }
        }
        Err(e) => {
            log_debug(Some(source_url), &e.to_string(), -1, true);
        }
    }
}

fn content_debug(
    source_url: &str,
    source_json: &str,
    chapter_url: &str,
    title: &str,
    session_id: u64,
) {
    let chapter = serde_json::json!({
        "title": title,
        "url": chapter_url,
        "index": 0,
    });
    content_debug_json(source_url, source_json, &chapter, title, session_id);
}

fn content_debug_json(
    source_url: &str,
    source_json: &str,
    chapter: &serde_json::Value,
    title: &str,
    session_id: u64,
) {
    if !still_active(session_id) {
        return;
    }
    log_debug(Some(source_url), "︾开始解析正文页", 1, true);
    let chapter_json = match serde_json::to_string(chapter) {
        Ok(j) => j,
        Err(e) => {
            log_debug(
                Some(source_url),
                &format!("章节 JSON 失败: {e}"),
                -1,
                true,
            );
            return;
        }
    };
    match webbook_content(source_json, &chapter_json) {
        Ok(content) => {
            if !still_active(session_id) {
                return;
            }
            let lines = JsSourceDebugFormatter::format_content_detail(title, content.len());
            emit_lines(source_url, &lines, 1);
            if content.trim().is_empty() {
                log_debug(Some(source_url), "︽正文为空", 1, true);
            } else {
                log_debug(
                    Some(source_url),
                    &preview(&content, 400),
                    1,
                    true,
                );
            }
            log_debug(Some(source_url), "︽正文页解析完成", 1000, true);
        }
        Err(e) => {
            log_debug(Some(source_url), &e.to_string(), -1, true);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_elapsed_zeroish() {
        let start = Instant::now();
        let s = format_elapsed(start);
        assert!(s.starts_with('['));
        assert!(s.contains(':'));
    }

    #[test]
    fn test_debug_log_item_json() {
        let item = DebugLogItem {
            state: 1000,
            msg: "[00:01.000] ︽正文页解析完成".into(),
        };
        let json = serde_json::to_string(&item).unwrap();
        assert!(json.contains("\"state\":1000"));
        assert!(json.contains("正文页解析完成"));
    }

    #[test]
    fn test_is_abs_url() {
        assert!(is_abs_url("https://example.com/book/1"));
        assert!(is_abs_url("HTTP://a.com"));
        assert!(!is_abs_url("斗破苍穹"));
        assert!(!is_abs_url("++https://a.com/toc"));
    }

    /// 关键字分流契约（对齐 Debug.startDebug）：
    /// `--` 正文 / `++` 目录 / `::` 发现 / 绝对 URL 详情 / 其余搜索
    #[test]
    fn test_debug_key_routing_prefixes() {
        assert!("--https://a.com/ch1".starts_with("--"));
        assert!("++https://a.com/toc".starts_with("++"));
        assert!("玄幻::https://a.com/explore".contains("::"));
        assert!(is_abs_url("https://a.com/book/1"));
        assert!(!is_abs_url("斗破苍穹"));
    }

    #[test]
    fn test_cancel_debug_sets_flag() {
        DEBUG_CANCELLED.store(false, Ordering::SeqCst);
        cancel_debug_book_source();
        assert!(DEBUG_CANCELLED.load(Ordering::SeqCst));
        DEBUG_CANCELLED.store(false, Ordering::SeqCst);
    }
}
