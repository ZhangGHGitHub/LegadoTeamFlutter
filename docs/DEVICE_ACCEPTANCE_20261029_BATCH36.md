# 批 36 设备验收报告（发现页源内容模式 / 页码跳转）

> 范围：批 36（`739740849b` … `46e7ccba74`）——发现页新增「源内容」模式
> （顶栏源列表 ⇄ 源内容切换、分类 Tab、书源选择 sheet 搜索/分组/列表或网格/列数、
> 单书源搜索、`exploreMainContent` / `exploreMainSourceUrl` / `exploreMainKind`
> 三键持久化与启动恢复、源删除回退、加载失败不清偏好），以及发现列表页码跳转
> （按规则显隐、数字输入、失败回退与重试）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线，adbd `uid=0`）。
>
> **结论**：场景 1~5、7、8 为 **PASS**；**场景 6 为 FAIL（阻塞）**——源内容模式下按
> 系统返回键会退出「发现」Tab 回到「书架」，而不是停留在发现页并回到源列表。
> 缺陷根因与复现见 §五.1。其余 3 项观察（显示尺寸改写触发的既有 FastScroller
> Dart 异常、DB 不可读时的引擎初始化失败、尺寸改写后的 Tab/内容短暂不同步）均由
> 验收注入操作触发，非批 36 引入，见 §五.2~§五.4。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 / 密度 | 1080x1920 / 480dpi（验收结束后已恢复原值） |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，`uid=0`） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.413** / versionCode **414**（2026-10-29 19:06 安装），DB v117、299,008 字节、1 个书源（`批25口令源`，`enabledExplore=0`）、书架空 |
| 验收版本 | versionName **2.0.414** / versionCode **415**（设备 `dumpsys` 与 APK badging 一致） |
| 源码基线 | `master` HEAD `46e7ccba74`（`chore: 批36 收尾（2.0.414+415 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-29 20:46 ~ 21:11（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261029_batch36/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 升级前备份

安装前 `am force-stop` 后完整拉取：

- `db/legado_pre_upgrade_2.0.413.db`（v117，299,008 字节，`book_sources=1`、`books=0`）；
- `prefs/FlutterSharedPreferences_pre_upgrade.xml`（5 个键）。

批 36 无 DB schema 变更：升级前后与清理后 `PRAGMA user_version` 均为 **117**。

### 1.2 构建

- `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`
  退出码 **0**（`logcat/rust_build_batch36.log`）。三 ABI `liblegado_ffi.so` 已复制到
  `flutter_legado/android/app/src/main/jniLibs/`。
  - 既有环境项（非本批引入）：armv7 + quickjs 编译失败（`rar` 3 errors），脚本按既有
    逻辑回退重试后成功；本机 x86_64 设备不受影响。
- `cd flutter_legado && flutter build apk --release` 退出码 **0**
  （`logcat/flutter_build_batch36.log`），产物
  `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`
  （197,607,168 字节，sha1 `bc7d98c304baede3b8f7523b68bb17d2431231ba`，
  `logcat/apk_sha1.txt`）。
- `aapt dump badging`：`versionCode='415' versionName='2.0.414'`
  （`logcat/apk_badging.txt`）。
- `adb install -r`：`Success: streamed 197607168 bytes`
  （`logcat/install_batch36.log`）。

### 1.3 测试数据与故障注入

为覆盖「页码规则 / 不支持页码 / 待删源」三类场景，向设备 DB 注入 3 个本地规则书源
（SQL 见 `seed_batch36.sql`），指向宿主机模拟书源（`mock_server.py`）：

| 源 | exploreUrl | 用途 |
|---|---|---|
| `QA36分页源` | `玄幻::http://127.0.0.1:18080/explore?kind=xh&page={{page}}` + `都市::…`（无页码） | 页码按钮显示/跳页；同源内分类切换 |
| `QA36无页码源` | `榜单::http://127.0.0.1:18080/explore?kind=xh` | 不支持页码 → 按钮隐藏 |
| `QA36待删源` | `删除分类::…&page={{page}}` | 源删除回退与偏好清理 |

