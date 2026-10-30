# 批9 接线计划——13 项「有开关无功能」逐项核实与实施就绪方案（2026-10-30）

> 编写：调研员（只读核实）｜ 2026-10-30
> 依据：`docs/SETTINGS_GAP_SCOPE_20261030.md` §3.2 的 13 项与 §五批9；对照当前 HEAD（`99a0ac55e8`）源码逐项 grep/read 核实。
> 参考版＝`D:\OH-WorkSpace\LegadoTeam\legado-with-MD3`；原版＝`D:\OH-WorkSpace\LegadoTeam\legado-upstream`。路径:行均为编写时点事实。

## 一、13 项一句话结论总表

| # | 项 | 偏好键（我方） | 当前消费方 | 结论 |
|---|---|---|---|---|
| 1 | 抗锯齿 | `antiAlias` | 无 | 纯 Dart 接线到图片绘制 Paint（Flutter 文字无法关抗锯齿，语义降级标注） |
| 2 | 图片绘制缓存 | `bitmapCacheSize` | 无（仅备份排除） | 纯 Dart 接线到 Flutter 全局 ImageCache 上限（贴近原版语义） |
| 3 | 漫画保留数 | `imageRetainNum` | 无 | 需 Rust 新增「按章窗口清理图片缓存」API；另我方默认值与参考版语义不同（见 §2.3） |
| 4 | 预下载数 | `preDownloadNum` | 无 | 现有下载队列（cache_download_api）不读它；纯 Dart 轻量预取可接（附待验证项） |
| 5 | 线程数 | `threadCount` | 无（仅恢复忽略） | Rust 并发全为硬编码常量；需 FFI 契约扩展传参 |
| 6 | 源编辑最大行数 | `sourceEditMaxLine` | 无 | 纯 Dart 接到源编辑器代码字段 maxLines |
| 7 | 自动清除过期搜索 | `autoClearExpired` | 无 | 需 Rust 新增 searchBooks 按期删除 FFI + Dart 启动调用（0.5d 小改动） |
| 8 | 漫画浏览 UI | `showMangaUi` | 无 | 纯 Dart 接到开书分流 routeForTypeBits |
| 9 | 自动更新 | `autoUpdateVariant` | 无（确认零消费方） | 纯 Dart 接启动钩子 + 既有 AppUpdateService；updateToVariant 待裁决另记 |
| 10 | 耳机按键三件套 | `mediaButtonOnExit`/`readAloudByMediaButton`/`ignoreAudioFocus` | 无 | ignoreAudioFocus 纯 Dart；另两枚需 Kotlin MediaSessionBridge 改动（仅 Android） |
| 11 | Web 服务唤醒锁 | `webServiceWakeLock` | 无（settings_screen 注释自认未接线） | 需 Android 平台通道 wake lock；iOS 无对应（沿用既有 WebKeepAliveService） |
| 12 | UserAgent | `userAgent` | 仅 RSS 文章 WebView 生效 | Rust 网络链路不读 config:userAgent；需 Rust 内部消费点（无新 API） |
| 13 | 语言 | `app_locale` | AppStrings 静态变量，且仅打开过其他设置页才初始化 | MaterialApp 无 locale；最小接法＝启动时初始化 AppStrings（0.25d） |

---

## 二、逐项详情

### 2.1 抗锯齿（antiAlias）

**现状**
- 设置项：`flutter_legado/lib/src/screens/other_settings_screen.dart:348-356`（开关，副题「绘制图片时抗锯齿」）。
- 偏好键：`flutter_legado/lib/src/constants/pref_keys.dart:247` `antiAlias`，默认 false（`:141` 读取）。
- 消费方：全仓 grep `PrefKeys.antiAlias` 除设置页与键定义外 **0 处**。Flutter 侧所有图片绘制均硬编码 `FilterQuality.medium`（`flutter_legado/lib/src/widgets/reader/turn/painters/cover_page_painter.dart:99`、`lib/src/widgets/reader/reader_image_dominant_body.dart:306`、`lib/src/widgets/reader/turn/painters/slide_page_painter.dart:76`）；`Clip.antiAlias` 命中均为 Flutter 枚举巧合、与本偏好无关。

**参考版/原版**
- 原版：`app/src/main/java/io/legado/app/help/config/AppConfig.kt:47`（useAntiAlias），消费于 `app/src/main/java/io/legado/app/ui/book/read/page/ContentTextView.kt:106`（正文绘制 `Paint.isAntiAlias`）。
- 参考版：`domain/model/settings/OtherSettings.kt:13`（默认 false）；`ui/config/readConfig/ReadConfig.kt:42` 暴露 `useAntiAlias`；但参考版自绘表面 `feature/reader/ReaderCanvasSurface.kt:1762` 恒为 `isAntiAlias = true`（即参考版该项实际未生效，仅模型保留）。

**建议消费方与改造点（纯 Dart）**
- 阅读翻页 painters 与漫画绘制 Paint：按偏好切换 `Paint()..isAntiAlias` 与 `FilterQuality`（medium ↔ 低档）。涉及上列 3 个 painter + `lib/src/screens/reader_comic_screen.dart` 图片绘制处。建议经一个共享 helper（如 `src/utils/image_paint_utils.dart`）读 UiSettingsNotifier 镜像，避免每处直读 SharedPreferences。
- **语义差异必须标注**：原版该键作用于**正文文字**绘制；Flutter `TextPainter` 不暴露抗锯齿开关（恒开启），故我方只能作用于**图片**绘制——UI 副题「绘制图片时抗锯齿」本就吻合，如实登记差异即可。

