# 批 9a 设备验收报告（预下载 · 漫画浏览开关 · 自动更新 · 源编辑行数 · 语言/抗锯齿/图片缓存 · 音频焦点）

> 范围：批 9a（预下载数接线 / 漫画浏览开关 showMangaUi / 自动更新启动检查 /
> 源编辑框最大行数 / 语言切换 / 抗锯齿与图片绘制缓存 / 忽略音频焦点）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线）。
>
> **结论**：**6 项 PASS，1 项 BLOCKED，0 FAIL**。OS 层 FATAL=0、ANR=0。
> BLOCKED 项为场景 6（忽略音频焦点行为层验证）——MuMu 设备无可用朗读引擎
> （TTS 走估算节奏假播放、无真实音频输出）且无第二音频源素材可自动化，
> 焦点行为不可插桩；已留证「开关关闭（默认）时应用正常请求并持有音频焦点」
> 的关闭侧行为（dumpsys audio 焦点栈），开关侧语义由单测覆盖。
> 另登记 2 项说明（非缺陷/观测受限）：§6.1 语言 i18n 覆盖范围（主框架 EN、
> 子页面大量文案仍中文）；§6.2 漫画源夹具正文渲染受限（0 图/正文为空提示，
> 不影响开关分流判定）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 / 密度 | 1080x1920 / 480dpi（未改动） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.423** / versionCode **424**（`dumpsys package` 与 pubspec `2.0.423+424` 一致） |
| 源码基线 | `master` HEAD `da63997081`（`chore: 批9a 收尾（2.0.423+424 双日志与计划关闭登记）`） |
| DB 路径 | `/data/user/0/io.legado.flutter_legado/app_flutter/legado.db` |
| 验收时间 | 2026-10-31 02:41 ~ 05:25（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch9a/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1031/`（97 张） |

### 1.1 构建与安装

| 步骤 | 命令 | 结果 |
|---|---|---|
| Rust FFI | 复用既有产物（本批仅 Dart 变更，无 Rust 重建） | 三 ABI `.so` mtime 保持 2026-10-30 19:32~19:34；arm64/x86_64 meta `quickjs:true` |
| Flutter APK | `flutter build apk --release` | **EXIT=0**，`√ Built ... app-release.apk (189.8MB)`，99.6s |
| APK 摘要 | sha256 | `3ac13e5438c1aa5e97b42a14abd41b184d04de601bb14d02de6073cd5b69a8bb`（199,036,516 字节） |
| arm64 `.so` | `jniLibs/arm64-v8a/liblegado_ffi.so` | mtime `2026-10-30 19:32:20`（未变），51,525,560 B |
| 安装 | `adb install -r` | `Success: streamed 199036516 bytes` |
| 版本确认 | `dumpsys package` | versionName=2.0.423 / versionCode=424（升级前设备为 2.0.422/423） |
| 启动冒烟 | 冷启动 + `logcat` | 无 FATAL/ANR（`shots/00_launch.png`） |

### 1.2 测试数据（造数据，未改业务代码）

| 数据 | 内容 / 路径 | 用途 |
|---|---|---|
| 书源夹具 | `data/qa9a_sources.json`（QA9A文书源 type=0 / QA9A漫画源 type=2 / QA9A坏章源 type=0，均指向宿主 mock `http://192.168.100.52:18090`） | 场景 1/2：多章预取、漫画分流、坏章重试 |
| mock 服务器 | `server/mock9a.py`，`0.0.0.0:18090`（Python ThreadingHTTPServer） | `/search` `/explore`（未用）`/book/{name}` `/content/{name}/{i}`（name=QA9A坏章书 且 i=3 时恒 HTTP 500）`/manga/search` `/manga/toc/{n}` `/mangacontent/{name}/{i}`（text/plain 图片 URL）`/mangapage/{name}/{i}/{j}`（20x30 PNG）`/sources`（回源夹具 JSON） |
| 访问日志 | `server/mock_access9a.log`（逐请求时间戳+路径） | 预取/换书请求时序取证 |
| cbz 夹具 | `data/qa9a.cbz`（3 张 200x300 PNG，推送到 `/sdcard/Download/qa9a.cbz`） | 场景 2 cbz 登记项（未实机导入，见 §6.2） |
| DB 查询脚本 | `dbq9a.sh` / `prefq9a.sh`（推送到 `/data/local/tmp/`，规避 MSYS 路径转换） | 全程只读取证 |
| prefs 取证 | `FlutterSharedPreferences.xml` grep（`flutter.*` 键） | 批 9a 各开关键值双向留证 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1a | 预下载 preDownloadNum=3：开书预取 + 翻章窗口滚动 | **PASS** | `cached_chapters` 增量 {0,1,3}→+{4}→+{5,6,7}；mock 03:40:37 一次性 `/content/.../6,7,8` |
| 1b | 预下载 preDownloadNum=0：关闭不再新增 | **PASS** | 跳回第 1 章后 cached 恒 7 行、无新 `/content/` 请求（04:26~04:29） |
| 1c | 快速翻章/换书：无崩溃无卡顿；换书后新书仍预取 | **PASS** | 连续 tap 翻章；书 B 开书后 `cached_chapters` 新增 `book/QA9A文B` 0/1/3 行 |
| 1d | 失败章（HTTP 500）不弹错不崩溃；预取通道失败不重复请求 | **PASS**（重试恢复语义登记，见 §3.1d） | mock `/content/QA9A坏章书/3` 恒 500；阅读页正常显示缓存章；预取通道对 index 2 无反复请求 |
| 2 | 漫画浏览开关：ON→漫画阅读器 / OFF→文本阅读器降级；文字书不受影响；cbz 登记 | **PASS**（cbz 实机项登记，见 §6.2） | logcat `[BookOpen]`：typeBits=64 route=`/reader-comic`(ON) ↔ `/reader`(OFF)；typeBits=8 恒 `/reader`；prefs `showMangaUi` true→false→true |
| 3 | 自动更新：时间戳触发 / 24h 内不重复 / 失败不阻塞 | **PASS** | prefs `lastCheckUpdate` 0→1793392273763（5s 延迟后写入）；二次冷启动时间戳不变；清 0 再启动失败静默（GitHub 不可达，无弹窗） |
| 4 | 源编辑最大行数 30→多行字段变化→10 生效 | **PASS** | 多行字段 36 行输入视口 h=1587px（30 行钳制）→ 12 行输入 h=768px（10 行钳制）；单行字段 h=120 恒定 |
| 5a | 语言切 en→重启生效 | **PASS**（范围登记，见 §6.1） | prefs `app_locale=en`；书架标题「Bookshelf」、底部 tab EN、My 页 EN；子页面大量中文（如实登记） |
| 5b | 抗锯齿开关切换不崩溃 | **PASS** | prefs `antiAlias` true→false→true；开书/翻页正常 |
| 5c | 图片缓存上限改小（5MB）重启正常 | **PASS** | prefs `bitmapCacheSize=5`；重启后开文字书/漫画书无 OOM 无崩溃（FATAL/OOM 计数 0） |
| 6 | 听书音频焦点：开关打开 TTS 不被抢占；关闭恢复 | **BLOCKED** | 关闭侧留证：`dumpsys audio` 焦点栈顶 `io.legado.flutter_legado GAIN`；设备无 TTS 引擎/第二音频源（§3.6） |
| 7 | 回归：冷启动/开书/翻章/切书/设置滚动 | **PASS** | 全会话 `FATAL EXCEPTION`=0、`ANR in io.legado`=`0`（`logcat/full_session.log`） |

