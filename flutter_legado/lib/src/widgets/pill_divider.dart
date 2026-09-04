import 'package:flutter/material.dart';

/// M3 胶囊分隔线（对齐 HapeLee PillDivider）
///
/// 规格：厚度 2dp、宽度 20%、颜色 outlineVariant 60%、两端圆角、上下间距各 4dp。
/// 用于分组卡内行间分隔（SettingItemDivider 开关打开时）。
class PillDivider extends StatelessWidget {
  /// 分隔线长度占可用宽度的比例（HapeLee itemDividerLength 默认 80%；
  /// PillDivider 默认 20%，见 SettingItemDivider 的 length 参数）。
  final double widthFraction;

  /// 是否启用（HapeLee enableItemDivider，默认 false 关）。
  final bool enabled;

  const PillDivider({
    super.key,
    this.widthFraction = 0.2,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: FractionallySizedBox(
          widthFactor: widthFraction,
          child: Container(
            height: 2,
            decoration: BoxDecoration(
              color: colorScheme.outlineVariant.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ),
      ),
    );
  }
}

/// 设置行分隔线（对齐 HapeLee SettingItemDivider）
///
/// 默认关闭（enableItemDivider=false），打开时为 80% 长 pill 线。
/// 存量 IosGroup 内 0.5dp 全宽线保持不动，逐屏迁移时替换。
class SettingItemDivider extends StatelessWidget {
  /// 是否启用（默认 false，与 HapeLee 一致）。
  final bool enabled;

  const SettingItemDivider({super.key, this.enabled = false});

  @override
  Widget build(BuildContext context) {
    return PillDivider(widthFraction: 0.8, enabled: enabled);
  }
}
