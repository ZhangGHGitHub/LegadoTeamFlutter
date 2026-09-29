import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/error_view.dart';

/// 1x1 透明 PNG（作为 FFI 解码结果 base64，供 Image.memory 渲染）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

/// 三章漫画目录（URL 末段为章节序号，决定 mock 正文图片数 = 序号 + 1）
const List<BookChapter> _kChapters = [
  BookChapter(
    index: 0,
    url: 'https://manga.example.com/comic/1/ch/1',
    title: '第一章',
  ),
  BookChapter(
    index: 1,
    url: 'https://manga.example.com/comic/1/ch/2',
    title: '第二章',
  ),
  BookChapter(
    index: 2,
    url: 'https://manga.example.com/comic/1/ch/3',
    title: '第三章',
  ),
];

Book _progressBook({int chapterIndex = 0, int chapterPos = 0}) {
  return Book(
    bookUrl: 'mock://comic/progress',
    tocUrl: 'mock://comic/progress/toc',
    name: '进度漫画',
    origin: 'https://manga.example.com',
    originName: '测试漫画源',
    canUpdate: true,
    totalChapterNum: 3,
    bookType: BookType.image,
    durChapterIndex: chapterIndex,
    durChapterPos: chapterPos,
  );
}

BookSource _comicSource() {
  return BookSource(
    bookSourceUrl: 'https://manga.example.com',
    bookSourceName: '测试漫画源',
    bookSourceType: 2,
    enabled: true,
    ruleContent: ContentRule(
      content: '.comics@img@html',
      imageDecode: 'decode(result);',
    ),
    customOrder: 0,
    lastUpdateTime: 0,
    respondTime: 0,
    weight: 0,
  );
}

/// 测试 Mock：注入三章漫画书，记录进度保存 / 相邻章预载 / 解码调用
class _ProgressMockApi extends MockBookApi {
  _ProgressMockApi({
    required this.book,
    this.failPreloadFor = const <int>{},
  });

  final Book book;

  /// 预载失败模拟的章节索引集合
  final Set<int> failPreloadFor;

  /// 进度保存调用序列 (chapterIndex, chapterPos)
  final List<(int, int)> progressCalls = [];

  /// 相邻章预载（getChapterContentFull）章节索引顺序
  final List<int> fullCalls = [];

  final List<String> decodeCalls = [];

  @override
  Future<List<BookSource>> getBookSources() async => [_comicSource()];

  @override
  Future<Book?> getBook(String bookUrl) async => book;

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => _kChapters;

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    final seq = int.tryParse(chapterUrl.split('/').last) ?? 1;
    final imgs = List.generate(
      seq + 1,
      (i) => '<img src="https://cdn.example.com/$bookUrl/$seq/$i.jpg">',
    ).join('');
    return '<p>$imgs</p>';
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    decodeCalls.add(url);
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex) async {
    fullCalls.add(chapterIndex);
    if (failPreloadFor.contains(chapterIndex)) {
      throw StateError('预载失败模拟：章节 $chapterIndex');
    }
    return '预载内容 章节 $chapterIndex';
  }

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {
    progressCalls.add((chapterIndex, chapterPos));
  }
}

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: ReaderComicScreen(bookUrl: 'mock://comic/progress'),
    ),
  );
}

/// 当前滚动位置
double _scrollPixels(WidgetTester tester) {
  final state = tester.state<ScrollableState>(find.byType(Scrollable));
  return state.position.pixels;
}

