// 通用容器/背景颜色选择对话框（批3a 抽取）
//
// 原实现位于 `screens/theme_config_screen.dart` 的私有
// `_ContainerColorDialog`（卡片边框/分隔线/项目图等共用）。批3a 的菜单
// 配色（背景/强调/容器/文字 × 日/夜）需要同一交互，故抽为公共 Widget，
// 行为保持不变：
// - 预设色板 + `#RRGGBB`/`#AARRGGBB` HEX 输入（# 可省略）；
// - 非法输入禁用「确定」并内联提示；
// - 「恢复默认」返回 0（语义=跟随主题/默认色），取消返回 null。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/color_hex.dart';

/// 预设色板（对齐原版 ColorPreference cpv_dialogType="preset"）
const List<int> kContainerColorPresets = [
  0xFFD32F2F,
  0xFFF44336,
  0xFFE91E63,
  0xFF9C27B0,
  0xFF673AB7,
  0xFF3F51B5,
  0xFF2196F3,
  0xFF03A9F4,
  0xFF00BCD4,
  0xFF009688,
  0xFF4CAF50,
  0xFF8BC34A,
  0xFFCDDC39,
  0xFFFFEB3B,
  0xFFFFC107,
  0xFFFF9800,
  0xFFFF5722,
  0xFF795548,
  0xFF9E9E9E,
  0xFF607D8B,
  0xFF000000,
  0xFF212121,
  0xFF424242,
  0xFFFAFAFA,
  0xFFFFFFFF,
];

/// 容器/背景颜色选择对话框
///
/// 返回 ARGB int；`0` = 恢复默认；`null` = 取消。
class ContainerColorDialog extends StatefulWidget {
  final String title;
  final int initialColor;
  final String defaultHint;
  final List<int> presetColors;

  const ContainerColorDialog({
    super.key,
    required this.title,
    required this.initialColor,
    required this.defaultHint,
    this.presetColors = kContainerColorPresets,
  });

  @override
  State<ContainerColorDialog> createState() => _ContainerColorDialogState();
}

class _ContainerColorDialogState extends State<ContainerColorDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: widget.initialColor == 0 ? '' : argbToHex(widget.initialColor),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int? get _parsed => parseArgbHexColor(_controller.text);

  void _submit() {
    final parsed = _parsed;
    if (parsed == null) return;
    Navigator.pop(context, parsed);
  }

  @override
  Widget build(BuildContext context) {
    final trimmed = _controller.text.trim();
    final invalid = trimmed.isNotEmpty && _parsed == null;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[#0-9a-fA-F]')),
              LengthLimitingTextInputFormatter(9),
            ],
            decoration: InputDecoration(
              labelText: 'HEX',
              hintText: '#AARRGGBB 或 #RRGGBB',
              errorText: invalid ? '请输入 6/8 位十六进制颜色' : null,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final c in widget.presetColors)
                InkWell(
                  onTap: () => Navigator.pop(context, c),
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 0),
          child: Text(widget.defaultHint),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _parsed == null ? null : _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
