# -*- coding: utf-8 -*-
"""生成批37 设备验收种子 SQL。

来源：
- QA37 字体源：search rule 执行 queryTTF / 字体缓存三链路攻击 / 32MB 上限，
  以及批36 A/C/D 回归（同名不覆盖、URL 选项、递归删目录）；
- QA37 写缓存源：cache.put('qa37_clear_key') 后回读（带磁盘读）；
- QA37 读缓存源：仅回读同 key（清理缓存前后各跑一次）；
- QA25 段评源（docs/materials_1113d/qa_b25_review_source.json）+ 书架书籍，
  用于阅读/翻章/段评/高亮主流程。

输出 qa37_seed_all.sql（按 bookSourceUrl 先删后插，幂等）。
"""

import json
import os
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
MOCK = "http://192.168.100.52:8926"
QA25_SRC = os.path.join(REPO, "docs", "materials_1113d", "qa_b25_review_source.json")
RUN = "b37r1"
FONT_URL = MOCK + "/font/valid.ttf?r=" + RUN
POISON_URL = MOCK + "/font/poison.zip?r=" + RUN
BIG_URL = MOCK + "/font/big.ttf?r=" + RUN


def common_js_prelude() -> str:
    return """var b='%s';
function P(s){java.post(b+'/report',s);}
function T(name,fn){try{return fn();}catch(e){P(name+' EXC '+e);return null;}}
""" % MOCK


def font_js(fd: str) -> str:
    return common_js_prelude() + """function H(u,c){try{return JSON.parse(c===undefined?java.queryTTF(u):java.queryTTF(u,c));}catch(e){P('H EXC '+e);return null;}}
var u='%s';
var h1=H(u);
P('B1 valid='+(h1&&h1.valid)+' type='+(h1&&h1.type)+' fontId='+(h1&&h1.fontId)+' hasErr='+(h1&&h1.error?'Y':'N'));
var h2=H(u);
P('B2 valid='+(h2&&h2.valid)+' sameId='+(!!h1&&!!h2&&h1.fontId===h2.fontId));
var h3=H(u,false);
P('B3 noCacheValid='+(h3&&h3.valid)+' sameId='+(!!h1&&!!h3&&h1.fontId===h3.fontId));
var vp='%s/'+(h1&&h1.fontId)+'.ttf';
P('B4 path='+vp);
var a1=T('A1',function(){deleteFile(vp);return 'NO_THROW';});
P('A1 ret='+a1);
var z=T('A2d',function(){return downloadFile(b+'/arch/book.zip');});
var a2=T('A2',function(){return java.un7zFile(z, '%s/qa37_poison_out');});
P('A2 input='+z+' ret='+a2);
var hp=H('%s');
var pp='%s/'+(hp&&hp.fontId)+'.ttf';
P('A3 path='+pp+' valid='+(hp&&hp.valid));
var a3=T('A3',function(){return java.unzipFile(pp);});
P('A3 ret='+a3);
var hc=H('%s');
P('C valid='+(hc&&hc.valid)+' fontId='+(hc&&hc.fontId)+' error='+(hc&&hc.error));
var f1=T('R1',function(){return downloadFile(b+'/a/cover.jpg');});
var f2=T('R2',function(){return downloadFile(b+'/b/cover.jpg');});
P('R A f1='+f1+' f2='+f2+' diff='+(f1!==f2)+' rel1='+(f1.indexOf('/')<0&&f1.indexOf(':')<0)+' rel2='+(f2.indexOf('/')<0&&f2.indexOf(':')<0));
var c1=java.readTxtFile(f1); var c2=java.readTxtFile(f2);
P('R A3 len1='+c1.length+' head1='+c1.substring(4,8)+' len2='+c2.length+' head2='+c2.substring(4,8)+' same='+(c1===c2));
var fc=downloadFile(b+'/a.jpg,{"type":"jpg"}');
P('R C f='+fc+' end='+fc.slice(-4));
var zp=T('R Cz',function(){return downloadFile(b+'/book2.zip');});
var d1=T('R D1u',function(){return java.unzipFile(zp);});
var t1=T('R D1g',function(){return getTxtInFolder(d1);});
P('R D1 dir='+d1+' txt='+(t1===null?'NULL':t1.replace(/\\s+/g,';')));
var d2=T('R D2u',function(){return java.unzipFile(zp);});
var delr=T('R D2d',function(){return deleteFile(d2);});
var t3=T('R D2g',function(){return getTxtInFolder(d2);});
P('R D2 dir='+d2+' delRet='+delr+' afterRead='+(t3===null?'NULL':t3.replace(/\\s+/g,';')));
'done';""" % (FONT_URL, fd, fd, POISON_URL, fd, BIG_URL)


def write_js() -> str:
    return common_js_prelude() + """var k='qa37_clear_key';
cache.put(k,'qa37_clear_val');
P('D1 put=get='+(cache.get(k)===null?'NULL':cache.get(k))+' disk='+(cache.get(k,true)===null?'NULL':cache.get(k,true)));
'done';"""


def read_js() -> str:
    return common_js_prelude() + """var k='qa37_clear_key';
P('D2 get='+(cache.get(k)===null?'NULL':cache.get(k))+' disk='+(cache.get(k,true)===null?'NULL':cache.get(k,true)));
'done';"""


