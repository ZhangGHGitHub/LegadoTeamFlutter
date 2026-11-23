PRAGMA foreign_keys=OFF;
DELETE FROM book_sources WHERE bookSourceUrl LIKE 'https://qa36.local/%';
INSERT OR REPLACE INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookUrlPattern,
  customOrder, enabled, enabledExplore, jsLib, enabledCookieJar, concurrentRate,
  header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, bookSourceComment,
  variableComment, variable, lastUpdateTime, respondTime, weight, exploreUrl,
  exploreScreen, ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
  ruleContent, ruleReview, mainJs, eventListener, customButton
) VALUES (
  'https://qa36.local/paged', 'QA36分页源', 'QA36', 0, '',
  101, 1, 1, '', 0, '',
  '', '', '', '', '', '',
  '', '', 1793300000000, 180000, 0,
  '玄幻::http://127.0.0.1:18080/explore?kind=xh&page={{page}}' || char(10) ||
  '都市::http://127.0.0.1:18080/explore?kind=ds',
  '',
  '{"bookList":"@css:.book-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href","kind":"@css:.kind@text"}',
  'http://127.0.0.1:18080/search?q={{key}}&page={{page}}',
  '{"bookList":"@css:.search-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href"}',
  '{"name":"@css:h1@text","author":"@css:.author@text","intro":"@css:.intro@text","coverUrl":"@css:.cover@src"}',
  '{"chapterList":"@css:.chapter","chapterName":"a@text","chapterUrl":"a@href"}',
  '{"content":"@css:.content@text"}',
  '', '', 0, 0
);
INSERT OR REPLACE INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookUrlPattern,
  customOrder, enabled, enabledExplore, jsLib, enabledCookieJar, concurrentRate,
  header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, bookSourceComment,
  variableComment, variable, lastUpdateTime, respondTime, weight, exploreUrl,
  exploreScreen, ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
  ruleContent, ruleReview, mainJs, eventListener, customButton
) VALUES (
  'https://qa36.local/nopage', 'QA36无页码源', 'QA36', 0, '',
  102, 1, 1, '', 0, '',
  '', '', '', '', '', '',
  '', '', 1793300000000, 180000, 0,
  '榜单::http://127.0.0.1:18080/explore?kind=xh',
  '',
  '{"bookList":"@css:.book-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href","kind":"@css:.kind@text"}',
  'http://127.0.0.1:18080/search?q={{key}}&page={{page}}',
  '{"bookList":"@css:.search-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href"}',
  '{"name":"@css:h1@text","author":"@css:.author@text","intro":"@css:.intro@text","coverUrl":"@css:.cover@src"}',
  '{"chapterList":"@css:.chapter","chapterName":"a@text","chapterUrl":"a@href"}',
  '{"content":"@css:.content@text"}',
  '', '', 0, 0
);
INSERT OR REPLACE INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookUrlPattern,
  customOrder, enabled, enabledExplore, jsLib, enabledCookieJar, concurrentRate,
  header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, bookSourceComment,
  variableComment, variable, lastUpdateTime, respondTime, weight, exploreUrl,
  exploreScreen, ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
  ruleContent, ruleReview, mainJs, eventListener, customButton
) VALUES (
  'https://qa36.local/deletable', 'QA36待删源', 'QA36', 0, '',
  103, 1, 1, '', 0, '',
  '', '', '', '', '', '',
  '', '', 1793300000000, 180000, 0,
  '删除分类::http://127.0.0.1:18080/explore?kind=ds&page={{page}}',
  '',
  '{"bookList":"@css:.book-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href","kind":"@css:.kind@text"}',
  'http://127.0.0.1:18080/search?q={{key}}&page={{page}}',
  '{"bookList":"@css:.search-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href"}',
  '{"name":"@css:h1@text","author":"@css:.author@text","intro":"@css:.intro@text","coverUrl":"@css:.cover@src"}',
  '{"chapterList":"@css:.chapter","chapterName":"a@text","chapterUrl":"a@href"}',
  '{"content":"@css:.content@text"}',
  '', '', 0, 0
);
UPDATE book_sources SET enabledExplore=0 WHERE bookSourceUrl='https://example.com/source-p25';
