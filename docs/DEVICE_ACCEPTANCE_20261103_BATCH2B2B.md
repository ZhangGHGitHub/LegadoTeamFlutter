# 批 2b-2b「我的」多栏布局设备验收报告（四档模式 · 双栏/单栏 · 匿名编辑保留 · root 导航）

> 范围：版本 **2.0.442+443**（HEAD `9242c0cb352bfb0f5318e8a83ee8b8886e13cfff`）的「我的」容器多栏能力：
> `MultiPaneMode` 四档（auto / landscape / always / off）、双栏列表-详情、单栏命名页
> root 全屏、匿名路由单栏全屏保留、阅读/搜索 root 导航、横竖屏与宽度切换、回归与清理。
> 核心实现：`flutter_legado/lib/src/utils/multi_pane_layout.dart`、
> `flutter_legado/lib/src/widgets/navigation/adaptive_my_pane.dart`、
> `flutter_legado/lib/src/screens/home_screen.dart`。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`），Android 15 / SDK 35 / x86_64，
> 物理 1080×1920 / 480 dpi（**360×640 dp**）；宽屏验收覆盖为 `wm size 1920x1200` +
> `wm density 240`（**1280×800 dp**，density 240 即 1.5x）。验收后已恢复物理值。
>
> **结论：8 组场景的核心功能全部成立（P0=0、P1=0），但 2 项验收文字口径未完全满足，作为 P2 登记（非崩溃/非阻塞）：**
> ① always 在默认 Rail 下窗口 744dp 为单栏、825.3dp 起才双栏（744dp 实为窗格内容宽）；
> ② 命名页跨「双栏→单栏」后返回宽屏时右栏栈不恢复（匿名栈按设计保留）。
> 若按任务文字字面判定，上述两项应视为未通过，是否接受取决于产品口径确认。
> 其余目标行为逐项实测成立：四档模式切换与持久化、双栏列表-详情与去重/逐级返回、
> 单栏命名页 root 全屏、匿名编辑页跨单栏保留（输入不丢、底栏/Rail 隐藏、PageView 禁滑）、
> 阅读记录/缓存管理打开书籍 root 全屏、auto/landscape 旋转切换、off 不切换；
> FATAL=0、ANR=0、overflow=0、E/flutter=0。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 物理分辨率 / 密度 | 1080×1920 / 480 dpi（**360×640 dp**；`wm size`/`wm density` 无 override） |
| 宽屏 override | 1920×1200 / 240 dpi（**1280×800 dp**）；边界测试另设 1200×1200、1257×1200、1260×1200、1116×1200、1234~1240×1200、1500×1200、1200×1920 |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备 root | `adb shell id` = `uid=0(root)`（可读取 `shared_prefs`/DB 取证） |
| 应用包名 / Activity | `io.legado.flutter_legado` / `io.legado.flutter.MainActivity` |
| 验收版本 | versionName **2.0.442** / versionCode **443**（安装后与清理后各复核） |
| 源码基线 | `master` HEAD **`9242c0cb352bfb0f5318e8a83ee8b8886e13cfff`**；QA 未修改代码 |
| 同机其他 legado 应用 | `com.legado.app.release`（原版）；参考版本次未参与断言 |
| 验收时间 | 2026-11-03 18:37 ~ 19:12（宿主时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_batch2b2b/`（logcat/data/scripts/shots，不入库） |
| 截图 | `docs/materials_1108/`（104 张，`b2b2b_*` 前缀） |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，sha256 **`7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`**；`.meta` contentHash **-993835076**、builtAt **2026-10-31T23:45:24+08:00**（沿用 M3 批次） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 68.4s`，**200,451,936 B（191.2 MB）**；sha256 **`4041be1fc1c1a18e710ef05fcc555958aa80dea1f84208d79003eb09b86fde49`**（`logcat/build_release.log`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200451936 bytes**（`logcat/install.log`）；设备侧 `base.apk` sha256 与构建产物**一致**（`data/version_installed.txt`） |
| 安装后版本 | `versionName=2.0.442 / versionCode=443`（与任务给定一致） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（14.9s） |
| 多栏定向测试 | `flutter test test/unit/multi_pane_layout_test.dart test/unit/multi_pane_setting_test.dart test/widget/adaptive_my_pane_test.dart test/widget/my_pane_root_navigation_test.dart test/widget/my_page_m1_test.dart test/widget/settings_test.dart` | **98/98 passed**，EXIT=0 |
| 全量 Flutter 测试 | `flutter test` | **4081 passed + 1 skipped**，EXIT=0（1:33） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success（见 §1.1） |

> 门禁、构建、安装串行执行，避免 `flutter test` 与 `flutter build` 并发触发
> `GeneratedPluginRegistrant.java` 竞态。设备操作在门禁完成后进行。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 四档模式：auto 840dp 边界、always 生效阈值、landscape、off；切换与重启持久化 | **PASS**（P2-O1 阈值口径偏差） | `b2b2b_10_wide_mode_dialog.png`、`b2b2b_45b_auto_800dp.png`、`b2b2b_46b_auto_840dp.png`、`b2b2b_47b_auto_838dp.png`、`b2b2b_55_always_1116x1200.png`、`b2b2b_55_always_1237x1200.png`、`b2b2b_69_land_portrait_single.png`、`b2b2b_70_land_landscape_dual.png`、`b2b2b_93_off_wide_single.png`、`b2b2b_97_restart_off_my_single.png`、`b2b2b_112_restart_auto_my_dual.png`、`b2b2b_155_off_narrow_single.png`、`b2b2b_157_off_narrow_my2.png`；`data/56_always_1238x1200.xml`、`data/56_always_1239x1200.xml`、`data/56_always_1240x1200.xml` |
| 2 | 双栏：My 左菜单 + 右空态；设置/书源管理/阅读记录右侧加载；左项高亮；重复点同项不叠栈；右栏返回逐级；底栏/Rail；空态文案 | **PASS**（P3-O1 左菜单语义） | `b2b2b_02_wide_my.png`、`b2b2b_03_wide_booksource.png`、`b2b2b_04_wide_after_dedupe_back.png`、`b2b2b_06_wide_settings.png`、`b2b2b_11_wide_back_to_settings.png`、`b2b2b_13_wide_back_to_empty2.png`、`b2b2b_14_wide_readrecord.png` |
| 3 | 单栏命名页：窄屏/off 点设置 → root 全屏（无底栏/侧栏）；返回回 My；不进入页签内 | **PASS** | `b2b2b_35_off_transition.png`、`b2b2b_38_off_settings_root.png`、`b2b2b_39_off_back_my.png` |
| 4 | 匿名编辑保留：双栏→书源管理→新建书源；输入；缩到单栏全屏、输入不丢、底栏/Rail 隐藏、PageView 不可横滑；放大回双栏仍保留；返回恢复 My | **PASS**（P3-O2 返回焦点） | `b2b2b_74_source_editor_dual.png`、`b2b2b_75_source_editor_form.png`、`b2b2b_76_source_name_input.png`、`b2b2b_77_anon_single_fullscreen.png`、`b2b2b_78_anon_after_swipe.png`、`b2b2b_79_anon_back_dual.png`、`b2b2b_80_anon_back_my.png`；`data/81_back2.xml`、`data/82_back3.xml` |
| 5 | root 阅读/搜索：双栏/单栏从阅读记录、缓存管理打开书籍 → 阅读器全屏 root；返回记录/缓存页；右栏栈不变；阅读记录无书搜索 → root 搜索页 | **PASS**（P3-O2 返回焦点） | `b2b2b_15_wide_open_from_record.png`、`b2b2b_17_wide_back_ui.png`、`b2b2b_28_wide_reader_root.png`、`b2b2b_29_wide_reader_back.png`、`b2b2b_108_single_readrecord.png`、`b2b2b_109_single_reader.png`、`b2b2b_110_single_back_record.png`、`b2b2b_111_single_back_my.png`、`b2b2b_126_cache_open_book.png`、`b2b2b_127_back_to_cache.png` |
| 6 | 横竖屏/宽度：auto/landscape 旋转切换；双栏↔双栏栈保留；landscape 竖屏单栏/横屏双栏；off 不切换 | **PASS**（P2-O2 命名页跨单栏栈不恢复） | `b2b2b_104_auto_portrait_single.png`、`b2b2b_105_auto_landscape_dual.png`、`b2b2b_69_land_portrait_single.png`、`b2b2b_70_land_landscape_dual.png`、`b2b2b_145_dual_1000dp_keep.png`、`b2b2b_146_dual_back_1280_keep.png`、`b2b2b_84_rotate_portrait_settings.png`、`b2b2b_85_rotate_back_dual_settings.png`、`b2b2b_86_rotate_back_then_back.png`、`b2b2b_93_off_wide_single.png`、`b2b2b_94_off_portrait_single.png`、`b2b2b_95_off_wide_single2.png` |
| 7 | 回归：My M1~M3、首页导航、设置、底栏/Rail、阅读/翻页、返回键；FATAL/ANR/overflow=0 | **PASS**（P3-O3 既有刷新项） | `b2b2b_87b_state.png`（M3 运行中动作行）、`b2b2b_139_web_off2.png`、`b2b2b_113_home.png`、`b2b2b_114_search.png`、`b2b2b_118_reader.png`、`b2b2b_119_reader_next.png`；`logcat/session_final.log` |
| 8 | 清理：恢复 wm size/density、多栏 auto、停 Web 服务、空书架、保留版本 | **PASS** | `b2b2b_140_final_narrow.png`、`b2b2b_142_final_after_restart.png`、`b2b2b_147_final_narrow2.png`；`data/wm_final.txt`、`data/wm_original.txt` |

## 三、逐场景证据

### 3.1 场景 1：四档模式（PASS，P2-O1）

**方法**：真实 UI 路径「我的 → 设置 → 外观 → 主界面 → 多栏布局」四档逐一选择；
每次选择后核对左右栏/菜单形态；宽度变化用 `wm size`，竖屏用宽高互换（`wm size 1200x1920`）。
density 固定 240（1.5x），因此 **px÷1.5=dp**。宽屏 `1920×1200` = **1280×800dp**。
「我的」页窗格区 = 窗口宽 − Rail（约 **81.3dp** = 80dp 栏 + 1px 分隔线，实测 0~122px），左右栏各 360dp、间距 24dp。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| auto @1280dp | 双栏 | 左菜单 360dp（122~662px）+ 24dp 间距 + 右空态「选择左侧项目」（`b2b2b_02_wide_my.png`） |
| auto @800dp（1200×1200） | 单栏 | 菜单单栏、无「选择左侧项目」（`b2b2b_45b_auto_800dp.png`） |
| auto @838dp（1257×1200） | 单栏 | 单栏菜单（`b2b2b_47b_auto_838dp.png`） |
| auto @840dp（1260×1200） | 双栏 | 右栏空态出现（`b2b2b_46b_auto_840dp.png`）；边界 838/840 精确成立 |
| landscape @1280×800 | 双栏 | `b2b2b_70_land_landscape_dual.png`；右栏空态 |
| landscape @800×1280（竖屏） | 单栏 | `b2b2b_69_land_portrait_single.png`；菜单单栏、Rail/底栏仍在 |
| off @1280×800 | 单栏 | `b2b2b_93_off_wide_single.png` |
| off @800×1280 / 360×640 | 单栏 | `b2b2b_94_off_portrait_single.png`、`b2b2b_155_off_narrow_single.png`、`b2b2b_157_off_narrow_my2.png`；off 不随宽高/方向切换（窄屏菜单无「选择左侧项目」） |
| always 边界（含 Rail） | 任务文字：≥744dp 双栏 | **实测：744dp 窗口（1116×1200）单栏**；822.7dp（1234px）、824dp（1236px）、824.7dp（1237px）均单栏；**825.3dp（1238px）起双栏**（1238/1239/1240px 均双栏）。根因：`resolveMultiPane` 先用**窗格可用宽**做最小尺寸校验（360+24+360=744dp），Rail 占约 81.3dp → 窗口阈值 = 744+81.3 = **825.3dp**（1237px/824.7dp 仍差约 0.3dp，实测为单栏）。见 P2-O1 |
| always @840dp（1260px） | 双栏 | `data/53_after_always2.xml` 同屏右栏外观页；`data/56_always_1260x1200.xml` |
| 重启保持 | 模式持久化 | off：`force-stop` 重启后宽屏仍单栏（`b2b2b_97_restart_off_my_single.png`），pref `multiPaneMode=off`；auto：重启后宽屏双栏（`b2b2b_112_restart_auto_my_dual.png`），pref `multiPaneMode=auto`。landscape/always 使用同一 `multiPaneMode` 键，未单独重启复核（如实声明） |
| 选择入口 | 外观→主界面 | 实际路径为「外观 → 主界面 → 多栏布局」（`b2b2b_08_wide_appearance_scrolled.png`；`data/09b_wide_appearance_main.xml`），不在「容器设置」组；文案/四档选项与参考版一致（`b2b2b_10_wide_mode_dialog.png`） |

- **P2-O1（阈值口径）**：任务文字「always 宽≥744dp 双栏」按**窗口宽**理解时不成立；
  744dp 是**窗格内容宽**（左右栏 360+24+360）。默认 `大屏导航形态=自动`（宽≥600dp 出 Rail）下，
  窗口需 ≥825.3dp 才双栏。代码注释（`multi_pane_layout.dart` 的 `resolveMultiPane`）与参考版
  `shouldUseListDetail` 的「先模式阈值、再看最小尺寸」口径一致；若验收要求「窗口 744dp 即双栏」，
  需把 Rail 宽度并入断点或改为窗格内无 Rail。**未在设备复核「大屏导航形态=关闭」时 744dp 的行为**
  （按实现 available=744dp 时应双栏，由单测覆盖），建议产品确认口径。

### 3.2 场景 2：双栏（PASS，P3-O1）

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 初始形态 | 左菜单 + 右空态 | 左菜单 360dp（122~662px），右栏 `选择左侧项目`（`b2b2b_02_wide_my.png`；`data/02_wide_my.xml`） |
| 点书源管理 | 右栏加载 | 右栏标题/空态「暂无书源」，左项粉底高亮（`b2b2b_03_wide_booksource.png`） |
| 点设置 | 右栏加载 | 右栏「设置」8 项（外观/高级/阅读界面/备份与恢复/缓存管理/书源管理/定时任务/关于），左项高亮（`b2b2b_06_wide_settings.png`） |
| 点阅读记录 | 右栏加载 | 右栏「已读 4 本 / 累计 1分钟43秒」+ 按书/按天 + 记录列表（`b2b2b_14_wide_readrecord.png`） |
| 重复点同项 | 不叠栈 | 书源管理连点 2 次后，**1 次系统返回即回空态**（`b2b2b_04_wide_after_dedupe_back.png`），证明栈深仍为 1 |
| 右栏逐级返回 | 外观→设置→空态 | 选中外观：返回 1 次回设置（`b2b2b_11_wide_back_to_settings.png`），再返回回空态（`b2b2b_13_wide_back_to_empty2.png`）；期间有一次返回被多栏模式对话框消费（属弹层关闭，非栈异常） |
| 底栏/Rail | 保持主壳 | 双栏时 Rail（80dp）与底栏（80dp）同时可见（基线形态，M1~M3 一致）；右栏内容 x≥698px，不遮挡 |
| 空态文案 | 「选择左侧项目」 | 文案与图标 `view_sidebar` 一致（`b2b2b_02`、`b2b2b_12`） |
| 左栏语义 | 可被无障碍读取 | **P3-O1**：uiautomator 语义树中双栏左菜单节点整体缺失（右栏节点正常），视觉/点击均正常；是否影响 TalkBack 需无障碍专项确认 |

### 3.3 场景 3：单栏命名页（PASS）

**步骤**：off/1280×800 → 我的单栏 → 设置 → 外观 → 多栏布局选「关闭」→ 外观页转为 root 全屏 → 返回 → 设置 root 全屏 → 返回 → 我的单栏；再点设置验证 root 全屏。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 双栏→单栏命名页 | 命名栈顶转 root 全屏 | 选「关闭」后外观页立即 root 全屏：左上返回箭头（15~69px）、无 Rail（无「展开侧栏/搜索/书架分组」）、无底栏（无 5 个 Tab 语义）（`b2b2b_35_off_transition.png`） |
| 单栏点设置 | root 全屏、无底栏/侧栏 | 设置页内容 x=24~1896px，无 Rail/底栏节点（`b2b2b_38_off_settings_root.png`） |
| 返回 | 回 My，不进入页签内 | 返回后 My 单栏菜单恢复，Rail/底栏恢复（`b2b2b_39_off_back_my.png`）；页面不在 PageView 页签内 |
| 模式持久化 | 关闭重启仍单栏 | `b2b2b_97_restart_off_my_single.png`（P2-O1 同批） |

### 3.4 场景 4：匿名编辑保留（PASS，P3-O2）

**步骤**：双栏（1280×800）→ 我的 → 书源管理 → 右上「更多选项」→「新建书源」→ 关闭帮助浮层 →
在「源名称（sourceName）」输入 `QA_ANON_KEEP` → 缩到 800×800dp → 横滑/截图/返回 → 放大回 1280×800。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 匿名路由入栈 | 编辑页在右栏（nested、无名路由） | 右栏「新建书源」表单，底部底栏仍可见（双栏态）（`b2b2b_74_source_editor_dual.png`、`b2b2b_75_source_editor_form.png`） |
| 输入保留 | 名称字段内容保留 | 字段显示 `QA_ANON_KEEP`（`b2b2b_76_source_name_input.png`） |
| 缩到单栏 | 编辑页全屏保留 | 800×800dp：内容 x=0~1200px，无 Rail/底栏节点；表单与输入保留（`b2b2b_77_anon_single_fullscreen.png`） |
| 输入不丢 | `QA_ANON_KEEP` | 语义树 `QA_ANON_KEEP (0,391,1200,451)`（`data/77_anon_single_fullscreen.xml`） |
| PageView 不可横滑 | 横滑不切页 | 左→右 300ms 滑动后仍为编辑页、输入不变（`b2b2b_78_anon_after_swipe.png`） |
| 放大回双栏 | 右栏编辑页 + 输入保留 | 1920×1200：Rail/底栏恢复，右栏编辑页与 `QA_ANON_KEEP` 保留（`b2b2b_79_anon_back_dual.png`） |
| 返回恢复 My | 退出匿名栈 | 第 1 次系统返回被输入焦点吞掉；第 2 次回右栏书源列表；第 3 次回空态（`b2b2b_80_anon_back_my.png`、`data/81_back2.xml`、`data/82_back3.xml`）。UI 左上返回即时；焦点吞返回为既有模式（P3-O2） |

### 3.5 场景 5：root 阅读 / 搜索（PASS，P3-O2）

**准备**：向设备推送 272B 本地 TXT（`qa_b2b2b_book.txt`）→ 书架「添加本地」导入 → 阅读若干页形成记录；
验收后删除书籍/记录/文件。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 双栏：阅读记录打开书 | 阅读器 root 全屏 | 右栏阅读记录 → 点 `qa_b2b2b_book` → 阅读器全屏（语义仅正文 0~1920×1200，无 Rail/底栏）（`b2b2b_28_wide_reader_root.png`） |
| 双栏：返回 | 回记录页、右栏栈不变 | 返回后右栏仍为阅读记录（已读 4 本/列表），Rail/底栏恢复（`b2b2b_29_wide_reader_back.png`） |
| 双栏：无书搜索 | root 搜索页 | 记录 `qa_book`（书架已无该书）→ root 搜索页，查询词 `qa_book`、空态「未找到相关书籍」（`b2b2b_15_wide_open_from_record.png`）；UI 返回回记录（`b2b2b_17_wide_back_ui.png`） |
| 单栏：阅读记录 | root 全屏 | 800×800dp：阅读记录全屏，无 Rail/底栏（`b2b2b_108_single_readrecord.png`） |
| 单栏：打开书 | 阅读器全屏 root | 阅读器全屏（`b2b2b_109_single_reader.png`） |
| 单栏：返回链 | 阅读器→记录→My | 返回记录页仍全屏（`b2b2b_110_single_back_record.png`）；再返回 My 单栏菜单、Rail/底栏恢复（`b2b2b_111_single_back_my.png`） |
| 缓存管理 | 列表 → 打开书 root 全屏 | 「缓存管理」右栏「离线缓存」列出 `qa_b2b2b_book / 本地书籍`（`b2b2b_125_offline_cache3.png`）；点开阅读器全屏（`b2b2b_126_cache_open_book.png`）；返回缓存页、右栏栈不变（`b2b2b_127_back_to_cache.png`） |
| 系统返回 | — | 搜索页/编辑页输入聚焦时系统返回需 2~3 次（首次被焦点吞掉）；左上 UI 返回 1 次即生效（P3-O2，既有字典页同类现象） |

### 3.6 场景 6：横竖屏 / 宽度（PASS，P2-O2）

**方法**：任务允许用 `wm size` 互换宽高模拟旋转（MuMu 覆盖尺寸下 `settings put system user_rotation`
不改变应用窗口）；应用判定基于 `MediaQuery` 窗口宽高，布局路径与旋转一致。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| auto 横屏→竖屏 | 双栏→单栏 | 1280×800 双栏 → 1200×1920（800×1280dp）单栏菜单（`b2b2b_104_auto_portrait_single.png`） |
| auto 竖屏→横屏 | 单栏→双栏 | 回 1920×1200 → 双栏空态（`b2b2b_105_auto_landscape_dual.png`） |
| landscape 竖屏 | 单栏 | 800×1280dp → 单栏菜单（`b2b2b_69_land_portrait_single.png`） |
| landscape 横屏 | 双栏 | 1280×800dp → 双栏（`b2b2b_70_land_landscape_dual.png`） |
| off | 任何方向不切换 | 1280×800、800×1280、360×640 均单栏（`b2b2b_93_off_wide_single.png`、`b2b2b_94_off_portrait_single.png`、`b2b2b_95_off_wide_single2.png`、`b2b2b_155_off_narrow_single.png`、`b2b2b_157_off_narrow_my2.png`） |
| 双栏↔双栏宽度变化 | 右栏栈保留 | 设置页右栏 → 1280dp→1000dp（1500×1200）→ 回 1280dp：设置页始终在右栏，左项仍高亮（`b2b2b_145_dual_1000dp_keep.png`、`b2b2b_146_dual_back_1280_keep.png`） |
| 命名页跨单栏 | 「双栏栈保留」 | 1280dp 双栏设置页 → 800×1280 竖屏单栏：设置转 root 全屏（`b2b2b_84_rotate_portrait_settings.png`）→ 回 1280×800：仍停留 root 设置页（**未回双栏**，`b2b2b_85_rotate_back_dual_settings.png`）→ 返回后 My 为双栏空态（右栏栈未恢复，`b2b2b_86_rotate_back_then_back.png`）。见 P2-O2 |
| 匿名页跨单栏 | 栈保留 | 场景 4：缩到 800dp 再放大，编辑页与输入完整保留（`b2b2b_77`→`b2b2b_79`） |

- **P2-O2（命名页跨单栏）**：命名路由（设置/外观等）在「双栏→单栏」时按 `_enterSinglePane`
  转为 root push，nested 栈被清空；回宽屏时 `_enterDualPane` 只能恢复空态，故**命名页右栏栈不保留**，
  用户需返回一次才见双栏 My。匿名路由则按设计保留。若「双栏栈保留」包含命名页，需改为
  单栏期间保留 nested 栈或按名重建回填；若仅指双栏↔双栏宽度变化，则本项已通过（上一行）。

### 3.7 场景 7：回归（PASS）

| 子项 | 实际 / 证据 |
|---|---|
| My M1~M3 | 分组/入口完整（规则 5 项、服务与工具、其他 6 项）；误触 Web 服务开关后 M3 运行中动作行「复制地址 / 在浏览器中打开」位于同一分组容器内（`b2b2b_87b_state.png`）；关闭后恢复副题「用浏览器写源或看书」、动作行收起（`b2b2b_139_web_off2.png`） |
| 首页/页签导航 | 首页 Rail 点击、搜索入口、系统/UI 返回正常（`b2b2b_113_home.png`、`b2b2b_114_search.png`、`data/116_after_back.xml`） |
| 设置 | 设置主页、外观（含多栏布局）在根/双栏两种形态渲染正常（`b2b2b_06`、`b2b2b_07`、`b2b2b_38`） |
| 底栏/Rail | 双栏/单栏主壳均正常；单栏匿名全屏与 root 全屏时均隐藏（`b2b2b_38`、`b2b2b_77`）；恢复后回归（`b2b2b_39`、`b2b2b_79`） |
| 阅读/翻页 | 打开本地书阅读器，右点翻页 66.7%→100.0%，正文切换（`b2b2b_118_reader.png`、`b2b2b_119_reader_next.png`） |
| 返回键 | My 双栏逐级、单栏 root、阅读器 root 均可返回；输入聚焦页需多次（P3-O2） |
| 稳定性 | `logcat/session_final2.log` 16,847 行：`FATAL EXCEPTION`=**0**、`ANR in io.legado.flutter_legado`=**0**、`overflowed by`=**0**、`E/flutter`=**0**；`/sdcard/Download/legado/crash` 仅 2026-10-30 旧文件，无本次新崩溃 |
| 既有项 | 删除书籍后书架列表不即时刷新（重启后消失）— M3 已登记 P3，本次复现（`b2b2b_141_final_shelf.png` vs `b2b2b_142_final_after_restart.png`） |

### 3.8 场景 8：清理（PASS）

| 项 | 结果 / 证据 |
|---|---|
| wm size / density | `wm size reset` / `wm density reset` → **Physical 1080×1920 / 480**（`data/wm_final.txt`；原值 `data/wm_original.txt`） |
| 旋转设置 | `accelerometer_rotation=0`、`user_rotation=0`（与验收开始时一致，`data/rotation_orig.txt`） |
| 多栏布局 | `multiPaneMode=auto`（`FlutterSharedPreferences.xml`） |
| Web 服务 | 开关关闭、副题「用浏览器写源或看书」、宿主 `curl http://192.168.100.62:1122/` = **000**、无前台服务（`b2b2b_139_web_off2.png`） |
| 空书架 | DB `select count(*) from books` = **0**；重启后 UI「书架还空着…」（`b2b2b_142_final_after_restart.png`） |
| 阅读记录 | 删除本次 `qa_b2b2b_book` 记录后回到基线 3 本（qa_book / qa_m1_novel / qa_m3_book，1分43秒） |
| 版本保留 | `versionName=2.0.442 / versionCode=443`；设备 `base.apk` sha256 = 构建产物 sha256（`data/version_installed.txt`） |
| 测试文件 | `/sdcard/Download/qa_b2b2b_book.txt` 与 file_picker 缓存已删除；书架/记录无残留 `qa_b2b2b` |

