DELETE FROM chapter_reviews WHERE book_url LIKE '%/b33/book/A';
INSERT INTO chapter_reviews (book_url, chapter_index, paragraph_index, content, author, created_at, like_count)
VALUES ('http://192.168.100.52:8099/b33/book/A', 0, 1, 'b33 段评：文件 API 验收通过', 'b33qa', 1794680000000, 3);
DELETE FROM highlightRules WHERE uuid='b33qa-rule-1';
INSERT INTO highlightRules (uuid, name, pattern, isRegex, scope, isEnabled, style, sortOrder, timeoutMillisecond, "group", applyToTitle, applyToBody)
VALUES ('b33qa-rule-1', 'b33高亮规则', 'BATCH33_TEXT_OK', 0, NULL, 1, '{"textColor":"#FF0000"}', 0, 1000, '', 0, 1);
SELECT 'REVIEW', book_url, chapter_index, paragraph_index, content FROM chapter_reviews WHERE book_url LIKE '%/b33/book/A';
SELECT 'RULE', uuid, pattern, style FROM highlightRules WHERE uuid='b33qa-rule-1';
