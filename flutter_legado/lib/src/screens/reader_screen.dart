import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/bookmark/bookmark_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../widgets/reader/reader_bottom_bar.dart';
import '../widgets/reader/reader_catalog_drawer.dart';
import '../widgets/reader/reader_page_view.dart';
import '../widgets/reader/reader_settings_sheet.dart';
import '../widgets/reader/reader_status_strip.dart';
import '../widgets/reader/reader_top_bar.dart';
import 'reader_config_panel.dart';

/// 阅读器页面（Riverpod ConsumerStatefulWidget 薄壳）
///
/// 状态由 [ReaderNotifier] 管理；分页/翻页渲染由 [ReaderPageView] 承担；
/// 工具栏/目录/设置/状态栏拆分为独立子组件（widgets/reader/）。
/// 本文件仅负责编排：高级配置、自动翻页、点击区域、预加载、书签、正文搜索。
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<ReaderPageViewState> _pageViewKey =
      GlobalKey<ReaderPageViewState>();

  /// 阅读器高级配置（自动翻页/点击区域/段距/状态栏）
  ReaderAdvancedConfig _advConfig = ReaderAdvancedConfig();

  /// 自动翻页定时器
  Timer? _autoTimer;

  /// 上一章是否处于加载状态（用于检测章节加载完成以触发预加载）
  bool _wasLoading = false;

  /// 已触发过预加载的章节索引（避免重复预加载）
  int _lastPreloadedIndex = -1;

  @override
  void initState() {
    super.initState();
    _loadAdvancedConfig();
  }

  Future<void> _loadAdvancedConfig() async {
    final config = await ReaderAdvancedConfig.load();
    if (!mounted) return;
    setState(() => _advConfig = config);
    _syncAutoTimer();
  }

  /// 根据配置同步自动翻页定时器
  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    final cfg = _advConfig;
    if (!cfg.autoPageTurn) return;
    final seconds = cfg.autoPageTurnInterval.round().clamp(3, 120);
    _autoTimer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!mounted) return;
      final pageView = _pageViewKey.currentState;
      if (pageView == null) return;
      if (cfg.autoPageTurnForward) {
        pageView.nextPageOrChapter();
      } else {
        pageView.prevPageOrChapter();
      }
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    super.dispose();
  }

  /// 章节内容加载完成后，后台预加载相邻章节
  void _maybePreloadAdjacentChapters(ReaderState state) {
    if (_wasLoading && !state.isLoading && state.error == null) {
      final index = state.currentChapterIndex;
      if (index != _lastPreloadedIndex) {
        _lastPreloadedIndex = index;
        _preloadAdjacentChapters(state);
      }
    }
    _wasLoading = state.isLoading;
  }

  /// 预加载当前章节的前后各 2 章内容，提升翻页阅读体验（静默失败）
  ///
  /// 对齐计划 Phase 2.7：前后各 2 章的 API 调用编排，实现翻页无等待感。
  /// 此处仅决定「何时调用 getChapterContent」，文本解析/净化/替换由 Rust 内部完成。
  void _preloadAdjacentChapters(ReaderState state) {
    final book = state.currentBook;
    final chapters = state.chapters;
    if (book == null || chapters.isEmpty) return;

    final api = ref.read(bookApiProvider);
    final index = state.currentChapterIndex;

    // 前后各预加载 2 章（按距离由近及远，越靠近当前章越优先）
    for (var offset = 1; offset <= 2; offset++) {
      final next = index + offset;
      if (next < chapters.length) {
        unawaited(
          api.getChapterContent(book.bookUrl, next).catchError((_) => ''),
        );
      }
      final prev = index - offset;
      if (prev >= 0) {
        unawaited(
          api.getChapterContent(book.bookUrl, prev).catchError((_) => ''),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(readerNotifierProvider);
    final notifier = ref.read(readerNotifierProvider.notifier);

    _maybePreloadAdjacentChapters(state);

    return PopScope<Object?>(
      // 退出阅读器时确保阅读进度已保存到书架
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(notifier.saveProgress());
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: state.backgroundColor,
        body: GestureDetector(
          onTapUp: (details) => _handleTap(context, details),
          child: Stack(
            children: [
              ReaderPageView(
                key: _pageViewKey,
                paragraphSpacing: _advConfig.paragraphSpacing,
              ),
              if (!state.showControls) ReaderStatusStrip(config: _advConfig),
              if (state.showControls)
                ReaderTopBar(
                  onOpenContentSearch: () => _openContentSearch(state),
                  onAddBookmark: () => _addBookmark(state),
                  onOpenAdvancedConfig: () => _openAdvancedConfig(context),
                ),
              if (state.showControls)
                ReaderBottomBar(
                  onOpenCatalog: () =>
                      _scaffoldKey.currentState?.openEndDrawer(),
                  onOpenSettings: () => ReaderSettingsSheet.show(context),
                ),
            ],
          ),
        ),
        endDrawer: const ReaderCatalogDrawer(),
      ),
    );
  }

  // ===== 交互 =====

  /// 根据点击区域配置执行对应功能
  void _handleTap(BuildContext context, TapUpDetails details) {
    final screenWidth = MediaQuery.of(context).size.width;
    final tapX = details.globalPosition.dx;
    final notifier = ref.read(readerNotifierProvider.notifier);
    final pageView = _pageViewKey.currentState;

    TapAction action;
    if (tapX < screenWidth * 0.3) {
      action = _advConfig.leftAction;
    } else if (tapX > screenWidth * 0.7) {
      action = _advConfig.rightAction;
    } else {
      action = _advConfig.centerAction;
    }

    switch (action) {
      case TapAction.none:
        break;
      case TapAction.prevPage:
        pageView?.prevPageOrChapter();
      case TapAction.nextPage:
        pageView?.nextPageOrChapter();
      case TapAction.toggleControls:
        notifier.toggleControls();
      case TapAction.openCatalog:
        _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  /// 添加书签（提取当前章节内容前 100 字符作为摘要）
  void _addBookmark(ReaderState state) {
    final book = state.currentBook;
    final chapter = state.currentChapter;
    if (book == null || chapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法添加书签：未打开书籍')),
      );
      return;
    }
    final content = state.chapterContent;
    final summary = content.length > 100 ? content.substring(0, 100) : content;

    ref.read(bookmarkNotifierProvider.notifier).addBookmark(
          bookName: book.name,
          bookAuthor: book.author,
          chapterIndex: state.currentChapterIndex,
          chapterPos: 0,
          chapterName: chapter.title,
          bookText: summary,
        );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已添加书签：${chapter.title}')),
    );
  }

  /// 打开正文搜索页面
  void _openContentSearch(ReaderState state) {
    final book = state.currentBook;
    if (book == null) return;
    Navigator.pushNamed(
      context,
      AppRoutes.searchContent,
      arguments: book,
    );
  }

  /// 打开高级设置面板，配置变更后实时应用
  Future<void> _openAdvancedConfig(BuildContext context) async {
    await ReaderConfigPanel.show(
      context,
      config: _advConfig,
      onChanged: (cfg) {
        _advConfig = cfg;
        _syncAutoTimer();
        if (mounted) setState(() {});
      },
    );
  }
}
