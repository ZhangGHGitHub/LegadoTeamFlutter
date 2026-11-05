// 详情页封面跟随封面设置测试（设置批6b-1）
//
// 覆盖：详情页封面阴影随「显示字体阴影」显示/隐藏（替换原硬编码
// elevation 8）；默认封面绘制书名（bookName 已传入详情页封面）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/cover_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/cover_settings/cover_settings_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/widgets/cover_text_painter.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    coverSettingsListenable.value = CoverSettings.defaults;
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  testWidgets('详情页封面阴影/描边跟随封面设置，默认封面绘制书名', (tester) async {
    final book = Book(
      bookUrl: 'https://src.com/book/cover',
      name: '封面设置书',
      author: '作者甲',
    );
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(any())).thenAnswer((_) async => const []);
    when(() => mockApi.getBooks()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(
      () => mockApi.sourceCallBackBtn(
        event: any(named: 'event'),
        bookUrl: any(named: 'bookUrl'),
        result: any(named: 'result'),
        bookType: any(named: 'bookType'),
      ),
    ).thenAnswer(
      (_) async => {'invoked': false, 'jsTrue': false, 'actions': <dynamic>[]},
    );

    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      showShadow: true,
    );

    await tester.pumpWidget(wrap(BookInfoScreen(book: book)));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bookCoverShadow')), findsOneWidget);
    expect(find.byKey(const ValueKey('bookCoverText')), findsOneWidget);
    final paint = tester.widget<CustomPaint>(
      find.byKey(const ValueKey('bookCoverText')),
    );
    final layout = (paint.painter! as CoverTextPainter).layout;
    expect(layout.nameGlyphs.map((g) => g.text).join(), '封面设置书');
    expect(layout.authorGlyphs.map((g) => g.text).join(), '作者甲');

    // 关闭阴影后详情页即时跟随（BookCover 监听全局设置）
    coverSettingsListenable.value = CoverSettings.defaults.copyWith(
      showShadow: false,
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('bookCoverShadow')), findsNothing);
  });
}
