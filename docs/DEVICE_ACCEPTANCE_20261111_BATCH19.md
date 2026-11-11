# 设备验收报告 — 批19「应用字体 + 隐私明示 + armv7」

- 日期：2026-11-11
- 设备：MuMu「Test测试」`192.168.100.62:5555`（SM-G9900 / Android 15 / SDK 35 / 1080x1920 / 480dpi，逻辑宽 360dp）
- APK：`2.0.489+490`（versionName=2.0.489，versionCode=490）
  - 文件：`build/app/outputs/flutter-apk/app-release.apk`（211,178,960 B）
  - SHA-256 实测：`300b4fa688e98ae729d1026090635071d2e9e785cfbdb0360f2cbdd2c32e94f6`（与任务给定值一致）
- 运行 ABI：`x86_64`（`primaryCpuAbi=x86_64`；MuMu 环境）
- 测试字体：`simhei.ttf`，9,745,792 B（9.29 MiB，低于 10MB 上限），push 至 `/sdcard/Download/` 后经 SAF 选择
- 测试书：`tmp_qb15_book`（本机 TXT，3 章，书架既有）
- 证据目录：`docs/materials_1111e/`（截图 `tmp_qb19_01.png` … `tmp_qb19_28.png`；日志 `logcat_b19.txt`、`crash_b19.txt`）

## 一、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 13 |
| FAIL | 0 |
| BLOCKED（清单项） | 0 |

**结论：13 项验收全部通过。** 应用字体可导入、即时生效、重启持久化、可清除恢复默认，且与阅读正文字体完全独立；隐私「说明」三段文案与要求逐字一致、无旧矛盾表述，font_scale 1.3 下无溢出；APK 含 `armeabi-v7a/liblegado_ffi.so`；全会话五项崩溃计数与 OOM 均为 0。

验收边界（不构成失败）：

- MuMu 为 x86_64，armv7 原生库仅验证「APK 内含」，**未做 v7a 运行时加载证明**（本清单亦只要求包内存在）。
- 设备未设置隐私密码（偏好中无 privacy 键），隐私页直接进入；**密码验证闸门路径本批未触发**。
- SAF 选择器未按扩展名收窄（可见 txt/json），本次通过搜索 `simhei` 选中目标文件；错误文件导入拒绝路径未构造验证（代码存在扩展名+魔数双校验）。

## 二、逐项验收

