// 替换规则页 widget 测试
//
// 验证 Phase 5.3 替换规则编辑表单（对标 Android ReplaceEditActivity）：
// - 表单包含原版全部字段：名称/分组/匹配模式/正则/替换为/作用于标题/作用于正文/作用范围/排除范围/超时/启用
// - 保存新规则时全字段传递给数据层
// - 编辑模式回填已有规则的全字段与开关状态
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/replace_rules_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getReplaceRules()).thenAnswer((_) async => []);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: ReplaceRulesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ReplaceRulesScreen 编辑表单', () {
    testWidgets('新建表单包含原版全部字段', (tester) async {
      await pumpScreen(tester);

      // 打开新建表单
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      expect(find.text('添加替换规则'), findsOneWidget);
      for (final label in const [
        '规则名称',
        '分组',
        '匹配模式',
        '替换为',
        '作用范围',
        '排除范围',
        '超时时间（毫秒）',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少字段：$label');
      }
      for (final label in const ['正则表达式', '作用于标题', '作用于正文', '启用']) {
        expect(find.text(label), findsOneWidget, reason: '缺少开关：$label');
      }
    });

    testWidgets('保存新规则时全字段传递给数据层', (tester) async {
      when(
        () => mockApi.addReplaceRule(any()),
      ).thenAnswer((inv) async => inv.positionalArguments[0] as ReplaceRule);
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // 表单字段顺序：名称/分组/匹配模式/替换为/作用范围/排除范围/超时
      // （at(0) 为顶栏搜索框，表单字段从 at(1) 起）
      await tester.enterText(find.byType(TextField).at(1), '去广告');
      await tester.enterText(find.byType(TextField).at(2), '净化');
      await tester.enterText(find.byType(TextField).at(3), '广告');
      await tester.enterText(find.byType(TextField).at(4), '【广告】');
      await tester.enterText(find.byType(TextField).at(5), '某书');
      await tester.enterText(find.byType(TextField).at(6), '排除书');
      await tester.enterText(find.byType(TextField).at(7), '5000');
      await tester.pumpAndSettle();

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      final captured =
          verify(() => mockApi.addReplaceRule(captureAny())).captured.single
              as ReplaceRule;
      expect(captured.name, '去广告');
      expect(captured.group, '净化');
      expect(captured.pattern, '广告');
      expect(captured.replacement, '【广告】');
      expect(captured.scope, '某书');
      expect(captured.excludeScope, '排除书');
      expect(captured.timeoutMillisecond, 5000);
    });

    testWidgets('编辑模式回填已有规则全字段', (tester) async {
      const rule = ReplaceRule(
        id: 1,
        name: '去广告',
        group: '净化',
        pattern: '广告',
        replacement: '',
        scope: '某书',
        scopeTitle: true,
        scopeContent: false,
        excludeScope: '排除书',
        isRegex: false,
        isEnabled: true,
        timeoutMillisecond: 5000,
      );
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [rule]);
      await pumpScreen(tester);

      // 点击列表项打开编辑表单
      await tester.tap(find.text('去广告'));
      await tester.pumpAndSettle();

      expect(find.text('编辑替换规则'), findsOneWidget);
      // 文本字段回填
      expect(find.text('净化'), findsWidgets);
      expect(find.text('某书'), findsWidgets);
      expect(find.text('排除书'), findsWidgets);
      expect(find.text('5000'), findsOneWidget);
      // 开关状态回填，顺序：正则表达式/作用于标题/作用于正文/启用
      final switches = tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .toList();
      expect(switches, hasLength(4));
      expect(switches[0].value, isFalse); // isRegex=false
      expect(switches[1].value, isTrue); // scopeTitle=true
      expect(switches[2].value, isFalse); // scopeContent=false
      expect(switches[3].value, isTrue); // isEnabled=true
    });
  });
}
