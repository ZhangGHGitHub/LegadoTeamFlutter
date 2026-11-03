# 批 2b-1b-2b 设备验收报告（全局卡面不透明度 · 项目背景图 · 九宫格 `.9`）

> 范围：版本 **2.0.441+442**（HEAD `ff42a79be8`）设置批 2b-1b-2b 设备验收：
> 全局 CardTheme 卡面不透明度、项目（卡片）背景图 100/50/0 与水波纹、
> 真实/构造 `.9.png` 九宫格拉伸与回落、组合外观（边框/圆角/护眼/大字体）、
> 大图内存、持久化与本地备份恢复、回归与清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`），Android 15 / SDK 35 / x86_64；
> 1080×1920 / 480 dpi（360×640 dp）。验收期间实例曾一次重启（见 O-1）。
>
> **结论：8 组场景全部 PASS（P1=0、P2=0、P3=4 登记、环境观察 3 项）。**
> 卡面不透明度 100/50/0 在默认 CardTheme（含显式 shape 未设色）上按 alpha
> 正确叠加，显式 color 卡片不变；项目图 100/50/0 在设置行卡/设置首页可见、
> 半透、隐藏，100% 时行点击与水波纹正常；真实 `0x.9.png` 与构造单区域 `.9`
> 均按 centerSlice 拉伸，`1J` 多区域与源码形态（无 npTc）回落 cover；
> 组合外观在 1.3/1.6 字体下无溢出；12MP `.9` 与 35MP 超限回落均无 OOM；
> 四键重启保持，本地恢复同会话生效，「忽略主题配置」未过滤新键；
> 最终 FATAL=0、ANR=0、overflow=0、OOM=0、E/flutter=0。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ x86_64 |
| 分辨率 / 密度 | 1080×1920 / 480 dpi（360×640 dp） |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 设备 root | `adb shell id` = `uid=0(root)`（重启后重新 `adb root` 恢复） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.441** / versionCode **442**（安装后、清理后各复核） |
| 源码基线 | `master` HEAD **`ff42a79be8ab138f281fa044bbe0686f505ebeca`**（`chore: 2b-1b-2b 收尾（2.0.441+442 双日志与计划登记）`，2026-11-03 13:56:47） |
| 验收时间 | 2026-11-03 13:59 ~ 15:22（宿主时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261103_batch2b1b2b/`（logcat/data/shots/scripts，不入库） |
| 截图 | `docs/materials_1107/`（58 张，`s1_*`~`s8_*`、`b2b_*`） |

