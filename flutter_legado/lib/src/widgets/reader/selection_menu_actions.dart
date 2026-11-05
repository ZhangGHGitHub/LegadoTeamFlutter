// 选择菜单动作执行器（批4c）
//
// 浮条与底部选择面板共用；行为沿用既有 TextSelectionPanel 实现
//（复制/分享/浏览器/朗读/书签/替换/字典/全文搜索/编辑内容）。
//
// 编写：全栈工程师（批4c） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/audio/audio_notifier.dart';
import '../../providers/bookmark/bookmark_notifier.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../dict_dialog.dart';
import 'reader_action_helpers.dart';

void selectionToast(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

Future<void> selectionCopy(
  BuildContext context,
  String text,
  VoidCallback onDone,
) async {
  await Clipboard.setData(ClipboardData(text: text));
  onDone();
  if (context.mounted) selectionToast(context, '已复制到剪贴板');
}

Future<void> selectionShare(
  BuildContext context,
  String text,
  VoidCallback onDone,
) async {
  onDone();
  try {
    await Share.share(text);
  } catch (e) {
    if (context.mounted) selectionToast(context, '分享失败：$e');
  }
}

Future<void> selectionOpenBrowser(
  BuildContext context,
  String text,
  VoidCallback onDone,
) async {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  onDone();
  if (RegExp(r'^https?://\S+$').hasMatch(trimmed)) {
    navigator.pushNamed(AppRoutes.browser, arguments: trimmed);
    return;
  }
  final uri = Uri.https('www.bing.com', '/search', {'q': trimmed});
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (context.mounted) selectionToast(context, '无法打开浏览器');
    }
  } catch (e) {
    if (context.mounted) selectionToast(context, '打开浏览器失败：$e');
  }
}

Future<void> selectionReadAloud(
  WidgetRef ref,
  BuildContext context, {
  required String selectedText,
  required String paragraphText,
  required int chapterPos,
  required VoidCallback onDone,
}) async {
  final state = ref.read(readerNotifierProvider);
  final book = state.currentBook;
  if (book == null) {
    selectionToast(context, '无法启动朗读：未打开书籍');
    return;
  }
  onDone();
  await ref
      .read(audioNotifierProvider.notifier)
      .startReadAloud(
        bookUrl: book.bookUrl,
        bookName: book.name,
        chapterIndex: state.currentChapterIndex,
        startChapterPos: chapterPos,
        startParagraphText: paragraphText,
        // [设置批5a-1] 选区朗读同属阅读器发起：退出阅读器按偏好停止
        fromReader: true,
      );
}

Future<void> selectionAddBookmark(
  WidgetRef ref,
  BuildContext context, {
  required String selectedText,
  required int chapterPos,
  required VoidCallback onDone,
}) async {
  final state = ref.read(readerNotifierProvider);
  final book = state.currentBook;
  if (book == null) {
    selectionToast(context, '无法添加书签：未打开书籍');
    return;
  }
  // [审查 P3] 与浮条其他动作一致，先收起菜单再落库，避免等待期间
  // 浮条/面板残留；先捕获 ScaffoldMessenger，收起后仍能提示成功/失败。
  final messenger = ScaffoldMessenger.maybeOf(context);
  onDone();
  try {
    await ref
        .read(bookmarkNotifierProvider.notifier)
        .addBookmark(
          bookName: book.name,
          bookAuthor: book.author,
          chapterIndex: state.currentChapterIndex,
          chapterPos: chapterPos,
          chapterName: state.currentChapter?.title ?? '',
          bookText: selectedText,
          content: selectedText,
        );
    messenger?.showSnackBar(
      const SnackBar(content: Text('已添加书签'), duration: Duration(seconds: 2)),
    );
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text('添加书签失败：$e'),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

void selectionReplace(BuildContext context, String text, VoidCallback onDone) {
  onDone();
  Navigator.of(
    context,
    rootNavigator: true,
  ).pushNamed(AppRoutes.replaceRules, arguments: text);
}

void selectionLookupDict(
  BuildContext context,
  String text,
  VoidCallback onDone,
) {
  final word = text.trim();
  if (word.isEmpty) return;
  final navigator = Navigator.of(context, rootNavigator: true);
  final ctx = navigator.context;
  onDone();
  unawaited(showDictDialog(ctx, word: word));
}

void selectionSearchContent(
  WidgetRef ref,
  BuildContext context,
  String text,
  VoidCallback onDone,
) {
  final book = ref.read(readerNotifierProvider).currentBook;
  if (book == null) {
    selectionToast(context, '无法搜正文：未打开书籍');
    return;
  }
  final navigator = Navigator.of(context, rootNavigator: true);
  onDone();
  navigator.pushNamed(
    AppRoutes.searchContent,
    arguments: {'book': book, 'query': text},
  );
}

void selectionEdit(WidgetRef ref, BuildContext context, VoidCallback onDone) {
  onDone();
  unawaited(showReaderEditContentDialog(context, ref));
}
