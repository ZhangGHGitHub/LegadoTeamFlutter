# 残留风险销账表（2026-08-13）

依据五类残留风险清单执行收口。状态：`✅` 已闭合 / `🟡` 部分 / `⏳` 进行中 / `⛔` 仍需用户素材 / `N/A` 不做。

编写者：Auto（Cursor）｜ 2026-08-13

---

## P0 工程

| ID | 项 | 状态 | 说明 / commit |
|---|---|---|---|
| Doc1 | GAP 听书「诚实隐藏」过时 | ✅ | 轮5为准；正文已统一 |
| Doc2 | REMAINING_ITEMS schema v102 延后口径 | ✅ | 顶栏改为 v104 已落地 |
| Doc5 | §4.3 P2-2 缺失页过时 | ✅ | 已交付页销记 |
| Doc7 | 台账 v102/v104 混称 | ✅ | 文首统一说明 |
| Doc8 | REMAINING 文首「全部完成」误导 | ✅ | 文首指向残留表 |
| F1 | 听书缓存 SAF DocumentFile 落盘 | ✅ | Saf.writeFileBytes + persistable URI |
| D1 | rule_subs/dict_rules/keyboard_assists 对齐 Room | 🟡 | 已清 default_data 双建表；全表 Room 改名仍分步 |
| F2 | Job 冷启动尽量 headless | ✅ | 无头引擎优先 + 最小化拉起 Activity |
| F4 | 封面规则 CRUD / 契约 | ⏳ | 本轮未开契约；Repository 已有 insert/delete |
| F5 | MCP LAN/token/jsSourceApiToken | 🟡 | UI 标明仅本机；LAN/token 契约待开 |
| F6 | MoreConfig 刘海/音量键/shareLayout | 🟡 | 音量键+刘海边距已接线；shareLayout 待日夜双配置 |
| D3/D4 | 迁移运维说明（备份/不可逆/legacy） | ✅ | 本文 §迁移运维 |
| D5 | insert_replace 前 name+author 预检 | ✅ | remap chapters 保目录 + 单测 |
| F3 | callBackBtn 副作用测试 | ✅ | 单测；专用源仍需用户 |

## P1

| ID | 项 | 状态 | 说明 |
|---|---|---|---|
| F7 | 禁止本地段评当 ruleReview | ✅ | BookApi 本地 CRUD @Deprecated |
| F9 | 缓存导出模板/WebDAV | ✅ | 复核已接线（335fcb11c） |
| T6 | bookUrl JS 路径 | ⏳ | 本轮未改；仍开放 |
| Doc3/4/6 | §5.13 / 定时服务 / QUIC 销记 | 🟡 | Doc4 定时服务已销；Doc3/6 部分 |
| A* | 环境验收项 | ⛔ | 见 USER_TEST 阻塞 12；附复现命令 |

## 不做

- Cronet / 直链上传重开
- 创意功能
- force push

---

## 迁移运维说明（D3/D4）

### SCHEMA 104（Migration103To104）

- **单向不可逆**：`down` 直接报错；升级失败只能靠备份还原。
- **升级前**：务必备份 `legado.db`（应用备份区或拷贝文件）。
- **空 link**：RSS 等合成键 `legacy:origin:title:sort`；后续同步/去重与原版可能不一致。
- **同主键冲突**：`INSERT OR IGNORE` + `ORDER BY` 保留较新行，冲突行静默丢弃。
- **残留表名**：`rule_subs` / `dict_rules` / `keyboard_assists` 仍为 snake_case（相对 Room `ruleSubs`/`dictRules`/`keyboardAssists`）。D1 已清 default_data 双建表，全表改名仍分步。

### users vs servers

Rust `users` ≠ Room `servers`；远程服务器列表走 Flutter `SettingsService`，从 Android 库迁入时须手工重配。

---

## A 类环境项复现命令（仍需用户素材）

```powershell
$adb = "D:\Android\platform-tools\adb.exe"
# 深链（系统 VIEW，非 -n 组件）
& $adb -s emulator-5556 shell am start -a android.intent.action.VIEW -d "legado://booksource/import?src=https://example.com/sources.json"
# MCP 端口探测
& $adb -s emulator-5556 shell "ss -ltn | grep 1236 || netstat -ltn | grep 1236"
# 冒烟
.\scripts\emulator_smoke_test.ps1 -Device emulator-5556 -SkipBuild -CheckUI
```

| 项 | 状态 | 素材 |
|---|---|---|
| A1 WebDAV 实网 | ⛔ 仍需用户素材 | 有效 WebDAV 账号 |
| A2 听书流媒体+片头/SAF | ⛔ 仍需用户素材 | 音频书源 |
| A3 真机媒体键/焦点 | ⛔ 仍需用户素材 | 真机 |
| A4 漫画/视频 | ⛔ 仍需用户素材 | 样例书 |
| A5 段评 ruleReview | ⛔ 仍需用户素材 | 含 ruleReview 源 |
| A9 深链 VIEW | ⏳ 可 adb 自测 | 见上命令 |
| A10 皮肤 zip | ⛔ 仍需用户素材 | 皮肤 zip |

---

## 批次 commits（随进度追加）

| 前缀 | 说明 |
|---|---|
| `[docs]` | 残留风险销账 + GAP/REMAINING/README 口径 |
| `[UI]+[Android]` | F1 SAF 落盘 + F2 Job headless |
| `[Rust]` | D5 name+author 预检 + D1 清双建表 + F3 单测 |
| `[UI]` | F5/F6/F7 MCP 文案 / 音量键刘海 / 本地段评 Deprecated |
| `[UI]` | **版本同源已修**：`package_info_plus` 替代硬编码 `2.0.38`（关于页 / 检查更新 / UA） |
