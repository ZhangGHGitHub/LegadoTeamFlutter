# 漫画/视频功能轨道 — 立项前现状调研报告

> 文档性质：漫画/视频轨道立项前的只读调研。书籍主流程已收口，用户指令：漫画/视频先于音频；真实样例保持「待用户素材」，先做离线 fixture 与自动化测试。
>
> - 调查日期：2026-09-29（报告文件名沿用任务指定的 20260928）
> - 工作仓 HEAD：`14da5a48c1`（2026-09-29，`chore(release): 版本 2.0.322+323`）
> - 原版快照：本仓 `app/src/main/java/io/legado/app/`（语义基准）
> - 上游快照：`/d/OH-WorkSpace/LegadoTeam/legado-upstream/`（已抽查 `WebBook.kt` 正文规则为空分支，与本仓一致）
> - 参考版（只读）：`/d/OH-WorkSpace/LegadoTeam/legado-with-MD3/`
> - 纪律：只读调研；未改任何代码；未改 `docs/REFACTORING_ACTIVE_PLAN.md`（主代理回写）；结论均带 file:line 出处；不确定处标注「未核实」。

---

## 一、结论摘要

1. **原版漫画链完整可对齐**：路由（`BookInfoActivity.kt:1509`）→ `ReadMangaActivity`（RecyclerView+PagerSnapHelper 横/纵翻页、WebtoonRecyclerView 双指缩放 0.5–3x）→ 全局单例 `ReadManga`（prev/cur/next 三章预载、前后 N 章预下载、进度复用 `book.durChapterIndex/durChapterPos`）→ 数据链 `BookType.image=64` → 正文规则 HTML → `formatKeepImg` 保留 `<img>` → `BookHelp.flowImages` 正则抽图绝对化 → 图片磁盘缓存（MD5 命名）+ `imageDecode` JS 解密 + 书源防盗链 header。
2. **参考版漫画是「原版语义 + Compose/UDF 架构升级」**：单向数据流 + domain session 状态机（16 命令/4 章态/load token）+ repository 分页模型；分页 5 模式、缩放 6 类型、宽页/双页、约 50 项设置、图片预取、9 区点击、分享/复制图片、付费 URL；并**新增本地漫画（cbz/zip/目录）加载——此为参考版扩展，原版 ReadManga 不读本地文件书（`BookInfoActivity.kt:1509` 路由条件 `!book.isLocal`）**。参考版无视频播放器。
3. **视频存在性结论（关键）**：**视频在原版完整存在**——`BookType.video=4`、`BookSourceType.video=4`、`help/gsyVideo/` 播放器模块（9 文件，GSYVideoPlayer+ExoPlayer、悬浮窗、选集/倍速/B 站弹幕解析）、`model/VideoPlay.kt`（进度缓存 `video_pos_`）、`service/VideoPlayService.kt`（前台服务）、书架 IdVideo 分组、副内容 `putDanmaku` 弹幕。因此视频**不属于「原版不存在的新功能」**，不构成重构红线的「新增功能需授权」问题；它是我方双轨（Rust/FFI/Dart）的缺口。参考版仅有类型位与 `isVideo` 扩展，无播放器实现。
4. **我方现状**：漫画屏（`reader_comic_screen.dart`，1385 行）与视频屏（`video_screen.dart`）骨架已通——漫画：纵向滚动+双指缩放+FFI 图片解码链（`fetchImageWithDecode` 含 imageDecode/防盗链/复合 URL）+电子纸/灰度/滤镜/页脚，v2.0.19 起 51漫画/favcomic 设备实测通过（代码内注释证据 + `rust/legado-ffi/src/api/image_api.rs:640` 起的 favcomic 真实链路测试）；视频：video_player 播放 + 章节列表/上下集/MPD/长按倍速/全屏/进度写回。**但**：漫画无页级进度（`chapterPos` 恒 0）、无横向/单页模式、无自动翻页、无三章预载、无预下载、无长按存图、无阅读时长、无 WebDav 同步、无图片磁盘缓存；视频无弹幕、无悬浮窗、无选集对话框；`subContent`（视频弹幕源）在 Rust 媒体分支被直接丢弃（`web_book.rs:3706-3712`）。
5. **最小闭环已通，缺口集中在「进度页级化 + 离线缓存 + 体验对齐参考版 + 视频弹幕/悬浮窗」**。建议第一批做：离线 fixture 测试矩阵 + 页级进度 + 图片磁盘缓存（契约扩展）+ 真实样例需求清单（见 §7）。

---

## 二、原版漫画链全貌（问题 1）

### 2.1 路由与宿主

- 书籍信息页开读路由：`app/src/main/java/io/legado/app/ui/book/info/BookInfoActivity.kt:1496-1512`
  - `book.isAudio → AudioPlayActivity`（L1496）
  - `book.isVideo → VideoPlayerActivity`（L1501）
  - `!book.isLocal && book.isImage && AppConfig.showMangaUi → ReadMangaActivity`，否则 `ReadBookActivity`（L1509）
  - 目录页跳转同判断（L1337）
