// [批25 P2 | 2026-11-13 设备验收] 段评摘要加载触发回归测试 — 全栈工程师
//
// 缺陷（设备已复现）：带 ruleReview 书源在阅读器中从不请求
// `/review/summary`，段落无徽标、段评面板不可达。根因是
// `_loadReviewSummary` 绑在「相邻章预载」的 loading 跃迁分支里；开书
// 路径（先 openBook 后 push 阅读器）正文已就绪时首帧 `isLoading=false`，
// 跃迁永不发生 → 摘要永不加载。
//
// 用例：
// 1. 首进阅读器（正文已就绪、首帧无 loading 跃迁）→ 摘要请求 1 次，
//    正文出现段评角标（修前 0 次，红）
// 2. 切章 → 按新章再次请求并换成新章徽标（累计 2 次）
// 3. 同章重复构建（控件显隐）→ 不重复请求（仍 2 次）
// 4. 书源无 ruleReview → 从不请求（既有行为不回归）
// 5. [审查 P2-1] 首次摘要失败 → 2s 退避窗口内不重复请求，退避结束后
//    自动重试成功并渲染徽标（修前失败即永久占键，红）
// 6. [审查 P2-1] 持续失败时自动重试有上限（首次 + 3 次重试后停止）
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/screens/reader_screen.dart';
import 'package:flutter_legado/src/widgets/reader/review_column.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/review-summary',
  name: '段评书',
  author: '作者',
  origin: 'https://source-review.com',
  originName: '段评源',
);

const _chapters = [
  BookChapter(
    url: 'https://book.com/review-summary/c1',
    title: '第一章',
    index: 0,
  ),
  BookChapter(
    url: 'https://book.com/review-summary/c2',
    title: '第二章',
    index: 1,
  ),
];

/// 开启 ruleReview 的书源（摘要规则与设备验收夹具同形）
const _reviewSource = BookSource(
  bookSourceUrl: 'https://source-review.com',
  bookSourceName: '段评源',
  ruleReview: ReviewRule(
    enabled: true,
    reviewSummaryUrl: 'https://source-review.com/review/summary',
    summaryListRule: r'$.data',
    summaryParagraphIndexRule: r'$.idx',
    summaryCountRule: r'$.cnt',
  ),
);

/// 无段评规则的书源（不应触发摘要请求）
const _plainSource = BookSource(
  bookSourceUrl: 'https://source-review.com',
  bookSourceName: '普通源',
);

/// 摘要请求计数
///
/// mocktail 的 `verify` 会消费已匹配的调用记录，无法直接累计断言，
/// 故用显式计数器记录 `reviewGetSummary` 实际调用次数。
class _SummaryCounter {
  int calls = 0;
}

/// 阅读主链路桩：目录/正文/源/配置/进度 + 段评摘要
///
/// 摘要按章返回不同计数（c1: 段1=7、段2=3；c2: 段2=9），用于断言
/// 「切章后重新请求且旧章徽标不残留」。
MockRustApi _stubApi({
  BookSource source = _reviewSource,
  _SummaryCounter? summaryCounter,
  int failFirstSummaryCalls = 0,
}) {
  final api = MockRustApi();
  when(() => api.getChapters(any())).thenAnswer((_) async => _chapters);
  when(() => api.getChapterContentFull(any(), any())).thenAnswer((i) async {
    final index = i.positionalArguments[1] as int;
    return index == 0 ? '第一章第一段正文。\n第一章第二段正文。' : '第二章第一段正文。\n第二章第二段正文。';
  });
  when(() => api.getChapterContent(any(), any())).thenAnswer((_) async => '');
  when(() => api.getBookSources()).thenAnswer((_) async => [source]);
  when(() => api.getConfig(any())).thenAnswer((_) async => '');
  when(() => api.getBook(any())).thenAnswer((_) async => _book);
  when(
    () => api.updateReadingProgress(
      bookUrl: any(named: 'bookUrl'),
      chapterIndex: any(named: 'chapterIndex'),
      chapterPos: any(named: 'chapterPos'),
    ),
  ).thenAnswer((_) async {});
  when(() => api.reviewGetSummary(any(), any())).thenAnswer((i) async {
    summaryCounter?.calls++;
    // [审查 P2-1] 前 N 次强制造失败，用于验证失败后不占去重键且会退避重试
    if (summaryCounter != null &&
        summaryCounter.calls <= failFirstSummaryCalls) {
      throw Exception('模拟摘要请求失败');
    }
    final request =
        jsonDecode(i.positionalArguments[1] as String) as Map<String, dynamic>;
    final chapter = request['chapter'] as Map<String, dynamic>?;
    final url = chapter?['url'] as String? ?? '';
    if (url.endsWith('/c2')) {
      return jsonEncode({
        'counts': {'2': 9},
        'keys': {'2': 'p2'},
      });
    }
    return jsonEncode({
      'counts': {'1': 7, '2': 3},
      'keys': {'1': 'p1', '2': 'p2'},
    });
  });
  return api;
}

