# 批22 设备验收报告：自动刷新书架 / 书架搜索过滤 / 书签直达 / process_text

- 验收日期：2026-11-13
- 验收执行：QA 子代理（仅取证，未修改代码）
- 仓库：`D:\OH-WorkSpace\LegadoTeam\legado`，HEAD `003ea9febf`（`chore: 批22 收尾（2.0.492+493 双日志）`）
- 验收对象：`io.legado.flutter_legado` 2.0.492（versionCode 493），release 变体
- 结论摘要：**13 PASS / 1 FAIL / 1 BLOCKED**；设备侧崩溃 0；新增 1 个产品交互缺陷（P2）与 1 个验收口径问题（P1）

## 一、环境与对象

| 项目 | 实测值 |
|---|---|
| 设备端点 | **`192.168.100.63:5555`**（guest 直连；`MuMuManager.exe info -v all` 判定 index 0「Test2」在线，index 1「Test测试」未启动；`127.0.0.1:16384` 未使用） |
| 模拟器 | MuMu 实例 index 0「Test2」，`is_android_started=true`，Android 15 |
| 屏幕 | 1080x1920，density 480（应用运行在 MuMu 次显示逻辑屏，截图按物理 display id 抓取） |
| 安装包 | `io.legado.flutter_legado` versionName `2.0.492` / versionCode `493`，`run-as` 报 `package not debuggable`（release） |
| APK sha256 | `fe6256a2dbb6a2ca9b864e83c6b1ff6fa950de5276cc6418dd18b6158bc2cc4b`（设备端 `base.apk` 实测与任务给定值一致） |
| 同机应用 | 另装原版 `com.legado.app.release` 3.26082823、参考版 `io.legato.kazusa` 3.26.15（影响第 13 项文字菜单标签判定，见下） |
| 测试数据 | `qb22_book_a.txt`（3 章）、`qb22_book_b.txt`（4 章），置于 `/sdcard/Download/`，经书架「更多 → 添加本地」导入 |
| 取证方式 | `adb shell input -d <logicalDisplay>` 注入、`uiautomator dump` 读 `content-desc`、`screencap` 按物理 display id 截图 |

说明：本机 MuMu 采用多显示，应用每次冷启动会落到新的次显示（logical id 变化），截图脚本按 `dumpsys SurfaceFlinger --display-id` 的物理 id 抓取；`screencap -d <logicalId>` 在本 ROM 返回 Status -2，已改用物理 id。

## 二、总体结论

| 指标 | 数量 |
|---|---|
| 验收项总数 | 15 |
| PASS | **13** |
| FAIL | **1**（第 3 项，按清单预期；根因为验收口径冲突，非本批代码回归） |
| BLOCKED | **1**（第 4 项，无法与「本地书排除」区分） |
| 设备崩溃 | **0**（FATAL / AndroidRuntime / ANR / OOM / 进程异常退出 均为 0） |
| 新增产品缺陷 | 1 个 P2：全局搜索页系统返回键无效 |
| 验收方案问题 | 1 个 P1：仅用本地 TXT 无法触发「已更新 N 本书的目录」提示 |

## 三、逐项结果

