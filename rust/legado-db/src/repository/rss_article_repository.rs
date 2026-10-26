//! RssArticle Repository - rssArticles 表 CRUD

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 文章记录（v101 补齐 group/read/article_type/dur_pos，对齐 Room 99.json）
#[derive(Debug, Clone)]
pub struct RssArticleRecord {
    pub origin: String,
    pub sort: String,
    pub title: String,
    pub order: i64,
    pub link: Option<String>,
    pub pub_date: Option<String>,
    pub description: Option<String>,
    pub content: Option<String>,
    pub image: Option<String>,
    pub variable: Option<String>,
    /// 分组（对齐 Kotlin RssArticle.group，默认“默认分组”）
    pub group: String,
    /// 是否已读（对齐 Kotlin RssArticle.read）
    pub read: bool,
    /// 类型 0网页，1图片，2视频（对齐 Kotlin RssArticle.type）
    pub article_type: i32,
    /// 阅读进度（对齐 Kotlin RssArticle.durPos）
    pub dur_pos: i32,
}

/// 默认分组名（对齐 Kotlin `@ColumnInfo(defaultValue = "默认分组")`）
pub const DEFAULT_RSS_GROUP: &str = "默认分组";

impl Default for RssArticleRecord {
    fn default() -> Self {
        Self {
            origin: String::new(),
            sort: String::new(),
            title: String::new(),
            order: 0,
            link: None,
            pub_date: None,
            description: None,
            content: None,
            image: None,
            variable: None,
            group: DEFAULT_RSS_GROUP.to_string(),
            read: false,
            article_type: 0,
            dur_pos: 0,
        }
    }
}

