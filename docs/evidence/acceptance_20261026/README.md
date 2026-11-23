# 设备验收证据归档：2026-10-26（审查批 1~7 合并实机验收）

## 1. 基本信息

| 项 | 值 |
|---|---|
| 来源目录 | `tmp_debug/device_acceptance_20261026/`（原目录，`.gitignore:49` 的 `/tmp_*` 规则忽略，`git ls-files` = 0） |
| 采集日期 | 2026-10-26（文件 mtime 14:18 ~ 14:30，宿主时间） |
| 归档日期 | 2026-11-23 |
| 归档位置 | `docs/evidence/acceptance_20261026/` |
| 文件数 | **51**（归档前后一致，`diff -r` 校验完全相同） |
| 体积 | 3,458,260 B（约 3.3 MB） |
| 设备 | MuMu 实例 guest 直连 `192.168.100.62:5555`（`io.legado.flutter_legado`） |
| 应用版本 | **2.0.374+375**（`versionName=2.0.374` / `versionCode=375`） |
| 批次 | **审查批 1~7 合并实机验收**（非 UI 编号批，见 §3 证据链） |

## 2. 推断用途（附证据）

**结论：这批证据是「审查批 1~7 合并实机验收 + 冒烟 + 6 项针对性回归」的原始证据。**

### 2.1 直接文档锚点（最强证据）

`docs/REFACTORING_ACTIVE_PLAN.md:831`（2026-10-26 条目）逐字点名了本目录：

> 批1~7 实机验收 PASS（2026-10-26，MuMu Test测试 guest 直连 `192.168.100.62:5555`…）：
> .so 双 ABI 重编（arm64/x86_64，FRB hash 236894094+源码指纹一致）→ APK 装机 2.0.374+375 →
> 冒烟 PASS（崩溃标记 0）→ 6/6 针对性回归 PASS（阅读器进入正文/关于页堆转储入口/
> Web 服务开关+宿主 curl /api/health 200/RSS 管理页/恢复确认框）；
> **证据目录 `tmp_debug/device_acceptance_20261026/`（截图+dump+日志）**。

### 2.2 目录内自证据

| 证据文件 | 内容 | 支撑的结论 |
|---|---|---|
| `package_info.txt` | `versionCode=375` / `versionName=2.0.374` / `lastUpdateTime=2026-10-26 14:25:58` | 装机版本与批次时间锚定 |
| `pre_build_state.txt` | Rust 源码指纹 `15030f2a…`、jniLibs 旧 `.so`（2026-10-05 产物）、`pubspec: version: 2.0.374+375` | 构建前态，证明 .so 需重编 |
| `post_build_state.txt` | 新 `.so`（2026-10-26 14:21 构建，`mode=release`、`quickjs=true`、`rustFingerprint=15030f2a…`）、APK 306,195,930 B | 双 ABI 重编完成 |
| `smoke_build.log` | FFI verify 首次 FAIL（hash 不同步）→ 自动重编 → verify PASSED → 装 APK；汇总 **7 通过 / 1 失败**（`[FAIL] UI 主界面元素未检出`） | 冒烟第一轮（UI 检测项失败，原因见 2.3） |
| `smoke_skipbuild.log` | 复用 APK 重跑：**7 通过 / 0 失败**，`结果: PASSED`，`EXITCODE=0` | 冒烟第二轮通过（对应计划中「冒烟 PASS」） |
| `web_health.txt` | `HTTP/1.1 200 OK` + `{"service":"legado-server","status":"ok","version":"0.2.0"}` | 对应回归项「宿主 curl /api/health 200」 |
| `ui_08_about.xml` | `更新日志 版本 2.0.374`、`创建堆转储` | 对应回归项「关于页堆转储入口」 |
| `ui_04_reader.xml` | 阅读器正文语义树 | 对应回归项「阅读器进入正文」 |
| `ui_06_web_on.xml` / `ui_06b_web_on.xml` | `Web 服务 用浏览器写源或看书` | 对应回归项「Web 服务开关」 |
| `ui_09_rss.xml` / `ui_10_rss_manage.xml` | 订阅列表（小说拾遗/Meow云/烏雲净化）与订阅源管理页 | 对应回归项「RSS 管理页」 |
| `ui_13_restore_confirm.xml` / `ui_13_parsed.txt` | `确认恢复吗？` / `恢复书架会覆盖现有书架…` | 对应回归项「恢复确认框」（批 7b 落地） |
| `ui_11*` / `ui_12*` / `ui_14*` / `ui_15*` | 「我的」页、设置首页、备份与恢复页（WebDav 设置/恢复长按提示）、Web 服务开/关两态 | 覆盖批 7b/批 8 相邻入口 |
| `logcat_since_launch.txt` / `logcat_30s_idle.txt` / `logcat_after_regression.txt` | 启动后、30s 空闲、回归后三段 logcat | 崩溃标记核查（FATAL/ANR 计数） |
| `parse_ui.py` | 解析 uiautomator dump 的 `text`/`content-desc`/`bounds` 小脚本 | 产出 `ui_*_parsed.txt`，属 QA 辅助，未改应用代码 |

