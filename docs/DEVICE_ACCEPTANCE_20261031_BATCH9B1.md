# 批 9b-1 设备验收报告（启动自动清除过期搜索结果 · 默认开/关闭/毫秒边界/失败静默/回归）

> 范围：批 9b-1——启动时按「自动清除过期搜索数据」开关（`autoClearExpired`，
> 默认 true）清理 `searchBooks` 中 `time < now - 86400000ms` 的记录；覆盖
> Rust 新增 `delete_expired` + FFI `search_books_clear_expired`、Dart 启动
> 接线（unawaited、失败静默）、默认开/关闭两态、严格小于边界、20,000 行
> 清理负载下的启动耗时、失败注入静默与回归清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，`adb devices` 实测 `device`）。
>
> **结论**：**7 组场景全部 PASS、0 FAIL、0 BLOCKED**。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0、OOM=0（会话日志留存）。
> 本批新增代码问题 0；登记 2 项 P3 观察（§6.1 注入需 debug 变体流程限制、
> §6.3 批 9a 遗留测试数据编码痕迹）与 1 项既有风险（§6.2 armeabi-v7a
> quickjs 回退，非本批回归）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM_G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.427** / versionCode **428**（`dumpsys package` 实测，与 pubspec `2.0.427+428` 一致） |
| 源码基线 | `master` HEAD `4e78daa1e5`（`chore: 批9b-1 收尾`；含 `409aeaef0c` Rust 清理链路、`74a09df128` 接线单测、`26c7784bf5` 审查回修） |
| 验收时间 | 2026-10-31 19:10 ~ 19:29（截图时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch9b1/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1031e/`（18 张） |

### 1.1 Rust .so 重建（本批新增 FFI，必须先 Rust 后 Flutter）

| 步骤 | 结果 |
|---|---|
| 构建命令 | `pwsh -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release` |
| 执行备注 | 脚本 UTF-8 无 BOM，在 **PowerShell 7.6.6（pwsh）** 下直接执行成功（EXIT=0），未做 BOM 副本/路径补丁（对比批 1b-3 的 PS 5.1 GBK 解析问题） |
| NDK | `D:\Android\ndk\28.2.13676358`；三 ABI 构建完成 `=== Build complete! ===` |
| arm64-v8a | `liblegado_ffi.so` 51,674,464 B，mtime **19:12:51**，sha256 `28d5088a02f6…3631806`；meta **quickjs:true** |
| armeabi-v7a | 34,329,120 B，mtime **19:14:23**，sha256 `4f3150e2…104970d`；meta **quickjs:false**（脚本既有回退，见 §6.2） |
| **x86_64（本设备）** | **51,960,152 B，mtime 19:15:46，sha256 `954b3bf5…877a6b5`；meta quickjs:true** |
| .so meta | `contentHash=-993835076`、`rustFingerprint=2b1ec3e0…4cd2ddb`、`builtAt=2026-10-31T19:15:46.6428356+08:00`（x86_64） |
| Flutter APK | `flutter build apk --release` EXIT=0，`assembleRelease 101.6s`，199,430,288 B；sha256 `7dc5f41f7453b5d12d6aace28b075b42334c9af3edcca7fdd036efaa1b2c38bc` |
| 安装 | `adb install -r` Success；`dumpsys` versionName=2.0.427 / versionCode=428 |
| 注入用变体 | `flutter build apk --debug` EXIT=0，316,639,611 B（仅用于 DB 注入，见 §6.1；非发布产物） |

### 1.2 静态分析与定向单测（交付前门禁）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `dart analyze`（`flutter_legado/`） | **No issues found!** EXIT=0 |
| 启动接线单测 | `flutter test test/unit/startup_clear_expired_search_test.dart` | **6/6 passed**（默认 true / 显式 true / false 不调用 / USE_MOCK 跳过 / FFI 失败静默 / unawaited 不向 Zone 抛异常） |
| Rust 边界单测 | `cargo test -p legado-db search_book_repository::tests::test_delete_expired_boundary` | **1 passed**（`< before` 删除、`== before` 保留、`> before` 保留、无匹配返回 0） |

### 1.3 测试数据与注入方式

| 项 | 说明 |
|---|---|
| 实际 DB 路径 | `/data/user/0/io.legado.flutter_legado/app_flutter/legado.db`（Dart `getApplicationDocumentsDirectory()`；批 1b-3 报告口径一致）。`.../databases/` 目录为空，**未误建 0 字节 DB** |
| 注入工具 | `run-as io.legado.flutter_legado /system/bin/sqlite3 <db> ".read /data/local/tmp/qa9b1_*.sql"`（脚本经 push + chmod 644） |
| SQL 夹具生成器 | `data/gen_qa9b1_sql.py`（s1/s2/grid/bulk/trigger/cleanup；时间基准取设备 `julianday('now')`，避免主机/设备时钟偏差） |
| FK 前置 | 每个场景先 `INSERT OR REPLACE book_sources(bookSourceUrl=…)`，再插 `searchBooks`（origin 引用该源） |
| 时间基准 | 设备 epoch 毫秒实测与主机一致（19:19 设备 1793445590198 / 主机 1793445596011，差约 6s 为两次采样间隔） |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 默认开 + 旧数据清理 | **PASS** | 插入 -2 天 / -1 天 1 分 / -1 小时 3 行；冷启动日志「删除 **2** 条（阈值 -1 天）」；DB 查询前两行消失、`-1 小时` 行保留 |
| 2 | 关闭开关不清理 | **PASS** | UI 开关 `checked=false` + prefs `flutter.autoClearExpired=false`；插 3 行（3 天/2 天/1 小时）冷启动后 **3/3 全保留**，无清理日志 |
| 3 | 严格小于边界（±5s 内） | **PASS** | 1ms 网格 6,001 行：阈值 T=基准-1天+**1231ms**；`time==T` 行保留、`T-1ms` 行删除、删除计数 2731、保留计数 3270 全部吻合；**毫秒误差 0** |
| 4 | 启动不阻塞（含 20,000 行清理负载） | **PASS** | release 2.0.427 冷启动 693/577/410ms（旧版 2.0.426 1586/314/370ms）；20,000 行删除日志出现在 Displayed 前 34ms，代码为 `unawaited`；无卡死/FATAL/ANR |
| 5 | 失败静默（DELETE 失败注入） | **PASS**（等价注入，见 §6.5） | `BEFORE DELETE` 触发器 `RAISE(ABORT)`：启动 Status ok / 1574ms，3 行全保留，日志「自动清除过期搜索失败（不阻断启动）：Instance of 'BridgeError'」，书架正常；移除触发器后恢复删除 2 留 1 |
| 6 | 回归：网络搜索/换源候选/书架/阅读 | **PASS** | 网络导入 3 书源；搜索「qa9b1test」结果 **6 · 进度 3/3**；换源「找到 1 个匹配书源」；加书架、阅读第 1 章正文渲染；FATAL=0、ANR=0 |
| 7 | 清理与恢复 | **PASS** | 卸载重装 release：books/sources/searchBooks/chapters = 0/0/0/0，prefs `autoClearExpired` 键不存在（默认），设备 QA SQL/XML 删除，mock 停止；空书架冷启动；保留 2.0.427/428 |

## 三、逐场景证据

### 3.1 场景 1：默认开 + 旧数据清理

- **前置**：`autoClearExpired` 未设置（prefs 无该键）→ 走默认 true；
  开关 UI 实测 `checked=true`（`shots/02`）。
- **注入**（base_ms=`1793445609514`，设备时钟）：

| bookUrl | time | 相对 | 预期 |
|---|---|---|---|
| `qa9b1_s1_2d` | 1793272809514 | now-2 天 | 删 |
| `qa9b1_s1_1d1m` | 1793359149514 | now-1 天 1 分 | 删（严格 `< now-1天`） |
| `qa9b1_s1_1h` | 1793442009514 | now-1 小时 | 留 |

- **冷启动**（`am start -W` Status ok；启动时刻约 1793445622038）：
  logcat `[启动] 自动清除过期搜索：删除 2 条（阈值 -1 天）`。
- **DB 查询（启动后）**：`qa9b1_s1_1h` 仍在；`qa9b1_s1_2d`、
  `qa9b1_s1_1d1m` 已删除；表内总行数 7（其中 6 行为批 9a 遗留的
  fresh 记录，time≈now-7.5h，按设计保留，见 §6.3）。
- 证据：`shots/01_s1_bookshelf_after_cleanup.png`、
  `logcat/s1_cleanup.log`、`data/qa9b1_s1.sql`。

### 3.2 场景 2：关闭开关不清理

- **UI 关闭**：其他设置 →「自动清除过期搜索数据」开关由 `checked=true`
  切到 **false**（`shots/02` → `shots/03`），prefs 落盘
  `flutter.autoClearExpired=false`（run-as 读取 XML 实测）。
- **注入** 3 行（3 天 / 2 天 / 1 小时，base 设备时钟）。
- **冷启动**（debug 变体 TotalTime 1979ms）：**3/3 行全部保留**；
  logcat 无「自动清除过期搜索」日志（未调用），无 FATAL/ANR。
- 证据：`shots/03_s2_switch_off.png`、`shots/04_s2_bookshelf_after_switch_off.png`、
  `logcat/s2_cleanup.log`（空匹配）、`data/qa9b1_s2.sql`。

### 3.3 场景 3：严格小于边界（毫秒级）

采用「毫秒网格 + 最小存活时间」取证：网格覆盖连续整数毫秒，若阈值 T 落在
网格内，则启动后**最小存活时间即 T 本身**（`T-1` 已被删除），可无歧义证明
SQL `time < before` 的严格小于语义（`==` 保留），且误差为 0ms。

- **粗网格**：base=`1793445799971`，121 行，offset ∈ [-4000, +8000] step 100ms；
  启动后剩 66 行，最小存活 offset=**+1500ms** → T ∈ (1400, 1500]。
- **精网格**：base=`1793445819043`（命中基准 `1793359419043`），6,001 行，
  offset ∈ [-1500, +4500] step **1ms**；

| 指标 | 值 |
|---|---|
| 插入行数 | 6,001 |
| 启动后存活行数 | **3,270**（= 4500 - 1231 + 1，完全吻合） |
| 最小存活 time | **1793359420274** = 基准 + **1231ms** = 阈值 T |
| 删除行数（logcat） | **2,731**（= 1231 - (-1500)，完全吻合） |
| 边界行 | `qa9b1_g_1231`（time==T）**存在**；`qa9b1_g_1230`（T-1ms）**不存在** |
| 毫秒误差 | **0ms**（整数毫秒网格，T 被精确命中） |

- 证据：`logcat/s3_coarse.txt`、`logcat/s3_fine.txt`、
  `data/qa9b1_grid_fine.sql`（1.6MB）、DB 查询输出（报告内）。

### 3.4 场景 4：启动不阻塞（耗时对比 + 20,000 行负载）

`am start -W` TotalTime（从 start 到首帧 Displayed；首轮含安装/磁盘冷缓存）：

| 版本 / 状态 | run1 | run2 | run3 | 备注 |
|---|---|---|---|---|
| 2.0.426（升级前基线，空 searchBooks） | 1586ms | 314ms | 370ms | 旧版无本功能 |
| 2.0.427（空 searchBooks） | 727ms | 464ms | 369ms | 功能默认开，删除 0 条 |
| **2.0.427（20,000 行过期数据）** | **693ms** | 577ms | 410ms | run1 日志「删除 **20000** 条」 |
| 2.0.427（清理后 fresh 最终态） | 348ms / 408ms | — | — | 空书架冷启动 |

- 20,000 行 run1 时序：`[启动] 总启动耗时：282ms`（19:24:37.539）→
  清理完成日志 19:24:37.728（+189ms，含 prefs 读取 + DELETE 20k）→
  `Displayed +693ms`（19:24:37.762）。清理日志早于首帧 34ms 完成，且
  20k 行负载下总耗时与基线同量级，无卡死、无 ANR、无 FATAL。
- 代码口径：`main.dart` 第 5c 步 `unawaited(clearExpiredSearchBooksOnStartup(...))`，
  再进入 `runApp`——即使 DELETE 更慢也不阻塞首帧。
- 清理真实性：release 启动删除 20k 后，重装 debug 查询
  `searchBooks WHERE bookUrl LIKE 'qa9b1_bulk%'` = **0**（总计 6 行均为
  批 9a 遗留 fresh 行）。
- 证据：`logcat/baseline_426_start.txt`、`logcat/release_427_start.txt`、
  `logcat/release_427_bulk.txt`、`data/qa9b1_bulk20k.sql`。

### 3.5 场景 5：失败静默（DELETE 失败注入）

- **为什么不选只读/锁定**：DB 只读会在启动第 4 步 `db_open` 就失败，
  进入 FFI 错误页，无法隔离「清理语句失败」这一目标路径；本场景改用
  SQL 级触发器让**仅 DELETE** 失败，DB 其余功能正常：
  `CREATE TRIGGER qa9b1_fail_delete BEFORE DELETE ON searchBooks
   BEGIN SELECT RAISE(ABORT,'QA9B1 injected delete failure'); END;`
- **注入**：先插 3 行（-2 天 / -1 天 1 分 / -1 小时），再建触发器；
  确认 `sqlite_master` 存在 `qa9b1_fail_delete`，searchBooks 3 行。
- **冷启动**：Status ok / TotalTime **1574ms**；书架正常显示
  （`shots/06_s5_failure_silent_bookshelf.png`）；3 行**全部保留**
  （DELETE 被 ABORT）；logcat：
  `[AppLog] [启动] 自动清除过期搜索失败（不阻断启动）：Instance of 'BridgeError'`；
  无 FATAL/ANR。
- **恢复**：`DROP TRIGGER` 后冷启动（1259ms）→「删除 2 条」，仅
  `qa9b1_s1_1h` 保留——失败注入未污染后续行为。
- 单测侧同口径：`startup_clear_expired_search_test.dart` 的 FFI 失败与
  unawaited/Zone 两用例证明静默语义（6/6 通过，§1.2）。
- 证据：`logcat/s5_full.log`、`logcat/s5_recovery.log`、
  `data/qa9b1_trigger_on.sql`。

### 3.6 场景 6：回归（网络搜索 / 换源候选 / 书架 / 阅读）

- **书源导入**：我的 → 书源管理 → 更多 → 网络导入
  `http://192.168.100.52:18090/sources`（批 9a mock 服务器，宿主同网段），
  预览 3 源、确认后「导入完成」：QA9A文书源 / QA9A坏章源 / QA9A漫画源
  （`shots/07~09`）。
