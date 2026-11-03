# 批3b「阅读器菜单系统（模糊/边框/取种/紧凑顶栏）」设备验收报告

- 日期：2026-11-04
- 验收角色：QA（设备验收，只测不改代码）
- 代码基线：`97558c6877 chore: 批3b 收尾（2.0.451+452 双日志与计划登记）`
- 应用版本：2.0.451+452（设备 `versionName=2.0.451`、`versionCode=452`）
- APK SHA-256：`23851e99731f9af42559b23b32e365dffc227bd2b31c185247bc619e8ff2d3b9`
- 证据目录：`docs/materials_1104d/`（169 个文件，约 49 MB）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu 实例 index 1「Test测试」（`is_android_started=true`、`player_state=start_finished`） |
| adb 端点 | `192.168.100.62:5555`（`adb devices` 实测 device；本次未漂移） |
| 系统 | Android 15，伪装 SM-G9900（r9q） |
| 分辨率/密度 | 1080x1920 / 480dpi（逻辑宽 360dp） |
| 已装包 | `io.legado.flutter_legado`（2.0.451/452）、`com.legado.app.release`、`io.legato.kazusa` |
| Flutter | 3.44.8 stable / Dart 3.12.2 |
| Rust | 无 Rust 改动，未重建；复用既有 `.so` |
| 测试数据 | 书架为空；推送 UTF-8 TXT（20 章，关键字「青竹丹枫」）→ 应用内导入。无书籍搜索书源，下载/换源仍为在线书型 N/A |

## 二、总体结论

- 验收项 20 项（A1-A3、B1-B3、C1-C7、D1-D2、E1-E2、F1-F3）：**PASS 20 / FAIL 0 / BLOCKED 0**。
- N/A 子项 2 个：D1「下载/换源」（本地 TXT 且本机无书籍搜索书源）。
- **P1=0；P2=0；P3=6 条观察项**。
- 全程 `FATAL EXCEPTION / ANR / E flutter / RenderFlex overflow / E AndroidRuntime` 均为 0。
- 关键回归：默认外观已从 3a 的「页面原色 + 无边框」变为「取种 surfaceContainerHigh + 85% 半透明 + 1dp 边框」；默认模糊关时边框可见（3b P1 修复）；紧凑顶栏解决 6 动作标题被压到 0。

## 三、逐项结果

### A. 默认外观

| 编号 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 | PASS | `A1_00_default_menu.png`；对照 `docs/materials_1104b/A1_00_menu_open.png` | 默认（跟随阅读背景/模糊关/边框 1/透明度 85）：底栏背景实测 `(231,236,237)`、顶栏 `(230,235,236)`，与页面白色 `(255,255,255)` 明确区分；1dp 边框实测宽 3px、色 `(216,196,190)`，底栏四边 + 顶栏下边线均可见。3a 基线：底栏 `(255,255,255)` 与页面同色、顶栏 `(254,254,254)`、无边框。85% 透明度反推：白底底栏 `(231,236,237)`、深底 `A2_04` 底栏 `(197,202,203)`（页面 `(26,26,26)`），解得基色约 `(226.8,232.6,233.8)`，按 0.85 混深底预测 `(196.7,201.6,202.7)`，与实测一致 |
| A2 | PASS | `A2_01_brown_menu.png`、`A2_03_bluegrey_menu.png`、`A2_04_dark_menu.png`、`A2_05_white_menu.png`、`A2_02_custom_color_dialog.png` | 白色：页面 `(255,255,255)`、底栏 `(231,236,237)`、文字/图标 `(57,73,76)`；棕色 `#D4A574`：页面 `(212,165,116)`、底栏 `(239,220,203)`、文字 `(80,69,58)`（深色文字，未出现白字）；蓝灰 `#90A4AE`：页面 `(144,164,174)`、底栏 `(215,223,227)`、文字 `(64,72,76)`；深色 `#1A1A1A`：页面 `(26,26,26)`、底栏 `(197,202,203)`、文字 `(63,72,74)`。深色阅读 + App 浅色主题时菜单偏亮（P3-2 记录，不判失败） |
| A3 | PASS | `A3_00_before_turn.png`、`A3_turn_01..45.png`、`A3_turn_30.png` | 菜单开 + 自动翻页连拍 45 帧：底栏采样 `(231,236,237)` 稳定，仅翻页滑动过渡帧 `A3_turn_30` 为 `(226,232,232)`（约 5/255，1 帧，来自 85% 半透明透出滑动页面），无重影；翻页后页码 1/3 → 2/3 |