## 三、逐场景证据

### 3.1 批 9a 场景 1：预下载

- **设置入口**：我的 → 设置 → 高级（其他设置）→「预下载」（subtitle「预先下载 N 章正文」），
  弹窗输入 3 → prefs `flutter.preDownloadNum=3`（`shots/25、26`）。
- **夹具**：QA9A文书源 8 章书（ruleToc JS 生成 8 章，章节 URL=`/content/QA9A文A/{i}`；
  QA9A坏章源同构但 `/content/QA9A坏章书/3` 恒 HTTP 500）。
- **1a 窗口滚动**（book=QA9A文A，`cached_chapters` 以 (book_url, chapter_index) 取证）：
  - 开书（durChapterIndex=0）→ cached = {0,1,3}（index 2 预取失败 500，静默；1、3 成功落库）；
  - 翻到第 2 章（index=1）→ cached + {4}（窗口 2..4，2 失败 4 成功）；
  - 目录跳第 5 章（index=4）→ mock 03:40:37 一次性收到 `/content/QA9A坏章书/6、7、8`
    三个请求，cached + {5,6,7}（共 7 行）——与「翻章成功后预取 index+1..index+3」一致；
  - 尾章（index=7）无 index≥8 请求（窗口按目录长度截断）。
- **1c 换书**：搜索添加 QA9A文B 并开书 → `cached_chapters` 新增 `book/QA9A文B` 的
  {0,1,3} 行（`shots/50`），旧书缓存不串本（v102 复合键生效）；Notifier 代际重置
  （`reader_notifier.dart` `_resetPreDownloadState`）由「重开书后不重复预取」佐证
  （尾章重开 cached 恒 7 行、无新增请求，`shots/49`）。
