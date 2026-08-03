import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/remote_book/remote_book_notifier.dart';

/// 远程书籍导入页面
///
/// 对标安卓原版 RemoteBookActivity：粘贴书籍链接（每行一个），
/// 批量导入到书架（REFACTORING_REMAINING_PLAN §4.3 P2-2④）。
/// 架构合规（§0.2 铁律）：导入经 RemoteBookNotifier → BookApi.importBooks
/// 委托 Rust，UI 层仅负责输入收集与结果反馈。
class RemoteBookScreen extends ConsumerStatefulWidget {
  const RemoteBookScreen({super.key});

  @override
  ConsumerState<RemoteBookScreen> createState() => _RemoteBookScreenState();
}

class _RemoteBookScreenState extends ConsumerState<RemoteBookScreen> {
  final _textCtrl = TextEditingController();

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  Future<void> _import() async {
    final notifier = ref.read(remoteBookNotifierProvider.notifier);
    await notifier.importUrls(_textCtrl.text);
    if (!mounted) return;
    final state = ref.read(remoteBookNotifierProvider);
    final messenger = ScaffoldMessenger.of(context);
    if (state.error != null) {
      messenger.showSnackBar(SnackBar(content: Text(state.error!)));
      return;
    }
    final count = state.importedCount ?? 0;
    messenger.showSnackBar(
      SnackBar(content: Text('成功导入 $count 本书')),
    );
    // 刷新书架，返回后可见新导入书籍
    ref.read(bookshelfNotifierProvider.notifier).refresh();
    if (count > 0) {
      _textCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = ref.watch(remoteBookNotifierProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('远程书籍导入')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '粘贴书籍链接，每行一个。导入时将自动匹配书源并加入书架。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _textCtrl,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/book/123\n'
                      'https://example.com/book/456',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: state.isImporting ? null : _import,
              icon: state.isImporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(state.isImporting ? '导入中…' : '导入到书架'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
