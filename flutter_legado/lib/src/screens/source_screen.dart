import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../providers/source_provider.dart';
import '../services/source_import_service.dart';
import '../widgets/empty_state.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/confirm_dialog.dart';
import 'source_edit_screen.dart';

/// 书源管理页面
class SourceScreen extends StatefulWidget {
  const SourceScreen({super.key});

  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends State<SourceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<SourceProvider>().loadSources();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<SourceProvider>();

    return PopScope(
      canPop: !provider.batchMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && provider.batchMode) {
          provider.exitBatchMode();
        }
      },
      child: Scaffold(
        appBar: provider.batchMode
            ? _buildBatchAppBar(context, provider)
            : _buildAppBar(context),
        body: _buildBody(context),
        floatingActionButton:
            !provider.batchMode ? _buildFab(context) : null,
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
        PopupMenuButton<String>(
          onSelected: (value) => _handleAction(context, value),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'new', child: Text('新建书源')),
            const PopupMenuDivider(),
            const PopupMenuItem(
                value: 'import_url', child: Text('从 URL 导入')),
            const PopupMenuItem(
                value: 'import_clipboard', child: Text('从剪贴板导入')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'export_all', child: Text('导出全部书源')),
            const PopupMenuItem(
                value: 'export_selected', child: Text('导出选中分组')),
            const PopupMenuDivider(),
            const PopupMenuItem(
                value: 'batch_mode', child: Text('批量操作')),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _buildBatchAppBar(
      BuildContext context, SourceProvider provider) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => provider.exitBatchMode(),
      ),
      title: Text('已选择 ${provider.selectedCount} 项'),
      actions: [
        IconButton(
          icon: Icon(provider.isAllSelected
              ? Icons.check_box
              : Icons.check_box_outline_blank),
          tooltip: '全选',
          onPressed: () {
            if (provider.isAllSelected) {
              provider.deselectAll();
            } else {
              provider.selectAll();
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
    final provider = context.watch<SourceProvider>();

    if (provider.loading && provider.sources.isEmpty) {
      return const LoadingIndicator(message: '加载书源...');
    }

    if (provider.error != null && provider.sources.isEmpty) {
      return ErrorView(
        message: provider.error!,
        onRetry: () => provider.loadSources(),
      );
    }

    return Column(
      children: [
        // 分组筛选 Chip
        if (provider.groups.isNotEmpty) _buildGroupChips(context, provider),
        // 书源列表
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [
              _buildSourceList(context, provider.filteredSources),
              _buildSourceList(context, provider.enabledSources),
              _buildSourceList(context, provider.disabledSources),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildGroupChips(BuildContext context, SourceProvider provider) {
    final groups = provider.groups;
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
              final selected = provider.selectedGroup == null;
              return FilterChip(
                label: const Text('全部'),
                selected: selected,
                onSelected: (_) => provider.setGroup(null),
              );
            }
            final group = groups[index - 1];
            final selected = provider.selectedGroup == group;
            return FilterChip(
              label: Text(group),
              selected: selected,
              onSelected: (_) =>
                  provider.setGroup(selected ? null : group),
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

    final provider = context.watch<SourceProvider>();

    return ListView.separated(
      itemCount: sources.length,
      separatorBuilder: (_, _) => const Divider(height: 1, indent: 60),
      itemBuilder: (context, index) {
        final source = sources[index];
        return provider.batchMode
            ? _buildBatchSourceItem(context, source, provider)
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
        onChanged: (_) =>
            context.read<SourceProvider>().toggleSource(source.bookSourceUrl),
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
      BuildContext context, BookSource source, SourceProvider provider) {
    final selected = provider.isSelected(source.bookSourceUrl);
    return ListTile(
      leading: Checkbox(
        value: selected,
        onChanged: (_) => provider.toggleSelection(source.bookSourceUrl),
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
      onTap: () => provider.toggleSelection(source.bookSourceUrl),
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
        context.read<SourceProvider>().deleteSource(source.bookSourceUrl);
      }
    }
  }

  Future<void> _shareSource(BuildContext context, BookSource source) async {
    try {
      final provider = context.read<SourceProvider>();
      final json =
          await provider.backupService.exportSelectedSources([source.bookSourceUrl]);
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
          onChanged: (v) => context.read<SourceProvider>().setFilter(v),
        ),
        actions: [
          TextButton(
            onPressed: () {
              controller.dispose();
              context.read<SourceProvider>().clearFilter();
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
      case 'import_clipboard':
        _importFromClipboard(context);
        break;
      case 'export_all':
        _exportAllSources(context);
        break;
      case 'export_selected':
        _exportSelectedGroup(context);
        break;
      case 'batch_mode':
        context.read<SourceProvider>().enterBatchMode();
        break;
    }
  }

  void _handleBatchAction(BuildContext context, String action) async {
    final provider = context.read<SourceProvider>();
    if (provider.selectedCount == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择书源')),
      );
      return;
    }

    switch (action) {
      case 'enable':
        await provider.batchEnable();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('批量启用完成')),
          );
        }
        break;
      case 'disable':
        await provider.batchDisable();
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
          content: '确定要删除选中的 ${provider.selectedCount} 个书源吗？',
          confirmText: '删除',
          isDestructive: true,
        );
        if (confirmed && context.mounted) {
          await provider.batchDelete();
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

              final provider = context.read<SourceProvider>();
              final result = await provider.importFromUrl(url);

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
    final provider = context.read<SourceProvider>();
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

      final result = await provider.importFromJson(text);

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
      final provider = context.read<SourceProvider>();
      final json = await provider.exportAllSources();

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

  Future<void> _exportSelectedGroup(BuildContext context) async {
    final provider = context.read<SourceProvider>();
    final group = provider.selectedGroup;

    if (group == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择一个分组')),
      );
      return;
    }

    try {
      final sources = provider.filteredSources;
      final urls = sources.map((s) => s.bookSourceUrl).toList();
      final json = await provider.backupService.exportSelectedSources(urls);

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
      final provider = context.read<SourceProvider>();
      final json = await provider.exportSelectedSources();

      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('已导出 ${provider.selectedCount} 个书源到剪贴板')),
        );
      }
      provider.exitBatchMode();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败：$e')),
        );
      }
    }
  }
}
