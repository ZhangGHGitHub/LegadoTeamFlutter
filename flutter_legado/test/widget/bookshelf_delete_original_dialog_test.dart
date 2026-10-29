import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/bookshelf_screen.dart';
import 'package:flutter_legado/src/services/book_api.dart' show DeleteBooksResult;
import 'package:flutter_legado/src/services/mock_book_api.dart';

/// [批35] 批量删除确认框「删除源文件」Checkbox 行为：
/// 仅当选中集合含本地/WebDAV 书时显示；勾选后 deleteBooks 透传
/// deleteOriginal=true；文件删除失败提示随 SnackBar 汇总展示。
///
/// 与 bookshelf_batch_mode_test.dart 同因（MockBookApi 经 rootBundle 惰性
/// 加载样例资产，fake-async 域内仅首个用例可靠完成资产加载），本文件只保留
/// 一个用例，把「无本地书不显示 / 有本地书显示 + 透传」串在同一用例内。
void main() {
  /// 捕获 deleteBooks 入参的 Mock 子类（其余行为沿用 MockBookApi 样例数据）
  testWidgets('删除确认框按选中集合显示「删除源文件」并透传 deleteOriginal',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final api = _CapturingMockBookApi();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(api)],
        child: MaterialApp(home: BookshelfScreen()),
      ),
    );
    final context = tester.element(find.byType(BookshelfScreen));
    final container = ProviderScope.containerOf(context);
    addTearDown(container.dispose);
    // Notifier build() 的微任务 + 异步加载：连续 pump 落定
    await tester.pump();
    await tester.pump();
    await tester.pump();

    final notifier = container.read(bookshelfNotifierProvider.notifier);
    final state = container.read(bookshelfNotifierProvider);
    // 样例数据中 01 为在线书、06 为本地书（loc_book + local 位）
    final onlineUrl = state.books
        .firstWhere((b) => b.name == '示例书籍 01')
        .bookUrl;
    final localUrl = state.books
        .firstWhere((b) => b.name == '示例书籍 06')
        .bookUrl;

    notifier.toggleBatchMode();
    await tester.pumpAndSettle();
    notifier.toggleSelect(onlineUrl);
    await tester.pumpAndSettle();

    // 仅在线书：不显示「删除源文件」
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    expect(find.text('已选1本'), findsOneWidget);
    expect(find.text('删除源文件'), findsNothing,
        reason: '选中集合不含本地书时不提供删除源文件');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    // 改为选中本地书：显示勾选，勾选后确认删除
    notifier.clearSelection();
    notifier.toggleSelect(localUrl);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.delete_rounded));
    await tester.pumpAndSettle();
    expect(find.text('删除源文件'), findsOneWidget,
        reason: '选中集合含本地书时显示删除源文件勾选');

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(api.lastDeleteUrls, [localUrl]);
    expect(api.lastDeleteOriginal, isTrue, reason: '勾选后必须透传 deleteOriginal=true');
    // 文件删除失败提示不阻断记录删除：SnackBar 同时给出已删除与失败原因
    expect(
      find.textContaining('已删除 1 本书籍'),
      findsOneWidget,
    );
    expect(find.textContaining('部分源文件未删除'), findsOneWidget);
    expect(find.text('示例书籍 06'), findsNothing, reason: '书籍记录已删除');
  });
}

class _CapturingMockBookApi extends MockBookApi {
  List<String>? lastDeleteUrls;
  bool? lastDeleteOriginal;

  @override
  Future<DeleteBooksResult> deleteBooks(
    List<String> bookUrls, {
    bool deleteOriginal = false,
  }) async {
    lastDeleteUrls = List<String>.of(bookUrls);
    lastDeleteOriginal = deleteOriginal;
    final result = await super.deleteBooks(
      bookUrls,
      deleteOriginal: deleteOriginal,
    );
    // 模拟「本地文件删除失败」提示（Rust 侧真实返回形态）
    return DeleteBooksResult(
      deleted: result.deleted,
      missing: result.missing,
      warnings: const ['《示例书籍 06》原文件不存在或不可访问，已跳过文件删除'],
    );
  }
}
