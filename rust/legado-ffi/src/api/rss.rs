//! RSS 源管理 API
//!
//! 提供 RSS 源的增删查与文章获取能力。
//! 早期无 RssSourceRepository 时直接通过 SQL 操作实现（既有函数保留）；
//! 新增函数（如 `update_rss_source`）改走 `legado_db::RssSourceRepository`。

use serde::{Deserialize, Serialize};

use legado_core::models::RssSource;
use legado_core::{LegadoError, LegadoResult};
use legado_db::RssSourceRepository;

use crate::db_state::with_database;
use crate::runtime;

/// RSS 文章项
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RssArticle {
    /// 标题
    pub title: String,
    /// 链接
    pub link: String,
    /// 描述
    pub description: Option<String>,
    /// 发布日期
    pub pub_date: Option<String>,
    /// 图片 URL
    pub image_url: Option<String>,
}

/// 获取所有 RSS 源
pub fn list_rss_sources() -> LegadoResult<Vec<RssSource>> {
    with_database(|db| {
        let conn = db.connection();
        let mut stmt = conn
            .prepare(
                "SELECT sourceUrl, sourceName, sourceIcon, sourceGroup, sourceComment,
                        enabled, variableComment, jsLib, enabledCookieJar, concurrentRate,
                        header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, sortUrl,
                        singleUrl, articleStyle, ruleArticles, ruleNextPage, ruleTitle,
                        rulePubDate, ruleDescription, ruleImage, ruleLink, ruleContent,
                        nextContentUrl,
                        contentWhitelist, contentBlacklist, shouldOverrideUrlLoading,
                        style, enableJs, loadWithBaseUrl, injectJs, preloadJs,
                        startHtml, startStyle, startJs, showWebLog, lastUpdateTime,
                        customOrder, type, preload, cacheFirst, searchUrl
                 FROM rssSources ORDER BY customOrder ASC",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let sources = stmt
            .query_map([], row_to_rss_source)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(sources)
    })
}

/// 添加 RSS 源（全字段写入，对齐 `RssSourceRepository::insert`）
///
/// 历史短 INSERT 会丢失 `sourceGroup` / `singleUrl` 等，导致默认订阅源
/// （`assets/defaultData/rssSources.json`）落库后无法按原版 singleUrl 打开。
pub fn add_rss_source(source_json: &str) -> LegadoResult<RssSource> {
    let source: RssSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("RssSource JSON 解析失败: {e}")))?;
    with_database(|db| {
        let repo = RssSourceRepository::new(db.connection());
        repo.insert(&source)
            .map_err(|e| LegadoError::Database(format!("插入 RSS 源失败: {e}")))?;
        Ok(source)
    })
}

/// 批量导入 RSS 源（JSON 数组），返回成功写入条数
///
/// 对齐契约 `importRssSources`；主键冲突走 INSERT OR REPLACE。
pub fn import_rss_sources(json_array: &str) -> LegadoResult<i32> {
    let sources: Vec<RssSource> = serde_json::from_str(json_array)
        .map_err(|e| LegadoError::Ffi(format!("RSS 源 JSON 数组解析失败: {e}")))?;
    with_database(|db| {
        let repo = RssSourceRepository::new(db.connection());
        let mut imported = 0i32;
        for source in &sources {
            repo.insert(source)
                .map_err(|e| LegadoError::Database(format!("导入 RSS 源失败: {e}")))?;
            imported += 1;
        }
        Ok(imported)
    })
}

/// 导出全部 RSS 源为 JSON 数组（对齐契约 `exportRssSources`）
pub fn export_rss_sources() -> LegadoResult<String> {
    let sources = list_rss_sources()?;
    serde_json::to_string(&sources).map_err(|e| LegadoError::Ffi(format!("RSS 源序列化失败: {e}")))
}

/// 删除默认分组订阅源（`sourceGroup = 'legado'`，对齐 DefaultData.deleteDefault）
pub fn delete_default_rss_sources() -> LegadoResult<i32> {
    with_database(|db| {
        let conn = db.connection();
        let n = conn
            .execute("DELETE FROM rssSources WHERE sourceGroup = 'legado'", [])
            .map_err(|e| LegadoError::Database(format!("删除默认 RSS 源失败: {e}")))?;
        Ok(n as i32)
    })
}

