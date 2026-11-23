// 「备份内容」多选 Dialog（C1 逐表备份忽略）组件测试
//
// 钉住三件事：
// 1. 可勾选项来自 BackupContentService.entries（15 项参考版键），勾选回传集合；
// 2. 角色卡（R42 阶段 2A）**不出现在可勾选清单里**（产品决策永不备份，
//    与「可选关闭」语义不同），但必须有只读告知行；
// 3. 取消返回 null，确认返回当前集合。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/l10n/app_strings.dart';
import 'package:flutter_legado/src/services/backup_content_service.dart';
import 'package:flutter_legado/src/widgets/backup_content_dialog.dart';

Widget _host(Set<String> initial, void Function(Set<String>?) onResult) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              final result = await showDialog<Set<String>>(
                context: context,
                builder: (_) => BackupContentDialog(initial: initial),
              );
              onResult(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => AppStrings.setLocale('zh'));

  testWidgets('列出全部可忽略项，角色卡只做告知不可勾选', (tester) async {
    await tester.pumpWidget(_host(const {}, (_) {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 每个可勾选项都在
    for (final entry in BackupContentService.entries) {
      expect(find.text(entry.title), findsOneWidget, reason: entry.key);
    }
    // 角色卡不得作为可勾选项出现（不在 entries 里，也不得凭空出现标题）
    expect(find.text('角色卡'), findsNothing, reason: '角色卡不是「可选关闭」项');
    // 但必须有告知行
    expect(
      find.text(AppStrings.backupContentCharactersExcluded),
      findsOneWidget,
      reason: '必须让用户知道角色卡不随备份迁移',
    );
    // 勾选框数量严格等于 entries 数量（告知行不是 CheckboxListTile）
    expect(
      find.byType(CheckboxListTile),
      findsNWidgets(BackupContentService.entries.length),
    );
  });

  testWidgets('勾选/取消回传集合；取消返回 null', (tester) async {
    Set<String>? result;
    await tester.pumpWidget(_host(const {'bookSource'}, (r) => result = r));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 初始已忽略项为选中态
    final sourceTile = tester.widget<CheckboxListTile>(
      find.ancestor(
        of: find.text('书源'),
        matching: find.byType(CheckboxListTile),
      ),
    );
    expect(sourceTile.value, isTrue);

    // 15 项超出 600dp 测试窗口，先滚到目标项再点（ensureVisible 走
    // SingleChildScrollView 的 Scrollable）
    await tester.ensureVisible(find.text('词典规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('词典规则'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.confirm));
    await tester.pumpAndSettle();

    expect(result, {'bookSource', 'dictRule'});

    // 取消分支
    result = null;
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(AppStrings.cancel));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
