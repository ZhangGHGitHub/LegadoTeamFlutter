# 视频轨道缺口全面调研（VIDEO_TRACK_SURVEY）

- 编写：调研代理（ZCode）｜ 2026-10-05
- 性质：只读调研报告，未修改任何项目文件（本报告除外）
- 基准口径：Android 原版（`app/src/main/java/io/legado/app/`）为本域唯一语义基线（参考版 kazusa 视频域仅类型位无播放器，经 Active 计划 §P4-3 红线澄清确认）
- 素材：`docs/materials_1301/video_sources_9.json`（9 个视频源，2026-09-29 用户交付）

---

## 〇、结论摘要

1. **弹幕数据来源不是固定 B 站 API**：来自书源 `contentRule.subContent`（副内容规则）的提取结果（可内联、可 http 二次请求），视频书存入章节变量 `danmaku`，格式为 B 站 XML（`<d p="...">`）。原版链路：`BookContent.kt:156` → `BookChapter.putDanmaku` → `VideoPlay.startPlay` 读取 → `BiliDanmukuParser` 解析 → danmaku-flame-master 渲染。
2. **我方 Rust 已完整实现副内容提取（含 http 二次请求），但在 `merge_sub_content_into_body`（`rust/legado-fetcher/src/web_book.rs:3777-3783`）对音频/视频有意丢弃且未落库**——任务书给的 `legado-ffi/src/api/web_book.rs:3706-3712` 行号已失效（该文件仅 2423 行）。
3. **悬浮窗 = SYSTEM_ALERT_WINDOW 全局悬浮窗**（`VideoPlayService` 前台服务承载 WindowManager overlay + 可拖动贴边 + MediaStyle 通知），**不是画中画**。
4. **`legado-core/src/video_state.rs` 已备好弹幕状态模型（`DanmakuSource` Inline/File/None，含测试）但未接线 FFI**—— dormant 资产，实施批可直接用。
5. 契约推荐路线：**b（独立 FFI `getVideoDanmaku` + Rust 写侧补存）**，契约新节建议 §2.49，+1~2 方法；c（Dart 直抓）违反 UI 层红线，否决。
6. 分批：B1 弹幕数据链（Rust，离线可做，需契约冻结）→ B2 弹幕渲染 UI（离线 fixture 可开发，真机验证）→ B3 悬浮窗（需真机，方案 spike）→ B4 小项收尾（直链进度/自动连播/长按倍速，离线）。

---

## 一、任务 1：原版视频模块全貌

### 1.1 弹幕链全流程（关键产出）

**数据来源：书源副内容规则，与正文同一次 getContent 产出**

| 环节 | 位置 | 证据 |
|---|---|---|
| ① 副内容规则提取 | `model/webBook/BookContent.kt:128-165` | `contentRule.subContent` 非空时提取；`book.isVideo` 分支 `bookChapter.putDanmaku(subContent)`（:156） |
| ①' http 二次请求 | `BookContent.kt:136-147` | 提取结果 `startsWith("http", true)` 时以 `AnalyzeUrl.getStrResponseAwait().body` 作副内容（如 B 站弹幕 API 返回 XML） |
| ② 存储 | `data/entities/BookChapter.kt:81-85` | `putDanmaku` → `super.putVariable("danmaku", value)` → `variable = GSON.toJson(variableMap)` 后 `update()` 落库 |
| ②' 大小分流 | `model/analyzeRule/RuleDataInterface.kt:7-28` | **value < 10000 字符存 variable 列（JSON）**；≥ 10000 走 `putBigVariable` 文件存储 |
| ②" 文件存储 | `help/RuleBigDataHelp.kt:208-220` | `getDanmakuFile(bookUrl, chapterUrl)` = `bookData/md5(bookUrl)/md5(chapterUrl)/md5("danmaku").txt` |
| ③ 播放读取 | `model/VideoPlay.kt:279-282` | `startPlay` 内 `when (val danmaku = chapter.getDanmaku())` → `is String → danmakuStr` / `is File → danmakuFile`；`getDanmaku` 定义在 `help/book/BookChapterExtensions.kt:8-10`（variableMap 优先、文件兜底） |
| ④ 渲染初始化 | `help/gsyVideo/VideoPlayer.kt:266-319` | `initDanmaku`：两者均空 → 隐藏弹幕开关直接返回（:269-272）；否则 `DanmakuView`（`video_layout_controller.xml:14-19`、`_full.xml:15-20`，match_parent 覆盖画面） |
| ⑤ 解析 | `VideoPlayer.kt:355-374` → `BiliDanmukuParser.kt` | `DanmakuLoaderFactory.create(TAG_BILI)` 加载（文件流/URL/字符串流三分支 :358-365）→ `BiliDanmukuParser` SAX 解析 |

