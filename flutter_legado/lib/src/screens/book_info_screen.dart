import 'dart:convert';
import 'dart:ui' show ImageFilter;

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
import '../services/settings_service.dart';
import 'source_login_screen.dart';
import '../widgets/book_cover.dart';
import '../widgets/error_view.dart';
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
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  // 当前书籍（供 AppBar 溢出菜单读取勾选态）
  Book? _loadedBook;
  // 当前书源（供溢出菜单条件项：设置变量/允许更新/登录/创建更新任务判定）
  BookSource? _bookSource;
  // 书架状态（对标原版 tv_shelf 加入书架/移出书架切换）
  bool _inBookshelf = false;
  // [UI-fix v2.0.3 | 2026-08-08] 删除提醒开关（对齐原版 LocalConfig.deleteBookAlert，本地持久化） — Qoder
  final SettingsService _settingsService = SettingsService();
  bool _deleteBookAlert = true;

  @override
  void initState() {
    super.initState();
    _future = _loadData();
    _loadDeleteBookAlert();
  }

  /// 加载「删除提醒」开关（对齐原版 LocalConfig.deleteBookAlert）
  Future<void> _loadDeleteBookAlert() async {
    final v = await _settingsService.getDeleteBookAlert();
    if (mounted) setState(() => _deleteBookAlert = v);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<_BookInfoData> _loadData() async {
    final api = ref.read(bookApiProvider);
    final url = widget.effectiveBookUrl;
    // 优先从数据库取最新记录（换源/刷新后元数据才会更新），传入对象仅兜底
    final dbBook = await api.getBook(url);
    // DB 有记录且未打 notShelf 位才视为已入书架（对标原版 inBookshelf；
    // 搜索/发现打开的在线书会以 notShelf 临时落库，不算在书架内）
    final inShelf =
        dbBook != null && (dbBook.bookType & BookType.notShelf) == 0;
    var book = dbBook ?? widget.book;
    var chapters = await api.getChapters(url);
    // 书源查询一次即复用：既供菜单条件项判定，也供下方联网补全传参
    BookSource? source;
    if (book != null && _isOnlineBook(book)) {
      source = await _findSourceByOrigin(api, book.origin);
    }

    // [UI-fix v2.0.3 | 2026-08-06] 未入库在线书进入即联网补全目录/详情/封面 — Qoder
    // 对齐原版 BookInfoViewModel.upBook：tocUrl/详情缺失→loadBookInfo 补
    // cover/intro/tocUrl；DB 无章节→loadChapter 取目录。关键：未入库时「仅展示
    // 不落库」（对齐原版 loadChapter 在 !inBookshelf 时不写 DB）；真正落库延迟到
    // 开始阅读（见 _openReader），且以 notShelf 位标记，书架列表(list_books)过滤，不污染书架。
    if (book != null && chapters.isEmpty && _isOnlineBook(book)) {
      var b = book;
      if (source != null) {
        final sourceJson = jsonEncode(source.toJson());
        // a. 补全元数据（现象3：封面/简介/tocUrl/字数缺失）
        if (_needCompleteInfo(b)) {
          try {
            final infoJson = await api.webbookInfo(sourceJson, b.bookUrl);
            b = _mergeWebInfo(b, infoJson);
          } catch (e) {
            debugPrint('webbookInfo 补全失败，降级用原书籍继续: ${_errMsg(e)}');
          }
        }
        // b. 取目录（现象1）
        try {
          if (inShelf) {
            // 已入库：走 DB 刷新（refreshToc 内部落库章节）
            chapters = await api.refreshToc(b.bookUrl, b.origin);
          } else {
            // 未入库：仅网络取目录用于展示，不落库
            final chJson = await api.webbookChapters(sourceJson, b.bookUrl);
            chapters = _parseWebChapters(chJson, b.bookUrl);
          }
        } catch (e) {
          debugPrint(
              '取目录失败(bookUrl=${b.bookUrl}, origin=${b.origin}): ${_errMsg(e)}');
        }
        // 目录数回填 totalChapterNum（供「目录：共 N 章」摘要行显示）
        if (chapters.isNotEmpty) {
          b = b.copyWith(totalChapterNum: chapters.length);
        }
        // 已入库书：把补全的元数据写回 DB（对标原版 inBookshelf 时 update）
        if (inShelf) {
          try {
            await api.updateBook(b);
          } catch (e) {
            debugPrint('更新书籍元数据失败: $e');
          }
        }
      }
      book = b;
    }

    _loadedBook = book;
    _bookSource = source;
    // 书架中已存在该书记录时按钮显示「移出书架」（对标原版 upTvBookshelf）
    if (mounted) setState(() => _inBookshelf = inShelf);
    return _BookInfoData(book: book, chapters: chapters);
  }

  /// 提取错误信息：BridgeError 等封装类型带 message 字段，直接 `$e` 只得类型名。
  String _errMsg(Object e) {
    try {
      final m = (e as dynamic).message;
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return e.toString();
  }

  /// 是否在线书籍（非本地、非 WebDAV）——仅在线书才走网络补全链路
  bool _isOnlineBook(Book book) =>
      book.origin.isNotEmpty &&
      book.origin != BookType.localTag &&
      !book.origin.startsWith(BookType.webDavTag);

  /// 元数据是否需要联网补全（封面/简介/目录链接任一缺失）
  bool _needCompleteInfo(Book book) =>
      (book.coverUrl == null || book.coverUrl!.isEmpty) ||
      (book.intro == null || book.intro!.isEmpty) ||
      book.tocUrl.isEmpty;

  /// 按 origin（书源 URL）查找对应书源（供 webbookInfo/webbookChapters 传参）
  Future<BookSource?> _findSourceByOrigin(BookApi api, String origin) async {
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == origin) return s;
      }
    } catch (e) {
      debugPrint('获取书源失败: $e');
    }
    return null;
  }

  /// 合并 webbookInfo 返回的详情到 book（WebBookInfo 为 snake_case，需手动映射，
  /// 不能直接 Book.fromJson 否则 cover_url/toc_url 等丢失）；仅补全当前缺失字段。
  Book _mergeWebInfo(Book book, String infoJson) {
    final decoded = jsonDecode(infoJson);
    if (decoded is! Map) return book;
    String? pick(String key) {
      final v = decoded[key];
      return (v is String && v.isNotEmpty) ? v : null;
    }

    final hasCover = book.coverUrl != null && book.coverUrl!.isNotEmpty;
    final hasIntro = book.intro != null && book.intro!.isNotEmpty;
    final hasWord = book.wordCount != null && book.wordCount!.isNotEmpty;
    final hasLast =
        book.latestChapterTitle != null && book.latestChapterTitle!.isNotEmpty;
    final hasKind = book.kind != null && book.kind!.isNotEmpty;
    final tocUrl = pick('toc_url');
    final name = pick('name');
    final author = pick('author');
    return book.copyWith(
      coverUrl: hasCover ? book.coverUrl : pick('cover_url'),
      intro: hasIntro ? book.intro : pick('intro'),
      tocUrl: book.tocUrl.isNotEmpty ? book.tocUrl : (tocUrl ?? book.tocUrl),
      wordCount: hasWord ? book.wordCount : pick('word_count'),
      latestChapterTitle: hasLast ? book.latestChapterTitle : pick('last_chapter'),
      kind: hasKind ? book.kind : pick('kind'),
      name: book.name.isNotEmpty ? book.name : (name ?? book.name),
      author: book.author.isNotEmpty ? book.author : (author ?? book.author),
    );
  }

  /// 解析 webbookChapters 返回的 WebChapter 数组（snake_case）为展示用章节列表
  List<BookChapter> _parseWebChapters(String json, String bookUrl) {
    final decoded = jsonDecode(json);
    if (decoded is! List) return const [];
    return [
      for (final e in decoded)
        if (e is Map)
          BookChapter(
            index: (e['index'] as num?)?.toInt() ?? 0,
            title: e['title']?.toString() ?? '',
            url: e['url']?.toString() ?? '',
            bookUrl: bookUrl,
            isVolume: e['is_volume'] == true,
            isVip: e['is_vip'] == true,
          ),
    ];
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
          // 编辑：仅在架书籍显示（对标原版 editMenuItem.isVisible = inBookshelf）
          if (_inBookshelf)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: '编辑书籍信息',
              onPressed: () async {
                try {
                  final data = await _future;
                  final book = data.book;
                  if (book == null) return;
                  if (!context.mounted) return;
                  // [fix Task#24 | 2026-08-08] 去掉 <bool> 泛型，避免 routes 表
                  // MaterialPageRoute<dynamic> 运行时强转崩溃 — Qoder
                  final saved = await Navigator.pushNamed(
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
            icon: const Icon(Icons.ios_share),
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
          // 安卓原版三点菜单（book_info.xml，条目顺序/可见性对齐原版）
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) {
              // [UI-fix v2.0.3 | 2026-08-06] 菜单条目顺序/可见性对齐原版
              // book_info.xml + onMenuOpened 判定逻辑 — Qoder
              final book = _loadedBook;
              final source = _bookSource;
              final hasSource = source != null;
              final isLocal = book != null && !_isOnlineBook(book);
              final isLocalTxt = isLocal; // 本地书视为可拆分长章节候选
              final hasLogin = (source?.loginUrl ?? '').isNotEmpty;
              final canUpd = book?.canUpdate ?? true;
              return [
                // 上传至远程（仅本地书；_todo 占位）
                if (isLocal)
                  const PopupMenuItem(value: 'upload', child: Text('上传至远程')),
                const PopupMenuItem(value: 'refresh', child: Text('刷新')),
                // 创建书籍更新任务（在架 + 书源 + 非本地 + 允许更新；_todo 占位）
                if (_inBookshelf && hasSource && !isLocal && canUpd)
                  const PopupMenuItem(
                    value: 'updateTask',
                    child: Text('创建书籍更新任务'),
                  ),
                // 登录（书源支持登录时）
                if (hasLogin)
                  const PopupMenuItem(value: 'login', child: Text('登录')),
                const PopupMenuItem(value: 'top', child: Text('置顶')),
                // 设置源变量 / 设置书籍变量（书源存在；_todo 占位）
                if (hasSource)
                  const PopupMenuItem(
                    value: 'sourceVariable',
                    child: Text('设置源变量'),
                  ),
                if (hasSource)
                  const PopupMenuItem(
                    value: 'bookVariable',
                    child: Text('设置书籍变量'),
                  ),
                const PopupMenuItem(
                    value: 'copyBookUrl', child: Text('拷贝书籍URL')),
                const PopupMenuItem(
                    value: 'copyTocUrl', child: Text('拷贝目录URL')),
                // 允许更新（书源存在；勾选态）
                if (hasSource)
                  CheckedPopupMenuItem(
                    value: 'canUpdate',
                    checked: book?.canUpdate ?? true,
                    child: const Text('允许更新'),
                  ),
                // 拆分长章节（仅本地 txt；勾选态）
                if (isLocalTxt)
                  CheckedPopupMenuItem(
                    value: 'splitLongChapter',
                    // isLocalTxt 已隐含 book != null（由 isLocal 推导），book 已提升为非空
                    checked: book.readConfig?.splitLongChapter ?? true,
                    child: const Text('拆分长章节'),
                  ),
                // [UI-fix v2.0.3 | 2026-08-08] 删除提醒接通本地持久化
                // （对齐原版 LocalConfig.deleteBookAlert） — Qoder
                CheckedPopupMenuItem(
                  value: 'deleteAlert',
                  checked: _deleteBookAlert,
                  child: const Text('删除提醒'),
                ),
                const PopupMenuItem(
                    value: 'clearCache', child: Text('清理缓存')),
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

  /// 页面主体：封面高斯虚化背景（iOS 沉浸深度）+ 半透明 scrim —— 内容叠层
  Widget _buildPage(BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    final coverUrl = book.customCoverUrl ?? book.coverUrl;
    final hasCover = coverUrl != null && coverUrl.isNotEmpty;
    return Stack(
      fit: StackFit.expand,
      children: [
        // [UI-fix v2.0.3 | 2026-08-06] 封面高斯虚化作背景层（sigma 25），
        // 营造 iOS 沉浸景深；无封面降级纯色背景不加模糊 — Qoder
        if (hasCover)
          ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 25, sigmaY: 25),
            child: CachedNetworkImage(imageUrl: coverUrl, fit: BoxFit.cover),
          )
        else
          ColoredBox(color: cs.surfaceContainerHighest),
        // [审计修复 §3.3] scrim 叠层改用 colorScheme.scrim Token，
        // 透明度对齐原版 vw_bg #50000000（虚化后仍保留以保标题/封面可读） — Qoder
        ColoredBox(
          color: cs.scrim.withValues(alpha: 0x50 / 0xFF),
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
        // 对齐原版：刷新即含目录更新（在线书走 refreshToc，本地书仅重加载）
        if (book != null && _isOnlineBook(book)) {
          await _refreshToc();
        } else {
          setState(() => _future = _loadData());
        }
        break;
      case 'copyBookUrl':
        if (book != null) {
          await Clipboard.setData(ClipboardData(text: book.bookUrl));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已拷贝书籍URL')));
          }
        }
        break;
      case 'copyTocUrl':
        if (book != null) {
          await Clipboard.setData(ClipboardData(text: book.tocUrl));
          if (mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(const SnackBar(content: Text('已拷贝目录URL')));
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
      case 'deleteAlert':
        // [UI-fix v2.0.3 | 2026-08-08] 删除提醒开关持久化（对齐原版
        // LocalConfig.deleteBookAlert：删除/移出书籍时是否弹确认框） — Qoder
        final next = !_deleteBookAlert;
        await _settingsService.setDeleteBookAlert(next);
        if (mounted) setState(() => _deleteBookAlert = next);
        break;
      default:
        _todo(value);
        break;
    }
  }

  /// 未移植功能提示（占位项，待后续版本对齐原版）
  void _todo(String value) {
    const names = {
      'upload': '上传至远程',
      'updateTask': '创建书籍更新任务',
      'sourceVariable': '设置源变量',
      'bookVariable': '设置书籍变量',
    };
    final feature = names[value] ?? value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  Widget _buildBody(BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    // [UI-fix v2.0.6 | 2026-08-08] 移除详情页内嵌「搜索章节」框与完整章节列表，
    // 对齐原版 activity_book_info（详情页不含目录列表，目录由 tv_toc_view 跳转
    // 独立 TocActivity 查看）。详情页仅保留封面卡 + 信息面板（含目录行显示当前
    // 章节名 + 查看目录按钮）。封面虚化背景层（见 _buildPage）仅透过顶部透明的
    // _buildHeader 封面区显现；信息面板起铺不透明 cs.surface 盖住虚化，底部用
    // SliverFillRemaining 续铺纯色，避免短内容时下方透出虚化封面。 — Qoder
    return CustomScrollView(
      controller: _scrollController,
      slivers: [
        // 封面卡（对标原版 ArcView + CardView 110x160 居中）
        SliverToBoxAdapter(child: _buildHeader(context, book)),
        // 信息面板：书名/字数标签/摘要行/简介（对标原版 ll_info）
        SliverToBoxAdapter(
          child: _buildSummaryPanel(context, book, chapters),
        ),
        // 底部续铺纯色：内容不足一屏时填满剩余视口，避免透出封面虚化层
        SliverFillRemaining(
          hasScrollBody: false,
          child: Container(color: cs.surface),
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

  /// 信息面板（对标原版 ll_info：书名 18sp 居中 + 标签栏 + 摘要行 + 简介）
  Widget _buildSummaryPanel(
      BuildContext context, Book book, List<BookChapter> chapters) {
    final cs = Theme.of(context).colorScheme;
    final latest = (book.latestChapterTitle ?? '').isNotEmpty
        ? '最新：${book.latestChapterTitle}'
        : '共 ${book.totalChapterNum} 章';
    // [UI-fix v2.0.6 | 2026-08-08] 目录行标题对齐原版（当前章节名）+ 字数标签 — Qoder
    final tocTitle = _resolveTocTitle(book, chapters);
    final wordCount = (book.wordCount ?? '').trim();
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
          // 书名：SF Pro 大标题风格（居中单行，对标 tv_name，行高/负字距提升质感）
          Text(
            book.name,
            maxLines: 2,
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              height: 1.15,
              color: cs.onSurface,
            ),
          ),
          // 标签栏（对标 lb_kind + 字数标签 tv_word_count）
          // [UI-fix v2.0.6 | 2026-08-08] 补齐字数标签（红色胶囊置于分类标签前，
          // 对齐原版 711万字 醒目标签） — Qoder
          if (wordCount.isNotEmpty || kinds.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                if (wordCount.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      wordCount,
                      style: TextStyle(
                          fontSize: 11, color: cs.onErrorContainer),
                    ),
                  ),
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
          // [UI-fix v2.0.6 | 2026-08-08] 按钮文案「换组」→「设置分组」对齐原版
          // change_group="Group settings"（点击设置该书所属分组，行为不变） — Qoder
          _summaryRow(context, Icons.groups_outlined, _groupText(book),
              action: _smallAction(context, '设置分组', _showChangeGroup)),
          // 目录行（对标 ll_toc：ic_folder_open + tv_toc + tv_toc_view）
          // [UI-fix v2.0.6 | 2026-08-08] 对齐原版：显示当前章节名
          // （resolveBookInfoTocTitle：durChapterTitle 优先，否则按 durChapterIndex
          // 取章、末章兜底）+「查看目录」按钮跳独立 TocScreen（不再内嵌章节列表） — Qoder
          _summaryRow(
            context,
            Icons.folder_open,
            '目录：$tocTitle',
            action: _smallAction(context, '查看目录', _openTocScreen),
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
          // [UI-fix v2.0.3 | 2026-08-08] lint：改用 null-aware 元素语法 — Qoder
          ?action,
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

  /// 目录行标题（对齐原版 BookInfoActivity.resolveBookInfoTocTitle）：
  /// durChapterTitle 非空优先，否则按 durChapterIndex 取章、末章兜底
  /// [UI-fix v2.0.6 | 2026-08-08] — Qoder
  String _resolveTocTitle(Book book, List<BookChapter> chapters) {
    final stored = (book.durChapterTitle ?? '').trim();
    if (stored.isNotEmpty) return stored;
    BookChapter? ch;
    final idx = book.durChapterIndex;
    if (idx >= 0 && idx < chapters.length) {
      ch = chapters[idx];
    } else if (chapters.isNotEmpty) {
      ch = chapters.last;
    }
    final title = (ch?.title ?? '').trim();
    return title.isNotEmpty ? title : '暂无最新章节';
  }

  Widget _buildIntro(BuildContext context, Book book) {
    final raw = book.customIntro ?? book.intro;
    if (raw == null || raw.isEmpty) return const SizedBox.shrink();
    // [UI-fix v2.0.7 | 2026-08-08] 展示层清洗：剥离书源 intro 自带的「简介：」前缀
    // （原版直接显示正文无前缀），清洗后为空则不渲染简介区 — Qoder
    final intro = _cleanIntro(raw);
    if (intro.isEmpty) return const SizedBox.shrink();
    return _ExpandableText(text: intro);
  }

  /// 清洗简介正文：剥离开头的「简介：」「简介 :」等前缀
  /// （兼容全/半角冒号及前后空白，仅剥离一次；对齐原版无前缀直接显示正文）
  /// [UI-fix v2.0.7 | 2026-08-08] — Qoder
  String _cleanIntro(String raw) {
    return raw.replaceFirst(
      RegExp(r'^[\s\u3000]*简介[\s\u3000]*[：:][\s\u3000]*'),
      '',
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

  /// 打开独立目录页（对齐原版 tv_toc_view → TocActivityResult），
  /// 返回选中章节 index 后走现有阅读跳转链路
  /// [UI-fix v2.0.3 | 2026-08-08] 模块 E：目录入口改造 — Qoder
  Future<void> _openTocScreen() async {
    final book = _loadedBook;
    if (book == null) return;
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.toc,
      arguments: book,
    );
    if (!mounted) return;
    if (result is int) {
      await _openReader(context, book, result);
    }
  }

  /// 加入书架 / 移出书架（对标原版 tv_shelf 切换逻辑）
  Future<void> _toggleShelf(Book book) async {
    final notifier = ref.read(bookshelfNotifierProvider.notifier);
    if (_inBookshelf) {
      // [UI-fix v2.0.3 | 2026-08-08] 移出书架按「删除提醒」开关弹确认框
      // （对齐原版 deleteBook + LocalConfig.deleteBookAlert） — Qoder
      if (_deleteBookAlert) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('移出书架'),
            content: Text('确定将《${book.name}》移出书架吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
      }
      await notifier.removeBook(book.bookUrl);
      if (!mounted) return;
      setState(() => _inBookshelf = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('《${book.name}》已移出书架')),
      );
    } else {
      // 清除 notShelf 位转正：之前阅读时可能已以 notShelf 临时落库，
      // addBook 走原地 UPDATE 安全 upsert（不会级联删章节），同时清掉标记进书架。
      await notifier
          .addBook(book.copyWith(bookType: book.bookType & ~BookType.notShelf));
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

  // ===== 操作 =====

  Future<void> _openReader(
      BuildContext context, Book book, int chapterIndex) async {
    // [UI-fix v2.0.3 | 2026-08-06] 对齐原版 readBook：未入库在线书阅读前先落库 — Qoder
    // 带正确 origin 落库，使阅读器 DB 依赖成立（get_chapter_content_full 按
    // book.origin 找书源取正文），规避「章节不存在 / 未配置书源」；已入库则幂等跳过。
    final api = ref.read(bookApiProvider);
    try {
      if (_isOnlineBook(book)) {
        final existing = await api.getBook(book.bookUrl);
        if (existing == null) {
          // 以 notShelf 位标记临时落库：阅读器 DB 依赖成立（按 origin 取正文），
          // 但不进书架列表；用户显式「加入书架」时再清标记转正（见 _toggleShelf）。
          await api.addBook(
              book.copyWith(bookType: book.bookType | BookType.notShelf));
        }
      }
    } catch (e) {
      debugPrint('阅读前落库失败: $e');
    }
    if (!context.mounted) return;
    final container = ProviderScope.containerOf(context);
    final bookToRead = chapterIndex != book.durChapterIndex
        ? book.copyWith(durChapterIndex: chapterIndex)
        : book;
    container.read(readerNotifierProvider.notifier).openBook(bookToRead);
    Navigator.pushNamed(context, AppRoutes.reader);
  }

  /// 打开换源页面，换源成功后用新的 bookUrl 重新加载详情页
  Future<void> _showChangeSourceDialog(Book book) async {
    // [fix Task#24 | 2026-08-08] routes 表统一生成 MaterialPageRoute<dynamic>，
    // pushNamed<String> 会触发运行时强转崩溃
    // （'MaterialPageRoute<dynamic>' is not a subtype of 'Route<String?>?'），
    // 表现为点「换源」无任何反应。改用无类型 pushNamed + is 判定（与 _openTocScreen 一致）— Qoder
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.changeSource,
      arguments: book,
    );
    if (!mounted) return;
    final newBookUrl = result is String ? result : null;
    // 换源成功后 bookUrl 会变化，需要用新 URL 替换当前详情页
    if (newBookUrl != null && newBookUrl.isNotEmpty) {
      Navigator.pushReplacementNamed(
        context,
        AppRoutes.bookInfo,
        arguments: book.copyWith(bookUrl: newBookUrl),
      );
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

  /// 折叠态显示行数（对齐原版折叠约 3 行）
  static const int _collapsedLines = 3;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      // [UI-fix v2.0.7 | 2026-08-08] 用 TextPainter 预测折叠态是否真的截断正文：
      // 仅在超过 _collapsedLines 行时才显示「展开/收起」控件，短简介整段直接显示
      // （按内容自适应，替代此前 length>100 的粗略字数阈值——后者会漏判「刚好
      // 超 3 行但不足百字」的简介，导致尾部被省略号截断却无展开入口） — Qoder
      child: LayoutBuilder(
        builder: (context, constraints) {
          final painter = TextPainter(
            text: TextSpan(text: widget.text, style: style),
            maxLines: _collapsedLines,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth);
          final showToggle = painter.didExceedMaxLines;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // [UI-fix v2.0.7 | 2026-08-08] 移除「简介」标题 heading：对齐原版
              // 无标签、直接显示简介正文 — Qoder
              AnimatedCrossFade(
                firstChild: Text(
                  widget.text,
                  maxLines: _collapsedLines,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
                secondChild: Text(widget.text, style: style),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),
              // [UI-fix v2.0.7 | 2026-08-08] 展开/收起：右对齐 + 主题色文字，
              // 对齐原版底部右下角切换控件（省略号硬截断改为可展开/收起） — Qoder
              if (showToggle)
                Align(
                  alignment: Alignment.centerRight,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _expanded = !_expanded),
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _expanded ? '收起' : '展开',
                        style: TextStyle(color: cs.primary, fontSize: 13),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
