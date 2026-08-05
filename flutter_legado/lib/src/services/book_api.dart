import '../models/models.dart';

/// 书籍 API 抽象接口
///
/// 定义所有数据层公开方法签名，供 UI 层依赖。
/// 实现类：
/// - [RustApi]：真实 FFI 实现（需要 Rust DLL）
/// - MockBookApi：纯 Dart Mock 实现（无 DLL 可跑，UI 轨开发用）
abstract class BookApi {
  // ========== 初始化/版本 ==========

  /// 初始化运行时和数据库连接
  Future<void> initialize();

  /// 获取引擎版本号
  Future<String> getVersion();

  // ========== 书架操作 ==========

  /// 获取书架上所有书籍
  Future<List<Book>> getBooks();

  /// 添加书籍到书架
  Future<Book> addBook(Book book);

  /// 更新书籍信息
  Future<void> updateBook(Book book);

  /// 从书架删除书籍
  Future<void> deleteBook(String bookUrl);

  /// 按 bookUrl 获取书籍详情
  Future<Book?> getBook(String bookUrl);

  /// 置顶书籍
  Future<void> topBook(String bookUrl);

  /// 取消置顶
  Future<void> unTopBook(String bookUrl);

  /// 设置书籍分组
  Future<void> setBookGroup(String bookUrl, int groupId);

  /// 批量导入书籍，返回成功导入的数量
  Future<int> importBooks(String jsonArray);

  // ========== 书源操作 ==========

  /// 获取所有书源
  Future<List<BookSource>> getBookSources();

  /// 获取所有启用的书源
  Future<List<BookSource>> getEnabledBookSources();

  /// 添加书源
  Future<BookSource> addBookSource(BookSource source);

  /// 更新书源
  Future<void> updateBookSource(BookSource source);

  /// 删除书源
  Future<void> deleteBookSource(String sourceUrl);

  /// 启用书源
  Future<void> enableBookSource(String sourceUrl);

  /// 禁用书源
  Future<void> disableBookSource(String sourceUrl);

  /// 批量导入书源，返回成功导入的数量
  Future<int> importBookSources(String jsonArray);

  /// 导出所有书源为 JSON 数组
  Future<String> exportBookSources();

  /// 书源排序
  Future<void> sortBookSources(int sortKey, bool ascending);

  /// 提取 JS 单文件书源配置（返回 BookSource JSON，需 QuickJS 构建）
  Future<String> extractJsSource(String content);

  /// JS 书源语法检查（返回含 valid/message/line 的 JSON）
  Future<String> checkJsSourceSyntax(String content);

  /// 写回 JS 书源顶层配置的 lastUpdateTime（返回替换后脚本文本，无匹配时空串）
  Future<String> stampJsSourceLastUpdateTime(String content, int stamp);

  // ========== 书源校验（Task #87） ==========

  /// 校验单个书源（搜索→详情→目录→正文四步 + 验证码/重定向检测）
  ///
  /// [sourceJson] — BookSource JSON（字段名对齐 Android 原版 camelCase）
  /// [configJson] — 可选校验配置 JSON：`keyword` / `step_timeout_ms` /
  /// `check_search` / `check_toc` / `check_content` / `detect_captcha` /
  /// `detect_redirect`，全部可选，缺省用默认配置。
  ///
  /// 返回 CheckResult Map，字段：`source_url` / `search_ok` / `toc_ok` /
  /// `content_ok` / `search_error` / `toc_error` / `content_error` /
  /// `total_time_ms` / `captcha`（detected/captcha_type/matched_keyword）/
  /// `redirect`（redirected/original_url/final_url/is_login_redirect）。
  Future<Map<String, dynamic>> checkSource(
    String sourceJson, {
    String? configJson,
  });

