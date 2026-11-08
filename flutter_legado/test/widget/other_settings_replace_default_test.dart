// 批7a 闭环 widget 测试：其他设置页「默认启用替换净化」开关
//
// 缺陷背景：该开关此前只写 SharedPreferences，Rust 阅读链读 caches
// `config:replaceEnableDefault` 恒缺省 true，总开关对阅读净化无效。
// 本用例从真实页面点击开关，断言 prefs 与 config 同时更新（不是只断言
// prefs）：MockBookApi 的 config 内存表可经 getConfig 回读。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/other_settings_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

void main() {
  late MockBookApi api;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: OtherSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('切换「默认启用替换净化」同时写 prefs 与 Rust config', (tester) async {
    await pumpScreen(tester);

    final row = find.widgetWithText(SettingSwitchRow, '默认启用替换净化');
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final switchFinder = find.descendant(of: row, matching: find.byType(Switch));
    expect(
      tester.widget<Switch>(switchFinder).value,
      isTrue,
      reason: '未设置偏好时默认 true',
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(PrefKeys.replaceEnableDefault),
      isNull,
      reason: '前置：尚无偏好写入',
    );

    // 关闭：prefs=false，config="false"
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isFalse);
    expect(prefs.getBool(PrefKeys.replaceEnableDefault), isFalse);
    expect(
      await api.getConfig(PrefKeys.replaceEnableDefault),
      'false',
      reason: '关闭时必须同步 Rust config，否则阅读链仍读缺省 true',
    );

    // 再开启：prefs=true，config="true"
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchFinder).value, isTrue);
    expect(prefs.getBool(PrefKeys.replaceEnableDefault), isTrue);
    expect(await api.getConfig(PrefKeys.replaceEnableDefault), 'true');
  });
}
