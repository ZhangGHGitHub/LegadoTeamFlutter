# 批12 替换规则排序与作用域写链路 — 设备验收报告

验收日期：2026-11-10
验收类型：MuMu 测试机真机运行时验收（只做验证与取证，未修改仓库代码）
证据目录：`D:/OH-WorkSpace/LegadoTeam/legado/docs/materials_1110c/`

## 一、验收环境

| 项目 | 值 |
| --- | --- |
| 设备 | MuMu「Test测试」，`192.168.100.62:5555`，`adb devices` 状态 `device` |
| 机型 / 系统 | SM-G9900（`ro.product.device=r9q`，MuMu 模拟），Android 15（API 35），构建 `V417IR release-keys` |
| 分辨率 / 密度 | 1080x1920，480dpi |
| 被测包 | `io.legado.flutter_legado` |
| APK 路径 | `D:/OH-WorkSpace/LegadoTeam/legado/flutter_legado/build/app/outputs/flutter-apk/app-release.apk` |
| APK 大小 / 构建时间 | 210,457,092 字节 / 2026-11-10 14:02 |
| APK sha256 | `454aa3d2aa8739bb0e42ebbd00ac3eb4e4e247875b7f8b544f700d4b50596e79`（与任务给定前缀 `454aa3d2…` 一致） |
| 设备实测版本（dumpsys） | `versionName=2.0.481`，`versionCode=482`，`lastUpdateTime=2026-11-10 14:02:47` |
| 声明目标版本 | `2.0.481+482`（`flutter_legado/pubspec.yaml` 第 4 行）——与设备一致 |
| 测试数据 | 规则 A/B/C（a→x、b→y、c→z）与 R1/R2（X→Y、Y→Z）；本地书 `qa_b12.txt`（70B，`/sdcard/Download/qa_b12.txt`，已导入书架） |

版本说明：本批 APK 与设备安装版本、`pubspec.yaml` 三者一致，未发现上一批的版本漂移问题。

## 二、总体结论

| 结果 | 数量 |
| --- | --- |
| PASS | 11 |
| FAIL | 0 |
| BLOCKED | 0 |
| 合计 | 11 |

结论：批12「替换规则排序与作用域写链路」在设备上主路径全部通过。排序在返回重进与 force-stop 冷启动后均持久化；置顶/置底（批量）行为及其相对顺序正确并持久化；筛选态正确禁用拖拽并给出提示；规则「特定范围/作用范围」修改保存后重新打开与冷启动均保留；排序变更可观察到净化结果的差异（R1→R2 得 Z，R2→R1 得 Y）。未发现 FATAL EXCEPTION、ANR、E/flutter、布局溢出或 E AndroidRuntime。存在 2 项低等级观察（见第四节），均不构成功能失败。

## 三、逐项结果

