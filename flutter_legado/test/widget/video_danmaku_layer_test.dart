// V-B2 视频弹幕渲染层 widget 测试（契约 §2.50 渲染侧）
//
// 覆盖播放器联动行为：
// 1. 滚动弹幕随播放移动（R2L x 递减）
// 2. 暂停冻结（isPlaying=false 后媒体时钟不再前进，对齐 VideoPlayer.kt:156-174）
// 3. seek 后时间轴同步（对齐 VideoPlayer.kt:199-209）
// 4. 无弹幕（空列表）不产生绘制项
//
// [V-B2 | 2026-10-05] 新增。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/widgets/video_danmaku_layer.dart';

VideoDanmakuItem _item(
  int type, {
  int timeMs = 0,
  String text = 'AAAA',
}) {
  return VideoDanmakuItem(
    timeMs: timeMs,
    type: type,
    textSizeRaw: 25,
    color: -1,
    text: text,
  );
}

VideoPlayerValue _value({int positionMs = 0, bool playing = true}) {
  return VideoPlayerValue(
    duration: const Duration(minutes: 10),
    position: Duration(milliseconds: positionMs),
    isPlaying: playing,
  );
}

Widget _host(
  ValueNotifier<VideoPlayerValue> player,
  List<VideoDanmakuItem> items, {
  bool show = true,
  double speed = 1.0,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 400,
          height: 300,
          child: VideoDanmakuLayer(
            items: items,
            player: player,
            show: show,
            playbackSpeed: speed,
          ),
        ),
      ),
    ),
  );
}

