# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.36] - 2026-08-12

### 修复（视频源误进漫画 / type=0 MacCMS 分流与播放，[UI]）

对照原版 `BookInfoActivity.startReadActivity`（`book.isVideo` → VideoPlayer，绝不进 ReadManga）与设备导出源。

1. **根因**：非凡资源网等「影视频源」在库里 `bookSourceType=0`（MacCMS），开读按文本处理；旧逻辑仅在 `typeBits==0` 时补书源类型，抽图启发式可误伤；用户见漫画页「暂无图片」。
2. **分流**：`BookOpenUtils.resolveTypeBits` — 显式 type 1–4 优先；type=0 时 MacCMS/`vod_play_url`/`影视频源`+播放特征 → `BookType.video`，**优先于**抽图提升；书架/详情/离线缓存共用。
3. **播放**：`resolveVideoPlayTarget` 正文为空或 `#EXTM3U` 清单时回退 `chapterUrl`；`startBrowser` 对流媒体 URL 跳过外开；`looksLikeImageUrl` 排除 m3u8/mp4。
4. **验证**：单元测试（非凡启发式 / 伪七猫 type=4 / 必应漫画仍升 comic）；emulator-5558 端到端（VideoScreen + 可播/缓冲态）。

编写者：Reasonix ｜ 2026-08-12

## [2.0.35] - 2026-08-12

### 修复（书源 JS `all` / VideoScreen 生命周期 / Array(0x…) 正文，[Rust]+[UI]）

对照原版 `AnalyzeRule.evalJS` 绑定、`JsSourceEngine.normalizeJsResult`、Riverpod InheritedWidget 约束。

1. **`all is not defined`（QuickJS 严格模式）**
   - 根因：书源常用 `all = JSON.parse(result)` 等裸赋值；Rhino 非严格可写，QuickJS eval 严格模式抛 ReferenceError。
   - 修复：`execute_js_rule` prologue 预声明 `var …, all`（与既有 `d/data/list…` 同策略）。

2. **VideoScreen `initState` 过早读 Provider（2.0.34 回归）**
   - 根因：`_loadBookVideo` 在 `initState` 内调用 `ProviderScope.containerOf(context)`。
   - 修复：书籍模式改到 `didChangeDependencies` 调度；直链模式仍可在 `initState` 启动。

3. **正文/详情刷 `Array(0x…)`**
   - 根因：QuickJS 对 Array/Object 降级 `format!("{:?}", val)`；原版 Scriptable 走 `JSON.stringify`。
   - 修复：引擎 `result_to_string` 对对象/数组 `json_stringify`；无 `$[*]` 后缀时展开 JSON 数组为多元素（对齐 NativeArray）。

4. **验证**
   - Rust：`test_js_rule_predeclares_all_*` / `test_js_rule_expands_json_array_*` / `test_eval_array_object_normalized_to_json` / `$[*]` 后缀不误展开。
   - 设备：emulator-5558 安装验收。

编写者：Reasonix ｜ 2026-08-12

## [2.0.34] - 2026-08-12

### 修复（视频源播放链路：复合 URL / header / MPD / subContent，[UI]+[Rust]）

对照原版 `VideoPlay.kt` / `VideoPlayerActivity` / `BookContent` isVideo（3.26080322）。

1. **Flutter 播放器接入 `video_play_utils`**
   - `video_screen` 完整走 `resolveVideoPlayTarget`：相对 URL 绝对化、复合 `url,{json}` UrlOption header、书源 header 合并、默认 UA/Referer、MPD 落临时文件以 file 播放。
   - 卷标题跳过（`findPlayableChapterIndex` / 上一集下一集）；错误重试当前章；进度写回保留。

2. **Rust `web_book` 视频 subContent**
   - **根因**：FFI 曾把副内容统一 `\n` 拼进正文；原版视频走 `putDanmaku`、音频 `putLyric`，不污染播放链接。
   - **修复**：`is_media`（AUDIO/VIDEO）不再合并副内容进正文；文本源仍追加。

3. **验证**
   - 单测：`video_play_utils_test` + Rust `merge_sub_content_skips_media_to_protect_play_url`。
   - 设备：emulator-5558 用真实视频源（如「伪七猫」）对照原版验收。

编写者：Reasonix ｜ 2026-08-12

## [2.0.33] - 2026-08-11

### 修复（必应漫画 type=0 正文刷 `<img>` HTML，[UI]）

1. **取证（emulator-5558）**
   - 书源 `https://www.biyingmh.com`：`bookSourceType=0`，`ruleContent.content=.img@img@html`，`imageStyle=FULL`，无 header / imageDecode / coverDecodeJs。
   - 正文已抽出明文 JPG（如 `jjmhw6.top/.../1135571.jpg`）；桌面直连与带 Referer 均为 200 + `FFD8` JPEG，**非**防盗链/密文问题。
   - 书籍位标记 `notShelf|text` → 文本阅读器；排版引擎不渲染 `<img>`，用户看到裸标签。

2. **修复**
   - `BookOpenUtils`：识别「抽图 HTML」正文规则，将 type=0 源提升为 `BookType.image`，详情/书架开读走漫画阅读器；入库回填媒体位。
   - 文本阅读器兜底：`isImageDominantContent` 时用纵向图片列表（FFI/`CachedNetworkImage`），避免再刷 HTML。

3. **验证**
   - 单测：必应规则提升路由、jjmhw6 样例图片主导判定、图文混排不误伤。
   - 复测：必应漫画搜书 → 详情开始阅读 → 应进漫画纵向出图，不应再显示 `<img src=...>` 文字。

编写者：Reasonix + UI ｜ 2026-08-11

## [2.0.32] - 2026-08-11

### 修复（搜索/列表封面解密卡顿，[UI]）

1. **卡顿根因**
   - 上一轮为 51 等源接通 `coverDecodeJs` → `fetchImageWithDecode` 后，搜索列表对**每条结果**立即并发 FFI 解密，无结果缓存、无并发上限、屏外项不取消；漫画源封面密且多，滑动极易卡顿。

2. **修复（对齐原版 Glide 列表节流体感）**
   - 新增 `CoverDecodeLoader`：解密结果 LRU（64）、全局并发上限 3、同 URL in-flight 去重、dispose 取消排队票证。
   - `BookCover`：无 `coverDecodeJs` 仍走轻量 `CachedNetworkImage`（`memCacheWidth` 缩略）；有解密则经 Loader；`Image.memory` 使用 `cacheWidth`。
   - 书源 origin → patched JSON 缓存，避免每张封面重复 `getBookSources`。
   - 搜索 `ListView`：`addAutomaticKeepAlives: false`，滚出可视区 dispose 并取消排队。

3. **验证**
   - 单测 `cover_decode_loader_test`（缓存/并发/取消排队）。
   - 请在 emulator-5558 用漫画源搜列表滑动验收。

编写者：Reasonix + UI ｜ 2026-08-11

## [2.0.31] - 2026-08-11

### 修复（搜索分组粘性 + 同书聚合 + `class.` 选择器，[UI]+[Rust]）

对照原版 3.26080322「漫画书源 / 一人之下」：聚合顶条约 **13** 源；重构引擎精确书名曾约 **10~11**，UI 却常搜全量 968 源且按源分行，体感「结果少/源少」。

1. **Flutter 漫画分组粘性（P1）**
   - **根因**：选分组用 `clearGroupFilter`+`toggleGroup` 两步写状态，并发 search 可能读到空分组而回退全量；搜索范围未持久化。
   - **修复**：`selectGroupExclusive` 原子单选；`searchScope`/`searchGroup` 读写对齐原版；芯片展示真实分组名，清除后自动重搜。

2. **同书多源聚合（P1）**
   - **根因**：`applyPrecisionSearch` 只分桶、不 `addOrigin`；徽标显示书源名而非同源数。
   - **修复**：按书名+作者聚合 `origins`，桶内按 `originsCount` 降序；多源徽标显示数字（对齐 `bv_originCount`）。

3. **引擎 `class.xxx` → 空列表（P0 引擎）**
   - **根因**：原版 `class.comics-card` 走 JSoup `getElementsByClass`；Rust 原样当 CSS → 匹配「标签 class」永远 0 命中 → 包子/爱看等大量 `search:empty`。
   - **修复**：`HtmlParser` 将 `class./tag./id.` 转为 `.xxx` / `tag` / `#id`。
   - **探针（漫画组 83 源，「一人之下」）**：精确书名源 **10→17**（超原版聚合 ~13）；有结果源 **20→34**；总命中 **317→583**；爱看 0→30、包子优+ 0→88。

4. **仍差**
   - 包子漫画（优）本轮仍 0（站点 SSL/可达性）；快看 TOC `__NUXT__`；部分 `@js`/`jsLib` 源仍空。

编写者：Auto ｜ 2026-08-11

## [2.0.30] - 2026-08-11

### 修复（搜索相对 URL 绝对化 + 目录 `<js>$[*]` 链拆解，[Rust] 为主）

取证（本机新建 emulator-5558 + 设备导出 sources.json 89 个 type=2）：批量搜索成功率仅 12/89，失败几乎全是 `search:empty`；相对 searchUrl 占 41/89。

1. **搜索结果过少（引擎级）**
   - **根因**：① `AnalyzeUrl::parse`/`parse_with_js` 未使用 `baseUrl`，相对 searchUrl（`/search?...`、`statics/...`）原样发出；② 无 path 的 host 拼接相对路径时 `rfind('/')` 命中 `://`，拼成 `https://statics/...` 假域名（拷贝漫画等）。
   - **修复**：`parse` 读取 `variables.baseUrl`；`get_absolute_url` 对「仅域名 base」正确追加路径。
   - **仍未对齐**：站点失效/空结果、page=1、个别源 JS（如快看 `__NUXT__`）仍会少结果；分组请选「漫画书源」（约 67 源），「图片书源」组本身仅约 4 个源。

2. **「暂无章节」（51 等 `<js>+$[*]` 目录）**
   - **根因**：`get_elements` 把 `<js>...</js>\n$[*]` 拆成 Js+Extract，对 HTML 跑 `$[*]` → JSON parse error，再被 `unwrap_or_default` 吞成 0 章；站点已无「目录」脚本时本应走 btn-read 回退。
   - **修复**：`<js>` 规则与 `get_strings` 一样走单步路径；目录解析错误不再静默；空标题+有 URL 仍保留章节；`book.name` 取首行。
   - **探针**：51 TOC 从 0→1（站点侧仅露出开始阅读章）；神漫画 TOC=61。

3. **`{{$.comic_id}}` 双花括号**
   - **根因**：丁斐等 `bookUrl` 用 `{{$.id}}`，只剥内层留下 `{106209}` → TOC HTTP 422。
   - **修复**：`process_inner_rules` 优先替换双花括号形式。

编写者：Reasonix ｜ 2026-08-11

## [2.0.29] - 2026-08-11

### 修复（51封面 + 漫画搜索/目录/正文引擎缺口，[Rust]+[UI]）

1. **51漫画封面不显示**
   - **根因**：书源 `coverDecodeJs`（AES/CBC/PKCS5Padding）未接入；`BookCover` 直连 `CachedNetworkImage`，密文进 `FlutterImageDecoder`（logcat `Failed to decode image`）。正文 `imageDecode` 已通但封面走另一套规则。
   - **修复**：`BookCover` 按 origin 加载书源，将 `coverDecodeJs` 映射为既有 `fetchImageWithDecode`；书架/搜索/详情/网格传 `sourceOrigin`。

2. **搜索几乎只有三站出结果**
   - **根因（引擎级）**：① 神漫画等 `bookUrl`/`coverUrl` 模板 `https://...?id={$.comic_id}` 内嵌替换后仍当 JsonPath 求值 → 空 URL 回退书源主页；② `@put:` / `extract@js:` / `##` 替换缺失致大量规则失败；③ Flutter 按「书名|作者」去重吞掉同名多源。
   - **修复**：内嵌 `{$.…}` 替换后返回字面量；AnalyzeRule 补 `@put` 剥离、`@js` 链、`##` 替换；去重键改为 `书名|作者|origin`。
   - **验证**：Rust 探针 神漫画/Nhentai/51/快看/COLA 单源搜索；**未声称与原版全网数量完全一致**（站点挂掉、page=1、其它 JS 缺口仍可能少结果）。

3. **神漫画 / Nhentai 目录与正文**
   - **核实**：51 目录/正文此前已通（本探针个别书详情页已无「目录」脚本属站点侧）；神漫画/Nhentai 为引擎缺口。
   - **根因**：神漫画 `chapterName` 含 `@put`、`chapterUrl` 为 `$.id@js:…`；正文 JS 需 `chapter.index`/`book.totalChapterNum`；Nhentai 正文 `//script@js:match…`。
   - **修复**：同上规则链 + 正文注入 chapter/book；探针：神漫画 TOC=61 CONTENT>2k；Nhentai TOC=1 CONTENT>7k。