- **1b 关闭（=0）**：prefs 改 0 → 重新跳第 1 章 → 等 6s，mock 无任何新增
  `/content/` 请求，cached 恒 7 行（`shots/72、73`）。
- **1d 失败章**：index 2（HTTP 500）全程未弹错误框、未崩溃；阅读页对缓存章正常
  渲染、对失败章走 ErrorView（重试/换源按钮，`shots/40`）——ErrorView 重试属于
  **阅读页正文加载通道**（mock log 中 `/content/.../3` 多次出现即该通道），预取通道
  自身静默失败且失败计数达 3 后不再排队（对 index 2 预取请求仅出现在首次窗口，
  后续翻章窗口未重复）。**登记**：「恢复网络后本会话可重试至多 3 次」的恢复侧
  （失败→成功翻转）需可变网络夹具，本次以「失败 3 次后本会话跳过」+ 单测
  `reader_predownload_test.dart`（构建链已含）为准，恢复翻转实机未单独复现。

### 3.2 批 9a 场景 2：漫画浏览开关

- **开关位置**：其他设置 →「漫画浏览」；双向 toggle 后 prefs
  `flutter.showMangaUi` true→false→true（`shots/66、67、69`）。
- **分流（logcat `[BookOpen]`，QA9A漫A typeBits=64）**：
  - ON：`route=/reader-comic srcType=2`（04:07:10、04:22:43 两次）→ 漫画阅读器
    （黑底、底部「话1 章节1/4 总进度」指示，`shots/55、62`）；
  - OFF：`route=/reader srcType=2`（04:17:49）→ **文本阅读器降级**（正文以文本
    呈现，页码 1/1，`shots/68`）。
- **文字书回归**：QA9A文A/文B typeBits=8，开关 ON/OFF 下均 `route=/reader`
  （04:12:19 logcat）——普通文字书不受开关影响。
- **cbz 登记项**：本地 cbz 恒走 `/reader-comic`（`book_open_utils.dart`
  `routeForTypeBits` isLocal 分支 + widget 测试 `book_open_manga_toggle_test.dart`
  钉住 0x1040 → comic）；实机 cbz 导入链路（DocumentsUI 选择器）未在本批自动化，
  以单测 + 代码口径登记。

### 3.3 批 9a 场景 3：自动更新

- **触发**：prefs `flutter.lastCheckUpdate` 手工清 0 → force-stop 冷启动 →
  约 5s 后（`_maybeAutoCheckUpdate` 延迟 5s）时间戳被写入
  `1793392273763`（= 2026-10-31 04:31:13，进程启动 +12s 时取证）。
- **24h 内不重复**：同一时间戳下再次 force-stop 冷启动，等 14s →
  `lastCheckUpdate` 仍为 `1793392273763`（无新写入、无二次检查）。
- **失败不阻塞**：清 0 后冷启动（GitHub API 不可达环境）→ 时间戳先行写入
  `1793392343087`（check 发起即记，对齐原版语义），失败静默：无 UpdateDialog、
  无崩溃框，书架正常可用（`shots/74`）；FATAL 计数 0。

### 3.4 批 9a 场景 4：源编辑框最大行数

- **设置**：其他设置 →「源编辑框最大行数」（默认 99）→ 改 30 →
  prefs `flutter.sourceEditMaxLine=30`；QA9A文书源「编辑」进书源编辑器。
- **30 行生效**：loginCheckJs 字段（多行，maxLines≥2）输入 36 行（L1..L36）→
  EditText 视口高 **1587px**（≈30 行 × 53px/行），第 31 行起滚动出视口
  （`shots/76、79`，dump `ui_srcedit30c.xml`）。
- **10 行生效**：偏好改 10（prefs=10）→ 同字段输入 12 行（Z1..Z12）→
  EditText 视口高 **768px**（≈10 行），仅显示末 10 行 Z3..Z12
  （`shots/83`，dump `ui_edit10e.xml`）。
- **单行字段不受影响**：源 URL / 源名称 / 源分组 / 并发率字段高度恒 **120px**
  （单行），30 与 10 两档下一致；多行字段空态高 144px（minLines=2）两档一致
  （dump `ui_srcedit30.xml` vs `ui_edit10d.xml`）。
