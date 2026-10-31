# 批 1a 设备 + UI 验收报告（独立阅读设置页 · 三组 23 行 · 顶栏附加信息 · 禁用返回键 · 振动 · 滑块 · 参考版 UI 对照）

> 范围：批 1a（设置主页「阅读界面」→ 独立「阅读设置」页；屏幕/页面控制/其他
> 三组 23 行接线；展示顶部工具栏附加区域；禁用返回键；翻页成功/选词振动；
> 滑块提交语义；参考版 UI 对照；大字体；深色模式）。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测在线）。
> 参考版对照机：同设备 `io.legato.kazusa`（versionName 3.26.19）。
>
> **结论**：**功能项 6 PASS + 1 BLOCKED；UI 项 3 PASS（对照差异清单见 §八）**。
> OS 层 FATAL=0、ANR=0、RenderFlex overflow=0。
> BLOCKED：振动（翻页成功/选词）——应用侧 vibrator 调用链已接通并有
> `dumpsys vibrator_manager` 调用记录，但 MuMu 虚拟振动器对该 effect 返回
> `ignored_unsupported`（无物理马达），体感无法观测，不伪 PASS。
> 滚轮翻页（鼠标滚轮）与音量键翻页：MuMu 环境无法注入滚轮事件 / 音量键被
> MuMu 系统层截走（`MuMuAudio/VolControlHelper` logcat 证据），登记环境限制。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」） |
| 设备型号 / 系统 | SM-G9900（MuMu 伪装）/ Android 15（SDK 35） |
| 分辨率 | 1080x1920（全程未改；项9 未做小窗，以系统字体放大 1.3 覆盖「大字体」侧） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.424** / versionCode **425**（`dumpsys package` 与 pubspec `2.0.424+425` 一致） |
| 源码基线 | `master` HEAD `9af2841398`（`chore: 批1a 收尾（2.0.424+425 双日志与计划关闭登记）`） |
| 参考版 | `io.legato.kazusa` 3.26.19（对照基准） |
| 验收时间 | 2026-10-31 07:22 ~ 09:20（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261031_batch1a/`；截图副本 `docs/materials_1031b/`（55 张） |

### 1.1 构建与安装

| 步骤 | 结果 |
|---|---|
| Rust FFI | 复用既有产物（本批仅 Dart 变更）；arm64 `.so` mtime 保持 `2026-10-30 19:32:20` |
| Flutter APK | `flutter build apk --release` **EXIT=0**（96.9s，189.9MB） |
| APK sha256 | `f7dd29c8052ffb882af5b4f4904c206b4a4c65d4cb0eebef1bd672c8874cb4a6`（199,118,560 B） |
| 安装 | `adb install -r` Success；`dumpsys` versionName=2.0.424 / versionCode=425 |
| 启动冒烟 | 冷启动无 FATAL（`shots/00_launch.png`） |

### 1.2 测试数据

| 数据 | 说明 |
|---|---|
| QA9A 三书源 + QA9A文A（8 章） | 复用批9a mock（18090）与夹具；本批将 ruleToc 改为纯 JSON 端点 `/tocjson/QA9A文A`（ruleToc.chapterList=`$[*]`，chapterUrl=`$.url`）规避 JS 拼接歧义；ruleBookInfo.tocUrl 指向该 JSON 端点 |
| DB/prefs 取证脚本 | `/data/local/tmp/dbq1a.sh`、`prefq1a.sh`（验收后已删） |
| prefs 直写脚本 | `pref_te_off/on.sh`、`pref_bk_on.sh`、`pref_vib_on/off.sh`（QA 数据侧操作，验收后已删） |

## 二、功能验收结果表

| # | 项 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 独立阅读设置页入口/返回/读内弹层 | **PASS** | `shots/01`（设置主页「阅读界面/屏幕/页面控制/阅读偏好」行）；`01`→BACK→设置主页 7 卡在位（`ui_sethome_back.xml`）；阅读器菜单底栏「设置」→ 阅读界面 Sheet（`shots/05`），返回后阅读器正常（`06`） |
| 2 | 三组 23 行逐项可操作 + 抽查 | **PASS**（滚轮/音量键环境限制登记） | 三屏 dump `ui_rc_g1/g2/g3.xml`（23 行全在位）；方向/状态栏/导航栏/进度条/双页/滑块见 §三 |
| 3 | 顶栏附加信息开关 | **PASS** | ON：菜单顶栏「第1章」+「QA9A文书源」徽章（`29`）；OFF：信息块整体不渲染（`30`）；prefs 直写后冷启动仍 OFF（重启保持）；恢复 ON 后复现（`31`） |
| 4 | 禁用返回键三态 | **PASS**（语义对齐原版，见 §三.4） | 关：BACK 退出回书架；开+菜单关：BACK 吞掉（`32` 正文仍在）；开+菜单开：BACK 退出（防死锁路径，对齐 ReadBookActivity.kt:391-414） |
| 5 | 翻页/选词振动 | **BLOCKED** | `logcat/vibrator_manager_full.txt`：`10-31 08:49:15 io.legado.flutter_legado ... ignored_unsupported`（4ms effect）；开关 `sliderVibrator` true→false 已双向 |
| 6 | 滑块拖动不落盘/松手提交 | **PASS** | 「滑动翻页阈值」拖动：mid-drag prefs `pageTouchSlop=0`（不落盘）→ 松手 `=1000`（一次性提交）；回拖提交 8（步进精度，登记）；`shots/27、28` |
| 7 | 回归 | **PASS** | 开书/翻页/BACK/设置滚动全流程 FATAL=0、ANR=0（`logcat/full_session.log`） |

## 三、逐项证据

### 3.1 项 1：独立阅读设置页

- 入口：我的 → 设置 → 「阅读界面｜屏幕/页面控制/阅读偏好」卡（`shots/01` 前身为
  `ui_sethome.xml` bounds [48,1008][1032,1209]）→ 独立页标题「阅读设置」，
  三组（屏幕/页面控制/其他）。
- 返回：BACK → 设置主页 7 张卡全部在位（`ui_sethome_back.xml`）。
- 阅读器内原弹层：开 QA9A文A → 菜单底栏「设置」→ 「阅读界面」Sheet（全局/
  菜单/信息/更多 tab，`shots/05`）→ 返回阅读器正常（`shots/06`）。弹层入口未删除。

### 3.2 项 2：三组 23 行 + 抽查

- **行清点**（dump：`ui_rc_g1/g2/g3.xml`，截图 `11/12/13`）：
  - 屏幕（8 行）：屏幕方向(下拉)/隐藏状态栏/隐藏导航栏/填充刘海区域/扩展到刘海/
    显示亮度调节控件/平板横屏双页(下拉)/进度条行为(下拉)；
  - 页面控制（12 行）：使用自定义中文分行/文字两端对齐/段首标点悬挂/边缘点击阈值
    (步进)/滑动翻页阈值(滑块)/鼠标滚轮翻页/音量键翻页/朗读时音量键翻页/
    禁用滚动点击动画/自动换源/长按选择文本/展示顶部工具栏附加区域；
  - 其他（3 行）：翻页成功振动/选词振动/禁用返回键。合计 23 行。
- **屏幕方向**：下拉选「竖屏」→ prefs `screenOrientation=1` → 退阅读器重进，
  `SurfaceOrientation: 0`（竖屏锁定生效，`shots/15` 竖屏 1080x1920 布局）；
  恢复「跟随系统」（=0）。
- **隐藏状态栏/导航栏**：双开（prefs true）→ 重进阅读器：顶部无系统时钟/电量、
  底部无手势条（`shots/19` 对比 `03_reading4`）；恢复 false。
- **进度条行为**：下拉切「调整章节位置」→ prefs `progressBarBehavior=chapter`、
  行值即时更新（`shots/24`）；恢复「调整本章页数」（=page）。
- **平板/横屏双页**：下拉选「双页」→ prefs `doubleHorizontalPage=1`（竖屏下渲染
  不崩溃）；恢复「单页」（=0）。
- **音量键翻页**：prefs `volumeKeyPage=true` 已在；`input keyevent 24/25` 后
  页码不变，logcat `VolControlHelper/MuMuAudio master volume=4` 证明按键被
  MuMu 系统音频层截走、未达 Flutter `HardwareKeyboard`（`logcat/volume_key_
  evidence.txt`）→ **环境限制，BLOCKED 登记**；实现链（`reader_screen.dart
  _onHardwareKey` → next/prevPageOrChapter）由单测覆盖。
- **鼠标滚轮翻页**：MuMu 无滚轮注入通道 → 环境限制登记（开关行本身可双向）。
- **touchSlop（滑动翻页阈值）**：见项 6 滑块验证（同 Slider 控件）。

### 3.3 项 3：展示顶部工具栏附加区域

- ON（默认）：阅读器菜单顶栏信息块 = 章节名「第1章」+ 书源徽章「QA9A文书源」
  （`shots/29`，消费点 `reader_menu_panel.dart` L648 `if (showTitleAddition && ...)`）。
- OFF：prefs `showReadTitleAddition=false`（QA 直写；UI 行双向 toggle 已在项2
  验证可操作）→ 冷启动 → 菜单顶栏信息块整体不渲染（`shots/30`）——同时证明
  **重启保持**。
- 恢复 ON：冷启动信息块复现（`shots/31`）。

### 3.4 项 4：禁用返回键

实现语义（`reader_screen.dart` `_onExitPop`，对齐原版
ReadBookActivity.kt:391-414）：`disableReturnKey && !menuLayoutIsVisible` 时
吞掉返回；菜单展开时不拦截（保证退出路径不死锁）。

| 态 | 操作 | 结果 |
|---|---|---|
| 开关关（默认） | 菜单开 → BACK | 菜单关闭（`ui_bk_menu.xml`） |
| 开关关 | 再 BACK | 退出阅读器回书架（原行为；已入架书直接 pop） |
| 开关开 | 菜单关 → BACK | **不退出**，正文仍在（`shots/32`，dump reader=True/shelf=False） |
| 开关开 | 中间点击开菜单 → BACK | 菜单收起后继续退出判定 → 已入架书直接退出回书架（与任务预期「返回退出」一致） |
| 系统返回手势 | MuMu 手势=BACK 等价 | 全程以 `KEYCODE_BACK` 覆盖等价路径（手势无独立注入通道，登记） |

验证后 prefs 恢复 false。

### 3.5 项 5：振动（BLOCKED）

- 开关：`sliderVibrator` true→false 双向（prefs 直写+恢复；UI 行可操作）。
- 调用证据：开开关、翻页一次，`dumpsys vibrator_manager` Recent vibrations：
  `10-31 08:49:15 | effect | ignored_unsupported | duration: 4ms | usage: TOUCH |
  io.legado.flutter_legado (uid=10062)`（`logcat/vibrator_today_evidence.txt`）。
- 结论：**应用调用链已接通**（翻页触发 vibrator 请求），但 MuMu 虚拟振动器对
  该 effect `ignored_unsupported`——无物理马达，体感不可观测 → BLOCKED，
  不伪 PASS。选词振动同机同因（同一 vibrator 通道）。

### 3.6 项 6：滑块

- 「滑动翻页阈值」（min 0 / max 1000）：拖至右端松手 → prefs
  `pageTouchSlop` **0 → 1000**（松手一次性提交）；拖动中途快照仍 0
  （拖动过程不落盘）。回拖至最左提交 8（Slider 连续值拇指停靠精度，
  登记；实现 min=0 但拖动像素精度所致）。「下拉/步进值重启保持」由
  独立页冷启动重读已多次间接验证（方向/进度条行为均保持）。

### 3.7 项 7：回归

- 冷启动 → 书架 → 开书 → 翻页（tap 前后）→ BACK 退出 → 我的 → 设置 →
  阅读设置 → 列表上下滚动：FATAL **0**、ANR **0**（`logcat/full_session.log`
  全会话留存）。

## 四、FATAL / ANR 汇总

| 项 | 计数 |
|---|---|
| `FATAL EXCEPTION` | **0** |
| `ANR in io.legado` | **0** |
| `RenderFlex overflowed` | **0**（含 font_scale 1.3 场景） |

## 五、项 9：大字体（font_scale 1.3）

- `settings put system font_scale 1.3` → 我的/设置/独立页全链路可导航
  （`shots/40~45`）；独立页滚动到底，开关行标题两行换行正常
  （「展示顶部工具栏附加区域」，`shots/45`），logcat overflow=0。
- 恢复 `font_scale 1.0`。小窗（自由窗口）未测——MuMu 实例无小窗模式入口，
  以大字体侧覆盖「小屏/大字体」任务的可执行半边，登记说明。

## 六、项 10：深色模式

- 外观 → 主题模式「深色」（`shots/47` 为浅色态对照）→ 独立阅读设置页深色
  渲染（`shots/48`）：分组卡深底、文字浅色、开关/下拉配色协调，无对比度异常。
- 验证后恢复「浅色」。

## 七、项 8：参考版 UI 对照

### 7.1 对照基准说明

参考版 `io.legato.kazusa` **无独立阅读设置页**；其同项内容承载于阅读器
菜单「设置」→「阅读界面」Sheet 的「更多」tab（截图 `35~39`）。对照以该
tab 为基准，与我方独立页（`11/12/13` 浅色、`48` 深色）逐项比对。

### 7.2 差异清单（参考版 vs 我方）

| # | 项 | 参考版 | 我方 | 定级 |
|---|---|---|---|---|
| D1 | **页面形态** | 无独立页；全部在阅读器 Sheet「更多」tab 内纵向滚动 | 独立「阅读设置」页 + 阅读器内弹层双入口；Sheet 保留字号/背景/翻页动画等即时项 | 结构性差异（本批目标即独立页），非缺陷 |
| D2 | **分组标题** | 「屏幕显示与亮度」「翻页控制」「其它」（组名+条目同卡混排，Material 卡片风） | 「屏幕」「页面控制」「其他」（IosGroup 分组卡，组头外置） | 视觉差异，非缺陷（我方设计口径） |
| D3 | **屏幕超时** | 有（`keep_light`，默认档） | **缺行**（`read_config_screen_data.part.dart` L15-16：字段有、消费未接线，按「禁新造死开关」不放入本页，留 1b 平台通道接线后补） | 有意缺行，**非缺陷**（登记待接线） |
| D4 | **适配特殊样式** | 有开关 | 缺行（EPUB 特殊样式适配，我方由 EPUB 渲染链内部处理，无全局开关） | 有意缺行，非缺陷 |
| D5 | **护眼模式** | 有（入口行） | 缺行（我方护眼由背景色板/纯黑模式承担） | 有意缺行，非缺陷 |
| D6 | **书签角标/角标大小/点击图片行为/点击区域设置/阅读锚点/朗读脱离提示/主题模式切换提醒/启用绘制优化/使用新版目录/无规则匹配时章节分割字数** | 有（10 行） | 缺行（属书级/渲染细节项，非本批三组范围；其中「无规则匹配章节分割字数」由内置 TXT 规则链承担） | 有意缺行，非缺陷 |
| D7 | **控件形态（下拉）** | 行尾胶囊 chip（点击弹选项，如「跟随系统」） | 行内下拉（行值+▼），点击弹 SimpleDialog | 形态差异，非缺陷（语义等价） |
| D8 | **控件形态（滑块/步进）** | 步进用 −/＋ 圆钮夹值（如角标大小 10dp） | 滑块 Slider（滑动翻页阈值）+ 步进（边缘点击阈值 −/＋） | 形态差异，非缺陷 |
| D9 | **开关配色** | Material 蓝（开启=蓝底白点） | 种子色（浅棕）开关 | 主题差异，非缺陷 |
| D10 | **行高/内边距** | 行高约 128px、卡内 16px 边距 | 行高 174px（标准 IosListTile 节奏）、组卡 12px 边距 | 视觉差异，非缺陷 |
| D11 | **标题字号** | 20sp 行标题、16sp 副标题 | 20sp 行标题、14sp 副标题（副标题略小） | 视觉差异（轻微），P3 观察项 |
| D12 | **进度条行为/双页/滚轮/音量键/朗读时音量键/禁用滚动点击动画/自动换源/长按选择文本** | 有（与参考版同名同义） | 有（本批接线，行为验证见 §三.2） | 对齐 ✓ |
| D13 | **滑动进度条时震动 / 选择文本时震动** | 有（参考版命名） | 有（命名「翻页成功振动/选词振动」，语义对应；本批新接线） | 对齐 ✓（命名差异） |
| D14 | **深色模式** | Sheet 深色（Material 深底） | 独立页深色（种子色深底），对比协调 | 对齐 ✓ |

### 7.3 结论（UI）

- 我方独立页覆盖参考版「更多」tab 的**全部通用行为项**（D12/D13/D14）；
  缺行均为参考版特有渲染细节项或未接线项（D3~D6），已在代码注释/计划中
  登记为有意取舍，无缺陷。
- 形态/配色/行高差异（D2/D7~D11）为我方 iOS 风格设计口径，与参考版
  Material 风格并存，P3 观察项，不阻断。

## 八、清理

- DB：books/chapters/cached_chapters/book_sources 清零（复核 count=0）。
- prefs：批1a 全部键（screenOrientation/hideStatusBar/hideNavigationBar/
  showReadTitleAddition/disableReturnKey/sliderVibrator/pageTouchSlop/
  doubleHorizontalPage/progressBarBehavior）删除回落默认（grep 复核 0 条）；
  font_scale 恢复 1.0；主题恢复浅色。
- 设备文件：`/sdcard/Download/qa9a_*`、`/data/local/tmp/*` QA 脚本全删。
- 设备保留验收版本 2.0.424/425；最终冷启动书架空态
  （`shots/49_final_clean.png`）。

## 九、结论

- 功能：项1/2/3/4/6/7 **PASS**；项5 振动 **BLOCKED**（调用链已接通、
  MuMu `ignored_unsupported` 留证）；滚轮/音量键环境限制登记（logcat 证据）。
- UI：项8/9/10 **PASS**；参考版对照差异清单 14 条，无 P1/P2 缺陷，
  P3 观察项 1 条（D11 副标题字号略小）。
- OS 层 FATAL=0、ANR=0、overflow=0。

编写者：QA（ZCode 子代理）｜ 2026-10-31
