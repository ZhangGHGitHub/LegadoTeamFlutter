# 批 38 设备验收报告（阅读主题列表）

> 范围：批 38（`d4802cbc0c` … `fa429fa912`）——阅读主题列表页（网格/列表、列数 2..6、
> 多选管理、上移/下移/置顶/置底、删除二次确认、定位当前/回顶/回底、内置 5 套钉死）、
> 主题应用（字号/行距/背景/文字色/边距/字距/缩进/段距）、新建/改名/删除、导入/导出/分享、
> 恢复默认，以及主题库/当前 id/列数随备份 `appPrefs` 往返与恢复后刷新。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线，adbd `uid=0`）。
>
> **结论**：场景 1~7、9 全部 **PASS**；场景 8 **PASS（附 1 项 P2 缺陷）**：
> 备份恢复成功后**同一会话内**打开阅读主题页会一直转圈、设置入口显示「未应用主题（自定义）」，
> **重启应用后恢复正常**（主题列表与当前 id 数据本身已正确往返）。缺陷详见 §五.1。
> 全流程 OS 层 FATAL=0、ANR=0。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 / 密度 | 1080x1920 / 480dpi（未改动） |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，`uid=0`，可直接读写应用私有目录与 DB） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.416** / versionCode **417**；DB `user_version=117`、299,008 字节、`books=0`、`book_sources=1` |
| 验收版本 | versionName **2.0.417** / versionCode **418**（`dumpsys package` 与 `aapt dump badging` 一致） |
| 源码基线 | `master` HEAD `fa429fa912`（`chore: 批38 收尾（2.0.417+418 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-30 00:13 ~ 00:55（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261029_batch38/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 构建与安装

| 步骤 | 命令 | 结果 |
|---|---|---|
| Rust FFI | `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release` | **EXIT=0**，`build_rust.log` |
| Flutter APK | `cd flutter_legado && flutter build apk --release` | **EXIT=0**，`√ Built ... app-release.apk (189.2MB)`，`build_flutter_apk.log` |
| APK 摘要 | `sha256sum app-release.apk` | `90f9081260c59f008a384a50c19882e78173fea3221a0c3940bfdeb4bdef1401`（198,364,228 字节） |
| 安装 | `adb install -r .../app-release.apk` | `Success: streamed 198364228 bytes` |
| 版本确认 | `dumpsys package` / `aapt dump badging` | 2.0.417 / 418 |

- 三个 ABI 的 `.so` 均已产出并拷入 `jniLibs`（49 / 32.5 / 49.3 MB）。`.meta`：
  arm64-v8a 与 x86_64 为 `quickjs:true`，**armeabi-v7a 为 `quickjs:false`**。
  原因仍是既有依赖冲突（`rar 0.4.0` 要求 `nom ^7.1`，`nom 7.1.3` 未对 `u64`
  实现 `ToUsize`），构建脚本按既有逻辑回退；与批 37 构建同口径，**非本批回归**。
- 升级前已 `am force-stop` 并整库备份：`pre_upgrade/legado.db`（299,008 字节，
  `user_version=117`）与 `pre_upgrade/FlutterSharedPreferences.xml`（6,579 字节，
  sha256 `0097984f…62895`）。

### 1.2 测试数据（造数据，未改业务代码）

| 数据 | 内容 / 路径 | 用途 |
|---|---|---|
| 本地书 | `/sdcard/Download/qa38_book.txt`（1,117 B，UTF-8，3 章） | 进入阅读器、验证主题落点 |
| DB 种子 | `seed_qa38.sql`：`books` 插入 `QA38验收本地书`（`loc_book` / type=4096） | 书架入口 |
| 单份主题 | `qa38_import_single.json`（字号 23 / 行距 2.1 / 背景 `#2E3B4E` / 文字 `#F2E9D8` / 字距 0.3 / 缩进 1 / 段距 8 / 边距 30-30-16-16） | 导入、应用全字段验证 |
| 重名主题 | `qa38_import_dup.json`（同名「QA38导入深蓝」） | 同名后缀 |
| BOM 主题 | `qa38_import_bom.json`（UTF-8 BOM，背景 `#7A4E2A`） | BOM 导入 |
| 批量主题 | `qa38_import_many.json`（30 份，`QA38长列表01..30`，深浅各异） | 长列表与定位 |
| 备份文件 | `/sdcard/Download/legado/legado_backup_1793292155776.json`（6,868 B） | 备份恢复往返 |