/// 删除 RSS 源
pub fn delete_rss_source(source_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let conn = db.connection();
        conn.execute(
            "DELETE FROM rssSources WHERE sourceUrl = ?1",
            rusqlite::params![source_url],
        )
        .map_err(|e| LegadoError::Database(format!("删除 RSS 源失败: {e}")))?;
        Ok(())
    })
}

/// 设置 RSS 源启用/禁用状态（按 `sourceUrl` 单条 UPDATE `rssSources.enabled`）
///
/// 契约 §2.5 `rssSourceSetEnabled`（2026-10-26 审查批6，加法式）。
///
/// 语义对照原版 Android `RssSourceDao.enable(sourceUrl, enable)`
/// （`@Query("update rssSources set enabled = :enable where sourceUrl = :sourceUrl")`）：
/// Room UPDATE 按主键静默执行——**源不存在时不报错、不写书源表**。
/// 因此本函数以 `bool` 返回是否实际命中行（`false` = 源不存在），
/// 仅 DB 故障才返回 `Err`；绝不触碰 `book_sources` 表
/// （历史缺陷：Dart 侧误接书源 `source_enable`/`source_disable`）。
///
/// DB 层写入统一走 [`RssSourceRepository::set_enabled`] 单实现。
pub fn set_rss_source_enabled(source_url: &str, enabled: bool) -> LegadoResult<bool> {
    with_database(|db| {
        let repo = RssSourceRepository::new(db.connection());
        repo.set_enabled(source_url, enabled)
            .map_err(|e| LegadoError::Database(format!("更新 RSS 源启用状态失败: {e}")))
    })
}

/// 原子更新 RSS 源（按 sourceUrl 主键单条 UPDATE）
///
/// 缺口④ rssUpdateSource 原子更新（审计 2026-08-06，加法式）：
/// 替代 Flutter 侧「删旧+加新」workaround，对既有行原地更新全字段，
/// 不删除行、不触发外键级联，规避关联表串表风险。
/// 源不存在时返回错误（不静默插入）。
pub fn update_rss_source(source_json: &str) -> LegadoResult<RssSource> {
    let source: RssSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("RssSource JSON 解析失败: {e}")))?;
    if source.source_url.trim().is_empty() {
        return Err(LegadoError::Ffi("RssSource sourceUrl 不能为空".into()));
    }
    with_database(|db| {
        let repo = RssSourceRepository::new(db.connection());
        let updated = repo
            .update_fields(&source)
            .map_err(|e| LegadoError::Database(format!("原子更新 RSS 源失败: {e}")))?;
        if !updated {
            return Err(LegadoError::Database(format!(
                "RSS 源不存在: {}",
                source.source_url
            )));
        }
        Ok(source)
    })
}

/// 清空指定 RSS 源的本地文章缓存（对齐 RssSortViewModel.clearArticles）
pub fn clear_rss_articles(source_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        repo.delete_by_source(source_url)
    })
}

