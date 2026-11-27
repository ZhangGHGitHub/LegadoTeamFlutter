# R43 B 类 1-12 正文长按菜单 · 参考版深色采集报告（2026-11-24）

> 采集执行：QA 子代理（原任务书覆盖 1-12 / 1-15 / 1-16，因模型路由冷却中断，仅完成 1-12）
> 整理与提交：主代理 ｜ 2026-11-24

## 一、结果摘要

| 项 | 值 |
|---|---|
| 是否采到 | **是（深色态）** |
| 参考版版本 | `io.legato.kazusa` 3.26.19 |
| 设备 | MuMu 实例 0「Test2」，端点 `192.168.100.63:5555`（当次实测） |
| 根节点 package | `io.legato.kazusa`（dump 反证通过） |
| 截图尺寸 / 字节 | 1080×1920 / 340,044 B |
| 灰度均值 | 32.2（深色确认） |
| dump 节点数 | **11**（浮条未进 a11y 树） |
| 断言状态 | **可截图无 dump 断言**，需人工核图 |

## 二、证据文件

| 文件 | 说明 |
|---|---|
| `docs/parity_shots/r43_b_class_20261124/1-12_long_press_menu.png` | 深色态正文长按浮条 |
| `docs/parity_shots/r43_b_class_20261124/1-12_long_press_menu.xml` | 同帧 dump（11 节点，仅正文，浮条未进树） |

三层校验全部通过：>1024B ✅ / IHDR 1080×1920 ✅ / dump 根包 `io.legato.kazusa` ✅ / 灰度均值 <90 ✅。

## 三、采到的浮条形态（人工核图）

深色态浮条为**粉底圆角胶囊**，横排 **7 项**：

```
复制   分享   浏览器   朗读   书签   笔记   ⚙
```

- 前 6 项带图标（复制/分享/浏览器/朗读/书签/笔记）
- 第 7 项为齿轮图标（设置），与前面 6 项之间有竖分隔线
- 选中文本为**灰色半透明高亮块**，段首尾各有一个**蓝色圆点手柄**（上下各一）
- 正文背景浅绿色（主题色），底栏「重生高考前99天　2/15 0.1%」

## 四、与既有参考版基线（0913/0914）的版本差异

| 采集时点 | 参考版版本 | 第 6 项 | 第 7 项 |
|---|---|---|---|
| 2026-09-14（`ref_20260914/12_reader_longpress.png`） | 3.26.x 早期 | **字！** | ⚙ |
| **2026-11-24（本帧）** | **3.26.19** | **笔记** | ⚙ |

**结论：参考版自身在两个版本间把第 6 项由「字！」改成了「笔记」。** 本帧（3.26.19）才是当前 1:1 基线，0914 旧图不应再作为对齐目标。

## 五、与我方的 1:1 对比 —— ⚠️ 已于 2026-11-28 自查撤销

> **本节初版（2026-11-24）的「三项已确认差异」结论作废，原因如下。**

初版对照的是 `docs/parity_shots/ours_2.0.260/12_reader_longpress.png`。经自查：

- 该图拍摄于 **2026-09-14**（2.0.260 版本期）
- 而选择菜单配置模型 `flutter_legado/lib/src/models/selection_menu_config.dart` 是 **批4c（2026-11-04）** 才引入的
- **旧图显示的「6 项 + 更多」是批4c 之前的实现**，不能作为与参考版 3.26.19 对比的基线

### 当前实现的代码事实（可复核）

`SelectionMenuIds.implemented`（`selection_menu_config.dart:56-67`）有 **10 项**：

```
复制(menu_copy) / 分享(menu_share_str) / 浏览器(menu_browser) / 朗读(menu_aloud)
/ 书签(menu_bookmark) / 笔记(menu_mark) / 字典(menu_dict) / 替换(menu_replace)
/ 编辑(menu_edit) / 全文搜索(menu_search_content)
```

默认 `showState=0`（`SelectionMenuConfig.defaults()`）表示**全部一级展开**。
另有 4 项（`menu_ai_clean` / `menu_ai_rewrite` / `menu_insert_bgm_before` / `menu_insert_bgm_after`）保留 id 与配置但**未实现、默认不渲染**。

**结论：「笔记」项并不缺失**——`menu_mark` 与参考版 `R.id.menu_mark` 同名同 id，标签就是「笔记」。

### 参考版的完整能力面（源码依据）

`legado-with-MD3/app/.../ui/book/read/ReadBookController.kt:2153-2192` 的 `getActionMenuItems()`：

- **14 项内置**：复制 / 分享 / 浏览器 / 朗读 / 书签 / 笔记(menu_mark) / 字典 / 替换 / 编辑 / **AI 净化** / **AI 改写** / 全文搜索 / **插入 BGM（前）** / **插入 BGM（后）**
- 另有**第三方 `ACTION_PROCESS_TEXT` 项**（动态发现，数量随设备安装应用变化）
- 全部项经 `textSelectMenuConfig`（`{id, enabled, showState}` JSON）可配置为「一级 / 折叠 / 隐藏」

**所以参考版截图里的 7 项是用户配置的子集，不是全部内置项。**

### 待实测确认项（采到 2.0.514 实机图前不下定论）

| 项 | 说明 |
|---|---|
| 我方浮条实际显示几项、顺序如何 | 按默认配置应为 10 项；实际受用户配置影响 |
| 我方是否有可见的选中文本高亮 + 手柄 | 需实机确认（可能是渲染差异、也可能是截图时机） |
| 我方 AI 净化/改写、插入 BGM 是否缺失 | 代码上已保留 id 但 `implemented` 不含——属**待排期功能**，非本屏缺陷 |
| 我方无第三方 PROCESS_TEXT 项 | 代码注释明示「PROCESS_TEXT 第三方项本批不做」——属**已知未实现** |

## 六、未完成项（如实登记）

| 屏 | 状态 | 原因 |
|---|---|---|
| **1-15 章节跳转** | **未采** | 子代理因模型路由冷却中断。已探明的障碍：参考版点正文 (540,960) 会被当作翻页并退出阅读器，需从屏幕边缘或底栏唤出菜单；`input keyevent MENU` 待试 |
| **1-16 自动翻页** | **未采** | 同上 |

**1-15/1-16 的浅色侧我方证据均已存在**（`ours_2.0.256/15_chapter_jump.png`、`ours_2.0.260/16_auto_flip.png`），仅参考侧深色缺失。

## 七、设备状态恢复

采集结束后已执行：`cmd uimode night auto`、`am force-stop io.legato.kazusa`、清理 `/sdcard/*.xml`。

## 八、复现要点（供后续补采复用）

1. **logical display id 在会话内持续漂移**（本轮另一条线观测 3→4→5→8→9→10→11→12→15→17→18），每次操作前必须重探；`dumpsys window | grep mCurrentFocus` 会命中多个 display 段落（含已销毁的），应从 `dumpsys window windows` 里定位含 `io.legato.kazusa` 的 `Window #` 行再取其 `mDisplayId=`。
2. **长按必须产生文本选区**（灰块 + 手柄）浮条才会出现，单纯「按住不放」不够。
3. **截图必须用 physical uniqueId**（`dumpsys SurfaceFlinger --display-id`），用 logical id 会返回 `Status: -2` 并产出 56B 空文件。

---

编写：主代理 ｜ 2026-11-24
