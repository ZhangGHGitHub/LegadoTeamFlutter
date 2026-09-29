// [P4-3 E5] 漫画屏九区点击 + 长按菜单（分享/复制/存图）
//
// 取证（参考版，legado-with-MD3）：
// - ui/book/manga/MangaReaderInteraction.kt L15-24 mangaClickRegionIndex
//   （3x3 网格 row*3+column；coerceAtLeast(1) 防零除），L26-32
//   mangaClickActionAt（getOrNull ?: 0），L34-41 nextMangaClickAction
//   （-1→0→1→2→3→4→-1 循环）；
// - ui/book/manga/MangaReaderContract.kt L132 longPressEnabled 默认 true，
//   L167 clickActions 默认 [-1, -1, 1, 2, 0, 1, 2, 1, 1]；
// - ui/book/manga/MangaReaderScreen.kt L705-736（条漫点击 1/2=滚一屏）、
//   L737-796（条漫长按 → LongPressPage）、L1082-1095（单页 onLongClick）、
//   L1945-1969 动作语义（-1 无 / 0 菜单 / 1 下一页 / 2 上一页 /
//   3 下一章 / 4 上一章）；
// - ui/book/manga/MangaReaderSheets.kt L179-252 页面操作底栏
//   （单页：保存图片/分享/复制/设置封面；宽页 spread 变体不在范围）；
// - 参考版 ReadMangaActivity.kt L149-154：ShareImage → share(临时文件,
//   "image/jpeg")；CopyImage → ClipboardManager.setPrimaryClip(
//   ClipData.newUri(...))（URI 复制）；
// - 原版 ReadMangaActivity.kt L242-276：长按存图（用户先选目录，
//   文件写入所选目录）+ L559/L750 menu_manga_long_click_save_image 开关。
//
// 本测试验证：
// 1. 九区映射 / 边界收敛 / 零尺寸视口 / 动作解析 / 短列表回退 /
//    动作循环 / 默认值（纯函数，对齐参考版单元测试期望值）；
// 2. 页面图片字节解析：内存命中（不触碰 API）/ 磁盘命中 / FFI 回退 /
//    全空 → null；
// 3. 单页 L2R(1)：右上点击 → 下一页、左中点击 → 上一页（页脚 + 进度）；
// 4. 条漫：右上点击 → 下滚一屏（恰好一个视口高、无切章副作用）；
//    左上点击（-1）无任何副作用；
// 5. 中心点击（action 0）→ 控制栏显隐切换；
// 6. 长按图片项 → 底栏菜单（保存图片/分享图片/复制链接）；点「复制链接」
//    → 剪贴板写入图片链接（参考版 CopyImage 的文本降级，见实现说明）。
//
// [P4-3 W2-fix P1-2] 条漫点击「下一页」距章尾不足一视口时：先滚完剩余
// 距离到章尾（部分消费），真正到章边界（consumed < 1）才切下一章
//（对齐参考版 performWebtoonTap L705-732）。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_click_actions.dart';
import 'package:flutter_legado/src/screens/reader_comic/manga_page_image_resolver.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// 1x1 透明 PNG（RGBA，68 字节，CRC 校验通过的合法编码）
///
/// 注意：reader_comic_scroll_mode_test 等早期文件共享的 1x1 PNG 常量
/// IDAT 块 CRC 损坏，引擎 codec 会拒解（Image errorBuilder 回退占位）；
/// 条漫滚动用例依赖图片解码后的真实项高，故此处使用合法字节。
const _kPngBase64 =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8'
    'AAAAASUVORK5CYII=';

/// 含 imageDecode 规则的漫画书源（对齐 favcomic 形态）
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

