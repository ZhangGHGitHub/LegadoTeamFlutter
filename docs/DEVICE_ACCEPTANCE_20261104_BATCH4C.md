# 批4c「选择菜单配置」设备验收报告

- 验收日期：2026-11-04
- 被测版本：2.0.455+456（versionCode 456，versionName 2.0.455）
- 代码基线：`4398a352d8`（`chore: 批4c 收尾（2.0.455+456 双日志与计划登记）`），工作区无源码改动（仅 `.zcode/` 未跟踪）
- 验收对象：正文选择菜单配置（浮条/底部面板分区渲染、三组配置 Sheet、多行展示、图标开关、窄屏与屏底可达性、动作回归）
- 验收人：QA 子代理（只测不改代码）
- 结论：**PASS（附 1 项 P2 缺陷待修、3 项 P3/观察）**

---

## 一、结论摘要

| 分组 | 项数 | PASS | FAIL | BLOCKED |
|---|---|---|---|---|
| A 入口与默认（A1–A3） | 3 | 3 | 0 | 0 |
| B 配置行为（B1–B6） | 6 | 6 | 0 | 0 |
| C 窄屏与屏底（C1–C2） | 2 | 2 | 0 | 0 |
| D 动作回归（D1–D2） | 2 | 2 | 0 | 0 |
| E 回归与稳定性（E1–E2） | 2 | 2 | 0 | 0 |
| F 清理（F1） | 1 | 1 | 0 | 0 |
| **合计** | **16** | **16** | **0** | **0** |

缺陷分级：**P1 = 0**；**P2 = 1**（浮条「管理」进入配置页后「保存」抛异常、保存失效）；**P3 = 2**（高亮配色行贴屏幕底缘被裁切；高亮保存后未见底色渲染）+ 1 项环境残留（备份路径）。

> 说明：16 项全部达到验收标准，但 B6「保存后生效」在**浮条「管理」入口**下不可用（P2），需从底部面板「管理」或阅读设置→更多→选择菜单进入才能保存。该项按「功能可完成、入口部分失效」记为 PASS + P2，修复后建议复验该入口。

---

## 二、环境与构建

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，guest 直连，实测可连） |
| 设备伪装 | SM-G9900 / Android 15（SDK 35） |
| 分辨率/密度 | 1080x1920 / 480dpi（360x640dp）；窄屏用例临时切 720x1280 + 360dpi（=320x568dp），测试后已 reset |
| 构建 | `cd flutter_legado && flutter build apk --release`（Gradle assembleRelease 84.8s，产物 192.2MB） |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，201,502,532 bytes |
| **APK sha256** | `87fc6b8924f6656a393a91c9fad61e8b1de5db39f37f8a15334f38e8e54db5a4` |
| 安装 | `adb install -r`（Success），设备 versionName 2.0.455 / versionCode 456，lastUpdateTime 2026-11-04 11:39:44 |
| 测试书 | UTF-8 TXT（18,318 B，6 章），push 到 `/sdcard/Download/qa4c_book.txt` 后经「添加本地」导入 |
| 测试起点 | `pm clear io.legado.flutter_legado`（书架空、配置全默认） |

---

## 三、逐项结果

### A. 入口与默认

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 入口 | PASS | `22_settings_more_scrolled.png`、`11_longpress_default.png`、`37_panel_B1.png`、`18_reader_menu.png`、`19_reader_more_menu.png` | 阅读设置（顶栏「更多」→界面设置 / 底栏「设置」）→「更多」页有「选择菜单 / 一级 / 折叠 / 隐藏项、多行展示与图标」入口；长按正文浮条尾部固定「更多」[795,608–924,782] + 「管理选择菜单」[924,635–1044,755]；底部选择面板尾部固定「管理选择菜单」[912,1749–1032,1869]。**注**：阅读器顶栏「更多」下拉菜单（添加书签/高亮规则/替换规则/…）本身不含该入口，入口在设置面板「更多」页，与参考 `MoreConfigSheet.kt:452-455` 一致 |
| A2 360dp 默认 10 项 | PASS | `11_longpress_default.png`、`12_bar_scrolled.png`、`117_bar_default_360.png` | 默认 10 项浮条横向可滑（滑动后可见书签/高亮/字典/替换/编辑/全文搜索），「更多」「管理」始终固定可见可点、不随滚动移动且都在 1080 宽内 |
| A3 面板与配置页 | PASS | `13_more_panel.png`、`14_config_sheet.png`、`15_config_sheet_bottom.png`、`23_sheet_from_settings.png` | 「更多」打开底部选择面板；「管理」打开「编辑选择菜单」Sheet，含「多行展示/展示图标」开关与三组：一级菜单（10）/折叠菜单（0）/已隐藏项目（0），底部「恢复默认/取消/保存」 |

