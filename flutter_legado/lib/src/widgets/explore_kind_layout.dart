/// 发现分类 Flexbox 布局（对标 Android ExploreAdapter + FlexboxLayout）
///
/// 支持 url / toggle / select / button / text 控件类型；
/// toggle/select 写入 Rust infoMap，button/text 调用 exploreEvalAction；
/// java.refreshExplore 触发分类重载。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/models.dart';
import '../providers/providers.dart';
import 'explore_kind_action.dart';
import 'md3_picker_sheet.dart';

/// 读取 infoMap 已存值（B① 回显：toggle/select/text 初始显示与 Rust 请求
/// 实际使用的 infoMap 值一致；读不到返回 null）— DeepSeek Harness + UI
Future<String?> _loadStoredInfoMapValue(
  WidgetRef ref,
  String sourceUrl,
  String key,
) async {
  try {
    final json =
        await ref.read(bookApiProvider).exploreInfoMapSnapshot(sourceUrl);
    final map = jsonDecode(json);
    if (map is Map<String, dynamic>) {
      final v = map[key]?.toString();
      return (v != null && v.isNotEmpty) ? v : null;
    }
  } catch (_) {}
  return null;
}

/// 按 [FlexChildStyle.layoutFlexBasisPercent] 将分类项排布为全宽行 / 网格 Chip。
class ExploreKindLayout extends StatelessWidget {
  const ExploreKindLayout({
    super.key,
    required this.sourceUrl,
    required this.sourceJson,
    required this.categories,
    this.onCategoryTap,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final List<ExploreCategory> categories;
  final void Function(String title, String url)? onCategoryTap;
  final Future<void> Function()? onRefreshCategories;

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
              sourceJson: sourceJson,
              category: category,
              width: _chipWidth(maxWidth, style),
              onCategoryTap: onCategoryTap,
              onRefreshCategories: onRefreshCategories,
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

  static void _showExploreErrorDialog(BuildContext context, String message) {
    // [MD3 全量清点] 原 CupertinoAlertDialog（iOS 三级菜单）→ M3 AlertDialog，
    // 前景走全局 dialogTheme（surfaceContainerHigh + 28dp 圆角 + TextTheme）
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        title: const Text('发现分类加载失败'),
        content: SelectableText(
          message,
          style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                color: Theme.of(ctx).colorScheme.onSurfaceVariant,
              ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}

class _ExploreKindItem extends ConsumerWidget {
  const _ExploreKindItem({
    required this.sourceUrl,
    required this.sourceJson,
    required this.category,
    this.width,
    this.onCategoryTap,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final ExploreCategory category;
  final double? width;
  final void Function(String title, String url)? onCategoryTap;
  final Future<void> Function()? onRefreshCategories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (category.type) {
      'toggle' => _ToggleChip(
        sourceUrl: sourceUrl,
        sourceJson: sourceJson,
        category: category,
        width: width,
        onRefreshCategories: onRefreshCategories,
      ),
      'select' => _SelectChip(
        sourceUrl: sourceUrl,
        sourceJson: sourceJson,
        category: category,
        width: width,
        onRefreshCategories: onRefreshCategories,
      ),
      'button' => _ButtonChip(
        sourceUrl: sourceUrl,
        sourceJson: sourceJson,
        category: category,
        width: width,
        onRefreshCategories: onRefreshCategories,
      ),
      'text' => _TextChip(
        sourceUrl: sourceUrl,
        sourceJson: sourceJson,
        category: category,
        width: width,
        onRefreshCategories: onRefreshCategories,
      ),
      _ => _StaticChip(
        category: category,
        width: width,
        onTap: category.hasUrl
            ? () {
                if (category.title == 'ERROR' || category.title.startsWith('ERROR:')) {
                  ExploreKindLayout._showExploreErrorDialog(
                    context,
                    category.url ?? category.title,
                  );
                  return;
                }
                onCategoryTap?.call(category.title, category.url!);
              }
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
    this.label,
  });

  final ExploreCategory category;
  final double? width;
  final VoidCallback? onTap;
  final String? label;

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
    final text = widget.label ?? widget.category.title;

    final fill = _pressed && hasTap
        ? colorScheme.onSurface.withValues(alpha: 0.14)
        : colorScheme.onSurface.withValues(alpha: 0.10);

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
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
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

class _DynamicLabel extends ConsumerStatefulWidget {
  const _DynamicLabel({
    required this.sourceJson,
    required this.category,
    required this.fallback,
    required this.builder,
  });

  final String sourceJson;
  final ExploreCategory category;
  final String fallback;
  final Widget Function(String label) builder;

  @override
  ConsumerState<_DynamicLabel> createState() => _DynamicLabelState();
}

class _DynamicLabelState extends ConsumerState<_DynamicLabel> {
  late String _label;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _label = _resolveInitialLabel();
    _loadDynamicLabel();
  }

  String _resolveInitialLabel() {
    final literal = ExploreKindActionRunner.literalViewName(widget.category.viewName);
    if (literal != null) return literal;
    return widget.fallback;
  }

  Future<void> _loadDynamicLabel() async {
    final viewName = widget.category.viewName;
    if (viewName == null || ExploreKindActionRunner.literalViewName(viewName) != null) {
      return;
    }
    setState(() => _loading = true);
    try {
      final text = await ref.read(bookApiProvider).exploreEvalUiJs(
            sourceJson: widget.sourceJson,
            jsStr: viewName,
          );
      if (!mounted) return;
      setState(() {
        _label = text.isEmpty ? 'null' : text;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _label = 'err';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return widget.builder(widget.fallback);
    }
    return widget.builder(_label);
  }
}

class _ButtonChip extends ConsumerStatefulWidget {
  const _ButtonChip({
    required this.sourceUrl,
    required this.sourceJson,
    required this.category,
    this.width,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final ExploreCategory category;
  final double? width;
  final Future<void> Function()? onRefreshCategories;

  @override
  ConsumerState<_ButtonChip> createState() => _ButtonChipState();
}

class _ButtonChipState extends ConsumerState<_ButtonChip> {
  bool _busy = false;

  Future<void> _onTap() async {
    final action = widget.category.action?.trim();
    if (action == null || action.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await ExploreKindActionRunner.runAction(
        ref: ref,
        sourceJson: widget.sourceJson,
        action: action,
        onRefreshCategories: widget.onRefreshCategories,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasAction =
        widget.category.action != null && widget.category.action!.trim().isNotEmpty;

    return _DynamicLabel(
      sourceJson: widget.sourceJson,
      category: widget.category,
      fallback: widget.category.title,
      builder: (label) => _StaticChip(
        category: widget.category,
        width: widget.width,
        label: _busy ? '$label…' : label,
        onTap: hasAction && !_busy ? _onTap : null,
      ),
    );
  }
}

class _ToggleChip extends ConsumerStatefulWidget {
  const _ToggleChip({
    required this.sourceUrl,
    required this.sourceJson,
    required this.category,
    this.width,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final ExploreCategory category;
  final double? width;
  final Future<void> Function()? onRefreshCategories;

  @override
  ConsumerState<_ToggleChip> createState() => _ToggleChipState();
}

class _ToggleChipState extends ConsumerState<_ToggleChip> {
  late List<String> _chars;
  late int _index;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _chars = widget.category.chars?.where((c) => c.isNotEmpty).toList() ??
        ['', ''];
    final defaultValue = widget.category.defaultValue ?? _chars.first;
    _index = _chars.indexOf(defaultValue);
    if (_index < 0) _index = 0;
    // 回显 infoMap 已存值（对齐原版 ExploreAdapter 读 infoMap[title]）— B①
    _loadStoredValue();
  }

  Future<void> _loadStoredValue() async {
    final stored = await _loadStoredInfoMapValue(
      ref,
      widget.sourceUrl,
      widget.category.title,
    );
    if (stored == null || !mounted) return;
    final idx = _chars.indexOf(stored);
    if (idx >= 0 && idx != _index) {
      setState(() => _index = idx);
    }
  }

  Future<void> _afterValueChanged() async {
    final value = _chars[_index];
    await ref.read(bookApiProvider).exploreInfoMapPut(
          widget.sourceUrl,
          widget.category.title,
          value,
        );
    final action = widget.category.action?.trim();
    if (action == null || action.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ExploreKindActionRunner.runAction(
        ref: ref,
        sourceJson: widget.sourceJson,
        action: action,
        onRefreshCategories: widget.onRefreshCategories,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cycle() async {
    if (_busy) return;
    setState(() => _index = (_index + 1) % _chars.length);
    await _afterValueChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final value = _chars[_index];

    return _DynamicLabel(
      sourceJson: widget.sourceJson,
      category: widget.category,
      fallback: widget.category.title,
      builder: (title) {
        final label = '$value$title';
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _busy ? null : _cycle,
            borderRadius:
                BorderRadius.circular(ExploreKindLayout._kChipRadius),
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
                _busy ? '$label…' : label,
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
      },
    );
  }
}

class _SelectChip extends ConsumerStatefulWidget {
  const _SelectChip({
    required this.sourceUrl,
    required this.sourceJson,
    required this.category,
    this.width,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final ExploreCategory category;
  final double? width;
  final Future<void> Function()? onRefreshCategories;

  @override
  ConsumerState<_SelectChip> createState() => _SelectChipState();
}

class _SelectChipState extends ConsumerState<_SelectChip> {
  late List<String> _chars;
  late int _index;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _chars = widget.category.chars?.where((c) => c.isNotEmpty).toList() ??
        ['', ''];
    final defaultValue = widget.category.defaultValue ?? _chars.first;
    _index = _chars.indexOf(defaultValue);
    if (_index < 0) _index = 0;
    // 回显 infoMap 已存值（对齐原版 ExploreAdapter 读 infoMap[title]）— B①
    _loadStoredValue();
  }

  Future<void> _loadStoredValue() async {
    final stored = await _loadStoredInfoMapValue(
      ref,
      widget.sourceUrl,
      widget.category.title,
    );
    if (stored == null || !mounted) return;
    final idx = _chars.indexOf(stored);
    if (idx >= 0 && idx != _index) {
      setState(() => _index = idx);
    }
  }

  Future<void> _onPick(int next) async {
    if (next == _index || _busy) return;
    setState(() => _index = next);
    final value = _chars[next];
    await ref.read(bookApiProvider).exploreInfoMapPut(
          widget.sourceUrl,
          widget.category.title,
          value,
        );
    final action = widget.category.action?.trim();
    if (action == null || action.isEmpty) return;
    setState(() => _busy = true);
    try {
      await ExploreKindActionRunner.runAction(
        ref: ref,
        sourceJson: widget.sourceJson,
        action: action,
        onRefreshCategories: widget.onRefreshCategories,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showPicker() async {
    if (_busy) return;
    final titleLabel = ExploreKindActionRunner.literalViewName(
          widget.category.viewName,
        ) ??
        widget.category.title;

    final picked = await showMd3WheelPickerSheet(
      context: context,
      title: titleLabel,
      itemCount: _chars.length,
      initialIndex: _index,
      itemBuilder: (ctx, i) => Text(_chars[i]),
    );
    if (!mounted || picked == null) return;
    await _onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final value = _chars[_index];

    return _DynamicLabel(
      sourceJson: widget.sourceJson,
      category: widget.category,
      fallback: widget.category.title,
      builder: (title) {
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _busy ? null : _showPicker,
            borderRadius:
                BorderRadius.circular(ExploreKindLayout._kChipRadius),
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
                      _busy ? '$title · $value…' : '$title · $value',
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
      },
    );
  }
}

class _TextChip extends ConsumerStatefulWidget {
  const _TextChip({
    required this.sourceUrl,
    required this.sourceJson,
    required this.category,
    this.width,
    this.onRefreshCategories,
  });

  final String sourceUrl;
  final String sourceJson;
  final ExploreCategory category;
  final double? width;
  final Future<void> Function()? onRefreshCategories;

  @override
  ConsumerState<_TextChip> createState() => _TextChipState();
}

class _TextChipState extends ConsumerState<_TextChip> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String? _lastSubmitted;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    // 回显 infoMap 已存值（对齐原版 ExploreAdapter 读 infoMap[title]）— B①
    _loadStoredValue();
  }

  Future<void> _loadStoredValue() async {
    final stored = await _loadStoredInfoMapValue(
      ref,
      widget.sourceUrl,
      widget.category.title,
    );
    if (stored == null || !mounted) return;
    _controller.text = stored;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _controller.text;
    ref.read(bookApiProvider).exploreInfoMapPut(
          widget.sourceUrl,
          widget.category.title,
          text,
        );
    final action = widget.category.action?.trim();
    if (action == null || action.isEmpty) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      if (_lastSubmitted == text) return;
      _lastSubmitted = text;
      await ExploreKindActionRunner.runAction(
        ref: ref,
        sourceJson: widget.sourceJson,
        action: action,
        onRefreshCategories: widget.onRefreshCategories,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final hint = ExploreKindActionRunner.literalViewName(widget.category.viewName) ??
        widget.category.title;

    return Container(
      width: widget.width,
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: colorScheme.onSurface.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(ExploreKindLayout._kChipRadius),
      ),
      child: TextField(
        controller: _controller,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurface,
          fontSize: 14,
        ),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontSize: 14,
          ),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
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
