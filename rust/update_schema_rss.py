import re

with open('legado-db/src/schema.rs', 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update SCHEMA_VERSION from 95 to 96
content = content.replace('pub const SCHEMA_VERSION: u32 = 95;', 'pub const SCHEMA_VERSION: u32 = 96;')

# 2. Update CREATE_RSS_SOURCES to add missing columns
old_rss = '''pub const CREATE_RSS_SOURCES: &str = "
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
";'''

new_rss = '''pub const CREATE_RSS_SOURCES: &str = "
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
";'''

content = content.replace(old_rss, new_rss)

with open('legado-db/src/schema.rs', 'w', encoding='utf-8') as f:
    f.write(content)

print('schema.rs updated successfully')