### B. 配置行为

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 折叠与隐藏 | PASS | `28_after_share_hidden.png`、`30_bar_after_B1.png`、`37_panel_B1.png` | 字典→折叠后浮条一级不再出现字典；分享→隐藏后浮条与面板均不再出现分享；「更多」面板中可见字典（折叠组）；配置跨阅读器重进保持 |
| B2 组内排序 | PASS | `39_after_up.png`、`42_bar_B2.png` | 「编辑」上移一位，Sheet 顺序变为 …高亮/编辑/替换/全文搜索；保存后浮条立即变为 …高亮/编辑（替换被推到滚动区外），即时生效 |
| B3 恢复默认 | PASS | `45_restored.png`、`46_restored_top.png` | 一级菜单回到（10）、折叠（0）、隐藏（0），顺序恢复默认（复制/分享/浏览器/朗读/书签/高亮/字典/替换/编辑/全文搜索）；**两个开关未被复位**（实测恢复后「多行展示=开」「展示图标=关」保持不变），与源码注释的既定行为一致 |
| B4 多行展示 | PASS | `63_bar_expand_on.png`、`75_bar_expand_off.png`、`117_bar_default_360.png` | 开：一级+折叠合并为多行 Wrap（两行，含折叠组字典），不再有「更多」，管理可达；关：恢复单行横向滚动 + 固定「更多」 |
| B5 展示图标 | PASS | `78_bar_no_icon.png`、`79_sheet_icon_off.png`、`80_sheet_icon_on.png`、`63_bar_expand_on.png` | 关：浮条动作只剩文字、无图标；开：图标恢复；配置页列表图标同步（关时行首无图标，开时有图标），差异已记录 |
| B6 取消/保存/重启/备份 | PASS（带 P2） | `81_bar_after_cancel_icon.png`、`91_bar_persist.png`、`backup_1104h.json`、`backup_1104h_final.json` | 取消：草稿改动不落盘（浮条保持图标关闭形态，配置不变）；保存（设置/面板入口）：force-stop 重启后浮条仍为保存的多行/无图标形态；备份 JSON `appPrefs` 含 `textSelectMenuConfig`/`expandTextMenu`/`showSelectMenuIcon` 三键且值与当前配置一致（首份备份：expand=True、icon=False；清理后终态：expand=False、icon=True）。**浮条「管理」入口保存失效见 P2** |

### C. 窄屏与屏底

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 320dp | PASS | `118_narrow_launch.png`、`120_bar_narrow.png`、`121_panel_narrow.png`、`122_sheet_narrow.png` | 720x1280@360dpi（320x568dp）长按不崩溃；浮条「复制」[27,356–124,487] 可见可点，「更多」[506,356–603,487]、「管理」[603,376–693,466] 均在 720 宽内可点；面板「管理」[594,1152–684,1242] 可见；配置 Sheet 正常打开、无 RenderFlex overflow |
| C2 屏底锚点 | PASS | `126_bar_bottom_anchor.png`、`127_bar_bottom2.png`、`131_bar_bigfont.png`、`132_bar_2x.png` | 屏底（y=950/1280，文字末尾附近）长按：展开多行菜单自动上移（两行 815–1076），管理 [475,966–565,1056] 在屏内可达、不越界；1.6 倍与 2.0 倍字体下菜单 3 行仍完整在屏内、管理可达。**限制说明**：「菜单可滚动」为结构性确认（`SingleChildScrollView`），本次 10 项内容在 1.0/1.6/2.0 倍字体下均未超出屏高，未触发实际滚动 |

