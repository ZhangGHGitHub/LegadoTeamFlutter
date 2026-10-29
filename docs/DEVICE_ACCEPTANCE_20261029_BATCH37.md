# 批 37 设备验收报告（阅读器顶栏按钮配置 / 本地 TXT 设置编码）

> 范围：批 37（`2b853b9c8c` … `2c2dea493f`）——阅读器顶栏动作池与配置持久化、
> 配置页（开关 / 上下移 / 恢复默认 / 上限 6 个）、顶栏按配置渲染与长按二级动作、
> 「更多」菜单兜底去重、本地 TXT 目录与正文消费 `Book.charset`（设置编码真正生效、
> 单列写不改动其它阅读配置）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线，adbd `uid=0`）。
>
> **结论**：场景 2~8 为 **PASS**。**场景 1 存在 1 项偏差（非阻塞）**：本地 TXT 默认
> 顶栏只有「设置编码 / 更多」，没有任务书期望的「TXT 目录规则」，原因是批 37b
> **有意**把 `toc_rule` 移出默认启用集（`3fa82be342`/`da0d2d5981` 登记，文案改为
> 「目录规则库（仅管理规则）」），需主代理/用户确认该偏差是否可接受（见 §五.1）。
> 另登记 1 项应用级异常（`Could not decompress image.`，3 次，无堆栈，未能稳定复现，
> OS 层 FATAL/ANR=0）与 4 项低优观察，见 §五。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 / 密度 | 1080x1920 / 480dpi（未改动） |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，`uid=0`；可直接读写应用私有目录与 DB） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.414** / versionCode **415**，DB `user_version=117`、299,008 字节、`books=0`、`book_sources=1`（`批25口令源`，规则为空占位） |
| 验收版本 | versionName **2.0.416** / versionCode **417**（`dumpsys package` 与 `aapt dump badging` 一致） |
| 源码基线 | `master` HEAD `2c2dea493f`（`chore: 批37 收尾（2.0.416+417 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-29 22:40 ~ 23:20（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261029_batch37/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 构建与安装

| 步骤 | 命令 | 结果 |
|---|---|---|
| Rust FFI | `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release` | **EXIT=0**，`build_rust.log` |
| Flutter APK | `cd flutter_legado && flutter build apk --release` | **EXIT=0**，`√ Built ... app-release.apk (188.8MB)`，`build_flutter_apk.log` |
| 安装 | `adb install -r flutter_legado/build/app/outputs/flutter-apk/app-release.apk` | `Success: streamed 197986720 bytes` |
| 版本确认 | `dumpsys package` / `aapt dump badging` | 2.0.416 / 417 |

- 三个 ABI 的 `.so` 均已产出并拷入 `jniLibs`：arm64-v8a / x86_64 为 `quickjs:true`，
  **armeabi-v7a 为 `quickjs:false`**（`liblegado_ffi.so.meta`）。原因是既有依赖冲突
  `rar 0.4.0`（要求 `nom ^7.1`）与 `nom 7.1.3` 不兼容（`ToUsize` 未对 `u64` 实现），
  构建脚本按既有逻辑回退「无 quickjs」。**非本批回归**：20:46 的旧构建 `.meta`
  同样是 `quickjs:false`，详见 §五.4。
- 升级前已 `am force-stop` 并整库备份：`pre_upgrade_db/legado.db`
  （299,008 字节，`user_version=117`，与升级后一致，本批无 DB schema 变更）。

### 1.2 测试数据（造数据，未改业务代码）

宿主 Python `ThreadingHTTPServer`（`mock_server.py`，监听 `0.0.0.0:18080`，设备经
`http://192.168.100.52:18080` 访问，同网段实测可达）提供探索页 / 搜索 / 详情 / 正文；
`seed_batch37.sql` 注入 2 个本地规则书源与 5 本书，`seed_source2.sql` 追加第二书源：

| 书 | 类型 | 文件 / URL | 说明 |
|---|---|---|---|
| QA37在线书 | 在线（mock 源） | `http://192.168.100.52:18080/book/mock-1` | 3 章，正文含中文 |
| qa37_gbk | 本地 TXT | `/sdcard/Download/qa37_gbk.txt`（4596 B） | **前 4158 字节纯 ASCII + 其后 GBK**，3 章 |
| qa37_utf8 | 本地 TXT | `/sdcard/Download/qa37_utf8.txt`（188 B） | UTF-8，2 章 |
| QA37验收EPUB | 本地 EPUB | `/sdcard/Download/qa37_utf8.epub` | UTF-8，2 章，**无封面** |
| QA37WebDAV验收EPUB | WebDAV 书 | `origin=webDav::http://…/qa37_dav.epub,{"serverID":9001}` | 复刻导入后形态（本地缓存文件 + `webDav::` origin），1 章 |

