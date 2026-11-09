/// 书架私密派生过滤测试（批9c）
///
/// 覆盖：私密分组书从「全部/本地/音频/视频/未关联」与公开分组计数剔除；
/// 私密分组自身 Tab 保留书籍（内容区由 UI 锁定）；单本私密仍留在公开书架；
/// 旧时间戳 ID 兼容；单个/分组授权的锁定判定。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/bookshelf/bookshelf_state.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';

const _privateGroup = BookGroup(
  groupId: 4,
  groupName: '私密组',
  isPrivate: true,
  order: 0,
);
const _publicGroup = BookGroup(groupId: 8, groupName: '公开组', order: 1);
const _allGroup = BookGroup(groupId: BookGroupId.all, groupName: '全部');
const _audioGroup = BookGroup(groupId: BookGroupId.audio, groupName: '音频');
const _netNoneGroup = BookGroup(groupId: BookGroupId.netNone, groupName: '未分组');

Book _book({
  required String url,
  String name = '书',
  int group = 0,
  int type = 0,
  bool isPrivate = false,
  String origin = '',
}) => Book(
  bookUrl: url,
  name: name,
  author: '作者',
  group: group,
  bookType: type,
  isPrivate: isPrivate,
  origin: origin,
);

BookshelfState _state(List<Book> books) => BookshelfState(
  books: books,
  groups: const [_allGroup, _privateGroup, _publicGroup],
  privateBookUrls: {
    for (final b in books)
      if (b.isPrivate) b.bookUrl,
  },
  privateGroupIds: const {4},
  privacyLoaded: true,
);

PrivacyState _privacy({
  Set<String> grantedBookUrls = const {},
  Set<int> grantedGroupIds = const {},
  bool enabled = true,
  bool verifyOnOpenBook = true,
  bool verifyOnEnterGroup = true,
}) => PrivacyState(
  enabled: enabled,
  hasPassword: true,
  verifyOnOpenBook: verifyOnOpenBook,
  verifyOnEnterGroup: verifyOnEnterGroup,
  grantedBookUrls: grantedBookUrls,
  grantedGroupIds: grantedGroupIds,
  loaded: true,
);

void main() {
  final privateGroupBook = _book(url: 'u1', name: '组内私密', group: 4);
  final singlePrivateBook = _book(url: 'u2', name: '单本私密', isPrivate: true);
  final publicBook = _book(url: 'u3', name: '公开书');
  final audioPrivateBook = _book(
    url: 'u4',
    name: '音频私密',
    group: 4,
    type: BookType.audio,
  );
  final legacyGroupBook = _book(url: 'u5', name: '旧组书', group: 1700000000000);
  final books = [
    privateGroupBook,
    singlePrivateBook,
    publicBook,
    audioPrivateBook,
    legacyGroupBook,
  ];

  test('「全部」剔除私密分组书，保留单本私密（卡片锁定）', () {
    final state = _state(books);
    final all = state.booksInGroup(_allGroup);
    expect(all.map((b) => b.bookUrl), isNot(contains('u1')));
    expect(all.map((b) => b.bookUrl), isNot(contains('u4')));
    expect(all.map((b) => b.bookUrl), contains('u2'));
    expect(
      all.map((b) => b.bookUrl),
      contains('u5'),
      reason: '旧时间戳组书不属于私密组，仍应显示',
    );
  });

  test('特殊分组（音频/未关联）过滤私密分组书', () {
    final state = _state(books);
    expect(
      state.booksInGroup(_audioGroup).map((b) => b.bookUrl),
      isNot(contains('u4')),
    );
    expect(
      state.booksInGroup(_netNoneGroup).map((b) => b.bookUrl),
      isNot(contains('u1')),
    );
  });

  test('公开自定义分组剔除私密组书；私密组 Tab 保留全部组内书', () {
    final state = _state(books);
    final publicMatched = state.booksInGroup(_publicGroup);
    expect(publicMatched, isEmpty);

    final privateMatched = state.booksInGroup(_privateGroup);
    expect(privateMatched.map((b) => b.bookUrl), containsAll(['u1', 'u4']));
    expect(state.bookCountOf(_privateGroup), 2);
    // 公开组计数走同一 booksInGroup，天然剔除
    expect(state.bookCountOf(_publicGroup), 0);
  });

  test('可见分组保留私密组（hideEmpty 时按组内真实书数保留）', () {
    final state = _state(books);
    final visible = state.visibleGroups();
    expect(visible.map((g) => g.groupId), contains(4));
  });

  test('锁定判定：单本 EveryTime 未授权锁定，授权后放行', () {
    final state = _state(books);
    final privacy = _privacy();
    expect(state.isBookContentLocked(singlePrivateBook, privacy), isTrue);
    expect(
      state.isBookContentLocked(
        singlePrivateBook,
        _privacy(grantedBookUrls: {'u2'}),
      ),
      isFalse,
    );
  });

  test('锁定判定：私密组书未授权锁定，分组授权后组内书一并放行', () {
    final state = _state(books);
    expect(state.isBookContentLocked(privateGroupBook, _privacy()), isTrue);
    expect(
      state.isBookContentLocked(
        privateGroupBook,
        _privacy(grantedGroupIds: {4}),
      ),
      isFalse,
    );
    expect(
      state.isBookContentLocked(privateGroupBook, _privacy(enabled: false)),
      isFalse,
    );
    expect(
      state.isBookContentLocked(
        privateGroupBook,
        _privacy(verifyOnOpenBook: false),
      ),
      isFalse,
    );
  });

  test('分组锁定判定：私密组未授权整页锁定，授权/关闭开关后放行', () {
    final state = _state(books);
    expect(state.isGroupContentLocked(4, _privacy()), isTrue);
    expect(
      state.isGroupContentLocked(4, _privacy(grantedGroupIds: {4})),
      isFalse,
    );
    expect(state.isGroupContentLocked(8, _privacy()), isFalse);
    expect(
      state.isGroupContentLocked(4, _privacy(verifyOnEnterGroup: false)),
      isFalse,
    );
  });

  test('privateLoaded=false 时不提前锁定（避免首帧误锁）', () {
    const state = BookshelfState(privacyLoaded: false);
    expect(state.isBookContentLocked(singlePrivateBook, _privacy()), isFalse);
    expect(state.isGroupContentLocked(4, _privacy()), isFalse);
  });
}
