import sqlite3

db_path = r'd:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\build\windows\x64\runner\Release\legado.db'

print(f"Checking database at: {db_path}")
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Check user_version
cursor.execute("PRAGMA user_version")
version = cursor.fetchone()[0]
print(f"Database version: {version}")

# Check if books table has infoHtml column
cursor.execute("PRAGMA table_info(books)")
books_columns = [row[1] for row in cursor.fetchall()]
print(f"\nbooks table columns ({len(books_columns)}):")
for col in books_columns:
    print(f"  {col}")

# Check if rssSources table has contentWhitelist column
try:
    cursor.execute("PRAGMA table_info(rssSources)")
    rss_columns = [row[1] for row in cursor.fetchall()]
    print(f"\nrssSources table columns ({len(rss_columns)}):")
    for col in rss_columns:
        print(f"  {col}")
except Exception as e:
    print(f"\nrssSources table error: {e}")

conn.close()