- 主题界面操作通过 `qa38.py`（uiautomator dump + 坐标驱动）完成；主题 JSON 含 `{}"` 等
  标点，`input text` 会丢字符，改用 `input keycombination` 逐字符输入（脚本内 `typejson`）。
- 该机 `cmd clipboard` 为「No shell command implementation」，剪贴板导入采用
  **应用内命名框输入最小 JSON → 长按全选 → 复制 → 从剪贴板导入** 的真实路径取证。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 入口与默认：内置 5 套色块/当前标记/默认主题应用 | **PASS** | `shots/02、03、04、06`；`shots/03_color_samples.txt`；`prefs/15` |
| 2 | 应用主题：内置/自建全字段生效、chip 一致、重启保持 | **PASS** | `shots/08、09、10、12、13、41、59`；`prefs/16、34` |
| 3 | 新建/改名/删除、内置不可删不可勾选 | **PASS** | `shots/14~22`；`prefs/17、18、19` |
| 4 | 排序（上/下/置顶/置底）与网格 2/4/6 列持久化 | **PASS** | `shots/24~28、30~35`；`prefs/21~32` |
| 5 | 30+ 长列表：定位当前 / 回顶 / 回底 | **PASS** | `shots/57~64`；`prefs/38、39` |
| 6 | 导出/导入/剪贴板/分享/BOM | **PASS（分享附说明）** | `export_QA38_BOM.json`、`shots/38~54`、`logcat/share_handoff.txt` |
| 7 | 恢复默认：清空自建 + 应用预设1 | **PASS** | `shots/65、66`；`prefs/40` |
| 8 | 回归：阅读器/设置/备份恢复 + FATAL/ANR | **PASS（附 P2 缺陷）** | `backup_roundtrip.json`、`shots/75~90`；§五.1 |
| 9 | 清理：恢复 DB/偏好、删除测试主题与文件 | **PASS** | `prefs/45、46`、`restore/FlutterSharedPreferences_final.xml`、`shots/91` |

## 三、逐场景证据

### 3.1 场景 1（入口与默认）

- 入口：阅读器 → 中心唤出菜单 → 顶部「设置」→「阅读界面」底部卡片「阅读主题」
  （`shots/02`，副标题「未应用主题（自定义）」）→ 打开列表。
- 内置 5 套卡片与色块（`shots/03`，像素取样见 `shots/03_color_samples.txt`）：
  微信读书 `#C0EDC6`、预设1 `#FFFFFF`、预设2 `#DDC090`、预设3 `#C2D8AA`、预设4 `#DBB8E2`，
  与 `kBuiltInReaderThemes` 定义逐值一致；初始无当前标记（当前 id 为空）。
- 应用「预设1」：SnackBar「已应用「预设1」」（`shots/04`），卡片出现主色描边 + 名称主色
  的当前标记；返回设置后入口副标题变为「预设1」（`shots/05`）；阅读页白底黑字（`shots/06`）。
- prefs（`prefs/15_prefs_after_preset1.xml`）：`reader_theme_current_id=builtin-preset-1`、
  `reader_adv_custom_text_color=4278190080`（`0xFF000000`）、`reader_bg_color_index=0`、
  `reader_font_size=20`、`reader_line_height=1.7`、边距 `24/24/20/20`、字距 `0.1`、缩进 `2`。

### 3.2 场景 2（应用主题与持久化）

- 内置：应用「微信读书」后，阅读页背景 `#C0EDC6`、字号 24、行距 1.42、边距 5/4/22/22、
  字距 0.0（`shots/08`）；设置面板字号 24、自定义背景选中（`shots/09`）；列表当前标记在
  微信读书（`shots/10`）。prefs（`prefs/16_prefs_after_wechat.xml`）逐项吻合，背景走
  `reader_custom_bg_color=4290833862`（`0xFFC0EDC6`）+ `reader_bg_use_custom=true`。
- 重启（force-stop + 冷启动）后：设置字号 24、入口「微信读书」（`shots/12`），列表当前标记
  仍在微信读书（`shots/13`），当前 id 保持 `builtin-wechat-read`。
