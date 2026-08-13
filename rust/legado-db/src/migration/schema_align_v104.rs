//! Migration103To104 — 台账「schema v102 结构对齐专项」落地
//!
//! 版本号说明：文档称「schema v102」，但代码链已占用 v102（cached_chapters）
//! 与 v103（book_sources.variable），故本专项以 **v103→v104** 落地。
//!
//! 变更（幂等：按主键/列形态检测，已对齐则跳过）：
//! 1. rssArticles：主键 (origin,title) → (origin,link,sort)，link NOT NULL
//! 2. rssStars：主键 (origin,title) → (origin,link)，link NOT NULL
//! 3. readRecord：主键 (bookName) → (deviceId,bookName)；保留 author 超集列
//! 4. rssReadRecords：重建为 Room v95 结构（主键 record）
//! 5. http_tts → httpTTS：Room v95 列集 + isEnabled 超集
//! 6. rssSources：去掉 enableCookieJar，合并入 enabledCookieJar
//! 7. search_keywords：id/keyword/time → word/usage/lastUseTime
//! 8. coverRules：确保表存在（纳入迁移体系）

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

use crate::migration::{column_exists, primary_key_columns, table_exists, Migration};
use crate::schema::{
    CREATE_COVER_RULES, CREATE_HTTP_TTS, CREATE_READ_RECORD, CREATE_RSS_ARTICLES,
    CREATE_RSS_READ_RECORDS, CREATE_RSS_STARS, CREATE_SEARCH_KEYWORDS,
};

/// 从 v103 升级到 v104（台账 schema v102 结构对齐专项）
pub struct Migration103To104;

impl Migration for Migration103To104 {
    fn from_version(&self) -> u32 {
        103
    }
    fn to_version(&self) -> u32 {
        104
    }
    fn description(&self) -> &str {
        "结构对齐 Room v95：rssArticles/rssStars/readRecord 主键重建 + rssReadRecords/httpTTS/rssSources/search_keywords + coverRules 入体系"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        rebuild_rss_articles(conn)?;
        rebuild_rss_stars(conn)?;
        rebuild_read_record(conn)?;
        rebuild_rss_read_records(conn)?;
        migrate_http_tts(conn)?;
        rebuild_rss_sources_drop_enable_cookie_jar(conn)?;
        rebuild_search_keywords(conn)?;
        // coverRules：仅确保存在（历史游离建表）
        conn.execute_batch(CREATE_COVER_RULES)
            .map_err(|e| LegadoError::Database(format!("确保 coverRules 表失败: {e}")))?;
        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration103To104: table rebuilds are one-way".into(),
        ))
    }
}

fn rebuild_rss_articles(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "rssArticles")? {
        conn.execute_batch(CREATE_RSS_ARTICLES)
            .map_err(|e| LegadoError::Database(format!("创建 rssArticles 失败: {e}")))?;
        return Ok(());
    }
    let pk = primary_key_columns(conn, "rssArticles")?;
    if pk == ["origin", "link", "sort"] {
        return Ok(());
    }

    conn.execute_batch(
        "CREATE TABLE rssArticles_v104 (
            origin TEXT NOT NULL,
            sort TEXT NOT NULL,
            title TEXT NOT NULL,
            \"order\" INTEGER NOT NULL,
            link TEXT NOT NULL,
            pubDate TEXT,
            description TEXT,
            content TEXT,
            image TEXT,
            \"group\" TEXT NOT NULL DEFAULT '默认分组',
            \"read\" INTEGER NOT NULL DEFAULT 0,
            variable TEXT,
            type INTEGER NOT NULL DEFAULT 0,
            durPos INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(origin, link, sort)
        );",
    )
    .map_err(|e| LegadoError::Database(format!("创建 rssArticles_v104 失败: {e}")))?;

    let sort_e = expr_or(conn, "rssArticles", "sort", "''")?;
    let has_order = column_exists(conn, "rssArticles", "order")?;
    let order_e = if has_order {
        "COALESCE(\"order\", 0)".to_string()
    } else {
        "0".to_string()
    };
    // 注意：ORDER BY 常量数字会被 SQLite 当成列序号；缺列时按 rowid
    let order_by = if has_order {
        "\"order\" DESC".to_string()
    } else {
        "rowid DESC".to_string()
    };
    let link_e = if column_exists(conn, "rssArticles", "link")? {
        format!(
            "CASE WHEN link IS NULL OR trim(link) = '' THEN 'legacy:' || origin || ':' || title || ':' || {sort_e} ELSE link END"
        )
    } else {
        format!("'legacy:' || origin || ':' || title || ':' || {sort_e}")
    };
    let pub_e = expr_or_null(conn, "rssArticles", "pubDate")?;
    let desc_e = expr_or_null(conn, "rssArticles", "description")?;
    let content_e = expr_or_null(conn, "rssArticles", "content")?;
    let image_e = expr_or_null(conn, "rssArticles", "image")?;
    let group_e = expr_or(conn, "rssArticles", "\"group\"", "'默认分组'")?;
    let read_e = expr_or(conn, "rssArticles", "\"read\"", "0")?;
    let var_e = expr_or_null(conn, "rssArticles", "variable")?;
    let type_e = expr_or(conn, "rssArticles", "type", "0")?;
    let dur_e = expr_or(conn, "rssArticles", "durPos", "0")?;

    // ORDER BY + INSERT OR IGNORE：同主键保留较新行
    let sql = format!(
        "INSERT OR IGNORE INTO rssArticles_v104
            (origin, sort, title, \"order\", link, pubDate, description, content, image,
             \"group\", \"read\", variable, type, durPos)
         SELECT
            origin, {sort_e}, title, {order_e}, {link_e},
            {pub_e}, {desc_e}, {content_e}, {image_e},
            {group_e}, {read_e}, {var_e}, {type_e}, {dur_e}
         FROM rssArticles
         ORDER BY {order_by};"
    );
    conn.execute_batch(&sql)
        .map_err(|e| LegadoError::Database(format!("搬迁 rssArticles 失败: {e}")))?;

    conn.execute_batch(
        "DROP TABLE rssArticles;
         ALTER TABLE rssArticles_v104 RENAME TO rssArticles;",
    )
    .map_err(|e| LegadoError::Database(format!("替换 rssArticles 失败: {e}")))?;
    Ok(())
}

