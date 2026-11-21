# 台账回销核实报告（R43 / R44）

- 核实日期：2026-11-21
- 核实角色：调研子代理（只读调研 + 台账文档回写；**未改任何产品代码**）
- 仓库 HEAD：`0b52660288`（`docs: R26/R30/R31/R33 契约回写与两份 jsHelp 同步`），分支 `master`
- 触发来源：`docs/REMAINING_WORK_INVENTORY_20261120.md:75-76`（R43 / R44 两行均带「台账未回销」疑点）
- 环境门禁：`flutter_legado/analysis_options.yaml` 存在；`dart analyze` → **No issues found!**（0 诊断）

---

## 一、结论摘要

### R43（深色主题台账 44 处「待补采」）

| 口径 | 数量 |
|---|---|
| 台账原「❌待补采」屏数（43 屏表内） | 42 |
| **本轮确认已有参考版深色实机证据 → 已回销** | **11 屏**（1-1 / 1-3 / 1-8 / 1-10 / 1-11 / 1-13 / 2-1 / 2-3 / 2-8 / 3-1 / 3-5） |
| **部分回销**（仅一半屏内容有证据） | **1 屏**（2-10：Web 服务开启态 ✅，RSS 源二级页 ❌） |
| **仍为真待办** | **30 屏** |
| 台账「待补采」字样计数变化 | 44 → 35（表内行 43→34 + 正文引用 1 行） |

> 注：`REMAINING_WORK_INVENTORY` 称「44 屏」，实测台账 `待补采` 出现 44 次，其中 **43 次为屏行、1 次为 B-1 汇总行引用**；实际屏清单为 **43 屏**（批1×16 + 批2×10 + 批3×11 + 批4×6），与台账 §四 表格行数一致。

**R43 判定：不是「44 屏全待补采」，而是「30 屏真待办 + 11 屏可回销 + 1 屏部分 + 1 屏（3-4）原本已闭环」。** 台账未回销属实，本轮已回销。

### R44（「待优化台账」6 项 UX）

| # | 项 | 台账原判 | **本轮实测** |
|---|---|---|---|
| ① | 替换规则保存/删除成功不返回数据 | 盘点称「仍保留（1:1 保留原版怪癖）」 | **已修**（批23 显式成功信封，用户裁决偏离原版）——盘点结论有误 |
| ② | 替换规则测试空 pattern 错误提示被结果覆盖 | 未复核 | **已修**（批23：空 pattern 只返回错误） |
| ③ | RSS 加载更多「末条判底」复用首条 sort | 未复核 | **已修**（批23；批23b 复核后归因为「防御性加固、无可观察行为变化」） |
| ④ | 崩溃报告对话框右侧溢出 12px | 已修 | **已修**（确认） |
| ⑤ | Web 服务卡片仅 Switch 命中区可点 | 未复核 | **已修**（批23 整卡可点；M2/M3 重构后由 `SettingSwitchRow` 整行 onTap 承接，有 2 条 widget 测试） |
| ⑥ | 冒烟脚本历史崩溃存根遮蔽 UI 检查 | 未复核 | **已修**（批23 + 批23b：先关弹窗、清 stale XML） |

**R44 判定：6/6 全部已修，整项可关闭。** `REMAINING_WORK_INVENTORY` 标注的「2~3 天工作量 / 偏离原版需用户确认」均不成立——用户裁决已于 2026-10-27 作出并落地（版本收尾 `2.0.399+400`）。

---

## 二、R43 逐屏对照表

### 2.1 判定方法

1. 全仓 `docs/**` 共 **6703 张**图片做 PIL 16×16 缩略灰度均值扫描，`< 90` 判深色（与 `DARK_DELTA_20260920.md` 的 `DARK_MEAN_THRESHOLD=90` 同口径），得 **845 张**候选。
2. 剔除我方截图目录（`materials_1101e/1102/1104*/1107/1109*/1110*/1112*/1113*`、`parity_shots/verify_ui_20260922`、`ours_dark_*`、`pairs_*` 等——经 `DEVICE_ACCEPTANCE_*.md` 反查均为 `io.legado.flutter_legado` 我方实机证据）。
3. 对剩余参考版候选（`materials_1301/evidence/kz*`、`materials_1031b/*kz*`、`materials_1105/ref_kazusa_*`、`materials_1101d/ref_*`、`parity_shots/ref_dark_20260920|21`、`ref_batch3/04_appearance_dark.png`）**逐张目视核对内容**，确认屏号归属。
4. 归属不明确或参考侧确无该屏的，一律维持「待补采」，不做推断式回销。

