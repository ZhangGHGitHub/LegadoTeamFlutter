// 阅读器公共动作 helper（批4a）
//
// 从 `widgets/reader/reader_top_bar.dart` 抽出的编辑内容 / 替换开关 /
// 同步阅读进度实现，供顶栏菜单与九宫格点击分发共用；行为保持不变。
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/models.dart';
import '../../providers/providers.dart'
    show bookApiProvider, replaceEnableDefaultProvider;
import '../../providers/reader/reader_notifier.dart';
import '../../providers/sync/sync_notifier.dart';

/// 九宫格动作执行回调（生产环境由 ReaderScreen 注入，测试可计数）
class ReaderTapActionDelegate {
  final VoidCallback toggleControls;
  final VoidCallback nextPage;
  final VoidCallback previousPage;
  final VoidCallback nextChapter;
  final VoidCallback previousChapter;
  final VoidCallback previousParagraph;
  final VoidCallback nextParagraph;
  final VoidCallback addBookmark;
  final VoidCallback editContent;
  final VoidCallback toggleReplace;
  final VoidCallback catalog;
  final VoidCallback search;
  final VoidCallback syncProgress;
  final VoidCallback toggleReadAloud;

  const ReaderTapActionDelegate({
    required this.toggleControls,
    required this.nextPage,
    required this.previousPage,
    required this.nextChapter,
    required this.previousChapter,
    required this.previousParagraph,
    required this.nextParagraph,
    required this.addBookmark,
    required this.editContent,
    required this.toggleReplace,
    required this.catalog,
    required this.search,
    required this.syncProgress,
    required this.toggleReadAloud,
  });
}

/// 朗读暂停/继续：空闲态不启动朗读（对齐参考 isRun no-op）
void toggleReaderReadAloud({
  required bool isPlaying,
  required bool isIdle,
  required VoidCallback pause,
  required VoidCallback resume,
}) {
  if (isPlaying) {
    pause();
    return;
  }
  if (!isIdle) resume();
}

/// 执行九宫格动作（批4a）；none 为空操作。
void dispatchReaderTapAction(
  ReaderTapAction action,
  ReaderTapActionDelegate delegate,
) {
  switch (action) {
    case ReaderTapAction.none:
      break;
    case ReaderTapAction.menu:
      delegate.toggleControls();
    case ReaderTapAction.nextPage:
      delegate.nextPage();
    case ReaderTapAction.previousPage:
      delegate.previousPage();
    case ReaderTapAction.nextChapter:
      delegate.nextChapter();
    case ReaderTapAction.previousChapter:
      delegate.previousChapter();
    case ReaderTapAction.previousParagraph:
      delegate.previousParagraph();
    case ReaderTapAction.nextParagraph:
      delegate.nextParagraph();
    case ReaderTapAction.addBookmark:
      delegate.addBookmark();
    case ReaderTapAction.editContent:
      delegate.editContent();
    case ReaderTapAction.toggleReplace:
      delegate.toggleReplace();
    case ReaderTapAction.catalog:
      delegate.catalog();
    case ReaderTapAction.search:
      delegate.search();
    case ReaderTapAction.syncProgress:
      delegate.syncProgress();
    case ReaderTapAction.toggleReadAloud:
      delegate.toggleReadAloud();
  }
}

void readerActionSnack(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// 编辑当前章正文（保存后写缓存并重载）
Future<void> showReaderEditContentDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final state = ref.read(readerNotifierProvider);
  final chapter = state.currentChapter;
  final ctrl = TextEditingController(text: state.chapterContent);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(chapter != null ? '编辑：${chapter.title}' : '编辑内容'),
      content: SizedBox(
        width: double.maxFinite,
        child: TextField(
          controller: ctrl,
          maxLines: null,
          minLines: 12,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            unawaited(_saveEditedContent(context, ref, ctrl.text));
          },
          child: const Text('保存'),
        ),
      ],
    ),
  );
}

Future<void> _saveEditedContent(
  BuildContext context,
  WidgetRef ref,
  String content,
) async {
  final state = ref.read(readerNotifierProvider);
  final book = state.currentBook;
  if (book == null) return;
  try {
    final ok = await ref
        .read(bookApiProvider)
        .saveChapterContent(
          bookUrl: book.bookUrl,
          chapterIndex: state.currentChapterIndex,
          title: state.currentChapter?.title ?? '',
          content: content,
        );
    if (!context.mounted) return;
    if (ok) {
      await ref.read(readerNotifierProvider.notifier).reloadChapterContent();
      if (context.mounted) readerActionSnack(context, '章节内容已保存');
    } else {
      readerActionSnack(context, '章节内容保存失败');
    }
  } catch (e) {
    if (context.mounted) readerActionSnack(context, '章节内容保存失败：$e');
  }
}

/// 更新当前书 ReadConfig 字段并持久化，随后重载当前章正文
Future<void> updateReaderBookConfig(
  BuildContext context,
  WidgetRef ref,
  ReadConfig Function(ReadConfig config) transform,
) async {
  final book = ref.read(readerNotifierProvider).currentBook;
  if (book == null) return;
  final updated = book.copyWith(
    readConfig: transform(book.readConfig ?? const ReadConfig()),
  );
  try {
    await ref.read(bookApiProvider).updateBook(updated);
    final notifier = ref.read(readerNotifierProvider.notifier);
    notifier.updateCurrentBook(updated);
    await notifier.reloadChapterContent();
  } catch (e) {
    if (context.mounted) readerActionSnack(context, '设置保存失败: $e');
  }
}