| 项 | 结果 | 证据文件（`docs/materials_1110c/`） | 说明 |
| --- | --- | --- | --- |
| A1 进入替换规则列表并准备 ≥3 条规则 | PASS | `tmp_qb12_03.png`、`tmp_qb12_10_initial_order.png` | 初始列表为空，按清单新建 A/B/C 三条（pattern `a`/`b`/`c`，正则开启，正文范围），列表初始顺序 A→B→C |
| A2 拖动第 3 条到第 1 位 | PASS | `tmp_qb12_10_initial_order.png`、`tmp_qb12_11_after_drag.png` | 从 C 行拖拽手柄（`=`）上拖，顺序变为 C→A→B，拖动即时生效 |
| A3 返回上一页再进入，顺序保持 | PASS | `tmp_qb12_12_reenter_order.png` | 返回「我的」后重新进入，顺序仍为 C→A→B |
| A4 force-stop 冷启动后顺序保持（本批核心） | PASS | `tmp_qb12_13_coldstart_home.png`、`tmp_qb12_14_coldstart_order.png` | `am force-stop` 后冷启动，再进入列表，顺序仍为 C→A→B |
| B5 第 2 条置底并持久化 | PASS | `tmp_qb12_15_row_menu.png`、`tmp_qb12_16_batch_mode.png`、`tmp_qb12_17_selected_A.png`、`tmp_qb12_18_batch_menu.png`、`tmp_qb12_19_after_bottom.png`、`tmp_qb12_20_bottom_persist.png` | 行内 `⋮` 仅有「删除」，置底由批量菜单完成：选中当前第 2 条 A → 置底 → 顺序 C→B→A；返回重进后仍为 C→B→A |
| B6 多选 2 条置顶并持久化 | PASS | `tmp_qb12_21_multi_selected.png`、`tmp_qb12_22_menu2.png`、`tmp_qb12_23_after_top.png`、`tmp_qb12_24_top_persist.png` | 批量选中 B、A（第二条、第三条）→ 置顶 → 顺序 B→A→C，两条相对顺序保持（B 在 A 前）；返回重进后仍为 B→A→C |
| C7 筛选态禁用拖动并提示 | PASS | `tmp_qb12_25_search_open.png`、`tmp_qb12_26_search_open2.png`、`tmp_qb12_27_filtered.png`、`tmp_qb12_28_filter_cleared.png`、`tmp_qb12_29_after_back.png`、`tmp_qb12_30_try_clear.png`、`tmp_qb12_32_reenter_filter.png` | 搜索/筛选关键字 `B` 后列表仅剩 B，出现提示「筛选/搜索状态下暂不支持拖拽排序」，拖拽手柄由深色变浅灰（禁用态）；退出重进后筛选清除、恢复完整列表 |
| D8 作用域写链路（保存并重开） | PASS | `tmp_qb12_33_edit_A_before.png`、`tmp_qb12_34_edit_scrolled.png`、`tmp_qb12_35_edit_modified.png`、`tmp_qb12_36_edit_scopes.png`、`tmp_qb12_37_after_save_scope.png`、`tmp_qb12_38_reopen_A.png`、`tmp_qb12_39_reopen_A_scrolled.png` | 编辑 A：作用范围由仅「正文」改为「标题+书源+正文」，并在「特定范围」填入 `chapter`；保存后列表行显示红色「范围: chapter」；重新打开该规则，三个范围按钮均为选中态且「特定范围」仍为 `chapter`；随后冷启动（`tmp_qb12_67_final_coldstart_order.png`）该行仍显示「范围: chapter」 |
| E9 排序影响净化顺序（已构造） | PASS | `tmp_qb12_49_imported.png`、`tmp_qb12_50_book_baseline.png`、`tmp_qb12_53_rules_before_R12.png`、`tmp_qb12_54_R1_filled.png`、`tmp_qb12_55_R2_filled.png`、`tmp_qb12_57_order_R1_R2.png`、`tmp_qb12_60_rules_list5.png`、`tmp_qb12_64_R2_topped.png`、`tmp_qb12_65_order_R2_R1.png` | 导入本地书 `qa_b12.txt`（正文含 3 处 `X`）；新建 R1 `X→Y`、R2 `Y→Z`（均为正文、正则）。顺序 R1→R2 时正文渲染为「这是 Z 测试文本，Z 应该被替换。」；将 R2 批量置顶为 R2→R1 后，正文渲染为「这是 Y 测试文本，Y 应该被替换。」——净化结果随规则顺序变化，链式替换生效 |
| F10 logcat 崩溃/异常统计 | PASS | `logcat_b12.txt`（16,552 行）、`logcat_b12_clean.txt`（414 行） | 全量日志与「清空日志→force-stop→冷启动→进入替换列表」干净日志中，`FATAL EXCEPTION`、`ANR in`、`E/flutter`、`overflowed`、`E AndroidRuntime` 五项计数均为 0 |
| F11 清理与终态 | PASS | `tmp_qb12_68_terminal.png` | `adb shell pm clear io.legado.flutter_legado` 返回 `Success`；应用进程退出，`topResumedActivity=com.microsoft.launcher/.Launcher`；终端截图显示桌面 |

## 四、发现的问题（分级）

