import 'package:flutter/material.dart';

/// M3 胶囊分隔线（对齐 HapeLee PillDivider）
///
/// 规格：厚度 2dp、宽度 20%、颜色 outlineVariant 60%、两端圆角、上下间距各 4dp。
/// 用于分组卡内行间分隔（SettingItemDivider 开关打开时）。
///
/// [设置批2b-1b-1] 增加 [thickness]/[color]/[padding] 参数：设置行分隔线
/// 改用参考版 `SettingItemDivider` 的宽度/长度百分比/颜色三参数，分组间距
/// 由 IosGroup 自己提供，因此传入零 padding；弹窗菜单用法保持默认值不变。
class PillDivider extends StatelessWidget {
  /// 分隔线长度占可用宽度的比例（HapeLee itemDividerLength 默认 80%；
  /// PillDivider 默认 20%，见 SettingItemDivider 的 length 参数）。
  final double widthFraction;

  /// 是否启用（HapeLee enableItemDivider，默认 false 关）。
  final bool enabled;

  /// 线高 dp（参考版 itemDividerWidth，默认 2dp 保持原弹窗形态）
  final double thickness;

  /// 线色；null = outlineVariant 60%（保持原弹窗形态）
  final Color? color;

  /// 线上下内边距（设置行分隔线传 EdgeInsets.zero）
  final EdgeInsetsGeometry padding;

  const PillDivider({
    super.key,
    this.widthFraction = 0.2,
    this.enabled = true,
    this.thickness = 2,
    this.color,
    this.padding = const EdgeInsets.symmetric(vertical: 4),
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Center(
        child: FractionallySizedBox(
          widthFactor: widthFraction,
          child: Container(
            height: thickness,
            decoration: BoxDecoration(
              color: color ??
                  colorScheme.outlineVariant.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(thickness / 2),
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

/// 弹窗菜单项间分隔（PopupMenuEntry 形态）。
///
/// 对标参考版 `PillDivider()` 在 RoundDropdownMenuItem 之间的用法
/// （PillDivider.kt 被 13 文件引用，均为弹窗菜单项分隔），亦为我方
/// `PopupMenuDivider` 的形态替代：高度沿用 PopupMenuDivider 的 16dp，
/// 内容为 20% 宽胶囊线（PillDivider 默认参数）。
/// 泛型与宿主 `PopupMenuButton<T>` 的 T 一致（由上下文推断）。
class PillMenuDivider<T> extends PopupMenuEntry<T> {
  const PillMenuDivider({super.key});

  @override
  double get height => 16;

  @override
  bool represents(T? value) => false;

  @override
  State<PillMenuDivider<T>> createState() => _PillMenuDividerState<T>();
}

class _PillMenuDividerState<T> extends State<PillMenuDivider<T>> {
  @override
  Widget build(BuildContext context) => const PillDivider();
}
