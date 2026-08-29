# -*- coding: utf-8 -*-
"""Filter enabled book source URLs by group name (optional) and limit count."""
import json
import sqlite3
import sys


def split_groups(raw: str) -> list[str]:
    if not raw:
        return []
    normalized = (
        raw.replace("\uff0c", ",")
        .replace("\uff1b", ";")
        .replace(";", ",")
    )
    return [p.strip() for p in normalized.split(",") if p.strip()]


def main() -> None:
    if len(sys.argv) < 4:
        print("usage: search_probe_filter.py <db> <group> <out_json> [limit]", file=sys.stderr)
        sys.exit(2)
    db_path, group, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
    limit = int(sys.argv[4]) if len(sys.argv) >= 5 and sys.argv[4] else 0

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("SELECT bookSourceUrl, bookSourceGroup FROM book_sources WHERE enabled=1")
    urls: list[str] = []
    for url, group_field in cur.fetchall():
        if group:
            parts = split_groups(group_field or "")
            if group not in parts:
                continue
        urls.append(url)
    if limit > 0:
        urls = urls[:limit]
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(urls, f, ensure_ascii=False)
    print(len(urls))


if __name__ == "__main__":
    main()
