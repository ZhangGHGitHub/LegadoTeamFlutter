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

/// E4 两章漫画目录（URL 末段为章节序号）
const List<BookChapter> _kChapters = [
  BookChapter(
    index: 0,
    url: 'https://manga.example.com/comic/e4/ch/1',
    title: '第一章',
  ),
  BookChapter(
    index: 1,
    url: 'https://manga.example.com/comic/e4/ch/2',
    title: '无图章',
  ),
];

/// E4 卷章（isVolume）目录：第二项为 0 图合法分隔章（中间位置，
/// 上下章导航均存在），第三项为分隔章后的普通章
const List<BookChapter> _kVolumeChapters = [
  BookChapter(
    index: 0,
    url: 'https://manga.example.com/comic/e4/ch/1',
    title: '第一章',
  ),
  BookChapter(
    index: 1,
    url: 'https://manga.example.com/comic/e4/vol/2',
    title: '第一卷',
    isVolume: true,
  ),
  BookChapter(
    index: 2,
    url: 'https://manga.example.com/comic/e4/ch/3',
    title: '第二章',
  ),
];

Book _e4Book({int chapterIndex = 0}) {
  return Book(
    bookUrl: 'mock://comic/e4',
    tocUrl: 'mock://comic/e4/toc',
    name: 'E4漫画',
    origin: 'https://manga.example.com',
    originName: '测试漫画源',
    canUpdate: true,
    totalChapterNum: 2,
    bookType: BookType.image,
    durChapterIndex: chapterIndex,
    durChapterPos: 0,
  );
}

/// E4 章内容会话状态测试 Mock
///
/// - [contentByCall] 按调用次序控制章节正文（url → 队列，队列耗尽后复用末项），
///   支持「0 图错误态 → 重试 → 恢复出图」的状态迁移；
/// - [failFirstCallFor] 指定 url 首次调用抛异常（模拟章节正文获取失败）；
/// - 记录 getBook / getChapters / fetchChapterContent 调用计数，用于甄别
///   「章级重试」（只重拉章节正文）与「书级重试」（重拉书籍信息 + 目录）。
class _ChapterErrorMockApi extends MockBookApi {
  _ChapterErrorMockApi({
    required this.book,
    required this.chapters,
    Map<String, List<String>>? contentByCall,
    Set<String> failFirstCallFor = const {},
  })  : _contentByCall = contentByCall ?? const {},
        _failFirstCallFor = failFirstCallFor;

  final Book book;
  final List<BookChapter> chapters;
  final Map<String, List<String>> _contentByCall;
  final Set<String> _failFirstCallFor;

  /// 章级重试不应重拉书籍信息 / 目录（对齐参考版 RetryChapter 只重拉当前章）
  int getBookCalls = 0;
  int getChaptersCalls = 0;

  /// 各章节 URL 的正文获取调用计数
  final Map<String, int> contentCalls = {};
  final Map<String, int> _counts = {};

  @override
  Future<List<BookSource>> getBookSources() async {
    // 提供与书籍 origin 匹配的书源：图片渲染走 FFI 解码链路
    //（_DecodedComicImage → fetchImageWithDecode，桩返回 1x1 PNG）
    return [
      BookSource(
        bookSourceUrl: book.origin,
        bookSourceName: book.originName,
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
      ),
    ];
  }

  @override
  Future<Book?> getBook(String bookUrl) async {
    getBookCalls++;
    return book;
  }

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async {
    getChaptersCalls++;
    return chapters;
  }

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    final count = (_counts[chapterUrl] ?? 0) + 1;
    _counts[chapterUrl] = count;
    contentCalls[chapterUrl] = count;
    if (_failFirstCallFor.contains(chapterUrl) && count == 1) {
      throw StateError('章节内容获取失败（模拟）');
    }
    final queue = _contentByCall[chapterUrl];
    if (queue == null || queue.isEmpty) {
      return '<img src="https://cdn.example.com/e4/fallback.jpg">';
    }
    return count <= queue.length ? queue[count - 1] : queue.last;
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String> getChapterContentFull(String bookUrl, int chapterIndex) async {
    return '预载内容 章节 $chapterIndex';
  }
}

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: ReaderComicScreen(bookUrl: 'mock://comic/e4'),
    ),
  );
}

