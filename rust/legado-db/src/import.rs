//! Room JSON 数据导入
//!
//! 提供从 Room 导出的 JSON 数据导入到 SQLite 的能力。
//! 支持书源 (book_sources) 和书籍 (books) 数据的导入。

use rusqlite::Connection;
use serde_json::Value;

use legado_core::{LegadoError, LegadoResult};

use crate::repository::Repository;

/// 从 Room 导出的 JSON 数据导入
pub struct RoomImporter;

impl RoomImporter {
    /// 导入书源数据（JSON 数组格式）
    ///
    /// JSON 格式示例：
    /// ```json
    /// [{"bookSourceUrl":"...", "bookSourceName":"...", ...}, ...]
    /// ```
    ///
    /// 返回成功导入的记录数。
    pub fn import_book_sources(conn: &Connection, json: &str) -> LegadoResult<usize> {
        let values: Vec<Value> = serde_json::from_str(json)
            .map_err(|e| LegadoError::Database(format!("解析书源 JSON 失败: {e}")))?;

        let mut count = 0;
        for item in &values {
            let obj = item
                .as_object()
                .ok_or_else(|| LegadoError::Database("书源条目不是 JSON 对象".into()))?;

            let book_source_url = obj
                .get("bookSourceUrl")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let book_source_name = obj
                .get("bookSourceName")
                .and_then(|v| v.as_str())
                .unwrap_or("");
            let book_source_group = obj.get("bookSourceGroup").and_then(|v| v.as_str());
            let book_source_type = obj
                .get("bookSourceType")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let book_url_pattern = obj.get("bookUrlPattern").and_then(|v| v.as_str());
            let custom_order = obj.get("customOrder").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let enabled = obj.get("enabled").and_then(|v| v.as_i64()).unwrap_or(1) as i32;
            let enabled_explore = obj
                .get("enabledExplore")
                .and_then(|v| v.as_i64())
                .unwrap_or(1) as i32;
            let js_lib = obj.get("jsLib").and_then(|v| v.as_str());
            let enabled_cookie_jar = obj
                .get("enabledCookieJar")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let concurrent_rate = obj.get("concurrentRate").and_then(|v| v.as_str());
            let header = obj.get("header").and_then(|v| v.as_str());
            let login_url = obj.get("loginUrl").and_then(|v| v.as_str());
            let login_ui = obj.get("loginUi").and_then(|v| v.as_str());
            let login_check_js = obj.get("loginCheckJs").and_then(|v| v.as_str());
            let cover_decode_js = obj.get("coverDecodeJs").and_then(|v| v.as_str());
            let book_source_comment = obj.get("bookSourceComment").and_then(|v| v.as_str());
            let variable_comment = obj.get("variableComment").and_then(|v| v.as_str());
            let last_update_time = obj
                .get("lastUpdateTime")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let respond_time = obj.get("respondTime").and_then(|v| v.as_i64()).unwrap_or(0);
            let weight = obj.get("weight").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let explore_url = obj.get("exploreUrl").and_then(|v| v.as_str());
            let explore_screen = obj.get("exploreScreen").and_then(|v| v.as_str());
            let rule_explore = obj.get("ruleExplore").and_then(|v| v.as_str());
            let search_url = obj.get("searchUrl").and_then(|v| v.as_str());
            let rule_search = obj.get("ruleSearch").and_then(|v| v.as_str());
            let rule_book_info = obj.get("ruleBookInfo").and_then(|v| v.as_str());
            let rule_toc = obj.get("ruleToc").and_then(|v| v.as_str());
            let rule_content = obj.get("ruleContent").and_then(|v| v.as_str());
            let rule_review = obj.get("ruleReview").and_then(|v| v.as_str());
            let main_js = obj.get("mainJs").and_then(|v| v.as_str());
            let event_listener = obj
                .get("eventListener")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let custom_button = obj
                .get("customButton")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;

            conn.execute(
                "INSERT OR REPLACE INTO book_sources (
                    bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType,
                    bookUrlPattern, customOrder, enabled, enabledExplore,
                    jsLib, enabledCookieJar, concurrentRate, header,
                    loginUrl, loginUi, loginCheckJs, coverDecodeJs,
                    bookSourceComment, variableComment, lastUpdateTime, respondTime,
                    weight, exploreUrl, exploreScreen, ruleExplore,
                    searchUrl, ruleSearch, ruleBookInfo, ruleToc,
                    ruleContent, ruleReview, mainJs, eventListener, customButton
                ) VALUES (
                    ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10,
                    ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20,
                    ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30,
                    ?31, ?32, ?33
                )",
                rusqlite::params![
                    book_source_url,
                    book_source_name,
                    book_source_group,
                    book_source_type,
                    book_url_pattern,
                    custom_order,
                    enabled,
                    enabled_explore,
                    js_lib,
                    enabled_cookie_jar,
                    concurrent_rate,
                    header,
                    login_url,
                    login_ui,
                    login_check_js,
                    cover_decode_js,
                    book_source_comment,
                    variable_comment,
                    last_update_time,
                    respond_time,
                    weight,
                    explore_url,
                    explore_screen,
                    rule_explore,
                    search_url,
                    rule_search,
                    rule_book_info,
                    rule_toc,
                    rule_content,
                    rule_review,
                    main_js,
                    event_listener,
                    custom_button,
                ],
            )
            .map_err(|e| LegadoError::Database(format!("插入书源失败: {e}")))?;
            count += 1;
        }