- 实现口径（`source_edit_screen_builders.part.dart`）：多行字段
  effectiveMaxLines = max(原定义, 偏好)；单行字段（maxLines=1）不套用。

### 3.5 批 9a 场景 5：语言 / 抗锯齿 / 图片缓存

- **语言**：其他设置 → 语言 → English（`shots/84`）→ prefs
  `flutter.app_locale=en` → force-stop 冷启动：书架标题「Bookshelf」、
  底部 tab「Bookshelf / Discover / RSS / My」、My 页标题「My」（`shots/85、87`）；
  其他设置页语言行 value=「English」（`shots/88`）。**范围登记见 §6.1**。
- **抗锯齿**：其他设置 →「抗锯齿」toggle → prefs `antiAlias`
  true→false→true 双向落盘（`shots/89`）；开关切换后立即开文字书翻页、
  开漫画书，无崩溃无异常渲染（视觉差异单帧难以量化，以「不崩溃 + 键值双向」
  为口径，对齐批 39 封面比例开关的观测局限登记）。
- **图片缓存**：其他设置 →「图片绘制缓存」→ 改 5（prefs
  `flutter.bitmapCacheSize=5`，`shots/90→91`）→ force-stop 冷启动 →
  开文字书（第 1 章正文正常，`shots/92`）、开漫画书、翻页——
  全程 `FATAL EXCEPTION`/`OutOfMemoryError` 计数 0（`shots/93`）。

### 3.6 批 9a 场景 6：忽略音频焦点（BLOCKED）

- **已取得的关闭侧证据**（开关默认 false）：阅读器发起朗读后
  `dumpsys audio` 显示应用位于 **Audio Focus 栈顶**（`GAIN, loss:none`，
  USAGE_MEDIA/CONTENT_TYPE_MUSIC），MediaFocusControl 事件日志记录
  `requestAudioFocus() from uid/pid 10062/... callingPack=io.legado.flutter_legado`
  两次（05:19:53 / 05:21:09）——即**关闭（默认）时应用正常请求并持有焦点**，
  「关闭时恢复原行为」半边成立（`shots/94`）。
- **BLOCKED 原因**：
  1. MuMu 设备无可用 TTS 朗读引擎——朗读面板明确提示「未配置可用朗读引擎，
     将按估算节奏朗读」，朗读为假播放、不产生真实音频输出与焦点竞争行为；
  2. 设备无第二音频源素材（`pm list packages` 无音乐播放器；仅
     SoundPicker/媒体提供器），「播放其他音频抢占」无从发起；
  3. 焦点丢失事件（`onAudioFocusLoss`）需要真实第二播放器触发，无法插桩。
- **开关侧补充**：`ignoreAudioFocus` 键在 prefs 无条目（默认 false），
  开关 ON 行为（不请求焦点 + 忽略丢失）由单测
  `audio_ignore_focus_wiring_test.dart` / `audio_focus_wiring_test.dart`
  覆盖（本批构建链包含）。

### 3.7 批 9a 场景 7：回归

- 冷启动（多次，含 force-stop 后）、书架→开书（文字/漫画）、阅读翻页、
  退出换书、设置页多级导航与滚动（外观/高级/阅读界面/其他设置全列表往返）——
  全程无崩溃、无长时间卡顿（界面操作即时响应，无 ANR 弹窗）。
- **FATAL/ANR 汇总**：全会话 `logcat -d` 过滤 `FATAL EXCEPTION` = **0**、
  `ANR in io.legado` = **0**（`logcat/full_session.log` 全量留存）。

## 四、FATAL / ANR 汇总

| 项 | 计数 | 说明 |
|---|---|---|
| `FATAL EXCEPTION` | **0** | 全会话 `logcat -d` 过滤 |
| `ANR in io.legado.flutter_legado` | **0** | 同上 |
| `OutOfMemoryError` | **0** | 含 bitmapCacheSize=5 压力场景 |
| 应用级错误提示 | ErrorView（坏章 500）×N、MCP 未配置令牌 SnackBar ×1（QA 侧误触开关，非缺陷） | 均为预期防御路径 |

## 五、证据清单（`tmp_debug/device_acceptance_20261031_batch9a/`）

