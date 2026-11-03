# 批 2b-2c「书架/发现/RSS 列表-详情」设备验收报告

> 范围：版本 **2.0.445+446**（HEAD `ec0a146d09`）的列表-详情双栏能力：
> 书架未读/长按/已读直读、发现源内容书单、RSS 源→文章列表→文章详情、
> 窄屏/off root 全屏、切 Tab 清右栏、双↔单宽度切换栈保留、返回语义、My 互斥、
> 视频/登录/搜索 root 分流与回归。
> 核心实现：`flutter_legado/lib/src/widgets/navigation/main_detail_pane_scope.dart`、
> `flutter_legado/lib/src/screens/home_screen.dart`、
> `flutter_legado/lib/src/widgets/explore_book_list.dart`、
> `flutter_legado/lib/src/screens/rss_screen.dart`、
> `flutter_legado/lib/src/screens/rss_articles_screen.dart`。
>
> 设备：MuMu 实例 index 1「Test测试」（`MuMuManager info -v all` 实测在线；
> adb 端点 `192.168.100.62:5555`），SM-G9900 伪装 / Android 15（SDK 35）/ x86_64。
> 宽屏验收覆盖 `wm size 1920x1200` + `wm density 240`（**1280×800 dp**）；
> 验收结束已 `wm size reset` / `wm density reset`（物理 1080×1920 / 480）。
>
> **结论：A1/A3/A4 通过，A2 存在 P1 崩溃缺陷，A5 无 FATAL/ANR/overflow 但存在
> Dart 异常（P1）。本批 A 不通过，需修复后复验。**
> 关键失败：宽屏「发现」平板双栏书单点书打开右栏 BookInfo 时，左侧发现页被
> Flutter `ErrorWidget` 灰块替代，应用崩溃日志记录
> `Bad state: Too many elements`（`md3_fast_scroller.dart:51`），下次启动弹出
> 「上次运行发生崩溃」。源内容模式（切换到源内容后的书单）路径正常。
>
> 声明：QA 未修改应用代码；书籍/RSS/漫画夹具均为验收临时数据，验收后已清空。
>
> **2026-11-03 23:57 追加：HEAD `eb9a74bbe3` 回修复验见 §六。A2 P1 已修复并关闭
> （FATAL/ANR/overflow=0；保留 1 项非阻塞响应式观察 O1）。**

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例 index 1「Test测试」；`MuMuManager info -v all` 判定 `is_android_started=true`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 物理分辨率 / 密度 | 1080×1920 / 480 dpi（验收开始前存在 override 1920×1200 / 240，来自上一轮；本次继续使用并在结束 reset） |
| 宽屏 override | 1920×1200 / 240 dpi（**1280×800 dp**）；窄屏另设 1200×1920 / 240（**800×1280 dp**） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备权限 | `adb shell id` = `uid=0(root)`（本机 MuMu 当前 adbd 为 root，可直接读取 app 私有目录） |
| 应用包名 / Activity | `io.legado.flutter_legado` / `io.legado.flutter.MainActivity` |
| 验收版本 | versionName **2.0.445** / versionCode **446**（安装后复核） |
| 源码基线 | `master` HEAD **`ec0a146d09`**；QA 未改代码 |
| 验收时间 | 2026-11-03 22:30 ~ 23:20（宿主时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261104/`（logcat/data/scripts/shots，不入库） |
| 截图 | `docs/materials_1109b/b2c_*.png`（101 张 A/B/C 总归档；本报告引用 `b2c_*`） |

### 1.1 构建与安装（本批含 Rust 9b-3）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | `pwsh 7` 执行 `rust/scripts/build-android.ps1 -Mode release`，EXIT=0；`logcat/rust_build.log` |
| x86_64 `.so` | **51,938,080 B**，mtime **2026-11-03 22:34:50**，sha256 **`5c29e4dd963272bbe3355688c67adeb9e414cc33c155ba3b81a9d2a22982b68c`**；`.meta` `mode=release`、`quickjs=true`、`contentHash=51404204`、`builtAt=2026-11-03T22:34:51+08:00`、`rustFingerprint=e494bfeb…` |
| arm64-v8a `.so` | 51,756,336 B，sha256 `5fa153afcb414bf5ec43ba35c949c79fac56f8f3488bed542d1323c5ee5d4f02`，`quickjs=true` |
| armeabi-v7a `.so` | 34,378,712 B，sha256 `849760b84eb54106a515abb39f0e76701ce2d7b2f9ce963e02d5e268848a0eae`，`quickjs=false`（见 P2-O1） |
| Flutter APK | `flutter build apk --release` EXIT=0，`assembleRelease 84.2s`，**200,697,868 B（191.4 MB）**，sha256 **`690767f10584c978e07bce56cc44f7ff72376784828b8fe5c255113eab80e630`**（`logcat/build_release.log`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200697868 bytes**（`logcat/install.log`）；设备 `base.apk` sha256 与构建产物一致（`data/version_installed.txt`） |
| 安装后版本 | `versionName=2.0.445 / versionCode=446` |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（36.3s） |
| 多栏/RSS/深链定向测试 | `flutter test test/widget/main_detail_pane_test.dart test/unit/legado_deep_link_test.dart test/unit/multi_pane_layout_test.dart test/unit/association_import_dialog_test.dart test/widget/explore_screen_dual_pane_test.dart` | **62/62 passed**，EXIT=0 |
| 全量 Flutter 测试 | `flutter test` | **4129 passed + 1 skipped**，EXIT=0（1:48） |
| Rust 9b-3 定向 | `cargo test -p legado-ffi --test retain_comic_images --features quickjs` | **8/8 passed** |
| Rust 图片缓存单测 | `cargo test -p legado-ffi --lib --features quickjs image_cache` | **31 passed / 0 failed**（765 filtered） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success |

> `flutter test` 与 `flutter build` 串行执行，避免 `GeneratedPluginRegistrant.java` 竞态。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 书架：未读单击→右栏 BookInfo、左书架保留；点另一本→右栏替换、返回不叠栈；长按→右栏；已读直读→阅读器 root 全屏、关闭后右栏空 | **PASS** | `b2c_a01_shelf_wide.png`、`b2c_a05_back_to_bookinfo.png`、`b2c_a06_back_shelf.png`、`b2c_a07_longpress_b.png`、`b2c_a09_read_book_reader.png`、`b2c_a12b_replace_b.png`、`b2c_a46_bookinfo_c_replace.png`、`b2c_a47_replace_back_shelf.png` |
| 2 | 发现书单：点书→右栏 BookInfo、左列表保留/返回 | **FAIL（P1）** | 源内容模式 PASS：`b2c_a20_source_content_bookinfo.png`、`b2c_a23_source_content_bookB2.png`、`b2c_a24_source_content_back2.png`；平板双栏 FAIL：`b2c_a17_discover_bookinfo.png`（左侧灰块）、`data/crash_log_2245.txt`、`p2e1_b01_cold_import_dialog.png`（崩溃提示，B 报告同图） |
| 3 | RSS：源→文章列表→详情逐级；返回逐级；切源替换；视频/登录/搜索 root 全屏 | **PASS（搜索 bridge 的设备项 BLOCKED）** | `b2c_a26_rss_source.png`、`b2c_a27_rss_article_detail.png`、`b2c_a28_rss_back_articles.png`、`b2c_a29_rss_back_sources.png`、`b2c_a30b_rss_switch_yuque.png`、`data/a58_video_articles.xml`、`b2c_a59_rss_video_root.png`、`b2c_a61_rss_menu.png`、`data/a64_rss_menu2.xml`、`b2c_a65_rss_login_root.png`、`b2c_a88_rss_search_root.png` |
| 4 | 窄屏/off 点书/文章→root 全屏；切 Tab 清右栏；双→单→双保留；窄屏返回不消费隐藏栈；My 双栏互斥 | **PASS** | `b2c_a32_tab_switch_shelf.png`、`b2c_a33_dual_bookinfo.png`、`b2c_a34_narrow_single.png`、`b2c_a35_narrow_back.png`、`b2c_a36_widen_restore.png`、`b2c_a37_my_dual.png`、`b2c_a38_back_shelf_pane_cleared.png`、`b2c_a39_narrow_bookinfo_root.png`、`b2c_a42_narrow_rss_article_root.png`、`b2c_a76_off_bookinfo_root.png`、`b2c_a80_off_bookinfo_root2.png`（off BookInfo）、`b2c_a82_rss_off_articles_root.png`、`b2c_a83_rss_off_article_root.png`（off RSS） |
| 5 | 回归：FATAL/ANR/overflow=0；右栏隐藏期间不自动开读；设置/阅读/返回 | **PASS（存在 Dart 异常 P1）** | `logcat/session_app.log`（6454 行）：`FATAL EXCEPTION`=0、`ANR in io.legado.flutter_legado`=0、`overflowed by`=0、`E/flutter`=0；`data/crash_log_2245.txt` 记录 Dart 异常（非 FATAL） |

## 三、逐场景证据

### 3.1 场景 1：书架列表-详情（PASS）

准备：书架两本既有本地 TXT（`qa_b2c_book_a` 未读、`qa_b2c_book_b` 已读）；验收中通过 DB 种子补 `qa_b2c_book_c`（未读，`loc_book`，2 章）验证「点另一本替换」。宽屏 1280×800 dp。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 未读单击 | 右栏 BookInfo、左书架保留 | 单击 A 后按设计**立即自动开读**（A4 语义），截图 `b2c_a02_unread_tap_0.4s.png` 已是阅读器 root；返回一次见右栏 BookInfo（左书架仍完整），`b2c_a05_back_to_bookinfo.png`、`data/a05_back_to_bookinfo.xml`。即初始落点确为右栏 BookInfo |
| 返回 | 回书架、右栏空 | 再返回一次回书架空右栏（`b2c_a06_back_shelf.png`，无「来源：」节点） |
| 长按 | 右栏 BookInfo、不自动开读 | 长按 B → 右栏 B 的 BookInfo，左书架保留（`b2c_a07_longpress_b.png`）；返回回书架（`b2c_a08_back_shelf2.png`） |
| 已读直读 | 阅读器 root 全屏、关闭后右栏空 | 点 B → 阅读器节点仅 `[0,0][1920,1200]`、无 Rail/底栏（`b2c_a09_read_book_reader.png`）；返回书架空右栏（`b2c_a10_read_back_shelf.png`） |
| 点另一本替换 | 右栏替换、返回不叠栈 | 右栏 A → 左列表点 C（未读）→ 阅读器 → 返回右栏 C（`b2c_a46_bookinfo_c_replace.png`）；返回一次即书架空右栏（`b2c_a47_replace_back_shelf.png`），证明 `replace` 未叠栈 |
| 长按替换 | 同上（长按入口） | 右栏 A → 长按 B → 右栏 B（`b2c_a12b_replace_b.png`）；一次返回回书架（`b2c_a13b_replace_back.png`） |
| 隐藏期间不自动开读 | 右栏隐藏时不消费自动开读机会 | 缩窄/切 Tab 期间未出现阅读器自启（后续 A4 场景）；`main_detail_pane_test.dart` 覆盖 |

### 3.2 场景 2：发现书单（FAIL，P1）

**路径 A（源内容模式，PASS）**：发现 → `QA_B2C源` → 点「切换到源内容」→ 源内容书单（左全宽）→ 点「QA探索书A」→ 右栏 BookInfo，左书单完整保留（`b2c_a19_source_content_mode.png`、`b2c_a20_source_content_bookinfo.png`）；点左书单「QA探索书B」→ 右栏替换为 B（`b2c_a23_source_content_bookB2.png`）；返回回书单（`b2c_a24_source_content_back2.png`）。

**路径 B（发现平板双栏，FAIL）**：发现源列表 → 展开 `QA_B2C源` → 点分类 `QA分类` → 左侧显示书单、右侧内容区（`b2c_a16_discover_books.png`）→ 点「QA探索书A」：
- 右栏 BookInfo 正常出现，但**左侧源/书单区域被一块灰色 `ErrorWidget` 覆盖**，语义树中左侧节点整体消失；截图 `b2c_a17_discover_bookinfo.png`；
- 应用崩溃日志（`data/crash_log_2245.txt`）：
  `Bad state: Too many elements`，栈 `#0 List.single` → `#1 ScrollController.position` → `#2 _Md3FastScrollerState._scrollable (md3_fast_scroller.dart:51)` → `#3 ... build`；
