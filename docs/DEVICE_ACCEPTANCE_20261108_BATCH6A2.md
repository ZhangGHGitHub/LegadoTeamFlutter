# 批6a-2 设备验收报告（书架文件夹模式）

- 日期：2026-11-08 至 2026-11-09（测试跨零点完成）
- 代码基线：`c9e13d7f27b4b1f5d92bda14d4a9ad1d7fede782`（批6a-2 收尾，2.0.466+467）
- 验收范围：A 配置、B 文件夹根、C 进出组/返回/组菜单/根目录批量、D 溢出/阴影/窄屏、E 回归与稳定性、F 清理
- 验收结论：初测 **FAIL（1 项 P2，无 P1/P0）**；P2-1 已回修，2026-11-09 定向复验 **PASS**（见「七、P2 回修复验」），批6a-2 结论更新为 **PASS**
- 验收人：QA 子代理（只验收，不改 `lib/`）
- 证据目录：`docs/materials_1108a/`（122 个文件：截图、logcat、prefs/DB、构建日志、APK 哈希）

---

## 一、环境与构建

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例，guest 直连 `192.168.100.62:5555`，SM-G9900 / Android 15，x86_64 |
| 显示 | 1080x1920 / 480dpi（验收全程；D1 临时 720x1280 / 360dpi，结束后已恢复） |
| 安装包 | `io.legado.flutter_legado` 2.0.466（versionCode 467，release，非 DEBUGGABLE） |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，208,154,864 B |
| APK SHA256 | `97e6dbf666f6de6feb1b12bf460982d8e9884fbbc3a500a9601962f31bca1d11`（`apk_sha256.txt`） |
| 构建命令 | `cd flutter_legado && flutter build apk --release`，EXIT=0，`assembleRelease` 151.8s |
| 构建日志 | `docs/materials_1108a/build_release.log` |
| Rust 状态 | 未改 Rust/FFI，未重建 `.so`；arm64 51,759,720 B / x86_64 51,943,848 B，mtime `2026-11-06 04:23`，quickjs=true（`so_mtime.txt`） |
| 设备信息/终态 | `docs/materials_1108a/env.txt` |

说明：

- 为构造精确的配置矩阵（列数/封面宽/横排数量/阴影等滑块值），采用与 6a-1/6b-1 设备验收相同的方法：安装同签名 debug 变体，经 `run-as` 写入 prefs/DB 种子，再覆盖安装 release 取证；**除特别注明外，所有验收截图均来自 release 构建**，最终设备保留 release。
- 滑块类控件用 adb 拖动不稳定，矩阵值通过 prefs 注入后重启验证；面板项的存在性/范围/重置行为则通过 UI 点按验证。
- 全程未修改 `lib/` 代码；测试结束已 `pm clear` 并删除测试文件。

---

## 二、测试数据

| 项 | 内容 |
|---|---|
| 测试书 | 12 本 UTF-8 TXT（11 本中文名 + `Zoo Story`），书名不同；作者经 DB 种子分别设为鲁迅/东野圭吾/紫金陈/天蚕土豆/曹雪芹/测试作者甲/佚名/忘语/天下霸唱/空/埃德加·斯诺/Edward Albee |
| 分组 | 3 个：`测试组A`(groupId=1，4 本)、`测试组B`(groupId=2，2 本)、`空组`(groupId=4，0 本)（`db_groups_before_cleanup.txt`） |
| 组封面 | 测试组A 使用本地 PNG（`/data/data/io.legado.flutter_legado/files/group_cover.png`），验证「组自定义封面优先于 2×2 拼图」 |
| 阅读时间 | 组A：阿Q正传 > 白夜行 > 长夜难明 > 斗破苍穹；组B：青竹丹枫 > 红楼梦（用于最近阅读预览与排序独立性验证） |
| 视频特殊组 | 无真实视频书，按契约注入 1 行 `type=4` 的「测试视频」种子验证「视频」特殊组卡片；C4 删除测试中以真实批量删除动作删除，随后从库中消失 |
| 测试文件 | 设备 `/sdcard/Download/qa6a2/`（12 TXT + 组封面源图）；测试后已删除 |

