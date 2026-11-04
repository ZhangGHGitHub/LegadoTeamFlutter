# 批4a「九宫格点击区域」设备验收报告

- 日期：2026-11-04
- 验收角色：QA（设备验收，只测不改代码）
- 代码基线：`c6bc2ba3fe chore: 批4a 收尾（2.0.452+453 双日志与计划登记）`
- 应用版本：2.0.452+453
- APK SHA-256：`4a179ee41901fe24a14a2963654f2606e25ca8485c44d5faf67e153c23d4b9e7`
- 证据目录：`docs/materials_1104e/`（77 个文件，约 15 MB）

## 一、环境与构建

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`（探测有效），Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi（360x640dp），display id 0 |
| 版本 | 仓库 `c6bc2ba3fe`，设备 `versionCode=453 / versionName=2.0.452` |
| 构建 | `flutter build apk --release` 退出码 0，Gradle 78.0s，APK 201,288,600 bytes |
| Rust | 无 Rust 改动，未重建（复用既有 .so） |
| 测试数据 | 书架为空；push UTF-8 TXT 后应用内导入 |

## 二、总体结论

- 验收项 17 项（A1-A3、B1-B3、C1-C4、D1-D3、E1-E3）：**PASS 16 / FAIL 0 / BLOCKED 1 子项**（B2 有会话朗读暂停/继续，设备无 TTS 引擎）。
- **P1=0；P2=0；P3=4 项观察/文档问题**。
- 全程 `FATAL EXCEPTION / ANR / E flutter / RenderFlex overflow` 均为 0。

## 三、逐项结果

### A 入口与默认

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 | PASS | `A1_read_config_page_control.png`、`A1_more_sheet.png` | 独立阅读设置页「页面控制」有「点击区域设置」入口；阅读器「更多」页仅单行入口，无左/中/右三行下拉（语义树仅 `点击区域设置\n9 个区域（3×3 九宫格）`） |
| A2 | PASS | `A2_grid_default.png` + 语义树 | 标题正确、9 格齐全；默认 TL/TC/ML/BL=上一页、TR/MR/BR=下一页、MC=菜单、BC=下一页 |
| A3 | PASS（备注） | `A3_action_options*.png`、`A3_grid_after_change.png` | 点格弹动作单选，实际 15 项：无操作/菜单/下一页/上一页/下一章/上一章/朗读上一段/朗读下一段/添加书签/编辑内容/替换开关/目录/全文搜索/同步阅读进度/朗读暂停继续（任务书“14 项”为计数笔误）；选中「目录」后网格即时更新并落盘 |

### B 九区分发

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| B1 | PASS | `B_config_grid.png`、`B1_*.png`、`B1_boundary_*.png` | 9 区设可观察动作后，每区在 1/6、1/2、5/6 各点一次：TL 翻页、TC 目录、TR 翻页、ML 上一章、MC 菜单显隐、MR 下一章、BL 全文搜索、BC 添加书签、BR 无操作。边界 x=355/365、715/725，y=635/645、1275/1285 全部正确。BC 第 3 次被 SnackBar 覆盖属正常覆盖，等待后复测通过 |
| B2 | PASS（空闲）/ BLOCKED（会话） | `B2_MC_idle_*.png` | MC=朗读暂停继续：空闲态 3 处点击无状态变化、无朗读条/TTS 启动。设备无 TTS 引擎（`tts_default_synth=null`），有会话暂停/继续无法构造，标 BLOCKED |
| B3 | PASS | `B3_edit_dialog.png`、`B3_toggle_replace.png`、`B3_sync_progress.png` | TL=编辑弹「编辑：第二章 山路」；TC=替换提示「已关闭替换规则」；TR=同步提示「请先配置 WebDAV」；关闭后阅读正常 |

### C 菜单与长按互斥

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| C1 | PASS | `C1_topbar_blank_after.png`、`C1_body_blank_after.png`、`C1_bottombar_blank_after.png` | 菜单展开后点顶栏空白/正文空白/底栏空白均只收起菜单，章节/页码不变 |
| C2 | PASS | `C2_settings_open.png` + 语义 MENU | 菜单展开点底栏「设置」正常打开设置，关闭后菜单仍展开 |
| C3 | PASS | `C3_longpress.png`、`C3_longpress.xml`、`C3_quicktap_menu.png` | 正文长按 600ms 弹选词浮条，不翻页/不弹目录；随后快速点击 MC 正常开菜单 |
| C4 | PASS（跳过） | 阅读设置页 | 默认「边缘点击阈值」=0，无死区，按验收单说明跳过 |

### D 迁移与持久化

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| D1 | PASS | `D1_backup.json`、`D1_grid_all_next.png`、`D1_grid_after_restore.png`、`D1_behavior_after_restore_edit.png` | 备份 JSON 含 9 个 `clickAction*` 键（TL=8/TC=9/TR=12/ML=4/MC=0/MR=3/BL=11/BC=7/BR=-1）；改全下一页→备份→恢复，网格与点击行为恢复 |
| D2 | PASS（按真实旧版编码） | `D2_backup.json`、`D2b_legacy_correct.json`、`D2b_migrated_result.json`、`D2_once_only_result.json` | 旧 Flutter 版存的是 `TapAction.index`（none=0/prev=1/next=2/toggle=3/openCatalog=4），故真实旧向量 1/3/2 → 左列 2、中列 0、右列 1；任务书 2/0/1 向量与旧编码不符（按该值映射结果为左1/中-1/右2，非缺陷）。迁移只一次：改 MC=目录后重启不被覆盖 |
| D3 | PASS | `D3_restart_MC_catalog.png` | 杀进程重启后 9 区配置保持，MC=目录仍生效 |

### E 回归与稳定性

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| E1 | PASS | `E1_swipe*.png`、`E1_toc_jump.png`、`E1_search.png` | 横滑翻页、点击翻页、目录跳章、全文搜索、菜单显隐、添加书签均正常 |
| E2 | PASS | `E2_landscape.png`、`E2_landscape_MC_toc.png`、`E2_portrait_restored.png` | 横屏 1920x1080：右中下一页、左中上一页、中中目录、上中菜单；x=630/650 边界正确；已恢复竖屏 |
| E3 | PASS | `logcat_4a_full.txt`（14,928 行） | FATAL=0、ANR=0、E flutter=0、RenderFlex overflow=0；dropbox 无 v453 crash/ANR（仅历史 2.0.434/436）；进程存活 |

## 四、问题清单

- **P1：无。**
- **P2：无。**
- **P3（观察/文档，不阻塞）：**
  1. 任务书 A3 写「14 项」，实际代码与列举清单为 15 项（-1..13），建议更正。
  2. 任务书 D2 注入向量 2/0/1 与旧版实际存储编码不符；真实旧向量为 1/3/2（prev/toggle/next）→ 左2/中0/右1。
  3. C3 选词浮条存在时按系统返回键会退出阅读器而非只关浮条；建议后续确认返回键优先级。
  4. 备份恢复后本地书文件缺失时阅读页裸露 Rust `IO error: No such file or directory`；建议改为「文件不存在，请重新导入」类提示。

## 五、设备终态

- 默认九宫格恢复并截图（`E4_terminal_default_grid.png`）：TL/TC=上一页、TR=下一页、ML=上一页、MC=菜单、MR=下一页、BL=上一页、BC=下一页、BR=下一页。
- 测试书删除、书架为空（`E4_terminal_bookshelf.png`）；`/sdcard/Download/` 测试文件与 `qa_backup/` 已清理。
- `font_scale=1.0`；竖屏（`user_rotation=0`，`accelerometer_rotation=0`）；`wm size=1080x1920`、`wm density=480`。
- 应用数据 `pm clear`，当前为 2.0.452+453 全新状态，应用仍安装可启动。
- 未修改 `flutter_legado/lib` 或产品代码；测试脚本在 gitignore 的 `tmp_qa_4a/`。

---

编写：QA 子代理 ｜ 2026-11-04
