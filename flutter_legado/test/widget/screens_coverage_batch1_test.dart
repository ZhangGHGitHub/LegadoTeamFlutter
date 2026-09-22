import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/audio/audio_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/audio_screen.dart';
import 'package:flutter_legado/src/screens/book_group_screen.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/audio_service.dart';

import '../mocks/mocks.dart';

/// 记录 push 的路由名（分流断言用）
class _PushedRouteObserver extends NavigatorObserver {
  final List<String> pushed;
  _PushedRouteObserver(this.pushed);

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name ?? '');
  }
}

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
    final mockAudio = MockAudioService();
    when(() => mockAudio.init()).thenAnswer((_) async {});
    when(() => mockAudio.isInitialized).thenReturn(false);
    when(() => mockAudio.dispose()).thenAnswer((_) async {});
    when(() => mockAudio.mediaButtonStream)
        .thenAnswer((_) => const Stream<MediaButtonEvent>.empty());
    when(() => mockAudio.audioFocusStream)
        .thenAnswer((_) => const Stream<AudioFocusEvent>.empty());
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(mockApi),
        audioServiceProvider.overrideWithValue(mockAudio),
      ],
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

    // [08 元信息区对齐 | 台账 0922 修订] 独立「目录：」行已移除（参考 08
    // 无此行）：目录入口仅保留四按钮「查看目录」卡；详情页仍不内嵌完整
    // 章节列表（列表在独立 TocScreen）；章数由「共 N 章」行承载
    testWidgets('目录入口仅「查看目录」卡（独立目录行已移除，不内嵌章节列表）',
        (tester) async {
      when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => const [
            BookChapter(bookUrl: 'https://src.com/book/1', index: 0, title: '第一章 开端'),
            BookChapter(bookUrl: 'https://src.com/book/1', index: 1, title: '第二章 发展'),
          ]);
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
      when(() => mockApi.getBooks()).thenAnswer((_) async => const []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      // 独立「目录：」行不再渲染；目录入口唯一（四按钮卡）
      expect(find.textContaining('目录：'), findsNothing);
      expect(find.text('查看目录'), findsOneWidget);
      // 原「已读: X%」进度显示随目录行移除（台账 0922 功能入口去向登记）
      expect(find.textContaining('已读:'), findsNothing);
      // 仍不内嵌完整章节列表；末章标题不渲染
      final list = find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(ListView),
      );
      expect(list, findsNothing);
      expect(find.textContaining('第二章 发展'), findsNothing);
      // 章数由「共 N 章」行承载（totalChapterNum 缺省回落目录长度 2、
      // durChapterIndex=0 → 未读）
      expect(find.textContaining('共 2 章'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('目录为空时点击「查看目录」提示目录为空', (tester) async {
      when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => []);
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
      when(() => mockApi.getBooks()).thenAnswer((_) async => const []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: book)));
      await tester.pumpAndSettle();

      // [台账 0922 修订] 独立目录行移除后「查看目录」唯一（四按钮卡），
      // 直接定位；空目录点卡弹「目录为空」
      expect(find.text('查看目录'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('查看目录'),
        find.byType(CustomScrollView),
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看目录'));
      await tester.pumpAndSettle();
      expect(find.text('目录为空'), findsOneWidget);
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

      // 滚动到简介区的「收起」控件（默认展开，[UI-fix v2.0.11]）
      final toggle = find.text('收起');
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
      // 默认展开态显示「收起」，点击后切换为「展开」
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(find.text('展开'), findsOneWidget);
      expect(find.text('收起'), findsNothing);
    });

    // [08 元信息区对齐 | 台账 0922 修订] 详情页版块顺序（对齐参考 08 元素集）：
    // ① chips 行（kind chips + 字数，分组 chip 条件显示）→
    // ② 四按钮卡 → ③ 在读/最新/共N章三行块 → ④ 简介（面板内）。
    // 参考 08 无独立「目录：」行、「分组：」行、「🏷️ 标签行」——去噪后
    // 以各版块文本节点 y 坐标断言纵向顺序
    // （chips y < 四按钮 y < 在读 y < 简介 y），并断言三行均不渲染
    testWidgets('版块顺序：chips<四按钮<在读/最新<简介（无目录/分组/标签行）',
        (tester) async {
      // 高视口保证全部版块同帧布局（CustomScrollView 视口外 sliver 不构建）
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 数据齐备：chips 行（kind 逐项 + 字数）+ 在读/最新/共N章 + 简介 全渲染
      const orderBook = Book(
        bookUrl: 'https://src.com/book/order',
        name: '序书',
        author: '作者',
        origin: 'https://src.com',
        originName: '测试源',
        kind: '9.9分,轻小说,已完结',
        wordCount: '120万字',
        totalChapterNum: 51,
        durChapterIndex: 1,
        durChapterTitle: '第一章 开端',
        latestChapterTitle: '第五十一章 完结',
        intro: '版块顺序验证简介正文。',
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => orderBook);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => const [
            BookChapter(
                bookUrl: 'https://src.com/book/order',
                index: 0,
                title: '第一章 开端'),
          ]);
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
      when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: orderBook)));
      await tester.pumpAndSettle();

      // ① chips 行在屏（kind 逐项成 chip + 字数 chip；chips 无章数项）
      expect(find.text('9.9分'), findsOneWidget);
      expect(find.text('轻小说'), findsOneWidget);
      expect(find.text('120万字'), findsOneWidget);
      expect(find.text('51章'), findsNothing);
      // ② 四按钮（独立目录行移除后「查看目录」唯一，即卡内一处）
      expect(find.text('查看目录'), findsOneWidget);
      final yButtons = tester.getTopLeft(find.text('查看目录')).dy;
      // ③ 在读/最新/共N章三行块（[P2-21] 形态对齐参考：在读行
      // 「在读 · {存储标题}」、最新行「最新 · {latestChapterTitle}」）
      final yReading = tester
          .getTopLeft(find.textContaining('在读 · 第一章 开端')).dy;
      expect(find.textContaining('最新 · 第五十一章 完结'), findsOneWidget);
      expect(find.textContaining('共 51 章'), findsOneWidget);
      // ④ 简介（展开态双 Text 同位，取 .first）
      final yIntro = tester
          .getTopLeft(find.textContaining('版块顺序验证简介正文。').first)
          .dy;

      // 去噪三行均不渲染（目录入口在 ② 卡内、分组信息入 ① chips 行、
      // kind 信息即 ① chips 行逐项）
      expect(find.textContaining('目录：'), findsNothing);
      expect(find.textContaining('分组：'), findsNothing);
      expect(find.textContaining('🏷️'), findsNothing);

      final yChips = tester.getTopLeft(find.text('9.9分')).dy;
      expect(yChips, lessThan(yButtons)); // ① 在 ② 之上
      expect(yButtons, lessThan(yReading)); // ② 在 ③ 之上
      expect(yReading, lessThan(yIntro)); // ③ 在 ④ 之上
      expect(tester.takeException(), isNull);
    });

    // [08 元信息区对齐 | 台账 0922 修订] chips 行横排回归守卫（U13 标签行
    // 后续）：原「🏷️ 前缀 + 逗号连排」标签行已移除（参考 08 无此行），
    // kind 信息改由 chips 行逐项渲染（每 kind 一枚 TextCard 形态 chip，
    // 横向单行滚动、不竖排）。断言：全部 kind 在屏（勿丢数据）+
    // 相邻 chip 同行（|Δy|≤2）+ 整行仅占 1 个纵向行（非竖排 9 行）
    testWidgets('chips 行横排连排：chip 同行非竖排且无数据丢失', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const tagBook = Book(
        bookUrl: 'https://src.com/book/tags',
        name: '标签书',
        author: '作者',
        origin: 'https://src.com',
        originName: '测试源',
        kind: '奇幻,武侠,历史,都市,科幻,悬疑,游戏,其他,言情',
        totalChapterNum: 51,
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => tagBook);
      when(() => mockApi.getChapters(any())).thenAnswer((_) async => const []);
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
      when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: tagBook)));
      await tester.pumpAndSettle();

      const tags = [
        '奇幻', '武侠', '历史', '都市', '科幻',
        '悬疑', '游戏', '其他', '言情',
      ];
      // 🏷️ 前缀标签行已移除；9 个 kind chip 全部渲染（勿丢数据）
      expect(find.textContaining('🏷️'), findsNothing);
      for (final t in tags) {
        expect(find.text(t), findsOneWidget, reason: 'chip $t 缺失');
      }
      // 横排连排：「奇幻」「武侠」同行（|Δy|≤2，严于验收 |Δy|≤20）
      final yA = tester.getTopLeft(find.text('奇幻')).dy;
      final yB = tester.getTopLeft(find.text('武侠')).dy;
      expect((yA - yB).abs(), lessThanOrEqualTo(2),
          reason: '相邻 chip 必须同行（横排连排，非竖排）');
      // 非竖排：全部 chip 同处 1 个纵向行（横向单行滚动；
      // 竖排=9 行、多行换行=2+ 行均失败）
      final ys = tags
          .map((t) => tester.getTopLeft(find.text(t)).dy)
          .toSet();
      expect(ys.length, equals(1),
          reason: 'chips 行应横向单行滚动，不应每 chip 独占一行竖排');
      expect(tester.takeException(), isNull);
    });

    // [E5 | 台账 0917 反馈批四][P2-21] 最新行补章节名：部分书源
    // latestChapterTitle 返回状态词（如「已完结」，参考实测缺章节名），
    // 回落目录末章真实标题（与在读行同源）；[P2-21] 形态对齐参考
    // 「最新 · %s」：无「第N章」前缀、无代码追加「（全书完）」后缀
    // （参考 dump 中该后缀为站点标题自带，非代码行为）；目录无标题数据
    // 时保持现状（不丢行、不造占位）
    testWidgets('E5 最新行：状态词回落目录末章标题（无第N章前缀/无全书完后缀）',
        (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const e5Book = Book(
        bookUrl: 'https://src.com/book/e5',
        name: 'E5书',
        author: '作者',
        origin: 'https://src.com',
        originName: '测试源',
        kind: '奇幻,武侠,历史,都市,科幻,悬疑,游戏,其他,言情',
        totalChapterNum: 51,
        latestChapterTitle: '已完结', // 状态词而非章节标题
      );
      when(() => mockApi.getBook(any())).thenAnswer((_) async => e5Book);
      when(() => mockApi.getChapters(any())).thenAnswer(
          (_) async => List.generate(
                51,
                (i) => BookChapter(
                    bookUrl: 'https://src.com/book/e5',
                    index: i,
                    title: i == 50 ? '第五十一章 大结局' : '第${i + 1}章'),
              ));
      when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
      when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);

      await tester.pumpWidget(wrap(const BookInfoScreen(book: e5Book)));
      await tester.pumpAndSettle();

      // 最新行 = 「最新 · 第五十一章 大结局」：补章节标题，状态词不再充当
      // 章节名；[P2-21] 无「第51章」前缀、无代码追加「（全书完）」后缀
      expect(
          find.textContaining('最新 · 第五十一章 大结局'), findsOneWidget);
      expect(find.textContaining('（全书完）'), findsNothing);
      expect(find.textContaining('第51章'), findsNothing);
      expect(find.textContaining('最新 · 已完结'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // [UI-fix v2.0.11 | 2026-08-10] 按书籍类型分流阅读器（对齐原版
    // BookInfoActivity.startReadActivity：audio→/audio、image→/reader-comic、
    // 文本→/reader）；bookType 为位标记（text=8/audio=32/image=64）— Reasonix
    group('开始阅读按类型分流', () {
      final pushed = <String>[];

      Widget wrapWithRoutes(Widget child) {
        pushed.clear();
        final observer = _PushedRouteObserver(pushed);
        // 分流断言只关心路由名；reader/video 用桩页规避测试环境
        // Theme.of / video_player 副作用（真实页由专项测试覆盖）
        final routes = Map<String, WidgetBuilder>.from(AppRoutes.routes)
          ..remove('/');
        routes[AppRoutes.reader] = (_) => const Scaffold(
              key: Key('reader-stub'),
              body: Text('文本阅读页'),
            );
        routes[AppRoutes.video] = (_) => const Scaffold(
              key: Key('video-stub'),
              body: Text('视频播放页'),
            );
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: child,
            routes: routes,
            navigatorObservers: [observer],
          ),
        );
      }

      void stubCommon(Book book) {
        when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
        when(() => mockApi.getChapters(any())).thenAnswer((_) async => const [
              BookChapter(
                  bookUrl: 'u1', index: 0, title: '第一章', url: 'c1'),
            ]);
        when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
        when(() => mockApi.fetchChapterContent(any(), any(), any()))
            .thenAnswer((_) async => '正文内容');
        when(() => mockApi.getChapterContent(any(), any()))
            .thenAnswer((_) async => '正文内容');
        when(() => mockApi.addBook(any())).thenAnswer((inv) async {
          return inv.positionalArguments[0] as Book;
        });
        when(() => mockApi.updateBook(any())).thenAnswer((_) async {});
        when(() => mockApi.refreshToc(any(), any()))
            .thenAnswer((_) async => []);
      }

      testWidgets('音频书（bookType=32）进入音频播放页', (tester) async {
        const book = Book(bookUrl: 'u1', name: '听书', bookType: 32);
        stubCommon(book);
        await tester
            .pumpWidget(wrapWithRoutes(const BookInfoScreen(book: book)));
        await tester.pumpAndSettle();

        await tester.tap(find.descendant(of: find.byType(FloatingActionButton), matching: find.text('阅读')));
        await tester.pumpAndSettle();

        expect(pushed, contains(AppRoutes.audio));
        // 返回详情页，避免媒体会话副作用
        Navigator.of(tester.element(find.byType(AudioScreen))).pop();
        await tester.pumpAndSettle();
      });

      testWidgets('图片书（bookType=64）进入漫画阅读页', (tester) async {
        const book = Book(bookUrl: 'u1', name: '漫画', bookType: 64);
        stubCommon(book);
        await tester
            .pumpWidget(wrapWithRoutes(const BookInfoScreen(book: book)));
        await tester.pumpAndSettle();

        await tester.tap(find.descendant(of: find.byType(FloatingActionButton), matching: find.text('阅读')));
        await tester.pumpAndSettle();

        expect(pushed, contains(AppRoutes.readerComic));
        Navigator.of(tester.element(find.byType(ReaderComicScreen))).pop();
        await tester.pumpAndSettle();
      });

      testWidgets('文本书（bookType=8）进入文本阅读页', (tester) async {
        const book = Book(bookUrl: 'u1', name: '文本书', bookType: 8);
        stubCommon(book);
        await tester
            .pumpWidget(wrapWithRoutes(const BookInfoScreen(book: book)));
        await tester.pumpAndSettle();

        await tester.tap(find.descendant(of: find.byType(FloatingActionButton), matching: find.text('阅读')));
        await tester.pumpAndSettle();

        expect(pushed, contains(AppRoutes.reader));
        expect(find.byKey(const Key('reader-stub')), findsOneWidget);
      });

      testWidgets('视频书（bookType=4）进入视频播放页', (tester) async {
        const book = Book(bookUrl: 'u1', name: '视频书', bookType: 4);
        stubCommon(book);
        await tester
            .pumpWidget(wrapWithRoutes(const BookInfoScreen(book: book)));
        await tester.pumpAndSettle();

        await tester.tap(find.descendant(of: find.byType(FloatingActionButton), matching: find.text('阅读')));
        await tester.pumpAndSettle();

        expect(pushed, contains(AppRoutes.video));
        expect(find.byKey(const Key('video-stub')), findsOneWidget);
      });

      testWidgets('已入库缺类型位（bookType=1024）时按书源类型分流图片书',
          (tester) async {
        // [UI-fix v2.0.12] 回归：搜索/旧库 type 缺失（0/仅 notShelf）时，
        // 按书源类型（bookSourceType=2 图片）补全类型位并分流 — Reasonix
        const book = Book(
            bookUrl: 'u1',
            name: '旧库漫画',
            bookType: BookType.notShelf, // 1024：缺类型位
            origin: 'https://manga-source.com');
        stubCommon(book);
        when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
        when(() => mockApi.getBookSources()).thenAnswer((_) async => [
              const BookSource(
                bookSourceUrl: 'https://manga-source.com',
                bookSourceName: '漫画源',
                bookSourceType: 2,
                enabled: true,
              ),
            ]);
        await tester
            .pumpWidget(wrapWithRoutes(const BookInfoScreen(book: book)));
        await tester.pumpAndSettle();

        await tester.tap(find.descendant(of: find.byType(FloatingActionButton), matching: find.text('阅读')));
        await tester.pumpAndSettle();

        // 类型位补全（64）→ 图片源分流到漫画页
        expect(pushed, contains(AppRoutes.readerComic));
        Navigator.of(tester.element(find.byType(ReaderComicScreen))).pop();
        await tester.pumpAndSettle();
      });
    });

    // [A4 对齐 B | 2026-09-21 裁决；2026-09-22 review 硬化]
    // openReaderImmediately（书架未读书单击 → 详情页 + 自动开读）：
    // 机会在首轮全量加载完成时无条件消费 + postFrame 栈顶守卫
    group('openReaderImmediately 自动开读', () {
      final pushed = <String>[];

      Widget wrapWithRoutes(Widget child) {
        pushed.clear();
        final observer = _PushedRouteObserver(pushed);
        final routes = Map<String, WidgetBuilder>.from(AppRoutes.routes)
          ..remove('/');
        routes[AppRoutes.reader] = (_) => const Scaffold(
              key: Key('reader-stub'),
              body: Text('文本阅读页'),
            );
        return UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: child,
            routes: routes,
            navigatorObservers: [observer],
          ),
        );
      }

      void stubAutoStart(Book book, List<BookChapter> chapters) {
        when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
        when(() => mockApi.getChapters(any()))
            .thenAnswer((_) async => chapters);
        when(() => mockApi.getBookSources()).thenAnswer((_) async => []);
        when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
        when(() => mockApi.fetchChapterContent(any(), any(), any()))
            .thenAnswer((_) async => '正文内容');
        when(() => mockApi.getChapterContent(any(), any()))
            .thenAnswer((_) async => '正文内容');
        when(() => mockApi.addBook(any())).thenAnswer((inv) async {
          return inv.positionalArguments[0] as Book;
        });
        when(() => mockApi.updateBook(any())).thenAnswer((_) async {});
        when(() => mockApi.refreshToc(any(), any()))
            .thenAnswer((_) async => const []);
      }

      testWidgets('正面：目录非空首轮加载后自动压栈阅读器', (tester) async {
        const book = Book(
            bookUrl: 'u1',
            name: '未读A4',
            bookType: 8,
            origin: 'https://src.com',
            originName: '测试源');
        stubAutoStart(book, const [
          BookChapter(bookUrl: 'u1', index: 0, title: '第一章', url: 'c1'),
          BookChapter(bookUrl: 'u1', index: 1, title: '第二章', url: 'c2'),
        ]);

        await tester.pumpWidget(wrapWithRoutes(
            const BookInfoScreen(book: book, openReaderImmediately: true)));
        await tester.pumpAndSettle();

        expect(pushed, contains(AppRoutes.reader));
        expect(find.byKey(const Key('reader-stub')), findsOneWidget);
      });

      testWidgets('负例：目录为空不自动开读，停留详情页', (tester) async {
        const book = Book(
            bookUrl: 'u2',
            name: '空目录A4',
            bookType: 8,
            origin: 'https://src.com',
            originName: '测试源');
        stubAutoStart(book, const []);

        await tester.pumpWidget(wrapWithRoutes(
            const BookInfoScreen(book: book, openReaderImmediately: true)));
        await tester.pumpAndSettle();

        expect(pushed, isNot(contains(AppRoutes.reader)));
        // 详情页仍在：书名渲染、无阅读器桩页
        expect(find.text('空目录A4'), findsWidgets);
        expect(find.byKey(const Key('reader-stub')), findsNothing);
      });

      testWidgets('守卫：自动开读返回后阅读器只被压栈一次', (tester) async {
        const book = Book(
            bookUrl: 'u3',
            name: '守卫A4',
            bookType: 8,
            origin: 'https://src.com',
            originName: '测试源');
        stubAutoStart(book, const [
          BookChapter(bookUrl: 'u3', index: 0, title: '第一章', url: 'c1'),
          BookChapter(bookUrl: 'u3', index: 1, title: '第二章', url: 'c2'),
        ]);

        await tester.pumpWidget(wrapWithRoutes(
            const BookInfoScreen(book: book, openReaderImmediately: true)));
        await tester.pumpAndSettle();
        expect(pushed.where((r) => r == AppRoutes.reader).length, 1);

        // 退出阅读器返回详情页（_openReader 尾部 _reload 触发二次加载，
        // 机会已消费，不得再压第二个阅读器）
        Navigator.of(tester.element(find.byKey(const Key('reader-stub'))))
            .pop();
        await tester.pumpAndSettle();

        expect(pushed.where((r) => r == AppRoutes.reader).length, 1);
        expect(find.byKey(const Key('reader-stub')), findsNothing);
      });
    });
  });
}
