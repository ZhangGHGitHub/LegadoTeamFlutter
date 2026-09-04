// 全站转场回归守护（[UI-fix v2.0.167]，对齐参考仓 navigation3 NavDisplay
// 实际行为）：阅读器 600ms / 书籍详情 300ms / 其余 700ms 分档；
// 转场形态为「进页淡入 + 被覆盖页同步淡出」的 crossfade（FastOutSlowIn）。
// 历史教训：routes map 写法下 MaterialPageRoute 硬编码 300ms，P4 声称的
// 阅读 fade 600 从未生效——本测试防止分档再次静默失效。
// 注意：debugDefaultTargetPlatformOverride 必须在测试体内复位（binding
// 不变量校验先于 tearDown 执行），故统一 try/finally。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';

void main() {
  group('转场时长分档（仅 Android 生效）', () {
    test('Android：阅读器 600ms / 详情 300ms / 其余 700ms', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        expect(
          AppRoutes.tieredTransitionDurationFor(AppRoutes.reader),
          const Duration(milliseconds: 600),
        );
        expect(
          AppRoutes.tieredTransitionDurationFor(AppRoutes.readerComic),
          const Duration(milliseconds: 600),
        );
        expect(
          AppRoutes.tieredTransitionDurationFor(AppRoutes.bookInfo),
          const Duration(milliseconds: 300),
        );
        expect(
          AppRoutes.tieredTransitionDurationFor(AppRoutes.about),
          const Duration(milliseconds: 700),
        );
        // 未注册路由兜底回首页，仍走默认 700ms 档
        expect(
          AppRoutes.tieredTransitionDurationFor('/__unknown__'),
          const Duration(milliseconds: 700),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    test('非 Android（iOS/桌面）：返回 null 维持平台默认 300ms', () {
      for (final platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        try {
          expect(
            AppRoutes.tieredTransitionDurationFor(AppRoutes.reader),
            isNull,
            reason: '$platform 不参与分档，避免改变既有手感',
          );
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      }
    });
  });

  group('转场形态：进页淡入 + 底页同步淡出（crossfade）', () {
    /// 搭建双页场景并推入 B；返回底页 A 文本查找器供断言。
    Future<void> pumpTwoPages(WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: Center(child: Text('底页A'))),
        ),
      );
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Center(child: Text('进页B'))),
            ),
          );
      await tester.pump(); // 启动转场
      await tester.pump(const Duration(milliseconds: 150)); // 300ms 中点
    }

    Iterable<double> ancestorFadeValues(WidgetTester tester, Finder text) =>
        tester
            .widgetList<FadeTransition>(
              find.ancestor(of: text, matching: find.byType(FadeTransition)),
            )
            .map((f) => f.opacity.value);

    testWidgets('转场中点：进页在淡入（0,1）且底页在淡出（<1）', (tester) async {
      await pumpTwoPages(tester);
      try {
        expect(find.text('底页A'), findsOneWidget);
        expect(find.text('进页B'), findsOneWidget);

        // 底页 A：primary 保持 1.0，被覆盖 fade（1→0）正在播放
        final valuesA = ancestorFadeValues(tester, find.text('底页A'));
        expect(valuesA, isNotEmpty);
        expect(
          valuesA.any((v) => v < 1.0),
          isTrue,
          reason: '被覆盖页必须同步淡出（对齐 NavDisplay fadeOut togetherWith）',
        );

        // 进页 B：淡入中的 fade 必须严格在 (0,1) 区间
        final valuesB = ancestorFadeValues(tester, find.text('进页B'));
        expect(valuesB, isNotEmpty);
        expect(
          valuesB.any((v) => v > 0.0 && v < 1.0),
          isTrue,
          reason: '进页必须渐显（而非瞬显）',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('转场结束后：进页全显、底页淡出至不可见', (tester) async {
      await pumpTwoPages(tester);
      try {
        await tester.pump(const Duration(milliseconds: 300)); // 完成剩余时长

        final valuesA = ancestorFadeValues(tester, find.text('底页A'));
        expect(
          valuesA.every((v) => v == 0.0),
          isTrue,
          reason: '被覆盖页在覆盖期间应完全淡出（其余 700ms 档同理）',
        );
        final valuesB = ancestorFadeValues(tester, find.text('进页B'));
        expect(valuesB.every((v) => v == 1.0), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('pop 反转：顶页淡出、底页淡回', (tester) async {
      await pumpTwoPages(tester);
      try {
        await tester.pump(const Duration(milliseconds: 300)); // 完成 push
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
        await tester.pump(); // 启动 pop
        await tester.pump(const Duration(milliseconds: 150)); // 300ms 中点

        // 顶页 B 淡出中：存在 <1 的 fade 值
        final valuesB = ancestorFadeValues(tester, find.text('进页B'));
        expect(valuesB.any((v) => v < 1.0), isTrue);
        // 底页 A 淡回中：存在 (0,1) 的 fade 值（被覆盖 fade 1→0 反向播放）
        final valuesA = ancestorFadeValues(tester, find.text('底页A'));
        expect(valuesA.any((v) => v > 0.0 && v < 1.0), isTrue);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