- 自建（导入深蓝）：应用后 prefs（`prefs/34_prefs_imported.xml`）字号 23、行距 2.1、
  背景 `4281219918`（`0xFF2E3B4E`）、文字 `4294109656`（`0xFFF2E9D8`）、字距 0.3、缩进 1、
  段距 8、边距 30/30/16/16，全部即时生效；阅读页深蓝底米色字、行距与字距肉眼可辨
  （`shots/41`）；设置入口副标题为「QA38导入深蓝」（`shots/40`）。
- 长列表主题 28：prefs（`prefs/39_prefs_bulk28.xml`）字号 22、行距 1.85、
  背景 `4282006074`（`0xFF3A3A3A`）、文字 `4294309365`（`0xFFF5F5F5`）、边距 20/20/18/18；
  设置入口「QA38长列表28」（`shots/59`）。

### 3.3 场景 3（新建/改名/删除）

- 新建：`+`/「更多 → 新建主题」→ 命名「QA38自建甲」→ 列表出现、SnackBar 提示（`shots/14、15`）；
  prefs（`prefs/17`）落盘样式为当前阅读样式快照（24 / 1.42 / `#FFC0EDC6` / `#FF0B0B0B` /
  5-4-22-22），即“当前样式另存为”语义正确。
- 改名：长按自建卡 → 底部操作单（导出 JSON / 分享 JSON / 重命名 / 删除，`shots/16`）→
  重命名为内置同名「微信读书」→ 实际落名 **「微信读书 (2)」**（`shots/17`、`prefs/18`），
  重名自动加后缀。
- 删除：管理态「已选 N」/全选/反选 + 底部上移/下移/置顶/置底/导出/分享/删除（`shots/18、19`）；
  删除弹出二次确认「确定删除选中的 1 个主题？内置主题不受影响。」（`shots/20`）；
  确认后列表只剩 5 套内置，`reader_theme_list=[]`（`prefs/19`）。
- 内置钉死：管理态点内置卡「已选 0」不变，点自建卡变「已选 1」；内置长按操作单只有
  导出/分享，无重命名/删除（`shots/22`）。

### 3.4 场景 4（排序与网格列数）

自建 A/B/C 三套，按操作逐步核对 prefs 顺序：

| 操作 | 顺序 | 证据 |
|---|---|---|
| 选中 B 上移 | B, A, C | `prefs/21`、`shots/24` |
| 多选 B+C 置顶 | B, C, A（多选保持组内相对顺序） | `prefs/22`、`shots/25` |
| 仅选 C 置底 | B, A, C | `prefs/23`、`shots/26` |
| 仅选 B 下移 | A, B, C | `prefs/25`、`shots/28` |
| 重启后 | A, B, C（保持） | `prefs/26`、`shots/29` |

- 网格列数：菜单项 2~6 列；设 6 列 → 重启仍为 6（`prefs/27、28`、`shots/30、31`）；
  设 2 列 → 重启仍为 2（`prefs/29、30`、`shots/32、33`）；设 4 列 → 重启仍为 4
  （`prefs/31、32`、`shots/34、35`）。6 列下卡片名称按设计省略号截断，属既定 UI。

### 3.5 场景 5（长列表定位）

- 以 `qa38_import_many.json` 一次导入 30 套（`shots/56`），自建总数 37、总条目 42
  （`prefs/38_prefs_bulk.xml`）。
- 列表自动滚到底部（`shots/57`，可见 `QA38长列表17..30` 与「新建主题」），应用
  「QA38长列表28」（`prefs/39`）。
- 重新进入主题页停在顶部（`shots/61`，仅见内置首行）→ 点「定位当前」后滚动至
  `QA38长列表25..30` 一行，28 位于视口内（`shots/62`，dump 中 28 的 bounds
  `[809,900,1032,1260]`）→ 「回到顶部」回内置首行（`shots/63`）→ 「回到底部」回
  `QA38长列表30` 与新建卡（`shots/64`）。三个悬浮钮均可用。

### 3.6 场景 6（导入/导出/分享）

- 导出单份：长按「QA38_BOM导入」→ 导出 JSON → `/sdcard/Download/legado/QA38_BOM导入.json`
  （522 B，`shots/51`），pull 回本地 `export_QA38_BOM.json`，内容为完整
  `type/schema/id/name/style`，背景 `#FF7A4E2A`、文字 `#FFFFF4E0`、字号 23、行距 2.1。