**工作量/风险**：0.5 天；低风险。文字绘制不生效属平台差异，非缺陷。

### 2.2 图片绘制缓存（bitmapCacheSize）

**现状**
- 设置项：`other_settings_screen.dart:357-368`（区间 1~1024 MB）。
- 偏好键：`pref_keys.dart:250`，默认 50；读取 `:142-143`。
- 消费方：**0 处**。仅 `lib/src/services/restore_ignore_prefs.dart:25` 将其列入「始终不备份」（说明该键曾被当作设备级项，接线后此排除仍合理）。

**参考版/原版**
- 原版：`AppConfig.kt:926-929`；消费于 `app/src/main/java/io/legado/app/model/ImageProvider.kt:44-47`（校验 1..1024 后作为 Bitmap LruCache 容量，50MB 默认）。
- 参考版：`model/ImageProvider.kt:52`（`1..<2048` 校验 ×1MB，否则回落 50MB）；`domain/model/settings/DownloadCacheSettings.kt:4`。

**建议消费方与改造点（纯 Dart）**
- 最贴近原版语义的等价物是 Flutter 全局解码缓存：`PaintingBinding.instance.imageCache.maximumSizeBytes = bitmapCacheSize * 1024 * 1024`，在 `flutter_legado/lib/main.dart` 启动序列（第 54 行 `Future.wait` 之后）设置一次即可，区间外回落 50MB（对齐原版 `ImageProvider.kt:44` 的钳制）。
- 可选增强（不属本项必做）：`lib/src/screens/reader_comic_screen.dart:2689` 的 `ComicImageDecodeCache` 当前是无上限、无淘汰的 `Map<String,Uint8List>`（仅 `:2745` 测试清理），可作为第二消费点加字节上限，但建议独立小任务，不与批9a 混做。

**工作量/风险**：0.25~0.5 天；低风险。全局 imageCache 变更影响所有图片页面，需冒烟书架/阅读器/漫画。

### 2.3 漫画保留数（imageRetainNum）

**现状**
- 设置项：`other_settings_screen.dart:369-380`（区间 0~999，副题「保留已读章节数量」）。
- 偏好键：`pref_keys.dart:253`，**我方默认 100**。
- 消费方：**0 处**（全仓 grep 无）。

**参考版/原版**
- 原版：`AppConfig.kt:932-935`（**默认 0**）；消费于 `app/src/main/java/io/legado/app/help/book/BookHelp.kt:207-212`（`clearComicCache`：`startIndex = durChapterIndex - imageRetainNum`，窗口外章节图片整目录清理；`:176` `includeImageBooks = AppConfig.imageRetainNum > 0`）。
- 参考版：`help/book/BookHelp.kt:195-205` 同语义；`domain/model/settings/DownloadCacheSettings.kt:5` **默认 0**。

**语义差异（重要）**：参考版/原版 0＝**不清除**已缓存图片；我方 UI 默认 100＝保留 100 章。接线时须明确 0 的语义（对齐参考版：0=不清理），并评估是否把默认值改 0（涉及既有用户已写入的 100，属产品口径，建议在实现时保守处理：仅接线不改默认值，0 语义按参考版落地）。

**建议消费方与改造点（需 Rust）**
- 我方漫画图片缓存落在 Rust：`rust/legado-ffi/src/api/image_cache_api.rs:190/225`（save/get_image_cache，按 `book_url + url` 键），无按章列举/删除能力；Dart 侧 `lib/src/screens/reader_comic/manga_page_image_resolver.dart:63` 仅消费。
- 改造：① Rust `image_cache_api` 新增「按书列举已缓存条目 + 按 URL 集删除」FFI（需章节→图片 URL 的映射，可从 `cached_chapters` 表内容或缓存目录索引推导，契约需登记 `docs/API_CONTRACT.md`）；② Dart 在漫画翻章钩子（`lib/src/screens/reader_comic_screen.dart` 章节切换处）调用清理窗口 `[cur-retainNum, cur]` 外的条目。
- **契约影响**：新增 2 个只读/删除 API，无破坏性变更；纯加法。

**工作量/风险**：2 天（Rust 1.5d + Dart 0.5d）；中风险（删错缓存仅导致重下载，不影响数据正确性）。批9b。

### 2.4 预下载数（preDownloadNum）

**现状**
- 设置项：`other_settings_screen.dart:381-392`（区间 0~9999，副题「预先下载 N 章正文」）。
- 偏好键：`pref_keys.dart:256`，默认 10（原版默认 2，`AppConfig.kt:753`）。
- 消费方：**0 处**。现有下载队列不读它：
  - 显式离线缓存走 `api.cacheDownloadStart`（调用点 `lib/src/screens/offline_cache_screen.dart:175/230`、`lib/src/screens/toc_screen.dart:1107/1137`），Rust 端 `rust/legado-ffi/src/api/cache_download_api.rs:236` 起的 `run_download`（`:310`）为**单线程顺序**循环，无并发参数、无预读配置。
  - `rust/legado-core/src/download_manager.rs` 的 PreloadConfig（`:39-58`）是独立的未挂线管理器（`DownloadManager::new(3)` 硬编码，`rust/legado-ffi/src/api/download_api.rs:16`），与阅读器无连接。
  - 漫画预下载为 Rust 内部状态（`rust/legado-core/src/manga_state.rs:384-385` 注释引用 preDownloadNum 仅为对齐 Kotlin 命名），读的是内部 `pre_download_ahead` 字段，与本偏好无关。

