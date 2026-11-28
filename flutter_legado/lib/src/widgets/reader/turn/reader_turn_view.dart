import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_strings.dart';
import 'package:flutter/scheduler.dart';

import '../../../providers/reader/reader_state.dart';
import '../reader_bookmark_policy.dart';
import 'page_direction.dart';
import 'page_snapshot.dart';
import 'page_snapshot_cache.dart';
import 'page_turn_controller.dart';
import 'painters/cover_page_painter.dart';
import 'painters/simulation_curl_painter.dart';
import 'painters/slide_page_painter.dart';

/// Horizontal page-turn host: live page + snapshot CustomPaint overlay.
class ReaderTurnView extends StatefulWidget {
  const ReaderTurnView({
    super.key,
    required this.mode,
    required this.pageIndex,
    required this.pageCount,
    required this.buildPage,
    required this.onPageChanged,
    required this.onTurnChapterPrev,
    required this.onTurnChapterNext,
    required this.hasChapterPrev,
    required this.hasChapterNext,
    this.overlay,
    this.backPageColor = const Color(0xFFECECEC),
    this.chapterPrevPage,
    this.chapterNextPage,
    this.pullBookmarkEnabled = false,
    this.hasBookmarkOnPage = false,
    this.onToggleBookmark,
    this.bookmarkHintTop = 0,
    this.selectionActive,
  });

  final PageTurnMode mode;
  final int pageIndex;
  final int pageCount;
  final Widget Function(int index) buildPage;
  final void Function(int index) onPageChanged;
  final VoidCallback onTurnChapterPrev;
  final VoidCallback onTurnChapterNext;
  final bool hasChapterPrev;
  final bool hasChapterNext;

  /// Drawn above the live page but under the turn overlay (e.g. click zones).
  final Widget? overlay;

  /// Simulation back-of-page fill (Jingshiro bgMeanColor).
  final Color backPageColor;

  /// 相邻章边界页预览（父级预载：下一章首屏 / 上一章末屏），
  /// 用于章边界turn的动画与承接显示（[UI_SYNC_REFACTOR S6 修 | 2026-09-08]
  /// 用户反馈：章末翻页无动画直接闪现 → 章边界参与快照与画笔）— Qoder
  final Widget? chapterPrevPage;
  final Widget? chapterNextPage;

  /// [批4d] 下滑书签手势开关（分页模式且菜单收起时由父级置 true）
  final bool pullBookmarkEnabled;

  /// [批4d] 当前屏是否已有书签（提示文案：删除/添加）
  final bool hasBookmarkOnPage;

  /// [批4d] 达到 80dp 后松手：添加或删除本屏书签
  final VoidCallback? onToggleBookmark;

  /// [批4d] 提示条距屏幕顶部距离（正文 contentTop；内部再 +8dp）
  final double bookmarkHintTop;

  /// [R49 阶段C] 正文选区是否活跃（null = 恒不活跃，旧路径行为不变）
  ///
  /// 裸 Listener 不属于手势竞技场：选区手柄拖拽产生的原始指针移动会
  /// 同时到达本层。选区活跃时必须显式短路翻页/下滑书签判定。
  final ValueListenable<bool>? selectionActive;

  @override
  State<ReaderTurnView> createState() => ReaderTurnViewState();
}

