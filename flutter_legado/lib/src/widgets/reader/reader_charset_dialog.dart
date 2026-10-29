// 阅读器「设置编码」对话框（批37，从 reader_top_bar.dart 私有实现抽出）
//
// 本地书（含 WebDAV 导入）读正文时可能需要指定 charset；入口原先只挂在
// 旧工具栏顶栏，菜单面板化后在把该动作放进可配置动作池时复用本实现。
// 行为与旧实现一致：写 Book.charset → 同步 ReaderNotifier → 重载当前章。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../providers/providers.dart' show bookApiProvider;
import '../../providers/reader/reader_notifier.dart';

/// 常用编码候选（对齐原版 showCharsetConfig 的选项集）
const List<String> kReaderCharsets = [
  'UTF-8',
  'GB2312',
  'GB18030',
  'GBK',
  'Unicode',
  'UTF-16',
  'UTF-16LE',
  'ASCII',
];

/// 弹出「设置编码」对话框
void showReaderCharsetDialog(BuildContext context, WidgetRef ref) {
  final book = ref.read(readerNotifierProvider).currentBook;
  if (book == null) return;
  final ctrl = TextEditingController(text: book.charset ?? '');
  final messenger = ScaffoldMessenger.of(context);

  showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('设置编码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(
                labelText: 'charset',
                hintText: '如 UTF-8 / GBK',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final cs in kReaderCharsets)
                  ChoiceChip(
                    label: Text(cs),
                    selected: ctrl.text == cs,
                    onSelected: (_) => setDialogState(() => ctrl.text = cs),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final charset = ctrl.text.trim();
              Navigator.pop(dialogContext);
              if (charset.isEmpty) {
                messenger.showSnackBar(const SnackBar(content: Text('编码不能为空')));
                return;
              }
              unawaited(_applyCharset(context, ref, charset));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

/// 持久化 charset 并重载当前章正文（对标 ReadBook.setCharset）
Future<void> _applyCharset(
  BuildContext context,
  WidgetRef ref,
  String charset,
) async {
  final book = ref.read(readerNotifierProvider).currentBook;
  if (book == null) return;
  final updated = book.copyWith(charset: charset);
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref.read(bookApiProvider).updateBook(updated);
    final notifier = ref.read(readerNotifierProvider.notifier);
    notifier.updateCurrentBook(updated);
    await notifier.reloadChapterContent();
    messenger.showSnackBar(SnackBar(content: Text('已设置编码：$charset')));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('设置编码失败: $e')));
  }
}
