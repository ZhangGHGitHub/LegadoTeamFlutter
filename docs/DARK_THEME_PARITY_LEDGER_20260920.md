# 深色主题一比一对账台账（DARK THEME PARITY LEDGER）

> 建账日期：2026-09-19（台账编号 20260920） ｜ 规范：[SCREEN_1TO1_PARITY_SPEC_20260914.md](SCREEN_1TO1_PARITY_SPEC_20260914.md)（§一.3 配色/明暗主题纳入一比一）
> 屏清单与批次划分沿用 [SCREEN_1TO1_PARITY_LEDGER_20260914.md](SCREEN_1TO1_PARITY_LEDGER_20260914.md) 的 43 屏（批 1×16 + 批 2×10 + 批 3×11 + 批 4×6）。
> 口径：视觉一比一（2026-09-14 修订）——深色态以参考版（io.legato.kazusa）实机深色截图为准；实现层 Material Design 3。
> 本轮范围：台账建立 + 静态审计（不依赖参考截图的客观缺陷盘点）。**未改任何 UI 代码；未使用设备/模拟器（截图比对留第二批）。**
> 状态图例：⬜ 未开工 ｜ 🔄 审计/比对中 ｜ ✅ 闭环
> 分级定义：**客观问题**=深色下必然异常（与主题无关的固定浅色/固定深色）；**疑似问题**=深色下可能异常或观感存疑（依赖参考截图裁决）；**已登记例外**=有 parity 量化依据/功能语义的硬编码（注释锚点齐全，不改）。

---

## 一、深色参考素材盘点（结论：部分 → **优先 7 屏已补采 2026-09-20**）

**补采轮（2026-09-20，MuMu Test `192.168.1.19:5555`，参考版 `io.legato.kazusa`）**：优先 7 屏深色参考已采并入 `docs/parity_shots/ref_dark_20260920/`（8 图 + 8 dump + manifest.json）——01 深色切换凭证（背景 lum≈49）、3-4 外观（lum≈70）、3-5 主题（lum≈28）、1-8 详情（lum≈28）、1-10 阅读正文（lum=0）、1-11 阅读菜单（顶栏≈8/底栏≈24）、1-13 内容搜索（lum≈19）、2-8 书源编辑器 QR。每屏均过独有元素断言 + 像素 DARK 判定；失败屏未落盘、卡点如实登记（「黑白」主题卡在该构建点击不选中 → 改走「主题模式=深色」，标 done_partial）。**其余 36 屏深色参考仍缺**。
**本轮两个需裁决的发现**：① **2-8 形态差异**：kazusa 的二维码入口是**全屏扫描器**（标题+图库按钮+取景框），我方 `source_edit_screen_dialogs.part.dart` 为**嵌入式 QrPainter/QrImageView 对话框**——按「视觉基准=参考版」口径，我方形态是否需改为全屏扫描器待裁决；② **3-5 主题卡名称集合不一致**：kazusa 12 卡与内置 12 套仅少数同名（柠檬/八月/透明等），**不可按名称做 1:1 映射**；`ref_batch3/theme_colors_ref.json` 的 fail_all 应改判为「网格可达、颜色可采，但名称集合不一致」。

（历史）屏级深色实机截图此前仅 1 张：

| 类别 | 结论 | 证据 |
|---|---|---|
| 屏级深色实机截图（参考侧） | **仅 1 张** | `docs/parity_shots/ref_batch3/04_appearance_dark.png`（设置·外观页，灰度均值 36.2，0916 夜采）；唯一配对我方对照+差分：`docs/parity_shots/ours_2.0.266/04_appearance_dark.png`（均值 52.3，0914 台账 3-4 行已记） |
| 源码级暗色调色板 | **齐全（2 套）** | `app/src/main/assets/defaultData/themeConfig.json`：4 套主题中 2 套暗色——「黑白」套（primary #303030 / accent #E0E0E0 / bg #424242 / bottom #424242，`isNightTheme=true`，**暗色对齐锚点**）、「A屏黑」套（全 #000000 底 + 白字，OLED） |
| 参考配色量化文件 | **不含 dark scheme** | `docs/parity_shots/ref_batch3/theme_colors_ref.json` 属批 3 阶段 D（2026-09-16），`status="fail_all"`（参考版 12 内置主题卡网格不存在，rgb 全 null），仅浅色 12 卡量化 |
| 我方深色基线图 | 非参考侧，不计 | `docs/parity_shots/baseline_flutter/15_dark_mode.png` 属我方归档 |

