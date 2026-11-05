# 批6a-1 设备验收报告（书架布局配置 + 核心渲染）

- 日期：2026-11-06
- 代码基线：`f96f778ba5`（2.0.462+463 双日志与计划登记）
- 验收范围：A 入口/默认、B 排序、C 布局渲染、D 分组、E 交互回归、F 清理
- 结论：**FAIL（1 项 P1 阻塞 + 2 项 P2 功能缺陷 + 1 项 P2 验证缺口）**；A/B 主链路与 C 大部分渲染通过
- 验收人：QA 子代理
- 证据目录：`docs/materials_1106a/`（172 个文件：截图、prefs XML、logcat、构建日志、APK 哈希）

---

## 一、环境与构建

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例，guest 直连 `192.168.100.62:5555`，SM_G9900 / Android 15 |
| 显示 | 1080x1920 / 480dpi（`wm size` / `wm density`） |
| 安装包 | `io.legado.flutter_legado` 2.0.462（versionCode 463，release，`flags` 无 DEBUGGABLE） |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，207,826,712 B |
| APK SHA256 | `9d351f5c785c3ba46a3c10c7d4b655ae4dcf3213a04a60aa90e9a555a39ca426` |
| 构建命令 | `cd flutter_legado && flutter build apk --release`，EXIT=0，Gradle assembleRelease 85.3s |
| 构建日志 | `docs/materials_1106a/build_release.log` |
| 证据哈希 | `docs/materials_1106a/apk_sha256.txt` |

说明：
- 设备原装 2.0.461+462 被 `adb install -r` 覆盖为本次构建；Rust 无改动，未重建 `.so`。
- 滑块类配置（列数/封面宽/行数/简介行数/更新数量限制）在本次环境**无法通过 adb 触摸注入改变**（见 P2-3）。为拿到精确布局矩阵，采用「安装同签名 debug 变体 → `run-as` 写入 prefs → 覆盖安装 release → 启动截图」的方式注入配置；**除特别注明处，所有截图均来自 release 构建**；A3 迁移写入的 prefs 回读在 release 运行后完成。
- 测试书：UTF-8 TXT 共 12 本（10 本中文名 + `Zoo Story` + `无作者之书`）。本地 TXT 导入的书名=文件名、作者为空；为验证作者拼音排序，通过应用内「编辑书籍信息」把《阿Q正传》作者改为「鲁迅」、《斗破苍穹》作者改为「天蚕土豆」。

---

## 二、逐项结果

### A 入口与默认

| 项 | 结果 | 证据 |
|---|---|---|
| A1 溢出菜单「布局设置」打开五段面板 | **PASS** | `02_overflow.png`、`12_layout_panel_top.png`、`13_panel_2.png`、`15_panel_badges.png`、`16_panel_badges2.png`：分组/排序/布局/角标/其他五段齐全；8 个文件夹键（folder layout mode/grid/list、group list style、group cover count）全程未出现 |
| A2 默认值 | **PASS** | `12/14/16/17` 系列：阅读时间降序、网格 3 列、网格样式标准、网格封面宽 120dp、书名小字体关、书名居中开、最大行数 2、阴影关、边距/列距 8dp、列表封面 84dp、分隔线开 |
| A3 旧 `bookshelf_layout` 迁移 | **PASS** | `prefs_legacy_false.xml` + `18_migration_false_release.png`（release 启动后为列表，prefs 回读 portrait/landscape=0：`prefs_after_migration_false.xml`）；`prefs_legacy_true.xml` + `19_migration_true_release.png`（网格，回读 =1：`prefs_after_migration_true.xml`）；旧键保留、新键写入 |

A2 量测（`17_shelf_grid_default.png`，480dpi，1dp=3px）：
- 内容左/右缘 24px、25px，列间距 25px → 8/8dp；
- 封面 328x459px（5:7），左上角圆角内缩 ~9-12px → 约 4dp；
- 阴影关闭时封面仅保留素材自身浅边框，无投影；
- 列表默认封面 254px ≈ 84.7dp（`18_migration_false_release.png`），条目间分隔线可见。

