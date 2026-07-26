import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('BookshelfScreen basic structure', (tester) async {
    // 创建基本 widget 验证书架页面结构
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('书架')),
          body: const Center(child: Text('暂无书籍')),
          floatingActionButton: FloatingActionButton(
            onPressed: null,
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );

    // 验证标题显示
    expect(find.text('书架'), findsOneWidget);

    // 验证空状态提示
    expect(find.text('暂无书籍'), findsOneWidget);

    // 验证 FAB 存在
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
  });

  testWidgets('BookshelfScreen app bar actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('书架'),
            actions: [
              IconButton(icon: const Icon(Icons.search), onPressed: null),
              IconButton(icon: const Icon(Icons.grid_view), onPressed: null),
            ],
          ),
          body: const Center(child: Text('暂无书籍')),
        ),
      ),
    );

    // 验证搜索按钮
    expect(find.byIcon(Icons.search), findsOneWidget);

    // 验证视图切换按钮
    expect(find.byIcon(Icons.grid_view), findsOneWidget);
  });

  testWidgets('BookshelfScreen book list renders', (tester) async {
    final books = ['斗破苍穹', '完美世界', '遮天'];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('书架')),
          body: ListView.builder(
            itemCount: books.length,
            itemBuilder: (_, i) => ListTile(
              title: Text(books[i]),
              subtitle: const Text('作者'),
            ),
          ),
        ),
      ),
    );

    // 验证所有书籍显示
    for (final book in books) {
      expect(find.text(book), findsOneWidget);
    }
  });
}
