# -*- coding: utf-8 -*-
"""批34 设备验收：构造高亮渲染测试书/章节/规则（基于升级前 v116 设备库副本）"""
import json, os, shutil, sqlite3, time

BASE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(BASE, 'db', 'legado_pre_upgrade_2.0.408.db')
DST = os.path.join(BASE, 'db', 'seed_batch34.db')
shutil.copyfile(SRC, DST)

now = int(time.time() * 1000)
conn = sqlite3.connect(DST)
c = conn.cursor()

BOOK = 'https://qa.batch34/book/highlight'
ORIGIN = 'https://qa.batch34/source'
BOOK_NAME = 'QA批34高亮书'

# 清理旧测试数据（幂等）
c.execute("DELETE FROM books WHERE bookUrl LIKE 'https://qa.batch34/%'")
c.execute("DELETE FROM chapters WHERE bookUrl LIKE 'https://qa.batch34/%'")
c.execute("DELETE FROM cached_chapters WHERE book_url LIKE 'https://qa.batch34/%'")
c.execute("DELETE FROM highlightRules WHERE name LIKE 'QA34%'")


def argb(r, g, b):
    return (0xFF << 24) | (r << 16) | (g << 8) | b


YELLOW = argb(0xFF, 0xFF, 0x00)
RED = argb(0xFF, 0x00, 0x00)
BLUE = argb(0x21, 0x96, 0xF3)
GREEN = argb(0x4C, 0xAF, 0x50)
ORANGE = argb(0xFF, 0x98, 0x00)
PURPLE = argb(0x9C, 0x27, 0xB0)

# ── 章节正文 ────────────────────────────────────────────────
filler = (
    '夜色顺着窗棂一点点渗进来，远处的犬吠被风剪成断续的碎片，'
    '桌上的茶早已凉透，只余一缕若有若无的清香在屋中盘桓。'
)

ch0 = '\n'.join([
    '本章用于验证高亮规则的基础渲染效果，正文与标签页均由设备验收脚本注入。',
    '第一处关键词测试出现在这段话的中间位置，用于核对文字颜色、背景填充与下划线样式。',
    '第二段为普通正文，不含任何需要高亮的短语，用作颜色与样式的对比基准。',
    '第三处关键词测试位于段首，方便截图时定位命中区域的起始边界。',
    filler, filler, filler, filler, filler, filler,
])

ch1_paras = ['分页对照专用章节：本段包含关键词测试，用于验证高亮启用前后分页完全一致。']
for i in range(24):
    ch1_paras.append(f'分页对照第{i + 2:02d}段。{filler}')
ch1 = '\n'.join(ch1_paras)

ch2 = '\n'.join([
    '重叠优先级验证开始：重叠命中区域测试，随后再次出现重叠命中区域测试。',
    '本段为普通正文，用于隔开命中区域，避免截图时难以分辨边界。',
    filler, filler, filler, filler,
])

ch3 = '\n'.join([
    '正则规则验证：关键词甲、关键词乙、关键词丙都应被正则规则命中。',
    '大小写验证：KeyWord 应当命中，而 keyword 不应命中。',
    '非法正则与空模式规则已在数据库中启用，本页应正常显示且不崩溃。',
    filler, filler, filler,
])

# 长章：约 1,000,000 字节（中文 3 字节/字）
long_paras = []
target_bytes = 1_000_000
cur = 0
idx = 0
while cur < target_bytes:
    idx += 1
    if idx == 1500:
        p = f'长章中段插入唯一命中点：关键词测试（第{idx}段）。{filler}'
    else:
        p = f'长章第{idx:04d}段。{filler}{filler}'
    long_paras.append(p)
    cur += len(p.encode('utf-8')) + 1
ch4 = '\n'.join(long_paras)

ch5 = '\n'.join([
    '回归阅读章节：普通正文不包含任何高亮规则命中的短语。',
    filler, filler, filler, filler, filler,
])

chapters = [
    ('第1章 基础渲染', ch0),
    ('第2章 分页对照', ch1),
    ('第3章 重叠优先级', ch2),
    ('第4章 正则与大小写', ch3),
    ('第5章 长章性能', ch4),
    ('第6章 回归阅读', ch5),
]

