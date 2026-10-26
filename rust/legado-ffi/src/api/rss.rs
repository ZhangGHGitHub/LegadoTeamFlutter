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
    /// 分类名（`sortName`；缺省空串。审查 P2-4：供详情按
    /// `(origin, link, sort)` 主键精确写回）
    pub sort: String,
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
        Ok(source.clone())
    })?;
    // 写库成功后刷新源级 concurrentRate（审查 P1-1；空值清除既有 limiter）
    refresh_rss_rate_limit(&source);
    Ok(source)
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
            // 每条写库成功后立即刷新该源限流配置（审查 P1-1）
            refresh_rss_rate_limit(source);
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
        Ok(())
    })?;
    // 写库成功后刷新源级 concurrentRate（审查 P1-1；空值清除既有 limiter）
    refresh_rss_rate_limit(&source);
    Ok(source)
}

/// 清空指定 RSS 源的本地文章缓存（对齐 RssSortViewModel.clearArticles）
pub fn clear_rss_articles(source_url: &str) -> LegadoResult<()> {
    with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        repo.delete_by_source(source_url)
    })
}

/// 只读查询本地缓存的 RSS 文章（契约 §2.5 `rssListCachedArticles`，批15f）
///
/// 对齐原版 `RssArticleDao.flowByOriginSort(origin, sortName)`
/// （`RssArticlesFragment.kt:179-218` 首屏先展示本地缓存）：
/// - **零网络、零写库**；
/// - `sort_name` 非空 → 按 `(origin, sort)` 过滤，缺省 → 该源全部分类；
/// - `order DESC` 排序（与原版 flow 一致）；
/// - 返回 JSON 数组，字段与列表载荷同族：`origin/sort/title/order/link/
///   pubDate/description/content/image/variable/group/read/type`；
///   空 `link` 已由仓库层落为 `legacy:` 伪主键（E4），此处原样返回，
///   UI 按既有 `hasRssArticleLink` 视为无链接。
pub fn rss_list_cached_articles(source_url: &str, sort_name: Option<&str>) -> LegadoResult<String> {
    let sort_filter = sort_name.filter(|value| !value.is_empty());
    let rows = with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        repo.find_by_origin_sort(source_url, sort_filter, 0)
    })?;
    let articles: Vec<serde_json::Value> = rows
        .iter()
        .map(|row| {
            serde_json::json!({
                "origin": row.origin,
                "sort": row.sort,
                "title": row.title,
                "order": row.order,
                "link": row.link,
                "pubDate": row.pub_date,
                "description": row.description,
                "content": row.content,
                "image": row.image,
                "variable": row.variable,
                "group": row.group,
                "read": row.read,
                "type": row.article_type,
            })
        })
        .collect();
    serde_json::to_string(&articles)
        .map_err(|e| LegadoError::Ffi(format!("RSS 缓存文章序列化失败: {e}")))
}

/// RSS 列表页返回载荷（契约 §2.5：`{"articles":[],"nextUrl":…,"hasMore":…}`）
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RssArticlesPagePayload {
    /// 本页文章（规则解析或默认解析）
    articles: Vec<legado_fetcher::rss::RssArticleItem>,
    /// 下一页 URL（`ruleNextPage` 解析结果；空值已归一为 `None`）
    next_url: Option<String>,
    /// 是否还有下一页（文章非空 && nextUrl 非空；loadMore 另要求实际追加）
    has_more: bool,
}

/// 当前毫秒时间戳（对齐原版 `System.currentTimeMillis()`）
fn current_millis() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// RSS 源保存成功后的限流配置刷新（审查 P1-1）
///
/// 与书源保存路径同一语义（[`crate::api::source_rate_limit::refresh`]）：
/// 空 / `"0"` → 移除既有 limiter；合法值 → 原位刷新（保留窗口）；非法值
/// 与未注册 key 不改动。RSS 与书源共享同一进程级注册表（同一 URL 同窗口）。
fn refresh_rss_rate_limit(source: &RssSource) {
    crate::api::source_rate_limit::refresh_source_rate_limit(
        &source.source_url,
        source.concurrent_rate.as_deref().unwrap_or(""),
    );
}