编写者：Reasonix ｜ 2026-08-11

## [2.0.28] - 2026-08-11

### 修复（51漫画图片全失败：jniLibs 未带上 createSymmetricCrypto/NoPadding，[Rust]+[UI]）
- **设备证据（emulator-5558 / 2.0.27+29）**：正文 40 张 `pic.xmbvxj.cn/...jpeg?auth_key=…` 已解析；logcat `FlutterImageDecoderImplDefault: Failed to decode image` / `Input contained an error` 刷屏。书源 `ruleContent.imageDecode` 为 AES/CBC/NoPadding + `java.createSymmetricCrypto(...).decrypt(result)`；raw 下载 magic=`4FE8…`（密文），桌面同 key/iv 解密后 `FFD8` + PIL JPEG 1280×1842。
- **根因**：2.0.26 已修 `createSymmetricCrypto` 对象桥与 `AES/CBC/NoPadding`，但 **5558 安装包内 `liblegado_ffi.so` 仍是 16:30 旧产物**（缺 `AES/CBC/NoPadding` / `decrypt input must` 等符号）；Dart 版本号升到 2.0.27 却未重编/同步 Android jniLibs → 实机 decrypt 仍失败，密文进解码器。
- **修复**：按 `rust/scripts/build-android.ps1` 重编 x86_64/arm64 `liblegado_ffi.so`（quickjs）并同步 jniLibs；漫画阅读器有 origin 时禁止 `CachedNetworkImage` 直连密文 CDN。
- **回归**：设备密文夹具 `tests/fixtures/51manga_page_cipher.bin` + 离线 51 imageDecode；桌面 `fetch_image_with_decode` 实网探针 JPEG。

编写者：Reasonix ｜ 2026-08-11

## [2.0.27] - 2026-08-11

### 修复（漫画/视频空目录自愈 + 51漫画链路取证，[UI] 为主 + [Rust] 回归测）
- **根因（51漫画「看不到正文/图」）**：设备 DB 中该书 `chapters=0` 且 `bookType=notShelf|image`。详情页对未入书架书只内存取目录不落库；「开始阅读」进 `ReaderComicScreen` 仅 `getChapters`，**不像文本阅读器 `ReaderNotifier` 那样在空目录时 `refreshToc`** → 永远「暂无章节」，后续 imageDecode 链路根本走不到。Rust 侧对同一书源实测：搜索 50 条、TOC 回退 1 章、正文含图 URL、AES/CBC/NoPadding imageDecode 出 JPEG——解密本身在 2.0.26 已通。
- **修复**：[UI] `ReaderComicScreen` / `video_screen` / `audio_notifier` 空目录自动 `refreshToc`；`book_info_screen._openReader` 对非文本路由开读前补拉并落库目录。
- **回归**：legado-ffi 离线 51 规则 AES imageDecode；Flutter `reader_comic_empty_toc_test`（空目录→refreshToc→出图）。
- **搜索差距（尚未声称对齐）**：单源 51 搜索 Rust 可出约 50 条；全网差距仍可能来自（1）仅 page=1、无原版翻页；（2）Flutter 按「书名|作者」去重且未 `addOrigin` 合并多源；（3）961 启用源中部分 JS 规则在 QuickJS 失败被静默跳过。需用户用同一关键词对比「仅 51漫画」与「全源」再继续。
- **书源侧说明**：当前 51acgs 详情页脚本已无「目录」字样，规则走 `.btn-read` 回退（单集「全集」）——与原版同一规则语义，非重构独有缺陷。

编写者：Reasonix ｜ 2026-08-11

## [2.0.26] - 2026-08-11

### 修复（对称加密 JS 对象桥 + aesBase64Decode + 图片魔数校验，[Rust]+[UI]）
- **根因 B（漫画能进正文但图全挂）**：`java.createSymmetricCrypto` 此前只返回 `"AES/CBC"` 字符串，书源 `cipher.decrypt(result)`（如 51漫画 AES/CBC/NoPadding imageDecode）恒失败 → 密文进 `Image.memory` → `Invalid image data` / FlutterImageDecoder 刷屏。修复：返回含 `decrypt`/`decryptStr`/`encrypt*` 的对象；core 补 `AES/CBC/NoPadding`；`fetch_image_with_decode` 在有 imageDecode 时校验 JPEG/PNG/GIF/WEBP 魔数，失败显式报错
- **根因 A（多数图片源无目录/正文）**：缺 `java.aesBase64DecodeToString`（全网漫画等 init/toc/content AES 解密）。补齐宿主桥；另：个别书源 `bookSourceUrl` 误写为 `…/@遇知` 属源数据问题，会 404
- **UI**：解密结果魔数校验，拒绝把密文写入预加载缓存
- 测试：legado-js createSymmetricCrypto/imageDecode/aesBase64；legado-core NoPadding；Flutter looksLikeImageBytes
- 实现：Reasonix（Rust/UI）

编写者：Reasonix ｜ 2026-08-11

## [2.0.25] - 2026-08-11

### 修复（书架 BookType 分流 + 漫画复合 URL/预加载 + imageDecode 新引擎 + 视频相对 URL/重试/进度 + 媒体 MPD 钩子，[Rust]+[UI] 双轨）
- **书架/详情 BookType 分流统一**（[UI]）：抽出 `BookOpenUtils`（位标记→路由：video/audio/image/text/webFile），书架已读直开与书详情「开始阅读」共用，避免分流复制漂移；补齐视频路由 `/video`
- **复合图片 URL 完整抽取**（[Rust]+[UI]）：`HtmlFormatter` / `comic_image_utils` 正则对齐原版——`src="url,{"headers":{...}}"` 引号内嵌 JSON 双引号不再截断为 `...webp,{`；漫画阅读器预加载与正式渲染统一走 FFI（复合 URL / imageDecode / 书源 header）
- **imageDecode 每次新引擎 + Referer 兜底**（[Rust]）：同源多图连续 decode 勿复用 `pool_engine`（顶层 const/let redeclaration → 退回密文）；jsLib 可选降级；`default_referer_from_source_url` 修正无路径域名不被截成 `https:`
- **视频相对 URL / 重试 / 进度**（[UI]）：章节正文相对路径以章节 URL 绝对化；错误「重试」按 book/直链正确重试当前章；退出/切章写回 `durChapterIndex`/`durChapterPos`；首帧 loading 避免 late controller 未初始化
- **媒体 MPD 钩子**（[Rust]）：视频/音频正文跳过 HTML 净化（MPD XML 以 `<` 开头会被剥标签破坏）；经 `VideoPlayerState::normalize_content` 识别空正文/Url/Mpd，清单原文透传供 UI 写临时文件播放
- 测试：新增复合 URL / BookOpen / 视频绝对化 / MPD 透传单测；5558 冒烟验收（v2.0.25+27）
- 实现：Reasonix（Rust/UI）；协调/交付：Auto
- 已知书源侧：favcomic 图床 NXDOMAIN——图片实测请用其他可用漫画源

编写者：Reasonix（实现）/ Auto（协调交付）｜ 2026-08-11

## [2.0.24] - 2026-08-11

### 修复（规则 JS 执行引擎池复用 const redeclaration，[Rust] 轨）
- **模拟器实测仍无目录的差异根因**：Rust 网络测试通过但 app 失败——进程内**引擎池复用**。书源规则常用顶层 `const/let` 声明（51漫画 chapterList `const scripts`），QuickJS 同一引擎第二次执行同一规则必报 `redeclaration of 'scripts'`（全局词法环境残留）。测试每次新进程（干净池）通过；app 内多次刷新/进详情页第二次执行即失败 → 目录空
- 修复：`QuickJsExecutor.execute_js` 每次执行创建**独立新引擎**（用完即弃），对齐原版 Rhino 每次 evalJS 新作用域语义；移除 QuickJsExecutor 的 pool 字段（global_pool/pool_engine 保留供 imageDecode 等一次性 eval 场景）
- 测试：legado-ffi 264/264 全过；5556/5558 冒烟 6/6（v2.0.24+26）

## [2.0.23] - 2026-08-11

### 修复（漫画源目录「暂无章节」最终根治，[Rust] 轨）
- **51漫画真实链路实测打通**（搜索→目录→正文），四层根因：
  ① QuickJS eval 严格模式禁止裸赋值：书源规则 `d = c ? ... : [...]`（未声明变量赋值）抛 ReferenceError（原版 Rhino 宽松模式允许）。修复：execute_js_rule prologue 预声明常见裸赋值变量（`var d/data/json/list/arr/obj/tmp`，避开书源可能 const 声明的 scripts/c/item 等防冲突）
  ② `get_elements` 对 `<js>` 规则误路由：`resolve_rule_type` 把 `<js>` 前缀判为 Auto/Css → 走 HTML 解析器 → 目录 0 章。修复：get_elements 开头显式识别 `<js>` 转 get_strings
  ③ `<js>...</js>\n$[*]` 复合规则：`</js>` 后 JSONPath 后缀被忽略，JS 返回的 JSON 数组未拆解（51漫画 chapterList 用 `JSON.stringify(d)` + `$[*]`）。修复：get_strings 的 `<js>` 分支对 `$[...]` 后缀逐元素 JSONPath 拆解
  ④ java 桥 `@attr` 链：`.btn-read@href` 需取 href 属性（对齐原版 AnalyzeByJSoup lastIndexOf('@') + getResultLast），非 CSS 选择器。修复：html_parse select_with_attr 拆分 selector@attr + @text 语义
- 实测：51漫画 refresh_toc 出章节（url=/comic/5957/chapter/18465）、正文 5395B 含真实图片 URL
- 测试：legado-parser 182/182、legado-js 471/471、legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.23+25）

## [2.0.22] - 2026-08-11

### 修复（漫画源目录「暂无章节」根治：java HTML 解析桥 + book 绑定，[Rust] 轨）
- **「暂无章节」根因⑥**：漫画书源目录/正文规则大量使用原版 JsExtensions 的 HTML 元素桥 `java.getElement(css)` / `java.getString(css, html)`（51漫画 chapterList 用 `<js>Array.from(java.getElement("script"))...</js>` 提取目录 JSON、快看/爱优漫等依赖），重构版 java 命名空间仅有工具函数 → ReferenceError → 目录解析空
- 修复：新增 `legado-js/src/host_api/html_parse.rs`——`getElement`/`getElements` 返回元素对象数组（`html()`=innerHTML / `text()` / `toString()`=outerHTML / `attr(name)`，对齐 JSoup Element），`getString`/`getStrings` 取文本；内容源读 `globalThis.src`（execute_js_rule 注入），getString 第二参 mContent 可覆盖；注册到 java 命名空间（getElement 等为 AnalyzeRule 方法语义，不挂裸全局）；legado-js 新增 scraper 0.22 依赖
- 修复②：`web_book.get_chapters` 目录解析未注入 `book` 绑定（51漫画规则 `book.name`）——从 ruleBookInfo.name 提取书名注入
- 测试：legado-js 471/471（新增 html_parse 3 测试）、legado-ffi 264/264；5556/5558 冒烟 6/6（v2.0.22+24）

## [2.0.21] - 2026-08-11

### 修复（漫画站图片复合 URL `url,{json headers}` 支持，[Rust]+[UI] 双轨）
- **图片不显示根因⑤**：favcomic.com 等漫画书源正文图片 URL 为原版复合格式 `url,{"headers":{...}}`（内嵌 User-Agent/Referer/x-requested-with 防盗链，对齐原版 AnalyzeUrl.kt analyzeUrl 切首个 `,` 前为 URL、后部 JSON 解析为 headerMap）。此前 CachedNetworkImage 直连将整体当 URL 请求 → `Invalid image data`（模拟器崩溃日志实测）
- 修复：[Rust] `fetch_image_with_decode` 新增 `split_composite_image_url` 拆分复合 URL 与内嵌 headers（与书源 header 合并，内嵌优先）；[UI] `reader_comic_screen` 图片统一走 FFI 下载（Rust 支持复合 URL + 防盗链 + imageDecode，无规则原样返回 bytes），`_bookSource == null` 保留 CachedNetworkImage 兜底
- 实测：Rust 全量 264/264（新增 test_split_composite_image_url）；flutter test 1153/1153、analyze 0 error；5556/5558 冒烟 6/6

### 已知书源侧问题（非代码缺陷）
- favcomic.net 图床 `ccdeoo.ykxbo.cn` 已 NXDOMAIN；favcomic.com 域名连接失败（站点失效）——图片源请以其他可用漫画源验证

