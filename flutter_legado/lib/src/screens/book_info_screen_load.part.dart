// book_info_screen.dart 的分域 part 文件（体检 §三.16 超长文件拆分，方法原样搬移）。
// extension _BookInfoLoad 承载：桥接刷新 / 重载 / 数据加载与合并。
// 同 library 内可访问 State 私有字段；生命周期（initState/dispose/build）留在主类。
part of 'book_info_screen.dart';

// ConsumerState.ref 为 protected 成员，extension 分区无法继承其访问域；
// 本文件所有方法均运行于 State 自身（this），受保护访问语义安全。
// ignore_for_file: invalid_use_of_protected_member

extension _BookInfoLoad on _BookInfoScreenState {
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
      // [fix 2026-08-15] 未在架在线书阅读返回后 reload：dbBook 已含落库时的
      // 完整详情元数据（author/tocUrl/章节数等），而 widget.book 仅是发现列表
      // 带入的瘦壳（author 等字段为空）→ 直接覆盖会显示「未知作者/共 0 章」。
      // 用 dbBook 补全 widget.book 的空字段，保留路由实时字段优先。
      if (!inShelf && book != null && dbBook != null) {
        book = BookOpenUtils.mergeDbBook(book, dbBook);
      }
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
      // [UI_SYNC_REFACTOR B4] 封面取色（跟随封面换肤）
      if (book != null) {
        unawaited(_extractCoverSeed(book));
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
              // [P2-8] 取址：当前书源详情页地址（originBookUrl 优先、空回退
              // bookUrl），避免换源后「旧源地址 + 当前书源规则」错页解析
              final infoFuture =
                  api.webbookInfo(sourceJson, BookOpenUtils.bookFetchUrl(b));
              final tocFuture = api.webbookChapters(
                sourceJson,
                BookOpenUtils.bookFetchUrl(b),
                tocUrl: b.tocUrl,
                bookName: b.name,
              );
              final results = await Future.wait([infoFuture, tocFuture]);
              debugPrint('[BookInfo] 并行 info+toc ${tParallel.elapsedMilliseconds}ms');
              try {
                b = BookOpenUtils.mergeWebInfo(b, results[0]);
              } catch (e) {
                debugPrint('webbookInfo 补全失败: ${_errMsg(e)}');
              }
              chapters = BookOpenUtils.parseWebChapters(
                results[1],
                b.bookUrl,
              );
            } else {
              // tocUrl 缺失：先 info 补 tocUrl，再拉目录
              if (needInfo) {
                try {
                  final tInfo = Stopwatch()..start();
                  final infoJson = await api.webbookInfo(
                    sourceJson,
                    BookOpenUtils.bookFetchUrl(b),
                  );
                  debugPrint(
                    '[BookInfo] webbookInfo ${tInfo.elapsedMilliseconds}ms',
                  );
                  b = BookOpenUtils.mergeWebInfo(b, infoJson);
                  if (mounted) setState(() => _loadedBook = b);
                  unawaited(_extractCoverSeed(b));
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
        unawaited(_extractCoverSeed(b));
      } else if (book != null &&
          chapters.isNotEmpty &&
          _isOnlineBook(book) &&
          source != null) {
        // ===== [U7 | 台账 0917 批二] 章节已缓存：进入即后台刷新 bookInfo =====
        // 对齐原版进入刷新语义（upBook/刷新）：更新式合并——刷新非空值覆盖陈旧
        // 字段（kind 评分/分类/完结态、字数、最新章、封面、简介），刷新值为空
        // 时保留原值（不用空覆盖）；不阻塞首屏（DB 缓存已上屏），刷新回写后
        // 聚合行「评分 · 分类 · N章 · 字数 · 完结态」完整渲染（缺项由聚合行省略）；
        // 失败则保留现有字段，不影响已上屏内容。
        var b = book;
        final sourceJson = jsonEncode(source.toJson());
        if (mounted) setState(() => _networkLoading = true);
        try {
          final tInfo = Stopwatch()..start();
          // [P2-8] 根因修复：U7 后台刷新取当前书源详情页地址（originBookUrl
          // 优先、空回退 bookUrl），换源后不再「旧源地址 + 新源规则」错页
          // 解析写坏 tocUrl；守卫（mergeWebInfo refresh 守卫）保留为纵深防御
          final infoJson = await api.webbookInfo(
            sourceJson,
            BookOpenUtils.bookFetchUrl(b),
          );
          debugPrint(
            '[BookInfo] U7 后台 info 刷新 ${tInfo.elapsedMilliseconds}ms',
          );
          b = BookOpenUtils.mergeWebInfo(b, infoJson, refresh: true);
          // 已入库书：刷新字段回写 DB（对标原版 bookDao.replace / inBookshelf
          // update）；未入库仅展示不落库（对齐原版 loadChapter !inBookshelf）
          if (inShelf) {
            try {
              await api.updateBook(b);
            } catch (e) {
              debugPrint('U7 刷新落库失败: $e');
            }
          }
        } catch (e) {
          debugPrint('U7 后台 info 刷新失败，保留现有字段: ${_errMsg(e)}');
        }
        if (mounted) {
          setState(() {
            _loadedBook = b;
            _networkLoading = false;
          });
        }
        unawaited(_extractCoverSeed(b));
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

  /// 本地 TXT（对齐原版 Book.isLocalTxt：isLocal && originName 以 .txt 结尾）
  /// — Cursor UI：拆分长章节菜单仅对本地 txt 可见，此前误用 isLocal 导致 epub 等也显示
  bool _isLocalTxt(Book book) {
    if (_isOnlineBook(book)) return false;
    final name = book.originName.trim();
    if (name.isNotEmpty) {
      return name.toLowerCase().endsWith('.txt');
    }
    return book.bookUrl.toLowerCase().endsWith('.txt');
  }

  /// 在线文件书（对齐原版 Book.isWebFile）
  bool _isWebFileBook(Book book) =>
      (book.bookType & BookType.webFile) != 0;

  /// 元数据是否需要联网补全（封面/简介/目录链接任一缺失）
  bool _needCompleteInfo(Book book) =>
      (book.coverUrl == null || book.coverUrl!.isEmpty) ||
      (book.intro == null || book.intro!.isEmpty) ||
      book.tocUrl.isEmpty;

  /// 按 origin（书源 URL）查找对应书源（供 webbookInfo/webbookChapters 传参）
  Future<BookSource?> _findSourceByOrigin(BookApi api, String origin) async {
    final key = origin.trim().replaceAll(RegExp(r'/+$'), '');
    if (_BookInfoScreenState._sourceByOriginCache.containsKey(key)) {
      return _BookInfoScreenState._sourceByOriginCache[key];
    }
    try {
      final sources = await api.getBookSources();
      for (final s in sources) {
        final u = s.bookSourceUrl.trim().replaceAll(RegExp(r'/+$'), '');
        if (u == key || s.bookSourceUrl == origin) {
          _BookInfoScreenState._sourceByOriginCache[key] = s;
          return s;
        }
      }
    } catch (e) {
      debugPrint('获取书源失败: $e');
    }
    _BookInfoScreenState._sourceByOriginCache[key] = null;
    return null;
  }

  // [P2-8 / P2-4] 详情合并（mergeWebInfo）与 DB 补全合并（mergeDbBook）逻辑
  // 已移至 BookOpenUtils（公共静态，可单测）；换源后刷新取址统一走
  // BookOpenUtils.bookFetchUrl（originBookUrl 优先、空回退 bookUrl，trim 语义
  // 对齐 Rust book_page_fetch_url），本 part 文件仅保留调用。

  /// 未入库在线书：仅网络取目录用于展示，不写 DB（对齐原版 loadChapter !inBookshelf）
  Future<List<BookChapter>> _fetchWebChaptersOnline(
    BookApi api,
    Book book, {
    String? sourceJson,
  }) async {
    final encoded = sourceJson ??
        jsonEncode((await _findSourceByOrigin(api, book.origin))?.toJson());
    if (encoded.isEmpty || encoded == 'null') return const [];
    // [P2-8] 取址同 webbookInfo：当前书源详情页（originBookUrl 优先）；
    // parseWebChapters 第二参仍传稳定主键 bookUrl（章节记录挂主键下）
    final chJson = await api.webbookChapters(
      encoded,
      BookOpenUtils.bookFetchUrl(book),
      tocUrl: book.tocUrl,
      bookName: book.name,
    );
    return BookOpenUtils.parseWebChapters(chJson, book.bookUrl);
  }
}