/// 文章行 → `rssArticle` JS 绑定 JSON（对齐 `AnalyzeRule.kt:906`）
///
/// 与 Kotlin `RssArticle` 字段同名（camelCase）：`origin` / `sort` / `title` /
/// `link` / `pubDate` / `description` / `content` / `image` / `variable` /
/// `group` / `read` / `type` / `durPos` / `order`。
fn article_js_json(row: &legado_db::RssArticleRecord) -> String {
    serde_json::json!({
        "origin": row.origin,
        "sort": row.sort,
        "title": row.title,
        "order": row.order,
        "link": row.link,
        "pubDate": row.pub_date,
        "description": row.description,
        "content": row.content,
        "image": row.image,
        "variable": row.variable,
        "group": row.group,
        "read": row.read,
        "type": row.article_type,
        "durPos": row.dur_pos,
    })
    .to_string()
}

/// 读取 RSS 源（全字段；不存在返回 `Ok(None)`）
fn load_rss_source(source_url: &str) -> LegadoResult<Option<RssSource>> {
    with_database(|db| {
        let repo = RssSourceRepository::new(db.connection());
        repo.find_by_url(source_url)
            .map_err(|e| LegadoError::Database(format!("查询 RSS 源失败: {e}")))
    })
}

/// 中立文章 → DB 记录（`order` 由调用方给定）
fn to_record(
    article: &legado_fetcher::rss::RssArticleItem,
    order: i64,
) -> legado_db::RssArticleRecord {
    legado_db::RssArticleRecord {
        origin: article.origin.clone(),
        sort: article.sort.clone(),
        title: article.title.clone(),
        order,
        link: Some(article.link.clone()),
        pub_date: article.pub_date.clone(),
        description: article.description.clone(),
        content: article.content.clone(),
        image: article.image.clone(),
        variable: article.variable.clone(),
        article_type: article.article_type,
        ..Default::default()
    }
}

/// 列表请求（源 + 登录头 → fetcher 引擎）
fn fetch_rss_page(
    source: &RssSource,
    sort_name: &str,
    sort_url: &str,
    page: Option<u32>,
    key: Option<&str>,
) -> LegadoResult<legado_fetcher::rss::RssListPage> {
    // 登录头：内存缓存优先、DB `loginHeader_<url>` 兜底（source_login_cache 单实现）
    let login_header = crate::api::source_login_cache::get_login_header(&source.source_url);
    let login_info = crate::api::source_login_cache::get_login_info(&source.source_url);
    // 源级 concurrentRate 限流（审查 P1-1）：进程级注册表与书源共享窗口语义；
    // 配置在源保存路径 refresh，这里按当前 DB 快照惰性创建/复用 limiter。
    let rate_limiter = crate::api::source_rate_limit::registry();
    runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        legado_fetcher::rss::fetch_articles(
            &client,
            &rate_limiter,
            source,
            sort_name,
            sort_url,
            page,
            key,
            login_header.as_deref(),
            login_info.as_deref(),
        )
        .await
    })
}

/// 获取 RSS 源的文章列表（保留兼容；内部等价 `rssRefreshArticles(sourceUrl, "", sourceUrl, null)`）
///
/// 契约 §2.5 批15b：`getRssArticles` 保留原签名，行为等价于
/// `rssRefreshArticles(source_url, "", source_url, None)`——分类空串按
/// 默认分类（旧数据 `sort=""` 兼容），列表 URL = 源 URL。
pub fn fetch_rss_articles(source_url: &str) -> LegadoResult<Vec<RssArticle>> {
    let json = rss_refresh_articles(source_url, "", source_url, None)?;
    let payload: RssArticlesPagePayload = serde_json::from_str(&json)
        .map_err(|e| LegadoError::Ffi(format!("RSS 列表载荷解析失败: {e}")))?;
    Ok(payload
        .articles
        .into_iter()
        .map(|article| RssArticle {
            title: article.title,
            link: article.link,
            sort: article.sort,
            description: article.description,
            pub_date: article.pub_date,
            image_url: article.image,
        })
        .collect())
}

