delete from book_sources where bookSourceGroup='QA39B' or bookSourceUrl like '%192.168.100.52:18090%';
delete from books where bookUrl like '%192.168.100.52:18090%';
delete from chapters where bookUrl like '%192.168.100.52:18090%';
delete from highlights where bookUrl like '%192.168.100.52:18090%';
select 'remaining_sources', count(*) from book_sources;
select 'remaining_books', count(*) from books;
