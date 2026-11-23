DELETE FROM books WHERE bookUrl='/storage/emulated/0/Download/qa38_book.txt';
DELETE FROM chapters WHERE bookUrl='/storage/emulated/0/Download/qa38_book.txt';
INSERT OR REPLACE INTO books (bookUrl,tocUrl,origin,originName,name,author,type,"order",lastCheckTime,durChapterTime,latestChapterTime)
VALUES ('/storage/emulated/0/Download/qa38_book.txt','','loc_book','qa38_book.txt','QA38验收本地书','QA38',4096,1,1793300000000,1793300000000,1793300000000);
