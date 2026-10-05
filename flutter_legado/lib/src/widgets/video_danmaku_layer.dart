import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:video_player/video_player.dart';

import '../models/models.dart';

/// 弹幕类型常量（B 站协议 / DanmakuFlameMaster 0.9.25 映射）
///
/// 1 右→左滚动 / 4 底部固定 / 5 顶部固定 / 6 左→右滚动 / 7 高级弹幕。
/// 2/3/8 及范围外类型已在 Rust 解析侧静默丢弃（契约 §2.50）。
abstract final class DanmakuType {
  static const int scrollR2L = 1;
  static const int fixBottom = 4;
  static const int fixTop = 5;
  static const int scrollL2R = 6;
  static const int special = 7;
}

/// 单条弹幕的当帧布局结果
class DanmakuPlacement {
  const DanmakuPlacement({
    required this.item,
    required this.lane,
    required this.x,
    required this.y,
    required this.fontSize,
  });

  /// 弹幕项
  final VideoDanmakuItem item;

  /// 行号（0 = 顶部第一行）
  final int lane;

  /// 绘制左边界（逻辑像素）
  final double x;

  /// 绘制上边界（逻辑像素）
  final double y;

  /// 字号（逻辑像素，已做 density 换算）
  final double fontSize;
}

/// 弹幕布局引擎（纯 Dart，可脱离 widget 单测）
///
/// 对齐原版 DanmakuFlameMaster 0.9.25 的关键行为：
/// - 滚动弹幕时长 = 3800ms（`DanmakuFactory.REAL_DANMAKU_DURATION`）×
///   速度因子 `danmakuSpeed - (speed-1)/6`（`VideoPlayer.kt:135-141/296`，
///   `danmakuSpeed=1.2` 见 `VideoPlay.kt:96`）；
/// - 固定弹幕时长 = 3800ms（`MAX_Duration_Fix_Danmaku`）；
/// - 右→左滚动最多 5 行（`VideoPlayer.kt:287` `maxLinesPair[TYPE_SCROLL_RL]=5`）；
/// - 字号 = 原值 × (density - 0.6)（`BiliDanmukuParser.kt:104`），并换算为
///   Flutter 逻辑像素（×(dpr-0.6)/dpr）；
/// - 行分配在弹幕进入时刻确定并按生命周期保持（避免中途换行闪烁）；
///   行满则丢弃该条（对齐库 MaxLinesFilter 超出隐藏语义）；
/// - 左→右滚动不设 5 行上限：原版 `maxLinesPair` 仅登记
///   `TYPE_SCROLL_RL=5`（`VideoPlayer.kt:287`），L2R 本就未限行，
///   本实现与之一致（对齐说明，非偏离）；
/// - 四类弹幕（含底部固定）统一执行同轨防重叠：原版 `preventOverlapping`
///   仅显式配置 `TYPE_SCROLL_RL` 与 `TYPE_FIX_TOP`（`VideoPlayer.kt:294-297`），
///   底部固定允许重叠——本实现更严格，登记为有意偏离（效果：底部密集时
///   多余条目按行满语义丢弃，而非重叠绘制）。
class DanmakuLayoutEngine {
  DanmakuLayoutEngine({required this.items});

  /// 弹幕项（按 timeMs 升序，来自 Rust §2.50 解析）
  final List<VideoDanmakuItem> items;

  /// 文本宽度测量回调（逻辑像素）；测试可注入确定值
  double Function(VideoDanmakuItem item, double fontSize) measureText =
      _defaultMeasureText;

  static double _defaultMeasureText(VideoDanmakuItem item, double fontSize) =>
      item.text.length * fontSize;

  /// 滚动弹幕基准时长（DanmakuFactory REAL_DANMAKU_DURATION = 3800ms）
  static const double _scrollBaseDurationMs = 3800;

  /// 固定弹幕时长（MAX_Duration_Fix_Danmaku = 3800ms）
  static const double _fixedDurationMs = 3800;

  /// 原版弹幕滚动速度因子（`VideoPlay.kt:96 danmakuSpeed = 1.2f`）
  static const double _baseSpeedFactor = 1.2;

  /// 右→左滚动最大行数（`VideoPlayer.kt:287`）
  static const int _scrollingMaxLines = 5;

  /// 时间跳变阈值：相邻帧时间差超过该值视为 seek → 清空行分配重排
  static const int seekSnapThresholdMs = 700;

  /// 行高基准字号（协议常见 25 号字；`DANMAKU_MEDIUM_TEXTSIZE`）
  static const double _lineSizeRaw = 25;

