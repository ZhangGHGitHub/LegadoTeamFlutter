# UI MD3 对齐增量差异审计报告（Phase 0）

> 版本：v1.0 ｜ 日期：2026-09-04 ｜ 编写：Qoder
> 输入：`docs/UI_MD3_ALIGNMENT_PLAN.md v1.1` ｜ 锚点 `HapeLee@6dc2972` → 当前 HEAD `0ce6805`
> 方法：主题资源 diff + 消费侧全量 grep（`Colors./Color(0x/AppColors/Cupertino/IosGroup/surfaceVariant`）

---

## 一、主题资源 diff 结论：零差异，无需追新

命令：

```powershell
git -C ".tmp/legado-with-MD3" diff 6dc2972..0ce6805 --stat -- app/src/main/res/values/colors.xml app/src/main/res/values-night/colors.xml app/src/main/res/values/themes.xml app/src/main/res/values-night/themes.xml app/src/main/res/values/styles.xml
```

结果：**零输出（EXIT 0）**——5 个主题资源文件在锚点区间内无任何变更。

总体 diff（613 文件，+23206/−33232）全部位于 View→Compose 清理、测试与构建配置，与 MD3 token 无关。

**结论**：`lib/src/theme/md3_colors.dart`（`tool/gen_md3_colors.py` 消费 `6dc2972`）仍为最新，无需重跑生成器。Batch 0 Flutter 侧降级为**校验**（`md3_palette_test.dart` 全绿即过）。

---

## 二、消费侧全量扫描

### 2.1 硬编码 `Colors./Color(0x`（除 `Colors.transparent`）

按文件命中数（`grep -rn`）：

