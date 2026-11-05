import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/bookshelf_settings.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/utils/time_utils.dart';
import 'package:flutter_legado/src/widgets/book_cover.dart';
import 'package:flutter_legado/src/widgets/book_display_tags_row.dart';
import 'package:flutter_legado/src/widgets/book_list_item.dart';

/// BookListItem 结构与角标验证（对标 item_bookshelf_list.xml）
void main() {
  Widget wrap(
    Book book, {
    VoidCallback? onTap,
    VoidCallback? onLongPress,
    BookshelfSettings settings = BookshelfSettings.defaults,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            BookListItem(
              book: book,
              settings: settings,
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
    // [设置批6a-1] 最新章节属「更多信息」子项，显式开启后验证
    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(showBookIntro: true),
    ));

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
    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(showBookIntro: true),
    ));

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

  // ===== [批35] 展示标签行 =====

  Widget wrapWithTags(Book book, List<String> tags) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [BookListItem(book: book, tags: tags)],
        ),
      ),
    );
  }

  testWidgets('传入标签时列表行渲染标签条（阅读章节之后）', (tester) async {
    final book = Book(
      bookUrl: 'u5',
      name: '标签书',
      durChapterTitle: '第一章',
      latestChapterTitle: '第二章',
    );
    await tester.pumpWidget(wrapWithTags(book, ['仙侠', '玄幻', '12万字']));

    expect(find.text('仙侠'), findsOneWidget);
    expect(find.text('玄幻'), findsOneWidget);
    expect(find.text('12万字'), findsOneWidget);
    expect(find.byType(BookDisplayTagsRow), findsOneWidget);
  });

  testWidgets('空标签列表不渲染标签行（空值不占位）', (tester) async {
    final book = Book(bookUrl: 'u6', name: '无标签');
    await tester.pumpWidget(wrapWithTags(book, const []));

    expect(find.byType(BookDisplayTagsRow), findsNothing);
  });

  testWidgets('列表封面宽/分隔线/卡片色按设置渲染', (tester) async {
    final book = Book(bookUrl: 'u7', name: '设置书', author: '作者');
    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(
        bookshelfListCoverWidth: 100,
        bookshelfShowDivider: false,
        bookshelfCardColor: 0xFF112233,
      ),
    ));

    final cover = tester.widget<BookCover>(find.byType(BookCover));
    expect(cover.width, 100);
    expect(find.byType(Divider), findsNothing);
    expect(
      find.byWidgetPredicate(
          (w) => w is Material && w.color == const Color(0xFF112233)),
      findsOneWidget,
    );

    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(bookshelfShowDivider: true),
    ));
    expect(find.byType(Divider), findsOneWidget);
  });

  testWidgets('简介显示位置与行数（内容内 / 内容下方）', (tester) async {
    final book = Book(
      bookUrl: 'u8',
      name: '简介书',
      author: '作者',
      intro: '<p>第一段简介</p><p>第二段</p>',
    );
    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(
        showBookIntro: true,
        bookshelfShowIntro: true,
        bookshelfIntroMaxLines: 1,
      ),
    ));
    final intro = tester.widget<Text>(find.textContaining('第一段简介'));
    expect(intro.maxLines, 1);

    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(
        showBookIntro: true,
        bookshelfShowIntro: true,
        bookshelfListIntroBelowContent: true,
      ),
    ));
    expect(find.textContaining('第一段简介'), findsOneWidget);
  });

  testWidgets('列表封面垂直居中可关闭', (tester) async {
    final book = Book(bookUrl: 'u9', name: '对齐书', author: '作者');
    await tester.pumpWidget(wrap(book));
    var row = tester.widget<Row>(find.byType(Row).first);
    expect(row.crossAxisAlignment, CrossAxisAlignment.center);

    await tester.pumpWidget(wrap(
      book,
      settings: const BookshelfSettings(bookshelfListCoverCenter: false),
    ));
    row = tester.widget<Row>(find.byType(Row).first);
    expect(row.crossAxisAlignment, CrossAxisAlignment.start);
  });

  testWidgets('上次更新时间仅在开启且非本地书时显示', (tester) async {
    final millis = DateTime.now().millisecondsSinceEpoch - 3600 * 1000;
    final online = Book(
      bookUrl: 'https://example.com/book',
      name: '在线书',
      author: '作者',
      origin: 'https://example.com',
      latestChapterTitle: '最新章',
      latestChapterTime: millis,
    );
    await tester.pumpWidget(wrap(
      online,
      settings: const BookshelfSettings(
        showBookIntro: true,
        bookshelfShowLatestChapter: true,
        showLastUpdateTime: true,
      ),
    ));
    expect(find.text(timeAgo(millis)), findsOneWidget);

    final local = online.copyWith(origin: 'loc_book');
    await tester.pumpWidget(wrap(
      local,
      settings: const BookshelfSettings(
        showBookIntro: true,
        bookshelfShowLatestChapter: true,
        showLastUpdateTime: true,
      ),
    ));
    expect(find.text(timeAgo(millis)), findsNothing);
  });
}