def source(url: str, name: str, group: str, js: str) -> dict:
    return {
        "bookSourceUrl": url,
        "bookSourceName": name,
        "bookSourceGroup": group,
        "bookSourceType": 0,
        "enabled": True,
        "enabledExplore": False,
        "customOrder": 0,
        "searchUrl": MOCK + "/search?q={{key}}",
        "ruleSearch": {
            "bookList": "class.item",
            "name": "@js:" + js,
            "author": "class.skip@text",
            "bookUrl": "class.link@href",
        },
        "ruleBookInfo": {
            "name": "class.name@text",
            "author": "class.author@text",
            "intro": "class.intro@text",
            "tocUrl": "class.toc@href",
        },
        "ruleToc": {
            "chapterList": "class.ch",
            "chapterName": "tag.a@text",
            "chapterUrl": "tag.a@href",
        },
        "ruleContent": {"content": "id.content@html"},
    }


COLUMNS = [
    "bookSourceUrl", "bookSourceName", "bookSourceGroup", "bookSourceType",
    "bookUrlPattern", "customOrder", "enabled", "enabledExplore", "jsLib",
    "enabledCookieJar", "concurrentRate", "header", "loginUrl", "loginUi",
    "loginCheckJs", "coverDecodeJs", "bookSourceComment", "variableComment",
    "variable", "lastUpdateTime", "respondTime", "weight", "exploreUrl",
    "exploreScreen", "ruleExplore", "searchUrl", "ruleSearch", "ruleBookInfo",
    "ruleToc", "ruleContent", "ruleReview", "mainJs", "eventListener",
    "customButton",
]
JSON_COLS = {"ruleExplore", "ruleSearch", "ruleBookInfo", "ruleToc",
             "ruleContent", "ruleReview", "exploreScreen"}
DEFAULTS = {"customOrder": 0, "enabled": 1, "enabledExplore": 1,
            "lastUpdateTime": 0, "respondTime": 0, "weight": 0,
            "eventListener": 0, "customButton": 0, "bookSourceType": 0,
            "variable": ""}


def to_sql(v) -> str:
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, (int, float)):
        return str(v)
    return "'" + str(v).replace("'", "''") + "'"


def build_insert(src: dict) -> str:
    cols, vals = [], []
    for c in COLUMNS:
        if c in src and src[c] is not None:
            v = src[c]
            if c in JSON_COLS:
                v = json.dumps(v, ensure_ascii=False)
            elif isinstance(v, bool):
                v = 1 if v else 0
        elif c in DEFAULTS:
            v = DEFAULTS[c]
        else:
            continue
        cols.append(c)
        vals.append(to_sql(v))
    return "INSERT INTO book_sources (%s) VALUES (%s);" % (",".join(cols), ",".join(vals))


def main() -> None:
    fd = os.environ.get("QA37_FONT_CACHE_DIR", "/data/data/io.legado.flutter_legado/cache/legado_font_cache")
    srcs = []
    if os.path.exists(QA25_SRC):
        with open(QA25_SRC, encoding="utf-8") as f:
            srcs.append(json.load(f))
    srcs.append(source(MOCK + "/qa37-font", "QA37 字体源", "QA37", font_js(fd)))
    srcs.append(source(MOCK + "/qa37-write", "QA37 写缓存源", "QA37",
                       write_js().replace("'qa37_clear_key'", "'qa37_clear_key'")))
    srcs.append(source(MOCK + "/qa37-read", "QA37 读缓存源", "QA37", read_js()))

    sql = ["PRAGMA journal_mode=WAL;"]
    for s in srcs:
        sql.append("DELETE FROM book_sources WHERE bookSourceUrl=%s;" % to_sql(s["bookSourceUrl"]))
        sql.append(build_insert(s))
    book_url = MOCK + "/book1.html"
    sql.append("DELETE FROM books WHERE bookUrl=%s;" % to_sql(book_url))
    sql.append(
        "INSERT INTO books (bookUrl,tocUrl,origin,originName,name,author,type,\"group\","
        "latestChapterTitle,latestChapterTime,lastCheckTime,lastCheckCount,totalChapterNum,"
        "durChapterTitle,durChapterIndex,durVolumeIndex,chapterInVolumeIndex,durChapterPos,"
        "durChapterTime,canUpdate,\"order\",originOrder,originBookUrl,infoHtml,tocHtml,"
        "downloadUrls,coverOrigin,syncTime) VALUES ("
        + ",".join([
            to_sql(book_url), to_sql(""), to_sql(MOCK),
            to_sql("QA25 段评源"), to_sql("QA25 段评书"), to_sql("QA作者"),
            "0", "0", to_sql("第一章 段评章"), "0", "0", "0", "0",
            to_sql("第一章 段评章"), "0", "0", "0", "0", "0", "1", "0", "0",
            to_sql(""), to_sql(""), to_sql(""), to_sql(""), to_sql(""), "0",
        ]) + ");"
    )
    sql.append("SELECT bookSourceUrl,bookSourceName,enabled FROM book_sources;")
    sql.append("SELECT bookUrl,name FROM books;")
    out = os.path.join(HERE, "qa37_seed_all.sql")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sql) + "\n")
    print("wrote", out)
    print("sources:", [s["bookSourceName"] for s in srcs])
    print("font_url:", FONT_URL)
    print("poison_url:", POISON_URL)
    print("big_url:", BIG_URL)


if __name__ == "__main__":
    main()
