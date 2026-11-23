BEGIN;
UPDATE books SET type=8, latestChapterTitle='第三章', totalChapterNum=3;
INSERT OR REPLACE INTO cached_chapters (book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) VALUES ('http://127.0.0.1:14984/book/1',0,'第一章','http://127.0.0.1:14984/chapter/1','第一章 回归正文。书架与阅读器冒烟验证，这是第一段正文内容。

第二段正文内容，用于验证阅读器分页与排版。',1793100462647,153);
INSERT OR REPLACE INTO cached_chapters (book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) VALUES ('http://127.0.0.1:14984/book/1',1,'第二章','http://127.0.0.1:14984/chapter/2','第二章 回归正文。用于验证翻章与进度显示。

第二段内容。',1793100462647,81);
INSERT OR REPLACE INTO cached_chapters (book_url,chapter_index,chapter_title,chapter_url,content,cached_at,size_bytes) VALUES ('http://127.0.0.1:14984/book/1',2,'第三章','http://127.0.0.1:14984/chapter/3','第三章 回归正文。最后一章。

结束。',1793100462647,51);
COMMIT;
