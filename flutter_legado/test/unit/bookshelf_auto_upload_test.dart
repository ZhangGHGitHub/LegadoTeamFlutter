// 批40：导入后自动上传接线（BookshelfNotifier → WebDavBookUploadService）
//
// 覆盖：开关开启时导入成功后异步上传书籍文件（不阻断导入返回）；开关
// 关闭时不上传。上传失败不阻断导入由 WebDavBookUploadService 单测覆盖。
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const importedBook = Book(
    bookUrl: '/books/a.txt',
    name: '本地书A',
    author: '',
    origin: 'local',
    originName: 'a.txt',
  );

  late FakeServersRustApi api;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = FakeServersRustApi();
    api.seedServer(
      config: jsonEncode({
        'url': 'https://dav.example.com/',
        'username': 'u',
        'password': 'p',
      }),
    );
    when(() => api.getBookGroups()).thenAnswer((_) async => []);
    when(() => api.getBooks()).thenAnswer((_) async => []);
    when(() => api.importLocalBook(any()))
        .thenAnswer((_) async => importedBook);
    when(() => api.webdavUploadFile(any(), any(), any()))
        .thenAnswer((_) async {});
    when(() => api.getBook(any())).thenAnswer((_) async => null);
    when(() => api.updateBook(any())).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
  });

  /// 等待 build() 初始化与 unawaited 自动上传完成
  Future<void> settle() async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('开关开启：导入成功后异步上传到 books/<originName>', () async {
    SharedPreferences.setMockInitialValues({'webDavBookAutoUpload': true});
    container.read(bookshelfNotifierProvider.notifier);

    final book = await container
        .read(bookshelfNotifierProvider.notifier)
        .importLocalBook('/books/a.txt');
    expect(book.bookUrl, importedBook.bookUrl, reason: '导入结果必须先返回');

    await settle();
    verify(
      () => api.webdavUploadFile(any(), 'books/a.txt', '/books/a.txt'),
    ).called(1);
  });

  test('开关关闭：导入成功后不上传', () async {
    SharedPreferences.setMockInitialValues({'webDavBookAutoUpload': false});
    container.read(bookshelfNotifierProvider.notifier);

    await container
        .read(bookshelfNotifierProvider.notifier)
        .importLocalBook('/books/a.txt');
    await settle();

    verifyNever(() => api.webdavUploadFile(any(), any(), any()));
  });
}