- 同一异常在 22:45:45 再次记录（从平板双栏切到源内容模式时；`b2c_a19_source_content_mode.png` 前后），说明宽度/布局切换即可触发；
- 下次冷启动弹出「上次运行发生崩溃」对话框（`p2e1_b01_cold_import_dialog.png` 背景可见；该图同时为 P2-E1 冷启动导入面板证据）。
- 返回一次后列表恢复（`b2c_a18_discover_back.png`），但崩溃日志/下次启动提示仍在。

**复现步骤（稳定）**：宽屏 1280×800dp → 发现 → 展开 `QA_B2C源` → 点 `QA分类`（书单出现）→ 点任一书籍卡片。
**期望**：右栏 BookInfo，左书单保留。
**实际**：左发现页灰块（ErrorWidget），Dart 异常 `Bad state: Too many elements`（`Md3FastScroller` 的 `ScrollController` 同时挂多个 position）。
**定位线索**：右栏占宽后 PageView 页区从 1280dp 缩到约 561dp，ExploreScreen 由平板双栏切单栏；`Md3FastScroller` 的滚动控制器在旧/新滚动视图切换期间同时持有多个 `ScrollPosition`，`controller.position` 的 `single` 抛错。建议修复为在 `_scrollable` 取 `positions` 的首个/最后活跃项或按 controller 绑定生命周期隔离；同时在 Explore 双栏/源内容切换时避免同一 controller 复用。

