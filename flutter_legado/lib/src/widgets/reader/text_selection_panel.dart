// [UI-fix v2.0.1 | 2026-08-06] 阅读器正文长按选择 + 9 项操作菜单（P0-1 审计修复） — Qoder
//
// 对齐 Android 原版 ReadBookActivity + TextActionMenu（content_select_action.xml）：
// 长按正文 → 选中文本 → 弹出操作菜单（替换/复制/书签/高亮/朗读/词典/搜正文/浏览器/分享）。
//
// 选区方案（最小侵入）：
// Flutter 侧正文为排版引擎分页后的逐行 Text 渲染（非 SelectableText，且处于
// PageView / 滚动容器中），原地实现拖拽手柄跨行选区代价过大。故采用任务建议的
// 段落选区面板：长按段落 → 底部面板展示整段 SelectableText（原生长按取词 /
// 拖拽手柄精细调整选区）+ 操作菜单。默认操作文本为整段，选区变化后以选区为准。
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/models.dart';
import '../../models/selection_menu_config.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../screens/reader_config_panel.dart';
import 'marking_sheet.dart';
import 'selection_menu_actions.dart';
import 'text_select_menu_config_sheet.dart';

/// 高亮配色（对齐原版 HighlightStyle 多色能力，颜色写入 BookHighlight.style JSON）
const List<Color> kHighlightColors = [
  Color(0xFFFFE082), // 琥珀
  Color(0xFFA5D6A7), // 绿
  Color(0xFF90CAF9), // 蓝
  Color(0xFFF48FB1), // 粉
  Color(0xFFFFCC80), // 橙
];

/// 选区起点在章节正文中的 UTF-16 偏移（批34b P3-2）
///
/// [paragraphText] 为段落渲染文本（含首行缩进全角空格），[chapterPos] 为
/// 段落正文（trim 后）在章节中的起始偏移。缩进列不在章节正文中，故精细
/// 选区定位后须扣除缩进宽度；未精细选择（整段）时直接取段落起点。
int chapterOffsetOfSelection({
  required String paragraphText,
  required int chapterPos,
  required String selection,
  required bool fineSelection,
}) {
  final indent = paragraphText.length - paragraphText.trimLeft().length;
  if (!fineSelection || selection.isEmpty) return chapterPos;
  final index = paragraphText.indexOf(selection);
  if (index < 0) return chapterPos;
  final bodyLength = paragraphText.length - indent;
  final bodyIndex = (index - indent).clamp(0, bodyLength);
  return chapterPos + bodyIndex;
}

/// 选区前后文片段（锚点消歧用；各最多 24 个 UTF-16 单元）
({String before, String after}) markingContextAround(
  String content,
  int position,
  int selectedLength,
) {
  if (content.isEmpty) return (before: '', after: '');
  const span = 24;
  final start = position.clamp(0, content.length);
  final end = (start + selectedLength).clamp(0, content.length);
  return (
    before: content.substring(
      (start - span).clamp(0, content.length),
      start,
    ),
    after: content.substring(end, (end + span).clamp(0, content.length)),
  );
}