fn expr_or(conn: &Connection, table: &str, column: &str, default: &str) -> LegadoResult<String> {
    if column_exists(conn, table, column)? {
        Ok(format!("COALESCE({column}, {default})"))
    } else {
        Ok(default.to_string())
    }
}

fn expr_or_null(conn: &Connection, table: &str, column: &str) -> LegadoResult<String> {
    if column_exists(conn, table, column)? {
        Ok(column.to_string())
    } else {
        Ok("NULL".to_string())
    }
}

fn rebuild_rss_stars(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "rssStars")? {
        conn.execute_batch(CREATE_RSS_STARS)
            .map_err(|e| LegadoError::Database(format!("创建 rssStars 失败: {e}")))?;
        return Ok(());
    }
    let pk = primary_key_columns(conn, "rssStars")?;
    if pk == ["origin", "link"] {
        return Ok(());
    }

    conn.execute_batch(
        "CREATE TABLE rssStars_v104 (
            origin TEXT NOT NULL,
            sort TEXT NOT NULL,
            title TEXT NOT NULL,
            starTime INTEGER NOT NULL,
            link TEXT NOT NULL,
            pubDate TEXT,
            description TEXT,
            content TEXT,
            image TEXT,
            \"group\" TEXT NOT NULL DEFAULT '默认分组',
            variable TEXT,
            type INTEGER NOT NULL DEFAULT 0,
            durPos INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(origin, link)
        );",
    )
    .map_err(|e| LegadoError::Database(format!("创建 rssStars_v104 失败: {e}")))?;

    let sort_e = expr_or(conn, "rssStars", "sort", "''")?;
    let has_star = column_exists(conn, "rssStars", "starTime")?;
    let star_e = if has_star {
        "COALESCE(starTime, 0)".to_string()
    } else {
        "0".to_string()
    };
    let order_by = if has_star {
        "starTime DESC".to_string()
    } else {
        "rowid DESC".to_string()
    };
    let link_e = if column_exists(conn, "rssStars", "link")? {
        format!(
            "CASE WHEN link IS NULL OR trim(link) = '' THEN 'legacy:' || origin || ':' || title || ':' || {sort_e} ELSE link END"
        )
    } else {
        format!("'legacy:' || origin || ':' || title || ':' || {sort_e}")
    };
    let pub_e = expr_or_null(conn, "rssStars", "pubDate")?;
    let desc_e = expr_or_null(conn, "rssStars", "description")?;
    let content_e = expr_or_null(conn, "rssStars", "content")?;
    let image_e = expr_or_null(conn, "rssStars", "image")?;
    let group_e = expr_or(conn, "rssStars", "\"group\"", "'默认分组'")?;
    let var_e = expr_or_null(conn, "rssStars", "variable")?;
    let type_e = expr_or(conn, "rssStars", "type", "0")?;
    let dur_e = expr_or(conn, "rssStars", "durPos", "0")?;

    let sql = format!(
        "INSERT OR IGNORE INTO rssStars_v104
            (origin, sort, title, starTime, link, pubDate, description, content, image,
             \"group\", variable, type, durPos)
         SELECT
            origin, {sort_e}, title, {star_e}, {link_e},
            {pub_e}, {desc_e}, {content_e}, {image_e},
            {group_e}, {var_e}, {type_e}, {dur_e}
         FROM rssStars
         ORDER BY {order_by};"
    );
    conn.execute_batch(&sql)
        .map_err(|e| LegadoError::Database(format!("搬迁 rssStars 失败: {e}")))?;

    conn.execute_batch(
        "DROP TABLE rssStars;
         ALTER TABLE rssStars_v104 RENAME TO rssStars;",
    )
    .map_err(|e| LegadoError::Database(format!("替换 rssStars 失败: {e}")))?;
    Ok(())
}

