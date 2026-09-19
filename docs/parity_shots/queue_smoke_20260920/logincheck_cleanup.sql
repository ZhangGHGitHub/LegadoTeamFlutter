DELETE FROM book_sources WHERE bookSourceUrl LIKE 'http://127.0.0.1:18080/probe%%';
UPDATE book_sources SET enabled=1 WHERE bookSourceUrl NOT LIKE 'http://127.0.0.1:18080/probe%%';
