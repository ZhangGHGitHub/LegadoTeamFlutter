//! 批15f：`rssListCachedArticles` 只读缓存查询用例
//!
//! 独立测试二进制（独立进程，`db_open` 只初始化一次）。覆盖：
//!
//! ```text
//! ffi::init + db_open(临时 DB) → 直连 rusqlite 灌 5 行
//!   → rss_list_cached_articles(origin, Some("科技"))
//!       ├─ 只命中本源本分类、order DESC
//!       └─ 全字段（link/pubDate/description/image/type/read/group）透传
//!   → rss_list_cached_articles(origin, None)：本源全部分类
//!   → rss_list_cached_articles(unknown, None)：空数组
//!   → 空 link 行按 legacy: 伪主键原样返回
//! ```
//!
//! 原版对照：`RssArticleDao.flowByOriginSort(origin, sortName)`
//! （`RssArticlesFragment.kt:179-218` 首屏先展示本地缓存）。

use std::path::PathBuf;

/// 临时 DB 路径（进程号后缀防并发二进制撞名；开头先清残留）
fn temp_db_path() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "legado-ffi-rss-cached-query-{}.db",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

/// 直连 DB 灌一行（`db_open` 已建表；测试只读链路不依赖仓库写路径）
#[allow(clippy::too_many_arguments)]
fn insert_row(
    conn: &rusqlite::Connection,
    origin: &str,
    sort: &str,
    title: &str,
    order: i64,
    link: Option<&str>,
    article_type: i32,
) {
    conn.execute(
        "INSERT INTO rssArticles (origin, sort, title, \"order\", link, pubDate,
         description, content, image, \"group\", \"read\", variable, type, durPos)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
        rusqlite::params![
            origin,
            sort,
            title,
            order,
            link,
            Some("2024-01-01"),
            Some("描述"),
            Option::<String>::None,
            Some("https://img.test/cover.jpg"),
            "科技分组",
            order % 2 == 0,
            Option::<String>::None,
            article_type,
            0,
        ],
    )
    .expect("灌入 rssArticles 行");
}

#[test]
fn rss_list_cached_articles_reads_db_only() {
    let db_path = temp_db_path();
    legado_ffi::ffi::ffi::init().expect("ffi init（tokio runtime）");
    legado_ffi::ffi::ffi::db_open(db_path.to_string_lossy().into_owned()).expect("db_open");

    let const_origin = "https://rss.test/feed";
    {
        let conn = rusqlite::Connection::open(&db_path).expect("直连 DB");
        insert_row(
            &conn,
            const_origin,
            "科技",
            "科技-旧",
            10,
            Some("https://rss.test/a1"),
            1,
        );
        insert_row(
            &conn,
            const_origin,
            "科技",
            "科技-新",
            20,
            Some("https://rss.test/a2"),
            2,
        );
        insert_row(
            &conn,
            const_origin,
            "文学",
            "文学",
            15,
            Some("https://rss.test/b1"),
            0,
        );
        // 空 link → 仓库层 legacy: 伪主键；此处直接写库模拟既有数据
        insert_row(
            &conn,
            const_origin,
            "科技",
            "空链接",
            5,
            Some("legacy:https://rss.test/feed:空链接:科技"),
            0,
        );
        // 其他源不受影响
        insert_row(
            &conn,
            "https://other.test/feed",
            "科技",
            "他源",
            99,
            Some("https://other.test/x"),
            0,
        );
    }

    // 指定分类：本源本分类、order DESC
    let json = legado_ffi::ffi::ffi::rss_list_cached_articles(
        const_origin.to_string(),
        Some("科技".to_string()),
    )
    .expect("缓存查询");
    let rows: Vec<serde_json::Value> = serde_json::from_str(&json).expect("JSON 数组");
    assert_eq!(rows.len(), 3, "只命中本源本分类: {json}");
    assert_eq!(rows[0]["title"], "科技-新");
    assert_eq!(rows[1]["title"], "科技-旧");
    assert_eq!(rows[2]["title"], "空链接");
    assert_eq!(rows[0]["origin"], const_origin);
    assert_eq!(rows[0]["sort"], "科技");
    assert_eq!(rows[0]["link"], "https://rss.test/a2");
    assert_eq!(rows[0]["pubDate"], "2024-01-01");
    assert_eq!(rows[0]["description"], "描述");
    assert_eq!(rows[0]["image"], "https://img.test/cover.jpg");
    assert_eq!(rows[0]["group"], "科技分组");
    assert_eq!(rows[0]["type"], 2, "类型透传（1 图片 / 2 视频）");
    assert_eq!(rows[0]["read"], true, "order 偶数行 read=true");
    assert_eq!(
        rows[2]["link"], "legacy:https://rss.test/feed:空链接:科技",
        "legacy 伪主键原样返回，由 UI 判定无链接"
    );

    // 不指定分类：本源全部分类
    let json = legado_ffi::ffi::ffi::rss_list_cached_articles(const_origin.to_string(), None)
        .expect("缓存查询（全分类）");
    let rows: Vec<serde_json::Value> = serde_json::from_str(&json).expect("JSON 数组");
    assert_eq!(rows.len(), 4, "本源全部分类: {json}");
    assert_eq!(rows[0]["title"], "科技-新", "order DESC 全局排序");

    // 未知源 → 空数组（不报错）
    let json = legado_ffi::ffi::ffi::rss_list_cached_articles(
        "https://missing.test/feed".to_string(),
        None,
    )
    .expect("未知源返回空数组");
    assert_eq!(json, "[]");

    // rssSortUrls 覆盖值（批15f）：JSON 对象保序展开
    let json = legado_ffi::ffi::ffi::rss_sort_urls(
        const_origin.to_string(),
        Some(r#"{"科技":"https://rss.test/tech","文学":"https://rss.test/lit"}"#.to_string()),
    )
    .expect("覆盖值解析");
    let sorts: Vec<serde_json::Value> = serde_json::from_str(&json).expect("JSON 数组");
    assert_eq!(sorts.len(), 2);
    assert_eq!(sorts[0]["name"], "科技", "保持书写顺序");
    assert_eq!(sorts[0]["url"], "https://rss.test/tech");
    assert_eq!(sorts[1]["name"], "文学");

    // 覆盖值为非 JSON：单条 ("", 值)
    let json = legado_ffi::ffi::ffi::rss_sort_urls(
        const_origin.to_string(),
        Some("https://rss.test/only".to_string()),
    )
    .expect("非 JSON 覆盖值");
    let sorts: Vec<serde_json::Value> = serde_json::from_str(&json).expect("JSON 数组");
    assert_eq!(sorts.len(), 1);
    assert_eq!(sorts[0]["name"], "");
    assert_eq!(sorts[0]["url"], "https://rss.test/only");

    // 空覆盖值：回退源配置（源未入库 → 单条源 URL）
    let json =
        legado_ffi::ffi::ffi::rss_sort_urls(const_origin.to_string(), Some("   ".to_string()))
            .expect("空覆盖值回退");
    let sorts: Vec<serde_json::Value> = serde_json::from_str(&json).expect("JSON 数组");
    assert_eq!(sorts.len(), 1);
    assert_eq!(sorts[0]["url"], const_origin);

    let _ = std::fs::remove_file(&db_path);
}
