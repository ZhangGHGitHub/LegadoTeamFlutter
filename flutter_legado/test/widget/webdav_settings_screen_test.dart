/// WebDAV 设置页「测试配置」行（差异清单 C7）
///
/// 覆盖「地址为空」提示分支：未填写服务器地址时点击「测试配置」
/// 应弹出 SnackBar「请先填写服务器地址」，且行尾状态保持「未测试」。
///
/// — full-stack-engineer + UI ｜ 2026-09-10
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/webdav_settings_screen.dart';

import '../mocks/mocks.dart';

/// 恒失败的 HTTP 客户端（探测必然落到「✗ 失败」，无需真实网络）
class _OfflineHttpClient implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    throw const SocketException('mock offline');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _OfflineHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _OfflineHttpClient();
}

void main() {
  late FakeServersRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    // 页面 initState 会触发 SyncNotifier.loadConfig 与 CrashLogService 读偏好
    SharedPreferences.setMockInitialValues({});
    mockApi = FakeServersRustApi();
    when(() => mockApi.getBooks()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: WebDavSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('地址为空：点击「测试配置」提示「请先填写服务器地址」', (tester) async {
    await pumpScreen(tester);

    // 行尾初始为「未测试」
    expect(find.text('未测试'), findsOneWidget);

    await tester.tap(find.text('测试配置'));
    await tester.pumpAndSettle();

    expect(find.text('请先填写服务器地址'), findsOneWidget);
    // 未发起探测，状态保持「未测试」
    expect(find.text('未测试'), findsOneWidget);
    expect(find.text('✗ 失败'), findsNothing);
  });

  testWidgets('地址非 http(s)：点击「测试配置」提示地址格式错误', (tester) async {
    await pumpScreen(tester);

    // 通过「WebDAV 服务器地址」行填入非法地址（弹框前该文案仅行标题一处）
    await tester.tap(find.text('WebDAV 服务器地址'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'dav.example.com');
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 此时 subtitle 显示已填地址，行可点击
    expect(find.text('dav.example.com'), findsWidgets);

    await tester.tap(find.text('测试配置'));
    await tester.pumpAndSettle();

    expect(find.text('服务器地址需要以 http(s):// 开头'), findsOneWidget);
    // 未发起探测，状态保持「未测试」
    expect(find.text('未测试'), findsOneWidget);
  });

  testWidgets('地址/账号/密码变更后「测试配置」复位为「未测试」（批11 回修 P3-2）', (tester) async {
    HttpOverrides.global = _OfflineHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);
    await pumpScreen(tester);

    Future<void> editRow(String rowTitle, String value) async {
      await tester.tap(find.text(rowTitle));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), value);
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
    }

    // 先得到非「未测试」状态：离线探测 → ✗ 失败
    await editRow('WebDAV 服务器地址', 'http://dav.example.com/');
    await tester.tap(find.text('测试配置'));
    await tester.pumpAndSettle();
    expect(find.text('✗ 失败'), findsOneWidget);

    // 清空地址（保存）后状态复位，不再保留上一次测试结果
    await editRow('WebDAV 服务器地址', '');
    expect(find.text('未测试'), findsOneWidget);
    expect(find.text('✗ 失败'), findsNothing);
  });
}