/// [P4-3 E5] 测试 Mock：可注入滚动模式 / 磁盘缓存 / 记录进度与解码调用
///
/// [W2-fix] 新增 [chapterCount] 注入（条漫章尾部分消费切章用例需多章）
class _ClickActionsMockApi extends MockBookApi {
  _ClickActionsMockApi({
    required this.source,
    required this.progressCalls,
    Map<String, String>? configs,
    this.durChapterPos = 0,
    this.imageCount = 3,
    this.chapterCount = 1,
    this.diskBytes,
  }) : _configs = configs ?? {};

  final BookSource source;
  /// 进度写入记录 [[chapterIndex, chapterPos], ...]
  final List<List<int>> progressCalls;
  final Map<String, String> _configs;
  final int durChapterPos;
  final int imageCount;
  final int chapterCount;
  /// 磁盘缓存注入（null = 未命中）
  final List<int>? diskBytes;
  final List<String> decodeCalls = [];
  int imageCacheCalls = 0;

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
        totalChapterNum: chapterCount,
        durChapterPos: durChapterPos,
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
    decodeCalls.add(url);
    return jsonEncode({'base64': _kPngBase64, 'len': 68});
  }

  @override
  Future<String?> getConfig(String key) async => _configs[key];

  @override
  Future<void> setConfig(String key, String value) async {
    _configs[key] = value;
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
  Future<List<int>?> getImageCache(String bookUrl, String url) async {
    imageCacheCalls++;
    return diskBytes;
  }
}

Widget _buildApp(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://comic/1')),
  );
}

_ClickActionsMockApi _buildApi({
  Map<String, String>? configs,
  int durChapterPos = 0,
  int imageCount = 3,
  int chapterCount = 1,
  List<int>? diskBytes,
  required List<List<int>> progressCalls,
}) {
  return _ClickActionsMockApi(
    source: _buildComicSource(),
    progressCalls: progressCalls,
    configs: configs,
    durChapterPos: durChapterPos,
    imageCount: imageCount,
    chapterCount: chapterCount,
    diskBytes: diskBytes,
  );
}

Future<void> _pumpScreen(
  WidgetTester tester,
  _ClickActionsMockApi api,
  ProviderContainer container,
) async {
  await tester.pumpWidget(_buildApp(container));
  // 等待异步加载（getBook → getChapters → fetchChapterContent → 解码渲染）
  await tester.pumpAndSettle();
  // 条漫/长按用例依赖图片解码后的真实项高（见 settleImageDecode）
  await _settleImageDecode(tester);
}

/// 等待引擎完成 PNG 解码（真实事件循环，供条漫内容高度生效）
///
/// 条漫项的 [Image.memory] 解码走引擎平台线程，其完成回调是真实异步——
/// [WidgetController.pumpAndSettle] 只推进假时间，等不到它；未解码时
/// 图片项高度为 0（intrinsic size 未知），可滚动范围为 0，「下滚一屏」
/// 会被误判为章节末尾（触发无操作切章）。[runAsync] 让真实事件循环
/// 转一轮，解码回调到达后 [pump] 一帧让布局按解码尺寸重排。
Future<void> _settleImageDecode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

/// 等待滚动范围稳定并返回稳定值（[W2-fix]）
///
/// 图片项「占位（屏高 0.6）→ FFI 解码后真实高度」的切换发生在真实事件
/// 循环（每 200ms 一轮 [runAsync] + 一帧布局），收敛前 [ScrollPosition]
/// 的 maxScrollExtent 会漂移，条漫「距章尾定位」用例须先等其稳定。
Future<double> _settleExtentStable(WidgetTester tester) async {
  var prev = -1.0;
  for (var i = 0; i < 10; i++) {
    await _settleImageDecode(tester);
    final cur = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .maxScrollExtent;
    if (cur > 0 && cur == prev) return cur;
    prev = cur;
  }
  return prev;
}