/// 打开「笔记」Sheet（划词菜单 menu_mark，对齐参考版 MarkingSheet）
///
/// [fineSelection] 为 true 时按选区文本在段落中的位置计算章节偏移；
/// 否则按段落起点。书籍/章节信息取自当前阅读状态。
Future<void> openMarkingForSelection(
  BuildContext context,
  WidgetRef ref, {
  required String paragraphText,
  required int chapterPos,
  required String selectedText,
  required bool fineSelection,
  VoidCallback? onBeforeOpen,
}) async {
  final state = ref.read(readerNotifierProvider);
  final book = state.currentBook;
  if (book == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('无法添加笔记：未打开书籍'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    return;
  }
  final chapter = state.currentChapter;
  final position = chapterOffsetOfSelection(
    paragraphText: paragraphText,
    chapterPos: chapterPos,
    selection: fineSelection ? selectedText : '',
    fineSelection: fineSelection,
  );
  final contextAround = markingContextAround(
    state.chapterContent,
    position,
    selectedText.length,
  );
  final navigator = Navigator.of(context, rootNavigator: true);
  onBeforeOpen?.call();
  await MarkingSheet.show(
    navigator.context,
    bookName: book.name,
    bookAuthor: book.author,
    bookUrl: book.bookUrl,
    chapterIndex: state.currentChapterIndex,
    chapterName: chapter?.title ?? '',
    chapterPosition: position,
    selectedText: selectedText,
    contextBefore: contextAround.before,
    contextAfter: contextAround.after,
  );
}

/// 正文长按选择操作面板
///
/// 对标原版 TextActionMenu 的菜单项清单（顺序对齐 content_select_action.xml）。
// [UI-fix v2.0.1 | 2026-08-06] 新建长按操作面板 — Qoder
class TextSelectionPanel extends ConsumerStatefulWidget {
  /// 长按命中的段落全文（默认操作文本）
  final String text;

  /// 段落在章节正文中的起始字符偏移（ParagraphInfo.startIndex；
  /// 批34 起为章节全局偏移，不再是恒 0）
  final int chapterPos;

  const TextSelectionPanel({
    super.key,
    required this.text,
    this.chapterPos = 0,
  });

  /// 弹出面板
  static Future<void> show(
    BuildContext context, {
    required String text,
    int chapterPos = 0,
  }) {
    if (text.trim().isEmpty) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TextSelectionPanel(
        text: text,
        chapterPos: chapterPos,
      ),
    );
  }

  @override
  ConsumerState<TextSelectionPanel> createState() => _TextSelectionPanelState();
}

class _TextSelectionPanelState extends ConsumerState<TextSelectionPanel> {
  /// 用户通过原生选区手柄选中的文本（空表示未精细选择，回退整段）
  String _userSelected = '';

  /// 是否展开高亮配色行（手工高亮二级入口，保留既有能力）
  bool _showHighlightColors = false;

  /// 上次使用的高亮颜色（会话内记忆，对齐原版 highlightLastStyle 的简化版）
  static Color _lastHighlightColor = kHighlightColors.first;

  /// [批4d] 拖选振动节流（避免每个字符都触发马达）
  DateTime _lastSelectHapticAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 起选/拖选手柄触发 selectVibrator；参考 LongPress/TextHandleMove
  void _maybeSelectHaptic(SelectionChangedCause? cause) {
    if (cause != SelectionChangedCause.drag &&
        cause != SelectionChangedCause.longPress) {
      return;
    }
    final cfg = ref.read(readerAdvConfigProvider);
    if (!(cfg?.selectVibrator ?? false)) return;
    final now = DateTime.now();
    if (now.difference(_lastSelectHapticAt).inMilliseconds < 60) return;
    _lastSelectHapticAt = now;
    HapticFeedback.selectionClick();
  }

