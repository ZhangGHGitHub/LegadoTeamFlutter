# 批15 替换规则 `@js:` 生产执行 — 设备验收报告

验收日期：2026-11-10
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改任何仓库代码）
证据目录：`docs/materials_1110f/`
验收依据：`docs/REFACTORING_ACTIVE_PLAN.md:1229`（批15 设备判据：构造含 `@js:` 的替换规则，阅读正文确认生效（与预览一致），FATAL/ANR/overflow=0）

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu 模拟器，`192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | `ro.product.model=SM-G9900`（MuMu 模拟），Android 15（API 35） |
| 分辨率 / 密度 / 逻辑宽度 | 1080x1920，480dpi → **360dp 宽** |
| 系统字体缩放 | `font_scale=1.0` |
| 被测包 | `io.legado.flutter_legado` |
| 设备路径 / APK sha256 | `/data/app/~~LbzcV0aGkMZN2lenPVc8aQ==/io.legado.flutter_legado-23qz76QpTc6_LfZjcWnP3Q==/base.apk`，`sha256=af82aac4c69cdf51e7e87d4b912fcee6dd5468918163ad99fc09c3171cf85496`（设备内 `sha256sum` 实测，与任务给定值一致） |
| 设备实测版本（dumpsys） | `versionName=2.0.484`，`versionCode=485`，`lastUpdateTime=2026-11-10 21:29:16` |
| 声明目标版本 | `2.0.484+485`（`flutter_legado/pubspec.yaml` 第 4 行）——与设备一致 |
| 测试书 | `tmp_qb15_book.txt`，19,486 B，`adb push` 到 `/sdcard/Download/` 后经书架「更多 → 添加本地」导入；书名为 `tmp_qb15_book`，共 3 章 |
| 测试书内容 | 第一章含 `12 34 56` 与两个标记段落；第二章为约 8 KB 长章（`数字 12 与 34 与 56 …` 大量重复）；第三章含 `最后 78 90 12` |

版本核对：设备 APK sha256、`dumpsys` 版本、`pubspec.yaml` 三者一致，未发现版本漂移。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 11 |
| FAIL | 0 |
| BLOCKED | 0 |
| 合计 | 11 |

结论：批15「替换规则 `@js:` 生产执行」在设备上验收项全部通过。核心修复点已实机证明：**同一规则在编辑页预览为 `12 → 24`，在阅读器生产正文同样生效**（第一章 `12 34 56` → `24 68 112`，第二章长章 `数字 24 与 68 与 112`）；`@js:` 可读取生产链路的 `chapter.title`（第一章/第二章分别输出各自标题）与 `book.name`（输出 `tmp_qb15_book`）；`@js:` 抛错与死循环超时均保留原文、页面可正常交互；约 8 KB 长章启用翻倍规则后冷启动打开，内容在约 0.3–0.5 s 内渲染完成（远低于 1–2 s 要求）；三份 logcat 的五项崩溃/异常计数均为 0；`pm clear` 后设备回到桌面终态。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1110f/`） | 说明 |
| --- | --- | --- | --- |
| A1 导入本地 TXT | PASS | `tmp_qb15_09_imported.png`（toast「已导入 1 本书籍」）、`ui_b15_09.xml`、`tmp_qb15_03_picker.png`、`ui_b15_12.xml`（共 3 章） | 书架「更多 → 添加本地」打开系统选择器，选中 `tmp_qb15_book.txt` 后返回书架并出现书卡；详情页显示 19.0 KB、共 3 章 |
| B2 新建 `JS double` 规则 | PASS | `tmp_qb15_18_rule_edit.png`（正文范围选中）、`tmp_qb15_24_rule_saved.png`（列表开关 ON）、`ui_b15_19.xml`、`ui_b15_20.xml`、`ui_b15_21.xml` | 名称 `JS double`；匹配规则 `(\d+)`；替换为 `@js:String(Number(result)*2)`；作用范围勾选「正文」；「使用正则表达式」勾选；超时 3000 ms；保存后列表出现且启用 |
| B3 编辑页预览 `12 → 24` | PASS | `tmp_qb15_23_preview_12_24.png`、`ui_b15_23.xml` | 预览输入 `12`，预览输出 `24`；预览走 `previewReplaceRule` FFI 真实替换管线 |
| B4 正文生产生效（核心） | PASS | `tmp_qb15_28_ch1_doubled.png`（第一章 `24 68 112`）、`tmp_qb15_25_reader_doubled.png`（第二章 `数字 24 与 68 与 112`）、`ui_b15_25.xml`、`ui_b15_28.xml`、`tmp_qb15_52_clean_coldstart_doubled.png`（冷启动复验） | 返回书架打开正文，数字全部翻倍且非原文；冷启动后仍为翻倍值。证明生产链路真实执行 `@js:`，与预览一致 |
| B5 关闭规则恢复原文 | PASS | `tmp_qb15_29_rule_disabled.png`（开关 OFF）、`tmp_qb15_30_rule_off_original.png`（`12 34 56`）、`ui_b15_30.xml` | 关闭开关后重新打开正文，恢复 `12 34 56` / `第 12 章…34…56`，无残留替换 |
| C6 chapter / book 绑定 | PASS | `tmp_qb15_33_chapter_binding.png`、`tmp_qb15_36_book_binding.png`、`ui_b15_33.xml`、`ui_b15_36.xml`、`tmp_qb15_37_rules3.png` | ① `(\d+)` → `@js:chapter.title`：第一章数字显示「第一章 数字测试」，同一次语义树中第二章数字显示「第二章 长章测试」，证明标题随章节动态绑定；② `(\d+)` → `@js:book.name`：数字显示 `tmp_qb15_book`。两规则分时启用，互不干扰。按清单允许的降级方案，采用 `@js:chapter.title` / `@js:book.name` 直接替换数字 token（避免 adb 注入引号与字符串拼接的转义风险） |
| D7 `@js:` 抛错降级 | PASS | `tmp_qb15_39_preview_throw.png`、`tmp_qb15_40_throw_original.png`、`ui_b15_39.xml`、`ui_b15_40.xml`、`tmp_qb15_41_rules4.png`（JS throw 开关 ON） | 规则 `(\d+)` → `@js:throw new Error("x")` 启用；预览输出以 `⚠️` 开头错误文本；打开正文保持原文 `12 34 56`，未崩溃、未清空 |
| D8 `@js:` 死循环超时降级 | PASS | `tmp_qb15_58_loop_enabled.png`（规则开关 ON）、`tmp_qb15_60_loop_loading_387ms.png`（加载中）、`tmp_qb15_61_loop_after_timeout.png`（原文恢复）、`tmp_qb15_62_loop_menu_responsive.png`（菜单可交互）、`ui_b15_61.xml`、`ui_b15_62.xml`；首轮复验 `tmp_qb15_43_timeout_original.png`、`tmp_qb15_44_timeout_menu_responsive.png` | 规则 `(\d+)` → `@js:while(true){}` 启用；打开正文约 0.39 s 显示「加载章节…」，约 3.1 s 后稳定为原文 `12 34 56`（与规则 3000 ms 超时一致）；随后点按屏幕菜单正常弹出，未卡死/ANR |
| E9 长章节性能 | PASS | `tmp_qb15_49_perf_shelf_baseline.png`、`tmp_qb15_50_perf_frame2_286ms.png`、`tmp_qb15_51_perf_frame3_settled.png`、`tmp_qb15_52_clean_coldstart_doubled.png` | 冷启动 → 书架 → 点击书籍；帧捕获：68 ms 仍为书架、286 ms 已显示第二章（`1/50`，`数字 24 与 68 与 112`，带页面切换过渡）、491 ms 稳定。首帧内容 ≤ 约 0.5 s，无白屏/ANR，远低于 1–2 s |
| F10 logcat 五项崩溃计数 | PASS | `logcat_b15_session.txt`（5,665 行，全程）、`logcat_b15.txt`（547 行，清空后冷启动→打开正文干净段）、`logcat_b15_d8_retest.txt`（1,893 行，D8 复测段） | 三份日志实测均为：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`overflowed`=0、`E AndroidRuntime`=0 |
| F11 清理与终态 | PASS | `tmp_qb15_63_terminal_final.png`、`tmp_qb15_53_terminal.png` | `adb shell pm clear io.legado.flutter_legado` 返回 `Success`；`pidof` 无输出；`mCurrentFocus=com.microsoft.launcher/.Launcher`；`font_scale=1.0`；截图显示桌面 |