**参考版/原版**
- 原版：`AppConfig.kt:753-756`；消费于 `app/src/main/java/io/legado/app/model/ReadBook.kt:1873-1914`（阅读时预载 `[cur+1, cur+N]` 前向、`[cur-min(5,N), cur-1]` 后向）及 `BookHelp.kt:212`（漫画清理窗口上界）。
- 参考版：`model/ReadBook.kt:1922-1934`、`help/book/BookHelp.kt:200`（同语义；`DownloadCacheSettings.kt:6` 默认 10）。

**建议接线点（不设计预取引擎）**
- 纯 Dart 轻量预取：在 `lib/src/providers/reader/reader_notifier.dart` 章节加载完成处（`_loadChapterContent` 成功返回后，`:1017` 附近）对 `[cur+1, min(cur+N, total-1)]` 逐章 fire-and-forget 调用既有 `api.getChapterContentFull`，触发 Rust 正文链路；命中既有缓存则零开销。
- **待验证项（实现前必须先确认）**：`getChapterContentFull` 对在线书是否将正文写入持久缓存（`cached_chapters` 表）。若只返回不落盘，则预取无意义，该键降级为批9b（需 Rust 提供轻量「预取并落盘 N 章」API，或复用 cache_download_start 的重型任务——不推荐，会带进度持久化/失败集合等副作用）。
- 防抖与代数约束照抄 `reader_notifier.dart:44-56` 既有 `_loadChapterContent` 代际号模式，避免连点翻页竞态。

**工作量/风险**：0.5~1 天（若缓存副作用成立，纯 Dart）；否则 1.5~2d（Rust 加轻量预取 API）。风险低（预取失败静默）。批9a（先做待验证项验证，再决定去留）。

### 2.5 线程数（threadCount）

**现状**
- 设置项：`other_settings_screen.dart:519-528`（区间 1~999，标题「更新和搜索线程数（太多会卡顿）」）。
- 偏好键：`pref_keys.dart:286`，默认 16（原版默认 32，`AppConfig.kt:417`）。
- 消费方：**0 处**（仅 `lib/src/services/restore_ignore_prefs.dart:172` 恢复忽略 + `settings_service.dart:1131` 忽略键清单，与行为无关）。

**参考版/原版消费面（语义＝更新/下载/搜索/批量 JS 的并发上限）**
- 原版：`model/CacheBook.kt:154`（onEachParallel）、`model/webBook/SearchModel.kt:38`、`help/book/BookHelp.kt:490`、`help/JsExtensions.kt:205/224`、`help/webView/WebViewPool.kt:35`、`service/CacheBookService.kt:43`、`model/rss/Rss.kt:107`。
- 参考版：`help/book/BookHelp.kt:384`、`data/repository/BookSourceCheckRepository.kt:50`、`domain/usecase/ImportBookshelfUseCase.kt:73`、`help/JsExtensions.kt:141/164`、`model/webBook/BookChapterList.kt:106`、`model/webBook/BookContent.kt:125`、`service/CacheBookService.kt:63`、`domain/usecase/ChangeSourceSearchUseCase.kt:74/130`。

**我方 Rust 并发现状（全部硬编码）**
- 多源搜索：`rust/legado-ffi/src/api/search.rs:114` `SEARCH_CONCURRENCY: usize = 32`，传给 `drive_source_batches`（`:257/402/621`）。
- 显式缓存下载：`cache_download_api.rs:310` 单线程顺序（见 §2.4）。
- 目录批量更新调度器：`rust/legado-core/src/toc_updater.rs:204-239` `run_batch` 支持并发上限入参，但 FFI 侧无调用方（仅测试 `TocUpdater::new(4)`）。
- 下载管理器：`rust/legado-ffi/src/api/download_api.rs:16` `DownloadManager::new(3)`。

**建议消费方与改造点（需 FFI 契约扩展）**
- 契约影响（`docs/API_CONTRACT.md` 新增登记）：搜索/缓存下载/批量更新三类 API 的并发数改为可配置。两条路线：
  - A（推荐，改动最小）：Dart 侧经既有 `setConfig('threadCount', v)` 持久化到 caches 表；Rust 在各入口启动时读 `config:threadCount`，替换 `SEARCH_CONCURRENCY` 硬编码与下载并发常量。无需改函数签名。
  - B：FFI 函数加 `concurrency` 参数（签名变更，影响面大，不推荐）。
- 消费点：`search.rs`（3 处 drive_source_batches 实参）、`cache_download_api.rs`（run_download 改为受控并发）、`toc_updater.rs` run_batch 的 FFI 挂线（若当前无批量更新 FFI 入口则仅接搜索/下载两处并如实标注）。
- **风险**：搜索链路经多轮稳定性修复（`search.rs:707-715` 设计注释），改并发上限必须回归多源搜索/取消/暂停；建议保留合理上限钳制（如 1..=64）。

**工作量/风险**：2 天；中高风险（并发回归）。批9b。

