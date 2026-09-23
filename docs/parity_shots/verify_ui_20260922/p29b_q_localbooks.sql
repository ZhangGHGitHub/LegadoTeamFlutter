SELECT 'LOCAL: '||bookUrl||' | name='||name||' | type='||type||' | origin='||COALESCE(origin,'NULL') FROM books WHERE origin='loc_book' OR origin LIKE 'dav:%' OR origin LIKE '%loc_book%';
SELECT 'ALL: '||bookUrl||' | name='||name||' | type='||type||' | origin='||COALESCE(origin,'NULL') FROM books;