### 关键取证摘要

**规则定义（设备内实际输入值）**

| 规则名 | 匹配规则 | 替换为 | 范围 | 备注 |
| --- | --- | --- | --- | --- |
| `JS double` | `(\d+)` | `@js:String(Number(result)*2)` | 正文 | 默认超时 3000 ms |
| `JS chapter` | `(\d+)` | `@js:chapter.title` | 正文 | 验证章节标题绑定 |
| `JS book` | `(\d+)` | `@js:book.name` | 正文 | 验证书名绑定 |
| `JS throw` | `(\d+)` | `@js:throw new Error("x")` | 正文 | 验证异常降级 |
| `JS loop` | `(\d+)` | `@js:while(true){}` | 正文 | 验证超时降级 |

**正文输出对照（设备截图 + 语义树双证据）**

- 规则全关（首次打开）：第一章 `12 34 56`；正文 `这是第 12 章的正文，共有 34 个段落和 56 行文字。`（`tmp_qb15_10_reader_original.png`）
- `JS double` 启用：第一章 `24 68 112`；正文 `这是第 24 章的正文，共有 68 个段落和 112 行文字。`；第二章 `数字 24 与 68 与 112 重复出现…`；第三章语义树 `最后 156 180 24`（`tmp_qb15_28_ch1_doubled.png`、`tmp_qb15_25_reader_doubled.png`、`ui_b15_25.xml`）
- `JS chapter` 启用：第一章数字位置显示 `第一章 数字测试`，同屏预加载的第二章数字位置显示 `第二章 长章测试`（`tmp_qb15_33_chapter_binding.png`、`ui_b15_33.xml`）
- `JS book` 启用：数字位置显示 `tmp_qb15_book`（`tmp_qb15_36_book_binding.png`、`ui_b15_36.xml`）
- 关闭 `JS double`：恢复 `12 34 56`（`tmp_qb15_30_rule_off_original.png`）

