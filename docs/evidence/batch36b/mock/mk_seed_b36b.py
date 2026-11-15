# -*- coding: utf-8 -*-
"""生成批36b 复验用种子 SQL（QA36 文件API源，cache 读回/TTL/putFile 复验）。

与批36 首轮相比，B 组脚本按复验任务重写：
  B1  java.cacheFile(u) -> cache.get(md5Encode16(u)) 应等于 downloadFile(u) 相对名
  B2  cache.put(k, v, 1) 1.3s 后 cache.get(k) 应为 null（TTL 生效）
  B3  cache.putFile/getFile 可用；带 saveTime=1 时 1.3s 后过期（e6bf47cf5c）
  B4  cache.put(k, v) 后 cache.get(k) / cache.get(k, true) 读回（持久化）
A/C/D 回归用例沿用批36 首轮形态（同名不覆盖 / URL 选项剥离 / 递归删目录）。

输出 qa36b_seed_all.sql（按 URL 先删后插，幂等）。
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
MOCK36 = "http://192.168.100.52:8926"

JS_AB = """var b='%s';
function P(s){java.post(b+'/report',s);}
function T(name,fn){try{return fn();}catch(e){P(name+' EXC '+e);return null;}}
var f1=T('A1',function(){return downloadFile(b+'/a/cover.jpg');});
var f2=T('A2',function(){return downloadFile(b+'/b/cover.jpg');});
P('A f1='+f1+' f2='+f2+' diff='+(f1!==f2)+' rel1='+(f1.indexOf('/')<0&&f1.indexOf(':')<0)+' rel2='+(f2.indexOf('/')<0&&f2.indexOf(':')<0));
var c1=java.readTxtFile(f1); var c2=java.readTxtFile(f2);
P('A3 len1='+c1.length+' head1='+c1.substring(4,8)+' len2='+c2.length+' head2='+c2.substring(4,8)+' same='+(c1===c2));
var u=b+'/a/cover.jpg';
var p=T('B1c',function(){return java.cacheFile(u);});
var k=java.md5Encode16(u);
var v=cache.get(k);
var vd=cache.get(k,true);
var dl=downloadFile(u);
P('B1 pLen='+(p===null?-1:p.length)+' k='+k+' v='+(v===null?'NULL':v)+' vd='+(vd===null?'NULL':vd)+' dl='+dl+' vEqDl='+(v===dl));
var kt='qa36b_ttl';
var pr0=cache.put(kt,'ttlval',1);
var b2a=cache.get(kt);
var pr1=cache.putFile('qa36b_f','fileval');
var gf=cache.getFile('qa36b_f');
var pr2=cache.putFile('qa36b_fttl','ttlfile',1);
var gt1=cache.getFile('qa36b_fttl');
java.sleep(1300);
var b2b=cache.get(kt);
var gt2=cache.getFile('qa36b_fttl');
P('B2 k='+kt+' putRet='+pr0+' before='+(b2a===null?'NULL':b2a)+' after='+(b2b===null?'NULL':b2b)+' ttlOk='+(b2a==='ttlval'&&b2b===null));
P('B3 putF='+(typeof cache.putFile)+' getF='+(typeof cache.getFile)+' rm='+(typeof cache.remove)+' putFileRet='+pr1+' gf='+(gf===null?'NULL':gf)+' ttlPutRet='+pr2+' ttlBefore='+(gt1===null?'NULL':gt1)+' ttlAfter='+(gt2===null?'NULL':gt2)+' ttlOk='+(gt1==='ttlfile'&&gt2===null));
var kp='qa36b_perm';
var pre=cache.get(kp);
cache.put(kp,'permval');
var g=cache.get(kp);
var gd=cache.get(kp,true);
P('B4 k='+kp+' pre='+(pre===null?'NULL':pre)+' get='+(g===null?'NULL':g)+' disk='+(gd===null?'NULL':gd)+' eq='+(g==='permval'));
var fc=downloadFile(b+'/a.jpg,{"type":"jpg"}');
P('C f='+fc+' end='+fc.slice(-4));
var zp=T('Cz',function(){return downloadFile(b+'/book2.zip');});
var d1=T('D1u',function(){return java.unzipFile(zp);});
var t1=T('D1g',function(){return getTxtInFolder(d1);});
P('D1 dir='+d1+' txt='+(t1===null?'NULL':t1.replace(/\s+/g,';')));
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
    sql = ["PRAGMA journal_mode=WAL;"]
    sql.append("DELETE FROM book_sources WHERE bookSourceUrl=%s;" % to_sql(QA36["bookSourceUrl"]))
    sql.append(build_insert(QA36))
    sql.append("SELECT bookSourceUrl,bookSourceName,enabled FROM book_sources;")
    out = os.path.join(HERE, "qa36b_seed_all.sql")
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sql) + "\n")
    print("wrote", out)
    print("sources:", [QA36["bookSourceName"]])


if __name__ == "__main__":
    main()
