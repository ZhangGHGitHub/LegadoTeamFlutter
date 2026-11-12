# -*- coding: utf-8 -*-
"""批21 QA 设备验收夹具生成器（宿主 HTTP 文档根：qa_b21/http）。"""
import json
import os

ROOT = r"C:/Users/admin/AppData/Local/Temp/qa_b21/http"
HOST = "http://192.168.100.52:8091"

# RAR4 样本（批21-B 条目名安全闸门只做条目名校验；条目名检查先于归档解析）
rar = open(r"D:/OH-WorkSpace/LegadoTeam/legado/tmp_debug/device_acceptance_20261027_7z/regression.rar", "rb").read()
RAR_HEX = rar.hex()
print("rar bytes", len(rar), "hex chars", len(RAR_HEX))

# 大 jsLib（约 600KB）：首次点击创建引擎时求值一次；缓存命中不重复求值
pad_lines = []
for i in range(6000):
    pad_lines.append("// qa21 lib padding line %05d " % i + "x" * 88)
lib_js = "\n".join(pad_lines) + "\n" + (
    "var __qa21_lib_ts = Date.now();\n"
    "function qa21lib(){ return 'lib-ok'; }\n"
)
open(os.path.join(ROOT, "lib.js"), "w", encoding="utf-8", newline="\n").write(lib_js)
print("lib.js bytes", os.path.getsize(os.path.join(ROOT, "lib.js")))

ACTIONS = {
    "ch1": (
        "globalThis.__qa21_clicks=(globalThis.__qa21_clicks||0)+1;"
        " var __age=(typeof __qa21_lib_ts==='number')?(Date.now()-__qa21_lib_ts):-1;"
        " java.toast('ACTION-CLICK-OK #'+globalThis.__qa21_clicks+' libAge='+__age+'ms')"
    ),
    "ch2": "java.toast('A'+'B')",
    "ch3": "java.openUrl('https://example.com')",
    "ch4": "java.openUrl('javascript:alert(1)')",
    "ch5": (
        "var r=java.getRarStringContent('" + RAR_HEX + "','../../etc/passwd');"
        " java.toast('RAR['+r.substring(0,26)+']')"
    ),
    "ch6": (
        "var h=java.queryTTF('file:///etc/hosts'); var o=JSON.parse(h);"
        " java.toast('TTFFILE valid='+o.valid+' err='+String(o.error||'').substring(0,14))"
    ),
    "ch7": (
        "var h=java.queryTTF('" + HOST + "/number.ttf'); var o=JSON.parse(h);"
        " java.toast('TTFHTTP valid='+o.valid+' type='+o.type)"
    ),
}

TITLES = {
    "ch1": "第1章 缓存连点",
    "ch2": "第2章 动态toast",
    "ch3": "第3章 openUrl-https",
    "ch4": "第4章 openUrl-js",
    "ch5": "第5章 RAR越界",
    "ch6": "第6章 TTF本地",
    "ch7": "第7章 TTF网络",
}
DESCS = {
    "ch1": "连续点击同一图片 3 次：toast 应递增显示 CLICK#1/#2/#3，libAge 持续增大（jsLib 只加载一次）。",
    "ch2": "点击图片：应弹出动态拼接消息 AB。",
    "ch3": "点击图片：https 外链应走统一链接策略（弹确认框），不是静默跳转。",
    "ch4": "点击图片：javascript: scheme 应被白名单拒绝，无弹窗无跳转。",
    "ch5": "点击图片：RAR 越界条目 ../../etc/passwd 应返回 [ERROR]，不返回文件内容。",
    "ch6": "点击图片：queryTTF('file:///etc/hosts') 应 valid=false 且带 error。",
    "ch7": "点击图片：合法 http 字体 url 应 valid=true type=url（不回归）。",
}


def html_attr(s):
    return s.replace("&", "&amp;").replace('"', "&quot;").replace("<", "&lt;").replace(">", "&gt;")


def chapter_page(key):
    src = HOST + "/t.png," + json.dumps({"click": ACTIONS[key]}, ensure_ascii=False)
    return (
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>%s</title></head>\n<body>\n"
        "<div class=\"content\">\n<p>%s</p>\n<img src=\"%s\">\n</div>\n</body></html>\n"
        % (TITLES[key], DESCS[key], html_attr(src))
    )


for key, title in TITLES.items():
    open(os.path.join(ROOT, "qa21a", key + ".html"), "w", encoding="utf-8", newline="\n").write(chapter_page(key))