设备经 `adb reverse tcp:18080 tcp:18080` 访问模拟服务（`http://127.0.0.1:18080`，
设备侧 `toybox nc` 实测 `HTTP/1.0 200 OK`）。「断网」通过移除 adb reverse 实现
（连接被拒，等同于该源不可达）。

## 二、验收场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 源内容模式：显示源分类与书籍 / 分类切换 / 书源 sheet（搜索/分组/列表或网格/列数）/ 单书源搜索 / 重启恢复 | **PASS** | `shots/01~14`、`prefs/prefs_after_content_mode.xml` |
| 2 | 源删除回退：返回源列表 + 偏好清理 + 重启不回内容模式 | **PASS** | `shots/30~33`、`prefs/prefs_after_delete_source.xml` |
| 3 | 加载失败不清偏好：离线启动 / 书源加载失败均保留偏好，恢复后回内容模式 | **PASS** | `shots/34~40`、`prefs/prefs_offline_restart.xml`、`prefs/prefs_booksource_failure.xml` |
| 4 | 页码跳转：按规则显隐 / 跳 2、3 / 空与 0 禁用 / 5 位截断 | **PASS** | `shots/03、07、15~20` |
| 5 | 跳页失败：错误提示、页码不前进、重试按目标页重放 | **PASS** | `shots/21、22` |
| 6 | 系统返回：内容模式返回键回源列表（不退出发现） | **FAIL** | `shots/23、24、26`、`logcat/crash_log.txt`（无）；复现 2 次 |
| 7 | 回归：源列表/双栏（可选）/探索详情/搜索/书架/阅读器 + FATAL/ANR | **PASS**（附观察） | `shots/41~47、56、63`、`logcat/logcat_full_session.log`、`logcat/exit_info.log` |
| 8 | 清理：恢复升级前 DB/偏好、删除测试数据 | **PASS** | `db/post_cleanup_state.txt`、`prefs/prefs_post_cleanup.xml`、`shots/64、65` |

> 原始命令输出与逐步记录：`tmp_debug/device_acceptance_20261029_batch36/`。
> 定向单元/组件测试：`flutter test`（批 36 相关 5 个文件）**60 tests all passed**
> （`logcat/flutter_test_batch36.log`）。

## 三、逐场景说明

### 场景 1：源内容模式 — PASS

- **切换入口**：源列表顶栏 `⇄`（tooltip「切换到源内容」）→ 内容模式顶栏显示
  「发现 / QA36分页源」，分类 Tab「玄幻 / 都市」，右侧「第 1 页」按钮，列表显示
  「玄幻第1页-书1~3」（封面/作者/分类标签齐全，`shots/02`）。
- **分类切换**：点「都市」→ 列表变为「都市第1页-书1~3」；该分类 URL 无页码占位符，
  页码按钮同时隐藏（`shots/03`），符合「不支持页码不显示」。
- **书源选择 sheet**（`shots/04~06、08`）：标题「选择书源」，含列表/网格分段、
  「3 列」步进（点 + 两次到 5 列）、搜索框「搜索书源（名称/地址）」、分组 chips
  （全部 / QA36）、当前源高亮勾选；选择「QA36无页码源」后内容区切到其分类「榜单」，
  网格按 5 列渲染（`shots/07`）；再切回「QA36分页源」并恢复列表（`shots/09`）。
  分组筛选、搜索框控件均已呈现（本批 UI 验收按控件存在与切换行为判定）。
- **单书源搜索**：内容模式顶栏搜索图标 → 搜索页；「搜索范围」中
  **仅「QA36分页源」被勾选**（`shots/11_search_source_scope.png`）；输入 `QA` 后
  展示「结果 2 · 进度 1/1」「1 书源」与两条结果（`shots/12`），证明进入的是
  单书源搜索而非全部源搜索。