## [2.0.20] - 2026-08-11

### 修复（书源 jsLib 加载失败降级，[Rust] 轨）
- **正文全空回归根治**：favcomic 等漫画/视频书源的混淆 jsLib 依赖 Android Rhino 特有全局（`Packages` Java 桥、`decode` 等），QuickJS 无法完整执行（实测 eval 报 `decode is not defined`）。v2.0.19 将 jsLib 求值失败从静默改为**报错阻断**，导致所有带 jsLib 书源的正文解析直接失败 →「能搜到但正文图片/视频无法显示」（全局回归）。修复：jsLib 求值失败**降级为 eprintln 警告并继续执行**——正文规则多为不依赖 jsLib 的纯正则/CSS（favcomic 正文 `<js>src.match(...)` 提取出完整 2966B 图片列表），阻断会误伤；后续 JS 规则引用缺失函数时仍自然抛 ReferenceError 可排错
- 实测（真实站点，Rust 网络测试）：favcomic 搜索→目录→正文恢复 2966B（此前 jsLib 阻断时 Content empty）；legado-ffi 263/263 全过；5556/5558 冒烟 6/6

### 已知书源侧问题（非代码缺陷）
- favcomic 图床域名 `ccdeoo.ykxbo.cn` 已 NXDOMAIN（书源写死的域名失效），该源图片显示需书源更新或换源

## [2.0.19] - 2026-08-11

### 修复（漫画/图片源 imageDecode 解码 + JS 注入严格模式根治，[Rust]+[UI] 双轨）
- 漫画/图片站图片无法显示根因③（**imageDecode 解密缺失**）：favcomic 等漫画站图片 bytes 经站点专用加密，书源通过 `ruleContent.imageDecode`（配合 jsLib）JS 解密后才可显示，重构版仅有字段无执行。修复：Rust 新增 `image_api`（下载图片[书源 header 防盗链+兜底 Referer] → 注入 `result`(Uint8Array)/`src`(URL) 绑定执行 imageDecode JS → base64），`legado-js` 新增 `eval_bytes`（`JsValue::Bytes` 以 Uint8Array 注入/结果读回）；`ffi.rs` frb 模块新增 `fetch_image_with_decode`（上一版误加进已冻结的 `bridge.rs`——该模块 DEPRECATED 冻结新增且 Flutter 无 dart:ffi 绑定调不到，已移除恢复冻结约束）；Flutter `reader_comic_screen` 书源含 imageDecode 规则时走 FFI 解码下载（`Image.memory` 显示，带缓存与重试），无规则时保持直连不回归
- 「搜到书但正文为空」JS 规则执行根因④（**严格模式裸赋值**）：上次将绑定注入由 `var result` 改裸赋值 `result = ...`（规避 jsLib `let/const result` 重复声明），但 QuickJS eval 处于严格模式，裸赋值抛 `ReferenceError: result is not defined` → 全部 `@js:`/jsLib 规则静默返回空（legado-ffi 5 测试失败，即上轮卡点）。修复：改 `globalThis.result = ...`（对齐原版 `ScriptableObject.put` 语义，严格模式合法且不构成重复声明）；jsLib 求值失败不再静默吞（favcomic 正文/imageDecode 引用 jsLib 函数，失败必须可见可排错）
- 修复既有缺陷：漫画阅读器 `_preloadVisibleImages` 在 loading 态访问未 attach 的 ScrollController 抛断言（`ScrollController not attached`），加 `hasClients` 防御

### 测试
- 新增：`image_api` XOR 解码单测 + favcomic 真实站点链路（网络测试，`#[ignore]`）；Flutter `reader_comic_decode_test`（含 imageDecode 规则走解码下载 / 无规则不触发）
- 全量：legado-ffi 263/263、legado-js 468/468、legado-parser 180/180；flutter analyze 0 error、flutter test 1153/1153
- 实机验证：重建 Rust .so（x86_64+arm64-v8a，quickjs）→ 重打包 → 5556 启动无崩溃 UI 完整渲染（书架/发现/订阅/我的）、5558 冒烟 6/6 全 PASS（此前 content hash 不匹配系 APK 内旧 .so 所致，已根治）

## [2.0.18] - 2026-08-11

### 修复（漫画/视频源正文与目录根治，[Rust] 轨）
- 漫画/视频源「正文为空、图片不显示、无法播放」根因①：规则 JS 执行器**零变量注入**——原版 AnalyzeRule.evalJS 注入 result/src/baseUrl/chapter/title/source 等 bindings（AnalyzeRule.kt:893-908），重构版 execute_js_rule 直接执行裸 JS → 视频源 `@js: String(result)` 与漫画源 `<js> src.match(...)` 全部 ReferenceError → 正文空。修复：AnalyzeRule 自动注入 `result`/`src`（=当前内容）/`baseUrl`，新增 `with_js_binding` 注入 `chapter`（`{title}` 对象）/`title`/`source`（web_book 正文解析处传入章节标题）
- 漫画源「目录 0 章」根因②：CSS 规则 `@a` 后缀被误判为**属性提取**（"a" 被当作属性名）而非**标签选择链**——漫画书源 chapterList 常写 `.right_box:nth-child(2)@a`（原版 AnalyzeByJSoup 的 `@` 链末段为标签名时继续选元素）。修复：html.rs 增加常见 HTML 标签名白名单，`@a`/`@div` 等按元素选择链处理，`@href`/`@src`/`@text` 等属性语义不受影响
- 实测（真实站点全链路）：伪七猫影视（视频源）搜索→目录→正文提取 `https://vod1.maowushi.com/.../index.m3u8` ✅；favcomic（漫画源）搜索→目录 8 章→正文 `2966B` 含 `<img>` 图片列表 ✅（书源原规则即可用，无需改书源）

### 测试
- 新增：analyze_rule JS bindings 注入测试（result/src/baseUrl/chapter/title/source 断言）、html `@a` 标签链测试（含 `@href` 属性语义回归）；legado-parser 180/180、legado-ffi 261/261 全过
- 遗留登记：armv7 so 交叉编译失败（NDK 28 链接问题，模拟器 x86_64/真机 arm64 不受影响）

## [2.0.17] - 2026-08-11

### 新增（离线缓存界面，对齐原版 CacheActivity）
- **缺口**：缓存下载全链路（阅读页缓存 → 队列页 → 缓存管理）缺少**离线缓存界面**——原版 CacheActivity 的书籍列表页（bookshelf_screen TODO 登记「CacheActivity 对齐尚缺——缓存管理独立页（书籍列表/缓存进度/单本导出入口）、缓存下载（download_after/download_all）」）
- 新增 **OfflineCacheScreen**（路由 `/offline_cache`）：书架书籍缓存状态列表，每项按原版 `item_download.xml` 三行布局（书名/作者/「已缓存 N/总章节数」）+ 右侧播放/停止下载按钮（原版 iv_download）+ 单本导出按钮（原版 tv_export）；顶栏菜单含**全部缓存**（download_all 0..末章）/ **缓存当前章节之后**（download_after 当前章..末章，原版 sureCacheBook 确认对话框）/ **停止全部下载** / **下载队列**；缓存章节数（listCachedChapterUrls）与进行中任务（cacheDownloadList）2s 轮询实时刷新（对齐原版 EventBus 语义）；点击列表项对齐原版 startActivityForBook（未读进书详，已读进阅读器）；本地书显示「本地书籍」并隐藏下载按钮（原版 isLocal 短路）
- **入口**：书架溢出菜单「缓存导出」替换为「离线缓存」（对齐原版书架菜单 menu_download「缓存/导出」→ CacheActivity），原选书导出对话框迁移为页内单本导出（功能等价：章节标题+已缓存正文拼 TXT 经分享保存）
- 遗留：epub/pdf 导出类型、导出文件夹选择与文件名模板、自定义导出设置、导出进度与 WebDav 仍待 FFI（同 bookshelf 原 TODO 其余项）

### 测试
- 新增离线缓存页 widget 测试 5 个（空态/三行列表与本地书短路/单本下载 download_all 参数/菜单批量下载确认对话框/下载中进度与停止按钮）；flutter analyze 0 error、flutter test 1150/1150 全过

## [2.0.16] - 2026-08-10

### 修复（缓存下载链路根治：真实下载 + 队列页 + 目录图标实时刷新，对齐原版 CacheActivity）
- **根因**：阅读页「缓存」按钮走 `downloadAddTask`——Rust `download_api.rs` 仅内存任务登记**无下载执行**（不抓正文、不写 cached_chapters）→ 目录页云图标永不亮（「无法识别是否已经下载」）；且无下载队列页（CacheSettingsScreen 仅统计/清理，无进度列表）。真正下载的 `cacheDownloadStart/Progress/List/Cancel` FFI 已生成但 Dart 侧零调用
- 修复：① BookApi/RustApi/MockBookApi 封装 4 个缓存下载方法（接通 FFI）；② 阅读页缓存对话框改用 `cacheDownloadStart` 批量任务（真实逐章下载写 cached_chapters，Rust worker 已在 v2.0.14 就绪）；③ 新增**缓存下载队列页**（CacheDownloadScreen，对齐原版 CacheActivity：任务列表/进度条/状态/取消，2s 轮询），路由 `/cache_downloads` + 书籍信息页菜单「缓存下载队列」入口；④ 目录页**云图标实时刷新**（在线书每 2s 轻量轮询 listCachedChapterUrls，对齐原版 EventBus.SAVE_CONTENT 语义——下载进行中图标即时变实心）
- 说明：任务表为 Rust 进程内内存表（重启后任务进度不可恢复，同批登记到 REMAINING_PLAN 遗留项）；下载正文依赖书源正文规则（站点不可用时该章失败计入 failed，不阻断整体）（Reasonix）

### 测试
- 新增缓存下载队列页 widget 测试 2 个（空态/任务列表状态与取消按钮）；cargo test（quickjs）legado-ffi 全量通过（缓存下载写表逻辑已有 test_local_book_batch_download 覆盖）；flutter analyze 0 error、flutter test 1145/1145

## [2.0.15] - 2026-08-10

### 修复（图片源搜索 + 漫画正文图片 + 视频播放，对齐原版）
- 图片书源分组搜索无结果：5 个图片源（爱妹子/Asian Porn Image/爱轻写真/学姐吧/萌图社）中 `@js:` 前缀 searchUrl 与 `{{encodeURIComponent(key)}}` 模板在搜索链路已由 v2.0.14 修复；本版补 **AnalyzeRule 不支持 `<js>` 标签**的核心缺口——规则引擎仅认 `@js:` 前缀，`<js>...</js>` 包裹落入 CSS/Auto 解析返回空（原版 RuleAnalyzer 将两者同视为 Mode.Js，JS 结果直接作为提取结果）。修复：`AnalyzeRule.get_strings` 识别 `<js>...</js>` 包裹并执行 JS（对齐原版 Mode.Js 语义）（Reasonix）
- 漫画正文图片不显示：① 正文/目录/书籍信息/搜索解析链路（web_book.rs 全部 9 处 construct_analyzer 调用点 + parse_content_page / fetch_paginated_content / fetch_sub_content / apply_content_replace_regex）**注入书源 jsLib**（漫画源 ruleContent 大量 `<js>eval(String(Reload('...')))</js>` 引用 jsLib 函数，不注入则 JS 抛错 → 空正文）；② Flutter 漫画阅读器：图片请求带**书源防盗链 header**（CachedNetworkImage httpHeaders，对齐原版 glide getGlideUrl 带 headerMap——CDN 校验 Referer 时无 header 403）；③ 相对图片路径以章节 URL 为 base 转绝对（对齐原版 BookHelp.flowImages getAbsoluteURL）；④ 图片 URL 解析兼容 JSON 数组/逗号列表（解析 img 标签 + 每行 URL 白名单外再补 JSON 数组解析）（Reasonix）
- 视频正文无法播放：① 正文链路 jsLib 注入（同漫画）；② `_extractVideoUrl` 增强——支持 `<iframe>/<video>/<source>/<embed>` 标签 src 提取（视频源 ruleContent 常返回播放器页 HTML，纯正则取首个 URL 会取到无关链接），兜底保持首个 `https?://` URL；③ 播放请求带书源防盗链 header（VideoPlayerController.networkUrl httpHeaders，对齐原版 player.mapHeadData）（Reasonix）

### 测试
- 新增 Rust 测试 3 个：`<js>` 标签 + jsLib 注入正文解析（web_book parse_content_page_with_js_lib）、无 jsLib 降级、js_executor jsLib 注入；cargo test（quickjs）legado-ffi 261 + legado-parser 178 全过；flutter analyze 0 error、flutter test 1143/1143 全过