**B 站 XML 协议**（`BiliDanmukuParser.kt:80-89` 原版注释给出字段表）：

```xml
<d p="出现时间秒,类型,字号,颜色,时间戳,弹幕池,用户hash,弹幕id">文本</d>
```
- 类型：1=右→左滚动、6=左→右滚动、5=顶部固定、4=底部固定、7=高级弹幕、8=脚本（:83）
- 高级弹幕（type 7）：文本为 JSON 数组 `[x,y,alpha,时长,文本,rotZ,rotY,endX,endY,平移时长,延迟,描边,...]`，含运动/旋转/透明度/路径动画（:136-253）
- 字号 `textSize * (mDispDensity - 0.6f)`（:104）、描边颜色黑白反选（:106-107）、百分比坐标按 BILI_PLAYER_WIDTH/HEIGHT 864/538 换算（:189-199, :277-286）

**渲染配置**（`VideoPlayer.kt:284-318`）：滚动弹幕（TYPE_SCROLL_RL）最多 5 行；滚动+顶部禁重叠；`SpannedCacheStuffer` + `DanmakuAdapter`（图文混排代理——现为 demo 性质：拉 bilibili favicon 做 ImageSpan，`DanmakuAdapter.kt:24-56`）；描边样式 STROKEN 3f；重复不合并。

**设置入口（原版全部现状，防止实施批擅自加项）**：
- 弹幕开关：控制器条 `toggle_danmaku` 按钮「开弹幕/关弹幕」（`VideoPlayer.kt:277-283`、`resolveDanmakuShow` :337-347），全屏与非全屏布局均有
- 弹幕滚动速度：`VideoPlay.danmakuSpeed = 1.2f`（`VideoPlay.kt:96`）——**内存变量，不持久化、无设置 UI**
- 字号缩放：`setScaleTextSize(1.0f)` 固定（`VideoPlayer.kt:297`）——**无透明度/字号设置 UI（原版不存在，红线禁止我方新增）**
- 倍速联动：`setVideoSpeed` 调整弹幕滚动速度因子（`VideoPlayer.kt:135-141`）
- seek/暂停/恢复/全屏切换同步：`VideoPlayer.kt:199-209`（onSeekComplete→seekTo）、:156-174（pause/resume）、:124-133（长按倍速结束回 seek）、:456-490（全屏窗口间转移偏移记录）

### 1.2 悬浮窗播放器

- **形态：全局悬浮窗（SYSTEM_ALERT_WINDOW overlay），非画中画、非应用内浮层。**
- `FloatingPlayer`（`help/gsyVideo/FloatingPlayer.kt:16-171`）：StandardGSYVideoPlayer 子类，布局 `video_layout_floating.xml`（仅 start 按钮/底部进度条/全屏键/返回键）——它只是浮窗里的播放器控件。
- 真正的悬浮窗由 **`service/VideoPlayService.kt`（641 行，注释即「视频悬浮窗服务」:66）** 承载：
  - `WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY`（API≥O）/ TYPE_PHONE 兜底（:474-486）；启动前 `Settings.canDrawOverlays` 检查（:206-211）
  - 清单：`SYSTEM_ALERT_WINDOW` 权限（`AndroidManifest.xml:26`）、`VideoPlayService` `foregroundServiceType="mediaPlayback"`（:555-557）
  - 窗口尺寸：竖屏视频=屏宽 1/2、横屏=3/4，高按视频比例、16:9 兜底（:462-495），onPrepared 后按实际比例二次适配（:560-576）
  - 触摸：拖动跟随 + 松手弹簧贴边动画（`FloatingTouchListener` :497-541、`startEdgeAnimation` :134-171）；单击显隐控制（`showControlUi` :99-105）
  - 入口三处：① `VideoPlayerActivity.startFloatingWindow`（`ui/video/VideoPlayerActivity.kt:729-738`，`isNew=false` 转移当前播放后 finish）② `VideoPlayerActivity.onActivityCreated`：设置 `defaultFloatWindow` 开启时直接把 intent 转给服务并 finish（:177-193）③ `SourceHelp.openVideoPlayer(isFloat=true)`（`help/source/SourceHelp.kt:188-206`，书源 JS 入口 `JsExtensions.kt:332-344`，直链单 URL）
  - 与全屏 Activity 互斥：`ActivityLifecycleCallbacks` 检测 VideoPlayerActivity 创建（非 forwarded）→ stop 服务（:92-108）；反向 `toggleFullScreen`（:599-607）
  - 播放器转移机制：`VideoPlay.savePlayState/clonePlayState`（`VideoPlay.kt:386-398`，cloneParams 复制播放器状态）+ `setSurfaceToPlay`（surface 转移，`VideoPlayer.kt:529-533`）
  - 自动连播：`onAutoComplete → VideoPlay.upDurIndex(1)`（:577-581），播完无法续 → stop

