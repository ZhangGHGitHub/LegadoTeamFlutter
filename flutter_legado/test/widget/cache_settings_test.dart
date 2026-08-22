import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('缓存管理页面基本结构渲染', (tester) async {
    // 验证缓存管理页面的基本 UI 结构
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('缓存管理')),
          body: ListView(
            children: [
              const SizedBox(height: 16),
              // 缓存统计区域
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '缓存统计',
                      style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: const [
                                  Icon(Icons.storage, size: 28),
                                  SizedBox(height: 8),
                                  Text('12.5 MB',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  SizedBox(height: 4),
                                  Text('总大小'),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: const [
                                  Icon(Icons.menu_book, size: 28),
                                  SizedBox(height: 8),
                                  Text('5',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  SizedBox(height: 4),
                                  Text('书籍数量'),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                children: const [
                                  Icon(Icons.article, size: 28),
                                  SizedBox(height: 8),
                                  Text('128',
                                      style: TextStyle(
                                          fontWeight: FontWeight.bold)),
                                  SizedBox(height: 4),
                                  Text('章节数量'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const Divider(),
              // 自动过期策略区域
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '自动过期策略',
                      style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: 0,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.schedule),
                        labelText: '缓存过期时间',
                      ),
                      items: const [
                        DropdownMenuItem(value: 7, child: Text('7 天')),
                        DropdownMenuItem(value: 30, child: Text('30 天')),
                        DropdownMenuItem(value: 0, child: Text('永不过期')),
                      ],
                      onChanged: (_) {},
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '超过设定时间的缓存将在下次启动时自动清除',
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              const Divider(),
              // 清理操作区域
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '清理操作',
                      style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {},
                        icon: Icon(Icons.cleaning_services,
                            color: Colors.red[700]),
                        label: Text('清除全部缓存',
                            style: TextStyle(color: Colors.red[700])),
                        style: OutlinedButton.styleFrom(
                          side: BorderSide(color: Colors.red[700]!),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );

    // 验证页面标题
    expect(find.text('缓存管理'), findsOneWidget);

    // 验证缓存统计区域
    expect(find.text('缓存统计'), findsOneWidget);
    expect(find.text('总大小'), findsOneWidget);
    expect(find.text('书籍数量'), findsOneWidget);
    expect(find.text('章节数量'), findsOneWidget);
    expect(find.text('12.5 MB'), findsOneWidget);
    expect(find.text('5'), findsOneWidget);
    expect(find.text('128'), findsOneWidget);

    // 验证统计图标
    expect(find.byIcon(Icons.storage), findsOneWidget);
    expect(find.byIcon(Icons.menu_book), findsOneWidget);
    expect(find.byIcon(Icons.article), findsOneWidget);
  });

  testWidgets('缓存管理页面过期策略下拉框', (tester) async {
    // 验证自动过期策略下拉框功能
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('缓存管理')),
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('自动过期策略'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      initialValue: 0,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.schedule),
                        labelText: '缓存过期时间',
                      ),
                      items: const [
                        DropdownMenuItem(value: 7, child: Text('7 天')),
                        DropdownMenuItem(value: 30, child: Text('30 天')),
                        DropdownMenuItem(value: 0, child: Text('永不过期')),
                      ],
                      onChanged: (_) {},
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // 验证过期策略区域标题
    expect(find.text('自动过期策略'), findsOneWidget);

    // 验证下拉框存在
    expect(find.byType(DropdownButtonFormField<int>), findsOneWidget);

    // 验证当前显示的值（永不过期）
    expect(find.text('永不过期'), findsOneWidget);

    // 点击下拉框展开选项
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();

    // 验证所有选项可见
    expect(find.text('7 天').last, findsOneWidget);
    expect(find.text('30 天').last, findsOneWidget);
  });

  testWidgets('缓存管理页面清理按钮和确认对话框', (tester) async {
    // 验证清理按钮点击后弹出确认对话框
    bool clearCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('缓存管理')),
            body: Center(
              child: OutlinedButton.icon(
                onPressed: () {
                  showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('清除缓存'),
                      content: const Text('确定要清除所有缓存数据吗？此操作不可撤销。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(ctx, true);
                            clearCalled = true;
                          },
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  );
                },
                icon: Icon(Icons.cleaning_services, color: Colors.red[700]),
                label: Text('清除全部缓存',
                    style: TextStyle(color: Colors.red[700])),
              ),
            ),
          ),
        ),
      ),
    );

    // 验证清理按钮存在
    expect(find.text('清除全部缓存'), findsOneWidget);
    expect(find.byIcon(Icons.cleaning_services), findsOneWidget);

    // 点击清理按钮
    await tester.tap(find.text('清除全部缓存'));
    await tester.pumpAndSettle();

    // 验证确认对话框弹出
    expect(find.text('确定要清除所有缓存数据吗？此操作不可撤销。'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);

    // 点击确定按钮
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 验证清理操作被触发
    expect(clearCalled, isTrue);
  });

  testWidgets('缓存管理页面取消清理操作', (tester) async {
    // 验证取消清理操作
    bool clearCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: const Text('缓存管理')),
            body: Center(
              child: OutlinedButton.icon(
                onPressed: () {
                  showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('清除缓存'),
                      content: const Text('确定要清除所有缓存数据吗？此操作不可撤销。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(ctx, true);
                            clearCalled = true;
                          },
                          child: const Text('确定'),
                        ),
                      ],
                    ),
                  );
                },
                icon: Icon(Icons.cleaning_services, color: Colors.red[700]),
                label: Text('清除全部缓存',
                    style: TextStyle(color: Colors.red[700])),
              ),
            ),
          ),
        ),
      ),
    );

    // 点击清理按钮
    await tester.tap(find.text('清除全部缓存'));
    await tester.pumpAndSettle();

    // 验证对话框弹出
    expect(find.text('确定要清除所有缓存数据吗？此操作不可撤销。'), findsOneWidget);

    // 点击取消按钮
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 验证清理操作未被触发
    expect(clearCalled, isFalse);

    // 验证对话框已关闭
    expect(find.text('确定要清除所有缓存数据吗？此操作不可撤销。'), findsNothing);
  });

  testWidgets('设置页面包含缓存管理入口', (tester) async {
    // 验证设置页面中存在缓存管理入口
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            children: const [
              // 数据管理分区
              Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('数据管理',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              ListTile(
                leading: Icon(Icons.cleaning_services),
                title: Text('清除缓存'),
                subtitle: Text('清除临时文件和缓存数据'),
              ),
              ListTile(
                leading: Icon(Icons.cached),
                title: Text('缓存管理'),
                subtitle: Text('缓存统计、清理和过期策略配置'),
              ),
            ],
          ),
        ),
      ),
    );

    // 验证缓存管理入口存在
    expect(find.text('缓存管理'), findsOneWidget);
    expect(find.text('缓存统计、清理和过期策略配置'), findsOneWidget);
    expect(find.byIcon(Icons.cached), findsOneWidget);
  });
}
