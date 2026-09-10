import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../providers/reader/reader_state.dart';
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
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scheduleWarmSnapshots(),
    );
  }

  @override
  void didUpdateWidget(covariant ReaderTurnView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final chapterLanded = oldWidget.pageIndex != widget.pageIndex ||
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
  Future<void> turnByAnim(PageTurnDirection dir) async {
    if (dir == PageTurnDirection.none) return;
    final size = context.size;
    if (size == null || size.isEmpty) return;

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
    if (mounted && !_chapterTurning) {
      setState(() => _overlayVisible = false);
      _scheduleWarmSnapshots();
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

  void _onPointerDown(PointerDownEvent e) {
    final size = context.size;
    _controller.onPointerDown(
      e.localPosition,
      viewWidth: size?.width,
      viewHeight: size?.height,
    );
  }

  void _onPointerMove(PointerMoveEvent e) {
    final size = context.size;
    if (size == null) return;
    final slop =
        MediaQuery.maybeGestureSettingsOf(context)?.touchSlop ?? kTouchSlop;

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
      final bmpOk = _cache.hasCur &&
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
    await _finishGesture();
  }

  Future<void> _onPointerCancel(PointerCancelEvent e) async {
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
                            _chapPrevBoundaryKey, widget.chapterPrevPage!),
                      if (widget.chapterNextPage != null)
                        _boundaryWidget(
                            _chapNextBoundaryKey, widget.chapterNextPage!),
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
                _livePage(pageIndex)
              else
                ColoredBox(color: widget.backPageColor),
              if (widget.overlay != null) widget.overlay!,
              if (painter != null)
                CustomPaint(
                  size: size,
                  painter: painter,
                  child: const SizedBox.expand(),
                ),
            ],
          ),
        );
      },
    );
  }
}