### 2.2 已回销屏（11 屏）

| 屏号 | 屏名 | 台账原状态 | 实际证据位置 | 内容核对 | 结论 |
|---|---|---|---|---|---|
| 1-1 | 底部导航（五页签） | ❌待补采 | `docs/materials_1301/evidence/kz1_home.png` | 深色书架，底部五页签（首页/书架/发现/订阅/我的）完整可见，书架页签选中态 | **已可回销** |
| 1-3 | 书架（含空态） | ❌待补采 | `docs/materials_1301/evidence/kz1_home.png`；`docs/materials_1101d/ref_00_launch.png` | 深色书架：大标题「书架」+ 四分组 tab（未读/小说/全部/网络未分组）+ 两书网格（`kz1_home`，tab 选中态为黄绿高亮）/ 顶栏圆底搜索+⋮（`ref_00_launch`，tab 选中态为蓝色） | **已可回销** |
| 1-8 | 书籍详情 | ❌待补采 | `docs/parity_shots/ref_dark_20260920/08_book_info.png` + `.xml` | 深色详情页：封面/书名/作者/书源/两 chip（奇幻玄幻·142.20万字）/四动作卡/在读行/「阅读」绿 FAB；背景均值 lum≈27.6（manifest 断言） | **已可回销** |
| 1-10 | 阅读器正文 | ❌待补采 | `docs/parity_shots/ref_dark_20260920/10_reader.png` + `.xml` | 深色正文：纯黑底 (0,0,0) + 浅灰字（max 173，非空白），底栏「斗罗大陆 / 1/12 0.0%」 | **已可回销** |
| 1-11 | 阅读器菜单 | ❌待补采 | `docs/parity_shots/ref_dark_20260920/11_reader_menu.png` + `.xml`；`docs/materials_1031b/35_kz_readcfg1.png`、`36~39_kz_more_tab*.png` | ①深色阅读器菜单（顶栏书名/章节/书源 + 底栏 5 键）；②「阅读界面」Sheet（字号 24 / 背景预设 / 翻页动画 / 全局-菜单-信息-更多 四 tab）；③「更多」tab 四帧（屏幕显示与亮度 / 翻页控制 / 其它）——`DEVICE_ACCEPTANCE_20261031_BATCH1A.md` §7.1 明载 35~39 为参考版基准 | **已可回销** |
| 1-13 | 全文搜索 | ❌待补采 | `docs/parity_shots/ref_dark_20260920/13_search_content.png` + `.xml` | 深色「搜索内容」页：搜索输入盒 + 「搜索历史」+ 右上「仅本书」浅色胶囊 + 空态表情；背景 lum≈18.8 | **已可回销** |
| 2-1 | 发现（分组 chips） | ❌待补采 | `docs/materials_1301/evidence/kz6_settings_night.png`（同内容另见 `kz5_reader_settings.png`/`kz7_settings_other.png`/`kz8_other_tab.png`，见 §2.4 命名问题） | 深色发现页：大标题「发现」+「全部」+ 五源卡片列表（半夏小说/奈飞工厂/SiS文學網/金银小说网/霹雳书屋）+ 两行分组 chips | **已可回销** |
| 2-3 | 发现源二级页（chips） | ❌待补采 | `docs/materials_1301/evidence/kz8b.png` | 深色展开态：「霹雳书屋」卡片展开（chevron 向下）+ 3 列 chips 两行（全部小说/男频小说/女频小说/电子图书/无CP小说/纯爱小说） | **已可回销** |
| 2-8 | 书源编辑器（扫码） | ❌待补采 | `docs/parity_shots/ref_dark_20260920/09_source_editor_qr_dialog.png` + `.xml` | 深色全屏扫描器（标题「扫描二维码」+ 右上「图库」+ 青色取景框 + 手电筒）；顶栏 lum≈18.8。**形态与台账 B4 登记的「全屏扫描器 vs 页内扫码」差异一致**，可直接用于 B4 裁决 | **已可回销** |
| 3-1 | 我的 | ❌待补采 | `docs/materials_1105/ref_kazusa_my_top.png`（停止态）、`ref_kazusa_my_stopped.png`、`ref_kazusa_running.png`（运行态）；`docs/materials_1301/evidence/kz9_longpress.png` | ①深色「我的」：Web 服务卡（浏览器窗口图标 + 副题 + 行内开关）+「规则」组（书源管理/替换净化/TXT 目录规则/字典规则/标签规则）；②运行态：开关开 + 地址 `http://192.168.100.62:1122` + 「拷贝 URL」「浏览器打开」两钮（无独立卡片，与台账 3-1 裁决记录一致） | **已可回销** |
| 3-5 | 主题设置（12 色卡） | ❌待补采 | `docs/parity_shots/ref_dark_20260920/05_theme.png` + `.xml`；`docs/parity_shots/ref_dark_20260921/04_appearance_clean_dark.png/.xml`、`04_appearance_clean_dark_mid.png/.xml` | ①深色外观页：主题模式三态分段（深色选中）+ 12 卡横滑行（可见 动态取色/草野/柠檬/黑白，逐卡 swatch rgb 已采：#514E44/#5B584E/#726739/#676359）+ 字体设置/主题风格/切换图标/预见性返回手势；②`ref_dark_20260921` 提供默认「动态取色」深色干净基线（背景 #101418、卡片 #1D2024）——台账 B-5 的「def 套暗色锚点核对」所需素材已具备 | **已可回销** |

