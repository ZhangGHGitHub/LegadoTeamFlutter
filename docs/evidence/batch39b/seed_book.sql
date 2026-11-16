
INSERT OR REPLACE INTO books (bookUrl, tocUrl, origin, originName, name, author, type, "group",
 latestChapterTitle, latestChapterTime, lastCheckTime, lastCheckCount, totalChapterNum,
 durChapterTitle, durChapterIndex, durChapterPos, durChapterTime, canUpdate, "order", originOrder,
 originBookUrl, variable)
VALUES ('http://192.168.100.52:18090/book/1','http://192.168.100.52:18090/book/1','http://192.168.100.52:18090','QA39B-B-目录并发','QA39B-B-测试书一','作者甲',0,0,
 '第3章',1700000000000,0,0,3,
 '第1章',0,0,0,1,0,0,'http://192.168.100.52:18090/book/1','');
