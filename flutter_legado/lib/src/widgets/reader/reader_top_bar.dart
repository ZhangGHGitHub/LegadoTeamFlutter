import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../models/book.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import 'reader_settings_sheet.dart';

/// 阅读器顶部工具栏
///
/// 对齐安卓原版 ReadMenu 顶部 TitleBar 与 book_read.xml 菜单：
/// 返回键 + 书名 + 阅读进度百分比 + 换源/刷新/缓存（在线书）
/// + 夜间模式 + 正文搜索 + 书签 + 溢出菜单（高级设置等）
class ReaderTopBar extends ConsumerWidget {
  final VoidCallback onOpenContentSearch;
  final VoidCallback onAddBookmark;
  final VoidCallback onOpenAdvancedConfig;

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批消费点 — Qoder

  /// 显示标题附加区（书名后追加章名，对标原版 showReadTitleAddition）
  final bool showTitleAddition;

  /// 工具栏样式跟随阅读页（对标原版 readBarStyleFollowPage/immersiveMenu）
  final bool styleFollowPage;

  const ReaderTopBar({
    super.key,
    required this.onOpenContentSearch,
    required this.onAddBookmark,
    required this.onOpenAdvancedConfig,
    this.showTitleAddition = true,
    this.styleFollowPage = false,
  });

  // ===== [UI-fix v2.0.2 | 2026-08-06] 溢出菜单去存根（对标原版
  // ReadBookActivity 菜单 handler） — Qoder =====

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 切换书籍 ReadConfig 字段并持久化，随后重载当前章正文
  Future<void> _updateBookConfig(
    BuildContext context,
    WidgetRef ref,
    ReadConfig Function(ReadConfig config) transform,
  ) async {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    final updated =
        book.copyWith(readConfig: transform(book.readConfig ?? const ReadConfig()));
    try {
      await ref.read(bookApiProvider).updateBook(updated);
      final notifier = ref.read(readerNotifierProvider.notifier);
      notifier.updateCurrentBook(updated);
      await notifier.reloadChapterContent();
    } catch (e) {
      if (context.mounted) _snack(context, '设置保存失败: $e');
    }
  }

  /// 替换规则开关（对标原版 menu_enable_replace）
  void _toggleReplaceRule(BuildContext context, WidgetRef ref) {
    final book = ref.read(readerNotifierProvider).currentBook;
    final enabled = book?.readConfig?.useReplaceRule ?? true;
    unawaited(_updateBookConfig(
      context,
      ref,
      (c) => c.copyWith(useReplaceRule: !enabled),
    ));
    if (context.mounted) {
      _snack(context, enabled ? '已关闭替换规则' : '已开启替换规则');
    }
  }

  /// 重新分段开关（对标原版 menu_re_segment）
  void _toggleReSegment(BuildContext context, WidgetRef ref) {
    final book = ref.read(readerNotifierProvider).currentBook;
    final enabled = book?.readConfig?.reSegment ?? false;
    unawaited(_updateBookConfig(
      context,
      ref,
      (c) => c.copyWith(reSegment: !enabled),
    ));
    if (context.mounted) {
      _snack(context, enabled ? '已关闭重新分段' : '已开启重新分段');
    }
  }

