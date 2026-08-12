import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// 恢复忽略项多选 Dialog（对齐原版 BackupConfigFragment.backupIgnore）
///
/// 当前备份 JSON 仅含业务表数据；恢复时**仅「本地书籍」生效**（预过滤）。
/// 其余键持久化对齐原版，待备份含 prefs/主题/阅读配置后接线。
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
                '勾选后恢复时跳过对应项。当前备份格式下仅「本地书籍」会生效；其余项已保存，待备份含主题/阅读配置后生效。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < SettingsService.restoreIgnoreKeys.length; i++)
                Builder(
                  builder: (ctx) {
                    final key = SettingsService.restoreIgnoreKeys[i];
                    final title = SettingsService.restoreIgnoreTitles[i];
                    final effective = key == 'localBook';
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      value: _checked[key] == true,
                      title: Text(title),
                      subtitle: effective ? null : const Text('待备份格式扩展'),
                      onChanged: (v) {
                        setState(() => _checked[key] = v == true);
                      },
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
          onPressed: () => Navigator.pop(context, Map<String, bool>.from(_checked)),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