fn rebuild_read_record(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "readRecord")? {
        conn.execute_batch(CREATE_READ_RECORD)
            .map_err(|e| LegadoError::Database(format!("创建 readRecord 失败: {e}")))?;
        return Ok(());
    }
    let pk = primary_key_columns(conn, "readRecord")?;
    if pk == ["deviceId", "bookName"] {
        return Ok(());
    }

    conn.execute_batch(
        "CREATE TABLE readRecord_v104 (
            deviceId TEXT NOT NULL DEFAULT '',
            bookName TEXT NOT NULL,
            author TEXT NOT NULL DEFAULT '',
            readTime INTEGER NOT NULL DEFAULT 0,
            lastRead INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(deviceId, bookName)
        );",
    )
    .map_err(|e| LegadoError::Database(format!("创建 readRecord_v104 失败: {e}")))?;

    // 同 (deviceId, bookName) 保留 readTime 最大行；缺列用默认值
    let has_device = column_exists(conn, "readRecord", "deviceId")?;
    let has_author = column_exists(conn, "readRecord", "author")?;
    let has_last = column_exists(conn, "readRecord", "lastRead")?;
    let device_expr = if has_device {
        "COALESCE(deviceId, '')"
    } else {
        "''"
    };
    let author_expr = if has_author {
        "COALESCE(author, '')"
    } else {
        "''"
    };
    let last_expr = if has_last {
        "COALESCE(lastRead, 0)"
    } else {
        "0"
    };

    let sql = format!(
        "INSERT OR IGNORE INTO readRecord_v104 (deviceId, bookName, author, readTime, lastRead)
         SELECT {device_expr}, bookName, {author_expr}, readTime, {last_expr}
         FROM readRecord
         ORDER BY readTime DESC;"
    );
    conn.execute_batch(&sql)
        .map_err(|e| LegadoError::Database(format!("搬迁 readRecord 失败: {e}")))?;

    conn.execute_batch(
        "DROP TABLE readRecord;
         ALTER TABLE readRecord_v104 RENAME TO readRecord;",
    )
    .map_err(|e| LegadoError::Database(format!("替换 readRecord 失败: {e}")))?;
    Ok(())
}

fn rebuild_rss_read_records(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "rssReadRecords")? {
        conn.execute_batch(CREATE_RSS_READ_RECORDS)
            .map_err(|e| LegadoError::Database(format!("创建 rssReadRecords 失败: {e}")))?;
        return Ok(());
    }
    // 已对齐：存在 record 主键列且无旧 id 自增主键形态
    let pk = primary_key_columns(conn, "rssReadRecords")?;
    if pk == ["record"] {
        return Ok(());
    }

    conn.execute_batch(
        "CREATE TABLE rssReadRecords_v104 (
            record TEXT NOT NULL,
            title TEXT,
            readTime INTEGER,
            \"read\" INTEGER NOT NULL DEFAULT 1,
            origin TEXT NOT NULL DEFAULT '',
            sort TEXT NOT NULL DEFAULT '',
            image TEXT,
            type INTEGER NOT NULL DEFAULT 0,
            durPos INTEGER NOT NULL DEFAULT 0,
            pubDate TEXT,
            PRIMARY KEY(record)
        );",
    )
    .map_err(|e| LegadoError::Database(format!("创建 rssReadRecords_v104 失败: {e}")))?;

    let has_link = column_exists(conn, "rssReadRecords", "link")?;
    let has_id = column_exists(conn, "rssReadRecords", "id")?;
    // record = link；空 link 回退 legacy:origin:title[:id]
    let record_expr = if has_link && has_id {
        "CASE
            WHEN link IS NOT NULL AND trim(link) != '' THEN link
            ELSE 'legacy:' || COALESCE(origin,'') || ':' || COALESCE(title,'') || ':' || CAST(id AS TEXT)
         END"
    } else if has_link {
        "CASE
            WHEN link IS NOT NULL AND trim(link) != '' THEN link
            ELSE 'legacy:' || COALESCE(origin,'') || ':' || COALESCE(title,'')
         END"
    } else if has_id {
        "'legacy:' || COALESCE(origin,'') || ':' || COALESCE(title,'') || ':' || CAST(id AS TEXT)"
    } else {
        "'legacy:' || COALESCE(origin,'') || ':' || COALESCE(title,'')"
    };

    let sql = format!(
        "INSERT OR IGNORE INTO rssReadRecords_v104
            (record, title, readTime, \"read\", origin, sort, image, type, durPos, pubDate)
         SELECT
            {record_expr},
            title,
            readTime,
            1,
            COALESCE(origin, ''),
            '',
            NULL,
            0,
            0,
            NULL
         FROM rssReadRecords
         ORDER BY readTime DESC;"
    );
    conn.execute_batch(&sql)
        .map_err(|e| LegadoError::Database(format!("搬迁 rssReadRecords 失败: {e}")))?;

    conn.execute_batch(
        "DROP TABLE rssReadRecords;
         ALTER TABLE rssReadRecords_v104 RENAME TO rssReadRecords;
         CREATE INDEX IF NOT EXISTS index_rssReadRecords_origin ON rssReadRecords (origin);",
    )
    .map_err(|e| LegadoError::Database(format!("替换 rssReadRecords 失败: {e}")))?;
    Ok(())
}