### D. 动作回归

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| D1 动作抽样（9/9） | PASS | `136_D1_copy_toast.png`、`138_D1_share.png`、`139_D1_browser.png`、`141_D1_aloud.png`、`143_D1_bookmark.png`、`145_D1_dict.png`、`146_D1_replace.png`、`149_D1_edit.png`、`150_D1_search.png` | 复制→「已复制到剪贴板」；分享→系统分享面板（分享文本/目标）；浏览器→Bing 搜索该段文本；朗读→朗读控制条（定时停止/上下段/停止朗读/倍速），可停止；书签→「已添加书签」；字典→词典面板（本地/百度汉语/哔哩/有道/海词）；替换→「添加替换规则」页并预填文本；编辑→「编辑：第1章 …」对话框；全文搜索→搜索页并显示「共 1 处匹配」 |
| D2 高亮（menu_mark） | PASS（附 P3） | `151_D2_mark_panel.png`、`154_D2_dialog.png`、`155_D2_highlight_saved.png`、`157_highlight_render.png` | 点「高亮」直接打开底部面板并展开「高亮颜色」行（5 色，上次色有勾选）；点色块打开「高亮」对话框，选色后「保存高亮」→「已添加高亮」。**P3**：①配色行贴屏幕底缘，色块下半被裁切（需点在 y≈1870 才命中）；②翻页往返后正文未见高亮底色渲染（疑既有渲染问题，非本批引入，见未闭环项） |

### E. 回归与稳定性

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| E1 选区与导航 | PASS | `183_E1_select.png`、`184_E1_drag.png`、`185/186` XML、`187` XML | 面板内 SelectableText 长按选中 1 字（原生句柄 + 系统菜单 Copy/Share/Select all/阅读），拖拽右侧手柄扩到 8 字，已选字数实时更新；翻页 5/6↔6/6 正常；菜单开合正常；返回退出阅读器到详情/书架正常 |
| E2 稳定性 | PASS | `logcat_qa4c_20261104.txt`、`85_crash_dialog.png`、`87_crash_report.png` | FATAL EXCEPTION **0**；ANR **0**；E/flutter **0**；RenderFlex overflow **0**。SIGSEGV 共 264 次，全部为 `uiautomator dump` 进程「Shutdown thread」（MuMu ROM 已知噪声，无一条属于应用 PID）。应用自身崩溃记录 **1 次**（P2 的 Bad state），非 FATAL/ANR |

### F. 清理

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| F1 清理与终态 | PASS | `189_F1_sheet.png`、`207_final_shelf.png`、`208_final_device.png`、`backup_1104h_final.json` | 选择菜单恢复默认（10 项一级、展开关、图标开；备份 JSON：14 项全部 showState=0、expand=false、icon=true）；测试书已删除、书架为空；`font_scale=1.0`；`wm size=1080x1920`、`wm density=480`；竖屏（`SurfaceOrientation=0`、`user_rotation=0`）；已删 `/sdcard/Download/qa4c_book.txt` 与测试备份 JSON |

---

## 四、缺陷与问题清单

### P2-1 浮条「管理」进入配置页后「保存」抛异常且不保存（功能不可用 + 误记崩溃）

- 入口：阅读器长按正文 → 浮条尾部齿轮「管理选择菜单」→「编辑选择菜单」Sheet →（任意修改后）点「保存」
- 期望：保存生效并关闭 Sheet（与从底部面板「管理」、阅读设置→更多→选择菜单进入时一致）
- 实际：Sheet 不关闭、配置不落盘；下次启动弹出应用崩溃提示「上次运行发生崩溃 / Bad state: Cannot use "ref" after the widget was disposed.」
- 复现率：2/2（B3 首次、B4 复核均复现）；对照路径（面板「管理」、设置入口）保存正常，各 3 次以上成功
- 证据：`85_crash_dialog.png`、`87_crash_report.png`、`88_crash_detail.xml`；崩溃时间 2026-11-04 11:50:38
- 堆栈（关键三帧）：
  ```
  #0 ConsumerStatefulElement._assertNotDisposed (flutter_riverpod/src/consumer.dart:550)
  #1 ConsumerStatefulElement.read (consumer.dart:619)
  #2 TextSelectMenuConfigSheet.showForReader.<anonymous closure>
     (flutter_legado/src/widgets/reader/text_select_menu_config_sheet.dart:51)
  #3 _TextSelectMenuConfigSheetState._confirm (text_select_menu_config_sheet.dart:111)
  ```
