-- 批33 设备验收种子：5 本书 + 章节（正文规则走文件 API @js）
-- 仅用于测试档（debug 变体，run-as 可读），不提交进产品
DELETE FROM chapters WHERE bookUrl LIKE 'http://192.168.100.52:8099/b33/book/%';
DELETE FROM books WHERE bookUrl LIKE 'http://192.168.100.52:8099/b33/book/%';

INSERT OR REPLACE INTO books
(bookUrl, tocUrl, origin, originName, name, author, kind, type, "group",
 latestChapterTitle, latestChapterTime, totalChapterNum, durChapterTitle,
 durChapterIndex, canUpdate, "order", originOrder, originBookUrl, intro)
VALUES
('http://192.168.100.52:8099/b33/book/A','http://192.168.100.52:8099/b33/book/A',
 'http://192.168.100.52:8099/b33/source/A','B33-A-文本下载','B33A','b33qa','测试',0,0,
 'CH-A',0,1,'CH-A',0,0,0,0,'http://192.168.100.52:8099/b33/book/A','b33 A 文本下载'),
('http://192.168.100.52:8099/b33/book/B','http://192.168.100.52:8099/b33/book/B',
 'http://192.168.100.52:8099/b33/source/B','B33-B-二进制zip','B33B','b33qa','测试',0,0,
 'CH-B',0,1,'CH-B',0,0,0,0,'http://192.168.100.52:8099/b33/book/B','b33 B 二进制 zip'),
('http://192.168.100.52:8099/b33/book/C','http://192.168.100.52:8099/b33/book/C',
 'http://192.168.100.52:8099/b33/source/C','B33-C-超限拒绝','B33C','b33qa','测试',0,0,
 'CH-C1',0,2,'CH-C1',0,0,0,0,'http://192.168.100.52:8099/b33/book/C','b33 C 超限'),
('http://192.168.100.52:8099/b33/book/D1','http://192.168.100.52:8099/b33/book/D1',
 'http://192.168.100.52:8099/b33/source/D1','B33-D1-下载方','B33D1','b33qa','测试',0,0,
 'CH-D1',0,1,'CH-D1',0,0,0,0,'http://192.168.100.52:8099/b33/book/D1','b33 D1 下载方'),
('http://192.168.100.52:8099/b33/book/D2','http://192.168.100.52:8099/b33/book/D2',
 'http://192.168.100.52:8099/b33/source/D2','B33-D2-跨源探测','B33D2','b33qa','测试',0,0,
 'CH-D2',0,1,'CH-D2',0,0,0,0,'http://192.168.100.52:8099/b33/book/D2','b33 D2 跨源探测');

INSERT OR REPLACE INTO chapters
(url, title, isVolume, baseUrl, bookUrl, "index", isVip, isPay)
VALUES
('http://192.168.100.52:8099/b33/ch/a','CH-A',0,'http://192.168.100.52:8099/b33/ch/a','http://192.168.100.52:8099/b33/book/A',0,0,0),
('http://192.168.100.52:8099/b33/ch/b','CH-B',0,'http://192.168.100.52:8099/b33/ch/b','http://192.168.100.52:8099/b33/book/B',0,0,0),
('http://192.168.100.52:8099/b33/ch/huge','CH-C1',0,'http://192.168.100.52:8099/b33/ch/huge','http://192.168.100.52:8099/b33/book/C',0,0,0),
('http://192.168.100.52:8099/b33/ch/huge_chunked','CH-C2',0,'http://192.168.100.52:8099/b33/ch/huge_chunked','http://192.168.100.52:8099/b33/book/C',1,0,0),
('http://192.168.100.52:8099/b33/ch/d1','CH-D1',0,'http://192.168.100.52:8099/b33/ch/d1','http://192.168.100.52:8099/b33/book/D1',0,0,0),
('http://192.168.100.52:8099/b33/ch/d2','CH-D2',0,'http://192.168.100.52:8099/b33/ch/d2','http://192.168.100.52:8099/b33/book/D2',0,0,0);

-- 独立查询：确认书源与书已就位
SELECT 'SRC', bookSourceUrl, bookSourceName FROM book_sources WHERE bookSourceGroup='B33QA';
SELECT 'BOOK', name, bookUrl, totalChapterNum FROM books WHERE bookUrl LIKE '%/b33/book/%';
SELECT 'CH', bookUrl, "index", url FROM chapters WHERE bookUrl LIKE '%/b33/book/%' ORDER BY bookUrl, "index";
