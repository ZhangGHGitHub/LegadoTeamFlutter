/// 私密内容授权模型测试（批9c）
///
/// 覆盖（对照验收标准）：
/// - EveryTime 目标授权只作用单本 / 单个分组；
/// - AppSession 一次验证放行全部私密内容；
/// - `unlock()`（启动闸门）在 EveryTime 下不代表内容授权；
/// - revokeBook / revokeGroup / revokeAll / lock 清理；
/// - 关闭「打开书籍时验证」与总开关关闭时不脱敏。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';

import '../mocks/privacy_mock_book_api.dart';

const _bookA = Book(
  bookUrl: 'https://a.com/1',
  name: '书A',
  author: '作者A',
  group: 4,
);
const _bookB = Book(
  bookUrl: 'https://a.com/2',
  name: '书B',
  author: '作者B',
  group: 8,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PrivacyMockBookApi api;
  late ProviderContainer container;

  Future<PrivacyNotifier> boot({
    PrivacyUnlockScope scope = PrivacyUnlockScope.everyTime,
    bool verifyOnOpenBook = true,
    bool enabled = true,
  }) async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: enabled,
      PrefKeys.privateVerifyOnOpenBook: verifyOnOpenBook,
      PrefKeys.privateVerifyOnEnterGroup: true,
      PrefKeys.privateUnlockScope: scope.storageValue,
    });
    api = PrivacyMockBookApi(books: [_bookA, _bookB]);
    await api.privacySetPassword('pw');
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(api)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(privacyNotifierProvider.notifier);
    await notifier.ensureLoaded();
    return notifier;
  }

  PrivacyState state() => container.read(privacyNotifierProvider);

  group('EveryTime 目标授权', () {
    test('验证单本只放行该本，其它私密书仍锁定', () async {
      final notifier = await boot();

      expect(
        await notifier.verifyForTarget('wrong', bookUrl: _bookA.bookUrl),
        isFalse,
      );
      expect(state().grantedBookUrls, isEmpty, reason: '密码错误不得授权');

      expect(
        await notifier.verifyForTarget('pw', bookUrl: _bookA.bookUrl),
        isTrue,
      );
      expect(state().grantedBookUrls, contains(_bookA.bookUrl));
      expect(
        state().sessionUnlocked,
        isFalse,
        reason: 'EveryTime 不得把目标授权提升为会话解锁',
      );
      expect(state().contentSessionUnlocked, isFalse);

      expect(
        state().isBookLocked(_bookA, isPrivate: true),
        isFalse,
        reason: '刚验证过的单本应放行',
      );
      expect(
        state().isBookLocked(_bookB, isPrivate: true),
        isTrue,
        reason: '未验证的私密书仍应锁定',
      );
      expect(state().isTargetGranted(bookUrl: _bookB.bookUrl), isFalse);
    });

    test('验证私密分组放行组内书，组外书仍锁定', () async {
      final notifier = await boot();
      expect(await notifier.verifyForTarget('pw', groupId: 4), isTrue);

      expect(state().isGroupContentLocked(4, isPrivate: true), isFalse);
      expect(state().isGroupContentLocked(8, isPrivate: true), isTrue);
      expect(state().isBookTargetGranted(_bookA), isTrue);
      expect(state().isBookTargetGranted(_bookB), isFalse);
    });

    test('启动闸门 unlock() 不代表内容授权（防 EveryTime 形同虚设）', () async {
      final notifier = await boot();
      expect(await notifier.unlock('pw'), isTrue);
      expect(state().sessionUnlocked, isTrue);
      expect(
        state().contentSessionUnlocked,
        isFalse,
        reason: 'EveryTime 下会话标记不参与内容放行',
      );
      expect(state().isBookLocked(_bookA, isPrivate: true), isTrue);
    });

    test('revokeBook 只撤该本；revokeAll/lock 清空全部目标', () async {
      final notifier = await boot();
      await notifier.verifyForTarget('pw', bookUrl: _bookA.bookUrl, groupId: 4);
      expect(state().grantedBookUrls, isNotEmpty);
      expect(state().grantedGroupIds, isNotEmpty);

      notifier.revokeBook(_bookA.bookUrl);
      expect(state().grantedBookUrls, isEmpty);
      expect(state().grantedGroupIds, contains(4), reason: '撤销单本不影响分组');

      notifier.revokeGroup(4);
      expect(state().grantedGroupIds, isEmpty);

      await notifier.verifyForTarget('pw', bookUrl: _bookB.bookUrl);
      notifier.revokeAll();
      expect(state().grantedBookUrls, isEmpty);
      expect(state().grantedGroupIds, isEmpty);

      await notifier.verifyForTarget('pw', bookUrl: _bookB.bookUrl);
      notifier.lock();
      expect(state().grantedBookUrls, isEmpty);
      expect(state().grantedGroupIds, isEmpty);
    });
  });

  group('会话级频率', () {
    test('AppSession：验证任意目标后全部私密内容放行', () async {
      final notifier = await boot(scope: PrivacyUnlockScope.appSession);
      expect(
        await notifier.verifyForTarget('pw', bookUrl: _bookA.bookUrl),
        isTrue,
      );

      expect(state().sessionUnlocked, isTrue);
      expect(state().contentSessionUnlocked, isTrue);
      expect(state().isBookLocked(_bookA, isPrivate: true), isFalse);
      expect(state().isBookLocked(_bookB, isPrivate: true), isFalse);
      expect(state().isGroupContentLocked(8, isPrivate: true), isFalse);
      // 会话级不登记目标集合（避免误以为 EveryTime 语义）
      expect(state().grantedBookUrls, isEmpty);
    });

    test('UntilBackground：验证后放行，lock() 后全部重新锁定', () async {
      final notifier = await boot(scope: PrivacyUnlockScope.untilBackground);
      await notifier.verifyForTarget('pw', groupId: 4);
      expect(state().isBookLocked(_bookB, isPrivate: true), isFalse);

      notifier.lock();
      expect(state().isBookLocked(_bookA, isPrivate: true), isTrue);
      expect(state().isBookLocked(_bookB, isPrivate: true), isTrue);
    });
  });

  group('策略关闭', () {
    test('总开关关闭：不验证、不脱敏', () async {
      await boot(enabled: false);
      expect(state().isTargetGranted(bookUrl: _bookA.bookUrl), isTrue);
      expect(state().isBookLocked(_bookA, isPrivate: true), isFalse);
      expect(state().isGroupContentLocked(4, isPrivate: true), isFalse);
    });

    test('关闭「打开书籍时验证」：单本不脱敏（分组开关独立）', () async {
      await boot(verifyOnOpenBook: false);
      expect(state().isBookLocked(_bookA, isPrivate: true), isFalse);
      expect(
        state().isGroupContentLocked(4, isPrivate: true),
        isTrue,
        reason: '进入分组验证开关仍为开',
      );
    });

    test('未设置密码时授权判定仍需显式验证（无凭据不会自动放行）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: PrivacyUnlockScope.everyTime.storageValue,
      });
      api = PrivacyMockBookApi(books: [_bookA]);
      container = ProviderContainer(
        overrides: [bookApiProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(privacyNotifierProvider.notifier);
      await notifier.ensureLoaded();
      expect(
        await notifier.verifyForTarget('pw', bookUrl: _bookA.bookUrl),
        isFalse,
      );
      // 无凭据时 Notifier 回落关闭 enabled（避免无密码锁死）→ 不脱敏
      expect(state().enabled, isFalse);
      expect(state().isBookLocked(_bookA, isPrivate: true), isFalse);
    });
  });
}
