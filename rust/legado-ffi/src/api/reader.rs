//! 阅读 API
//!
//! 提供章节列表获取与章节内容读取能力，支持在线书源与本地书籍两种模式。
//! 在线书籍支持通过网络刷新书籍目录（refresh_toc）和抓取正文（fetch_chapter_content）。

use serde::{Deserialize, Serialize};

use legado_core::cache_book::CachedChapter;
use legado_core::content_processor::{ContentProcessor, ProcessorConfig, ReplaceRuleEntry};
use legado_core::models::{BookChapter, ReplaceRule};
use legado_core::web_book::WebChapter;
use legado_core::{LegadoError, LegadoResult};
use legado_db::repository::Repository;
use legado_db::{
    BookChapterRepository, BookRepository, BookSourceRepository, CacheBookRepository,
    CacheRepository, ReplaceRuleRepository,
};

use crate::db_state::with_database;
use crate::runtime;

// ─── 简繁转换配置（对齐 Kotlin AppConfig.chineseConverterType） ──────────────

/// 配置键：繁简转换类型（与 Kotlin `PreferKey.chineseConverterType` 同名，
/// 备份恢复时可跨端互通）
const CHINESE_CONVERT_CONFIG_KEY: &str = "chineseConverterType";

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
    let _ = crate::api::config_api::set_config(
        CHINESE_CONVERT_CONFIG_KEY,
        &normalized.to_string(),
    );
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
    let value = with_database(|db| {
        let repo = CacheRepository::new(db.connection());
        repo.get(&same_title_removed_key(book_url, chapter_index))
    })
    .ok()
    .flatten();
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
}

/// 获取指定书籍的章节列表
///
/// 优先从数据库读取；若数据库无记录且为本地书籍，则从文件解析章节并入库（懒加载）。
pub fn get_chapters(book_url: &str) -> LegadoResult<ChapterListResponse> {
    // 1. 尝试从数据库读取已有章节
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;

    if !chapters.is_empty() {
        let mut chapters = chapters;
        apply_title_convert(&mut chapters);
        let total = chapters.len() as i32;
        return Ok(ChapterListResponse { total, chapters });
    }

    // 2. 数据库无章节：如果是本地书籍，从文件解析并入库
    if is_local_book(book_url) {
        let chapter_infos = legado_book::LocalBook::get_chapters(book_url)?;
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

        // 存入数据库供后续访问
        if !book_chapters.is_empty() {
            with_database(|db| {
                let repo = BookChapterRepository::new(db.connection());
                repo.insert_batch(&book_chapters)?;
                Ok(())
            })?;
        }

        // 显示层标题繁简转换（不回写数据库）
        apply_title_convert(&mut book_chapters);

        let total = book_chapters.len() as i32;
        return Ok(ChapterListResponse {
            total,
            chapters: book_chapters,
        });
    }

    // 3. 在线书籍无章节记录，返回空
    Ok(ChapterListResponse {
        total: 0,
        chapters: vec![],
    })
}

