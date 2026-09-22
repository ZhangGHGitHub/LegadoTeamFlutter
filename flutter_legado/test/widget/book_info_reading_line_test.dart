// [P2-21] 08 详情页三行块（在读/最新/共N章+状态）回归测试：
// - 在读行 off-by-one：durChapterIndex 为 0 基，dci=1 + 3 章目录必须取
//   chapters[1].title（原实现按 1 基取 chapters[durIdx-1]，偏一章）
// - 形态对齐双基准（Kotlin 参考版 BookInfoSummary + 原版 upLoading）：
//   在读行 = '在读 · {标题}'（无「第N章」前缀；标题取值
//   ① 存储值 durChapterTitle → ② 目录回落 chapters[durIdx] → ③ 皆缺不渲染）
//   最新行 = '最新 · {标题}'（无「第N章」前缀、无代码追加「（全书完）」；
//   E5 状态词 → 目录末章回落保留，回落同样不加后缀）
// - 第三行三态（参考 Kotlin when 同源）：
//   未读（dci==0 且 pos==0）/ 已读 N 章（N=dci+1）/ 已读完（dci+1==total）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';
import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget themeWrap(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      theme: AppTheme.palette(brightness: brightness, palette: Md3Palettes.wh),
      darkTheme: AppTheme.palette(
        brightness: Brightness.dark,
        palette: Md3Palettes.wh,
      ),
      themeMode: brightness == Brightness.light
          ? ThemeMode.light
          : ThemeMode.dark,
      home: child,
    );
  }

  /// 3 章目录（0 基下标 0/1/2 对应 第一/二/三章）
  List<BookChapter> tocChapters() => const [
    BookChapter(title: '第一章'),
    BookChapter(title: '第二章'),
    BookChapter(title: '第三章'),
  ];

  Future<void> pumpBookInfo(
    WidgetTester tester,
    Book book, {
    List<BookChapter> chapters = const [],
  }) async {
    tester.view.physicalSize = const Size(1080, 2260);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final mockApi = MockRustApi();
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(any())).thenAnswer((_) async => chapters);
    when(() => mockApi.getBooks()).thenAnswer((_) async => [book]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => '');
    when(
      () => mockApi.getChapterContent(any(), any()),
    ).thenAnswer((_) async => '内容');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: themeWrap(BookInfoScreen(book: book)),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Book makeBook({
    int durChapterIndex = 0,
    int durChapterPos = 0,
    int totalChapterNum = 0,
    String? durChapterTitle,
    String? latestChapterTitle,
  }) => Book(
    bookUrl: 'u1',
    name: '测试书',
    author: '作者',
    coverUrl: '',
    durChapterIndex: durChapterIndex,
    durChapterPos: durChapterPos,
    totalChapterNum: totalChapterNum,
    durChapterTitle: durChapterTitle,
    latestChapterTitle: latestChapterTitle,
  );

  group('P2-21 08 三行块', () {
    testWidgets('off-by-one：dci=1 指向 chapters[1] 而非 chapters[0]', (
      tester,
    ) async {
      final book = makeBook(
        durChapterIndex: 1,
        totalChapterNum: 3,
        latestChapterTitle: '最新章',
      );
      await pumpBookInfo(tester, book, chapters: tocChapters());

      // 在读行 = 0 基回落 chapters[1].title = 第二章（原 1 基实现会误显第一章）
      expect(find.text('在读 · 第二章'), findsOneWidget);
      expect(find.text('在读 · 第一章'), findsNothing);
      // 形态：无「第N章」前缀（旧形态「在读·第1章 …」不得出现）
      expect(find.textContaining('在读·第'), findsNothing);
      expect(find.textContaining('第1章'), findsNothing);
      // 最新行 = '最新 · {标题}'：无前缀、无代码追加（全书完）
      expect(find.text('最新 · 最新章'), findsOneWidget);
      expect(find.textContaining('最新·第'), findsNothing);
      expect(find.textContaining('（全书完）'), findsNothing);
      // 第三行：共 3 章 + 已读 2 章（N=dci+1=2，2≠3 非已读完）
      expect(find.text('共 3 章'), findsOneWidget);
      expect(find.text('已读 2 章'), findsOneWidget);
      expect(find.text('未读'), findsNothing);
      expect(find.text('已读完'), findsNothing);
    });

    testWidgets('存储值 durChapterTitle 优先于目录回落', (tester) async {
      final book = makeBook(
        durChapterIndex: 1,
        totalChapterNum: 3,
        durChapterTitle: '存储标题X',
        latestChapterTitle: '最新章',
      );
      await pumpBookInfo(tester, book, chapters: tocChapters());

      // ① 存储值非空 → 优先（即使目录有 chapters[1]=第二章 也不用它）
      expect(find.text('在读 · 存储标题X'), findsOneWidget);
      expect(find.text('在读 · 第二章'), findsNothing);
    });

    testWidgets('存储值为空白串视为缺数据 → 回落 chapters[durIdx]', (tester) async {
      final book = makeBook(
        durChapterIndex: 1,
        totalChapterNum: 3,
        durChapterTitle: '   ',
        latestChapterTitle: '最新章',
      );
      await pumpBookInfo(tester, book, chapters: tocChapters());

      expect(find.text('在读 · 第二章'), findsOneWidget);
    });

    testWidgets('存储值缺 + 目录越界 → 在读行不渲染（D4 口径）', (tester) async {
      // dci=99 超出 3 章目录，且无存储值 → 两路皆缺 → 不渲染该行
      final book = makeBook(
        durChapterIndex: 99,
        totalChapterNum: 3,
        latestChapterTitle: '最新章',
      );
      await pumpBookInfo(tester, book, chapters: tocChapters());

      expect(find.textContaining('在读 · '), findsNothing);
      // 最新行不受影响
      expect(find.text('最新 · 最新章'), findsOneWidget);
    });

    testWidgets('目录未加载 + 无存储值 → 在读行不渲染', (tester) async {
      final book = makeBook(
        durChapterIndex: 1,
        totalChapterNum: 3,
        latestChapterTitle: '最新章',
      );
      // 不传 chapters：目录空
      await pumpBookInfo(tester, book);

      expect(find.textContaining('在读 · '), findsNothing);
      expect(find.text('最新 · 最新章'), findsOneWidget);
    });

    testWidgets('最新行：状态词回落目录末章且不加（全书完）后缀', (tester) async {
      // E5：latestChapterTitle 为完结状态词 → 回落目录末章（第三章），
      // [P2-21] 回落同样不追加「（全书完）」（参考 dump 该后缀为站点自带）
      final book = makeBook(totalChapterNum: 3, latestChapterTitle: '已完结');
      await pumpBookInfo(tester, book, chapters: tocChapters());

      expect(find.text('最新 · 第三章'), findsOneWidget);
      expect(find.textContaining('（全书完）'), findsNothing);
      expect(find.textContaining('第3章'), findsNothing);
    });

    testWidgets('最新行：字段为空 → 不渲染', (tester) async {
      final book = makeBook();
      await pumpBookInfo(tester, book, chapters: tocChapters());

      expect(find.textContaining('最新 · '), findsNothing);
      expect(find.textContaining('（全书完）'), findsNothing);
    });

    // 第三行三态（每态独立 pump：BookInfoScreen 的 State 仅 initState
    // 时取 widget.book，同树换书不重载，故每态一个 testWidgets）

    testWidgets('第三行·未读：dci==0 且 pos==0', (tester) async {
      await pumpBookInfo(
        tester,
        makeBook(totalChapterNum: 3),
        chapters: tocChapters(),
      );
      expect(find.text('共 3 章'), findsOneWidget);
      expect(find.text('未读'), findsOneWidget);
      expect(find.text('已读完'), findsNothing);
      expect(find.textContaining('已读 '), findsNothing);
    });

    testWidgets('第三行·已读完：dci+1 == total（2+1==3）', (tester) async {
      await pumpBookInfo(
        tester,
        makeBook(durChapterIndex: 2, totalChapterNum: 3),
        chapters: tocChapters(),
      );
      expect(find.text('共 3 章'), findsOneWidget);
      expect(find.text('已读完'), findsOneWidget);
      // 已读完时不渲染「已读 3 章」
      expect(find.text('已读 3 章'), findsNothing);
    });

    testWidgets('第三行·已读 N 章：首章读一部分（pos>0, dci==0）→ 已读 1 章', (tester) async {
      await pumpBookInfo(
        tester,
        makeBook(durChapterPos: 120, totalChapterNum: 3),
        chapters: tocChapters(),
      );
      expect(find.text('共 3 章'), findsOneWidget);
      expect(find.text('未读'), findsNothing);
      expect(find.text('已读完'), findsNothing);
      expect(find.text('已读 1 章'), findsOneWidget);
    });
  });
}