- **网络搜索**（旧 searchBooks 已清空后）：书架搜索
  「qa9b1test」→ **结果 6 · 进度 3/3**（3 个书源并发返回），
  文 A/B/C 与漫 A/B/C 全部展示（`shots/10`）。
- **换源候选**：QA9A文A 详情 →「换源」→ **找到 1 个匹配书源**
  （QA9A坏章源），说明 searchBooks 清理不影响候选链路（`shots/12`）。
- **书架/阅读**：加书架 toast「《QA9A文A》已加入书架」→ 阅读第 1 章，
  正文「QA9A段落1-1…1-5」正常渲染、翻页控件可用（`shots/13、14`）；
  书架出现 QA9A文A（`shots/15`）。
- **稳定性**：全会话 `FATAL EXCEPTION`=0、`ANR in io.legado`=0、
  `RenderFlex overflowed`=0、`OutOfMemoryError`=0
  （`logcat/full_session_9b1.log` 1,614 行）。

### 3.7 场景 7：清理与恢复

- **应用数据**：卸载后全新安装 release；临时装 debug 读取 DB：
  `books|book_sources|searchBooks|chapters = 0|0|0|0`；
  prefs `flutter.autoClearExpired` 键**不存在**（默认 true 路径），
  随后装回 release（同签名保留空数据）。
