import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';
import 'package:flutter_legado/src/services/platform_channel.dart';

/// [cbz 批 D | 2026-10-03] 漫画屏本地 cbz 页渲染测试
///
/// 链路：Book（LOCAL|image=0x1040，origin=loc_book）→ getChapters 懒解析
/// 1 章（url 空）→ getChapterContent 返回 `cbz://<条目名>` 行列表 →
/// BookApi.cbzReadPage（FFI `cbz_read_page`）取图 → Image.memory 渲染。
/// mock 形态与既有一族漫画 widget 测试（mock BookApi + 覆盖
/// bookApiProvider）一致。

/// 1x1 透明 PNG（与 reader_comic_decode/image_cache 测试同款）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQAB'
    'h6FO1AAAAABJRU5ErkJggg==';

/// 本地 cbz 书 route 参数（与 Rust `import_local_book` 的 bookUrl 对齐）
const _kCbzBookUrl = 'file:///storage/books/本地漫画.cbz';
const _kEntry0 = 'cbz://01 封面.png';
const _kEntry1 = 'cbz://02.png';

/// 测试专用 MockBookApi：本地 cbz 书 + `cbz://` 正文章节 + 读页计数/失败注入
class _CbzMockApi extends MockBookApi {
  _CbzMockApi({
    this.failRead = false,
    this.pagedMode = false,
    this.longClickSaveImage = true,
  });

  /// true 时 cbzReadPage 抛异常（失败占位/重试断言）
  final bool failRead;

  /// true 时配置为单页式（mangaScrollMode=1）：验证屏幕加载即触发
  /// `_preloadVisibleImages → _preloadIndicesInRange` 的 cbz 预载路径
  final bool pagedMode;

  /// false 时长按弹页操作菜单（mangaLongClickSaveImage=false，对齐默认 true）
  final bool longClickSaveImage;

  /// cbzReadPage 调用序列（`path|entry`，用于缓存命中零重复调用断言）
  final List<String> readCalls = [];

  @override
  Future<List<BookSource>> getBookSources() async => const <BookSource>[];

  @override
  Future<String?> getConfig(String key) async {
    if (pagedMode && key == MangaConfigKeys.scrollMode) return '1';
    if (!longClickSaveImage &&
        key == MangaConfigKeys.mangaLongClickSaveImage) {
      return 'false';
    }
    return super.getConfig(key);
  }

  @override
  Future<Book?> getBook(String bookUrl) async {
    if (pagedMode) {
      // 屏幕 initState 并发 _loadMangaConfig 与 _loadBook：让纯微任务链的
      // 配置加载先落定（scrollMode=1），保证 _loadChapterImages 进入时
      // 已是分页模式、可命中 _preloadVisibleImages 的预载分支
      await Future<void>.delayed(Duration.zero);
    }
    return Book(
      bookUrl: bookUrl,
      name: '本地漫画',
      author: '本地导入',
      origin: BookType.localTag,
      originName: '本地漫画.cbz',
      // 与 Rust import_local_book 对齐：cbz = LOCAL|image = 0x1040
      bookType: BookType.local | BookType.image,
      totalChapterNum: 1,
    );
  }

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => [
        const BookChapter(index: 0, url: '', title: '本地漫画'),
      ];

  @override
  Future<String> getChapterContent(String bookUrl, int chapterIndex) async =>
      '$_kEntry0\n$_kEntry1';

  @override
  Future<String> cbzReadPage({
    required String path,
    required String entry,
  }) async {
    readCalls.add('$path|$entry');
    if (failRead) throw StateError('cbz 读页失败（模拟）');
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }
}

/// Image.memory（MemoryImage provider）定位器（skipOffstage 覆盖 ListView 懒加载）
Finder _memoryImageFinder() => find.byWidgetPredicate(
      (w) => w is Image && w.image is MemoryImage,
      skipOffstage: false,
    );

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: ReaderComicScreen(bookUrl: _kCbzBookUrl),
    ),
  );
}