- 从文件导入：单份导入成功（`shots/38`、`prefs/33`，样式逐字段一致）；同名再导入得到
  「QA38导入深蓝 (2)」（`prefs/35`）；带 BOM 的 JSON 导入得到「QA38_BOM导入」
  （`shots/46`、`prefs/36`，UTF-8 BOM 被正确剥离）。
- 从剪贴板导入：应用内命名框输入 `{"name":"QA38CLIP","style":{}}` → 长按全选 → 复制 →
  「更多 → 从剪贴板导入」→ SnackBar「已导入 1 个主题」，列表出现 `QA38CLIP`
  （`shots/48、49`、`prefs/37`）。
- 分享：长按 → 分享 JSON，系统 Chooser 将 `ACTION_SEND typ=application/json`
  投递给设备上唯一 JSON 处理方 `com.legado.app.release/...FileAssociationActivity`
  （`logcat/share_handoff.txt`）；目标应用成功打开文件并解析，因“阅读主题 JSON 不是书源
  格式”弹出「格式不对」提示（`shots/54`，提示来自原版应用，属预期）。**文件投递与可打开性
  成立**；设备上没有能渲染本应用主题 schema 的接收方，故未做第三方成功导入验证。

### 3.7 场景 7（恢复默认）

- 「更多 → 恢复默认主题」→ 确认文案「将删除全部自建主题，并把阅读样式恢复为内置「预设1」，
  是否继续？」（`shots/65`）→「恢复」。
- 结果：`reader_theme_list=[]`、`reader_theme_current_id=builtin-preset-1`、字号 20、行距 1.7、
  白底、文字 `0xFF000000`、边距 24/24/20/20（`prefs/40_prefs_restored.xml`）；列表仅 5 套内置、
  预设1 带当前标记，SnackBar「已恢复默认主题，阅读样式已应用「预设1」」（`shots/66`）。

### 3.8 场景 8（回归与备份恢复）

- 阅读器：正文正常渲染、可进退阅读（`shots/89`）；阅读设置面板（字号/背景/主题入口）正常
  （`shots/80`）；书架、发现、关于（版本 2.0.417）、缓存管理入口均正常打开（`shots/73、74、88`）。
- 备份：本地备份路径设为 `/storage/emulated/0/Download/legado`（SAF 授权，`shots/69~71`），
  备份生成 `legado_backup_1793292155776.json`（6,868 B，`shots/75`）。pull 校验
  `appPrefs` 含 `reader_theme_list`（`QA38备份往返`）、`reader_theme_current_id`、
  `themeGridColumns=4`（`backup_roundtrip.json`）。
- 恢复往返：先「恢复默认」清空（`prefs/42`：列表空、当前 `builtin-preset-1`）→ 长按「恢复」
  选本地备份 → 确认恢复（`shots/77、78`）→ prefs（`prefs/43`）恢复出主题列表、
  `current_id=theme-1793292014848143-35`、列数 4；重启后列表显示「QA38备份往返」且带当前标记
  （`shots/85、90`）。**数据往返正确**。
- 全流程 logcat/`logcat_session.txt`：`FATAL EXCEPTION` 0 次、`ANR in io.legado.flutter_legado`
  0 次；dropbox 同期 `SYSTEM_TOMBSTONE` 均为 `uiautomator` 进程（工具自身 SIGSEGV，
  与本应用无关），未见本应用 crash/ANR 记录。
- **缺陷**：恢复后同一会话内主题页转圈（见 §五.1）。

### 3.9 场景 9（清理）

- 停止应用后恢复 `pre_upgrade/legado.db` 与 `FlutterSharedPreferences.xml`（含属主
  `u0_a62`、644），删除 WAL/SHM；删除 `/sdcard/Download/qa38_*`、导出文件、测试备份、
  `/data/local/tmp` 种子文件。
- 校验：prefs 恢复后 sha256 与升级前**逐字节一致**
  （`0097984fc85c8b6927de72bbe57c5155c67761592b634327c5ed1299ba662895`，
  `restore/FlutterSharedPreferences_final.xml`）；`diff` 无差异（`prefs/45、46`）。
  DB 内容恢复：`user_version=117`、`books=0`、`chapters=0`、`book_sources=1`、299,008 字节；
  文件 sha 与备份不同是应用启动后 SQLite 重开/checkpoint 所致，内容口径一致。
- 清理后冷启动书架为空态「书架还空着…」（`shots/91`），设备保留验收版本 2.0.417/418。

