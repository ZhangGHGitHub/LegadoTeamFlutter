import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../providers/audio/audio_notifier.dart';
import '../providers/bookmark/bookmark_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../widgets/reader/read_aloud_bar.dart';
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

  /// [UI-fix v2.0.1 | 2026-08-06] 朗读控制条是否被手动收起
  /// （收起后朗读继续，再次点击底栏朗读按钮重新展开） — Qoder
  bool _aloudBarHidden = false;

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
    // 朗读控制条显隐依赖全局朗读状态（朗读进行中时替代底部功能栏）
    final audio = ref.watch(audioNotifierProvider);
    final book = state.currentBook;
    final aloudActive = book != null &&
        audio.bookUrl == book.bookUrl &&
        audio.state != PlayerState.idle;

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
                // [UI-fix v2.0.2 | 2026-08-06] 阅读配置面板新增排版参数接入分页渲染 — Qoder
                letterSpacing: _advConfig.letterSpacing,
                paragraphIndent: _advConfig.paragraphIndent,
                textFullJustify: _advConfig.textFullJustify,
                // [UI-fix v2.0.3 | 2026-08-06] 页面边距接入分页渲染 — Qoder
                marginTop: _advConfig.pageMarginTop,
                marginBottom: _advConfig.pageMarginBottom,
                marginLeft: _advConfig.pageMarginLeft,
                marginRight: _advConfig.pageMarginRight,
              ),
              if (!state.showControls) ReaderStatusStrip(config: _advConfig),
              // 全局页码指示器（跨章节连续分页已注册时显示）
              if (state.showControls && state.totalPages > 0)
                Positioned(
                  bottom: 80,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '全局页 ${state.globalPageIndex + 1} / ${state.totalPages}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                ),
              if (state.showControls)
                ReaderTopBar(
                  onOpenContentSearch: () => _openContentSearch(state),
                  onAddBookmark: () => _addBookmark(state),
                  onOpenAdvancedConfig: () => _openAdvancedConfig(context),
                ),
              // [UI-fix v2.0.1 | 2026-08-06] 朗读激活时以 ReadAloudBar 替代底部
              // 功能栏（对标原版 ReadAloudDialog 覆盖 ReadMenu 底部的行为） — Qoder
              if (aloudActive && !_aloudBarHidden)
                ReadAloudBar(
                  onDismiss: () => setState(() => _aloudBarHidden = true),
                  onOpenCatalog: () =>
                      _scaffoldKey.currentState?.openEndDrawer(),
                  onBackstage: () => Navigator.of(context).maybePop(),
                )
              else if (state.showControls)
                ReaderBottomBar(
                  onOpenCatalog: () =>
                      _scaffoldKey.currentState?.openEndDrawer(),
                  onOpenSettings: () => ReaderSettingsSheet.show(context),
                  onOpenAdvancedConfig: () => _openAdvancedConfig(context),
                  onReadAloud: _onReadAloudTap,
                ),
            ],
          ),
        ),
        endDrawer: const ReaderCatalogDrawer(),
      ),
    );
  }

  // ===== 交互 =====

  /// 底栏朗读按钮点击处理
  ///
  /// [UI-fix v2.0.1 | 2026-08-06] 去除存根 SnackBar，打通朗读链路：
  /// 对标原版 ReadBookActivity.onClickReadAloud —— 朗读进行中再次点击为
  /// 播放/暂停切换并重新展开控制条；未启动时从当前章启动朗读 — Qoder
  void _onReadAloudTap() {
    final state = ref.read(readerNotifierProvider);
    final audio = ref.read(audioNotifierProvider);
    final book = state.currentBook;
    final aloudActive = book != null &&
        audio.bookUrl == book.bookUrl &&
        audio.state != PlayerState.idle;

    if (aloudActive) {
      final notifier = ref.read(audioNotifierProvider.notifier);
      if (audio.isPlaying) {
        notifier.pause();
      } else {
        unawaited(notifier.play());
      }
      setState(() => _aloudBarHidden = false);
      return;
    }
    unawaited(_startReadAloud(state));
  }

  /// 启动当前书的朗读（链路：AudioNotifier.startReadAloud → play → audioSpeak）
  Future<void> _startReadAloud(ReaderState state) async {
    final book = state.currentBook;
    if (book == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法启动朗读：未打开书籍')),
      );
      return;
    }
    setState(() => _aloudBarHidden = false);
    await ref.read(audioNotifierProvider.notifier).startReadAloud(
          bookUrl: book.bookUrl,
          bookName: book.name,
          chapterIndex: state.currentChapterIndex,
        );
  }

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
        _navigatePrevPage(notifier, pageView);
      case TapAction.nextPage:
        _navigateNextPage(notifier, pageView);
      case TapAction.toggleControls:
        notifier.toggleControls();
      case TapAction.openCatalog:
        _scaffoldKey.currentState?.openEndDrawer();
    }
  }

  /// 全局上一页（优先跨章节连续分页，失败时回退到章级翻页）
  void _navigatePrevPage(ReaderNotifier notifier, ReaderPageViewState? pageView) {
    final stateBefore = ref.read(readerNotifierProvider);
    if (stateBefore.totalPages > 0) {
      notifier.prevGlobalPage().then((_) {
        final stateAfter = ref.read(readerNotifierProvider);
        if (stateAfter.globalPageIndex == stateBefore.globalPageIndex) {
          pageView?.prevPageOrChapter();
        }
      }).catchError((_) {
        pageView?.prevPageOrChapter();
      });
    } else {
      pageView?.prevPageOrChapter();
    }
  }

  /// 全局下一页（优先跨章节连续分页，失败时回退到章级翻页）
  void _navigateNextPage(ReaderNotifier notifier, ReaderPageViewState? pageView) {
    final stateBefore = ref.read(readerNotifierProvider);
    if (stateBefore.totalPages > 0) {
      notifier.nextGlobalPage().then((_) {
        final stateAfter = ref.read(readerNotifierProvider);
        if (stateAfter.globalPageIndex == stateBefore.globalPageIndex) {
          pageView?.nextPageOrChapter();
        }
      }).catchError((_) {
        pageView?.nextPageOrChapter();
      });
    } else {
      pageView?.nextPageOrChapter();
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
