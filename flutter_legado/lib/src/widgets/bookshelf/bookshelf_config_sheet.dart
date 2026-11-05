// 书架布局配置 Sheet（设置批6a-1）
//
// 对齐参考版 `BookshelfConfigSheet.kt`：五段（分组 / 排序 / 布局 / 角标 /
// 其他）+ 按当前横竖屏与布局模式条件显隐。参考版的 8 个文件夹字段
// （`bookshelfFolderLayout*` / `bookshelfGroupListStyle` /
// `bookshelfGroupCoverCount`）属 6a-2，本批只保留默认值、不渲染。
//
// 取色复用公共 `ContainerColorDialog`（HEX + 预设色板，返回 0 = 跟随
// 主题）。所有改动即时写入 `BookshelfSettingsNotifier`（滑块松手提交）。
//
// 编写：全栈工程师（设置批6a-1） ｜ 2026-11-06
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/bookshelf_settings.dart';
import '../../providers/bookshelf/bookshelf_notifier.dart';
import '../../providers/bookshelf_settings/bookshelf_settings_notifier.dart';
import '../../utils/bookshelf_sort.dart';
import '../../widgets/container_color_dialog.dart';
import '../../widgets/setting_slider_row.dart';

/// 打开书架布局配置 Sheet
Future<void> showBookshelfConfigSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => const BookshelfConfigSheet(),
  );
}

/// 书架布局配置 Sheet
class BookshelfConfigSheet extends ConsumerWidget {
  const BookshelfConfigSheet({super.key});

