// [设置批2b-1a | 2026-11-01] 设置页行内滑块行（自 read_config_screen 提取）
//
// 参考版 `SliderSettingItem`（标题 + 行内 Slider + 当前值）。外观设置页的
// 容器不透明度/背景图虚化与阅读设置页共用同一形态。提取自
// `screens/read_config_screen.dart`（批1a），行为零变更；read_config_screen
// 仍 re-export 本文件，既有调用方/测试的 import 不受影响 — 全栈工程师
import 'package:flutter/material.dart';

import 'setting_cards.dart' show LabelMediumEmphasized;

/// 行内滑块行：标题 + 当前值 + Slider（参考版 SliderSettingItem 形态）
///
/// [批1a 审查回修 | 2026-10-31] 提交时机对齐既有字号滑块口径（批33b）：
/// 拖动中（onChanged）仅本地预览数值，松手（onChangeEnd）才提交一次——
/// 避免逐帧触发约 90 键全量写盘 + provider 推送 — 全栈工程师
class SettingSliderRow extends StatefulWidget {
  final String title;
  final int value;
  final int min;
  final int max;

  /// 可选说明文字（标题下方小字；[批1b-3 审查回修 P2-3] 用于生效范围提示）
  final String? subtitle;

  /// 当前值后缀（如 'dp'/'%'；默认空串保持既有行形态）
  final String valueSuffix;

  /// 松手提交（一次）
  final ValueChanged<int> onChanged;

  const SettingSliderRow({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    this.subtitle,
    this.valueSuffix = '',
    required this.onChanged,
  });

  @override
  State<SettingSliderRow> createState() => _SettingSliderRowState();
}

class _SettingSliderRowState extends State<SettingSliderRow> {
  /// 拖动中的本地预览值（null = 未在拖动，显示外部值）
  int? _preview;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shown = _preview ?? widget.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(widget.title,
                  style: Theme.of(context).textTheme.titleMedium),
              Text(
                '$shown${widget.valueSuffix}',
                style: Theme.of(context).textTheme.labelMediumEmphasized
                    ?.copyWith(color: cs.primary),
              ),
            ],
          ),
          if (widget.subtitle != null)
            Text(
              widget.subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          Slider(
            value: shown.toDouble().clamp(widget.min.toDouble(),
                widget.max.toDouble()),
            min: widget.min.toDouble(),
            max: widget.max.toDouble(),
            divisions: widget.max - widget.min,
            label: '$shown',
            onChanged: (v) => setState(() => _preview = v.round()),
            onChangeEnd: (v) {
              final target = v.round().clamp(widget.min, widget.max);
              setState(() => _preview = null);
              widget.onChanged(target);
            },
          ),
        ],
      ),
    );
  }
}
