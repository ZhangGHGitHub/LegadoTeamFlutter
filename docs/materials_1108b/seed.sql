DELETE FROM books;
DELETE FROM book_groups;
INSERT INTO book_groups (groupId,groupName,cover,[order],enableRefresh,show,bookSort,onlyUpdateRead) VALUES
 (1,'测试组甲',NULL,0,1,1,-1,0),
 (2,'测试组乙',NULL,1,1,1,-1,0);
INSERT INTO books (bookUrl,origin,originName,name,author,type,[group],latestChapterTitle,latestChapterTime,lastCheckTime,totalChapterNum,durChapterTitle,durChapterIndex,durChapterTime,canUpdate) VALUES
 ('/sdcard/Download/qa6a2b/甲书一.txt','loc_book','本地','甲书一','作者甲一',4096,1,'第一章',(strftime('%s','now')*1000-60000),(strftime('%s','now')*1000-60000),3,'第一章',0,(strftime('%s','now')*1000-60000),1),
 ('/sdcard/Download/qa6a2b/甲书二.txt','loc_book','本地','甲书二','作者甲二',4096,1,'第一章',(strftime('%s','now')*1000-120000),(strftime('%s','now')*1000-120000),3,'第一章',0,(strftime('%s','now')*1000-120000),1),
 ('/sdcard/Download/qa6a2b/甲书三.txt','loc_book','本地','甲书三','作者甲三',4096,1,'第一章',(strftime('%s','now')*1000-180000),(strftime('%s','now')*1000-180000),3,'第一章',0,(strftime('%s','now')*1000-180000),1),
 ('/sdcard/Download/qa6a2b/甲书四.txt','loc_book','本地','甲书四','作者甲四',4096,1,'第一章',(strftime('%s','now')*1000-240000),(strftime('%s','now')*1000-240000),3,'第一章',0,(strftime('%s','now')*1000-240000),1),
 ('/sdcard/Download/qa6a2b/乙书一.txt','loc_book','本地','乙书一','作者乙一',4096,2,'第一章',(strftime('%s','now')*1000-300000),(strftime('%s','now')*1000-300000),3,'第一章',0,(strftime('%s','now')*1000-300000),1),
 ('/sdcard/Download/qa6a2b/乙书二.txt','loc_book','本地','乙书二','作者乙二',4096,2,'第一章',(strftime('%s','now')*1000-360000),(strftime('%s','now')*1000-360000),3,'第一章',0,(strftime('%s','now')*1000-360000),1),
 ('/sdcard/Download/qa6a2b/乙书三.txt','loc_book','本地','乙书三','作者乙三',4096,2,'第一章',(strftime('%s','now')*1000-420000),(strftime('%s','now')*1000-420000),3,'第一章',0,(strftime('%s','now')*1000-420000),1),
 ('/sdcard/Download/qa6a2b/乙书四.txt','loc_book','本地','乙书四','作者乙四',4096,2,'第一章',(strftime('%s','now')*1000-480000),(strftime('%s','now')*1000-480000),3,'第一章',0,(strftime('%s','now')*1000-480000),1);
