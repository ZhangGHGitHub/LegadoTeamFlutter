# 待删除素材暂存（pending deletion）

本目录存放已移出正式资源目录、等待最终删除的素材文件。

## 当前内容

- `assets_icons_unused/`：`flutter_legado/assets/icons/ic_bottom_*.svg` 共 8 个底部导航图标
  - 移出日期：2026-09-30
  - 依据：全仓（lib/ + test/）零引用（调研报告 `docs/LOADING_ASSETS_UNIFY_SURVEY_20260930.md` §3 终核 grep=0），疑似早期底部导航方案的遗留素材
  - 用户裁决（2026-09-30）：先移动到待删除目录，暂不直接删除
  - 后续处置：观察期无问题后，下一批清理时 `git rm` 本目录整体删除；删除前建议再跑一次全仓 grep 终核
- 同步改动：`flutter_legado/pubspec.yaml` 已移除 `- assets/icons/` 声明（目录已空，保留声明会导致构建报错）
- `web_dist_custom_index/`：`rust/legado-server/web-dist/index.html` 自制 Web 首页（9,536B）
  - 移出日期：2026-10-06
  - 依据：Web 服务页面与原版保持一致，原版前端资产（`app/src/main/assets/web/**`，67 文件）已整目录拷入 `web-dist/` 并编译期嵌入，自制页与同名 `index.html` 冲突
  - 用户裁决（2026-10-06）：Web 服务书架页面必须与原版一致；自制页不再作为 `/` 的响应内容
  - 后续处置：观察期无问题后，下一批清理时 `git rm` 本目录整体删除；详见 `web_dist_custom_index/README.md`

- `lib/src/widgets/`：7 个零引用死代码组件（`search_bar_widget.dart`、`swipe_action.dart`、`source_card.dart`、`tag_chip.dart`、`badge_widget.dart`、`chapter_tile.dart`、`custom_progress.dart`）
  - 移出日期：2026-11-17
  - 依据：全 `lib/` 逐类名 grep（`SearchBarWidget` / `SwipeAction` / `SwipeActionItem` / `SourceCard` / `TagChip` / `BadgeWidget` / `ChapterTile` / `CustomProgress`）排除定义文件后命中 0；另核实无 barrel 汇总导出、无 `part`/`part of` 关联、无字符串引用
  - 同步改动：删除 7 个同名专属测试文件；`test/widget/input_none_seal_test.dart` 移除依赖 `SearchBarWidget` 的单个用例（其余 4 个用例保留）
  - 后续处置：观察期无问题后，下一批清理时 `git rm` 本目录整体删除；删除前建议再跑一次全仓 grep 终核

## 已核实零引用、待移入（2026-11-17 登记，同日已移入）

以下 7 个组件（原在 `flutter_legado/lib/src/widgets/`）经全 `lib/` 逐类名 grep 核实**生产引用为零**，仅被同名测试文件引用。按项目约定已移入本目录 `lib/src/widgets/` 观察，再整体删除。

| 文件（已移入 `lib/src/widgets/`） | 主类 | 生产引用 | 原引用方（已处理） |
|---|---|---|---|
| `search_bar_widget.dart` | `SearchBarWidget` | 0 | `test/widget/search_bar_widget_test.dart`（已删）、`test/widget/input_none_seal_test.dart`（已删该用例） |
| `swipe_action.dart` | `SwipeAction` / `SwipeActionItem` | 0 | `test/widget/swipe_action_test.dart`（已删） |
| `source_card.dart` | `SourceCard` | 0 | `test/widget/source_card_test.dart`（已删） |
| `tag_chip.dart` | `TagChip` | 0 | `test/widget/tag_chip_test.dart`（已删） |
| `badge_widget.dart` | `BadgeWidget` | 0 | `test/widget/badge_widget_test.dart`（已删） |
| `chapter_tile.dart` | `ChapterTile` | 0 | `test/widget/chapter_tile_test.dart`（已删） |
| `custom_progress.dart` | `CustomProgress` | 0 | `test/widget/custom_progress_test.dart`（已删） |

- 核实方法：`grep -rn "\b<类名>\b" flutter_legado/lib --include="*.dart"`，排除定义文件自身后结果为 0；另确认无 barrel/part 间接导出（`lib/` 内无 `widgets.dart` 汇总导出）、无 `part of` 关联、无字符串引用。
- 移动前复核实测（2026-11-17，基线 `7a1c4b5554`）：8 个类名在 `lib/` 内除各自定义文件外命中 0；文件名 import 仅出现在上述 8 个测试文件中。
- **已完成动作（2026-11-17）**：`git mv` 7 个文件入本目录；`git rm` 7 个专属测试；裁剪 `input_none_seal_test.dart` 中依赖 `SearchBarWidget` 的用例；`flutter analyze --no-fatal-infos` 0 warning、`flutter test` 全绿。
- **后续处置**：观察期无问题后整体 `git rm`。

> 注意：本目录位于 `docs/` 下、不在 pubspec assets 声明内，不会打进应用包。