### 2.6 源编辑最大行数（sourceEditMaxLine）

**现状**
- 设置项：`other_settings_screen.dart:325-336`（区间 10~99999）。
- 偏好键：`pref_keys.dart:244`，我方默认 99（原版默认 `Int.MAX_VALUE`，`AppConfig.kt:956-958`）。
- 消费方：**0 处**。我方源编辑器 `lib/src/screens/source_edit_screen.dart:145-152` 各字段 maxLines 硬编码（1/3/4）。

**参考版/原版**
- 原版：`ui/book/source/edit/BookSourceEditAdapter.kt:23`（`editEntityMaxLine = AppConfig.sourceEditMaxLine`）→ `:99-102`（`editText.maxLines`）。
- 参考版：`domain/model/settings/OtherSettings.kt:19`（默认 Int.MAX_VALUE；`FeatureSettingsRepositories.kt:513/530` 归一 `<10 → MAX`）；`ui/config/otherConfig/OtherConfigScreen.kt:186` 展示。参考版自身代码编辑器的实际消费点未逐一核对（标注：编辑器实现已 Compose 化，未确认是否有消费方）。

**建议消费方与改造点（纯 Dart）**
- `source_edit_screen.dart` 的多行代码字段（js/loginUi 等大文本项）maxLines 改为读该偏好（每次进页读一次即可）；`rss_source_edit_screen.dart` 同理可选。
- 语义差异：原版是「编辑实体输入框」统一行数上限（超出内部滚动）；我方为逐字段表单，映射到代码/JS 类大文本字段即可，短字段不套用。

**工作量/风险**：0.5 天；低风险。批9a。

### 2.7 自动清除过期搜索（autoClearExpired）

**现状**
- 设置项：`other_settings_screen.dart:431-439`（副题「超过一天的搜索数据」，默认开）。
- 偏好键：`pref_keys.dart:271`，默认 true。
- 消费方：**0 处**；启动链（`flutter_legado/lib/main.dart:18-96`）无任何清理调用。

**参考版/原版**
- 原版：`app/src/main/java/io/legado/app/App.kt:114-118`（启动时 `searchBookDao.clearExpired(now - 24h)`；DAO 定义 `data/dao/SearchBookDao.kt:95`）。
- 参考版：`app/src/main/java/io/legado/app/App.kt:226-229` 同语义。
- **语义**：清理对象是**搜索结果表 searchBooks**（原版 SearchBookDao），不是搜索关键词历史（search_keywords 表）。

**我方数据基础**
- `searchBooks` 表存在且含 `time` 列：`rust/legado-db/src/schema.rs:300-324`；搜索链路确实落库（`rust/legado-ffi/src/api/search.rs:913` insert searchBooks）。
- 缺口：`rust/legado-db/src/repository/search_book_repository.rs:17-158` 无按期删除方法；`rust/legado-ffi/src/api/search_history_api.rs` 只管 search_keywords。

**建议消费方与改造点（需 Rust 小改动）**
- Rust：`search_book_repository.rs` 新增 `delete_expired(before_ms)`（`DELETE FROM searchBooks WHERE time < ?`）；`rust/legado-ffi/src/api/` 新增薄封装 FFI（如 `search_clear_expired(before_ms: i64) -> i32`，返回删除行数）——契约加法登记。
- Dart：`main.dart` 启动序列（并行初始化之后）读 `PrefKeys.autoClearExpired`（默认 true），为 true 则调用，`before = now - 24h`（24h 常量对齐原版 `TimeUnit.DAYS.toMillis(1)`）。失败静默记日志。
- 备选（不推荐）：Rust 启动自动清理需让 Rust 读到 Flutter 侧偏好，除非该键已同步 caches 表，否则引入新的同步义务；保持「Dart 决策、Rust 执行」与现有 Web 端口/HTTP 日志模式一致。

**工作量/风险**：0.5 天；低风险。批9b（量小，可与 §2.12 同批）。

### 2.8 漫画浏览 UI（showMangaUi）

**现状**
- 设置项：`other_settings_screen.dart:459-466`（标题「漫画浏览」，默认开）。
- 偏好键：`pref_keys.dart:280`，默认 true。
- 消费方：**0 处**。开书分流 `lib/src/utils/book_open_utils.dart:243` `routeForTypeBits`：`(typeBits & BookType.image) != 0 → AppRoutes.readerComic`，**不看任何偏好**。

**参考版/原版**
- 原版：`AppConfig.kt:992`；消费于 `utils/ContextExtensions.kt:73`、`utils/FragmentExtensions.kt:101`、`ui/book/info/BookInfoActivity.kt:1337/1509`——`!book.isLocal && book.isImage && AppConfig.showMangaUi` 才进 ReadMangaActivity，否则普通阅读器。
- 参考版：`domain/model/settings/MangaSettings.kt:4`（默认 true）；消费于 `ui/book/info/BookInfoRouteScreen.kt:147`、`ui/main/MainNavGraph.kt:552`（同条件）。