## 四、问题与观察清单

| 编号 | 级别 | 描述 | 影响 / 建议 |
|---|---|---|---|
| P2-O1 | P2（口径确认） | always 模式在默认 Rail 下，窗口 744dp 为单栏，825.3dp 起才双栏（744dp 为窗格内容宽；Rail 约 81.3dp） | 不崩溃、不影响 auto/landscape/off。若验收要求「窗口 744dp 即双栏」，需把 Rail 宽度并入断点或关闭 Rail；否则建议验收文案改为「窗格宽 ≥744dp」。证据：`b2b2b_55_always_1116x1200.png`、`b2b2b_55_always_1237x1200.png`、`data/56_always_1238x1200.xml` |
| P2-O2 | P2（预期确认） | 命名页（设置/外观）跨「双栏→单栏」转 root 后，回宽屏仍停留 root 页；返回后 My 右栏为空态，命名页右栏栈不恢复；匿名页栈正常保留 | 若「双栏栈保留」包含命名页则未满足；建议产品确认。证据：`b2b2b_84`→`b2b2b_85`→`b2b2b_86`；双栏↔双栏宽度变化已保留（`b2b2b_145`/`146`） |
| P3-O1 | P3（无障碍观察） | 双栏左菜单在 uiautomator 语义树中整体缺失（右栏正常），视觉/点击正常 | 可能影响 TalkBack 逐项朗读；建议无障碍专项复核（Flutter semantics 合并策略或可访问性缺口） |
| P3-O2 | P3（既有交互） | 搜索框/编辑框聚焦时系统返回首次（个别需 2 次）被焦点吞掉；UI 左上返回即时 | M3 已登记同类字典页现象；本次在搜索页/书源编辑页复现。非本批引入，未计入阻塞 |
| P3-O3 | P3（既有） | 删除书籍后书架列表不即时刷新，重启后消失 | M3 已登记；本次清理时复现，DB 已为空 |

