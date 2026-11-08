# 批7a「净化链修复 + 高亮富样式编辑」设备验收报告

- 日期：2026-11-09
- 验收角色：主代理（设备只读验证，验收期间仅修复后重新构建安装）
- 代码基线：`95f3279a02`（含 P1-A/P1-B 回修）
- 应用版本：2.0.470+471
- APK SHA-256：`b28cd50d01636d78280bff30925c3240c0e7c5f69e247b69156c2ad6955d961b`
- 证据：`docs/materials_1109c/`（112 个文件，约 14MB）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 2.0.470（versionCode 471） |
| Rust | release + quickjs；FRB hash 51404204；源码指纹 `24d11eba…`；`.so` 于 06:37/06:39 重建 |
| 测试数据 | UTF-8 TXT 4 本：`batch7a_global`、`batch7a_global2`、`batch7a_replace`、`batch7a_reseg`；替换规则「批7a去广告」；高亮规则「批7a富样式」 |

## 二、总体结论

- 功能验收 16 项：**PASS 14 / BLOCKED 2（均以单元/Widget 测试覆盖并注明）**；**P1=2（验收中发现并修复后复验 PASS）**；**P2=0**；P3=4。
- FATAL/ANR/E.flutter/RenderFlex overflow/E AndroidRuntime/TabAlignment 均为 **0**。
- 7a 关闭条件满足：P1 全部关闭、无 P2、设备终态干净。

## 三、逐项结果

### A. 替换净化开关（书级/全局）

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 全局默认开 + 新书 null → 规则生效 | PASS | `39_reader.png` | 「全局广告正文」显示为「全局正文」，规则已应用 |
| A2 全局默认关 + 新书 null → 规则不生效 | PASS | `92_globaloff.png`、`96_globaloffbook.png` | 设置页关闭「默认启用替换净化」后导入新书，正文保留「广告新书正文」 |
| A3 全局关时首次点击书级开关 → 显式开启并立即生效 | PASS | `97_globalmenu.png`、`98_firstclick.png` | 菜单未勾选；点击后 toast「已开启替换规则」，正文变为「新书正文」（广告被删） |
| A4 活跃阅读菜单书级关/开 → 立即重载 | PASS | `67_newmenu.png`、`68_replaceoff_live.png`、`71_replaceon2.png` | 关闭后正文出现「廣告」；再开启后「广告」再次被删；无需切章 |
| A5 目录页切换使用替换规则 → 返回立即重载 | PASS | `103_tocmenu.png`、`104_tocon_reload.png` | 目录勾选开启后返回正文立即变为「再次出现。」（广告删除），不再需要重开书 |
| A6 书级开关优先于全局 | PASS（间接） | `104_tocon_reload.png` | 全局关时目录页开启书级开关即生效，证明显式值优先 |
| A7 简繁转换独立于替换开关 | BLOCKED（设备） | Rust 单测 `test_use_replace_rule_false_keeps_chinese_convert` | 本机未找到活跃 UI 的简繁入口（文A 为设置编码），设备未直接构造；Rust 测试断言关闭替换后 t2s 仍生效 |

### B. 重新分段

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 默认关：保留 4 段原始排版 | PASS | `72_reseg_off.png` | 第一/二/三段与长段各自独立 |
| B2 开启：短段合并、长段保持 | PASS | `73_reseg_on.png` | 前三段合并为一行，长度超过十字的长段独立 |
| B3 关闭：立即恢复原始分段 | PASS | `76_reseg_off3.png` | 三段重新分开，无切章/重开书 |
| B4 搜索 raw 路径不重分段 | BLOCKED（设备） | Rust 单测 `test_raw_search_path_does_not_re_segment` | 内容搜索原始路径的设备可见差异难以稳定构造，Rust 用例覆盖 |

### C. 高亮富样式

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 编辑面板新增控件 | PASS | `19_hledit.png`、`20_hlfill.png`、`22_hltoggles.png`、`24_wave.png` | 背景填充开关+色板、下划线开关+5 线型下拉+色板+0–10 宽度、删除线开关+色板，360dp 无红屏/溢出 |
| C2 预览实时联动 | PASS | `24_wave.png`、`28_strikeon.png` | 预览卡显示黄色填充、波浪下划线、删除线 |
| C3 保存与导出保真 | PASS | `30_hlsaved.png`、`HighlightRules.json` | 导出 `style` = `{"fill":4293970317,"textColor":4294630099,"underline":{"kind":"WAVY","color":0,"width":1.0},"strike":{"color":0}}`；uuid/order/applyToBody 保留 |
| C4 正文渲染 | PASS | `66_highlightrender.png`、`66_highlight_zoom.png` | 「測試」呈现矩形填充 + 波浪下划线 + 删除线；文字色随规则 |
| C5 未触碰宽度/未知键保真 | PASS（Widget/单测） | `highlight_rules_test.dart`、`highlight_rule_style_test.dart` | width=8/0 只改名不改写；`underline:false/数组` 不删除；未知键与 `distance` 保留；release 包不可 run-as，未做设备 DB 取证 |
| C6 宽度滑块拖拽 | PASS（控件显示）/ 工具受限 | `26_width2.png` | adb 横向拖动未改变数值（输入注入问题，非应用崩溃）；Widget 测试覆盖 3.5 写入与 0/8 保真 |