- 编码回归用 `readConfig` 预置了 Dart 侧**未建模**的键
  `{"reverseTocDisplay":true,"tocExpanded":true,"manualReplaceRuleIds":[7,8],"useGlobalAudioSkip":true}`，
  用于验证「单列写不清空其它阅读配置」。
- 另：测试中一次「换源」由应用自身创建了 `搜索-QA37-第1页-书1`（DB 证据），已在清理时删除。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 顶栏默认（在线 / 本地 TXT / 本地 EPUB） | **PASS（本地 TXT 偏差，非阻塞）** | `shots/02`、`shots/05`、`shots/06`；偏差见 §五.1 |
| 2 | 配置页：开关即时生效 / 打开目录 / 排序 / 恢复默认 / 满额禁用 / 重启保持 | **PASS** | `shots/16、17、21、26、27、28、29、30、33`；`prefs` 键值 |
| 3 | 兜底：「更多」仍可访问且可用；不重复底部常驻动作 | **PASS** | `shots/22、23、67、68、69、70、72` |
| 4 | 长按换源 / 长按下载 / 普通点击不受影响 | **PASS** | `shots/34、35、36、37、40` |
| 5 | GBK TXT：乱码错章 → 设置 GBK 正确 → 切 UTF-8 合理 → 重启保持 | **PASS** | `shots/05、42、43、44、45、48、49、50`；DB `charset/chapters` |
| 6 | 编码回归：UTF-8 TXT / EPUB / WebDAV 不被破坏；非 TXT 只写编码列；其它配置不清空 | **PASS** | `shots/51~60`；`db_before/after_charset_regression.txt`、`db_chapters_before/after.txt` |
| 7 | 回归：阅读器 / 目录 / 书架 / 发现 / RSS；FATAL=0、ANR=0 | **PASS** | `shots/61、62、63、64`；`logcat/` |
| 8 | 清理：恢复 DB、删除测试书 | **PASS** | `shots/65、73`；`restore/final_state2.txt` |

## 三、逐场景说明

### 场景 1：顶栏默认按钮 — 在线 PASS / 本地 EPUB PASS / 本地 TXT 偏差

- **在线书**（`shots/02`）：顶栏 `← 下载（离线缓存） 刷新正文 换源 ⋮更多`，与期望一致。
- **本地 TXT**（`shots/05`，此时仍为默认配置）：顶栏只有 `← 设置编码 ⋮更多`；
  **没有**「TXT 目录规则」。代码侧证据：`kReaderDefaultTopBarActionIds` 不含
  `toc_rule`（`flutter_legado/lib/src/widgets/reader/reader_top_bar_actions.dart:238`），
  批 37b 注释明确「批37b P2-2 登记」默认关闭、文案改「目录规则库（仅管理规则）」。
- **本地 EPUB**（`shots/06`）：`← 设置编码 ⋮更多`，与期望一致。
- 配置页里 `toc_rule` 行存在且可手动开启（`shots/16` 第 4 行「目录规则库（仅管理规则）·
  仅本地 TXT」），证明能力未丢失，只是默认不展示。

### 场景 2：顶栏按钮配置页 — PASS

1. 入口：阅读菜单 →「设置」→「更多」页 →「顶栏按钮」（`shots/09~15`；入口在「更多」
   页末尾，不在「菜单」页）。配置页展示动作池 16 项、副标题标注适用范围与「支持长按」、
   每行上下移 + 开关、底部「恢复默认 / 已开启 N/6 / 完成」（`shots/16`）。
2. **关闭「换源」→ 顶栏立即消失**：`shots/17` 开关关闭、计数 `已开启 4/6`；返回阅读页
   顶栏变为 `下载 / 刷新正文 / 更多`（`shots/21`），无需重启。
3. **打开「目录」→ 顶栏出现**：`shots/26` 计数 `已开启 5/6`，返回后顶栏
   `下载 / 刷新正文 / 目录 / 更多`（`shots/28`）。
4. **上下移排序生效**：把「目录」上移两位（`shots/27`），阅读页顶栏顺序变为
   `下载 → 刷新正文 → 目录 → 更多`（`shots/28`）；持久化值顺序同步为
   `download,true;refresh,true;change_source,false;catalog,true;toc_rule,false;charset,true;…`
   （`shared_prefs/FlutterSharedPreferences.xml`，键 `flutter.title_bar_actions.actions`）。