- **重启恢复**：`am force-stop` 后冷启动 → 进入「发现」直接恢复内容模式，源
  `QA36分页源`、分类 `玄幻`、页码「第 1 页」均还原（`shots/14`）。
  `prefs/prefs_after_content_mode.xml` 实测三键：
  `exploreMainContent=true`、`exploreMainSourceUrl=https://qa36.local/paged`、
  `exploreMainKind` 含 `玄幻` 分类 URL；布局键 `explore_layout_mode=0`、
  `explore_layout_grid_portrait=5`。

### 场景 2：源删除回退 — PASS

1. 内容模式选择 `QA36待删源`，偏好落盘 `exploreMainSourceUrl=https://qa36.local/deletable`
   （`prefs/prefs_before_delete_source.xml`、`shots/28`）。
2. 通过 UI 删除源：我的 → 书源管理 → 勾选 `QA36待删源` → 删除 → 确认
   （`shots/30、31`）。
3. 返回「发现」：**已回到源列表**，列表只剩 2 个源（`shots/32`）。
4. 偏好被清理（`prefs/prefs_after_delete_source.xml`）：
   `exploreMainContent=false`、`exploreMainSourceUrl` 为空、
   `exploreMainKind` 仅保留仍存在的 `QA36分页源` 条目（孤儿条目被裁剪）。
5. 冷启动后再次进入「发现」仍为源列表（`shots/33`），未回到内容模式。

### 场景 3：加载失败不清偏好 — PASS

- **3a 离线启动（源不可达）**：内容模式下移除 adb reverse 后冷启动 → 发现页仍保持
  内容模式（标题/源名/分类 Tab/页码按钮均在），书单区为网络错误视图 + 「重试」
  （`shots/35`）；偏好保持 `exploreMainContent=true`、
  `exploreMainSourceUrl=https://qa36.local/paged`（`prefs/prefs_offline_restart.xml`）。
  恢复 reverse 后点「重试」→ 正常加载第 1 页书籍（`shots/36`）。
- **3b 书源加载失败（DB 查询失败）**：停止应用后把 `book_sources` 表改名为
  `book_sources_qa36bak`（模拟 `getBookSources()` 抛错）→ 启动进入发现页：
  **回退到源列表 UI**，显示「加载书源失败：Database error: … no such table:
  book_sources」+「重试」（`shots/39`）；偏好仍为 `exploreMainContent=true` /
  `exploreMainSourceUrl=…paged`（`prefs/prefs_booksource_failure.xml`），即只回退 UI
  不清偏好。恢复表名后点「重试」→ **自动回到内容模式**并加载第 1 页（`shots/40`）。
- 补充（不参与判定）：直接把 DB 文件 `chmod 000` 会让 Rust 引擎初始化失败，
  应用停在「Rust 引擎初始化失败」页（`shots/37`），属于比「书源加载失败」更早的
  初始化故障；权限已当场恢复。详见 §五.3。

### 场景 4：页码跳转 — PASS

- **按钮显隐**：分类「玄幻」URL 含 `{{page}}` → 显示「第 1 页」（`shots/02`）；
  「都市」分类与 `QA36无页码源` 的分类「榜单」均不显示页码按钮（`shots/03、07`）。
- **跳页**：点「第 1 页」→「跳转到页码」弹层（提示 1-9999，输入框预填当前页，
  `shots/15`）；清空输入 `2` 确定 → 列表变为「玄幻第2页-书1~3」，按钮「第 2 页」，
  顶部出现「上滑加载上一页」（`shots/16`）；再跳 `3` → 「第 3 页」+ 第 3 页书籍
  （`shots/17`）。
- **非法输入**：清空 → 「确定」灰色不可点（`shots/18`）；输入 `0` → 「确定」仍不可点
  （`shots/19`）；输入 `12345` → 输入框截断为 `1234`（4 位上限，`shots/20`）。
  需求允许「禁用或截断」，本次实现为 4 位截断 + ≥1 才可确认，符合参考版语义。

### 场景 5：跳页失败与重试 — PASS

- 当前第 3 页时移除 adb reverse（源不可达）→ 跳 `4`：列表区显示
  「Network error: 请求发现页失败…Connection refused (os error 111)」，
  错误 URL 为 `…&page=4`，顶栏页码**保持「第 3 页」**（`shots/21`），未错误前进。