| # | 验收项 | 结果 | 关键证据 | 说明 |
|---|---|---|---|---|
| 1 | 导入 A/B；A 制造「有未读章节」 | PASS | `tmp_qb22_06.png`、`07.png`、`08.png`、`13.png`、`65.png` | A 共 3 章，打开读至第 1 章后 `durChapterIndex=0`，封面未读角标 `2`（13/65）；B 共 4 章，目录解析完成后角标 `3`（65） |
| 2 | 开启自动刷新后「仅更新已读完」出现（依赖 auto_refresh） | PASS | `11.png`、`63.png` | 开自动刷新 → 该项出现；关自动刷新 → 该项消失，依赖关系正确 |
| 3 | 冷启动 10-20s 出现「已更新 N 本书的目录」 | **FAIL** | `13.png`、`logcat_b22_a3.txt` | 无提示；日志：`[AutoRefreshBook] 没有符合刷新条件的书籍，跳过`。仅本地 TXT 时 `BookType.canUpdateToc` 排除本地书（`lib/src/models/book.dart:106`），该场景按实现语义不可能出现提示 |
| 4 | 开启「仅更新已读完」后冷启动只刷已读完书 | **BLOCKED** | `15.png`、`17.png`、`logcat_b22_a4.txt` | 开关存在且可开启（图 15）；冷启动日志同样为「没有符合刷新条件的书籍」，无法区分是 onlyUpdateRead 过滤还是本地书被排除；无在线书可构造可刷新目录 |
| 5 | 关闭自动刷新后冷启动无提示、无刷新 | PASS | `65.png`、`logcat_b22_a5.txt` | `AutoRefreshBook` 日志计数 0；书架与未读角标未变化 |
| 6 | 默认「搜索直达」开启时点搜索图标进全局搜索 | PASS | `18.png` | 进入全局搜索页（含 搜索范围/搜索结果过滤 入口），非书架内过滤 |
| 7 | 长按搜索图标切书架内过滤；输入即时筛选；无匹配空态；清除恢复 | PASS | `20.png`、`21.png`、`22.png`、`23.png`、`24.png` | 长按出现「搜索书架中的书名或作者」过滤条；`qb22` 命中两本；`book_a` 仅剩 A；`zzz` 显示「未找到匹配的书籍」；清除后两本恢复 |
| 8 | 关闭「搜索直达」后点搜索图标直接进书架内过滤 | PASS | `27.png`、`28.png` | 图 27 为布局设置中关闭搜索直达；图 28 点击后进入过滤条（tooltip 变为「书架内搜索」） |
| 9 | 过滤态拖拽不可用；返回键退出过滤而非退出应用 | PASS | `31.png`、`33.png`、`35.png`、`36.png`、`37.png`、`25.png` | 书架无独立「拖拽手柄」控件，拖拽为长按整行：手动排序非过滤态长按拖拽后顺序 A,B → B,A（33→35）；过滤态同样长按打开书籍详情、顺序不变（36→37）；返回键退出过滤且应用进程存活（25）。注：过滤输入框有焦点时首次返回可能只收起焦点/IME，第二次返回退出过滤 |
| 10 | 第 2 章加书签 → 我的 → 书签 → 直达阅读器第 2 章 | PASS | `44.png`、`46.png`、`47.png` | 书签页显示「第二章 章节标题2 2/3」；我的书签列表点击后直接进阅读器，进度 66.7% |
| 11 | 第 1 章（index 0）加书签 → 点击直达阅读器而非详情 | PASS | `49.png`、`50.png` | 书签列表存在第 1、2 章两条；点第 1 章书签直接进阅读器（33.3%），未落到书籍详情 |
| 12 | 「文字操作显示搜索」开关存在且可切换 | PASS | `51.png`、`52.png`、`53.png` | 默认 ON；切换 OFF/ON 均即时生效；`cmd package query-activities -a android.intent.action.PROCESS_TEXT -t text/plain` 中 `ProcessTextAlias` 随开关消失/恢复 |
| 13 | 系统文字菜单出现「阅读」项（随开关） | PASS | `58.png`、`60.png`、`56.png`、`57.png` | 设置页搜索框选中文本 → 工具栏溢出：开关 ON 时有 3 项（`阅读·搜索`、`阅读`、`阅读·搜索`），中间 `阅读` 为我方 alias；开关 OFF 后只剩 2 项 `阅读·搜索`，我方项消失。同机原版/参考版各贡献一个 `阅读·搜索`，故出现重名 |
| 14 | logcat 五项崩溃计数为 0，OOM=0 | PASS | `logcat_b22.txt`、`logcat_b22_a3/a4/a5/final.txt`、`exit_info_b22.txt` | FATAL EXCEPTION 0、`E/AndroidRuntime` 0、ANR 0、OutOfMemory 0、进程异常死亡 0；`dumpsys activity exit-info` 仅有 `USER REQUESTED / FORCE STOP`（02:45、02:50、02:51、03:08）与 `clear data`（03:09），无 CRASH/ANR/LOW_MEMORY；dropbox 唯一 `data_app_crash` 为 2026-11-12 的 `com.microsoft.launcher`，与本包无关 |
| 15 | `pm clear` 清理 + 终态截图 | PASS | `68.png` | `pm clear io.legado.flutter_legado` 返回 `Success`；重新启动后书架为空；版本仍为 2.0.492+493、sha256 未变 |

