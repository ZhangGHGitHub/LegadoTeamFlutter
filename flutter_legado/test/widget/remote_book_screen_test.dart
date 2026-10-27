/// 远程书库服务器 Sheet Widget 测试（批18a：servers 表数据源）
///
/// 钉住：
/// - Sheet 从 mock DB 渲染，默认行唯一，`id=-1` 不在自定义列表重复出现；
/// - 无效行标记「配置无效」；
/// - 添加/编辑/删除走 servers 表；
/// - 保存失败在 Sheet 内联提示（旧实现的 SnackBar 会被贴底 Sheet 遮挡）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/book.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/remote_book_screen.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(registerFallbacks);

  late FakeServersRustApi mockApi;

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'sync_webdav_url': 'https://dav.example.com/',
      'sync_webdav_username': 'u',
      'sync_webdav_password': 'p',
      'sync_webdav_remote_dir': '/legado/',
      'remote_server_id': -1,
    });
    mockApi = FakeServersRustApi();
    when(() => mockApi.webdavListDir(any(), any()))
        .thenAnswer((_) async => jsonEncode([]));
    when(() => mockApi.getBooks()).thenAnswer((_) async => <Book>[]);
  });

  String configJson({
    String url = 'https://dav.example.com/',
    String username = 'u',
    String password = 'p',
  }) =>
      jsonEncode({'url': url, 'username': username, 'password': password});

  Future<void> pumpScreen(WidgetTester tester, {MockRustApi? api}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api ?? mockApi)],
        child: const MaterialApp(home: RemoteBookScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openServersSheet(WidgetTester tester) async {
    await tester.tap(find.byIcon(Symbols.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('服务器配置').last);
    await tester.pumpAndSettle();
  }

  Future<void> fillServerDialog(
    WidgetTester tester, {
    required String name,
    required String url,
  }) async {
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), name);
    await tester.enterText(fields.at(1), url);
  }

  testWidgets('Sheet 从 DB 渲染，默认行唯一，无效行标记', (tester) async {
    mockApi.seedServer(id: -1, name: '默认 WebDAV', config: configJson());
    mockApi.seedServer(
      id: 1,
      name: '我的网盘',
      config: configJson(url: 'https://dav1.example.com/'),
    );
    mockApi.seedServer(id: 2, name: '坏配置', config: 'not-json');

    await pumpScreen(tester);
    await openServersSheet(tester);

    expect(find.text('我的网盘'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);
    expect(find.text('使用备份设置中的 WebDAV（books/）'), findsOneWidget);
    expect(find.text('配置无效（请编辑修复）'), findsOneWidget);
    // 默认行（RadioListTile）+ 两个自定义行；id=-1 不重复出现
    expect(find.byType(RadioListTile<int>), findsNWidgets(3));
    expect(find.text('默认 WebDAV'), findsNothing);
  });

  testWidgets('添加服务器走 servers 表并刷新 Sheet', (tester) async {
    await pumpScreen(tester);
    await openServersSheet(tester);

    await tester.tap(find.byIcon(Symbols.add_rounded));
    await tester.pumpAndSettle();
    await fillServerDialog(
      tester,
      name: '新服务器',
      url: 'https://new.example.com/',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('新服务器'), findsOneWidget);
    final saved = mockApi.servers.singleWhere(
      (e) => e['name'] == '新服务器',
    );
    expect(saved['type'], 'WEBDAV');
    final config = jsonDecode(saved['config'] as String);
    expect(config['url'], 'https://new.example.com/');
  });

  testWidgets('编辑服务器保留主键并更新名称', (tester) async {
    mockApi.seedServer(id: 7, name: '旧名', config: configJson());
    await pumpScreen(tester);
    await openServersSheet(tester);

    await tester.tap(find.byIcon(Symbols.edit_rounded));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '改名');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    expect(find.text('改名'), findsOneWidget);
    expect(find.text('旧名'), findsNothing);
    final row = mockApi.servers.singleWhere((e) => e['id'] == 7);
    expect(row['name'], '改名');
  });

  testWidgets('删除服务器走 servers 表', (tester) async {
    mockApi.seedServer(id: 8, name: '待删网盘', config: configJson());
    await pumpScreen(tester);
    await openServersSheet(tester);

    await tester.tap(find.byIcon(Symbols.delete_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('待删网盘'), findsNothing);
    expect(
      mockApi.servers.any((e) => (e['id'] as num?)?.toInt() == 8),
      isFalse,
      reason: '目标行已删除（id=-1 默认行由同步迁移写入，不受影响）',
    );
  });

  testWidgets('空 URL 保存：对话框内联提示且不调用保存（批18c P2）', (tester) async {
    final api = MockRustApi();
    when(() => api.webdavServersList()).thenAnswer((_) async => '[]');
    when(() => api.webdavListDir(any(), any()))
        .thenAnswer((_) async => jsonEncode([]));
    when(() => api.getBooks()).thenAnswer((_) async => <Book>[]);

    await pumpScreen(tester, api: api);
    await openServersSheet(tester);

    await tester.tap(find.byIcon(Symbols.add_rounded));
    await tester.pumpAndSettle();
    // 只填名称，URL 留空
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '无地址服务器');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // 旧实现 `if (url.isEmpty) return;`：对话框无提示、静默不保存。
    // 新实现必须在对话框内显示「名称和地址不能为空」并保持打开。
    expect(find.byType(AlertDialog), findsOneWidget, reason: '校验失败应留在对话框');
    expect(find.text('名称和地址不能为空'), findsOneWidget);
    // 启动期同步配置迁移会写默认服务器（id=-1），因此只断言「本次输入的
    // 服务器没有被保存」——校验失败不得触发 save。
    verifyNever(
      () => api.webdavServerSave(any(that: contains('无地址服务器'))),
    );
  });

  testWidgets('保存失败在 Sheet 内联提示（不被贴底 Sheet 遮挡）', (tester) async {
    final failing = MockRustApi();
    when(() => failing.webdavServersList()).thenAnswer((_) async => '[]');
    when(() => failing.webdavServerSave(any()))
        .thenThrow(StateError('写入失败'));
    when(() => failing.webdavListDir(any(), any()))
        .thenAnswer((_) async => jsonEncode([]));
    when(() => failing.getBooks()).thenAnswer((_) async => <Book>[]);

    await pumpScreen(tester, api: failing);
    await openServersSheet(tester);

    await tester.tap(find.byIcon(Symbols.add_rounded));
    await tester.pumpAndSettle();
    await fillServerDialog(
      tester,
      name: '失败服务器',
      url: 'https://fail.example.com/',
    );
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();

    // 旧实现走 ScaffoldMessenger SnackBar：Sheet 仍开着且贴底，提示被遮挡。
    // 新实现必须在 Sheet 内、列表上方以内联错误行展示（红→绿断言）。
    expect(find.byType(SnackBar), findsNothing,
        reason: '不得再用会被 Sheet 遮挡的 SnackBar');
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.textContaining('写入失败'),
      ),
      findsOneWidget,
      reason: '错误文本必须在 Sheet 内可见',
    );
  });
}
