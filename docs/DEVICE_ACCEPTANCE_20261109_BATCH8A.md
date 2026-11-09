# 批8a「备份忽略 + 仅保留最新本地备份」设备验收报告

- 日期：2026-11-09
- 验收角色：主代理
- 代码基线：`5d062b1238`（含审查/设备回修）
- 应用版本：2.0.474+475
- APK SHA-256：`7fc3736ac44ceeefc0c45a50509e241aef040d71da907751f235ec8b5e46c1bd`
- 证据：`docs/materials_1109g/`（22 个文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 2.0.474（versionCode 475） |
| Rust | 沿用 2.0.471 的 release+quickjs `.so`（本批未改 Rust） |
| 测试 | 本地 TXT `batch7b_notes`；备份路径 `/storage/emulated/0/Download/legado`；备份忽略勾选「阅读界面配置」「本地书籍」 |

## 二、总体结论

- 功能验收 8 项：**PASS 8 / BLOCKED 0**；审查 1 P1 + 1 P2 已回修；设备复核再发现 1 P2（设备级键随备份）已回修并重建复验。
- FATAL/ANR/E.flutter/overflow/E AndroidRuntime 均为 **0**（15,129 行 logcat）。
- 设备终态：`pm clear` 空书架，默认设置。

## 三、逐项结果

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 备份忽略入口 | PASS | `tmp_qa8a_05.png` | 「恢复忽略列表」下有独立「备份忽略列表」，未设置时副标题「未设置」 |
| A2 备份忽略对话框 | PASS | `tmp_qa8a_06.png` | 标题「备份忽略」、副题为备份专属文案；8 项（含本地书籍）；可滚动 |
| A3 保存与计数 | PASS | `tmp_qa8a_07.png` | 勾选「阅读界面配置」「本地书籍」→ 确定；副标题「已勾选 2 项」+ toast「已保存备份忽略项」 |
| A4 仅保留最新本地备份 | PASS | `tmp_qa8a_11.png`、`tmp_qa8a_12.png`、`tmp_qa8a_15.png` | 开关默认开；连续备份后目录仅保留本次 `legado_backup_1794209333421.json`；非匹配旧文件 `legado_backup_verify2.json` 保留 |
| B1 备份忽略「阅读界面配置」生效 | PASS | `tmp_qa8a_backup2.json` | `appPrefs` 为空，不含 `reader_font_size`/`themeMode` 等 |
| B2 备份忽略「本地书籍」生效 | PASS | `tmp_qa8a_backup2.json` | `books` 为空（原书架有 1 本本地 TXT） |
| B3 设备级键排除 | PASS | `tmp_qa8a_backup2.json` | `app_backup_path`、`remote_servers_migrated`、`backupIgnore` 均不在 appPrefs |
| C1 稳定性/清理 | PASS | `logcat_8a.txt`、`tmp_qa8a_17.png` | 五项崩溃计数 0；`pm clear` 空书架 |

## 四、审查与回修

### P1-1 尾分隔符目录误删本次备份（回修）

- 根因：按绝对路径字符串比较当前备份；`dirPath` 末尾带分隔符（如盘符根 `E:\`）时 `currentPath` 出现双分隔符，与 `Directory.list()` 路径不等，本次文件也被删，仍报成功。
- 回修 `3bb24df443`：改为按文件名比较（`uri.pathSegments.last`）；清理正则收紧 `^legado_backup_\d+\.json$`；补尾分隔符回归用例（修复前失败）。

### P2-1 备份忽略「本地书籍」无消费方（回修）

- 回修 `3bb24df443`：备份+注入 appPrefs 后、上传前按 `backupIgnore['localBook']` 过滤 `books`（判定与恢复侧同规则）；临时文件+rename 原子写回；失败 fail-closed（删除未过滤文件并中止备份）。设备 B2 验证 `books` 为空。

### 设备复核新增 P2（已回修）

- 首次设备备份的 `appPrefs` 携带 `app_backup_path`（设备绝对路径）与 `remote_servers_migrated`（设备迁移标记）。
- 回修 `5d062b1238`：`app_backup_path` 入 `alwaysIgnoreKeys`（备份/恢复均排除）；`remote_servers_migrated` 入 `backupExcludedKeys`（仅新备份不写，旧备份仍可恢复）。重建后设备复验 `appPrefs` 为空（B3 PASS）。

### 同批 P3（已关闭）

- 恢复忽略默认副标题改为「恢复时跳过对应项；备份忽略请单独设置」。
- `saveBackupIgnoreConfig` 返回 bool，保存失败不提示已保存、不更新计数。
- `onlyLatestBackup` 开关写入显式 `unawaited` 并注明尽力语义。
- 测试中 `/tmp` 路径改 `tempDir.path`，避免 POSIX 真删。
- 契约 `appPrefs` 口径改为备份侧 `backupIgnore`/恢复侧 `restoreIgnore`。
- 补上传失败仍清理、360dp+2.0 字体、保存失败 UI 用例。

## 五、P3 / 未覆盖

1. `autoCheckNewBackup` 仍未消费（启动检查+提示另批）。
2. 备份/恢复三选 Sheet 未做；当前仍是「备份=本地+WebDAV、恢复=短按同步/长按本地」。
3. 备份忽略仅配置组；数据库表级忽略（bookmark/bookSource 等）需 Rust 支持，未做。
4. 设备未验证「仅保留最新」关闭态（单测覆盖保留全部）。
5. 设备未验证上传失败仍清理旧备份（单测覆盖）。
6. 自动备份入口复用 `createBackup`，清理/过滤自动生效，但无独立入口用例。

## 六、设备终态

- 应用 2.0.474+475 已安装，`pm clear` 后空书架、默认设置、可启动。
- 测试备份文件保留在 `/sdcard/Download/legado` 供复验。

## 七、门禁（代码基线）

- flutter analyze 0；flutter test **5110 通过 + 1 skipped**；本批 format 0 changed。
- 未改 Rust/FFI；契约计数不变。
- 审查 needs changes（1 P1+1 P2）→ 回修；设备复核新增 P2 → 回修并重建复验。

---

编写：ZCode 主代理 ｜ 2026-11-09