---

## 三、逐项结果

### A 配置

| 项 | 结果 | 证据 |
|---|---|---|
| A1 分组样式=文件夹时出现 8 项 | **PASS** | `15_config_top.png`（分组样式/隐藏空分组）、`16_config_mid.png`（文件夹布局模式=网格、行列数 3、说明+重置）、`18_folder_list_controls.png`（列表模式：列数 1、列表封面宽 84dp、列表样式）、`19_folder_horizontal_controls.png`（横排封面数量 4）、`21_config_showcount.png`（显示分组书籍数） |
| A1 取值/范围 | **PASS** | 语义树：网格列数 `SeekBar 14%,3`（1–15）、列表列数 `0%,1`（1–5）、封面宽 `55%,84`（40–120）、横排数量 `33%,4`（1–10）；重置与说明在面板内 |
| A2 重置只恢复这 8 项 | **PASS** | 预置：列表 5 列 / 封面宽 120 / 横排样式 / 数量 10 / 显示标签关 / 显示书籍数关（`85_a2_repro_before_reset.png`、`prefs_before_reset.xml`）；点重置后 `86_a2_repro_after_reset.png`、`prefs_after_reset.xml`：folder mode=1、grid=3、list=1、groupListStyle=0、coverCount=4；共享 `bookshelfListCoverWidth` 仍=120、`bookshelfShowTag=false`、`showBookCount=false` 均未被改 |
| A2 切回标签/隐藏标签时文件夹项隐藏 | **PASS** | `28_style_tabs_no_folder.png`（顶部标签）、`29_style_hidden_no_folder.png`/`29c_style_hidden_no_folder.png`（隐藏标签）：布局段直接进入共享布局模式，文件夹根目录段消失 |
| A2 重启保持 | **PASS** | 切回文件夹后 `30_a2_folder_restored.png`；force-stop 重启后 `31_a2_restart_persist.png` 仍为文件夹根网格 3 列 |

### B 文件夹根

