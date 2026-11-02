// [设置批2b-2a | 2026-11-02] 「首页与导航」设置 Sheet
//
// 对齐参考版 `MainNavigationSettingsSheet.kt` + `NavIconManageSheet.kt`：
// - 默认首页下拉（仅列可见页签，选中项失效时显示 bookshelf）；
// - 底栏文字四档（auto/selected/labeled/unlabeled，参考版 label_vis_mode）；
// - 导航栏图标管理（5 页签 × 未选中/选中 两槽，自定义图片，支持替换/删除）；
// - 导航项列表：显示项可拖拽排序 + 开关隐藏，隐藏项置底不可拖拽；
// - 「恢复默认」重置显隐/顺序/默认首页/图标 + 底栏文字（参考版
//   theme_config_reset_defaults 的导航子集）。
// — 全栈工程师 + UI，2026-11-02
import 'dart:io' show File;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:material_symbols_icons/symbols.dart';

import '../models/main_tab.dart';
import '../providers/bottom_bar_skin_notifier.dart';
import '../providers/main_prefs_notifier.dart';
import '../providers/ui_settings/ui_settings_notifier.dart';
import '../services/container_image_picker.dart';
import '../services/nav_icon_store.dart';
import '../widgets/ios_widgets.dart';
import '../widgets/navigation/app_navigation_bars.dart';

/// 首页与导航设置 Sheet
class MainNavigationSettingsSheet extends ConsumerStatefulWidget {
  const MainNavigationSettingsSheet({super.key});

  /// 以 Modal Bottom Sheet 形式打开（对齐参考版 AppModalBottomSheet）
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.92,
        child: MainNavigationSettingsSheet(),
      ),
    );
  }

  @override
  ConsumerState<MainNavigationSettingsSheet> createState() =>
      _MainNavigationSettingsSheetState();
}

