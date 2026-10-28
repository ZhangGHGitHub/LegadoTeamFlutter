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

  /// 批28b（P2-2②）：编辑保存必须保留 `group`（表单无分组输入）
  ///
  /// 修复前 `_save()` 重建 HighlightRule 时漏掉 group，编辑一次即丢分组；
  /// 本用例从列表点入编辑面板保存，断言传给 highlightRuleSave 的载荷含原分组。
  testWidgets('编辑保存保留 group 分组', (tester) async {
    final groupedRule = <String, dynamic>{
      ...sampleRule,
      'group': '分组A',
      'uuid': '11111111-1111-4111-8111-111111111111',
      'timeoutMillisecond': 2500,
      'applyToBody': false,
    };
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([groupedRule]));
    await pumpScreen(tester);

    // 点击规则行进入编辑面板（表单无 group 输入）
    await tester.tap(find.text('关键词高亮'));
    await tester.pumpAndSettle();
    expect(find.text('编辑高亮规则'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    expect(saved['group'], '分组A', reason: '编辑保存不得丢分组');
    expect(saved['uuid'], '11111111-1111-4111-8111-111111111111');
    expect(saved['timeoutMillisecond'], 2500);
    expect(saved['applyToBody'], false);
  });

  /// [批33 | 高亮字段保真] 编辑颜色保存不得丢 style 其他字段
  ///
  /// 缺陷路径：编辑表单只有颜色选择，旧 `_save()` 直接
  /// `jsonEncode({'textColor': color})` 重建 style，一次改色就把原版导入的
  /// fill/fillShape/underline/bold/strike 等全部抹掉（渲染前置数据丢失）。
  /// 修复：读取原始 style JSON → 只覆盖 textColor → 原样写回。
  testWidgets('编辑颜色保存保留 style 其余字段（补丁式写回）', (tester) async {
    final richStyle = jsonEncode({
      'textColor': -65536, // 红
      'fill': -16711936, // 绿底
      'fillShape': 'ROUNDED',
      'bold': true,
      'italic': true,
      'underline': {'kind': 'WAVY', 'color': -65536, 'width': 2.0},
      'strike': {'color': -1},
      'fontSize': 22.5,
      'futureUnknownKey': 42,
    });
    final richRule = {...sampleRule, 'style': richStyle};
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([richRule]));
    await pumpScreen(tester);

    await tester.tap(find.text('关键词高亮'));
    await tester.pumpAndSettle();
    expect(find.text('编辑高亮规则'), findsOneWidget);

    // 选第二个预设色块（改色）
    final swatches = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle),
    );
    await tester.tap(swatches.at(1));
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    final style = jsonDecode(saved['style'] as String) as Map<String, dynamic>;

    expect(style['textColor'], isNot(-65536), reason: '本次选色应生效');
    expect(style['fill'], -16711936);
    expect(style['fillShape'], 'ROUNDED');
    expect(style['bold'], true);
    expect(style['italic'], true);
    expect(style['underline'], {'kind': 'WAVY', 'color': -65536, 'width': 2.0});
    expect(style['strike'], {'color': -1});
    expect(style['fontSize'], 22.5);
    expect(style['futureUnknownKey'], 42);
  });

  /// [批33b | 未触碰保真] 只打开编辑面板直接保存，不得把原 textColor=0
  /// （原版语义：0=不设置文字色）改写为主题默认色。
  testWidgets('未触碰颜色保存：原 textColor=0 原样保留', (tester) async {
    final style = jsonEncode({
      'textColor': 0,
      'fill': -16711936,
      'bold': true,
      'futureUnknownKey': 7,
    });
    final rule = {...sampleRule, 'style': style};
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([rule]));
    await pumpScreen(tester);

    await tester.tap(find.text('关键词高亮'));
    await tester.pumpAndSettle();
    expect(find.text('编辑高亮规则'), findsOneWidget);

    // 不做任何颜色选择，直接保存
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    final savedStyle =
        jsonDecode(saved['style'] as String) as Map<String, dynamic>;

    expect(savedStyle['textColor'], 0, reason: '未触碰颜色不得改写原值');
    expect(savedStyle['fill'], -16711936);
    expect(savedStyle['bold'], true);
    expect(savedStyle['futureUnknownKey'], 7);
  });

  /// [批33b] 新增规则（无原 style）未选色时仍写入主题默认色，
  /// 保持既有「新增即可见高亮」行为不回退。
  testWidgets('新增规则未选色：写入主题默认 textColor', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byIcon(Symbols.add_rounded));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), '关键词');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    final savedStyle =
        jsonDecode(saved['style'] as String) as Map<String, dynamic>;
    expect(savedStyle['textColor'], isA<int>());
    expect(savedStyle['textColor'], isNot(0));
  });
}