### 1.3 前台服务职责（VideoPlayService 641 行拆解）

不是「后台播音频」，是**视频前台服务 = 悬浮窗载体 + 通知栏控制 + MediaSession**：
- MediaSessionCompat：seekTo/play/pause/skipToPrev/Next + 自定义 stop（:266-294）
- MediaStyle 通知：上一集/播放暂停/下一集/停止 + 封面大图（:296-458），NotificationId=108（`constant/NotificationId.kt:16`），复用 channelIdReadAloud 通道（:319）
- 耳机拔出暂停：`ACTION_AUDIO_BECOMING_NOISY`（:333-343）
- 0.5s 刷播放状态进 MediaSession（:383-392）
- 生命周期收尾：onDestroy 存进度 `VideoPlay.saveRead()`、移除浮窗、释放 session（:621-639）

### 1.4 进度缓存（video_pos_）

- **键规则**：`video_pos_ + 视频URL`（`VideoPlay.kt:56` `VIDEO_POS_NAME`）——**仅单链接模式**（`singleUrl`，非书籍非订阅，:140-165）
- **读取**：`CacheManager.getLong(VIDEO_POS_NAME + mUrl)` → `player.seekOnStart`（:143-145）
- **写入**：`saveRead` 中 book/rssStar/rssRecord 均空时 `CacheManager.put(VIDEO_POS_NAME + videoUrl, durPos, VIDEO_POS_SAVE_TIME)`（:498-502），**TTL 20 天**（:57）
- **书籍模式不走 video_pos_**：走 `saveRead`（:492-536）→ `book.durVolumeIndex/chapterInVolumeIndex/durChapterIndex`（卷内索引换算 :517-519）/`durChapterPos`；订阅走 `rssStar/rssRecord.durPos`（:526-533）；onError 也 saveRead（`VideoPlayer.kt:445-449`）

### 1.5 其余未盘点项

- **`SwitchVideoAdapter`（24 行）**：通用 ListView ArrayAdapter（泛型+标题 lambda，:11-24），仅被选集/倍速对话框用作列表项适配器（`ChoiceEpisodeDialog.kt:55`、`ChoiceSpeedDialog.kt:51`）——**不是换源**，名字沿用 GSY demo 习惯。
- **`ChoiceEpisodeDialog`（80 行）**：右侧抽屉选集（Gravity.END、屏宽 40%、全高，:61-67），标题「选集（N）」，支持初始定位 `setSelectionFromTop`（:57-59）。
- **`ChoiceSpeedDialog`（73 行）**：同形态 30% 宽，档位 `[0.5,0.75,1.0,1.25,1.5,2.0,2.5,3.0]` 倒序 8 档（`VideoPlayer.kt:403`）。
- **`ExoVideoManager`（74 行）**：GSYVideoBaseManager 子类，playManager=ExoPlayerManager，暴露 previous/next/setDisplayNew。单例持于 `VideoPlay.videoManager`（`VideoPlay.kt:102`）。
- **`ExoPlayerManager`（277 行）**：BasePlayerManager 实现，持 `Exo2MediaPlayer`；API 29+ 用 `SurfaceControl` 假 surface 延迟绑定显示（:81-91）——为跨窗口 surface 转移服务；`getBufferedPercentage` 恒 -1（:168-170）。
- **`Exo2MediaPlayer`（131 行）**：`IjkExo2MediaPlayer`（ijkplayer exo2 封装）子类，内核即 Media3 ExoPlayer：`prepareAsyncInternal` 重写（:59-100）——`EXTENSION_RENDERER_MODE_PREFER`（优先软解扩展渲染器 :65-71）、`DefaultLoadControl`、`DefaultMediaSourceFactory(ResolvingDataSource.Factory(ExoPlayerHelper.cacheDataSourceFactory))`（**有边播边缓存**，:79-84）、直播 targetOffset 5s、looping=REPEAT_MODE_ALL、EventLogger；previous/next 基于 timeline 多窗口（:37-56, :105-120）。
- **投屏：未找到**（app 模块无 Cast/DisplayManager/RoutePlayer 相关代码，rg 无命中）。
- **单链接入口**：`SourceHelp.openVideoPlayer`（:188-206）isFloat=true 直接起服务、false 进 Activity（`forceNormalPlayer`）；书源 JS `JsExtensions.openVideoPlayer`（:332-344）按 `defaultFloatWindow` 分流。