| 项 | 结果 | 证据 |
|---|---|---|
| B1 根目录无 Tab，3 列组卡片 | **PASS** | `13_folder_root_grid_A.png`、`32_b1_grid_video_counts.png`：无 TabBar；3 列；「全部 12 本」「测试组A 4 本」「测试组B 2 本」，第二行「测试组B」 |
| B1 2×2 封面预览/组名/书籍数 | **PASS** | 同上；空槽为浅灰占位（`13` 组B 两本、`33` 空组） |
| B1 空组隐藏开/关 | **PASS** | 开：`32` 无空组；关：`33_b1_hideempty_off.png` 出现「空组 0 本」 |
| B1 组自定义封面优先 | **PASS** | `13`/`32`：测试组A 显示青绿斜纹自定义封面，而非 2×2 书籍拼图 |
| B1 视频特殊组 | **PASS（种子数据）** | `32_b1_grid_video_counts.png` 出现「视频 1 本」卡片；`39_b4_namesort_root.png` 同时可见全部/视频/自定义组；删除唯一视频书后 `63_c4_back_to_root.png` 视频组消失 |
| B2 列表样式 0（分组+最近阅读） | **PASS（1/2 列）** | `41_b2_style0_cols1_w40.png`（40dp）、`43_b2_style0_cols2.png`：组名/书籍数/「最近阅读：…」正常 |
| B2 列表样式 1（紧凑） | **PASS（1 列）** | `42_b2_style1_cols1_w120.png`：组名+书籍数，无「最近阅读」，封面 120dp 正常 |
| B2 列表样式 2（横排封面） | **PASS** | `46_b2_style2_cols1_count1.png`、`47_b2_style2_cols2_count10.png`、`48_b2_style2_cols5_count10.png`：1/2/5 列、数量 1/10 均可见，无 RenderFlex overflow |
| B2 列数 5 卡片不裁切 | **FAIL（P2）** | `44_b2_style0_cols5_w40.png`、`44_crop2.png`、`45_b2_style1_cols5.png`：360dp/5 列时组名完全不可见，书籍数被截断为「13…」「4 …」；`68_d1_320dp_style2_cols5_count10_font16.png`：320dp/1.6 字号下同样不可读。详见 P2-1 |
| B3 显示分组书籍数关 | **PASS** | `49_b3_counts_off_root.png`（卡片无数量）、`50_b3_counts_off_menu.png`（组菜单无副标题）、`51_b3_counts_off_title.png`（组标题无「N 本」） |
| B3 显示分组书籍数开 | **PASS** | `32`（卡片 12/4/2）、`34_b3_group_menu_counts_on.png`（菜单 13/1/4/2 本）、`37_c3_switch_groupB.png`（标题 2 本） |
| B4 预览离线/缓存不联网 | **PASS** | 在线时：根目录预览对 `http://192.168.100.52:18080/cover.png` **无任何请求**；`http_server.log` 仅 2 条请求，均发生在进入组内容后的普通封面加载（00:03:40 首次进组、00:14:15 清缓存后再次进组），根目录预览期间无请求；清空 image 缓存并重启后 `52_b4_offline_preview.png` 显示默认封面文字，预览阶段服务器日志无新增请求 |
| B4 最近阅读预览不受排序影响 | **PASS** | 组B：阅读时间序=青竹丹枫、红楼梦（`38_b4_recency_root.png` 预览首格青竹丹枫）；切书名升序后根预览仍青竹丹枫（`39_b4_namesort_root.png`），而组内顺序变为红楼梦、青竹丹枫（`40_b4_namesort_groupB.png`） |

### C 进入/返回/组菜单

| 项 | 结果 | 证据 |
|---|---|---|
| C1 点组卡进入组内容，顶部返回+组名+书籍数 | **PASS** | `14_groupA_content.png`（测试组A 4 本）、`73_e1_groupB_content.png`（测试组B 2 本、无 TabBar、返回/组菜单/搜索/更多） |
| C1 组内为 6a-1 网格/列表/排序/批量/拖拽 | **PASS（抽检）** | 组内网格 3 列/列表/批量选择在 C4 复验；排序切换在 B4 复验；未逐项重跑 6a-1 全矩阵 |
| C2 顶部返回→组根 | **PASS** | `53_c2_topback_root.png` |
| C2 系统返回→组根 | **PASS** | `54_c2_sysback_root.png` |
| C2 组根再返回→双击退出 | **PASS** | `55_c2_root_back1.png` 首按提示「再按一次退出程序」；`56b_c2_doubleback_exit.png` 连按退出到桌面 |
| C2 预测性返回 | **PASS（记录）** | 实现为 `HomeScreen`/`BookshelfScreen` 的 `PopScope(canPop:false)+onPopInvokedWithResult`，仅消费系统返回事件，无参考版手势进度跟随动画；未逐帧录屏 |
| C3 组菜单切换分组 | **PASS** | `35_b3_group_menu_scrolled.png`（选择分组：全部/视频/A/B/空组）、`37_c3_switch_groupB.png`（切到 B 后内容 2 本） |
| C3 管理分组 | **PASS** | `64_c3_manage_groups.png`：管理页计数 A=4、B=2、空组=0，删除后视频组不再存在 |
| C3 显示书籍数 | **PASS（按实现记录）** | 组菜单以 `subtitle` 显示「N 本」（`34`/`35`），不是独立开关项；开关位于布局面板「角标」段（`21`）。任务文字若要求菜单内独立项，则以本条实现口径为准 |
| C4 根目录「选择模式」自动进入组内容 | **PASS** | `58_c4_root_selectmode.png`：从根目录点选择模式后进入「空组 1 本」内容并直接显示批量栏（全选/反选/删除/取消、已选 0 本·共 1 本） |
| C4 全选/删除作用于真实书 | **PASS** | `59_c4_selectall.png`（已选 1 本）、`61_c4_delete_confirm.png`（删除书籍/已选1本/删除源文件）、`62_c4_after_delete.png`；DB `books` 计数 13→12，`测试视频` 行消失 |
| C4 批量返回先退批量再回根 | **PASS** | `60_c4_back_exit_batch.png`：系统返回先退出批量并停留在组内容；再返回回到根 `63_c4_back_to_root.png` |