### A. 应用字体（核心）

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 1 | 我的 → 设置 → 外观 →「字体设置」行，且在主题管理之后 | PASS | `tmp_qb19_03.png` | 外观页顺序为「主题管理」（y=1272–1488）→「字体设置」（y=1494–1710）→「导出主题」；字体设置副标题「未设置（跟随系统默认字体）」 |
| 2 | 点击弹出「选择字体文件」「清除字体」 | PASS | `tmp_qb19_04.png`、`tmp_qb19_08.png` | 未设置字体时弹窗仅显示「选择字体文件」（`04`，清除项按设计仅在有字体时出现）；设置后再次打开同时显示「选择字体文件」「清除字体」（`08`），语义正确 |
| 3 | 选择宿主字体 → 成功提示；界面文字明显变化 | PASS | `tmp_qb19_05.png`、`tmp_qb19_06.png`、`tmp_qb19_26.png`、`tmp_qb19_07.png`、`tmp_qb19_03.png` | SAF 打开 Download（`05`），搜索 `simhei` 命中「simhei.ttf，9.75 MB，TTF 文件」（`06`）；选中后 SnackBar「应用字体已更新」（`26`）；设置页全部中文由默认无衬线变为黑体（`07` vs `03`），行副标题「已设置：simhei.ttf」；应用内副本 `app_font/4093871a7f48e43b9ce7c38da0c34809_simhei.ttf`（9,745,792 B） |
| 4 | force-stop + 重启后字体仍生效 | PASS | `tmp_qb19_09.png`、`tmp_qb19_19.png` | 强制停止并冷启动后，书架大标题「书架」及列表仍为黑体（`09` vs 默认基线 `01`）；外观页行仍「已设置：simhei.ttf」（`19`）；偏好 `flutter.appFontPath` 保持 |
| 5 | 正文独立性：打开本地 TXT，正文不得使用应用字体 | PASS | `tmp_qb19_10.png`、`tmp_qb19_07.png` | 应用字体已设为 simhei 时打开 `tmp_qb15_book`：设置页为黑体（`07`），正文为阅读器默认字体、字形明显不同（`10`），页码 1/31；偏好 `appFontPath` 有值而 `reader_font_family` **不存在**（空=系统默认），两条链路互不影响 |
| 6 | 阅读器内改为另一字体 → 正文变化、设置页仍为应用字体 | PASS | `tmp_qb19_14.png`、`tmp_qb19_15.png`、`tmp_qb19_16.png`、`tmp_qb19_18.png`、`tmp_qb19_19.png` | 阅读器 → 设置 → Tt →「选择字体/正文字体」→ 字体管理（`14`）；选「等宽体 (Monospace)」后正文重排，页码 1/31→1/34（`16`）；再选「衬线体 (Serif)」后正文为明显衬线字形（`18`）；期间设置页始终保持应用黑体（`19`）；偏好 `reader_font_family=serif` 与 `appFontPath` 并存 |
| 7 | 清除字体 → 恢复系统默认；重启后仍默认 | PASS | `tmp_qb19_20.png`、`tmp_qb19_21.png` | 点「清除字体」后 SnackBar「已恢复默认字体」，界面立即回到默认字体，行副标题「未设置（跟随系统默认字体）」（`20`）；force-stop 冷启动后书架与 `01` 一致（`21`）；`flutter.appFontPath` 已移除，`files/app_font/` 为空目录；`reader_font_family=serif` 保留，进一步证明两套字体独立 |

### B. 隐私明示

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 8 | 设置 → 隐私 →「说明」三段文案，且无旧矛盾表述 | PASS | `tmp_qb19_22.png`、`tmp_qb19_23.png` | 设备未设隐私密码，入口直接进入（`22`）；滚到「说明」段（`23`），三段逐字为：①「隐私密码凭据仅保存在本机，不随应用内备份或书籍导出。…」②「私密内容不会从本地与 WebDAV 备份（含自动上传）、书籍导出、进度同步或 Web 服务中排除。…」③「隐私密码凭据（加盐校验值）与私密标记保存在应用数据库内，可能随 Android 系统云备份一起迁移到其他设备。」；全仓 `grep -rn "不随备份导出" lib` = **0 命中**，无旧矛盾表述 |
| 9 | 360dp + font_scale 1.3 文案不溢出 | PASS | `tmp_qb19_24.png`、`tmp_qb19_25.png`；`logcat_b19.txt` | `settings put system font_scale 1.3` 后隐私页文字放大（`24`），滚动到底三段完整显示、无横向溢出/截断/省略号（`25`）；1080/480dpi 即 360dp；全会话 `RenderFlex overflowed=0`；验证后恢复 `font_scale=1.0` |

### C. armv7

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 10 | APK 内含 `lib/armeabi-v7a/liblegado_ffi.so` | PASS | `unzip -l app-release.apk` 输出 | `lib/armeabi-v7a/liblegado_ffi.so` = **22,529,324 B**；同目录另有 `libapp.so` 21,381,708 B、`libflutter.so` 8,453,804 B；对照 `arm64-v8a/liblegado_ffi.so`=35,778,992 B、`x86_64/liblegado_ffi.so`=39,671,056 B |
| 11 | 设备侧记录当前运行 ABI | PASS | `dumpsys package` 输出 | `primaryCpuAbi=x86_64`（MuMu x86_64 运行 x86_64 库）；`versionName=2.0.489`、`versionCode=490`、`minSdk=24`、`targetSdk=36`。清单仅要求确认包内含 v7a，已确认 |

### D. 稳定性