A3 说明：仅覆盖 Flutter 旧键 `bookshelf_layout`（bool，true/false 均测）；参考版旧 Android 键 `bookshelfLayout` 走同一迁移函数，未单独构造验证。

### B 排序

| 项 | 结果 | 证据 |
|---|---|---|
| B1 书名拼音排序 / 升降序 / 英文与空作者 | **PASS** | 升序 `24_sort_name_asc.png`、`25_sort_name_asc_scrolled.png`：阿 Q < 白 < 长 < 斗 < 尔 < 凡 < 鬼 < 红 < 青 < 无 < 西 < Zoo Story；降序 `22_sort_name_grid.png`：西 → 青 → 红；空作者（10 本）稳定并列、`Zoo Story` 英文键回落 Unicode；不崩 |
| B2 六种模式各切一次 | **PASS** | 作者（`34/45/46`：空作者组 < 鲁迅 < 天蚕土豆，符合 l < t）、阅读时间（`50_readtime_desc.png`：唯一读过的《阿Q正传》置顶）、更新时间（`55_updatetime_desc.png`：按 latestChapterTime 重排）、手动（`58/59/60/61/62`）、综合（`66_comprehensive.png`：与更新时间同序，符合 max(latest,dur)） |
| B2 手动拖拽落盘 + 重启保持 | **PASS** | `62_manual_drag3.png` 顺序变化（阿Q → 斗破 → 白夜行），`63_manual_after_restart.png` 重启后同序 |
| B3 手动 + 网格回落列表 | **PASS** | `57_manual_panel.png`（副标题说明拖拽范围）、`58_manual_fallback.png`（提示条「已临时切换为列表」+ 列表渲染） |
| B3 分组展示不可拖拽 | **PASS（记录）** | 代码路径：分组模式先走 `_buildGroupedSlivers`，`SliverReorderableList` 分支被跳过；设备上开启「按分组显示」后仅展示分组标题与列表（`d2_groupmode_bygroup.png`），无拖拽手柄 |

说明：本地书无书源更新，更新时间/综合排序只能验证「按 latestChapterTime 的确定性顺序」，无法与远端更新时延交叉校验；顺序在多次重启后稳定。

### C 布局渲染