### D 溢出/阴影/窄屏

| 项 | 结果 | 证据 |
|---|---|---|
| D1 横排样式 2 列 + 12 本 + 字号 1.6 + 320dp | **PASS** | 720x1280/360dpi（320dp），`67_d1_320dp_style2_cols2_count10_font16.png`：组名/计数可读，卡片无 RenderFlex overflow；logcat `RenderFlex` 0 |
| D1 5 列 + 字号 1.6 + 320dp | **PASS（overflow 0）** | `68_d1_320dp_style2_cols5_count10_font16.png`：无 RenderFlex overflow；但组名/计数裁切，归入 P2-1 |
| D1 恢复显示 | **PASS** | 测试后 `wm size`=1080x1920、`wm density`=480、`font_scale`=1.0（`env.txt`） |
| D2 书架封面阴影开→文件夹预览有阴影 | **PASS** | `69_d2_shadow_off.png` vs `70_d2_bookshelf_shadow_on.png`；像素差 78,246（组A 区域 27,864），`70_d2_bookshelf_shadow_on_cropA.png` 可见柔和投影 |
| D2 全局封面阴影开同样生效 | **PASS** | `71_d2_global_shadow_on.png`（组A 区域像素差 27,864），`71_d2_global_shadow_on_cropA.png` |
| D2 关闭恢复 | **PASS** | `72_d2_shadow_off_again.png` 与 `69` 差 657 像素（仅状态栏时钟），组A 区域差 0 |

### E 回归与稳定性

| 项 | 结果 | 证据 |
|---|---|---|
| E1 组内打开书/退出 | **PASS** | `73_e1_groupB_content.png` → `74_e1_reader_open_qingzhu.png`（阅读页正文）→ `75_e1_reader_exit_detail.png`（详情）→ `76_e1_back_root.png`（组内容/根） |
| E1 详情页 | **PASS** | `75_e1_reader_exit_detail.png`：书名/作者/来源/分组/字数/换源 |
| E1 搜索 | **PASS** | `77_e1_search.png`、`84_e1_search2.png`：搜索页打开/返回正常（首次点顶栏返回需页面过渡完成，二次验证正常） |
| E1 发现 | **PASS** | `79_e1_discover.png`：发现 Tab 正常（当前无发现源，空态） |
| E1 分组样式 0/1/2 | **PASS** | 0：`80_e1_style0_tabs.png`；1：`82_e1_style1_hidden.png`（无 Tab，顶部组标题+组菜单）；2：`13`/`32`（文件夹根） |
| E1 隐藏空组/全部/视频组 | **PASS** | 隐藏空组：`32`；全部：`13`；视频组：`32`（有视频书时出现）→`63`（删除后消失） |
| E1 FATAL/ANR/E.flutter/overflow | **PASS** | E 段 `logcat_e_regression.txt` 1,576 行：4 类计数均 0；F 段 `logcat_f_final.txt` 4,725 行：4 类计数均 0；`exit_info_final.txt` 16 条均为 `reason=10/21 USER REQUESTED/FORCE STOP`（验收 force-stop），无 crash/ANR |

### F 清理