- 恢复 reverse 后点「重试」：**按目标页 4 重放**，加载「玄幻第4页-书1~3」，
  页码变为「第 4 页」（`shots/22`）。

### 场景 6：系统返回键 — FAIL（阻塞）

复现步骤（两次一致，20:55 与 20:56）：

1. 发现页进入源内容模式（如 `shots/22` 第 4 页、`shots/25` 再次进入）；
2. 按一次系统返回键（`adb shell input keyevent 4`）；
3. **实际**：直接切到「书架」Tab（`shots/23`、`shots/26`），即退出了「发现」；
   再次点「发现」时内容为源列表（`shots/24`），说明内容模式的 `PopScope`
   回调确实执行了 `setShowContent(false)`，但同一帧里 Tab 也被切走。
4. **期望**（本批验收要求）：停留「发现」，由内容模式回到源列表；不得退出发现/
   退出应用。

根因定位（未修改代码）：

- `flutter_legado/lib/src/screens/explore_screen.dart:103-110`：内容模式挂
  `PopScope(canPop: false)`，`onPopInvokedWithResult` 中 `setShowContent(false)`；
- `flutter_legado/lib/src/screens/home_screen.dart:252-256`：`HomeScreen` 根节点同样
  挂 `PopScope(canPop: false)`，回调 `_handleBack`；而 `_handleBack`
  （同文件 161-169 行）对任何非「书架」Tab 直接切回书架。
- 两者位于同一 `ModalRoute`，Flutter 返回处理会**依次通知所有 `PopScope` 条目**
  （`didPop=false`），因此内层 `PopScope` 无法「消费」本次返回；结果是内容模式
  关闭 + Tab 切回书架同时发生。批 36 的组件测试
  `explore_source_content_test.dart`「系统返回键在内容模式先回源列表（PopScope）」
  通过，是因为测试直接挂载 `ExploreScreen`、没有 `HomeScreen` 这一层。

修复方向（供实现方参考）：`HomeScreen._handleBack` 在切 Tab 前检查「当前是否由
子页面消费返回」（例如内容模式状态/返回消费标记），或在发现页内容模式激活时
让根 `PopScope` 跳过 Tab 回退。本报告不改业务代码。

### 场景 7：回归 — PASS（附观察）

- **发现源列表**：3 个源正常展示；点源行展开「玄幻 / 都市」分类 chips（`shots/46`）；
- **探索详情页**：点「玄幻」chip 进入「玄幻 - QA36分页源」书单页，页码按钮/筛选/
  视图切换入口均在（`shots/47`）；
- **书籍详情**：从内容模式点书 → 详情页展示书名/作者/来源/分类/目录（共 3 章）/
  简介，操作区「加书架 / 查看目录 / 书源 / 阅读记录 / 阅读」正常（`shots/41`）；
- **书架**：加入后书架显示书籍与进度/标签（`shots/42、43`）；
- **阅读器**：打开后正文正常加载（第 1 章、进度 33.3%，`shots/44`）；
- **搜索**：单书源搜索入口与结果正常（`shots/10~12`）；
- **订阅（RSS）**：页面正常，空态「当前没有订阅源！」（`shots/63`）；
- **双栏（可选）**：`wm size 1600x2560` + `wm density 240` 下，发现页呈现
  「左源列表 + 右内容」双栏（右侧空态「选择发现分类」，`shots/56`）；已恢复
  1080x1920/480。
- **FATAL=0、ANR=0**：`logcat_full_session.log` 中 `FATAL EXCEPTION` 计数 0、
  `ANR in io.legado` 计数 0；`dumpsys activity exit-info` 全部为
  `USER REQUESTED/FORCE STOP/PACKAGE UPDATED`，无 CRASH/ANR reason
  （`logcat/exit_info.log`）。
- 尺寸改写与异常注入引起的 2 条 Dart 级异常不属于上述统计（见 §五.2、§五.3）。

### 场景 8：清理 — PASS

