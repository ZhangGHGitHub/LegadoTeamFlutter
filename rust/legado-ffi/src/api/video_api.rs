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
}