# ── 书籍 ────────────────────────────────────────────────────
c.execute(
    "INSERT OR REPLACE INTO books (bookUrl, tocUrl, origin, originName, name, author, type,"
    " latestChapterTitle, latestChapterTime, totalChapterNum, durChapterTitle, durChapterIndex,"
    " durChapterTime, canUpdate) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
    (BOOK, BOOK, ORIGIN, 'QA批34源', BOOK_NAME, 'QA验收', 0,
     chapters[-1][0], now, len(chapters), chapters[0][0], 0, now - 3600_000, 1))

for i, (title, content) in enumerate(chapters):
    ch_url = f'{BOOK}/chapter/{i + 1}'
    c.execute(
        "INSERT INTO chapters (url, title, isVolume, baseUrl, bookUrl, \"index\", isVip, isPay,"
        " wordCount) VALUES (?,?,?,?,?,?,?,?,?)",
        (ch_url, title, 0, ORIGIN, BOOK, i, 0, 0, str(len(content))))
    c.execute(
        "INSERT INTO cached_chapters (book_url, chapter_index, chapter_title, chapter_url, content,"
        " cached_at, size_bytes) VALUES (?,?,?,?,?,?,?)",
        (BOOK, i, title, ch_url, content, now, len(content.encode('utf-8'))))

# ── 高亮规则 ────────────────────────────────────────────────
def style_json(fill=0, text_color=0, underline=None):
    st = {'fill': fill, 'textColor': text_color, 'bold': False, 'italic': False}
    if underline:
        st['underline'] = underline
    return json.dumps(st, ensure_ascii=False, separators=(',', ':'))


rules = [
    # name, pattern, isRegex, sortOrder, style
    ('QA34基础规则', '关键词测试', 0, 10,
     style_json(fill=YELLOW, text_color=RED,
                underline={'kind': 'SOLID', 'color': 0, 'width': 1.5, 'distance': 0})),
    ('QA34重叠蓝(高)', '重叠', 0, 30, style_json(fill=BLUE)),
    ('QA34重叠绿(低)', '重叠命中区域测试', 0, 20, style_json(fill=GREEN)),
    ('QA34正则规则', r'关键词\w*', 1, 5, style_json(fill=ORANGE)),
    ('QA34空规则', '', 0, 5, style_json(fill=PURPLE)),
    ('QA34非法正则', '(', 1, 5, style_json(fill=PURPLE)),
    ('QA34大小写规则', 'KeyWord', 0, 5, style_json(fill=PURPLE)),
]
for name, pattern, is_regex, order, style in rules:
    c.execute(
        "INSERT INTO highlightRules (uuid, name, pattern, isRegex, scope, isEnabled, style,"
        " sortOrder, timeoutMillisecond, \"group\", applyToTitle, applyToBody)"
        " VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        (f'qa34-{name}', name, pattern, is_regex, None, 1, style,
         order, 3000, '', 0, 1))

conn.commit()
print('user_version =', c.execute('PRAGMA user_version').fetchone()[0])
print('books =', c.execute('SELECT COUNT(*) FROM books').fetchone()[0])
print('chapters =', c.execute('SELECT COUNT(*) FROM chapters WHERE bookUrl=?', (BOOK,)).fetchone()[0])
print('cached =', c.execute('SELECT COUNT(*) FROM cached_chapters WHERE book_url=?', (BOOK,)).fetchone()[0])
print('rules =', c.execute("SELECT COUNT(*) FROM highlightRules WHERE name LIKE 'QA34%'").fetchone()[0])
for row in c.execute('SELECT "index", title, length(content) FROM cached_chapters WHERE book_url=? ORDER BY chapter_index', (BOOK,)):
    print('chapter', row)
for row in c.execute("SELECT id, name, sortOrder, pattern, style FROM highlightRules WHERE name LIKE 'QA34%' ORDER BY sortOrder DESC"):
    print('rule', row)
conn.close()
print('seeded ->', DST)
