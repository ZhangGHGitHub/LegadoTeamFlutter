# -*- coding: utf-8 -*-
"""批31 设备验收：向 v114 设备库注入多源/多书/章节/缓存正文测试数据"""
import json, os, shutil, sqlite3, time

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, 'db', 'legado_pre_upgrade_2.0.406.db')
DST = os.path.join(BASE, 'db', 'seed_batch31.db')
shutil.copyfile(SRC, DST)

now = int(time.time() * 1000)
conn = sqlite3.connect(DST)
c = conn.cursor()

# 清掉历史测试源（保留批25源作为零本书源对照）
c.execute("DELETE FROM book_sources WHERE bookSourceUrl LIKE 'http://qa.local/%'")
c.execute("DELETE FROM books WHERE bookUrl LIKE 'http://qa.local/%'")

sources = [
    ('http://qa.local/a', 'QA源A（批31）', '批31验收', 0, 1),
    ('http://qa.local/b', 'QA源B（批31）', '批31验收', 0, 1),
    ('http://qa.local/c', 'QA源C（批31，零本）', '批31验收', 0, 1),
]
for url, name, group, stype, enabled in sources:
    c.execute(
        "INSERT OR REPLACE INTO book_sources (bookSourceUrl, bookSourceName, bookSourceGroup,"
        " bookSourceType, customOrder, enabled, enabledExplore, lastUpdateTime, respondTime, weight,"
        " ruleSearch, ruleToc, ruleContent) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (url, name, group, stype, 0, enabled, 0, now, 1000, 0,
         '{"bookList":"","name":"","author":"","bookUrl":"","intro":"","coverUrl":""}',
         '{"chapterList":"","chapterName":"","chapterUrl":""}',
         '{"content":""}'))

cfg = json.dumps({"reverseToc": False, "reverseTocDisplay": False}, ensure_ascii=False, separators=(',', ':'))

books = [
    # bookUrl, tocUrl, origin, originName, name, author, type, chapters, durIndex, readConfig
    ('http://qa.local/a/book/1', 'http://qa.local/a/book/1', 'http://qa.local/a', 'QA源A（批31）',
     'QA批31书A1', '作者甲', 0, 25, 4, cfg),
    ('http://qa.local/a/book/2', 'http://qa.local/a/book/2', 'http://qa.local/a', 'QA源A（批31）',
     'QA批31书A2', '作者乙', 0, 3, 0, cfg),
    ('http://qa.local/b/book/1', 'http://qa.local/b/book/1', 'http://qa.local/b', 'QA源B（批31）',
     'QA批31书B1', '作者丙', 0, 5, 1, cfg),
    # notShelf 临时书：不应出现在书架、不应计入书源数量
    ('http://qa.local/a/book/temp', 'http://qa.local/a/book/temp', 'http://qa.local/a', 'QA源A（批31）',
     'QA批31临时书', '作者丁', 1024, 2, 0, cfg),
]
for url, toc, origin, oname, name, author, typ, nchap, dur, rc in books:
    c.execute(
        "INSERT OR REPLACE INTO books (bookUrl, tocUrl, origin, originName, name, author, type,"
        " latestChapterTitle, latestChapterTime, totalChapterNum, durChapterTitle, durChapterIndex,"
        " durChapterTime, canUpdate, readConfig) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (url, toc, origin, oname, name, author, typ,
         f'第{nchap}章 QA-{name}-{nchap}', now, nchap,
         f'第{dur+1}章 QA-{name}-{dur+1:02d}', dur, now - 3600_000, 1, rc))

# 章节 + 缓存正文
for url, toc, origin, oname, name, author, typ, nchap, dur, rc in books:
    if typ & 1024:
        nchap = 2  # 临时书也造两章，但不影响书架
    c.execute("DELETE FROM chapters WHERE bookUrl=?", (url,))
    c.execute("DELETE FROM cached_chapters WHERE book_url=?", (url,))
    for i in range(nchap):
        ch_url = f'{url}/chapter/{i+1}'
        title = f'第{i+1}章 QA-{name}-{i+1:02d}'
        c.execute(
            "INSERT INTO chapters (url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay)"
            " VALUES (?,?,?,?,?,?,?,?)",
            (ch_url, title, 0, origin, url, i, 0, 0))
        content = (f'{title}\n\n这是批31设备验收测试正文（第 {i+1} 章），用于验证目录显示反转后的'
                   f'章节跳转与当前章高亮。' + ('正文段落。' * 30))
        c.execute(
            "INSERT INTO cached_chapters (book_url, chapter_index, chapter_title, chapter_url, content,"
            " cached_at, size_bytes) VALUES (?,?,?,?,?,?,?)",
            (url, i, title, ch_url, content, now, len(content.encode('utf-8'))))

conn.commit()
print('user_version =', c.execute('PRAGMA user_version').fetchone()[0])
print('sources =', c.execute("SELECT COUNT(*) FROM book_sources").fetchone()[0])
print('books =', c.execute("SELECT COUNT(*) FROM books").fetchone()[0])
print('chapters =', c.execute("SELECT COUNT(*) FROM chapters").fetchone()[0])
print('cached =', c.execute("SELECT COUNT(*) FROM cached_chapters").fetchone()[0])
print('--- expected counts (exclude notShelf/local) ---')
for row in c.execute("SELECT origin, COUNT(*) FROM books WHERE (type & 1024)=0 AND (type & 256)=0 AND (type & 4096)=0 GROUP BY origin"):
    print(row)
conn.close()
print('seeded ->', DST)