| 项 | 结果 | 证据 |
|---|---|---|
| F1 恢复默认 | **PASS** | 最终 `pm clear` 后默认：分组样式标签、网格 3、列表 1、封面 84、样式 0、横排 4、书籍数显示、隐藏空组开；`88_f_final_relaunch.png` 空书架+「全部」Tab |
| F1 删除测试书/组 | **PASS** | `pm clear` 成功；测试后书架为空（`87_f_final_empty_shelf.png`、`88`） |
| F1 环境恢复 | **PASS** | font_scale=1.0、1080x1920/480、竖屏（user_rotation=0 / accelerometer_rotation=0 / SurfaceOrientation=0） |
| F1 测试文件清理 | **PASS** | `/sdcard/Download/qa6a2` 与 `/data/local/tmp/group_cover.png` 已删除 |
| F1 最终安装包 | **PASS** | release 2.0.466+467，非 DEBUGGABLE（`env.txt`） |

---

## 四、缺陷与观察

### P1

无。

### P2

**P2-1 文件夹列表样式 0/1 在 5 列时组名不可见、书籍数被裁切**

- 复现：布局设置 → 分组样式「文件夹」→ 文件夹布局模式「列表」→ 行列数拖到 5（360dp，480dpi）→ 返回书架根目录。
- 期望：每张组卡片至少显示组名；书籍数完整或明确省略（如「13 本」→「13…」可接受，但组名不应消失）。
- 实际：组名整行不渲染；书籍数显示为「13…」「4 …」；像素统计组名行仅 4 个暗像素（`44_crop2.png`）。样式 0 与样式 1 均可复现。
- 窄屏放大：720x1280/360dpi + font_scale 1.6 + 5 列 + 横排 10 张时，组名全部消失、计数显示「4 …」「2 …」，封面缩到约 1dp（`68_d1_320dp_style2_cols5_count10_font16.png`）。
- 影响：配置允许的 5 列/窄屏组合下无法辨认组；无崩溃、无 RenderFlex 黄黑条。
- 证据：`44_b2_style0_cols5_w40.png`、`44_crop2.png`、`45_b2_style1_cols5.png`、`68_d1_320dp_style2_cols5_count10_font16.png`。
- 建议：dense 5 列时给文本列设最小宽度/组名优先布局（如组名+计数上下两行或计数移到封面角标）；或在 cellWidth 过小时限制 effective columns / 隐藏计数文本，保证组名可读；补 360dp×5 列与 320dp×5 列×1.6 的 golden/overflow 用例。

### P3（不阻塞）

1. 预测性返回仅消费系统返回事件（组内→根、根级双击退出），无参考版手势进度跟随动画；与 6a-2 计划登记一致。
2. 文件夹网格样式 1 仍为「封面下组名」，参考版紧凑叠字未做（计划已登记）。
3. 组菜单的「显示书籍数」为分组行副标题，不是独立开关项；开关在布局面板「角标」段。
4. Hero 过渡仅通过打开/退出的静态结果验证，未逐帧录屏量化；阅读页退出实际落到详情页再回组内容，属现有导航栈行为。
5. 视频特殊组使用注入的 `type=4` 种子书验证（无真实视频文件），仅验证卡片/计数/删除消失，未验证视频播放。
6. 「100+ 书籍数」未构造（按任务用现有 12 本）；5 列大计数裁切的极端 1000 本场景未上设备（单测矩阵已覆盖 123/1000）。
7. 全流程早期 logcat 未整段留存；稳定性计数以 E 段（1,576 行）与 F 段（4,725 行）为准。crash buffer 仅见 `uiautomator`（uid 2000）Shutdown thread SIGSEGV，属 ROM/工具噪声，不是应用崩溃。
8. 搜索页顶栏返回首次点击在页面过渡未完成时可能被吞，二次/系统返回正常；未列为缺陷，建议后续真实手指复核。

---

## 五、设备终态