  /// 6a-2 文件夹模式才启用的 8 个配置键（本期隐藏，仅保留模型默认值）
  static const hiddenFolderPrefKeys = <String>{
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
            child: Text('布局设置', style: theme.textTheme.titleLarge),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                // ===== 分组 =====
                const _SectionHeader('分组'),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfGroupStyleDropdown'),
                  title: '分组样式',
                  value: settings.bookGroupStyle.clamp(0, 1),
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('顶部标签')),
                    DropdownMenuItem(value: 1, child: Text('隐藏标签')),
                  ],
                  onChanged: (value) => update(
                    (s) => s.copyWith(bookGroupStyle: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfHideEmptyGroupsSwitch'),
                  title: '隐藏空分组',
                  value: settings.hideEmptyGroups,
                  onChanged: (value) => update(
                    (s) => s.copyWith(hideEmptyGroups: value),
                  ),
                ),

                // ===== 排序 =====
                const _SectionHeader('排序'),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfSortDropdown'),
                  title: '排序',
                  value: settings.bookshelfSort,
                  items: [
                    for (var i = 0; i < BookshelfSortMode.labels.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(BookshelfSortMode.labels[i]),
                      ),
                  ],
                  onChanged: (value) => update(
                    (s) => s.copyWith(bookshelfSort: value),
                  ),
                ),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfSortOrderDropdown'),
                  title: '排序方向',
                  value: settings.bookshelfSortOrder,
                  items: [
                    for (var i = 0; i < BookshelfSortOrder.labels.length; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(BookshelfSortOrder.labels[i]),
                      ),
                  ],
                  onChanged: (value) => update(
                    (s) => s.copyWith(bookshelfSortOrder: value),
                  ),
                ),

                // ===== 布局 =====
                const _SectionHeader('布局'),
                _DropdownRow<int>(
                  key: const ValueKey('bookshelfLayoutModeDropdown'),
                  title: '布局模式',
                  subtitle: isLandscape ? '横屏' : '竖屏',
                  value: layoutMode,
                  items: const [
                    DropdownMenuItem(value: 0, child: Text('列表')),
                    DropdownMenuItem(value: 1, child: Text('网格')),
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
                    title: '网格样式',
                    value: settings.bookshelfGridLayout.clamp(0, 2),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('标准')),
                      DropdownMenuItem(value: 1, child: Text('紧凑')),
                      DropdownMenuItem(value: 2, child: Text('仅封面')),
                    ],
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfGridLayout: value),
                    ),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfGridColumnsSlider'),
                    title: '行列数',
                    value:
                        settings.gridColumnsFor(isLandscape: isLandscape),
                    min: 1,
                    max: 15,
                    subtitle: isLandscape ? '横屏网格列数' : '竖屏网格列数',
                    onChanged: (value) => update(
                      (s) => isLandscape
                          ? s.copyWith(bookshelfLayoutGridLandscape: value)
                          : s.copyWith(bookshelfLayoutGridPortrait: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfTitleSmallFontSwitch'),
                    title: '书名小字体',
                    value: settings.bookshelfTitleSmallFont,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfTitleSmallFont: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfTitleCenterSwitch'),
                    title: '书名居中',
                    value: settings.bookshelfTitleCenter,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfTitleCenter: value),
                    ),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfGridCoverWidthSlider'),
                    title: '网格封面宽',
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
                    title: '显示分隔线',
                    value: settings.bookshelfShowDivider,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfShowDivider: value),
                    ),
                  ),
                  _ColorRow(
                    key: const ValueKey('bookshelfDayCardColorRow'),
                    title: '日间卡片背景色',
                    color: settings.bookshelfCardColor,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfCardColor: value),
                    ),
                  ),
                  _ColorRow(
                    key: const ValueKey('bookshelfNightCardColorRow'),
                    title: '夜间卡片背景色',
                    color: settings.bookshelfCardColorDark,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfCardColorDark: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfCompactDetailsSwitch'),
                    title: '精简详情',
                    subtitle: '只保留书名、作者与未读数',
                    value: settings.bookshelfLayoutCompact,
                    onChanged: (value) => update(
                      (s) => s.copyWith(bookshelfLayoutCompact: value),
                    ),
                  ),
                  SettingSliderRow(
                    key: const ValueKey('bookshelfListCoverWidthSlider'),
                    title: '列表封面宽',
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
                    title: '行列数',
                    value:
                        settings.listColumnsFor(isLandscape: isLandscape),
                    min: 1,
                    max: 5,
                    subtitle: isLandscape ? '横屏列表列数' : '竖屏列表列数',
                    onChanged: (value) => update(
                      (s) => isLandscape
                          ? s.copyWith(bookshelfLayoutListLandscape: value)
                          : s.copyWith(bookshelfLayoutListPortrait: value),
                    ),
                  ),
                  _SwitchRow(
                    key: const ValueKey('bookshelfMoreInfoSwitch'),
                    title: '更多信息',
                    value: settings.showBookIntro,
                    onChanged: (value) => update(
                      (s) => s.copyWith(showBookIntro: value),
                    ),
                  ),
                  if (settings.showBookIntro) ...[
                    _SwitchRow(
                      key: const ValueKey('bookshelfListCoverCenterSwitch'),
                      title: '封面垂直居中',
                      subtitle: '关闭后封面顶部对齐',
                      value: settings.bookshelfListCoverCenter,
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfListCoverCenter: value),
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey(
                          'bookshelfShowLatestChapterSwitch'),
                      title: '显示最新章节',
                      value: settings.bookshelfShowLatestChapter,
                      onChanged: (value) => update(
                        (s) =>
                            s.copyWith(bookshelfShowLatestChapter: value),
                      ),
                    ),
                    _SwitchRow(
                      key: const ValueKey('bookshelfShowIntroSwitch'),
                      title: '显示简介',
                      value: settings.bookshelfShowIntro,
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfShowIntro: value),
                      ),
                    ),
                    if (settings.bookshelfShowIntro && layoutMode == 0)
                      _SwitchRow(
                        key:
                            const ValueKey('bookshelfIntroBelowSwitch'),
                        title: '简介显示在内容下方',
                        value: settings.bookshelfListIntroBelowContent,
                        onChanged: (value) => update(
                          (s) => s.copyWith(
                            bookshelfListIntroBelowContent: value,
                          ),
                        ),
                      ),
                    if (settings.bookshelfShowIntro)
                      SettingSliderRow(
                        key: const ValueKey(
                            'bookshelfIntroMaxLinesSlider'),
                        title: '简介行数',
                        value: settings.bookshelfIntroMaxLines,
                        min: 0,
                        max: 10,
                        subtitle: settings.bookshelfIntroMaxLines == 0
                            ? '显示全部简介'
                            : '显示 ${settings.bookshelfIntroMaxLines} 行',
                        onChanged: (value) => update(
                          (s) =>
                              s.copyWith(bookshelfIntroMaxLines: value),
                        ),
                      ),
                    _SwitchRow(
                      key: const ValueKey('bookshelfShowTagSwitch'),
                      title: '显示标签',
                      value: settings.bookshelfShowTag,
                      onChanged: (value) => update(
                        (s) => s.copyWith(bookshelfShowTag: value),
                      ),
                    ),
                    // 我方扩展（批35）：标签内容勾选，随「显示标签」显隐
                    if (settings.bookshelfShowTag)
                      _TagContentRow(
                        key: const ValueKey('bookshelfTagContentRow'),
                      ),
                  ],
                ],
                SettingSliderRow(
                  key: const ValueKey('bookshelfTitleMaxLinesSlider'),
                  title: '书名最大行数',
                  value: settings.bookshelfTitleMaxLines,
                  min: 1,
                  max: 5,
                  onChanged: (value) => update(
                    (s) => s.copyWith(bookshelfTitleMaxLines: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfCoverShadowSwitch'),
                  title: '封面阴影',
                  value: settings.bookshelfCoverShadow,
                  onChanged: (value) => update(
                    (s) => s.copyWith(bookshelfCoverShadow: value),
                  ),
                ),

                // ===== 角标 =====
                const _SectionHeader('角标'),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowUnreadSwitch'),
                  title: '显示未读标志',
                  value: settings.showUnread,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showUnread: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowUnreadNewSwitch'),
                  title: '显示新章节标志',
                  value: settings.showUnreadNew,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showUnreadNew: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowWaitUpCountSwitch'),
                  title: '显示等待更新数量',
                  value: settings.showWaitUpCount,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showWaitUpCount: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowBookCountSwitch'),
                  title: '显示分组书籍数',
                  subtitle: '文件夹模式上线后生效',
                  value: settings.showBookCount,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showBookCount: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowLastUpdateTimeSwitch'),
                  title: '显示上次更新时间',
                  value: settings.showLastUpdateTime,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showLastUpdateTime: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfShowTipSwitch'),
                  title: '显示书籍类型',
                  value: settings.showTip,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showTip: value),
                  ),
                ),

                // ===== 其他 =====
                const _SectionHeader('其他'),
                _SwitchRow(
                  key: const ValueKey('bookshelfSearchDirectSwitch'),
                  title: '搜索直达',
                  subtitle: '书架内搜索过滤将在后续批次提供',
                  // 书架内搜索过滤不在 6a-1 范围：保持参考版默认开启并禁用，
                  // 避免给出「已生效」的假象；后续批次接入过滤后启用。
                  value: true,
                  onChanged: null,
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfFastScrollerSwitch'),
                  title: '显示快速滚动条',
                  value: settings.showBookshelfFastScroller,
                  onChanged: (value) => update(
                    (s) => s.copyWith(showBookshelfFastScroller: value),
                  ),
                ),
                _SwitchRow(
                  key: const ValueKey('bookshelfMoreGroupsSwitch'),
                  title: '显示更多分组',
                  subtitle: '在分组标签行尾显示组菜单按钮',
                  value: settings.shouldShowExpandButton,
                  onChanged: (value) => update(
                    (s) => s.copyWith(shouldShowExpandButton: value),
                  ),
                ),
                SettingSliderRow(
                  key: const ValueKey('bookshelfRefreshLimitSlider'),
                  title: '更新数量限制',
                  value: settings.bookshelfRefreshingLimit,
                  min: 0,
                  max: 100,
                  subtitle: settings.bookshelfRefreshingLimit <= 0
                      ? '不限制'
                      : '每次最多更新 ${settings.bookshelfRefreshingLimit} 本',
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
      trailing: Switch(
        value: value,
        onChanged: onChanged,
      ),
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
      subtitle: Text(color == 0 ? '跟随主题' : '已自定义'),
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
            defaultHint: '恢复默认（跟随主题）',
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
      if (state.showCustomTags) '用户标签',
      if (state.showSourceTags) '书源分类',
      if (state.showWordCount) '字数',
    ];
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      title: const Text('标签显示内容'),
      subtitle: Text(selected.isEmpty ? '未选择显示内容' : selected.join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => _showTagContentDialog(context, ref),
    );
  }

  Future<void> _showTagContentDialog(
      BuildContext context, WidgetRef ref) async {
    final state = ref.read(bookshelfNotifierProvider);
    var showCustomTags = state.showCustomTags;
    var showSourceTags = state.showSourceTags;
    var showWordCount = state.showWordCount;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('标签显示内容'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CheckboxListTile(
                value: showCustomTags,
                onChanged: (v) =>
                    setDialogState(() => showCustomTags = v ?? false),
                title: const Text('用户标签'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: showSourceTags,
                onChanged: (v) =>
                    setDialogState(() => showSourceTags = v ?? false),
                title: const Text('书源分类'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
              CheckboxListTile(
                value: showWordCount,
                onChanged: (v) =>
                    setDialogState(() => showWordCount = v ?? false),
                title: const Text('字数'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await ref.read(bookshelfNotifierProvider.notifier).setTagContent(
          showCustomTags: showCustomTags,
          showSourceTags: showSourceTags,
          showWordCount: showWordCount,
        );
  }
}
