// [批4a] 顶栏/九宫格共用动作 helper 回归
//
// 编写：全栈工程师（批4a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';
import 'package:flutter_legado/src/widgets/reader/reader_action_helpers.dart';
import 'package:flutter_legado/src/widgets/reader/reader_top_bar.dart';

import '../mocks/mocks.dart';

const _book = Book(
  bookUrl: 'https://book.com/helper4a',
  name: 'Helper书',
  author: '作者H',
  origin: 'https://source-h.com',
  readConfig: ReadConfig(useReplaceRule: true),
);

class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      body: Column(
        children: [
          TextButton(
            key: const ValueKey('helper-edit'),
            onPressed: () => showReaderEditContentDialog(context, ref),
            child: const Text('edit'),
          ),
          TextButton(
            key: const ValueKey('helper-replace'),
            onPressed: () => toggleReaderReplaceRule(context, ref),
            child: const Text('replace'),
          ),
          TextButton(
            key: const ValueKey('helper-sync'),
            onPressed: () => syncReaderProgress(context, ref),
            child: const Text('sync'),
          ),
        ],
      ),
    );
  }
}

void main() {
  setUpAll(registerFallbacks);

  late MockRustApi api;
  late ProviderContainer container;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = MockRustApi();
    stubEmptyWebdavServers(api);
    when(() => api.updateBook(any())).thenAnswer((_) async {});
    when(
      () => api.getChapterContentFull(any(), any()),
    ).thenAnswer((_) async => '正文');
    when(() => api.getConfig(any())).thenAnswer((_) async => '');
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    container.read(readerNotifierProvider.notifier).updateCurrentBook(_book);
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: _Harness()),
      ),
    );
    await tester.pump();
  }

  testWidgets('编辑内容 helper 打开同一编辑对话框', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('helper-edit')));
    await tester.pumpAndSettle();
    expect(find.text('编辑内容'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('替换开关 helper 写 ReadConfig 并提示', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('helper-replace')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final captured = verify(() => api.updateBook(captureAny())).captured;
    final updated = captured.single as Book;
    expect(updated.readConfig?.useReplaceRule, isFalse);
    expect(find.text('已关闭替换规则'), findsOneWidget);
  });

  testWidgets('顶栏菜单仍调用抽离后的编辑/替换 helper', (tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Stack(children: [ReaderTopBar(onAddBookmark: () {})]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑内容'));
    await tester.pumpAndSettle();
    expect(find.text('编辑内容'), findsWidgets);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('替换规则'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final captured = verify(() => api.updateBook(captureAny())).captured;
    expect((captured.last as Book).readConfig?.useReplaceRule, isFalse);
  });

  testWidgets('同步进度 helper 未配置时给出开启同步提示', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('helper-sync')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