**异常与超时**

- 抛错规则预览输出原文：`⚠️ JS engine error: x (at <eval> (<input>:1:10)\n    at <anonymous> (eval_script:1:42)\n    at <eval> (eval_script:1:74))`；正文保持原文（`ui_b15_39.xml`、`tmp_qb15_40_throw_original.png`）
- 死循环规则：0.387 s 帧为「加载章节…」；约 3.1 s 后内容帧稳定为原文（逐帧 `dark_px` 由加载态约 9k 跳至正文态约 31k 并保持不变）；点按菜单 2 s 内正常响应（`tmp_qb15_60_loop_loading_387ms.png`、`tmp_qb15_61_loop_after_timeout.png`、`tmp_qb15_62_loop_menu_responsive.png`）

**性能帧序列（长章 + `JS double`）**

| 帧 | 时间戳（相对点击） | 画面 |
| --- | --- | --- |
| f1 | 68 ms | 仍为书架 |
| f2 | 286 ms | 已显示第二章正文 `数字 24 与 68 与 112`，带页面切换过渡 |
| f3 | 491 ms | 页面稳定 |

另：`uiautomator` 首次语义 dump 返回内容耗时 2,212 ms（含工具自身 dump/进程启动开销），不作为应用首帧耗时口径。

**正则方言适配旁证**：`logcat` 中 `I/legado-regex` 记录 `[regex_safe] 首次编译 pattern … 前64字符: ([0-9]+)`（21:45:00.040），说明规则 `(\d+)` 已进入 Java 方言适配后的真实编译路径。

