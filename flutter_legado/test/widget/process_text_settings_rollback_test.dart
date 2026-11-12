// 「文字操作显示搜索」设置页开关回滚 widget 测试
//
// 缺陷背景：该开关此前只写 SharedPreferences，无任何消费方（死开关）。
// 接线后开关经 `legado/process_text` 通道启停 Android activity-alias；
// 原生未回传明确结果（null）或抛错时必须回滚 UI + 偏好，不能出现
// 「偏好已改但系统菜单没变」的假生效。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  const channel = MethodChannel('legado/process_text');
  late MockBookApi api;
  late List<MethodCall> calls;

  TestDefaultBinaryMessenger messenger() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockBookApi();
    calls = <MethodCall>[];
    // Android 默认可用；setEnabled 返回 null 模拟原生未确认（回滚路径）
    messenger().setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'isEnabled':
          return true;
        case 'setEnabled':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger().setMockMethodCallHandler(channel, null);
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

  Future<void> revealRow(WidgetTester tester, Finder row) async {
    await tester.scrollUntilVisible(
      row,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('原生 setEnabled 返回 null → 开关与偏好回滚并提示', (tester) async {
    await pumpScreen(tester);

    final row = find.widgetWithText(SettingSwitchRow, '文字操作显示搜索');
    await revealRow(tester, row);
    final switchFinder = find.descendant(
      of: row,
      matching: find.byType(Switch),
    );
    expect(
      tester.widget<Switch>(switchFinder).value,
      isTrue,
      reason: '原生组件默认启用 → 开关为开',
    );
    expect(
      calls.map((c) => c.method),
      containsAllInOrder(['isEnabled', 'isEnabled']),
      reason: '进页面先探测可用性，再以组件实态回写偏好',
    );

    await tester.tap(switchFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      tester.widget<Switch>(switchFinder).value,
      isTrue,
      reason: '原生未确认 → UI 必须回滚，不能假生效',
    );
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(PrefKeys.processText),
      isTrue,
      reason: '偏好也必须回滚（与原生组件状态一致）',
    );
    expect(find.text('系统限制，文字操作菜单设置未生效'), findsOneWidget);
    expect(calls.where((c) => c.method == 'setEnabled').single.arguments, {
      'enabled': false,
    });
  });
}
