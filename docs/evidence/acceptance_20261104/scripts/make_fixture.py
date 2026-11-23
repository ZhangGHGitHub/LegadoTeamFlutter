import base64, hashlib, json, os, sqlite3, struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(ROOT, "fixture_payload")
os.makedirs(FIX, exist_ok=True)

BOOK_C = "/data/user/0/io.legado.flutter_legado/cache/file_picker/qa_c/qa_b2c_book_c.txt"
COMIC_URL = "http://192.168.100.52:8899/comic/qa9b3"
CHAPTER_URL = "http://192.168.100.52:8899/comic/ch{}.html"
IMG_URL = "http://192.168.100.52:8899/comic/img{}.png"

def book_dir_name(book_url):
    san = "".join(c if (c.isalnum() and c.isascii()) or c in "._-" else "_" for c in book_url)
    san = san[:64]
    return san + "_" + hashlib.md5(book_url.encode()).hexdigest()[:8]

def fname(url):
    h = hashlib.md5(url.encode()).hexdigest()
    suffix = "png"  # imgN.png
    return f"{h[8:24]}.{suffix}"

# 1x1 transparent PNG
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)
img_dir = os.path.join(FIX, "images")
os.makedirs(img_dir, exist_ok=True)
names = []
for i in range(18):
    n = fname(IMG_URL.format(i))
    names.append(n)
    with open(os.path.join(img_dir, n), "wb") as f:
        f.write(PNG)
# 窗口外多余文件（无章节引用）
for extra in ["deadbeefdeadbeef.png", "ffffffffffffffff.png", "notimage.png"]:
    with open(os.path.join(img_dir, extra), "wb") as f:
        f.write(PNG)
# 子目录/符号链接（验证不递归/不跟随）——符号链接在设备侧创建
os.makedirs(os.path.join(img_dir, "nested"), exist_ok=True)
with open(os.path.join(img_dir, "nested", "inner.png"), "wb") as f:
    f.write(PNG)

# 本地书 C 文件
os.makedirs(os.path.join(FIX, "loc"), exist_ok=True)
with open(os.path.join(FIX, "loc", "qa_b2c_book_c.txt"), "w", encoding="utf-8", newline="\n") as f:
    f.write("QA_B2C 未读测试书C\n作者：丙作者\n第一章 启程\n这是未读书C的第一章正文。\n第二章 抵达\n这是未读书C的第二章正文。\n")

# SQL
def q(s):
    return "'" + s.replace("'", "''") + "'"

lines = []
lines.append("BEGIN;")
lines.append(f"""INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,kind,customTag,coverUrl,customCoverUrl,intro,customIntro,charset,type,"group",latestChapterTitle,latestChapterTime,lastCheckTime,lastCheckCount,totalChapterNum,durChapterTitle,durChapterIndex,durVolumeIndex,chapterInVolumeIndex,durChapterPos,durChapterTime,wordCount,canUpdate,disableReadRecord,"order",originOrder,variable,readConfig,syncTime,infoHtml,tocHtml,downloadUrls,coverOrigin,originBookUrl)
VALUES ({q(BOOK_C)},'', 'loc_book','qa_b2c_book_c.txt','qa_b2c_book_c','','','','','','','','',4096,0,'第二章 抵达',0,0,0,2,'',0,0,0,0,0,'',1,0,0,0,'','',0,'','','','','');""")
for i,t in enumerate(["第一章 启程","第二章 抵达"]):
    lines.append(f"INSERT OR REPLACE INTO chapters (url,title,isVolume,baseUrl,bookUrl,\"index\",isVip,isPay,resourceUrl,tag,wordCount,start,end,startFragmentId,endFragmentId,variable,imgUrl) VALUES ({q(f'txt://chapter/{i}')},{q(t)},0,{q(BOOK_C)},{q(BOOK_C)},{i},0,0,'','','',0,0,'','','','');")

lines.append(f"""INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,kind,customTag,coverUrl,customCoverUrl,intro,customIntro,charset,type,"group",latestChapterTitle,latestChapterTime,lastCheckTime,lastCheckCount,totalChapterNum,durChapterTitle,durChapterIndex,durVolumeIndex,chapterInVolumeIndex,durChapterPos,durChapterTime,wordCount,canUpdate,disableReadRecord,"order",originOrder,variable,readConfig,syncTime,infoHtml,tocHtml,downloadUrls,coverOrigin,originBookUrl)
VALUES ({q(COMIC_URL)},'', 'http://192.168.100.52:8899','QA漫画源','QA9B3_COMIC','QA作者','漫画','','','','QA 9b-3 图片保留夹具','','',64,0,'第18章',0,0,0,18,'第6章',5,0,0,0,0,'',1,0,0,0,'','',0,'','','','','');""")
for i in range(18):
    cu = CHAPTER_URL.format(i)
    lines.append(f"INSERT OR REPLACE INTO chapters (url,title,isVolume,baseUrl,bookUrl,\"index\",isVip,isPay,resourceUrl,tag,wordCount,start,end,startFragmentId,endFragmentId,variable,imgUrl) VALUES ({q(cu)},{q(f'第{i+1}章')},0,{q(COMIC_URL)},{q(COMIC_URL)},{i},0,0,'','','',0,0,'','','','');")
    if 3 <= i <= 15:
        content = f'<p>第{i+1}章图片</p><img src="{IMG_URL.format(i)}">'
        lines.append(f"INSERT OR REPLACE INTO cached_chapters (book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) VALUES ({q(COMIC_URL)},{i},{q(f'第{i+1}章')},{q(cu)},{q(content)},0,{len(content.encode('utf-8'))});")
lines.append("COMMIT;")
sql = "\n".join(lines)
with open(os.path.join(FIX, "seed.sql"), "w", encoding="utf-8", newline="\n") as f:
    f.write(sql)

meta = {
    "book_c": BOOK_C,
    "comic_url": COMIC_URL,
    "book_dir": book_dir_name(COMIC_URL),
    "image_names": names,
    "counts": {"chapters": 18, "cached": 13, "images": len(names)},
}
with open(os.path.join(FIX, "meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, ensure_ascii=False, indent=2)
print(json.dumps(meta, ensure_ascii=False, indent=2))
