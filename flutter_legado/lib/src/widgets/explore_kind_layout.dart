/// 发现分类 Flexbox 布局（对标 Android ExploreAdapter + FlexboxLayout）
library;

import 'package:flutter/material.dart';

import '../models/models.dart';

/// 按 [FlexChildStyle.layoutFlexBasisPercent] 将分类项排布为全宽行 / 网格 Chip。
///
/// - `layoutFlexBasisPercent >= 1`：独占一行（分组标题或可点击全宽项）
/// - `0 < layoutFlexBasisPercent < 1`：按百分比宽度并排（如 0.25 → 一行 4 个）
/// - 默认（-1）：自适应宽 Chip，连续默认项用 [Wrap] 包裹
class ExploreKindLayout extends StatelessWidget {
  const ExploreKindLayout({
    super.key,
    required this.categories,
    this.onCategoryTap,
  });

  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onCategoryTap;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();

    final segments = _segmentCategories(categories);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final segment in segments) ...[
          if (segment is _WideSegment)
            _WideKindTile(
              category: segment.category,
              onTap: onCategoryTap,
            )
          else if (segment is _CellRowSegment)
            _CellKindRow(
              categories: segment.categories,
              onTap: onCategoryTap,
            )
          else if (segment is _WrapSegment)
            _WrapKindRow(
              categories: segment.categories,
              onTap: onCategoryTap,
            ),
        ],
      ],
    );
  }
}

// ─── 分段逻辑（对标 Flexbox wrap / flexBasisPercent）────────────────────────

sealed class _KindSegment {}

class _WideSegment extends _KindSegment {
  _WideSegment(this.category);
  final ExploreCategory category;
}

class _CellRowSegment extends _KindSegment {
  _CellRowSegment(this.categories);
  final List<ExploreCategory> categories;
}

class _WrapSegment extends _KindSegment {
  _WrapSegment(this.categories);
  final List<ExploreCategory> categories;
}

List<_KindSegment> _segmentCategories(List<ExploreCategory> categories) {
  final segments = <_KindSegment>[];
  var cellRow = <ExploreCategory>[];
  var wrapGroup = <ExploreCategory>[];
  var rowBasis = 0.0;

  void flushCellRow() {
    if (cellRow.isEmpty) return;
    segments.add(_CellRowSegment(List.unmodifiable(cellRow)));
    cellRow = [];
    rowBasis = 0.0;
  }

  void flushWrapGroup() {
    if (wrapGroup.isEmpty) return;
    segments.add(_WrapSegment(List.unmodifiable(wrapGroup)));
    wrapGroup = [];
  }

  for (final category in categories) {
    final style = category.effectiveStyle;
    if (style.layoutWrapBefore) {
      flushCellRow();
      flushWrapGroup();
    }

    final basis = style.layoutFlexBasisPercent;
    if (basis >= 1.0) {
      flushCellRow();
      flushWrapGroup();
      segments.add(_WideSegment(category));
    } else if (basis > 0 && basis < 1.0) {
      flushWrapGroup();
      cellRow.add(category);
      rowBasis += basis;
      if (rowBasis >= 0.99) flushCellRow();
    } else {
      flushCellRow();
      wrapGroup.add(category);
    }
  }

  flushCellRow();
  flushWrapGroup();
  return segments;
}

// ─── 全宽行（wide / 分组标题）──────────────────────────────────────────────

class _WideKindTile extends StatelessWidget {
  const _WideKindTile({
    required this.category,
    this.onTap,
  });

  final ExploreCategory category;
  final void Function(String title, String url)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasUrl = category.hasUrl;
    final justify = category.effectiveStyle.layoutJustifySelf;

    final alignment = switch (justify) {
      'flex_start' || 'start' => Alignment.centerLeft,
      'flex_end' || 'end' => Alignment.centerRight,
      'center' => Alignment.center,
      _ => Alignment.center,
    };

    final child = Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      alignment: alignment,
      child: Text(
        category.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: hasUrl
              ? colorScheme.onSurface
              : colorScheme.onSurfaceVariant,
          fontWeight: hasUrl ? FontWeight.w500 : FontWeight.w600,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: _textAlignFor(justify),
      ),
    );

    if (!hasUrl) return child;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onTap?.call(category.title, category.url!),
        borderRadius: BorderRadius.circular(16),
        child: child,
      ),
    );
  }
}

// ─── 网格 Chip 行（cell，如 0.25 → 4 列）──────────────────────────────────

class _CellKindRow extends StatelessWidget {
  const _CellKindRow({
    required this.categories,
    this.onTap,
  });

  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              flex: _flexWeight(categories[i]),
              child: _KindChip(
                category: categories[i],
                onTap: onTap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _flexWeight(ExploreCategory category) {
    final basis = category.effectiveStyle.layoutFlexBasisPercent;
    if (basis <= 0) return 1;
    return (basis * 100).round().clamp(1, 100);
  }
}

// ─── 默认 Wrap Chip ─────────────────────────────────────────────────────────

class _WrapKindRow extends StatelessWidget {
  const _WrapKindRow({
    required this.categories,
    this.onTap,
  });

  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final category in categories)
            _KindChip(category: category, onTap: onTap),
        ],
      ),
    );
  }
}

// ─── 单个 Chip（对标 item_fillet_text.xml）──────────────────────────────────

class _KindChip extends StatelessWidget {
  const _KindChip({
    required this.category,
    this.onTap,
  });

  final ExploreCategory category;
  final void Function(String title, String url)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasUrl = category.hasUrl;

    final label = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        category.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );

    if (!hasUrl) return label;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onTap?.call(category.title, category.url!),
        borderRadius: BorderRadius.circular(16),
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
