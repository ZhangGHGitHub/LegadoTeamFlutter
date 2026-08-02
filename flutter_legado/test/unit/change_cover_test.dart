import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/change_cover/change_cover_notifier.dart';

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
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
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

    test('searchCovers 生成确定性候选（含尺寸）', () async {
      await readNotifier().searchCovers(' chapter ');

      final state = readState();
      expect(state.isSearching, isFalse);
      expect(state.candidates.length, equals(8));
      expect(state.candidates.first.width, equals(240));
      expect(state.candidates.first.height, equals(320));
      expect(state.candidates.first.url, contains('picsum.photos'));
    });

    test('searchCovers 同书名结果确定（可复现）', () async {
      await readNotifier().searchCovers('novel');
      final first = readState().candidates.map((e) => e.url).toList();

      // 新建容器重查，结果一致
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      await container2
          .read(changeCoverNotifierProvider.notifier)
          .searchCovers('novel');
      final second = container2
          .read(changeCoverNotifierProvider)
          .candidates
          .map((e) => e.url)
          .toList();

      expect(second, equals(first));
    });

    test('searchCovers 空字符串被忽略（状态不变）', () async {
      await readNotifier().searchCovers('');

      final state = readState();
      expect(state.candidates, isEmpty);
      expect(state.isSearching, isFalse);
    });

    test('searchCovers 纯空白被忽略', () async {
      await readNotifier().searchCovers('   ');
      expect(readState().candidates, isEmpty);
    });
  });
}