---

## 二、任务 2：我方现状精确盘点

### 2.1 subContent 丢弃点核实（修正任务书行号）

**任务书给的 `rust/legado-ffi/src/api/web_book.rs:3706-3712` 已失效**：该文件实际仅 2423 行且无 subContent 内容（Read 工具实测）；全部行号在历史重构中漂移。实际位置：

| 环节 | 实际位置 | 状态 |
|---|---|---|
| 副内容规则读取 | `rust/legado-fetcher/src/web_book.rs:1895-1903`（`content_rule.sub_content`） | ✅ 已实现 |
| 副内容提取 + http 二次请求 | 同文件 `fetch_sub_content`（:3731-3771），含 4 个单测（:7048 起） | ✅ 已实现（对齐 BookContent.kt:128-165，注释明示） |
| **丢弃点** | 同文件 `merge_sub_content_into_body`（:3777-3783）：`if is_media || sub.is_empty() { return; }`；`is_media` 按书源 bookSourceType AUDIO/VIDEO 判定（:1906-1908） | ⚠️ **音频/视频副内容提取后直接不拼正文** |
| 写入 chapter.variable | — | ❌ **不存在**：全仓 rg `putVariable/saveChapterVariable/danmaku` 无写路径命中；丢弃是终态，数据未保存 |
| 调用点 | `get_content`（:1856）内 :1979-1996（分页后提取） | ✅ |

- 单测注释（:7121）「视频/音频：副内容不得拼进正文（对齐 putDanmaku / putLyric）」——**不拼接是有意对齐原版，但原版后续的 putDanmaku 落库这半步没有做**。
- **上游解析已具备**：规则求值、http 二次请求、失败忽略（runCatching 对齐）全在 `fetch_sub_content`，数据在丢弃点前可无损捕获。
- **Dart 侧没有它的位置**：`getChapterContent`/`getChapterContentFull`/`fetchChapterContent`（契约 §2.9，`docs/API_CONTRACT.md:362-365`）返回纯 String；视频无专用 media API。音频已有先例：`getAudioChapterMedia`（§2.26，契约 :534-539）返回体含 `lyric` 字段，Rust 实现 `rust/legado-ffi/src/api/audio_api.rs:44`（`pub lyric: Option<String>`）+ `lyric_from_variable`（:109-120，从 chapter.variable JSON 读）——**这正是弹幕字段可以照抄的模板**。
- 关联防御事实：Dart 曾误把副内容拼进播放链接导致解析失败，后修复为取首行（`flutter_legado/lib/src/utils/video_play_utils.dart:34-48` 注释记录）——**证明副内容绝不能回正文流，必须走独立字段**。

### 2.2 VideoScreen 已有/缺失清单（逐项行号，`flutter_legado/lib/src/screens/video_screen.dart`，916 行）