| 项 | 结果 | 证据 |
|---|---|---|
| C1 网格 2/3/5/7 列（竖/横） | **PASS** | 2 列 `c1_s1_grid2_cover150_shadow.png`、5 列 `c1_s3_grid5_compact.png`、7 列 `c1_s2_grid7_coveronly.png`、横屏 7 列 `c1_s8_landscape_grid7.png`；均无 overflow |
| C1 封面宽 40/120/150 | **PASS** | 40（`c1_s2_*`）、60（`c1_s4b_*`）、120（`c1_s3_*`）、150（`c1_s1_*`，受 cell 宽夹取为 ~109dp） |
| C1 三种网格样式 | **PASS** | 标准 `c1_s1_*`；紧凑（书名叠封面+渐变）`c1_s3_*`；仅封面 `c1_s2_*` |
| C1 标题小字体/居中/最大行数 1/3 | **PASS** | 小字体+左对齐+1 行 `c1_s1_*`；常规+居中+2 行 `c1_s3_*`；最大行数 3 已注入（`c1_s2_*`，仅封面样式不渲染标题） |
| C1 阴影开/关 | **PASS** | 开：`c1_s1_*`（封面四周投影）；关：`c1_s2_*`/`c1_s3_*` |
| C1 卡片日/夜色 | **FAIL（P2-1）** | 注入日间红 `0xFFCC0000`（`c1_s4b_day_cardcolor.png`）与夜间 `0xFF203040`（`c1_s4_dark_cardcolor.png`）后均无可视变化；代码中 `BookshelfSettings.cardColorFor()` 在 `lib/` 无调用方 |
| C2 列表 1 列全字段 | **PASS** | `e1_s12_list1.png`：封面、书名、作者、当前章（时钟）、最新章节（>|）、未读角标、分隔线 |
| C2 360dp 下 3–5 列夹取 | **PASS** | 配置 5 → 实显 2 列（`c2_s5_list_cols5_info.png`）；配置 3 → 实显 2 列（`c2_s6_list_cols3_compact_nodivider.png`）；公式 `maxReadableListColumns(360)=2` |
| C2 横屏/窄 pane 实际列数 | **PASS** | 横屏导航栏 pane 内容宽约 563dp，配置 5 → 实显 3 列（`e2_landscape_list5.png`），无 overflow |
| C2 封面宽/居中/分隔线/精简 | **PASS** | 40（`c2_s5`）、84（`e1_s12`）、120（`c2_s6`）；居中关=顶部对齐（`c2_s6`）；分隔线开/关（`c2_s5` vs `c2_s6`）；精简详情=「鲁迅 · 2 章…」（`c2_s6`） |
| C2 书籍类型/标签 | **PASS** | `c2_s5`/`e1_s12` 显示「本地」类型角标 |
| C2 最新章节 / 上次更新时间 / 简介 | **PARTIAL（BLOCKED）** | 最新章节已验证（`e1_s12`）；上次更新时间、简介在本地书为空/0，设备无法呈现，需网络书源复核 |
| C3 未读/新章角标 | **PARTIAL** | 未读数角标已验证（`c3_s9_fastscroll_moregroups.png` 等显示 1/2）；新章角标需 `lastCheckCount>0`，本地书无更新，**BLOCKED** |
| C3 等待更新数量 | **BLOCKED** | 需可更新书源；本地书「更新目录」无可更新目标，待更新胶囊不出现 |
| C3 分组书籍数 | **PASS（按设计）** | 面板副标题「文件夹模式上线后生效」，本批不渲染 |
| C3 快速滚动条 | **PASS** | `c3_s9_fastscroll_moregroups.png` 右侧滚动条 |
| C3 更多分组按钮 | **PASS** | `d1_shelf_tabs.png` 组数 >1 时行尾出现分组菜单按钮 |
| C3 更新数量限制 | **BLOCKED** | 同上，无网络书源可更新，无法验证「只处理 1 本并提示」 |

说明：C2 的「简介显示/位置/行数」「上次更新时间」字段代码路径已核对，但本地 TXT 无简介、无更新时间，设备上没有可观察差异；未用伪造 DB 数据冒充通过。

### D 分组

| 项 | 结果 | 证据 |
|---|---|---|
| D1 分组样式 0（顶部 Tab） | **PASS** | `d1_shelf_tabs.png`、`d1_tab_testgroup.png` |
| D1 分组样式 1（隐藏 Tab + 顶部组标题 + 组菜单） | **PASS** | `d1_s10_groupstyle1.png`、`d1_group_menu_sheet.png`、`d1_group_switch_testgroup.png`；切换后标题/内容同步，无待切换标记残留 |
| D1 隐藏空分组 | **FAIL（受 P1 连带）** | 空组存在时仍显示（`d1_shelf_tabs.png`、`d1_group_menu_sheet.png`）；删除书籍后空组才隐藏（`f3_shelf_empty.png`）——根因见 P1 串组 |
| D2 现有「分组模式」入口 | **PASS** | `d2_overflow_bottom.png`：不分组（选中）/按来源分组/按分组显示均在溢出菜单，与新面板不冲突 |
| D2 按分组显示 | **FAIL（P2-2）** | `d2_groupmode_bygroup.png`：分组头显示 `分组 1793904884364 1`（groupId 数字）而非组名 |

### E 交互回归

