// 隐私批量/脱敏测试用 BookApi 替身（批9c）
//
// 在 MockBookApi 基础上用显式内存列表驱动书架/私密标记/阅读记录/书签，
// 避免样例资产惰性加载干扰测试时序。只覆写测试实际用到的只读/标记方法，
// 密码生命周期继续复用 MockBookApi（加盐 SHA-256 模拟）。
library;

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';

class PrivacyMockBookApi extends MockBookApi {
  PrivacyMockBookApi({
    List<Book> books = const [],
    List<BookGroup> groups = const [],
    List<ReadRecord> readRecords = const [],
    List<Bookmark> bookmarks = const [],
  }) : books = List<Book>.of(books),
       groups = List<BookGroup>.of(groups),
       readRecords = List<ReadRecord>.of(readRecords),
       bookmarks = List<Bookmark>.of(bookmarks);

  final List<Book> books;
  final List<BookGroup> groups;
  final List<ReadRecord> readRecords;
  final List<Bookmark> bookmarks;

  /// 记录 setBooksPrivate / setBookGroupPrivate 调用（链路断言）
  final List<({List<String> bookUrls, bool isPrivate})> setBooksPrivateCalls =
      [];
  final List<({int groupId, bool isPrivate})> setBookGroupPrivateCalls = [];

  /// 覆盖 setBooksPrivate 返回的更新行数（toast 用实际返回值测试）
  int? forcedSetBooksPrivateCount;

  /// 单本标记覆盖（即使 URL 不在 books 列表也能被隐私服务识别）
  final Set<String> privateUrlOverrides = <String>{};

  int addBookCalls = 0;
  int deleteReadRecordCalls = 0;
  int deleteBookmarkCalls = 0;
  bool failDeleteReadRecord = false;
  bool failDeleteBookmark = false;

  @override
  Future<List<Book>> getBooks() async => List<Book>.of(books);

  @override
  Future<Book?> getBook(String bookUrl) async {
    for (final book in books) {
      if (book.bookUrl == bookUrl) return book;
    }
    return null;
  }

  @override
  Future<Book> addBook(Book book) async {
    addBookCalls++;
    if (!books.any((b) => b.bookUrl == book.bookUrl)) books.add(book);
    return book;
  }

  @override
  Future<List<BookGroup>> getBookGroups() async => List<BookGroup>.of(groups);

  @override
  Future<List<String>> getPrivateBookUrls() async => {
    for (final b in books)
      if (b.isPrivate) b.bookUrl,
    ...privateUrlOverrides,
  }.toList();

  @override
  Future<List<int>> getPrivateGroupIds() async => [
    for (final g in groups)
      if (g.isPrivate) g.groupId,
  ];

  @override
  Future<int> setBooksPrivate(List<String> bookUrls, bool isPrivate) async {
    setBooksPrivateCalls.add((
      bookUrls: List.of(bookUrls),
      isPrivate: isPrivate,
    ));
    var updated = 0;
    for (var i = 0; i < books.length; i++) {
      if (!bookUrls.contains(books[i].bookUrl)) continue;
      books[i] = books[i].copyWith(isPrivate: isPrivate);
      updated++;
    }
    if (isPrivate) {
      privateUrlOverrides.addAll(bookUrls);
    } else {
      privateUrlOverrides.removeAll(bookUrls);
    }
    return forcedSetBooksPrivateCount ?? updated;
  }

  @override
  Future<bool> setBookGroupPrivate(int groupId, bool isPrivate) async {
    setBookGroupPrivateCalls.add((groupId: groupId, isPrivate: isPrivate));
    final idx = groups.indexWhere((g) => g.groupId == groupId);
    if (idx < 0) return false;
    groups[idx] = groups[idx].copyWith(isPrivate: isPrivate);
    return true;
  }

  @override
  Future<BookGroup> addBookGroup(BookGroup group) async {
    var id = 1;
    while (groups.any((g) => g.groupId == id)) {
      id <<= 1;
    }
    final created = group.copyWith(groupId: id, isPrivate: false);
    groups.add(created);
    return created;
  }

  @override
  Future<void> updateBookGroup(BookGroup group) async {
    final idx = groups.indexWhere((g) => g.groupId == group.groupId);
    if (idx >= 0) {
      // 与 Rust 语义一致：私密位保留库内旧值
      groups[idx] = group.copyWith(isPrivate: groups[idx].isPrivate);
    }
  }

  @override
  Future<List<BookChapter>> getChapters(String bookUrl) async => const [];

  @override
  Future<List<BookSource>> getBookSources() async => const [];

  @override
  Future<List<ReadRecord>> getReadRecords() async =>
      List<ReadRecord>.of(readRecords);

  @override
  Future<List<Map<String, dynamic>>> readRecordDailyList(int year) async =>
      const [];

  @override
  Future<void> deleteReadRecord(String bookName) async {
    deleteReadRecordCalls++;
    if (failDeleteReadRecord) throw StateError('删除阅读记录失败');
    readRecords.removeWhere((r) => r.bookName == bookName);
  }

  @override
  Future<List<Bookmark>> getAllBookmarks() async =>
      List<Bookmark>.of(bookmarks);

  @override
  Future<void> deleteBookmark(int id) async {
    deleteBookmarkCalls++;
    if (failDeleteBookmark) throw StateError('删除书签失败');
    bookmarks.removeWhere((b) => b.id == id);
  }

  @override
  Future<String> cacheDownloadList() async => '[]';

  @override
  Future<List<String>> listCachedChapterUrls(String bookUrl) async => const [];

  @override
  Future<List<SearchKeyword>> getSearchHistory({int limit = 50}) async =>
      const [];

  @override
  Future<List<String>> searchHistoryByPrefix(
    String prefix, {
    int limit = 20,
  }) async => const [];

  @override
  Future<List<BookSource>> getEnabledBookSources() async => const [];

  @override
  Future<String?> getConfig(String key) async => null;

  @override
  Future<void> setConfig(String key, String value) async {}

  @override
  Future<Map<String, dynamic>> sourceCallBackBtn({
    required String event,
    required String bookUrl,
    int? chapterIndex,
    int bookType = 0,
    String? result,
  }) async => const {'invoked': false, 'jsTrue': false, 'actions': <dynamic>[]};
}
