DELETE FROM cached_chapters WHERE book_url LIKE '%/b33/book/%';
SELECT count(*) FROM cached_chapters;
