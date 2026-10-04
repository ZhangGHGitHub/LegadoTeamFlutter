// 注：本工具链（Flutter 3.44.8 / Dart 3.12.2，2026-09 升级后）新编译的
// Windows 前端对无扩展名包导入（package:x/x）解析失败（报「系统找不到
// 指定的文件」），显式 .dart 扩展名为当前可编译形态；存量测试文件沿用
// 无扩展名形态系旧工具链产物，未动。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

/// 目录页章节行缓存状态指示测试（用户验收 P2-28b 三态 → P2-29 五态 →
/// P2-29b 互斥分支与着色修正，对齐参考版 ReaderBookSheet.kt
/// ReaderSheetChapterStatus 单 when 链 + DownloadState 状态机 —
/// full-stack-engineer + UI）
///
/// 图标取证基准（参考版 legado-with-MD3 ReaderBookSheet.kt
/// ReaderSheetChapterStatus :1039-1096 单 when 互斥链，ReaderSheetStatusIcon
/// :1100-1111 tint=secondary；行级高亮 ReaderSheetChapterItem :965-974）：
/// - ① showCount（字数开关开 && wordCount 非空 && (LOCAL || SUCCESS)）
///   → 字数胶囊：当前章 = primaryContainer 底 + onPrimaryContainer 字；
///   普通章 = surfaceContainer 底（灰底）+ onSurfaceVariant 字；
///   8sp labelSmallEmphasized，padding 横 6 纵 2，圆角 8 —— 胶囊短路
///   全部状态图标（当前章有字数时只显示胶囊，无定位图标）
/// - ② isDur（当前章且无胶囊）→ Icons.Default.LocationOn（secondary 着色，
///   非红）→ 我方 Icons.location_on（行高适配 16px，参考版 16dp）
/// - ③ DOWNLOADING → AppContainedLoadingIndicator 16dp 转圈 → 我方
///   SizedBox 16 + CircularProgressIndicator（strokeWidth 2，primary 着色），
///   数据经 BookApi.listDownloadingChapters（契约 §2.43.7，1s 轮询同周期刷新）
/// - ④ SUCCESS（已缓存且无胶囊，如字数开关关）→ Icons.Default.CheckCircle
///   （secondary 着色）→ 我方 Icons.check_circle（16px）
/// - ⑤ ERROR → 红色重试图标（Icons.refresh，error 着色）可点击 → 单章重下
///   cacheDownloadStart(bookUrl, idx, idx)；数据经 BookApi.listFailedChapters
///   （契约 §2.43.8，P2-29c 后续批接通，与下载中同周期 1s 轮询；注入缝
///   failedChapterIndicesForTest 已移除），本文件经 stub 真实数据源驱动
/// - ⑥ NONE（未缓存网络章）→ Icons.Outlined.DownloadForOffline
///   （outline 50% 着色）→ 我方 Icons.download_for_offline_outlined
/// - ⑦ LOCAL（本地书无字数且非当前章）→ when 链无分支命中，渲染空
///   （本地书不显示对勾图标）
/// 行级高亮（参考版 ReaderSheetChapterItem :965-974）：当前章（isDur）
/// 行背景 secondaryContainer + 标题 onSecondaryContainer（M3 ListTile 经
/// tileColor 铺底、textColor 注色）；普通行 onSurface。
/// 字数胶囊：Rust 回填链（对齐原版 BookHelp.writeText → upWordCount，
/// StringUtils.wordCountFormat 存「1200字」/「1.1万字」形态），展示端
/// 原样输出（对齐原版 ChapterListAdapter.kt:231），不再追加「 字」后缀。
/// [P2-28b] 追加：页面打开期间每秒轮询 listCachedChapterUrls（零契约面
/// 替代原版 ChapterListFragment 订阅 EventBus.SAVE_CONTENT 的行刷新），
/// 批量离线缓存下载中对应行 ⬇ 图标实时变为字数胶囊/对勾图标；dispose
/// 取消定时器。注意：在线书 TocScreen 持有 1s 周期轮询定时器，本文件各
/// 用例均用显式 tester.pump 推进（pumpAndSettle 永不停机），并在用例末尾
/// 卸载（dispose 取消定时器，teardown 的「periodic Timer still active」
/// 检查同时充当「dispose 后不再轮询」的证明）。
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(home: child),
      );

  /// 查找包含指定章节标题的章节行（ListTile）。
  /// 状态图标/字数胶囊位于行 trailing 区（与标题 Text 平级，对齐原版
  /// item_chapter_list.xml 布局），故以行为锚点而非 Text 后代。
  Finder chapterRow(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(ListTile));

  /// [P2-29b] 行内字数胶囊 Container（字数 Text 的最近 Container 祖先；
  /// M3 ListTile 内部无 Container 且胶囊 Container 直挂 Text，上溯首个
  /// 命中即胶囊本体）。
  Container capsuleOf(WidgetTester tester, String rowTitle, String wordCount) {
    final Element el = tester.element(
      find.descendant(of: chapterRow(rowTitle), matching: find.text(wordCount)),
    );
    Container? capsule;
    // 本工具链（Flutter 3.44.8）Element 无公开 parent getter，改用
    // visitAncestorElements 上溯（命中即停）
    el.visitAncestorElements((Element ancestor) {
      if (ancestor.widget is Container) {
        capsule = ancestor.widget as Container;
        return false;
      }
      return true;
    });
    return capsule!;
  }

  /// [P2-29b] 行标题 Text 的包裹 DefaultTextStyle（M3 ListTile 以
  /// AnimatedDefaultTextStyle 包标题，并把行 textColor 写入 style.color；
  /// 上溯取首个 DefaultTextStyle 祖先（含子类 AnimatedDefaultTextStyle））。
  DefaultTextStyle titleStyleOf(WidgetTester tester, String rowTitle) {
    final Element el = tester.element(
      find.descendant(of: chapterRow(rowTitle), matching: find.text(rowTitle)),
    );
    DefaultTextStyle? style;
    el.visitAncestorElements((Element ancestor) {
      if (ancestor.widget is DefaultTextStyle) {
        style = ancestor.widget as DefaultTextStyle;
        return false;
      }
      return true;
    });
    return style!;
  }

  /// [P2-29b] 行背景（M3 ListTile 以 Ink.decoration 承载 tileColor）。
  Color? tileColorOf(WidgetTester tester, String rowTitle) {
    final ink = tester.widget<Ink>(
      find.descendant(of: chapterRow(rowTitle), matching: find.byType(Ink)),
    );
    final deco = ink.decoration;
    return deco is ShapeDecoration ? deco.color : null;
  }

  const String bookUrl = 'https://src.com/book/1';

  Book makeBook({String origin = 'https://src.com', int dur = 3}) => Book(
        bookUrl: bookUrl,
        name: '测试书',
        author: '作者A',
        totalChapterNum: 4,
        origin: origin,
        durChapterIndex: dur,
        durChapterTitle: '第四章',
      );

  List<BookChapter> makeChapters() => [
        const BookChapter(
          url: 'u0',
          title: '第一章',
          index: 0,
          bookUrl: bookUrl,
          wordCount: '1200',
        ),
        const BookChapter(
          url: 'v0',
          title: '第一卷',
          index: 1,
          bookUrl: bookUrl,
          isVolume: true,
        ),
        const BookChapter(
          url: 'u2',
          title: '第三章',
          index: 2,
          bookUrl: bookUrl,
        ),
        const BookChapter(
          url: 'u3',
          title: '第四章',
          index: 3,
          bookUrl: bookUrl,
          wordCount: '3400',
        ),
      ];

  /// 公共 stub：书架态/章节/缓存集合/下载中集合/标注/书签
  void stubCommon(
    List<BookChapter> chapters,
    List<String> cachedUrls, {
    List<int> downloading = const [],
    List<int> failed = const [],
  }) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
    when(() => mockApi.getChapters(bookUrl)).thenAnswer(
      (_) async => chapters,
    );
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer(
      (_) async => cachedUrls,
    );
    // [P2-29] 下载中集合（契约 §2.43.7）：初始加载与 1s 轮询均经此 stub
    when(() => mockApi.listDownloadingChapters(bookUrl)).thenAnswer(
      (_) async => downloading,
    );
    // [P2-29c 后续] 失败章集合（契约 §2.43.8）：初始加载与 1s 轮询均经此
    // stub（真实数据源，ERROR 态不再依赖 UI 注入缝）
    when(() => mockApi.listFailedChapters(bookUrl)).thenAnswer(
      (_) async => failed,
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);
  }

  /// 初始渲染：build 帧 + 冲刷三次异步加载微任务（P2-29 初始加载链
  /// getBook→getChapters→listCachedChapterUrls→listDownloadingChapters，
  /// 不推进 1s 轮询定时器）
  Future<void> settleInitial(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('未缓存网络章显示离线下载图标⬇，已缓存章与卷标题行无状态图标',
      (tester) async {
    // 缓存集合命中 u0（第一章）与 u3（当前章），u2 未缓存；卷 v0 不在集合
    stubCommon(makeChapters(), const ['u0', 'u3']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);

    expect(find.text('第一章'), findsOneWidget);
    expect(find.text('第三章'), findsOneWidget);
    // 仅未缓存的「第三章」显示离线下载图标（参考版 StatusIcon NONE 态）
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    // 已缓存的「第一章」无状态图标，字数胶囊原样展示（P2-28b：不再追加
    // 「 字」；[P2-29b] 普通章胶囊为 surfaceContainer 灰底，分色见互斥用例）
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200')),
      findsOneWidget,
    );
    // [P2-29b] 当前章「第四章」（有字数且已缓存）：字数胶囊短路定位图标——
    // 只显示「3400」胶囊，无 location_on（修前两者并存，本断言修前红）
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsNothing,
    );
    // 卷标题行（Container，非章节行 ListTile）无状态图标（原版 ivChecked.gone）
    final volumeRow = find.ancestor(
      of: find.text('第一卷'),
      matching: find.byType(Container),
    );
    expect(
      find.descendant(
          of: volumeRow,
          matching: find.byIcon(Icons.download_for_offline_outlined)),
      findsNothing,
    );
    expect(
      find.descendant(
          of: volumeRow,
          matching: find.byIcon(Icons.location_on)),
      findsNothing,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('当前章无字数胶囊（未缓存不显字数）显示定位图标替代⬇（对齐参考版 isDur 分支）',
      (tester) async {
    // 缓存集合仅 u0：u2 未缓存、u3（当前章）也未缓存 → 当前章不满足
    // showCount（需本地 || 已缓存）→ 无字数胶囊 → 走 isDur 分支显示定位图标
    stubCommon(makeChapters(), const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    // [P2-29b] 当前章「第四章」无胶囊（未缓存）：定位图标（DUR 分支，
    // 参考版 :1063，short-circuit 于 ①胶囊之后；替代 P2-28b 的对勾圈）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    // 当前章未缓存也不显示离线下载图标（参考版 isDur 分支优先于 NONE 分支）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 非当前的未缓存章「第三章」仍显示离线下载图标
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('字数胶囊：开关默认开且 wordCount 非空原样展示，空则隐藏',
      (tester) async {
    // [P2-29b] 胶囊条件对齐参考版 showCount（:1039-1041）：开关开 &&
    // wordCount 非空 && (本地 || 已缓存)——两章均需已缓存才显示胶囊
    stubCommon(makeChapters(), const ['u0', 'u3']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    // 有 wordCount 且已缓存的两章显示字数胶囊，原样展示（对齐原版
    // tv_word_count / 参考版 NormalCard 原样输出；Rust 回填值自带
    // 「字/万字」后缀）
    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400')),
      findsOneWidget,
    );
    // 无 wordCount 的「第三章」无字数标签
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.textContaining('字'),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('「加载字数」开关关闭：隐藏字数胶囊，已缓存章显示对勾图标（参考版 SUCCESS 态）',
      (tester) async {
    // 开关持久化为 false（默认 true）：wordCount 非空也不显示胶囊；
    // [P2-29b] 已缓存且无胶囊的章走参考版 SUCCESS 分支 → 对勾图标
    // （CheckCircle，secondary 色，:1069-1071）
    SharedPreferences.setMockInitialValues({'toc_load_word_count': false});
    stubCommon(makeChapters(), const ['u0', 'u3']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200')),
      findsNothing,
    );
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400')),
      findsNothing,
    );
    // 已缓存的「第一章」：对勾图标（SUCCESS 态替代 P2-29 的「已缓存无图标」）
    final checkIcon = find.descendant(
      of: chapterRow('第一章'),
      matching: find.byIcon(Icons.check_circle),
    );
    expect(checkIcon, findsOneWidget);
    // 对勾着色 secondary（对齐参考版 ReaderSheetStatusIcon tint，:1100-1111）
    expect(
      tester.widget<Icon>(checkIcon).color,
      Theme.of(tester.element(chapterRow('第一章'))).colorScheme.secondary,
    );
    // 当前章「第四章」（开关关 → 无胶囊）：定位图标（isDur 分支，
    // 优先于 NONE/未缓存判定——u3 本未缓存，不显示 ⬇）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本地书不显示⬇图标且不请求缓存列表（对齐原版 isLocalBook 恒 cached）',
      (tester) async {
    // [P2-29b] 第一章带 wordCount：本地书恒视为已缓存（LOCAL 计入 showCount
    // 的 LOCAL || SUCCESS 条件），有字数即显示胶囊
    final localChapters = [
      const BookChapter(
          url: 'u0',
          title: '第一章',
          index: 0,
          bookUrl: bookUrl,
          wordCount: '1200'),
      const BookChapter(
          url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
      const BookChapter(
          url: 'u2', title: '第三章', index: 2, bookUrl: bookUrl),
    ];
    when(() => mockApi.getBook(any()))
        .thenAnswer((_) async => makeBook(origin: BookType.localTag, dur: 1));
    when(() => mockApi.getChapters(bookUrl)).thenAnswer(
      (_) async => localChapters,
    );
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer(
      (_) async => const ['u0'],
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);

    await tester.pumpWidget(
      wrap(TocScreen(book: makeBook(origin: BookType.localTag, dur: 1))),
    );
    await settleInitial(tester);

    // 本地书无离线下载图标（原版：isLocalBook → cached=true → 图标隐藏）
    expect(find.byIcon(Icons.download_for_offline_outlined), findsNothing);
    // 本地书不请求缓存列表（数据无意义，避免无谓 FFI 调用；亦免轮询定时器）
    verifyNever(() => mockApi.listCachedChapterUrls(any()));
    // [P2-29] 本地书当前章（第二章，无字数）显示定位图标（LOCAL 恒缓存
    // 语义下 isDur 分支，被 ①胶囊短路后的第二分支）
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    // [P2-29b] 本地书有字数的章节显示字数胶囊（LOCAL 计入 showCount 的
    // LOCAL || SUCCESS 条件，参考版 :1041）
    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200')),
      findsOneWidget,
    );
    // [P2-29b] 本地书不显示对勾图标（LOCAL 不等同网络书 SUCCESS 态：
    // 参考版 when 链对 LOCAL 且无字数且非当前的章节无分支命中，渲染空）
    expect(find.byIcon(Icons.check_circle), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('[P2-28c] 轮询：新缓存章⬇消失且字数胶囊同帧出现，dispose 后停止轮询',
      (tester) async {
    // 章节数据中 u3（第四章）**无 wordCount**（chapters 表未回填）：
    // 字数胶囊只能来自轮询字数映射（P2-28c 数据链），而非章节数据——
    // 修前实现（仅 diff URL 集合）⬇ 会翻转但胶囊缺席（红）
    final chapters = [
      const BookChapter(
        url: 'u0',
        title: '第一章',
        index: 0,
        bookUrl: bookUrl,
        wordCount: '1200',
      ),
      const BookChapter(
        url: 'v0',
        title: '第一卷',
        index: 1,
        bookUrl: bookUrl,
        isVolume: true,
      ),
      const BookChapter(
        url: 'u2',
        title: '第三章',
        index: 2,
        bookUrl: bookUrl,
      ),
      const BookChapter(
        url: 'u3',
        title: '第四章',
        index: 3,
        bookUrl: bookUrl,
      ),
    ];

    // 首次查询仅 u0 已缓存（u3 未缓存 → 行内 ⬇ 图标）；
    // 轮询起 u3 新缓存（模拟批量离线缓存逐章落库）
    var urlsPollCount = 0;
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
    when(() => mockApi.getChapters(bookUrl))
        .thenAnswer((_) async => chapters);
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer((_) async {
      urlsPollCount++;
      return urlsPollCount == 1
          ? const <String>['u0']
          : const <String>['u0', 'u3'];
    });
    // 字数刷新数据链（契约 §2.43.6）：已缓存章 url → wordCount 映射
    var wcPollCount = 0;
    when(() => mockApi.listCachedChapters(bookUrl)).thenAnswer((_) async {
      wcPollCount++;
      return const <String, String>{'u0': '1200', 'u3': '3400'};
    });
    // [P2-29] 下载中集合数据链（契约 §2.43.7）：轮询同周期拉取，恒空
    // （本用例不驱动 DOWNLOADING 态，仅需 stub 以免 mocktail 抛 TypeError
    // 被轮询 catch 吞掉后掩盖真实断言）
    var dlPollCount = 0;
    when(() => mockApi.listDownloadingChapters(bookUrl)).thenAnswer(
      (_) async {
        dlPollCount++;
        return const <int>[];
      },
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);

    // 当前章设为第一章（u0 已缓存）：第四章/第三章均未缓存 → 两行 ⬇
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 0))));
    await settleInitial(tester);

    // 初始：未缓存的「第四章」显示 ⬇；章节数据无 wordCount → 无胶囊
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );

    // 1s 轮询触发：u3 新缓存 → 同一帧「第四章」⬇ 消失且字数胶囊
    // 「3400」出现（对齐参考版 SAVE_CONTENT 同帧刷行语义）；
    // 「第三章」仍未缓存，⬇ 保留
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );

    // dispose（卸载）后不再轮询：三个查询入口调用计数均冻结；
    // 若 dispose 漏取消定时器，teardown 的「periodic Timer still active」
    // 检查将直接使本用例失败
    final urlsBeforeDispose = urlsPollCount;
    final wcBeforeDispose = wcPollCount;
    final dlBeforeDispose = dlPollCount;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(
      urlsPollCount,
      urlsBeforeDispose,
      reason: 'dispose 后不应再有 listCachedChapterUrls 查询',
    );
    expect(
      wcPollCount,
      wcBeforeDispose,
      reason: 'dispose 后不应再有 listCachedChapters 查询',
    );
    expect(
      dlPollCount,
      dlBeforeDispose,
      reason: 'dispose 后不应再有 listDownloadingChapters 查询（P2-29）',
    );
  });

  // ===== [P2-29] 目录章节行五态（对齐参考版 DownloadState 状态机） =====

  testWidgets(
      '[P2-29] 下载中章渲染 16px 加载指示（替代 ⬇，对齐参考版 LOADING 态；'
      '当前章定位图标 / 已缓存章无图标）',
      (tester) async {
    // 缓存 u0（第一章）；在途下载集合 [2]（第三章）；
    // 第三章未缓存但下载中 → 应显示 16px 转圈而非 ⬇
    stubCommon(makeChapters(), const ['u0'], downloading: const [2]);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    // 下载中的「第三章」：行内 16px 加载指示（CircularProgressIndicator），
    // 且不再显示离线下载 ⬇（LOADING 态优先于 NONE 态）
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 转圈直径 16px（对齐参考版 AppContainedLoadingIndicator 16dp 形态）
    expect(
      tester.getSize(find.descendant(
        of: chapterRow('第三章'),
        matching: find.byType(CircularProgressIndicator),
      )),
      const Size.square(16),
    );
    // 当前章「第四章」：定位图标（DUR 态，P2-29 新形态）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    // 已缓存的「第一章」：[P2-29b] 显示字数胶囊（非状态图标，互斥分支 ①），
    // ⬇ 与转圈均不显示
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200')),
      findsOneWidget,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('[P2-29] 失败章红色重试图标，点击触发单章重下（start==end 单章语义）',
      (tester) async {
    // 缓存 u0；失败集合经 listFailedChapters（契约 §2.43.8）真实数据源返回：
    // 第三章（index 2）失败（[P2-29c 后续] 注入缝已移除）。本用例验证 UI 分支：
    // 红色重试图标 + 点击 → cacheDownloadStart(idx, idx)
    stubCommon(makeChapters(), const ['u0'], failed: const [2]);
    when(() => mockApi.cacheDownloadStart(bookUrl, 2, 2))
        .thenAnswer((_) async => 7);

    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    // 失败章「第三章」：红色重试图标（替代 ⬇；ERROR 态优先于 NONE 态）
    final retryIcon = find.descendant(
      of: chapterRow('第三章'),
      matching: find.byIcon(Icons.refresh),
    );
    expect(retryIcon, findsOneWidget);
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 图标着色为 error（对齐参考版 ERROR 态 error 着色）
    final iconWidget = tester.widget<Icon>(retryIcon);
    expect(
      iconWidget.color,
      Theme.of(tester.element(chapterRow('第三章'))).colorScheme.error,
    );

    // 点击 → 单章重下（契约 §2.43.3 闭区间 start==end）+ SnackBar 反馈
    await tester.tap(retryIcon);
    await tester.pump();
    await tester.pump();
    verify(() => mockApi.cacheDownloadStart(bookUrl, 2, 2)).called(1);
    expect(
      find.textContaining('已加入重新下载队列'),
      findsOneWidget,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('[P2-29c 后续] 失败集合经 1s 轮询真实出现/清除（契约 §2.43.8）',
      (tester) async {
    // 数据链闭环：初始无失败 → 轮询拉取到 [2] → 红色重试图标出现；
    // 重试后（任务取章清除失败标记）下一轮轮询集合空 → 图标消失
    var hasFailure = false;
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
    when(() => mockApi.getChapters(bookUrl))
        .thenAnswer((_) async => makeChapters());
    when(() => mockApi.listCachedChapterUrls(bookUrl))
        .thenAnswer((_) async => const ['u0']);
    when(() => mockApi.listCachedChapters(bookUrl))
        .thenAnswer((_) async => const <String, String>{'u0': '1200'});
    when(() => mockApi.listDownloadingChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.listFailedChapters(bookUrl)).thenAnswer(
      (_) async => hasFailure ? const [2] : const <int>[],
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);

    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);
    // 初始无失败：第三章为 NONE 态 ⬇，无红色重试图标
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.refresh),
      ),
      findsNothing,
    );

    // 失败集合出现 → 1s 轮询翻转 ERROR 态（红色重试图标）
    hasFailure = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.refresh),
      ),
      findsOneWidget,
    );

    // 重试清除（Rust 取章清失败标记）→ 下一轮轮询回到 ⬇（NONE 态）
    hasFailure = false;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.refresh),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  // ===== [P2-29b] 互斥分支与着色修正断言 =====

  testWidgets(
      '[P2-29b] 当前章+有字数（已缓存）：只显示胶囊无状态图标（互斥）+ isDur 分色',
      (tester) async {
    // u0/u3 均缓存且带 wordCount，当前章为「第四章」(u3)：胶囊短路全部
    // 状态图标——定位/对勾/转圈/⬇/重试均须缺席（修前胶囊与定位图标
    // 并存，本断言修前红）
    stubCommon(makeChapters(), const ['u0', 'u3']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    final cs = Theme.of(tester.element(chapterRow('第四章'))).colorScheme;

    // ① 胶囊独占断言：「第四章」仅有「3400」胶囊，五种状态元素皆无
    expect(
      find.descendant(of: chapterRow('第四章'), matching: find.text('3400')),
      findsOneWidget,
    );
    for (final finder in [
      find.byIcon(Icons.location_on),
      find.byIcon(Icons.check_circle),
      find.byType(CircularProgressIndicator),
      find.byIcon(Icons.download_for_offline_outlined),
      find.byIcon(Icons.refresh),
    ]) {
      expect(
        find.descendant(of: chapterRow('第四章'), matching: finder),
        findsNothing,
      );
    }

    // ② isDur 分色（参考版 :1045-1059）：当前章胶囊 primaryContainer 底 +
    // onPrimaryContainer 字，8sp（参考版 labelSmallEmphasized.copy(8sp)）
    final currentCapsule = capsuleOf(tester, '第四章', '3400');
    final currentDeco = currentCapsule.decoration;
    expect(currentDeco, isA<BoxDecoration>());
    expect((currentDeco as BoxDecoration).color, cs.primaryContainer);
    final currentText = tester.widget<Text>(find.descendant(
      of: chapterRow('第四章'),
      matching: find.text('3400'),
    ));
    expect(currentText.style?.color, cs.onPrimaryContainer);
    expect(currentText.style?.fontSize, 8);

    // ③ 普通章胶囊（「第一章」，非当前）：surfaceContainer 灰底 +
    // onSurfaceVariant 字（参考版 :1048/:1058 非 isDur 分支）
    final normalCapsule = capsuleOf(tester, '第一章', '1200');
    final normalDeco = normalCapsule.decoration;
    expect(normalDeco, isA<BoxDecoration>());
    expect((normalDeco as BoxDecoration).color, cs.surfaceContainer);
    final normalText = tester.widget<Text>(find.descendant(
      of: chapterRow('第一章'),
      matching: find.text('1200'),
    ));
    expect(normalText.style?.color, cs.onSurfaceVariant);

    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('[P2-29b] 当前章无字数：定位图标 secondary 色（非红）',
      (tester) async {
    // 「第三章」(u2) 为当前章且无 wordCount、未缓存 → 无胶囊 → isDur 分支
    // 定位图标；[P2-29b] 将 P2-29 的红色定位改为 secondary（参考版
    // ReaderSheetStatusIcon :1100-1111 tint=colorScheme.secondary）
    stubCommon(makeChapters(), const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 2))));
    await settleInitial(tester);

    final locationIcon = find.descendant(
      of: chapterRow('第三章'),
      matching: find.byIcon(Icons.location_on),
    );
    expect(locationIcon, findsOneWidget);
    // 着色 secondary（非红/error 色）
    final cs = Theme.of(tester.element(chapterRow('第三章'))).colorScheme;
    expect(tester.widget<Icon>(locationIcon).color, cs.secondary);
    // 当前章走 isDur 分支优先于 NONE 分支 → 不显示 ⬇
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      '[P2-29b] 当前章行级高亮：secondaryContainer 底 + onSecondaryContainer '
      '标题（参考版 ReaderSheetChapterItem :965-974）',
      (tester) async {
    stubCommon(makeChapters(), const ['u0', 'u3']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    final cs = Theme.of(tester.element(chapterRow('第四章'))).colorScheme;

    // 当前章行背景：secondaryContainer（M3 ListTile 经 Ink.decoration 承载
    // tileColor）
    expect(tileColorOf(tester, '第四章'), cs.secondaryContainer);
    // 当前章标题色：onSecondaryContainer（M3 ListTile 以 effectiveColor
    // 覆写标题样式色，经 textColor 参数注入）
    expect(
      titleStyleOf(tester, '第四章').style.color,
      cs.onSecondaryContainer,
    );
    // 普通行标题色：onSurface 不变（tileColor 为 null 回退主题默认）
    expect(titleStyleOf(tester, '第一章').style.color, cs.onSurface);
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('[P2-29b] 未缓存章带 wordCount 不显示胶囊（showCount 需 本地||已缓存）',
      (tester) async {
    // u2 带 wordCount「2500」但未缓存 → 不满足 showCount 的
    // (本地 || 已缓存) 条件 → 无胶囊，落 ⑥ NONE 分支显 ⬇；
    // 已缓存 u0（当前章）胶囊正常
    final chapters = [
      const BookChapter(
        url: 'u0',
        title: '第一章',
        index: 0,
        bookUrl: bookUrl,
        wordCount: '1200',
      ),
      const BookChapter(
        url: 'u2',
        title: '第三章',
        index: 2,
        bookUrl: bookUrl,
        wordCount: '2500',
      ),
    ];
    stubCommon(chapters, const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 0))));
    await settleInitial(tester);

    expect(
      find.descendant(of: chapterRow('第三章'), matching: find.text('2500')),
      findsNothing,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    // 已缓存「第一章」（当前章）：胶囊正常显示
    expect(
      find.descendant(of: chapterRow('第一章'), matching: find.text('1200')),
      findsOneWidget,
    );
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  // ===== [P2-29c] 目录缓存交互补齐（增量需求登记落地） =====

  testWidgets(
      '[P2-29c] 未缓存章 ⬇ 可点：单章下载 cacheDownloadStart(idx, idx) + '
      '反馈，且不冒泡触发行跳转（参考版 canDownload = NONE || ERROR）',
      (tester) async {
    // 参考版依据：TocScreen.kt ChapterItem :879-881 canDownload 含 NONE；
    // :958-965 状态图标 Box 挂 onDownloadClick；:808 onDownloadClick →
    // TocIntent.DownloadChapter → TocViewModel.kt downloadChapter :863-869
    // 按章索引单章下载。我方复用既有 cacheDownloadStart（契约 §2.43.3
    // 闭区间 start==end 单章），与 ERROR 重试同路径（零契约）。
    stubCommon(makeChapters(), const ['u0']);
    when(() => mockApi.cacheDownloadStart(bookUrl, 2, 2))
        .thenAnswer((_) async => 7);

    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    final downloadIcon = find.descendant(
      of: chapterRow('第三章'),
      matching: find.byIcon(Icons.download_for_offline_outlined),
    );
    expect(downloadIcon, findsOneWidget);
    // 修前：⬇ 为纯 Icon 无手势（不可点）；修后为 IconButton，且
    // shrinkWrap 保持 16px 图标几何不变（P2-28/29 行高适配口径）
    final tappable = find.descendant(
      of: chapterRow('第三章'),
      matching: find.byType(IconButton),
    );
    expect(tappable, findsOneWidget);
    expect(tester.getSize(tappable), const Size.square(16));

    // 点击图标 → 单章下载（不得冒泡到 ListTile onTap 触发章节跳转）
    await tester.tap(downloadIcon);
    await tester.pump();
    await tester.pump();
    verify(() => mockApi.cacheDownloadStart(bookUrl, 2, 2)).called(1);
    expect(find.byType(TocScreen), findsOneWidget, reason: '点击不得触发行跳转');
    expect(find.textContaining('已加入缓存队列'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      '[P2-29c] 点击 ⬇ 后 1s 轮询进入下载中动画，完成后徽标翻转为对勾',
      (tester) async {
    // 全链闭环：点击 → cacheDownloadStart → 轮询拾取在途章 [2] → 16px
    // 加载指示（参考版 LOADING 态）→ 完成后章节落入缓存集合 → 对勾
    // （参考版 SUCCESS 态 :1069-1071）
    var tapped = false;
    var done = false;
    when(() => mockApi.getBook(any())).thenAnswer((_) async => makeBook());
    when(() => mockApi.getChapters(bookUrl))
        .thenAnswer((_) async => makeChapters());
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer(
      (_) async => done ? const ['u0', 'u2'] : const ['u0'],
    );
    when(() => mockApi.listDownloadingChapters(bookUrl)).thenAnswer(
      (_) async => tapped && !done ? const [2] : const <int>[],
    );
    // [P2-29c 后续] 失败章集合（契约 §2.43.8）恒空 stub：轮询链新增查询，
    // 缺省会被轮询外层 catch 吞掉而截断后续刷新
    when(() => mockApi.listFailedChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    when(() => mockApi.listCachedChapters(bookUrl)).thenAnswer(
      // 轮询 URL 集合取本接口 keys（契约 §2.43.6；wordCount 未回填为空串，
      // Rust 侧空值仍收录 key）——done 后 u2 落缓存 → ⬇ 翻转对勾
      (_) async => done
          ? const <String, String>{'u0': '1200', 'u2': ''}
          : const <String, String>{'u0': '1200'},
    );
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('测试书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);
    when(() => mockApi.cacheDownloadStart(bookUrl, 2, 2))
        .thenAnswer((_) async => 7);

    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    tapped = true;
    await tester.tap(find.descendant(
      of: chapterRow('第三章'),
      matching: find.byType(IconButton),
    ));
    await tester.pump();
    await tester.pump();

    // 轮询拾取在途集合 → 16px 加载指示替代 ⬇（LOADING 态）
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );

    // 下载完成：下一轮轮询翻转为对勾（SUCCESS 态）
    done = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      '[P2-29c] ERROR 优先于已缓存：失败章不显示对勾/字数胶囊（对齐参考版 '
      'running > error > cached；字数仅 LOCAL/SUCCESS）',
      (tester) async {
    // 参考版依据：TocViewModel.kt rawDataFlow :510-514 状态判定顺序
    // running → error → cached → none；StatusIcon :1146-1157 字数胶囊
    // 仅 LOCAL/SUCCESS 态命中。本用例经 listFailedChapters（契约 §2.43.8）
    // 真实数据源返回「同时已缓存且在失败集合」的章节（[P2-29c 后续] 注入缝
    // 已移除）：修前 isCached 分支先行 → 显示对勾/胶囊（红），修后 ERROR
    // 分支先行 → 红色重试图标。
    final chapters = [
      const BookChapter(
          url: 'u0',
          title: '第一章',
          index: 0,
          bookUrl: bookUrl,
          wordCount: '1200'),
      const BookChapter(
          url: 'u2',
          title: '第三章',
          index: 2,
          bookUrl: bookUrl,
          wordCount: '2500'),
      const BookChapter(
          url: 'u3', title: '第四章', index: 3, bookUrl: bookUrl),
    ];
    stubCommon(chapters, const ['u0', 'u2'], failed: const [2]);

    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.refresh),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: chapterRow('第三章'), matching: find.text('2500')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