## [2.0.14] - 2026-08-10

### 修复（Rust 搜索链路，对齐原版）
- 搜索无结果根治（原版可搜到、重构版搜不到）：yckceo 书源包（968 源中 896 个 searchUrl 含 `{{}}` 模板）大量使用 `{{encodeURIComponent(key)}}`（思兔阅读 sto66 等核心源），而 quickjs 宿主**未注册 encodeURIComponent** → 表达式求值失败 → URL 中模板被替换为空串 → 搜索 URL 残缺 → 无结果。修复：
  - `legado-js` 新增 `encode_uri_component`（JS 标准语义：percent-encode 除 `A-Za-z0-9-_.!~*'()` 外全部字符）并注册到 quickjs 宿主（`encodeURIComponent`，java + globals，对齐原版 Rhino 内建）
  - 实测：思兔 `https://www.sto66.com/search/{{encodeURIComponent(key)}}.html` 渲染 `都市` → `/search/%E9%83%BD%E5%B8%82.html`，真实站点 HTTP 200 返回书条目
- 书源 jsLib 未注入模板 JS 执行器（图片/视频/漫画源搜索无结果主因之一）：yckceo 漫画源 searchUrl 大量使用 `<js>eval(String(Reload('...')))` 动态加载与 jsLib 定义的函数（getHosts 等），此前模板执行器不注入 jsLib 且沙箱禁用 eval → URL 构建失败。修复：
  - `QuickJsExecutor` 支持 `with_js_lib`，`construct_analyzer_with_js_lib`/`build_search_url_with_lib` 注入书源 jsLib（每次 JS 执行前先 eval 库，对齐原版 JsSource 语义）；搜索解析与 URL 构建链路接入
  - `EnginePool` 默认沙箱允许 `eval`/`Function`（对齐原版 Rhino 书源信任模型；js_eval 调试端点仍用严格 SandboxConfig::default()，安全边界保留）
  - `build_search_url` JS 路径条件扩展：含 `<js>`/`@js:`/`{{` 任一语法即走 JS 求值（此前 `<js>` 模板落入字面路径未被执行）
- 搜索结果 bookUrl 规则解析为空时回退书源主页（bookSourceUrl，对齐原版 `BookList.kt:282-284` + `AnalyzeRule.kt:369-375`），避免条目无法打开
- 搜索请求头缺 User-Agent 时补充 Chrome UA（对齐原版 `BaseSource.kt:202-204` + `AppConfig.userAgent`；默认 `Legado/1.0` 会被反爬站点拒绝）
- 新增 10 个 Rust 测试（encodeURIComponent 语义×2 + quickjs eval 渲染×2 + jsLib 注入×3 + bookUrl 回退 + UA 补充×2），全量 cargo test（quickjs）：legado-ffi 259、legado-js 468 全过（Reasonix）

## [2.0.13] - 2026-08-10

### 修复
- 图片源/音频源/视频源打不开（分流失效根治）：搜索输出不带 `type`（Flutter 侧 bookType 恒 0）且阅读前落库只写 `notShelf` 位（8/32/64 类型位丢失）→ 第二次起分流落回文本阅读器。修复（对齐原版 BookInfoActivity.startReadActivity）：
  - `_openReader` 解析类型位：bookType 缺类型位（0/仅状态位）时按书源类型（bookSourceType：1=音频/2=图片/3=文件/4=视频）映射补全位标记（text=8/audio=32/image=64/video=4/webFile=128）
  - 落库以正确类型位 + notShelf；已入库缺类型位旧数据回填 updateBook
  - 分流补齐 video 分支：视频源书 → `/video`（章节播放）
- 视频源书阅读（对齐原版 VideoPlayerActivity）：VideoScreen 支持 `book` 参数——加载章节列表、取当前章正文（视频链接，Rust is_media 分支不做 HTML 格式化）播放、上一集/下一集切换、章节标题显示；`_controller` 未初始化防御（异步加载中退出/首次播放）
- 新增 4 个分流 widget 测试（音频/图片/文本/视频 + 已入库缺类型位回归），全量 flutter test 1143/1143（Reasonix）

## [2.0.12] - 2026-08-10

### 修复
- 阅读进度不恢复：搜索结果进入书籍详情页→开始阅读→返回→再次进入总是回到第一章。根因：详情页 `book` 为 initState 旧快照，阅读返回后不重新加载（Rust 侧 `dur_chapter_index` 已正确写入 books 表但从未被该页面实例重读）。修复：`_openReader` 阅读返回后 `setState` 重新 `_loadData()`（对齐原版 BookInfoViewModel 重查语义），按钮按最新进度显示「继续阅读」并定位到上次章节；`ReaderNotifier.openBook` 同步恢复 `durChapterPos` 章内位置（Reasonix）
- 图片源/音频源不可用：`BookInfoActivity` 分流缺失——`_openReader` 无条件走文本阅读器，漫画阅读器（ReaderComicScreen）与音频播放器（AudioScreen）已实现但零调用方。修复：① `BookType` 常量由 0/1/2 枚举语义修正为位标记（对齐 Kotlin BookType.kt：text=8/audio=32/image=64/video=4/webFile=128）；② `_openReader` 按 `bookType` 位标记分流：audio→`/audio`、image→`/reader-comic`、文本→`/reader`，bookType 缺失（0）时兜底按书源类型（bookSourceType 1=音频/2=图片）判定；③ 书架「音频/视频」分组筛选改用位运算（原 `==` 单值比较恒失配）（Reasonix）

### 测试
- 新增 3 个分流 widget 测试（音频→音频播放页/图片→漫画阅读页/文本→文本阅读页，NavigatorObserver 断言路由）；AudioScreen.dispose 增加卸载时序防御（快速导航/测试树卸载边界）

## [2.0.11] - 2026-08-10

### 修复
- 搜索异常书源弹窗提示消除（对齐原版 SearchModel 静默语义）：批次回调补齐 `error` 字段消费——单书源搜索失败不再产生任何弹窗/整页错误提示路径，失败源不阻断整体搜索，仅按原版 `AppLog.put` 语义以 error 级别写入应用日志（「书源搜索出错」）留痕，可通过日志菜单查看（Reasonix）
- 搜索框文字显示不全修复：AppBar 搜索框 `isDense` 压缩行高 + `textAlignVertical.center` 垂直居中 + 清除按钮（suffixIcon）约束收敛至 32×32（原默认 IconButton 48px 高度撑破 36px 容器导致文字垂直裁切）
- 书籍信息页简介默认全部显示：`_ExpandableText` 默认展开（保留「收起」按钮），短简介仍由 TextPainter 自适应隐藏切换控件

## [2.0.10] - 2026-08-10

### 修复
- 搜索结果排序对齐原版 `SearchModel.mergeItems`：默认搜索也按匹配度分桶排序（equal 完全匹配 → tags kind 匹配 → contains 包含 → other 保底），不再按书源顺序展示；精准搜索丢弃 other 桶，切换精准开关自动重新搜索（对齐原版 SearchActivity）
- 精准搜索卡顿修复：分桶排序从 build 层移至搜索批次回调（每批次一次，对齐原版每次 mergeItems 后排序），展示层直接消费已排序结果，避免每帧全量分桶遍历
- bookUrl 空校验文案可读化（Rust）：「bookUrl不能为空」→「书籍详情页地址为空，无法获取详情/目录（该书源搜索/发现规则未解析出详情链接）」；非 JS 搜索路径空 bookUrl 回退 baseUrl 保持，JS 路径与原版一致丢弃空条目

## [2.0.9] - 2026-08-10

### 修复
- XPath 引擎 xmlns 声明处理修复（思兔阅读等书源目录/正文/详情解析根治）：
  - 根因：页面源码自带 `<html xmlns="http://www.w3.org/1999/xhtml">` 时，HTML→XHTML 回退序列化原样保留 xmlns 属性，sxd-document 解析后全部元素进入该命名空间，无前缀 XPath（`//dd`、`//a` 等）全部失配（仅 `//*` 与谓词字符串比较可命中）
  - 修复：`xpath.rs` `write_node_xhtml` 序列化时跳过 `xmlns`/`xmlns:*` 属性；实测思兔 sto66 详情页 tocUrl 规则（`//*[@id='allchapter']//a[contains(text(), '查看全部章节')]/@href`）从 0 项恢复 1 项、目录页 chapterList/chapterUrl 恢复 500 项
  - 影响面：所有在源码中声明 xmlns 的网站（含 XHTML 页面）的 XPath 规则此前整体失效，本次根治
  - 新增回归测试 `test_xmlns_declaration_does_not_break_prefixed_xpath`；legado-parser 178+1 全过

## [2.0.8] - 2026-08-10

### 修复
- 需登录书源目录/正文获取修复（loginCheckJs 三处语义修正，对齐原版 WebBook 双路径）：
  - `js_executor.rs` result 注入改为**带方法语义的 JS 对象**（原实现 to_string 后注入导致 result 为 JSON 字符串，真实书源 `result.body()`/`url()`/`code()` 写法全部失败）；判定剥除 eval 返回值的 JSON 引号（`"false"` 原无法匹配）
  - `web_book.rs` execute_login_check 区分两类错误：**判定未登录**（false/未登录/needLogin）→ errResponse（HTTP 500）二次 eval 对齐原版失败路径，仍未登录则上抛 `LoginRequired`（用户可见「书源需要登录，请先在书源菜单中登录后重试」）；**JS 环境不兼容**（依赖 java.* 等）→ 降级放行不阻断
  - `legado-core/error.rs` 新增 `LoginRequired` 变体（错误码 1012）；`legado-server/error.rs` 映射 HTTP 401 login_required
  - 新增单测 2 个（对象语义/判定分类），legado-ffi --features quickjs 253/253 通过，workspace 全量 0 failed
- 模拟器冒烟脚本修正：默认包名 `io.legado.flutter_legado`（与 applicationId 同步）、MainActivity 全限定类名 `io.legado.flutter.MainActivity`（原 `.MainActivity` 报 Activity does not exist）

## [2.0.7] - 2026-08-10

### 新增
- §5.12 纯 Flutter 三项行为接线（Reasonix 实施，全量 flutter test 1135/1135 通过）：
  - 双页模式（`doubleHorizontalPage` 0-3 档，对齐原版 ChapterProvider.upLayout）：`reader_page_view.dart` 档位判定（0=单页/1=双页/2=横屏双页/3=平板或横屏，滚动模式强制单页，桌面端窗口宽≥700 模拟平板语义），每栏可用宽（屏宽-边距-16 栏间隙）/2，双栏整屏渲染（`_buildSpread` 左 2s 右 2s+1，末屏右栏留白），屏索引翻页（步进 2），slide/simulate/none/cover 四翻页模式适配，分页缓存键
  - 自定义中文分行开关（`useZhLayout`，对齐原版 useZhLayout=false 走 StaticLayout 语义）：`paragraph_layout_engine.dart` `ParagraphConfig.useZhLayout`（默认 true 保持现行为）+ `_breakLines` 朴素按宽断行分支（无避头尾）
  - 段首标点悬挂（`hangingPunctuation`，对齐原版 HangingPunctuationRule + ZhLayout.hangingWidth）：`ChinesePunctuationRule.shouldHang`（缩进全角空格+起始引号判定）+ `ZhLayout.compute` 首行宽度上限放宽 + `_breakLines` 两分支首行悬挂 + `LineInfo.hangingWidth` 标记 + 渲染侧 OverflowBox 放宽约束 + Transform.translate 左移（标点悬挂进缩进区）

### 修复
- 顺带修复既有 lint：`reader_screen.dart` 自动换源监听 `(prev?.error ?? null) == null` 冗余（等价化简）

## [2.0.6] - 2026-08-10

### 新增
- 自定义 hosts（契约 §2.20.3 setCustomHosts）：legado-net Resolve DNS 覆盖（实时读全局映射 + 系统 DNS 回落）、持久化启动恢复，其他设置页 JSON 编辑对话框对齐原版（非法输入拒绝保存）
- MCP 独立端口（契约 §2.22.5 setMcpPort）：对齐原版 McpService（默认 1236，区间 1024..65530 越界报错），其他设置页接线
- 封面规则搜索（契约 §2.4.8 searchCoverRules）：coverRules 表执行启用规则（key 模板 + isUrl 提取 + 失败隔离），封面设置对话框测试入口（规则 CRUD 待后续契约）

### 修复
- MCP 暴露面收敛：独立服务仅挂 /mcp/tools /mcp/call /health + 127.0.0.1 回环绑定
- MCP DB 路径对齐主应用（不再另开库）
- MCP 同端口重启竞态与状态机互斥修复（实机验证监听地址与重启恢复）
- analyze_url data: URI 豁免对齐原版

