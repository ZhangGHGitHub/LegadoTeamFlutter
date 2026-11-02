# 批 2b-2a 设备验收报告（首页与导航：显隐 · 顺序 · 默认页 · 底栏文字 · 自定义图标）

> 范围：设置批 2b-2a「首页与导航」——底栏五页签默认顺序与书架落点、
> 首页/发现/订阅显隐（书架/我的恒显示）、拖拽排序与隐藏项置底、
> 默认主页下拉（仅可见页）与冷启动落点、底栏文字四档（标准/悬浮/Rail）、
> 5 页签 × 2 槽自定义导航图标（SAF 选图/选中优先/替换/删除/缺文件回退/
> 陈旧 MediaStore 项/重启与重装保持）、导航备份与恢复（同会话刷新、
> 图标文件不随 JSON）、返回键/深链/书架/发现/RSS/阅读回归、清理与版本保留。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`）。
>
> **结论：功能验收通过（9/9 场景 PASS），附条件 1 项 P2、4 项 P3 登记。**
> 本批目标行为均实测成立：默认五页签顺序与书架落点、显隐/排序即时生效并
> 重启保持、默认主页与「仅可见页」下拉、四档底栏文字在标准/悬浮/Rail 三形态
> 的一致语义、自定义图标全生命周期（SAF / 选中优先 / 原子存储 / 相对标识 /
> 缺文件回退 / 陈旧项不崩溃）、备份恢复同会话刷新且图标文件不入 JSON。
> **P1=0、P2=1、P3=4。** 唯一 P2 是横竖屏切换（底栏 ↔ Rail 布局切换）后
> PageView 内容回到索引 1（书架）而选中页签仍为原页（我的），页面内容与
> 选中态不同步（可复现、无崩溃/数据丢失，见 §四 P2-1）。
> 稳定性：日志窗口内 **FATAL=0、ANR=0、RenderFlex overflow=0**；
> crash buffer 中 `io.legado` 相关记录 0 条。
>
> **复验更新（2026-11-03 01:00–01:40）**：P2-1 已由 `74e5638b66` 修复并在
> 设备上复验通过，**P2 关闭**；P3-1/P3-2 已修复并实测通过，P3-3 确认为有意
> 语义。详见 **§六 旋转回修复验**。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM_G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（3x，1dp=3px） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备 root | `adb shell id` = `uid=0(root)`（直接读取 `shared_prefs`、`files/nav_icons` 取证） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.437** / versionCode **438**（安装后、重装后与最终 `pm clear` 后各复核；`data/version_final.txt`） |
| 源码基线 | `master` HEAD **`5ba6d1f14e`**（`chore: 批2b-2a 收尾（2.0.437+438 双日志与计划登记）`）；工作区仅 `.zcode/`/报告/证据目录未跟踪 |
| 验收时间 | 2026-11-02 23:45 ~ 2026-11-03 00:40（宿主机时间；设备时钟慢约 2 分钟） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_batch2b2a/`（logcat/data/scripts/fixtures，不入库）；截图 **70 张** 在 `docs/materials_1103/` |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45:24**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（与 2b-1b-2a 复用一致；`data/so_info.txt`） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 38.4s`，**200,186,540 B（190.9 MB）**；sha256 **`2174242d089cdb4ea53e8808237f5d308e054d170fec98aa804937e777b0c488`**；构建时间 2026-11-02 23:49:04（`logcat/build_release.log`、`data/apk_info.txt`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200186540 bytes**；`flutter build apk --release` 后重装同 APK 仍 Success |
| 冷启动 | 首次 988 ms；后续 **412 / 515 / 364 / 475 / 311 / 329 / 385 / 424 / 376 / 376 ms**（`am start -W` TotalTime） |
| 清理后版本 | `pm clear` 后仍为 **2.0.437 / 438** |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（15.7s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/unit/main_tab_order_test.dart test/unit/nav_icon_picker_test.dart test/unit/nav_icon_store_test.dart test/widget/home_navigation_config_test.dart test/widget/main_navigation_settings_sheet_test.dart test/widget/navigation_bars_labels_test.dart` | **65/65 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量 Flutter 测试 | `flutter test` | **3916 passed + 1 skipped**，EXIT=0（1:34，`logcat/full_tests.log`） |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |
| Kotlin JVM 单测 | 未执行 | 本批无 Kotlin 变更 |