### 问题 1（低，待人工复测）：5 条规则列表上 adb 手势拖拽两次未触发重排
- 现象：在 5 条规则（B/A/C/R1/R2）列表中，从 R2 拖拽手柄向上拖动（一次拖到 R1 上方、一次拖到列表顶部）均未发生重排（`tmp_qb12_61_R2_before_R1.png`、`tmp_qb12_62_R2_top.png` 顺序仍为 B→A→C→R1→R2）；而 3 条列表时同样的 `adb input swipe` 一次成功（`tmp_qb12_11_after_drag.png`）。
- 影响：无法判定是代码缺陷（如长列表拖拽判定/手势阈值）还是 adb 合成手势在 Flutter 拖拽手柄上的注入限制；本次改用批量「置顶」完成顺序变更并继续完成 E 项，不影响 E 项结论。
- 建议：真机手指长按拖拽复测 5 条及以上列表；若可复现，检查拖拽手柄 `ReorderableDragStartListener` 命中区域与长列表滚动手势竞争。
- 证据：`tmp_qb12_61_R2_before_R1.png`、`tmp_qb12_62_R2_top.png`、`tmp_qb12_11_after_drag.png`、`tmp_qb12_64_R2_topped.png`。

### 问题 2（低，观察）：搜索/筛选入口未见可见输入框，清除入口不明显
- 现象：点击工具栏放大镜后直接通过 `adb input text` 输入 `B` 即可生效（列表仅剩 B 并显示筛选提示），但截图中未见可见的搜索输入框；再次点击放大镜仅出现锚点气泡（`tmp_qb12_28_filter_cleared.png`），筛选状态仍在，直至返回上一页再进入才清除（`tmp_qb12_32_reenter_filter.png`）。
- 影响：筛选功能本身可用（C7 通过），但输入与清除的可发现性存疑；也可能与 adb 文本注入路径/截图时机有关。
- 建议：人工复测搜索框展开、关键字清除按钮与返回键行为，确认是否存在渲染或状态残留问题。
- 证据：`tmp_qb12_25_search_open.png`、`tmp_qb12_26_search_open2.png`、`tmp_qb12_27_filtered.png`、`tmp_qb12_28_filter_cleared.png`、`tmp_qb12_32_reenter_filter.png`。

### 问题 3（观察，非缺陷）：列表以红色展示「范围: chapter」
- 现象：保存特定范围后，列表 A 行以红色文字显示「范围: chapter」（`tmp_qb12_37_after_save_scope.png`、`tmp_qb12_67_final_coldstart_order.png`）。
- 影响：不影响保存、重开与冷启动持久化的结论；红色是否为有意的高亮/告警语义需产品确认。
- 建议：与设计稿核对颜色语义，避免被误读为校验错误。

### 补充观察（非缺陷）
- 行内 `⋮` 菜单仅有「删除」；置顶/置底位于批量选择模式的 `⋮` 菜单（启用选中/禁用选中/置顶/置底/导出选中），与清单「行内菜单或批量按钮」的描述一致。
- 规则编辑页在「正文」范围外新增「特定范围」「排除范围」「超时时间」「预览输入/输出」等字段，本次仅验证作用范围与特定范围的写链路。
- 导入本地书时系统 SAF 默认停留在上次目录 `Download/legado_b11`，需手动切到 `Download` 根目录选择文件，属系统行为。

## 五、设备终态

| 项目 | 状态 |
| --- | --- |
| 应用数据 | 已 `pm clear io.legado.flutter_legado` 清理（返回 `Success`） |
| 应用进程 | 已停止；当前前台为 `com.microsoft.launcher/.Launcher`（桌面），见 `tmp_qb12_68_terminal.png` |
| 安装包 | 仍安装 `io.legado.flutter_legado` 2.0.481（482），未卸载、未降级 |
| 测试残留 | 设备 `/sdcard/Download/qa_b12.txt`（70 字节，`pm clear` 不会删除）；应用内规则/书架数据已随 `pm clear` 清除 |
| 设备连接 | `adb devices` 仍显示 `192.168.100.62:5555 device` |
| 证据 | `docs/materials_1110c/`：68 张截图（`tmp_qb12_*.png`）、`logcat_b12.txt`、`logcat_b12_clean.txt` |

## 六、门禁引用