### 变更
- frb 分派表重编号 159 起顺延——.so 与 Dart 生成物必须同批产出禁止混装

## [2.0.5] - 2026-08-10

### 新增
- 设置源变量（契约 §2.3 setSourceVariable）：单列 UPDATE + lenient 序列化双保险，Migration102To103 补列；详情页 `_VariableDialog` 对齐原版 setVariable 的 source 分支，§5.11 全部 7 项至此闭合
- 书签双键查询（契约 §2.7 getBookmarksByBook）：书名+作者双键（加法式），消费方全切换（bookmark_notifier/toc_screen/书签导出），MCP 宿主加法式可选 book_author 参数

### 修复
- 书籍写入 upsert 根治级联删除（主键判存在 + 原地 UPDATE / insert_replace），含 import_books 覆盖链路，新增重复插入保留 chapters 测试
- BookSource.variable 双轨 null 序列化失配修复（lenient 序列化双保险）
- 源变量/书籍变量对话框红屏（_VariableDialog 自持 StatefulWidget 范式，D1 修复）
- 源列表过滤残留（dispose clearFilter + 空列表不覆盖非空内存守卫，D2 修复）
- 备份恢复失败日志补齐

### 变更
- frb 配对纪律写入 TWO_TRACK_DEV_SPEC §3.5
- MCP 书签工具新增可选 book_author 参数（加法式兼容）

## [2.0.4] - 2026-08-10

### 新增（第二批后置项三 FFI 接线：压缩数据库/上传至远程/删除重复标题章级开关，契约 §2.16.6/§2.28.6/§2.9.10）
- 压缩数据库（契约 §2.16.6 shrinkDatabase）：其他设置页接通 VACUUM + 释放字节统计（失败降级返回 0），提示文案对齐原版
- 上传至远程（契约 §2.28.6 webdavUploadFile）：详情页菜单接通本地文件路径上传 + PUT 状态码校验，对齐原版 RemoteBookWebDav.upload（origin 回写 webDavTag+远端地址、lastCheckTime 刷新、仅本地书）
- 删除重复标题章级开关（契约 §2.9.10 toggleSameTitleRemoved）：阅读器顶栏开关接通，caches KV 章级 opt-out 持久化、正文净化六链路按章应用、缓存清理复位对齐原版 .nr 语义，切换后重载正文

### 修复（搜索 native 崩溃根治：rule_analyzer 零前进无限递归 + 正则安全编译统一加固）
- 搜索崩溃根治：四轮调查定位 rule_analyzer 零前进无限递归（移植时将原版 throw 改为 break 重试所致），对齐原版 fail-fast + tailrec 修复，五轮复测零崩溃；正则安全编译统一入口保留为纵深防御（非递归嵌套预检 + LRU 缓存 + logcat 诊断）
- 对话框红屏、书籍变量 setState 断言、书签导出 SAF 选目录、书签时间戳单位修复
- WebDAV PUT 状态码校验（非 2xx 不再静默成功）

### 变更
- tokio runtime 线程栈扩至 8MB（FFI/server/JS/webdav 兜底 runtime 统一，对齐原版 JVM 线程栈水位）
- 正则缓存 LRU 化（替换 regex-syntax 预解析依赖为 lru 淘汰）
- build-android.ps1 EAP（ErrorActionPreference）修复

## [2.0.3] - 2026-08-08

### 变更（留项10：定时服务应用内调度器落地，对齐 Kotlin AutoTaskScheduler/AutoTaskJobService，署名 Qoder/QoderCN）
- 新建 `services/auto_task_scheduler.dart`（署名 QoderCN）：应用内 Timer 调度器单例，经 autoTaskListRules + autoTaskNextDueAt 计算最近到期（基准时间对齐原版 baseTime：lastRunAt>0 取之、否则 now-5 分钟首次宽限，对标 FIRST_RUN_GRACE_MS）；Timer 到点筛 isEnabled 且到期任务（对标 dueRules）逐个 autoTaskExecuteWithId；串行隔离：_running 执行锁同刻仅一批、重复触发跳过（对标 executionLock）；单任务失败不影响整批（对标 runTask 逐任务 catch），批次级失败 60s 退避重试（对标 jobFinished(retry=true)+RETRY_BACKOFF_MS）；批次完成后按 nextAfterBatchAt 语义重排；并发 refresh 以代数作废旧结果
- 触发点对齐原版：app.dart initState 装配 attach（对标 App.kt 启动 refresh）+ 应用自后台恢复 resumed 重算（WidgetsBindingObserver）；auto_task_screen 增删改/启停/立即运行/导入后经 _resyncScheduler 重算（对标 AutoTask.save/delete/updateEnabled 后 refresh）；设置页开关开启→refresh/关闭→cancelAll（对标 MyFragment 开关分支），持久化开关加载时恢复调度
- 过时标注清理：移除设置页「后端未移植/后续版本支持」TODO，副标题改为诚实描述「前台应用内调度（应用退出后不执行）」；真后台（进程被杀后仍调度）需 WorkManager，属决策项不在本批范围，保留诚实标注

## [2.0.3] - 2026-08-08

### 变更（Task #147：payAction 章节购买 UI 接线，契约 §2.43.2，对照 Kotlin ReadBookActivity.payAction，署名 Qoder/QoderCN）
- 封装层：`BookApi.chapterPayAction` 接口新增（book_api.dart，返回 `({String kind, String value})` 元组），`rust_api.dart` 直调 bridge 绑定并解析 `{"kind","value"}` JSON（kind 缺失视为 none），`mock_book_api.dart` 同步返回 kind=none（署名 QoderCN）
- reader_bottom_bar 源菜单「章节购买」接通：调用 chapterPayAction(bookUrl, 当前章 index) 后按 kind 三分支处理——url→内置浏览器打开购买页（AppRoutes.browser，标题「章节购买」，对标原版 WebViewActivity + chapter_pay 标题）；success→提示「购买成功」并经 ReaderNotifier.reloadChapterContent 重载当前章（Rust 侧已清章缓存，重载路径参考留项 1 编辑保存）；none→提示「当前章节无需购买或书源未配置购买动作」；异常→错误提示（对标原版 onError）；移除原 TODO(留批次) 占位标注
- 本地书隐藏：源菜单章节购买项对本地书不显示（对标原版 isLocal 短路，且源操作行本身本地书已隐藏）

## [2.0.3] - 2026-08-08

### 修复（留项12 增强：换源 searchSource 分组过滤 Rust 原生实现 + 空结果对话框，零契约签名变更——Qoder）
- Rust 侧：`source_switch::resolve_switch_sources` 追加按 config `searchGroup` 的原生分组过滤（内部读 config 仓储，零 FFI 签名变更，对齐原版 ChangeBookSourceViewModel L197-206 读 AppConfig.searchGroup 后走 getEnabledPartByGroup 行为）；包含判定对齐原版 SOURCE_GROUP_MEMBERSHIP_FILTER SQL 语义：分组字段按 `,`/`;`/`，`/`；` 规范化拆分、逐组名 trim 后与目标分组精确相等匹配（非子串），空分组=全部启用源；新增单测 4 项（多组包含匹配/纯语义判定/空分组全量/过滤后零结果），既有 Task #131 用例补 searchGroup 清空隔离
- UI 侧：`change_source_screen._search` 搜索完成后分组过滤零结果时弹「xx分组搜索结果为空，是否切换到全部分组」对话框（对标原版 ChangeChapterSourceDialog L90-97），确认后清空 searchGroup config 并自动重搜
- 契约：API_CONTRACT.md §2.4 searchSource 登记 Task #145 行为增强说明（零签名变更，无需 codegen/重建 .so）

### 修复（留项 1+2 闭合：阅读器编辑内容保存 + 反转内容闭环接线 saveChapterContent FFI，署名 Qoder/QoderCN）
- 封装层：`BookApi.saveChapterContent` 接口新增（book_api.dart），`rust_api.dart` 直调 bridge 绑定（契约 §2.43.1，chapterUrl 传空串由 Rust 侧从 DB 章节表回填），`mock_book_api.dart` 同步回写 _contentCache 保证后续读回新内容（署名 QoderCN）
- 编辑内容（留项 1）：`reader_top_bar._showEditContentDialog` 保存按钮接通 saveChapterContent，成功后经 `ReaderNotifier.reloadChapterContent` 重载当前章（对标原版 saveContent → BookHelp.saveText + loadContent），失败给错误提示；移除「FFI 未交付」诚实标注与 TODO(留批次)
- 反转内容（留项 2）：先 `getChapterContentFull` 取正文（无缓存章节联网取，避免空转）→ 按原版真实语义码点级整串倒序（ReadBookViewModel.reverseContent L447-459 经 toStringArray 按码点拆单字符逐个 insert(0)，StringExtensions L143 注释明确「拆分为单个字符」，非按行；Dart 用 runes 反转保证 emoji 安全）→ saveChapterContent 写回 → 重载当前章；移除 TODO 标注
- 收口修复：reader_page_view 分页缓存键纳入正文内容（编辑/反转保存后同章重载强制重分页渲染新正文，修复命中旧分页缓存页面仍显旧文）；E2E 实机验证编辑保存即时生效 + DB WAL 持久化确认

## [2.0.3] - 2026-08-07

### 变更（留项6 第①批：阅读器 MoreConfig 无平台依赖配置项落地，每项真实生效，键名对齐原版 AppConfig——Qoder）
- MoreConfig 面板补齐第①批 11 项（对标原版 pref_config_read.xml 项序与文案，持久化键名=原版键）：屏幕方向 screenOrientation / 保持亮屏 keep_light / 隐藏状态栏 hideStatusBar / 隐藏导航栏 hideNavigationBar / 进度条行为 progressBarBehavior / 自动换源 autoChangeSource / 长按选择文本 selectText / 显示亮度控件 showBrightnessView / 滚动翻页无动画 noAnimScrollPage / 显示标题附加区 showReadTitleAddition / 工具栏跟随页面 readBarStyleFollowPage
- 逐项生效方式（对标 MoreConfigDialog.onSharedPreferenceChanged 事件语义）：隐藏状态栏/导航栏→SystemChrome.setEnabledSystemUIMode 手动 overlay 组合（退出阅读器还原 edgeToEdge），分页缓存键新增系统栏 padding 自动重新分页；屏幕方向→SystemChrome.setPreferredOrientations（0跟随系统/1竖屏/2横屏/3传感器/4反向竖屏/5反向横屏，退出还原）；进度条行为=page→底栏滑条改调章内页（跨章分页器取页数、currentChapterPos 取当前页，拖动驱动 ReaderPageView.goToPage，未注册时回退调章节）；自动换源→章节加载失败经 searchSource 取首个非同源候选→switchSource FFI→重开书（限在线书，同书最多 3 次防循环）；选择文本→关闭后正文段落长按选区面板入口移除（分页/滚动两路渲染）；亮度控件→底栏亮度行随开关显隐；无动画滚动→程序化翻页（点击区域/自动翻页/底栏调页）jumpToPage 无动画，滚动模式新增按屏翻页（到底/到顶跨章）；显示标题附加区→顶栏「书名 · 章名」；工具栏跟随页面→顶/底栏背景与前景色跟随阅读页配色（对标 ReadMenu immersiveMenu）
- 平台限制诚实标注：保持亮屏 keep_light 因项目未引入 wakelock 依赖（不改 pubspec）仅持久化，待平台能力接入后生效（与 audio_screen audioWakeLock 标注一致）；音量键翻页等平台相关项留第②批
- 既有测试同步：reader_components_test 顶栏书名断言适配标题附加区默认开启；settings_test 销记已移除的 QUIC 开关断言（2.0.3 QUIC 移除批遗留）

