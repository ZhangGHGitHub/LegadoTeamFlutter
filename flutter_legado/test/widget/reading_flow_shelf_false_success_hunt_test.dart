// 视角 A：阅读主流程「状态机 / 生命周期」缺陷猎捕 —— 红态复现用例（widget 层）
//
// F3 「加入书架」静默失败 → 详情页无条件成功提示：
//   book_info_screen_builders.part.dart:1749-1757
//     await notifier.addBook(book.copyWith(...));   // BookshelfNotifier.addBook
//     setState(() => _inBookshelf = true);          // 不看结果
//     SnackBar('《x》已加入书架')                      // 无条件成功
//   provers/bookshelf/bookshelf_notifier.dart:118-126 addBook 把异常吞进
//   state.error 后正常返回 → 调用方无法区分成功/失败；
//   而 bookshelf_screen.dart:481 只在 books.isEmpty 时才把 state.error
//   渲染成 ErrorView，书架非空时该错误完全不可见。
//
// 本用例**故意断言「失败不得报成功」**：当前实现报成功 → 红 = 缺陷复现。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/book_info_screen.dart';
import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/theme/md3_colors.dart';

import '../mocks/mocks.dart';

void main() {
  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// 未入库在线书（getBook → null ⇒ 不在书架，「加书架」卡可用）
  const book = Book(
    bookUrl: 'u1',
    name: '测试书',
    author: '作者',
    origin: '',
    coverUrl: '',
    durChapterIndex: 0,
    durChapterPos: 0,
  );

  testWidgets('[F3] 加入书架写库失败时不得提示「已加入书架」', (tester) async {
    tester.view.physicalSize = const Size(1080, 2260);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final mockApi = MockRustApi();
    when(() => mockApi.getBook(any())).thenAnswer((_) async => null);
    when(() => mockApi.getChapters(any())).thenAnswer((_) async => const []);
    when(() => mockApi.getBooks()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookGroups()).thenAnswer((_) async => const []);
    when(() => mockApi.getBookSources()).thenAnswer((_) async => const []);
    when(() => mockApi.getConfig(any())).thenAnswer((_) async => '');
    // 写库失败（DB 异常 / 磁盘满 / 桥接错误）
    when(() => mockApi.addBook(any())).thenThrow(
      StateError('DB 写入失败（复现用）'),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          theme: AppTheme.palette(
            brightness: Brightness.light,
            palette: Md3Palettes.wh,
          ),
          home: const BookInfoScreen(book: book),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: '基线：详情页可正常渲染');

    // 基线：四个操作卡中的「加书架」可见可点
    expect(find.text('加书架'), findsOneWidget, reason: '基线：未入库 ⇒ 显示「加书架」');
    await tester.tap(find.text('加书架'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // 失败必须可见（不得出现成功提示）
    expect(
      find.text('《测试书》已加入书架'),
      findsNothing,
      reason:
          'addBook 抛错但 BookshelfNotifier 吞掉异常正常返回 → 详情页仍 '
          'setState(_inBookshelf = true) 并弹「已加入书架」；用户回书架'
          '看不到这本书（state.books 未追加），且书架非空时 state.error '
          '不渲染 → 完全静默的假成功',
    );
    expect(
      find.text('已在书架'),
      findsNothing,
      reason: '卡片标签也不应切到「已在书架」（本地 _inBookshelf 被无条件置 true）',
    );
  });
}
