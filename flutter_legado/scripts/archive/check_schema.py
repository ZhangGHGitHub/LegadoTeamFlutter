import sqlite3

conn = sqlite3.connect('legado.db')

# Check books table columns
cursor = conn.execute('PRAGMA table_info(books)')
books_columns = [row[1] for row in cursor]
print(f'books table has {len(books_columns)} columns:')
for col in books_columns:
    print(f'  {col}')

# Check rssSources table columns
try:
    cursor = conn.execute('PRAGMA table_info(rssSources)')
    rss_columns = [row[1] for row in cursor]
    print(f'\nrssSources table has {len(rss_columns)} columns:')
    for col in rss_columns:
        print(f'  {col}')
except Exception as e:
    print(f'\nrssSources table error: {e}')

# Check what columns are expected by Rust
expected_books_columns = [
    'bookUrl', 'tocUrl', 'origin', 'originName', 'name', 'author', 'kind',
    'customTag', 'coverUrl', 'customCoverUrl', 'intro', 'customIntro',
    'charset', 'type', 'group', 'latestChapterTitle', 'latestChapterTime',
    'lastCheckTime', 'lastCheckCount', 'totalChapterNum', 'durChapterTitle',
    'durChapterIndex', 'durVolumeIndex', 'chapterInVolumeIndex',
    'durChapterPos', 'durChapterTime', 'wordCount', 'canUpdate', 'order',
    'originOrder', 'variable', 'readConfig', 'syncTime', 'infoHtml',
    'tocHtml', 'downloadUrls', 'coverOrigin'
]

expected_rss_columns = [
    'sourceUrl', 'sourceName', 'sourceIcon', 'sourceGroup', 'sourceComment',
    'enabled', 'sortUrl', 'customOrder', 'lastUpdateTime', 'header',
    'enableJs', 'loadWithBaseUrl', 'variableComment', 'loginUrl', 'loginUi',
    'loginCheckJs', 'coverDecodeJs', 'concurrentRate', 'ruleArticles',
    'ruleNextPage', 'ruleTitle', 'rulePubDate', 'ruleDescription',
    'ruleImage', 'ruleLink', 'ruleContent', 'style', 'enableCookieJar',
    'articleStyle', 'singleUrl', 'jsLib'
]

missing_books = [col for col in expected_books_columns if col not in books_columns]
print(f'\nMissing books columns ({len(missing_books)}):')
for col in missing_books:
    print(f'  {col}')

try:
    missing_rss = [col for col in expected_rss_columns if col not in rss_columns]
    print(f'\nMissing rssSources columns ({len(missing_rss)}):')
    for col in missing_rss:
        print(f'  {col}')
except:
    pass

conn.close()
