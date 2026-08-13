# API 契约文档（BookApi 接口基准）

**日期**: 2026-08-01
**版本**: v1.0
**维护人**: Legado 开发团队（Qoder / QoderCN）

**更新记录**：

| 日期 | 内容 |
|------|------|
| 2026-08-01 | 契约初版冻结（v1.0） |
| 2026-08-10 | 第二批后置项 FFI 冻结：三个加法式新增——`shrinkDatabase`（§2.16 缓存管理）/ `webdavUploadFile`（§2.28 WebDAV 云同步）/ `toggleSameTitleRemoved`（§2.9 阅读器操作），契约合计方法数 174→177（Task #50） |
| 2026-08-10 | 第三批后置项 FFI 冻结：两个加法式新增——`setSourceVariable`（§2.3 书源操作）/ `getBookmarksByBook`（§2.7 书签操作，书签作者维度查询）+ `book_sources` 表补 `variable` 列 schema 迁移预告（SCHEMA_VERSION 102→103，幂等迁移），契约合计方法数 225→227（Task #63） |
| 2026-08-10 | 第四批后置项 FFI 冻结（Task #72）：三个加法式新增——`setCustomHosts`（§2.20 网络组，对齐原版 hosts 映射 JSON 对象）/ `setMcpPort`（§2.22 服务器组，**决策：对齐原版独立端口方案**，不复用 `setServerPort`，默认 1236，≤0=停止独立 MCP 服务）/ `searchCoverRules`（§2.4 搜索组，coverRules 表规则搜封面），附录合计 236→239，BookApi 口径 227→230 |
| 2026-08-12 | 远程书库（P1-5）加法式新增——`webdavDownloadFile`（§2.28 WebDAV 云同步，镜像 `webdavUploadFile`，二进制落盘）；远程服务器列表沿用 Flutter `SettingsService` 持久化（对齐原版 `servers` 表语义，不新增 Server CRUD FFI）。附录合计 239→240，BookApi 口径 230→231 |
| 2026-08-12 | P1-2 加法式新增——`clearCookie`（§2.3 书源操作，对齐原版 `CookieStore.removeCookie`）：按 URL 二级域名清除持久层 + 共享 HTTP 内存 CookieStore + JS 宿主 Cookie；附录合计 240→241，BookApi 口径 231→232 |
| 2026-08-13 | P2-4 部分：恢复忽略项 UI + `localBook` 在调用 `restore` 前由 Flutter 过滤备份 JSON（无新 FFI）；「导入旧版」仍隐藏待确认 |
| 2026-08-13 | P2-4 续：恢复忽略项其余键——备份 JSON 注入 `appPrefs`，恢复时按 BackupConfig.keyIsNotIgnore 过滤（readConfig/themeMode/themeConfig/coverConfig/bookshelfLayout/showRss/threadCount）；无新 FFI |
| 2026-08-13 | P2-1：底栏皮肤最小可用——纯 Flutter（`archive` zip 导入 + PrefKeys.bottomBarSkin）；**无新 FFI** |
| 2026-08-12 | P1-14 加法式新增——`looksLikeCurl` / `curlToAnalyzeUrl` / `analyzeUrlToCurl`（§2.3 书源操作）：对齐原版 `CurlAnalyzeUrlConverter`；Rust 复用 `legado-parser::curl_converter`。附录合计 241→244，BookApi 口径 232→235 |
| 2026-08-14 | **F3-20**：BookApi 补 5 项延迟封装，§3 待 UI 封装清单清零；BookApi **252** 方法 |
| 2026-08-14 | **F3-17**：加法式 `rssListReadRecordsByOrigin`（§2.35）；**F3-10** 契约全面同步至 BookApi **247** 方法、附录 **251** |
| 2026-08-14 | **F3-14**：加法式新增 `httpGetBytes`（§2.20）；UI 层 8 处裸 `http.get` 收敛至 Bridge；附录 244→245，BookApi 233→234 |
| 2026-08-14 | **F3-5**：§1.6 登记 9 个 FFI 非 Result 导出豁免（只读/哨兵语义，不改签名） |
| 2026-08-13 | P2-8：检查更新对接 GitHub Release API（`AppUpdateService` + `UpdateDialog`）；纯 Flutter HTTP，**无新 FFI** |
| 2026-08-13 | P2-7：AutoTaskDebug 流式调试——UI 逐行回调 + `TaskResult.details` 对齐 LogFormatter；复用 `autoTaskExecuteWithId`，**无新 StreamSink FFI** |
| 2026-08-13 | `getSameTitleRemoved` / `canRemoveSameTitle` 权威查询与试算 FFI（§2.9）；UI 勾选态改读 caches KV；复刻「未找到可移除的重复标题」提示 |
| 2026-08-13 | **DB schema 结构对齐专项落地**（台账称「schema v102」，代码版本号 **103→104**，因 102/103 已分别用于 cached_chapters 复合索引与 book_sources.variable）：rssArticles/rssStars/readRecord 主键重建；rssReadRecords/httpTTS（原 http_tts）/search_keywords 结构对齐 Room v95；rssSources 去掉 enableCookieJar 冗余列；coverRules 纳入建表清单。无新 FFI；Repository 列名随表结构适配。残留：rule_subs/dict_rules/keyboard_assists 表名仍为 snake_case（见台账 §4.2.1） |
| 2026-08-13 | **D1**：SCHEMA 104→105，`ruleSubs`/`dictRules`/`keyboardAssists` 对齐 Room 表名列名（Migration104To105） |
| 2026-08-13 | **F4**：封面规则 CRUD 加法式新增——`getCoverRule` / `saveCoverRule` / `deleteCoverRule`（§2.4，对齐原版 `BookCover` + `CoverRuleConfigDialog`） |
| 2026-08-13 | **F5**：`setMcpPort` 对齐原版 LAN（`0.0.0.0`）+ `jsSourceApiToken` 启动前置 + `X-Legado-Token` 鉴权（§2.22） |
| 2026-08-13 | **SOURCE_DIFF P0-1**：`@put:`/`@get:`/`setLocal` 变量系统落地——`AnalyzeRule` 会话变量 + 章节 `WebChapter.variable` / `BookChapter.variable` 透传；**无新 FFI 方法**（既有 webbook/reader JSON 加法式字段） |
| 2026-08-14 | **F3-13（D4=B）**：`video_play_utils.dart` 视频 URL/MPD 解析保留 Flutter 层（对齐原版 VideoPlay 复合 URL 语义）；**登记豁免**，不新增 video FFI |
| 2026-08-14 | **F3-4（D3=A）**：沙箱文档口径——书源主路径 `EnginePool` 启用 eval/Function（Rhino 对齐）；`js_eval` 仍用严格 `SandboxConfig::default()` |
| 2026-08-13 | **SOURCE_DIFF P1 DOM WebView**：加法式新增 `webviewRequestStream` / `webviewSubmit` / `webviewCancel` / `webviewPending`（§2.3）：对齐 `BackstageWebView` 挂起-唤醒；Flutter 订阅后 `@webjs`/正文 webJs/`java.webView*` 走真实 DOM。附录合计随 codegen +4 |
| 2026-08-13 | **SOURCE_DIFF 纯工程收口（无新 FFI）**：Android 原生 `backstageEval` 落地页内 `java`/`source`/`cache` JavascriptInterface + `cacheFirst`→`LOAD_CACHE_ELSE_NETWORK`；Rust `ownText`/`string_rule_cache`。契约语义边界更新，方法表不变 |

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

### 1.6 FFI 非 Result 导出豁免（F3-5，2026-08-14）

以下 9 个 `ffi.rs` 导出**刻意**不包 `Result<_, BridgeError>`，BookApi/Dart 侧保持既有签名；语义为只读查询或哨兵返回值，失败不抛 bridge 异常：

| FFI 函数 | 返回类型 | 豁免理由 |
|----------|----------|----------|
| `version` | `String` | 编译期常量版本号，永真 |
| `backup_list` | `String` | 目录列表 JSON；IO 失败返回 `[]` 空数组字符串 |
| `server_stop` | `String` | 状态消息字符串（对齐 stopServer 吞错语义） |
| `server_status` | `String` | 状态 JSON；未启动时返回 `{running:false}` |
| `archive_is_archive` | `bool` | 纯路径扩展名判定，无 IO |
| `auto_task_normalize_script` | `String` | 纯字符串变换，输入必返字符串 |
| `auto_task_can_refresh_toc` | `bool` | 纯布尔逻辑组合 |
| `auto_task_next_due_at` | `i64` | cron 无法解析时返回 **-1** 哨兵（非异常） |
| `audio_with_play_mode` | `String` | readConfig JSON 变换；非法 JSON 回落 `{}` |

> 其余新增 FFI 仍遵循 `Result<_, BridgeError>` 铁律；本表仅销记历史非 Result 面，**不扩范围**。

### 1.7 BookApi / FFI 命名等价表（F3-10，2026-08-14）

以下 8 对 Dart `BookApi` 方法名与契约/FFI 登记名不一致，语义等价，计数时勿重复：

| BookApi（Dart） | 契约 §2.x / FFI 登记名 |
|-----------------|------------------------|
| `extractJsSource` | `jsSourceExtract`（§2.37） |
| `checkJsSourceSyntax` | `jsSourceSyntaxCheck`（§2.37） |
| `stampJsSourceLastUpdateTime` | `jsSourceStampLastUpdateTime`（§2.37） |
| `isLoginUiV2` | `sourceIsLoginUiV2`（§2.3） |
| `loginUiV2` | `sourceLoginUiV2`（§2.3） |
| `loginActionV2` | `sourceLoginActionV2`（§2.3） |
| `listCachedChapterUrls` | `cacheListCachedChapterUrls`（§2.43.5） |
| `getCachedChapter` | `cacheGetChapter`（§2.16 / §2.41） |

---

## 2. 方法清单

> 共 **43 个模块**（§2.1–§2.43）；以 `flutter_legado/lib/src/services/book_api.dart` 程序化计数
> 为基准，BookApi 接口当前共 **252 个方法**（2026-08-14 F3-20 补 backupList/bookGroupSetShow/httpTtsSetEnabled/ttsSpeak/ttsSetCacheDir 5）。
> 附录 §2.1–§2.43 行合计 **251**；扣除尚未封装进 BookApi 的 FFI 5 个（§2.43 缓存下载等，见附录口径）+ 命名等价闭合 = **252**（F3-20 后 §3 待封装清单清零，BookApi 已含原 §2.41/§2.42 待封装 5 项）。

### 2.1 初始化/版本（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `initialize()` | 无 | `Future<void>` | 初始化 Rust 运行时和数据库连接 |
| `getVersion()` | 无 | `Future<String>` | 获取引擎版本号 |

### 2.2 书架操作（10 个方法）

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
| `reorderBooks(List<Map<String, dynamic>> orders)` | orders: `[{bookUrl, order}, ...]` | `Future<void>` | 批量持久化拖拽排序（对齐原版 BookAdapter.swap 后 updateBook） |

