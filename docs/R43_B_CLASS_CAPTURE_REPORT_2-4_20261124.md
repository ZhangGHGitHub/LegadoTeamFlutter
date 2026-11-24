# R43 B 类参考版补采报告 — 2-4 发现源二级页（下拉选择器型源）

- 采集日期：2026-11-24
- 采集人：QA 子代理
- 设备：MuMu 实例 0（Test2），guest IP `192.168.100.63`，adb `192.168.100.63:5555`
- 参考版：`io.legato.kazusa`（Android 15 / 1080x1920 @480）
- 权限：`uid=2000(shell)`，非 root、无 su；`run-as` 不可用（`package not debuggable`）→ **全程未写库、未注入源**
- 结论：**深色态采到**（下拉选择器 + 选项展开态各 1 张）

---

## 一、结论摘要

| 项 | 结果 |
|---|---|
| 是否采到 | **是（深色态）** |
| 使用的源 | `⚡📁听小说APP`（`exploreUrl` 含 `"type": "select"` 型） |
| 产出文件 | `2-4_discover_dropdown_dark.png/.xml`（下拉选择器展开态）、`2-4_dropdown_options_dark.png/.xml`（选项弹层） |
| 辅助证据 | `2-4_pre_open_dark.png/.xml`（点击前的源行定位帧） |
| 控件形态判定 | 下拉选择器（**非 chips**），见 §四 |

**重要更正**：台账与主代理曾判断「听小说APP 在当前参考版已不存在」。**该判断不成立** —— 本机实测该源存在，位于发现页源列表靠下位置（滚动至第 11 屏后出现）。此前的「找不到」是扫描器缺陷导致（见 §五），不是源缺失。

---

## 二、执行路径（可复现）

1. `adb connect 192.168.100.63:5555`
2. `cmd uimode night yes`（深色）
3. 冷启 `io.legato.kazusa`，回退至主页（底部 5 tab）
4. 点「发现」tab（540,1822）
5. 在发现页源列表**纯上滑**（540,1450 → 540,1000，900ms），逐屏 dump
6. 第 11 屏命中 `⚡📁听小说APP`，滚动至安全区（中心 y=1046 < 1400，避开底部 tab 区 y≥1724）
7. 点按 (278,1046) → 该源展开，出现三个下拉选择器
8. 截图 + dump；再点「排序 热播」→ 选项弹层出现，截图 + dump

---

## 三、设备与多显示实测数据

| 项 | 值 |
|---|---|
| 命中时 logical display id | **18** |
| 对应 physical uniqueId | `4619826980576867857` |
| 截图方式 | `adb exec-out screencap -p -d <physUniqueId>` |
| dump 方式 | `adb shell uiautomator dump --display 18 /sdcard/.parity_ref_ui.xml` |
| 输入方式 | `adb shell input -d 18 tap/swipe ...` |

**display id 在会话内持续漂移**：本轮观测到 3 → 4 → 5 → 8 → 9 → 10 → 11 → 12 → 15 → 17 → 18。每次操作前都必须重新从 `dumpsys window windows` 取真实存活窗口的 `mDisplayId`，不能缓存。

**注意**：`dumpsys window | grep mCurrentFocus` 会同时命中多个 display 段落（含已销毁的旧 display），直接取第一个会拿到错误的 id。本轮改为从 `dumpsys window windows` 中定位 `Window #` 行含 `io.legato.kazusa` 的窗口，再取其后的 `mDisplayId=`，才稳定。

---

## 四、控件形态判定依据（select 而非 chips）

依据 `2-4_discover_dropdown_dark.xml`（114 节点，根包 `io.legato.kazusa`）：

```
[48, 962, 1032, 1130] h=168  View  '⚡📁听小说APP'      ← 源行（可折叠，右侧 ˅）
[48, 1154, 1032, 1254] h=100 View '频道 男频'           ← 下拉 1
[48, 1278, 1032, 1378] h=100 View '类别 分类'           ← 下拉 2
[48, 1402, 1032, 1502] h=100 View '排序 热播'           ← 下拉 3
[48, 1526, 1032, 1628] h=102 View '关键字'              ← 文本输入框
[48, 1652, 1032, 1724] h=72  View '🔍搜全网'            ← 提交按钮
```

判定要点：

1. **整行单节点**：三个控件均为 `w=984`（48→1032）的整行宽节点，文本居中，`h=100`；chips 型控件是 `w≈312` 的三列小方块（`h=100`），两者宽度差 3 倍以上，形态完全不同。
2. **右侧有上下双箭头**：截图中三个控件右端均有 `⌃⌄` 堆叠小三角（chips 无此标记，chips 只有文字）。
3. **点击产生弹层**：点「排序 热播」后 dump 变为 15 节点、文本仅剩 `热播/评分/完本/新书/人气`，即浮层选项列表（`2-4_dropdown_options_dark.png/.xml`）。chips 点击是筛选跳转，不会产生选项浮层。
4. **同屏共存对照**：`2-4_pre_open_dark.xml`（107 节点）中，`📻听友M` 展开后是 chips 网格（`评书/单田芳/刘兰芳/田连元/…`，每个 `w≈312`），与「听小说APP」的整行下拉形成同屏直接对照 —— 这是区分 chips 与 select 最硬的证据。

