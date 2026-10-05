# 目录页状态图标触控尺寸实测报告（参考版 / 原版 / 我方）

- 日期：2026-10-05（调研执行日；文件名按任务要求取 20261005）
- 性质：只读调研，未修改任何项目文件
- 结论先行：**"参考版触控约 32dp"不成立——实测参考版命中区 = 视觉 24dp（裸 Box + combinedClickable，无 48dp 强制）**；原版命中区 48dp 但动作只是"打开章节"（TouchDelegate 外扩）；我方命中区被 IconButton shrinkWrap 显式收缩到 16×16，是三方最小。数据支持把命中区从 16 提到 24 对齐参考版，不建议上 48。

---

## 1. 参考版（D:\OH-WorkSpace\LegadoTeam\legado-with-MD3）

### 1.1 控件类型：裸 Box + combinedClickable，不是 IconButton

`app/src/main/java/io/legado/app/ui/book/toc/TocScreen.kt:952-979`（ChapterItem 行尾状态元素）：

- 外层 `Box(modifier = Modifier.padding(start = 8.dp).wrapContentSize().clip(MaterialTheme.shapes.medium).then(...))`
- 仅当 `canDownload` 时挂 `Modifier.combinedClickable(role = Role.Button, onClick = onDownloadClick)`（:958-966）；否则 `clearAndSetSemantics`（:968）。
- `canDownload = downloadState == NONE || downloadState == ERROR`（:879-880）。
- **无 `IconButton`、无 `minimumInteractiveComponentSize`**。全库检索 `minimumInteractiveComponentSize` 仅两处使用（`ui/book/source/manage/BookSourceScreen.kt:272`、`ui/widget/components/button/series/SeriesIconButton.kt:124`），目录行未用。

Compose Material3 的 48dp 最小交互区强制（`LocalMinimumInteractiveComponentEnforcement`）只作用于 Material 组件（IconButton/Button 等）内部；裸 foundation `combinedClickable` 不经过该强制。因此：

> **参考版命中区 = 视觉尺寸 = 24×24dp**（NONE ⬇ / ERROR 红刷新两态）。"约 32dp"的说法在代码中无出处，判为误传。

### 1.2 StatusIcon 各态视觉尺寸（TocScreen.kt:1148-1241）

| 态 | 内容 | 尺寸 | 行号 |
|---|---|---|---|
| NONE（else 分支） | `Icons.Outlined.DownloadForOffline`，outline 色 alpha 0.5 | **24dp** | :1231-1238 |
| ERROR | `Icons.Default.Refresh`，error 红 | **24dp** | :1222-1228 |
| SUCCESS_ICON | `Icons.Default.CheckCircle`，secondary 色 | 24dp | :1213-1219 |
| DUR | `Icons.Rounded.LocationOn`，secondary 色 | 24dp | :1181-1187 |
| LOADING | AppContainedLoadingIndicator | 20dp | :1190-1193 |
| EMPTY | 空占位 Box | 24dp | :1177-1178 |
| SUCCESS_WORD_COUNT | 字数胶囊：NormalCard r12 + 文字 9sp，padding h8/v4 | 内容自适应 | :1196-1210 |

### 1.3 行内几何

- 状态元素与标题列间距：`padding(start = 8.dp)`（:954）。
- 行水平 padding：`adaptiveHorizontalPadding(vertical = 16.dp)`（:906）→ M3 引擎 16dp / Miuix 引擎 12dp（`ui/theme/AdaptivePadding.kt:25-30, 12-15`）。状态元素右缘 = 距屏缘 16dp（M3 引擎）。
- 行高：wrap（标题最多 2 行 + tag 行），无固定 48dp。

---

## 2. 原版（D:\OH-WorkSpace\LegadoTeam\legado\app\）

### 2.1 布局尺寸

`app/src/main/res/layout/item_chapter_list.xml`：

- 行根：`minHeight 48dp`、`padding 12dp`（:9, :11）。
- 行尾 `end_actions` FrameLayout：**24×24dp**，约束在行右缘（:83-89）。
- `iv_checked`：match_parent（=24dp）、`padding 4dp` → **可见字形 16dp**、tint secondaryText（:91-101）。前期线索（24dp、tint、padding 4dp）属实。

### 2.2 点击行为：有 TouchDelegate，但动作不是"下载"

`app/src/main/java/io/legado/app/ui/book/toc/ChapterListAdapter.kt`：

- `endActions.setOnClickListener`（:300-308）：卷行可切换 → `onVolumeToggled`；**普通章节 → `openChapter`（与行点击等价，无独立下载语义）**。普通章节行 endActions 不可聚焦、无 contentDescription（:265-268）。
- `expandEndActionTouchTarget`（:317-325）：`getHitRect` 后 `bounds.inset(-12dp, -12dp)` 设 TouchDelegate → **命中区 24 + 12×2 = 48×48dp**。
- `upHasCache`（:343-351）：未缓存章显示 `ic_outline_cloud_24` 云朵，当前章显示 `ic_check` 对勾；已缓存非当前章不显示。**原版行尾没有"下载中/失败"图标，也没有单章下载按钮**（下载由目录菜单整本/选段发起）。

> 结论：原版"无可点击下载图标"的前期结论**半对**——无独立下载动作，但 24dp 图标经 TouchDelegate 有 48dp 命中区（动作=打开章节）。它不构成"下载按钮需 48dp 命中"的先例。

---

## 3. 我方（D:\OH-WorkSpace\LegadoTeam\legado\flutter_legado\lib\src\screens\toc_screen.dart）

