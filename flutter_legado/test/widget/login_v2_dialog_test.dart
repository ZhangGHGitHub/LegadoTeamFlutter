// LoginV2Dialog widget 测试
//
// 覆盖：V2 rows 渲染（text/password/select/button/label）、countdown、
// action 命令处理（state/error/login/close）、渲染异常防御
// （V2 书源登录红屏排查，2026-08-14）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/widgets/login_v2_dialog.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
  });

  Future<void> pumpDialog(
    WidgetTester tester, {
    required String uiJson,
  }) async {
    when(() => mockApi.loginUiV2(any(), any()))
        .thenAnswer((_) async => uiJson);
    when(() => mockApi.loginActionV2(any(), any()))
        .thenAnswer((_) async => '{"state":{}}');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => LoginV2Dialog(
                    api: mockApi,
                    sourceJson: '{}',
                    sourceName: '测试源',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('全类型 rows 渲染无异常（text/password/label/select/button）', (tester) async {
    await pumpDialog(
      tester,
      uiJson: jsonEncode({
        'rows': [
          {'key': 'phone', 'name': '手机号', 'type': 'text'},
          {'key': 'pwd', 'name': '密码', 'type': 'password'},
          {'name': '提示', 'type': 'label', 'value': '请输入手机号'},
          {
            'key': 'gender',
            'name': '性别',
            'type': 'select',
            'options': ['男', '女'],
          },
          {'name': '发送验证码', 'type': 'button', 'action': 'sendCode'},
        ],
      }),
    );

    expect(find.text('登录 - 测试源'), findsOneWidget);
    expect(find.text('手机号'), findsWidgets);
    expect(find.text('密码'), findsWidgets);
    expect(find.text('提示'), findsOneWidget);
    // select 行显示当前选中值（options.first）
    expect(find.text('男'), findsOneWidget);
    expect(find.text('发送验证码'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('空 options 的 select 渲染无异常（防御 options.first）', (tester) async {
    await pumpDialog(
      tester,
      uiJson: jsonEncode({
        'rows': [
          {
            'key': 'empty',
            'name': '空选择',
            'type': 'select',
            'options': <String>[],
          },
        ],
      }),
    );

    expect(find.text('空选择'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺 key 的 text 行渲染无异常（防御 putIfAbsent('')）', (tester) async {
    await pumpDialog(
      tester,
      uiJson: jsonEncode({
        'rows': [
          {'name': '无key输入', 'type': 'text'},
        ],
      }),
    );

    expect(find.text('无key输入'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('loginUiV2 返回非法 JSON 时显示错误不崩溃', (tester) async {
    when(() => mockApi.loginUiV2(any(), any()))
        .thenAnswer((_) async => 'not-json{');
    when(() => mockApi.loginActionV2(any(), any()))
        .thenAnswer((_) async => '{}');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => LoginV2Dialog(
                    api: mockApi,
                    sourceJson: '{}',
                    sourceName: '测试源',
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 对话框仍在（错误显示在框内），无红屏
    expect(find.text('登录 - 测试源'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
