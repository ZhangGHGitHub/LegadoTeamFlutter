# 批3a「阅读器菜单系统」设备验收报告

- 日期：2026-11-04
- 验收角色：QA（设备验收，只测不改代码）
- 代码基线：`14e3933528 chore: 批3a 收尾（2.0.449+450 双日志与计划登记）`
- 应用版本：2.0.449+450（设备 `versionName=2.0.449`、`versionCode=450`）
- 证据目录：`docs/materials_1104b/`（截图 99 张 + 备份 JSON + 完整 logcat，共 101 个文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu 实例 index 1「Test测试」（`MuMuManager info -v all` 实测 `is_android_started=true`） |
| adb 端点 | `192.168.100.62:5555`（`adb devices` 实测 device） |
| 系统 | Android 15（`ro.build.version.release=15`），伪装型号 SM-G9900（r9q） |
| 分辨率/密度 | 1080x1920 / 480dpi（逻辑宽 360dp）；displayId=0，无独立逻辑屏 |
| 已装包 | `io.legado.flutter_legado`（我方，本次安装 2.0.449/450）、`com.legado.app.release`、`io.legato.kazusa` |
| Flutter | 3.44.8 stable / Dart 3.12.2 |
| Git 工作区 | HEAD `14e3933528`，仅 `.zcode/` 未跟踪；`lib/` 与 HEAD 一致 |

### 构建与安装