/// 解析 RSS 源分类列表（契约 §2.5 `rssSortUrls`，批15b；批15f 增可选覆盖）
///
/// 对齐原版 `RssSource.sortUrls()`（`RssSourceExtensions.kt:87-107`）：
/// - `@js:` / `<js>` 配置经 JS 求值（注入 RSS 源 jsLib + setup + source 绑定）；
/// - 脚本结果按源缓存（`CacheRepository` 键 `rssSortUrl_<md5(sourceUrl+sortUrl)>`，
///   对齐原版 ACache 名 `rssSortUrl` + `MD5(sourceUrl+sortUrl)`）；
/// - 求值失败/无配置 → 回退 `[{"name":"","url":sourceUrl}]`。
///
/// [sort_url_override] 非空时（批15f，对齐 `RssSortActivity.kt:356-366`）
/// **忽略源配置**，按覆盖值解析：JSON `{name:url}` 保持书写顺序展开，
/// 非 JSON 单条 `("", 值)`，JSON 解析失败回退单条（见
/// [`legado_fetcher::rss::sort_urls::parse_sort_url_override`]）。
pub fn rss_sort_urls(source_url: &str, sort_url_override: Option<&str>) -> LegadoResult<String> {
    if let Some(override_value) = sort_url_override.filter(|value| !value.trim().is_empty()) {
        let entries =
            legado_fetcher::rss::sort_urls::parse_sort_url_override(override_value, source_url);
        return serde_json::to_string(&entries)
            .map_err(|e| LegadoError::Ffi(format!("RSS 分类列表序列化失败: {e}")));
    }
    let entries = match load_rss_source(source_url)? {
        Some(source) => {
            let login_header = crate::api::source_login_cache::get_login_header(&source.source_url);
            let login_info = crate::api::source_login_cache::get_login_info(&source.source_url);
            let setup_script = legado_fetcher::source_setup::rss_source_js_setup_script(
                &source,
                login_header.as_deref(),
                login_info.as_deref(),
            )
            .ok();
            legado_fetcher::rss::sort_urls::resolve_sort_urls_with_cache(
                &source.source_url,
                source.sort_url.as_deref(),
                |key| {
                    with_database(|db| legado_db::CacheRepository::new(db.connection()).get(key))
                        .ok()
                        .flatten()
                },
                |key, value| {
                    if let Err(e) = with_database(|db| {
                        legado_db::CacheRepository::new(db.connection()).put(key, value, 0)
                    }) {
                        log::warn!("RSS sortUrl 缓存写入失败（{key}）: {e}");
                    }
                },
                |script| {
                    legado_fetcher::rss::sort_urls::evaluate_sort_script(
                        &source,
                        script,
                        setup_script.clone(),
                    )
                },
            )
        }
        // 源未入库：等价原版 `RssSource(sourceUrl=url)` 空配置
        None => legado_fetcher::rss::sort_urls::fallback_sort_urls(source_url),
    };
    serde_json::to_string(&entries)
        .map_err(|e| LegadoError::Ffi(format!("RSS 分类列表序列化失败: {e}")))
}

/// 清除 RSS 源分类脚本求值缓存（契约 §2.5 `rssClearSortCache`，批15b）
///
/// 对齐原版 `RssSource.removeSortCache()`：键 = `rssSortUrl_<md5(sourceUrl+sortUrl)>`
/// （`sortUrl` 为 null 时按 Kotlin 字符串拼接口径拼字面量 `"null"`）。
/// 源不存在时按空配置键静默删除（无命中 = no-op）。
pub fn rss_clear_sort_cache(source_url: &str) -> LegadoResult<()> {
    let configured = load_rss_source(source_url)?.and_then(|source| source.sort_url);
    let key = legado_fetcher::rss::sort_urls::sort_cache_key(source_url, configured.as_deref());
    with_database(|db| legado_db::CacheRepository::new(db.connection()).delete(&key))
}

