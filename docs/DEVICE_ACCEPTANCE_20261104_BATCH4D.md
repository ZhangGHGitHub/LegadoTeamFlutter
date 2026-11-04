# 批4d 设备验收报告（滑动书签 + 书签角标 + 振动收口）

- 验收日期：2026-11-04
- 验收范围：批4d「下滑添加书签 / 书签角标 / 滑动进度条震动 / 选词震动」
- 仓库 HEAD：`629e7c696f`（chore: 批4d 收尾（2.0.457+458 双日志与计划登记））
- 验收角色：设备验收代理（只测不改代码）
- 证据目录：`docs/materials_1104j/`

## 一、环境

| 项 | 值 |
|---|---|
| 设备 | MuMu 模拟器「Test测试」实例（index 1） |
| 端点 | `192.168.100.62:5555`（本次实测可用；`127.0.0.1:16416` 拒绝连接） |
| 系统 | Android 15，SM_G9900 伪装 |
| 显示 | 1080x1920 / 480dpi，竖屏（ROTATION_0） |
| 应用包 | `io.legado.flutter_legado` |
| 版本 | versionName `2.0.457`，versionCode `458`（与 `flutter_legado/pubspec.yaml` 一致） |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`（192.2 MB，14:44 构建，14:45 安装） |
| APK SHA256 | `2bf022c660bc205313f1088bd6a127ca849cf3109d4fb6f689f8fb34243b8881` |
| Rust | 本次无 Rust 改动，未重建 `.so` |

测试书（自建，已清理）：

- `batch4d_normal_20ch.txt`：20 章，约 2.87 万字符，默认分页 12 页/章；
- `batch4d_long_paragraph.txt`：单章单段 6600 字无换行，默认分页 30 页；
- `badge_test.png`：120x60，左红/中白/右蓝三段，用于 contain 判定。

## 二、逐项结果

### A. 入口与默认

| 项 | 结果 | 证据 |
|---|---|---|
| A1 阅读器「更多」页入口齐全、默认值正确 | **PASS** | `10_more_tab_scrolled.png`、`11b_more_vibrators.png` |
| A2 横竖屏可用、角标大小 0..50 可调 | **PASS** | `12_slider_50.png`、`13_landscape_settings.png`、`75_badge_size0_hidden.png` |

- A1：阅读器设置「更多」页依次可见「下滑添加书签（默认关）」「角标大小 10dp」「书签角标：默认 + 选择」「滑动进度条时震动（默认关）」「选择文本时震动（默认关）」；滑块位于 20%（10/50）。
- A2：旋转到横屏（ROTATION_90）后「更多」页正常渲染，无 RenderFlex overflow；滑块拖到 0 显示 `0dp`、拖到 50 显示 `50dp`（divisions=50 生效），恢复 10 正常。验收结束已恢复竖屏。

### B. 下滑手势

| 项 | 结果 | 证据 |
|---|---|---|
| B1 分页模式下滑 <80dp 不触发；≥80dp 提示并添加 | **PASS** | `18_short_pull_150px.png`、`23_pull_add_hint.png`、`24_bookmark_added_p3.png`、`backup_batch4d.json` |
| B2 带角标页再次下滑提示取消并只删本页 | **PASS** | `21_pull_cancel_hint.png`、`22_after_cancel_bookmark.png` |
| B3 横滑翻页/九宫格点击/长按选词正常；菜单展开下滑不触发 | **PASS** | `25_hswipe_next_p4.png`、`26_tap_left_p3.png`、`30_longpress_select.png`、`29_after_pull_menu_open.png` |
| B4 滚动模式下滑不触发；关闭开关后不触发 | **PASS** | `36_scroll_mode.png`、`39_scroll_pull_mid.png`、`40_scroll_pull_after.png`、`44_swipe_switch_off.png`、`47_pull_switch_off_after.png` |
| B5 顶栏「添加书签」落当前页页首；列表跳转；无「备注: 正文」 | **PASS** | `52_topbar_more.png`、`53_topbar_add_bookmark.png`、`56_bookmark_list.png`、`66_toc_jump_p3.png`、`backup_batch4d.json` |

- B1：短拖 150px（≈50dp）无提示、无角标；长拖 300px（≈100dp）拖动中顶部出现「松手以添加书签」，松手后角标出现。备份 JSON 中该书签 `chapterPos=237`（第 3 页页首，非 0），`bookText` 为该页首行正文。
- B2：带角标页拖动中提示「松手以取消书签」，松手后角标消失；书签总数由 1 → 0，第 1/2 页无角标。
- B3：左滑/横滑正常翻页（4/12），点击左区回第 3 页、右区前进、中心区切换菜单；长按正文弹出「复制/分享/浏览器/朗读/书签/高亮/更多」选择面板；菜单展开时下滑**未添加书签**（页面无角标、无提示）。观察到菜单展开/开关关闭时纵向拖动会被既有翻页控制器当作「下一页」，见 P3-1。
- B4：切到「滚动」模式后下拉为滚动/无书签、无提示、无角标；切回「覆盖」并关闭「下滑添加书签」后下拉不产生书签。
- B5：顶栏更多 →「添加书签」提示「已添加书签：第1章 山谷纪事之1」；目录 →「书签」Tab 点击该书签回到 3/12 页；书签列表两条新增项仅显示章节名/书名/页首正文，无「备注: 正文」（历史 qa4c 书签自带备注，按原样显示）。

### C. 角标

| 项 | 结果 | 证据 |
|---|---|---|
| C1 默认琥珀书签带几何/尺寸变化/0 隐藏 | **PASS** | `72_badge_size10_p3.png`、`74_badge_size30_clean.png`、`75_badge_size0_hidden.png` |
| C2 页眉启用时角标在正文顶；滚动模式隐藏 | **PASS** | `82_header_immersive.png`、`83_page2_header_badge.png`、`39_scroll_pull_mid.png` |
| C3 自定义图 contain、缺失回落琥珀、清除恢复默认 | **PASS** | `100_custom_badge.png`、`101_custom_p3.png`、`108_fallback_badge.png`、`110_badge_reset_default.png` |

- C1（像素实测，1080x1920 截图像素）：
  - size=10：可见琥珀区 **20x49 px** = 6.67dp x 16.33dp，符合 size×2/3 宽、size×5/6×2 高；缺口自 y=187 收窄至 y=197（约 10px/49px，含抗锯齿约 25%）。
  - size=30：可见区 **60x149 px** = 20dp x 49.7dp，缺口自 y≈272 收窄至 307（36px/149px ≈ 24.2%）。
  - size=0：全屏无琥珀像素，角标隐藏。
- C2：信息页「页眉显示=显示」+「隐藏状态栏=开」后，系统状态栏隐藏、页眉（时间/电量）出现在顶部；角标 bbox 顶部 y=119，页眉文字顶部约 y=25、正文首行顶部约 y=150 → 角标位于**正文顶**而非页眉顶。滚动模式不构建分页页，角标不显示。
- C3：选择 120x60 三段图后，角标渲染为 30x16 且逐像素保留红/白/蓝三段（BoxFit.contain，无裁切）；将备份 `bookmarkBadgeImage` 改为不存在的标识并恢复后，角标回落默认琥珀 20x49；点「恢复默认书签角标」后入口显示「默认 + 选择」。

### D. 长段落跨页

| 项 | 结果 | 证据 |
|---|---|---|
| D1 第 5 页下滑仅第 5 页有角标，chapterPos 为页首 | **PASS** | `116_long_p5_after.png`、`117~121_long_p*.png`、`backup_d1_long.json` |
| D2 第 5 页再次下滑只删该页 | **PASS** | `129_long_p5_cancel_hint.png`、`130_long_p5_deleted.png`、`131_long_bookmark_tab_empty.png` |
| D3 顶栏在第 8 页添加落第 8 页首 | **PASS** | `136_long_p8_added.png`、`backup_d3_long_p8.json` |

- D1：单段 6600 字书共 30 页；第 5 页下拉添加后，逐页像素检查第 1/2/3/4/6 页均无琥珀角标，仅第 5 页有（20x49）。备份 JSON：`chapterPos=883`（非 0、非整段 6600），`bookText` 为第 5 页首行「。他忽然想起许多年前的夏天，那」。
- D2：第 5 页再次下拉提示「松手以取消书签」，松手后角标消失；本书书签 Tab 显示「暂无书签」，第 6 页及前后页无角标。
- D3：第 8 页顶栏添加，角标出现；备份 JSON：`chapterPos=1558`，`bookText` 为第 8 页首行「信，又仔细看了一遍。信上的字迹」。

### E. 振动与持久化

| 项 | 结果 | 证据 |
|---|---|---|
| E1 进度条震动开/关不崩溃、无异常日志（体感 BLOCKED） | **PASS（体感 BLOCKED）** | `143_after_slider.png`、`logcat_full.txt` |
| E2 选词震动开：长按选词 + 拖拽手柄不崩溃（体感 BLOCKED） | **PASS（体感 BLOCKED）** | `144_select_vibrate_on.png`、`145_handle_drag.png` |
| E3 书签三字段 + 两振动开关杀进程重启保持；备份 JSON 含 5 键 | **PASS** | `147_vibrators_persist.png`、`148_bookmarks_after_restart.png`、`backup_e3_after_restart.json` |

- E1：两开关开启后拖动底部进度条（1/12 → 9/12），应用存活（pid 不变），logcat 无 FATAL/ANR/E flutter/Exception。MuMu 无马达，logcat 亦无 VibratorService 记录；实现通道为 Flutter `HapticFeedback.selectionClick`（`reader_menu_panel.dart` / `text_selection_panel.dart`），体感无法在本机判定，记 **BLOCKED**。
- E2：开启选词震动后长按正文弹出选择面板并拖拽选区，无崩溃、无异常日志；体感同样 BLOCKED。
- E3：`am force-stop` 后重启，两个振动开关仍为开；书签 Tab 仍显示 chapterName 与 bookText；备份 JSON `appPrefs` 含 `swipeToAddBookmark/bookmarkBadgeImage/bookmarkBadgeSize/sliderVibrator/selectVibrator` 五键，重启后值分别为 `true/""/10/true/true`；书签 `chapterPos/chapterName/bookText` 三字段完整（237、1558 两条样本）。

### F. 回归与稳定性

| 项 | 结果 | 证据 |
|---|---|---|
| F1 翻页/目录/搜索/朗读/书签跳转/删除/历史书签 | **PASS（含 2 项既有观察）** | `155_search_entry.png`、`158_tts_screen.png`、`66_toc_jump_p3.png`、`164_deleted_one.png`、`56_bookmark_list.png` |
| F2 FATAL/ANR/E.flutter/overflow = 0 | **PASS（排除 uiautomator 噪声）** | `logcat_full.txt` |

- F1：翻页（点击/横滑）、目录三 Tab、全文搜索页、朗读页（「正在朗读」+ 上/下一章段控件）均正常打开；目录→书签 Tab 跳转到第 3 页正常；长按书签 → 确认删除 → 提示「书签已删除」且列表减 1；历史 `qa4c_book` 书签显示章节名/正文/备注，样式正常。
- F2（logcat 2436 行统计）：
  - `Fatal signal` 12 条，**全部**为 `uiautomator` 进程 `Shutdown thread`（tombstone Cmdline: uiautomator），属工具自身噪声，不计入应用；
  - 应用相关 FATAL：**0**；ANR：**0**；`E/flutter`：**0**；`RenderFlex overflowed`：**0**。

### G. 清理

| 项 | 结果 | 证据 |
|---|---|---|
| G1 恢复默认、删除测试书、系统参数与书架终态 | **PASS** | `176_shelf_after_restart.png`、`179_bookmarks_cleaned.png`、`182_final_shelf.png`、`backup_final_defaults.json` |

终态实测：

- `swipeToAddBookmark=false`、`bookmarkBadgeImage=""`、`bookmarkBadgeSize=10`、`sliderVibrator=false`、`selectVibrator=false`；
- 书架为空（`books=[]`）；书签仅保留验收前的历史 `qa4c_book`（chapterPos=519）1 条；
- `font_scale=1.0`、`wm size=1080x1920`、`wm density=480`、`user_rotation=0`（ROTATION_0 竖屏）；
- 已删除设备端 `batch4d_normal_20ch.txt`、`batch4d_long_paragraph.txt`、`badge_test.png` 与本次生成的 `legado_backup/*.json`。

## 三、问题清单

### P1

- 无。

### P2（既有问题，非批4d引入，建议单独立项裁决）

1. **删除书籍不级联删除书签**：`rust/legado-ffi/src/api/bookshelf.rs` 的 `delete_book/delete_books` 仅删 `books` 行，书签残留为孤儿条目（本次删除两本测试书后书签列表仍显示 4 条）。影响：书签列表出现无主条目，点击无法定位。证据：删除书后书签列表 `179_bookmarks_cleaned.png` 清理前状态、`backup_final_defaults.json` 清理后仅剩历史书签。
2. **「我的 → 书签」列表点击不跳转**：`bookmark_screen.dart` 的 `_navigateToChapter` 仅 `Navigator.pop(result)`，唯一入口（我的页）未消费返回值；点击后直接回到「我的」。阅读器内「目录 → 书签」Tab 跳转正常。证据：`58_bookmark_list_again.png` + `59_after_jump_2s.png`。
3. **备份恢复不去重书签**：恢复同一备份后，相同 `chapterPos` 的书签被重复插入（本次恢复后 237 位置出现 4 条、qa4c 出现 2 条）。证据：`backup_after_restore.json`、`56_bookmark_list.png`。

### P3（观察项）

1. 菜单展开或「下滑添加书签」关闭时，纵向拖动会被既有翻页控制器判为「下一页」（`page_turn_controller.dart` 方向仅按 `dx` 符号判定，`dx=0` 落入 else → next）。批4d 下拉手势只在「开关开 + 菜单收起」时拦截，故不属 4d 回归，但用户可能感知为「下滑翻页」。证据：`29_after_pull_menu_open.png`、`47_pull_switch_off_after.png`。
2. 启用「隐藏状态栏/页眉」后分页从 12 页变为 7 页（排版区域变化），书签 `chapterPos` 仍正确，但页序号映射变化；属预期排版行为，验收中已按新分页重新定位角标。证据：`82_header_immersive.png`、`83_page2_header_badge.png`。
3. 从其他章节经「目录 → 书签」跨章跳转时，首帧偶发落在章首页（分页未就绪后校正），再次进入或翻页后定位正确；本次出现 2 次，未稳定复现（现场截图未纳入精简证据集），建议后续单独跟踪。
4. `uiautomator dump` 在 MuMu 上每次退出均触发自身 SIGSEGV（Shutdown thread），本次 logcat 中 12 条 FATAL 全属该工具，统计应用 FATAL 时必须排除。

## 四、结论

批4d 验收项 **A1–A2、B1–B5、C1–C3、D1–D3、E1–E3、F1–F2、G1 全部 PASS**；E1/E2 体感因模拟器无马达记 BLOCKED（功能通道与稳定性已取证）。未发现批4d 引入的 P1/P2 缺陷；发现的 3 项 P2 均为既有实现问题（删书不级联书签、我的页书签列表不跳转、恢复备份书签重复），建议由主代理裁决是否单独立项。

设备终态：书架空、默认阅读配置已恢复、1080x1920/480 竖屏、font_scale 1.0、测试文件与临时备份已清理。

---

编写：设备验收代理（QA） ｜ 2026-11-04