5. **恢复默认**：`shots/29`，计数回到 `已开启 5/6`，prefs 恢复
   `download,true;refresh,true;change_source,true;toc_rule,false;charset,true;catalog,false;…`。
6. **满额后未开启项禁用**：再开「目录」到 `已开启 6/6`（5 个可配置 + 固定「更多」），
   其余未开启行开关 `enabled=false`（`shots/30`，uiautomator `enabled="false"`），
   与描述「已达上限时需先关闭其它动作才能开启新的」一致。
7. **重启后配置保持**：force-stop → 重启 → 打开在线书，顶栏仍为
   `下载 / 刷新正文 / 换源 / 目录 / 更多`（`shots/33`），与重启前一致。

### 场景 3：兜底与去重 — PASS

- 关闭「换源」后打开「更多」（`shots/22`）：固定项 `添加书签 / 高亮规则 / 替换规则 /
  查看目录 / 目录显示反转 / 界面设置`，分隔线下多出 `换源`，点击进入换源页并显示
  「找到 1 个匹配书源 / 当前」（`shots/23`）——入口未丢失且可用。
- 同时关闭「下载 / 刷新 / 换源」：顶栏只剩 `⋮更多`（`shots/68`），「更多」列出
  `下载（离线缓存）/ 刷新正文 / 换源`（`shots/69`）。
  - 「刷新正文」可用：点击后底部出现 **「正文已刷新」**（`shots/70`，mock 日志同时记录
    `/chapter/mock-1/*` 请求）。
  - 「下载（离线缓存）」可用：打开缓存范围对话框（`shots/72`，`1 / 3`、取消 / 开始缓存）。
- **不重复底部常驻动作**：两次菜单快照均**不含**「全文搜索 / 自动翻页 / 朗读」，
  也不重复「目录 / 界面设置」（以固定项形式各仅一处）。注意 `search/auto_page/read_aloud`
  在默认配置下本就未开启，本应落入兜底列表，实际未出现 → 去重（`_moreMenuOwnActionIds`）生效。

### 场景 4：长按二级动作 — PASS

- 长按「换源」→ 底部弹层 `单章换源（第1章 验收章节1）/ 换书源（切换整本书的书源）`
  （`shots/34`）；点「换书源」进入换源页（`shots/35`），点「单章换源」进入单章换源页
  （`shots/40`，标题「单章换源 / 第1章 验收章节1」）。
- 长按「下载」→ 进入离线缓存管理页（`shots/36`，标题「缓存操作」、书单含
  「mock-1 已缓存 2/3」与本地书「导出」）。
- 普通点击「换源」不受影响：进入常规换源页（`shots/37`），未弹出长按菜单。
- 数据限制：本环境仅 mock 源可供比对，换源页在按当前书名检索后提示
  「未找到可替换的书源」/「没有可用书源」（`shots/35、40`）——入口与页面正常，
  替代源列表为空属测试数据不足；会话内曾由应用自身成功换源生成新书
  `搜索-QA37-第1页-书1`（DB 证据 `restore/db_after_tests.db`），说明换源链路可用。

### 场景 5：GBK TXT 编码 — PASS

1. **设置前（自动检测误判）**：GBK 文件前 4KB 为 ASCII，`detect_encoding` 判为 UTF-8 →
   目录只有一个「全文」章（`shots/05` 顶栏 `全文`、1/11；目录页 `全文 1/1`，`shots/42`），
   中文段落显示为方块/乱码（`shots/48`，10/11 页）。DB：`chapters=1`。
2. **设置编码 GBK**：顶栏「设置编码」→ 对话框（`shots/43`，候选 UTF-8/GB2312/GB18030/GBK/
   Unicode/UTF-16/UTF-16LE/ASCII）→ 选 GBK → 确定 → 正文立刻变为
   「第1段：山雨欲来风满楼，江湖夜雨十年灯。」（`shots/44`，标题「第一章 山雨欲来」）；
   目录变为 3 章「第一章 山雨欲来 / 第二章 风起云涌 / 第三章 尘埃落定」（`shots/45`）。
   DB：`charset=GBK`、`totalChapterNum=3`、`chapters=3`。
3. **切回 UTF-8 行为合理**：显式覆盖优先（代码 `decode_with_charset`），目录回落到 1 章、
   正文乱码复现（`shots/46、48`，DB `charset=UTF-8`、`chapters=1`）；再切回 GBK 恢复正常
   （`shots/49`，`charset=GBK`、`chapters=3`）。
