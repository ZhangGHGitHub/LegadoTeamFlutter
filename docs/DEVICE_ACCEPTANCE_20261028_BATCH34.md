# 批 34 设备验收报告（高亮规则正文渲染 MVP）

> 范围：批 34（Rust `highlightRuleMatch` 规则正文匹配、Dart `HighlightMatchSync`
> 接线与 `Text.rich` span 渲染、超时中止与失败退避、36 例单测/组件测试）。
> 设备：MuMu「Test测试」实例（guest 直连 `192.168.100.62:5555`，实测在线，adbd root）。
>
> **结论**：场景 1~8 全部 **PASS**。未发现功能缺陷；2 项渲染/方言差异（下划线
> color=0 回退色、`\w` Unicode 语义）与 1 项可观测性缺口（Rust 日志未接
> logcat）记录在 §四。

## 一、环境与产物

| 项 | 值 |
|---|---|
| 设备端点 | `192.168.100.62:5555`（MuMu 实例「Test测试」，`adb devices` 实测 `device`） |
| 设备型号 / 系统 / ABI | SM_G9900（MuMu 伪装）/ Android 15 / `x86_64` |
| 分辨率 / 密度 | 1080x1920 / 480dpi |
| adb | `D:\Android\platform-tools\adb.exe`（adbd root，`uid=0`） |
| 应用包名 | `io.legado.flutter_legado` |
| 升级前版本 | versionName **2.0.408** / versionCode **409**（`dumpsys package`） |
| 验收版本 | versionName **2.0.411** / versionCode **412**（`dumpsys package` + APK badging） |
| 源码基线 | `master` HEAD `a4c420487f`（`chore: 批34 收尾（2.0.411+412 双日志与计划关闭登记）`） |
| 验收时间 | 2026-10-29 05:44 ~ 06:12（+08:00） |
| 证据目录 | `tmp_debug/device_acceptance_20261028_batch34/`（`tmp_debug/` 在 `.gitignore`，不入库） |

### 1.1 升级前备份

- 设备 DB（v116，299,008 字节）+ 偏好 XML 于安装前完整拉取：
  `db/legado_pre_upgrade_2.0.408.db`、`prefs/FlutterSharedPreferences_pre_upgrade.xml`。
- 备份后向库副本注入批 34 验收数据（`db/seed_batch34.db`，脚本 `seed_batch34.py`，
  输出 `db/seed_batch34_output.txt`）：1 本书（`QA批34高亮书`，6 章，含 1 章
  约 1MB 长章）、6 条 `cached_chapters` 正文、7 条高亮规则（基础/重叠高/重叠低/
  正则/空 pattern/非法正则/大小写，另保留既有 `QA26` 规则作干扰对照）。

### 1.2 Rust Android 构建

`pwsh.exe -NoProfile -ExecutionPolicy Bypass -File rust/scripts/build-android.ps1 -Mode release`
退出码 **0**；三个 ABI 的 `liblegado_ffi.so` 重新编译并复制到
`flutter_legado/android/app/src/main/jniLibs/`。日志：`logcat/rust_build_batch34.log`。

- **既有环境项（非本批引入）**：armv7 目标编译 `rar` 失败（`3 previous errors`），
  脚本按既有逻辑回退重试后成功；本机设备为 x86_64，不受影响。

### 1.3 Flutter 发布包

`cd flutter_legado && flutter build apk --release` 退出码 **0**，产物
`flutter_legado/build/app/outputs/flutter-apk/app-release.apk`
（197,175,936 字节 / 188.0 MB，sha1 `9db1888f6be5ae292bf8c6536006068dec88cb4b`），
`adb install -r` 成功（`logcat/install_batch34.log`）。
日志：`logcat/flutter_build_batch34.log`、`logcat/apk_sha1.txt`。

- APK badging / 设备 `dumpsys` 均实测 `versionName=2.0.411`、`versionCode=412`。
- 升级后 DB `PRAGMA user_version` 保持 **116**（本批无 schema 变更）；注入数据行数
  完整（books=1、highlightRules=8、cached_chapters=6）。

## 二、验收场景结果表