### D. 回归与稳定性

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| D1 规则页/设置/目录/阅读器 | PASS | `10_replace.png`、`18_highlight.png`、`48_toc4.png`、`88_settings.png` | 页面进出、列表、空态、导出均正常 |
| D2 菜单新旧项 | PASS | `67_newmenu.png` | 「使用替换规则」「重新分段」「管理替换规则」共存；管理项仍可进入规则页 |
| D3 稳定性 | PASS | `logcat_7a.txt`（7,268 行） | FATAL=0、ANR=0、E/flutter=0、overflow=0、E AndroidRuntime=0、TabAlignment=0 |
| D4 设备终态 | PASS | `106_clean.png` | `pm clear` 后空书架，设置恢复默认，应用可启动 |

## 四、P1 问题与回修（验收中发现）

### P1-A 目录页切换「使用替换规则」后正文不重载

- **现象**：目录菜单取消/勾选后返回阅读器，正文仍按旧规则显示；彻底退出重开书才变化。
- **根因**：`toc_screen._updateReadConfigField` 落库后立即 `updateCurrentBook(updated)`，阅读器 `didPopNext` 的 fresh/latest 对比因此相同，判定「无变化」跳过重载（配置已落盘，仅自动重载缺失）。
- **回修**：`95f3279a02` — 目录页写完 `useReplaceRule`/`reSegment` 且页面仍 mounted 时直接 `await reloadChapterContent()`；mounted=false 分支保留差异对比兜底。补「写后已同步快照仍必须重载」用例。
- **复验**：`104_tocon_reload.png` PASS（目录开启后返回立即去掉「广告」）。

### P1-B 活跃阅读菜单缺少书级「使用替换规则」「重新分段」开关

- **现象**：阅读器 3-dot 菜单只有「替换规则」→打开管理页，无书级开关；`reader_top_bar.dart` 中已有勾选项但该组件全仓无实例化点（死实现），导致重新分段无用户入口。
- **回修**：`fd035af736` — 活跃 `reader_menu_panel.dart` 增加两个 `CheckedPopupMenuItem`：使用替换规则（按生效值勾选/取反）、重新分段（写 `readConfig.reSegment` 并重载）；原「替换规则」改名「管理替换规则」；死顶栏补保留说明。补 9 个 widget 用例。
- **复验**：`67_newmenu.png`、`68_replaceoff_live.png`、`71_replaceon2.png`、`73_reseg_on.png`、`76_reseg_off3.png` 均 PASS。

## 五、P3（观察/登记，不阻塞）

1. `reader_top_bar.dart` 仍为无实例化点的旧实现，已加注释保留，后续可删除或合并；新功能不应继续堆叠。
2. 简繁转换独立性与搜索 raw 路径未做设备直接验证，由 Rust 单测覆盖；活跃阅读设置中未找到简繁转换入口（文A 为设置编码），入口可见性另登记。
3. adb 横向拖动高亮宽度滑块未生效（注入手势被外层滚动/滑块命中问题），控件显示与 Widget 测试正常；设备未做宽度 8/0 的 DB 取证（release 不可 run-as）。
4. 高亮文字色与填充色均为主题色板可选组合，本次选择的浅粉字+黄色底对比度偏低，属用户可选组合而非渲染缺陷。

## 六、设备终态

- 应用 2.0.470+471 已安装，`pm clear` 后空书架、默认设置、可正常启动（`106_clean.png`）。
- 测试书籍/规则/导出文件未保留在应用内；`/sdcard/Download` 测试 TXT 保留供后续复验。
- 屏幕 1080x1920 / 480dpi，竖屏。

## 七、门禁（代码基线）

- flutter analyze 0；flutter test **4923 通过 + 1 skipped**（P1-B 修复后）。
- cargo fmt/clippy 0；`cargo test -p legado-ffi` **689 通过/21 ignored**；quickjs **762 通过/42 ignored**。
- 独立审查两轮 + 定向复核：P1/P2 全部关闭；无未决 P1/P2。

---

编写：ZCode 主代理 ｜ 2026-11-09
