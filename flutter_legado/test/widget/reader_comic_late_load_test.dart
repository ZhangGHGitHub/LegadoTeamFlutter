// P3-5 回归：漫画阅读器 _loadBook 的迟到回调不得在页面销毁后 setState
//
// 场景：getBook 是慢请求（弱网），用户等待期间返回；迟到的 setState 在
// debug 包会抛 "setState() called after dispose()"。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/reader_comic_screen.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

class _PendingBookApi extends MockBookApi {
  final completer = Completer<Book?>();
  int chaptersCalls = 0;

  @override
  Future<Book?> getBook(String bookUrl) => completer.future;

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async {
    chaptersCalls++;
    return const [];
  }
}

void main() {
  testWidgets('getBook 在页面销毁后才返回：不再继续加载/写状态', (tester) async {
    final api = _PendingBookApi();
    final container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: ReaderComicScreen(bookUrl: 'https://example.test/comic/1'),
        ),
      ),
    );
    await tester.pump();
    expect(api.completer.isCompleted, isFalse, reason: 'getBook 仍处于等待中');

    // 卸载页面（用户返回）
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    // 迟到的 getBook 结果：页面已销毁，后续目录加载/状态写入必须停止
    api.completer.complete(const Book(
      bookUrl: 'https://example.test/comic/1',
      name: '迟到的漫画',
      origin: 'https://example.test',
    ));
    await tester.pump();
    await tester.pump();

    expect(api.chaptersCalls, 0, reason: '页面销毁后不得继续加载目录');
    expect(tester.takeException(), isNull);
  });
}
