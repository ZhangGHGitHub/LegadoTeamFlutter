#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批21h 设备验收回修（verify2）DB 夹具。

与批21原夹具的差异：
- P1-1 动作面探针：`java.log` 立即发送；`toast/longToast/open` 用 setTimeout
  错峰触发，便于截图与 logcat 取证；
- P1-2 全局名探针：`Object.getOwnPropertyNames(window)` 的 `legado` 过滤 +
  按新前缀统计（`__rs_`/`__rn_`/`__rc_`/`__rk_`/`__rb_`）；
- override 探针改用新桩名 `__rssJava`。

所有 sourceUrl 指向宿主 mock `192.168.100.52:18082`。
"""
import json
import os

BASE = "http://192.168.100.52:18082"

# ── 场景 1：P1-1 动作通道（java.log / toast / longToast / open） ──────────
LOG_PRELOAD = """java.log('BRIDGE_LOG');
setTimeout(function(){ java.toast('BRIDGE_TOAST'); }, 1200);
setTimeout(function(){ java.longToast('BRIDGE_LONG'); }, 3200);
setTimeout(function(){ java.open('__qa_noop', '', '', ''); }, 5200);
document.title = 'LOG21H';"""

# ── 场景 2：P1-2 全局名/安全探针 ─────────────────────────────────────────
SEC_PRELOAD = "document.title='SEC';"

SEC_INJECT = """(function(){
 function qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
 var all = Object.getOwnPropertyNames(window);
 var names = all.filter(function(n){return /legado/i.test(n);});
 function count(prefix){var c=0;for(var i=0;i<all.length;i++){if(all[i].indexOf(prefix)===0)c++;}return c;}
 var scripts = Array.prototype.map.call(document.scripts, function(s){return s.textContent||'';}).join('\\n');
 var tokens = ['QA_SECRET_21','LOGIN_SECRET_21','SECRET_VAR_21'];
 var leaks = tokens.filter(function(k){return scripts.indexOf(k)>=0;});
 qa('qa-sec-names','NAMES=['+names.join(',')+']');
 qa('qa-sec-prefix','RN='+count('__rn_')+' RS='+count('__rs_')+' RK='+count('__rk_')+' RB='+count('__rb_')+' RC='+count('__rc_'));
 qa('qa-sec-leak','LEAKS=['+leaks.join(',')+'] SCRIPTCOUNT='+document.scripts.length);
 qa('qa-sec-title','TITLE='+document.title);
})();"""

# ── 场景 3：mXSS 清洗（标题 SAFE 为通过口径） ────────────────────────────
CLEAN_PRELOAD = "document.title='SAFE';"

CLEAN_INJECT = """function qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
qa('qa-clean','TITLE='+document.title+' URL='+location.href+' IMGS='+document.querySelectorAll('img').length+' SCRIPTS='+document.scripts.length);"""

# ── 场景 4：桥基础回归（同步面纯函数/source/cache） ──────────────────────
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
function qa(id,text){var p=document.createElement('p');p.id=id;p.textContent=text;document.body.appendChild(p);}
qa('qa-inject','INJECTED='+document.body.dataset.injected+' JAVA='+document.body.dataset.java+' SRC='+typeof source+' CACHE='+typeof cache);
qa('qa-title','TITLE='+document.title);
qa('qa-href','URL='+location.href);"""

# ── 场景 5：普通文章回归（无 preloadJs） ─────────────────────────────────


def quote(value) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def source_row(url, name, *, preload=None, inject=None, override=None,
               show_web_log=0, single_url=0, header=None, group="QA批21h"):
    return (
        "INSERT OR REPLACE INTO rssSources "
        "(sourceUrl, sourceName, sourceGroup, sourceIcon, enabled, header, enableJs, "
        "loadWithBaseUrl, preloadJs, injectJs, shouldOverrideUrlLoading, showWebLog, "
        "singleUrl, articleStyle, customOrder) VALUES ("
        f"{quote(url)}, {quote(name)}, {quote(group)}, '', 1, "
        f"{quote(header) if header else 'NULL'}, 1, "
        f"1, {quote(preload) if preload else 'NULL'}, "
        f"{quote(inject) if inject else 'NULL'}, "
        f"{quote(override) if override else 'NULL'}, {show_web_log}, {single_url}, 0, 0);"
    )


def cache_row(key, value):
    return (
        "INSERT OR REPLACE INTO caches (key, value, deadline, created_at) VALUES ("
        f"{quote(key)}, {quote(value)}, 0, CAST(strftime('%s','now') AS INTEGER) * 1000);"
    )


S1 = f"{BASE}/rss_bridge.xml?s=log"
S2 = f"{BASE}/rss_bridge.xml?s=sec"
S3 = f"{BASE}/rss_bridge.xml?s=clean"
S4 = f"{BASE}/rss_bridge.xml?s=bridge"
S5 = f"{BASE}/rss_bridge.xml?s=normal"

rows = [
    source_row(S1, "QA22-日志", preload=LOG_PRELOAD, show_web_log=1),
    source_row(
        S2,
        "QA22-安全",
        preload=SEC_PRELOAD,
        inject=SEC_INJECT,
        header=json.dumps(
            {"User-Agent": "LegadoQA/21hBridge", "X-QA-Header": "QA_SECRET_21"},
            ensure_ascii=False,
        ),
    ),
    source_row(S3, "QA22-清洗", preload=CLEAN_PRELOAD, inject=CLEAN_INJECT),
    source_row(S4, "QA22-桥基础", preload=BRIDGE_PRELOAD, inject=BRIDGE_INJECT),
    source_row(S5, "QA22-普通"),
    cache_row(f"loginHeader_{S2}", json.dumps({"Cookie": "LOGIN_SECRET_21=1"}, ensure_ascii=False)),
    cache_row(f"sourceVariable_{S2}", "SECRET_VAR_21"),
]

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "seed_verify2.sql")
with open(out, "w", encoding="utf-8") as fh:
    fh.write("BEGIN;\n")
    fh.write("\n".join(rows))
    fh.write("\nCOMMIT;\n")
print(out)
print("sources:", S1, S2, S3, S4, S5)
