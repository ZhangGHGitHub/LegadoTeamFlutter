// 注：本工具链（Flutter 3.44.8 / Dart 3.12.2，2026-09 升级后）新编译的
// Windows 前端对无扩展名包导入（package:x/x）解析失败（报「系统找不到
// 指定的文件」），显式 .dart 扩展名为当前可编译形态；存量测试文件沿用
// 无扩展名形态系旧工具链产物，未动。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

/// 目录页章节行缓存状态指示测试（用户验收 P2-28，对齐原版
/// ChapterListAdapter.upHasCache 三态语义 — full-stack-engineer + UI）
///
/// 原版基准（app/src/main/java/io/legado/app/ui/book/toc/ChapterListAdapter.kt）：
/// - :192-197 cached 判定：本地书/卷标题恒 true；在线章按 cacheFileNames 命中
/// - :343-352 upHasCache：未缓存显示云朵（ic_outline_cloud_24）、已缓存隐藏；
///   当前阅读章恒显示对勾（ic_check）
/// - :219-236 字数标签：tocCountWords 开关且 wordCount 非空时显示（我方
///   「加载字数」开关默认开，对齐 AppConfig.tocCountWords）
/// 本地书/卷标题行无云图标；本地书当前阅读章仍显示对勾（对齐原版
/// upHasCache 的 isCurrent 分支，非卷行一律经 upHasCache 处理）。
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

  Widget wrap(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: child),
      );

  /// 查找包含指定章节标题的章节行（ListTile）。
  /// 状态图标/字数胶囊位于行 trailing 区（与标题 Text 平级，对齐原版
  /// item_chapter_list.xml 布局），故以行为锚点而非 Text 后代。
  Finder chapterRow(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(ListTile));

  const String bookUrl = 'https://src.com/book/1';

  Book makeBook({String origin = 'https://src.com', int dur = 3}) => Book(
        bookUrl: bookUrl,
        name: '测试书',
        author: '作者A',
        totalChapterNum: 4,
        origin: origin,
        durChapterIndex: dur,
        durChapterTitle: '第四章',
      );

  List<BookChapter> makeChapters() => [
        const BookChapter(
          url: 'u0',
          title: '第一章',
          index: 0,
          bookUrl: bookUrl,
          wordCount: '1200',
        ),
        const BookChapter(
          url: 'v0',
          title: '第一卷',
          index: 1,
          bookUrl: bookUrl,
          isVolume: true,
        ),
        const BookChapter(
          url: 'u2',
          title: '第三章',
          index: 2,
          bookUrl: bookUrl,
        ),
        const BookChapter(
          url: 'u3',
          title: '第四章',
          index: 3,
          bookUrl: bookUrl,
          wordCount: '3400',
        ),
      ];

  /// 公共 stub：书架态/章节/缓存集合/标注/书签
  void stubCommon(List<BookChapter> chapters, List<String> cachedUrls) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
    when(() => mockApi.getChapters(bookUrl)).thenAnswer(
      (_) async => chapters,
    );
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer(
      (_) async => cachedUrls,
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);
  }

  testWidgets('未缓存网络章显示云朵图标，已缓存章与卷标题行无图标',
      (tester) async {
    // 缓存集合命中 u0（第一章）与 u3（当前章），u2 未缓存；卷 v0 不在集合
    stubCommon(makeChapters(), const ['u0', 'u3']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await tester.pumpAndSettle();

    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第三章'), findsOneWidget);
    // 仅未缓存的「第三章」显示云朵
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.cloud_outlined),
      ),
      findsOneWidget,
    );
    // 已缓存的「第一章」无图标
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.cloud_outlined),
      ),
      findsNothing,
    );
    // 卷标题行（Container，非章节行 ListTile）无状态图标（原版 ivChecked.gone）
    final volumeRow = find.ancestor(
      of: find.text('第一卷'),
      matching: find.byType(Container),
    );
    expect(
      find.descendant(
          of: volumeRow, matching: find.byIcon(Icons.cloud_outlined)),
      findsNothing,
    );
    expect(
      find.descendant(of: volumeRow, matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('当前阅读章恒显示对勾（未缓存时以对勾替代云朵，对齐原版 isCurrent 分支）',
      (tester) async {
    // 缓存集合仅 u0：u2 未缓存、u3（当前章）也未缓存
    stubCommon(makeChapters(), const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await tester.pumpAndSettle();

    // 当前章「第四章」：对勾
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    // 当前章未缓存也不显示云朵（原版：isCurrent 时 ivChecked 置为 ic_check）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.cloud_outlined),
      ),
      findsNothing,
    );
    // 非当前的未缓存章「第三章」仍显示云朵
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.cloud_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets('字数标签：开关默认开且 wordCount 非空显示胶囊，空则隐藏',
      (tester) async {
    stubCommon(makeChapters(), const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await tester.pumpAndSettle();

    // 有 wordCount 的两章显示字数胶囊（对齐原版 tv_word_count，位于行内）
    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200 字')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400 字')),
      findsOneWidget,
    );
    // 无 wordCount 的「第三章」无字数标签
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.textContaining('字'),
      ),
      findsNothing,
    );
  });

  testWidgets('本地书不显示云朵图标且不请求缓存列表（对齐原版 isLocalBook 恒 cached）',
      (tester) async {
    final localChapters = [
      const BookChapter(
          url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
      const BookChapter(
          url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
      const BookChapter(
          url: 'u2', title: '第三章', index: 2, bookUrl: bookUrl),
    ];
    when(() => mockApi.getBook(any()))
        .thenAnswer((_) async => makeBook(origin: BookType.localTag, dur: 1));
    when(() => mockApi.getChapters(bookUrl)).thenAnswer(
      (_) async => localChapters,
    );
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer(
      (_) async => const ['u0'],
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);

    await tester.pumpWidget(
      wrap(TocScreen(book: makeBook(origin: BookType.localTag, dur: 1))),
    );
    await tester.pumpAndSettle();

    // 本地书无云图标（原版：isLocalBook → cached=true → 云朵隐藏）
    expect(find.byIcon(Icons.cloud_outlined), findsNothing);
    // 本地书不请求缓存列表（数据无意义，避免无谓 FFI 调用）
    verifyNever(() => mockApi.listCachedChapterUrls(any()));
    // 本地书当前章（第二章）仍显示对勾（原版 upHasCache isCurrent 分支）
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
  });
}