  /// 图片样式选择（对标原版 menu_image_style：default/full/text/single）
  void _showImageStyleDialog(BuildContext context, WidgetRef ref) {
    final current =
        ref.read(readerNotifierProvider).currentBook?.readConfig?.imageStyle;
    const options = <String?, String>{
      null: '默认（文字旁显示图片）',
      'full': '图片铺满宽度',
      'text': '仅显示文字',
      'single': '单独成页显示图片',
    };
    showDialog<void>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('图片样式'),
        children: [
          for (final entry in options.entries)
            RadioListTile<String?>(
              title: Text(entry.value),
              value: entry.key,
              groupValue: current,
              onChanged: (v) {
                Navigator.pop(dialogContext);
                if (v != current) {
                  unawaited(_updateBookConfig(
                    context,
                    ref,
                    (c) => c.copyWith(imageStyle: v),
                  ));
                }
              },
            ),
        ],
      ),
    );
  }

  /// 更新目录（对标原版 menu_update_toc → refreshToc FFI）
  Future<void> _updateToc(BuildContext context, WidgetRef ref) async {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    if (book.origin == BookType.localTag) {
      _snack(context, '本地书籍无需更新目录');
      return;
    }
    _snack(context, '正在更新目录…');
    try {
      await ref.read(bookApiProvider).refreshToc(book.bookUrl, book.origin);
      await ref.read(readerNotifierProvider.notifier).openBook(book);
      if (context.mounted) _snack(context, '目录已更新');
    } catch (e) {
      if (context.mounted) _snack(context, '更新目录失败: $e');
    }
  }

  /// 模拟追读（对标原版 showSimulatedReading：readSimulating/startChapter/
  /// dailyChapters/startDate）
  void _showSimulatedReadingDialog(BuildContext context, WidgetRef ref) {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    final cfg = book.readConfig ?? const ReadConfig();
    var simulating = cfg.readSimulating;
    final startCtrl =
        TextEditingController(text: '${cfg.startChapter ?? book.durChapterIndex}');
    final dailyCtrl = TextEditingController(text: '${cfg.dailyChapters}');

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('模拟追读'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用模拟追读'),
                subtitle: const Text('按日逐步释放章节，模拟追更体验'),
                value: simulating,
                onChanged: (v) => setDialogState(() => simulating = v),
              ),
              TextField(
                controller: startCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '起始章节序号'),
              ),
              TextField(
                controller: dailyCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '每日更新章数'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                final start = int.tryParse(startCtrl.text) ?? book.durChapterIndex;
                final daily = (int.tryParse(dailyCtrl.text) ?? 3).clamp(1, 100);
                unawaited(_updateBookConfig(
                  context,
                  ref,
                  (c) => c.copyWith(
                    readSimulating: simulating,
                    startChapter: start,
                    dailyChapters: daily,
                    // 启用时记录起始日期（原版 startDate 用于按日推算可见章节）
                    startDate: simulating
                        ? DateTime.now().toIso8601String().substring(0, 10)
                        : c.startDate,
                  ),
                ));
                _snack(context, simulating ? '已开启模拟追读' : '已关闭模拟追读');
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 编辑章节内容（对标原版 EditContentDialog：可编辑正文，保存经
  /// saveChapterContent FFI 持久化后重载当前章）
  void _showEditContentDialog(BuildContext context, WidgetRef ref) {
    final state = ref.read(readerNotifierProvider);
    final chapter = state.currentChapter;
    final ctrl = TextEditingController(text: state.chapterContent);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(chapter != null ? '编辑：${chapter.title}' : '编辑内容'),
        content: SizedBox(
          width: double.maxFinite,
          child: TextField(
            controller: ctrl,
            maxLines: null,
            minLines: 12,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              // [UI-fix v2.0.3 | 2026-08-08] 保存接线（对标原版
              // saveContent → BookHelp.saveText + loadContent） — Qoder
              unawaited(_saveEditedContent(context, ref, ctrl.text));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // [UI-fix v2.0.3 | 2026-08-08] 编辑内容保存闭环：saveChapterContent
  // FFI（契约 §2.43.1）写回缓存后重载当前章正文 — Qoder
  Future<void> _saveEditedContent(
    BuildContext context,
    WidgetRef ref,
    String content,
  ) async {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) return;
    try {
      final ok = await ref.read(bookApiProvider).saveChapterContent(
            bookUrl: book.bookUrl,
            chapterIndex: state.currentChapterIndex,
            title: state.currentChapter?.title ?? '',
            content: content,
          );
      if (!context.mounted) return;
      if (ok) {
        await ref.read(readerNotifierProvider.notifier).reloadChapterContent();
        if (context.mounted) _snack(context, '章节内容已保存');
      } else {
        _snack(context, '章节内容保存失败');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '章节内容保存失败: $e');
    }
  }

  /// 反转内容（对标原版 ReadBookViewModel.reverseContent L447-459：
  /// toStringArray（StringExtensions L143，按码点拆单字符）逐个 insert(0)
  /// 即整串码点级倒序，随后 saveText 写回并 loadContent 重载）
  // [UI-fix v2.0.3 | 2026-08-08] 反转内容闭环：先取正文（无缓存时经
  // getChapterContentFull 联网取，避免空转）→ runes 倒序 → saveChapterContent
  // 写回 → 重载当前章 — Qoder
  Future<void> _reverseContent(BuildContext context, WidgetRef ref) async {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) return;
    final chapterIndex = state.currentChapterIndex;
    try {
      final content = await ref
          .read(bookApiProvider)
          .getChapterContentFull(book.bookUrl, chapterIndex);
      if (content.isEmpty) {
        if (context.mounted) _snack(context, '暂无正文可反转');
        return;
      }
      // 码点级倒序（runes 反转保证 emoji 等补充平面字符安全）
      final reversed = String.fromCharCodes(content.runes.toList().reversed);
      final ok = await ref.read(bookApiProvider).saveChapterContent(
            bookUrl: book.bookUrl,
            chapterIndex: chapterIndex,
            title: state.currentChapter?.title ?? '',
            content: reversed,
          );
      if (!context.mounted) return;
      if (ok) {
        await ref.read(readerNotifierProvider.notifier).reloadChapterContent();
        if (context.mounted) _snack(context, '内容已反转');
      } else {
        _snack(context, '反转内容保存失败');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '反转内容失败: $e');
    }
  }

  // [UI-fix v2.0.3 | 2026-08-06] 设置编码（对标原版 menu_set_charset →
  // BaseReadBookActivity.showCharsetConfig → ReadBook.setCharset：
  // 写入 book.charset 并重载章节，本地书乱码时按指定编码重读） — Qoder

  /// 常用编码候选（对标原版 AppConst.charsets）
  static const List<String> _charsets = [
    'UTF-8', 'GB2312', 'GB18030', 'GBK',
    'Unicode', 'UTF-16', 'UTF-16LE', 'ASCII',
  ];

  /// 设置编码对话框（对标原版 showCharsetConfig）
  void _showCharsetDialog(BuildContext context, WidgetRef ref) {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    final ctrl = TextEditingController(text: book.charset ?? '');

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('设置编码'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(
                  labelText: 'charset',
                  hintText: '如 UTF-8 / GBK',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final cs in _charsets)
                    ChoiceChip(
                      label: Text(cs),
                      selected: ctrl.text == cs,
                      onSelected: (_) =>
                          setDialogState(() => ctrl.text = cs),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final charset = ctrl.text.trim();
                Navigator.pop(dialogContext);
                if (charset.isEmpty) {
                  _snack(context, '编码不能为空');
                  return;
                }
                unawaited(_applyCharset(context, ref, charset));
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 持久化 charset 并重载当前章正文（对标 ReadBook.setCharset）
  Future<void> _applyCharset(
    BuildContext context,
    WidgetRef ref,
    String charset,
  ) async {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    final updated = book.copyWith(charset: charset);
    try {
      await ref.read(bookApiProvider).updateBook(updated);
      final notifier = ref.read(readerNotifierProvider.notifier);
      notifier.updateCurrentBook(updated);
      await notifier.reloadChapterContent();
      if (context.mounted) _snack(context, '已设置编码：$charset');
    } catch (e) {
      if (context.mounted) _snack(context, '设置编码失败: $e');
    }
  }

  /// 帮助对话框（对标原版 menu_help）
  void _showHelpDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('阅读器帮助'),
        content: const SingleChildScrollView(
          child: Text(
            '• 点击屏幕中央可显示/隐藏工具栏\n'
            '• 顶栏：换源、刷新、缓存、夜间模式、搜索、书签、更多菜单\n'
            '• 底栏：目录、夜间、设置、朗读、源操作\n'
            '• 左右滑动或点击两侧区域翻页\n'
            '• 长按正文可选择文本（复制/搜索/替换/朗读等）\n'
            '• 高级设置：翻页模式/自动翻页/点击区域/字体与排版\n'
            '• 遇到问题可在“更多→日志”查看运行日志',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 离线缓存对话框（对标原版 CacheActivity/showDownloadDialog：
  /// 选择起止章节 → downloadAddTask 逐章加入下载队列）
  void _showCacheDialog(BuildContext context, WidgetRef ref) {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    final chapters = state.chapters;
    if (book == null || chapters.isEmpty) return;
    if (book.origin == BookType.localTag) {
      _snack(context, '本地书籍无需缓存');
      return;
    }
    final startCtrl = TextEditingController(text: '${book.durChapterIndex + 2}');
    final endCtrl = TextEditingController(text: '${chapters.length}');

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('缓存后续章节'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: startCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '起始章节序号'),
            ),
            TextField(
              controller: endCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: '结束章节序号（共 ${chapters.length} 章）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final start = int.tryParse(startCtrl.text) ?? 1;
              final end = int.tryParse(endCtrl.text) ?? chapters.length;
              if (start < 1 || end > chapters.length || start > end) {
                _snack(context, '章节范围无效');
                return;
              }
              final api = ref.read(bookApiProvider);
              var count = 0;
              for (var i = start - 1; i <= end - 1; i++) {
                final ch = chapters[i];
                try {
                  await api.downloadAddTask(
                    bookUrl: book.bookUrl,
                    chapterUrl: ch.url,
                    chapterTitle: ch.title,
                    chapterIndex: i,
                  );
                  count++;
                } catch (_) {
                  // 单章失败不阻断整体缓存任务
                }
              }
              if (context.mounted) {
                _snack(context, '已加入缓存队列：$count 章');
              }
            },
            child: const Text('开始缓存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final isDark = state.isDarkBackground;
    final progressPct = (state.readingProgress * 100).toStringAsFixed(1);

    // [UI-fix v2.0.3 | 2026-08-08] 工具栏跟随页面：背景/前景色跟随当前
    // 阅读页配色（对标原版 ReadMenu immersiveMenu：bgColor=页面背景、
    // textColor=页面文字色）；关闭时维持主题 surface — Qoder
    final followColor = styleFollowPage ? state.backgroundColor : null;
    final foreground = styleFollowPage ? state.textColor : null;
    // [UI-fix v2.0.3 | 2026-08-08] 标题附加区：书名 · 章名（对标原版
    // showReadTitleAddition 开启时菜单顶栏显示章名）— Qoder
    final chapterTitle = state.currentChapter?.title ?? '';
    final titleText = (showTitleAddition && chapterTitle.isNotEmpty)
        ? '${state.currentBook?.name ?? ''} · $chapterTitle'
        : (state.currentBook?.name ?? '');

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Material(
        color: followColor ?? Theme.of(context).colorScheme.surface,
        // iOS 风格：无阴影 + hairline 底边
        elevation: 0,
        shape: Border(
          bottom: BorderSide(
            color: styleFollowPage
                ? state.textColor.withValues(alpha: 0.2)
                : (Theme.of(context).dividerTheme.color ??
                    Theme.of(context).dividerColor),
            width: 0.0,
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: IconTheme(
            // 跟随页面时图标前景色改用页面文字色
            data: IconThemeData(color: foreground),
            child: SizedBox(
            height: kToolbarHeight,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    titleText,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: foreground,
                        ),
                  ),
                ),
                // 阅读进度百分比
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    '$progressPct%',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                          color: styleFollowPage
                              ? state.textColor
                              : Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                // [UI-fix v2.0.3 | 2026-08-06] 顶栏图标过多致 RIGHT OVERFLOWED，
                // 将换源/刷新/缓存（原 menu_group_on_line 三枚 IconButton）收入溢出
                // 菜单，顶栏仅保留高频的夜间/搜索/书签，Row 不再溢出（对标 iOS 精简导航栏） — Qoder
                // 夜间模式快速切换
                IconButton(
                  icon: Icon(
                    isDark ? Icons.light_mode : Icons.dark_mode,
                  ),
                  tooltip: isDark ? '日间模式' : '夜间模式',
                  onPressed: () {
                    notifier.updateBackgroundColor(
                      isDark ? ReaderBackground.white : ReaderBackground.dark,
                    );
                  },
                ),
                // 正文搜索
                IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索正文',
                  onPressed: onOpenContentSearch,
                ),
                // 书签按钮
                IconButton(
                  icon: const Icon(Icons.bookmark_add_outlined),
                  tooltip: '添加书签',
                  onPressed: onAddBookmark,
                ),
                // 安卓原版：溢出菜单（book_read.xml never 项）
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) async {
                    switch (value) {
                      // [UI-fix v2.0.3 | 2026-08-06] 换源/刷新/缓存由顶栏
                      // IconButton 迁入溢出菜单（修复顶栏溢出） — Qoder
                      case 'changeSource':
                        Navigator.pushNamed(
                          context,
                          AppRoutes.changeSource,
                          arguments: state.currentBook,
                        );
                        break;
                      case 'refreshBook':
                        final book = state.currentBook;
                        if (book != null) {
                          await notifier.openBook(book);
                          if (context.mounted) _snack(context, '已刷新');
                        }
                        break;
                      case 'cache':
                        _showCacheDialog(context, ref);
                        break;
                      case 'advanced':
                        onOpenAdvancedConfig();
                        break;
                      case 'highlightRule':
                        // 对标原版 ReadMenu → HighlightRuleActivity
                        Navigator.pushNamed(context, AppRoutes.highlightRules);
                        break;
                      case 'pageAnim':
                        // [UI-fix v2.0.1 | 2026-08-06] 翻页动画接阅读设置面板
                        // （面板内含翻页模式设置，对标原版 ReadStyleDialog） — Qoder
                        ReaderSettingsSheet.show(context);
                        break;
                      case 'log':
                        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
                        Navigator.pushNamed(context, AppRoutes.appLog);
                        break;
                      // [UI-fix v2.0.2 | 2026-08-06] 以下菜单项去存根，
                      // 逐项对标原版 ReadBookActivity — Qoder
                      case 'editContent':
                        _showEditContentDialog(context, ref);
                        break;
                      case 'reverseContent':
                        unawaited(_reverseContent(context, ref));
                        break;
                      case 'simulatedReading':
                        _showSimulatedReadingDialog(context, ref);
                        break;
                      case 'enableReplace':
                        _toggleReplaceRule(context, ref);
                        break;
                      case 'reSegment':
                        _toggleReSegment(context, ref);
                        break;
                      case 'imageStyle':
                        _showImageStyleDialog(context, ref);
                        break;
                      case 'setCharset':
                        // [UI-fix v2.0.3 | 2026-08-06] 设置编码接通 — Qoder
                        _showCharsetDialog(context, ref);
                        break;
                      case 'updateToc':
                        unawaited(_updateToc(context, ref));
                        break;
                      case 'help':
                        _showHelpDialog(context);
                        break;
                    }
                  },
                  itemBuilder: (_) {
                    // [UI-fix v2.0.2 | 2026-08-06] 替换规则/重新分段以勾选
                    // 样式展示当前启用状态（对标原版 checkable 菜单项） — Qoder
                    final book = ref.read(readerNotifierProvider).currentBook;
                    final replaceOn = book?.readConfig?.useReplaceRule ?? true;
                    final segmentOn = book?.readConfig?.reSegment ?? false;
                    // 在线书才显示换源/刷新/缓存（对标原版 menu_group_on_line）
                    final isOnline = book != null &&
                        book.origin != BookType.localTag &&
                        !book.origin.startsWith(BookType.webDavTag);
                    Widget checked(String text, bool on) => Row(
                          children: [
                            if (on) ...[
                              Icon(Icons.check, size: 16,
                                  color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 6),
                            ],
                            Text(text),
                          ],
                        );
                    return [
                      // [UI-fix v2.0.3 | 2026-08-06] 换源/刷新/缓存（仅在线书）— Qoder
                      if (isOnline) ...[
                        const PopupMenuItem(
                            value: 'changeSource', child: Text('换源')),
                        const PopupMenuItem(
                            value: 'refreshBook', child: Text('刷新')),
                        const PopupMenuItem(value: 'cache', child: Text('缓存')),
                        const PopupMenuDivider(),
                      ],
                      const PopupMenuItem(
                        value: 'advanced',
                        child: Text('高级设置'),
                      ),
                      const PopupMenuItem(
                        value: 'highlightRule',
                        child: Text('高亮规则'),
                      ),
                      const PopupMenuItem(
                        value: 'editContent',
                        child: Text('编辑内容'),
                      ),
                      const PopupMenuItem(value: 'pageAnim', child: Text('翻页动画')),
                      const PopupMenuItem(
                        value: 'reverseContent',
                        child: Text('反转内容'),
                      ),
                      const PopupMenuItem(
                        value: 'simulatedReading',
                        child: Text('模拟追读'),
                      ),
                      PopupMenuItem(
                        value: 'enableReplace',
                        child: checked('替换规则', replaceOn),
                      ),
                      PopupMenuItem(
                        value: 'reSegment',
                        child: checked('重新分段', segmentOn),
                      ),
                      const PopupMenuItem(
                        value: 'imageStyle',
                        child: Text('图片样式'),
                      ),
                      // [UI-fix v2.0.3 | 2026-08-06] 新增设置编码菜单项 — Qoder
                      const PopupMenuItem(
                        value: 'setCharset',
                        child: Text('设置编码'),
                      ),
                      const PopupMenuItem(value: 'updateToc', child: Text('更新目录')),
                      const PopupMenuItem(value: 'log', child: Text('日志')),
                      const PopupMenuItem(value: 'help', child: Text('帮助')),
                    ];
                  },
                ),
              ],
            ),
          ),
          ),
        ),
      ),
    );
  }
}