**结论**：深色参考素材 = **部分**。屏级深色实机截图仅「设置·外观」1 屏（43 屏的 1/43），其余 42 屏深色参考须补采（外部输入，见 §五）；源码级 2 套暗色调色板可作为配色裁决依据先行使用。

## 二、我方深色实现现状（摸底结论：机制齐全）

| 维度 | 现状 | 证据 |
|---|---|---|
| MaterialApp 级 darkTheme | **存在**，与 theme 对称构建 | `lib/app.dart:242`（darkTheme 构建，含壁纸透明 Scaffold 分支）/ `app.dart:271`（`darkTheme: darkTheme` 挂载） |
| 主题切换机制 | **三态齐全且持久化**：system（默认）/ light / dark，`ThemeMode` 驱动 `MaterialApp.themeMode` 全局实时切换 | `lib/src/providers/theme/theme_notifier.dart`（`setThemeMode` 持久化；`toggleDayNight` 写明确 light/dark，对齐原版 "1"日/"2"夜）；`theme_state.dart`（`@Default(ThemeMode.system)`） |
| 暗色 ColorScheme 来源（三源叠加） | ① **md3DarkScheme**：13 套调色板**全部含完整暗色半套**（逐 role 47 个 M3 tonal role，与亮色对称，逐一核对无误；生成器 `tool/gen_md3_colors.py` 维护，来源 HapeLee 参考仓库 values-night/colors.xml）② **自定义 Night 四色**（primary/accent/background/bottomBackground 非 null 时按「自定义>内置」覆盖）③ **参数化引擎/壁纸取色**（`buildParameterizedRoles(..., amoledDark)` / `DynamicColorBuilder` dark 取 `darkDynamic?.primary/tertiary`） | `lib/src/theme/md3_colors.dart`（13 套 dark 半套；`md3DarkScheme` line 1579 起）；`lib/src/theme/app_theme.dart`（`AppTheme.palette(brightness, ...)` brightness==dark 走 `md3DarkScheme`；`_onColor` 按 `estimateBrightnessForColor` 动态算前景） |
| 暗色对齐锚点 | 参考版「黑白」套：primary #303030 / accent #E0E0E0 / background #424242 / bottom #424242；我方 def 暗色锚点 surface 0xFF424242 / onSurface 0xFFEDE6E4 与之对应（0914 台账阶段 D 2.0.270 已闭环 def 套） | `themeConfig.json`（isNightTheme=true）；`md3_colors.dart` def dark（line 1452-1500） |
| 遗留 iOS 槽位体系 | **基本孤儿化**：`app_colors.dart` 97 处 Color(0x) 全为槽位定义（light*/dark* 成对），外部引用仅 1 处且合法（`settings_screen.dart:168-170` `AppColors.iosGreenDark/Light` 按 `theme.brightness` 分支）；`lightColorScheme`/`darkColorScheme` 两个 const ColorScheme **零引用** | `lib/src/theme/app_colors.dart`；全库 grep `AppColors.` 仅 11 行（10 行是同名扩展 `AppColorsExt`，与槽位体系无关） |
| 其他 ThemeData 构造 | `lib/main.dart:124` `theme: ThemeData.dark()` 为 **Rust 引擎初始化失败错误页**（非主应用主题，非 43 屏），合理保留 | `lib/main.dart:124` |

**结论**：主题切换/暗色 ColorScheme/调色板暗色覆盖三层机制齐全且干净，**43 屏主路径无「漏建 darkTheme」类结构性缺口**；问题集中在屏幕级硬编码色（见 §三）。

## 三、静态审计结果（flutter_legado/lib 全量 grep + 逐条定性）

扫描模式：`Colors.white/black 直赋`、`Color(0x...) 硬编码`、`Color.fromARGB/fromRGBO`、`ColorScheme.light()/dark()` 写死构造、`Brightness.light/dark` 写死、硬编码色 `.withOpacity/.withValues` 叠加、`ThemeData.light()/dark()`。

