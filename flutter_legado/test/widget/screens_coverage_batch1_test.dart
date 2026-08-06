import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';

import '../mocks/mocks.dart';

/// screens 层深度覆盖第一批（§9.5 覆盖率推进）：
/// BookGroupScreen / BookInfoScreen
// [UI-fix v2.0.2 | 2026-08-06] 结构治理：RssConfigScreen 已删除，同步移除其测试组 — Qoder
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  group('BookGroupScreen', () {
    void stubBooks(List<Book> books) {
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
    }

    testWidgets('渲染分组列表（名称/书籍数）', (tester) async {
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const [
            BookGroup(groupId: 1, groupName: '武侠', order: 0),
            BookGroup(groupId: 2, groupName: '科幻', order: 1),
          ]);
      stubBooks(const [Book(bookUrl: 'u1', name: '书一', group: 1)]);

      await tester.pumpWidget(wrap(const BookGroupScreen()));
      await tester.pumpAndSettle();

      expect(find.text('分组管理'), findsOneWidget);
      expect(find.text('武侠'), findsOneWidget);
      expect(find.text('科幻'), findsOneWidget);
    });

    testWidgets('空分组显示空态', (tester) async {
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
      stubBooks([]);

      await tester.pumpWidget(wrap(const BookGroupScreen()));
      await tester.pumpAndSettle();

      expect(find.text('还没有分组'), findsOneWidget);
    });

    testWidgets('加载失败显示错误与重试', (tester) async {
      when(() => mockApi.getBookGroups()).thenThrow(Exception('ffi'));
      stubBooks([]);

      await tester.pumpWidget(wrap(const BookGroupScreen()));
      await tester.pumpAndSettle();

      expect(find.text('重试'), findsOneWidget);
    });

    testWidgets('新建分组对话框保存调用 addBookGroup', (tester) async {
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
      when(() => mockApi.addBookGroup(any()))
          .thenAnswer((_) async => const BookGroup(groupName: '新分组'));
      stubBooks([]);

      await tester.pumpWidget(wrap(const BookGroupScreen()));
      await tester.pumpAndSettle();

      // 点击 FAB 打开新建对话框
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.text('新建分组'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '分组名称'),
        '新分组',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final captured = verify(() => mockApi.addBookGroup(captureAny()))
          .captured
          .single as BookGroup;
      expect(captured.groupName, equals('新分组'));
    });

    testWidgets('删除分组确认后调用 deleteBookGroup', (tester) async {
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const [
            BookGroup(groupId: 7, groupName: '待删', order: 0),
          ]);
      when(() => mockApi.deleteBookGroup(any())).thenAnswer((_) async {});
      stubBooks([]);

      await tester.pumpWidget(wrap(const BookGroupScreen()));
      await tester.pumpAndSettle();

      // 分组项的更多菜单（删除入口）
      await tester.tap(find.byIcon(Icons.more_vert).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();

      // 确认对话框
      await tester.tap(find.text('删除').last);
      await tester.pumpAndSettle();

      verify(() => mockApi.deleteBookGroup(7)).called(1);
    });
  });

  group('BookInfoScreen', () {
    const book = Book(
      bookUrl: 'https://src.com/book/1',
      name: '测试书籍',
      author: '测试作者',
      intro: '这是一段简介文本，用于验证书籍详情页渲染。',
      origin: 'https://src.com',
      originName: '测试源',
    );

    testWidgets('渲染书名/作者/简介（getBook 兜底 widget.book）',
        (tester) async {
      when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      expect(find.text('测试书籍'), findsWidgets);
      expect(find.textContaining('测试作者'), findsWidgets);
    });

    testWidgets('渲染章节目录', (tester) async {
      when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => const [
            BookChapter(bookUrl: 'https://src.com/book/1', index: 0, title: '第一章 开端'),
            BookChapter(bookUrl: 'https://src.com/book/1', index: 1, title: '第二章 发展'),
          ]);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      // 书详页头部较高（居中封面卡 + 信息面板），章节列表在首屏外，先滚动
      final firstChapter = find.textContaining('第一章 开端');
      await tester.dragUntilVisible(
        firstChapter,
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      expect(firstChapter, findsWidgets);
      expect(find.textContaining('第二章 发展'), findsWidgets);
    });
  });
}