- `showMangaUi` 默认 true：`app/src/main/java/io/legado/app/help/config/AppConfig.kt:876-877`（PreferKey `app/src/main/java/io/legado/app/help/PreferKey.kt:218`）
- 类型位：`app/src/main/java/io/legado/app/constant/BookType.kt` — `video=0b100(4)`、`text=8`、`audio=32`、**`image=64 (0b1000000)`**、`webFile=128`、`local=256`；`BookSourceType.kt`：default=0/audio=1/**image=2**/file=3/**video=4**；`isImage`/`isVideo` 扩展 `app/src/main/java/io/legado/app/help/book/BookExtensions.kt:41-48`。

### 2.2 阅读器 UI（`ui/book/manga/`）

- `ReadMangaActivity.kt`（910 行）：
  - RecyclerView + PagerSnapHelper 横向翻页（L101-103）；横向/纵向布局切换 `setHorizontalScroll`（L726-741，`MangaLayoutManager` HORIZONTAL/VERTICAL）
  - 滚动预载：RecyclerViewPreloader + Glide（L716-724，预载数量 `AppConfig.mangaPreDownloadNum`）
  - 长按存图（L241-253，`mangaLongClickSaveImage` 开关）；中央点按弹菜单、左右区点按翻页（WebtoonFrame L255-267）
  - 自动滚动/自动翻页（菜单项 L568-591，ScrollTimer + `mangaAutoPageSpeed`）
  - 颜色滤镜（L497-500 → `updateWindowBrightness`）、灰度/电子纸二值化（L631-674）
  - 音量键翻页（L892-905）；finish 时「加入书架」确认（L835-856）；页脚标签/百分比进度（L323-380，进度计算 L355-375）
- `WebtoonRecyclerView.kt`（373 行，`manga/recyclerview/`）：
  - pinch 缩放 `onScale`（L193-218；常量 L370-373：MIN_RATE=0.5 / MAX_SCALE_RATE=3 / DEFAULT=1）
  - 双击 2x 放大（L244-255）；缩放下拖拽 `zoomScrollBy`（L179-186）
  - `IComicPreScroll` 预滚动监听（L365-367）；`disableMangaScale`/`disableClickScroll` 开关
- `MangaAdapter.kt`（280 行）：AsyncListDiffer，LOADING/CONTENT 两类 item + LoadMore footer；Glide transformation（色彩滤镜 ColorMatrix L112-128、电子纸/灰度 L253-279）；预加载 `getPreloadRequestBuilder`（L237-246）
- `MangaVH.kt`（147 行）：`mangaImagePath(imageUrl)`（L31-34）— 本地缓存文件存在则用本地路径，否则远程 URL；`loadImageWithRetry` 进度百分比 + 失败重试
- entities：`MangaPage`/`MangaChapter`/`MangaContent`/`ReaderLoading`（边栏项「阅读 X」/「已读完 X」）/`BaseMangaPage`/`EpaperTransformation`（灰度+二值化 threshold）/`GrayscaleTransformation`（0.299/0.587/0.114 矩阵）

### 2.3 ViewModel 与模型层

- `ReadMangaViewModel.kt`（326 行）：
  - `initData`（L55-79）：inBookshelf/chapterChanged intent extras、lastReadBook 兜底
  - `initManga`（L81-124）：目录/详情/章节加载 + 自动换源
  - `autoChangeSource`（L167-210）：`mapParallelSafe` 对候选源做精确搜索+目录+正文探测
  - `syncBookProgress` WebDav（L215-240）；`changeTo` 换源（L245-263）；`refreshContentDur`（L298-306）；`saveImage` → `BookHelp.saveImage` + FileDoc 写入（L308-325）
- `model/ReadManga.kt`（653 行，全局 object 单例）：
  - prev/cur/nextMangaChapter 三章预载（L53-55）；`resetData`/`upData` 从 `book.durChapterIndex/durChapterPos` 恢复（L71-117）
  - `loadContent`（L166-185）：先读缓存 `BookHelp.getContent`，未命中 `download`（WebBook 抓正文）
  - `contentLoadFinish`（L206-252）：「正文没有图片」校验（L227-229，`imageCount == 0 && !chapter.isVolume` 时 loadFail）
  - `buildMangaContent`（L254-281）：三章页面拼接 + pos 计算 + `hideMangaTitle`
  - `moveToNextChapter`/`moveToPrevChapter`（L286-333，自动切章时 saveRead）
  - **`saveRead`（L340-363）：进度复用 `book.durChapterIndex/durChapterPos`，无独立漫画进度字段**
  - `upReadTime`（L135-152）：ReadRecord 阅读时长
  - `preDownload`（L392-421）：前后各 N 章预下载（`AppConfig.mangaPreDownloadNum`）
  - `syncProgress`/`uploadProgress` WebDav（L501-547）
  - `getManageChapter`（L611-644）：**`BookHelp.flowImages(chapter, content)` → `MangaPage` 列表** + ReaderLoading 边栏项

### 2.4 数据链（问题 1 下半）

- **图片规则解析**：原版无独立「图片规则」字段——图片 URL 从正文 content 规则的 HTML 输出中抽取：
  - `app/src/main/java/io/legado/app/model/webBook/BookContent.kt:239-249`：`analyzeRule.getString(contentRule.content)` 后 `if (!book.isAudio && !book.isVideo) content = HtmlFormatter.formatKeepImg(content, rUrl)`（保留 `<img>` 标签 + 绝对化；音频/视频取的是链接，跳过 HTML 格式化）
  - 多页 `nextContentUrl`：串行 while（L73-101）/ 并发 `mapAsync(AppConfig.threadCount)`（L103-127）
  - 副内容 `subContent`（L149-158）：`book.isAudio → putLyric`；**`book.isVideo → putDanmaku`（弹幕）**
  - 标题规则 `imgRegex` 提取 imgUrl（L176-198）
  - **正文规则为空**：`app/src/main/java/io/legado/app/model/webBook/WebBook.kt:429-433` — `contentRule.content.isNullOrEmpty() → return bookChapter.url`（正文=章节链接字符串；下游 `flowImages` 无法从中抽图 → ReadManga 侧表现为「正文没有图片」，即原版语义下图片书源须配 content 规则或已有正文缓存）。上游快照 `legado-upstream/.../WebBook.kt:431` 行为一致。
- **抽图**：`app/src/main/java/io/legado/app/help/book/BookHelp.kt:324-333` `flowImages` — `AppPattern.imgPattern` 正则（`app/src/main/java/io/legado/app/constant/AppPattern.kt:14`：`<img[^>]*src="..."`）匹配 + `NetworkUtils.getAbsoluteURL(bookChapter.url, src)` 绝对化，`Flow<String>`；`saveImages` 并发（L335）
- **图片缓存**：`BookHelp.saveImage`（L347+，`AnalyzeUrl.getByteArrayAwait` 下载 → `ImageUtils.decode` 执行 imageDecode JS 解密 → 写盘）；`BookHelp.getImage`（L392）— 路径 `downloadDir/cache/<bookFolder>/cacheImage/<MD5(src)>.suffix`；`isImageExist`；`mangaImagePath`（MangaVH L31-34）本地优先
- **防盗链**：`model/BookCover.kt` L140-160+ `loadManga`/`preloadManga` Glide RequestBuilder + `OkHttpModelLoader.mangaOption`/`sourceOriginOption`（书源 header 注入）
- **阅读记录**：漫画进度复用 `book.durChapterIndex/durChapterPos`（ReadManga.saveRead L340-363，**非独立字段**）；阅读时长 ReadRecord（L135-152）；WebDav 进度同步（L501-547）

---

## 三、参考版漫画（问题 2，legado-with-MD3，只读）

### 3.1 架构差异（相对原版）

| 维度 | 原版 | 参考版（MD3） |
|---|---|---|
| UI 框架 | RecyclerView + PagerSnapHelper（`ReadMangaActivity` 910 行单体） | Compose：`ReadMangaActivity` 仅 252 行宿主（`ui/book/manga/ReadMangaActivity.kt`），`MangaReaderScreen`（1973 行）承载界面 |
| 状态模型 | ViewModel 命令式 + 全局单例 ReadManga | 单向数据流：`MangaReaderContract.kt`（397 行）Intent/UiState(~40 字段)/Effect + domain session 状态机 |
| 章节状态 | 回调 upContent/loadFail | `MangaReaderSessionModels.kt`（147 行）：`MangaChapterState`（Empty/Loading/Ready/Failed）+ `MangaLoadToken`(sessionId/revision) 防竞态 + 16 种 Command/3 种 Event |
| 数据仓库 | BookHelp 全局 | `data/repository/manga/`：`MangaReaderDataRepository`/`DefaultMangaReaderSession`/`MangaChapterPageLoader`(85 行)/`LocalMangaLoader`(128 行) |
| 图片提取 | `BookHelp.flowImages`（imgPattern） | 同款：`MangaChapterPageLoader.kt:31-35` — `BookHelp.getContent` 缓存 → `RemoteChapterContentLoader`（WebBook.getContentAwait）→ `BookHelp.flowImages(chapter, content).distinctUntilChanged()` |
| 分页/缩放 | 横/纵 2 向 + pinch 0.5–3x | 5 种 scrollMode（`MangaScrollMode.kt:3-9`：PAGE_L2R/R2L/T2B、WEBTOON、WEBTOON_WITH_GAP）+ 6 种 pageScaleType（`MangaPageConfig.kt`：FIT_SCREEN/STRETCH/FIT_WIDTH/FIT_HEIGHT/ORIGINAL/SMART_FIT）+ 宽页 4 模式 + 双页 5 模式 |
| 设置面 | 散落的 AppConfig 项 | `MangaReaderSettings` 约 50 字段（默认 WEBTOON、preDownloadCount=10、autoReadSpeed=3、eInkThreshold=150、footer 8 项 hide*、liquid glass 菜单、`clickActions=[-1,-1,1,2,0,1,2,1,1]` 9 区、sourceOrigin 防盗链） |
| 预取 | RecyclerViewPreloader（屏内 N 张） | 图片预取 `MangaChapterImagePrefetch`（`MangaReaderScreen.kt:361-424`，preDownloadCount + pageDecodeSize）+ 章预取 |
| 本地漫画 | 无（`BookInfoActivity.kt:1509` 条件 `!book.isLocal`，本地书走文本阅读） | **`LocalMangaLoader.kt`：.cbz/.zip/图片目录，imageGroups 按目录分组为章节——参考版扩展功能（原版不存在，若做需按「新功能」走用户授权）** |
| 其他 | 长按存图、分享 | 分享/复制图片（`ReadMangaActivity.kt:149-155`）、付费 URL（`OpenPaymentUrl`，L134-143）、音量键翻页（L240-251，volumeKeyPage/reverseVolumeKeyPage） |
| 单测 | 无 manga 专项单测 | 7 个：`app/src/test/.../ui/book/manga/`（MangaBookSnapshotTest、MangaColorFilterTest、MangaPageDecodeSizeTest、MangaPageLoadStateTest、MangaReaderInteractionTest）+ `data/repository/manga/`（DefaultMangaReaderSessionTest、LocalMangaLoaderTest） |

### 3.2 参考版视频

- 仅类型位：`BookType.kt:15` video=4、`BookExtensions.isVideo`、`BookContent.kt:235` 「视频获取链接不格式化」分支；**无 gsyVideo/VideoPlay/VideoPlayerActivity 任何播放器实现**（全仓 grep 无命中）。

---

## 四、视频能力存在性（问题 3）

### 4.1 原版：视频完整存在（结论：属我方双轨缺口，非原版新功能）

- 类型/路由：`BookType.video=4`、`BookSourceType.video=4`；`BookInfoActivity.kt:1501` → `VideoPlayerActivity`；书架分组 IdVideo（`app/src/main/java/io/legado/app/data/dao/BookGroupDao.kt:36-51`、`BookshelfGroupItem.kt:54-61`、`BookInfoEditActivity` L107/131/136 类型 4→video|local、`SourceLoginViewModel` L47 登录类型）
- 播放器模块 `app/src/main/java/io/legado/app/help/gsyVideo/`（9 文件）：`VideoPlayer.kt`（552 行=VideoPlayerActivity，GSYVideoPlayer 封装）、`ExoPlayerManager`（277 行）/`Exo2MediaPlayer`（131 行）、`FloatingPlayer`（170 行悬浮窗）、`ChoiceEpisodeDialog`（80 行选集）/`ChoiceSpeedDialog`（73 行倍速）/`SwitchVideoAdapter`、`BiliDanmukuParser`（287 行 B 站弹幕解析）/`DanmakuAdapter`
- 模型 `app/src/main/java/io/legado/app/model/VideoPlay.kt`（541 行）：videoUrl/singleUrl/episodes/volumes/danmaku/danmakuSpeed/lockCurScreen/isPortraitVideo；进度缓存键 `VIDEO_POS_NAME="video_pos_"`（L56，L499-500 读写）
- 服务 `app/src/main/java/io/legado/app/service/VideoPlayService.kt`（641 行）：BaseService 前台服务 + 悬浮窗（L460-501）
- 数据语义：视频书正文规则返回播放链接（不做 HTML 格式化，`BookContent.kt:240`）；副内容 `subContent` 作弹幕（`BookContent.kt:155-158` → `BookChapter.putDanmaku/getDanmaku`，`app/src/main/java/io/legado/app/data/entities/BookChapter.kt:81-82`，variable key `danmaku`）

### 4.2 参考版：无视频播放实现（仅类型位，见 §3.2）

### 4.3 我方（先行结论，详见 §5.4）

- 已有 `VideoScreen`（`flutter_legado/lib/src/screens/video_screen.dart`）：video_player 播放 + 视频源书籍模式；无弹幕、无悬浮窗、无选集对话框。

---

## 五、我方现状盘点（问题 4）

### 5.1 路由与类型位

- `flutter_legado/lib/src/models/book.dart:11-18` — Dart `BookType` 与原版一致：video=4、text=8、updateError=16、audio=32、**image=64**、webFile=128、local=0x1000、notShelf=0x400
- 路由分派 `flutter_legado/lib/src/utils/book_open_utils.dart:196-228`：
  - `resolveTypeBits`（L196-219）：视频启发式 `looksLikeVideoSource` 优先（修正 MacCMS 误标图片源）→ 显式 `bookSourceType` 4=video/2=image 优先 → `promoteImageContentSource`（L183-189：图源 HTML 内容则 text 位提升为 image 位）
  - `routeForTypeBits`（L223-228）：video→`/video`、audio→`/audio`、image→`/reader-comic`、其余→`/reader`
- `flutter_legado/lib/src/routes.dart`：`readerComic`（L145-151，传 bookUrl）、`video`（L407-421，支持直链 Map 或 Book 书籍视频源模式）；`book_open_utils.dart:232-242` 参数分派（video/audio 传 Book，漫画传 bookUrl）

### 5.2 漫画屏 `reader_comic_screen.dart`（1385 行）能力清单

已具备（行号均指该文件）：
- 纵向 ListView 连续滚动 + InteractiveViewer 双指缩放 1.0–3.0（L627-645）
- 章节切换 `_goToChapter/_nextChapter/_prevChapter` + 底部 Slider 章节定位（L500-524、L985-1008）
- 目录空时自动 `refreshToc` 回退（L260-267，注释记 51漫画 notShelf 设备实测）
- 图片 URL 解析 `parseComicImageUrls`（L380 调用，见 §5.3）；相对→绝对 URL（L349-360，对齐原版 getAbsoluteURL）
- 预加载前后 2 页（L419-473）
- 双轨图片渲染：有书源 → `_DecodedComicImage`（FFI `fetchImageWithDecode` + imageDecode 解码 + 防盗链，L663-681、L1072，注释记 v2.0.19 51漫画实测）；无书源 → `CachedNetworkImage + httpHeaders`（L703-724）
- `ComicImageDecodeCache`（L1047-1084，`looksLikeImageBytes` 魔数防污染）
- 电子纸二值化（`_EpaperNetworkImage` + `mangaEpaperFromBytes`，L1268-1384）；灰度 ColorFilter.matrix（L221-228）
- 颜色滤镜/页脚配置（MangaConfigKeys，getConfig/setConfig L108-126）；亮度 SystemBrightness（L195-202）；MangaConfigSheet 设置面板（L204-218）
- 进度保存（L527-538：`api.updateReadingProgress(bookUrl, chapterIndex, chapterPos: 0)` — **chapterPos 恒 0 = 页级进度缺失**；L98-105/L557-561 dispose/退出保存）
- 错误重试占位（L774-806）；`_visiblePageIndex` 滚动估算页码（L88、L405-406、L929）

缺失（对原版/参考版）：三章预载、横向/单页翻页模式、自动翻页/自动滚动、长按存图、换源、阅读时长、WebDav 进度同步、图片磁盘缓存、页级进度恢复、音量键翻页、分享/复制图片。

### 5.3 Dart 数据层

- `comic_image_utils.dart`（142 行）：`isCompositeImageUrl`/`stripCompositeImageUrl`（`url,{json}` 复合 URL）；`looksLikeImageUrl`（m3u8/mp4 等流媒体排除，L27-34）；`comicImgSrcRegex`（L55-61，对齐原版 `HtmlFormatter.formatImagePattern`：复合 src、data-src/data-original/data-srcset、普通 src、data-* 兜底）；`parseComicImageUrls`（L66-89：HTML img → 每行 URL 兜底）；`isImageDominantContent`（L96-106，文本阅读器兜底转漫画渲染，必应漫画设备证据）；`looksLikeImageBytes`（L110-141，JPEG/PNG/GIF/WEBP 魔数）
- `manga_config.dart`：`MangaColorFilterConfig`（L7）、`MangaFooterConfig`（L76）、`kMangaGrayscaleMatrix`（L204）、`MangaConfigKeys`（L212-217：colorFilter/footerConfig/enableEInk/eInkThreshold/enableGray）
- `BookApi`（`flutter_legado/lib/src/services/book_api.dart`）：
  - `getChapterContent`（L557）/`getChapterContentRaw`（L562）/`getChapterContentFull`（L568，一次调用合并抓取+缓存）
  - `fetchChapterContent(bookUrl, chapterUrl, sourceUrl)`（L571-575，网络抓取）
  - `saveChapterContent`（L581-586，契约 §2.43.1）
  - `updateReadingProgress({bookUrl, chapterIndex, chapterPos})`（L589-593 — **已有 chapterPos 参数，页级进度无需契约变更**）
  - `fetchImageWithDecode(url, sourceJson)`（L972-977：图片下载 + imageDecode 解码，返回 JSON `{base64, len}`；无 imageDecode 规则时返回原始 base64）
  - `ContentRule` 字段（`models/rule/rule.dart:81-89`）：content/subContent/nextContentUrl/webJs/sourceRegex/replaceRegex/imageDecode — 与原版 ruleContent 对齐
- 实现侧：`rust_api_reader_data.part.dart:241,260`（getChapterContentFull/fetchChapterContent → FFI）；`mock_book_api_reader_data.part.dart:147`（测试 Mock）

### 5.4 视频屏 `video_screen.dart`（+ `video_play_utils.dart`、`video_settings_dialog.dart`）

已具备：
- video_player 播放：播放/暂停、进度拖拽、时间显示、全屏（横屏）、加载中/错误处理（L27-26 文档注释）
- 视频源书籍模式：章节列表、正文经 `resolveVideoPlayTarget`（相对 URL/复合 UrlOption header/MPD 临时文件）后播放、上一集/下一集跳过卷标题（L24-26）；书源原始 header 每集与 UrlOption 合并（对齐 AnalyzeUrl.headerMap，L67-71）
- 进度写回 `durChapterIndex/durChapterPos`（L290 注释）+ 初始化恢复进度自动播放（L354，对齐 VideoPlay.seekOnStart）
- 设置（`video_settings_dialog.dart`）：长按倍速（原版存 5–60，实际倍速=value/10，L14）、全屏底栏进度条（L121）
- 入口：直链（platform_bridge_service.dart:958 浏览器页）或书籍视频源（book_open_utils 路由）

缺失（对原版 §4.1）：弹幕（subContent 源数据 Rust 侧已丢弃，见 §5.5）、悬浮窗、选集对话框（ChoiceEpisodeDialog）、倍速对话框（ChoiceSpeedDialog 对应物，长按倍速已有部分能力）、独立 `video_pos_` 缓存（我方复用 durChapterPos，语义近似）、书架视频分组（IdVideo，我方 book_group 无视频分组——grep 无命中）、B 站弹幕解析。

### 5.5 Rust 侧现状

- 正文净化 `rust/legado-core/src/html_formatter.rs:108` `format_keep_img`（对标 Kotlin `HtmlFormatter.formatKeepImg`，保留 `<img>` + 懒加载属性处理 + URL 绝对化；单测 L466-519 覆盖 basic/preserves/lazy/srcset/absolute/script-style/block 8 例）
- FFI content 链 `rust/legado-ffi/src/api/web_book.rs`：
  - `parse_content_page_with_bindings`（L3320+）：注入 chapter/title/book（含 totalChapterNum、type 位）JS 绑定（漫画/视频书源正文 JS 依赖）；神漫画 `chapter.index`/`book.totalChapterNum` 修复（注释 L3327-3329）
  - 净化分派（L3389-3411）：**is_media（音频/视频）跳过 HTML 净化** → `VideoPlayerState::normalize_content` 空正文对齐 ContentEmptyException、Url/Mpd 分类；非媒体 → `format_keep_img` + `unescape_html4`
  - **正文规则为空 → `analyzer.content()` = 抓取的原始 HTML body（L3385-3387）— 与原版「空规则→章节 URL 字符串」（WebBook.kt:429-433）语义不同**：Rust 行为对图片书更实用（章节页 HTML 自带 `<img>`），但属既有实现事实，契约文档未显式记载该差异（建议补记）
  - subContent（Task #134，L1793-1910）：`fetch_sub_content`（L3656-3698，二次请求 http 开头副内容）+ `merge_sub_content_into_body`（L3706-3712：**is_media 时直接丢弃** → 视频书 subContent（弹幕源）不进入正文；原版 putDanmaku 存章节变量供播放器消费）
- 图片面 `rust/legado-ffi/src/api/image_api.rs`：
  - `decode_image_bytes`（L65+）：QuickJS imageDecode（每次新建引擎对齐规则路径 v2.0.24，jsLib 可选，失败回退原图并 eprintln 可观测）
  - `split_composite_image_url`（L175-197 注释区）：`url,{json headers}` 复合 URL 拆分
  - 防盗链兜底 Referer（L148-150）
  - `fetch_image_with_decode`（L207）：下载（书源 header 合并）→ imageDecode 解码 → base64 JSON
  - 单测：复合 URL 拆分（L291）、无 imageDecode 原样返回（L328）、默认 Referer（L339）、imageDecode+jsLib 按位翻转（L365）、仅 imageDecode 无 jsLib（L385）、**51漫画真实 CDN 密文设备取证回归（L404）**；`js_executor.rs:1496` favcomic jsLib 校验
- 视频状态机 `rust/legado-core/src/video_state.rs`：`normalize_content`/`is_mpd_content`（MPD 写临时文件，UI 轨调用）
- 缓存面：`rust/legado-ffi/src/api/cache_api.rs` — **仅 `cached_chapters` 文本章缓存**（get/clear 系列，L14-107），**无图片磁盘缓存**（原版 BookHelp.saveImage/getImage MD5 缓存无对应物）
- 测试 fixture：`rust/legado-ffi/tests/fixtures/comic_source.json`（favcomic 喜漫漫画书源：bookSourceType=2、JS content 规则 `"images": [...]` 提取 → `<img src>` 拼接、`imageDecode: decode(result)`、jsLib 混淆 polyfill、toc 规则 `.right_box:nth-child(2)@a`）+ `comic_2122.html`（search 测试用）

### 5.6 已有漫画/视频相关测试与 fixture（问题 4 尾项）

- Flutter（`flutter_legado/test/`）：
  - `unit/book_open_and_comic_url_test.dart`（类型位/路由/漫画 URL 解析）
  - `unit/manga_config_test.dart`、`unit/manga_epaper_test.dart`（配置/电子纸）
  - `widget/manga_config_sheet_test.dart`（设置面板）
  - `widget/reader_comic_decode_test.dart`（Mock 书源含 imageDecode，1x1 PNG base64 注入验证 Image.memory 渲染 + decode 调用记录）
  - `widget/reader_comic_empty_toc_test.dart`（目录空回退）
- Rust：
  - `rust/legado-core/src/html_formatter.rs:466-519`（format_keep_img 8 例）
  - `rust/legado-ffi/src/api/image_api.rs:291-420`（复合 URL/无规则/有规则/51漫画取证）
  - `rust/legado-ffi/src/js_executor.rs:1496`（favcomic jsLib）
  - `rust/legado-ffi/src/api/image_api.rs:640` 起 `test_fetch_favcomic_image_decode_real`（网络测试，`#[ignore]`：搜索→目录→正文→抽图→解码全链路）
  - `rust/legado-ffi/src/api/search.rs:4794`（comic_2122.html 搜索 fixture）
- 设备证据文档：`docs/QUEUE_CLOSURE_20260922.md`、`docs/RHINO_INTEROP_ANALYSIS_20260920.md`（51漫画/favcomic 实测记录）；`docs/REFACTORING_ROADMAP_PROPOSAL_20260927.md:33,57`（漫画/视频列入用户素材验收门槛，素材缺失记「待外部验收」）

---

## 六、差距清单（问题 5）

按「最小闭环 → 体验对齐参考版 → 边缘能力」三层。涉及轨道：Rust=legado-parser/core、FFI=legado-ffi、Dart=flutter_legado；工作量 S（≤1 天）/M（2-4 天）/L（1 周+）。

### 第一层：最小闭环（漫画源→详情→目录→图片正文→翻页阅读→进度）

闭环主体已通（v2.0.19+ 设备实测证据在代码注释与 §5.6 测试中），剩余缺口：

| # | 缺口 | 缺失面 | 轨道 | 量级 | 契约依赖 |
|---|---|---|---|---|---|
| C1 | **页级进度**：漫画进度 chapterPos 恒 0（`reader_comic_screen.dart:533`），重开只能回到章首；原版 saveRead 存页索引（ReadManga.kt:340-363） | 进度恢复精度 | Dart（`updateReadingProgress` 已有 chapterPos 参数，`book_api.dart:589-593`） | S | 无 |
| C2 | **图片磁盘缓存**：无对应原版 BookHelp.saveImage/getImage（MD5 命名，L347+/L392）；现有仅内存 ComicImageDecodeCache + cached_chapters 文本缓存 | 离线/重开加载性能 | Rust+FFI（新增图片缓存 API）+Dart | M-L | **需契约新增**（docs/API_CONTRACT.md 加节） |
| C3 | **相邻章内容预载**：无原版 preDownload（ReadManga.kt:392-421）/参考版 preDownloadCount=10 的章级预取；现仅屏内 ±2 页图片预载 | 翻页流畅度 | Rust（复用 get_chapter_content_full 写缓存）+Dart | M | 无（复用既有 FFI） |
| C4 | **空正文规则语义差异未入契约**：Rust 空规则=原始 HTML body（web_book.rs:3385-3387）vs 原版=章节 URL 字符串（WebBook.kt:429-433） | 契约文档完备性 | 文档（Rust 无需改） | S | 补记契约说明 |
| C5 | **离线 fixture 测试矩阵**：parseComicImageUrls 各分支（复合 URL/data-src/懒加载/行 URL/m3u8 排除）与 content 链图片书断言的独立测试集（现有分散，无专项目录） | 自动化保障 | Dart+Rust 测试 | M | 无 |
| C6 | 漫画屏进度/章节切换/回退的 widget 测试补强（现有 decode/empty_toc 两例，缺章节切换与进度保存路径） | 自动化保障 | Dart 测试 | S | 无 |

### 第二层：体验对齐参考版（对齐目标 = 参考版 §3.1 能力面）

| # | 缺口 | 缺失面 | 轨道 | 量级 | 契约依赖 |
|---|---|---|---|---|---|
| E1 | **翻页模式**：仅纵向条漫；参考版 5 模式（PAGE_L2R/R2L/T2B/WEBTOON/WEBTOON_WITH_GAP，MangaScrollMode.kt:3-9）+ 单页双指 | 交互 | Dart | M-L | 无 |
| E2 | **缩放/分页类型**：InteractiveViewer 1-3x 自由缩放；参考版 6 种 pageScaleType + zoomStartPosition + 宽页/双页模式（MangaPageConfig.kt） | 交互 | Dart | M | 无 |
| E3 | **自动翻页/自动滚动**（原版 ScrollTimer+mangaAutoPageSpeed；参考版 autoReadSpeed=3） | 交互 | Dart | M | 无 |
| E4 | **三章预载会话状态**（原版 prev/cur/next + 参考版 session/load token 防竞态模型） | 架构 | Dart（+C3 预取） | M-L | 无 |
| E5 | **点击区域/长按菜单/存图分享**（参考版 clickActions 9 区、ShareImage/CopyImage，ReadMangaActivity.kt:149-155；原版长按存图 mangaLongClickSaveImage） | 交互 | Dart | M | 无 |
| E6 | **设置面扩展**：约 50 项（sidePadding/背景色/footer 8 项 hide*/liquid glass 菜单/双页宽页…，MangaReaderSettings）；我方现 6 键（MangaConfigKeys L212-217） | 可配置性 | Dart | L | 无 |
| E7 | **阅读时长记录**（原版 ReadManga.upReadTime L135-152）+ **WebDav 进度同步**（L501-547） | 数据 | Rust+Dart（read_record FFI 已有 read_record_api.rs，WebDav 有 webdav_api.rs） | M | 无 |
| E8 | **自动换源**（原版 autoChangeSource L167-210 mapParallelSafe 探测；参考版 ChangeSourceBook intent） | 可靠性 | Rust+Dart | L | 依赖搜索/目录/正文探测链 |
| E9 | **本地漫画文件（cbz/zip/图片目录）** — 参考版 LocalMangaLoader 扩展；原版 ReadManga 不读本地书 | 功能 | Rust（archive 解压，archive_import_api.rs 已有基础，cbz 章节分组未核实）+Dart | L | **参考版扩展功能，原版不存在 → 按重构红线需用户授权** |
| E10 | 漫画/视频屏暗色主题硬编码浅色缺陷（`docs/DARK_THEME_PARITY_LEDGER_20260920.md` 经 roadmap L30 转述登记「漫画设置等疑似硬编码浅色缺陷」，具体条目**未核实**） | 视觉 | Dart | S-M | 无 |

