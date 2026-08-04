# UI 一致性修复与 E2E 阅读链路验证 — 最终报告

日期：2026-08-04
范围：Flutter 重构版（flutter_legado）vs 原版 Android（app/）界面对比修复 + yckceo 7631 书源端到端验证。

## 1. 目标回顾

1. 系统性对比 Flutter 界面与原版 Android 布局/菜单（fragment_bookshelf1.xml、main_bookshelf.xml、BookSourceActivity 等），识别并修复差异。
2. 修复用户反馈的已知问题（书架加号、更多菜单、发现页分组、订阅页 FAB/搜索框、订阅源管理菜单、状态栏全白）。
3. 使用书源 https://www.yckceo.com/yuedu/shuyuan/json/id/7631.json 端到端验证「导入→搜索→详情→加书架→阅读」全链路，以模拟器截图为证据。

## 2. UI 对比修复（ui1–ui5，均已在模拟器验证）

| # | 问题 | 修复 | 证据 |
|---|------|------|------|
| ui1 | 书架有原版不存在的加号 FAB | 移除 FAB，顶栏保留 搜索+视图切换+三点菜单（对齐 main_bookshelf.xml） | `_ui_final_02_after_skip.png` |
| ui2 | 书架更多菜单缺项 | 对齐原版：更新目录/添加本地/添加远程书籍/添加网址/书架管理/缓存导出/分组管理/书架布局/不分组·按来源分组·按分组显示 | `_ui_final_03_bookshelf_menu.png` |
| ui3 | 发现页右上角误用「筛选」按钮 | 改为原版分组按钮（多人图标，对齐 menu_main_explore.xml） | `_ui_final_04_explore.png` |
| ui4 | 订阅页存在多余 FAB、顶栏无搜索框 | 移除 FAB；顶栏下增加搜索框「订阅」；顶栏图标对齐（刷新/收藏/分组/设置） | `_ui_final_05_rss.png` |
| ui5 | 订阅源管理/书源管理菜单不一致 | 订阅源管理：添加订阅源/本地导入/网络导入/二维码导入/导入默认规则/帮助；书源管理：添加书源/新建 JS 书源/本地导入/网络导入/二维码导入/按域名拆分分组/帮助/从剪贴板导入/导出全部书源/导出选中分组/导出到文件/批量操作 | `_ui_final_06/07/09/10_*.png` |
| ui6 | 顶部状态栏全白不可见 | AppBar/系统栏前景色修复，状态栏图标可见 | 全部截图（时间/WiFi/电量清晰可见） |

「我的」页条目与原版设置项对齐：书源管理/定时任务/定时任务服务/TXT 目录规则/替换净化/词典规则/主题模式/Web 服务/MCP 服务/设置-备份恢复/其他（书签/阅读记录/文件管理/关于/退出/导出日志）。证据：`_ui_final_08/11/12_*.png`。

## 3. E2E 阅读链路：根因与修复（本次会话）

集成测试：`flutter_legado/integration_test/e2e_search_read_test.dart`（自包含：在线下载 yckceo 7631 → 导入 → 搜索「都市」→ 详情 → 加书架 → 打开阅读）。最终 run17/run18 均 `All tests passed`（00:57）。

| # | 根因 | 修复文件 |
|---|------|----------|
| 1 | Dart 无筛选时传 `'[]'`，Rust `load_search_sources` 把空数组当精确过滤条件 → 0 书源 | `rust/legado-ffi/src/api/search.rs`：空串与 `'[]'` 均视为「搜全部」+ 回归测试 |
| 2 | FFI `search_books` 序列化内部 snake_case 结构，Dart `SearchBook.fromJson` 期望 camelCase | `rust/legado-ffi/src/ffi.rs`：映射为 `legado_core::models::SearchBook`（serde camelCase） |
| 3 | 搜索加入书架的书本地无目录，阅读器只查 DB → 「暂无内容」 | `lib/src/providers/reader/reader_notifier.dart`：chapters 为空且 origin 非空时自动 `refreshToc` |
| 4 | 书源 `loginCheckJs` 依赖 `java.*`/`cookie.*`/`result.body()` 等原版运行时对象，QuickJS 抛异常被升级为致命错误阻断详情/目录/正文 | `rust/legado-ffi/src/api/web_book.rs` `execute_login_check`：执行失败降级为日志放行（对齐原版语义：loginCheckJs 仅登录态检查） |
| 5 | `AnalyzeRule` 不支持裸提取关键字（`text`/`textNodes`/`ownText`/`html`/`allText`）与裸属性名（`href`），且元素提取结果错误去重 → 目录 5862 元素解析后仅剩 1 章 | `rust/legado-parser/src/html.rs`：① 裸关键字直接对当前内容提取（对标 Kotlin AnalyzeByJSoup getResultLast）② 选择器无结果且规则为裸 token 时按属性名从当前元素提取 ③ 去重仅限属性提取路径（text/html 逐元素保留） |
| 6 | 正文加载成功后，`_paginateIfNeeded` 在 build 阶段同步修改 provider → Riverpod 断言崩溃 | `lib/src/widgets/reader/reader_page_view.dart`：`updateChapterPageCount` 包进 `Future(() => ...)` 延迟到下一帧 |