/// 获取 RSS 源的文章列表（对齐原版 `Rss.getArticles` / `getArticlesAwait`）
///
/// 编排：读取源（全字段，含 `header` / `enabledCookieJar`）→ `legado-fetcher`
/// RSS 引擎列表请求（`AnalyzeUrl` + 源 header）→ 默认解析 → 写本地
/// `rssArticles` 缓存。
///
/// 批15a 语义修正（逐条对齐原版）：
/// - **删除**「解析空/失败伪造单条摘要」：原版 `RssParserByRule.parseXML`
///   在 body 空白时抛错、解析出 0 篇即空列表，绝不伪造文章；
/// - **删除** `cacheFirst` 列表短路：原版该字段只作用于阅读页 WebView 缓存，
///   与列表取数无关（语义还原登记于批15c/15f 评估）；
/// - 源 `header` 应用到列表请求（含 `enabledCookieJar` 内部标记头）。
///
/// `sort` 恒空、`order` 递减写库（分类与分页留批15b）。
pub fn fetch_rss_articles(source_url: &str) -> LegadoResult<Vec<RssArticle>> {
    // 全字段读取（单一实现：RssSourceRepository::find_by_url）
    let source = with_database(|db| {
        let repo = RssSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
            .map_err(|e| LegadoError::Database(format!("查询 RSS 源失败: {e}")))
    })?
    .ok_or_else(|| LegadoError::Database("RSS 源不存在".into()))?;

    // 批15a：sort 名恒空、列表 URL = sourceUrl
    // （对齐原版 `parseRssSortUrls` 空值回退 `("" to sourceUrl)`；分类/分页留批15b）
    let page = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        legado_fetcher::rss::fetch_articles(&client, &source, "", source_url, None, None).await
    })?;

    // 写入本地文章缓存（对齐原版 rssArticles；sort 恒空、order 递减）
    //
    // 取舍（审查 P2-4）：列表取数本身已成功，缓存写库失败不应让整次调用
    // 报错（原版写库在独立协程执行，失败也不影响返回列表）；故逐条 `warn`
    // 记录后继续，不向上抛。DB 未打开等外层错误同样 warn（不再完全静默）。
    if let Err(e) = with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        for (i, article) in page.items.iter().enumerate() {
            let record = legado_db::RssArticleRecord {
                origin: article.origin.clone(),
                sort: article.sort.clone(),
                title: article.title.clone(),
                order: now - i as i64,
                link: Some(article.link.clone()),
                pub_date: article.pub_date.clone(),
                description: article.description.clone(),
                content: article.content.clone(),
                image: article.image.clone(),
                variable: article.variable.clone(),
                article_type: article.article_type,
                ..Default::default()
            };
            if let Err(e) = repo.insert(&record) {
                log::warn!(
                    "RSS 文章缓存写入失败（origin={}, link={:?}）: {e}",
                    record.origin,
                    record.link
                );
            }
        }
        Ok(())
    }) {
        log::warn!("RSS 文章缓存写入失败（{source_url}）: {e}");
    }

    Ok(page
        .items
        .into_iter()
        .map(|article| RssArticle {
            title: article.title,
            link: article.link,
            description: article.description,
            pub_date: article.pub_date,
            image_url: article.image,
        })
        .collect())
}

