import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../services/book_api.dart';
import '../services/export_service.dart';
import 'source_login_screen.dart';
import '../widgets/book_cover.dart';
import '../widgets/error_view.dart';
import '../widgets/export_dialog.dart';
import '../widgets/loading_indicator.dart';

/// 书籍详情页面
class BookInfoScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book? book;

  /// 书籍 URL（向后兼容，当未传入 Book 对象时使用）
  final String bookUrl;

  const BookInfoScreen({super.key, this.book, this.bookUrl = ''});

  /// 获取有效的 bookUrl：优先从 Book 对象取值
  String get effectiveBookUrl => book?.bookUrl ?? bookUrl;

  @override
  ConsumerState<BookInfoScreen> createState() => _BookInfoScreenState();
}

class _BookInfoScreenState extends ConsumerState<BookInfoScreen> {
  late Future<_BookInfoData> _future;
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _tocHeaderKey = GlobalKey();
  String _filter = '';
  bool _isLoading = false;
  // 当前书籍（供 AppBar 溢出菜单读取勾选态）
  Book? _loadedBook;
  // 书架状态（对标原版 tv_shelf 加入书架/移出书架切换）
  bool _inBookshelf = false;

  @override
  void initState() {
    super.initState();
    _future = _loadData();
    _searchCtrl.addListener(() {
      setState(() => _filter = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<_BookInfoData> _loadData() async {
    final api = ref.read(bookApiProvider);
    final url = widget.effectiveBookUrl;
    // 优先从数据库取最新记录（换源/刷新后元数据才会更新），传入对象仅兜底
    final book = await api.getBook(url) ?? widget.book;
    final chapters = await api.getChapters(url);
    _loadedBook = book;
    // 书架中已存在该书记录时按钮显示「移出书架」（对标原版 upTvBookshelf）
    final shelfBook = book != null ? await api.getBook(book.bookUrl) : null;
    if (mounted) setState(() => _inBookshelf = shelfBook != null);
    return _BookInfoData(book: book, chapters: chapters);
  }

  @override
  Widget build(BuildContext context) {
    // 对标原版 activity_book_info.xml：封面背景 + 半透明遮罩 + 深色 TitleBar
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('书籍信息'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        // [审计修复 §3.3] 改用 Theme Token（沉浸式封面背景上仍为白色系） — Qoder
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑书籍信息',
            onPressed: () async {
              try {
                final data = await _future;
                final book = data.book;
                if (book == null) return;
                if (!context.mounted) return;
                final saved = await Navigator.pushNamed<bool>(
                  context,
                  AppRoutes.editBookInfo,
                  arguments: book,
                );
                // 编辑保存成功后重新加载书籍信息
                if (saved == true && mounted) {
                  setState(() => _future = _loadData());
                }
              } catch (e) {
                // [审计修复 §4.1] 不再静默吞异常，向用户提示 — Qoder
                debugPrint('编辑书籍信息失败: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('书籍信息暂不可用，请稍后重试')),
                  );
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.file_download_outlined),
            tooltip: '导出',
            onPressed: () async {
              try {
                final data = await _future;
                final book = data.book;
                if (book == null) return;
                if (!context.mounted) return;
                _showExportDialog(context, book);
              } catch (e) {
                // [审计修复 §4.1] 不再静默吞异常，向用户提示 — Qoder
                debugPrint('导出书籍失败: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('书籍信息暂不可用，请稍后重试')),
                  );
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.share),
            tooltip: '分享',
            onPressed: () async {
              try {
                final data = await _future;
                final book = data.book;
                if (book == null) return;
                final buffer = StringBuffer('《${book.name}》');
                if (book.author.isNotEmpty) {
                  buffer.write(' 作者：${book.author}');
                }
                final intro = book.customIntro ?? book.intro;
                if (intro != null && intro.isNotEmpty) {
                  final shortIntro =
                      intro.length > 100 ? '${intro.substring(0, 100)}...' : intro;
                  buffer.write('\n$shortIntro');
                }
                await Share.share(buffer.toString());
              } catch (e) {
                // [审计修复 §4.1] 不再静默吞异常，向用户提示 — Qoder
                debugPrint('分享书籍失败: $e');
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('书籍信息暂不可用，请稍后重试')),
                  );
                }
              }
            },
          ),
          // 安卓原版：三点菜单（book_info.xml）
          PopupMenuButton<String>(
            onSelected: _handleMenu,
            itemBuilder: (_) {
              final book = _loadedBook;
              return [
                const PopupMenuItem(value: 'upload', child: Text('上传至远程')),
                const PopupMenuItem(value: 'refresh', child: Text('刷新')),
                const PopupMenuItem(value: 'refreshToc', child: Text('更新目录')),
                const PopupMenuItem(
                  value: 'updateTask',
                  child: Text('创建书籍更新任务'),
                ),
                const PopupMenuItem(value: 'login', child: Text('登录')),
                const PopupMenuItem(value: 'top', child: Text('置顶')),
                const PopupMenuItem(
                  value: 'sourceVariable',
                  child: Text('设置源变量'),
                ),
                const PopupMenuItem(
                  value: 'bookVariable',
                  child: Text('设置书籍变量'),
                ),
                const PopupMenuItem(value: 'copyBookUrl', child: Text('拷贝书籍链接')),
                const PopupMenuItem(value: 'copyTocUrl', child: Text('拷贝目录链接')),
                CheckedPopupMenuItem(
                  value: 'canUpdate',
                  checked: book?.canUpdate ?? true,
                  child: const Text('允许更新'),
                ),
                CheckedPopupMenuItem(
                  value: 'splitLongChapter',
                  checked: book?.readConfig?.splitLongChapter ?? true,
                  child: const Text('拆分长章节'),
                ),
                const PopupMenuItem(value: 'deleteAlert', child: Text('删除警告')),
                const PopupMenuItem(value: 'clearCache', child: Text('清除缓存')),
                const PopupMenuItem(value: 'log', child: Text('日志')),
              ];
            },
          ),
        ],
      ),
      body: FutureBuilder<_BookInfoData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LoadingIndicator(message: '加载书籍信息...');
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: () => setState(() => _future = _loadData()),
            );
          }
          final data = snapshot.data!;
          final book = data.book;
          if (book == null) {
            return const ErrorView(message: '书籍不存在');
          }
          return _buildPage(context, book, data.chapters);
        },
      ),
      bottomNavigationBar: _buildBottomBar(),
    );
  }

  /// 页面主体：封面背景（bg_book）+ 半透明遮罩（vw_bg #50000000）+ 内容
  Widget _buildPage(BuildContext context, Book book, List<BookChapter> chapters) {
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    final Widget? bgImage = (coverUrl != null && coverUrl.isNotEmpty)
        ? CachedNetworkImage(imageUrl: coverUrl, fit: BoxFit.cover)
        : null;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 传统写法（null-aware 元素 ?bgImage 与 build_runner
        // 内置 analyzer 版本不兼容，codegen 会报语法错）
        if (bgImage != null) bgImage,
        // [审计修复 §3.3] 遮罩改用 colorScheme.scrim Token，
        // 透明度对齐原版 vw_bg #50000000 — Qoder
        ColoredBox(
          color: Theme.of(
            context,
          ).colorScheme.scrim.withValues(alpha: 0x50 / 0xFF),
        ),
        SafeArea(
          top: false,
          child: RefreshIndicator(
            onRefresh: () async => setState(() => _future = _loadData()),
            child: _buildBody(context, book, chapters),
          ),
        ),
      ],
    );
  }

  /// 溢出菜单处理（对标原版 BookInfoActivity.onOptionsItemSelected）
  Future<void> _handleMenu(String value) async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    switch (value) {
      case 'refresh':
        setState(() => _future = _loadData());
        break;
      case 'refreshToc':
        await _refreshToc();
        break;
      case 'copyBookUrl':
        if (book != null) {
          await Clipboard.setData(ClipboardData(text: book.bookUrl));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已拷贝书籍链接')));
          }
        }
        break;
      case 'copyTocUrl':
        if (book != null) {
          await Clipboard.setData(ClipboardData(text: book.tocUrl));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已拷贝目录链接')));
          }
        }
        break;
      case 'canUpdate':
      case 'splitLongChapter':
        if (book == null) return;
        final Book updated;
        if (value == 'canUpdate') {
          updated = book.copyWith(canUpdate: !book.canUpdate);
        } else {
          // splitLongChapter 存于 ReadConfig（对标原版 Book.splitLongChapter）
          final cfg = book.readConfig ?? const ReadConfig();
          updated = book.copyWith(
            readConfig: cfg.copyWith(
              splitLongChapter: !cfg.splitLongChapter,
            ),
          );
        }
        await api.updateBook(updated);
        if (mounted) setState(() => _future = _loadData());
        break;
      case 'log':
        // [UI-fix v2.0.1 | 2026-08-06] 日志菜单接通 AppLogScreen（对标原版 menu_log → AppLogDialog） — Qoder
        Navigator.pushNamed(context, AppRoutes.appLog);
        break;
      case 'login':
        // [UI-fix v2.0.2 | 2026-08-06] 登录接通书源登录链路（V2 动态协议/旧版凭据页） — Qoder
        await _loginSource();
        break;
      case 'top':
        // [UI-fix v2.0.2 | 2026-08-06] 置顶接通 topBook FFI（对标原版 topBook） — Qoder
        await _topBook();
        break;
      case 'clearCache':
        // [UI-fix v2.0.2 | 2026-08-06] 清缓存接通 clearCache FFI — Qoder
        await _clearCache();
        break;
      default:
        _todo(value);
        break;
    }
  }

  /// 未移植功能提示
  void _todo(String value) {
    const names = {
      'upload': '上传至远程',
      'updateTask': '创建书籍更新任务',
      'sourceVariable': '设置源变量',
      'bookVariable': '设置书籍变量',
      'deleteAlert': '删除警告',
    };
    final feature = names[value] ?? value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  Widget _buildBody(BuildContext context, Book book, List<BookChapter> chapters) {
    final filteredChapters = _filter.isEmpty
        ? chapters
        : chapters
            .where((c) => c.title.toLowerCase().contains(_filter))
            .toList();
    final cs = Theme.of(context).colorScheme;

    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // 封面卡（对标原版 ArcView + CardView 110x160 居中）
        SliverToBoxAdapter(child: _buildHeader(context, book)),
        // 信息面板：书名/标签/摘要行/简介（对标原版 ll_info）
        SliverToBoxAdapter(child: _buildSummaryPanel(context, book)),
        // 章节搜索与列表头（白色背景延续面板）
        SliverToBoxAdapter(
          child: Container(
            color: cs.surface,
            child: Column(
              children: [
                _buildChapterSearch(context),
                Container(
                  key: _tocHeaderKey,
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text(
                    '章节列表（${chapters.length}）',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 章节列表
        if (filteredChapters.isEmpty)
          SliverToBoxAdapter(
            child: Container(
              color: cs.surface,
              child: const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无匹配章节')),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: filteredChapters.length,
            itemBuilder: (context, index) {
              final chapter = filteredChapters[index];
              final isCurrentRead = chapter.index == book.durChapterIndex;
              return ListTile(
                // tileColor 延续白色面板背景（不能用 ColoredBox 包裹，会遮挡 ink 效果）
                tileColor: cs.surface,
                title: Text(
                  chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight:
                        isCurrentRead ? FontWeight.bold : FontWeight.normal,
                    color: isCurrentRead
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
                subtitle: chapter.wordCount != null &&
                        chapter.wordCount!.isNotEmpty
                    ? Text('${chapter.wordCount} 字')
                    : null,
                dense: true,
                trailing: isCurrentRead
                    ? const Icon(Icons.play_circle, size: 20)
                    : null,
                onTap: () => _openReader(context, book, chapter.index),
                onLongPress: () =>
                    _showChapterMenu(context, book, chapter, index),
              );
            },
          ),
        SliverToBoxAdapter(
          child: Container(color: cs.surface, height: 24),
        ),
      ],
    );
  }

  /// 顶部封面区（对标原版 ArcView + CardView：110x160 封面居中 + elevation 8）
  Widget _buildHeader(BuildContext context, Book book) {
    final topPadding = MediaQuery.paddingOf(context).top + kToolbarHeight + 8;
    return Padding(
      padding: EdgeInsets.only(top: topPadding, bottom: 12),
      child: Center(
        child: Material(
          elevation: 8,
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: BookCover(
            coverUrl: book.customCoverUrl ?? book.coverUrl,
            width: 110,
            height: 160,
            borderRadius: 10,
          ),
        ),
      ),
    );
  }

  /// 信息面板（对标原版 ll_info：书名 18sp 居中 + 标签栏 + 5 行 13sp 摘要行 + 简介）
  Widget _buildSummaryPanel(BuildContext context, Book book) {
    final cs = Theme.of(context).colorScheme;
    final latest = (book.latestChapterTitle ?? '').isNotEmpty
        ? '最新：${book.latestChapterTitle}'
        : '共 ${book.totalChapterNum} 章';
    final kinds = (book.kind ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        // iOS sheet 风格大圆角顶部
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
      child: Column(
        children: [
          // 书名 18sp 居中单行（对标 tv_name）
          Text(
            book.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w500,
              color: cs.onSurface,
            ),
          ),
          // 标签栏（对标 lb_kind，kind 非空时显示）
          if (kinds.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final kind in kinds)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.secondaryContainer.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      kind,
                      style: TextStyle(fontSize: 11, color: cs.onSurface),
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          // 作者行（对标 ic_author + tv_author）
          _summaryRow(
              context, Icons.person_outline, book.author.isNotEmpty ? book.author : '未知作者'),
          // 来源行（对标 ic_web + tv_origin + tv_change_source）
          _summaryRow(
            context,
            Icons.language,
            '来源：${book.originName.isNotEmpty ? book.originName : book.origin}',
            action: _smallAction(
                context, '换源', () => _showChangeSourceDialog(book)),
          ),
          // 最新行（对标 ic_book_last + tv_lasted）
          _summaryRow(context, Icons.menu_book_outlined, latest),
          // 分组行（对标 ic_groups + tv_group + tv_change_group）
          _summaryRow(context, Icons.groups_outlined, _groupText(book),
              action: _smallAction(context, '换组', _showChangeGroup)),
          // 目录行（对标 ll_toc：ic_folder_open + tv_toc + tv_toc_view）
          InkWell(
            onTap: _scrollToToc,
            child: _summaryRow(
              context,
              Icons.folder_open,
              '目录：共 ${book.totalChapterNum} 章',
              action: _smallAction(context, '查看目录', _scrollToToc),
            ),
          ),
          // 简介（对标 tv_intro_container + tv_intro_toggle）
          _buildIntro(context, book),
        ],
      ),
    );
  }

  /// 摘要行（对标原版：18dp 图标 + 6dp 间距 + 13sp 文本 + 可选小按钮）
  Widget _summaryRow(BuildContext context, IconData icon, String text,
      {Widget? action}) {
    final cs = Theme.of(context).colorScheme;
    final summaryColor = cs.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 18, color: summaryColor),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: summaryColor),
            ),
          ),
          if (action != null) action,
        ],
      ),
    );
  }

  /// 小按钮（对标原版 AccentBgTextView；iOS 风格胶囊小按钮）
  Widget _smallAction(BuildContext context, String text, VoidCallback onTap) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: cs.primary,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text, style: TextStyle(fontSize: 13, color: cs.onPrimary)),
      ),
    );
  }

  /// 分组显示文本（对标原版 tv_group；book.group 为位掩码）
  String _groupText(Book book) {
    final groups = ref.read(bookshelfNotifierProvider).groups;
    final names = groups
        .where((g) => g.groupId > 0 && (book.group & g.groupId) != 0)
        .map((g) => g.groupName)
        .toList();
    return '分组：${names.isEmpty ? '无' : names.join('，')}';
  }

  Widget _buildIntro(BuildContext context, Book book) {
    final intro = book.customIntro ?? book.intro;
    if (intro == null || intro.isEmpty) return const SizedBox.shrink();

    return _ExpandableText(text: intro);
  }

  Widget _buildChapterSearch(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _searchCtrl,
        decoration: InputDecoration(
          hintText: '搜索章节...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _filter.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchCtrl.clear();
                  },
                )
              : null,
          isDense: true,
          // iOS 风格填充搜索框（无边框，走主题 inputDecorationTheme 圆角）
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  /// 底部操作条（对标原版 fl_action：tv_shelf 加书架/移出书架 + tv_read 阅读，
  /// 各 weight 1、高 48、radius 8、15sp）
  Widget _buildBottomBar() {
    return FutureBuilder<_BookInfoData>(
      future: _future,
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final book = snapshot.data!.book;
        if (book == null) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return SafeArea(
          top: false,
          child: Container(
            color: cs.surfaceContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.tonal(
                      onPressed: () => _toggleShelf(book),
                      style: FilledButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text(_inBookshelf ? '移出书架' : '加入书架'),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: () =>
                          _openReader(context, book, book.durChapterIndex),
                      style: FilledButton.styleFrom(
                        textStyle: const TextStyle(fontSize: 15),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child:
                          Text(book.durChapterIndex > 0 ? '继续阅读' : '开始阅读'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 更新目录（对标原版 refreshToc；从底部按钮迁入溢出菜单）
  Future<void> _refreshToc() async {
    final book = _loadedBook;
    if (book == null || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final api = ref.read(bookApiProvider);
      final chapters = await api.refreshToc(book.bookUrl, book.origin);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录已更新，共 ${chapters.length} 章')),
      );
      setState(() => _future = _loadData());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('更新失败: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 加入书架 / 移出书架（对标原版 tv_shelf 切换逻辑）
  Future<void> _toggleShelf(Book book) async {
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
    if (_inBookshelf) {
      await notifier.removeBook(book.bookUrl);
      if (!mounted) return;
      setState(() => _inBookshelf = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.name}》已移出书架')),
      );
    } else {
      await notifier.addBook(book);
      if (!mounted) return;
      setState(() => _inBookshelf = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.name}》已加入书架')),
      );
    }
  }

  /// 换组（对标原版 tv_change_group → BookGroupDialog，单选菜单实现）
  Future<void> _showChangeGroup() async {
    final book = _loadedBook;
    if (book == null) return;
    final groups = ref
        .read(bookshelfNotifierProvider)
        .groups
        .where((g) => g.groupId > 0)
        .toList();
    if (!mounted) return;
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择分组'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 0),
            child: const Text('未分组'),
          ),
          for (final g in groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g.groupId),
              child: Text(g.groupName),
            ),
        ],
      ),
    );
    if (selected == null || !mounted) return;
    await ref.read(bookApiProvider).updateBook(book.copyWith(group: selected));
    if (mounted) setState(() => _future = _loadData());
  }

  /// 查看目录：滚动到本页章节列表区（对标原版 tv_toc_view）
  void _scrollToToc() {
    final ctx = _tocHeaderKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // ===== [UI-fix v2.0.2 | 2026-08-06] 登录 / 置顶 / 清缓存 — Qoder =====

  /// 书源登录（对标 Kotlin BookInfoActivity menu_login）：
  /// V2 动态状态协议（上游 #402/#488）→ 页内对话框；旧版协议 → SourceLoginScreen
  Future<void> _loginSource() async {
    final book = _loadedBook;
    if (book == null) return;
    if (book.origin == BookType.localTag ||
        book.origin.startsWith(BookType.webDavTag)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地书籍不支持书源登录')),
      );
      return;
    }
    final api = ref.read(bookApiProvider);
    BookSource? source;
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == book.origin) {
          source = s;
          break;
        }
      }
    } catch (e) {
      debugPrint('获取书源失败: $e');
    }
    if (!mounted) return;
    if (source == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未找到本书对应的书源')),
      );
      return;
    }
    final sourceJson = jsonEncode(source.toJson());
    var isV2 = false;
    try {
      isV2 = await api.isLoginUiV2(sourceJson);
    } catch (e) {
      debugPrint('loginUiV2 判定失败: $e');
    }
    if (!mounted) return;
    if (isV2) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => _LoginV2Dialog(
          api: api,
          sourceJson: sourceJson,
          sourceName: source!.bookSourceName,
        ),
      );
      if (ok == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录成功')),
        );
      }
    } else {
      // 旧版协议：复用手动凭据登录页
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SourceLoginScreen(
            sourceUrl: source!.bookSourceUrl,
            sourceName: source.bookSourceName,
            loginUrl: source.loginUrl,
          ),
        ),
      );
    }
  }

  /// 置顶（对标 Kotlin BookInfoViewModel.topBook；原版仅置顶无取消）
  Future<void> _topBook() async {
    final book = _loadedBook;
    if (book == null) return;
    try {
      await ref.read(bookApiProvider).topBook(book.bookUrl);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已置顶')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('置顶失败: $e')),
        );
      }
    }
  }

  /// 清除缓存（对标 Kotlin BookInfoViewModel.clearCache）
  ///
  /// TODO(Rust轨)：原版按书清缓存（BookCacheManager.clear），当前 FFI 仅有
  /// 全局 cacheClear，暂以全局清理 + 确认对话框降级实现 — Qoder
  Future<void> _clearCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除缓存'),
        // 当前 FFI 仅支持全局清缓存（按书清缓存留 Rust 轨补齐）
        content: const Text('当前仅支持清除全部缓存，是否继续？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(bookApiProvider).clearCache();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('缓存已清除')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('清除缓存失败: $e')),
        );
      }
    }
  }

  /// 打开导出对话框
  void _showExportDialog(BuildContext context, Book book) {
    final api = ref.read(bookApiProvider);
    final exportService = ExportService(api);
    showDialog(
      context: context,
      builder: (_) => ExportDialog(
        book: book,
        exportService: exportService,
        rustApi: api,
      ),
    );
  }

  // ===== 操作 =====

  void _openReader(BuildContext context, Book book, int chapterIndex) {
    final container = ProviderScope.containerOf(context);
    final bookToRead = chapterIndex != book.durChapterIndex
        ? book.copyWith(durChapterIndex: chapterIndex)
        : book;
    container.read(readerNotifierProvider.notifier).openBook(bookToRead);
    Navigator.pushNamed(context, AppRoutes.reader);
  }

  /// 打开换源页面，换源成功后用新的 bookUrl 重新加载详情页
  Future<void> _showChangeSourceDialog(Book book) async {
    final newBookUrl = await Navigator.pushNamed<String>(
      context,
      AppRoutes.changeSource,
      arguments: book,
    );
    if (!mounted) return;
    // 换源成功后 bookUrl 会变化，需要用新 URL 替换当前详情页
    if (newBookUrl != null && newBookUrl.isNotEmpty) {
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.bookInfo,
        arguments: book.copyWith(bookUrl: newBookUrl),
      );
    }
  }

  Future<void> _showChapterMenu(
    BuildContext context,
    Book book,
    BookChapter chapter,
    int index,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.flag),
              title: const Text('设为阅读起点'),
              onTap: () => Navigator.pop(ctx, 'start'),
            ),
            ListTile(
              leading: const Icon(Icons.play_arrow),
              title: const Text('从此章开始阅读'),
              onTap: () => Navigator.pop(ctx, 'read'),
            ),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (!context.mounted) return;
    if (action == 'start' || action == 'read') {
      _openReader(context, book, chapter.index);
    }
  }
}