- 本次为设备运行时验收，输入为 release APK；**未执行** `dart analyze` / `flutter test` / 构建门禁（不在本任务范围），因此不声明静态分析、单元测试或构建门禁通过。
- 构建溯源已核对：`pubspec.yaml` 声明 `2.0.481+482`，APK sha256 `454aa3d2aa8739bb0e42ebbd00ac3eb4e4e247875b7f8b544f700d4b50596e79`，设备 `dumpsys` 显示 `versionName=2.0.481 / versionCode=482` 且 `lastUpdateTime` 与 APK 构建时间（2026-11-10 14:02）一致，被测对象可追溯。
- 运行时证据按「验证反馈回路与证据固化」要求留存：逐项截图 + 全量/干净 logcat 稳定性统计 + `pm clear` 终态截图。
- 未验证或无法插桩的项：本次清单 11 项均有设备截图或日志证据，PASS/FAIL/BLOCKED 计数中无 BLOCKED；问题 1、问题 2 的具体代码归因需人工复测后确认，未据此声明缺陷成立。

## 七、复现命令（关键步骤）

```bash
export PATH="$PATH:/d/Program Files/MuMuPlayer/nx_main"
export MSYS_NO_PATHCONV=1

adb devices -l
adb shell dumpsys package io.legado.flutter_legado | grep -E "versionName|versionCode|lastUpdateTime"
adb shell am start -n io.legado.flutter_legado/io.legado.flutter.MainActivity
adb exec-out screencap -p > docs/materials_1110c/tmp_qb12_XX.png

# 排序持久化核心验证
adb shell am force-stop io.legado.flutter_legado
adb shell am start -n io.legado.flutter_legado/io.legado.flutter.MainActivity
# 进入 我的 → 替换净化 截图核对顺序

# 稳定性统计
adb logcat -d > docs/materials_1110c/logcat_b12.txt
grep -c -E "FATAL EXCEPTION|ANR in|E/flutter|overflowed|E AndroidRuntime" docs/materials_1110c/logcat_b12.txt

# 清理
adb shell pm clear io.legado.flutter_legado
adb exec-out screencap -p > docs/materials_1110c/tmp_qb12_68_terminal.png
```

— QA 子代理 ｜ 2026-11-10

## 九、5 条规则拖拽复验（调试子代理，2026-11-10）

### 9.1 复验目标与方法

目标：判定第四节「问题 1」（5 条规则列表上 adb 拖拽未触发重排）是重排代码缺陷还是 adb 合成手势限制。只做验证与取证，未修改代码。

环境：MuMu `192.168.100.62:5555`，1080x1920 / density 480，`io.legado.flutter_legado` 2.0.481（482）。复验前 `pm clear`，从空列表新建 5 条规则 A/B/C/D/E（pattern `a`/`b`/`c`/`d`/`e`，正则 + 正文范围），列表初始顺序 A→B→C→D→E（`tmp_qb12_recheck_01_launch.png` 至 `tmp_qb12_recheck_06_rules5.png`）。

### 9.2 手势复验结果（5 条列表，均从第 5 条拖到第 1 位）

| 序号 | 操作 | 结果 | 证据 |
| --- | --- | --- | --- |
| 1 | `input swipe 103 1289 103 250 1500`（起点按行高估算，未对准手柄中心） | 未重排。拖动过程中列表内容上移约 240px 后回弹，无卡片抬升/阴影，表现为滚动手势而非拖拽 | `tmp_qb12_recheck_07_mid_drag1500.png`、`tmp_qb12_recheck_08_after_drag1500.png` |
| 2 | `input swipe 99 1344 99 300 1500`（手柄几何中心） | 成功。拖动中 E 卡片抬升（阴影可见）并位于 A 之上；松手后顺序 E→A→B→C→D | `tmp_qb12_recheck_09_mid_drag_exact.png`、`tmp_qb12_recheck_10_after_drag_exact.png` |
| 3 | `input motionevent DOWN/MOVE/UP`（21 步 MOVE、每步 80ms，坐标同上） | 成功。顺序 D→E→A→B→C | `tmp_qb12_recheck_12_mid_motionevent.png`、`tmp_qb12_recheck_13_after_motionevent.png` |
| 4 | `input touchscreen swipe 99 1344 99 300 2500`（2500ms 长拖） | 成功。拖动中 C 卡片抬升；松手后顺序 C→D→E→A→B | `tmp_qb12_recheck_14_mid_swipe2500.png`、`tmp_qb12_recheck_15_after_swipe2500.png` |
| 5 | 返回「我的」再进入替换净化 | 顺序保持 C→D→E→A→B | `tmp_qb12_recheck_11_reenter_order.png` |
| 6 | `am force-stop` 冷启动 → 我的 → 替换净化 | 顺序保持 C→D→E→A→B（三次重排均已持久化） | `tmp_qb12_recheck_16_coldstart_home.png`、`tmp_qb12_recheck_17_coldstart_order.png` |