- `Color.fromARGB/fromRGBO`：**0 处**
- `ColorScheme.light()/ColorScheme.dark()` 写死：**0 处**（app_colors.dart 用 `ColorScheme(...)` 直接构造，属孤儿槽位体系）
- `Brightness.light/dark`：全部为**主题构建合法位**（md3_colors/app_theme/app.dart/app_colors）或 **运行时分支**（`Theme.of(context).brightness == Brightness.dark` / `estimateBrightnessForColor`），无写死
- 硬编码色 withOpacity/withValues 叠加：仅 2 处（见下 §三.C 疑似 + §三.E 合法）

### A. 客观问题（深色下必然异常）

| # | 位置 | 屏 | 描述 | 分级 |
|---|---|---|---|---|
| A1 | `lib/src/widgets/manga/manga_config_sheet.dart:103/114/127/324/369/387/402/427/432` + `:379` | 漫画/漫剧设置弹层（**不在 43 屏清单，漫画体系单独登记**） | 整张 sheet 固定 iOS 浅色调色板：分组背景 #F2F2F7、卡片 `Colors.white`、主字 #1C1C1E、次字 #8E8E93、分割线 #E5E5EA、选中底 #C7C7CC——深色下必然「白卡+浅底+深字」观感全异 | 客观（P1，方案=scheme 化，无需参考截图） |

**43 屏主路径内：无客观必然异常。** 43 屏内全部硬编码点均为已登记例外（§三.B）、疑似（§三.C）或自成深色体系/功能色（§三.D/E）。

### B. 已登记例外（有 parity 量化依据或功能语义，注释锚点齐全——本轮不改，深色形态待参考截图裁决）

| # | 位置 | 屏 | 描述 | 深色裁决依赖 |
|---|---|---|---|---|
| B1 | `lib/src/screens/book_info_screen.dart:147-148` | 1-8 书籍详情 | 「阅读」FAB 绿底 #AFF2C4 / 深绿字 #0B5130（PARITY C1 D3，ref 08 量化 (175,242,196)/(11,81,48)） | ref 08 深色态（补采后裁决保持/改调） |
| B2 | `lib/src/screens/book_info_screen_builders.part.dart:1008` | 1-8 书籍详情 | 状态词「已读/未读」绿色 #4CAF50（ref 08 状态词绿调，台账 0917 反馈批七 H4） | 同 B1 |
| B3 | `lib/src/screens/search_content_screen.dart:607`（+`:637` 选中白字） | 1-13 全文搜索 | 「仅本书」胶囊 #526070 深色实底+白字（ref 13 量化 (82,96,112)；该色本身偏深，深色态大概率保持） | ref 13 深色态确认 |
| B4 | `lib/src/screens/source_edit_screen_dialogs.part.dart:91-93`（QrPainter 黑/白）+ `:136`（QrImageView 白底） | 2-8 书源编辑器 | 二维码黑白 + 白底=扫码语义（UI_MD3_ALIGNMENT_PLAN B10 例外，注释锚点齐全） | 扫码白底惯例上应保留；仅需参考侧确认对话框形态 |

### C. 疑似问题（深色下可能异常/观感存疑）

| # | 位置 | 屏 | 描述 | 处理建议 |
|---|---|---|---|---|
| C1 | `lib/src/screens/replace_rules_screen.dart:101` | 2-9 替换净化编辑器 | 搜索框 `fillColor: Colors.white.withValues(alpha: 0.2)`：亮色下白 0.2 近隐形、深色下呈灰白填充，两态行为不一致，未走 scheme | 无需截图即可修：改 `colorScheme.surfaceContainerHighest`（Batch A） |
| C2 | `lib/src/screens/reader_screen.dart:511-517` | 1-10 阅读器正文 | 「全局页 X/Y」徽标 `Colors.black54` 底 + `Colors.white` 字：纯黑预设背景下徽标底近隐形、仅剩悬浮白字 | 无需截图可修（`surfaceContainerHighest`+`onSurface`）；或对照参考阅读器深色态裁决（Batch A 候选） |
| C3 | `lib/src/widgets/paragraph_layout_engine.dart:176-177` | 1-10 关联 | `ParagraphConfig` 默认 `backgroundColor=Colors.white` / `textColor=Colors.black`——调用方（`reader_page_view.dart:533`）恒以 state 派生色覆写，**死默认值**（代码异味，无功能影响） | 低优：删除默认参数或改 `Colors.transparent`（Batch A 顺手项） |
| C4 | `lib/src/screens/settings_screen.dart:168-170` | 3-3 设置主页 | 引用孤儿 iOS 槽位 `AppColors.iosGreenDark/Light`（按 `theme.brightness` 分支，视觉无异常，属槽位体系清理项） | 改 `colorScheme`（Batch A 顺手项，随 app_colors.dart 孤儿化清理） |