### 变更（Rust 剩余项全批闭合 R1-R10+R12 + QUIC 代码移除，用户决策纯重构边界——Nora/Paul/Hunk/Ivan/Simon/Dylan/Nick）
- Rust 剩余项全批闭合：R1+R2 web_book 正文 subContent 副内容（在线 txt/http 二次请求分支）与 replaceRegex 全文替换（对标 BookContent.kt L128-174）；R3 legado-server 正文接口真实实现（接 RealBookSourceFetcher 正文链路，替换元数据桩）；R4 dict_api 重写为原版字典规则引擎（dict_rules 表逐规则执行 DictRule.search 等价链路 + 表空时注入原版默认 5 字典源 seed，与 assets/defaultData/dictRules.json 同源）；R5 saveChapterContent 缓存写 FFI；R6 chapterPayAction 章节购买 FFI（复用登录 V2 JS 执行设施，url/success/none 三态）；R7 缓存批量下载 4 方法（内存任务表 + worker 线程 + 取消令牌）；R8 bookExportWithOptions 导出参数扩展（格式/charset/章节范围/文件名模板）；R9 font_api 字体反爬 cmap 真实替换（新增 query_ttf.rs）；R10 JS 书源段评回复（js_source_book.rs）；R12 bridge.rs C ABI 模块级 DEPRECATED 标注 + 冻结新增（废弃三步走之步骤2）
- QUIC 代码移除（用户决策，纯重构边界：QUIC 为 Rust 轨扩展、原版无对应能力）：删除 legado-net/quic.rs 与 legado-ffi quic_api.rs、QUIC 8+8 FFI 导出、quinn 等依赖，Dart UI 开关清理（other_settings_screen/book_api/mock_book_api/rust_api），codegen 重跑；契约 §2.41 登记移除记录、§3 待封装清单销记
- 契约：API_CONTRACT.md §2.43 新增 7 方法（R5 缓存写 / R6 购买 / R7 批量下载 4 方法 / R8 导出参数，均加法式、仅走 frb 主链路）+ §2.41 QUIC 移除记录
- 验证：cargo test --workspace 全绿、quickjs feature 213 全过、flutter analyze 0 error；台账销记见 REFACTORING_REMAINING_PLAN.md §5.10

### 修复（留项4+5：朗读段落化起点 + 语速跟随配置对齐原版——Qoder）
- 留项4 朗读段落化（AudioNotifier）：整章一次性送 audioSpeak 改为章节正文按段拆分入队逐段送播（对标原版 BaseReadAloudService contentList/nowSpeak 段落队列）；分段口径与阅读器排版引擎 ParagraphLayoutEngine._splitParagraphs 完全一致（双换行优先、否则单换行、逐段 trim 过滤空段），保证偏移映射起点与排版段落对齐；段落播完自动下一段（探活级 audioSpeak 无真实完成回调，暂以字数/语速估算时长驱动，clamp 0.8s~90s）、章末自动下一章（sequential/singleLoop/末章读完即停均保留既有跨章语义）；新增 nextParagraph/prevParagraph（对标原版 ReadAloud.nextParagraph/prevParagraph，章内边界自动跨章），播放令牌机制防陈旧异步/定时器回调；段落进度经 ChangeNotifier 混入通知 UI（不动 freezed State，免 codegen），rust_api 既有 audioSpeak 封装未动
- 留项4 段落级起播：startReadAloud 新增可选 startChapterPos 字符偏移参数，偏移映射段落索引起播（取最后一个 start<=offset 的段落，对标原版 pos→nowSpeak 定位）；另增 startParagraphText 段落文本匹配兜底（分页排版模式下 ParagraphInfo.startIndex 恒为 0、偏移不可用场景）；text_selection_panel 朗读所选传入 chapterPos + 段落文本，移除降级标注 TODO
- 留项4 read_aloud_bar 解禁：上一段/下一段按钮接入段落切换（朗读激活且段落队列非空时可用），头部新增「·段 x/y」段落进度指示
- 收口修复：read_aloud_bar 底行四按钮窄屏（720px 级）横排溢出 59px 黄条，改 Expanded 均分 + 紧凑内边距，任意屏宽不溢出；E2E 实机验证朗读控制条上一段/下一段可点、无溢出
- 留项5 语速跟随系统语义对齐原版：原版并非实时读系统语速，而是 ttsFlowSys 时 speechRatePlay=defaultSpeechRate(=5) 默认语速常量（AppConfig.kt L393）；勾选跟随→应用默认倍速 1.0x（即原版刻度 5 的等价映射）并禁用手动滑条、速度位显示「默认」，开关状态持久化生效时同步应用，无需系统语速读取通道
- 回归：audio_provider_test 63 项全绿（播放/暂停/停止/上下章/播放模式/配置全链路）；flutter test 1115 过、仅 2 失败为并行代理改动所致（ReaderTopBar 显示书名/OtherSettingsScreen QUIC 开关已移除，均不涉及本任务文件）；flutter analyze 本任务文件 0 error/warning

### 变更（主搜索页分组选择改原版锚定菜单方式：点选即生效自动重搜，解决底部弹窗高度小列表截断——Qoder）
- 分组选择改锚定 PopupMenu：三点菜单「分组或书源」不再直接打开底部弹窗分组 Tab，改为 `showMenu` 弹出锚定三点按钮下方的分组菜单（对齐原版 SearchActivity.onMenuOpened 溢出菜单形态）——「全部书源」+ 各分组名，当前选中分组带勾选标记；点未选分组=单选替换（对标原版 `update(title)`）、点已选分组=取消（对标原版 `remove(title)`）、点「全部书源」=清空；点选即生效且已有关键词时自动重搜（对标原版 scope 变更观察者重搜行为），无需确定按钮；菜单高度自适应、分组多时自动滚动不截断
- 书源多选保留：锚定菜单底部「书源多选…」入口打开 SearchFilterPanel；面板分组 Tab 移除（已被锚定菜单替代），仅保留书源多选（全选/搜索过滤/确定批量生效）；弹窗初始高度由 0.6 加大至 0.9（max 0.95），解决书源列表截断
- 实机 E2E 验证（emulator-5556）：锚定菜单弹出「全部书源」带勾选 → 点「快速书源」立即自动重搜 170→75 条且显示「1 分组」chip，重开菜单「快速书源」带勾选；菜单可滚动不截断；「书源多选」面板加高后列表完整不截断

## [2.0.3] - 2026-08-06

### 修复（「按分组搜索用不了」：换源页分组过滤生效 + 主搜索页选分组自动重搜，留项#12 闭合，跨 Rust+UI 全链，契约先行——Qoder/QoderCN）
- 换源页分组搜索修复（根因：Rust `search_alternative_sources` 硬编码 `list_enabled_sources()` 搜全部源，选分组仅存 config 不生效）：`ffi::source_switch_search` 新增可选参数 `source_urls_json`（空串/空数组/缺省=搜全部启用源，加法式兼容既有调用，语义与 `search_books` 完全一致，复用 `search::load_search_sources` 过滤逻辑），契约登记 API_CONTRACT.md §2.4；C ABI `ffi_source_switch_search` 同步加参；新增单测「传 URL 列表只搜指定源 / 空参数搜全部」；codegen 重新生成 Dart 绑定 + 重建 x86_64 .so
- UI 接线：`BookApi.searchSource` 加可选 `sourceUrls` 参数（rust_api 编码为 sourceUrlsJson / mock 模拟过滤语义，署名 QoderCN）；`ChangeSourceNotifier.search` 加 `group` 参数——非空时用 `getEnabledBookSources()` 内存过滤出该分组源 URL 列表传给 searchSource（分组下无启用源时直接空结果，不误搜全部）；`change_source_screen._search()` 传入 `_searchGroup`，分组过滤全链生效，删除过时 TODO(留批次) 注释
- 主搜索页 UX 修复：三点菜单选分组/书源关闭筛选面板后自动重搜（筛选变更且有关键词时），对齐原版选 scope 后自动重搜行为，避免「选了没用」
- 筛选面板红屏修复（E2E 实机发现）：全局 `tabBarTheme` 设 `TabAlignment.start`（仅滚动 TabBar 合法），`search_filter_panel` 非滚动双 Tab 面板在 debug 下触发断言红屏+底部溢出，面板完全不可用；显式 `tabAlignment: TabAlignment.fill` 覆盖主题修复，分组/书源选择恢复可用
- 台账销记：REFACTORING_REMAINING_PLAN.md §5.9 留项 1（searchSource 分组过滤）闭合（v1.10）

### 修复（书详情页背景分区：仅顶部封面区虚化，章节列表区改纯色——Qoder）
- 书详情页背景分区回退：上一提交 `c620c97e4` 将章节列表 section 底色改为半透明 scrim（`cs.surface` alpha 0.82）让封面虚化整页透出，用户确认不要此效果。现回退 `book_info_screen._buildBody` 章节列表 section（章节搜索/章节列表（N）头/空态/底部间距）为**不透明** `cs.surface`；章节列表本体额外用 `DecoratedSliver(BoxDecoration(color: cs.surface))` 铺满不透明底色——`ListTile.tileColor` 在全屏虚化栈上不可靠地绘制不透明背景（早期无虚化层时被不透明 Scaffold 底色掩盖，加虚化后暴露），故显式加不透明背景 Sliver 盖住虚化。`_buildPage` 的 `ImageFilter.blur` 封面虚化背景层保留，仅透过顶部透明的 `_buildHeader` 封面区显现，`_buildSummaryPanel` 及以下均用不透明纯色盖住虚化，形成「顶部封面虚化景深 → 章节列表纯色清爽背景」的自然过渡（`_buildSummaryPanel` 顶部圆角 20 作为过渡分隔）

### 修复（阅读器点击翻页失效回归——Qoder）
- 阅读器点击翻页失效（P0 回归）根因修复：`reader_screen._handleTap` 命中 `TapAction.nextPage/prevPage` 时经 `ReaderNotifier.nextGlobalPage/prevGlobalPage` 走「全局连续分页」路径，该路径仅更新 `globalPageIndex/currentChapterPos` 状态，却从未驱动 `ReaderPageView` 内部的 `PageController`，故点击后视觉上不翻页；且其「`globalPageIndex` 未变才回退章级翻页」的兜底判定在同章翻页时永不成立（同章翻页必然 +1），兜底 `pageView.nextPageOrChapter()` 从不触发。改为在 `_handleTap` 中直接调用 `ReaderPageView.next/prevPageOrChapter()`——统一驱动 `PageController` 完成各翻页模式（仿真/滑动/覆盖/无动画/滚动）视觉翻页与跨章无缝切换；删除失效的 `_navigateNextPage/_navigatePrevPage`
- 全局页码指示器同步修复：`ReaderNotifier.updatePosition` 在更新章内页位后补调 `_syncGlobalPageInfo()`，使点击翻页与滑动手势翻页时底部「全局页 N/总页」指示器实时更新（此前仅 `updateChapterPageCount` 才刷新，章内翻页时指示器停滞）
- 实机 E2E 验证（emulator-5556）：滑动模式右侧点击 1/558→2/558→3/558、左侧点击 3→2、中间点击呼出/隐藏菜单；仿真模式右侧点击 2→3 均生效，滑动手势翻页未受影响

### 修复（书详情页章节列表区背景虚化覆盖——Qoder）
- 书详情页向下滚动到章节列表时背景无封面虚化修复：`book_info_screen._buildBody` 中章节列表 section（章节搜索/章节列表（N）头/列表项 ListTile/空态/底部间距）原使用不透明 `cs.surface` 背景，完全遮挡了 `_buildPage` 铺满全页的 `ImageFilter.blur` 封面虚化层，导致仅顶部封面区可见景深、下方列表区为纯色。改为半透明 scrim（`cs.surface` withValues alpha 0.82），让封面虚化背景隐约透出、整页保持 iOS 沉浸景深一致；仍保留足够对比度确保章节文字可读（方案 B）

### 变更（书详情页 iOS 视觉重设计 + 溢出菜单对齐原版 + 阅读器顶栏溢出修复，署名 Qoder）
- 书详情页封面高斯虚化背景：`book_info_screen._buildPage` 封面图改用 `ImageFiltered(ImageFilter.blur sigma 25)` 作背景层 + 保留半透明 scrim 叠层，营造 iOS 沉浸景深；无封面降级纯色背景不加模糊
- 顶栏精简至 iOS 导航栏节奏：移除下载/导出按钮（原版书详情无此入口）；编辑按钮条件化，仅在架书籍显示（对标原版 `editMenuItem.isVisible = inBookshelf`）；保留分享 + 更多菜单；标题固定「书籍信息」
- 溢出菜单对齐原版 book_info.xml：条目顺序/可见性对标原版（onMenuOpened 判定）——上传至远程(仅本地书)/刷新/创建更新任务(在架+书源+非本地+允许更新)/登录(书源支持)/置顶/设置源变量·书籍变量(书源存在)/拷贝书籍URL·目录URL/允许更新(勾选,书源存在)/拆分长章节(勾选,本地txt)/删除提醒(勾选)/清理缓存/日志；移除「更新目录」独立项（刷新即含目录更新）；文案「拷贝书籍链接/目录链接」→「拷贝书籍URL/目录URL」、「删除警告」→「删除提醒」；占位项(设置源/书籍变量·删除提醒·上传远程·创建更新任务)保持 _todo 标注不强行实现
- iOS 排版层级：书名改 SF Pro 大标题风格(22sp/w700/负字距)，底部按钮主次分明（放入书架=tinted、开始阅读=filled），分享图标改 `ios_share`
- 阅读器顶栏溢出修复：`reader_top_bar` 顶栏 Row 图标过多致 `RIGHT OVERFLOWED BY 68 PIXELS`，将换源/刷新/缓存（原 menu_group_on_line 三枚 IconButton）收入溢出菜单（仅在线书显示），顶栏仅保留高频的夜间/搜索/书签，Row 不再溢出