### 3.3 场景 3：RSS（主链 PASS；搜索 bridge 设备项 BLOCKED）

准备：本地 mock HTTP（宿主 `192.168.100.52:8899`）提供 `/feed.xml`（3 篇）、`/rss_bridge.xml`、`/video_feed.xml`；DB 中既有 `QA_B2C_RSS`（`http://192.168.100.52:8899/feed.xml`，`loginUrl=http://192.168.100.52:8899/login.html`）；另种子 `QA_B2C_VIDEO`（`type=2`，视频源）。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 源→文章列表 | 右栏文章列表、左源网格保留 | 点 `QA_B2C_RSS` → 右栏 3 篇文章、左源网格完整（`b2c_a26_rss_source.png`） |
| 文章→详情 | 右栏详情（同一右栏栈追加） | 点文章一 → 右栏「文章详情 / QA文章一」（`b2c_a27_rss_article_detail.png`）；左源网格仍保留 |
| 逐级返回 | 详情→列表→源网格 | 返回回文章列表（`b2c_a28_rss_back_articles.png`，文章一标记「已读」）；再返回回源网格（`b2c_a29_rss_back_sources.png`） |
| 切源替换 | 右栏替换为新源内容 | 点「使用说明」→ 右栏替换为语雀文章列表（`b2c_a30b_rss_switch_yuque.png`） |
| 视频 root | VideoScreen root 全屏、不进右栏 | `QA_B2C_VIDEO` 文章列表→点文章：`VideoScreen` 全屏、无底栏 Tab（`b2c_a59_rss_video_root.png`；夹具为 1KB 假 mp4，播放报源错误，属夹具限制） |
| 登录 root | SourceLoginScreen root 全屏 | 文章列表右上 ⋮ →「登录」→「登录 - QA_B2C_RSS」全屏，无主壳底栏（`b2c_a65_rss_login_root.png`） |
| 搜索 | standalone 搜索 root 全屏 | **设备未构造成功（BLOCKED）**：顶部搜索实际是「源内文章搜索」，提交后停留在右栏（`b2c_a88_rss_search_root.png`，仍可见 5 个底栏 Tab；因 mock 未提供 `/search` 返回 404，属夹具）；`java.searchBook` → `openRssArticleSearch` root 分流由 `test/widget/main_detail_pane_test.dart:1017`（「RSS searchBook 桥：搜索固定 root 全屏」）覆盖，**未在设备上触发** |