| # | 场景 | 结果 | 关键证据 |
|---|---|---|---|
| 1 | 基础渲染（文本色/背景/下划线命中渲染，像素取色） | **PASS** | `shots/02`、`shots/03`、`db/` 像素统计（本报告 §3.1） |
| 2 | 分页不变（启用/禁用规则前后页数、首尾文字、行几何） | **PASS** | `shots/06`、`shots/09`、`db/scene2_pagination_compare.txt` |
| 3 | 开关：禁用消失 / 重新启用恢复 / 改色生效 | **PASS** | `shots/08~13`、`db/scene3_*.txt` |
| 4 | 重叠优先级（sortOrder 高者覆盖，低者差集保留） | **PASS** | `shots/14`、`14b/14c`、`db/scene4_overlap_rules_enabled.txt` |
| 5 | 正则/大小写/空 pattern/非法正则 | **PASS** | `shots/15`、`db/scene5_rules_enabled.txt` |
| 6 | 长章（约 1MB）打开/翻页性能；滚动模式不触发高亮 | **PASS** | `shots/16~19`、`shots/22~23`、`db/scene6_*.txt` |
| 7 | 回归（普通阅读/字号/边距/目录/主题）+ FATAL/ANR | **PASS** | `shots/24~35`、`logcat/logcat_full_session.log`、`logcat/fatal_anr_counts.txt` |
| 8 | 清理（恢复 DB/偏好、移除测试数据与设备临时文件） | **PASS** | `db/scene8_cleanup_db_counts.txt`、`shots/36` |

## 三、逐场景说明

### 场景 1：基础渲染 — PASS

规则 `QA34基础规则`（`关键词测试`，isEnabled=1，applyToBody=1，sortOrder=10）样式
`{"fill":4294967040(黄),"textColor":4294901760(红),"underline":{"kind":"SOLID","width":1.5}}`。

- 打开第 1 章（`shots/02_ch1_basic_render.png`）：两处「关键词测试」均呈现
  **黄色填充 + 红色文字 + 实线下划线**（`shots/03_zoom_keyword_yellow_red_underline.png`
  2 倍裁切目视；`shots/03b_zoom_keyword_second.png`）。
- 像素核对（1080x1920 原图）：`#FFFF00` 47,596 px（bbox 381,544-699,1268）、
  `#FF0000` 7,914 px（bbox 385,570-693,1248），命中区域与语义树中两处短语位置一致。
- 同页还叠出了正则规则（见场景 5）对「出现在这段话的中间位置」的橙色覆盖：
  order 10 的基础规则在重叠段胜出，恰好印证重叠裁剪。
- 页脚页码 `1/3 16.7%`，正文/标签/主题均正常。

### 场景 2：分页不变 — PASS

以第 2 章「分页对照」（9 页）为对象，在**规则全启用**与**规则全禁用**两态对照
（`shots/06_ch2_enabled.png` vs `shots/09_ch2_disabled.png`）：

- 语义树页脚均为 `1/9 33.3%`，页数 9 页不变（`db/scene2_pagination_compare.txt`）。
- 页面首行「分页对照专用章节：本段包含关键词测试…」、页尾第 06 段文本两态
  **完全相同**（语义树逐字比对 True）。
- 逐行几何：两态均检出 14 条字形行带，除命中行因**下划线多出 4 px**（626-629 行，
  属装饰绘制而非排版变化）外，行带上下沿逐行一致（≤1 px）。
- 页脚页码区逐像素 diff 最大 0；正文末行区逐像素 diff 最大 0。
- 结论：颜色/背景/下划线渲染不改度量，分页零变化。

### 场景 3：开关与改色 — PASS

1. **禁用全部 7 条 QA34 规则**（规则页开关逐个关闭，DB 快照
   `db/scene3_rules_all_disabled.txt`）→ 返回阅读器，第 2 章命中样式完全消失，页码
   仍为 `1/9 33.3%`（`shots/09_ch2_disabled.png`；页码区像素 diff 0）。
2. **仅重新启用基础规则**（`db/scene3_base_rule_enabled.txt`）→ 样式立即恢复
   （`shots/10_ch2_base_reenabled.png`），页码不变。
3. **修改颜色**：点规则行打开编辑面板（`shots/11_rule_edit_sheet.png`），选色板
   第 7 色块（`#F0C98D`）保存（`shots/12_swatch_selected.png`）。DB 实测
   `style = {"fill":4294967040,"textColor":4293970317,…,"underline":{…}}`
   （`db/scene3_style_after_color_change.txt`）——fill/underline 保真未丢；返回阅读器
   同章即生效（`shots/13_color_changed_reader.png`：黄色像素 24,569、琥珀文字
   `#F0C98D` 4,017 px、红字 0 px），页码仍 1/9。
- 说明：编辑表单只改 textColor（批 33 保真补丁保留 fill/underline），改色后
  下划线仍为实线。

### 场景 4：重叠优先级 — PASS

启用两条规则：`QA34重叠蓝(高)`（pattern `重叠`，sortOrder=30，蓝 `#2196F3`）与
`QA34重叠绿(低)`（pattern `重叠命中区域测试`，sortOrder=20，绿 `#4CAF50`），
DB 快照 `db/scene4_overlap_rules_enabled.txt`。第 3 章两处命中：

