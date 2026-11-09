/// 笔记（书签标记）配置 Sheet（契约 §2.52，批7b-2a）
///
/// 对齐参考版 `MarkingSheet.kt`：
/// - 标题「笔记 / 编辑笔记」、选中文本预览（最多 3 行）；
/// - 16 预设色横向色板（选中环，颜色取自 `MarkingPresetColors`）；
/// - 7 效果格（单实线/波浪线/虚线/删除线/荧光/背景色/字体色）；
/// - 备注多行输入、保存；编辑模式显示删除（二次确认）。
///
/// 本批只做 UI 与落库，不做正文渲染（7b-2b）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../providers/book_marking/book_marking_notifier.dart';
import '../../utils/error_message.dart';

/// 笔记配置底部 Sheet
class MarkingSheet extends ConsumerStatefulWidget {
  const MarkingSheet({
    super.key,
    required this.bookName,
    required this.bookAuthor,
    required this.bookUrl,
    required this.chapterIndex,
    required this.chapterName,
    required this.chapterPosition,
    required this.selectedText,
    this.contextBefore = '',
    this.contextAfter = '',
    this.existing,
  });

  /// 书籍信息（跨源关联键 + 创建源指纹）
  final String bookName;
  final String bookAuthor;
  final String bookUrl;

  /// 章节信息
  final int chapterIndex;
  final String chapterName;

  /// 选区在章节正文中的起始偏移
  final int chapterPosition;

  /// 选中文本（未归一化）
  final String selectedText;

  /// 选区前后文（定位消歧用）
  final String contextBefore;
  final String contextAfter;

  /// 编辑模式的已有标记；null 为新建
  final BookMarking? existing;

  /// 打开 Sheet；保存返回落库对象，取消/删除返回 null
  static Future<BookMarking?> show(
    BuildContext context, {
    required String bookName,
    required String bookAuthor,
    required String bookUrl,
    required int chapterIndex,
    required String chapterName,
    required int chapterPosition,
    required String selectedText,
    String contextBefore = '',
    String contextAfter = '',
    BookMarking? existing,
  }) {
    return showModalBottomSheet<BookMarking>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => MarkingSheet(
        bookName: bookName,
        bookAuthor: bookAuthor,
        bookUrl: bookUrl,
        chapterIndex: chapterIndex,
        chapterName: chapterName,
        chapterPosition: chapterPosition,
        selectedText: selectedText,
        contextBefore: contextBefore,
        contextAfter: contextAfter,
        existing: existing,
      ),
    );
  }

  @override
  ConsumerState<MarkingSheet> createState() => _MarkingSheetState();
}

class _MarkingSheetState extends ConsumerState<MarkingSheet> {
  late final TextEditingController _noteCtrl;
  late MarkingEffect _effect;
  late int _color;
  late final BookMarkingAnchor? _existingAnchor;
  late final BookMarkingStyle? _existingStyle;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  String get _previewText {
    final anchorText = _existingAnchor?.selectedText ?? '';
    if (anchorText.isNotEmpty) return anchorText;
    return widget.selectedText.trim();
  }

