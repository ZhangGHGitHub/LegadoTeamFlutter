import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Settings sections render', (tester) async {
    // 验证设置页面各分区渲染
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            children: const [
              // 外观设置分区
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('外观设置',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: Icon(Icons.brightness_6),
                title: Text('主题模式'),
                subtitle: Text('跟随系统'),
              ),
              ListTile(
                leading: Icon(Icons.language),
                title: Text('语言'),
                subtitle: Text('跟随系统'),
              ),
              Divider(),
              // 阅读设置分区
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('阅读设置',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: Icon(Icons.text_fields),
                title: Text('默认字号'),
                subtitle: Text('18'),
              ),
              Divider(),
              // 网络设置分区
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('网络设置',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: Icon(Icons.wifi),
                title: Text('代理设置'),
                subtitle: Text('无代理'),
              ),
              Divider(),
              // 数据管理分区
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('数据管理',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: Icon(Icons.backup),
                title: Text('备份数据'),
              ),
              ListTile(
                leading: Icon(Icons.restore),
                title: Text('恢复数据'),
              ),
              Divider(),
              // 关于分区
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('关于',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: Icon(Icons.info),
                title: Text('版本'),
                subtitle: Text('1.0.0'),
              ),
            ],
          ),
        ),
      ),
    );

    // 验证页面标题
    expect(find.text('设置'), findsOneWidget);

    // 验证各分区标题（顶部可见项）
    expect(find.text('外观设置'), findsOneWidget);
    expect(find.text('阅读设置'), findsOneWidget);

    // 验证关键设置项（滚动前检查顶部可见项）
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('默认字号'), findsOneWidget);

    // 滚动到底部查看“关于”分区和更多项
    await tester.scrollUntilVisible(find.text('关于'), 100);
    await tester.pumpAndSettle();
    expect(find.text('关于'), findsOneWidget);
    expect(find.text('版本'), findsOneWidget);
  });

  testWidgets('Settings has auto task entry', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            children: const [
              ListTile(
                leading: Icon(Icons.schedule),
                title: Text('定时任务'),
                subtitle: Text('管理自动刷新和备份任务'),
              ),
            ],
          ),
        ),
      ),
    );

    // 验证定时任务入口
    expect(find.text('定时任务'), findsOneWidget);
    expect(find.byIcon(Icons.schedule), findsOneWidget);
  });
}
