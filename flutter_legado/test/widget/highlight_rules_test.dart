// 高亮规则页 widget 测试
//
// 验证补齐的原版 HighlightRuleActivity 对等实现：
// - 空状态提示
// - 规则列表渲染（名称/模式/范围/正则徽标/启用开关）
// - 启用开关切换调用 highlightRuleSave（isEnabled 翻转）
// - 新增表单包含原版字段并保存时经 highlightRuleSave 传递
// - 删除走确认对话框并调用 highlightRuleDelete
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/highlight_rules_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  const sampleRule = {
    'id': 1,
    'name': '关键词高亮',
    'pattern': '修炼',
    'isRegex': false,
    'scope': null,
    'isEnabled': true,
    'style': '{"textColor":-65536}',
    'sortOrder': 0,
    'timeoutMillisecond': 3000,
    'applyToTitle': false,
  };

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.highlightRuleList()).thenAnswer((_) async => '[]');
    when(() => mockApi.highlightRuleSave(ruleJson: any(named: 'ruleJson')))
        .thenAnswer((_) async => 1);
    when(() => mockApi.highlightRuleDelete(id: any(named: 'id')))
        .thenAnswer((_) async => true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: const MaterialApp(home: HighlightRulesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空列表显示空状态', (tester) async {
    await pumpScreen(tester);
    expect(find.text('暂无高亮规则'), findsOneWidget);
  });

  testWidgets('列表渲染规则名称/模式/范围', (tester) async {
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([sampleRule]));
    await pumpScreen(tester);

    expect(find.text('关键词高亮'), findsOneWidget);
    expect(find.text('修炼'), findsOneWidget);
    expect(find.text('全局生效'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
  });

  testWidgets('切换启用开关保存翻转后的 isEnabled', (tester) async {
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([sampleRule]));
    await pumpScreen(tester);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    expect(saved['isEnabled'], false);
    expect(saved['id'], 1);
  });

  testWidgets('新增表单包含原版字段且保存传递 pattern', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byIcon(Symbols.add_rounded));
    await tester.pumpAndSettle();

    expect(find.text('新增高亮规则'), findsOneWidget);
    expect(find.text('使用正则表达式'), findsOneWidget);
    expect(find.text('应用到标题'), findsOneWidget);
    expect(find.text('高亮颜色'), findsOneWidget);

    // 表单字段：名称 / 匹配模式 / 生效范围
    await tester.enterText(find.byType(TextField).at(0), '测试规则');
    await tester.enterText(find.byType(TextField).at(1), '关键词');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    expect(saved['name'], '测试规则');
    expect(saved['pattern'], '关键词');
    expect(saved['isEnabled'], true);
  });

  testWidgets('删除走确认对话框并调用 highlightRuleDelete', (tester) async {
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([sampleRule]));
    await pumpScreen(tester);

    await tester.tap(find.byIcon(Symbols.delete_rounded));
    await tester.pumpAndSettle();

    // 确认对话框（对标原版 sure_del）
    expect(find.text('确定删除吗？\n关键词高亮'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();

    verify(() => mockApi.highlightRuleDelete(id: 1)).called(1);
  });
}