- 「重叠」两字被高 order 的**蓝色**覆盖；随后「命中区域测试」为低 order 的**绿色**
  （`shots/14_ch3_overlap.png`；`shots/14c_zoom_overlap_first.png` 目视）。
- 像素：蓝 28,450 px、绿 61,058 px；行带内蓝绿分界与「重叠/命中区域测试」字符边界
  对齐（`shots/14b_zoom_overlap_second.png` 两处均 2 蓝 + 1 绿接续到下行的绿色）。
- 语义与设计一致：高 sortOrder 先占位，低者按差集截断，无叠加混色。

### 场景 5：正则/大小写/空 pattern/非法正则 — PASS

启用 `QA34正则规则`（`关键词\w*`，isRegex=1，order=5，橙 `#FF9800`）、
`QA34空规则`（pattern 空）、`QA34非法正则`（pattern `(`）、
`QA34大小写规则`（`KeyWord`，紫 `#9C27B0`），DB 快照 `db/scene5_rules_enabled.txt`。
第 4 章（`shots/15_ch4_regex.png`）：

- 正则命中：「关键词甲」「关键词乙」「关键词丙…」均橙色；`\w*` 对连续汉字贪婪匹配，
  橙带一直延伸到标点前（如「关键词丙都应被正则规则命中」整段），**页面正常渲染**。
- 大小写：`KeyWord` 紫色命中；`keyword` 无样式（区分大小写）。
- 空 pattern / 非法正则：同章无任何紫色块、无崩溃、翻页/目录正常（页面内其余正文
  与标题正常显示）。
- **可观测性说明**：Rust `log::warn!`（无效正则/超时）在 Flutter 应用内**未接
  Android logger**，设备 logcat 无 `[highlight]` 文本（`logcat/logcat_highlight_warn.txt`
  为空），故以行为证据（无样式、无崩溃）判定；建议后续接 `android_logger`。

### 场景 6：长章性能与滚动模式 — PASS

第 5 章正文约 1,000,090 字节（约 34.3 万字符），分页 **2907 页**。

- **冷启动打开**（force-stop 后置 `durChapterIndex=4` 重启进入本书）：从点按书架到
  首帧含「长章第0001段」语义 2,613 ms（含 1MB 正文加载 + 2907 页分页；
  `db/scene6_cold_open_timing.txt`、`shots/18_ch5_cold_open.png`）。首屏「关键词测试」
  在冷启动首帧即已高亮，说明 ~1MB 文本的规则匹配在可接受时间内完成且未超
  1 MiB 上限。
- **翻页**：连续 5 次右翻全部成功（`shots/19_ch5_turn_1..5.png` 5 张画面互异），
  页码 1/2907 → 6/2907（语义树 5/6/7 为预载相邻页）；单次翻页首帧变化 ≤213 ms、
  动画收敛 ≤524 ms（`db/scene6_turn_latency.txt`，每次间隔约 145 ms 连拍比对）。
- **滚动模式**：设置「翻页动画 → 滚动」后回到第 5 章首段（`shots/23_scroll_mode_keyword_nohighlight.png`），
  同一「关键词测试」文本**无任何高亮**（黄色/琥珀/橙色像素均为 0），滑动流畅、
  无 ANR；与代码 `enabled = pageTurnMode != scroll` 的 MVP 边界一致。
- 全程无 FATAL/ANR（`logcat/fatal_anr_counts.txt`）。

### 场景 7：回归 — PASS

- 普通阅读：第 1/2/3/5/6 章打开、翻页、目录跳转均正常（`shots/05`、`14`、`15`、`18`）。
- 字号：设置面板 20 → 22（`shots/25_font_22.png` 面板显示 22）后正文行高变化
  （字形行带高 56→61 px，`shots/25b_font_22_reader.png`），再回 20 恢复；高亮随
  重新分页正确重绘。
- 边距：页面边距面板左边距 20→22（`shots/29_margin_sheet.png` →
  `shots/30_margin_changed_sheet.png`），正文可用宽由 60-1017 收窄为 66-1010
  （`shots/31_margin_changed_reader.png`），偏好落盘
  `reader_adv_margin_left/right=22.0`；不在本场景后立即还原（随场景 8 整体恢复）。
- 目录：目录页 6 章列表、当前章高亮、点击跳转正常（`shots/05_toc.png`）。
- 主题：绿色（`shots/32_theme_green.png`）、棕色（`shots/33b_theme_brown_reader.png`）、
  夜间（`shots/34_theme_dark_highlight.png`，黄底高亮在深色背景下仍正确）→ 恢复
  白色/日间（`shots/35b_reader_restored.png`）。
