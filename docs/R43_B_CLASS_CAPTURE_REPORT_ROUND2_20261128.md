# R43 B 类补采报告（第 2 轮）—— 我方 1-12 + 参考版 1-15 / 1-16

- 日期：2026-11-28
- 设备：MuMu 实例 0「Test2」，adb `192.168.100.63:5555`（Android SDK 35，1080x1920 @480，`uid=2000(shell)` 非 root/无 su）
- 包版本（实测）：
  - 我方 `io.legado.flutter_legado` = 2.0.514（versionCode 515）
  - 参考版 `io.legato.kazusa` = 3.26.19（versionCode 18759）
- 产物目录：`docs/parity_shots/r43_b_class_20261124/`
- 三项结果概览：**任务 A ✅ / 任务 B ✅ / 任务 C ✅**（均为实机真采，非回填）

---

## 〇、本轮新发现的环境陷阱（后续采集必读）

### 0.1 logical display → physical uniqueId 不能按 `SurfaceFlinger --display-id` 的顺序取

`adb shell dumpsys display`（`mViewports`）给出的权威映射（本次实测）：

| logical displayId | uniqueId | 名称 / port | 本次用途 |
|---|---|---|---|
| 0 | `4619827820427265280` | mumuscreen000 / 0 | 桌面 |
| 2 | `4619827767814508545` | mumuscreen001 / 1 | 我方应用窗口 |
| 3 | `4619826888814064386` | mumuscreen002 / 2 | 参考版窗口 |

- **错误做法**：把 `dumpsys SurfaceFlinger --display-id` 输出里的 “HWC display N” 当作 logical id 去 `screencap -d`。
  实测对 logical 2 用 HWC display 2 的 uniqueId 截图，得到 **12504B 全黑 PNG**（IHDR 1080x1920 正常、体积 >1KB，**不会被 "<1024B 失败" 规则拦住**，属静默错采）。
- **正确做法**：先 `dumpsys window windows` 逐 `Window #n` 块取目标包的 `mDisplayId=`，再 `dumpsys display | grep "displayId=<N>, uniqueId="` 取 uniqueId，用于 `screencap -p -d <uniqueId>`。
  `input -d <logicalId>` / `uiautomator dump --display <logicalId>` 仍用 logical id。

### 0.2 其他工具坑

- 本环境 `adb` 不在 PATH，必须用 MuMu 自带：`"/d/Program Files/MuMuPlayer/nx_main/adb.exe"`。
- Git Bash 会把 `/sdcard/...` 改写成 Windows 路径，所有 adb shell/pull 命令需 `export MSYS_NO_PATHCONV=1`；`adb pull` 的本地目标要写 Windows 路径（`D:/...`），写 `/d/...` 会报 No such file。

---

## 一、任务 A：我方 1-12 正文长按菜单（当前版本）

### 1.1 路径与操作

1. `am force-stop` + `am start -n io.legado.flutter_legado/io.legado.flutter.MainActivity`
2. 书架页（已默认停在「书架」tab）→ 点书籍卡 `big_gbk_cn`（`input -d 2 tap 188 1035`）→ 进入正文
3. 长按 `input -d 2 swipe 540 400 540 400 800` → 拖拽 `input -d 2 swipe 540 400 780 640 700`
4. 浮条出现后截图 + dump；再横向滑动浮条 `input -d 2 swipe 700 300 200 300 1500` 逐项露出后续动作

### 1.2 结论：浮条实际显示几项、分别是哪些

**初始形态（长按后原样，未滚动）：**

| 序 | 项名 | dump content-desc | bounds | 说明 |
|---|---|---|---|---|
| 1 | 复制 | 复制 | [36,208][165,382] | |
| 2 | 分享 | 分享 | [168,208][297,382] | |
| 3 | 浏览器 | 浏览器 | [300,208][463,382] | |
| 4 | 朗读 | 朗读 | [466,208][595,382] | |
| 5 | 书签 | 书签 | [598,208][727,382] | |
| 6 | 笔记 | 笔记 | [730,208][792,382] | **被滚动视口裁切，截图里只看到「笔」，实为「笔记」** |
| — | 更多 | 更多 | [795,208][924,382] | 固定项（打开旧版段落面板） |
| — | 管理选择菜单（齿轮） | 管理选择菜单 | [924,235][1044,355] | 固定项 |

即：**一次可见 6 个一级动作（第 6 项「笔记」半裁切）+ 「更多」+ 齿轮 = 8 个可点节点**；不是 10 项平铺。

**横向滑动浮条后（scroll 末端）额外露出：**

- 朗读 / 书签 / **笔记（完整）** / 字典 / 替换 / 编辑 / **全文搜索** / 更多 / 齿轮