**未覆盖 / 声明**：
- always 在「大屏导航形态=关闭」（无 Rail）时窗口 744dp 是否双栏未实机复核（按实现应为双栏，`multi_pane_layout_test` 覆盖纯函数口径）。
- landscape 在 840dp 横屏的边界（宽度恰好 840dp 且宽>高）未单列实测；已覆盖 1280×800 双栏/800×1280 单栏。
- 「大屏导航形态」与「多栏布局」两个设置均使用 `tabletInterface` / `multiPaneMode` 独立键；本次未做两键交叉矩阵（如 tablet=off + multiPane=always）。
- 双栏左菜单语义缺失（P3-O1）未用 TalkBack 实测，仅以 uiautomator 语义树判定。
- 旋转采用 `wm size` 互换模拟（任务允许），未做物理传感器旋转。

## 五、证据与产物索引

| 类别 | 路径 |
|---|---|
| 构建日志 | `tmp_debug/device_acceptance_20261103_batch2b2b/logcat/build_release.log`、`install.log` |
| 会话日志 | `tmp_debug/device_acceptance_20261103_batch2b2b/logcat/session_all.log`、`session_final.log`、`session_final2.log` |
| 语义树/尺寸 | `tmp_debug/device_acceptance_20261103_batch2b2b/data/*.xml`（含 `02_wide_my.xml`、`56_always_1238x1200.xml`、`77_anon_single_fullscreen.xml`、`wm_original.txt`、`wm_final.txt`、`apk_sha256.txt`、`version_installed.txt`） |
| 截图 | `docs/materials_1108/b2b2b_*.png`（104 张） |
| 交互脚本 | `tmp_debug/device_acceptance_20261103_batch2b2b/scripts/dev.py`（截图/语义树/点击辅助，未改应用代码） |

---

编写：QA（设备验收子代理） · 2026-11-03
