// [P4-3 M5] 音量键翻页行为 + 九宫格点击区编辑器
//
// 依据：
// - 原版 ReadMangaActivity.kt L894-902（onKeyDown：KEYCODE_VOLUME_UP→
//   上一页、KEYCODE_VOLUME_DOWN→下一页、return true 消费不调系统音量）；
//   参考版 reverseVolumeKeyPage 反转方向（默认 false）
// - 参考版 MangaSettingsPanel.kt L772-802 ClickActionsSettingsContent：
//   3x3 网格每格显示动作名，点击循环切换（nextMangaClickAction
//   -1→0→1→2→3→4→-1）；动作文案：无操作/菜单/下一页/上一页/下一章/上一章
//
// 覆盖：
// 1. 进屏后经 legado/reader_keys 通道开启音量键捕获（setVolumeKeyCapture
//    true），volumeKeyPage=false 时不开启
// 2. 原生事件 volumeKey down/up → 下一页/上一页（单页模式页脚断言）
// 3. reverseVolumeKeyPage=true 交换方向
// 4. 点击区网格渲染 9 格 + 动作标签（默认配置逐格核对）
// 5. 点击格循环切换（菜单→下一页）+ 持久化 mangaClickActions
// 6. 配置改 clickActions 后屏内即时生效（左上格 -1→1 后点击左上翻页）
// 7. MangaClickActions 纯函数（cycleNext/labelOf/parse/serialize）
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_click_actions.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/platform_bridge_service.dart';

/// 1x1 透明 PNG（合法 68 字节编码；同 auto_read/page_scale 先例）
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8'
    'AAAAASUVORK5CYII=';

/// M5 测试 Mock：3 章 × 3 图；记录配置写入
class _M5MockApi extends MockBookApi {
  _M5MockApi({required this.configWrites, Map<String, String>? configs})
      : _configs = configs ?? {};

  static const int imageCount = 3;
  static const int chapterCount = 3;

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
        totalChapterNum: chapterCount,
        durChapterPos: 0,
      );

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => List.generate(
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
  }) async {}

  @override
  Future<List<int>?> getImageCache(String bookUrl, String url) async => null;
}

/// 建屏（单页模式：页脚「页数N/3」为最可靠落点断言；
/// 配置经 [_M5MockApi] 构造注入）
Future<void> _pumpReader(WidgetTester tester, _M5MockApi api) async {
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
}

/// 模拟原生端回发音量键事件（MainActivity.onKeyDown →
/// invokeMethod('volumeKey', 'up'/'down')）
Future<void> _emitVolumeKey(WidgetTester tester, String direction) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'legado/reader_keys',
    const StandardMethodCodec()
        .encodeMethodCall(MethodCall('volumeKey', direction)),
    (_) {},
  );
  await tester.pumpAndSettle();
}

/// 打开漫画设置面板（控制栏 → 底栏「翻页设置」键）
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tapAt(const Offset(400, 300));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('翻页设置'));
  await tester.pumpAndSettle();
}