  /// 行高倍率（文本高度 + 行距近似）
  static const double _lineHeightRatio = 1.35;

  final Map<int, int> _laneOf = {}; // item 下标 -> 行号（-1 = 行满丢弃）
  final Map<int, double> _widthCache = {};
  int _scanStart = 0;
  int? _lastPositionMs;
  Size? _lastSize;
  double _lastDpr = 0;

  /// 字号换算（原版物理像素 → Flutter 逻辑像素）
  static double fontSizeOf(double rawSize, double dpr) {
    final scale = (dpr - 0.6) / dpr;
    return (rawSize * scale).clamp(1.0, 400.0);
  }

  /// 单条弹幕在媒体时间轴上的显示时长（毫秒）
  static double durationMsOf(VideoDanmakuItem item, double playbackSpeed) {
    switch (item.type) {
      case DanmakuType.scrollR2L:
      case DanmakuType.scrollL2R:
        final factor = _baseSpeedFactor - (playbackSpeed - 1) / 6;
        return _scrollBaseDurationMs * factor.clamp(0.2, 3.0);
      default:
        return _fixedDurationMs;
    }
  }

  /// 当帧应绘制的弹幕（含位置）；行满/已过期/未到时刻的不包含
  List<DanmakuPlacement> placementsAt({
    required int positionMs,
    required Size size,
    required double dpr,
    required double playbackSpeed,
  }) {
    if (items.isEmpty || size.width <= 0 || size.height <= 0) {
      return const [];
    }
    final last = _lastPositionMs;
    if (last != null && (positionMs - last).abs() > seekSnapThresholdMs) {
      // seek/时间跳变：行分配作废重排
      _laneOf.clear();
      _scanStart = 0;
    }
    _lastPositionMs = positionMs;
    if (_lastSize != size || _lastDpr != dpr) {
      // 视口/密度变化：行分配与文本宽度缓存作废
      _laneOf.clear();
      _widthCache.clear();
      _scanStart = 0;
      _lastSize = size;
      _lastDpr = dpr;
    }

    final lineHeight = fontSizeOf(_lineSizeRaw, dpr) * _lineHeightRatio;
    final viewportLanes = math.max(1, (size.height / lineHeight).floor());

    // 跳过已过期前缀（保守：仅当该项按自身时长已过期才前移），
    // 并同步裁剪行分配/宽度缓存（P0-2）：items 按 timeMs 升序、index 连续，
    // 每个条目只会被裁剪一次（O(1) 摊销），同时把 _assignLane 的扫描集
    // 限定在活跃窗口内，避免长视频 UI 线程千万级 Map 访问/秒。
    // 回退 seek <700ms 时被裁剪项若重入窗口会重新分配行号，属可接受代价
    // （>700ms 本就全量重排）。
    while (_scanStart < items.length) {
      final item = items[_scanStart];
      if (item.timeMs + durationMsOf(item, playbackSpeed) >= positionMs) {
        break;
      }
      _laneOf.remove(_scanStart);
      _widthCache.remove(_scanStart);
      _scanStart++;
    }

    final result = <DanmakuPlacement>[];
    for (var i = _scanStart; i < items.length; i++) {
      final item = items[i];
      if (item.timeMs > positionMs) break;
      final duration = durationMsOf(item, playbackSpeed);
      if (positionMs > item.timeMs + duration) continue;

      var lane = _laneOf[i];
      if (lane == null) {
        lane = _assignLane(
          i,
          size: size,
          lineHeight: lineHeight,
          viewportLanes: viewportLanes,
          playbackSpeed: playbackSpeed,
        );
        _laneOf[i] = lane;
      }
      if (lane < 0) continue;

      final fontSize = fontSizeOf(item.textSizeRaw, dpr);
      final textWidth = _widthOf(i, fontSize);
      final progress =
          ((positionMs - item.timeMs) / duration).clamp(0.0, 1.0);

      final double x;
      final double y;
      switch (item.type) {
        case DanmakuType.scrollR2L:
          x = size.width - progress * (size.width + textWidth);
          y = lane * lineHeight;
        case DanmakuType.scrollL2R:
          x = -textWidth + progress * (size.width + textWidth);
          y = lane * lineHeight;
        case DanmakuType.fixTop:
          x = (size.width - textWidth) / 2;
          y = lane * lineHeight;
        case DanmakuType.fixBottom:
          x = (size.width - textWidth) / 2;
          y = size.height - (lane + 1) * lineHeight;
        default:
          // type7（高级弹幕）V-B2 不渲染（契约 §2.50 登记边界）
          continue;
      }
      result.add(
        DanmakuPlacement(
          item: item,
          lane: lane,
          x: x,
          y: y,
          fontSize: fontSize,
        ),
      );
    }
    return result;
  }