/// 引擎侧图片解码（FFI Image.memory 像素）只在真实事件循环推进，
/// widget 测试的 fake async 里 `pumpAndSettle` 无法让图片获得真实高度
/// （同 reader_comic_progress_preload_test 先例）
Future<void> _settleWithImageDecode(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(
    const Duration(milliseconds: 300),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('E4 非卷章 0 图：进入错误态（正文没有图片）+ 章级重试恢复',
      (tester) async {
    const ch2 = 'https://manga.example.com/comic/e4/ch/2';
    final api = _ChapterErrorMockApi(
      book: _e4Book(chapterIndex: 1),
      chapters: _kChapters,
      contentByCall: {
        ch2: [
          '<p>本章正文没有图片</p>', // 首次：0 图
          '<img src="https://cdn.example.com/e4/ch2/0.jpg">', // 重试后恢复
        ],
      },
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 非卷章 0 图 = 章级错误态（对齐原版 ReadManga.kt L227-230
    // imageCount==0 && !isVolume → loadFail「正文没有图片」；参考版
    // MangaChapterPageLoader L36-38 同条件 throw → Failed 全屏错误 + 重试）
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('正文没有图片'), findsOneWidget);
    expect(find.text('暂无图片'), findsNothing,
        reason: '非卷章 0 图应进错误态，而非「暂无图片」导航页');

    // 点「重试」：章级重试（只重拉章节正文，不重拉书籍信息/目录），恢复出图
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await _settleWithImageDecode(tester);

    expect(api.getBookCalls, 1, reason: '章级重试不得重拉书籍信息');
    expect(api.getChaptersCalls, 1, reason: '章级重试不得重拉目录');
    expect(api.contentCalls[ch2], 2, reason: '重试重拉章节正文一次');
    expect(find.byType(ErrorView), findsNothing, reason: '重试恢复后错误态解除');
    expect(find.byType(Image, skipOffstage: false), findsWidgets);
  });

  testWidgets('E4 卷章（isVolume）0 图：显示章节标题分隔页（非错误、非暂无图片）',
      (tester) async {
    const vol = 'https://manga.example.com/comic/e4/vol/2';
    final api = _ChapterErrorMockApi(
      book: _e4Book(chapterIndex: 1),
      chapters: _kVolumeChapters,
      contentByCall: {
        vol: ['<p>卷分隔章，无正文</p>'],
      },
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 卷章 0 图 = 合法分隔页（对齐原版 ReadManga L635-636 卷章渲染
    // ReaderLoading 分隔页、标题=章名；参考版 L452-460 ChapterEdge
    // "volume:..." message=chapterTitle）：显示章节标题，非错误态
    expect(find.byType(ErrorView), findsNothing);
    expect(find.text('暂无图片'), findsNothing,
        reason: '卷章 0 图应显示标题分隔页，而非误导性的「暂无图片」');
    expect(find.text('第一卷'), findsOneWidget, reason: '分隔页显示章节标题');
    // 分隔页保留章节导航（用户需跳过分隔章继续阅读）
    expect(find.text('下一章'), findsOneWidget);
  });

  testWidgets('E4 章节正文获取失败：错误态 + 章级重试（非书级重载）',
      (tester) async {
    const ch2 = 'https://manga.example.com/comic/e4/ch/2';
    final api = _ChapterErrorMockApi(
      book: _e4Book(chapterIndex: 1),
      chapters: _kChapters,
      contentByCall: {
        ch2: ['<img src="https://cdn.example.com/e4/ch2/0.jpg">'],
      },
      failFirstCallFor: {ch2},
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 章节正文获取失败 → 章级错误态（参考版 Failed(token, message)
    // 全屏错误 + Retry），错误信息来自异常本身（非 0 图校验文案）
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.textContaining('章节内容获取失败'), findsOneWidget);
    expect(find.text('正文没有图片'), findsNothing);

    // 点「重试」：章级重试恢复出图，且未重拉书籍信息/目录
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await _settleWithImageDecode(tester);

    expect(api.getBookCalls, 1, reason: '章级重试不得重拉书籍信息');
    expect(api.getChaptersCalls, 1, reason: '章级重试不得重拉目录');
    expect(api.contentCalls[ch2], 2, reason: '重试重拉章节正文一次');
    expect(find.byType(ErrorView), findsNothing, reason: '重试恢复后错误态解除');
    expect(find.byType(Image, skipOffstage: false), findsWidgets);
  });
}