### 3.1 可点击两态：IconButton 被显式收缩到 16×16

- NONE ⬇（:1216-1231）：`IconButton(icon: Icon(Icons.download_for_offline_outlined, size: 16), iconSize: 16, visualDensity: VisualDensity.compact, padding: EdgeInsets.zero, constraints: BoxConstraints(minWidth: 16, minHeight: 16), tapTargetSize: shrinkWrap)` → **命中区恰 16×16**（Flutter IconButton 默认 48dp 命中，被 constraints+shrinkWrap 显式覆盖）。
- ERROR 红 Refresh（:1193-1204）：同参数 → **16×16**。
- 注释（:1190-1192）自述"shrinkWrap 保持 16px 图标几何（P2-28/29 行高适配口径）"，是有意决策。

### 3.2 不可点各态（裸 Icon/Container，不涉及命中区）

- 字数胶囊：Container padding h6/v2、radius 8、fontSize 8（:1151-1172）；与参考版胶囊（r12、9sp、h8/v4）有细节差，非本次议题。
- 当前章定位 Icon 16（:1176）；LOADING 16（:1179-1186，参考版为 20dp）；已缓存对勾 Icon 16（:1209，参考版 24dp）。

### 3.3 行几何约束

- `ListTile(dense: true, contentPadding: EdgeInsets.symmetric(horizontal: 8))`（:1237-1252）；列表 `itemExtent: _chapterRowExtent = 48`（:99, :1045）。
- 注释（:1246-1251）记录过一次回归：contentPadding.vertical 12 曾把 16px ERROR 图标中心点挤出可命中带，导致 tester.tap 失败，故 vertical 取 0。**改动命中区时图标中心必须不动。**

---

## 4. 三方对比表

| 维度 | 参考版 (MD3 快照) | 原版 (app/) | 我方 (flutter_legado) |
|---|---|---|---|
| 图标视觉尺寸（NONE/ERROR） | **24dp**（LOADING 20dp） | 容器 24dp（字形 16dp） | **16px** |
| 触控命中区（可点态） | **24×24dp**（=视觉，裸 clickable） | **48×48dp**（TouchDelegate，但动作=打开章节，非下载） | **16×16px**（shrinkWrap 显式收缩） |
| 控件类型 | 裸 Box + combinedClickable（非 IconButton，无 48dp 强制） | ImageView + TouchDelegate（非按钮） | IconButton（默认 48 被覆盖为 16） |
| 可点击语义 | NONE/ERROR → onDownloadClick（独立下载/重试） | 无独立下载动作 | NONE/ERROR → _downloadChapter（独立下载/重试） |
| 状态元素右缘 | 距屏缘 16dp（M3 引擎） | 距屏缘 12dp | 距屏缘 8dp |

---

## 5. 建议

**改（数据依据：我方 16×16 是三方最小；参考版 24dp，比我方面积大 2.25 倍；原版虽 48 但动作等同行点击，不足以支撑 48 的产品先例）。**

### 推荐方案：视觉 16 不动，命中框 16 → 24（对齐参考版）

对 `toc_screen.dart` 两处 IconButton（ERROR :1198、NONE :1225）：

- `constraints: const BoxConstraints(minWidth: 24, minHeight: 24)`（原 16,16）；
- `padding: EdgeInsets.zero` 保留（24 框内 16 图标居中，每边 4px 容差）；`visualDensity.compact`、`tapTargetSize: shrinkWrap` 保留（shrinkWrap 下最终尺寸 = constraints = 24×24）。

### 影响面评估（逐项）

1. **行高不被撑破**：24×24 < 行高 48（itemExtent，:99），dense ListTile trailing 不会被撑高；trailing 垂直居中，图标中心不动 → P2-28/29 居中口径与既有 tester.tap（打图标中心）不受影响。
2. **水平几何**：trailing 右缘由 contentPadding 固定（:1252），命中框只向左扩展 8px，标题可用宽度 -8px（单行 ellipsis 可吸收，无需改标题约束）。
3. **与胶囊/定位图标共存**：状态元素为互斥分支（:1145-1148，①~⑦ 至多一个），胶囊与裸 Icon 非 IconButton，不受本次改动影响。
4. **可选对齐项（非必需）**：参考版状态元素右缘为屏缘 16dp、与文本列间距 8dp；我方右缘 8dp。若追求完全对齐可把 contentPadding 尾部调至 16，但这会动整行右缘几何（影响所有行、含胶囊行），建议单独立项评估，不与本次混做。
5. **不建议直接上 48dp**：参考版未做 48（裸 clickable 即 24）；48×48 trailing 等于整行高，ListTile 垂直空间被占满，有重蹈 P2-29"图标中心被挤出命中带"回归的风险（:1246-1251 注释记录）；且原版 48dp 的动作语义是"打开章节"，不构成"下载按钮 48dp"依据。
6. **回归验证**：改后跑目录页现有 widget 测试（重点 ERROR 重试 / NONE 下载两分支的 tap 命中），并核对字数胶囊行的行高与对齐无变化。

### 明确标注

- 参考版 24dp 命中区为源码直接读出（Box wrapContentSize + clickable），非运行时实测；"32dp"无代码出处。
- 原版 48dp 来自 TouchDelegate inset(-12dp)（ChapterListAdapter.kt:317-325），源码直接读出。
- 我方 16×16 由 IconButton 参数推算（constraints 16 + padding 0 + shrinkWrap），Flutter 框架语义确定。