### D. 自成深色/黑底体系（非异常，不在 43 屏，单独登记不改）

| 位置 | 说明 |
|---|---|
| `lib/src/screens/reader_comic_screen.dart`（23 处 Color(0x) + 9 处 Colors.white/black：#1A1A1A 底/#2A2A2A 控件/#444444/#666666/#888888 字等） | 漫画阅读器自成黑底白控件体系（漫画恒黑底，对齐原版行为），深色下无异常 |
| `lib/src/screens/video_screen.dart`（7 处：Colors.black 底/白控件） | 视频页黑底体系，同上 |
| `lib/src/widgets/page_flip_widget.dart:537-713`（8 处）/ `widgets/reader/turn/painters/simulation_curl_painter.dart:11-32`（4 处）/ `widgets/reader/turn/painters/cover_page_painter.dart:134` | 翻页/卷曲阴影渐变色（功能装饰，不随主题） |
| `lib/src/providers/reader/reader_state.dart:72-76/172` + `widgets/reader/reader_settings_sheet.dart:78-93`（16 色） | 阅读器背景色板（白/护眼/深灰/黑等预设+自定义亮度分支），功能性配色，合法 |
| `lib/src/widgets/reader/text_selection_panel.dart:31-35` | 正文长按高亮色板（琥珀/绿/蓝/粉/橙，用户可选功能色），合法 |
| `lib/src/services/rust_api.dart:202-203` | 阅读配置注入 Rust 的背景色 hex（`isDark ? #1A1A1A : #FFFFFF` 分支），合法 |

### E. 合法位（核对无误，不动）

- `routes.dart:450`（modal barrier black54）/ `reader_settings_sheet.dart:880`（black54 scrim）/ `swipe_action.dart:113/118`（彩色滑动动作底白图标）/ `source_debug_screen.dart:293`（tonal chip 白 on 色，注释齐全）/ `bookshelf_screen.dart:421`（0x14 中性薄覆盖）/ `book_info_screen_builders.part.dart:818-819`（卡阴影半透明）/ `system_bar_service.dart:25/35-45/61-66`（状态/导航栏半透明黑）
- `app_theme.dart:199`（`_onColor` 返回白，合法）/ `app_navigation_bars.dart:176`（`Colors.black.withValues(alpha: isDark ? 0.2 : 0.1)` 已分支）/ `review_column.dart:31`、`reader_bottom_bar.dart:246-265`、`welcome_screen.dart:184`、`reader_screen.dart:97/164`、`theme_colors_notifier.dart:61`、`theme_config_screen.dart:1127`（均为运行时 brightness 分支/校验）
- `main.dart:124`（Rust 失败错误页 `ThemeData.dark()`，非主主题、非 43 屏）

## 四、43 屏 × 深色对账表

> 「深色参考素材」列：✅=已有参考侧深色实机截图；❌=待补采（外部输入）。
> 静态审计发现/客观问题/疑似问题：填「—」=该屏无命中。优先级：P0 客观异常 > P1 有疑似项的核心屏 > P2 有已登记例外/疑似的次核心屏 > P3 仅待深色截图比对的常规屏。批次=修复批次（A=无需参考截图 / B=须对照参考截图）。

### 第 1 批：高频核心（16 屏）