### 3.4 场景 4：窄屏 / off / 栈与互斥（PASS）

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 切 Tab 清右栏 | 右栏清空、不恢复旧详情 | 书架右栏 B → 切「发现」→ 回「书架」：右栏空（`b2c_a32_tab_switch_shelf.png`，无来源节点） |
| 双→单→双保留 | 右栏栈与页面保留 | 宽屏右栏 B（`b2c_a33_dual_bookinfo.png`）→ 1200×1920（800×1280dp）单栏（`b2c_a34_narrow_single.png`）→ 返回一次（`b2c_a35_narrow_back.png`）→ 恢复 1920×1200：右栏 B 原样恢复（`b2c_a36_widen_restore.png`） |
| 窄屏返回不消费隐藏栈 | 返回不 pop 隐藏右栏 | 窄屏返回后应用仍在前台、未退出；恢复宽屏右栏 B 仍在（同上），证明隐藏栈未被消费 |
| 窄屏点书 | root 全屏、无主壳 | 800×1280dp 长按书 → BookInfo 全屏、无 Tab/底栏（`b2c_a39_narrow_bookinfo_root.png`，tabs=0） |
| 窄屏 RSS | 源→文章列表→详情均 root | 源→文章列表全屏（`b2c_a41_narrow_rss_articles_root.png`，tabs=0）；文章详情全屏（`b2c_a42_narrow_rss_article_root.png`，tabs=0）；返回逐级（`b2c_a43/a44`） |
| off 宽屏点书 | root 全屏 | 多栏布局=关闭（pref `multiPaneMode=off`）→ 长按书 → BookInfo 全屏、无 Tab（`b2c_a76_off_bookinfo_root.png`/`b2c_a80_off_bookinfo_root2.png`，tabs=0） |
| off 宽屏 RSS | 源/详情 root | 源→文章列表全屏（`b2c_a82_rss_off_articles_root.png`，tabs=0）；文章详情全屏（`b2c_a83_rss_off_article_root.png`，tabs=0） |
| My 双栏互斥 | 切到我的时清空列表-详情右栏 | 从书架右栏 B 切「我的」→ 双栏菜单 +「选择左侧项目」，书架详情消失（`b2c_a37_my_dual.png`）；回书架右栏空（`b2c_a38_back_shelf_pane_cleared.png`） |

