// 书架内搜索过滤（搜索直达）派生过滤单测
//
// 对齐参考版 BookshelfViewModel.matchesSearchKey：书名/作者/来源名/分类/
// 自定义标签任一包含关键词即命中（大小写不敏感）；过滤态可先剔除私密
// 未授权书（避免「能否搜到书名」泄露私密内容）。
//
// [审查回修] 追加批量选择/删除误删防护：过滤态全选只选可见书、关键词
// 变化清空已选、删除只提交「可见 ∩ 已选」。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_content_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/book_api.dart'
    show DeleteBooksResult;
import 'package:flutter_legado/src/services/privacy_content_service.dart';

import '../mocks/mocks.dart';

/// 隐私开关已启用（enabled + verifyOnOpenBook）的假状态
class _FakePrivacyNotifier extends PrivacyNotifier {
  @override
  PrivacyState build() =>
      const PrivacyState(enabled: true, hasPassword: true, loaded: true);
}

/// 固定私密 URL 快照的假内容 notifier
class _FakePrivacyContentNotifier extends PrivacyContentNotifier {
  _FakePrivacyContentNotifier(this.privateUrls);

  final Set<String> privateUrls;

  @override
  PrivacyContentSnapshot build() =>
      PrivacyContentSnapshot(loaded: true, privateBookUrls: privateUrls);

  @override
  Future<PrivacyContentSnapshot> ensureLoaded() async => state;
}

