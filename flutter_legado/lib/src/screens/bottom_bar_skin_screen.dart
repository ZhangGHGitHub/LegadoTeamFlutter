import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/bottom_bar_skin_notifier.dart';
import '../services/bottom_bar_skin_format.dart';
import '../services/bottom_bar_skin_service.dart';
import '../widgets/ios_widgets.dart';

/// 底栏皮肤管理（对齐原版 BottomBarSkinActivity 最小可用）
///
/// 设计：iOS 分组列表——系统默认 + 已导入皮肤；导入命名槽位 zip；点选启用。
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
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _confirmDelete(context, notifier, name),
                    ),
                    onTap: () => notifier.setActive(name),
                  ),
              ],
            ),
            const IosSectionFooter(
              '导入 zip：文件名需为 bookshelf/home/notes/settings 的 '
              '_selected / _normal 图片（对齐原版槽位命名）。',
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
            Text(slot, style: const TextStyle(fontSize: 10)),
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
    try {
      final name = await notifier.importZipFile(File(path));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入并启用：$name')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
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