> 另注（3-4 已闭环屏的素材补充）：`docs/materials_1101d/ref_00_launch.png`、`ref_01_eye_group.png`、`ref_02_eye_enabled.png`、`ref_03_color_temp_dialog.png`、`ref_eye_i0|i50|i100.png` 经目视为**外观页深色 + 护眼 0/50/100 强度 + 色温弹窗**（非书架），已在台账 3-4 行追加登记，可支撑护眼/色温两组的深色比对。

### 2.3 部分回销屏（1 屏）

| 屏号 | 屏名 | 台账原状态 | 实际证据 | 缺口 | 结论 |
|---|---|---|---|---|---|
| 2-10 | RSS 源二级页 / Web 服务开启态 | ❌待补采 | Web 服务开启态 ✅：`docs/materials_1105/ref_kazusa_running.png`（深色，开关开 + 地址 + 两动作钮） | RSS 源二级页深色态仍缺（参考侧订阅无源不可达，与 `SCREEN_1TO1_PARITY_LEDGER_20260914.md` 2-10 同口径） | **部分回销**（台账已改为 🔄） |

### 2.4 仍为真待办（30 屏）

| 批次 | 屏号 | 缺口说明 |
|---|---|---|
| 批1（9 屏） | 1-2 首页页签、1-4 书架溢出菜单、1-5 书架批量多选态、1-6 搜索、1-7 搜索结果页、1-9 目录页、1-12 正文长按菜单、1-14 目录·书签页签、1-15 章节跳转、1-16 自动翻页 | 参考侧均无深色实机截图（10 屏） |
| 批2（6 屏） | 2-2 发现溢出菜单、2-4 发现源二级页（下拉型源）、2-5 发现分类书单、2-6 换源/书源弹层、2-7 书源管理、2-9 替换净化编辑器 | 2-4 已核：`kz8b.png` 为 chips 型源展开态，非下拉选择器型源，不能替代 |
| 批3（8 屏） | 3-2 阅读记录、3-3 设置主页、3-6 备份与恢复、3-7 字体（Tt）、3-8 朗读、3-9 分组管理、3-10 定时任务、3-11 高亮标注列表 | 参考侧无深色实机截图 |
| 批4（6 屏） | 4-1 TXT 目录规则、4-2 字典规则、4-3 文件管理、4-4 关于页、4-5 首页模块管理（用户裁决暂不实施）、4-6 超低频深页 | 参考侧无深色实机截图；4-5 维持「随裁决」 |

> 批1 实际剩 10 屏（1-2/1-4/1-5/1-6/1-7/1-9/1-12/1-14/1-15/1-16），上表按批次小计为 10+6+8+6 = 30。

### 2.5 证据完整性问题（新发现，需下游注意）

`docs/materials_1301/evidence/` 下 `kz*.png` 的**文件名与实际内容不符**，md5 实测：