**配置层完整一级项共 10 个**（与 `flutter_legado/lib/src/models/selection_menu_config.dart` 的 `implemented` 集合一致，默认 `showState=0` 全一级）：

```
复制 / 分享 / 浏览器 / 朗读 / 书签 / 笔记 / 字典 / 替换 / 编辑 / 全文搜索
```

> 关键判定：台账旧图 `ours_2.0.260/12_reader_longpress.png` 的 6 项（复制/分享/浏览器/朗读/书签/更多）确实过时——当前版本是 **10 个一级动作 + 横向滚动视口** 的实现（`ReaderSelectionToolbar` 用 `SingleChildScrollView` 承载一级动作，`更多` 与齿轮固定在滚动区外）。所以「浮条应显示 10 项」的说法需修正为「配置 10 项、同屏最多 6 项、余项横滑可达」。

### 1.3 逐项回答任务问题

- **浮条实际显示几项？** 初始 6 个一级动作（第 6 项裁切）+ 更多 + 齿轮；横滑后可见全部 10 个一级动作。
- **「笔记」项在不在？** **在**。默认一级第 6 位，初始视口被裁到只剩「笔」一个字（bounds 宽 62px，正常项约 129px），轻微横滑即完整显示。
- **是否有末项「更多」或齿轮？** **两者都有**：`更多`（`Icons.more_horiz`，打开旧段落面板）+ `管理选择菜单`（齿轮，打开 `textSelectMenuConfig` 三态配置表）。
- **有没有可见的选中文本高亮（灰块）+ 上下手柄？** **没有**。逐行像素检测：正文背景采样为纯白 `(255,255,255)`，全图唯一的灰色带在 y≈220–400（即浮条本体），正文区无灰色选区块、无手柄。原因是当前实现为「长按段落 → 浮出工具条，动作作用整段」（`ReaderSelectionToolbar`），正文是分页渲染的 Text 而非 SelectableText，不产生原生选区。

### 1.4 证据

| 文件 | 字节 | IHDR | dump 节点 | 根节点 package |
|---|---|---|---|---|
| `docs/parity_shots/r43_b_class_20261124/ours_1-12_long_press_menu.png` | 357913 | 1080x1920 | — | — |
| `docs/parity_shots/r43_b_class_20261124/ours_1-12_long_press_menu.xml` | 12140 | — | 23 | **io.legado.flutter_legado** ✅ |
| `docs/parity_shots/r43_b_class_20261124/ours_1-12_long_press_menu_scrolled.png` | 356623 | 1080x1920 | — | — |
| `docs/parity_shots/r43_b_class_20261124/ours_1-12_long_press_menu_scrolled.xml` | 12141 | — | 23 | **io.legado.flutter_legado** ✅ |

- 补充帧 `*_scrolled.*` 为同一浮条横滑到末端的状态，仅用于证明「字典/替换/编辑/全文搜索」确实存在（否则单张初始帧无法反证 10 项）。如台账只收单帧，以 `ours_1-12_long_press_menu.*` 为准。
- logical display = 2；physical uniqueId = `4619827767814508545`。

---

## 二、任务 B：参考版 1-15 章节跳转（深色）

### 2.1 尝试记录（含失败路径）

| # | 动作 | 结果 |
|---|---|---|
| 1 | 点右下进度文字 `input -d 3 tap 960 1875` | ❌ 被当作翻页（10/15 → 11/15），**仍在阅读器**（未退出，仅是翻页） |
| 2 | `input -d 3 keyevent MENU` | ✅ 唤出阅读菜单（返回/离线缓存/刷新章节/换源/更多操作 + 全文搜索/自动翻页/目录/朗读/设置 + 亮度/上一章/进度/下一章） |
| 3 | 菜单内点「目录」 | ⚠️ 打开的是**底部工作表式目录**（信息/目录/书签/笔记 + 章节列表），**无 FAB、无底部进度条+上下箭头** |
| 4 | 目录内「更多菜单」(984,927) | ❌ 仅「一键缓存 / 更新目录」，无跳转 |
| 5 | 阅读菜单「进度」滑杆行 | 未作为入口（是 seekbar 行，非跳转面板） |
| 6 | 返回书架 → 长按书籍 → **书籍详情页**「查看目录」 `tap 414 1151` | ✅ 打开**全屏目录**，右下出现 FAB「菜单」 |
| 7 | 点 FAB `tap 948 1788` | ✅ 展开跳转菜单：**定位至当前阅读 / 移至顶部 / 移至底部 / 一键缓存 + X** |

