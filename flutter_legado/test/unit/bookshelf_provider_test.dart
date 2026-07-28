import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_legado/src/providers/bookshelf_provider.dart';
import 'package:flutter_legado/src/services/rust_api.dart';

void main() {
  late BookshelfProvider provider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = BookshelfProvider(RustApi());
  });

  group('BookshelfProvider 初始状态', () {
    test('初始书架为空', () {
      expect(provider.books, isEmpty);
      expect(provider.isEmpty, isTrue);
      expect(provider.loading, isFalse);
      expect(provider.error, isNull);
    });

    test('初始视图模式为网格', () {
      expect(provider.isGridView, isTrue);
    });

    test('初始分组模式为 none', () {
      expect(provider.groupMode, equals(GroupMode.none));
    });

    test('初始显示最近阅读和统计', () {
      expect(provider.showRecentReading, isTrue);
      expect(provider.showStats, isTrue);
    });
  });

  group('BookshelfProvider 视图切换', () {
    test('toggleViewMode 切换为列表视图', () {
      provider.toggleViewMode();
      expect(provider.isGridView, isFalse);
    });

    test('toggleViewMode 再次切换回网格视图', () {
      provider.toggleViewMode();
      provider.toggleViewMode();
      expect(provider.isGridView, isTrue);
    });

    test('toggleViewMode 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.toggleViewMode();
      expect(notified, isTrue);
    });
  });

  group('BookshelfProvider 分组模式', () {
    test('setGroupMode 切换到 bySource', () {
      provider.setGroupMode(GroupMode.bySource);
      expect(provider.groupMode, equals(GroupMode.bySource));
    });

    test('setGroupMode 切换到 byGroup', () {
      provider.setGroupMode(GroupMode.byGroup);
      expect(provider.groupMode, equals(GroupMode.byGroup));
    });

    test('setGroupMode 切换回 none', () {
      provider.setGroupMode(GroupMode.bySource);
      provider.setGroupMode(GroupMode.none);
      expect(provider.groupMode, equals(GroupMode.none));
    });

    test('setGroupMode 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.setGroupMode(GroupMode.byGroup);
      expect(notified, isTrue);
    });

    test('空书架时 groupedBooks 返回全部键', () {
      final grouped = provider.groupedBooks;
      expect(grouped.containsKey('全部'), isTrue);
      expect(grouped['全部'], isEmpty);
    });
  });

  group('BookshelfProvider 错误管理', () {
    test('clearError 清除错误状态', () {
      // error 初始为 null，clearError 不应抛异常
      provider.clearError();
      expect(provider.error, isNull);
    });

    test('clearError 触发通知', () {
      var notified = false;
      provider.addListener(() => notified = true);
      provider.clearError();
      expect(notified, isTrue);
    });
  });

  group('BookshelfProvider reorderBook 边界检查', () {
    test('空书架时 reorderBook 不抛异常', () {
      // oldIndex 越界，应直接返回
      provider.reorderBook(0, 1);
      expect(provider.books, isEmpty);
    });

    test('负索引 reorderBook 不抛异常', () {
      provider.reorderBook(-1, 0);
      expect(provider.books, isEmpty);
    });
  });
}
