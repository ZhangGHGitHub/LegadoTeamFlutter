import 'package:flutter/material.dart';

/// 确认对话框快捷方法
///
/// [LAYOUT_PLAN P4] 走主题默认 dialogTheme（28dp extraLarge），不逐个定制。
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmText = '确认',
  String cancelText = '取消',
  bool isDestructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(cancelText),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: isDestructive
              ? TextButton.styleFrom(
                  foregroundColor: Theme.of(ctx).colorScheme.error,
                )
              : null,
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return result ?? false;
}
