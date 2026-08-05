// 复现回归：网络导入书源 _dependents.isEmpty 断言
//
// 根因：URL 导入对话框在关闭回调中提前 dispose TextEditingController，
// 退场动画中的 TextField 仍挂载着它，触发 "used after disposed" 及
// InheritedElement.debugDeactivated 的 _dependents.isEmpty 断言级联。
// 修复：controller 由对话框内容组件自持，随子树卸载统一释放。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/source_import_confirm_screen.dart';
import 'package:flutter_legado/src/screens/source_screen.dart';
import 'package:flutter_legado/src/services/source_import_service.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  final sources = [
    const BookSource(
      bookSourceUrl: 'https://a.com',
      bookSourceName: '书源A',
    ),
  ];

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getBookSources()).thenAnswer((_) async => sources);
  });

  Widget wrapSourceScreen() {
    return ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
      child: const MaterialApp(home: SourceScreen()),
    );
  }

  final dialogField = find.descendant(
      of: find.byType(AlertDialog), matching: find.byType(TextField));

  testWidgets('URL 导入：请求失败弹 SnackBar 不崩溃', (tester) async {
    await tester.pumpWidget(wrapSourceScreen());
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: find.byType(AppBar),
      matching: find.byIcon(Icons.more_vert),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('网络导入'));
    await tester.pumpAndSettle();

    // flutter_test 拦截真实 HTTP（统一返回 400），此处验证失败路径：
    // 加载对话框正常关闭、SnackBar 提示、无框架断言
    await tester.enterText(dialogField, 'http://example.com/s.json');
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('获取书源失败'), findsOneWidget);
  });

  testWidgets('扫码导入 JSON：解析成功进入确认页不崩溃', (tester) async {
    // 二维码路由返回书源 JSON，走无网络的解析分流，
    // 覆盖 加载对话框关闭 → 确认页 push 的完整路由时序
    final qrJson = jsonEncode([
      {'bookSourceUrl': 'https://b.com', 'bookSourceName': '书源B'},
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: const SourceScreen(),
          onGenerateRoute: (settings) {
            if (settings.name == AppRoutes.qrcode) {
              return MaterialPageRoute<String>(
                builder: (qrContext) => Scaffold(
                  body: Center(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(qrContext, qrJson),
                      child: const Text('返回JSON'),
                    ),
                  ),
                ),
              );
            }
            return null;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.descendant(
      of: find.byType(AppBar),
      matching: find.byIcon(Icons.more_vert),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('二维码导入'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('返回JSON'));
    await tester.pumpAndSettle();

    // 成功进入导入确认页
    expect(find.text('导入书源'), findsOneWidget);
    expect(find.text('书源B'), findsOneWidget);
    expect(find.text('新增'), findsOneWidget);
  });

  testWidgets('确认导入：字符串数字书源直传原始 JSON 给 importBookSources',
      (tester) async {
    // 第三方书源字符串数字字段（yckceo_7631 形态）：预览解析不再全灭，
    // 确认导入时选中项的原始 JSON（含字符串数字）直传 Rust 宽松兜底
    when(() => mockApi.importBookSources(any())).thenAnswer((_) async => 1);
    final raw = <String, dynamic>{
      'bookSourceUrl': 'https://www.qianyezw.com',
      'bookSourceName': '新御书屋(千夜)',
      'bookSourceGroup': 'AI',
      'lastUpdateTime': '1785432524399',
      'ruleToc': {'isVolume': 'false', 'chapterList': '#list dd a'},
    };

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: SourceImportConfirmScreen(
            sources: [SourcePreview.fromRaw(raw)],
            localSources: const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 预览条目正常展示（未被严格解析拦截）
    expect(find.text('新御书屋(千夜)'), findsOneWidget);
    expect(find.text('新增'), findsOneWidget);

    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    // 验证 importBookSources 收到的是原始 JSON（字符串数字原样保留）
    final captured = verify(
      () => mockApi.importBookSources(captureAny()),
    ).captured;
    expect(captured, isNotEmpty);
    final passed = captured.single as String;
    expect(passed, contains('"lastUpdateTime":"1785432524399"'));
    expect(passed, contains('"isVolume":"false"'));
    expect(passed, contains('新御书屋(千夜)'));
  });
}
