import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';

/// 自定义源分组对话框（对标原版 dialog_custom_group.xml：
/// 添加分组开关 + 分组名称输入）
///
/// 书源/订阅源/替换规则导入确认页共用；
/// controller 生命周期绑定对话框子树，随子树卸载统一释放
/// （避免退场动画期间 dispose 引发框架断言）；
/// 确定返回（分组名, 是否添加分组），取消返回 null
class CustomGroupDialog extends StatefulWidget {
  final String initialName;
  final bool initialAddGroup;

  const CustomGroupDialog({
    super.key,
    required this.initialName,
    required this.initialAddGroup,
  });

  @override
  State<CustomGroupDialog> createState() => _CustomGroupDialogState();
}

class _CustomGroupDialogState extends State<CustomGroupDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);
  late bool _addGroup = widget.initialAddGroup;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(AppStrings.customGroupNameTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(AppStrings.addGroup),
            subtitle: Text(AppStrings.customGroupNameDesc),
            value: _addGroup,
            onChanged: (v) => setState(() => _addGroup = v),
          ),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: AppStrings.groupNameLabel,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(AppStrings.cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            (_controller.text.trim(), _addGroup),
          ),
          child: Text(AppStrings.confirm),
        ),
      ],
    );
  }
}