### 3.5 场景 5：回归（FATAL/ANR/overflow=0，Dart 异常 P1）

- `logcat/session_app.log`（6454 行，全程 22:40~23:14）：
  - `FATAL EXCEPTION` = **0**
  - `ANR in io.legado.flutter_legado` = **0**
  - `overflowed by` = **0**
  - `E/flutter` = **0**
- 但应用自捕获 Dart 异常 2 次：`Bad state: Too many elements`（P1，见 §3.2）与一次 `HttpException: Invalid statusCode: 404 … /comic/img4.png`（23:00:55，C 夹具未提供静态图导致；补齐后未再新增，见 9b-3 报告）。
- 既有 P3：删除书籍后书架不即时刷新（本批清空后重启显示空态正常）；输入焦点吞首次返回（既有）。

## 四、问题与观察清单

| 编号 | 级别 | 描述 | 影响 / 建议 |
|---|---|---|---|
| P1-O1 | **P1** | 宽屏发现平板双栏书单点书 → 左侧发现页被 `ErrorWidget` 灰块覆盖，崩溃日志 `Bad state: Too many elements`（`Md3FastScroller._scrollable` 取 `ScrollController.position` 时多 position）；切到源内容模式亦可触发 | 用户可见内容丢失 + 下次启动崩溃提示；主路径不通过。建议修复 fast scroller 多 position 取值/生命周期，并在 1280dp→561dp 布局切换时避免复用同一 controller；修复后复验本场景 |
| P2-O1 | P2（构建环境） | armeabi-v7a `.so` 构建 quickjs 失败（第三方 `rar 0.4.0` 32 位 `u64: ToUsize` 编译错误），脚本回退到无 quickjs 仍以 `quickjs=false` 产出；x86_64/arm64 为 `quickjs=true` | 当前设备 x86_64 不受影响；若需 32 位 JS 能力需修 rar/依赖或裁剪；非本批 Rust 逻辑回归（10-31 产物亦为 false），登记待处理 |
| P2-O2 | P2（口径/夹具） | RSS 顶部「搜索」实际为源内文章搜索，提交后留在右栏（仍见底栏）；standalone 搜索 root 仅由 `java.searchBook` 桥触发，设备未构造 | 若验收「RSS 搜索」指顶部搜索，则与「root 全屏」不符；若指 WebView 桥，则当前实现正确但设备项未证明。建议产品确认口径并补设备桥链夹具 |
| P3-O1 | P3（既有） | 输入聚焦时首次系统返回被焦点吞掉；UI 左上返回即时 | 既有模式（M3 已登记），非本批引入 |
| P3-O2 | P3（夹具） | 漫画/视频夹具使用 1×1 PNG / 1KB 假 mp4，阅读器显示「图片加载失败」「视频加载失败」 | 不影响路由与保留逻辑断言；真实媒体加载未覆盖 |

