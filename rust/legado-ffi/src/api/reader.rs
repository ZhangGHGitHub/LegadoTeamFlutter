//! 阅读 API
//!
//! 提供章节列表获取与章节内容读取能力，支持在线书源与本地书籍两种模式。
//! 在线书籍支持通过网络刷新书籍目录（refresh_toc）和抓取正文（fetch_chapter_content）。

use serde::{Deserialize, Serialize};

use legado_core::cache_book::CachedChapter;
use legado_core::content_processor::{
    ContentProcessor, ProcessorConfig, ReplaceJsExecutor, ReplaceRuleEntry,
};
use legado_core::models::{book_type, Book, BookChapter, ReplaceRule};
use legado_core::web_book::{BookSourceFetcher, WebBookEngine, WebChapter};
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{
    BookChapterRepository, BookRepository, BookSourceRepository, CacheBookRepository,
    CacheRepository, ReplaceRuleRepository,
};

use crate::api::replace_rule_js::{
    ReplaceJsBindings, ReplaceJsBook, ReplaceJsChapter, ReplaceRuleJsExecutor,
};
use crate::db_state::{resolve_local_book_path, with_database};
use crate::runtime;

// ─── 简繁转换配置（对齐 Kotlin AppConfig.chineseConverterType） ──────────────

/// 配置键：繁简转换类型（与 Kotlin `PreferKey.chineseConverterType` 同名，
/// 备份恢复时可跨端互通）
const CHINESE_CONVERT_CONFIG_KEY: &str = "chineseConverterType";

/// [批1b-3] 配置键：无目录规则时每章最大字数（与参考版
/// `PreferKey.maxLengthWithNoToc` 同名，跨端备份可互通）
const MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY: &str = "maxLengthWithNoToc";

/// 读取持久化的繁简转换类型（0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t）
///
/// 配置不存在、非数字或超出 0..=2 范围时回退为 0（不转换）。
pub fn get_chinese_convert_type() -> i32 {
    crate::api::config_api::get_config(CHINESE_CONVERT_CONFIG_KEY)
        .ok()
        .and_then(|v| v.parse::<i32>().ok())
        .filter(|t| (0..=2).contains(t))
        .unwrap_or(0)
}

/// 设置并持久化繁简转换类型（0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t）
///
/// 非法取值一律归一为 0（不转换），与 Kotlin 面板仅提供三个选项的语义对齐。
pub fn set_chinese_convert_type(convert_type: i32) {
    let normalized = if (0..=2).contains(&convert_type) {
        convert_type
    } else {
        0
    };
    let _ = crate::api::config_api::set_config(CHINESE_CONVERT_CONFIG_KEY, &normalized.to_string());
}

/// 繁简转换类型 → content_processor 管线方向（None / "t2s" / "s2t"）
fn chinese_convert_direction(convert_type: i32) -> Option<String> {
    match convert_type {
        1 => Some("t2s".to_string()),
        2 => Some("s2t".to_string()),
        _ => None,
    }
}

/// 当前配置的管线转换方向（读取持久化配置）
fn current_chinese_convert_direction() -> Option<String> {
    chinese_convert_direction(get_chinese_convert_type())
}

// ─── 替换净化默认开关（批7a，对齐 Kotlin AppConfig.replaceEnableDefault）────────

/// 配置键：默认启用替换净化（与 Kotlin `PreferKey.replaceEnableDefault` 同名）
const REPLACE_ENABLE_DEFAULT_CONFIG_KEY: &str = "replaceEnableDefault";

/// 读取「默认启用替换净化」（缺省/非法 → true）
///
/// 语义对齐 Kotlin `AppConfig.replaceEnableDefault`
/// （`app/src/main/java/io/legado/app/help/config/AppConfig.kt:774`
/// `getPrefBoolean(PreferKey.replaceEnableDefault, true)`）：
/// - 缺省 / 空串 / 非法 → `true`；
/// - `"false"` / `"0"`（忽略大小写与首尾空白）→ `false`；
/// - 其余 → `true`。
///
/// 参考同文件 [`get_chinese_convert_type`] 的 config_api 用法：读取失败
/// （DB 不可用等）同样回落 `true`，不阻断正文读取。
fn get_replace_enable_default() -> bool {
    match crate::api::config_api::get_config(REPLACE_ENABLE_DEFAULT_CONFIG_KEY) {
        Ok(raw) => !matches!(raw.trim().to_lowercase().as_str(), "false" | "0"),
        Err(_) => true,
    }
}

/// 书籍实体是否为本地书（对齐 Kotlin `Book.isLocal`，与
/// `legado-server/src/legacy/book_api.rs` 的 `is_local_book(&Book)` 同口径）
///
/// - `bookType == 0`（历史数据未写类型）→ 按 origin 判定
///   （`loc_book` 或 `webDav::`/存量 `dav:`）；
/// - `bookType != 0` → 只看 local 位（Rust 域 0x1000 与原版 0x100 双标准）。
fn is_local_book_entity(book: &Book) -> bool {
    if book.book_type == 0 {
        return book.origin == book_type::LOCAL_TAG || book_type::is_web_dav_origin(&book.origin);
    }
    book_type::is_local_type(book.book_type)
}

/// 是否本地 epub（对齐 Kotlin `Book.isEpub`：`isLocal &&
/// originName.endsWith(".epub", true)`，BookExtensions.kt:61-62）
///
/// 注意：只看书籍实体的本地类型 + `originName`，**不能**用 `bookUrl` 后缀
/// 白名单判定——在线书籍的 `bookUrl` 也可能以 `.epub` 结尾。
fn is_local_epub_book(book: &Book) -> bool {
    is_local_book_entity(book) && book.origin_name.to_lowercase().ends_with(".epub")
}

/// 该书是否启用替换规则（对齐 Kotlin `Book.getUseReplaceRule()`，
/// `app/src/main/java/io/legado/app/data/entities/Book.kt:232-242`）
///
/// 优先级（逐条对齐上游）：
/// 1. `readConfig.useReplaceRule` 显式非空 → 取该值（`false` 也尊重；
///    图片/epub 书显式 `Some(true)` 同样开启）；
/// 2. 图片类书（`book.bookType & BookType.image != 0`）或本地 epub
///    （书籍实体为本地书且 `originName` 小写以 `.epub` 结尾）→ 默认关闭；
/// 3. 其余回退全局 [`get_replace_enable_default`]。
///
/// 无书籍行（`None`）→ 按全局默认处理（保持既有行为默认 `true`）。
fn use_replace_rule_for_book(book: Option<&Book>) -> bool {
    let Some(book) = book else {
        return get_replace_enable_default();
    };
    if let Some(value) = book
        .read_config
        .as_ref()
        .and_then(|config| config.use_replace_rule)
    {
        return value;
    }
    let is_image_book = book.book_type & book_type::IMAGE_BIT != 0;
    if is_image_book || is_local_epub_book(book) {
        return false;
    }
    get_replace_enable_default()
}

// ─── 无目录规则时每章最大字数（批1b-3，对齐参考版 PreferKey.maxLengthWithNoToc）───

/// 读取无目录规则时每章最大字数（caches `config:maxLengthWithNoToc`）
///
/// 缺省/非数字/越界回落默认 3000，范围内原样保留（对齐参考版
/// `ReadConfigViewModel` 写入口 `coerceIn(3000, 100000)` 与
/// `ReadSettings.maxLengthWithNoToc` 默认 3000；DB 读取失败同样回落默认，
/// 不阻断目录解析）。注意：夹逼语义与写入侧一致——**越界值夹到边界**
/// （如 100 → 3000、200000 → 100000），非数字/空值回落 3000。
fn get_max_length_with_no_toc() -> u32 {
    let parsed = crate::api::config_api::get_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY)
        .ok()
        .and_then(|v| v.trim().parse::<u32>().ok());
    match parsed {
        Some(v)
            if (legado_book::txt::MIN_MAX_LENGTH_WITH_NO_TOC
                ..=legado_book::txt::MAX_MAX_LENGTH_WITH_NO_TOC)
                .contains(&v) =>
        {
            v
        }
        Some(v) => {
            // 越界：夹到边界（保留用户量级意图，对齐 coerceIn）
            v.clamp(
                legado_book::txt::MIN_MAX_LENGTH_WITH_NO_TOC,
                legado_book::txt::MAX_MAX_LENGTH_WITH_NO_TOC,
            )
        }
        None => legado_book::txt::DEFAULT_MAX_LENGTH_WITH_NO_TOC,
    }
}

// ─── 章级「删除重复标题」开关（API_CONTRACT §2.9.10，Task #51） ───────────────

/// 章级开关存储键前缀（caches 表 KV，零迁移复用既有表结构）
///
/// 键格式：`sameTitleRemoved:{book_url}:{chapter_index}`，值 "1" 表示
/// 该章 opt-out（保留原始标题）；无键/其他值 → 全局默认（去除重复标题）。
/// 语义对齐原版：原版以 "nr" 后缀章节文件标记不删标题的章（removeSameTitleCache），
/// 此处等价地以 caches 键表达，缓存清理时开关随之复位为默认，与原版语义一致。
const SAME_TITLE_REMOVED_KEY_PREFIX: &str = "sameTitleRemoved:";

/// 构造章级开关的 caches 存储键
fn same_title_removed_key(book_url: &str, chapter_index: i32) -> String {
    format!("{SAME_TITLE_REMOVED_KEY_PREFIX}{book_url}:{chapter_index}")
}

/// 该章是否启用「去除重复标题」（全局默认 true；章级 opt-out 时 false）
///
/// DB 不可用/读取异常时回退全局默认 true，不阻断正文读取。
fn is_same_title_removed(book_url: &str, chapter_index: i32) -> bool {
    // DB 读取异常不再静默吞错：warn 后回退全局默认 true（返回值行为不变）
    let value = match with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.get(&same_title_removed_key(book_url, chapter_index))
    }) {
        Ok(value) => value,
        Err(e) => {
            log::warn!("读取章级删除重复标题开关失败，回退全局默认 true: {e}");
            None
        }
    };
    !matches!(value.as_deref(), Some("1"))
}

/// 权威查询章级「删除重复标题」开关（caches KV，对齐 §5.14 遗留）
///
/// 返回值语义同 [`is_same_title_removed`]：true=去除重复标题（默认），
/// false=该章 opt-out。供 Flutter 菜单勾选态回读，避免仅依赖 SP 镜像分叉。
pub fn get_same_title_removed(book_url: &str, chapter_index: i32) -> bool {
    is_same_title_removed(book_url, chapter_index)
}

/// 试算正文开头是否含可移除的重复标题（对齐原版 toast「未找到可移除的重复标题」）
pub fn can_remove_same_title(chapter_title: &str, raw_content: &str) -> bool {
    if chapter_title.is_empty() || raw_content.is_empty() {
        return false;
    }
    raw_content.trim_start().starts_with(chapter_title)
}

/// 章级「删除重复标题」开关（契约 §2.9.10，加法式新增）
///
/// 状态持久化于 caches 表，重启后保持。`enable=true` 恢复全局默认
/// （去除重复标题，删除 opt-out 记录）；`enable=false` 为该章 opt-out
/// （保留原始标题）。
///
/// 错误码：书籍不存在 → Internal；章节不存在 → Db。
pub fn toggle_same_title_removed(
    book_url: &str,
    chapter_index: i32,
    enable: bool,
) -> LegadoResult<()> {
    // 1. 书籍存在性校验（不存在 → Internal 错误）
    let book_exists = with_database(|db| {
        Ok(BookRepository::new(db.connection())
            .find_by_url(book_url)?
            .is_some())
    })?;
    if !book_exists {
        return Err(LegadoError::Internal(format!("书籍不存在: {book_url}")));
    }

    // 2. 章节存在性校验（不存在 → Db 错误）
    let chapter_exists = with_database(|db| {
        Ok(BookChapterRepository::new(db.connection())
            .find_by_book_url_and_index(book_url, chapter_index)?
            .is_some())
    })?;
    if !chapter_exists {
        return Err(LegadoError::Database(format!(
            "章节 {chapter_index} 不存在: {book_url}"
        )));
    }

    // 3. 持久化：opt-out 写 "1"；恢复默认则删除记录（保持存储精简）
    with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        let key = same_title_removed_key(book_url, chapter_index);
        if enable {
            repo.delete(&key)?;
        } else {
            repo.put(&key, "1", 0)?; // ttl=0 永不过期
        }
        Ok(())
    })
}

/// 按当前繁简配置转换单个标题文本
///
/// 对齐 Kotlin `BookChapter.getDisplayTitle`（BookChapter.kt L132-135）：
/// 1 → t2s（繁转简），2 → s2t（简转繁），其他不转换。
fn convert_title_by_type(title: &str, convert_type: i32) -> String {
    match convert_type {
        1 => legado_core::chinese_convert::traditional_to_simplified(title),
        2 => legado_core::chinese_convert::simplified_to_traditional(title),
        _ => title.to_string(),
    }
}

/// 对章节列表的标题应用当前繁简转换（仅转换返回副本，不回写数据库）
///
/// 阅读器/目录展示路径不经过 content_processor 正文管线，
/// 标题的繁简转换需在此显示层补齐，与 Android getDisplayTitle 行为对等。
fn apply_title_convert(chapters: &mut [BookChapter]) {
    let convert_type = get_chinese_convert_type();
    if convert_type == 0 {
        return;
    }
    for ch in chapters.iter_mut() {
        ch.title = convert_title_by_type(&ch.title, convert_type);
    }
}

/// 章节列表响应（包含章节概要信息）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChapterListResponse {
    /// 章节总数
    pub total: i32,
    /// 章节列表
    pub chapters: Vec<BookChapter>,
    /// 本次目录是否真正应用了该书的显式 TXT 目录规则（[批43b P2-1]）
    ///
    /// 语义仅在**本地 TXT 懒解析**时有效：
    /// - `true`：`books.tocUrl` 中的规则命中并用于分章；
    /// - `false`：未配置规则（默认规则）或规则不可用/未命中而回退内置默认。
    ///
    /// 目录缓存命中（未重新解析）、在线书与其它本地格式恒为 `false`。
    /// `#[serde(default)]` 兼容旧调用方：缺字段按 false 处理。
    #[serde(default)]
    pub used_custom_rule: bool,
}

/// 获取指定书籍的章节列表
///
/// 优先从数据库读取；若数据库无记录且为本地书籍，则从文件解析章节并入库（懒加载）。
///
/// [iOS 视角F C1] 本地书 `book_url` 可能是相对可迁移标识（`books/x.epub`），
/// 落盘解析前经 [`resolve_local_book_path`] 还原为当前容器真实路径；DB 查询与
/// 章节行 `book_url`/`base_url` 仍用原始标识（保持主键一致）。绝对路径原样透传。
pub fn get_chapters(book_url: &str) -> LegadoResult<ChapterListResponse> {
    // 1. 尝试从数据库读取已有章节
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;

    if !chapters.is_empty() {
        let mut chapters = chapters;
        // [批43b P1-2] 缓存命中也要校验/回填目录派生字段：`setBookTocRule`
        // 返回的 Book 派生字段已重置，若 Dart 曾整书写回 0/NULL，后续目录
        // 读取不能继续沿用坏值（这里以 chapters 表为真源修复 books 行）。
        sync_cached_toc_derived_fields(book_url, &chapters)?;
        apply_title_convert(&mut chapters);
        let total = chapters.len() as i32;
        return Ok(ChapterListResponse {
            total,
            chapters,
            used_custom_rule: false,
        });
    }

    // 2. 数据库无章节：如果是本地书籍，从文件解析并入库
    if is_local_book(book_url) {
        // [C1] 还原为真实文件路径（相对标识 → 当前 Documents；绝对原样）
        let real_path = resolve_local_book_path(book_url);
        // [批43b P2-2] 解析（读文件）与落库之间可能插入并发写：
        // `set_book_toc_rule` / `set_book_charset` 会清空目录并改写设置。
        // 若把按旧设置解析的结果落库，会把并发设置后的新目录覆盖成旧章节。
        // 处理：解析前取设置快照 → 解析 → BEGIN IMMEDIATE 事务内复查
        // charset/tocUrl 未变才写入；变了丢弃本次结果并按新设置重解析一次。
        const MAX_LOCAL_PARSE_ATTEMPTS: u32 = 2;
        let mut last_error: Option<String> = None;
        for attempt in 1..=MAX_LOCAL_PARSE_ATTEMPTS {
            // 设置快照同时包含解码编码与目录规则来源（同一行读取，避免两次
            // 查询落在不同版本上）
            let snapshot = local_parse_snapshot(book_url)?;
            let charset = snapshot.charset_label().map(str::to_string);
            // [批43] 本地 TXT 优先使用该书显式目录规则（`books.tocUrl`，原版
            // `rule + spaceChars + replacement`）；其它格式忽略该字段。
            let (toc_rule, toc_replacement) = snapshot
                .toc_url
                .as_deref()
                .map(legado_book::txt::split_toc_rule)
                .unwrap_or((None, String::new()));
            if toc_rule.is_some() && !toc_replacement.trim().is_empty() {
                log::warn!(
                    "TXT 目录规则包含 JS 替换片段，Rust 解析不执行替换（标题保留正则命中原文）: {book_url}"
                );
            }
            let outcome = legado_book::LocalBook::get_chapters_with_rule_config(
                &real_path,
                charset.as_deref(),
                toc_rule.as_deref(),
                // [批1b-3] 无目录规则时的长度分章档位（config:maxLengthWithNoToc，
                // 缺省/非法回落 3000、越界夹逼 3000..100000）
                get_max_length_with_no_toc(),
            )?;
            if toc_rule.is_some() && !outcome.used_custom_rule {
                log::warn!("TXT 目录规则未命中或不可用，已回退内置默认规则: {book_url}");
            }
            let used_custom_rule = outcome.used_custom_rule;
            let chapter_infos = outcome.chapters;
            let mut book_chapters: Vec<BookChapter> = chapter_infos
                .iter()
                .map(|ci| BookChapter {
                    url: ci.url.clone(),
                    title: ci.title.clone(),
                    is_volume: ci.is_volume,
                    base_url: book_url.to_string(),
                    book_url: book_url.to_string(),
                    index: ci.index,
                    is_vip: false,
                    is_pay: false,
                    resource_url: None,
                    tag: None,
                    word_count: None,
                    start: ci.start,
                    end: ci.end,
                    start_fragment_id: None,
                    end_fragment_id: None,
                    variable: None,
                    img_url: None,
                })
                .collect();

            // 存入数据库供后续访问（[B-13b] 同事务同步目录派生字段）
            let committed =
                persist_local_chapters_if_unchanged(book_url, &snapshot, &book_chapters)?;
            if !committed {
                log::warn!(
                    "目录解析期间 charset/tocUrl 被并发修改，丢弃第 {attempt} 次解析结果并重试: {book_url}"
                );
                last_error = Some("目录解析期间书籍编码或目录规则被并发修改".to_string());
                continue;
            }

            // 显示层标题繁简转换（不回写数据库）
            apply_title_convert(&mut book_chapters);

            let total = book_chapters.len() as i32;
            return Ok(ChapterListResponse {
                total,
                chapters: book_chapters,
                used_custom_rule,
            });
        }
        return Err(LegadoError::Database(format!(
            "{}，请重试: {book_url}",
            last_error.unwrap_or_else(|| "目录解析失败".to_string())
        )));
    }

    // 3. 在线书籍无章节记录，返回空
    Ok(ChapterListResponse {
        total: 0,
        chapters: vec![],
        used_custom_rule: false,
    })
}

/// 本地目录懒解析的设置快照（[批43b P2-2]）
///
/// 与解析结果一起用于落库前的并发复查：数据库中 `charset` / `tocUrl`
/// 仍与快照一致才写入，否则说明用户并发改设置（`setBookTocRule` /
/// `setBookCharset`）并已清空旧目录，本次结果必须丢弃。
#[derive(Debug, Clone, PartialEq, Eq)]
struct LocalParseSnapshot {
    /// 原始 `books.charset`（未归一化，用于逐字比较；None = 未设置）
    charset: Option<String>,
    /// 原始 `books.tocUrl`；`None` = 该格式不消费该列（不参与比较）
    toc_url: Option<String>,
}

impl LocalParseSnapshot {
    /// 可用于解码的编码标签（空白/不支持的编码按未设置处理，与
    /// [`local_book_charset`] 的读取侧容错一致）
    fn charset_label(&self) -> Option<&str> {
        self.charset
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .filter(|s| legado_book::txt::encoding_for_label(s).is_ok())
    }
}

/// 读取本次懒解析使用的设置快照（一次 DB 查询）
fn local_parse_snapshot(book_url: &str) -> LegadoResult<LocalParseSnapshot> {
    let book = with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))?;
    let consumes_toc_url = crate::api::bookshelf::is_txt_path(book_url);
    Ok(match book {
        Some(book) => LocalParseSnapshot {
            toc_url: consumes_toc_url.then_some(book.toc_url),
            charset: book.charset,
        },
        // 书籍行缺失（临时书）：保持自动检测 + 默认规则，行为与旧实现一致
        None => LocalParseSnapshot {
            charset: None,
            toc_url: consumes_toc_url.then(String::new),
        },
    })
}

/// 落库本地解析结果前复查设置未变（[批43b P2-2]）
///
/// `BEGIN IMMEDIATE` 在事务起点取写锁：复查通过后到 COMMIT 之间没有其他
/// 写者能改写 `books.charset`/`books.tocUrl`，因此「复查 + 写入」是原子的。
/// 返回 `Ok(false)` 表示设置已被并发修改（事务无写入、直接回滚），调用方
/// 应按新设置重新解析。
fn persist_local_chapters_if_unchanged(
    book_url: &str,
    snapshot: &LocalParseSnapshot,
    chapters: &[BookChapter],
) -> LegadoResult<bool> {
    with_database(|db| {
        let conn = db.connection();
        let tx =
            rusqlite::Transaction::new_unchecked(conn, rusqlite::TransactionBehavior::Immediate)
                .map_err(|e| {
                    LegadoError::Database(format!("开启目录落库事务失败（BEGIN IMMEDIATE）: {e}"))
                })?;

        let current = BookRepository::new(conn).find_by_url(book_url)?;
        let unchanged = match &current {
            Some(book) => {
                book.charset == snapshot.charset
                    && snapshot
                        .toc_url
                        .as_deref()
                        .is_none_or(|expected| book.toc_url == expected)
            }
            // 书籍行本来就不存在（临时书）：只允许「快照也是不存在」时落库
            None => {
                snapshot.charset.is_none()
                    && snapshot
                        .toc_url
                        .as_deref()
                        .is_none_or(|expected| expected.is_empty())
            }
        };
        if !unchanged {
            // 未执行任何写语句，drop 即回滚
            return Ok(false);
        }

        let new_total = chapters.len() as i32;
        let new_latest_title: Option<String> = chapters.last().map(|c| c.title.clone());
        BookChapterRepository::new(conn).insert_batch_no_tx(chapters)?;
        let book_repo = BookRepository::new(conn);
        if let Some(existing) = book_repo.find_by_url(book_url)? {
            book_repo.update_toc_derived_fields(
                book_url,
                new_total,
                new_latest_title.as_deref(),
                (existing.total_chapter_num < new_total).then_some(now_millis()),
            )?;
        }
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交目录落库事务失败: {e}")))?;
        Ok(true)
    })
}

/// 目录缓存命中时校验/回填 `books` 行目录派生字段（[批43b P1-2]）
///
/// `chapters` 表是目录真源：`totalChapterNum` 与实际行数不一致、或
/// `latestChapterTitle` 与末章标题不一致时，以 chapters 为准单列修复
/// （`update_toc_derived_fields` 只触碰派生列，不写进度/其他列）。
/// `latestChapterTime` 仍沿用「仅章数增长时写入」语义；修复章数变小时保留
/// 旧时间（不影响用户可见内容）。
fn sync_cached_toc_derived_fields(book_url: &str, chapters: &[BookChapter]) -> LegadoResult<()> {
    if chapters.is_empty() {
        return Ok(());
    }
    let total = chapters.len() as i32;
    let latest_title = chapters.last().map(|c| c.title.clone());
    with_database(|db| {
        let repo = BookRepository::new(db.connection());
        let Some(existing) = repo.find_by_url(book_url)? else {
            return Ok(());
        };
        if existing.total_chapter_num == total && existing.latest_chapter_title == latest_title {
            return Ok(());
        }
        repo.update_toc_derived_fields(
            book_url,
            total,
            latest_title.as_deref(),
            (existing.total_chapter_num < total).then_some(now_millis()),
        )
    })
}

/// 获取章节正文内容
///
/// 对于本地书籍（bookUrl 为文件路径或相对可迁移标识），使用 legado-book 解析器读取。
/// 对于在线书籍，需配合书源规则通过网络获取（此处返回数据库缓存或空）。
///
/// [iOS 视角F C1] 本地书 `book_url` 为相对可迁移标识时，经 [`resolve_local_book_path`]
/// 还原为当前容器真实路径后再落盘解析；章节 DB 查询仍用原始标识。
pub fn get_chapter_content(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    get_chapter_content_inner(book_url, chapter_index, true)
}

/// 获取章节正文内容（不应用替换规则）
///
/// 取正文流程与 [`get_chapter_content`] 完全相同，但内容净化时关闭替换规则
/// （仅做去重复标题等），与 Android 书内搜索默认行为（replaceEnabled=false）对齐。
/// 供内容搜索使用，避免被替换/删除的词搜不到。
pub fn get_chapter_content_raw(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    get_chapter_content_inner(book_url, chapter_index, false)
}

/// get_chapter_content 的内部实现：`apply_replace_rules` 控制是否应用替换规则
fn get_chapter_content_inner(
    book_url: &str,
    chapter_index: i32,
    apply_replace_rules: bool,
) -> LegadoResult<String> {
    // 查询章节信息
    let chapter = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url_and_index(book_url, chapter_index)
    })?
    .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;

    // 判断是否为本地书籍
    if is_local_book(book_url) {
        // 使用 legado-book 解析本地文件
        // [C1] 还原为真实文件路径（相对标识 → 当前 Documents；绝对原样）
        let real_path = resolve_local_book_path(book_url);
        // [批37b P1-1] 消费 `Book.charset`：阅读器「设置编码」后正文按
        // 用户指定编码解码（检测/默认之上）；TXT 之外的格式忽略该值
        let charset = local_book_charset(book_url)?;
        let content = legado_book::LocalBook::get_chapter_content_with_charset(
            &real_path,
            &chapter_to_local_info(&chapter),
            charset.as_deref(),
        )?;
        // 读取时净化：DB/文件保留原始正文，返回前应用内容净化
        Ok(apply_content_processing_inner(
            book_url,
            &content,
            &chapter.title,
            apply_replace_rules,
            Some(chapter_index),
            Some(&chapter.url),
            true,
        ))
    } else {
        // 在线书籍：返回章节 URL 信息，由上层配合书源规则获取正文
        // 简化实现：返回章节 URL 供 Dart 侧进一步处理（标题做显示层繁简转换）
        Ok(serde_json::to_string(&serde_json::json!({
            "chapter_url": chapter.url,
            "base_url": chapter.base_url,
            "title": convert_title_by_type(&chapter.title, get_chinese_convert_type()),
            "need_fetch": true,
        }))?)
    }
}

