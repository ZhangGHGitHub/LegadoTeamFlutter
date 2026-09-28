import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';

/// 阅读器「离线缓存」章节范围选择对话框（两个阅读顶栏共享实现）
///
/// [P2-27 | 2026-09-28] 统一菜单面板顶栏与工具栏顶栏的下载入口行为：
/// 点击下载图标弹出「离线缓存」范围对话框（对齐原版
/// BaseReadBookActivity.showBookDownloadDialog / 参考版 DownloadSheet），
/// 不再存在「直接缓存当前章」的快捷行为（当前章保留为默认起始值）。
///
/// 语义对齐原版：
/// - 标题 = offline_cache（离线缓存）
/// - 默认起始 = 当前章（1-based = currentChapterIndex + 1，
///   对应原版 book.durChapterIndex + 1）
/// - 默认结束 = 总章数（已加载目录 chapters.length）
/// - 确认时转 0-based 含端点索引（契约 §2.43.3：Rust 侧超界自动截断）
///
/// 保留既有校验（与顶栏原 _showCacheDialog 一致）：
/// - 空输入：起始 → 1，结束 → 总章数
/// - start < 1 || end > 总章数 || start > end →「章节范围无效」
void showReaderOfflineCacheDialog(BuildContext context, WidgetRef ref) {
  final state = ref.read(readerNotifierProvider);
  final book = state.currentBook;
  final chapters = state.chapters;
  if (book == null || chapters.isEmpty) return;
  if (book.origin == BookType.localTag) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('本地书籍无需缓存')));
    return;
  }
  final totalChapters = chapters.length;
  // 默认起始 = 当前章（1-based，对齐原版 durChapterIndex + 1）
  final startCtrl =
      TextEditingController(text: '${state.currentChapterIndex + 1}');
  final endCtrl = TextEditingController(text: '$totalChapters');
  final messenger = ScaffoldMessenger.of(context);

  showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('离线缓存'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: startCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '起始章节序号'),
          ),
          TextField(
            controller: endCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: '结束章节序号（共 $totalChapters 章）',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(dialogContext);
            final start = int.tryParse(startCtrl.text) ?? 1;
            final end = int.tryParse(endCtrl.text) ?? totalChapters;
            if (start < 1 || end > totalChapters || start > end) {
              messenger.showSnackBar(
                const SnackBar(content: Text('章节范围无效')),
              );
              return;
            }
            final count = end - start + 1;
            try {
              // 0-based 索引（含端点）；Rust 侧超界自动截断
              await ref
                  .read(bookApiProvider)
                  .cacheDownloadStart(book.bookUrl, start - 1, end - 1);
              if (context.mounted) {
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      '已加入缓存队列：$count 章（可在书籍菜单「缓存管理」查看进度）',
                    ),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                messenger.showSnackBar(
                  SnackBar(content: Text('缓存启动失败：$e')),
                );
              }
            }
          },
          child: const Text('开始缓存'),
        ),
      ],
    ),
  );
}