| 文件 | md5(前8) | 实际内容（目视） |
|---|---|---|
| `kz1_home.png` | `f22422f0` | 书架（深色）✅ 与文件名相符 |
| `kz2_reader_open.png` | `17b573eb` | **书架**（与 kz1 视觉一致） |
| `kz3_reader_menu.png` | `17b573eb` | **书架**（与 kz2 字节相同） |
| `kz4_tap_top.png` | `17b573eb` | **书架**（与 kz2 字节相同） |
| `kz5_reader_settings.png` | `a97093c5` | **发现页**（非「心境」设置 dialog） |
| `kz6_settings_night.png` | `edebb3f4` | **发现页**（与 kz5 仅时间戳差异） |
| `kz7_settings_other.png` | `a97093c5` | 发现页（与 kz5 字节相同） |
| `kz7b_settings_other.png` | `edebb3f4` | 发现页（与 kz6 字节相同） |
| `kz8_other_tab.png` | `0942cd65` | 发现页 |
| `kz8b.png` | `e5bfa193` | 发现页·霹雳书屋展开 chips ✅ |
| `kz9_longpress.png` | `a3bc312c` | 我的页（深色） |

**影响**：`docs/P43_WAVE1_DEVICE_QA_20260929.md:122-127` 声称 `kz2_reader_open.png` =「阅读器（暗色）深褐底白字」、`kz3/kz4` =「阅读器工具条」、`kz5/kz6` =「心境设置 dialog / 夜间模式 tab」——与实际文件内容不符（kz2/kz3/kz4 均为**书架**，kz5/kz6/kz7/kz8 均为**发现页**）。**该报告的 kz2/kz3/kz5/kz6 描述不可作为阅读器/阅读设置深色基准**。

**处置**：本轮 R43 回销**只采用内容经目视确认的 4 个文件**（`kz1_home.png`→书架/底栏、`kz6_settings_night.png`→发现、`kz8b.png`→发现展开、`kz9_longpress.png`→我的），1-10/1-11 的深色基准改用 `ref_dark_20260920/10_reader.png`、`11_reader_menu.png` 与 `materials_1031b/35~39_kz_*.png`（后者经 `DEVICE_ACCEPTANCE_20261031_BATCH1A.md` §7.1 明确登记为参考版基准）。**建议**下游修正 `P43_WAVE1_DEVICE_QA_20260929.md` 的 kz2/kz3/kz5/kz6 描述，或重采该 4 屏（本轮未改，属报告纠错事项）。

---

## 三、R44 逐项核实

### 3.0 台账原文位置

- 建账：`docs/REFACTORING_ACTIVE_PLAN.md:849`（2026-10-26，「待优化台账（UX 缺陷类）」，6 项）
- 关闭：`docs/REFACTORING_ACTIVE_PLAN.md:893`（2026-10-27，「批23（UX 待优化台账 6 项）工程关闭——版本收尾 2.0.399+400」）
- 提交核验（全部为 HEAD 祖先）：`85804492f4` / `939eca3feb` / `ff14782a28` / `7a3c84c818` / `7f36fa93f9` / `f63aeb3e29`（批23b）/ `b36515a7b1`（批23b）/ `a1fbac458f`（批23b）

### 3.1 ① Web 替换规则保存/删除成功不返回数据

**台账原文**：「原版 `ReplaceRuleController.kt:23-107` 成功路径不调 setData → 网页端保存后显示「未知错误,请联系开发者!」；我方 `legacy/source_write_api.rs` 1:1 保留；建议优化为显式 success 信封并同步 vue 提示，属用户可见行为偏离 → 需确认」。

**代码现状**（`rust/legado-server/src/legacy/source_write_api.rs`）：

- `:1103-1107` 文档注释——**盘点只读了前半段**：
  ```
  /// **返回值形态**：原版成功路径未调用 `setData`，信封保持构造默认
  /// （`isSuccess=false` +「未知错误,请联系开发者!」），Web 页因此把成功
  /// 显示为未知错误。批23 按用户裁决改为**显式成功信封**
  /// （`isSuccess=true` / `errorMsg=""` / `data=""`，与
  /// `saveBookSource` 等写端点成功形态一致）。
  ```
- `:1142` `Ok(()) => ReturnData::success(Value::String(String::new()))`（save）
- `:1175` 同形态（delete）
- `ReturnData::success` 定义 `rust/legado-server/src/legacy/mod.rs:136-142`：`is_success: true` / `error_msg: String::new()` / `data`
- 测试：`rust/legado-server/tests/legacy_web_test.rs:4371-4373` 断言 `isSuccess==true`、`errorMsg==""`、`data==""`；`:4498-4500` 同（delete）

