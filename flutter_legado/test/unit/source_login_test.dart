import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/source_login/source_login_notifier.dart';

import '../mocks/mocks.dart';

void main() {
  group('SourceLoginNotifier', () {
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

    SourceLoginState readState() =>
        container.read(sourceLoginNotifierProvider);
    SourceLoginNotifier readNotifier() =>
        container.read(sourceLoginNotifierProvider.notifier);

    test('初始状态为空', () {
      final state = readState();
      expect(state.token, equals(''));
      expect(state.cookies, isEmpty);
      expect(state.headers, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.isSaving, isFalse);
    });

    test('load 解析已保存的登录信息', () async {
      final saved = jsonEncode({
        'token': 'abc123',
        'cookies': [
          {'name': 'sid', 'value': 'xyz'},
        ],
        'headers': [
          {'name': 'X-Token', 'value': 'h1'},
        ],
      });
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => saved);

      await readNotifier().load('https://a.com');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.token, equals('abc123'));
      expect(state.cookies.single.name, equals('sid'));
      expect(state.cookies.single.value, equals('xyz'));
      expect(state.headers.single.name, equals('X-Token'));
      verify(() => mockApi.getConfig('source_login_https://a.com')).called(1);
    });

    test('load 无已保存数据时保持空', () async {
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);

      await readNotifier().load('https://a.com');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.token, equals(''));
      expect(state.cookies, isEmpty);
      expect(state.headers, isEmpty);
    });

    test('addCookie/removeCookie 维护 Cookie 列表', () {
      final n = readNotifier();
      n.addCookie('a', '1');
      n.addCookie('b', '2');
      expect(readState().cookies.length, equals(2));

      n.removeCookie(0);
      expect(readState().cookies.single.name, equals('b'));
    });

    test('addHeader/removeHeader 维护 Header 列表', () {
      final n = readNotifier();
      n.addHeader('h1', 'v1');
      expect(readState().headers.single.value, equals('v1'));

      n.removeHeader(0);
      expect(readState().headers, isEmpty);
    });

    test('clear 清空凭据', () {
      final n = readNotifier();
      n.setToken('t');
      n.addCookie('a', '1');
      n.addHeader('h', 'v');

      n.clear();

      final state = readState();
      expect(state.token, equals(''));
      expect(state.cookies, isEmpty);
      expect(state.headers, isEmpty);
    });

    test('save 经 setConfig 写入 Rust 配置库', () async {
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      final n = readNotifier();
      n.setToken('tok');
      n.addCookie('sid', 'xyz');

      await n.save(sourceUrl: 'https://a.com', sourceName: 'A源');

      final captured = verify(
        () => mockApi.setConfig('source_login_https://a.com', captureAny()),
      ).captured.single as String;
      final decoded = jsonDecode(captured) as Map<String, dynamic>;
      expect(decoded['sourceUrl'], equals('https://a.com'));
      expect(decoded['token'], equals('tok'));
      expect((decoded['cookies'] as List).single['name'], equals('sid'));
      expect(readState().isSaving, isFalse);
    });

    test('save 异常时重新抛出并清除 isSaving', () async {
      when(() => mockApi.setConfig(any(), any()))
          .thenThrow(Exception('写入失败'));

      await expectLater(
        readNotifier().save(sourceUrl: 'https://a.com', sourceName: 'A源'),
        throwsA(isA<Exception>()),
      );
      expect(readState().isSaving, isFalse);
    });
  });
}
