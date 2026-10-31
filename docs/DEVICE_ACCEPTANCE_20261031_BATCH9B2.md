# 批 9b-2 设备验收报告（线程数并发 · 搜索 2/8 · 单书下载 8/1 · 多书准入 · 取消 · force-stop 续跑 · 回归/清理）

> 范围：批 9b-2——设置页「更新和搜索线程数」默认 16、范围 1..256、
> subtitle「搜索有效上限 32；离线缓存有效上限 8」、保存/启动同步 Rust
> `config:threadCount`；搜索跨源并发（2 vs 8）；批量离线下载单书并发
> （threadCount=8/1）；进程级同时只准入 1 本书；取消（下载中 / 排队中）；
> force-stop 后续跑（threadCount=1，已完成章不重下、不重复计数、不误判
> failed）；搜索/换源/正文/书架/阅读/备份回归；清理并保留验收版本。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，`adb devices` 实测
> `device`）。
>
> **结论**：**8 组场景全部 PASS、0 FAIL、0 BLOCKED**。
> 全会话 `FATAL EXCEPTION`=0、`ANR in io.legado`=0、
> `RenderFlex overflowed`=0、`OutOfMemoryError`=0（57,011 行 logcat 留存）。
> 本批未发现代码缺陷；登记 6 项非缺陷观察（§6：armv7 quickjs 回退、
> 取消竞态窗口派发、QA 计时迭代、S1 换源镜像夹具、门禁范围、备份仅创建）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带；root shell 可用） |
| 应用包名 | `io.legado.flutter_legado`（`io.legado.flutter.MainActivity`） |
| 验收版本 | versionName **2.0.429** / versionCode **430**（`dumpsys package` 实测，与 pubspec `2.0.429+430` 一致） |
| 源码基线 | `master` HEAD `1868e3d97a`（`chore: 批9b-2 收尾`；含 `53b2a16aed` P0 续跑修复、`fb477ff3b2` 审查回修） |
| 验收时间 | 2026-10-31 23:43 ~ 2026-11-01 00:35（截图/日志时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch9b2/`（`tmp_debug/` 不入库） |
| 截图副本 | `docs/materials_1031g/`（45 张） |

### 1.1 Rust .so 重建（本批有 Rust 变更：先 Rust 后 Flutter）

| 步骤 | 结果 |
|---|---|
| 构建命令 | `pwsh -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`（pwsh 7.6.6） |
| 结果 | EXIT=0，`=== Build complete! ===`，三 ABI 均复制到 `flutter_legado/android/app/src/main/jniLibs/`；aarch64 1m02s、armv7 23.75s、x86_64 43.43s |
| arm64-v8a | `liblegado_ffi.so` 51,630,176 B，mtime 23:44，sha256 `c8c8aea52e09…6cff3f38`；meta **quickjs:true** |
| armeabi-v7a | 34,268,780 B，mtime 23:44，sha256 `cb6d5729156f…96a844`；meta **quickjs:false**（脚本既有回退，§6.1） |
| **x86_64（本设备）** | **51,883,696 B，mtime 23:45，sha256 `7fea8be82055…4a41871e`；meta quickjs:true** |
| .so meta | `contentHash=-993835076`、`rustFingerprint=1ede733fbc7f7e25…50f23616`、`builtAt=2026-10-31T23:45:24`（三 ABI 同指纹） |
| Flutter APK | `flutter build apk --release` EXIT=0，`assembleRelease 70.6s`，199,250,288 B（190.0MB）；sha256 `a3a00d64638bf448621b4513e30f3bf01ee9f48091077e56db263a6ff0c108b3` |
| 安装 | `adb uninstall` → `adb install` Success；`dumpsys` versionName=2.0.429 / versionCode=430 |
| 启动冒烟 | 冷启动 `Status: ok` / TotalTime 351~1229ms；空书架正常渲染（`shots/00_launch.png`） |

### 1.2 宿主门禁（设备验收前/后定向复核）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0 |
| 线程数同步/设置 UI | `flutter test test/unit/startup_thread_count_sync_test.dart test/widget/settings_test.dart` | **25/25 passed**（含默认 16、保存同步 Rust、越界拒绝、存量 999 夹逼 256） |
| 下载并发/准入/续跑 | `cargo test -p legado-ffi --lib cache_download_api::tests::` | **23/23 passed**（含 P0 续跑、全局准入、计数闭合） |
| 定向并发 | `cargo test -p legado-ffi --lib test_download_concurrency_clamps_thread_count` / `test_search_books_max_in_flight_uses_thread_count_config` / `test_download_global_admission_one_book_at_a_time` | **各 1 passed** |
| 范围说明 | 未重跑 cargo/flutter 全量套件（工程侧门禁见计划登记）；本报告只对上述定向用例背书 | — |

### 1.3 测试夹具（宿主 mock + 8 书源 + 两本书）

| 项 | 说明 |
|---|---|
| Mock 服务 | `server/mock9b2.py`，监听 **0.0.0.0:18092**（宿主 `192.168.100.52`）；GET 全路径记录时间/路径/在途数/最大在途/UA |
| 延迟 | 搜索每源 **800ms**；正文每章 **150–300ms**（random），用于形成并发窗口 |
| 书源 | 8 个：`QA9B2-A`（/a）、`QA9B2-B`（/b）、`QA9B2-S1..S6`（/s1../s6），JSON 规则 `searchUrl/ruleSearch/ruleBookInfo/ruleToc/ruleContent` |
| 书籍 | `QAB2A-1`（源 A，20 章）、`QAB2B-1`（源 B，20 章）；正文 URL 形如 `/a/content/QAB2A-1/1` |
| 统计口径 | `content_inflight/content_max`（全局正文）、`book_inflight/book_max`（单书）、`book_count/chapter_count`（请求次数）；`/stats` 可读快照，`MAX/MAX_BOOK` 行落日志 |
| 请求日志 | `server/mock_access9b2.log`（含每请求 START/END、在途、章节、UA） |
| 测试数据 | `data/qa9b2_sources.json`；书源导入预览「QA9B2-A..S6 新增」8 项 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | UI 默认/范围：默认 16；subtitle 上限提示；改 8/1 重启保持；200 保存；存量 999 夹逼 256；300 拒绝 | **PASS** | 默认 16（`shots/01`）；8/1 冷启动保持（`03、04`）；200 保存（`05`，DB/prefs=200）；999→显示/同步 **256**（`06`）；300 提示「请输入 1 ~ 256 之间的数字」（`07`） |
| 2 | 搜索并发：8 源，threadCount=2 与 8，最大在途接近设置值且结果数不变 | **PASS** | 00:00:36-39 `max_search=2`、结果 8/8（`13`）；00:02:33 `max_search=8`、结果 8/8（`14`）；两次均覆盖 /a /b /s1..s6 |
| 3 | 单书下载并发：t=8 最大在途 ≤8 且 >1；t=1 最大在途=1；进度/计数/无重复 | **PASS** | t=8：`content_max=8`、A=8、20 次请求每章 1 次，task1 completed=20（`22、23`）；t=1：`content_max=1`、20 次，task2 completed=20（`25、26`） |
| 4 | 多书准入：同时缓存 A/B，同一时刻只有一本在请求，B 排队零 HTTP，A 完再 B，每章一次 | **PASS** | UI 中段 A 8/20、B 0/20（`27`）；A 20 次 + B 20 次，40 章各 1 次；378 采样点 A/B 同时在途 **0**；A 最后 END inflight=0 → B 首 START inflight=1；task16/17 均 completed=20 |
| 5 | 取消：下载中取消 A 停止派发、在途完成；取消排队 B，B 零 HTTP | **PASS** | A：取消时 14 起、在途 8；取消后 starts 冻结 **16**、在途 8→0；task9 cancelled completed=16（`30`）。B：starts=0、max_inflight=0；task14 cancelled completed=0，A task13 completed=20（`31、32`） |
| 6 | 续跑：t=1 下载一半 force-stop；冷启动继续；已完成不重下、无重复计数/误判 failed | **PASS** | Kill 前 10 次请求、快照 completed=9/nextIndex=9/running、缓存 idx0..8；续跑仅重下第 10 章 + 11..20（总 21 次，chapter#10=2，其余 1）；终态 completed=20 failed=0，cached=20（`34、36、37`） |
| 7 | 回归：搜索/换源/正文、书架、阅读、备份；FATAL/ANR/overflow | **PASS** | 8 源搜索 8/8（镜像夹具加入前）；换源 2 候选（A 当前 + S1），切换后 origin=/s1、章节 URL 更新、正文 /s1 成功；A 第 1 章渲染；本地备份 11,502B 生成；FATAL=0、ANR=0、overflow=0、OOM=0 |
| 8 | 清理：停 mock、删测试源/书/文件、prefs 默认、空书架；保留验收版本 | **PASS** | mock 端口无监听；卸载重装后 books/sources/chapters/cached=0/0/0/0；prefs 无 threadCount 键、caches 默认 `16`（`51`）；空书架（`50、52`）；版本保留 2.0.429/430 |

## 三、逐场景证据

### 3.1 场景 1：UI 默认 / 范围 / 重启保持 / 夹逼

- **默认 16 + 提示文案**：全新安装后 其他设置 → 「更新和搜索线程数（太多会卡顿）」
  行值为 **16**，subtitle「搜索有效上限 32；离线缓存有效上限 8」（`shots/01`）。
- **改 8 → 冷启动保持**：UI 输入 8，toast「线程数已保存，下次搜索/下载生效」；
  prefs `flutter.threadCount=8`、caches `config:threadCount=8`；force-stop 冷启动后
  行值仍 8（`shots/03`），同步日志/DB 一致。
- **改 1 → 冷启动保持**：同上，冷启动后行值 **1**（`shots/04`）；
  prefs/caches 均为 1。后续场景 3/6 的真实并发测量也以该值为运行期输入。
- **200 保存**：输入 200（范围内）→ 行值 **200**（`shots/05`）；
  prefs `flutter.threadCount=200`、caches `config:threadCount=200`。
- **存量 999 夹逼**：force-stop 后直接改写 prefs XML `flutter.threadCount=999`
  （停机状态夹具注入）→ 冷启动 → 行值 **256**（`shots/06`），caches 同步为
  **256**（启动第 5e 步按 `clamp(1,256)` 单向对齐）。证明「>256 存量值显示/同步均夹逼」。
- **输入 300 拒绝**：对话框内输入 300 → 点击确定 → 对话框保留、toast
  「请输入 1 ~ 256 之间的数字」（`shots/07`），caches 仍 256，未落盘。
- **UI 范围**：代码 `min=1/max=256`（`other_settings_screen.dart` L543-547），
  与实数输入验证一致；搜索/下载的有效上限由 Rust 运行期夹逼（32/8）。

### 3.2 场景 2：搜索并发（threadCount=2 vs 8，8 源）

- **源集合**：`QA9B2-A`、`QA9B2-B`、`QA9B2-S1..S6`，共 **8 源**；每源
  `/search` 固定延迟 800ms，结果各 1 本（合计 8 本）。
- **threadCount=2**（00:00:36-39，mock 日志）：

| 时间 | 路径 | inflight_search | max_search |
|---|---|---|---|
| 00:00:36 | /b/search | 1 | 1 |
| 00:00:36 | /a/search | 2 | **2** |
| 00:00:37 | /s2/search、/s1/search | 1、2 | 2 |
| 00:00:38 | /s3/search、/s4/search | 1、2 | 2 |
| 00:00:39 | /s5/search、/s6/search | 1、2 | 2 |

  UI「结果 8 · 进度 8/8」（`shots/13`）。
- **threadCount=8**（00:02:33，mock 日志）：/a 1、/s5 2、/s4 3、/s3 4、
  /s1 5、/b 6、/s6 7、/s2 **8** → `max_search=8`；UI 仍「结果 8 · 进度 8/8」
  （`shots/14`）。
- **结论**：搜索跨源最大在途严格跟随设置（2 vs 8）；结果数与聚合口径不变。
  单源内解析顺序、搜索会话其它语义不在本批变更范围。

### 3.3 场景 3：单书下载并发（t=8 / t=1）

- **threadCount=8**（00:05:28）：
  - mock：`content_max=8`、`book_max[QAB2A-1]=8`、`book_count=20`；
    `chapter_count` 20 项全部 =1（每章恰好一次）。
  - UI 进度「下载中 → 已缓存 20/20」（`shots/22、23`）。
  - DB task1：`completed=20, failed=0, nextIndex=20, status=completed`；
    `cached_chapters=20`。
- **threadCount=1**（00:07:51，清空 A 缓存后重下）：
  - mock：`content_max=1`、`book_max=1`、`book_count=20`、每章 1 次。
  - task2：`completed=20, failed=0, nextIndex=20, status=completed`；
    UI 20/20（`shots/25、26`）。
- **结论**：单书 worker 数 = `threadCount` 夹逼 1..=8；8 并发实际达到 8，
  1 并发严格串行；进度、完成章数与正文请求计数一致，无重复。

### 3.4 场景 4：多书准入（A/B 串行，B 排队零 HTTP）

- **操作**：threadCount=8，清空两书缓存 → 离线缓存页「缓存操作 → 全部缓存」
  → 确认「将缓存书架全部 2 本书」；UI 中段 A「下载中 8/20」、B「下载中 0/20」
  （`shots/27`，toast「已加入缓存队列：2 本书」）；结束后两书均 20/20（`shots/28`）。
- **并发采样**（30ms 间隔，378 点，`data/admission_samples.json`）：
  - `max_content=8`；`book_max A=8`、`book_max B=8`；
  - **A/B 同时在途样本 = 0**；
  - 首个 B 在途样本：`{'QAB2A-1':0, 'QAB2B-1':8}`，此时 A 的 `book_count` 已=20。
- **日志边界**（重跑，00:30:36-37）：

```
00:30:37 END /s1/content/QAB2A-1/20 ... inflight_content=0   ← A 最后一章结束
00:30:37 START /b/content/QAB2B-1/1 ... inflight_content=1   ← B 首章开始
```

- **请求计数**：A=20、B=20；40 个 chapter 键全部 =1（每章一次）。
- **备注**：本次为补录 DB 任务状态的重跑，此时 A 已在场景 7 换源至 S1，
  故日志中 A 的 URL 为 `/s1/content/...`；准入语义与书源无关，计数与串行
  结论同首轮一致（首轮 A 使用 `/a/content/...`）。
- **DB 任务**（重跑留证）：task16(A)/task17(B) 均
  `completed=20, failed=0, nextIndex=20, status=completed`。
- **结论**：进程级准入在设备上生效——同一时刻只有 1 本书发 HTTP，B 在 A
  完成前零正文请求；单书内部仍保持 8 并发。

### 3.5 场景 5：取消（下载中 A / 排队中 B）

**A 下载中取消**（threadCount=8，00:13:21）：
- 取消时刻采样：`book_count=14`、`content_inflight=8`；
- 取消后采样：`book_count` 冻结在 **16**，`content_inflight` 序列
  `8 → 8 → 5 → 2 → 0`（在途章完成，无新派发）；
- DB task9：`completed=16, failed=0, nextIndex=16, status=cancelled`；
  `cached_chapters=16`；UI「已缓存 16/20」（`shots/30`）。
- 竞态窗口内额外派发 2 章（14→16），在契约允许的「最多再派发 N 章
  （N=并发 8）」范围内；在途清空后不再增长。

**B 排队中取消**（A 下载中，逐本快速点 B 开始再取消）：
- mock：`book_count[B]=0`、`book_max[B]=0` —— **B 零 HTTP**；
- DB task14：`completed=0, failed=0, nextIndex=0, status=cancelled`；
- 同时 A task13：`completed=20, failed=0, status=completed`；
- UI：取消前 A 8/20、B 0/20（`shots/31`）；取消后 A 20/20、B 0/20（`shots/32`）；
- 结论：排队任务在获得准入前取消 → 不创建 worker、不发任何请求。

### 3.6 场景 6：threadCount=1 force-stop 续跑（关键）

**阶段 1**（mock 起始 00:18:36）：
- threadCount=1，A 从 0 开始；mock 收到 **10** 次正文请求（第 1..10 章各 1 次），
  `max_inflight=1`；
- 当第 10 次请求发出后立即 `am force-stop`；`pidof` 为空；
- DB task15：

```json
{"taskId":15,"bookUrl":".../a/book/QAB2A-1","total":20,"completed":9,
 "failed":0,"nextIndex":9,"status":"running","failedChapters":[],
 "finishedChapters":[]}