**建议消费方与改造点（纯 Dart）**
- `book_open_utils.dart` 的分流链（`routeForTypeBits` 或其调用方 `:225-275` 编排处）读取偏好：`showMangaUi == false` 时 image 书回落 `AppRoutes.reader`。读取时机：编排函数是 async，可直读 SharedPreferences，或经启动期注入的镜像（与 §2.1 的 helper 同一镜像可复用）。
- **需验证项**：文本阅读器（ReaderScreen）对图片类型章节的降级呈现（原版走普通阅读器时会显示图片占位/内容）。实现前先以一本 image 书关开关实测，若文本阅读器无法呈现，则如实登记「关=仅影响新开书入口」或评估占位渲染，不得硬接。

**工作量/风险**：0.5 天 + 0.25d 验证；低-中风险（只改分流不改阅读器）。批9a。

### 2.9 自动更新（autoUpdateVariant）

**现状（确认零消费方）**
- 设置项：`other_settings_screen.dart:450-458`（标题「自动更新」，副题「每天自动检查软件是否更新」，默认开）。
- 偏好键：`pref_keys.dart:277` `autoUpdateVariant`，默认 true。
- 消费方：**0 处**（全仓 grep 无）。启动链 `main.dart`/`app.dart` 均无检查更新调用——**确认该偏好当前完全无效**。
- 更新服务已具备：`lib/src/services/app_update_service.dart:77-104` `AppUpdateService.check()`（GitHub Releases，含 variant/sameMajorOnly/ignoreUpdateVersion 逻辑）；唯一调用方是关于页手动检查 `lib/src/screens/about_screen.dart:65-75`；更新弹窗 `lib/src/widgets/update_dialog.dart` 已有。

**参考版/原版语义（该键名在两版含义已分叉）**
- 原版：`autoUpdateVariant`＝「每天自动检查更新」总开关——`ui/main/MainActivity.kt:308-320`（`upVersion` 内 `lastCheckUpdate + 24h` 才 check），配置读 `AppConfig.kt:1128`。
- 参考版：该键**已被拆成两枚**——`autoCheckUpdateOnStart`（启动检查开关，`OtherSettings.kt:14`，消费于 `ui/main/MainActivity.kt:388/419/1052-1059`）与 `updateToVariant`（**更新通道**：official/beta_release/all，`OtherSettings.kt:13`，消费于 `help/update/AppUpdateGitHub.kt:32-37` 把通道映射为 AppVariant）。
- 我方键名沿用原版 `autoUpdateVariant`，但 UI 文案「每天自动检查」对应的是参考版 `autoCheckUpdateOnStart` 语义（默认值也相反：参考版 false，我方 true）。

**建议接线（纯 Dart，含待裁决标注）**
- 启动钩子：`lib/app.dart` `_LegadoAppState.initState`（`:211-258`，既有 AutoTaskScheduler/AutoBackupScheduler 装配处同位）读 `PrefKeys.autoUpdateVariant`，为 true 时延迟（如首帧后 3~5s）调 `AppUpdateService.check()`；有更新弹 `UpdateDialog`，`isIgnored` 沿用既有忽略键；每日一次需本地记录 lastCheckUpdate 时间戳（新 LocalConfig 类键，设备级，加入 `RestoreIgnorePrefs.alwaysIgnoreKeys`）。
- 失败静默（原版 check 失败也无感），Mock/调试构建跳过。
- **`updateToVariant` 待裁决**：我方 `AppUpdateService.check(variant:)` 参数已预留（`:79`），但当前发布为单一 official 变种（`about_screen.dart:75` 未传 variant），且 `app_update_service.dart:52` releasesUrl 指向我方仓库——参考版通道语义（manifest+多变种）依赖其自有发布体系，照搬无意义。**结论：updateToVariant 维持不做**，待我方出现多变种发布再按参考版 `AppUpdateGitHub.kt:32-37` 映射补 0.5d。
- 默认值差异：我方默认 true、参考版 autoCheckUpdateOnStart 默认 false。接线即让默认 true 生效，属产品口径，与缺口盘点文档「启动时自动检测更新 P1」意图一致，按现状默认实现。

**工作量/风险**：1 天；低风险（失败静默、不阻塞启动）。批9a。

### 2.10 耳机按键三件套（mediaButtonOnExit / readAloudByMediaButton / ignoreAudioFocus）

**现状**
- 设置项：`other_settings_screen.dart:403-430`（三枚开关，均灰字标注或未标注「仅 Android」——`mediaButtonOnExit`/`readAloudByMediaButton`/`ignoreAudioFocus` 注释为仅 Android，`pref_keys.dart:262-268`）。
- 消费方：**0 处**（三键全仓无引用）。
- 我方媒体链路：`flutter_legado/lib/src/services/audio_service.dart:21-93`（MediaButtonEvent/AudioFocusEvent 事件流，经平台通道）→ `lib/src/providers/audio/audio_notifier.dart:327`（mediaButton 播放/暂停/上下曲）与 `:342`（audioFocus 事件）、`:1080`（`_syncMediaSession` 每次 `requestAudioFocus()`，无条件）。Android 侧 `flutter_legado/android/app/src/main/kotlin/io/legado/flutter/MediaSessionBridge.kt`（init 注册回调、`:261` isActive、`:408` release），未读任何偏好。

**参考版/原版语义**
- 原版 `MediaButtonReceiver.kt:101`：非朗读态 media key 须 `AppConfig.readAloudByMediaButton` 才响应（即默认关＝按键不启动朗读）；`:111`：`AppConfig.mediaButtonOnExit || activitySize()>0 || !isMediaKey` 才处理（默认 true＝退出后仍响应）。
- 原版 `ignoreAudioFocus`：`AudioPlayService.kt:838/978`、`BaseReadAloudService.kt:582/706/941`（不请求焦点/忽略焦点丢失/配合来电暂停）。
- 参考版：`aloud` 设置组同语义（`AppConfig.kt:109-110` 委托 aloud 组）。

