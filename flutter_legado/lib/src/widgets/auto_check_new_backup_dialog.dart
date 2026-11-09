// 批10：启动自动检查新备份的确认对话框
//
// 对齐参考版 MainActivity.alert(R.string.restore,
// R.string.webdav_after_local_restore_confirm)：
// - 标题「恢复」；
// - 正文「WebDAV 备份比本地新，是否恢复？」+ 远端备份文件名；
// - 按钮「取消 / 确定」；取消不恢复（去重键已在弹窗前写入，等同永久忽略
//   该备份），确定进入恢复链。
//
// 布局：文件名单独一行、最多两行省略，360dp + 大字模式下正文可换行，
// 按钮由 AlertDialog 的 OverflowBar 自动堆叠，避免横向溢出。
import 'package:flutter/material.dart';

/// 显示「恢复」确认框；关闭/取消返回 false
Future<bool> showAutoCheckNewBackupDialog(
  BuildContext context, {
  required String fileName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AutoCheckNewBackupDialog(fileName: fileName),
  );
  return result ?? false;
}

/// 新备份恢复确认框
class AutoCheckNewBackupDialog extends StatelessWidget {
  const AutoCheckNewBackupDialog({super.key, required this.fileName});

  /// 远端备份文件名（只展示，不参与逻辑）
  final String fileName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('autoCheckNewBackupDialog'),
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(12, 0, 16, 12),
      title: const Text('恢复'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('WebDAV 备份比本地新，是否恢复？'),
          const SizedBox(height: 8),
          Text(
            fileName,
            key: const ValueKey('autoCheckNewBackupFileName'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('autoCheckNewBackupCancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        const SizedBox(width: 12),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 88),
          child: TextButton(
            key: const ValueKey('autoCheckNewBackupConfirm'),
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确定'),
          ),
        ),
      ],
    );
  }
}