### 第三层：边缘能力（原版视频面，参考版亦无对应）

| # | 缺口 | 缺失面 | 轨道 | 量级 | 契约依赖 |
|---|---|---|---|---|---|
| V1 | **视频弹幕**：subContent→putDanmaku（原版 BookContent.kt:155-158、BookChapter.kt:81-82）→ BiliDanmukuParser → 播放器弹幕层；我方 Rust 媒体分支直接丢弃 subContent（web_book.rs:3706-3712） | 视频体验 | Rust（保留 subContent 入变量/返回值）+FFI（契约）+Dart（弹幕 UI） | L | **需契约变更**（视频 subContent 数据面） |
| V2 | **视频悬浮窗**（原版 FloatingPlayer.kt + VideoPlayService 前台服务 L460-501） | 视频体验 | Dart 平台层（Android 悬浮窗权限） | L | 平台能力，无 FFI 契约 |
| V3 | 选集对话框/倍速对话框（ChoiceEpisodeDialog/ChoiceSpeedDialog）；我方长按倍速已有部分（video_settings_dialog.dart:155） | 视频体验 | Dart | S-M | 无 |
| V4 | 书架视频分组（IdVideo，BookGroupDao.kt:36-51；我方 book_group 无视频分组） | 书架 | Rust+Dart | S | 无 |
| V5 | 视频独立进度缓存 video_pos_（原版 VideoPlay.kt:56；我方复用 durChapterPos，`video_screen.dart:290`，语义近似——如需与原版一致再拆） | 数据 | Dart | S | 无 |
| V6 | 付费章节 URL 打开（参考版 OpenPaymentUrl；原版 VIP 章付费链**细节未核实**） | 内容 | Dart | M | 无 |