  /// 进入时刻分配行号：同类弹幕从 0 行起找首个占用区间不重叠的行；
  /// 行满返回 -1（该条整生命期丢弃）
  ///
  /// 滚动弹幕同轨判据（P1-3 修正）：滚动速度 = (W + width) / duration 与
  /// 自身宽度成正比，旧实现只要求后车晚于「前车尾部完全入场」，等宽成立、
  /// 异宽不成立（长后车更快，巡航期必然追及重叠）。精确不追尾条件：两车
  /// 共存期间最小横向间距 ≥ 0，其极值取在前车完全离场时刻（前车尾缘恰在
  /// 出场侧屏缘），化简得最小入场间隔
  /// `duration × max(W前, W后) / (W + max(W前, W后))`：
  /// 两车等宽时退化为原判据；后车更长时要求更晚，极端下收敛于「前车完全
  /// 离场」（duration）。R2L/L2R 推导对称，同式成立。
  /// 固定弹幕按整时长 [start, start+duration) 区间占用；底部固定同样参与
  /// 防重叠（原版仅 R2L/TOP 显式开启，见类头注释的偏离登记）。
  int _assignLane(
    int index, {
    required Size size,
    required double lineHeight,
    required int viewportLanes,
    required double playbackSpeed,
  }) {
    final item = items[index];
    final laneCount = item.type == DanmakuType.scrollR2L
        ? math.min(_scrollingMaxLines, viewportLanes)
        : viewportLanes;
    final start = item.timeMs.toDouble();
    final duration = durationMsOf(item, playbackSpeed);
    final isScroll = item.type == DanmakuType.scrollR2L ||
        item.type == DanmakuType.scrollL2R;
    final newWidth = isScroll
        ? _widthOf(index, fontSizeOf(item.textSizeRaw, _lastDpr))
        : 0.0;

    for (var lane = 0; lane < laneCount; lane++) {
      var free = true;
      for (final entry in _laneOf.entries) {
        if (entry.value != lane) continue;
        final other = items[entry.key];
        if (other.type != item.type) continue;
        final otherStart = other.timeMs.toDouble();
        if (isScroll) {
          // 同轨滚动：按两车较宽者取最小入场间隔（见方法注释推导）
          final otherWidth =
              _widthOf(entry.key, fontSizeOf(other.textSizeRaw, _lastDpr));
          final maxWidth = math.max(otherWidth, newWidth);
          final minGap = duration * maxWidth / (size.width + maxWidth);
          if ((start - otherStart).abs() < minGap) {
            free = false;
            break;
          }
        } else {
          final otherEnd = otherStart + durationMsOf(other, playbackSpeed);
          if (start < otherEnd && otherStart < start + duration) {
            free = false;
            break;
          }
        }
      }
      if (free) return lane;
    }
    return -1;
  }

  double _widthOf(int index, double fontSize) {
    final cached = _widthCache[index];
    if (cached != null) return cached;
    final width = measureText(items[index], fontSize);
    _widthCache[index] = width;
    return width;
  }

  /// 作废行分配（P2：倍速变化时占用时长口径改变，旧区间失效 → 重排；
  /// 文本宽度与倍速无关，宽度缓存保留）
  void resetLaneAssignments() {
    _laneOf.clear();
  }

  /// 测试辅助：行分配缓存条目数（P0-B 有界性断言）
  @visibleForTesting
  int get debugLaneCacheSize => _laneOf.length;

  /// 测试辅助：文本宽度缓存条目数（P0-B 有界性断言）
  @visibleForTesting
  int get debugWidthCacheSize => _widthCache.length;

  /// 测试辅助：清空内部布局缓存
  @visibleForTesting
  void debugReset() {
    _laneOf.clear();
    _widthCache.clear();
    _scanStart = 0;
    _lastPositionMs = null;
    _lastSize = null;
    _lastDpr = 0;
  }
}

/// 视频弹幕渲染层（V-B2，自绘 CustomPainter，不引第三方插件）
///
/// 叠加在视频画面之上、控制层之下；时间轴跟随播放位置：
/// - 播放：本地 Ticker 在两次 position 采样间插值（媒体时钟 × 倍速）；
/// - 暂停：Ticker 停止，弹幕冻结在原位（对齐 `VideoPlayer.kt:156-174`）；
/// - seek：position 跳变后重新锚定并重排（对齐 `:199-209`）；
/// - [show]=false：只隐藏绘制，时间轴照常推进（对齐 `DanmakuView.hide()`）。
class VideoDanmakuLayer extends StatefulWidget {
  const VideoDanmakuLayer({
    super.key,
    required this.items,
    required this.player,
    required this.show,
    this.playbackSpeed = 1.0,
  });