/// 刷新 RSS 列表（契约 §2.5 `rssRefreshArticles`，批15b）
///
/// 对齐 `RssArticlesViewModel.loadArticles`（`RssArticlesViewModel.kt:66-105`）：
/// 1. `order = now`，请求 `AnalyzeUrl(sortUrl, page=1, key)`；
/// 2. 文章逐个 `order = order--` 后 `INSERT OR REPLACE` 写库；
/// 3. `ruleNextPage` 非空时 `clearOld(origin, sort, order)` 清理旧页；
/// 4. `hasMore = 文章非空 && nextUrl 非空`。
///
/// 取舍（沿用 15a 审查 P2-4）：列表取数成功后写库失败只 `warn`，不向上抛
/// （原版写库在 IO 协程内，失败不影响返回列表）；但**任一写入失败则跳过
/// clearOld**，避免误删未能替换的旧行。
pub fn rss_refresh_articles(
    source_url: &str,
    sort_name: &str,
    sort_url: &str,
    key: Option<&str>,
) -> LegadoResult<String> {
    let source =
        load_rss_source(source_url)?.ok_or_else(|| LegadoError::Database("RSS 源不存在".into()))?;
    // 原版 refresh 的 page 从 1 开始（`RssPaginationState.startRefresh`）
    let page = fetch_rss_page(&source, sort_name, sort_url, Some(1), key)?;

    let now = current_millis();
    let mut any_write_failed = false;
    if let Err(e) = with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        for (i, article) in page.items.iter().enumerate() {
            let record = to_record(article, now - i as i64);
            if let Err(e) = repo.insert(&record) {
                any_write_failed = true;
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
        any_write_failed = true;
    }

    // [RssArticlesViewModel.kt:88-92] ruleNextPage 非空 → 按刷新后水位清理旧页
    let has_next_page_rule = source
        .rule_next_page
        .as_deref()
        .map(|rule| !rule.is_empty())
        .unwrap_or(false);
    if has_next_page_rule && !any_write_failed {
        let watermark = now - page.items.len() as i64;
        if let Err(e) = with_database(|db| {
            legado_db::RssArticleRepository::new(db.connection()).clear_old(
                &source.source_url,
                sort_name,
                watermark,
            )
        }) {
            log::warn!("RSS 旧文章清理失败（{source_url}）: {e}");
        }
    }

    let has_more = !page.items.is_empty() && page.next_url.is_some();
    serialize_page(page, has_more)
}

/// 加载 RSS 下一页（契约 §2.5 `rssLoadMoreArticles`，批15b）
///
/// 对齐 `RssArticlesViewModel.loadMore` + `loadMoreSuccess`
/// （`RssArticlesViewModel.kt:107-166`）：
/// 0. **空/空白 `nextUrl` → 直接返回 `{articles:[],nextUrl:"",hasMore:false}`**
///    （审查 P2-4：无翻页目标，不发请求、不查库）；
/// 1. 请求 `nextUrl`、页码取当前页 + 1（调用方传入）；
/// 2. 本页**首条与末条**均已在库 → 判到底，不写库；
/// 3. 否则 `order` 续接该 `(origin, sort)` 最小 order 递减（原版 VM 的
///    `order` 字段跨页递减；本 FFI 无会话状态，从 DB 水位反推），
///    `INSERT OR IGNORE` 追加（已存在行保持原 order）；
/// 4. `hasMore = 实际追加 && nextUrl 非空`。
///
/// ## 已登记差异：`order` 水位（审查 P2-5）
///
/// 原版 `order` 是 VM 会话字段：刷新时取 `System.currentTimeMillis()`，
/// 翻页时在同一次会话内继续递减；**进程重启后**再次翻页会从新的当前毫秒
/// 重新计数（新页可能排到旧页之前）。本实现无会话状态，每次翻页都以
/// `min(order) - 1` 续接，保证新页始终排在旧页之后。对「部分重叠页」
/// （本页首条已存在、末条为新）两种口径结果一致：已存在条目 `IGNORE`
/// 保持原 order，新条目接在水位之下（用例见
/// `tests/rss_rule_pagination_loopback.rs` 的 `/list?p=4` 场景）。
pub fn rss_load_more_articles(
    source_url: &str,
    sort_name: &str,
    next_url: &str,
    page: u32,
    key: Option<&str>,
) -> LegadoResult<String> {
    // [审查 P2-4] 空/空白 nextUrl：无翻页目标，直接返回空页载荷，
    // 不发网络请求、不触碰 DB（源不存在也按空页处理）
    if next_url.trim().is_empty() {
        let payload = serde_json::json!({
            "articles": [],
            "nextUrl": "",
            "hasMore": false,
        });
        return serde_json::to_string(&payload)
            .map_err(|e| LegadoError::Ffi(format!("RSS 空页载荷序列化失败: {e}")));
    }
    let source =
        load_rss_source(source_url)?.ok_or_else(|| LegadoError::Database("RSS 源不存在".into()))?;
    let fetched = fetch_rss_page(&source, sort_name, next_url, Some(page.max(1)), key)?;

    let mut added = false;
    if let (Some(first), Some(last)) = (fetched.items.first(), fetched.items.last()) {
        // 原版 quirk：末条也用 firstArticle.sort 查询（同页 sort 相同，无行为差异）
        let (first_exists, last_exists) = with_database(|db| {
            let repo = legado_db::RssArticleRepository::new(db.connection());
            Ok((
                repo.find_one(&first.origin, &first.link, &first.sort)?,
                repo.find_one(&last.origin, &last.link, &first.sort)?,
            ))
        })?;

        if !(first_exists && last_exists) {
            // order 续接：min(order) - 1（无行则取当前毫秒）
            let start_order = with_database(|db| {
                legado_db::RssArticleRepository::new(db.connection())
                    .min_order(&source.source_url, sort_name)
            })?
            .map(|min| min.saturating_sub(1))
            .unwrap_or_else(current_millis);

            let mut any_write_failed = false;
            if let Err(e) = with_database(|db| {
                let repo = legado_db::RssArticleRepository::new(db.connection());
                for (i, article) in fetched.items.iter().enumerate() {
                    let record = to_record(article, start_order - i as i64);
                    if let Err(e) = repo.append_ignore(&record) {
                        any_write_failed = true;
                        log::warn!(
                            "RSS 文章追加失败（origin={}, link={:?}）: {e}",
                            record.origin,
                            record.link
                        );
                    }
                }
                Ok(())
            }) {
                log::warn!("RSS 文章追加失败（{source_url}）: {e}");
                any_write_failed = true;
            }
            added = !any_write_failed;
        }
    }

    let has_more = added && fetched.next_url.is_some();
    serialize_page(fetched, has_more)
}

/// 拉取 RSS 文章正文并写回（契约 §2.5 `rssFetchContent`，批15c）
///
/// 对齐原版 `ReadRssViewModel.loadContent`（`ReadRssViewModel.kt:153-168`）：
///
/// ```text
/// Rss.getContent(rssArticle, rssSource.ruleContent, rssSource)
///   .onSuccess(IO) { body ->
///     rssArticle.description = body; rssArticleDao.insert(rssArticle)
///     rssStar?.let { it.description = body; rssStarDao.insert(it) }
///   }
/// ```
///
/// 1. 源不存在 → `Err`（与批15b 列表方法同口径）；
/// 2. `ruleContent` 空/空白 → `Ok("")`（不发请求；原版调用方在此前已短路）；
/// 3. 按 `(origin, link[, sort])` 索引查询文章行（`find_by_link`，审查 P2-9）：
///    `type` 参与正文分页门控、`variable` 作为正文规则 `@get` 初值、整行
///    JSON 注入 `rssArticle` JS 绑定（审查 P2-10）、行本身是写回目标；
///    行不存在（历史入口/未刷新列表）按 `type = 0` 处理且跳过文章写回
///    （对齐原版内存态 `RssArticle(origin, title, title, link = openUrl)`；
///    **历史入口暂不抓规则正文的收敛属批15d/15f**）；
/// 4. 引擎抓取（[`legado_fetcher::rss::content::fetch_content`]）：失败（首屏/
///    任一后续页/登录检测）→ `Err`；正文为空 → `Ok("")`；
/// 5. 成功后写回 `rssArticles.description` 与 `rssStars.description`（仅
///    `(origin, link)` 已收藏行）。**已登记差异**：写回失败只 `warn`，正文
///    仍返回（原版写库异常会让整次加载显示失败）。
pub fn rss_fetch_content(source_url: &str, link: &str, sort: Option<&str>) -> LegadoResult<String> {
    if link.trim().is_empty() {
        return Err(LegadoError::Ffi("RSS 文章链接不能为空".into()));
    }
    let source =
        load_rss_source(source_url)?.ok_or_else(|| LegadoError::Database("RSS 源不存在".into()))?;

    // [ReadRssViewModel.kt:52-58] 正文规则空白时原版不会进入 loadContent
    let rule_content = source.rule_content.as_deref().unwrap_or("");
    if rule_content.trim().is_empty() {
        return Ok(String::new());
    }

    // 文章行：type / variable / rssArticle 绑定 / 写回目标（主键索引查询；
    // sort 缺省按 order DESC 取首行，对齐原版 `getByLink` 的单行语义）
    let article = with_database(|db| {
        let repo = legado_db::RssArticleRepository::new(db.connection());
        repo.find_by_link(source_url, link, sort)
    })?;
    let article_type = article.as_ref().map(|row| row.article_type).unwrap_or(0);
    let article_variable = article.as_ref().and_then(|row| row.variable.clone());
    // 行不存在时仍注入最小对象（历史入口），规则 @js 读 rssArticle 不报错
    let article_json = article.as_ref().map(article_js_json).unwrap_or_else(|| {
        serde_json::json!({
            "origin": source.source_url,
            "title": "",
            "link": link,
            "type": 0,
        })
        .to_string()
    });

    // 登录头 / 用户信息：内存缓存优先、DB 兜底（同源门控在引擎内完成）
    let login_header = crate::api::source_login_cache::get_login_header(&source.source_url);
    let login_info = crate::api::source_login_cache::get_login_info(&source.source_url);
    // 源级 concurrentRate 限流（审查 P1-1）：每次正文/分页请求前取许可
    let rate_limiter = crate::api::source_rate_limit::registry();

    let content = runtime::block_on(async {
        let client = crate::http_state::shared_client()?;
        legado_fetcher::rss::content::fetch_content(
            &client,
            &rate_limiter,
            &source,
            link,
            article_type,
            article_variable.as_deref(),
            Some(&article_json),
            login_header.as_deref(),
            login_info.as_deref(),
        )
        .await
    })?;

    // [ReadRssViewModel.kt:157-162] 写回文章描述（REPLACE 全行，保留 order/read 等）
    if let Some(mut record) = article {
        record.description = Some(content.clone());
        if let Err(e) = with_database(|db| {
            legado_db::RssArticleRepository::new(db.connection()).insert(&record)
        }) {
            log::warn!("RSS 正文写回文章描述失败（{source_url}, {link}）: {e}");
        }
    } else {
        log::debug!("RSS 文章不在库中，跳过正文写回（{source_url}, {link}）");
    }

    // [ReadRssViewModel.kt:159-162] 已收藏时同步收藏描述（未收藏不写）
    match with_database(|db| {
        legado_db::RssStarRepository::new(db.connection()).find_by_key(&source.source_url, link)
    }) {
        Ok(Some(mut star)) => {
            star.description = Some(content.clone());
            if let Err(e) = with_database(|db| {
                legado_db::RssStarRepository::new(db.connection()).add_star(&star)
            }) {
                log::warn!("RSS 正文写回收藏描述失败（{source_url}, {link}）: {e}");
            }
        }
        Ok(None) => {}
        Err(e) => log::warn!("RSS 收藏查询失败，跳过正文写回（{source_url}, {link}）: {e}"),
    }

    Ok(content)
}

/// 列表页 → 契约 JSON 载荷
fn serialize_page(page: legado_fetcher::rss::RssListPage, has_more: bool) -> LegadoResult<String> {
    let payload = RssArticlesPagePayload {
        articles: page.items,
        // 空白 nextUrl 归一为 None（对齐原版 `normalizedPageUrl`）
        next_url: page.next_url.filter(|url| !url.trim().is_empty()),
        has_more,
    };
    serde_json::to_string(&payload)
        .map_err(|e| LegadoError::Ffi(format!("RSS 列表载荷序列化失败: {e}")))
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

    /// 审查 P2-4：空/空白 `nextUrl` 直接返回空页载荷（`nextUrl` 为空串），
    /// 不发请求、不查库（源不存在也不报错）
    #[test]
    fn rss_load_more_blank_next_url_returns_empty_page() {
        for blank in ["", "   ", "\r\n"] {
            let json =
                rss_load_more_articles("https://rss-blank.example.com/missing", "", blank, 2, None)
                    .unwrap_or_else(|e| panic!("空白 nextUrl 不应失败（{blank:?}）: {e}"));
            let value: serde_json::Value = serde_json::from_str(&json).expect("解析载荷");
            assert_eq!(value["articles"], serde_json::json!([]), "{blank:?}");
            assert_eq!(value["nextUrl"], "", "空白 nextUrl 归一为空串: {json}");
            assert_eq!(value["hasMore"], false, "{blank:?}");
        }
    }

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
