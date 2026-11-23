import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/backup_content_service.dart';

/// 「备份内容」多选 Dialog（C1 逐表备份忽略）
///
/// 对齐参考版 `BackupConfigScreen` 的「数据库忽略」页签（`Backup.kt:156-222`
/// 的 `dbIsNotIgnored(key, true)` 门控）：勾选后该表不写入备份文件。
/// 与「备份忽略列表」（偏好级）相互独立，二者共同决定备份内容。
class BackupContentDialog extends StatefulWidget {
  const BackupContentDialog({
    super.key,
    required this.initial,
    this.title,
    this.subtitle,
  });

  /// 已忽略的表键集合
  final Set<String> initial;

  /// 对话框标题（null = 取 [AppStrings.backupContentTitle]）
  final String? title;

  /// 说明文案（null = 取 [AppStrings.backupContentSubtitle]）
  final String? subtitle;

  @override
  State<BackupContentDialog> createState() => _BackupContentDialogState();
}

class _BackupContentDialogState extends State<BackupContentDialog> {
  late final Set<String> _ignored;

  @override
  void initState() {
    super.initState();
    _ignored = {...widget.initial};
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? AppStrings.backupContentTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.subtitle ?? AppStrings.backupContentSubtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in BackupContentService.entries)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _ignored.contains(entry.key),
                  title: Text(entry.title),
                  onChanged: (checked) {
                    setState(() {
                      if (checked == true) {
                        _ignored.add(entry.key);
                      } else {
                        _ignored.remove(entry.key);
                      }
                    });
                  },
                ),
              const Divider(height: 16),
              // 角色卡（R42 阶段 2A）：产品决策上**永不备份**，故不提供勾选项
              // （勾选项语义是「可选关闭」，与此不同）。此行只做告知——否则
              // 换机 / 恢复备份后角色全丢，用户会误以为是 Bug。
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      AppStrings.backupContentCharactersExcluded,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, <String>{..._ignored}),
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}