| # | 屏 | 深色参考素材 | 静态审计发现 | 客观问题 | 疑似问题 | 优先级 | 批次 |
|---|---|---|---|---|---|---|---|
| 1-1 | 底部导航（五页签） | ❌待补采 | —（`app_navigation_bars.dart:164/176` isDark 分支合法） | — | — | P3 | B |
| 1-2 | 首页页签 | ❌待补采 | — | — | — | P3 | B |
| 1-3 | 书架（含空态） | ❌待补采 | —（`bookshelf_screen.dart:421` 中性薄覆盖合法） | — | — | P3 | B |
| 1-4 | 书架溢出菜单 | ❌待补采 | — | — | — | P3 | B |
| 1-5 | 书架批量多选态 | ❌待补采 | — | — | — | P3 | B |
| 1-6 | 搜索 | ❌待补采 | — | — | — | P3 | B |
| 1-7 | 搜索结果页 | ❌待补采 | — | — | — | P3 | B |
| 1-8 | 书籍详情 | ❌待补采 | `book_info_screen.dart:147-148`（B1）；`book_info_screen_builders.part.dart:1008`（B2）；`builders:818-819` 阴影合法 | —（B1/B2 为已登记例外，非客观异常） | 绿 FAB/状态词绿深色形态存疑 | P2 | B（依赖 ref 08 深色） |
| 1-9 | 目录页 | ❌待补采 | — | — | — | P3 | B |
| 1-10 | 阅读器正文 | ❌待补采 | `reader_screen.dart:511-517`（C2）；`paragraph_layout_engine.dart:176-177`（C3 死默认）；`reader_page_view.dart:784-785` 亮度自适应合法 | — | C2 纯黑底徽标近隐形 | P2 | A（C2/C3 可无截图修；C2 亦可留 B 对照） |
| 1-11 | 阅读器菜单 | ❌待补采 | `reader_settings_sheet.dart:880` black54 合法 | — | — | P3 | B |
| 1-12 | 正文长按菜单 | ❌待补采 | `text_selection_panel.dart:31-35` 高亮色板合法 | — | — | P3 | B |
| 1-13 | 全文搜索 | ❌待补采 | `search_content_screen.dart:607/637`（B3，ref 13 量化） | — | 胶囊深色形态存疑（色本身偏深，大概率保持） | P2 | B（依赖 ref 13 深色） |
| 1-14 | 目录·书签页签 | ❌待补采 | — | — | — | P3 | B |
| 1-15 | 章节跳转 | ❌待补采 | — | — | — | P3 | B |
| 1-16 | 自动翻页 | ❌待补采 | — | — | — | P3 | B |

### 第 2 批：发现与源管理（10 屏）

| # | 屏 | 深色参考素材 | 静态审计发现 | 客观问题 | 疑似问题 | 优先级 | 批次 |
|---|---|---|---|---|---|---|---|
| 2-1 | 发现（分组 chips） | ❌待补采 | — | — | — | P3 | B |
| 2-2 | 发现溢出菜单 | ❌待补采 | — | — | — | P3 | B |
| 2-3 | 发现源二级页（chips） | ❌待补采 | — | — | — | P3 | B |
| 2-4 | 发现源二级页（下拉） | ❌待补采 | — | — | — | P3 | B |
| 2-5 | 发现分类书单 | ❌待补采 | — | — | — | P3 | B |
| 2-6 | 换源/书源 | ❌待补采 | — | — | — | P3 | B |
| 2-7 | 书源管理 | ❌待补采 | — | — | — | P3 | B |
| 2-8 | 书源编辑器 | ❌待补采 | `source_edit_screen_dialogs.part.dart:91-93/136`（B4，B10 扫码语义例外） | — | QR 对话框深色形态（白底惯例保留） | P2 | B（B4 例外仅需形态确认） |
| 2-9 | 替换净化编辑器 | ❌待补采 | `replace_rules_screen.dart:101`（C1） | — | C1 白 0.2 填充两态不一致 | P2 | A |
| 2-10 | RSS 源二级页/Web 服务 | ❌待补采 | — | — | — | P3 | B |

### 第 3 批：我的与设置（11 屏）

