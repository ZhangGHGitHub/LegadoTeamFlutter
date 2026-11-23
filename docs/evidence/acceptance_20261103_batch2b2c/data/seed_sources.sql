-- QA 2b-2c 设备验收测试夹具（仅测试实例使用）
INSERT OR REPLACE INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceGroup, bookSourceType, customOrder,
  enabled, enabledExplore, jsLib, header, loginUrl, loginUi, bookSourceComment,
  variable, lastUpdateTime, respondTime, weight, exploreUrl, ruleExplore,
  searchUrl, ruleSearch, ruleBookInfo, ruleToc, ruleContent, mainJs,
  eventListener, customButton
) VALUES (
  'https://qa.b2c.local', 'QA_B2C源', 'QA', 0, 1,
  1, 1, '', '', 'http://192.168.100.52:8899/login.html', '', 'QA 双栏验收书源',
  '', 0, 180000, 0,
  'QA分类::http://192.168.100.52:8899/explore.html',
  '{"bookList":"ul#list li","name":"a@text","author":".author@text","intro":".intro@text","kind":".kind@text","bookUrl":"a@href"}',
  '', '',
  '{"name":"h1@text","author":".author@text","intro":".intro@text","tocUrl":"a.toc@href","lastChapter":".latest@text"}',
  '{"chapterList":"ul#chapters li","chapterName":"a@text","chapterUrl":"a@href"}',
  '{"content":"#content@text"}', '',
  0, 0
);

INSERT OR REPLACE INTO rssSources (
  sourceUrl, sourceName, sourceGroup, sourceComment, enabled, enableReadRecord,
  customOrder, lastUpdateTime, enableJs, loadWithBaseUrl, ruleArticles,
  ruleNextPage, ruleTitle, rulePubDate, ruleDescription, ruleImage, ruleLink,
  ruleContent, nextContentUrl, contentWhitelist, contentBlacklist, style,
  loginUrl, loginUi, loginCheckJs, header, jsLib, type, articleStyle,
  singleUrl, preload, cacheFirst, searchUrl, showWebLog
) VALUES (
  'http://192.168.100.52:8899/feed.xml', 'QA_B2C_RSS', 'QA', 'QA 双栏验收 RSS 源',
  1, 1, 1, 0, 1, 1, '',
  '', '', '', '', '', '',
  '#content@text', '', '', '', '',
  'http://192.168.100.52:8899/login.html', '', '', '', '', 0, 0,
  0, 0, 0, '', 0
);
