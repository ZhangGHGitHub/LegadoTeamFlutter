# 批26 设备验收报告：段评摘要加载修复（reader 摘要加载与相邻章预载解耦）

- 验收日期：2026-11-13
- 验收执行：QA 子代理（仅设备取证与证据归档，未修改任何产品代码）
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`，HEAD `c3fc76b77f`
- 被验修复：`32d9636835`（`fix(ui): 段评摘要加载与相邻章预载解耦，修复段评面板不可达`）
- 验收对象：`io.legado.flutter_legado` 2.0.496（versionCode 497），release 变体
- 结论摘要：**段评链路 4/4 PASS**；设备崩溃五项计数 0；批25 的 BLOCKED 项（段评面板不可达）已闭环

## 一、环境与对象

| 项目 | 实测值 |
|---|---|
| 设备端点 | **`192.168.100.63:5555`**（`adb devices -l` 在线） |
| 模拟器 | MuMu 实例，Android 15，1080x1920 / density 480 |
| 安装包 | `io.legado.flutter_legado` versionName **2.0.496** / versionCode **497**，release 变体 |
| APK sha256 | **`da5ebbcc5e0acc1eab5070f70795f431bde4c292a341309a42f88956b56e3851`**（宿主 `flutter_legado/build/app/outputs/flutter-apk/app-release.apk` 实测，202,113,768 B） |
| 构建证据 | `build_release_b26.log`：三 ABI 复用既有 `.so`（arm64-v8a / armeabi-v7a / x86_64 指纹一致），`assembleRelease` 95.9s，输出 APK 202.3 MB |
| 段评夹具 | 复用批25 宿主 mock 源站（`docs/materials_1113d/qa_b25_mock_server.py`、`qa_b25_review_source.json`）：源站 `http://192.168.100.52:8925`，书 `QA25 段评书` 6 章；`/review/summary` 固定返回 `counts={"1":7,"2":3}`，`/review/detail` 返回 QA读者甲/乙两条评论 |
| 应用数据 | 测试书源 `QA25 段评源`（带 `ruleReview`）、测试书、Web 访问令牌均已入库，供用户复核 |
| 取证方式 | 宿主 mock 访问日志、`uiautomator dump`、`screencap`、`logcat -d`、`logcat -b crash -d` |

## 二、总体结论

| 指标 | 数量 |
|---|---|
| 验收项总数 | **4** |
| PASS | **4** |
| FAIL | **0** |
| BLOCKED | **0** |
| 设备崩溃五项（FATAL / AndroidRuntime / ANR / OOM / Low memory） | **0** |
| crash buffer 中 legado 引用 | **0**（24 次 SIGSEGV 全部为 `Cmdline: uiautomator`） |

**核心结论**：修复后在「开书即已装载完成、首帧 `isLoading=false`」的生产路径下，阅读器会主动发起当前章段评摘要请求并渲染段落徽标；点击徽标可打开详情面板并请求详情；切换章节会重新请求摘要并刷新徽标，且不残留上一章计数。批25 登记的 P2（段评面板不可达）在设备上确认闭环。

## 三、逐项结果

| # | 验收项 | 结果 | 关键证据 | 说明 |
|---|---|---|---|---|
| 1 | 首进阅读器即请求 `/review/summary` | **PASS** | `qa_b26_mock_access.log`（第 5 行）、`logcat_b26.txt`、`u14.xml` | mock 访问日志在书页与章节预载（`/chapter2..4.html`）之后出现 `GET /review/summary`，无需任何额外交互；对应源码 `_maybeLoadReviewSummary(state)` 在 `build` 中与预载并列调用 |
| 2 | 正文段落徽标渲染 `7` / `3` | **PASS** | `u14.xml`、`b26_panel.png` | `u14.xml` 中第 1 段 `content-desc` 末尾为 `7`、第 2 段末尾为 `3`（第 3/4 段无徽标）；`b26_panel.png` 背景可见第 1/2 段右侧灰色徽标 `7`/`3` |
| 3 | 点击徽标打开面板并请求 `/review/detail` | **PASS** | `u15.xml`、`b26_panel.png`、`qa_b26_mock_access.log`（第 8 行） | 面板标题 `段评 · 7`，内容为 `QA读者甲`（`批25 段评正文：这一段的讨论很热闹。`/昨天）与 `QA读者乙`（`批25 段评正文：同意楼上。`/今天）；同一次交互后 mock 收到 `GET /review/detail` |
| 4 | 切第 2 章再次请求摘要且徽标刷新 | **PASS** | `u18.xml`、`b26_ch2.png`、`qa_b26_mock_access.log`（第 9 行） | 切章后 mock 收到第二次 `GET /review/summary`；第二章第 1/2 段徽标为 `7`/`3`，页面标题「第二章 后续」、进度 `1/1 33.3%`，无旧章徽标残留 |

## 四、关键证据

### 4.1 mock 访问日志完整序列