## 四、问题分级

### P1（验收口径问题，非产品缺陷）：仅本地 TXT 无法触发自动刷新提示

- 现象：按清单导入 2 本本地 TXT 后，冷启动（自动刷新 ON）20s 内无「已更新 N 本书的目录」提示；日志明确 `[AutoRefreshBook] 没有符合刷新条件的书籍，跳过`（`logcat_b22_a3.txt`、`logcat_b22_a4.txt`）。
- 定位：`lib/src/models/book.dart:106` 的 `BookType.canUpdateToc` 为 `book.canUpdate && !isLocalBook(book)`；`auto_refresh_book_scheduler.dart` 的 `shouldRefresh` 使用该判定。单测 `test/unit/auto_refresh_book_scheduler_test.dart` 亦明确「跳过本地书」（文件头注释与第 120、394 行用例）。
- 影响：清单第 3 项期望与实现语义冲突；第 4 项因此无法与「本地书排除」区分。
- 建议：改用在线书（或可控 TOC 变化的本地 mock 书源）复测第 3/4 项；在此之前不应把第 3 项判为代码回归。若产品确需本地 TXT 参与自动刷新，应作为独立需求另行评审（当前与上游一致地排除本地书）。

### P2（产品交互缺陷）：全局搜索页系统返回键无效

- 复现：书架 → 点搜索图标进入全局搜索页（`18.png`）→ 连续两次 `input keyevent 4` → 仍停留在搜索页；点击左上角 `Back` 按钮才返回书架。
- 期望：系统返回键应返回书架（与书籍详情、阅读器、目录页的返回行为一致）。
- 实际：系统返回被吞掉，页面无变化。证据：`tmp_qb22_67.png` 与对应 `uiautomator` dump（两次返回后仍为「搜索/搜索范围/搜索结果过滤」页面）。
- 备注：该问题不在清单 15 项内，属于本次取证额外发现；建议排查全局搜索页所在路由的 `PopScope`/返回分发，并补一条系统返回回归用例。

### P3（观察项，非缺陷）

- 过滤态输入框有焦点时，首次系统返回可能只收起焦点/IME，第二次才退出过滤（第 9 项已记录）；应用未被退出，行为可接受。
- 书架「拖拽手柄」并非独立控件，实际交互为长按整行拖拽；本报告用「手动排序正常态可重排 / 过滤态不可重排」对照取证。
- 同机安装 3 个 Legado 系应用，系统文字菜单出现两个 `阅读·搜索` 与我方 `阅读` 并列；已通过开关前后条目增减确认归属，不影响第 13 项结论。

## 五、设备终态

- `pm clear io.legado.flutter_legado` 执行成功（`Success`），测试书籍、书签、开关偏好全部清除。
- 清理后重新启动应用，停留在空书架（`tmp_qb22_68.png`），无残留测试数据。
- 包信息未变：versionName `2.0.492` / versionCode `493`，base.apk sha256 `fe6256a2...8bc2cc4b`。
- 终态 logcat（`logcat_b22_final.txt`）无 FATAL/ANR/OOM/进程死亡；`exit-info` 最后一条为 `clear data` 触发的强制停止。
- 设备保持在线：`192.168.100.63:5555`。

## 六、门禁引用

- 项目验证命令（`AGENTS.md`）：Flutter `flutter analyze && flutter test`（CI `flutter-ci.yml`）、Android `./gradlew :app:testAppReleaseUnitTest`（CI `test.yml`）、Rust `cargo test`（CI `rust-ci.yml`）。本次为设备实机取证，未重复执行 CI 已覆盖的静态/单测门禁；安装包为 release 变体，未改代码。
- 相关实现位置（HEAD `003ea9febf`）：
  - `flutter_legado/lib/src/services/auto_refresh_book_scheduler.dart`（`notice`、`shouldRefresh`、`onlyUpdateReadAllows`）
  - `flutter_legado/lib/src/models/book.dart:106`（`canUpdateToc` 排除本地书）
  - `flutter_legado/lib/src/screens/bookshelf_screen.dart`（过滤态返回/禁用拖拽、搜索图标分流）
  - `flutter_legado/lib/src/screens/other_settings_screen.dart`（`仅更新已读完`、`文字操作显示搜索`）
  - `flutter_legado/android/app/src/main/AndroidManifest.xml:183-201`（`ProcessTextAlias`，label=`阅读`）
  - `flutter_legado/test/unit/auto_refresh_book_scheduler_test.dart`（本地书跳过、onlyUpdateRead 口径）
