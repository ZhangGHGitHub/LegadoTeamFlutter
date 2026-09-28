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

/// 目录页章节行缓存状态指示测试（用户验收 P2-28b 三态 → P2-29 五态，
/// 对齐参考版 TocScreen.StatusIcon + DownloadState 状态机 —
/// full-stack-engineer + UI）
///
/// 图标取证基准（参考版 legado-with-MD3 TocScreen.kt StatusIcon 1148-1241）：
/// - 未缓存（NONE）→ Icons.Outlined.DownloadForOffline（outline 50% 着色）
///   → 我方 Icons.download_for_offline_outlined
/// - [P2-29] 当前章（DUR）→ Icons.Default.LocationOn（secondary 着色）
///   → 我方 Icons.location_on（行高适配 16px，参考版 24dp；替代 P2-28b
///   的 check_circle）
/// - [P2-29] 下载中（DOWNLOADING）→ AppContainedLoadingIndicator 16dp
///   转圈 → 我方 SizedBox 16 + CircularProgressIndicator（strokeWidth 2，
///   primary 着色），数据经 BookApi.listDownloadingChapters（契约 §2.43.7，
///   1s 轮询同周期刷新）
/// - [P2-29] 失败（ERROR）→ 红色重试图标（Icons.refresh，error 着色）
///   可点击 → 单章重下 cacheDownloadStart(bookUrl, idx, idx)；数据链留项：
///   Rust 任务表仅 failed 计数、无逐章失败记录 → 生产恒空恒不显示（不伪造），
///   本文件经 TocScreen.failedChapterIndicesForTest 注入缝驱动该分支
/// 字数胶囊：Rust 回填链（对齐原版 BookHelp.writeText → upWordCount，
/// StringUtils.wordCountFormat 存「1200字」/「1.1万字」形态），展示端
/// 原样输出（对齐原版 ChapterListAdapter.kt:231 / 参考版 TocScreen.kt:1205），
/// 不再追加「 字」后缀。
/// [P2-28b] 追加：页面打开期间每秒轮询 listCachedChapterUrls（零契约面
/// 替代原版 ChapterListFragment 订阅 EventBus.SAVE_CONTENT 的行刷新），
/// 批量离线缓存下载中对应行 ⬇ 图标实时变为字数胶囊/无图标；dispose 取消
/// 定时器。注意：在线书 TocScreen 持有 1s 周期轮询定时器，本文件各用例
/// 均用显式 tester.pump 推进（pumpAndSettle 永不停机），并在用例末尾
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

  testWidgets('未缓存网络章显示离线下载图标⬇，已缓存章与卷标题行无图标',
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
    // 已缓存的「第一章」无图标，且字数胶囊原样展示（P2-28b：不再追加「 字」）
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
    // [P2-29] 当前章「第四章」显示定位图标（参考版 DUR 态，替代 check_circle）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
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

  testWidgets('当前阅读章恒显示定位图标（未缓存时以定位替代⬇，对齐原版 isCurrent 分支）',
      (tester) async {
    // 缓存集合仅 u0：u2 未缓存、u3（当前章）也未缓存
    stubCommon(makeChapters(), const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    // [P2-29] 当前章「第四章」：定位图标（DUR 态，替代对勾圈）
    expect(
      find.descendant(
        of: chapterRow('第四章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    // 当前章未缓存也不显示离线下载图标（原版：isCurrent 时状态图标置定位）
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
    stubCommon(makeChapters(), const ['u0']);
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 3))));
    await settleInitial(tester);

    // 有 wordCount 的两章显示字数胶囊，原样展示（对齐原版 tv_word_count /
    // 参考版 NormalCard 原样输出；Rust 回填值自带「字/万字」后缀）
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

  testWidgets('「加载字数」开关关闭时隐藏字数胶囊（对齐原版 tocCountWords 门控）',
      (tester) async {
    // 开关持久化为 false（默认 true）：wordCount 非空也不显示胶囊
    SharedPreferences.setMockInitialValues({'toc_load_word_count': false});
    stubCommon(makeChapters(), const ['u0']);
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
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本地书不显示⬇图标且不请求缓存列表（对齐原版 isLocalBook 恒 cached）',
      (tester) async {
    final localChapters = [
      const BookChapter(
          url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
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
    // [P2-29] 本地书当前章（第二章）仍显示定位图标（LOCAL 恒缓存语义下
    // isCurrent 分支 → 定位图标，替代 check_circle）
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
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
    // 已缓存的「第一章」：无状态图标（已缓存态）
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
    // 卸载：dispose 取消轮询定时器（在线书）
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('[P2-29] 失败章红色重试图标，点击触发单章重下（start==end 单章语义）',
      (tester) async {
    // 缓存 u0；ERROR 态经注入缝（failedChapterIndicesForTest）驱动：
    // 第三章（index 2）失败。生产无失败记录数据源（恒空恒不显示，不伪造），
    // 本用例仅验证 UI 分支：红色重试图标 + 点击 → cacheDownloadStart(idx, idx)
    stubCommon(makeChapters(), const ['u0']);
    when(() => mockApi.cacheDownloadStart(bookUrl, 2, 2))
        .thenAnswer((_) async => 7);

    await tester.pumpWidget(
      wrap(
        TocScreen(
          book: makeBook(dur: 3),
          failedChapterIndicesForTest: const {2},
        ),
      ),
    );
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
}
