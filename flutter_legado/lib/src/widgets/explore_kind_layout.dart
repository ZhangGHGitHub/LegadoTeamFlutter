/// 发现分类 Flexbox 布局（对标 Android ExploreAdapter + FlexboxLayout）
///
/// 支持 url / toggle / select / button / text 控件类型；
/// toggle/select 写入 Rust infoMap，保证与原版请求 URL 一致。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';

/// 按 [FlexChildStyle.layoutFlexBasisPercent] 将分类项排布为全宽行 / 网格 Chip。
class ExploreKindLayout extends StatelessWidget {
  const ExploreKindLayout({
    super.key,
    required this.sourceUrl,
    required this.categories,
    this.onCategoryTap,
  });

  final String sourceUrl;
  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onCategoryTap;

  static const _kChipRadius = 10.0;
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
            children.add(SizedBox(width: maxWidth, height: 0));
          }
          children.add(
            _ExploreKindItem(
              sourceUrl: sourceUrl,
              category: category,
              width: _chipWidth(maxWidth, style),
              onCategoryTap: onCategoryTap,
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

  static double? _chipWidth(double maxWidth, FlexChildStyle style) {
    final basis = style.layoutFlexBasisPercent;
    if (basis >= 1.0) return maxWidth;
    if (basis <= 0) return null;

    final columns = (1.0 / basis).round().clamp(1, 12);
    return (maxWidth - _kChipGap * (columns - 1)) / columns;
  }
}

class _ExploreKindItem extends ConsumerWidget {
  const _ExploreKindItem({
    required this.sourceUrl,
    required this.category,
    this.width,
    this.onCategoryTap,
  });

  final String sourceUrl;
  final ExploreCategory category;
  final double? width;
  final void Function(String title, String url)? onCategoryTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (category.type) {
      'toggle' => _ToggleChip(
        sourceUrl: sourceUrl,
        category: category,
        width: width,
      ),
      'select' => _SelectChip(
        sourceUrl: sourceUrl,
        category: category,
        width: width,
      ),
      'button' => _StaticChip(
        category: category,
        width: width,
        onTap: null,
      ),
      'text' => _StaticChip(
        category: category,
        width: width,
        onTap: null,
        muted: true,
      ),
      _ => _StaticChip(
        category: category,
        width: width,
        onTap: category.hasUrl
            ? () => onCategoryTap?.call(category.title, category.url!)
            : null,
      ),
    };
  }
}

class _StaticChip extends StatefulWidget {
  const _StaticChip({
    required this.category,
    this.width,
    this.onTap,
    this.muted = false,
  });

  final ExploreCategory category;
  final double? width;
  final VoidCallback? onTap;
  final bool muted;

  @override
  State<_StaticChip> createState() => _StaticChipState();
}

class _StaticChipState extends State<_StaticChip> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hasTap = widget.onTap != null;

    final fill = _pressed && hasTap
        ? colorScheme.onSurface.withValues(alpha: 0.14)
        : colorScheme.onSurface.withValues(alpha: widget.muted ? 0.06 : 0.10);

    final label = Container(
      width: widget.width,
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
      ),
      alignment: Alignment.center,
      child: Text(
        widget.category.title,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: widget.muted
              ? colorScheme.onSurfaceVariant
              : colorScheme.onSurface,
          fontSize: 14,
          fontWeight: hasTap ? FontWeight.w500 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
    );

    if (!hasTap) return label;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (v) => setState(() => _pressed = v),
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
        splashColor: colorScheme.onSurface.withValues(alpha: 0.06),
        highlightColor: Colors.transparent,
        child: label,
      ),
    );
  }
}

class _ToggleChip extends ConsumerStatefulWidget {
  const _ToggleChip({
    required this.sourceUrl,
    required this.category,
    this.width,
  });

  final String sourceUrl;
  final ExploreCategory category;
  final double? width;

  @override
  ConsumerState<_ToggleChip> createState() => _ToggleChipState();
}

class _ToggleChipState extends ConsumerState<_ToggleChip> {
  late List<String> _chars;
  late int _index;

  @override
  void initState() {
    super.initState();
    _chars = widget.category.chars?.where((c) => c.isNotEmpty).toList() ??
        ['', ''];
    final defaultValue = widget.category.defaultValue ?? _chars.first;
    _index = _chars.indexOf(defaultValue);
    if (_index < 0) _index = 0;
  }

  Future<void> _cycle() async {
    setState(() => _index = (_index + 1) % _chars.length);
    final value = _chars[_index];
    await ref.read(bookApiProvider).exploreInfoMapPut(
          widget.sourceUrl,
          widget.category.title,
          value,
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final value = _chars[_index];
    final label = '$value${widget.category.title}';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _cycle,
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
        splashColor: colorScheme.onSurface.withValues(alpha: 0.06),
        child: Container(
          width: widget.width,
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: colorScheme.onSurface.withValues(alpha: 0.10),
            borderRadius:
                BorderRadius.circular(ExploreKindLayout._kChipRadius),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _SelectChip extends ConsumerStatefulWidget {
  const _SelectChip({
    required this.sourceUrl,
    required this.category,
    this.width,
  });

  final String sourceUrl;
  final ExploreCategory category;
  final double? width;

  @override
  ConsumerState<_SelectChip> createState() => _SelectChipState();
}

class _SelectChipState extends ConsumerState<_SelectChip> {
  late List<String> _chars;
  late int _index;

  @override
  void initState() {
    super.initState();
    _chars = widget.category.chars?.where((c) => c.isNotEmpty).toList() ??
        ['', ''];
    final defaultValue = widget.category.defaultValue ?? _chars.first;
    _index = _chars.indexOf(defaultValue);
    if (_index < 0) _index = 0;
  }

  Future<void> _onPick(int next) async {
    if (next == _index) return;
    setState(() => _index = next);
    await ref.read(bookApiProvider).exploreInfoMapPut(
          widget.sourceUrl,
          widget.category.title,
          _chars[next],
        );
  }

  Future<void> _showPicker() async {
    var picked = _index;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (ctx) => Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 8),
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(ctx)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.category.title,
                          style: Theme.of(ctx).textTheme.titleSmall,
                        ),
                      ),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: () => Navigator.pop(ctx),
                        child: Text(
                          '完成',
                          style: TextStyle(
                            color: Theme.of(ctx).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(
                  height: 216,
                  child: CupertinoPicker(
                    scrollController:
                        FixedExtentScrollController(initialItem: picked),
                    itemExtent: 36,
                    onSelectedItemChanged: (i) => picked = i,
                    children: _chars
                        .map((c) => Center(child: Text(c)))
                        .toList(),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    await _onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final value = _chars[_index];

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _showPicker,
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
        splashColor: colorScheme.onSurface.withValues(alpha: 0.06),
        child: Container(
          width: widget.width,
          constraints: const BoxConstraints(minHeight: 34),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: colorScheme.onSurface.withValues(alpha: 0.10),
            borderRadius:
                BorderRadius.circular(ExploreKindLayout._kChipRadius),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '${widget.category.title} · $value',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurface,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Icon(
                Icons.unfold_more,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [ExploreCategory] 布局辅助
extension ExploreCategoryLayout on ExploreCategory {
  FlexChildStyle get effectiveStyle =>
      style ?? const FlexChildStyle();

  bool get hasUrl => url != null && url!.trim().isNotEmpty;
}