- **设备文件**：`/data/local/tmp/qa9b1_*.sql`（8 个）与 `/sdcard/ui.xml`
  全部删除（`ls` 确认 No such file or directory）；mock 服务器进程停止。
- **最终态**：versionName **2.0.427** / versionCode **428**；空书架
  （`shots/16、17`）；冷启动 348/408ms；logcat FATAL/ANR=0。

## 四、FATAL / ANR 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado.flutter_legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |

（`logcat/full_session_9b1.log` 与 `logcat/final_state.log` 全量留存；
各场景另有独立日志。）

## 五、证据清单（`tmp_debug/device_acceptance_20261031_batch9b1/`）

| 类别 | 文件 |
|---|---|
| 构建 | `logcat/rust_build_9b1.log`（三 ABI + armv7 回退 + Build complete/EXIT=0）、`logcat/flutter_build_release_9b1.log`（101.6s）、`logcat/flutter_build_debug_9b1.log` |
| 静态/单测 | `logcat/flutter_analyze.log`（No issues found / EXIT=0）、Flutter 6/6 与 Rust 1 passed 输出见报告 §1.2 |
| 产物 | `data/apk_sha256.txt`；三 ABI `.so` + `.meta`（仓库 `flutter_legado/android/app/src/main/jniLibs/`） |
| 注入 SQL | `data/qa9b1_s1.sql`、`qa9b1_s2.sql`、`qa9b1_grid_coarse.sql`、`qa9b1_grid_fine.sql`、`qa9b1_bulk20k.sql`、`qa9b1_trigger_on/off.sql`、`gen_qa9b1_sql.py` |
| 场景日志 | `logcat/s1_cleanup.log`、`s2_cleanup.log`、`s3_coarse.txt`、`s3_fine.txt`、`s5_full.log`、`s5_recovery.log`、`full_session_9b1.log`、`final_state.log` |
| 启动耗时 | `logcat/baseline_426_start.txt`、`release_427_start.txt`、`release_427_bulk.txt` |
| UI dump | `data/ui_*.xml`（home/my/settings/advanced/sources/import/search/detail/change_source/reader/bookshelf） |
| 截图 | `shots/00~17`；副本 `docs/materials_1031e/`（18 张） |
| mock | 复用 `tmp_debug/device_acceptance_20261031_batch9a/server/mock9a.py`（本次运行日志 `logcat/mock9a_run.log`），验收后已停止 |