4. **重启保持**：force-stop → 重启 → 打开该书，直接显示「第一章 山雨欲来」且中文正确
   （`shots/50`），`charset` 未被重置。
5. 说明：对话框对空输入提示「编码不能为空」（fail-closed），**没有「自动」选项**；
   自动检测等价于 `charset` 为空的历史书，已用初始状态（第 1 步）覆盖验证。

### 场景 6：编码回归 — PASS

对 UTF-8 TXT、本地 EPUB、WebDAV EPUB 分别设置编码（含 GB18030/UTF-8 往返），逐次比对 DB：

| 书 | 正文 | 章节数 | `readConfig` | 仅写编码列 |
|---|---|---|---|---|
| qa37_utf8（TXT） | 设置前后一致（`shots/51、52`） | 2 → 2 | 未变 | 是 |
| QA37验收EPUB | 一致（`shots/53、54`） | 2 → 2 | 未变 | 是 |
| QA37WebDAV验收EPUB | 一致（`shots/55、57`） | 1 → 1（GB18030 与 UTF-8 往返仍是 1，`shots/58、59`） | 未变 | 是 |
| 本地 EPUB 往返 | 一致（`shots/60`） | 2 → 2 | 未变 | 是 |

- 全列对比 `db_before_charset_regression.txt` vs `db_after_charset_regression.txt`：
  **差异只有 `charset`**（`totalChapterNum/durChapterTitle` 的变化来自「首次打开」解析，
  与编码写入无关，且 `readConfig` 四键 `reverseTocDisplay/tocExpanded/manualReplaceRuleIds/
  useGlobalAudioSkip` **逐字未变**）。
- 章节对比 `db_chapters_before.txt` vs `db_chapters_after.txt`：仅新增首次打开的书的章节，
  EPUB 章节数未因编码写入被清空 → 与 Rust `set_book_charset`
  （仅 `is_local_storage_book && is_txt_path` 才清目录）一致。

### 场景 7：回归与稳定性 — PASS

- 阅读器 / 目录（目录·书签·标注三个 Tab，`shots/42、45`）/ 书架（`shots/64`）/
  发现（`shots/61`，源内容模式加载 mock 分类与书，`shots/62`，mock 日志记录
  `/explore?kind=xh&page=1`）/ 订阅（`shots/63`，空态「当前没有订阅源！」）均正常。
- `logcat`：`FATAL EXCEPTION` = **0**、`ANR in` = **0**（`logcat/logcat_full.txt`、
  `logcat_final.txt`）；`dumpsys activity exit-info` 全部为 `reason=10 (USER REQUESTED) /
  subreason=21 (FORCE STOP)`（共 16 次，均为验收 force-stop），**无进程级崩溃记录**
  （`logcat/exit_info.txt`）；`/data/anr` 无本次时间段的 ANR 文件。

### 场景 8：清理 — PASS

- 恢复升级前 DB（299,008 字节，`user_version=117`），`books=0`、`chapters=0`、
  `book_sources=1`（仅 `批25口令源`），见 `restore/final_state2.txt`。
- 删除 `/sdcard/Download/qa37_*` 测试文件与 `/data/local/tmp` 注入脚本；
  删除应用 `crash_log.txt` 测试残留。
- 还原偏好：移除本次新增的 `flutter.title_bar_actions.actions` 键（清理后计数 0），
  顶栏回到默认配置。
- 停止 mock 书源服务（端口 18080）。
- 清理后启动：书架空态正常（`shots/65、73`）。

## 四、构建期事实（与验收结论相关）

| 事实 | 说明 |
|---|---|
| Rust 构建 EXIT=0 | aarch64/x86_64 带 quickjs；**armeabi-v7a 回退无 quickjs**（见 §五.4） |
| Flutter 构建 EXIT=0 | `app-release.apk` 188.8 MB |
| 安装 | `adb install -r` 成功，版本 2.0.416/417，包数据保留（升级安装） |
| DB schema | 升级前后 `user_version=117`，本批无迁移 |

## 五、发现与遗留问题

### 5.1 本地 TXT 默认顶栏缺「TXT 目录规则」（偏差，需裁决）

- **期望（任务书场景 1）**：本地 TXT 显示「TXT 目录规则 / 设置编码 / 更多」。
- **实际**：`设置编码 / 更多`（`shots/05`）。
- **原因**：批 37b 有意修改——`kReaderDefaultTopBarActionIds` 不含 `toc_rule`，
  文案改「目录规则库（仅管理规则）」，理由记在
  `reader_top_bar_actions.dart:13-17`（「本仓库 toc_rule 目前只打开规则库管理页，尚未把
  选中规则作用于当前本地 TXT…为不误导用户，本批将其移出默认启用集」），提交
  `da0d2d5981 fix(ui): 阅读器顶栏审查回修（菜单去重/书型/toc_rule 降级）`。