/// 读取本地书的 `Book.charset`（未设置/书籍不存在时返回 `None`）
///
/// [批37b P1-1] 编码覆盖只对 TXT 生效；书籍行缺失时保持自动检测行为，
/// 不让「查不到书」把正文读取变成硬失败（懒解析/临时书场景仍可读）。
///
/// 库内编码名若已无法被 `encoding_rs` 识别（手工改库/历史脏值），读取侧
/// 按未设置处理回退自动检测——设置入口本身 fail-closed，不会写入脏值；
/// 读取侧再报错只会让整本书打不开，代价大于收益。
pub(crate) fn local_book_charset(book_url: &str) -> LegadoResult<Option<String>> {
    let charset = with_database(|db| {
        Ok(BookRepository::new(db.connection())
            .find_by_url(book_url)?
            .and_then(|book| book.charset))
    })?;
    Ok(charset
        .filter(|value| !value.trim().is_empty())
        .filter(|value| legado_book::txt::encoding_for_label(value).is_ok()))
}

/// 判断是否为本地书籍
///
/// [cbz 批 B | 2026-10-03] 白名单新增 `.cbz`（本地漫画包，E9 参考版扩展：
/// 命中后 `get_chapters` 懒解析经 `LocalBook` → `CbzFile`，正文返回
/// `cbz://<条目名>` 行列表，图片字节经 `cbz_api::cbz_read_page` 读取）。
/// `.zip` **不加入**：保持压缩容器语义（`archiveImportZip` 路径不变）。
pub fn is_local_book(book_url: &str) -> bool {
    let lower = book_url.to_lowercase();
    lower.ends_with(".epub")
        || lower.ends_with(".txt")
        || lower.ends_with(".text")
        || lower.ends_with(".mobi")
        || lower.ends_with(".azw")
        || lower.ends_with(".azw3")
        || lower.ends_with(".pdf")
        || lower.ends_with(".cbz")
}

/// 将 BookChapter 转换为 legado-book 的 ChapterInfo
pub fn chapter_to_local_info(ch: &BookChapter) -> legado_book::ChapterInfo {
    legado_book::ChapterInfo {
        url: ch.url.clone(),
        title: ch.title.clone(),
        index: ch.index,
        is_volume: ch.is_volume,
        start: ch.start,
        end: ch.end,
    }
}

// ─── 在线目录/正文抓取 ────────────────────────────────────────────────────────

/// 当前 Unix 时间戳（毫秒）——目录派生字段同步写 latestChapterTime 用
/// （与本模块缓存写入处的 SystemTime 表达式同一实现风格）
fn now_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// 从网络刷新书籍目录
///
/// 流程：
/// 1. 根据 `source_url` 从数据库查找书源配置
/// 2. 使用 WebBookEngine 从网络获取章节列表
///    （[P2-2] 首抓为空且书籍页取址点不同时，按取址点重试一次并持久化新 tocUrl）
/// 3. 将 WebChapter 转换为 BookChapter 并存入数据库
/// 4. 返回 JSON 格式的章节列表
pub fn refresh_toc(book_url: &str, source_url: &str) -> LegadoResult<ChapterListResponse> {
    // P1-2 入口收口：本入口执行 preUpdate JS + ruleBookInfo/ruleToc（变量桥
    // 读写）→ 先切 flow scope（键 = book_url，与 webbook_info/chapters 同键），
    // 防上一流程的残留 scope 串读/误清
    crate::api::web_book::begin_book_flow(book_url);
    // 生产入口：构建真实 engine 后委托核心逻辑（fetcher 泛型化便于单测注入脚本化 fetcher）
    let engine = super::web_book::build_engine()?;
    refresh_toc_with_fetcher(book_url, source_url, &engine)
}

/// refresh_toc 核心逻辑（fetcher 泛型化，便于单测注入脚本化 fetcher；
/// 生产入口 [`refresh_toc`] 构建真实 engine 后委托本函数）
fn refresh_toc_with_fetcher<F: BookSourceFetcher>(
    book_url: &str,
    source_url: &str,
    engine: &WebBookEngine<F>,
) -> LegadoResult<ChapterListResponse> {
    // [性能专项 2026-09-24] 刷新代数 +1：本刷新成为最新代数，使在途旧刷新的
    // 目录分页链在下一页边界判活失败而中止（换源场景取消 10 分钟在途链；
    // 对齐上游 ensureActive() 判活语义，无状态 FFI 用进程级原子计数器，
    // 不改 FFI 签名）。
    crate::api::web_book::bump_toc_fetch_epoch();
    // 1. 从数据库获取书源配置 + 书籍记录（书籍用于确定真实的目录抓取 URL）
    let (source, existing_book) = with_database(|db| {
        let source = BookSourceRepository::new(db.connection()).find_by_url(source_url)?;
        let book = legado_db::BookRepository::new(db.connection()).find_by_url(book_url)?;
        Ok((source, book))
    })?;
    let source =
        source.ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // Task #21 修复：抓取目录用书籍的 tocUrl，而非 bookUrl。换源后 bookUrl 作为
    // 稳定主键保持旧源 URL（在新源上并非有效地址），tocUrl 才指向当前书源的
    // 详情/目录页；用 bookUrl 抓取会把旧源 URL 传给新源解析器导致目录获取失败
    // （用户反馈「目录也获取不到」的根因之一）。tocUrl 为空时回退 bookUrl，
    // 对齐原版 WebBook.getChapterList 以 book.tocUrl 为目录页地址的行为。
    // [P2-8] 回退链细化为 tocUrl → originBookUrl（当前书源详情页，换源事务
    // 写入；tocUrl 可能已被坏值污染或为空）→ bookUrl（未换源书籍/存量库，
    // 行为不变）。
    // 目录更新前钩子（对齐 WebBook.getChapterListAwait(runPerJs=true) → runPreUpdateJs）
    // 须在计算 fetch_url 之前执行，以便 reGetBook/refreshTocUrl/手写改 book 生效
    let mut working_book = existing_book.clone();
    if let Some(ref mut book) = working_book {
        if let Err(e) = crate::api::pre_update::run_pre_update_js(&source, book) {
            eprintln!("[refresh_toc] preUpdateJs: {e}");
        } else {
            // 持久化 preUpdateJs / 钩子对 bookUrl·tocUrl·variable 等的改写。
            // [B-4] 这是全行快照写回，但 `update` 的 UPDATE SET 结构性排除
            // 进度列（B-3），钩子执行/持久化期间并发写入的进度不会被回退
            // （此处零代码改动，靠结构排除保护进度）。
            let _ =
                with_database(|db| legado_db::BookRepository::new(db.connection()).update(book));
        }
    }

    let fetch_url = working_book
        .as_ref()
        .map(|b| {
            let toc = b.toc_url.trim();
            if !toc.is_empty() {
                toc.to_string()
            } else {
                // [P2-8] 书籍页取址（originBookUrl 优先、空回退 bookUrl，见
                // Book::book_page_fetch_url）；两者皆空时回退入参 book_url
                let origin = b.book_page_fetch_url();
                if origin.trim().is_empty() {
                    book_url.to_string()
                } else {
                    origin.to_string()
                }
            }
        })
        .unwrap_or_else(|| book_url.to_string());

    // [P2-12 2026-09-18] 变量链：目录/详情请求模板经 DB `books.variable`
    // （working_book.variable——preUpdateJs 钩子运行后已持久化的用户值）
    // 展开。优先级：DB 持久化值（用户显式设置）> 书源 `@put` 默认导出，
    // 与换源链 P1-1 理由一致（本刷新路径无 @put 再合并，仅更新目录）。
    // 修复前两处 get_chapters 变量表恒空 → 换源后重进详情/刷新目录时
    // `{{svid}}`/`{{tok}}` 展开为空 → 请求错误地址（服务端 400）。
    let toc_variables = super::web_book::chapter_url_variables(
        working_book.as_ref().and_then(|b| b.variable.as_deref()),
    );

    // 2. 使用 WebBookEngine 从网络获取章节列表（变量表见上方 P2-12 注释）
    // [bookUrl 脏值修正 2026-10-05] 身份/取址点分离：本入口的 `book_url` 入参
    // 是书籍稳定主键（DB `find_by_url` 查询键），`fetch_url` 只是取址点
    //（tocUrl / 书籍页取址点 / 回退 bookUrl）。旧调用把取址点当 book_url 传给
    // fetcher → 目录阶段 meta 缓存把 tocUrl 记成“书籍取址点”并经 (书源, 章节)
    // 反查泄漏到正文阶段 `book` 绑定与媒体副内容 sink（弹幕/歌词落库键，
    // V-B1 审查已登记的静默丢弹幕面）。对齐原版 WebBook.getChapterListAwait
    //（book.bookUrl 主键 + book.tocUrl 取址点二元语义，WebBook.kt:310-326）。
    let book_key = book_url;
    let mut web_chapters: Vec<WebChapter> = runtime::block_on(async {
        engine
            .get_chapters_with_book_key_and_vars(
                &source,
                &fetch_url,
                book_key,
                None,
                None,
                &toc_variables,
            )
            .await
    })?;

    // [P2-2 | 存量坏 tocUrl 自愈 2026-09-18] 首次抓取（通常按 tocUrl）未解析到
    // 章节（存量坏值：如换源后 tocUrl 仍指向旧源页面、页面改版后不再含目录），
    // 且书籍页取址点（book_page_fetch_url：originBookUrl 优先、空回退 bookUrl）
    // 与已尝试的抓取地址不同 → 按书籍页地址重试一次；成功则把新 tocUrl 持久化
    //（对齐既有 update 语义：tocUrl 为当前书源目录页地址），后续刷新直达有效
    // 地址。`!= fetch_url` 同时覆盖「tocUrl 为空、首抓地址已是书籍页取址点」
    // 的情形，避免对同一地址重复抓取。
    if web_chapters.is_empty() {
        let retry_url = working_book
            .as_ref()
            .map(|b| b.book_page_fetch_url().to_string())
            .filter(|u| !u.trim().is_empty() && *u != fetch_url);
        if let Some(retry_url) = retry_url {
            // [P2-12] 重试同样携 DB 变量表（retry_url 为书籍页取址点，
            // 可能含 {{key}} 模板）
            // [bookUrl 脏值修正] 重试仍以 `book_url` 为主键、retry_url 为取址点
            match runtime::block_on(async {
                engine
                    .get_chapters_with_book_key_and_vars(
                        &source,
                        &retry_url,
                        book_key,
                        None,
                        None,
                        &toc_variables,
                    )
                    .await
            }) {
                Ok(chapters) if !chapters.is_empty() => {
                    // 持久化新 tocUrl；写库失败仅记录，不影响本次刷新结果。
                    // P2-1：改用单列 update_toc_url（全行 update 会把两次网络
                    // 抓取前读取的 37 列快照写回：期间并发写入的进度列
                    // （durChapterIndex 等）被旧值覆盖，且「本来正确但一次
                    // 瞬时解析为空」的 tocUrl 会被永久改写）。
                    if let Some(b) = working_book.as_mut() {
                        b.toc_url = retry_url.clone();
                        let book_url_key = b.book_url.clone();
                        let _ = with_database(|db| {
                            legado_db::BookRepository::new(db.connection())
                                .update_toc_url(&book_url_key, &retry_url)
                        });
                    }
                    web_chapters = chapters;
                }
                _ => {}
            }
        }
    }

    // Task #21 修复：空结果保护。新抓取未解析到任何章节时（get_chapters 返回
    // Ok(vec![]) 而非错误，如书源失效/页面改版），绝不清空已有目录——否则会把
    // 书留成「无章节」状态，比刷新前更糟（换源/刷新「越刷越糟」回归）。
    // 有旧章节则原样返回旧目录；无旧章节才返回可读错误。
    if web_chapters.is_empty() {
        let existing = with_database(|db| {
            BookChapterRepository::new(db.connection()).find_by_book_url(book_url)
        })?;
        if !existing.is_empty() {
            let mut existing = existing;
            apply_title_convert(&mut existing);
            let total = existing.len() as i32;
            return Ok(ChapterListResponse {
                total,
                chapters: existing,
                used_custom_rule: false,
            });
        }
        return Err(LegadoError::Parser(
            "刷新目录失败：未从书源解析到任何章节（书源可能失效，请尝试换源）".into(),
        ));
    }

    // 3. 转换为 BookChapter 并存入数据库
    //    P1-1/P2-1：卷章/付费标记与章节附加信息全量透传（统一走
    //    web_chapters_to_book_chapters，与换源/server 链共用同一转换语义）
    let book_chapters =
        legado_core::web_book::web_chapters_to_book_chapters(&web_chapters, book_url);

    // [目录派生字段同步] 对齐上游 updateBookTocInfo：刷新成功后 books 行
    // totalChapterNum = 新目录章数 / latestChapterTitle = 末章标题（截断保留
    // 前缀时 = 前缀章数，与上游一致；空结果不会走到这里——上方守卫已提前
    // 返回）。latestChapterTime 仅章数增长时写入（上游条件分支）。真实 origin
    // 书籍走单列 UPDATE 写器（只触碰派生字段，不写进度列——B-3 安全，P2-1
    // 风格）；占位/本地 origin 路径在同一内存对象上同步（全行写结构性排除
    // 进度列，B-3 安全）。
    let new_total = book_chapters.len() as i32;
    let new_latest_title: Option<String> = book_chapters.last().map(|c| c.title.clone());

    // 4. 确保书籍记录存在（满足 chapters 表外键约束），然后先删除旧章节，再批量插入新章节
    // [Task #66 加固] 占位落库须带书源信息（origin/originName）：否则 origin 取默认
    // loc_book，阅读器随后按 origin 找书源取正文会报「书源不存在: loc_book」
    // （搜索→目录页→点章节进入阅读的路径，此时 Flutter 尚未执行带 origin 的
    // addBook）。既有记录 origin 仍为默认值时同样补齐（加法式，不覆盖已有真实书源）。
    with_database(|db| {
        let conn = db.connection();
        // [B-7] 「删旧章节 + 写新章节 + 清失效缓存」包进同一事务：裸 autocommit
        // 删除会向并发读者暴露「0 章」中间态（对齐换源事务模式）。
        // delete_by_book_url 事务外为 no-op（见 BookChapterRepository）；
        // pool 共享 &Connection 无法用 &mut Connection::transaction()，
        // 沿用项目既有的 unchecked_transaction() 模式（见 source_switch.rs）。
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| LegadoError::Database(format!("开启目录更新事务失败: {e}")))?;
        let book_repo = legado_db::BookRepository::new(conn);
        match book_repo.find_by_url(book_url)? {
            None => {
                // Task#125：占位落库须打 NOT_SHELF，对齐原版 readBook 临时书 /
                // 书架 list_books 过滤；否则「仅浏览/拉目录」会污染书架。
                let mut book = legado_core::models::Book {
                    book_url: book_url.to_string(),
                    origin: source_url.to_string(),
                    origin_name: source.book_source_name.clone(),
                    book_type: legado_core::models::book::book_type::NOT_SHELF,
                    ..legado_core::models::Book::default()
                };
                // [目录派生字段同步] 新书无旧章数（0 < new_total 恒成立——
                // 目录非空守卫在前）→ 派生字段随插入一并写入
                book.total_chapter_num = new_total;
                book.latest_chapter_title = new_latest_title.clone();
                book.latest_chapter_time = now_millis();
                book_repo.insert(&book)?;
            }
            Some(mut existing)
                if existing.origin.is_empty()
                    || existing.origin == legado_core::models::book::book_type::LOCAL_TAG =>
            {
                existing.origin = source_url.to_string();
                if existing.origin_name.is_empty() {
                    existing.origin_name = source.book_source_name.clone();
                }
                // [目录派生字段同步] 同一内存对象上同步（全行 update 结构性
                // 排除进度列，B-3 安全）
                let old_total = existing.total_chapter_num;
                existing.total_chapter_num = new_total;
                existing.latest_chapter_title = new_latest_title.clone();
                if old_total < new_total {
                    existing.latest_chapter_time = now_millis();
                }
                book_repo.update(&existing)?;
            }
            Some(existing) => {
                // [目录派生字段同步] 真实 origin 书籍：单条 UPDATE 只触碰派生
                // 字段（不写进度列、不回退抓取前快照的其他列，B-3/P2-1 安全）；
                // latestChapterTime 仅章数增长时写（上游条件分支）
                book_repo.update_toc_derived_fields(
                    book_url,
                    new_total,
                    new_latest_title.as_deref(),
                    (existing.total_chapter_num < new_total).then_some(now_millis()),
                )?;
            }
        }
        let repo = BookChapterRepository::new(conn);
        repo.delete_by_book_url(book_url)?;
        repo.insert_batch_no_tx(&book_chapters)?;
        // [B-5] 目录变更后清理失效缓存（同事务）：章节 URL 已不在新目录中的
        // 缓存行删除，URL 未变的章节保留缓存（不强制重抓）
        legado_db::CacheBookRepository::new(conn).clear_stale_chapter_urls(book_url)?;
        tx.commit()
            .map_err(|e| LegadoError::Database(format!("提交目录更新事务失败: {e}")))?;
        Ok(())
    })?;

    // [B-6] 目录重写后按当前书源登记 (书源, 章节) → 下一章 URL：正文分页
    // 「命中下一章即截断」需按最新目录判定。本入口（refresh_toc）不经
    // web_book 的章节列表缓存链（record_chapter_list_cache），须在此显式登记；
    // registry 复合键 (书源, 章节) 天然隔离旧源登记，重复登记幂等。
    super::web_book::record_next_chapter_map(source_url, &web_chapters);

    // 显示层标题繁简转换（入库的是原始标题，仅转换返回副本）
    let mut book_chapters = book_chapters;
    apply_title_convert(&mut book_chapters);

    let total = book_chapters.len() as i32;
    Ok(ChapterListResponse {
        total,
        chapters: book_chapters,
        used_custom_rule: false,
    })
}

/// 获取章节正文内容（在线抓取，带 DB 缓存）
///
/// 流程：
/// 1. 先检查 DB 缓存（cached_chapters 表）
/// 2. 如果缓存命中，直接返回缓存的正文
/// 3. 如果缓存未命中：
///    a. 使用 WebBookEngine::get_content 从网络抓取正文
///    b. 将结果存入 DB 缓存
///    c. 返回真实正文文本
pub fn fetch_chapter_content(
    book_url: &str,
    chapter_url: &str,
    source_url: &str,
) -> LegadoResult<String> {
    // 取得真实章节序号与标题（供去重复标题与缓存使用）
    // [B-12] 第 4 项 known_chapter：未知章节 URL 时不得回退 (0, "") 并写
    // index=0 缓存行（污染缓存且目录云图标错位）
    let (chapter_index, chapter_title, chapter_variable, known_chapter, is_volume, is_vip) =
        get_chapter_index_title_variable(book_url, chapter_url)?;
    fetch_chapter_content_inner(
        book_url,
        chapter_url,
        source_url,
        chapter_index,
        &chapter_title,
        chapter_variable.as_deref(),
        known_chapter,
        is_volume,
        is_vip,
    )
}

/// 章节正文抓取核心逻辑（不含 get_chapter_index_and_title 查询）
///
/// 由 [`fetch_chapter_content`] 和 [`get_chapter_content_full`] 共用：
/// - `fetch_chapter_content` 先查询章节序号/标题再调用本函数
/// - `get_chapter_content_full` 已持有章节信息，直接调用本函数避免冗余查询
#[allow(clippy::too_many_arguments)]
fn fetch_chapter_content_inner(
    book_url: &str,
    chapter_url: &str,
    source_url: &str,
    chapter_index: i32,
    chapter_title: &str,
    chapter_variable: Option<&str>,
    known_chapter: bool,
    is_volume: bool,
    is_vip: bool,
) -> LegadoResult<String> {
    // 1. 检查 DB 缓存
    // Task #16 P0：按 (book_url, chapter_url) 复合键查找，避免不同书籍共用
    // 相同 chapter_url 时命中他书缓存（正文张冠李戴）。
    let cached = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.get_by_book_and_chapter_url(book_url, chapter_url)
    })?;

    // [B-1] 空正文缓存行按 miss 处理（对齐上游 BookHelp.kt:271「内容为空
    // 直接返回」/ :557-559「空内容不入缓存」）：历史遗留的空行若按命中
    // 返回，该章节将永久空白、永不重抓
    let cached = cached.filter(|c| !c.content.trim().is_empty());

    if let Some(cached_chapter) = cached {
        // [P2-28b] 存量惰性自愈：缓存命中但该章 wordCount 为空（旧版本
        // 写入的缓存，早于回填链引入）时，按缓存正文长度补算回填**一次**
        // （回填成功后 wordCount 非空，后续命中不再写）。失败仅告警，
        // 不影响正文返回（对齐原版 writeText 的 best-effort 语义）
        let wc_missing = with_database(|db| {
            BookChapterRepository::new(db.connection()).word_count_missing(book_url, chapter_url)
        })
        .unwrap_or(false);
        if wc_missing {
            if let Err(e) =
                backfill_chapter_word_count(book_url, chapter_url, &cached_chapter.content)
            {
                log::warn!("章节字数自愈回填失败（已忽略，不影响阅读）: {e}");
            }
        }
        // 缓存存储原始正文，返回前应用净化（避免规则变更后缓存陈旧）
        let processed = apply_content_processing_chapter_with_context(
            book_url,
            &cached_chapter.content,
            &cached_chapter.chapter_title,
            chapter_index,
            Some(chapter_url),
            known_chapter,
        );
        return Ok(processed);
    }

    // 2. 缓存未命中，从网络获取
    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // [T4 | RuleDataInterface] 内容链变量注入：book.variable ⊕ chapter.variable
    //（章节同名键优先，对齐原版 getVariable chapter → book 级联）。合并结果随
    // WebChapter 进入 get_content 的 AnalyzeUrl 变量表与解析上下文种子——
    // 此前内容链仅携带章节变量（R3），token/host 类书级变量在正文链全丢。
    let book_variable: Option<String> = with_database(|db| {
        Ok(BookRepository::new(db.connection())
            .find_by_url(book_url)?
            .and_then(|b| b.variable))
    })?;
    let merged_variable =
        super::web_book::merge_variables_json(book_variable.as_deref(), chapter_variable);

    // P1-1：卷章/VIP 标记随正文链透传（WebChapter 由 DB 章节构造，
    // 不再硬编码 false——卷章豁免空正文检查、音频链跳章均依赖该标记）
    let web_chapter = WebChapter {
        index: chapter_index,
        title: chapter_title.to_string(),
        url: chapter_url.to_string(),
        is_vip,
        is_volume,
        is_pay: false,
        tag: None,
        variable: merged_variable,
        word_count: None,
    };

    let engine = super::web_book::build_engine()?;
    // P1-2：标题规则链随正文抓取返回（标题覆盖值 + 标题内段评图）
    let meta =
        runtime::block_on(async { engine.get_content_with_meta(&source, &web_chapter).await })?;
    let content = meta.content;

    // P1-2：标题覆盖 / 段评图落库（对标 BookContent.kt:180-191 副作用：
    // bookChapter.title = title; bookChapter.imgUrl = group2）。
    // 已知章节才写（未知 URL 落库会污染目录）；写失败仅告警不传播。
    // 授权边界注：本批不新增 legado-db 仓库方法，收敛为单列 UPDATE 于
    // ffi 内部完成（与 up_word_count 同族单列更新语义）。
    let effective_title =
        if known_chapter && (meta.title_override.is_some() || meta.img_url.is_some()) {
            let updated: LegadoResult<usize> = with_database(|db| {
                db.connection()
                .execute(
                    "UPDATE chapters SET title = ?3, imgUrl = ?4 WHERE bookUrl = ?1 AND url = ?2",
                    rusqlite::params![
                        book_url,
                        chapter_url,
                        meta.title_override.as_deref().unwrap_or(chapter_title),
                        meta.img_url,
                    ],
                )
                .map_err(|e| LegadoError::Database(format!("章节标题回写失败: {e}")))
            });
            match updated {
                Ok(_) => meta
                    .title_override
                    .clone()
                    .unwrap_or_else(|| chapter_title.to_string()),
                Err(e) => {
                    log::warn!("章节标题/段评图回写失败（已忽略，不影响阅读）: {e}");
                    chapter_title.to_string()
                }
            }
        } else {
            chapter_title.to_string()
        };

    // 3. 抓取成功后写入 DB 缓存（对齐原版 BookContent.analyzeContent
    //    L207-209 `needSave → BookHelp.saveContent` 的「获取成功即写」时机）。
    //    写失败仅告警不传播——缓存写入失败不得导致阅读获取失败。
    //    P1-2：缓存行携带标题链覆盖后的章节标题（对齐原版 saveContent 保存
    //    bookChapter 覆盖后标题）。
    // [B-12] 未知章节 URL（不在当前目录）不写缓存：上游按目录定位章节，
    // 回退 (0, "") 写出的 index=0 缓存行会污染目录云图标与后续读取
    if known_chapter {
        save_chapter_cache(
            book_url,
            chapter_index,
            &effective_title,
            chapter_url,
            &content,
        );
    }

    // 缓存写入原始正文，返回净化后的正文（透传真实章节标题，使去重复标题生效）
    Ok(apply_content_processing_chapter_with_context(
        book_url,
        &content,
        &effective_title,
        chapter_index,
        Some(chapter_url),
        known_chapter,
    ))
}

