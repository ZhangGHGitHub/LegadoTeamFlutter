import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import '../widgets/md3_fast_scroller.dart';
import '../widgets/app_scaffold.dart';
import '../widgets/legado_app_bar.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../models/models.dart';
import '../providers/book_marking/book_marking_notifier.dart';
import '../providers/bookmark/bookmark_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../services/audio_cache_events.dart';
import '../services/book_api.dart';
import '../services/bookmark_export.dart';
import '../services/settings_service.dart';
import '../utils/app_route_observer.dart';
import '../utils/book_open_utils.dart';
import '../utils/toc_cache_state.dart';
import '../utils/txt_toc_rule.dart' show buildReparseRuleJson, isLocalTxtBook;
import '../widgets/reader/marking_sheet.dart';
import '../widgets/reader/reader_action_helpers.dart';
import '../widgets/reader/reader_toc_rule_dialog.dart';
import '../utils/error_message.dart';

/// 独立目录页（对齐原版 TocActivity + ChapterListFragment/BookmarkFragment/HighlightFragment）
///
/// [UI-fix v2.0.3 | 2026-08-08] 模块 D：新建独立目录页 — Qoder
/// - 三 Tab：目录 / 书签 / 标注（对齐原版 TabFragmentPageAdapter；
///   [PARITY C2 T1] 参考版仅 2 项，「标注」为功能超集，登记保留）
/// - 目录 Tab：卷分组样式、当前章节淡蓝底高亮（[PARITY C2 T5]）+ 自动定位、
///   章节字数胶囊（[PARITY C2 T2]，受「加载字数」开关控制）、
///   缓存状态图标（[P2-28]，对齐原版 ChapterListAdapter.upHasCache 三态）
///   [PARITY C2 T4] 底部当前章节信息条 + 跳转顶/底已移除（跳转能力保留于目录 FAB）
/// - 书签/标注 Tab：数据经 BookApi（bookmarkNotifier / highlightListByBook）
/// - 溢出菜单对齐 book_toc.xml 顺序与条件显隐（随 Tab 切换，对齐 TocActivity.onMenuOpened）
/// - 返回值：选中章节 index（int），供调用方走现有阅读跳转链路
/// - [P2-28b] 章节行缓存状态三态（未缓存=离线下载图标⬇ / 已缓存=无图标 /
///   当前章=对勾圈），图标对齐参考版 TocScreen.StatusIcon，
///   数据经 BookApi.listCachedChapterUrls
///   （[UI-fix v2.0.6] Task #22 接通的只读 FFI，契约 §2.43.5）
/// - [P2-29] 章节行状态机对齐参考版五态（用户验收「下载中缺少过渡动画」）：
///   当前章→定位图标 location_on（替代 check_circle）/ 下载中→16px 加载
///   指示（数据经 BookApi.listDownloadingChapters，契约 §2.43.7，1s 轮询
///   同周期刷新）/ 失败→红色重试图标（点击单章重下，复用
///   cacheDownloadStart(idx, idx)；数据经 BookApi.listFailedChapters，
///   契约 §2.43.8，与下载中同周期 1s 轮询）/
///   未缓存→⬇ / 已缓存→无图标（本地书恒视为已缓存，无图标）
/// - [P2-29b] 状态元素互斥分支与着色修正（用户指正：参考版当前章没有
///   红色定位图标，只有高亮胶囊）：行右侧状态元素改为对齐参考版
///   ReaderSheetChapterStatus 单 when 链的互斥分支（字数胶囊短路全部状态
///   图标——当前章有字数时只显示高亮胶囊，不再与定位图标并存）；定位图标
///   着色统一 secondary（参考 ReaderSheetStatusIcon tint）；补参考版
///   SUCCESS 态对勾图标（已缓存且无胶囊时，secondary 色）；当前章行级
///   高亮改参考行色（背景 secondaryContainer + 标题 onSecondaryContainer）；
///   字数胶囊改 isDur 分色（当前章 primaryContainer/onPrimaryContainer，
///   普通章 surfaceContainer/onSurfaceVariant，8sp、圆角 8）
/// - [P2-29c] 目录缓存交互补齐（P2-29b 增量需求登记落地，零契约）：
///   ① NONE 态 ⬇ 图标可点击单章下载（对齐参考版 TocScreen.kt ChapterItem
///   :879-881 `canDownload = downloadState == NONE || ERROR` + :958-965
///   状态图标 Box 挂 onDownloadClick + :808 onDownloadClick →
///   TocViewModel.kt downloadChapter :863-869 按章索引单章下载）——复用
///   [BookApi.cacheDownloadStart]（契约 §2.43.3 闭区间 start==end 单章，
///   与 ERROR 重试同路径）；② ERROR 分支优先级提到已缓存之前 + showCount
///   排除 ERROR（对齐参考版 TocViewModel.kt rawDataFlow :510-514
///   running > error > cached 判定序；StatusIcon :1146-1157 字数胶囊仅
///   LOCAL/SUCCESS 态命中）；③ 两态图标按钮统一 shrinkWrap 触控尺寸，
///   保持 16px 图标几何不变（沿用 P2-28/29 行高适配口径）；④ 失败态数据源
///   于 P2-29c 后续批接通：Rust 任务表/持久化快照新增失败章索引集合，
///   只读 FFI cacheDownloadFailedChapters（契约 §2.43.8）→ BookApi.listFailedChapters，
///   本页 1s 轮询同周期拉取（见 [_failedIndices]），注入缝已移除
/// - [P2-28b] 页面打开期间每秒轮询缓存状态（对齐原版 ChapterListFragment
///   订阅 EventBus.SAVE_CONTENT 的行刷新语义）：批量离线缓存下载中，每章正文
///   保存后对应行 ⬇ 图标实时变为字数胶囊/无图标，无需退出重进
/// - [B1-TOC] 音频书章节「已缓存」徽标接线（2026-10-04）：音频书的已缓存
///   判定改取 BookApi.audioCacheList（契约 §2.47，返回已缓存章节下标集合），
///   对齐原版 ChapterListFragment.kt:154-184（仅 `if (book.isAudio)` 经
///   AudioCacheManager.listCachedChapterKeys 取缓存键集合）+
///   ChapterListAdapter.kt:192-198（音频书 `audioCacheKeys.contains(
///   AudioCacheKey.from(chapter))`）；1s 轮询同周期追加 audioCacheList
///   （**仅非本地音频书**，非音频书不消耗此 FFI 调用），无变化与文本缓存
///   同样跳过 setState、查询失败保留旧态。非音频书仍走
///   listCachedChapterUrls 文本缓存判定（§2.43.5）不受影响；本地书恒无
///   徽标（原版 isLocalBook 恒视为已缓存 + 本地书无书源不可缓存）。
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

  /// 加载字数开关（本地持久化，对齐原版 AppConfig.tocCountWords）
  bool _loadWordCount = true;

  /// 目录 FAB 展开菜单显隐（定位/顶部/底部/一键缓存，对齐参考版）— 2026-09-08
  bool _jumpMenuOpen = false;

  /// 当前书籍（菜单勾选项更新后刷新，如 useReplaceRule/splitLongChapter）
  late Book _book;

  /// 是否在架（对标原版 inBookshelf；未在架时不 refreshToc 落库）
  bool _inBookshelf = false;

  /// 章节列表（含卷行）
  List<BookChapter> _chapters = [];
  bool _chaptersLoading = true;
  String? _chaptersError;

  /// [批43b P2-1] 最近一次目录加载是否真正应用了显式 TXT 目录规则
  /// （Rust `ChapterListResponse.used_custom_rule`；缓存命中/未解析为 false）
  bool _chaptersUsedCustomRule = false;

  /// [P2-28] 本书已缓存章节 URL 集合（经 BookApi.listCachedChapterUrls，
  /// 契约 §2.43.5；对齐原版 cacheFileNames.contains(chapter.getFileName()) 判定。
  /// 本地书恒视为已缓存（对齐原版 isLocalBook），不发起查询）
  Set<String> _cachedUrls = const {};

  /// [B1-TOC] 本书已缓存音频章节下标集合（经 BookApi.audioCacheList，
  /// 契约 §2.47，返回 `List<int>` 已缓存章节下标）。**仅非本地音频书**使用：
  /// 对齐原版 ChapterListFragment.kt:154-184 的 `if (book.isAudio)` 分支
  /// （只有音频书经 AudioCacheManager.listCachedChapterKeys 取键，
  /// ChapterListAdapter.kt:192-198 以 audioCacheKeys 判「已缓存」）；
  /// 非音频书不走此数据链（不浪费一次 FFI 调用），本地书无书源不可缓存
  /// 且原版 isLocalBook 恒视为已缓存 → 亦不查询、不显示徽标。
  Set<int> _audioCachedIndices = const {};

  /// [P2-28c] 轮询获得的字数映射（url → wordCount，取 chapters 表当前值，
  /// 仅含非空项）：行渲染时优先于章节数据 wordCount，使新缓存章的字数
  /// 胶囊与 ⬇ 图标翻转同帧出现（对齐参考版 ChapterListFragment 订阅
  /// SAVE_CONTENT 同帧刷行语义，P2-28b 轮询升级）
  final Map<String, String> _polledWordCounts = {};

  /// [P2-29] 本书当前在途下载章节 index 集合（经 BookApi.listDownloadingChapters，
  /// 契约 §2.43.7 cacheDownloadRunningChapters；对齐参考版 TocViewModel
  /// runningIndices——源自 `CacheBook.downloadStateFlow` 全局状态流）：
  /// 初始加载 + 1s 轮询（P2-28b/c）同周期刷新，驱动下载中行 16px 加载指示
  /// 动画（对齐参考版 `AppContainedLoadingIndicator` 16dp 形态）；
  /// 无活跃批量下载任务时为空集。
  Set<int> _downloadingIndices = const {};

  /// [P2-29] 缓存状态轮询定时器（每秒一次，仅在线书；页面关闭/dispose 时取消）。
  /// 对齐原版 ChapterListFragment 订阅 EventBus.SAVE_CONTENT 的「每章正文保存
  /// 后刷新对应行」语义——我方以只读 FFI listCachedChapterUrls 轮询替代事件总线
  /// （零契约面方案）：批量离线缓存下载中，每章正文保存后该行 ⬇ 图标实时
  /// 变为字数胶囊/无图标。
  Timer? _cachePollTimer;

  /// [B2-EVT] 音频缓存变更事件订阅（进程内 broadcast，对齐原版
  /// EventBus.AUDIO_CACHE_CHANGED 订阅，ChapterListFragment.kt:196-208）：
  /// 听书页批量预下载每章成功即触发本页立即重查 audioCacheList，
  /// 徽标刷新无需等待 1s 轮询；dispose 必须取消订阅（防销毁后回调泄漏）。
  StreamSubscription<AudioCacheChanged>? _audioCacheChangeSub;

  /// [P2-29c 后续] 本书批量下载已失败章节 index 集合（ERROR 态，对齐参考版
  /// failedIndices——源自 `CacheBook.downloadStateFlow`）。数据源经
  /// [BookApi.listFailedChapters]（契约 §2.43.8 cacheDownloadFailedChapters）：
  /// 初始加载 + 1s 轮询（与 [_downloadingIndices] 同周期）刷新；失败记录随
  /// 任务终态保留（供展示与重试），任务重新取到该章开始下载时清除（对齐
  /// 参考版 CacheDownloadStateStore.markFailed/markSuccess 语义）。
  Set<int> _failedIndices = const {};

  /// 标注列表（BookHighlight JSON 解析后的 Map，经 BookApi.highlightListByBook）
  List<Map<String, dynamic>> _highlights = [];
  bool _highlightsLoading = true;
  String? _highlightsError;

  /// 笔记列表（书签标记，契约 §2.52；状态含所属书/加载结果，见 Notifier）

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
    // [P2-28b] 页面打开期间每秒轮询缓存状态（本地书恒视为已缓存，免轮询）
    _startCachePolling();
    // [B2-EVT] 订阅进程内音频缓存变更事件（听书页每章缓存成功后立即重查，
    // 早于 1s 轮询；本页 dispose 时取消订阅）
    _audioCacheChangeSub = AudioCacheEvents.instance.stream.listen(
      _onAudioCacheChanged,
    );
    // 书签按书名+作者加载（对齐原版 bookmarkDao.getByBook，规避同名书混入，
    // 契约 §2.7 getBookmarksByBook，台账 §5.14-2，Task #65）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref
          .read(bookmarkNotifierProvider.notifier)
          .loadByBook(_book.name, _book.author);
      // [P2-3] 笔记加载不能在 initState 修改 provider，移入首帧后
      _loadMarkings();
    });
  }

  /// 初始化在架状态（DB 有记录且非 notShelf / refresh_toc 占位）
  ///
  /// [批31b P1-1] 同时以 DB 记录的 `readConfig` 刷新本页 `_book`：路由参数
  /// 可能是调用方持有的旧快照（阅读器/详情页打开目录时传入的对象），若只读
  /// `_inBookshelf` 而保留旧 `readConfig`，则「目录显示反转/倒序目录」等已落库
  /// 配置在同一对象重开目录时不生效，且后续整书写回会把 DB 值还原。
  ///
  /// 只取 DB 的 `readConfig`（目录勾选项的唯一真源），其余字段保留路由快照：
  /// 调阅方可能持有比 DB 更新的内存进度（阅读器章内位置），整本替换会让
  /// 当前章高亮/定位回退。查询失败或无记录时保持路由快照（未入库在线书
  /// 仅展示、不落库）。
  Future<void> _initBookshelfState() async {
    try {
      final dbBook = await ref.read(bookApiProvider).getBook(_book.bookUrl);
      if (!mounted) return;
      setState(() {
        _inBookshelf = BookOpenUtils.resolveInBookshelf(dbBook, widget.book);
        final dbConfig = dbBook?.readConfig;
        if (dbConfig != null) {
          _book = _book.copyWith(readConfig: dbConfig);
        }
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

  /// [P2-28b] 启动缓存状态轮询（仅在线书；本地书恒视为已缓存，免轮询）。
  ///
  /// 每秒调用一次 [_pollCachedUrls]，与当前 [_cachedUrls] 做 diff，
  /// 仅在出现**新增**已缓存章节时 setState 刷新对应行——批量离线缓存下载
  /// 进行中，每章正文保存后目录页对应行状态实时变动（⬇ 图标 → 字数胶囊/
  /// 无图标），无需退出重进。对齐原版 ChapterListFragment 订阅
  /// EventBus.SAVE_CONTENT 增量刷新行的用户可见行为。
  void _startCachePolling() {
    if (_isLocal) return; // 本地书恒视为已缓存，免轮询
    _cachePollTimer?.cancel();
    _cachePollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _pollCachedUrls();
    });
  }

  /// [B2-EVT] 音频缓存变更事件回调（对齐原版 ChapterListFragment.kt:196-208
  /// 的 AUDIO_CACHE_CHANGED 订阅）：仅供当前书的非本地音频书使用——
  /// 命中后立即重查 [_pollCachedUrls]（内含 audioCacheList），徽标刷新不等
  /// 1s 轮询；复用其「无变化跳过 setState」守卫，事件与轮询结果一致时零重建。
  void _onAudioCacheChanged(AudioCacheChanged event) {
    if (!mounted) return;
    if (event.bookUrl != _book.bookUrl) return;
    if (_isLocal || !_isAudioBook) return;
    unawaited(_pollCachedUrls());
  }

  /// [P2-28b→P2-28c] 轮询缓存态（升级为字数刷新数据链）：单次调用
  /// [BookApi.listCachedChapters]（契约 §2.43.6）同时完成 URL 集合 diff
  /// （翻转「未缓存」⬇ 图标）与字数映射刷新（新缓存章字数胶囊同帧出现，
  /// 对齐参考版 ChapterListFragment 订阅 SAVE_CONTENT 同帧刷行语义）；
  /// 两者均无变化时跳过 setState（避免每秒无谓整行重建）；查询失败保留旧态。
  Future<void> _pollCachedUrls() async {
    try {
      final api = ref.read(bookApiProvider);
      final entries = await api.listCachedChapters(_book.bookUrl);
      final urls = entries.keys.toSet();
      final urlsChanged =
          urls.difference(_cachedUrls).isNotEmpty ||
          _cachedUrls.difference(urls).isNotEmpty;
      final wordCountsChanged = entries.keys.any(
        (u) => _polledWordCounts[u] != entries[u],
      );
      // [P2-29] 下载中集合（契约 §2.43.7）：与缓存态/字数同周期拉取，
      // 驱动下载中行 16px 加载指示动画；单项查询失败保留旧态
      List<int> downloading;
      try {
        downloading = await api.listDownloadingChapters(_book.bookUrl);
      } catch (_) {
        downloading = _downloadingIndices.toList();
      }
      final downloadingSet = downloading.toSet();
      final downloadingChanged =
          downloadingSet.difference(_downloadingIndices).isNotEmpty ||
          _downloadingIndices.difference(downloadingSet).isNotEmpty;
      // [P2-29c 后续] 失败章集合（契约 §2.43.8）：与缓存态/下载中同周期拉取，
      // 驱动失败行红色重试图标（ERROR 态）；单项查询失败保留旧态
      Set<int> failed;
      try {
        failed = (await api.listFailedChapters(_book.bookUrl)).toSet();
      } catch (_) {
        failed = _failedIndices;
      }
      final failedChanged =
          failed.difference(_failedIndices).isNotEmpty ||
          _failedIndices.difference(failed).isNotEmpty;
      // [B1-TOC] 音频书音频缓存下标集合（契约 §2.47 audioCacheList）：与文本
      // 缓存/下载中同周期拉取，仅非本地音频书调用（对齐原版
      // ChapterListFragment.kt:155 的 `if (book.isAudio)` 分支——非音频书
      // 不浪费这次 FFI 调用）；单项查询失败保留旧态，不影响目录展示
      Set<int> audioCached = _audioCachedIndices;
      if (_isAudioBook && !_isLocal) {
        try {
          audioCached = (await api.audioCacheList(
            bookUrl: _book.bookUrl,
          )).toSet();
        } catch (_) {
          audioCached = _audioCachedIndices;
        }
      }
      // 无变化跳过 setState 守卫纳入音频集合（集合为空且未变时同样完全
      // 跳过，不引入每秒空转重建；长度相等且无新增即等价集合相等）
      final audioChanged =
          audioCached.length != _audioCachedIndices.length ||
          audioCached.difference(_audioCachedIndices).isNotEmpty;
      if (!mounted) return;
      if (!urlsChanged &&
          !wordCountsChanged &&
          !downloadingChanged &&
          !failedChanged &&
          !audioChanged) {
        return;
      }
      setState(() {
        _cachedUrls = urls;
        _polledWordCounts
          ..clear()
          ..addAll(entries);
        _downloadingIndices = downloading.toSet();
        _failedIndices = failed;
        _audioCachedIndices = audioCached;
      });
    } catch (_) {
      // 查询失败保留旧态（不影响目录展示）
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _cachePollTimer?.cancel();
    // [B2-EVT] 取消事件订阅（防页面销毁后事件回调泄漏）
    _audioCacheChangeSub?.cancel();
    _debounce?.cancel();
    _tabController.dispose();
    _tocScrollController.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// [UI-fix v2.0.7 | 2026-08-09] Task #26：页面重现（从阅读器返回）时刷新。
  /// 对齐原版 ChapterListFragment 经 EventBus.SAVE_CONTENT 增量刷新语义：
  /// 同步书籍进度（durChapterIndex/Title）使当前章高亮与标题不陈旧。
  /// [P2-28] 同时刷新已缓存章节 URL 集，使目录云图标状态在从阅读器/
  /// 缓存页返回后保持最新。
  @override
  void didPopNext() {
    _refreshOnReshow();
  }

  Future<void> _refreshOnReshow() async {
    try {
      final api = ref.read(bookApiProvider);
      final fresh = await api.getBook(_book.bookUrl);
      if (!mounted) return;
      if (fresh != null) setState(() => _book = fresh);
      // [P2-28] 刷新缓存 URL 集（本地书恒视为已缓存，对齐原版 isLocalBook，不查询）
      if (!_isLocal) {
        try {
          final urls = (await api.listCachedChapterUrls(_book.bookUrl)).toSet();
          if (!mounted) return;
          setState(() => _cachedUrls = urls);
        } catch (_) {
          // 刷新失败保持旧集
        }
      }
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
      // [批43b P2-1] 取解析元信息：规则未命中回退默认时 UI 需提示
      final meta = await api.getChaptersWithMeta(_book.bookUrl);
      var chapters = meta.chapters;
      var usedCustomRule = meta.usedCustomRule;
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
        // 在线目录刷新不经过 TXT 规则解析
        usedCustomRule = false;
      }
      if (!mounted) return;
      // [P2-28] 加载已缓存章节 URL 集供章节行缓存状态图标渲染（对齐原版
      // cacheFileNames 判定，契约 §2.43.5 listCachedChapterUrls）；本地书
      // 恒视为已缓存（对齐原版 isLocalBook），跳过查询。
      Set<String> cachedUrls = const {};
      List<int> downloading = const [];
      // [P2-29c 后续] 音频书初始加载已失败章节集合（契约 §2.43.8
      // cacheDownloadFailedChapters）：首帧即可渲染失败章红色重试图标
      // （对齐参考版打开目录即见 ERROR 态）；失败降级空集（后续 1s 轮询自愈）
      List<int> failed = const [];
      // [B1-TOC] 音频书初始加载已缓存章节下标集合（契约 §2.47
      // audioCacheList）：首帧即可渲染音频已缓存章的「已缓存」徽标
      // （对齐原版 cacheFileJob 建页即 listCachedChapterKeys + 全量刷行）；
      // 仅非本地音频书查询，失败降级空集（后续 1s 轮询自愈）
      Set<int> audioCached = const {};
      if (!_isLocal) {
        try {
          cachedUrls = (await api.listCachedChapterUrls(_book.bookUrl)).toSet();
        } catch (_) {
          // 查询失败降级为全未缓存态，不阻断目录展示
        }
        // [P2-29] 初始加载下载中集合（契约 §2.43.7）：使首帧即可渲染
        // 下载中行 16px 加载指示（对齐参考版打开目录即见 LOADING 态）；
        // 查询失败降级为空集（后续 1s 轮询自愈）
        try {
          downloading = await api.listDownloadingChapters(_book.bookUrl);
        } catch (_) {}
        // [P2-29c 后续] 初始加载失败章节集合（契约 §2.43.8）：使首帧即可
        // 渲染 ERROR 态红色重试图标；查询失败降级为空集（后续 1s 轮询自愈）
        try {
          failed = await api.listFailedChapters(_book.bookUrl);
        } catch (_) {}
        if (_isAudioBook) {
          try {
            audioCached = (await api.audioCacheList(
              bookUrl: _book.bookUrl,
            )).toSet();
          } catch (_) {
            // 查询失败降级为空集，不阻断目录展示（后续 1s 轮询自愈）
          }
        }
        if (!mounted) return;
      }
      setState(() {
        _chapters = chapters;
        _chaptersUsedCustomRule = usedCustomRule;
        _cachedUrls = cachedUrls;
        _downloadingIndices = downloading.toSet();
        _failedIndices = failed.toSet();
        _audioCachedIndices = audioCached;
        _chaptersLoading = false;
        // [批43b P1-2] 目录已加载即同步派生字段：`setBookTocRule` 返回的
        // Book 在重解析前 totalChapterNum=0，目录页底部「第 x / 0」会一直
        // 显示坏值；这里以刚加载的 chapters 为准修正内存快照。
        if (chapters.isNotEmpty) {
          _book = _book.copyWith(
            totalChapterNum: chapters.length,
            latestChapterTitle: chapters.last.title,
          );
        }
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

  /// 加载笔记列表（书签标记，契约 §2.52；按书名+作者跨源）
  ///
  /// 状态（loading/loaded/error/所属书）由 Notifier 维护；失败不在此处
  /// setState，错误页按「当前书 + 本次加载失败」判定（P2-3）。
  Future<void> _loadMarkings() async {
    try {
      await ref
          .read(bookMarkingNotifierProvider.notifier)
          .loadByBook(_book.name, _book.author);
    } catch (_) {
      // 错误已写入 Notifier 状态，由标注 Tab 统一展示
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
      // [P2-8] 取址同详情页刷新：当前书源详情页（originBookUrl 优先、
      // 空回退 bookUrl）；parseWebChapters 第二参仍为稳定主键 bookUrl
      final chJson = await api.webbookChapters(
        jsonEncode(source.toJson()),
        BookOpenUtils.bookFetchUrl(_book),
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
  bool get _isLocal => BookType.isLocalOrigin(_book.origin);

  /// 本地 TXT 书（批43b P3-4：统一走 utils 共享判定，与 Rust 同构，
  /// 覆盖 `.txt` / `.text`，避免「UI 可见但 Rust 拒绝」的假入口）
  bool get _isLocalTxt => isLocalTxtBook(_book);

  /// 音频书（位标记判定，对齐原版 Book.isAudio = isType(BookType.audio)；
  /// bookType 为位标记，须用 `&` 而非 `==`，同 book_open_utils 分流先例）
  bool get _isAudioBook => (_book.bookType & BookType.audio) != 0;

  // ===== 目录展示列表（搜索过滤 + 倒序，保留原始章节 index 供跳转） =====

  /// 展示条目：(原始列表位置, 章节)
  ///
  /// [批31] 反转组合语义逐字对齐原版 `TocListState`（先 `reverseOrder`
  /// 数据反转、再 `reverseDisplay` 展示反转）：两项同开 = 两次反转回到
  /// 原始顺序。条目始终携带**真实章节 index**，因此点击跳转、当前章
  /// 高亮与进度显示不受展示顺序影响（章节身份保持）。
  List<MapEntry<int, BookChapter>> get _displayEntries {
    final query = _searchKey.trim().toLowerCase();
    var entries = _chapters.asMap().entries.toList();
    if (query.isNotEmpty) {
      entries = entries
          .where((e) => e.value.title.toLowerCase().contains(query))
          .toList();
    }
    // ① 数据反转（ReadConfig.reverseToc）
    if (_book.readConfig?.reverseToc ?? false) {
      entries = entries.reversed.toList();
    }
    // ② 展示反转（ReadConfig.reverseTocDisplay，批31；数据顺序不变）
    if (_book.readConfig?.reverseTocDisplay ?? false) {
      entries = entries.reversed.toList();
    }
    return entries;
  }

  /// 滚动定位到指定章节 index（按展示列表位置 * 行高估算偏移）
  void _scrollToChapter(int chapterIndex) {
    if (!_tocScrollController.hasClients) return;
    final entries = _displayEntries;
    final displayIndex = entries.indexWhere(
      (e) => e.value.index == chapterIndex,
    );
    if (displayIndex < 0) return;
    final offset = (displayIndex * _chapterRowExtent).clamp(
      0.0,
      _tocScrollController.position.maxScrollExtent,
    );
    _tocScrollController.jumpTo(offset);
  }

  /// [批31b P3-5] 反转切换后于下一帧重新定位当前章
  ///
  /// 展示顺序改变后原滚动偏移对应到别的章节；待列表按新顺序重建完成
  /// （post frame）再按 `durChapterIndex` 重新定位。
  void _scheduleScrollToCurrentChapter() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _scrollToChapter(_book.durChapterIndex);
    });
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

  List<PopupMenuEntry<String>> _buildMenuItems(bool globalReplaceDefault) {
    final tab = _tabController.index;
    final items = <PopupMenuEntry<String>>[];
    if (tab == 0) {
      // menu_group_text：仅本地 TXT 书可见（对齐原版 isLocalTxt 判定）
      if (_isLocalTxt) {
        items.add(
          const PopupMenuItem(value: 'tocRegex', child: Text('TXT 目录规则')),
        );
        items.add(
          CheckedPopupMenuItem(
            value: 'splitLongChapter',
            checked: _book.readConfig?.splitLongChapter ?? true,
            child: const Text('拆分长章节'),
          ),
        );
        // [批1b-3 审查回修 P2-3] 重新解析目录（对齐参考版 TocScreen.kt:457
        // menu「update_toc」→ TocViewModel.updateToc：本地书重跑
        // LocalBook.getChapterList 并 replaceChaptersAndUpdateBook）。为
        // 「无目录时每章字数」等解析档位改值后的重进目录入口。
        items.add(
          const PopupMenuItem(value: 'reparseToc', child: Text('重新解析目录')),
        );
      }
      // menu_group_toc：目录 Tab 可见
      // [批31] 目录反转（ReadConfig.reverseToc，数据反转）与目录显示反转
      // （ReadConfig.reverseTocDisplay，仅展示反序）为两个独立勾选项：
      // 对齐原版 `TocListState` 的 reverseOrder → reverseDisplay 组合语义
      //（先数据反转、再显示反转；双开回到原始顺序）。
      items.add(
        CheckedPopupMenuItem(
          value: 'reverseToc',
          checked: _book.readConfig?.reverseToc ?? false,
          child: const Text('倒序目录'),
        ),
      );
      items.add(
        CheckedPopupMenuItem(
          value: 'reverseTocDisplay',
          checked: _book.readConfig?.reverseTocDisplay ?? false,
          child: const Text('目录显示反转'),
        ),
      );
      items.add(
        CheckedPopupMenuItem(
          value: 'useReplace',
          // useReplaceRule 存于 ReadConfig（对齐原版 Book.ReadConfig.useReplaceRule）；
          // [批7a P2-1] 勾选态按书级/图片/epub/全局默认的生效值展示
          checked: effectiveReplaceRuleEnabled(_book, globalReplaceDefault),
          child: const Text('使用替换规则'),
        ),
      );
      items.add(
        CheckedPopupMenuItem(
          value: 'loadWordCount',
          checked: _loadWordCount,
          child: const Text('加载字数'),
        ),
      );
    } else if (tab == 1) {
      // menu_group_bookmark：书签 Tab 可见
      items.add(
        const PopupMenuItem(value: 'exportBookmark', child: Text('导出')),
      );
      items.add(
        const PopupMenuItem(value: 'exportMd', child: Text('导出 Markdown')),
      );
    }
    // menu_log：始终可见
    items.add(const PopupMenuItem(value: 'log', child: Text('日志')));
    return items;
  }

  Future<void> _handleMenu(String value) async {
    switch (value) {
      case 'tocRegex':
        // 批43：对齐原版 menu_toc_regex → TxtTocRuleDialog：选择规则后写
        // 当前书 books.tocUrl 并清空本地章节缓存，本页重载目录。
        await showReaderTocRuleDialog(
          context,
          ref,
          book: _book,
          onApplied: (updated) async {
            if (!mounted) return (error: null, usedCustomRule: true);
            setState(() => _book = updated);
            final readerState = ref.read(readerNotifierProvider);
            TocRuleReloadResult? readerResult;
            if (readerState.currentBook?.bookUrl == updated.bookUrl) {
              // 阅读器持有旧章节表：同步按新规则重载（目录页 pop 回阅读器
              // 时 didPopNext 只重读书籍快照，不重拉章节）
              readerResult = await ref
                  .read(readerNotifierProvider.notifier)
                  .reloadAfterTocRuleChange(updated);
            }
            await _loadChapters();
            if (!mounted) return (error: null, usedCustomRule: true);
            // [批43b P3-7] 阅读器重载失败也必须并入结果（此前被直接丢弃，
            // 目录页成功就提示「已应用」，阅读器实际仍停在旧目录）。
            final error =
                readerResult?.error ??
                _chaptersError ??
                (_chapters.isEmpty ? '目录为空（可尝试其它规则）' : null);
            // 阅读器先重解析并已入库时，本页 `_loadChapters` 是缓存命中
            // （used_custom_rule=false 表示「未解析」而非「未命中」）——
            // 以阅读器本次解析结果为准；阅读器未参与时才用本页结果。
            final usedCustomRule =
                readerResult?.usedCustomRule ?? _chaptersUsedCustomRule;
            return (error: error, usedCustomRule: usedCustomRule);
          },
        );
        break;
      case 'splitLongChapter':
        // 拆分长章节存于 ReadConfig（参照 book_info_screen 已有实现）
        // [批32b P2-2] 改走单键写：updateBook 整书快照写会清空 Dart 未建模的
        // readConfig 键（useGlobalAudioSkip/tocExpanded/manualReplaceRuleIds）
        final cfg = _book.readConfig ?? const ReadConfig();
        final nextSplit = !cfg.splitLongChapter;
        await _updateReadConfigField(
          'splitLongChapter',
          nextSplit,
          (c) => c.copyWith(splitLongChapter: nextSplit),
        );
        // 对齐原版 upBookAndToc：切换后需重载目录
        await _loadChapters();
        break;
      case 'reverseToc':
        // [批31] 持久化到 ReadConfig.reverseToc（数据反转）；展示层按
        // 「先数据反转、再显示反转」组合，见 _displayEntries
        // [批32] 改走单键写：updateBook 整书写回会清空 Dart 未建模的
        // readConfig 键（useGlobalAudioSkip/tocExpanded/manualReplaceRuleIds）
        final rtc = _book.readConfig ?? const ReadConfig();
        await _updateReadConfigField(
          'reverseToc',
          !rtc.reverseToc,
          (c) => c.copyWith(reverseToc: !rtc.reverseToc),
        );
        // [批31b P3-5] 展示顺序反转后重新定位当前章（对齐原版列表刷新后
        // scrollToDurChapter 语义），避免用户停留在与原位置无关的行
        _scheduleScrollToCurrentChapter();
        break;
      case 'reverseTocDisplay':
        // [批31] 目录显示反转（对齐原版 ReadConfig.reverseTocDisplay）：
        // 仅展示层反序，数据顺序与章节 index 身份不变
        // [批32] 同 reverseToc：单键持久化，保留未建模 readConfig 键
        final rtd = _book.readConfig ?? const ReadConfig();
        await _updateReadConfigField(
          'reverseTocDisplay',
          !rtd.reverseTocDisplay,
          (c) => c.copyWith(reverseTocDisplay: !rtd.reverseTocDisplay),
        );
        // [批31b P3-5] 同 reverseToc：切换后重新定位当前章
        _scheduleScrollToCurrentChapter();
        break;
      case 'useReplace':
        // 接 ReadConfig.useReplaceRule 字段经 BookApi 更新（对齐原版 menu_use_replace）
        // [批32b P2-2] 同 splitLongChapter：单键持久化，保留未建模 readConfig 键
        // [批7a P2-1] 取反基于生效值：图片书/本地 epub/全局默认关闭时
        // 首次点击写入显式 true。provider 尚在加载时等待一次，避免把
        // 全局 false 误读为 fallback true 后写成显式 false。
        final cachedDefault = ref.read(replaceEnableDefaultProvider).value;
        bool globalReplaceDefault;
        if (cachedDefault != null) {
          globalReplaceDefault = cachedDefault;
        } else {
          try {
            globalReplaceDefault = await ref.read(
              replaceEnableDefaultProvider.future,
            );
          } catch (_) {
            globalReplaceDefault = true;
          }
          if (!mounted) return;
        }
        final nextReplace = !effectiveReplaceRuleEnabled(
          _book,
          globalReplaceDefault,
        );
        await _updateReadConfigField(
          'useReplaceRule',
          nextReplace,
          (c) => c.copyWith(useReplaceRule: nextReplace),
        );
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
      case 'reparseToc':
        await _reparseLocalToc();
        break;
    }
  }

  /// [批1b-3 审查回修 P2-3] 重新解析目录（本地 TXT 专属，对齐参考版
  /// `TocViewModel.updateToc` 本地分支：重跑解析并 `replaceChaptersAndUpdateBook`）。
  ///
  /// 失效通道复用 `setBookTocRule`：把当前 `books.tocUrl` 拆回
  /// `{rule, replacement}` JSON 原样写回（Rust 单列写 + 同事务清空
  /// `chapters` 表该书行并重置目录派生字段）——规则选择原样保留
  /// （默认书为空串 → `null` 恢复默认，语义不变），下一次
  /// `_loadChapters` 必然按当前设置（含 `maxLengthWithNoToc` 档位）重新
  /// 懒解析。阅读器持有旧章节表时同步 `reloadAfterTocRuleChange`（与
  /// `tocRegex` 分支同一数据链）。
  ///
  /// [批1b-3 复验 P2-5] 全链 try/catch：Rust 清表/重载任一步失败都
  /// SnackBar 明示「重新解析目录失败」并 return——清表 fail-closed 时
  /// 旧目录仍在，绝不可误报成功（兜底口径对齐
  /// `reader_toc_rule_dialog` 的「设置目录规则失败: $e」）。
  Future<void> _reparseLocalToc() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final api = ref.read(bookApiProvider);
      // 1) 拆回规则 JSON 并原样写回 → 清章节行 + 失效派生字段
      //    （buildReparseRuleJson：直接传 raw tocUrl 会被 Rust 当无分隔符
      //    正则重编码，追加多余分隔符且丢失 replacement）
      final updated = await api.setBookTocRule(
        _book.bookUrl,
        buildReparseRuleJson(_book.tocUrl),
      );
      if (!mounted) return;
      setState(() => _book = updated);
      // 2) 阅读器若持有该书，同步重载目录与正文
      final readerState = ref.read(readerNotifierProvider);
      if (readerState.currentBook?.bookUrl == _book.bookUrl) {
        final result = await ref
            .read(readerNotifierProvider.notifier)
            .reloadAfterTocRuleChange(_book);
        if (result.error != null) {
          if (!mounted) return;
          messenger.showSnackBar(
            SnackBar(content: Text('重新解析目录失败: ${result.error}')),
          );
          return;
        }
      }
      // 3) 本页重载（必然走懒解析，消费最新解析档位）
      await _loadChapters();
      if (!mounted) return;
      if (_chaptersError != null) {
        messenger.showSnackBar(
          SnackBar(content: Text('重新解析目录失败: $_chaptersError')),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text('已重新解析目录（共 ${_chapters.length} 章）')),
      );
    } catch (e) {
      // [P2-5] fail-closed 不误报：Rust 拒绝/清表失败时旧目录仍在，
      // 必须明示失败（口径对齐 reader_toc_rule_dialog）
      messenger.showSnackBar(SnackBar(content: Text('重新解析目录失败: ${errorMessage(e)}')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('暂无书签可导出')));
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出成功: $savedPath')));
    } catch (e) {
      // 写入失败给出可读错误（对齐原版 AppLog.put「导出失败」提示语义）
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出失败: ${_errMsg(e)}')));
    }
  }

  /// 单键持久化 `readConfig` 并同步本页/阅读器状态（批32，契约 §2.2）
  ///
  /// [批32b P2-2] 目录页全部 readConfig 勾选项（`reverseToc` /
  /// `reverseTocDisplay` / `splitLongChapter` / `useReplaceRule`）统一走单键写：
  /// `updateBook` 是整书快照写，Dart `ReadConfig` 未建模的键
  /// （`useGlobalAudioSkip`、`tocExpanded`、`manualReplaceRuleIds` 等）会在
  /// Dart→Rust 往返中被清空；单键写在 DB 侧只合并目标键，其余键原样保留。
  /// 本页仍用 [apply] 在内存快照上更新对应字段，保持 UI 即时响应。
  ///
  /// [批31b P1-1] 落库成功后若阅读器正打开同一本书，同步 ReaderNotifier 的
  /// `currentBook`（与 `reader_menu_panel._toggleReverseTocDisplay` 同构）：
  /// 阅读器持有的是打开时的 Book 快照，目录页改了 `readConfig` 后若不同步，
  /// 阅读器后续任何整书 `updateBook`（设置保存/进度回写等）都会用旧快照
  /// 把刚落库的配置还原。
  Future<void> _updateReadConfigField(
    String key,
    bool value,
    ReadConfig Function(ReadConfig config) apply,
  ) async {
    try {
      await ref
          .read(bookApiProvider)
          .updateReadConfigField(_book.bookUrl, key, jsonEncode(value));
      // 页面已关闭（勾选后立即返回）：跳过内存同步——阅读器返回时会经
      // RouteAware.didPopNext 重读 DB（见 reader_screen.dart）
      if (!mounted) return;
      final updated = _book.copyWith(
        readConfig: apply(_book.readConfig ?? const ReadConfig()),
      );
      setState(() => _book = updated);
      final readerState = ref.read(readerNotifierProvider);
      if (readerState.currentBook?.bookUrl == updated.bookUrl) {
        ref.read(readerNotifierProvider.notifier).updateCurrentBook(updated);
        // [批7a P1-A 设备复验] 上面的 eager 快照同步会让阅读器 didPopNext
        // 的 fresh/latest 对比无差异，返回时不会自动重载正文。这两个键
        // 直接改变正文净化/分段，必须在目录页内立即重载；失败由
        // ReaderNotifier 写入 error 态（不抛出），pop 后正文即为新配置结果。
        // mounted=false 的提前返回分支不同步快照，仍由 didPopNext 兜底。
        if (key == 'useReplaceRule' || key == 'reSegment') {
          await ref
              .read(readerNotifierProvider.notifier)
              .reloadChapterContent();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('更新失败: ${_errMsg(e)}')));
      }
    }
  }

  // ===== 构建 =====

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // [批7a P2-1] 全局默认替换净化开关（provider 未就绪回落 true）
    final globalReplaceDefault =
        ref.watch(replaceEnableDefaultProvider).value ?? true;
    // [PARITY C2 T3] 头部对齐参考版：章名大标题与「N / M」页码同行（参考为
    // 「章节名 + 页码」整体大标题，与右侧 🔍/⋮ 分离；此前为两行 Column 堆叠）。
    final currentChapterTitle = _book.durChapterTitle?.isNotEmpty == true
        ? _book.durChapterTitle!
        : '';
    final chapterProgressText =
        '${_book.durChapterIndex + 1} / ${_chapters.isNotEmpty ? _chapters.length : (_book.totalChapterNum > 0 ? _book.totalChapterNum : 0)}';
    // [GLOBALCOMP B4] 页壳统一：AppScaffold（行为等价直通 Scaffold）
    return AppScaffold(
      topBar: LegadoAppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索...',
                  // [B3] 顶栏沉浸搜索框：三态显式无边框，防主题底线式渗入
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onChanged: _onSearchChanged,
              )
            : currentChapterTitle.isNotEmpty
            // [PARITY C2 T3] 章名（主标题）+ 页码（小字）同行，整体作为
            // AppBar 标题区，与右侧 🔍/⋮ 动作分离（对齐参考大标题形态）。
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      currentChapterTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    chapterProgressText,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              )
            : Text(_book.name.isNotEmpty ? _book.name : '目录'),
        actions: [
          IconButton(
            icon: Icon(
              _searching ? Symbols.close_rounded : Symbols.search_rounded,
            ),
            tooltip: _searching ? '关闭搜索' : '搜索',
            onPressed: _toggleSearch,
          ),
          PopupMenuButton<String>(
            tooltip: '更多',
            onSelected: _handleMenu,
            itemBuilder: (_) => _buildMenuItems(globalReplaceDefault),
          ),
        ],
        // AppBar 内 TabBar 显式指定前景色，避免白底白字（项目规范）
        // [LAYOUT_PLAN P1] Tab 标准化：无分割线 + labelLargeEmphasized
        bottom: TabBar(
          controller: _tabController,
          // 全局 tabBarTheme 设了 TabAlignment.start，非 scrollable TabBar
          // 必须覆盖为 fill，否则触发断言崩溃（同 rss_source_edit_screen 先例）
          tabAlignment: TabAlignment.fill,
          labelColor: cs.primary,
          unselectedLabelColor: cs.onSurfaceVariant,
          indicatorColor: cs.primary,
          dividerColor: Colors.transparent,
          labelStyle: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
          unselectedLabelStyle: Theme.of(
            context,
          ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w500),
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
      // [PARITY C2 T4] 目录底栏「页码 + ↑↓」条已移除（参考无）：跳转顶部/底部与
      // 定位当前章能力保留于下方目录 FAB 展开菜单（_buildJumpFab）。
      // [UI_SYNC_REFACTOR S5 修 | 2026-09-08] 目录 FAB 展开菜单（对齐参考版）：
      // 定位至当前阅读 / 移至顶部 / 移至底部 / 一键缓存（自当前章入队）。
      // 仅目录 Tab 显示；AnimatedBuilder 保证切页签时显隐即时刷新 — Qoder
      floatingActionButton: AnimatedBuilder(
        animation: _tabController,
        builder: (context, _) => _tabController.index == 0
            ? _buildJumpFab(context)
            : const SizedBox.shrink(),
      ),
    );
  }

  /// 目录 FAB：点击展开四项快捷操作（对齐参考版展开式菜单形态）
  Widget _buildJumpFab(BuildContext context) {
    final actions = [
      (Icons.my_location_rounded, '定位至当前阅读', _locateCurrentChapter),
      (Icons.vertical_align_top_rounded, '移至顶部', _scrollTocTop),
      (Icons.vertical_align_bottom_rounded, '移至底部', _scrollTocBottom),
      (Icons.cloud_download_rounded, '一键缓存', _cacheFromCurrent),
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_jumpMenuOpen)
          for (final (icon, label, onTap) in actions)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: FilledButton.tonalIcon(
                onPressed: () {
                  setState(() => _jumpMenuOpen = false);
                  onTap();
                },
                icon: Icon(icon, size: 20),
                label: Text(label),
              ),
            ),
        FloatingActionButton(
          onPressed: () => setState(() => _jumpMenuOpen = !_jumpMenuOpen),
          child: Icon(
            _jumpMenuOpen ? Icons.close_rounded : Icons.menu_open_rounded,
          ),
        ),
      ],
    );
  }

  /// 定位至当前阅读（复用进入目录时的定位逻辑）
  void _locateCurrentChapter() => _scrollToChapter(_book.durChapterIndex);

  void _scrollTocTop() {
    if (!_tocScrollController.hasClients) return;
    _tocScrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollTocBottom() {
    if (!_tocScrollController.hasClients) return;
    _tocScrollController.animateTo(
      _tocScrollController.position.maxScrollExtent,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  /// 一键缓存：自当前章到末章加入下载队列（对齐原版 download_after 语义）
  Future<void> _cacheFromCurrent() async {
    final total = _book.totalChapterNum;
    final start = _book.durChapterIndex;
    if (total <= 0 || start > total - 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无可缓存的章节')));
      return;
    }
    try {
      await ref
          .read(bookApiProvider)
          .cacheDownloadStart(_book.bookUrl, start, total - 1);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已从当前章加入缓存队列')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('缓存启动失败：${errorMessage(e)}')));
    }
  }

  /// [P2-29/P2-29c] 单章下载（NONE 态 ⬇ 点击）/ 单章重下（ERROR 态红色
  /// 重试图标点击）。对齐参考版 canDownload = NONE || ERROR 时点击状态图标
  /// （TocScreen.kt :879-881 + :958-965）→ TocIntent.DownloadChapter →
  /// TocViewModel.downloadChapter :863-869 按章索引单章下载；
  /// 复用 [BookApi.cacheDownloadStart]（契约 §2.43.3 闭区间语义 start==end
  /// 即单章；同书在途任务复用语义不变）启动下载；启动成功后 1s 轮询
  /// （P2-28b/c）自动把该行翻为下载中 16px 加载指示，完成后翻为对勾/
  /// 字数胶囊，失败翻为红色重试图标（失败集合经契约 §2.43.8
  /// listFailedChapters 轮询，取章重下即清、再失败重新记入）。
  /// [retry] 仅影响用户反馈文案：ERROR 重下 / NONE 首次下载。
  Future<void> _downloadChapter(int chapterIndex, {required bool retry}) async {
    try {
      await ref
          .read(bookApiProvider)
          .cacheDownloadStart(_book.bookUrl, chapterIndex, chapterIndex);
      if (!mounted) return;
      var title = '';
      for (final c in _chapters) {
        if (c.index == chapterIndex) {
          title = c.title;
          break;
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            title.isNotEmpty
                ? '「$title」${retry ? '已加入重新下载队列' : '已加入缓存队列'}'
                : '第 ${chapterIndex + 1} 章${retry ? '已加入重新下载队列' : '已加入缓存队列'}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${retry ? '重新下载' : '缓存'}启动失败：${errorMessage(e)}')),
      );
    }
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
            Icon(
              Symbols.error_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
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
    // [UI_SYNC_REFACTOR R3] 千级章节列表快速滚动条（对齐原版 FastScroller）
    return Md3FastScroller(
      controller: _tocScrollController,
      child: ListView.builder(
        controller: _tocScrollController,
        itemExtent: _chapterRowExtent,
        itemCount: entries.length,
        itemBuilder: (context, i) {
          final chapter = entries[i].value;
          return chapter.isVolume
              ? _buildVolumeRow(context, chapter)
              : _buildChapterRow(context, chapter);
        },
      ),
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
        style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface),
      ),
    );
  }

  /// 章节行：当前章行级高亮（[P2-29b] 对齐参考版 ReaderSheetChapterItem
  /// :965-974——isDur → 行背景 secondaryContainer + 标题 onSecondaryContainer，
  /// 替代此前 primary 10% 淡底；[PARITY C2 T5]）；右侧状态元素为
  /// **互斥分支**（[P2-29b] 对齐参考版 ReaderSheetChapterStatus :1039-1096 单
  /// when 链，优先级从高到低，字数胶囊短路全部状态图标）：
  /// - ① showCount（加载字数开关开 && wordCount 非空 && (本地书 || 已缓存)
  ///   && 非 ERROR，[P2-29c] 排除 ERROR 对齐参考版 StatusIcon :1146-1157
  ///   字数分支仅 LOCAL/SUCCESS 态）→ 字数胶囊：当前章 = primaryContainer 底 +
  ///   onPrimaryContainer 字；普通章 = surfaceContainer 底 + onSurfaceVariant
  ///   字；8sp labelSmallEmphasized，padding 横 6 纵 2，圆角 8
  ///   （当前章有字数时只显示高亮胶囊，无定位图标）
  /// - ② isDur（当前章且无胶囊）→ 定位图标（Icons.Default.LocationOn →
  ///   Icons.location_on；[P2-29b] 着色统一 secondary，对齐参考版
  ///   ReaderSheetStatusIcon :1100-1111 tint=colorScheme.secondary，16px）
  /// - ③ 下载中（index ∈ _downloadingIndices，数据经
  ///   BookApi.listDownloadingChapters 契约 §2.43.7，对齐参考版 LOADING 态
  ///   `AppContainedLoadingIndicator` 16dp 形态）→ 16px 加载指示
  ///   （SizedBox 16 + CircularProgressIndicator strokeWidth 2，着色 primary）
  /// - ④ 失败（index ∈ _failedIndices，对齐参考版 ERROR 态）→ 红色重试图标
  ///   （Icons.refresh，error 着色）可点击 → 单章重下复用
  ///   cacheDownloadStart(bookUrl, idx, idx)；[P2-29c] 优先级提到已缓存之前
  ///   （对齐参考版 TocViewModel rawDataFlow :510-514 running > error >
  ///   cached 判定序：失败章不显示成 SUCCESS 对勾）；数据链留项：Rust 任务表
  ///   仅 failed 计数、无逐章失败记录 → 生产恒空恒不显示（不伪造，契约
  ///   §2.43.7 ERROR 留项）
  /// - ⑤ 已缓存且无胶囊（非音频书 url ∈ _cachedUrls；音频书
  ///   chapter.index ∈ _audioCachedIndices，契约 §2.47，[B1-TOC]；如字数
  ///   开关关或 wordCount 空）→ 对勾图标（参考版 SUCCESS 态 :1069-1071
  ///   CheckCircle，secondary 色）
  /// - ⑥ 未缓存网络章 → 离线下载图标 ⬇（Icons.Outlined.DownloadForOffline →
  ///   Icons.download_for_offline_outlined，着色 outline 50% 透明度）；
  ///   [P2-29c] 可点击单章下载（对齐参考版 canDownload = NONE || ERROR
  ///   :879-881 + :958-965 → downloadChapter :863-869）：复用
  ///   cacheDownloadStart(bookUrl, idx, idx)（契约 §2.43.3 闭区间单章语义）
  /// - ⑦ 本地书章节（无胶囊且非当前章）→ 无显示（参考版 LOCAL 态：showCount
  ///   假且非 isDur 时 when 链无分支命中，渲染空；本地书不等同网络书 SUCCESS
  ///   态，故也不显示对勾图标；卷标题行走 _buildVolumeRow，不参与判定）
  /// 字数胶囊：原样展示 wordCount（Rust 回填链已按原版 wordCountFormat 存
  /// 「1200字」/「1.1万字」形态，与原版 ChapterListAdapter:231 / 参考版
  /// TocScreen.kt:1205 的 as-is 展示一致，不再追加「 字」后缀）。
  /// 布局对齐 item_chapter_list.xml：状态元素居右（互斥，至多一个）。
  Widget _buildChapterRow(BuildContext context, BookChapter chapter) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isCurrent = chapter.index == _book.durChapterIndex;
    // [P2-28c] 优先取轮询字数映射（新缓存章胶囊同帧出现），回退章节数据值
    final wordCount = _polledWordCounts[chapter.url] ?? chapter.wordCount;
    // [B1-TOC] 已缓存判定分型（对齐原版 ChapterListAdapter.kt:192-198）：
    // 音频书取音频缓存下标集合（契约 §2.47 audioCacheList，原版
    // `audioCacheKeys.contains(AudioCacheKey.from(chapter))`）；非音频书
    // 沿用文本缓存 URL 判定（契约 §2.43.5 cacheFileNames 等价）。本地书
    // 恒视为已缓存不显示徽标（原版 isLocalBook → cached=true → 图标隐藏；
    // 且本地书无书源不可缓存）。分卷章节行走 _buildVolumeRow，不进入本行。
    // [批39] 显示口径改为宽松判定（有正文即已缓存，缺图仍算已缓存，
    // 对齐参考版 TocViewModel.kt:293-320）；下载链路仍严格（Rust 逐章抓取）。
    final isCached =
        tocChapterCacheBadge(
          isLocal: _isLocal,
          isAudioBook: _isAudioBook,
          audioCached: _audioCachedIndices.contains(chapter.index),
          textCached: _cachedUrls.contains(chapter.url),
        ) ==
        TocChapterCacheBadge.cached;
    // [P2-29c] 下载中/失败标记先于 showCount 判定：失败章不显示字数胶囊
    // （对齐参考版 StatusIcon :1146-1157 字数分支仅 LOCAL/SUCCESS 态命中）
    final bool isDownloading = _downloadingIndices.contains(chapter.index);
    final bool isError = _failedIndices.contains(chapter.index);
    // [P2-29b] 字数胶囊条件对齐参考版 showCount（:1039-1041）：
    // 开关开 && wordCount 非空 && (本地书 || 网络书已缓存)；
    // [P2-29c] && !isError（ERROR 态优先于 SUCCESS/字数）
    final showCount =
        _loadWordCount &&
        (wordCount?.isNotEmpty ?? false) &&
        (_isLocal || isCached) &&
        !isError;
    // [P2-29b] 状态元素互斥分支（对齐参考版单 when 链，①~⑥ 至多渲染一个；
    // size 16 沿用 P2-28 行高适配；内容带取整行 48 保证图标居中可命中，见
    // 下方 contentPadding 注释）
    final Widget? statusTrailing;
    if (showCount) {
      // ① 字数胶囊（isDur 分色；短路全部状态图标——当前章不再与定位图标并存）
      statusTrailing = Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          // 参考版 :1045-1049：当前章 = primaryContainer 底，
          // 普通章 = surfaceContainer 底（灰底）
          color: isCurrent ? cs.primaryContainer : cs.surfaceContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        // [P2-28b] 原样展示（Rust 回填值已带「字/万字」后缀；showCount 守卫
        // 已保证非空）
        child: Text(
          wordCount!,
          style: textTheme.labelSmall?.copyWith(
            fontSize: 8,
            // 8sp labelSmallEmphasized（参考版 :1054）
            fontWeight: FontWeight.w500,
            // 参考版 :1055-1059：当前章 = onPrimaryContainer，
            // 普通章 = onSurfaceVariant
            color: isCurrent ? cs.onPrimaryContainer : cs.onSurfaceVariant,
          ),
        ),
      );
    } else if (isCurrent) {
      // ② 当前章且无胶囊（被 ① 短路）：定位图标（参考版 DUR 态，
      // ReaderSheetStatusIcon tint=secondary，非红色）
      statusTrailing = Icon(Icons.location_on, size: 16, color: cs.secondary);
    } else if (isDownloading) {
      // ③ 下载中：16px 加载指示（对齐参考版 LOADING 态 16dp 转圈形态）
      statusTrailing = SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
      );
    } else if (isError) {
      // ④ 失败（[P2-29c] 优先级先于已缓存，对齐参考版 rawDataFlow
      // :510-514 running > error > cached 判定序）：红色重试图标可点击 →
      // 单章重下复用 cacheDownloadStart(bookUrl, idx, idx)（契约 §2.43.3
      // 闭区间单章语义）；shrinkWrap 保持 16px 图标几何（P2-28/29 行高
      // 适配口径），不改变行内状态元素对齐
      statusTrailing = IconButton(
        icon: Icon(Icons.refresh, size: 16, color: cs.error),
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        // 命中区 24×24 对齐参考版（视觉仍 16；16×16 仅参考版面积的
        // 44%。不上 48：参考版未做，且占满行高有 P2-29 中心裁切回归风险）
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        tooltip: '重新下载本章',
        onPressed: () => _downloadChapter(chapter.index, retry: true),
      );
    } else if (isCached) {
      // ⑤ 已缓存且无胶囊（字数开关关或 wordCount 空）：对勾图标
      // （参考版 SUCCESS 态 :1069-1071 CheckCircle，secondary 色）；
      // [B1-TOC] 音频书的已缓存判定来自音频缓存下标集合（契约 §2.47）
      statusTrailing = Icon(Icons.check_circle, size: 16, color: cs.secondary);
    } else if (!_isLocal && !isCached) {
      // ⑥ 未缓存网络章：离线下载图标 ⬇（参考版 NONE 态 outline 色）；
      // [P2-29c] 可点击单章下载（对齐参考版 canDownload = NONE || ERROR
      // :879-881 + :958-965 状态图标挂 onDownloadClick → downloadChapter
      // :863-869），复用 cacheDownloadStart(bookUrl, idx, idx)（契约
      // §2.43.3 闭区间单章语义）；shrinkWrap 保持 16px 图标几何
      statusTrailing = IconButton(
        icon: Icon(
          Icons.download_for_offline_outlined,
          size: 16,
          color: cs.outline.withValues(alpha: 0.5),
        ),
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        // 命中区 24×24 对齐参考版（视觉仍 16；同上不上 48 的理由）
        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
        style: IconButton.styleFrom(
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        tooltip: '下载本章',
        onPressed: () => _downloadChapter(chapter.index, retry: false),
      );
    } else {
      // ⑦ 本地书章节（无胶囊且非当前章）：无显示（参考版 LOCAL 态渲染空，
      // 本地书恒视为已缓存但不显示对勾图标，对齐原版 isLocalBook 语义）
      statusTrailing = null;
    }
    return ListTile(
      dense: true,
      // [P2-29b] 当前章行级高亮对齐参考版 ReaderSheetChapterItem :965-974：
      // isDur → 行背景 secondaryContainer + 标题 onSecondaryContainer（蓝色
      // 主调下即此前量化的淡蓝底 ≈(238,243,253)，替代 primary 10% 铺底）
      tileColor: isCurrent ? cs.secondaryContainer : null,
      // [P2-29b] 行级文字色：M3 ListTile 以 effectiveColor 覆写标题样式色，
      // 经 textColor 参数注入（普通行回退 listTileTheme 的 onSurface 不变）
      textColor: isCurrent ? cs.onSecondaryContainer : null,
      // [LAYOUT_MOTION_AUDIT L3] 章节行内边距 horizontal8；vertical 取 0 而非 12：
      // M3 ListTile trailing 的 _yOffsetFor 按整 tile 高 48 居中后再叠加
      // contentPadding.vertical，v12 会把 16px 状态图标下移 12px（底边超出 24px
      // 内容带），中心点被裁切，ERROR 重试图标 tester.tap 命中不到。vertical 0
      // 使内容带=整行 48，图标居中（16..32）可命中；dense 自然行高 48 与 itemExtent
      // 48 一致，标题仍垂直居中，视觉与 P2-28 不变。
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(chapter.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      // [P2-29b] 右侧状态元素：互斥分支——字数胶囊与状态图标不再并存
      // （对齐参考版单 when 链），两者皆无时为 null
      trailing: statusTrailing,
      // 返回选中章节 index，由调用方走现有阅读跳转链路（对齐原版 openChapter setResult）
      onTap: () => Navigator.of(context).pop(chapter.index),
    );
  }

  // [PARITY C2 T4] 原「目录底栏：当前章节名 + 跳转顶部/底部」已移除（参考无底栏）；
  // 跳转顶部/底部与定位当前章能力保留于目录 FAB 展开菜单（_buildJumpFab）。

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
            Icon(
              Symbols.error_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
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
              .where(
                (b) =>
                    b.chapterName.toLowerCase().contains(query) ||
                    b.bookText.toLowerCase().contains(query) ||
                    b.content.toLowerCase().contains(query),
              )
              .toList();
    if (bookmarks.isEmpty) {
      // [UI_SYNC_REFACTOR S5 修 | 2026-09-07] 空态对齐参考版颜文字彩蛋
      // （(╮_╰) 暂无书签；颜文字空态为已授权口径）— Qoder
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '(╮_╰)',
              style: TextStyle(
                fontSize: 40,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
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
            child: Icon(
              Symbols.delete_rounded,
              color: Theme.of(context).colorScheme.onError,
            ),
          ),
          confirmDismiss: (_) => _confirmDeleteBookmark(bookmark),
          onDismissed: (_) => ref
              .read(bookmarkNotifierProvider.notifier)
              .deleteBookmark(bookmark.id),
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
                  Icon(
                    Symbols.bookmark_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      bookmark.chapterName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // [Task #54 | 2026-08-10] 缺陷⑤修复：bookmark.time 已是
                  // epoch 毫秒，删除多余的 ×1000 换算 — Qoder
                  Text(
                    _formatTime(bookmark.time),
                    style: theme.textTheme.labelSmall,
                  ),
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
    final markingState = ref.watch(bookMarkingNotifierProvider);
    final markingsCurrent = markingState.isFor(_book.name, _book.author);
    final markings = markingsCurrent
        ? markingState.items
        : const <BookMarking>[];
    final markingsError = markingsCurrent ? markingState.error : null;
    if (_highlightsLoading || markingState.loading || !markingsCurrent) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _highlightsError ?? markingsError;
    if (error != null && _highlights.isEmpty && markings.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.error_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(error, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () {
                _loadHighlights();
                _loadMarkings();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final query = _searchKey.trim().toLowerCase();
    final filteredMarkings = query.isEmpty
        ? markings
        : markings.where((m) {
            final anchor = BookMarkingAnchor.tryParse(m.anchorJson);
            return m.chapterName.toLowerCase().contains(query) ||
                (anchor?.selectedText.toLowerCase().contains(query) ?? false) ||
                m.note.toLowerCase().contains(query);
          }).toList();
    final highlights = query.isEmpty
        ? _highlights
        : _highlights.where((h) {
            final chapterName = (h['chapterName'] ?? '')
                .toString()
                .toLowerCase();
            final bookText = (h['bookText'] ?? '').toString().toLowerCase();
            final note = (h['note'] ?? '').toString().toLowerCase();
            return chapterName.contains(query) ||
                bookText.contains(query) ||
                note.contains(query);
          }).toList();
    if (filteredMarkings.isEmpty &&
        highlights.isEmpty &&
        markingsError == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Symbols.border_color_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(query.isEmpty ? '暂无标注' : '未找到匹配的标注'),
          ],
        ),
      );
    }
    final children = <Widget>[];
    if (markingsError != null) {
      // 高亮非空时笔记加载失败不再静默：笔记区先显示错误行与重试
      children.add(_buildMarkingErrorRow(context, markingsError));
    }
    if (filteredMarkings.isNotEmpty) {
      children.add(_buildSectionHeader(context, '笔记'));
      children.addAll(
        filteredMarkings.map((m) => _buildMarkingTile(context, m)),
      );
    }
    if (highlights.isNotEmpty) {
      if (filteredMarkings.isNotEmpty) {
        children.add(_buildSectionHeader(context, '标注'));
      }
      children.addAll(highlights.map((h) => _buildHighlightTile(context, h)));
    }
    return ListView(children: children);
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    final theme = Theme.of(context);
    return Padding(
      key: ValueKey('toc-section-$title'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  /// 笔记加载失败行（高亮非空时仍可见，避免静默）
  Widget _buildMarkingErrorRow(BuildContext context, String error) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('toc-marking-error'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(
              Symbols.error_rounded,
              size: 18,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '笔记加载失败：${errorMessage(error)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              key: const ValueKey('toc-marking-retry'),
              onPressed: _loadMarkings,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  /// 笔记行（书签标记）：效果色/线型、选中文本、备注、章节名、时间、启停
  Widget _buildMarkingTile(BuildContext context, BookMarking marking) {
    final theme = Theme.of(context);
    final anchor = BookMarkingAnchor.tryParse(marking.anchorJson);
    final style = BookMarkingStyle.tryParse(marking.styleJson);
    final effect = MarkingEffect.fromStyle(style);
    final color = Color(MarkingEffect.colorOf(style));
    final selectedText = anchor?.selectedText ?? '';
    final chapterIndex = marking.chapterIndex;
    final chapterName = marking.chapterName.isNotEmpty
        ? marking.chapterName
        : (chapterIndex == null ? '--' : '第${chapterIndex + 1}章');
    final time = marking.updatedAt > 0 ? marking.updatedAt : marking.createdAt;
    return Card(
      key: ValueKey('toc-marking-tile-${marking.id}'),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => _editMarking(marking, anchor),
        // 参考版：tap 编辑、长按跳章；chapterIndex 为 null 不跳 0 章
        onLongPress: chapterIndex == null
            ? null
            : () => Navigator.of(context).pop(chapterIndex),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 4,
                height: 40,
                margin: const EdgeInsets.only(top: 2, right: 10),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          effect.label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: color,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            chapterName,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          _formatTime(time),
                          style: theme.textTheme.labelSmall,
                        ),
                      ],
                    ),
                    if (selectedText.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        selectedText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          decoration: switch (effect) {
                            MarkingEffect.strike => TextDecoration.lineThrough,
                            MarkingEffect.solid ||
                            MarkingEffect.wave ||
                            MarkingEffect.dashed ||
                            MarkingEffect.highlight => TextDecoration.underline,
                            _ => null,
                          },
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (marking.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        '备注: ${marking.note}',
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
              Switch(
                key: ValueKey('toc-marking-switch-${marking.id}'),
                value: marking.enabled,
                onChanged: (value) => _toggleMarking(marking, value),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editMarking(
    BookMarking marking,
    BookMarkingAnchor? anchor,
  ) async {
    final saved = await MarkingSheet.show(
      context,
      bookName: _book.name,
      bookAuthor: _book.author,
      bookUrl: marking.bookUrl,
      chapterIndex: marking.chapterIndex ?? anchor?.chapterIndex ?? 0,
      chapterName: marking.chapterName,
      chapterPosition: anchor?.chapterPosition ?? 0,
      selectedText: anchor?.selectedText ?? '',
      contextBefore: anchor?.contextBefore ?? '',
      contextAfter: anchor?.contextAfter ?? '',
      existing: marking,
    );
    if (!mounted || saved == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存笔记'), duration: Duration(seconds: 2)),
    );
  }

  Future<void> _toggleMarking(BookMarking marking, bool enabled) async {
    try {
      await ref
          .read(bookMarkingNotifierProvider.notifier)
          .setEnabled(marking.id, enabled);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('更新笔记失败：${_errMsg(e)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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
                  Icon(
                    Symbols.border_color_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      chapterName,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
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