> 构建/测试串行执行，规避 `flutter test` 与 `flutter build` 并发导致的
> `GeneratedPluginRegistrant.java` 竞态。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 默认：五页签 首页/书架/发现/订阅/我的，落在书架，默认「自动」仅选中项有文字 | **PASS** | `01_default_launch.png`、`data/ui_default.xml` |
| 2 | 显隐：关首页/发现/订阅→仅书架/我的；书架/我的开关禁用；隐藏项置底；重启保持 | **PASS**（P3-1 禁用开关配色） | `05`、`06`、`07`、`08`、`68` |
| 3 | 顺序：拖拽重排、底栏顺序变化、内容/滚动保持；隐藏项无把手置底；恢复默认 | **PASS** | `15`、`16`、`17`、`18`、`19`~`21`、`68` |
| 4 | 默认首页：下拉仅可见页；设「我的」→冷启动落我的；隐藏默认页回落 | **PASS**（P3-4 语义登记） | `22`~`27`、`57` |
| 5 | 底栏文字四档：标准/悬浮；Rail 展开+不显示强制折叠不出现文字 | **PASS**（P2-1 旋转不同步） | `28`~`37`、`67` |
| 6 | 自定义图标：SAF、选中优先、替换/删除、缺文件回退、陈旧项不崩溃、重启/重装保持 | **PASS**（P3-2 toast 被遮挡） | `38`~`52`、`data/ui_stale_toast_semantics.xml` |
| 7 | 备份/恢复：JSON 含导航键不含图标文件；同会话刷新；异常默认页回落首个可见 | **PASS**（P3-3 缺省键语义） | `53`~`57`、`data/backup_nav*.json` |
| 8 | 回归：返回键、双击、深链、书架/发现/RSS、导入 TXT 阅读；FATAL/ANR/overflow=0 | **PASS（限见 §3.8）** | `58`~`65`、`logcat/session_full.log` |
| 9 | 清理：恢复默认导航/图标、空书架、保留版本 | **PASS** | `66`、`69`、`data/version_final.txt` |

## 三、逐场景证据

### 3.1 场景 1：默认底栏与书架落点

- **步骤**：`pm clear` → 冷启动 → 截图并 dump 语义树。
- **预期**：底栏 5 项顺序 首页/书架/发现/订阅/我的；默认落书架；
  「自动」档只显示选中项文字。
- **实际**：底栏 5 项 `Tab 1 of 5`~`Tab 5 of 5`，顺序正确；内容为书架
  （空书架插画 + 「全部」分组）；仅「书架」有文字（自动档 =
  `onlyShowSelected`）。语义树 `data/ui_default.xml`，截图 `01`。
- **结论**：PASS。

### 3.2 场景 2：显隐与重启保持

- **步骤**：外观 → 首页与导航 → 依次关闭「首页」「发现」「订阅」开关；
  检查底栏、书架/我的开关可点性；重启复核；再单独隐藏「首页」复核
  底栏回到 2 项、隐藏项列表位置。
- **预期**：底栏只剩书架/我的；书架/我的不可隐藏（开关禁用）；
  隐藏项移到顺序末尾；重启保持。
- **实际**：
  - 三项关闭后（`05`、`06`）导航项列表仅剩「书架（始终显示）」「我的
    （始终显示）」；底栏 2 项（`07`）；prefs：
    `showHome=false/showDiscovery=false/showRss=false`、
    `mainNavigationOrder=bookshelf,my,home,explore,rss`（隐藏项置底）。
  - 点击书架开关无状态变化（`ui_after_tap_bookshelf_switch.xml` 行仍
    「始终显示」、prefs 未变），符合禁用语义；视觉仍为启用配色 → **P3-1**。
  - 重启（`08`、`ui_restart_two_tabs.xml`）仍为 2 项、落书架（412 ms）。
  - 仅隐藏「首页」时（`68`）：列表底部出现无拖拽把手的「发现/首页」隐藏行，
    `mainNavigationOrder` 末尾追加隐藏项，验证「置底、不可拖」。
- **边界说明**：「隐藏当前 tab 的运行时回退」无法通过 UI 触发——唯一入口
  「首页与导航」位于「我的 → 设置 → 外观」，而「我的」恒显示；该代码路径由
  widget 测试覆盖，并以场景 4/7 的异常配置冷启动回落实测（见 §3.7）。
- **结论**：PASS（P3-1 登记）。

### 3.3 场景 3：拖拽排序、内容/滚动保持、恢复默认

- **步骤**：全部页签可见（顺序 书架/我的/发现/订阅/首页）→ 打开 Sheet →
  拖动「我的」到首位 → 再拖动「首页」到第二/第三位 → 关闭复核；
  重启复核；点「恢复默认」→ 确认。
- **预期**：底栏顺序变化；当前页内容不丢；滚动位置保持；隐藏项置底不可拖；
  恢复默认回到五页签默认顺序与书架落点。
- **实际**：
  - 第一次拖拽（把手 x≈105,y=978→640）：顺序变为
    `my,bookshelf,explore,rss,home`（`ui_after_drag_my_top.xml`）。
  - 第二次拖拽（首页 y=1542→1010）：顺序变为 `my,home,bookshelf,explore,rss`
    （`ui_after_drag_home_third.xml`、`16`）。
  - 返回主界面：底栏顺序 我的/首页/书架/发现/订阅（`17`）；当前页仍为「我的」，
    打开 Sheet 前记录的「设置」行 y=`1524..1680` 与返回后完全一致
    （`ui_my_scrolled_before_reorder.xml`/`ui_after_reorder_main.xml`），
    内容与滚动位置保持；选中索引 0。
  - 重启（`18`）：顺序保持，落点仍为「书架」（按页签身份而非索引）。
  - 恢复默认（`19`~`21`）：Sheet 列回 首页/书架/发现/订阅/我的，prefs 中
    `showHome/showDiscovery/showRss/defaultHomePage/mainNavigationOrder/navIcon*`
    键全部移除，底栏恢复五页签默认顺序。