/// 替换规则 scope 是否匹配当前书（批7c-1）
///
/// - scope 为 null/空/`global`（大小写不敏感）→ 全局生效；
/// - 否则按 `,`/`;`/`，`/`；` 拆分并 trim，任一项等于书名才生效；
/// - 书名为空时，非全局 scope 一律不生效（对齐「作用域书」语义）。
bool replaceRuleScopeMatchesBook(String? scope, String bookName) {
  final raw = scope?.trim() ?? '';
  if (raw.isEmpty || raw.toLowerCase() == 'global') return true;
  final name = bookName.trim();
  if (name.isEmpty) return false;
  for (final part in raw.split(RegExp(r'[,;，；]'))) {
    if (part.trim() == name) return true;
  }
  return false;
}

/// 替换净化是否生效（Dart 侧对齐 Rust `use_replace_rule_for_book`）
///
/// 三级优先级（与 `Book.getUseReplaceRule()`，Book.kt:232-242 一致）：
/// 1. `readConfig.useReplaceRule` 显式非空 → 取该值（false 也尊重）；
/// 2. 图片类书（`bookType & BookType.image`）或本地 epub
///    （`BookType.isLocalBook` + `originName` 小写 `.epub` 结尾）→ false；
/// 3. 其余回退全局 `replaceEnableDefault`。
///
/// 菜单勾选态与切换取反必须使用本函数，避免「显示 true 但 Rust 实际
/// 按图片/epub/全局默认关闭」的不一致。
bool effectiveReplaceRuleEnabled(Book? book, bool globalDefault) {
  if (book == null) return globalDefault;
  final explicit = book.readConfig?.useReplaceRule;
  if (explicit != null) return explicit;
  if ((book.bookType & BookType.image) != 0) return false;
  // 与 Rust/Kotlin 一致只看 originName：bookUrl 在本地书场景可能是无后缀
  // 的存储标识，在线书也可能是 .epub URL，不能作为 epub 判定依据。
  if (BookType.isLocalBook(book) &&
      book.originName.toLowerCase().endsWith('.epub')) {
    return false;
  }
  return globalDefault;
}

/// 读取全局默认值（provider 未就绪/读取失败回落 true，与 Rust 缺省一致）
Future<bool> _readGlobalReplaceDefault(WidgetRef ref) async {
  try {
    return await ref.read(replaceEnableDefaultProvider.future);
  } catch (_) {
    return true;
  }
}

/// 替换规则开关（对标原版 menu_enable_replace）
///
/// 取反基于 [effectiveReplaceRuleEnabled]（而非仅 readConfig 值）：图片书/
/// 本地 epub/全局默认关闭时，首次点击写入显式 true 即开启。
Future<void> toggleReaderReplaceRule(
  BuildContext context,
  WidgetRef ref,
) async {
  final book = ref.read(readerNotifierProvider).currentBook;
  // 显式书级值无需等待全局 provider（也避免无谓异步跳变）；仅在 null 时读取
  final explicit = book?.readConfig?.useReplaceRule;
  final bool enabled;
  if (explicit != null) {
    enabled = explicit;
  } else {
    final globalDefault = await _readGlobalReplaceDefault(ref);
    enabled = effectiveReplaceRuleEnabled(book, globalDefault);
    if (!context.mounted) return;
  }
  await updateReaderBookConfig(
    context,
    ref,
    (c) => c.copyWith(useReplaceRule: !enabled),
  );
  if (context.mounted) {
    readerActionSnack(context, enabled ? '已关闭替换规则' : '已开启替换规则');
  }
}

/// 拉取/同步云端进度（对齐 menu_get_progress → syncBookProgress）
Future<void> syncReaderProgress(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final reader = ref.read(readerNotifierProvider);
  final book = reader.currentBook;
  if (book == null) return;
  final syncNotifier = ref.read(syncNotifierProvider.notifier);
  await syncNotifier.loadConfig();
  final liveBook = book.copyWith(
    durChapterIndex: reader.currentChapterIndex,
    durChapterPos: reader.currentChapterPos,
    durChapterTitle: reader.currentChapter?.title,
    durChapterTime: DateTime.now().millisecondsSinceEpoch,
  );
  try {
    final result = await syncNotifier.syncBookProgressForBook(
      liveBook,
      onCloudNewer: (progress) async {
        if (!context.mounted) return;
        final go = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('同步阅读进度'),
            content: Text(
              '云端进度更新（第 ${progress.durChapterIndex + 1} 章'
              '${progress.durChapterTitle != null && progress.durChapterTitle!.isNotEmpty ? '「${progress.durChapterTitle}」' : ''}）。'
              '\n是否跳转到云端进度？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('跳转'),
              ),
            ],
          ),
        );
        if (go == true && context.mounted) {
          await ref
              .read(readerNotifierProvider.notifier)
              .applyBookProgress(
                chapterIndex: progress.durChapterIndex,
                chapterPos: progress.durChapterPos,
              );
        }
      },
    );
    if (!context.mounted) return;
    switch (result) {
      case 'uploaded':
        messenger.showSnackBar(const SnackBar(content: Text('本地进度较新，已上传到云端')));
      case 'same':
        messenger.showSnackBar(const SnackBar(content: Text('进度已与云端一致')));
      case 'skipped':
        messenger.showSnackBar(
          const SnackBar(content: Text('请先在 WebDAV 设置中开启「同步书籍进度」')),
        );
      case 'cloud':
        break; // 已弹确认框
    }
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(SnackBar(content: Text('同步进度失败：$e')));
  }
}