**未覆盖 / 声明**：
- 发现平板双栏路径未做 2× 字体/最小 744dp 溢出复测（该路径已在 P1 崩溃，优先修复）。
- RSS `java.searchBook` 设备项未构造（见 P2-O2），以 `main_detail_pane_test.dart` widget 测试为行为证据，未声称设备通过。
- 铰链/折叠、左栏 420、`supportsMainPanes` 其余路由对不在本批范围。
- 「大屏导航形态=关闭（无 Rail）」下 always/auto 的窗口阈值未复测（2b-2b 已覆盖纯函数）。

## 五、证据与产物索引

| 类别 | 路径 |
|---|---|
| 构建/安装 | `tmp_debug/device_acceptance_20261104/logcat/rust_build.log`、`build_release.log`、`install.log`；`data/apk_sha256.txt`、`data/so_evidence.txt`、`data/version_installed.txt` |
| 门禁 | `tmp_debug/device_acceptance_20261104/logcat/flutter_test_all.log`；Rust 定向输出见报告 §1.2 |
| 会话日志 | `tmp_debug/device_acceptance_20261104/logcat/session_app.log`（6454 行，FATAL/ANR/overflow/E-flutter=0） |
| 崩溃证据 | `tmp_debug/device_acceptance_20261104/data/crash_log_2245.txt`（Bad state 全栈）；`shots/a17_discover_bookinfo.png`（灰块）；`shots/b01_cold_import_dialog.png`（下次启动提示） |
| 语义树 | `tmp_debug/device_acceptance_20261104/data/a*.xml`（书架/发现/RSS/窄屏/off 各步） |
| 截图 | `docs/materials_1109b/b2c_*.png` |
| 交互脚本 | `tmp_debug/device_acceptance_20261104/scripts/dev.py`（QA 辅助，未改应用代码） |

---

编写：QA（设备验收子代理） · 2026-11-03

---

## 六、A2 回修复验（2026-11-03 23:42 ~ 23:57）

> 复验基线：`master` HEAD **`eb9a74bbe3`**（`fix(ui): 2b-2c 双栏 ScrollController 隔离`）。
> 修复内容：`home_screen.dart` 右栏独立 `PrimaryScrollController`；
> `adaptive_my_pane.dart` 同类隔离；`md3_fast_scroller.dart` 不再访问
> `controller.position`，改按 `positions` + 子树定位。
> 设备同前：MuMu index 1「Test测试」，`192.168.100.62:5555`，
> SM-G9900 / Android 15（SDK 35）/ x86_64，`wm size 1920x1200` + `wm density 240`
> （**1280×800 dp**）。QA 未修改应用代码。

### 6.1 修复前后对照

| 维度 | 2b-2c 首轮（HEAD `ec0a146d09`） | 本轮（HEAD `eb9a74bbe3`） |
|---|---|---|
| 宽屏发现「源列表→分类→点书」左发现页 | 整块 `ErrorWidget` 灰块，左侧语义节点消失（`b2c_a17_discover_bookinfo.png`） | 左发现页正常渲染，无灰块；`a2r_06_bookinfo_after.png` 左侧仍见 `QA_B2C源` 列表，右侧为 BookInfo |
| Dart 异常 | `Bad state: Too many elements`，栈 `md3_fast_scroller.dart:51`（`crash_log_2245.txt`） | `Bad state`=0、`Too many elements`=0（全量 logcat 3,217,779 行） |
| 下次冷启动崩溃提示 | 弹出「上次运行发生崩溃」（`p2e1_b01_cold_import_dialog.png`） | 冷启动无崩溃提示；`flutter.crash_last_crash=false`，应用私有目录无 crash 文件（`a2r_70_cleanup_empty_shelf.png`） |
| 右侧 BookInfo | 出现，但左侧灰块 | 出现；A→返回→B 正常替换（`a2r_06/a2r_07/a2r_08`） |
| 左右滚动 | 同一 controller 多 position，滚动即可能触发断言 | 左右滚动像素级隔离（§6.4），快速滚动条可拖动 |

### 6.2 构建与安装

仅 Dart 变更，Rust 复用 9b-3 产物，未重编 Rust。