- 版本记录：`flutter_legado/CHANGELOG.md` 2.0.492 条目与本批提交（`6fca26a1e0`、`97c48bcb64`、`77ca821669`、`5dc08cb0c0`、`003ea9febf`）。

## 七、证据索引

目录：`docs/materials_1113a/`

| 文件 | 内容 |
|---|---|
| `tmp_qb22_06/07.png` | 导入 A/B 后书架 |
| `tmp_qb22_11.png` | 自动刷新 ON + 仅更新已读完出现 |
| `tmp_qb22_13.png` | 自动刷新 ON 冷启动 20s，无提示（A 未读角标 2） |
| `tmp_qb22_15.png` | 自动刷新 + 仅更新已读完均 ON |
| `tmp_qb22_17.png` | 仅更新已读完 ON 冷启动，无提示 |
| `tmp_qb22_18.png` | 搜索图标 → 全局搜索页 |
| `tmp_qb22_20/21/22/23/24.png` | 过滤条 / `qb22` 命中两本 / 仅 A / 无匹配 / 清除恢复 |
| `tmp_qb22_27/28.png` | 关闭搜索直达 / 点图标进入过滤 |
| `tmp_qb22_31/33/35/36/37.png` | 过滤态与正常态拖拽对照 |
| `tmp_qb22_25.png` | 返回键退出过滤（应用仍在） |
| `tmp_qb22_44/46/47.png` | 第 2 章书签与直达阅读器 |
| `tmp_qb22_49/50.png` | 第 1 章书签与直达阅读器 |
| `tmp_qb22_51/52/53.png` | 文字操作开关 ON/OFF/ON |
| `tmp_qb22_56/57/58.png` | 系统选中文字工具栏与开关 ON 时的 3 个 PROCESS_TEXT 项 |
| `tmp_qb22_59/60.png` | 开关 OFF 后系统菜单仅剩 2 个 `阅读·搜索` |
| `tmp_qb22_61/62/63.png` | 关闭自动刷新后「仅更新已读完」消失 |
| `tmp_qb22_65.png` | 自动刷新 OFF 冷启动无提示 |
| `tmp_qb22_67.png` | 全局搜索页按系统返回两次仍停留（P2） |
| `tmp_qb22_68.png` | `pm clear` 后终态（空书架） |
| `logcat_b22.txt` | 分段合并日志（a3/a4/a5/终态），含分隔标题 |
| `logcat_b22_a3/a4/a5/final.txt` | 各场景原始 logcat |
| `exit_info_b22.txt` | `dumpsys activity exit-info io.legado.flutter_legado` |

---

## 九、在线书复测自动刷新

针对第三项（自动刷新书架）在批22 中因「设备只有本地 TXT、按设计不参与 TOC 更新」而无法判定的问题，本节改用宿主 HTTP 构造可控在线书源复测。只取证，未改代码。

### 9.1 构造与口径