  /// 当前操作文本：优先取用户选区，未选择时为整段
  String get _selectedText {
    final selected = _userSelected.trim();
    return selected.isEmpty ? widget.text.trim() : selected;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = ref.watch(readerAdvConfigProvider) ?? ReaderAdvancedConfig();
    final menuView = SelectionMenuConfig.decode(cfg.textSelectMenuConfig).view;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.dividerColor.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  '已选文本',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_selectedText.length} 字',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
                const Spacer(),
                // [批7b-2a] menu_mark 改为「笔记」后，手工高亮保留为面板内
                // 二级入口（参考版无独立高亮项；既有 highlightAdd 能力不删）
                TextButton(
                  key: const ValueKey('selection-panel-highlight'),
                  onPressed: () => setState(
                    () => _showHighlightColors = !_showHighlightColors,
                  ),
                  child: const Text('高亮'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
            // 段落选区：原生 SelectableText（长按取词 + 拖拽手柄精细调整）
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.3,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    widget.text,
                    style: theme.textTheme.bodyLarge?.copyWith(height: 1.6),
                    onSelectionChanged: (selection, cause) {
                      _maybeSelectHaptic(cause);
                      final text = widget.text;
                      if (!selection.isValid || selection.isCollapsed) {
                        if (_userSelected.isNotEmpty) {
                          setState(() => _userSelected = '');
                        }
                        return;
                      }
                      final start = selection.start.clamp(0, text.length);
                      final end = selection.end.clamp(0, text.length);
                      setState(
                        () => _userSelected = text.substring(start, end),
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '提示：长按上方文本可精细调整选区，未选择时默认操作整段',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            // 操作菜单（批4c：按选择菜单配置排序/分区）
            // [审查 P2-1] 动作可横向滚动，管理按钮固定在滚动区外，
            // 避免 360dp 下被挤出屏幕后折叠组不可达。
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    key: const ValueKey('selection-panel-actions-scroll'),
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final def in menuView.active)
                          _actionItem(
                            def,
                            showIcon: cfg.showSelectMenuIcon,
                            onTap: _panelAction(def.id),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: 24,
                  child: VerticalDivider(
                    width: 1,
                    color: theme.colorScheme.outlineVariant,
                  ),
                ),
                IconButton(
                  key: const ValueKey('selection-panel-manage'),
                  tooltip: '管理选择菜单',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.settings_outlined, size: 20),
                  onPressed: () => unawaited(
                    TextSelectMenuConfigSheet.showForReader(
                      context,
                      ProviderScope.containerOf(context, listen: false),
                    ),
                  ),
                ),
              ],
            ),
            // 高亮配色行（多色高亮，对齐原版 HighlightStyle）
            AnimatedSize(
              duration: const Duration(milliseconds: 150),
              child: _showHighlightColors
                  ? Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Text(
                            '高亮颜色',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                          const SizedBox(width: 12),
                          for (final color in kHighlightColors)
                            Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: InkWell(
                                onTap: () => _openHighlightDialog(color),
                                customBorder: const CircleBorder(),
                                child: Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: color,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: color == _lastHighlightColor
                                          ? theme.colorScheme.primary
                                          : theme.dividerColor,
                                      width: color == _lastHighlightColor
                                          ? 2.5
                                          : 1,
                                    ),
                                  ),
                                  child: color == _lastHighlightColor
                                      ? Icon(
                                          Icons.check,
                                          size: 18,
                                          color: theme.colorScheme.onSurface,
                                        )
                                      : null,
                                ),
                              ),
                            ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionItem(
    SelectionMenuItemDef def, {
    required bool showIcon,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      key: ValueKey('selection-panel-action-${def.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIcon) ...[
              Icon(def.icon, size: 22, color: theme.colorScheme.primary),
              const SizedBox(height: 4),
            ],
            Text(def.label, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }

  VoidCallback _panelAction(String id) {
    // [审查 P3] 面板动作统一走 selection_menu_actions，避免与浮条
    // 各维护一份实现（书签也在此统一为先收起面板再落库）。
    switch (id) {
      case SelectionMenuIds.copy:
        return () => unawaited(selectionCopy(context, _selectedText, _close));
      case SelectionMenuIds.share:
        return () => unawaited(selectionShare(context, _selectedText, _close));
      case SelectionMenuIds.browser:
        return () =>
            unawaited(selectionOpenBrowser(context, _selectedText, _close));
      case SelectionMenuIds.aloud:
        return () => unawaited(
          selectionReadAloud(
            ref,
            context,
            selectedText: _selectedText,
            paragraphText: widget.text,
            chapterPos: widget.chapterPos,
            onDone: _close,
          ),
        );
      case SelectionMenuIds.bookmark:
        return () => unawaited(
          selectionAddBookmark(
            ref,
            context,
            selectedText: _selectedText,
            chapterPos: widget.chapterPos,
            onDone: _close,
          ),
        );
      case SelectionMenuIds.mark:
        return () => unawaited(
          openMarkingForSelection(
            context,
            ref,
            paragraphText: widget.text,
            chapterPos: widget.chapterPos,
            selectedText: _selectedText,
            fineSelection: _userSelected.trim().isNotEmpty,
            onBeforeOpen: _close,
          ),
        );
      case SelectionMenuIds.dict:
        return () => selectionLookupDict(context, _selectedText, _close);
      case SelectionMenuIds.replace:
        return () => selectionReplace(context, _selectedText, _close);
      case SelectionMenuIds.edit:
        return () => selectionEdit(ref, context, _close);
      case SelectionMenuIds.search:
        return () =>
            selectionSearchContent(ref, context, _selectedText, _close);
      default:
        return () {};
    }
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  // ===== 菜单动作（顺序对齐原版 TextSelectMenuItem） =====

  /// 高亮样式/笔记 Dialog（对齐 HighlightStyleDialog 配色 + HighlightNoteDialog 笔记）
  Future<void> _openHighlightDialog(Color color) async {
    final noteCtrl = TextEditingController();
    final selectedColor = ValueNotifier<Color>(color);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final bottom = MediaQuery.viewInsetsOf(ctx).bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, 16 + bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('高亮', style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: 12),
              Text('样式颜色', style: Theme.of(ctx).textTheme.bodySmall),
              const SizedBox(height: 8),
              ValueListenableBuilder<Color>(
                valueListenable: selectedColor,
                builder: (_, current, _) => Row(
                  children: [
                    for (final c in kHighlightColors)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: InkWell(
                          onTap: () => selectedColor.value = c,
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: c == current
                                    ? Theme.of(ctx).colorScheme.primary
                                    : Theme.of(ctx).dividerColor,
                                width: c == current ? 2.5 : 1,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: noteCtrl,
                maxLines: 3,
                decoration: const InputDecoration(labelText: '笔记（可选）'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('保存高亮'),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    final chosen = selectedColor.value;
    selectedColor.dispose();
    if (ok != true || !mounted) return;
    await _saveHighlight(chosen, note: noteCtrl.text.trim());
  }

  /// 高亮：对齐原版 menu_highlight → createHighlight + ReadBook.addHighlight
  ///
  /// BookHighlight JSON 字段对齐 API_CONTRACT.md §2.36（DB v99 highlights 表）。
  Future<void> _saveHighlight(Color color, {String note = ''}) async {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) {
      _toast('无法添加高亮：未打开书籍');
      return;
    }
    final chapter = state.currentChapter;
    final selected = _selectedText;
    // [批34b P3-2] 段落渲染文本含首行缩进全角空格（不在章节正文中），
    // 章节偏移须扣除缩进列，否则高亮区间整体右移 — full-stack-engineer
    final chapterPos = chapterOffsetOfSelection(
      paragraphText: widget.text,
      chapterPos: widget.chapterPos,
      selection: _userSelected,
      fineSelection: _userSelected.trim().isNotEmpty,
    );
    final highlight = <String, dynamic>{
      'time': 0, // 0 时由 Rust 侧自动分配主键
      'bookUrl': book.bookUrl,
      'chapterUrl': chapter?.url ?? '',
      'bookName': book.name,
      'bookAuthor': book.author,
      'chapterIndex': state.currentChapterIndex,
      'chapterPos': chapterPos,
      'chapterPosEnd': chapterPos + selected.length,
      'layoutTitleLength': 0,
      'chapterName': chapter?.title ?? '',
      'bookText': selected,
      'style': jsonEncode({
        'type': 'background',
        'color':
            '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
      }),
      'note': note,
    };
    try {
      await ref
          .read(bookApiProvider)
          .highlightAdd(highlightJson: jsonEncode(highlight));
      _lastHighlightColor = color;
      _toast(note.isEmpty ? '已添加高亮' : '已添加高亮与笔记');
      _close();
    } catch (e) {
      _toast('添加高亮失败：$e');
    }
  }
}

/// 正文长按浮出工具条（对齐参考版浮窗形态）
///
/// [UI_SYNC_REFACTOR S6 | 2026-09-08] 用户裁决 A（对齐参考版浮窗）：
/// 长按段落于按压点浮出工具条（复制/分享/浏览器/朗读/书签/更多）。
/// 「更多」打开保留的段落面板（替换/高亮/词典/搜正文/精细选区等增强
/// 动作不丢失）。注：SelectionArea 在阅读器 PageView 手势栈下长按
/// 不触发（探针实证），故用长按点 Overlay 浮条，行为确定 — Qoder
class ReaderSelectionToolbar extends ConsumerWidget {
  /// 按压点全局坐标（工具条锚点）
  final Offset anchor;

  /// 段落全文（动作作用文本）
  final String text;

  /// 选区起始段内位置（书签/朗读定位用，与段落面板同语义）
  final int chapterPos;

  final VoidCallback onDismiss;

  const ReaderSelectionToolbar({
    super.key,
    required this.anchor,
    required this.text,
    required this.chapterPos,
    required this.onDismiss,
  });

  /// 浮出：全屏点击屏障 + 锚点工具条（点屏/执行动作即收起）
  static void show(
    BuildContext context, {
    required Offset anchor,
    required String text,
    required int chapterPos,
  }) {
    // [批1a | 2026-10-31] selectVibrator 接线（对标参考版
    // ReadBookRouteScreen selectionHapticsEnabled → ReaderCanvasSurface
    // 选词起选时 HapticFeedback）：选词振动开关开启时长按起选即触发 —
    // 全栈工程师
    final container = ProviderScope.containerOf(context);
    if (container.read(readerAdvConfigProvider)?.selectVibrator ?? false) {
      HapticFeedback.selectionClick();
    }
    final overlay = Overlay.of(context, rootOverlay: true);
    late OverlayEntry entry;
    var dismissed = false;
    void dismiss() {
      if (dismissed) return;
      dismissed = true;
      entry.remove();
    }

    entry = OverlayEntry(
      builder: (overlayContext) {
        final expanded =
            container.read(readerAdvConfigProvider)?.expandTextMenu ?? false;
        final screen = MediaQuery.sizeOf(overlayContext);
        return Stack(
          children: [
            // 点击屏障：任意点按收起浮条
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: dismiss,
                child: const SizedBox.expand(),
              ),
            ),
            // [审查 P2-2/P2-3] 统一由布局代理双向 clamp：窄屏下
            // `width-342` 可能小于 12，底部锚点也可能让菜单越界。
            CustomSingleChildLayout(
              delegate: _ReaderToolbarLayoutDelegate(
                anchor: anchor,
                expanded: expanded,
                screenSize: screen,
              ),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(12),
                color: Theme.of(
                  overlayContext,
                ).colorScheme.surfaceContainerHighest,
                child: ReaderSelectionToolbar(
                  anchor: anchor,
                  text: text,
                  chapterPos: chapterPos,
                  onDismiss: dismiss,
                ),
              ),
            ),
          ],
        );
      },
    );
    overlay.insert(entry);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cfg = ref.watch(readerAdvConfigProvider) ?? ReaderAdvancedConfig();
    final view = SelectionMenuConfig.decode(cfg.textSelectMenuConfig).view;
    final items = cfg.expandTextMenu ? view.active : view.primary;
    final buttons = [
      for (final def in items)
        _buildActionButton(
          context,
          def,
          showIcon: cfg.showSelectMenuIcon,
          onTap: _actionFor(context, ref, def.id),
        ),
    ];
    final manage = IconButton(
      key: const ValueKey('selection-menu-manage'),
      tooltip: '管理选择菜单',
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.settings_outlined, size: 20),
      onPressed: () {
        // [设备验收 P2] 不能在 onDismiss 后继续使用浮条的 WidgetRef；
        // 先取稳定 Navigator 与 ProviderContainer，再关闭浮条并打开 Sheet。
        final navigator = Navigator.of(context, rootNavigator: true);
        final container = ProviderScope.containerOf(context, listen: false);
        onDismiss();
        unawaited(
          TextSelectMenuConfigSheet.showForReader(navigator.context, container),
        );
      },
    );
    final screen = MediaQuery.sizeOf(context);
    final divider = SizedBox(
      height: 24,
      child: VerticalDivider(
        width: 1,
        color: Theme.of(context).colorScheme.outlineVariant,
      ),
    );
    if (cfg.expandTextMenu) {
      // [审查 P2-2] 参考 MultiLineMenuView 的 heightIn(max=300) +
      // verticalScroll；这里按窗口高度封顶并允许纵向滚动，屏底锚点
      // 由布局代理上移，首行与管理按钮仍可达。
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(0, screen.width - 24),
          maxHeight: math.max(0, screen.height - 24),
        ),
        child: SingleChildScrollView(
          key: const ValueKey('selection-expanded-scroll'),
          padding: const EdgeInsets.all(4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [...buttons, manage],
          ),
        ),
      );
    }
    // [审查 P2-1] 一级动作可横向滚动；分隔线、更多、管理固定在
    // 滚动区外，360dp 默认 10 项时仍可点击并进入折叠组。
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: math.max(0, screen.width - 24)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              key: const ValueKey('selection-actions-scroll'),
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < buttons.length; i++) ...[
                    if (i > 0) divider,
                    buttons[i],
                  ],
                ],
              ),
            ),
          ),
          divider,
          _buildActionButton(
            context,
            const SelectionMenuItemDef(
              id: 'menu_more',
              label: '更多',
              icon: Icons.more_horiz,
              implemented: true,
            ),
            showIcon: cfg.showSelectMenuIcon,
            onTap: () {
              onDismiss();
              TextSelectionPanel.show(
                context,
                text: text,
                chapterPos: chapterPos,
              );
            },
          ),
          manage,
        ],
      ),
    );
  }

  VoidCallback _actionFor(BuildContext context, WidgetRef ref, String id) {
    switch (id) {
      case SelectionMenuIds.copy:
        return () => unawaited(selectionCopy(context, text, onDismiss));
      case SelectionMenuIds.share:
        return () => unawaited(selectionShare(context, text, onDismiss));
      case SelectionMenuIds.browser:
        return () => unawaited(selectionOpenBrowser(context, text, onDismiss));
      case SelectionMenuIds.aloud:
        return () => unawaited(
          selectionReadAloud(
            ref,
            context,
            selectedText: text,
            paragraphText: text,
            chapterPos: chapterPos,
            onDone: onDismiss,
          ),
        );
      case SelectionMenuIds.bookmark:
        return () => unawaited(
          selectionAddBookmark(
            ref,
            context,
            selectedText: text,
            chapterPos: chapterPos,
            onDone: onDismiss,
          ),
        );
      case SelectionMenuIds.mark:
        return () => unawaited(
          openMarkingForSelection(
            context,
            ref,
            paragraphText: text,
            chapterPos: chapterPos,
            selectedText: text.trim(),
            fineSelection: false,
            onBeforeOpen: onDismiss,
          ),
        );
      case SelectionMenuIds.dict:
        return () => selectionLookupDict(context, text, onDismiss);
      case SelectionMenuIds.replace:
        return () => selectionReplace(context, text, onDismiss);
      case SelectionMenuIds.edit:
        return () => selectionEdit(ref, context, onDismiss);
      case SelectionMenuIds.search:
        return () => selectionSearchContent(ref, context, text, onDismiss);
      default:
        return () {};
    }
  }

  Widget _buildActionButton(
    BuildContext context,
    SelectionMenuItemDef def, {
    required bool showIcon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: ValueKey('selection-action-${def.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showIcon) ...[
              Icon(
                def.icon,
                size: 22,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 4),
            ],
            Text(def.label, style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}

/// 浮条定位：水平方向贴近锚点并限制在 12dp 安全边距内，
/// 垂直方向在屏底时整体上移，避免多行菜单或大字号越界。
class _ReaderToolbarLayoutDelegate extends SingleChildLayoutDelegate {
  final Offset anchor;
  final bool expanded;
  final Size screenSize;

  const _ReaderToolbarLayoutDelegate({
    required this.anchor,
    required this.expanded,
    required this.screenSize,
  });

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.min(screenSize.width, constraints.maxWidth);
    return BoxConstraints(
      maxWidth: math.max(0, width - 24),
      maxHeight: math.max(0, screenSize.height - 24),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final maxLeft = math.max(12.0, size.width - childSize.width - 12);
    final left = expanded
        ? 12.0
        // [审查 P2-3] 320dp 下 width-342 小于下界，先保证上界不小于 12。
        : (anchor.dx - 150).clamp(12.0, maxLeft).toDouble();
    final maxTop = math.max(12.0, size.height - childSize.height - 12);
    final top = (anchor.dy - 64).clamp(12.0, maxTop).toDouble();
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(covariant _ReaderToolbarLayoutDelegate oldDelegate) =>
      anchor != oldDelegate.anchor ||
      expanded != oldDelegate.expanded ||
      screenSize != oldDelegate.screenSize;
}