/// 引擎侧图片解码（FFI Image.memory 像素）只在真实事件循环推进，
/// widget 测试的 fake async 里 `pumpAndSettle` 无法让图片获得真实高度
/// （未解码时 RenderImage 布局高度为 0 → 内容不可滚动 → 无法触发
/// 页级进度保存 / 恢复跳转）。这里切到真实事件循环让解码完成后再回
/// fake 上下文理帧，使 ListView 内容可滚动、页级进度可被驱动。
Future<void> _settleWithImageDecode(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(
    const Duration(milliseconds: 300),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('C1 页级进度：翻页后节流持久化 chapterPos（非恒 0）',
      (tester) async {
    final api = _ProgressMockApi(book: _progressBook());
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();
    await _settleWithImageDecode(tester); // 图片解码 → 内容可滚动

    // 打开后（页 0）尚未产生进度保存（保存点在可见页变化/切章/退出）
    expect(api.progressCalls, isEmpty);

    // 第一章 2 图：向下拖动一屏 → 可见页 = 1 → 页级进度立即持久化
    await tester.drag(find.byType(Scrollable), const Offset(0, -600));
    await tester.pump();
    expect(
      api.progressCalls,
      [(0, 1)],
      reason: '翻页后 updateReadingProgress 须携带页级 chapterPos（修复前恒 0）',
    );
    // 页脚反映可见页（buildLabel 输出无空格：'页数2/2' = 第 2 页）
    expect(find.textContaining('页数2/2'), findsOneWidget);

    // 再向上拖回页 0：可见页再次变化 → 持久化最新页
    // （对齐文本阅读器「每次页级位置变化保存一次」的事件驱动频率）
    await tester.drag(find.byType(Scrollable), const Offset(0, 600));
    await tester.pump();
    expect(
      api.progressCalls,
      [(0, 1), (0, 0)],
      reason: '每次可见页变化均持久化页级进度',
    );
  });

  testWidgets('C1 恢复：重开定位到记录的页级进度（非章首）', (tester) async {
    final api = _ProgressMockApi(
      book: _progressBook(chapterIndex: 1, chapterPos: 1),
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();
    // 图片解码后滚动范围才可用；恢复跳转在滚动范围稳定（度量变化）时
    // 由 _onScrollMetrics 补跳，须让引擎解码完成
    await _settleWithImageDecode(tester);

    // 应进入第二章（durChapterIndex=1）且滚动到记录的页（durChapterPos=1），
    // 而非章首（修复前 chapterPos 恒 0，重开只能回到章首）
    expect(find.textContaining('章节2/3'), findsOneWidget);
    expect(
      _scrollPixels(tester),
      greaterThan(0),
      reason: '恢复须滚动到记录页（偏移 > 0）',
    );
  });

  testWidgets('C3 预载：当前章加载完成后后台预载相邻章（下一章优先）',
      (tester) async {
    final api = _ProgressMockApi(
      book: _progressBook(chapterIndex: 1),
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 当前第二章：下一章（3）优先、上一章（1）次之，复用
    // getChapterContentFull（零契约变更）
    expect(
      api.fullCalls,
      [2, 0],
      reason: '相邻章预载须下一章优先、上一章次之',
    );
  });

  testWidgets('C3 预载：失败静默不干扰阅读（下一章失败不阻塞上一章）',
      (tester) async {
    final api = _ProgressMockApi(
      book: _progressBook(chapterIndex: 1),
      failPreloadFor: {2},
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 下一章预载失败：不弹错误页，当前章图片正常渲染
    expect(find.byType(ErrorView), findsNothing);
    expect(find.byType(Image, skipOffstage: false), findsWidgets);
    // 下一章（3）先试（失败），上一章（1）随后仍触发
    expect(api.fullCalls, [2, 0]);
  });

  testWidgets('回归：章节切换走既有链路并保存新章进度', (tester) async {
    final api = _ProgressMockApi(book: _progressBook());
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();
    expect(find.textContaining('章节1/3'), findsOneWidget);

    // 滚到底部章节导航区，点「下一章」
    await tester.dragUntilVisible(
      find.text('下一章'),
      find.byType(Scrollable),
      const Offset(0, -300),
    );
    await tester.pump();
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();

    // 进入第二章（既有章节切换能力回归），且进度保存携带新章索引
    expect(find.textContaining('章节2/3'), findsOneWidget);
    expect(
      api.progressCalls.last,
      (1, 0),
      reason: '切章后保存 (chapterIndex=1, chapterPos=0)',
    );
  });
}
