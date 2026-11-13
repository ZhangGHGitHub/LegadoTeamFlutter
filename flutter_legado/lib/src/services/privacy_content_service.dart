// 私密内容数据服务（批9c / 审查 P2-3）
//
// 职责：缓存 Rust 侧私密标记（单本 URL / 分组 ID）与书架书籍快照，
// 为书架、详情、阅读记录、书签、缓存管理、搜索提示提供**同一套**判定：
// - 单本私密 ∪ 所属私密分组（复用 `bookBelongsToCustomGroup` 混合语义）；
// - 阅读记录/书签没有 bookUrl，按「书名 + 作者」反查书籍后判定；
// - [审查 P2-3] 反查索引额外并入 [PrivacyRecordAliasStore] 登记的改名历史
//   别名（旧书名+旧作者 → bookUrl）：私密书改名后旧记录仍能被识别并按
//   bookUrl 取回当前书籍，避免旧名明文显示与第三方搜索外发。
//
// **失败语义（fail-open）**：任一查询失败时该维度按「无标记」处理，
// 绝不让一次 IO 失败把整库书锁住。加载失败不抛异常，调用方拿到
// `loaded=true` 的空快照即可继续渲染。
//
// 编写：全栈工程师（批9c / 审查 P2-3） ｜ 2026-11-09 / 2026-11-13
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../providers/privacy/privacy_state.dart';
import '../utils/book_group_match.dart';
import 'book_api.dart';
import 'privacy_record_alias_store.dart';

/// 阅读记录 / 书签的身份键（这两类表没有 bookUrl）
@immutable
class PrivacyRecordKey {
  const PrivacyRecordKey(this.name, this.author);

  final String name;
  final String author;

  @override
  bool operator ==(Object other) =>
      other is PrivacyRecordKey && other.name == name && other.author == author;

  @override
  int get hashCode => Object.hash(name, author);

  @override
  String toString() => 'PrivacyRecordKey($name, $author)';
}

/// 私密标记快照（不可变）
@immutable
class PrivacyContentSnapshot {
  const PrivacyContentSnapshot({
    this.privateBookUrls = const <String>{},
    this.privateGroupIds = const <int>{},
    this.booksByUrl = const <String, Book>{},
    this.recordKeyCandidates = const <PrivacyRecordKey, List<Book>>{},
    this.groupsById = const <int, BookGroup>{},
    this.loaded = false,
    this.markersUnavailable = false,
  });

  /// 空快照（未加载 / 加载失败；一切按非私密处理）
  static const PrivacyContentSnapshot empty = PrivacyContentSnapshot();

  /// 单本私密 URL 集合
  final Set<String> privateBookUrls;

  /// 私密分组 ID 集合
  final Set<int> privateGroupIds;

  /// `bookUrl -> Book`（反查封面 / 分组位）
  final Map<String, Book> booksByUrl;

  /// 「书名 + 作者」-> 候选书籍（当前名 + [P2-3] 改名历史别名）
  ///
  /// 同一键可能对应多本书（旧名被新书复用、同名同作者跨源书）：
  /// 判定侧按「任一候选私密即锁定」fail-closed，取封面时优先私密候选。
  final Map<PrivacyRecordKey, List<Book>> recordKeyCandidates;

  /// `groupId -> BookGroup`（分组名等展示信息）
  final Map<int, BookGroup> groupsById;

  /// 是否已完成一次加载（失败也算完成，避免 UI 永久等待）
  final bool loaded;

  /// 私密标记读取是否失败（失败时按未锁定处理，UI 可提示“标记暂不可用”）
  final bool markersUnavailable;

  /// 分组是否私密
  bool isGroupPrivate(int groupId) => privateGroupIds.contains(groupId);

  /// 书籍是否属于任一私密分组（混合语义，不做裸位与）
  bool isBookInPrivateGroup(Book book) =>
      privateGroupIds.any((gid) => bookBelongsToCustomGroup(book, gid));