## 六、说明与遗留（非缺陷）

### 6.1 DB 注入使用 debug 变体（口径登记）

- release 包不可调试（`run-as` 报 `package not debuggable`），无法向
  release 应用数据目录注入 SQL。场景 1/2/3/5 的数据注入与查询在
  **debug 变体**上完成：同一 `applicationId`、同一签名（release 亦用 debug
  keys）、同一份源码与重建 `.so`、同一 `versionCode 428`，安装时保留数据。
- 场景 4/6/7（启动耗时、回归、清理）在 **release 2.0.427** 上完成；
  场景 4 的 20k 行数据由 debug 变体注入后，**装回 release 冷启动**并触发
  清理，再以 debug 查询确认删除——被验证的是 release 二进制的清理行为。
- 影响面：debug 变体的 Flutter JIT 启动耗时（1.2~2.0s）未用于场景 4 的
  版本对比；清理逻辑与阈值读取为同一 Dart/Rust 代码路径。

### 6.2 armeabi-v7a quickjs 既有回退（非本批回归）

- `armeabi-v7a` 带 quickjs 构建失败：`rar 0.4.0` 的 `extra_block.rs` 对
  `u64` 调 `nom::take`，32 位目标 `u64: ToUsize` 未实现（`E0277`，3 处）；
  脚本按既有逻辑回退无 quickjs，`.meta` 记 `quickjs:false`。
