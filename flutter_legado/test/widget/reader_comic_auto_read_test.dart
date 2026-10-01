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
import 'package:flutter_legado/src/screens/reader_comic/manga_auto_read.dart';
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

/// [W2-fix ⑬] 当前测试表面逻辑尺寸的**正中点**：九区点击按「视口 3×3
/// 分区」判定，中心区（row1×col1）= 动作 0 = 控制栏显隐。用例改测试
/// 表面尺寸（如 ⑬ 的 480×800 纵屏）后，写死的 (400,300) 不再是正中、
/// 会落入其它九区（触发翻页/滚动而非开控制栏），故统一按实际表面取正中。
Offset _centerOffset(WidgetTester tester) {
  final logical = tester.view.physicalSize / tester.view.devicePixelRatio;
  return Offset(logical.width / 2, logical.height / 2);
}

/// 打开「自动翻页」开关（控制栏 → 设置面板 → 开关），返回已打开的 sheet
Future<void> _enableAutoRead(WidgetTester tester) async {
  // 中心点击 → 控制栏显示
  await tester.tapAt(_centerOffset(tester));
  await tester.pumpAndSettle();
  // 底栏「翻页设置」键（[P4-3 M1] 菜单对齐参考版后入口改底栏）
  await tester.tap(find.byTooltip('翻页设置'));
  await tester.pumpAndSettle();
  // 「自动翻页」开关（SwitchListTile 标题定位，避免命中灰度/电子纸开关）
  final switchTile = find.widgetWithText(SwitchListTile, '自动翻页');
  expect(switchTile, findsOneWidget);
  await tester.tap(switchTile);
  await tester.pumpAndSettle();
}

