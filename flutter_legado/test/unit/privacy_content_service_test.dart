/// 私密内容服务测试（批9c）
///
/// 覆盖：单本/分组（2^n 位掩码与旧时间戳 exact）判定、书名+作者反查、
/// 记录脱敏、列表锁定 URL 过滤、加载失败 fail-open（不致整库误锁）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/services/privacy_content_service.dart';

import '../mocks/privacy_mock_book_api.dart';

const _nowTimestamp = 1700000000000;

Book _book({
  required String url,
  required String name,
  String author = '作者',
  int group = 0,
  bool isPrivate = false,
}) => Book(
  bookUrl: url,
  name: name,
  author: author,
  group: group,
  isPrivate: isPrivate,
);

PrivacyState _privacy({
  bool enabled = true,
  bool verifyOnOpenBook = true,
  bool verifyOnEnterGroup = true,
  PrivacyUnlockScope scope = PrivacyUnlockScope.everyTime,
  Set<String> grantedBookUrls = const {},
  Set<int> grantedGroupIds = const {},
  bool sessionUnlocked = false,
}) => PrivacyState(
  enabled: enabled,
  hasPassword: true,
  verifyOnOpenBook: verifyOnOpenBook,
  verifyOnEnterGroup: verifyOnEnterGroup,
  unlockScope: scope,
  grantedBookUrls: grantedBookUrls,
  grantedGroupIds: grantedGroupIds,
  sessionUnlocked: sessionUnlocked,
  loaded: true,
);

/// 读取标记失败的替身（fail-open 断言）
class _BrokenMarkerApi extends PrivacyMockBookApi {
  _BrokenMarkerApi({super.books});

  @override
  Future<List<String>> getPrivateBookUrls() async =>
      throw StateError('markers down');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('快照判定：单本 + 2^n 分组 + 旧时间戳 exact', () async {
    final api = PrivacyMockBookApi(
      books: [
        _book(url: 'u1', name: '单本私密', isPrivate: true),
        _book(url: 'u2', name: '新分组书', group: 4 | 1),
        _book(url: 'u3', name: '旧时间戳书', group: _nowTimestamp),
        _book(url: 'u4', name: '普通书', group: 1),
      ],
      groups: [
        const BookGroup(groupId: 4, groupName: '私密新组', isPrivate: true),
        BookGroup(groupId: _nowTimestamp, groupName: '私密旧组', isPrivate: true),
      ],
    );
    final snapshot = await PrivacyContentService(api: api).load();

    expect(snapshot.loaded, isTrue);
    expect(snapshot.privateBookUrls, {'u1'});
    expect(snapshot.privateGroupIds, {4, _nowTimestamp});
    expect(snapshot.isBookPrivate(snapshot.booksByUrl['u1']!), isTrue);
    expect(
      snapshot.isBookPrivate(snapshot.booksByUrl['u2']!),
      isTrue,
      reason: '新分组按位掩码命中',
    );
    expect(
      snapshot.isBookPrivate(snapshot.booksByUrl['u3']!),
      isTrue,
      reason: '旧时间戳按 exact 命中',
    );
    expect(
      snapshot.isBookPrivate(snapshot.booksByUrl['u4']!),
      isFalse,
      reason: '旧时间戳低位 bit 不得误命中新 2^n 分组',
    );
  });

  test('书名+作者反查：精确命中、同名多作者不误伤', () async {
    final api = PrivacyMockBookApi(
      books: [
        _book(url: 'u1', name: '同名书', author: '甲', isPrivate: true),
        _book(url: 'u2', name: '同名书', author: '乙'),
      ],
    );
    final snapshot = await PrivacyContentService(api: api).load();

    expect(snapshot.findBookByNameAuthor('同名书', '甲')?.bookUrl, 'u1');
    expect(snapshot.findBookByNameAuthor('同名书', '乙')?.bookUrl, 'u2');
    expect(
      snapshot.findBookByNameAuthor('同名书', ''),
      isNull,
      reason: '作者为空且同名多本时无法确定，按非私密处理',
    );
    expect(snapshot.findBookByNameAuthor('不存在', '甲'), isNull);
  });

  test('记录锁定：私密书按名+作者脱敏，未知书记录不脱敏', () async {
    final api = PrivacyMockBookApi(
      books: [_book(url: 'u1', name: '秘密书', author: '秘密作者', isPrivate: true)],
    );
    final snapshot = await PrivacyContentService(api: api).load();
    final privacy = _privacy();

    expect(
      snapshot.isRecordLocked(const PrivacyRecordKey('秘密书', '秘密作者'), privacy),
      isTrue,
    );
    expect(
      snapshot.isRecordLocked(const PrivacyRecordKey('公开书', '作者'), privacy),
      isFalse,
    );

    final granted = _privacy(grantedBookUrls: {'u1'});
    expect(
      snapshot.isRecordLocked(const PrivacyRecordKey('秘密书', '秘密作者'), granted),
      isFalse,
      reason: 'EveryTime 已授权该本时记录不再脱敏',
    );
  });

  test('列表锁定 URL：只返回未授权的私密书（搜索/提示过滤依据）', () async {
    final api = PrivacyMockBookApi(
      books: [
        _book(url: 'u1', name: '私密1', isPrivate: true),
        _book(url: 'u2', name: '私密2', group: 4),
        _book(url: 'u3', name: '公开'),
      ],
      groups: [const BookGroup(groupId: 4, groupName: '私密组', isPrivate: true)],
    );
    final snapshot = await PrivacyContentService(api: api).load();

    expect(snapshot.lockedBookUrls(snapshot.booksByUrl.values, _privacy()), {
      'u1',
      'u2',
    });
    expect(
      snapshot.lockedBookUrls(
        snapshot.booksByUrl.values,
        _privacy(grantedBookUrls: {'u1'}),
      ),
      {'u2'},
    );
    expect(
      snapshot.lockedBookUrls(
        snapshot.booksByUrl.values,
        _privacy(verifyOnOpenBook: false),
      ),
      isEmpty,
    );
  });

  test('无任何私密标记时不拉全量书籍（避免多余 IO）', () async {
    final api = PrivacyMockBookApi(
      books: [_book(url: 'u1', name: '公开')],
    );
    final snapshot = await PrivacyContentService(api: api).load();
    expect(snapshot.loaded, isTrue);
    expect(snapshot.booksByUrl, isEmpty);
    expect(snapshot.lockedBookUrls(const [], _privacy()), isEmpty);
  });

  test('读取标记失败：快照仍 loaded，按未锁定处理（fail-open）', () async {
    final api = _BrokenMarkerApi(
      books: [_book(url: 'u1', name: '私密', isPrivate: true)],
    );
    final snapshot = await PrivacyContentService(api: api).load();
    expect(snapshot.loaded, isTrue);
    expect(snapshot.privateBookUrls, isEmpty);
    expect(
      snapshot.markersUnavailable,
      isTrue,
      reason: '标记读取失败应上报“暂不可用”，UI 据此提示',
    );
    expect(
      snapshot.lockedBookUrls([
        const Book(bookUrl: 'u1', name: '私密', author: '作者'),
      ], _privacy()),
      isEmpty,
      reason: '标记读取失败时不得误锁整库（fail-open）',
    );
  });
}