- 与批 16X/37/38/39-43 记录完全同口径（既有依赖冲突），**非本批回归**；
  本设备为 x86_64，使用 `quickjs:true` 的 x86_64 `.so`，不影响本批结论。
  armv7 完整引擎需单独修复该依赖（上游议题）。

### 6.3 批 9a 遗留 searchBooks 行（测试数据痕迹）

- 开始验收时应用数据内已有 6 行批 9a 的 `searchBooks`（time=1793418635385，
  ≈now-7.5h，未过期），场景 1 冷启动按规则保留，符合预期。
- 这 6 行的中文名在 sqlite3 输出中呈乱码（如「QA9A婕獳」），为批 9a 注入
  时的编码痕迹；本次注入行（UTF-8 SQL）显示正常。属**测试数据历史遗留**，
  非本批代码行为；回归前已清空，最终态随重装归零。
- 观察项 P3（仅登记，不影响验收）。

### 6.4 DB 路径与「0 字节 DB」防护

- 任务描述中的 `databases/legado.db` 在本应用实际不使用：`databases/`
  目录为空；应用经 Dart `getApplicationDocumentsDirectory()` 打开
  `app_flutter/legado.db`（注入前 315,392 B，WAL 模式）。
- 所有注入/查询均显式使用 `app_flutter/legado.db` 绝对路径，未创建或误用
  0 字节 DB。

