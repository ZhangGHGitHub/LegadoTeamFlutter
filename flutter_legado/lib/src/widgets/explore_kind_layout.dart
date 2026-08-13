/// 发现分类 Flexbox 布局（对标 Android ExploreAdapter + FlexboxLayout）
///
/// 分类 Chip 对齐原版 item_fillet_text + bg_fillet_btn：浅灰圆角、按 flexBasisPercent 网格换行。
library;

import 'package:flutter/material.dart';

import '../models/models.dart';

/// 按 [FlexChildStyle.layoutFlexBasisPercent] 将分类项排布为全宽行 / 网格 Chip。
///
/// - `layoutFlexBasisPercent >= 1`：独占一行（分组标题或可点击全宽 Chip）
/// - `0 < layoutFlexBasisPercent < 1`：按百分比宽度并排（如 0.25 → 4 列，0.33 → 3 列）
/// - 默认（-1）：自适应宽 Chip，连续默认项自动换行
class ExploreKindLayout extends StatelessWidget {
  const ExploreKindLayout({
    super.key,
    required this.categories,
    this.onCategoryTap,
  });

  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onCategoryTap;

  /// 对标 Android item_fillet_text 圆角（16dp）
  static const _kChipRadius = 16.0;
  static const _kChipGap = 6.0;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final children = <Widget>[];

        for (final category in categories) {
          final style = category.effectiveStyle;
          if (style.layoutWrapBefore && children.isNotEmpty) {
            // 对标 Flexbox layout_wrapBefore：强制换行
            children.add(SizedBox(width: maxWidth, height: 0));
          }
          children.add(
            _KindChip(
              category: category,
              width: _chipWidth(maxWidth, style),
              onTap: onCategoryTap,
            ),
          );
        }

        return Wrap(
          spacing: _kChipGap,
          runSpacing: _kChipGap,
          children: children,
        );
      },
    );
  }

  /// 计算 Chip 宽度（对标 FlexboxLayout.LayoutParams.flexBasisPercent）
  static double? _chipWidth(double maxWidth, FlexChildStyle style) {
    final basis = style.layoutFlexBasisPercent;
    if (basis >= 1.0) return maxWidth;
    if (basis <= 0) return null;

    final columns = (1.0 / basis).round().clamp(1, 12);
    return (maxWidth - _kChipGap * (columns - 1)) / columns;
  }
}

// ─── 单个 Chip（对标 bg_fillet_btn / item_fillet_text）────────────────────

class _KindChip extends StatefulWidget {
  const _KindChip({
    required this.category,
    this.width,
    this.onTap,
  });

  final ExploreCategory category;
  final double? width;
  final void Function(String title, String url)? onTap;

  @override
  State<_KindChip> createState() => _KindChipState();
}

class _KindChipState extends State<_KindChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasUrl = widget.category.hasUrl;
    final justify = widget.category.effectiveStyle.layoutJustifySelf;

    // 对标 Android btn_bg_press / btn_bg_press_2
    final fill = _pressed && hasUrl
        ? colorScheme.onSurface.withValues(alpha: 0.16)
        : colorScheme.onSurface.withValues(alpha: 0.10);

    final textAlign = _textAlignFor(justify);
    final alignment = switch (justify) {
      'flex_start' || 'start' => Alignment.centerLeft,
      'flex_end' || 'end' => Alignment.centerRight,
      'center' => Alignment.center,
      _ => Alignment.center,
    };

    final label = Container(
      width: widget.width,
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
      ),
      alignment: alignment,
      child: Text(
        widget.category.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
          fontSize: 14,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: textAlign,
      ),
    );

    if (!hasUrl) return label;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () =>
            widget.onTap?.call(widget.category.title, widget.category.url!),
        onHighlightChanged: (v) => setState(() => _pressed = v),
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
        splashColor: colorScheme.primary.withValues(alpha: 0.08),
        highlightColor: Colors.transparent,
        child: label,
      ),
    );
  }
}

TextAlign _textAlignFor(String justify) {
  return switch (justify) {
    'flex_start' || 'start' => TextAlign.start,
    'flex_end' || 'end' => TextAlign.end,
    'center' => TextAlign.center,
    _ => TextAlign.center,
  };
}

/// [ExploreCategory] 布局辅助
extension ExploreCategoryLayout on ExploreCategory {
  FlexChildStyle get effectiveStyle =>
      style ?? const FlexChildStyle();

  bool get hasUrl => url != null && url!.trim().isNotEmpty;
}
