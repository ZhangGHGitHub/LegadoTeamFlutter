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

/// 添加 RSS 源
pub fn add_rss_source(source_json: &str) -> LegadoResult<RssSource> {
    let source: RssSource = serde_json::from_str(source_json)
        .map_err(|e| LegadoError::Ffi(format!("RssSource JSON 解析失败: {e}")))?;
    with_database(|db| {
        let conn = db.connection();
        conn.execute(
            "INSERT OR REPLACE INTO rssSources
             (sourceUrl, sourceName, sourceIcon, enabled, customOrder, enableJs,
              loadWithBaseUrl, showWebLog, lastUpdateTime, type, preload, cacheFirst)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
            rusqlite::params![
                source.source_url,
                source.source_name,
                source.source_icon,
                source.enabled,
                source.custom_order,
                source.enable_js,
                source.load_with_base_url,
                source.show_web_log,
                source.last_update_time,
                source.rss_type,
                source.preload,
                source.cache_first,
            ],
        )
        .map_err(|e| LegadoError::Database(format!("插入 RSS 源失败: {e}")))?;
        Ok(source)
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

/// 获取 RSS 源的文章列表（通过网络请求获取）
pub fn fetch_rss_articles(source_url: &str) -> LegadoResult<Vec<RssArticle>> {
    // 从数据库获取源信息
    let source = with_database(|db| {
        let conn = db.connection();
        let mut stmt = conn
            .prepare("SELECT sourceUrl, sourceName FROM rssSources WHERE sourceUrl = ?1")
            .map_err(|e| LegadoError::Database(format!("查询 RSS 源失败: {e}")))?;
        let mut rows = stmt
            .query_map(rusqlite::params![source_url], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        match rows.next() {
            Some(Ok((url, name))) => Ok((url, name)),
            _ => Err(LegadoError::Database("RSS 源不存在".into())),
        }
    })?;

    // 通过网络获取 RSS 内容
    let articles = runtime::block_on(async {
        let client = crate::http_state::shared_client();
        let response = client.get(&source.0, None).await?;
        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "获取 RSS 内容失败: HTTP {}",
                response.status
            )));
        }
        // 简化实现：返回原始内容作为单条文章
        Ok(vec![RssArticle {
            title: source.1,
            link: source.0,
            description: Some(response.body.chars().take(200).collect()),
            pub_date: None,
            image_url: None,
        }])
    })?;

    Ok(articles)
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
        content_whitelist: row.get(26)?,
        content_blacklist: row.get(27)?,
        should_override_url_loading: row.get(28)?,
        style: row.get(29)?,
        enable_js: row.get(30)?,
        load_with_base_url: row.get(31)?,
        inject_js: row.get(32)?,
        preload_js: row.get(33)?,
        start_html: row.get(34)?,
        start_style: row.get(35)?,
        start_js: row.get(36)?,
        show_web_log: row.get(37)?,
        last_update_time: row.get(38)?,
        custom_order: row.get(39)?,
        rss_type: row.get(40)?,
        preload: row.get(41)?,
        cache_first: row.get(42)?,
        search_url: row.get(43)?,
    })
}
