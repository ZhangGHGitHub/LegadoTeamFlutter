import 'package:flutter/material.dart';

import '../bridge/ffi.dart' show BridgeError;
import '../l10n/app_strings.dart';
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
  return AppStrings.sourceLoginRequiredHint;
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
      title: Text(AppStrings.loginRequiredTitle),
      content: Text(sourceLoginRequiredMessage(error)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(AppStrings.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(AppStrings.goLogin),
        ),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  // [2b-2c 复核 P1] 登录属 standalone：提示可能来自列表-详情右栏内的
  // BookInfo，登录页固定 root 全屏。
  await Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(
      builder: (_) => SourceLoginScreen(
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        loginUrl: source.loginUrl,
      ),
    ),
  );
}