fn migrate_http_tts(conn: &Connection) -> LegadoResult<()> {
    let has_new = table_exists(conn, "httpTTS")?;
    let has_old = table_exists(conn, "http_tts")?;

    if has_new && column_exists(conn, "httpTTS", "contentType")? && !has_old {
        // 已是目标形态；确保超集列
        add_is_enabled_if_needed(conn)?;
        return Ok(());
    }

    if !has_new {
        conn.execute_batch(CREATE_HTTP_TTS)
            .map_err(|e| LegadoError::Database(format!("创建 httpTTS 失败: {e}")))?;
    } else {
        // 旧 ensure_tables 可能建了不完整 httpTTS，补齐缺列
        ensure_http_tts_columns(conn)?;
    }

    if has_old {
        // 从 http_tts 搬迁；冲突保留已有 httpTTS 行
        let has_content_type = column_exists(conn, "http_tts", "content_type")?;
        let has_created = column_exists(conn, "http_tts", "created_at")?;
        let has_enabled = column_exists(conn, "http_tts", "is_enabled")?;
        let ct = if has_content_type {
            "content_type"
        } else {
            "NULL"
        };
        let lu = if has_created { "created_at" } else { "0" };
        let en = if has_enabled {
            "COALESCE(is_enabled, 1)"
        } else {
            "1"
        };
        let sql = format!(
            "INSERT OR IGNORE INTO httpTTS
                (id, name, url, contentType, pauseDuration, concurrentRate,
                 loginUrl, loginUi, header, jsLib, enabledCookieJar, loginCheckJs,
                 lastUpdateTime, isEnabled)
             SELECT
                id, name, url, {ct}, 0, '0',
                NULL, NULL, NULL, NULL, 0, NULL,
                {lu}, {en}
             FROM http_tts;"
        );
        conn.execute_batch(&sql)
            .map_err(|e| LegadoError::Database(format!("搬迁 http_tts→httpTTS 失败: {e}")))?;
        conn.execute_batch("DROP TABLE http_tts;")
            .map_err(|e| LegadoError::Database(format!("删除旧 http_tts 失败: {e}")))?;
    }

    add_is_enabled_if_needed(conn)?;
    Ok(())
}

