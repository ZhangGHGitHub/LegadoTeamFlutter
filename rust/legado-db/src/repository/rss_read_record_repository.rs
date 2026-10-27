//! RssReadRecord Repository - rssReadRecords 表 CRUD（对齐 Room v95：主键 record）

use rusqlite::{params, Connection};

use legado_core::{LegadoError, LegadoResult};

/// RSS 已读记录行（用于列表查询返回）
///
/// 字段对齐 Room v95 `rssReadRecords` 表与原版 `RssReadRecord`
/// （`app/src/main/java/io/legado/app/data/entities/RssReadRecord.kt`）：
/// `type` 0 网页 / 1 图片 / 2 视频；`sort` 分类名；`image` 封面；
/// `pubDate` 发布时间（Room 列为 TEXT，原版实体为 `String?`）；
/// `durPos` 阅读进度。旧数据兼容：`type` / `durPos` 读出 0，
/// `sort` 读出空串，`image` / `pubDate` 读出 `None`（DB 列早已存在，无迁移）。
#[derive(Debug, Clone, serde::Serialize)]
pub struct RssReadRecordRow {
    /// 来源 URL
    pub origin: String,
    /// 文章标题
    pub title: String,
    /// 文章链接（= Room record 主键）
    pub link: Option<String>,
    /// 阅读时间（Unix 毫秒）
    pub read_time: i64,
    /// 类型：0 网页 / 1 图片 / 2 视频（DB NOT NULL DEFAULT 0）
    pub r#type: i32,
    /// 分类名（DB NOT NULL DEFAULT ''，旧行读出空串）
    pub sort: String,
    /// 封面图
    pub image: Option<String>,
    /// 发布时间（对齐 Room 列名 `pubDate`，TEXT 可空）
    #[serde(rename = "pubDate")]
    pub pub_date: Option<String>,
    /// 阅读进度（DB NOT NULL DEFAULT 0，旧行读出 0）
    #[serde(rename = "durPos")]
    pub dur_pos: i32,
}

/// 标记已读时写入的扩展字段（批20，对齐原版 `RssArticle.toRecord()`）
///
/// 全部字段可选：`None` 表示沿用 DB 缺省值（`type=0` / `sort=''` /
/// `image=NULL` / `pubDate=NULL` / `durPos=0`），旧调用行为不变。
#[derive(Debug, Clone, Default)]
pub struct RssReadRecordMeta {
    /// 类型：0 网页 / 1 图片 / 2 视频
    pub article_type: Option<i32>,
    /// 分类名
    pub sort: Option<String>,
    /// 封面图
    pub image: Option<String>,
    /// 发布时间
    pub pub_date: Option<String>,
    /// 阅读进度
    pub dur_pos: Option<i32>,
}

/// RSS 已读记录数据访问层
pub struct RssReadRecordRepository<'a> {
    conn: &'a Connection,
}

impl<'a> RssReadRecordRepository<'a> {
    pub fn new(conn: &'a Connection) -> Self {
        Self { conn }
    }

    /// 标记文章为已读（主键 record = link；无 link 时用 legacy:origin:title）
    ///
    /// 兼容入口：扩展字段全部取 DB 缺省值（`type=0` / `sort=''` /
    /// `image=NULL` / `pubDate=NULL` / `durPos=0`），旧调用行为不变；
    /// 命中既有主键时忽略写入（`INSERT OR IGNORE`），不改写扩展列与
    /// `readTime`（批20b 审查 P2-1，对齐原版 `RssReadRecordDao.insertRecord`
    /// 的 `OnConflictStrategy.IGNORE`）。
    pub fn mark_read(&self, origin: &str, title: &str, link: Option<&str>) -> LegadoResult<()> {
        self.mark_read_with(origin, title, link, &RssReadRecordMeta::default())
    }

