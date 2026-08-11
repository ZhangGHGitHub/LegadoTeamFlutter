import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

/// 模拟设备实测：DB 无章节（getChapters=[]），须 refreshToc 自愈后才能出图
class _EmptyTocThenRefreshApi extends MockBookApi {
  _EmptyTocThenRefreshApi({
    required this.source,
    required this.refreshCalls,
    required this.decodeCalls,
  });

  final BookSource source;
  final List<String> refreshCalls;
  final List<String> decodeCalls;

  @override
  Future<List<BookSource>> getBookSources() async => [source];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: bookUrl,
        name: '51测试',
        author: '',
        origin: source.bookSourceUrl,
        originName: source.bookSourceName,
        canUpdate: true,
        totalChapterNum: 0,
        bookType: BookType.image | BookType.notShelf,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => const [];

  @override
  Future<List<BookChapter>> refreshToc(String bookUrl, String sourceUrl) async {
    refreshCalls.add('$bookUrl|$sourceUrl');
    return [
      BookChapter(
        index: 0,
        url: 'https://51acgs.com/comic/5957/chapter/18465',
        title: '全集',
      ),
    ];
  }

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '<img src="https://pic.example.com/a.jpeg">';
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    decodeCalls.add(url);
    // 确保 sourceJson 含 imageDecode（对齐真实书源序列化）
    expect(sourceJson, contains('imageDecode'));
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }
}

void main() {
  testWidgets('本地无目录时自动 refreshToc 后再加载图片', (tester) async {
    final refreshCalls = <String>[];
    final decodeCalls = <String>[];
    final source = BookSource(
      bookSourceUrl: 'https://51acgs.com',
      bookSourceName: '51漫画',
      bookSourceType: 2,
      enabled: true,
      ruleContent: ContentRule(
        content: '.comics@img@html',
        imageDecode: 'decryptImage(result);',
      ),
      customOrder: 0,
      lastUpdateTime: 0,
      respondTime: 0,
      weight: 0,
    );
    final api = _EmptyTocThenRefreshApi(
      source: source,
      refreshCalls: refreshCalls,
      decodeCalls: decodeCalls,
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ReaderComicScreen(bookUrl: 'https://51acgs.com/comic/5957'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(refreshCalls, isNotEmpty,
        reason: '章节为空时必须 refreshToc（对齐 reader_notifier）');
    expect(refreshCalls.first, contains('https://51acgs.com'));
    expect(find.text('暂无章节'), findsNothing);
    expect(decodeCalls, isNotEmpty);
    expect(find.byType(Image, skipOffstage: false), findsWidgets);
  });
}