| 项 | 内容 |
|---|---|
| 宿主 HTTP | `python -m http.server 8091 --bind 0.0.0.0`，文档根 `C:/Users/admin/AppData/Local/Temp/qa_b22/http/`；全部夹具已存档到 `docs/materials_1113a/qa22_fixtures/`（`source.json`、`search.html`、`book_3ch.html`、`book_5ch.html`、`ch1..ch5.html`、`save_book_qa22.json`、`stale_book_qa22.json`、`progress_qa22.json`） |
| 书源 | `bookSourceUrl=http://192.168.100.52:8091/qa22`，`searchUrl→search.html`，`ruleToc=class.chapter / text / href`，`ruleContent=class.content@html`；设备「我的 → 书源管理 → 更多选项 → 本地导入」导入成功（`tmp_qb22_refresh_01_source_imported.png`） |
| 书籍 | 「QA批22在线书」，`bookUrl=http://192.168.100.52:8091/qa22/book.html`；宿主目录第一阶段 3 章、第二阶段 5 章 |
| 入架方式 | 应用内 Web 服务 `192.168.100.63:1122` `POST /saveBook` 种入书架；`GET /getChapterList` 实测由书源规则解析出 ch1–ch3（标题/URL 与 `book.html` 一致），证明书源规则链路真实执行（`tmp_qb22_refresh_01b_getchapterlist.txt`）。未用 UI 搜索入架：Flutter 搜索框对 `adb shell input text` 注入无响应（IME 已连接但文本不入框），改用批20/21 已登记的 Web 服务种书路径，不影响刷新链判定 |
| 时钟 | 宿主与设备存在约 13 s 时钟偏差（设备快）；下文时间线以设备 logcat 为准，宿主访问日志时间需 +13 s 对齐 |

### 9.2 结果

| 项 | 结果 | 证据 | 说明 |
|---|---|---|---|
| 1. 在线书源构造、导入与规则可执行 | PASS | `tmp_qb22_refresh_01_source_imported.png`、`tmp_qb22_refresh_01b_getchapterlist.txt`、`qa22_fixtures/source.json`、`host_http_8091_access.log` | 导入后设备出现「QA批22在线书源（QA）开启」；`/getChapterList` 返回 3 章，证明搜索/目录规则解析真实生效 |
| 2. 自动刷新 ON 冷启动（宿主 3 章、书目录已同步） | PASS | `tmp_qb22_refresh_09_auto_refresh_on.png`、`tmp_qb22_refresh_10_scenario1_nochange.png`、`logcat_b22_refresh_s1.txt`、`host_http_8091_access.log` | 日志 `尝试 1，更新 0，无变化 1，失败 0，新增 0 章`；宿主在启动后约 2 s 收到 `GET /qa22/book.html`（03:30:06 宿主 / 03:30:19 设备）。无「已更新」提示符合「目录无实变不打扰」设计；种书时 `/getChapterList` 已把目录同步为 3 章，故无差异 |
| 3. 目录实变时出现「已更新 N 本书的目录」提示 | PASS | `tmp_qb22_refresh_19a_scenario1b_notice_1.png`、`logcat_b22_refresh_s1b.txt`、`tmp_qb22_refresh_19b_bookshelf_after_s1b.txt` | 将书元信息重置为 2 章（宿主仍 5 章）后冷启动：SnackBar「已更新 1 本书的目录，新增 3 章」，日志 `更新 1，新增 3 章`；刷新后书架元信息为 total=5 / 末章「第5章 新增乙」，2→5 与差值一致 |
| 4. 新增章节验证（宿主 3 章 → 5 章） | PASS | `tmp_qb22_refresh_11_scenario2_notice.png`、`logcat_b22_refresh_s2.txt`、`host_http_8091_access.log` | 宿主 `book.html` 增为 5 章后冷启动：SnackBar「已更新 1 本书的目录，新增 2 章」，日志 `尝试 1，更新 1，无变化 0，新增 2 章`；书架未读角标 2→4 |
| 5. 仅更新已读完 + 有未读章节 → 不刷新 | PASS | `tmp_qb22_refresh_12_only_read_on.png`、`13_scenario3_skip.png`、`logcat_b22_refresh_s3.txt` | 两开关均 ON；书 total=5、durChapterIndex=0（未读 4）：日志 `没有符合刷新条件的书籍，跳过`，宿主 0 请求、无提示 |
| 6. 正控：仅更新已读完 + 已读至末章 → 刷新 | PASS | `tmp_qb22_refresh_16_scenario3b_readall_refresh.png`、`logcat_b22_refresh_s3b.txt`、`tmp_qb22_refresh_15_bookshelf_before_readall.txt` | `/saveBookProgress` 置 durChapterIndex=4 后冷启动：日志 `尝试 1，更新 0，无变化 1`，宿主收到 `GET /qa22/book.html`；同书同设置仅进度不同即不再跳过，排除「无书可刷」歧义 |
| 7. 关闭自动刷新 → 冷启动 0 条刷新日志 | PASS | `tmp_qb22_refresh_17_auto_refresh_off.png`、`18_scenario4_off.png`、`logcat_b22_refresh_s4.txt` | 关闭后冷启动 13 s：`[AutoRefreshBook]` 计数 0，宿主 0 请求；「仅更新已读完」行随开关消失 |
| 8. 稳定性：五项崩溃计数 | PASS | `logcat_b22_refresh_s1/s1b/s2/s3/s3b/s4.txt`、`logcat_b22_refresh_terminal.txt`、`exit_info_b22_refresh.txt` | 六份日志：`FATAL EXCEPTION`=0、`ANR in`=0、`E/flutter`=0、`RenderFlex overflowed`=0、`E AndroidRuntime`=0、`OutOfMemory`=0；exit-info 仅 `USER REQUESTED(FORCE STOP)` 与一条历史的 `PACKAGE UPDATED`，无 CRASH/ANR/LOW_MEMORY；crash buffer 为空 |
| 9. 清理与设备终态 | PASS | `tmp_qb22_refresh_20_terminal.png`、`logcat_b22_refresh_terminal.txt`、`exit_info_b22_refresh.txt` | 应用内 Web 服务关闭（`/api/health` exit 7、`:1122` LISTEN 0）；宿主 8091 停止（`curl` exit 7）；`/sdcard/Download/qa22_source.json` 等测试文件已删；`pm clear io.legado.flutter_legado` 返回 `Success`，重启后空书架；APK 仍为 2.0.492 / 493，sha256 `fe6256a2…8bc2cc4b`；设备保持在线 `192.168.100.63:5555` |

