import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/bottom_bar_skin_notifier.dart';
import '../services/bottom_bar_skin_format.dart';
import '../services/bottom_bar_skin_service.dart';
import '../widgets/ios_widgets.dart';
import 'bottom_bar_skin_assign_screen.dart';

/// 底栏皮肤管理（对齐 BottomBarSkinActivity）
///
/// 导入 zip → 分配页选槽位 → 启用/删除/编辑；底栏读 PrefKeys.bottomBarSkin 换图标。
class BottomBarSkinScreen extends ConsumerWidget {
  const BottomBarSkinScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bottomBarSkinProvider);
    final notifier = ref.read(bottomBarSkinProvider.notifier);

    return Scaffold(
      appBar: AppBar(
        title: const Text('底部操作栏皮肤'),
        actions: [
          IconButton(
            tooltip: '导入',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: () => _import(context, notifier),
          ),
        ],
      ),
      body: IosGroupedBody(
        child: ListView(
          children: [
            const IosSectionHeader('皮肤'),
            IosGroup(
              children: [
                ListTile(
                  leading: Icon(
                    state.active.isEmpty
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                  ),
                  title: const Text('系统默认'),
                  onTap: () => notifier.setActive(''),
                ),
                for (final name in state.skins)
                  ListTile(
                    leading: Icon(
                      state.active == name
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                    ),
                    title: Text(name),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_horiz),
                      onPressed: () => _showItemMenu(context, notifier, name),
                    ),
                    onTap: () => notifier.setActive(name),
                    onLongPress: () => _showItemMenu(context, notifier, name),
                  ),
              ],
            ),
            const IosSectionFooter(
              '导入 zip 后进入分配页：为书架/发现/订阅/我的各选「选中」图'
              '（「未选」可空）。若文件名已是 bookshelf_selected 等，将自动预填。',
            ),
            if (state.loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  state.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (state.active.isNotEmpty)
              FutureBuilder(
                future: _previewRows(state.active),
                builder: (context, snap) {
                  final rows = snap.data;
                  if (rows == null || rows.isEmpty) {
                    return const SizedBox.shrink();
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const IosSectionHeader('预览'),
                      IosGroup(
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceAround,
                              children: rows,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<List<Widget>> _previewRows(String skin) async {
    final service = BottomBarSkinService.instance;
    final widgets = <Widget>[];
    for (final slot in BottomBarSkinFormat.mappedSlots) {
      final icons = await service.iconsForSlot(skin, slot);
      final path = icons.selected ?? icons.normal;
      widgets.add(
        Column(
          children: [
            if (path != null)
              Image.file(File(path), width: 28, height: 28, fit: BoxFit.contain)
            else
              const Icon(Icons.image_not_supported_outlined, size: 28),
            const SizedBox(height: 4),
            Text(
              BottomBarSkinFormat.slotLabels[slot] ?? slot,
              style: const TextStyle(fontSize: 10),
            ),
          ],
        ),
      );
    }
    return widgets;
  }

  Future<void> _import(
    BuildContext context,
    BottomBarSkinNotifier notifier,
  ) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    final path = result?.files.single.path;
    if (path == null) return;
    final zip = File(path);
    String? sessionId;
    try {
      sessionId =
          await BottomBarSkinService.instance.extractZipToSession(zip);
      final preferred = zip.uri.pathSegments.last.replaceAll(
        RegExp(r'\.zip$', caseSensitive: false),
        '',
      );
      if (!context.mounted) {
        await BottomBarSkinService.instance.discardSession(sessionId);
        return;
      }
      final name = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => BottomBarSkinAssignScreen(
            sessionId: sessionId!,
            preferredName: preferred,
          ),
        ),
      );
      sessionId = null; // Assign 屏负责 discard 或已保存
      if (name != null) {
        await notifier.reload();
        await notifier.setActive(name);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已保存并启用：$name')),
          );
        }
      } else {
        await notifier.reload();
      }
    } catch (e) {
      if (sessionId != null) {
        await BottomBarSkinService.instance.discardSession(sessionId);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    }
  }

  Future<void> _showItemMenu(
    BuildContext context,
    BottomBarSkinNotifier notifier,
    String name,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(name),
              enabled: false,
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('编辑'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'delete') {
      await _confirmDelete(context, notifier, name);
    } else if (action == 'edit') {
      await _edit(context, notifier, name);
    }
  }

  Future<void> _edit(
    BuildContext context,
    BottomBarSkinNotifier notifier,
    String name,
  ) async {
    String? sessionId;
    try {
      sessionId = await BottomBarSkinService.instance.stageExisting(name);
      if (!context.mounted) {
        await BottomBarSkinService.instance.discardSession(sessionId);
        return;
      }
      final saved = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => BottomBarSkinAssignScreen(
            sessionId: sessionId!,
            preferredName: name,
            editName: name,
          ),
        ),
      );
      sessionId = null;
      await notifier.reload();
      if (saved != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已更新：$saved')),
        );
      }
    } catch (e) {
      if (sessionId != null) {
        await BottomBarSkinService.instance.discardSession(sessionId);
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法编辑：$e')),
        );
      }
    }
  }

  Future<void> _confirmDelete(
    BuildContext context,
    BottomBarSkinNotifier notifier,
    String name,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除皮肤'),
        content: Text('确定删除「$name」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await notifier.delete(name);
  }
}