---

## 七、建议批次划分（问题 6）

### 第一批（离线 fixture + 最小闭环收口，不依赖用户素材）

1. **C1 页级进度**：漫画屏以 `_visiblePageIndex`（现 L88/L405-406 已有）为 chapterPos 写入 `updateReadingProgress`（替换 L533 恒 0 值），重开经 `getReadingProgress` 定位到章内页；对齐原版 durChapterPos 语义。**纯 Dart，S**。
2. **C5 离线 fixture 测试矩阵**（对应「先做离线 fixture 与自动化测试」指令）：
   - Dart：`parseComicImageUrls` 全分支用例（复合 `url,{json}`、data-src/data-original/data-srcset、普通 src、每行 URL、m3u8/mp4 排除、isImageDominantContent 阈值、looksLikeImageBytes 四魔数）— 建议 `flutter_legado/test/unit/comic_image_utils_test.dart` 专项
   - Rust：content 链图片书离线断言（format_keep_img 保留 img + 绝对化已有 8 例，补「content 规则空 → body 直用」与「is_media subContent 丢弃」两个行为固化测试）；`fetchImageWithDecode` 补 fixture 驱动用例（现有 51漫画取证测试 L404 保留为 ignore 网络测试）
   - 复用现有 `comic_source.json`（favcomic 书源，含 JS content 规则 + imageDecode + jsLib）作离线书源 fixture 基线
