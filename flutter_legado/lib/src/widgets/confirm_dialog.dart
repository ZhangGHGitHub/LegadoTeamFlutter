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
      // [UI_SYNC_REFACTOR B7] 对话框按钮规范（对齐参考仓：右对齐 +
      // minWidth 88 + 间距 12 的宽扁形态）
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
      title: Text(title),
      content: Text(content),
      actions: [
        _DialogAction(
          label: cancelText,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        const SizedBox(width: 12),
        _DialogAction(
          label: confirmText,
          onPressed: () => Navigator.of(ctx).pop(true),
          isDestructive: isDestructive,
        ),
      ],
    ),
  );
  return result ?? false;
}

/// [UI_SYNC_REFACTOR B7] 对话框按钮（minWidth 88 宽扁形态）
class _DialogAction extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool isDestructive;

  const _DialogAction({
    required this.label,
    required this.onPressed,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 88),
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          foregroundColor: isDestructive ? cs.error : null,
        ),
        child: Text(label),
      ),
    );
  }
}
