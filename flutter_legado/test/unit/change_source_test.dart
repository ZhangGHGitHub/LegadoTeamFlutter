import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/change_source/change_source_notifier.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/mocks.dart';

void main() {
  group('SourceMatch model', () {
    test('fromJson 解析 Rust SourceMatch 的 snake_case 字段', () {
      final json = {
        'source_url': 'https://source.example.com',
        'source_name': '笔趣阁',
        'book_url': 'https://source.example.com/book/1',
        'book_name': '斗破苍穹',
        'author': '天蚕土豆',
        'latest_chapter': '第一千六百章 大结局',
        'word_count': '530万字',
        'score': 87.5,
      };

      final item = SourceMatch.fromJson(json);

      expect(item.sourceUrl, equals('https://source.example.com'));
      expect(item.sourceName, equals('笔趣阁'));
      expect(item.bookUrl, equals('https://source.example.com/book/1'));
      expect(item.bookName, equals('斗破苍穹'));
      expect(item.author, equals('天蚕土豆'));
      expect(item.latestChapter, equals('第一千六百章 大结局'));
      expect(item.wordCount, equals('530万字'));
      expect(item.score, equals(87.5));
    });

    test('fromJson 可选字段缺失时为 null，score 默认 0', () {
      final item = SourceMatch.fromJson({
        'source_url': 'https://a.com',
        'source_name': 'A源',
        'book_url': 'https://a.com/b',
        'book_name': '测试',
        'author': '',
      });

      expect(item.latestChapter, isNull);
      expect(item.wordCount, isNull);
      expect(item.score, equals(0.0));
    });

    test('fromJson score 为整数时正确转为 double', () {
      final item = SourceMatch.fromJson({
        'source_url': 'https://a.com',
        'source_name': 'A源',
        'book_url': 'https://a.com/b',
        'book_name': '测试',
        'author': '',
        'score': 95,
      });

      expect(item.score, equals(95.0));
    });

    test('fromJson 空 map 使用默认值', () {
      final item = SourceMatch.fromJson({});
      expect(item.sourceUrl, equals(''));
      expect(item.sourceName, equals(''));
      expect(item.bookUrl, equals(''));
      expect(item.score, equals(0.0));
    });
  });

  group('ChangeSourceNotifier', () {
    late MockRustApi mockApi;
    late ProviderContainer container;

    setUpAll(() {
      registerFallbacks();
    });

    setUp(() {
      mockApi = MockRustApi();
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
      );
      addTearDown(container.dispose);
    });

    ChangeSourceState readState() =>
        container.read(changeSourceNotifierProvider);
    ChangeSourceNotifier readNotifier() =>
        container.read(changeSourceNotifierProvider.notifier);

    /// 构造一条候选结果 Map（snake_case，对齐 Rust SourceMatch）
    Map<String, dynamic> rawMatch(String url, String name, double score) => {
          'source_url': url,
          'source_name': name,
          'book_url': '$url/book',
          'book_name': '斗破苍穹',
          'author': '天蚕土豆',
          'score': score,
        };

    test('初始状态为空', () {
      final state = readState();
      expect(state.results, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.applyingUrl, isNull);
      expect(state.hasResults, isFalse);
      expect(state.isApplying, isFalse);
    });

    test('search 经 BookApi.searchSource 解析为 SourceMatch 列表', () async {
      when(() => mockApi.searchSource(any(), any())).thenAnswer((_) async => [
            rawMatch('https://a.com', 'A源', 90),
            rawMatch('https://b.com', 'B源', 70),
          ]);

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.results.length, equals(2));
      expect(state.results.first.sourceUrl, equals('https://a.com'));
      expect(state.results.first.sourceName, equals('A源'));
      expect(state.results.first.score, equals(90));
      verify(() => mockApi.searchSource('斗破苍穹', '天蚕土豆')).called(1);
    });

    test('search 保持 Rust 返回顺序（不在 Dart 侧重排）', () async {
      // Rust 已按评分降序；此处故意返回升序，验证 Notifier 不重排
      when(() => mockApi.searchSource(any(), any())).thenAnswer((_) async => [
            rawMatch('https://low.com', '低分源', 30),
            rawMatch('https://high.com', '高分源', 95),
          ]);

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      expect(readState().results.first.sourceUrl, equals('https://low.com'));
      expect(readState().results.last.sourceUrl, equals('https://high.com'));
    });

    test('search 异常时记录 error 并清除加载态', () async {
      when(() => mockApi.searchSource(any(), any()))
          .thenThrow(Exception('网络错误'));

      await readNotifier().search('斗破苍穹', '天蚕土豆');

      final state = readState();
      expect(state.isLoading, isFalse);
      expect(state.error, contains('网络错误'));
      expect(state.results, isEmpty);
    });

    test('search 进行中时重复调用被忽略', () async {
      var callCount = 0;
      when(() => mockApi.searchSource(any(), any())).thenAnswer((_) async {
        callCount++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return [rawMatch('https://a.com', 'A源', 90)];
      });

      final f1 = readNotifier().search('斗破苍穹', '天蚕土豆');
      final f2 = readNotifier().search('斗破苍穹', '天蚕土豆');
      await Future.wait([f1, f2]);

      expect(callCount, equals(1));
    });

    test('applySource 经 BookApi.switchSource 回写并返回新 bookUrl', () async {
      when(() => mockApi.switchSource(any(), any(), any())).thenAnswer(
        (_) async => '{"bookUrl":"https://new.com/book/1"}',
      );
      const match = SourceMatch(
        sourceUrl: 'https://new.com',
        sourceName: '新源',
        bookUrl: 'https://new.com/fallback',
      );

      final newUrl = await readNotifier().applySource(
        match,
        bookUrl: 'https://old.com/book',
      );

      expect(newUrl, equals('https://new.com/book/1'));
      expect(readState().applyingUrl, isNull);
      verify(() => mockApi.switchSource(
            'https://old.com/book',
            'https://new.com',
            'https://new.com/fallback',
          )).called(1);
    });

    test('applySource 返回 JSON 无 bookUrl 时回退到候选项 bookUrl', () async {
      when(() => mockApi.switchSource(any(), any(), any()))
          .thenAnswer((_) async => '{}');
      const match = SourceMatch(
        sourceUrl: 'https://new.com',
        sourceName: '新源',
        bookUrl: 'https://new.com/fallback',
      );

      final newUrl = await readNotifier().applySource(
        match,
        bookUrl: 'https://old.com/book',
      );

      expect(newUrl, equals('https://new.com/fallback'));
    });

    test('applySource 异常时清除 applyingUrl 并重新抛出', () async {
      when(() => mockApi.switchSource(any(), any(), any()))
          .thenThrow(Exception('切换失败'));
      const match = SourceMatch(sourceUrl: 'https://new.com');

      await expectLater(
        readNotifier().applySource(match, bookUrl: 'https://old.com/book'),
        throwsA(isA<Exception>()),
      );
      expect(readState().applyingUrl, isNull);
      expect(readState().isApplying, isFalse);
    });

    test('applySource 进行中时再次调用抛出 StateError', () async {
      when(() => mockApi.switchSource(any(), any(), any())).thenAnswer(
        (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return '{}';
        },
      );
      const match = SourceMatch(sourceUrl: 'https://new.com');

      final f1 = readNotifier().applySource(match, bookUrl: 'https://old.com');
      // 等待第一次调用进入 applying 状态
      await Future<void>.delayed(Duration.zero);
      expect(readState().isApplying, isTrue);

      expect(
        () => readNotifier().applySource(match, bookUrl: 'https://old.com'),
        throwsA(isA<StateError>()),
      );
      await f1;
    });
  });
}