### 2.3 书源操作（25 个方法）

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
| `sourceIsLoginUiV2(String sourceJson)` | sourceJson: BookSource JSON | `Future<bool>` | 判定登录 UI 是否为 V2 动态状态协议（#402/#488，加法式新增） |
| `sourceLoginUiV2(String sourceJson, String stateJson)` | sourceJson, stateJson（首次传 `"{}"`） | `Future<String>` | 执行 loginUi v2 脚本，返回动态 UI 描述 JSON `{"rows":[RowUi...]}`（#402，加法式新增） |
| `sourceLoginActionV2(String sourceJson, String userInputJson)` | sourceJson, userInputJson | `Future<String>` | 执行 loginAction v2 动作，返回命令 JSON（state/error/login/close）（#402，加法式新增） |
| `checkSource(String sourceJson, {String? configJson})` | sourceJson: BookSource JSON；configJson(可选): 校验配置 JSON | `Future<Map<String, dynamic>>` | 校验单个书源（搜索→详情→目录→正文四步 + 验证码/重定向检测），返回 CheckResult JSON（Task #87，加法式新增） |
| `checkSourcesStream(List<String> sourceUrls, {String? configJson})` | sourceUrls: 待校验书源 URL 列表（空列表=全部书源）；configJson(可选) | `Stream<Map<String, dynamic>>` | 批量校验书源（串行逐个回推进度，对齐 Kotlin CheckSourceService），每条为 CheckProgress JSON（Task #87，加法式新增） |
| `cancelCheckSources()` | 无 | `Future<void>` | 取消正在进行的批量书源校验（Task #87，加法式新增） |
| `verificationRequestStream()` | 无 | `Stream<Map<String, dynamic>>` | 验证码请求事件流（长期存活，订阅时先回放进行中请求），事件字段：`key` / `source_url` / `source_name` / `image_url` / `title` / `use_browser`（恒 false，已降级）/ `created_at_ms`（Task #90，加法式新增） |
| `submitVerificationResult(String key, String code)` | key: resultKey；code: 用户输入的验证码 | `Future<bool>` | 提交验证码结果唤醒 JS 等待方（对齐 Kotlin `setResult`：空值也唤醒，空值判定在等待侧），返回是否命中进行中请求（Task #90，加法式新增） |
| `cancelVerificationRequest(String key)` | key: resultKey | `Future<bool>` | 取消验证码请求（对齐 Kotlin `checkResult`：以空结果唤醒等待方），返回是否命中（Task #90，加法式新增） |
| `webviewRequestStream()` | 无 | `Stream<Map<String, dynamic>>` | BackstageWebView DOM 执行请求流（长期存活，订阅时回放进行中请求）。事件字段：`key` / `action` / `html` / `url` / `js` / `source_regex` / `override_url_regex` / `cache_first` / `delay_time` / `is_rule` / `result` / `created_at_ms`（SOURCE_DIFF P1，加法式新增） |
| `submitWebviewResult(String key, String result)` | key: resultKey；result: WebView 执行结果（可空） | `Future<bool>` | 提交 DOM 执行结果唤醒 Rust 等待方，返回是否命中（SOURCE_DIFF P1，加法式新增） |
| `cancelWebviewRequest(String key)` | key: resultKey | `Future<bool>` | 取消 WebView 请求（空结果唤醒），返回是否命中（SOURCE_DIFF P1，加法式新增） |
| `setSourceVariable(String sourceUrl, String variable)` | sourceUrl: 书源 URL；variable: 自定义变量内容（空串=清除） | `Future<void>` | 设置书源自定义变量（对齐原版 `source.setVariable`），单列 UPDATE 语义仅更新 `variable` 单列，规避 `updateBookSource` 全行更新风险；variable 为空串表示清除该变量。错误码：Internal（书源不存在）/ Db（写入失败）。**DB schema 变更预告**：`book_sources` 表补 `variable` 列（幂等迁移，SCHEMA_VERSION 102→103）（台账 §5.11-3，第三批后置项，Task #63，加法式新增） |
| `clearCookie(String url)` | url: 书源/订阅源 URL（或任意含域名的地址） | `Future<void>` | 清除该 URL 所属二级域名的 Cookie（对齐原版 `CookieStore.removeCookie` / 编辑页 `menu_clear_cookie`）。清除范围：① cookies 表持久层；② 共享 HTTP 客户端内存 CookieStore；③ JS 宿主 `java.clearCookies` 内存表。差距说明：原版另清 WebView Cookie / 会话 CacheManager，本实现无独立 WebView Cookie 层（与 MCP `clear_cookies` 一致）。url 为空 → Internal。加法式新增（2026-08-12 P1-2） |
| `looksLikeCurl(String text)` | text: 待判定文本 | `Future<bool>` | 判断是否形似 cURL 命令（对齐 `CurlAnalyzeUrlConverter.looksLikeCurl`）。加法式新增（2026-08-12 P1-14） |
| `curlToAnalyzeUrl(String text)` | text: cURL 命令 | `Future<String>` | cURL → AnalyzeUrl 模板（`url` 或 `url,{options}`）。错误消息含 `[CURL_*]` 前缀。加法式新增（2026-08-12 P1-14） |
| `analyzeUrlToCurl(String text)` | text: AnalyzeUrl 模板 | `Future<String>` | AnalyzeUrl → cURL 命令。错误消息含 `[CURL_*]` 前缀。加法式新增（2026-08-12 P1-14） |
| `sourceCallBackBtn({required String event, required String bookUrl, int? chapterIndex, String? result, int bookType = 0})` | event, bookUrl, chapterIndex(可选), result(可选), bookType | `Future<Map<String, dynamic>>` | 书源 callBackBtn JS（对齐 SourceCallBack）；返回 `invoked` / `jsTrue` / `raw` / `actions`（F3-10 补登记） |

> ℹ️ **登录 UI V2 动态状态协议（#402/#488）**：Rust 侧 `ffi::source_is_login_ui_v2 / source_login_ui_v2 / source_login_action_v2`（核心实现 `legado-core/src/login_ui_v2.rs`，对齐 Kotlin `LoginUiV2.kt` + `BaseSource.evalLoginUiV2/evalLoginActionV2`）。`loginUi` 为 `{"version":2}` 标记时启用；登录脚本取自 `mainJs`（JS 单文件书源）或 `loginUrl`，须实现 `loginUi(state)` / `loginAction(action, state, form)`。`userInputJson` 契约：`{"action":"...","stateJson":"...","formJson":{...}}`（stateJson/formJson 支持字符串或对象）。JS 返回 null/undefined 时返回空字符串；需 quickjs 特性构建。RowUi V2 扩展字段：key/hint/value/options/countdown。冻结契约保持不变，本组方法为加法式新增。
>
> ℹ️ **书源校验（Task #87）**：Rust 侧 `ffi::source_check / source_check_stream / source_check_cancel`（核心实现 `legado-ffi/src/api/source_check_api.rs`，包装 `legado-net::source_checker::SourceChecker`，与 legado-server `/sources/check` 同源）。`checkSource` 返回 CheckResult JSON：`source_url` / `search_ok` / `toc_ok` / `content_ok` / `search_error` / `toc_error` / `content_error` / `total_time_ms` / `captcha`（detected/captcha_type/matched_keyword）/ `redirect`（redirected/original_url/final_url/is_login_redirect）。`checkSourcesStream` 每完成一个书源推送一条 CheckProgress JSON：`index` / `total` / `is_last` / `source_name` / `result`（CheckResult）；**串行**校验（对齐 Kotlin `CheckSourceService` flow 顺序执行，避免对书源站并发压力），不存在的书源推送失败结果而非跳过（序号连续）。`configJson` 契约：`{"keyword":String,"step_timeout_ms":int,"check_search":bool,"check_toc":bool,"check_content":bool,"detect_captcha":bool,"detect_redirect":bool}`，全部字段可选，缺省回落 CheckerConfig 默认值（keyword="我的"、step_timeout_ms=180000、其余全开）。冻结契约保持不变，本组方法为加法式新增。
>
> ℹ️ **验证码交互通道（Task #90）**：Rust 侧 `ffi::verification_request_stream / verification_submit / verification_cancel / verification_pending`（核心实现 `legado-core/src/verification_channel.rs`，对齐 Kotlin `SourceVerificationHelp` + `JsExtensions.getVerificationCode/startBrowserAwait`）。JS 书源经宿主 API 钩子挂起等待（std condvar 阻塞 JS 工作线程，不占用 tokio runtime，默认超时 5 分钟对齐 Kotlin）；同书源并发请求经航班去重共享结果（空 source_url 匿名请求不去重）；`use_browser` 一律降级为图片验证码（桌面端无 WebView）。`verificationSubmit` 无论 code 是否为空都唤醒等待方（对齐 Kotlin `setResult`），空值由等待侧报「验证结果为空」；`verificationCancel` 等价 Kotlin `checkResult`（空结果唤醒）；超时返回「source verification timed out」。订阅事件流时先回放当前进行中的请求。冻结契约保持不变，本组方法为加法式新增。
>
> ℹ️ **BackstageWebView DOM 通道（SOURCE_DIFF P1）**：Rust 侧 `ffi::webview_request_stream / webview_submit / webview_cancel / webview_pending`（核心 `legado-core/src/webview_channel.rs`）。Flutter `WebViewBridgeListener` 订阅后，`@webjs` / 正文 `contentRule.webJs` / `java.webView*` 经真实 WebView 执行并回传；无订阅者时回退无头 QuickJS 或历史桥接载荷（`interceptResult`）。默认超时 60s，规则级 Mode.WebJs 10s。**Android**：`PlatformBridgeService`→原生 `legado/webview.backstageEval`：`cacheFirst`→`WebSettings.LOAD_CACHE_ELSE_NETWORK`；`isRule`+html 时注入 `java`/`source`/`cache` JavascriptInterface（变量读写与精简同步 API；ajax 等网络类仍建议无头宿主）。非 Android 回退 `webview_flutter`（无 cacheMode）。加法式新增。

### 2.4 搜索操作（12 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `searchBooks(String keyword, {List<String>? sourceUrls})` | keyword, sourceUrls(可选) | `Future<List<SearchResult>>` | 搜索书籍 |
| `preciseSearch(String name, String author, {List<String>? sourceUrls})` | name, author, sourceUrls(可选) | `Future<SearchBook>` | 精确搜索（对齐 `WebBook.preciseSearchAwait`）：启用源中搜书名，返回首个 name+author 完全匹配的 SearchBook JSON；未命中抛错（SOURCE_DIFF P0-2） |
| `searchMulti(String query, {List<String>? sourceUrls})` | query, sourceUrls(可选) | `Future<List<Map<String, dynamic>>>` | 多源并行搜索 |
| `searchMultiStream(String query, {List<String>? sourceUrls})` | query, sourceUrls(可选) | `Stream<Map<String, dynamic>>` | 多源渐进式（流式）搜索：每完成一个书源即推送一个批次，无需等待最慢书源 |
| `cancelSearch()` | 无 | `Future<void>` | 取消搜索 |
| `searchSource(String bookName, String author, {List<String>? sourceUrls, bool loadInfo = false, bool loadToc = false, bool loadWordCount = false})` | bookName, author, sourceUrls(可选), loadInfo, loadToc, loadWordCount | `Future<List<Map<String, dynamic>>>` | 搜索可替换的书源 ⚠️ 双兼容点（留项#12/Task #131：`sourceUrls` 为加法式新增可选参数，null/空=搜全部启用源，兼容既有调用） |
| `searchCover(String bookName)` | bookName | `Future<List<Map<String, dynamic>>>` | 搜索书籍封面候选列表：复用多书源搜索提取封面 URL，每项字段 `url` / `width` / `height`（未知尺寸填 0），无候选返回空列表 |
| `switchSource(String bookUrl, String newSourceUrl, String newBookUrl)` | bookUrl, newSourceUrl, newBookUrl | `Future<String>` | 切换书源 |
| `searchCoverRules(String name)` | name: 书名（作为规则搜索关键词，对齐原版 `BookCover.searchCover(book)` 传 `book.name` 语义） | `Future<String>` | 按书名执行 coverRules 表中全部启用规则搜封面（JS 搜索规则语义对齐原版 `BookCover.searchCover` 链路），返回候选封面 URL **裸 JSON Array**（遵守 §1.4 铁律）；无启用规则/无候选返回空数组（非异常）；单规则失败隔离（记日志跳过，不阻断其余规则）。错误码：Internal（coverRules 规则数据读取失败）（台账 §5.13-10，第四批后置项，Task #72，加法式新增） |
| `getCoverRule()` | 无 | `Future<String>` | 读取封面规则配置（对齐原版 `BookCover.getCoverRule`）：返回裸 JSON 对象 `{enable, searchUrl, coverRule}`；表空时回退 `DefaultData.coverRule`（assets 同源）。错误码：Internal |
| `saveCoverRule(String ruleJson)` | ruleJson: `{enable, searchUrl, coverRule}` | `Future<bool>` | 保存封面规则（对齐原版 `BookCover.saveCoverRule`）：写入 coverRules 表（单配置语义，REPLACE 主配置行）；searchUrl/coverRule 为空 → Internal。F4 |
| `deleteCoverRule()` | 无 | `Future<bool>` | 删除用户封面规则配置（对齐原版 `BookCover.delCoverRule`）：清空 coverRules；随后 `getCoverRule` 回退默认。F4 |

