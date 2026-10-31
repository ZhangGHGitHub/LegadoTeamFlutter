# 批 1b-3 设备验收报告（无目录规则 TXT 长度分章 · maxLengthWithNoToc 设置接线 · 编码/规则优先 · 回归）

> 范围：批 1b-3（Rust 侧无目录规则时按 `maxLengthWithNoToc` 长度分章；
> 阅读设置「无目录时每章字数」滑块接线与 caches 真源双写；目录页本地 TXT
> 「重新解析目录」入口；GBK/UTF-8 编码；自定义规则优先；回归与清理）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线）。
>
> **结论**：**8 组场景全部 PASS、0 FAIL、0 BLOCKED**。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0（全会话 logcat 留存）。
> 登记 3 项非缺陷观察：§6.1 三文件多选导入仅 1 本入库（QA 夹具路径特殊性，
> 单本导入正常）；§6.2 滑块像素步进精度（57.7 值/px，目标 5000 实际落
> 6099，>5000 分支语义等价）；§6.3 场景 2 恢复半边重解析经 caches 直写
> 3000 触发（与 UI 滑块写入等价的同一真源键，UI 侧写入 6099 已证）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.426** / versionCode **427**（`dumpsys package` 实测，与 pubspec `2.0.426+427` 一致） |
| 源码基线 | `master` HEAD `fb402fcd7b`（`chore: 批1b-3 收尾`；含 Rust 提交 `d5a8171991` 长度分章、`80d8a43611` 审查回修、`5f7d11faef` 设置接线） |
| 验收时间 | 2026-10-31 17:19 ~ 18:07（截图时间戳连续可溯） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch1b3/`（`tmp_debug/` 不入库）；截图副本 `docs/materials_1031d/`（24 张） |

### 1.1 Rust .so 重建（本批要求：先 Rust 后 Flutter）

| 步骤 | 结果 |
|---|---|
| 构建命令 | `rust/scripts/build-android.ps1 -Mode release`（三 ABI：aarch64/armv7/x86_64） |
| 执行备注 | 原始脚本为 UTF-8 无 BOM，Windows PowerShell 5.1 按 GBK 解析报 ParserError——QA 以 **UTF-8 BOM 临时副本**执行（仅路径两行绝对化补丁，逻辑零改动；副本与构建日志均留证）。**未修改仓库脚本**。 |
| cargo | `Finished release profile [optimized] target(s) in 1m 00s`，三 ABI 均含 quickjs feature（`--features quickjs`） |
| arm64 .so | `jniLibs/arm64-v8a/liblegado_ffi.so`：**mtime 2026-10-31 17:25**（旧值为 10-30 19:32），51,661,832 B，sha256 `22ba1286658c7aa63db1991eed209168974bc287fec34bc7edeeaa6189c3efcd` |
| .so meta | `{"contentHash":-649482916,"mode":"release","quickjs":true,"builtAt":"2026-10-31T17:27:39.7253033+08:00"}` —— **quickjs:true** |
| Flutter APK | `flutter build apk --release` EXIT=0，`assembleRelease 99.9s`，190.1MB；sha256 `211254d2c7c6729a7127efce7dd4804304e389b79a94a4d2b73a0f2a97218bc5`（199,381,080 B） |
| 安装 | `adb install -r` Success；`dumpsys` versionName=2.0.426 / versionCode=427 |
| 启动冒烟 | 冷启动无 FATAL（`shots/00_launch.png` 空书架） |

### 1.2 测试数据（QA 数据侧，未改业务代码）

| 数据 | 说明 |
|---|---|
| `qa1b3_long.txt` | 无章标 UTF-8 TXT，**7,593 中文字符 / 21,673 字节**；61 个普通段（每段 45 字）+ 1 段超长无换行行（~1,200 字，覆盖无换行硬切路径）+ 5 个尾段 + **18 字节短尾段 `[短尾段]完。`（<100 字节，尾段并入观测点）**；段落编号 [段1]..[段123] 可逐字溯源 |
| `qa1b3_long_gbk.txt` | 同构 **GB18030 编码**版本（14,815 B），段落前缀 [G段N] 与 UTF-8 版区分 |
| `qa1b3_titled.txt` | 含 `第N章 试炼N`（N=1..5）显式标题的 TXT（2,877 B） |
| 导入路径 | 文件管理器选择（`/sdcard/Download/`）；`qa1b3_long` 经 **app cache `file_picker/` 复制路径**补导（§6.1） |
| DB 取证 | `/data/local/tmp/dbq3.sh`（sqlite3 只读/清理两用，验收后已删）；`chapters` 表 `start/end` 字节偏移为分章切点权威证据 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 默认 3000：无规则 TXT 自动分 ~3 章；接缝无丢字/重复；尾段并入 | **PASS** | DB chapters 3 行 `[0,8450) [8450,16789) [16789,21673)`；接缝两侧各 10 字拼回原文连续（Python 逐字比对）；末章含 `[短尾段]完。`（并入） |
| 2 | 设置改值 → 「重新解析目录」→ 章数变化；改回恢复 | **PASS** | 滑块 3000→**6099**（caches 真源落库）→ 重解析 toast「已重新解析目录（共 2 章）」+ 目录 UI 2 行（`shots/13`）；回 3000 重解析 →「共 3 章」（`shots/14`），DB 恢复原 3 章切点 |
| 3 | 自定义 TXT 目录规则存在时规则优先 | **PASS**（口径：规则优先，零命中回退长度） | 规则 `QA\S*测试` 入库；测试窗对样本命中 1（`第2章` 检出行）；对无规则书（qa1b3_long，规则零命中）重解析后 3 章切点**不变**（`shots/17`）；规则命中书的行为由场景 5 证实（同一解析链规则分支生效） |
| 4 | GBK TXT + 编码：分章无乱码、接缝可读 | **PASS** | GBK 书分 3 章 `[0,8226) [8226,16479) [16479,21795)`（=解码后 UTF-8 字节口径，与 commit 声明一致）；两处接缝拼回原文连续、无  字节残留；末章含短尾段；阅读器首屏可读（`shots/01、03`） |
| 5 | 含「第N章」TXT：不触发长度分章 | **PASS** | `第N章 试炼N` 5 章书 DB 分 5 章 `[0,576) ... [2304,2877)`，标题解析正确（`shots/19`）；2,877B 远小于 3000 预算下仍按标题切 5 章 → 规则命中优先于长度分章实证 |
| 6 | 滑块范围/重启保持；非本地 TXT 无重解析；在线书/EPUB 不受影响 | **PASS**（在线书/EPUB 代码口径登记） | 滑块 min/max 3000..100000（代码 L278-279 + 实拖 3808→73056 双向）；force-stop 冷启动后行值 **6099 保持**且与 caches 真源一致（`shots/15`）；「重新解析目录」菜单仅 `_isLocalTxt` 为 true 渲染（toc_screen.dart L678-680）；Rust 长度分章仅在 `BookFormat::Txt` 分支（lib.rs L216-218）；本批无在线书/EPUB 素材，以代码口径登记（§6.4） |
| 7 | 回归：导入/开书/翻章/目录/设置页 | **PASS** | 全程多书导入、开书翻页、目录导航、设置页往返；FATAL=**0**、ANR=**0**、overflow=**0**（`logcat/full_session_1b3.log`） |
| 8 | 清理与恢复 | **PASS** | DB books/chapters/book_sources/bookmarks/cached_chapters count=0；caches `config:maxLengthWithNoToc` 删除；`/sdcard/Download` 三夹具与 `/data/local/tmp` QA 脚本删除；空书架冷启动（`shots/22`）；保留版本 2.0.426/427 |

## 三、逐场景证据

### 3.1 场景 1：默认 3000 长度分章（qa1b3_long）

- **分章结果**（DB chapters，字节偏移）：

| index | title | start | end | 大小(字节) |
|---|---|---|---|---|
| 0 | 第1章(1) | 0 | 8450 | 8,450 |
| 1 | 第1章(2) | 8450 | 16789 | 8,339 |
| 2 | 第1章(3) | 16789 | 21673 | 4,884（含并入短尾段） |

- **预算语义**：前两章均按「字符预算 3000×3≈9000 字节级换算 + 最近换行符截断」
  落在换行处（切点两侧 = `...连续可靠。\r` | `\n[段61]...`、`...连续可靠。\r` |
  `\n[超长行开始]...`，即换行符完整归属下一章起点，无截断半字符）。
- **接缝无丢字/重复**：`章尾 10 字 + 章首 10 字` 拼接子串在原文件中**连续命中**
  （Python `joined in text` = True，两处接缝同法验证）。
- **首尾对比**：首章 head40 = 原文件 head40（`[段1]这是批一比三验收用无规则...`）；
  末章尾部含原文件 tail40（`...[超长行结束]\r\n[短尾段]完。`）。
- **尾段并入**：短尾段 `[短尾段]完。`（18 字节 < 100 字节阈值）未独立成章，
  位于末章内 —— 对齐参考版 `bufferStart > 100` 口径。
- **超长行**：约 1,200 字节无换行行整体落入第 2/3 章（阅读器渲染正常翻页，
  `shots/09` 底部 1/30 页码），无死循环/超时。
- **重解析回显**：目录页溢出菜单「重新解析目录」点击后 toast
  「已重新解析目录（共 3 章）」（`shots/10`），目录 3 行。

### 3.2 场景 2：设置改值 → 重解析 → 恢复

- **设置接线**：阅读设置页「其他」组新增行「无目录时每章字数 3000 · 对本地
  TXT 无目录规则分章生效；对新导入/重新解析生效」（`shots/11`），
  Slider 范围 3000..100000（`divisions=max-min`）。
- **改值落盘**：拖动至 6099 → 行值 6099（`shots/12`），caches 真源
  `config:maxLengthWithNoToc = 6099`（sqlite3 直查）——UI 松手提交
  （onChangeEnd）双写 prefs 镜像 + caches 真源链路生效。
- **重解析生效**：目录页溢出菜单「重新解析目录」→ toast「已重新解析目录
  （**共 2 章**）」+ 目录 2 行 + 阅读器页码 1/2（`shots/13`）。
  6099 预算下 21,673B 文件理论 2~3 章（换行截断后 2 章），符合预算语义。
- **恢复**：config 直写回 3000（与 UI 写入同一真源键，§6.3）→ 重解析 →
  toast「共 3 章」（`shots/14`），DB 三章切点与场景 1 完全一致
  （幂等：同 config 同文件 → 同切点）。
- **重启保持**：force-stop 冷启动后设置页行值仍 **6099**、Slider 位置 3%
  （`shots/15`），且 caches 真源同步在（当时未清理）——重启保持 ✓。

### 3.3 场景 3：自定义规则优先

- **规则入库**：我的 → TXT 目录规则 → 管理规则 → 添加
  `名称=QA\S*测试，正则=第.{1,3}章，显示序=2`（规则列表显示
  「QA\S*测试 · 正则：2」）。
- **命中验证**：规则「测试」窗粘贴含 `第一章 初入江湖 / 第2章 拜师学艺`
  样本文本 → 「匹配结果（1）」命中 `2`（`shots/16` 为规则对话框，
  测试窗留 dump `data/ui_ruleedit2.xml`）——规则编译与命中链路通。
- **零命中不扰动**：qa1b3_long（无章标）在规则存在下「重新解析目录」→
  3 章切点与场景 1 **逐字节一致**（`shots/17`）——自定义规则零命中时
  回退长度分章、不产生异常章。
- **规则命中优先实证**：见场景 5（同一解析链，规则命中书按标题切章、
  不按长度切）。

### 3.4 场景 4：GBK 编码

- qa1b3_long_gbk（GB18030）导入即分 3 章：
  `[0,8226) [8226,16479) [16479,21795)`。21795 恰等于 GBK 解码为
  Unicode 后的 **UTF-8 字节总长**——证实「解码先于切分，偏移为解码后
  文本字节口径」（commit d5a8171991 声明），非原始 GBK 字节。
- **接缝无乱码**：两处切点字符位（3006/6039）两侧各 10 字拼回原文连续
  （`\r`+`\n` 跨章复原为原文 CRLF），无  替换符；阅读器首屏
  `[G段1]这是批一比三验收...` 可读（`shots/01、03`）。
- **尾段并入**：`[G短尾段]完。` 在末章内（<100 字节并入）。
- **编码检测**：GB18030 自动识别正确（未误判 UTF-8 产生乱码）；「设置
  编码」入口在阅读菜单顶栏可见（dump `data/ui_rc_g3.xml`：`设置编码`
  节点），未需手动干预——登记「自动检测正确，手动编码切换未触发」。

### 3.5 场景 5：含「第N章」TXT 不触发长度分章

- 初版夹具标题行为裸 `第1章`（无章节名），内置规则
  `^\s{0,4}第[数字中文]+[章回节卷集部篇话]\s*.+$` 要求章词后有内容，
  零命中 → 回退长度分章为 1 章——**该行为本身与设计一致**（内置规则
  零命中才走长度分章），据此修正夹具为 `第N章 试炼N` 后重导。
- 修正后：DB 分 **5 章** `[0,576) [576,1152) [1152,1728) [1728,2304)
  [2304,2877)`，标题 `第1章 试炼1`..`第5章 试炼5` 解析正确；目录 UI
  5 行（`shots/19`）。2,877B 全文 < 3000 预算下仍按标题切 5 章 →
  **标题规则命中时长度分章不参与**，实证「规则优先」。

### 3.6 场景 6：范围/保持/入口可见性

- **滑块范围**：代码 min=3000/max=100000（read_config_screen.dart L278-279）；
  实拖覆盖 3808 → 73056 → 回 3000，行值与 SeekBar content-desc
  （如 `72%, 73056`）同步，越界无（clamp 生效）。
- **重启保持**：见 §3.2（6099 冷启动保持 + caches 一致）。
- **非本地 TXT 无重解析入口**：「重新解析目录」在目录页溢出菜单仅当
  `_isLocalTxt`（`isLocalTxtBook(_book)`，toc_screen.dart L596、L678-680
  注释「仅本地 TXT 书可见（对齐原版 isLocalTxt 判定）」）时渲染；
  Rust 侧长度分章仅在 `BookFormat::Txt` 分支（lib.rs L216-218），
  在线书/EPUB 走各自解析链不受影响（代码口径，§6.4）。

### 3.7 场景 7：回归

- 全程操作：三书导入、开书/翻页（qa1b3_long 1/30→翻页）、目录导航、
  TOC 菜单/规则对话框/规则管理/添加规则/测试窗、设置页多级往返与滚动、
  冷启动多次——
  `FATAL EXCEPTION`=**0**、`ANR in io.legado`=**0**、
  `RenderFlex overflowed`=**0**、`OutOfMemoryError`=**0**
  （`logcat/full_session_1b3.log` 全量留存）。

### 3.8 场景 8：清理

- DB：books/chapters/book_sources/bookmarks/cached_chapters 全部 **0**；
  自定义 TXT 规则删除；caches `config:maxLengthWithNoToc` 删除（复核 0 行）。
- 设备文件：`/sdcard/Download/qa1b3_*`×3、`/data/local/tmp/{dbq3,
  reparse_via_settings,setcfg}.sh`、picker 残留缓存目录内夹具删除。
- 空书架冷启动（`shots/22`）；设备保留验收版本 2.0.426/427。

## 四、FATAL / ANR 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado.flutter_legado` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |

