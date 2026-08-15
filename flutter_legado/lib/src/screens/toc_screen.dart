import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/models.dart';
import '../providers/bookmark/bookmark_notifier.dart';
import '../providers/providers.dart';
import '../routes.dart';
import '../services/book_api.dart';
import '../services/bookmark_export.dart';
import '../services/settings_service.dart';
import '../utils/app_route_observer.dart';
import '../utils/book_open_utils.dart';

/// 独立目录页（对齐原版 TocActivity + ChapterListFragment/BookmarkFragment/HighlightFragment）
///
/// [UI-fix v2.0.3 | 2026-08-08] 模块 D：新建独立目录页 — Qoder
/// - 三 Tab：目录 / 书签 / 标注（对齐原版 TabFragmentPageAdapter）
/// - 目录 Tab：卷分组样式、当前章节高亮 + 自动定位、章节字数（受「加载字数」开关控制）、
///   底部当前章节信息条 + 跳转顶部/底部
/// - 书签/标注 Tab：数据经 BookApi（bookmarkNotifier / highlightListByBook）
/// - 溢出菜单对齐 book_toc.xml 顺序与条件显隐（随 Tab 切换，对齐 TocActivity.onMenuOpened）
/// - 返回值：选中章节 index（int），供调用方走现有阅读跳转链路
/// - 章节缓存状态云图标：经 BookApi.listCachedChapterUrls（Rust
///   cache_list_cached_chapter_urls FFI）查询 cached_chapters 已缓存 chapter_url
///   集合，据此为每章渲染实心/空心云（[UI-fix v2.0.6 | 2026-08-08] Task #22）
class TocScreen extends ConsumerStatefulWidget {
  /// 书籍对象（路由参数规范化：优先使用 Book 对象）
  final Book book;

  const TocScreen({super.key, required this.book});

  @override
  ConsumerState<TocScreen> createState() => _TocScreenState();
}