> ⚠️ `searchSource`：Rust 返回 `SourceSwitchResponse { book_name, author, matches[] }`，Dart 侧提取 `matches` 字段。
>
> ℹ️ `searchSource` 分组/书源范围过滤（留项#12，Task #131 闭合）：Rust 侧 `ffi::source_switch_search(book_name, author, source_urls_json)` 新增第三个参数 `source_urls_json`（JSON 字符串数组；空串/空数组/缺省=搜全部启用源，语义与 `search_books` 的 `source_urls_json` 完全一致，复用 `search::load_search_sources` 过滤逻辑）。C ABI `ffi_source_switch_search` 同步加参。Dart 侧 `searchSource` 新增可选命名参数 `sourceUrls`，由 `rust_api` 编码为 `sourceUrlsJson` 传入；换源页按 `AppConfig.searchGroup` 内存过滤出该分组源 URL 列表后传入。冻结契约返回结构不变，本变更为加法式新增。
>
> ℹ️ `searchSource` 分组 config 原生过滤（留项#12 增强，Task #145，**零签名变更**）：Rust 侧 `source_switch::resolve_switch_sources` 内部读取 config `searchGroup`（键名对齐原版 `AppConfig.searchGroup`，UI setConfig 已通），非空时对齐原版 `getEnabledPartByGroup` 的 `SOURCE_GROUP_MEMBERSHIP_FILTER` SQL 语义过滤：分组字段按 `,`/`;`/`，`/`；` 规范化拆分、逐组名 trim 后与目标分组精确相等匹配（非子串）；空分组=全部启用源。过滤后零结果由 UI 弹「xx分组搜索结果为空，是否切换到全部分组」对话框（对标 ChangeChapterSourceDialog L90-97，确认后清空 searchGroup 重搜）。
>
> ℹ️ `searchSource` 换源高级选项（审计 F2-2，**加法式新增**）：Rust 侧 `ffi::source_switch_search` 第四参 `options_json` 为 JSON 对象 `{loadInfo,loadToc,loadWordCount}`；Dart `searchSource` 三命名参数编码传入。空串/缺省时 Rust 回退读取 config `changeSourceLoadInfo`/`changeSourceLoadToc`/`changeSourceLoadWordCount`（键名对齐原版 AppConfig）。`loadInfo` 触发详情页补全；`loadToc`/`loadWordCount` 触发目录抓取；`loadWordCount` 另试读末章正文计字数并按原版 `wordCountComparator` 排序。返回 `matches[]` 项新增可选字段 `chapter_word_count_text` / `chapter_word_count` / `respond_time` / `origin_order`（snake_case）。
>
> ℹ️ `searchMultiStream`：Rust 侧 `ffi::search_multi_stream(query, source_urls_json, sink: StreamSink<String>)`（frb 生成 Dart `Stream<String>`），每完成一个书源推送一个 `SearchSourceBatch` JSON：`source_index` / `source_url` / `source_name` / `books[]` / `error?` / `finished_count` / `total_count` / `is_last`。冻结契约 `searchMulti` 保持不变，本方法为加法式新增。
>
> ℹ️ **封面规则搜索（台账 §5.13-10，Task #72）**：原版实现为单条封面规则配置——Kotlin `BookCover.searchCover(book)` 读取 `CoverRule(enable, searchUrl, coverRule)`（用户配置存 CacheManager，缺省回退 `DefaultData.coverRule`，UI 入口 `CoverRuleConfigDialog`），以 `AnalyzeUrl(searchUrl, book.name)` 发起搜索请求，再经 `AnalyzeRule.getString(coverRule, isUrl=true)` 提取封面 URL。本轨差异与对齐方案：规则载体为 `legado-db` 既有 `coverRules` 表（`id` / `name` / `rule` / `enable`，默认数据注入已就位），执行全部 `enable=1` 规则；规则执行复用既有书源搜索/JS 执行基础设施（`legado-net` HTTP 抓取 + `legado-parser`/quickjs 规则解析链路，与 `dictLookup` 字典规则执行同模式），`rule` 文本承载 searchUrl 与提取规则（具体内联格式由 Rust 轨实施时按表内既有数据确定）；单规则失败隔离不阻断其余；与既有 `searchCover`（多书源搜索提取封面）互补并存、互不影响。冻结契约保持不变，本方法为加法式新增。

### 2.5 RSS 源操作（10 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getRssSources()` | 无 | `Future<List<RssSource>>` | 获取所有 RSS 源 |
| `addRssSource(RssSource source)` | source: RssSource 对象 | `Future<RssSource>` | 添加 RSS 源 |
| `updateRssSource(RssSource source)` | source: RssSource 对象 | `Future<void>` | 更新 RSS 源（Rust 侧 `ffi::rss_update_source`：按 `sourceUrl` 主键单条 UPDATE 原子更新，替代「删旧+加新」workaround，规避级联串表风险；Task #108，加法式新增 FFI）。✅ UI 封装接通：`rust_api.updateRssSource` 已由误接 `sourceUpdate` 改接 `rssUpdateSource` 真实管线（本次评审修复提交），Mock 同步对齐「源不存在时报错」语义 |
| `rssUpdateSource(String sourceJson)` | sourceJson: RssSource JSON | `Future<String>` | 原子更新 RSS 源（按 `sourceUrl` 主键单条 UPDATE 全字段），源不存在时报错，返回更新后的 RssSource JSON（Task #108，加法式新增） |
| `deleteRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 删除 RSS 源 |
| `enableRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 启用 RSS 源 |
| `disableRssSource(String sourceUrl)` | sourceUrl | `Future<void>` | 禁用 RSS 源 |
| `importRssSources(String jsonArray)` | jsonArray: JSON 数组字符串 | `Future<int>` | 导入 RSS 源，返回成功数量。✅ **2026-08-12 纠偏**：Flutter `rust_api.importRssSources` 曾误接 `sourceImport`（写入书源表）；现改为逐条 `rssAddSource` 落 `rssSources`。Rust `add_rss_source` 已改走 `RssSourceRepository::insert` 全字段；`import_rss_sources` 已在 `api/rss.rs` 备好，待 FRB 生成后可改批量 FFI |
| `exportRssSources()` | 无 | `Future<String>` | 导出 RSS 源。✅ **2026-08-12 纠偏**：勿走 `sourceExport`；现导出 `getRssSources()` JSON |
| `getRssArticles(String sourceUrl)` | sourceUrl | `Future<List<RssFeedArticle>>` | 获取 RSS 文章列表 |
| `rssClearArticles(String sourceUrl)` | sourceUrl | `Future<void>` | 清空指定 RSS 源本地文章缓存（对齐原版 clearArticles，F3-10 补登记） |

> ℹ️ **RSS 源原子更新（Task #108 缺口④）**：Rust 侧 `ffi::rss_update_source(source_json)`（核心实现 `legado-ffi/src/api/rss.rs::update_rss_source`，DB 层 `legado-db::RssSourceRepository::update_fields`）。对 `rssSources` 表按 `sourceUrl` 主键执行**单条 UPDATE 语句**全字段原子更新（不走 DELETE+INSERT，不触发外键级联）；目标源不存在时返回错误（不静默插入）。Flutter 侧 RSS 源编辑保存应改走本接口，替代原「删旧+加新」workaround。冻结契约保持不变，本方法为加法式新增。

### 2.6 本地书籍操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `importLocalBook(String filePath)` | filePath | `Future<Book>` | 导入本地书籍 |
| `scanLocalBooks(String dirPath)` | dirPath | `Future<List<Map<String, dynamic>>>` | 扫描本地书籍，返回 `{path, name, size, lastModified}` |
| `detectFormat(String filePath)` | filePath | `Future<String>` | 检测书籍文件格式 |
| `parseMetadata(String filePath)` | filePath | `Future<String>` | 解析书籍元数据（返回 JSON） |

### 2.7 书签操作（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getBookmarks(String bookName)` | bookName | `Future<List<Bookmark>>` | 获取某本书的所有书签（仅按书名查询；同名书会混入，兼容保留，推荐用 `getBookmarksByBook`） |
| `getBookmarksByBook(String bookName, String bookAuthor)` | bookName, bookAuthor | `Future<List<Bookmark>>` | 按书名+作者获取某本书的所有书签（对齐原版 `bookmarkDao.getByBook(name, author)`，规避同名书混入）；返回书签列表（遵守 §1.4 裸数组铁律）。既有 `getBookmarks` 签名保持不变，本方法为加法式新增。方案说明：不采用给 `getBookmarks` 追加可选参数方案，避免触碰既有冻结签名；新增独立方法对既有调用方零破坏（台账 §5.14-2，第三批后置项，Task #63，加法式新增） |
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