  /// 当前章节弹幕（Rust §2.50 解析结果；type7 已含但本批不渲染）
  final List<VideoDanmakuItem> items;

  /// 播放器值监听（读取 position / isPlaying；测试可传 ValueNotifier）
  final ValueListenable<VideoPlayerValue> player;

  /// 弹幕开关（对齐原版 VideoPlay.danmakuShow）
  final bool show;

  /// 当前倍速（对齐 VideoPlayer.kt:135-141 的弹幕速度联动）
  final double playbackSpeed;

  @override
  State<VideoDanmakuLayer> createState() => VideoDanmakuLayerState();
}

class VideoDanmakuLayerState extends State<VideoDanmakuLayer>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<int> _clockMs = ValueNotifier<int>(0);
  late DanmakuLayoutEngine _engine;

  /// 媒体时钟锚点：最近一次已知播放位置与对应 Ticker 时刻
  int _anchorPositionMs = 0;
  Duration _anchorElapsed = Duration.zero;
  /// 最近一次 Ticker 回调的 elapsed（SDK Ticker 无公开 elapsed getter）
  Duration _lastTickElapsed = Duration.zero;
  bool _wasPlaying = false;

  /// 测试辅助：当前媒体时钟（毫秒）
  @visibleForTesting
  int get debugClockMs => _clockMs.value;

  /// 测试辅助：当前帧布局
  @visibleForTesting
  List<DanmakuPlacement> debugPlacements(Size size, {double dpr = 3.0}) =>
      _engine.placementsAt(
        positionMs: _clockMs.value,
        size: size,
        dpr: dpr,
        playbackSpeed: widget.playbackSpeed,
      );

  @override
  void initState() {
    super.initState();
    _engine = DanmakuLayoutEngine(items: widget.items)
      ..measureText = _measureTextWidth;
    _ticker = createTicker(_onTick);
    widget.player.addListener(_onPlayerChanged);
    _rebindToPlayer(widget.player.value);
  }

  @override
  void didUpdateWidget(covariant VideoDanmakuLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.items, widget.items)) {
      _engine = DanmakuLayoutEngine(items: widget.items)
        ..measureText = _measureTextWidth;
    }
    if (!identical(oldWidget.player, widget.player)) {
      // [P0-1] 切集换控制器：video_screen 会 dispose 旧实例并新建，
      // 相邻两集均有弹幕时本层持续挂载，必须重订阅：否则监听已 dispose
      // 的旧控制器 → 播放中弹幕退化为墙钟漂移（暂停/seek 失效），
      // 暂停中切集则永久冻结。
      oldWidget.player.removeListener(_onPlayerChanged);
      widget.player.addListener(_onPlayerChanged);
      _rebindToPlayer(widget.player.value);
    }
    if (oldWidget.playbackSpeed != widget.playbackSpeed) {
      // 倍速变化：以当前插值位置为新锚点，避免时间轴跳变
      _anchorPositionMs = _clockMs.value;
      _anchorElapsed =
          _ticker.isActive ? _lastTickElapsed : Duration.zero;
      // [P2] 行占用区间按旧 duration 计算已失效 → 作废重排
      _engine.resetLaneAssignments();
    }
  }

  /// 以控制器当前值重锚时间轴并同步 Ticker（初挂与切集换控制器共用）。
  ///
  /// Ticker 已在跑且新控制器在播放时，从最近一次 tick 的 elapsed 继续插值，
  /// 避免把累计 elapsed 重新计入新锚点造成时钟跳变。
  void _rebindToPlayer(VideoPlayerValue value) {
    _anchorPositionMs = value.position.inMilliseconds;
    _clockMs.value = _anchorPositionMs;
    _wasPlaying = value.isPlaying;
    if (_wasPlaying) {
      if (_ticker.isActive) {
        _anchorElapsed = _lastTickElapsed;
      } else {
        _anchorElapsed = Duration.zero;
        _lastTickElapsed = Duration.zero;
        _ticker.start();
      }
    } else {
      _anchorElapsed = _ticker.isActive ? _lastTickElapsed : Duration.zero;
      if (_ticker.isActive) {
        _ticker.stop();
      }
    }
  }

  void _onPlayerChanged() {
    final value = widget.player.value;
    final newMs = value.position.inMilliseconds;
    if (newMs != _anchorPositionMs) {
      // 位置采样/seek：重新锚定（插值误差在采样周期内自校正）
      _anchorPositionMs = newMs;
      _anchorElapsed =
          _ticker.isActive ? _lastTickElapsed : Duration.zero;
      _clockMs.value = newMs;
    }
    if (value.isPlaying != _wasPlaying) {
      _wasPlaying = value.isPlaying;
      if (value.isPlaying) {
        _anchorElapsed = Duration.zero;
        _lastTickElapsed = Duration.zero;
        _ticker.start();
      } else {
        // 暂停：冻结在当前插值位置（对齐 danmakuOnPause）
        _anchorPositionMs = _clockMs.value;
        _ticker.stop();
      }
    }
  }

  void _onTick(Duration elapsed) {
    _lastTickElapsed = elapsed;
    final deltaMs = (elapsed - _anchorElapsed).inMicroseconds / 1000.0;
    _clockMs.value =
        _anchorPositionMs + (deltaMs * widget.playbackSpeed).round();
  }

  double _measureTextWidth(VideoDanmakuItem item, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: item.text,
        style: TextStyle(fontSize: fontSize, height: 1.0),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  @override
  void dispose() {
    widget.player.removeListener(_onPlayerChanged);
    _ticker.dispose();
    _clockMs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return IgnorePointer(
      child: RepaintBoundary(
        child: SizedBox.expand(
          child: CustomPaint(
            painter: _DanmakuPainter(
              engine: _engine,
              clock: _clockMs,
              show: widget.show,
              playbackSpeed: widget.playbackSpeed,
              dpr: dpr,
            ),
          ),
        ),
      ),
    );
  }
}

