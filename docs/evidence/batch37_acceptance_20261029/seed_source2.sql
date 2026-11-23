INSERT OR REPLACE INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, bookUrlPattern,
  customOrder, enabled, enabledExplore, jsLib, enabledCookieJar, concurrentRate,
  header, loginUrl, loginUi, loginCheckJs, coverDecodeJs, bookSourceComment,
  variableComment, variable, lastUpdateTime, respondTime, weight, exploreUrl,
  exploreScreen, ruleExplore, searchUrl, ruleSearch, ruleBookInfo, ruleToc,
  ruleContent, ruleReview, mainJs, eventListener, customButton
) VALUES (
  'https://qa37.local/mock2', 'QA37备用Mock源', 'QA37', 0, '',
  202, 1, 1, '', 0, '',
  '', '', '', '', '', '',
  '', '', 1793300000000, 100, 0,
  '',
  '',
  '{"bookList":"@css:.book-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href","kind":"@css:.kind@text"}',
  'http://192.168.100.52:18080/search?q={{key}}&page={{page}}',
  '{"bookList":"@css:.search-item","name":"@css:.name@text","author":"@css:.author@text","bookUrl":"a@href"}',
  '{"name":"@css:h1@text","author":"@css:.author@text","intro":"@css:.intro@text","coverUrl":"@css:.cover@src"}',
  '{"chapterList":"@css:.chapter","chapterName":"a@text","chapterUrl":"a@href"}',
  '{"content":"@css:.content@text"}',
  '', '', 0, 0
);
