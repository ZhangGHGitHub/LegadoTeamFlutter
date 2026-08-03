import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/remote_book/remote_book_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  group('RemoteBookNotifier.parseUrls', () {
    test('多行解析：去空白/空行/去重/仅 http(s)', () {
      final urls = RemoteBookNotifier.parseUrls(
        'https://a.com/1\n'
        '  https://a.com/2  \n'
        '\n'
        'https://a.com/1\n'
        'ftp://a.com/3\n'
        '不是链接\n'
        'http://b.com/4',
      );
      expect(urls, equals([
        'https://a.com/1',
        'https://a.com/2',
        'http://b.com/4',
      ]));
    });

    test('空文本返回空列表', () {
      expect(RemoteBookNotifier.parseUrls('  \n  '), isEmpty);
    });
  });

  group('RemoteBookNotifier.nameFromUrl', () {
    test('取路径末段并去扩展名', () {
      expect(
        RemoteBookNotifier.nameFromUrl('https://a.com/book/123.html'),
        equals('123'),
      );
    });

    test('URL 解码末段', () {
      expect(
        RemoteBookNotifier.nameFromUrl('https://a.com/book/Hello%20World'),
        equals('Hello World'),
      );
    });

    test('截断百分号编码兜底原串（不抛异常）', () {
      expect(
        RemoteBookNotifier.nameFromUrl('https://a.com/book/abc%E4'),
        equals('https://a.com/book/abc%E4'),
      );
    });

    test('UTF-8 多字节百分号编码正常解码', () {
      expect(
        RemoteBookNotifier.nameFromUrl(
            'https://a.com/book/%E4%B8%89%E4%BD%93'),
        equals('三体'),
      );
    });

    test('无路径时兜底主机名', () {
      expect(
        RemoteBookNotifier.nameFromUrl('https://a.com/'),
        equals('a.com'),
      );
    });
  });

  group('RemoteBookNotifier.importUrls', () {
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

    RemoteBookState readState() => container.read(remoteBookNotifierProvider);
    RemoteBookNotifier readNotifier() =>
        container.read(remoteBookNotifierProvider.notifier);

    test('初始状态为空', () {
      final state = readState();
      expect(state.isImporting, isFalse);
      expect(state.importedCount, isNull);
      expect(state.error, isNull);
    });

    test('导入成功记录数量并透传 JSON', () async {
      when(() => mockApi.importBooks(any())).thenAnswer((_) async => 2);

      await readNotifier().importUrls('https://a.com/1\nhttps://a.com/2');

      final state = readState();
      expect(state.isImporting, isFalse);
      expect(state.importedCount, equals(2));
      expect(state.error, isNull);

      final captured = verify(() => mockApi.importBooks(captureAny()))
          .captured
          .single as String;
      final list = jsonDecode(captured) as List<dynamic>;
      expect(list.length, equals(2));
      expect(list.first['bookUrl'], equals('https://a.com/1'));
      expect(list.first['origin'], equals('web'));
    });

    test('无有效链接时记录错误且不触发契约', () async {
      await readNotifier().importUrls('随便一些文字');

      final state = readState();
      expect(state.isImporting, isFalse);
      expect(state.importedCount, isNull);
      expect(state.error, isNotNull);
      verifyNever(() => mockApi.importBooks(any()));
    });

    test('异常时兜底并记录 error', () async {
      when(() => mockApi.importBooks(any())).thenThrow(Exception('ffi'));

      await readNotifier().importUrls('https://a.com/1');

      final state = readState();
      expect(state.isImporting, isFalse);
      expect(state.importedCount, isNull);
      expect(state.error, isNotNull);
    });
  });
}
