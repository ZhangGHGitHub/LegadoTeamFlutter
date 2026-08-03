import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/change_cover/change_cover_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  group('CoverCandidate.fromJson', () {
    test('解析 url/width/height', () {
      final c = CoverCandidate.fromJson({
        'url': 'https://x.com/cover.jpg',
        'width': 240,
        'height': 320,
      });
      expect(c.url, equals('https://x.com/cover.jpg'));
      expect(c.width, equals(240));
      expect(c.height, equals(320));
    });

    test('缺省字段兜底为空值/零', () {
      const c = CoverCandidate();
      expect(c.url, isEmpty);
      expect(c.width, isZero);
      expect(c.height, isZero);
    });
  });

  group('ChangeCoverNotifier', () {
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

    ChangeCoverState readState() =>
        container.read(changeCoverNotifierProvider);
    ChangeCoverNotifier readNotifier() =>
        container.read(changeCoverNotifierProvider.notifier);

    test('初始状态为空', () {
      final state = readState();
      expect(state.candidates, isEmpty);
      expect(state.isSearching, isFalse);
      expect(state.error, isNull);
    });

    test('searchCovers 解析真实契约返回（含尺寸缺省兜底）', () async {
      when(() => mockApi.searchCover(any())).thenAnswer((_) async => [
            {'url': 'https://a.com/1.jpg', 'width': 240, 'height': 320},
            {'url': 'https://a.com/2.jpg'},
          ]);

      await readNotifier().searchCovers(' chapter ');

      final state = readState();
      expect(state.isSearching, isFalse);
      expect(state.candidates.length, equals(2));
      expect(state.candidates.first.url, equals('https://a.com/1.jpg'));
      expect(state.candidates.first.width, equals(240));
      expect(state.candidates[1].width, isZero);
      verify(() => mockApi.searchCover('chapter')).called(1);
    });

    test('searchCovers 无候选返回空列表（非异常）', () async {
      when(() => mockApi.searchCover(any())).thenAnswer((_) async => []);

      await readNotifier().searchCovers('novel');

      final state = readState();
      expect(state.candidates, isEmpty);
      expect(state.isSearching, isFalse);
      expect(state.error, isNull);
    });

    test('searchCovers 异常时兜底并记录 error', () async {
      when(() => mockApi.searchCover(any())).thenThrow(Exception('网络错误'));

      await readNotifier().searchCovers('novel');

      final state = readState();
      expect(state.isSearching, isFalse);
      expect(state.candidates, isEmpty);
      expect(state.error, isNotNull);
    });

    test('searchCovers 空字符串被忽略（不触发契约）', () async {
      await readNotifier().searchCovers('   ');

      expect(readState().candidates, isEmpty);
      verifyNever(() => mockApi.searchCover(any()));
    });
  });
}