说明：三次连续拖拽（第 5 条→第 1 位）均由不同注入方式触发成功，未出现「第一次成功、后续失败」。拖动中的卡片抬升/阴影在 09、12、14 中均可见。

### 9.3 命中区域测量

- 列表行高 240px，行范围 A[264,504]、B[504,744]、C[744,984]、D[984,1224]、E[1224,1464]；手柄图标绘制像素中心 y=1344。
- 代码中 `ReorderableDragStartListener` 只包住裸 `Icon`（默认 24dp），无额外 Padding/SizedBox（`flutter_legado/lib/src/screens/replace_rules_screen.dart:841-847`）→ 命中盒为 24dp×24dp；density 480 时为 72px×72px（y 约 1308–1380）。
- 失败的起点 y=1289 位于命中盒上方约 19px（≈6.3dp）；该次手势被列表滚动接管（09 中可见明确抬升，07 中无）。

### 9.4 代码路径核对（3 条 vs 5 条）

- 非批量、非筛选态统一走 `ReorderableListView.builder`（`flutter_legado/lib/src/screens/replace_rules_screen.dart:329`），`itemCount: rules.length`，无规则数量阈值或分支。
- `onReorderItem`（同文件 334-338）→ `ReplaceRuleNotifier.reorder`（`flutter_legado/lib/src/providers/replace_rule/replace_rule_notifier.dart:117-139`）→ 全量落库 `_commitOrder`（同文件 158-169）。3 条与 5 条无代码路径差异。
- 拖拽只能由手柄触发：整行 `InkWell` 的 `onTap` 进入编辑、`onLongPress` 进入批量（`replace_rules_screen.dart:827-830`），在行体上拖动只会滚动列表。因此手势起点偏离手柄时表现为滚动，而非重排逻辑失败。

### 9.5 判定

判定：**adb 合成手势限制（起点落点精度不足），非重排代码缺陷**。

依据：

1. 同一版本、同一 5 条列表，起点对准手柄几何中心后，`input swipe`、`input motionevent`、`input touchscreen swipe` 三种注入方式连续三次均成功重排，并在返回重进与 force-stop 冷启动后持久化。
2. 3 条与 5 条共用同一 `ReorderableListView.builder` 代码路径，无数量相关分支，不存在「长列表拖拽判定」差异。
3. 原失败可稳定复现为「起点偏离 24dp 手柄命中盒 → 列表滚动、无卡片抬升」，而不是「拖拽高亮已出现但落点未识别」（成功拖拽的中途截图均有明确卡片抬升/阴影）。
4. logcat 过滤 `Reorderable|replace_rule|E/flutter|overflow|FATAL EXCEPTION|ANR in|E AndroidRuntime` 为 0 行（`tmp_qb12_recheck_logcat_filtered.txt`）；窗口内 Fatal signal 均为 adb `input` 辅助进程 `app_process`（uid 2000，Shutdown thread）退出时崩溃，与应用进程无关。

结论：第四节「问题 1」不构成重排功能缺陷，可从缺陷清单降级为测试方法注记；拖拽排序功能无需修改代码。

### 9.6 附带发现（低优先级 UI 改进，非本次失败根因）

拖拽手柄命中区域仅 24dp×24dp（裸 `Icon`），低于 Material 建议的 48dp 最小触控目标；真实手指操作时容错较小，容易误触发列表滚动。建议（如需派发）：在 `replace_rules_screen.dart:841-847` 为手柄增加透明命中层（例如 `Container(width: 48, height: 48, color: Colors.transparent)` 等等价的 opaque hit-test 容器）并居中图标；拖拽逻辑本身无需改动。本次未改代码。