### 2.9 阅读器操作（10 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getChapters(String bookUrl)` | bookUrl | `Future<List<BookChapter>>` | 获取章节列表 ⚠️ 双兼容点 |
| `getChapterContent(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取章节正文内容 |
| `getChapterContentRaw(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 获取章节正文（不应用替换规则，用于内容搜索，与 Android replaceEnabled=false 对齐） |
| `getChapterContentFull(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 一次调用获取章节正文（合并 getChapterContent + fetchChapterContent，在线书籍自动网络抓取，始终返回纯正文） |
| `fetchChapterContent(String bookUrl, String chapterUrl, String sourceUrl)` | bookUrl, chapterUrl, sourceUrl | `Future<String>` | 从网络获取章节正文 |
| `updateReadingProgress({required String bookUrl, required int chapterIndex, required int chapterPos})` | bookUrl, chapterIndex, chapterPos | `Future<void>` | 更新阅读进度 |
| `refreshToc(String bookUrl, String sourceUrl)` | bookUrl, sourceUrl | `Future<List<BookChapter>>` | 从网络刷新书籍目录 ⚠️ 双兼容点 |
| `setChineseConvertType(int type)` | type | `Future<void>` | 设置阅读器繁简转换类型并持久化（0=不转换 / 1=繁转简 t2s / 2=简转繁 s2t，对齐 Android `AppConfig.chineseConverterType`，非法值归一为 0） |
| `getChineseConvertType()` | 无 | `Future<int>` | 获取当前繁简转换类型（0/1/2） |
| `toggleSameTitleRemoved(String bookUrl, int chapterIndex, bool enable)` | bookUrl: 书籍 URL；chapterIndex: 章节序号（0 起）；enable: true=去除重复标题 / false=保留原始标题 | `Future<void>` | 章级「删除重复标题」开关，覆盖全局默认（全局默认仍为去除）；状态须持久化（建议 DB，重启后保持）；接线后正文读取按章应用该开关。错误码：Db（章节不存在）/ Internal（书籍不存在）。语义对齐原版章级 opt-out 方向（台账 §5.11-7 删除重复标题正文链路，Task #50，加法式新增） |
| `getSameTitleRemoved(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<bool>` | 权威查询章级开关（caches KV `sameTitleRemoved:{bookUrl}:{chapterIndex}`）；true=去除（默认），false=opt-out。UI 菜单勾选态须以此为准，避免仅 SP 镜像分叉（2026-08-13 加法式新增） |
| `canRemoveSameTitle(String chapterTitle, String rawContent)` | chapterTitle, rawContent | `Future<bool>` | 试算正文 trim 后是否以标题开头（对齐原版「未找到可移除的重复标题」提示条件；2026-08-13 加法式新增） |

> ⚠️ `getChapters` / `refreshToc`：Rust 返回 `ChapterListResponse { total, chapters[] }`，Dart 侧提取 `chapters` 字段。
>
> 繁简转换（Task #100）：配置键 `chineseConverterType`（caches 表 `config:` 前缀，与 Kotlin PreferKey 同名）。正文在净化管线按配置做 t2s/s2t；章节标题在 getChapters/refreshToc 返回前做显示层转换（对齐 Kotlin `BookChapter.getDisplayTitle`，不回写 DB）；内容搜索 raw 路径保持原文。

### 2.10 配置操作（4 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getConfig(String key)` | key | `Future<String?>` | 获取配置值 |
| `setConfig(String key, String value)` | key, value | `Future<void>` | 设置配置值 |
| `deleteConfig(String key)` | key | `Future<void>` | 删除配置 |
| `getAllConfigs()` | 无 | `Future<Map<String, String>>` | 获取所有配置 |

### 2.11 备份操作（3 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `backup(String dirPath)` | dirPath | `Future<String>` | 备份数据，返回备份文件路径。**P2-4（2026-08-13）**：Flutter 在 FFI 写出 JSON 后注入 `appPrefs`（当前 SharedPreferences 快照，已按 restoreIgnore + alwaysIgnore 过滤）；无新 FFI 签名 |
| `restore(String backupPath)` | backupPath | `Future<void>` | 恢复数据。**P2-4（2026-08-13）**：UI 先读 `SettingsService.restoreIgnore`；`localBook` 预过滤备份 JSON 本地书；其余 ignore 键在应用备份内 `appPrefs` 时经 `RestoreIgnorePrefs.keyIsNotIgnore` 跳过（对齐 BackupConfig）；再调用本方法恢复业务表（无需改 FFI 签名） |
| `importOldData(String dirPath)` | dirPath：含旧版备份文件的目录 | `Future<String>`（统计 JSON） | **P2-4（2026-08-13）**：对齐原版 `ImportOldData.importUri`。读取目录下 `myBookShelf.json` / `myBookSource.json` / `myBookReplaceRule.json`（缺文件不致命，计入 `messages`）；书架字段映射（`noteUrl`→`bookUrl`、`bookInfoBean.*` 等）；书源经 `toNewRule`/`toNewUrl`/`toNewUrls`/`uaToHeader` 迁到 3.x 规则结构；替换规则兼容新格式或旧字段（`regex`/`replaceSummary`/`useTo`/`enable`/`serialNumber`）。已存在 `bookUrl` 的书跳过。返回 JSON：`{books, bookSources, replaceRules, messages: string[]}` |

### 2.12 阅读记录（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getReadRecords()` | 无 | `Future<List<ReadRecord>>` | 获取所有阅读记录 |
| `putReadRecord(ReadRecord record)` | record: ReadRecord 对象 | `Future<void>` | 更新阅读记录 |
| `deleteReadRecord(String bookName)` | bookName | `Future<void>` | 删除阅读记录 |
| `clearReadRecords()` | 无 | `Future<void>` | 清空阅读记录 |
| `recordReadingTime(String bookName, int seconds)` | bookName, seconds | `Future<void>` | 记录阅读时长（对齐原版 ReadRecord，非统计子系统） |

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

### 2.16 缓存管理（8 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `getCacheSize()` | 无 | `Future<int>` | 获取缓存大小（字节） |
| `clearCache()` | 无 | `Future<void>` | 清除全部缓存 |
| `clearBookCache(String bookUrl)` | bookUrl | `Future<int>` | 清除指定书籍章节缓存，返回删除行数（对齐 BookHelp.clearCache(book)） |
| `getCacheBookCount()` | 无 | `Future<int>` | 获取缓存书籍数量 |
| `getCacheChapterCount()` | 无 | `Future<int>` | 获取缓存章节数量 |
| `clearCacheBefore(int beforeTimestampMs)` | beforeTimestampMs: 毫秒时间戳 | `Future<void>` | 清除指定时间之前的缓存 |
| `shrinkDatabase()` | 无 | `Future<int>` | 执行 SQLite VACUUM 压缩数据库文件，返回释放的字节数；Rust 侧应在后台线程执行避免阻塞。错误语义：VACUUM 失败（数据库锁/文件损坏）或数据库未初始化 → 返回 0 降级为无操作（不抛异常阻断业务）（台账 §5.13-9，第二批后置项，Task #50，加法式新增） |
| `getCachedChapter(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<String>` | 读取已缓存章节正文（FFI `cacheGetChapter`，F3-10 补登记 §1.7 命名等价） |

### 2.17 WebBook 操作（6 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `webbookSearch(String sourceJson, String query, int page)` | sourceJson, query, page | `Future<String>` | 搜索书籍（书源规则驱动），返回 JSON |
| `webbookInfo(String sourceJson, String bookUrl)` | sourceJson, bookUrl | `Future<String>` | 获取书籍详情 JSON |
| `webbookChapters(String sourceJson, String bookUrl)` | sourceJson, bookUrl | `Future<String>` | 获取章节列表 JSON |
| `webbookContent(String sourceJson, String chapterJson)` | sourceJson, chapterJson | `Future<String>` | 获取章节正文（含 nextContentUrl 分页抓取，见下） |
| `debugBookSourceStream(String sourceUrl, String key)` | sourceUrl（已入库书源 URL）, key（调试关键字） | `Stream<Map<String, dynamic>>` | 流式书源调试（对齐 Kotlin `Debug.startDebug` + `Callback.printLog`）。每条 JSON：`state`（int）/ `msg`（String，含 `[mm:ss.SSS]` 时间戳）；`state=-1` 失败终止、`1000` 成功完成；关键字分流：绝对 URL→详情、`分类名::url`→发现、`++tocUrl`→目录、`--chapterUrl`→正文、否则搜索→详情→目录→正文。流在完成/取消/sink 关闭后结束 |
| `cancelDebugBookSource()` | 无 | `Future<void>` | 取消正在进行的书源调试（对齐 `Debug.cancelDebug`） |

> ℹ️ **nextContentUrl 分页抓取行为（Task #108 缺口①）**：`webbookContent` 签名不变，行为完善——消费 `contentRule.nextContentUrl` 规则（对标 Kotlin `BookContent.analyzeContent` 分页循环）：解析当前页正文后解析下一页 URL 规则，非空且未重复则继续抓取并按页拼接（`\n` 连接，同 Kotlin `contentList.joinToString("\n")`）；每页正文独立走 HtmlFormatter 净化（按该页 URL 绝对化 img）。防死循环保护：已访问 URL 去重（含首章 URL）+ 最大页数上限 99（原版无显式上限，Rust 轨加法式加固）；nextContentUrl 命中下一章 URL 的截断判定因无状态签名不可得 nextChapterUrl，由 URL 去重与页数上限兜底。音视频源不参与分页净化（同单页行为）。

> ℹ️ **流式 Debug.Callback（2026-08-13）**：Rust 侧 `ffi::debug_book_source_stream / debug_book_source_cancel`（实现 `legado-ffi/src/api/source_debug_api.rs`），复用既有 `webbook*` / `exploreFetchBooks` 链路推送逐步日志与字段摘要（`JsSourceDebugFormatter` 风格）。冻结 `webbook*` 契约不变，本组为加法式新增。

### 2.18 发现页操作（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `exploreParseUrl(String exploreUrl)` | exploreUrl | `Future<List<ExploreCategory>>` | 解析 exploreUrl 为分类列表 |
| `exploreFetchBooks(String sourceJson, String url, int page)` | sourceJson, url, page | `Future<List<SearchBook>>` | 抓取发现分类的书籍列表 |

### 2.19 规则解析（1 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseRule(String content, String rule, String ruleType)` | content, rule, ruleType（css/xpath/json/regex 等，rule 无 `@` 前缀时拼为 `@type:rule`） | `Future<String>` | 使用规则解析内容，返回 `{results,count}` JSON |

### 2.20 网络操作（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `httpGet(String url)` | url | `Future<String>` | HTTP GET 请求，返回 JSON `{"status": int, "body": string, "url": string}`（文本 body） |
| `httpPost(String url, String body)` | url, body | `Future<String>` | HTTP POST 请求，返回格式同 httpGet |
| `httpGetBytes(String url, {String headersJson = ''})` | url；headersJson 可选 JSON 对象 | `Future<String>` | HTTP GET 二进制响应，返回 JSON `{"status": int, "bodyBase64": string, "url": string}`（F3-14，经 legado-net 共享客户端） |
| `fetchImageWithDecode(String url, String sourceJson)` | url, sourceJson（BookSource JSON） | `Future<String>` | 图片下载 + imageDecode JS 解密，返回 `{base64,len}` JSON（F3-10 补登记） |
| `setCustomHosts(String hostsJson)` | hostsJson: 域名→IP 映射 JSON 对象字符串（对齐原版存储格式） | `Future<void>` | 设置自定义 hosts 映射，配置后网络层 DNS 解析优先使用该映射（命中域名直连映射 IP，未命中回落系统 DNS）。存储格式对齐原版 `AppConfig.customHosts`：JSON **对象** `{"域名":"IP", "域名":["IP1","IP2"]}`（值支持单 IP 字符串或 IP 数组，实读原版 `AppConfig.hostMap/addressCache` 确认）；空串/空对象=清除映射、恢复系统 DNS。配置需持久化（复用既有配置存储语义，caches 表 `config:` 前缀键 `customHosts`，与既有 `setConfig` 同语义）并即时生效（后续请求使用新映射）。Rust 实现要点：legado-net 经 reqwest `ClientBuilder::resolve` 域名覆盖或自定义 DNS resolver 挂钩（现状无 custom_hosts 钩子，实施时补）。错误码：Internal（hostsJson 非合法 JSON 对象）。差异注明：原版非法输入即清除；本契约改为拒绝保存（更防误操作，Task #76 Med2）。既有 `httpGet` / `httpPost` 签名保持不变，本方法为加法式新增（台账 §5.13-1，第四批后置项，Task #72） |

### 2.21 JS 引擎（2 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `evalJs(String script)` | script | `Future<String>` | 执行 JS 脚本 |
| `getJsEngineVersion()` | 无 | `Future<String>` | 获取 JS 引擎版本 |

### 2.22 服务器管理（5 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `startServer({int port = 1122})` | port(默认1122) | `Future<void>` | 启动服务器 |
| `stopServer()` | 无 | `Future<void>` | 停止服务器 |
| `getServerStatus()` | 无 | `Future<String>` | 获取服务器状态 |
| `setServerPort(int port)` | port | `Future<void>` | 设置服务器端口 |
| `setMcpPort(int port)` | port: 独立 MCP 服务端口（合法区间 1024–65530，对齐原版 NumberPicker 取值；缺省语义默认 1236，对齐原版 `AppConfig.mcpPort` 默认值，未配置时 UI 对话框预填 1236 落实该缺省语义）；port ≤ 0 = 停止独立 MCP 服务 | `Future<void>` | 启动/停止独立 MCP 服务端口（**对齐原版独立端口方案**，见下方决策说明）。独立端口启动后提供与既有 Web 端口挂载的 `/mcp/tools`（GET）/ `/mcp/call`（POST）等价能力（同一套 MCP 工具与调用入口，零新增工具）；**并存策略**：独立端口开启时保持 Web 端口 `/mcp/*` 挂载不变（兼容既有消费方），二者共用同一 AppState/工具实现。端口配置需持久化（caches 表 `config:` 前缀键 `mcpPort`，与既有配置语义一致）。**F5（2026-08-13）**：监听 `0.0.0.0`（LAN 可达，对齐原版）；启动前置要求 `config:jsSourceApiToken` 非空（否则 Internal）；独立端口 `/mcp/*` 请求须带请求头 `X-Legado-Token`（大小写不敏感）与配置 token 字节级相等，否则 401。错误码：Internal（端口绑定失败 / 越界 / token 未设置）。既有 `startServer` / `stopServer` / `getServerStatus` / `setServerPort` 签名保持不变，本方法为加法式新增（台账 §5.13-6，第四批后置项，Task #72） |

> ℹ️ **mcpPort 决策说明（台账 §5.13-6，Task #72；F5 补齐）**：调研原版 `McpService.kt`——其为**独立前台服务**，ktor CIO embeddedServer 绑定 **0.0.0.0** 独立端口（`AppConfig.mcpPort` 默认 1236，合法区间 1024..65530），与 Web 服务完全分离；启动前置条件为 `jsSourceApiToken` 非空；请求经 `X-Legado-Token` 鉴权 + Host/Origin 白名单。本轨：`setMcpPort` 独立端口 + REST `/mcp/tools`/`/mcp/call`；**F5 已对齐** LAN 绑定、`jsSourceApiToken` 启动前置与 `X-Legado-Token` 校验。差异：原版另有 Host/Origin 白名单（本轨暂以 token 为访问控制主防线）；原版越界回落 1236，本契约改为报错（UI 内联区间校验前置拦截）。

### 2.23 书籍格式解析（3 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `parseTxt(String filePath)` | filePath | `Future<List<BookChapter>>` | 解析 TXT 文件 |
| `parseEpub(String filePath)` | filePath | `Future<List<BookChapter>>` | 解析 EPUB 文件 |
| `exportBook(String bookUrl, String format, String outDir)` | bookUrl, format, outDir | `Future<String>` | 导出书籍（将章节内容写入文件） |

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
| `audioSpeak({required String text, required String engineUrl, double speed = 1.0, double pitch = 1.0, double volume = 1.0, String? voiceName})` | text, engineUrl, speed, pitch, volume, voiceName | `Future<void>` | TTS 朗读（文本书朗读路径；与音频书流媒体互斥） |
| `getAudioChapterMedia(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<Map<String, dynamic>>` | **音频书章节取址**（对齐原版 `AudioPlay` → `WebBook.getContent`）。Rust FFI：`audioGetChapterMedia` → JSON。返回字段（camelCase）：`chapterIndex` / `title` / **`mediaUrl`**（可播地址，即 getContent 正文 trim）/ `url`（章节页 URL，兼容旧字段）/ `resourceUrl` / `isVolume`（卷章无媒体，调用方应跳过）/ `fromCache` / `lyric` / `sourceUrl`。流程：查章 → 卷章短路 → DB 章节内容缓存命中则直接作 `mediaUrl` → 否则按 `book.origin` 书源 `getContent`（**正文规则为空时回退章节 URL**，对齐 Kotlin）→ 写入缓存。空 `mediaUrl` 且非卷章表示取址失败。错误码：章节/书籍不存在 → Database；书源网络/解析失败向上抛。与 TTS `audioSpeak` 分流：仅 `BookType.audio` 走本接口流媒体 |
| `getAudioProgress(String bookUrl, int chapterIndex)` | bookUrl, chapterIndex | `Future<Map<String, dynamic>?>` | 获取音频播放进度 |
| `saveAudioProgress(String bookUrl, int chapterIndex, int positionMs)` | bookUrl, chapterIndex, positionMs | `Future<void>` | 保存音频播放进度 |

### 2.28 WebDAV 云同步（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `webdavListDir(String configJson, String path)` | configJson, path | `Future<String>` | WebDAV 列出远程目录；返回 `Vec<WebDavFileInfo>` JSON：`name` / `path` / `size` / `last_modified` / `etag` / `is_dir` |
| `webdavUpload(String configJson, String path, String data)` | configJson, path, data | `Future<void>` | WebDAV 上传文件 |
| `webdavDownload(String configJson, String path)` | configJson, path | `Future<String>` | WebDAV 下载文件（**仅 UTF-8 文本**；二进制请用 `webdavDownloadFile`） |
| `webdavDelete(String configJson, String path)` | configJson, path | `Future<void>` | WebDAV 删除远程文件 |
| `webdavFullSync(String configJson, String localBooks, String localSources)` | configJson, localBooks, localSources | `Future<String>` | WebDAV 全量同步 |
| `webdavUploadFile(String configJson, String path, String localFilePath)` | configJson（与既有 `webdavUpload` 相同，WebDavConfig JSON）；path: 远程目标路径；localFilePath: 本地文件绝对路径 | `Future<void>` | WebDAV 从本地文件路径读取并上传（大文件场景，如书籍上传至远程），区别于既有 `webdavUpload` 的 String data 直传；既有 `webdavUpload` 签名保持不变。错误码：Io（文件不存在/读取失败）/ Net（上传失败）/ Internal（配置解析失败）（台账 §5.11-1 上传至远程，Task #50，加法式新增） |
| `webdavDownloadFile(String configJson, String path, String localFilePath)` | configJson（WebDavConfig JSON，字段 `url`/`username`/`password`/`remote_dir`）；path: 相对 `remote_dir` 的远程路径；localFilePath: 本地落盘绝对路径 | `Future<void>` | WebDAV 下载**二进制**到本地文件（对齐远程书库 `RemoteBookActivity` 导入；镜像 `webdavUploadFile`）。父目录不存在时创建；错误码：Io（写盘失败）/ Net（下载失败）/ Internal（配置解析失败）。既有 `webdavDownload` 签名保持不变（加法式新增，2026-08-12 P1-5） |

> **远程书库服务器列表（非 FFI）**：对齐原版 `servers` 表 + `AppConfig.remoteServerId`。Flutter 侧以 `SettingsService` 持久化 `remote_servers`（JSON 数组：`id`/`name`/`url`/`username`/`password`）与 `remote_server_id`（`-1` = 默认 WebDAV，即同步设置中的账号，根目录相对 path 为 `books/`）。目录浏览复用 `webdavListDir`；导入 = `webdavDownloadFile` → `importLocalBook`。

### 2.29 下载管理器（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `downloadAddTask({required String bookUrl, required String chapterUrl, required String chapterTitle, required int chapterIndex, int priority = 0})` | bookUrl, chapterUrl, chapterTitle, chapterIndex, priority | `Future<String>` | 添加下载任务，返回任务 ID（**字符串**，opaque 标识符，非数字序号） |
| `downloadGetStats()` | 无 | `Future<String>` | 获取下载统计信息 JSON |
| `downloadListByBook(String bookUrl)` | bookUrl | `Future<String>` | 获取指定书籍的下载任务 JSON |
| `downloadPauseAll()` | 无 | `Future<void>` | 暂停所有下载 |
| `downloadResumeAll()` | 无 | `Future<void>` | 恢复所有下载 |
| `downloadRemoveTask(String taskId)` | taskId（字符串 opaque ID） | `Future<void>` | 移除下载任务 |
| `downloadUpdateProgress(String taskId, double progress)` | taskId（字符串 opaque ID）, progress | `Future<void>` | 更新下载进度 |

### 2.30 段评（3 个方法，书源 ruleReview）

> **口径**：`reviewGetSummary` / `reviewGetDetail` / `reviewGetReplies` 为书源 `ruleReview` 路径（对齐原版 ReadBook / ReviewDetailDialog / ReviewController）。  
> **已移除**（F3-15）：本地库 CRUD（`reviewGetByChapter` / `reviewAdd` / `reviewDelete` / `reviewLike`）——原版 Android 无本地段评表/CRUD，属重构偏离创意，已从 FFI 与 BookApi 删除。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `reviewGetSummary(String sourceJson, String requestJson)` | sourceJson, requestJson | `Future<String>` | 段评摘要（对标 `ReadBookActivity.loadReviewSummary*` + `ReviewRuleParser.parseSummary` / JS `getReviewSummary`）。返回 `{"counts":{"1":5},"keys":{"1":"paraData"}}`（键为段落索引字符串；仅 count>0 的段）。requestJson：`chapterUrl`；可选 `book`/`chapter` JSON。规则缺失/未启用返回空 maps（非异常） |
| `reviewGetDetail(String sourceJson, String requestJson, int page)` | sourceJson, requestJson, page | `Future<String>` | 段评详情分页（对标 `ReviewDetailDialog.loadDetailPage` + `parseDetailPage` / JS `getReviewDetail`）。返回 `{"items":[DetailItem...],"nextPageUrl":String?,"hasReplyUrl":bool}`。requestJson：`paraIndex`/`paraData`/`chapterUrl`；可选 `detailUrl`（翻页直连）、`book`/`chapter`。条目字段同 `reviewGetReplies`，另含 likeCount/replyCount/replies |
| `reviewGetReplies(String sourceJson, String requestJson, int page)` | sourceJson, requestJson, page | `Future<String>` | 按需加载段评回复（上游 #519），返回 `{"items": [...], "nextPageUrl": String?}` 对象包装（含分页 URL，非裸数组）；requestJson 支持 reviewId/paraIndex/paraData/chapterUrl/replyUrl 字段；回复条目字段：id/avatar/name/badges/content/imageUrl/audioUrl/time |

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
| `autoTaskExecuteWithId({required String protocolJson, required String taskId})` | protocolJson, taskId（自动任务规则 ID，字符串 UUID/主键，非下载 taskId） | `Future<Map<String, dynamic>>` | 带任务 ID 执行任务协议 |
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

### 2.35 RSS 已读记录（7 个方法）

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `rssMarkRead(String origin, String title, {String? link})` | origin, title, link(可选) | `Future<void>` | 标记 RSS 文章为已读 |
| `rssIsRead(String link)` | link | `Future<bool>` | 判断文章是否已读（按 link 匹配） |
| `rssIsReadByTitle(String origin, String title)` | origin, title | `Future<bool>` | 判断文章是否已读（按 origin+title 匹配） |
| `rssClearReadRecords()` | 无 | `Future<void>` | 清空所有已读记录 |
| `rssReadRecordCount()` | 无 | `Future<int>` | 获取已读记录总数 |
| `rssListReadRecords({int? limit})` | limit(可选，默认100) | `Future<List<RssReadRecordRow>>` | 获取已读记录列表（按 readTime 降序） |
| `rssListReadRecordsByOrigin(String origin, {int? limit})` | origin, limit(可选，默认100) | `Future<List<RssReadRecordRow>>` | 按 RSS 源 origin 获取已读记录（对齐原版 `getRecordsByOrigin`，F3-17） |

### 2.36 正文高亮（highlight FFI）（11 个方法）

> 对齐上游 `BookHighlight` / `HighlightRule` 实体与 DAO（DB v96-v99）。
> JSON 字段名对齐 Room 列名（camelCase）：BookHighlight 含 `time` / `bookUrl` / `chapterUrl` / `bookName` / `bookAuthor` / `chapterIndex` / `chapterPos` / `chapterPosEnd` / `layoutTitleLength` / `chapterName` / `bookText` / `style` / `note`；HighlightRule 含 `id` / `name` / `pattern` / `isRegex` / `scope` / `isEnabled` / `style` / `sortOrder` / `timeoutMillisecond` / `applyToTitle`。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `highlightAdd({required String highlightJson})` | BookHighlight JSON（time=0 时自动分配） | `Future<int>` | 新增/更新高亮记录，返回 time 主键 |
| `highlightDelete({required int time})` | time | `Future<bool>` | 按主键删除高亮记录，返回是否实际删除 |
| `highlightDeleteByBook({required String bookUrl})` | bookUrl | `Future<int>` | 按书籍删除全部高亮，返回删除数量 |
| `highlightListByBook({required String bookUrl})` | bookUrl | `Future<String>` | 按书籍获取高亮列表（BookHighlight 数组 JSON） |
| `highlightListByChapter({required String bookUrl, required int chapterIndex})` | bookUrl, chapterIndex | `Future<String>` | 按书籍+章节获取高亮列表（BookHighlight 数组 JSON） |
| `highlightSearch({required String keyword})` | keyword | `Future<String>` | 全局关键词搜索高亮（bookText/note，BookHighlight 数组 JSON） |
| `highlightListAll()` | 无 | `Future<String>` | 获取所有高亮记录（BookHighlight 数组 JSON） |
| `highlightRuleList()` | 无 | `Future<String>` | 获取所有高亮规则（按 sortOrder 升序，HighlightRule 数组 JSON） |
| `highlightRuleSave({required String ruleJson})` | HighlightRule JSON（id=0 时自增新增） | `Future<int>` | 保存高亮规则，返回规则 ID |
| `highlightRuleDelete({required int id})` | id | `Future<bool>` | 按 ID 删除高亮规则，返回是否实际删除 |
| `highlightRuleFindEnabled({required String bookName, required String origin})` | bookName, origin | `Future<String>` | 按书籍查找启用的高亮规则（scope 匹配书名或 origin，HighlightRule 数组 JSON） |

### 2.37 JS 单文件书源配置（JsSourceConfig 对齐）（3 个方法）

> 对齐 Kotlin `JsSourceConfig.kt`：extract 配置提取 / stampLastUpdateTime 时间写回（#208/#515）/ 语法检查（#479）。
> extract 需 QuickJS 构建（`--features quickjs`），非 quickjs 构建返回错误；语法检查非 quickjs 构建降级为括号平衡基础检查。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `jsSourceExtract({required String content})` | content（完整 JS 书源脚本） | `Future<String>` | 执行脚本提取顶层 config/source 配置（BookSource JSON，mainJs 回填完整脚本）；缺必备函数/配对校验失败报错 |
| `jsSourceSyntaxCheck({required String content})` | content（待检查 JS 脚本） | `Future<String>` | 语法检查（SyntaxCheckResult JSON：`valid` / `message` / `line`）；quickjs 下只编译不执行 |
| `jsSourceStampLastUpdateTime({required String content, required int stamp})` | content（JS 书源脚本）, stamp（新时间戳毫秒） | `Future<String>` | 写回顶层 config/source 对象的 lastUpdateTime（仅替换数字字面量或 Date.now()）；无可替换位置返回空字符串 |

### 2.38 应用日志（app_log FFI，Task #79）（5 个方法）

> 对齐 Kotlin `AppLog.kt` / `AppLogDialog.kt`（旧欠账 + 上游 #512/#524/#543）。
> Rust 侧进程级环形缓冲（每级上限 500 条，最新在前），三级独立：`message` / `crash` / `http`（大小写不敏感）。
> 日志条目 JSON 字段：`timestamp`（毫秒）/ `level` / `message`（对齐 Kotlin `Triple<Long, String, Throwable?>`）。
> 导出文本格式 `yyyy-MM-dd HH:mm:ss.SSS [LEVEL] message`，时间升序，超 64_000 字符按字符边界截断（对齐 #543 `MAX_SHARE_TEXT`）。
> 纯内存缓冲、无 DB 依赖，任意时机可调用；日志页面 UI 由 UI 轨后续接入（与 Flutter 现有 `CrashLogService` 文件型崩溃日志互补，不重复）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `appLogPush({required String level, required String message})` | level（message/crash/http）, message | `Future<void>` | 写入一条日志；非法级别抛 BridgeError，空消息忽略（对齐 Kotlin `put` 的 null 短路） |
| `appLogList({required String level})` | level | `Future<String>` | 获取指定级别日志列表（裸 JSON Array，最新在前，对齐 §1.4 铁律） |
| `appLogClear({required String level})` | level | `Future<void>` | 清空指定级别日志 |
| `appLogClearAll()` | 无 | `Future<void>` | 清空全部级别日志（对齐 #543 清空确认后的 AppLog.clear + HttpLogStore.clear） |
| `appLogExport()` | 无 | `Future<String>` | 导出全部日志为格式化文本（时间升序，64_000 字符截断，对齐 #543） |

### 2.39 规则订阅（rule_sub FFI，Task #89）（7 个方法）

> 对齐 Kotlin `RuleSub.kt` 实体与 `RuleSubActivity.kt`（列表 CRUD / 拖拽排序 / 自动更新 / 静默更新 / 更新间隔）。
> DB v100（Rust 轨自有扩展）：rule_subs 表补全 Kotlin RuleSub 字段 `customOrder` / `autoUpdate` / `updateInterval` /
> `silentUpdate` / `js` / `showRule` / `sourceUrl`（Migration99To100，幂等补列，不动 v95-v99 高亮体系迁移）。
> RuleSub JSON 字段：`id` / `url` / `name` / `sub_type`（bookSource/replaceRule/rssSource）/ `last_update` / `version` /
> `is_enabled` / `created_at` / `customOrder` / `autoUpdate` / `updateInterval` / `silentUpdate` / `js` / `showRule` / `sourceUrl`（新增 7 字段对齐 Kotlin 驼峰命名）。
> 检查/应用更新委托 `legado-net` rule_update_client（should_update / fetch_subscription / merge_subscription）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `ruleSubList()` | 无 | `Future<String>` | 获取订阅列表（RuleSub 数组 JSON，按 customOrder 排序） |
| `ruleSubSave({required String subJson})` | RuleSub JSON | `Future<bool>` | 新增/更新订阅（id>0 且存在则更新，否则新增） |
| `ruleSubDelete({required int id})` | id | `Future<bool>` | 删除订阅，返回是否实际删除 |
| `ruleSubSetEnabled({required int id, required bool enabled})` | id, enabled | `Future<bool>` | 切换启用状态，返回记录是否存在 |
| `ruleSubUpdateOrder({required String idsJson})` | idsJson（新顺序 ID 数组 JSON） | `Future<bool>` | 拖拽排序：按索引重写 customOrder（0 起） |
| `ruleSubCheckUpdate({required int id})` | id | `Future<String>` | 检查更新（检查结果 JSON：`id` / `url` / `name` / `dueForUpdate`（should_update 间隔判定）/ `hasUpdate`（远程版本对比）/ `remoteVersion` / `error`） |
| `ruleSubApplyUpdate({required int id})` | id | `Future<String>` | 应用更新（应用结果 JSON：`id` / `url` / `success` / `itemsAdded` / `itemsUpdated` / `itemsRemoved` / `totalItems` / `error`；合并后回写版本号与最后更新时间） |

### 2.40 本地 TXT 全文搜索（txt_search FFI，Task #98 缺口#4）（4 个方法）

> 对齐既有 C ABI 4 函数（`ffi_txt_search` / `ffi_txt_search_regex` / `ffi_txt_search_in_chapter` / `ffi_txt_search_count`），
> 本小节为其 frb 主链路暴露（包装 `legado-book::txt_search::TxtSearch` 引擎），供 Flutter 侧本地 TXT 书内搜索调用。
> 返回裸 JSON Array（遵守 §1.4 铁律），每项字段（snake_case）：`chapter_index` / `chapter_title` / `char_offset` /
> `matched_text` / `context` / `context_match_start` / `context_match_end`（TxtSearchResult 序列化）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `txtSearch(String path, String query, {bool caseSensitive = false, int maxResults = 500})` | path: TXT 文件路径，query: 关键词 | `Future<List<Map<String, dynamic>>>` | 纯文本全文搜索（章节感知 + 上下文摘要） |
| `txtSearchRegex(String path, String pattern, {bool caseSensitive = false, int maxResults = 500})` | path, pattern: 正则表达式 | `Future<List<Map<String, dynamic>>>` | 正则全文搜索，返回格式同上 |
| `txtSearchInChapter(String path, String query, int chapterIndex, {bool caseSensitive = false, int maxResults = 50})` | path, query, chapterIndex（0 起） | `Future<List<Map<String, dynamic>>>` | 指定章节内搜索，返回格式同上 |
| `txtSearchCount(String path, String query, {bool caseSensitive = false})` | path, query | `Future<int>` | 匹配总数计数（不返回完整结果，供 UI 显示） |

### 2.41 契约外已实现 FFI 补登记（2026-08-06 审计，5 个）

> 以下函数已在 `rust/legado-ffi/src/ffi.rs` 实现并生成 Dart 绑定（`ffi.dart`），但此前未登记本契约（违反 §1.2「新增 API 须同步更新文档」），本节为补登记（承接 REMAINING_PLAN §4.2.2 P1-3）。其中多数尚未封装进 `BookApi` 抽象层，UI 封装计划见 §3「待 UI 封装清单」。
>
> **注（2026-08-07，Task #139）**：原 QUIC 系列 8 个函数（quicCreateClient / quicGet / quicPost / quicPerformanceTest / quicIsInitialized / quicCleanup / netSetQuicEnabled / netIsQuicEnabled）属原版不存在的新增能力，按「项目目标是纯重构」的用户决策已整体移除，不再作为契约项。

**其他（5 个）**

| 函数 | 所属模块 | 说明 |
|------|----------|------|
| `backupList` | 备份操作（§2.11 扩展） | 列出备份文件——✅ 已封装 `BookApi.backupList`（F3-20） |
| `cacheGetChapter` | 缓存管理（§2.16 扩展） | 获取已缓存章节内容（离线缓存 UI 批次依赖）——✅ 已封装接通（本次评审修复提交，`RustApi.getCachedChapter` 封装，书架菜单缓存导出） |
| `bookGroupSetShow` | 书籍分组（§2.14 扩展） | 设置分组显示状态——✅ 已封装 `BookApi.bookGroupSetShow`（F3-20） |
| `httpTtsSetEnabled` | HTTP TTS（§2.25 扩展） | 启用/禁用 HTTP TTS 配置——✅ 已封装 `BookApi.httpTtsSetEnabled`（F3-20） |
| `dictLookup` | 词典（§3 需求 4） | 词典释义查询——✅ 已封装 `BookApi.dictLookup`（F3-10 补登记） |

### 2.42 TTS 真实合成管线（Task #113 批次 2 缺口②，2 个方法）

> 对齐 Kotlin 原版 `HttpReadAloudService.getSpeakStream` + `AnalyzeUrl(speakText/speakSpeed)` 模型：
> url 模板占位符替换 → HTTP 请求获取音频二进制 → Content-Type 校验（`application/json` / `text/*` 视为服务器报错）→
> 以「模板+文本+语速」MD5 命名缓存到本地（命中直接返回路径，避免重复请求）。
> Flutter 侧 `audioSpeak`（§2.26）当前为 `http.get` 探活 fallback，UI 轨后续改接 `ttsSpeak` 真实管线。
>
> **占位符约定**：`{{speakText}}` / `{{text}}`（朗读文本，URL 编码后替换）、`{{speakSpeed}}` / `{{speed}}`（语速）。
> **缓存目录**：默认为系统临时目录下 `legado_tts_cache`，可通过 `ttsSetCacheDir` 覆盖（建议 UI 轨初始化时传入应用缓存目录）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `ttsSpeak({required String text, required String engineUrl, double speed = 1.0})` | text: 朗读文本，engineUrl: 引擎 URL 模板，speed: 语速 | `Future<Map<String, dynamic>>` | TTS 真实合成。返回字段（camelCase）：`audioPath: String`（本地音频文件绝对路径）/ `fromCache: bool`（是否缓存命中）/ `contentType: String`（音频 MIME 类型）。服务器返回 json/text 时以响应体文本抛出 BridgeError |
| `ttsSetCacheDir(String path)` | path: 缓存目录绝对路径 | `Future<bool>` | 设置 TTS 音频缓存目录（全局生效） |

### 2.43 缓存写/购买/批量下载/导出扩展（Task #136 R5+R6+R7+R8，7 个方法）

> Task #136 合并批次，均为**加法式**新增（不改既有签名/行为）。仅走 frb 主链路（`ffi.rs`），
> 旧式 C ABI（`bridge.rs`）已按 Task #136 R12 冻结新增并标注 DEPRECATED，故本批不在 C ABI 面暴露。

#### 2.43.1 R5 缓存写（1 个方法）

> 缓存系 FFI 此前仅读侧（§2.16 + §2.41 `cacheGetChapter`），写侧补齐：
> 复用 `legado-db` `CacheBookRepository.insert`（INSERT OR REPLACE），供阅读器「编辑内容/反转」闭环回写章节缓存。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `saveChapterContent({required String bookUrl, required int chapterIndex, required String title, required String content, String chapterUrl = ''})` | bookUrl, chapterIndex（0 起）, title（空串=从 DB 章节表回填）, content（正文原文，不做净化）, chapterUrl（空串=从 DB 章节表回填） | `Future<bool>` | 写入/覆盖单章缓存（cached_chapters 表），cached_at=当前毫秒、size_bytes=content 字节数；写入后可经 `cacheGetChapter` 读回一致 |

#### 2.43.2 R6 章节购买（1 个方法）

> 对齐 Kotlin `ReadBookActivity.payAction`：取书源 `ruleContent.payAction`（js 或含 `{{js}}` 的 url，空则报错 "no pay action"）→
> 复用登录 V2 JS 执行基础设施（书源 URL 分桶引擎池 + `eval_with_bindings`）执行，注入绑定 `baseUrl`=章节 url、
> `title`=章节标题、`book`/`chapter`=实体 JSON 对象、`source`=书源对象（Kotlin 另注入 java/result/src，Rust `java` 命名空间已全局注册，result/src 原版即为 null）。
> **结果语义（对照 Kotlin onSuccess）**：返回绝对 URL → UI 打开支付页 WebView；返回 "true" → 购买成功（Kotlin 随后清当前章缓存并刷新目录，UI 轨自行对应）；其他 → 原样回传。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `chapterPayAction({required String bookUrl, required int chapterIndex})` | bookUrl（本地书短路返回 kind=none，对齐 Kotlin isLocal 短路）, chapterIndex | `Future<String>` | 结果 JSON（camelCase）：`{"kind": "url"/"success"/"none", "value": "<JS 返回原文>"}`；kind=success 时 Rust 侧已清当前章正文缓存；需 quickjs 构建，否则返回 JsEngine 错误 |

#### 2.43.3 R7 缓存批量下载（4 个方法）

> 对标 Kotlin `CacheActivity` + `CacheBook` 批量缓存下载。运行态为进程内内存表（独立 worker 线程 + `AtomicBool` 取消令牌，
> worker 不用 tokio spawn 因正文抓取链路含 `block_on` 不可嵌套；取消对齐 §2.3 `cancelCheckSources` 的书源校验流机制）；
> **进度快照落库**至 `caches` 表（键前缀 `cacheDownloadTask:` / 索引 `cacheDownloadTaskIndex`，重启后恢复进行中任务并续跑；
> 终态任务亦可经 `cacheDownloadProgress`/`List` 回读）。逐章复用正文抓取链路 `get_chapter_content_full`
> （缓存命中免网络 → 网络抓取 → 缓存写入；本地书走解析器 + R5 写缓存），失败章计入 failed 并继续。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `cacheDownloadStart({required String bookUrl, required int startChapter, required int endChapter})` | bookUrl, startChapter/endChapter（章节 index，闭区间；越界自动收敛） | `Future<String>` | 创建并后台启动批量下载任务，返回任务 ID（字符串）；同一本书已有进行中任务时复用返回既有 ID |
| `cacheDownloadProgress(String taskId)` | taskId | `Future<String>` | 进度 JSON（camelCase）：`taskId`/`bookUrl`/`status`（running/completed/cancelled/failed/notFound）/`total`/`completed`/`failed` |
| `cacheDownloadCancel(String taskId)` | taskId | `Future<bool>` | 取消进行中任务（当前章完成后停止），返回任务是否存在 |
| `cacheDownloadList()` | 无 | `Future<String>` | 全部任务进度 JSON 数组（字段同上） |

#### 2.43.4 R8 书籍导出参数扩展（1 个方法）

> 加法式扩展：既有 `bookExport`（§2.31）签名与行为不变（缺省=现行为）。新方法以 `optionsJson` 透传参数，
> 对照 Kotlin `ExportBookService`（`AppConfig.exportCharset` 编码 / 章节范围 / `getExportFileName` 文件名规则）：
> - `encoding`：UTF-8（缺省）/ GB2312 / GBK / GB18030 / UTF-16 / UTF-16LE / ASCII（对齐 Kotlin `AppConst.charsets`），仅作用于 TXT；不可映射字符以 `?` 替代
> - `startChapter` / `endChapter`：章节 index 闭区间，缺省/`-1` = 不限
> - `fileNameTemplate`：`{name}` / `{author}` 占位符模板，缺省 = 现行为 `{书名}.{扩展名}`

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `bookExportWithOptions({required String bookUrl, required String format, required bool includeToc, String optionsJson = ''})` | bookUrl, format（txt/epub/html/pdf）, includeToc, optionsJson（`{"encoding":"GBK","startChapter":0,"endChapter":9,"fileNameTemplate":"{name} 作者：{author}"}`，空串=全缺省） | `Future<String>` | ExportResult JSON（同 §2.31 `bookExport` 返回结构） |

#### 2.43.5 目录页缓存态查询（Task #22，1 个方法）

> [UI-fix v2.0.6 | 2026-08-08] 加法式新增（不改既有签名/行为），仅走 frb 主链路（`ffi.rs`）。
> 目录页云图标缓存态数据源：复用 `legado-db` `CacheBookRepository.get_by_book`（按
> `book_url` 复合键查询，不串本），仅提取 `chapter_url`。对齐 Kotlin
> `item_chapter_list` 的 `iv_toc_cache`（已缓存实心云 / 未缓存空心云）。

| 方法 | 入参 | 返回 | 说明 |
|------|------|------|------|
| `cacheListCachedChapterUrls({required String bookUrl})` | bookUrl | `Future<String>` | 已缓存 `chapter_url` 的 JSON 字符串数组（`["url1","url2",...]`，按 chapter_index 升序、空 url 过滤）；Dart 侧 `RustApi.listCachedChapterUrls` 解析为 `List<String>` 供目录页渲染云图标 |

---

### 2.44 数据层实现备注（不涉契约签名）

> 本节登记数据层内部实现变更预告，均不改变任何契约签名，仅供 Rust 轨实施与双轨知会。
> 本节不含方法，不计入模块数与附录统计（模块仍为 43 个，§2.1–§2.43）。
>
> ℹ️ **BookRepository::insert 级联删除隐患（第三批后置项，Task #63）**：`BookRepository::insert` 当前走
> INSERT OR REPLACE，存在外键级联删除隐患；将在本批改为 upsert 链路（内部实现变更，不涉契约签名，不改任何 FFI 行为）。
>
> ℹ️ **瞬态 HTML/下载字段（F3-8，2026-08-14）**：`books` 表 `infoHtml` / `tocHtml` / `downloadUrls` 对齐原版 Room 列，存书源详情/目录页原始 HTML 与下载地址缓存，**非用户持久配置**；换源/清缓存时可被覆盖或清空，UI 不应当作权威书元数据。

---

## 3. UI 轨需求登记区

> UI 轨需要新数据时，在此登记需求，Rust 轨按契约实现。流程见 [TWO_TRACK_DEV_SPEC.md § 4.3](TWO_TRACK_DEV_SPEC.md)。

| 方法名 | 入参 | 期望返回 | 登记日期 | 状态 |
|--------|------|----------|----------|------|
| `getSearchHistory`（字段修复） | 不变 | `List<SearchKeyword>` 序列化字段对齐 Dart 模型：`word` / `usage` / `lastUseTime` | 2026-08-01 | ✅ 已完成 |
| `searchHistoryByPrefix`（新增） | `String prefix, {int limit = 20}` | `Future<List<String>>`（前缀匹配的历史关键词，对标 Android `searchKeywordDao.flowSearch`） | 2026-08-01 | ✅ 已完成 |
| `importBooks`（新增） | `String jsonArray` | `Future<int>`（批量导入书籍，返回成功导入数量，用于 WebDAV 书架批量回写） | 2026-08-02 | ✅ 已完成 |
| `searchMultiStream`（新增） | `String query, {List<String>? sourceUrls}` | `Stream<Map<String, dynamic>>`（多源渐进式搜索，逐书源推送批次，用于 Phase 3.3 渐进搜索） | 2026-08-02 | ✅ 已完成 |
| `searchCover`（新增） | `String bookName` | `Future<List<Map<String, dynamic>>>`（网络封面候选列表，字段建议 `url` / `width` / `height`，用于 Phase 6 P1 `change_cover_screen` 封面搜索） | 2026-08-01 | ✅ 已完成 |
| `dictLookup`（新增） | `String word` | `Future<Map<String, dynamic>>`（词典释义，字段对齐 Dart `DictEntry`：`word` / `phonetic` / `definitions[]`，用于 `dict_screen` 真实词典查询；Task #137 起数据源由静态占位表改为 dict_rules 字典规则引擎，见需求 4 补记） | 2026-08-01 | ✅ 已完成 |
| `highlight*` / `highlightRule*`（新增） | 见 §2.36 方法清单 | 高亮记录 CRUD + 高亮规则 CRUD（对齐上游 DB v96-v99，用于阅读器正文高亮一期） | 2026-08-04 | ✅ 已完成 |
| `reviewGetReplies`（新增） | `String sourceJson, String requestJson, int page` | `Future<String>`（段评回复按需加载，对标 Android `ReviewDetailDialog.loadReplies` + `ReviewRuleParser.parseReplyPage`，上游 #519；返回 `{items, nextPageUrl}` 对象包装，Flutter 段评弹窗回复 UI 由 UI 轨后续接入） | 2026-08-04 | ✅ 已完成 |
| `reviewGetSummary`（新增，P2-9） | `String sourceJson, String requestJson` | `Future<String>`（段评摘要，对标 `loadReviewSummary`+`parseSummary`；返回 `{counts, keys}`） | 2026-08-13 | ✅ 已冻结 |
| `reviewGetDetail`（新增，P2-9） | `String sourceJson, String requestJson, int page` | `Future<String>`（段评详情分页，对标 `ReviewDetailDialog`+`parseDetailPage`；返回 `{items, nextPageUrl, hasReplyUrl}`） | 2026-08-13 | ✅ 已冻结 |
| `appLog*`（新增，Task #79） | 见 §2.38 方法清单 | 应用日志体系：Rust 侧三级环形缓冲（message/crash/http）+ 写入/查询/清空/导出 FFI（对齐 Kotlin AppLog 旧欠账 + 上游 #543 导出 64K 截断），日志页面 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `checkSource` / `checkSourcesStream` / `cancelCheckSources`（新增，Task #87） | 见 §2.3 方法清单 | 书源校验 FFI 暴露：单本四步校验（CheckResult JSON）+ 批量串行 Stream 进度回推（CheckProgress JSON）+ 取消（包装 legado-net SourceChecker，对齐 Kotlin CheckSource 与 server /sources/check），校验页面 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `ruleSub*`（新增，Task #89） | 见 §2.39 方法清单 | 规则订阅 FFI 暴露：列表/保存/删除/启用切换/拖拽排序 + 检查更新/应用更新（DB v100 补全 Kotlin RuleSub 7 字段，委托 legado-net rule_update_client），订阅管理 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `verificationRequestStream` / `submitVerificationResult` / `cancelVerificationRequest`（新增，Task #90） | 见 §2.3 方法清单 | 验证码交互通道：JS 钩子（getVerificationCode/startBrowserAwait，对齐 Kotlin JsExtensions）经请求管理器挂起等待 → FFI 事件流推送请求（含航班去重/回放/5 分钟超时）→ UI 提交/取消唤醒；useBrowser 降级为图片验证码（桌面无 WebView），验证码弹窗 UI 由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `txtSearch` / `txtSearchRegex` / `txtSearchInChapter` / `txtSearchCount`（新增，Task #98 缺口#4） | 见 §2.40 方法清单 | 本地 TXT 全文搜索接入 frb 主链路：既有 C ABI 4 函数的 frb 暴露（包装 legado-book TxtSearch 引擎，纯文本/正则/章节内搜索 + 匹配计数，返回裸 JSON Array），供搜索页内“搜本地书正文”场景调用，UI 由 UI 轨后续接入 | 2026-08-05 | ✅ 已完成 |
| `setChineseConvertType` / `getChineseConvertType`（新增，Task #100） | 见 §2.9 方法清单 | 繁简转换 FFI 透传：reader.rs 硬编码 `chinese_convert: None` 改为读取持久化配置（键 `chineseConverterType`，0/1/2 → None/t2s/s2t），新增 set/get 接口；章节标题在展示路径补齐 t2s/s2t（对齐 Kotlin getDisplayTitle）；阅读器样式面板控件由 UI 轨接入 | 2026-08-05 | ✅ 已完成 |
| `ttsSpeak` / `ttsSetCacheDir`（新增，Task #113 缺口②） | 见 §2.42 方法清单 | TTS 真实合成管线：url 模板替换（speakText/speakSpeed）→ HTTP 拉取音频二进制（legado-net 新增 get_raw）→ Content-Type 校验 → MD5 命名本地缓存（命中免请求）；请 UI 轨将 `audioSpeak`（§2.26）的 `http.get` 探活 fallback 改接 `ttsSpeak`，音频播放器播放返回的 `audioPath` | 2026-08-06 | ✅ 已完成 |

#### 待 UI 封装清单（2026-08-06 审计：7 个 bridge 绑定已实现未被 UI 层封装）

> 以下 bridge 绑定（ffi.dart）已实现但未被 BookApi/rust_api.dart 封装或未被 UI 调用，登记于此供 UI 轨排期封装；封装后逐项销记。

| # | 绑定 | 所属组 | 备注 |
|---|------|--------|------|
| 1 | `sourceIsLoginUiV2` | 登录 UI V2 整组（§2.3） | ✅ 已封装接通（522e1c1be，`RustApi.isLoginUiV2`，书详/阅读器登录链路接入） |
| 2 | `sourceLoginUiV2` | 登录 UI V2 整组（§2.3） | ✅ 已封装接通（522e1c1be，`RustApi.loginUiV2`） |
| 3 | `sourceLoginActionV2` | 登录 UI V2 整组（§2.3） | ✅ 已封装接通（522e1c1be，`RustApi.loginActionV2`） |
| 4 | `backupList` | 其他（§2.41） | ✅ 已封装 `BookApi.backupList`（F3-20） |
| 5 | `cacheGetChapter` | 其他（§2.41） | ✅ 已封装接通（本次评审修复提交，`RustApi.getCachedChapter`，书架缓存导出） |
| 6 | `bookGroupSetShow` | 其他（§2.41） | ✅ 已封装 `BookApi.bookGroupSetShow`（F3-20） |
| 7 | `httpTtsSetEnabled` | 其他（§2.41） | ✅ 已封装 `BookApi.httpTtsSetEnabled`（F3-20） |
| 8 | `ttsSpeak` | TTS 真实合成管线（§2.42） | ✅ 已封装 `BookApi.ttsSpeak`（F3-20；`audioSpeak` 内部亦调用） |
| 9 | `ttsSetCacheDir` | TTS 真实合成管线（§2.42） | ✅ 已封装 `BookApi.ttsSetCacheDir`（F3-20；`RustApi.init` 内 `_initTtsCacheDir` 注入应用支持目录 tts_cache） |

> **销记更新（F3-20，2026-08-14）**：§3 待 UI 封装清单 **9 项全部销记**——登录 UI V2 三件套 + `cacheGetChapter` + `ttsSpeak`/`ttsSetCacheDir`（先前批次）+ `backupList`/`bookGroupSetShow`/`httpTtsSetEnabled`（本批补入 BookApi 抽象与 RustApi/MockBookApi 双实现）。**剩余待封装：0 项。**
>
> **移除记录（2026-08-07，Task #139）**：原表中 QUIC 客户端六件套（quicCreateClient/quicGet/quicPost/quicPerformanceTest/quicIsInitialized/quicCleanup）连同 netSetQuicEnabled/netIsQuicEnabled 总开关共 8 项 FFI，属原版不存在的新增能力，按纯重构决策已从 Rust/FFI/Dart 全链路移除，从本清单销记。

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
>
> **Task #137 补记（2026-08-07，数据源对齐原版字典规则，签名不变）**：
> Rust 侧 `dictLookup` 数据源由 18 词静态占位表改为对齐 Android 原版字典规则（dict_rules）体系：
> ① 查询 `dict_rules` 表全部启用规则（按 sortNumber 排序），逐条执行原版 `DictRule.search(word)`
> 等价链路（AnalyzeUrl urlRule 模板/`{{key}}`/data: URI → HTTP → AnalyzeRule showRule，`@js:` 经
> quickjs 特性执行）；② 表为空时注入原版默认 5 个字典源（海词中文/海词英文/有道/哔哩/百度汉语，
> 数据与 `assets/defaultData/dictRules.json` 逐字节同源）；③ 每条成功规则结果为一个 `definitions`
> 条目（前缀 `【规则名】`，原版为每规则独立页签），HTML 释义做轻量纯文本化；`phonetic` 恒为空；
> ④ 无启用规则/DB 未初始化返回空列表（非异常），单规则失败记日志跳过；
> ⑤ 入参仅 trim 不再小写（中文词兼容，原版原样传词）；⑥ 原版部分规则依赖 Rhino 专属能力
> （JavaImporter/org.jsoup/cache.putMemory）在 QuickJS 下不可等价复现，规则数据不改写、失败即跳过。

---

## 附录：模块方法数统计

| # | 模块 | 方法数 |
|---|------|--------|
| 1 | 初始化/版本 | 2 |
| 2 | 书架操作 | 10 |
| 3 | 书源操作 | 25 |
| 4 | 搜索操作 | 12 |
| 5 | RSS 源操作 | 10 |
| 6 | 本地书籍操作 | 4 |
| 7 | 书签操作 | 7 |
| 8 | 替换规则操作 | 6 |
| 9 | 阅读器操作 | 10 |
| 10 | 配置操作 | 4 |
| 11 | 备份操作 | 2 |
| 12 | 阅读记录 | 5 |
| 13 | RSS 收藏操作 | 4 |
| 14 | 书籍分组 | 4 |
| 15 | 搜索历史 | 5 |
| 16 | 缓存管理 | 8 |
| 17 | WebBook 操作 | 6 |
| 18 | 发现页操作 | 2 |
| 19 | 规则解析 | 1 |
| 20 | 网络操作 | 5 |
| 21 | JS 引擎 | 2 |
| 22 | 服务器管理 | 5 |
| 23 | 书籍格式解析 | 3 |
| 24 | HTTP TTS | 7 |
| 25 | 音频播放 | 4 |
| 26 | WebDAV 云同步 | 7 |
| 29 | 下载管理器 | 7 |
| 30 | 段评（ruleReview） | 3 |
| 31 | 书籍导出 | 2 |
| 32 | 自动任务 | 14 |
| 33 | 音频播放模式 | 2 |
| 34 | 压缩包导入 | 7 |
| 35 | RSS 已读记录 | 7 |
| 36 | 正文高亮 | 11 |
| 37 | JS 单文件书源配置 | 3 |
| 38 | 应用日志 | 5 |
| 39 | 规则订阅 | 7 |
| 40 | 本地 TXT 全文搜索 | 4 |
| 41 | 契约外已实现 FFI 补登记（§2.41，待 BookApi 封装） | 5 |
| 42 | TTS 真实合成管线 | 2 |
| 43 | 缓存写/购买/批量下载/导出扩展（§2.43，Task #136） | 7 |
| | **合计（§2.1–§2.43 附录行合计）** | **251** |

> 口径说明（F3-10，2026-08-14 校准；基准 = `book_api.dart` 程序化计数 **247**）：
> - **与 BookApi 闭合**：附录行合计 251 − 尚未封装进 BookApi 的 FFI 10 个
>   （行 41 的 `backupList` / `bookGroupSetShow` / `httpTtsSetEnabled` 3 个、行 42 TTS 管线 2 个、
>   行 43 的 `cacheDownloadStart` / `cacheDownloadProgress` / `cacheDownloadCancel` / `cacheDownloadList` /
>   `bookExportWithOptions` 5 个，待 UI 封装，见 §3「待 UI 封装清单」）= 241；
>   − 行 41 中 `dictLookup` 已在 BookApi 实现但附录重复计数 1 = 240；
>   + §1.7 命名等价 8 对中 BookApi 侧 7 个已在 §2.x 表格计数、仅 `dictLookup` 见上行 = **247**。
>   第四批 3 项（`setCustomHosts` / `setMcpPort` / `searchCoverRules`）均为 BookApi 封装口径方法；
>   2026-08-12 再加 `webdavDownloadFile` 1 + `clearCookie` 1 + curl 三方法 3（230 + 5 = 235）；
>   2026-08-13 加 `reviewGetSummary` / `reviewGetDetail` 2；2026-08-14 F3-15 移除本地 CRUD 4 → **233**。
> - 本表行数已逐行与各 §2.x 章节标题对齐：行 3 按 §2.3 表格实际 24 行（含 `setSourceVariable` / `clearCookie` / curl 三方法）；
>   行 7 按 §2.7 标题修正为 7（原 6 + 第三批 `getBookmarksByBook` 1）；行 30 按 §2.30 标题为 **3**（reviewGetReplies/Summary/Detail）；
>   行 4 按 §2.4 标题为 8（原 7 + 第四批 `searchCoverRules` 1）；行 20 按 §2.20 标题为 3（原 2 + 第四批 `setCustomHosts` 1）；
>   行 22 按 §2.22 标题为 5（原 4 + 第四批 `setMcpPort` 1）。