- **影响**：能力未丢失（配置页可手动开启，开启后在本地 TXT 顶栏出现），但与本批任务书
  的验收期望不一致。**判定：偏差，非阻塞；是否回退默认开启请主代理/用户裁决。**

### 5.2 应用级异常 `Could not decompress image.`（P2 观察，未定位）

- 现象：应用内崩溃记录（`app_flutter/crash_log.txt`，已留档
  `logcat/crash_log_2245.txt`）在 22:45:40、22:59:31、23:02:00 三次写入同一消息
  `Exception: Could not decompress image.`，**无堆栈**；启动时以「上次运行发生崩溃」弹窗提示。
- 边界：OS 层无 FATAL/ANR、`exit-info` 无 CRASH 记录（§场景 7），属 Dart 未捕获异步异常。
- 复现：清理图片缓存 + 空书架后启动不再出现（`shots/38`）；随后用「单本本地 TXT」、
  「单本 EPUB（无封面）」、「单本在线书（mock 封面）」分别 A/B，**均未复现**；
  因此暂不能归因到具体书/封面，也不能确认与批 37 代码路径有关（顶栏/编码链路不涉及图片解码）。
- 建议：后续用带堆栈的 debug 包 + 封面加载断点复现；本批不阻塞。

### 5.3 编码变更后 `durChapterTitle` 未同步（P3）

- 设置 GBK 后 `chapters`/`totalChapterNum` 已更新为 3 章，但 `books.durChapterTitle`
  仍为旧值「全文」（阅读页头部与目录已显示「第一章 山雨欲来」）。
- 影响：书架「最近阅读章节」文案可能滞后到下次翻章才刷新。不阻塞本批（任务书未要求）。

### 5.4 armv7 构建回退无 quickjs（既有依赖问题，非本批引入）

- `rar 0.4.0` 依赖 `nom 7.1`，而 `nom 7.1.3` 未对 `u64` 实现 `ToUsize` →
  `error[E0277] ... extra_block.rs:32`；构建脚本按既有逻辑重试「无 quickjs」并通过。
- 证据：`build_rust.log`；`jniLibs/armeabi-v7a/liblegado_ffi.so.meta` 为
  `"quickjs":false`，与 20:46 的上一版构建相同（同文件 20:46 内容），说明**不是本批回归**。
- 影响：32 位 ARM 设备上的 JS 书源不可用。建议单独开项修依赖（升级 `rar` 或裁剪 feature）。

### 5.5 换源页替代源为空（数据限制，非缺陷）

- 详见场景 4：仅 mock 源时按当前书名检索无替代项，页面提示「未找到可替换的书源」/
  「没有可用书源」；会话内应用自身换源成功过一次，故链路可用。

### 5.6 「更多」兜底包含「日/夜切换 / 上一章 / 下一章」（提示）

- 未开启的池内动作会全部进入兜底列表（`hiddenReaderTopBarActions` 设计如此）。
  当前默认配置下「更多」会多出这三项；若产品期望「更多」只放常驻动作，需另行收敛。

## 六、证据清单（`tmp_debug/device_acceptance_20261029_batch37/`）

| 类别 | 文件 |
|---|---|
| 构建 | `build_rust.log`、`build_flutter_apk.log` |
| 数据 | `mock_server.py`、`mock_server.log`、`seed_batch37.sql`、`seed_source2.sql`、`data/`、`pre_upgrade_db/legado.db` |
| 驱动 | `drive.py`（状态感知 UI 驱动）、`cap.sh`、`texts.py`、`open_config.sh` |
| 截图 | `shots/01~73`（含每次采集的 uiautomator XML） |
| DB 对比 | `db_before_charset_regression.txt`、`db_after_charset_regression.txt`、`db_chapters_before.txt`、`db_chapters_after.txt` |
| 日志 | `logcat/logcat_full.txt`、`logcat_final.txt`、`logcat_crash_all.txt`、`logcat/exit_info.txt`、`logcat/crash_log_2245.txt` |
| 恢复 | `restore/db_after_tests.db`、`restore/prefs_after_tests.xml`、`restore/final_db_state.txt`、`restore/final_state2.txt` |

编写者：QA（ZCode 子代理）｜ 2026-10-29
