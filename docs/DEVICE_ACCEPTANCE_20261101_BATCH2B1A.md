# 批 2b-1a 设备验收报告（容器背景图 · 容器不透明度 · 背景图虚化）

> 范围：设置批 2b-1a「容器外观」——外观页「容器设置」分组的总开关/日间与夜间
> 大容器背景图/容器不透明度/日间与夜间背景图虚化；含选择、清除、重启保持、
> 文件缺失回落、透明调色板 P1 回归、备份恢复与忽略主题配置、性能与回归清理。
>
> 设备：MuMu「Test测试」实例（`192.168.100.62:5555`，实测 `device`）。
>
> **结论：不通过。** 8 组场景中 6 组 PASS、2 组 FAIL；P1=0、P2=2、P3=4。
> 两项 P2 为：① 容器背景图绘制在分组卡面之上，默认 100% 不透明度下图片从
> 4dp/2dp 缝隙漏出，呈「红色虚线边框」（场景 2 FAIL）；② 选择改名的非图片
> `.png` 时 `file_picker 8.3.7` 在压缩线程对 null Bitmap 调用 `compress`
> 触发应用 FATAL，未按预期拒绝并提示（场景 5 FAIL，场景 8 的 FATAL=0
> 硬指标同因此不成立）。透明调色板 P1 回归（100% 不应变纯白卡片）**通过**
> （深色空图条件下分组卡面实测 `(51,51,51)`，页面 `(0,0,0)`）。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM-G9900（MuMu 伪装）/ Android 15（SDK 35）/ **x86_64** |
| 分辨率 / 密度 | 1080×1920 / 480 dpi |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe`（MuMu 自带） |
| 应用包名 | `io.legado.flutter_legado` |
| 验收版本 | versionName **2.0.434** / versionCode **435**（`dumpsys package` 实测） |
| 源码基线 | `master` HEAD `eec7c6c651`（`chore: 批2b-1a 收尾（2.0.434+435 双日志与计划关闭登记）`）；工作区仅 `.zcode/` 未跟踪 |
| 验收时间 | 2026-11-01 11:36 ~ 12:32（设备时间） |
| 证据目录 | `tmp_debug/device_acceptance_20261101_batch2b1a/`（日志/数据/原始截图，不入库）；截图副本 `docs/materials_1101e/`（76 张） |
| 参考版 | `io.legato.kazusa` 3.26.19 / 18759（本轮未新增参考版截图，仅用代码/文档既有结论对照） |

### 1.1 构建产物（本批仅 Dart/UI，复用现有 `.so`）

| 步骤 | 结果 |
|---|---|
| Rust 构建 | **未执行**（批 2b-1a 无 Rust/FFI 变更）；复用 `jniLibs/` 现有 quickjs `.so` |
| x86_64 `.so` | `liblegado_ffi.so`：**51,883,696 B**，mtime **2026-10-31 23:45:24**，sha256 `7fea8be820550d7108a8f38c246140cba39e8f3ae9ed374e53fa0f2c4a41871e`（与 2a-1/9b-6c 验收一致，未重建） |
| `.so` meta | `{"contentHash":-993835076,"mode":"release","quickjs":true,"builtAt":"2026-10-31T23:45:24.5288717+08:00","rustFingerprint":"1ede733fbc7f7e25778d8cd48406b4db0d49626fc4a4602eb83ae86150f23616"}` —— **quickjs:true** |
| Flutter APK | `flutter build apk --release` **EXIT=0**，`assembleRelease 93.5s`，**199,971,976 B（190.7 MB）**；sha256 `f5e10531e6bcc1c748651d4006772f20b2d9fd2b4e4c92f3a3459254b3fd6d22`（`logcat/build_2b1a.log`） |
| 安装 | `adb install -r` **Success**（streamed 199,971,976 B）；`dumpsys` versionName=**2.0.434** / versionCode=**435** |
| 启动冒烟 | 安装后 `pm clear` + 冷启动 `am start -W` **434 ms**；后续冷启动 338/361/369/151/334/362 ms；空书架正常渲染（`71_clean_shelf.png`、`75_final_clean_launch.png`） |
| 清理后版本 | 两次 `pm clear` 后仍为 **2.0.434 / 435**（§3.8 复核） |

### 1.2 交付前门禁（QA 实测）

| 检查 | 命令 | 结果 |
|---|---|---|
| Dart 静态分析 | `flutter analyze`（`flutter_legado/`） | **No issues found!** EXIT=0（30.8s，`logcat/analyze.log`） |
| 容器定向测试 | `flutter test test/unit/theme_background_image_store_test.dart test/unit/theme_container_settings_test.dart test/unit/restore_ignore_prefs_test.dart test/unit/local_backup_service_test.dart test/widget/ios_group_container_test.dart test/widget/theme_container_settings_test.dart test/widget/theme_background_layer_test.dart` | **78/78 passed**，EXIT=0（`logcat/container_tests.log`） |
| 全量 Flutter 测试 | 未执行 | 本轮以设备验收为主；定向 78 项覆盖本批存储/渲染/设置/备份路径 |
| Release 构建 | `flutter build apk --release` | EXIT=0（见 §1.1） |
| Kotlin JVM 单测 | 未执行 | 本批无 Kotlin 变更 |

## 二、场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 总开关默认关+图片行隐藏；开启显示日/夜行；关闭后路径保留且不绘制 | **PASS** | `01_container_default.png`、`02_container_enabled.png`、`67_toggle_off_rows_hidden.png`、`69_toggle_off_dark_verified.png`、`70_toggle_on_path_retained.png` |
| 2 | 日/夜背景：浅色红图、深色蓝图；重启保持；清除日间回落 | **FAIL（P2-1）** | 映射/重启/清除子项 PASS：`10_light_opacity0.png`、`15_light_opacity50_pre.png`、`12_dark_opacity0_container.png`、`14_dark_opacity50.png`、`20_after_restart_container.png`、`21_day_cleared_light.png`、`22_night_only_dark.png`；**默认 100% 仅虚线边框**：`16_light_opacity100.png` |
| 3 | 不透明度 0/50/100；透明主题 100% P1 回归；文字可读 | **PASS（含 P2-1 观察）** | `10_light_opacity0.png`、`15_light_opacity50_pre.png`、`16_light_opacity100.png`、`73_transparent_dark_p1.png`、`74_transparent_dark_p1_container.png`、`65_shelf_light_regression.png`、`56_reader.png` |
| 4 | 虚化 0/50/100 视觉递增；文字/行卡不受影响；护眼叠加 | **PASS（含登记偏差）** | `24_blur_day0.png`、`25_blur_day50.png`、`26_blur_day100.png`、`29_eye_on_blur50_final.png`、`51_dark_op0_nightblur0.png`、`52_dark_op0_nightblur100.png` |
| 5 | 删除图片文件回落；非图片拒绝并提示；12MP 大图显示/RSS | **FAIL（P2-2）** | 缺失文件 PASS：`34_missing_day_file.png`；12MP PASS：`33_12mp_day_selected.png`；**伪图片选择崩溃**：`logcat/session_2b1a.log`、`logcat/crash_buffer.log`（两次 FATAL NPE） |
| 6 | 虚化三档滚动/设置页进出帧时间；12MP RSS | **PASS** | `logcat/sf_scroll_blur{0,50,100}_v3.txt`、`logcat/sf_enter_appearance_blur100.txt`、`logcat/sf_exit_appearance_clean.txt`、`data/samples_2b1a.json` |
| 7 | 本地备份→改容器设置→恢复同会话生效；忽略主题配置不覆盖 | **PASS** | `37_backup_done.png`、`38_backup_done2.png`、`42_after_restore.png`、`43_after_restore_appearance.png`、`46_ignore_theme_checked.png`、`47_ignore_restore_result.png`、`data/backup_before.json` |
| 8 | 回归（设置/阅读/护眼/主题切换）；FATAL/ANR/overflow/OOM；清理 | **FAIL（FATAL=2）+ 清理 PASS** | `56_reader.png`、`58_reader_menu.png`、`59_reader_toc.png`、`64_light_appearance.png`、`65_shelf_light_regression.png`、`71_clean_shelf.png`、`72_clean_appearance_container.png`、`75_final_clean_launch.png`；FATAL 见 §四 |

## 三、逐场景证据

### 3.1 场景 1：总开关默认/显隐/路径保留

- **步骤**：`pm clear` 后进入 设置 → 外观 → 滚动到「容器设置」；记录默认态；
  点「容器背景图」开关；再关闭；在已选夜间图的情况下强制停止并冷启动后复核。
- **预期**：默认开关关、日/夜图片行隐藏；开启后出现两行；关闭后路径保留但
  设置页不再绘制图片。
- **实际**：符合。

| 检查点 | 实测 |
|---|---|
| 默认态 | `01_container_default.png`：仅「容器背景图」开关（关）、「容器不透明度 100」、「背景图虚化（日间/夜间）0」、「卡片圆角」「显示分隔线」；无「容器背景图片（日间/夜间）」行 |
| 开启后 | `02_container_enabled.png`：出现「容器背景图片（日间）/未设置」「容器背景图片（夜间）/未设置」 |
| 选图自动置开 | 选图后 prefs `enableContainerBackgroundImage=true`（§3.2） |
| 关闭保留路径 | 夜间图已设置时关闭开关：UI 两图片行隐藏（`67_toggle_off_rows_hidden.png`）；prefs 仍为 `largeContainerBackgroundImageDark=theme_backgrounds/large_dark/c23068520115d5e09dd72592ccacced2.jpg`；深色主题分组卡面无蓝图（`69_toggle_off_dark_verified.png`） |
| 再次开启 | 两行恢复且夜间路径仍为原文件名（`70_toggle_on_path_retained.png`），`enableContainerBackgroundImage=true` |

- **结论**：PASS。截图：`01_container_default.png`、`02_container_enabled.png`、
  `67_toggle_off_rows_hidden.png`、`69_toggle_off_dark_verified.png`、
  `70_toggle_on_path_retained.png`。

### 3.2 场景 2：日/夜背景、重启保持、清除回落（含 P2-1）

- **步骤**：总开关开；日间选 `qa_day_red_3000x2000.png`（红白棋盘+“DAY RED”），
  夜间选 `qa_night_blue_3000x2000.jpg`（蓝白棋盘+“NIGHT BLUE”）；分别在
  浅色/深色主题与不透明度 0/50 下截图；`am force-stop` 冷启动复核；
  清除日间图后复核浅色回落与夜间保留。
- **预期**：浅色显示红图、深色显示蓝图；重启保持；清除日间后回落主题底色、
  夜间仍在。

| 子项 | 实测 | 证据 |
|---|---|---|
| 浅色 + 日间红图 | 不透明度 0 全图红白棋盘；50 时分组卡面呈红色调 | `10_light_opacity0.png`、`15_light_opacity50_pre.png` |
| 深色 + 夜间蓝图 | 不透明度 0 全图蓝白棋盘；50 时蓝灰色调 | `12_dark_opacity0_container.png`、`14_dark_opacity50.png` |
| 重启保持 | 冷启动 377ms；开关开、日/夜文件名、不透明度 100 均保留 | `20_after_restart_container.png`；prefs 两键原值 |
| 清除日间 | prefs `largeContainerBackgroundImageLight` 键被删除；浅色分组卡面为主题底色（无红图）；夜间键保留 | `21_day_cleared_light.png` |
| 夜间仍在 | 深色分组卡面仍出现蓝图（不透明度 100 时为蓝色虚线边框） | `22_night_only_dark.png` |
| **默认 100% 显示** | **FAIL**：不透明度 100 时图片不作为背景显示，只在每组 4dp 内边距与行间 2dp 缝隙露出原图，呈红色虚线边框；截图内检测到 **113 个高饱和红像素**（如 `(204,39,41)`），卡面内部为 `(240,240,240)` | `16_light_opacity100.png` |
| 50% 均匀性 | 50 时缝隙仍为**全强度**原图（边缘 `(231,166,165)`），卡面内部为 50% 混合（`(243,229,229)`），未按同一 alpha 衰减 | `15_light_opacity50_pre.png` |

- **失败说明（P2-1）**：`IosGroup` 把背景图放在 `Container` 底色之上的 `Stack`
  子层（`ios_widgets.dart:192-232`：195-198 分组底色、205-218 图片、221 行卡），
  图片不受 `containerOpacity` 调制，且 100% 时卡面无法遮挡 4dp/2dp 缝隙。
  预期：100% 时图片完全不可见；<100% 时整张卡面（含内边距）按同一 alpha 混合。
  实际：缝隙处始终为原图强度，100% 时形成虚线边框，50% 时边框比内部更亮。
- **结论**：日/夜映射、重启保持、清除回落 **PASS**；默认 100% 视觉 **FAIL
  （P2-1）**。截图：`10_light_opacity0.png`、`15_light_opacity50_pre.png`、
  `16_light_opacity100.png`、`12_dark_opacity0_container.png`、
  `14_dark_opacity50.png`、`20_after_restart_container.png`、
  `21_day_cleared_light.png`、`22_night_only_dark.png`。

### 3.3 场景 3：不透明度 0/50/100 与透明主题 P1 回归

- **步骤**：浅色主题、日间红图已选；不透明度滑杆依次置 0/50/100，
  截取同一「容器设置」区域；再将调色板切「透明」、主题深色、无容器图，
  复核 100% 卡片颜色；最后查看书架/阅读页是否受容器设置影响。
- **预期**：0/50/100 视觉递进；透明主题 100% 不应被洗成纯白卡片；
  文字在 50/100 可读；书架/阅读页不适用（容器仅设置分组卡面）。

| 档位 | 实测 | 证据 |
|---|---|---|
| 0 | 图片全强度可见；采样 `(216,76,75)` / `(232,182,174)`；文字直接叠在棋盘上 | `10_light_opacity0.png` |
| 50 | 图片与卡面混合；采样 `(229,169,167)`；文字可读 | `15_light_opacity50_pre.png` |
| 100 | 卡面 `(240,240,240)` 基本不透明；但边缘仍漏出原图红虚线（P2-1） | `16_light_opacity100.png` |
| 透明主题 100%（深色、无图） | 分组卡面 **`(51,51,51)`**、页面 **`(0,0,0)`**，为 20% 白叠黑，**不是纯白**；P1 回归通过 | `73_transparent_dark_p1.png`、`74_transparent_dark_p1_container.png` |
| 书架 | 仅有全局壁纸，无容器图/不透明度效果（登记：容器仅设置分组卡面） | `65_shelf_light_regression.png` |
| 阅读页 | 阅读背景独立，无容器图/不透明度影响 | `56_reader.png` |

- **文字可读性**：50/100 下标题与说明文字对比正常；0% 时文字直接叠在
  `DAY RED` 高对比棋盘上，局部可读性下降（图片内容决定，P3-1）。
- **结论**：PASS（透明主题 P1 回归通过）；P2-1 的层序问题在 100% 档同时暴露。
  截图：`10_light_opacity0.png`、`15_light_opacity50_pre.png`、
  `16_light_opacity100.png`、`73_transparent_dark_p1.png`、
  `74_transparent_dark_p1_container.png`。

### 3.4 场景 4：虚化 0/50/100、文字/行卡、护眼叠加

- **步骤**：在「自定义主题·白天 → 背景图片」设置全局壁纸
  （`qa_day_red_3000x2000.png`）；回到「容器设置」，背景图虚化（日间）
  依次 0/50/100，截取外观页；再开护眼模式、虚化 50 截图；
  另在深色主题、不透明度 0 下对容器夜间图比较夜间虚化 0/100。
- **预期**：0/50/100 虚化视觉递增；文字/行卡不受虚化；护眼叠加正常。

| 检查点 | 实测 | 证据 |
|---|---|---|
| 虚化 0 | 壁纸边缘棋盘清晰；边缘亮度标准差 **57.0** | `24_blur_day0.png` |
| 虚化 50 | 边缘明显变糊；标准差 **13.1** | `25_blur_day50.png` |
| 虚化 100 | 边缘近似均匀粉色；标准差 **12.1** | `26_blur_day100.png` |
| 文字/行卡 | 三档下标题、说明、滑杆均保持清晰，未随壁纸虚化 | `24`/`25`/`26` |
| 护眼开 + 虚化 50 | 全局暖色叠加 + 壁纸虚化，文字可读 | `29_eye_on_blur50_final.png` |
| 容器图是否被虚化 | 夜间虚化 0→100：容器图区域左条带 **平均绝对差 0.0**，亮度标准差均 **85.1**，完全无变化 | `51_dark_op0_nightblur0.png`、`52_dark_op0_nightblur100.png` |

- **登记偏差**：虚化行文案与实现均明确「仅作用于已设置的全局背景图」，
  容器背景图不参与虚化（像素差 0.0）。这与任务描述中「背景图虚化」
  可能被理解为容器图的直觉不同；按实现语义 PASS，作为已登记边界记录（P3-2）。
- **结论**：PASS（全局壁纸虚化递增、文字/行卡不受影响、护眼叠加正常）。
  截图：`24_blur_day0.png`、`25_blur_day50.png`、`26_blur_day100.png`、
  `29_eye_on_blur50_final.png`、`51_dark_op0_nightblur0.png`、
  `52_dark_op0_nightblur100.png`。

### 3.5 场景 5：健壮性（缺失文件 / 伪图片 / 12MP）

#### 5a 删除背景图文件

- 步骤：选中 12MP 日间图后，删除应用目录中的
  `files/theme_backgrounds/large_light/3837b766f5d96507c14eb4a11d699e0b.jpg`，
  `am force-stop` 冷启动，再进外观页。
- 预期：副标题提示「文件缺失，已回落」，不崩溃，按无图回落。
- 实际：`34_missing_day_file.png` 显示
  `3837b766f5d96507c14eb4a11d699e0b.jpg（文件缺失，已回落）`；分组卡面回落为
  全局壁纸/主题底色；应用无 FATAL，冷启动 369 ms。**PASS**。

#### 5b 非图片文件（`.txt` 改名 `.png`）

- 步骤：将文本文件改名为 `qa_fake_image.png`，`MEDIA_SCANNER_SCAN_FILE`
  入 MediaStore（`mime_type=image/png`，5,200 B），在「容器背景图片（日间）」
  → 选择图片 → Download 中选择该项。
- 预期：拒绝并提示（如「图片内容为空/无法解码」），保留原设置，不崩溃。
- 实际：**FAIL**。系统照片选择器返回后应用进程直接死亡（回到桌面），
  两次复现均为 `FATAL EXCEPTION`：
  - 11:54:26.718 PID 36368 / `Thread-7`
  - 11:56:19.115 PID 37980 / `Thread-5`
  - 异常：`java.lang.NullPointerException: Attempt to invoke virtual method
    'boolean android.graphics.Bitmap.compress(...)' on a null object reference`
  - 栈：`at t3.u0.a(SourceFile:56)` ← `P.e.run(SourceFile:389)` ←
    `java.lang.Thread.run`
- 定位：`file_picker 8.3.7` `FileUtils.compressImage()`（pub cache
  `.../file_picker-8.3.7/android/.../FileUtils.java:102`）对
  `BitmapFactory.decodeStream()` 返回的 null 直接调用 `compress`；
  调用点 `flutter_legado/lib/src/screens/theme_config_screen.dart:1872-1875`
  未传 `allowCompression`，默认 `true`/`quality=30`
  （`file_picker.dart:98-99`）。应用侧 `ThemeBackgroundImageStore._validateDecodable`
  与 `FormatException` 提示在此之后才执行，无法兜底。
- 建议：选择图片时显式 `allowCompression: false`（由应用自行校验/存储），
  或升级 file_picker（11.0.2 已无该 `compressImage` 路径），或在插件返回前
  预校验源文件可解码。**问题性质：代码/插件缺陷，非环境问题**。
- 截图：`31_fake_image_rejected.png`（实际为崩溃后桌面）；日志
  `logcat/session_2b1a.log`、`logcat/crash_buffer.log`。

#### 5c 12MP 大图

- 步骤：选择 `qa_big_12mp_4000x3000.jpg`（4000×3000，973,379 B）作为日间容器图；
  记录 `dumpsys meminfo`。
- 预期：显示正常、不 OOM、记录 RSS。
- 实际：`33_12mp_day_selected.png` 显示绿色棋盘图，文件名哈希
  `3837b766f5d96507c14eb4a11d699e0b.jpg`（插件压缩后落盘 294,769 B）；
  无 OOM/崩溃。RSS：选择前 **246,416 KB** → 选择后 **301,824 KB**
  （+55.4 MB）；Native Heap 24,132 → 74,060 KB；PSS 113,520 → 167,578 KB。
  应用随后仍可正常滚动/切页。**PASS**。

- **结论**：5a PASS；**5b FAIL（P2-2）**；5c PASS。

### 3.6 场景 6：性能（帧时间、RSS）

- **方法**：Flutter 使用 SurfaceView，`dumpsys gfxinfo` 不覆盖其渲染；
  采用 `dumpsys SurfaceFlinger --latency <RequestedLayerState>` 的 128 帧
  呈现时间戳计算相邻帧间隔；每档先经滑杆设定并读取 prefs 校验实际值，
  再做 8 次上下滑动；另采集进入/退出外观页的过渡帧。

| 项 | 帧数/间隔 | p50 | p95 | 最大 | >17ms | >33ms |
|---|---|---|---|---|---|---|
| 外观页滚动 · 虚化 0 | 127 / 126 | 16.7 ms | 16.7 ms | 16.7 ms | 0 | 0 |
| 外观页滚动 · 虚化 50 | 127 / 126 | 16.7 ms | 16.7 ms | 33.3 ms | 1 | 1 |
| 外观页滚动 · 虚化 100 | 127 / 126 | 16.7 ms | 16.7 ms | 16.7 ms | 0 | 0 |
| 进入外观页 · 虚化 100 | 127 / 124 | 16.7 ms | 16.7 ms | 50.0 ms | 1 | 1 |
| 退出外观页 · 清理后 | 127 / 124 | 16.7 ms | 16.7 ms | 50.0 ms | 1 | 1 |

- **主观**：三档虚化下外观页连续滚动无肉眼卡顿/冻结；设置页进出正常；
  12MP 图显示后滚动依旧顺滑。
- **RSS 对比**：无日间图（夜间图+全局壁纸）246,416 KB → 12MP 日间图
  301,824 KB（+55.4 MB）；`pm clear` 后空状态 257,636 KB。
- **结论**：PASS。P3-2：虚化 50 滚动 1/126 帧 33.3ms、进出各 1/124 帧
  50ms，属单帧抖动，无可感知卡顿。

### 3.7 场景 7：本地备份 → 修改 → 同会话恢复；忽略主题配置

- **步骤**：备份路径设为 `/storage/emulated/0/Download/legado_qa_backup`
  （SAF 新建子目录并允许访问）→ 点「备份」；将容器不透明度 50→100、
  日间虚化 0→50；长按「恢复」选择本地 JSON → 确认；不重启复核 UI/prefs。
  再设不透明度 86、日间虚化 72；恢复忽略列表勾选「主题配置」→ 确定；
  再次恢复同一 JSON，复核是否被覆盖。
- **预期**：备份包含容器键；恢复到备份值且同会话生效；忽略主题配置时
  主题类键不被覆盖。

| 阶段 | containerOpacity | backgroundImageBlurring | 夜间图路径 |
|---|---|---|---|
| 备份时（JSON 内） | 50 | 0 | `theme_backgrounds/large_dark/c23068520115d5e09dd72592ccacced2.jpg` |
| 修改后 | 100 | 50 | 未变 |
| 恢复后（同一会话） | **50** | **0** | 保留 |
| 忽略恢复前 | 86 | 72 | 保留 |
| 忽略「主题配置」恢复后 | **86** | **72** | 保留 |

- 备份文件：`/sdcard/Download/legado_qa_backup/legado_backup_1793505954016.json`
  **989 B**；`appPrefs` 内含 `containerOpacity=50`、
  `enableContainerBackgroundImage=true`、
  `largeContainerBackgroundImageDark=theme_backgrounds/...`、
  `backgroundImageBlurring=0`（另含主题/护眼等既有键）。
- 同会话生效：恢复后未重启，外观页读数即为 50/0，夜间文件名恢复
  （`43_after_restore_appearance.png`）。
- 忽略主题配置：勾选状态见 `46_ignore_theme_checked.png`；恢复后
  `containerOpacity=86`、`backgroundImageBlurring=72` 未被备份值覆盖
  （`47_ignore_restore_result.png`）。
- **登记**：`largeContainerBackgroundImageLight/Dark` 不在
  `themePrefKeys` 内（`pref_keys.dart:78-80`），"忽略主题配置"不会跳过
  图片路径；本次备份与当前路径相同，未构造差异值，故该点在设备上
  **未单独证明**，按代码语义登记。
- **结论**：PASS。

### 3.8 场景 8：回归、FATAL 统计与清理

#### 8a 回归

- 主题切换：浅色/深色多次切换，外观页立即重绘（`53`、`64`、`69`），无异常。
- 阅读：导入 `qa2b1a.txt` 后打开章节 1，正文/章节名/进度正常
  （`56_reader.png`）；点右侧翻页到 2/5（40%）；菜单、目录、书签/标注 Tab
  正常（`58_reader_menu.png`、`59_reader_toc.png`）；返回书架正常
  （`65_shelf_light_regression.png`）。
  - 说明：测试 TXT 的正文行以「第二章正文」「第三章正文」开头，被默认
    TXT 目录规则识别为章节标题，导致出现「本章无正文」空章（`58` 中
    2/5 页）；属夹具文本与默认规则组合现象，不是本批代码回归，未计入缺陷。
- 护眼：外观页开关开/关、强度/虚化 50 叠加正常（`29`）；关闭后恢复正常。
- 设置页/弹层/滚动：无 `RenderFlex overflowed`（§四）。
- 容器设置作用域：书架、阅读页均不出现容器图/不透明度效果
  （`65_shelf_light_regression.png`、`56_reader.png`）。

#### 8b FATAL / ANR 汇总

统计口径：`adb logcat -b all -d -v time`（会话窗口内缓冲 49,987 行 /
5.9 MB；含 09:37 上一批遗留的 `UiAutomation` 崩溃）+ `logcat -b crash -d`。

| 项 | 计数 |
|---|---|
| 应用 `FATAL EXCEPTION`（`Process: io.legado.flutter_legado`） | **2**（11:54:26 PID 36368、11:56:19 PID 37980，均为伪图片 `Bitmap.compress` NPE） |
| `ANR in io.legado` / `ANR in` | **0** |
| `RenderFlex overflowed` | **0** |
| `OutOfMemoryError` | **0** |
| 应用 native tombstone（`Cmdline: io.legado.flutter_legado`） | **0** |
| QA 工具 `FATAL EXCEPTION: UiAutomation` | 1（09:37:31，PID 29369，上一批遗留） |
| QA 工具 uiautomator native tombstone | 557（会话内工具退出 SIGSEGV，非应用） |

- **结论**：回归功能 PASS，但「FATAL=0」硬指标 **FAIL**（原因同 P2-2）。

#### 8c 清理

| 项 | 结果 |
|---|---|
| 应用数据 | `pm clear io.legado.flutter_legado` **Success**（清理前/后各一次；后者用于删除透明主题测试状态） |
| 书架 | **空**（`71_clean_shelf.png`、`75_final_clean_launch.png`：「书架还空着…」） |
| 容器默认 | 开关关、日/夜图片行隐藏、不透明度 100、虚化 0/0；prefs 无 `containerOpacity`/`largeContainerBackgroundImage*`/`backgroundImageBlurring` 等键（`72_clean_appearance_container.png`） |
| 主题/护眼 | `pm clear` 后为默认（浅色跟随系统、护眼关、调色板默认） |
| 设备文件 | `/sdcard/Download/qa_*.{png,jpg}`、`qa2b1a.txt`、`/sdcard/Download/legado_qa_backup/` 已删除（备份目录需先 `force-stop documentsui` 解锁后 rmdir） |
| 系统设置 | `auto_time=1`、`accelerometer_rotation=1`、`user_rotation=0`、`Night mode: no`（测试中未改时钟） |
| 版本 | 保留 **2.0.434 / 435**（`dumpsys package` 复核） |

## 四、问题清单与分级

### P2-1 容器背景图绘制层序错误：100% 时漏出「虚线边框」，不透明度非均匀

- **复现**：外观 → 容器设置 → 开总开关 → 选任意高对比图片（如
  `qa_day_red_3000x2000.png`）→ 不透明度保持默认 100 → 观察设置分组卡面。
- **期望**：100% 时卡面完全不透明、图片不可见；50% 时整张卡面（含 4dp
  内边距与 2dp 行距）按同一 alpha 与图片混合。
- **实际**：图片层位于分组底色之上；100% 时仅在 4dp/2dp 缝隙露出原图，
  呈红色虚线边框（`16_light_opacity100.png`，113 个高饱和红像素）；
  50% 时缝隙为全强度原图、卡面内部为半透明混合（`15_light_opacity50_pre.png`），
  视觉不均匀。
- **代码定位**：`flutter_legado/lib/src/widgets/ios_widgets.dart:192-232`
  （`Container` 底色 195-198 → `Stack` 内图片 205-218 → 行卡 221-232）。
  图片应绘制在卡面底色之下，或对图片层同样应用 `containerOpacity`，
  并让内边距被卡面完整覆盖。
- **影响**：只要用户设置容器背景图且保持默认 100%，每个设置分组都会出现
  与图片内容相关的彩色虚线边框；场景 2「设置页显示红图/蓝图」在默认档位
  不成立。
- **分级**：P2（视觉缺陷，不崩溃；用户可降不透明度规避，但默认档位即触发）。

### P2-2 选择改名非图片（`.png`）导致应用 FATAL 崩溃

- **复现**：外观 → 容器设置 → 容器背景图片（日间）→ 选择图片 →
  在 Download 选择 `qa_fake_image.png`（文本改扩展名，5,200 B，
  MediaStore `mime_type=image/png`）。
- **期望**：拒绝并提示（如「图片内容为空/无法解码」），保留原设置。
- **实际**：系统照片选择器返回后应用进程死亡；两次复现
  （11:54:26 PID 36368、11:56:19 PID 37980）均为
  `NullPointerException` at `Bitmap.compress(...)`（null Bitmap），
  栈 `t3.u0.a` ← `P.e.run` ← `Thread.run`。
- **根因**：`file_picker 8.3.7` `FileUtils.compressImage()` 未判空
  （`FileUtils.java:102`）；应用调用
  `flutter_legado/lib/src/screens/theme_config_screen.dart:1872-1875`
  未关闭压缩；插件默认 `allowCompression=true`、`quality=30`。
  应用自身的解码校验/`FormatException` 提示在插件崩溃之后，无法执行。
- **修复方向**：选择容器图时传 `allowCompression: false`（由
  `ThemeBackgroundImageStore` 自行校验/落盘），或升级 file_picker
  （11.0.2 已无该 compressImage 路径），或选图后先校验源文件可解码。
- **影响**：用户误选损坏/伪装图片即崩溃；场景 5 明确要求的「拒绝并提示」
  未实现。
- **分级**：P2（崩溃，无数据丢失；可稳定复现）。

### P3-1 不透明度 0% 时文字可读性取决于图片内容

- 0% 时行卡面完全透明，标题/说明直接叠在图片上；高对比棋盘图下
  局部文字可读性下降（`10_light_opacity0.png`）。50%/100% 正常。
- 属 0% 极端档位的固有权衡；建议后续对 0% 增加文字保护或下限提示。
- 分级：P3。

### P3-2 虚化 50 滚动 1/126 帧 33ms、进出各 1/124 帧 50ms

- 三档滚动 p50/p95 均 16.7ms；仅虚化 50 出现 1 帧 33.3ms，进入/退出
  各 1 帧 50ms；无肉眼卡顿/冻结。分级：P3。

### P3-3 uiautomator 工具 tombstone

- 会话内 557 条 `Cmdline: uiautomator` native tombstone（工具退出 SIGSEGV），
  应用 native tombstone=0。与上一批一致，非应用问题。分级：P3。

### P3-4 虚化语义仅全局壁纸（登记偏差）

- 虚化 0/100 对容器图区域像素差 **0.0**（`51`/`52`）；文案明确
  「仅作用于已设置的全局背景图」。若产品期望「容器背景图也可虚化」，
  需在 2b-1b 扩展；本批按实现语义验收。分级：P3/登记。

### 参考预期说明：`containerOpacity` 仅作用于 IosGroup

- 实测书架（`65_shelf_light_regression.png`）与阅读页（`56_reader.png`）
  均不受容器图/不透明度影响，只有 `IosGroup` 分组卡面参与。
- 参考版为全局 `GlassCard`（`GlassCard.kt:74-75` alpha 相乘），本批按
  工程计划登记为 **2b-1b 扩展**，因此**不等同参考版的全局范围**；
  本批验收按登记范围判定，不把「未全局覆盖」计为本批回归。
- 另：`IosGroup(flat: true)` 无卡片面，不参与容器背景/不透明度
  （`ios_widgets.dart:143-150` 注释），备份/恢复等扁平列表页不显示容器图，
  属已登记边界。

## 五、证据清单

| 类别 | 文件 |
|---|---|
| 构建 | `tmp_debug/device_acceptance_20261101_batch2b1a/logcat/build_2b1a.log` |
| 门禁 | `logcat/analyze.log`、`logcat/container_tests.log` |
| 崩溃 | `logcat/session_2b1a.log`（49,987 行）、`logcat/crash_buffer.log` |
| 帧数据 | `logcat/sf_scroll_blur0_v3.txt`、`sf_scroll_blur50_v3.txt`、`sf_scroll_blur100_v3.txt`、`sf_enter_appearance_blur100.txt`、`sf_exit_appearance_clean.txt` |
| 采样/汇总 | `data/samples_2b1a.json`、`data/backup_before.json`、`data/prefs_after_scene3.xml`、`data/sf_layer.txt` |
| 截图 | `docs/materials_1101e/`（76 张，s1~s8 对应文件见 §二/§三） |

## 六、未证明 / 不可证明项

- 「忽略主题配置」对 `largeContainerBackgroundImageLight/Dark` 的覆盖行为：
  备份与当前路径相同，未构造差异值；仅按 `pref_keys.dart:78-80` 不在
  `themePrefKeys` 的代码语义登记。
- 容器背景图自身的虚化：实现明确不支持；已证明 0/100 像素差 0.0，
  未按「应支持」验收。
- 全量 Flutter 测试未跑；仅定向 78 项 + `flutter analyze`。
- 帧数据来自 SurfaceFlinger 128 帧窗口，非完整 trace；未覆盖长时间
  连续滚动与低端真机。
- 参考版仅沿用既有代码/文档结论，本轮未重新安装 kazusa 做逐像素对照。

## 七、结论

- 场景 1（默认关/行隐藏/关闭保留路径）：**PASS**。
- 场景 2（日/夜映射、重启保持、清除回落）：子项 PASS；**默认 100% 视觉 FAIL（P2-1）**。
- 场景 3（0/50/100、透明主题 P1、文字可读）：**PASS**（P1 回归通过，P2-1 同时在 100% 暴露）。
- 场景 4（虚化递增、文字/行卡、护眼叠加）：**PASS**（含「仅全局壁纸」登记）。
- 场景 5（缺失文件/伪图片/12MP）：缺失文件与 12MP **PASS**；**伪图片 FAIL（P2-2 崩溃）**。
- 场景 6（帧时间/RSS）：**PASS**（60fps，12MP +55.4MB，无 OOM）。
- 场景 7（备份/恢复/忽略主题配置）：**PASS**。
- 场景 8（回归/崩溃统计/清理）：功能回归与清理 PASS；**FATAL=0 指标 FAIL（2 次应用 FATAL，均由 P2-2）**。

**问题分级**：P1=0；P2=2（§四 P2-1 层序虚线边框、P2-2 伪图片崩溃）；
P3=4（0% 文字可读性、单帧抖动、uiautomator tombstone、虚化仅全局壁纸）
+ 参考范围登记（containerOpacity 仅 IosGroup，2b-1b 扩展）。

**总判定：不通过（需修复 P2-1/P2-2 后复验场景 2、5、8）。**
其余场景与透明主题 P1 回归可作为通过证据保留。

编写者：QA（ZCode 子代理）｜ 2026-11-01

## 八、回修复验（2026-11-01 12:41 ~ 13:12，HEAD `6ab181516e`）

> 复验对象：提交 `6ab181516e fix(ui): 批2b-1a 容器图层序与选图崩溃修复`
> （P2-1 层序/不透明度、P2-2 伪图片崩溃）。版本未变，仍为
> **2.0.434+435**；设备仍为 MuMu「Test测试」`192.168.100.62:5555`。
>
> **复验结论：通过。** 两处 P2 均已关闭；FATAL/ANR 均为 0。
> 修复前 `16_light_opacity100.png` 的红色虚线边框、`15_light_opacity50_pre.png`
> 的全强度缝隙、以及两次伪图片 `Bitmap.compress` NPE 均未复现。

### 8.1 复验环境与产物

| 项 | 值 |
|---|---|
| 源码基线 | HEAD `6ab181516e`（`fix(ui): 批2b-1a 容器图层序与选图崩溃修复`），工作区仅 `.zcode/`、本报告与证据目录未跟踪 |
| 版本 | versionName **2.0.434** / versionCode **435**（安装后与清理后 `dumpsys package` 各复核一次） |
| 设备 | SM-G9900（MuMu 伪装）/ Android 15 / x86_64；1080×1920 / 480 dpi |
| adb | `D:\Program Files\MuMuPlayer\nx_main\adb.exe` |
| 静态分析 | `flutter analyze` → **No issues found!**（10.2s，EXIT=0） |
| 定向测试 | 容器 7 个测试文件 → **82/82 passed**（含新增「100% 图层序/50% 同 rect」「allowCompression=false」断言） |
| 全量测试 | `flutter test` → **3775 passed / 1 skipped**，EXIT=0（1:42） |
| Release 构建 | `flutter build apk --release` **EXIT=0**，`assembleRelease 5.9s`，**199,971,976 B（190.7 MB）** |
| APK sha256 | `6ca78ed3d065ecaae32ac5bb6c46b9d72d9c0b4d278fd6ff53edc612fa491612`（与修复提交正文一致） |
| 安装 | `adb install -r` **Success: streamed 199971976 bytes** |
| 冷启动 | force-stop 重启 **379 ms**；`pm clear` 后冷启动 **360 ms** |
| x86_64 `.so` | `liblegado_ffi.so` 51,883,696 B / sha256 `7fea8be8…a41871e` / mtime 2026-10-31 23:45（未重建） |
| 证据目录 | 截图 `docs/materials_1101e/reverify/rev_01~rev_34`；日志/数据 `tmp_debug/device_acceptance_20261101_reverify/` |

### 8.2 修复实现复核（仅阅读，未改代码）

- **P2-1 层序**：`flutter_legado/lib/src/widgets/ios_widgets.dart:195-251`
  改为 `ClipRRect(16dp) > Stack[背景图 Positioned.fill, 分组底色 Container]`。
  背景图从「底色之上」移到「底色之下」；4dp 分组内边距与 2dp 行间距同属
  该底色 Container，`color = groupSurface.withValues(alpha: groupSurface.a * opacity)`。
  → 100% 时底色整卡覆盖图片；<100% 时整卡按同一 alpha 混合，行小卡再叠加
  自身 `surfaceContainerLow * opacity`。
- **P2-2 选图崩溃**：`flutter_legado/lib/src/screens/theme_config_screen.dart:1872-1885`
  显式 `allowCompression: false`、`withData: false`，绕开 `file_picker 8.3.7`
  对 null Bitmap 调用 `compress` 的 Android 原生链路；格式/完整性统一由
  `ThemeBackgroundImageStore.store` 的 `ImageDescriptor.encoded` 校验，
  失败抛 `FormatException` 并由页面 toast。

### 8.3 逐项复验结果

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 默认 100%：分组卡内无图片缝隙/彩色虚线边框 | **PASS** | `rev_04_light_100_dayred.png`、`rev_07_light_100_default_theme_dayred.png` |
| 2 | 50%：整卡均匀透出图片，缝隙无全强度原图线 | **PASS** | `rev_05_light_50_dayred.png` |
| 3 | 0%：图片完整可见、文字可读性（P3-1 观察） | **PASS（含 P3-1）** | `rev_06_light_0_dayred.png` |
| 4 | 透明主题 100%/50% 不洗白 | **PASS** | `rev_08`~`rev_11` |
| 5 | 伪图片 `.png`：不崩溃、回设置页、toast | **PASS** | `rev_12`~`rev_14`、`logcat/session_reverify.log` |
| 6 | 正常 PNG/JPG 可选并显示 | **PASS** | `rev_04`（PNG 日间）、`rev_18`（JPG 夜间） |
| 7 | 12MP 大图设置/显示、RSS、无 OOM | **PASS** | `rev_15`、`rev_16`、`data/reverify_summary.json` |
| 8 | 日/夜切换、重启保持 | **PASS** | `rev_17`~`rev_19` |
| 9 | 清除日间回落、夜间保留 | **PASS** | `rev_20` |
| 10 | 总开关关闭隐藏行且不绘制 | **PASS** | `rev_21`、`rev_22` |
| 11 | 虚化 0/50/100 递增、文字不受影响 | **PASS** | `rev_24`~`rev_26` |
| 12 | 护眼叠加 | **PASS** | `rev_27` |
| 13 | 本地备份→改值→恢复同会话生效 | **PASS** | `rev_28`~`rev_30`、`data/backup_before.json` |
| 14 | FATAL/ANR/OOM/overflow | **PASS（全 0）** | `logcat/session_reverify.log`、`logcat/crash_final.log` |
| 15 | 清理与版本保留 | **PASS** | `rev_33`、`rev_34` |

#### 8.3.1 层序 / 不透明度（修复前后）

- **100%（浅色、日间高对比红白棋盘 3000×2000）**：
  - 全屏逐像素扫描 `x 0..1080 / y 240..1919`，强红像素
    （`R>150 且 G<100 且 B<100`）**0 个**；基线同口径为 113 个高饱和红像素。
  - 分组左侧条带 `x 66..78` 为纯 `(240,240,240)`（std 0.3），
    行间缝隙带 `y 825..840` 亦为纯 `(240,240,240)`（1 种颜色）。
  - 卡面整区 `x 60..1020 / y 240..1900` 均值 `(229.1,228.1,227.8)`、
    强红 0、红倾向 0。
  - 结论：图片被不透明分组底色完整覆盖，**虚线边框消失**。
- **50%（同一图片）**：
  - 全屏强红像素 **0 个**（基线缝隙为全强度原图，边缘采样 `(231,166,165)`）。
  - 4dp 内边距单层混合，实测 alpha（以 0% 同坐标原图色为基准、绿色通道反解）
    **0.471 / 0.503 / 0.471 / 0.500**，即分组底色按 0.5 生效；
    行小卡区因再叠加一层 `surfaceContainerLow * 0.5`，表现为 0.75 混合（设计如此）。
  - 缝隙带颜色 `(233,198,198)`（红格）与 `(243,243,243)`（白格），
    相对 0% 的 `(216,76,76)` / `(255,255,255)` 为半强度混合，
    **无全强度原图线**。
- **0%（同一图片）**：全屏强红 356,662、红倾向 625,158，图片完整可见；
  文字直接叠在高对比棋盘上，**P3-1 仍存在**（非本批修复目标，未计回归）。
- **透明主题（深色、无图）**：100% 分组卡 `(51,51,51)`、页面 `(0,0,0)`；
  50% 卡 `(25,25,25)`、页面 `(0,0,0)` —— 与基线 P1 回归值
  `(51,51,51)/(0,0,0)` 完全一致，**未洗白**。
  透明主题 + 夜间蓝图：100% 卡 `(106,124,193)`、50% 卡 `(88,107,185)`，
  图片可按调色板 alpha 透出，未被白卡覆盖。
  （首次用点击轨道设 100 落在 97%，仅作中间过程；最终 100% 由滑杆拖到端点，
  UI 读数与像素均按 100% 记录。）

#### 8.3.2 伪图片（`.txt` 改名 `.png`）不再崩溃

- 步骤：外观 → 容器设置 → 容器背景图片（日间）→ 选择图片 →
  系统照片选择器「下载」→ `qa_fake_image.png`（5,200 B，MediaStore 声明 `image/png`）。
- 实际：
  - 进程存活：选择前后 PID 均为 **45786**；返回设置页，日间路径保持
    `8661e9d12f215e5e68ee531b35b135ca.png` 未被覆盖。
  - SnackBar 实测文案：**`设置容器背景图失败：不是可解码的图片：qa_fake_image.png`**
    （`rev_13_fake_rejected_toast.png`；uiautomator 语义节点
    `(0,1683)-(1080,1920)`）。
  - 日志：`FilePickerUtils: File loaded and cached at .../cache/file_picker/.../qa_fake_image.png`
    → `FlutterImageDecoderImplDefault: Failed to decode image`（非致命）
    → `I/flutter: ThemeConfigScreen._showContainerBgImageDialog 设置异常:
    FormatException: 不是可解码的图片：qa_fake_image.png`。
  - 崩溃缓冲：应用 FATAL **0**；`logcat -b crash` 仅 `Cmdline: uiautomator`
    工具退出 SIGSEGV。
- 正常图片回归：日间 PNG（`8661e9d1…png`）与夜间 JPG（`1a311a39…jpg`）
  在修复后多次选择/显示正常（`rev_04`、`rev_18`）。

#### 8.3.3 12MP 大图

- 选择 `qa_big_12mp_4000x3000.jpg`（4000×3000，973,379 B）作为日间容器图，
  落盘标识 `2a76838351a2fc772d6a116e7feb1704.jpg`（关闭压缩后原文件拷贝）。
- 浅色 + 50% 显示正常（`rev_16_12mp_light_50.png`），无 OOM/崩溃。
- 内存（`dumpsys meminfo`，单位 KB）：

| 时点 | TOTAL PSS | TOTAL RSS |
|---|---|---|
| 选择前（夜间图在深色下已绘制） | 121,128 | 255,228 |
| 选择后、尚未绘制（深色） | 128,467 | 263,120 |
| 切浅色绘制 12MP 后 | **124,400** | **259,004** |

  → 绘制后较基线 **+3.3 MB PSS / +3.8 MB RSS**；无 OOM。
  原因：`themeBackgroundImageProvider` 用 `ResizeImage(policy: fit)` 按
  「窗口×DPR」（1080×1920）限尺寸解码，未全量解码 12MP。

#### 8.3.4 回归

| 子项 | 实测 | 证据 |
|---|---|---|
| 日/夜切换 | 浅色显示红图、深色显示蓝图（均 50%），切换即时重绘 | `rev_17`、`rev_18` |
| 重启保持 | force-stop 后冷启动 379 ms；不透明度 50、日/夜文件名、总开关均保留 | `rev_19` |
| 清除日间回落 | 日间→未设置，浅色卡面回落主题底色（无图）；夜间路径保留 | `rev_20` |
| 总开关关闭 | 日/夜图片行隐藏；深色下卡面无蓝图，仅主题底色 | `rev_21`、`rev_22` |
| 虚化 0/50/100 | 页面边缘亮度标准差 **48.3 → 9.5 → 8.6**；文字/行卡清晰 | `rev_24`~`rev_26` |
| 护眼叠加 | 暖色滤镜 + 虚化 50%，文字可读；关闭后卡面恢复中性 | `rev_27`、`rev_31` |
| 备份/恢复同会话 | 备份 JSON 1,026 B，含 `containerOpacity=100`、`enableContainerBackgroundImage=true`、夜间路径、`backgroundImageBlurring=50`；改为 30/0 后长按恢复 → 未重启即回到 **100/50**，夜间路径恢复 | `rev_28`~`rev_30`、`data/backup_before.json` |

#### 8.3.5 FATAL / ANR / OOM

统计口径：`adb logcat -b all -d -v time`（会话 11,788 行）+
`adb logcat -b crash -d -v time`（最终 2,028 行）。

| 项 | 计数 |
|---|---|
| 应用 `FATAL EXCEPTION` / `Process: io.legado.flutter_legado` | **0** |
| `ANR in io.legado` | **0** |
| `OutOfMemoryError` | **0** |
| `RenderFlex overflowed` | **0** |
| 应用 native tombstone（`Cmdline: io.legado.flutter_legado`） | **0** |
| QA 工具 `uiautomator` tombstone | 92（工具退出 SIGSEGV，非应用） |

- 修复前同口径应用 FATAL=2；本轮复验 **FATAL=0**，场景 5 的伪图片路径未新增
  任何 FATAL。

#### 8.3.6 清理

| 项 | 结果 |
|---|---|
| 应用数据 | `pm clear io.legado.flutter_legado` **Success**，随后冷启动 360 ms |
| 书架 | **空**（`rev_33`：「书架还空着…」） |
| 容器默认 | 总开关关、日/夜图片行隐藏、不透明度 100、虚化 0/0（`rev_34`） |
| 全局壁纸 | 已删除（`背景图片/未设置`，`rev_32`） |
| 主题/护眼 | 默认（跟随系统、默认预设、护眼关） |
| 设备文件 | `/sdcard/Download/qa_*.{png,jpg}` 已删；`legado_qa_backup/` 先重命名再 `rmdir` 清除（SAF 占用时 `rm -rf` 报 Text file busy） |
| 版本 | 保留 **2.0.434 / 435**（`dumpsys` 复核） |

### 8.4 修复前后对照

| 检查点 | 修复前（基线） | 修复后（本轮） |
|---|---|---|
| 100% 默认档 | 4dp/2dp 缝隙漏原图，呈红色虚线边框；截图 113 个高饱和红像素 | 全屏强红 **0**；4dp 条带与行间缝隙均为 `(240,240,240)` |
| 50% | 缝隙为全强度原图（边缘 `(231,166,165)`），卡内 50% 混合，亮度不均 | 内边距 alpha≈0.5、行卡 0.75（同一 alpha 叠加）；全屏强红 **0** |
| 伪图片选择 | 两次 `Bitmap.compress` NPE，应用进程死亡（PID 36368/37980） | 进程存活（PID 45786 不变），SnackBar 提示「不是可解码的图片」，路径保留 |
| 应用 FATAL | 2 | **0** |
| ANR / OOM / overflow | 0 | 0 |
| 透明主题 100%（无图） | 卡 `(51,51,51)`、页面 `(0,0,0)` | `(51,51,51)` / `(0,0,0)`（未回退） |

### 8.5 结论与残留

- **P2-1（层序虚线边框/不均匀）**：关闭。100% 无任何图片泄漏，
  50% 整卡按同一 alpha 混合且无全强度缝隙；透明主题 P1 回归保持通过。
- **P2-2（伪图片 FATAL）**：关闭。`allowCompression:false` 生效，
  非图片文件由 Dart 解码校验拒绝并 toast，进程/旧设置保持；FATAL=0。
- **P3-1（0% 文字可读性）**：仍存在（0% 时文字直接叠图），属既有极端档位
  权衡，未在本轮修复范围内。
- **设计说明（非缺陷）**：50% 时行小卡区为 0.75 混合、分组内边距为 0.5，
  系行卡自身 `surfaceContainerLow * opacity` 叠加所致；两者都受同一
  `containerOpacity` 调制，无全强度原图线，符合提交说明。
- 本轮**未重新测量**：SurfaceFlinger 帧时间/长时间滚动性能（基线 P3-2 数据
  保留，本轮仅回归虚化视觉递增）；「忽略主题配置」对图片路径的覆盖语义
  （基线已登记）；参考版 kazusa 逐像素对照。
- 全量 Flutter 测试已补跑：**3775 passed / 1 skipped**，EXIT=0。

### 8.6 复验证据清单

| 类别 | 文件 |
|---|---|
| 截图 | `docs/materials_1101e/reverify/rev_01_container_default.png` ~ `rev_34_final_clean_container_default.png`（34 张） |
| 构建/安装 | `tmp_debug/device_acceptance_20261101_reverify/logcat/build_reverify.log` |
| 全量测试 | `logcat/full_tests.log`（3775 passed / 1 skipped，EXIT=0） |
| 会话日志 | `logcat/session_reverify.log`（11,788 行，FATAL/ANR/OOM/overflow 均 0） |
| 崩溃缓冲 | `logcat/crash_reverify.log`、`logcat/crash_final.log`（应用崩溃 0；uiautomator 92） |
| 像素/内存汇总 | `data/pixel_samples_reverify.json`、`data/reverify_summary.json` |
| 备份样本 | `data/backup_before.json`（1,026 B；容器键实测值） |

编写者：QA（ZCode 子代理）｜ 2026-11-01（回修复验）