/// mock 系统剪贴板通道（setData 记录写入文本；getData 返回空）。
/// 先例：replace_rule_edit_test.dart mockClipboard（SDK 3.44 方法名
/// Clipboard.*；兼容旧版 SystemClipboard.*）。
List<String> mockClipboard(WidgetTester tester) {
  final written = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
        case 'SystemClipboard.setData':
          final args = call.arguments as Map<Object?, Object?>;
          // 本 SDK 版本 setData 参数即 {'text': ...}（SDK clipboard.dart L36-39）
          final value = args['text'] ?? args['value'];
          if (value is Map) {
            written.add(value['text'] as String? ?? '');
          } else if (value is String) {
            written.add(value);
          }
          return null;
        case 'Clipboard.getData':
        case 'SystemClipboard.getData':
          return null;
        default:
          return null;
      }
    },
  );
  return written;
}

void main() {
  group('[P4-3 E5] 九区点击区域（对齐 mangaClickRegionIndex）', () {
    test('九区映射：900x1800 视口每格中心点 → 0..8（参考测试同值）', () {
      const w = 900.0;
      const h = 1800.0;
      const cells = [
        (150.0, 300.0, 0),
        (450.0, 300.0, 1),
        (750.0, 300.0, 2),
        (150.0, 900.0, 3),
        (450.0, 900.0, 4),
        (750.0, 900.0, 5),
        (150.0, 1500.0, 6),
        (450.0, 1500.0, 7),
        (750.0, 1500.0, 8),
      ];
      for (final cell in cells) {
        expect(
          MangaClickActions.regionIndex(cell.$1, cell.$2, w, h),
          cell.$3,
          reason: '(${"${cell.$1},${cell.$2}"}) → 期望区 ${cell.$3}',
        );
      }
    });

    test('边界外触摸收敛到边缘区域（-20,-20 → 0；920,1820 → 8）', () {
      expect(MangaClickActions.regionIndex(-20, -20, 900, 1800), 0);
      expect(MangaClickActions.regionIndex(920, 1820, 900, 1800), 8);
    });

    test('零尺寸视口不抛异常（宽度/高度按 1 兜底，参考版 coerceAtLeast(1)）',
        () {
      // 1/(1/3)=3 → 收敛到 2；区域 = 2*3+2 = 8
      expect(MangaClickActions.regionIndex(1, 1, 0, 0), 8);
    });

    test('动作解析：点 → 区域 → 动作（参考测试示例列表）', () {
      const actions = [-1, 0, 3, 2, 0, 1, 4, 1, 2];
      // 900x1800：(750,300)→区2→3；(150,900)→区3→2；
      // (150,1500)→区6→4；(450,900)→区4→0
      expect(MangaClickActions.actionAt(actions, 750, 300, 900, 1800), 3);
      expect(MangaClickActions.actionAt(actions, 150, 900, 900, 1800), 2);
      expect(MangaClickActions.actionAt(actions, 150, 1500, 900, 1800), 4);
      expect(MangaClickActions.actionAt(actions, 450, 900, 900, 1800), 0);
    });

    test('列表不足 9 项时越界区回退 0（对齐 getOrNull ?: 0）', () {
      expect(MangaClickActions.actionAt(const [-1, -1], 450, 900, 900, 1800), 0);
    });

    test('动作循环 -1→0→1→2→3→4→-1（对齐 nextMangaClickAction）', () {
      expect(MangaClickActions.cycleNext(-1), 0);
      expect(MangaClickActions.cycleNext(0), 1);
      expect(MangaClickActions.cycleNext(1), 2);
      expect(MangaClickActions.cycleNext(2), 3);
      expect(MangaClickActions.cycleNext(3), 4);
      expect(MangaClickActions.cycleNext(4), -1);
    });

    test('默认 clickActions（对齐 Contract L167）', () {
      expect(MangaClickActions.defaultActions, const [-1, -1, 1, 2, 0, 1, 2, 1, 1]);
    });
  });

  group('[P4-3 E5] 页面图片字节解析（内存 → 磁盘 → FFI 回退）', () {
    final progressCalls = <List<int>>[];
    _ClickActionsMockApi api({List<int>? diskBytes}) {
      return _ClickActionsMockApi(
        source: _buildComicSource(),
        progressCalls: progressCalls,
        diskBytes: diskBytes,
      );
    }

    final pngBytes = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01, 0x02
    ]);

    test('内存缓存命中：直接返回，不触碰磁盘/FFI API', () async {
      final a = api();
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
        memoryCached: pngBytes,
      );
      expect(result, isNotNull);
      expect(result!.bytes, equals(pngBytes));
      expect(result.suffix, '.png');
      expect(a.imageCacheCalls, 0, reason: '内存命中不应再查磁盘');
    });

    test('内存未命中 → 磁盘缓存命中（jpg 魔数 → 后缀 .jpg）', () async {
      final disk = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x01];
      final a = api(diskBytes: disk);
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
      );
      expect(result, isNotNull);
      expect(result!.bytes, equals(disk));
      expect(result.suffix, '.jpg');
      expect(a.imageCacheCalls, 1);
    });

    test('双未命中 + 提供 sourceJson → FFI 解码回退（base64 → PNG）',
        () async {
      final a = api();
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
        sourceJson: '"{}"',
      );
      expect(result, isNotNull, reason: 'FFI 回退应解出 PNG 字节');
      expect(result!.suffix, '.png');
      expect(a.decodeCalls, ['https://cdn.example.com/img/0.jpg']);
    });

    test('缓存全空且无 sourceJson → null（不旁路直连）', () async {
      final a = api();
      final result = await resolveMangaPageImageBytes(
        api: a,
        bookUrl: 'mock://comic/1',
        url: 'https://cdn.example.com/img/0.jpg',
      );
      expect(result, isNull);
      expect(a.decodeCalls, isEmpty, reason: '无 sourceJson 不得走 FFI 解码');
    });
  });

  group('[P4-3 E5] 九区点击 + 长按菜单（整页行为）', () {
    // 测试视口 800x600：列界 0/267/533/800，行界 0/200/400/600。
    // 默认 clickActions[-1,-1,1,2,0,1,2,1,1]：
    //   左上(133,100) 区0 → -1 无；右上(667,100) 区2 → 1 下一页；
    //   左中(133,300) 区3 → 2 上一页；中心(400,300) 区4 → 0 菜单。

    testWidgets('单页 L2R：右上点击 → 下一页；左中点击 → 上一页',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(
        configs: const {'mangaScrollMode': '1'},
        progressCalls: progressCalls,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 右上区（区2）action 1 → 下一页
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数2/3'), findsOneWidget);
      expect(progressCalls, contains(equals([0, 1])));

      // 左中区（区3）action 2 → 上一页
      await tester.tapAt(const Offset(133, 300));
      await tester.pumpAndSettle();
      expect(find.textContaining('页数1/3'), findsOneWidget);
    });

    testWidgets('条漫：右上点击 → 下滚一屏（恰好一个视口高，无副作用）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.byType(ListView), findsWidgets);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      // 顶部初始位置
      final pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos.pixels, closeTo(0, 0.01));

      // 右上区（区2）action 1 → 条漫下滚一屏（参考版 MangaReaderScreen
      // L705-736「滚一屏」= 一个视口高；条漫无页单位，页脚页数在顶部
      // 因懒加载估算 maxScrollExtent 不变，属预期，不在此断言）
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      final pos2 =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos2.pixels, closeTo(600, 1),
          reason: '一屏 = 视口高 600（animateTo 300ms 终止于目标）');
      // 无切章副作用：单章未跳章，未触发章末切章
      expect(find.textContaining('章节1/1'), findsOneWidget);
      // 页级估算未变（顶部一屏后仍为第 0 页）→ 不产生进度写入
      expect(progressCalls, isEmpty);
    });

    // [P4-3 W2-fix P1-2] 对齐参考版 performWebtoonTap（L705-732）：
    // animateScrollBy 部分消费（目标被章边界钳制），只有真正已在章边界
    //（consumed < 1）才切章；旧实现距章尾不足一视口时直接跳章、
    // 跳过剩余内容。
    testWidgets('条漫：距章尾不足一视口点「下一页」先滚完剩余再切章（P1-2）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls, chapterCount: 2);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // [W2-fix] 先滚到底部强制构建尾部项（末张图 + 底部章节导航），
      // 再等滚动范围稳定：ListView.builder 对未构建尾部项按「已构建项
      // 平均高度」估算 maxScrollExtent（底部导航实际 ~148px 会被估算成
      // 800px，extent 虚高 652px），未滚到底前读到的稳定值不可信；
      // 滚到底后全部项已构建，extent 收敛到实际值（3×800+148−600=1948）
      final pos =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      pos.jumpTo(100000); // 越界 → jumpTo 收敛到当前 maxScrollExtent
      await tester.pump();
      final extent = await _settleExtentStable(tester);
      expect(extent, greaterThan(600),
          reason: '三页内容高应超过一个视口（600px）');

      // 移到距章尾不足一视口（600px）处：剩余 300px
      pos.jumpTo(extent - 300);
      await tester.pump();

      // 右上区（区2，action 1）= 下一页：先滚完剩余 300px 到章尾
      //（目标被章边界钳制、部分消费），不切章
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      final pos2 =
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      expect(pos2.pixels, closeTo(pos2.maxScrollExtent, 1),
          reason: '应滚完剩余距离停在章尾（对齐 animateScrollBy 部分消费；'
              'extent 用 settle 后重读值，防解码期漂移）');
      expect(find.textContaining('章节1/2'), findsOneWidget,
          reason: '未真正到章边界（consumed ≥ 1）不应切章'
              '（旧实现 target > maxScrollExtent 即跳章、跳过章尾内容）');

      // 再点：已停在章边界（无可滚距离）→ 切下一章
      await tester.tapAt(const Offset(667, 100));
      await tester.pumpAndSettle();
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '章边界处点「下一页」= 切下一章（consumed < 1 语义）');
    });

    testWidgets('左上点击（区0 = 无动作）：无控制栏、无滚动、无进度',
        (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      await tester.tapAt(const Offset(133, 100));
      await tester.pumpAndSettle();

      // 控制栏未出现（顶栏书名文本不在树中）
      expect(find.text('测试漫画'), findsNothing);
      // 仍停在第 1 页，未产生进度写入
      expect(find.textContaining('页数1/3'), findsOneWidget);
      expect(progressCalls, isEmpty);
    });

    testWidgets('中心点击（action 0）→ 控制栏显隐切换', (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      expect(find.text('测试漫画'), findsNothing);
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsOneWidget,
          reason: '中心点击 = 菜单动作，顶栏（书名）应出现');

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(find.text('测试漫画'), findsNothing,
          reason: '再次中心点击应收起控制栏');
    });

    testWidgets('长按图片项 → 底栏菜单（保存/分享/复制链接）', (tester) async {
      final progressCalls = <List<int>>[];
      final api = _buildApi(progressCalls: progressCalls);
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await _pumpScreen(tester, api, container);

      // 长按第 1 张图（顶部区域）
      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      expect(find.text('保存图片'), findsOneWidget);
      expect(find.text('分享图片'), findsOneWidget);
      // [W2-fix P2-4] 复制的是图片链接文本（URI 复制降级），文案对齐行为
      expect(find.text('复制链接'), findsOneWidget);

      // 点「复制链接」→ 关闭菜单 + 剪贴板写入图片链接
      final written = mockClipboard(tester);
      await tester.tap(find.text('复制链接'));
      await tester.pumpAndSettle();
      expect(find.text('复制链接'), findsNothing, reason: '菜单应已关闭');
      expect(
        written,
        contains('https://cdn.example.com/img/0.jpg'),
        reason: '复制链接 = 图片链接文本（参考版 CopyImage 的文本降级）',
      );
      expect(find.text('已复制图片链接'), findsOneWidget);
    });
  });
}