**逐键建议**
1. **ignoreAudioFocus——纯 Dart，批9a（0.5d）**：`audio_notifier.dart:1080` 按偏好跳过 `requestAudioFocus`；`:342` 的 audioFocusStream 监听在开关打开时忽略 `loss/lossTransient` 事件（对齐原版「允许与其他应用同时播放音频」语义）。风险：来电/他应用抢占暂停行为失效，与原版一致，属预期。
2. **readAloudByMediaButton——基本已满足，登记即可**：我方 mediaButton 消费方仅在朗读/听书会话内订阅（`audio_notifier.dart:312-333` 会话生命周期挂接），App 退出后无播放器在监听，media key 不会「启动朗读」——当前行为等价默认 false 的语义。开关打开时也不应从按键冷启动朗读（原版该键只是「非朗读态响应播放/暂停」门，我方无对应 receiver）。**建议：批9b 仅 Android（1d）**，在 `MediaSessionBridge.kt` 按偏好决定非活跃态是否注册 MediaButtonReceiver；若裁决不做，UI 保持灰字「仅 Android」如实标注现状。
3. **mediaButtonOnExit——需 Kotlin 改动，批9b（1~1.5d，仅 Android）**：原版语义＝App 退到后台/退出后耳机键仍控制播放。我方 `MediaSessionBridge.kt:408` 会话释放即失效；实现路径＝按偏好在朗读/听书服务结束时保留 MediaSession（或注册静态 MediaButtonReceiver 经PendingIntent 兜底），需 Android 侧改动+真机回归，且与「退出软件」的进程生命周期强相关（Flutter 容器下语义需实测界定：后台存活 vs 进程退出）。

### 2.11 Web 服务唤醒锁（webServiceWakeLock）

**现状**
- 设置项：`other_settings_screen.dart:309-317`（灰字「仅 Android 生效」，默认关）。
- 偏好键：`pref_keys.dart:238`，默认 false。
- 消费方：**0 处**；`lib/src/screens/settings_screen.dart:141` 注释自述「`webServiceWakeLock` 偏好仅持久化未接线」；`restore_ignore_prefs.dart:23` 已列入始终不备份（正确，保持）。
- 我方 Web 服务＝Rust 进程内 HTTP server（`rust/legado-ffi/src/api/server_api.rs:2537` 经 `server_start`，tokio Runtime），Rust 侧无 wake lock 概念（grep 无）；Android 后台保活现状＝无（`:141-146` 注释），iOS 已有 `WebKeepAliveService`（`settings_screen.dart:146-152` 用户批准方案 C+A）。

**参考版/原版**
- 原版：`service/WebService.kt:76`（读偏好）+ onCreate 时 `wakeLock.acquire()/wifiLock?.acquire()`（PARTIAL_WAKE_LOCK + WIFI_MODE_FULL_HIGH_PERF）。
- 参考版：`service/WebService.kt:68-87` 同语义（服务 onCreate 持锁）。

**建议消费方与改造点（需 Android 平台通道，仅 Android）**
- 平台通道（`platform_bridge_service.dart` 既有通道族）新增 `acquireWakeLock(tag)/releaseWakeLock(tag)`（Kotlin 侧 MainActivity/新 helper，PowerManager.PARTIAL_WAKE_LOCK，reference-counted=false 对齐参考版 `:76-81`）。
- 接线点：`settings_screen.dart` `_toggleWebService`（`:152` `api.startServer` 成功后）读 `PrefKeys.webServiceWakeLock`，为 true 则 acquire；停止服务分支 release；进程死亡即释放（wake lock 天然语义，无需持久化补救）。
- iOS 无对应物（参考版也无 iOS），保持该项 Android-only 灰字；iOS 后台可用性继续由 WebKeepAliveService 承担（两机制并存，互不替代）。
- **契约影响**：仅平台通道方法新增，不涉 Rust FFI。

**工作量/风险**：1 天；中风险（耗电体验；需真机验证锁屏后局域网可达）。批9b。

### 2.12 UserAgent（仅 RSS 文章 WebView 生效）

**现状**
- 设置项：`other_settings_screen.dart:297-300`（副题默认/自定义 UA）。
- 偏好键：`pref_keys.dart:235` `userAgent`。
- 消费方（确认「仅 RSS 生效」的准确范围）：**仅 RSS 文章内嵌 WebView**——`lib/src/screens/rss_article_detail_screen.dart:459`（源 header 未配 UA 时回落 `_globalUserAgent()`，`:1186-1193` 直读 SharedPreferences）。RSS 源列表/文章数据请求走 Rust（`rss.rs`），不读此键。
- **Rust 全链路不消费**：`rust/legado-net/src/client.rs:49,119` `DEFAULT_USER_AGENT` 硬编码；`rust/legado-ffi/src/api/search.rs:2181` `ensure_default_user_agent` 同串兜底；Rust 全工作区 grep `config:userAgent` **未找到**读取点。书源级 UA 只来自书源 JSON header（既有机制）。

