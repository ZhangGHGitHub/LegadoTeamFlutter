-- 批 2 HLS 音频缓存真机验收夹具（QA 临时数据，验收后删除）
-- 目标 DB：/data/data/io.legado.flutter_legado/app_flutter/legado.db
-- 用途：让 audio_cache_download 的前置校验（书/章/书源存在）通过。

DELETE FROM chapters WHERE bookUrl = 'qa://batch2-hls/book';
DELETE FROM books WHERE bookUrl = 'qa://batch2-hls/book';
DELETE FROM book_sources WHERE bookSourceUrl = 'http://127.0.0.1:18080/qa/source';
DELETE FROM caches WHERE key LIKE 'loginHeader_http://127.0.0.1:18080/qa/source%';

-- 书源（音频类 type=1；header 带静态头；无正文规则）
INSERT INTO book_sources (
  bookSourceUrl, bookSourceName, bookSourceType, customOrder, enabled,
  enabledExplore, lastUpdateTime, respondTime, weight, header, enabledCookieJar
) VALUES (
  'http://127.0.0.1:18080/qa/source', 'QA-HLS-源', 1, 0, 1, 0, 0, 0, 0,
  '{"User-Agent":"QA-Batch2-HLS","Referer":"http://127.0.0.1:18080/"}', 0
);

-- 书籍：origin 指向书源，tocUrl 指向书源域（同站）
INSERT INTO books (
  bookUrl, tocUrl, origin, originName, name, author, type, originBookUrl
) VALUES (
  'qa://batch2-hls/book', 'http://127.0.0.1:18080/qa/toc', 'http://127.0.0.1:18080/qa/source',
  'QA-HLS-源', 'QA HLS 验收书', 'QA', 1, 'http://127.0.0.1:18080/qa/toc'
);

-- 章节（index 0..5，对应 6 个场景）
INSERT INTO chapters (url, title, isVolume, baseUrl, bookUrl, "index", isVip, isPay)
VALUES
  ('http://127.0.0.1:18080/qa/ch-audio-track', '音频轨档',   0, '', 'qa://batch2-hls/book', 0, 0, 0),
  ('http://127.0.0.1:18080/qa/ch-nocodes',     '无 CODECS 音频档', 0, '', 'qa://batch2-hls/book', 1, 0, 0),
  ('http://127.0.0.1:18080/qa/ch-live',        '直播章',     0, '', 'qa://batch2-hls/book', 2, 0, 0),
  ('http://127.0.0.1:18080/qa/ch-empty',       '空分片章',   0, '', 'qa://batch2-hls/book', 3, 0, 0),
  ('http://127.0.0.1:18080/qa/ch-ok',          '正常章',     0, '', 'qa://batch2-hls/book', 4, 0, 0),
  ('http://127.0.0.1:18080/qa/ch-auth',        '头门控章',   0, '', 'qa://batch2-hls/book', 5, 0, 0);

-- 登录头（同站才发；用于验证 Authorization 同站/跨站门控）
INSERT INTO caches (key, value, deadline, created_at)
VALUES (
  'loginHeader_http://127.0.0.1:18080/qa/source',
  '{"Authorization":"Bearer QA-SECRET-TOKEN"}', 0, 0
);