| # | 验收项 | 结果 | 证据 | 说明 |
| --- | --- | --- | --- | --- |
| 12 | logcat 五项崩溃计数=0，OutOfMemory=0 | PASS | `logcat_b19.txt`（19,560 行）、`crash_b19.txt`（1,211 行） | 全缓冲区计数：`FATAL EXCEPTION`=**0**、`ANR in`=**0**、`E/flutter`=**0**、`RenderFlex overflowed`=**0**、`E AndroidRuntime`=**0**、`OutOfMemory`=**0**；crash buffer 中 `io.legado` 命中 **0**，55 条 tombstone 全部为 `Cmdline: uiautomator`（测试工具退出期 SIGSEGV，非应用）；`dumpsys activity exit-info` 仅有 USER REQUESTED（force-stop）、PACKAGE UPDATED、clear data，无 crash/ANR 退出原因 |
| 13 | `pm clear` 清理 + 终态截图 | PASS | `tmp_qb19_28.png` | `pm clear io.legado.flutter_legado` 返回 `Success`；重新启动后书架为空态「书架还空着，先去搜索书籍或从发现里添加吧！」（`28`），应用数据已重置；外部测试字体 `/sdcard/Download/simhei.ttf` 已删除 |

## 三、问题分级

未发现 P0/P1/P2 缺陷。以下为观察项/覆盖边界，均不影响本批验收结论：

### P3-1（观察项，非缺陷）SAF 选择器未按扩展名收窄

- 现象：点击「选择字体文件」进入 `com.android.documentsui` 的 Download 目录后，列表同时显示 `.txt`、`.json` 等非字体文件（`tmp_qb19_05.png`），未见 ttf/otf/ttc 过滤。
- 影响：用户可能选中非字体文件；`AppFontStore` 在导入侧做扩展名白名单 + 文件头魔数/表目录双校验，超限/损坏文件会以中文错误提示拒绝（`lib/src/services/app_font_store.dart:1-16` 注释与实现），预期不会崩溃或应用非法字体。
- 边界：本批未构造「选择 txt/json」路径，拒绝行为未实测；目标文件可通过右上角搜索 `simhei` 正常选中（`tmp_qb19_06.png`）。

### P3-2（覆盖边界）隐私密码闸门未触发

- 设备为新清理状态，偏好中无 privacy 相关键，`我的 → 设置 → 隐私` 直接进入（`tmp_qb19_22.png`），符合「未设密码」语义；「已设密码需先验证」的分支本批未覆盖。

### P3-3（环境边界）armv7 仅验证包内含，未验证运行时加载

- MuMu 为 x86_64（`primaryCpuAbi=x86_64`），无法执行 armeabi-v7a 原生库；本项按任务口径只确认 APK 打包存在（22,529,324 B），真机/armv7 设备上的加载与运行未证明。

### P3-4（测试工具噪声）55 条 tombstone 全部来自 uiautomator

- `crash_b19.txt` 共 1,211 行，`Cmdline: uiautomator` 55 条，`Cmdline` 含 `io.legado` 0 条；`Fatal signal` 55 条与 `Shutting down VM` 55 条一一对应，均为 uiautomator 进程退出期 `__cxa_finalize` SIGSEGV，与应用无关；不计入崩溃计数。

## 四、设备终态

- 应用数据：`pm clear io.legado.flutter_legado` 返回 `Success`，应用回到空书架首启状态（`tmp_qb19_28.png`）；
- 字体偏好：`flutter.appFontPath` 与 `reader_font_family` 均随数据清除；`files/app_font/` 为空；
- 系统字体缩放：已恢复 `font_scale=1.0`；
- 外部测试字体：`/sdcard/Download/simhei.ttf` 已删除；
- 应用仍安装：`io.legado.flutter_legado` 2.0.489+490，`primaryCpuAbi=x86_64`；
- 当前前台：`io.legado.flutter_legado/io.legado.flutter.MainActivity`（空书架）；
- 稳定性终值：`logcat_b19.txt` 19,560 行，五项崩溃计数与 OOM 全为 0。

## 五、门禁引用