**参考版/原版（全局生效）**
- 原版：`AppConfig.kt:48`（`getPrefUserAgent()`）；全局消费点：`help/http/HttpHelper.kt:75`（OkHttp 默认头）、`model/analyzeRule/AnalyzeUrl.kt:801`（书源请求 UA 回落）、`help/webView/WebViewPool.kt:62`、`help/http/BackstageWebView.kt:114`、`data/entities/BaseSource.kt:215`。
- 参考版：`AppConfig.userAgent` 等价全局委托（`AppConfig.kt` 未在本次逐行核对 UA 行，标注：参考版 FeatureSettingsRepositories 迁移后语义不变，均为全局）。

**建议消费方与改造点（需 Rust，无新 API）**
- Dart 侧：保存时（`other_settings_screen.dart:681-684`）同步 `api.setConfig('userAgent', v)`（caches 表，既有通道，`setCustomHosts` 同模式）。
- Rust 侧：`search.rs:2181` `ensure_default_user_agent` 与各请求头构造处、`legado-net` 客户端默认 UA（`client.rs:116-119`）在读到非空 `config:userAgent` 时覆盖默认串。注意 `client.rs:1545-1553` 有跨 crate「同串」钉死测试，改动需同步更新测试口径。
- **风险**：UA 全局变更影响所有书源请求（部分源对 UA 敏感），须回归搜索/正文/验证码；建议实现为「书源 header 未显式配 UA 时才回落用户全局 UA」（与原版 `AnalyzeUrl.kt:801` 优先级一致）。

**工作量/风险**：1~2 天；中高风险（全局网络行为变更）。批9b。

### 2.13 语言（仅 AppStrings）

**现状（含 MaterialApp 事实）**
- 偏好键：`app_locale`（`lib/src/services/settings_service.dart:22,476-489`，值 system/zh/en，默认 system）。
- **MaterialApp 无 locale 参数**：`lib/app.dart:376-421` 的 MaterialApp 未设置 `locale`/`localizationsDelegates`（本项目 UI 文案以硬编码中文+AppStrings 为主，符合 AGENTS.md l10n 约定 D5=B，无需接 MaterialApp.locale）。
- **AppStrings 选语言机制**：静态 `_locale` 默认 'zh'（`lib/src/l10n/app_strings.dart:3-9`，`_get(zh,en)` 二选一，全文件 195 行）。
- **初始化缺陷**：唯一初始化点是其他设置页 `initState → _loadLocale`（`other_settings_screen.dart:115-123`）——**冷启动从不读偏好**，只有打开过其他设置页才生效；选「系统」时立即回退 'zh'（`:1148-1151`）。

**参考版/原版**
- 原版：`base/AppContextWrapper.kt:78-86` per-app locale（zh/tw/en/系统，attachBaseContext 全局、重启生效；支持 tw 我方不支持）。
- 参考版：语言项在设置中存于 OtherSettings（本次未逐行定位参考版消费点，标注：原版机制为权威语义参照）。

**最小接法（纯 Dart，0.25d）**
- `main.dart` 启动序列（第 53-56 行 `Future.wait` 之后、`runApp` 之前）：
  `final locale = await SettingsService().getLocale(); AppStrings.setLocale(locale == 'system' ? 'zh' : locale);`
  （'system'→'zh' 与 `other_settings_screen.dart:117-121` 约定注释一致）。
- AppStrings 无变更通知机制，运行中切语言仍即时 setLocale（现行为），冷启动按偏好——重启生效语义与原版一致。
- **不做**：MaterialApp.locale/localizationsDelegates 接线（项目不推进国际化，无收益）；tw 语言（原版有、我方 AppStrings 无 tw 词条，扩词条超出批9 范围）。

---

## 三、分批清单（批内文件不重叠）

### 批9a：纯 Dart 低风险（合计约 4.5~5 天）

| # | 项 | 文件清单 | 工作量 | 实现前验证项 |
|---|---|---|---|---|
| 1 | 语言启动接线 | `flutter_legado/lib/main.dart`、`lib/src/l10n/app_strings.dart`（如需暴露 init 帮助函数） | 0.25d | 无 |
| 2 | 抗锯齿（图片绘制） | 新增 `lib/src/utils/image_paint_utils.dart`；改 `lib/src/widgets/reader/turn/painters/cover_page_painter.dart`、`slide_page_painter.dart`、`lib/src/widgets/reader/reader_image_dominant_body.dart`、`lib/src/screens/reader_comic_screen.dart`（绘制处） | 0.5d | UI 文案已写「绘制图片」，文字不适用如实登记 |
| 3 | 图片绘制缓存上限 | `flutter_legado/lib/main.dart`（启动设置 imageCache） | 0.25d | 书架/阅读器/漫画冒烟 |
| 4 | 漫画浏览开关 | `flutter_legado/lib/src/utils/book_open_utils.dart`（分流编排 `:225-275`） | 0.5d | 关开关后 image 书走文本阅读器的降级呈现实测 |
| 5 | 自动更新接线 | `flutter_legado/lib/app.dart`（initState 钩子）、`lib/src/services/app_update_service.dart`（加每日一次时间戳读写）、`lib/src/services/restore_ignore_prefs.dart`（新时间戳键入排除表） | 1d | Mock/DEBUG 构建跳过 |
| 6 | ignoreAudioFocus | `flutter_legado/lib/src/providers/audio/audio_notifier.dart`（`:1080`、`:342`） | 0.5d | 听书+TTS 两条路径都过偏好 |
| 7 | 源编辑最大行数 | `flutter_legado/lib/src/screens/source_edit_screen.dart` | 0.5d | 仅套代码/JS 大文本字段 |
| 8 | 预下载数（轻量预取） | `flutter_legado/lib/src/providers/reader/reader_notifier.dart`（翻章成功钩子） | 0.5~1d | **先验证** `getChapterContentFull` 在线书落盘副作用；不成立则整项移批9b |