3. **C2 图片磁盘缓存（契约先行）**：docs/API_CONTRACT.md 新增图片缓存节（下载→MD5 文件缓存→本地优先读取，对齐原版 BookHelp.saveImage/getImage L347+/L392 + mangaImagePath L31-34 本地优先语义）→ Rust 实现 → 漫画屏改走本地优先；兼做离线阅读能力底座。**M-L，本批唯一契约变更项**。
4. **C3 相邻章预取**：切章时对前后 1-2 章调 `get_chapter_content_full`（既有 FFI，无契约变更）后台写缓存。**M**。
5. **C4 契约补记**：空正文规则语义差异（§5.5）写入契约/文档，避免后续误改。
6. **C6 漫画屏 widget 测试补强**：章节切换、进度保存/恢复、空目录回退路径。
7. **视频侧第一批仅固化**：V4 书架视频分组（S）与 V5 进度语义确认（复用 durChapterPos，不改）；V1-V3 留第二批（涉及契约/平台，且可等真实视频素材到位验收）。

### 真实样例需求清单（供用户准备素材，对应「待用户素材」门槛）

素材到位后按 `docs/REFACTORING_ROADMAP_PROPOSAL_20260927.md:57` 流程验收真实链路。建议清单：

**漫画（4 类，覆盖全部解析分支）：**
1. 标准 HTML 漫画源 ×1：content 规则为 CSS/HTML 抽 `<img>`、无 imageDecode、无复合 URL（基础形态）
2. JS content 规则 + jsLib + imageDecode 加密图片源 ×1（favcomic/51漫画形态，fixture 已有同类基线，需真实在架书验证）
3. 复合 URL `url,{json headers}` 防盗链源 ×1（图片 URL 内嵌 header）
4. （可选）本地 cbz/zip 漫画文件 ×1 —— **仅在授权 E9（本地漫画为参考版扩展功能）后需要**