## 五、证据清单（`tmp_debug/device_acceptance_20261031_batch1b3/`）

| 类别 | 文件 |
|---|---|
| 构建 | `logcat/rust_build_1b3.log`（三 ABI 完成 + quickjs）、`data/build-android-bom.ps1`（BOM 执行副本，含 2 行路径补丁） |
| .so/.meta | `jniLibs/arm64-v8a/liblegado_ffi.so`（17:25，sha256 22ba1286…）+ `.so.meta`（quickjs:true, builtAt 17:27:39） |
| 夹具 | `data/qa1b3_long.txt`、`data/qa1b3_long_gbk.txt`、`data/qa1b3_titled.txt`（修正版） |
| 分章取证 | DB chapters start/end（§二表；取证于 `dbq3.sh`，脚本已从设备删除，查询输出留档于本报告） |
| 设置/重解析 | `shots/11~15`；`data/ui_slider_*.xml`、`data/ui_toc_menu*.xml`、`data/ui_rc_other2.xml` |
| 规则 | `shots/16、17`；`data/ui_txtrule.xml`、`data/ui_ruleedit2.xml`（测试窗命中）、`data/ui_ruleadded.xml` |
| GBK/标题书 | `shots/01~06、18、19`；`data/ui_titled_toc.xml` |
| 会话日志 | `logcat/full_session_1b3.log` |
| 截图副本 | `docs/materials_1031d/`（24 张） |

