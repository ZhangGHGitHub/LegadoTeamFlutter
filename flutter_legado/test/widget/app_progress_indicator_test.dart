import 'package:flutter/material.dart';
import 'package:flutter_legado/src/widgets/app_progress_indicator.dart';
import 'package:flutter_legado/src/widgets/contained_loading_indicator.dart';
import 'package:flutter_test/flutter_test.dart';

/// [STAGE-UI-P43UNIFY2 B3] 统一封装三件套 widget 测试
///
/// 覆盖：默认参数（4dp 线宽 / 主题槽 primary）、确定性 progress 模式、
/// 显式色/线宽覆盖、linear 透传（minHeight）、contained 委托。
void main() {
  Future<void> pumpCircular(
    WidgetTester tester, {
    double? progress,
    double strokeWidth = 4.0,
    Color? color,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: AppCircularProgressIndicator(
              progress: progress,
              strokeWidth: strokeWidth,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  group('AppCircularProgressIndicator', () {
    testWidgets('默认参数：4dp 线宽 + 色走主题槽（color 透传 null）',
        (tester) async {
      await pumpCircular(tester);
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.strokeWidth, 4.0);
      expect(indicator.color, isNull,
          reason: '默认色 = 组件默认主题槽 colorScheme.primary'
              '（color 透传 null，保留「null 即主题槽」取证口径）');
      expect(indicator.value, isNull, reason: '不传 progress = indeterminate');
    });

    testWidgets('显式 color 覆盖主题槽', (tester) async {
      await pumpCircular(tester, color: const Color(0xFF123456));
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.color, const Color(0xFF123456));
    });

    testWidgets('strokeWidth: 2 细环实参透传（B4 线宽口径保留项）',
        (tester) async {
      await pumpCircular(tester, strokeWidth: 2);
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.strokeWidth, 2.0);
    });

    testWidgets('progress 确定性模式：value 透传 0~1 区间', (tester) async {
      await pumpCircular(tester, progress: 0.42);
      final indicator = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(indicator.value, 0.42,
          reason: '确定性模式 value 透传（SDK 环 value 即 0~1 比例）');
    });

    testWidgets('语义标签默认「加载中」', (tester) async {
      await pumpCircular(tester);
      expect(
        find.bySemanticsLabel('加载中'),
        findsOneWidget,
        reason: '默认 semanticsLabel 暴露到无障碍树',
      );
    });
  });

  group('AppLinearProgressIndicator', () {
    Future<void> pumpLinear(
      WidgetTester tester, {
      double? progress,
      double? minHeight,
      Color? color,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppLinearProgressIndicator(
                progress: progress,
                minHeight: minHeight,
                color: color,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('indeterminate：色走主题槽（color 透传 null）', (tester) async {
      await pumpLinear(tester);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, isNull, reason: '不传 progress = indeterminate');
      expect(indicator.color, isNull,
          reason: '默认色 = 组件默认主题槽 colorScheme.primary');
    });

    testWidgets('progress 确定性模式：value 透传 0~1 区间', (tester) async {
      await pumpLinear(tester, progress: 0.6);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.value, 0.6,
          reason: '确定性模式 value 透传（SDK 线 value 即 0~1 比例）');
    });

    testWidgets('minHeight 实参透传（换接点保留视觉）', (tester) async {
      await pumpLinear(tester, minHeight: 2);
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.minHeight, 2.0);
    });

    testWidgets('显式 color 覆盖主题槽', (tester) async {
      await pumpLinear(tester, color: const Color(0xFFABCDEF));
      final indicator = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(indicator.color, const Color(0xFFABCDEF));
    });
  });

  group('AppContainedLoadingIndicator', () {
    testWidgets('委托既有 ContainedLoadingIndicator（签名对齐出口）',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppContainedLoadingIndicator(size: 32, strokeWidth: 2.5),
            ),
          ),
        ),
      );
      expect(
        find.byType(ContainedLoadingIndicator),
        findsOneWidget,
        reason: 'MD3 实现委托既有组件（勿误改项），三件套命名对齐',
      );
      final contained = tester.widget<ContainedLoadingIndicator>(
        find.byType(ContainedLoadingIndicator),
      );
      expect(contained.size, 32);
      expect(contained.strokeWidth, 2.5);
      // 内置环存在
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });
}
