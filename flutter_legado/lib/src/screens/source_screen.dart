import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../providers/source/source_notifier.dart';
import '../routes.dart';
import '../services/source_import_service.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/confirm_dialog.dart';
import 'source_edit_screen.dart';

/// 书源管理页面
class SourceScreen extends ConsumerStatefulWidget {
  const SourceScreen({super.key});

  @override
  ConsumerState<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends ConsumerState<SourceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sourceNotifierProvider.notifier).loadSources();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sourceNotifierProvider);

    return PopScope(
      canPop: !state.batchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && state.batchMode) {
          ref.read(sourceNotifierProvider.notifier).exitBatchMode();
        }
      },
      child: Scaffold(
        appBar: state.batchMode
            ? _buildBatchAppBar(context, state)
            : _buildAppBar(context),
        body: _buildBody(context),
        floatingActionButton:
            !state.batchMode ? _buildFab(context) : null,
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: const Text('书源管理'),
      bottom: TabBar(
        controller: _tabController,
        tabs: const [
          Tab(text: '全部'),
          Tab(text: '已启用'),
          Tab(text: '已禁用'),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索书源',
          onPressed: () => _showSearchDialog(context),
        ),
        // 排序菜单（对标 Android action_sort 子菜单）
        PopupMenuButton<String>(
          icon: const Icon(Icons.sort),
          tooltip: '排序',
          onSelected: (value) => _handleSortAction(context, value),
          itemBuilder: (_) => _buildSortMenuItems(context),
        ),
        PopupMenuButton<String>(
          onSelected: (value) => _handleAction(context, value),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'new', child: Text('新建书源')),
            const PopupMenuDivider(),
            const PopupMenuItem(
                value: 'import_url', child: Text('从 URL 导入')),
            const PopupMenuItem(
                value: 'import_file', child: Text('从文件导入')),
            const PopupMenuItem(
                value: 'import_qr', child: Text('扫码导入')),
            const PopupMenuItem(
                value: 'import_clipboard', child: Text('从剪贴板导入')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'export_all', child: Text('导出全部书源')),
            const PopupMenuItem(
                value: 'export_selected', child: Text('导出选中分组')),
            const PopupMenuItem(
                value: 'export_file', child: Text('导出到文件')),
            const PopupMenuDivider(),
            const PopupMenuItem(
                value: 'batch_mode', child: Text('批量操作')),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildBatchAppBar(
      BuildContext context, SourceState state) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () =>
            ref.read(sourceNotifierProvider.notifier).exitBatchMode(),
      ),
      title: Text('已选择 ${state.selectedCount} 项'),
      actions: [
        IconButton(
          icon: Icon(state.isAllSelected
              ? Icons.check_box
              : Icons.check_box_outline_blank),
          tooltip: '全选',
          onPressed: () {
            final notifier = ref.read(sourceNotifierProvider.notifier);
            if (state.isAllSelected) {
              notifier.deselectAll();
            } else {
              notifier.selectAll();
            }
          },
        ),
        PopupMenuButton<String>(
          onSelected: (value) => _handleBatchAction(context, value),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'enable', child: Text('批量启用')),
            const PopupMenuItem(value: 'disable', child: Text('批量禁用')),
            const PopupMenuItem(value: 'delete', child: Text('批量删除')),
            const PopupMenuItem(value: 'export', child: Text('导出选中')),
          ],
        ),
      ],
    );
  }

  Widget? _buildFab(BuildContext context) {
    return FloatingActionButton(
      tooltip: '新建书源',
      onPressed: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const SourceEditScreen(),
          ),
        );
      },
      child: const Icon(Icons.add),
    );
  }

  Widget _buildBody(BuildContext context) {
    final state = ref.watch(sourceNotifierProvider);

    if (state.loading && state.sources.isEmpty) {
      return const LoadingIndicator(message: '加载书源...');
    }

    if (state.error != null && state.sources.isEmpty) {
      return ErrorView(
        message: state.error!,
        onRetry: () => ref.read(sourceNotifierProvider.notifier).loadSources(),
      );
    }

    return Column(
      children: [
        // 分组筛选 Chip
        if (state.groups.isNotEmpty) _buildGroupChips(context, state),
        // 书源列表
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSourceList(context, state.filteredSources),
              _buildSourceList(context, state.enabledSources),
              _buildSourceList(context, state.disabledSources),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGroupChips(BuildContext context, SourceState state) {
    final groups = state.groups;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: SizedBox(
        height: 36,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: groups.length + 1, // +1 for "全部"
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            if (index == 0) {
              final selected = state.selectedGroup == null;
              return FilterChip(
                label: const Text('全部'),
                selected: selected,
                onSelected: (_) =>
                    ref.read(sourceNotifierProvider.notifier).setGroup(null),
              );
            }
            final group = groups[index - 1];
            final selected = state.selectedGroup == group;
            return FilterChip(
              label: Text(group),
              selected: selected,
              onSelected: (_) => ref
                  .read(sourceNotifierProvider.notifier)
                  .setGroup(selected ? null : group),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSourceList(BuildContext context, List<BookSource> sources) {
    if (sources.isEmpty) {
      return const EmptyState(
        icon: Icons.library_books_outlined,
        title: '暂无书源',
        subtitle: '点击右下角按钮新建书源，或从菜单导入',
      );
    }

    final state = ref.watch(sourceNotifierProvider);

    return ListView.separated(
      itemCount: sources.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 60),
      itemBuilder: (context, index) {
        final source = sources[index];
        return state.batchMode
            ? _buildBatchSourceItem(context, source, state)
            : _buildSourceItem(context, source);
      },
    );
  }

  Widget _buildSourceItem(BuildContext context, BookSource source) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Text(
          source.bookSourceName.isNotEmpty
              ? source.bookSourceName[0]
              : '?',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ),
      title: Text(
        source.bookSourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        source.bookSourceGroup ?? '未分组',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      trailing: Switch(
        value: source.enabled,
        onChanged: (_) => ref
            .read(sourceNotifierProvider.notifier)
            .toggleSource(source.bookSourceUrl),
      ),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceEditScreen(sourceUrl: source.bookSourceUrl),
          ),
        );
      },
      onLongPress: () => _showSourceMenu(context, source),
    );
  }

  Widget _buildBatchSourceItem(
      BuildContext context, BookSource source, SourceState state) {
    final selected = state.isSelected(source.bookSourceUrl);
    return ListTile(
      leading: Checkbox(
        value: selected,
        onChanged: (_) => ref
            .read(sourceNotifierProvider.notifier)
            .toggleSelection(source.bookSourceUrl),
      ),
      title: Text(
        source.bookSourceName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        source.bookSourceGroup ?? '未分组',
        style: Theme.of(context).textTheme.bodySmall,
      ),
      onTap: () => ref
          .read(sourceNotifierProvider.notifier)
          .toggleSelection(source.bookSourceUrl),
    );
  }

  Future<void> _showSourceMenu(BuildContext context, BookSource source) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.share),
              title: const Text('分享'),
              onTap: () => Navigator.pop(ctx, 'share'),
            ),
            ListTile(
              leading:
                  Icon(Icons.delete, color: Theme.of(ctx).colorScheme.error),
              title: Text('删除',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );

    if (action == null) return;

    if (action == 'edit') {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SourceEditScreen(sourceUrl: source.bookSourceUrl),
        ),
      );
    } else if (action == 'share') {
      if (!context.mounted) return;
      await _shareSource(context, source);
    } else if (action == 'delete') {
      if (!context.mounted) return;
      final confirmed = await showConfirmDialog(
        context,
        title: '删除书源',
        content: '确定要删除书源「${source.bookSourceName}」吗？',
        confirmText: '删除',
        isDestructive: true,
      );
      if (confirmed && context.mounted) {
        ref
            .read(sourceNotifierProvider.notifier)
            .deleteSource(source.bookSourceUrl);
      }
    }
  }

  Future<void> _shareSource(BuildContext context, BookSource source) async {
    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final json = await notifier.backupService
          .exportSelectedSources([source.bookSourceUrl]);
      await Share.share(json, subject: '书源分享：${source.bookSourceName}');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分享失败：$e')),
        );
      }
    }
  }

  void _showSearchDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('搜索书源'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '输入书源名称或分组',
          ),
          onChanged: (v) =>
              ref.read(sourceNotifierProvider.notifier).setFilter(v),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dispose();
              ref.read(sourceNotifierProvider.notifier).clearFilter();
              Navigator.pop(ctx);
            },
            child: const Text('清除'),
          ),
          TextButton(
            onPressed: () {
              controller.dispose();
              Navigator.pop(ctx);
            },
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  void _handleAction(BuildContext context, String action) {
    switch (action) {
      case 'new':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const SourceEditScreen()),
        );
        break;
      case 'import_url':
        _showImportUrlDialog(context);
        break;
      case 'import_file':
        _importFromFile(context);
        break;
      case 'import_qr':
        _importFromQrCode(context);
        break;
      case 'import_clipboard':
        _importFromClipboard(context);
        break;
      case 'export_all':
        _exportAllSources(context);
        break;
      case 'export_selected':
        _exportSelectedGroup(context);
        break;
      case 'export_file':
        _exportAllToFile(context);
        break;
      case 'batch_mode':
        ref.read(sourceNotifierProvider.notifier).enterBatchMode();
        break;
    }
  }

  /// 排序菜单项（对标 Android menu_sort_manual/auto/name/url + menu_sort_desc）
  List<PopupMenuEntry<String>> _buildSortMenuItems(BuildContext context) {
    final state = ref.read(sourceNotifierProvider);
    PopupMenuItem<String> sortItem(SourceSort sort, String label) {
      final selected = state.sort == sort;
      return PopupMenuItem(
        value: 'sort_${sort.name}',
        child: Row(
          children: [
            Icon(
              selected ? Icons.check : null,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );
    }

    return [
      PopupMenuItem(
        value: 'sort_desc',
        child: Row(
          children: [
            Icon(
              state.sortAscending ? null : Icons.check,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Text('降序'),
          ],
        ),
      ),
      const PopupMenuDivider(),
      sortItem(SourceSort.manual, '手动排序'),
      sortItem(SourceSort.weight, '自动排序（权重）'),
      sortItem(SourceSort.name, '按名称'),
      sortItem(SourceSort.url, '按 URL'),
      sortItem(SourceSort.update, '按更新时间'),
      sortItem(SourceSort.enable, '按启用状态'),
      sortItem(SourceSort.respond, '按响应时间'),
    ];
  }

  void _handleSortAction(BuildContext context, String action) {
    final notifier = ref.read(sourceNotifierProvider.notifier);
    if (action == 'sort_desc') {
      notifier.toggleSortDirection();
      return;
    }
    if (action.startsWith('sort_')) {
      final name = action.substring('sort_'.length);
      final sort = SourceSort.values.firstWhere(
        (e) => e.name == name,
        orElse: () => SourceSort.manual,
      );
      notifier.setSort(sort);
    }
  }

  void _handleBatchAction(BuildContext context, String action) async {
    final notifier = ref.read(sourceNotifierProvider.notifier);
    final state = ref.read(sourceNotifierProvider);
    if (state.selectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择书源')),
      );
      return;
    }

    switch (action) {
      case 'enable':
        await notifier.batchEnable();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('批量启用完成')),
          );
        }
        break;
      case 'disable':
        await notifier.batchDisable();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('批量禁用完成')),
          );
        }
        break;
      case 'delete':
        if (!context.mounted) return;
        final confirmed = await showConfirmDialog(
          context,
          title: '批量删除',
          content: '确定要删除选中的 ${state.selectedCount} 个书源吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (confirmed && context.mounted) {
          await notifier.batchDelete();
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('批量删除完成')),
            );
          }
        }
        break;
      case 'export':
        await _exportBatchSelected(context);
        break;
    }
  }

  void _showImportUrlDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从 URL 导入书源'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '输入书源 URL 地址',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final url = controller.text.trim();
              if (url.isEmpty) return;
              Navigator.pop(ctx);
              controller.dispose();

              final notifier = ref.read(sourceNotifierProvider.notifier);
              final result = await notifier.importFromUrl(url);

              if (context.mounted) {
                _showImportResult(context, result);
              }
            },
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  Future<void> _importFromClipboard(BuildContext context) async {
    final notifier = ref.read(sourceNotifierProvider.notifier);
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;

      if (text == null || text.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('剪贴板为空')),
          );
        }
        return;
      }

      final result = await notifier.importFromJson(text);

      if (!context.mounted) return;
      _showImportResult(context, result);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('剪贴板读取失败：$e')),
        );
      }
    }
  }

  /// 从本地文件导入书源（对标 Android menu_import_local，txt/json）
  Future<void> _importFromFile(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (picked == null || picked.files.isEmpty) return;

      final path = picked.files.single.path;
      if (path == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('无法获取文件路径')),
        );
        return;
      }

      if (!context.mounted) return;
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final result = await notifier.importFromFile(path);

      if (!context.mounted) return;
      _showImportResult(context, result);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('从文件导入失败：$e')),
        );
      }
    }
  }

  /// 扫码导入书源（对标 Android menu_import_qr）
  ///
  /// 扫码页返回内容后按类型分流：HTTP URL → 远程拉取；书源 JSON → 直接解析；
  /// legado:// 协议链接 → 提示使用关联导入页（支持多类型）。
  Future<void> _importFromQrCode(BuildContext context) async {
    final content = await Navigator.of(context)
        .pushNamed<String>(AppRoutes.qrcode);
    if (!context.mounted) return;
    if (content == null || content.trim().isEmpty) return;

    final trimmed = content.trim();
    final messenger = ScaffoldMessenger.of(context);

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final result = await notifier.importFromUrl(trimmed);
      if (context.mounted) _showImportResult(context, result);
      return;
    }

    if (trimmed.startsWith('[') || trimmed.startsWith('{')) {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final result = await notifier.importFromJson(trimmed);
      if (context.mounted) _showImportResult(context, result);
      return;
    }

    if (trimmed.startsWith('legado://')) {
      messenger.showSnackBar(
        const SnackBar(content: Text('legado 协议链接请使用「关联导入」页处理')),
      );
      return;
    }

    messenger.showSnackBar(
      const SnackBar(content: Text('扫码内容不是可识别的书源数据')),
    );
  }

  void _showImportResult(BuildContext context, ImportResult result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入结果'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.summary),
            if (result.errors.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('详细信息：',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView(
                  shrinkWrap: true,
                  children: result.errors
                      .map((e) => Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(e,
                                style: Theme.of(ctx).textTheme.bodySmall),
                          ))
                      .toList(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportAllSources(BuildContext context) async {
    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final json = await notifier.exportAllSources();

      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('全部书源已复制到剪贴板')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  /// 导出全部书源到文件（对标 Android menu_export_selection 的 saveToFile）
  Future<void> _exportAllToFile(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final json = await notifier.exportAllSources();

      final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择书源导出目录',
      );
      if (!context.mounted) return;
      if (dir == null) {
        messenger.showSnackBar(const SnackBar(content: Text('未选择导出目录')));
        return;
      }

      final timestamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .split('.')
          .first;
      final filePath = '$dir${Platform.pathSeparator}bookSources_$timestamp.json';
      await File(filePath).writeAsString(json, flush: true);

      if (context.mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('已导出到：$filePath')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出到文件失败：$e')),
        );
      }
    }
  }

  Future<void> _exportSelectedGroup(BuildContext context) async {
    final state = ref.read(sourceNotifierProvider);
    final group = state.selectedGroup;

    if (group == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一个分组')),
      );
      return;
    }

    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final sources = state.filteredSources;
      final urls = sources.map((s) => s.bookSourceUrl).toList();
      final json = await notifier.backupService.exportSelectedSources(urls);

      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('分组「$group」书源已复制到剪贴板')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }

  Future<void> _exportBatchSelected(BuildContext context) async {
    try {
      final notifier = ref.read(sourceNotifierProvider.notifier);
      final state = ref.read(sourceNotifierProvider);
      final json = await notifier.exportSelectedSources();

      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('已导出 ${state.selectedCount} 个书源到剪贴板')),
        );
      }
      notifier.exitBatchMode();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }
}
