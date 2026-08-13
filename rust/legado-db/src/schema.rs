//! 数据库 Schema 定义（基于 AppDatabase v99 + Rust 轨扩展）
//!
//! 本模块包含所有核心表的 CREATE TABLE DDL 语句。
//! 调用 `init_schema()` 可一次性创建所有表。

use rusqlite::Connection;

use legado_core::{LegadoError, LegadoResult};

/// 当前 Schema 版本号
///
/// - v99：对齐上游 Room AppDatabase v99
/// - v100：Rust 轨自有扩展（rule_subs 补全 Kotlin RuleSub 字段）
/// - v101：偏离表修复（rssArticles/rssStars/readRecord/txtTocRules 补齐 Room 99.json 缺列）
/// - v102：cached_chapters 唯一索引由 chapter_url 单列改为 (book_url, chapter_url)
///   复合键（Task #16 P0：修复跨书缓存串本导致「正文显示为另一本书内容」）
/// - v103：book_sources 表补 `variable` 列（台账 §5.11-3，支撑契约 §2.3
///   setSourceVariable 书源自定义变量，幂等迁移，Task #63）
/// - v104：台账「schema v102 结构对齐专项」落地（版本号避开已被占用的 102/103）：
///   rssArticles/rssStars 主键重建、readRecord 主键重建、rssReadRecords/httpTTS
///   结构对齐 Room v95、rssSources 去掉 enableCookieJar 冗余列、search_keywords
///   对齐 word/usage/lastUseTime、coverRules 纳入建表清单。
/// - v105：D1 — ruleSubs/dictRules/keyboardAssists 对齐 Room 表名列名
///   （Migration104To105；清理 snake_case 旧表残留）
pub const SCHEMA_VERSION: u32 = 105;

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
    conn.execute_batch(CREATE_CACHED_CHAPTERS)
        .map_err(|e| LegadoError::Database(format!("创建 cached_chapters 表失败: {e}")))?;
    conn.execute_batch(CREATE_CHAPTER_REVIEWS)
        .map_err(|e| LegadoError::Database(format!("创建 chapter_reviews 表失败: {e}")))?;
    conn.execute_batch(CREATE_RULE_SUBS)
        .map_err(|e| LegadoError::Database(format!("创建 ruleSubs 表失败: {e}")))?;
    conn.execute_batch(CREATE_CACHES)
        .map_err(|e| LegadoError::Database(format!("创建 caches 表失败: {e}")))?;
    conn.execute_batch(CREATE_HTTP_TTS)
        .map_err(|e| LegadoError::Database(format!("创建 httpTTS 表失败: {e}")))?;
    conn.execute_batch(CREATE_DICT_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 dictRules 表失败: {e}")))?;
    conn.execute_batch(CREATE_KEYBOARD_ASSISTS)
        .map_err(|e| LegadoError::Database(format!("创建 keyboardAssists 表失败：{e}")))?;
    conn.execute_batch(CREATE_COVER_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 coverRules 表失败: {e}")))?;
    conn.execute_batch(CREATE_DOWNLOAD_TASKS)
        .map_err(|e| LegadoError::Database(format!("创建 download_tasks 表失败：{e}")))?;
    conn.execute_batch(CREATE_HIGHLIGHTS)
        .map_err(|e| LegadoError::Database(format!("创建 highlights 表失败：{e}")))?;
    conn.execute_batch(CREATE_HIGHLIGHT_RULES)
        .map_err(|e| LegadoError::Database(format!("创建 highlightRules 表失败：{e}")))?;

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
    infoHtml TEXT DEFAULT '',
    tocHtml TEXT DEFAULT '',
    downloadUrls TEXT DEFAULT '',
    coverOrigin TEXT DEFAULT '',
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
    variable TEXT DEFAULT '',
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

/// search_keywords 表（对齐 Room v95：word/usage/lastUseTime，主键 word）
pub const CREATE_SEARCH_KEYWORDS: &str = "
CREATE TABLE IF NOT EXISTS search_keywords (
    word TEXT NOT NULL,
    usage INTEGER NOT NULL DEFAULT 1,
    lastUseTime INTEGER NOT NULL,
    PRIMARY KEY(word)
);
CREATE UNIQUE INDEX IF NOT EXISTS index_search_keywords_word ON search_keywords (word);
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

/// rssArticles 表（对齐 Room v95：主键 (origin, link, sort)，link NOT NULL）
pub const CREATE_RSS_ARTICLES: &str = "
CREATE TABLE IF NOT EXISTS rssArticles (
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
);
";

/// rssReadRecords 表（对齐 Room v95：主键 record）
pub const CREATE_RSS_READ_RECORDS: &str = "
CREATE TABLE IF NOT EXISTS rssReadRecords (
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
);
CREATE INDEX IF NOT EXISTS index_rssReadRecords_origin ON rssReadRecords (origin);
";

/// rssStars 表（对齐 Room v95：主键 (origin, link)，link NOT NULL）
pub const CREATE_RSS_STARS: &str = "
CREATE TABLE IF NOT EXISTS rssStars (
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
);
";

/// txtTocRules 表（对齐 Room 99.json 列集，v101 补齐 replacement）
pub const CREATE_TXT_TOC_RULES: &str = "
CREATE TABLE IF NOT EXISTS txtTocRules (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    name TEXT NOT NULL,
    rule TEXT NOT NULL,
    replacement TEXT NOT NULL DEFAULT '',
    serialNumber INTEGER NOT NULL DEFAULT 0,
    enable INTEGER NOT NULL DEFAULT 1,
    example TEXT
);
";

/// readRecord 表（对齐 Room v95 主键 (deviceId, bookName)；author 为 Rust/上游超集列）
pub const CREATE_READ_RECORD: &str = "
CREATE TABLE IF NOT EXISTS readRecord (
    deviceId TEXT NOT NULL DEFAULT '',
    bookName TEXT NOT NULL,
    author TEXT NOT NULL DEFAULT '',
    readTime INTEGER NOT NULL DEFAULT 0,
    lastRead INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(deviceId, bookName)
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
-- Task #16 P0：唯一键改为 (book_url, chapter_url) 复合键，避免不同书籍共用
-- 相同 chapter_url 时 INSERT OR REPLACE 跨书覆盖、查找串本（正文张冠李戴）。
-- 存量库经 Migration101To102 显式 DROP 旧的 idx_cached_chapters_url 后重建本索引。
CREATE UNIQUE INDEX IF NOT EXISTS idx_cached_chapters_book_url ON cached_chapters(book_url, chapter_url);
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

/// ruleSubs 表（对齐 Room `RuleSub`；version/isEnabled/createdAt 为 Rust 超集）
///
/// Room 列：id/name/url/type/customOrder/autoUpdate/update/updateInterval/
/// silentUpdate/js/showRule/sourceUrl。`type`：0 书源 / 1 订阅源 / 3 替换规则。
pub const CREATE_RULE_SUBS: &str = "
CREATE TABLE IF NOT EXISTS ruleSubs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL DEFAULT '',
    url TEXT NOT NULL UNIQUE,
    type INTEGER NOT NULL DEFAULT 0,
    customOrder INTEGER NOT NULL DEFAULT 0,
    autoUpdate INTEGER NOT NULL DEFAULT 0,
    \"update\" INTEGER NOT NULL DEFAULT 0,
    updateInterval INTEGER NOT NULL DEFAULT 0,
    silentUpdate INTEGER NOT NULL DEFAULT 0,
    js TEXT,
    showRule TEXT,
    sourceUrl TEXT,
    version TEXT DEFAULT '',
    isEnabled INTEGER NOT NULL DEFAULT 1,
    createdAt INTEGER NOT NULL DEFAULT 0
);
";

pub const CREATE_CACHES: &str = "
CREATE TABLE IF NOT EXISTS caches (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL DEFAULT '',
    deadline INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_caches_deadline ON caches(deadline);
";

/// httpTTS 表（对齐 Room v95 列集；`isEnabled` 为 Rust 轨超集，支撑启用开关 API）
pub const CREATE_HTTP_TTS: &str = "
CREATE TABLE IF NOT EXISTS httpTTS (
    id INTEGER NOT NULL,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    contentType TEXT,
    pauseDuration INTEGER NOT NULL DEFAULT 0,
    concurrentRate TEXT DEFAULT '0',
    loginUrl TEXT,
    loginUi TEXT,
    header TEXT,
    jsLib TEXT,
    enabledCookieJar INTEGER DEFAULT 0,
    loginCheckJs TEXT,
    lastUpdateTime INTEGER NOT NULL DEFAULT 0,
    isEnabled INTEGER NOT NULL DEFAULT 1,
    PRIMARY KEY(id)
);
";

/// coverRules 表（纳入迁移体系，对齐 default_data / CoverRuleRepository DDL）
pub const CREATE_COVER_RULES: &str = "
CREATE TABLE IF NOT EXISTS coverRules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL DEFAULT '',
    rule TEXT NOT NULL DEFAULT '',
    enable INTEGER NOT NULL DEFAULT 1
);
";

/// dictRules 表（对齐 Room `DictRule`；id 为 Rust 超集便于既有 id 基 CRUD）
///
/// Room 语义主键为 name（UNIQUE）；列：name/urlRule/showRule/enabled/sortNumber。
pub const CREATE_DICT_RULES: &str = "
CREATE TABLE IF NOT EXISTS dictRules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,
    urlRule TEXT DEFAULT '',
    showRule TEXT DEFAULT '',
    enabled INTEGER NOT NULL DEFAULT 1,
    sortNumber INTEGER NOT NULL DEFAULT 0
);
";

/// keyboardAssists 表（对齐 Room `KeyboardAssist`，主键 (type, key)）
pub const CREATE_KEYBOARD_ASSISTS: &str = "
CREATE TABLE IF NOT EXISTS keyboardAssists (
    type INTEGER NOT NULL DEFAULT 0,
    key TEXT NOT NULL DEFAULT '',
    value TEXT NOT NULL DEFAULT '',
    serialNo INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(type, key)
);
";

pub const CREATE_DOWNLOAD_TASKS: &str = "
CREATE TABLE IF NOT EXISTS download_tasks (
    id TEXT PRIMARY KEY NOT NULL,
    book_url TEXT NOT NULL DEFAULT '',
    chapter_url TEXT NOT NULL DEFAULT '',
    chapter_title TEXT NOT NULL DEFAULT '',
    chapter_index INTEGER NOT NULL DEFAULT 0,
    status INTEGER NOT NULL DEFAULT 0,
    progress REAL NOT NULL DEFAULT 0.0,
    priority INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT 0,
    completed_at INTEGER,
    error TEXT,
    fail_count INTEGER NOT NULL DEFAULT 0,
    last_retry_at INTEGER,
    next_retry_at INTEGER
);
";

/// highlights 表（v99 最终形态，对齐 Room schema 99.json）
///
/// 正文高亮记录：主键为 time（Unix 毫秒），bookUrl/chapterUrl 定位高亮所属书籍与章节。
pub const CREATE_HIGHLIGHTS: &str = "
CREATE TABLE IF NOT EXISTS highlights (
    time INTEGER NOT NULL,
    bookUrl TEXT NOT NULL DEFAULT '',
    chapterUrl TEXT NOT NULL DEFAULT '',
    bookName TEXT NOT NULL,
    bookAuthor TEXT NOT NULL,
    chapterIndex INTEGER NOT NULL,
    chapterPos INTEGER NOT NULL,
    chapterPosEnd INTEGER NOT NULL,
    layoutTitleLength INTEGER NOT NULL DEFAULT -1,
    chapterName TEXT NOT NULL,
    bookText TEXT NOT NULL,
    style TEXT NOT NULL,
    note TEXT NOT NULL,
    PRIMARY KEY(time)
);
CREATE INDEX IF NOT EXISTS index_highlights_bookUrl ON highlights (bookUrl);
";

/// highlightRules 表（对齐 Room schema 98.json/99.json）
///
/// 自动高亮规则：支持正则/普通文本匹配，scope 限定生效书籍范围。
pub const CREATE_HIGHLIGHT_RULES: &str = "
CREATE TABLE IF NOT EXISTS highlightRules (
    id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
    name TEXT NOT NULL,
    pattern TEXT NOT NULL,
    isRegex INTEGER NOT NULL,
    scope TEXT,
    isEnabled INTEGER NOT NULL,
    style TEXT NOT NULL,
    sortOrder INTEGER NOT NULL,
    timeoutMillisecond INTEGER NOT NULL,
    applyToTitle INTEGER NOT NULL DEFAULT 0
);
";

/// 索引定义
pub const INDEXES: &str = "
CREATE UNIQUE INDEX IF NOT EXISTS index_books_name_author ON books (name, author);
CREATE INDEX IF NOT EXISTS index_book_sources_bookSourceUrl ON book_sources (bookSourceUrl);
CREATE INDEX IF NOT EXISTS index_chapters_bookUrl ON chapters (bookUrl);
CREATE UNIQUE INDEX IF NOT EXISTS index_chapters_bookUrl_index ON chapters (bookUrl, \"index\");
CREATE INDEX IF NOT EXISTS index_replace_rules_id ON replace_rules (id);
";