| 项 | 结果 | 证据 |
|---|---|---|
| E1 批量选择（网格/单列/多列） | **PASS** | 网格 `e1_batch_grid_selected2.png`（3/12，勾选在封面右上）；单列 `e1_batch_list1_selected.png`（2/12，勾选在行右）；双列 `e1_batch_list2_selected2.png`（3/12，勾选在封面左上）；命中位置与可视位置一致 |
| E1 长按信息 | **PASS** | `39_longpress2.png`（书籍详情：作者/来源/共 3 章/在读章） |
| E1 打开书 | **PASS** | `38_open_book.png`（正文 + 底部进度 1/1 33.3%） |
| E1 Hero 封面过渡 | **PASS（站点正常，未逐帧取证）** | 书架↔详情往返正常（`39/43/47`），Hero tag 代码在位 |
| E1 拖拽 | **PASS** | 见 B2/B3 |
| E1 搜索 / 发现 | **PASS** | `e1_search.png`、`e1_discover3.png`（无发现源空态） |
| E1 详情封面 | **PASS** | `43_book2_info.png`、`47_zoo_info.png` |
| E1 横竖屏 | **PASS** | 横屏 `c1_s8_landscape_grid7.png`、`e2_landscape_list5.png`（导航栏 + 底部栏自适应） |
| E1 字号 1.3 / 1.6 | **PASS** | `e1_font13.png`、`e1_font16.png`（截断省略号，无 overflow） |
| E1 暗色 | **PASS** | `c1_s4_dark_cardcolor.png` |
| E2 pane 宽度提示 | **PARTIAL（BLOCKED 文本证据）** | 夹取行为已在设备验证（5→3 横屏、3/5→2 竖屏）；面板「当前书架宽度最多 N 列」提示文本因横屏 sheet 内被标题栏遮挡，未截到完整文本 |
| E2 保存/取消/重启回显 | **PASS（N/A 保存/取消）** | 面板为即时生效模型，无保存/取消按钮；注入/切换后重启均正确回显（`f8_defaults_panel_top.png` 等） |
| E2 备份含书架键 / 忽略书架布局恢复 | **BLOCKED** | 未执行备份-恢复往返（避免覆盖测试库）；代码核对：`BookshelfSettings.prefKeys` 全量登记，`RestoreIgnorePrefs.applyFromBackup` 按 `keyIsNotIgnore` 过滤。无设备证据，不计通过 |
| E3 FATAL/ANR/E.flutter/overflow | **PASS** | `logcat_full.txt`（15,042 行）：FATAL=0、ANR=0、`E/flutter`=0、`RenderFlex overflowed`=0；出现的 Exception 均为 MuMu/蓝牙/WindowManager 系统噪声 |

### F 清理

| 项 | 结果 | 证据 |
|---|---|---|
| 删除测试书（12 本） | **PASS** | `f1_all_selected.png` → `f2_delete_confirm.png` → `f3_shelf_empty.png`（「已删除 12 本书籍」） |
| 删除测试分组（2 个） | **PASS** | `f4_group_menu_delete.png`、`f6_groups_empty.png`（分组管理空态） |
| 恢复默认配置 | **PASS** | prefs 重写为空（仅保留 `remote_servers_migrated`）→ `f7_defaults_empty.png`、`f8_defaults_panel_top.png`：分组样式顶部标签、隐藏空分组开、按阅读时间/降序、网格/标准、3 列、阴影关等 |
| 设备参数 | **PASS** | `font_scale=1.0`、`user_rotation=0`（竖屏）、`wm size 1080x1920`、`wm density 480` |
| 测试文件清理 | **PASS** | `/sdcard/Download/qa6a1` 已删除；`/data/local/tmp/q*.sql` 已删除 |
| 终态 | **PASS** | release 2.0.462+463、空书架、默认配置、竖屏（`f9_final_state.png`） |

---

## 三、缺陷清单

### P1（阻塞）

**P1-1 自定义分组 ID 采用时间戳，与位掩码分组语义冲突，导致书籍跨组串显、隐藏空分组失效**

