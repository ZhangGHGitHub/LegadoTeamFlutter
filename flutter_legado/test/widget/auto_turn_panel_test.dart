import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/reader/auto_turn_panel.dart';

/// 自动翻页运行时浮条测试（差异清单 C10）
///
/// 覆盖：间隔展示、步进夹取范围、三个快捷入口回调。
void main() {
  Future<void> pumpPanel(
    WidgetTester tester, {
    required double interval,
    required ValueChanged<double> onIntervalChanged,
    VoidCallback? onStop,
    VoidCallback? onCatalog,
    VoidCallback? onSettings,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AutoTurnPanel(
          intervalSeconds: interval,
          onIntervalChanged: onIntervalChanged,
          onStop: onStop ?? () {},
          onOpenCatalog: onCatalog ?? () {},
          onOpenSettings: onSettings ?? () {},
        ),
      ),
    ));
  }

  testWidgets('展示当前间隔与三个快捷入口', (tester) async {
    await pumpPanel(tester, interval: 20, onIntervalChanged: (_) {});
    expect(find.text('自动翻页'), findsOneWidget);
    expect(find.text('20 秒'), findsOneWidget);
    expect(find.byTooltip('目录'), findsOneWidget);
    expect(find.byTooltip('停止自动翻页'), findsOneWidget);
    expect(find.byTooltip('阅读设置'), findsOneWidget);
  });

  testWidgets('＋ 按步进（5 秒）上调间隔', (tester) async {
    double? updated;
    await pumpPanel(
      tester,
      interval: 20,
      onIntervalChanged: (v) => updated = v,
    );
    await tester.tap(find.byTooltip('加快翻页'));
    expect(updated, 25);
  });

  testWidgets('− 按步进下调间隔', (tester) async {
    double? updated;
    await pumpPanel(
      tester,
      interval: 20,
      onIntervalChanged: (v) => updated = v,
    );
    await tester.tap(find.byTooltip('减慢翻页'));
    expect(updated, 15);
  });

  testWidgets('间隔上限 120 秒封顶', (tester) async {
    double? updated;
    await pumpPanel(
      tester,
      interval: 118,
      onIntervalChanged: (v) => updated = v,
    );
    await tester.tap(find.byTooltip('加快翻页'));
    expect(updated, 120);
  });

  testWidgets('间隔下限 3 秒兜底', (tester) async {
    double? updated;
    await pumpPanel(
      tester,
      interval: 5,
      onIntervalChanged: (v) => updated = v,
    );
    await tester.tap(find.byTooltip('减慢翻页'));
    expect(updated, 3);
  });

  testWidgets('停止 / 目录 / 设置回调触发', (tester) async {
    var stopped = false;
    var catalog = false;
    var settings = false;
    await pumpPanel(
      tester,
      interval: 20,
      onIntervalChanged: (_) {},
      onStop: () => stopped = true,
      onCatalog: () => catalog = true,
      onSettings: () => settings = true,
    );
    await tester.tap(find.byTooltip('停止自动翻页'));
    await tester.tap(find.byTooltip('目录'));
    await tester.tap(find.byTooltip('阅读设置'));
    expect(stopped, isTrue);
    expect(catalog, isTrue);
    expect(settings, isTrue);
  });
}