已有：
| 能力 | 行号 | 对齐原版 |
|---|---|---|
| 章节列表加载（getChapters/refreshToc） | :226-229 | VideoPlay.initSource/upEpisodes |
| 可播章定位（跳卷标题） | utils `video_play_utils.dart:196-208` | upEpisodes 语义 |
| 逐集播放 + 正文取址 | :252-307（fetchChapterContent/getChapterContent :276-278） | startPlay 的 WebBook.getContent 分支 |
| 复合 URL / header / MPD 解析 | utils `resolveVideoPlayTarget` :234-281 | AnalyzeUrl + startPlay `<` 判 MPD |
| MPD 落盘 file 播放 + 临时文件清理 | :310-341 | VideoPlay video_temp 写文件 |
| 上一集/下一集（AppBar + 跳卷） | :344-352、:538-553 | upDurIndex(±1) |
| 倍速对话框 + 会话级保持 | :139-150、:447-449 | showSpeedDialog |
| 选集对话框 | :122-135（widgets/video_settings_dialog.dart） | ChoiceEpisodeDialog |
| 全屏切换（横屏 immersive） | :482-502 | startWindowFullscreen 语义 |
| 双击播放暂停 | :716-722 | touchDoubleUp |
| tip 居中提示 | :112-118、:729-746 | showOverlayTip |
| 进度写回（updateReadingProgress）+ 进入恢复 + 退页写回 | :355-376、:436-439、:519-524 | saveRead/seekOnStart |
| autoPlay/startFull/longPressSpeed/fullBottomProgress 设置 | widgets/video_settings_dialog.dart:7-42 | video_config prefs（VideoPlay.kt:62-94） |
| 音频焦点 mixWithOthers=false | :29-36 | （焦点抢占语义修复，D1 记录） |

V3 选集/倍速浮层（`ee3b5e4c23`，2026-09-29，feat(ui)）：video_screen +103 / video_settings_dialog +270 / 测试 +250 行，零 FFI 契约变更。

缺失（与原版差距）：
| 缺口 | 原版证据 | 备注 |
|---|---|---|
| **弹幕（全链）** | §1.1 全链 | lib 全域 rg `danmaku/弹幕` 0 命中 |
| **悬浮窗** | §1.2 | flutter_legado AndroidManifest 无 SYSTEM_ALERT_WINDOW（:4-28 权限清单无此行）、无 overlay 服务 |
| 播放完成自动连播 | VideoPlayer.kt:185-188 onAutoCompletion→upDurIndex | 我方无 isCompleted 监听 |
| 长按倍速手势 | VideoPlayer.kt:108-116（longPressSpeed/10） | 设置项已存（longPressSpeed）但屏幕无手势 |
| 直链模式进度记忆 | VideoPlay.kt:56,143,500 video_pos_ | `_playDirectUrl`（:184-205）无进度存取；书籍模式已有 |
| 锁屏手势 | VideoPlayer.kt:84-86（isNeedLockFull/lockTouchLogic） | 优先级低 |
| 边播边缓存 | Exo2MediaPlayer.kt:79-84（ExoPlayerHelper cacheDataSourceFactory） | video_player 插件无此能力 |
| 外部播放器打开 | VideoPlayerActivity.kt:702-712（menu_open_other_video_player） | 未做 |

### 2.3 video_player 插件能力边界 vs 原版 ExoPlayer

- 我方依赖：`video_player: ^2.9.3`（pubspec.yaml:23），Android 端内核同为 ExoPlayer（Media3）——解码/流协议层面无本质差距。
- 插件**不提供**而原版有的：① 弹幕渲染层（原版 DanmakuView 独立 View 叠加）→ Flutter 需自绘（Canvas/CustomPainter，由 `_controller.value.position` 驱动逐帧同步，纯 Dart 可实现且可离线测试）；② 边播边缓存（原版 ResolvingDataSource+cacheDataSourceFactory）；③ surface 跨窗口转移（悬浮窗核心机制——插件 texture 归 Flutter engine 所有，**无法直接搬进服务 overlay**，悬浮窗需服务内自建播放器 surface 或 VirtualDisplay 方案）；④ 播放完成事件（插件 value.isCompleted 可监听，属未接线非无能力）。
- MPD：我方走清单文本落盘 + `VideoPlayerController.file`（:318-327），已在非凡源真机验证通过（Active 计划 P4-3 ①），维持现状。

### 2.4 弹幕设置入口将来挂哪

- 原版弹幕开关是**控制器条直接按钮**（toggle_danmaku，全屏/非全屏布局都有），不在设置对话框。我方对齐位置 = `_buildControlBar`（video_screen.dart:776-889）按钮行，倍速/选集 TextButton（:852-871）同排左侧。
- 弹幕速度无 UI（1.2f 硬编码内存）；按红线我方不应新增弹幕字号/透明度设置 UI。

