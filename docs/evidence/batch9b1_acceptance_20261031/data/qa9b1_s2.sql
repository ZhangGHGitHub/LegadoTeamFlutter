
PRAGMA foreign_keys=ON;
INSERT OR REPLACE INTO book_sources
  (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight)
  VALUES ('https://qa9b1.example/source', 'QA9B1测试源', 0, 0, 0, 0);

DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';
INSERT OR REPLACE INTO searchBooks (bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES ('qa9b1_s2_3d','https://qa9b1.example/source','QA9B1测试源',0,'QA旧书S2-3天','QA作者','https://qa9b1.example/source/toc/QA旧书S2-3天', 1793186531846, 0);
INSERT OR REPLACE INTO searchBooks (bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES ('qa9b1_s2_2d','https://qa9b1.example/source','QA9B1测试源',0,'QA旧书S2-2天','QA作者','https://qa9b1.example/source/toc/QA旧书S2-2天', 1793272931846, 0);
INSERT OR REPLACE INTO searchBooks (bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES ('qa9b1_s2_1h','https://qa9b1.example/source','QA9B1测试源',0,'QA新书S2-1小时','QA作者','https://qa9b1.example/source/toc/QA新书S2-1小时', 1793442131846, 0);
-- base_ms=1793445731846