- 根因（代码阅读，非臆测）：`ReaderSelectionToolbar` 的管理按钮 `onPressed` 先 `onDismiss()` 移除 OverlayEntry（浮条 widget 随即销毁），再用该已销毁 widget 的 `context/ref` 调用 `TextSelectMenuConfigSheet.showForReader`；`showForReader` 捕获的 `onChanged` 在保存时执行 `ref.read(readerAdvConfigProvider.notifier)`（该文件第 51 行）→ `ConsumerStatefulElement._assertNotDisposed` 抛 `Bad state` → `_confirm` 中 `Navigator.pop` 未执行，故既未保存也未关闭
- 建议修复方向（不越权改码，供实现方参考）：`show()` 先于 `onDismiss()`（或延后到下一帧再移除浮条），或改为传入 `ProviderContainer` / 稳定的 Navigator 上下文，避免保存回调持有已 dispose 的 `WidgetRef`
- 影响面：A1/A3 的「浮条管理」入口 + B6 保存；底部面板「管理」与设置入口不受影响

### P3-1 高亮配色行贴屏幕底缘、色块被裁切

- 现象：`initialHighlight=true` 打开底部面板时，「高亮颜色」行位于 1920 屏高最底，32dp 圆点 bounds 约 1836–1932，下半被裁；直接点圆心（y≈1900）易落空，需点上缘（y≈1870）才命中
- 证据：`151_D2_mark_panel.png`、`152_D2_color_dialog.png`、`154_D2_dialog.png`
- 影响：可用但命中区不佳（窄屏/大字体下更明显）

### P3-2 高亮保存后正文未见底色渲染（观察项）

- 现象：点「保存高亮」提示「已添加高亮」`155_D2_highlight_saved.png`，但当前页与翻页往返后（`157_highlight_render.png`）正文均无底色
- 判断：疑为既有高亮渲染能力问题（批4c 仅映射 menu_mark→既有高亮动作，未改渲染），不构成本批回归结论；建议由高亮渲染/批7 专项确认

### 观察（非缺陷）

- 空配置保存后实际落盘为 14 项完整 JSON（含未实现的 `menu_ai_clean`/`menu_ai_rewrite`/`menu_insert_bgm_*`），UI 三组只列已实现的 10 项；与工程关闭登记 ②⑤ 一致
- 备份路径残留：为完成 B6 备份抽查，将「备份路径」从空设置为 `/storage/emulated/0/Download/legado_backup`（F1 未列该项；如需清除需重新选择路径或清除应用数据）

---

## 五、崩溃与稳定性统计

| 指标 | 数值 | 备注 |
|---|---|---|
| FATAL EXCEPTION（Java） | 0 | grep `FATAL EXCEPTION` |
| ANR | 0 | grep `ANR in` |
| E/flutter | 0 | release 变体未打印 Flutter 错误；异常由应用崩溃记录器捕获 |
| RenderFlex overflow | 0 | grep `overflowed` |
| Fatal signal 11 (SIGSEGV) | 264 | **全部**来自 `uiautomator dump` 的「Shutdown thread」（每个 dump 进程 1 次），无应用 PID（`23571` 等） |
| 应用崩溃记录（应用内） | 1 | 即 P2-1 的 `Bad state: Cannot use "ref" after the widget was disposed.` |

---

## 六、未闭环项

1. **P2-1 待修复**：浮条「管理」→「保存」抛 `Bad state`，保存失效。修复后需复验：该入口保存→关闭→重启保持，且不再产生崩溃记录。
2. **C2「菜单可滚动」未实测触发**：10 项在 1.0/1.6/2.0 倍字体、320dp/360dp 下菜单高度均未超过屏高，仅确认 `SingleChildScrollView` 结构与屏底 clamp 生效；如需强制验证，可后续用更多已实现项/更高字体放大比例构造。
3. **高亮渲染观察项**（P3-2）未定性：建议高亮/批7 专项确认是否为既有缺陷。
4. 拖拽排序（`ReorderableDragStartListener`）本次以「上/下移」替代验证（验收项允许），真实长按拖拽未验。

