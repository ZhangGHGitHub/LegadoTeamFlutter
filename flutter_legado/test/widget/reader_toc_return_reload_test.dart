// 批7a P1-A：目录页返回阅读器时的正文重载判定
//
// 设备验收缺陷：目录页写 readConfig.useReplaceRule 后返回，阅读器只刷新
// currentBook 快照，已渲染正文仍按旧配置，需切章才生效。
// 本测试固定 refreshReaderBookAfterToc 的判定与重载调用（useReplaceRule /
// reSegment 变化才 reload；null 与显式 false 不等价）。
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

import '../mocks/mocks.dart';

/// 只计数 reload，不触发真实取正文
class _SpyReaderNotifier extends ReaderNotifier {
  int reloadCount = 0;

  @override
  Future<void> reloadChapterContent() async {
    reloadCount++;
  }
}

class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => refreshReaderBookAfterToc(ref),
          child: const Text('refresh'),
        ),
      ),
    );
  }
}

void main() {
  setUpAll(registerFallbacks);

  const bookUrl = 'https://batch7a.example.com/toc-return';
  const oldBook = Book(
    bookUrl: bookUrl,
    name: '目录返回测试',
    author: '作者',
    origin: 'https://batch7a.example.com',
    readConfig: ReadConfig(useReplaceRule: true, reSegment: false),
  );

  late MockRustApi api;
  late ProviderContainer container;
  late _SpyReaderNotifier spy;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    container = ProviderContainer(
      overrides: [
        bookApiProvider.overrideWithValue(api),
        readerNotifierProvider.overrideWith(_SpyReaderNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    spy = container.read(readerNotifierProvider.notifier) as _SpyReaderNotifier;
    spy.updateCurrentBook(oldBook);
  });

  Future<void> run(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _Harness()),
      ),
    );
    await tester.tap(find.text('refresh'));
    await tester.pumpAndSettle();
  }

  testWidgets('useReplaceRule 变化 → 重载一次正文并刷新快照', (tester) async {
    when(() => api.getBook(bookUrl)).thenAnswer(
      (_) async => oldBook.copyWith(
        readConfig: const ReadConfig(useReplaceRule: false, reSegment: false),
      ),
    );

    await run(tester);

    expect(spy.reloadCount, 1, reason: '书级替换开关变化必须重载正文');
    expect(
      container.read(readerNotifierProvider).currentBook?.readConfig?.useReplaceRule,
      isFalse,
      reason: 'fresh 快照应写回 currentBook',
    );
  });

  testWidgets('reSegment 变化 → 重载一次正文', (tester) async {
    when(() => api.getBook(bookUrl)).thenAnswer(
      (_) async => oldBook.copyWith(
        readConfig: const ReadConfig(useReplaceRule: true, reSegment: true),
      ),
    );

    await run(tester);

    expect(spy.reloadCount, 1, reason: '重新分段变化必须重载正文');
  });

  testWidgets('null → 显式 false 视为变化（null 非 false）', (tester) async {
    spy.updateCurrentBook(
      oldBook.copyWith(readConfig: const ReadConfig()),
    );
    when(() => api.getBook(bookUrl)).thenAnswer(
      (_) async => oldBook.copyWith(
        readConfig: const ReadConfig(useReplaceRule: false),
      ),
    );

    await run(tester);

    expect(spy.reloadCount, 1, reason: 'null 与显式 false 语义不同，应重载');
  });

  testWidgets('配置未变化 → 不重载正文', (tester) async {
    when(() => api.getBook(bookUrl)).thenAnswer((_) async => oldBook);

    await run(tester);

    expect(spy.reloadCount, 0, reason: '配置无变化不应触发无谓重载');
  });
}