| 项 | 值 / 证据 |
|---|---|
| `flutter build apk --release` | **EXIT=0**，`Running Gradle task 'assembleRelease'... 49.4s`，`Built ... app-release.apk (191.4MB)`（`tmp_debug/reverify_a2/logcat/build_release.log`） |
| APK | **200,698,008 B**，sha256 **`619dc57f5d6a5dfba01bed1d8e1e7367135ee69f1b350d6fb53c4c3cc8839c09`**（`data/apk_sha256.txt`） |
| x86_64 `.so` | **51,938,080 B**，mtime **2026-11-03 22:34:50**，sha256 **`5c29e4dd963272bbe3355688c67adeb9e414cc33c155ba3b81a9d2a22982b68c`**（9b-3 产物，mtime 未变=未重编）；APK 内 `lib/x86_64/liblegado_ffi.so` 为 Gradle strip 后 **39,402,984 B / `ef67b4f5…`**（`data/version_installed.txt`） |
| 安装 | `adb install -r` **Success: streamed 200698008 bytes**（`logcat/install.log`）；设备 `base.apk` sha256 与构建产物一致（`619dc57f…`） |
| 版本 | versionName **2.0.445** / versionCode **446**；`lastUpdateTime=2026-11-03 23:42:17` |
| 设备状态复核 | `wm size`=Physical 1080×1920（override 已 reset）；`wm density`=480；`multiPaneMode=auto` |

### 6.3 逐项结果

| # | 复验项 | 结果 | 证据 |
|---|---|---|---|
| A2-R1 | 1280dp 发现→展开 `QA_B2C源`→`QA分类`→点 `QA探索书A`：右栏 BookInfo、左发现页正常无 ErrorWidget/灰块、无 `Bad state` | **PASS** | `a2r_04_books_before.png`（点前双栏）、`a2r_05_tap_book_0.5s.png`、`a2r_06_bookinfo_after.png`（左源列表可见、无灰块）；`data/a2r_06_bookinfo_after.xml` 记录右栏 BookInfo（左栏未包含在该 UI 树导出中）；日志 0 异常 |
| A2-R2 | 返回、进入下一本 `QA探索书B`、右栏替换不叠栈 | **PASS** | 返回恢复双栏书单 `a2r_07_back_to_explore.png`；点 B 右栏替换 `a2r_08_bookB.png`（`QA探索书B`，左侧发现页正常显示源列表） |
| A2-R3 | 左右滚动独立；`Md3FastScroller` 可见/拖动正常 | **PASS** | `a2r_19/a2r_22` 左书源列表可见滑块；`a2r_20` 左滚；`a2r_23` 右滚；`a2r_24` 拖动滑块至列表尾部（`QA_A2源16~24`）；像素差分见 §6.4 |
| A2-R4 | My 双栏右栏长列表滚动与左菜单独立、无异常 | **PASS** | `a2r_30_my_dual.png`、`a2r_31_my_sources.png`（右栏 25 条书源）；`a2r_32_my_right_scrolled.png`（左 0.000%/右 11.454%）、`a2r_33_my_left_scrolled.png`（左 17.474%/右 0.000%） |
| A2-R5 | 快速宽度 1280→800→1280 ×3：无 ErrorWidget/崩溃；右栏栈恢复 | **PASS** | 3 次窄屏截图 sha256 完全一致 `24fdf33d…`；3 次宽屏完全一致 `fe8bd909…`；窄屏书架 `a2r_43_cycle3_narrow.png`，宽屏右栏 BookInfo 恢复 `a2r_44_cycle3_wide.png` + `data/a2r_45_wide_restore.xml` |
| A2-R6 | 回归：书架双栏、RSS 双栏、窄屏 root、切 Tab | **PASS** | 书架双栏 `a2r_42_bookinfo_longpress.png`；RSS 列表/详情右栏 `a2r_51_rss_articles.png`、`a2r_52_rss_detail.png`；切 Tab 清右栏 `a2r_54_tab_switch_cleared.png`（与 `a2r_53` sha256 相同 `11372984…`）；窄屏 BookInfo root `a2r_57_narrow_bookinfo_root.png`（无 Tab 节点）、窄屏 RSS 列表/详情 root `a2r_59/a2r_60`（全宽、无 Tab） |
| A2-R7 | FATAL/ANR/overflow=0；无 crash_log | **PASS** | 全量 logcat 3,217,779 行：`FATAL`=0、`ANR`=0、`E/flutter`=0、`overflowed by`=0、`Bad state`=0、`Too many elements`=0；`flutter.crash_last_crash=false`，无 crash 文件（§6.5） |
| A2-R8 | 清理：分辨率/auto/空书架，保留版本 | **PASS** | `wm size reset`→1080×1920、`wm density reset`→480；`multiPaneMode=auto`；书架空态 `a2r_70_cleanup_empty_shelf.png`；DB books=0、`QA_A2源*`=0、`cache/qa_a2` 已删；版本仍 2.0.445+446 |

