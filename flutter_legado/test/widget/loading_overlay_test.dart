import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/loading_overlay.dart';
import 'package:flutter_legado/src/widgets/md3_loading_indicator.dart';

void main() {
  Widget buildTestWidget({
    bool isLoading = false,
    String? message,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LoadingOverlay(
          isLoading: isLoading,
          message: message,
          child: const Center(child: Text('内容区域')),
        ),
      ),
    );
  }

  testWidgets('LoadingOverlay renders child widget', (tester) async {
    await tester.pumpWidget(buildTestWidget(isLoading: false));

    expect(find.text('内容区域'), findsOneWidget);
    expect(find.byType(LoadingOverlay), findsOneWidget);
  });

  testWidgets('LoadingOverlay shows indicator when isLoading', (tester) async {
    await tester.pumpWidget(buildTestWidget(isLoading: true));

    // [MD3 Expressive] 加载指示器升级为波浪环
    expect(find.byType(Md3LoadingIndicator), findsOneWidget);
  });

  testWidgets('LoadingOverlay hides indicator when not loading',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(isLoading: false));

    expect(find.byType(Md3LoadingIndicator), findsNothing);
  });

  testWidgets('LoadingOverlay shows message when provided', (tester) async {
    await tester.pumpWidget(buildTestWidget(
      isLoading: true,
      message: '加载中...',
    ));

    expect(find.text('加载中...'), findsOneWidget);
  });

  testWidgets('LoadingOverlay hides message when not provided',
      (tester) async {
    await tester.pumpWidget(buildTestWidget(isLoading: true));

    expect(find.text('加载中...'), findsNothing);
  });
}