| 项 | 终态 |
|---|---|
| 应用 | release 2.0.466+467（versionCode 467），非 DEBUGGABLE |
| 数据 | `pm clear` 成功；书架空、无分组、无测试书 |
| 测试文件 | 设备目录与临时封面已删除 |
| 显示 | 1080x1920 / 480dpi；font_scale 1.0；竖屏（rotation 0） |
| 进程 | 应用已正常启动并停留在空书架（`88_f_final_relaunch.png`） |

---

## 六、证据索引（`docs/materials_1108a/`）

- 构建/环境：`build_release.log`、`build_debug.log`、`apk_sha256.txt`、`env.txt`、`so_mtime.txt`
- 配置：`15_config_top.png`、`16_config_mid.png`、`18_folder_list_controls.png`、`19_folder_horizontal_controls.png`、`21_config_showcount.png`、`28_style_tabs_no_folder.png`、`29_style_hidden_no_folder.png`、`85_a2_repro_before_reset.png`、`86_a2_repro_after_reset.png`、`prefs_before_reset.xml`、`prefs_after_reset.xml`
- 文件夹根/列表矩阵：`13_folder_root_grid_A.png`、`32_b1_grid_video_counts.png`、`33_b1_hideempty_off.png`、`41`–`48`、`65`、`66`、`44_crop2.png`
- 计数/排序/离线：`34`–`40`、`49`–`52`
- 进出组/返回/批量：`53`–`64`
- 窄屏/溢出：`67`、`68`
- 阴影：`69`–`72` 及 `*_cropA.png`
- 回归：`73`–`84`
- 清理终态：`87`、`88`
- 日志：`logcat_e_regression.txt`、`logcat_f_final.txt`、`logcat_crash_buffer_final.txt`、`exit_info_final.txt`、`http_server.log`
- 数据证据：`db_groups_before_cleanup.txt`、`db_books_before_cleanup.txt`、`prefs_current_before_f.txt`

---

## 七、P2 回修复验（2026-11-09）

### 0. 回修基线

| 项 | 值 |
|---|---|
| 代码基线 | `13b1b33b597d294badc15772531837295a8fc276`（`738d138d95` 修复 + `13b1b33b59` 测试） |
| 版本 | 2.0.466+467（versionCode 467）；release，非 DEBUGGABLE |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，208,220,400 B |
| APK SHA256 | `695db5e397c52fe354a6ed95fde94cbf0f5145f0357bc94ca76d54c25eb54f62`（`apk_sha256.txt`；设备内 `base.apk` 复算一致，`installed_apk_sha256.txt`） |
| 构建 | `cd flutter_legado && flutter build apk --release` EXIT=0，`assembleRelease` 61.6s（`build_release.log`） |
| Rust | 未改 Rust/FFI，未重建 `.so` |
| 种子方式 | 同签名 debug 变体 `run-as` 写入 2 组/8 书与 prefs；除注明外截图均来自 release；测试后覆盖安装 release 并 `pm clear` |
| 测试数据 | `测试组甲`(groupId=1，4 本)、`测试组乙`(groupId=2，4 本)；8 本本地书；`seed.sql`/`db_before_cleanup.txt` |
| 配置 | 分组样式=文件夹、文件夹布局=列表、列表样式=0/1、列数=5、显示书籍数=开 |

### 1. 逐项结果

