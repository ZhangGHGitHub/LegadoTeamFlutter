/// 发现分类 Flexbox 布局（对标 Android ExploreAdapter + FlexboxLayout）
///
/// 视觉：iOS inset grouped list — wide 行对标 Settings 列表项，Chip 为系统灰底克制圆角。
library;

import 'package:flutter/material.dart';

import '../models/models.dart';
import 'ios_widgets.dart';

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

  static const _kMinRowHeight = 44.0;
  static const _kChipRadius = 8.0;
  static const _kChipGap = 8.0;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();

    final segments = _segmentCategories(categories);
    final children = <Widget>[];

    var pendingWideRows = <ExploreCategory>[];

    void flushWideRows() {
      if (pendingWideRows.isEmpty) return;
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: _kChipGap),
          child: IosGroup(
            children: [
              for (var i = 0; i < pendingWideRows.length; i++)
                _WideKindRow(
                  category: pendingWideRows[i],
                  onTap: onCategoryTap,
                ),
            ],
          ),
        ),
      );
      pendingWideRows = [];
    }

    for (final segment in segments) {
      if (segment is _WideSegment) {
        if (!segment.category.hasUrl) {
          flushWideRows();
          children.add(
            IosSectionHeader(
              segment.category.title,
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 6),
            ),
          );
        } else {
          pendingWideRows.add(segment.category);
        }
      } else {
        flushWideRows();
        if (segment is _CellRowSegment) {
          children.add(
            _CellKindRow(
              categories: segment.categories,
              onTap: onCategoryTap,
            ),
          );
        } else if (segment is _WrapSegment) {
          children.add(
            _WrapKindRow(
              categories: segment.categories,
              onTap: onCategoryTap,
            ),
          );
        }
      }
    }
    flushWideRows();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
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

// ─── 全宽行（wide，iOS Settings 列表项）────────────────────────────────────

class _WideKindRow extends StatelessWidget {
  const _WideKindRow({
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

    final textAlign = _textAlignFor(justify);
    final alignment = switch (justify) {
      'flex_start' || 'start' => Alignment.centerLeft,
      'flex_end' || 'end' => Alignment.centerRight,
      _ => Alignment.centerLeft,
    };

    final row = ConstrainedBox(
      constraints: const BoxConstraints(
        minHeight: ExploreKindLayout._kMinRowHeight,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: alignment,
                child: Text(
                  category.title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: textAlign,
                ),
              ),
            ),
            if (hasUrl)
              Icon(
                Icons.chevron_right,
                size: 20,
                color: colorScheme.outlineVariant,
              ),
          ],
        ),
      ),
    );

    if (!hasUrl) return row;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onTap?.call(category.title, category.url!),
        child: row,
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
      padding: const EdgeInsets.only(bottom: ExploreKindLayout._kChipGap),
      child: Row(
        children: [
          for (var i = 0; i < categories.length; i++) ...[
            if (i > 0) const SizedBox(width: ExploreKindLayout._kChipGap),
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
      padding: const EdgeInsets.only(bottom: ExploreKindLayout._kChipGap),
      child: Wrap(
        spacing: ExploreKindLayout._kChipGap,
        runSpacing: ExploreKindLayout._kChipGap,
        children: [
          for (final category in categories)
            _KindChip(category: category, onTap: onTap),
        ],
      ),
    );
  }
}

// ─── 单个 Chip（系统灰底 + 克制圆角）────────────────────────────────────────

class _KindChip extends StatefulWidget {
  const _KindChip({
    required this.category,
    this.onTap,
  });

  final ExploreCategory category;
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

    final fill = _pressed && hasUrl
        ? colorScheme.onSurfaceVariant.withValues(alpha: 0.22)
        : colorScheme.onSurfaceVariant.withValues(alpha: 0.12);

    final label = Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
      ),
      alignment: Alignment.center,
      child: Text(
        widget.category.title,
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
        onTap: () => widget.onTap?.call(widget.category.title, widget.category.url!),
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
    _ => TextAlign.start,
  };
}

/// [ExploreCategory] 布局辅助
extension ExploreCategoryLayout on ExploreCategory {
  FlexChildStyle get effectiveStyle =>
      style ?? const FlexChildStyle();

  bool get hasUrl => url != null && url!.trim().isNotEmpty;
}
