# 批 2b-1b-2a 设备验收报告（容器图层序 · 大容器背景图透明度 · 设置首页卡面）

> 范围：设置批 2b-1b-2a「容器外观」——IosGroup 容器背景图层序修正
> （图片铺满最底层、删除整卡 scrim、行卡满宽，图片仅从 2dp 行距露出）、
> `appColumnBackgroundOpacity`（大容器背景图自身透明度 0-100）与
> `containerOpacity` 独立叠加、滑块按「总开关 + 当前亮暗图可用」显隐、
> 设置首页手写卡片乘 `containerOpacity` 卡面 alpha；含圆角/边框/分隔线/
> 虚化/护眼/日夜/重启/备份恢复与「忽略主题配置」回归、清理与版本保留。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`）。
>
> **结论：功能验收通过（7/7 场景 PASS），附条件 1 项 P2。**
> 本批全部目标行为均实测成立；P1=0、P2=1、P3=2。唯一 P2 是设备
> **陈旧 MediaStore 记录**触发的 `file_picker` Java 线程 `FileNotFoundException`
> 崩溃（FATAL=1，可复现步骤见 §五）：触发条件与本批 Dart 改动无关，
> 属既有插件健壮性/夹具环境问题；因此本报告**不声称“FATAL=0”**，
> 严格门禁记为「FATAL 未达 0（环境触发）」。其余 ANR=0、overflow=0。
>
> 关键量化：容器图 100% 时仅 2dp 行距露出 **5px 纯红（含 AA 共 6px）**、
> 横向铺满 984px 分组宽、行卡区域 `x=48..1031` 全为不透明 `(240,240,240)`、
> 无 4dp 彩色边框；`appColumnBackgroundOpacity` 100/50/0 的缝隙像素为
> `(255,0,0)` / `(250,122,122)` / `(245,245,245)`（0 时全图无红）；
> `containerOpacity=50` 行卡 `(247,120,120)`（=50%×240+50%×红图），
> 叠加图片 50 后行卡 `(245,181,181)`、缝隙 `(250,122,122)`；
> 设置首页卡面 100→50 实测 `(240,240,240)`→`(242,242,242)`（默认浅色底
> 对比仅 5 级；改用全局壁纸场景放大为 `(240,240,240)`→`(243,182,182)`），
> 文字最深像素两态均为 `(29,29,29)` 不淡。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM_G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（3x，1dp=3px） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| **设备 root 状态** | **`adb shell id` = `uid=0(root)`**（本轮直接读取 `/data/data/<pkg>/shared_prefs/FlutterSharedPreferences.xml` 与 `files/theme_backgrounds/` 取证） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.436** / versionCode **437**（安装后与 `pm clear` 后各复核一次） |
| 源码基线 | `master` HEAD **`437edf4a0b`**（`chore: 批2b-1b-2a 收尾（2.0.436+437 双日志与计划登记）`）；工作区仅 `.zcode/` 与本报告/证据目录未跟踪 |
| 验收时间 | 2026-11-02 20:11 ~ 20:52（设备时间；设备时钟较宿主机慢约 2 分钟） |
| 证据目录 | `tmp_debug/device_acceptance_20261102_batch2b1b2a/`（logcat/data/scripts/fixtures，不入库）；截图 **73 张** 在 `docs/materials_1102/` |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（与 2b-1a/2b-1b-1 验收一致，未重建） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 90.6s`，**200,070,432 B（190.8 MB）**；sha256 `9e42c64057f1b4cb260e02024f7b7138e557abab60ffc9de2c19bcf8d2aeaebb`；构建时间 2026-11-02 20:11:23（`logcat/build_release.log`） |
| 安装 | `adb install -r` **Success: streamed 200070432 bytes** |
| 冷启动 | 安装后 `am start -W` **367 ms**；后续 362 / 381 / 349 ms |
| 清理后版本 | `pm clear` 后仍为 **2.0.436 / 437**（`data/version.txt`） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（27.7s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test test/widget/ios_group_container_test.dart test/widget/settings_home_container_test.dart test/widget/theme_container_settings_test.dart test/unit/theme_container_settings_test.dart test/widget/theme_card_style_settings_test.dart test/widget/ios_group_card_style_test.dart` | **64/64 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量 Flutter 测试 | `flutter test` | **3828 passed + 1 skipped**，EXIT=0（1:42，`logcat/full_tests.log`） |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |
| Kotlin JVM 单测 | 未执行 | 本批无 Kotlin 变更 |

> 注：构建/测试串行执行，规避 2b-1b-1 报告中「`flutter test` 与 `flutter build` 并发
> 导致 `GeneratedPluginRegistrant.java` 竞态」；本轮未复现该问题。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 层序 100%：行卡满宽/不透明，容器图仅 2dp 行距露出细线，无 4dp 彩色边框 | **PASS**（P3-1 圆角不露图） | `13_scene1_clean_red_100.png`、`13a`、`13b` |
| 2 | `appColumnBackgroundOpacity` 100/50/0（container=100） | **PASS** | `13`、`14_scene2_appcol_50.png`、`15_scene2_appcol_0.png` |
| 3 | `containerOpacity=50` 行卡半透明 + 图片 50 独立叠加 | **PASS** | `16_scene3_container50_image100.png`、`17_scene3_container50_image50.png` |
| 4 | 滑块显隐：总开关关 / 开但无图 / 有可用图 / 关后保留路径 | **PASS** | `02`、`03_switch_on_no_image.png`、`13`、`18_scene4_off_with_image_hidden.png`、`20_scene4_on_with_image_visible_settled.png` |
| 5 | 设置首页卡面 100/50：50% 透出背景，文字/图标不淡 | **PASS**（P3-2 默认浅色对比小） | `23`、`24_scene5_home_card_50.png`、`41`、`42_scene5_home_wallpaper_card50.png` |
| 6 | 回归：圆角/边框/分隔线、虚化 0/100、护眼、日夜、重启、备份恢复、忽略主题 | **PASS（功能）**；FATAL=1（环境触发，P2-1） | `26`~`29`、`39`、`40`、`50`、`49`、`53`、`58`~`64`；`logcat/crash_stale_media_20261102.txt` |
| 7 | 清理：清除背景/恢复默认/删图/空书架/保留版本 | **PASS** | `68`、`69`、`70`、`71_final_clean_launch.png`、`data/prefs_before_pmclear.xml` |

## 三、逐场景证据

### 3.1 场景 1：层序 100%（图片在最底层、行卡满宽、仅 2dp 行距露图）

- **步骤**：外观 → 容器设置 → 开「容器背景图」→「容器背景图片（日间）」选择
  纯红测试图（`container_red_day.png`，1440×2560，白字 RED DAY）→ 确认
  「容器不透明度 100」「大容器背景图透明度 100」→ 截图并按列/行采样。
- **预期**：图片铺满分组最底层且无整卡 scrim；行卡满宽、100% 不透明；
  图片仅从 2dp 行距/圆角边缘露出细线；无 4dp 彩色边框。
- **实际**：符合。测量对象为「容器设置」分组（截图 y=697 起，分组外框
  `x=48..1031`，984px = 328dp）。

| 检查点 | 实测 | 结论 |
|---|---|---|
| 分组外框 / 行卡宽度 | `x=48..1031`（984px），行卡同宽，无 4dp 水平内缩 | 满宽成立 |
| 行卡底色（100%） | `(240,240,240)`（surfaceContainerLow，alpha=1） | 不透明 |
| 行距露图（4 处行距） | 纯红 `(255,0,0)` 5px + 上下各 1px AA = **6px=2dp**；y=914..918、1136..1140、1358..1362、1742..1746（x=540 与 x=60 完全一致） | 仅 2dp 细线 |
| 露图横向范围 | 每处红带横向 **984px（x=48..1031 均为纯红 `(255,0,0)`）** | 全宽 |
| 4dp 彩色边框 | 行卡区域 `x=48/50/60/1020/1030/1031`、y=800 均为 `(240,240,240)`，无红色；红仅存在于行距 | **无 4dp 边框** |
| 圆角 | 分组左上角：首行非页面底色 x=93（top y=697），到 y=744 收至 x=48 → 半径 **≈45~48px = 15~16dp** | 16dp 成立 |
| 圆角处露图 | 左上/右上圆角 130×70px 区域红色像素 **0**（行卡 4dp 圆角小于分组 16dp 且共用 ClipRRect，图片在圆角区被行卡完全覆盖） | 见 P3-1 |

- **结论**：PASS。层序与「无整卡 scrim / 无 4dp 边框 / 满宽行卡」全部成立；
  圆角区域不露图，属实现细节（P3-1）。
  截图：`13_scene1_clean_red_100.png`，局部放大 `13a_scene1_topleft_corner_zoom.png`、
  `13b_scene1_gap_zoom.png`；首次条纹夹具截图 `10/11` 仅作过程记录。

### 3.2 场景 2：`appColumnBackgroundOpacity` 100/50/0（containerOpacity=100）

- **步骤**：保持总开关开、日间红图、容器不透明度 100；把「大容器背景图透明度」
  依次置 100/50/0（读 UI 数值并截图）；每次采样同一行距像素。
- **预期**：100 行距红线；50 行距红变淡；0 行距无红（图片完全透明）；
  行卡不随图片透明度变化。
- **实际**：全部符合，像素值与理论混合完全一致（页面底色 245）。

| 图片透明度 | UI 读数 | 行距像素（y=916, x=540） | 理论值 | 行卡像素（y=800） | 截图 |
|---|---|---|---|---|---|
| 100 | 100 | **(255,0,0)** | 纯红 | (240,240,240) | `13` |
| 50 | 50 | **(250,122,122)** | 0.5×255+0.5×245=250 / 0.5×0+0.5×245=122.5 | (240,240,240) | `14` |
| 0 | 0 | **(245,245,245)**，全图红带 0 处 | 页面底色 | (240,240,240) | `15` |

- **结论**：PASS。图片 alpha 仅乘在图片层，卡面不随其变化；0=完全透明。

### 3.3 场景 3：`containerOpacity=50` 半透明行卡 + 图片透明度独立叠加

- **步骤**：日间红图、图片透明度 100，先把「容器不透明度」置 50；再叠加
  「大容器背景图透明度」50；分别截图/采样行卡与行距。
- **预期**：50 时行卡半透明、红图从行卡透出；行距仍为全强度红；两个不透明度
  独立相乘叠加；文字不淡。
- **实际**：符合，像素值与两层 alpha 合成公式逐位一致。

| 组合 | 行卡像素 | 行距像素 | 文字最深像素 | 理论 |
|---|---|---|---|---|
| 卡 50 / 图 100 | **(247,120,120)** | (255,0,0) | (29,29,29) | 0.5×240+0.5×255=247.5；0.5×240+0.5×0=120 |
| 卡 50 / 图 50 | **(245,181,181)** | **(250,122,122)** | (29,29,29) | 0.5×240+0.5×250=245；0.5×240+0.5×122=181 |

- **补充**：两态行卡均满宽（984px），行卡边缘无 4dp 彩色边框；文字/图标
  保持不透明（最深 `(29,29,29)`，与 100% 时一致）。
- **结论**：PASS。截图：`16_scene3_container50_image100.png`、
  `17_scene3_container50_image50.png`。

### 3.4 场景 4：滑块显隐（含标题）

- **步骤**：依次构造 5 种状态，读取 `uiautomator` 语义树确认
  「大容器背景图透明度」行是否存在及其标题/数值：
  ①总开关关且无图；②总开关开但日/夜图均未设置；③开 + 日间图可用；
  ④有日间图路径但关闭总开关；⑤再次开启（路径保留）；另在深色模式
  + 夜间图可用时复核。

| 状态 | 行是否存在 | 其它观察 | 截图/证据 |
|---|---|---|---|
| 总开关关、无图 | **不存在** | 仅有容器不透明度 + 两条虚化 | `02_appearance_container_switch_off.png` |
| 总开关开、无图 | **不存在** | 「容器背景图片（日间/夜间）」两行出现，均“未设置” | `03_switch_on_no_image.png` |
| 开 + 日间图可用 | **存在**，标题 **「大容器背景图透明度」** | 数值 100；副标题“0-100；仅作用于大容器背景图自身，与容器不透明度独立叠加（0=图片完全透明）” | `13`、`14` |
| 有关闭总开关（图路径保留） | **不存在** | 两图片行同时隐藏；容器不透明度 50 保留 | `18_scene4_off_with_image_hidden.png` |
| 再次开启 | **存在**，值恢复 50 | 路径仍为原文件 | `20_scene4_on_with_image_visible_settled.png` |
| 深色 + 夜间蓝图可用 | **存在**，值 100 | 夜间图按亮暗切换生效 | `49_dark_blue_gaps_correct.png` |

- **结论**：PASS。显隐条件 =「总开关开 && 当前亮暗图片可用」；标题与副标题正确。
  单测另覆盖「文件缺失视为不可用」分支（`theme_container_settings_test.dart`）。

### 3.5 场景 5：设置首页卡面 `containerOpacity` 100/50

- **步骤**：我的 → 设置；在默认浅色主题且无全局壁纸时，分别置容器不透明度
  100/50，截取「设置」首页；再设置全局壁纸（模糊棋盘格，虚化 100）放大
  透明效果后重复 100/50 截图；采样卡片空白区与标题最深像素。
- **预期**：100 卡面不透明；50 卡面透出背景；文字/图标不淡。
- **实际**：符合。

| 背景场景 | 容器不透明度 | 卡片空白像素 | 页面/壁纸像素 | 标题/图标最深像素 | 截图 |
|---|---|---|---|---|---|
| 默认浅色底 | 100 | (240,240,240) | (245,245,245) | (29,29,29) | `23` |
| 默认浅色底 | 50 | **(242,242,242)** | (245,245,245) | **(29,29,29)** | `24` |
| 全局壁纸（模糊棋盘） | 100 | (240,240,240) | (251,128,129) | (29,29,29) | `41` |
| 全局壁纸（模糊棋盘） | 50 | **(243,182,182)** | (251,128,129) | **(29,29,29)** | `42` |

- **说明（P3-2）**：默认浅色主题 `surfaceContainerLow=240` 与页面底 245 仅差 5 级，
  50% 合成后为 242.5（取整 242），肉眼几乎不可辨；改用全局壁纸场景后
  50% 卡面明显透出壁纸（浅粉），文字/图标仍为 `(29,29,29)` 全不透明。
- **登记**：设置首页不渲染大容器背景图（2b-1b-2b 范围），`appColumnBackgroundOpacity`
  在该页无视觉作用；本批只做卡面 alpha（源码注释与单测一致）。
- **结论**：PASS。截图：`23`、`24`、`41_scene5_home_wallpaper_card100.png`、
  `42_scene5_home_wallpaper_card50.png`。

### 3.6 场景 6：回归

#### 3.6.1 圆角覆盖 / 卡片边框 / 分隔线（与图片层共存）

- **步骤**：日间红图 + 容器不透明度 100；开「覆盖卡片圆角」置 40dp；再开
  「覆盖卡片边框」置 3dp；再开「显示分隔线」置 3dp；逐项截图并测量；
  结束后全部关闭。
- **预期**：三项覆盖仍生效；不改变卡片外框/文字位置；不出现 4dp 彩色边框；
  图片只从行距露出。
- **实际**：

| 检查点 | 实测 | 截图 |
|---|---|---|
| 圆角 40dp | 分组顶行首个非页面底色 x=162，到 +119px 收至 x=48 → **≈114px=38dp**（阈值法系统性低约 5%；40dp=120px） | `26_reg_radius40_group_top.png` |
| 边框 3dp | `x=48..56` 共 **9px** 实线，颜色 `(216,196,190)`（outlineVariant）；卡片外框仍 `x=48..1031`，行距红带仍 5px | `27_reg_border3_radius40.png` |
| 分隔线 3dp | 厚度 **9px**，颜色 `(219,41,41)` = 30% 灰叠在红图上（0 色回落灰 30%）；长度 `x=147..932`=**786px = 79.9%（默认 80%）**；线上下各保留 2dp 红距 | `28`、`29_reg_divider3_with_image.png` |
| 无 4dp 边框 | 行卡边缘全为卡面色 240；红色只出现在行距/分隔线缝隙 | `13`、`29` |
| 全部关闭 | 三开关 `checked=false`，行距回到 2dp 红线 | `30_reg_all_style_off.png` |

#### 3.6.2 虚化 0/100

- **步骤**：自定义主题·白天 → 背景图片选择棋盘格（1200×1600，`BLUR CHECK`）；
  外观 → 容器设置 → 「背景图虚化（日间）」0/100，截取外观页；测量页面
  左右边缘（x=0..43）亮度标准差。
- **实际**：虚化 0 边缘棋盘清晰，标准差 **79.1**；虚化 100 边缘均匀粉色，
  标准差 **3.0**；卡片、文字、滑杆不随虚化变化。截图：
  `39_blur0_checker.png`、`40_blur100_checker.png`。
- **结论**：PASS（虚化仅作用于全局壁纸，与容器图无关；与本批登记语义一致）。

#### 3.6.3 护眼叠加

- **步骤**：深色 + 夜间蓝图 + 容器不透明度 100；开「启用护眼模式」（色温 50），
  截取容器分组；关闭复核。
- **实际**：全屏暖色叠加；蓝色行距由 `(0,0,255)` 变为 **`(0,0,182)`**，
  共 **28,018 px** 连成行距；文字可读，布局不变。截图
  `50_eye_on_dark_blue_gaps.png`、`51_eye_off_restored.png`。
- **结论**：PASS。

#### 3.6.4 日/夜切换

- **步骤**：日间红图 + 夜间蓝图（均纯色、白字）；主题模式切「深色」；
  在「容器设置」分组截取行距并全图统计纯色像素。
- **实际**：深色下分组卡面 `(29,32,36)`；行距纯蓝 `(0,0,255)` 共 **26,272 px**，
  纯红 **0 px**；行距带 5px（y=458..462、680..684 等）。截图
  `49_dark_blue_gaps_correct.png`。
- **结论**：PASS。亮暗各取对应图片（`Theme.of(context).brightness`）。

#### 3.6.5 重启保持

- **步骤**：保持深色 + 日红/夜蓝 + 容器 100 + 图片 100 + 日间虚化 100；
  `am force-stop` → 冷启动 → 我的→设置→外观→容器设置复核数值与像素。
- **实际**：主题仍深色；两个图片路径保持；滑块 100/100/日间虚化 100/夜间 0；
  行距纯蓝 **25,225 px**、纯红 0；冷启动 **381 ms**。截图
  `52_restart_launch_dark.png`、`53_restart_dark_blue_gaps.png`。
- **结论**：PASS。

#### 3.6.6 本地备份 → 修改 → 同会话恢复

- **步骤**：备份路径设为 SAF 新建目录
  `/storage/emulated/0/Download/legado_qa_1102` → 点「备份」→ 读取
  `legado_backup_1793623215916.json`；把容器不透明度 100→50、图片透明度
  100→50、日间虚化 100→0；长按「恢复」选择该 JSON → 确认；不重启复核。
- **实际**：
  - 备份 JSON **1312 B**，含 `containerOpacity=100`、
    `appColumnBackgroundOpacity=100`、`backgroundImageBlurring=100`、
    `enableContainerBackgroundImage=true`、日/夜图片路径（`data/backup_before.json`）。
  - 恢复后 prefs 与 UI 同会话回到 **100/100/100**；截图
    `59_values_changed_before_restore.png`、`60_after_restore.png`、
    `61_after_restore_appearance.png`。
- **结论**：PASS。

#### 3.6.7 恢复忽略列表「主题配置」

- **步骤**：恢复忽略列表勾选「主题配置」→ 确定；容器不透明度/图片透明度
  改 30/30；再次恢复同一 JSON；查 prefs 与 UI。
- **实际**：`containerOpacity` 保持 **30**（主题配置被忽略）；新增
  `appColumnBackgroundOpacity` 恢复为 **100**（按参考版归组，刻意不在
  `themePrefKeys`，随 appPrefs 往返）；主题模式 dark 保持不变。
  截图 `62_ignore_values_30.png`、`63_after_ignore_restore.png`、
  `64_ignore_result_ui.png`。
- **结论**：PASS（与本批提交说明的归组设计一致）。

#### 3.6.8 崩溃 / ANR / overflow

| 项 | 计数 | 证据 |
|---|---|---|
| FATAL EXCEPTION | **1**（`20:26:35.960`，环境触发，P2-1） | `logcat/session_full.log:14679`、`logcat/crash_stale_media_20261102.txt` |
| ANR in `io.legado.flutter_legado` | **0** | 全量 logcat grep |
| RenderFlex overflow | **0** | 全量 logcat grep |
| `pm clear` 后最终启动 | 0 FATAL/ANR/overflow | 最近 2000 行 logcat |

### 3.7 场景 7：清理与版本保留

| 步骤 | 结果 | 证据 |
|---|---|---|
| 清除日/夜容器图 | 两行均“未设置”；`files/theme_backgrounds/large_*` 随 `pm clear` 移除 | `68_cleanup_container_defaults.png` |
| 关闭总开关 | `checked=false`，图片行与图片透明度行隐藏 | `69_cleanup_switches_off.png` |
| 恢复默认值 | `containerOpacity=100`、`appColumnBackgroundOpacity=100`、虚化 0/0、主题 system | `data/prefs_before_pmclear.xml` |
| 清除全局壁纸 | 自定义主题·白天背景图片“未设置” | `data/prefs_before_pmclear.xml` |
| 关联卡片样式开关 | 关闭分组圆角/圆角覆盖/边框/分隔线全部 `checked=false` | UI 语义树 |
| 删除测试图 | `/sdcard/Download/container_red_day.png`、`container_blue_night.png`、`container_blur_checker_1102.png` 删除，MediaStore 记录同步清除 | `data/download_after_cleanup.txt`（输出 `clean_download`） |
| 删除备份目录 | `/sdcard/Download/legado_qa_1102` 删除 | adb `rmdir` 成功 |
| 空书架 | `pm clear` 后冷启动空书架 | `71_final_clean_launch.png` |
| 版本保留 | **2.0.436 / 437** | `data/version.txt` |

## 四、问题清单与分级

| 级别 | 编号 | 描述 | 复现步骤 / 证据 | 归属 |
|---|---|---|---|---|
| P1 | — | 无 | — | — |
| P2 | P2-1 | 选择 MediaStore 中已删除文件的陈旧缩略图时，`file_picker` Java 线程抛出 `FileNotFoundException`，应用 FATAL 崩溃（`Thread-13`） | 设备 Download 中 `qa_day_red_3000x2000.png` 文件已不存在，但 MediaStore 仍保留记录（`data/mediastore_stale_entries.txt`）；照片选择器缓存显示该缩略图，点选后 20:26:35.960 崩溃，堆栈 `ContentResolver.openInputStream → t3.u0.a`（`logcat/crash_stale_media_20261102.txt`）。期望：提示文件不可用并留在设置页；实际：进程被杀回桌面 | **环境/夹具触发 + 既有插件健壮性**；本批改动仅 Dart UI/测试文件，未触及 file_picker/Android；不计为本批功能回归，但 FATAL 门禁未达 0 |
| P3 | P3-1 | 分组圆角处不露出容器图（0 红色像素），图片只从 2dp 行距露出 | 场景 1 左上/右上 130×70px 圆角区红像素 0；行卡 4dp 圆角小于分组 16dp 且共用 ClipRRect，圆角区被行卡完全覆盖（`13a`） | 视觉细节；与「无 4dp 边框、仅细线」主目标不冲突，登记待产品确认是否需要圆角露线 |
| P3 | P3-2 | 默认浅色主题下设置首页 100/50 的视觉差异仅 2 级（240→242），肉眼难辨 | 场景 5 表；改用全局壁纸放大后 50% 明显透背景（243,182,182） | 调色板低对比所致，非功能缺陷 |

## 五、结论与建议

- **功能结论**：本批 7 组场景全部 PASS。层序修正达到参考版语义：图片铺满
  分组最底层、无整卡 scrim、行卡满宽且 100% 不透明，图片仅从 2dp 行距
  以细线露出（5px 纯色 + AA），无 4dp 彩色边框；`appColumnBackgroundOpacity`
  与 `containerOpacity` 两个 alpha 通道独立叠加，像素级与理论公式一致；
  滑块按「开关 + 当前亮暗图可用」显隐且标题正确；设置首页卡面 alpha 生效、
  文字/图标不淡；圆角/边框/分隔线/虚化/护眼/日夜/重启/备份恢复均回归通过。
- **门禁结论**：`flutter analyze` 0、定向 64/64、全量 3828+1 skipped、
  release 构建 EXIT=0。**FATAL 未达 0（1 次，环境/陈旧 MediaStore 触发，
  非本批 diff）**；ANR=0、overflow=0。已登记 P2-1，建议另立
  file_picker/媒体选择健壮性修复项（选择前校验 URI 可读、捕获
  `FileNotFoundException` 并提示）。
- **建议**：P3-1 若产品要求「圆角边缘也露细线」，需让行卡圆角大于分组圆角
  或取消分组级裁剪；P3-2 无需处理，验收时以壁纸场景或像素采样为准。
- **证据路径**：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261102_BATCH2B1B2A.md`
  - 截图（73 张）：`docs/materials_1102/`
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261102_batch2b1b2a/`
    （`logcat/analyze.log`、`full_tests.log`、`targeted_tests.log`、
    `build_release.log`、`session_full.log`、`crash_stale_media_20261102.txt`；
    `data/backup_before.json`、`prefs_before_pmclear.xml`、`version.txt`）

---

## 六、SAF 回修复验（2026-11-02 21:15–21:35）

> 触发：§四 P2-1（陈旧 MediaStore 缩略图 → file_picker 原生 FATAL）。
> 修复提交 **`4d7f09ba4b`**（`fix(ui): 批2b-1b-2a Android 容器图改 SAF 选择`）：
> 新增 `ContainerImagePicker`，Android 走 `Saf().pickFile(mimeTypes:['image/*'])`
> + `withFileDescriptor` 字节读取；取消返回 null；SAF 异常仅 toast，不降级
> file_picker；落盘改走 `ThemeBackgroundImageStore.storeBytes`（32MB/可解码
> 校验与 tmp+rename 原子写）。
>
> **结论：7/7 场景 PASS；FATAL=0（基线 1 → 本次 0）；P2-1 关闭。**
> 全流程应用 PID 恒为 **33103**（除验收结束 `pm clear` 后 36033，预期）；
> 9 次选图全部为 `com.android.documentsui/.picker.PickActivity`
> （`ACTION_OPEN_DOCUMENT`），无照片选择器（`PICK_IMAGES`）启动。

### 6.1 复验门禁与产物

| 项 | 值 |
|---|---|
| 源码 HEAD | **`4d7f09ba4b`**（工作区仍仅 `.zcode/`、本报告与证据目录未跟踪） |
| 版本 | **2.0.436 / 437**（安装后与 `pm clear` 后各复核一次；`data/version.txt`、`data/version_after_pmclear.txt`） |
| Flutter 静态分析 | `flutter analyze` **No issues found!** EXIT=0（10.1s，`logcat/analyze.log`） |
| 定向测试 | `flutter test test/unit/container_image_picker_test.dart test/unit/theme_background_image_store_test.dart test/widget/theme_container_settings_test.dart` → **37/37 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| 全量测试 | `flutter test` → **3837 passed + 1 skipped**，EXIT=0（1:34，`logcat/full_tests.log`） |
| Release 构建 | `flutter build apk --release` EXIT=0，`assembleRelease 26.7s`；APK **200,070,432 B（190.8 MB）**；sha256 **`d5ccc628f500f288a817facdb5d9e0620909f5480ec03f726af47fa553be454d`**（`logcat/build_release.log`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200070432 bytes** |
| 冷启动 | 安装后 `am start -W` **341 ms**；`pm clear` 后 **324 ms** |
| 日志窗口 | `logcat/session_full.log` **14,259 行**（21:15–21:34，含全部选图与回归操作） |

### 6.2 修复前后对照（同一台设备、同一批陈旧记录）

| 维度 | 基线（`437edf4a0b`，file_picker） | 本次（`4d7f09ba4b`，SAF） |
|---|---|---|
| 选图入口 | 照片选择器 / file_picker MediaStore 路径 | **DocumentsUI `ACTION_OPEN_DOCUMENT`**（9/9 次） |
| 陈旧记录 `image:1000001532`（`qa_day_red_3000x2000.png`，文件已删除） | 点选后 **FATAL=1**（`20:26:35.960`，`Thread-13`，`t3.u0.a` → `ContentResolver.openInputStream` ENOENT） | **SafNotFoundException 被捕获**，toast「无法打开系统图片选择器，请重试」，进程存活 |
| 陈旧记录 `image:1000001540`（`qa_day_red.png`，文件已删除） | 未单独复测（同类路径） | 同上，toast，进程存活 |
| FATAL 计数 | **1** | **0**（14,259 行 logcat；`grep FATAL EXCEPTION` = 0） |
| PID | 崩溃致死（22457 → 新进程） | **33103 全程不变**（两轮陈旧项前后均核对） |
| 选图后落盘 | 受插件压缩/路径解析影响 | fd 读字节 → md5 命名 → 原子写；正常图/12MP 均成功 |
| 伪图片 / 超大图 | 依赖 allowCompression=false 与 UI 侧校验 | SAF 读取后引擎试解码（伪图 toast）；SAF 元数据 >32MB **读取前拒绝** |

### 6.3 场景结果表（回修复验）

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 正常选图：SAF DocumentsUI → Download 正常 PNG → 落盘/设置页显示/无崩溃 | **PASS** | `01_saf_documentsui.png`、`02_scene1_after_pick.png`；log `[ContainerImagePicker] 平台=Android SAF 读取 saf_red_day.png (16663 bytes)` |
| 2 | 取消：打开 SAF 后返回 → 无变化、无崩溃 | **PASS** | `05_scene2_saf_open.png`、`06_scene2_cancelled.png`；log `平台=Android SAF 用户取消` |
| 3 | 陈旧 MediaStore 项：DocumentsUI 仍列出已删除文件 → 选中不 FATAL | **PASS（P2-1 关闭）** | `07`、`08`、`09_scene3_toast.png`；log `SafNotFoundException ... image%3A1000001540 / %3A1000001532 ... ENOENT` |
| 4 | 伪图片：`.txt` 改名 `.png` 经 SAF 选 → 不崩溃、明确 toast | **PASS** | `10_scene4_fake_toast.png`；log `FormatException: 不是可解码的图片：saf_fake.png` |
| 5 | 大图：>32MB 读取前拒绝；12MP 正常落盘 | **PASS** | `13_scene5_33mb_toast.png`、`15_scene5_12mp_stored.png`；log `Android SAF 文件过大: 34604032 bytes` + `读取 saf_12mp_green.jpg (188630 bytes)` |
| 6 | 回归：图层序 100/50/0、图片透明度、设置首页卡面、圆角/边框/分隔线/护眼、FATAL=0 | **PASS** | `17`~`23`、`25`~`28`；像素采样见 §6.4.6 |
| 7 | 清理：清图/恢复默认/删测试图/空书架/保留版本 | **PASS** | `29_scene7_cleanup_defaults.png`、`30_final_clean_launch.png`、`data/prefs_before_pmclear.xml` |

### 6.4 逐场景证据

#### 6.4.1 场景 1：正常选图（SAF）

- **步骤**：我的 → 设置 → 外观 → 容器设置 → 开「容器背景图」→
  「容器背景图片（日间）」→「选择图片」。
- **入口确认**：`ActivityTaskManager` 21:19:40.882
  `START u0 {act=android.intent.action.OPEN_DOCUMENT ... cmp=com.android.documentsui/.picker.PickActivity}`；
  `uiautomator` dump 的 package 计数为 `com.android.documentsui` 163 个节点，
  页面标题「最近 / 近期的图片」，**不是**相册缩略图选择器（截图 `01`）。
- **选择**：Download 中 `saf_red_day.png`（1440×2560 纯红，16,663 B）。
- **实际**：
  - log `21:19:59.343 I/flutter (33103): [ContainerImagePicker] 平台=Android SAF 读取 saf_red_day.png (16663 bytes)`；
  - 落盘 `files/theme_backgrounds/large_light/d5935fa607fe0f960879a3ca1a3c54ec.png`，
    文件名 md5 与宿主 `md5sum saf_red_day.png` = `d5935fa607fe0f960879a3ca1a3c54ec` 一致；
  - 设置页日间行显示 `d5935fa...c54ec.png`，并出现「大容器背景图透明度」行；
  - `PID=33103` 不变，FATAL=0；截图 `02`。
- **结论**：PASS。

#### 6.4.2 场景 2：取消

- **步骤**：再次点日间行 →「选择图片」→ DocumentsUI（`05`）→ 系统返回键。
- **实际**：log `21:21:22.616 [ContainerImagePicker] 平台=Android SAF 用户取消`；
  返回外观页，日间行仍为「未设置」，无新文件、无崩溃（`06`），PID=33103。
- **过程说明**：首轮复验时因「已设置图片」状态下弹窗新增「清除图片」按钮、
  坐标与「未设置」状态不同，误触清除（`_process/03_mistap_after_clear.png`、
  `_process/04_mistap_settings_page.png`）；随后重新设置并严格按 dump 坐标重测，
  该误触也顺带验证了清除路径。另有一次点击设置首页「备份与恢复」打开
  WebDAV 弹窗（`_process/24_mistap_webdav_dialog.png`），已取消恢复。
- **结论**：PASS。

#### 6.4.3 场景 3：陈旧 MediaStore 项（P2-1 复测）

- **构造/取证**：设备 Download 中以下文件**已不存在**，但 MediaStore 仍保留行
  （`data/download_old_entries.txt`、`data/mediastore_stale_probe.txt`）：

  | `_id` | `_display_name` | `_size` | 文件是否存在 |
  |---|---|---|---|
  | 1000001540 | `qa_day_red.png` | 5,782 | **MISSING** |
  | 1000001532 | `qa_day_red_3000x2000.png` | 72.46 kB | **MISSING**（与基线崩溃同一行号） |

- **入口观察**：DocumentsUI「最近」仍显示这些条目（`07`；dump 可见
  `qa_day_red.png, 5.78 kB`、`qa_day_red_3000x2000.png, 72.46 kB`）。
- **实际**：
  - 选中 `qa_day_red.png`（`image:1000001540`）→
    log `21:21:41.870 [ContainerImagePicker] 平台=Android SAF 失败:
    SafNotFoundException(content://com.android.providers.media.documents/document/image%3A1000001540):
    open failed: ENOENT (No such file or directory)` →
    `ThemeConfigScreen... 选择失败: 无法打开系统图片选择器，请重试`；
    截图 `08` 可见 toast，页面仍为「未设置」。
  - 选中 `qa_day_red_3000x2000.png`（`image:1000001532`）→
    log `21:22:07.576` 同样的 SafNotFoundException；截图 `09` toast 清晰可读。
  - 两次前后 `PID=33103` 不变；FATAL 计数 **0**；无 `has died` / `am_crash`。
- **结论**：PASS。**P2-1 关闭**：曾经触发原生 FATAL 的同一批陈旧记录，
  在 SAF 路径下退化为「toast + 留在设置页」。
- **残余观察**：DocumentsUI 仍会列出已删除文件的陈旧条目（系统 MediaStore
  行为，应用无法控制）；应用侧已不再经 file_picker/MediaStore 打开它们。

#### 6.4.4 场景 4：伪图片

- **步骤**：`saf_fake.png`（38 B 纯文本改名）经 SAF 选择。
- **实际**：log `21:22:32.388` 读取 38 B 后
  `FormatException: 不是可解码的图片：saf_fake.png`；
  toast「设置容器背景图失败：不是可解码的图片：saf_fake.png」（`10`）；
  未落盘，PID=33103，FATAL=0。
- **结论**：PASS。

#### 6.4.5 场景 5：大图（>32MB 与 12MP）

- **>32MB**：构造 `saf_33mb_padded.png` = **34,604,032 B**（33MB+1KB，
  有效 PNG 头 + 填充）。DocumentsUI 显示「34.60 MB」。
  选中后 log 仅出现
  `21:24:23.670 [ContainerImagePicker] Android SAF 文件过大: 34604032 bytes`，
  **无「读取」日志**（元数据阶段拒绝，未把内容读入 Dart 堆）；toast
  「图片过大（上限 32MB）」（`13`）。
  - `dumpsys meminfo` 前后：TOTAL PSS **127,923 → 122,503 KB**，
    Native Heap **27,460 → 27,448 KB**，无 OOM / lowmemorykiller。
- **12MP**：`saf_12mp_green.jpg`（4000×3000，188,630 B）→ log
  `21:25:26.359 ... 读取 saf_12mp_green.jpg (188630 bytes)`；落盘
  `large_light/2de7320652637b73320ac392c7ea6223.jpg`（宿主 md5 =
  `2de7320652637b73320ac392c7ea6223`），设置页显示该文件名（`15`）。
  PID=33103，FATAL=0。
- **说明（环境）**：另构造的 48MB 随机图在 DocumentsUI 可见，但
  MediaProvider 扫描时因 MuMu `vboxsf` 存储不支持 project quota
  （`Failed to update quota type ... Inappropriate ioctl for device`）未能入库；
  故以 33MB 文件完成 >32MB 门禁验证。该限制属模拟器存储，不影响应用侧结论。
- **结论**：PASS。

#### 6.4.6 场景 6：回归

| 检查点 | 实测（像素/语义） | 结论 |
|---|---|---|
| 层序 100（红图） | 行距红带 **y=1348..1352、1570..1574、1792..1796（5px=2dp）**；横向 **x=48..1031（984px）** 全宽；行卡 `(240,240,240)` 不透明（`17`） | PASS |
| 图片透明度 49 / 0 | 49 时行距 `(250,125,125)`（理论 0.49×255+0.51×245=250 / 125）；0 时行距 `(245,245,245)`、全图无红（`19`、`20`） | PASS |
| 容器不透明度 49 + 图片 98 | 行卡 `(248,120,120)`（理论 0.49×240+0.51×255=248 / 0.49×240+0.51×5=120），层间叠加正确（`21`） | PASS |
| 设置首页卡面 100 / 49 | 卡片 `(240,240,240)` → `(242,242,242)`，页面底 `(245,245,245)`；与基线一致（`22`、`23`） | PASS |
| 边框 1dp | 卡片左缘 x=48 为 `(216,196,190)`（outlineVariant），内侧 `(240,240,240)`（`26`） | PASS |
| 分隔线 1dp | 开启后行间红带上出现 3px `(219,41,41)`（30% 灰叠在红图上，y=312..314），与 2dp 露图红带叠加（`26`）；关闭后恢复（`ui_styles_all_off.xml` 三个开关均 `checked=false`） | PASS |
| 覆盖卡片圆角 | 开关开启（`27`），关闭后 `checked=false` | PASS |
| 护眼模式 | 页面底由 `(245,245,245)` → `(240,205,172)` 暖色；关闭后复归（`28`） | PASS |
| FATAL / ANR / overflow | 全量 14,259 行：**FATAL=0、ANR=0、RenderFlex overflow=0、lowmemorykiller=0、进程死亡=0**；Android crash buffer 1,477 行全部为 `uiautomator` 工具进程 SIGSEGV（该机 dump 后自杀的已知噪声），**0 条涉及 `io.legado`** | PASS |

- **补充**：回归段所有选图操作同样走 SAF（9 次 `OPEN_DOCUMENT` 全部命中
  `documentsui/.picker.PickActivity`；`PICK_IMAGES` 启动 0 次；log 中
  `file_picker`/`FilePicker` 字样 0 次）。

#### 6.4.7 场景 7：清理与版本保留

| 步骤 | 结果 | 证据 |
|---|---|---|
| 清除日/夜容器图 | 两行恢复「未设置」；`files/theme_backgrounds/large_*` 目录为空 | `29`、`data/theme_files_both.txt` 后续 `find` 为空 |
| 关闭总开关 | `容器背景图 checked=false`，图片行隐藏 | `29` |
| 恢复默认 | prefs：`containerOpacity=100`、`appColumnBackgroundOpacity=100`、`enableContainerBackgroundImage=false`；图片路径键已清空 | `data/prefs_before_pmclear.xml` |
| 卡片样式开关 | 圆角/圆角覆盖/边框/分隔线全部 `checked=false` | `data/ui_styles_all_off.xml` |
| 删除测试图 | `/sdcard/Download/saf_*` 全部删除（`ls` 无匹配，输出 `clean_download`） | `data/download_after_cleanup.txt` |
| 空书架 | `pm clear` 后冷启动空书架（324 ms） | `30_final_clean_launch.png` |
| 版本保留 | **2.0.436 / 437** | `data/version_after_pmclear.txt` |

- **环境备注（不影响结论）**：MediaStore 的 `files_delete` 触发器中调用了
  MediaProvider 进程私有的 `_DELETE()` 函数，外部 `sqlite3` 无法直接删除行
  （报 `no such function: _DELETE`），因此已删除测试文件在 MediaStore 中可能
  残留陈旧行（与基线 P2-1 的成因一致）。应用侧已不受其影响；如需彻底清理，
  需通过 MediaStore API 或系统相册删除。

### 6.5 问题清单（本次回修）

| 级别 | 编号 | 描述 | 处理/建议 |
|---|---|---|---|
| P2 | P2-1（原） | 陈旧 MediaStore 项经 file_picker 触发原生 FATAL | **关闭**：Android 改 SAF 后同一批记录仅 toast，PID 不变，FATAL=0 |
| P3 | P3-3（新增） | 陈旧项读取失败的 toast 文案为「无法打开系统图片选择器，请重试」，未区分「文件不存在/读取失败」 | 建议后续按异常类型细分文案（例如「文件已失效，请重新选择」），不影响功能 |
| — | 环境 | DocumentsUI 仍显示已删除文件的陈旧条目 | 系统 MediaStore 行为；应用侧已不依赖该路径 |

### 6.6 回修复验结论

- **功能**：SAF 选图在正常图、取消、陈旧项、伪图、33MB 超限、12MP 六类输入下
  行为均符合预期；图层序/透明度/首页卡面/圆角/边框/分隔线/护眼回归通过。
- **稳定性**：全流程 **FATAL=0、ANR=0、overflow=0**，应用 PID 33103 全程存活
  （仅验收结束 `pm clear` 后变为 36033）。基线 P2-1 的 FATAL 不再复现。
- **P2 状态**：**P2-1 关闭**；仅保留 P3-3 文案建议。
- **证据路径**：
  - 截图：`docs/materials_1102/reverify_saf/`（主证据 28 张，另有
    `_process/` 3 张过程记录）
  - 日志/数据/夹具：`tmp_debug/device_acceptance_20261102_reverify_saf/`
    （`logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
    `build_release.log`、`session_full.log`、`crash_buffer.txt`；`data/apk_sha256.txt`、
    `version.txt`、`version_after_pmclear.txt`、`mediastore_stale_probe.txt`、
    `prefs_before_pmclear.xml`、`meminfo_before_33mb.txt`、
    `meminfo_after_33mb.txt`；`fixtures/` 测试图）
