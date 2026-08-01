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
    ReplaceRuleRepository,
};

use crate::db_state::with_database;
use crate::runtime;

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
        let total = chapters.len() as i32;
        return Ok(ChapterListResponse { total, chapters });
    }

    // 2. 数据库无章节：如果是本地书籍，从文件解析并入库
    if is_local_book(book_url) {
        let chapter_infos = legado_book::LocalBook::get_chapters(book_url)?;
        let book_chapters: Vec<BookChapter> = chapter_infos
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
        // 读取时净化：DB/文件保留原始正文，返回前应用替换规则与内容净化
        Ok(apply_content_processing(book_url, &content, &chapter.title))
    } else {
        // 在线书籍：返回章节 URL 信息，由上层配合书源规则获取正文
        // 简化实现：返回章节 URL 供 Dart 侧进一步处理
        Ok(serde_json::to_string(&serde_json::json!({
            "chapter_url": chapter.url,
            "base_url": chapter.base_url,
            "title": chapter.title,
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
    // 1. 从数据库获取书源配置
    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // 2. 使用 WebBookEngine 从网络获取章节列表
    let engine = super::web_book::build_engine();
    let web_chapters: Vec<WebChapter> =
        runtime::block_on(async { engine.get_chapters(&source, book_url).await })?;

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
            variable: None,
            img_url: None,
        })
        .collect();

    // 4. 确保书籍记录存在（满足 chapters 表外键约束），然后先删除旧章节，再批量插入新章节
    with_database(|db| {
        let book_repo = legado_db::BookRepository::new(db.connection());
        if book_repo.find_by_url(book_url)?.is_none() {
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                ..legado_core::models::Book::default()
            };
            book_repo.insert(&book)?;
        }
        let repo = BookChapterRepository::new(db.connection());
        repo.delete_by_book_url(book_url)?;
        repo.insert_batch(&book_chapters)?;
        Ok(())
    })?;

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
    // 1. 检查 DB 缓存
    let cached = with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.get_by_chapter_url(chapter_url)
    })?;

    if let Some(cached_chapter) = cached {
        // 缓存存储原始正文，返回前应用净化（避免规则变更后缓存陈旧）
        let processed = apply_content_processing(
            book_url,
            &cached_chapter.content,
            &cached_chapter.chapter_title,
        );
        return Ok(processed);
    }

    // 2. 缓存未命中，从网络获取
    let source = with_database(|db| {
        let repo = BookSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
    })?
    .ok_or_else(|| LegadoError::Database(format!("书源不存在: {source_url}")))?;

    // 构造 WebChapter 用于请求（同时取得真实章节标题，供去重复标题与缓存使用）
    let (chapter_index, chapter_title) = get_chapter_index_and_title(book_url, chapter_url)?;
    let web_chapter = WebChapter {
        index: chapter_index,
        title: chapter_title.clone(),
        url: chapter_url.to_string(),
        is_vip: false,
    };

    let engine = super::web_book::build_engine();
    let content = runtime::block_on(async { engine.get_content(&source, &web_chapter).await })?;

    // 3. 存入 DB 缓存
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);

    let cached_chapter = CachedChapter {
        id: 0,
        book_url: book_url.to_string(),
        chapter_index,
        chapter_title: chapter_title.clone(),
        chapter_url: chapter_url.to_string(),
        content: content.clone(),
        cached_at: now_ms,
        size_bytes: content.len() as i64,
    };

    with_database(|db| {
        let repo = CacheBookRepository::new(db.connection());
        repo.insert(&cached_chapter)?;
        Ok(())
    })?;

    // 缓存写入原始正文，返回净化后的正文（透传真实章节标题，使去重复标题生效）
    Ok(apply_content_processing(book_url, &content, &chapter_title))
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

    process_content_with_rules(raw_content, chapter_title, &rules, &book_name)
}

/// 净化核心逻辑（纯函数，便于单元测试）：按 scope 过滤规则后经 ContentProcessor 处理
fn process_content_with_rules(
    raw_content: &str,
    chapter_title: &str,
    rules: &[ReplaceRule],
    book_name: &str,
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

    // 3. 构造处理器：仅启用「去重复标题 + 替换规则」，与 Android 净化行为对等
    let config = ProcessorConfig {
        remove_duplicate_title: true,
        re_segment: false,
        chinese_convert: None,
        apply_replace_rules: true,
        indent_spaces: 0,
        trim_empty_lines: false,
    };
    let processor = ContentProcessor::new(config);
    processor.process(raw_content, chapter_title, &entries)
}

/// 根据 chapter_url 查找章节序号与标题（找不到时返回 (0, 空标题)）
fn get_chapter_index_and_title(book_url: &str, chapter_url: &str) -> LegadoResult<(i32, String)> {
    let chapters = with_database(|db| {
        let repo = BookChapterRepository::new(db.connection());
        repo.find_by_book_url(book_url)
    })?;
    Ok(chapters
        .iter()
        .find(|ch| ch.url == chapter_url)
        .map(|ch| (ch.index, ch.title.clone()))
        .unwrap_or((0, String::new())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use legado_core::models::rule::ContentRule;
    use legado_core::models::BookSource;

    /// 初始化测试数据库（全局 Once 保护，并行安全）
    fn setup_db_and_source(source_url: &str) {
        crate::db_state::ensure_test_db();
        insert_test_source(source_url);
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
        setup_db_and_source(source_url);

        let resp = refresh_toc(book_url, source_url).unwrap();
        assert!(resp.total >= 0);
    }

    #[test]
    fn test_refresh_toc_source_not_found() {
        setup_db_and_source("https://other.example.com");
        let err = refresh_toc("https://x.com/book", "https://nonexistent.example.com").unwrap_err();
        assert!(err.to_string().contains("书源不存在"));
    }

    /// 网络测试：需要真实网络访问，CI 中忽略
    #[test]
    #[ignore = "requires network access"]
    fn test_refresh_toc_saves_to_db() {
        let source_url = "https://toc-db-test.example.com";
        let book_url = "https://toc-db-test.example.com/book/2";
        setup_db_and_source(source_url);

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
        setup_db_and_source(source_url);

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
        setup_db_and_source(source_url);

        // 第一次调用：从网络获取并缓存
        let content1 = fetch_chapter_content(book_url, chapter_url, source_url).unwrap();
        assert!(!content1.is_empty());

        // 第二次调用：应命中缓存，返回相同内容
        let content2 = fetch_chapter_content(book_url, chapter_url, source_url).unwrap();
        assert_eq!(content1, content2);
    }

    #[test]
    fn test_fetch_chapter_content_source_not_found() {
        setup_db_and_source("https://other2.example.com");
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
        setup_db_and_source(source_url);

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
        crate::db_state::ensure_test_db();

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
}