---

## 七、设备终态

| 项 | 终态 |
|---|---|
| 应用 | `io.legado.flutter_legado` 2.0.455+456 运行中，前台为书架（空态） |
| 书架 | 空（测试书已删除） |
| 选择菜单配置 | 默认：一级菜单 10 项、折叠 0、隐藏 0；多行展示关；展示图标开（备份 JSON 复核：14 项全 showState=0、expand=false、icon=true） |
| 分辨率/密度 | 1080x1920 / 480dpi（已 reset override） |
| 字体缩放 | 1.0 |
| 屏幕方向 | 竖屏（SurfaceOrientation=0，user_rotation=0，accelerometer_rotation=1） |
| SD 卡测试物 | 已删除 `/sdcard/Download/qa4c_book.txt`、`/sdcard/Download/legado_backup/*.json` |
| 残留 | 应用内「备份路径」=`/storage/emulated/0/Download/legado_backup`（见观察项） |

---

## 八、证据索引（`docs/materials_1104h/`）

**关键截图**

- A：`11_longpress_default.png`、`12_bar_scrolled.png`、`13_more_panel.png`、`14_config_sheet.png`、`15_config_sheet_bottom.png`、`22_settings_more_scrolled.png`、`23_sheet_from_settings.png`、`117_bar_default_360.png`
- B：`28_after_share_hidden.png`、`30_bar_after_B1.png`、`37_panel_B1.png`、`42_bar_B2.png`、`45_restored.png`、`46_restored_top.png`、`63_bar_expand_on.png`、`75_bar_expand_off.png`、`78_bar_no_icon.png`、`79_sheet_icon_off.png`、`80_sheet_icon_on.png`、`81_bar_after_cancel_icon.png`、`91_bar_persist.png`
- C：`118_narrow_launch.png`、`120_bar_narrow.png`、`121_panel_narrow.png`、`122_sheet_narrow.png`、`126_bar_bottom_anchor.png`、`127_bar_bottom2.png`、`131_bar_bigfont.png`、`132_bar_2x.png`
- D：`136_D1_copy_toast.png`、`138_D1_share.png`、`139_D1_browser.png`、`141_D1_aloud.png`、`143_D1_bookmark.png`、`145_D1_dict.png`、`146_D1_replace.png`、`149_D1_edit.png`、`150_D1_search.png`、`151_D2_mark_panel.png`、`154_D2_dialog.png`、`155_D2_highlight_saved.png`、`157_highlight_render.png`
- E：`183_E1_select.png`、`184_E1_drag.png`
- F：`189_F1_sheet.png`、`197_delete_dialog.png`、`207_final_shelf.png`、`208_final_device.png`
- P2：`85_crash_dialog.png`、`87_crash_report.png`

**日志与数据**

- `logcat_qa4c_20261104.txt`（11:41–12:21 全量 logcat，E2 统计原始证据）
- `backup_1104h.json`（B6 备份抽查：expand=True/icon=False/含三键）
- `backup_1104h_final.json`（F1 终态复核：expand=False/icon=True/14 项 showState=0）
- 语义树快照（保留关键 19 份 XML，其余同名 dump 归档在 `tmp_qa_4c/xml_archive/`）：`11_longpress_default.xml`、`12_bar_scrolled.xml`、`13_more_panel.xml`、`14_config_sheet.xml`、`15_config_sheet_bottom.xml`、`22_settings_more_scrolled.xml`、`37_panel_B1.xml`、`45_restored.xml`、`63_bar_expand_on.xml`、`78_bar_no_icon.xml`、`87_crash_report.xml`、`88_crash_detail.xml`、`120_bar_narrow.xml`、`121_panel_narrow.xml`、`122_sheet_narrow.xml`、`127_bar_bottom2.xml`、`132_bar_2x.xml`、`183_E1_select.xml`、`184_E1_drag.xml`、`189_F1_sheet.xml`、`207_final_shelf.xml`

**复现用辅助脚本**：`tmp_qa_4c/qa_ui.py`（dump/tap/longpress/shot/swipe 封装，未入库）

---

编写：QA 子代理 ｜ 2026-11-04