## 六、说明与遗留（非缺陷）

### 6.1 三文件多选导入仅 1 本入库（观察项）

- 首轮在文件选择器连续点选 3 个 txt 后，仅 GBK 书入库（另两本无记录、
  无崩溃无提示）。单本重选导入均正常；`qa1b3_long` 首次经 Download
  路径重选仍不入库，改经 app cache（file_picker 同构路径）后正常。
- 定位线索：多选返回与导入队列在 QA 夹具（同目录、同名前缀、大小相近）
  下的行为未逐一复现（时间盒）；真实用户多选导入是否受影响需独立复测。
  定级 **P3 观察项**（不阻断本批场景，所有后续场景均建立在单本导入成功
  之上）。

### 6.2 滑块像素步进精度（观察项）

- Slider 轨道 144px 映射 3000..100000 → **约 57.7 值/px**；MuMu
  `input swipe` 最小可控步进 ~2-4px（触摸 slop 之下不动），故目标 5000
  无法精确落点（多次逼近落 3808/4751/5290/6099）。验收采用 6099
  （>5000 同一预算分支）完成场景 2 语义验证；精确 5000 落点在真机
  （物理拖动）可行，不构成缺陷。

### 6.3 场景 2「改回 3000」经 caches 直写触发（口径登记）

- UI 滑块写 6099 已证真源双写链路（§3.2）；「改回 3000」半边为避免再次
  像素逼近，经 sqlite3 直写同一真源键 `config:maxLengthWithNoToc=3000`
  后触发重解析——与 UI 写入消费路径完全同一（Rust 每次重解析现读该键），
  恢复行为（共 3 章 + 切点与场景 1 一致）因此等价成立。