  /// 书籍是否为私密内容（单本标记 ∪ 私密分组）
  ///
  /// `book.isPrivate` 与 URL 快照取并集：列表接口可能滞后于刚写入的标记。
  bool isBookPrivate(Book book) =>
      book.isPrivate ||
      privateBookUrls.contains(book.bookUrl) ||
      isBookInPrivateGroup(book);

  /// 书籍此刻是否应脱敏（与详情/阅读闸门共用 [PrivacyState] 判定）
  bool isBookLocked(Book book, PrivacyState privacy) =>
      loaded && privacy.isBookLocked(book, isPrivate: isBookPrivate(book));

  /// 这批书里此刻应脱敏的 URL（列表页一次算好，避免逐条重复判定）
  Set<String> lockedBookUrls(Iterable<Book> books, PrivacyState privacy) {
    if (!loaded || !privacy.enabled || !privacy.verifyOnOpenBook) {
      return const <String>{};
    }
    return {
      for (final book in books)
        if (isBookLocked(book, privacy)) book.bookUrl,
    };
  }

  /// 按「书名 + 作者」反查书籍（先精确匹配；作者为空时仅在同名唯一时命中）
  ///
  /// 反查不到返回 null，调用方按「与私密无关」处理（fail-open），
  /// 避免同名误伤或整表脱敏。精确键命中多本候选时优先返回私密书，
  /// 供锁定行取真实封面（判定仍由 [isRecordLocked] 逐候选执行）。
  Book? findBookByNameAuthor(String name, String author) {
    if (name.trim().isEmpty) return null;
    final exact = recordKeyCandidates[PrivacyRecordKey(name, author)];
    if (exact != null && exact.isNotEmpty) {
      return _preferPrivateCandidate(exact);
    }
    if (author.trim().isNotEmpty) return null;
    final sameName = _sameNameCandidates(name);
    if (sameName.length != 1) return null; // 同名多本：无法确定，按非私密处理
    return sameName.first;
  }

  /// 阅读记录 / 书签是否应脱敏
  ///
  /// 作者列在 v113 写路径中常为空（`readRecord.upsert` 只在已存在行保留
  /// 作者），此时按同名全部候选判定：任一候选私密且未授权即锁定
  /// （fail-closed，优先保证旧名不泄漏）。
  bool isRecordLocked(PrivacyRecordKey key, PrivacyState privacy) {
    if (!loaded || !privacy.enabled || !privacy.verifyOnOpenBook) return false;
    final candidates = _lockCandidates(key);
    if (candidates.isEmpty) return false;
    return candidates.any(
      (book) => privacy.isBookLocked(book, isPrivate: isBookPrivate(book)),
    );
  }

  /// 锁定判定候选：作者非空取精确键；作者为空取同名全部候选
  List<Book> _lockCandidates(PrivacyRecordKey key) {
    if (key.author.trim().isNotEmpty) {
      return _withoutDuplicates(recordKeyCandidates[key]);
    }
    return _sameNameCandidates(key.name);
  }

  /// 同名（忽略作者）的全部候选，按 bookUrl 去重
  List<Book> _sameNameCandidates(String name) {
    final out = <Book>[];
    for (final entry in recordKeyCandidates.entries) {
      if (entry.key.name != name) continue;
      for (final book in entry.value) {
        if (out.every((b) => b.bookUrl != book.bookUrl)) out.add(book);
      }
    }
    return out;
  }

  /// 候选列表按 bookUrl 去重（保持顺序）
  static List<Book> _withoutDuplicates(Iterable<Book>? books) {
    if (books == null || books.isEmpty) return const <Book>[];
    final out = <Book>[];
    for (final book in books) {
      if (out.every((b) => b.bookUrl != book.bookUrl)) out.add(book);
    }
    return out;
  }

  /// 精确键多候选时优先私密书（锁定行封面取真实书籍图）
  Book _preferPrivateCandidate(List<Book> candidates) {
    for (final book in candidates) {
      if (isBookPrivate(book)) return book;
    }
    return candidates.first;
  }
}

