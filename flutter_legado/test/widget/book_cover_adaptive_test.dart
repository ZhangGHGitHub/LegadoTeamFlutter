// 封面比例开关 widget 测试（批39）
//
// 覆盖：
// - 「限制封面比例」开启（默认）时保持固定高度（既有视觉不变）；
// - 关闭后按已解析原图比例换算高度（0.5 → 宽 × 2），并受上下限约束；
// - 设置切换即时生效（uiSettingsListenable 广播）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/cover_aspect_ratio.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const url = 'http://cover.test/book.jpg';

  setUp(() {
    CoverAspectRatio.clear();
    uiSettingsListenable.value = const UiSettingsState();
    SharedPreferences.setMockInitialValues({});
    // 预置已解析比例（宽/高 = 0.5 → 高度 = 宽 × 2）
    CoverAspectRatio.remember(url, 0.5);
  });

  Widget host({double width = 70, double height = 100}) => ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(MockRustApi())],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: BookCover(
                coverUrl: url,
                width: width,
                height: height,
                adaptAspectRatio: true,
                adaptiveMinHeight: 50,
                adaptiveMaxHeight: 200,
              ),
            ),
          ),
        ),
      );

  testWidgets('限制比例开启（默认）：固定高度', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();

    expect(tester.getSize(find.byType(BookCover)).height, 100);
  });

  testWidgets('关闭后按原图比例自适应，切换设置即时生效', (tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    expect(tester.getSize(find.byType(BookCover)).height, 100);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BookCover)),
    );
    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(false);
    await tester.pumpAndSettle();

    // 宽 70 / 0.5 = 140（在 50..200 内）
    expect(
      tester.getSize(find.byType(BookCover)).height,
      closeTo(140, 0.01),
    );

    // 再开启恢复固定高度
    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(true);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(BookCover)).height, 100);
  });

  testWidgets('自适应高度受上下限约束（横版封面）', (tester) async {
    CoverAspectRatio.remember(url, 2.0); // 横版 → 收敛到 1.5
    await tester.pumpWidget(host());
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(BookCover)),
    );
    await container.read(uiSettingsProvider.notifier).setRestrictCoverRatio(false);
    await tester.pumpAndSettle();

    // 宽 70 / 1.5 = 46.7 → 下限 50
    expect(
      tester.getSize(find.byType(BookCover)).height,
      closeTo(50, 0.01),
    );
  });
}