chapters = "\n".join(
    '<a class="chapter" href="%s/qa21a/%s.html">%s</a>' % (HOST, k, TITLES[k]) for k in TITLES
)
book_a = (
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>QA批21图片动作书A</title></head>\n<body>\n"
    '<h1 class="name">QA批21图片动作书A</h1>\n<span class="author">QA作者</span>\n'
    '<div class="intro">批21 图片动作引擎缓存 / UI action 回传 / 文件访问门控。</div>\n'
    '<div class="chapters">\n%s\n</div>\n</body></html>\n' % chapters
)
open(os.path.join(ROOT, "qa21a", "book.html"), "w", encoding="utf-8", newline="\n").write(book_a)

# 源 B：独立书源 + 独立引擎；同名全局计数应从 1 开始（多源隔离）
src_b = HOST + "/t.png," + json.dumps(
    {"click": "globalThis.__qa21_clicks=(globalThis.__qa21_clicks||0)+1; java.toast('SOURCE-B ACTION-CLICK-OK #'+globalThis.__qa21_clicks)"},
    ensure_ascii=False,
)
ch_b = (
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>第1章 源B动作</title></head>\n<body>\n"
    "<div class=\"content\">\n<p>源 B 独立引擎：点击后计数应为 #1（与源 A 的缓存互不复用）。</p>\n"
    "<img src=\"%s\">\n</div>\n</body></html>\n" % html_attr(src_b)
)
open(os.path.join(ROOT, "qa21b", "ch1.html"), "w", encoding="utf-8", newline="\n").write(ch_b)
book_b = (
    "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"><title>QA批21图片动作书B</title></head>\n<body>\n"
    '<h1 class="name">QA批21图片动作书B</h1>\n<span class="author">QA作者</span>\n'
    '<div class="intro">批21 多源隔离。</div>\n'
    '<div class="chapters">\n<a class="chapter" href="%s/qa21b/ch1.html">第1章 源B动作</a>\n</div>\n'
    "</body></html>\n" % HOST
)
open(os.path.join(ROOT, "qa21b", "book.html"), "w", encoding="utf-8", newline="\n").write(book_b)


def source(name, key, with_lib):
    obj = {
        "bookSourceUrl": HOST + "/" + key,
        "bookSourceName": name,
        "bookSourceGroup": "QA",
        "bookSourceType": 0,
        "bookUrlPattern": ".*192\\.168\\.100\\.52:8091/%s/book\\.html.*" % key,
        "enabled": True,
        "enabledExplore": False,
        "customOrder": 0,
        "ruleBookInfo": {"name": "class.name@text", "author": "class.author@text", "intro": "class.intro@text"},
        "ruleToc": {"chapterList": "class.chapter", "chapterName": "text", "chapterUrl": "href"},
        "ruleContent": {"content": "class.content@html"},
    }
    if with_lib:
        obj["jsLib"] = json.dumps({"qa21lib": HOST + "/lib.js"}, ensure_ascii=False)
    return obj


open(os.path.join(ROOT, "qa21a_source.json"), "w", encoding="utf-8", newline="\n").write(
    json.dumps(source("QA批21图片动作源A", "qa21a", True), ensure_ascii=False, indent=2)
)
open(os.path.join(ROOT, "qa21b_source.json"), "w", encoding="utf-8", newline="\n").write(
    json.dumps(source("QA批21图片动作源B", "qa21b", False), ensure_ascii=False, indent=2)
)

save_a = {"bookUrl": HOST + "/qa21a/book.html", "origin": HOST + "/qa21a", "originName": "QA批21图片动作源A",
          "name": "QA批21图片动作书A", "author": "QA作者", "type": 0, "group": 0, "canUpdate": True}
save_b = {"bookUrl": HOST + "/qa21b/book.html", "origin": HOST + "/qa21b", "originName": "QA批21图片动作源B",
          "name": "QA批21图片动作书B", "author": "QA作者", "type": 0, "group": 0, "canUpdate": True}
open(os.path.join(ROOT, "save_book_a.json"), "w", encoding="utf-8", newline="\n").write(
    json.dumps(save_a, ensure_ascii=False))
open(os.path.join(ROOT, "save_book_b.json"), "w", encoding="utf-8", newline="\n").write(
    json.dumps(save_b, ensure_ascii=False))

print("generated files:")
for dirpath, _dirnames, filenames in os.walk(ROOT):
    for f in filenames:
        p = os.path.join(dirpath, f)
        print(" ", p.replace(ROOT, ""), os.path.getsize(p))