> 文件冲突检查：批9a 与批2/8（theme_config_screen、home_screen 等）、批1（read_config_screen 新文件）无交集；`main.dart`/`app.dart` 为低冲突敏感文件（启动钩子一次加齐，避免多次重放）。

### 批9b：需 Rust/FFI 或平台通道（合计约 7~9 天）

| # | 项 | Dart/Flutter 文件 | Rust/Android 文件 | 契约影响 | 工作量 |
|---|---|---|---|---|---|
| 1 | 自动清除过期搜索 | `lib/main.dart`（启动调用，可与 9a-1 同次提交相邻）、`lib/src/services/book_api.dart`（声明） | `rust/legado-db/src/repository/search_book_repository.rs`（加 delete_expired）、`rust/legado-ffi/src/api/search_history_api.rs` 或新薄 API | §新增 1 个只读删除 FFI | 0.5d |
| 2 | 线程数 | `lib/src/screens/other_settings_screen.dart`（保存时 setConfig 同步）、`book_api.dart` | `rust/legado-ffi/src/api/search.rs`（SEARCH_CONCURRENCY→config 读取）、`rust/legado-ffi/src/api/cache_download_api.rs`（受控并发） | §无签名变更（走 setConfig）；行为契约登记并发来源 | 2d |
| 3 | 漫画保留数 | `lib/src/screens/reader_comic_screen.dart`（翻章清理钩子）、`book_api.dart` | `rust/legado-ffi/src/api/image_cache_api.rs`（列举+按删） | §新增 2 个 FFI（列举/删除） | 2d |
| 4 | UserAgent 全局回落 | `lib/src/screens/other_settings_screen.dart`（保存时 setConfig） | `rust/legado-ffi/src/api/search.rs`（ensure_default_user_agent 回落）、`rust/legado-net/src/client.rs`（默认 UA 读取，同步更新同串测试 `client.rs:1545-1553`） | §无新 API；行为契约登记 UA 优先级（书源 header > 用户全局 > 内置默认） | 1~2d |
| 5 | 耳机 readAloudByMediaButton / mediaButtonOnExit | `lib/src/screens/other_settings_screen.dart`（状态同步，如需） | `flutter_legado/android/app/src/main/kotlin/io/legado/flutter/MediaSessionBridge.kt`（按偏好保留会话/注册 receiver）；平台通道 `lib/src/services/platform_bridge_service.dart` | 平台通道新增方法（非 FFI） | 1~1.5d |
| 6 | Web 服务唤醒锁 | `lib/src/screens/settings_screen.dart`（`:152` 启动成功后 acquire/停止 release）、`platform_bridge_service.dart` | `flutter_legado/android/.../MainActivity`（或新 WakeLockHelper） | 平台通道新增方法 | 1d |

> 排序建议：9b-1（0.5d 最小）→ 9b-4（UA）→ 9b-2（线程数，回归重）→ 9b-6（唤醒锁）→ 9b-5（耳机）→ 9b-3（漫画保留数）。Rust 侧改动均须先更新 `docs/API_CONTRACT.md`（AGENTS.md 关键约束）。

### 暂不做（缺能力 / 参考版独有且无后端 / 待裁决）

| 项 | 原因 |
|---|---|
| updateToVariant（检查更新查找版本） | **待裁决**。我方发布单一 official 变种，`AppUpdateService.check(variant:)` 已预留参数（`app_update_service.dart:79`）；需要多变种发布时按参考版 `help/update/AppUpdateGitHub.kt:32-37` 补 0.5d。缺口盘点 §六.5 已注明「若当前发布只有单一主线包，可暂不实现」 |
| 漫画保留数的默认值改 0 | 参考版/原版默认 0（不清除），我方 UI 默认 100；属产品口径，建议实现时仅按参考版语义处理 0 值、不改存量默认，若改默认另行裁决 |
| tw 繁体语言 | 原版支持（`AppContextWrapper.kt:80`）、我方 AppStrings 无 tw 词条；扩词条超出批9 |

---

## 四、验证口径

- 批9a/9b 每项完成后：`flutter_legado` 下 `flutter analyze && flutter test`（CI 为准，AGENTS.md 验证命令节）；涉 Rust 项在 `rust/` 下 `cargo test`。
- 实机验证按 AGENTS.md 测试档流程：自动更新（批9a-5）与唤醒锁（9b-6）、耳机（9b-5）须 MuMu 真机冒烟；线程数（9b-2）须多源搜索回归 + 取消/暂停路径。
- 每项接线后在设置页移除/保留「未接线」类灰字标注（当前仅 Web 唤醒锁 `other_settings_screen.dart:311` 与 `settings_screen.dart:141` 注释两处需随接线更新）。

编写：调研员 ｜ 2026-10-30
