// 发现网格封面比例联动测试（批39）
//
// 覆盖：关闭「限制封面比例」后，发现网格行高按首个已解析的原图比例调整
// （限制比例开启时保持既有 3:4 基准），并随设置切换即时重算。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/explore/explore_show_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/ui_settings/ui_settings_notifier.dart';
import 'package:flutter_legado/src/services/cover_aspect_ratio.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';
import 'package:flutter_legado/src/widgets/explore_book_list.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRustApi mockApi;

  const testSource = BookSource(
    bookSourceUrl: 'http://source.com',
    bookSourceName: '测试书源',
  );
  const args = ExploreShowArgs(
    source: testSource,
    categoryName: '推荐榜',
    categoryUrl: 'http://source.com/rank',
  );

  setUpAll(registerFallbacks);

  setUp(() {
    CoverAspectRatio.clear();
    uiSettingsListenable.value = const UiSettingsState();
    addTearDown(() => uiSettingsListenable.value = const UiSettingsState());
    mockApi = MockRustApi();
    // 首本书预置原图比例 0.5（宽/高）：网格按该比例算行高
    CoverAspectRatio.remember('http://book.com/1', 0.5);
    when(() => mockApi.exploreFetchBooks(any(), any(), any())).thenAnswer(
      (_) async => [
        const SearchBook(
          bookUrl: 'http://book.com/1',
          name: '书1',
          author: '作者1',
          coverUrl: 'http://book.com/1',
        ),
        const SearchBook(
          bookUrl: 'http://book.com/2',
          name: '书2',
          author: '作者2',
          coverUrl: 'http://book.com/2',
        ),
      ],
    );
  });

  Widget host() => ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(
          home: Scaffold(
            body: ExploreBookList(args: args, gridCount: 2),
          ),
        ),
      );

  testWidgets('限制比例开启：网格封面保持既有 3:4 行高', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final coverHeight = tester.getSize(find.byType(BookCover).first).height;
    // 两列 + 左右 16 边距 + 8 列距 → itemW = (800-32-8)/2 = 380
    // 限制比例：单元格 = itemW × 4/3 + 文本区；封面色块 ≈ 506.67
    // （文本区约 37dp 在单元格下方，故允许 ±15 容差）
    expect(coverHeight, closeTo(380 * 4 / 3, 15.0));
  });

  testWidgets('关闭限制比例：网格行高按原图比例（0.5）放大', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final restrictedHeight =
        tester.getSize(find.byType(BookCover).first).height;

    // 关闭限制比例（设置广播到 ExploreBookList 监听 → 重算行高）
    uiSettingsListenable.value =
        const UiSettingsState(restrictCoverRatio: false);
    await tester.pumpAndSettle();

    final adaptiveHeight =
        tester.getSize(find.byType(BookCover).first).height;
    // 行高差值 = itemW/0.5 - itemW/(3/4) = 760 - 506.67 = 253.33
    // （文本区不变，差值即单元格封面色块增量）
    expect(adaptiveHeight - restrictedHeight, closeTo(380 / 0.5 - 380 * 4 / 3, 1.0));
    expect(adaptiveHeight, greaterThan(restrictedHeight));
  });
}