- 复现：
  1. 分组管理新建「测试组」「空组」；
  2. 给「测试组」分配《Zoo Story》（管理页此时两组的「X 本书」都显示 0，计数已可疑）；
  3. 书架 Tab 或组菜单切换：「测试组」与「空组」都显示《Zoo Story》。
- 期望：书只出现在被分配的自定义组；空组在「隐藏空分组」开启时不显示。
- 实际：两组互相显示同一本书；空组被视为非空。
- 根因证据：
  - DB：`book_groups` 中 `测试组=1793904884364`、`空组=1793904908173`；`books` 中 `Zoo Story.group=1793904884364`。
  - `lib/src/providers/bookshelf/bookshelf_state.dart:117` 自定义组过滤使用 `b.group & groupId != 0`（位掩码语义）。
  - 参考实现 `app/src/main/java/io/legado/app/data/dao/BookGroupDao.kt:98` 的 `getUnusedId()` 返回 2 的幂（1,2,4…），保证位掩码互不重叠。
  - Flutter 侧分组 ID 由 Rust `rust/legado-ffi/src/api/book_group_api.rs:45` 生成：`SystemTime::now()...as_millis()`，与位掩码语义冲突。
- 影响：D1 的隐藏空分组判定、分组 Tab 内容、组菜单切换均可能错误；E1 分组切换的使用信任度受损。
- 建议：Rust `add_book_group` 改为返回未使用的 2 的幂（对齐参考 `getUnusedId`），并迁移存量时间戳 ID（或过滤处改为等值匹配，需与参考语义裁决）；修复后补「两组各含不同书 + 空组隐藏」用例。

### P2

**P2-1 卡片日间/夜间背景色无渲染效果**

- `c1_s4b_day_cardcolor.png`（日间红）、`c1_s4_dark_cardcolor.png`（夜间蓝）设置后书架无颜色变化。
- `BookshelfSettings.cardColorFor()` 在 `lib/` 内无调用方（`grep` 仅命中模型定义），属「可配置但未接线」。
- 影响：C1 卡片色项不通过。

**P2-2「按分组显示」分组标题显示 groupId 数字而非组名**

- `d2_groupmode_bygroup.png`：标题为「分组 1793904884364 1」，参考版应显示组名（如「测试组」）。
- 影响：D2 可读性缺陷，且暴露内部 ID。

**P2-3 布局设置面板滑块无法通过 adb 触摸注入改变（验证缺口，需手指复核）**

- 现象：`input tap` / `input swipe` / `input draganddrop` 对列数、封面宽、最大行数等 Slider 均无响应；同面板的 Switch、Dropdown、列表滚动均正常（如 `14 → 75` 小字体开关被成功打开）。
- 影响：本次列数/封面宽/行数矩阵改用 prefs 注入完成；**不能据此判定滑块在真实手指下失效**，但必须在真机/真手指复核后再关闭该项。
- 建议：在有条件时用真实触摸或 Flutter integration_test 的 `tester.drag` 复核 Slider。

### P3

- P3-1 书籍信息编辑页顶栏「取消/保存」文字被裁切（仅见「取」与圆形棕色块），见 `40_edit_book.png`、`44_book2_author_saved.png`。非 6a-1 改动范围，但与本次设备验收同屏可见，建议单独确认。
- P3-2 双列列表行高偏大、长书名/最新章节截断较多（`c2_s6`、`e1_s13_list2`），无溢出但信息密度偏低，属观感项。
- P3-3 A3 仅验证 Flutter 旧键 `bookshelf_layout`；`bookshelfLayout`（参考版旧 Android 键）未单独构造。

---

## 四、阻塞/未闭环清单

1. C3 新章角标：需书源产生 `lastCheckCount>0`，本地书库无法构造。
2. C3 待更新数量、更新数量限制：需可更新书源（本地书 `canUpdateToc=false`）。
3. C2 简介显示/位置/行数、上次更新时间：本地 TXT 无简介与更新时间数据。
4. E2 备份含书架键、「忽略书架布局」恢复不覆盖：未做备份-恢复往返（避免覆盖测试库），仅有代码核对。
5. E2 pane 宽度提示：夹取行为已验证，提示文本未取得完整截图。
6. P2-3 滑块：adb 注入无效，需真实手指复核。