### 9.7 复验后设备终态

- `adb shell pm clear io.legado.flutter_legado` 返回 `Success`；前台回到 `com.microsoft.launcher/.Launcher`（`tmp_qb12_recheck_18_terminal.png`）。
- 证据：`docs/materials_1110c/tmp_qb12_recheck_01..18*.png`、`tmp_qb12_recheck_logcat_full.txt`、`tmp_qb12_recheck_logcat_filtered.txt`。
- 未执行静态分析、单元测试或构建门禁（本次仅设备复验，未改代码）。

— 调试子代理 ｜ 2026-11-10

## 十、手柄触控区扩大后复验（ZCode 全栈工程师子代理，2026-11-10）

### 10.1 被测对象与设备

| 项目 | 值 |
| --- | --- |
| APK | `flutter_legado/build/app/outputs/flutter-apk/app-release.apk`，sha256 `4fe1aebef2c48a427a8fdb003db1038e392ff212cbe1c60e8d91551f24d26014`，210,457,092 字节，构建时间 2026-11-10 14:36 |
| 设备安装版本 | `versionName=2.0.481`、`versionCode=482`、`lastUpdateTime=2026-11-10 14:37:17`（`dumpsys package`） |
| 设备 / 屏幕 | MuMu `192.168.100.62:5555`，1080×1920，density 480（3.0×，1dp=3px） |
| 被测提交 | `79a2e255ff`（手柄改为 48×48 `SizedBox` + `Center(24dp Icon)`，`ReorderableDragStartListener` 包住该盒子，新增 `Semantics(label: '拖动排序')`） |

### 10.2 复验结果

| 项 | 结果 | 证据（`docs/materials_1110c/`） | 说明 |
| --- | --- | --- | --- |
| G1 安装与版本核对 | PASS | `tmp_qb12_handle_01_launch.png` | `adb install -r` 返回 Success；设备版本 2.0.481/482，`lastUpdateTime` 与新 APK 构建时间（14:36）一致 |
| G2 新建 5 条规则 A/B/C/D/E | PASS | `tmp_qb12_handle_08_rules_cleared.png` 至 `tmp_qb12_handle_10_rules5_initial.png` | 清空数据后逐条新建（pattern `a`…`e`，正则+正文），初始顺序 A→B→C→D→E；`uiautomator dump` 确认每行高 240px、行带 [264,504]/[504,744]/[744,984]/[984,1224]/[1224,1464]，手柄图标中心 x=143.5、行中心 y=384/624/864/1104/1344 |
| G3 第 5 条拖到第 1 位 | PASS | `tmp_qb12_handle_10_rules5_initial.png`、`tmp_qb12_handle_11_after_drag.png` | 起点取 E 手柄图标内 (140,1315)，上拖至 (140,375)，1500ms；松手后顺序 E→A→B→C→D，拖拽中卡片抬升可见 |
| G4 返回重进持久化 | PASS | `tmp_qb12_handle_12_reenter_order.png` | 返回「我的」再进替换净化，顺序仍 E→A→B→C→D |
| G5 force-stop 冷启动持久化 | PASS | `tmp_qb12_handle_13_coldstart_home.png`、`tmp_qb12_handle_14_coldstart_order.png` | `am force-stop` 后冷启动再进列表，顺序仍 E→A→B→C→D |
| G6 拖拽方向与重复性 | PASS | `tmp_qb12_handle_18_E_to_top.png`、`tmp_qb12_handle_19_upward_again.png`、`tmp_qb12_handle_20_mid_down_drag.png`、`tmp_qb12_handle_21_after_down_drag.png` | 手柄图标盒内起点连续多次成功：D 上拖置顶、C 上拖置顶、C 下拖置底（中途卡片跟随手指，见 `_20_mid_down_drag.png`）；向上/向下均可重排 |
| G7 「48dp 命中区」实测 | **FAIL** | `tmp_qb12_handle_15_mid_drag_offset.png`、`tmp_qb12_handle_16_after_offset_drag.png`、`tmp_qb12_handle_17_exact_center_drag.png`、`tmp_qb12_handle_22_offset_inside48.png`、`tmp_qb12_handle_23_x200_outside_icon.png`、`tmp_qb12_handle_24_x175_inside_icon.png` | 起点在 48dp 盒内、24dp 图标盒外时不触发拖拽，列表被滚动接管：(140,905)、(96,864)、(90,1284)、(200,1344) 失败；(175,1344)（图标盒内）成功。实际命中区仍为 24dp 图标盒（72×72px） |
| G8 单条对照（命中区归因） | **FAIL** | `tmp_qb12_handle_28_onerule.png`、`tmp_qb12_handle_29_mid_x200.png`、`tmp_qb12_handle_30_mid_x175.png` | 单条规则下 (200,384) 中途卡片不跟手（overscroll），(175,384) 卡片抬升并随手指下移；两条路径同屏对照，确认为命中区问题而非重排逻辑 |
| G9 logcat 崩溃/异常统计 | PASS | `logcat_b12_handle.txt`（5,611 行） | `FATAL EXCEPTION`、`ANR in`、`E/flutter`、`overflowed`、`E AndroidRuntime` 五项计数均为 0 |
| G10 清理与终态 | PASS | `tmp_qb12_handle_32_terminal.png`（首轮清理见 `_25_terminal.png`） | `pm clear` 返回 Success；前台回到 `com.microsoft.launcher/.Launcher`；应用仍安装 2.0.481/482 |

