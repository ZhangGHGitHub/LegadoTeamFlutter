//! 数据库 Schema 定义（基于 AppDatabase v95）
//!
//! 本模块包含所有核心表的 CREATE TABLE DDL 语句。
//! 调用 `init_schema()` 可一次性创建所有表。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

/// 当前 Schema 版本号
pub const SCHEMA_VERSION: u32 = 95;

/// 初始化全部 Schema（创建所有表）
pub fn init_schema(conn: &Connection) -> LegadoResult<()> {
    conn.execute_batch(CREATE_BOOKS)
        .map_err(|e| LegadoError::Database(format!("创建 books 表失败: {e}")))?;
    conn.execute_batch(CREATE_BOOK_GROUPS)
        .map_err(|e| LegadoError::Database(format!("创建 book_groups 表失败: {e}")))?;
    conn.execute_batch(CREATE_BOOK_SOURCES)
        .map_err(|e| LegadoError::Database(format!("创建 book_sources 表失败: {e}")))?;
    conn.execute_batch(CREATE_CHAPTERS)
        .map_err(|e| LegadoError::Database(format!("创建 chapters 表失败: {e}")))?;
    conn.execute_batch(CREATE_REPLACE_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 replace_rules 表失败: {e}")))?;
    conn.execute_batch(CREATE_SEARCH_BOOKS)
        .map_err(|e| LegadoError::Database(format!("创建 searchBooks 表失败: {e}")))?;
    conn.execute_batch(CREATE_SEARCH_KEYWORDS)
        .map_err(|e| LegadoError::Database(format!("创建 search_keywords 表失败: {e}")))?;
    conn.execute_batch(CREATE_COOKIES)
        .map_err(|e| LegadoError::Database(format!("创建 cookies 表失败: {e}")))?;
    conn.execute_batch(CREATE_RSS_SOURCES)
        .map_err(|e| LegadoError::Database(format!("创建 rssSources 表失败: {e}")))?;
    conn.execute_batch(CREATE_BOOKMARKS)
        .map_err(|e| LegadoError::Database(format!("创建 bookmarks 表失败: {e}")))?;
    conn.execute_batch(CREATE_RSS_ARTICLES)
        .map_err(|e| LegadoError::Database(format!("创建 rssArticles 表失败: {e}")))?;
    conn.execute_batch(CREATE_RSS_READ_RECORDS)
        .map_err(|e| LegadoError::Database(format!("创建 rssReadRecords 表失败: {e}")))?;
    conn.execute_batch(CREATE_RSS_STARS)
        .map_err(|e| LegadoError::Database(format!("创建 rssStars 表失败: {e}")))?;
    conn.execute_batch(CREATE_TXT_TOC_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 txtTocRules 表失败: {e}")))?;
    conn.execute_batch(CREATE_READ_RECORD)
        .map_err(|e| LegadoError::Database(format!("创建 readRecord 表失败: {e}")))?;
    conn.execute_batch(CREATE_AUTO_TASK_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 auto_task_rules 表失败: {e}")))?;
    conn.execute_batch(CREATE_READING_SESSIONS)
        .map_err(|e| LegadoError::Database(format!("创建 reading_sessions 表失败: {e}")))?;
    conn.execute_batch(CREATE_CACHED_CHAPTERS)
        .map_err(|e| LegadoError::Database(format!("创建 cached_chapters 表失败: {e}")))?;
    conn.execute_batch(CREATE_CHAPTER_REVIEWS)
        .map_err(|e| LegadoError::Database(format!("创建 chapter_reviews 表失败: {e}")))?;

    // 创建索引
    conn.execute_batch(INDEXES)
        .map_err(|e| LegadoError::Database(format!("创建索引失败: {e}")))?;

    Ok(())
}

// ---------------------------------------------------------------------------
// CREATE TABLE 语句
// ---------------------------------------------------------------------------

pub const CREATE_BOOKS: &str = "
CREATE TABLE IF NOT EXISTS books (
    bookUrl TEXT NOT NULL DEFAULT '',
    tocUrl TEXT NOT NULL DEFAULT '',
    origin TEXT NOT NULL DEFAULT 'loc_book',
    originName TEXT NOT NULL DEFAULT '',
    name TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    kind TEXT,
    customTag TEXT,
    coverUrl TEXT,
    customCoverUrl TEXT,
    intro TEXT,
    customIntro TEXT,
    charset TEXT,
    type INTEGER NOT NULL DEFAULT 0,
    \"group\" INTEGER NOT NULL DEFAULT 0,
    latestChapterTitle TEXT,
    latestChapterTime INTEGER NOT NULL DEFAULT 0,
    lastCheckTime INTEGER NOT NULL DEFAULT 0,
    lastCheckCount INTEGER NOT NULL DEFAULT 0,
    totalChapterNum INTEGER NOT NULL DEFAULT 0,
    durChapterTitle TEXT,
    durChapterIndex INTEGER NOT NULL DEFAULT 0,
    durVolumeIndex INTEGER NOT NULL DEFAULT 0,
    chapterInVolumeIndex INTEGER NOT NULL DEFAULT 0,
    durChapterPos INTEGER NOT NULL DEFAULT 0,
    durChapterTime INTEGER NOT NULL DEFAULT 0,
    wordCount TEXT,
    canUpdate INTEGER NOT NULL DEFAULT 1,
    \"order\" INTEGER NOT NULL DEFAULT 0,
    originOrder INTEGER NOT NULL DEFAULT 0,
    variable TEXT,
    readConfig TEXT,
    syncTime INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(bookUrl)
);
";

pub const CREATE_BOOK_GROUPS: &str = "
CREATE TABLE IF NOT EXISTS book_groups (
    groupId INTEGER NOT NULL,
    groupName TEXT NOT NULL,
    cover TEXT,
    \"order\" INTEGER NOT NULL,
    enableRefresh INTEGER NOT NULL DEFAULT 1,
    show INTEGER NOT NULL DEFAULT 1,
    bookSort INTEGER NOT NULL DEFAULT -1,
    onlyUpdateRead INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(groupId)
);
";

pub const CREATE_BOOK_SOURCES: &str = "
CREATE TABLE IF NOT EXISTS book_sources (
    bookSourceUrl TEXT NOT NULL,
    bookSourceName TEXT NOT NULL,
    bookSourceGroup TEXT,
    bookSourceType INTEGER NOT NULL,
    bookUrlPattern TEXT,
    customOrder INTEGER NOT NULL DEFAULT 0,
    enabled INTEGER NOT NULL DEFAULT 1,
    enabledExplore INTEGER NOT NULL DEFAULT 1,
    jsLib TEXT,
    enabledCookieJar INTEGER DEFAULT 0,
    concurrentRate TEXT,
    header TEXT,
    loginUrl TEXT,
    loginUi TEXT,
    loginCheckJs TEXT,
    coverDecodeJs TEXT,
    bookSourceComment TEXT,
    variableComment TEXT,
    lastUpdateTime INTEGER NOT NULL,
    respondTime INTEGER NOT NULL,
    weight INTEGER NOT NULL,
    exploreUrl TEXT,
    exploreScreen TEXT,
    ruleExplore TEXT,
    searchUrl TEXT,
    ruleSearch TEXT,
    ruleBookInfo TEXT,
    ruleToc TEXT,
    ruleContent TEXT,
    ruleReview TEXT,
    mainJs TEXT,
    eventListener INTEGER NOT NULL DEFAULT 0,
    customButton INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(bookSourceUrl)
);
";

pub const CREATE_CHAPTERS: &str = "
CREATE TABLE IF NOT EXISTS chapters (
    url TEXT NOT NULL,
    title TEXT NOT NULL,
    isVolume INTEGER NOT NULL,
    baseUrl TEXT NOT NULL,
    bookUrl TEXT NOT NULL,
    \"index\" INTEGER NOT NULL,
    isVip INTEGER NOT NULL,
    isPay INTEGER NOT NULL,
    resourceUrl TEXT,
    tag TEXT,
    wordCount TEXT,
    start INTEGER,
    end INTEGER,
    startFragmentId TEXT,
    endFragmentId TEXT,
    variable TEXT,
    imgUrl TEXT,
    PRIMARY KEY(url, bookUrl),
    FOREIGN KEY(bookUrl) REFERENCES books(bookUrl) ON DELETE CASCADE
);
";

pub const CREATE_REPLACE_RULES: &str = "
CREATE TABLE IF NOT EXISTS replace_rules (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    \"group\" TEXT,
    pattern TEXT NOT NULL DEFAULT '',
    replacement TEXT NOT NULL DEFAULT '',
    scope TEXT,
    scopeTitle INTEGER NOT NULL DEFAULT 0,
    scopeContent INTEGER NOT NULL DEFAULT 1,
    excludeScope TEXT,
    isEnabled INTEGER NOT NULL DEFAULT 1,
    isRegex INTEGER NOT NULL DEFAULT 1,
    timeoutMillisecond INTEGER NOT NULL DEFAULT 3000,
    sortOrder INTEGER NOT NULL DEFAULT 0
);
";

pub const CREATE_SEARCH_BOOKS: &str = "
CREATE TABLE IF NOT EXISTS searchBooks (
    bookUrl TEXT NOT NULL,
    origin TEXT NOT NULL,
    originName TEXT NOT NULL,
    type INTEGER NOT NULL,
    name TEXT NOT NULL,
    author TEXT NOT NULL,
    kind TEXT,
    coverUrl TEXT,
    intro TEXT,
    wordCount TEXT,
    latestChapterTitle TEXT,
    tocUrl TEXT NOT NULL,
    time INTEGER NOT NULL,
    variable TEXT,
    originOrder INTEGER NOT NULL,
    chapterWordCountText TEXT,
    chapterWordCount INTEGER NOT NULL DEFAULT -1,
    respondTime INTEGER NOT NULL DEFAULT -1,
    PRIMARY KEY(bookUrl),
    FOREIGN KEY(origin) REFERENCES book_sources(bookSourceUrl) ON DELETE CASCADE
);
";

pub const CREATE_SEARCH_KEYWORDS: &str = "
CREATE TABLE IF NOT EXISTS search_keywords (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    keyword TEXT NOT NULL,
    time INTEGER NOT NULL
);
";

pub const CREATE_COOKIES: &str = "
CREATE TABLE IF NOT EXISTS cookies (
    url TEXT NOT NULL,
    cookie TEXT NOT NULL,
    PRIMARY KEY(url)
);
";

pub const CREATE_RSS_SOURCES: &str = "
CREATE TABLE IF NOT EXISTS rssSources (
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
    enableCookieJar INTEGER DEFAULT 0,
    articleStyle INTEGER NOT NULL DEFAULT 0,
    singleUrl INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(sourceUrl)
);
";

pub const CREATE_BOOKMARKS: &str = "
CREATE TABLE IF NOT EXISTS bookmarks (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    bookName TEXT NOT NULL,
    bookAuthor TEXT NOT NULL,
    chapterIndex INTEGER NOT NULL,
    chapterPos INTEGER NOT NULL,
    chapterName TEXT NOT NULL,
    bookText TEXT NOT NULL,
    content TEXT NOT NULL,
    time INTEGER NOT NULL
);
";

pub const CREATE_RSS_ARTICLES: &str = "
CREATE TABLE IF NOT EXISTS rssArticles (
    origin TEXT NOT NULL,
    sort TEXT NOT NULL,
    title TEXT NOT NULL,
    \"order\" INTEGER NOT NULL,
    link TEXT,
    pubDate TEXT,
    description TEXT,
    content TEXT,
    image TEXT,
    variable TEXT,
    PRIMARY KEY(origin, title)
);
";

pub const CREATE_RSS_READ_RECORDS: &str = "
CREATE TABLE IF NOT EXISTS rssReadRecords (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    origin TEXT NOT NULL,
    title TEXT NOT NULL,
    readTime INTEGER NOT NULL,
    link TEXT,
    variable TEXT
);
";

pub const CREATE_RSS_STARS: &str = "
CREATE TABLE IF NOT EXISTS rssStars (
    origin TEXT NOT NULL,
    sort TEXT NOT NULL,
    title TEXT NOT NULL,
    starTime INTEGER NOT NULL,
    link TEXT,
    pubDate TEXT,
    description TEXT,
    content TEXT,
    image TEXT,
    variable TEXT,
    PRIMARY KEY(origin, title)
);
";

pub const CREATE_TXT_TOC_RULES: &str = "
CREATE TABLE IF NOT EXISTS txtTocRules (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    name TEXT NOT NULL,
    rule TEXT NOT NULL,
    serialNumber INTEGER NOT NULL DEFAULT 0,
    enable INTEGER NOT NULL DEFAULT 1,
    example TEXT
);
";

pub const CREATE_READ_RECORD: &str = "
CREATE TABLE IF NOT EXISTS readRecord (
    bookName TEXT NOT NULL,
    readTime INTEGER NOT NULL,
    PRIMARY KEY(bookName)
);
";

pub const CREATE_AUTO_TASK_RULES: &str = "
CREATE TABLE IF NOT EXISTS auto_task_rules (
    id TEXT NOT NULL,
    name TEXT NOT NULL,
    enable INTEGER NOT NULL,
    cron TEXT,
    loginUrl TEXT,
    loginUi TEXT,
    loginCheckJs TEXT,
    comment TEXT,
    script TEXT NOT NULL,
    header TEXT,
    jsLib TEXT,
    concurrentRate TEXT,
    enabledCookieJar INTEGER NOT NULL,
    customOrder INTEGER NOT NULL,
    lastRunAt INTEGER NOT NULL,
    lastResult TEXT,
    lastError TEXT,
    lastLog TEXT,
    PRIMARY KEY(id)
);
";

pub const CREATE_READING_SESSIONS: &str = "
CREATE TABLE IF NOT EXISTS reading_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_url TEXT NOT NULL,
    chapter_index INTEGER NOT NULL DEFAULT 0,
    chapter_name TEXT,
    start_time INTEGER NOT NULL,
    end_time INTEGER,
    word_count INTEGER NOT NULL DEFAULT 0,
    reading_speed REAL NOT NULL DEFAULT 0.0
);
CREATE INDEX IF NOT EXISTS idx_reading_sessions_book ON reading_sessions(book_url);
CREATE INDEX IF NOT EXISTS idx_reading_sessions_time ON reading_sessions(start_time);
";

pub const CREATE_CACHED_CHAPTERS: &str = "
CREATE TABLE IF NOT EXISTS cached_chapters (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_url TEXT NOT NULL,
    chapter_index INTEGER NOT NULL,
    chapter_title TEXT NOT NULL DEFAULT '',
    chapter_url TEXT NOT NULL,
    content TEXT NOT NULL DEFAULT '',
    cached_at INTEGER NOT NULL,
    size_bytes INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_cached_chapters_book ON cached_chapters(book_url);
CREATE UNIQUE INDEX IF NOT EXISTS idx_cached_chapters_url ON cached_chapters(chapter_url);
";

pub const CREATE_CHAPTER_REVIEWS: &str = "
CREATE TABLE IF NOT EXISTS chapter_reviews (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    book_url TEXT NOT NULL,
    chapter_index INTEGER NOT NULL,
    paragraph_index INTEGER NOT NULL DEFAULT -1,
    content TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    created_at INTEGER NOT NULL,
    like_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_chapter_reviews_book_chapter ON chapter_reviews(book_url, chapter_index);
";

/// 索引定义
pub const INDEXES: &str = "
CREATE UNIQUE INDEX IF NOT EXISTS index_books_name_author ON books (name, author);
CREATE INDEX IF NOT EXISTS index_book_sources_bookSourceUrl ON book_sources (bookSourceUrl);
CREATE INDEX IF NOT EXISTS index_chapters_bookUrl ON chapters (bookUrl);
CREATE UNIQUE INDEX IF NOT EXISTS index_chapters_bookUrl_index ON chapters (bookUrl, \"index\");
CREATE INDEX IF NOT EXISTS index_replace_rules_id ON replace_rules (id);
";
