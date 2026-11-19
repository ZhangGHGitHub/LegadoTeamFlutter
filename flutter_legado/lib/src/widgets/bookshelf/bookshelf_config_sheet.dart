// 书架布局配置 Sheet（设置批6a-1 / 6a-2）
//
// 对齐参考版 `BookshelfConfigSheet.kt`：五段（分组 / 排序 / 布局 / 角标 /
// 其他）+ 按当前横竖屏与布局模式条件显隐。分组样式=文件夹（2）时，
// 「布局」段内追加文件夹根目录的 8 个配置键（文件夹布局模式 / 网格列数 /
// 列表列数 / 列表封面宽 / 列表样式 / 横排封面数量 + 重置入口）。
//
// 取色复用公共 `ContainerColorDialog`（HEX + 预设色板，返回 0 = 跟随
// 主题）。所有改动即时写入 `BookshelfSettingsNotifier`（滑块松手提交）。
//
// 编写：全栈工程师（设置批6a-1 / 6a-2） ｜ 2026-11-08
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../l10n/app_strings.dart';
import '../../models/bookshelf_settings.dart';
import '../../providers/bookshelf/bookshelf_notifier.dart';
import '../../providers/bookshelf_settings/bookshelf_settings_notifier.dart';
import '../../utils/bookshelf_sort.dart';
import '../../widgets/container_color_dialog.dart';
import '../../widgets/setting_slider_row.dart';

/// 打开书架布局配置 Sheet
///
/// [viewportWidth] 为书架内容实际宽度（多栏/窄 pane 时小于窗口宽）；
/// 传入后「列表列数」提示按真实可用宽度计算，与书架入口夹取一致。
Future<void> showBookshelfConfigSheet(
  BuildContext context, {
  double? viewportWidth,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => BookshelfConfigSheet(viewportWidth: viewportWidth),
  );
}

/// 书架布局配置 Sheet
class BookshelfConfigSheet extends ConsumerWidget {
  /// 书架内容实际宽度（null = 回退窗口宽，仅独立使用/测试时）
  final double? viewportWidth;

  const BookshelfConfigSheet({super.key, this.viewportWidth});

  /// 文件夹根目录独立配置键（6a-2；分组样式=文件夹时显示）
  ///
  /// 「重置文件夹布局」只恢复这 8 个键，不改共享的列表封面宽
  /// （`bookshelfListCoverWidth`）与「显示分组书籍数」开关。
  static const folderPrefKeys = <String>{
    BookshelfSettings.keyBookshelfFolderLayoutModePortrait,
    BookshelfSettings.keyBookshelfFolderLayoutGridPortrait,
    BookshelfSettings.keyBookshelfFolderLayoutModeLandscape,
    BookshelfSettings.keyBookshelfFolderLayoutGridLandscape,
    BookshelfSettings.keyBookshelfFolderLayoutListPortrait,
    BookshelfSettings.keyBookshelfFolderLayoutListLandscape,
    BookshelfSettings.keyBookshelfGroupListStyle,
    BookshelfSettings.keyBookshelfGroupCoverCount,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(bookshelfSettingsProvider);
    final notifier = ref.read(bookshelfSettingsProvider.notifier);
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final layoutMode = settings.layoutModeFor(isLandscape: isLandscape);
    final folderLayoutMode = settings.folderLayoutModeFor(
      isLandscape: isLandscape,
    );
    final maxReadableListColumns = BookshelfSettings.maxReadableListColumns(
      viewportWidth ?? MediaQuery.sizeOf(context).width,
    );
    final configuredListColumns = settings.listColumnsFor(
      isLandscape: isLandscape,
    );
    final theme = Theme.of(context);

    void update(BookshelfSettings Function(BookshelfSettings) transform) {
      notifier.update(transform);
    }

    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(AppStrings.layoutSettings,
                style: theme.textTheme.titleLarge),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // ===== 分组 =====
                _SectionHeader(AppStrings.group),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfGroupStyleDropdown'),
                  title: AppStrings.bookshelfGroupStyle,
                  value: settings.bookGroupStyle.clamp(0, 2),
                  items: [
                    DropdownMenuItem(
                        value: 0, child: Text(AppStrings.bookshelfGroupStyleTabs)),
                    DropdownMenuItem(
                        value: 1,
                        child: Text(AppStrings.bookshelfGroupStyleHidden)),
                    DropdownMenuItem(
                        value: 2, child: Text(AppStrings.bookshelfGroupStyleFolder)),
                  ],
                  onChanged: (value) =>
                      update((s) => s.copyWith(bookGroupStyle: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfHideEmptyGroupsSwitch'),
                  title: AppStrings.hideEmptyGroups,
                  value: settings.hideEmptyGroups,
                  onChanged: (value) =>
                      update((s) => s.copyWith(hideEmptyGroups: value)),
                ),

                // ===== 排序 =====
                _SectionHeader(AppStrings.sortLabel),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfSortDropdown'),
                  title: AppStrings.sortLabel,
                  // 手动排序：UI 明确说明拖拽范围（网格自动回落列表；
                  // 分组展示模式暂无组内拖拽）
                  subtitle: settings.bookshelfSort == BookshelfSortMode.manual
                      ? AppStrings.bookshelfSortManualHint
                      : null,
                  value: settings.bookshelfSort,
                  items: [
                    for (var i = 0; i < BookshelfSortMode.labels.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(BookshelfSortMode.labels[i]),
                      ),
                  ],
                  onChanged: (value) =>
                      update((s) => s.copyWith(bookshelfSort: value)),
                ),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfSortOrderDropdown'),
                  title: AppStrings.sortOrderLabel,
                  value: settings.bookshelfSortOrder,
                  items: [
                    for (var i = 0; i < BookshelfSortOrder.labels.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(BookshelfSortOrder.labels[i]),
                      ),
                  ],
                  onChanged: (value) =>
                      update((s) => s.copyWith(bookshelfSortOrder: value)),
                ),