统计：PASS 8、FAIL 2（G7/G8 为同一缺陷的两项取证）、BLOCKED 0。

### 10.3 判定与根因

判定：**拖拽排序功能与持久化 PASS；「24dp→48dp 命中区」未生效，实际命中区仍为 24dp 图标盒（P3，非阻断）**。

依据（像素测量 + 起点对照，全部同一版本、同一列表）：

- 手柄图标 24dp 盒：x 107.5–179.5，各行 y 中心 ±36px；新 48dp 盒：x 71.5–215.5，y 中心 ±72px。
- 成功起点 (140,1315)、(144,1344)、(144,384)、(175,1344) 全部落在 24dp 图标盒内；失败起点 (96,864)、(140,905)、(90,1284)、(200,1344) 全部落在 48dp 盒内、24dp 图标盒外，均表现为列表滚动/overscroll。
- 单条规则对照排除了「多条列表手势竞争」与「重排落库失败」：x=200 时卡片不跟手，x=175 时卡片抬升并跟随手指。

根因：`_buildDragHandleIcon` 使用 `SizedBox(width: 48, height: 48) + Center(Icon)`，`SizedBox`/`Center` 均无绘制、也不在命中测试中自报命中；`ReorderableDragStartListener` 内部 `Listener` 默认 `HitTestBehavior.deferToChild`，因此只有中间的 24dp `Icon` 进入命中路径，透明外圈不接收 pointer down。现有 widget 测试只断言手柄 `size == 48×48`，未覆盖命中行为，故测试与设备表现不一致。

建议（另立 UI 修复，本次按任务要求未改代码）：命中层改为可命中的透明绘制/opaque 容器，例如 `Container(width: 48, height: 48, color: Colors.transparent)`、`ColoredBox(color: Colors.transparent)` 或 `Listener(behavior: HitTestBehavior.opaque)`；并补一条命中测试（在图标盒外、48dp 盒内按下应触发重排）。修复后需重建 APK 并复验 G7/G8。

### 10.4 结论

- 被测 APK sha256 `4fe1aebef2c48a427a8fdb003db1038e392ff212cbe1c60e8d91551f24d26014`，版本 2.0.481/482，与 `pubspec.yaml` 一致。
- 5 条规则「第 5 条拖到第 1 位」在返回重进与 force-stop 冷启动后均持久化，拖拽排序功能本身可用。
- 48dp 触控目标未达成，实际命中区仍为 24dp；`79a2e255ff` 的标题描述与设备实测不符，记为 P3 待修。
- 五项崩溃计数 0，`pm clear` 终态干净，无测试残留（应用数据已清除）。

— ZCode 全栈工程师子代理 ｜ 2026-11-10