fn ensure_http_tts_columns(conn: &Connection) -> LegadoResult<()> {
    use crate::migration::add_column_if_not_exists;
    add_column_if_not_exists(conn, "httpTTS", "contentType", "TEXT")?;
    add_column_if_not_exists(conn, "httpTTS", "pauseDuration", "INTEGER NOT NULL DEFAULT 0")?;
    add_column_if_not_exists(conn, "httpTTS", "concurrentRate", "TEXT DEFAULT '0'")?;
    add_column_if_not_exists(conn, "httpTTS", "loginUrl", "TEXT")?;
    add_column_if_not_exists(conn, "httpTTS", "loginUi", "TEXT")?;
    add_column_if_not_exists(conn, "httpTTS", "header", "TEXT")?;
    add_column_if_not_exists(conn, "httpTTS", "jsLib", "TEXT")?;
    add_column_if_not_exists(conn, "httpTTS", "enabledCookieJar", "INTEGER DEFAULT 0")?;
    add_column_if_not_exists(conn, "httpTTS", "loginCheckJs", "TEXT")?;
    add_column_if_not_exists(
        conn,
        "httpTTS",
        "lastUpdateTime",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    add_is_enabled_if_needed(conn)?;
    Ok(())
}

fn add_is_enabled_if_needed(conn: &Connection) -> LegadoResult<()> {
    use crate::migration::add_column_if_not_exists;
    if table_exists(conn, "httpTTS")? {
        add_column_if_not_exists(conn, "httpTTS", "isEnabled", "INTEGER NOT NULL DEFAULT 1")?;
    }
    Ok(())
}

fn rebuild_rss_sources_drop_enable_cookie_jar(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "rssSources")? {
        return Ok(());
    }
    if !column_exists(conn, "rssSources", "enableCookieJar")? {
        return Ok(());
    }

    // 读取列清单，重建时去掉 enableCookieJar，合并 cookie jar 语义
    conn.execute_batch(
        "CREATE TABLE rssSources_v104 (
            sourceUrl TEXT NOT NULL,
            sourceName TEXT NOT NULL,
            sourceIcon TEXT NOT NULL DEFAULT '',
            sourceGroup TEXT,
            sourceComment TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            sortUrl TEXT,
            customOrder INTEGER NOT NULL DEFAULT 0,
            lastUpdateTime INTEGER NOT NULL DEFAULT 0,
            header TEXT,
            enableJs INTEGER NOT NULL DEFAULT 1,
            loadWithBaseUrl INTEGER NOT NULL DEFAULT 1,
            variableComment TEXT,
            loginUrl TEXT,
            loginUi TEXT,
            loginCheckJs TEXT,
            coverDecodeJs TEXT,
            concurrentRate TEXT,
            ruleArticles TEXT,
            ruleNextPage TEXT,
            ruleTitle TEXT,
            rulePubDate TEXT,
            ruleDescription TEXT,
            ruleImage TEXT,
            ruleLink TEXT,
            ruleContent TEXT,
            style TEXT,
            articleStyle INTEGER NOT NULL DEFAULT 0,
            singleUrl INTEGER NOT NULL DEFAULT 0,
            jsLib TEXT,
            enabledCookieJar INTEGER DEFAULT 0,
            contentWhitelist TEXT,
            contentBlacklist TEXT,
            shouldOverrideUrlLoading TEXT,
            injectJs TEXT,
            preloadJs TEXT,
            startHtml TEXT,
            startStyle TEXT,
            startJs TEXT,
            showWebLog INTEGER NOT NULL DEFAULT 0,
            type INTEGER NOT NULL DEFAULT 0,
            preload INTEGER NOT NULL DEFAULT 0,
            cacheFirst INTEGER NOT NULL DEFAULT 0,
            searchUrl TEXT,
            PRIMARY KEY(sourceUrl)
        );",
    )
    .map_err(|e| LegadoError::Database(format!("创建 rssSources_v104 失败: {e}")))?;

    // 动态探测可选列，避免旧库缺列
    let col = |name: &str| -> LegadoResult<bool> { column_exists(conn, "rssSources", name) };
    let or_null = |present: bool, name: &str| {
        if present {
            name.to_string()
        } else {
            "NULL".to_string()
        }
    };
    let or_default = |present: bool, name: &str, default: &str| {
        if present {
            format!("COALESCE({name}, {default})")
        } else {
            default.to_string()
        }
    };

    let enabled_cookie = if col("enabledCookieJar")? && col("enableCookieJar")? {
        "CASE WHEN COALESCE(enabledCookieJar,0)!=0 OR COALESCE(enableCookieJar,0)!=0 THEN 1 ELSE 0 END"
            .to_string()
    } else if col("enabledCookieJar")? {
        "COALESCE(enabledCookieJar, 0)".to_string()
    } else if col("enableCookieJar")? {
        "COALESCE(enableCookieJar, 0)".to_string()
    } else {
        "0".to_string()
    };

    let sql = format!(
        "INSERT INTO rssSources_v104 (
            sourceUrl, sourceName, sourceIcon, sourceGroup, sourceComment, enabled,
            sortUrl, customOrder, lastUpdateTime, header, enableJs, loadWithBaseUrl,
            variableComment, loginUrl, loginUi, loginCheckJs, coverDecodeJs, concurrentRate,
            ruleArticles, ruleNextPage, ruleTitle, rulePubDate, ruleDescription, ruleImage,
            ruleLink, ruleContent, style, articleStyle, singleUrl, jsLib, enabledCookieJar,
            contentWhitelist, contentBlacklist, shouldOverrideUrlLoading, injectJs, preloadJs,
            startHtml, startStyle, startJs, showWebLog, type, preload, cacheFirst, searchUrl
         ) SELECT
            sourceUrl,
            sourceName,
            {source_icon},
            {source_group},
            {source_comment},
            {enabled},
            {sort_url},
            {custom_order},
            {last_update},
            {header},
            {enable_js},
            {load_base},
            {variable_comment},
            {login_url},
            {login_ui},
            {login_check},
            {cover_decode},
            {concurrent},
            {rule_articles},
            {rule_next},
            {rule_title},
            {rule_pub},
            {rule_desc},
            {rule_image},
            {rule_link},
            {rule_content},
            {style},
            {article_style},
            {single_url},
            {js_lib},
            {enabled_cookie},
            {content_white},
            {content_black},
            {should_override},
            {inject_js},
            {preload_js},
            {start_html},
            {start_style},
            {start_js},
            {show_web_log},
            {rss_type},
            {preload},
            {cache_first},
            {search_url}
         FROM rssSources;",
        source_icon = or_default(col("sourceIcon")?, "sourceIcon", "''"),
        source_group = or_null(col("sourceGroup")?, "sourceGroup"),
        source_comment = or_null(col("sourceComment")?, "sourceComment"),
        enabled = or_default(col("enabled")?, "enabled", "1"),
        sort_url = or_null(col("sortUrl")?, "sortUrl"),
        custom_order = or_default(col("customOrder")?, "customOrder", "0"),
        last_update = or_default(col("lastUpdateTime")?, "lastUpdateTime", "0"),
        header = or_null(col("header")?, "header"),
        enable_js = or_default(col("enableJs")?, "enableJs", "1"),
        load_base = or_default(col("loadWithBaseUrl")?, "loadWithBaseUrl", "1"),
        variable_comment = or_null(col("variableComment")?, "variableComment"),
        login_url = or_null(col("loginUrl")?, "loginUrl"),
        login_ui = or_null(col("loginUi")?, "loginUi"),
        login_check = or_null(col("loginCheckJs")?, "loginCheckJs"),
        cover_decode = or_null(col("coverDecodeJs")?, "coverDecodeJs"),
        concurrent = or_null(col("concurrentRate")?, "concurrentRate"),
        rule_articles = or_null(col("ruleArticles")?, "ruleArticles"),
        rule_next = or_null(col("ruleNextPage")?, "ruleNextPage"),
        rule_title = or_null(col("ruleTitle")?, "ruleTitle"),
        rule_pub = or_null(col("rulePubDate")?, "rulePubDate"),
        rule_desc = or_null(col("ruleDescription")?, "ruleDescription"),
        rule_image = or_null(col("ruleImage")?, "ruleImage"),
        rule_link = or_null(col("ruleLink")?, "ruleLink"),
        rule_content = or_null(col("ruleContent")?, "ruleContent"),
        style = or_null(col("style")?, "style"),
        article_style = or_default(col("articleStyle")?, "articleStyle", "0"),
        single_url = or_default(col("singleUrl")?, "singleUrl", "0"),
        js_lib = or_null(col("jsLib")?, "jsLib"),
        enabled_cookie = enabled_cookie,
        content_white = or_null(col("contentWhitelist")?, "contentWhitelist"),
        content_black = or_null(col("contentBlacklist")?, "contentBlacklist"),
        should_override = or_null(col("shouldOverrideUrlLoading")?, "shouldOverrideUrlLoading"),
        inject_js = or_null(col("injectJs")?, "injectJs"),
        preload_js = or_null(col("preloadJs")?, "preloadJs"),
        start_html = or_null(col("startHtml")?, "startHtml"),
        start_style = or_null(col("startStyle")?, "startStyle"),
        start_js = or_null(col("startJs")?, "startJs"),
        show_web_log = or_default(col("showWebLog")?, "showWebLog", "0"),
        rss_type = or_default(col("type")?, "type", "0"),
        preload = or_default(col("preload")?, "preload", "0"),
        cache_first = or_default(col("cacheFirst")?, "cacheFirst", "0"),
        search_url = or_null(col("searchUrl")?, "searchUrl"),
    );

    conn.execute_batch(&sql)
        .map_err(|e| LegadoError::Database(format!("搬迁 rssSources 失败: {e}")))?;

    conn.execute_batch(
        "DROP TABLE rssSources;
         ALTER TABLE rssSources_v104 RENAME TO rssSources;",
    )
    .map_err(|e| LegadoError::Database(format!("替换 rssSources 失败: {e}")))?;
    Ok(())
}