- **结论**：PASS。

### 3.4 场景 4：默认主页（仅可见页 / 冷启动 / 回落）

- **步骤**：①全可见时打开「默认主页」下拉；②选「我的」→ 冷启动；
  ③隐藏「订阅」后再打开下拉；④隐藏默认页「首页」→ 冷启动；
  ⑤构造「默认页被隐藏」的恢复配置（见 §3.7）→ 冷启动。
- **预期**：下拉仅列可见页；设「我的」后冷启动落我的；默认页不可见时回落
  首个可见页（顺序如此时不是书架）。
- **实际**：
  - 下拉 5 项：首页/书架/发现/订阅/我的（`22`）；隐藏「订阅」后下拉仅 4 项，
    不含订阅（`26`、`ui_defaultpage_menu_hidden.xml`）——仅可见页成立。
  - 设「我的」→ 冷启动落「我的」（`24`，364 ms；prefs `defaultHomePage=my`）。
  - 通过开关隐藏当前默认页「首页」时，prefs 立即被重置为
    `defaultHomePage=bookshelf`（参考版 `fallbackHomePage` 语义），冷启动落书架
    （`27`，4 项底栏）——与任务文案「回落首个可见（不是书架）」存在语义差异，
    登记 **P3-4**。
  - 恢复「默认页=首页 + 首页隐藏」的备份配置后冷启动：落点为**我的**
    （`57`、`ui_abnormal_launch.xml`）——即 `tabs.first` 回落路径实测成立，
    不是书架。
- **结论**：PASS（P3-4 语义登记）。

### 3.5 场景 5：底栏文字四档（标准 / 悬浮 / Rail）

- **步骤**：首页与导航 → 底栏文字依次设「自动/选中时显示/常驻/不显示」，
  分别在标准底栏、悬浮底栏（外观→主界面→悬浮底栏）截图；横屏启用 Rail
  （大屏导航形态=自动），先展开侧栏再切「不显示」观察。
- **预期**：自动/选中=仅选中项有文字；常驻=全部；不显示=无文字；
  Rail 展开态遇「不显示」不得出现文字（允许强制折叠，需记录）。
- **实际**：

  | 形态 | 自动 | 选中时显示 | 常驻 | 不显示 |
  |---|---|---|---|---|
  | 标准底栏 | 仅选中（`01`/`27`） | 仅选中（`28`） | 全部 4/5 项（`30`） | 无文字（`29`） |
  | 悬浮底栏 | 仅选中（`32`） | 仅选中（`33`） | 全部（`31`） | 无文字（`34`；语义树无文本节点） |

  - Rail（横屏 1920×1080，240px=80dp 折叠态，自动档）：显示文字（`35`）；
    点「展开侧栏」后 768px=256dp、显示文字，`railExtended=true`（`36`）。
  - 保持 `railExtended=true` 切「不显示」并回横屏：Rail **强制折叠为 80dp**、
    纯图标无文字（`37`），「展开侧栏」按钮不再出现——与复核说明一致，宽度
    差异已登记。
  - **P2-1**：旋转到横屏时 PageView 内容回到书架，而 Rail/底栏仍选中我的
    （`67`，见 §四）。
  - 横屏同时构建 Rail 与悬浮底栏（`35`~`37`），属计划登记的既有行为。
- **结论**：PASS（P2-1/P3 登记）。

### 3.6 场景 6：自定义导航图标

- **步骤**：生成纯色 PNG（红 `220,30,30`、蓝 `30,90,220`、绿 `30,180,70`）
  推送至 `/sdcard/Download/` 并扫描 → 首页与导航 → 导航栏图标 →
  为「首页」未选中选红、选中选蓝 → 返回主界面验证两种状态 → 用绿替换未选中 →
  删除未选中 → 用 root 删除选中文件后重启 → 选择已删除文件的陈旧 MediaStore
  行 → 重启 / `install -r` 复核持久化。
- **预期**：底栏显示自定义图；选中态优先；替换/删除即时生效且清理旧文件；
  缺文件回退内置；陈旧项不崩溃且有提示；重启/重装保持。
