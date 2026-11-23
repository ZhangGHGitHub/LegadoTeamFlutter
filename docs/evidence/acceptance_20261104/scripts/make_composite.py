import base64, hashlib, json, os
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX=os.path.join(ROOT,'fixture_payload')
BOOK='http://192.168.100.52:8899/comic/qa9b3c'
def q(s): return "'"+s.replace("'","''")+"'"
def mid(url):
    return hashlib.md5(url.encode()).hexdigest()[8:24]
def suffix(url):
    u=url.split('?')[0].split('#')[0]
    last=u.rsplit('/',1)[-1]
    i=last.rfind('.')
    s=last[i+1:] if i>=0 else ''
    return s if s and len(s)<=5 and s.isalnum() else 'jpg'
def cname(url): return mid(url)+'.'+suffix(url)
full0='http://192.168.100.52:8899/comic/cc0.png,{"headers":{"Referer":"http://x"}}'
full1='http://192.168.100.52:8899/comic/cc1.png,{"headers":{"Referer":"http://x"}}'
base0=full0.split(',{')[0]; base1=full1.split(',{')[0]
plain3='http://192.168.100.52:8899/comic/cc3.png'
dirp=os.path.join(FIX,'images_composite'); os.makedirs(dirp,exist_ok=True)
png=base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")
files={cname(full0):'keep-full0', cname(full1):'keep-full1', cname(plain3):'keep-plain3',
       cname(base0):'drop-trunc0', cname(base1):'drop-trunc1', 'outside.png':'drop-outside'}
for n in files: open(os.path.join(dirp,n),'wb').write(png)
# write suffix mismatch file too (png name of full URL) to ensure only exact keep set survives
mismatch=mid(full0)+'.png'
open(os.path.join(dirp,mismatch),'wb').write(png); files[mismatch]='drop-mismatch'
lines=['BEGIN;']
book_cols='(bookUrl,tocUrl,origin,originName,name,author,kind,customTag,coverUrl,customCoverUrl,intro,customIntro,charset,type,"group",latestChapterTitle,latestChapterTime,lastCheckTime,lastCheckCount,totalChapterNum,durChapterTitle,durChapterIndex,durVolumeIndex,chapterInVolumeIndex,durChapterPos,durChapterTime,wordCount,canUpdate,disableReadRecord,"order",originOrder,variable,readConfig,syncTime,infoHtml,tocHtml,downloadUrls,coverOrigin,originBookUrl)'
lines.append(f"INSERT OR REPLACE INTO books {book_cols} VALUES ({q(BOOK)},'', 'http://192.168.100.52:8899','QA漫画源','QA9B3_COMPOSITE','QA作者','漫画','','','','复合URL夹具','','',64,0,'第5章',0,0,0,5,'第2章',1,0,0,0,0,'',1,0,0,0,'','',0,'','','','','');")
contents={0:f"<img src='{full0}'>",1:f"<img src='{full1}'>",3:f'<img src="{plain3}">'}
for i in range(5):
    url=f'http://192.168.100.52:8899/comic/cc{i}.html'
    vol=1 if i==2 else 0
    lines.append(f"INSERT OR REPLACE INTO chapters (url,title,isVolume,baseUrl,bookUrl,\"index\",isVip,isPay,resourceUrl,tag,wordCount,start,end,startFragmentId,endFragmentId,variable,imgUrl) VALUES ({q(url)},{q(f'第{i+1}章')},{vol},{q(BOOK)},{q(BOOK)},{i},0,0,'','','',0,0,'','','','');")
    if i in contents:
        c=contents[i]
        lines.append(f"INSERT OR REPLACE INTO cached_chapters (book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) VALUES ({q(BOOK)},{i},{q(f'第{i+1}章')},{q(url)},{q(c)},0,{len(c.encode('utf-8'))});")
lines.append('COMMIT;')
open(os.path.join(FIX,'seed_composite.sql'),'w',encoding='utf-8',newline='\n').write('\n'.join(lines))
meta={'book':BOOK,'dir':dirp,'keep':[cname(full0),cname(full1),cname(plain3)],'drop':[cname(base0),cname(base1),'outside.png',mismatch],'files':files}
open(os.path.join(FIX,'meta_composite.json'),'w',encoding='utf-8').write(json.dumps(meta,ensure_ascii=False,indent=2))
print(json.dumps(meta,ensure_ascii=False,indent=2))