```

- `cached_chapters=9`（chapter_index 0..8）；第 10 章（idx 9）为中断在途章，
  内容未落库。UI kill 前「下载中 6/20」（UI 刷新滞后，`shots/34`）。

**阶段 2**（冷启动 → 进入离线缓存页触发 `ensure_restored`）：
- 冷启动至进入缓存页前，mock `book_count` 仍为 10（未提前发请求）；
- 进入缓存页后：00:19:20 重新请求第 10 章（阶段 1 在途章），00:19:21-23
  请求第 11..20 章；**1..9 未再请求**；
- mock 最终：正文请求 **21** 次；`chapter_count`：`#10=2`，其余 19 章 =1；
- 续跑进度截图 16/20（`shots/36`），完成 20/20（`shots/37`）；
- DB task15 终态：

```json
{"taskId":15,"total":20,"completed":20,"failed":0,"nextIndex":20,
 "status":"completed","failedChapters":[],"finishedChapters":[]}
```

- `cached_chapters=20`（idx 0..19）。

**结论**：已完成前缀（0..8）零重复请求；仅「kill 时在途」的第 10 章重下 1 次
（幂等）；`completed` 最终恰为 20（未把 21 次请求计成 21），`failed=0`，
未误判 failed/cancelled。P0 续跑重复计数修复在设备上验证通过。

