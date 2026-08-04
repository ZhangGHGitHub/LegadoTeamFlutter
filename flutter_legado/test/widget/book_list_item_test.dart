import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/widgets/book_list_item.dart';

/// BookListItem 结构与角标验证（对标 item_bookshelf_list.xml）
void main() {
  Widget wrap(Book book, {VoidCallback? onTap, VoidCallback? onLongPress}) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            BookListItem(
              book: book,
              onTap: onTap,
              onLongPress: onLongPress,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('已读书籍渲染四行信息与进度条/百分比', (tester) async {
    final book = Book(
      bookUrl: 'u1',
      name: '斗破苍穹',
      author: '天蚕土豆',
      totalChapterNum: 101,
      durChapterIndex: 50,
      durChapterPos: 10,
      durChapterTitle: '第五十章 修炼',
      latestChapterTitle: '第一百零一章 大结局',
      latestChapterTime: DateTime.now().millisecondsSinceEpoch - 3600 * 1000,
    );
    await tester.pumpWidget(wrap(book));

    // 书名 / 作者 / 阅读章节 / 最新章节
    expect(find.text('斗破苍穹'), findsOneWidget);
    expect(find.text('天蚕土豆'), findsOneWidget);
    expect(find.text('第五十章 修炼'), findsOneWidget);
    expect(find.text('第一百零一章 大结局'), findsOneWidget);
    // 阅读百分比（50/100 = 50%）
    expect(find.text('50%'), findsOneWidget);
    // 底部阅读进度条
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 无未读（totalChapterNum - durChapterIndex - 1 = 50 > 0 时才有角标）
    expect(find.text('50'), findsOneWidget); // 未读角标 50
  });

  testWidgets('未读书籍隐藏进度条/阅读行，无进度百分比', (tester) async {
    final book = Book(
      bookUrl: 'u2',
      name: '未读书籍',
      author: '佚名',
      totalChapterNum: 10,
      durChapterIndex: 0,
      durChapterPos: 0,
      latestChapterTitle: '第十章 终章',
      latestChapterTime: DateTime.now().millisecondsSinceEpoch - 86400 * 1000,
    );
    await tester.pumpWidget(wrap(book));

    expect(find.text('未读书籍'), findsOneWidget);
    expect(find.text('第十章 终章'), findsOneWidget);
    // 无阅读记录：进度条与百分比不显示
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.textContaining('%'), findsNothing);
    // 未读角标：10 - 0 - 1 = 9
    expect(find.text('9'), findsOneWidget);
  });

  testWidgets('无最新章节时隐藏最新章节行', (tester) async {
    final book = Book(
      bookUrl: 'u3',
      name: '无章节信息',
      author: '佚名',
      totalChapterNum: 0,
      durChapterIndex: 0,
      durChapterPos: 0,
    );
    await tester.pumpWidget(wrap(book));

    expect(find.text('无章节信息'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    // 未读数为 0 → 无角标
    expect(find.text('0'), findsNothing);
  });

  testWidgets('点击与长按回调', (tester) async {
    var tapped = false;
    var longPressed = false;
    final book = Book(bookUrl: 'u4', name: '交互测试');
    await tester.pumpWidget(
      wrap(book, onTap: () => tapped = true, onLongPress: () => longPressed = true),
    );

    await tester.tap(find.text('交互测试'));
    expect(tapped, isTrue);

    await tester.longPress(find.text('交互测试'));
    expect(longPressed, isTrue);
  });
}
