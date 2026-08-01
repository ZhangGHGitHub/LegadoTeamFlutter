import sqlite3

db_path = 'legado.db'
print(f"Checking database: {db_path}")

try:
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()
    
    # Check version
    cursor.execute("PRAGMA user_version")
    version = cursor.fetchone()[0]
    print(f"Database version: {version}")
    
    # Check books table
    cursor.execute("PRAGMA table_info(books)")
    books_cols = [row[1] for row in cursor.fetchall()]
    print(f"\nbooks table has {len(books_cols)} columns")
    print(f"Has infoHtml: {'infoHtml' in books_cols}")
    print(f"Has tocHtml: {'tocHtml' in books_cols}")
    
    # Check rssSources table
    cursor.execute("PRAGMA table_info(rssSources)")
    rss_cols = [row[1] for row in cursor.fetchall()]
    print(f"\nrssSources table has {len(rss_cols)} columns")
    print(f"Has contentWhitelist: {'contentWhitelist' in rss_cols}")
    print(f"Has jsLib: {'jsLib' in rss_cols}")
    
    conn.close()
    print("\n✓ Database check complete")
except Exception as e:
    print(f"✗ Error: {e}")