```
cd flutter_legado && flutter build apk --release
# 复用既有 Rust .so，未重建 Rust；assembleRelease 69.9s
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

- APK 路径：`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`
- APK 大小：200,927,872 bytes（191.6 MB）
- **APK SHA-256：`b1c68408ddf98e1b7800e94f70a1dcb33d57fb18a1026f9a55180c398799e0cf`**
- 安装结果：`Success: streamed 200927872 bytes`；安装后 `dumpsys package` 为 2.0.449（450）。

### 测试数据

书架为空，导入本地 TXT《批3a测试.txt》（UTF-8，20 章，含关键字「青竹丹枫」）用于全部阅读器场景；
备份恢复使用本地备份目录 `/storage/emulated/0/Download/legado_backup`（SAF 授权）。
无可用**书源**（`书源管理` 仅有发现源 `QA_B2C源`，标记「发现已启用」，非书籍搜索源），因此仅在线书可用的
「下载/刷新正文/换源」路径无法在本机验证（见 A3 的 BLOCKED 项与 D5 的 N/A 子项）。

## 二、总体结论

- 验收项共 26 项（A1-A3、B1-B8、C1-C4、D1-D5、E1-E2、F1、G1-G3）。
- **PASS：25 项；FAIL：0 项；BLOCKED：1 项**（A3 的「换源顶栏/更多入口」；D5 的「下载/换源点击」为 N/A 子项，核心 6 可见/可点已通过）。
- P1：0；P2：2；P3：4（见第四节）。
- 全程 `FATAL EXCEPTION / ANR / E flutter / RenderFlex overflow` 均为 0（详见 G3）。

## 三、逐项结果

| 编号 | 结果 | 证据（docs/materials_1104b/） | 说明 |
|---|---|---|---|
| A1 | PASS | A1_00_menu_open.png、A1_01_settings_sheet.png、A1_02_menu_tab.png | 中央点按出菜单；设置弹层顶部页签为 全局/菜单/信息/更多；「菜单」页有 全局/底栏布局/顶栏布局 三段子页 |
| A2 | PASS | A2_01_more_tab.png、A2_04_more_brightness.png、A2_05_menu_bottom_default.png、A2_06_menu_top_tab.png | 「更多」页含 自动翻页/点击区域/亮度控制 三卡；「菜单」三子页仅菜单系统配置，不再出现三卡 |
| A3 | BLOCKED（本地范围 PASS） | A1_00/D2_01、A3_01~A3_07、A3_08_more_menu.png、A3_09_change_source_local.png | 顶栏中部不再有 5 个快捷小图标；全文搜索/自动翻页/目录/朗读/设置 均从底栏网格打开并返回；**换源**：本地书顶栏与更多菜单按书型过滤不显示（配置页标注「仅在线书」），仅书籍详情页有入口，点击后进入换源搜索并报 `Parser error: 书源 searchUrl 为空`（本地书无书源）。无在线书源，无法完成「顶栏动作/更多菜单」路径 |
| B1 | PASS | A1_00_menu_open.png、A3_04_auto_page_on.png | 默认单行 5 键（全文搜索/自动翻页/目录/朗读/设置），无文字、图标无底衬 |
| B2 | PASS | B2_00b_settings_3x2_sliders.png、B2_01_3perrow_2rows_menu.png | 每行 3 + 2 行 → 第一行 3、第二行 2，无溢出 |
| B3 | PASS | B3_01_page1.png、B3_02b_page_swipe.png、B3_03_page3.png、B3_04_page3_settings_opened.png | 每行 2 + 1 行 → 3 页；第 2 页为第 3/4 键（目录/朗读），第 3 页为第 5 键（设置），点击设置成功打开面板 |
| B4 | PASS | B4_01_bottom_icons_text_on.png、A1_00_menu_open.png | 图标文字开：5 个文案完整显示，「全文搜索」无截断/省略号；关：文字消失 |
| B5 | PASS | A3_04（无底衬）、B5_02_tone_container.png（色调=圆底）、B5_03_outline_container.png（描边=圆环） | 三态视觉差异明确 |
| B6 | PASS | 开：C1_00_follow_system.png；关：B6_02_float_off.png | 开=左右边距实测 48px（16dp）、底部留白实测 48px（16dp）、四角圆角；关=贴底全宽、仅上圆角。注：截图命名已按实际状态修正（原「B6_01_float_on」实为关闭态，已改名 B6_02_float_off） |
| B7 | PASS | B7_01_radius1.png（≈0）、B7_02_radius16.png、B6_02_float_off.png（32） | 圆角 0/16/32 顶部角部形态差异可见（滑块最小档实测为 1） |
| B8 | PASS | B8_01_after_restart_shelf.png、B8_02_after_restart_menu.png | 杀进程重启后：浮动关闭态/圆角 16/图标文字/描边容器/工具栏样式 均保持 |
| C1 | PASS | C1_00_follow_system.png、C1_03_follow_page_brown.png、C1_04_follow_page_dark.png、C1_06_follow_page_white.png | 跟随系统=系统容器色；阅读背景 #D4A574（棕）时菜单文字/图标仍为深色且清晰（回归点通过，未变白字）；#1A1A1A 时文字转浅色；白色时恢复深色 |
| C2 | PASS | C2_02_tonalspot_menu.png、C2_04_vibrant_menu.png、C2_05_system_vibrant.png | 自定义+种子色下 TonalSpot→Vibrant：顶栏底色 RGB (247,228,223)→(255,226,217)，强调色 (143,76,51)→(168,57,0)，变化可见；应用主题调色板=Vibrant 时「跟随系统」实测与 Vibrant 同色 (255,226,217) |
| C3 | PASS | C3_02_custom_colors_settings.png、C3_03_custom_day_menu.png、C3_04_custom_night_menu.png、C3_05_restart_night_menu.png | 日间（#8BC34A 底/#212121 字/#D32F2F 强调）与夜间（#212121 底/#FAFAFA 字/#2196F3 强调）随日/夜切换；重启后夜间配色保持 |
| C4 | PASS | C3_03、C3_04 | 进度条 thumb 与已走轨道使用强调色：日间红、夜间蓝，肉眼可辨 |
| D1 | PASS | A1_00（顶栏显示）、D1_01_own_line.png（另起一行）、D1_02_chapter_only.png（仅章节）、D1_03_hidden.png（不显示） | 四档形态均符合定义：书名+章节行/书名单独一行+章节行/首行章名无章节行/无书名章名 |
| D2 | PASS | D2_01_capsule_on.png、D2_02_capsule_book_info.png | 胶囊开：返回键右侧出现书名+章名胶囊；点击进入书籍详情并可返回；关：恢复书名文本 |
| D3 | PASS | D3_01_merged_on.png（合并为单一圆角胶囊）、D4_01_title_tonal.png（独立圆钮，间距 6dp） | 开关两态符合 |
| D4 | PASS | A1_00（无底衬）、D4_01_title_tonal.png（色调）、D4_02_title_outline.png（描边） | 独立按钮上三态差异明显 |
| D5 | PASS（在线动作 N/A） | D5_00_topbar_actions_sheet.png、D5_01_disabled_online_actions.png、D5_04_six_actions_topbar.png、D5_05_action_catalog.png、D5_06_action_settings.png | 顶栏按钮配置支持 6 个并显示「已开启 6/6」；360dp 下 6 个动作（TXT 目录规则/设置编码/目录/全文搜索/界面设置/更多）全部可见不裁切；实测点击「目录」「界面设置」均成功。**下载/换源**为「仅在线书」，本机无书源，无法逐项点击验证（N/A 子项） |
| E1 | PASS | E1_01_font13_bottom.png、E1_02_font13_capsule.png、E1_03_font15_menu.png | font_scale 1.3/1.5：底栏 5 个图标文字均完整无裁切、无黄黑溢出条；标题胶囊随字体增高不溢出 |
| E2 | PASS | E2_01_restored_font10.png、`settings get system font_scale=1.0` | 已恢复 1.0 |
| F1 | PASS | F1_04_style_before_backup_final.png、F1_05_backup_done.png、F1_backup_1793736287730.json、F1_07_restore_picker.png、F1_08_restore_confirm.png、F1_09_restore_done.png、F1_10_restored_settings.png | 备份前设为 每行3/圆角8/强调#E91E63 并备份（JSON 的 appPrefs 含 `readMenuIconItemsPerRow=3`、`readMenuBottomCornerRadius=8`、`readMenuAccentColor=4293467747` 即 #FFE91E63）；改回 每行5/圆角32/强调默认 后恢复；**同一会话**重新打开菜单设置即显示 3/8/#E91E63，阅读菜单底栏立即按每行 3 渲染，无需重启 |
| G1 | PASS | G1_02_tap_right_next.png（点击右侧→2/3）、G1_03_tap_left_prev.png（点击左侧→1/3）、G1_04_swipe_next.png、A3_05/A3_06（目录跳章）、A3_01~A3_03（全文搜索 6 处命中）、A3_07（朗读提示「未配置可用朗读引擎」）、A3_09（换源入口，本地书报无 searchUrl） | 翻页/目录/全文搜索/朗读/退出均正常；换源入口存在但本地书不可用（环境限制） |
| G2 | PASS | G2_01_landscape.png、G2_02_portrait_restored.png | 菜单展开/收起动画正常无卡死；横屏一次后菜单/底栏/进度条布局正常（分页 2/6），回竖屏正常 |
| G3 | PASS | logcat_batch3a_full.txt（20,792 行） | `FATAL EXCEPTION`=0、`ANR in / Application Not Responding`=0、`E/flutter`=0、`RenderFlex overflow/overflowed by`=0、`E AndroidRuntime`=0（MESA 噪声已过滤不计） |

## 四、问题清单（P 级）

### P1（重要问题）
无。

### P2（次要问题，建议本迭代确认/修复）

1. **P2-1 顶栏配置 6 个动作后书名/章名区域完全消失**
   - 复现：设置→阅读设置→更多→顶栏按钮，开启 6 个动作（含固定「更多」）；返回阅读菜单。
   - 实际：动作区占满整行，标题宽度被压到 0，书名/章名与标题胶囊均不显示（D5_04_six_actions_topbar.png）。
   - 期望：对照参考版确认该形态是否允许；若参考版仍保留标题（省略号/缩小），则属视觉差异。
   - 影响：用户失去书名/章名上下文；6 个动作全部可见可点本身符合 D5。

2. **P2-2 调色板 TonalSpot→Vibrant 时菜单背景差异偏弱**
   - 复现：工具栏样式=自定义、颜色来源=种子色；调色板分别选 TonalSpot / Vibrant。
   - 实测：顶栏底色 RGB (247,228,223) → (255,226,217)，仅约 3-11 个色阶；强调色 (143,76,51) → (168,57,0) 变化明显（C2_02、C2_04）。
   - 期望：验收口径为「菜单背景/强调色明显变化」；当前背景变化较难肉眼分辨，建议确认是否与参考版一致。

### P3（优化项/观察项）

1. **P3-1** 每行 2、单行时第 3 页仅「设置」一个按钮且靠左（B3_03_page3.png）。
2. **P3-2** 标题胶囊在常规 3 动作下章名仍被省略为「第3章 测试章节…」（D2_01_capsule_on.png）。
3. **P3-3** 6 动作时顶栏按钮经 FittedBox 等比缩小（约 36dp），较 40dp 基准略小（D5_04_six_actions_topbar.png）。
4. **P3-4** font_scale 1.5 时底栏「全文搜索」距屏幕左缘余量很小（未裁切，E1_03_font15_menu.png）。

## 五、FATAL / ANR 统计

- 采集命令：`adb -s 192.168.100.62:5555 logcat -d -v brief`（2026-11-04 04:12，覆盖本次全部安装/启动/测试过程）
- 文件：`docs/materials_1104b/logcat_batch3a_full.txt`（20,792 行）
- 统计（脚本精确匹配）：
  - `FATAL EXCEPTION`：0
  - `ANR in` / `Application Not Responding`：0
  - `E/flutter`：0
  - `RenderFlex overflow` / `overflowed by`：0
  - `E AndroidRuntime`：0
- 说明：`E MESA: Failed to find VkFence` 属模拟器 GPU 噪声，未计入。

## 六、清理记录

| 项 | 结果 |
|---|---|
| 测试书 | 已删除（书架选择模式 → 删除书籍 + 删除源文件），书架恢复空态（CLEANUP_05_shelf_empty.png） |
| `/sdcard/Download/批3a测试.txt` | 已删除 |
| `/sdcard/Download/legado_backup/` | 目录内备份 JSON 已删除；空目录因 SAF 授权挂载报 `Text file busy` 暂留（内容为空，不影响使用） |
| 备份 JSON 取证 | 已拉取留存：`docs/materials_1104b/F1_backup_1793736287730.json` |
| 阅读菜单样式 | 已恢复：工具栏样式=跟随阅读背景、颜色来源=自定义主题色且 8 个颜色=默认、每行 5、1 行、圆角 32、图标文字关、容器无底衬、浮动底栏开、标题胶囊关、标题显示方式=顶栏显示、顶栏图标无底衬、合并按钮关（CLEANUP_01/02） |
| 顶栏动作 | 已「恢复默认」 |
| 应用主题调色板 | 已恢复「关闭（内置色板）」（测试中曾临时设 Vibrant 验证 C2） |
| 应用内「文件管理」等 | 仅导航误入，无数据变更 |
| 测试脚本 | `tmp_batch3a_qa/`（adb/截图/UI dump 辅助脚本，未入库） |

## 七、设备终态

- `font_scale = 1.0`（E2 已恢复）
- 屏幕方向：竖屏（`user_rotation=0`）；`accelerometer_rotation=1`（已恢复自动旋转）
- 书架：空（已清理测试书）
- 应用：`io.legado.flutter_legado` 2.0.449（450）前台/可再次启动；`com.legado.app.release`、`io.legato.kazusa` 未改动
- 无 ANR/崩溃残留

## 八、未闭环项

1. **A3 换源顶栏/更多入口（BLOCKED）、D5 下载/换源点击（N/A 子项）**：本机只有本地 TXT 书与发现源 `QA_B2C源`，无书籍搜索书源，无法构造在线书。已在书籍详情页验证换源入口可打开（本地书报 `书源 searchUrl 为空`），顶栏动作配置页确认三者标注「仅在线书」。D5 已用「目录/界面设置」完成 2 个动作的点击验证。建议在具备在线书源的环境补验 A3 换源路径与 D5 下载/换源点击。
2. P2-1（6 动作隐藏标题）与 P2-2（调色板背景差异弱）需对照参考版或产品口径确认是否属预期。

---

编写：QA 子代理 ｜ 2026-11-04