### 2.5 dormant 资产：legado-core video_state

`rust/legado-core/src/video_state.rs`（775 行，lib.rs:67 导出）已实现：
- `VideoPlayerState` 状态机（卷/剧集组织 up_episodes、up_dur_index、进度、PlayState 迁移），对齐 VideoPlay.kt
- **`DanmakuSource` 枚举（None/Inline/File，:44-63）+ `resolve_danmaku`（:343-355，inline 优先、file 兜底，对齐 getDanmaku 语义）+ `danmaku_show` 开关（:110-113）**，含 4 个弹幕单测（:685-723）
- 当前仅 `normalize_content/is_mpd_content` 被 fetcher 引用（web_book.rs:3471-3478）；**FFI 未暴露、Dart 未使用**——实施批可直接接线，无需重建模型。

---

## 三、任务 3：契约影响面（关键产出）

### 3.0 前置事实

- 丢弃点在 Rust fetcher **内部**（`get_content` 返回 `LegadoResult<String>`），捕获点在 `merge_sub_content_into_body` 之前——改造属 fetcher 内部签名调整，不动既有 FFI。
- 存储语义对标：chapter.variable JSON（<10000 字符，`BookChapter.variable` 列，BookChapterRepository 有通用 `Repository::update`（book_chapter_repository.rs:271）可整行更新）；≥10000 原版走 RuleBigDataHelp 文件——**Rust 无大变量文件等价物**（rg `10000/big_variable` 无业务命中），这是唯一的对齐深水区。
- 契约现状：末节 §2.48；音频先例 §2.26 `getAudioChapterMedia`（4 方法节）含 `lyric` 字段。

### 3.1 弹幕数据链三条路评估

**路线 a：新节 `getVideoChapterMedia`（对齐音频 §2.26 全套）**
- 形态：§2.49「视频播放」新节，`getVideoChapterMedia(bookUrl, chapterIndex) → JSON{chapterIndex,title,mediaUrl,url,isVolume,fromCache,danmaku?,sourceUrl}`（字段照抄 AudioChapterMedia，lyric→danmaku）
- Rust 工作量：写侧（get_content 捕获 sub→落 chapter.variable，1 处改动）+ 读侧（新 video_api.rs 克隆 audio_api.rs 结构 ~250 行）+ 把 Dart 侧取址/解析逐步收进 Rust（mediaUrl 由 Rust 直出）
- 契约：新节 +1 方法（后续连播/进度再扩）
- 优点：一次把视频取址链拉齐到音频架构水准，Dart 侧 resolveVideoPlayTarget 的 URL 判定杂质风险（toast/桥接污染，utils :271-276 兜底逻辑暗示的脆弱性）可逐步下沉 Rust
- 风险：中——牵动 Dart 现有取址链改造，超出弹幕单项范围

**路线 b：独立 FFI `getVideoDanmaku`（推荐首批）**
- 形态：§2.49 新节 +1 方法：`getVideoDanmaku(bookUrl, chapterIndex) → Option<String>`（读 chapter.variable `danmaku` 键；大变量文件缺位时对 ≥10000 场景返回 None 并登记边界）；**写侧同样必须做**（get_content 对 VIDEO 书捕获 sub→JSON 合并写入 chapter.variable）——「只加 getter 不补写侧」是无米之炊
- Rust 工作量：写侧 ~30-60 行（fetcher 一处 + DB 合并写）+ 读侧 ~80 行（含 danmaku_from_variable，照抄 lyric_from_variable）+ video_state 接线可选
- 契约：新节 §2.49 +1 方法（若顺带做直链进度见 B4，+2 方法可选）
- 优点：最小增量、不动既有取址链、Dart 播放链零改动、与音频 lyric 字段模式完全同构（评审可参照 §2.26 先例）
- 风险：低；唯一边界 = ≥10000 字符大弹幕（原版存文件、我方无对应物）——**契约条目须明示该边界并交用户裁决**（选项：v1 截断/不落库并登记；v2 补文件存储 FFI）
- 路线 a/b 可串联：b 先行（弹幕最小闭环），a 后续按音频架构统一时升级

