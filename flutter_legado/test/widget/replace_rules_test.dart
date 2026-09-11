// 替换规则页 widget 测试
//
// [A3 形态对齐 | full-stack-engineer + UI] 编辑器由弹窗表单升级为整页
// ReplaceRuleEditScreen 后，本页只保留入口级断言：
// - 新增入口（顶栏 +）与列表行编辑图标都打开整页编辑器
// - 路由预填 pattern 时首帧后直接打开整页编辑器（pattern 已预填）
// - 整页保存新规则后返回列表且规则出现在列表
// 整页编辑器字段/保存/剪贴板等用例见 replace_rule_edit_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/replace_rules_screen.dart';

import '../mocks/mocks.dart';

/// 按 decoration labelText 定位输入框（当前 flutter_test 未提供
/// find.byLabel，以 byWidgetPredicate 等价实现）
Finder byLabel(String label) {
  return find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
}

void main() {
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getReplaceRules()).thenAnswer((_) async => []);
  });

  Future<void> pumpScreen(
    WidgetTester tester, {
    List<ReplaceRule> rules = const [],
  }) async {
    when(() => mockApi.getReplaceRules()).thenAnswer((_) async => rules);
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

  group('ReplaceRulesScreen 整页编辑器入口（A3）', () {
    testWidgets('新增入口（顶栏 +）打开整页编辑器', (tester) async {
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Symbols.add_rounded));
      await tester.pumpAndSettle();

      // 整页渲染（非弹窗）：标题 + 关键字段
      expect(find.text('添加替换规则'), findsOneWidget);
      for (final label in const ['规则名称', '匹配规则', '替换为', '预览输入']) {
        expect(find.text(label), findsOneWidget, reason: '缺少字段：$label');
      }
    });

    testWidgets('列表行编辑图标打开整页编辑器并回填', (tester) async {
      const rule = ReplaceRule(
        id: 1,
        name: '去广告',
        pattern: '广告',
        replacement: '【广告】',
        scope: '某书',
      );
      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      await pumpScreen(tester, rules: [rule]);

      // 点行内编辑图标（对标 iv_edit）
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      expect(find.text('编辑替换规则'), findsOneWidget);
      // 字段回填
      final nameField = tester.widget<TextField>(byLabel('规则名称'));
      expect(nameField.controller?.text, '去广告');
      final scopeField = tester.widget<TextField>(byLabel('特定范围'));
      expect(scopeField.controller?.text, '某书');
    });

    testWidgets('整页保存新规则后返回列表且规则出现在列表',
        (tester) async {
      when(() => mockApi.addReplaceRule(any())).thenAnswer(
        (inv) async => (inv.positionalArguments[0] as ReplaceRule).copyWith(id: 1),
      );
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Symbols.add_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(byLabel('规则名称'), '去广告');
      await tester.enterText(byLabel('匹配规则'), '广告');
      await tester.enterText(byLabel('替换为'), '【广告】');
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      // 返回列表，新规则已入列表（notifier addRule 追加）
      expect(find.text('添加替换规则'), findsNothing);
      expect(find.text('去广告'), findsOneWidget);
      expect(
        find.text('正则: 广告 → 【广告】'),
        findsOneWidget,
      );
    });

    testWidgets('路由预填 pattern 时首帧后直接打开整页编辑器',
        (tester) async {
      when(() => mockApi.addReplaceRule(any()))
          .thenAnswer((inv) async => const ReplaceRule());
      await tester.binding.setSurfaceSize(const Size(800, 2000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(mockApi)],
          child: const MaterialApp(
            home: ReplaceRulesScreen(initialPattern: '选中词'),
          ),
        ),
      );
      // 首帧后 postFrame 回调打开编辑器
      await tester.pumpAndSettle();

      expect(find.text('添加替换规则'), findsOneWidget);
      final patternField =
          tester.widget<TextField>(byLabel('匹配规则'));
      expect(patternField.controller?.text, '选中词');
    });
  });
}