## 四、证据清单（`tmp_debug/device_acceptance_20261029_batch38/`）

| 类别 | 文件 |
|---|---|
| 构建 | `build_rust.log`、`build_flutter_apk.log` |
| 数据 | `qa38_book.txt`、`seed_qa38.sql`、`qa38_import_single.json`、`qa38_import_dup.json`、`qa38_import_bom.json`、`qa38_import_many.json` |
| 备份样本 | `backup_roundtrip.json`（备份文件 pull）、`export_QA38_BOM.json`（导出 pull） |
| 驱动 | `qa38.py`（UI dump/坐标/逐字符 JSON 输入）、`drive.py`、`cap.sh`、`ui.sh` |
| 截图 | `shots/00~91`（每张附 uiautomator XML），颜色取样 `shots/03_color_samples.txt` |
| prefs | `prefs/15~46`（每次关键操作后 pull） |
| 日志 | `logcat/logcat_session.txt`（22,498 行）、`logcat/logcat_crash.txt`、`logcat/share_handoff.txt` |
| 恢复 | `pre_upgrade/legado.db`、`pre_upgrade/FlutterSharedPreferences.xml`、`restore/FlutterSharedPreferences_final.xml` |

## 五、缺陷与遗留

### 5.1 P2：备份恢复后同会话内阅读主题页持续转圈，重启后恢复

- 复现（稳定复现 2 次）：
  1. 应用内创建/导入主题并应用（当前 id 非空），本地备份到
     `/sdcard/Download/legado`；
  2. 「恢复默认」清空主题库（或任意改动主题数据）；
  3. 设置 → 备份与恢复 → 长按「恢复」→ 选该备份 → 确认恢复，等待「恢复成功」；
  4. 打开阅读器 → 阅读设置 → 点「阅读主题」入口。
- 实际：主题页仅 AppBar + 居中转圈，2 秒/8 秒截图均未加载（`shots/86、87`）；同一时刻
  设置入口卡片显示「未应用主题（自定义）」（`shots/80`），但磁盘 prefs 已恢复
  （`prefs/43`：主题列表、`current_id`、列数 4 齐全）。
- 期望：恢复完成后主题库/当前 id/列数即时刷新，页面正常展示列表。
- 恢复手段：重启应用后列表与当前标记正常（`shots/85、90`）。
- 影响：数据无丢失；仅恢复成功后本次会话内的主题页不可用，需重启。**非阻塞本批验收**，
  但建议本批内或下一批修复。
- 定位线索：批 38 在 `flutter_legado/lib/src/screens/webdav_settings_screen.dart:669`
  新增 `ref.invalidate(readerThemeProvider)`；`ReaderThemeNotifier.build()` 以
  `unawaited` 方式启动 `_loadLoop()` 异步落 `loaded=true`。恢复后 provider 重建时
  `_loadLoop` 未完成落状态（logcat 无异常输出），疑似 invalidate/重建与异步首载的时序问题；
  建议改为显式 `reload()`（await 完成后再更新 state）或对 invalidate 后的首次读取加超时兜底。

### 5.2 分享接收方限制（说明，非缺陷）

- 本机唯一 `application/json` 接收方是原版 Legado 的书源导入页；阅读主题 JSON 被其判为
  「格式不对」（`shots/54`）。分享链路本身已验证：Chooser 收到 `ACTION_SEND` 并把
  content URI 交给目标 Activity（`logcat/share_handoff.txt`）。若需“接收方成功打开”的
  正向证据，需另装能读取本应用主题 schema 的接收端。

### 5.3 构建回退（既有问题，非本批引入）

- `armeabi-v7a` 构建因 `rar`/`nom` 依赖冲突回退为无 quickjs（`"quickjs":false`），与批 37
  同口径；32 位 ARM 设备 JS 书源不可用。建议单独开项处理依赖。

## 六、结论

- 场景 1~7、9：**PASS**。
- 场景 8：**PASS（数据往返与回归正常），附 P2 缺陷 1 项**（恢复后同会话主题页转圈，
  重启恢复；不影响数据正确性）。
- 遗留：§5.1（建议修）、§5.2（验证边界说明）、§5.3（既有构建回退）。
- 设备已清理：DB/偏好恢复至升级前内容，测试主题与文件删除，应用保留 2.0.417/418。

编写者：QA（ZCode 子代理）｜ 2026-10-30
