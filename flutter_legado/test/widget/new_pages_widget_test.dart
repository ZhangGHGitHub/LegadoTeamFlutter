import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_manage_screen.dart';
import 'package:flutter_legado/src/screens/remote_book_screen.dart';
import 'package:flutter_legado/src/screens/rss_screen.dart';

import '../mocks/mocks.dart';

/// 近期新增页面（书架管理/远程导入）与订阅主页入口 widget 深度测试
///
/// 覆盖真实渲染分支：加载/空态/错误/列表/交互（勾选/全选/操作栏/导入反馈）。
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

  group('BookshelfManageScreen', () {
    testWidgets('加载书籍列表并显示书名/作者', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => const [
            Book(bookUrl: 'u1', name: '斗破苍穹', author: '天蚕土豆'),
            Book(bookUrl: 'u2', name: '完美世界', author: '辰东'),
          ]);

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      // 顶栏内嵌搜索框（对标原版 view_search，无标题文字）
      expect(find.byType(TextField), findsOneWidget);
      expect(find.text('斗破苍穹'), findsOneWidget);
      expect(find.text('天蚕土豆'), findsOneWidget);
      expect(find.text('完美世界'), findsOneWidget);
    });

    testWidgets('空书架显示空态', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      expect(find.text('书架为空'), findsOneWidget);
    });

    testWidgets('加载失败显示错误与重试', (tester) async {
      when(() => mockApi.getBooks()).thenThrow(Exception('ffi'));

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.refresh), findsWidgets);
    });

    testWidgets('勾选书籍后显示底部操作栏（删除/分组/置顶）', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => const [
            Book(bookUrl: 'u1', name: '书一'),
          ]);

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      // 初始无操作栏
      expect(find.text('删除'), findsNothing);

      // 勾选第一本
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();

      // 底部操作栏显示已选数量（对标原版 SelectActionBar）
      expect(find.text('已选 1 本'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('分组'), findsOneWidget);
      expect(find.text('置顶'), findsOneWidget);
    });

    testWidgets('全选复选框勾选全部书籍', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => const [
            Book(bookUrl: 'u1', name: '书一'),
            Book(bookUrl: 'u2', name: '书二'),
          ]);

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      // 先勾选第一本，底部操作栏出现
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选 1 本'), findsOneWidget);

      // 底栏末尾的全选复选框勾选全部书籍
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(find.text('已选 2 本'), findsOneWidget);

      // 再次点击取消全选，操作栏消失
      await tester.tap(find.byType(Checkbox).last);
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsNothing);
    });

    testWidgets('置顶选中书籍调用 topBook', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => const [
            Book(bookUrl: 'u1', name: '书一'),
          ]);
      when(() => mockApi.topBook(any())).thenAnswer((_) async {});

      await tester.pumpWidget(wrap(const BookshelfManageScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('置顶'));
      await tester.pumpAndSettle();

      verify(() => mockApi.topBook('u1')).called(1);
      expect(find.text('已置顶'), findsOneWidget);
    });
  });

  group('RemoteBookScreen', () {
    testWidgets('渲染输入区与导入按钮', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);

      await tester.pumpWidget(wrap(const RemoteBookScreen()));
      await tester.pump();

      expect(find.text('远程书籍导入'), findsOneWidget);
      expect(find.text('导入到书架'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('无有效链接导入给出错误提示', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);

      await tester.pumpWidget(wrap(const RemoteBookScreen()));
      await tester.pump();

      await tester.enterText(find.byType(TextField), '随便一些文字');
      await tester.tap(find.text('导入到书架'));
      await tester.pumpAndSettle();

      expect(find.textContaining('未找到有效的书籍链接'), findsOneWidget);
      verifyNever(() => mockApi.importBooks(any()));
    });

    testWidgets('有效链接导入成功反馈数量并调用契约', (tester) async {
      when(() => mockApi.getBooks()).thenAnswer((_) async => []);
      when(() => mockApi.importBooks(any())).thenAnswer((_) async => 1);

      await tester.pumpWidget(wrap(const RemoteBookScreen()));
      await tester.pump();

      await tester.enterText(
        find.byType(TextField),
        'https://example.com/book/1',
      );
      await tester.tap(find.text('导入到书架'));
      await tester.pumpAndSettle();

      verify(() => mockApi.importBooks(any())).called(1);
      expect(find.text('成功导入 1 本书'), findsOneWidget);
    });
  });

  group('RssScreen 阅读记录对话框', () {
    testWidgets('历史入口打开阅读记录对话框并渲染记录', (tester) async {
      when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
      when(() => mockApi.rssListReadRecords(any())).thenAnswer((_) async => [
            {
              'origin': 'https://rss.example.com/feed',
              'title': '文章一',
              'read_time': 1750000000000,
            },
          ]);

      await tester.pumpWidget(wrap(const RssScreen()));
      await tester.pumpAndSettle();

      // 顶栏 4 入口（对标原版 main_rss.xml）
      await tester.tap(find.byIcon(Icons.history));
      await tester.pumpAndSettle();

      expect(find.text('阅读记录'), findsOneWidget);
      expect(find.text('文章一'), findsOneWidget);
      expect(find.textContaining('rss.example.com'), findsOneWidget);
      expect(find.text('清除'), findsOneWidget);
    });

    testWidgets('空记录显示空态且清除禁用', (tester) async {
      when(() => mockApi.getRssSources()).thenAnswer((_) async => []);
      when(() => mockApi.rssListReadRecords(any()))
          .thenAnswer((_) async => []);

      await tester.pumpWidget(wrap(const RssScreen()));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.history));
      await tester.pumpAndSettle();

      expect(find.text('暂无阅读记录'), findsOneWidget);
      // 清除按钮禁用（TextButton onPressed null）
      final clearButton = tester.widget<TextButton>(
        find
            .ancestor(
              of: find.text('清除'),
              matching: find.byType(TextButton),
            )
            .first,
      );
      expect(clearButton.onPressed, isNull);
    });
  });
}