### 6.5 场景 3 边界取证方法与场景 5 注入方式

- 场景 3 未直接「猜」启动时刻的阈值，而是插入 1ms 连续网格：启动后
  最小存活 time 必等于阈值 T（整数毫秒），且 `T-1` 必已删除。实测
  T=基准+1231ms、存活 3270、删除 2731 三者自洽，等价于 `time == before`
  保留、`time < before` 删除，误差 0ms。
- 场景 5 用 DELETE 触发器注入失败（而非 chmod 只读）：只读会在 `db_open`
  阶段失败、无法覆盖「清理失败但启动完成」路径；触发器让 DELETE 精确
  ABORT，启动其余流程与用户界面均正常，验证了目标语义。

### 6.6 启动耗时口径

- 表内 TotalTime 为 `am start -W` 的 Activity 首帧 Displayed 时间；每次
  均 `force-stop` 后启动。首轮（run1）含安装后磁盘冷缓存，故普遍高于
  后续轮次；版本对比以同轮次量级为准。
- 20k 行清理本身耗时（总启动日志→清理完成日志）约 189ms，清理日志早于
  首帧 34ms；加上代码 `unawaited` 口径，结论为「不阻塞首帧」。未观察到
  卡死、ANR 或 FATAL。

## 七、结论

- 场景 1（默认开，-2 天/-1 天 1 分删除、-1 小时保留）：**PASS**。
- 场景 2（UI 关闭开关 + prefs false，3 行一行不删、无调用日志）：**PASS**。
- 场景 3（1ms 网格严格小于边界，`==` 保留、`T-1` 删除、误差 0ms）：**PASS**。
- 场景 4（release 冷启动与旧版同量级；20k 行清理不阻塞、无 ANR/FATAL）：**PASS**。
- 场景 5（DELETE 失败注入，启动完成、失败静默、恢复后清理正常）：**PASS**。
- 场景 6（网络搜索 6 结果 3/3、换源候选、加书架与阅读；FATAL/ANR=0）：**PASS**。
- 场景 7（卸载重装后 DB 全 0、prefs 默认、设备临时文件清理、空书架）：**PASS**。
- 问题分级：本批新增 P1/P2 **0**；P3 观察 2（§6.1 注入需 debug 变体、
  §6.3 批 9a 遗留测试数据编码痕迹）；既有风险 1（§6.2 armv7 quickjs
  回退，非本批回归）。
- 阻塞项：**无**。

编写者：QA（ZCode 子代理）｜ 2026-10-31