---

# 九、P2 回修复验（2026-11-04 追加，定向复验）

> 本章节**取代**第三章 B6 的 P2 结论与第四章 P2-1 的待修状态。复验范围仅覆盖 P2 修复、三条入口对照、重启/备份与关键回归，不重跑全量 16 项。

## 9.1 结论

**P2 回修复验：PASS。** 浮条「管理」→ 配置 Sheet →「保存」已恢复正常（Sheet 关闭、配置落盘、无 Dart 异常、无应用内崩溃记录）；三条入口（浮条管理 / 底部面板管理 / 阅读设置→更多→选择菜单）保存均正常，取消不落盘；重启保持与备份 JSON 均符合预期。

- P1：0
- P2（代码缺陷）：0（原 P2-1 已闭环）
- 环境风险：1 项（Flutter 引擎 Impeller Vulkan OOM 原生崩溃 2 次，见 9.6，非本批代码缺陷）
- 回归项：功能类全部 PASS；稳定性统计见 9.6（FATAL EXCEPTION 0 / ANR 0 / RenderFlex overflow 0 / Dart 异常 0；E/flutter 9 行全部为引擎 Vulkan OOM）

## 9.2 版本与构建

| 项 | 值 |
|---|---|
| 修复提交 | `955fcbd605`（`fix(ui): 选择菜单 Sheet 改用稳定 ProviderContainer`）+ `21aed23856`（`test(ui): 覆盖浮条管理保存与配置重开回显`） |
| 版本 | **2.0.456+457**（`pubspec.yaml` 版本号在构建时位于工作区未提交状态；代码基线 HEAD=`21aed23856`） |
| 构建 | `cd flutter_legado && flutter build apk --release` → `assembleRelease 64.8s`，产物 192.2MB |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，201,502,564 bytes |
| **APK sha256** | `631f1d84e77b2e33057d430f0c7bdfb5c5fa5e995c00ed1c6347507e3eeece63` |
| 安装 | `adb install -r` Success；设备 versionName **2.0.456** / versionCode **457**，lastUpdateTime 2026-11-04 12:39:46 |

**构建环境问题（非代码，已规避）**：首次构建失败于 `:app:compileReleaseJavaWithJavac`——`GeneratedPluginRegistrant.java:54` 引用了 `dev.flutter.plugins.integration_test`，而该生成文件（gitignore）是 12:35 由其他构建/测试残留的旧版本（含 dev 依赖插件）。删除该生成文件后 `flutter build apk --release` 正常重新生成（新文件 0 处 integration_test），构建成功。证据：`tmp_qa_4c_p2_build.log`（失败）与 `tmp_qa_4c_p2_build2.log`（成功）、`tmp_qa_4c/GeneratedPluginRegistrant.before_4i.java`。**建议后续构建前执行 `flutter clean` 或删除该生成文件，避免同类假失败。**

## 9.3 原 P2 主场景复验（浮条齿轮入口）

| 步骤 | 期望 | 实际 | 证据 |
|---|---|---|---|
| 1. 阅读器长按正文 → 浮条 → 齿轮「管理选择菜单」 | 打开「编辑选择菜单」Sheet | 打开，一级菜单（10） | `06_sheet_open.xml` |
| 2. 「分享」→ 移动到 → 移至隐藏 | 一级（9）、隐藏组 +1 | 一级菜单（9） | `08_share_hidden_draft.png`、`08_share_hidden_draft.xml` |
| 3. 点「保存」 | Sheet 关闭、无异常、配置落盘 | **Sheet 正常关闭，配置生效；无 Dart 异常、无应用内崩溃提示** | `10_after_save.png`、`10_after_save.xml` |
| 4. 再次长按 → 浮条 | 不含「分享」 | 复制/浏览器/朗读/书签/高亮 + 更多 + 管理 | `11_bar_after_save.png`、`11_bar_after_save.xml` |
| 5. 从浮条重新打开配置 | 已隐藏项目（1），分享在隐藏组 | 已隐藏项目（1）/ 分享 | `12_sheet_reopen_hidden.png`、`12_sheet_reopen_hidden.xml` |
| 6. 底部面板 | 不含「分享」 | 复制/浏览器/朗读/书签/高亮/字典 + 管理 | `13_panel_after_save.png`、`13_panel_after_save.xml` |