| 验收点 | 结果 | 证据 |
|---|---|---|
| 360dp/1.0，列表样式 0，列数 5 | **PASS** | `01_5col_style0_360dp.png`：竖向紧凑卡（封面在上、名称/计数在下）；「全部 8 本」「测试组甲 4 本」「测试组乙 4 本」组名与计数完整可见 |
| 360dp/1.0，列表样式 1，列数 5 | **PASS** | `02_5col_style1_360dp.png`：同上，组名/计数完整 |
| 360dp/1.0，列表样式 0/1，列数 4 | **PASS** | `03_4col_style0_360dp.png`、`04_4col_style1_360dp.png`：竖向紧凑卡生效，组名/计数完整 |
| 320dp（720x1280/360dpi）/1.6，样式 0，列数 5 | **PASS** | `09_5col_style0_320dp_font16.png`：名称「全部」「测…」「测…」（非空白、非仅省略号），计数「8 本」「4 本」「4 本」完整（FittedBox 缩放未裁断） |
| 320dp/1.6，样式 1，列数 5 | **PASS** | `10_5col_style1_320dp_font16.png`：同上 |
| 1–3 列仍为原 Row 样式（360dp，样式 0） | **PASS** | `07_1col_style0_360dp.png`、`06_2col_style0_360dp.png`、`05_3col_style0_360dp.png`：封面在左、名称/计数在右；1/2 列名称完整，3 列名称为「测试…」省略（原 Row 行为，未变为竖向卡）；`08_1col_style1_360dp.png` 样式 1 同为 Row |
| 横排样式 2，5 列，数量 10，360dp 不回归 | **PASS（与基线一致）** | `11_style2_5col_count10_360dp.png` 对比初测 `docs/materials_1108a/48_b2_style2_cols5_count10.png`：均为计数省略、组名不显示的既有表现，布局/高度一致，修复未引入新回归；该既有表现记为 P3，不属于本次 P2-1 范围 |
| RenderFlex overflow | **PASS** | 各状态测试后 `grep RenderFlex/overflowed` 均为 0；`logcat_retest.txt` 785 行、`logcat_final.txt` 1,816 行：FATAL EXCEPTION / ANR / E.flutter / RenderFlex overflowed 均 0 |
| 崩溃/ANR | **PASS** | `logcat_crash_buffer_final.txt` 无应用 crash；`exit_info_final.txt` 13 条 FORCE STOP + 3 条 PACKAGE UPDATED（均为验收安装/清理），无 crash/ANR |

### 2. 结论

- **P2-1 已修复：PASS**。列表样式 0/1 在 4–5 列改为竖向紧凑卡后，360dp/1.0 组名与计数完整；320dp/1.6 组名可见、计数完整且未被裁成「N…」；无 RenderFlex overflow。
- 1–3 列保持原 Row 布局，无回归；样式 2 横排 5 列与修复前基线一致，无新增回归。
- 无新增 P1/P2。批6a-2 验收结论由初测 FAIL 更新为 **PASS**。

### 3. 清理与设备终态

| 项 | 终态 |
|---|---|
| 安装包 | release 2.0.466+467（versionCode 467），非 DEBUGGABLE |
| 数据 | `pm clear` 成功；书架空、无分组 |
| 测试文件 | `/sdcard/Download/qa6a2b`、`/data/local/tmp/qa6a2b_seed.sql` 已删除 |
| 显示 | 1080x1920 / 480dpi；font_scale 1.0；竖屏（user_rotation=0 / accelerometer_rotation=0 / SurfaceOrientation=0） |
| 终态截图 | `12_final_empty_shelf.png` |

### 4. 证据索引（`docs/materials_1108b/`）

`01_5col_style0_360dp.png`、`02_5col_style1_360dp.png`、`03_4col_style0_360dp.png`、`04_4col_style1_360dp.png`、`05_3col_style0_360dp.png`、`06_2col_style0_360dp.png`、`07_1col_style0_360dp.png`、`08_1col_style1_360dp.png`、`09_5col_style0_320dp_font16.png`、`10_5col_style1_320dp_font16.png`、`11_style2_5col_count10_360dp.png`、`12_final_empty_shelf.png`、`apk_sha256.txt`、`installed_apk_sha256.txt`、`build_release.log`、`build_debug.log`、`env.txt`、`seed.sql`、`prefs_before_cleanup.xml`、`db_before_cleanup.txt`、`logcat_retest.txt`、`logcat_final.txt`、`logcat_crash_buffer_final.txt`、`exit_info_final.txt`

---

编写：QA 子代理 ｜ 2026-11-09