| # | 屏 | 深色参考素材 | 静态审计发现 | 客观问题 | 疑似问题 | 优先级 | 批次 |
|---|---|---|---|---|---|---|---|
| 3-1 | 我的 | ❌待补采 | — | — | — | P3 | B |
| 3-2 | 阅读记录 | ❌待补采 | — | — | — | P3 | B |
| 3-3 | 设置主页 | ❌待补采 | `settings_screen.dart:168-170`（C4，孤儿槽位引用） | — | C4 槽位体系清理（视觉无异常） | P3 | A（顺手项） |
| 3-4 | 设置·外观 | ✅ **ref_batch3/04_appearance_dark.png**（唯一屏级深色参考；配对 ours_2.0.266/04_appearance_dark.png 差分已记） | — | — | 既有差分（均值 36.2 vs 52.3）待 2.0.270 后复验深色态 | P1 | B |
| 3-5 | 主题设置（12 色卡） | ❌待补采（参考 12 卡网格量化 fail_all，`theme_colors_ref.json` 无 dark scheme） | — | — | 12 色卡深色形态 + def 套暗色锚点（#303030 系）核对 | P1 | B（须补采 12 卡深色 + def 暗色锚点复核） |
| 3-6 | 设置·备份与恢复 | ❌待补采 | — | — | — | P3 | B |
| 3-7 | 字体（Tt 入口） | ❌待补采 | — | — | — | P3 | B |
| 3-8 | 朗读 | ❌待补采 | — | — | — | P3 | B |
| 3-9 | 分组管理 | ❌待补采 | — | — | — | P3 | B |
| 3-10 | 定时任务 | ❌待补采 | — | — | — | P3 | B |
| 3-11 | 高亮标注列表 | ❌待补采 | — | — | — | P3 | B |

### 第 4 批：长尾深页（6 屏）

| # | 屏 | 深色参考素材 | 静态审计发现 | 客观问题 | 疑似问题 | 优先级 | 批次 |
|---|---|---|---|---|---|---|---|
| 4-1 | TXT 目录规则 | ❌待补采 | — | — | — | P3 | B |
| 4-2 | 字典规则 | ❌待补采 | — | — | — | P3 | B |
| 4-3 | 文件管理 | ❌待补采 | — | — | — | P3 | B |
| 4-4 | 关于页 | ❌待补采 | — | — | — | P3 | B |
| 4-5 | 首页模块管理二级页 | ❌待补采（用户裁决暂不实施，维持） | — | — | — | P3 | B（随裁决） |
| 4-6 | 超低频深页 | ❌待补采 | — | — | — | P3 | B |

### 43 屏之外单独登记（漫画/漫剧体系 + 全局）

| 位置 | 屏/域 | 分级 | 说明 |
|---|---|---|---|
| `lib/src/widgets/manga/manga_config_sheet.dart:103-432` | 漫画设置弹层（manga 域） | **客观 A1**（P1，Batch A 可修） | 整 sheet 固定 iOS 浅色板，深色下必然异常；scheme 化无需参考截图 |
| `lib/src/screens/reader_comic_screen.dart` / `lib/src/screens/video_screen.dart` / 翻页 3 个 painter / 阅读背景色板 / 高亮色板 / `rust_api.dart:202-203` | 漫画/视频/翻页/阅读配色域 | 自成黑底体系/功能色（§三.D） | 不改；深色下无异常 |
| `lib/src/theme/app_colors.dart`（97 槽位 + 2 个 const ColorScheme 零引用） | 全局主题域 | 孤儿代码（§三.E/C4） | 建议第二批随 C4 一并清理或留档 |
| `lib/main.dart:124` | Rust 失败错误页 | 合理（`ThemeData.dark()` 兜底） | 不改 |

## 五、第二批修复建议切分

### Batch A：无需参考截图即可修（硬编码色 scheme 化 + 代码清理，本批可全量执行）

| # | 项 | 位置 | 改法 |
|---|---|---|---|
| A-1 | 【A1，客观 P1】漫画设置弹层 scheme 化 | `manga_config_sheet.dart` 9 处 Color(0x) + `:379` | 浅底板（F2F2F7/白卡/1C1C1E/8E8E93/E5E5EA/C7C7CC）→ `colorScheme.surfaceContainerHighest/surface/onSurface/onSurfaceVariant/outlineVariant/secondaryContainer` |
| A-2 | 【C1，P2】替换净化搜索框填充 | `replace_rules_screen.dart:101` | `Colors.white.withValues(alpha:0.2)` → `colorScheme.surfaceContainerHighest`（或 `outlineVariant`） |
| A-3 | 【C2，P2】阅读器全局页徽标 | `reader_screen.dart:511-517` | black54+白字 → `colorScheme.surfaceContainerHighest`+`onSurface`（或留待 B 批对照参考阅读器深色态后裁决） |
| A-4 | 【C3，低优】段落排版死默认 | `paragraph_layout_engine.dart:176-177` | 删除默认参数或改 `Colors.transparent`（调用方恒覆写） |
| A-5 | 【C4，低优】孤儿 iOS 槽位清理 | `settings_screen.dart:168-170`（+ 视情况整个 `app_colors.dart`） | 改 `colorScheme.tertiary/error` 等 M3 槽位；`app_colors.dart` 孤儿化清理随主代理裁决 |