## 9.4 对照路径

| 路径 | 结果 | 证据 |
|---|---|---|
| 底部面板「管理」→ 字典移至折叠 → 保存 | PASS：Sheet 关闭；面板仍含字典（折叠项）、浮条不含字典 | `14_panel_manage_sheet.xml`、`17_panel_after_manage_save`（同一会话 dump）、`13_panel_after_save.png` |
| 阅读设置→更多→选择菜单 → 直接保存 | PASS：Sheet 关闭并回到设置页 | `20_settings_sheet.xml`、`21_settings_saved` dump |
| 从设置入口改「编辑→隐藏」后点取消 | PASS：Sheet 关闭；重开仍为一级（8）/折叠（1，字典）/隐藏（1，分享），编辑仍在一级 | `23_edit_hidden_draft.xml`、`26_sheet_top_order.png`、`26_sheet_top_order.xml` |

## 9.5 重启保持与备份

| 项 | 结果 | 证据 |
|---|---|---|
| force-stop 后重启 | 无崩溃提示；浮条为 复制/浏览器/朗读/书签/高亮/替换 + 更多 + 管理（分享仍隐藏、字典仍折叠） | `27_relaunch.xml`、`28_bar_after_restart.png`、`28_bar_after_restart.xml` |
| 备份 JSON（复验中配置） | `appPrefs.textSelectMenuConfig` 存在；`menu_share_str` `{showState:2}`、`menu_dict` `{showState:1}`；`expandTextMenu=false`、`showSelectMenuIcon=true` | `backup_1104i.json` |

## 9.6 关键回归与稳定性

| 项 | 结果 | 证据 |
|---|---|---|
| 浮条一级动作可点（复制） | PASS：「已复制到剪贴板」 | `34_reg_copy_toast.png` |
| 更多/管理可见可点（360dp 默认） | PASS：更多 [795,608–924,782]、管理 [924,635–1044,755] | `28_bar_after_restart.xml`、`43_bar_default_final.xml` |
| 320dp（720x1280@360dpi）打开不崩溃 | PASS：复制 [27,356]、更多 [506,356–603,487]、管理 [603,376–693,466] 均在屏内；面板管理 [594,1152–684,1242] 可见 | `35_narrow_bar.png/xml`、`36_narrow_panel.png/xml` |
| 屏底上移（320dp，y=1000 长按） | PASS：浮条 y=856–987，不越界，更多/管理可点 | `37_narrow_bottom.png/xml` |
| FATAL EXCEPTION / ANR / RenderFlex overflow | 0 / 0 / 0 | `logcat_1104i.txt` |
| Dart 异常 / Bad state | 0（应用内崩溃记录无新增，重启后无「上次运行发生崩溃」提示） | `logcat_1104i.txt`、`27/47/53` dump |
| E/flutter | **9 行，全部为 Impeller Vulkan OOM（2 次事件），非 Dart 异常**，见下 | `logcat_1104i.txt`、`crash_impeller_vulkan_oom.txt` |
| 应用进程原生崩溃 | **2 次**（raster 线程，Impeller Vulkan OOM），见下 | 同上 |

**环境风险（非本批代码缺陷，未闭环观察项）**：12:50:32 与 12:50:48 应用进程各发生 1 次原生崩溃（SIGSEGV，线程 `1.raster`，backtrace 全部位于 `libflutter.so`）。崩溃前日志明确为 GPU 显存不足：

```
E/flutter: [ERROR:...allocator_vk.cc(361)] Impeller validation: Unable to allocate Vulkan Image:
           ErrorOutOfDeviceMemory Type: Texture2DMultisample ... Format: D32SfloatS8Uint ... { DepthStencilAttachment }
E/flutter: [ERROR:...inline_pass_context.cc(121)] Depth attachment unexpectedly missing from the EntityPass render target.
E/flutter: [ERROR:...khr_swapchain_impl_vk.cc(207)] Could not create swapchain: ErrorOutOfDeviceMemory
E/flutter: [ERROR:flutter/shell/common/platform_view.cc(76)] Failed to create platform view rendering surface
```

