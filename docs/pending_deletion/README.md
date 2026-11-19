# 待删除素材暂存（pending deletion）

本目录存放已移出正式资源目录、等待最终删除的素材文件。

## 当前状态：已清空（2026-11-20）

三类历史待删素材已于 2026-11-20 批次（基线 `c3d95bda8e`）全部 `git rm`，本目录现仅剩本 README。

| 原内容 | 移出日期 | 删除日期 | 删除前复核方法 |
|---|---|---|---|
| `assets_icons_unused/`（8 个 `ic_bottom_*.svg`） | 2026-09-30 | 2026-11-20 | 全仓文本扫描（17,752 文件）：`flutter_legado/` 内命中 0；`assets/icons/` 目录已不存在且 `pubspec.yaml` 无该声明；命中项仅为 `docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md` 的登记文本与 Android 侧同名 **XML**（`app/src/main/res/drawable/ic_bottom_*.xml`，是另一套矢量资源，非这些 SVG） |
| `web_dist_custom_index/`（自制首页 9,536B + README） | 2026-10-06 | 2026-11-20 | 删除前确认 `rust/legado-server/web-dist/index.html` 已存在且为原版导航页（`<title>Legado web 导航</title>`，2,210B）；`web_dist_custom_index` 字样仅出现在 `docs/` 的登记与历史报告，代码/构建脚本零引用 |
| `lib/src/widgets/`（7 个零引用 Dart 组件） | 2026-11-17 | 2026-11-20 | 见下节复核结论 |

### 7 个 Dart 组件的删除前复核（2026-11-20 独立重跑）

扫描范围：`flutter_legado/lib` + `flutter_legado/test` + `flutter_legado/integration_test`（1,130 个 `.dart/.yaml/.json/.txt/.md` 文件）+ `pubspec.yaml` / `pubspec.lock` / `analysis_options.yaml`。

| 类名 | 定义文件 | 类名命中 | 文件名/import 命中 |
|---|---|---|---|
| `BadgeWidget` | `badge_widget.dart` | 0 | 0（`badge_widget_` 仅作 `Directory.systemTemp.createTemp('badge_widget_')` 临时目录前缀，与组件无关） |
| `ChapterTile` | `chapter_tile.dart` | 0 | 0 |
| `CustomProgress` | `custom_progress.dart` | 0 | 0 |
| `SearchBarWidget` | `search_bar_widget.dart` | 0 | 0 |
| `SourceCard` | `source_card.dart` | 0 | 0 |
| `SwipeAction` / `SwipeActionItem` | `swipe_action.dart` | 0 / 0 | 0 |
| `TagChip` | `tag_chip.dart` | 0 | 0 |

- 方法：Python（UTF-8）对每个类名做 `\b<类名>\b` 全词匹配，对文件名做子串匹配，逐条输出命中文件与行号后人工判读。
- 另核实：`lib/` 内无 barrel 汇总导出、无 `part`/`part of` 关联、无字符串形式引用。
- 结论：**7/7 零引用确认成立**，与 2026-11-17 登记口径一致。
- 删除后门禁：`flutter analyze --no-fatal-infos` → `No issues found!`

## 历史记录（保留供追溯）

### `assets_icons_unused/`（2026-09-30 移入，2026-11-20 删除）

- 来源：`flutter_legado/assets/icons/ic_bottom_*.svg` 共 8 个底部导航图标
- 依据：全仓（lib/ + test/）零引用（调研报告 `docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md` §3 终核 grep=0），疑似早期底部导航方案的遗留素材
- 用户裁决（2026-09-30）：先移动到待删除目录，暂不直接删除
- 同步改动：`flutter_legado/pubspec.yaml` 已移除 `- assets/icons/` 声明（目录已空，保留声明会导致构建报错）

### `web_dist_custom_index/`（2026-10-06 移入，2026-11-20 删除）

- 来源：`rust/legado-server/web-dist/index.html` 自制 Web 首页（9,536B）
- 依据：Web 服务页面与原版保持一致，原版前端资产（`app/src/main/assets/web/**`，67 文件）已整目录拷入 `web-dist/` 并编译期嵌入，自制页与同名 `index.html` 冲突
- 用户裁决（2026-10-06）：Web 服务书架页面必须与原版一致；自制页不再作为 `/` 的响应内容

### `lib/src/widgets/`（2026-11-17 移入，2026-11-20 删除）

7 个组件原在 `flutter_legado/lib/src/widgets/`，经全 `lib/` 逐类名 grep 核实生产引用为零，仅被同名测试文件引用。

| 文件 | 主类 | 原引用方（2026-11-17 已处理） |
|---|---|---|
| `search_bar_widget.dart` | `SearchBarWidget` | `test/widget/search_bar_widget_test.dart`（已删）、`test/widget/input_none_seal_test.dart`（已删该用例） |
| `swipe_action.dart` | `SwipeAction` / `SwipeActionItem` | `test/widget/swipe_action_test.dart`（已删） |
| `source_card.dart` | `SourceCard` | `test/widget/source_card_test.dart`（已删） |
| `tag_chip.dart` | `TagChip` | `test/widget/tag_chip_test.dart`（已删） |
| `badge_widget.dart` | `BadgeWidget` | `test/widget/badge_widget_test.dart`（已删） |
| `chapter_tile.dart` | `ChapterTile` | `test/widget/chapter_tile_test.dart`（已删） |
| `custom_progress.dart` | `CustomProgress` | `test/widget/custom_progress_test.dart`（已删） |

- 2026-11-17 已完成：`git mv` 7 个文件入本目录；`git rm` 7 个专属测试；裁剪 `input_none_seal_test.dart` 中依赖 `SearchBarWidget` 的用例；`flutter analyze --no-fatal-infos` 0 warning、`flutter test` 全绿。
- 2026-11-20：复核零引用成立后 `git rm` 7 个文件。

## 后续新建待删目录的约定

1. 移入前先在正式目录做全仓 grep 终核，并在本 README 登记来源、日期、依据、用户裁决。
2. 观察期结束后整体 `git rm`，删除前**再跑一次终核**（防止观察期内被重新引用）。
3. 本目录位于 `docs/` 下、不在 pubspec assets 声明内，不会打进应用包。
