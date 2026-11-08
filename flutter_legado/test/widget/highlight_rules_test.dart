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

  /// 批7a 起编辑面板内容变长（富样式分组），点击前先滚动到可见区域
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// 按色板区域 Key 取圆形色块（批7a 起弹窗内多组色板）
  Finder paletteSwatches(String paletteKey) => find.descendant(
        of: find.byKey(Key(paletteKey)),
        matching: find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle),
      );

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

    await tapVisible(tester, find.text('保存'));

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

    await tapVisible(tester, find.text('保存'));

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

    // 选第二个预设色块（改色）——批7a 起弹窗多组色板，按区域 Key 限定
    final swatches = find.descendant(
      of: find.byKey(const Key('highlight-text-colors')),
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle),
    );
    await tester.tap(swatches.at(1));
    await tester.pump();

    await tapVisible(tester, find.text('保存'));

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
    await tapVisible(tester, find.text('保存'));

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
    await tapVisible(tester, find.text('保存'));

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    final savedStyle =
        jsonDecode(saved['style'] as String) as Map<String, dynamic>;
    expect(savedStyle['textColor'], isA<int>());
    expect(savedStyle['textColor'], isNot(0));
  });

  /// [批7a] 富样式编辑：修改填充/下划线线型+线宽/删除线颜色并保存。
  ///
  /// 断言全部已渲染字段与未知键保真：textColor 未触碰保真、fillShape/bold/
  /// italic/fontSize/顶层未知键保留、underline.distance 与嵌套未知键保留。
  testWidgets('编辑富样式：填充/下划线/删除线保存并保留未知键与 distance',
      (tester) async {
    final richStyle = jsonEncode({
      'fill': -16711936,
      'fillShape': 'ROUNDED',
      'textColor': -65536,
      'bold': true,
      'italic': true,
      'underline': {
        'kind': 'WAVY',
        'color': -65536,
        'width': 2.0,
        'distance': 2.5,
        'futureUnderlineKey': 'keep',
      },
      'strike': {'color': -1, 'futureStrikeKey': 9},
      'fontSize': 22.5,
      'futureUnknownKey': 42,
    });
    final richRule = <String, dynamic>{
      ...sampleRule,
      'style': richStyle,
      'uuid': '22222222-2222-4222-8222-222222222222',
      'group': '分组A',
      'timeoutMillisecond': 2500,
      'applyToBody': false,
    };
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([richRule]));
    await pumpScreen(tester);

    await tester.tap(find.text('关键词高亮'));
    await tester.pumpAndSettle();
    final cs = Theme.of(tester.element(find.text('背景填充'))).colorScheme;

    // 填充：选第 3 个主题色（tertiaryContainer）
    await tapVisible(tester, paletteSwatches('highlight-fill-colors').at(2));

    // 下划线线型：波浪 → 虚线
    await tapVisible(tester, find.byType(DropdownButton<String>));
    await tester.tap(find.text('虚线').last);
    await tester.pumpAndSettle();

    // 线宽：2.0 → 3.5（直接驱动 Slider.onChanged，避免像素拖拽抖动）
    tester.widget<Slider>(find.byType(Slider)).onChanged!(3.5);
    await tester.pump();

    // 删除线颜色：errorContainer
    await tapVisible(
      tester,
      paletteSwatches('highlight-strike-colors').at(3),
    );

    await tapVisible(tester, find.text('保存'));

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    final style = jsonDecode(saved['style'] as String) as Map<String, dynamic>;

    expect(style['fill'], cs.tertiaryContainer.toARGB32());
    expect(style['textColor'], -65536, reason: '未触碰文字色应保真');
    expect(style['fillShape'], 'ROUNDED');
    expect(style['bold'], true);
    expect(style['italic'], true);
    expect(style['fontSize'], 22.5);
    expect(style['futureUnknownKey'], 42);

    final underline = style['underline'] as Map<String, dynamic>;
    expect(underline['kind'], 'DASHED');
    expect(underline['color'], -65536);
    expect(underline['width'], 3.5);
    expect(underline['distance'], 2.5, reason: 'distance 不在 UI 编辑但必须保留');
    expect(underline['futureUnderlineKey'], 'keep');

    final strike = style['strike'] as Map<String, dynamic>;
    expect(strike['color'], cs.errorContainer.toARGB32());
    expect(strike['futureStrikeKey'], 9);

    // 既有保真逻辑不回退
    expect(saved['uuid'], '22222222-2222-4222-8222-222222222222');
    expect(saved['group'], '分组A');
    expect(saved['timeoutMillisecond'], 2500);
    expect(saved['applyToBody'], false);
  });

  /// [批7a] 关闭富样式开关：fill 写 0，underline/strike 键被移除
  testWidgets('关闭填充/下划线/删除线：fill=0 且移除 underline/strike',
      (tester) async {
    final richStyle = jsonEncode({
      'fill': -16711936,
      'textColor': -65536,
      'underline': {'kind': 'WAVY', 'color': -1, 'width': 2.0},
      'strike': {'color': -1},
      'futureUnknownKey': 42,
    });
    final richRule = {...sampleRule, 'style': richStyle};
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([richRule]));
    await pumpScreen(tester);

    await tester.tap(find.text('关键词高亮'));
    await tester.pumpAndSettle();

    await tapVisible(tester, find.text('背景填充'));
    await tapVisible(tester, find.text('下划线'));
    await tapVisible(tester, find.text('删除线'));
    await tapVisible(tester, find.text('保存'));

    final captured = verify(
      () => mockApi.highlightRuleSave(ruleJson: captureAny(named: 'ruleJson')),
    ).captured.single as String;
    final saved = jsonDecode(captured) as Map<String, dynamic>;
    final style = jsonDecode(saved['style'] as String) as Map<String, dynamic>;

    expect(style['fill'], 0, reason: '关闭填充必须写 fill=0');
    expect(style.containsKey('underline'), isFalse, reason: '关闭下划线应移除键');
    expect(style.containsKey('strike'), isFalse, reason: '关闭删除线应移除键');
    expect(style['textColor'], -65536);
    expect(style['futureUnknownKey'], 42);
  });

  /// [批7a] 预览实时使用本地编辑态（填充/下划线线型/删除线开关）
  testWidgets('富样式预览随本地编辑实时变化', (tester) async {
    final richStyle = jsonEncode({
      'fill': -16711936,
      'textColor': -65536,
      'underline': {
        'kind': 'WAVY',
        'color': -65536,
        'width': 2.0,
        'distance': 1.5,
      },
      'strike': {'color': -1},
    });
    final richRule = {...sampleRule, 'style': richStyle};
    when(() => mockApi.highlightRuleList())
        .thenAnswer((_) async => jsonEncode([richRule]));
    await pumpScreen(tester);

    await tester.tap(find.text('关键词高亮'));
    await tester.pumpAndSettle();
    final cs = Theme.of(tester.element(find.text('背景填充'))).colorScheme;

    Text previewText() => tester.widget<Text>(find.text('高亮效果预览'));
    BoxDecoration previewDeco() => tester
        .widget<Container>(find.byKey(const Key('highlight-style-preview')))
        .decoration! as BoxDecoration;

    // 初始态来自原 rule
    expect(previewDeco().color, const Color(-16711936));
    expect(previewText().style!.color, const Color(-65536));
    expect(
      previewText().style!.decoration!.contains(TextDecoration.underline),
      isTrue,
    );
    expect(
      previewText().style!.decoration!.contains(TextDecoration.lineThrough),
      isTrue,
    );
    expect(previewText().style!.decorationStyle, TextDecorationStyle.wavy);
    expect(previewText().style!.decorationThickness, 2.0);

    // 关闭删除线：预览立即移除 lineThrough，下划线保留
    await tapVisible(tester, find.text('删除线'));
    expect(
      previewText().style!.decoration!.contains(TextDecoration.lineThrough),
      isFalse,
    );
    expect(
      previewText().style!.decoration!.contains(TextDecoration.underline),
      isTrue,
    );

    // 下划线线型改为点线
    await tapVisible(tester, find.byType(DropdownButton<String>));
    await tester.tap(find.text('点线').last);
    await tester.pumpAndSettle();
    expect(previewText().style!.decorationStyle, TextDecorationStyle.dotted);

    // 填充改色：预览背景立即使用新填充色
    await tapVisible(tester, paletteSwatches('highlight-fill-colors').at(2));
    expect(previewDeco().color, cs.tertiaryContainer);
  });
}