### 3.7 场景 7：回归（搜索 / 换源 / 正文 / 书架 / 阅读 / 备份）

- **搜索/书架**：8 源搜索「qa9b2」结果 8/8（镜像换源夹具加入前）；两书加入书架并显示 20 章。
- **阅读与正文**：打开 A 第 1 章，正文 8 段正常渲染（缓存命中，`shots/38`）；
  阅读菜单可用（`shots/39`）。
- **换源**：A 详情/阅读菜单「换源」→ 首次提示「找到 1 个匹配书源（当前）」，
  「重新搜索」后「找到 2 个匹配书源」：QA9B2-A（当前）+ QA9B2-S1；
  选择 S1 → 确认「切换书源」→ A 的 `books.origin` 更新为
  `http://192.168.100.52:18092/s1`，20 章 URL 全部改为 `/s1/content/...`，
  正文请求 `/s1/content/QAB2A-1/1..3` 成功、阅读器内容正常
  （`shots/40~43`）。换源搜索 8 次请求，`max_search=1`（当时 threadCount=1），
  与设置一致。
- **备份**：备份与恢复页选择本地路径 `/storage/emulated/0/Download/legado` →
  「备份」→ 生成 `legado_backup_1793463970739.json`（11,502 B，`shots/44、45、47`）；
  本批只验证「备份不因线程数改动而回归」，恢复链路由批 9b-4 覆盖。