void main() {
  // 屏幕渲染缓存为进程内静态 Map：用例前后清空，避免跨用例串扰
  setUp(ComicImageDecodeCache.clearForTest);
  tearDown(ComicImageDecodeCache.clearForTest);

  testWidgets('本地 cbz 书打开 → cbz:// 页经 cbzReadPage 渲染 Image.memory',
      (tester) async {
    final api = _CbzMockApi();
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    expect(api.readCalls, isNotEmpty,
        reason: '本地 cbz 页须经 BookApi.cbzReadPage 取图');
    expect(api.readCalls.any((c) => c.contains(_kEntry0)), isTrue,
        reason: 'cbz:// 条目行应逐行作为 entry 传入（含中文/空格条目名）');
    expect(_memoryImageFinder(), findsWidgets,
        reason: '校验通过的字节应以 Image.memory 渲染');
    expect(find.text('图片加载失败'), findsNothing,
        reason: '成功路径不得出现错误占位');
  });

  testWidgets('cbzReadPage 失败 → 错误占位 + 重试按钮；重试再次调用 cbzReadPage',
      (tester) async {
    final api = _CbzMockApi(failRead: true);
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 失败经 _LocalCbzImage.onError → 屏幕 _failedIndices → 页面级失败占位
    expect(find.text('图片加载失败'), findsWidgets);
    final retry = find.widgetWithText(OutlinedButton, '重试');
    expect(retry, findsWidgets, reason: '错误占位须提供重试按钮');

    final before = api.readCalls.length;
    await tester.tap(retry.first);
    await tester.pumpAndSettle();

    expect(api.readCalls.length, greaterThan(before),
        reason: '重试须经 _retryImage → 重建 _LocalCbzImage 再次调用 cbzReadPage');
    expect(find.text('图片加载失败'), findsWidgets,
        reason: '仍失败时保持错误占位');
  });

  testWidgets('cbz 页预载入缓存后正式渲染命中缓存（零重复 FFI 调用）',
      (tester) async {
    final api = _CbzMockApi();

    // 预载：与屏幕 _preloadIndicesInRange → _preloadCbzPage 同一入口与缓存键
    await ComicImageDecodeCache.preloadCbz(
      api: api,
      path: _kCbzBookUrl,
      cacheKey: _kCbzBookUrl,
      entry: _kEntry0,
    );
    expect(
      api.readCalls.where((c) => c.contains(_kEntry0)),
      hasLength(1),
      reason: '预载应调用一次 cbzReadPage 并写入缓存',
    );

    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    expect(
      api.readCalls.where((c) => c.contains(_kEntry0)),
      hasLength(1),
      reason: '预载命中缓存后正式渲染不得重复调用 cbzReadPage（零重复 FFI）',
    );
    expect(_memoryImageFinder(), findsWidgets,
        reason: '缓存命中应直接渲染 Image.memory');
  });

  testWidgets('单页式加载即预载 cbz 页：预载与渲染共用缓存，每页仅一次 FFI',
      (tester) async {
    final api = _CbzMockApi(pagedMode: true);
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 分页模式 _loadChapterImages 同步触发 _preloadIndicesInRange(±2 页)：
    // 两个 cbz 条目各预载一次；随后页面渲染须命中缓存、零重复调用
    expect(
      api.readCalls.where((c) => c.contains(_kEntry0)),
      hasLength(1),
      reason: '条目 0 预载一次后渲染须命中缓存',
    );
    expect(
      api.readCalls.where((c) => c.contains(_kEntry1)),
      hasLength(1),
      reason: '条目 1 预载一次后渲染须命中缓存',
    );
    expect(_memoryImageFinder(), findsWidgets,
        reason: '预载缓存命中应直接渲染 Image.memory');
    expect(find.text('图片加载失败'), findsNothing,
        reason: '预载/渲染链路不得出现错误占位');
  });

  testWidgets('cbz 页长按：菜单含保存/分享、隐藏复制链接；保存通道收到 PNG 字节',
      (tester) async {
    // MediaStore 直写通道 mock + Android 分派覆写（先例：click_actions D2）
    final channelCalls = <MethodCall>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(PlatformChannel.storage, (call) async {
      channelCalls.add(call);
      return 'Download/legado/manga-cbz.png';
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(PlatformChannel.storage, null),
    );
    PlatformBridgeService.instance.saveViaDownloadsOverride = true;
    addTearDown(
      () => PlatformBridgeService.instance.saveViaDownloadsOverride = null,
    );

    // mangaLongClickSaveImage=false → 长按弹页操作菜单
    final api = _CbzMockApi(longClickSaveImage: false);
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_buildApp(container));
    await tester.pumpAndSettle();

    // 渲染阶段已经 cbzReadPage 取到首页字节（内存缓存在场，保存零重复 FFI）
    expect(api.readCalls.any((c) => c.contains(_kEntry0)), isTrue);

    // 长按命中依赖 PNG 解码后的真实项高（先例：click_actions _settleImageDecode）
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();

    await tester.longPressAt(const Offset(400, 100));
    await tester.pumpAndSettle();

    expect(find.text('保存图片'), findsOneWidget, reason: 'cbz 页长按菜单须存在');
    expect(find.text('分享图片'), findsOneWidget);
    expect(find.text('复制链接'), findsNothing,
        reason: 'cbz:// 伪 URL 无消费价值 → cbz 页隐藏「复制链接」项');

    final before = api.readCalls.length;
    await tester.tap(find.text('保存图片'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));

    expect(
      api.readCalls.length,
      before,
      reason: '保存应命中渲染内存缓存（键 = 活跃 bookUrl + 条目名），零重复 FFI',
    );
    expect(channelCalls, hasLength(1), reason: '保存路径须调用 MediaStore 通道');
    final args = channelCalls.single.arguments as Map<Object?, Object?>;
    expect(args['fileName'], endsWith('.png'),
        reason: '文件名后缀按魔数推断');
    expect(
      (args['bytes'] as List<int>).take(4).toList(),
      equals(const [0x89, 0x50, 0x4E, 0x47]),
      reason: '通道 bytes 应为 cbzReadPage 返回的 PNG 字节',
    );
    expect(find.textContaining('已保存: Download/legado/'), findsOneWidget);
  });
}