**结论：已修**（批23，用户裁决的有意偏离原版）。**盘点结论「仍保留 / 刻意 1:1 保留原版怪癖」不成立**——注释后半句已明示改为显式信封。工作量：0（已完成）。

### 3.2 ② 替换规则测试空 pattern 错误提示被结果覆盖

**台账原文**：「原版先 setErrorMsg 后 setData，怪癖保留；建议优化为保留错误提示」。

**代码现状**（`source_write_api.rs`）：

- `:386` `const EMPTY_REPLACE_PATTERN_MESSAGE: &str = "替换规则不能为空";`
- `:1231-1239`：
  ```rust
  // 批23：空 pattern 只返回错误，不执行替换、不写结果区（原版被
  // setData 覆盖，前端错误提示不可见）
  if rule.pattern.is_empty() {
      return to_response(&ReturnData::error(EMPTY_REPLACE_PATTERN_MESSAGE), uri, origin.as_deref());
  }
  ```
- `:1188-1200` 文档注释记录「原版先 setErrorMsg 但不返回，随后 setData 覆盖」及批23 改法
- 测试：`legacy_web_test.rs:4625-4626` 断言 `isSuccess==false` + `errorMsg=="替换规则不能为空"`；`:4632-4658` 补边界（空 pattern 先于 text 类型校验，返回错误信封而非 HTTP 500）

**结论：已修**（批23，登记为有意偏离）。工作量：0。

### 3.3 ③ RSS 加载更多「末条判底」复用首条 sort

**台账原文**：「`RssArticlesViewModel.kt:141-149` 上游小瑕疵，我方 `rss.rs` 已复刻；边界排序问题，建议优化为末条自身 sort」。

**代码现状**（`rust/legado-ffi/src/api/rss.rs`）：

- `:644-660` `fn page_already_stored(items)`：首条与末条**各自**取自身 `(origin, link, sort)` 查 `find_one`
- `:589` 调用前加非空门控：`if !fetched.items.is_empty() && !page_already_stored(&fetched.items)? {`
- `:620` `let has_more = added && fetched.next_url.is_some();`
- `:636-641` 注释记录**批23b 归因修正**：「批23 把末条查询键从 `first.sort` 改为 `last.sort`，属**防御性加固（无可观察行为变化）**：在『页内 sort 恒等』不变量下两者查询结果完全相同，旧实现并不存在『同页跨分类误判』」
- 单测 4 条：`:852` 空页 / `:865` 末条自身 sort / `:923` 同 sort 首末缺一 / `:995` 末条在其它分类

**结论：已修**（批23，批23b 修正归因为防御性加固）。**注意**：台账 ① 所述「跨分类误判」在批23b 被证伪——引擎对整页每条都写入请求的 `sort_name`（`legado-fetcher/src/rss/parser_rule.rs:216`、`legado-net/src/rss.rs:589`），页内 sort 恒等，因此原实现并无用户可见缺陷。工作量：0（已完成，且实际收益为语义解耦而非缺陷修复）。

### 3.4 ④ 崩溃报告对话框右侧溢出 12px

**台账原文**：「批1~7 设备验收发现，既有 UI 布局缺陷」。

**代码现状**（`flutter_legado/lib/src/widgets/crash_log_dialog.dart`）：

- `:89-91` 注释：「原实现 Row 内 Text 无宽度约束：崩溃时间带长时区/附加文案时横向撑破对话框（实测右侧溢出 12px）。改为 Expanded + 顶端对齐，超长自动换行」
- `:101` `Expanded(`、`:104` `softWrap: true`
- 测试：`flutter_legado/test/widget/crash_log_dialog_test.dart:13-41`（超长崩溃时间不横向溢出，`expect(tester.takeException(), isNull)`）、`:49+`（320dp 回归）

**结论：已修**（批23 `ff14782a28`）。工作量：0。

### 3.5 ⑤ Web 服务设置卡片仅 Switch 命中区可切换

**台账原文**：「设备验收观察项，建议整卡可点」。

**代码现状**：

