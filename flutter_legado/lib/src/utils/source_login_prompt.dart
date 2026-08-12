import 'package:flutter/material.dart';

import '../bridge/ffi.dart' show BridgeError;
import '../models/book_source.dart';
import '../screens/source_login_screen.dart';

/// 是否为 loginCheckJs 判定的「书源需要登录」错误（错误码 1012 / 文案对齐）。
bool isSourceLoginRequiredError(Object? error) {
  if (error == null) return false;
  final msg = error is BridgeError ? error.message : error.toString();
  return msg.contains('书源需要登录') ||
      msg.contains('LoginRequired') ||
      msg.contains('login_required') ||
      msg.contains('1012');
}

String sourceLoginRequiredMessage(Object? error) {
  if (error is BridgeError && error.message.isNotEmpty) {
    return error.message;
  }
  final s = error?.toString() ?? '';
  if (s.contains('书源需要登录')) return s;
  return '书源需要登录，请先在书源菜单中登录后重试';
}

/// 弹出登录提示并可选跳转 [SourceLoginScreen]（对齐原版 LoginSourceException 引导）。
Future<void> promptSourceLoginIfNeeded(
  BuildContext context, {
  required Object? error,
  required BookSource? source,
}) async {
  if (!isSourceLoginRequiredError(error) || source == null) return;
  if (!context.mounted) return;

  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要登录'),
      content: Text(sourceLoginRequiredMessage(error)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('去登录'),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SourceLoginScreen(
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        loginUrl: source.loginUrl,
      ),
    ),
  );
}
