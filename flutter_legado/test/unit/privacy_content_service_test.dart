/// 私密内容服务测试（批9c）
///
/// 覆盖：单本/分组（2^n 位掩码与旧时间戳 exact）判定、书名+作者反查、
/// 记录脱敏、列表锁定 URL 过滤、加载失败 fail-open（不致整库误锁）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/services/privacy_content_service.dart';
import 'package:flutter_legado/src/services/privacy_record_alias_store.dart';

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

/// 固定别名替身（不触碰 SharedPreferences）
class _FakeAliasStore extends PrivacyRecordAliasStore {
  _FakeAliasStore(this.aliases);

  final List<PrivacyRecordAlias> aliases;

  @override
  Future<List<PrivacyRecordAlias>> load() async => aliases;
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

  group('P2-3 改名别名反查', () {
    test('私密书改名后：旧名+作者按 bookUrl 命中当前书并锁定', () async {
      final api = PrivacyMockBookApi(
        books: [_book(url: 'u1', name: '新书名', author: '作者', isPrivate: true)],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '作者', bookUrl: 'u1'),
        ]),
      ).load();
      final privacy = _privacy();

      expect(
        snapshot.findBookByNameAuthor('旧书名', '作者')?.bookUrl,
        'u1',
        reason: '改名别名应锚回当前书籍',
      );
      expect(
        snapshot.isRecordLocked(const PrivacyRecordKey('旧书名', '作者'), privacy),
        isTrue,
      );
      expect(
        snapshot.isRecordLocked(const PrivacyRecordKey('旧书名', ''), privacy),
        isTrue,
        reason: '作者列为空的历史行应按同名唯一候选锁定',
      );
      expect(
        snapshot.isRecordLocked(const PrivacyRecordKey('新书名', '作者'), privacy),
        isTrue,
        reason: '改名后的当前记录同样锁定',
      );
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '作者'),
          _privacy(grantedBookUrls: {'u1'}),
        ),
        isFalse,
        reason: 'EveryTime 已授权该本时不再脱敏',
      );
    });

    test('非私密书改名后：旧记录不误锁（不过度脱敏）', () async {
      final api = PrivacyMockBookApi(
        books: [_book(url: 'u1', name: '新书名', author: '作者')],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '作者', bookUrl: 'u1'),
        ]),
      ).load();

      expect(
        snapshot.findBookByNameAuthor('旧书名', '作者')?.name,
        '新书名',
        reason: '非私密改名也应按别名解析当前书名',
      );
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '作者'),
          _privacy(),
        ),
        isFalse,
      );
    });

    test('旧名被新书复用：任一候选私密即锁定（fail-closed）', () async {
      final api = PrivacyMockBookApi(
        books: [
          _book(url: 'u1', name: '新书名', author: '作者', isPrivate: true),
          _book(url: 'u2', name: '旧书名', author: '作者'),
        ],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '作者', bookUrl: 'u1'),
        ]),
      ).load();

      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '作者'),
          _privacy(),
        ),
        isTrue,
        reason: '旧名记录可能属于已改名私密书，不得因同名新书而放行',
      );
      expect(
        snapshot.findBookByNameAuthor('旧书名', '作者')?.bookUrl,
        'u1',
        reason: '锁定行取封面优先私密候选',
      );
    });

    test('无任何私密标记但有改名别名：仍加载书籍供展示解析', () async {
      final api = PrivacyMockBookApi(
        books: [_book(url: 'u1', name: '新书名', author: '作者')],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '作者', bookUrl: 'u1'),
        ]),
      ).load();

      expect(snapshot.loaded, isTrue);
      expect(snapshot.booksByUrl, contains('u1'));
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '作者'),
          _privacy(),
        ),
        isFalse,
      );
    });

    test('合并作者显示串 + 改名别名：精确键未中仍按作者分段锁定', () async {
      final api = PrivacyMockBookApi(
        books: [_book(url: 'u1', name: '新书名', author: '甲', isPrivate: true)],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '甲', bookUrl: 'u1'),
        ]),
      ).load();

      // v113 迁移保留的合并作者行：作者列展示为「甲、乙」，与别名登记的
      // 「甲」精确键不一致。修复前作者非空直接返回空候选 → 旧名 fail-open。
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '甲、乙'),
          _privacy(),
        ),
        isTrue,
        reason: '合并作者串必须拆段命中别名，旧私密书名不得明文显示',
      );
      expect(
        snapshot.findBookByNameAuthor('旧书名', '甲、乙')?.bookUrl,
        'u1',
        reason: '锁定行应能锚回当前书籍取真实封面',
      );
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '\u001Eauthors:["乙","甲"]'),
          _privacy(),
        ),
        isTrue,
        reason: '直接传入历史原始合并串（未解码）时同样应拆段命中',
      );
    });

    test('合并作者与别名作者完全不相交：仅按别名同名回落锁定', () async {
      final api = PrivacyMockBookApi(
        books: [_book(url: 'u1', name: '新书名', author: '甲', isPrivate: true)],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '甲', bookUrl: 'u1'),
        ]),
      ).load();

      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('旧书名', '乙、丙'),
          _privacy(),
        ),
        isTrue,
        reason: '精确键与作者分段均未中时，别名派生候选的同名回落必须兜底',
      );
    });

    test('非私密记录不误锁：精确命中公开书 / 同名私密书不扩大匹配', () async {
      final api = PrivacyMockBookApi(
        books: [
          _book(url: 'u1', name: '新书名', author: '甲', isPrivate: true),
          _book(url: 'u2', name: '公开书', author: '甲'),
          _book(url: 'u3', name: '同名书', author: '丙', isPrivate: true),
        ],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '旧书名', author: '甲', bookUrl: 'u1'),
        ]),
      ).load();

      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('公开书', '甲、乙'),
          _privacy(),
        ),
        isFalse,
        reason: '作者分段只命中公开书时不得脱敏',
      );
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('同名书', '甲、乙'),
          _privacy(),
        ),
        isFalse,
        reason: '作者非空时不得回落到当前书籍的同名候选（避免 P2-5 误锁）',
      );
    });

    test('别名指向已删除书籍：跳过且不误锁', () async {
      final api = PrivacyMockBookApi(
        books: [_book(url: 'u2', name: '其它书', author: '作者', isPrivate: true)],
      );
      final snapshot = await PrivacyContentService(
        api: api,
        aliasStore: _FakeAliasStore(const [
          PrivacyRecordAlias(name: '已删书', author: '作者', bookUrl: 'u1'),
        ]),
      ).load();

      expect(snapshot.findBookByNameAuthor('已删书', '作者'), isNull);
      expect(
        snapshot.isRecordLocked(
          const PrivacyRecordKey('已删书', '作者'),
          _privacy(),
        ),
        isFalse,
      );
    });
  });
}