  /// 批量校验书源（串行逐个回推进度，对齐 Kotlin CheckSourceService）
  ///
  /// [sourceUrls] — 待校验书源 URL 列表；空列表校验全部书源。
  /// [configJson] — 可选校验配置 JSON，同 [checkSource]。
  ///
  /// 每完成一个书源推送一条进度 Map，字段：`index`（从 0 开始）/
  /// `total` / `is_last` / `source_name` / `result`（CheckResult，
  /// 字段同 [checkSource]）。流在所有书源完成或取消后自然结束。
  Stream<Map<String, dynamic>> checkSourcesStream(
    List<String> sourceUrls, {
    String? configJson,
  });

  /// 取消正在进行的批量书源校验
  Future<void> cancelCheckSources();

  // ========== 验证码交互通道（Task #90） ==========

  /// 订阅验证码请求事件流（长期存活，对齐 Kotlin SourceVerificationHelp）
  ///
  /// 书源 JS 经 `getVerificationCode` 钩子挂起等待时，每个请求推送
  /// 一条事件 Map，字段：`key`（resultKey）/ `source_url` / `source_name` /
  /// `image_url` / `title` / `use_browser`（桌面端恒 false，浏览器模式
  /// 已降级）/ `created_at_ms`。订阅时先回放当前进行中的请求。
  /// UI 拿到事件后弹验证码对话框；用户输入经 [submitVerificationResult]
  /// 回传；关闭对话框调 [cancelVerificationRequest]。
  Stream<Map<String, dynamic>> verificationRequestStream();

  /// 提交验证码结果，唤醒 JS 等待方（对齐 Kotlin `setResult`）
  ///
  /// [key] — 请求事件中的 resultKey；[code] — 用户输入的验证码。
  /// 返回是否命中进行中的请求。
  Future<bool> submitVerificationResult(String key, String code);

  /// 取消验证码请求（对齐 Kotlin `checkResult`：UI 关闭对话框未提交）
  ///
  /// 以空结果唤醒等待方（等待侧报「验证结果为空」，对齐 Kotlin 语义）。
  Future<bool> cancelVerificationRequest(String key);

  // ========== 搜索操作 ==========

  /// 搜索书籍
  Future<List<SearchResult>> searchBooks(
    String keyword, {
    List<String>? sourceUrls,
  });

  /// 多源并行搜索
  Future<List<Map<String, dynamic>>> searchMulti(
    String query, {
    List<String>? sourceUrls,
  });

  /// 多源渐进式（流式）搜索
  ///
  /// 与 [searchMulti]（一次性返回全部）不同：每完成一个书源即推送一个批次，
  /// UI 侧可逐源渲染，无需等待最慢书源。流在所有书源完成后自然结束。
  ///
  /// 每个元素为一个书源批次 Map，字段：
  /// `source_index` / `source_url` / `source_name` / `books`(List) /
  /// `error`(String?) / `finished_count` / `total_count` / `is_last`。
  Stream<Map<String, dynamic>> searchMultiStream(
    String query, {
    List<String>? sourceUrls,
  });

  /// 取消搜索
  Future<void> cancelSearch();

  /// 搜索可替换的书源
  Future<List<Map<String, dynamic>>> searchSource(
    String bookName,
    String author,
  );

  /// 搜索书籍封面候选列表
  ///
  /// 按书名搜索网络封面候选（API_CONTRACT.md §3 需求 3，用于 `change_cover_screen`）。
  /// 每个元素字段：`url`（封面地址，必需）/ `width`（像素，未知填 0）/ `height`（像素，未知填 0）。
  /// 无候选时返回空列表（非异常）。
  Future<List<Map<String, dynamic>>> searchCover(String bookName);

  /// 切换书源
  Future<String> switchSource(
    String bookUrl,
    String newSourceUrl,
    String newBookUrl,
  );

  // ========== RSS 源操作 ==========

  /// 获取所有 RSS 源
  Future<List<RssSource>> getRssSources();

  /// 添加 RSS 源
  Future<RssSource> addRssSource(RssSource source);

  /// 更新 RSS 源
  Future<void> updateRssSource(RssSource source);

  /// 删除 RSS 源
  Future<void> deleteRssSource(String sourceUrl);

