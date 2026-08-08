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

    // [UI-fix v2.0.6 | 2026-08-08] 对齐原版：详情页目录行只显示当前章节名 +
    // 「查看目录」按钮，不再内嵌完整章节列表（列表移至独立 TocScreen） — Qoder
    testWidgets('目录行显示当前章节名与「查看目录」按钮（不内嵌章节列表）',
        (tester) async {
      when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => const [
            BookChapter(bookUrl: 'https://src.com/book/1', index: 0, title: '第一章 开端'),
            BookChapter(bookUrl: 'https://src.com/book/1', index: 1, title: '第二章 发展'),
          ]);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      // 书详页头部较高（居中封面卡 + 信息面板），目录行在首屏外，先滚动
      final tocRow = find.textContaining('第一章 开端');
      await tester.dragUntilVisible(
        tocRow,
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      // 目录行对齐原版：显示当前章节名（durChapterIndex=0 → 第一章）+「查看目录」按钮
      expect(tocRow, findsWidgets);
      expect(find.text('查看目录'), findsOneWidget);
      // 详情页不再内嵌完整章节列表（第二章仅存在于独立目录页）
      expect(find.textContaining('第二章 发展'), findsNothing);
    });

    // [UI-fix v2.0.7 | 2026-08-08] 对齐原版简介区：无「简介」标题、无「简介：」
    // 前缀、省略号硬截断改为可展开/收起（右对齐主题色切换） — Qoder
    testWidgets('简介区无「简介」标题与「简介：」前缀，支持展开/收起',
        (tester) async {
      // 折叠/展开是否显示切换控件取决于「折叠 3 行是否截断正文」（TextPainter 实测），
      // 与屏幕宽度相关；故固定为手机窗口尺寸，并让 intro 足够长以稳定超过 3 行
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 书源 intro 自带「简介：」前缀 + 足够长（清洗后远超折叠 3 行）以触发展开/收起控件
      const introBody = '灵气复苏的世界主角觉醒吞噬系统一路高歌猛进不断变强战胜强敌'
          '守护身边之人最终登临绝巅笑傲苍穹的热血玄幻长篇故事精彩纷呈引人入胜'
          '天赋异禀奇遇连连历经磨难终成大道恩怨情仇跌宕起伏令人拍案叫绝欲罢不能'
          '再攀高峰续写传奇书写属于自己的不朽神话篇章荧屏前精彩不容错过'
          '风起云涌群雄逐鹿一步步揭开上古秘辛探寻天地至理感悟大道真意'
          '身负血海深仇却始终坚守本心以无上意志碾碎一切阻碍勇往直前';
      const bookWithIntro = Book(
        bookUrl: 'https://src.com/book/2',
        name: '测试书籍',
        author: '测试作者',
        intro: '简介：$introBody',
        origin: 'https://src.com',
        originName: '测试源',
      );
      when(() => mockApi.getBook(any()))
          .thenAnswer((_) async => bookWithIntro);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => const []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: bookWithIntro)));
      await tester.pumpAndSettle();

      // 滚动到简介区的「展开」控件
      final toggle = find.text('展开');
      await tester.dragUntilVisible(
        toggle,
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      // 无「简介」标题 heading、无「简介：」前缀（展示层已清洗）
      expect(find.text('简介'), findsNothing);
      expect(find.textContaining('简介：'), findsNothing);
      // 正文按清洗后内容显示（不含前缀）
      expect(find.textContaining(introBody), findsWidgets);
      // 折叠态显示「展开」，点击后切换为「收起」
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('收起'), findsOneWidget);
      expect(find.text('展开'), findsNothing);
    });
  });
}
