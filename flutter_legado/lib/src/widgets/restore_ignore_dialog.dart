import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// 恢复忽略项多选 Dialog（对齐原版 BackupConfigFragment.backupIgnore）
///
/// 勾选项在备份/恢复时经 [RestoreIgnorePrefs] 过滤偏好；
/// 「本地书籍」在调用 restore 前预过滤备份 JSON 中的本地书。
class RestoreIgnoreDialog extends StatefulWidget {
  const RestoreIgnoreDialog({super.key, required this.initial});

  final Map<String, bool> initial;

  @override
  State<RestoreIgnoreDialog> createState() => _RestoreIgnoreDialogState();
}

class _RestoreIgnoreDialogState extends State<RestoreIgnoreDialog> {
  late final Map<String, bool> _checked;

  @override
  void initState() {
    super.initState();
    _checked = {
      for (final k in SettingsService.restoreIgnoreKeys)
        k: widget.initial[k] == true,
    };
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('恢复忽略'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '勾选后备份与恢复时跳过对应项（对齐原版）。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < SettingsService.restoreIgnoreKeys.length; i++)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _checked[SettingsService.restoreIgnoreKeys[i]] == true,
                  title: Text(SettingsService.restoreIgnoreTitles[i]),
                  onChanged: (v) {
                    setState(
                      () => _checked[SettingsService.restoreIgnoreKeys[i]] =
                          v == true,
                    );
                  },
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, Map<String, bool>.from(_checked)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