class ReaderTurnViewState extends State<ReaderTurnView>
    with TickerProviderStateMixin {
  final PageTurnController _controller = PageTurnController();
  final PageSnapshotCache _cache = PageSnapshotCache();
  final GlobalKey _prevBoundaryKey = GlobalKey();
  final GlobalKey _curBoundaryKey = GlobalKey();
  final GlobalKey _nextBoundaryKey = GlobalKey();
  final GlobalKey _chapPrevBoundaryKey = GlobalKey();
  final GlobalKey _chapNextBoundaryKey = GlobalKey();

  /// 章边界页快照（父级预载页抓取）
  ui.Image? _chapPrevImg;
  ui.Image? _chapNextImg;

  /// 章边界 turn 进行中/承接中（遮罩保留至父级章节落地）
  bool _chapterTurning = false;
  PageTurnDirection _chapterTurnDir = PageTurnDirection.none;

  bool _overlayVisible = false;
  int _warmGeneration = 0;

  // ===== [批4d] 下滑书签手势状态 =====

  /// 当前页纵向位移（正=向下，最大 0.6 页高）
  double _pullOffset = 0;
  bool _pullDragging = false;
  bool _pullArmed = false;

  /// 一旦首次越过阈值判定为横滑/滚动即锁定，后续斜向移动不再抢占
  bool _pullReleased = false;
  Offset _pullDown = Offset.zero;

  /// 回弹动画（参考 180ms）
  ///
  /// 必须在 initState 创建：`late final` 惰性初始化会在未发生下拉的页面
  /// 于 dispose 首次触碰字段时、在已失活 Element 上建 Ticker 而抛错。
  late final AnimationController _pullReturnController;
  double _pullReturnFrom = 0;

  /// [批1b-2a P1] 程序化翻页在途标记：对齐参考版
  /// `ReaderProgrammaticTurnPolicy.shouldAccept(!animationRunning)`——
  /// 动画进行中忽略新的程序化翻页（不 abort、不排队），动画结束后
  /// 下一次 repeat 再翻。修复前 50ms 长按 repeat 会反复 abort 收尾动画，
  /// 被取消的 Completer 永不完成、页面不提交，整段长按只翻 1 页。
  bool _programmaticTurnInFlight = false;

  /// Gesture may cross chapter; bitmap exists only for in-chapter neighbors.
  bool get _gestureHasPrev => widget.pageIndex > 0 || widget.hasChapterPrev;
  bool get _gestureHasNext =>
      widget.pageIndex < widget.pageCount - 1 || widget.hasChapterNext;

  bool get _captureHasPrev => widget.pageIndex > 0;
  bool get _captureHasNext => widget.pageIndex < widget.pageCount - 1;

  /// 有效邻页快照：章内邻页优先，章边界回退到预载的相邻章页
  ui.Image? get _effPrev {
    if (_captureHasPrev) return _cache.display?.prev;
    if (widget.hasChapterPrev && widget.chapterPrevPage != null) {
      return _chapPrevImg;
    }
    return null;
  }

  ui.Image? get _effNext {
    if (_captureHasNext) return _cache.display?.next;
    if (widget.hasChapterNext && widget.chapterNextPage != null) {
      return _chapNextImg;
    }
    return null;
  }

  PageTurnSettleStyle get _settleStyle {
    switch (widget.mode) {
      case PageTurnMode.cover:
      case PageTurnMode.slide:
        return PageTurnSettleStyle.horizontal;
      case PageTurnMode.simulate:
      case PageTurnMode.none:
      case PageTurnMode.scroll:
        return PageTurnSettleStyle.simulation;
    }
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerTick);
    _pullReturnController = AnimationController(
      vsync: this,
      duration: const Duration(
        milliseconds: ReaderBookmarkPullGesture.returnDurationMillis,
      ),
    )..addListener(_onPullReturnTick);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scheduleWarmSnapshots(),
    );
  }

  @override
  void didUpdateWidget(covariant ReaderTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final chapterLanded =
        oldWidget.pageIndex != widget.pageIndex ||
        oldWidget.pageCount != widget.pageCount ||
        oldWidget.chapterPrevPage != widget.chapterPrevPage ||
        oldWidget.chapterNextPage != widget.chapterNextPage;
    if (chapterLanded && _chapterTurning) {
      // 父级章节已落地：退出承接态、收起遮罩
      setState(() {
        _chapterTurning = false;
        _chapterTurnDir = PageTurnDirection.none;
        _overlayVisible = false;
      });
      _scheduleWarmSnapshots();
      return;
    }
    // [UI_SYNC_REFACTOR S6 修 | 2026-09-08] 相邻章预览变更即作废其位图
    //（防旧章残留位图被当作"下一章"滑入 → 用户可见"闪现正文内容"），
    // 并立即重新抓取新预览 — Qoder
    if (oldWidget.chapterNextPage != widget.chapterNextPage) {
      _chapNextImg?.dispose();
      _chapNextImg = null;
    }
    if (oldWidget.chapterPrevPage != widget.chapterPrevPage) {
      _chapPrevImg?.dispose();
      _chapPrevImg = null;
    }
    if (oldWidget.pageIndex != widget.pageIndex ||
        oldWidget.pageCount != widget.pageCount ||
        oldWidget.mode != widget.mode ||
        oldWidget.backPageColor != widget.backPageColor ||
        oldWidget.chapterNextPage != widget.chapterNextPage ||
        oldWidget.chapterPrevPage != widget.chapterPrevPage) {
      _scheduleWarmSnapshots();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerTick);
    _controller.dispose();
    _pullReturnController.dispose();
    _cache.invalidate();
    _chapPrevImg?.dispose();
    _chapNextImg?.dispose();
    super.dispose();
  }

  void _onControllerTick() {
    if (mounted) setState(() {});
  }

  void _scheduleWarmSnapshots() {
    if (widget.mode == PageTurnMode.none ||
        widget.mode == PageTurnMode.scroll) {
      return;
    }
    if (widget.pageCount <= 0) return;
    final gen = ++_warmGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || gen != _warmGeneration) return;
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted || gen != _warmGeneration) return;
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final ok = await _cache.refresh(
        prevKey: _prevBoundaryKey,
        curKey: _curBoundaryKey,
        nextKey: _nextBoundaryKey,
        pixelRatio: dpr,
        hasPrev: _captureHasPrev,
        hasNext: _captureHasNext,
      );
      await _captureChapterBoundaries(dpr);
      if (mounted && ok && gen == _warmGeneration) {
        setState(() {});
      }
    });
  }

  Future<bool> _ensureCacheReady() async {
    if (_cache.hasCur) return true;
    await SchedulerBinding.instance.endOfFrame;
    if (!mounted) return false;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final ok = await _cache.refresh(
      prevKey: _prevBoundaryKey,
      curKey: _curBoundaryKey,
      nextKey: _nextBoundaryKey,
      pixelRatio: dpr,
      hasPrev: _captureHasPrev,
      hasNext: _captureHasNext,
    );
    await _captureChapterBoundaries(dpr);
    return ok;
  }

  /// 抓取相邻章预载页快照（章边界动画与承接用）
  Future<void> _captureChapterBoundaries(double dpr) async {
    if (widget.chapterPrevPage != null) {
      final img = await captureBoundary(_chapPrevBoundaryKey, pixelRatio: dpr);
      if (img != null && mounted) {
        _chapPrevImg?.dispose();
        _chapPrevImg = img;
      }
    }
    if (widget.chapterNextPage != null) {
      final img = await captureBoundary(_chapNextBoundaryKey, pixelRatio: dpr);
      if (img != null && mounted) {
        _chapNextImg?.dispose();
        _chapNextImg = img;
      }
    }
  }

  /// Programmatic turn used by tap zones / volume keys / auto-read.
  ///
  /// [批1b-2a P1] 动画运行中直接忽略（不 abort、不排队）：对齐参考版
  /// `ReaderProgrammaticTurnPolicy.shouldAccept(!animationRunning)`。
  /// 在途标记同时覆盖 `_ensureCacheReady` 的 await 窗口，防止两个
  /// 程序化翻页并发进入控制器。
  Future<void> turnByAnim(PageTurnDirection dir) async {
    if (dir == PageTurnDirection.none) return;
    if (_programmaticTurnInFlight ||
        _controller.isSettling ||
        _controller.isDragging) {
      return;
    }
    final size = context.size;
    if (size == null || size.isEmpty) return;

    _programmaticTurnInFlight = true;
    try {
      if (widget.mode == PageTurnMode.none) {
        _applyCompleted(dir);
        return;
      }

      // 章边界：有预载相邻章快照则照常动画；缺失才瞬时填充
      if (dir == PageTurnDirection.prev && !_captureHasPrev) {
        if (_chapPrevImg == null) {
          _applyCompleted(dir);
          return;
        }
      }
      if (dir == PageTurnDirection.next && !_captureHasNext) {
        if (_chapNextImg == null) {
          _applyCompleted(dir);
          return;
        }
      }

      final ready = await _ensureCacheReady();
      if (!mounted) return;
      // await 期间手势/其它动画可能已接管：不打断，直接放弃本次
      if (_controller.isSettling || _controller.isDragging) return;
      if (!ready || !_cache.hasCur) {
        _applyCompleted(dir);
        return;
      }

      setState(() => _overlayVisible = true);

      await _controller.turnByAnim(
        dir,
        vsync: this,
        viewWidth: size.width,
        viewHeight: size.height,
        hasPrev: _gestureHasPrev,
        hasNext: _gestureHasNext,
        onCompleted: _applyCompleted,
        settleStyle: _settleStyle,
      );
    } finally {
      _programmaticTurnInFlight = false;
      // 收尾清理不依赖 Completer 是否由动画正常完成：_abortSettle 现在
      // 也会 settle，被手势打断时同样走到这里恢复遮罩/调度快照
      if (mounted && !_chapterTurning) {
        setState(() => _overlayVisible = false);
        _scheduleWarmSnapshots();
      }
    }
  }

  void _applyCompleted(PageTurnDirection dir) {
    if (dir == PageTurnDirection.prev) {
      if (widget.pageIndex > 0) {
        widget.onPageChanged(widget.pageIndex - 1);
      } else if (widget.hasChapterPrev) {
        // 章边界：进入承接态（遮罩保留至父级章节落地，防闪现）
        setState(() {
          _chapterTurning = true;
          _chapterTurnDir = dir;
        });
        widget.onTurnChapterPrev();
      }
    } else if (dir == PageTurnDirection.next) {
      if (widget.pageIndex < widget.pageCount - 1) {
        widget.onPageChanged(widget.pageIndex + 1);
      } else if (widget.hasChapterNext) {
        setState(() {
          _chapterTurning = true;
          _chapterTurnDir = dir;
        });
        widget.onTurnChapterNext();
      }
    }
  }

  ReaderBookmarkPullDrag _pullDrag(Offset delta, Size size) {
    return ReaderBookmarkPullGesture.drag(
      delta: delta,
      pageHeight: size.height,
      enabled: widget.pullBookmarkEnabled,
      pagedMode: widget.mode != PageTurnMode.scroll,
      // [R49 阶段C] 字符级选区不再走模态路由：手柄拖拽的原始指针事件会
      // 到达本层，必须按真实选区状态禁用下拉书签判定（此前硬编码 false
      // 的假设已被阶段 A/B 的非模态交互打破）。
      selectionActive: _selectionActive,
    );
  }

  /// [R49 阶段C] 正文选区是否活跃（事件发生时读取，避免陈旧快照）
  bool get _selectionActive => widget.selectionActive?.value ?? false;

  void _resetPullState() {
    if (_pullReturnController.isAnimating) _pullReturnController.stop();
    _pullReturnController.reset();
    final hadPullState = _pullOffset != 0 || _pullDragging || _pullArmed;
    if (hadPullState) {
      // 回弹/拖动中点按：清零必须触发重绘，否则页面停在偏移位置
      setState(() {
        _pullOffset = 0;
        _pullDragging = false;
        _pullArmed = false;
        _pullReleased = false;
      });
    } else {
      _pullOffset = 0;
      _pullDragging = false;
      _pullArmed = false;
      _pullReleased = false;
    }
  }

  void _onPullReturnTick() {
    if (!mounted) return;
    setState(() {
      _pullOffset = _pullReturnFrom * (1 - _pullReturnController.value);
    });
  }

  void _startPullReturn() {
    if (!mounted) return;
    _pullReturnFrom = _pullOffset;
    if (_pullReturnFrom <= 0) {
      _pullOffset = 0;
      return;
    }
    _pullReturnController.forward(from: 0);
  }

  void _onPointerDown(PointerDownEvent e) {
    final size = context.size;
    _resetPullState();
    _pullDown = e.localPosition;
    _controller.onPointerDown(
      e.localPosition,
      viewWidth: size?.width,
      viewHeight: size?.height,
    );
    if (_selectionActive) {
      // [R49 阶段C] 选区活跃：翻页层让位（拖手柄/长按扩展不得翻页）。
      // 仍记录本次手势起点，若选区在手势中途被清除，位移从正确起点判定，
      // 也不会留下上一次手势的陈旧坐标。
      _controller.resetGesture();
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    final size = context.size;
    if (size == null) return;
    if (_selectionActive) {
      // [R49 阶段C] 选区活跃：原始指针移动全部让给选区层，翻页与下滑
      // 书签都不得消费；本手势若已进入判定则显式复位（防门控释放后
      // 用陈旧状态继续判定）。
      if (_pullDragging ||
          _pullOffset != 0 ||
          _pullArmed ||
          _pullReleased ||
          _controller.direction != PageTurnDirection.none ||
          _controller.isDragging) {
        _resetPullState();
        _controller.resetGesture();
      }
      return;
    }
    final slop =
        MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop;
    final delta = e.localPosition - _pullDown;

    // [批4d] 首次过 slop 只判定一次：纵向优势成立则本手势归书签，
    // 否则锁定给横滑翻页，后续斜向移动不得重新抢占。
    if (!_pullDragging && !_pullReleased && delta.distance >= slop) {
      final pull = _pullDrag(delta, size);
      if (pull.isCandidate) {
        _pullDragging = true;
      } else {
        _pullReleased = true;
      }
    }
    if (_pullDragging) {
      final pull = _pullDrag(delta, size);
      if (pull.isCandidate) {
        setState(() {
          _pullOffset = pull.pageOffset;
          _pullArmed = pull.isArmed;
        });
        return;
      }
      // 书签候选失效：清位移并把当前指针交还翻页控制器（参考同语义）
      setState(() {
        _pullDragging = false;
        _pullArmed = false;
        _pullOffset = 0;
      });
      _pullReleased = true;
    }

    final wasNone = _controller.direction == PageTurnDirection.none;
    final locked = _controller.onPointerMove(
      e.localPosition,
      hasPrev: _gestureHasPrev,
      hasNext: _gestureHasNext,
      slop: slop,
      viewWidth: size.width,
      viewHeight: size.height,
    );

    // Jingshiro: bitmaps already ready at setDirection — never capture here.
    if (locked &&
        wasNone &&
        _controller.direction != PageTurnDirection.none &&
        widget.mode != PageTurnMode.none) {
      final dir = _controller.direction;
      final canAnimate =
          _cache.hasCur &&
          (dir != PageTurnDirection.prev ||
              _captureHasPrev ||
              widget.hasChapterPrev) &&
          (dir != PageTurnDirection.next ||
              _captureHasNext ||
              widget.hasChapterNext);

      // Neighbor page bitmap required for in-chapter anim; chapter edge → instant.
      final bmpOk =
          _cache.hasCur &&
          (dir != PageTurnDirection.prev || _effPrev != null) &&
          (dir != PageTurnDirection.next || _effNext != null);

      if (canAnimate && bmpOk) {
        setState(() => _overlayVisible = true);
      } else if (dir == PageTurnDirection.prev && !_captureHasPrev) {
        // Chapter prev: no overlay, complete on up.
      } else if (dir == PageTurnDirection.next && !_captureHasNext) {
        // Chapter next: no overlay, complete on up.
      } else if (!_cache.hasCur) {
        // Missing cache — treat as none on up.
      }
    }

    // Jingshiro SimulationPageDelegate.onTouch MOVE mid-band Y pin.
    if (widget.mode == PageTurnMode.simulate &&
        _controller.direction != PageTurnDirection.none) {
      final h = size.height;
      final startY = _controller.startY;
      final dir = _controller.direction;
      if ((startY > h / 3 && startY < h * 2 / 3) ||
          dir == PageTurnDirection.prev) {
        _controller.touchY = h;
      }
      if (startY > h / 3 && startY < h / 2 && dir == PageTurnDirection.next) {
        _controller.touchY = 1;
      }
    }
  }

  Future<void> _onPointerUp(PointerUpEvent e) async {
    if (_selectionActive) {
      // [R49 阶段C] 选区活跃：抬手不得提交翻页/书签，显式复位门控状态
      _resetPullState();
      _controller.resetGesture();
      return;
    }
    if (_pullDragging) {
      final size = context.size;
      if (size != null) {
        // 参考：抬手判定必须使用指针最终位移，而非最后一个 MOVE 采样
        final pull = _pullDrag(e.localPosition - _pullDown, size);
        if (pull.isCandidate) {
          setState(() => _pullOffset = pull.pageOffset);
        }
        final toggle = ReaderBookmarkPullGesture.shouldToggleOnRelease(
          wasDragging: true,
          finalDrag: pull,
        );
        setState(() {
          _pullDragging = false;
          _pullArmed = false;
        });
        if (toggle) widget.onToggleBookmark?.call();
      } else {
        setState(() {
          _pullDragging = false;
          _pullArmed = false;
        });
      }
      _controller.resetGesture();
      _startPullReturn();
      return;
    }
    await _finishGesture();
  }

  Future<void> _onPointerCancel(PointerCancelEvent e) async {
    if (_selectionActive) {
      // [R49 阶段C] 选区活跃：取消同样只复位，不提交任何翻页/书签
      _resetPullState();
      _controller.resetGesture();
      return;
    }
    if (_pullDragging) {
      // 取消同样走 180ms 回弹（参考仅取消切换动作，位移平滑归零）
      setState(() {
        _pullDragging = false;
        _pullArmed = false;
      });
      _controller.resetGesture();
      _startPullReturn();
      return;
    }
    _controller.isCancel = true;
    await _finishGesture();
  }

  Future<void> _finishGesture() async {
    final size = context.size;
    if (size == null) return;

    final dir = _controller.direction;
    final cancel = _controller.isCancel;

    if (widget.mode == PageTurnMode.none) {
      if (dir != PageTurnDirection.none && !cancel) {
        _applyCompleted(dir);
      }
      _controller.resetGesture();
      return;
    }

    // No overlay (cache miss or chapter edge): instant fill when not cancelled.
    if (!_overlayVisible && dir != PageTurnDirection.none) {
      if (!cancel) {
        _applyCompleted(dir);
      }
      _controller.resetGesture();
      _scheduleWarmSnapshots();
      return;
    }

    if (dir == PageTurnDirection.none) {
      setState(() => _overlayVisible = false);
      _controller.resetGesture();
      return;
    }

    await _controller.onPointerUp(
      vsync: this,
      viewWidth: size.width,
      viewHeight: size.height,
      onCompleted: _applyCompleted,
      settleStyle: _settleStyle,
    );
    if (mounted && !_chapterTurning) {
      setState(() => _overlayVisible = false);
      _scheduleWarmSnapshots();
    }
  }

  CustomPainter? _buildPainter(Size size) {
    final c = _controller;
    final snap = _cache.display;
    final running = c.isDragging || c.isSettling;
    switch (widget.mode) {
      case PageTurnMode.slide:
        return SlidePagePainter(
          cur: snap?.cur,
          prev: _effPrev,
          next: _effNext,
          direction: c.direction,
          touchX: c.touchX,
          startX: c.startX,
          viewSize: size,
          isRunning: running,
        );
      case PageTurnMode.cover:
        return CoverPagePainter(
          cur: snap?.cur,
          prev: _effPrev,
          next: _effNext,
          direction: c.direction,
          touchX: c.touchX,
          startX: c.startX,
          viewSize: size,
          isRunning: running,
          devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
        );
      case PageTurnMode.simulate:
        return SimulationCurlPainter(
          cur: snap?.cur,
          prev: _effPrev,
          next: _effNext,
          direction: c.direction,
          touchX: c.touchX,
          touchY: c.touchY,
          cornerX: c.cornerX,
          cornerY: c.cornerY,
          viewSize: size,
          isRunning: running,
          backPageColor: widget.backPageColor,
        );
      case PageTurnMode.none:
      case PageTurnMode.scroll:
        return null;
    }
  }

  Widget _boundaryPage(GlobalKey key, int? index) {
    if (index == null || index < 0 || index >= widget.pageCount) {
      return const SizedBox.shrink();
    }
    // Opaque page (bg + content) so Cover/Slide bitmaps fully occlude underlay —
    // Jingshiro screenshots the full page view, not transparent text alone.
    return RepaintBoundary(
      key: key,
      child: ColoredBox(
        color: widget.backPageColor,
        child: SizedBox.expand(child: widget.buildPage(index)),
      ),
    );
  }

  Widget _boundaryWidget(GlobalKey key, Widget child) {
    return RepaintBoundary(
      key: key,
      child: ColoredBox(
        color: widget.backPageColor,
        child: SizedBox.expand(child: child),
      ),
    );
  }

  Widget _livePage(int pageIndex) {
    return ColoredBox(
      color: widget.backPageColor,
      child: KeyedSubtree(
        key: ValueKey('live-$pageIndex'),
        child: widget.buildPage(pageIndex),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pageIndex = widget.pageIndex;
    final prevIndex = pageIndex > 0 ? pageIndex - 1 : null;
    final nextIndex = pageIndex < widget.pageCount - 1 ? pageIndex + 1 : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final painter = _overlayVisible ? _buildPainter(size) : null;
        // Jingshiro ReadView: live curPage stays under the horizontal canvas.
        final keepLiveUnderlay =
            widget.mode == PageTurnMode.cover ||
            widget.mode == PageTurnMode.slide;

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: (e) => _onPointerUp(e),
          onPointerCancel: (e) => _onPointerCancel(e),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Slight opacity so RepaintBoundary.toImage still paints.
              Opacity(
                opacity: 0.01,
                child: IgnorePointer(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _boundaryPage(_prevBoundaryKey, prevIndex),
                      _boundaryPage(_curBoundaryKey, pageIndex),
                      _boundaryPage(_nextBoundaryKey, nextIndex),
                      if (widget.chapterPrevPage != null)
                        _boundaryWidget(
                          _chapPrevBoundaryKey,
                          widget.chapterPrevPage!,
                        ),
                      if (widget.chapterNextPage != null)
                        _boundaryWidget(
                          _chapNextBoundaryKey,
                          widget.chapterNextPage!,
                        ),
                    ],
                  ),
                ),
              ),
              if (_chapterTurning)
                // 承接态：直接显示相邻章预载页（新章落地前无闪现）
                ColoredBox(
                  color: widget.backPageColor,
                  child: _chapterTurnDir == PageTurnDirection.next
                      ? (widget.chapterNextPage ?? const SizedBox.shrink())
                      : (widget.chapterPrevPage ?? const SizedBox.shrink()),
                )
              else if (!_overlayVisible || keepLiveUnderlay)
                Transform.translate(
                  offset: Offset(0, _pullOffset),
                  child: _livePage(pageIndex),
                )
              else
                ColoredBox(color: widget.backPageColor),
              if (widget.overlay != null) widget.overlay!,
              if (painter != null)
                CustomPaint(
                  size: size,
                  painter: painter,
                  child: const SizedBox.expand(),
                ),
              // [批4d] 下滑达 80dp 后显示提示；120ms 淡入、松手立即隐藏
              Positioned(
                top:
                    widget.bookmarkHintTop +
                    ReaderBookmarkPullGesture.hintContentTopMargin,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _pullArmed ? 1 : 0,
                      duration: _pullArmed
                          ? const Duration(
                              milliseconds:
                                  ReaderBookmarkPullGesture.hintFadeMillis,
                            )
                          : Duration.zero,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xA0000000),
                          borderRadius: BorderRadius.circular(
                            ReaderBookmarkPullGesture.hintCornerRadius,
                          ),
                        ),
                        child: Text(
                          widget.hasBookmarkOnPage
                              ? AppStrings.releaseToRemoveBookmark
                              : AppStrings.releaseToAddBookmark,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