| 文件 | 命中 | 定性 |
|---|---|---|
| `lib/src/theme/app_colors.dart` | 98 | 兼容层本体，冻结不改（新增代码禁引） |
| `lib/src/screens/reader_comic_screen.dart` | 46 | 沉浸黑域排除（纯黑画廊） |
| `lib/src/widgets/reader/reader_settings_sheet.dart` | 18 | 沉浸域：16 色纸张色板，排除 |
| `lib/src/widgets/reader/review_detail_sheet.dart` | 11 | 沉浸域排除（段评浮层，见 2.2） |
| `lib/src/screens/video_screen.dart` | 11 | 浮层例外，排除 |
| `lib/src/screens/source_debug_screen.dart` | 11 | **需改**：状态语义色（green/orange/blueGrey/red shade） |
| `lib/src/widgets/manga/manga_config_sheet.dart` | 10 | 沉浸域排除 |
| `lib/src/screens/source_screen_builders.part.dart` | 10 | **需改**：`AppColors.iosGreen/iosRedLight` 状态点 |
| `lib/src/screens/rss_source_debug_screen.dart` | 10 | **需改**：同 source_debug 状态语义色 |
| `lib/src/screens/highlight_rules_screen.dart` | 9 | **需改（内容色例外登记）**：高亮内容色 `iosYellow/Green/Teal/Blue/Purple/Pink/Red/OrangeLight` |
| `lib/src/widgets/page_flip_widget.dart` | 8 | 需看上下文（翻页阴影， likely 排除） |
| `lib/src/screens/js_source_edit_screen.dart` | 7 | **需改**：iOS 式背景 `#F2F2F7` + 错误/警告底 `#FFEBEE/#FFF8E1` + 文字 `#1C1C1E/#C62828/#F9A825/#6D4C41` |
| `lib/src/widgets/reader/text_selection_panel.dart` | 6 | 沉浸域：高亮 5 色，排除 |
| `lib/src/providers/reader/reader_state.dart` | 6 | 沉浸域：5 档纸张预设，排除 |
| `lib/src/widgets/reader/reader_page_view.dart` | 4 | 沉浸域：文字自适应 `0xFFCCCCCC/0xFF333333` + 阴影，排除 |
| `lib/src/screens/source_import_confirm_screen.dart` | 4 | **需改**：iOS 绿 `#4CD964/#34C759` + 橙 `#FFC069/#FF9500` |
| `lib/src/widgets/help/help_markdown_styles.dart` | 3 | **需改**：半透明遮罩 `#1FFFFFFF/#1F000000` + 弱文本 `#B3FFFFFF/#8A000000`（→ scrim/onSurfaceVariant） |
| `lib/src/screens/source_edit_screen_dialogs.part.dart` | 3 | **需改**：取色器黑/白硬编码（→ colorScheme） |
| `lib/src/widgets/swipe_action.dart` | 2 | 保留：`Colors.white` 为动作底上前景（onPrimary），登记为例外 |
| `lib/src/widgets/reader/review_column.dart` | 2 | 沉浸域排除 |
| `lib/src/widgets/reader/reader_image_dominant_body.dart` | 2 | 沉浸域：`Colors.grey[600]` 占位，排除 |
| `lib/src/widgets/paragraph_layout_engine.dart` | 2 | 排版引擎，排除 |
| `lib/src/theme/app_theme.dart` | 2 | 本体：`black87/white` 为 `_onColor` 计算 + `transparent` surfaceTint，保留 |
| `lib/src/services/system_bar_service.dart` | 2 | 系统栏：`statusBarBag 0x19000000 + black26`，保留（Android 语义，iOS 忽略） |
| `lib/src/screens/search_screen_builders.part.dart` | 2 | **需改**：`0xFFFF9800` + `0xFF43A047(md_green_600)` |
| `lib/src/screens/reader_screen.dart` | 2 | 沉浸域：`black54/white` 浮层，排除 |
| `lib/src/screens/change_source_screen.dart` | 2 | **需改（样板）**：`goodColor 0xFFFF5252 / badColor 0xFF448AFF`（评分正负指示） |
| `lib/src/widgets/reader/reader_status_strip.dart` | 1 | 沉浸域排除 |
| `lib/src/screens/welcome_config_screen.dart` | 1 | 注释行（已登记清点），无需改 |
| `lib/src/screens/replace_rules_screen.dart` | 1 | `fillColor: Colors.white.withValues(alpha:0.2)` 搜索框前景，保留登记为例外 |
| `lib/src/screens/cache_download_screen.dart` | 1 | **需改**：`'completed' => Colors.green` 状态映射 |

### 2.2 Cupertino 残留

| 文件 | 命中 | 定性 |
|---|---|---|
| `lib/src/widgets/reader/review_detail_sheet.dart` | 15（`CupertinoColors.systemBackground/secondaryLabel/systemGrey3/label/separator/systemGrey5/activeBlue` + `CupertinoButton×2` + `xmark_circle_fill/person_fill` + `CupertinoActivityIndicator×2`） | 沉浸域排除（段评浮层），**本轮不改** |
| `lib/src/widgets/reader/review_column.dart` | 1（`systemBlue`） | 沉浸域排除，不改 |
| `lib/src/widgets/manga/manga_config_sheet.dart` | 1（`CupertinoSlidingSegmentedControl`） | 沉浸域排除，不改 |
| `lib/src/widgets/md3_picker_sheet.dart` / `explore_kind_layout.dart` / `explore_page_control.dart` | 0 运行时（仅注释提及已迁移） | 无需改 |

`cupertino_icons ^1.0.8` 保留（沉浸域仍引用），本轮不移除依赖。

### 2.3 AppColors / IosGroup / surfaceVariant

- `AppColors`：6 文件引用（`highlight_rules/source_import_confirm/source_screen_builders/rss_source_import_confirm/replace_rule_import_confirm` + 本体），其中高亮/状态点按 2.1 逐项迁移，`app_colors.dart` 本体冻结。
- `IosGroup/IosListTile`：9 屏 96 处消费（`about/bottom_bar_skin*/explore/other_settings/settings/theme_config/webdav/welcome_config`）——消费的是已 MD3 化的 shim（`Card+outlineVariant+primaryContainer`），**无需改**。
- `surfaceVariant`：消费侧零引用（仅 `md3_colors.dart` 定义），已完成 `surfaceContainer*` 迁移，**无需改**。