- **实际**：
  - 选图入口为 SAF DocumentsUI（`39`，`data/ui_saf_icon_pick.xml`），落盘
    `files/nav_icons/<sha1>.png`（526/527 B，与宿主 sha1 一致）；
    prefs 值改为相对标识 `nav_icons/<sha1>.png`。
  - 未选中态显示红色方块（`42`）；选中「首页」后显示蓝色方块（`43`）——
    选中态优先级成立。
  - 替换为绿色（`44`）：新文件 `<green sha1>.png` 写入，旧红色文件删除，
    prefs 指向绿；蓝色（选中）保留。
  - 删除未选中（`45`）：绿色文件删除、`navIconHome` 键移除；底栏未选中回退
    内置房子图标（`46`）。
  - root 删除选中文件（`navIconHomeSelected` 仍指向不存在文件）→ 重启后
    选中「首页」显示内置图标（`48`），无 FATAL（`47`）。
  - 陈旧 MediaStore 行：删除 `/sdcard/Download/saf_fake.png` 后 DocumentsUI
    仍列出（`saf_fake.png, 38 B`）；选中后日志（00:18:40）
    `[ContainerImagePicker] 平台=Android SAF 失败: SafNotFoundException(
    content://com.android.providers.downloads.documents/document/msf%3A1000001549):
    open failed: ENOENT (No such file or directory)`，
    `PID=46956` 不变、FATAL=0；图标槽显示 broken-image（`49`、
    `data/ui_stale_toast_semantics.xml`）。失败提示 toast 被图标管理面板遮挡
    （**P3-2**）。说明：该条日志在后续为隔离复测执行 `logcat -c` 后未保留在
    最终 `session_full.log`，此处按当时抓取原文转录；复测阶段系统已不再列出
    被删文件的陈旧行，未能二次构造。
  - 重启（`51`）与 `adb install -r` 重装（`52`）后绿色自定义图标仍在，
    prefs 相对标识与文件均保留。
- **结论**：PASS（P3-2 登记）。

### 3.7 场景 7：备份 / 恢复与图标文件

- **步骤**：备份路径设为 SAF 新建目录
  `/storage/emulated/0/Download/legado_qa_1103` → 备份（JSON1）→ 检查 JSON；
  启用订阅后再次备份（JSON2）；把导航改为「隐藏订阅 + 默认我的 + 底栏文字
  不显示」→ 长按「恢复」选本地 JSON2 → 不重启回主界面复核；
  另构造「默认页=首页且首页隐藏」的 JSON 副本（异常配置注入）恢复并冷启动。
- **预期**：备份 JSON 含导航键与图标路径、不含图标二进制；恢复后同会话刷新
  底栏；图标文件不随 JSON（跨设备缺文件回退内置）；异常默认页回落首个可见。
- **实际**：
  - JSON1 **3167 B**、JSON2 **3316 B**（`data/backup_nav.json`、
    `data/backup_nav2.json`）；`appPrefs` 含
    `mainNavigationOrder / showHome / showRss / defaultHomePage /
    labelVisibilityMode / navIconHome(Selected) / useFloatingBottomBar`，
    `navIcon*` 仅为相对路径字符串，**无图片内容**。
  - 恢复 JSON2（`showRss=true, default=bookshelf, order=my,bookshelf,
    explore,rss,home, label=auto`）后同会话回到主界面（不重启）：
    底栏立即恢复 **5 项**、自动档仅选中「我的」有文字、首页显示绿色自定义图标
    （`56`）；prefs 与 JSON2 一致。
  - 首轮 JSON1 未包含 `showRss`（备份时该键为缺省 true 未落盘），恢复后本机
    的 `showRss=false` 保留 → 底栏仍 4 项。属「缺省键不覆盖本机值」的 JSON
    合并语义，登记 **P3-3**；JSON2 显式含 `showRss=true` 后完整还原。
  - 异常 JSON（`defaultHomePage=home`、`showHome=false`、order 我的在首）
    恢复后冷启动：落 **我的**（`57`），即首个可见页，不是书架。
  - 图标文件不随 JSON：JSON 仅存相对标识；跨设备缺文件按场景 6 的回退路径
    显示内置图标（本机文件存在时保持自定义图）。
- **结论**：PASS（P3-3 登记）。

### 3.8 场景 8：回归

| 检查点 | 实测 | 证据 |
|---|---|---|
| 返回键（非书架页→书架） | 我的页按返回 → 书架页（未退出） | `58`、`ui_back_from_my.xml` |
| 双击底栏（书架重选） | 空书架双击书架项，无崩溃/无异常弹层 | `ui_double_tap_bookshelf.xml` |
| 深链 `legado://import/bookSource` | 打开「关联导入」页；返回后回到书架、当前页签保持 | `59`、`ui_after_deeplink_back.xml` |
| 发现页 | 「当前没有发现源！」空态正常渲染，无 overflow | `60` |
| 订阅页 | 规则订阅/收藏/使用说明/小说拾遗/Meow云/烏雲净化正常渲染 | `61` |
| 本地 TXT 导入与阅读 | `qa_novel.txt`（10.2 KB）导入成功 → 打开阅读器显示正文与 `1/19` 页码 → 左滑翻页 → 返回书详 → 返回书架；书架保留「在读」进度 | `62`~`65` |
| FATAL / ANR / overflow | 日志窗口 **14,315 行**：FATAL=0、ANR=0、RenderFlex overflow=0；crash buffer 中 `io.legado` 0 条（其余为 uiautomator 噪声） | `logcat/session_full.log`、`logcat/crash_buffer.txt` |

- **未覆盖**：通知点击压栈（无通知夹具）；有滚动内容时的「双击回顶」
  （清理阶段书架为空/单本不足滚动，交互无崩溃但未观察滚动位置回顶）。