> 与台账口径对齐：参考版 1-15 的正确形态是「**全屏目录页 + 右下 FAB 展开式跳转菜单**」（与 `UI_SCREEN_DIFF_INVENTORY_20260907.md` 记载一致），而不是任务说明里预期的「底部进度栏 + 上↑下↓箭头」——后者是我方 `ours_2.0.256/15_chapter_jump.png` 的形态。参考版 3.26.19 的目录有两种入口：阅读器菜单「目录」= 底部工作表（无 FAB）；书籍详情「查看目录」= 全屏目录（有 FAB）。

### 2.2 证据

| 文件 | 字节 | IHDR | dump 节点 | 根节点 package |
|---|---|---|---|---|
| `docs/parity_shots/r43_b_class_20261124/1-15_chapter_jump_dark.png` | 196898 | 1080x1920 | — | — |
| `docs/parity_shots/r43_b_class_20261124/1-15_chapter_jump_dark.xml` | 33002 | — | 93 | **io.legato.kazusa** ✅ |

- dump 关键节点：`定位至当前阅读` [619,1020][960,1092]、`移至顶部` [765,1200][960,1272]、`移至底部` [765,1380][960,1452]、`一键缓存` [765,1560][960,1632]、`菜单`(FAB) [918,1758][978,1818]。
- logical display = 3；physical uniqueId = `4619826888814064386`；深色由 `cmd uimode night yes` 保证（截图亮度均值 <30，纯深色）。

---

## 三、任务 C：参考版 1-16 自动翻页（深色）

### 3.1 路径

1. 正文页 `input -d 3 keyevent MENU` → 点「自动翻页」`tap 264 432`
2. 自动翻页启动后**点正文中心** `tap 540 960` → 弹出参考版自动翻页控制面板（`AutoReadDialog`）
3. 截图 + dump
4. 采完点面板「停止」`tap 540 1740` 退出自动翻页（已确认回到纯正文）

### 3.2 参考版实际形态（与我方不同）

面板内容（dump 实测）：

| 元素 | 文案/参数 | bounds |
|---|---|---|
| 标题 | 自动翻页速度 | [180,1224][888,1296] |
| 当前速度 | 自动翻页速度 10s | [359,1362][721,1428] |
| 滑杆 | 自动翻页速度 / 10s / 减小 / `10` / 增大 | [84,1482][975,1591] |
| 动作 | 目录 / 停止 / 设置 | 行 y≈1704–1872 |

- **参考版没有我方那种底部胶囊**（「自动翻页 — 10 秒 + ｜ ☰ ◉ 退出」）；它的控制界面是 **底部 AutoReadDialog：速度滑杆 + 目录/停止/设置**，且阅读菜单同屏可见（kazusa 行为）。
- 自动翻页运行时正文上会有一条强调色细线（`AutoPager.onDraw` 画的翻页进度线），截图抓到了该线；这不是控制条。
- 运行态验证：两次间隔取帧，页码 `7/15 → 8/15`、`11/15 → 12/15`，确认自动翻页确实在推进；停止后回到纯正文（dump 11 节点）。
- **dump 可断言**：61 节点，所有控制项均在 a11y 树内，非「自绘浮层无 dump」场景。

### 3.3 证据

| 文件 | 字节 | IHDR | dump 节点 | 根节点 package |
|---|---|---|---|---|
| `docs/parity_shots/r43_b_class_20261124/1-16_auto_flip_dark.png` | 355066 | 1080x1920 | — | — |
| `docs/parity_shots/r43_b_class_20261124/1-16_auto_flip_dark.xml` | 21547 | — | 61 | **io.legato.kazusa** ✅ |

- logical display = 3；physical uniqueId = `4619826888814064386`；深色 `cmd uimode night yes`。

---

## 四、清理与恢复

- `cmd uimode night auto` → 实测回读 `Night mode: auto`
- `am force-stop io.legato.kazusa`、`am force-stop io.legado.flutter_legado`
- 删除 `/sdcard/d_ours.xml`、`/sdcard/d_ref.xml`、`/sdcard/t1.png` 及 `/sdcard/*.xml`
- 探测帧全部留在 `.tmp/qa_r43/`（`.gitignore` 已忽略 `.tmp/`），未入库；正式目录只新增 `1-15_*` / `1-16_*` / `ours_1-12_*` 八件。

---

## 五、给台账的结论

1. **1-12（我方）**：旧证据（6 项浮条）已过时。应更新为「10 个已实现一级动作，浮条同屏 6 项 + 横滑可达，另含更多+齿轮，无原生选区高亮/手柄」。
2. **1-15（参考）**：已补到深色实机帧，形态为全屏目录 + FAB 展开跳转菜单（定位至当前阅读/移至顶部/移至底部/一键缓存 + X）。
3. **1-16（参考）**：已补到深色实机帧，形态为底部 AutoReadDialog（自动翻页速度 + 目录/停止/设置），无胶囊形态。