**路线 c：Dart 直抓（否决）**
- Dart 无 subContent 规则、无书源响应体上下文；重抓章节页+重跑规则 = 解析业务复制进 UI 层，直接违反「UI 层不含业务逻辑」红线（AGENTS.md:49）；且与 Rust 已完成提取重复请求。**不可行。**

**a 变体否决说明**：把 §2.9 `getChapterContent` 返回 String 改 JSON 加字段 = 破坏性契约变更，波及全部阅读/搜索/缓存调用方，成本收益不成比例，否决。

### 3.2 悬浮窗

- **需要平台通道：是。** 对齐原版形态的 Android 原生路线：① manifest 加 `SYSTEM_ALERT_WINDOW` + `canDrawOverlays` 检查与设置页引导（对齐 VideoPlayService.kt:206-211）；② 新建前台服务承载 WindowManager overlay（TYPE_APPLICATION_OVERLAY）；③ **播放器承载是主要技术风险**：video_player 插件 texture 归 Flutter engine，不能直接进服务 overlay——需服务内自建 Media3 ExoPlayer（surface 直挂）或 VirtualDisplay 方案，建议实施前 0.5 天 spike 定案。
- **可复用**：`PlaybackForegroundService`（flutter_legado/android/.../PlaybackForegroundService.kt:29 起，mediaPlayback 前台服务骨架+通知构建）与 `MediaSessionBridge`（MediaSession+焦点+媒体键，active 单例，MediaSessionBridge.kt:41-49）——但 active 为单 session 设计，音频/视频双服务并存需扩为多 session 或视频单独持桥；原版音频（ReadAloudService）与视频（VideoPlayService）本就是两个并行服务。
- 可跨窗口转移播放进度/位置：方法通道需 open/close/state/seek/position 等 5-8 个方法（Dart→Android）+ 服务 300-500 行 Kotlin。
- **PiP 简化路线**（enterPictureInPictureMode）：工程量小一个量级、无需悬浮窗权限，但**原版没有 PiP**、用户可见形态不同（系统 PiP 窗 vs 自绘可拖悬浮窗）——按重构红线，未经用户裁决不得以 PiP 替代。
- iOS/桌面：无对等形态（原版也仅 Android），登记不支持。

### 3.3 前台服务与既有 PlaybackForegroundService 关系

- **建议新建 `VideoPlayService`（Kotlin），不共用音频服务**：原版即两服务并行（NotificationId 108 vs 音频独立 id）；通知/MediaSession 代码可复制泛化（通知文案测试 PlaybackNotificationTextsTest.kt 已有可扩展）。共用单服务会让「听书后台 + 视频悬浮窗」并发场景的 session/通知归属纠缠，原版无此耦合。
- `VideoPlay` 单例核心逻辑已在 Rust video_state.rs 预建模（§2.5），服务只做表现层。

---

## 四、任务 4：分批实施建议

排序原则：依赖（B2 依赖 B1 数据链；B3 独立但平台风险最大）+ 风险（先小后大）+ 用户价值（弹幕是视频域第一可见缺口）。

### B1：弹幕数据链（Rust + 契约，离线可做）
- 做什么：契约先行冻结 §2.49 `getVideoDanmaku(bookUrl, chapterIndex) → Option<String>`（+1 方法，附 ≥10000 大弹幕边界裁决项）；Rust 写侧（`merge_sub_content_into_body` 改造：VIDEO 书把 sub 经 `BookChapterRepository.update` 合并进 chapter.variable `danmaku` 键，<10000 生效）+ 读侧 video_api（照抄 audio_api 模式）+ video_state.rs DanmakuSource 接线（可选）；fixture XML 单测。
- 为什么先：一切弹幕 UI 的前提；纯 Rust+单测，MuMu 网络档不可用也不影响（cargo test 离线绿）。
- 规模：Rust 1-2 人日 + 契约 0.5 人日。
- **需用户裁决：是（契约冻结是硬规矩 AGENTS.md:45；大弹幕存储边界一并呈报）**。
- 离线：✅（单测用 fixture，不依赖真实源）。

