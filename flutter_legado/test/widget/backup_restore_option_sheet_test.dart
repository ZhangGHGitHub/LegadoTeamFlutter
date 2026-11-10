// 批11：备份/恢复选项 Sheet 组件测试
//
// 钉住参考版交互：标题 + 选项卡片、无取消按钮、遮罩/返回关闭；备份三项
// 顺序与图标；恢复四项顺序；禁用项点按只提示不关闭；忙碌态全部禁用。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/backup_restore_option_sheet.dart';

/// 打开 Sheet 的宿主页面（按钮触发，记录返回值）
Widget _host(Future<void> Function(BuildContext context) onPressed) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => onPressed(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('备份 Sheet 三项顺序/图标，无取消按钮，选择返回枚举', (tester) async {
    BackupOption? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showBackupOptionSheet(
          context: context,
          webDavConfigured: true,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('备份'), findsOneWidget);
    expect(_top(tester, '备份至本地'), lessThan(_top(tester, '备份至网络')));
    expect(_top(tester, '备份至网络'), lessThan(_top(tester, '备份至本地与网络')));
    expect(find.byIcon(Icons.phone_android), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byIcon(Icons.lan_outlined), findsOneWidget);
    expect(find.text('取消'), findsNothing, reason: '参考版备份 Sheet 无取消按钮');
    expect(result, isNull);

    await tester.tap(find.text('备份至本地'));
    await tester.pumpAndSettle();

    expect(result, BackupOption.local);
    expect(find.text('备份至本地'), findsNothing);
  });

  testWidgets('备份 Sheet：点遮罩关闭返回 null（不执行任何操作）', (tester) async {
    BackupOption? result = BackupOption.localAndWebDav;
    await tester.pumpWidget(
      _host((context) async {
        result = await showBackupOptionSheet(
          context: context,
          webDavConfigured: true,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('备份至本地'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('备份至本地'), findsNothing);
  });

  testWidgets('系统返回键关闭 Sheet 返回 null（不执行任何操作）', (tester) async {
    BackupOption? result = BackupOption.local;
    await tester.pumpWidget(
      _host((context) async {
        result = await showBackupOptionSheet(
          context: context,
          webDavConfigured: true,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('备份至本地'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('备份至本地'), findsNothing);
  });

  testWidgets('WebDAV 未配置：备份至网络禁用，点按提示且不关闭 Sheet', (tester) async {
    BackupOption? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showBackupOptionSheet(
          context: context,
          webDavConfigured: false,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('请先配置 WebDAV'), findsOneWidget);
    expect(result, isNull);

    await tester.tap(find.text('备份至网络'));
    await tester.pumpAndSettle();

    // 禁用原因保留在行内 + SnackBar 提示，Sheet 不关闭、不返回选择
    expect(find.text('请先配置 WebDAV'), findsNWidgets(2));
    expect(find.text('备份至网络'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('忙碌态：全部选项禁用并提示，点按不返回选择', (tester) async {
    BackupOption? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showBackupOptionSheet(
          context: context,
          webDavConfigured: true,
          busy: true,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text(kBackupRestoreBusyHint), findsNWidgets(3));

    await tester.tap(find.text('备份至本地'));
    await tester.pumpAndSettle();

    expect(find.text(kBackupRestoreBusyHint), findsNWidgets(4));
    expect(find.text('备份至本地'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets('恢复 Sheet 四项顺序/图标（参考两项 + 用户裁决两项）', (tester) async {
    RestoreOption? result;
    await tester.pumpWidget(
      _host((context) async {
        result = await showRestoreOptionSheet(
          context: context,
          webDavConfigured: true,
        );
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('恢复'), findsOneWidget);
    expect(_top(tester, '本地恢复'), lessThan(_top(tester, '网络恢复')));
    expect(_top(tester, '网络恢复'), lessThan(_top(tester, '本地最新')));
    expect(_top(tester, '本地最新'), lessThan(_top(tester, '远端最新')));
    expect(find.byIcon(Icons.phone_android), findsOneWidget);
    expect(find.byIcon(Icons.cloud_outlined), findsOneWidget);
    expect(find.byIcon(Icons.history), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
    expect(find.text('取消'), findsNothing);

    await tester.tap(find.text('远端最新'));
    await tester.pumpAndSettle();

    expect(result, RestoreOption.latestRemote);
  });

  testWidgets('恢复 Sheet：未配置 WebDAV 时远程两项禁用', (tester) async {
    await tester.pumpWidget(
      _host((context) async {
        await showRestoreOptionSheet(context: context, webDavConfigured: false);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('请先配置 WebDAV'), findsNWidgets(2));
    expect(find.text('本地恢复'), findsOneWidget);
    expect(find.text('本地最新'), findsOneWidget);
  });

  testWidgets('360dp + 1.3 字：备份/恢复 Sheet 均不溢出', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      _host((context) async {
        await showBackupOptionSheet(context: context, webDavConfigured: true);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('备份至本地与网络'), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.pumpWidget(
      _host((context) async {
        await showRestoreOptionSheet(context: context, webDavConfigured: true);
      }),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.text('远端最新'), findsOneWidget);
  });
}
