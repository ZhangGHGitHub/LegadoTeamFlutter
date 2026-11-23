
PRAGMA foreign_keys=ON;
INSERT OR REPLACE INTO book_sources
  (bookSourceUrl, bookSourceName, bookSourceType, lastUpdateTime, respondTime, weight)
  VALUES ('https://qa9b1.example/source', 'QA9B1测试源', 0, 0, 0, 0);

DELETE FROM searchBooks WHERE bookUrl LIKE 'qa9b1_%';
INSERT OR REPLACE INTO searchBooks (bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES ('qa9b1_s1_2d','https://qa9b1.example/source','QA9B1测试源',0,'QA旧书-2天','QA作者','https://qa9b1.example/source/toc/QA旧书-2天', 1793272809514, 0);
INSERT OR REPLACE INTO searchBooks (bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES ('qa9b1_s1_1d1m','https://qa9b1.example/source','QA9B1测试源',0,'QA旧书-1天1分','QA作者','https://qa9b1.example/source/toc/QA旧书-1天1分', 1793359149514, 0);
INSERT OR REPLACE INTO searchBooks (bookUrl,origin,originName,type,name,author,tocUrl,time,originOrder) VALUES ('qa9b1_s1_1h','https://qa9b1.example/source','QA9B1测试源',0,'QA新书-1小时','QA作者','https://qa9b1.example/source/toc/QA新书-1小时', 1793442009514, 0);
-- base_ms=1793445609514
