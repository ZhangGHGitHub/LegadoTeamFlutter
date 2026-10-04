// 注：本工具链（Flutter 3.44.8 / Dart 3.12.2）对无扩展名包导入解析失败，
// 显式 .dart 扩展名为当前可编译形态（同 toc_chapter_cache_state_test.dart）。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/toc_screen.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../mocks/mocks.dart';

/// 听书目录页音频缓存徽标测试（[B1-TOC] 2026-10-04）
///
/// 原版依据：
/// - `ChapterListFragment.kt:154-184`：仅 `if (book.isAudio)` 经
///   `AudioCacheManager.listCachedChapterKeys(treeUri, bookUrl)` 取已缓存
///   章节键集合（非音频书走 `BookHelp.getChapterFiles` 文本缓存文件链）；
///   建页即拉取 + `notifyItemRangeChanged` 全量刷行。
/// - `ChapterListAdapter.kt:192-198`：音频书「已缓存」判定 =
///   `audioCacheKeys.contains(AudioCacheKey.from(chapter))`；分卷章节
///   （`isVolume`）不参与（L272 `if (!isVolume)` 才更新缓存图标）。
/// - `AudioCacheService.kt:211-225`：每章缓存成功后 post
///   `EventBus.AUDIO_CACHE_CHANGED`，Fragment 订阅逐行增量刷新
///   （L196-208）——我方以 1s 轮询 `BookApi.audioCacheList`（契约 §2.47）
///   实现等价「下载中逐章实时出现」。
/// - `AudioCacheManager.kt:115`：分卷章节拒缓存（`chapter.isVolume →
///   throw "分卷章节不支持缓存"`），故分卷行不应出现徽标。
///
/// 我方落地：音频书章节已缓存判定改取 `audioCacheList` 返回的**章节下标
/// 集合**（非音频书仍走 `listCachedChapterUrls` 文本缓存判定，互不影响），
/// 渲染复用本屏已验收的参考版状态机——已缓存且无字数胶囊 → SUCCESS
/// 对勾 `Icons.check_circle`（即「已缓存」徽标），未缓存 → ⬇，当前章 →
/// 定位图标。本地书恒无徽标（原版 `isLocalBook` 恒视为已缓存 + 本地书
/// 无书源不可缓存，不查询）。1s 轮询内追加 audioCacheList（仅非本地音频
/// 书），无变化跳过 setState（含音频集合为空且未变），查询失败保留旧态。
///
/// 注意：在线书 TocScreen 持有 1s 周期轮询定时器，各用例以显式 tester.pump
/// 推进并在末尾卸载（dispose 取消定时器；teardown 的 periodic Timer 检查
/// 同时证明 dispose 后不再轮询）。
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  /// 数据源调用计数：证明音频书命中 audioCacheList、非音频书/本地书零调用
  var audioListCalls = 0;
  var cachedUrlsCalls = 0;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    audioListCalls = 0;
    cachedUrlsCalls = 0;
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
  Finder chapterRow(String title) =>
      find.ancestor(of: find.text(title), matching: find.byType(ListTile));

  /// 行标题 Text 实例（用于「无变化不 setState」的同一性断言：未重建时
  /// Element 复用同一 widget 实例，重建则产生新实例）。
  Text rowTitleWidget(WidgetTester tester, String title) => tester.widget<Text>(
        find.descendant(of: chapterRow(title), matching: find.text(title)),
      );

  const String bookUrl = 'https://src.com/audio-book/1';

  Book makeBook({
    int bookType = BookType.audio,
    String origin = 'https://src.com',
    int dur = 2,
  }) =>
      Book(
        bookUrl: bookUrl,
        name: '听书',
        author: '作者A',
        totalChapterNum: 3,
        origin: origin,
        bookType: bookType,
        durChapterIndex: dur,
        durChapterTitle: '第三章',
      );

  /// 音频书章节：无字数字段（音频章无正文缓存回填），当前章默认第三章。
  List<BookChapter> makeAudioChapters() => [
        const BookChapter(url: 'a0', title: '第一章', index: 0, bookUrl: bookUrl),
        const BookChapter(url: 'a1', title: '第二章', index: 1, bookUrl: bookUrl),
        const BookChapter(url: 'a2', title: '第三章', index: 2, bookUrl: bookUrl),
      ];

  /// 公共 stub：书架态/章节/文本缓存集合/下载中集合/音频缓存集合/
  /// 标注/书签。音频缓存集合经 [audioCachedByCall] 支持按调用次数变化
  /// （模拟批量缓存逐章落盘）。
  void stubBook({
    required Book book,
    required List<BookChapter> chapters,
    List<String> cachedUrls = const [],
    List<int> audioCached = const [],
    List<int> Function()? audioCachedByCall,
  }) {
    when(() => mockApi.getBook(any())).thenAnswer((_) async => book);
    when(() => mockApi.getChapters(bookUrl)).thenAnswer((_) async => chapters);
    when(() => mockApi.listCachedChapterUrls(bookUrl)).thenAnswer((_) async {
      cachedUrlsCalls++;
      return cachedUrls;
    });
    // 轮询首个查询（契约 §2.43.6 字数映射链），恒空——不 stub 会因
    // MissingStubError 被轮询外层 catch 吞掉而截断后续音频查询
    when(() => mockApi.listCachedChapters(bookUrl))
        .thenAnswer((_) async => const <String, String>{});
    when(() => mockApi.listDownloadingChapters(bookUrl))
        .thenAnswer((_) async => const <int>[]);
    // 恒 stub（即便预期零调用），确保 verify/计数断言不会因 MissingStub
    // 抛错吞掉而失真
    when(() => mockApi.audioCacheList(bookUrl: any(named: 'bookUrl')))
        .thenAnswer((_) async {
      audioListCalls++;
      return audioCachedByCall != null ? audioCachedByCall() : audioCached;
    });
    when(() => mockApi.highlightListByBook(bookUrl: bookUrl))
        .thenAnswer((_) async => '[]');
    when(() => mockApi.getBookmarksByBook('听书', '作者A'))
        .thenAnswer((_) async => const <Bookmark>[]);
  }

  /// 初始渲染：build 帧 + 冲刷异步加载微任务（不推进 1s 轮询定时器）
  Future<void> settleInitial(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
    await tester.pump();
  }

  testWidgets('音频书：audioCacheList 命中章显示「已缓存」对勾徽标，未命中显⬇',
      (tester) async {
    // 音频缓存集合 [0]（第一章已缓存）；当前章第三章未缓存
    stubBook(
      book: makeBook(),
      chapters: makeAudioChapters(),
      audioCached: const [0],
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);

    // 已缓存章「第一章」：SUCCESS 对勾徽标（参考版 CheckCircle，
    // 即音频缓存徽标），不再是未缓存 ⬇
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 未缓存章「第二章」：不显示对勾徽标，显示未缓存 ⬇
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    // 当前章「第三章」：定位图标优先（状态机 isDur 分支）
    expect(
      find.descendant(
        of: chapterRow('第三章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    // 数据源证明：音频书经 audioCacheList 建页即拉取一次
    expect(audioListCalls, greaterThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('音频书：无缓存章不显示对勾徽标；空集轮询无变化不 setState',
      (tester) async {
    stubBook(
      book: makeBook(),
      chapters: makeAudioChapters(),
      audioCached: const [],
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);

    // 音频缓存集合为空：全部非当前章显 ⬇，无任何对勾徽标
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );

    // 1s 轮询仍返回空集（未变）：音频集合为空且未变 → 不 setState，
    // 行标题 Text 保持同一实例（未重建）
    final before = rowTitleWidget(tester, '第一章');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    final after = rowTitleWidget(tester, '第一章');
    expect(
      identical(before, after),
      isTrue,
      reason: '音频集合为空且未变时轮询不应触发 setState 重建',
    );
    // 轮询确实执行了（空集查询同样发起，仅状态未变不重建）
    expect(audioListCalls, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('非音频书：绝不查询音频缓存，仍走文本缓存判定（不误加徽标）',
      (tester) async {
    // 文本书（bookType=8）：文本缓存命中 u0 → 对勾徽标；音频缓存集合
    // 即便有值也不得参与渲染
    final textChapters = [
      const BookChapter(url: 'u0', title: '第一章', index: 0, bookUrl: bookUrl),
      const BookChapter(url: 'u1', title: '第二章', index: 1, bookUrl: bookUrl),
      const BookChapter(url: 'u2', title: '第三章', index: 2, bookUrl: bookUrl),
    ];
    stubBook(
      book: makeBook(bookType: BookType.text),
      chapters: textChapters,
      cachedUrls: const ['u0'],
      audioCached: const [0], // 若误用音频集合，行为与本断言一致时无法
      // 仅凭图标区分，故追加 audioListCalls == 0 的调用断言
    );
    await tester.pumpWidget(
      wrap(TocScreen(book: makeBook(bookType: BookType.text))),
    );
    await settleInitial(tester);

    // 文本缓存命中「第一章」：对勾徽标（原文本书路径不受本批影响）
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    // 未缓存「第二章」：⬇
    expect(
      find.descendant(
        of: chapterRow('第二章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    // 非音频书零消耗音频缓存 FFI（含建页与 1s 轮询）
    expect(audioListCalls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(audioListCalls, 0, reason: 'dispose 前亦不应有 audioCacheList 查询');
  });

  testWidgets('分卷章节不显示缓存徽标（原版拒绝分卷缓存，下标混入亦不渲染）',
      (tester) async {
    final chapters = [
      const BookChapter(url: 'a0', title: '第一章', index: 0, bookUrl: bookUrl),
      const BookChapter(
        url: 'v0',
        title: '第一卷',
        index: 1,
        bookUrl: bookUrl,
        isVolume: true,
      ),
      const BookChapter(url: 'a2', title: '第二章', index: 2, bookUrl: bookUrl),
    ];
    // 防御性夹具：把分卷下标 1 混入音频缓存集合（正常路径不可能——
    // AudioCacheManager.kt:115 拒缓存分卷），分卷行仍不得渲染任何徽标
    stubBook(
      book: makeBook(dur: 2),
      chapters: chapters,
      audioCached: const [0, 1],
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook(dur: 2))));
    await settleInitial(tester);

    // 卷标题行走 _buildVolumeRow（Container），无任何状态图标
    final volumeRow = find.ancestor(
      of: find.text('第一卷'),
      matching: find.byType(Container),
    );
    expect(
      find.descendant(of: volumeRow, matching: find.byIcon(Icons.check_circle)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: volumeRow,
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 对照：同页已缓存普通章「第一章」对勾正常显示（证明集合被消费）
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('音频书轮询：新缓存章对勾徽标出现（数据变化才 setState），无变化不重建',
      (tester) async {
    // 建页首次查询空集（第一章显⬇）；1s 轮询起返回 [0]（模拟音频批量
    // 预下载逐章完成，对齐原版 AUDIO_CACHE_CHANGED 逐行刷新语义）
    var polls = 0;
    stubBook(
      book: makeBook(),
      chapters: makeAudioChapters(),
      audioCachedByCall: () {
        polls++;
        return polls == 1 ? const <int>[] : const <int>[0];
      },
    );
    await tester.pumpWidget(wrap(TocScreen(book: makeBook())));
    await settleInitial(tester);
    await tester.pump(); // 确保书签/设置等旁路异步重建已排空

    // 初始（首次查询空集）：「第一章」无对勾、显 ⬇
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsOneWidget,
    );
    final beforeChange = rowTitleWidget(tester, '第一章');

    // 1s 轮询返回 [0]：数据变化 → setState → 同帧⬇消失、对勾徽标出现
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.download_for_offline_outlined),
      ),
      findsNothing,
    );
    // 行被重建（新 Text 实例）证明本帧发生了 setState
    final afterChange = rowTitleWidget(tester, '第一章');
    expect(
      identical(beforeChange, afterChange),
      isFalse,
      reason: '音频缓存数据变化应触发 setState 重建',
    );

    // 再次轮询（数据未变 [0]）：跳过 setState，行保持同一实例
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    final stable = rowTitleWidget(tester, '第一章');
    expect(
      identical(afterChange, stable),
      isTrue,
      reason: '音频集合未变化时轮询不应触发 setState',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('本地音频书：不显示徽标且零查询（无书源不可缓存 + 原版 isLocalBook 恒 cached）',
      (tester) async {
    // 本地音频书：origin=loc_book，bookType = local | audio（位标记口径）
    const localType = BookType.local | BookType.audio;
    stubBook(
      book: makeBook(bookType: localType, origin: BookType.localTag, dur: 0),
      chapters: makeAudioChapters(),
      cachedUrls: const ['a0'],
      audioCached: const [0],
    );
    await tester.pumpWidget(
      wrap(TocScreen(
        book: makeBook(bookType: localType, origin: BookType.localTag, dur: 0),
      )),
    );
    await settleInitial(tester);

    // 本地书恒视为已缓存：无对勾徽标、无 ⬇（对齐原版 isLocalBook → 图标隐藏）
    expect(find.byIcon(Icons.check_circle), findsNothing);
    expect(find.byIcon(Icons.download_for_offline_outlined), findsNothing);
    // 当前章「第一章」（无字数）：定位图标
    expect(
      find.descendant(
        of: chapterRow('第一章'),
        matching: find.byIcon(Icons.location_on),
      ),
      findsOneWidget,
    );
    // 本地书不查询音频缓存，也不查询文本缓存（免无谓 FFI 与轮询定时器）
    expect(audioListCalls, 0);
    expect(cachedUrlsCalls, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    expect(audioListCalls, 0);
  });
}