  /// 启用 RSS 源
  Future<void> enableRssSource(String sourceUrl);

  /// 禁用 RSS 源
  Future<void> disableRssSource(String sourceUrl);

  /// 导入 RSS 源
  Future<int> importRssSources(String jsonArray);

  /// 导出 RSS 源
  Future<String> exportRssSources();

  /// 获取 RSS 文章列表
  Future<List<RssFeedArticle>> getRssArticles(String sourceUrl);

  // ========== RSS 已读记录 ==========

  /// 标记 RSS 文章为已读
  Future<void> rssMarkRead(String origin, String title, [String? link]);

  /// 判断 RSS 文章是否已读（按 link）
  Future<bool> rssIsRead(String link);

  /// 判断 RSS 文章是否已读（按 origin + title）
  Future<bool> rssIsReadByTitle(String origin, String title);

  /// 清空所有 RSS 已读记录
  Future<void> rssClearReadRecords();

  /// 获取 RSS 已读记录总数
  Future<int> rssReadRecordCount();

  /// 获取 RSS 已读记录列表（按 readTime 降序）
  Future<List<Map<String, dynamic>>> rssListReadRecords([int? limit]);

  // ========== 本地书籍操作 ==========

  /// 导入本地书籍
  Future<Book> importLocalBook(String filePath);

  /// 扫描本地书籍
  Future<List<Map<String, dynamic>>> scanLocalBooks(String dirPath);

  /// 检测书籍文件格式
  Future<String> detectFormat(String filePath);

  /// 解析书籍元数据
  Future<String> parseMetadata(String filePath);

  // ========== 本地 TXT 全文搜索（Task #98 缺口#4，加法式新增） ==========

  /// 搜索本地 TXT 文件内容（纯文本模式，章节感知）
  ///
  /// 对齐 Android 原版搜索页内“搜本地书正文”场景。
  /// 返回搜索结果列表，每项字段（snake_case）：
  /// `chapter_index`（章节序号）/ `chapter_title`（章节标题）/
  /// `char_offset`（匹配在章节内的字符偏移）/ `matched_text`（匹配文本）/
  /// `context`（上下文摘要）/ `context_match_start` / `context_match_end`
  /// （匹配在上下文中的起止位置）。
  Future<List<Map<String, dynamic>>> txtSearch(
    String path,
    String query, {
    bool caseSensitive = false,
    int maxResults = 500,
  });

  /// 使用正则表达式搜索本地 TXT 文件内容
  ///
  /// 返回格式同 [txtSearch]。
  Future<List<Map<String, dynamic>>> txtSearchRegex(
    String path,
    String pattern, {
    bool caseSensitive = false,
    int maxResults = 500,
  });

  /// 在本地 TXT 文件指定章节内搜索
  ///
  /// [chapterIndex] 为章节序号（从 0 开始）。返回格式同 [txtSearch]。
  Future<List<Map<String, dynamic>>> txtSearchInChapter(
    String path,
    String query,
    int chapterIndex, {
    bool caseSensitive = false,
    int maxResults = 50,
  });

  /// 统计本地 TXT 文件内关键词匹配总数（不返回完整结果，供 UI 显示计数）
  Future<int> txtSearchCount(
    String path,
    String query, {
    bool caseSensitive = false,
  });

  // ========== 书签操作 ==========

  /// 获取某本书的所有书签
  Future<List<Bookmark>> getBookmarks(String bookName);

  /// 获取所有书签
  Future<List<Bookmark>> getAllBookmarks();

  /// 添加书签
  Future<Bookmark> addBookmark(Bookmark bookmark);

  /// 更新书签
  Future<void> updateBookmark(Bookmark bookmark);

  /// 删除书签
  Future<void> deleteBookmark(int id);

  /// 搜索书签
  Future<List<Bookmark>> searchBookmarks(String keyword);

  // ========== 替换规则操作 ==========

  /// 获取所有替换规则
  Future<List<ReplaceRule>> getReplaceRules();