- **日志窗口说明**：安装后至 00:18 的 logcat 在陈旧项复测前被 `logcat -c`
  清空，未纳入计数；期间应用持续可交互、无崩溃回桌面现象（PID 变更仅来自
  `install -r`/`force-stop` 等主动操作）。
- **结论**：PASS（限见上）。

### 3.9 场景 9：清理与版本保留

| 步骤 | 结果 | 证据 |
|---|---|---|
| 恢复默认导航 | Sheet 列回默认五页签；`show*/defaultHomePage/mainNavigationOrder/navIcon*` 键全部移除；`labelVisibilityMode=auto` | `ui_after_nav_reset2.xml` |
| 删除自定义图标 | `files/nav_icons` 目录不存在/为空 | adb `ls` 报 No such file |
| 删除测试书 | 书架管理删除《qa_novel》，书架为空 | `ui_shelf_manage3.xml` |
| 删除测试图/书文件 | `qa_nav_*.png`、`qa_novel.txt` 删除 | `ls` 无匹配 |
| 删除备份目录 | JSON 均删除；目录空壳因 `Text file busy` 暂无法移除（环境限制，遗留空目录） | `rm -rf` 输出 |
| `pm clear` 后最终态 | 空书架、默认五页签（首页/书架/发现/订阅/我的）、落书架；无 `nav_icons` | `66`、`69`、`ui_final_clean2.xml` |
| 版本保留 | **2.0.437 / 438** | `data/version_final.txt` |

## 四、问题清单与分级

| 级别 | 编号 | 描述 | 复现步骤 / 证据 | 归属 |
|---|---|---|---|---|
| P1 | — | 无 | — | — |
| P2 | P2-1 | 横竖屏切换（底栏 ↔ Rail 布局切换）后 PageView 回到 `initialPage=1`（书架），而 `_currentTab` 仍为原页签：底栏/Rail 选中「我的」但内容显示「书架」 | ①默认态点「我的」（内容我的）→ ②`settings put system user_rotation 1` 横屏 → ③内容变书架、选中仍我的（`67_p2_rotation_desync.png`；`data/ui_p2_clean_landscape.xml` 内容书架 + `Tab 5 of 5`）；恢复竖屏仍不同步（`_process_unlabeled_desync_portrait.png`）。期望：旋转后内容与选中页签一致（保持我的）。疑为布局结构切换重建 PageView 时 PageController 采用 initialPage，需开发确认是否本批引入 | 代码问题（HomeScreen 布局/索引同步）；无崩溃、无数据丢失 |
| P3 | P3-1 | 「书架/我的」禁用开关仍渲染启用配色（主题 `SwitchThemeData` 未处理 disabled state），点击无效但视觉像可切换 | `06`、`25`、`68`：两行「始终显示」开关为棕色轨道+白圆；点击不改变状态（`ui_after_tap_bookshelf_switch.xml`）。建议禁用态使用灰轨道/灰圆 | UI 视觉细节 |
| P3 | P3-2 | 图标管理面板内选择陈旧/失败项时 SnackBar 被面板遮挡，用户看不到 toast（异常已捕获、进程存活） | `49_stale_mediastore_toast.png`（面板覆盖底部，无可见提示）；当时日志见 §3.6 转录 `SafNotFoundException`；PID 46956 不变、FATAL=0。建议面板内联提示或提升 SnackBar 层级 | UI 可用性 |
| P3 | P3-3 | 恢复备份时，备份 JSON 未包含的布尔键（缺省 true 未落盘）不会覆盖本机 false，导航状态可能「恢复不完整」 | 备份 JSON1（3167 B）无 `showRss`；本机 `showRss=false` 恢复后仍 false（底栏 4 项）。JSON2 显式含 `showRss=true` 后恢复为 5 项（`56`）。属 appPrefs 合并语义，建议产品/开发确认是否需要在备份时强制落盘显隐三键 | 语义登记（可能参考版同口径） |
| P3 | P3-4 | 通过开关隐藏当前默认页时，`defaultHomePage` 被立即重置为 bookshelf（参考版 `fallbackHomePage`），冷启动落书架；与任务文案「回落首个可见（不是书架）」不同 | 默认页=首页 → 隐藏首页 → prefs `defaultHomePage=bookshelf`、冷启动书架（`27`）；而「恢复配置中默认页已隐藏」场景冷启动落我的（`57`），即 `tabs.first` 路径正确。建议明确产品预期 | 语义登记 |
| — | 环境 | 备份目录 `legado_qa_1103` 空壳无法删除（`Text file busy`，DocumentsUI/FUSE 占用） | `rm -rf` 输出；目录内容已清空 | 环境限制 |

## 五、结论与建议