fn rebuild_search_keywords(conn: &Connection) -> LegadoResult<()> {
    if !table_exists(conn, "search_keywords")? {
        conn.execute_batch(CREATE_SEARCH_KEYWORDS)
            .map_err(|e| LegadoError::Database(format!("创建 search_keywords 失败: {e}")))?;
        return Ok(());
    }
    if column_exists(conn, "search_keywords", "word")?
        && column_exists(conn, "search_keywords", "usage")?
        && column_exists(conn, "search_keywords", "lastUseTime")?
    {
        return Ok(());
    }

    conn.execute_batch(
        "CREATE TABLE search_keywords_v104 (
            word TEXT NOT NULL,
            usage INTEGER NOT NULL DEFAULT 1,
            lastUseTime INTEGER NOT NULL,
            PRIMARY KEY(word)
        );",
    )
    .map_err(|e| LegadoError::Database(format!("创建 search_keywords_v104 失败: {e}")))?;

    let has_keyword = column_exists(conn, "search_keywords", "keyword")?;
    let has_time = column_exists(conn, "search_keywords", "time")?;
    if has_keyword {
        let time_expr = if has_time {
            "COALESCE(time, 0)"
        } else {
            "0"
        };
        let order_by = if has_time {
            "time DESC"
        } else {
            "rowid DESC"
        };
        let sql = format!(
            "INSERT OR IGNORE INTO search_keywords_v104 (word, usage, lastUseTime)
             SELECT keyword, 1, {time_expr}
             FROM search_keywords
             WHERE keyword IS NOT NULL AND trim(keyword) != ''
             ORDER BY {order_by};"
        );
        conn.execute_batch(&sql)
            .map_err(|e| LegadoError::Database(format!("搬迁 search_keywords 失败: {e}")))?;
    }

    conn.execute_batch(
        "DROP TABLE search_keywords;
         ALTER TABLE search_keywords_v104 RENAME TO search_keywords;
         CREATE UNIQUE INDEX IF NOT EXISTS index_search_keywords_word ON search_keywords (word);",
    )
    .map_err(|e| LegadoError::Database(format!("替换 search_keywords 失败: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::Database;
    use crate::migration::{primary_key_columns, MigrationRegistry};

    fn column_exists_bool(conn: &Connection, table: &str, column: &str) -> bool {
        column_exists(conn, table, column).unwrap_or(false)
    }

    /// 构造接近 v103 的偏离表形态，验证全链路升到 v104
    #[test]
    fn test_migration_103_to_104_structural_align() {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            r#"
            CREATE TABLE rssArticles (
                origin TEXT NOT NULL, sort TEXT NOT NULL, title TEXT NOT NULL,
                "order" INTEGER NOT NULL, link TEXT, pubDate TEXT, description TEXT,
                content TEXT, image TEXT, "group" TEXT NOT NULL DEFAULT '默认分组',
                "read" INTEGER NOT NULL DEFAULT 0, variable TEXT,
                type INTEGER NOT NULL DEFAULT 0, durPos INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(origin, title)
            );
            CREATE TABLE rssStars (
                origin TEXT NOT NULL, sort TEXT NOT NULL, title TEXT NOT NULL,
                starTime INTEGER NOT NULL, link TEXT, pubDate TEXT, description TEXT,
                content TEXT, image TEXT, "group" TEXT NOT NULL DEFAULT '默认分组',
                variable TEXT, type INTEGER NOT NULL DEFAULT 0, durPos INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY(origin, title)
            );
            CREATE TABLE readRecord (
                deviceId TEXT NOT NULL DEFAULT '', bookName TEXT NOT NULL,
                author TEXT NOT NULL DEFAULT '', readTime INTEGER NOT NULL,
                lastRead INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(bookName)
            );
            CREATE TABLE rssReadRecords (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                origin TEXT NOT NULL, title TEXT NOT NULL, readTime INTEGER NOT NULL,
                link TEXT, variable TEXT
            );
            CREATE TABLE http_tts (
                id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, url TEXT NOT NULL,
                content_type TEXT DEFAULT '', is_enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE rssSources (
                sourceUrl TEXT NOT NULL, sourceName TEXT NOT NULL,
                sourceIcon TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1,
                enableCookieJar INTEGER DEFAULT 0, enabledCookieJar INTEGER DEFAULT 0,
                PRIMARY KEY(sourceUrl)
            );
            CREATE TABLE search_keywords (
                id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                keyword TEXT NOT NULL, time INTEGER NOT NULL
            );
            CREATE TABLE book_sources (
                bookSourceUrl TEXT NOT NULL, bookSourceName TEXT NOT NULL,
                variable TEXT DEFAULT '', PRIMARY KEY(bookSourceUrl)
            );
            "#,
        )
        .unwrap();

        // 存量数据
        conn.execute(
            r#"INSERT INTO rssArticles (origin, sort, title, "order", link)
               VALUES ('https://rss.com', 's1', '文章A', 2, 'https://rss.com/a'),
                      ('https://rss.com', 's1', '文章B', 1, NULL)"#,
            [],
        )
        .unwrap();
        conn.execute(
            r#"INSERT INTO rssStars (origin, sort, title, starTime, link)
               VALUES ('https://rss.com', 's1', '收藏A', 100, 'https://rss.com/s')"#,
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO readRecord (bookName, author, readTime) VALUES ('书A', '作者', 999)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO rssReadRecords (origin, title, readTime, link)
             VALUES ('https://rss.com', '文章A', 50, 'https://rss.com/a')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO http_tts (name, url, content_type, is_enabled, created_at)
             VALUES ('引擎', 'http://tts', 'audio/mpeg', 1, 123)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO rssSources (sourceUrl, sourceName, enableCookieJar, enabledCookieJar)
             VALUES ('https://rss.com', '源', 1, 0)",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO search_keywords (keyword, time) VALUES ('仙侠', 1000)",
            [],
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 103).unwrap();

        let m = Migration103To104;
        m.up(conn).unwrap();
        m.up(conn).unwrap(); // 幂等

        assert_eq!(
            primary_key_columns(conn, "rssArticles").unwrap(),
            vec!["origin", "link", "sort"]
        );
        assert_eq!(
            primary_key_columns(conn, "rssStars").unwrap(),
            vec!["origin", "link"]
        );
        assert_eq!(
            primary_key_columns(conn, "readRecord").unwrap(),
            vec!["deviceId", "bookName"]
        );
        assert_eq!(
            primary_key_columns(conn, "rssReadRecords").unwrap(),
            vec!["record"]
        );
        assert!(table_exists(conn, "httpTTS").unwrap());
        assert!(!table_exists(conn, "http_tts").unwrap());
        assert!(column_exists_bool(conn, "httpTTS", "contentType"));
        assert!(column_exists_bool(conn, "httpTTS", "isEnabled"));
        assert!(!column_exists_bool(conn, "rssSources", "enableCookieJar"));
        assert!(column_exists_bool(conn, "rssSources", "enabledCookieJar"));
        assert!(column_exists_bool(conn, "search_keywords", "word"));
        assert!(table_exists(conn, "coverRules").unwrap());

        // 数据保留
        let article_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM rssArticles", [], |r| r.get(0))
            .unwrap();
        assert_eq!(article_count, 2);
        let empty_link: String = conn
            .query_row(
                "SELECT link FROM rssArticles WHERE title = '文章B'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(empty_link.starts_with("legacy:"));
        let cookie: i32 = conn
            .query_row(
                "SELECT enabledCookieJar FROM rssSources WHERE sourceUrl = 'https://rss.com'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(cookie, 1, "enableCookieJar=1 应合并进 enabledCookieJar");
        let word: String = conn
            .query_row("SELECT word FROM search_keywords", [], |r| r.get(0))
            .unwrap();
        assert_eq!(word, "仙侠");
        let author: String = conn
            .query_row(
                "SELECT author FROM readRecord WHERE bookName = '书A'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(author, "作者");

        assert!(m.down(conn).is_err());
    }

    #[test]
    fn test_migration_103_to_104_via_registry() {
        let db = Database::open_in_memory_raw().unwrap();
        let conn = db.connection();
        conn.execute_batch(
            "CREATE TABLE rssArticles (
                origin TEXT NOT NULL, title TEXT NOT NULL, PRIMARY KEY(origin, title)
            );
            CREATE TABLE readRecord (
                bookName TEXT NOT NULL, readTime INTEGER NOT NULL, PRIMARY KEY(bookName)
            );
            CREATE TABLE book_sources (
                bookSourceUrl TEXT NOT NULL, bookSourceName TEXT NOT NULL, PRIMARY KEY(bookSourceUrl)
            );",
        )
        .unwrap();
        conn.pragma_update(None, "user_version", 103).unwrap();
        let registry = MigrationRegistry::new();
        registry.migrate_to_latest(conn).unwrap();
        assert_eq!(MigrationRegistry::current_version(conn).unwrap(), 105);
        assert_eq!(
            primary_key_columns(conn, "rssArticles").unwrap(),
            vec!["origin", "link", "sort"]
        );
        assert!(table_exists(conn, "dictRules").unwrap());
        assert!(table_exists(conn, "ruleSubs").unwrap());
    }
}