Host 侧诊断测试（`cargo test -p legado-ffi read_chain --features quickjs -- --ignored --nocapture`）：
- 目录 5862 章，第一章《第一章 女模特和穷小子》url 正确绝对化
- 正文 2315 字真实内容

## 4. E2E 截图证据（run18，`_e2e_seq_*.png`）

| 阶段 | 截图 | 内容 |
|------|------|------|
| 搜索结果 | seq_04~06 | 搜索「都市」返回结果列表 |
| 书籍详情 | seq_07~10 | 《都市逍遥邪医（都市超级邪医林辰苏夕然）》详情对话框 + 加入书架按钮 |
| 书架 | seq_14~17 | 新书显示在书架，顶栏无加号按钮 |
| 阅读页 | seq_19~27 | **正文渲染成功**：第一章 女模特和穷小子，页码 1/4，正文段落正常排版 |

## 5. 回归验证

- `cargo test -p legado-parser`：120 项全部通过（含新增裸关键字/属性去重测试）
- `cargo test -p legado-ffi --features quickjs -- --test-threads=1`：121 项全部通过
- 集成测试 run17/run18：All tests passed
- 模拟器实机（emulator-5556，release APK）：书架/发现/订阅/订阅源管理/书源管理/我的 各页面与菜单截图核对原版一致

## 6. 书架分组 Tab 对齐与实机验证（2026-08-01 补充）

对标原版 `fragment_bookshelf1.xml`（TitleBar 内嵌 TabLayout）+ `BookshelfFragment1`（Tab 位置持久化）：
多分组时书架顶栏显示可滚动分组 Tab，`currentGroupBooks` 按 book.group 位掩码过滤，支持 全部/本地/音频/视频/未分组 特殊组。

实机验证中修复两处阻塞缺陷：

| # | 问题 | 修复 |
|---|------|------|
| 1 | Rust `BookGroupDto` 输出 snake_case，Dart `BookGroup.fromJson` 期望 camelCase → 分组名解析为空、Tab 不显示 | `book_group_api.rs` 加 `#[serde(rename_all = "camelCase")]` + `test_dto_serializes_camel_case` 回归测试 |
| 2 | TabController 在 build 期间同步 index 与 TabBar 内部状态竞争 → 点击 Tab 无响应 | `bookshelf_screen.dart` 改 listener 驱动（controller 变化→selectGroup；状态变化→postFrame animateTo） |

验证结果（emulator-5556）：双 Tab「全部」+「TestGroup」渲染、点击切换指示器移动（裁剪放大确认）、Tab 位置重启后恢复、空分组空态正常。证据：`_group_tab_21_loaded.png` / `_group_tab_25_crop.png` / `_group_tab_26_search.png`。

回归：书架相关 52 项单测/组件测试全部通过；`flutter analyze lib` 无 error/warning；`cargo test -p legado-ffi book_group` 通过。另修复 `rust/scripts/build-android.ps1` 交叉编译环境问题（全局 CC 污染宿主机构建 → 改 target 限定 `CC_<triple>`）。

## 7. 结论

- 用户反馈的 6 项 UI 差异全部修复并有模拟器截图证据。
- 指定书源 yckceo 7631 完成「导入→搜索→详情→加书架→阅读正文」端到端验证。
- 期间发现并修复 6 个阻断性根因（4 个 Rust 引擎语义问题、1 个 Dart 懒加载缺失、1 个 Riverpod 生命周期问题），均附带回归测试或集成测试覆盖。
