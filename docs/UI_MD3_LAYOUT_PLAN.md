# 分批全量二三级重排 + 动效全补实施规划

> 版本：v1.0 ｜ 日期：2026-09-04 ｜ 编写：Qoder
> 依据：`docs/UI_MD3_LAYOUT_MOTION_AUDIT.md`（全局标尺+原则）+ 三路 Explore 只读深挖
> 用户已定：暂不做 MD3/原版切换 / 分批全量二三级重排 / 动效缺口全补

---

## 一、已确认结论

- AUDIT 文档含布局调整（全局标尺一节 + 顶栏导航设置行动效原则），但缺 60+ 二三级逐页红线——本规划补齐。
- 目标仓皮肤切换为 M3/Miuix 双引擎，与本地诉求（MD3/原版）不对版；本地暂不做切换开关，MD3 单风格做到位。
- 动效缺口：转场无分档、Skeleton 零调用、Contained 缺失、下拉旧式——本轮全补。

---

## 二、批次设计（分批全量，约 14 天）

### P1 主链二三级（4 天）

| 页组 | 文件 | 对标目标 |
|---|---|---|
| 书籍详情三级 | `edit_book_info_screen.dart`、`change_cover_screen.dart`、`toc_screen.dart`（书签/标注 Tab）、`bookmark_screen.dart`、`search_content_screen.dart`、`cache_download_screen.dart` | BookInfo 链路：透明顶栏信息架构 + 表单卡片分组 + 操作行规范 |
| 阅读链 | `reader_config_panel*.part.dart`、`font_screen.dart`、`highlight_rules_screen.dart`、`read_aloud_config_screen.dart` | ReadBookMenu Sheet 体系：配置面板分组 + 开关行规范 |
| 搜索 | `search_content_screen.dart`、`explore_show_screen.dart` | Search 双列表 + 结果 Footer |

### P2 书源规则链（4 天）

| 页组 | 文件 | 对标目标 |
|---|---|---|
| 书源三级 | `source_debug_screen.dart`、`source_import_confirm_screen.dart`、`js_source_edit_screen.dart`、`code_edit_screen.dart`、`curl_analyze_url_sheet.dart`、`source_login_screen.dart`、`webview_login_screen.dart`、`book_source_group_manage_dialog.dart` | BookSource 管理/编辑链：单滚卡片分组 + 字段 Sheet + 调试行规范 |
| 规则三级 | `replace_rules_screen.dart`、`replace_rule_import_confirm_screen.dart`、`txt_toc_rules_screen.dart`、`dict_screen.dart` | 规则列表 + 导入确认 + 字段编辑规范 |
| RSS 三级 | `rss_source_debug_screen.dart`、`rss_source_import_confirm_screen.dart`、`rss_article_detail_screen.dart`、`rss_favorites_screen.dart` | RSS 文章/收藏/调试规范 |

### P3 设置系与通用（3 天）

| 页组 | 文件 | 对标目标 |
|---|---|---|
| 书架管理 | `bookshelf_manage_screen.dart`、`book_group_screen.dart`、`offline_cache_screen.dart`、`cache_settings_screen.dart`、`remote_book_screen.dart`、`file_manage_screen.dart` | FastScroll 网格 + SelectionBottomBar + GroupEditSheet |
| 设置子页 | `auto_task_screen.dart`、`read_record_screen.dart`、`about_screen.dart`、`app_log_screen.dart`、`webdav_settings_screen.dart`、`other_settings_screen.dart` 内三 Dialog | Spliced 分组卡 + 设置行规范（L2 已落地，仅结构对齐） |
| 通用 | `import_screen.dart`、`archive_import_dialog.dart`、`association_import_dialog.dart`、`browser_screen.dart`、`qrcode_screen.dart`、`audio_screen.dart`、`video_screen.dart`、`reader_comic_screen.dart` | 导入确认 + 工具页规范（沉浸域 audio/video/comic 仅顶栏动作行） |

### P4 动效全补（3 天）

| 项 | 内容 |
|---|---|
| 转场分档 | 阅读器 fade 600ms / 详情条件 fade 300ms（Home/ExploreShow/Search 来）/ 其余 slide480+fade360；predictiveBack 门控 |
| Hero 扩展 | 换封面 3 处 + 编辑页 + 分组页补 `book-cover:` tag；flightShuttle 统一封装进 BookCover |
| Skeleton 接线 | 书架/发现/搜索/详情首屏 LoadingIndicator → Skeleton（shimmer 1200ms） |
| Contained 组件 | 新建 ContainedLoadingIndicator 等效组件，替换 explore 等高频小 spinner |
| 下拉 M3 化 | 10+ 裸 RefreshIndicator 统一走 CustomRefreshIndicator（M3 TopCenter） |
| 空态收敛 | EmptyState isLoading/240 宽/SmallTonal 全页；rss_article_detail 自绘空态并入 |
| 阅读器 chrome | 菜单 slide+fade、胶囊 180/220-0.88、搜索 pill |
| 对话框 Sheet | 进场动效按 M3 默认收敛（以主题为准，不逐个定制）；dict loading 换波浪环；bottom_sheet radius 16→28 对齐 Expressive |

---

## 三、文件清单（执行时锁定）

- 改：上述三批约 40 页 + `widgets/` 通用件 + `app_theme.dart`（转场分档/Contained）+ `routes.dart`（条件转场）。
- 不改：调色板数值、Rust、haze/liquid/blur/字体、manga/review 沉浸本体、cupertino 依赖、bottomBar 皮肤、响应式双栏、已落地的 L1/L2/L3/M1/M2。

---

## 四、验收门禁

- 每批 `flutter analyze 0 + flutter test` 全绿（含 palette/acceptance_matrix 回归 + 受影响 widget 断言同步）。
- 逐屏对 `baseline_android/` 功能一致（视觉不像素验收）。
- `emulator_smoke_test.ps1 -Device emulator-5556 -CheckUI`（5558 用户验收）；iOS 以 ios-build.yml 为准。
- 版本按批递增 + CHANGELOG/应用内 updateLog 双同步。

---

## 五、风险回滚（PS7 专属）

- 唯一执行器 `pwsh.exe -NoProfile -ExecutionPolicy Bypass`。
- revert 逆序 LIFO（含 ccb6cd86e0/37f97f5350/7e4adb1456/007b19a1cb/5d23c32867/71b22add5c/19fc1e5c78）；超 500 行按屏拆；FRB 三连 hash 核对；CI 重跑限定 fork 仓。

---

编写者：Qoder ｜ 2026-09-04