/// RSS 文章数据访问层
pub struct RssArticleRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RssArticleRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 插入文章（主键冲突时替换），主键 (origin, link, sort)
    pub fn insert(&self, article: &RssArticleRecord) -> LegadoResult<()> {
        self.insert_with_conflict(article, "REPLACE")?;
        Ok(())
    }

    /// 追加文章（主键冲突时忽略），主键 (origin, link, sort)
    ///
    /// 对齐原版 `RssArticleDao.append`（`@Insert(onConflict = IGNORE)`，
    /// `RssArticleDao.kt:30-31`）：`RssArticlesViewModel.loadMoreSuccess` 用其
    /// 追加下一页，已存在的旧文章保持原 `order`/标题不被覆盖。
    ///
    /// 返回是否实际插入（`INSERT OR IGNORE` 命中冲突时为 `false`）。
    pub fn append_ignore(&self, article: &RssArticleRecord) -> LegadoResult<bool> {
        self.insert_with_conflict(article, "IGNORE")
    }

    /// 写库公共实现（`conflict` = `REPLACE` / `IGNORE`）
    fn insert_with_conflict(
        &self,
        article: &RssArticleRecord,
        conflict: &str,
    ) -> LegadoResult<bool> {
        // 空分组回退为默认分组（对齐 Kotlin 实体默认值）
        let group = if article.group.is_empty() {
            DEFAULT_RSS_GROUP
        } else {
            &article.group
        };
        let link = resolve_rss_link(
            &article.origin,
            &article.title,
            &article.sort,
            article.link.as_deref(),
        );
        let sql = format!(
            "INSERT OR {conflict} INTO rssArticles (origin, sort, title, \"order\", link,
             pubDate, description, content, image, \"group\", \"read\", variable,
             type, durPos)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)"
        );
        let affected = self
            .conn
            .execute(
                &sql,
                params![
                    article.origin,
                    article.sort,
                    article.title,
                    article.order,
                    link,
                    article.pub_date,
                    article.description,
                    article.content,
                    article.image,
                    group,
                    article.read,
                    article.variable,
                    article.article_type,
                    article.dur_pos,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入 RSS 文章失败: {e}")))?;
        Ok(affected > 0)
    }

    /// 删除指定分类下 `order` 小于给定值的旧文章
    ///
    /// 逐字对齐原版 `RssArticleDao.clearOld`（`RssArticleDao.kt:36-37`：
    /// `delete from rssArticles where origin = :origin and sort = :sort and
    /// \`order\` < :order`）。`RssArticlesViewModel.loadArticles` 在
    /// `ruleNextPage` 非空时按刷新后的 order 水位清理旧页。
    pub fn clear_old(&self, origin: &str, sort: &str, order: i64) -> LegadoResult<usize> {
        let affected = self
            .conn
            .execute(
                "DELETE FROM rssArticles WHERE origin = ?1 AND sort = ?2 AND \"order\" < ?3",
                params![origin, sort, order],
            )
            .map_err(|e| LegadoError::Database(format!("清理 RSS 旧文章失败: {e}")))?;
        Ok(affected)
    }

    /// 判断指定主键的文章是否已存在（对齐原版 `RssArticleDao.get`）
    ///
    /// `RssArticlesViewModel.loadMoreSuccess` 用本页首条与末条各查一次，
    /// 两者同时命中即判「已到底」。
    ///
    /// 空 `link` 兼容：15a 起仓库层把空 link 落为 `legacy:{origin}:{title}:{sort}`
    /// 伪造主键（E4 维持），此处按 `legacy:{origin}:` 前缀判定存在性，
    /// 避免翻页判底对空 link 永远失效。
    ///
    /// **不可达说明（审查 P2-6）**：当前唯一调用点
    /// `rss_load_more_articles` 传入的 `link` 恒非空——规则列表解析在
    /// link 为空时回退 `sortUrl`（`legado-fetcher::rss::parser_rule`），
    /// 默认解析也保留 feed 原始 link。因此空前缀分支实际不可达，保留为
    /// 防御性兜底：未来若新增调用点（如直读 15a 遗留的空 link 数据），
    /// 判底不会静默失效。注意前缀匹配只用于「是否存在」，不做精确主键比对。
    pub fn find_one(&self, origin: &str, link: &str, sort: &str) -> LegadoResult<bool> {
        let exists: i64 = if link.trim().is_empty() {
            let prefix = format!("legacy:{origin}:");
            self.conn
                .query_row(
                    "SELECT EXISTS(
                        SELECT 1 FROM rssArticles
                        WHERE origin = ?1 AND sort = ?2
                          AND substr(link, 1, length(?3)) = ?3
                    )",
                    params![origin, sort, prefix],
                    |row| row.get(0),
                )
                .map_err(|e| LegadoError::Database(format!("查询 RSS 文章失败: {e}")))?
        } else {
            self.conn
                .query_row(
                    "SELECT EXISTS(
                        SELECT 1 FROM rssArticles
                        WHERE origin = ?1 AND link = ?2 AND sort = ?3
                    )",
                    params![origin, link, sort],
                    |row| row.get(0),
                )
                .map_err(|e| LegadoError::Database(format!("查询 RSS 文章失败: {e}")))?
        };
        Ok(exists != 0)
    }

    /// 按 `(origin, link[, sort])` 查询单篇文章（审查 P2-9）
    ///
    /// 对齐原版 `RssArticleDao.getByLink(origin, link)` 与
    /// `get(origin, link, sort)`：`sort` 给定时按完整主键收窄；未给定时
    /// 返回该 `origin + link` 下 `order` 最大的一行（`ORDER BY "order" DESC
    /// LIMIT 1`，与原实现「`find_by_source` 按 order DESC 后取首条」行为
    /// 一致）。同 link 多分类（多 sort）时缺省取最新一条，调用方应尽量传
    /// `sort` 精确定位。
    ///
    /// 替代 `rss_fetch_content` 原先的 `find_by_source(source, i32::MAX)`
    /// 全表扫描 + 内存过滤；走主键索引前缀 `(origin, link)`。
    pub fn find_by_link(
        &self,
        origin: &str,
        link: &str,
        sort: Option<&str>,
    ) -> LegadoResult<Option<RssArticleRecord>> {
        let sql = match sort {
            Some(_) => {
                "SELECT origin, sort, title, \"order\", link, pubDate, description,
                        content, image, \"group\", \"read\", variable, type, durPos
                 FROM rssArticles WHERE origin = ?1 AND link = ?2 AND sort = ?3
                 ORDER BY \"order\" DESC LIMIT 1"
            }
            None => {
                "SELECT origin, sort, title, \"order\", link, pubDate, description,
                        content, image, \"group\", \"read\", variable, type, durPos
                 FROM rssArticles WHERE origin = ?1 AND link = ?2
                 ORDER BY \"order\" DESC LIMIT 1"
            }
        };
        let mut stmt = self
            .conn
            .prepare(sql)
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let mut rows = match sort {
            Some(sort) => stmt.query_map(params![origin, link, sort], row_to_article),
            None => stmt.query_map(params![origin, link], row_to_article),
        }
        .map_err(|e| LegadoError::Database(format!("查询 RSS 文章失败: {e}")))?;
        match rows.next() {
            Some(row) => row
                .map(Some)
                .map_err(|e| LegadoError::Database(format!("查询 RSS 文章失败: {e}"))),
            None => Ok(None),
        }
    }

    /// 指定分类当前最小 `order`（无行返回 `None`）
    ///
    /// 供翻页写入续接水位：下一次 `append_ignore` 的起始 order 取
    /// `min_order - 1`，使新页文章排在上一页之后（对齐原版 VM 中
    /// `order` 字段跨刷新/翻页持续递减的语义；本层无会话状态，故从
    /// DB 水位反推）。
    pub fn min_order(&self, origin: &str, sort: &str) -> LegadoResult<Option<i64>> {
        let order: Option<i64> = self
            .conn
            .query_row(
                "SELECT MIN(\"order\") FROM rssArticles WHERE origin = ?1 AND sort = ?2",
                params![origin, sort],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询 RSS 最小 order 失败: {e}")))?;
        Ok(order)
    }

    /// 标记文章已读状态（按 origin+title；同标题多 link 时批量更新）
    pub fn update_read(&self, origin: &str, title: &str, read: bool) -> LegadoResult<()> {
        self.conn
            .execute(
                "UPDATE rssArticles SET \"read\" = ?1 WHERE origin = ?2 AND title = ?3",
                params![read, origin, title],
            )
            .map_err(|e| LegadoError::Database(format!("更新 RSS 文章已读状态失败: {e}")))?;
        Ok(())
    }

    /// 按来源查询文章列表（按 order 降序）
    pub fn find_by_source(
        &self,
        source_url: &str,
        limit: i32,
    ) -> LegadoResult<Vec<RssArticleRecord>> {
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, sort, title, \"order\", link, pubDate, description,
                        content, image, \"group\", \"read\", variable, type, durPos
                 FROM rssArticles WHERE origin = ?1
                 ORDER BY \"order\" DESC LIMIT ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;

        let rows = stmt
            .query_map(params![source_url, limit], row_to_article)
            .map_err(|e| LegadoError::Database(format!("查询失败: {e}")))?
            .filter_map(|r| r.ok())
            .collect();
        Ok(rows)
    }

    /// 按 link 删除文章
    pub fn delete(&self, link: &str) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM rssArticles WHERE link = ?1", params![link])
            .map_err(|e| LegadoError::Database(format!("删除 RSS 文章失败: {e}")))?;
        Ok(())
    }

    /// 按来源删除所有文章
    pub fn delete_by_source(&self, source_url: &str) -> LegadoResult<()> {
        self.conn
            .execute(
                "DELETE FROM rssArticles WHERE origin = ?1",
                params![source_url],
            )
            .map_err(|e| LegadoError::Database(format!("按来源删除 RSS 文章失败: {e}")))?;
        Ok(())
    }

    /// 获取文章总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM rssArticles", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }
}