`qa_b26_mock_access.log`：

```text
GET /book1.html
GET /chapter2.html
GET /chapter3.html
GET /chapter4.html
GET /review/summary
GET /chapter5.html
GET /chapter6.html
GET /review/detail
GET /review/summary
```

解读：进入书页 → 相邻章预载 `chapter2..4` → **首章摘要 `summary`** → 继续预载 `chapter5..6` → 点击第 1 段徽标触发 **`detail`** → 切第 2 章触发**第二次 `summary`**。整条链路只含段评读端点，无写请求。

### 4.2 徽标与面板（UI dump 原文）

`u14.xml`（第一章，节选）：

```text
content-desc="　　第一段：这一章用于验证段评&#10;摘要徽标与详情面板。&#10;7"
content-desc="　　第二段：本段应显示段评数量&#10;徽标一。&#10;3"
content-desc="　　第三段：本段应显示段评数量&#10;徽标二。"
content-desc="　　第四段：本段用于确认正文渲&#10;染正常。"
```

`u15.xml`（段评面板，节选）：

```text
content-desc="段评 · 7"
content-desc="QA读者甲&#10;QA&#10;批25 段评正文：这一段的讨论很热闹。&#10;昨天"
content-desc="QA读者乙&#10;批25 段评正文：同意楼上。&#10;今天"
```

`u18.xml`（第二章，节选）：

```text
content-desc="　　第二章第一段：普通正文。&#10;7"
content-desc="　　第二章第二段：普通正文。&#10;3"
content-desc="第二章 后续&#10;QA25 段评书&#10;1/1  33.3%"
```

说明：修复前同一夹具下 mock 日志只有 `/book1.html`、正文无徽标、无任何 `/review/summary` 请求（见批25 报告 §4.4）；本次同一路径首帧即请求，且徽标/面板/切章三态齐全。

### 4.3 稳定性

| 指标 | 计数 | 证据 |
|---|---:|---|
| `FATAL EXCEPTION` | 0 | `logcat_b26.txt` |
| `E/AndroidRuntime` | 0 | `logcat_b26.txt` |
| ANR | 0 | `logcat_b26.txt` |
| OutOfMemory / Out of memory | 0 | `logcat_b26.txt` |
| Low memory / lowmemorykiller | 0 | `logcat_b26.txt` |

`crash_b26.txt`（530 行）共 24 次 `Fatal signal 11 (SIGSEGV)`，`Cmdline` 全部为 `uiautomator`（自动化 dump 退出时崩溃），无 `io.legado.flutter_legado` 进程崩溃记录。

### 4.4 构建与门禁

| 门禁 | 结果 |
|---|---|
| `flutter analyze` | **0 issue** |
| `flutter test` | **5774 通过 + 1 跳过**（0 失败） |
| `dart format --output=none --set-exit-if-changed` | **0 changed** |
| release 构建 | PASS（`build_release_b26.log`，三 ABI `.so` 指纹一致，APK sha256 如上） |
| 新增测试 `reader_review_summary_test.dart` | 4 例全绿（修复前 2 例红：`Expected 1 Actual 0`） |

## 五、设备终态

| 项目 | 终态 |
|---|---|
| 应用界面 | 停留在**第二章阅读页**（`b26_ch2.png` / `u18.xml`：标题「第二章 后续」，进度 `1/1 33.3%`，徽标 `7`/`3`），进程未清理，供用户复核 |
| 应用数据 | 测试书源 `QA25 段评源`、测试书 `QA25 段评书`、Web 访问令牌均已入库；未执行 `pm clear` |
| Web 服务 | **已关闭**（会话收尾操作） |
| 宿主 mock | **已停止**（端口 8925，`qa_b26_mock_access.log` 不再增长） |
| 版本 | versionName **2.0.496** / versionCode **497**，APK sha256 未变化 |

## 六、证据索引（`docs/materials_1113e/`）

| 类别 | 文件 |
|---|---|
| 构建 | `build_release_b26.log` |
| 段评链路 | `qa_b26_mock_access.log`、`u14.xml`（第一章徽标）、`u15.xml`（详情面板）、`u18.xml`（第二章徽标）、`b26_panel.png`、`b26_ch2.png`、`b26_reader.png`（该次截图为黑屏，以 `u14.xml` 为准） |
| 稳定性 | `logcat_b26.txt`、`crash_b26.txt` |
| 环境/过程 | `b26_launch.png`、`b26_mine.png`、`b26_dialog.png`、`b26_web.png`、`b26_webon.png`、`b26_webon2.png`、`ui_b26_top.xml`、`ui_b26_back.xml`、`ui_b26_mine.xml`、`ui_b26_mine2.xml`、`ui_b26_web.xml`、`ui_b26_webon.xml`、`u2..u13.xml`、`u16.xml`、`u17.xml`、`d_*.png`、`d2_*.png`、`mock_server.out` |
