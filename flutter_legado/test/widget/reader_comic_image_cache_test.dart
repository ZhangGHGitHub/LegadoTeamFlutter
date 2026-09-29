import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（与 reader_comic_decode_test 同款，作为解码结果 base64）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

const _kBookUrl = 'mock://comic/1';
const _kImageUrl = 'https://cdn.example.com/img/1.jpg';

/// 含 imageDecode 规则的漫画书源（对齐 reader_comic_decode_test 形态）
BookSource _buildComicSource() {
  return BookSource(
    bookSourceUrl: 'https://manga.example.com',
    bookSourceName: '测试漫画源',
    bookSourceGroup: '漫画',
    bookSourceType: 2,
    enabled: true,
    ruleContent: ContentRule(
      content: '.x',
      imageDecode: 'decode(result);',
    ),
    customOrder: 0,
    lastUpdateTime: 0,
    respondTime: 0,
    weight: 0,
  );
}

/// 测试专用 MockBookApi：注入漫画书 + 含 img 的章节正文 + 解码返回；
/// 网络下载链路计数用于断言「磁盘命中不再走网络」。
class _ComicCacheMockApi extends MockBookApi {
  _ComicCacheMockApi({required this.source, required this.decodeCalls});

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
    return '<p><img src="$_kImageUrl"></p>';
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
        home: ReaderComicScreen(bookUrl: _kBookUrl),
      ),
    );
  }

  testWidgets(
    'P4-2a 磁盘缓存优先：冷启走网络并写缓存；清内存后重挂载磁盘命中不再走网络',
    (tester) async {
      final decodeCalls = <String>[];
      final api = _ComicCacheMockApi(
        source: _buildComicSource(),
        decodeCalls: decodeCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);

      // ── 会话 1：冷启动（磁盘缓存为空）→ 网络加载并写磁盘缓存 ──
      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();
      expect(decodeCalls, [contains(_kImageUrl)],
          reason: '冷启动应走一次网络解码');
      // 屏幕侧 fire-and-forget 的 saveImageCache 应已落地（mock 内存 Map 模拟）
      final saved = await api.getImageCache(_kBookUrl, _kImageUrl);
      expect(saved, isNotNull, reason: '加载成功后应写入图片磁盘缓存');

      // ── 会话 2：清内存缓存（模拟应用重启）→ 磁盘命中，不再走网络 ──
      ComicImageDecodeCache.clearForTest();
      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();
      expect(
        decodeCalls.length,
        1,
        reason: '磁盘缓存命中后不得再次调用网络解码链（仍为 1 次）',
      );
      expect(
        find.byType(Image, skipOffstage: false),
        findsWidgets,
        reason: '磁盘命中应直接渲染图片',
      );
    },
  );
}