/// 启动 App（首页按钮 push 真实 ReaderScreen）
Future<ProviderContainer> _pumpLauncher(
  WidgetTester tester,
  MockRustApi api,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [bookApiProvider.overrideWithValue(api)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<Route<dynamic>>(
                    builder: (_) => const ReaderScreen(),
                  ),
                ),
                child: const Text('进入阅读'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return ProviderScope.containerOf(tester.element(find.text('进入阅读')));
}

/// 生产开书顺序：先 openBook 装载完成，再 push 阅读器（书架/详情页同序）
///
/// 该顺序下 ReaderScreen 首帧 `isLoading` 即为 false——修复前
/// `_wasLoading && !isLoading` 跃迁永不发生，摘要请求为 0。
Future<ProviderContainer> _enterReaderWithContentReady(
  WidgetTester tester,
  MockRustApi api,
) async {
  final container = await _pumpLauncher(tester, api);
  await container.read(readerNotifierProvider.notifier).openBook(_book);
  await tester.pumpAndSettle();
  expect(
    container.read(readerNotifierProvider).isLoading,
    isFalse,
    reason: '前置：阅读器首帧正文已就绪（修复前无 loading 跃迁）',
  );
  await tester.tap(find.text('进入阅读'));
  await tester.pumpAndSettle();
  expect(find.byType(ReaderScreen), findsOneWidget);
  return container;
}

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({'enableReadRecord': false});
  });

  testWidgets('首进阅读器正文已就绪即加载段评摘要并渲染徽标', (tester) async {
    final summary = _SummaryCounter();
    final api = _stubApi(summaryCounter: summary);

    await _enterReaderWithContentReady(tester, api);

    expect(summary.calls, 1, reason: '首进阅读器正文就绪即应请求一次摘要（修复前为 0）');
    final badgeCounts = tester
        .widgetList<ReviewColumnBadge>(find.byType(ReviewColumnBadge))
        .map((badge) => badge.count)
        .toList();
    expect(
      badgeCounts,
      containsAll(<int>[7, 3]),
      reason: '摘要 counts 应经 _reviewCounts 渲染到正文段落角标',
    );
  });

  testWidgets('切章后重新加载摘要并替换徽标，同章不重复请求', (tester) async {
    final summary = _SummaryCounter();
    final api = _stubApi(summaryCounter: summary);
    final container = await _enterReaderWithContentReady(tester, api);
    expect(summary.calls, 1);

    await container.read(readerNotifierProvider.notifier).nextChapter();
    await tester.pumpAndSettle();
    final switched = container.read(readerNotifierProvider);
    expect(switched.currentChapterIndex, 1, reason: '前置：已切到第二章');
    expect(switched.isLoading, isFalse, reason: '前置：新章正文已加载完成');
    expect(switched.error, isNull, reason: '前置：新章加载无错误');
    expect(summary.calls, 2, reason: '切章后应按新章重新请求摘要');

    final badgeCounts = tester
        .widgetList<ReviewColumnBadge>(find.byType(ReviewColumnBadge))
        .map((badge) => badge.count)
        .toList();
    expect(badgeCounts, contains(9), reason: '新章摘要应生效');
    expect(badgeCounts, isNot(contains(7)), reason: '旧章计数不得残留到新章正文');

    // 同章重复构建（控件显隐两次）不重复请求
    final notifier = container.read(readerNotifierProvider.notifier);
    notifier.toggleControls();
    await tester.pumpAndSettle();
    notifier.toggleControls();
    await tester.pumpAndSettle();
    expect(summary.calls, 2, reason: '同一章重复构建不得重复请求摘要');
  });

  testWidgets('书源无 ruleReview 时不请求段评摘要', (tester) async {
    final api = _stubApi(source: _plainSource);

    await _enterReaderWithContentReady(tester, api);

    verifyNever(() => api.reviewGetSummary(any(), any()));
    expect(find.byType(ReviewColumnBadge), findsNothing);
  });

  // [审查 P2-1 | 2026-11-13] 失败/竞态不得占用去重键：修复前
  // `_maybeLoadReviewSummary` 在发起请求前即写 `_reviewLoadedKey`，同章
  // 一次失败后永久不再重试，徽标与段评面板均不可达。
  testWidgets('摘要首次失败后按 2s 退避自动重试，成功后渲染徽标', (tester) async {
    final summary = _SummaryCounter();
    final api = _stubApi(summaryCounter: summary, failFirstSummaryCalls: 1);
    final container = await _enterReaderWithContentReady(tester, api);

    expect(summary.calls, 1, reason: '首进阅读器应发起一次摘要请求并失败');
    expect(find.byType(ReviewColumnBadge), findsNothing, reason: '失败后不得残留摘要徽标');

    // 退避窗口内同章重复构建（控件显隐）不得再打 FFI
    final notifier = container.read(readerNotifierProvider.notifier);
    notifier.toggleControls();
    await tester.pump();
    notifier.toggleControls();
    await tester.pump();
    expect(summary.calls, 1, reason: '2s 退避窗口内的重复 build 不得重复请求摘要（防弱网抖动）');

    // 退避结束：定时器触发重建 → 同章重试成功
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(summary.calls, 2, reason: '首次失败后应在退避结束后自动重试（修复前永久不重试）');
    final badgeCounts = tester
        .widgetList<ReviewColumnBadge>(find.byType(ReviewColumnBadge))
        .map((badge) => badge.count)
        .toList();
    expect(
      badgeCounts,
      containsAll(<int>[7, 3]),
      reason: '重试成功后摘要 counts 应渲染到正文段落角标',
    );
  });

  testWidgets('摘要持续失败时自动重试有上限，不会无限打 FFI', (tester) async {
    final summary = _SummaryCounter();
    final api = _stubApi(summaryCounter: summary, failFirstSummaryCalls: 999);
    await _enterReaderWithContentReady(tester, api);
    expect(summary.calls, 1, reason: '首次请求已发生');

    // 每次退避结束触发一次自动重试：共 3 次
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    }
    expect(summary.calls, 4, reason: '首次失败后最多自动重试 3 次');

    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(summary.calls, 4, reason: '达到重试上限后不得继续自动重试');
  });
}