### 9.3 logcat 关键行

```
# 第 2 项（宿主 3 章、书目录已同步；刷新执行但无变更）
11-13 03:30:19.267 18619 18619 I flutter : [AutoRefreshBook] 完成：尝试 1，更新 0，无变化 1，被取代 0，失败 0，新增 0 章
# 第 4 项（宿主 3→5 章）
11-13 03:31:02.427 18761 18761 I flutter : [AutoRefreshBook] 完成：尝试 1，更新 1，无变化 0，被取代 0，失败 0，新增 2 章
# 第 5 项（仅更新已读完 + 未读）
11-13 03:32:12.950 19092 19092 I flutter : [AutoRefreshBook] 没有符合刷新条件的书籍，跳过
# 第 6 项（正控：已读至末章）
11-13 03:33:49.974 19389 19389 I flutter : [AutoRefreshBook] 完成：尝试 1，更新 0，无变化 1，被取代 0，失败 0，新增 0 章
# 第 3 项（元信息 2 章、宿主 5 章）
11-13 03:37:18.802 20046 20046 I flutter : [AutoRefreshBook] 完成：尝试 1，更新 1，无变化 0，被取代 0，失败 0，新增 3 章
# 第 7 项（自动刷新关闭）：0 条
```

宿主访问日志（`host_http_8091_access.log`，设备 IP `192.168.100.63`；宿主时间 +13 s ≈ 设备时间）：

```
192.168.100.63 - - [13/Nov/2026 03:30:06] "GET /qa22/book.html HTTP/1.1" 200 -   # 第 2 项
192.168.100.63 - - [13/Nov/2026 03:30:49] "GET /qa22/book.html HTTP/1.1" 200 -   # 第 4 项
192.168.100.63 - - [13/Nov/2026 03:33:37] "GET /qa22/book.html HTTP/1.1" 200 -   # 第 6 项
192.168.100.63 - - [13/Nov/2026 03:37:06] "GET /qa22/book.html HTTP/1.1" 200 -   # 第 3 项
```

第 5 项（跳过）与第 7 项（关闭）期间宿主无任何请求。

### 9.4 结论

**自动刷新生效。** 在线书在冷启动后 2 s 内触发逐本 `refreshToc`，真实请求书源目录页；目录增长时按差值提示「已更新 1 本书的目录，新增 N 章」（3→5 为「新增 2 章」），无变化时不提示；「仅更新已读完」能按未读章节数正确过滤（未读跳过、已读完放行）；关闭开关后无任何刷新副作用。