/// 获取章节正文内容
///
/// 对于本地书籍（bookUrl 为文件路径），使用 legado-book 解析器读取。
/// 对于在线书籍，需配合书源规则通过网络获取（此处返回数据库缓存或空）。
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
        let content = legado_book::LocalBook::get_chapter_content(
            book_url,
            &chapter_to_local_info(&chapter),
        )?;
        // 读取时净化：DB/文件保留原始正文，返回前应用内容净化
        Ok(apply_content_processing_inner(
            book_url,
            &content,
            &chapter.title,
            apply_replace_rules,
            Some(chapter_index),
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

/// 判断是否为本地书籍
pub fn is_local_book(book_url: &str) -> bool {
    let lower = book_url.to_lowercase();
    lower.ends_with(".epub")
        || lower.ends_with(".txt")
        || lower.ends_with(".text")
        || lower.ends_with(".mobi")
        || lower.ends_with(".azw")
        || lower.ends_with(".azw3")
        || lower.ends_with(".pdf")
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

/// 从网络刷新书籍目录
///
/// 流程：
/// 1. 根据 `source_url` 从数据库查找书源配置
/// 2. 使用 WebBookEngine 从网络获取章节列表
/// 3. 将 WebChapter 转换为 BookChapter 并存入数据库
/// 4. 返回 JSON 格式的章节列表
pub fn refresh_toc(book_url: &str, source_url: &str) -> LegadoResult<ChapterListResponse> {
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
    // 目录更新前钩子（对齐 WebBook.getChapterListAwait(runPerJs=true) → runPreUpdateJs）
    // 须在计算 fetch_url 之前执行，以便 reGetBook/refreshTocUrl/手写改 book 生效
    let mut working_book = existing_book.clone();
    if let Some(ref mut book) = working_book {
        if let Err(e) = crate::api::pre_update::run_pre_update_js(&source, book) {
            eprintln!("[refresh_toc] preUpdateJs: {e}");
        } else {
            // 持久化 preUpdateJs / 钩子对 bookUrl·tocUrl·variable 等的改写
            let _ = with_database(|db| {
                legado_db::BookRepository::new(db.connection()).update(book)
            });
        }
    }

    let fetch_url = working_book
        .as_ref()
        .map(|b| {
            let toc = b.toc_url.trim();
            if !toc.is_empty() {
                toc.to_string()
            } else if !b.book_url.trim().is_empty() {
                b.book_url.clone()
            } else {
                book_url.to_string()
            }
        })
        .unwrap_or_else(|| book_url.to_string());

    // 2. 使用 WebBookEngine 从网络获取章节列表
    let engine = super::web_book::build_engine();
    let web_chapters: Vec<WebChapter> =
        runtime::block_on(async { engine.get_chapters(&source, &fetch_url).await })?;

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
            });
        }
        return Err(LegadoError::Parser(
            "刷新目录失败：未从书源解析到任何章节（书源可能失效，请尝试换源）".into(),
        ));
    }

    // 3. 转换为 BookChapter 并存入数据库
    let book_chapters: Vec<BookChapter> = web_chapters
        .iter()
        .map(|wc| BookChapter {
            url: wc.url.clone(),
            title: wc.title.clone(),
            is_volume: false,
            base_url: book_url.to_string(),
            book_url: book_url.to_string(),
            index: wc.index,
            is_vip: wc.is_vip,
            is_pay: false,
            resource_url: None,
            tag: None,
            word_count: None,
            start: None,
            end: None,
            start_fragment_id: None,
            end_fragment_id: None,
            variable: wc.variable.clone(),
            img_url: None,
        })
        .collect();

    // 4. 确保书籍记录存在（满足 chapters 表外键约束），然后先删除旧章节，再批量插入新章节
    // [Task #66 加固] 占位落库须带书源信息（origin/originName）：否则 origin 取默认
    // loc_book，阅读器随后按 origin 找书源取正文会报「书源不存在: loc_book」
    // （搜索→目录页→点章节进入阅读的路径，此时 Flutter 尚未执行带 origin 的
    // addBook）。既有记录 origin 仍为默认值时同样补齐（加法式，不覆盖已有真实书源）。
    with_database(|db| {
        let book_repo = legado_db::BookRepository::new(db.connection());
        match book_repo.find_by_url(book_url)? {
            None => {
                // Task#125：占位落库须打 NOT_SHELF，对齐原版 readBook 临时书 /
                // 书架 list_books 过滤；否则「仅浏览/拉目录」会污染书架。
                let book = legado_core::models::Book {
                    book_url: book_url.to_string(),
                    origin: source_url.to_string(),
                    origin_name: source.book_source_name.clone(),
                    book_type: legado_core::models::book::book_type::NOT_SHELF,
                    ..legado_core::models::Book::default()
                };
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
                book_repo.update(&existing)?;
            }
            _ => {}
        }
        let repo = BookChapterRepository::new(db.connection());
        repo.delete_by_book_url(book_url)?;
        repo.insert_batch(&book_chapters)?;
        Ok(())
    })?;

    // 显示层标题繁简转换（入库的是原始标题，仅转换返回副本）
    let mut book_chapters = book_chapters;
    apply_title_convert(&mut book_chapters);

    let total = book_chapters.len() as i32;
    Ok(ChapterListResponse {
        total,
        chapters: book_chapters,
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
    let (chapter_index, chapter_title, chapter_variable) =
        get_chapter_index_title_variable(book_url, chapter_url)?;
    fetch_chapter_content_inner(
        book_url,
        chapter_url,
        source_url,
        chapter_index,
        &chapter_title,
        chapter_variable.as_deref(),
    )
}

/// 章节正文抓取核心逻辑（不含 get_chapter_index_and_title 查询）
///
/// 由 [`fetch_chapter_content`] 和 [`get_chapter_content_full`] 共用：
/// - `fetch_chapter_content` 先查询章节序号/标题再调用本函数
/// - `get_chapter_content_full` 已持有章节信息，直接调用本函数避免冗余查询
fn fetch_chapter_content_inner(
    book_url: &str,
    chapter_url: &str,
    source_url: &str,
    chapter_index: i32,
    chapter_title: &str,
    chapter_variable: Option<&str>,
) -> LegadoResult<String> {
    // 1. 检查 DB 缓存
    // Task #16 P0：按 (book_url, chapter_url) 复合键查找，避免不同书籍共用
    // 相同 chapter_url 时命中他书缓存（正文张冠李戴）。
    let cached = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.get_by_book_and_chapter_url(book_url, chapter_url)
    })?;

    if let Some(cached_chapter) = cached {
        // 缓存存储原始正文，返回前应用净化（避免规则变更后缓存陈旧）
        let processed = apply_content_processing_chapter(
            book_url,
            &cached_chapter.content,
            &cached_chapter.chapter_title,
            chapter_index,
        );
        return Ok(processed);
    }

    // 2. 缓存未命中，从网络获取
    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    let web_chapter = WebChapter {
        index: chapter_index,
        title: chapter_title.to_string(),
        url: chapter_url.to_string(),
        is_vip: false,
        is_volume: false,
        variable: chapter_variable.map(|s| s.to_string()),
    };

    let engine = super::web_book::build_engine();
    let content = runtime::block_on(async { engine.get_content(&source, &web_chapter).await })?;

    // 3. 抓取成功后写入 DB 缓存（对齐原版 BookContent.analyzeContent
    //    L207-209 `needSave → BookHelp.saveContent` 的「获取成功即写」时机）。
    //    写失败仅告警不传播——缓存写入失败不得导致阅读获取失败。
    save_chapter_cache(book_url, chapter_index, chapter_title, chapter_url, &content);

    // 缓存写入原始正文，返回净化后的正文（透传真实章节标题，使去重复标题生效）
    Ok(apply_content_processing_chapter(
        book_url,
        &content,
        chapter_title,
        chapter_index,
    ))
}

