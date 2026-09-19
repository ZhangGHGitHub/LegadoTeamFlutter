#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成探针书源 INSERT SQL（正确 SQLite 转义），输出到 logincheck_probe_insert.sql。
语义映射（对照 rust/legado-ffi/tests/fixtures/search_s0）：
  probeA = login_check_pass          ① 裸 true → cast 失败 → 整源失败
  probeC = login_check_modified_response ③ 首检采用 JS 改写响应
  probeD = login_check_second_adopt  ② 二次 code!=500 → 采用第二次结果
  probeE = (无夹具，自造)            ② 二次 code==500 → 整源失败
"""
import os
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SCRIPT_DIR, "logincheck_probe_insert.sql")
PORT = 18080
NOW_MS = int(time.time() * 1000)

RULE_SEARCH = '{"bookList":".book-item","name":".name","author":".author","bookUrl":".name@href"}'
RULE_BOOK = '{"name":".title","author":".author"}'


def esc(s: str) -> str:
    return s.replace("'", "''")


# 每个探针: (key, name, js)
PROBES = [
    (
        "A",
        "S0P-A",
        # ① 首检 code200 → 裸 true → cast 失败 → 整源失败（对照组：若误把裸 true 当"通过"会返回夺宝奇兵）
        "result.code() == 200",
    ),
    (
        "C",
        "S0P-C",
        # ③ 首检 code200 → 返回对象 → 采用改写后的 body/url（书名"修改后书名"只存在于 JS 对象）
        "result.code() == 200 ? { code: 200, body: '<html><body><div class=\"book-item\">"
        "<a class=\"name\" href=\"/alt/book/1\">修改后书名</a><span class=\"author\">修改后作者</span>"
        "</div></body></html>', url: 'http://127.0.0.1:%d/probeC/alt' } : false" % PORT,
    ),
    (
        "D",
        "S0P-D",
        # ②-采用 首检 code200 → 裸 false → cast 失败 → errResponse(500) 二次 eval →
        #       二次 code500 命中 → 返回 code200 对象(≠500) → 采用第二次（书名"恢复后书名"）
        "result.code() == 500 ? { code: 200, body: '<html><body><div class=\"book-item\">"
        "<a class=\"name\" href=\"/rec/book/1\">恢复后书名</a><span class=\"author\">恢复后作者</span>"
        "</div></body></html>', url: 'http://127.0.0.1:%d/probeD/rec' } : false" % PORT,
    ),
    (
        "E",
        "S0P-E",
        # ②-失败 首检 code200 → 裸 false → cast 失败 → 二次 eval code500 命中 →
        #       返回 code500 对象(==500) → 整源失败（对照组：若二次 code500 被误当通过会返回登录墙/无结果）
        "result.code() == 500 ? { code: 500, body: result.body(), url: result.url() } : false",
    ),
]

sql = []
sql.append("-- loginCheckJs 实机探针：停用现有源 + 插入 4 探针（幂等）")
sql.append("DELETE FROM book_sources WHERE bookSourceUrl LIKE 'http://127.0.0.1:%d/probe%%';" % PORT)
sql.append(
    "UPDATE book_sources SET enabled=0 WHERE bookSourceUrl NOT LIKE 'http://127.0.0.1:%d/probe%%';"
    % PORT
)
for key, name, js in PROBES:
    vals = [
        "http://127.0.0.1:%d/probe%s" % (PORT, key),
        name,
        "S0PROBE",
        "0",  # bookSourceType
        "1",  # enabled
        "1",  # enabledExplore
        "http://127.0.0.1:%d/probe%s/search?kw={{key}}" % (PORT, key),
        RULE_SEARCH,
        RULE_BOOK,
        js,
        str(NOW_MS),  # lastUpdateTime
        "0",  # respondTime (NOT NULL 无默认)
        "0",  # weight (NOT NULL 无默认)
    ]
    vals_sql = ", ".join(
        v if v.isdigit() else "'" + esc(v) + "'" for v in vals
    )
    sql.append(
        "INSERT INTO book_sources (bookSourceUrl, bookSourceName, bookSourceGroup, "
        "bookSourceType, enabled, enabledExplore, searchUrl, ruleSearch, ruleBookInfo, "
        "loginCheckJs, lastUpdateTime, respondTime, weight) VALUES (%s);" % vals_sql
    )

content = "\n".join(sql) + "\n"
with open(OUT, "w", encoding="utf-8") as f:
    f.write(content)
print("wrote", OUT)
print("=" * 60)
print(content)
