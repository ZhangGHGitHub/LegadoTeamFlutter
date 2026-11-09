/// 高亮规则批量选择 + 分组管理测试（批7c-2）
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/highlight_rules/highlight_rules_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/highlight_rules_screen.dart';

import '../mocks/mocks.dart';

/// 内存高亮规则 API（列表/保存/删除），用于批量与分组联动测试
class _FakeHighlightRuleApi extends MockRustApi {
  final List<HighlightRule> rules = [];
  final Set<int> failSaveIds = {};
  int _nextId = 1;

  @override
  Future<String> highlightRuleList() async =>
      jsonEncode(rules.map((rule) => rule.toJson()).toList());

  @override
  Future<int> highlightRuleSave({required String ruleJson}) async {
    final parsed = HighlightRule.fromJson(
      jsonDecode(ruleJson) as Map<String, dynamic>,
    );
    if (failSaveIds.contains(parsed.id)) {
      throw Exception('save failed ${parsed.id}');
    }
    var id = parsed.id;
    if (id <= 0) {
      id = _nextId++;
    }
    final saved = parsed.copyWith(id: id);
    final index = rules.indexWhere((rule) => rule.id == id);
    if (index >= 0) {
      rules[index] = saved;
    } else {
      rules.add(saved);
    }
    return id;
  }

  @override
  Future<bool> highlightRuleDelete({required int id}) async {
    final before = rules.length;
    rules.removeWhere((rule) => rule.id == id);
    return rules.length != before;
  }
}

HighlightRule _rule({
  required int id,
  required String name,
  String? group,
  bool isEnabled = true,
}) {
  return HighlightRule(
    id: id,
    uuid: 'uuid-$id',
    name: name,
    pattern: 'p$id',
    group: group,
    isEnabled: isEnabled,
    sortOrder: id,
  );
}