- **功能结论**：本批 9 组场景全部达到验收目标（其中场景 2/4/7 的边界语义
  与场景 5 的旋转态各有登记项）。显隐/排序/默认页即时生效且重启保持；
  底栏文字四档在标准/悬浮/Rail 三形态语义一致；Rail 在不显示档强制折叠、
  无文字、隐藏展开钮；自定义图标全生命周期（SAF、选中优先、相对标识、
  32MB/试解码/原子写由单测覆盖，本机实测替换删除清理旧文件、缺文件回退、
  陈旧项不崩溃）成立；备份 JSON 仅含导航键与图标路径、同会话刷新底栏。
- **稳定性结论**：日志窗口 14,315 行 FATAL=0、ANR=0、overflow=0；
  crash buffer 无 `io.legado` 记录；PID 变更均来自重装/强停等主动操作。
- **门禁结论**：`flutter analyze` 0、定向 65/65、全量 3916+1 skipped、
  release 构建 EXIT=0、安装成功、版本 2.0.437+438。
- **建议**：
  1. **P2-1**：旋转/宽窄布局切换后按 `_currentTab` 校正 PageController（或为
     PageView 增加 PageStorageKey / 在布局切换分支保持同一 Element），并补
     widget 测试「当前页≠索引 1 时切换 Rail/底栏」。
  2. **P3-1**：SwitchThemeData 增加 disabled 态颜色，避免禁用开关误示可点。
  3. **P3-2**：图标管理面板内失败提示改为面板内 SnackBar/Banner，确保可见。
  4. **P3-3/P3-4**：与产品确认「缺省键恢复」「隐藏默认页立即重置为书架」
     的预期；若要求严格回落首个可见，需在隐藏默认页时保留 route 到启动期
     再按 `tabs.first` 计算（但会偏离参考版 `fallbackHomePage`）。
  5. 横屏 Rail 与悬浮底栏同时构建为既有行为，建议后续单独立项收敛。
- **证据路径**：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261102_BATCH2B2A.md`
  - 截图（70 张）：`docs/materials_1103/`
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261103_batch2b2a/`
    （`logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
    `build_release.log`、`session_full.log`、`crash_buffer.txt`；`data/apk_info.txt`、`apk_sha256.txt`、`so_info.txt`、
    `version_final.txt`、`backup_nav.json`、`backup_nav2.json`、
    `backup_nav_abnormal.json`；`data/ui_*.xml` 为逐步骤语义树；`scripts/` 为
    本轮 UI 自动化脚本）

## 六、旋转回修复验（2026-11-03 01:00–01:40）

> 范围：`74e5638b66`（`fix(ui): 批2b-2a 旋转后 PageView 与页签同步`）对 §四 P2-1
> 的修复复验，兼 P3-1/P3-2 修复回归、P3-3 语义确认、显隐/排序/默认页/底栏文字/
> 图标 SAF/返回键回归与稳定性计数。**结论：P2-1 关闭（P2=0）**；
> 场景 1/2/3/5/6/7 实测 PASS，场景 4（单页不可达）**BLOCKED/登记**，不伪造 PASS。

### 6.1 复验对象与产物

| 项 | 值 |
|---|---|
| 源码基线 | `master` HEAD **`74e5638b66`**（`fix(ui): 批2b-2a 旋转后 PageView 与页签同步`）；工作区仅未跟踪文档/证据目录 |
| 版本 | **2.0.437 / 438**（安装后与 `pm clear` 后各复核，`data/version_final.txt`） |
| APK | `flutter build apk --release` **EXIT=0**（`assembleRelease 4.6s`），**200,186,540 B（190.9 MB）**，构建时间 2026-11-03 01:03:02；sha256 **`870402d1ff16e323f1f86efbbc320931af7a194991d209a430e9d5f0b1ac45e6`**（`data/apk_info.txt`、`logcat/build_release.log`） |
| AOT 产物 | `build/app/intermediates/flutter/release/x86_64/app.so` mtime **2026-11-03 00:57:17**（arm64 00:57:18），由修复工作树编译；`.so` 复用 `7fea8be8…`（51,883,696 B，与 2b-2a 一致，本批无 Rust 变更） |
| 安装 | `adb install -r` **Success: streamed 200186540 bytes** |
| 设备 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 / SDK 35 / x86_64，1080×1920 / 480 dpi，root |
| 冷启动 | 382 ms（装后首次）、362 ms（默认页=我的）、323/353/343/310 ms（后续各次 `am start -W`） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_reverify/`（`logcat/`、`data/` 149 个语义树/数据、`scripts/`）；截图 **50 张** 在 `docs/materials_1103/reverify/` |

交付前门禁（本机实测，串行执行）：