- **稳定性**：全程多次冷启动/force-stop/页面往返；会话日志 57,011 行，
  FATAL=0、ANR=0、overflow=0、OOM=0。

### 3.8 场景 8：清理与恢复

- **停 mock**：结束 18092 监听进程，`/health` 不可达（`MOCK_DOWN`）。
- **删测试文件**：删除 QA 本地备份 `legado_backup_1793463970739.json`；
  删除设备端 `qa9b2_ui.xml` dump；未向 `/data/local/tmp` 推送脚本。
- **卸载重装**：`adb uninstall` → `adb install app-release.apk`；卸载清空
  DB/prefs/源/书/缓存；重装后 DB：`books=0、book_sources=0、chapters=0、
  cached_chapters=0`；`searchBooks=0`；prefs 无 `flutter.threadCount` 键；
  caches 仅 `config:threadCount=16`（缺省初始化）。
- **默认值回显**：重装后其他设置行值 **16**（`shots/51`）。
- **空书架**：`shots/50`（重装后冷启动）与 `shots/52`（终态冷启动）。
- **版本保留**：`dumpsys` versionName=2.0.429 / versionCode=430；APK 未卸载。

## 四、FATAL / ANR / 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado.flutter_legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| 会话日志行数 | 57,011（`logcat/full_session_9b2.log`） |

