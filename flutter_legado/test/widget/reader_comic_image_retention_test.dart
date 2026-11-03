// 批9b-3：漫画阅读器「已读图片保留数」接线（契约 §2.46 retainComicImages）
//
// 语义钉住：
// - 打开漫画成功加载当前章后调用一次，参数 = (bookUrl, durChapterIndex,
//   imageRetainNum, preDownloadNum)；
// - 翻章成功后以新章索引再次调用；
// - imageRetainNum=0 不调用（默认不清理）；
// - FFI 异常静默，不影响章节渲染。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/widgets/error_view.dart';

/// 1x1 透明 PNG（FFI 解码返回，供 Image.memory 渲染）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

const _kBookUrl = 'mock://comic/retention';
const _kSourceUrl = 'https://manga.example.com';

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
];

BookSource _comicSource() => BookSource(
      bookSourceUrl: _kSourceUrl,
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

/// 记录 retainComicImages 调用；可模拟 FFI 抛错。
class _RetentionMockApi extends MockBookApi {
  final List<(String, int, int, int)> retentionCalls = [];
  bool shouldThrow = false;

  @override
  Future<List<BookSource>> getBookSources() async => [_comicSource()];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: 'https://manga.example.com/comic/1/',
        name: '保留测试漫画',
        origin: _kSourceUrl,
        originName: '测试漫画源',
        canUpdate: true,
        totalChapterNum: 2,
        bookType: BookType.image,
        durChapterIndex: 0,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => _kChapters;

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    final seq = chapterUrl.split('/').last;
    return '<p><img src="https://cdn.example.com/retention/$seq/0.jpg"></p>';
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async =>
      jsonEncode({'base64': _kPngBase64, 'len': 68});

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {}

  @override
  Future<int> retainComicImages({
    required String bookUrl,
    required int durIndex,
    required int retain,
    required int preDownload,
  }) async {
    retentionCalls.add((bookUrl, durIndex, retain, preDownload));
    if (shouldThrow) throw StateError('模拟清理失败');
    return 2;
  }
}

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: ReaderComicScreen(bookUrl: _kBookUrl),
    ),
  );
}

/// 引擎侧图片解码只在真实事件循环推进（同 reader_comic_progress_preload_test）
Future<void> _settleWithImageDecode(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 300),
      ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    ComicImageDecodeCache.clearForTest();
  });

  testWidgets('打开漫画：按当前章与偏好参数触发一次图片保留清理', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.imageRetainNum: 2,
      PrefKeys.preDownloadNum: 4,
    });
    final api = _RetentionMockApi();
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    expect(api.retentionCalls, [(_kBookUrl, 0, 2, 4)],
        reason: '打开成功钩子须带 durChapterIndex/retain/preDownload');
  });

  testWidgets('翻章成功：以新章索引再次触发（窗口随当前章移动）', (tester) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.imageRetainNum: 2,
      PrefKeys.preDownloadNum: 4,
    });
    final api = _RetentionMockApi();
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();
    await _settleWithImageDecode(tester);

    await tester.dragUntilVisible(
      find.text('下一章'),
      find.byType(Scrollable),
      const Offset(0, -300),
    );
    await tester.pump();
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();

    expect(find.textContaining('章节2/2'), findsOneWidget);
    expect(api.retentionCalls, [
      (_kBookUrl, 0, 2, 4),
      (_kBookUrl, 1, 2, 4),
    ], reason: '翻章后须以 durChapterIndex=1 再次触发清理');
  });

  testWidgets('imageRetainNum=0（默认）：打开与翻章均不调用清理', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _RetentionMockApi();
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();
    await _settleWithImageDecode(tester);

    await tester.dragUntilVisible(
      find.text('下一章'),
      find.byType(Scrollable),
      const Offset(0, -300),
    );
    await tester.pump();
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();

    expect(api.retentionCalls, isEmpty, reason: '0=不清理，不得调用 FFI');
  });

  testWidgets('清理失败静默：不影响章节渲染与错误页', (tester) async {
    SharedPreferences.setMockInitialValues({PrefKeys.imageRetainNum: 3});
    final api = _RetentionMockApi()..shouldThrow = true;
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    expect(api.retentionCalls, hasLength(1), reason: '失败前已调用一次');
    expect(find.textContaining('章节1/2'), findsOneWidget,
        reason: '清理失败不得阻断阅读');
    expect(find.byType(ErrorView), findsNothing);
  });
}
