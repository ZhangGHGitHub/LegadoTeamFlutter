import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf_manage/bookshelf_manage_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  group('BookshelfManageNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUpAll(registerFallbacks);

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    BookshelfManageState readState() =>
        container.read(bookshelfManageNotifierProvider);
    BookshelfManageNotifier readNotifier() =>
        container.read(bookshelfManageNotifierProvider.notifier);

    void stubBooks(List<Book> books) {
      when(() => mockApi.getBooks()).thenAnswer((_) async => books);
    }

    const bookA = Book(bookUrl: 'url-a', name: '书A');
    const bookB = Book(bookUrl: 'url-b', name: '书B');

    test('初始状态为空', () {
      final state = readState();
      expect(state.books, isEmpty);
      expect(state.selectedUrls, isEmpty);
      expect(state.isLoading, isFalse);
    });

    test('load 加载书籍并清空勾选', () async {
      stubBooks([bookA, bookB]);

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.books.length, equals(2));
      expect(state.selectedUrls, isEmpty);
    });

    test('load 异常时兜底并记录 error', () async {
      when(() => mockApi.getBooks()).thenThrow(Exception('ffi'));

      await readNotifier().load();

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNotNull);
    });

    test('toggleSelect 勾选与取消', () async {
      stubBooks([bookA, bookB]);
      await readNotifier().load();

      readNotifier().toggleSelect('url-a');
      expect(readState().selectedUrls, equals({'url-a'}));

      readNotifier().toggleSelect('url-a');
      expect(readState().selectedUrls, isEmpty);
    });

    test('selectAll / deselectAll', () async {
      stubBooks([bookA, bookB]);
      await readNotifier().load();

      readNotifier().selectAll();
      expect(readState().selectedUrls, equals({'url-a', 'url-b'}));

      readNotifier().deselectAll();
      expect(readState().selectedUrls, isEmpty);
    });

    test('removeSelected 逐本删除并刷新列表', () async {
      stubBooks([bookA, bookB]);
      await readNotifier().load();
      readNotifier().selectAll();

      when(() => mockApi.deleteBook(any())).thenAnswer((_) async {});
      stubBooks([]); // 删除后列表为空

      await readNotifier().removeSelected();

      verify(() => mockApi.deleteBook('url-a')).called(1);
      verify(() => mockApi.deleteBook('url-b')).called(1);
      final state = readState();
      expect(state.isBusy, isFalse);
      expect(state.books, isEmpty);
      expect(state.selectedUrls, isEmpty);
    });

    test('moveSelectedToGroup 逐本调用 setBookGroup', () async {
      stubBooks([bookA, bookB]);
      await readNotifier().load();
      readNotifier().toggleSelect('url-a');

      when(() => mockApi.setBookGroup(any(), any()))
          .thenAnswer((_) async {});

      await readNotifier().moveSelectedToGroup(4);

      verify(() => mockApi.setBookGroup('url-a', 4)).called(1);
      verifyNever(() => mockApi.setBookGroup('url-b', any()));
      expect(readState().isBusy, isFalse);
    });

    test('pinSelected 逐本调用 topBook', () async {
      stubBooks([bookA, bookB]);
      await readNotifier().load();
      readNotifier().selectAll();

      when(() => mockApi.topBook(any())).thenAnswer((_) async {});

      await readNotifier().pinSelected();

      verify(() => mockApi.topBook('url-a')).called(1);
      verify(() => mockApi.topBook('url-b')).called(1);
      expect(readState().isBusy, isFalse);
    });

    test('无勾选时批量操作不触发契约', () async {
      await readNotifier().removeSelected();
      await readNotifier().moveSelectedToGroup(1);
      await readNotifier().pinSelected();

      verifyNever(() => mockApi.deleteBook(any()));
      verifyNever(() => mockApi.setBookGroup(any(), any()));
      verifyNever(() => mockApi.topBook(any()));
    });

    test('批量删除异常时兜底并记录 error', () async {
      stubBooks([bookA]);
      await readNotifier().load();
      readNotifier().selectAll();

      when(() => mockApi.deleteBook(any())).thenThrow(Exception('ffi'));

      await readNotifier().removeSelected();

      final state = readState();
      expect(state.isBusy, isFalse);
      expect(state.error, isNotNull);
    });
  });
}