### B. 边框

| 编号 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 | PASS | `B1_01_border_off.png`、`B1_02_settings_border_on.png`、`B1_03_width4.png`、`A1_00_default_menu.png` | 关：无边框色/无顶栏下边线。开/默认 1dp：底栏四边约 3px、顶栏下边线约 4px（含 AA），色 `(216,196,190)`。宽度 4：底栏四边各 12px、顶栏 12px。**默认模糊关时边框可见（P1 修复通过）** |
| B2 | PASS | `B2_02_border_day_red.png`、`B2_04_night_blue.png`、`B2_05_restart_night_blue.png`、`B2_07_night_border_default.png`、`B2_08_light_red_persist.png` | 日间红 `#FFD32F2F` 实测 `(211,47,47)`；夜间蓝 `#FF2196F3` 实测 `(33,150,243)`；清除夜间色回落 outlineVariant `(83,67,62)`；重启后夜间蓝保持；切浅色主题日间红保持 |
| B3 | PASS | `B3_01_capsule_on.png` | 标题胶囊开启后顶栏下方无红色下边线（x=100 逐行扫描无红色），底栏红色整框仍 12px；符合「胶囊开启时不绘制顶栏下边线」 |

### C. 模糊

| 编号 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 | PASS | `C1_01_haze_24_85.png`、`C1_02_alpha100.png`、`C1_03_alpha0.png`、`C1_04_radius8.png`、`C1_05_radius32.png`、`A3_turn_30.png` | Haze 24/85：面板半透明、页面指示胶囊/页脚被模糊（翻页过渡帧可见正文被模糊）。透明度 100：底栏 `(227,233,234)`、更实；0：全透明 `(255,255,255)`、模糊胶囊清晰可见、菜单内容完整。半径 8/24/32 鬼影纹理标准差 `2.25/2.06` → `1.65/1.92` → `1.19/1.52`，强弱差异可见 |
| C2 | PASS | `C2_01_blur_day_red.png`、`C2_02_night_blue.png`、`C2_04_blurcolor_default.png`、`A2_04_dark_menu.png` | 日间红：底栏 `(218,80,80)`；夜间蓝：`(69,167,245)`；清除（0）：回升跟随背景 `(231,236,237)` |
| C3 | PASS | `C3_01_solid.png`、`C3_02_progressive.png` | 非浮动底栏：Solid 全高均匀 `(231,236,237)`；Progressive 顶部 `(248,248,248)` → 底部 `(229,234,234)`，约 19 个色阶连续渐变，幅度明显（非 4pp 近似） |
| C4 | PASS | `C4_01_liquid_glass_brown.png`、`C4_02_haze_brown.png`、`C4_03_nonfloating_liquid_fallback.png` | 浮动 + 液态玻璃开：模糊 + 白色高光描边 + 顶部镜面渐变；关：普通 Haze；非浮动 + 模式仍为液态玻璃：回落 Haze，未绘制矩形玻璃框。无折射/透镜属已登记近似边界 |
| C5 | PASS | `C5_01_glass_buttons_on.png`、`C5_02_glass_buttons_off.png` | 开：底栏 5 图标均有半透明圆底 + 白色高光边；关：恢复无底衬普通图标 |
| C6 | PASS | `C6_01_topbar_haze.png`、`C6_02_topbar_off.png` | 顶栏 Haze 开：顶栏下正文被模糊为均匀色（取样 222/223），Material 透明；关：正文鬼影文字清晰可读，仍按透明度半透明 |
| C7 | PASS | `C7_00_before_open.png`、`C7_open_01.png`、`C7_open_02..12.png`、`C7_close_1..8.png`、`C7_03_after_close.png` | 打开首帧内容淡入中途但模糊已生效（非“先清晰后突然模糊”）；关闭第 2-8 帧及最终态与关闭基线一致，无残影/残模糊 |

### D. 紧凑顶栏

