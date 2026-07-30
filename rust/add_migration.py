import sys

migration_code = '''
// ---------------------------------------------------------------------------
// v95 → v96: books 和 rssSources 表新增缺失列
// ---------------------------------------------------------------------------

/// 从 v95 升级到 v96
///
/// 变更内容：
/// - books 表新增: infoHtml, tocHtml, downloadUrls, coverOrigin
/// - rssSources 表新增: jsLib, enabledCookieJar, contentWhitelist, contentBlacklist,
///   shouldOverrideUrlLoading, injectJs, preloadJs, startHtml, startStyle, startJs,
///   showWebLog, type, preload, cacheFirst, searchUrl
pub struct Migration95To96;

impl Migration for Migration95To96 {
    fn from_version(&self) -> u32 {
        95
    }
    fn to_version(&self) -> u32 {
        96
    }
    fn description(&self) -> &str {
        "books 和 rssSources 表新增缺失列"
    }

    fn up(&self, conn: &Connection) -> LegadoResult<()> {
        // books 表新增列
        add_column_if_not_exists(conn, "books", "infoHtml", "TEXT DEFAULT ''")?;
        add_column_if_not_exists(conn, "books", "tocHtml", "TEXT DEFAULT ''")?;
        add_column_if_not_exists(conn, "books", "downloadUrls", "TEXT DEFAULT ''")?;
        add_column_if_not_exists(conn, "books", "coverOrigin", "TEXT DEFAULT ''")?;

        // rssSources 表新增列
        add_column_if_not_exists(conn, "rssSources", "jsLib", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "enabledCookieJar", "INTEGER DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "contentWhitelist", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "contentBlacklist", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "shouldOverrideUrlLoading", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "injectJs", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "preloadJs", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "startHtml", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "startStyle", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "startJs", "TEXT")?;
        add_column_if_not_exists(conn, "rssSources", "showWebLog", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "type", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "preload", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "cacheFirst", "INTEGER NOT NULL DEFAULT 0")?;
        add_column_if_not_exists(conn, "rssSources", "searchUrl", "TEXT")?;

        Ok(())
    }

    fn down(&self, _conn: &Connection) -> LegadoResult<()> {
        Err(LegadoError::Database(
            "Cannot safely rollback Migration95To96: DROP COLUMN not supported".into(),
        ))
    }
}
'''

with open('legado-db/src/migration/migrations.rs', 'a', encoding='utf-8') as f:
    f.write(migration_code)

print('Migration95To96 added successfully')