### Batch B：必须对照参考截图才能修（外部输入依赖）

| # | 项 | 依赖（外部输入清单） |
|---|---|---|
| B-1 | 43 屏全量深色实机比对（本台账 42 屏 ❌待补采 + 3-4 复验 + 3-5） | **参考版（io.legato.kazusa）实机深色截图补采**：①「黑白」套（#303030，isNightTheme）与「A屏黑」套（#000000）两套各一屏级全量（或至少 P1/P2 屏：1-8/1-10/1-11/1-13/2-8/3-4/3-5 七屏两套）②归档按规范 `docs/parity_shots/ref_dark_<YYYYMMDD>/` |
| B-2 | 【B1/B2】1-8 绿 FAB + 状态词绿深色形态裁决 | ref 08 深色截图 |
| B-3 | 【B3】1-13 「仅本书」胶囊深色形态确认 | ref 13 深色截图 |
| B-4 | 【B4】2-8 QR 对话框深色形态确认（扫码白底预期保留） | ref 09 深色截图 |
| B-5 | 3-5 主题设置 12 色卡深色态 + def 套暗色锚点（#303030/#E0E0E0/#424242 系）核对 | 参考 12 主题卡网格深色补采（现 `theme_colors_ref.json` fail_all 无 dark scheme） |
| B-6 | 3-4 既有深色差分（36.2 vs 52.3）2.0.270 后复验 | 复用 ref_batch3/04_appearance_dark.png（已有）+ 我方重采 |

**外部输入清单（汇总）**：①参考版实机深色截图（黑白套 + A屏黑套，优先级屏见 B-1；归档 ref_dark_<YYYYMMDD>/）②参考版 12 主题卡网格深色补采（解决 fail_all）③（可选）参考版漫画/视频域深色行为确认（若漫画域纳入一比一范围）。

## 六、执行记录

- **2026-09-20 用户裁决（形态类）**：**深色/形态差异一律以参考版为准**。据此：A1 扫码改**全屏扫描器**形态；**A2 主题页同步风格版**——布局（横滑一行）+ **名称/顺序/颜色一并对齐**（需先采参考 12 卡名称与颜色事实）；A3 先**重采参考版默认主题的干净基线**（现采集疑被其柠檬强调色污染）再对齐页面 IA；A4 入口按参考版语义（**证据不足时先报告不猜**，避免把"点书开读"弄反）；A5 菜单键集收敛到参考版 5 键（字号/亮度按参考版位置仍在阅读器内）；A6 输入盒先复核是否采集污染再对齐。另：**深色剩余 36 屏参考补采继续推进**（不需用户输入）。
- **2026-09-20 用户裁决（代码级缓议）**：**A-4 选②**——`ParagraphConfig` 死默认改为必填（编译期拦住漏传），单独立小批 + code-reviewer 审查（承重区）；**A-5 选"整体删除"**——先全仓确认无动态引用（含字符串取色）→ 在用的 1 处消费方一并**改 MD3 风格** → 跑全量测试 → 删除 `app_colors.dart`；**N6 选②**——保留「字体（Tt 入口）」页但**先收起来**（隐藏入口/降存在感）并正式登记为**授权偏离**（原口径"勿删勿改待裁决"作废）。
- **2026-09-20 用户裁决（设备与排期）**：设备口径定案——**MuMu「Test测试」实例统一承担自测与用户验收**，雷电不再修复、5554/5558 档位废弃（AGENTS.md 已改，提交 `c302191eb7`）。**可选排期两项（P1-1 项2 聚合下沉、P1-2 项3 逐项对齐评估）放在顺序最后做**。

