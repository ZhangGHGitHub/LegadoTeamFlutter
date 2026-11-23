# -*- coding: utf-8 -*-
"""批27~29 设备验收：迁移后测试数据注入脚本（在主机侧对 DB 副本执行）。

用法：python seed_after_upgrade.py <db路径>
"""
import json
import sqlite3
import sys
import time

DB = sys.argv[1]
HOST = "192.168.100.52"
SRC = f"http://{HOST}:18080"
now = int(time.time() * 1000)

conn = sqlite3.connect(DB)
c = conn.cursor()

# 1) mock 书源（正文规则带 #content@html，跨域图片在正文内）
c.execute(
    """INSERT OR REPLACE INTO book_sources
       (bookSourceUrl, bookSourceName, bookSourceType, enabled, enabledExplore,
        lastUpdateTime, respondTime, weight, header, ruleContent, eventListener, customButton)
       VALUES (?,?,0,1,1,?,0,0,NULL,?,0,0)""",
    (SRC, "QA登录头源", now, json.dumps({"content": "#content@html"}, ensure_ascii=False)),
)

# 2) 规则字段往返源（contentBatch/maxBatchSize 必须原样保留）
rule_src_url = "http://qa.local/rules"
rule_json = {
    "content": "#content@html",
    "contentBatch": "java.getContentBatch()",
    "maxBatchSize": 3,
}
c.execute(
    """INSERT OR REPLACE INTO book_sources
       (bookSourceUrl, bookSourceName, bookSourceType, enabled, enabledExplore,
        lastUpdateTime, respondTime, weight, header, ruleContent, eventListener, customButton)
       VALUES (?,?,0,1,1,?,0,0,NULL,?,0,0)""",
    (rule_src_url, "QA规则字段源", now, json.dumps(rule_json, ensure_ascii=False)),
)

# 3) mock 书 + 章节
book_url = f"{SRC}/book/1"
c.execute(
    """INSERT OR REPLACE INTO books
       (bookUrl, tocUrl, origin, originName, name, author, type, "group",
        latestChapterTitle, latestChapterTime, lastCheckTime, lastCheckCount, totalChapterNum,
        durChapterTitle, durChapterIndex, durChapterPos, durChapterTime, canUpdate, "order",
        syncTime, originBookUrl)
       VALUES (?,?,?,?,?,?,0,0,?,?,?,0,2,?,0,0,?,0,0,0,'')""",
    (
        book_url,
        f"{SRC}/toc/1",
        SRC,
        "QA登录头源",
        "QA登录头书",
        "QA作者",
        "第二章 跨域",
        now,
        now,
        "第一章 登录头",
        now,
    ),
)
for idx, title in enumerate(["第一章 登录头", "第二章 跨域"]):
    c.execute(
        """INSERT OR REPLACE INTO chapters
           (url, title, isVolume, baseUrl, bookUrl, "index", isVip, isPay,
            resourceUrl, tag, wordCount, start, end, startFragmentId, endFragmentId,
            variable, imgUrl)
           VALUES (?,?,0,?,?,?,0,0,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL)""",
        (f"{SRC}/chapter/{idx + 1}", title, book_url, book_url, idx),
    )

# 4) 登录头（模拟登录成功后缓存；通道 = caches.loginHeader_<url>）
c.execute(
    "INSERT OR REPLACE INTO caches(key,value,deadline,created_at) VALUES(?,?,0,?)",
    (f"loginHeader_{SRC}", json.dumps({"X-Login-Token": "qa-token-27-29"}), now),
)
c.execute(
    "INSERT OR REPLACE INTO caches(key,value,deadline,created_at) VALUES(?,?,0,?)",
    (f"userInfo_{SRC}", json.dumps({"name": "QA用户"}), now),
)

# 5) RSS 两源（A/B），供按源清空与全局开关验证
for tag in ("a", "b"):
    c.execute(
        """INSERT OR REPLACE INTO rssSources
           (sourceUrl, sourceName, sourceGroup, enabled, lastUpdateTime,
            ruleArticles, ruleTitle, ruleLink, ruleContent, rulePubDate, type)
           VALUES (?,?,?,1,?,?,?,?,?,NULL,0)""",
        (
            f"{SRC}/rss/{tag}",
            f"QA RSS {tag.upper()}",
            "默认",
            now,
            "div.item",
            "a.title@text",
            "a.title@href",
            "#content@html",
        ),
    )

# 6) 两源各自的历史阅读记录（A 源 2 条，B 源 1 条）
for tag, titles in (("a", ["RSS文章一", "RSS文章二"]), ("b", ["B源文章一"])):
    for title in titles:
        c.execute(
            """INSERT OR REPLACE INTO rssReadRecords
               (record, title, readTime, read, origin, sort, image, type, durPos, pubDate)
               VALUES (?,?,?,1,?,?,NULL,0,0,NULL)""",
            (f"{SRC}/rss/{tag}#{title}", title, now, f"{SRC}/rss/{tag}", title),
        )

conn.commit()
print("seed done:", DB)
for t in ("book_sources", "books", "chapters", "caches", "rssSources", "rssReadRecords"):
    print(t, c.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0])
conn.close()
