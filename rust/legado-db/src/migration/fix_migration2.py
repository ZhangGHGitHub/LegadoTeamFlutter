with open('migrations.rs', 'r', encoding='utf-8') as f:
    content = f.read()

# Find and replace the rssSources section
old_section = '''        // rssSources 表新增列（仅当表存在时）
          if table_exists(conn, "rssSources")? {
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
          add_column_if_not_exists(conn, "rssSources", "searchUrl", "TEXT")?;'''

new_section = '''        // rssSources 表新增列（仅当表存在时）
        if table_exists(conn, "rssSources")? {
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
        }'''

content = content.replace(old_section, new_section)

with open('migrations.rs', 'w', encoding='utf-8') as f:
    f.write(content)

print("Fixed indentation successfully")