    /// 标记文章为已读并写入扩展字段（批20，对齐原版 `RssArticle.toRecord()`）
    ///
    /// `meta` 中 `None` 字段回落到 DB 缺省值；`sort` / `durPos` 为
    /// `NOT NULL` 列，缺省分别写 `''` / `0`（与原版实体默认值一致）。
    ///
    /// 冲突语义（批20b 审查 P2-1）：同主键已存在时整行忽略
    /// （`INSERT OR IGNORE`），对齐原版 `RssReadRecordDao` 的
    /// `OnConflictStrategy.IGNORE`——原版 `toRecord()` 每次打开都带新
    /// `readTime`，但插入被 IGNORE，故 `order by readTime desc` 的排序
    /// 依据是**首次标记时间**；重复打开既不改写
    /// `type/sort/image/pubDate/durPos`，也不刷新 `readTime`。
    pub fn mark_read_with(
        &self,
        origin: &str,
        title: &str,
        link: Option<&str>,
        meta: &RssReadRecordMeta,
    ) -> LegadoResult<()> {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as i64;
        let record = match link {
            Some(l) if !l.trim().is_empty() => l.to_string(),
            _ => format!("legacy:{origin}:{title}"),
        };
        let sort = meta.sort.as_deref().unwrap_or("");
        let article_type = meta.article_type.unwrap_or(0);
        let dur_pos = meta.dur_pos.unwrap_or(0);
        self.conn
            .execute(
                "INSERT OR IGNORE INTO rssReadRecords
                 (record, title, readTime, \"read\", origin, sort, image, type, durPos, pubDate)
                 VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![
                    record,
                    title,
                    now,
                    origin,
                    sort,
                    meta.image,
                    article_type,
                    dur_pos,
                    meta.pub_date
                ],
            )
            .map_err(|e| LegadoError::Database(format!("标记已读失败: {e}")))?;
        Ok(())
    }

    /// 判断文章是否已读（按 record/link 匹配）
    pub fn is_read(&self, link: &str) -> LegadoResult<bool> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rssReadRecords WHERE record = ?1",
                params![link],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询已读状态失败: {e}")))?;
        Ok(count > 0)
    }

    /// 判断文章是否已读（按 origin + title 匹配）
    pub fn is_read_by_title(&self, origin: &str, title: &str) -> LegadoResult<bool> {
        let count: i64 = self
            .conn
            .query_row(
                "SELECT COUNT(*) FROM rssReadRecords WHERE origin = ?1 AND title = ?2",
                params![origin, title],
                |row| row.get(0),
            )
            .map_err(|e| LegadoError::Database(format!("查询已读状态失败: {e}")))?;
        Ok(count > 0)
    }

    /// 清空所有已读记录
    pub fn clear_all(&self) -> LegadoResult<()> {
        self.conn
            .execute("DELETE FROM rssReadRecords", [])
            .map_err(|e| LegadoError::Database(format!("清空已读记录失败: {e}")))?;
        Ok(())
    }

    /// 获取已读记录总数
    pub fn count(&self) -> LegadoResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM rssReadRecords", [], |row| row.get(0))
            .map_err(|e| LegadoError::Database(format!("计数查询失败: {e}")))?;
        Ok(count)
    }

    /// 获取已读记录列表（按 readTime 降序）
    pub fn list_records(&self, limit: Option<i32>) -> LegadoResult<Vec<RssReadRecordRow>> {
        let limit = limit.unwrap_or(100);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, title, record, readTime, type, sort, image, pubDate, durPos
                 FROM rssReadRecords
                 ORDER BY readTime DESC LIMIT ?1",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![limit], map_read_record_row)
            .map_err(|e| LegadoError::Database(format!("查询已读记录失败: {e}")))?;
        let records = rows
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| LegadoError::Database(format!("Row mapping failed: {e}")))?;
        Ok(records)
    }

    /// 按 origin 获取已读记录（按 readTime 降序，对齐原版 getRecordsByOrigin）
    pub fn list_records_by_origin(
        &self,
        origin: &str,
        limit: Option<i32>,
    ) -> LegadoResult<Vec<RssReadRecordRow>> {
        let limit = limit.unwrap_or(100);
        let mut stmt = self
            .conn
            .prepare(
                "SELECT origin, title, record, readTime, type, sort, image, pubDate, durPos
                 FROM rssReadRecords
                 WHERE origin = ?1 ORDER BY readTime DESC LIMIT ?2",
            )
            .map_err(|e| LegadoError::Database(format!("准备查询失败: {e}")))?;
        let rows = stmt
            .query_map(params![origin, limit], map_read_record_row)
            .map_err(|e| LegadoError::Database(format!("查询已读记录失败: {e}")))?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(|e| LegadoError::Database(format!("Row mapping failed: {e}")))
    }
}