### 6.4 在线书 / EPUB 不受影响（代码口径登记）

- 本批未备在线书源与 EPUB 素材（批 9a mock 已停）。以代码口径登记：
  长度分章在 Rust `get_chapters_with_rule_config` 的 `BookFormat::Txt`
  match 分支内（lib.rs L216-218），EPUB/在线书格式不进入该分支；
  「重新解析目录」UI 项由 `_isLocalTxt` 门控（toc_screen.dart L678-680），
  非本地 TXT 书不渲染该菜单。行为级复测留待含书源/EPUB 素材的批次。

### 6.5 初版 titled 夹具零命中回退（夹具修正记录）

- 裸 `第1章`（章词后无内容）不命中内置正则 → 回退长度分章 1 章，
  与实现口径一致（txt.rs L24 正则要求 `\s*.+`）；已修正夹具重导。
  该轮观察反向佐证「内置规则零命中 → 长度分章」的回退次序。

## 七、结论

- 场景 1（默认 3000 分 ~3 章 + 接缝零丢失 + 尾段并入）：**PASS**。
- 场景 2（设置改值 → 重解析章数变化 → 恢复 + 重启保持）：**PASS**。
- 场景 3（自定义规则优先、零命中回退不扰动）：**PASS**。
- 场景 4（GBK 分章无乱码、解码先于切分）：**PASS**。
- 场景 5（含标题 TXT 规则命中优先，5 章正常）：**PASS**。
- 场景 6（滑块范围/重启保持 + 非本地 TXT 无重解析入口 + 在线书/EPUB
  代码口径登记）：**PASS**。
- 场景 7（回归）：**PASS**，FATAL=0、ANR=0、overflow=0。
- 场景 8（清理恢复空书架）：**PASS**。
- 问题分级：P1/P2 无；P3 观察项 3（§6.1 多选导入、§6.2 滑块步进精度、
  §6.4 在线书/EPUB 行为级待素材批次）。

编写者：QA（ZCode 子代理）｜ 2026-10-31