- 批23 `7a3c84c818` 当时实现为 `Material + InkWell + Ink` 包裹整卡
- M2/M3 重构（2026-11-03）后形态改为 `IosGroup` + `SettingSwitchRow`（`flutter_legado/lib/src/screens/settings_screen.dart:658`），**整行可点能力保留**：
  - `flutter_legado/lib/src/widgets/ios_widgets.dart:590` `onTap: onChanged == null ? null : () => onChanged(!value)`（`IosListTile` 的 `ListTile.onTap`）
  - `:588-589` `trailing: ExcludeFocus(child: Switch(...))`——Switch 子手势优先，不产生二次切换
- 测试（`flutter_legado/test/widget/settings_test.dart`）：`:908-957`「点标题即切换开关」（断言 `startedPorts == [1122]`、`Switch.value == true`、只写一次 `webService=true`）；`:963-1010`「点开关不误触整行点击」

**结论：已修**（批23 + M2/M3 承接，有回归测试）。工作量：0。

### 3.6 ⑥ 冒烟脚本历史崩溃存根遮蔽 UI 检查

**台账原文**：「工具链 UX，建议脚本先关闭弹窗/清存根」。

**代码现状**（`scripts/emulator_smoke_test.ps1`）：

- `:4-6` 文件头说明：「`-CheckUI` 时先自动关闭「上次运行发生崩溃」弹窗再断言，防历史崩溃存根遮蔽主界面语义」
- `:89-95` `Get-UiDump`：**先清设备/本地旧转储**（`Remove-Item $UiLocalPath`），防 pull 失败时读到上一轮 stale XML 造成假阳性
- `:107-111` `Test-CrashDialogXml`（批23b 收紧识别：标题命中，或「崩溃时间」+「确定」同时存在）
- `:128-133` `Close-CrashDialogOnce`（单次关闭、失败不重试/不重复计数）
- `:155-160` 关闭成功 `Pass`、失败 `Fail`（不再静默遮蔽）

**结论：已修**（批23 `7f36fa93f9` + 批23b `a1fbac458f`）。工作量：0。

### 3.7 R44 汇总

| # | 项 | 结论 | 修复提交 | 验证证据 |
|---|---|---|---|---|
| ① | 替换规则保存/删除不返回数据 | **已修** | `85804492f4` | `source_write_api.rs:1142/1175`；`legacy_web_test.rs:4371-4373/4498-4500` |
| ② | 空 pattern 错误被覆盖 | **已修** | `85804492f4` | `source_write_api.rs:1231-1239`；`legacy_web_test.rs:4625-4658` |
| ③ | RSS 末条判底复用首条 sort | **已修**（防御性加固） | `939eca3feb` + `f63aeb3e29` | `rss.rs:589/620/644-660`；4 条单测 |
| ④ | 崩溃弹窗溢出 12px | **已修** | `ff14782a28` | `crash_log_dialog.dart:89-105`；`crash_log_dialog_test.dart` |
| ⑤ | Web 服务卡仅 Switch 可点 | **已修** | `7a3c84c818`（+ M2/M3 承接） | `ios_widgets.dart:588-590`；`settings_test.dart:908-1010` |
| ⑥ | 冒烟脚本存根遮蔽 | **已修** | `7f36fa93f9` + `a1fbac458f` | `emulator_smoke_test.ps1:89-95/107-160` |

**R44 整项结论：已全部完成，可从待办清单移除。** 唯一残留的是文档层面的「归因表述」：③ 的实际收益是语义解耦而非缺陷修复（批23b 已自行修正）。

---

## 四、台账更新明细

本轮对 `docs/DARK_THEME_PARITY_LEDGER_20260920.md` 的修改（共 26 增 / 14 删）：