  @override
  void initState() {
    super.initState();
    _existingAnchor = BookMarkingAnchor.tryParse(widget.existing?.anchorJson);
    _existingStyle = BookMarkingStyle.tryParse(widget.existing?.styleJson);
    _effect = MarkingEffect.fromStyle(_existingStyle);
    _color = MarkingEffect.colorOf(_existingStyle);
    _noteCtrl = TextEditingController(text: widget.existing?.note ?? '');
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  BookMarkingStyle _composeStyle() {
    final style = _effect.toStyle(_color);
    // 编辑模式保留参考版隐藏透传字段（本批不编辑宽度/偏移/SVG）
    final base = _existingStyle;
    if (base == null) return style;
    return style.copyWith(
      underlineWidth: base.underlineWidth,
      underlineOffset: base.underlineOffset,
      underlineSvgPath: base.underlineSvgPath,
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    if (widget.bookName.isEmpty ||
        widget.bookAuthor.isEmpty ||
        widget.bookUrl.isEmpty) {
      _toast('无法保存笔记：未打开书籍');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(bookMarkingNotifierProvider.notifier)
          .save(
            bookName: widget.bookName,
            bookAuthor: widget.bookAuthor,
            bookUrl: widget.bookUrl,
            chapterIndex: widget.chapterIndex,
            chapterName: widget.chapterName,
            chapterPosition: widget.chapterPosition,
            selectedText: _previewText,
            style: _composeStyle(),
            note: _noteCtrl.text.trim(),
            contextBefore: widget.contextBefore,
            contextAfter: widget.contextAfter,
          );
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存笔记失败：${errorMessage(e)}');
    }
  }

  Future<void> _delete() async {
    final existing = widget.existing;
    if (existing == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除笔记？'),
        content: const Text('删除后不可恢复。'),
        actions: [
          TextButton(
            key: const ValueKey('marking-delete-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('marking-delete-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref
          .read(bookMarkingNotifierProvider.notifier)
          .delete(existing.id);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      _toast('删除笔记失败：${errorMessage(e)}');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.85;
    final style = _composeStyle();
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        key: const ValueKey('marking-sheet'),
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _editing ? '编辑笔记' : '笔记',
                      key: const ValueKey('marking-sheet-title'),
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  if (_editing)
                    IconButton(
                      key: const ValueKey('marking-delete'),
                      tooltip: '删除笔记',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _delete,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(
                    alpha: 0.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _previewText.isEmpty ? '（无选中文本）' : _previewText,
                  key: const ValueKey('marking-preview'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: _previewStyle(theme, style),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '颜色',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 6),
              SingleChildScrollView(
                key: const ValueKey('marking-color-row'),
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < kMarkingPresetColors.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: _ColorSwatch(
                          key: ValueKey(
                            'marking-color-'
                            '${kMarkingPresetColors[i].toRadixString(16)}',
                          ),
                          color: kMarkingPresetColors[i],
                          selected: kMarkingPresetColors[i] == _color,
                          onTap: () => setState(
                            () => _color = kMarkingPresetColors[i],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '效果',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final effect in MarkingEffect.values)
                    Expanded(
                      child: _EffectCell(
                        key: ValueKey('marking-effect-${effect.name}'),
                        effect: effect,
                        selected: effect == _effect,
                        onTap: () => setState(() => _effect = effect),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('marking-note-field'),
                controller: _noteCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注',
                  hintText: '输入备注…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('marking-save'),
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(_saving ? '保存中…' : '保存'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 预览文本效果（下划线/删除线/背景/字色；荧光按双下划线近似）
  TextStyle _previewStyle(ThemeData theme, BookMarkingStyle style) {
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    final color = Color(_color);
    switch (_effect) {
      case MarkingEffect.solid:
        return base.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: color,
          decorationStyle: TextDecorationStyle.solid,
          decorationThickness: style.underlineWidth.clamp(1, 4).toDouble(),
        );
      case MarkingEffect.wave:
        return base.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: color,
          decorationStyle: TextDecorationStyle.wavy,
          decorationThickness: style.underlineWidth.clamp(1, 4).toDouble(),
        );
      case MarkingEffect.dashed:
        return base.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: color,
          decorationStyle: TextDecorationStyle.dashed,
          decorationThickness: style.underlineWidth.clamp(1, 4).toDouble(),
        );
      case MarkingEffect.strike:
        return base.copyWith(
          decoration: TextDecoration.lineThrough,
          decorationColor: color,
          decorationThickness: style.underlineWidth.clamp(1, 4).toDouble(),
        );
      case MarkingEffect.highlight:
        return base.copyWith(
          decoration: TextDecoration.underline,
          decorationColor: color,
          decorationStyle: TextDecorationStyle.double,
          decorationThickness: style.underlineWidth.clamp(1, 4).toDouble(),
        );
      case MarkingEffect.bg:
        return base.copyWith(backgroundColor: Color(style.bgColor ?? _color));
      case MarkingEffect.text:
        return base.copyWith(color: Color(style.textColor ?? _color));
    }
  }
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final int color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fill = Color(color);
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: fill,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 16,
                color: fill.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white,
              )
            : null,
      ),
    );
  }
}

class _EffectCell extends StatelessWidget {
  const _EffectCell({
    super.key,
    required this.effect,
    required this.selected,
    required this.onTap,
  });

  final MarkingEffect effect;
  final bool selected;
  final VoidCallback onTap;

  IconData get _icon => switch (effect) {
    MarkingEffect.solid => Icons.format_underline,
    MarkingEffect.wave => Icons.waves,
    MarkingEffect.dashed => Icons.linear_scale,
    MarkingEffect.strike => Icons.format_strikethrough,
    MarkingEffect.highlight => Icons.highlight,
    MarkingEffect.bg => Icons.format_color_fill,
    MarkingEffect.text => Icons.format_color_text,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _icon,
                size: 18,
                color: selected
                    ? theme.colorScheme.onSecondaryContainer
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  effect.label,
                  maxLines: 1,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: selected
                        ? theme.colorScheme.onSecondaryContainer
                        : theme.colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