另：`/sdcard/Download/legado/crash/` 无本次会话新增崩溃日志（仅 2026-10-30
既有文件）。

## 五、证据清单（`tmp_debug/device_acceptance_20261031_batch9b2/`）

| 类别 | 文件 |
|---|---|
| 构建 | `logcat/rust_build_9b2.log`（三 ABI/quickjs 回退）、`logcat/flutter_build_9b2.log` |
| 产物 | `data/build_meta_9b2.txt`（.so 大小/hash/meta + APK hash/version）、`data/apk_sha256_9b2.txt` |
| 门禁 | `logcat/dart_analyze_9b2.log`、`logcat/flutter_test_9b2.log`、`logcat/cargo_test_9b2.log`、`logcat/cargo_cache_download_tests_9b2.log` |
| Mock | `server/mock9b2.py`、`server/mock_access9b2.log`、`server/mock9b2_run*.log` |
| 源/书夹具 | `data/qa9b2_sources.json`（8 源）；mock 内 A/B 各 20 章 |
| 并发采样 | `data/admission_samples.json`（378 点）、`data/cancelA_samples.json`（168 点）、`data/cancelB_samples.json`（257 点） |
| 统计/续跑 | `data/scenario_stats_9b2.txt`、`data/resume_evidence_9b2.txt`、`data/task_snapshots_all.txt`、`data/task_state_timeline.txt`（逐场景 DB 原始 JSON 转抄） |
| 会话日志 | `logcat/full_session_9b2.log`（57,011 行） |
| 截图 | `shots/*.png`（55 张，含过程/重复尝试）；`docs/materials_1031g/`（45 张精选） |