/// 字数格式化（对齐原版 `StringUtils.wordCountFormat`：
/// words≤0 → ""；0<words≤10000 → "{words}字"；
/// words>10000 → `DecimalFormat("#.#").format(words * 1.0f / 10000f.toDouble()) + "万字"`）
///
/// 原版 `words * 1.0f` 为 f32 乘法（<2^24 整数精确），`/ 10000f.toDouble()`
/// 为 f64 除法；`DecimalFormat("#.#")` 默认 HALF_EVEN，按 double 的**精确
/// 二进制值**（dyadic rational）舍入——故此处不近似 round，而是取出
/// f64 尾数/指数后做精确的有理数 HALF_EVEN 舍入（`#` 号语义：去尾零，
/// 无小数位时不补 ".0"）。
pub fn word_count_format(words: usize) -> String {
    if words == 0 {
        return String::new();
    }
    if words <= 10000 {
        return format!("{words}字");
    }
    let v = f64::from(words as f32) / 10000.0;
    let bits = v.to_bits();
    let exp_field = ((bits >> 52) & 0x7FF) as i32;
    let mantissa = ((bits & 0x000F_FFFF_FFFF_FFFF) | (1u64 << 52)) as u128;
    // v = mantissa × 2^(exp_field-1075)；求 t = round_HALF_EVEN(v×10)
    //（v×10 的精确值即 mantissa×10 × 2^e，e≥0 为纯移位无舍入）
    let e = exp_field - 1075;
    let n = mantissa * 10;
    let t = if e >= 0 {
        n << e.min(72) as u32 // e>72 对现实字数不可达
    } else {
        let d_exp = (-e) as u32;
        let q = n >> d_exp;
        let r = n & ((1u128 << d_exp) - 1);
        let half = 1u128 << d_exp;
        let twice_r = 2 * r;
        if twice_r > half {
            q + 1
        } else if twice_r < half {
            q
        } else {
            // tie（恰为 .5）→ HALF_EVEN 取偶数侧
            if q.is_multiple_of(2) {
                q
            } else {
                q + 1
            }
        }
    };
    let (int_part, frac_part) = (t / 10, t % 10);
    if frac_part == 0 {
        format!("{int_part}万字")
    } else {
        format!("{int_part}.{frac_part}万字")
    }
}

/// [P2-28b] 正文缓存写入/命中自愈后回填 chapters.wordCount
/// （对齐原版 `BookHelp.writeText` → `BookChapterDao.upWordCount`）
///
/// 注意：原版门控 `AppConfig.tocCountWords` 为 Kotlin 端设置；我方对应开关
/// （`toc_load_word_count`）在 Flutter SharedPreferences，未同步至 Rust，
/// 故 Rust 侧**无条件**回填，显示由目录页「加载字数」开关控制。
///
/// 返回受影响行数（0 = 该章不在目录中，无需回填，非错误）。
fn backfill_chapter_word_count(
    book_url: &str,
    chapter_url: &str,
    content: &str,
) -> LegadoResult<u64> {
    // 原版字数 = Kotlin `String.length`（UTF-16 码元数）
    let word_count = word_count_format(content.encode_utf16().count());
    if word_count.is_empty() {
        return Ok(0);
    }
    with_database(|db| {
        BookChapterRepository::new(db.connection()).up_word_count(
            book_url,
            chapter_url,
            &word_count,
        )
    })
}

/// 阅读获取（非缓存命中）成功后把正文写入 cached_chapters
///
/// 对齐 Android 原版「阅读即缓存」语义：正文成功解析后按
/// (book_url, chapter_url) 复合键立即写入（含 chapter_index 等字段），
/// 目录页云图标据此变为已缓存态。写失败仅告警不传播——原版
/// saveContent 为异步 fire-and-forget，缓存写失败不得使阅读主流程失败。
///
/// [P2-28b] 写入成功后按原版 `writeText` 语义回填 `chapters.wordCount`
/// （best-effort，失败仅告警）。返回缓存写入是否成功。
fn save_chapter_cache(
    book_url: &str,
    chapter_index: i32,
    chapter_title: &str,
    chapter_url: &str,
    content: &str,
) -> bool {
    // [B-1] 空内容不入缓存（对齐上游 BookHelp.kt:557-559）：杜绝空行入库后
    // 被读侧按命中返回、章节永久空白的缺陷链
    if content.trim().is_empty() {
        return false;
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let cached_chapter = CachedChapter {
        id: 0,
        book_url: book_url.to_string(),
        chapter_index,
        chapter_title: chapter_title.to_string(),
        chapter_url: chapter_url.to_string(),
        content: content.to_string(),
        cached_at: now_ms,
        size_bytes: content.len() as i64,
    };
    let result = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.insert(&cached_chapter)?;
        Ok(())
    });
    if let Err(e) = result {
        log::warn!("阅读缓存写入失败（已忽略，不影响阅读）: {e}");
        return false;
    }
    // 回填失败仅告警（对齐原版 writeText：回填属 best-effort，不得影响阅读）
    if let Err(e) = backfill_chapter_word_count(book_url, chapter_url, content) {
        log::warn!("章节字数回填失败（已忽略，不影响阅读）: {e}");
    }
    true
}

