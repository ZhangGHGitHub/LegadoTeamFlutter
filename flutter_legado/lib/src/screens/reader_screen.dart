import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../models/book.dart';
import '../models/book_source.dart';
import '../models/source_match.dart';
import '../providers/audio/audio_notifier.dart';
import '../providers/bookmark/bookmark_notifier.dart';
import '../providers/providers.dart';
import '../providers/reader/reader_notifier.dart';
import '../routes.dart';
import '../widgets/reader/read_aloud_bar.dart';
import '../widgets/reader/reader_bottom_bar.dart';
import '../widgets/reader/reader_page_chrome.dart';
import '../widgets/reader/reader_image_dominant_body.dart';
import '../widgets/reader/reader_page_view.dart';
import '../widgets/reader/reader_settings_sheet.dart';
import '../widgets/reader/reader_status_strip.dart';
import '../widgets/reader/reader_top_bar.dart';
import '../widgets/reader/review_detail_sheet.dart';
import '../utils/comic_image_utils.dart';
import '../utils/source_login_prompt.dart';
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

  /// 段评摘要（P2-9 ruleReview；禁止接本地 CommentService）
  Map<int, int> _reviewCounts = {};
  Map<int, String> _reviewKeys = {};
  String? _reviewSourceJson;
  int _reviewLoadToken = 0;

  // [UI-fix v2.0.3 | 2026-08-08] 自动换源（autoChangeSource）防循环状态 — Qoder

  /// 自动换源进行中（避免并发触发）
  bool _autoSwitching = false;

  /// 当前正在自动换源的书 bookUrl（换书时重置尝试计数）
  String? _autoSwitchBookUrl;

  /// 同一本书连续自动换源尝试次数（上限 3 次，避免无可用源时死循环）
  int _autoSwitchAttempts = 0;

  static const int _autoSwitchMaxAttempts = 3;

  /// F6：跟踪主题日夜，变化时重载布局桶（shareLayout=false）
  bool? _layoutIsNight;

  @override
  void initState() {
    super.initState();
    // F6：音量键翻页（对标 volumeKeyPage / volumeKeyPageOnPlay）
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Theme.of 不可在 initState 调用；首次与日夜切换时加载高级配置
    final isNight = Theme.of(context).brightness == Brightness.dark;
    if (_layoutIsNight == null || _layoutIsNight != isNight) {
      unawaited(_loadAdvancedConfig());
    }
    _layoutIsNight = isNight;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    _autoTimer?.cancel();
    // [UI-fix v2.0.3 | 2026-08-08] 退出阅读器恢复系统 UI 与方向
    // （hideStatusBar/hideNavigationBar/screenOrientation 仅阅读页内生效，
    // 对标原版 ReadBookActivity 退出时 upSystemUiMode 还原）— Qoder
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  // ===== [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批系统级生效 =====

  /// 应用隐藏状态栏/导航栏与屏幕方向（对标原版 MoreConfigDialog
  /// onSharedPreferenceChanged：hideStatusBar/hideNavigationBar → UP_CONFIG
  /// 重建沉浸式；screenOrientation → setOrientation）— Qoder
  void _applySystemChrome(ReaderAdvancedConfig cfg) {
    final overlays = <SystemUiOverlay>[];
    if (!cfg.hideStatusBar) overlays.add(SystemUiOverlay.top);
    if (!cfg.hideNavigationBar) overlays.add(SystemUiOverlay.bottom);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: overlays);
    SystemChrome.setPreferredOrientations(
        _orientationsFor(cfg.screenOrientation));
    // keep_light（保持亮屏）：项目未引入 wakelock 依赖（不改 pubspec），
    // 设置仅持久化，待平台能力接入后生效（与 audio_screen audioWakeLock
    // 标注一致，诚实标注平台限制）— Qoder
  }

  /// 原版 screen_direction_value → Flutter DeviceOrientation 映射
  List<DeviceOrientation> _orientationsFor(int orientation) {
    switch (orientation) {
      case 1: // 竖屏
        return const [DeviceOrientation.portraitUp];
      case 2: // 横屏
        return const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ];
      case 3: // 自动(传感器)
        return DeviceOrientation.values.toList();
      case 4: // 反向竖屏
        return const [DeviceOrientation.portraitDown];
      case 5: // 反向横屏
        return const [DeviceOrientation.landscapeRight];
      default: // 跟随系统：空列表解除锁定
        return const [];
    }
  }

  Future<void> _loadAdvancedConfig() async {
    // F6：按当前主题亮度选择日/夜布局桶（shareLayout 时走共用桶）
    final isNight = Theme.of(context).brightness == Brightness.dark;
    _layoutIsNight = isNight;
    final config = await ReaderAdvancedConfig.load(isNight: isNight);
    if (!mounted) return;
    setState(() => _advConfig = config);
    ref.read(readerAdvConfigProvider.notifier).apply(config);
    _syncAutoTimer();
    // [UI-fix v2.0.3 | 2026-08-08] 进入阅读器即应用隐藏栏/方向配置 — Qoder
    _applySystemChrome(config);
  }

  /// F6：音量键翻页（仅 Android 有效；桌面无音量键事件）
  bool _onHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final isVolUp = event.logicalKey == LogicalKeyboardKey.audioVolumeUp;
    final isVolDown = event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
    if (!isVolUp && !isVolDown) return false;

    final cfg = ref.read(readerAdvConfigProvider) ?? _advConfig;
    final aloud = ref.read(audioNotifierProvider).isPlaying;
    final allow = cfg.volumeKeyPage && (!aloud || cfg.volumeKeyPageOnPlay);
    if (!allow) return false;

    final pageView = _pageViewKey.currentState;
    if (pageView == null) return false;
    if (isVolDown) {
      pageView.nextPageOrChapter();
    } else {
      pageView.prevPageOrChapter();
    }
    return true; // 消费事件，避免系统调音量
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


  /// 加载当前章段评摘要（对齐 ReadBookActivity.loadReviewSummaryIfNeeded）
  Future<void> _loadReviewSummary() async {
    final token = ++_reviewLoadToken;
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    if (book == null || book.origin.isEmpty) {
      if (mounted && token == _reviewLoadToken) {
        setState(() {
          _reviewCounts = {};
          _reviewKeys = {};
          _reviewSourceJson = null;
        });
      }
      return;
    }
    try {
      final api = ref.read(bookApiProvider);
      final sources = await api.getBookSources();
      BookSource? matched;
      for (final s in sources) {
        if (s.bookSourceUrl == book.origin) {
          matched = s;
          break;
        }
      }
      if (matched == null) {
        if (mounted && token == _reviewLoadToken) {
          setState(() {
            _reviewCounts = {};
            _reviewKeys = {};
            _reviewSourceJson = null;
          });
        }
        return;
      }
      final rr = matched.ruleReview;
      final isJs = (matched.mainJs ?? '').trim().isNotEmpty;
      final enabled = isJs ||
          (rr != null &&
              rr.enabled &&
              (rr.reviewSummaryUrl ?? '').trim().isNotEmpty);
      if (!enabled) {
        if (mounted && token == _reviewLoadToken) {
          setState(() {
            _reviewCounts = {};
            _reviewKeys = {};
            _reviewSourceJson = null;
          });
        }
        return;
      }
      final chapter = state.currentChapter;
      final request = <String, dynamic>{
        'chapterUrl': chapter?.url ?? '',
        'book': book.toJson(),
        if (chapter != null) 'chapter': chapter.toJson(),
      };
      final sourceJson = jsonEncode(matched.toJson());
      final raw = await api.reviewGetSummary(sourceJson, jsonEncode(request));
      if (!mounted || token != _reviewLoadToken) return;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final countsRaw = map['counts'] as Map? ?? {};
      final keysRaw = map['keys'] as Map? ?? {};
      final counts = <int, int>{};
      for (final e in countsRaw.entries) {
        final k = int.tryParse(e.key.toString());
        final v = (e.value as num?)?.toInt();
        if (k != null && v != null && v > 0) counts[k] = v;
      }
      final keys = <int, String>{};
      for (final e in keysRaw.entries) {
        final k = int.tryParse(e.key.toString());
        if (k != null) keys[k] = e.value.toString();
      }
      setState(() {
        _reviewCounts = counts;
        _reviewKeys = keys;
        _reviewSourceJson = sourceJson;
      });
    } catch (_) {
      if (mounted && token == _reviewLoadToken) {
        setState(() {
          _reviewCounts = {};
          _reviewKeys = {};
          _reviewSourceJson = null;
        });
      }
    }
  }

  void _onReviewTap(int paragraphIndex, int count) {
    final state = ref.read(readerNotifierProvider);
    final book = state.currentBook;
    final chapter = state.currentChapter;
    final sourceJson = _reviewSourceJson;
    if (book == null || chapter == null || sourceJson == null) return;
    final paraData = _reviewKeys[paragraphIndex] ?? '$paragraphIndex';
    ReviewDetailSheet.show(
      context,
      api: ref.read(bookApiProvider),
      sourceJson: sourceJson,
      bookUrl: book.bookUrl,
      chapterUrl: chapter.url,
      chapterIndex: state.currentChapterIndex,
      paragraphIndex: paragraphIndex,
      paragraphData: paraData,
      totalCount: count,
      bookJson: book.toJson(),
      chapterJson: chapter.toJson(),
    );
  }

  /// 章节内容加载完成后，后台预加载相邻章节
  void _maybePreloadAdjacentChapters(ReaderState state) {
    if (_wasLoading && !state.isLoading && state.error == null) {
      final index = state.currentChapterIndex;
      if (index != _lastPreloadedIndex) {
        _lastPreloadedIndex = index;
        _preloadAdjacentChapters(state);
        unawaited(_loadReviewSummary());
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

    // 必应漫画等：正文仅为 <img> HTML 时勿走文本排版（会刷裸标签）
    final imageDominant = book != null &&
        !state.isLoading &&
        state.chapterContent.isNotEmpty &&
        isImageDominantContent(state.chapterContent);

    // [UI-fix v2.0.3 | 2026-08-08] 自动换源监听：章节加载新产生错误时，
    // autoChangeSource 开启且在线书 → 自动搜索替代书源并切换（对标原版
    // ReadBook AutoChangeSource 加载失败自动换源语义的最小路径）— Qoder
    ref.listen(readerNotifierProvider, (prev, next) {
      if (next.error != null && prev?.error == null) {
        unawaited(_maybePromptSourceLogin(next));
        _maybeAutoChangeSource(next);
      }
    });

    return PopScope<Object?>(
      // 退出阅读器时确保阅读进度已保存到书架
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) {
          unawaited(notifier.saveProgress());
        }
      },
      child: Scaffold(
        backgroundColor: state.backgroundColor,
        // F6：刘海/挖孔边距（paddingDisplayCutouts / readBodyToLh）
        body: Builder(
          builder: (context) {
            final cfg =
                ref.watch(readerAdvConfigProvider) ?? _advConfig;
            Widget body = GestureDetector(
          onTapUp: imageDominant
              ? null
              : (details) => _handleTap(context, details),
          child: Stack(
            children: [
              if (imageDominant)
                ReaderImageDominantBody(
                  content: state.chapterContent,
                  book: book,
                  imageStyle: book.readConfig?.imageStyle,
                  onToggleControls: notifier.toggleControls,
                  hasNextChapter: state.hasNextChapter,
                  hasPrevChapter: state.hasPreviousChapter,
                  onNextChapter: notifier.nextChapter,
                  onPrevChapter: notifier.prevChapter,
                )
              else
              ReaderPageView(
                key: _pageViewKey,
                // [UI-fix v2.0.4 | 2026-08-08] 共享配置源：面板/界面 Sheet 的
                // 修改统一推送 readerAdvConfigProvider，watch 触发重建并同步
                // _advConfig（Stack 子级按序求值，后续 ReaderStatusStrip 等
                // 消费点拿到最新配置；provider 未加载完成时兜底用自加载值）— Qoder
                paragraphSpacing: (_advConfig =
                        ref.watch(readerAdvConfigProvider) ?? _advConfig)
                    .paragraphSpacing,
                // [UI-fix v2.0.2 | 2026-08-06] 阅读配置面板新增排版参数接入分页渲染 — Qoder
                letterSpacing: _advConfig.letterSpacing,
                paragraphIndent: _advConfig.paragraphIndent,
                textFullJustify: _advConfig.textFullJustify,
                // [UI-fix v2.0.3 | 2026-08-06] 页面边距接入分页渲染 — Qoder
                marginTop: _advConfig.pageMarginTop,
                marginBottom: _advConfig.pageMarginBottom,
                marginLeft: _advConfig.pageMarginLeft,
                marginRight: _advConfig.pageMarginRight,
                pageChrome: ReaderPageChromeConfig.fromAdvanced(_advConfig),
                // [UI-fix v2.0.3 | 2026-08-08] MoreConfig 第①批：长按选择
                // 文本开关与滚动翻页无动画接入内容区 — Qoder
                selectText: _advConfig.selectText,
                noAnimScroll: _advConfig.noAnimScrollPage,
                // [UI-fix v2.0.4 | 2026-08-08] 界面面板字重/自定义文字色与
                // MoreConfig 第②批鼠标滚轮翻页接入内容区 — Qoder
                textBold: _advConfig.textBold,
                customTextColor: _advConfig.customTextColor,
                mouseWheelPage: _advConfig.mouseWheelPage,
                // [UI-fix v2.0.5 | 2026-08-10] 双页模式档位透传（对标原版
                // doubleHorizontalPage 0-3 档）— Reasonix
                doubleHorizontalPage: _advConfig.doubleHorizontalPage,
                // [UI-fix v2.0.5 | 2026-08-10] 中文分行开关透传（对标原版
                // useZhLayout）— Reasonix
                useZhLayout: _advConfig.useZhLayout,
                // [UI-fix v2.0.5 | 2026-08-10] 段首标点悬挂透传（对标原版
                // hangingPunctuation）— Reasonix
                hangingPunctuation: _advConfig.hangingPunctuation,
                reviewCounts: _reviewCounts,
                onReviewTap: _onReviewTap,
              ),
              if (!state.showControls) ReaderStatusStrip(config: _advConfig),
              // 全局页码指示器（跨章节连续分页已注册时显示）
              if (state.showControls && state.totalPages > 0 && !imageDominant)
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
                  onAddBookmark: () => _addBookmark(state),
                  // [UI-fix v2.0.4 | 2026-08-08] 顶栏对齐原版 ReadMenu：搜索/
                  // 高级设置入口已迁出（搜索→底栏悬浮按钮，设置→底栏设置按钮），
                  // 不再传入对应回调 — Qoder
                  // [UI-fix v2.0.3 | 2026-08-08] 显示标题附加区/工具栏跟随页面 — Qoder
                  showTitleAddition: _advConfig.showReadTitleAddition,
                  styleFollowPage: _advConfig.readBarStyleFollowPage,
                ),
              // [UI-fix v2.0.1 | 2026-08-06] 朗读激活时以 ReadAloudBar 替代底部
              // 功能栏（对标原版 ReadAloudDialog 覆盖 ReadMenu 底部的行为） — Qoder
              if (aloudActive && !_aloudBarHidden)
                ReadAloudBar(
                  onDismiss: () => setState(() => _aloudBarHidden = true),
                  // [UI-fix v2.0.4 | 2026-08-08] 目录入口切换为独立目录页
                  // TocScreen（对标原版 TocActivity），抽屉已删除 — Qoder
                  onOpenCatalog: () => unawaited(_openToc()),
                  onBackstage: () => Navigator.of(context).maybePop(),
                )
              else if (state.showControls)
                ReaderBottomBar(
                  onOpenCatalog: () => unawaited(_openToc()),
                  onOpenSettings: () => ReaderSettingsSheet.show(context),
                  onOpenAdvancedConfig: () => _openAdvancedConfig(context),
                  onOpenContentSearch: () => _openContentSearch(state),
                  onReadAloud: _onReadAloudTap,
                  showBrightnessView: _advConfig.showBrightnessView,
                  progressBehavior: _advConfig.progressBarBehavior,
                  onSeekPage: (page) =>
                      _pageViewKey.currentState?.goToPage(page),
                  styleFollowPage: _advConfig.readBarStyleFollowPage,
                  onToggleAutoPage: _toggleAutoPage,
                  onOpenReplaceRules: () =>
                      Navigator.pushNamed(context, AppRoutes.replaceRules),
                ),
            ],
          ),
        );
            // F6：填充刘海 / 扩展到刘海
            if (cfg.paddingDisplayCutouts) {
              final vp = MediaQuery.viewPaddingOf(context);
              body = Padding(
                padding: EdgeInsets.only(
                  top: cfg.readBodyToLh ? 0 : vp.top,
                  left: vp.left,
                  right: vp.right,
                  bottom: vp.bottom,
                ),
                child: body,
              );
            } else if (!cfg.readBodyToLh) {
              body = SafeArea(
                left: true,
                right: true,
                top: true,
                bottom: false,
                child: body,
              );
            }
            return body;
          },
        ),
      ),
    );
  }

  // ===== 交互 =====

  /// 打开独立目录页（对标原版 ll_catalog → TocActivity）
  ///
  /// [UI-fix v2.0.4 | 2026-08-08] 目录入口由侧边抽屉改为独立目录页
  /// TocScreen（/toc 路由，传当前 Book）；页面 pop 返回选中章节原始
  /// index（int）后跳转对应章节 — Qoder
  Future<void> _openToc() async {
    final book = ref.read(readerNotifierProvider).currentBook;
    if (book == null) return;
    final result =
        await Navigator.pushNamed(context, AppRoutes.toc, arguments: book);
    if (!mounted) return;
    if (result is int) {
      await ref.read(readerNotifierProvider.notifier).goToChapter(result);
    }
  }

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

  /// 底栏自动翻页 FAB（对标原版 fabAutoPage → autoPage）
  void _toggleAutoPage() {
    _advConfig = _advConfig.copy()..autoPageTurn = !_advConfig.autoPageTurn;
    unawaited(_advConfig.save());
    ref.read(readerAdvConfigProvider.notifier).apply(_advConfig.copy());
    _syncAutoTimer();
    if (mounted) setState(() {});
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

    // [fix Task#41 | 2026-08-09] pageTouchClick 消费点（对标原版
    // ReadView.setRect9x：左右边缘 pageTouchClick px 内不落入任何点击
    // 分区，即该条带内的点击不触发任何动作）；默认值 0 与原版一致，
    // 不影响既有左 30%/中 40%/右 30% 分区
    // [fix Task#45 | 2026-08-09] 死区钳制到半屏以内（M2）：阈值最大
    // 399，窄窗口下左右死区重叠会吞掉全部点击（含中央菜单唤出），
    // 钳制后中央至少保留 2px 可点击区；默认 0 行为不变 — Qoder
    final deadZone = math.min(
      _advConfig.pageTouchClick.toDouble(),
      screenWidth / 2 - 1,
    );
    if (deadZone > 0 && (tapX < deadZone || tapX > screenWidth - deadZone)) {
      return;
    }

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
        // [UI-fix v2.0.3 | 2026-08-06] 直接驱动 PageView 翻页（见下方根因说明）— Qoder
        pageView?.prevPageOrChapter();
      case TapAction.nextPage:
        pageView?.nextPageOrChapter();
      case TapAction.toggleControls:
        notifier.toggleControls();
      case TapAction.openCatalog:
        unawaited(_openToc());
    }
  }

  // [UI-fix v2.0.3 | 2026-08-06] 修复点击翻页失效回归 —— Qoder
  // 根因：此前点击翻页经 ReaderNotifier.nextGlobalPage/prevGlobalPage 仅更新
  // 全局页索引状态（globalPageIndex/currentChapterPos），却未驱动 ReaderPageView
  // 内部的 PageController；且「globalPageIndex 未变才回退章级翻页」的判定在同章
  // 翻页时永不成立（同章翻页必然改变 globalPageIndex），导致点击后视觉上不翻页。
  // 现改为在 _handleTap 中直接调用 ReaderPageView.next/prevPageOrChapter()：
  // 既驱动 PageController 完成各模式（仿真/滑动/覆盖/无动画/滚动）视觉翻页与
  // 跨章无缝切换，又经其内部 updatePosition() 同步全局页码指示器。

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
        // [UI-fix v2.0.3 | 2026-08-08] 面板内变更隐藏栏/方向等系统级
        // 配置后立即生效（对标原版 onSharedPreferenceChanged 即时语义）— Qoder
        _applySystemChrome(cfg);
        if (mounted) setState(() {});
      },
    );
  }

  // ===== [UI-fix v2.0.3 | 2026-08-08] 自动换源最小路径 =====
  // 对标原版 ReadBook 内容加载失败后 AutoChangeSource 按书名搜替代源并切换：
  // 复用 searchSource/switchSource FFI（与换源页同源链路）；完整重试策略/
  // 失败源禁用等复杂逻辑留待后续批次 — Qoder

  /// loginCheckJs 判定未登录时自动拉起登录页（§5.14-18）
  Future<void> _maybePromptSourceLogin(ReaderState state) async {
    if (!isSourceLoginRequiredError(state.error)) return;
    final book = state.currentBook;
    if (book == null) return;
    if (book.origin == BookType.localTag ||
        book.origin.startsWith(BookType.webDavTag)) {
      return;
    }
    BookSource? source;
    try {
      final sources = await ref.read(bookApiProvider).getBookSources();
      for (final s in sources) {
        if (s.bookSourceUrl == book.origin) {
          source = s;
          break;
        }
      }
    } catch (_) {
      return;
    }
    if (!mounted || source == null) return;
    await promptSourceLoginIfNeeded(
      context,
      error: state.error,
      source: source,
    );
  }

  /// 章节加载失败时尝试自动换源（在线书且开关开启时）
  void _maybeAutoChangeSource(ReaderState state) {
    if (!_advConfig.autoChangeSource) return;
    if (_autoSwitching) return;
    final book = state.currentBook;
    if (book == null) return;
    // 本地书/WebDAV 书无书源可换（对标原版仅网络书自动换源）
    if (book.origin == BookType.localTag ||
        book.origin.startsWith(BookType.webDavTag)) {
      return;
    }
    if (_autoSwitchBookUrl != book.bookUrl) {
      _autoSwitchBookUrl = book.bookUrl;
      _autoSwitchAttempts = 0;
    }
    if (_autoSwitchAttempts >= _autoSwitchMaxAttempts) return;
    _autoSwitchAttempts++;
    unawaited(_doAutoChangeSource(book));
  }

  /// 执行自动换源：搜索替代书源 → 取首个非同源候选 → switchSource → 重开书
  Future<void> _doAutoChangeSource(Book book) async {
    _autoSwitching = true;
    try {
      final api = ref.read(bookApiProvider);
      final matches = (await api.searchSource(book.name, book.author))
          .map(SourceMatch.fromJson)
          .toList();
      SourceMatch? target;
      for (final m in matches) {
        if (m.sourceUrl.isNotEmpty && m.sourceUrl != book.origin) {
          target = m;
          break;
        }
      }
      if (!mounted) return;
      if (target == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('自动换源：无可用替代书源')),
        );
        return;
      }
      final updatedJson = await api.switchSource(
        book.bookUrl,
        target.sourceUrl,
        target.bookUrl,
      );
      var newBookUrl = target.bookUrl;
      try {
        final decoded = jsonDecode(updatedJson);
        if (decoded is Map<String, dynamic>) {
          final url = decoded['bookUrl'] as String?;
          if (url != null && url.isNotEmpty) newBookUrl = url;
        }
      } catch (_) {
        // 解析失败回退候选项 bookUrl（与换源页同策略）
      }
      if (!mounted) return;
      final updated = book.copyWith(
        bookUrl: newBookUrl,
        origin: target.sourceUrl,
        originName: target.sourceName,
      );
      final notifier = ref.read(readerNotifierProvider.notifier);
      notifier.updateCurrentBook(updated);
      await notifier.openBook(updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('章节加载失败，已自动换源：${target.sourceName}')),
      );
      // 换源成功后重置尝试计数（新书源可再次触发）
      _autoSwitchAttempts = 0;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('自动换源失败: $e')),
        );
      }
    } finally {
      _autoSwitching = false;
    }
  }
}
