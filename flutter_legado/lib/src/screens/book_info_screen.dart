import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/models.dart';
import '../providers/auto_task/auto_task_notifier.dart';
import '../providers/bookshelf/bookshelf_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../providers/sync/sync_notifier.dart';
import '../routes.dart';
import '../services/book_api.dart';
import '../services/cache_service.dart';
import '../services/platform_bridge_service.dart';
import '../services/settings_service.dart';
import '../utils/book_open_utils.dart';
import '../utils/source_login_prompt.dart';
import 'source_login_screen.dart';
import '../widgets/book_cover.dart';
import '../widgets/error_view.dart';
import '../widgets/loading_indicator.dart';
import '../widgets/list_footer.dart';

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
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  /// 整页首屏：仅在连 Book 壳都没有时显示（对齐原版先 post bookData）
  bool _pageLoading = true;
  /// 目录联网补全中（信息区已可交互）
  bool _tocLoading = false;
  /// 顶栏网络加载（对标原版 refreshProgressBar.isAutoLoading）
  bool _networkLoading = false;
  String? _loadError;
  // 当前书籍（供 AppBar 溢出菜单读取勾选态）
  Book? _loadedBook;
  List<BookChapter> _chapters = const [];
  // 当前书源（供溢出菜单条件项：设置变量/允许更新/登录/创建更新任务判定）
  BookSource? _bookSource;
  // 书架状态（对标原版 tv_shelf 加入书架/移出书架切换）
  bool _inBookshelf = false;
  // [UI-FIX v2.0.3 | 2026-08-08] 删除提醒开关（对齐原版 LocalConfig.deleteBookAlert，本地持久化） — Qoder
  // 书源按 origin 缓存，避免每次详情页全量扫描书源列表
  static final Map<String, BookSource?> _sourceByOriginCache = {};
  final SettingsService _settingsService = SettingsService();
  bool _deleteBookAlert = true;

  @override
  void initState() {
    super.initState();
    // 发现/搜索带入的 Book 立刻上屏（对齐原版 bookData.postValue 先于网络）
    _loadedBook = widget.book;
    _pageLoading = widget.book == null && widget.effectiveBookUrl.isEmpty;
    _loadData();
    _loadDeleteBookAlert();
    PlatformBridgeService.refreshSignal.addListener(_onBridgeRefresh);
  }

  void _onBridgeRefresh() {
    final signal = PlatformBridgeService.refreshSignal.value;
    if (!mounted || signal == null) return;
    if (signal == 'bookInfo' || signal == 'bookToc') {
      _reload();
    }
  }

  /// 重新加载详情（刷新/编辑后）
  void _reload() {
    if (!mounted) return;
    setState(() {
      _pageLoading = _loadedBook == null;
      _loadError = null;
      _tocLoading = false;
    });
    _loadData();
  }

  /// 加载「删除提醒」开关（对齐原版 LocalConfig.deleteBookAlert）
  Future<void> _loadDeleteBookAlert() async {
    final v = await _settingsService.getDeleteBookAlert();
    if (mounted) setState(() => _deleteBookAlert = v);
  }

  @override
  void dispose() {
    PlatformBridgeService.refreshSignal.removeListener(_onBridgeRefresh);
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final sw = Stopwatch()..start();
    final api = ref.read(bookApiProvider);
    final url = widget.effectiveBookUrl;
    try {
      // 优先从数据库取最新记录（换源/刷新后元数据才会更新），传入对象仅兜底
      final dbBook = url.isEmpty ? null : await api.getBook(url);
      // DB 有记录且未打 notShelf 位才视为已入书架（对标原版 inBookshelf；
      // 搜索/发现打开的在线书会以 notShelf 临时落库，不算在书架内）
      final inShelf = BookOpenUtils.resolveInBookshelf(dbBook, widget.book);
      // 未在架时优先用路由带入的发现/搜索元数据，避免 DB 占位壳覆盖
      var book = (!inShelf && widget.book != null)
          ? widget.book!
          : (dbBook ?? widget.book);
      var chapters =
          url.isEmpty ? <BookChapter>[] : await api.getChapters(url);
      // 书源查询一次即复用：既供菜单条件项判定，也供下方联网补全传参
      BookSource? source;
      if (book != null && _isOnlineBook(book)) {
        source = await _findSourceByOrigin(api, book.origin);
      }

      _bookSource = source;
      if (mounted) {
        setState(() {
          _loadedBook = book;
          _chapters = chapters;
          _inBookshelf = inShelf;
          _pageLoading = book == null;
          _loadError = null;
          // 在线书无本地目录：先上屏信息，再后台补全（对齐原版章节 LiveData 后至）
          _tocLoading =
              book != null && chapters.isEmpty && _isOnlineBook(book);
        });
      }
      debugPrint(
        '[BookInfo] 首屏就绪 ${sw.elapsedMilliseconds}ms '
        'name=${book?.name} chapters=${chapters.length} tocLoading=$_tocLoading',
      );

      // [UI-FIX v2.0.3 | 2026-08-06] 未入库在线书进入即联网补全目录/详情/封面 — Qoder
      // 对齐原版 BookInfoViewModel.upBook：tocUrl/详情缺失→loadBookInfo 补
      // cover/intro/tocUrl；DB 无章节→loadChapter 取目录。关键：未入库时「仅展示
      // 不落库」（对齐原版 loadChapter 在 !inBookshelf 时不写 DB）；真正落库延迟到
      // 开始阅读（见 _openReader），且以 notShelf 位标记，书架列表(list_books)过滤，不污染书架。
      if (book != null && chapters.isEmpty && _isOnlineBook(book)) {
        var b = book;
        if (source != null) {
          final sourceJson = jsonEncode(source.toJson());
          if (mounted) {
            setState(() {
              _networkLoading = true;
              _tocLoading = true;
            });
          }

          final hasTocUrl = b.tocUrl.isNotEmpty;
          final needInfo = _needCompleteInfo(b);

          try {
            if (hasTocUrl && !needInfo) {
              // 对齐原版 upBook：已有 tocUrl 且元数据齐全 → 直接 loadChapter
              chapters = await _fetchWebChaptersOnline(
                api,
                b,
                sourceJson: sourceJson,
              );
            } else if (hasTocUrl && needInfo) {
              // 详情与目录并行（tocUrl 已知，目录不必等 info）
              final tParallel = Stopwatch()..start();
              final infoFuture = api.webbookInfo(sourceJson, b.bookUrl);
              final tocFuture = api.webbookChapters(
                sourceJson,
                b.bookUrl,
                tocUrl: b.tocUrl,
                bookName: b.name,
              );
              final results = await Future.wait([infoFuture, tocFuture]);
              debugPrint('[BookInfo] 并行 info+toc ${tParallel.elapsedMilliseconds}ms');
              try {
                b = _mergeWebInfo(b, results[0] as String);
              } catch (e) {
                debugPrint('webbookInfo 补全失败: ${_errMsg(e)}');
              }
              chapters = BookOpenUtils.parseWebChapters(
                results[1] as String,
                b.bookUrl,
              );
            } else {
              // tocUrl 缺失：先 info 补 tocUrl，再拉目录
              if (needInfo) {
                try {
                  final tInfo = Stopwatch()..start();
                  final infoJson = await api.webbookInfo(sourceJson, b.bookUrl);
                  debugPrint(
                    '[BookInfo] webbookInfo ${tInfo.elapsedMilliseconds}ms',
                  );
                  b = _mergeWebInfo(b, infoJson);
                  if (mounted) setState(() => _loadedBook = b);
                } catch (e) {
                  debugPrint(
                    'webbookInfo 补全失败，降级用原书籍继续: ${_errMsg(e)}',
                  );
                }
              }
              final tToc = Stopwatch()..start();
              if (inShelf) {
                chapters = await api.refreshToc(b.bookUrl, b.origin);
              } else {
                chapters = await _fetchWebChaptersOnline(
                  api,
                  b,
                  sourceJson: sourceJson,
                );
              }
              debugPrint(
                '[BookInfo] toc ${tToc.elapsedMilliseconds}ms '
                'chapters=${chapters.length}',
              );
            }
          } catch (e) {
            debugPrint(
              '取目录失败(bookUrl=${b.bookUrl}, origin=${b.origin}): ${_errMsg(e)}',
            );
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
        if (mounted) {
          setState(() {
            _loadedBook = b;
            _chapters = chapters;
            _tocLoading = false;
            _networkLoading = false;
          });
        }
      } else if (mounted) {
        setState(() {
          _tocLoading = false;
          _networkLoading = false;
        });
      }
      debugPrint('[BookInfo] 全量完成 ${sw.elapsedMilliseconds}ms');
    } catch (e) {
      debugPrint('[BookInfo] 加载失败: ${_errMsg(e)}');
      if (mounted) {
        setState(() {
          _pageLoading = false;
          _tocLoading = false;
          _loadError = _errMsg(e);
        });
      }
    }
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
  bool _isOnlineBook(Book book) => BookOpenUtils.isOnlineBook(book);

  /// 元数据是否需要联网补全（封面/简介/目录链接任一缺失）
  bool _needCompleteInfo(Book book) =>
      (book.coverUrl == null || book.coverUrl!.isEmpty) ||
      (book.intro == null || book.intro!.isEmpty) ||
      book.tocUrl.isEmpty;

  /// 按 origin（书源 URL）查找对应书源（供 webbookInfo/webbookChapters 传参）
  Future<BookSource?> _findSourceByOrigin(BookApi api, String origin) async {
    final key = origin.trim().replaceAll(RegExp(r'/+$'), '');
    if (_sourceByOriginCache.containsKey(key)) {
      return _sourceByOriginCache[key];
    }
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        final u = s.bookSourceUrl.trim().replaceAll(RegExp(r'/+$'), '');
        if (u == key || s.bookSourceUrl == origin) {
          _sourceByOriginCache[key] = s;
          return s;
        }
      }
    } catch (e) {
      debugPrint('获取书源失败: $e');
    }
    _sourceByOriginCache[key] = null;
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


  /// 未入库在线书：仅网络取目录用于展示，不写 DB（对齐原版 loadChapter !inBookshelf）
  Future<List<BookChapter>> _fetchWebChaptersOnline(
    BookApi api,
    Book book, {
    String? sourceJson,
  }) async {
    final encoded = sourceJson ??
        jsonEncode((await _findSourceByOrigin(api, book.origin))?.toJson());
    if (encoded.isEmpty || encoded == 'null') return const [];
    final chJson = await api.webbookChapters(
      encoded,
      book.bookUrl,
      tocUrl: book.tocUrl,
      bookName: book.name,
    );
    return BookOpenUtils.parseWebChapters(chJson, book.bookUrl);
  }

  @override
  Widget build(BuildContext context) {
    // 对标原版 activity_book_info.xml：封面背景 + 半透明遮罩 + 深色 TitleBar
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: LegadoAppBar(
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
                  final book = _loadedBook;
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
                    _reload();
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
                final book = _loadedBook;
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
          if (_bookSource?.customButton == true)
            IconButton(
              icon: const Icon(Icons.extension_outlined),
              tooltip: '自定义',
              onPressed: _onCustomButton,
            ),
          // 安卓原版三点菜单；P2-2 自定义按钮已接通 callBackBtn 中途 UI 桥
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) {
              final book = _loadedBook;
              final source = _bookSource;
              final hasSource = source != null;
              final isLocal = book != null && !_isOnlineBook(book);
              final isLocalTxt = isLocal;
              final hasLogin = (source?.loginUrl ?? '').isNotEmpty;
              final canUpd = book?.canUpdate ?? true;
              return [
                if (source?.customButton == true)
                  const PopupMenuItem(value: 'customBtn', child: Text('自定义')),
                if (isLocal)
                  const PopupMenuItem(value: 'upload', child: Text('上传至远程')),
                const PopupMenuItem(value: 'refresh', child: Text('刷新')),
                // 创建书籍更新任务（在架 + 书源 + 非本地 + 允许更新；
                // [Task #39 §5.11-2] 已接通 AutoTaskScreen 编辑/创建流程）
                if (_inBookshelf && hasSource && !isLocal && canUpd)
                  const PopupMenuItem(
                    value: 'updateTask',
                    child: Text('创建书籍更新任务'),
                  ),
                // 登录（书源支持登录时）
                if (hasLogin)
                  const PopupMenuItem(value: 'login', child: Text('登录')),
                const PopupMenuItem(value: 'top', child: Text('置顶')),
                // 设置源变量（Task #63 冻结 / #64-65 实现，§5.11-3 已接通 setSourceVariable）/
                // 设置书籍变量
                //（[Task #39 §5.11-4] 已接通变量对话框 + updateBook 保存）
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
                const PopupMenuItem(
                    value: 'cacheDownloads', child: Text('缓存下载队列')),
                const PopupMenuItem(value: 'log', child: Text('日志')),
              ];
            },
          ),
        ],
      ),
      body: _pageLoading
          ? const LoadingIndicator(message: '加载书籍信息...')
          : _loadError != null && _loadedBook == null
              ? ErrorView(
                  message: _loadError!,
                  onRetry: _reload,
                )
              : _loadedBook == null
                  ? const ErrorView(message: '书籍不存在')
                  : _buildPage(context, _loadedBook!, _chapters),
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
            onRefresh: () async => _reload(),
            child: _buildBody(context, book, chapters),
          ),
        ),
        // 顶栏加载条（对标原版 refreshProgressBar.isAutoLoading）
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: TopNetworkLoadingBar(
            isLoading: _networkLoading || _tocLoading,
          ),
        ),
      ],
    );
  }


  /// P2-2 自定义按钮：SourceCallBack.callBackBtn + 中途 UI 回放
  Future<void> _onCustomButton() async {
    final book = _loadedBook;
    if (book == null) return;
    final api = ref.read(bookApiProvider);
    try {
      final r = await api.sourceCallBackBtn(
        event: 'clickCustomButton',
        bookUrl: book.bookUrl,
        bookType: book.bookType,
      );
      final actions = r['actions'];
      if (actions is List) {
        await PlatformBridgeService.instance.dispatchActions(actions);
      }
      final invoked = r['invoked'] == true;
      final jsTrue = r['jsTrue'] == true;
      if (!invoked || !jsTrue) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未配置回调或回调未接管')),
          );
        }
      }
    } catch (e) {
      debugPrint('自定义按钮失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自定义按钮执行失败: $e')),
        );
      }
    }
  }
  /// 溢出菜单处理（对标原版 BookInfoActivity.onOptionsItemSelected）
  Future<void> _handleMenu(String value) async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    switch (value) {
      case 'customBtn':
        await _onCustomButton();
        break;
      case 'refresh':
        // 对齐原版：刷新即含目录更新（在线书走 refreshToc，本地书仅重加载）
        if (book != null && _isOnlineBook(book)) {
          await _refreshToc();
        } else {
          _reload();
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
        if (!_inBookshelf) {
          _snack('请先加入书架');
          return;
        }
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
        if (mounted) _reload();
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
      case 'cacheDownloads':
        // [UI-fix v2.0.16 | 2026-08-10] 缓存下载队列页（对齐原版 CacheActivity）— Reasonix
        if (!context.mounted) break;
        await Navigator.pushNamed(context, AppRoutes.cacheDownloads);
        break;
      case 'deleteAlert':
        // [UI-fix v2.0.3 | 2026-08-08] 删除提醒开关持久化（对齐原版
        // LocalConfig.deleteBookAlert：删除/移出书籍时是否弹确认框） — Qoder
        final next = !_deleteBookAlert;
        await _settingsService.setDeleteBookAlert(next);
        if (mounted) setState(() => _deleteBookAlert = next);
        break;
      case 'bookVariable':
        // [UI-fix v2.0.3 | 2026-08-09] 设置书籍变量接通保存链路（Task #39
        // §5.11-4，对齐原版 BookInfoActivity.setBookVariable + setVariable
        // 的 bookUrl 分支：putCustomVariable + saveBook） — Qoder
        await _setBookVariable();
        break;
      case 'sourceVariable':
        // [Task #63 冻结 / #64-65 实现 | 2026-08-10] 设置源变量接通（台账 §5.11-3，对齐原版
        // BookInfoActivity.setSourceVariable + setVariable 的 source 分支：
        // bookSource.setVariable 后保存） — Qoder
        await _setSourceVariable();
        break;
      case 'updateTask':
        // [UI-fix v2.0.3 | 2026-08-09] 创建书籍更新任务接通（Task #39
        // §5.11-2，对齐原版 BookInfoActivity.openBookUpdateTask：
        // findBookUpdateTask 已存在→编辑，否则 buildBookUpdateTask 新建） — Qoder
        await _openBookUpdateTask();
        break;
      case 'upload':
        // [Task #52 | 2026-08-10] §5.11-1：上传至远程接通（对齐原版
        // BookInfoActivity.menu_upload → RemoteBookWebDav.upload：
        // WebDav PUT 本地书籍文件 → book.origin = webDavTag+putUrl → update） — Qoder
        await _uploadToRemote();
        break;
      default:
        _todo(value);
        break;
    }
  }

  /// 未移植功能提示（占位项，待后续版本对齐原版）
  void _todo(String value) {
    final feature = value;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「$feature」后续版本支持')),
    );
  }

  /// 设置源变量（Task #63 冻结 / #64-65 实现，台账 §5.11-3，对齐原版 BookInfoActivity
  /// setSourceVariable + setVariable 的 source 分支）
  ///
  /// 原版语义：
  /// - 书源不存在时 toast「书源不存在」直接返回（菜单层已按 hasSource 隐藏，
  ///   此处为二次防护，对齐原版 setSourceVariable 的 source==null 分支）
  /// - 说明文案对齐 getDisplayVariableComment：书源 variableComment
  ///   非空优先展示，否则用默认文案
  /// - 输入框预填当前书源 variable；确认后 setSourceVariable（空串=清除）
  ///   单列 UPDATE 写库，成功后 Toast + 刷新本地书源状态
  Future<void> _setSourceVariable() async {
    final api = ref.read(bookApiProvider);
    final source = _bookSource;
    if (source == null) {
      _snack('书源不存在');
      return;
    }
    // 说明文案（对齐原版 getDisplayVariableComment：书源注释优先）
    final srcComment = (source.variableComment ?? '').trim();
    final comment = srcComment.isNotEmpty
        ? srcComment
        : '源变量可在js中通过source.getVariable()获取';
    // 输入框预填当前书源 variable（对齐原版 source.getVariable 初值；
    // 评审 C1 后 variable 为非空串，无需 ?? 兼容）
    // [Task #70 D1 修复 | 2026-08-10] 重构为自持 StatefulWidget 对话框
    //（_TextPromptDialog 范式）：原实现 controller 在外部作用域创建 +
    // pop 后立即 dispose，退场动画期间触发 _dependents.isEmpty 断言 +
    // OverlayEntry Duplicate GlobalKey 红屏；现 controller 生命周期
    // 绑定对话框子树，确定按钮先取值再 pop 回传 — Qoder
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => _VariableDialog(
        title: '设置源变量',
        comment: comment,
        initialText: source.variable,
      ),
    );
    // 取消（pop 无值）不保存；确定恒保存，空串=清除（对齐原版 setVariable）
    if (input == null || !mounted) return;
    try {
      // 单列 UPDATE 语义（契约 §2.3）：仅改 variable 列，空串=清除；
      // 规避 updateBookSource 全行更新覆盖其它字段的风险
      await api.setSourceVariable(source.bookSourceUrl, input);
      if (!mounted) return;
      // 刷新本地书源状态（重载页面数据，书源查询自然带出新 variable；
      // 评审 C1：variable 非空串语义，空串即已清除，不再传 null）
      setState(() {
        _bookSource = source.copyWith(
          variable: input,
        );
      });
      _reload();
      _snack(input.isEmpty ? '源变量已清除' : '源变量已保存');
    } catch (e) {
      debugPrint('设置源变量失败: $e');
      if (mounted) _snack('设置源变量失败: ${_errMsg(e)}');
    }
  }

  /// 上传至远程（Task #52 §5.11-1，对齐原版 RemoteBookWebDav.upload）
  ///
  /// 原版语义（BookInfoActivity.menu_upload → upLoadBook）：
  /// - 仅本地书可见（isLocal = localTag 或 webDavTag，菜单已限定）
  /// - 已有远程地址时先确认（sure_upload），否则直接上传
  /// - WebDav PUT 本地书籍文件到远程 books 目录（rootBookUrl + originName）
  /// - 成功后 book.origin = webDavTag + 远程地址，并刷新 lastCheckTime
  Future<void> _uploadToRemote() async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    if (book == null) return;
    // 防御：仅本地书支持上传（在线书无本地文件，按原版语义不支持）
    if (_isOnlineBook(book)) {
      _snack('上传至远程仅支持本地书籍');
      return;
    }
    // 前置：读取已保存的 WebDAV 配置（复用 SyncNotifier 既有配置链路）
    final syncNotifier = ref.read(syncNotifierProvider.notifier);
    await syncNotifier.loadConfig();
    if (!mounted) return;
    final sync = ref.read(syncNotifierProvider);
    if (!sync.isConfigured) {
      // 未配置 → 提示并引导跳转 WebDAV 设置（对齐原版「未配置webDav」异常提示）
      await _showWebDavNotConfiguredDialog();
      return;
    }
    // 已有远程地址 → 确认是否覆盖（对齐原版 sure_upload 对话框）
    if (book.origin.startsWith(BookType.webDavTag)) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('提示'),
          content: const Text('已存在远程 webDav 地址，继续上传？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.confirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    // 本地书 bookUrl 即本地文件路径（对齐 Rust import_local_book 落库约定）
    final localPath = book.bookUrl;
    final fileName = book.originName.isNotEmpty
        ? book.originName
        : localPath.split(Platform.pathSeparator).last;
    // 远程路径规则对齐原版 RemoteBookWebDav：rootBookUrl(books/) + originName；
    // path 相对 remote_dir，Rust 侧 full_url = url + remote_dir + path
    final remotePath = 'books/$fileName';
    _snack('正在上传至远程…');
    // [Task #55 F9 | 2026-08-10] 上传与 origin 回写分两段 try/catch：
    // 回写失败时提示「上传成功但保存记录失败」而非误报「上传失败」 — Qoder
    try {
      await api.webdavUploadFile(
        syncNotifier.buildConfigJson(),
        remotePath,
        localPath,
      );
    } catch (e) {
      debugPrint('上传至远程失败: $e');
      if (mounted) _snack('上传失败: ${_errMsg(e)}');
      return;
    }
    if (!mounted) return;
    try {
      // 回写 book.origin（webDav 标记 + 远程完整地址）；从库中读回完整 Book
      // 再 copyWith，防全行覆盖（与 _setBookVariable 同模式）
      final full = await api.getBook(book.bookUrl) ?? book;
      final remoteUrl =
          '${sync.webDavUrl}${syncNotifier.normalizedRemoteDir}$remotePath';
      await api.updateBook(full.copyWith(
        origin: BookType.webDavTag + remoteUrl,
        // 对齐原版：刷新最后检查时间，使之比远程书籍的时间新
        lastCheckTime: DateTime.now().millisecondsSinceEpoch,
      ));
      if (!mounted) return;
      _reload();
      _snack('上传至远程成功');
    } catch (e) {
      debugPrint('上传成功但保存记录失败: $e');
      if (mounted) _snack('上传成功但保存记录失败，请重试');
    }
  }

  /// WebDAV 未配置引导对话框（确认后跳转 WebDAV 设置页）
  Future<void> _showWebDavNotConfiguredDialog() async {
    final goSettings = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('未配置 WebDAV'),
        content: const Text('上传至远程需要先配置 WebDAV 服务器信息'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去设置'),
          ),
        ],
      ),
    );
    // 异步对话框返回后先检查 mounted，再跳转
    if (goSettings == true && mounted) {
      Navigator.pushNamed(context, AppRoutes.webdavSettings);
    }
  }

  /// SnackBar 轻提示（统一入口）
  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 设置书籍变量（对齐原版 setBookVariable + setVariable 的 bookUrl 分支）
  ///
  /// 弹输入对话框（含说明文案，对齐原版 VariableDialog 的 comment 展示：
  /// 书源 variableComment 非空优先，否则用默认提示），确认后把变量
  /// 写入 Book 并经 update_book 保存。
  ///
  /// [fix Task#45 | 2026-08-09] 对齐原版 BaseBook.putCustomVariable /
  /// getCustomVariable 语义（M4）：variable 为 JSON Map 串，自定义变量
  /// 挂 "custom" 键；输入框初值取 map['custom']，保存时回写该键
  /// （空输入移除键）后 jsonEncode 整体写回。另补原版 inBookshelf
  /// 守卫（M5）：非在架时不 saveBook，避免 upsert 进 books 表 — Qoder
  ///
  /// 防坑：update_book 为全行 UPDATE，保存前必须基于从库中读回的完整
  /// Book 对象（含 readConfig 等字段）仅修改 variable 后回写，
  /// 禁止用页面缓存的不完整对象覆盖。
  Future<void> _setBookVariable() async {
    final api = ref.read(bookApiProvider);
    final book = _loadedBook;
    final source = _bookSource;
    if (book == null || source == null) {
      _snack('书源不存在');
      return;
    }
    // 说明文案（对齐原版 getDisplayVariableComment：书源注释优先）
    final srcComment = (source.variableComment ?? '').trim();
    final comment = srcComment.isNotEmpty
        ? srcComment
        : '书籍变量可在js中通过book.getVariable("custom")获取';
    // 输入框初值：解析 variable JSON Map 取 custom 键（解析失败视为空 Map）
    final customInit = _parseVariableMap(book.variable)['custom'];
    // [Task #70 D1 修复 | 2026-08-10] 同 _setSourceVariable：重构为自持
    // StatefulWidget 对话框，消除外部 controller 提前 dispose 隐患 — Qoder
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => _VariableDialog(
        title: '设置书籍变量',
        comment: comment,
        initialText: customInit?.toString() ?? '',
      ),
    );
    if (input == null || !mounted) return;
    // 原版 inBookshelf 守卫：仅在架时 saveBook，否则无条件 updateBook
    // 会把非在架书 upsert 进 books 表（M5）
    if (!_inBookshelf) {
      _snack('请先加入书架');
      return;
    }
    try {
      // 从库中读回完整 Book（含 readConfig 等）仅改 variable 后回写
      final full = await api.getBook(book.bookUrl) ?? book;
      // putCustomVariable 语义：其余键原样保留，仅回写 custom 键
      final varMap = _parseVariableMap(full.variable);
      if (input.isEmpty) {
        varMap.remove('custom');
      } else {
        varMap['custom'] = input;
      }
      await api.updateBook(full.copyWith(variable: jsonEncode(varMap)));
      if (!mounted) return;
      _reload();
      _snack('书籍变量已保存');
    } catch (e) {
      debugPrint('保存书籍变量失败: $e');
      if (mounted) _snack('保存书籍变量失败');
    }
  }

  /// 解析 variable 为可变 Map（非法/空串视为空 Map，
  /// 对齐原版 getVariableMap 解析失败回落空表的容错）
  Map<String, dynamic> _parseVariableMap(String? variable) {
    final raw = (variable ?? '').trim();
    if (raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {
      // 解析失败视为空 Map
    }
    return <String, dynamic>{};
  }

  /// 创建书籍更新任务（对齐原版 openBookUpdateTask）
  ///
  /// 先经 findBookUpdateTask 查该书是否已有更新任务：
  /// - 已存在 → 携 editTaskId 跳转 AutoTaskScreen 定位并进入该任务编辑；
  /// - 不存在 → 用 buildBookUpdateTask 构建默认任务（任务名对齐原版
  ///   auto_task_book_update_name：更新 %s），携 newTask 进入创建流程。
  Future<void> _openBookUpdateTask() async {
    final book = _loadedBook;
    if (book == null) return;
    final notifier = ref.read(autoTaskNotifierProvider.notifier);
    // findBookUpdateTask 基于 notifier 内任务列表匹配，先静默加载确保最新
    await notifier.loadTasks(silent: true);
    if (!mounted) return;
    final existing = await notifier.findBookUpdateTask(
      bookUrl: book.bookUrl,
      bookName: book.name,
      bookAuthor: book.author,
    );
    if (!mounted) return;
    if (existing != null) {
      final id = existing['id']?.toString() ?? '';
      await Navigator.pushNamed(
        context,
        AppRoutes.autoTasks,
        arguments: <String, dynamic>{'editTaskId': id},
      );
      return;
    }
    final built = await notifier.buildBookUpdateTask(
      bookUrl: book.bookUrl,
      bookName: book.name,
      bookAuthor: book.author,
      // [fix Task#45 | 2026-08-09] 文案对齐原版 auto_task_book_update_name
      // （「更新 %s」含空格）— Qoder
      name: '更新 ${book.name}',
    );
    if (!mounted) return;
    if (built == null) {
      _snack('创建任务失败');
      return;
    }
    await Navigator.pushNamed(
      context,
      AppRoutes.autoTasks,
      arguments: <String, dynamic>{'newTask': built},
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
            sourceOrigin: book.origin,
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
    final tocTitle = _tocLoading ? '加载中…' : _resolveTocTitle(book, chapters);
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
          // [UI-fix v2.0.3 | 2026-08-08] lint：null-aware 元素语法与 build_runner 内置分析器不兼容，用 if-element 等价表达 — Qoder
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
    final book = _loadedBook;
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
  }

  /// 更新目录（对标原版 refreshToc；从底部按钮迁入溢出菜单）
  Future<void> _refreshToc() async {
    final book = _loadedBook;
    if (book == null || _isLoading) return;
    setState(() => _isLoading = true);
    try {
      final api = ref.read(bookApiProvider);
      final List<BookChapter> chapters;
      if (!_inBookshelf) {
        // 未入库：仅内存拉目录，不落库（对齐原版 loadChapter !inBookshelf）
        chapters = await _fetchWebChaptersOnline(api, book);
      } else {
        chapters = await api.refreshToc(book.bookUrl, book.origin);
      }
      if (!mounted) return;
      setState(() => _chapters = chapters);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('目录已更新，共 ${chapters.length} 章')),
      );
      if (_inBookshelf) {
        _reload();
      }
    } catch (e) {
      if (!mounted) return;
      BookSource? source;
      try {
        final sources = await ref.read(bookApiProvider).getBookSources();
        for (final s in sources) {
          if (s.bookSourceUrl == book.origin) {
            source = s;
            break;
          }
        }
      } catch (_) {}
      if (!mounted) return;
      if (isSourceLoginRequiredError(e)) {
        await promptSourceLoginIfNeeded(context, error: e, source: source);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败: $e')),
        );
      }
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
    if (mounted) _reload();
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
  Future<void> _clearCache() async {
    final book = _loadedBook;
    if (book == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清除缓存'),
        content: Text('确定清除《${book.name}》的章节缓存？'),
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
      final deleted =
          await ref.read(bookApiProvider).clearBookCache(book.bookUrl);
      await CacheService.clearSameTitleRemovedFlags();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清除 $deleted 条章节缓存')),
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
    // [UI-fix v2.0.12 | 2026-08-10] 解析书籍类型位（对齐原版 BookType 位标记）：
    // 搜索输出不带 type（bookType=0）或旧库只有 notShelf 位时，按书源类型
    // （bookSourceType：1=音频/2=图片/3=文件/4=视频）映射补全，保证分流与
    // 落库类型正确（修复图片/音频/视频源「打不开」——类型位丢失致分流落回
    // 文本阅读器）— Reasonix
    // 分流逻辑抽至 BookOpenUtils，与书架 startActivityForBook 对齐 — Reasonix + UI
    const typeMask = BookOpenUtils.typeMask;
    var typeBits = BookOpenUtils.typeBitsOf(book);
    BookSource? matchedSource;
    if (_isOnlineBook(book)) {
      matchedSource = await _findSourceByOrigin(api, book.origin);
      // 书源媒体类型 / 视频启发式优先于抽图提升（非凡 type=0 MacCMS 等）
      // — Reasonix + UI
      typeBits = BookOpenUtils.resolveTypeBits(typeBits, matchedSource);
    }
    try {
      if (_isOnlineBook(book)) {
        final existing = await api.getBook(book.bookUrl);
        if (existing == null) {
          // 以正确类型位 + notShelf 位标记临时落库：阅读器 DB 依赖成立
          // （按 origin 取正文），但不进书架列表；用户显式「加入书架」时再
          // 清标记转正（见 _toggleShelf）。
          await api.addBook(
              book.copyWith(bookType: typeBits | BookType.notShelf));
        } else if (typeBits != 0 &&
            (existing.bookType & typeMask) != typeBits) {
          // 缺类型位，或文本→图片提升（必应漫画）→ 回填媒体位
          await api.updateBook(existing.copyWith(
              bookType: (existing.bookType & ~typeMask) | typeBits));
        }
        // 漫画/视频等非文本阅读器只收 bookUrl，不会走 ReaderNotifier 的
        // 空目录自愈；详情页「未入库」路径又不落库章节 → 必须在开读前
        // 把目录写入 DB，否则进 comic/video 仍是「暂无章节」。
        // 对齐原版 readBook 前确保目录可用。— Reasonix + UI
        if (!BookOpenUtils.needsReaderNotifier(
            BookOpenUtils.routeForTypeBits(typeBits))) {
          final existingChapters = await api.getChapters(book.bookUrl);
          if (existingChapters.isEmpty && book.origin.isNotEmpty) {
            await api.refreshToc(book.bookUrl, book.origin);
          }
        }
      }
    } catch (e) {
      debugPrint('阅读前落库失败: $e');
    }
    if (!context.mounted) return;
    final container = ProviderScope.containerOf(context);
    final bookToRead = chapterIndex != book.durChapterIndex
        ? book.copyWith(durChapterIndex: chapterIndex, bookType: typeBits)
        : book.copyWith(bookType: typeBits);
    // 按类型分流（对齐原版 BookInfoActivity.startReadActivity）— Reasonix + UI
    final route = BookOpenUtils.routeForTypeBits(typeBits);
    debugPrint(
      '[BookOpen] name=${book.name} origin=${book.origin} '
      'typeBits=$typeBits route=$route '
      'srcType=${matchedSource?.bookSourceType} '
      'videoLike=${BookOpenUtils.looksLikeVideoSource(matchedSource)}',
    );
    if (BookOpenUtils.needsReaderNotifier(route)) {
      container.read(readerNotifierProvider.notifier).openBook(bookToRead);
      // [UI-fix v2.0.11 | 2026-08-10] 阅读返回后重新加载详情数据 — Reasonix
      if (!context.mounted) return;
      await Navigator.pushNamed(context, route);
    } else {
      if (!context.mounted) return;
      await Navigator.pushNamed(
        context,
        route,
        arguments: BookOpenUtils.argumentsForRoute(route, bookToRead),
      );
    }
    if (mounted) {
      _reload();
    }
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
  /// action → 剩余秒数（对标 SourceLoginV2Delegate.countdownLeft）
  final Map<String, int> _countdownLeft = {};
  final Map<String, Timer> _countdownTimers = {};
  final Map<String, String> _buttonLabels = {};

  @override
  void initState() {
    super.initState();
    _loadUi();
  }

  @override
  void dispose() {
    for (final t in _countdownTimers.values) {
      t.cancel();
    }
    _countdownTimers.clear();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _startCountdown(String action, int seconds) {
    _countdownTimers.remove(action)?.cancel();
    _countdownLeft[action] = seconds;
    setState(() {});
    _countdownTimers[action] = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_countdownLeft[action] ?? 1) - 1;
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (left <= 0) {
        timer.cancel();
        _countdownTimers.remove(action);
        _countdownLeft.remove(action);
        setState(() {});
      } else {
        setState(() => _countdownLeft[action] = left);
      }
    });
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
  Future<void> _doAction(String action, {int? countdownSeconds}) async {
    if ((_countdownLeft[action] ?? 0) > 0) return;
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
      // 成功且配置了 countdown：启动按钮倒计时（对齐 Kotlin）
      if (countdownSeconds != null && countdownSeconds > 0) {
        _startCountdown(action, countdownSeconds);
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
        final countdownRaw = row['countdown'];
        final countdown = countdownRaw is int
            ? countdownRaw
            : int.tryParse(countdownRaw?.toString() ?? '');
        if (action.isNotEmpty && name.isNotEmpty) {
          _buttonLabels.putIfAbsent(action, () => name);
        }
        final left = _countdownLeft[action] ?? 0;
        final label = left > 0
            ? '${_buttonLabels[action] ?? name} (${left}s)'
            : (_buttonLabels[action] ?? name);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: OutlinedButton(
            onPressed: _busy || action.isEmpty || left > 0
                ? null
                : () => _doAction(action, countdownSeconds: countdown),
            child: Text(label),
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
  // [UI-fix v2.0.11 | 2026-08-10] 简介默认全部显示（用户反馈），
  // 保留「收起」按钮供手动折叠；短简介仍由 showToggle 自适应隐藏切换控件 — Reasonix
  bool _expanded = true;

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

/// 变量设置对话框（供设置源变量/设置书籍变量复用）
///
/// [Task #70 D1 修复 | 2026-08-10] 照 source_screen.dart 的
/// _TextPromptDialog 范式实现自持 StatefulWidget：controller 在 State
/// 内 late final 创建、dispose 随子树卸载统一释放，确定按钮先取值再
/// Navigator.pop(ctx, value)，规避外部作用域 controller 在退场动画期间
/// 提前 dispose 引发的 framework.dart '_dependents.isEmpty' 断言 +
/// OverlayEntry Duplicate GlobalKey 红屏 — Qoder
///
/// 回传约定：确定 → pop 输入值（可为空串，空串=清除语义由调用方保持）；
/// 取消/系统关闭 → pop 无值（null），调用方不保存。
class _VariableDialog extends StatefulWidget {
  final String title;

  /// 说明文案（对齐原版 VariableDialog 的 comment 展示）
  final String comment;

  /// 输入框预填文本
  final String initialText;

  const _VariableDialog({
    required this.title,
    required this.comment,
    required this.initialText,
  });

  @override
  State<_VariableDialog> createState() => _VariableDialogState();
}

class _VariableDialogState extends State<_VariableDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.comment,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 3,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'variable',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            // 先取值再 pop（controller 随子树卸载后不可再读）
            final value = _controller.text;
            Navigator.pop(context, value);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