- 恢复升级前 DB（`db/legado_pre_upgrade_2.0.413.db`）与偏好
  （`prefs/FlutterSharedPreferences_pre_upgrade.xml`）；
- 删除 `/data/local/tmp/legado.db`、恢复用临时文件、`app_flutter/crash_log.txt`；
  移除 `adb reverse` 并停止模拟书源服务；
- 复核（`db/post_cleanup_state.txt`）：`user_version=117`、`book_sources=1`
  （`批25口令源`，`enabledExplore=0`）、`books=0`、`chapters=0`，`book_sources`
  表名已还原；偏好与升级前**逐字节一致**（`PREFS_IDENTICAL`）；
- 重启应用：书架空态（`shots/64`）、发现页「当前没有发现源！」（`shots/65`，
  与升级前一致），版本 2.0.414/415 正常运行；清理后 logcat FATAL=0、ANR=0。

## 四、门禁与证据固化

- 本批为设备验收，不重复 CI 已覆盖的全量 `cargo test` / `flutter analyze && flutter test`
  / `:app:testAppReleaseUnitTest`（按 AGENTS.md 完成定义以 CI 为准）。
- 额外执行批 36 定向测试（5 个文件，含页码规则、Notifier、跳页与源内容页面）：
  **60 tests all passed**（`logcat/flutter_test_batch36.log`，退出码 0）。
- 设备侧证据：截图 71 张、DB/偏好快照、构建/安装/日志与模拟书源脚本，均位于
  `tmp_debug/device_acceptance_20261029_batch36/`（不入库）。

## 五、缺陷与观察

1. **【阻塞/P1】场景 6：内容模式系统返回退出「发现」**。复现 2 次；根因是
   `HomeScreen` 与 `ExploreScreen` 两个 `PopScope` 同属一个 Route，返回时都会收到
   回调，`HomeScreen._handleBack` 把非书架 Tab 切回书架，导致无法停留在发现页。
   期望：内容模式返回后仍处于「发现」并显示源列表。影响：本批验收场景 6 不通过。
2. **【观察/既有】显示尺寸在线改写触发 `Bad state: Too many elements`**：
   在 `wm size 1600x2560; wm density 240` → 恢复 1080x1920/480 的过程中，21:07:17
   应用自身崩溃记录器捕获到
   `ScrollController.position`（`List.single`）异常，栈指向
   `flutter_legado/lib/src/widgets/md3_fast_scroller.dart:51/65`
   （`_scrollable` 在布局切换瞬间同时存在多个 `ScrollPosition`）。完整栈见
   `logcat/crash_log.txt`。该组件来自既有 UI_SYNC_REFACTOR（`f81f7f5e05`），
   与批 36 无关；进程未崩溃（Dart 层捕获），下次启动显示「上次运行发生崩溃」弹窗。
   仅在人为改写显示尺寸时触发，正常使用未见。
3. **【观察/环境注入】DB 文件不可读时引擎初始化失败**：`chmod 000 legado.db` 后启动，
   应用显示「Rust 引擎初始化失败 / Instance of 'BridgeError'」（`shots/37`），
   无法进入主界面；该次启动在下一次打开时留下崩溃弹窗
   （`shots/38`，错误 `Instance of 'BridgeError'`）。这是验收为模拟「书源查询失败」
   所做的注入，权限已恢复；「加载失败不清偏好」改用 `book_sources` 表缺失场景验证
   （§场景 3b）。非批 36 引入。
4. **【观察/既有】显示尺寸改写后的 Tab 与内容短暂不同步**：改写 `wm size/density`
   后，底栏/侧栏高亮「发现」但主内容仍显示书架，需再点一次 Tab 才恢复
   （`shots/48、49b、50、52`）；同为尺寸改写触发，非批 36 范围，正常尺寸下未复现。
5. **说明**：页码输入按参考版语义「最多 4 位 + ≥1 才可确认」实现，5 位输入为截断
   而非整段拒绝，满足验收要求「禁用或截断」。

编写者：QA（ZCode）｜ 2026-10-29
