import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';

import '../mocks/mocks.dart';

/// [队列⑫ P3] 书架从阅读器返回后不刷新 回归测试
///
/// 背景：书架页经 _KeepAlivePage 常驻，从书架开书（阅读器/详情+自动开读）
/// 返回后**无任何刷新钩子**——内存态 Book 进度滞留（刚读完的书仍显示旧
/// 进度，进度行缺失）。修复：`_openBook` 中 `await Navigator.pushNamed`
/// 返回（即弹回书架）后触发单本定向刷新（BookshelfNotifier.refreshBook）。
///
/// 本用例以桩路由模拟「打开→进度被更新（mock 数据源返回 dci=1）→返回」
/// 全链路：不 pump 真实 ReaderScreen / BookInfoPage（红线：不碰阅读器），
/// 桩页仅占位，返回动作由测试 `tester.page.back()` 完成。数据源侧
/// （getBooks 初始 dci=0，getBook 返回 dci=1）模拟阅读器 _saveProgress
/// 已写库、书架内存态未同步的现场。
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
  });

  // ── 用例数据（dci=durChapterIndex）─────────────────────────────
  /// 未读书：dci=0、无进度标题（书架无进度行）
  const bookUnread = Book(
    name: '未读之书',
    bookUrl: 'book://a',
    totalChapterNum: 100,
  );
  /// 同一本被阅读器保存进度后：dci=1 + 进度标题（mock 数据源返回）
  const bookUnreadRead = Book(
    name: '未读之书',
    bookUrl: 'book://a',
    totalChapterNum: 100,
    durChapterIndex: 1,
    durChapterPos: 120,
    durChapterTitle: '第2章 风云际会',
  );

  /// 已读书：dci=5（返回前书架显示旧进度「第6章 已读」）
  const bookRead = Book(
    name: '已读之书',
    bookUrl: 'book://b',
    totalChapterNum: 100,
    durChapterIndex: 5,
    durChapterTitle: '第6章 已读',
  );
  /// 同一本被阅读器保存进度后：dci=6 + 新进度标题
  const bookReadUpdated = Book(
    name: '已读之书',
    bookUrl: 'book://b',
    totalChapterNum: 100,
    durChapterIndex: 6,
    durChapterTitle: '第7章 更新后',
  );

  /// pump 书架页（桩路由：详情页/阅读器占位），返回其 ProviderScope 容器
  Future<ProviderContainer> pumpShelf(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: const BookshelfScreen(),
          routes: {
            AppRoutes.bookInfo: (_) => const _StubPage(label: 'STUB_DETAIL'),
            AppRoutes.reader: (_) => const _StubPage(label: 'STUB_READER'),
          },
        ),
      ),
    );
    final context = tester.element(find.byType(BookshelfScreen));
    return ProviderScope.containerOf(context);
  }

  testWidgets(
      '未读书：详情+自动开读返回书架后，条目显示新进度（A4 链路 dci=0→1）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    when(() => mockApi.getBooks()).thenAnswer((_) async => [bookUnread]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    // 「数据源进度已更新」：书架重新拉取该书时返回 dci=1 + 进度标题
    when(() => mockApi.getBook('book://a'))
        .thenAnswer((_) async => bookUnreadRead);

    container = await pumpShelf(tester);
    addTearDown(container.dispose);
    // Notifier build() 的 _loadSettings/_loadBooks/_loadGroups 落定
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(find.text('未读之书'), findsOneWidget);

    // 开书 → 详情页（桩）+ 自动开读
    await tester.tap(find.text('未读之书'));
    await tester.pumpAndSettle();
    expect(find.text('STUB_DETAIL'), findsOneWidget);

    // 「阅读器」内进度已保存（数据源 dci=1），返回书架
    Navigator.of(tester.element(find.text('STUB_DETAIL'))).pop();
    await tester.pumpAndSettle();
    // 定向刷新是微任务链（getBook → 状态写回 → 重建），补 pump 兜底
    await tester.pump();
    await tester.pump();

    // [队列⑫ P3] 书架须刷新单本进度：进度行（「第2章 风云际会」）出现
    expect(
      find.text('第2章 风云际会'),
      findsOneWidget,
      reason: '返回书架后条目应显示新阅读进度（修复前：内存态滞留 dci=0）',
    );
    verify(() => mockApi.getBook('book://a')).called(1);
  });

  testWidgets('已读书：直开阅读器返回书架后，条目显示新进度（dci=5→6）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    when(() => mockApi.getBooks()).thenAnswer((_) async => [bookRead]);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => []);
    when(() => mockApi.getBook('book://b'))
        .thenAnswer((_) async => bookReadUpdated);
    // 文本阅读器 openBook 会加载目录/正文（ReaderNotifier 后台任务）
    when(() => mockApi.getChapters('book://b')).thenAnswer(
      (_) async => [
        for (var i = 0; i < 10; i++)
          BookChapter(
            title: '第${i + 1}章',
            bookUrl: 'book://b',
            url: 'mock://b/$i',
            index: i,
          ),
      ],
    );
    when(() => mockApi.getChapterContentFull('book://b', 5))
        .thenAnswer((_) async => '正文内容');

    container = await pumpShelf(tester);
    addTearDown(container.dispose);
    await tester.pump();
    await tester.pump();
    await tester.pump();
    // 已读书显示旧进度
    expect(find.text('第6章 已读'), findsOneWidget);

    // 开书 → 阅读器（桩）；openBook 后台运行不阻塞
    await tester.tap(find.text('已读之书'));
    await tester.pumpAndSettle();
    expect(find.text('STUB_READER'), findsOneWidget);

    // 「阅读器」内进度更新后，返回书架
    Navigator.of(tester.element(find.text('STUB_READER'))).pop();
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();

    // [队列⑫ P3] 书架须刷新单本进度：新进度行替换旧进度行
    expect(
      find.text('第7章 更新后'),
      findsOneWidget,
      reason: '返回书架后条目应显示新阅读进度（修复前：内存态滞留 dci=5）',
    );
    expect(find.text('第6章 已读'), findsNothing);
    verify(() => mockApi.getBook('book://b')).called(1);
  });
}

/// 桩页：占位详情页/阅读器（红线：不 pump 真实阅读器代码）。
/// 返回动作由测试 `tester.page.back()` 完成。
class _StubPage extends StatelessWidget {
  final String label;
  const _StubPage({required this.label});

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: Text(label));
  }
}