## 六、说明与遗留（非缺陷）

1. **armv7 quickjs 回退**：构建日志出现
   `quickjs build failed; retrying without quickjs ...`，armeabi-v7a
   `.so.meta` 为 `quickjs:false`；这是构建脚本既有回退（批 9b-1/9b-4 已登记），
   本设备 x86_64 及发布主 ABI arm64 均为 `quickjs:true`，不影响本次验收。
2. **取消竞态窗口**：A 下载中取消时，在途 8 章内又派发了 2 章（14→16）后才
   停止；契约允许「取消后最多再派发 N 章（N=并发上限）」，且取消后
   `book_count` 不再增长、在途最终归零。属于既定语义，不是缺陷。
3. **QA 取消计时迭代**：正文延迟仅 150–300ms，threadCount=8 时 20 章约
   0.6–1s 完成；前两次尝试因 `uiautomator dump` 耗时错过取消窗口（一次 A
   已完成、一次 B 已准入）。最终改用固定坐标快速点击完成取证；该过程仅
   影响 QA 操作，不涉及产品行为。
4. **换源镜像夹具**：为回归「换源」，mock 的 `/s1/search` 额外返回同名
   `QAB2A-1` 镜像（独立 URL）。该夹具使该次搜索返回 9 本；场景 2 的并发
   测量在加镜像之前完成（8 源 / 8 结果），两组数据互不影响。
5. **门禁范围**：本报告重跑了 `dart analyze`、线程数同步/设置 UI 的 25 例
   Flutter 测试、`cache_download_api` 23 例及 3 个定向 Rust 用例；未重跑
   cargo/flutter 全量套件，不对全量计数背书。
6. **备份范围**：本批仅验证本地备份创建成功（回归「备份不受线程数影响」）；
   恢复流程沿用批 9b-4 的设备验收结论。

## 七、问题分级

| 级别 | 数量 | 说明 |
|---|---|---|
| P0 / P1 / P2（产品缺陷） | **0** | 未发现 |
| P3（观察/流程） | 3 | armv7 quickjs 回退（既有）、取消竞态窗口（契约内）、QA 取消计时迭代 |
| 范围/夹具登记（非缺陷） | 3 | S1 换源镜像夹具、门禁仅定向用例、备份仅创建 |
| BLOCKED | **0** | 无 |