## 四、发现的问题（分级）

### 问题 1（P3，观察，非本批路径）：部分 TXT 段落首行在阅读器可视区缺失
- 现象：测试书中的两行 `批十五标记 出现在这一行。`、`批十五书名 出现在这一行。` 在阅读器中只显示 `出现在这一行。` / `这一行。`，段落首行（`批十五标记` / `批十五书名 出现在`）不可见；长章正文首段、数字段均正常。
- 范围界定：**规则全关时同样复现**（`tmp_qb15_10_reader_original.png` 与 `ui_b15_10.xml`：语义树文本含完整 `批十五标记`，但可视区无该行），与本批 `@js:` 执行改动无直接关系；不影响数字翻倍、章节/书名绑定、异常/超时判定。
- 影响：仅影响视觉呈现与完整性观感，不影响数据（语义树/选区文本仍含全文）。
- 建议：另立单排查阅读器段落排版/分页（`flutter_legado/lib/src/widgets/paragraph_layout_engine.dart`、`reader_text_content.dart`），确认“段落首行未绘制”的触发条件；本批不阻塞。
- 证据：`tmp_qb15_10_reader_original.png`、`ui_b15_10.xml`、`tmp_qb15_30_rule_off_original.png`。

### 问题 2（P3，取证工具/环境）：`uiautomator dump` 进程退出时 SIGSEGV
- 现象：每次 `uiautomator dump` 结束后，日志出现 `F/libc … Fatal signal 11 … name: Shutdown thread >>> uiautomator <<<` 与 `F/DEBUG`、`crash_dump64`；这是 shell 侧 `uiautomator` 进程（MuMu x86_64/Houdini 转换环境）在 VM 关闭阶段的崩溃，并非被测应用进程。
- 影响：不影响 dump 结果与验收结论；五项规定计数仍为 0。已核对崩溃进程名为 `uiautomator`，非 `io.legado.flutter_legado`。
- 建议：后续设备取证可改用其他语义/截图工具，或在统计时显式排除该工具进程；无需应用侧修复。
- 证据：`logcat_b15_session.txt` 中 `pid: 32945 … >>> uiautomator <<<` 段；`logcat_b15.txt` 同类 1 条。

### 问题 3（P3，展示细节）：规则列表把替换表达式截断为 `@j...`
- 现象：替换规则列表的副标题仅显示 `正则: (\d+) → @j...`，完整表达式需进编辑页查看。
- 影响：纯展示摘要，无功能影响；编辑页完整显示并已用于验收。
- 建议：如需要一眼辨认多条 JS 规则，可考虑加长摘要或显示规则名 tooltip（超出本批范围）。
- 证据：`tmp_qb15_24_rule_saved.png`、`tmp_qb15_58_loop_enabled.png`。

### 说明（非问题）：预览不含 chapter/book 上下文
- `@js:chapter.title` / `@js:book.name` 在编辑页预览中按设计使用空章节/空书籍上下文（与参考版预览一致，代码测试 `test_preview_js_rule_binds_empty_chapter_and_book` 明确断言），因此 C6 的 chapter/book 绑定必须在生产正文验证；本次已按此执行并取证，不构成缺陷。

### 结论
无 P0/P1/P2 问题，无 FAIL / BLOCKED 项；以上 3 项均为 P3（1 项范围外观察、1 项工具链现象、1 项展示细节），不阻塞批15 验收。

## 五、设备终态