/// 书籍信息加载结果
class _BookInfoData {
  final Book? book;
  final List<BookChapter> chapters;

  const _BookInfoData({required this.book, required this.chapters});
}

/// 登录 V2 动态状态协议对话框（对标 Kotlin SourceLoginDialogV2，上游 #402/#488）
///
/// [UI-fix v2.0.2 | 2026-08-06] — Qoder
/// rows 类型：text(需 key)/password/label/select(需 options)/button(需 action)；
/// action 返回命令键：state(对象→更新状态重渲染) / error(对象→键值错误) /
/// login(对象→登录成功) / close(布尔→关闭)。
class _LoginV2Dialog extends StatefulWidget {
  final BookApi api;
  final String sourceJson;
  final String sourceName;

  const _LoginV2Dialog({
    required this.api,
    required this.sourceJson,
    required this.sourceName,
  });

  @override
  State<_LoginV2Dialog> createState() => _LoginV2DialogState();
}

class _LoginV2DialogState extends State<_LoginV2Dialog> {
  String _stateJson = '{}';
  List<Map<String, dynamic>> _rows = [];
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _selects = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadUi();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 拉取动态 UI 描述（首次/收到 state 命令后重渲染）
  Future<void> _loadUi() async {
    setState(() => _busy = true);
    try {
      final json = await widget.api.loginUiV2(widget.sourceJson, _stateJson);
      final data = jsonDecode(json);
      final rows = (data is Map && data['rows'] is List)
          ? (data['rows'] as List)
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : <Map<String, dynamic>>[];
      if (!mounted) return;
      // 预填默认值（text/password → 控制器；select → 选中项）
      for (final row in rows) {
        final key = row['key']?.toString() ?? '';
        final value = row['value']?.toString() ?? '';
        final type = row['type']?.toString() ?? '';
        if (key.isEmpty) continue;
        if (type == 'select') {
          final options = (row['options'] is List)
              ? (row['options'] as List).map((e) => e.toString()).toList()
              : <String>[];
          _selects.putIfAbsent(
            key,
            () => value.isNotEmpty
                ? value
                : (options.isNotEmpty ? options.first : ''),
          );
        } else if (type == 'text' || type == 'password') {
          final ctrl = _controllers.putIfAbsent(key, TextEditingController.new);
          if (ctrl.text.isEmpty && value.isNotEmpty) ctrl.text = value;
        }
      }
      setState(() {
        _rows = rows;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  /// 收集表单数据（text/password 控制器 + select 选中项）
  Map<String, dynamic> _formJson() {
    final form = <String, dynamic>{};
    for (final e in _controllers.entries) {
      form[e.key] = e.value.text;
    }
    form.addAll(_selects);
    return form;
  }

  /// 执行 action 命令（button 行触发），处理返回命令键
  Future<void> _doAction(String action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final input = jsonEncode({
        'action': action,
        'stateJson': _stateJson,
        'formJson': _formJson(),
      });
      final resJson =
          await widget.api.loginActionV2(widget.sourceJson, input);
      final res = jsonDecode(resJson);
      if (!mounted) return;
      if (res is! Map) {
        setState(() => _busy = false);
        return;
      }
      if (res['close'] == true || res['login'] is Map) {
        Navigator.pop(context, true);
        return;
      }
      if (res['error'] is Map) {
        final msgs = (res['error'] as Map)
            .values
            .map((v) => v.toString())
            .where((v) => v.isNotEmpty);
        setState(() {
          _error = msgs.isEmpty ? '登录失败' : msgs.join('\n');
          _busy = false;
        });
        return;
      }
      if (res['state'] is Map) {
        _stateJson = jsonEncode(res['state']);
        setState(() => _busy = false);
        await _loadUi();
        return;
      }
      setState(() => _busy = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('登录 - ${widget.sourceName}'),
      content: SizedBox(
        width: 360,
        child: _busy && _rows.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    for (final row in _rows) _buildRow(row),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
      ],
    );
  }

  /// 按 rows 类型渲染单行（对齐 login_ui_v2.rs 协议）
  Widget _buildRow(Map<String, dynamic> row) {
    final type = row['type']?.toString() ?? '';
    final key = row['key']?.toString() ?? '';
    final name = row['name']?.toString() ?? '';
    final hint = row['hint']?.toString() ?? name;
    switch (type) {
      case 'label':
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Text(
            name.isNotEmpty ? name : (row['value']?.toString() ?? ''),
          ),
        );
      case 'select':
        final options = (row['options'] is List)
            ? (row['options'] as List).map((e) => e.toString()).toList()
            : <String>[];
        final current = _selects[key] ?? '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DropdownButton<String>(
            value: options.contains(current)
                ? current
                : (options.isNotEmpty ? options.first : null),
            isExpanded: true,
            hint: Text(hint),
            items: [
              for (final o in options)
                DropdownMenuItem<String>(value: o, child: Text(o)),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _selects[key] = v);
            },
          ),
        );
      case 'button':
        final action = row['action']?.toString() ?? '';
        // TODO: button countdown 倒计时暂未实现（后续对齐 — Qoder）
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: OutlinedButton(
            onPressed:
                _busy || action.isEmpty ? null : () => _doAction(action),
            child: Text(name),
          ),
        );
      case 'password':
      case 'text':
      default:
        final ctrl = _controllers.putIfAbsent(key, TextEditingController.new);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: ctrl,
            obscureText: type == 'password',
            decoration: InputDecoration(
              labelText: name.isNotEmpty ? name : null,
              hintText: hint,
            ),
          ),
        );
    }
  }
}

/// 可折叠文字组件
class _ExpandableText extends StatefulWidget {
  final String text;

  const _ExpandableText({required this.text});

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '简介',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
          ),
          const SizedBox(height: 4),
          AnimatedCrossFade(
            firstChild: Text(
              widget.text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            secondChild: Text(
              widget.text,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            crossFadeState:
                _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 200),
          ),
          if (widget.text.length > 100)
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _expanded ? '收起' : '展开全部',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
