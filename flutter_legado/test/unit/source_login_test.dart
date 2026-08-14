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

    test('load 解析 source_login_cache 保存的登录信息', () async {
      when(() => mockApi.getLoginInfo('https://a.com'))
          .thenAnswer((_) async => jsonEncode({'token': 'abc123'}));
      when(() => mockApi.getLoginHeader('https://a.com')).thenAnswer(
        (_) async => jsonEncode({
          'X-Token': 'h1',
          'Cookie': 'sid=xyz; theme=dark',
        }),
      );

      await readNotifier().load('https://a.com');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.token, equals('abc123'));
      expect(state.cookies.length, equals(2));
      expect(state.cookies.first.name, equals('sid'));
      expect(state.cookies.first.value, equals('xyz'));
      expect(state.headers.single.name, equals('X-Token'));
      expect(state.headers.single.value, equals('h1'));
      verify(() => mockApi.getLoginInfo('https://a.com')).called(1);
      verify(() => mockApi.getLoginHeader('https://a.com')).called(1);
    });

    test('load 无已保存数据时保持空（含旧 config 键回退迁移）', () async {
      when(() => mockApi.getLoginInfo('https://a.com'))
          .thenAnswer((_) async => '');
      when(() => mockApi.getLoginHeader('https://a.com'))
          .thenAnswer((_) async => '');
      when(() => mockApi.getConfig(any())).thenAnswer((_) async => null);

      await readNotifier().load('https://a.com');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.token, equals(''));
      expect(state.cookies, isEmpty);
      expect(state.headers, isEmpty);
    });

    test('load 回退旧 config 键（历史数据迁移）', () async {
      when(() => mockApi.getLoginInfo('https://a.com'))
          .thenAnswer((_) async => '');
      when(() => mockApi.getLoginHeader('https://a.com'))
          .thenAnswer((_) async => '');
      when(() => mockApi.getConfig('source_login_https://a.com'))
          .thenAnswer(
        (_) async => jsonEncode({
          'token': 'old-tok',
          'cookies': [
            {'name': 'sid', 'value': 'old'},
          ],
          'headers': [
            {'name': 'X-Old', 'value': 'v'},
          ],
        }),
      );

      await readNotifier().load('https://a.com');

      final state = readState();
      expect(state.token, equals('old-tok'));
      expect(state.cookies.single.name, equals('sid'));
      expect(state.headers.single.name, equals('X-Old'));
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

    test('save 经 putLoginInfo/putLoginHeader 写入 source_login_cache', () async {
      when(() => mockApi.putLoginInfo(any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.putLoginHeader(any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.setConfig(any(), any())).thenAnswer((_) async {});
      final n = readNotifier();
      n.setToken('tok');
      n.addCookie('sid', 'xyz');
      n.addHeader('X-Token', 'h1');

      await n.save(sourceUrl: 'https://a.com', sourceName: 'A源');

      // loginHeader：headers + Cookie 合并
      final headerCaptured = verify(
        () => mockApi.putLoginHeader('https://a.com', captureAny()),
      ).captured.single as String;
      final headerDecoded = jsonDecode(headerCaptured) as Map<String, dynamic>;
      expect(headerDecoded['X-Token'], equals('h1'));
      expect(headerDecoded['Cookie'], equals('sid=xyz'));

      // userInfo：token 落库
      final infoCaptured = verify(
        () => mockApi.putLoginInfo('https://a.com', captureAny()),
      ).captured.single as String;
      final infoDecoded = jsonDecode(infoCaptured) as Map<String, dynamic>;
      expect(infoDecoded['token'], equals('tok'));

      expect(readState().isSaving, isFalse);
    });

    test('save 异常时重新抛出并清除 isSaving', () async {
      when(() => mockApi.putLoginHeader(any(), any()))
          .thenAnswer((_) async {});
      when(() => mockApi.putLoginInfo(any(), any()))
          .thenThrow(Exception('写入失败'));

      await expectLater(
        readNotifier().save(sourceUrl: 'https://a.com', sourceName: 'A源'),
        throwsA(isA<Exception>()),
      );
      expect(readState().isSaving, isFalse);
    });
  });
}
