// 经典 loginUi 表单登录对话框 widget 测试
//
// 对齐 Kotlin SourceLoginDialog（书山聚合等经典 JSON 行协议书源）：
// - 渲染 text/password 输入、button 动作按钮（basisPercent 网格）
// - 预填已保存登录信息（getLoginInfo）
// - 按钮动作经 exploreEvalAction 执行（脚本 = result 绑定表单 JSON +
//   loginUrl JS + action）
// - ✓ 保存登录信息（putLoginInfo）并执行 login.apply(this)
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/widgets/classic_login_dialog.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getLoginInfo(any())).thenAnswer((_) async => '');
    when(() => mockApi.getLoginHeader(any())).thenAnswer((_) async => '');
    when(() => mockApi.putLoginInfo(any(), any())).thenAnswer((_) async {});
    when(() => mockApi.putLoginHeader(any(), any())).thenAnswer((_) async {});
    when(
      () => mockApi.exploreEvalAction(
        sourceJson: any(named: 'sourceJson'),
        actionJs: any(named: 'actionJs'),
      ),
    ).thenAnswer((_) async => {'raw': '', 'actions': <dynamic>[], 'refreshExplore': false});
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  BookSource source({
    String loginUi = '''
[
  {"name":"邮箱","type":"text"},
  {"name":"密码","type":"password"},
  {"name":"⭕账号登录","type":"button","action":"login()","style":{"layout_flexBasisPercent":0.4}},
  {"name":"🔑注册书源","type":"button","action":"key()","style":{"layout_flexBasisPercent":0.4}},
  {"name":"↓   设置   ↓","type":"button","action":"","style":{"layout_flexBasisPercent":1}}
]
''',
    String loginUrl = 'function login(){ java.toast("正在登录..."); }',
  }) {
    return BookSource(
      bookSourceUrl: '书山聚合',
      bookSourceName: '书山聚合测试',
      loginUi: loginUi,
      loginUrl: loginUrl,
    );
  }

  Future<void> pumpDialog(
    WidgetTester tester,
    BookSource source, {
    Future<bool> Function()? push,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) => ClassicLoginDialog(
                      api: container.read(bookApiProvider),
                      source: source,
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染输入框与按钮网格', (tester) async {
    await pumpDialog(tester, source());

    expect(find.text('登录 - 书山聚合测试'), findsOneWidget);
    expect(find.text('邮箱'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('⭕账号登录'), findsOneWidget);
    expect(find.text('🔑注册书源'), findsOneWidget);
    // 整行按钮（basisPercent=1）也应渲染
    expect(find.text('↓   设置   ↓'), findsOneWidget);
  });

  testWidgets('按钮动作经 exploreEvalAction 执行并绑定表单 result', (tester) async {
    await pumpDialog(tester, source());

    // 填入表单
    await tester.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await tester.enterText(find.widgetWithText(TextField, '密码'), 'secret');
    await tester.tap(find.text('⭕账号登录'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.exploreEvalAction(
        sourceJson: any(named: 'sourceJson'),
        actionJs: captureAny(named: 'actionJs'),
      ),
    ).captured.single as String;
    // result 绑定表单 JSON（对象字面量）+ loginUrl JS + action
    expect(captured, contains('globalThis.result ='));
    expect(captured, contains('"邮箱":"a@b.com"'));
    expect(captured, contains('"密码":"secret"'));
    expect(captured, contains('function login()'));
    expect(captured.trimRight().endsWith('login()'), isTrue);
  });

  testWidgets('✓ 保存登录信息并执行 login.apply(this)', (tester) async {
    await pumpDialog(tester, source());

    await tester.enterText(find.widgetWithText(TextField, '邮箱'), 'a@b.com');
    await tester.tap(find.byTooltip('确认登录'));
    await tester.pumpAndSettle();

    // putLoginInfo 已保存表单 JSON
    final info = verify(
      () => mockApi.putLoginInfo(any(), captureAny()),
    ).captured.last as String;
    expect(info, contains('"邮箱":"a@b.com"'));

    // login.apply(this) 脚本已执行
    final captured = verify(
      () => mockApi.exploreEvalAction(
        sourceJson: any(named: 'sourceJson'),
        actionJs: captureAny(named: 'actionJs'),
      ),
    ).captured.single as String;
    expect(captured, contains("typeof login=='function'"));
    expect(captured, contains('login.apply(this)'));
  });
}
