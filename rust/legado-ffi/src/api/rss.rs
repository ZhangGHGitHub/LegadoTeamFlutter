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

/// 获取 RSS 源的文章列表
///
/// - `cacheFirst`：优先返回本地 rssArticles 缓存
/// - 网络拉取后解析 RSS/Atom（legado-net），并写入本地缓存
pub fn fetch_rss_articles(source_url: &str) -> LegadoResult<Vec<RssArticle>> {
    let (feed_url, cache_first) = with_database(|db| {
        let conn = db.connection();
        let mut stmt = conn
            .prepare(
                "SELECT sourceUrl, COALESCE(cacheFirst, 0) FROM rssSources WHERE sourceUrl = ?1",
            )
            .map_err(|e| LegadoError::Database(format!("查询 RSS 源失败: {e}")))?;
        let mut rows = stmt
            .query_map(rusqlite::params![source_url], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, i32>(1)? != 0))
            })
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?;
        match rows.next() {
            Some(Ok(v)) => Ok(v),
            _ => Err(LegadoError::Database("RSS 源不存在".into())),
        }
    })?;

    if cache_first {
        let cached = with_database(|db| {
            let repo = legado_db::RssArticleRepository::new(db.connection());
            repo.find_by_source(source_url, 500)
        })?;
        if !cached.is_empty() {
            return Ok(cached
                .into_iter()
                .map(|a| RssArticle {
                    title: a.title,
                    link: a.link.unwrap_or_default(),
                    description: a.description,
                    pub_date: a.pub_date,
                    image_url: a.image,
                })
                .collect());
        }
    }

    let articles = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        let response = client.get(&feed_url, None).await?;
        if !response.is_success() {
            return Err(LegadoError::Network(format!(
                "获取 RSS 内容失败: HTTP {}",
                response.status
            )));
        }
        match legado_net::rss::parse_feed(&response.body) {
            Ok(feed) if !feed.articles.is_empty() => Ok(feed
                .articles
                .into_iter()
                .map(|a| RssArticle {
                    title: a.title,
                    link: a.link,
                    description: a.description,
                    pub_date: a.pub_date,
                    image_url: a.image_url,
                })
                .collect::<Vec<_>>()),
            _ => {
                // 非标准 XML / 规则源：保留单条摘要回退，避免整页空白
                Ok(vec![RssArticle {
                    title: feed_url.clone(),
                    link: feed_url.clone(),
                    description: Some(response.body.chars().take(200).collect()),
                    pub_date: None,
                    image_url: None,
                }])
            }
        }
    })?;

    // 写入本地文章缓存（对齐原版 rssArticles）
    let _ = with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        for (i, a) in articles.iter().enumerate() {
            let record = legado_db::RssArticleRecord {
                origin: source_url.to_string(),
                sort: String::new(),
                title: a.title.clone(),
                order: now - i as i64,
                link: Some(a.link.clone()),
                pub_date: a.pub_date.clone(),
                description: a.description.clone(),
                content: None,
                image: a.image_url.clone(),
                variable: None,
                ..Default::default()
            };
            let _ = repo.insert(&record);
        }
        Ok(())
    });

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
}
