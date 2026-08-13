import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/remote_book/remote_book_notifier.dart';
import '../routes.dart';
import '../services/settings_service.dart';
import '../widgets/help/help_assets.dart';
import '../widgets/help/show_help.dart';

/// 远程书库（对齐原版 RemoteBookActivity）
///
/// 服务器列表 + WebDAV 目录浏览 + 多选导入本地书架。
class RemoteBookScreen extends ConsumerStatefulWidget {
  const RemoteBookScreen({super.key});

  @override
  ConsumerState<RemoteBookScreen> createState() => _RemoteBookScreenState();
}

class _RemoteBookScreenState extends ConsumerState<RemoteBookScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(remoteBookNotifierProvider.notifier).init();
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _onWillPop() async {
    final notifier = ref.read(remoteBookNotifierProvider.notifier);
    if (notifier.goBackDir()) return;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _importSelected() async {
    final notifier = ref.read(remoteBookNotifierProvider.notifier);
    await notifier.addSelectedToBookshelf();
    if (!mounted) return;
    final state = ref.read(remoteBookNotifierProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (state.error != null && (state.importedCount ?? 0) == 0) {
      messenger.showSnackBar(SnackBar(content: Text(state.error!)));
      return;
    }
    final count = state.importedCount ?? 0;
    messenger.showSnackBar(SnackBar(content: Text('成功导入 $count 本')));
    if (count > 0) {
      ref.read(bookshelfNotifierProvider.notifier).refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(remoteBookNotifierProvider);
    final notifier = ref.read(remoteBookNotifierProvider.notifier);
    final theme = Theme.of(context);
    final selectedCount = state.selectedPaths.length;

    return PopScope(
      canPop: state.dirStack.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onWillPop();
      },
      child: Scaffold(
        appBar: LegadoAppBar(
          title: const Text('远程书籍'),
          actions: [
            IconButton(
              icon: const Icon(Icons.help_outline),
              tooltip: '帮助',
              onPressed: () => showHelp(context, HelpAssets.webDavBookHelp),
            ),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: state.isLoading ? null : () => notifier.refresh(),
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'server':
                    await _showServersDialog();
                  case 'sort_name':
                    notifier.setSort(RemoteBookSort.name);
                  case 'sort_time':
                    notifier.setSort(RemoteBookSort.time);
                  case 'webdav_settings':
                    await Navigator.pushNamed(context, AppRoutes.webdavSettings);
                    await notifier.init();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'server', child: Text('服务器配置')),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'sort_name',
                  checked: state.sortKey == RemoteBookSort.name,
                  child: const Text('按名称'),
                ),
                CheckedPopupMenuItem(
                  value: 'sort_time',
                  checked: state.sortKey == RemoteBookSort.time,
                  child: const Text('按时间'),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'webdav_settings',
                  child: Text('默认 WebDAV 设置'),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          children: [
            Material(
              color: theme.colorScheme.surfaceContainerHighest
                  .withValues(alpha: 0.45),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '返回上级',
                      onPressed:
                          state.dirStack.isEmpty ? null : () => notifier.goBackDir(),
                      icon: const Icon(Icons.arrow_back),
                    ),
                    Expanded(
                      child: Text(
                        state.displayPath,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: '筛选 • 远程书籍',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: notifier.setFilter,
              ),
            ),
            if (state.error != null && state.items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  state.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Expanded(
              child: state.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : state.visibleItems.isEmpty
                      ? Center(
                          child: Text(
                            '没有文件',
                            style: theme.textTheme.bodyLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        )
                      : ListView.separated(
                          itemCount: state.visibleItems.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            final item = state.visibleItems[index];
                            final selected =
                                state.selectedPaths.contains(item.relativePath);
                            return ListTile(
                              leading: Icon(
                                item.isDir
                                    ? Icons.folder_outlined
                                    : Icons.menu_book_outlined,
                                color: item.isOnBookShelf
                                    ? theme.colorScheme.primary
                                    : null,
                              ),
                              title: Text(item.filename),
                              subtitle: item.isDir
                                  ? const Text('文件夹')
                                  : Text(_formatSize(item.size)),
                              trailing: item.isDir
                                  ? const Icon(Icons.chevron_right)
                                  : item.isOnBookShelf
                                      ? Icon(Icons.check_circle,
                                          color: theme.colorScheme.primary)
                                      : Checkbox(
                                          value: selected,
                                          onChanged: (_) =>
                                              notifier.toggleSelect(item),
                                        ),
                              onTap: () {
                                if (item.isDir) {
                                  notifier.openDir(item);
                                } else if (!item.isOnBookShelf) {
                                  notifier.toggleSelect(item);
                                }
                              },
                              onLongPress: item.isDir || item.isOnBookShelf
                                  ? null
                                  : () => notifier.toggleSelect(item),
                            );
                          },
                        ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: () => notifier.selectAllVisible(true),
                      child: const Text('全选'),
                    ),
                    TextButton(
                      onPressed: notifier.revertSelection,
                      child: const Text('反选'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: state.isImporting || selectedCount == 0
                          ? null
                          : _importSelected,
                      child: Text(
                        state.isImporting
                            ? '导入中…'
                            : '加入书架${selectedCount > 0 ? ' ($selectedCount)' : ''}',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _showServersDialog() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(remoteBookNotifierProvider);
            final notifier = ref.read(remoteBookNotifierProvider.notifier);
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ListTile(
                      title: Text(
                        '服务器配置',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      trailing: IconButton(
                        tooltip: '添加',
                        icon: const Icon(Icons.add),
                        onPressed: () async {
                          final created = await _editServerDialog();
                          if (created != null) {
                            await notifier.saveServer(created);
                          }
                        },
                      ),
                    ),
                    const Divider(height: 1),
                    RadioListTile<int>(
                      value: SettingsService.defaultRemoteServerId,
                      groupValue: state.serverId,
                      title: const Text('默认'),
                      subtitle: const Text('使用备份设置中的 WebDAV（books/）'),
                      onChanged: (v) async {
                        if (v == null) return;
                        await notifier.selectServer(v);
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                      ),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: state.servers.length,
                        itemBuilder: (_, i) {
                          final s = state.servers[i];
                          return RadioListTile<int>(
                            value: s.id,
                            groupValue: state.serverId,
                            title: Text(s.name.isEmpty ? s.url : s.name),
                            subtitle: Text(s.url, maxLines: 1),
                            secondary: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () async {
                                    final edited =
                                        await _editServerDialog(existing: s);
                                    if (edited != null) {
                                      await notifier.saveServer(edited);
                                    }
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (d) => AlertDialog(
                                        title: const Text('删除'),
                                        content: const Text('确认删除该服务器？'),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(d, false),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(d, true),
                                            child: const Text('删除'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok == true) {
                                      await notifier.deleteServer(s.id);
                                    }
                                  },
                                ),
                              ],
                            ),
                            onChanged: (v) async {
                              if (v == null) return;
                              await notifier.selectServer(v);
                              if (ctx.mounted) Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<RemoteServerConfig?> _editServerDialog({
    RemoteServerConfig? existing,
  }) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final urlCtrl = TextEditingController(text: existing?.url ?? '');
    final userCtrl = TextEditingController(text: existing?.username ?? '');
    final passCtrl = TextEditingController(text: existing?.password ?? '');
    final result = await showDialog<RemoteServerConfig>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? '添加服务器' : '编辑服务器'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: urlCtrl,
                decoration: const InputDecoration(
                  labelText: 'url',
                  hintText: 'https://dav.example.com/books/',
                ),
                keyboardType: TextInputType.url,
              ),
              TextField(
                controller: userCtrl,
                decoration: const InputDecoration(labelText: 'username'),
              ),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'password'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final url = urlCtrl.text.trim();
              if (url.isEmpty) return;
              Navigator.pop(
                ctx,
                RemoteServerConfig(
                  id: existing?.id ?? DateTime.now().millisecondsSinceEpoch,
                  name: nameCtrl.text.trim().isEmpty
                      ? url
                      : nameCtrl.text.trim(),
                  url: url,
                  username: userCtrl.text.trim(),
                  password: passCtrl.text,
                ),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    urlCtrl.dispose();
    userCtrl.dispose();
    passCtrl.dispose();
    return result;
  }
}
