import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/book.dart';
import '../../models/book_source.dart';
import '../../providers/providers.dart';
import '../../providers/reader/reader_notifier.dart';
import '../../routes.dart';
import '../../screens/source_edit_screen.dart';
import '../../screens/source_login_screen.dart';
import 'change_chapter_source_sheet.dart';
import 'reader_settings_sheet.dart';

/// 阅读器顶部工具栏
///
/// [UI-fix v2.0.4 | 2026-08-08] 模块 A：对齐安卓原版 view_read_menu.xml
/// TitleBar + book_read.xml 菜单 — Qoder
/// - 常驻图标：在线书=换源/刷新/缓存（menu_group_on_line），本地书=设置编码
///   （menu_group_local），窄窗口用紧凑图标防溢出
/// - 标题附加区（title_bar_addition，受 showReadTitleAddition 控制）：
///   章节名 + 章节 URL（点击复制）+ 书源徽章（tv_source_action，点击弹源操作菜单）
/// - 溢出菜单顺序/条件显隐逐项对齐 book_read.xml（visible=false 项不实现）
/// - 夜间/搜索按钮迁至底栏悬浮按钮行（对齐原版 fabNightTheme/fabSearch）；
///   书签迁入溢出菜单（对齐原版 menu_add_bookmark showAsAction=never）
class ReaderTopBar extends ConsumerStatefulWidget {
  /// 添加书签回调（溢出菜单 menu_add_bookmark）
  final VoidCallback onAddBookmark;

  // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批消费点 — Qoder

  /// 显示标题附加区（章节名/URL/源徽章，对标原版 showReadTitleAddition）
  final bool showTitleAddition;

  /// 工具栏样式跟随阅读页（对标原版 readBarStyleFollowPage/immersiveMenu）
  final bool styleFollowPage;

  const ReaderTopBar({
    super.key,
    required this.onAddBookmark,
    this.showTitleAddition = true,
    this.styleFollowPage = false,
  });

  @override
  ConsumerState<ReaderTopBar> createState() => _ReaderTopBarState();
}

class _ReaderTopBarState extends ConsumerState<ReaderTopBar> {
  // [UI-fix v2.0.4 | 2026-08-08] EPUB delTag 位标（对齐 Kotlin Book.hTag=2、
  // Book.rubyTag=4，经 ReadConfig.delTag 位运算持久化） — Qoder
  static const int _hTag = 2;
  static const int _rubyTag = 4;

  /// 章级「删除重复标题」开关展示态（Task #52 §5.11-7，契约 §2.9.10）
  ///
  /// true=去除重复标题（全局默认，FFI enable=true）；false=该章保留
  /// 原标题（章级 opt-out，FFI enable=false），方向与原版
  /// reverseRemoveSameTitle 一致。Rust 侧无查询 API，初始态用本地
  /// 切换记录辅助显示，行为以 FFI 为准。
  bool _sameTitleRemoved = true;

  /// 已启用替换规则计数（menu_effective_replaces 只读展示；原版为当前章
  /// 生效规则列表，Flutter 侧无章级 API，降级为全局启用计数）
  int? _effectiveReplaceCount;

  /// 已加载章级开关的复合键（bookUrl#chapterIndex，换书/换章后重新加载）
  String? _flagsLoadedKey;