fn resolve_rss_link(origin: &str, title: &str, sort: &str, link: Option<&str>) -> String {
    match link {
        Some(l) if !l.trim().is_empty() => l.to_string(),
        _ => format!("legacy:{origin}:{title}:{sort}"),
    }
}

fn row_to_article(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssArticleRecord> {
    let link: String = row.get(4)?;
    Ok(RssArticleRecord {
        origin: row.get(0)?,
        sort: row.get(1)?,
        title: row.get(2)?,
        order: row.get(3)?,
        link: if link.is_empty() { None } else { Some(link) },
        pub_date: row.get(5)?,
        description: row.get(6)?,
        content: row.get(7)?,
        image: row.get(8)?,
        group: row.get(9)?,
        read: row.get::<_, i32>(10)? != 0,
        variable: row.get(11)?,
        article_type: row.get(12)?,
        dur_pos: row.get(13)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_article(origin: &str, title: &str, order: i64) -> RssArticleRecord {
        RssArticleRecord {
            origin: origin.to_string(),
            sort: "default".to_string(),
            title: title.to_string(),
            order,
            link: Some(format!("https://example.com/{title}")),
            pub_date: Some("2025-01-01".to_string()),
            description: Some("desc".to_string()),
            content: None,
            image: None,
            variable: None,
            ..Default::default()
        }
    }

    #[test]
    fn test_insert_and_find_by_source() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "Article1", 1))
            .unwrap();
        repo.insert(&make_article("https://rss.com", "Article2", 2))
            .unwrap();

        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles.len(), 2);
        // order DESC
        assert_eq!(articles[0].title, "Article2");
    }

    #[test]
    fn test_insert_replace() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "Article1", 1))
            .unwrap();
        // 相同主键 (origin, link, sort) 替换
        let mut updated = make_article("https://rss.com", "Article1", 5);
        updated.description = Some("updated".to_string());
        repo.insert(&updated).unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles[0].description, Some("updated".to_string()));
    }

    #[test]
    fn test_delete_by_link() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "A1", 1))
            .unwrap();
        repo.insert(&make_article("https://rss.com", "A2", 2))
            .unwrap();
        repo.delete("https://example.com/A1").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
    }

    #[test]
    fn test_delete_by_source() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss1.com", "A1", 1))
            .unwrap();
        repo.insert(&make_article("https://rss1.com", "A2", 2))
            .unwrap();
        repo.insert(&make_article("https://rss2.com", "B1", 1))
            .unwrap();
        repo.delete_by_source("https://rss1.com").unwrap();

        assert_eq!(repo.count().unwrap(), 1);
        let remaining = repo.find_by_source("https://rss2.com", 10).unwrap();
        assert_eq!(remaining.len(), 1);
    }

    #[test]
    fn test_find_by_source_limit() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        for i in 0..10 {
            repo.insert(&make_article("https://rss.com", &format!("A{i}"), i))
                .unwrap();
        }
        let articles = repo.find_by_source("https://rss.com", 3).unwrap();
        assert_eq!(articles.len(), 3);
    }

    #[test]
    fn test_find_by_source_empty() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        let articles = repo.find_by_source("https://nonexist.com", 10).unwrap();
        assert!(articles.is_empty());
    }

    // ─── v101 新增字段读写测试（group/read/type/durPos）────────────

    #[test]
    fn test_new_fields_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        let mut article = make_article("https://rss.com", "新字段文章", 1);
        article.group = "科技".to_string();
        article.read = true;
        article.article_type = 2;
        article.dur_pos = 42;
        repo.insert(&article).unwrap();

        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles.len(), 1);
        assert_eq!(articles[0].group, "科技");
        assert!(articles[0].read);
        assert_eq!(articles[0].article_type, 2);
        assert_eq!(articles[0].dur_pos, 42);
    }

    #[test]
    fn test_default_group_and_update_read() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        // 默认构造：group 为默认分组，未读
        repo.insert(&make_article("https://rss.com", "默认分组文章", 1))
            .unwrap();

        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(articles[0].group, "默认分组");
        assert!(!articles[0].read);

        // 更新已读状态
        repo.update_read("https://rss.com", "默认分组文章", true)
            .unwrap();
        let articles = repo.find_by_source("https://rss.com", 10).unwrap();
        assert!(articles[0].read);
    }

    // ─── 批15b：分页写入/清理/判底 ────────────────────────────────

    /// `clear_old` 只删同 (origin, sort) 下 order 小于水位的行
    #[test]
    fn test_clear_old_only_below_watermark() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        for i in 0..5 {
            repo.insert(&make_article("https://rss.com", &format!("A{i}"), i))
                .unwrap();
        }
        // 其他分类不受影响
        let mut other = make_article("https://rss.com", "其他分类", 1);
        other.sort = "科技".to_string();
        repo.insert(&other).unwrap();

        let deleted = repo.clear_old("https://rss.com", "default", 3).unwrap();
        assert_eq!(deleted, 3, "order < 3 的 3 行应被删除");
        let remaining = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(remaining.len(), 3, "本分类剩 2 行 + 其他分类 1 行");
        assert!(remaining.iter().any(|r| r.sort == "科技"));
    }

    /// `append_ignore` 命中主键时保持旧行内容（不覆盖标题/order）
    #[test]
    fn test_append_ignore_keeps_existing_row() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        let original = make_article("https://rss.com", "已有文章", 9);
        repo.insert(&original).unwrap();

        let mut duplicate = make_article("https://rss.com", "已有文章", 1);
        duplicate.link = original.link.clone();
        duplicate.description = Some("新描述".to_string());
        assert!(!repo.append_ignore(&duplicate).unwrap(), "冲突应被忽略");

        let rows = repo.find_by_source("https://rss.com", 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].order, 9, "旧 order 必须保留");
        assert_eq!(
            rows[0].description.as_deref(),
            Some("desc"),
            "旧描述必须保留"
        );

        // 新主键正常插入
        let fresh = make_article("https://rss.com", "新文章", 2);
        assert!(repo.append_ignore(&fresh).unwrap());
        assert_eq!(repo.count().unwrap(), 2);
    }

    /// `find_one` 命中/未命中；空 link 按 `legacy:` 前缀判定
    #[test]
    fn test_find_one_and_legacy_empty_link() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        repo.insert(&make_article("https://rss.com", "有链接", 1))
            .unwrap();

        assert!(repo
            .find_one("https://rss.com", "https://example.com/有链接", "default")
            .unwrap());
        assert!(!repo
            .find_one("https://rss.com", "https://example.com/不存在", "default")
            .unwrap());
        assert!(
            !repo
                .find_one("https://rss.com", "https://example.com/有链接", "科技")
                .unwrap(),
            "分类不匹配不得命中"
        );

        // 空 link 落库为 legacy: 伪造主键；判底按前缀命中
        let mut empty_link = make_article("https://rss.com", "空链接", 0);
        empty_link.link = None;
        repo.insert(&empty_link).unwrap();
        assert!(
            repo.find_one("https://rss.com", "", "default").unwrap(),
            "空 link 应按 legacy 前缀判定存在"
        );
        assert!(!repo.find_one("https://rss.org", "", "default").unwrap());
    }

    /// `find_by_link` 按 link 精确命中；sort 给定时收窄；缺省取 order 最大行
    #[test]
    fn test_find_by_link_with_and_without_sort() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        let url = "https://example.com/a1";
        let mut first = make_article("https://rss.com", "分类一", 5);
        first.sort = "科技".to_string();
        first.link = Some(url.to_string());
        repo.insert(&first).unwrap();
        let mut second = make_article("https://rss.com", "分类二", 9);
        second.sort = "文学".to_string();
        second.link = Some(url.to_string());
        repo.insert(&second).unwrap();

        // 给定 sort：完整主键定位
        let hit = repo
            .find_by_link("https://rss.com", url, Some("科技"))
            .unwrap()
            .expect("命中科技分类");
        assert_eq!(hit.title, "分类一");
        assert_eq!(hit.sort, "科技");

        // 缺省 sort：取 order 最大的一行（文学 9 > 科技 5）
        let hit = repo
            .find_by_link("https://rss.com", url, None)
            .unwrap()
            .expect("缺省取最新行");
        assert_eq!(hit.title, "分类二");
        assert_eq!(hit.order, 9);

        // 源或 link 不匹配 → None
        assert!(repo
            .find_by_link("https://other.com", url, None)
            .unwrap()
            .is_none());
        assert!(repo
            .find_by_link("https://rss.com", "https://example.com/missing", None)
            .unwrap()
            .is_none());
    }

    /// `min_order` 返回分类最小 order，无行返回 None
    #[test]
    fn test_min_order_watermark() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssArticleRepository::new(db.connection());
        assert_eq!(repo.min_order("https://rss.com", "default").unwrap(), None);

        repo.insert(&make_article("https://rss.com", "A", 7))
            .unwrap();
        repo.insert(&make_article("https://rss.com", "B", 3))
            .unwrap();
        let mut other = make_article("https://rss.com", "C", 1);
        other.sort = "科技".to_string();
        repo.insert(&other).unwrap();

        assert_eq!(
            repo.min_order("https://rss.com", "default").unwrap(),
            Some(3),
            "只统计目标分类"
        );
        assert_eq!(repo.min_order("https://rss.com", "科技").unwrap(), Some(1));
    }
}