/// 已读记录行映射（两个列表入口共用，保证列序与缺省值口径一致）
///
/// 旧数据兼容：`type` / `durPos` 为 NULL 时回落 0，`sort` 为 NULL 时
/// 回落空串，`image` / `pubDate` 保持 `None`。
fn map_read_record_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<RssReadRecordRow> {
    let record: String = row.get(2)?;
    Ok(RssReadRecordRow {
        origin: row.get(0)?,
        title: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
        link: if record.is_empty() {
            None
        } else {
            Some(record)
        },
        read_time: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
        r#type: row.get::<_, Option<i32>>(4)?.unwrap_or(0),
        sort: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
        image: row.get(6)?,
        pub_date: row.get(7)?,
        dur_pos: row.get::<_, Option<i32>>(8)?.unwrap_or(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mark_read_and_is_read() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "Article1", Some("https://link.com/1"))
            .unwrap();

        assert!(repo.is_read("https://link.com/1").unwrap());
        assert!(!repo.is_read("https://link.com/2").unwrap());
    }

    #[test]
    fn test_is_read_by_title() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "Article1", None).unwrap();

        assert!(repo
            .is_read_by_title("https://rss.com", "Article1")
            .unwrap());
        assert!(!repo
            .is_read_by_title("https://rss.com", "Article2")
            .unwrap());
    }

    #[test]
    fn test_clear_all() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "A1", Some("l1")).unwrap();
        repo.mark_read("https://rss.com", "A2", Some("l2")).unwrap();
        repo.clear_all().unwrap();

        assert_eq!(repo.count().unwrap(), 0);
        assert!(!repo.is_read("l1").unwrap());
    }

    #[test]
    fn test_multiple_reads() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        for i in 0..5 {
            repo.mark_read("https://rss.com", &format!("A{i}"), Some(&format!("l{i}")))
                .unwrap();
        }
        assert_eq!(repo.count().unwrap(), 5);
    }

    #[test]
    fn test_mark_read_no_link() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "NoLink", None).unwrap();

        assert!(repo.is_read_by_title("https://rss.com", "NoLink").unwrap());
        assert_eq!(repo.count().unwrap(), 1);
        assert!(repo.is_read("legacy:https://rss.com:NoLink").unwrap());
    }

    #[test]
    fn test_list_records() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());

        let records = repo.list_records(None).unwrap();
        assert!(records.is_empty());

        for i in 0..5 {
            repo.mark_read(
                "https://rss.com",
                &format!("Title{i}"),
                Some(&format!("link{i}")),
            )
            .unwrap();
        }

        let records = repo.list_records(None).unwrap();
        assert_eq!(records.len(), 5);

        let records = repo.list_records(Some(3)).unwrap();
        assert_eq!(records.len(), 3);

        let first = &records[0];
        assert_eq!(first.origin, "https://rss.com");
        assert!(first.link.is_some());
        assert!(first.read_time > 0);
    }

    #[test]
    fn test_list_records_by_origin() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());

        repo.mark_read("https://a.com", "A1", Some("l1")).unwrap();
        repo.mark_read("https://b.com", "B1", Some("l2")).unwrap();
        repo.mark_read("https://a.com", "A2", Some("l3")).unwrap();

        let a_records = repo.list_records_by_origin("https://a.com", None).unwrap();
        assert_eq!(a_records.len(), 2);
        assert!(a_records.iter().all(|r| r.origin == "https://a.com"));

        let b_records = repo.list_records_by_origin("https://b.com", None).unwrap();
        assert_eq!(b_records.len(), 1);
        assert_eq!(b_records[0].title, "B1");
    }

    /// 批20：扩展字段写读回环（type/sort/image/pubDate/durPos）
    #[test]
    fn test_mark_read_with_full_fields_roundtrip() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());

        repo.mark_read_with(
            "https://rss.com",
            "图片文章",
            Some("link-img"),
            &RssReadRecordMeta {
                article_type: Some(1),
                sort: Some("图片分类".to_string()),
                image: Some("https://img.test/1.jpg".to_string()),
                pub_date: Some("2026-10-27".to_string()),
                dur_pos: Some(42),
            },
        )
        .unwrap();
        // 未传字段回落 DB 默认值；本例仅 type 显式（其余 sort=''、image/pubDate=NULL、durPos=0）
        repo.mark_read_with(
            "https://rss.com",
            "视频文章",
            Some("link-video"),
            &RssReadRecordMeta {
                article_type: Some(2),
                ..Default::default()
            },
        )
        .unwrap();

        let all = repo.list_records(None).unwrap();
        assert_eq!(all.len(), 2);
        let img = all
            .iter()
            .find(|r| r.link.as_deref() == Some("link-img"))
            .expect("图片记录应存在");
        assert_eq!(img.r#type, 1);
        assert_eq!(img.sort, "图片分类");
        assert_eq!(img.image.as_deref(), Some("https://img.test/1.jpg"));
        assert_eq!(img.pub_date.as_deref(), Some("2026-10-27"));
        assert_eq!(img.dur_pos, 42);

        let video = all
            .iter()
            .find(|r| r.link.as_deref() == Some("link-video"))
            .expect("视频记录应存在");
        assert_eq!(video.r#type, 2);
        assert_eq!(video.sort, "");
        assert!(video.image.is_none());
        assert!(video.pub_date.is_none());
        assert_eq!(video.dur_pos, 0);

        // 按源入口列集合/映射口径与全量入口一致
        let by_origin = repo
            .list_records_by_origin("https://rss.com", None)
            .unwrap();
        assert_eq!(by_origin.len(), 2);
        let img_by_origin = by_origin
            .iter()
            .find(|r| r.link.as_deref() == Some("link-img"))
            .expect("按源查询应返回图片记录");
        assert_eq!(img_by_origin.r#type, 1);
        assert_eq!(img_by_origin.sort, "图片分类");
        assert_eq!(
            img_by_origin.image.as_deref(),
            Some("https://img.test/1.jpg")
        );
        assert_eq!(img_by_origin.pub_date.as_deref(), Some("2026-10-27"));
        assert_eq!(img_by_origin.dur_pos, 42);

        // serde JSON 键名锁定：type / pubDate / durPos（对齐原版 Room 列名），
        // read_time 保持既有 snake_case（Dart 侧 JsonKey 依赖）。
        let json = serde_json::to_string(&all).unwrap();
        assert!(json.contains("\"type\":1"));
        assert!(json.contains("\"sort\":\"图片分类\""));
        assert!(json.contains("\"pubDate\":\"2026-10-27\""));
        assert!(json.contains("\"durPos\":42"));
        assert!(json.contains("\"read_time\":"));
    }

    /// 批20：旧数据（可空列 NULL、NOT NULL 列取列默认值）读出默认口径
    #[test]
    fn test_legacy_null_columns_read_defaults() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        // 手工插入旧数据形态：image/pubDate 显式 NULL，type/sort/durPos 走列默认值
        db.connection()
            .execute(
                "INSERT INTO rssReadRecords
                 (record, title, readTime, \"read\", origin, image, pubDate)
                 VALUES ('legacy-link', 'Legacy', 123, 1, 'https://rss.com', NULL, NULL)",
                [],
            )
            .unwrap();

        let records = repo.list_records(None).unwrap();
        assert_eq!(records.len(), 1);
        let row = &records[0];
        assert_eq!(row.link.as_deref(), Some("legacy-link"));
        assert_eq!(row.r#type, 0);
        assert_eq!(row.sort, "");
        assert!(row.image.is_none());
        assert!(row.pub_date.is_none());
        assert_eq!(row.dur_pos, 0);

        let by_origin = repo
            .list_records_by_origin("https://rss.com", None)
            .unwrap();
        assert_eq!(by_origin.len(), 1);
        assert_eq!(by_origin[0].r#type, 0);
        assert_eq!(by_origin[0].sort, "");
        assert!(by_origin[0].image.is_none());
        assert!(by_origin[0].pub_date.is_none());
        assert_eq!(by_origin[0].dur_pos, 0);
    }

    /// 批20：兼容入口（3 参 mark_read）保持旧写入口径
    #[test]
    fn test_mark_read_legacy_signature_keeps_defaults() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read("https://rss.com", "Old", Some("old-link"))
            .unwrap();

        let records = repo.list_records(None).unwrap();
        assert_eq!(records.len(), 1);
        let row = &records[0];
        assert_eq!(row.r#type, 0);
        assert_eq!(row.sort, "");
        assert!(row.image.is_none());
        assert!(row.pub_date.is_none());
        assert_eq!(row.dur_pos, 0);
    }

    /// 批20b 审查 P2-1：全列写入后，兼容入口同主键再标记不重置扩展列与
    /// readTime（原版 `RssReadRecordDao.insertRecord` 为 `OnConflictStrategy.IGNORE`）
    #[test]
    fn test_mark_read_ignores_existing_full_record() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read_with(
            "https://rss.com",
            "图片文章",
            Some("link-img"),
            &RssReadRecordMeta {
                article_type: Some(1),
                sort: Some("图片分类".to_string()),
                image: Some("https://img.test/1.jpg".to_string()),
                pub_date: Some("2026-10-27".to_string()),
                dur_pos: Some(42),
            },
        )
        .unwrap();
        let before = repo.list_records(None).unwrap();
        assert_eq!(before.len(), 1);
        let read_time = before[0].read_time;

        // 拉开时间窗口：若实现是 REPLACE，readTime 必然变化
        std::thread::sleep(std::time::Duration::from_millis(5));
        repo.mark_read("https://rss.com", "图片文章", Some("link-img"))
            .unwrap();

        let after = repo.list_records(None).unwrap();
        assert_eq!(after.len(), 1, "同主键不应新增行");
        let row = &after[0];
        assert_eq!(row.read_time, read_time, "重复标记不刷新 readTime");
        assert_eq!(row.r#type, 1, "扩展列不应被默认值重置");
        assert_eq!(row.sort, "图片分类");
        assert_eq!(row.image.as_deref(), Some("https://img.test/1.jpg"));
        assert_eq!(row.pub_date.as_deref(), Some("2026-10-27"));
        assert_eq!(row.dur_pos, 42);
    }

    /// 批20b 审查 P2-1：`mark_read_with` 重复标记同样整行 IGNORE
    /// （首次标记决定 readTime，对齐原版 `toRecord()` + IGNORE 插入链）
    #[test]
    fn test_mark_read_with_ignores_existing_record() {
        let db = crate::init_in_memory_database().unwrap();
        let repo = RssReadRecordRepository::new(db.connection());
        repo.mark_read_with(
            "https://rss.com",
            "首次标题",
            Some("dup-link"),
            &RssReadRecordMeta {
                article_type: Some(1),
                sort: Some("首次分类".to_string()),
                image: Some("https://img.test/1.jpg".to_string()),
                pub_date: Some("2026-10-27".to_string()),
                dur_pos: Some(7),
            },
        )
        .unwrap();
        let before = repo.list_records(None).unwrap();
        assert_eq!(before.len(), 1);
        let read_time = before[0].read_time;

        std::thread::sleep(std::time::Duration::from_millis(5));
        repo.mark_read_with(
            "https://rss.com",
            "再次标题",
            Some("dup-link"),
            &RssReadRecordMeta {
                article_type: Some(2),
                sort: Some("再次分类".to_string()),
                image: Some("https://img.test/2.jpg".to_string()),
                pub_date: Some("2027-01-01".to_string()),
                dur_pos: Some(99),
            },
        )
        .unwrap();

        let after = repo.list_records(None).unwrap();
        assert_eq!(after.len(), 1, "同主键不应新增行");
        let row = &after[0];
        assert_eq!(row.read_time, read_time);
        assert_eq!(row.title, "首次标题");
        assert_eq!(row.r#type, 1);
        assert_eq!(row.sort, "首次分类");
        assert_eq!(row.image.as_deref(), Some("https://img.test/1.jpg"));
        assert_eq!(row.pub_date.as_deref(), Some("2026-10-27"));
        assert_eq!(row.dur_pos, 7);
    }
}