/// 将 rusqlite Row 转换为 RssSource
fn row_to_rss_source(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssSource> {
    Ok(RssSource {
        source_url: row.get(0)?,
        source_name: row.get(1)?,
        source_icon: row.get(2)?,
        source_group: row.get(3)?,
        source_comment: row.get(4)?,
        enabled: row.get(5)?,
        variable_comment: row.get(6)?,
        js_lib: row.get(7)?,
        enabled_cookie_jar: row.get(8)?,
        concurrent_rate: row.get(9)?,
        header: row.get(10)?,
        login_url: row.get(11)?,
        login_ui: row.get(12)?,
        login_check_js: row.get(13)?,
        cover_decode_js: row.get(14)?,
        sort_url: row.get(15)?,
        single_url: row.get(16)?,
        article_style: row.get(17)?,
        rule_articles: row.get(18)?,
        rule_next_page: row.get(19)?,
        rule_title: row.get(20)?,
        rule_pub_date: row.get(21)?,
        rule_description: row.get(22)?,
        rule_image: row.get(23)?,
        rule_link: row.get(24)?,
        rule_content: row.get(25)?,
        next_content_url: row.get(26)?,
        content_whitelist: row.get(27)?,
        content_blacklist: row.get(28)?,
        should_override_url_loading: row.get(29)?,
        style: row.get(30)?,
        enable_js: row.get(31)?,
        load_with_base_url: row.get(32)?,
        inject_js: row.get(33)?,
        preload_js: row.get(34)?,
        start_html: row.get(35)?,
        start_style: row.get(36)?,
        start_js: row.get(37)?,
        show_web_log: row.get(38)?,
        last_update_time: row.get(39)?,
        custom_order: row.get(40)?,
        rss_type: row.get(41)?,
        preload: row.get(42)?,
        cache_first: row.get(43)?,
        search_url: row.get(44)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn add_rss_source_persists_group_and_single_url() {
        let _guard = crate::db_state::ensure_test_db();
        let json = r#"{
            "sourceUrl":"https://www.yuque.com/legado",
            "sourceName":"使用说明",
            "sourceGroup":"legado",
            "sourceIcon":"https://example.com/icon.png",
            "enabled":true,
            "singleUrl":true,
            "customOrder":2
        }"#;
        let added = add_rss_source(json).expect("add");
        assert_eq!(added.source_group.as_deref(), Some("legado"));
        assert!(added.single_url);

        let listed = list_rss_sources().expect("list");
        let found = listed
            .iter()
            .find(|s| s.source_url == "https://www.yuque.com/legado")
            .expect("found");
        assert_eq!(found.source_group.as_deref(), Some("legado"));
        assert!(found.single_url);

        let n = import_rss_sources(
            r#"[{"sourceUrl":"https://pan.miaogongzi.net","sourceName":"Meow云","sourceGroup":"legado","singleUrl":true,"enabled":true}]"#,
        )
        .expect("import");
        assert_eq!(n, 1);
        let _ = delete_rss_source("https://www.yuque.com/legado");
        let _ = delete_rss_source("https://pan.miaogongzi.net");
    }

    /// 审查批6：RSS 源开关只更新 `rssSources` 表，书源表零触碰；
    /// 源不存在返回 `false`（不报错），对齐原版 `RssSourceDao.enable`
    /// 的 Room `@Query` UPDATE 静默语义（`RssSourceDao.kt:152-153`）。
    #[test]
    fn set_rss_source_enabled_updates_only_rss_sources() {
        use legado_db::repository::Repository;

        let _guard = crate::db_state::ensure_test_db();
        let url = "https://rss-toggle.example.com/feed";

        // 缺陷复现前提：同 URL 同时存在 RSS 源与书源（旧实现会误改书源）
        add_rss_source(&format!(
            r#"{{"sourceUrl":"{url}","sourceName":"开关测试","enabled":false}}"#
        ))
        .expect("add rss source");
        let book_source = legado_core::models::BookSource {
            book_source_url: url.to_string(),
            book_source_name: "同 URL 书源".to_string(),
            enabled: true,
            ..Default::default()
        };
        with_database(|db| {
            legado_db::BookSourceRepository::new(db.connection()).insert(&book_source)
        })
        .expect("add book source");

        // 正例：启用 RSS 源返回 true，且只有 rssSources 变化
        assert!(set_rss_source_enabled(url, true).expect("enable rss source"));
        let rss_enabled = list_rss_sources()
            .expect("list rss")
            .into_iter()
            .find(|s| s.source_url == url)
            .expect("rss source exists")
            .enabled;
        assert!(rss_enabled, "RSS 源应被启用");
        let book_source_after = with_database(|db| {
            legado_db::BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .expect("find book source")
        .expect("book source exists");
        assert!(book_source_after.enabled, "同 URL 书源不得被 RSS 开关改动");

        // 禁用同样只影响 RSS 源
        assert!(set_rss_source_enabled(url, false).expect("disable rss source"));
        let rss_enabled = list_rss_sources()
            .expect("list rss")
            .into_iter()
            .find(|s| s.source_url == url)
            .expect("rss source exists")
            .enabled;
        assert!(!rss_enabled, "RSS 源应被禁用");
        let book_source_after = with_database(|db| {
            legado_db::BookSourceRepository::new(db.connection()).find_by_url(url)
        })
        .expect("find book source")
        .expect("book source exists");
        assert!(book_source_after.enabled, "禁用 RSS 源不得改动同 URL 书源");

        // 负例：源不存在返回 false，不报错、不新建行
        assert!(
            !set_rss_source_enabled("https://rss-toggle.example.com/missing", true)
                .expect("missing source returns false"),
            "源不存在应返回 false"
        );
        assert!(
            list_rss_sources()
                .expect("list rss")
                .iter()
                .all(|s| s.source_url != "https://rss-toggle.example.com/missing"),
            "源不存在时不得静默插入新行"
        );

        // 清理（共享测试库）
        let _ = delete_rss_source(url);
        let _ =
            with_database(|db| legado_db::BookSourceRepository::new(db.connection()).delete(url));
    }
}