void main() {
  setUpAll(() {
    registerFallbacks();
    registerFallbackValue(<String>[]);
  });

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  BookshelfState shelf(
    List<Book> books, {
    bool filterMode = true,
    String q = '',
  }) {
    return BookshelfState(
      books: books,
      groups: const [
        BookGroup(groupId: BookGroupId.all, groupName: '全部', order: -10),
      ],
      selectedGroupIndex: 0,
      isFilterMode: filterMode,
      filterQuery: q,
    );
  }

  const books = [
    Book(bookUrl: 'u1', name: '斗破苍穹', author: '天蚕土豆', originName: '起点'),
    Book(bookUrl: 'u2', name: 'Perfect World', author: '辰东', kind: '玄幻'),
    Book(bookUrl: 'u3', name: '遮天', author: '辰东', customTag: '已读'),
  ];

  test('未开过滤或关键词为空：原样返回全部书籍', () {
    expect(shelf(books, filterMode: false, q: '斗破').filterBooks(books), books);
    expect(shelf(books, q: '   ').filterBooks(books), books);
    expect(shelf(books, filterMode: false, q: '遮天').isFiltering, isFalse);
  });

  test('匹配书名（大小写不敏感）', () {
    final state = shelf(books, q: '斗破');
    expect(state.isFiltering, isTrue);
    expect(state.filterBooks(books).map((b) => b.bookUrl), ['u1']);

    // 英文书名忽略大小写
    expect(
      shelf(books, q: 'perfect').filterBooks(books).map((b) => b.bookUrl),
      ['u2'],
    );
  });

  test('匹配作者', () {
    final result = shelf(books, q: '辰东').filterBooks(books);
    expect(result.map((b) => b.bookUrl), ['u2', 'u3']);
  });

  test('匹配来源名/分类/自定义标签（对齐参考版五字段口径）', () {
    expect(shelf(books, q: '起点').filterBooks(books).single.bookUrl, 'u1');
    expect(shelf(books, q: '玄幻').filterBooks(books).single.bookUrl, 'u2');
    expect(shelf(books, q: '已读').filterBooks(books).single.bookUrl, 'u3');
  });

  test('无匹配返回空列表（UI 据此呈现空态）', () {
    expect(shelf(books, q: '不存在的书').filterBooks(books), isEmpty);
  });

  test('清除关键词/退出过滤后恢复全部', () {
    final filtered = shelf(books, q: '遮天');
    expect(filtered.filterBooks(books), hasLength(1));
    // 清除关键词（过滤模式仍开）→ 恢复
    final cleared = filtered.copyWith(filterQuery: '');
    expect(cleared.filterBooks(books), books);
    // 退出过滤模式 → filterQuery 语义上不再生效
    final exited = filtered.copyWith(isFilterMode: false, filterQuery: '');
    expect(exited.filterBooks(books), books);
  });

  test('exclude 回调先剔除私密未授权书（命中关键词也不返回）', () {
    final state = shelf(books, q: '辰东');
    final result = state.filterBooks(
      books,
      exclude: (book) => book.bookUrl == 'u3',
    );
    expect(result.map((b) => b.bookUrl), ['u2']);
  });

  group('批量选择/删除误删防护（过滤态 + 隐私集成）', () {
    const publicBook = Book(bookUrl: 'u1', name: '公开书', author: '作者');
    const privateBook = Book(bookUrl: 'u2', name: '私密书', author: '作者');
    late MockRustApi api;
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      api = MockRustApi();
      when(
        () => api.getBooks(),
      ).thenAnswer((_) async => const [publicBook, privateBook]);
      when(() => api.getBookGroups()).thenAnswer((_) async => const []);
      when(() => api.deleteBooks(any(), deleteOriginal: false)).thenAnswer(
        (_) async => const DeleteBooksResult(deleted: 1, missing: 0),
      );
      container = ProviderContainer(
        overrides: [
          bookApiProvider.overrideWithValue(api),
          privacyNotifierProvider.overrideWith(_FakePrivacyNotifier.new),
          privacyContentProvider.overrideWith(
            () => _FakePrivacyContentNotifier({'u2'}),
          ),
        ],
      );
      addTearDown(container.dispose);
      // 触发 build() 内的微任务加载（书籍/分组/私密标记）
      container.read(bookshelfNotifierProvider);
      await settle();
    });

    test('过滤态全选排除私密未授权书；删除只提交可见交集', () async {
      final notifier = container.read(bookshelfNotifierProvider.notifier);
      notifier.setFilterMode(true);
      notifier.setFilterQuery('书');
      await settle();

      final loaded = container.read(bookshelfNotifierProvider);
      expect(loaded.privateBookUrls, contains('u2'), reason: '隐私快照已接入');
      expect(
        notifier.visibleGroupBooks().map((b) => b.bookUrl),
        ['u1'],
        reason: '私密未授权书不得出现在可见集合',
      );

      notifier.selectAll();
      expect(container.read(bookshelfNotifierProvider).selectedUrls, {'u1'});

      // 模拟修复前全选遗留的屏外隐藏选中项
      notifier.toggleSelect('u2');
      expect(container.read(bookshelfNotifierProvider).selectedUrls, {
        'u1',
        'u2',
      });
      expect(notifier.visibleSelectedUrls, {'u1'});

      final result = await notifier.deleteSelectedBooks();
      expect(result.deleted, 1);
      final captured = verify(
        () => api.deleteBooks(captureAny(), deleteOriginal: false),
      ).captured;
      expect(captured.single, ['u1'], reason: '屏外私密书不得进入删除请求');
      expect(container.read(bookshelfNotifierProvider).selectedUrls, isEmpty);
    });

    test('关键词变化立即清空已选；退出过滤同样清空', () async {
      final notifier = container.read(bookshelfNotifierProvider.notifier);
      notifier.setFilterMode(true);
      notifier.setFilterQuery('公开');
      await settle();
      notifier.selectAll();
      expect(container.read(bookshelfNotifierProvider).selectedUrls, {'u1'});

      notifier.setFilterQuery('私密');
      expect(
        container.read(bookshelfNotifierProvider).selectedUrls,
        isEmpty,
        reason: '可见集合变化后旧选中不得保留',
      );

      notifier.selectAll(); // 仅剩私密未授权书 → 可见集合为空
      expect(container.read(bookshelfNotifierProvider).selectedUrls, isEmpty);

      notifier.toggleSelect('u2');
      notifier.setFilterMode(false);
      expect(container.read(bookshelfNotifierProvider).selectedUrls, isEmpty);
    });
  });
}
