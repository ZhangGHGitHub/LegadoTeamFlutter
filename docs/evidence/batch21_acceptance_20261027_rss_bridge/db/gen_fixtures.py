#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""生成批21 RSS 宿主桥设备验收 DB 夹具（rssSources + caches）。

输出 seed_sources.sql（在当前目录），由 adb shell sqlite3 执行。
所有 sourceUrl 均指向宿主 mock 服务 192.168.100.52:18082。
"""
import json
import os

BASE = "http://192.168.100.52:18082"

BRIDGE_PRELOAD = """var t = [];
t.push(java.getTag ? 'tag=' + java.getTag() : 'no-tag');
t.push('src=' + source.getKey());
source.put('k','v1'); t.push('put=' + source.get('k'));
cache.put('ck','cv1'); t.push('cache=' + cache.get('ck'));
t.push('b64=' + java.base64Encode('中文'));
t.push('md5=' + java.md5Encode('abc'));
document.title = 'BRIDGE|' + t.join('|');"""

BRIDGE_INJECT = """document.body.dataset.injected='1';
document.body.dataset.java=typeof java;
function __qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
__qa('qa-inject','INJECTED='+document.body.dataset.injected+' JAVA='+document.body.dataset.java+' SRC='+typeof source+' CACHE='+typeof cache);
__qa('qa-title','TITLE='+document.title);
__qa('qa-href','URL='+location.href);"""

CLEAN_PRELOAD = "document.title='SAFE';"

CLEAN_INJECT = """function __qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
__qa('qa-clean','TITLE='+document.title+' URL='+location.href+' IMGS='+document.querySelectorAll('img').length+' SCRIPTS='+document.scripts.length);"""

SEC_PRELOAD = "document.title='SEC';"

SEC_INJECT = """(function(){
 function __qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
 var names = Object.getOwnPropertyNames(window).filter(function(n){return /legado/i.test(n);});
 var chans = names.filter(function(n){return /rssNative/i.test(n);});
 var scripts = Array.prototype.map.call(document.scripts, function(s){return s.textContent||'';}).join('\\n');
 var tokens = ['QA_SECRET_21','LOGIN_SECRET_21','SECRET_VAR_21'];
 var leaks = tokens.filter(function(k){return scripts.indexOf(k)>=0;});
 __qa('qa-sec','NAMES=['+names.join(',')+']');
 __qa('qa-sec-chan','CHAN=['+chans.join(',')+']');
 __qa('qa-sec-leak','LEAKS=['+leaks.join(',')+'] SCRIPTCOUNT='+document.scripts.length);
 __qa('qa-sec-title','TITLE='+document.title);
})();"""

URLMODE_PRELOAD = """function __qa(id,text){function go(){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);} if(document.body){go();}else{document.addEventListener('DOMContentLoaded',go);}}
__qa('qa-url-src','SRC='+source.getKey());
ajaxAwait('http://192.168.100.52:18082/echo?from=urlmode','',9000).then(function(r){__qa('aw-url-body','AW-BODY '+(r && r.body));__qa('aw-url-raw','AW-RAW '+String(r));document.title='URLBRIDGE|'+(r && r.body ? r.body : String(r));},function(e){__qa('aw-url-err','ERR '+e);});"""

OVERRIDE_PRELOAD = "document.title='OVERRIDE';"

OVERRIDE_INJECT = """function __qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
__qa('qa-override','TITLE='+document.title+' JAVA_K='+((window.__legadoJava&&window.__legadoJava.get)?window.__legadoJava.get('k'):'(no-stub)'));"""

LOG_PRELOAD = "java.log('BRIDGE_LOG'); document.title='LOG';"

AJAX_PRELOAD = """function __qa(id,text){function go(){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);} if(document.body){go();}else{document.addEventListener('DOMContentLoaded',go);}}
ajaxAwait('http://192.168.100.52:18082/echo','',9000).then(function(r){__qa('aw','AW-BODY '+(r && r.body));__qa('aw-raw','AW-RAW '+String(r));document.title='AJAX|'+String(r);},function(e){__qa('aw-err','ERR '+e);});"""


def quote(value: str) -> str:
    if value is None:
        return "NULL"
    return "'" + value.replace("'", "''") + "'"


def source_row(url, name, *, preload=None, inject=None, override=None,
               show_web_log=0, single_url=0, header=None, group="QA批21"):
    return (
        "INSERT OR REPLACE INTO rssSources "
        "(sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, "
        "loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, "
        "singleUrl, articleStyle, customOrder) VALUES ("
        f"{quote(url)}, {quote(name)}, {quote(group)}, '', 1, {quote(header) if header else 'NULL'}, 1, "
        f"1, {quote(preload) if preload else 'NULL'}, {quote(inject) if inject else 'NULL'}, "
        f"{quote(override) if override else 'NULL'}, {show_web_log}, {single_url}, 0, 0);"
    )


def cache_row(key, value):
    return (
        "INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ("
        f"{quote(key)}, {quote(value)}, 0, CAST(strftime('%s','now') AS INTEGER) * 1000);"
    )


S1 = f"{BASE}/rss_bridge.xml?s=bridge"
S2 = f"{BASE}/rss_bridge.xml?s=clean"
S3 = f"{BASE}/rss_bridge.xml?s=normal"
S4 = f"{BASE}/rss_bridge.xml?s=sec"
S5 = f"{BASE}/urlmode.html"
S6 = f"{BASE}/rss_bridge.xml?s=override"
S7 = f"{BASE}/rss_bridge.xml?s=log"
S8 = f"{BASE}/rss_bridge.xml?s=ajax"

rows = [
    source_row(S1, "QA21-桥基础", preload=BRIDGE_PRELOAD, inject=BRIDGE_INJECT),
    source_row(S2, "QA21-清洗", preload=CLEAN_PRELOAD, inject=CLEAN_INJECT),
    source_row(S3, "QA21-普通"),
    source_row(
        S4,
        "QA21-安全",
        preload=SEC_PRELOAD,
        inject=SEC_INJECT,
        header=json.dumps({"User-Agent": "LegadoQA/21Bridge", "X-QA-Header": "QA_SECRET_21"}, ensure_ascii=False),
    ),
    source_row(S5, "QA21-URL模式", preload=URLMODE_PRELOAD, single_url=1),
    source_row(S6, "QA21-拦截", preload=OVERRIDE_PRELOAD, inject=OVERRIDE_INJECT,
               override="java.get('k')=='v1'"),
    source_row(S7, "QA21-日志", preload=LOG_PRELOAD, show_web_log=1),
    source_row(S8, "QA21-AJAX", preload=AJAX_PRELOAD),
    cache_row(f"loginHeader_{S4}", json.dumps({"Cookie": "LOGIN_SECRET_21=1"}, ensure_ascii=False)),
    cache_row(f"sourceVariable_{S4}", "SECRET_VAR_21"),
    cache_row(f"v_{S6}_k", "v1"),
]

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed_sources.sql")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("BEGIN;\n")
    fh.write("\n".join(rows))
    fh.write("\nCOMMIT;\n")
print(out)
print("sources:", S1, S2, S3, S4, S5, S6, S7, S8)
