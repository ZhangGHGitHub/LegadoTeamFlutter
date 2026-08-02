# API 契约文档（BookApi 接口基准）

**日期**: 2026-08-01
**版本**: v1.0
**维护人**: Legado 开发团队（Qoder / QoderCN）

---

## 1. 契约总则

### 1.1 定位

本文档是 **UI 轨**与 **Rust 轨**的唯一接口契约基准。所有跨轨数据流通均以 `BookApi` 抽象接口（`flutter_legado/lib/src/services/book_api.dart`）为准，本文档为其权威文字说明。

### 1.2 变更规则

| 变更类型 | 规则 |
|----------|------|
| **新增 API** | Rust 轨可自由添加，但须同步：① 更新本文档 ② 补 `MockBookApi` 假实现 ③ `BookApi` 接口新增抽象方法 |
| **修改/删除已有签名** | 破坏性变更，必须双轨评审确认后执行，PR 标注"破坏性变更"及影响范围 |

详细流程参见 [TWO_TRACK_DEV_SPEC.md § 4 契约变更流程](TWO_TRACK_DEV_SPEC.md)。

### 1.3 数据传递约定

- 复杂类型统一以 **JSON String** 跨 FFI 边界传递（项目既有决策）。
- Dart 侧负责 `jsonEncode` / `jsonDecode`，Rust 侧返回序列化后的 JSON 字符串。
- 模型对象（Book、BookSource 等）通过各自 `toJson()` / `fromJson()` 完成序列化。

### 1.4 已知双兼容点（重要警告）

以下方法的 Rust 侧返回为 **Map 包装结构**（非裸 List），Dart 侧已做兼容处理（提取内部字段）：

| 方法 | Rust 返回结构 | 提取字段 | 历史事故 |
|------|---------------|----------|----------|
| `getChapters` | `ChapterListResponse { total, chapters[] }` | `chapters` | Task #29 崩溃修复 |
| `refreshToc` | `ChapterListResponse { total, chapters[] }` | `chapters` | Task #42 崩溃修复 |
| `searchSource` | `SourceSwitchResponse { book_name, author, matches[] }` | `matches` | Task #42 崩溃修复 |

> **铁律**：未来新增返回列表的 FFI 方法，Rust 侧必须返回裸 JSON Array `[...]`，禁止无预警使用 Map 包装。若确需包装，必须在本文档登记并在 Dart 侧同步兼容。

### 1.5 实现类

| 类 | 文件 | 用途 |
|----|------|------|
| `RustApi` | `rust_api.dart` | 真实 FFI 实现（需 Rust DLL） |
| `MockBookApi` | `mock_book_api.dart` | 纯 Dart Mock（`--dart-define=USE_MOCK=true`） |

---

## 2. 方法清单

> 共 **35 个模块**、**171 个方法**（与 `book_api.dart` 一一对应）。

### 2.1 初始化/版本（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `initialize()` | 无 | `Future<void>` | 初始化 Rust 运行时和数据库连接 |
| `getVersion()` | 无 | `Future<String>` | 获取引擎版本号 |