### 1.1 构建产物（仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（本批无 Rust/FFI 变更） |
| x86_64 `.so` | `liblegado_ffi.so` **51,883,696 B**，mtime **2026-10-31 23:45**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（`data/so_info.txt`） |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 42.9s`，**200,435,412 B（191.2 MB）**；sha256 **`68f673d57e53e3f24f46501d75acb080ede974046bdebf7bf9cd5eb1cdc79cab`**（`logcat/build_release.log`、`data/apk_sha256.txt`） |
| 安装 | `adb install -r` **Success: streamed 200435412 bytes**（`logcat/install.log`）；安装后设备侧 `base.apk` sha256 与构建产物**一致**（`data/apk_sha256_installed.txt`） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（15.6s，`logcat/analyze.log`） |
| 本批定向测试 | `flutter test`（`nine_patch_test`、`theme_item_background_test`、`ios_group_item_background_test`、`theme_container_settings_test`、`settings_home_item_background_test`、`settings_home_container_test`、`theme_card_style_settings_test`、`ios_group_card_style_test`、`theme_background_layer_test`） | **110/110 passed**，EXIT=0（`logcat/targeted_tests.log`） |
| ui_settings 补充 | `flutter test test/widget/ui_settings_test.dart` | **3/3 passed**，EXIT=0 |
| 全量 Flutter 测试 | `flutter test` | **4037 passed + 1 skipped**，EXIT=0（1:38，`logcat/full_tests.log`） |
| Release 构建 / 安装 | `flutter build apk --release` + `adb install -r` | EXIT=0 / Success（见 §1.1） |

> 定向测试首次命令误把 `ui_settings_test.dart` 写成 `test/unit/`（实际在
> `test/widget/`），产生一条 “Does not exist” 载入失败；修正路径后 3/3 通过。
> 该失败为 QA 命令路径笔误，非代码/测试失败；全量测试已覆盖。

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 全局 CardTheme 不透明度 100/50/0：默认卡片、显式 shape 未设色卡片；显式 color 不变；透明调色板/深色不为纯白 | **PASS** | `s1_01`~`s1_09`；`data/dict100.xml`、`s1_50_dict_exact2`、`s1_0_dict`、`s1_0_selected` |
| 2 | 项目背景图（普通 PNG）：100/50/0、水波纹、独立叠加、日夜切换、清图/缺文件回落；大容器图透明度 100/50/0 | **PASS**（P3-1） | `s2_01`~`s2_16`；`data/after_pick.xml`、`backup_s1.json` |
| 3 | `.9` 九宫格：真实 `0x` 大容器/项目图；构造单区域 centerSlice；`1J` 多区域回落；源码形态回落；12MP/35MP/9k | **PASS**（P3-3） | `s3_01`~`s3_14`、`s5_01`、`s5_02` |
| 4 | 组合：容器图 + 项目图 + 边框/圆角 + 护眼 + 字体 1.3/1.6；设置页/设置首页无溢出 | **PASS**（P3-2） | `s4_01`~`s4_04`；`data/s4_font13_counts.txt`、`s4_font16_counts.txt` |
| 5 | 内存：12MP `.9`、35MP 超限 `.9`、12MP JPG；RSS/PSS；无 OOM | **PASS**（O-2） | `data/mem_*.txt`、`s3_11`~`s3_14`、`s5_01`、`s5_02` |
| 6 | 持久化/恢复：重启保持四键；本地备份→改值→恢复同会话生效；「忽略主题配置」不过滤新键 | **PASS**（P3-1） | `s6_01`~`s6_06`；`data/backup_s1.json`、`data/confirm.xml` |
| 7 | 回归：设置页/阅读/主题/容器背景/卡片样式；FATAL/ANR/overflow/OOM=0 | **PASS**（O-1） | `s7_01`、`s7_02`；`data/s7_stability_counts.txt` |
| 8 | 清理：清除图片/大图、恢复默认、空书架、保留版本 | **PASS** | `s8_01`~`s8_04`；`data/version_final.txt`、`data/prefs_cleanup_fixed.xml` |

## 三、逐场景证据

### 3.1 场景 1：全局 CardTheme 不透明度（PASS）

**步骤**：外观→容器设置→「容器不透明度」滑杆（真实 UI 点击，读数 51/53）；
另以精确值 50/0（root 写入偏好后重启）复核像素；在同一「字典规则管理」页
（`Card` 使用显式 16dp shape、未设 color；选中行显式 `primaryContainer`）
逐档采样；再切深色/透明调色板复核。

| 档位 | 默认卡片采样（屏幕像素） | 背景采样 | 判定 |
|---|---|---|---|
| 100% | `(600,300)=(255,255,255)`；`(900,330)=(255,255,255)` | `(30,300)=(245,245,245)` | 卡面白，正常 |
| 50%（精确 50） | `(600,300)=(250,250,250)`；`(500,700)=(250,250,250)` | `(30,300)=(245,245,245)` | 0.5×255+0.5×245≈250，alpha 乘算成立 |
| 0% | `(600,300)=(245,245,245)`；`(540,1000)=(245,245,245)` | `(30,300)=(245,245,245)` | 卡面完全透明，等于背景 |
| 50%（滑杆 UI 51） | 设置行卡 `(250,250,250)`；My 行卡 `(242,242,242)`（叠在分组底 229 上） | 245 | 滑杆真实路径同样生效 |
| 显式 color（选中行） | 51% 与 0% 均为 `(250,218,211)` | — | 显式 color 不受 containerOpacity 影响 |
| 深色 50% | 卡面 `(22,26,30)`；背景 `(16,20,24)` | — | 深色下非纯白 |
| 透明调色板 50% | 卡面 `(6,6,6)`；背景 `(0,0,0)` | — | 透明调色板未被洗成白卡 |

- **证据**：`s1_01_cardtheme100_dict`、`s1_02_slider_real_ui_51`、
  `s1_03_cardtheme50_dict`、`s1_04_cardtheme0_dict`、
  `s1_05_explicit_color_selected_51`、`s1_06_explicit_color_selected_0`、
  `s1_07_my_rows_50`、`s1_08_dark50_dict`、`s1_09_transparent_palette50_dict`。
- **说明**：滑杆点击分辨率为约 3 px/1%，真实 UI 路径读数为 51/53；
  像素与精确 50% 的验证使用 root 写入 `containerOpacity=50` 后冷启，
  两者在像素上连续一致（250 vs 249.8）。
- **结论**：PASS。

### 3.2 场景 2：项目背景图（PASS，P3-1）

**步骤**（真实用户路径）：外观→容器设置→开「容器背景图」→
「项目背景图片（日间）」→「选择图片」→ 系统 SAF 选择
`/sdcard/Download/qa_plain.png`；同样路径选择「项目背景图片（夜间）」=
`qa_night.png`；滑杆调整项目图透明度；随后清除图片、删除文件、切换日夜。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| SAF 选图 | 落盘到 `theme_backgrounds/item_light/<md5>.png`，偏好为相对标识 | `data/after_pick.xml`：`theme_backgrounds/item_light/2556bfe22745e926e20a3caeeb941f23.png`；文件 1,777 B（`p2_05`） |
| 项目图 100% | 设置行卡、设置首页卡片显示图片 | 行卡红/绿 `(220,40,40)`/`(40,160,60)`；首页四象限可见（`s2_03`、`s2_04`） |
| 项目图 50%（滑杆读数 52） | 半透，与卡面 alpha 独立叠加 | 行卡红 `(231,137,137)`、绿 `(137,199,147)`；首页黑 X `(116,116,116)`、蓝 `(137,158,231)`（`s2_05`、`s2_06`） |
| 项目图 0% | 图片完全隐藏 | 首页卡面 `(242,242,242)`，无图像（`s2_07`） |
| 100% 水波纹 | 行可点击，水波纹在图片之上 | 录屏 `data/qa_ripple3.mp4` 帧差：行左区均值 137.6→150.2（峰值），>30 差分像素 53,514；点击同一行时开关由关变开，证明未被 `IgnorePointer` 拦截（`s2_13`/`s2_14`） |
| 与容器不透明度独立 | 项目图 100% 时不受 containerOpacity 影响 | containerOpacity=50 时行卡图像仍为 `(220,40,40)`/`(40,160,60)`（`s2_03`） |
| 日夜切换 | 深色用夜间图、浅色用日间图 | 深色：`(500,900)=(0,200,220)`、`(500,700)=(200,0,220)`；浅色恢复日间四象限（`s2_08`~`s2_10`） |
| 清除图片 | 偏好清空、行回「未设置」、卡片无图 | `s2_12`；`data` 中 `itemBackgroundImageLight` 被删除 |
| 缺文件回落 | 行副题「文件缺失，已回落」，卡片无图 | 删除落盘文件后冷启：副题 `2556…png（文件缺失，已回落）`，首页 `(242,242,242)`（`s2_11`） |
| 大容器图透明度 0/50/100 | 图片 0=隐藏、50=半透、100=原色 | 0：全 `(245,209,175)`（护眼底色，无图）；50：红 `(232,121,102)`、绿 `(142,172,109)`；100：原色（`s2_15`、`s2_16`、`s3_04`） |

- **P3-1**：本地备份只保存图片偏好路径，不包含 `theme_backgrounds/` 图片文件。
  若改图/清图时旧文件已被删除，恢复后偏好路径按「文件缺失」回落（本批实测：
  恢复后 UI 值已更新，但需把旧文件补回才显示图片）。与计划登记一致，
  建议在备份说明中明示「跨设备/删图后恢复，容器与项目图片需重新选择」。
- **结论**：PASS（P3-1 登记）。

### 3.3 场景 3：`.9` 九宫格（PASS，P3-3）

**夹具**：仓库真实 `nine_patch_0x.9.png`（单区域，12×12，npTc 84 B）、
`nine_patch_1J.9.png`（4+4 区域，54×54）、
`nine_patch_source_no_nptc.9.png`（仅黑边/无 npTc，12×12）；
另构造同像素 `qa_diag.9.png`（120×120，npTc 单区域 20/100）与
`qa_diag_src.9.png`（去掉 npTc）用于可视化对照；12MP/35MP/9k 构造图见场景 5。
全部经 SAF 或 root 落盘（`.9.png` 双扩展名保留）。

| 子项 | 预期 | 实际 / 证据 |
|---|---|---|
| 真实 `0x.9.png` 设为大容器图 | 解析成功、按图 alpha 渲染 | 分组区域 `(500,650)=(234,234,234)`；`0x40` 灰 (204) 以 25% 叠在 245 上 = 234.75（`s3_01`） |
| 真实 `0x.9.png` 设为项目图 | 每行 25% 灰叠加 | 行区 `(540,600)=(234,234,234)`，背景 245（`s3_10`） |
| 构造单区域 `.9`（大容器） | centerSlice 生效：角/边固定、中心拉伸、不模糊 | 20 源 px 角/边 = 60 物理 px；上下蓝边、左右绿边、中心品红，黑 X 被横向拉伸（`s3_02`） |
| 同像素无 npTc（大容器） | 回落 cover：整图等比缩放/裁剪 | 左右绿边、黄角显著放大，蓝色顶带变高，X 保持 45°（`s3_03`）——与 centerSlice 几何明显不同 |
| 普通 PNG（大容器） | cover | 四象限按宽度缩放、中心黑 X 可见，与 `.9` fill 不同（`s3_04`） |
| `1J.9` 多区域 | 回落 cover（centerSlice 无法表达 4×4） | 白斑按 cover 缩放并居中显示，未见错误切片（`s3_05`） |
| 仓库源码形态 `source_no_nptc.9.png` | 回落 cover | 12×12 全半透明灰，渲染为均匀 234；因图像均匀，cover/centerSlice 视觉不可区分（`s3_06`，P3-3） |
| 构造单区域 `.9`（项目图） | 每行 centerSlice | 行内黄角/蓝边/绿边/品红中心，X 横向拉伸（`s3_07`）；普通图对照为 cover（`s3_08`）；`1J` 项目图回落（`s3_09`） |
| 12MP `.9`（4000×3000） | 单区域 centerSlice，显示清晰 | 行/分组内绿-红-蓝分带边缘锐利，无模糊（`s3_11`、`s5_01`） |
| 35MP `.9`（7000×5000） | 超 32MP → 回落 cover，不 OOM | 分组/行均为纯紫 `(120,80,200)`，进程存活（`s3_12`、`s5_02`） |
| 单边 9000 `.9`（9000×100） | 超单边 8192 → 回落 cover | 纯青 `(30,180,180)`（`s3_13`） |

- **P3-3**：仓库 `source_no_nptc` 夹具为均匀半透明灰，回落与 centerSlice
  在该图上像素一致；本批用同像素 `qa_diag_src.9.png` 对照证明「无 npTc →
  cover」，并如实标注仓库夹具不可视觉区分，未伪造结论。
- **结论**：PASS（P3-3 登记）。

### 3.4 场景 4：组合外观与大字体（PASS，P3-2）

**配置**：大容器图 `qa_plain.png` + 项目图 `qa_plain.png`（均 100%）+
覆盖卡片边框 1dp + 覆盖卡片圆角 40 + 护眼模式（色温 50）+ 字体 1.3/1.6。

| 子项 | 实际 / 证据 |
|---|---|
| 设置首页 1.3 | 卡片图片覆盖、40dp 圆角、护眼暖色；入口行完整，无截断（`s4_01`） |
| 设置首页 1.6 | 副题换行（如「WebDav 设置/导入旧版本数据」两行），无溢出、可读（`s4_02`） |
| 外观页 1.6 | 顶部主题模式/调色板与底部长页均可达；`overflowed by`=0（`s4_03`、`s4_04`） |
| 护眼叠加 | 整页暖色矩阵生效（截图底色 245,209,175），文字仍可读 |
| 边框/圆角 | 40dp 圆角卡片可见；边框 1dp 随主题描边绘制，不改变布局 |

- 计数：1.3 与 1.6 阶段 `overflowed by`=**0**、`FATAL EXCEPTION`=**0**、
  `ANR in io.legado`=**0**（`data/s4_font13_counts.txt`、`s4_font16_counts.txt`）。
- **P3-2**：100% 项目图覆盖整行时，文字与图片内容的对比度取决于图片本身；
  本批使用的四象限高饱和图属极端样例，文字仍可辨识但观感一般。与参考版
  「图片层在卡面之上、内容之下」同口径，非缺陷；建议在帮助文案提示
  「项目图建议使用低对比度/留白图片」。
- **结论**：PASS（P3-2 登记）。

### 3.5 场景 5：内存与大图回落（PASS，O-2）

`dumpsys meminfo io.legado.flutter_legado` 与 `/proc/<pid>/status` 采样
（单位为 KB；每次冷启后进入「我的」页采样）：

| 状态 | TOTAL PSS | TOTAL RSS | VmHWM | 备注 |
|---|---|---|---|---|
| 小图基线（`qa_nine_src` 113 B） | 119,815 | 237,360 | — | 基线 |
| 大容器 12MP `.9`（4000×3000） | 119,991 | 237,564 | 231,972 | 渲染 12MP 切片，无 OOM |
| 大容器 35MP `.9`（7000×5000，超限） | 120,386 | 238,048 | 231,732 | 回落 cover |
| 大容器 12MP JPG | 122,337 | 240,076 | — | ResizeImage cover |
| 项目图 12MP `.9` | 117,314 | 235,208 | 227,736 | 多行重复绘制同一缓存 |
| 项目图 35MP `.9`（超限） | 119,160 | 236,092 | — | 回落 cover |

- 全程无 `OutOfMemory`、无进程重启、无 ANR；`pidof` 始终存在。
- **O-2**：本机 `dumpsys meminfo` 的 `Graphics=0`，Flutter/Impeller 的图片
  纹理与解码峰值未体现在 PSS/RSS 中，故上表只能证明「无 OOM 且进程内存稳定」，
  **不能**据此推算 12MP/35MP 的精确解码峰值；如需精确归因需 GPU/引擎侧计数。
- **结论**：PASS（O-2 采样口径限制已登记）。

### 3.6 场景 6：持久化、本地备份恢复与忽略主题（PASS，P3-1）

| 子项 | 实际 / 证据 |
|---|---|
| 本地备份 | 备份路径 `/sdcard/Download`；点击「备份」成功生成 `legado_backup_1793689650008.json`（11,066 B，`s6_01`）；JSON `appPrefs` 含 `containerOpacity=70`、`appColumnBackgroundOpacity=60`、`glassCardBackgroundOpacity=80`、`itemBackgroundImageLight/Dark`、`largeContainerBackgroundImageLight` |
| 改值 | 改为 `containerOpacity=20`、`appColumnBackgroundOpacity=10`、`glassCardBackgroundOpacity=30`，项目图/大容器图换为 `qa_night.png`，`eyeProtectionEnabled=true` |
| 忽略主题配置 | 「恢复忽略列表」勾选「主题配置」并保存：`restoreIgnore` 中 `themeConfig=true`（`s6_02`） |
| 本地恢复 | 长按「恢复」→ SAF 选 JSON → 「确认恢复吗？」→ 恢复成功（`s6_03`） |
| 恢复结果（偏好） | `containerOpacity=20`（主题配置过滤，保持本机值）；`appColumnBackgroundOpacity=60`、`glassCardBackgroundOpacity=80`、项目图/大容器图恢复为日间 `2556…`（新键不在 themePrefKeys，未被过滤）；`eyeProtectionEnabled=true` 保持（主题配置过滤） |
| 同会话生效 | 恢复后未重启：外观页显示 大容器图透明度 **60**、项目图透明度 **80**、容器不透明度 **20**（`s6_04`）；重新进入设置首页可见恢复后的日间四象限图（`s6_05`） |
| 重启保持 | 再次冷启后视觉与偏好不变（`s6_06`、`data/prefs_cleanup_fixed.xml` 的对应键未变）；本批多次冷启均保持四键 |
| 说明 | 恢复仅回填偏好路径，不包含图片文件；本批 S1 图片文件在 S2 改图时被删除，恢复后需把文件补回才显示（P3-1），与「文件缺失回落」登记一致 |

- **结论**：PASS（P3-1 登记）。

### 3.7 场景 7：回归与稳定性（PASS，O-1）

| 检查点 | 实测 / 证据 |
|---|---|
| 设置页/主题/容器背景/卡片样式 | 默认、100/50/0、深色、透明调色板、图片组合、1.3/1.6 全部走过；无布局异常 |
| 阅读 | 导入本地 `qa_book.txt` → 书架出现 `qa_book` → 打开阅读页显示正文；左滑翻页至「本章无正文」；返回书籍详情/书架正常（`s7_01`、`s7_02`） |
| 护眼 | 阅读页整页暖色矩阵生效，正文可读（`s7_01`） |
| 稳定性 | 最终 `logcat`（清理后窗口）：`overflowed by`=0、`FATAL EXCEPTION`=0、`ANR in io.legado`=0、`OutOfMemory`=0、`E/flutter`=0；crash buffer 中 `io.legado`=0（`data/s7_stability_counts.txt`） |
| MCP 提示 | 清理阶段误触 MCP 行仍弹既有「请先配置 Web 书源访问令牌」SnackBar，属 M2 已登记行为，本批未改动 |

- **O-1（环境观察）**：在把 `1J.9.png` 设为项目图后，第一次 `screencap`
  与 `dumpsys SurfaceFlinger` 同时超时（UI Automator dump 正常、logcat 无
  FATAL/ANR）。重启实例后同一配置可正常截图与渲染，未复现；判定为 MuMu
  SurfaceFlinger/编码器瞬时故障，非应用缺陷。重启后 `adb root` 失效，
  已重新 `adb root` 恢复取证。
- **结论**：PASS。

### 3.8 场景 8：清理（PASS）

| 步骤 | 结果 / 证据 |
|---|---|
| 清除图片 | `files/theme_backgrounds/` 整目录删除；`itemBackgroundImageLight/Dark`、`largeContainerBackgroundImageLight/Dark` 置空 |
| 恢复默认 | `enableContainerBackgroundImage=false`、`containerOpacity=100`、`appColumnBackgroundOpacity=100`、`glassCardBackgroundOpacity=100`、`overrideBaseCardBorder/CornerRadius=false`、`eyeProtectionEnabled=false`、`colorTemperature=50`、`app_theme_mode=system`、`restoreIgnore` 全 false、`app_backup_path` 置空；`font_scale=1.0` |
| 书架 | 删除 `qa_book`（选择模式→删除；含源文件），书架空态（`s7_02`、`s8_01`） |
| 设备文件 | `/sdcard/Download/qa_*`、`legado_backup_*.json`、`/sdcard/qa_ripple*.mp4`、临时 UI dump 全部删除；`Download` 匹配 `qa_/legado_backup` = **0** |
| 默认复核 | 「我的」行卡 240/背景 245（无图/无护眼）；外观页主题模式系统、容器开关关闭、不透明度 100（`s8_01`~`s8_03`） |
| 版本保留 | **2.0.441 / 442**（`s8_04`、`data/version_final.txt`） |

- **说明**：清理时一次 `sed` 替换把 `restoreIgnore` 的 `&` 当成 sed 反向引用，
  造成偏好行损坏；已用备份行修复并冷启验证（`data/prefs_cleanup_fixed.xml`），
  属 QA 操作失误，非应用问题。
- **结论**：PASS。

## 四、问题清单与分级

| 级别 | 编号 | 描述 | 复现步骤 / 证据 | 归属 |
|---|---|---|---|---|
| P1 | — | 无 | — | — |
| P2 | — | 无 | — | — |
| P3 | P3-1 | **备份/恢复不包含容器与项目图片文件**：恢复后偏好路径生效，但文件缺失时按「文件缺失，已回落」不显示图片；跨设备恢复需重新选图 | 备份→改图（旧文件删除）→恢复（`s6_05`）；补回 `theme_backgrounds/*` 后正常显示 | 与计划登记一致；建议帮助文案说明 |
| P3 | P3-2 | **100% 项目图降低文字对比度**：高饱和图片覆盖整行时文字仍可读但观感一般 | 组合场景 `s4_01`/`s4_02` | 图片层序与参考版同口径；建议提示使用低对比图 |
| P3 | P3-3 | **仓库 `source_no_nptc.9.png` 为均匀半透明灰**，fallback 与 centerSlice 像素不可区分 | `s3_06` vs `s3_02`；同像素 `qa_diag_src.9.png` 证明 cover（`s3_03`） | 夹具可读性限制，非缺陷 |
| P3 | P3-4 | 项目图透明度滑杆点击精度约 1%/3px，真实 UI 只能取到 51/52/53；精确 50 用偏好注入复核 | `s1_02`、`s2_05` | 交互精度，非功能缺陷 |
| 观察 | O-1 | MuMu SurfaceFlinger/screencap 瞬时挂起一次（设置 `1J` 项目图后），无 FATAL/ANR，重启实例后不复现 | logcat 14:37~14:42；重启后 `s3_09` 正常 | 环境问题 |
| 观察 | O-2 | `dumpsys meminfo` 的 `Graphics=0`，PSS/RSS 不含 GPU 纹理/解码峰值，内存结论仅能覆盖「无 OOM、进程稳定」 | `data/mem_*.txt` | 采样口径限制 |
| 观察 | O-3 | 「恢复忽略列表」同时提供「主题模式」与「主题配置」两项；本批按验收口径勾选「主题配置」 | `s6_02`；`data/confirm.xml` | 与参考版一致，仅提示 |

## 五、结论与建议

- **功能结论**：8/8 场景 PASS。全局 CardTheme 在 100/50/0 下按 alpha 正确
  叠加且不影响显式 color；项目图 100/50/0 在设置行卡/设置首页正确显示、
  半透、隐藏，100% 时行可点击且水波纹可见；真实与构造 `.9` 单区域按
  centerSlice 拉伸，`1J` 多区域与源码形态回落 cover；12MP/35MP/9k
  大图回落无 OOM；四键重启保持，本地恢复同会话生效，「忽略主题配置」
  未过滤 `appColumnBackgroundOpacity`/`glassCardBackgroundOpacity`/项目图键。
- **稳定性结论**：最终日志窗口 FATAL=0、ANR=0、overflow=0、OOM=0、
  E/flutter=0；crash buffer 无 `io.legado`。
- **门禁结论**：`flutter analyze` 0；定向 113/113；全量 4037 passed + 1 skipped；
  release 构建 EXIT=0；安装成功；版本 2.0.441+442。
- **建议**：
  1. **P3-1**：在备份/恢复帮助中说明「容器图/项目图为设备本地文件，不随
     备份携带；跨设备或删图后恢复需重新选择」；如需完整迁移，可评估把
     四槽位图片纳入备份包（需同步参考版口径）。
  2. **P3-2**：项目图管理页增加「建议使用低对比度图片」提示，或提供预览
     对比度提示。
  3. **P3-4**：如需精确 50%，可在滑杆上增加长按输入/步进按钮（参考版同
     为滑杆，建议随 M3 评估）。
  4. **O-1**：MuMu 实例在长时间多图渲染后出现过一次 SurfaceFlinger 挂起，
     建议后续设备任务继续观察；如复现，先区分实例/图形栈与 App。
- **证据路径**：
  - 报告：`docs/DEVICE_ACCEPTANCE_20261103_BATCH2B1B2B.md`
  - 截图（58 张）：`docs/materials_1107/`
  - 日志/数据/脚本：`tmp_debug/device_acceptance_20261103_batch2b1b2b/`
    - `logcat/analyze.log`、`targeted_tests.log`、`full_tests.log`、
      `build_release.log`、`install.log`
    - `data/apk_sha256.txt`、`apk_sha256_installed.txt`、`so_info.txt`、
      `version_installed.txt`、`version_final.txt`、`mem_*.txt`、
      `backup_s1.json`、`prefs_cleanup_fixed.xml`、`s4_font13_counts.txt`、
      `s4_font16_counts.txt`、`s7_stability_counts.txt`
    - `data/qa_ripple3.mp4`（水波纹录屏）
    - `scripts/qa.py`、`set_large.py`、`make_fixtures.py`（本批取证辅助）

编写：ZCode QA 子代理 ｜ 2026-11-03