/// 关闭设置面板（barrier 点击）并收起控制栏，回到沉浸态
Future<void> _closeSheetAndControls(WidgetTester tester) async {
  final center = _centerOffset(tester);
  // barrier → 关 sheet（顶部正中，避开底部 sheet 内容）
  await tester.tapAt(Offset(center.dx, 20));
  await tester.pumpAndSettle();
  expect(find.text('自动翻页'), findsNothing, reason: '设置面板应已关闭');
  // 中心点击 → 控制栏隐藏
  await tester.tapAt(center);
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
      await tester.tapAt(_centerOffset(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
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
      // [漫画设置作用域 2026-10-01] 阅读模式卡新增作用域行后自动速度区
      // 可能落到视口下沿外 → 先滚入视野再拖（断言不变）
      await tester.ensureVisible(slider);
      await tester.pumpAndSettle();
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
      await tester.tapAt(_centerOffset(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
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
        // [P4-3 M4 批2] 注入 mangaLongClickSaveImage=false：批 2 新默认
        // true 使长按直接存图（不进页操作底栏），本用例测「长按开底栏
        // 暂停自动翻页」语义，须显式关闭长按存图保持旧菜单路径
        configs: {
          'mangaScrollMode': '1',
          'mangaAutoReadSpeed': '15',
          'mangaLongClickSaveImage': 'false',
        },
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
      await tester.tapAt(Offset(_centerOffset(tester).dx, 20));
      await tester.pumpAndSettle();
      expect(find.text('保存图片'), findsNothing, reason: '底栏应已关闭');

      // 下一周期（@45s，距关栏 ≤15s）→ 自动翻到第 2 页
      await tester.pump(const Duration(seconds: 15));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.textContaining('页数2/3'), findsOneWidget,
          reason: '底栏关闭后自动翻页应从周期恢复');

      // 收尾：关自动翻页（取消周期定时器，避免测试残留活动 Timer）
      await tester.tapAt(_centerOffset(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '自动翻页'));
      await tester.pumpAndSettle();
      await _closeSheetAndControls(tester);
    });

    // [P4-3 W2-fix ⑬] 条漫自动滚动：滚完剩余距离的**当下**即调度切章
    //（滚动完成回调复检到章末 → 500ms → 切章），对齐参考版
    // MangaReaderScreen L688-699：animateScrollBy 挂起至动画结束后**立即**
    // 检查 consumed < 1f → NextChapter + delay(500L)，不等待下一个周期 tick。
    // 旧实现只在周期 tick 上检测 remaining<=0：测试世界里 tick 读到的
    // pixels 恒落后动画完成一帧（tick 在 elapse 内先于帧落定触发），
    // 滚完剩余后仍判「还有剩余」再爬一个完整周期 → 低速（速度档 1，
    // 周期 160s）章尾停留 ≈ 3P+0.5s（设备实测 QA ⑬ ≥90s 同族）；
    // 新实现切章 ≈ 2P+0.5s。
    // 时序设计：速度档 1（周期 P=160000ms）+ 两章 mock + 章尾剩余距离
    // < 10000px（一个周期即滚完剩余到章末）：
    // - 新实现：首个 tick（≈t0+P）滚剩余到章末（动画满周期，≈t0+2P 落定）
    //   → 完成回调立即调度 → t0+2P+0.5s 切章，断言 t0+2P+10s 内
    //   [1,0] 进度写入（本断言在旧实现下失败 → 红）；
    // - 收尾关自动翻页防残留活动 Timer（同 P1-1 用例）。
    testWidgets('条漫低速（周期长）：滚完剩余距离当下即调度切章（⑬）',
        (tester) async {
      final progressCalls = <List<int>>[];
      // 条漫（默认模式 4）+ 速度档 1（周期 160s）+ 两章
      final api = _AutoReadMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        configs: {'mangaAutoReadSpeed': '1'},
        chapterCount: 2,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      // [W2-fix ⑬] 测试表面设 5/3 纵屏（宽 480 × 高 800）：
      // 图片项占位高 = 0.6×屏高 = 0.6×800 = 480，恰等于 1×1 PNG 的
      // fitWidth 解码高（= 屏宽 480）→ 「占位 → 解码」内容高度不变，
      // maxScrollExtent 全程恒定（含懒布局离屏项重估），消除「解码切换
      // 漂移 extent」的测试世界假象（漂移时旧实现在飞动画被新 extent 钳制
      // 后 rem 恰好归零、意外调度切章，⑬ 会假绿）。真机图片预载完成后
      // extent 本就稳定，本设定对齐该稳态，使 ⑬ 成为真红→绿守卫。
      final origSize = tester.view.physicalSize;
      final origDpr = tester.view.devicePixelRatio;
      tester.view.physicalSize = const Size(480, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.physicalSize = origSize;
        tester.view.devicePixelRatio = origDpr;
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child:
              const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://c5')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('章节1/2'), findsOneWidget);

      await _enableAutoRead(tester);
      await _closeSheetAndControls(tester);
      // 等滚动范围稳定（占位高度 = 解码高度，extent 恒定，见用例头部
      // 测试表面 5/3 纵横比设计）
      final extent = await _settleExtentStable(tester);
      expect(extent, greaterThan(0), reason: '解码后应可滚动');
      expect(extent, lessThan(MangaAutoRead.webtoonScrollPx),
          reason: '章尾剩余距离应 < 一周期滚动量 10000px'
              '（一个周期即滚完剩余距离）');

      // 假时钟基准 t0 = 当前时刻（Clock.now() 为方法，基线 2015-01-01）；
      // P = 周期毫秒数
      final t0 = tester.binding.clock.now();
      final periodMs = MangaAutoRead.webtoonCycle(1).inMilliseconds;
      final deadline = t0.add(Duration(milliseconds: 2 * periodMs + 10_000));
      // [W2-fix ⑬] 帧驱动有界等待 + **非整除步长**（977ms，160000 %
      // 977 = 749 ≠ 0）：假时钟世界里周期 tick 在 elapse 内（帧落定前）
      // 触发，若泵步长整除周期 P（如 100ms），tick 恰与动画完成帧同泵
      // 落定（优势相位），旧实现 tick 恰好读到章末、红→绿失效；977ms
      // 非整除使 tick 恒落后动画完成帧一拍（复刻真机 tick 相位漂移、
      // QA ⑬ 低速章尾停留的同源时序）：旧实现每 tick 读 rem>0 再爬整周
      // 期、窗口内永不切章（红）；新实现 whenComplete 于完成帧当下调度
      //（≈ t0+2P+0.7s，窗口内，绿）。有帧待落时以 977ms 步泵（保证动画
      // 逐帧推进），无帧时整步 1s 快进到下个周期边界。
      var iNext = -1;
      var tSwitch = -1; // 切章（进度 [1,0]）写入的假时钟时刻（相对 t0，ms）
      var tMax = -1; // pixels 首次到章末的假时钟时刻（相对 t0，ms）
      void captureTMax() {
        if (tMax < 0) {
          final pos =
              tester.state<ScrollableState>(find.byType(Scrollable).first).position;
          if (pos.pixels >= pos.maxScrollExtent - 0.5) {
            tMax = tester.binding.clock.now().difference(t0).inMilliseconds;
          }
        }
      }
      while (tester.binding.clock.now().isBefore(deadline)) {
        while (tester.binding.hasScheduledFrame) {
          await tester.pump(const Duration(milliseconds: 977));
          captureTMax();
          if (iNext < 0) {
            iNext = progressCalls
                .indexWhere((c) => c.length == 2 && c[0] == 1 && c[1] == 0);
            if (iNext >= 0) tSwitch = tester.binding.clock.now().difference(t0).inMilliseconds;
          }
          if (iNext >= 0) break;
        }
        if (iNext >= 0) break;
        await tester.pump(const Duration(milliseconds: 1000));
        captureTMax();
        if (iNext < 0) {
          iNext = progressCalls
              .indexWhere((c) => c.length == 2 && c[0] == 1 && c[1] == 0);
          if (iNext >= 0) tSwitch = tester.binding.clock.now().difference(t0).inMilliseconds;
        }
      }
      // [W2-fix ⑬] 红→绿判别器：切章调度时机相对「pixels 首次到章末 tMax」
      // 的间隔。新实现 whenComplete 于滚动完成帧当下复检章末并调度切章
      //（500ms 延迟 + 泵步 977ms 量化，间隔 ≈ 1~2s）；旧实现完成帧仅
      // 落在周期 tick 上、须再等下一 tick 才调度（非整除相位下多等至多
      // 一整周期 P=160s，实测间隔 ≈ 48s）。5s 阈值稳判别（新 ≈ 1.5s
      // 远小于、旧 ≈ 48s 远大于），与绝对相位无关。
      expect(iNext, greaterThanOrEqualTo(0),
          reason: '滚完剩余距离后应在窗口内调度切章（切到下一章）');
      expect(tMax, greaterThan(0),
          reason: '等待窗口内 pixels 应到达章末（滚动完成）');
      expect(
        tSwitch - tMax,
        lessThan(5000),
        reason:
            '⑬ 滚完剩余距离应**当下**调度切章：切章时刻应距 pixels 首次到章末'
            '（tMax）≤ 5s（whenComplete 于完成帧当下复检 + 500ms 延迟）；'
            '旧实现须等下一周期 tick（非整除相位下实测间隔 ≈ 48s ≈ 0.3P），必失败',
      );
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '条漫自动滚动到章末应自动进入下一章');

      // 收尾：关自动翻页（取消周期定时器，避免测试残留活动 Timer）
      await tester.tapAt(_centerOffset(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '自动翻页'));
      await tester.pumpAndSettle();
      await _closeSheetAndControls(tester);
    });

    // [P4-3 W2-fix ⑫] 单页自动翻页：到末页应自动切下一章——对齐参考版
    // 单页 LaunchedEffect（MangaReaderScreen L200-216：循环
    // delay(速度×1000) → PageStep(1)）+ requestPageStep
    //（MangaReaderViewModel L1127-1143：nextPageItemIndex 返回 null =
    // 末页 → openRelativeChapter 切下一章）。QA ⑫ 设备实测「L2R 单页
    // 自动翻页 17/17 后停住不跨章」：本用例锁定「末页→切章」行为
    //（末页进度 [0,2] 先于新章进度 [1,0]），作回归守卫；
    // 末页分支链（_autoReadTick → _stepPage(1) atBoundary →
    // _nextChapter → _goToChapter）静态核对与参考版一致。
    testWidgets('单页自动翻页：到末页自动切下一章（⑫）', (tester) async {
      final progressCalls = <List<int>>[];
      // L2R 单页（模式 1）+ 速度档 1（1s/页）+ 两章（各 3 页）
      final api = _AutoReadMockApi(
        progressCalls: progressCalls,
        configWrites: <List<String>>[],
        configs: {'mangaScrollMode': '1', 'mangaAutoReadSpeed': '1'},
        chapterCount: 2,
      );
      final container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child:
              const MaterialApp(home: ReaderComicScreen(bookUrl: 'mock://c6')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('章节1/2'), findsOneWidget);
      expect(find.textContaining('页数1/3'), findsOneWidget);

      await _enableAutoRead(tester);
      await _closeSheetAndControls(tester);

      // 1s/页：1/3 → 2/3 → 3/3（末页）；下一周期 tick 在末页命中
      // atBoundary → 自动切第 2 章（进度 [1,0]）。
      // [W2-fix ⑫] 帧驱动有界等待（同 ⑬ 用例泵节奏）：300ms 翻页动画
      // 只在帧落定时推进，周期 tick（1s 步长 elapse 内）重启动画的同帧
      // elapsed=0 零进度 —— 整步 1s 泵下 pixels 永不前进（测试世界相位
      // 假象，真机 60fps 无此问题）。有帧待落时以 100ms 小步泵：
      // 3 次翻页（各 3 帧 × 100ms）+ 末页 tick 切章，t0+10s 内必然落定。
      final t0 = tester.binding.clock.now();
      final deadline = t0.add(const Duration(seconds: 10));
      var iEnd = -1;
      var iNext = -1;
      while (tester.binding.clock.now().isBefore(deadline)) {
        while (tester.binding.hasScheduledFrame) {
          await tester.pump(const Duration(milliseconds: 100));
          iNext = progressCalls
              .indexWhere((c) => c.length == 2 && c[0] == 1 && c[1] == 0);
          if (iNext >= 0) break;
        }
        if (iNext >= 0) break;
        await tester.pump(const Duration(milliseconds: 1000));
        iEnd = progressCalls
            .indexWhere((c) => c.length == 2 && c[0] == 0 && c[1] == 2);
        iNext = progressCalls
            .indexWhere((c) => c.length == 2 && c[0] == 1 && c[1] == 0);
      }
      expect(iEnd, greaterThanOrEqualTo(0),
          reason: '应先翻到末页（末页进度 [0,2] 写入）');
      expect(iNext, greaterThan(iEnd),
          reason: '末页进度 [0,2] 应先于新章进度 [1,0]'
              '（单页自动翻页到末页应自动切下一章，对齐参考版 '
              'requestPageStep null → openRelativeChapter）');
      expect(find.textContaining('章节2/2'), findsOneWidget,
          reason: '单页自动翻页到末页应自动进入下一章');

      // 收尾：关自动翻页（取消周期定时器，避免测试残留活动 Timer）
      await tester.tapAt(_centerOffset(tester));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('翻页设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SwitchListTile, '自动翻页'));
      await tester.pumpAndSettle();
      await _closeSheetAndControls(tester);
    });
}
