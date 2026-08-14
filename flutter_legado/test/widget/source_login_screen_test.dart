// SourceLoginScreen widget 测试
//
// 回归：全局 TabBarTheme.tabAlignment=start 对非 scrollable TabBar 断言失败
// 红屏（"TabAlignment.start is only valid for scrollable tab bars"）。
// 登录页 TabBar 须显式 tabAlignment: fill（2026-08-14 登录红屏修复）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/source_login_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getLoginInfo(any())).thenAnswer((_) async => '');
    when(() => mockApi.getLoginHeader(any())).thenAnswer((_) async => '');
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);
  });

  testWidgets('登录页 TabBar 渲染无断言红屏（tabAlignment.fill）', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(
          home: SourceLoginScreen(
            sourceUrl: 'https://a.com',
            sourceName: '测试源',
            loginUrl: 'https://a.com/login',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // TabBar 两页签 + 手动输入表单正常渲染，无异常
    expect(find.text('登录 - 测试源'), findsOneWidget);
    expect(find.text('手动输入'), findsOneWidget);
    expect(find.text('登录链接'), findsOneWidget);
    expect(find.text('保存登录信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