| 位置 | 改动 |
|---|---|
| `§一` 结论段（原第 26 行） | 追加「2026-11-21 回销核实（R43）」段：说明 11 屏全量 + 1 屏部分已回销、30 屏真待办、证据来源目录清单 |
| `§四` 1-1 行 | ❌待补采 → ✅已补采（`kz1_home.png` + `kz9_longpress.png`）；顺带修正路径与行号：`app_navigation_bars.dart:164/176` → `navigation/app_navigation_bars.dart:262/274`（原引用行号已漂移） |
| `§四` 1-3 行 | ❌待补采 → ✅已补采（`kz1_home.png` + `materials_1101d/ref_00_launch.png`、`ref_eye_i*`） |
| `§四` 1-8 行 | ❌待补采 → ✅已补采（`ref_dark_20260920/08_book_info.png`） |
| `§四` 1-10 行 | ❌待补采 → ✅已补采（`ref_dark_20260920/10_reader.png`） |
| `§四` 1-11 行 | ❌待补采 → ✅已补采（`ref_dark_20260920/11_reader_menu.png` + `materials_1031b/35~39_kz_*`） |
| `§四` 1-13 行 | ❌待补采 → ✅已补采（`ref_dark_20260920/13_search_content.png`） |
| `§四` 2-1 行 | ❌待补采 → ✅已补采（`kz6_settings_night.png`） |
| `§四` 2-3 行 | ❌待补采 → ✅已补采（`kz8b.png`） |
| `§四` 2-4 行 | 维持 ❌，追加核实说明（`kz8b.png` 为 chips 型源，非下拉型源，不能替代） |
| `§四` 2-8 行 | ❌待补采 → ✅已补采（`ref_dark_20260920/09_source_editor_qr_dialog.png`） |
| `§四` 2-10 行 | ❌待补采 → 🔄部分已补采（Web 服务 ✅ / RSS 源二级页 ❌） |
| `§四` 3-1 行 | ❌待补采 → ✅已补采（`materials_1105/ref_kazusa_my_*.png` + `kz9_longpress.png`） |
| `§四` 3-5 行 | ❌待补采 → ✅已补采（`ref_dark_20260920/05_theme.png` + `ref_dark_20260921/04_appearance_clean_dark*`） |
| `§五` B-1 行 | 「本台账 42 屏 ❌待补采 + 3-4 复验 + 3-5」→「30 屏 ❌待补采 + 2-10 部分 + 3-4 复验」，并注明 P1/P2 七屏中 6 屏已在 `ref_dark_20260920` 采到单套 |
| `§六` 执行记录末尾 | 追加 2026-11-21 回销核实条目（11 屏逐条列证据、30 屏待办清单、口径说明：`materials_1031c/1031d/1031e`、`1101e/1102/1104*/1107/1109a/1110d` 等深色图为**我方**证据不计入参考侧） |

未改动：`SCREEN_1TO1_PARITY_LEDGER_20260914.md`（该台账为浅色 1:1，与 R43/R44 无关）、`REMAINING_WORK_INVENTORY_20261120.md`（本轮仅核实，未回写——建议主代理据本报告关闭 R43/R44 两行）、`REFACTORING_ACTIVE_PLAN.md`（L849/L893 原文保留，作为历史记录）。

---

## 五、给下游的可执行建议

1. **R43 剩余 30 屏**：需参考版（`io.legato.kazusa`）设备逐屏补采深色截图，归档到 `docs/parity_shots/ref_dark_<YYYYMMDD>/`。建议按「高频优先」分三波：①批1 剩余 10 屏（首页/溢出菜单/批量多选/搜索/结果页/目录/长按菜单/书签页签/章节跳转/自动翻页）；②批2 剩余 6 屏（其中 2-10 RSS 二级页受「参考侧订阅无源」硬阻塞，宜沿用「双基准裁决」以原版为视觉基准）；③批3+批4 剩余 14 屏。
2. **R43 已回销 11 屏可直接进入比对**：`ref_dark_20260920` 的 6 屏（1-8/1-10/1-11/1-13/2-8/3-5）已有我方配对（`ours_dark_20260920/` + `DARK_DELTA_20260920.md` 8 组差分），可直接用于 B-2/B-3/B-4/B-5 四项裁决；1-1/1-3/2-1/2-3/3-1 尚需我方同条件深色配对采图。
3. **R44 可整项关闭**：`REMAINING_WORK_INVENTORY_20261120.md:76` 的「2~3 天 / 偏离原版需用户确认」应改为「已完成（批23，2.0.399+400）」。若保留条目，仅需在台账 ③ 处补一句「批23b 归因修正：防御性加固，无用户可见缺陷」。
4. **证据卫生**：`docs/materials_1301/evidence/kz2/kz3/kz4/kz5/kz7/kz7b/kz7d/kz7e/kz8_other_tab.png` 命名与实际内容不符（详见 §2.5），且 `P43_WAVE1_DEVICE_QA_20260929.md:122-127` 的对应描述失实。建议重采或改名，并修正该报告段落——本轮未动（属报告纠错，非本次授权范围）。
