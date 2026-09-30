// [P4-3 E2] 分页适配类型（设置项 + 持久化，整页行为）
//
// 取证（参考版，legado-with-MD3）：
// - MangaSettingsPanel.kt L372-386：非条漫模式显示「页面适配」6 选项下拉
//   → UpdateSetting(PAGE_SCALE_TYPE)；L364-371 条漫模式改显侧边距滑杆
//   （侧边距不在本波范围，故条漫模式下不渲染「页面适配」项）；
// - MangaReaderContract.kt L121：默认 0；MangaReaderViewModel.kt L816
//   PAGE_SCALE_TYPE → updateMangaPreference（持久化）。
//
// 本测试验证：
// 1. 单页模式（模式 1）：设置面板出现「页面适配」下拉（默认「全屏适配」），
//    切换「拉伸」→ 持久化 mangaPageScaleType=1；
// 2. 条漫模式（默认 4）：设置面板不渲染「页面适配」项；
// 3. 已配置值（mangaPageScaleType=3）：下拉回显「适配高度」。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（合法 68 字节编码）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8'
    'AAAAASUVORK5CYII=';

/// 页面适配测试 Mock：可注入配置（翻页模式/适配类型），记录配置写入
class _ScaleMockApi extends MockBookApi {
  _ScaleMockApi({
    required this.configWrites,
    Map<String, String>? configs,
  }) : _configs = configs ?? {};

  /// 每章图片数（与 E1/E3 mock 一致取 3，保证单页式有页可翻）
  static const int imageCount = 3;

  final List<List<String>> configWrites;
  final Map<String, String> _configs;

  @override
  Future<List<BookSource>> getBookSources() async => [
        BookSource(
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
        ),
      ];

  @override
  Future<Book?> getBook(String bookUrl) async => Book(
        bookUrl: bookUrl,
        tocUrl: 'https://manga.example.com/comic/1/',
        name: '测试漫画',
        author: '作者',
        origin: 'https://manga.example.com',
        originName: '测试漫画源',
        canUpdate: true,
        totalChapterNum: 1,
        durChapterPos: 0,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => [
        BookChapter(
          index: 0,
          url: 'https://manga.example.com/comic/1/ch1.html',
          title: '第1章',
        ),
      ];

  @override
  Future<String> fetchChapterContent(
    String bookUrl,
    String chapterUrl,
    String sourceUrl,
  ) async {
    return List.generate(
      imageCount,
      (i) => '<p><img src="https://cdn.example.com/img/$i.jpg"></p>',
    ).join();
  }

  @override
  Future<String> fetchImageWithDecode(String url, String sourceJson) async {
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    configWrites.add([key, value]);
  }

  @override
  Future<void> updateReadingProgress({
    required String bookUrl,
    required int chapterIndex,
    required int chapterPos,
  }) async {}

  @override
  Future<List<int>?> getImageCache(String bookUrl, String url) async => null;
}

/// 打开漫画设置面板（控制栏 → 底栏「翻页设置」键 [P4-3 M1]）
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('翻页设置'));
  await tester.pumpAndSettle();
}

void main() {
  group('[P4-3 E2] 分页适配类型设置项', () {
    testWidgets('单页模式：下拉切换「拉伸」→ 持久化 mangaPageScaleType=1',
        (tester) async {
      final configWrites = <List<String>>[];
      final api = _ScaleMockApi(
        configWrites: configWrites,
        configs: {'mangaScrollMode': '1'},
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://s1')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('页数1/3'), findsOneWidget);

      await _openSheet(tester);

      // 「页面适配」下拉（单页模式才渲染，对齐参考版 L372-386）
      expect(find.text('页面适配'), findsOneWidget);
      // 默认值 0 = 全屏适配（Contract L121）
      expect(find.text('全屏适配'), findsOneWidget);

      // 打开下拉选「拉伸」：菜单打开后舞台上恰有 1 个「拉伸」菜单项
      // （隐藏层另有 1 个离舞台副本，故按默认 skipOffstage 定位）
      await tester.tap(find.text('全屏适配'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('拉伸'));
      await tester.pumpAndSettle();

      expect(
        configWrites,
        contains(equals(['mangaPageScaleType', '1'])),
        reason: '切换「拉伸」应持久化到 mangaPageScaleType',
      );
    });

    testWidgets('条漫模式（默认）：不渲染「页面适配」项', (tester) async {
      final api = _ScaleMockApi(configWrites: <List<String>>[]);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child:
              const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://s2')),
        ),
      );
      await tester.pumpAndSettle();

      await _openSheet(tester);

      // 条漫模式下参考版显示侧边距滑杆（不在本波范围）→ 无「页面适配」
      expect(find.text('页面适配'), findsNothing);
      expect(find.text('翻页模式'), findsOneWidget);
    });

    testWidgets('已配置 mangaPageScaleType=3：下拉回显「适配高度」',
        (tester) async {
      final api = _ScaleMockApi(
        configWrites: <List<String>>[],
        configs: {'mangaScrollMode': '1', 'mangaPageScaleType': '3'},
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://s3')),
        ),
      );
      await tester.pumpAndSettle();

      await _openSheet(tester);

      expect(find.text('适配高度'), findsOneWidget);
    });
  });
}