                // ===== 布局 =====
                _SectionHeader(AppStrings.bookshelfSectionLayout),
                // [设置批6a-2] 文件夹根目录独立布局（分组样式=文件夹时显示）
                if (settings.bookGroupStyle == 2) ...[
                  _SubSectionHeader(AppStrings.bookshelfFolderRoot),
                  _DropdownRow<int>(
                    key: const ValueKey('bookshelfFolderLayoutModeDropdown'),
                    title: AppStrings.folderLayoutMode,
                    subtitle: isLandscape
                        ? AppStrings.landscapeLabel
                        : AppStrings.portraitLabel,
                    value: folderLayoutMode,
                    items: [
                      DropdownMenuItem(
                          value: 0, child: Text(AppStrings.layoutList)),
                      DropdownMenuItem(
                          value: 1, child: Text(AppStrings.layoutGrid)),
                    ],
                    onChanged: (value) => update(
                      (s) => isLandscape
                          ? s.copyWith(
                              bookshelfFolderLayoutModeLandscape: value,
                            )
                          : s.copyWith(
                              bookshelfFolderLayoutModePortrait: value,
                            ),
                    ),
                  ),
                  if (folderLayoutMode == 1)
                    SettingSliderRow(
                      key: const ValueKey('bookshelfFolderGridColumnsSlider'),
                      title: AppStrings.bookshelfRowColumnCount,
                      value: settings.folderGridColumnsFor(
                        isLandscape: isLandscape,
                      ),
                      min: 1,
                      max: 15,
                      subtitle: AppStrings.folderGridColumnsDesc(
                        isLandscape
                            ? AppStrings.landscapeLabel
                            : AppStrings.portraitLabel,
                      ),
                      onChanged: (value) => update(
                        (s) => isLandscape
                            ? s.copyWith(
                                bookshelfFolderLayoutGridLandscape: value,
                              )
                            : s.copyWith(
                                bookshelfFolderLayoutGridPortrait: value,
                              ),
                      ),
                    )
                  else ...[
                    SettingSliderRow(
                      key: const ValueKey('bookshelfFolderListColumnsSlider'),
                      title: AppStrings.bookshelfRowColumnCount,
                      value: settings.folderListColumnsFor(
                        isLandscape: isLandscape,
                      ),
                      min: 1,
                      max: 5,
                      subtitle: AppStrings.folderListColumnsDesc(
                        isLandscape
                            ? AppStrings.landscapeLabel
                            : AppStrings.portraitLabel,
                      ),
                      onChanged: (value) => update(
                        (s) => isLandscape
                            ? s.copyWith(
                                bookshelfFolderLayoutListLandscape: value,
                              )
                            : s.copyWith(
                                bookshelfFolderLayoutListPortrait: value,
                              ),
                      ),
                    ),
                    SettingSliderRow(
                      key: const ValueKey(
                        'bookshelfFolderListCoverWidthSlider',
                      ),
                      title: AppStrings.bookshelfListCoverWidth,
                      value: settings.bookshelfListCoverWidth,
                      min: 40,
                      max: 120,
                      valueSuffix: 'dp',
                      subtitle: AppStrings.bookshelfFolderListCoverWidthDesc,
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfListCoverWidth: value),
                      ),
                    ),
                    _DropdownRow<int>(
                      key: const ValueKey('bookshelfFolderListStyleDropdown'),
                      title: AppStrings.folderListStyle,
                      value: settings.bookshelfGroupListStyle.clamp(0, 2),
                      items: [
                        DropdownMenuItem(
                            value: 0, child: Text(AppStrings.group)),
                        DropdownMenuItem(
                            value: 1, child: Text(AppStrings.compactList)),
                        DropdownMenuItem(
                            value: 2, child: Text(AppStrings.horizontalCovers)),
                      ],
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfGroupListStyle: value),
                      ),
                    ),
                    if (settings.bookshelfGroupListStyle == 2)
                      SettingSliderRow(
                        key: const ValueKey('bookshelfFolderCoverCountSlider'),
                        title: AppStrings.horizontalCoverCount,
                        value: settings.bookshelfGroupCoverCount,
                        min: 1,
                        max: 10,
                        onChanged: (value) => update(
                          (s) => s.copyWith(bookshelfGroupCoverCount: value),
                        ),
                      ),
                  ],
                  _FolderHintRow(
                    onReset: () {
                      const defaults = BookshelfSettings.defaults;
                      update(
                        (s) => s.copyWith(
                          bookshelfFolderLayoutModePortrait:
                              defaults.bookshelfFolderLayoutModePortrait,
                          bookshelfFolderLayoutGridPortrait:
                              defaults.bookshelfFolderLayoutGridPortrait,
                          bookshelfFolderLayoutModeLandscape:
                              defaults.bookshelfFolderLayoutModeLandscape,
                          bookshelfFolderLayoutGridLandscape:
                              defaults.bookshelfFolderLayoutGridLandscape,
                          bookshelfFolderLayoutListPortrait:
                              defaults.bookshelfFolderLayoutListPortrait,
                          bookshelfFolderLayoutListLandscape:
                              defaults.bookshelfFolderLayoutListLandscape,
                          bookshelfGroupListStyle:
                              defaults.bookshelfGroupListStyle,
                          bookshelfGroupCoverCount:
                              defaults.bookshelfGroupCoverCount,
                        ),
                      );
                    },
                  ),
                ],
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfLayoutModeDropdown'),
                  title: AppStrings.layoutMode,
                  subtitle: isLandscape
                      ? AppStrings.landscapeLabel
                      : AppStrings.portraitLabel,
                  value: layoutMode,
                  items: [
                    DropdownMenuItem(
                        value: 0, child: Text(AppStrings.layoutList)),
                    DropdownMenuItem(value: 1, child: Text(AppStrings.layoutGrid)),
                  ],
                  onChanged: (value) => update(
                    (s) => isLandscape
                        ? s.copyWith(bookshelfLayoutModeLandscape: value)
                        : s.copyWith(bookshelfLayoutModePortrait: value),
                  ),
                ),
                if (layoutMode == 1) ...[
                  _DropdownRow<int>(
                    key: const ValueKey('bookshelfGridStyleDropdown'),
                    title: AppStrings.bookshelfGridStyle,
                    value: settings.bookshelfGridLayout.clamp(0, 2),
                    items: [
                      DropdownMenuItem(
                          value: 0, child: Text(AppStrings.gridStyleStandard)),
                      DropdownMenuItem(
                          value: 1, child: Text(AppStrings.gridStyleCompact)),
                      DropdownMenuItem(
                          value: 2, child: Text(AppStrings.gridStyleCoverOnly)),
                    ],
                    onChanged: (value) =>
                        update((s) => s.copyWith(bookshelfGridLayout: value)),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfGridColumnsSlider'),
                    title: AppStrings.bookshelfRowColumnCount,
                    value: settings.gridColumnsFor(isLandscape: isLandscape),
                    min: 1,
                    max: 15,
                    subtitle: AppStrings.gridColumnsDesc(
                      isLandscape
                          ? AppStrings.landscapeLabel
                          : AppStrings.portraitLabel,
                    ),
                    onChanged: (value) => update(
                      (s) => isLandscape
                          ? s.copyWith(bookshelfLayoutGridLandscape: value)
                          : s.copyWith(bookshelfLayoutGridPortrait: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfTitleSmallFontSwitch'),
                    title: AppStrings.bookshelfTitleSmallFont,
                    value: settings.bookshelfTitleSmallFont,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfTitleSmallFont: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfTitleCenterSwitch'),
                    title: AppStrings.bookshelfTitleCenter,
                    value: settings.bookshelfTitleCenter,
                    onChanged: (value) =>
                        update((s) => s.copyWith(bookshelfTitleCenter: value)),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfGridCoverWidthSlider'),
                    title: AppStrings.bookshelfGridCoverWidth,
                    value: settings.bookshelfGridCoverWidth,
                    min: 40,
                    max: 150,
                    valueSuffix: 'dp',
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfGridCoverWidth: value),
                    ),
                  ),
                ] else ...[
                  _SwitchRow(
                    key: const ValueKey('bookshelfShowDividerSwitch'),
                    title: AppStrings.showDivider,
                    value: settings.bookshelfShowDivider,
                    onChanged: (value) =>
                        update((s) => s.copyWith(bookshelfShowDivider: value)),
                  ),
                  _ColorRow(
                    key: const ValueKey('bookshelfDayCardColorRow'),
                    title: AppStrings.bookshelfDayCardColor,
                    color: settings.bookshelfCardColor,
                    onChanged: (value) =>
                        update((s) => s.copyWith(bookshelfCardColor: value)),
                  ),
                  _ColorRow(
                    key: const ValueKey('bookshelfNightCardColorRow'),
                    title: AppStrings.bookshelfNightCardColor,
                    color: settings.bookshelfCardColorDark,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfCardColorDark: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfCompactDetailsSwitch'),
                    title: AppStrings.compactDetails,
                    subtitle: AppStrings.compactDetailsDesc,
                    value: settings.bookshelfLayoutCompact,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfLayoutCompact: value),
                    ),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfListCoverWidthSlider'),
                    title: AppStrings.bookshelfListCoverWidth,
                    value: settings.bookshelfListCoverWidth,
                    min: 40,
                    max: 120,
                    valueSuffix: 'dp',
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfListCoverWidth: value),
                    ),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfListColumnsSlider'),
                    title: AppStrings.bookshelfRowColumnCount,
                    value: settings.listColumnsFor(isLandscape: isLandscape),
                    min: 1,
                    max: 5,
                    subtitle: configuredListColumns > maxReadableListColumns
                        ? AppStrings.listColumnsExceedDesc(
                            isLandscape
                                ? AppStrings.landscapeLabel
                                : AppStrings.portraitLabel,
                            '$maxReadableListColumns',
                          )
                        : AppStrings.listColumnsDesc(
                            isLandscape
                                ? AppStrings.landscapeLabel
                                : AppStrings.portraitLabel,
                          ),
                    onChanged: (value) => update(
                      (s) => isLandscape
                          ? s.copyWith(bookshelfLayoutListLandscape: value)
                          : s.copyWith(bookshelfLayoutListPortrait: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfMoreInfoSwitch'),
                    title: AppStrings.bookshelfMoreInfo,
                    value: settings.showBookIntro,
                    onChanged: (value) =>
                        update((s) => s.copyWith(showBookIntro: value)),
                  ),
                  if (settings.showBookIntro) ...[
                    _SwitchRow(
                      key: const ValueKey('bookshelfListCoverCenterSwitch'),
                      title: AppStrings.centerCoverVertically,
                      subtitle: AppStrings.centerCoverVerticallyDesc,
                      value: settings.bookshelfListCoverCenter,
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfListCoverCenter: value),
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('bookshelfShowLatestChapterSwitch'),
                      title: AppStrings.showLatestChapter,
                      value: settings.bookshelfShowLatestChapter,
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfShowLatestChapter: value),
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('bookshelfShowIntroSwitch'),
                      title: AppStrings.showSynopsis,
                      value: settings.bookshelfShowIntro,
                      onChanged: (value) =>
                          update((s) => s.copyWith(bookshelfShowIntro: value)),
                    ),
                    if (settings.bookshelfShowIntro && layoutMode == 0)
                      _SwitchRow(
                        key: const ValueKey('bookshelfIntroBelowSwitch'),
                        title: AppStrings.showSynopsisBelowContent,
                        value: settings.bookshelfListIntroBelowContent,
                        onChanged: (value) => update(
                          (s) =>
                              s.copyWith(bookshelfListIntroBelowContent: value),
                        ),
                      ),
                    if (settings.bookshelfShowIntro)
                      SettingSliderRow(
                        key: const ValueKey('bookshelfIntroMaxLinesSlider'),
                        title: AppStrings.synopsisLines,
                        value: settings.bookshelfIntroMaxLines,
                        min: 0,
                        max: 10,
                        subtitle: settings.bookshelfIntroMaxLines == 0
                            ? AppStrings.showAllSynopsis
                            : AppStrings.synopsisLineCount(
                                '${settings.bookshelfIntroMaxLines}'),
                        onChanged: (value) => update(
                          (s) => s.copyWith(bookshelfIntroMaxLines: value),
                        ),
                      ),
                  ],
                ],
                // [审查 P2] 标签开关同时作用于网格与列表，移出列表分支
                _SwitchRow(
                  key: const ValueKey('bookshelfShowTagSwitch'),
                  title: AppStrings.showTags,
                  value: settings.bookshelfShowTag,
                  onChanged: (value) =>
                      update((s) => s.copyWith(bookshelfShowTag: value)),
                ),
                // 我方扩展（批35）：标签内容勾选，随「显示标签」显隐
                if (settings.bookshelfShowTag)
                  _TagContentRow(key: const ValueKey('bookshelfTagContentRow')),
                SettingSliderRow(
                  key: const ValueKey('bookshelfTitleMaxLinesSlider'),
                  title: AppStrings.bookshelfTitleMaxLines,
                  value: settings.bookshelfTitleMaxLines,
                  min: 1,
                  max: 5,
                  onChanged: (value) =>
                      update((s) => s.copyWith(bookshelfTitleMaxLines: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfCoverShadowSwitch'),
                  title: AppStrings.coverShadow,
                  value: settings.bookshelfCoverShadow,
                  onChanged: (value) =>
                      update((s) => s.copyWith(bookshelfCoverShadow: value)),
                ),

                // ===== 角标 =====
                _SectionHeader(AppStrings.badgeSection),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowUnreadSwitch'),
                  title: AppStrings.showUnread,
                  value: settings.showUnread,
                  onChanged: (value) =>
                      update((s) => s.copyWith(showUnread: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowUnreadNewSwitch'),
                  title: AppStrings.showUnreadNew,
                  value: settings.showUnreadNew,
                  onChanged: (value) =>
                      update((s) => s.copyWith(showUnreadNew: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowWaitUpCountSwitch'),
                  title: AppStrings.showWaitUpCount,
                  value: settings.showWaitUpCount,
                  onChanged: (value) =>
                      update((s) => s.copyWith(showWaitUpCount: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowBookCountSwitch'),
                  title: AppStrings.showGroupBookCount,
                  subtitle: settings.bookGroupStyle == 2
                      ? AppStrings.showBookCountFolderDesc
                      : AppStrings.showBookCountDesc,
                  value: settings.showBookCount,
                  onChanged: (value) =>
                      update((s) => s.copyWith(showBookCount: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowLastUpdateTimeSwitch'),
                  title: AppStrings.showLastUpdateTime,
                  value: settings.showLastUpdateTime,
                  onChanged: (value) =>
                      update((s) => s.copyWith(showLastUpdateTime: value)),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowTipSwitch'),
                  title: AppStrings.showTip,
                  value: settings.showTip,
                  onChanged: (value) =>
                      update((s) => s.copyWith(showTip: value)),
                ),

                // ===== 其他 =====
                _SectionHeader(AppStrings.otherSection),
                _SwitchRow(
                  key: const ValueKey('bookshelfSearchDirectSwitch'),
                  title: AppStrings.bookshelfSearchDirect,
                  subtitle: AppStrings.bookshelfSearchButtonHint,
                  // 书架内搜索过滤已接入：点击/长按按本开关分流全局搜索与
                  // 书架内过滤（对齐参考版 bookshelf_search_button_hint）。
                  value: settings.bookshelfSearchActionDirectToSearch,
                  onChanged: (value) => update(
                    (s) =>
                        s.copyWith(bookshelfSearchActionDirectToSearch: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfFastScrollerSwitch'),
                  title: AppStrings.showBookshelfFastScroller,
                  value: settings.showBookshelfFastScroller,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showBookshelfFastScroller: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfMoreGroupsSwitch'),
                  title: AppStrings.showMoreGroupsButton,
                  subtitle: AppStrings.showMoreGroupsButtonDesc,
                  value: settings.shouldShowExpandButton,
                  onChanged: (value) =>
                      update((s) => s.copyWith(shouldShowExpandButton: value)),
                ),
                SettingSliderRow(
                  key: const ValueKey('bookshelfRefreshLimitSlider'),
                  title: AppStrings.bookshelfUpdateLimit,
                  value: settings.bookshelfRefreshingLimit,
                  min: 0,
                  max: 100,
                  subtitle: settings.bookshelfRefreshingLimit <= 0
                      ? AppStrings.unlimitedLabel
                      : AppStrings.bookshelfUpdateLimitDesc(
                          '${settings.bookshelfRefreshingLimit}'),
                  onChanged: (value) => update(
                    (s) => s.copyWith(bookshelfRefreshingLimit: value),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 分组标题（五段）
class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 子分段标题（文件夹根目录独立配置）
class _SubSectionHeader extends StatelessWidget {
  final String title;

  const _SubSectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件夹根目录说明 + 重置入口（6a-2）
class _FolderHintRow extends StatelessWidget {
  final VoidCallback onReset;

  const _FolderHintRow({required this.onReset});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.info_outline,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              AppStrings.bookshelfFolderRootHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('bookshelfFolderResetButton'),
            onPressed: onReset,
            child: Text(AppStrings.resetLabel),
          ),
        ],
      ),
    );
  }
}

/// 开关行（对齐参考 CompactSwitchSettingItem：整行可点）
class _SwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _SwitchRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    return ListTile(
      enabled: onChanged != null,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: Switch(value: value, onChanged: onChanged),
      onTap: onChanged == null ? null : () => onChanged(!value),
    );
  }
}

/// 下拉行（对齐参考 CompactDropdownSettingItem）
class _DropdownRow<T> extends StatelessWidget {
  final String title;
  final String? subtitle;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T> onChanged;

  const _DropdownRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          items: items,
          onChanged: (next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}

/// 颜色行（点击打开公共 ContainerColorDialog）
class _ColorRow extends StatelessWidget {
  final String title;
  final int color;
  final ValueChanged<int> onChanged;

  const _ColorRow({
    super.key,
    required this.title,
    required this.color,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(title),
      subtitle: Text(
          color == 0 ? AppStrings.followTheme : AppStrings.customized,
        ),
      trailing: color == 0
          ? const Icon(Icons.palette_outlined)
          : Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: Color(color),
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.outlineVariant),
              ),
            ),
      onTap: () async {
        final picked = await showDialog<int>(
          context: context,
          builder: (_) => ContainerColorDialog(
            title: title,
            initialColor: color,
            defaultHint: AppStrings.resetFollowTheme,
          ),
        );
        if (picked != null) onChanged(picked);
      },
    );
  }
}

/// 标签内容摘要行（我方扩展，批35）
class _TagContentRow extends ConsumerWidget {
  const _TagContentRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookshelfNotifierProvider);
    final selected = <String>[
      if (state.showCustomTags) AppStrings.bookshelfTagCustom,
      if (state.showSourceTags) AppStrings.sourceCategories,
      if (state.showWordCount) AppStrings.bookshelfTagWordCount,
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: Text(AppStrings.bookshelfTagContent),
      subtitle: Text(
        selected.isEmpty
            ? AppStrings.bookshelfTagNone
            : selected.join(' · '),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showTagContentDialog(context, ref),
    );
  }

  Future<void> _showTagContentDialog(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final state = ref.read(bookshelfNotifierProvider);
    var showCustomTags = state.showCustomTags;
    var showSourceTags = state.showSourceTags;
    var showWordCount = state.showWordCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(AppStrings.bookshelfTagContent),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: showCustomTags,
                onChanged: (v) =>
                    setDialogState(() => showCustomTags = v ?? false),
                title: Text(AppStrings.bookshelfTagCustom),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: showSourceTags,
                onChanged: (v) =>
                    setDialogState(() => showSourceTags = v ?? false),
                title: Text(AppStrings.sourceCategories),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: showWordCount,
                onChanged: (v) =>
                    setDialogState(() => showWordCount = v ?? false),
                title: Text(AppStrings.bookshelfTagWordCount),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(AppStrings.confirm),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await ref
        .read(bookshelfNotifierProvider.notifier)
        .setTagContent(
          showCustomTags: showCustomTags,
          showSourceTags: showSourceTags,
          showWordCount: showWordCount,
        );
  }
}