- **2026-09-20 Batch B 前半完成**（我方采集 + 配对差分，证据 `docs/parity_shots/ours_dark_20260920/`，报告 `DARK_DELTA_20260920.md`）：我方深色 9/9 屏采集成功（MuMu Test；两次首跑失败为环境问题已补采，如实留痕），8 组配对量化完成。**必须改 1 项**：**M1 阅读器深色态正文背景为纯白**（参考纯黑，Δlum 213–255，8 屏中唯一方向性大色差）——已另行派修（阅读器为承重区，按谨慎口径：仅改深色态背景默认，不动排版/翻页管线）。**待裁决 6 项**：A1 扫码全屏扫描器 vs 页内；A2 主题横滑行 vs 网格 + 主题集映射方式；A3 04 页面 IA 与暖调基准（注意参考暖调疑为其 build 柠檬强调色残留）；A4 1-8 入口长按 vs 单击；A5 1-11 菜单键集是否收敛（参考 5 键、我方为超集）；A6 1-13 输入盒/仅本书细节（低优）。01/13 整体无需改。本轮 0 次崩溃弹窗（与 M2 误报修复待合验）。

## 六、执行记录

- **2026-09-20 Batch A 完成**（提交 `c1616a1fc3`）：A-1 漫画弹层 10 色 scheme 化（把手槽位偏离台账原议 secondaryContainer→outlineVariant，理由：着色容器语义不合中性把手；伴随 _card 包 transparency Material 的结构性修复，零像素变化）；A-2 替换规则搜索框 fillColor 统一 surfaceContainerHighest；A-3 阅读器徽标 onSurfaceVariant+surface（亮色等效论证 + 暗色观感留 Batch B 复核三要点已标注）。新增 manga_config_sheet_test.dart 2 项；flutter analyze 0；flutter test 1508 全过。A-4（排版引擎死默认，承重区）与 A-5（app_colors.dart 整体处置）按红线缓议，需单独 review/裁决。

- 2026-09-19 建账：静态审计全量 grep（6 类模式）+ 逐条定性完成；未改代码、未用设备；台账首版发布。
- 下一步：Batch A 五项可独立排期修复（其中 A-1 为唯一客观 P1）；Batch B 阻塞于外部输入清单①②。

- **2026-09-21 队列③ 闭环（提交 `14752aba63`，版本 2.0.302+303）**：**A-4** ParagraphConfig 死默认改必填（28 构造点核对、25 处测试补显式色、行为不变；漏传颜色=编译错误）；**A-5** `app_colors.dart` 整体删除（全仓无引用验证后；唯一消费方设置页 Web 服务卡强调色 → `colorScheme.primary`，**有意可见变更**，随 0914 台账 3-1 屏补采复验）；**N6** 字体入口收起（页面/路由保留，阅读器面板可进）。已过 code-reviewer（结论：可提交，无 P0/P1）。门禁：analyze 0 / test 1584 全过（删除前后各一轮）。遗留 P3：`settings_screen.dart` 变量名 green→accent、失效文档（design_system/UI_MD3_* 提到 AppColors 的三处）同步。

- **2026-09-21 用户裁决：A4 采用「B 方案（对齐）」**，实施形态取**重构版模式**（详情页 + 立即自动开读）。依据（三处源码核实）：原版 `startActivityForBook`（`style1/books/BooksFragment.kt:302`、`style2/BookshelfFragment2.kt:310`）与参考版 Compose `onClick→onOpenBookshelfBook`（`BookItem.kt:91` / `MainScreen.kt:556-568` / `MainNavGraph.kt:338-351` 无未读判断）**均为单击直开书**；重构版参考源 `_openBook` 为 `BookInfoPage(openReaderImmediately: true)`（`bookshelf_style1_page.dart:568-573`）——**三方一致，仅我方"未读书→详情页"偏离**。落地要求：① 去掉 `bookshelf_screen.dart:724-727` 未读特例（或改为详情页+自动开读）；② 阅读器**零进度兜底**（现无该处理，属承重区）→ 必须 code-reviewer + 设备验证；③ 实机验证点：未读书单击直达正文首章、返回后进度写回、长按仍进详情。