| 编号 | 结果 | 证据 | 说明 |
|---|---|---|---|
| D1 | PASS（在线动作 N/A） | `D1_02_compact_off_6actions.png`、`D1_03_compact_on_6actions.png`、`D1_04_more_menu.png`、`D1_05_toc_rule_dialog.png`、`D1_06_charset_dialog.png`、`D1_07_catalog.png`、`D1_01_topbar_config.png` | 配置 6 个可适用动作（TXT 目录规则/设置编码/目录/全文搜索/自动翻页/更多）。紧凑关：360dp 下动作占满、标题宽度 0（P3-1，3a P2-1 已知形态）；紧凑开：只留「更多」，书名标题恢复且宽度正常，章名行可见。更多菜单 11 项，实测点开「TXT 目录规则」「设置编码」「查看目录」3 项成功。下载/换源本机本地 TXT 且无书源，N/A |
| D2 | PASS | `D2_01_restart_compact_on.png`、`D2_02_compact_off_restored.png`、`E2_01_restart_menu.png` | 紧凑开重启仍只显示「更多」+ 书名/章名；紧凑关恢复 6 动作原样 |

### E. 设置迁移与持久化

| 编号 | 结果 | 证据 | 说明 |
|---|---|---|---|
| E1 | PASS | `E1_01_menu_global_tab.png`、`E1_03_brightness_vertical_position.png`、`E1_04_vertical_brightness_bar.png`、`E1_05_more_brightness.png`、`E1_02_palette_dropdown.png` | 「全局」页含工具栏样式/调色板/亮度调节控件/边框开关/宽度/日夜色/模糊半径/透明度/底色日夜；亮度模式=竖排时出现位置行，关闭设置后右侧竖排条可见。「更多」页保留亮度滑条/自动亮度卡（参考同位置能力），不再有模式/位置双入口 |
| E2 | PASS | `E2_00_settings_global_values.png`、`E2_01_restart_menu.png`、`E2_02_settings_after_restart.png`、`E2_backup_1793744568696.json` | 非默认组合（边框 3、半径 16、透明度 70、夜间模糊底色蓝、顶栏 Haze、底栏液态玻璃非浮动回落、Progressive、玻璃按钮、紧凑开、浮动关）重启后全部保持；备份 JSON 含 `readMenuBorderWidth=3`、`readMenuBlurRadius=16`、`readMenuBlurAlpha=70`、`readMenuBlurColorNight`、`readMenuTopBarBlurMode=2`、`readMenuBottomBarBlurMode=1`、`readMenuBottomBarBlurStyle=1`、`readMenuBottomBarLiquidGlassButtons=true`、`titleBarCompact=true`、`readMenuFloatingBottomBar=false`、`readBarStyle=1` |

### F. 性能与回归

| 编号 | 结果 | 证据 | 说明 |
|---|---|---|---|
| F1 | PASS | `F1_01_auto_start.png`、`F1_04_auto_t31.png`、`F1_meminfo_before/after.txt`、`F1_sf_latency_t10/20/31.txt`、`F1_gfxinfo_framestats.txt` | 半径 32/透明度 85/菜单展开/自动翻页 32s。PSS 160,037 → 155,647 KB；RSS 256,596 → 252,492 KB（无增长）。SurfaceFlinger latency（每样本 127 帧）：中位 16.67ms、p95 16.67ms、最大 33.33ms，>25ms 占比 1.63%/1.63%/2.46%，无 ≥50ms 帧。gfxinfo HWUI 0 帧（Flutter SurfaceView 不经 HWUI） |
| F2 | PASS | `F2_01_content_search.png`、`F2_02_content_search_results.png`、`F2_03_read_aloud.png`、`F2_04_exit_to_shelf.png`、`D1_07_catalog.png`、`A3_turn_30.png`、`C7_*` | 全文搜索命中 6 处；目录打开/返回；朗读启动显示无引擎提示并可停止；退出阅读回书架；菜单展开/收起无卡死 |
| F3 | PASS | `logcat_batch3b_full.txt`（13,924 行）、`logcat_batch3b_final.txt`（15,478 行） | 两次统计一致：FATAL=0、ANR=0、E/flutter=0、RenderFlex overflow=0、E AndroidRuntime=0 |

## 四、问题清单

### P1（重要问题）
无。

### P2（次要问题）
无。

### P3（优化项/观察项）

