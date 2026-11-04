# 批4b「自定义翻页键 + 长按泛化」设备验收报告

- 日期：2026-11-04
- 验收角色：QA（设备验收，只测不改代码）
- 首轮基线：2.0.453+454（`f6d7fab26a`）→ **FAIL（P1）**
- 复验基线：2.0.454+455（`e6aeeb5865` + 版本/日志改动）
- 复验 APK SHA-256：`1aea2a850a70da8da437d58aefb0f299d194b56583b1136db46fab5244982d91`
- 证据：`docs/materials_1104f/`（首轮 212 文件）、`docs/materials_1104g/`（复验 112 文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 首轮 2.0.453+454；复验 2.0.454+455（`versionCode=455`） |
| Rust | 无改动，未重建（`.so` 仍为 2026-11-03 22:33） |
| 测试数据 | UTF-8 TXT 20 章 + 最小 CBZ（3 页）用于漫画音量键回归 |

## 二、总体结论

- 首轮 16 项：PASS 14 / FAIL 2 / BLOCKED 1 子项；**P1=1**（PageUp/PageDown/DPad 在设置页录制与阅读器内均无响应；FlutterView 在 `Activity.onKeyDown` 之前消费）。
- 回修后复验 9/9 指定项 PASS，**P1 关闭**；合并判定：**PASS 16 / FAIL 0 / BLOCKED 1 子项**（朗读中音量键翻页，设备无 TTS），P1=0、P2=0、P3=2。
- FATAL/ANR/E.flutter/overflow/READER_KEYS_ERROR 均为 0。

## 三、首轮结果（2.0.453+454）

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 设置页录制 | **FAIL** | `A1_sheet_open.png`、`A1_recheck_92/24.png`、`A1_probe_62/19/93.png` | 92/93/19 无 chip；24/62 正常；删除/清空可用 |
| A2 BACK/DEL/长按去重 | PASS | `A2_after_del67.png`、`A2_longpress25_once.png`、`A2_after_back4.xml` | DEL 不追加、BACK 关闭、长按只 1 chip |
| A3 持久化 | PASS（备注） | `A3_after_confirm.png`、`A3_reopen_chips.png`、`A3_after_restart_persist.png` | 以 24/62 验证确定/取消/重开/重启 |
| A4 大字体滚动 | PASS | `A4_narrow_bigfont_settings.png`、`A4_sheet_narrow_bigfont.png`、`A4_sheet_scrolled.png` | 720x1280 + 1.6 倍可滚动、按钮可达、0 overflow |
| B1 阅读器按键 | **FAIL** | `B1b_reader_before_dpad.png`、`B1b_dpad_19/20/21/22.png` | 92/93/62 正常；19-22 全部无响应 |
| B2 长按 | PASS | `B2b_longpress93_off/on.png`、`B2_hold62_on_2000ms.png` | 关=1 页；开=2 页并跨章（工具仅 1 次 repeat） |
| B3 自定义优先 | PASS | `B3_custom24_pages_volOff.png`、`B3_vol25_system_volOff.png`、`D1_vol24_prev.png` | 24 自定义且音量关→翻页；25 调音量；清空后音量开→24/25 方向正确 |
| B4 菜单交还 | PASS | `B4_menu_after_93.png`、`B4_restored_93.png` | 24/25 系统音量 8→9→8、93 不翻页；收起恢复 |
| B5 子路由 | PASS | `B5_catalog_open.png`、`B5_catalog_after_keys.png`、`B5_restored_key2.png` | 目录下按键无效果；返回恢复 |
| C1 漫画音量键 | PASS | `C1_text_volume_off.png`、`C1_manga_25_1/2.png`、`C1_manga_24_1.png` | 文本音量关→CBZ 24/25 连续翻页、无音量条 |
| C2 残留自定义 | PASS | `C2_custom_set`、`C2_manga_open.png`、`C2_manga_24_prev.png` | 文本残留 24=下一页→漫画 24 仍上一页、25 下一页 |
| D1 原音量回归 | PASS（1 子项 BLOCKED） | `D1_vol_before.png`、`D1_longpress_on_persist.png` | 方向/开关/长按正常；朗读中音量键翻页无 TTS 无法验证 |
| D2 回归 | PASS | `D2_search_open.png`、`D2_exit_reader.png`、`A2_after_back4` | 翻页/目录/搜索/退出正常；BACK 不被吞 |
| D3 稳定性 | PASS | `logcat_batch4b_raw.txt` 等 | FATAL=0、ANR=0、E/flutter=0、overflow=0、READER_KEYS_ERROR=0 |
| E1 备份 | PASS | `E1_backup.json`、`E1_after_restore_state.png` | 含 prevKeyCodes=24/nextKeyCodes=62，恢复生效 |
| E2 清理 | PASS | `E2_default_config.png`、`E2_final_shelf2.png` | 自定义清空、音量开/长按关、书与 cbz 删除、书架空 |

