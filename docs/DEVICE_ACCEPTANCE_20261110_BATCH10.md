# 批10「autoCheckNewBackup 启动检查与提示」设备验收报告

- 日期：2026-11-10
- 验收角色：主代理
- 代码基线：`d652506784`（含审查回修与设备缺陷回修）
- 应用版本：2.0.479+480
- APK SHA-256：`27638f7f491fe0f7d9b3e1e51d67ce8fd40b3a7abb8c90adcfd0788fc7bd0d4a`
- 证据：`docs/materials_1110a/`（42 个文件）

## 一、环境

| 项 | 值 |
|---|---|
| 模拟器 | MuMu「Test测试」`192.168.100.62:5555`，Android 15 |
| 分辨率/密度 | 1080x1920 / 480dpi |
| 版本 | 2.0.479（versionCode 480） |
| Rust | 本批未改 Rust/FFI/契约，沿用 2.0.478 的 `.so` |
| WebDAV | 宿主 `wsgidav 4.4.0`，`http://192.168.100.52:8090/legado/`，匿名；服务器文件见 `webdav_server_files.txt` |

## 二、总体结论

- 功能验收 7 项：**PASS 7 / BLOCKED 0**；审查 1 P1 + 3 P2 已回修；设备复核发现 1 P2（未来 mtime 重复提示）已回修并复验。
- FATAL/ANR/E.flutter/overflow/E AndroidRuntime 均为 **0**（`logcat_b10.txt`）。
- 设备终态：`pm clear` 空书架、默认设置；宿主 WebDAV 服务已停止。

## 三、逐项结果

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| A1 WebDAV 连接 | PASS | `tmp_qb10_07.png`、`tmp_qb10_32.png` | 地址保存后「测试配置」→「连接成功」 |
| A2 冷启动自动检查 | PASS | `tmp_qb10_08.png` | 配置远端已有较新备份，冷启动约 5s 后弹出「恢复 / WebDAV 备份比本地新，是否恢复？ / backup_20260101_120000_000.json / 取消·确定」 |
| A3 取消后不重复 | PASS | `tmp_qb10_09.png` | 取消同一备份后重启无弹窗（seen 去重） |
| A4 远端更新再次提示 | PASS | `tmp_qb10_33.png`、`tmp_qb10_37.png` | 远端产生更新备份（含未来 mtime）后再次冷启动会提示，文件名正确 |
| A5 确认恢复成功 | PASS | `tmp_qb10_36.png`、`tmp_qb10_38.png` | 确定后完成下载/探测/恢复，SnackBar「恢复成功」，书架与设置刷新 |
| A6 恢复后不重复 | PASS | `tmp_qb10_35.png`、`tmp_qb10_39.png` | 恢复后即使远端 mtime 在未来，重启也不再提示同一备份（回修后） |
| A7 稳定性/终态 | PASS | `logcat_b10.txt`、`tmp_qb10_40.png` | 五类崩溃计数 0；`pm clear` 后空书架、默认设置、可启动 |

## 四、审查与回修

- 首轮审查 `needs changes`（无 P0；P1×1「refresh 异常被误判恢复失败」、P2×4「busy 永久消费配额」「闪屏丢弹窗但写 seen」「本地恢复不更新 seen」「appPrefs 先于 restore 半覆盖」）→ `ed85e9d47b`；复审 **pass**。
- 设备验收发现 P2：远端 mtime 为未来（服务器时钟超前）时，确认/取消后每次启动仍重复提示（`shouldPrompt` 把 seen 也按未来归零）→ `d652506784`（仅 lastBackup 未来归零，lastSeen 按原值比较）→ 复验 A6 PASS。

## 五、P3 / 未覆盖

1. 关闭「自动检查新备份」开关与未配置 WebDAV 的静默行为由单测覆盖，本轮未逐项设备操作。
2. 加密 zip 备份（`passwordRequired`）不自动恢复、提示手动处理，由单测覆盖，未做设备加密 zip。
3. busy 延迟重试（30s×3）、闪屏/启动锁门控、点遮罩不写 seen 由单测/Widget 覆盖，未在设备构造慢备份/闪屏窗口。
4. `applyAppPrefsFromBackupFile` 先于 `api.restore` 的半覆盖风险保留（审查要求登记，未改顺序）。
5. 远端 displayname 与实际路径不一致的服务器下载失败风险沿用既有远程书库链路（登记）。
6. 进程在恢复中途被杀的临时目录残留（`legado_webdav_restore_*`，无敏感内容）未做启动清扫（登记）。

## 六、设备终态

- 应用 2.0.479+480 已安装，`pm clear` 后空书架、默认设置、可启动；测试 WebDAV 服务已停止、配置随清数据移除。

## 七、门禁（代码基线）

- Flutter：analyze 0；test **5371 通过 + 1 skipped**；本批 format 0 changed。
- Rust/契约未改：core 860 / db 472 / ffi 702（默认）/775（quickjs）；§2.53 12 方法、338/336/172/188；DB 119。

---

编写：ZCode 主代理 ｜ 2026-11-10