1. **6 动作 + 紧凑关时标题宽度为 0**（`D1_02`）：3a P2-1 仍存在；3b 已提供「紧凑标题」开关作为解法（紧凑开时标题与章名正常）。默认紧凑关，属参考默认形态，记录不改判。
2. **深色阅读背景 + 浅色 App 主题时菜单偏亮**：深色页面 `(26,26,26)` 上菜单底 `(197,202,203)`，观感偏亮；按任务口径记录，不判失败。
3. **「更多」页仍保留亮度滑条/自动亮度卡**：为参考版「更多」页亮度控制能力；3b 仅把「亮度调节控件（模式/位置）」回迁菜单全局页，无模式/位置双入口。
4. **gfxinfo 无法统计 Flutter 帧**：Flutter 使用独立 SurfaceView，改用 SurfaceFlinger latency 取真实呈现帧间隔。
5. **液态玻璃/Progressive 为已登记近似**：无折射透镜；Progressive 为单层线性渐变。设备观感与登记边界一致。
6. **备份 JSON 仅落非默认值键**：默认值新键不出现；非默认值新键全部存在（属现有备份策略）。

## 五、性能数字汇总

| 指标 | 数值 |
|---|---|
| 场景 | 半径 32 / 透明度 85 / 菜单展开 / 自动翻页 32s（Haze 顶栏 + 底栏，非浮动，Progressive） |
| PSS before → after | 160,037 → 155,647 KB |
| RSS before → after | 256,596 → 252,492 KB |
| SurfaceFlinger 帧（3 样本） | 每样本 127 帧；中位 16.67ms；p95 16.67ms；最大 33.33ms |
| >25ms 帧占比 | 1.63% / 1.63% / 2.46% |
| ≥50ms 帧 | 0 |
| gfxinfo HWUI | 0 帧（不可用） |

## 六、FATAL / ANR 统计

- 采集：`adb -s 192.168.100.62:5555 logcat -d -v brief` 两次（测试结束、清理结束后）
- 文件：`docs/materials_1104d/logcat_batch3b_full.txt`（13,924 行）、`logcat_batch3b_final.txt`（15,478 行）
- `FATAL EXCEPTION`：0；`ANR in`/`Application Not Responding`：0；`E/flutter`：0；`RenderFlex overflow`/`overflowed by`：0；`E AndroidRuntime`：0。

## 七、清理记录与设备终态

| 项 | 结果 |
|---|---|
| 测试书 | 应用内删除，书架恢复空态（`CLEANUP_05_shelf_empty.png`） |
| 源文件 | `adb` 删除 `/sdcard/Download/batch3b_test.txt`（复查不存在） |
| 备份 | 取证 JSON 已拉取后删除；`/sdcard/Download/legado_backup/` 为空目录 |
| 菜单系统设置 | 恢复默认（跟随阅读背景/调色板跟随系统/亮度不显示/边框开宽 1 日夜默认/模糊 24·85·底色默认/浮动开/模糊关/无玻璃/胶囊关/标题顶栏显示/紧凑关/合并关/顶栏动作默认 6/6） |
| 阅读背景 | 白色；App 主题浅色 |
| 显示 | `font_scale=1.0`；`accelerometer_rotation=1`；`user_rotation=0`；1080x1920/480dpi |
| 服务开关 | 运行定时任务=关、MCP 服务=关 |
| 应用版本 | `io.legado.flutter_legado` 2.0.451（452）；三包均在 |
| 代码 | 未修改 lib；仅 `.zcode/` 与 `docs/materials_1104d/` 未跟踪 |

## 八、未闭环项与限制

1. 下载/换源（在线书型动作）：本机本地 TXT 且无书籍搜索书源，D1 标 N/A；紧凑更多菜单已实测 TXT 目录规则/设置编码/查看目录。建议有在线书源环境补验。
2. 图片背景取种：`ReaderState` 无背景图字段、`palette_generator` 未接入，已在 3b 计划登记，不属本批失败项。
3. gfxinfo 不可用：后续性能验收统一用 SurfaceFlinger latency（层名重启后会变）。
4. 默认 6 动作标题宽度 0：已有紧凑开关作为用户可选解法；若要求默认保留标题，需另行裁决默认值或最小标题宽度策略（P3-1）。

---

编写：QA 子代理 ｜ 2026-11-04