  /// 获取启用的替换规则
  Future<List<ReplaceRule>> getEnabledReplaceRules();

  /// 添加替换规则
  Future<ReplaceRule> addReplaceRule(ReplaceRule rule);

  /// 更新替换规则
  Future<void> updateReplaceRule(ReplaceRule rule);

  /// 删除替换规则
  Future<void> deleteReplaceRule(int id);

  /// 启用/禁用替换规则
  Future<void> setReplaceRuleEnabled(int id, bool enabled);

  // ========== 阅读器操作 ==========

  /// 获取书籍的章节列表
  Future<List<BookChapter>> getChapters(String bookUrl);

  /// 获取章节正文内容
  Future<String> getChapterContent(String bookUrl, int chapterIndex);

  /// 获取章节正文内容（不应用替换规则，用于内容搜索）
  ///
  /// 与 Android 书内搜索默认行为（replaceEnabled=false）对齐。
  Future<String> getChapterContentRaw(String bookUrl, int chapterIndex);

  /// 一次调用获取章节正文（合并 getChapterContent + fetchChapterContent）
  ///
  /// 本地书籍直接解析返回；在线书籍自动从网络抓取并返回净化后的正文。
  /// 始终返回纯正文字符串，不返回 JSON 元数据。
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex);

  /// 从网络获取章节正文
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  );

  /// 更新阅读进度
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  });

  /// 从网络刷新书籍目录
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl);

  // ========== 配置操作 ==========

  /// 获取配置值
  Future<String?> getConfig(String key);

  /// 设置配置值
  Future<void> setConfig(String key, String value);

  /// 删除配置
  Future<void> deleteConfig(String key);

  /// 获取所有配置
  Future<Map<String, String>> getAllConfigs();

  // ========== 词典操作 ==========

  /// 词典查询（本地内置词典）
  ///
  /// 按单词查询释义（API_CONTRACT.md §3 需求 4，用于 `dict_screen`）。
  /// 返回字段：`word`（归一化单词）/ `phonetic`（音标，可空）/ `definitions`（释义列表）。
  /// 未收录词返回空 `definitions`（非异常）；查询异常抛出经 bridge 映射为 [BridgeError]。
  Future<Map<String, dynamic>> dictLookup(String word);

  // ========== 备份操作 ==========

  /// 备份数据
  Future<String> backup(String dirPath);

  /// 恢复数据
  Future<void> restore(String backupPath);

  // ========== 阅读记录 ==========

  /// 获取所有阅读记录
  Future<List<ReadRecord>> getReadRecords();

  /// 更新阅读记录
  Future<void> putReadRecord(ReadRecord record);

  /// 删除阅读记录
  Future<void> deleteReadRecord(String bookName);

  /// 清空阅读记录
  Future<void> clearReadRecords();

  // ========== RSS 收藏操作 ==========

  /// 获取所有 RSS 收藏
  Future<List<RssStar>> getRssStars();

  /// 添加 RSS 收藏
  Future<RssStar> addRssStar(RssStar star);

  /// 删除 RSS 收藏
  Future<void> deleteRssStar(String link);

  /// 判断是否已收藏
  Future<bool> isStarred(String link);

  // ========== 书籍分组 ==========

  /// 获取所有书籍分组
  Future<List<BookGroup>> getBookGroups();

  /// 添加书籍分组
  Future<BookGroup> addBookGroup(BookGroup group);

  /// 更新书籍分组
  Future<void> updateBookGroup(BookGroup group);

  /// 删除书籍分组
  Future<void> deleteBookGroup(int groupId);

  // ========== 搜索历史 ==========

  /// 获取搜索历史
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50});

  /// 按前缀搜索历史关键词（用于搜索联想）
  Future<List<String>> searchHistoryByPrefix(String prefix, {int limit = 20});

  /// 添加搜索关键词
  Future<void> addSearchKeyword(String keyword, String bookName);

  /// 删除搜索关键词
  Future<void> deleteSearchKeyword(String keyword);

  /// 清空搜索历史
  Future<void> clearSearchHistory();

  // ========== 缓存管理 ==========

  /// 获取缓存大小
  Future<int> getCacheSize();

  /// 清除缓存
  Future<void> clearCache();

  /// 获取缓存书籍数量
  Future<int> getCacheBookCount();

  /// 获取缓存章节数量
  Future<int> getCacheChapterCount();

  /// 清除指定时间之前的缓存
  Future<void> clearCacheBefore(int beforeTimestampMs);

  // ========== WebBook 操作 ==========

  /// 搜索书籍（书源规则驱动）
  Future<String> webbookSearch(String sourceJson, String query, int page);

  /// 获取书籍详情
  Future<String> webbookInfo(String sourceJson, String bookUrl);

  /// 获取章节列表
  Future<String> webbookChapters(String sourceJson, String bookUrl);

  /// 获取章节正文
  Future<String> webbookContent(String sourceJson, String chapterJson);

  // ========== 发现页操作 ==========

  /// 解析 exploreUrl 为分类列表
  Future<List<ExploreCategory>> exploreParseUrl(String exploreUrl);

  /// 抓取发现分类的书籍列表
  Future<List<SearchBook>> exploreFetchBooks(
    String sourceJson,
    String url,
    int page,
  );

  // ========== 规则解析 ==========

  /// 使用规则解析内容
  Future<String> parseRule(String content, String rule, String ruleType);

  // ========== 网络操作 ==========

  /// HTTP GET 请求
  Future<String> httpGet(String url);

  /// HTTP POST 请求
  Future<String> httpPost(String url, String body);

  /// 查询 QUIC/HTTP3 传输开关状态
  Future<bool> netIsQuicEnabled();

  /// 设置 QUIC/HTTP3 传输开关（实验性）
  Future<void> netSetQuicEnabled(bool enabled);

  // ========== JS 引擎 ==========

  /// 执行 JS 脚本
  Future<String> evalJs(String script);

  /// 获取 JS 引擎版本
  Future<String> getJsEngineVersion();

  // ========== 服务器管理 ==========

  /// 启动服务器
  Future<void> startServer({int port = 1122});

  /// 停止服务器
  Future<void> stopServer();

  /// 获取服务器状态
  Future<String> getServerStatus();

  /// 设置服务器端口
  Future<void> setServerPort(int port);

  // ========== 书籍格式解析 ==========

  /// 解析 TXT 文件
  Future<List<BookChapter>> parseTxt(String filePath);

  /// 解析 EPUB 文件
  Future<List<BookChapter>> parseEpub(String filePath);

  /// 导出书籍（将章节内容写入文件）
  Future<String> exportBook(String bookUrl, String format, String outDir);

  // ========== 阅读统计 ==========

  /// 获取今日阅读统计
  Future<ReadingStatsToday> getTodayReadingStats();

  /// 获取每日阅读统计
  Future<Map<String, int>> getDailyReadingStats({required int days});

  /// 获取书籍阅读统计
  Future<Map<String, int>> getBookReadingStats();

  /// 获取阅读热力图
  Future<Map<String, int>> getReadingHeatmap({required int days});

  /// 记录阅读时长
  Future<void> recordReadingTime(String bookName, int seconds);

  // ========== HTTP TTS ==========

  /// 获取所有 HTTP TTS 配置
  Future<List<HttpTts>> getHttpTts();

  /// 获取所有 HTTP TTS 配置（别名）
  Future<List<HttpTts>> getHttpTtsList();

  /// 添加 HTTP TTS 配置
  Future<HttpTts> addHttpTts(HttpTts tts);

  /// 更新 HTTP TTS 配置
  Future<void> updateHttpTts(HttpTts tts);

  /// 删除 HTTP TTS 配置
  Future<void> deleteHttpTts(int id);

  /// 导入 HTTP TTS 配置
  Future<int> importHttpTts(String json);

  /// 导出 HTTP TTS 配置
  Future<String> exportHttpTts();

  // ========== 音频播放 ==========

  /// TTS 朗读
  Future<void> audioSpeak({
    required String text,
    required String engineUrl,
    double speed = 1.0,
    double pitch = 1.0,
    double volume = 1.0,
    String? voiceName,
  });

  /// 获取章节媒体信息
  Future<Map<String, dynamic>> getAudioChapterMedia(
    String bookUrl,
    int chapterIndex,
  );

  /// 获取音频播放进度
  Future<Map<String, dynamic>?> getAudioProgress(
    String bookUrl,
    int chapterIndex,
  );

  /// 保存音频播放进度
  Future<void> saveAudioProgress(
    String bookUrl,
    int chapterIndex,
    int positionMs,
  );

  // ========== 用户管理 ==========

  /// 获取所有用户
  Future<List<Map<String, dynamic>>> getUsers();

  /// 保存用户，返回用户 ID
  Future<int> saveUser({
    required String username,
    required String password,
    required String sourceUrl,
  });

  /// 删除用户
  Future<bool> deleteUser(String username);

  /// 用户登录
  Future<bool> userLogin({
    required String username,
    required String password,
  });

  /// 用户登出
  Future<bool> userLogout(String username);

  /// 检查登录状态
  Future<bool> checkLoginStatus(String username);

  // ========== WebDAV 云同步 ==========

  /// WebDAV 列出远程目录
  Future<String> webdavListDir(String configJson, String path);

  /// WebDAV 上传文件
  Future<void> webdavUpload(String configJson, String path, String data);

  /// WebDAV 下载文件
  Future<String> webdavDownload(String configJson, String path);

  /// WebDAV 删除远程文件
  Future<void> webdavDelete(String configJson, String path);

  /// WebDAV 全量同步
  Future<String> webdavFullSync(
    String configJson,
    String localBooks,
    String localSources,
  );

  // ========== 下载管理器 ==========

  /// 添加下载任务
  Future<String> downloadAddTask({
    required String bookUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int chapterIndex,
    int priority = 0,
  });

  /// 获取下载统计信息
  Future<String> downloadGetStats();

  /// 获取指定书籍的下载任务
  Future<String> downloadListByBook(String bookUrl);

  /// 暂停所有下载
  Future<void> downloadPauseAll();

  /// 恢复所有下载
  Future<void> downloadResumeAll();

  /// 移除下载任务
  Future<void> downloadRemoveTask(String taskId);

  /// 更新下载进度
  Future<void> downloadUpdateProgress(String taskId, double progress);

  // ========== 段评/章评 ==========

  /// 获取指定章节的所有评论
  Future<String> reviewGetByChapter(String bookUrl, int chapterIndex);

  /// 添加评论，返回评论 ID
  Future<int> reviewAdd({
    required String bookUrl,
    required int chapterIndex,
    int paragraphIndex = -1,
    required String content,
    String author = '',
  });

  /// 删除评论
  Future<bool> reviewDelete(int id);

  /// 点赞评论
  Future<void> reviewLike(int id);

  /// 按需加载段评回复（上游 #519）
  ///
  /// 返回 JSON 对象字符串 `{"items": [回复列表], "nextPageUrl": String?}`；
  /// 回复条目字段：id/avatar/name/badges/content/imageUrl/audioUrl/time。
  ///
  /// # 参数
  /// - `sourceJson`: BookSource JSON（含 ruleReview）
  /// - `requestJson`: 请求上下文 JSON，支持
  ///   reviewId/paraIndex/paraData/chapterUrl/replyUrl 字段
  /// - `page`: 回复页码（从 1 开始）
  Future<String> reviewGetReplies(
      String sourceJson, String requestJson, int page);

  // ========== 书籍导出 ==========

  /// 导出书籍（返回 ExportResult JSON）
  Future<Map<String, dynamic>> bookExport({
    required String bookUrl,
    required String format,
    required bool includeToc,
  });

  /// 获取导出预览信息
  Future<Map<String, dynamic>> bookExportInfo({
    required String bookUrl,
    required String format,
  });

  // ========== 自动任务（auto_task FFI） ==========

  /// 构建书籍更新定时任务
  Future<Map<String, dynamic>> autoTaskBuildBookUpdateTask({
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
    required String name,
  });

  /// 批量更新 cron 表达式
  Future<List<Map<String, dynamic>>> autoTaskUpdateCronBatch({
    required String rulesJson,
    required String idsJson,
    required String cron,
  });

  /// 准备导入任务
  Future<List<Map<String, dynamic>>> autoTaskPrepareImported({
    required String localTasksJson,
    required String importedJson,
  });

  /// 执行任务协议
  Future<Map<String, dynamic>> autoTaskExecute({
    required String protocolJson,
  });

  /// 带任务 ID 执行任务协议
  Future<Map<String, dynamic>> autoTaskExecuteWithId({
    required String protocolJson,
    required String taskId,
  });

  /// 规范化脚本
  Future<String> autoTaskNormalizeScript({required String script});

  /// 判断书籍是否允许刷新目录
  Future<bool> autoTaskCanRefreshBookToc({
    required bool canUpdate,
    required bool respectCanUpdate,
  });

  /// 查找书籍更新任务
  Future<Map<String, dynamic>?> autoTaskFindBookUpdateTask({
    required String tasksJson,
    required String bookUrl,
    required String bookName,
    required String bookAuthor,
  });

  /// 解析 cron 表达式计算下次执行时间
  Future<int> autoTaskNextDueAt({
    required String cron,
    required int fromMs,
  });

  // ========== 自动任务数据库 CRUD ==========

  /// 列出所有自动任务规则（按 customOrder 排序）
  Future<List<Map<String, dynamic>>> autoTaskListRules();

  /// 创建自动任务规则（返回任务 ID）
  Future<String> autoTaskCreateRule({required String ruleJson});

  /// 更新自动任务规则
  Future<void> autoTaskUpdateRule({required String ruleJson});

  /// 删除自动任务规则
  Future<void> autoTaskDeleteRule({required String id});

  /// 根据 ID 查询自动任务规则
  Future<Map<String, dynamic>?> autoTaskFindRuleById({required String id});

  // ========== 音频播放模式（audio FFI） ==========

  /// 将播放模式写入 readConfig JSON
  Future<String> audioWithPlayMode({
    String? readConfig,
    required int playMode,
  });

  /// 解析听书书籍
  Future<Map<String, dynamic>?> audioResolvePlayBook({
    String? requestedBookUrl,
    String? cachedBookJson,
  });

  // ========== 压缩包导入 ==========

  /// 导入 ZIP 压缩包中的书籍文件
  Future<Map<String, dynamic>> archiveImportZip({
    required String zipPath,
    required String outputDir,
  });

  /// 导入 RAR 压缩包中的书籍文件
  Future<Map<String, dynamic>> archiveImportRar({
    required String rarPath,
    required String outputDir,
    String? password,
  });

  /// 列出 ZIP 压缩包中的书籍文件名
  Future<List<String>> archiveListZipFiles({required String zipPath});

  /// 列出 RAR 压缩包中的书籍文件名
  Future<List<String>> archiveListRarFiles({
    required String rarPath,
    String? password,
  });

  /// 检测 TXT 文件编码
  Future<Map<String, dynamic>> archiveDetectEncoding({
    required String filePath,
  });

  /// 转换 TXT 文件编码
  Future<Map<String, dynamic>> archiveConvertEncoding({
    required String filePath,
    required String fromEncoding,
    required String toEncoding,
  });

  /// 判断文件是否为压缩包格式
  Future<bool> archiveIsArchive({required String filePath});

  // ========== 正文高亮（highlight FFI） ==========

  /// 新增/更新高亮记录（BookHighlight JSON，time=0 时自动分配），返回 time
  Future<int> highlightAdd({required String highlightJson});

  /// 按主键 time 删除高亮记录，返回是否实际删除
  Future<bool> highlightDelete({required int time});

  /// 按书籍删除全部高亮记录，返回删除数量
  Future<int> highlightDeleteByBook({required String bookUrl});

  /// 按书籍获取高亮列表（BookHighlight 数组 JSON）
  Future<String> highlightListByBook({required String bookUrl});

  /// 按书籍 + 章节索引获取高亮列表（BookHighlight 数组 JSON）
  Future<String> highlightListByChapter({
    required String bookUrl,
    required int chapterIndex,
  });

  /// 全局关键词搜索高亮（BookHighlight 数组 JSON）
  Future<String> highlightSearch({required String keyword});

  /// 获取所有高亮记录（BookHighlight 数组 JSON）
  Future<String> highlightListAll();

  /// 获取所有高亮规则（HighlightRule 数组 JSON，按 sortOrder 升序）
  Future<String> highlightRuleList();

  /// 保存高亮规则（HighlightRule JSON，id=0 时自增新增），返回规则 ID
  Future<int> highlightRuleSave({required String ruleJson});

  /// 按 ID 删除高亮规则，返回是否实际删除
  Future<bool> highlightRuleDelete({required int id});

  /// 按书籍查找启用的高亮规则（HighlightRule 数组 JSON）
  Future<String> highlightRuleFindEnabled({
    required String bookName,
    required String origin,
  });

  // ========== 应用日志（appLog FFI） ==========
  // [审计修复 §1.2] 补齐契约 §2.38 已交付但接口缺失的 appLog* 五方法 — QoderCN

  /// 推送一条应用日志（对齐 Android AppLog.put；空消息由 Rust 侧短路忽略）
  ///
  /// [level] 取值：`message` / `crash` / `http`（对齐契约 §2.38）。
  Future<void> appLogPush({required String level, required String message});

  /// 获取指定级别的日志列表（JSON 数组，最新在前）
  ///
  /// 每项字段：`timestamp`（毫秒）/ `level` / `message`。
  Future<String> appLogList({required String level});

  /// 清空指定级别的日志
  Future<void> appLogClear({required String level});

  /// 清空全部级别日志（对齐 #543 AppLog.clear + HttpLogStore.clear）
  Future<void> appLogClearAll();

  /// 导出全部日志为格式化文本（时间升序，64_000 字符截断，对齐 #543）
  Future<String> appLogExport();

  // ========== 规则订阅（rule_sub FFI，Task #89） ==========

  /// 获取规则订阅列表（按 customOrder 排序，对齐 Kotlin RuleSubDao.all）
  ///
  /// 每项字段：`id` / `name` / `url` / `type`（0 书源 / 1 订阅源 / 2 替换规则）/
  /// `customOrder` / `autoUpdate` / `update`（最后更新时间戳）/
  /// `updateInterval`（小时）/ `silentUpdate` / `js`? / `showRule`? / `sourceUrl`?。
  Future<List<Map<String, dynamic>>> ruleSubList();

  /// 新增/更新规则订阅（RuleSub JSON；id>0 且存在则更新，否则新增）
  Future<bool> ruleSubSave({required String subJson});

  /// 删除规则订阅，返回是否实际删除
  Future<bool> ruleSubDelete({required int id});

  /// 切换规则订阅启用状态，返回记录是否存在
  Future<bool> ruleSubSetEnabled({required int id, required bool enabled});

  /// 拖拽排序：按新顺序 ID 列表重写 customOrder（0 起）
  Future<bool> ruleSubUpdateOrder({required List<int> ids});

  /// 检查更新（返回检查结果 Map：
  /// `id` / `url` / `name` / `dueForUpdate` / `hasUpdate` / `remoteVersion` / `error`）
  Future<Map<String, dynamic>> ruleSubCheckUpdate({required int id});

  /// 应用更新（返回应用结果 Map：
  /// `id` / `url` / `success` / `itemsAdded` / `itemsUpdated` /
  /// `itemsRemoved` / `totalItems` / `error`）
  Future<Map<String, dynamic>> ruleSubApplyUpdate({required int id});
}