**视频（2-3 类）：**
1. MP4 直链视频源 ×1：有卷/章节结构、单章=播放链接（覆盖 resolveVideoPlayTarget 相对 URL/header 合并/上下集）
2. （可选）m3u8/HLS 视频源 ×1（覆盖流媒体，配合 looksLikeImageUrl 排除逻辑）
3. （可选，做 V1 弹幕时）B 站系弹幕源 ×1

**每类素材要求**：书源 JSON（原版 app 导出，含 jsLib/imageDecode 等完整字段）+ 1-2 本书 + 每书 ≥3 章 + 每章 ≥3 图（漫画）；有登录/反爬的源提前说明（我方 sourceLogin 链已有，但素材需可复现）。

### 第二、三批（建议，不展开）

- 第二批：E1-E5（翻页模式/缩放类型/自动翻页/三章会话/点击区域）+ E10 暗色修复 + V3 选集/倍速对话框
- 第三批：E6 设置面扩展、E7 阅读时长+WebDav 同步、E8 自动换源、V1 弹幕（契约）、V2 悬浮窗、E9 本地漫画（待授权）

---

## 八、未核实事项清单

1. 原版 VIP/付费章节的付费 URL 打开细节（参考版有 OpenPaymentUrl，原版对应物未逐行核实）— 影响 V6 量级
2. `docs/DARK_THEME_PARITY_LEDGER_20260920.md` 中漫画设置硬编码浅色缺陷的具体条目（经 roadmap L30 转述，未回读原表）— 影响 E10 范围
3. `archive_import_api.rs` 对 cbz 的章节分组（imageGroups 语义）支持度 — 影响 E9 量级
4. 参考版 `MangaReaderDataRepository`/`DefaultMangaReaderSession` 全文（未逐行读，能力面经 Contract/Models/Loader 层推断）
5. MuMu 设备档 2026-09-24 起不可用（AGENTS.md 记载）— 第一批为纯离线 fixture/自动化测试，不阻塞；真实样例验收需设备恢复或用户真机

---

*调研人：调研子代理（只读）。所有结论以 file:line 为据；「未核实」项已在 §8 登记。*
