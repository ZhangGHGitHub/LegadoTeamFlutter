PRAGMA foreign_keys=OFF;
DELETE FROM books WHERE bookUrl LIKE '/storage/emulated/0/Download/qa37_%' OR bookUrl='http://192.168.100.52:18080/book/mock-1';
DELETE FROM chapters WHERE bookUrl LIKE '/storage/emulated/0/Download/qa37_%' OR bookUrl='http://192.168.100.52:18080/book/mock-1';
DELETE FROM book_sources WHERE bookSourceUrl='https://qa37.local/mock';

INSERT OR REPLACE INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookUrlPattern,
  customOrder, enabled, enabledExplore, jsLib, enabledCookieJar, concurrentRate,
  header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, bookSourceComment,
  variableComment, variable, lastUpdateTime, respondTime, weight, exploreUrl,
  exploreScreen, ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
  ruleContent, ruleReview, mainJs, eventListener, customButton
) VALUES (
  'https://qa37.local/mock', 'QA37本地Mock源', 'QA37', 0, '',
  201, 1, 1, '', 0, '',
  '', '', '', '', '', '',
  '', '', 1793300000000, 100, 0,
  '玄幻::http://192.168.100.52:18080/explore?kind=xh&page={{page}}',
  '',
  '{"bookList":"@css:.book-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href","kind":"@css:.kind@text"}',
  'http://192.168.100.52:18080/search?q={{key}}&page={{page}}',
  '{"bookList":"@css:.search-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href"}',
  '{"name":"@css:h1@text","author":"@css:.author@text","intro":"@css:.intro@text","coverUrl":"@css:.cover@src"}',
  '{"chapterList":"@css:.chapter","chapterName":"a@text","chapterUrl":"a@href"}',
  '{"content":"@css:.content@text"}',
  '', '', 0, 0
);

INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,type,"order",lastCheckTime,durChapterTime)
VALUES ('http://192.168.100.52:18080/book/mock-1','','https://qa37.local/mock','QA37本地Mock源','QA37在线书','QA36作者',0,1,1793300000000,1793300000000);

INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,type,"order",lastCheckTime,durChapterTime)
VALUES ('/storage/emulated/0/Download/qa37_gbk.txt','','loc_book','qa37_gbk.txt','qa37_gbk','',4096,2,1793300000000,1793300000000);

INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,type,"order",lastCheckTime,durChapterTime)
VALUES ('/storage/emulated/0/Download/qa37_utf8.txt','','loc_book','qa37_utf8.txt','qa37_utf8','',4096,3,1793300000000,1793300000000);

INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,type,"order",lastCheckTime,durChapterTime)
VALUES ('/storage/emulated/0/Download/qa37_utf8.epub','','loc_book','qa37_utf8.epub','QA37验收EPUB','QA37',4096,4,1793300000000,1793300000000);

INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,type,"order",lastCheckTime,durChapterTime)
VALUES ('/storage/emulated/0/Download/qa37_dav.epub','','webDav::http://192.168.100.52:18081/dav/books/qa37_dav.epub,{"serverID":9001}','qa37_dav.epub','QA37WebDAV验收EPUB','QA37',4096,5,1793300000000,1793300000000);
