// [批4d] 阅读器「更多」页滑动书签/角标/振动行测试
//
// 覆盖：三行渲染、开关落盘、角标大小滑块夹逼与提交、恢复默认角标图、
// 振动两行开关。
//
// 编写：全栈工程师（批4d） ｜ 2026-11-04
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_config_panel.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

Future<void> _pumpMore(
  WidgetTester tester, {
  ReaderAdvancedConfig? config,
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(MockBookApi())],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReaderConfigPanel(
              config: config ?? ReaderAdvancedConfig(),
              section: ReaderConfigSection.more,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('「更多」页渲染滑动书签三行与振动两行', (tester) async {
    await _pumpMore(tester);

    expect(
      find.byKey(const ValueKey('reader-swipe-bookmark-switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-bookmark-badge-size')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-bookmark-badge-image')),
      findsOneWidget,
    );
    expect(find.text('下滑添加书签'), findsOneWidget);
    expect(find.text('角标大小'), findsOneWidget);
    expect(find.text('书签角标'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('reader-slider-vibrator-switch')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('reader-select-vibrator-switch')),
      findsOneWidget,
    );
    expect(find.text('滑动进度条时震动'), findsOneWidget);
    expect(find.text('选择文本时震动'), findsOneWidget);
  });

  testWidgets('下滑书签开关 → 落盘并推送配置', (tester) async {
    await _pumpMore(tester);

    await tester.tap(
      find.byKey(const ValueKey('reader-swipe-bookmark-switch')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.swipeToAddBookmark), isTrue);
  });

  testWidgets('角标大小滑块 → 松手提交并夹逼到 0..50', (tester) async {
    await _pumpMore(tester);

    final slider = find.byKey(
      const ValueKey('reader-bookmark-badge-size-slider'),
    );
    expect(slider, findsOneWidget);
    final size = tester.getSize(slider);
    await tester.drag(slider, Offset(size.width / 2 + 40, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.bookmarkBadgeSize), 50, reason: '拖到最右为上限 50');
    expect(find.text('50 dp'), findsWidgets);
  });

  testWidgets('自定义角标图存在时可恢复默认', (tester) async {
    final image = 'bookmark_badges/${'a'.padRight(32, 'a')}.png';
    await _pumpMore(
      tester,
      config: ReaderAdvancedConfig()..bookmarkBadgeImage = image,
    );

    expect(find.text('自定义图片'), findsOneWidget);
    final reset = find.byKey(const ValueKey('reader-bookmark-badge-reset'));
    expect(reset, findsOneWidget);

    await tester.tap(reset);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PrefKeys.bookmarkBadgeImage), '');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('reader-bookmark-badge-image')),
        matching: find.text('默认'),
      ),
      findsOneWidget,
    );
  });
}