/// 一次调用获取章节正文（合并 get_chapter_content + fetch_chapter_content）
///
/// 与 [`get_chapter_content`] 的区别：在线书籍不再返回 JSON 元数据，
/// 而是自动完成网络抓取并直接返回净化后的正文文本。
///
/// 流程：
/// 1. 查询章节信息（DB）
/// 2. 本地书籍 → legado-book 解析 + 净化
/// 3. 在线书籍 → 以 `book.origin` 为书源 URL，内部调用 [`fetch_chapter_content`]
///    （含 DB 缓存检查 → 网络抓取 → 缓存写入 → 净化）
/// 4. 始终返回纯正文字符串，不返回 JSON 元数据
pub fn get_chapter_content_full(book_url: &str, chapter_index: i32) -> LegadoResult<String> {
    // 1. 查询章节信息
    let chapter = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url_and_index(book_url, chapter_index)
    })?
    .ok_or_else(|| LegadoError::Database(format!("章节 {chapter_index} 不存在")))?;

    // 2. 本地书籍：解析文件 + 净化
    if is_local_book(book_url) {
        // [批18c P3-2] 与 `get_chapter_content` 一致：相对可迁移标识
        // （`books/x.txt`）须先还原为当前容器真实路径，否则阅读器主取正文
        // 链路（`getChapterContentFull`）会报「无法打开文件」。
        let real_path = resolve_local_book_path(book_url);
        // [批37b P1-1] 阅读器主取正文链路同样消费 `Book.charset`
        let charset = local_book_charset(book_url)?;
        let content = legado_book::LocalBook::get_chapter_content_with_charset(
            &real_path,
            &chapter_to_local_info(&chapter),
            charset.as_deref(),
        )?;
        return Ok(apply_content_processing_chapter_with_context(
            book_url,
            &content,
            &chapter.title,
            chapter.index,
            Some(&chapter.url),
            true,
        ));
    }

    // 3. 在线书籍：查找书籍获取书源 URL（book.origin）
    let book = with_database(|db| {
        let repo = BookRepository::new(db.connection());
        repo.find_by_url(book_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书籍 {book_url} 不存在")))?;

    if book.origin.is_empty() {
        return Err(LegadoError::Database(format!(
            "书籍 {book_url} 未配置书源（origin 为空）"
        )));
    }
    let source_url = book.origin;

    // 直接调用 inner，复用已持有的章节信息，避免冗余的 get_chapter_index_and_title 查询
    // （章节经 find_by_book_url_and_index 定位，必然已知 → known_chapter=true）
    // P1-1：正文链透传 DB 章节卷章/VIP 标记（卷章豁免空正文检查依赖此值）
    fetch_chapter_content_inner(
        book_url,
        &chapter.url,
        &source_url,
        chapter.index,
        &chapter.title,
        chapter.variable.as_deref(),
        true,
        chapter.is_volume,
        chapter.is_vip,
    )
}

/// 对原始正文应用「替换规则 + 内容净化」，返回净化后的正文（读取时净化）
///
/// 与 Android 原版 ContentProcessor 对等：DB 缓存继续存储原始正文，
/// 在正文返回给上层前应用净化，从而避免「规则变更后缓存陈旧」的问题。
///
/// 处理范围（批7a 起与上游 `ContentProcessor.getContent` 对齐）：
/// - 去除重复标题（正文开头与章节标题相同的文本，受章级开关控制）；
/// - 简繁转换（由持久化 `chineseConverterType` 决定，独立于替换开关）；
/// - 正文重新分段（仅当该书 `readConfig.reSegment=true`）；
/// - 应用启用的替换规则（路径语义 && 书级/全局开关，按 scope 过滤后）。
///
/// 缩进/空行修剪仍不在此处做（`indent_spaces=0`、`trim_empty_lines=false`），
/// 以免改变原始正文排版。
pub fn apply_content_processing(book_url: &str, raw_content: &str, chapter_title: &str) -> String {
    apply_content_processing_inner(
        book_url,
        raw_content,
        chapter_title,
        true,
        None,
        None,
        false,
    )
}

/// [测试/历史入口] 对原始正文应用净化（带章级「删除重复标题」开关，Task #51）
///
/// **生产链路已全部改用 [`apply_content_processing_chapter_with_context`]**：
/// 本入口未持有 chapter_url，`@js:` 的 `chapter.url` 只能按 index 回查，
/// 在 chapter_url 不在目录 / 回退 index=0 的场景可能绑定错章；保留仅为
/// 既有测试与历史调用，生产代码不要新增调用。
pub fn apply_content_processing_chapter(
    book_url: &str,
    raw_content: &str,
    chapter_title: &str,
    chapter_index: i32,
) -> String {
    apply_content_processing_inner(
        book_url,
        raw_content,
        chapter_title,
        true,
        Some(chapter_index),
        None,
        true,
    )
}

/// 对原始正文应用净化（携带调用方已持有的章节 URL 与「是否命中目录」标记）
///
/// [批15 回修 P2-2] `chapter_url` 已知时直接作为 `@js:` 的 `chapter.url`
/// 绑定，不再按 index 回查——`fetch_chapter_content` 对不在目录的
/// chapter_url 会回退 index=0，按 index 回查会把第 0 章的 url/index 绑进
/// 当前章节的 JS。`known_chapter=false` 时 `chapter` 绑定整体留空
/// （空串/0），不给出错误值；`book` 绑定仍使用书籍行。
pub fn apply_content_processing_chapter_with_context(
    book_url: &str,
    raw_content: &str,
    chapter_title: &str,
    chapter_index: i32,
    chapter_url: Option<&str>,
    known_chapter: bool,
) -> String {
    apply_content_processing_inner(
        book_url,
        raw_content,
        chapter_title,
        true,
        Some(chapter_index),
        chapter_url,
        known_chapter,
    )
}

/// 对原始正文应用内容净化但【不应用替换规则】（内容搜索语义）
///
/// 与 Android 书内搜索默认行为对齐：仅做去重复标题等，不应用替换规则，
/// 避免被替换/删除的词搜不到。
///
/// `chapter_index` 由调用方显式传入（Task #55 F8）：Some(idx) 时按章
/// 读取「删除重复标题」开关，None 时用全局默认（去除）。当前生产
/// 内容搜索链路走 [`get_chapter_content_raw`]（内部不经本函数），
/// 本函数仅测试调用，签名变更不影响 frb 公开接口。
pub fn apply_content_processing_raw(
    book_url: &str,
    raw_content: &str,
    chapter_title: &str,
    chapter_index: Option<i32>,
) -> String {
    apply_content_processing_inner(
        book_url,
        raw_content,
        chapter_title,
        false,
        chapter_index,
        None,
        false,
    )
}

/// apply_content_processing 的内部实现：`apply_replace_rules` 表示路径语义
/// （阅读器/导出 = true，内容搜索 raw = false）；
/// `chapter_index` 非 None 时按章读取「删除重复标题」开关（缺省全局默认去除）。
///
/// [批7a] 参数语义变化：`apply_replace_rules` 不再是「无条件应用替换规则」，
/// 而是与书级/全局开关叠加——
/// `replace_rules_enabled = apply_replace_rules && use_replace_rule_for_book(book)`，
/// 对齐 Kotlin `ContentProcessor.getContent`（ContentProcessor.kt:140-142
/// `replaceEnabled = useReplace && book.getUseReplaceRule()`）。
/// 简繁转换与重新分段仍各自独立：
/// - `chinese_convert` 只由路径参数决定（ContentProcessor.kt:182-191，独立于
///   useReplace，禁止与替换开关绑定）；
/// - `re_segment = apply_replace_rules && book.readConfig.reSegment`
///   （ContentProcessor.kt:176-179 `if (reSegment && book.getReSegment())`；
///   搜索 raw 路径保持不重分段）。
fn apply_content_processing_inner(
    book_url: &str,
    raw_content: &str,
    chapter_title: &str,
    apply_replace_rules: bool,
    chapter_index: Option<i32>,
    chapter_url: Option<&str>,
    known_chapter: bool,
) -> String {
    // 1. 一次开库同时取出启用替换规则与书籍行（name/readConfig/bookType 均来自
    //    同一行，避免多次查询落在不同版本上）
    let loaded = with_database(|db| {
        let rule_repo = ReplaceRuleRepository::new(db.connection());
        let rules = rule_repo.get_enabled_rules()?;
        let book_repo = BookRepository::new(db.connection());
        let book = book_repo.find_by_url(book_url)?;
        Ok((rules, book))
    });

    let (rules, book) = match loaded {
        Ok(v) => v,
        // 数据库不可用或查询失败时，退化为不净化（与无规则时行为一致）
        Err(_) => return raw_content.to_string(),
    };
    let book_name = book.as_ref().map(|b| b.name.as_str()).unwrap_or_default();

    // [批7a] 替换规则开关 = 路径语义 && 书级/全局开关（对齐 Kotlin
    // ContentProcessor.kt:140-142；图片类/epub 默认关、显式 readConfig 覆盖优先）
    let replace_rules_enabled = apply_replace_rules && use_replace_rule_for_book(book.as_ref());

    // 繁简转换仅作用于阅读器/导出正文路径（apply_replace_rules=true）；
    // 内容搜索 raw 路径保持原文，避免搜不到被转换的词
    // （对齐 Kotlin BookHelp.getContent 的 replaceEnabled=false 路径）。
    // 注意：此处只看路径参数，不看 useReplaceRule（上游 ContentProcessor.kt:182-191
    // 的 chineseConvert 独立于替换开关）。
    let chinese_convert = if apply_replace_rules {
        current_chinese_convert_direction()
    } else {
        None
    };

    // [批7a] 正文重新分段：阅读/导出路径且该书 readConfig.reSegment=true 才启用
    // （对齐 ContentProcessor.kt:176-179）；搜索 raw 路径保持原文排版。
    let re_segment = apply_replace_rules
        && book
            .as_ref()
            .and_then(|b| b.read_config.as_ref())
            .map(|config| config.re_segment)
            .unwrap_or(false);

    // 章级「删除重复标题」开关（Task #51）：无章节上下文时维持全局默认 true；
    // 带 chapter_index 的路径（阅读器/导出，以及 apply_content_processing_raw
    // 显式传入时）均尊重章级 opt-out，对齐原版 removeSameTitleCache
    // 不受 useReplace 影响的行为
    let remove_duplicate_title = chapter_index
        .map(|idx| is_same_title_removed(book_url, idx))
        .unwrap_or(true);

    // [批15] `@js:` 替换规则的生产执行上下文：仅在确有需要执行的正则
    // `@js:` 规则时才构建（非 quickjs 构建直接返回空上下文，不查库）
    let js_bindings = build_replace_js_bindings(
        book_url,
        book.as_ref(),
        chapter_title,
        chapter_index,
        chapter_url,
        known_chapter,
        replace_rules_enabled,
        &rules,
    );

    process_content_with_rules_inner_ctx(
        raw_content,
        chapter_title,
        &rules,
        book_name,
        replace_rules_enabled,
        re_segment,
        chinese_convert,
        remove_duplicate_title,
        js_bindings,
    )
}

/// 净化核心逻辑（应用替换规则）：保留 4 参签名供既有测试调用
///
/// 默认语义：应用替换规则（`replace_rules_enabled=true`）、关闭重新分段
/// （`re_segment=false`），与批7a 前的输出行为一致。
#[cfg(test)]
fn process_content_with_rules(
    raw_content: &str,
    chapter_title: &str,
    rules: &[ReplaceRule],
    book_name: &str,
) -> String {
    process_content_with_rules_inner(
        raw_content,
        chapter_title,
        rules,
        book_name,
        true,
        false,
        None,
        true,
    )
}

/// 净化核心逻辑（纯函数，便于单元测试）：
/// - `replace_rules_enabled` 控制是否应用替换规则（路径语义 && 书级/全局开关）
/// - `re_segment` 控制是否重新分段（阅读/导出路径 && 书级 reSegment）
/// - `chinese_convert` 控制简繁转换方向（None / "t2s" / "s2t"，由调用方从持久化配置读取）
/// - `remove_duplicate_title` 控制是否去除重复标题（章级开关由调用方预先读取）
// 参数集对应上游 ContentProcessor.getContent 的四个独立开关（useReplace /
// reSegment / chineseConvert / removeSameTitle），拆结构体会增加所有测试调用点
// 噪声，暂不拆（与仓库既有 allow 处理一致）。
#[cfg(test)]
#[allow(clippy::too_many_arguments)]
fn process_content_with_rules_inner(
    raw_content: &str,
    chapter_title: &str,
    rules: &[ReplaceRule],
    book_name: &str,
    replace_rules_enabled: bool,
    re_segment: bool,
    chinese_convert: Option<String>,
    remove_duplicate_title: bool,
) -> String {
    // 无章节/书籍上下文的入口（既有测试/内容搜索）：`@js:` 绑定为空上下文，
    // 但执行器仍注入——修复「预览能跑、生产跳过」
    process_content_with_rules_inner_ctx(
        raw_content,
        chapter_title,
        rules,
        book_name,
        replace_rules_enabled,
        re_segment,
        chinese_convert,
        remove_duplicate_title,
        ReplaceJsBindings::empty(),
    )
}

/// 净化核心逻辑（带 `@js:` 章节/书籍绑定上下文）
///
/// 与 `process_content_with_rules_inner` 相同，额外接收正文净化生产路径
/// 已解析的 `chapter`/`book` 绑定（预览与源导入不传章节/书籍上下文）。
#[allow(clippy::too_many_arguments)]
fn process_content_with_rules_inner_ctx(
    raw_content: &str,
    chapter_title: &str,
    rules: &[ReplaceRule],
    book_name: &str,
    replace_rules_enabled: bool,
    re_segment: bool,
    chinese_convert: Option<String>,
    remove_duplicate_title: bool,
    js_bindings: ReplaceJsBindings,
) -> String {
    // 2. 按 scope 过滤（与 Android 语义一致，并修复空 book_name 守卫与精确匹配）：
    //    - None → 全局生效
    //    - Some(scope)：scope 为空或 "global" → 全局；
    //      否则仅当 book_name 非空，且 scope 按 [,;，；] 拆分后存在 trim()==book_name 的精确项才生效。
    let entries: Vec<ReplaceRuleEntry> = rules
        .iter()
        .filter(|rule| match &rule.scope {
            None => true,
            Some(scope) => {
                if scope.is_empty() || scope == "global" {
                    true
                } else if book_name.is_empty() {
                    // book_name 为空时，带具体 scope 的规则不生效（避免 contains("") 恒真）
                    false
                } else {
                    scope
                        .split([',', ';', '，', '；'])
                        .any(|item| item.trim() == book_name)
                }
            }
        })
        .map(ReplaceRuleEntry::from_replace_rule)
        .collect();

    // 3. 构造处理器：启用「去重复标题 + 替换规则 + 简繁转换」，与 Android 净化行为对等
    //    replace_rules_enabled 已由调用方叠加路径语义与书级/全局开关（批7a）；
    //    re_segment 由阅读/导出路径与该书 readConfig.reSegment 共同决定；
    //    chinese_convert 来自持久化配置 chineseConverterType（0/1/2 → None/t2s/s2t）；
    //    remove_duplicate_title 来自章级开关（Task #51，全局默认 true）
    let config = ProcessorConfig {
        remove_duplicate_title,
        re_segment,
        chinese_convert,
        apply_replace_rules: replace_rules_enabled,
        indent_spaces: 0,
        trim_empty_lines: false,
    };
    // [批15] 仅在确有可执行的 `@js:` 正文规则时注入执行器：
    // 非 quickjs 构建下执行器 eval 返回 Err，管线按既有口径保留原文（不 panic）
    let js_executor: Option<std::sync::Arc<dyn ReplaceJsExecutor>> =
        if config.apply_replace_rules && entries.iter().any(entry_needs_js_execution) {
            Some(std::sync::Arc::new(ReplaceRuleJsExecutor::new(js_bindings)))
        } else {
            None
        };
    let processor = ContentProcessor::new(config);
    processor.process_with_js(raw_content, chapter_title, &entries, js_executor)
}

/// 判断替换规则字段是否需要在正文管线执行 `@js:`
///
/// 与 `content_processor::apply_single_rule` 的执行条件严格一致：仅启用的
/// **正则**规则、`scopeContent` 生效、pattern 非空、且替换内容以 `@js:` 开头
/// （非正则规则走字面量替换，`@js:` 原样插入，对齐参考版 `String.replace` 语义）。
/// 正文规则过滤与 `@js:` 绑定构建共用本判定，避免两处条件漂移。
fn rule_needs_js_execution(
    is_enabled: bool,
    is_regex: bool,
    scope_content: bool,
    pattern: &str,
    replacement: &str,
) -> bool {
    is_enabled
        && is_regex
        && scope_content
        && !pattern.is_empty()
        && replacement.starts_with("@js:")
}

/// 判断替换规则条目是否需要执行 `@js:`（见 [`rule_needs_js_execution`]）
fn entry_needs_js_execution(rule: &ReplaceRuleEntry) -> bool {
    rule_needs_js_execution(
        rule.is_enabled,
        rule.is_regex,
        rule.scope_content,
        &rule.pattern,
        &rule.replacement,
    )
}

/// 构建正文净化 `@js:` 的章节/书籍绑定（生产路径）
///
/// 对齐参考版 `RegexExtensions.kt:32-57`：
/// - 章节：优先使用调用方已持有的 `chapter_url`；未持有且 `known_chapter`
///   为真时按 `(book_url, index)` 回查，章节行缺失则空串；
/// - `known_chapter=false`（chapter_url 不在当前目录、index 是回退值 0）时
///   章节绑定整体留空（空串/0），**不把第 0 章的 url/index 绑进当前章节**；
/// - 书籍：`name`/`author` 取书籍行，`bookUrl` 回退书籍主键（书籍行缺失时
///   仍给出 `bookUrl`，对应参考版 `book ?: chapter.bookUrl` 的兜底语义）；
/// - 无需要执行的 `@js:` 规则时返回空上下文，避免额外的章节回查与引擎创建；
/// - 非 quickjs 构建直接返回空上下文，不产生章节回查 DB 查询。
#[allow(clippy::too_many_arguments)] // 章节/书籍上下文 + 规则开关，均为调用方已有值
fn build_replace_js_bindings(
    book_url: &str,
    book: Option<&Book>,
    chapter_title: &str,
    chapter_index: Option<i32>,
    chapter_url_hint: Option<&str>,
    known_chapter: bool,
    replace_rules_enabled: bool,
    rules: &[ReplaceRule],
) -> ReplaceJsBindings {
    // P3-7：非 quickjs 构建不执行 @js:，无需查章节 URL
    if !cfg!(feature = "quickjs") || !replace_rules_enabled {
        return ReplaceJsBindings::empty();
    }
    let needs_js = rules.iter().any(|rule| {
        rule_needs_js_execution(
            rule.is_enabled,
            rule.is_regex,
            rule.scope_content,
            &rule.pattern,
            &rule.replacement,
        )
    });
    if !needs_js {
        return ReplaceJsBindings::empty();
    }

    let resolved_book_url = book
        .map(|b| b.book_url.as_str())
        .filter(|url| !url.is_empty())
        .unwrap_or(book_url);
    let chapter_binding = if known_chapter {
        let chapter_url = match chapter_url_hint {
            // 优先使用调用方已持有的章节 URL（避免 index 回退导致错章）
            Some(url) => url.to_string(),
            None => chapter_index
                .and_then(|index| {
                    with_database(|db| {
                        BookChapterRepository::new(db.connection())
                            .find_by_book_url_and_index(book_url, index)
                    })
                    .ok()
                    .flatten()
                })
                .map(|chapter| chapter.url)
                .unwrap_or_default(),
        };
        ReplaceJsChapter {
            title: chapter_title.to_string(),
            index: chapter_index.unwrap_or(0),
            url: chapter_url,
            book_url: resolved_book_url.to_string(),
        }
    } else {
        // 章节不在目录：留空，不给出错误值
        ReplaceJsChapter::default()
    };

    ReplaceJsBindings::new(
        chapter_binding,
        ReplaceJsBook {
            name: book.map(|b| b.name.clone()).unwrap_or_default(),
            author: book.map(|b| b.author.clone()).unwrap_or_default(),
            book_url: resolved_book_url.to_string(),
        },
    )
}

/// 根据 chapter_url 查找章节序号、标题与变量（找不到时返回 (0, 空标题, None, false)）
///
/// 第 4 项 `known`（[B-12]）：该 URL 是否命中当前目录。未知 URL 回退
/// (0, "", None) 仅用于读取/展示，调用方不得据此写入 index=0 的缓存行。
fn get_chapter_index_title_variable(
    book_url: &str,
    chapter_url: &str,
) -> LegadoResult<(i32, String, Option<String>, bool, bool, bool)> {
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;
    Ok(match chapters.iter().find(|ch| ch.url == chapter_url) {
        Some(ch) => (
            ch.index,
            ch.title.clone(),
            ch.variable.clone(),
            true,
            // P1-1：卷章/VIP 标记随正文链透传（卷章豁免空正文检查 + 音频跳章）
            ch.is_volume,
            ch.is_vip,
        ),
        None => (0, String::new(), None, false, false, false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::ContentRule;
    use legado_core::models::BookSource;

    /// 初始化测试数据库并持锁（返回串行锁守卫，测试必须绑定到变量）
    fn setup_db_and_source(source_url: &str) -> std::sync::MutexGuard<'static, ()> {
        let db_guard = crate::db_state::ensure_test_db();
        insert_test_source(source_url);
        db_guard
    }

    /// 插入测试书源
    fn insert_test_source(source_url: &str) {
        with_database(|db| {
            let repo = BookSourceRepository::new(db.connection());
            let source = BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "测试书源".to_string(),
                search_url: Some(format!("{source_url}/search?q={{key}}")),
                rule_content: Some(ContentRule {
                    content: Some("css(.content).html".to_string()),
                    ..ContentRule::default()
                }),
                ..BookSource::default()
            };
            repo.insert(&source)?;
            Ok(())
        })
        .unwrap();
    }

    // ─── [cbz 批 B | 2026-10-03] 本地漫画白名单与懒解析链路 ────────────────

    /// c) `is_local_book` 白名单含 `.cbz`；`.zip` 仍为 false（压缩容器回归）
    #[test]
    fn is_local_book_includes_cbz_excludes_zip() {
        // cbz（大小写不敏感）
        assert!(is_local_book("/books/本地漫画.cbz"));
        assert!(is_local_book("/books/COMIC.CBZ"));
        // .zip 保持压缩容器语义：不在本地书白名单（回归）
        assert!(!is_local_book("/books/archive.zip"));
        assert!(!is_local_book("/books/ARCHIVE.ZIP"));
        // 既有白名单回归
        assert!(is_local_book("/books/a.epub"));
        assert!(is_local_book("/books/a.txt"));
        assert!(is_local_book("/books/a.text"));
        assert!(is_local_book("/books/a.mobi"));
        assert!(is_local_book("/books/a.azw"));
        assert!(is_local_book("/books/a.azw3"));
        assert!(is_local_book("/books/a.pdf"));
        assert!(!is_local_book("/books/a.umd"));
        assert!(!is_local_book("/books/a.epub.bak"));
    }

    /// `.cbz` 加入白名单后端到端：懒解析目录（1 章、url 置空）→ 正文为
    /// `cbz://` 条目行（批 A `CbzFile` 接线回归；cbz_api 单测另验字节读取）
    #[test]
    fn cbz_local_book_lazy_toc_and_content_end_to_end() {
        use std::io::Write as _;
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("legado_cbz_e2e_{}_{}", std::process::id(), n));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let cbz_path = dir.join("本地 漫画.cbz");
        {
            let file = std::fs::File::create(&cbz_path).unwrap();
            let mut writer = zip::ZipWriter::new(file);
            let options = zip::write::SimpleFileOptions::default();
            for (name, data) in [
                ("02.jpg", b"page-two".as_slice()),
                ("01 封面.jpg", b"page-one".as_slice()),
                ("readme.txt", b"ignored".as_slice()),
            ] {
                writer.start_file(name, options).unwrap();
                writer.write_all(data).unwrap();
            }
            writer.finish().unwrap();
        }
        let book_url = cbz_path.to_string_lossy().into_owned();

        let _db_guard = crate::db_state::ensure_test_db();
        // books 行（书架入口语义；懒加载分支会同步 B-13b 派生字段）
        let book_json = serde_json::json!({
            "bookUrl": book_url,
            "name": "本地 漫画",
            "origin": "loc_book"
        })
        .to_string();
        crate::api::bookshelf::add_book(&book_json).expect("本地漫画入库");

        // 懒解析：整包 1 章、章节 url 置空、标题 = 文件名去扩展名
        let chapters = get_chapters(&book_url).expect("cbz 章节懒解析");
        assert_eq!(chapters.total, 1, "CBZ 整包应固定 1 章");
        assert_eq!(chapters.chapters[0].url, "", "CBZ 章节 url 应置空");
        assert_eq!(chapters.chapters[0].title, "本地 漫画");

        // 正文：自然排序的 cbz:// 行列表（仅图片条目）
        let content = get_chapter_content(&book_url, 0).expect("cbz 正文");
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines.len(), 2, "content={content}");
        assert_eq!(lines[0], "cbz://01 封面.jpg");
        assert_eq!(lines[1], "cbz://02.jpg");
        assert!(!content.contains("readme.txt"));

        // 收尾清理：章节行 + 书行 + 文件
        with_database(|db| {
            BookChapterRepository::new(db.connection()).delete_by_book_url(&book_url)?;
            BookRepository::new(db.connection()).delete_by_url(&book_url)?;
            Ok(())
        })
        .unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ─── [iOS 视角F C1] 本地书「相对可迁移标识」读写回环 ─────────────────────

    /// [iOS 视角F C1] 相对标识回环：写入以「当前容器 Documents 基目录」解析。
    ///
    /// 构造临时基目录 `base`（模拟 Documents），其下 `books/sample.txt` 为本地书；
    /// 通过 `record_db_path(base/legado.db)` 让 resolver 以 `base` 为基。导入时传入
    /// 相对标识 `books/sample.txt`，断言 `book_url` 原样存标识（非绝对路径），且
    /// `get_chapters`/`get_chapter_content` 能经 resolver 还原真实路径读到内容。
    /// 收尾删除该书与章节行，避免污染共享内存库（不削弱既有测试）。
    #[test]
    fn local_book_relative_identifier_roundtrip() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let base =
            std::env::temp_dir().join(format!("legado_c1_base_{}_{}", std::process::id(), n));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        let file = books.join("sample.txt");
        std::fs::write(&file, "第一章\n正文一\n\n第二章\n正文二\n").unwrap();

        let _db_guard = crate::db_state::ensure_test_db();
        // resolver 以 DB 路径的父目录为 Documents 基：记录 base/legado.db
        crate::db_state::record_db_path(base.join("legado.db").to_str().unwrap());

        // 写侧：导入存「相对可迁移标识」，而非绝对路径
        let res = crate::api::book_import::import_local_book("books/sample.txt").unwrap();
        assert!(res.success, "导入失败: {:?}", res.error);
        let url = res.book.as_ref().unwrap().book_url.clone();
        assert_eq!(url, "books/sample.txt", "book_url 应存相对可迁移标识");

        // 读侧：章节列表 + 正文均经 resolver 还原真实路径
        let chapters = get_chapters("books/sample.txt").unwrap();
        assert!(chapters.total >= 1, "相对标识应能解析出章节");
        let content = get_chapter_content("books/sample.txt", 0).unwrap();
        assert!(!content.trim().is_empty(), "应能读到正文");
        // [批18c P3-2] 阅读器主取正文链路（get_chapter_content_full）同样
        // 必须经 resolver 还原相对标识，否则设备上打开相对路径书报
        // 「无法打开文件: No such file or directory」。
        let full = get_chapter_content_full("books/sample.txt", 0)
            .expect("get_chapter_content_full 应能解析相对标识");
        assert!(!full.trim().is_empty(), "全文链路应能读到正文");

        // 收尾清理：删除该书的章节行与书行，恢复共享内存库状态
        with_database(|db| {
            BookChapterRepository::new(db.connection()).delete_by_book_url("books/sample.txt")?;
            BookRepository::new(db.connection()).delete_by_url("books/sample.txt")?;
            Ok(())
        })
        .unwrap();
        let _ = std::fs::remove_dir_all(&base);
    }

    // ─── [批37b P1-1] 设置编码端到端（charset 消费 + 目录重解析） ───────────

    /// 红→绿：GBK 正文 + 前 4KB 纯 ASCII（自动检测误判 UTF-8）
    /// → 未设置编码时正文乱码、目录退化为单章；
    /// → `book_set_charset(GBK)` 后目录按新编码重解析、正文正确解码。
    ///
    /// 同时验证单列写：设置编码不走 `update_book` 整书回写，
    /// `readConfig` 未建模键与阅读进度保持原值。
    #[test]
    fn local_txt_charset_setting_rebuilds_toc_and_decodes_content() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let base =
            std::env::temp_dir().join(format!("legado_charset_base_{}_{}", std::process::id(), n));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        let file = books.join("gbk.txt");
        // 前 4096 字节 ASCII（末位换行）→ detect_encoding 命中 UTF-8；
        // 其后为 GBK 正文
        let mut bytes = vec![b'A'; 4095];
        bytes.push(b'\n');
        let (gbk_body, _, _) =
            encoding_rs::GBK.encode("第一章 起始\n这是正文内容。\n\n第二章 继续\n更多正文内容。\n");
        bytes.extend_from_slice(&gbk_body);
        std::fs::write(&file, &bytes).unwrap();

        let _db_guard = crate::db_state::ensure_test_db();
        let previous_db_path = crate::db_state::current_db_path();
        crate::db_state::record_db_path(base.join("legado.db").to_str().unwrap());

        let res = crate::api::book_import::import_local_book("books/gbk.txt").unwrap();
        assert!(res.success, "导入失败: {:?}", res.error);
        let book_url = res.book.as_ref().unwrap().book_url.clone();
        assert_eq!(book_url, "books/gbk.txt");

        // 红：未设置编码时按 UTF-8 解码 → 标题乱码 → 内置规则零命中 →
        // [批1b-3] 按默认 3000 字符档位长度分章（4230 字节 ≈ 4149 字符
        // > 3000 → 切 2 章；内容仍为乱码，仅长度分章语义生效）
        let auto = get_chapters(&book_url).unwrap();
        assert_eq!(
            auto.total, 2,
            "乱码长文应按默认档位长度分章: {:?}",
            auto.chapters
        );
        assert_eq!(auto.chapters[0].title, "第1章(1)");

        // 造未建模 readConfig 键 + 进度，验证单列写不回退
        with_database(|db| {
            db.connection()
                .execute(
                    "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                    rusqlite::params![
                        r#"{"reverseToc":false,"useGlobalAudioSkip":true,"tocExpanded":{"0":true}}"#,
                        book_url
                    ],
                )
                .map_err(|e| LegadoError::Database(format!("写原始 readConfig 失败: {e}")))?;
            BookRepository::new(db.connection()).update_progress(
                &book_url,
                1,
                42,
                Some("旧章"),
                1_700_000_000_000,
            )?;
            Ok(())
        })
        .unwrap();

        // 绿：设置 GBK（单列写 + 清本地 TXT 目录）
        let updated = crate::api::bookshelf::set_book_charset(&book_url, "GBK").unwrap();
        assert_eq!(updated.charset.as_deref(), Some("GBK"));
        assert_eq!(updated.total_chapter_num, 0, "旧目录应失效");

        // 目录按 GBK 重解析
        let chapters = get_chapters(&book_url).unwrap();
        assert_eq!(
            chapters.total, 2,
            "GBK 目录应识别两章: {:?}",
            chapters.chapters
        );
        assert_eq!(chapters.chapters[0].title, "第一章 起始");
        assert_eq!(chapters.chapters[1].title, "第二章 继续");

        // 正文按 GBK 解码（阅读器主链路）
        let content = get_chapter_content_full(&book_url, 1).unwrap();
        assert!(
            content.contains("更多正文内容"),
            "GBK 正文应正确解码: {content}"
        );
        // 旧读取入口（get_chapter_content）同口径
        let content_legacy = get_chapter_content(&book_url, 0).unwrap();
        assert!(
            content_legacy.contains("这是正文内容"),
            "get_chapter_content 也应消费 charset: {content_legacy}"
        );

        // 单列写断言：未建模 readConfig 键 + 进度保持
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(&book_url)?
                .expect("书籍记录应存在");
            assert_eq!(saved.charset.as_deref(), Some("GBK"));
            assert_eq!(saved.dur_chapter_index, 1, "进度不得被编码写回退");
            assert_eq!(saved.dur_chapter_pos, 42, "进度不得被编码写回退");
            let raw: Option<String> = db
                .connection()
                .query_row(
                    "SELECT readConfig FROM books WHERE bookUrl = ?1",
                    rusqlite::params![book_url],
                    |row| row.get(0),
                )
                .map_err(|e| LegadoError::Database(format!("查询 readConfig 失败: {e}")))?;
            let cfg: serde_json::Value =
                serde_json::from_str(&raw.unwrap_or_else(|| "{}".into())).unwrap();
            assert_eq!(cfg["useGlobalAudioSkip"], serde_json::json!(true));
            assert_eq!(cfg["tocExpanded"], serde_json::json!({"0": true}));
            Ok(())
        })
        .unwrap();

        // 不支持的编码：fail-closed（UI 不得假成功）
        let err = crate::api::bookshelf::set_book_charset(&book_url, "no-such-charset")
            .expect_err("不支持的编码必须报错");
        assert!(err.to_string().contains("不支持的编码"), "{err}");

        // 收尾：事务内清章节 + 书行，恢复 DB 路径
        with_database(|db| {
            let tx = db
                .connection()
                .unchecked_transaction()
                .map_err(|e| LegadoError::Database(format!("开启清理事务失败: {e}")))?;
            BookChapterRepository::new(db.connection()).delete_by_book_url(&book_url)?;
            BookRepository::new(db.connection()).delete_by_url(&book_url)?;
            tx.commit()
                .map_err(|e| LegadoError::Database(format!("提交清理事务失败: {e}")))?;
            Ok(())
        })
        .unwrap();
        match previous_db_path {
            Some(path) => crate::db_state::record_db_path(&path),
            None => crate::db_state::record_db_path(""),
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    // ─── [批43] TXT 目录规则作用于当前书 ─────────────────────────────────────

    /// 端到端：显式规则写 `books.tocUrl` → 清章节 → 下次 `get_chapters`
    /// 按新规则重解析；规则未命中回退默认；清空恢复默认；单列写保留其它列。
    #[test]
    fn local_txt_toc_rule_applies_falls_back_and_clears() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        static CTR: AtomicUsize = AtomicUsize::new(0);
        let n = CTR.fetch_add(1, Ordering::SeqCst);
        let base =
            std::env::temp_dir().join(format!("legado_toc_rule_{}_{}", std::process::id(), n));
        let books = base.join("books");
        std::fs::create_dir_all(&books).unwrap();
        let file = books.join("rules.txt");
        // 内置默认规则只认识「第五章 默认」；两组自定义标记各自成章
        std::fs::write(
            &file,
            "\n【第一篇】 开端\n甲。\n【第二篇】 继续\n乙。\n\
             @@第三篇@@\n丙。\n@@第四篇@@\n丁。\n第五章 默认\n戊。\n",
        )
        .unwrap();

        let _db_guard = crate::db_state::ensure_test_db();
        let previous_db_path = crate::db_state::current_db_path();
        crate::db_state::record_db_path(base.join("legado.db").to_str().unwrap());

        let res = crate::api::book_import::import_local_book("books/rules.txt").unwrap();
        assert!(res.success, "导入失败: {:?}", res.error);
        let book_url = res.book.as_ref().unwrap().book_url.clone();
        assert_eq!(book_url, "books/rules.txt");

        // 红：默认规则只识别「第五章 默认」
        let auto = get_chapters(&book_url).unwrap();
        assert_eq!(auto.total, 1, "{:?}", auto.chapters);
        assert_eq!(auto.chapters[0].title, "第五章 默认");
        assert!(
            !auto.used_custom_rule,
            "未配置规则时不得标记使用了自定义规则"
        );

        // 造未建模 readConfig 键 + 进度，验证单列写不回退
        with_database(|db| {
            db.connection()
                .execute(
                    "UPDATE books SET readConfig = ?1 WHERE bookUrl = ?2",
                    rusqlite::params![r#"{"useGlobalAudioSkip":true}"#, book_url],
                )
                .map_err(|e| LegadoError::Database(format!("写原始 readConfig 失败: {e}")))?;
            BookRepository::new(db.connection()).update_progress(
                &book_url,
                0,
                7,
                Some("第五章 默认"),
                1_700_000_000_000,
            )?;
            Ok(())
        })
        .unwrap();

        // 绿 1：显式规则 A
        let rule_a = r#"{"name":"方括号篇","rule":"^【第.+篇】.*$","replacement":""}"#;
        let updated = crate::api::bookshelf::set_book_toc_rule(&book_url, Some(rule_a)).unwrap();
        assert_eq!(
            updated.toc_url,
            format!("^【第.+篇】.*${}", legado_book::txt::TOC_RULE_SEPARATOR)
        );
        assert_eq!(updated.total_chapter_num, 0, "旧目录应失效");
        let chapters = get_chapters(&book_url).unwrap();
        assert_eq!(chapters.total, 2, "{:?}", chapters.chapters);
        assert_eq!(chapters.chapters[0].title, "【第一篇】 开端");
        assert!(
            chapters.used_custom_rule,
            "规则命中应透出 used_custom_rule=true"
        );
        let content = get_chapter_content_full(&book_url, 1).unwrap();
        assert!(content.contains("乙"), "换规则后正文切片应正确: {content}");

        // 单列写：未建模 readConfig 键 + 进度保持
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(&book_url)?
                .expect("书籍记录应存在");
            assert_eq!(saved.dur_chapter_index, 0, "进度不得被规则写回退");
            assert_eq!(saved.dur_chapter_pos, 7, "进度不得被规则写回退");
            let raw: Option<String> = db
                .connection()
                .query_row(
                    "SELECT readConfig FROM books WHERE bookUrl = ?1",
                    rusqlite::params![book_url],
                    |row| row.get(0),
                )
                .map_err(|e| LegadoError::Database(format!("查询 readConfig 失败: {e}")))?;
            let cfg: serde_json::Value =
                serde_json::from_str(&raw.unwrap_or_else(|| "{}".into())).unwrap();
            assert_eq!(cfg["useGlobalAudioSkip"], serde_json::json!(true));
            Ok(())
        })
        .unwrap();

        // 绿 2：换规则 B → 目录重载为新标题
        let rule_b = r#"{"rule":"^@@.+@@$"}"#;
        crate::api::bookshelf::set_book_toc_rule(&book_url, Some(rule_b)).unwrap();
        let chapters = get_chapters(&book_url).unwrap();
        assert_eq!(chapters.total, 2, "{:?}", chapters.chapters);
        assert_eq!(chapters.chapters[0].title, "@@第三篇@@");

        // 规则未命中 → 回退内置默认规则
        crate::api::bookshelf::set_book_toc_rule(&book_url, Some(r#"{"rule":"^不存在的标题$"}"#))
            .unwrap();
        let fallback = get_chapters(&book_url).unwrap();
        assert_eq!(
            fallback.total, 1,
            "未命中应回退默认: {:?}",
            fallback.chapters
        );
        assert_eq!(fallback.chapters[0].title, "第五章 默认");
        assert!(
            !fallback.used_custom_rule,
            "规则未命中回退默认时必须透出 used_custom_rule=false（UI 据此提示）"
        );

        // 清空（null）→ 恢复默认规则
        crate::api::bookshelf::set_book_toc_rule(&book_url, None).unwrap();
        let cleared = get_chapters(&book_url).unwrap();
        assert_eq!(cleared.total, 1, "{:?}", cleared.chapters);
        assert_eq!(cleared.chapters[0].title, "第五章 默认");

        // 非法规则 fail-closed：不落库、**不清理旧目录**（现有目录继续可用）
        let rule_c = r#"{"rule":"^@@.+@@$"}"#;
        crate::api::bookshelf::set_book_toc_rule(&book_url, Some(rule_c)).unwrap();
        let before_invalid = get_chapters(&book_url).unwrap();
        assert_eq!(before_invalid.total, 2);
        assert!(before_invalid.used_custom_rule);
        let toc_before_invalid = with_database(|db| {
            Ok(BookRepository::new(db.connection())
                .find_by_url(&book_url)?
                .map(|b| b.toc_url))
        })
        .unwrap();
        let err =
            crate::api::bookshelf::set_book_toc_rule(&book_url, Some(r#"{"rule":"([unclosed"}"#))
                .expect_err("非法正则应报错");
        assert!(err.to_string().contains("目录规则正则无效"), "{err}");
        let toc_after_invalid = with_database(|db| {
            Ok(BookRepository::new(db.connection())
                .find_by_url(&book_url)?
                .map(|b| b.toc_url))
        })
        .unwrap();
        assert_eq!(
            toc_after_invalid, toc_before_invalid,
            "非法规则不得落库，也不得改写已有 tocUrl"
        );
        let after_invalid = get_chapters(&book_url).unwrap();
        assert_eq!(
            after_invalid.total, 2,
            "非法规则失败后旧目录必须原样保留: {:?}",
            after_invalid.chapters
        );
        assert_eq!(after_invalid.chapters[0].title, "@@第三篇@@");

        // 超长 / 深嵌套规则：fail-closed（同样不改旧目录）
        let overlong = "a".repeat(legado_core::regex_safe::MAX_REGEX_PATTERN_LEN + 8);
        let deep_nested = format!("{}chapter{}", "(".repeat(40), ")".repeat(40));
        for bad in [overlong.as_str(), deep_nested.as_str()] {
            let err = crate::api::bookshelf::set_book_toc_rule(&book_url, Some(bad))
                .expect_err("病态规则必须报错");
            assert!(
                err.to_string().contains("目录规则正则无效"),
                "超长/深嵌套规则应 fail-closed: {err}"
            );
        }
        let after_bad_rules = get_chapters(&book_url).unwrap();
        assert_eq!(after_bad_rules.total, 2, "病态规则不得清空旧目录");

        // `.text` 扩展名同样属于本地 TXT：规则成功生效
        let text_file = books.join("rules.text");
        std::fs::write(&text_file, "【第一篇】 开始\n甲。\n【第二篇】 结束\n乙。\n").unwrap();
        let text_import = crate::api::book_import::import_local_book("books/rules.text").unwrap();
        assert!(text_import.success, "导入失败: {:?}", text_import.error);
        let text_url = text_import.book.unwrap().book_url;
        assert_eq!(text_url, "books/rules.text");
        crate::api::bookshelf::set_book_toc_rule(&text_url, Some(rule_a))
            .expect(".text 应允许设置目录规则");
        let text_chapters = get_chapters(&text_url).unwrap();
        assert_eq!(text_chapters.total, 2, "{:?}", text_chapters.chapters);
        assert!(text_chapters.used_custom_rule);

        // 非 TXT 的本地书：fail-closed（显式 loc_book + local 位 + 非 txt 文件）
        let epub_url = "books/not-txt.epub";
        with_database(|db| {
            let book = legado_core::models::Book {
                book_url: epub_url.to_string(),
                origin: legado_core::models::book_type::LOCAL_TAG.to_string(),
                origin_name: "not-txt.epub".to_string(),
                book_type: legado_core::models::book_type::LOCAL,
                ..Default::default()
            };
            BookRepository::new(db.connection()).insert(&book)
        })
        .unwrap();
        let err = crate::api::bookshelf::set_book_toc_rule(epub_url, Some("^第.+章$"))
            .expect_err("本地非 TXT 应报错");
        assert!(err.to_string().contains("仅适用于本地 TXT"), "{err}");

        // 收尾：事务内清章节 + 书行，恢复 DB 路径
        with_database(|db| {
            let tx = db
                .connection()
                .unchecked_transaction()
                .map_err(|e| LegadoError::Database(format!("开启清理事务失败: {e}")))?;
            let chapter_repo = BookChapterRepository::new(db.connection());
            chapter_repo.delete_by_book_url(&book_url)?;
            chapter_repo.delete_by_book_url(&text_url)?;
            let book_repo = BookRepository::new(db.connection());
            book_repo.delete_by_url(&book_url)?;
            book_repo.delete_by_url(&text_url)?;
            book_repo.delete_by_url(epub_url)?;
            tx.commit()
                .map_err(|e| LegadoError::Database(format!("提交清理事务失败: {e}")))?;
            Ok(())
        })
        .unwrap();
        match previous_db_path {
            Some(path) => crate::db_state::record_db_path(&path),
            None => crate::db_state::record_db_path(""),
        }
        let _ = std::fs::remove_dir_all(&base);
    }

    // ─── [批43b] 陈旧整书快照 / 并发解析窗口回归 ─────────────────────────────

    /// 本地 TXT 测试夹具：临时目录 + 文件 + 独立 DB 路径
    struct LocalTxtFixture {
        base: std::path::PathBuf,
        book_url: String,
        previous_db_path: Option<String>,
    }

    impl LocalTxtFixture {
        /// `content` 写入 `<base>/books/<name>`，并导入为本地书
        fn new(tag: &str, name: &str, content: &str) -> Self {
            use std::sync::atomic::{AtomicUsize, Ordering};
            static CTR: AtomicUsize = AtomicUsize::new(0);
            let n = CTR.fetch_add(1, Ordering::SeqCst);
            let base = std::env::temp_dir().join(format!(
                "legado_toc_rule_43b_{}_{}_{}",
                std::process::id(),
                n,
                tag
            ));
            let books = base.join("books");
            std::fs::create_dir_all(&books).unwrap();
            std::fs::write(books.join(name), content).unwrap();

            // 调用方已持有 `ensure_test_db` 串行锁并完成 DB 初始化
            let previous_db_path = crate::db_state::current_db_path();
            crate::db_state::record_db_path(base.join("legado.db").to_str().unwrap());
            let rel = format!("books/{name}");
            let imported = crate::api::book_import::import_local_book(&rel).unwrap();
            assert!(imported.success, "导入失败: {:?}", imported.error);
            let book_url = imported.book.unwrap().book_url;
            Self {
                base,
                book_url,
                previous_db_path,
            }
        }

        fn cleanup(self) {
            with_database(|db| {
                let tx = db
                    .connection()
                    .unchecked_transaction()
                    .map_err(|e| LegadoError::Database(format!("开启清理事务失败: {e}")))?;
                BookChapterRepository::new(db.connection()).delete_by_book_url(&self.book_url)?;
                BookRepository::new(db.connection()).delete_by_url(&self.book_url)?;
                tx.commit()
                    .map_err(|e| LegadoError::Database(format!("提交清理事务失败: {e}")))?;
                Ok(())
            })
            .unwrap();
            match self.previous_db_path {
                Some(path) => crate::db_state::record_db_path(&path),
                None => crate::db_state::record_db_path(""),
            }
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    /// [批1b-3] config 缺省/非法/越界回落语义 + 本地 TXT 目录数量随配置变化
    ///
    /// 端到端：无规则长文（内置规则零命中）→ 缺省 3000 字档位分章；
    /// `config:maxLengthWithNoToc` 改大（50000，范围内）→ 章节数减少；
    /// 非法值/越界下限回落夹逼到 3000（同默认）；越界上限夹逼到 100000。
    /// 规则命中时不按长度切。夹逼语义对齐参考版 `coerceIn(3000, 100000)`。
    #[test]
    fn local_txt_no_rule_length_split_follows_config() {
        let _db_guard = crate::db_state::ensure_test_db();
        // ASCII 头 + 6 行 × 1500 汉字（UTF-8 4501 字节/行，27011 字节）
        let line = "文".repeat(1500);
        let mut content = String::from("head\n");
        for _ in 0..6 {
            content.push_str(&line);
            content.push('\n');
        }
        let fixture = LocalTxtFixture::new("1b3", "longdoc.txt", &content);
        let book_url = fixture.book_url.clone();

        // 1) 缺省（无配置）：按默认 3000 字符档位分章
        let dflt = get_chapters(&book_url).unwrap();
        assert!(
            dflt.total > 1,
            "缺省档位长文应切多章: {:?}",
            dflt.chapters
                .iter()
                .map(|c| (&c.title, c.start))
                .collect::<Vec<_>>()
        );
        assert!(!dflt.used_custom_rule, "长度分章不得标记 used_custom_rule");
        let total_default = dflt.total;

        // 2) 范围内改大档位（50000）→ 重新解析后章节数减少
        crate::api::config_api::set_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY, "50000").unwrap();
        clear_chapters_for_reparse(&book_url);
        let big = get_chapters(&book_url).unwrap();
        assert!(
            big.total < total_default,
            "50000 字档位应比 3000 档位切更少章: {} vs {total_default}",
            big.total
        );

        // 3) 非法值（非数字）→ 回落默认档位
        crate::api::config_api::set_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY, "abc").unwrap();
        clear_chapters_for_reparse(&book_url);
        let invalid = get_chapters(&book_url).unwrap();
        assert_eq!(invalid.total, total_default, "非法值应回落默认 3000 档位");

        // 4) 越界值：下限以下（100）夹逼到 3000（同默认）；上限以上（200000）
        //    夹逼到 100000（同 50000 档章数）
        crate::api::config_api::set_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY, "100").unwrap();
        clear_chapters_for_reparse(&book_url);
        let below = get_chapters(&book_url).unwrap();
        assert_eq!(below.total, total_default, "越界下限应夹逼到 3000");
        crate::api::config_api::set_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY, "200000").unwrap();
        clear_chapters_for_reparse(&book_url);
        let above = get_chapters(&book_url).unwrap();
        assert_eq!(
            above.total, big.total,
            "越界上限应夹逼到 100000（与 50000 档同章数分配）"
        );

        // 5) 规则命中时不按长度切（档位 3000 + 显式规则命中 → 章数=命中数）
        crate::api::config_api::set_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY, "3000").unwrap();
        crate::api::bookshelf::set_book_toc_rule(&book_url, Some(r#"{"rule":"^head$"}"#)).unwrap();
        let ruled = get_chapters(&book_url).unwrap();
        assert_eq!(
            ruled.total, 1,
            "规则命中（单标题）不得按长度切: {:?}",
            ruled.chapters
        );
        assert!(ruled.used_custom_rule);
        crate::api::bookshelf::set_book_toc_rule(&book_url, None).unwrap();

        // 收尾：清配置键，避免污染共享测试库其它用例
        crate::api::config_api::set_config(MAX_LENGTH_WITH_NO_TOC_CONFIG_KEY, "").unwrap();
        fixture.cleanup();
    }

    /// [批1b-3] 清空指定书的章节行（模拟「重新解析」触发条件：改配置后
    /// 已入库目录不自动失效，用户重进目录经既有失效机制重解析）
    fn clear_chapters_for_reparse(book_url: &str) {
        with_database(|db| {
            // [B-7] delete_by_book_url 事务外为 no-op：必须显式开启事务
            let tx = db
                .connection()
                .unchecked_transaction()
                .map_err(|e| LegadoError::Database(format!("开启目录清理事务失败: {e}")))?;
            BookChapterRepository::new(db.connection()).delete_by_book_url(book_url)?;
            tx.commit()
                .map_err(|e| LegadoError::Database(format!("提交目录清理事务失败: {e}")))?;
            Ok(())
        })
        .unwrap();
    }

    /// [批43b P1-1 红→绿] 恢复默认（tocUrl 清空）后，陈旧整书快照不得
    /// 复活旧规则。
    ///
    /// 旧行为（红）：`merge_source_fields` 仅在库内 tocUrl 非空时覆盖入参，
    /// 库内已清空 → 用陈旧快照的旧规则补齐 → 下一次 `get_chapters` 又按旧
    /// 规则解析，「恢复默认」实际失效。修复后本地 TXT 的 tocUrl 一律取库内值。
    #[test]
    fn stale_full_book_write_does_not_resurrect_cleared_toc_rule() {
        let _db_guard = crate::db_state::ensure_test_db();
        let fixture = LocalTxtFixture::new(
            "p11",
            "restore.txt",
            "\n【第一篇】 开端\n甲。\n【第二篇】 继续\n乙。\n第五章 默认\n丙。\n",
        );
        let book_url = fixture.book_url.clone();
        let rule_a = r#"{"rule":"^【第.+篇】.*$"}"#;

        // 应用显式规则 → 旧快照（tocUrl=规则 A，total=2）
        crate::api::bookshelf::set_book_toc_rule(&book_url, Some(rule_a)).unwrap();
        let custom = get_chapters(&book_url).unwrap();
        assert_eq!(custom.total, 2, "{:?}", custom.chapters);
        let stale = crate::api::bookshelf::get_book(&book_url)
            .unwrap()
            .expect("书籍应存在");
        assert!(!stale.toc_url.is_empty());

        // 恢复默认 → 目录按默认规则重解析（1 章）
        crate::api::bookshelf::set_book_toc_rule(&book_url, None).unwrap();
        let dflt = get_chapters(&book_url).unwrap();
        assert_eq!(dflt.total, 1, "{:?}", dflt.chapters);
        assert_eq!(dflt.chapters[0].title, "第五章 默认");

        // 陈旧整书快照回写：本地 TXT tocUrl 必须取库内空值
        crate::api::bookshelf::update_book(&serde_json::to_string(&stale).unwrap())
            .expect("update_book 应成功");
        let saved = crate::api::bookshelf::get_book(&book_url)
            .unwrap()
            .expect("书籍应存在");
        assert_eq!(saved.toc_url, "", "恢复默认后的空 tocUrl 不得被旧快照复活");
        assert_eq!(saved.total_chapter_num, 1, "派生字段也不得被旧快照打回");

        let after = get_chapters(&book_url).unwrap();
        assert_eq!(after.total, 1, "{:?}", after.chapters);
        assert_eq!(after.chapters[0].title, "第五章 默认");
        assert!(!after.used_custom_rule, "恢复默认后应按内置默认规则解析");

        fixture.cleanup();
    }

    /// [批43b P1-2 红→绿] `setBookTocRule` 返回的 Book 派生字段已失效
    /// （0/NULL），整书写回不得把已解析出的 N 打回 0；缓存命中路径还要能
    /// 修复历史坏值。
    #[test]
    fn stale_book_from_set_toc_rule_does_not_reset_derived_fields() {
        let _db_guard = crate::db_state::ensure_test_db();
        let fixture = LocalTxtFixture::new(
            "p12",
            "derived.txt",
            "第一章 起始\n正文一。\n第二章 继续\n正文二。\n",
        );
        let book_url = fixture.book_url.clone();
        let rule = r#"{"rule":"^第.+章.*$"}"#;

        // setBookTocRule 返回派生字段已重置的 Book（0/NULL）
        let stale = crate::api::bookshelf::set_book_toc_rule(&book_url, Some(rule)).unwrap();
        assert_eq!(stale.total_chapter_num, 0, "设置规则后旧派生字段应失效");
        assert!(stale.latest_chapter_title.is_none());

        // 重载目录 → books 行回填 N=2
        let parsed = get_chapters(&book_url).unwrap();
        assert_eq!(parsed.total, 2, "{:?}", parsed.chapters);
        assert!(parsed.used_custom_rule);
        let expected_latest = parsed.chapters.last().unwrap().title.clone();

        // 用「set 返回的旧 Book」整书写回：派生字段必须保持 2/末章标题
        crate::api::bookshelf::update_book(&serde_json::to_string(&stale).unwrap())
            .expect("update_book 应成功");
        let saved = crate::api::bookshelf::get_book(&book_url)
            .unwrap()
            .expect("书籍应存在");
        assert_eq!(saved.total_chapter_num, 2, "陈旧 Book 不得把章数打回 0");
        assert_eq!(
            saved.latest_chapter_title.as_deref(),
            Some(expected_latest.as_str()),
            "陈旧 Book 不得清空最新章节标题"
        );

        // 缓存命中路径修复历史坏值（模拟旧版本已把 0/NULL 写回）
        with_database(|db| {
            BookRepository::new(db.connection()).update_toc_derived_fields(&book_url, 0, None, None)
        })
        .unwrap();
        let repaired = get_chapters(&book_url).unwrap();
        assert_eq!(repaired.total, 2);
        let saved = crate::api::bookshelf::get_book(&book_url)
            .unwrap()
            .expect("书籍应存在");
        assert_eq!(
            saved.total_chapter_num, 2,
            "缓存命中路径应以 chapters 表为准回填 totalChapterNum"
        );
        assert_eq!(
            saved.latest_chapter_title.as_deref(),
            Some(expected_latest.as_str()),
            "缓存命中路径应以 chapters 表为准回填 latestChapterTitle"
        );

        fixture.cleanup();
    }

    /// [批43b P2-2] 解析后复查：并发 setBookTocRule/setBookCharset 已清目录
    /// 时，按旧设置解析的结果不得落库（返回 false 让调用方重解析）。
    #[test]
    fn local_parse_result_is_discarded_when_settings_changed_mid_parse() {
        let _db_guard = crate::db_state::ensure_test_db();
        let fixture = LocalTxtFixture::new(
            "p22",
            "race.txt",
            "第一章 起始\n正文一。\n第二章 继续\n正文二。\n",
        );
        let book_url = fixture.book_url.clone();

        // 解析前快照：默认规则 + 自动编码
        let snapshot = local_parse_snapshot(&book_url).unwrap();
        assert!(snapshot.toc_url.as_deref() == Some(""));
        assert!(snapshot.charset.is_none());

        // 并发窗口内用户改规则（清空目录并写 tocUrl）
        crate::api::bookshelf::set_book_toc_rule(&book_url, Some(r#"{"rule":"^第.+章.*$"}"#))
            .unwrap();

        // 旧快照解析出的章节若落库，会把新规则下的空目录覆盖成旧章节
        let bogus = vec![BookChapter {
            book_url: book_url.clone(),
            url: "txt://chapter/0".to_string(),
            title: "旧规则章节".to_string(),
            index: 0,
            ..BookChapter::default()
        }];
        let committed = persist_local_chapters_if_unchanged(&book_url, &snapshot, &bogus).unwrap();
        assert!(!committed, "设置已变更时必须拒绝写入旧解析结果");

        let count = with_database(|db| {
            BookChapterRepository::new(db.connection()).count_by_book_url(&book_url)
        })
        .unwrap();
        assert_eq!(count, 0, "旧解析结果不得落库");

        // 按新设置重新解析仍可正常入库
        let fresh = get_chapters(&book_url).unwrap();
        assert_eq!(fresh.total, 2);
        assert!(fresh.used_custom_rule);

        fixture.cleanup();
    }

    // ─── refresh_toc 测试 ───────────────────────────────────────────────────

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_refresh_toc_success() {
        // refresh_toc 入口执行 begin_book_flow（切 flow scope）→ 触碰全局
        // store，持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let source_url = "https://toc-test.example.com";
        let book_url = "https://toc-test.example.com/book/1";
        let _db_guard = setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
    }

    #[test]
    fn test_refresh_toc_source_not_found() {
        // P2-1：refresh_toc 入口在 DB 查询前执行 begin_book_flow（切
        // flow scope，清旧前缀）→ 触碰全局 store 状态，须与其它 store
        // 测试串行（共享 crate 级 test_support 锁）；结尾复位 flow scope
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = setup_db_and_source("https://other.example.com");
        let err = refresh_toc("https://x.com/book", "https://nonexistent.example.com").unwrap_err();
        assert!(err.to_string().contains("书源不存在"));
        legado_js::host_api::variable_store::clear_flow_scope().expect("复位 flow scope");
    }

    /// refresh_toc 占位落库须打 NOT_SHELF，书架 list 不可见（Task#125）
    #[test]
    fn test_refresh_toc_placeholder_not_on_shelf() {
        use legado_core::models::book::book_type;
        use legado_db::BookRepository;

        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://placeholder-not-shelf.example.com/book/1";

        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: "https://src.example.com".to_string(),
                origin_name: "测试书源".to_string(),
                book_type: book_type::NOT_SHELF,
                ..legado_core::models::Book::default()
            };
            book_repo.insert(&book)?;
            let saved = book_repo.find_by_url(book_url)?.unwrap();
            assert_ne!(saved.book_type & book_type::NOT_SHELF, 0);
            let shelf = book_repo.find_all_in_shelf()?;
            assert!(!shelf.iter().any(|b| b.book_url == book_url));
            Ok(())
        })
        .unwrap();
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_refresh_toc_saves_to_db() {
        // refresh_toc 入口执行 begin_book_flow（切 flow scope）→ 触碰全局
        // store，持 crate 级 test_support 锁串行防串表
        let _lock = crate::test_support::lock_global_store();
        let source_url = "https://toc-db-test.example.com";
        let book_url = "https://toc-db-test.example.com/book/2";
        let _db_guard = setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
    }

    // ─── [P2-2] 存量坏 tocUrl 自愈测试 ─────────────────────────────────────

    /// [P2-2] 脚本化目录 fetcher：按 URL 返回预置章节（未命中 → 空列表），
    /// 记录每次 get_chapters 请求 URL 供断言
    struct ScriptedTocFetcher {
        chapters_by_url: Vec<(String, Vec<WebChapter>)>,
        requested: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
        /// [P2-1 复审] 自愈回写调用点回归测试：在首次抓取（坏 tocUrl）时模拟刷新窗口
        /// （抓取前快照读取之后、tocUrl 回写之前）发生的「并发进度写入」——把该书的
        /// durChapterIndex 置为 7。单列 update_toc_url 只触碰 tocUrl 不会覆盖它；若调用点
        /// 退回旧的全行 update 形式，抓取前快照里的 0 会覆盖掉 7（丢更新）。仅自愈测试置
        /// Some，其它测试置 None 不受影响。
        seed_progress_book_url: Option<String>,
    }

    impl BookSourceFetcher for ScriptedTocFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<legado_core::web_book::WebBookInfo> {
            Err(LegadoError::Internal("mock: get_book_info unused".into()))
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            let mut req = self.requested.lock().unwrap_or_else(|e| e.into_inner());
            let is_first_fetch = req.is_empty();
            req.push(book_url.to_string());
            drop(req);

            // [P2-1 复审] 模拟刷新窗口内的「并发进度写入」：只在首次抓取（坏 tocUrl）播种，
            // 避开重试抓取，确保落在「快照读取之后、tocUrl 回写之前」的丢更新窗口内。
            if is_first_fetch {
                if let Some(burl) = &self.seed_progress_book_url {
                    let _ = with_database(|db| {
                        use rusqlite::params;
                        db.connection()
                            .execute(
                                "UPDATE books SET durChapterIndex = 7 WHERE bookUrl = ?1",
                                params![burl],
                            )
                            .map_err(|e| {
                                LegadoError::Database(format!("播种 durChapterIndex 失败: {e}"))
                            })?;
                        Ok(())
                    });
                }
            }

            Ok(self
                .chapters_by_url
                .iter()
                .find(|(u, _)| u == book_url)
                .map(|(_, c)| c.clone())
                .unwrap_or_default())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }
    }

    /// [P2-2] 存量坏 tocUrl 自愈：首抓按坏 tocUrl 未解析到章节 → 按书籍页
    /// 取址点（originBookUrl）重试一次；成功则持久化新 tocUrl，后续刷新直达
    #[test]
    fn test_refresh_toc_self_heals_bad_toc_url() {
        use std::sync::{Arc, Mutex};

        let book_url = "https://p2-2-heal.example.com/book/1";
        let source_url = "https://p2-2-heal-src.example.com";
        let bad_toc = "https://p2-2-heal.example.com/old-toc";
        let detail_url = "https://p2-2-heal-src.example.com/book/1";

        let _db_guard = setup_db_and_source(source_url);
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "测试书源".to_string(),
                name: "自愈书".to_string(),
                toc_url: bad_toc.to_string(),
                origin_book_url: detail_url.to_string(),
                ..legado_core::models::Book::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let requested = Arc::new(Mutex::new(Vec::new()));
        let fetcher = ScriptedTocFetcher {
            chapters_by_url: vec![
                (bad_toc.to_string(), vec![]),
                (
                    detail_url.to_string(),
                    vec![WebChapter {
                        index: 0,
                        title: "第一章".to_string(),
                        url: format!("{detail_url}/c1"),
                        is_vip: false,
                        is_volume: false,
                        is_pay: false,
                        tag: None,
                        variable: None,
                        word_count: None,
                    }],
                ),
            ],
            requested: Arc::clone(&requested),
            seed_progress_book_url: Some(book_url.to_string()),
        };
        let engine = WebBookEngine::new(fetcher);
        let resp = refresh_toc_with_fetcher(book_url, source_url, &engine).expect("自愈刷新应成功");
        assert_eq!(resp.total, 1, "重试后应解析到 1 个章节");

        let reqs = requested.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(
            reqs,
            vec![bad_toc.to_string(), detail_url.to_string()],
            "应先按坏 tocUrl 抓取，再按书籍页取址点重试"
        );

        // 新 tocUrl 已持久化（对齐既有 update 语义）
        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(saved.toc_url, detail_url, "成功地址应持久化为新 tocUrl");
            // [P2-1 复审] 调用点回归检测：刷新窗口内并发写入的进度列
            // （durChapterIndex=7，由 get_chapters 首次抓取时播种）必须保留。
            // 单列 update_toc_url 只触碰 tocUrl；若调用点退回旧的全行 update 形式，
            // 抓取前 37 列快照里的 0 会覆盖 7 → 本断言失败。
            assert_eq!(
                saved.dur_chapter_index, 7,
                "刷新窗口内并发写入的进度列（durChapterIndex=7）不得被抓取前全行快照覆盖"
            );
            Ok(())
        })
        .expect("DB 断言失败");

        // 收尾清理，避免污染共享测试库
        with_database(|db| {
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            let _ = BookRepository::new(db.connection()).delete(book_url);
            Ok(())
        })
        .ok();
    }

    /// [P2-2] tocUrl 与 originBookUrl 均为空时，首抓地址即入参 bookUrl（书籍页
    /// 取址点的最终回退），不存在「坏值重试」对象 → 不得重复抓取；仍为空时
    /// 走既有空结果保护（无既有章节 → 可读错误）
    #[test]
    fn test_refresh_toc_no_duplicate_retry_when_toc_url_empty() {
        use std::sync::{Arc, Mutex};

        let book_url = "https://p2-2-noretry.example.com/book/1";
        let source_url = "https://p2-2-noretry-src.example.com";

        let _db_guard = setup_db_and_source(source_url);
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "测试书源".to_string(),
                name: "无重试书".to_string(),
                ..legado_core::models::Book::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let requested = Arc::new(Mutex::new(Vec::new()));
        let fetcher = ScriptedTocFetcher {
            chapters_by_url: vec![(book_url.to_string(), vec![])],
            requested: Arc::clone(&requested),
            seed_progress_book_url: None,
        };
        let engine = WebBookEngine::new(fetcher);
        let err = refresh_toc_with_fetcher(book_url, source_url, &engine)
            .expect_err("未解析到章节且无既有目录应返回可读错误");
        assert!(
            err.to_string().contains("未从书源解析到任何章节"),
            "应走既有空结果保护的可读错误文案"
        );

        let reqs = requested.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(
            reqs,
            vec![book_url.to_string()],
            "取址点与首抓地址相同时不得重复重试"
        );

        // 收尾清理
        with_database(|db| {
            let _ = BookRepository::new(db.connection()).delete(book_url);
            Ok(())
        })
        .ok();
    }

    /// [目录派生字段同步] refresh_toc 成功后 books 行 totalChapterNum/
    /// latestChapterTitle 同步为新目录值（红态：刷新前 999/「旧最新章节」；
    /// 修复前第 4 步事务只删章+插章+清缓存，派生字段不触碰 → 书架「共 N 章」
    /// 与详情页「最新·…」保持旧值）。真实 origin 书籍走单列 UPDATE 写器
    /// （B-3 安全：不写进度列——播种 durChapterIndex=42 断言不被覆盖）。
    #[test]
    fn test_refresh_toc_syncs_toc_derived_fields() {
        use std::sync::{Arc, Mutex};

        let book_url = "https://toc-sync.example.com/book/1";
        let source_url = "https://toc-sync-src.example.com";
        let toc_url = "https://toc-sync.example.com/toc";

        let _db_guard = setup_db_and_source(source_url);
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "测试书源".to_string(),
                name: "同步书".to_string(),
                toc_url: toc_url.to_string(),
                // 红态播种：陈旧的目录派生字段 + 进度列（B-3 回归哨兵）
                total_chapter_num: 999,
                latest_chapter_title: Some("旧最新章节".to_string()),
                dur_chapter_index: 42,
                ..legado_core::models::Book::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let requested = Arc::new(Mutex::new(Vec::new()));
        let fetcher = ScriptedTocFetcher {
            chapters_by_url: vec![(
                toc_url.to_string(),
                (0..4)
                    .map(|i| WebChapter {
                        index: i,
                        title: format!("新目录第{i}章"),
                        url: format!("{toc_url}/c{i}"),
                        is_vip: false,
                        is_volume: false,
                        is_pay: false,
                        tag: None,
                        variable: None,
                        word_count: None,
                    })
                    .collect(),
            )],
            requested: Arc::clone(&requested),
            seed_progress_book_url: None,
        };
        let engine = WebBookEngine::new(fetcher);
        let resp = refresh_toc_with_fetcher(book_url, source_url, &engine).expect("目录刷新应成功");
        assert_eq!(resp.total, 4, "应解析到 4 个章节");

        with_database(|db| {
            let saved = BookRepository::new(db.connection())
                .find_by_url(book_url)?
                .expect("书籍记录应仍存在");
            assert_eq!(
                saved.total_chapter_num, 4,
                "totalChapterNum 应同步为新目录章数（不得保留旧值 999）"
            );
            assert_eq!(
                saved.latest_chapter_title.as_deref(),
                Some("新目录第3章"),
                "latestChapterTitle 应同步为新目录末章标题（不得保留旧值）"
            );
            assert_eq!(
                saved.dur_chapter_index, 42,
                "进度列（durChapterIndex=42）不得被派生字段同步覆盖（B-3）"
            );
            Ok(())
        })
        .expect("DB 断言失败");

        // 收尾清理
        with_database(|db| {
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            let _ = BookRepository::new(db.connection()).delete(book_url);
            Ok(())
        })
        .ok();
    }

    // ─── [P2-12] 目录刷新变量链测试（2026-09-18） ───────────────────────────

    /// [P2-12] 脚本化目录 fetcher（变量表版）：捕获
    /// `get_chapters_with_hints_and_vars` 收到的变量表并返回预置章节
    struct ScriptedTocFetcherWithVars {
        vars_requested:
            std::sync::Arc<std::sync::Mutex<Vec<std::collections::HashMap<String, String>>>>,
    }

    impl BookSourceFetcher for ScriptedTocFetcherWithVars {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<legado_core::web_book::WebBookInfo> {
            Err(LegadoError::Internal("mock: get_book_info unused".into()))
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            Ok(Vec::new())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }

        async fn get_chapters_with_hints_and_vars(
            &self,
            _source: &BookSource,
            _book_url: &str,
            known_toc_url: Option<&str>,
            _book_name_hint: Option<&str>,
            variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.vars_requested
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push(variables.clone());
            Ok(vec![WebChapter {
                index: 0,
                title: "第一章".to_string(),
                url: known_toc_url
                    .map(|u| format!("{u}/c1"))
                    .unwrap_or_else(|| "https://p212.example.com/c1".to_string()),
                is_vip: false,
                is_volume: false,
                is_pay: false,
                tag: None,
                variable: None,
                word_count: None,
            }])
        }
    }

    /// [P2-12] 刷新目录：DB `books.variable`（working_book.variable，
    /// preUpdateJs 钩子后已持久化的用户值）必须传入 fetcher 变量表——
    /// 修复前回归：refresh_toc 两处抓取变量表恒空 → 目录/详情模板
    /// `{{svid}}`/`{{tok}}` 展开为空 → 请求错误地址（服务端 400）
    #[test]
    fn test_refresh_toc_passes_db_variables_to_fetcher() {
        use std::sync::{Arc, Mutex};

        let book_url = "https://p212.example.com/r1vb/detail?vid={{svid}}";
        let source_url = "https://p212-src.example.com";
        let toc_url = "https://p212.example.com/r1vb/toc?tok={{tok}}";
        let var_json = r#"{"svid":"VID123","tok":"TK777"}"#;

        let _db_guard = setup_db_and_source(source_url);
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "测试书源".to_string(),
                name: "P12变量书".to_string(),
                toc_url: toc_url.to_string(),
                origin_book_url: book_url.to_string(),
                variable: Some(var_json.to_string()),
                ..legado_core::models::Book::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let vars_requested = Arc::new(Mutex::new(Vec::new()));
        let fetcher = ScriptedTocFetcherWithVars {
            vars_requested: Arc::clone(&vars_requested),
        };
        let engine = WebBookEngine::new(fetcher);
        let resp =
            refresh_toc_with_fetcher(book_url, source_url, &engine).expect("携变量目录刷新应成功");
        assert_eq!(resp.total, 1, "应解析到 1 个章节");

        let vars = vars_requested
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone();
        assert_eq!(
            vars.len(),
            1,
            "刷新应恰好抓取一次目录（变量表正确时无坏址重试）"
        );
        assert_eq!(
            vars[0].get("svid").map(String::as_str),
            Some("VID123"),
            "svid 应自 DB books.variable 传入 fetcher（修复前恒空表）"
        );
        assert_eq!(
            vars[0].get("tok").map(String::as_str),
            Some("TK777"),
            "tok 应自 DB books.variable 传入 fetcher（修复前恒空表）"
        );

        // 收尾清理，避免污染共享测试库
        with_database(|db| {
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            let _ = BookRepository::new(db.connection()).delete(book_url);
            Ok(())
        })
        .ok();
    }

    // ─── [bookUrl 脏值修正 2026-10-05] 目录抓取链身份/取址点分离测试 ────────

    /// 捕获 refresh_toc 传给 fetcher 的（取址点, 书籍主键）二元组
    struct KeyCapturingTocFetcher {
        captured: std::sync::Arc<std::sync::Mutex<Vec<(String, String)>>>,
    }

    impl BookSourceFetcher for KeyCapturingTocFetcher {
        async fn search(
            &self,
            _source: &BookSource,
            _query: &str,
            _page: i32,
        ) -> LegadoResult<Vec<legado_core::web_book::WebSearchResult>> {
            Err(LegadoError::Internal("mock: search unused".into()))
        }

        async fn get_book_info(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<legado_core::web_book::WebBookInfo> {
            Err(LegadoError::Internal("mock: get_book_info unused".into()))
        }

        async fn get_chapters(
            &self,
            _source: &BookSource,
            _book_url: &str,
        ) -> LegadoResult<Vec<WebChapter>> {
            // 旧调用形态（未传书籍主键）落到这里：返回空让红态可见
            Ok(Vec::new())
        }

        async fn get_content(
            &self,
            _source: &BookSource,
            _chapter: &WebChapter,
        ) -> LegadoResult<String> {
            Err(LegadoError::Internal("mock: content unused".into()))
        }

        async fn get_chapters_with_book_key_and_vars(
            &self,
            _source: &BookSource,
            book_url: &str,
            book_key: &str,
            _known_toc_url: Option<&str>,
            _book_name_hint: Option<&str>,
            _variables: &std::collections::HashMap<String, String>,
        ) -> LegadoResult<Vec<WebChapter>> {
            self.captured
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .push((book_url.to_string(), book_key.to_string()));
            Ok(vec![WebChapter {
                index: 0,
                title: "第一章".to_string(),
                url: format!("{book_url}/c1"),
                is_vip: false,
                is_volume: false,
                is_pay: false,
                tag: None,
                variable: None,
                word_count: None,
            }])
        }
    }

    /// [bookUrl 脏值修正] 刷新目录链（入库书）：fetcher 收到的取址点必须是
    /// DB `books.tocUrl`、书籍主键必须是 DB `books.bookUrl`——修复前旧调用只
    /// 传 fetch_url（tocUrl）当 book_url，meta 缓存把 tocUrl 记成“书籍取址点”
    /// → 正文阶段 (书源, 章节) 反查拿到脏值交弹幕 sink（B1 落库侧兜底）。
    #[test]
    fn test_refresh_toc_passes_book_key_not_fetch_url() {
        use std::sync::{Arc, Mutex};

        let book_url = "https://bookkey-not-fetch.example.com/book/1";
        let source_url = "https://bookkey-not-fetch-src.example.com";
        let toc_url = "https://bookkey-not-fetch.example.com/toc-page";

        let _db_guard = setup_db_and_source(source_url);
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "测试书源".to_string(),
                name: "主键书".to_string(),
                toc_url: toc_url.to_string(),
                ..legado_core::models::Book::default()
            })?;
            Ok(())
        })
        .expect("初始数据写入失败");

        let captured = Arc::new(Mutex::new(Vec::new()));
        let fetcher = KeyCapturingTocFetcher {
            captured: Arc::clone(&captured),
        };
        let engine = WebBookEngine::new(fetcher);
        let resp = refresh_toc_with_fetcher(book_url, source_url, &engine).expect("目录刷新应成功");
        assert_eq!(resp.total, 1, "应解析到 1 个章节");

        let got = captured.lock().unwrap_or_else(|e| e.into_inner()).clone();
        assert_eq!(
            got,
            vec![(toc_url.to_string(), book_url.to_string())],
            "刷新链须向 fetcher 传（取址点 = DB tocUrl, 主键 = DB bookUrl）两个值；\
             修复前只传取址点当 book_url → meta 缓存 bookUrl 脏值"
        );

        // 收尾清理，避免污染共享测试库
        with_database(|db| {
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            let _ = BookRepository::new(db.connection()).delete(book_url);
            Ok(())
        })
        .ok();
    }

    // ─── fetch_chapter_content 测试 ──────────────────────────────────────────

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_chapter_content_success() {
        let source_url = "https://content-test.example.com";
        let book_url = "https://content-test.example.com/book/1";
        let chapter_url = format!("{book_url}/chapter/0");
        let _db_guard = setup_db_and_source(source_url);

        let content = fetch_chapter_content(book_url, &chapter_url, source_url).unwrap();
        assert!(!content.is_empty());
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_chapter_content_cache_hit() {
        let source_url = "https://cache-test.example.com";
        let book_url = "https://cache-test.example.com/book/1";
        let chapter_url = "https://cache-test.example.com/ch/99";
        let _db_guard = setup_db_and_source(source_url);

        // 第一次调用：从网络获取并缓存
        let content1 = fetch_chapter_content(book_url, chapter_url, source_url).unwrap();
        assert!(!content1.is_empty());

        // 第二次调用：应命中缓存，返回相同内容
        let content2 = fetch_chapter_content(book_url, chapter_url, source_url).unwrap();
        assert_eq!(content1, content2);
    }

    // ─── 阅读获取成功后写入缓存测试（Task #26）─────────────────────

    /// 阅读获取成功后缓存写入生效：save_chapter_cache 写入 cached_chapters，
    /// 复合键可查、目录页云图标数据源 list_cached_chapter_urls 可见，
    /// 重复写入（同章再次阅读）覆盖不报错
    #[test]
    fn test_save_chapter_cache_after_successful_fetch() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://cache-write-t26.example.com/book/1";
        let chapter_url = "https://cache-write-t26.example.com/ch/4";

        // 前置：该章未缓存（目录页空心云）
        let before = with_database(|db| {
            let repo = CacheBookRepository::new(db.connection());
            repo.get_by_book_and_chapter_url(book_url, chapter_url)
        })
        .unwrap();
        assert!(before.is_none());

        // 抓取成功后写缓存（fetch_chapter_content_inner 同一时机）
        save_chapter_cache(book_url, 4, "第四章", chapter_url, "第四章正文");

        // 复合键命中（目录页实心云）
        let cached = with_database(|db| {
            let repo = CacheBookRepository::new(db.connection());
            repo.get_by_book_and_chapter_url(book_url, chapter_url)
        })
        .unwrap()
        .expect("阅读获取成功后应写入缓存");
        assert_eq!(cached.content, "第四章正文");
        assert_eq!(cached.chapter_index, 4);
        assert_eq!(cached.chapter_title, "第四章");

        // 目录页云图标数据源可见
        let urls = crate::api::cache_api::list_cached_chapter_urls(book_url).unwrap();
        assert!(urls.contains(&chapter_url.to_string()));

        // 同章重复写入覆盖不报错（INSERT OR REPLACE）
        save_chapter_cache(book_url, 4, "第四章", chapter_url, "第四章正文v2");
        let cached = with_database(|db| {
            let repo = CacheBookRepository::new(db.connection());
            repo.get_by_book_and_chapter_url(book_url, chapter_url)
        })
        .unwrap()
        .unwrap();
        assert_eq!(cached.content, "第四章正文v2");
    }

    // ─── [P2-28b] 章节字数回填链测试（对齐原版 BookHelp.writeText → upWordCount）──

    /// 辅助：读取指定书指定 index 章节的 wordCount
    fn read_chapter_word_count(book_url: &str, index: i32) -> Option<String> {
        with_database(|db| {
            Ok(BookChapterRepository::new(db.connection())
                .find_by_book_url_and_index(book_url, index)?
                .and_then(|c| c.word_count))
        })
        .unwrap_or_default()
    }

    /// [P2-28b] word_count_format 与原版 StringUtils.wordCountFormat 逐值对齐
    ///
    /// 原版：words≤0 → ""；0<words≤10000 → "{words}字"；words>10000 →
    /// `DecimalFormat("#.#").format(words * 1.0f / 10000f.toDouble()) + "万字"`。
    /// DecimalFormat 按 double 的精确二进制值 HALF_EVEN 舍入，故以下用例覆盖
    /// 浮点怪癖值：10500（1.05 双精度略高于 1.05 → 1.1）、12500（1.25 精确
    /// 平局 → HALF_EVEN 取偶 1.2）、13500（1.35 双精度略高于 1.35 → 1.4）、
    /// 14999/15000（同为 1.5）、10001/99999（去尾零形态）
    #[test]
    fn test_word_count_format_aligned_with_original() {
        let cases = [
            (0usize, ""),
            (1, "1字"),
            (9999, "9999字"),
            (10000, "10000字"),
            (10001, "1万字"),
            (10500, "1.1万字"),
            (12500, "1.2万字"),
            (13500, "1.4万字"),
            (14999, "1.5万字"),
            (15000, "1.5万字"),
            (25000, "2.5万字"),
            (99999, "10万字"),
        ];
        for (words, expected) in cases {
            assert_eq!(
                word_count_format(words),
                expected,
                "words={} 应与原版 wordCountFormat 一致",
                words
            );
        }
    }

    /// [P2-28b] 缓存写入成功后回填章节字数（对齐原版 writeText「成功写入后回填」；
    /// 字数 = UTF-16 码元数，格式对齐原版 StringUtils.wordCountFormat）
    #[test]
    fn test_save_chapter_cache_backfills_word_count() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://wc-backfill.example.com/book/1";
        let chapter_url = "https://wc-backfill.example.com/ch/4";

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: "https://wc-src.example.com".to_string(),
                ..legado_core::models::Book::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                url: chapter_url.to_string(),
                title: "第四章".to_string(),
                book_url: book_url.to_string(),
                index: 4,
                ..BookChapter::default()
            })?;
            Ok(())
        })
        .expect("前置数据写入失败");

        // 10500 UTF-16 码元 → "1.1万字"（double(1.05) 精确值 1.0500…0044 > 1.05 中点，
        // HALF_EVEN 进位——与原版 DecimalFormat("#.#") 行为一致）
        assert!(
            save_chapter_cache(book_url, 4, "第四章", chapter_url, &"字".repeat(10500)),
            "缓存写入应成功"
        );
        assert_eq!(
            read_chapter_word_count(book_url, 4).as_deref(),
            Some("1.1万字"),
            "缓存写入成功后应按原版 wordCountFormat 格式回填字数"
        );

        // 短内容 → 纯字数 + 字 形态
        assert!(
            save_chapter_cache(book_url, 4, "第四章", chapter_url, "第四章正文"),
            "缓存写入应成功"
        );
        assert_eq!(
            read_chapter_word_count(book_url, 4).as_deref(),
            Some("5字"),
            "≤10000 码元应为 纯字数+字 形态"
        );

        // 收尾清理（章节行事务外删除为 B-7 no-op，测试库隔离无害）
        with_database(|db| {
            CacheBookRepository::new(db.connection()).delete_by_book(book_url)?;
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            BookRepository::new(db.connection()).delete_by_url(book_url)?;
            Ok(())
        })
        .ok();
    }

    /// [P2-28b] 缓存命中惰性自愈：存量 wordCount 为空的章，命中返回路径按本次
    /// 缓存正文长度补算回填一次；首次回填后 wordCount 非空，后续命中不再写
    /// （一次性语义，经 AFTER UPDATE 探针触发器计数证明）
    #[test]
    fn test_cache_hit_lazy_self_heals_word_count_once() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://wc-heal.example.com/book/1";
        let chapter_url = "https://wc-heal.example.com/ch/7";
        let content = "x".repeat(25000); // 25000 UTF-16 码元 → "2.5万字"

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: "https://wc-src.example.com".to_string(),
                ..legado_core::models::Book::default()
            })?;
            // 章节行（wordCount 为空，模拟存量目录）
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                url: chapter_url.to_string(),
                title: "第七章".to_string(),
                book_url: book_url.to_string(),
                index: 7,
                ..BookChapter::default()
            })?;
            // 直写缓存行（模拟早于回填链引入的旧缓存，wordCount 未回填；
            // 不经 save_chapter_cache，避免其自身的回填掩盖「存量」前提）
            CacheBookRepository::new(db.connection()).insert(&CachedChapter {
                id: 0,
                book_url: book_url.to_string(),
                chapter_index: 7,
                chapter_title: "第七章".to_string(),
                chapter_url: chapter_url.to_string(),
                content: content.clone(),
                cached_at: 0,
                size_bytes: content.len() as i64,
            })?;
            Ok(())
        })
        .expect("前置数据写入失败");

        // 首次命中：正文原样返回 + 一次性字数回填
        let got = fetch_chapter_content(book_url, chapter_url, "https://wc-src.example.com")
            .expect("缓存命中正文返回不受回填影响");
        assert_eq!(got, content);
        assert_eq!(
            read_chapter_word_count(book_url, 7).as_deref(),
            Some("2.5万字"),
            "首次命中应惰性自愈回填字数"
        );

        // 安装 UPDATE 探针（仅本书范围），证明二次命中不再写 wordCount
        with_database(|db| {
            db.connection()
                .execute("CREATE TABLE IF NOT EXISTS wc_update_probe (n INTEGER)", [])
                .map_err(|e| LegadoError::Database(format!("探针建表失败: {e}")))?;
            db.connection()
                .execute(
                    "CREATE TRIGGER wc_heal_probe AFTER UPDATE ON chapters \
                     WHEN OLD.bookUrl = 'https://wc-heal.example.com/book/1' \
                     BEGIN INSERT INTO wc_update_probe VALUES (1); END",
                    [],
                )
                .map_err(|e| LegadoError::Database(format!("探针触发器创建失败: {e}")))?;
            Ok(())
        })
        .expect("探针安装失败");

        // 二次命中：wordCount 已非空 → 不重复回填
        let got2 =
            fetch_chapter_content(book_url, chapter_url, "https://wc-src.example.com").unwrap();
        assert_eq!(got2, content);
        assert_eq!(
            read_chapter_word_count(book_url, 7).as_deref(),
            Some("2.5万字")
        );
        let updates = with_database(|db| {
            let count: i64 = db
                .connection()
                .query_row("SELECT COUNT(*) FROM wc_update_probe", [], |row| row.get(0))
                .map_err(|e| LegadoError::Database(format!("探针计数查询失败: {e}")))?;
            Ok(count)
        })
        .unwrap();
        assert_eq!(updates, 0, "二次命中不应再次写 wordCount（一次性回填）");

        // 收尾清理：撤探针 + 清缓存/章节/书行
        with_database(|db| {
            let _ = db
                .connection()
                .execute("DROP TRIGGER IF EXISTS wc_heal_probe", []);
            let _ = db
                .connection()
                .execute("DROP TABLE IF EXISTS wc_update_probe", []);
            CacheBookRepository::new(db.connection()).delete_by_book(book_url)?;
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            BookRepository::new(db.connection()).delete_by_url(book_url)?;
            Ok(())
        })
        .ok();
    }

    /// [P2-28b] 回填失败不得影响正文返回：用按 bookUrl 定界的触发器模拟
    /// chapters 表 UPDATE 失败（RAISE ABORT；定界使即便清理遗漏也不波及其他用例）
    /// ——缓存命中自愈路径与缓存写入路径均降级告警，正文照常返回
    #[test]
    fn test_word_count_backfill_failure_harmless() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://wc-fail.example.com/book/1";
        let chapter_url = "https://wc-fail.example.com/ch/0";
        let content = "f".repeat(12000); // 12000 码元 → "1.2万字"（1.2 为精确双精度值）

        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: "https://wc-src.example.com".to_string(),
                ..legado_core::models::Book::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                url: chapter_url.to_string(),
                title: "第一章".to_string(),
                book_url: book_url.to_string(),
                index: 0,
                ..BookChapter::default()
            })?;
            CacheBookRepository::new(db.connection()).insert(&CachedChapter {
                id: 0,
                book_url: book_url.to_string(),
                chapter_index: 0,
                chapter_title: "第一章".to_string(),
                chapter_url: chapter_url.to_string(),
                content: content.clone(),
                cached_at: 0,
                size_bytes: content.len() as i64,
            })?;
            // 模拟回填失败：仅拦截本书的 chapters UPDATE
            db.connection()
                .execute(
                    "CREATE TRIGGER wc_fail_sim BEFORE UPDATE ON chapters \
                     WHEN OLD.bookUrl = 'https://wc-fail.example.com/book/1' \
                     BEGIN SELECT RAISE(ABORT, '模拟字数回填失败'); END",
                    [],
                )
                .map_err(|e| LegadoError::Database(format!("失败模拟触发器创建失败: {e}")))?;
            Ok(())
        })
        .expect("前置数据写入失败");

        // 缓存命中路径：自愈回填失败（降级告警）→ 正文仍原样返回
        let got = fetch_chapter_content(book_url, chapter_url, "https://wc-src.example.com")
            .expect("回填失败不得影响正文返回");
        assert_eq!(got, content);

        // 写入路径：缓存写入成功（覆盖缓存行），回填失败降级告警，主流程不受影响
        save_chapter_cache(book_url, 0, "第一章", chapter_url, &content);

        // wordCount 保持为空（回填从未成功）
        assert!(
            read_chapter_word_count(book_url, 0)
                .map(|w| w.trim().is_empty())
                .unwrap_or(true),
            "回填失败后 wordCount 应保持为空"
        );

        // 收尾清理：撤触发器 + 清缓存/章节/书行
        with_database(|db| {
            let _ = db
                .connection()
                .execute("DROP TRIGGER IF EXISTS wc_fail_sim", []);
            CacheBookRepository::new(db.connection()).delete_by_book(book_url)?;
            let _ = BookChapterRepository::new(db.connection()).delete_by_book_url(book_url);
            BookRepository::new(db.connection()).delete_by_url(book_url)?;
            Ok(())
        })
        .ok();
    }

    #[test]
    fn test_fetch_chapter_content_source_not_found() {
        let _db_guard = setup_db_and_source("https://other2.example.com");
        let err = fetch_chapter_content(
            "https://x.com/book",
            "https://x.com/ch/1",
            "https://no-such-source.example.com",
        )
        .unwrap_err();
        assert!(err.to_string().contains("书源不存在"));
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_fetch_chapter_content_returns_text_not_json_metadata() {
        let source_url = "https://text-check.example.com";
        let book_url = "https://text-check.example.com/book/1";
        let chapter_url = format!("{book_url}/chapter/0");
        let _db_guard = setup_db_and_source(source_url);

        let content = fetch_chapter_content(book_url, &chapter_url, source_url).unwrap();
        // 确保返回的是真实正文，不是 JSON 元数据
        assert!(!content.contains("need_fetch"));
        assert!(!content.contains("chapter_url"));
    }

    // ─── 内容净化 / 替换规则测试 ────────────────────────────────────────

    /// 辅助：构造启用/禁用的替换规则
    fn make_test_rule(
        name: &str,
        pattern: &str,
        replacement: &str,
        is_regex: bool,
        enabled: bool,
    ) -> ReplaceRule {
        ReplaceRule {
            name: name.to_string(),
            pattern: pattern.to_string(),
            replacement: replacement.to_string(),
            is_regex,
            is_enabled: enabled,
            ..ReplaceRule::default()
        }
    }

    /// 测试普通字符串替换：启用的规则应生效
    #[test]
    fn test_content_processing_text_replace() {
        let rules = vec![
            make_test_rule("去广告", "广告", "", false, true),
            make_test_rule("替换test", "test", "测试", false, true),
        ];
        let result = process_content_with_rules("这是广告内容test", "", &rules, "");
        assert_eq!(result, "这是内容测试");
    }

    /// 测试正则替换：启用的正则规则应生效
    #[test]
    fn test_content_processing_regex_replace() {
        let rules = vec![make_test_rule("数字", r"\d+", "NUM", true, true)];
        let result = process_content_with_rules("abc 123 def 456", "", &rules, "");
        assert_eq!(result, "abc NUM def NUM");
    }

    /// [批15] 生产正文净化必须执行 `@js:` 替换规则
    ///
    /// 断言走 reader.rs 正文净化生产核心 [`process_content_with_rules`]，
    /// 不走 `previewReplaceRule` 预览 API：修复前执行器未注入 → `@js:` 被
    /// 安全跳过、输出原文（红）；修复后逐匹配执行 QuickJS、数字翻倍（绿）。
    /// 非 quickjs 构建口径：`@js:` 明确不执行、保留原文（不 panic）。
    #[test]
    fn test_content_processing_js_replace_rule_executes_in_production_pipeline() {
        let rules = vec![make_test_rule(
            "批15_js翻倍",
            r"(\d+)",
            "@js:String(Number(result) * 2)",
            true,
            true,
        )];
        let result = process_content_with_rules("a12b", "", &rules, "");
        #[cfg(feature = "quickjs")]
        assert_eq!(
            result, "a24b",
            "生产链路应执行 @js: 替换（result 绑定当前匹配文本）"
        );
        #[cfg(not(feature = "quickjs"))]
        assert_eq!(result, "a12b", "无 quickjs 构建 @js: 不执行，保留原文");
    }

    /// [批15 回修 P1] 2000 次匹配必须复用同一引擎并在默认 3000ms 内完成
    ///
    /// 修复前每次匹配新建 QuickJS 引擎（约 2.5ms/次），2000 次约 3s+ 会触发
    /// 规则超时、整条规则被丢弃且输出原文；复用引擎后应在预算内全部执行。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_replace_rule_2000_matches_reuse_engine_within_timeout() {
        let rules = vec![make_test_rule(
            "批15_2000匹配",
            r"(\d+)",
            "@js:String(Number(result) * 2)",
            true,
            true,
        )];
        let content = "1 ".repeat(2000);
        let expected = "2 ".repeat(2000);
        let started = std::time::Instant::now();
        let result = process_content_with_rules(&content, "", &rules, "");
        let elapsed = started.elapsed();
        eprintln!("[批15 perf] 2000 matches elapsed: {elapsed:?}");
        assert_eq!(
            result, expected,
            "2000 次 @js: 匹配应在默认 3000ms 超时内全部执行（实际 {elapsed:?}）"
        );
        assert!(
            elapsed < std::time::Duration::from_millis(3000),
            "2000 次匹配耗时 {elapsed:?} 不应触发 3000ms 规则超时"
        );
    }

    /// [批15] `@js:` 的 `chapter` / `book` 绑定在生产净化链路可见
    ///
    /// 对齐参考版 `RegexExtensions.kt:44-49`：逐匹配绑定 `result`、`chapter`
    /// 与 `book`。本章节/书籍字段全部断言，防止只绑 `result` 的半实现回归。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_content_processing_js_bindings_chapter_and_book_visible() {
        let rules = vec![make_test_rule(
            "批15_绑定可见",
            "批十五标记",
            r#"@js: result + "|" + chapter.title + "|" + chapter.index + "|" + chapter.url + "|" + chapter.bookUrl + "|" + book.name + "|" + book.author + "|" + book.bookUrl"#,
            true,
            true,
        )];
        let bindings = ReplaceJsBindings::new(
            ReplaceJsChapter {
                title: "第九章 绑定".to_string(),
                index: 9,
                url: "https://batch15.example.com/ch/9".to_string(),
                book_url: "https://batch15.example.com/book/1".to_string(),
            },
            ReplaceJsBook {
                name: "绑定书名".to_string(),
                author: "绑定作者".to_string(),
                book_url: "https://batch15.example.com/book/1".to_string(),
            },
        );
        let result = process_content_with_rules_inner_ctx(
            "前批十五标记后",
            "第九章 绑定",
            &rules,
            "绑定书名",
            true,
            false,
            None,
            true,
            bindings,
        );
        assert_eq!(
            result,
            "前批十五标记|第九章 绑定|9|https://batch15.example.com/ch/9|\
             https://batch15.example.com/book/1|绑定书名|绑定作者|\
             https://batch15.example.com/book/1后"
        );
    }

    /// [批15] 预览与生产结果一致（同一输入、同一规则）
    ///
    /// 预览走 `previewReplaceRule` FFI，生产走 reader.rs 正文净化核心；
    /// 两处共用 [`ReplaceRuleJsExecutor`] 与绑定构造函数，输出必须相等。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_replace_rule_preview_matches_production() {
        let rule = make_test_rule(
            "批15_预览一致",
            r"(\d+)",
            "@js:String(Number(result) * 2)",
            true,
            true,
        );
        let rule_json = serde_json::to_string(&rule).unwrap();
        let preview = crate::api::replace_rule_api::preview_replace_rule(&rule_json, "a12b")
            .expect("预览不应上抛异常");
        let production = process_content_with_rules("a12b", "", std::slice::from_ref(&rule), "");
        assert_eq!(preview, "a24b", "预览应真实执行 @js:");
        assert_eq!(production, preview, "预览与生产输出应完全一致");
    }

    /// [批15 回修 P2-5] `@js:` 抛错 → 保留原文，且不阻断后续 **JS** 规则
    ///
    /// 后续规则也用 `@js:`：父提交（生产链路未注入执行器）两条都跳过，
    /// 输出不会变成「本次执行」，因此本用例在父提交为红、修复后为绿。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_replace_rule_error_keeps_original_and_continues() {
        let bad = make_test_rule(
            "批15_抛错",
            "抛错标记",
            "@js:(function(){ throw new Error('boom'); })()",
            true,
            true,
        );
        let good = make_test_rule("批15_后续JS", "正常标记", r#"@js:"本次执行""#, true, true);
        let result = process_content_with_rules("抛错标记 正常标记", "", &[bad, good], "");
        assert_eq!(
            result, "抛错标记 本次执行",
            "@js: 抛错应保留原文，后续 @js: 规则仍需执行"
        );
    }

    /// [批15 回修 P2-5] `@js:` 超时 → 保留原文，且不阻断后续 **JS** 规则
    ///
    /// 后续规则也用 `@js:`（父提交两条都跳过 → 红），修复后超时规则保留
    /// 原文、后续 JS 规则执行 → 绿。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_replace_rule_timeout_keeps_original_and_continues() {
        let mut slow = make_test_rule("批15_超时", "超时标记", "@js:while(true){}", true, true);
        slow.timeout_millisecond = 50;
        let good = make_test_rule("批15_超时后JS", "正常标记", r#"@js:"本次执行""#, true, true);
        let started = std::time::Instant::now();
        let result = process_content_with_rules("超时标记 正常标记", "", &[slow, good], "");
        assert_eq!(
            result, "超时标记 本次执行",
            "@js: 超时应保留原文，后续 @js: 规则仍需执行"
        );
        assert!(
            started.elapsed() < std::time::Duration::from_secs(3),
            "规则级 50ms 超时应先于沙箱 5s 截止返回，实际耗时 {:?}",
            started.elapsed()
        );
    }

    /// [批15 回修 P1] 引擎复用后逐匹配 `let` 不重复声明（IIFE + 直接 eval 作用域）
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_replace_rule_engine_reuse_supports_let_per_match() {
        let rules = vec![make_test_rule(
            "批15_let复用",
            r"(\d+)",
            "@js: let n = Number(result); String(n * 2)",
            true,
            true,
        )];
        let result = process_content_with_rules("1 2 3", "", &rules, "");
        assert_eq!(
            result, "2 4 6",
            "同一引擎逐匹配复用不应触发顶层 let 重复声明"
        );
    }

    /// [批15 回修 P2-4] 单次 `@js:` 结果超过上限 → 保留原文，不拼进正文
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_js_replace_rule_result_length_capped() {
        let rules = vec![make_test_rule(
            "批15_结果超限",
            "超限标记",
            r#"@js:"甲".repeat(2 * 1024 * 1024)"#,
            true,
            true,
        )];
        let result = process_content_with_rules("超限标记", "", &rules, "");
        assert_eq!(
            result, "超限标记",
            "超过 1MB 的单次 @js: 结果应被拒绝并保留原文"
        );
    }

    /// [批15 回修 P2-2] `@js:` 绑定回查 chapter.url / bookUrl
    ///
    /// 调用方未持有 chapter_url 时按 (book_url, index) 回查；已持有时优先
    /// 使用调用方 URL，不再回查。book 行缺失时 bookUrl 回退书籍主键。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_build_replace_js_bindings_chapter_url_and_book_fallback() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch15-bind.example.com/book/1";
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            if book_repo.find_by_url(book_url)?.is_none() {
                book_repo.insert(&Book {
                    book_url: book_url.to_string(),
                    name: "批十五绑定书籍".to_string(),
                    author: "批十五绑定作者".to_string(),
                    ..Book::default()
                })?;
            }
            let chapter_repo = BookChapterRepository::new(db.connection());
            if chapter_repo
                .find_by_book_url_and_index(book_url, 0)?
                .is_none()
            {
                chapter_repo.insert_batch(&[BookChapter {
                    url: format!("{book_url}/chapter/0"),
                    title: "批十五绑定章节".to_string(),
                    book_url: book_url.to_string(),
                    index: 0,
                    ..BookChapter::default()
                }])?;
            }
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let book = with_database(|db| BookRepository::new(db.connection()).find_by_url(book_url))
            .unwrap()
            .expect("书籍行应存在");
        let rules = vec![make_test_rule(
            "批15_绑定回查",
            "标记",
            "@js:result",
            true,
            true,
        )];

        // 1) 无 URL hint：按 index 回查 chapter.url / bookUrl
        let bindings = build_replace_js_bindings(
            book_url,
            Some(&book),
            "批十五绑定章节",
            Some(0),
            None,
            true,
            true,
            &rules,
        );
        assert_eq!(
            bindings.chapter.url,
            format!("{book_url}/chapter/0"),
            "应按 (book_url, index) 回查章节 URL"
        );
        assert_eq!(bindings.chapter.book_url, book_url);
        assert_eq!(bindings.book.name, "批十五绑定书籍");
        assert_eq!(bindings.book.author, "批十五绑定作者");
        assert_eq!(bindings.book.book_url, book_url);

        // 2) 调用方持有 URL：优先使用，忽略 index 回查
        let bindings = build_replace_js_bindings(
            book_url,
            Some(&book),
            "批十五绑定章节",
            Some(0),
            Some("https://hint.example.com/ch/9"),
            true,
            true,
            &rules,
        );
        assert_eq!(
            bindings.chapter.url, "https://hint.example.com/ch/9",
            "调用方已持有 chapter_url 时应优先使用"
        );

        // 3) 章节不在目录（known_chapter=false）：chapter 留空、book 保留
        let bindings = build_replace_js_bindings(
            book_url,
            Some(&book),
            "不应出现的标题",
            Some(0),
            Some("https://hint.example.com/ch/999"),
            false,
            true,
            &rules,
        );
        assert_eq!(
            bindings.chapter,
            ReplaceJsChapter::default(),
            "known_chapter=false 时 chapter 绑定应留空，不得给出第 0 章错误值"
        );
        assert_eq!(bindings.book.name, "批十五绑定书籍");

        // 4) 书籍行缺失：bookUrl 回退书籍主键，name/author 空串
        let bindings = build_replace_js_bindings(
            "https://missing-book.example.com/book",
            None,
            "章节",
            Some(0),
            Some("https://missing-book.example.com/ch/0"),
            true,
            true,
            &rules,
        );
        assert_eq!(
            bindings.book.book_url, "https://missing-book.example.com/book",
            "书籍行缺失时 bookUrl 应回退书籍主键"
        );
        assert!(bindings.book.name.is_empty());
        assert!(bindings.book.author.is_empty());

        // 清理本用例数据
        with_database(|db| {
            BookChapterRepository::new(db.connection()).delete_by_book_url(book_url)?;
            BookRepository::new(db.connection()).delete_by_url(book_url)?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();
    }

    /// [批15 回修 P2-2] 生产入口 known_chapter=false 时章节绑定留空
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_apply_content_processing_unknown_chapter_leaves_bindings_empty() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch15-unknown.example.com/book/1";
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            if book_repo.find_by_url(book_url)?.is_none() {
                book_repo.insert(&Book {
                    book_url: book_url.to_string(),
                    name: "批十五未知章书籍".to_string(),
                    ..Book::default()
                })?;
            }
            Ok::<(), LegadoError>(())
        })
        .unwrap();
        let rule_id = with_database(|db| {
            ReplaceRuleRepository::new(db.connection()).insert(&ReplaceRule {
                name: "批15_未知章".to_string(),
                pattern: "批十五未知章标记".to_string(),
                // 章节为空 → 空章；否则输出错误 URL（用于区分旧行为）
                replacement:
                    r#"@js: (chapter.url === "" && chapter.title === "" && chapter.index === 0) ? "空章" : ("错误:" + chapter.url)"#
                        .to_string(),
                is_regex: true,
                is_enabled: true,
                ..ReplaceRule::default()
            })
        })
        .unwrap();

        // known_chapter=false：即便 index 回退为 0，也不能绑定第 0 章 url
        let result = apply_content_processing_chapter_with_context(
            book_url,
            "前批十五未知章标记后",
            "不应出现的标题",
            0,
            Some("https://batch15-unknown.example.com/ch/999"),
            false,
        );
        assert!(
            result.contains("空章") && !result.contains("错误:"),
            "known_chapter=false 时 chapter 绑定应留空，实际: {result}"
        );

        // known_chapter=true 且持有 URL：绑定真实 URL（输出含「错误:」标记即可）
        let result = apply_content_processing_chapter_with_context(
            book_url,
            "前批十五未知章标记后",
            "真实标题",
            0,
            Some("https://batch15-unknown.example.com/ch/999"),
            true,
        );
        assert!(
            result.contains("错误:"),
            "known_chapter=true 时应绑定调用方 URL，实际: {result}"
        );

        with_database(|db| {
            ReplaceRuleRepository::new(db.connection()).delete(rule_id)?;
            BookRepository::new(db.connection()).delete_by_url(book_url)?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();
    }

    /// [批15 回修 P3-7] 非 quickjs 构建：绑定构建直接返回空上下文（不查库）
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn test_build_replace_js_bindings_skips_lookup_without_quickjs() {
        let rules = vec![make_test_rule(
            "批15_无quickjs绑定",
            "标记",
            "@js:result",
            true,
            true,
        )];
        let bindings = build_replace_js_bindings(
            "https://batch15-nq.example.com/book",
            None,
            "章节",
            Some(0),
            None,
            true,
            true,
            &rules,
        );
        assert_eq!(
            bindings,
            ReplaceJsBindings::empty(),
            "非 quickjs 构建不应构建章节/书籍绑定（避免多余 DB 查询）"
        );
    }

    /// [批15] 非 quickjs 构建：`@js:` 明确不执行（保留原文），其他规则不受影响
    #[cfg(not(feature = "quickjs"))]
    #[test]
    fn test_js_replace_rule_skipped_in_non_quickjs_build() {
        let js_rule = make_test_rule(
            "批15_无quickjs",
            r"(\d+)",
            "@js:String(Number(result) * 2)",
            true,
            true,
        );
        let plain = make_test_rule("批15_普通", "普通标记", "已换", true, true);
        let result = process_content_with_rules("a12b 普通标记", "", &[js_rule, plain], "");
        assert_eq!(
            result, "a12b 已换",
            "无 quickjs 构建 @js: 应保留原文，普通规则仍生效"
        );
    }

    /// [批15] DB 规则加载 → `apply_content_processing_chapter` 生产入口执行 `@js:`
    ///
    /// 覆盖「get_enabled_rules → 正文净化」完整生产链路（非预览 API），
    /// 并验证生产路径把真实 `chapter.title` / `book.name` 注入 JS。
    /// 规则/token 用独立中文词汇，规避共享测试库其他规则的干扰。
    #[cfg(feature = "quickjs")]
    #[test]
    fn test_apply_content_processing_chapter_executes_db_js_rule() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://batch15-db-js.example.com/book/1";

        // 书籍行：name/author 供 JS `book.*` 绑定
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            if book_repo.find_by_url(book_url)?.is_none() {
                book_repo.insert(&Book {
                    book_url: book_url.to_string(),
                    name: "批十五测试书籍".to_string(),
                    author: "批十五作者".to_string(),
                    ..Book::default()
                })?;
            }
            let chapter_repo = BookChapterRepository::new(db.connection());
            chapter_repo.insert_batch(&[BookChapter {
                url: format!("{book_url}/chapter/0"),
                title: "批十五章节标题".to_string(),
                book_url: book_url.to_string(),
                index: 0,
                ..BookChapter::default()
            }])?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();

        let rule_id = with_database(|db| {
            ReplaceRuleRepository::new(db.connection()).insert(&ReplaceRule {
                name: "批15_db规则".to_string(),
                pattern: "批十五唯一标记甲".to_string(),
                replacement: r#"@js: result + "|" + chapter.title + "|" + book.name"#.to_string(),
                is_regex: true,
                is_enabled: true,
                ..ReplaceRule::default()
            })
        })
        .unwrap();

        let result = apply_content_processing_chapter(
            book_url,
            "前文批十五唯一标记甲后文",
            "批十五章节标题",
            0,
        );
        assert_eq!(
            result, "前文批十五唯一标记甲|批十五章节标题|批十五测试书籍后文",
            "生产入口应从 DB 加载规则并执行 @js:，chapter/book 绑定应可见"
        );

        // 清理本用例的规则/章节/书籍（避免污染共享测试库）
        with_database(|db| {
            ReplaceRuleRepository::new(db.connection()).delete(rule_id)?;
            BookChapterRepository::new(db.connection()).delete_by_book_url(book_url)?;
            BookRepository::new(db.connection()).delete_by_url(book_url)?;
            Ok::<(), LegadoError>(())
        })
        .unwrap();
    }

    /// 测试未启用规则不生效：仅传入启用规则（模拟 get_enabled_rules 过滤）
    #[test]
    fn test_content_processing_disabled_rules_not_applied() {
        // 模拟 get_enabled_rules 仅返回启用的规则
        let all_rules = [
            make_test_rule("启用", "hello", "hi", false, true),
            make_test_rule("禁用", "world", "WORLD", false, false),
        ];
        // 只传入启用的（与 get_enabled_rules 行为一致）
        let enabled: Vec<_> = all_rules.iter().filter(|r| r.is_enabled).cloned().collect();
        let result = process_content_with_rules("hello world", "", &enabled, "");
        assert_eq!(result, "hi world"); // world 未被替换
    }

    /// 测试 scope 过滤：精确匹配（scope 按分隔符拆分后须与书籍名称完全相等）
    #[test]
    fn test_content_processing_scope_filter() {
        let mut rule = make_test_rule("特定书", "a", "X", false, true);
        rule.scope = Some("特定书籍".to_string());
        let rules = vec![rule];

        // 精确匹配 scope 命中
        let result = process_content_with_rules("abc", "", &rules, "特定书籍");
        assert_eq!(result, "Xbc");

        // 不匹配 scope
        let result = process_content_with_rules("abc", "", &rules, "其他书籍");
        assert_eq!(result, "abc");
    }

    /// 测试 scope 为空字符串或 global 时全局生效
    #[test]
    fn test_content_processing_scope_global() {
        let mut rule = make_test_rule("全局", "x", "Y", false, true);
        rule.scope = Some("global".to_string());
        let rules = vec![rule.clone()];
        let result = process_content_with_rules("xax", "", &rules, "任意书籍");
        assert_eq!(result, "YaY");

        // scope 为空字符串也视为全局
        let mut rule2 = make_test_rule("空scope", "x", "Y", false, true);
        rule2.scope = Some(String::new());
        let result = process_content_with_rules("xax", "", &[rule2], "任意书籍");
        assert_eq!(result, "YaY");
    }

    /// 测试空 book_name 时带具体 scope 的规则不生效（修复 contains("") 恒真缺陷）
    #[test]
    fn test_content_processing_scope_empty_book_name() {
        let mut rule = make_test_rule("限定书", "a", "X", false, true);
        rule.scope = Some("某书籍".to_string());
        let rules = vec![rule];
        // book_name 为空时，scoped 规则不应生效
        let result = process_content_with_rules("abc", "", &rules, "");
        assert_eq!(result, "abc");
    }

    /// 测试子串不误命中：book_name="斗破" 不应命中 scope="斗破苍穹"
    #[test]
    fn test_content_processing_scope_no_substring_match() {
        let mut rule = make_test_rule("斗破苍穹", "a", "X", false, true);
        rule.scope = Some("斗破苍穹".to_string());
        let rules = vec![rule];
        // 子串书名不应命中
        let result = process_content_with_rules("abc", "", &rules, "斗破");
        assert_eq!(result, "abc");
        // 精确书名应命中
        let result = process_content_with_rules("abc", "", &rules, "斗破苍穹");
        assert_eq!(result, "Xbc");
    }

    /// 测试 scope 多分隔符（,;，；）拆分后精确匹配
    #[test]
    fn test_content_processing_scope_multi_delimiter() {
        let mut rule = make_test_rule("多书", "a", "X", false, true);
        rule.scope = Some("书A，书B;书C".to_string());
        let rules = vec![rule];
        assert_eq!(process_content_with_rules("abc", "", &rules, "书B"), "Xbc");
        assert_eq!(process_content_with_rules("abc", "", &rules, "书C"), "Xbc");
        assert_eq!(process_content_with_rules("abc", "", &rules, "书D"), "abc");
    }

    /// 测试去重复标题：正文开头与章节标题相同时应被去除
    #[test]
    fn test_content_processing_remove_duplicate_title() {
        let rules: Vec<ReplaceRule> = vec![];
        let result = process_content_with_rules("第一章 开始\n正文内容", "第一章 开始", &rules, "");
        assert_eq!(result, "正文内容");
    }

    /// 集成测试：通过 apply_content_processing 完整链路（DB 加载规则 + 净化）
    #[test]
    fn test_apply_content_processing_integration() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 插入一条唯一命名的启用规则（不清理其他测试的规则，避免并行竞态）
        let rule_id = with_database(|db| {
            let repo = ReplaceRuleRepository::new(db.connection());
            repo.insert(&ReplaceRule {
                name: "reader_集成测试规则_unique".to_string(),
                pattern: "广告文字".to_string(),
                replacement: String::new(),
                is_regex: false,
                is_enabled: true,
                ..ReplaceRule::default()
            })
        })
        .unwrap();

        let result =
            apply_content_processing("https://any-book-url.example.com", "正文广告文字结尾", "");
        assert_eq!(result, "正文结尾");

        // 清理本测试插入的规则
        with_database(|db| {
            let repo = ReplaceRuleRepository::new(db.connection());
            repo.delete(rule_id)?;
            Ok(())
        })
        .unwrap();
    }

    /// 测试 raw 变体不应用替换规则：被规则删除/替换的词仍保留
    #[test]
    fn test_content_processing_raw_keeps_replaced_words() {
        let rules = vec![make_test_rule("去广告", "广告", "", false, true)];
        // apply_replace_rules=false：即使有启用规则，"广告" 仍保留
        let result = process_content_with_rules_inner(
            "这是广告内容",
            "",
            &rules,
            "",
            false,
            false,
            None,
            true,
        );
        assert_eq!(result, "这是广告内容");
        // apply_replace_rules=true：规则生效，"广告" 被删除
        let result = process_content_with_rules_inner(
            "这是广告内容",
            "",
            &rules,
            "",
            true,
            false,
            None,
            true,
        );
        assert_eq!(result, "这是内容");
    }

    /// 测试 raw 变体仍执行去重复标题（仅替换规则关闭）
    #[test]
    fn test_content_processing_raw_still_removes_duplicate_title() {
        let rules: Vec<ReplaceRule> = vec![];
        let result = process_content_with_rules_inner(
            "第一章 开始\n正文",
            "第一章 开始",
            &rules,
            "",
            false,
            false,
            None,
            true,
        );
        assert_eq!(result, "正文");
    }

    // ─── 简繁转换透传测试 ───────────────────────────────────

    /// 测试净化管线 t2s：繁体正文经处理后转为简体
    #[test]
    fn test_content_processing_chinese_convert_t2s() {
        let rules: Vec<ReplaceRule> = vec![];
        let result = process_content_with_rules_inner(
            "測試內容",
            "",
            &rules,
            "",
            true,
            false,
            Some("t2s".to_string()),
            true,
        );
        assert_eq!(result, "测试内容");
    }

    /// 测试净化管线 s2t：简体正文经处理后转为繁体
    #[test]
    fn test_content_processing_chinese_convert_s2t() {
        let rules: Vec<ReplaceRule> = vec![];
        let result = process_content_with_rules_inner(
            "测试内容",
            "",
            &rules,
            "",
            true,
            false,
            Some("s2t".to_string()),
            true,
        );
        assert_eq!(result, "測試內容");
    }

    /// 测试 0=不转换回归：chinese_convert=None 时正文保持原样
    #[test]
    fn test_content_processing_chinese_convert_none() {
        let rules: Vec<ReplaceRule> = vec![];
        let result = process_content_with_rules_inner(
            "測試內容abc",
            "",
            &rules,
            "",
            true,
            false,
            None,
            true,
        );
        assert_eq!(result, "測試內容abc");
    }

    /// 测试设置/读取往返：0/1/2 持久化后读回一致，非法值归一为 0
    #[test]
    fn test_chinese_convert_type_roundtrip() {
        let _db_guard = crate::db_state::ensure_test_db();

        for t in [1, 2, 0] {
            set_chinese_convert_type(t);
            assert_eq!(get_chinese_convert_type(), t);
        }
        // 非法值归一为 0
        set_chinese_convert_type(9);
        assert_eq!(get_chinese_convert_type(), 0);
        set_chinese_convert_type(-1);
        assert_eq!(get_chinese_convert_type(), 0);

        // 方向映射语义：0/1/2 → None/t2s/s2t
        assert_eq!(chinese_convert_direction(0), None);
        assert_eq!(chinese_convert_direction(1), Some("t2s".to_string()));
        assert_eq!(chinese_convert_direction(2), Some("s2t".to_string()));
    }

    /// 集成测试：设置繁简配置后，apply_content_processing 完整链路对正文生效
    #[test]
    fn test_apply_content_processing_chinese_convert_integration() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://chinese-convert-test.example.com/book/1";

        // t2s：繁体正文转简体
        set_chinese_convert_type(1);
        let result = apply_content_processing(book_url, "繁體正文內容", "");
        assert_eq!(result, "繁体正文内容");

        // s2t：简体正文转繁体
        set_chinese_convert_type(2);
        let result = apply_content_processing(book_url, "简体正文内容", "");
        assert_eq!(result, "簡體正文內容");

        // 0=不转换回归
        set_chinese_convert_type(0);
        let result = apply_content_processing(book_url, "繁體正文內容", "");
        assert_eq!(result, "繁體正文內容");

        // raw 路径（内容搜索语义）不做繁简转换，保持原文（无章节上下文传 None）
        set_chinese_convert_type(1);
        let result = apply_content_processing_raw(book_url, "繁體正文內容", "", None);
        assert_eq!(result, "繁體正文內容");

        // 还原默认配置，避免影响其他测试
        set_chinese_convert_type(0);
    }

    /// 测试标题繁简转换：对齐 Kotlin getDisplayTitle（1=t2s / 2=s2t / 0=不转）
    #[test]
    fn test_title_convert_by_type() {
        assert_eq!(convert_title_by_type("第一章 測試", 1), "第一章 测试");
        assert_eq!(convert_title_by_type("第一章 测试", 2), "第一章 測試");
        assert_eq!(convert_title_by_type("第一章 測試", 0), "第一章 測試");
    }

    // ─── get_chapter_content_full 测试 ─────────────────────────────────────

    /// 章节不存在时应返回错误
    #[test]
    fn test_get_chapter_content_full_chapter_not_found() {
        let _db_guard = crate::db_state::ensure_test_db();
        let err = get_chapter_content_full("https://no-such-book.example.com", 999).unwrap_err();
        assert!(err.to_string().contains("章节"));
    }

    /// 在线书籍未配置书源（origin 为空）时应返回错误
    #[test]
    fn test_get_chapter_content_full_no_origin() {
        let _db_guard = crate::db_state::ensure_test_db();
        let book_url = "https://full-test-no-origin.example.com/book/1";

        // 插入一本 origin 为空的书籍和章节
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: String::new(), // 空 origin
                ..legado_core::models::Book::default()
            };
            let _ = book_repo.insert(&book);

            let ch_repo = BookChapterRepository::new(db.connection());
            let ch = legado_core::models::BookChapter {
                url: format!("{book_url}/ch/0"),
                title: "第一章".to_string(),
                is_volume: false,
                base_url: book_url.to_string(),
                book_url: book_url.to_string(),
                index: 0,
                is_vip: false,
                is_pay: false,
                resource_url: None,
                tag: None,
                word_count: None,
                start: None,
                end: None,
                start_fragment_id: None,
                end_fragment_id: None,
                variable: None,
                img_url: None,
            };
            let _ = ch_repo.insert_batch(&[ch]);
            Ok::<(), legado_core::LegadoError>(())
        })
        .unwrap();

        let err = get_chapter_content_full(book_url, 0).unwrap_err();
        assert!(err.to_string().contains("书源"));
    }

    /// 网络测试：在线书籍完整链路（需要真实网络，CI 中忽略）
    #[test]
    #[ignore = "requires network access"]
    fn test_get_chapter_content_full_online() {
        let source_url = "https://full-online-test.example.com";
        let book_url = "https://full-online-test.example.com/book/1";
        let _db_guard = setup_db_and_source(source_url);

        // 插入书籍（origin = source_url）和章节
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                ..legado_core::models::Book::default()
            };
            let _ = book_repo.insert(&book);

            let ch_repo = BookChapterRepository::new(db.connection());
            let ch = legado_core::models::BookChapter {
                url: format!("{book_url}/chapter/0"),
                title: "第一章".to_string(),
                is_volume: false,
                base_url: book_url.to_string(),
                book_url: book_url.to_string(),
                index: 0,
                is_vip: false,
                is_pay: false,
                resource_url: None,
                tag: None,
                word_count: None,
                start: None,
                end: None,
                start_fragment_id: None,
                end_fragment_id: None,
                variable: None,
                img_url: None,
            };
            let _ = ch_repo.insert_batch(&[ch]);
            Ok::<(), legado_core::LegadoError>(())
        })
        .unwrap();

        let content = get_chapter_content_full(book_url, 0).unwrap();
        assert!(!content.is_empty());
        // 确保返回的是真实正文，不是 JSON 元数据
        assert!(!content.contains("need_fetch"));
    }

    /// 集成测试：apply_content_processing_raw 不应用替换规则，apply_content_processing 仍应用
    #[test]
    fn test_apply_content_processing_raw_integration() {
        let _db_guard = crate::db_state::ensure_test_db();
        let rule_id = with_database(|db| {
            let repo = ReplaceRuleRepository::new(db.connection());
            repo.insert(&ReplaceRule {
                name: "reader_raw_测试规则_unique".to_string(),
                pattern: "敏感词".to_string(),
                replacement: String::new(),
                is_regex: false,
                is_enabled: true,
                ..ReplaceRule::default()
            })
        })
        .unwrap();

        let raw_input = "正文含敏感词结尾";
        // 净化变体（阅读器/导出）：替换规则生效
        let purified = apply_content_processing("https://raw-test.example.com", raw_input, "");
        assert_eq!(purified, "正文含结尾");
        // raw 变体（内容搜索语义）：替换规则不生效，原词保留（无章节上下文传 None）
        let raw = apply_content_processing_raw("https://raw-test.example.com", raw_input, "", None);
        assert_eq!(raw, raw_input);

        with_database(|db| {
            let repo = ReplaceRuleRepository::new(db.connection());
            repo.delete(rule_id)?;
            Ok(())
        })
        .unwrap();
    }

    // ─── [批7a] 替换净化开关 / 重新分段接线测试 ─────────────────────────────

    /// 配置隔离守卫：保存 `config:<key>` 原值，Drop 时还原（原本不存在则删除）
    ///
    /// 共享测试库的 caches 配置会跨用例存活，批7a 用例读写全局开关时
    /// 必须显式隔离，避免污染其他用例（守卫在 DB 串行锁仍持有时 Drop）。
    struct ConfigValueGuard {
        full_key: String,
        previous: Option<String>,
    }

    impl ConfigValueGuard {
        /// 捕获当前值但不修改（配合测试内多次 set_config 使用）
        fn capture(key: &str) -> Self {
            let full_key = format!("{}{}", crate::api::config_api::CONFIG_PREFIX, key);
            let previous =
                with_database(|db| CacheRepository::new(db.connection()).get(&full_key)).unwrap();
            Self { full_key, previous }
        }

        /// 捕获当前值并写入测试值
        fn set(key: &str, value: &str) -> Self {
            let guard = Self::capture(key);
            crate::api::config_api::set_config(key, value).expect("写入测试配置失败");
            guard
        }
    }

    impl Drop for ConfigValueGuard {
        fn drop(&mut self) {
            let _ = with_database(|db| {
                let repo = CacheRepository::new(db.connection());
                match &self.previous {
                    Some(value) => repo.put(&self.full_key, value, 0)?,
                    None => repo.delete(&self.full_key)?,
                }
                Ok(())
            });
        }
    }

    /// 插入批7a 测试书行（调用方负责唯一 bookUrl 与收尾删除）
    fn insert_batch7a_book(book: Book) {
        with_database(|db| BookRepository::new(db.connection()).insert(&book))
            .expect("批7a 测试书行写入失败");
    }

    /// 删除批7a 测试书行
    fn delete_batch7a_book(book_url: &str) {
        let _ = with_database(|db| BookRepository::new(db.connection()).delete_by_url(book_url));
    }

    /// 插入唯一命名的启用替换规则（返回 id，调用方负责删除）
    fn insert_batch7a_rule(name: &str, pattern: &str, replacement: &str) -> i64 {
        with_database(|db| {
            ReplaceRuleRepository::new(db.connection()).insert(&ReplaceRule {
                name: name.to_string(),
                pattern: pattern.to_string(),
                replacement: replacement.to_string(),
                is_regex: false,
                is_enabled: true,
                ..ReplaceRule::default()
            })
        })
        .expect("批7a 测试规则写入失败")
    }

    /// 删除批7a 测试规则
    fn delete_batch7a_rule(rule_id: i64) {
        let _ = with_database(|db| ReplaceRuleRepository::new(db.connection()).delete(rule_id));
    }

    /// `replaceEnableDefault` 解析口径：缺省/非法 → true；"false"/"0"（忽略
    /// 大小写与首尾空白）→ false
    #[test]
    fn test_replace_enable_default_parsing() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _cfg = ConfigValueGuard::capture(REPLACE_ENABLE_DEFAULT_CONFIG_KEY);

        for raw in ["false", "FALSE", "  False  ", "0", " 0 "] {
            crate::api::config_api::set_config(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, raw).unwrap();
            assert!(!get_replace_enable_default(), "raw={raw:?} 应解析为 false");
        }
        for raw in ["true", "TRUE", "1", "", "anything", "2"] {
            crate::api::config_api::set_config(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, raw).unwrap();
            assert!(get_replace_enable_default(), "raw={raw:?} 应回落 true");
        }
    }

    /// a) `useReplaceRule=false`：命中的替换规则不生效，但繁简转换（t2s）仍生效
    ///
    /// 上游管线顺序（ContentProcessor.kt:182-211）：简繁转换在替换规则之前，
    /// 因此用繁体正文验证「转换已发生、规则未执行」两个独立事实。
    #[test]
    fn test_use_replace_rule_false_keeps_chinese_convert() {
        let _db_guard = crate::db_state::ensure_test_db();
        // 全局默认置 true，证明关闭来自书级显式 false（而非全局默认）
        let _replace_default = ConfigValueGuard::set(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, "true");
        let _chinese = ConfigValueGuard::set(CHINESE_CONVERT_CONFIG_KEY, "1");
        let book_url = "https://batch7a.example.com/use-replace-false";
        insert_batch7a_book(Book {
            book_url: book_url.to_string(),
            origin: "https://batch7a.example.com".to_string(),
            name: "批7a关替换".to_string(),
            read_config: Some(legado_core::models::ReadConfig {
                use_replace_rule: Some(false),
                ..Default::default()
            }),
            ..Book::default()
        });
        let rule_id = insert_batch7a_rule("批7a_use_replace_false_unique", "测试", "");

        // 规则模式为简体「测试」；t2s 先把繁体转成简体，若规则生效则「测试」会被删
        let got = apply_content_processing(book_url, "繁體測試正文", "");
        assert_eq!(
            got, "繁体测试正文",
            "useReplaceRule=false 时替换规则不得生效"
        );
        assert_ne!(got, "繁體測試正文", "简繁转换不应被替换开关关闭");

        delete_batch7a_rule(rule_id);
        delete_batch7a_book(book_url);
    }

    /// b) 图片类书 `useReplaceRule=null` → 规则默认不生效；显式 `Some(true)` → 生效
    ///
    /// 同批附带本地 epub 默认关闭回归（上游 Book.kt:232-242 与 Kotlin
    /// `Book.isEpub` 同为「图片类别 / 本地 epub 默认关净化」）。
    #[test]
    fn test_image_book_replace_default_off_explicit_on() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _replace_default = ConfigValueGuard::set(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, "true");
        let rule_id = insert_batch7a_rule("批7a_image_gate_unique", "广告", "");
        let content = "图片广告正文";

        // 图片类书（位域 IMAGE_BIT），未显式设置 → 默认关闭替换
        let image_null_url = "books/batch7a_image_null.cbz";
        insert_batch7a_book(Book {
            book_url: image_null_url.to_string(),
            origin: book_type::LOCAL_TAG.to_string(),
            name: "批7a图片书默认".to_string(),
            book_type: book_type::LOCAL | book_type::IMAGE_BIT,
            ..Book::default()
        });
        assert_eq!(
            apply_content_processing(image_null_url, content, ""),
            content,
            "图片类书 useReplaceRule=null 时替换规则必须默认关闭"
        );

        // 同一图片类书显式 Some(true) → 显式覆盖优先，规则生效
        let image_true_url = "books/batch7a_image_true.cbz";
        insert_batch7a_book(Book {
            book_url: image_true_url.to_string(),
            origin: book_type::LOCAL_TAG.to_string(),
            name: "批7a图片书显式".to_string(),
            book_type: book_type::LOCAL | book_type::IMAGE_BIT,
            read_config: Some(legado_core::models::ReadConfig {
                use_replace_rule: Some(true),
                ..Default::default()
            }),
            ..Book::default()
        });
        assert_eq!(
            apply_content_processing(image_true_url, content, ""),
            "图片正文",
            "图片类书显式 useReplaceRule=true 时必须生效"
        );

        // 本地 epub（无 IMAGE_BIT）同样默认关闭；判定看实体 originName
        // （bookUrl 不带 .epub 后缀，避免旧的后缀白名单误判路径）
        let epub_url = "books/batch7a_local";
        insert_batch7a_book(Book {
            book_url: epub_url.to_string(),
            origin: book_type::LOCAL_TAG.to_string(),
            origin_name: "batch7a_local.epub".to_string(),
            name: "批7a本地epub".to_string(),
            book_type: book_type::LOCAL,
            ..Book::default()
        });
        assert_eq!(
            apply_content_processing(epub_url, content, ""),
            content,
            "本地 epub 默认关闭替换规则"
        );

        delete_batch7a_rule(rule_id);
        delete_batch7a_book(image_null_url);
        delete_batch7a_book(image_true_url);
        delete_batch7a_book(epub_url);
    }

    /// [P2-3] 本地 epub 判定必须看书籍实体（本地类型 + originName），
    /// 不能只看 `bookUrl` 后缀：在线 `.epub` URL 不应按本地 epub 关闭。
    #[test]
    fn test_use_replace_rule_epub_entity_detection() {
        let _db_guard = crate::db_state::ensure_test_db();
        let _replace_default = ConfigValueGuard::set(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, "true");

        // 在线书：bookUrl 以 .epub 结尾，但 originName 不是 → 不关闭
        let online = Book {
            book_url: "https://online.example.com/book.epub".to_string(),
            origin: "https://online.example.com".to_string(),
            origin_name: "book.txt".to_string(),
            book_type: book_type::TEXT,
            ..Book::default()
        };
        assert!(
            use_replace_rule_for_book(Some(&online)),
            "在线书 bookUrl 的 .epub 后缀不得误判为本地 epub"
        );

        // 本地书：originName="x.epub"，bookUrl 不带后缀 → 关闭
        let local_epub = Book {
            book_url: "books/x".to_string(),
            origin: book_type::LOCAL_TAG.to_string(),
            origin_name: "x.epub".to_string(),
            book_type: book_type::LOCAL,
            ..Book::default()
        };
        assert!(
            !use_replace_rule_for_book(Some(&local_epub)),
            "本地书 originName 为 .epub 时应默认关闭替换"
        );

        // 在线书 originName 为 .epub 但非本地类型 → 仍按全局默认（开启）
        let online_named_epub = Book {
            book_url: "https://online.example.com/book".to_string(),
            origin: "https://online.example.com".to_string(),
            origin_name: "book.epub".to_string(),
            book_type: book_type::TEXT,
            ..Book::default()
        };
        assert!(use_replace_rule_for_book(Some(&online_named_epub)));
    }

    /// c) 普通文字书 `useReplaceRule=null`：跟随 `replaceEnableDefault`
    #[test]
    fn test_text_book_replace_follows_replace_enable_default() {
        let _db_guard = crate::db_state::ensure_test_db();
        let rule_id = insert_batch7a_rule("批7a_text_default_unique", "广告", "");
        let book_url = "https://batch7a.example.com/text-default";
        insert_batch7a_book(Book {
            book_url: book_url.to_string(),
            origin: "https://batch7a.example.com".to_string(),
            name: "批7a文字书".to_string(),
            book_type: book_type::TEXT,
            ..Book::default()
        });
        let content = "普通广告正文";

        {
            let _cfg = ConfigValueGuard::set(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, "false");
            assert_eq!(
                apply_content_processing(book_url, content, ""),
                content,
                "replaceEnableDefault=false 时普通文字书默认关闭替换"
            );
        }
        {
            let _cfg = ConfigValueGuard::set(REPLACE_ENABLE_DEFAULT_CONFIG_KEY, "true");
            assert_eq!(
                apply_content_processing(book_url, content, ""),
                "普通正文",
                "replaceEnableDefault=true 时普通文字书默认启用替换"
            );
        }

        delete_batch7a_rule(rule_id);
        delete_batch7a_book(book_url);
    }

    /// d) `readConfig.reSegment=true` 时正文重新分段生效（与 false 输出不同）
    ///
    /// 构造稳定断言：两行各 6 字的短段落，`re_segment` 会把第二段
    /// （<10 字、非引号开头）并入第一段并以单段输出（content_help.rs
    /// `merge_short_paragraphs`）——关闭时保留原始换行。
    #[test]
    fn test_re_segment_applies_when_book_config_enabled() {
        let _db_guard = crate::db_state::ensure_test_db();
        let raw = "第一段内容。\n第二段内容。";
        let expected_segmented = "第一段内容。第二段内容。";

        // 关闭（默认）：保持原始排版
        let off_url = "https://batch7a.example.com/re-segment-off";
        insert_batch7a_book(Book {
            book_url: off_url.to_string(),
            origin: "https://batch7a.example.com".to_string(),
            name: "批7a不重分段".to_string(),
            read_config: Some(legado_core::models::ReadConfig {
                re_segment: false,
                use_replace_rule: Some(false),
                ..Default::default()
            }),
            ..Book::default()
        });
        assert_eq!(apply_content_processing(off_url, raw, ""), raw);

        // 开启：重新分段；替换规则仍关闭（证明 reSegment 独立于替换开关）
        let on_url = "https://batch7a.example.com/re-segment-on";
        insert_batch7a_book(Book {
            book_url: on_url.to_string(),
            origin: "https://batch7a.example.com".to_string(),
            name: "批7a重分段".to_string(),
            read_config: Some(legado_core::models::ReadConfig {
                re_segment: true,
                use_replace_rule: Some(false),
                ..Default::default()
            }),
            ..Book::default()
        });
        let got = apply_content_processing(on_url, raw, "");
        assert_eq!(got, expected_segmented);
        assert_ne!(got, raw, "重新分段后的输出必须与关闭时不同");

        delete_batch7a_book(off_url);
        delete_batch7a_book(on_url);
    }

    /// e) 搜索 raw 路径即使书 `reSegment=true` 也不重分段
    #[test]
    fn test_raw_search_path_does_not_re_segment() {
        let _db_guard = crate::db_state::ensure_test_db();
        let raw = "第一段内容。\n第二段内容。";
        let book_url = "https://batch7a.example.com/re-segment-raw";
        insert_batch7a_book(Book {
            book_url: book_url.to_string(),
            origin: "https://batch7a.example.com".to_string(),
            name: "批7a搜索原文".to_string(),
            read_config: Some(legado_core::models::ReadConfig {
                re_segment: true,
                use_replace_rule: Some(true),
                ..Default::default()
            }),
            ..Book::default()
        });

        // raw（内容搜索）：保留原始排版，不重分段
        assert_eq!(apply_content_processing_raw(book_url, raw, "", None), raw);
        // 对照：同一本书阅读路径会重分段，证明 reSegment 配置本身生效
        assert_eq!(
            apply_content_processing(book_url, raw, ""),
            "第一段内容。第二段内容。"
        );

        delete_batch7a_book(book_url);
    }

    // ─── toggle_same_title_removed 测试（Task #51，契约 §2.9.10） ─────────────

    /// 插入测试书籍 + 章节（toggle 开关测试专用）
    ///
    /// 书籍已存在时跳过插入：INSERT OR REPLACE 会先删旧行再插新行，
    /// 触发 chapters 外键级联删除，把已有章节一并清掉。
    fn insert_book_and_chapter(book_url: &str, chapter_index: i32, title: &str) {
        with_database(|db| {
            let book_repo = BookRepository::new(db.connection());
            if book_repo.find_by_url(book_url)?.is_none() {
                let book = legado_core::models::Book {
                    book_url: book_url.to_string(),
                    ..legado_core::models::Book::default()
                };
                book_repo.insert(&book)?;
            }

            let ch_repo = BookChapterRepository::new(db.connection());
            let ch = legado_core::models::BookChapter {
                url: format!("{book_url}/chapter/{chapter_index}"),
                title: title.to_string(),
                is_volume: false,
                base_url: book_url.to_string(),
                book_url: book_url.to_string(),
                index: chapter_index,
                is_vip: false,
                is_pay: false,
                resource_url: None,
                tag: None,
                word_count: None,
                start: None,
                end: None,
                start_fragment_id: None,
                end_fragment_id: None,
                variable: None,
                img_url: None,
            };
            ch_repo.insert_batch(&[ch])?;
            Ok::<(), legado_core::LegadoError>(())
        })
        .unwrap();
    }

    /// 清理测试书籍章节与开关记录
    fn cleanup_toggle_test_data(book_url: &str) {
        with_database(|db| {
            use rusqlite::params;
            let conn = db.connection();
            let to_db_err = |e| LegadoError::Database(format!("清理测试数据失败: {e}"));
            conn.execute("DELETE FROM chapters WHERE bookUrl = ?1", params![book_url])
                .map_err(to_db_err)?;
            conn.execute("DELETE FROM books WHERE bookUrl = ?1", params![book_url])
                .map_err(to_db_err)?;
            conn.execute(
                "DELETE FROM caches WHERE key LIKE ?1",
                params![format!("sameTitleRemoved:{book_url}:%")],
            )
            .map_err(to_db_err)?;
            Ok(())
        })
        .unwrap();
    }

    /// Task #51：错误码——书籍不存在 → Internal；章节不存在 → Db
    #[test]
    fn test_toggle_same_title_removed_errors() {
        let _db_guard = crate::db_state::ensure_test_db();

        // 书籍不存在 → Internal 错误
        let err = toggle_same_title_removed("https://no-such-book.example.com", 0, false)
            .expect_err("书籍不存在应报错");
        assert!(
            matches!(err, LegadoError::Internal(_)),
            "书籍不存在应为 Internal 错误，实际: {err:?}"
        );

        // 书籍存在但章节不存在 → Db 错误
        let book_url = "https://toggle-err-test.example.com/book/1";
        insert_book_and_chapter(book_url, 0, "第一章 测试");
        let err = toggle_same_title_removed(book_url, 99, false).expect_err("章节不存在应报错");
        assert!(
            matches!(err, LegadoError::Database(_)),
            "章节不存在应为 Db 错误，实际: {err:?}"
        );
        cleanup_toggle_test_data(book_url);
    }

    /// Task #51：章级开关接通正文净化链路（默认去除 / opt-out 保留 / 恢复默认）
    #[test]
    fn test_toggle_same_title_removed_content_pipeline() {
        let _db_guard = crate::db_state::ensure_test_db();

        let book_url = "https://toggle-pipeline-test.example.com/book/1";
        let title = "第一章 测试";
        insert_book_and_chapter(book_url, 0, title);
        // 正文开头与章节标题重复（去重复标题的目标场景）
        let raw = "第一章 测试\n正文内容。";

        // 全局默认：去除重复标题
        let result = apply_content_processing_chapter(book_url, raw, title, 0);
        assert_eq!(result, "正文内容。");

        // opt-out（enable=false）：保留原始标题
        toggle_same_title_removed(book_url, 0, false).unwrap();
        let result = apply_content_processing_chapter(book_url, raw, title, 0);
        assert_eq!(result, "第一章 测试\n正文内容。");

        // 其他章不受影响（章级隔离，仍走全局默认）
        insert_book_and_chapter(book_url, 1, "第二章 测试");
        let raw2 = "第二章 测试\n第二正文。";
        let result = apply_content_processing_chapter(book_url, raw2, "第二章 测试", 1);
        assert_eq!(result, "第二正文。");

        // 恢复默认（enable=true）：重新去除重复标题
        toggle_same_title_removed(book_url, 0, true).unwrap();
        let result = apply_content_processing_chapter(book_url, raw, title, 0);
        assert_eq!(result, "正文内容。");

        // 幂等：重复切换不报错
        toggle_same_title_removed(book_url, 0, true).unwrap();
        toggle_same_title_removed(book_url, 0, false).unwrap();
        toggle_same_title_removed(book_url, 0, false).unwrap();

        cleanup_toggle_test_data(book_url);
    }
    // ─── P1-1/P2-1 目录字段族透传 + 卷章落库测试 ────────────────────────────

    /// P1-1/P2-1：refresh_toc 落库断言——卷章/付费/附加信息/字数写入
    /// chapters 表（此前 is_volume 恒 false、tag 恒 None）
    #[test]
    fn test_refresh_toc_persists_volume_pay_and_tag() {
        use std::sync::{Arc, Mutex};
        let _lock = crate::test_support::lock_global_store();
        let source_url = "https://toc-fields-ffi.test";
        let book_url = "https://toc-fields-ffi.test/book/1";
        let toc_url = "https://toc-fields-ffi.test/toc";
        let _db_guard = setup_db_and_source(source_url);
        with_database(|db| {
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "字段族书源".to_string(),
                name: "字段族书".to_string(),
                toc_url: toc_url.to_string(),
                ..legado_core::models::Book::default()
            })?;
            Ok(())
        })
        .expect("初始书籍写入失败");

        let fetcher = ScriptedTocFetcher {
            chapters_by_url: vec![(
                toc_url.to_string(),
                vec![
                    WebChapter {
                        index: 0,
                        title: "第二卷".to_string(),
                        url: format!("{toc_url}/v/2"),
                        is_vip: false,
                        is_volume: true,
                        is_pay: false,
                        tag: Some("2024-01-01".to_string()),
                        variable: None,
                        word_count: None,
                    },
                    WebChapter {
                        index: 1,
                        title: "第一章".to_string(),
                        url: format!("{toc_url}/c/1"),
                        is_vip: true,
                        is_volume: false,
                        is_pay: true,
                        tag: Some("2024-01-02 12:00".to_string()),
                        variable: None,
                        word_count: Some("13.5万字".to_string()),
                    },
                ],
            )],
            requested: Arc::new(Mutex::new(Vec::new())),
            seed_progress_book_url: None,
        };
        let engine = WebBookEngine::new(fetcher);
        let resp = refresh_toc_with_fetcher(book_url, source_url, &engine).expect("目录刷新应成功");
        assert_eq!(resp.total, 2);

        with_database(|db| {
            let rows = BookChapterRepository::new(db.connection()).find_by_book_url(book_url)?;
            assert_eq!(rows.len(), 2);
            let (v, c) = (&rows[0], &rows[1]);
            assert!(v.is_volume, "卷章标记应落库（修复前恒 false）");
            assert_eq!(
                v.tag.as_deref(),
                Some("2024-01-01"),
                "卷章附加信息应落库（修复前恒 None）"
            );
            assert!(c.is_pay, "付费标记应落库（修复前恒 false）");
            assert!(c.is_vip);
            assert_eq!(c.tag.as_deref(), Some("2024-01-02 12:00"));
            assert_eq!(c.word_count.as_deref(), Some("13.5万字"));
            Ok(())
        })
        .expect("落库断言失败");
    }

    // ─── P1-2/P1-1 正文链标题规则 + 卷章豁免端到端测试 ───────────────────────

    /// 回环静态 HTML 服务器（正文链 fixture）
    fn spawn_chapter_html_server(html: String) -> u16 {
        use std::io::{Read, Write};
        use std::net::TcpListener;
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind 回环服务器");
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut head: Vec<u8> = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    match stream.read(&mut byte) {
                        Ok(1) => head.push(byte[0]),
                        _ => break,
                    }
                    if head.len() > 16 * 1024 {
                        break;
                    }
                }
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    html.len()
                );
                let _ = stream.write_all(resp.as_bytes());
                let _ = stream.write_all(html.as_bytes());
                let _ = stream.flush();
            }
        });
        port
    }

    /// 播种「正文规则 + 标题规则」书源与指定章节（章节 URL 指向回环服务器）
    fn seed_title_chain_fixture(
        book_url: &str,
        source_url: &str,
        chapter_url: &str,
        is_volume: bool,
        title: &str,
    ) {
        use legado_core::models::rule::ContentRule;
        with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: source_url.to_string(),
                book_source_name: "标题链测试源".to_string(),
                rule_content: Some(ContentRule {
                    content: Some("class.content@text".to_string()),
                    title: Some("class.title@text".to_string()),
                    ..ContentRule::default()
                }),
                ..BookSource::default()
            })?;
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.to_string(),
                origin: source_url.to_string(),
                origin_name: "标题链测试源".to_string(),
                name: "标题链书".to_string(),
                ..legado_core::models::Book::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                book_url: book_url.to_string(),
                index: 0,
                title: title.to_string(),
                url: chapter_url.to_string(),
                is_volume,
                base_url: chapter_url.to_string(),
                ..BookChapter::default()
            })?;
            Ok(())
        })
        .expect("标题链 fixture 写入失败");
    }

    /// P1-2 端到端：title 规则 + 标题内段评图 → 标题覆盖 chapters.title、
    /// img_url 落 chapters.imgUrl（修复前两列均无写入来源）
    #[test]
    fn test_content_title_rule_overrides_title_and_persists_img_url() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let html = "<html><body>\
                    <div class='title'>第一章 http://img.test/1.jpg</div>\
                    <div class='content'>正文段落</div>\
                    </body></html>"
            .to_string();
        let port = spawn_chapter_html_server(html);
        let source_url = format!("http://127.0.0.1:{port}");
        let book_url = format!("{source_url}/b/1");
        let chapter_url = format!("{source_url}/c/1");
        seed_title_chain_fixture(&book_url, &source_url, &chapter_url, false, "第一章");

        let content = get_chapter_content_full(&book_url, 0).expect("正文获取应成功");
        assert!(content.contains("正文段落"));

        with_database(|db| {
            let row = BookChapterRepository::new(db.connection())
                .find_by_book_url_and_index(&book_url, 0)?
                .expect("章节行应存在");
            assert_eq!(
                row.title.trim(),
                "第一章",
                "标题规则应覆盖 chapters.title（imgRegex group1 余量）"
            );
            assert_eq!(
                row.img_url.as_deref(),
                Some("http://img.test/1.jpg"),
                "标题内段评图应落 chapters.imgUrl"
            );
            Ok(())
        })
        .expect("标题链落库断言失败");
    }

    /// P1-2 无回归：无 title 规则的书源不覆盖标题（存量行为不变）
    #[test]
    fn test_content_without_title_rule_keeps_chapter_title() {
        use legado_core::models::rule::ContentRule;
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        let html = "<html><body><div class='content'>正文段落</div></body></html>".to_string();
        let port = spawn_chapter_html_server(html);
        let source_url = format!("http://127.0.0.1:{port}");
        let book_url = format!("{source_url}/b/2");
        let chapter_url = format!("{source_url}/c/1");
        with_database(|db| {
            BookSourceRepository::new(db.connection()).insert(&BookSource {
                book_source_url: source_url.clone(),
                book_source_name: "无标题规则源".to_string(),
                rule_content: Some(ContentRule {
                    content: Some("class.content@text".to_string()),
                    ..ContentRule::default()
                }),
                ..BookSource::default()
            })?;
            BookRepository::new(db.connection()).insert(&legado_core::models::Book {
                book_url: book_url.clone(),
                origin: source_url.clone(),
                origin_name: "无标题规则源".to_string(),
                name: "无规则书".to_string(),
                ..legado_core::models::Book::default()
            })?;
            BookChapterRepository::new(db.connection()).insert(&BookChapter {
                book_url: book_url.clone(),
                index: 0,
                title: "原标题".to_string(),
                url: chapter_url.clone(),
                base_url: chapter_url.clone(),
                ..BookChapter::default()
            })?;
            Ok(())
        })
        .expect("fixture 写入失败");

        get_chapter_content_full(&book_url, 0).expect("正文获取应成功");
        with_database(|db| {
            let row = BookChapterRepository::new(db.connection())
                .find_by_book_url_and_index(&book_url, 0)?
                .expect("章节行应存在");
            assert_eq!(row.title, "原标题", "无 title 规则不得改写标题");
            assert!(row.img_url.is_none(), "无 title 规则不得写 imgUrl");
            Ok(())
        })
        .expect("无回归断言失败");
    }

    /// P1-1 端到端：卷章空正文豁免「章节正文为空」错误（修复前正文链
    /// 构造 WebChapter 硬编码 is_volume:false，卷章抓空正文直接报错）
    #[test]
    fn test_volume_chapter_empty_content_is_exempt() {
        let _lock = crate::test_support::lock_global_store();
        let _db_guard = crate::db_state::ensure_test_db();
        // 页面 content 节点为空元素 → 解析正文为空（规则命中但文本空）
        let html = "<html><body><div class='content'></div></body></html>".to_string();
        let port = spawn_chapter_html_server(html);
        let source_url = format!("http://127.0.0.1:{port}");
        let book_url = format!("{source_url}/b/3");
        let chapter_url = format!("{source_url}/c/1");
        seed_title_chain_fixture(&book_url, &source_url, &chapter_url, true, "第一卷");

        // 卷章：空正文不报错（豁免，正文为空串返回）
        let content = get_chapter_content_full(&book_url, 0).expect("卷章空正文应豁免");
        assert!(
            content.trim().is_empty(),
            "空 content 节点解析结果应为空正文，实际: {content}"
        );

        // 对照：普通章同页空正文仍报「章节正文为空」
        let book_url2 = format!("{source_url}/b/4");
        seed_title_chain_fixture(&book_url2, &source_url, &chapter_url, false, "第一章");
        let err = get_chapter_content_full(&book_url2, 0).expect_err("普通章空正文应报错");
        assert!(
            err.to_string().contains("正文为空"),
            "普通章空正文错误信息，实际: {err}"
        );
    }
}