---

## 五、为什么之前会误判「源不存在」（扫描器缺陷，已修正）

这是本轮最有价值的经验，供后续采集复用：

1. **行高过滤漏检**：最初用「`w>700 且 120<h<260`」筛选源行。当某个源（如 `听友M`）处于展开态时，其 chips 网格节点为 `w=312, h=100`，全部被过滤掉 → `rows()` 返回空 → 被误判为「列表到底」，从而**跳过了下方真正的源行**。修正：改用「全文本指纹」判断到底，搜索时不做尺寸过滤。
2. **下滑手势 = 下拉刷新**：为「回到列表顶部」而下滑（540,700 → 540,1500）会触发 pull-to-refresh，清空列表甚至跳回阅读器。修正：全程**只用上滑**，需要回顶时改为「切 tab 再切回」或直接不重置。
3. **上滑起点落入 tab 区**：起点 y=1500 时手势可能被底部 tab 栏接管，误切到「书架」。修正：滑动区间限制在 y∈[900,1450]。
4. **截图与 dump 短暂不一致**：页面正在加载/跳转时，dump 与 screencap 会采到不同帧。修正：每次断言前 `wait 2-3s`，并在截图前重新 dump 复核坐标。

---

## 六、与浅色参考的对照

| 侧 | 文件 | 形态 |
|---|---|---|
| 参考浅色 | `docs/parity_shots/ref_20260913/15_discover_expanded_dropdown_source.png` | 听小说APP 展开：频道 男频 / 类别 分类 / 排序 热播 + 关键字 + 搜全网 + chips 组 |
| 参考浅色 | `docs/parity_shots/ref_20260913/16_dropdown_options_open.png` | 下拉选项展开态 |
| 参考浅色 | `docs/parity_shots/ref_batch2/04_discover_expand_dropdown.png`、`05_dropdown_options.png` | 同类（旧批次） |
| **参考深色（本次）** | `docs/parity_shots/r43_b_class_20261124/2-4_discover_dropdown_dark.png` | **结构一致**：三个整行下拉 + 关键字 + 搜全网，深色配色 |
| **参考深色（本次）** | `docs/parity_shots/r43_b_class_20261124/2-4_dropdown_options_dark.png` | 选项浮层：热播/评分/完本/新书/人气 |

**明暗结构差异**：无。深色态下控件布局、文案、顺序与 0913 浅色参考完全一致，仅配色不同（卡片深灰底、选中源行高亮为暖棕色、文字米白）。

**深色配色实测值**（供我方对齐参考）：
- 页面背景：近黑（#121212 量级）
- 源卡片底：深灰（#1E1E1E 量级），圆角
- 展开中的源行：暖棕高亮（#4A3226 量级），文字为浅金/米色
- 下拉控件底：深灰，与源卡片同色系但略深
- 正文文字：米白（#E8E0DC 量级）
- 底部 tab 选中态：暖棕胶囊 + 图标反白

（以上为目视取值，未做像素采样，仅供参考。）

---

## 七、未完成/未验证项（诚实登记）

1. **未验证我方（flutter_legado）对应的深色下拉源页面** —— 本轮任务范围仅为参考版采集。
2. **未做像素级取色** —— 报告中的色值为目视估计，若需精确对齐需另做取色脚本。
3. **`频道`/`类别` 两个下拉的选项列表未采** —— 仅采了 `排序`。若对比需要，可点开另两个控件补采（同一页面，成本低）。
4. **未尝试导入含 select 的源** —— 设备 `run-as` 不可用且写库属越界，本轮完全靠 UI 操作命中已安装源，未做任何数据注入。

---

## 八、证据文件清单

| 文件 | 字节 | 尺寸 | 说明 |
|---|---|---|---|
| `2-4_discover_dropdown_dark.png` | 115387 | 1080x1920 | 下拉选择器展开态（主产出） |
| `2-4_discover_dropdown_dark.xml` | 39699 chars / 114 nodes | — | 主产出配套 dump，根包 `io.legato.kazusa` |
| `2-4_dropdown_options_dark.png` | 108373 | 1080x1920 | 下拉选项弹层 |
| `2-4_dropdown_options_dark.xml` | 5323 chars / 15 nodes | — | 选项弹层 dump |
| `2-4_pre_open_dark.png` | 118213 | 1080x1920 | 点击前源行定位帧 |
| `2-4_pre_open_dark.xml` | 37321 chars / 107 nodes | — | 定位帧 dump（含听友M chips 对照） |

全部位于 `docs/parity_shots/r43_b_class_20261124/`。

---

## 九、设备状态恢复

采集完成后执行：

```
cmd uimode night auto
am force-stop io.legato.kazusa
rm -f /sdcard/.parity_ref_ui.xml /sdcard/*.xml
```