| 类别 | 文件 |
|---|---|
| 构建 | `tmp_build_apk_batch9a.log` |
| 夹具 | `data/qa9a_sources.json`、`data/qa9a.cbz`、DB/prefs 取证与清理脚本（`dbq9a.sh` 等，已从设备清理） |
| 服务器 | `server/mock9a.py`、`server/mock_access9a.log`（content/toc/mangapage/sources 全请求时序） |
| 截图 | `shots/00~96`（97 张，含 uiautomator dump `data/ui_*.xml`）；副本 `docs/materials_1031/` |
| 日志 | `logcat/full_session.log`（全会话） |

## 六、说明与遗留（非缺陷/观测受限）

### 6.1 语言 i18n 覆盖范围（如实登记）

- **已英文**：书架标题（Bookshelf）、底部导航 5 tab、My 页标题（My）、
  设置弹窗按钮（Cancel/OK）、主题模式值（Light）等主框架文案。
- **仍中文**：设置二级页标题（其他设置）、大多数设置行标题/副标题
  （语言/自动刷新/漫画浏览等）、定时任务页、MCP SnackBar、阅读器菜单等
  子页面与组件级文案。
- 即本批语言切换功能本身可用（app_locale 持久化 + 冷启动生效 + 主框架切换），
  但 i18n 词条覆盖不完整，属**观测记录**而非本批缺陷（本批接线点为
  `AppStrings.setLocale` 调用链，覆盖面由词条表决定）。

### 6.2 漫画源夹具正文渲染受限

- QA9A漫画源正文规则经三轮夹具修正（`<img>{{baseUrl}}<img>` →
  `<img src=...>` → text/plain URL 行），阅读器始终无法渲染出图：
  先后出现「正文没有图片」（0 图校验，`shots/52、55`）与
  「Content empty: 章节 话1 正文为空」（`shots/59`）。
- 定位结论：为**夹具与解析链的组合限制**（URL 含中文路径段经百分号编码、
  ruleContent 模板/JSON 规则求值差异），不影响本批验收口径——开关分流以
  `[BookOpen]` route 日志为准（/reader-comic ↔ /reader 双向已证），
  图片渲染链路（imageDecode、防盗链 header）不在本批范围。
- **连带登记**：QA9A文A/文B 书名在换源（自动切到坏章源）后 DB 落库为
  百分号编码形态（`QA9A%E6%96%87A`），QA 经 DB 改回后流程恢复；该现象
  源于夹具书名含中文且出现在 URL 路径段，真实书源书名通常不含 URL 保留字，
  未定级。

### 6.3 cbz 实机项

- 「本地 cbz 不随开关变化」以 `book_open_utils.dart` isLocal 分支代码口径 +
  widget 测试（`book_open_manga_toggle_test.dart`）登记；实机 DocumentsUI
  导入 cbz 流程未在本批自动化（选择器交互复杂），与批 cbz 验收（0x1040 →
  /reader-comic）口径一致。

## 七、清理

- DB：`books`/`chapters`/`cached_chapters`/`book_sources` 测试行清空
  （复核 count=0；`search_books` 表不存在于当前 schema，跳过）。
- prefs：批 9a 全部键（`preDownloadNum`/`sourceEditMaxLine`/`bitmapCacheSize`/
  `antiAlias`/`showMangaUi`/`lastCheckUpdate`/`app_locale`）删除回落代码默认
  （grep 复核 0 条）。
- 设备文件：`/sdcard/Download/qa9a_*`（JSON/CBZ）与 `/data/local/tmp/` 全部
  QA 脚本删除。
- 设备保留验收版本 2.0.423/424；最终冷启动书架空态
  （`shots/96_final_clean.png`）。

## 八、结论

- 场景 1（预下载 4 项：=3 窗口滚动 / =0 关闭 / 快速翻章换书 / 失败章）：
  **PASS**（恢复网络重试翻转侧登记，见 §3.1d）。
- 场景 2（漫画浏览开关双向分流 + 文字书回归）：**PASS**（cbz 实机项登记，§6.3）。
- 场景 3（自动更新触发 / 24h 门 / 失败静默）：**PASS**。
- 场景 4（源编辑最大行数 30→10 生效，单行字段不受影响）：**PASS**。
- 场景 5（语言 en 生效【范围登记】/ 抗锯齿双向 / 图片缓存 5MB 无 OOM）：**PASS**。
- 场景 6（忽略音频焦点）：**BLOCKED**（设备无朗读引擎与第二音频源，行为不可插桩；
  关闭侧焦点持有已留证，开关侧由单测覆盖）。
- 场景 7（回归）：**PASS**，OS 层 FATAL=0、ANR=0、OOM=0。

编写者：QA（ZCode 子代理）｜ 2026-10-31
