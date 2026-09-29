// [P4-3 E3] 自动翻页/自动滚动（整页行为）
//
// 取证（参考版，legado-with-MD3）：
// - MangaReaderContract.kt L44/L136：autoReadEnabled 会话态默认 false，
//   autoReadSpeed 默认 3；
// - MangaSettingsPanel.kt L755-767：自动阅读开关 + 速度滑杆 1..15；
// - MangaReaderScreen.kt L200-216 单页式：delay(速度×1000ms) 后 PageStep(1)
//   （每秒一页）；L677-699 条漫：每周期滚动 10000px
//   （tween(ceil(16/速度×10000)ms)），到章末 → NextChapter；
//   LaunchedEffect 依赖 menuVisible/activeSheet——控制栏/面板打开期间
//   暂停（本测试以 _showControls 守卫对齐）；
// - 原版 ReadMangaActivity L570-591 开关/速度菜单互斥语义，
//   L691-694 菜单显示暂停、隐藏恢复。
//
// 本测试验证：
// 1. 单页式（模式 1）：设置面板「自动翻页」开关 → 到点自动下一页；
//    再关开关 → 停止翻页（再点停止）；
// 2. 速度滑杆：拖动 → setConfig 持久化 mangaAutoReadSpeed；
// 3. 条漫（模式 4）：自动滚动到章末 → 自动切下一章（两章 mock 端到端）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（合法 68 字节编码；条漫用例依赖解码后的真实项高）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8'
    'AAAAASUVORK5CYII=';

/// 自动翻页测试 Mock：可注入配置（翻页模式/速度档）、章节数，
/// 记录进度写入与配置写入
class _AutoReadMockApi extends MockBookApi {
  _AutoReadMockApi({
    required this.progressCalls,
    required this.configWrites,
    Map<String, String>? configs,
    this.chapterCount = 1,
  }) : _configs = configs ?? {};

  /// 每章图片数（与原版 mock 一致取 3，保证单页式有页可翻）
  static const int imageCount = 3;

  final List<List<int>> progressCalls;
  final List<List<String>> configWrites;
  final Map<String, String> _configs;
  final int chapterCount;

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
        totalChapterNum: chapterCount,
        durChapterPos: 0,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async =>
      List<BookChapter>.generate(
        chapterCount,
        (i) => BookChapter(
          index: i,
          url: 'https://manga.example.com/comic/1/ch${i + 1}.html',
          title: '第${i + 1}章',
        ),
      );

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
  }) async {
    progressCalls.add([chapterIndex, chapterPos]);
  }

  @override
  Future<List<int>?> getImageCache(String bookUrl, String url) async => null;
}

/// 打开「自动翻页」开关（控制栏 → 设置面板 → 开关），返回已打开的 sheet
Future<void> _enableAutoRead(WidgetTester tester) async {
  // 中心点击 → 控制栏显示
  await tester.tapAt(const Offset(400, 300));
  await tester.pumpAndSettle();
  // 顶栏「漫画设置」
  await tester.tap(find.byTooltip('漫画设置'));
  await tester.pumpAndSettle();
  // 「自动翻页」开关（SwitchListTile 标题定位，避免命中灰度/电子纸开关）
  final switchTile = find.widgetWithText(SwitchListTile, '自动翻页');
  expect(switchTile, findsOneWidget);
  await tester.tap(switchTile);
  await tester.pumpAndSettle();
}

/// 关闭设置面板（barrier 点击）并收起控制栏，回到沉浸态
Future<void> _closeSheetAndControls(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 20)); // barrier → 关 sheet
  await tester.pumpAndSettle();
  expect(find.text('自动翻页'), findsNothing, reason: '设置面板应已关闭');
  await tester.tapAt(const Offset(400, 300)); // 中心点击 → 控制栏隐藏
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('[P4-3 E3] 单页式：开关后到点自动下一页；再关开关停止',
      (tester) async {
      final progressCalls = <List<int>>[];
      final configWrites = <List<String>>[];
      // 模式 1（L2R 单页）+ 速度档 1（1 秒一页）
      final api = _AutoReadMockApi(
        progressCalls: progressCalls,
        configWrites: configWrites,
        configs: {'mangaScrollMode': '1', 'mangaAutoReadSpeed': '1'},
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://c1')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('页数1/3'), findsOneWidget);

      await _enableAutoRead(tester);
      await _closeSheetAndControls(tester);

      // 1 秒后自动翻到第 2 页（速度档 1 = 1000ms）
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.textContaining('页数2/3'), findsOneWidget);

      // 再关开关 → 停止翻页（「再点停止」语义）
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('漫画设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '自动翻页'));
      await tester.pumpAndSettle();
      await _closeSheetAndControls(tester);

      // 再等 3 个周期 → 页码不再前进
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(find.textContaining('页数2/3'), findsOneWidget);
    });

    testWidgets('速度滑杆：拖动 → 持久化 mangaAutoReadSpeed', (tester) async {
      final configWrites = <List<String>>[];
      final api = _AutoReadMockApi(
        progressCalls: <List<int>>[],
        configWrites: configWrites,
        configs: {'mangaScrollMode': '1', 'mangaAutoReadSpeed': '3'},
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://c2')),
        ),
      );
      await tester.pumpAndSettle();

      await _enableAutoRead(tester);

      // 速度滑杆仅在开关打开后出现（对齐原版 L572-575 速度项随开关显隐；
      // 色彩滤镜区恒有 5 条滑杆，故按「自动速度」标题定位其所在滑杆卡片，
      // 再取该卡片内唯一的 Slider（标题与滑杆同卡片、为兄弟节点，
      // 故经最近 Column 祖先定位而非直接 ancestor））
      final autoTile = find.ancestor(
        of: find.text('自动速度'),
        matching: find.byType(Column),
      ).first;
      final slider = find.descendant(
        of: autoTile,
        matching: find.byType(Slider),
      );
      expect(slider, findsOneWidget, reason: '开关打开后应出现速度滑杆');
      // 拖到最右 → 15 档
      await tester.drag(slider, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(
        configWrites,
        contains(equals(['mangaAutoReadSpeed', '15'])),
        reason: '滑杆值应持久化到 mangaAutoReadSpeed',
      );
    });

    testWidgets('条漫：自动滚动到章末 → 自动切下一章', (tester) async {
      final progressCalls = <List<int>>[];
      // 条漫（模式 4）+ 速度档 15（最快，周期 ceil(16/15×10000)=10667ms）
      // + 两章
      final api = _AutoReadMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        configs: {'mangaAutoReadSpeed': '15'},
        chapterCount: 2,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://c3')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('章节1/2'), findsOneWidget);

      await _enableAutoRead(tester);
      await _closeSheetAndControls(tester);

      // 一个周期（10667ms）：条漫滚动 10000px 超过章内容高 → 章末切章
      await tester.pump(const Duration(milliseconds: 10700));
      // 参考版 consumed<1 → NextChapter 前有 500ms 延迟（L694）
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '条漫自动滚动到章末应自动进入下一章');
      expect(progressCalls, contains(equals([1, 0])),
          reason: '新章章首应写入进度 [1,0]');
  });
}
