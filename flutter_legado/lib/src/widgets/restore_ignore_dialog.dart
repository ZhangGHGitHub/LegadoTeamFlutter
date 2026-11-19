import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../services/settings_service.dart';

/// 忽略项多选 Dialog（恢复忽略默认；备份忽略复用同一 UI）
///
/// 恢复忽略勾选项经 [RestoreIgnorePrefs] 在恢复时过滤偏好；
/// 「本地书籍」在调用 restore 前预过滤备份 JSON 中的本地书。
/// 备份忽略仅在备份侧生效，两者配置相互独立。
class RestoreIgnoreDialog extends StatefulWidget {
  const RestoreIgnoreDialog({
    super.key,
    required this.initial,
    this.title,
    this.subtitle,
    this.keys = SettingsService.restoreIgnoreKeys,
    this.titles = SettingsService.restoreIgnoreTitles,
  });

  final Map<String, bool> initial;

  /// 对话框标题（备份忽略复用同一 UI；null = 取 [AppStrings.restoreIgnoreTitle]）
  final String? title;

  /// 说明文案（null = 取 [AppStrings.restoreIgnoreSubtitle]）
  final String? subtitle;

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
      title: Text(widget.title ?? AppStrings.restoreIgnoreTitle),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.subtitle ?? AppStrings.restoreIgnoreSubtitle,
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
          child: Text(AppStrings.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, Map<String, bool>.from(_checked)),
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}
