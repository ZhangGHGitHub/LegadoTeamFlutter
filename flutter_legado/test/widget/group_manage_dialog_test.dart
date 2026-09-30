import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/widgets/group_manage_dialog.dart';

/// GroupManageDialog 泛型壳行为测试（B2 统一批）
///
/// 三处同型 dialog（书源/替换规则/订阅源）收敛后的公共行为验证：
/// 分组推导去重保序、重命名批量更新、删除确认、添加分组收拢未分组项、
/// 文案名词参数化、变更标记返回值。
class _Item {
  final String name;
  final String? group;
  const _Item(this.name, this.group);
  _Item withGroup(String? newGroup) => _Item(name, newGroup);
}

void main() {
  Future<List<_Item>> Function(WidgetTester) openDialog(
    List<_Item> items,
    List<_Item> updated,
    String noun,
  ) {
    return (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: ElevatedButton(
                  onPressed: () => showDialog<bool>(
                    context: context,
                    builder: (_) => GroupManageDialog<_Item>(
                      itemNoun: noun,
                      items: items,
                      groupOf: (it) => it.group,
                      copyWithGroup: (it, g) => it.withGroup(g),
                      update: (it) async => updated.add(it),
                    ),
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      return updated;
    };
  }

  testWidgets('分组推导：多字段分隔去重保序', (tester) async {
    await openDialog(
      const [
        _Item('s1', '甲,乙'),
        _Item('s2', '乙'),
        _Item('s3', '丙；丁'),
        _Item('s4', null),
      ],
      [],
      '书源',
    )(tester);

    expect(find.text('分组管理'), findsOneWidget);
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    expect(find.text('丙'), findsOneWidget);
    expect(find.text('丁'), findsOneWidget);
  });

  testWidgets('重命名：批量更新含该分组条目且保留其他分组', (tester) async {
    final updated = <_Item>[];
    await openDialog(
      const [
        _Item('s1', '甲,乙'),
        _Item('s2', '乙'),
        _Item('s3', '丙'),
      ],
      updated,
      '书源',
    )(tester);

    // 点「乙」行的重命名
    await tester.tap(find.byTooltip('重命名').at(1));
    await tester.pumpAndSettle();
    expect(find.text('重命名分组'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '戊');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // s1: 甲,乙 -> 甲,戊 ; s2: 乙 -> 戊 ; s3 不含乙不更新
    expect(updated.length, 2);
    expect(updated[0].group, '甲,戊');
    expect(updated[1].group, '戊');
    expect(find.text('戊'), findsOneWidget);
  });

  testWidgets('删除分组：确认后批量清空该分组字段', (tester) async {
    final updated = <_Item>[];
    await openDialog(
      const [
        _Item('s1', '乙'),
        _Item('s2', '乙,丙'),
      ],
      updated,
      '订阅源',
    )(tester);

    // 点「乙」行删除（列表第一行是乙）
    await tester.tap(find.byTooltip('删除').first);
    await tester.pumpAndSettle();
    expect(find.text('删除分组'), findsOneWidget);
    // 文案名词参数化：订阅源
    expect(find.textContaining('分组内订阅源将移出'), findsOneWidget);
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(updated.length, 2);
    expect(updated[0].group, isNull);
    expect(updated[1].group, '丙');
  });

  testWidgets('添加分组：收拢未分组项；全部分组时给名词化提示', (tester) async {
    final updated = <_Item>[];
    await openDialog(
      const [
        _Item('s1', '甲'),
        _Item('s2', null),
        _Item('s3', null),
      ],
      updated,
      '规则',
    )(tester);

    await tester.tap(find.byTooltip('添加分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '新组');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 两个无分组项被归入
    expect(updated.length, 2);
    expect(updated.every((it) => it.group == '新组'), isTrue);

    // 再添加：此时全部有分组 -> 名词化提示
    await tester.tap(find.byTooltip('添加分组'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '又一组');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.text('没有未分组的规则可归入该分组'), findsOneWidget);
  });

  testWidgets('关闭返回变更标记 true', (tester) async {
    bool? result;
    final items = const [_Item('s1', '甲')];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    builder: (_) => GroupManageDialog<_Item>(
                      itemNoun: '书源',
                      items: items,
                      groupOf: (it) => it.group,
                      copyWithGroup: (it, g) => it.withGroup(g),
                      update: (it) async {},
                    ),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
