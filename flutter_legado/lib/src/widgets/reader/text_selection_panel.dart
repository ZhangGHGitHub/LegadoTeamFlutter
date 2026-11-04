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


import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../providers/audio/audio_notifier.dart';
import '../../providers/bookmark/bookmark_notifier.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/reader_config_panel.dart';
import '../../models/selection_menu_config.dart';
import '../dict_dialog.dart';
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

  /// [批4c] menu_mark 从浮条进入时直接展开高亮颜色行
  final bool initialHighlight;

  const TextSelectionPanel({
    super.key,
    required this.text,
    this.chapterPos = 0,
    this.initialHighlight = false,
  });

  /// 弹出面板
  static Future<void> show(
    BuildContext context, {
    required String text,
    int chapterPos = 0,
    bool initialHighlight = false,
  }) {
    if (text.trim().isEmpty) return Future.value();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TextSelectionPanel(
        text: text,
        chapterPos: chapterPos,
        initialHighlight: initialHighlight,
      ),
    );
  }

  @override
  ConsumerState<TextSelectionPanel> createState() =>
      _TextSelectionPanelState();
}

class _TextSelectionPanelState extends ConsumerState<TextSelectionPanel> {
  /// 用户通过原生选区手柄选中的文本（空表示未精细选择，回退整段）
  String _userSelected = '';

  /// 是否展开高亮配色行
  late bool _showHighlightColors = widget.initialHighlight;

  /// 上次使用的高亮颜色（会话内记忆，对齐原版 highlightLastStyle 的简化版）
  static Color _lastHighlightColor = kHighlightColors.first;

