import 'package:flutter/material.dart';

import '../services/settings_service.dart';

/// 恢复忽略项多选 Dialog（对齐原版 BackupConfigFragment.backupIgnore）
///
/// 勾选项在备份/恢复时经 [RestoreIgnorePrefs] 过滤偏好；
/// 「本地书籍」在调用 restore 前预过滤备份 JSON 中的本地书。
class RestoreIgnoreDialog extends StatefulWidget {
  const RestoreIgnoreDialog({
    super.key,
    required this.initial,
    this.title = '恢复忽略',
    this.subtitle = '勾选后备份与恢复时跳过对应项（对齐原版）。',
    this.keys = SettingsService.restoreIgnoreKeys,
    this.titles = SettingsService.restoreIgnoreTitles,
  });

  final Map<String, bool> initial;

  /// 对话框标题（备份忽略复用同一 UI）
  final String title;

  /// 说明文案
  final String subtitle;

  /// 可勾选项键（默认恢复忽略 8 项）
  final List<String> keys;

  /// 对应标题（缺省用键名）
  final List<String>? titles;

  @override
  State<RestoreIgnoreDialog> createState() => _RestoreIgnoreDialogState();
}

class _RestoreIgnoreDialogState extends State<RestoreIgnoreDialog> {
  late final Map<String, bool> _checked;

  @override
  void initState() {
    super.initState();
    _checked = {for (final k in widget.keys) k: widget.initial[k] == true};
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < widget.keys.length; i++)
                CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: _checked[widget.keys[i]] == true,
                  title: Text(
                    widget.titles != null && i < widget.titles!.length
                        ? widget.titles![i]
                        : widget.keys[i],
                  ),
                  onChanged: (v) {
                    setState(() => _checked[widget.keys[i]] = v == true);
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
