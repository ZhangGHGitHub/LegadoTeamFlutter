import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../providers.dart';
import 'remote_book_state.dart';

export 'remote_book_state.dart';

/// 远程书籍导入页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 书籍链接批量导入经 `BookApi.importBooks` 委托 Rust（Rust 侧按 URL
///   匹配书源并加入书架），UI 层仅负责链接解析与结果反馈。
/// - 对标安卓原版 RemoteBookActivity（REFACTORING_REMAINING_PLAN §4.3 P2-2④）。
class RemoteBookNotifier extends Notifier<RemoteBookState> {
  @override
  RemoteBookState build() => const RemoteBookState();

  /// 解析多行文本中的书籍链接
  ///
  /// 每行一个链接：去空白、去空行、去重，仅保留 http/https 链接。
  static List<String> parseUrls(String text) {
    final seen = <String>{};
    final urls = <String>[];
    for (final line in text.split('\n')) {
      final url = line.trim();
      if (url.isEmpty) continue;
      if (!url.startsWith('http://') && !url.startsWith('https://')) continue;
      if (seen.add(url)) {
        urls.add(url);
      }
    }
    return urls;
  }

  /// 由书籍链接提取显示名（URL 路径末段，兜底主机名/原串）
  static String nameFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    try {
      final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isNotEmpty) {
        // 去掉常见扩展名，保留可读名
        final last = segments.last.replaceAll(RegExp(r'\.\w+$'), '');
        if (last.isNotEmpty) {
          // 百分号解码容错：非法编码时回退原段
          try {
            return Uri.decodeComponent(last);
          } catch (_) {
            return last;
          }
        }
      }
      return uri.host.isNotEmpty ? uri.host : url;
    } catch (_) {
      // pathSegments 对截断的百分号编码会抛 FormatException，兜底原串
      return url;
    }
  }

  /// 批量导入书籍链接（成功后返回导入数量）
  Future<void> importUrls(String text) async {
    final urls = parseUrls(text);
    if (urls.isEmpty) {
      state = state.copyWith(
        importedCount: null,
        error: '未找到有效的书籍链接（每行一个 http/https 链接）',
      );
      return;
    }
    state = state.copyWith(isImporting: true, error: null);
    try {
      final booksJson = [
        for (final url in urls)
          {
            'bookUrl': url,
            'name': nameFromUrl(url),
            'origin': 'web',
          },
      ];
      final count =
          await ref.read(bookApiProvider).importBooks(jsonEncode(booksJson));
      state = state.copyWith(importedCount: count, isImporting: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isImporting: false);
    }
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 远程书籍导入 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(remoteBookNotifierProvider);
/// ref.read(remoteBookNotifierProvider.notifier).importUrls(text);
/// ```
final remoteBookNotifierProvider =
    NotifierProvider<RemoteBookNotifier, RemoteBookState>(
  RemoteBookNotifier.new,
);