  /// 当前操作文本：优先取用户选区，未选择时为整段
  String get _selectedText {
    final selected = _userSelected.trim();
    return selected.isEmpty ? widget.text.trim() : selected;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfg = ref.watch(readerAdvConfigProvider) ?? ReaderAdvancedConfig();
    final menuView = SelectionMenuConfig.decode(
      cfg.textSelectMenuConfig,
    ).view;
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
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_selectedText.length} 字',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const Spacer(),
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
                color: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
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
                      final text = widget.text;
                      if (!selection.isValid || selection.isCollapsed) {
                        if (_userSelected.isNotEmpty) {
                          setState(() => _userSelected = '');
                        }
                        return;
                      }
                      final start = selection.start.clamp(0, text.length);
                      final end = selection.end.clamp(0, text.length);
                      setState(() => _userSelected = text.substring(start, end));
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '提示：长按上方文本可精细调整选区，未选择时默认操作整段',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 8),
            // 操作菜单（批4c：按选择菜单配置排序/分区）
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final def in menuView.active)
                    _actionItem(
                      def,
                      showIcon: cfg.showSelectMenuIcon,
                      onTap: _panelAction(def.id),
                    ),
                  IconButton(
                    key: const ValueKey('selection-panel-manage'),
                    tooltip: '管理选择菜单',
                    icon: const Icon(Icons.settings_outlined, size: 20),
                    onPressed: () =>
                        unawaited(TextSelectMenuConfigSheet.showForReader(
                          context,
                          ref,
                        )),
                  ),
                ],
              ),
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
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline),
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
                                      width: color == _lastHighlightColor ? 2.5 : 1,
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
    switch (id) {
      case SelectionMenuIds.copy:
        return () => unawaited(_copy());
      case SelectionMenuIds.share:
        return () => unawaited(_share());
      case SelectionMenuIds.browser:
        return () => unawaited(_openInBrowser());
      case SelectionMenuIds.aloud:
        return _readAloud;
      case SelectionMenuIds.bookmark:
        return () => unawaited(_addBookmark());
      case SelectionMenuIds.mark:
        return () => setState(
          () => _showHighlightColors = !_showHighlightColors,
        );
      case SelectionMenuIds.dict:
        return _lookupDict;
      case SelectionMenuIds.replace:
        return _openReplace;
      case SelectionMenuIds.edit:
        return () => selectionEdit(ref, context, _close);
      case SelectionMenuIds.search:
        return _searchContent;
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

  /// 替换：原版以选中文本为替换 pattern 打开 ReplaceEditActivity
  void _openReplace() {
    // [UI-fix v2.0.2 | 2026-08-06] 闭合留批次项：选中文本作为替换规则
    // pattern 预填传入规则管理页（对标原版 ReplaceEditActivity 预填） — Qoder
    _close();
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pushNamed(AppRoutes.replaceRules, arguments: _selectedText);
  }

  /// 复制：对齐原版 menu_copy → sendToClip
  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _selectedText));
    _toast('已复制到剪贴板');
    _close();
  }

  /// 书签：对齐原版 menu_bookmark → createBookmark + BookmarkDialog
  Future<void> _addBookmark() async {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) {
      _toast('无法添加书签：未打开书籍');
      return;
    }
    try {
      await ref.read(bookmarkNotifierProvider.notifier).addBookmark(
            bookName: book.name,
            bookAuthor: book.author,
            chapterIndex: state.currentChapterIndex,
            chapterPos: widget.chapterPos,
            chapterName: state.currentChapter?.title ?? '',
            bookText: _selectedText,
            content: _selectedText,
          );
      _toast('已添加书签');
      _close();
    } catch (e) {
      _toast('添加书签失败：$e');
    }
  }

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
                decoration: const InputDecoration(
                  labelText: '笔记（可选）',
                ),
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

  /// 朗读所选：对齐原版 menu_aloud → speak(selectedText)
  void _readAloud() {
    // [UI-fix v2.0.2 | 2026-08-06] 闭合留批次项：接朗读链路
    // （AudioNotifier.startReadAloud → audioSpeak FFI）。
    // [UI-fix v2.0.3 | 2026-08-08] 留项4 闭合：传入选区起始 chapterPos，
    // 由 AudioNotifier 映射段落索引实现段落级起播（对标原版从选中文本
    // 位置起读的行为） — Qoder
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) {
      _toast('无法启动朗读：未打开书籍');
      return;
    }
    final chapterIndex = state.currentChapterIndex;
    _close();
    unawaited(
      ref.read(audioNotifierProvider.notifier).startReadAloud(
            bookUrl: book.bookUrl,
            bookName: book.name,
            chapterIndex: chapterIndex,
            startChapterPos: widget.chapterPos,
            // [批34] ParagraphInfo.startIndex 已改为章节全局偏移（不再是
            // 恒 0），段落文本仍作等值校验/兜底定位 — full-stack-engineer
            startParagraphText: widget.text,
          ),
    );
  }

  /// 词典：对齐原版 menu_dict → DictDialog(selectedText)
  void _lookupDict() {
    final word = _selectedText.trim();
    if (word.isEmpty) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final ctx = navigator.context;
    _close();
    unawaited(showDictDialog(ctx, word: word));
  }

  /// 搜正文：对齐原版 menu_search_content → openSearchActivity(selectedText)
  void _searchContent() {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) {
      _toast('无法搜正文：未打开书籍');
      return;
    }
    // [UI-fix v2.0.2 | 2026-08-06] 闭合留批次项：选中文本作为初始查询词
    // 传入正文搜索页（对标原版 viewModel.searchContentQuery） — Qoder
    final navigator = Navigator.of(context, rootNavigator: true);
    _close();
    navigator.pushNamed(
      AppRoutes.searchContent,
      arguments: {'book': book, 'query': _selectedText},
    );
  }

  /// 浏览器：对齐原版 menu_browser（绝对 URL 直接打开，否则网页搜索）
  Future<void> _openInBrowser() async {
    final text = _selectedText.trim();
    if (text.isEmpty) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    _close();
    if (RegExp(r'^https?://\S+$').hasMatch(text)) {
      // 应用内置浏览器（对齐原版 ACTION_VIEW）
      navigator.pushNamed(AppRoutes.browser, arguments: text);
      return;
    }
    // 网页搜索（对齐原版 ACTION_WEB_SEARCH）
    final uri = Uri.https('www.bing.com', '/search', {'q': text});
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        _toast('无法打开浏览器');
      }
    } catch (e) {
      _toast('打开浏览器失败：$e');
    }
  }

  /// 分享：对齐原版 menu_share_str → share(selectedText)
  Future<void> _share() async {
    final text = _selectedText;
    _close();
    try {
      await Share.share(text);
    } catch (e) {
      _toast('分享失败：$e');
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
      builder: (_) => Stack(
        children: [
          // 点击屏障：任意点按收起浮条
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dismiss,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned(
            left: container.read(readerAdvConfigProvider)?.expandTextMenu == true
                ? 12
                : (anchor.dx - 150).clamp(
                    12.0,
                    MediaQuery.of(context).size.width - 342,
                  ),
            top: (anchor.dy - 64).clamp(12.0, double.infinity),
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(12),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ReaderSelectionToolbar(
                anchor: anchor,
                text: text,
                chapterPos: chapterPos,
                onDismiss: dismiss,
              ),
            ),
          ),
        ],
      ),
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
        onDismiss();
        unawaited(TextSelectMenuConfigSheet.showForReader(context, ref));
      },
    );
    if (cfg.expandTextMenu) {
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width - 24,
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [...buttons, manage],
          ),
        ),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width - 24,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < buttons.length; i++) ...[
              if (i > 0)
                SizedBox(
                  height: 24,
                  child: VerticalDivider(
                    width: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              buttons[i],
            ],
            if (buttons.isNotEmpty)
              SizedBox(
                height: 24,
                child: VerticalDivider(
                  width: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
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
        return () {
          onDismiss();
          TextSelectionPanel.show(
            context,
            text: text,
            chapterPos: chapterPos,
            initialHighlight: true,
          );
        };
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