---

## 五、设备终态

- 应用：`io.legado.flutter_legado` 2.0.462（versionCode 463，release），已启动并停留在书架
- 书架：空（`f9_final_state.png`）
- 配置：书架布局全部默认（按阅读时间降序、网格 3 列、标准样式、阴影关、标签开、未读/新章开、快速滚动关、更多分组关、更新限制 0、分组样式 0、隐藏空分组开）
- 系统：`font_scale=1.0`、竖屏、1080x1920 / 480dpi
- 测试数据：12 本测试书、2 个测试分组、`/sdcard/Download/qa6a1` 均已删除
- 日志：验收结束后已 `logcat -c` 清空

---

## 六、证据索引（关键文件）

- 构建/包：`apk_sha256.txt`、`build_release.log`
- 迁移：`prefs_before_migration.xml`、`prefs_legacy_false.xml`、`prefs_after_migration_false.xml`、`prefs_legacy_true.xml`、`prefs_after_migration_true.xml`、`18_migration_false_release.png`、`19_migration_true_release.png`
- 默认/入口：`12_layout_panel_top.png`、`14_panel_grid_defaults.png`、`16_panel_badges2.png`、`17_shelf_grid_default.png`
- 排序：`24_sort_name_asc.png`、`25_sort_name_asc_scrolled.png`、`34_sort_author_asc.png`、`46_author_asc_bottom.png`、`50_readtime_desc.png`、`55_updatetime_desc.png`、`62_manual_drag3.png`、`63_manual_after_restart.png`
- 布局：`c1_s1_grid2_cover150_shadow.png`、`c1_s2_grid7_coveronly.png`、`c1_s3_grid5_compact.png`、`c1_s4_dark_cardcolor.png`、`c1_s4b_day_cardcolor.png`、`c1_s8_landscape_grid7.png`、`c2_s5_list_cols5_info.png`、`c2_s6_list_cols3_compact_nodivider.png`、`e2_landscape_list5.png`、`c3_s9_fastscroll_moregroups.png`
- 分组：`d1_shelf_tabs.png`、`d1_group_switch_testgroup.png`、`d1_tab_emptygroup.png`、`d2_groupmode_bygroup.png`、`f3_shelf_empty.png`
- 交互：`e1_batch_grid_selected2.png`、`e1_batch_list1_selected.png`、`e1_batch_list2_selected2.png`、`e1_font13.png`、`e1_font16.png`、`38_open_book.png`
- 清理/终态：`f1_all_selected.png`、`f2_delete_confirm.png`、`f7_defaults_empty.png`、`f8_defaults_panel_top.png`、`f9_final_state.png`
- 日志：`logcat_full.txt`（15,042 行，FATAL/ANR/E.flutter/overflow 均为 0）

---

# P1/P2 回修复验（2026-11-06 05:20，2.0.463+464）

## 0. 回修基线

| 项 | 值 |
|---|---|
| 代码基线 | `e005cb67d4`（批6a-1b 收尾，含 `f14cb349a3` / `4ed9d58c43` / `c34273ff76` / `98915df894` / `daa95af48a` / `32f15719ca` / `bc4d04db9c`） |
| 版本 | 2.0.463+464（versionCode 464，release） |
| APK | 207,925,088 B |
| APK SHA256 | `3193ac3ffacd72a8e0926154cb4623aefe55b424753c776773d37ba5825f4bb5` |
| `liblegado_ffi.so` arm64 | 51,759,720 B，mtime `2026-11-06 04:23:12.896 +0800` |
| `liblegado_ffi.so` x86_64 | 51,943,848 B，mtime `2026-11-06 04:23:55.992 +0800` |
| `app.so` arm64/x86_64 | 25,080,424 B / 25,670,864 B，mtime `2026-11-06 04:27:47` |
| 构建 | `flutter build apk --release` EXIT=0，assembleRelease 54.9s |
| 设备 | MuMu「Test测试」`192.168.100.62:5555`，1080x1920/480dpi，Android 15 |

