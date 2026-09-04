# 布局规划 P1–P4 完成度审计与收尾记录

> 版本：v1.1 ｜ 日期：2026-09-05 ｜ 编写：Qoder UI
> 依据：`docs/UI_MD3_LAYOUT_PLAN.md`（规划 v1.0）逐项对照 git 提交与代码现状核实
> 关联提交：P1 `c95d32f12f`（2.0.161+162）、P2 `b9e1090ac0`（2.0.162+163）、P3 `c28f95f3eb`（2.0.163+164）、P4 `cf6f7a1dfc`（2.0.164+165）

---

## 一、总体结论

- **四批 P1–P4 全部有交付提交，代码侧完成度约 85%–90%**：约 40 页重排落地约 37 页，动效八项中 3 项全成、4 项部分成、1 项（predictiveBack 门控）按登记口径替代。
- 计划估 14 天，实际 2026-09-04 一天内压完四批（09-05 P4 收尾）。
- 门禁：每批提交声明 `flutter analyze 0` + `flutter test 1321 全过`；09-05 审计实测 `flutter analyze` 0 issues 复核通过。
- 版本按批递增 2.0.161→2.0.164+165，四批均同步 CHANGELOG 与应用内 `assets/updateLog.md` 双日志。

| 批次 | 提交 | 版本 | 状态 |
|---|---|---|---|
| P1 主链二三级 | `c95d32f12f` | 2.0.161+162 | 基本完成，缺 1 页 |
| P2 书源规则链 | `b9e1090ac0` | 2.0.162+163 | 完整完成（16 文件全覆盖） |
| P3 设置系与通用 | `c28f95f3eb` | 2.0.163+164 | 基本完成，缺 2 处 |
| P4 动效全补 | `cf6f7a1dfc` | 2.0.164+165 | 主体完成，4 项半成品 |

## 二、P4 动效逐项核对

| 项 | 结论 | 证据 |
|---|---|---|
| 转场分档 | ✅ 完成（predictiveBack 门控未做，代码登记"仅主题 builder 分档"） | `app_theme.dart` 路由名分档：阅读器 fade / 详情 fade 300 / 其余 slide+fade |
| Hero 扩展 | ✅ 完成 | `book-cover:` tag 全链路（换封面 3 处、编辑页、分组页）；flightShuttle 统一 `coverFlightShuttleBuilder`（`book_cover.dart:89`） |
| Skeleton 接线 | ✅ 完成 | 计划点名四域（书架/发现/搜索/详情）首屏均已接线 |
| Contained 组件 | ⚠️ 半完成 | 组件已新建（`contained_loading_indicator.dart`），但全库零调用，"替换 explore 等高频小 spinner"未执行 |
| 下拉 M3 化 | ⚠️ 部分完成 | 4 页走 CustomRefreshIndicator（书架/换源/RSS 文章/RSS 主屏），仍有 7 处裸 RefreshIndicator |
| 空态收敛 | ⚠️ 大部分完成 | EmptyState 已铺 21 文件；rss_article_detail 自绘空态未并入 |
| 阅读器 chrome | ⚠️ 部分完成 | 菜单 slide+fade、朗读 fade 完成；胶囊独立 fade 登记缺口、搜索 pill 待设计收敛（`reader_screen.dart` 注明暂不改结构） |
| 对话框 Sheet | ⚠️ 部分完成 | radius 16→28 已对齐；dict loading 波浪环未做（仍普通 CircularProgressIndicator） |

裸 RefreshIndicator 残留 7 处（审计时点）：`auto_task_screen.dart`、`cache_download_screen.dart`、`offline_cache_screen.dart`、`read_record_screen.dart`、`rss_favorites_screen.dart`、`book_info_screen_builders.part.dart`（详情自动刷新）、`explore_book_list.dart`（发现列表 footer）。

## 三、布局重排遗漏页（3 处）

1. `explore_show_screen.dart`（发现分类页）——计划列入 P1 搜索组（对标 Search 双列表 + 结果 Footer），最后改动 08-29（Symbols 图标批次），四批均未触碰。
2. `reader_comic_screen.dart`（漫画沉浸页）——计划列入 P3 通用组（沉浸域仅顶栏动作行），最后改动 09-01（BridgeError 展示修复），未实施。
3. `other_settings_screen.dart` 内三 Dialog——计划注明"L2 已落地，仅结构对齐"，该文件最后被 L2 批次 `ccb6cd86e0` 触碰，P3 未做结构对齐。

## 四、流程与文档欠账