计数：**9 PASS / 0 FAIL / 0 BLOCKED**。批22 原第 3 项（自动刷新提示）与原第 4 项（仅更新已读完）由 **BLOCKED 改判 PASS**。

### 9.5 边界与说明（P3）

- 本节使用宿主 HTTP 构造书源，不是真实互联网站点；已覆盖「网络请求 → 规则解析 → 目录落库 → 书架重载 → SnackBar」全链，但不覆盖真实站点的反爬/动态 JS 场景。
- 入架方式与清单有偏差：搜索框无法接受 `adb shell input text` 注入，改用应用内 `/saveBook` 种书；书源规则的可执行性另由 `/getChapterList` 独立证明（解析出与夹具一致的 3 章）。
- 导航过程中误触「MCP 服务」行，出现既有防御提示「MCP 服务切换失败…请先配置 Web 书源访问令牌」；非崩溃、与本批改动无关（批20 已登记同类 P3）。
- 自动刷新为**进程内单次**语义（`_ran` 守卫）：同一次启动内不重复执行，与实现注释一致；本节每个场景均以 force-stop + 冷启动取证。

### 9.6 本节证据索引（`docs/materials_1113a/`）

| 文件 | 内容 |
|---|---|
| `tmp_qb22_refresh_00_baseline.png` | 起始空书架（pm clear 后） |
| `tmp_qb22_refresh_01_source_imported.png` | 本地导入「QA批22在线书源」完成 |
| `tmp_qb22_refresh_01b_getchapterlist.txt` | `/getChapterList` 运行时响应留存（解析出 ch1–ch3） |
| `tmp_qb22_refresh_06_web_service.png` | Web 服务开启 `http://192.168.100.63:1122` |
| `tmp_qb22_refresh_07_shelf_before_coldstart_empty.png` | 种书后未重启，书架尚未重载（空） |
| `tmp_qb22_refresh_08_auto_refresh_off.png` / `09_auto_refresh_on.png` | 自动刷新关闭 / 开启（开启后「仅更新已读完」出现） |
| `tmp_qb22_refresh_10_scenario1_nochange.png` | 3 章冷启动：无提示，书未读角标 2 |
| `tmp_qb22_refresh_11_scenario2_notice.png` | 5 章冷启动：SnackBar「已更新 1 本书的目录，新增 2 章」，角标 4 |
| `tmp_qb22_refresh_12_only_read_on.png` | 自动刷新 + 仅更新已读完均 ON |
| `tmp_qb22_refresh_13_scenario3_skip.png` | 未读章节存在时跳过刷新（无提示，角标 4） |
| `tmp_qb22_refresh_16_scenario3b_readall_refresh.png` | 已读至末章后的书架（无未读角标） |
| `tmp_qb22_refresh_17_auto_refresh_off.png` / `18_scenario4_off.png` | 自动刷新关闭态 / 关闭后冷启动无提示 |
| `tmp_qb22_refresh_19a_scenario1b_notice_1.png` | 元信息滞后（2 章）冷启动：SnackBar「新增 3 章」 |
| `tmp_qb22_refresh_20_terminal.png` | `pm clear` 后重启空书架终态 |
| `logcat_b22_refresh_s1/s1b/s2/s3/s3b/s4.txt` | 各场景原始 logcat |
| `logcat_b22_refresh_terminal.txt` | 清数据后重启终态 logcat（`AutoRefreshBook` 0 条） |
| `host_http_8091_access.log` | 宿主 8091 访问日志（证明真实网络请求） |
| `exit_info_b22_refresh.txt` | `dumpsys activity exit-info io.legado.flutter_legado` |
| `tmp_qb22_refresh_15_bookshelf_before_readall.txt` / `15b_progress.json` | 正控前书架元信息与进度写入体 |
| `tmp_qb22_refresh_19b_bookshelf_after_s1b.txt` | 第 3 项刷新后的书架元信息（total=5） |
| `qa22_fixtures/` | 书源 JSON、搜索页、3 章/5 章目录页、章节页、saveBook / stale saveBook / saveBookProgress 请求体 |

编写：QA 子代理 ｜ 2026-11-13
