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
import '../../providers/dict/dict_notifier.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';

/// 高亮配色（对齐原版 HighlightStyle 多色能力，颜色写入 BookHighlight.style JSON）
const List<Color> kHighlightColors = [
  Color(0xFFFFE082), // 琥珀
  Color(0xFFA5D6A7), // 绿
  Color(0xFF90CAF9), // 蓝
  Color(0xFFF48FB1), // 粉
  Color(0xFFFFCC80), // 橙
];

/// 正文长按选择操作面板
///
/// 对标原版 TextActionMenu 的菜单项清单（顺序对齐 content_select_action.xml）。
// [UI-fix v2.0.1 | 2026-08-06] 新建长按操作面板 — Qoder
class TextSelectionPanel extends ConsumerStatefulWidget {
  /// 长按命中的段落全文（默认操作文本）
  final String text;

  /// 段落在章节正文中的起始字符偏移（ParagraphInfo.startIndex，可为 0）
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
      builder: (_) => TextSelectionPanel(text: text, chapterPos: chapterPos),
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
  bool _showHighlightColors = false;

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
            // 操作菜单（顺序对齐原版 content_select_action.xml）
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _actionItem(Icons.swap_horiz, '替换', _openReplace),
                  _actionItem(Icons.copy_outlined, '复制', _copy),
                  _actionItem(Icons.bookmark_border, '书签', _addBookmark),
                  _actionItem(
                    Icons.highlight_outlined,
                    '高亮',
                    () => setState(
                      () => _showHighlightColors = !_showHighlightColors,
                    ),
                  ),
                  _actionItem(Icons.record_voice_over_outlined, '朗读', _readAloud),
                  _actionItem(Icons.menu_book_outlined, '词典', _lookupDict),
                  _actionItem(Icons.search, '搜正文', _searchContent),
                  _actionItem(
                      Icons.open_in_browser_outlined, '浏览器', _openInBrowser),
                  _actionItem(Icons.share_outlined, '分享', _share),
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
                                onTap: () => _saveHighlight(color),
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

  Widget _actionItem(IconData icon, String label, VoidCallback onTap) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: theme.colorScheme.primary),
            const SizedBox(height: 4),
            Text(label, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
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

  /// 高亮：对齐原版 menu_highlight → createHighlight + ReadBook.addHighlight
  ///
  /// BookHighlight JSON 字段对齐 API_CONTRACT.md §2.36（DB v99 highlights 表）。
  Future<void> _saveHighlight(Color color) async {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) {
      _toast('无法添加高亮：未打开书籍');
      return;
    }
    final chapter = state.currentChapter;
    final selected = _selectedText;
    final highlight = <String, dynamic>{
      'time': 0, // 0 时由 Rust 侧自动分配主键
      'bookUrl': book.bookUrl,
      'chapterUrl': chapter?.url ?? '',
      'bookName': book.name,
      'bookAuthor': book.author,
      'chapterIndex': state.currentChapterIndex,
      'chapterPos': widget.chapterPos,
      'chapterPosEnd': widget.chapterPos + selected.length,
      'layoutTitleLength': 0,
      'chapterName': chapter?.title ?? '',
      'bookText': selected,
      'style': jsonEncode({
        'type': 'background',
        'color':
            '#${color.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}',
      }),
      'note': '',
    };
    try {
      await ref
          .read(bookApiProvider)
          .highlightAdd(highlightJson: jsonEncode(highlight));
      _lastHighlightColor = color;
      _toast('已添加高亮');
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
            // 分页排版下 ParagraphInfo.startIndex 恒 0，段落文本匹配兜底定位
            startParagraphText: widget.text,
          ),
    );
  }

  /// 词典：对齐原版 menu_dict → DictDialog(selectedText)
  ///
  /// 复用现有 DictScreen + DictNotifier（查询经 BookApi.dictLookup 委托 Rust）。
  void _lookupDict() {
    final word = _selectedText.trim();
    if (word.isEmpty) return;
    unawaited(ref.read(dictNotifierProvider.notifier).lookup(word));
    final navigator = Navigator.of(context, rootNavigator: true);
    _close();
    navigator.pushNamed(AppRoutes.dict);
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
