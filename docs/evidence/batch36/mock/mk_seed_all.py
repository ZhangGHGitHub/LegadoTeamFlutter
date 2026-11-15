# -*- coding: utf-8 -*-
"""生成批36 设备验收用种子 SQL（QA36 文件API源 + QA25 段评源）。

- QA36：searchUrl 指向 8926 mock；ruleSearch.name = A/B 脚本、
  ruleSearch.author = C/D 脚本，结果同时 POST 回 mock /report。
- QA25：直接读 docs/materials_1113d/qa_b25_review_source.json（批25 既有夹具），
  用于阅读/翻章与段评主流程。
输出 qa36_seed_all.sql（含按 URL 先删后插，幂等）。
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
MOCK36 = "http://192.168.100.52:8926"
QA25_SRC = os.path.join(REPO, "docs", "materials_1113d", "qa_b25_review_source.json")

JS_AB = """var b='%s';
function P(s){java.post(b+'/report',s);}
function T(name,fn){try{return fn();}catch(e){P(name+' EXC '+e);return null;}}
var f1=T('A1',function(){return downloadFile(b+'/a/cover.jpg');});
var f2=T('A2',function(){return downloadFile(b+'/b/cover.jpg');});
P('A f1='+f1+' f2='+f2+' diff='+(f1!==f2)+' rel1='+(f1.indexOf('/')<0&&f1.indexOf(':')<0)+' rel2='+(f2.indexOf('/')<0&&f2.indexOf(':')<0));
var c1=java.readTxtFile(f1); var c2=java.readTxtFile(f2);
P('A3 len1='+c1.length+' head1='+c1.substring(4,8)+' len2='+c2.length+' head2='+c2.substring(4,8)+' same='+(c1===c2));
var u=b+'/a/cover.jpg';
var p=T('B1',function(){return java.cacheFile(u);});
var k=java.md5Encode16(u);
var v=cache.get(k);
var dl=downloadFile(u);
P('B pLen='+(p===null?-1:p.length)+' k='+k+' v='+(v===null?'NULL':v)+' dl='+dl+' vEqDl='+(v===dl));
P('B4 remove='+(typeof cache.remove)+' putFile='+(typeof cache.putFile)+' getFile='+(typeof cache.getFile)+' put='+(typeof cache.put));
var u2=b+'/a.jpg?probe=36';
var fq=downloadFile(u2);
var k2=java.md5Encode16(u2);
var cf2=java.cacheFile(u2);
var v2=cache.get(k2);
P('B2 k2='+k2+' fq='+fq+' cfLen='+cf2.length+' v2='+(v2===null?'NULL':v2)+' eq='+(v2===fq));
cache.put('qa36k','qa36v');
P('B3 varStoreRt='+cache.get('qa36k'));
var fc=downloadFile(b+'/a.jpg,{"type":"jpg"}');
P('C f='+fc+' end='+fc.slice(-4));
var zp=T('Cz',function(){return downloadFile(b+'/book2.zip');});
var d1=T('D1u',function(){return java.unzipFile(zp);});
var t1=T('D1g',function(){return getTxtInFolder(d1);});
var t2=T('D1g2',function(){return getTxtInFolder(d1);});
P('D1 dir='+d1+' txt='+(t1===null?'NULL':t1.replace(/\s+/g,';'))+' secondRead='+(t2===null?'NULL':t2.replace(/\s+/g,';')));
var d2=T('D2u',function(){return java.unzipFile(zp);});
var delr=T('D2d',function(){return deleteFile(d2);});
var t3=T('D2g',function(){return getTxtInFolder(d2);});
P('D2 dir='+d2+' delRet='+delr+' afterRead='+(t3===null?'NULL':t3.replace(/\s+/g,';')));
'done';""" % MOCK36

QA36 = {
    "bookSourceUrl": MOCK36,
    "bookSourceName": "QA36 文件API源",
    "bookSourceGroup": "QA36",
    "bookSourceType": 0,
    "enabled": True,
    "enabledExplore": False,
    "customOrder": 0,
    "searchUrl": MOCK36 + "/search?q={{key}}",
    "ruleSearch": {
        "bookList": "class.item",
        "name": "@js:" + JS_AB,
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
    srcs = [QA36]
    if os.path.exists(QA25_SRC):
        with open(QA25_SRC, encoding="utf-8") as f:
            srcs.append(json.load(f))
    sql = ["PRAGMA journal_mode=WAL;"]
    for s in srcs:
        sql.append("DELETE FROM book_sources WHERE bookSourceUrl=%s;" % to_sql(s["bookSourceUrl"]))
        sql.append(build_insert(s))
    # 主流程夹具：把 QA25 段评书直接放上书架（该源无 searchUrl/exploreUrl，
    # 只能以已入库书籍形态打开；书籍规则仍由 QA25 源在线解析）
    book_url = "http://192.168.100.52:8925/book1.html"
    sql.append("DELETE FROM books WHERE bookUrl=%s;" % to_sql(book_url))
    sql.append(
        "INSERT INTO books (bookUrl,tocUrl,origin,originName,name,author,type,\"group\","
        "latestChapterTitle,latestChapterTime,lastCheckTime,lastCheckCount,totalChapterNum,"
        "durChapterTitle,durChapterIndex,durVolumeIndex,chapterInVolumeIndex,durChapterPos,"
        "durChapterTime,canUpdate,\"order\",originOrder,originBookUrl,infoHtml,tocHtml,"
        "downloadUrls,coverOrigin,syncTime) VALUES ("
        + ",".join([
            to_sql(book_url), to_sql(""), to_sql("http://192.168.100.52:8925"),
            to_sql("QA25 段评源"), to_sql("QA25 段评书"), to_sql("QA作者"),
            "0", "0", to_sql("第一章 段评章"), "0", "0", "0", "0",
            to_sql("第一章 段评章"), "0", "0", "0", "0", "0", "1", "0", "0",
            to_sql(""), to_sql(""), to_sql(""), to_sql(""), to_sql(""), "0",
        ]) + ");"
    )
    sql.append("SELECT bookUrl,name,origin FROM books;")
    out = os.path.join(HERE, "qa36_seed_all.sql")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sql) + "\n")
    print("wrote", out)
    print("sources:", [s["bookSourceName"] for s in srcs])


if __name__ == "__main__":
    main()