void main() {
  late _FakeHighlightRuleApi api;

  setUp(() => api = _FakeHighlightRuleApi());

  Future<void> pumpScreen(
    WidgetTester tester, {
    Size size = const Size(400, 900),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: const MaterialApp(home: HighlightRulesScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> openMore(WidgetTester tester) async {
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
  }

  Future<void> enterBatch(WidgetTester tester) async {
    await openMore(tester);
    await tester.tap(find.text('批量管理'));
    await tester.pumpAndSettle();
  }

  Future<void> selectAll(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('highlight-batch-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
  }

  testWidgets('进入/退出批量、点击与长按选择、全选/反选', (tester) async {
    api.rules.addAll([_rule(id: 1, name: '规则一'), _rule(id: 2, name: '规则二')]);
    await pumpScreen(tester);

    await enterBatch(tester);
    expect(find.byKey(const ValueKey('highlight-batch-count')), findsOneWidget);
    expect(find.text('已选 0 项'), findsWidgets);
    expect(find.byType(Checkbox), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('highlight-rule-tile-1')));
    await tester.pump();
    expect(find.text('已选 1 项'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('highlight-select-2')));
    await tester.pump();
    expect(find.text('已选 2 项'), findsWidgets);

    await selectAll(tester);
    expect(find.text('已选 2 项'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('highlight-batch-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 项'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('highlight-batch-close')));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('长按行进入批量并选中', (tester) async {
    api.rules.add(_rule(id: 1, name: '规则一'));
    await pumpScreen(tester);
    await tester.longPress(find.byKey(const ValueKey('highlight-rule-tile-1')));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 项'), findsWidgets);
    expect(find.byType(Checkbox), findsOneWidget);
  });

  testWidgets('批量停用/启用串行保存，选择保留', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: '规则一', isEnabled: false),
      _rule(id: 2, name: '规则二', isEnabled: false),
    ]);
    await pumpScreen(tester);
    await enterBatch(tester);
    await selectAll(tester);

    await tester.tap(find.byKey(const ValueKey('highlight-batch-enable')));
    await tester.pumpAndSettle();
    expect(api.rules.every((rule) => rule.isEnabled), isTrue);
    expect(find.text('已选 2 项'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('highlight-batch-disable')));
    await tester.pumpAndSettle();
    expect(api.rules.every((rule) => !rule.isEnabled), isTrue);
  });

  testWidgets('批量删除二次确认并清空选择', (tester) async {
    api.rules.addAll([_rule(id: 1, name: '规则一'), _rule(id: 2, name: '规则二')]);
    await pumpScreen(tester);
    await enterBatch(tester);
    await selectAll(tester);

    await tester.tap(find.byKey(const ValueKey('highlight-batch-delete')));
    await tester.pumpAndSettle();
    expect(find.text('确定删除选中的 2 条规则吗？'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('highlight-batch-delete-confirm')),
    );
    await tester.pumpAndSettle();

    expect(api.rules, isEmpty);
    expect(find.text('已选 0 项'), findsWidgets);
  });

  testWidgets('导出选中：JSON 只含选中项', (tester) async {
    final selected = _rule(id: 2, name: '选中规则');
    final json = buildHighlightRulesExportJson([selected]);
    final decoded = jsonDecode(json) as Map<String, dynamic>;
    final rules = (decoded['rules'] as List).cast<Map<String, dynamic>>();
    expect(rules, hasLength(1));
    expect(rules.single['id'], 2);
    expect(rules.single['name'], '选中规则');
    expect(decoded['type'], 'highlightRule');
  });

  testWidgets('筛选后批量范围：只作用于当前分组可见项', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: 'A1', group: '分组A', isEnabled: false),
      _rule(id: 2, name: 'A2', group: '分组A', isEnabled: false),
      _rule(id: 3, name: 'B1', group: '分组B', isEnabled: false),
    ]);
    await pumpScreen(tester);
    await enterBatch(tester);
    await tester.tap(find.byKey(const ValueKey('highlight-group-filter-分组A')));
    await tester.pump();
    await selectAll(tester);

    await tester.tap(find.byKey(const ValueKey('highlight-batch-enable')));
    await tester.pumpAndSettle();
    expect(api.rules.firstWhere((r) => r.id == 1).isEnabled, isTrue);
    expect(api.rules.firstWhere((r) => r.id == 2).isEnabled, isTrue);
    expect(api.rules.firstWhere((r) => r.id == 3).isEnabled, isFalse);
  });

  testWidgets('分组筛选 chips：全部/未分组/各分组', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: 'A1', group: '分组A'),
      _rule(id: 2, name: 'B1', group: '分组B'),
      _rule(id: 3, name: '未分组项'),
    ]);
    await pumpScreen(tester);

    expect(find.text('分组：分组A'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('highlight-group-filter-分组A')));
    await tester.pump();
    expect(find.byKey(const ValueKey('highlight-rule-tile-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('highlight-rule-tile-2')), findsNothing);
    expect(find.byKey(const ValueKey('highlight-rule-tile-3')), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('highlight-group-filter-__ungrouped__')),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('highlight-rule-tile-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('highlight-rule-tile-1')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('highlight-group-filter-all')));
    await tester.pump();
    expect(find.byKey(const ValueKey('highlight-rule-tile-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('highlight-rule-tile-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('highlight-rule-tile-3')), findsOneWidget);
  });

  testWidgets('编辑分组保存/清空', (tester) async {
    api.rules.add(_rule(id: 1, name: '规则一', group: '旧组'));
    await pumpScreen(tester);

    await tester.tap(find.byKey(const ValueKey('highlight-rule-tile-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('highlight-rule-group')),
      ' 新组 ',
    );
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.rules.single.group, '新组');

    await tester.tap(find.byKey(const ValueKey('highlight-rule-tile-1')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('highlight-rule-group')),
      '',
    );
    await tester.ensureVisible(find.text('保存'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(api.rules.single.group, isNull);
  });

  testWidgets('分组重命名：合并到已存在分组', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: 'A1', group: '分组A'),
      _rule(id: 2, name: 'B1', group: '分组B'),
    ]);
    await pumpScreen(tester);
    await openMore(tester);
    await tester.tap(find.text('管理分组'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('highlight-group-rename-分组A')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('highlight-group-rename-field')),
      '分组B',
    );
    await tester.tap(
      find.byKey(const ValueKey('highlight-group-rename-confirm')),
    );
    await tester.pumpAndSettle();

    expect(api.rules.every((rule) => rule.group == '分组B'), isTrue);
    expect(find.byKey(const ValueKey('highlight-group-row-分组A')), findsNothing);
    expect(find.text('2 条规则'), findsOneWidget);
  });

  testWidgets('删除分组：规则 group 置 null，规则保留', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: 'A1', group: '分组A'),
      _rule(id: 2, name: 'B1', group: '分组B'),
    ]);
    await pumpScreen(tester);
    await openMore(tester);
    await tester.tap(find.text('管理分组'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('highlight-group-delete-分组A')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('highlight-group-delete-confirm')),
    );
    await tester.pumpAndSettle();

    expect(api.rules, hasLength(2));
    expect(api.rules.firstWhere((r) => r.id == 1).group, isNull);
    expect(api.rules.firstWhere((r) => r.id == 2).group, '分组B');
    expect(find.byKey(const ValueKey('highlight-group-row-分组A')), findsNothing);
  });

  testWidgets('分组重命名失败：对话框内错误汇总', (tester) async {
    api.rules.add(_rule(id: 1, name: 'A1', group: '分组A'));
    api.failSaveIds.add(1);
    await pumpScreen(tester);
    await openMore(tester);
    await tester.tap(find.text('管理分组'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('highlight-group-rename-分组A')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('highlight-group-rename-field')),
      '分组B',
    );
    await tester.tap(
      find.byKey(const ValueKey('highlight-group-rename-confirm')),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('highlight-group-error')), findsOneWidget);
    expect(find.textContaining('重命名分组失败'), findsOneWidget);
    expect(api.rules.single.group, '分组A');
  });

  testWidgets('360dp 分组管理对话框不溢出', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: 'A1', group: '分组A'),
      _rule(id: 2, name: 'B1', group: '分组B'),
    ]);
    await pumpScreen(tester, size: const Size(360, 800));
    await openMore(tester);
    await tester.tap(find.text('管理分组'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('批量失败汇总 SnackBar', (tester) async {
    api.rules.addAll([
      _rule(id: 1, name: '失败规则', isEnabled: false),
      _rule(id: 2, name: '成功规则', isEnabled: false),
    ]);
    api.failSaveIds.add(1);
    await pumpScreen(tester);
    await enterBatch(tester);
    await selectAll(tester);
    await tester.tap(find.byKey(const ValueKey('highlight-batch-enable')));
    await tester.pumpAndSettle();

    expect(find.textContaining('启用失败'), findsOneWidget);
    expect(find.textContaining('失败规则'), findsWidgets);
    expect(api.rules.firstWhere((r) => r.id == 2).isEnabled, isTrue);
  });

  testWidgets('360dp 批量顶栏不溢出', (tester) async {
    api.rules.addAll([_rule(id: 1, name: '规则一'), _rule(id: 2, name: '规则二')]);
    await pumpScreen(tester, size: const Size(360, 800));
    await enterBatch(tester);
    await selectAll(tester);
    expect(tester.takeException(), isNull);
  });
}