/// 阅读获取（非缓存命中）成功后把正文写入 cached_chapters
///
/// 对齐 Android 原版「阅读即缓存」语义：正文成功解析后按
/// (book_url, chapter_url) 复合键立即写入（含 chapter_index 等字段），
/// 目录页云图标据此变为已缓存态。写失败仅告警不传播——原版
/// saveContent 为异步 fire-and-forget，缓存写失败不得使阅读主流程失败。
fn save_chapter_cache(
    book_url: &str,
    chapter_index: i32,
    chapter_title: &str,
    chapter_url: &str,
    content: &str,
) {
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
    }
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
        let content = legado_book::LocalBook::get_chapter_content(
            book_url,
            &chapter_to_local_info(&chapter),
        )?;
        return Ok(apply_content_processing_chapter(
            book_url,
            &content,
            &chapter.title,
            chapter.index,
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
    fetch_chapter_content_inner(
        book_url,
        &chapter.url,
        &source_url,
        chapter.index,
        &chapter.title,
        chapter.variable.as_deref(),
    )
}

/// 对原始正文应用「替换规则 + 内容净化」，返回净化后的正文（读取时净化）
///
/// 与 Android 原版 ContentProcessor 对等：DB 缓存继续存储原始正文，
/// 在正文返回给上层前应用净化，从而避免「规则变更后缓存陈旧」的问题。
///
/// 处理范围（与 Android 默认行为一致）：
/// - 去除重复标题（正文开头与章节标题相同的文本）
/// - 应用启用的替换规则（按 scope 过滤后）
///
/// 不在此处做段落重排/简繁转换/缩进/空行修剪，以免改变原始正文排版。
pub fn apply_content_processing(book_url: &str, raw_content: &str, chapter_title: &str) -> String {
    apply_content_processing_inner(book_url, raw_content, chapter_title, true, None)
}

/// 对原始正文应用净化（带章级「删除重复标题」开关，Task #51）
///
/// 阅读器正文读取/导出链路调用：按章读取开关（全局默认去除，
/// 章级 opt-out 时保留原始标题），其余行为与 [`apply_content_processing`] 一致。
pub fn apply_content_processing_chapter(
    book_url: &str,
    raw_content: &str,
    chapter_title: &str,
    chapter_index: i32,
) -> String {
    apply_content_processing_inner(book_url, raw_content, chapter_title, true, Some(chapter_index))
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
    apply_content_processing_inner(book_url, raw_content, chapter_title, false, chapter_index)
}

/// apply_content_processing 的内部实现：`apply_replace_rules` 控制是否应用替换规则；
/// `chapter_index` 非 None 时按章读取「删除重复标题」开关（缺省全局默认去除）
fn apply_content_processing_inner(
    book_url: &str,
    raw_content: &str,
    chapter_title: &str,
    apply_replace_rules: bool,
    chapter_index: Option<i32>,
) -> String {
    // 1. 加载启用的替换规则 + 查询书籍名称（用于 scope 过滤）
    let loaded = with_database(|db| {
        let rule_repo = ReplaceRuleRepository::new(db.connection());
        let rules = rule_repo.get_enabled_rules()?;
        let book_repo = BookRepository::new(db.connection());
        let book_name = book_repo
            .find_by_url(book_url)?
            .map(|b| b.name)
            .unwrap_or_default();
        Ok((rules, book_name))
    });

    let (rules, book_name) = match loaded {
        Ok(v) => v,
        // 数据库不可用或查询失败时，退化为不净化（与无规则时行为一致）
        Err(_) => return raw_content.to_string(),
    };

    // 繁简转换仅作用于阅读器/导出正文路径（apply_replace_rules=true）；
    // 内容搜索 raw 路径保持原文，避免搜不到被转换的词
    // （对齐 Kotlin BookHelp.getContent 的 replaceEnabled=false 路径）。
    let chinese_convert = if apply_replace_rules {
        current_chinese_convert_direction()
    } else {
        None
    };

    // 章级「删除重复标题」开关（Task #51）：无章节上下文时维持全局默认 true；
    // 带 chapter_index 的路径（阅读器/导出，以及 apply_content_processing_raw
    // 显式传入时）均尊重章级 opt-out，对齐原版 removeSameTitleCache
    // 不受 useReplace 影响的行为
    let remove_duplicate_title = chapter_index
        .map(|idx| is_same_title_removed(book_url, idx))
        .unwrap_or(true);

    process_content_with_rules_inner(
        raw_content,
        chapter_title,
        &rules,
        &book_name,
        apply_replace_rules,
        chinese_convert,
        remove_duplicate_title,
    )
}

/// 净化核心逻辑（应用替换规则）：保留 4 参签名供既有测试调用
#[cfg(test)]
fn process_content_with_rules(
    raw_content: &str,
    chapter_title: &str,
    rules: &[ReplaceRule],
    book_name: &str,
) -> String {
    process_content_with_rules_inner(raw_content, chapter_title, rules, book_name, true, None, true)
}

/// 净化核心逻辑（纯函数，便于单元测试）：
/// - `apply_replace_rules` 控制是否应用替换规则
/// - `chinese_convert` 控制简繁转换方向（None / "t2s" / "s2t"，由调用方从持久化配置读取）
/// - `remove_duplicate_title` 控制是否去除重复标题（章级开关由调用方预先读取）
fn process_content_with_rules_inner(
    raw_content: &str,
    chapter_title: &str,
    rules: &[ReplaceRule],
    book_name: &str,
    apply_replace_rules: bool,
    chinese_convert: Option<String>,
    remove_duplicate_title: bool,
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
    //    apply_replace_rules 由调用方控制（阅读器/导出=true，内容搜索=false）
    //    chinese_convert 来自持久化配置 chineseConverterType（0/1/2 → None/t2s/s2t）
    //    remove_duplicate_title 来自章级开关（Task #51，全局默认 true）
    let config = ProcessorConfig {
        remove_duplicate_title,
        re_segment: false,
        chinese_convert,
        apply_replace_rules,
        indent_spaces: 0,
        trim_empty_lines: false,
    };
    let processor = ContentProcessor::new(config);
    processor.process(raw_content, chapter_title, &entries)
}

/// 根据 chapter_url 查找章节序号、标题与变量（找不到时返回 (0, 空标题, None)）
fn get_chapter_index_title_variable(
    book_url: &str,
    chapter_url: &str,
) -> LegadoResult<(i32, String, Option<String>)> {
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;
    Ok(chapters
        .iter()
        .find(|ch| ch.url == chapter_url)
        .map(|ch| (ch.index, ch.title.clone(), ch.variable.clone()))
        .unwrap_or((0, String::new(), None)))
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

    // ─── refresh_toc 测试 ───────────────────────────────────────────────────

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_refresh_toc_success() {
        let source_url = "https://toc-test.example.com";
        let book_url = "https://toc-test.example.com/book/1";
        let _db_guard = setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
    }

    #[test]
    fn test_refresh_toc_source_not_found() {
        let _db_guard = setup_db_and_source("https://other.example.com");
        let err = refresh_toc("https://x.com/book", "https://nonexistent.example.com").unwrap_err();
        assert!(err.to_string().contains("书源不存在"));
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
        let source_url = "https://toc-db-test.example.com";
        let book_url = "https://toc-db-test.example.com/book/2";
        let _db_guard = setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
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

    /// 测试未启用规则不生效：仅传入启用规则（模拟 get_enabled_rules 过滤）
    #[test]
    fn test_content_processing_disabled_rules_not_applied() {
        // 模拟 get_enabled_rules 仅返回启用的规则
        let all_rules = vec![
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
        let result = process_content_with_rules("xax", "", &vec![rule2], "任意书籍");
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
        let result =
            process_content_with_rules_inner("这是广告内容", "", &rules, "", false, None, true);
        assert_eq!(result, "这是广告内容");
        // apply_replace_rules=true：规则生效，"广告" 被删除
        let result =
            process_content_with_rules_inner("这是广告内容", "", &rules, "", true, None, true);
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
            Some("s2t".to_string()),
            true,
        );
        assert_eq!(result, "測試內容");
    }

    /// 测试 0=不转换回归：chinese_convert=None 时正文保持原样
    #[test]
    fn test_content_processing_chinese_convert_none() {
        let rules: Vec<ReplaceRule> = vec![];
        let result =
            process_content_with_rules_inner("測試內容abc", "", &rules, "", true, None, true);
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
            let to_db_err =
                |e| LegadoError::Database(format!("清理测试数据失败: {e}"));
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
}