void main() {
  final readerKeyCalls = <MethodCall>[];

  setUp(() {
    readerKeyCalls.clear();
    // 测试宿主（Windows）Platform.isAndroid=false：经分派覆写走 Android 分支
    PlatformBridgeService.instance.volumeKeyCaptureOverride = true;
  });

  tearDown(() {
    PlatformBridgeService.instance.volumeKeyCaptureOverride = null;
  });

  group('[P4-3 M5-1] 音量键翻页', () {
    testWidgets('进屏开启捕获（volumeKeyPage 默认 true → setVolumeKeyCapture true）',
        (tester) async {
      // 注意：setMockMethodCallHandler 会拦截该通道入站投递（实证），
      // 故「出站记录断言」与「入站事件翻页断言」分测试执行；
      // 本用例只验证捕获开启（出站）。
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('legado/reader_keys'),
        (call) async {
          readerKeyCalls.add(call);
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('legado/reader_keys'), null);
      });

      final api = _M5MockApi(
        configWrites: <List<String>>[],
        configs: {'mangaScrollMode': '1'},
      );
      await _pumpReader(tester, api);

      expect(
        readerKeyCalls.any((c) =>
            c.method == 'setVolumeKeyCapture' && c.arguments == true),
        isTrue,
        reason: '进屏（volumeKeyPage 默认 true）应开启音量键捕获',
      );
    });

    testWidgets('volumeKey down/up 翻页（入站事件直达屏内导航链）', (tester) async {
      final api = _M5MockApi(
        configWrites: <List<String>>[],
        configs: {'mangaScrollMode': '1'},
      );
      await _pumpReader(tester, api);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // down = 下一页（原版 scrollToNext）
      await _emitVolumeKey(tester, 'down');
      expect(find.textContaining('页数2/3'), findsOneWidget);

      // up = 上一页（原版 scrollToPrev）
      await _emitVolumeKey(tester, 'up');
      expect(find.textContaining('页数1/3'), findsOneWidget);
    });

    testWidgets('reverseVolumeKeyPage=true：up=下一页（方向反转）', (tester) async {
      final api = _M5MockApi(
        configWrites: <List<String>>[],
        configs: {
          'mangaScrollMode': '1',
          'reverseVolumeKeyPage': 'true',
        },
      );
      await _pumpReader(tester, api);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 反转后 up = 下一页
      await _emitVolumeKey(tester, 'up');
      expect(find.textContaining('页数2/3'), findsOneWidget);
    });

    testWidgets('volumeKeyPage=false：不开启捕获', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('legado/reader_keys'),
        (call) async {
          readerKeyCalls.add(call);
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('legado/reader_keys'), null);
      });

      final api = _M5MockApi(
        configWrites: <List<String>>[],
        configs: {
          'mangaScrollMode': '1',
          'volumeKeyPage': 'false',
        },
      );
      await _pumpReader(tester, api);
      await tester.pumpAndSettle();

      expect(
        readerKeyCalls.any((c) =>
            c.method == 'setVolumeKeyCapture' && c.arguments == true),
        isFalse,
        reason: '开关关闭时不应开启捕获（系统音量键保持默认行为）',
      );
    });
  });

  group('[P4-3 M5-2] 九宫格点击区编辑器', () {
    testWidgets('网格渲染 9 格 + 默认动作标签；点击循环切换并持久化', (tester) async {
      final configWrites = <List<String>>[];
      final api = _M5MockApi(
        configWrites: configWrites,
        configs: {'mangaScrollMode': '1'},
      );
      await _pumpReader(tester, api);
      await _openSheet(tester);

      // 面板为惰性列表：「点击区域」区块在底部，先滚动到可见
      // （M4 先例：dragUntilVisible 后断言）
      await tester.dragUntilVisible(
        find.text('点击区域'),
        find.byType(Scrollable).last,
        const Offset(0, -300),
      );
      await tester.pumpAndSettle();

      // 「点击区域」区块 + 9 格（默认 [-1,-1,1,2,0,1,2,1,1] 逐格标签）
      expect(find.text('点击区域'), findsOneWidget);
      for (var i = 0; i < 9; i++) {
        expect(find.byKey(ValueKey('mangaClickActionCell-$i')),
            findsOneWidget,
            reason: '第 $i 格应渲染');
      }
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mangaClickActionCell-0')),
          matching: find.text('无操作'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mangaClickActionCell-2')),
          matching: find.text('下一页'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mangaClickActionCell-4')),
          matching: find.text('菜单'),
        ),
        findsOneWidget,
      );

      // 点击中间格（菜单）→ cycleNext(0)=1 下一页
      await tester.tap(find.byKey(const ValueKey('mangaClickActionCell-4')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('mangaClickActionCell-4')),
          matching: find.text('下一页'),
        ),
        findsOneWidget,
        reason: '点击循环：菜单(0) → 下一页(1)',
      );
      expect(
        configWrites,
        contains(equals(['mangaClickActions', '[-1,-1,1,2,1,1,2,1,1]'])),
        reason: '循环切换应持久化完整九值 JSON 数组',
      );
    });

    testWidgets('配置 clickActions 改左上格为 1（下一页）→ 屏内点击左上翻页',
        (tester) async {
      final api = _M5MockApi(
        configWrites: <List<String>>[],
        configs: {
          'mangaScrollMode': '1',
          // 左上格由 -1 改为 1=下一页（其余对齐默认）
          'mangaClickActions': '[1,-1,1,2,0,1,2,1,1]',
        },
      );
      await _pumpReader(tester, api);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 点击左上区（800x600 测试表面 → 左上格中心约 (133, 100)）
      await tester.tapAt(const Offset(133, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget,
          reason: '左上格配置为 1（下一页）后点击应翻页');
    });
  });

  group('[P4-3 M5] MangaClickActions 纯函数', () {
    test('cycleNext 循环 -1→0→1→2→3→4→-1（对齐参考版 nextMangaClickAction）',
        () {
      expect(MangaClickActions.cycleNext(-1), 0);
      expect(MangaClickActions.cycleNext(0), 1);
      expect(MangaClickActions.cycleNext(4), -1);
    });

    test('labelOf 动作文案逐值（对齐参考版 labels）', () {
      expect(MangaClickActions.labelOf(-1), '无操作');
      expect(MangaClickActions.labelOf(0), '菜单');
      expect(MangaClickActions.labelOf(1), '下一页');
      expect(MangaClickActions.labelOf(2), '上一页');
      expect(MangaClickActions.labelOf(3), '下一章');
      expect(MangaClickActions.labelOf(4), '上一章');
    });

    test('parse/serialize 往返 + 非法输入回默认配置', () {
      const list = [1, 2, 3, 4, 0, -1, 2, 1, 1];
      expect(MangaClickActions.parse(MangaClickActions.serialize(list)), list);
      expect(MangaClickActions.parse(null), MangaClickActions.defaultActions);
      expect(MangaClickActions.parse('bad-json'),
          MangaClickActions.defaultActions);
      expect(MangaClickActions.parse('[0,0]'),
          MangaClickActions.defaultActions,
          reason: '长度不符回默认');
      expect(
        MangaClickActions.parse('[9,0,0,0,0,0,0,0,0]'),
        [MangaClickActions.none, 0, 0, 0, 0, 0, 0, 0, 0],
        reason: '越界动作归一化为 -1（无操作）',
      );
    });
  });
}