- **FATAL=0、ANR=0**：全流程主 logcat 9,255 行，`grep FATAL EXCEPTION|ANR in io.legado`
  命中 0（`logcat/logcat_full_session.log`、`logcat/fatal_anr_counts.txt`）；
  唯一一条 `InputDispatcher channel … Consumer closed` 发生在验收中主动
  force-stop（05:59:49），为预期行为。

### 场景 8：清理 — PASS

- 设备 DB 已从 `db/legado_pre_upgrade_2.0.408.db` 还原、偏好 XML 还原，并删除
  `-wal/-shm` 后重启应用：`books=0`、`highlightRules=1`（既有 `QA26`）、
  `chapters=0`、`cached_chapters=0`、`user_version=116`
  （`db/scene8_cleanup_db_counts.txt`）；书架为空态（`shots/36_cleanup_shelf_restored.png`）。
- 设备临时文件已删：`/data/local/tmp/seed_batch34.db`、`legado_pre_upgrade_batch34.db`、
  `restore_batch34.db`、`prefs_restore.xml`、`/sdcard/qa34_ui.xml`。
  `/data/local/tmp` 下仍有 `seed_book.sql`、`seed_sources.sql`、`seed_verify2.sql`
  三个 2026-10-27 的历史文件，非本次生成，未处置。
- 本地证据目录保留在 `tmp_debug/device_acceptance_20261028_batch34/`（`.gitignore` 内）。

## 四、发现、限制与观察

| 类型 | 项 | 说明 | 影响 |
|---|---|---|---|
| 渲染差异 | 下划线 `color=0` 回退色 | 命中行下划线实测 RGB(29,29,29)（正文基色），而非高亮 textColor（红/琥珀）。原版 `TextLine.drawHighlightRuns` 的 `fallbackColor = style.textColor.takeIf { it != 0 } ?: textColor` 会用高亮文字色。根因：Flutter `TextStyle.decorationColor` 为 null 时取「外层文本样式」颜色而非 span 自身 color（`highlight_span_builder.dart:129`） | 观感差异（线色），不改度量；建议后续把 `underline.color=0` 显式映射为 `style.textColor` |
| 正则方言 | `\w` 为 Unicode 语义 | Rust `regex` 的 `\w` 含 CJK，`关键词\w*` 命中「关键词甲」及整段连续汉字；Java 默认 `\w` 仅 ASCII。`adapt_java_regex` 未转换该语义 | 命中范围比原版大（视觉覆盖更多字），契约已登记「Java 正则方言差异」，此处补充设备实证 |
| 可观测性 | Rust 日志不进 logcat | `legado-ffi` 仅依赖 `log` crate，无 Android logger 初始化；非法正则/超时 warn 在设备不可见 | 不阻塞验收（行为正确），建议接线 `android_logger` 便于现场排障 |
| 已登记边界 | 滚动模式无高亮 | 代码 `enabled = pageTurnMode != scroll`，与 MVP 计划一致；本场景要求即「滚动模式不触发高亮」 | 符合预期 |
| 环境 | armv7 `rar` 编译失败 | 既有环境项，构建脚本自动回退，三 ABI 产物齐备；x86_64 设备不受影响 | 不阻塞 |
| 性能观察 | 1MB 章节分页 2907 页 | 冷启动首帧 2.6 s（含 1MB 匹配 + 分页），翻页首帧 ≤213 ms；建议后续以更大字号/边距组合再压测 | 不阻塞，登记备查 |
| 观察 | 验收中边距被改为 22 | 场景 7 修改后未即时还原，随场景 8 整体恢复偏好 | 已复原，无残留 |

未发现批 34 相关功能缺陷。

## 五、结论

批 34 设备验收 **通过**：高亮规则正文匹配与渲染在真机上按契约工作——文本色/背景/
下划线正确呈现且不改分页（页数、首尾文字、行几何、页码区像素均一致）；禁用/启用/
改色即时生效且 style 未编辑字段保真；重叠按 sortOrder 高者覆盖、低者差集保留；
正则、大小写、空 pattern、非法正则均稳定；约 1MB 长章冷启动 2.6 s、翻页流畅、
滚动模式按边界不渲染高亮；普通阅读/字号/边距/目录/主题回归正常，全程
FATAL/ANR 为 0。设备 DB 与偏好已恢复，测试数据与设备临时文件已清理；两项渲染/
方言差异与日志可观测性缺口已登记（§四）。

— QA（ZCode） 2026-10-29