### 2.3 为什么冒烟第一轮 UI 检测失败（可解释，非缺陷）

`01_launch_shelf.png` 截图显示启动即弹出「上次运行发生崩溃」modal（崩溃时间 2026-10-06 21:0x，
内容 `HTTP request failed, statusCode: 404, https://imgs.34img.cc/manga-cover/…`），且该 modal
右侧有 `RIGHT OVERFLOWED BY 12 PIXELS` 条幅。此 modal 遮蔽了书架语义树，导致
`smoke_build.log` 的 `-CheckUI` 检不到「书架/发现/订阅/我的」。这正是计划 831 行登记的
验收遗留 ②「崩溃报告对话框右侧溢出 12px」与 ③「历史崩溃存根 modal 会遮蔽冒烟 -CheckUI
（建议脚本先关弹窗/清存根）」。第二轮 `smoke_skipbuild.log` 关闭弹窗后即 7/7 通过。

## 3. 批次归属判定

- **批次 = 审查批 1~7 合并实机验收**，版本 **2.0.374+375**。
- 判定依据：`REFACTORING_ACTIVE_PLAN.md:827`（批 5/批 6 关闭收尾 2.0.374+375）与 `:831`
  （批 1~7 实机验收 PASS + 点名本证据目录）构成完整链条；`package_info.txt` 与
  `pre_build_state.txt` 的 `2.0.374` / `2.0.374+375` 双向吻合。
- 注意：这不是「设置批 2b-x」等 UI 编号批——那类批次编号从 2026-10-31 的 `batch1a` 才开始。
- **来源明确，非「来源不明」**。

## 4. 内容清单（按类型）

| 类型 | 数量 | 说明 |
|---|---|---|
| `.xml` | 21 | uiautomator 语义树：`ui_shelf*.xml`、`ui_03~ui_15*.xml`（含 05b/07b/11b/12b/13b 变体） |
| `.txt` | 14 | 状态/日志/解析文本：`package_info.txt`、`pre/post_build_state.txt`、`web_health.txt`、3 份 logcat、7 份 `ui_*_parsed.txt` |
| `.png` | 13 | 截图：`01_launch_shelf` ~ `13_restore_confirm`（编号 11/12/14/15 仅留 XML，无截图） |
| `.log` | 2 | `smoke_build.log`（含 FFI 重编）、`smoke_skipbuild.log` |
| `.py` | 1 | `parse_ui.py`（QA 辅助脚本） |
| **合计** | **51** | |

目录为**扁平结构**（无子目录）。

## 5. 归档说明

- 整目录复制，**未筛选**（日志、脚本、语义树、截图全留）。
- 复制使用保留时间戳方式（`cp -a`），文件 mtime 仍为 2026-10-26 原始值。
- 归档前后 `diff -r` 完全一致，文件数 51 → 51。
- 原目录 `tmp_debug/device_acceptance_20261026/` 在归档校验通过后已删除。
- 与并行归档的关系：本目录是 `docs/REMAINING_WORK_INVENTORY_20261120.md` 附录 A.5
  点名的两个「无文档来源」目录之一；另一为 `acceptance_20261103_batch2b2c/`。