- 触发时机：320dp（720x1280@360dpi）用例结束、执行 `wm size/density reset` 回到 1080x1920/480 后约 3 分钟，连续返回退出阅读器时；第二次为随后一次冷启动 1 秒内（swapchain 创建失败）。第三次启动后稳定，后续 5 分钟内完成备份/复制/删书/清理等操作无复发。
- 判定依据：错误为 `ErrorOutOfDeviceMemory`（引擎/GPU 层），崩溃栈全在 `libflutter.so`，`SIGNAL_LOG` 显示 MuMu Houdini (`invalid arm reg`)，无任何 Dart 日志/异常；与本次修复（仅调整 Dart 回调持有的 ProviderContainer/Navigator）无逻辑关联。同一设备在 2.0.455+456 会话中执行相同分辨率切换未出现该错误，说明为**模拟器 Vulkan 显存非确定性耗尽**，非稳定复现的代码回归。
- 建议：后续设备任务避免在应用运行中频繁切换分辨率（如必须切换，切后重启应用并等待 GPU 释放）；如需在该模拟器长期跑 UI 验收，可考虑关闭 Impeller/Vulkan（`--enable-impeller=false`）或提升模拟器显存配置。已在 `crash_impeller_vulkan_oom.txt` 固化原始日志摘录。

## 9.7 设备终态

| 项 | 终态 |
|---|---|
| 应用 | `io.legado.flutter_legado` **2.0.456+457** 运行中（PID 30245），前台书架（空态），无崩溃提示 |
| 书架 | 空（测试书已删除，备份 JSON `books=0`） |
| 选择菜单配置 | 默认：一级 10、折叠 0、隐藏 0；多行展示关；展示图标开（备份 JSON 复核：14 项全 showState=0、expand=false、icon=true） |
| 分辨率/密度 | 1080x1920 / 480dpi（override 已 reset） |
| 字体缩放 | 1.0 |
| 屏幕方向 | 竖屏（SurfaceOrientation=0，user_rotation=0，accelerometer_rotation=1） |
| SD 卡测试物 | 已删除 `/sdcard/Download/qa4c_book.txt` 与 `/sdcard/Download/legado_backup/*.json` |
| 残留 | 应用内「备份路径」仍为 `/storage/emulated/0/Download/legado_backup`（与上一轮相同，非本轮新增） |

## 9.8 证据索引（`docs/materials_1104i/`）

- 截图：`06_sheet_open`（等待中无图，见 XML）、`08_share_hidden_draft.png`、`10_after_save.png`、`11_bar_after_save.png`、`12_sheet_reopen_hidden.png`、`13_panel_after_save.png`、`26_sheet_top_order.png`、`28_bar_after_restart.png`、`34_reg_copy_toast.png`、`35_narrow_bar.png`、`36_narrow_panel.png`、`37_narrow_bottom.png`、`43_bar_default_final.png`、`47_shelf_check.png`、`53_final_shelf.png`
- 数据：`backup_1104i.json`（复验配置）、`backup_1104i_final.json`（终态默认配置 + books=0）、`logcat_1104i.txt`（12:41–12:55 全量）、`crash_impeller_vulkan_oom.txt`（Vulkan OOM/原生崩溃摘录）
- 语义树（保留 18 份，其余归档 `tmp_qa_4c/xml_archive_1104i/`）：`06_sheet_open.xml`、`08_share_hidden_draft.xml`、`10_after_save.xml`、`11_bar_after_save.xml`、`12_sheet_reopen_hidden.xml`、`13_panel_after_save.xml`、`14_panel_manage_sheet.xml`、`17_panel_after_manage_save.xml`、`20_settings_sheet.xml`、`21_settings_saved.xml`、`23_edit_hidden_draft.xml`、`26_sheet_top_order.xml`、`28_bar_after_restart.xml`、`35_narrow_bar.xml`、`36_narrow_panel.xml`、`37_narrow_bottom.xml`、`43_bar_default_final.xml`、`53_final.xml`
- 构建日志：`tmp_qa_4c_p2_build.log`（首次失败）、`tmp_qa_4c_p2_build2.log`（成功）

编写：QA 子代理 ｜ 2026-11-04（P2 回修复验）
