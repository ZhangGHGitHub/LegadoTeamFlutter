# 批5b 设备验收报告：朗读内容划分与段落间隔

- 验收日期：2026-11-05
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`
- 代码基线：`35a12562a8985f2e31a1a80a836270a23a3cddae`（chore: 批5b 收尾（2.0.460+461 双日志与计划登记））
- 版本：pubspec `2.0.460+461` → 设备 `versionName=2.0.460` / `versionCode=461`
- 证据目录：`docs/materials_1105c/`
- 验收角色：设备验收代理（只测不改代码，未修改 `lib/`/`rust/` 任何文件）

## 一、环境

| 项 | 值 |
|---|---|
| 设备 | MuMu「Test测试」实例 index 1，`adb -s 192.168.100.62:5555`（状态 `device`） |
| 系统 | Android 15（`ro.build.version.release=15`），机型伪装 SM-G9900 |
| 屏幕 | 1080x1920，density 480，`SurfaceOrientation: 0`（竖屏） |
| 显示 | 应用位于主 display，单屏操作，未使用 `-d` |
| TTS 引擎 | **无**：`settings get secure tts_default_synth` = `null`；`pm list packages | grep -iE 'tts|speech'` 无结果 |
| 构建 | `cd flutter_legado && flutter build apk --release`（无 Rust 改动，未重建 .so），Gradle `assembleRelease` 114.7s，产物 192.6MB |
| 安装 | `adb install -r build/app/outputs/flutter-apk/app-release.apk` → Success（`lastUpdateTime=2026-11-05 21:21:16`） |
| 测试书 | A 空行分段 3 段；B 单换行 5 行；C 单段 10 句（句号 3、感叹 2、问号 2、逗号 2）；补充 D 含 URL+JSON 广告文本（E1）；补充 E 两章长/短章（C1 切章回退）。均为 UTF-8 无 BOM，push 到 `/sdcard/Download/` 后经「添加本地」导入 |
| 朗读模式 | 无 TTS 引擎，全部走估算推进（`text.length / 5` 秒，最小 0.8s）；以朗读条「段 x/y」、`media_session`、通知、截图判定，不要求出声 |

### APK 指纹

```
sha256  f3c0b62aa6ccbeb3a6d8402a3ac806455539a816132f5136bcf5b5805d66b665
path    flutter_legado/build/app/outputs/flutter-apk/app-release.apk
size    201,928,992 bytes (2026-11-05 21:19)
```

## 二、逐项结果

结论口径：PASS=实测符合；FAIL=实测不符且可复现；BLOCKED=设备能力缺失无法验证（附证据）。

### A. 设置页

| 项 | 结果 | 证据 |
|---|---|---|
| A1 常规页有「内容分析」组：章节分片方式（规则可选，规则+AI/AI 理解置灰）、推理级别置灰、内容划分方式（默认/整段/整页/按符号）、段落间隔 0–5000ms | **PASS** | `04_content_analysis_header.png`（内容分析组）、`05_chapter_split_dialog.png`（规则选中；规则+AI/AI 理解显示「暂未支持」灰色）、`06_disabled_ai_noop.png`（点击两个置灰项无选中变化、弹窗保持）、`03_content_analysis.png`（推理级别置灰「关闭」）、`07_content_split_dialog.png`（4 种划分方式）、`12_interval_max_5000.png`（滑块右端 5000 ms） |
| A2 按符号展开 14 个标点 chip，可多选；取消到最后一个不可再取消；不选标点时回显句末四标点 | **PASS** | `08_symbols_chips_14.png`（14 chip：`。！？…；，、：.!?;,:`，默认四枚句末选中）、`09_symbols_2_selected.png`（多选后剩 2）、`10_symbols_1_selected.png`（剩 1）、`11_last_chip_toast.png`（再点最后一个弹「至少保留一个标点」，选中数不变）、`46_final_symbols_empty_fallback.png`（重置后空存储 → 回显 。！？… 四枚 + 提示「未选择时按句末标点 。！？… 划分」） |
| A3 整段/整页时标点 chips 隐藏；模式/标点/间隔重启保持；备份 JSON 含三项 | **PASS** | 整段/整页选中后 chips 不渲染（`44_mode_paragraph.png`、`23_mode_page.png`）；`13_persist_after_restart.png`（force-stop 重启后仍「按符号 / 1 个标点 / 2000 ms」）；`backup_20261105_2130.json` 的 `appPrefs`：`readAloudContentSplitMode='symbols'`、`readAloudContentSplitSymbols=['。']`（数组）、`ttsParagraphInterval=2000` |

A3 键名说明：实际存储键为 `readAloudContentSplitMode` / `readAloudContentSplitSymbols`（带 `readAloud` 前缀，与既有朗读偏好命名一致），验收要求中的 `contentSplitMode/contentSplitSymbols` 按语义对应；标点以数组形态落盘，读取侧兼容历史 String 与数组两种形态。

### B. 切段正确性（无 TTS 引擎，估算模式）

| 项 | 结果 | 证据 |
|---|---|---|
| B1 A 空行分段书（3 段）：总段数=3，逐段推进 | **PASS** | `14_A_default_seg1of3.png`（`段1/3`）、`15_A_default_seg3of3_reader_menu.png`（推进到 `段3/3`，随后会话自然结束） |
| B2 B 单换行 5 行书：总段数=5（回归不得为 1），逐段推进；从第 3 行起读应从第 3 段开始 | **PASS** | `16_B_total5.png`（`段2/5`，总段数 5）、`17_B_selection_start_seg3of5.png`（长按第 3 行 → 菜单「朗读」，起读后立即显示 `段3/5`） |
| B3 C 单段 10 句：按符号选「。」段数=3+1=4；加「，」段数增加；清空标点不允许 | **PASS** | `18_C_period_only_seg1of4.png`（仅 。 → `段1/4`，3 个句号 + 尾段）、`19_C_period_comma_seg1of6.png`（。+， → `段1/6`，3+2 个符号 + 尾段）；清空被拒绝：`11_last_chip_toast.png`（至少保留一个标点）；空存储回退句末见 `46_final_symbols_empty_fallback.png`（未构造段数：无书状态下未复测段数，回退规则由实现与设置页提示共同证明） |
| B4 内容划分=整段/默认：A=3、B=5、C=1 | **PASS** | 整段：`21_A_paragraph_seg1of3.png`（1/3）、`22_B_paragraph_seg1of5.png`（1/5）、`20_C_paragraph_seg1of1.png`（1/1）；默认：`14_A_default_seg1of3.png`（1/3）、`16_B_total5.png`（2/5，总 5） |

补充：A/B/C 三本书的章节均只有 1 章，默认/整段行为一致（`default` 运行时归一为 `paragraph`），已分别实测，非推断。

### C. 整页模式

| 项 | 结果 | 证据 |
|---|---|---|
| C1 整页：A 书分页到第 3 页 → 总段数≈当前章页数、首段对应当前页；切章后回退整段 | **PASS** | A 书字号调至 50 后共 4 页：`24_A_page3of4.png`（页脚 3/4）、`25_A_page_mode_seg3of4.png`（起读即 `段3/4`，总段数=4=页数）；补充长书 E 第 1 章 24 页：`26_E_page_mode_seg3of24.png`（页脚 3/24 起读，`段3/24`）；`27_E_ch2_fallback_seg1of3.png`（点「下一章」后「第二章 短章 2/2 · 段1/3」，页模式回退为整段的 3 段） |

说明：A 书默认字号仅 1 页，无法构造「第 3 页」；为满足验收项，临时把阅读器字号调到 50（默认 20），得到 4 页后再验；验收后已通过清除应用数据恢复默认字号。E 书为补充夹具（2 章），用于验证「切章回退整段」；其第 1 章 24 页、第 2 章 3 段，回退差异明确。

### D. 段落间隔

| 项 | 结果 | 证据 |
|---|---|---|
| D1 间隔 0 vs 2000ms：估算推进间隔明显变长；切段/停止不被延迟卡住；暂停后恢复从下一段（不重播上一段） | **PASS** | `29_poll_interval0.txt`：B 书 5 段，`interval=0` 时 t=2.4 段2、t=5.6 段4、t=8.8 会话结束（总≈8.8s）；`30_poll_interval2000.txt`：同书同设置下 t=4.4 段2、t=9.0 段3、t=11.7 段4、t=16.8 结束（总≈16.8s）；差值 8.0s ≈ 4 个段间 × 2s。暂停/恢复（A 书，段1 估算 7.0s）：`32_pause_in_gap.png`（t=7.9s 暂停仍 `段1/3`）、`33_pause_3s_still_seg1.png`（暂停 3s 后仍 `1/3`，间隔定时器未推进）、`34_resume_next_seg2.png`（恢复立即 `段2/3`，未重播段1）；`35_next_segment_immediate.png`（间隔期间点「下一段」立即 `段3/3`）、`36_stop_immediate.png` + `media_session STOPPED(1)`（停止即时生效） |

方法说明：UI 的段计数只出现在根节点 `content-desc`（`·段x/y`），通过 `uiautomator dump` 轮询读取；轮询本身约 0.9–1.5s/次，因此单次跳变可能跨过一段，但总时长与 4×2s 的理论差吻合，且暂停/恢复的关键段位由截图直接证明。

### E. 回归与稳定性

| 项 | 结果 | 证据 |
|---|---|---|
| E1 替换/净化仍生效；翻页/目录/书签/退出正常；FATAL/ANR/E.flutter/overflow=0 | **PASS** | 新建 2 条正则替换规则（URL 句、JSON 句，作用域「正文」）：D 书正文显示仅剩「这是净化测试正文第一句。这是第三句正文。」（`37_D_purified_reader.png`），朗读总段数由原始 4 段变为 `段1/2`（`38_D_readaloud_seg1of2.png`），证明替换链同样作用于朗读正文；目录页正常（`39_toc_open.png`）；长按菜单「书签」提示「已添加书签」（`40_bookmark_added_toast.png`）；翻页已在 C1/A 书实测（页 1→2→3）；退出阅读器多次正常。`logcat_full_20261105.txt`（18,560 行）四类关键字计数 **0/0/0/0**；`logcat_crash_20261105.txt` 186 条崩溃记录 **全部为 `uiautomator`**（工具自身段错误，按约定不计入应用） |
| E2 阅读器退出停止朗读（5a-1 修复）不回归：默认 keep=false 退出后 STOPPED | **PASS** | `41_E2_playing_before_exit.png`（面板「正在朗读」）、退出前 `media_session state=PLAYING(3)` + `NotificationRecord id=7776`；系统返回键退出后 2s：`42_E2_after_exit.png`、`state=STOPPED(1)`、无通知记录；20s 后 `43_E2_after_20s.png` 仍 `STOPPED(1)`、无通知记录 |

### F. 清理

| 项 | 结果 | 证据 |
|---|---|---|
| F1 恢复默认（内容划分=默认、标点=空/句末、间隔=0、章节分片=规则、推理 OFF）、删除测试书、font_scale 1.0、1080x1920/480、竖屏、空书架 | **PASS** | 通过 `pm clear io.legado.flutter_legado` 重置应用数据后复核：`45_final_readaloud_defaults.png`（章节分片=规则、推理级别=关闭、内容划分=默认、段落间隔=0 ms）、`46_final_symbols_empty_fallback.png`（空存储回显句末四标点）、`44_final_shelf_empty.png`（空书架）；三个开关 `朗读唤醒锁/退出阅读时继续朗读/媒体键翻章` 均 `checked=false`；`wm size` 1080x1920、`wm density` 480、`SurfaceOrientation: 0`；`字体大小=跟随系统`（`107_appearance.png`），`app_font_scale` 未写入=默认 1.0；设备端测试书 A–E、本次备份 JSON、临时 xml 已删除，`/sdcard/Download/legado_backup/` 仅保留会话前 `legado_backup_1793873079273.json` |

清理方式说明：应用未提供「朗读内容分析恢复默认」的细粒度入口，且标点 chip 强制至少保留 1 个，无法通过 UI 把标点存储清空；故最终采用 `pm clear` 重置应用数据（同时完成删除 5 本测试书、删除临时替换规则、复位所有偏好）。该操作会清除本机此前批次遗留的测试书签/高亮/阅读记录等 QA 数据，属测试实例数据，不影响源码仓库。

## 三、缺陷与风险

本次未发现 P1/P2 级缺陷。

### P3 观察项

1. **朗读面板播放/暂停按钮无可访问语义**：`uiautomator` 语义树中朗读条只有「上一段 / 下一段 / 停止朗读 / 定时停止 / 收起朗读面板 / 选择朗读引擎」等按钮，中央播放/暂停按钮没有 `content-desc`（截图可见图标）。影响无障碍与自动化定位；本次暂停测试只能按坐标点击（首次按错坐标导致误判，纠正后才得到有效结论）。建议补语义标签。
2. **超大字下分页断行过碎**：字号 50 时 A 书单章被切成 4 页，页内出现「这是A / 第二段第一 / 。」这类逐字/断词分页；整页模式按页切段时首段会是跨行残句。该行为来自既有分页算法，非本批引入；默认字号（20）下 A 书为 1 页，影响有限。建议后续单独评估分页断行质量。
3. **备份键名与验收口径的命名差异**：实际键为 `readAloudContentSplitMode/readAloudContentSplitSymbols`，与任务书的 `contentSplitMode/contentSplitSymbols` 前缀不同；语义一致，已按实际键验收，建议在计划/契约中统一记录，避免后续按错键名核对。

## 四、BLOCKED 清单

| 项 | 原因 | 证据 |
|---|---|---|
| 朗读真实出声、音色、音调/音量实际效果 | MuMu 无任何 TTS 引擎：`settings get secure tts_default_synth=null`，`pm list packages` 无 tts/speech 包；朗读按估算节奏推进 | `02_readaloud_top.png` 等面板均显示「未配置可用朗读引擎，将按估算节奏朗读」 |
| 真实音频驱动的段完成/段间隔（非估算路径） | 无引擎，无法产生音频完成回调；本报告间隔数据均来自估算路径 | `29/30_poll_*.txt` |
| 按符号「清空到空集」后的段数回退 | 实现禁止清空（至少保留一个），UI 无法构造空集；空存储回退句末仅通过重置后默认态验证了回显与规则提示 | `11_last_chip_toast.png`、`46_final_symbols_empty_fallback.png` |

## 五、FATAL / 稳定性统计

- `logcat_full_20261105.txt`（18,560 行，threadtime）：`FATAL EXCEPTION` / `ANR in io.legado` / `E/flutter` / `A RenderFlex overflowed` 关键字计数 **0 / 0 / 0 / 0**。
- `logcat_crash_20261105.txt`：崩溃记录 186 条，`Cmdline:` 统计 **全部为 `uiautomator`**（工具自身退出段错误，按项目约定不计入应用缺陷）。
- `logcat_after_cleanup_20261105.txt`：清理后复核四类关键字同样 **0/0/0/0**。
- 全程 `topResumedActivity` 为本应用；无应用被杀/重启（`pm clear` 为验收主动操作）。

## 六、设备终态

| 项 | 终态 |
|---|---|
| 书架 | 空（`44_final_shelf_empty.png`，空态文案「书架还空着…」） |
| 朗读设置 | 章节分片=规则、推理级别=关闭、内容划分=默认、标点存储=空（回显句末 。！？…）、段落间隔=0 ms；朗读唤醒锁/退出继续朗读/媒体键翻章均关 |
| 朗读会话 | 无：`media_session` 无 PlaybackState，通知记录 0 |
| 字体缩放 | `app_font_scale` 默认 1.0（应用数据已重置；外观「字体大小=跟随系统」） |
| 屏幕 | 1080x1920 / 480dpi / 竖屏（rotation 0） |
| 设备端文件 | 测试书 A–E、本次备份 JSON、临时 xml 已删除；`/sdcard/Download/` 仅保留会话前既有文件（如 `qa_b2c_book_a/b.txt`、`legado_backup_1793873079273.json`） |
| 应用版本 | 2.0.460 / 461（安装于 2026-11-05 21:21） |

## 七、结论汇总

- **PASS**：A1、A2、A3、B1、B2、B3、B4、C1、D1、E1、E2、F1
- **FAIL**：无
- **BLOCKED**：真实出声/音色/音调音量、真实音频驱动的段完成与间隔（MuMu 无 TTS 引擎）；按符号清空到空集的段数回退（实现禁止清空）
- **P1/P2**：无；P3 三项（朗读面板播放/暂停无语义、超大字分页断行过碎、备份键名前缀差异）
- **建议**：批5b 设备验收可放行；P3 建议后续按需修复/记录

---

编写者：设备验收代理 ｜ 2026-11-05