证据目录：`docs/materials_1106b/`（68 个文件）。APK 哈希与 `.so` mtime 见 `apk_sha256.txt`、`so_mtimes.txt`；回归 logcat 见 `logcat_regression.txt`。

说明：本轮仍采用「同签名 debug 变体写 prefs/DB → 覆盖安装 release → 启动取证」的方式准备配置与旧数据；除特别注明外，UI 证据均来自 release 包。测试书 6 本，《阿Q正传》为书 X；干部分组 ID/组位通过 `run-as` + sqlite3 读取。

## 1. P1-1 分组位掩码（回修）：PASS

| 验收点 | 结果 | 证据 |
|---|---|---|
| 新建组 ID 为 2 的幂 | **PASS** | DB：`组B=2`、`空组=4`、`复用组=1`（删除组A 后复用最小空闲位 1）；均满足 `id & (id-1) == 0` |
| 组A 放书 X 后，组A/组B 不再同显 | **PASS** | 组A Tab 仅《阿Q正传》（`13_tabA_content.png`）；关闭隐藏空分组后组B 为空态（`15_tabB_empty.png`）、空组为空态（`16_tabEmpty_empty.png`） |
| 空组隐藏 | **PASS** | 隐藏空分组开启时 Tab 仅 `全部/组A`（`10_shelf_tabs_hideempty.png`） |
| 组管理计数 | **PASS（重进页面后）** | 重进分组管理：组A 1 本、组B 0、空组 0（`12_group_counts_reloaded.png`）；旧时间戳组 1 本（`26_new_group_created.png`） |
| 删除组A 清书位 | **PASS** | 删除后 DB `阿Q正传.group=0`；新建复用组（bit1）后其 Tab 为空（`22_reuse_tab_empty.png`），管理页 0 本（`19_reuse_group_created.png`） |
| 旧时间戳组只匹配自身 | **PASS** | 注入 `groupId=1793904884368` + `白夜行.group=1793904884368` 后：旧组 Tab 仅显示《白夜行》（`24_legacy_group_only.png`），组B 为空（`25_groupB_empty_no_leak.png`），旧组管理计数 1 |
| 删除新组不清旧时间戳值 | **PASS** | 新建/删除「新组」后 DB 复查：`白夜行.group` 仍为 `1793904884368`，组列表仅 1/2/4 + 旧时间戳组 |
| 多组分配保留其它组位 | **PASS** | 书 X 同时分配到组B(2) 与复用组(1) 后 DB `阿Q正传.group=3`；分组显示标题为「组B、复用组」 |

## 2. P2-1 卡片日夜色（回修）：PASS

| 验收点 | 结果 | 证据 |
|---|---|---|
| 日间红网格生效 | **PASS** | `29_card_day_grid.png`（2 列、封面 60dp，卡片底红） |
| 日间红列表生效 | **PASS** | `31_card_day_list.png`（整行红底） |
| 夜间蓝生效 | **PASS** | `32_card_night_grid.png`（系统暗色下使用 `bookshelfCardColorDark`，日间红不生效） |
| 0 = 跟随主题 | **PASS** | `33_card_zero_default.png`（无色块，恢复主题底色） |
| 批量选中底色可见 | **PASS** | `30b_card_selected.png`：选中项显示 secondaryContainer 粉底，未选中仍为红卡 |
| 列表卡色圆角 8dp | **PASS** | `31_card_day_list.png` 像素量测：首卡上缘红色起点 x=19→0 过渡约 20px、稳定内缩 24px（480dpi 下 8dp） |

## 3. P2-2 分组真实组名（回修）：PASS

