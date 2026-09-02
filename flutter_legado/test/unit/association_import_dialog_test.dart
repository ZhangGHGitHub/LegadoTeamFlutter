import 'package:flutter/material.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/screens/association_import_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

/// 固定就绪态的假 Notifier（不触 FFI：build 直接返回两条候选）
class _FakeReadyNotifier extends AssociationNotifier {
  @override
  AssociationState build() => const AssociationState(
        type: ImportType.bookSource,
        items: [
          AssociationItem(
            raw: {'bookSourceName': '测试源A', 'bookSourceUrl': 'https://a'},
            name: '测试源A',
            status: ImportItemStatus.isNew,
          ),
          AssociationItem(
            raw: {'bookSourceName': '测试源B', 'bookSourceUrl': 'https://b'},
            name: '测试源B',
            status: ImportItemStatus.exists,
          ),
        ],
      );
}

void main() {
  testWidgets('关联导入对话框：就绪态弹出渲染（勾选/状态标签/底部操作区）',
      (tester) async {
    // 视口缩到手机典型尺寸，验证 85% 屏高约束下的弹窗布局
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          associationNotifierProvider.overrideWith(_FakeReadyNotifier.new),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => showAssociationImportDialog(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 头部标题（按类型）
    expect(find.text('导入书源'), findsOneWidget);
    // 两条候选项行 + 状态标签（新增 / 已存在，颜色角色化）
    expect(find.byType(Checkbox), findsNWidgets(2));
    expect(find.text('新增'), findsOneWidget);
    expect(find.text('已存在'), findsOneWidget);
    // 底部操作区：默认 新增选中 / 已存在不选 → 全选（1/2）、确认（1）
    expect(find.text('全选（1/2）'), findsOneWidget);
    expect(find.text('确认（1）'), findsOneWidget);
    // bookSource 头部动作：自定义分组 + 更多选项菜单
    expect(find.text('自定义分组'), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsOneWidget);

    // 回归守护：点选后重建不得回弹（freezed items getter 每次访问新建包装，
    // 旧实现按列表 identity 判定会重置勾选）
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(find.text('确认（2）'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).last);
    await tester.pump();
    expect(find.text('确认（1）'), findsOneWidget);

    // 全选 → 确认数联动
    await tester.tap(find.text('全选（1/2）'));
    await tester.pump();
    expect(find.text('取消全选（2/2）'), findsOneWidget);
    expect(find.text('确认（2）'), findsOneWidget);
  });

  testWidgets('关联导入对话框：空闲态渲染手动入口', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () =>
                    showAssociationImportDialog(context, url: null),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 空闲态标题 + 手动入口（地址输入 / 从文件 / 从剪贴板 / 加载）
    expect(find.text('关联导入'), findsOneWidget);
    expect(find.text('内容地址'), findsOneWidget);
    expect(find.text('从文件'), findsOneWidget);
    expect(find.text('从剪贴板'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '加载'), findsOneWidget);
  });
}
