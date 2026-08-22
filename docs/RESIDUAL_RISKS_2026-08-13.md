# 残留风险销账表（2026-08-13）

依据五类残留风险清单执行收口。状态：`✅` 已闭合 / `🟡` 部分 / `⏳` 进行中 / `⛔` 仍需用户素材 / `N/A` 不做。

编写者：Auto（Cursor）｜ 2026-08-13  
修订：Auto｜2026-08-13（D1/F4/F5/F6/T6/Doc3/6 收口）  
修订：Auto（Cursor）｜ 2026-08-14（v2.0.45：误入书架 / refresh_toc NOT_SHELF 闭合）

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
| D1 | ruleSubs/dictRules/keyboardAssists 对齐 Room | ✅ | SCHEMA 105（Migration104To105）；`18003a7b9` |
| F2 | Job 冷启动尽量 headless | ✅ | 无头引擎优先 + 最小化拉起 Activity |
| F4 | 封面规则 CRUD / 契约 | ✅ | get/save/deleteCoverRule + 主题页对话框；`f7bcf4425`/`d83e6eb26` |
| F5 | MCP LAN/token/jsSourceApiToken | ✅ | `0.0.0.0` + 非空 token + `X-Legado-Token`；`5cb4d4ca3` |
| F6 | MoreConfig 刘海/音量键/shareLayout | ✅ | 音量键+刘海已接线；shareLayout 日夜/共用桶 + 主题切换重载 |
| D3/D4 | 迁移运维说明（备份/不可逆/legacy） | ✅ | 本文 §迁移运维（含 SCHEMA 105） |
| D5 | insert_replace 前 name+author 预检 | ✅ | remap chapters 保目录 + 单测 |
| F3 | callBackBtn 副作用测试 | ✅ | 单测；专用源仍需用户 |

## P1

| ID | 项 | 状态 | 说明 |
|---|---|---|---|
| F7 | 禁止本地段评当 ruleReview | ✅ | BookApi 本地 CRUD @Deprecated |
| F9 | 缓存导出模板/WebDAV | ✅ | 复核已接线（335fcb11c） |
| T6 | bookUrl JS 路径 | ✅ | CSS→`@js:` 链单测覆盖（quickjs）；空 bookUrl 回退书源主页已落地 |
| B1 | 仅浏览详情/目录误入书架 | ✅ | UI 不落库 + Rust `NOT_SHELF` 占位；`1fd863406` / `fafc65782` |
| B2 | `refresh_toc` 占位污染书架 | ✅ | 同 B1；`fafc65782` |
| Doc3/4/6 | §5.13 / 定时服务 / QUIC 销记 | ✅ | Doc4 定时服务已销；Doc3：§5.13-7/10 与 F4/F5 对齐销记，余项为故意后置（Cronet/WebView/直链/视频）；Doc6：QUIC 按用户决策已移除（N/A） |
| A* | 环境验收项 | ⛔ | 见 USER_TEST 阻塞 12；附复现命令 |

## 不做

- Cronet / 直链上传重开（**F4-5 ✅ 2026-08-14**：RESIDUAL 销记；其他设置页移除空壳占位，对齐「诚实不展示」）
- 创意功能
- force push

---

## 迁移运维说明（D3/D4）

### SCHEMA 105（Migration104To105）

- **单向不可逆**：升级失败只能靠备份还原。
- **升级前**：务必备份 `legado.db`。
- **表名对齐 Room**：`dictRules` / `keyboardAssists` / `ruleSubs`（自 snake_case 迁入并删旧表）。
- **列语义**：`ruleSubs.type` 为 Int（0/1/3）；FFI 仍暴露 `sub_type` 字符串，Repository 内转换。
- **keyboardAssists**：Room 主键 `(type, key)`，列 `serialNo`。

### SCHEMA 104（Migration103To104）

- **单向不可逆**：`down` 直接报错；升级失败只能靠备份还原。
- **升级前**：务必备份 `legado.db`（应用备份区或拷贝文件）。
- **空 link**：RSS 等合成键 `legacy:origin:title:sort`；后续同步/去重与原版可能不一致。
- **同主键冲突**：`INSERT OR IGNORE` + `ORDER BY` 保留较新行，冲突行静默丢弃。

### users vs servers

Rust `users` ≠ Room `servers`；远程服务器列表走 Flutter `SettingsService`，从 Android 库迁入时须手工重配。

---

## A* 验收矩阵（P2-4 登记，2026-08-22）

> **口径**：待验收 ≠ 工程未实现——每行「工程证据」列记录已落地的实现/测试依据；验收需真实环境素材，**不得以模拟器冒烟销账**（设计使然，非缺陷）。验收通过后在本表销账并附证据。

```powershell
$adb = "D:\Android\platform-tools\adb.exe"
# 深链（2026-08-22 已验证）：5556 上 io.legado.flutter_legado 与原版 com.legado.app.release 并存且均注册 legado://，
# 裸 VIEW 会触发系统选择器（ResolverActivity）→ 验收必须显式组件定向
& $adb -s emulator-5556 shell am start -a android.intent.action.VIEW -d "legado://booksource/import?src=https://example.com/sources.json" -n io.legado.flutter_legado/io.legado.flutter.MainActivity
# MCP 端口探测（LAN 绑定后本机可见）
& $adb -s emulator-5556 shell "ss -ltn | grep 1236 || netstat -ltn | grep 1236"
# 冒烟
.\scripts\emulator_smoke_test.ps1 -Device emulator-5556 -SkipBuild -CheckUI
```

