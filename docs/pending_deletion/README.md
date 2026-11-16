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

## 已核实零引用、待移入（2026-11-17 登记，尚未移动）

以下 7 个组件（均在 `flutter_legado/lib/src/widgets/`）经全 `lib/` 逐类名 grep 核实**生产引用为零**，仅被同名测试文件引用。按项目约定应移入本目录后观察，再整体删除。

| 文件 | 主类 | 生产引用 | 仅存引用方 |
|---|---|---|---|
| `search_bar_widget.dart` | `SearchBarWidget` | 0 | `test/widget/search_bar_widget_test.dart`、`test/widget/input_none_seal_test.dart` |
| `swipe_action.dart` | `SwipeAction` / `SwipeActionItem` | 0 | `test/widget/swipe_action_test.dart` |
| `source_card.dart` | `SourceCard` | 0 | `test/widget/source_card_test.dart` |
| `tag_chip.dart` | `TagChip` | 0 | `test/widget/tag_chip_test.dart` |
| `badge_widget.dart` | `BadgeWidget` | 0 | `test/widget/badge_widget_test.dart` |
| `chapter_tile.dart` | `ChapterTile` | 0 | `test/widget/chapter_tile_test.dart` |
| `custom_progress.dart` | `CustomProgress` | 0 | `test/widget/custom_progress_test.dart` |

- 核实方法：`grep -rn "\b<类名>\b" flutter_legado/lib --include="*.dart"`，排除定义文件自身后结果为 0；另确认无 barrel/part 间接导出（`lib/` 内无 `widgets.dart` 汇总导出）。
- **为何尚未移动（2026-11-17）**：① 当批任务边界禁止触碰 `flutter_legado/lib/**`（其他并行线正在改动该目录）；② 移动会同时破坏上述 8 个测试文件的 import，属代码改动，超出当批「仅文档改动」门禁。
- **后续处置**：待并行线交付后，下一批清理时把 7 个文件 `git mv` 入本目录，并同步删除/迁移对应 8 个测试文件，然后跑 `flutter analyze && flutter test` 验证；观察期无问题后整体 `git rm`。

> 注意：本目录位于 `docs/` 下、不在 pubspec assets 声明内，不会打进应用包。