  /// 加载章级开关与替换规则计数（书籍/章节变化时调用）
  Future<void> _loadLocalFlags(String bookUrl, int chapterIndex) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // [Task #55 F10 | 2026-08-10] 一次性移除旧书级键（不带章节后缀的
      // 早期格式），幂等无副作用；键已不存在时 remove 亦不报错 — Qoder
      await prefs.remove('sameTitleRemoved_$bookUrl');
      // [Task #52 | 2026-08-10] Rust 侧无查询 API，用本地切换记录辅助
      // 显示；默认 true（全局默认=去除重复标题） — Qoder
      final removed =
          prefs.getBool('sameTitleRemoved_${bookUrl}_$chapterIndex') ?? true;
      if (mounted) setState(() => _sameTitleRemoved = removed);
    } catch (_) {
      // 持久化不可用时保持默认开启
    }
    try {
      final rules = await ref.read(bookApiProvider).getEnabledReplaceRules();
      if (mounted) setState(() => _effectiveReplaceCount = rules.length);
    } catch (_) {
      // 替换规则 API 不可用时不展示计数
    }
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 溢出菜单去存根（对标原版
  // ReadBookActivity 菜单 handler） — Qoder =====

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 换源菜单（对标原版 showChangeSourceMenu：单章换源 / 换书源）
  void _showChangeSourceMenu(BuildContext context, Book book) {
    final state = ref.read(readerNotifierProvider);
    final chapter = state.currentChapter;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.article_outlined),
                title: const Text('单章换源'),
                subtitle: Text(
                  chapter?.title.isNotEmpty == true
                      ? chapter!.title
                      : '仅替换当前章正文',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  showChangeChapterSourceSheet(
                    context,
                    bookUrl: book.bookUrl,
                    bookName: book.name,
                    author: book.author,
                    chapterIndex: state.currentChapterIndex,
                    chapterTitle: chapter?.title ?? '',
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: const Text('换书源'),
                subtitle: const Text('切换整本书的书源'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.pushNamed(
                    context,
                    AppRoutes.changeSource,
                    arguments: book,
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
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
            '• 顶栏：换源（单章/整书）、刷新、缓存（在线书）/设置编码（本地书）、更多菜单\n'
            '• 顶栏下方：章节名与链接（点击复制）、书源徽章（点击弹源操作）\n'
            '• 底栏：搜索/夜间悬浮按钮、上一章/进度/下一章、目录、朗读、界面、设置\n'
            '• 左右滑动或点击两侧区域翻页\n'
            '• 长按正文可选择文本（复制/搜索/替换/朗读等）\n'
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
  /// 选择起止章节 → cacheDownloadStart 批量任务真实下载写缓存）
  /// [UI-fix v2.0.16 | 2026-08-10] 原实现逐章 downloadAddTask 仅登记内存
  /// 任务不执行下载，cached_chapters 永不写入→目录页图标不更新 — Reasonix
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
              final count = end - start + 1;
              try {
                // 0-based 索引（含端点）；Rust 侧超界自动截断
                await api.cacheDownloadStart(book.bookUrl, start - 1, end - 1);
                if (context.mounted) {
                  _snack(context, '已加入缓存队列：$count 章（可在书籍菜单「缓存管理」查看进度）');
                }
              } catch (e) {
                if (context.mounted) {
                  _snack(context, '缓存启动失败：$e');
                }
              }
            },
            child: const Text('开始缓存'),
          ),
        ],
      ),
    );
  }

  // ===== [UI-fix v2.0.4 | 2026-08-08] 模块 A 新增：源操作菜单自底栏
  // 迁入（承接原底栏“源菜单”全部功能，对齐原版 tv_source_action 点击
  // 弹 book_read_source 菜单：登录源/章节购买/编辑源/禁用源） — Qoder =====

  /// 显示源操作菜单（先查书源详情获取登录地址等）
  Future<void> _showSourceMenu(BuildContext context, Book book) async {
    final api = ref.read(bookApiProvider);
    final sourceUrl = book.origin;
    // 查找当前书籍对应书源（失败时仍提供编辑/禁用入口）
    BookSource? source;
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == sourceUrl) {
          source = s;
          break;
        }
      }
    } catch (_) {
      // 书源列表不可用时降级：登录项隐藏，其余入口保留
    }
    if (!context.mounted) return;

    final loginUrl = source?.loginUrl ?? '';
    final sourceName =
        (source?.bookSourceName ?? book.originName).trim();

    // 菜单锚在顶栏下缘右侧（徽章位置），不遮挡顶栏内容
    final screenWidth = MediaQuery.of(context).size.width;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          screenWidth - 200, kToolbarHeight + 56, 8, 0),
      items: [
        if (loginUrl.isNotEmpty)
          const PopupMenuItem(value: 'login', child: Text('登录源')),
        // 本地书隐藏章节购买项（对标原版 isLocal 短路）— Qoder
        if (book.origin != BookType.localTag)
          const PopupMenuItem(value: 'chapterPay', child: Text('章节购买')),
        const PopupMenuItem(value: 'editSource', child: Text('编辑源')),
        const PopupMenuItem(value: 'disableSource', child: Text('禁用源')),
      ],
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'login':
        // 对标原版 menu_login → 登录 V2 页面
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceLoginScreen(
              sourceUrl: sourceUrl,
              sourceName: sourceName,
              loginUrl: loginUrl,
            ),
          ),
        );
      case 'chapterPay':
        // [UI-fix v2.0.3 | 2026-08-08] 章节购买接线（契约 §2.43.2） — Qoder
        await _chapterPay(context, book);
      case 'editSource':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SourceEditScreen(sourceUrl: sourceUrl),
          ),
        );
      case 'disableSource':
        try {
          await api.disableBookSource(sourceUrl);
          if (context.mounted) {
            _snack(context, '已禁用书源：$sourceName');
          }
        } catch (e) {
          if (context.mounted) _snack(context, '禁用书源失败: $e');
        }
    }
  }

  // [UI-fix v2.0.3 | 2026-08-08] 章节购买（契约 §2.43.2，对照 Kotlin
  // ReadBookActivity.payAction 的 onSuccess 三分支）：
  // url → 内置浏览器打开购买页；success → 提示购买成功并重载当前章
  // （Rust 侧已清章节缓存）；none → 提示无需购买；异常 → 错误提示 — Qoder
  Future<void> _chapterPay(BuildContext context, Book book) async {
    final api = ref.read(bookApiProvider);
    final chapterIndex =
        ref.read(readerNotifierProvider).currentChapterIndex;
    _snack(context, '正在执行章节购买…');
    try {
      final result = await api.chapterPayAction(
        bookUrl: book.bookUrl,
        chapterIndex: chapterIndex,
      );
      if (!context.mounted) return;
      switch (result.kind) {
        case 'url':
          // 购买页地址：内置浏览器打开（对标原版 WebViewActivity，
          // 标题为 chapter_pay 字符串）
          Navigator.of(context).pushNamed(
            AppRoutes.browser,
            arguments: <String, String>{
              'url': result.value,
              'title': '章节购买',
            },
          );
        case 'success':
          // 购买成功：重载当前章正文（参考编辑保存后的重载路径）；
          // 重载失败不影响购买结果提示
          try {
            await ref
                .read(readerNotifierProvider.notifier)
                .reloadChapterContent();
          } catch (e) {
            debugPrint('购买成功后重载章节失败: $e');
          }
          if (context.mounted) _snack(context, '购买成功');
        default:
          // kind=none：本地书短路/书源未配置 payAction/不支持
          _snack(context, '当前章节无需购买或书源未配置购买动作');
      }
    } catch (e) {
      // 对标原版 onError：执行购买操作出错
      if (context.mounted) _snack(context, '章节购买失败: $e');
    }
  }

  // ===== [UI-fix v2.0.4 | 2026-08-08] 模块 A 新增：溢出菜单补缺项与
  // 标题附加区辅助 — Qoder =====

  /// 是否 EPUB 书籍（对齐 Kotlin Book.isEpub：本地书且文件名 .epub 后缀，
  /// menu_group_epub 仅 EPUB 可见）
  bool _isEpub(Book? book) {
    if (book == null || book.origin != BookType.localTag) return false;
    final name =
        (book.originName.isNotEmpty ? book.originName : book.bookUrl)
            .toLowerCase();
    return name.endsWith('.epub');
  }

  /// delTag 位标是否启用（对齐 Kotlin Book.getDelTag）
  bool _hasDelTag(Book? book, int tag) =>
      ((book?.readConfig?.delTag ?? 0) & tag) != 0;

  /// 切换 delTag 位标并重载正文（对齐 Kotlin addDelTag/removeDelTag 后
  /// refreshContentAll；ReadConfig.delTag 经 updateBook 持久化）
  void _toggleDelTag(BuildContext context, int tag, String label) {
    final book = ref.read(readerNotifierProvider).currentBook;
    final enabled = _hasDelTag(book, tag);
    unawaited(_updateBookConfig(
      context,
      ref,
      (c) => c.copyWith(delTag: enabled ? (c.delTag & ~tag) : (c.delTag | tag)),
    ));
    if (context.mounted) {
      _snack(context, enabled ? '已关闭$label' : '已开启$label');
    }
  }

  /// 切换章级「删除重复标题」（Task #52 §5.11-7，契约 §2.9.10）
  ///
  /// 对齐原版 ReadBookActivity.menu_same_title_removed →
  /// reverseRemoveSameTitle：开关 ON=去除（enable=true，全局默认），
  /// OFF=该章保留原标题（enable=false，章级 opt-out）；
  /// 切换成功后重载当前章正文（对齐原版 ReadBook.loadContent）。
  Future<void> _toggleSameTitleRemoved(BuildContext context) async {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null) return;
    final chapterIndex = state.currentChapterIndex;
    final next = !_sameTitleRemoved;
    try {
      await ref
          .read(bookApiProvider)
          .toggleSameTitleRemoved(book.bookUrl, chapterIndex, next);
      if (!mounted) return;
      setState(() => _sameTitleRemoved = next);
      // 本地辅助显示缓存（Rust 侧无查询 API，行为以 FFI 为准）
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(
            'sameTitleRemoved_${book.bookUrl}_$chapterIndex', next);
      } catch (_) {
        // 持久化失败不阻断开关切换
      }
      // 重载当前章正文，使开关立即生效（对齐原版 loadContent）
      await ref.read(readerNotifierProvider.notifier).reloadChapterContent();
      if (context.mounted) {
        _snack(context, next ? '已去除重复标题' : '该章已保留原标题');
      }
    } catch (e) {
      if (context.mounted) _snack(context, '设置失败: $e');
    }
  }

  /// 有效替换规则只读展示（对标原版 menu_effective_replaces →
  /// EffectiveReplacesDialog；降级为全局启用计数展示）
  void _showEffectiveReplacesDialog(BuildContext context) {
    final count = _effectiveReplaceCount;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('有效替换规则'),
        content: Text(
          count != null
              ? '当前已启用替换规则 $count 条（全局启用计数；原版为当前章节生效规则列表，章级数据待 FFI 契约补齐）'
              : '替换规则数据暂不可用',
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

  /// URL 中间省略截断（对齐原版 tv_chapter_url singleLine 展示，任务要求
  /// 中间省略；Flutter Text 无内置 middle ellipsis，按字符数截断）
  String _middleEllipsis(String text, {int maxLength = 60}) {
    if (text.length <= maxLength) return text;
    final head = maxLength ~/ 2;
    final tail = maxLength - head - 1;
    return '${text.substring(0, head)}…${text.substring(text.length - tail)}';
  }

  /// 复制章节 URL 到剪贴板并提示
  Future<void> _copyChapterUrl(BuildContext context, String url) async {
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) _snack(context, '章节链接已复制');
  }

  // [UI-fix v2.0.4 | 2026-08-08] 章节 URL 行交互对齐原版 tv_chapter_url：
  // 点击按持久化偏好打开（键名对齐原版 readUrlInBrowser，默认内置
  // BrowserScreen，桌面无 WebView 时其内部已降级 url_launcher），
  // 长按弹选择菜单（内置/系统浏览器/复制链接，选择打开方式同时
  // 记住偏好）— Qoder

  /// 点击章节 URL：按 readUrlInBrowser 偏好打开（false=内置，true=系统）
  Future<void> _openChapterUrl(BuildContext context, String url) async {
    var inSystemBrowser = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      inSystemBrowser = prefs.getBool('readUrlInBrowser') ?? false;
    } catch (_) {
      // 偏好读取失败时默认内置打开
    }
    if (!context.mounted) return;
    if (inSystemBrowser) {
      await _openUrlInSystemBrowser(context, url);
    } else {
      Navigator.of(context).pushNamed(
        AppRoutes.browser,
        arguments: <String, String>{'url': url, 'title': '章节链接'},
      );
    }
  }

  /// 系统浏览器打开（url_launcher 已在 pubspec 依赖中）
  Future<void> _openUrlInSystemBrowser(
      BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    final ok = uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) _snack(context, '无法打开链接：$url');
  }

  /// 长按章节 URL：选择打开方式（选内置/系统同时持久化偏好）
  Future<void> _showChapterUrlMenu(BuildContext context, String url) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('打开方式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'inner'),
            child: const Text('内置浏览器打开'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'system'),
            child: const Text('系统浏览器打开'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, 'copy'),
            child: const Text('复制链接'),
          ),
        ],
      ),
    );
    if (choice == null || !context.mounted) return;
    switch (choice) {
      case 'inner':
      case 'system':
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setBool('readUrlInBrowser', choice == 'system');
        } catch (_) {
          // 偏好持久化失败不阻断本次打开
        }
        if (!context.mounted) return;
        if (choice == 'system') {
          await _openUrlInSystemBrowser(context, url);
        } else {
          Navigator.of(context).pushNamed(
            AppRoutes.browser,
            arguments: <String, String>{'url': url, 'title': '章节链接'},
          );
        }
      case 'copy':
        await _copyChapterUrl(context, url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);
    final progressPct = (state.readingProgress * 100).toStringAsFixed(1);
    final book = state.currentBook;

    // [Task #52 | 2026-08-10] §5.11-7：删重标题开关改章级，换书/换章后
    // 重新加载辅助显示态（顶栏仅在 showControls 时挂载） — Qoder
    final flagsKey = '${book?.bookUrl}#${state.currentChapterIndex}';
    if (book != null && _flagsLoadedKey != flagsKey) {
      _flagsLoadedKey = flagsKey;
      unawaited(_loadLocalFlags(book.bookUrl, state.currentChapterIndex));
    }

    // 在线书判定（对齐原版 onLine = !book.isLocal，WebDAV 视作本地）
    final isOnline = book != null &&
        book.origin != BookType.localTag &&
        !book.origin.startsWith(BookType.webDavTag);

    // [UI-fix v2.0.3 | 2026-08-08] 工具栏跟随页面：背景/前景色跟随当前
    // 阅读页配色（对标原版 ReadMenu immersiveMenu：bgColor=页面背景、
    // textColor=页面文字色）；关闭时维持主题 surface — Qoder
    final followColor = widget.styleFollowPage ? state.backgroundColor : null;
    final foreground = widget.styleFollowPage ? state.textColor : null;
    // [UI-fix v2.0.4 | 2026-08-08] 标题附加区数据（对齐原版 upBookView：
    // tv_chapter_name=章名，tv_chapter_url 仅在线书可见） — Qoder
    final chapter = state.currentChapter;
    final chapterTitle = chapter?.title ?? '';
    final chapterUrl = chapter?.url ?? '';
    // 附加区文字弱化色（对齐原版 immersiveMenu lightenColor 0.75 透明度）
    final additionColor = widget.styleFollowPage
        ? state.textColor.withValues(alpha: 0.75)
        : Theme.of(context).colorScheme.onSurfaceVariant;

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
            color: widget.styleFollowPage
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: kToolbarHeight,
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      Expanded(
                        child: Text(
                          book?.name ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(color: foreground),
                        ),
                      ),
                      // 阅读进度百分比
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          '$progressPct%',
                          style: Theme.of(context)
                              .textTheme
                              .labelMedium
                              ?.copyWith(
                                color: widget.styleFollowPage
                                    ? state.textColor
                                    : Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                      // [UI-fix v2.0.4 | 2026-08-08] 换源/刷新/缓存提为顶栏
                      // 常驻图标（对齐原版 menu_group_on_line
                      // showAsAction=always，仅在线书可见）；本地书展示设置
                      // 编码（menu_group_local）；统一紧凑尺寸防窄窗口
                      // RIGHT OVERFLOWED（标题 Expanded 吸收余宽） — Qoder
                      if (isOnline) ...[
                        IconButton(
                          icon: const Icon(Icons.swap_horiz, size: 22),
                          tooltip: '换源',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _showChangeSourceMenu(context, book),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh, size: 22),
                          tooltip: '刷新',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await notifier.openBook(book);
                            if (context.mounted) _snack(context, '已刷新');
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.download_outlined, size: 22),
                          tooltip: '缓存（离线缓存）',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _showCacheDialog(context, ref),
                        ),
                      ] else if (book != null)
                        IconButton(
                          icon: const Icon(Icons.translate, size: 22),
                          tooltip: '设置编码',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _showCharsetDialog(context, ref),
                        ),
                      // 溢出菜单（顺序对齐 book_read.xml never 项；
                      // [UI-fix v2.0.4 | 2026-08-08] 书签迁入、补删除重复
                      // 标题/EPUB 标签清理/有效替换规则，移除与常驻图标
                      // 重复的换源/刷新/缓存/设置编码与原版不存在的
                      // 高级设置项（底栏设置按钮承接） — Qoder）
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        // 菜单自顶栏正下方展开（项目菜单定位规范）
                        position: PopupMenuPosition.under,
                        onSelected: (value) async {
                          switch (value) {
                            case 'addBookmark':
                              // 对标原版 menu_add_bookmark → addBookmark()
                              widget.onAddBookmark();
                              break;
                            case 'highlightRule':
                              // 对标原版 ReadMenu → HighlightRuleActivity
                              Navigator.pushNamed(
                                  context, AppRoutes.highlightRules);
                              break;
                            case 'editContent':
                              _showEditContentDialog(context, ref);
                              break;
                            case 'pageAnim':
                              // [UI-fix v2.0.1 | 2026-08-06] 翻页动画接阅读
                              // 设置面板（对标原版 ReadStyleDialog） — Qoder
                              ReaderSettingsSheet.show(context);
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
                            case 'sameTitleRemoved':
                              unawaited(_toggleSameTitleRemoved(context));
                              break;
                            case 'reSegment':
                              _toggleReSegment(context, ref);
                              break;
                            case 'delRubyTag':
                              _toggleDelTag(context, _rubyTag, '删除 Ruby 标签');
                              break;
                            case 'delHTag':
                              _toggleDelTag(context, _hTag, '删除 H 标签');
                              break;
                            case 'imageStyle':
                              _showImageStyleDialog(context, ref);
                              break;
                            case 'updateToc':
                              unawaited(_updateToc(context, ref));
                              break;
                            case 'effectiveReplaces':
                              _showEffectiveReplacesDialog(context);
                              break;
                            case 'log':
                              // [UI-fix v2.0.1 | 2026-08-06] 日志接通
                              // AppLogScreen（对标 menu_log） — Qoder
                              Navigator.pushNamed(context, AppRoutes.appLog);
                              break;
                            case 'help':
                              _showHelpDialog(context);
                              break;
                          }
                        },
                        itemBuilder: (_) {
                          // [UI-fix v2.0.2 | 2026-08-06] checkable 菜单项以
                          // 勾选样式展示当前启用状态 — Qoder
                          final replaceOn =
                              book?.readConfig?.useReplaceRule ?? true;
                          final segmentOn =
                              book?.readConfig?.reSegment ?? false;
                          final isEpub = _isEpub(book);
                          Widget checked(String text, bool on) => Row(
                                children: [
                                  if (on) ...[
                                    Icon(Icons.check,
                                        size: 16,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary),
                                    const SizedBox(width: 6),
                                  ],
                                  Text(text),
                                ],
                              );
                          return [
                            // 顺序对齐 book_read.xml：add_bookmark →
                            // highlight_rule → edit_content → page_anim →
                            // reverse_content(仅在线) → simulated_reading →
                            // enable_replace → same_title_removed →
                            // re_segment → epub 组(仅 EPUB) → image_style →
                            // update_toc → effective_replaces → log → help；
                            // get_progress/cover_progress/enable_review 为
                            // 原版 visible=false 项，不实现
                            const PopupMenuItem(
                                value: 'addBookmark', child: Text('添加书签')),
                            const PopupMenuItem(
                                value: 'highlightRule', child: Text('高亮规则')),
                            const PopupMenuItem(
                                value: 'editContent', child: Text('编辑内容')),
                            const PopupMenuItem(
                                value: 'pageAnim', child: Text('翻页动画')),
                            // 反转内容仅在线书可见（对齐 upMenu
                            // isVisible=onLine）
                            if (isOnline)
                              const PopupMenuItem(
                                  value: 'reverseContent',
                                  child: Text('反转内容')),
                            const PopupMenuItem(
                                value: 'simulatedReading',
                                child: Text('模拟追读')),
                            PopupMenuItem(
                              value: 'enableReplace',
                              child: checked('替换规则', replaceOn),
                            ),
                            // [Task #52 | 2026-08-10] 删除重复标题接通章级 FFI
                            // （契约 §2.9.10 toggleSameTitleRemoved；对齐原版
                            // menu_same_title_removed → reverseRemoveSameTitle） — Qoder
                            PopupMenuItem(
                              value: 'sameTitleRemoved',
                              child:
                                  checked('删除重复标题', _sameTitleRemoved),
                            ),
                            PopupMenuItem(
                              value: 'reSegment',
                              child: checked('重新分段', segmentOn),
                            ),
                            // [UI-fix v2.0.4 | 2026-08-08] EPUB 标签清理组
                            // （对齐 menu_group_epub 仅 EPUB 可见，经
                            // ReadConfig.delTag 位标持久化） — Qoder
                            if (isEpub) ...[
                              PopupMenuItem(
                                value: 'delRubyTag',
                                child: checked(
                                    '删除 Ruby 标签', _hasDelTag(book, _rubyTag)),
                              ),
                              PopupMenuItem(
                                value: 'delHTag',
                                child: checked(
                                    '删除 H 标签', _hasDelTag(book, _hTag)),
                              ),
                            ],
                            const PopupMenuItem(
                                value: 'imageStyle', child: Text('图片样式')),
                            const PopupMenuItem(
                                value: 'updateToc', child: Text('更新目录')),
                            // [UI-fix v2.0.4 | 2026-08-08] 有效替换规则只读
                            // 展示（对齐 menu_effective_replaces） — Qoder
                            PopupMenuItem(
                              value: 'effectiveReplaces',
                              child: Text(_effectiveReplaceCount != null
                                  ? '有效替换规则（$_effectiveReplaceCount 条启用）'
                                  : '有效替换规则'),
                            ),
                            const PopupMenuItem(
                                value: 'log', child: Text('日志')),
                            const PopupMenuItem(
                                value: 'help', child: Text('帮助')),
                          ];
                        },
                      ),
                    ],
                  ),
                ),
                // [UI-fix v2.0.4 | 2026-08-08] 标题附加区（对齐原版
                // title_bar_addition，受 showReadTitleAddition 控制）：
                // 章节名 + 章节 URL（点击复制）+ 书源徽章
                // （tv_source_action，点击弹源操作菜单，本地书隐藏） — Qoder
                if (widget.showTitleAddition &&
                    book != null &&
                    (chapterTitle.isNotEmpty || isOnline))
                  Padding(
                    padding:
                        const EdgeInsets.only(left: 16, right: 12, bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (chapterTitle.isNotEmpty)
                                Text(
                                  chapterTitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodySmall
                                      ?.copyWith(color: additionColor),
                                ),
                              // [UI-fix v2.0.4 | 2026-08-08] 章节 URL 行
                              // （仅在线书，对齐 upBookView isLocalBook
                              // 隐藏）：点击按偏好打开，长按选择
                              // 打开方式（对齐原版 tv_chapter_url）— Qoder
                              if (isOnline && chapterUrl.isNotEmpty)
                                InkWell(
                                  onTap: () => unawaited(
                                      _openChapterUrl(context, chapterUrl)),
                                  onLongPress: () => unawaited(
                                      _showChapterUrlMenu(
                                          context, chapterUrl)),
                                  child: Text(
                                    _middleEllipsis(chapterUrl),
                                    maxLines: 1,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: additionColor,
                                            fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        // 书源徽章（对齐 tv_source_action：maxWidth 120、
                        // 强调色底；承接原底栏“源菜单”入口）
                        if (isOnline) ...[
                          const SizedBox(width: 8),
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () =>
                                unawaited(_showSourceMenu(context, book)),
                            child: Container(
                              constraints:
                                  const BoxConstraints(maxWidth: 120),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                book.originName.isNotEmpty
                                    ? book.originName
                                    : '书源',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                // 强调色底徽章用 onPrimary 白色文字
                                // （项目配色可访问性规范）
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onPrimary),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
