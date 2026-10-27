// 崩溃日志弹窗布局回归测试（批23）
//
// 缺陷：`CrashLogDialog` 的「崩溃时间」一行是 Row + 无约束 Text，崩溃时间
// 较长（含时区/附加文案）时把对话框横向撑破，右侧溢出 12px。
// 修复：Text 改为 Expanded + 自动换行；本测试用窄屏 + 超长文案断言无
// RenderFlex overflow 异常。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/widgets/crash_log_dialog.dart';

void main() {
  testWidgets('崩溃报告对话框：超长崩溃时间不横向溢出', (tester) async {
    // 窄屏（320 逻辑像素）放大长文案的宽度压力
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 堆栈信息、错误摘要同时给足长度，覆盖整卡纵向滚动场景
    final longTime =
        '2026-10-27 12:34:56.789 +08:00 Asia/Shanghai (CST) 附加说明超长文案';
    final longError = '数据库初始化失败：${'底层错误详情 ' * 12}';
    final crashLog = [
      '时间: $longTime',
      '错误: $longError',
      '----- 堆栈信息 -----',
      '#0      Foo.bar (package:foo/foo.dart:1:1)',
      '#1      Baz.qux (package:foo/baz.dart:2:2)',
      '日志结束',
    ].join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CrashLogDialog(crashLog: crashLog)),
      ),
    );
    await tester.pump();

    // RenderFlex overflow 会经 FlutterError 上报，被测试 binding 记录
    expect(tester.takeException(), isNull, reason: '对话框不得横向溢出');
    expect(find.textContaining('崩溃时间:'), findsOneWidget);
    expect(find.textContaining('数据库初始化失败'), findsOneWidget);
  });

  testWidgets('崩溃报告对话框：真实 yyyy-MM-dd HH:mm:ss 时间正常展示', (tester) async {
    // CrashLogService._formatTime 的实际输出格式：yyyy-MM-dd HH:mm:ss
    // （无时区/毫秒）。补一条真实格式用例，防止解析/展示回归。
    final crashLog = [
      '===== 崩溃日志 =====',
      '时间: 2026-10-27 12:34:56',
      '错误: 测试错误摘要',
      '----- 堆栈信息 -----',
      '#0      Foo.bar (package:foo/foo.dart:1:1)',
      '===== 日志结束 =====',
    ].join('\n');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CrashLogDialog(crashLog: crashLog)),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('崩溃时间: 2026-10-27 12:34:56'), findsOneWidget);
    expect(find.text('测试错误摘要'), findsOneWidget);
  });
}
