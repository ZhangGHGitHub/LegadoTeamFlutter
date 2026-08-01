// 书源管理导入/导出 + 扫码页 widget 测试
//
// 验证 Phase 4.3 书源导入/导出（对标 Android BookSourceActivity）：
// - SourceScreen 菜单含「从文件导入 / 扫码导入 / 导出到文件」入口
// - QrcodeScreen 在桌面/测试环境降级为手动输入模式（无相机），可输入并返回内容
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:provider/provider.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/source_provider.dart';
import 'package:flutter_legado/src/screens/qrcode_screen.dart';
import 'package:flutter_legado/src/screens/source_screen.dart';

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
    return ChangeNotifierProvider(
      create: (_) => SourceProvider(mockApi),
      child: const MaterialApp(home: SourceScreen()),
    );
  }

  group('SourceScreen 导入/导出菜单', () {
    testWidgets('菜单含文件导入/扫码导入/导出到文件入口', (tester) async {
      await tester.pumpWidget(wrapSourceScreen());
      await tester.pumpAndSettle();

      // 打开溢出菜单（更多操作）
      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();

      expect(find.text('从 URL 导入'), findsOneWidget);
      expect(find.text('从文件导入'), findsOneWidget);
      expect(find.text('扫码导入'), findsOneWidget);
      expect(find.text('从剪贴板导入'), findsOneWidget);
      expect(find.text('导出全部书源'), findsOneWidget);
      expect(find.text('导出到文件'), findsOneWidget);
    });
  });

  group('QrcodeScreen 降级手动输入', () {
    testWidgets('桌面/测试环境展示手动输入模式', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: QrcodeScreen()),
      );
      await tester.pumpAndSettle();

      // 降级提示（无相机）
      expect(find.text('当前平台未启用相机扫码'), findsOneWidget);
      expect(find.text('手动输入'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('输入内容后确认可返回结果', (tester) async {
      String? popped;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () async {
                    popped = await Navigator.of(context).push<String>(
                      MaterialPageRoute(
                        builder: (_) => const QrcodeScreen(),
                      ),
                    );
                  },
                  child: const Text('打开扫码'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开扫码'));
      await tester.pumpAndSettle();

      const url = 'https://example.com/sources.json';
      await tester.enterText(find.byType(TextField), url);
      await tester.pumpAndSettle();

      await tester.tap(find.text('使用该内容'));
      await tester.pumpAndSettle();

      expect(popped, equals(url));
    });
  });
}