### 修复（未入库书详情页加载链路，署名 Qoder）
- 未入库书「目录/章节/封面」加载链路修复（三现象同源，对齐原版 BookInfoViewModel.upBook）：从搜索结果跳转的未入库书进入详情页时，`book_info_screen._loadData` 由「仅查 DB」改为完整链路——在线书 DB 无章节时按 origin 取书源，`webbookInfo` 补全封面/简介/tocUrl/字数（现象③封面缺失），`webbookChapters` 联网取目录用于展示（现象①共 0 章）；未入库时「仅展示不落库」（对齐原版 loadChapter 在 !inBookshelf 时不写 DB），避免污染书架（getBooks=find_all 无 notShelf 过滤）
- 阅读器「章节不存在/未配置书源」修复（现象②）：`_openReader` 对齐原版 readBook——未入库在线书阅读前先 `addBook` 带正确 origin 落库，使 Rust `get_chapter_content_full` 按 book.origin 找书源取正文成立，规避 refresh_toc 兜底插入空 origin 记录导致的第二章及后续报错；已入库则幂等跳过
- 阅读器「翻章后目录被清空 / 章节 N 不存在」根因修复（现象②真因，实机 E2E 定位）：`BookRepository::update` 此前复用 `insert` 的 `INSERT OR REPLACE INTO books`，主键冲突时会先删除旧 books 行再插入，触发 chapters 表 `ON DELETE CASCADE` 级联删除该书全部章节；每次翻章 `_saveProgress → update_reading_progress → repo.update` 都会清空目录，导致下一章「章节不存在」（影响所有在线书，非仅未入库）。改为真正原地 `UPDATE books SET ... WHERE bookUrl=?`（行不存在时退化 insert，保留 upsert 语义且不误触发级联删除），并新增回归测试 `test_update_book_preserves_chapters` 守护；实机验证翻章后 chapters 计数稳定 2598、第三/四章连续阅读正常
- WebBookInfo/WebChapter 为 snake_case（cover_url/toc_url/is_vip），手动映射合并而非 Book.fromJson 直解，避免封面/目录链接丢失
- 发现分类书籍 origin 丢失修复（同源缺陷，端到端验证时发现）：`rust_api.exploreFetchBooks` 返回的 Rust `WebSearchResult` 为 snake_case（book_url/cover_url/source_url，且无 origin/originName），此前直接 `SearchBook.fromJson`（期望 camelCase）会丢失 bookUrl/origin/coverUrl，导致从「发现」进入书详情页的未入库书同样共 0 章、无封面、阅读报「章节不存在」；改为显式归一化（兼容 snake/camel 两种键名）并用本次发现所属书源补齐 origin/originName，使详情页联网补全链路对搜索/发现两个入口一致生效
- 未入库书 notShelf 标记与书架过滤（对齐原版 `BookType.notShelf` / `BookDao.getBooksOnBookshelf`，彻底闭合上一条所述「污染书架」隐患）：新增 `BookType.notShelf`(0x400) / `book_type::NOT_SHELF`(1024) 常量与 `BookRepository::find_all_in_shelf`（`WHERE (type & 1024)=0 ORDER BY "order"`），`list_books` 改走书架过滤查询、`add_book` 改用原地 UPDATE 安全 upsert（避免对已存在临时书触发 INSERT OR REPLACE 级联删章节）；`_openReader` 阅读前落库时打 notShelf 位、`_toggleShelf`「加入书架」时清位转正。相比「详情页离开时清理临时记录」的退路方案，本方案复用既有 type 位标志、书架查询 O(1) 过滤且幂等，并能保留临时书阅读进度/已缓存章节（UX 更优），故择优采用。同步补齐 `update_preserving_read_config` 调用点由 `insert` 改 `update`（原地 UPDATE 三处调用点全覆盖）

### 修复（评审修复：三维评审问题收口，署名 Qoder）
- 搜索结果直达阅读：search_screen 搜索结果点击由弹出仅含「加入书架」的简易 AlertDialog 改为 `Navigator.pushNamed(bookInfo)` 跳转书详情页（对齐原版 SearchActivity→BookInfoActivity），补齐「开始阅读」入口——未入架时开始阅读自动 openBook 直达阅读器，无需先手动加书架；同步删除废弃的 `_showBookDetail`/`_addToBookshelf` 方法及 bookshelf_notifier 冗余引用
- rssUpdateSource 真实接线：`rust_api.updateRssSource` 由误接 `sourceUpdate`（按 BookSource 语义落 book_sources 表，产生幽灵书源脏数据且 RSS 变更静默丢失）改接 `bridge.rssUpdateSource` 原子更新管线，Mock 同步对齐「源不存在时报错」语义（审计缺口④至此全链闭合）
- 书架缓存导出：书架菜单新增缓存章节导出，新增 `BookApi.getCachedChapter` 封装（接通 `cacheGetChapter` FFI）逐章取缓存正文拼接 TXT 经分享通道保存；缓存管理页/epub·pdf/模板等扩展项 TODO(留批次) 登记（台账 §5.9）
- 嗅探委托合并：platform_bridge_service WebView 嗅探改为单一 NavigationDelegate（跳转拦截与加载终态等待共用，不再二次重设委托与二次加载），修复 JS 分支嗅探因委托覆盖必超时问题
- ttsSetCacheDir 初始化接线：`RustApi.init` 内注入应用支持目录 tts_cache（Rust 默认临时目录 Android 可能不可写），失败仅记日志不阻断初始化
- AutoTask 导入 id 碰撞修复：空 id 批量补齐改为基准时间戳拼接循环下标（`${baseId}_$i`），避免同一循环内 microsecondsSinceEpoch 重复导致 id 碰撞
- 日志入口补接：source_edit_screen「日志」菜单接通 AppLogScreen（批次0 遗漏项，日志入口销记口径修正为 7/7，补提交）
- 署名补齐：audio_screen/browser_screen/app.dart 共 3 处注释署名/标记补齐
- 台账口径修正：API_CONTRACT §3 待封装清单销记（登录 V2 三件套/ttsSpeak/cacheGetChapter/rssUpdateSource/ttsSetCacheDir）、审计报告 §7.3 留项修订 + §7.4 P2 处置明细（诚实口径）、UI_FIX_PLAN widget 测试验收口径显式修订、台账 v1.9 + §5.9 TODO(留批次) 登记

### 修复（批次3 P2 收尾：排版细节 + 菜单行为，署名 Qoder）
- 阅读器页面边距：阅读高级配置新增上/下/左/右四向边距滑杆（对标原版 ReadBookConfig paddingTop/Bottom/Left/Right），接入分页缓存键与排版渲染，默认值与历史行为零变化
- 阅读器设置编码：顶栏溢出菜单新增「设置编码」（对标原版 menu_set_charset → showCharsetConfig），写入 book.charset 并重载当前章，本地书乱码可按 UTF-8/GBK/GB18030 等候选重读
- 定时任务页溢出菜单：导入本地（txt/json）/导入线上（URL）/导出（exportAutoTask.json）/帮助，导入经 autoTaskPrepareImported FFI 合并本地运行时状态（对标原版 AutoTaskActivity menu_import_local/import_on_line/export/help）

### 销记（审计 P2 台账核验后无需改动）
- 日志入口 7/7：批次0 已接通 6 处 AppLogScreen（书架/搜索/书详/阅读器/听书/关于），source_edit_screen（书源编辑）为批次0 遗漏项随本次评审修复补接（补提交），销记
- 字距/段距/首行缩进/两端对齐：v2.0.2 已接入排版引擎，销记
- 书源导入排序：排序已应用于显示列表且导入后 reload 保持当前排序（原版 ImportBookSourceDialog 亦无排序 UI），判定对齐，销记

## [2.0.2] - 2026-08-06

### 修复（批次2 组A 阅读器系，署名 Qoder）
- 阅读器顶栏菜单补齐 10 项：重新加载当前章正文（替换规则开关重新分段）、同步已持久化书对象到 State 等，对齐原版 ReadBookActivity 菜单
- 阅读器源操作：批量换源链路接通（对标 Kotlin changeSource）
- 阅读配置 5 项：字体选择/字距调节/首行缩进/两端对齐（MoreConfig textFullJustify）接入排版参数与分页渲染，对标原版 ReadBookConfig
- 离线缓存：阅读器离线下载配置项接通（待 Rust 侧缓存体系补齐）
- 朗读控制条完善：read_aloud_bar 定时/目录/章节跳转等控制项补齐，阅读器底栏朗读入口接线 AudioNotifier.startReadAloud

### 修复（批次2 组B 书架书详，署名 Qoder）
- 书架菜单 7 项：更新目录接真实 refreshToc FFI、添加网址接 WebBook 入库（对标 addBookByUrl）、导入/导出书单对齐 Kotlin importBookshelf/exportBookshelf（url/json/文件三通道）等
- 书详页：登录接通书源登录链路（V2 动态协议+旧版凭据页）、置顶接 topBook FFI、清缓存接 clearCache FFI、批量换源入口（对标 changeSource）
- 书架管理页：批量置顶/置底（对标原版 + replace_rule_sel.xml menu_top_sel/menu_bottom_sel），重排后逐条持久化

### 修复（批次2 组C RSS·规则·换源·听书·设置+结构治理，署名 Qoder）
- RSS：文章列表菜单（登录/刷新/排序/设置源变量/编辑源/切换布局，对标 rss_articles.xml）、双列网格布局切换本地态（articleStyle 0-4）、详情收藏接 addRssStar/deleteRssStar/isStarred FFI（对标 RssFavoritesDialog）、阅读记录对话框（对标 ReadRecordDialog）、rssMarkRead 已读标记
- 替换规则：分组筛选（menu_group：全部/启用/禁用/无分组/分组:x）、批量模式（启用/禁用选中/置顶/置底/导出选中，对标 replace_rule_sel.xml）、网络/二维码导入接通确认页、新规则 pattern 预填
- 换源页：高级选项（搜索筛选/停止刷新切换/书源管理入口/刷新列表/校验作者开关/加载字数开关，对标 change_source.xml）+ 搜索筛选（对标 menu_screen SearchView）
- 听书页：溢出菜单 7 动作（换源/登录/复制播放地址/缓存目录选择/缓存范围/清当前章缓存等，对标 audio_play.xml）
- 设置页：登录/置顶/清缓存等入口接线
- 结构治理：删除 rss_config_screen.dart 及 rssConfig 路由（原版无此页，订阅源管理统一走 rssSourceManage）

### 修复（批次2 跨轨管线：WebView 拦截 + TTS 接线，署名 Qoder）
- WebView 桥接拦截：新建 platform_bridge_service.dart 统一承接 Rust 侧 7 个平台桥接 API（webView/webViewGetSource/webViewGetOverrideUrl/showBrowser/startBrowser/openUrl/openVideoPlayer）结构化 JSON 桥载荷；rust_api.dart 11 处拦截接入，browser_screen/routes/app.dart 联动打开真实 WebView/浏览器（Task #114）
- audioSpeak 接 ttsSpeak 真实管线：rust_api.dart audioSpeak 由 http.get 探活改接 bridge.ttsSpeak（模板替换+MD5 文件缓存+Content-Type 校验由 Rust 侧完成），异常降级探活保留 audio_notifier 既有保护（契约 §2.42，缺口②闭合，署名 QoderCN）
- 搜索内容页：支持阅读器长按选中文本作为初始查询词预填+自动搜索（对标 searchContentQuery）

## [2.0.1] - 2026-08-06

### 修复（批次0 纯接线快赢）
- 阅读器翻页动画入口：reader_top_bar 翻页动画菜单接 ReaderSettingsSheet（对标原版 ReadStyleDialog）
- 日志入口接线：书架/搜索/书详/书源编辑/阅读器菜单的「日志」项接通 AppLogScreen（对标原版 menu_log → AppLogDialog）
- 朗读配置页入口：听书页 TTS 设置面板新增「朗读引擎」入口，接通孤儿页 ReadAloudConfigScreen（对标原版 pref_aloud）
- 替换规则导入：replace_rules_screen 新增导入菜单，本地文件导入接通 ReplaceRuleImportConfirmScreen；网络/二维码导入缺导入 service，留批次2

