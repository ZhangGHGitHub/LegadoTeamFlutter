import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（作为解码结果 base64，验证 Image.memory 渲染路径）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

/// 含 imageDecode 规则的漫画书源（对齐 favcomic 形态）
BookSource _buildComicSource({bool withDecode = true, String? url}) {
  return BookSource(
    bookSourceUrl: url ?? 'https://manga.example.com',
    bookSourceName: '测试漫画源',
    bookSourceGroup: '漫画',
    bookSourceType: 2,
    enabled: true,
    ruleContent: ContentRule(
      content: '.x',
      imageDecode: withDecode ? 'decode(result);' : null,
    ),
    customOrder: 0,
    lastUpdateTime: 0,
    respondTime: 0,
    weight: 0,
  );
}

/// 测试专用 MockBookApi：注入漫画书 + 含 img 的章节正文 + 解码返回
class _ComicMockApi extends MockBookApi {
  _ComicMockApi({required this.source, required this.decodeCalls});

  final BookSource source;
  final List<String> decodeCalls;

  @override
  Future<List<BookSource>> getBookSources() async => [source];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: 'https://manga.example.com/comic/1/',
        name: '测试漫画',
        author: '作者',
        origin: source.bookSourceUrl,
        originName: source.bookSourceName,
        canUpdate: true,
        totalChapterNum: 1,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => [
        BookChapter(
          index: 0,
          url: 'https://manga.example.com/comic/1/ch1.html',
          title: '第一章',
        ),
      ];

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return '<p><img src="https://cdn.example.com/img/1.jpg"></p>';
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    decodeCalls.add(url);
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }
}

void main() {
  Widget buildApp(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: ReaderComicScreen(bookUrl: 'mock://comic/1'),
      ),
    );
  }

  testWidgets('含 imageDecode 规则：漫画图片走 FFI 解码下载并显示',
      (tester) async {
    final decodeCalls = <String>[];
    final api = _ComicMockApi(
      source: _buildComicSource(withDecode: true),
      decodeCalls: decodeCalls,
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    // 等待异步加载（getBook → getChapters → fetchChapterContent → 解码）
    await tester.pumpAndSettle();

    // 解码链路被调用且传入了图片 URL
    expect(decodeCalls, isNotEmpty);
    expect(decodeCalls.first, contains('cdn.example.com/img/1.jpg'));
    // 图片渲染为 Image（解码结果）；skipOffstage:false 覆盖 ListView 懒加载
    expect(find.byType(Image, skipOffstage: false), findsWidgets);
    expect(find.byType(RawImage, skipOffstage: false), findsWidgets);
  });

  testWidgets('无 imageDecode 规则：仍走 FFI 下载（复合 URL/防盗链支持）',
      (tester) async {
    final decodeCalls = <String>[];
    final api = _ComicMockApi(
      source: _buildComicSource(withDecode: false, url: 'https://manga2.example.com'),
      decodeCalls: decodeCalls,
    );
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 无 imageDecode 规则时同样走 FFI 下载（Rust 原样返回 bytes，
    // 用于解析 `url,{json headers}` 复合格式与书源防盗链 header）
    expect(decodeCalls, isNotEmpty);
    expect(decodeCalls.first, contains('cdn.example.com/img/1.jpg'));
  });
}