class _TocScreenState extends ConsumerState<TocScreen>
    with SingleTickerProviderStateMixin, RouteAware {
  /// 目录章节行估算高度（ListView.builder itemExtent，供初次进入按 index 定位）
  static const double _chapterRowExtent = 48;

  late final TabController _tabController;
  final ScrollController _tocScrollController = ScrollController();
  final TextEditingController _searchCtrl = TextEditingController();
  SettingsService get _settings => ref.read(settingsProvider);

  /// 搜索防抖计时器（300ms，对齐任务规范）
  Timer? _debounce;

  /// 是否处于搜索态（AppBar 标题切换为搜索框）
  bool _searching = false;

  /// 当前搜索关键词（防抖后生效，三 Tab 共用，对齐原版 viewModel.searchKey）
  String _searchKey = '';

  /// 倒序目录（纯本地显示序反转，对齐原版 menu_reverse_toc 语义的展示部分）
  bool _reverseToc = false;

  /// 加载字数开关（本地持久化，对齐原版 AppConfig.tocCountWords）
  bool _loadWordCount = true;

  /// 当前书籍（菜单勾选项更新后刷新，如 useReplaceRule/splitLongChapter）
  late Book _book;

  /// 是否在架（对标原版 inBookshelf；未在架时不 refreshToc 落库）
  bool _inBookshelf = false;

  /// 章节列表（含卷行）
  List<BookChapter> _chapters = [];
  bool _chaptersLoading = true;
  String? _chaptersError;

  /// 已缓存章节的 chapter_url 集合（目录页云图标缓存态，
  /// 经 BookApi.listCachedChapterUrls）
  Set<String> _cachedChapterUrls = {};

  /// 缓存态轮询定时器（页面可见期间每 2s 轻量查询，实现云图标实时刷新；
  /// 对齐原版 EventBus.SAVE_CONTENT 实时语义）
  /// [UI-fix v2.0.16 | 2026-08-10] 下载进行中目录页图标即时变实心 — Reasonix
  Timer? _cachePollTimer;
  /// 标注列表（BookHighlight JSON 解析后的 Map，经 BookApi.highlightListByBook）
  List<Map<String, dynamic>> _highlights = [];
  bool _highlightsLoading = true;
  String? _highlightsError;

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _tabController = TabController(length: 3, vsync: this)
      // Tab 切换需刷新溢出菜单条件显隐与底部信息条（对齐原版 onMenuOpened）
      ..addListener(() {
        if (mounted) setState(() {});
      });
    _initBookshelfState();
    _loadSettings();
    _loadHighlights();
    // 在线书启动缓存态轮询（本地 SQLite 轻量查询；页面销毁自动停止）
    if (_book.origin != BookType.localTag) {
      _cachePollTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _refreshCachedUrls(),
      );
    }
    // 书签按书名+作者加载（对齐原版 bookmarkDao.getByBook，规避同名书混入，
    // 契约 §2.7 getBookmarksByBook，台账 §5.14-2，Task #65）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(bookmarkNotifierProvider.notifier)
          .loadByBook(_book.name, _book.author);
    });
  }

  /// 初始化在架状态（DB 有记录且非 notShelf / refresh_toc 占位）
  Future<void> _initBookshelfState() async {
    try {
      final dbBook =
          await ref.read(bookApiProvider).getBook(_book.bookUrl);
      if (!mounted) return;
      setState(() {
        _inBookshelf =
            BookOpenUtils.resolveInBookshelf(dbBook, widget.book);
      });
    } catch (_) {
      // 查询失败视为未在架，避免误 refreshToc 落库
    }
    await _loadChapters();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // [UI-fix v2.0.7 | 2026-08-09] Task #26：订阅全局路由观察器，
    // 从阅读器返回本页（didPopNext）时刷新缓存云图标/当前章节
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    _cachePollTimer?.cancel();
    appRouteObserver.unsubscribe(this);
    _debounce?.cancel();
    _tabController.dispose();
    _tocScrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 缓存态轮询刷新（轻量查询；列表变化才 setState，避免无谓重建）
  Future<void> _refreshCachedUrls() async {
    try {
      final api = ref.read(bookApiProvider);
      final cached =
          (await api.listCachedChapterUrls(_book.bookUrl)).toSet();
      if (!mounted) return;
      if (cached.length != _cachedChapterUrls.length ||
          !cached.containsAll(_cachedChapterUrls)) {
        setState(() => _cachedChapterUrls = cached);
      }
    } catch (_) {
      // 查询失败静默（保持旧状态，下一轮重试）
    }
  }

  /// [UI-fix v2.0.7 | 2026-08-09] Task #26：页面重现（从阅读器返回）时刷新。
  /// 对齐原版 ChapterListFragment 经 EventBus.SAVE_CONTENT 增量刷新语义：
  /// 阅读过程写入 cached_chapters 的章节云图标应变实心，同时同步书籍
  /// 进度（durChapterIndex/Title）使当前章对勾与底部信息条不陈旧。
  @override
  void didPopNext() {
    _refreshOnReshow();
  }

  Future<void> _refreshOnReshow() async {
    try {
      final api = ref.read(bookApiProvider);
      final cached =
          (await api.listCachedChapterUrls(_book.bookUrl)).toSet();
      final fresh = await api.getBook(_book.bookUrl);
      if (!mounted) return;
      setState(() {
        _cachedChapterUrls = cached;
        if (fresh != null) _book = fresh;
      });
    } catch (_) {
      // 刷新失败不阻断展示，保持旧状态
    }
  }

  /// 加载「加载字数」开关（本地持久化）
  Future<void> _loadSettings() async {
    final v = await _settings.getTocLoadWordCount();
    if (mounted) setState(() => _loadWordCount = v);
  }

  /// 加载章节列表（经 BookApi），完成后自动滚动定位当前章节
  Future<void> _loadChapters() async {
    setState(() {
      _chaptersLoading = true;
      _chaptersError = null;
    });
    try {
      final api = ref.read(bookApiProvider);
      var chapters = await api.getChapters(_book.bookUrl);
      // [Task #21 | 2026-08-08] 自愈：本地库无目录的在线书籍（含换源后旧章节
      // 已清、或历史遗留未拉取过目录的书），自动经书源规则从网络刷新目录。
      // 与 reader_notifier.openBook 的回退保持一致，使打开目录页时也能触发
      // 目录获取，修复用户反馈的「目录也获取不到」。refresh_toc 内部以书籍
      // tocUrl 为抓取地址（换源后指向当前书源），tocUrl 空时回退 bookUrl。
      if (chapters.isEmpty && _book.origin.isNotEmpty) {
        if (_inBookshelf) {
          chapters = await api.refreshToc(_book.bookUrl, _book.origin);
        } else {
          // 未入库：仅网络取目录展示，不落库（对齐 BookInfoScreen / 原版 !inBookshelf）
          chapters = await _fetchWebChaptersOnline(api);
        }
      }
      if (!mounted) return;
      // [UI-fix v2.0.6 | 2026-08-08] Task #22：加载已缓存章节 url 集合，供每章
      // 渲染云图标；查询失败不阻断目录展示（降级为全部未缓存态）
      Set<String> cached = {};
      try {
        cached = (await api.listCachedChapterUrls(_book.bookUrl)).toSet();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _cachedChapterUrls = cached;
        _chaptersLoading = false;
      });
      // 初次进入自动滚动定位当前章节（按 index 估算偏移）
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToChapter(_book.durChapterIndex);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _chaptersError = _errMsg(e);
        _chaptersLoading = false;
      });
    }
  }

  /// 加载标注列表（经 BookApi.highlightListByBook，返回 BookHighlight 数组 JSON）
  Future<void> _loadHighlights() async {
    setState(() {
      _highlightsLoading = true;
      _highlightsError = null;
    });
    try {
      final api = ref.read(bookApiProvider);
      final json = await api.highlightListByBook(bookUrl: _book.bookUrl);
      final decoded = jsonDecode(json);
      if (!mounted) return;
      setState(() {
        _highlights = decoded is List
            ? decoded
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
            : <Map<String, dynamic>>[];
        _highlightsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _highlightsError = _errMsg(e);
        _highlightsLoading = false;
      });
    }
  }

  /// 未入库在线书：webbookChapters 仅展示，不写 DB
  Future<List<BookChapter>> _fetchWebChaptersOnline(BookApi api) async {
    BookSource? source;
    try {
      final sources = await api.getBookSources();
      final o = _book.origin.trim().replaceAll(RegExp(r'/+$'), '');
      for (final s in sources) {
        final u = s.bookSourceUrl.trim().replaceAll(RegExp(r'/+$'), '');
        if (u == o || s.bookSourceUrl == _book.origin) {
          source = s;
          break;
        }
      }
    } catch (_) {
      return const [];
    }
    if (source == null) return const [];
    try {
      final chJson = await api.webbookChapters(
        jsonEncode(source.toJson()),
        _book.bookUrl,
        tocUrl: _book.tocUrl,
        bookName: _book.name,
      );
      return BookOpenUtils.parseWebChapters(chJson, _book.bookUrl);
    } catch (e) {
      debugPrint('webbookChapters 错误: ${_errMsg(e)}');
      return const [];
    }
  }

  /// 提取错误信息（BridgeError 等封装类型带 message 字段）
  String _errMsg(Object e) {
    try {
      final m = (e as dynamic).message;
      if (m is String && m.isNotEmpty) return m;
    } catch (_) {}
    return e.toString();
  }

  // ===== 书籍类型判定（对齐原版 isLocal/isLocalTxt） =====

  /// 本地书（含 WebDAV 导入，对齐原版 Book.isLocal）
  bool get _isLocal =>
      _book.origin == BookType.localTag ||
      _book.origin.startsWith(BookType.webDavTag);

  /// 本地 TXT 书（对齐原版 Book.isLocalTxt，控制 TXT 目录规则/拆分长章节显隐）
  bool get _isLocalTxt =>
      _isLocal &&
      (_book.originName.toLowerCase().endsWith('.txt') ||
          _book.bookUrl.toLowerCase().endsWith('.txt'));

  // ===== 目录展示列表（搜索过滤 + 倒序，保留原始章节 index 供跳转） =====

  /// 展示条目：(原始列表位置, 章节)
  List<MapEntry<int, BookChapter>> get _displayEntries {
    final query = _searchKey.trim().toLowerCase();
    var entries = _chapters.asMap().entries.toList();
    if (query.isNotEmpty) {
      entries = entries
          .where((e) => e.value.title.toLowerCase().contains(query))
          .toList();
    }
    if (_reverseToc) {
      entries = entries.reversed.toList();
    }
    return entries;
  }

  /// 滚动定位到指定章节 index（按展示列表位置 * 行高估算偏移）
  void _scrollToChapter(int chapterIndex) {
    if (!_tocScrollController.hasClients) return;
    final entries = _displayEntries;
    final displayIndex =
        entries.indexWhere((e) => e.value.index == chapterIndex);
    if (displayIndex < 0) return;
    final offset = (displayIndex * _chapterRowExtent).clamp(
      0.0,
      _tocScrollController.position.maxScrollExtent,
    );
    _tocScrollController.jumpTo(offset);
  }

  // ===== 搜索（300ms 防抖） =====

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _searchKey = text);
    });
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchCtrl.clear();
        _searchKey = '';
        _debounce?.cancel();
      }
    });
  }

  // ===== 溢出菜单（对齐 book_toc.xml 顺序 + TocActivity.onMenuOpened 条件显隐） =====

  List<PopupMenuEntry<String>> _buildMenuItems() {
    final tab = _tabController.index;
    final items = <PopupMenuEntry<String>>[];
    if (tab == 0) {
      // menu_group_text：仅本地 TXT 书可见（对齐原版 isLocalTxt 判定）
      if (_isLocalTxt) {
        items.add(const PopupMenuItem(
            value: 'tocRegex', child: Text('TXT 目录规则')));
        items.add(CheckedPopupMenuItem(
          value: 'splitLongChapter',
          checked: _book.readConfig?.splitLongChapter ?? true,
          child: const Text('拆分长章节'),
        ));
      }
      // menu_group_toc：目录 Tab 可见
      items.add(const PopupMenuItem(value: 'reverseToc', child: Text('倒序目录')));
      items.add(CheckedPopupMenuItem(
        value: 'useReplace',
        // useReplaceRule 存于 ReadConfig（对齐原版 Book.ReadConfig.useReplaceRule）
        checked: _book.readConfig?.useReplaceRule ?? true,
        child: const Text('使用替换规则'),
      ));
      items.add(CheckedPopupMenuItem(
        value: 'loadWordCount',
        checked: _loadWordCount,
        child: const Text('加载字数'),
      ));
    } else if (tab == 1) {
      // menu_group_bookmark：书签 Tab 可见
      items.add(const PopupMenuItem(
          value: 'exportBookmark', child: Text('导出')));
      items.add(const PopupMenuItem(
          value: 'exportMd', child: Text('导出 Markdown')));
    }
    // menu_log：始终可见
    items.add(const PopupMenuItem(value: 'log', child: Text('日志')));
    return items;
  }

  Future<void> _handleMenu(String value) async {
    switch (value) {
      case 'tocRegex':
        // 跳转已有 TXT 目录规则页（对齐原版 menu_toc_regex → TxtTocRuleDialog）
        Navigator.pushNamed(context, AppRoutes.txtTocRules);
        break;
      case 'splitLongChapter':
        // 拆分长章节存于 ReadConfig（参照 book_info_screen 已有实现）
        final cfg = _book.readConfig ?? const ReadConfig();
        final updated = _book.copyWith(
          readConfig: cfg.copyWith(splitLongChapter: !cfg.splitLongChapter),
        );
        await _updateBook(updated);
        // 对齐原版 upBookAndToc：切换后需重载目录
        await _loadChapters();
        break;
      case 'reverseToc':
        // 纯 Dart 本地反转显示序（对齐原版 menu_reverse_toc 展示语义）
        setState(() => _reverseToc = !_reverseToc);
        break;
      case 'useReplace':
        // 接 ReadConfig.useReplaceRule 字段经 BookApi 更新（对齐原版 menu_use_replace）
        final rc = _book.readConfig ?? const ReadConfig();
        await _updateBook(_book.copyWith(
          readConfig: rc.copyWith(
            useReplaceRule: !(rc.useReplaceRule ?? true),
          ),
        ));
        break;
      case 'loadWordCount':
        // 本地持久化并即时刷新字数显隐（对齐原版 menu_load_word_count）
        final next = !_loadWordCount;
        await _settings.setTocLoadWordCount(next);
        if (mounted) setState(() => _loadWordCount = next);
        break;
      case 'exportBookmark':
        // [Task #40 | 2026-08-09] §5.11-5 接线：导出书签 JSON
        //（对齐原版 menu_export_bookmark → TocViewModel.saveBookmark） — Qoder
        await _exportBookmarks(asMarkdown: false);
        break;
      case 'exportMd':
        // [Task #40 | 2026-08-09] §5.11-5 接线：导出 Markdown
        //（对齐原版 menu_export_bookmark_md → saveBookmarkMd） — Qoder
        await _exportBookmarks(asMarkdown: true);
        break;
      case 'log':
        Navigator.pushNamed(context, AppRoutes.appLog);
        break;
    }
  }

  /// 导出书签（JSON / Markdown 双格式，对齐原版 TocViewModel.saveBookmark/
  /// saveBookmarkMd 交互流程：菜单触发 → 选目录 → 写文件 → Toast 结果）
  /// [Task #40 | 2026-08-09] §5.11-5 — Qoder
  Future<void> _exportBookmarks({required bool asMarkdown}) async {
    try {
      // 书签数据经 BookApi.getBookmarksByBook 获取（契约 §2.7，台账
      // §5.14-2 Task #65：按书名+作者查询，规避同名书混入）
      final bookmarks = await ref
          .read(bookApiProvider)
          .getBookmarksByBook(_book.name, _book.author);
      if (!mounted) return;
      if (bookmarks.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('暂无书签可导出')));
        return;
      }
      // 「默认书籍保存位置」已设置时作为目录选择器初始路径
      final initialDir = await _settings.getStringPref(
        PrefKeys.defaultBookTreeUri,
      );
      if (!mounted) return;
      final savedPath = asMarkdown
          ? await BookmarkExport.exportMarkdown(
              book: _book,
              bookmarks: bookmarks,
              initialDirectory: initialDir,
            )
          : await BookmarkExport.exportJson(
              book: _book,
              bookmarks: bookmarks,
              initialDirectory: initialDir,
            );
      if (!mounted) return;
      // 用户取消目录选择时静默返回（对齐原版 SAF 取消语义）
      if (savedPath == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出成功: $savedPath')),
      );
    } catch (e) {
      // 写入失败给出可读错误（对齐原版 AppLog.put「导出失败」提示语义）
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败: ${_errMsg(e)}')),
      );
    }
  }

  /// 经 BookApi 更新书籍并同步本页状态
  Future<void> _updateBook(Book updated) async {
    try {
      await ref.read(bookApiProvider).updateBook(updated);
      if (mounted) setState(() => _book = updated);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败: ${_errMsg(e)}')),
        );
      }
    }
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: LegadoAppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索...',
                  border: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
              )
            : Text(_book.name.isNotEmpty ? _book.name : '目录'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            tooltip: _searching ? '关闭搜索' : '搜索',
            onPressed: _toggleSearch,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) => _buildMenuItems(),
          ),
        ],
        // AppBar 内 TabBar 显式指定前景色，避免白底白字（项目规范）
        bottom: TabBar(
          controller: _tabController,
          // 全局 tabBarTheme 设了 TabAlignment.start，非 scrollable TabBar
          // 必须覆盖为 fill，否则触发断言崩溃（同 rss_source_edit_screen 先例）
          tabAlignment: TabAlignment.fill,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
          indicatorColor: cs.primary,
          tabs: const [
            Tab(text: '目录'),
            Tab(text: '书签'),
            Tab(text: '标注'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildChapterTab(context),
          _buildBookmarkTab(context),
          _buildHighlightTab(context),
        ],
      ),
      // 底部操作栏仅目录 Tab 显示（对齐原版 ll_chapter_base_info 属于 ChapterListFragment）
      bottomNavigationBar:
          _tabController.index == 0 ? _buildChapterInfoBar(context) : null,
    );
  }

  // ===== 目录 Tab =====

  Widget _buildChapterTab(BuildContext context) {
    if (_chaptersLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_chaptersError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(_chaptersError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadChapters, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_chapters.isEmpty) {
      return const Center(child: Text('暂无章节'));
    }
    final entries = _displayEntries;
    if (entries.isEmpty) {
      return const Center(child: Text('未找到匹配的章节'));
    }
    return ListView.builder(
      controller: _tocScrollController,
      itemExtent: _chapterRowExtent,
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final chapter = entries[i].value;
        return chapter.isVolume
            ? _buildVolumeRow(context, chapter)
            : _buildChapterRow(context, chapter);
      },
    );
  }

  /// 卷行：不可点、加粗 + 背景区分（对齐原版 item_chapter_group 样式语义）
  Widget _buildVolumeRow(BuildContext context, BookChapter chapter) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: cs.onSurface,
        ),
      ),
    );
  }

  /// 章节行：当前章节高亮；右侧缓存状态云图标 + 可选字数（受「加载字数」开关控制）
  /// [UI-fix v2.0.6 | 2026-08-08] Task #22：新增缓存状态云图标（对齐原版 iv_toc_cache） — Qoder
  Widget _buildChapterRow(BuildContext context, BookChapter chapter) {
    final cs = Theme.of(context).colorScheme;
    final isCurrent = chapter.index == _book.durChapterIndex;
    final wordCount = chapter.wordCount;
    final showWordCount =
        _loadWordCount && wordCount != null && wordCount.isNotEmpty;
    return ListTile(
      dense: true,
      selected: isCurrent,
      title: Text(
        chapter.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          color: isCurrent ? cs.primary : null,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showWordCount) ...[
            Text(
              '$wordCount 字',
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 8),
          ],
          _cacheStatusIcon(context, chapter, isCurrent),
        ],
      ),
      // 返回选中章节 index，由调用方走现有阅读跳转链路（对齐原版 openChapter setResult）
      onTap: () => Navigator.of(context).pop(chapter.index),
    );
  }

  /// 章节缓存状态图标（对齐原版 item_chapter_list 的 iv_toc_cache）：
  /// 当前阅读章 → 对勾高亮；已缓存 → 实心云；未缓存 → 空心云
  /// [UI-fix v2.0.6 | 2026-08-08] Task #22 — Qoder
  Widget _cacheStatusIcon(
      BuildContext context, BookChapter chapter, bool isCurrent) {
    final cs = Theme.of(context).colorScheme;
    if (isCurrent) {
      return Icon(Icons.check, size: 18, color: cs.primary);
    }
    final cached = _cachedChapterUrls.contains(chapter.url);
    return Icon(
      cached ? Icons.cloud_done : Icons.cloud_outlined,
      size: 18,
      color: cached ? cs.primary : cs.onSurfaceVariant,
    );
  }

  /// 底部操作栏：当前章节名（居左）+ 跳转顶部/底部（居右）
  /// 对齐原版 fragment_chapter_list 的 ll_chapter_base_info
  Widget _buildChapterInfoBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = _book.durChapterTitle ?? '';
    final info =
        '$title(${_book.durChapterIndex + 1}/${_chapters.length})';
    return SafeArea(
      top: false,
      child: Container(
        color: cs.surfaceContainer,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        height: 48,
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                // 点击当前章节信息条重新定位（对齐原版 tvCurrentChapterInfo 点击）
                onTap: () => _scrollToChapter(_book.durChapterIndex),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    info,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_top),
              tooltip: '跳转顶部',
              onPressed: () {
                if (_tocScrollController.hasClients) {
                  _tocScrollController.jumpTo(0);
                }
              },
            ),
            IconButton(
              icon: const Icon(Icons.vertical_align_bottom),
              tooltip: '跳转底部',
              onPressed: () {
                if (_tocScrollController.hasClients) {
                  _tocScrollController.jumpTo(
                      _tocScrollController.position.maxScrollExtent);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // ===== 书签 Tab（对齐原版 BookmarkFragment，样式复用 bookmark_screen） =====

  Widget _buildBookmarkTab(BuildContext context) {
    final state = ref.watch(bookmarkNotifierProvider);
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(state.error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref
                  .read(bookmarkNotifierProvider.notifier)
                  .loadByBook(_book.name, _book.author),
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final query = _searchKey.trim().toLowerCase();
    final bookmarks = query.isEmpty
        ? state.bookmarks
        : state.bookmarks
            .where((b) =>
                b.chapterName.toLowerCase().contains(query) ||
                b.bookText.toLowerCase().contains(query) ||
                b.content.toLowerCase().contains(query))
            .toList();
    if (bookmarks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(query.isEmpty ? '暂无书签' : '未找到匹配的书签'),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: bookmarks.length,
      itemBuilder: (context, index) {
        final bookmark = bookmarks[index];
        // 滑动删除（Dismissible）+ 长按删除双入口
        return Dismissible(
          key: ValueKey('bookmark_${bookmark.id}'),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Theme.of(context).colorScheme.error,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          confirmDismiss: (_) => _confirmDeleteBookmark(bookmark),
          onDismissed: (_) =>
              ref.read(bookmarkNotifierProvider.notifier).deleteBookmark(bookmark.id),
          child: _buildBookmarkTile(context, bookmark),
        );
      },
    );
  }

  /// 书签列表项（章节名/摘要/时间，复用 bookmark_screen 卡片样式）
  Widget _buildBookmarkTile(BuildContext context, Bookmark bookmark) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        // 点击跳转对应章节（返回 index 走调用方阅读链路）
        onTap: () => Navigator.of(context).pop(bookmark.chapterIndex),
        onLongPress: () async {
          final ok = await _confirmDeleteBookmark(bookmark);
          if (ok == true && mounted) {
            ref
                .read(bookmarkNotifierProvider.notifier)
                .deleteBookmark(bookmark.id);
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.bookmark,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      bookmark.chapterName,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // [Task #54 | 2026-08-10] 缺陷⑤修复：bookmark.time 已是
                  // epoch 毫秒，删除多余的 ×1000 换算 — Qoder
                  Text(_formatTime(bookmark.time),
                      style: theme.textTheme.labelSmall),
                ],
              ),
              if (bookmark.bookText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  bookmark.bookText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (bookmark.content.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '备注: ${bookmark.content}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 删除书签确认框（复用 bookmark_screen 交互语义）
  Future<bool?> _confirmDeleteBookmark(Bookmark bookmark) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书签'),
        content: Text('确定删除「${bookmark.chapterName}」的书签吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  // ===== 标注 Tab（对齐原版 HighlightFragment） =====

  Widget _buildHighlightTab(BuildContext context) {
    if (_highlightsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_highlightsError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 48, color: Theme.of(context).colorScheme.error),
            const SizedBox(height: 16),
            Text(_highlightsError!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
                onPressed: _loadHighlights, child: const Text('重试')),
          ],
        ),
      );
    }
    final query = _searchKey.trim().toLowerCase();
    final highlights = query.isEmpty
        ? _highlights
        : _highlights.where((h) {
            final chapterName =
                (h['chapterName'] ?? '').toString().toLowerCase();
            final bookText = (h['bookText'] ?? '').toString().toLowerCase();
            final note = (h['note'] ?? '').toString().toLowerCase();
            return chapterName.contains(query) ||
                bookText.contains(query) ||
                note.contains(query);
          }).toList();
    if (highlights.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.border_color_outlined,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(query.isEmpty ? '暂无标注' : '未找到匹配的标注'),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: highlights.length,
      itemBuilder: (context, index) =>
          _buildHighlightTile(context, highlights[index]),
    );
  }

  /// 标注列表项：章节名/标注内容/时间，点击跳转对应章节
  Widget _buildHighlightTile(BuildContext context, Map<String, dynamic> h) {
    final theme = Theme.of(context);
    final chapterName = (h['chapterName'] ?? '').toString();
    final bookText = (h['bookText'] ?? '').toString();
    final note = (h['note'] ?? '').toString();
    final time = (h['time'] as num?)?.toInt() ?? 0;
    final chapterIndex = (h['chapterIndex'] as num?)?.toInt() ?? 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => Navigator.of(context).pop(chapterIndex),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.border_color,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      chapterName,
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // BookHighlight.time 为 Unix 毫秒（对齐 Rust highlight.rs 契约）
                  Text(_formatTime(time), style: theme.textTheme.labelSmall),
                ],
              ),
              if (bookText.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  bookText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (note.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '笔记: $note',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                    fontStyle: FontStyle.italic,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 毫秒时间戳 → "yyyy-MM-dd HH:mm"（与 bookmark_screen 显示格式一致）
  String _formatTime(int millis) {
    if (millis <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(millis);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