- `AGENTS.md:23`：Flutter 门禁为 `flutter_legado/` 下 `flutter analyze && flutter test`（CI：`.github/workflows/flutter-ci.yml`）。本批为 CI 覆盖不到的设备验收（UI 交互/实机持久化/文案核查），未改代码，不重复静态门禁。
- `AGENTS.md:65`：每轮修复后两级验证（测试档模拟器 → 用户验收档）；本次在 MuMu「Test测试」实例执行。
- `AGENTS.md:77`：CI 能覆盖的验证以 CI 结果为准，角色只用于实机冒烟、UI 交互等场景。
- `AGENTS.md:79`：子代理自述（无独立证据）不构成验收依据；本报告每项均附截图/命令/日志路径。
- 崩溃五项口径沿用批11–批18 设备验收：`FATAL EXCEPTION` / `ANR in` / `E/flutter` / `RenderFlex overflowed` / `E AndroidRuntime`（并加 `OutOfMemory`），参见 `docs/DEVICE_ACCEPTANCE_20261101_BATCH9B6C.md` 与 `docs/DEVICE_ACCEPTANCE_20261111_BATCH18.md`。
- APK 指纹与任务给定值一致（`300b4fa6…c32e94f6`），确认验收对象正确。

## 六、证据清单（`docs/materials_1111e/`）

| 文件 | 用途 |
| --- | --- |
| `tmp_qb19_01.png` | 基线：默认字体书架 |
| `tmp_qb19_02.png` | 我的页（导航定位） |
| `tmp_qb19_03.png` | 外观页：主题管理 → 字体设置（未设置） |
| `tmp_qb19_04.png` | 字体设置弹窗（未设置，仅「选择字体文件」） |
| `tmp_qb19_05.png` | SAF Download 列表（未按扩展名收窄） |
| `tmp_qb19_06.png` | SAF 搜索 simhei.ttf（9.75MB TTF） |
| `tmp_qb19_07.png` | 选中后：设置页变黑体、行显示已设置 |
| `tmp_qb19_08.png` | 设置后弹窗：选择字体文件 + 清除字体 |
| `tmp_qb19_09.png` | 重启后书架仍为黑体 |
| `tmp_qb19_10.png` | A5：应用字体为黑体时，正文仍为默认阅读字体 |
| `tmp_qb19_11.png` | 阅读器菜单 |
| `tmp_qb19_12.png` | 阅读器设置面板 |
| `tmp_qb19_13.png` | 阅读器字体面板（正文字体/标题字体） |
| `tmp_qb19_14.png` | 阅读器字体管理列表 |
| `tmp_qb19_15.png` | 选择等宽体后的预览 |
| `tmp_qb19_16.png` | 正文等宽体：页码 1/31→1/34 |
| `tmp_qb19_17.png` | 字体列表（改选衬线体前） |
| `tmp_qb19_18.png` | 正文衬线体（与设置页黑体明显不同） |
| `tmp_qb19_19.png` | 阅读字体改为衬线后，设置页仍为黑体 |
| `tmp_qb19_20.png` | 清除字体：SnackBar 已恢复默认字体 + 默认 UI |
| `tmp_qb19_21.png` | 清除后重启：书架仍默认字体 |
| `tmp_qb19_22.png` | 隐私设置页（无密码直接进入） |
| `tmp_qb19_23.png` | 隐私「说明」三段文案（默认缩放） |
| `tmp_qb19_24.png` | 隐私页 font_scale 1.3 上半段 |
| `tmp_qb19_25.png` | 隐私「说明」font_scale 1.3 底部，无溢出 |
| `tmp_qb19_26.png` | 再次选择字体：SnackBar「应用字体已更新」 |
| `tmp_qb19_27.png` | 更新提示消失后的设置页（黑体） |
| `tmp_qb19_28.png` | `pm clear` 后终态：空书架 |
| `logcat_b19.txt` | 全会话 19,560 行；五项崩溃计数与 OOM 取证 |
| `crash_b19.txt` | crash buffer 1,211 行；55 条均为 uiautomator，app 0 条 |
| `commands_b19.txt` | 环境/指纹/armv7/偏好/字号/崩溃计数/终态的命令与输出转录 |

---

编写：QA 子代理｜2026-11-11