| 检查 | 命令 | 结果 |
|---|---|---|
| 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（9.3s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/unit/main_tab_order_test.dart test/unit/nav_icon_picker_test.dart test/unit/nav_icon_store_test.dart test/unit/main_prefs_navigation_test.dart test/unit/switch_disabled_theme_test.dart test/widget/home_navigation_config_test.dart test/widget/main_navigation_settings_sheet_test.dart test/widget/navigation_bars_labels_test.dart` | **86/86 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量测试 | `flutter test` | **3923 passed + 1 skipped**，EXIT=0（1:36，`logcat/full_tests.log`） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success（见上表） |

### 6.2 P2-1 修复前后对照（根因与证据）

- **根因**（提交正文）：`useRail` 分支改变 PageView 父链，横竖屏切换时 PageView
  元素被重建并按 `initialPage=1` 重新挂载，选中页签与 `_currentTab` 未变 →
  内容回到书架。
- **修复**：`SafeArea → Row → Expanded` 结构恒定，Rail 在窄屏用零尺寸占位；
  `_syncPageController` 每次 build 无条件 post-frame 校正（去重）；单页配置
  隐藏 NavigationBar/Rail 并收敛索引 0。

| 状态 | 内容页（语义树首个业务标题） | 底栏/Rail 选中 | 证据 |
|---|---|---|---|
| **修复前**（5ba6d1f14e） | 书架（`书架` + `全部` + 空态文案） | 底栏「我的」选中；Rail「我的」selected（0×0 被遮挡） | `docs/materials_1103/67_p2_rotation_desync.png`；`tmp_debug/device_acceptance_20261103_batch2b2a/data/ui_p2_clean_landscape.xml` |
| **修复后**（74e5638b66）·我的 | **我的**（书源管理/定时任务/运行定时任务） | 底栏 Tab 5/5「我的」selected；Rail Tab 5/5 selected | `reverify/03_landscape_my.png`、`data/ui_03_landscape_my.xml` |
| 修复后·订阅 | **订阅**（规则订阅/收藏/使用说明…） | 底栏 Tab 4/5「订阅」selected；Rail Tab 4/5 selected | `reverify/06_landscape_rss.png`、`data/ui_06_landscape_rss.xml` |
| 修复后·顺序重排（我的在首位） | **我的** | 底栏 Tab 1/5 selected；Rail Tab 1/5 selected | `reverify/14_landscape_reorder_my.png`、`data/ui_16_landscape_reorder_my.xml` |
| 修复后·2 页签配置 | **我的** | Rail 仅 2 项且「我的」selected（可见）；底栏 Tab 1/2 selected | `reverify/25_landscape_two_tabs.png`、`data/ui_40_landscape_two_tabs.xml` |

### 6.3 逐项复验结果

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 旋转同步（竖→横 Rail→竖，我的/订阅/2 页签/重排后） | **PASS** | `02`→`03`→`04`；`05`→`06`→`07`；`24`→`25`→`26`；`13`→`14`→`15`；内容页、底栏/Rail 高亮、内容索引全程一致 |
| 2 | 顺序重排后旋转往返 | **PASS** | 拖「我的」到首位（`11`/`12`，`ui_13` 顺序 my,home,bookshelf,explore,rss）→ 底栏 Tab 1/5 我的（`ui_15`）→ 横屏 `14`/`ui_16`（Rail Tab 1 selected）→ 竖屏 `15`/`ui_17` 内容与滚动位置（设置行 1513..1680）一致 |
| 3 | 当前页内容/滚动/输入保持 | **PASS** | 我的：`08`/`ui_08` → `09` → `10`/`ui_10`，书签 354、阅读记录 576、缓存管理 798、文件管理 1020、关于 1242、退出 1416 **逐值一致**；书架：导入 8 本后滚动，`16`/`ui_27` → `17` → `18`/`ui_29`，qa_shelf_1 432-654、2 654-996、3 996-1338、4 1338-1680 **逐值一致**；发现页输入 `RotationTest123`：`19`→`20`→`21`（三张截图同尺寸 68,171 B，EditText 文本保持） |
| 4 | 单页不可达 | **BLOCKED/登记** | 书架/我的恒显示（`main_tab.dart:112`），UI 开关禁用，备份仅支持 `showHome/showDiscovery/showRss`（无书架/我的键），无法构造单页；单页契约仅由 widget 测试 `单页配置：initialPage=1 由 post-frame 收敛到索引 0`（`home_navigation_config_test.dart:430`）与导航组件 <2 项保护覆盖；设备侧仅验证最小 2 页签旋转（`25`/`26`，无断言） |
| 5 | P3 回归 | **P3-1 PASS / P3-2 PASS / P3-3 语义确认** | P3-1：禁用开关轨道 `(213,213,213)`/thumb `(163,163,163)`，启用轨道 `(121,85,72)`/thumb 白（`22`，像素采样）；P3-2：33 MB PNG 选择失败 toast **`图片过大（上限 32MB）`** 在图标面板内部可见，节点 bounds `[0,1731][1080,1920]`（`29`、`ui_46`）；P3-3：恢复不含 `showRss` 的 JSON（3167 B）后本机 `showRss=false` 保持不变、`showHome=true` 生效、底栏同会话 4 项（`32`/`33`，prefs 实测），与单测「备份缺省导航键不覆盖本机 false」一致 |
| 6 | 回归：显隐/排序/默认页/底栏文字/图标 SAF/返回键 | **PASS** | 显隐：关首页/发现/订阅→2 页签（`23`/`24`）、prefs 三键 false、隐藏项置底；排序：拖拽生效、恢复默认回五页签（`30`/`31`）；默认页：下拉仅列可见页（`ui_79` 无订阅）、设我的→冷启动落我的（`34`，362 ms）；底栏文字：常驻 4 项全标签（`35`）、不显示纯图标（`36`）、恢复自动；图标 SAF：选入红色 PNG→`navIconHome=nav_icons/2ee6a8e4…png`（相对标识，文件 526 B）、底栏显示红块（`38`）、选中槽缺文件回退内置房子（`39`）、删除文件重启后回退内置（`40`，无崩溃）；返回键：我的→书架（`41`）；FATAL/ANR/overflow=0 |
| 7 | 清理与版本保留 | **PASS** | 恢复默认后导航键全部移除（仅 `labelVisibilityMode=auto`，`45`）；8 本书经书架管理删除、重启后空书架（`ui_106`）；测试文件 `qa_novel/qa_shelf_1..8/qa_big.png/qa_backup_nav.json/qa_icon_red.png` 全部删除，`legado_qa_1103` 空目录本轮 `rmdir` 成功（上轮环境遗留解除）；`pm clear` 后默认五页签/空书架（`47`/`50`），版本 **2.0.437/438**，`files/nav_icons` 不存在（`data/version_final.txt`） |

### 6.4 稳定性计数

| 日志 | 窗口/行数 | FATAL EXCEPTION | ANR | RenderFlex overflow | E/flutter | io.legado tombstone |
|---|---|---|---|---|---|---|
| `logcat/session_full.log`（筛选 flutter/AndroidRuntime/ActivityManager/libc/DEBUG） | 01:01:46–01:31:24，7,172 行 | **0** | **0** | **0** | **0** | — |
| `logcat/full_buffer.log`（完整 ring buffer） | 截至 01:40，50,578 行 | **0** | **0** | **0** | **0** | **0**（337 个 tombstone 全部为 `uiautomator`/`app_process`，即 dump 工具自身退出噪声） |

`logcat -b crash` 中 `io.legado` 记录 0 条；进程 PID 变更均来自 `install -r`、
`force-stop`、`pm clear` 等主动操作。未出现崩溃回桌面、无应用 ANR 弹窗。

### 6.5 复验发现与登记

| 类型 | 编号 | 描述 | 证据/步骤 |
|---|---|---|---|
| 既有行为（非本批引入） | O-1 | 横屏同时构建 Rail 与底栏；底栏占高后 Rail 第 4/5 项语义 bounds 为 0×0（订阅/我的不可见，底栏仍可达）。修复前语义树同样为 0×0，本批未改该布局策略 | 修复前 `data/ui_p2_clean_landscape.xml`（订阅/我的 0×0）；修复后 `ui_03`/`ui_06` 同样 0×0；`25_landscape_two_tabs.png` 两页签时 Rail 可见 |
| 观察（疑似既有缺陷，待独立确认） | O-2 | 在「书架管理」删除书籍并返回书架主界面后，封面列表不即时刷新（切页签后仍显示已删书），重启后消失；非本批修改文件（`bookshelf_screen.dart` 未在本提交内），判定疑似既有缺陷，不计入本批复验结论 | 单本复现：导入→书架管理删除（`ui_113` 书架为空）→返回仍显示封面（`48`、`ui_114`）→切发现再回书架仍显示（`49`、`ui_115`）→重启后空书架（`ui_106`）；8 本批量删除后同样在 `46_final_empty_shelf.png` 观察到残留 4 张封面 |
| 说明 | — | 本轮备份恢复复用 2b-2a 生成的 `backup_nav.json`（3167 B，无 `showRss`），恢复链路与 JSON 合并语义一致，未重新生成备份文件 | `data/backup_nav.json`（旧证据目录）、`32`/`33` |

### 6.6 结论

- **P2-1 关闭**：竖→横（Rail）→竖在「我的」「订阅」、2 页签与顺序重排后四种
  配置下，内容页/底栏/Rail 选中/索引全部一致；修复前后截图与语义树对照成立。
- **P3-1、P3-2 关闭**（禁用开关置灰、Sheet 内 toast 可见均可复现验证）；
  **P3-3 确认为有意语义**（缺省键不覆盖本机 false，产品如需严格还原另行裁决）；
  **P3-4 维持原登记**（本批未改默认页回落语义，未复测）。
- **场景 4 单页配置 BLOCKED**：正常配置与备份均无法构造单页，仅单测覆盖，
  设备侧不作 PASS 声明。
- 残留：O-1 横屏 Rail/底栏并存遮挡（既有行为，建议单独立项）；O-2 书架管理
  删除后主界面不刷新（疑似既有缺陷，待独立确认）。二者均不阻塞本次 P2 关闭。
- 证据路径：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261102_BATCH2B2A.md`（本章）
  - 截图（50 张）：`docs/materials_1103/reverify/`（`01`~`50`）
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261103_reverify/`
    （`logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
    `build_release.log`、`session_full.log`、`full_buffer.log`、`crash_buffer.txt`；
    `data/apk_info.txt`、`version_final.txt`、`ui_*.xml`（149 个）；
    `scripts/ui.py`、`open_nav_sheet.py`）