/// 私密内容加载服务（无状态；缓存由 Provider 持有快照）
class PrivacyContentService {
  PrivacyContentService({
    required BookApi api,
    PrivacyRecordAliasStore aliasStore = const PrivacyRecordAliasStore(),
  }) : _api = api,
       _aliasStore = aliasStore;

  final BookApi _api;

  /// [P2-3] 改名别名来源（旧书名+旧作者 → bookUrl）
  final PrivacyRecordAliasStore _aliasStore;

  /// 加载全部私密标记与反查所需的书籍/分组快照
  ///
  /// 各查询独立兜底：单个失败只清空该维度并记录日志，不抛出、不影响
  /// 其它维度（fail-open，避免误锁全库）。
  ///
  /// [P2-3] 无任何私密标记但存在改名别名时，仍需拉取书架书籍：别名把
  /// 旧记录锚回当前书籍后，阅读记录页才能显示改名后的书名（不锁定）。
  Future<PrivacyContentSnapshot> load() async {
    Set<String> privateBookUrls = const <String>{};
    Set<int> privateGroupIds = const <int>{};
    List<Book> books = const <Book>[];
    List<BookGroup> groups = const <BookGroup>[];
    List<PrivacyRecordAlias> aliases = const <PrivacyRecordAlias>[];
    var markersUnavailable = false;

    try {
      privateBookUrls = (await _api.getPrivateBookUrls()).toSet();
    } catch (e) {
      markersUnavailable = true;
      debugPrint('[隐私] 读取私密书籍标记失败（按无标记处理）：$e');
    }
    try {
      privateGroupIds = (await _api.getPrivateGroupIds()).toSet();
    } catch (e) {
      markersUnavailable = true;
      debugPrint('[隐私] 读取私密分组标记失败（按无标记处理）：$e');
    }
    aliases = await _aliasStore.load();

    final hasMarkers = privateBookUrls.isNotEmpty || privateGroupIds.isNotEmpty;
    // 无任何私密标记且无改名历史（绝大多数用户）：不必再拉全量书籍/分组
    // 做反查，既省一次 IO，也避免只读场景无谓的数据往返。
    if (!hasMarkers && aliases.isEmpty) {
      return PrivacyContentSnapshot(
        loaded: true,
        markersUnavailable: markersUnavailable,
      );
    }
    try {
      books = await _api.getBooks();
    } catch (e) {
      debugPrint('[隐私] 读取书籍列表失败（记录反查不可用）：$e');
    }
    if (hasMarkers) {
      try {
        groups = await _api.getBookGroups();
      } catch (e) {
        debugPrint('[隐私] 读取分组列表失败（分组信息不可用）：$e');
      }
    }

    final booksByUrl = <String, Book>{
      for (final book in books) book.bookUrl: book,
    };
    final recordKeyCandidates = <PrivacyRecordKey, List<Book>>{};
    void addCandidate(String name, String author, Book book) {
      if (name.trim().isEmpty) return;
      final list = recordKeyCandidates.putIfAbsent(
        PrivacyRecordKey(name, author),
        () => <Book>[],
      );
      if (list.every((b) => b.bookUrl != book.bookUrl)) list.add(book);
    }

    // 当前「书名+作者」优先入索引（与改名别名同键时同书去重）
    for (final book in books) {
      addCandidate(book.name, book.author, book);
    }
    // [P2-3] 改名历史别名：按 bookUrl 找回当前书籍，旧记录键即可命中
    for (final alias in aliases) {
      final book = booksByUrl[alias.bookUrl];
      if (book == null) continue; // 书已删除：无当前书籍可锚定
      addCandidate(alias.name, alias.author, book);
    }
    final groupsById = <int, BookGroup>{
      for (final group in groups) group.groupId: group,
    };

    return PrivacyContentSnapshot(
      privateBookUrls: privateBookUrls,
      privateGroupIds: privateGroupIds,
      booksByUrl: booksByUrl,
      recordKeyCandidates: recordKeyCandidates,
      groupsById: groupsById,
      loaded: true,
      markersUnavailable: markersUnavailable,
    );
  }
}