### B2：弹幕渲染 UI（Dart，fixture 离线开发 + 真机验证）
- 做什么：B 站 XML→弹幕对象解析（放 Dart utils 或由 Rust 下发结构化，随 B1 契约定型；XML 解析若认定属数据解码放 Dart 有 video_play_utils 先例，若认定属业务放 Rust——**建议在 B1 契约条目里一并裁决**）+ Canvas 自绘弹幕层（滚动/顶部/底部 3 类、5 行上限、防重叠、描边、颜色字号，对齐 §1.1 协议）+ 开关按钮（_buildControlBar 同排）+ seek/暂停/倍速/全屏切换同步（对齐 VideoPlayer.kt:199-209/156-174/135-141/456-490）。
- 为什么：B1 数据到位后弹幕即为纯 UI 工程；自绘引擎可先用录制/fixture 弹幕离线开发。
- 规模：Dart 3-5 人日（自绘弹幕引擎是主要成本）。
- **需用户裁决：解析归属一项（小）；渲染形态零裁决（完全对齐原版）**。
- 离线：开发 ✅（fixture）；验收需真机 + 真实 B 站弹幕源（video_sources_9.json 中含弹幕类源则用之，Active 计划 :625 素材需求已列「可选 B 站弹幕源」）。

### B3：悬浮窗（Android 平台工程，需真机）
- 做什么：0.5 天 spike（服务内 Media3 直挂 vs VirtualDisplay 定案）→ VideoPlayService（overlay+拖动贴边+比例适配+通知+自动连播）→ SYSTEM_ALERT_WINDOW 权限引导 → Dart 入口按钮 + defaultFloatWindow 设置接线 → 悬浮窗↔全屏互斥与进度转移。
- 为什么放后：平台风险最大（overlay 权限在 MuMu 上可能受限需实测；texture 承载方案未定）、与弹幕无依赖。
- 规模：3-5 人日 + 真机验证。
- **需用户裁决：是（若考虑 PiP 简化路线必须用户点头；纯对齐路线只需常规开工确认）**。
- 离线：❌（需真机验证悬浮窗权限与窗口行为）。

### B4：小项收尾（零裁决，离线）
- 做什么：① 直链模式进度记忆（对齐 video_pos_：键 `video_pos_<url>`、20 天 TTL——复用 Rust CacheRepository 模式，参照 audio_api.rs:49-72 `get_audio_progress/save_audio_progress` 先例 +2 FFI 方法，或挂 §2.16 缓存管理现有通用方法则零契约，需实施批核对）；② 播放完成自动下一集（监听 isCompleted→_switchChapter(1)，边界「已播完」toast 对齐 :477-489）；③ 长按倍速手势（longPressSpeed 设置已有）；④ 锁屏手势（可选，优先级最低）。
- 规模：1-2 人日。
- **需用户裁决：直链进度若需新增 FFI 则契约 +1~2（小额冻结）；其余否**。
- 离线：✅。

### 验证矩阵速查

| 批次 | 离线（无网无真机） | 模拟器 | 真实视频源 |
|---|---|---|---|
| B1 | ✅ cargo test fixture | — | — |
| B2 | 开发 ✅（fixture 弹幕） | 部分 | 弹幕源验收需真机+真实源 |
| B3 | ❌ | MuMu（overlay 权限需实测） | 需要 |
| B4 | ✅ | ✅ | 直链进度可用任意源 |

---

## 五、未找到/待验证清单（如实登记）

1. **投屏**：原版 app 模块未找到 Cast/DisplayManager 相关实现（rg 无命中）——原版无此能力，我方不提。
2. **弹幕字号/透明度设置 UI**：原版不存在（仅固定 1.0f/无 alpha 设置），我方禁止新增。
3. **Rust 大变量文件存储等价物**：未找到（rg `RuleBigDataHelp/10000/big_variable` 无业务命中）——B1 契约须显式登记边界。
4. **video_player 插件对本地 MPD 文件的协议解析深度**：既有实现在非凡源真机通过（P4-3 记录），未做更多协议面测试——维持现状不扩测。
5. **video_sources_9.json 中是否含 B 站弹幕源**：抽查首个源（奈飞工厂）为影视聚合源；9 源逐一核验留待 B2 开工时进行（本报告未逐源判别 subContent 规则分布）。
6. MuMu 模拟器对 `Settings.canDrawOverlays` 的支持情况：未实测（设备档状态以 AGENTS.md:70-74 时效性说明为准）。

---

编写者：调研代理（ZCode）｜ 2026-10-05