### P1 根因（首轮）

`MainActivity` 仅重写 `onKeyDown`；FlutterView 在 `dispatchKeyEvent` 阶段先消费 PAGE_UP/PAGE_DOWN（ScrollIntent）与 DPad（DirectionalFocus），Activity.onKeyDown 不被调用 → 设置页录制无 chip、阅读器 DPad 不翻页；24/62 因未被 Flutter 消费而正常。

### 回修

`79cb442902`（`ReaderKeysBridge.handleKeyEvent`：DOWN 命中记录、UP 成对吞掉、BACK/DEL 透传；`MainActivity.dispatchKeyEvent` 唯一入口；`resetLegacyState`/`resetPageKeyConfig`；录制 repeat 只记首次）、`43680ec9e4`（租约清空清 `keyRecording`）、`289b6535e7`/`e6aeeb5865`（JVM + Dart 回归）。

## 四、复验结果（2.0.454+455，9/9 PASS）

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 录制 | PASS | `R_A1_after92.png`、`R_A1_all5.png`、`R_A1_delete92.png`、`R_A1_clear.png` | 92/93/19/62/24 均出现 chip；删除/清空；BACK 不追加；长按 93/25 各 1 chip |
| A3 持久化 | PASS | `R_A3_confirmed.png`、`R_A3_reopen.xml`、`R_A3_after_cancel.xml`、`R_A3_after_restart.png` | 92/93 确定落盘、取消不改、重开回显、重启保持 |
| B1 阅读器 | PASS | `R_B1_footer_contact.png` + 各键 `R_B1_*_1/2.png` | 序列：93→2/6→3/6；92→2/6→1/6；62→2/6→3/6；19→2/6→1/6；20→2/6→3/6；21→2/6→1/6；22→2/6→3/6，全部单步 |
| B2 长按 | PASS | `R_B2_off_footer.png`、`R_B2_on3_footer.png` | 关=3/6→4/6；开=6/6→第2章2/6（跨章 2 页） |
| B4 菜单 | PASS | `R_B4_menu_after_keys.png`、`R_B4_restored_93.png` | 24/25 音量 7→8→7；92/93 页码 2/6 不动；收起后 93→3/6 |
| B5 子路由 | PASS | `R_B5_catalog_open.png`、`R_B5_catalog_after_keys.png`、`R_B5_restored_93b.png` | 目录下无效果；返回 3/6→93→4/6 |
| C1/C2 漫画 | PASS | `R_C_manga_contact.png`、`R_C_manga_25_1/2.png`、`R_C_manga_24.png` | 文本音量关 + 残留 24→CBZ 24/25 仍音量翻页 1/3→2/3→3/3→2/3，音量 7、无音量条 |
| D3 稳定性 | PASS | `logcat_batch4b_reverify.txt`、`logcat_batch4b_reverify_final.txt` | FATAL=0、ANR=0、E/flutter=0、overflow=0、READER_KEYS_ERROR=0；BACK 从漫画/目录不被吞 |
| E2 清理 | PASS | `R_E_default_config.png`、`R_E_shelf_empty.png` | 自定义清空、音量开/朗读中关/长按关、TXT+CBZ 删除、font_scale 1.0、竖屏、书架空 |

## 五、问题清单

- **P1：0（首轮 P1-1 关闭）。**
- **P2：0。**
- **P3：**
  1. 「更多」页语义树中「自定义翻页键」与「按键长按翻页」bounds 重叠（无障碍/自动化定位受影响）。
  2. 书架「删除源文件」对 SAF 导入原件的行为未单独判定（首轮观察到原件留存，已 adb 清理）。
  3. `input keyevent --duration` 不产生无限自动 repeat，长按连续翻页只能验证到 2 页/跨章。
  4. 朗读中音量键翻页（volumeKeyPageOnPlay）因设备无 TTS 服务 BLOCKED。
  5. 遗留（非本轮）：备份路径仍为 `/storage/emulated/0/Download/legado_backup`；阅读器搜索历史保留测试词。

## 六、设备终态

- 应用 2.0.454+455 已安装，书架空；TXT/CBZ 已删除。
- 自定义翻页键未设置；音量键翻页开、朗读中关、长按关。
- `font_scale=1.0`、1080x1920/480dpi、竖屏。
- 未修改 lib/Android/Rust 源码。

---

编写：QA 子代理 ｜ 2026-11-04