### 修复（批次1 P0 长按选择 + 朗读链路）
- 阅读器正文长按选择：新增段落选区面板（SelectText 精细选区），接通复制/书签/高亮（5色）/词典/浏览器/分享，操作菜单对齐原版 content_select_action 顺序（审计 P0-1，署名 Qoder）
- 阅读器朗读链路：底栏朗读按钮接通朗读启动/播放暂停切换，新增朗读控制条（章节切换/语速 0.5-3.0x/目录/朗读设置/转后台），对标原版 ReadAloud 控制项（审计 P0-2，真实 TTS 管线待批次2，署名 Qoder）

### 新增（2026-07-31 重构遗留任务收尾）
- 排版引擎渲染侧整合（Task #34）：paragraph_layout_engine 接入 reader_screen，屏级分页 + 中文避头尾 + 两端对齐，847+ 测试通过
- 听书后台媒体按钮（Task #17）：MediaSession 通道注册 + AudioProvider 接线，锁屏/通知栏媒体控制 + 音频焦点管理，22/22 测试
- 发现页 exploreUrl 分类（Task #30）：新增 explore_show_screen + Rust explore_api，分类展开/翻页加载/搜索防抖，Rust 6+4 测试
- 压缩包导入 + 编码检测（Task #31）：archive_import_dialog 支持 zip/rar/7z 解压导入 + TXT 自动编码检测 + 手动编码选择 UI
- audio/auto_task FFI（Task #19 注册 + Task #32 接入）：legado-ffi 新增 9+2 个 FFI 方法，Flutter 侧完成接入
- QUIC 主网络链路（Task #43）：client.rs 集成可选 QUIC/HTTP3 + 失败自动 fallback HTTP/2，配置开关默认关闭，net 188 + ffi 79 测试
- M3 主题系统集中化（Task #39）：独立 app_theme.dart + app_typography.dart，light/dark 双 ColorScheme（用户确认 M3 方向）
- 响应式网格布局（Task #35）：bookshelf/rss/explore 改用 MaxCrossAxisExtent 自适应列数 + responsive.dart 断点工具
- SafeArea 安全边距（Task #36）：home_screen 导航栏与主体补充 SafeArea

### 修复（2026-07-31 UI 一致性）
- 长按多选精确化（Task #37）：长按多选限定封面区域，标题区域排除误触
- 全局 ScrollBehavior 统一（Task #38）：统一滚动物理，各列表手感一致
- Dark Mode 完整校验（Task #41）：42 个 screen 暗色对比度（WCAG ≥ 4.5）与图标可见性核验

### 优化（2026-07-31 性能与质量）
- 性能优化（Task #40）：cached_network_image 双缓存 + RepaintBoundary/稳定 Key/const 构造 + dispose 资源释放审计 + 冷启动/滚动 FPS/翻页性能基线
- 测试覆盖率（Task #33）：新增 +148 测试，Providers 层覆盖率达 72.4%，总计 855 测试全部通过

### 新增
- Tab 自定义图标：8 个安卓原版 SVG 图标（选中/未选中各 4 个）+ flutter_svg 集成 + home_screen.dart 导航栏替换
- 书架自定义刷新组件：custom_refresh_indicator.dart，对齐安卓下拉刷新动画
- 搜索分组筛选：分组/书源双 Tab 筛选面板，对齐安卓 SearchScopeDialog
- 导出路径选择与入口：FilePicker 路径选择 + book_info_screen/bookshelf_screen 双入口集成
- 崩溃防护体系：CrashLogService 全局错误捕获、runZonedGuarded 异步兖底、启动崩溃日志检测弹窗
- 崩溃日志弹窗组件，支持查看详情和清除日志

### 修复
- 阻塞修复：bookshelf_screen.dart dynamic 调用修复、reader_provider.dart 异步空安全、reader_screen.dart PageController hasClients 守卫
- 翻页动画参数对齐：300ms + linear，与安卓 PageDelegate 一致
- RSS 界面样式对齐：4 列网格 + 50x50 圆角图标居中
- 搜索框样式对齐：35dp 胶囊 + 半透明填充 + 0.5dp 描边
- 发现页样式对齐：AppBar 内嵌搜索框 + 扁平列表项

### 变更
- 路由参数规范化：bookInfo/changeSource/audio/searchContent/changeCover/export 6 个路由支持 Book 对象传递
- ExportDialog 参数从 bookId 改为 Book 对象，支持完整书籍信息导出

### 优化
- main.dart 启动流程：SharedPreferences 与 Rust FFI 并行初始化
- HomeScreen Tab 懒构建，减少首帧构建开销
- SettingsService/CacheService 全部方法添加异常保护
- BookshelfProvider/ReaderProvider loadSettings 下沉到首帧回调
- 添加启动阶段 Stopwatch 计时调试日志
- 移除章节预热缓存功能（`_prewarmChapterContent`），保持与 Android 原版一致

## [Unreleased]

### Added
- **JsExtensions 完整实现**：40+ 宿主 API（加密/编码/字符串/正则/JSON/文件/时间/网络/变量/Cookie），java 命名空间绑定，QuickJS 统一注册框架
- **服务端功能扩展**：书源调试 API（会话管理 + 步骤跟踪）、朗读引擎 API（状态机 + 段落分割）、书源规则更新 API、MCP Server（JSON-RPC 2.0 + 12 个 AI 工具）、目录更新 API
- **章节预加载状态机**：三章滑动窗口 + Semaphore 有界并发 + LRU 内存缓存 + 失败熔断器
- **音频预加载优化**：有界 LRU 淘汰 + 磁盘持久化 + 流式分块加载
- **自动任务执行层**：cron 调度策略 + 脚本执行 + 导入/导出 + REST 全 CRUD 7 端点
- **下载管理器**：优先级队列 + 并发池(3) + 暂停/恢复 + REST 5 端点
- **解压缩宿主 API**：zip 完整实现 + 7z/rar 桩化，java 命名空间双挂载
- **CacheManager + SourceLock + RuleComplete**：KV 缓存 + deadline 过期、singleFlight 并发控制、JSOUP/XPath 规则自动补全
- **数据库全覆盖**：25/25 表 Repository 100% 覆盖（新增 search_keywords/cookies/rssArticles/rssReadRecords/rssStars/txtTocRules 等 6 张表）
- **WebSocket 实时通道**：搜索进度推送 + 书源/RSS 调试日志流，5 个 WS 端点
- **DefaultData + Cron 解析**：JSON 默认数据导入 + 5/6 段 cron 表达式解析
- **ContentHelp 段落重排**：完整移植 Kotlin ContentHelp.kt（630 行）至 Rust
- **FFI 大规模扩展**：103+ FFI 导出函数，新增书签/替换规则/在线阅读/换源/AutoTask/RSS收藏/搜索历史/阅读记录/书籍分组/统计/缓存/配置/HTTP TTS/音频进度/Backup/Server/User/WebDAV/Download/Review 等 API
- **Flutter UI 完善**：40 个屏幕（+14）、10 个可复用组件、78 个新 Provider 测试、APK 构建 + 模拟器安装验证通过
- **MCP Server 12 工具接入真实数据库**：search_books/get_chapters/read_chapter/list_sources 等全部接入真实查询
- **用户管理**：users 表 + UserRepository + FFI 6 函数
- **本地 TXT 分词搜索**：TxtSearch 引擎（纯文本/正则 + 章节感知 + 上下文摘要 + 结果数限制）+ FFI 4 函数 + 18 个测试
- **阅读记录 + 书籍分组**：ReadRecordRepository + BookGroupRepository 完整 CRUD
- **HTTP TTS**：http_tts 表 + Repository + FFI 5 函数
- Multi-Agent parallel development scheme (5 roles)
- Module ownership matrix and branch protocol
- WebDAV sync FFI API (6 functions)
- Download Manager FFI API (8 functions)
- Review/paragraph comment FFI API (4 functions) + Flutter dialog
- Simulation page flip animation (ported from Kotlin SimulationPageDelegate.kt bezier algorithm)
- RSS article WebView rendering with JS execution and plain-text fallback
- Source editor rule validation (webbook search/info/chapters/content) and debug log enhancement
- Audio player timer/stop countdown with preset duration selector
- Video player screen with playback controls and fullscreen
- Comic reader screen with vertical scroll, pinch zoom, and image preloading
- CI auto-release workflow (flutter-release.yml)
- 16 new Flutter widget tests (page flip + paragraph comment)

### Changed
- **2026-07-29 源码深度审计**：整体迁移完成度修正为 ~80%（Rust ~85%，Flutter UI ~78%），识别 P0 缺口：排版引擎/导出UI/缓存管理
- **网络栈统一**：从独立 ureq 迁移至 LegadoClient，复用连接池、中间件、重试策略
- **引擎池化增强**：SharedScopeManager LRU 缓存 + 超时中断保护
- **flutter_rust_bridge codegen**：53 → 103+ Dart bindings，rust_api.dart 全量重写为真实 FFI 调用
- **Mutex 安全**：49 处 unwrap() 替换为 unwrap_or_else（毒性恢复，避免 panic 级联）
- **Backup 扩展**：备份范围新增 bookSources、rssSources、readRecords
- Agent configs specialized with role-specific prompts
- rust-ci.yml: exclude legado-ffi from workspace checks
- flutter-ci.yml: pin Flutter 3.41.7, add test step
- All workflows: upgrade actions/checkout to v7

### Fixed
- **java 命名空间核心修复**：`java.get()`/`java.post()`/`java.getStr()` 等关键方法可用
- **QuickJS 超时中断**：从相对时间修复为绝对 deadline
- **AnalyzeRule @js: 规则执行**：JsExecutor trait 注入模式解决跨 crate 循环依赖
- **EPUB 封面提取**：3 级 fallback 策略（cover meta → OPF item → 首图片）
- **MOBI 完善**：EXTH 元数据解析 + KF8 检测 + 错误处理增强
- **WebBook 真实链路**：AnalyzeUrl 模板解析 + LegadoClient HTTP + AnalyzeRule 规则解析，搜索→详情→目录→正文全流程
- **Flutter UI 修复**：clearCache 接入 RustApi、主题导入实现、SharedPreferences TODO 清理
- **FFI UnimplementedError 清零**：Flutter rust_api.dart 全部替换为真实实现
- Rust CI failure: legado-ffi needs Flutter/Dart toolchain not available in Rust CI
- Flutter CI failure: unspecified Flutter version didn't satisfy `sdk: ^3.11.5`
- Node.js 20 deprecation warnings in GitHub Actions
- Clippy redundant_closure warning in bridge.rs ffi_user_get_all

## [2.0.0] - 2026-07-26

### Added
- **Rust Core Engine**: Complete Rust workspace with 8 crates (core, parser, net, js, book, db, ffi, server)
- **Flutter UI**: 18 screens, 12 providers, cross-platform Material3 design
- **QuickJS Engine**: Real QuickJS runtime with 70+ host APIs, sandbox security, engine pooling
- **Rule Parser**: RuleAnalyzer with JSoup/XPath/JsonPath/Regex parsers + @js: mode
- **Network Layer**: LegadoClient with retry/rate-limit/proxy/UA rotation/SSL middleware
- **Book Parsers**: EPUB/TXT/MOBI/PDF/UMD format support + TXT/EPUB/HTML export
- **Database**: SQLite Schema v95, Room migration (v90-v95), 7 repositories
- **HTTP Server**: axum-based REST API with 25+ endpoints + Web SPA frontend
- **FFI Bridge**: flutter_rust_bridge v2.12.0 with 30+ export functions
- **Multimedia**: Audio playback with preload optimization, TTS integration
- **Reading Engine**: Chapter preloading state machine with LRU cache and failure circuit breaker
- **Security**: File API sandbox with path traversal protection
- **Cloud Sync**: WebDAV client for book data synchronization
- **i18n**: Chinese/English dual language support
- **CI/CD**: GitHub Actions workflows for Rust and Flutter
- **Build Scripts**: Windows one-click build (PowerShell + BAT)

### Changed
- Migrated from Android Kotlin to Rust core + Flutter UI architecture
- Network stack unified from ureq to LegadoClient (connection pooling, middleware chain)
- JS engine upgraded from stub to real QuickJS runtime with engine pooling

### Fixed
- QuickJS timeout interrupt (was using relative time instead of absolute deadline)
- Java namespace for book source JS scripts (java.xxx() calling convention)
- File API path traversal vulnerability (added sandbox validation)
- HostApiRegistry dead code removed (150 lines of empty TODOs)

## [1.0.0] - Legacy

### Description
- Original Android Kotlin implementation (io.legado.app)
- 329 releases tracked via git tags (3.YYMMDDHH format)
- Full-featured Android reading app with 60+ Kotlin models, 20+ services