| 项目 | 终态 |
| --- | --- |
| `pm clear` | `Success`（`io.legado.flutter_legado` 应用数据已清空） |
| 应用进程 | `pidof io.legado.flutter_legado` 无输出，已退出 |
| 前台窗口 | `mCurrentFocus=Window{96da3b4 u0 com.microsoft.launcher/com.microsoft.launcher.Launcher}` |
| 系统字体缩放 | `font_scale=1.0` |
| 屏幕 | 桌面（`tmp_qb15_63_terminal_final.png`） |
| APK | 仍安装 `2.0.484+485`（未卸载、未降级），设备内 sha256 未变 |
| 测试残留 | `/sdcard/Download/tmp_qb15_book.txt` 保留（测试素材）；应用侧规则/书籍数据已随 `pm clear` 清除 |

## 六、门禁引用

### 代码路径（本批实现，只读核对）
- `rust/legado-js/src/replace_rule_js.rs`（批17 由 `rust/legado-ffi/src/api/replace_rule_js.rs` 下沉，App/Web 共用）：替换规则 `@js:` 执行器；`build_script` 为 `result` / `chapter` / `book` 唯一绑定构造点；线程内复用 QuickJS 引擎；逐匹配 IIFE + `eval`；单次执行预算与规则剩余预算取小。
- `rust/legado-ffi/src/api/reader.rs`：`apply_content_processing_inner` 在正文净化生产路径构造 `ReplaceJsBindings` 并注入执行器（`build_replace_js_bindings`），`re_segment` / `remove_duplicate_title` 等步骤顺序未变。
- `rust/legado-core/src/content_processor.rs`：`run_replace_rules` / `apply_replace_rules` 对 `@js:` 逐匹配执行、规则级异常/超时保留原文。
- `flutter_legado/lib/src/screens/replace_rule_edit_screen.dart:395-420`：编辑页预览走 `previewReplaceRule`，规则级错误以 `⚠️` 前缀展示。

### 代码侧单测（本轮设备验收未重跑，作为门禁引用）
- `test_content_processing_js_replace_rule_executes_in_production_pipeline`（生产链路执行 `@js:`，`a12b → a24b`）
- `test_js_replace_rule_2000_matches_reuse_engine_within_timeout`（2000 次匹配复用引擎、默认 3000 ms 内完成）
- `test_content_processing_js_bindings_chapter_and_book_visible`（`chapter.title/index/url/bookUrl`、`book.name/author/bookUrl` 全字段可见）
- `test_js_replace_rule_preview_matches_production`（预览与生产输出一致）
- `test_js_replace_rule_error_keeps_original_and_continues`（抛错保留原文且后续 JS 规则继续）
- `test_js_replace_rule_timeout_keeps_original_and_continues`（超时保留原文且后续 JS 规则继续）
- `replace_rule_api.rs` 预览五类用例，含 `test_preview_js_rule_binds_empty_chapter_and_book`（预览空章节/书籍上下文）

### 版本与计划引用
- `CHANGELOG.md:6-10`（2.0.484：`@js:` 阅读正文与书源导入真实执行；chapter/book 绑定；出错/超时保留原文；引擎复用性能）
- `docs/REFACTORING_ACTIVE_PLAN.md:1229`（批15 范围与设备判据）
- `flutter_legado/pubspec.yaml:4`（`version: 2.0.484+485`）

### 结论边界（claim ceiling）
- 本轮未在设备上重跑 cargo / flutter 测试，仅引用仓库既有单测与修复路径；未验证无 quickjs 构建的降级口径（本项目发布矩阵待确认）。
- 设备为 MuMu x86_64，未覆盖 armv7/arm64 真机与“无 quickjs”构建；`@js:` 在书源导入 `applyReplaceRulesToSource` 路径的设备行为不在本清单内，未取证。
- 预览页的 chapter/book 绑定为空上下文属设计行为，C6 结论仅来自生产正文。
