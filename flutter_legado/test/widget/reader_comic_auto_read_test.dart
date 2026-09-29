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
// 3. 条漫（模式 4）：自动滚动**先滚完剩余距离到章末**（部分消费，
//    不跳过章尾内容）→ 500ms 延迟 → 自动切下一章（两章 mock 端到端）；
// 4. [W2-fix P2-1] 长按页操作底栏打开期间自动翻页暂停，关闭后恢复。
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

/// 等待引擎完成 PNG 解码（真实事件循环，供条漫项真实高度生效）
///
/// 同 reader_comic_click_actions_test._settleImageDecode 先例：未解码时
/// 图片项高度为 0，条漫可滚动范围为 0，「章末」判定与页级进度写入
///（_onScroll 在 maxScrollExtent = 0 时跳过）均不成立。
Future<void> _settleImageDecode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
}

/// 等待滚动范围稳定并返回稳定值（[W2-fix]）
///
/// 图片项「占位（屏高 0.6）→ FFI 解码后真实高度」的切换发生在真实事件
/// 循环（每 200ms 一轮 [runAsync] + 一帧布局），收敛前 maxScrollExtent
/// 会漂移，条漫「章尾时序推演」用例须先等其稳定。
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

    // [P4-3 W2-fix P1-1] 条漫自动滚动对齐参考版 autoScrollWebtoon：
    // 每周期 animateScrollBy(10000px) 部分消费——距章尾不足 10000px
    // 时先滚完剩余距离（consumed 被边界钳制），真正到章末（consumed<1）
    // 才 delay(500L) 切章；旧实现「target ≥ maxScrollExtent 即切章」
    // 会在距章尾不足 10000px 时跳过章尾内容，本用例以章尾可见页
    // 进度 [0,2] 的写入锁定「先滚完再切章」行为。
    testWidgets('条漫：距章尾不足一周期先滚完剩余距离再切章（P1-1）',
        (tester) async {
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
      // [W2-fix] 真实解码 + 等滚动范围稳定（占位 → 解码高度收敛；
      // 条漫项 3×800px 内容高，章尾约 1800px < 10000px）
      final extent = await _settleExtentStable(tester);
      expect(extent, greaterThan(0), reason: '解码后应可滚动');
      expect(extent, lessThan(10000),
          reason: '章尾距顶部不足一个周期滚动量 10000px'
              '（用例时序按「一周期滚完剩余距离」推演）');

      // [W2-fix] 定时器相位与解码收敛循环的真实时间推进耦合（范围稳定
      // 期间假时钟同步前移），首个周期可能仍在飞行，固定泵序列不可推演
      // → 以 1s 步长有界等待章末切章：两个完整周期（2×10667ms）+
      // 500ms 切章延迟 + 相位余量，40 步足够覆盖。关键断言是**次序**：
      // 章尾进度 [0,2]（可见页 = 末页）先于新章 [1,0] 写入——即
      // 「先滚完章尾再切章」；旧实现「target ≥ maxScrollExtent 即切章」
      // 直接跳章、不产生 [0,2]，本用例在旧实现下为红。
      int iEnd = -1;
      int iNext = -1;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 1000));
        iEnd = progressCalls
            .indexWhere((c) => c.length == 2 && c[0] == 0 && c[1] == 2);
        iNext = progressCalls
            .indexWhere((c) => c.length == 2 && c[0] == 1 && c[1] == 0);
        if (iNext >= 0) break;
      }
      expect(iEnd, greaterThanOrEqualTo(0),
          reason: '应先滚完章 1 章尾（可见页 = 末页 2 写入进度 [0,2]），'
              '旧实现「target ≥ maxScrollExtent 即切章」不产生该写入');
      expect(iNext, greaterThan(iEnd),
          reason: '章尾进度 [0,2] 应先于新章章首进度 [1,0]'
              '（先滚完再切章，不跳过章尾内容）');
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '条漫自动滚动到章末应自动进入下一章');

      // 收尾：关自动翻页（取消周期定时器，避免测试残留活动 Timer）
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('漫画设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '自动翻页'));
      await tester.pumpAndSettle();
      await _closeSheetAndControls(tester);
    });

    // [P4-3 W2-fix P2-1] 对齐参考版 LaunchedEffect 依赖 activeSheet：
    // 长按页操作底栏打开期间自动翻页暂停（旧实现仅 _showControls 守卫），
    // 关闭后从新周期恢复。
    // 时序设计：速度档 15（周期 15s ≫ 长按 500ms 持有窗口）——
    // 首个 tick 落在底栏打开之后，长按与定时器 tick 无重建竞态；
    // 底栏打开期间两个周期 tick 应全部被 _pageActionsOpen 守卫暂停。
    testWidgets('自动翻页：页操作底栏打开期间暂停、关闭后恢复（P2-1）',
        (tester) async {
      final progressCalls = <List<int>>[];
      final configWrites = <List<String>>[];
      // 单页式（模式 1）+ 速度档 15（15s/页，见上时序设计）
      final api = _AutoReadMockApi(
        progressCalls: progressCalls,
        configWrites: configWrites,
        configs: {'mangaScrollMode': '1', 'mangaAutoReadSpeed': '15'},
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://c4')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('页数1/3'), findsOneWidget);

      await _enableAutoRead(tester);
      await _closeSheetAndControls(tester);

      // 长按打开页操作底栏（首个 15s 周期内无 tick，长按不被重建打断）
      await tester.longPressAt(const Offset(400, 100));
      await tester.pumpAndSettle();
      expect(find.text('保存图片'), findsOneWidget,
          reason: '页操作底栏应已打开');

      // 底栏打开期间两个完整周期（tick @15s / @30s）→ 全部被
      // _pageActionsOpen 守卫暂停（页码不前进；旧实现仅 _showControls
      // 守卫，底栏打开仍翻页，本断言在旧实现下必然失败）
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(seconds: 15));
      expect(find.textContaining('页数1/3'), findsOneWidget,
          reason: '底栏打开期间定时器 tick 应被暂停（页码不前进）');

      // 关闭底栏（barrier 点击）→ 恢复
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();
      expect(find.text('保存图片'), findsNothing, reason: '底栏应已关闭');

      // 下一周期（@45s，距关栏 ≤15s）→ 自动翻到第 2 页
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.textContaining('页数2/3'), findsOneWidget,
          reason: '底栏关闭后自动翻页应从周期恢复');

      // 收尾：关自动翻页（取消周期定时器，避免测试残留活动 Timer）
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('漫画设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '自动翻页'));
      await tester.pumpAndSettle();
      await _closeSheetAndControls(tester);
    });
}