void main() {
  const viewSize = Size(400, 300);

  testWidgets('滚动弹幕随播放移动（R2L x 递减）', (tester) async {
    final player = ValueNotifier(_value(positionMs: 0, playing: true));
    addTearDown(player.dispose);
    await tester.pumpWidget(
      _host(player, [_item(DanmakuType.scrollR2L)]),
    );
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));

    final start = state.debugPlacements(viewSize).single;
    expect(start.x, closeTo(viewSize.width, 1), reason: '入场贴右缘');

    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugClockMs, closeTo(500, 30), reason: 'Ticker 插值推进媒体时钟');
    final moved = state.debugPlacements(viewSize).single;
    expect(moved.x, lessThan(start.x), reason: '滚动弹幕随时间左移');
  });

  testWidgets('暂停冻结：isPlaying=false 后时钟不再前进', (tester) async {
    final player = ValueNotifier(_value(positionMs: 0, playing: true));
    addTearDown(player.dispose);
    await tester.pumpWidget(_host(player, [_item(DanmakuType.scrollR2L)]));
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));

    await tester.pump(const Duration(milliseconds: 300));
    final beforePause = state.debugClockMs;
    expect(beforePause, greaterThan(0));

    player.value = _value(positionMs: beforePause, playing: false);
    await tester.pump();
    final frozen = state.debugClockMs;

    await tester.pump(const Duration(seconds: 2));
    expect(state.debugClockMs, frozen, reason: '暂停期间弹幕时间轴冻结');
    final placement = state.debugPlacements(viewSize).single;
    expect(placement.item.timeMs, 0);
  });

  testWidgets('seek 后时间轴同步到新位置并切换可见弹幕', (tester) async {
    final player = ValueNotifier(_value(positionMs: 0, playing: true));
    addTearDown(player.dispose);
    await tester.pumpWidget(
      _host(player, [
        _item(DanmakuType.scrollR2L, timeMs: 0, text: '旧'),
        _item(DanmakuType.scrollR2L, timeMs: 120000, text: '新'),
      ]),
    );
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));
    expect(
      state.debugPlacements(viewSize).map((p) => p.item.text),
      contains('旧'),
    );

    // seek 到 120s：控制器值变化 → 层重锚，引擎按时间跳变重排
    player.value = _value(positionMs: 120000, playing: true);
    await tester.pump();

    expect(state.debugClockMs, 120000, reason: 'seek 后媒体时钟对齐新位置');
    final placements = state.debugPlacements(viewSize);
    expect(placements.length, 1);
    expect(placements.single.item.text, '新', reason: '旧弹幕已过期不再绘制');
  });

  testWidgets('无弹幕（空列表）不产生绘制项', (tester) async {
    final player = ValueNotifier(_value(positionMs: 0, playing: false));
    addTearDown(player.dispose);
    await tester.pumpWidget(_host(player, const []));
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));

    expect(state.debugPlacements(viewSize), isEmpty);
    expect(
      find.byType(CustomPaint),
      findsWidgets,
      reason: '渲染层仍在（开关/画面容器），只是无弹幕可绘',
    );
  });

  testWidgets('player 实例替换：重订阅新控制器、旧控制器监听失效（切集）', (tester) async {
    // [P0-1] 切集时 video_screen 会 dispose 旧控制器并新建实例；
    // 相邻两集均有弹幕时弹幕层持续挂载，必须随 widget.player 更换重订阅
    final playerA = ValueNotifier(_value(positionMs: 0, playing: true));
    final playerB = ValueNotifier(_value(positionMs: 60000, playing: false));
    addTearDown(playerA.dispose);
    addTearDown(playerB.dispose);
    final items = [
      _item(DanmakuType.scrollR2L, timeMs: 0, text: 'old'),
      _item(DanmakuType.scrollR2L, timeMs: 60000, text: 'new'),
    ];
    await tester.pumpWidget(_host(playerA, items));
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));
    await tester.pump(const Duration(milliseconds: 300));
    expect(state.debugClockMs, greaterThan(0), reason: '旧控制器播放中推进');

    // 切集：host 以新控制器重建（同类型同位置 → State 保留）
    await tester.pumpWidget(_host(playerB, items));
    expect(state.debugClockMs, 60000, reason: '时间轴重锚到新控制器位置');
    expect(
      state.debugPlacements(viewSize).single.item.text,
      'new',
      reason: '绘制窗口随新控制器时间轴切换',
    );

    // 新控制器暂停 → 冻结（不得退化为墙钟漂移）
    await tester.pump(const Duration(seconds: 2));
    expect(state.debugClockMs, 60000, reason: '新控制器暂停时时钟冻结');

    // 旧控制器事件不得再驱动本层
    playerA.value = _value(positionMs: 5000, playing: true);
    await tester.pump();
    expect(state.debugClockMs, 60000, reason: '旧控制器监听已解除');

    // 新控制器播放 → 恢复推进
    playerB.value = _value(positionMs: 60000, playing: true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.debugClockMs, greaterThan(60000), reason: '新控制器播放恢复推进');
  });

  testWidgets('倍速变化：行分配按新时长口径重排（P2）', (tester) async {
    final player = ValueNotifier(_value(positionMs: 1000, playing: false));
    addTearDown(player.dispose);
    final items = [
      _item(DanmakuType.scrollR2L, timeMs: 0, text: 'AAAAAAAA'), // 宽 160
      _item(DanmakuType.scrollR2L, timeMs: 1000, text: 'AAAA'), // 宽 80
    ];
    await tester.pumpWidget(_host(player, items, speed: 1.0));
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));
    expect(state.debugPlacements(viewSize).length, 2);
    expect(
      state
          .debugPlacements(viewSize)
          .firstWhere((p) => p.item.timeMs == 1000)
          .lane,
      1,
      reason: '1x：间隔 1000ms < minGap 4560×160/560≈1302.9ms → 换轨',
    );

    await tester.pumpWidget(_host(player, items, speed: 3.0));
    expect(
      state
          .debugPlacements(viewSize)
          .firstWhere((p) => p.item.timeMs == 1000)
          .lane,
      0,
      reason: '3x：时长缩至 3293ms，间隔 1000ms ≥ minGap≈941ms → 重排进 0 轨',
    );
  });

  testWidgets('开关显隐：show=false 时绘制项为空（时间轴照常推进）', (tester) async {
    final player = ValueNotifier(_value(positionMs: 0, playing: true));
    addTearDown(player.dispose);
    final items = [_item(DanmakuType.scrollR2L)];
    await tester.pumpWidget(_host(player, items, show: false));
    final state =
        tester.state<VideoDanmakuLayerState>(find.byType(VideoDanmakuLayer));

    // 与 painter 共用同一可见性函数：显示时有项、隐藏时无项
    final engine = DanmakuLayoutEngine(items: items)
      ..measureText = (item, fontSize) => 40;
    expect(
      visibleDanmakuPlacements(
        engine: engine,
        positionMs: 0,
        size: viewSize,
        show: true,
        dpr: 3,
        playbackSpeed: 1,
      ),
      isNotEmpty,
    );
    expect(
      visibleDanmakuPlacements(
        engine: engine,
        positionMs: 0,
        size: viewSize,
        show: false,
        dpr: 3,
        playbackSpeed: 1,
      ),
      isEmpty,
    );

    await tester.pump(const Duration(milliseconds: 400));
    expect(state.debugClockMs, greaterThan(0), reason: '隐藏不暂停时间轴（对齐 hide 语义）');
  });
}
