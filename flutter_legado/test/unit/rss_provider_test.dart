import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_legado/src/providers/rss_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  late RssProvider provider;

  setUp(() {
    provider = RssProvider(RustApi());
  });

  group('RssProvider 初始状态', () {
    test('初始源列表为空', () {
      expect(provider.sources, isEmpty);
      expect(provider.isEmpty, isTrue);
    });

    test('初始文章列表为空', () {
      expect(provider.articles, isEmpty);
    });

    test('初始无选中源', () {
      expect(provider.selectedSource, isNull);
    });

    test('初始非加载状态', () {
      expect(provider.isLoadingSources, isFalse);
      expect(provider.isLoadingArticles, isFalse);
      expect(provider.isLoading, isFalse);
    });

    test('初始无错误', () {
      expect(provider.error, isNull);
    });
  });

  group('RssProvider 状态管理', () {
    test('clearSelectedSource 清除选中源和文章', () {
      provider.clearSelectedSource();
      expect(provider.selectedSource, isNull);
      expect(provider.articles, isEmpty);
    });

    test('clearSelectedSource 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearSelectedSource();
      expect(notified, isTrue);
    });

    test('clearError 清除错误', () {
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('clearError 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearError();
      expect(notified, isTrue);
    });

    test('isLoading 是 sources 或 articles 加载的或', () {
      // 初始两者都 false
      expect(provider.isLoading, isFalse);
    });
  });

  group('RssProvider 文章列表操作', () {
    test('refreshArticles 在无选中源时不抛异常', () async {
      // 无选中源时应直接返回
      await provider.refreshArticles();
      expect(provider.articles, isEmpty);
      expect(provider.selectedSource, isNull);
    });

    test('多次 clearSelectedSource 不抛异常', () {
      provider.clearSelectedSource();
      provider.clearSelectedSource();
      expect(provider.selectedSource, isNull);
      expect(provider.articles, isEmpty);
    });
  });
}