| # | 项 | 状态 | 素材 | 负责人 | 工程证据（待验收 ≠ 未实现） | 验收命令 / 方法 |
|---|---|---|---|---|---|---|
| A1 | WebDAV 实网 | ⛔ 待验收 | 有效 WebDAV 账号 | 用户 | `webdav.rs` 已实现（重试循环不变量断言，P2-5 D1），单测在位；未实测真实 WebDAV 服务 | 应用内备份/恢复到 WebDAV → 往返一致性 |
| A2 | 听书流媒体+片头/SAF | ⛔ 待验收 | 音频书源 | 用户 | TTS/音频管线 + Job headless + SAF 落盘路径已实现；未用真实音频源走完整链路 | 播放音频书 → 后台续播 → SAF 落盘 |
| A3 | 真机媒体键/焦点 | ⛔ 待验收 | 真机 | 用户 | 媒体键/焦点处理逻辑已实现（模拟器无硬件媒体键）；参照侧原版 `MediaButtonReceiver` 在位 | 真机按媒体键 → 验证切章与焦点切换 |
| A4 | 漫画/视频 | ⛔ 待验收 | 样例漫画书/视频书 | 用户 | 图片/视频渲染路径已实现（翻页、缩放、全屏）；未用样例书走全路径 | 打开样例漫画/视频书 → 翻页/缩放/全屏 |
| A5 | 段评 ruleReview | ⛔ 待验收 | 含 ruleReview 源 | 用户 | 段评实现已落地（本地 Deprecated + 远端通道）；未用真实 ruleReview 源验证 | 打开带段评书 → 显示/交互 |
| A9 | 深链 VIEW | ✅ **已验证 2026-08-22** | 无 | 自测（主代理） | `am start -n io.legado.flutter_legado/io.legado.flutter.MainActivity` 启动成功，`mCurrentFocus` 确认 Flutter MainActivity 前台处理；发现 5556 并存原版且双方注册 scheme → 裸 VIEW 触发系统选择器（已记入命令块） | 见上命令块（显式组件定向） |
| A10 | 皮肤 zip | ⛔ 待验收 | 皮肤 zip 文件 | 用户 | 皮肤导入路径已实现；未用真实皮肤包验证 | 导入皮肤 zip → 应用生效 |
| V1 | 验证码实网 | ⛔ 待验收 | 触发验证码的书源 | 用户 | JS 钩子 `getVerificationCode`/`startBrowserAwait` + FFI 事件流/提交/取消（Task #90，契约 §2.3）已交付；`CaptchaInfo` 被动检测在位；未实网端到端 | 登录含验证码源 → 弹窗识别填入 → 成功 |
| V2 | 登录倒计时 | ⛔ 待验收 | 含 loginUi 倒计时源 | 用户 | 登录倒计时 UI/逻辑已实现（USER_TEST H10：阻塞于素材，非缺陷）；未用真实源验证 | 打开 loginUi 倒计时源 → 自动刷新 |
| V3 | 外链确认 | ⛔ 待验收 | 触发外链跳转的书源 | 用户 | 外链确认弹窗路径已实现（GAP_AUDIT UI 检查 OK）；未实网触发 | 触发外链跳转 → 弹窗确认/取消 → 流程继续 |

---

## 其他待素材项（P2 登记，2026-08-22）

| 项 | 状态 | 素材 / 行动 |
|---|---|---|
| Mock 书架真实数据 | ⛔ 仍需用户素材 | 脱敏 Android 书架导出 JSON，替换 `mock_book_api.dart` 占位书籍（TODO §6.4）。口径：**部分真实样本**——书源/RSS/TTS 为原 Android `defaultData/` 真实资产，书架为调试占位 |

---

## 批次 commits（随进度追加）

| 前缀 | 说明 |
|---|---|
| `[docs]` | 残留风险销账 + GAP/REMAINING/README 口径 |
| `[UI]+[Android]` | F1 SAF 落盘 + F2 Job headless |
| `[Rust]` | D5 name+author 预检 + D1 清双建表 + F3 单测 |
| `[UI]` | F5/F6/F7 MCP 文案 / 音量键刘海 / 本地段评 Deprecated |
| `[UI]` | **版本同源已修**：`package_info_plus` 替代硬编码 `2.0.38`（关于页 / 检查更新 / UA） |
| `[Rust]` | D1 SCHEMA 105 Room 表名列名对齐（`18003a7b9`） |
| `[Rust]`/`[UI]` | F4 封面规则 CRUD（`f7bcf4425`/`d83e6eb26`） |
| `[Rust]` | F5 MCP LAN + jsSourceApiToken + X-Legado-Token（`5cb4d4ca3`） |
| `[UI]` | F6 shareLayout 日夜双配置 |
| `[Rust]` | T6 bookUrl CSS@js 链单测 |
| `[docs]` | 本表 D1/F4–F6/T6/Doc3/6 销账 |
| `[docs]` | v2.0.45 B1/B2 误入书架 + refresh_toc NOT_SHELF 销记 |