class _MainNavigationSettingsSheetState
    extends ConsumerState<MainNavigationSettingsSheet> {
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _labelModeLabel(BottomBarLabelMode mode) => switch (mode) {
    BottomBarLabelMode.auto => '自动',
    BottomBarLabelMode.selected => '选中时显示',
    BottomBarLabelMode.labeled => '常驻',
    BottomBarLabelMode.unlabeled => '不显示',
  };

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(mainPrefsProvider);
    final ui = ref.watch(uiSettingsProvider);
    final theme = Theme.of(context);
    final tabs = prefs.visibleTabs;
    final ordered = prefs.orderedTabs;
    final hidden = ordered
        .where((tab) => !tabs.contains(tab))
        .toList(growable: false);
    final defaultRoute = tabs.any((tab) => tab.route == prefs.defaultHomePage)
        ? prefs.defaultHomePage
        : MainTab.bookshelf.route;
    // 参考版 NavIconManageSheet 按 10 个槽位计数（同一图片可被多槽引用）
    final iconCount = [
      ...prefs.navIconPaths.values,
      ...prefs.navIconSelectedPaths.values,
    ].where((path) => path.isNotEmpty).length;

    // [批2b-2a P3] Sheet 内嵌 ScaffoldMessenger/Scaffold：SnackBar 显示在
    // Sheet 内部（否则根 Scaffold 的 SnackBar 会被 Modal Sheet 遮挡）。
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('首页与导航', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  IosListTile(
                    title: '默认主页',
                    subtitle: '启动应用时优先打开的页签（仅显示可见项）',
                    trailing: DropdownButton<String>(
                      value: defaultRoute,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(16),
                      items: [
                        for (final tab in tabs)
                          DropdownMenuItem<String>(
                            value: tab.route,
                            child: Text(mainTabLabel(tab)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        ref
                            .read(mainPrefsProvider.notifier)
                            .setDefaultHomePage(value);
                      },
                    ),
                  ),
                  IosListTile(
                    title: '底栏文字',
                    subtitle: '导航栏标签显示方式',
                    trailing: DropdownButton<BottomBarLabelMode>(
                      value: ui.labelVisibilityMode,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(16),
                      items: [
                        for (final mode in BottomBarLabelMode.values)
                          DropdownMenuItem<BottomBarLabelMode>(
                            value: mode,
                            child: Text(_labelModeLabel(mode)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        ref
                            .read(uiSettingsProvider.notifier)
                            .setLabelVisibilityMode(value);
                      },
                    ),
                  ),
                  IosListTile(
                    icon: Symbols.image_rounded,
                    title: '导航栏图标',
                    subtitle: iconCount > 0 ? '已自定义 $iconCount 个图标' : '使用默认图标',
                    onTap: () => _showIconManager(context),
                  ),
                  const IosSectionHeader(
                    '导航项',
                    padding: EdgeInsets.fromLTRB(0, 20, 0, 4),
                  ),
                  Text(
                    '拖动左侧把手调整顺序；开关控制首页/发现/订阅是否显示；'
                    '书架与我的始终显示。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ReorderableListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    itemCount: tabs.length + hidden.length,
                    onReorderItem: (oldIndex, newIndex) => _onReorder(
                      tabs: tabs,
                      all: ordered,
                      oldIndex: oldIndex,
                      newIndex: newIndex,
                    ),
                    itemBuilder: (context, index) {
                      final isVisible = index < tabs.length;
                      final tab = isVisible
                          ? tabs[index]
                          : hidden[index - tabs.length];
                      return _buildItem(
                        context,
                        tab: tab,
                        index: index,
                        visible: isVisible,
                        prefs: prefs,
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: TextButton.icon(
                      onPressed: _confirmReset,
                      icon: const Icon(Symbols.restart_alt_rounded),
                      label: const Text('恢复默认'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(
    BuildContext context, {
    required MainTab tab,
    required int index,
    required bool visible,
    required MainPrefsState prefs,
  }) {
    final hideable = kHideableMainTabs.contains(tab);
    return Material(
      key: ValueKey('nav-item-${tab.route}'),
      color: Colors.transparent,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (visible)
              ReorderableDragStartListener(
                index: index,
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Symbols.drag_handle_rounded, size: 22),
                ),
              )
            else
              const SizedBox(width: 30),
            const SizedBox(width: 4),
            NavSpecIcon(
              spec: mainTabNavSpec(
                tab,
                customIconPath: prefs.navIconPath(tab),
                customSelectedIconPath: prefs.navIconPath(tab, selected: true),
              ),
              selected: false,
              activeSkin: ref.watch(
                bottomBarSkinProvider.select((s) => s.active),
              ),
            ),
          ],
        ),
        title: Text(mainTabLabel(tab)),
        subtitle: hideable
            ? null
            : const Text('始终显示', style: TextStyle(fontSize: 12)),
        trailing: Switch(
          value: visible,
          onChanged: hideable
              ? (value) => ref
                    .read(mainPrefsProvider.notifier)
                    .setTabVisible(tab, value)
              : null,
        ),
      ),
    );
  }

  void _onReorder({
    required List<MainTab> tabs,
    required List<MainTab> all,
    required int oldIndex,
    required int newIndex,
  }) {
    // 隐藏项不参与拖拽（没有 DragStartListener），但落点可能越过它们：
    // reorderVisibleTabs 会把目标夹到可见区末尾。
    if (oldIndex >= tabs.length) return;
    final reordered = reorderVisibleTabs(
      visible: tabs,
      all: all,
      oldIndex: oldIndex,
      newIndex: newIndex,
      newIndexAdjusted: true,
    );
    ref.read(mainPrefsProvider.notifier).setNavigationOrder(reordered);
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认导航设置？'),
        content: const Text('将重置导航项显隐、顺序、默认首页、底栏文字和自定义图标。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(mainPrefsProvider.notifier).resetNavigationSettings();
    await ref
        .read(uiSettingsProvider.notifier)
        .setLabelVisibilityMode(BottomBarLabelMode.auto);
    await NavIconStore.deleteAll();
    if (mounted) _toast('已恢复默认导航设置');
  }

  Future<void> _showIconManager(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const FractionallySizedBox(
        heightFactor: 0.85,
        child: _NavIconManagerSheet(),
      ),
    );
  }
}

/// 导航栏图标管理（5 页签 × 未选中/选中）
class _NavIconManagerSheet extends ConsumerStatefulWidget {
  const _NavIconManagerSheet();

  @override
  ConsumerState<_NavIconManagerSheet> createState() =>
      _NavIconManagerSheetState();
}

class _NavIconManagerSheetState extends ConsumerState<_NavIconManagerSheet> {
  @override
  void initState() {
    super.initState();
    // [复核 P2-5] 打开图标管理时低成本回收未引用自有文件/超龄 tmp；
    // 先确保 Support 缓存就绪（平台通道失败时 ensureWarm 内部吞掉）。
    _cleanupOrphans();
  }

  Future<void> _cleanupOrphans() async {
    await NavIconStore.ensureWarm();
    if (!mounted) return;
    final prefs = ref.read(mainPrefsProvider);
    NavIconStore.cleanupOrphansSync(keep: _navIconPathsOf(prefs));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(mainPrefsProvider);
    final theme = Theme.of(context);
    // 同上：图标管理 Sheet 自带 ScaffoldMessenger，失败 toast 不被遮挡。
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('导航栏图标', style: theme.textTheme.titleLarge),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Symbols.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Text(
                    '可为每个页签分别选择未选中/选中图标；留空使用内置图标。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Spacer(),
                      _columnHeader(theme, '未选中'),
                      const SizedBox(width: 12),
                      _columnHeader(theme, '选中'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  for (final tab in MainTab.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Row(
                              children: [
                                NavSpecIcon(
                                  spec: mainTabNavSpec(tab),
                                  selected: false,
                                  activeSkin: '',
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  mainTabLabel(tab),
                                  style: theme.textTheme.titleMedium,
                                ),
                              ],
                            ),
                          ),
                          _IconSlot(
                            tab: tab,
                            selected: false,
                            path: prefs.navIconPath(tab),
                          ),
                          const SizedBox(width: 12),
                          _IconSlot(
                            tab: tab,
                            selected: true,
                            path: prefs.navIconPath(tab, selected: true),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _columnHeader(ThemeData theme, String text) => SizedBox(
    width: 44,
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: theme.textTheme.labelSmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

/// 单个图标槽（空 = 添加；有图 = 点击替换/删除）
class _IconSlot extends ConsumerWidget {
  final MainTab tab;
  final bool selected;
  final String path;

  const _IconSlot({
    required this.tab,
    required this.selected,
    required this.path,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final resolved = NavIconStore.resolveSync(path);
    final usable = path.isNotEmpty && NavIconStore.isUsableSync(path);
    return SizedBox(
      width: 44,
      height: 44,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => path.isEmpty
              ? _pickIcon(context, ref)
              : _showActions(context, ref),
          child: path.isEmpty
              ? Icon(
                  Symbols.add_rounded,
                  size: 22,
                  color: theme.colorScheme.primary,
                )
              : usable
              ? Image.file(
                  // ignore: avoid_slow_placeholder_io
                  File(resolved),
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => Icon(
                    Symbols.broken_image_rounded,
                    size: 20,
                    color: theme.colorScheme.error,
                  ),
                )
              : Icon(
                  Symbols.broken_image_rounded,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
        ),
      ),
    );
  }

  void _showActions(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Symbols.image_rounded),
              title: const Text('替换图标'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickIcon(context, ref);
              },
            ),
            ListTile(
              leading: const Icon(Symbols.delete_rounded),
              title: const Text('删除图标'),
              onTap: () {
                Navigator.pop(sheetContext);
                _clearIcon(ref);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickIcon(BuildContext context, WidgetRef ref) async {
    try {
      // [复核 P1] Android 走 SAF（fd 读字节），不再使用 file_picker 的
      // MediaStore 路径；iOS/桌面走 file_picker（allowCompression:false）。
      final picked = await ContainerImagePicker.pick(
        maxBytes: NavIconStore.maxBytes,
        dialogTitle: '选择导航图标',
      );
      if (picked == null) return;
      final stored = await NavIconStore.importBytes(
        picked.bytes,
        originalName: picked.name,
      );
      final before = ref.read(mainPrefsProvider);
      final oldPath = before.navIconPath(tab, selected: selected);
      await ref
          .read(mainPrefsProvider.notifier)
          .setNavIconPath(tab, selected: selected, path: stored);
      if (oldPath.isNotEmpty && oldPath != stored) {
        final after = ref.read(mainPrefsProvider);
        await NavIconStore.deleteIfUnused(
          oldPath,
          keep: _navIconPathsOf(after),
        );
      }
    } on ContainerImagePickException catch (e) {
      if (context.mounted) _toast(context, e.message);
    } on FormatException catch (e) {
      if (context.mounted) _toast(context, e.message);
    } on UnsupportedError catch (e) {
      if (context.mounted) {
        _toast(context, e.message ?? '当前平台不支持自定义导航图标');
      }
    } catch (e) {
      if (context.mounted) _toast(context, '图标保存失败，请重试');
    }
  }

  Future<void> _clearIcon(WidgetRef ref) async {
    final before = ref.read(mainPrefsProvider);
    final oldPath = before.navIconPath(tab, selected: selected);
    await ref
        .read(mainPrefsProvider.notifier)
        .setNavIconPath(tab, selected: selected, path: '');
    if (oldPath.isNotEmpty) {
      final after = ref.read(mainPrefsProvider);
      await NavIconStore.deleteIfUnused(oldPath, keep: _navIconPathsOf(after));
    }
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 当前全部图标偏好值（相对标识或旧绝对路径）
Iterable<String> _navIconPathsOf(MainPrefsState state) sync* {
  for (final path in state.navIconPaths.values) {
    if (path.isNotEmpty) yield path;
  }
  for (final path in state.navIconSelectedPaths.values) {
    if (path.isNotEmpty) yield path;
  }
}