        Ok(count)
    }

    /// 导入书籍数据（JSON 数组格式）
    ///
    /// JSON 格式示例：
    /// ```json
    /// [{"bookUrl":"...", "name":"...", "author":"...", ...}, ...]
    /// ```
    ///
    /// 返回成功导入的记录数。
    pub fn import_books(conn: &Connection, json: &str) -> LegadoResult<usize> {
        let values: Vec<Value> = serde_json::from_str(json)
            .map_err(|e| LegadoError::Database(format!("解析书籍 JSON 失败: {e}")))?;

        let mut count = 0;
        for item in &values {
            let obj = item
                .as_object()
                .ok_or_else(|| LegadoError::Database("书籍条目不是 JSON 对象".into()))?;

            let book_url = obj.get("bookUrl").and_then(|v| v.as_str()).unwrap_or("");
            let toc_url = obj.get("tocUrl").and_then(|v| v.as_str()).unwrap_or("");
            let origin = obj
                .get("origin")
                .and_then(|v| v.as_str())
                .unwrap_or("loc_book");
            let origin_name = obj.get("originName").and_then(|v| v.as_str()).unwrap_or("");
            let name = obj.get("name").and_then(|v| v.as_str()).unwrap_or("");
            let author = obj.get("author").and_then(|v| v.as_str()).unwrap_or("");
            let kind = obj.get("kind").and_then(|v| v.as_str());
            let custom_tag = obj.get("customTag").and_then(|v| v.as_str());
            let cover_url = obj.get("coverUrl").and_then(|v| v.as_str());
            let custom_cover_url = obj.get("customCoverUrl").and_then(|v| v.as_str());
            let intro = obj.get("intro").and_then(|v| v.as_str());
            let custom_intro = obj.get("customIntro").and_then(|v| v.as_str());
            let charset = obj.get("charset").and_then(|v| v.as_str());
            let book_type = obj.get("type").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let group = obj.get("group").and_then(|v| v.as_i64()).unwrap_or(0);
            let latest_chapter_title = obj.get("latestChapterTitle").and_then(|v| v.as_str());
            let latest_chapter_time = obj
                .get("latestChapterTime")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let last_check_time = obj
                .get("lastCheckTime")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let last_check_count = obj
                .get("lastCheckCount")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let total_chapter_num = obj
                .get("totalChapterNum")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let dur_chapter_title = obj.get("durChapterTitle").and_then(|v| v.as_str());
            let dur_chapter_index = obj
                .get("durChapterIndex")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let dur_volume_index = obj
                .get("durVolumeIndex")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let chapter_in_volume_index = obj
                .get("chapterInVolumeIndex")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let dur_chapter_pos = obj
                .get("durChapterPos")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            let dur_chapter_time = obj
                .get("durChapterTime")
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let word_count = obj.get("wordCount").and_then(|v| v.as_str());
            let can_update = obj
                .get("canUpdate")
                .and_then(|v| v.as_i64())
                .map(|v| v != 0)
                .unwrap_or(true);
            let order = obj.get("order").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let origin_order = obj.get("originOrder").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
            let variable = obj.get("variable").and_then(|v| v.as_str());
            let read_config = obj.get("readConfig").and_then(|v| v.as_str());
            let sync_time = obj.get("syncTime").and_then(|v| v.as_i64()).unwrap_or(0);

            // 台账 §5.14-3（评审 W1）：裸 INSERT OR REPLACE 改走
            // BookRepository::insert 的 upsert 链路（主键判存在→原地 UPDATE /
            // insert_replace），避免重复导入同 bookUrl 时删旧行触发 chapters
            // ON DELETE CASCADE 级联清空目录；列集统一为仓储全列（导入源
            // 缺失的 infoHtml/tocHtml/downloadUrls/coverOrigin 取模型缺省空值）。
            let read_config_obj = read_config.and_then(|s| serde_json::from_str(s).ok());
            let book = legado_core::models::Book {
                book_url: book_url.to_string(),
                toc_url: toc_url.to_string(),
                origin: origin.to_string(),
                origin_name: origin_name.to_string(),
                name: name.to_string(),
                author: author.to_string(),
                kind: kind.map(str::to_string),
                custom_tag: custom_tag.map(str::to_string),
                cover_url: cover_url.map(str::to_string),
                custom_cover_url: custom_cover_url.map(str::to_string),
                intro: intro.map(str::to_string),
                custom_intro: custom_intro.map(str::to_string),
                charset: charset.map(str::to_string),
                book_type,
                group,
                latest_chapter_title: latest_chapter_title.map(str::to_string),
                latest_chapter_time,
                last_check_time,
                last_check_count,
                total_chapter_num,
                dur_chapter_title: dur_chapter_title.map(str::to_string),
                dur_chapter_index,
                dur_volume_index,
                chapter_in_volume_index,
                dur_chapter_pos,
                dur_chapter_time,
                word_count: word_count.map(str::to_string),
                can_update,
                order,
                origin_order,
                variable: variable.map(str::to_string),
                read_config: read_config_obj,
                sync_time,
                ..legado_core::models::Book::default()
            };
            crate::BookRepository::new(conn).insert(&book)?;
            count += 1;
        }

        Ok(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::Database;

    #[test]
    fn test_import_book_sources() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();

        let json = r#"[
            {
                "bookSourceUrl": "https://example.com",
                "bookSourceName": "Test Source",
                "bookSourceGroup": "test",
                "bookSourceType": 0,
                "customOrder": 1,
                "enabled": 1,
                "enabledExplore": 1,
                "lastUpdateTime": 1000,
                "respondTime": 200,
                "weight": 10,
                "eventListener": 0,
                "customButton": 0
            }
        ]"#;

        let count = RoomImporter::import_book_sources(conn, json).unwrap();
        assert_eq!(count, 1);

        // 验证数据
        let name: String = conn
            .query_row(
                "SELECT bookSourceName FROM book_sources WHERE bookSourceUrl = 'https://example.com'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(name, "Test Source");
    }

    #[test]
    fn test_import_books() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();

        let json = r#"[
            {
                "bookUrl": "https://example.com/book/1",
                "name": "Test Book",
                "author": "Test Author",
                "type": 0,
                "group": 0,
                "totalChapterNum": 100,
                "canUpdate": 1
            }
        ]"#;

        let count = RoomImporter::import_books(conn, json).unwrap();
        assert_eq!(count, 1);

        // 验证数据
        let name: String = conn
            .query_row(
                "SELECT name FROM books WHERE bookUrl = 'https://example.com/book/1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(name, "Test Book");
    }

    /// 评审 W1：重复导入同一 bookUrl 不丢目录——upsert 改走仓储后
    /// 原地 UPDATE 不删行，不触发 chapters ON DELETE CASCADE（原裸
    /// INSERT OR REPLACE 二次导入会删旧行级联清空目录）
    #[test]
    fn test_import_books_reimport_keeps_chapters() {
        use crate::BookChapterRepository;
        use legado_core::models::BookChapter;

        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();
        let book_url = "https://example.com/book/reimport";

        let json = r#"[{"bookUrl":"https://example.com/book/reimport","name":"Imported Book","author":"A","type":0,"group":0}]"#;
        RoomImporter::import_books(conn, json).unwrap();

        // 插入 2 章模拟已有目录
        let chapters: Vec<BookChapter> = (0..2)
            .map(|i| BookChapter {
                url: format!("{book_url}/chapter/{i}"),
                title: format!("第{}章", i + 1),
                is_volume: false,
                base_url: book_url.to_string(),
                book_url: book_url.to_string(),
                index: i,
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
            })
            .collect();
        BookChapterRepository::new(conn).insert_batch(&chapters).unwrap();

        // 再次导入同 bookUrl（书名更新）：章节应保留且字段被覆盖
        let json2 = r#"[{"bookUrl":"https://example.com/book/reimport","name":"Imported Book v2","author":"A","type":0,"group":0}]"#;
        RoomImporter::import_books(conn, json2).unwrap();

        let count: i32 = conn
            .query_row(
                "SELECT COUNT(*) FROM chapters WHERE bookUrl='https://example.com/book/reimport'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 2);

        let name: String = conn
            .query_row(
                "SELECT name FROM books WHERE bookUrl='https://example.com/book/reimport'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(name, "Imported Book v2");
    }

    #[test]
    fn test_import_empty_array() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();

        let count = RoomImporter::import_book_sources(conn, "[]").unwrap();
        assert_eq!(count, 0);

        let count = RoomImporter::import_books(conn, "[]").unwrap();
        assert_eq!(count, 0);
    }

    #[test]
    fn test_import_invalid_json() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();

        let result = RoomImporter::import_book_sources(conn, "not json");
        assert!(result.is_err());
    }

    #[test]
    fn test_import_replace_existing() {
        let db = Database::open_in_memory().unwrap();
        let conn = db.connection();

        let json1 = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"Name1","bookSourceType":0,"lastUpdateTime":0,"respondTime":0,"weight":0,"eventListener":0,"customButton":0}]"#;
        let json2 = r#"[{"bookSourceUrl":"https://a.com","bookSourceName":"Name2","bookSourceType":0,"lastUpdateTime":0,"respondTime":0,"weight":0,"eventListener":0,"customButton":0}]"#;

        RoomImporter::import_book_sources(conn, json1).unwrap();
        RoomImporter::import_book_sources(conn, json2).unwrap();

        // INSERT OR REPLACE 应该替换同名记录
        let count: i32 = conn
            .query_row("SELECT COUNT(*) FROM book_sources", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);

        let name: String = conn
            .query_row(
                "SELECT bookSourceName FROM book_sources WHERE bookSourceUrl='https://a.com'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(name, "Name2");
    }
}