### 2.2 书架操作（9 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBooks()` | 无 | `Future<List<Book>>` | 获取书架上所有书籍 |
| `addBook(Book book)` | book: Book 对象 | `Future<Book>` | 添加书籍到书架 |
| `updateBook(Book book)` | book: Book 对象 | `Future<void>` | 更新书籍信息 |
| `deleteBook(String bookUrl)` | bookUrl | `Future<void>` | 从书架删除书籍 |
| `getBook(String bookUrl)` | bookUrl | `Future<Book?>` | 按 bookUrl 获取书籍详情 |
| `topBook(String bookUrl)` | bookUrl | `Future<void>` | 置顶书籍 |
| `unTopBook(String bookUrl)` | bookUrl | `Future<void>` | 取消置顶 |
| `setBookGroup(String bookUrl, int groupId)` | bookUrl, groupId | `Future<void>` | 设置书籍分组 |
| `importBooks(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 批量导入书籍，返回成功导入的数量 |

### 2.3 书源操作（10 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookSources()` | 无 | `Future<List<BookSource>>` | 获取所有书源 |
| `getEnabledBookSources()` | 无 | `Future<List<BookSource>>` | 获取所有启用的书源 |
| `addBookSource(BookSource source)` | source: BookSource 对象 | `Future<BookSource>` | 添加书源 |
| `updateBookSource(BookSource source)` | source: BookSource 对象 | `Future<void>` | 更新书源 |
| `deleteBookSource(String sourceUrl)` | sourceUrl | `Future<void>` | 删除书源 |
| `enableBookSource(String sourceUrl)` | sourceUrl | `Future<void>` | 启用书源 |
| `disableBookSource(String sourceUrl)` | sourceUrl | `Future<void>` | 禁用书源 |
| `importBookSources(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 批量导入书源，返回成功数量 |
| `exportBookSources()` | 无 | `Future<String>` | 导出所有书源为 JSON 数组 |
| `sortBookSources(int sortKey, bool ascending)` | sortKey, ascending | `Future<void>` | 书源排序 |

### 2.4 搜索操作（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `searchBooks(String keyword, {List<String>? sourceUrls})` | keyword, sourceUrls(可选) | `Future<List<SearchResult>>` | 搜索书籍 |
| `searchMulti(String query, {List<String>? sourceUrls})` | query, sourceUrls(可选) | `Future<List<Map<String, dynamic>>>` | 多源并行搜索 |
| `searchMultiStream(String query, {List<String>? sourceUrls})` | query, sourceUrls(可选) | `Stream<Map<String, dynamic>>` | 多源渐进式（流式）搜索：每完成一个书源即推送一个批次，无需等待最慢书源 |
| `cancelSearch()` | 无 | `Future<void>` | 取消搜索 |
| `searchSource(String bookName, String author)` | bookName, author | `Future<List<Map<String, dynamic>>>` | 搜索可替换的书源 ⚠️ 双兼容点 |
| `switchSource(String bookUrl, String newSourceUrl, String newBookUrl)` | bookUrl, newSourceUrl, newBookUrl | `Future<String>` | 切换书源 |

> ⚠️ `searchSource`：Rust 返回 `SourceSwitchResponse { book_name, author, matches[] }`，Dart 侧提取 `matches` 字段。
>
> ℹ️ `searchMultiStream`：Rust 侧 `ffi::search_multi_stream(query, source_urls_json, sink: StreamSink<String>)`（frb 生成 Dart `Stream<String>`），每完成一个书源推送一个 `SearchSourceBatch` JSON：`source_index` / `source_url` / `source_name` / `books[]` / `error?` / `finished_count` / `total_count` / `is_last`。冻结契约 `searchMulti` 保持不变，本方法为加法式新增。

### 2.5 RSS 源操作（9 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getRssSources()` | 无 | `Future<List<RssSource>>` | 获取所有 RSS 源 |
| `addRssSource(RssSource source)` | source: RssSource 对象 | `Future<RssSource>` | 添加 RSS 源 |
| `updateRssSource(RssSource source)` | source: RssSource 对象 | `Future<void>` | 更新 RSS 源 |
| `deleteRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 删除 RSS 源 |
| `enableRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 启用 RSS 源 |
| `disableRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 禁用 RSS 源 |
| `importRssSources(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 导入 RSS 源，返回成功数量 |
| `exportRssSources()` | 无 | `Future<String>` | 导出 RSS 源 |
| `getRssArticles(String sourceUrl)` | sourceUrl | `Future<List<RssFeedArticle>>` | 获取 RSS 文章列表 |

### 2.6 本地书籍操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `importLocalBook(String filePath)` | filePath | `Future<Book>` | 导入本地书籍 |
| `scanLocalBooks(String dirPath)` | dirPath | `Future<List<Map<String, dynamic>>>` | 扫描本地书籍，返回 `{path, name, size, lastModified}` |
| `detectFormat(String filePath)` | filePath | `Future<String>` | 检测书籍文件格式 |
| `parseMetadata(String filePath)` | filePath | `Future<String>` | 解析书籍元数据（返回 JSON） |

### 2.7 书签操作（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookmarks(String bookName)` | bookName | `Future<List<Bookmark>>` | 获取某本书的所有书签 |
| `getAllBookmarks()` | 无 | `Future<List<Bookmark>>` | 获取所有书签 |
| `addBookmark(Bookmark bookmark)` | bookmark: Bookmark 对象 | `Future<Bookmark>` | 添加书签 |
| `updateBookmark(Bookmark bookmark)` | bookmark: Bookmark 对象 | `Future<void>` | 更新书签 |
| `deleteBookmark(int id)` | id | `Future<void>` | 删除书签 |
| `searchBookmarks(String keyword)` | keyword | `Future<List<Bookmark>>` | 搜索书签 |

### 2.8 替换规则操作（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getReplaceRules()` | 无 | `Future<List<ReplaceRule>>` | 获取所有替换规则 |
| `getEnabledReplaceRules()` | 无 | `Future<List<ReplaceRule>>` | 获取启用的替换规则 |
| `addReplaceRule(ReplaceRule rule)` | rule: ReplaceRule 对象 | `Future<ReplaceRule>` | 添加替换规则 |
| `updateReplaceRule(ReplaceRule rule)` | rule: ReplaceRule 对象 | `Future<void>` | 更新替换规则 |
| `deleteReplaceRule(int id)` | id | `Future<void>` | 删除替换规则 |
| `setReplaceRuleEnabled(int id, bool enabled)` | id, enabled | `Future<void>` | 启用/禁用替换规则 |

### 2.9 阅读器操作（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getChapters(String bookUrl)` | bookUrl | `Future<List<BookChapter>>` | 获取章节列表 ⚠️ 双兼容点 |
| `getChapterContent(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取章节正文内容 |
| `getChapterContentRaw(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取章节正文（不应用替换规则，用于内容搜索，与 Android replaceEnabled=false 对齐） |
| `getChapterContentFull(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 一次调用获取章节正文（合并 getChapterContent + fetchChapterContent，在线书籍自动网络抓取，始终返回纯正文） |
| `fetchChapterContent(String bookUrl, String chapterUrl, String sourceUrl)` | bookUrl, chapterUrl, sourceUrl | `Future<String>` | 从网络获取章节正文 |
| `updateReadingProgress({required String bookUrl, required int chapterIndex, required int chapterPos})` | bookUrl, chapterIndex, chapterPos | `Future<void>` | 更新阅读进度 |
| `refreshToc(String bookUrl, String sourceUrl)` | bookUrl, sourceUrl | `Future<List<BookChapter>>` | 从网络刷新书籍目录 ⚠️ 双兼容点 |

> ⚠️ `getChapters` / `refreshToc`：Rust 返回 `ChapterListResponse { total, chapters[] }`，Dart 侧提取 `chapters` 字段。

### 2.10 配置操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getConfig(String key)` | key | `Future<String?>` | 获取配置值 |
| `setConfig(String key, String value)` | key, value | `Future<void>` | 设置配置值 |
| `deleteConfig(String key)` | key | `Future<void>` | 删除配置 |
| `getAllConfigs()` | 无 | `Future<Map<String, String>>` | 获取所有配置 |

### 2.11 备份操作（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `backup(String dirPath)` | dirPath | `Future<String>` | 备份数据，返回备份文件路径 |
| `restore(String backupPath)` | backupPath | `Future<void>` | 恢复数据 |

### 2.12 阅读记录（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getReadRecords()` | 无 | `Future<List<ReadRecord>>` | 获取所有阅读记录 |
| `putReadRecord(ReadRecord record)` | record: ReadRecord 对象 | `Future<void>` | 更新阅读记录 |
| `deleteReadRecord(String bookName)` | bookName | `Future<void>` | 删除阅读记录 |
| `clearReadRecords()` | 无 | `Future<void>` | 清空阅读记录 |

### 2.13 RSS 收藏操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getRssStars()` | 无 | `Future<List<RssStar>>` | 获取所有 RSS 收藏 |
| `addRssStar(RssStar star)` | star: RssStar 对象 | `Future<RssStar>` | 添加 RSS 收藏 |
| `deleteRssStar(String link)` | link | `Future<void>` | 删除 RSS 收藏 |
| `isStarred(String link)` | link | `Future<bool>` | 判断是否已收藏 |

### 2.14 书籍分组（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookGroups()` | 无 | `Future<List<BookGroup>>` | 获取所有书籍分组 |
| `addBookGroup(BookGroup group)` | group: BookGroup 对象 | `Future<BookGroup>` | 添加书籍分组 |
| `updateBookGroup(BookGroup group)` | group: BookGroup 对象 | `Future<void>` | 更新书籍分组 |
| `deleteBookGroup(int groupId)` | groupId | `Future<void>` | 删除书籍分组 |

### 2.15 搜索历史（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getSearchHistory({int limit = 50})` | limit(默认50) | `Future<List<SearchKeyword>>` | 获取搜索历史 |
| `searchHistoryByPrefix(String prefix, {int limit = 20})` | prefix, limit(默认20) | `Future<List<String>>` | 按前缀搜索历史关键词（搜索联想） |
| `addSearchKeyword(String keyword, String bookName)` | keyword, bookName | `Future<void>` | 添加搜索关键词 |
| `deleteSearchKeyword(String keyword)` | keyword | `Future<void>` | 删除搜索关键词 |
| `clearSearchHistory()` | 无 | `Future<void>` | 清空搜索历史 |

### 2.16 缓存管理（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getCacheSize()` | 无 | `Future<int>` | 获取缓存大小（字节） |
| `clearCache()` | 无 | `Future<void>` | 清除缓存 |
| `getCacheBookCount()` | 无 | `Future<int>` | 获取缓存书籍数量 |
| `getCacheChapterCount()` | 无 | `Future<int>` | 获取缓存章节数量 |
| `clearCacheBefore(int beforeTimestampMs)` | beforeTimestampMs: 毫秒时间戳 | `Future<void>` | 清除指定时间之前的缓存 |

### 2.17 WebBook 操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `webbookSearch(String sourceJson, String query, int page)` | sourceJson, query, page | `Future<String>` | 搜索书籍（书源规则驱动），返回 JSON |
| `webbookInfo(String sourceJson, String bookUrl)` | sourceJson, bookUrl | `Future<String>` | 获取书籍详情 JSON |
| `webbookChapters(String sourceJson, String bookUrl)` | sourceJson, bookUrl | `Future<String>` | 获取章节列表 JSON |
| `webbookContent(String sourceJson, String chapterJson)` | sourceJson, chapterJson | `Future<String>` | 获取章节正文 |

### 2.18 发现页操作（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `exploreParseUrl(String exploreUrl)` | exploreUrl | `Future<List<ExploreCategory>>` | 解析 exploreUrl 为分类列表 |
| `exploreFetchBooks(String sourceJson, String url, int page)` | sourceJson, url, page | `Future<List<SearchBook>>` | 抓取发现分类的书籍列表 |

### 2.19 规则解析（1 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseRule(String content, String rule, String ruleType)` | content, rule, ruleType | `Future<String>` | 使用规则解析内容 |

### 2.20 网络操作（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `httpGet(String url)` | url | `Future<String>` | HTTP GET 请求 |
| `httpPost(String url, String body)` | url, body | `Future<String>` | HTTP POST 请求 |

### 2.21 JS 引擎（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `evalJs(String script)` | script | `Future<String>` | 执行 JS 脚本 |
| `getJsEngineVersion()` | 无 | `Future<String>` | 获取 JS 引擎版本 |

### 2.22 服务器管理（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `startServer({int port = 1122})` | port(默认1122) | `Future<void>` | 启动服务器 |
| `stopServer()` | 无 | `Future<void>` | 停止服务器 |
| `getServerStatus()` | 无 | `Future<String>` | 获取服务器状态 |
| `setServerPort(int port)` | port | `Future<void>` | 设置服务器端口 |

### 2.23 书籍格式解析（3 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseTxt(String filePath)` | filePath | `Future<List<BookChapter>>` | 解析 TXT 文件 |
| `parseEpub(String filePath)` | filePath | `Future<List<BookChapter>>` | 解析 EPUB 文件 |
| `exportBook(String bookUrl, String format, String outDir)` | bookUrl, format, outDir | `Future<String>` | 导出书籍（将章节内容写入文件） |

### 2.24 阅读统计（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getTodayReadingStats()` | 无 | `Future<ReadingStatsToday>` | 获取今日阅读统计 |
| `getDailyReadingStats({required int days})` | days | `Future<Map<String, int>>` | 获取每日阅读统计 |
| `getBookReadingStats()` | 无 | `Future<Map<String, int>>` | 获取书籍阅读统计 |
| `getReadingHeatmap({required int days})` | days | `Future<Map<String, int>>` | 获取阅读热力图 |
| `recordReadingTime(String bookName, int seconds)` | bookName, seconds | `Future<void>` | 记录阅读时长 |

### 2.25 HTTP TTS（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getHttpTts()` | 无 | `Future<List<HttpTts>>` | 获取所有 HTTP TTS 配置 |
| `getHttpTtsList()` | 无 | `Future<List<HttpTts>>` | 获取所有 HTTP TTS 配置（别名） |
| `addHttpTts(HttpTts tts)` | tts: HttpTts 对象 | `Future<HttpTts>` | 添加 HTTP TTS 配置 |
| `updateHttpTts(HttpTts tts)` | tts: HttpTts 对象 | `Future<void>` | 更新 HTTP TTS 配置 |
| `deleteHttpTts(int id)` | id | `Future<void>` | 删除 HTTP TTS 配置 |
| `importHttpTts(String json)` | json: JSON 字符串 | `Future<int>` | 导入 HTTP TTS 配置，返回成功数量 |
| `exportHttpTts()` | 无 | `Future<String>` | 导出 HTTP TTS 配置 |

### 2.26 音频播放（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `audioSpeak({required String text, required String engineUrl, double speed = 1.0, double pitch = 1.0, double volume = 1.0, String? voiceName})` | text, engineUrl, speed, pitch, volume, voiceName | `Future<void>` | TTS 朗读 |
| `getAudioChapterMedia(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<Map<String, dynamic>>` | 获取章节媒体信息 |
| `getAudioProgress(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<Map<String, dynamic>?>` | 获取音频播放进度 |
| `saveAudioProgress(String bookUrl, int chapterIndex, int positionMs)` | bookUrl, chapterIndex, positionMs | `Future<void>` | 保存音频播放进度 |

### 2.27 用户管理（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getUsers()` | 无 | `Future<List<Map<String, dynamic>>>` | 获取所有用户 |
| `saveUser({required String username, required String password, required String sourceUrl})` | username, password, sourceUrl | `Future<int>` | 保存用户，返回用户 ID |
| `deleteUser(String username)` | username | `Future<bool>` | 删除用户 |
| `userLogin({required String username, required String password})` | username, password | `Future<bool>` | 用户登录 |
| `userLogout(String username)` | username | `Future<bool>` | 用户登出 |
| `checkLoginStatus(String username)` | username | `Future<bool>` | 检查登录状态 |

### 2.28 WebDAV 云同步（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `webdavListDir(String configJson, String path)` | configJson, path | `Future<String>` | WebDAV 列出远程目录 |
| `webdavUpload(String configJson, String path, String data)` | configJson, path, data | `Future<void>` | WebDAV 上传文件 |
| `webdavDownload(String configJson, String path)` | configJson, path | `Future<String>` | WebDAV 下载文件 |
| `webdavDelete(String configJson, String path)` | configJson, path | `Future<void>` | WebDAV 删除远程文件 |
| `webdavFullSync(String configJson, String localBooks, String localSources)` | configJson, localBooks, localSources | `Future<String>` | WebDAV 全量同步 |

### 2.29 下载管理器（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `downloadAddTask({required String bookUrl, required String chapterUrl, required String chapterTitle, required int chapterIndex, int priority = 0})` | bookUrl, chapterUrl, chapterTitle, chapterIndex, priority | `Future<String>` | 添加下载任务，返回任务 ID |
| `downloadGetStats()` | 无 | `Future<String>` | 获取下载统计信息 JSON |
| `downloadListByBook(String bookUrl)` | bookUrl | `Future<String>` | 获取指定书籍的下载任务 JSON |
| `downloadPauseAll()` | 无 | `Future<void>` | 暂停所有下载 |
| `downloadResumeAll()` | 无 | `Future<void>` | 恢复所有下载 |
| `downloadRemoveTask(String taskId)` | taskId | `Future<void>` | 移除下载任务 |
| `downloadUpdateProgress(String taskId, double progress)` | taskId, progress | `Future<void>` | 更新下载进度 |

### 2.30 段评/章评（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `reviewGetByChapter(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取指定章节的所有评论 JSON |
| `reviewAdd({required String bookUrl, required int chapterIndex, int paragraphIndex = -1, required String content, String author = ''})` | bookUrl, chapterIndex, paragraphIndex, content, author | `Future<int>` | 添加评论，返回评论 ID |
| `reviewDelete(int id)` | id | `Future<bool>` | 删除评论 |
| `reviewLike(int id)` | id | `Future<void>` | 点赞评论 |

### 2.31 书籍导出（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `bookExport({required String bookUrl, required String format, required bool includeToc})` | bookUrl, format, includeToc | `Future<Map<String, dynamic>>` | 导出书籍，返回 ExportResult JSON |
| `bookExportInfo({required String bookUrl, required String format})` | bookUrl, format | `Future<Map<String, dynamic>>` | 获取导出预览信息 |

### 2.32 自动任务（auto_task FFI）（14 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `autoTaskBuildBookUpdateTask({required String bookUrl, required String bookName, required String bookAuthor, required String name})` | bookUrl, bookName, bookAuthor, name | `Future<Map<String, dynamic>>` | 构建书籍更新定时任务 |
| `autoTaskUpdateCronBatch({required String rulesJson, required String idsJson, required String cron})` | rulesJson, idsJson, cron | `Future<List<Map<String, dynamic>>>` | 批量更新 cron 表达式 |
| `autoTaskPrepareImported({required String localTasksJson, required String importedJson})` | localTasksJson, importedJson | `Future<List<Map<String, dynamic>>>` | 准备导入任务 |
| `autoTaskExecute({required String protocolJson})` | protocolJson | `Future<Map<String, dynamic>>` | 执行任务协议 |
| `autoTaskExecuteWithId({required String protocolJson, required String taskId})` | protocolJson, taskId | `Future<Map<String, dynamic>>` | 带任务 ID 执行任务协议 |
| `autoTaskNormalizeScript({required String script})` | script | `Future<String>` | 规范化脚本 |
| `autoTaskCanRefreshBookToc({required bool canUpdate, required bool respectCanUpdate})` | canUpdate, respectCanUpdate | `Future<bool>` | 判断书籍是否允许刷新目录 |
| `autoTaskFindBookUpdateTask({required String tasksJson, required String bookUrl, required String bookName, required String bookAuthor})` | tasksJson, bookUrl, bookName, bookAuthor | `Future<Map<String, dynamic>?>` | 查找书籍更新任务 |
| `autoTaskNextDueAt({required String cron, required int fromMs})` | cron, fromMs | `Future<int>` | 解析 cron 表达式计算下次执行时间 |
| `autoTaskListRules()` | 无 | `Future<List<Map<String, dynamic>>>` | 列出所有自动任务规则（数据库 CRUD） |
| `autoTaskCreateRule({required String ruleJson})` | ruleJson | `Future<String>` | 创建自动任务规则（数据库 CRUD） |
| `autoTaskUpdateRule({required String ruleJson})` | ruleJson | `Future<void>` | 更新自动任务规则（数据库 CRUD） |
| `autoTaskDeleteRule({required String id})` | id | `Future<void>` | 删除自动任务规则（数据库 CRUD） |
| `autoTaskFindRuleById({required String id})` | id | `Future<Map<String, dynamic>?>` | 根据 ID 查询自动任务规则（数据库 CRUD） |

### 2.33 音频播放模式（audio FFI）（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `audioWithPlayMode({String? readConfig, required int playMode})` | readConfig(可选), playMode | `Future<String>` | 将播放模式写入 readConfig JSON |
| `audioResolvePlayBook({String? requestedBookUrl, String? cachedBookJson})` | requestedBookUrl(可选), cachedBookJson(可选) | `Future<Map<String, dynamic>?>` | 解析听书书籍 |

### 2.34 压缩包导入（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `archiveImportZip({required String zipPath, required String outputDir})` | zipPath, outputDir | `Future<Map<String, dynamic>>` | 导入 ZIP 压缩包中的书籍文件 |
| `archiveImportRar({required String rarPath, required String outputDir, String? password})` | rarPath, outputDir, password(可选) | `Future<Map<String, dynamic>>` | 导入 RAR 压缩包中的书籍文件 |
| `archiveListZipFiles({required String zipPath})` | zipPath | `Future<List<String>>` | 列出 ZIP 压缩包中的书籍文件名 |
| `archiveListRarFiles({required String rarPath, String? password})` | rarPath, password(可选) | `Future<List<String>>` | 列出 RAR 压缩包中的书籍文件名 |
| `archiveDetectEncoding({required String filePath})` | filePath | `Future<Map<String, dynamic>>` | 检测 TXT 文件编码 |
| `archiveConvertEncoding({required String filePath, required String fromEncoding, required String toEncoding})` | filePath, fromEncoding, toEncoding | `Future<Map<String, dynamic>>` | 转换 TXT 文件编码 |
| `archiveIsArchive({required String filePath})` | filePath | `Future<bool>` | 判断文件是否为压缩包格式 |

### 2.35 RSS 已读记录（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `rssMarkRead(String origin, String title, {String? link})` | origin, title, link(可选) | `Future<void>` | 标记 RSS 文章为已读 |
| `rssIsRead(String link)` | link | `Future<bool>` | 判断文章是否已读（按 link 匹配） |
| `rssIsReadByTitle(String origin, String title)` | origin, title | `Future<bool>` | 判断文章是否已读（按 origin+title 匹配） |
| `rssClearReadRecords()` | 无 | `Future<void>` | 清空所有已读记录 |
| `rssReadRecordCount()` | 无 | `Future<int>` | 获取已读记录总数 |
| `rssListReadRecords({int? limit})` | limit(可选，默认100) | `Future<List<RssReadRecordRow>>` | 获取已读记录列表（按 readTime 降序） |

---

## 3. UI 轨需求登记区

> UI 轨需要新数据时，在此登记需求，Rust 轨按契约实现。流程见 [TWO_TRACK_DEV_SPEC.md § 4.3](TWO_TRACK_DEV_SPEC.md)。

| 方法名 | 入参 | 期望返回 | 登记日期 | 状态 |
|--------|------|----------|----------|------|
| `getSearchHistory`（字段修复） | 不变 | `List<SearchKeyword>` 序列化字段对齐 Dart 模型：`word` / `usage` / `lastUseTime` | 2026-08-01 | ✅ 已完成 |
| `searchHistoryByPrefix`（新增） | `String prefix, {int limit = 20}` | `Future<List<String>>`（前缀匹配的历史关键词，对标 Android `searchKeywordDao.flowSearch`） | 2026-08-01 | ✅ 已完成 |
| `importBooks`（新增） | `String jsonArray` | `Future<int>`（批量导入书籍，返回成功导入数量，用于 WebDAV 书架批量回写） | 2026-08-02 | ✅ 已完成 |
| `searchMultiStream`（新增） | `String query, {List<String>? sourceUrls}` | `Stream<Map<String, dynamic>>`（多源渐进式搜索，逐书源推送批次，用于 Phase 3.3 渐进搜索） | 2026-08-02 | ✅ 已完成 |
| `searchCover`（新增） | `String bookName` | `Future<List<Map<String, dynamic>>>`（网络封面候选列表，字段建议 `url` / `width` / `height`，用于 Phase 6 P1 `change_cover_screen` 封面搜索） | 2026-08-01 | ⛔ 待 Rust 实现 |
| `dictLookup`（新增） | `String word` | `Future<Map<String, dynamic>>`（词典释义，字段对齐 Dart `DictEntry`：`word` / `phonetic` / `definitions[]`，用于 `dict_screen` 真实词典查询） | 2026-08-01 | ⛔ 待 Rust 实现 |

> **需求 1：getSearchHistory 字段修复（Bug）**
> 当前 Rust `search_history_api::get_search_history` 返回 DTO 字段为 `keyword` / `book_name` / `time`，
> 而 Dart `SearchKeyword` 模型（对齐 Android 原版实体）解析 `word` / `usage` / `lastUseTime`。
> 字段名不匹配导致 `SearchKeyword.fromJson` 解析后 `word` 恒为空字符串，
> 影响全局搜索历史与书内搜索历史（`search_content_screen.dart`）的真实 FFI 显示。
> 请 Rust 轨将 `SearchHistoryItem` 序列化字段对齐 Dart 模型（`word` / `usage` / `lastUseTime`）。
>
> **需求 2：searchHistoryByPrefix 前缀联想**
> Rust 仓储层已有 `SearchKeywordRepository::find_by_prefix`（LIKE 前缀匹配），但未暴露至 FFI bridge。
> 请暴露为 `searchHistoryByPrefix(prefix, {limit})` FFI 方法，供搜索页联想使用。
> UI 轨当前以客户端前缀过滤临时实现（行为等价），待本方法交付后切换为 DB 查询。
>
> **需求 3：searchCover 网络封面搜索（Phase 6 P1）**
> `change_cover_screen` 网络封面搜索原为 UI 内联占位假数据（`Future.delayed` + picsum 随机图）。
> Android 原版通过配置的封面源（图片搜索）按书名检索候选封面。请 Rust 轨提供 `searchCover(bookName)`。
> **响应契约**（snake_case，UI 侧已建 `CoverCandidate` freezed 模型对齐）：返回 `List<Map<String, dynamic>>`，
> 每项字段 `url: String`（封面图片地址，必需）/ `width: int`（像素，未知填 0）/ `height: int`（像素，未知填 0）。
> **错误语义**：无候选返回空列表（非异常）；网络/源异常抛出经 bridge 统一映射为 `BridgeError`。
> **UI 侧现状（Mock 先行）**：`ChangeCoverNotifier.searchCovers` 已就位并以 Mock 数据驱动 `CoverCandidate` 数据流，
> `change_cover_screen` 已重构为 `ConsumerStatefulWidget`（UI 层不再制造假数据）。Rust 交付后仅需将 Notifier 内
> `_mockSearch` 替换为 `ref.read(bookApiProvider).searchCover(keyword)` 并 `CoverCandidate.fromJson` 解析返回。
> 本地选图路径（FilePicker）不依赖本契约。因 UI 轨禁改 `rust_api.dart`，未单边添加 BookApi 抽象方法。
>
> **需求 4：dictLookup 词典查询（Phase 6 P2 延伸）**
> `dict_screen` 本地内置词典为静态占位数据，仅覆盖少量示例词。请 Rust 轨提供 `dictLookup(word)`。
> **响应契约**（snake_case，UI 侧已建 `DictEntry` freezed 模型对齐）：返回 `Map<String, dynamic>`，
> 字段 `word: String`（归一化后的单词）/ `phonetic: String`（音标，可空字符串）/ `definitions: List<String>`（释义条目）。
> **错误语义**：未收录词返回 `definitions` 空列表（非异常）；查询异常抛出经 bridge 统一映射为 `BridgeError`。
> **UI 侧现状（Mock 先行）**：`DictNotifier.lookup` 已封装查询职责，当前以本地内置词典 `_localDict` 为占位数据；
> 在线词典规则跳转经 `getConfig/setConfig` 持久化，不依赖本契约。Rust 交付后将 `_localDict[key]` 替换为
> `await api.dictLookup(key)`（届时 `lookup` 转异步）即可，模型字段即契约。

---

## 附录：模块方法数统计

| # | 模块 | 方法数 |
|---|------|--------|
| 1 | 初始化/版本 | 2 |
| 2 | 书架操作 | 9 |
| 3 | 书源操作 | 10 |
| 4 | 搜索操作 | 5 |
| 5 | RSS 源操作 | 9 |
| 6 | 本地书籍操作 | 4 |
| 7 | 书签操作 | 6 |
| 8 | 替换规则操作 | 6 |
| 9 | 阅读器操作 | 6 |
| 10 | 配置操作 | 4 |
| 11 | 备份操作 | 2 |
| 12 | 阅读记录 | 4 |
| 13 | RSS 收藏操作 | 4 |
| 14 | 书籍分组 | 4 |
| 15 | 搜索历史 | 5 |
| 16 | 缓存管理 | 5 |
| 17 | WebBook 操作 | 4 |
| 18 | 发现页操作 | 2 |
| 19 | 规则解析 | 1 |
| 20 | 网络操作 | 2 |
| 21 | JS 引擎 | 2 |
| 22 | 服务器管理 | 4 |
| 23 | 书籍格式解析 | 3 |
| 24 | 阅读统计 | 5 |
| 25 | HTTP TTS | 7 |
| 26 | 音频播放 | 4 |
| 27 | 用户管理 | 6 |
| 28 | WebDAV 云同步 | 5 |
| 29 | 下载管理器 | 7 |
| 30 | 段评/章评 | 4 |
| 31 | 书籍导出 | 2 |
| 32 | 自动任务 | 14 |
| 33 | 音频播放模式 | 2 |
| 34 | 压缩包导入 | 7 |
| 35 | RSS 已读记录 | 6 |
| | **合计** | **171** |
