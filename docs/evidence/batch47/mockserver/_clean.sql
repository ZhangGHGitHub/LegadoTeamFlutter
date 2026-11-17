DELETE FROM chapters WHERE bookUrl = 'http://192.168.100.52:8099/book/1';
DELETE FROM books WHERE bookUrl = 'http://192.168.100.52:8099/book/1';
DELETE FROM book_sources WHERE bookSourceUrl = 'http://192.168.100.52:8099/home';
DELETE FROM cached_chapters WHERE book_url = 'http://192.168.100.52:8099/book/1';