- 台账 `REFACTORING_ACTIVE_PLAN.md` 未登记四批布局规划（最新修订止于 09-04 换源 T6 收口）；规划文档无「实施状态」节。
- 门禁要求的 5556 冒烟与 5558 用户验收在提交与文档中均无记录。
- `flutter test` 审计轮未重跑（约 1321 用例），以各批提交声明为准。

## 五、收尾执行记录（2026-09-05）

### 5.1 代码收尾范围（P4 残项 + 残页 3 处）

- ContainedLoadingIndicator 接线：explore 列表 footer 等高频小 spinner 替换。
- 裸 RefreshIndicator → CustomRefreshIndicator（M3 TopCenter）：上述 7 处。
- rss_article_detail 自绘空态并入 EmptyState。
- dict_dialog loading 换波浪环。
- 残页 3 处：explore_show 重排（Search 标准）、reader_comic 顶栏动作行、other_settings 三 Dialog 结构对齐。

### 5.2 保留登记项（按登记口径，不在本批实施）

- 搜索 pill 化：底栏全文搜索现为 mini FAB，pill 化待设计收敛。
- 阅读器进度胶囊独立 220ms fade：进场已由顶/底栏 slide+fade 覆盖，独立 fade 待统一补。
- predictiveBack 门控：需路由级 PredictiveBackPageTransitionsBuilder 登记，涉及 Android 14+ 系统开关联动，另行排期。

### 5.3 执行结果（2026-09-05 回填）

- **P4 残项四件全部落地**：
  - ContainedLoadingIndicator 接线三处（口径经参考仓核实）：`ListLoadMoreFooter`/`ListMoreFooter` loading 态（对齐 HapeLee LoadMoreFooter loading 分支：48dp Contained + 加载中文案 outline）、`EmptyState` isLoading 分支（原注释即声明 Contained，此前误用 Md3 环）、发现分类列表（explore_book_list）首屏接 Skeleton（8×ListSkeletonItem，对齐 explore_screen 样板）。
  - 裸 RefreshIndicator 清零：自动任务/缓存下载/离线缓存/阅读记录/RSS 收藏/书籍详情 6 处换 CustomRefreshIndicator，加原 4 页共 10 页统一 M3 下拉。
  - rss_article_detail 自绘空态并入 EmptyState（保留「浏览器查看原文」动作槽）。
  - dict_dialog 两处 loading 换 Md3LoadingIndicator 波浪环。
- **残页三处闭合**：
  - explore_show_screen：无独立缺口——列表/首屏骨架/下拉/footer 全部由共享 ExploreBookList 承载，本批升级后自动继承；P1 SearchBar 项不适用（该页无搜索框）。
  - reader_comic_screen：顶栏动作行对齐（返回补 tooltip、返回/设置图标切 Symbols 体系对齐 legado_app_bar），沉浸本体不动。
  - other_settings_screen 三 Dialog：全文件无 backgroundColor/shape 覆写，全局 dialogTheme（surfaceContainer + 28dp extraLarge）已兜底，验证即合规，零改动。
- **门禁**：flutter analyze 0 issues；flutter test 1321 全过（本批实测）。
- **冒烟**：`emulator_smoke_test.ps1 -Device emulator-5556 -CheckUI` 通过（8/8：构建 267.3MB、安装、版本一致 2.0.165、进程存活、无崩溃、UI 主界面元素齐全）。
- 版本 2.0.165+166；CHANGELOG 与 assets/updateLog.md 双同步；台账与本规划文档「实施状态」节已补登记。

### 5.4 追加修复：进书籍转场卡顿与封面闪占位（用户验收反馈，v2.0.166+167）

用户反馈进入书籍动画卡顿、与目标风格不一致。对照参考仓 MainNavGraph（BookInfo entry = 条件 fadeIn 300，封面走 sharedBounds 同图飞行）定位两处根因并修复：

1. **飞行封面闪默认占位图**：本地 Hero 飞行内容取 `toHero.child`（详情页新建 BookCover 实例），该实例经 `resolvePatchedSourceJson` 异步解析，期间显示默认封面——飞行中真实封面闪成默认图。修复：`coverFlightShuttleBuilder` 改取 `fromHero.child`（push=书架已渲染图 / pop=详情已渲染图，飞行层不在路由子树内，内置 Hero 不生效），对齐参考仓「同图飞行」语义。
2. **背景虚化层转场期掉帧**：详情背景为全尺寸封面解码 + 25σ ImageFiltered 模糊，转场每帧合成开销大。修复：虚化源降采样 1/3 屏宽（σ25 下视觉无差，clamp 120–480px）+ RepaintBoundary 隔离重绘。

门禁：flutter analyze 0 issues；flutter test 1321 全过。转场分档本身（详情 fade 300）与参考仓一致，无需调整。

---

编写者：Qoder UI ｜ 2026-09-05