---

## 三、精确待改清单（Batch A/B 输入）

### P0 样板（Batch A）

| # | 文件 | 行 | 改动 |
|---|---|---|---|
| A1 | `lib/src/screens/change_source_screen.dart` | 843–844 | `goodColor/badColor` → `colorScheme.error/tertiary`（评分正负指示，亮暗自适应） |

### P1 增量（Batch B）

| # | 文件 | 行 | 改动 |
|---|---|---|---|
| B1 | `lib/src/screens/source_debug_screen.dart` | 290,436–474 | `Colors.white`（暗色前景）→ `colorScheme.onSurface`；`green/orange/blueGrey/red shade` 状态色 → `colorScheme.primary/tertiary/error + outline`（亮暗分支保留语义） |
| B2 | `lib/src/screens/rss_source_debug_screen.dart` | 305–343 | 同 B1 |
| B3 | `lib/src/screens/source_screen_builders.part.dart` | 665–879 | `AppColors.iosGreen/iosRedLight` 状态点 → `colorScheme.primary/error`（或 `tertiary/error`，与 B1 一致） |
| B4 | `lib/src/screens/js_source_edit_screen.dart` | 261,308–385 | `0xFFF2F2F7` 背景 → `surfaceContainerLowest/Low`；`0xFFFFEBEE/0xFFC62828` 错误 → `errorContainer/onErrorContainer`；`0xFFFFF8E1/0xFFF9A825/0xFF6D4C41` 警告 → `tertiaryContainer/onTertiaryContainer`；`0xFF1C1C1E` → `onSurface` |
| B5 | `lib/src/screens/source_import_confirm_screen.dart` | 465–471 | iOS 绿/橙 → `primary/tertiary`（亮暗分支合并为单 token） |
| B6 | `lib/src/screens/search_screen_builders.part.dart` | 425,450 | `0xFFFF9800/0xFF43A047` → `tertiary/primary` |
| B7 | `lib/src/screens/highlight_rules_screen.dart` | 269–289 | 高亮内容色：保留色值语义（用户内容色），改由 `colorScheme` 派生或登记为**内容色例外**（不随 tonal 强制映射，亮暗各一套） |
| B8 | `lib/src/screens/cache_download_screen.dart` | 175 | `Colors.green` → `colorScheme.primary`（或 tertiary，按状态语义统一） |
| B9 | `lib/src/widgets/help/help_markdown_styles.dart` | 7–17 | 遮罩/弱文本 → `colorScheme.scrim/onSurfaceVariant` |
| B10 | `lib/src/screens/source_edit_screen_dialogs.part.dart` | 89–133 | 取色器黑/白 → `colorScheme.onSurface/surface`（保持对比语义） |

### 明确不改（排除登记）

阅读器沉浸域（`reader_screen/reader_comic/reader_page_view/text_content/page_chrome/status_strip/text_selection_panel/reader_state/paragraph_layout_engine`）、漫画（`manga_config_sheet`）、视频浮层（`video_screen`）、段评（`review_detail_sheet/review_column`）、`page_flip_widget` 阴影、`app_theme/system_bar_service` 本体逻辑、`swipe_action/replace_rules` 白色前景、`transparent/elink` 特殊主题、`cupertino_icons` 依赖。

---

## 四、Batch 0 输入

- Flutter：无需重跑 `gen_md3_colors.py`；执行 `flutter test test/unit/md3_palette_test.dart` 校验即过。
- Rust R1/R2（见 ALIGNMENT_PLAN §八）：`rust/legado-js/src/host_api/config_api.rs:43/61` 两函数 + Flutter `setConfig("themeMode")` 注入。

---

编写者：Qoder ｜ 2026-09-04
