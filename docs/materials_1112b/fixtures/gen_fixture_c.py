# -*- coding: utf-8 -*-
"""源 C：大 jsLib 加载耗时观测（引擎缓存首次 vs 复用）。"""
import json
import os

ROOT = r"C:/Users/admin/AppData/Local/Temp/qa_b21/http"
HOST = "http://192.168.100.52:8091"

js_lib = (
    "var __t0=Date.now(); var __acc=0;"
    " for (var i=0;i<20000000;i++){__acc=(__acc+i)%1000003;}"
    " var __loadedAt=Date.now();"
    " function __loadMs(){return __loadedAt-__t0;}"
)

action = (
    "var a=(typeof __loadedAt==='number')?(__loadedAt-__t0):-1;"
    " var age=(typeof __loadedAt==='number')?(Date.now()-__loadedAt):-1;"
    " java.toast('HEAVY LOADMS='+a+' AGE='+age+'ms result='+(typeof __loadMs==='function'?__loadMs():-2))"
)
src = HOST + "/t.png," + json.dumps({"click": action}, ensure_ascii=False)


def html_attr(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


os.makedirs(os.path.join(ROOT, "qa21c"), exist_ok=True)
ch = (
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>第1章 大jsLib</title></head>\n<body>\n"
    "<div class=\"content\">\n<p>大 jsLib：首次点击应 LOADMS 较大、AGE 约 0；再次点击 LOADMS 不变、AGE 明显增大。</p>\n"
    "<img src=\"%s\">\n</div>\n</body></html>\n" % html_attr(src)
)
open(os.path.join(ROOT, "qa21c", "ch1.html"), "w", encoding="utf-8", newline="\n").write(ch)
book = (
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>QA批21图片动作书C</title></head>\n<body>\n"
    '<h1 class="name">QA批21图片动作书C</h1>\n<span class="author">QA作者</span>\n'
    '<div class="intro">批21-A 大 jsLib 引擎缓存耗时观测。</div>\n'
    '<div class="chapters">\n<a class="chapter" href="%s/qa21c/ch1.html">第1章 大jsLib</a>\n</div>\n'
    "</body></html>\n" % HOST
)
open(os.path.join(ROOT, "qa21c", "book.html"), "w", encoding="utf-8", newline="\n").write(book)

source = {
    "bookSourceUrl": HOST + "/qa21c",
    "bookSourceName": "QA批21图片动作源C",
    "bookSourceGroup": "QA",
    "bookSourceType": 0,
    "bookUrlPattern": ".*192\\.168\\.100\\.52:8091/qa21c/book\\.html.*",
    "enabled": True,
    "enabledExplore": False,
    "customOrder": 0,
    "jsLib": js_lib,
    "ruleBookInfo": {"name": "class.name@text", "author": "class.author@text", "intro": "class.intro@text"},
    "ruleToc": {"chapterList": "class.chapter", "chapterName": "text", "chapterUrl": "href"},
    "ruleContent": {"content": "class.content@html"},
}
open(os.path.join(ROOT, "qa21c_source.json"), "w", encoding="utf-8", newline="\n").write(
    json.dumps(source, ensure_ascii=False, indent=2)
)

save_c = {"bookUrl": HOST + "/qa21c/book.html", "origin": HOST + "/qa21c", "originName": "QA批21图片动作源C",
          "name": "QA批21图片动作书C", "author": "QA作者", "type": 0, "group": 0, "canUpdate": True}
open(os.path.join(ROOT, "save_book_c.json"), "w", encoding="utf-8", newline="\n").write(
    json.dumps(save_c, ensure_ascii=False))
print("ok", os.path.getsize(os.path.join(ROOT, "qa21c_source.json")))