| 验收点 | 结果 | 证据 |
|---|---|---|
| 按分组显示标题为真实组名、多组「、」连接 | **PASS** | `38_grouped_names.png`：`组B、复用组 1`（书 X）、`旧时间戳组 1`（白夜行）；无数字 groupId |
| 详情页分组 chip 同 | **PASS（P3 观察）** | `39_detail_group_chip.png`：chip 为「组B,复用组」，为真实组名、无数字 ID；分隔符为半角逗号，与分组标题的「、」不一致（P3） |

## 4. 回归抽检：PASS

| 项 | 结果 | 证据 |
|---|---|---|
| 默认阅读时间降序 + 网格 3 列 | PASS | `40_reg_default_grid3.png` |
| 网格列数 2 / 7 | PASS | `41_reg_cols2.png`、`42_reg_cols7.png`，无 overflow |
| 手动排序列表拖拽 + 重启保持 | PASS | `43_reg_manual_before.png` → `44_reg_manual_drag.png`（白夜行上移）→ `45_reg_manual_persist.png` 重启同序 |
| 列表配置 3–5 列夹取 | PASS | 配置 5 → 实显 2 列（`46_reg_list5_clamp.png`），无 overflow |
| 批量勾选可点 | PASS | `47_reg_batch_list2.png`：双列列表 2/6 选中，勾选位置正确 |
| 分组样式 0 / 1 | PASS | 样式 1 无 Tab、顶部组标题+组菜单（`48_reg_style1.png`）；样式 0 见 `40` |
| 隐藏空分组回退 | PASS | 选中「空组」后开启隐藏：空组 Tab 消失、选择回退「全部」并展示全部 6 本（`52_emptygroup_selected_real.png` → `53_hideempty_fallback_real.png`） |
| 字号 1.3 / 1.6 | PASS | `54_font13.png`、`55_font16.png`，无 overflow |
| 暗色 | PASS | `32_card_night_grid.png`，无 overflow |
| FATAL / ANR / E.flutter / overflow | PASS | `logcat_regression.txt`（363 行）：均为 0 |

## 5. 回修复验新增观察（P3）

1. **分组管理计数与书架分组 Tab 的创建刷新延迟**：分配书籍后管理页计数仍显示 0，离开/重进后正确（`09_groupA_count.png` vs `12_group_counts_reloaded.png`）；新建分组后返回书架，新组 Tab 需重启应用才出现（`20_tabs_reuse.png` vs `21_tabs_after_restart.png`）。数据与匹配逻辑均正确，属刷新时机问题。
2. **详情页分组 chip 分隔符**为半角逗号（`组B,复用组`），与分组标题「组B、复用组」不一致（`39_detail_group_chip.png`）。
3. 上一轮 P2-3（滑块 adb 注入无响应）本轮未复测；本轮配置矩阵仍通过 prefs 注入完成，滑块仍需真实手指复核。

## 6. 回修后设备终态

- 应用：`io.legado.flutter_legado` 2.0.463（versionCode 464，release）
- 书架：空（`60_final_device.png`）
- 配置：书架布局全部默认（按阅读时间降序、网格 3 列、标准样式、卡色 0、分组样式 0、隐藏空分组开）
- 测试数据：6 本测试书、4 个测试分组（含注入的旧时间戳组）、`/sdcard/Download/qa6a1`、`/sdcard/Download/qa6a1b`、`/data/local/tmp/*.sql` 全部删除
- 系统：`font_scale=1.0`、竖屏、1080x1920 / 480dpi
- 日志：回归检查后已 `logcat -c`

## 7. 回修结论

- 上轮 P1-1（分组串组/隐藏空组失效）、P2-1（卡片日夜色未接线）、P2-2（分组标题显示数字 ID）三项**全部 PASS**。
- 未发现新的 P1/P2 功能缺陷；新增 2 项 P3（分组创建/计数刷新时机、详情 chip 分隔符）与 1 项沿用验证缺口（滑块真实手指复核）。

---

编写：QA 子代理 ｜ 2026-11-06