/// 当帧可见弹幕（painter 与测试共用；[show]=false 或空列表 → 不绘制）
List<DanmakuPlacement> visibleDanmakuPlacements({
  required DanmakuLayoutEngine engine,
  required int positionMs,
  required Size size,
  required bool show,
  required double dpr,
  required double playbackSpeed,
}) {
  if (!show) return const [];
  return engine.placementsAt(
    positionMs: positionMs,
    size: size,
    dpr: dpr,
    playbackSpeed: playbackSpeed,
  );
}

class _DanmakuPainter extends CustomPainter {
  _DanmakuPainter({
    required this.engine,
    required this.clock,
    required this.show,
    required this.playbackSpeed,
    required this.dpr,
  }) : super(repaint: clock);

  final DanmakuLayoutEngine engine;
  final ValueNotifier<int> clock;
  final bool show;
  final double playbackSpeed;
  final double dpr;

  /// 描边宽度（原版 `setDanmakuStyle(STROKEN, 3f)`，物理像素 → 逻辑像素）
  static const double _strokeWidthPx = 3;

  @override
  void paint(Canvas canvas, Size size) {
    final placements = visibleDanmakuPlacements(
      engine: engine,
      positionMs: clock.value,
      size: size,
      show: show,
      dpr: dpr,
      playbackSpeed: playbackSpeed,
    );
    for (final placement in placements) {
      _paintItem(canvas, placement);
    }
  }

  void _paintItem(Canvas canvas, DanmakuPlacement placement) {
    final item = placement.item;
    final fillColor = Color(item.color & 0xFFFFFFFF);
    // 对齐原版 BiliDanmukuParser.kt:106-107 的有符号比较：
    // color <= BLACK(-16777216) 仅纯黑成立 → 纯黑白描边，其余黑描边
    final strokeColor =
        item.color <= -16777216 ? Colors.white : Colors.black;
    final baseStyle = TextStyle(
      fontSize: placement.fontSize,
      height: 1.0,
    );
    final strokeStyle = baseStyle.copyWith(
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidthPx / dpr
        ..strokeJoin = StrokeJoin.round
        ..color = strokeColor,
    );
    final fillStyle = baseStyle.copyWith(color: fillColor);

    final painter = TextPainter(
      text: TextSpan(text: item.text, style: strokeStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final offset = Offset(placement.x, placement.y);
    painter.paint(canvas, offset);
    painter.text = TextSpan(text: item.text, style: fillStyle);
    painter.layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _DanmakuPainter oldDelegate) {
    return oldDelegate.engine != engine ||
        oldDelegate.show != show ||
        oldDelegate.playbackSpeed != playbackSpeed ||
        oldDelegate.dpr != dpr;
  }
}
