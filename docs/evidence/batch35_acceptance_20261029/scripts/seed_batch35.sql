-- 批35 设备验收种子数据（schema 117 后执行）
DELETE FROM books;
DELETE FROM chapters;
DELETE FROM readRecord;
DELETE FROM readRecordDaily;

INSERT INTO books ("bookUrl","tocUrl","origin","originName","name","author","kind","customTag","coverUrl","customCoverUrl","intro","customIntro","charset","type","group","latestChapterTitle","latestChapterTime","lastCheckTime","lastCheckCount","totalChapterNum","durChapterTitle","durChapterIndex","durVolumeIndex","chapterInVolumeIndex","durChapterPos","durChapterTime","wordCount","canUpdate","order","originOrder","variable","readConfig","syncTime","infoHtml","tocHtml","downloadUrls","coverOrigin","originBookUrl","disableReadRecord") VALUES
('books/qa_batch35_tags.txt','','loc_book','本地','QA35标签书','验收','玄幻,修真','都市,爽文',NULL,NULL,'标签验收书','',NULL,0,0,'第一章',0,0,0,1,'第一章',0,0,0,0,0,'12.3万字',1,1,0,'','{}',0,'','','','','',0),
('https://example.com/qa35_empty','https://example.com/qa35_empty','https://example.com','示例源','QA35空标签书','验收',NULL,NULL,NULL,NULL,'空标签验收书','',NULL,0,0,'',0,0,0,0,'',0,0,0,0,0,NULL,1,2,0,'','{}',0,'','','','','',0),
('books/qa_batch35_read.txt','','loc_book','本地','QA35阅读书','验收',NULL,NULL,NULL,NULL,'阅读记录开关验收书','',NULL,0,0,'第二章 继续',0,0,0,2,'第一章 起点',0,0,0,0,0,NULL,1,3,0,'','{}',0,'','','','','',0),
('books/qa_batch35_other.txt','','loc_book','本地','QA35对照书','验收',NULL,NULL,NULL,NULL,'对照书','',NULL,0,0,'第二章 对照',0,0,0,2,'第一章 对照',0,0,0,0,0,NULL,1,4,0,'','{}',0,'','','','','',0),
('books/qa_batch35_delete.txt','','loc_book','本地','QA35删除本地书','验收',NULL,NULL,NULL,NULL,'删除源文件验收书','',NULL,0,0,'',0,0,0,1,'',0,0,0,0,0,NULL,1,5,0,'','{}',0,'','','','','',0),
('https://example.com/qa_batch35_online.txt','','https://example.com','示例源','QA35在线书','验收',NULL,NULL,NULL,NULL,'在线书删除记录验收','',NULL,0,0,'',0,0,0,0,'',0,0,0,0,0,NULL,1,6,0,'','{}',0,'','','','','',0),
('/sdcard/Download/qa_batch35_outside.txt','','loc_book','本地','QA35越界书','验收',NULL,NULL,NULL,NULL,'应用目录外文件','',NULL,0,0,'',0,0,0,0,'',0,0,0,0,0,NULL,1,7,0,'','{}',0,'','','','','',0),
('books/qa_batch35_symlink.txt','','loc_book','本地','QA35链接书','验收',NULL,NULL,NULL,NULL,'符号链接文件','',NULL,0,0,'',0,0,0,0,'',0,0,0,0,0,NULL,1,8,0,'','{}',0,'','','','','',0);

INSERT INTO readRecord (deviceId,bookName,author,readTime,lastRead,lastChapterTitle,lastChapterIndex,lastChapterPos,coverUrl,resolvedAuthor,displayBookName,displayAuthor,metadataEditedAt) VALUES
('','QA35阅读书','',60000,0,'第一章 起点',0,0,NULL,NULL,'','',0),
('','QA35对照书','',60000,0,'第一章 对照',0,0,NULL,NULL,'','',0);
