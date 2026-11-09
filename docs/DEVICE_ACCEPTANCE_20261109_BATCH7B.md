# 批7b「书签标记（book_marks）」设备验收报告

- 日期：2026-11-09
- 验收角色：主代理（设备验收）
- 代码基线：`19cbb2daa7`（含审查/复核回修）
- 应用版本：2.0.471+472
- APK SHA-256：`8e040fefb2a3ec9b1df9d1357b78c579b76284eb385dc88973252f8c4c5cacf6`
- 证据：`docs/materials_1109d/`（29 个文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 2.0.471（versionCode 472） |
| Rust | release + quickjs；FRB hash -1839437133；源码指纹 `b44b6172…`；`.so` 11:46 重建 |
| 测试书 | `batch7b_notes.txt`：第一章 3 段，含重复词「重复词测试」与长段 |

## 二、总体结论

- 功能验收 14 项：**PASS 14 / BLOCKED 0（未覆盖边界在 §五登记）**；**P1=1（审查中发现并回修，设备复验通过）**；**P2=0**；P3=5。
- FATAL/ANR/E.flutter/overflow/E AndroidRuntime 均为 **0**（12,068 行 logcat）。
- 设备终态：`pm clear` 后空书架、默认设置，应用可启动。

## 三、逐项结果

### A. 划词入口与编辑 Sheet

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 长按正文 → 工具栏「笔记」 | PASS | `tmp_qa7b_03.png` | 工具栏含复制/分享/浏览器/朗读/书签/笔记/更多；「笔记」文案与图标正确 |
| A2 打开笔记 Sheet | PASS | `tmp_qa7b_04.png` | 显示选中文本预览、16 色、7 效果、备注、保存；默认单实线+绿色 |
| A3 背景色效果 + 备注保存 | PASS | `tmp_qa7b_05.png`、`tmp_qa7b_06.png` | 选择橙色+背景色、备注「第一段备注」；保存后正文该段显示 20% alpha 橙色背景 |
| A4 同段再次打开自动编辑并预填 | PASS | `tmp_qa7b_07.png` | 标题「编辑笔记」、删除图标、橙色选中、背景色选中、备注回显 |
| A5 改为波浪线保存 | PASS | `tmp_qa7b_08.png` | 背景消失，该段出现橙色波浪下划线；备注更新为「第一段备注改波浪」 |
| A6 删除二次确认 | PASS | `tmp_qa7b_16.png`、`tmp_qa7b_17.png`、`tmp_qa7b_18.png` | 「删除笔记？删除后不可恢复。」→ 删除后正文标记消失、标注页空态 |

### B. 目录「标注」页

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 笔记区展示 | PASS | `tmp_qa7b_11.png` | 显示效果「波浪线」、章节「第一章 笔记」、时间、文本摘要（带下划线）、备注「第一段备注改波浪」、启用开关 |
| B2 关闭/开启即时生效 | PASS | `tmp_qa7b_12.png`、`tmp_qa7b_13.png`、`tmp_qa7b_14.png`、`tmp_qa7b_15.png` | 关闭后正文下划线消失（图标开关 off），开启后恢复并更新时间 |
| B3 删除后空态 | PASS | `tmp_qa7b_18.png` | 删除后显示「暂无标注」 |

### C. 渲染与持久化

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 背景色渲染 | PASS | `tmp_qa7b_06.png` | 第一段橙色 20% 背景，跨行按行盒渲染 |
| C2 波浪线渲染 | PASS | `tmp_qa7b_08.png` | 橙色波浪下划线覆盖整段 |
| C3 删除线渲染 | PASS | `tmp_qa7b_24.png` | 第三段绿色删除线 |
| C4 重启持久化 | PASS | `tmp_qa7b_25.png` | `force-stop` 后重开书，第三段绿色删除线仍在；空作者书可保存（P2-4 复验） |
| C5 笔记优先/与规则高亮合并 | PASS（单测/Widget） | `book_marking_merge_test.dart`、`reader_marking_render_test.dart` | 本次设备未同时配置规则高亮；区间合并与渲染由 35 项测试覆盖 |

### D. 稳定性与终态

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| D1 崩溃/ANR/overflow | PASS | `logcat_7b.txt`（12,068 行） | FATAL=0、ANR=0、E/flutter=0、overflow=0、E AndroidRuntime=0 |
| D2 设备清理 | PASS | `tmp_qa7b_26.png` | `pm clear` 后空书架，默认设置，应用可启动 |

## 四、P1 问题与回修

### P1-1 精细选区锚点用 trim 后文本 `indexOf`，重复文本必错位

- **现象**：段落内有重复词时，选第二次出现保存笔记，会落到第一次出现的位置。
- **根因**：`onSelectionChanged` 只保存选中文本、丢弃 `selection.start`；`chapterOffsetOfSelection` 用 `paragraphText.indexOf(selection)` 取第一次出现。
- **回修**：`a1c8e11769` 保存 `selection.start`，按 `(selectionStart + 前导空白 - indent).clamp(...) + paragraphChapterPos` 计算；`indexOf` 仅作无 start 回退；`_saveHighlight` 同步修复。
- **复验**：设备长按整段创建/编辑/渲染正常；重复词第二次出现的组件级用例（`SelectableText.onSelectionChanged` 注入 start，锚点 104）通过。

### 同批审查回修的 P2（均已在设备复验）

- 旧章 marks 请求失败不再清空新章（切章并发保护）。
- 加载冻结帧下笔记/高亮/书签/朗读使用分页快照章号，避免写到新章。
- 目录笔记加载失败不显示上一本书数据；高亮非空时也显示「笔记加载失败」并可重试。
- 空作者本地书可保存笔记（本次设备书「未知作者」保存成功）。
- 换源后再次保存保留原 `bookUrl`。
- 同段再次打开预填备注/样式（设备 A4 验证）。

## 五、P3 / 未覆盖边界（登记）

1. **滚动模式不渲染笔记**：沿用既有高亮边界；本轮已修其选区入口的章号/段偏移，但正文不画标记。
2. **相邻章预载预览不传笔记**（章节全局偏移口径不同，沿用批34 P3-6）。
3. **荧光（HIGHLIGHT）按整行 20% alpha 背景近似**，未复刻参考版半高荧光笔绘制。
4. **SVG 下划线（mode 5）回退单实线**，`underlineSvgPath` 不渲染。
5. **参考版「复用高亮规则/自定义取色器」未做**：当前仅 16 预设色；设备未测字体色（TEXT）效果，Widget 测试覆盖 7 效果映射。
6. **book_marks 不纳入备份**（与参考版一致）；跨设备不迁移。
7. 跨页长段落后续页的 `chapterPos` 基线偏差未改（解析器就近兜底，多数情况可显示）。
8. 设备验收未同时配置规则高亮与笔记同屏（合并逻辑由 12 项单测 + 5 项 Widget 覆盖）。

## 六、设备终态

- 应用 2.0.471+472 已安装，`pm clear` 后空书架、默认设置、可启动。
- 测试书 `batch7b_notes.txt` 仍在 `/sdcard/Download`，未在应用内保留。
- 1080x1920 / 480dpi，竖屏。

## 七、门禁（代码基线）

- flutter analyze 0；flutter test **5026 通过 + 1 skipped**；本批 format 0 changed。
- cargo fmt/clippy 0；`legado-db` 461、`legado-ffi` 693/21 ignored、quickjs 766/42 ignored。
- 契约 §2.52 5 方法/模块 49/附录 326/BookApi 324/表 B 160；契约测试 9 项。

---

编写：ZCode 主代理 ｜ 2026-11-09
