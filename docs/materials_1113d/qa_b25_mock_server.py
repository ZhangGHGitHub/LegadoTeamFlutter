"""Batch 25 QA mock source server (paragraph review fixture).

Serves a book info/toc page, chapter content pages, and review summary/detail
JSON. Used only for device acceptance evidence; not part of the product.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BOOK_HTML = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>QA25 段评书</title></head>
<body>
<h1 class="name">QA25 段评书</h1>
<div class="author">QA作者</div>
<div class="intro">用于批25 段评面板验收的本地书。</div>
<ul id="list">
  <li><a href="/chapter1.html">第一章 段评章</a></li>
  <li><a href="/chapter2.html">第二章 后续</a></li>
  <li><a href="/chapter3.html">第三章</a></li>
  <li><a href="/chapter4.html">第四章</a></li>
  <li><a href="/chapter5.html">第五章 远跳</a></li>
  <li><a href="/chapter6.html">第六章</a></li>
</ul>
</body></html>
"""

CHAPTERS = {
    "/chapter1.html": """<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<div class="content">
<p>第一段：这一章用于验证段评摘要徽标与详情面板。</p>
<p>第二段：本段应显示段评数量徽标一。</p>
<p>第三段：本段应显示段评数量徽标二。</p>
<p>第四段：本段用于确认正文渲染正常。</p>
</div>
</body></html>
""",
    "/chapter2.html": """<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<div class="content">
<p>第二章第一段：普通正文。</p>
<p>第二章第二段：普通正文。</p>
</div>
</body></html>
""",
    "/chapter5.html": """<!DOCTYPE html>
<html><head><meta charset="utf-8"></head><body>
<div class="content">
<p>第五章第一段：远跳章节，用于触发非预加载的正文加载。</p>
<p>第五章第二段：本段应显示段评数量徽标一。</p>
<p>第五章第三段：本段应显示段评数量徽标二。</p>
</div>
</body></html>
""",
}

for _n in (3, 4, 6):
    CHAPTERS[f"/chapter{_n}.html"] = (
        "<!DOCTYPE html>\n<html><head><meta charset=\"utf-8\"></head><body>"
        f"<div class=\"content\"><p>第{_n}章第一段：普通正文。</p>"
        f"<p>第{_n}章第二段：普通正文。</p></div></body></html>\n"
    )

SUMMARY = {
    "data": [
        {"idx": 1, "cnt": 7, "token": "p1"},
        {"idx": 2, "cnt": 3, "token": "p2"},
        {"idx": 3, "cnt": 0, "token": "p3"},
    ]
}

DETAIL = {
    "comments": [
        {
            "id": "c1",
            "user": "QA读者甲",
            "text": json.dumps(
                {"text": "批25 段评正文：这一段的讨论很热闹。", "replyToName": "楼主", "time": "昨天"},
                ensure_ascii=False,
            ),
            "tag": "QA",
        },
        {
            "id": "c2",
            "user": "QA读者乙",
            "text": json.dumps(
                {"text": "批25 段评正文：同意楼上。", "replyToName": "", "time": "今天"},
                ensure_ascii=False,
            ),
            "tag": "",
        },
    ]
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        with open(sys.argv[2], "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (self.command, self.path))

    def _send(self, body, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path in ("/", "/book1.html"):
            self._send(BOOK_HTML)
        elif path in CHAPTERS:
            self._send(CHAPTERS[path])
        elif path == "/review/summary":
            self._send(json.dumps(SUMMARY, ensure_ascii=False), "application/json; charset=utf-8")
        elif path == "/review/detail":
            qs = parse_qs(parsed.query)
            page = qs.get("page", ["1"])[0]
            if page == "2":
                self._send(json.dumps({"comments": []}, ensure_ascii=False),
                           "application/json; charset=utf-8")
            else:
                self._send(json.dumps(DETAIL, ensure_ascii=False), "application/json; charset=utf-8")
        else:
            self.send_response(404)
            self.end_headers()


if __name__ == "__main__":
    port = int(sys.argv[1])
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
