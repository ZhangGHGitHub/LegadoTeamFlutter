// 替换规则页 widget 测试
//
// [A3 形态对齐 | full-stack-engineer + UI] 编辑器由弹窗表单升级为整页
// ReplaceRuleEditScreen 后，本页只保留入口级断言：
// - 新增入口（顶栏 +）与列表行编辑图标都打开整页编辑器
// - 路由预填 pattern 时首帧后直接打开整页编辑器（pattern 已预填）
// - 整页保存新规则后返回列表且规则出现在列表
// 整页编辑器字段/保存/剪贴板等用例见 replace_rule_edit_test.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/replace_rule/replace_rule_notifier.dart';
import 'package:flutter_legado/src/screens/replace_rules_screen.dart';
import 'package:flutter_legado/src/services/book_api.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

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

  /// 以指定 BookApi 实现挂载页面（批12：排序链路用真实 MockBookApi）
  Future<void> pumpScreenWithApi(WidgetTester tester, BookApi api) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
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

    testWidgets('整页保存新规则后返回列表且规则出现在列表', (tester) async {
      when(() => mockApi.addReplaceRule(any())).thenAnswer(
        (inv) async =>
            (inv.positionalArguments[0] as ReplaceRule).copyWith(id: 1),
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
      expect(find.text('正则: 广告 → 【广告】'), findsOneWidget);
    });

    testWidgets('路由预填 pattern 时首帧后直接打开整页编辑器', (tester) async {
      when(
        () => mockApi.addReplaceRule(any()),
      ).thenAnswer((inv) async => const ReplaceRule());
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
      final patternField = tester.widget<TextField>(byLabel('匹配规则'));
      expect(patternField.controller?.text, '选中词');
    });

    testWidgets('编辑「特定范围」后保存：update 收到新 scope（批12）', (tester) async {
      const rule = ReplaceRule(
        id: 1,
        name: '去广告',
        pattern: '广告',
        replacement: '【广告】',
        scope: '旧范围',
      );
      ReplaceRule? captured;
      when(() => mockApi.updateReplaceRule(any())).thenAnswer((inv) async {
        captured = inv.positionalArguments[0] as ReplaceRule;
      });
      await pumpScreen(tester, rules: [rule]);

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      await tester.enterText(byLabel('特定范围'), '新范围');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect(captured!.scope, '新范围', reason: '特定范围编辑应随保存透传');
    });
  });

  // ===== [批12 | 2026-11-10] 排序写链路与子集态禁用 =====
  group('ReplaceRulesScreen 排序写链路（批12）', () {
    testWidgets('拖拽 0→2 只调一次全量重排，load 后顺序保持', (tester) async {
      final api = MockBookApi();
      await api.addReplaceRule(const ReplaceRule(name: 'A', pattern: 'a'));
      await api.addReplaceRule(const ReplaceRule(name: 'B', pattern: 'b'));
      await api.addReplaceRule(const ReplaceRule(name: 'C', pattern: 'c'));
      final ids = (await api.getReplaceRules()).map((r) => r.id).toList();
      await pumpScreenWithApi(tester, api);

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      // onReorderItem 的 newIndex 已按移除项调整：A(0) 拖到末位
      list.onReorderItem!(0, 2);
      await tester.pumpAndSettle();

      expect(api.reorderReplaceRulesCalls, 1, reason: '一次全量调用');
      expect(
        api.lastReorderReplaceRulesIdsJson,
        equals(jsonEncode([ids[1], ids[2], ids[0]])),
        reason: '应提交全量 id 的新顺序',
      );
      double dyOf(String name) => tester.getTopLeft(find.text(name)).dy;
      expect(dyOf('B'), lessThan(dyOf('C')));
      expect(dyOf('C'), lessThan(dyOf('A')));

      // 模拟退出再进入：load() 后顺序由 DB/Mock 的 order 决定，不应退回原序
      final container = ProviderScope.containerOf(
        tester.element(find.byType(ReplaceRulesScreen)),
      );
      await container.read(replaceRuleNotifierProvider.notifier).load();
      await tester.pumpAndSettle();
      expect(dyOf('B'), lessThan(dyOf('C')));
      expect(dyOf('C'), lessThan(dyOf('A')));
    });

    testWidgets('拖拽手柄触控区 48×48 且带无障碍标签', (tester) async {
      const rule = ReplaceRule(id: 7, name: '去广告', pattern: '广告');
      await pumpScreen(tester, rules: [rule]);

      final handle = find.byKey(const ValueKey('replace-rule-drag-handle-7'));
      expect(handle, findsOneWidget);
      expect(
        tester.getSize(handle),
        const Size(48, 48),
        reason: '手柄命中区应达 Material 最小触控目标 48dp',
      );

      final semantics = find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.label == '拖动排序',
      );
      expect(semantics, findsOneWidget);
      expect(
        tester.widget<Semantics>(semantics).properties.button,
        isTrue,
        reason: '手柄应作为按钮暴露给无障碍服务',
      );
    });

    testWidgets('手柄 48dp 全域可起拖（图标盒外偏移命中）', (tester) async {
      final api = MockBookApi();
      await api.addReplaceRule(const ReplaceRule(name: 'A', pattern: 'a'));
      await api.addReplaceRule(const ReplaceRule(name: 'B', pattern: 'b'));
      await api.addReplaceRule(const ReplaceRule(name: 'C', pattern: 'c'));
      final firstId = (await api.getReplaceRules()).first.id;
      await pumpScreenWithApi(tester, api);

      final handle = find.byKey(ValueKey('replace-rule-drag-handle-$firstId'));
      final topLeft = tester.getTopLeft(handle);
      // 24dp 图标居中于 48dp：图标 x 区间为 [topLeft.dx+12, topLeft.dx+36]，
      // 取 +4 落在图标盒外、48dp 命中区内（修复前该点不进入 Listener 命中路径）
      final gesture = await tester.startGesture(topLeft + const Offset(4, 24));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        api.reorderReplaceRulesCalls,
        1,
        reason: '图标外、48dp 命中区内的起点也必须触发拖拽重排',
      );
      expect(api.lastReorderReplaceRulesIdsJson, isNotNull);
    });

    testWidgets('搜索筛选态禁用拖拽手柄并显示说明', (tester) async {
      const rule = ReplaceRule(id: 1, name: '去广告', pattern: '广告');
      await pumpScreen(tester, rules: [rule]);
      expect(find.byType(ReorderableDragStartListener), findsOneWidget);
      expect(
        tester.getSize(
          find.byKey(const ValueKey('replace-rule-drag-handle-1')),
        ),
        const Size(48, 48),
      );

      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == '搜索规则',
        ),
        '广告',
      );
      await tester.pumpAndSettle();

      expect(find.text('筛选/搜索状态下暂不支持拖拽排序'), findsOneWidget);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(
        find.byType(ReorderableDragStartListener),
        findsNothing,
        reason: '子集态不应挂拖拽监听',
      );
      expect(
        tester.getSize(
          find.byKey(const ValueKey('replace-rule-drag-handle-1')),
        ),
        const Size(48, 48),
        reason: '禁用态手柄保持同尺寸，切换筛选不引起布局跳动',
      );
    });

    testWidgets('分组/启用筛选态同样禁用拖拽并显示说明', (tester) async {
      const rules = [
        ReplaceRule(id: 1, name: '甲规则', pattern: 'a', group: '净化组'),
        ReplaceRule(
          id: 2,
          name: '乙规则',
          pattern: 'b',
          group: '净化组',
          isEnabled: false,
        ),
        ReplaceRule(id: 3, name: '丙规则', pattern: 'c'),
      ];
      await pumpScreen(tester, rules: rules);
      expect(find.byType(ReorderableDragStartListener), findsWidgets);

      // 分组筛选：只有「净化组」两条可见
      await tester.tap(find.byTooltip('分组筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('分组：净化组').last);
      await tester.pumpAndSettle();
      expect(find.text('筛选/搜索状态下暂不支持拖拽排序'), findsOneWidget);
      expect(find.byType(ReorderableListView), findsNothing);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      expect(find.text('丙规则'), findsNothing, reason: '无分组规则被筛掉');

      // 启用筛选：禁用的乙规则不可见，仍不可拖拽
      await tester.tap(find.byTooltip('分组筛选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用').last);
      await tester.pumpAndSettle();
      expect(find.text('筛选/搜索状态下暂不支持拖拽排序'), findsOneWidget);
      expect(find.byType(ReorderableDragStartListener), findsNothing);
      expect(find.text('乙规则'), findsNothing, reason: '禁用规则被筛掉');
    });

    testWidgets('排序落库失败：回滚原顺序并提示', (tester) async {
      final api = _FailingReorderApi();
      await api.addReplaceRule(const ReplaceRule(name: 'A', pattern: 'a'));
      await api.addReplaceRule(const ReplaceRule(name: 'B', pattern: 'b'));
      await api.addReplaceRule(const ReplaceRule(name: 'C', pattern: 'c'));
      await pumpScreenWithApi(tester, api);

      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(0, 2);
      await tester.pumpAndSettle();

      // FFI 抛错 → notifier.load() 回滚 → 页面提示
      expect(api.reorderAttempts, 1, reason: '失败只尝试一次，不逐条写入');
      expect(find.text('排序保存失败'), findsOneWidget);

      double dyOf(String name) => tester.getTopLeft(find.text(name)).dy;
      expect(dyOf('A'), lessThan(dyOf('B')));
      expect(dyOf('B'), lessThan(dyOf('C')), reason: '顺序应回滚为原序');
    });
  });
}

/// [批12] reorder 恒失败的 BookApi（模拟 FFI 参数错误/落库失败）
class _FailingReorderApi extends MockBookApi {
  int reorderAttempts = 0;

  @override
  Future<int> reorderReplaceRules(List<int> ids) async {
    reorderAttempts++;
    throw Exception('重排替换规则参数错误: 缺失 id');
  }
}