> 夹具说明：为覆盖滚动/长列表，本轮临时向 DB 种入 12 本本地书、24 个 `QA_A2源*`、
> explore 夹具扩至 43 本书并给书 A 加长简介；均为验收临时数据，§6.6 已全部清理。
> 原 `QA_B2C源` / `QA_B2C_RSS` 未改动。

### 6.4 左右滚动隔离量化（截图像素差分，阈值单通道 >8）

| 操作 | 左区域变化 | 右区域变化 | 判定 |
|---|---|---|---|
| 左发现书源列表上滑（`a2r_19`→`a2r_20`） | **15.796%** | 0.009%（94/1,042,200，仅分栏线边缘） | 左动右不动 |
| 右 BookInfo 上滑（`a2r_22`→`a2r_23`） | **0.000%**（0/685,150） | **32.981%** | 右动左不动 |
| 拖动左侧快速滚动条（`a2r_23`→`a2r_24`） | **15.229%** | 0.009%（94 像素，分栏线） | 左动右不动 |

### 6.5 日志与崩溃证据

- 全量：`tmp_debug/reverify_a2/logcat/session_app.log.gz`（3,217,779 行，23:43~23:57；
  其中 `E/MESA` 3,211,371 行为 MuMu 图形驱动噪声，已单独过滤）。
- 过滤版：`tmp_debug/reverify_a2/logcat/session_app_filtered.log`（6,023 行）。
- 计数（全量与过滤版一致）：`Bad state`=0、`Too many elements`=0、`E/flutter`=0、
  `FATAL`=0、`ANR`=0、`overflowed by`=0、`ErrorWidget`=0。
- `shared_prefs/FlutterSharedPreferences.xml`：`flutter.crash_last_crash=false`；
  `/data/data/io.legado.flutter_legado/files/` 无 crash 文件。
- 冷启动（清理后）无「上次运行发生崩溃」对话框：`a2r_70_cleanup_empty_shelf.png`。

### 6.6 清理结果

| 项 | 结果 |
|---|---|
| 分辨率/密度 | `wm size reset` / `wm density reset` → Physical 1080×1920 / 480 dpi |
| 多栏模式 | `flutter.multiPaneMode=auto` |
| 书架 | `books`=0，空态「书架还空着…」（`a2r_70_cleanup_empty_shelf.png`） |
| 临时源/章节/进度 | `QA_A2源*`=0、`qa_a2` 章节=0、`readRecord` QA 行=0 |
| 临时文件 | `/data/data/io.legado.flutter_legado/cache/qa_a2/` 已删除 |
| 版本 | 保留 **2.0.445+446**（`lastUpdateTime=2026-11-03 23:42:17`） |

### 6.7 结论与残余观察

- **A2 关闭**：首轮 P1 的「左发现页 `ErrorWidget` 灰块 + `Bad state: Too many elements`」
  在 `eb9a74bbe3` 上未再出现；主路径、下一本/返回、左右滚动隔离、快速滚动条、
  My 双栏、快速宽度切换、书架/RSS/窄屏/切 Tab 回归全部通过；FATAL/ANR/overflow=0。
- **残余观察 O1（非阻塞，非本轮修复目标）**：宽屏点击书籍打开右栏后，主区宽度降至
  约 561dp（<840dp），`ExploreScreen` 按响应式规则切回单栏，左侧只保留「发现书源列表」，
  不再显示刚选中的「QA分类」书单；返回宽屏后书单恢复（`a2r_07_back_to_explore.png`）。
  本轮 A2 判定标准为「无 ErrorWidget/灰块、无崩溃」，故不阻塞关闭；若产品仍要求
  「点书后左书单必须保留」，需另立 P2 跟踪响应式降级行为。
- 未发现新增 P1/P2 缺陷；未复测项：2× 字体/最小 744dp 溢出、铰链/折叠——仍沿用首轮声明。

> 证据目录：截图 `docs/materials_1109b/reverify_a2/`（36 张）；
> XML/日志/哈希 `tmp_debug/reverify_a2/{data,logcat}/`；交互脚本
> `tmp_debug/reverify_a2/scripts/dev.py`（QA 辅助，未改应用代码）。

编写：QA（设备验收子代理） · 2026-11-03 23:57
