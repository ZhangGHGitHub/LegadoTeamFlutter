/// 隐私/应用锁 Notifier 测试（设置批9b；审查回修）
///
/// 覆盖：默认策略与持久化、启用需密码、解锁成功/失败、只验不授权、
/// 改密验旧、清密需验证与错误分类、AppSession 后台不失效、
/// UntilBackground 宽限 0/30s（paused/hidden）、策略/凭据读取失败
/// fail-closed 与重试、策略写入失败回滚、备份口径。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart' show BridgeError;
import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_notifier.dart';
import 'package:flutter_legado/src/providers/privacy/privacy_state.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/services/mock_book_api.dart';
import 'package:flutter_legado/src/services/privacy_biometric_service.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';

/// 凭据读取可失败的 Mock（fail-closed 测试）
class _FlakyCredentialApi extends MockBookApi {
  bool failHasPassword = true;

  @override
  Future<bool> privacyHasPassword() {
    if (failHasPassword) {
      throw const BridgeError(message: '数据库尚未初始化');
    }
    return super.privacyHasPassword();
  }
}

/// 策略读取可恢复失败（fail-closed 重试测试）
class _FlakyPolicyStore extends PrivacyPolicyStore {
  bool failRead = true;

  @override
  Future<PrivacyPolicy> read() {
    if (failRead) throw const FormatException('策略存储不可读');
    return super.read();
  }
}

/// 策略写入恒失败（setter bool / UI SnackBar 测试）
class _FailingWriteStore extends PrivacyPolicyStore {
  const _FailingWriteStore();

  @override
  Future<bool> writeBool(String key, bool value) async => false;

  @override
  Future<bool> writeString(String key, String value) async => false;

  @override
  Future<bool> writeInt(String key, int value) async => false;
}

/// 删除凭据抛错（清密失败分类测试）
class _FailingClearApi extends MockBookApi {
  @override
  Future<void> privacyClearPassword() async {
    throw const BridgeError(message: '删除凭据失败');
  }
}

/// 生物识别平台 Fake（批9d）：默认可用，可逐项注入失败
class _FakeBiometricService implements PrivacyBiometricService {
  static final String defaultToken = base64Encode(List<int>.filled(32, 7));
  static final String defaultEnvelope = base64Encode(List<int>.filled(64, 9));
  static final String defaultIv = base64Encode(List<int>.filled(12, 5));

  PrivacyBiometricStatus status = const PrivacyBiometricStatus(available: true);
  PrivacyBiometricErrorCode? enableError;
  PrivacyBiometricErrorCode? unlockError;
  String? unlockTokenOverride;
  String? envelopeOverride;
  String? ivOverride;
  int enableCalls = 0;
  int deleteCalls = 0;
  String? lastEnabledToken;
  String? lastUnlockEnvelope;
  String? lastUnlockIv;
  Completer<String>? unlockCompleter;

  @override
  Future<PrivacyBiometricStatus> getStatus() async => status;

  @override
  Future<PrivacyBiometricEnvelope> enable(String tokenBase64) async {
    enableCalls++;
    lastEnabledToken = tokenBase64;
    if (enableError != null) {
      throw PrivacyBiometricException(enableError!);
    }
    return PrivacyBiometricEnvelope(
      envelope: envelopeOverride ?? defaultEnvelope,
      iv: ivOverride ?? defaultIv,
    );
  }

  @override
  Future<String> unlock({required String envelope, required String iv}) async {
    lastUnlockEnvelope = envelope;
    lastUnlockIv = iv;
    if (unlockCompleter != null) return unlockCompleter!.future;
    if (unlockError != null) {
      throw PrivacyBiometricException(unlockError!);
    }
    return unlockTokenOverride ?? defaultToken;
  }

  @override
  Future<void> deleteKey() async => deleteCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockBookApi api;
  late ProviderContainer container;

  setUp(() {
    api = MockBookApi();
  });

  Future<PrivacyNotifier> boot({
    Map<String, Object> prefs = const {},
    MockBookApi? overrideApi,
    PrivacyPolicyStore? store,
    PrivacyBiometricService? biometricService,
  }) async {
    SharedPreferences.setMockInitialValues(prefs);
    final overrides = <Override>[
      bookApiProvider.overrideWithValue(overrideApi ?? api),
    ];
    if (store != null) {
      overrides.add(privacyPolicyStoreProvider.overrideWithValue(store));
    }
    if (biometricService != null) {
      overrides.add(
        privacyBiometricServiceProvider.overrideWithValue(biometricService),
      );
    }
    container = ProviderContainer(overrides: overrides);
    addTearDown(container.dispose);
    final notifier = container.read(privacyNotifierProvider.notifier);
    await notifier.ensureLoaded();
    // 平台能力为不阻塞的异步刷新，等它落到状态
    await Future<void>.delayed(Duration.zero);
    return notifier;
  }

  /// 预置「已有密码 + 已配置生物凭据」
  Future<void> seedBiometric({String password = 'pw'}) async {
    await api.privacySetPassword(password);
    await api.privacyBiometricSet(
      _FakeBiometricService.defaultToken,
      _FakeBiometricService.defaultEnvelope,
      _FakeBiometricService.defaultIv,
    );
  }

  PrivacyState state() => container.read(privacyNotifierProvider);

  test('默认策略：启用关、验证时机 开/开/关、AppSession、宽限 0', () async {
    await boot();
    final s = state();
    expect(s.loaded, isTrue);
    expect(s.enabled, isFalse);
    expect(s.hasPassword, isFalse);
    expect(s.policyError, isNull);
    expect(s.credentialError, isNull);
    expect(s.verifyOnEnterGroup, isTrue);
    expect(s.verifyOnOpenBook, isTrue);
    expect(s.verifyOnAppStart, isFalse);
    expect(s.unlockScope, PrivacyUnlockScope.appSession);
    expect(s.backgroundGraceSeconds, 0);
    expect(s.sessionUnlocked, isFalse);
    expect(s.appStartVerified, isFalse);
  });

  test('策略持久化：读取已存值并写回偏好', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnEnterGroup: false,
        PrefKeys.privateVerifyOnOpenBook: false,
        PrefKeys.privateVerifyOnAppStart: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 120,
      },
    );
    var s = state();
    expect(s.enabled, isTrue);
    expect(s.hasPassword, isTrue);
    expect(s.verifyOnEnterGroup, isFalse);
    expect(s.verifyOnOpenBook, isFalse);
    expect(s.verifyOnAppStart, isTrue);
    expect(s.unlockScope, PrivacyUnlockScope.untilBackground);
    expect(s.backgroundGraceSeconds, 120);

    await notifier.setVerifyOnEnterGroup(true);
    await notifier.setVerifyOnOpenBook(true);
    await notifier.setVerifyOnAppStart(false);
    await notifier.setUnlockScope(PrivacyUnlockScope.everyTime);
    await notifier.setBackgroundGraceSeconds(300);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateVerifyOnEnterGroup), isTrue);
    expect(prefs.getBool(PrefKeys.privateVerifyOnOpenBook), isTrue);
    expect(prefs.getBool(PrefKeys.privateVerifyOnAppStart), isFalse);
    expect(prefs.getString(PrefKeys.privateUnlockScope), 'every_time');
    expect(prefs.getInt(PrefKeys.privateBackgroundGraceSeconds), 300);
    s = state();
    expect(s.unlockScope, PrivacyUnlockScope.everyTime);
    expect(s.backgroundGraceSeconds, 300);
  });

  test('非法宽限值回落 0，未知频率回落 AppSession', () async {
    await boot(
      prefs: {
        PrefKeys.privateUnlockScope: 'nonsense',
        PrefKeys.privateBackgroundGraceSeconds: 42,
      },
    );
    expect(state().unlockScope, PrivacyUnlockScope.appSession);
    expect(state().backgroundGraceSeconds, 0);
  });

  test('启用需密码：无凭据开启失败，设密后可开启', () async {
    final notifier = await boot();
    expect(await notifier.setEnabled(true), isFalse);
    expect(state().enabled, isFalse);
    expect(
      await notifier.setPassword('new-pass'),
      PrivacyPasswordChangeResult.success,
    );
    expect(state().hasPassword, isTrue);
    expect(await notifier.setEnabled(true), isTrue);
    expect(state().enabled, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateEnabled), isTrue);
    // 关闭只改开关，不改凭据与策略
    await notifier.setEnabled(false);
    expect(state().enabled, isFalse);
    expect(state().hasPassword, isTrue);
    expect(await api.privacyVerifyPassword('new-pass'), isTrue);
  });

  test('解锁成功置会话与启动标记；失败不改状态', () async {
    final notifier = await boot();
    await notifier.setPassword('pw');
    expect(await notifier.unlock('wrong'), isFalse);
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
    expect(await notifier.unlock('pw'), isTrue);
    expect(state().sessionUnlocked, isTrue);
    expect(state().appStartVerified, isTrue);
    notifier.lock();
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
  });

  test('改密必须验旧：缺失/错误旧密拒绝，正确旧密生效并重新上锁', () async {
    final notifier = await boot();
    await notifier.setPassword('first-pass');
    await notifier.unlock('first-pass');
    expect(state().sessionUnlocked, isTrue);

    expect(
      await notifier.setPassword('second-pass'),
      PrivacyPasswordChangeResult.oldPasswordWrong,
    );
    expect(
      await notifier.setPassword('second-pass', oldPassword: 'bad'),
      PrivacyPasswordChangeResult.oldPasswordWrong,
    );
    expect(await api.privacyVerifyPassword('first-pass'), isTrue);

    expect(
      await notifier.setPassword('second-pass', oldPassword: 'first-pass'),
      PrivacyPasswordChangeResult.success,
    );
    expect(state().hasPassword, isTrue);
    expect(state().sessionUnlocked, isFalse, reason: '改密后需重新解锁');
    expect(state().appStartVerified, isFalse);
    expect(await api.privacyVerifyPassword('first-pass'), isFalse);
    expect(await api.privacyVerifyPassword('second-pass'), isTrue);
  });

  test('新密码非法：空串/全空白/超 128 字符拒绝', () async {
    final notifier = await boot();
    expect(
      await notifier.setPassword(''),
      PrivacyPasswordChangeResult.invalidPassword,
    );
    expect(
      await notifier.setPassword('   '),
      PrivacyPasswordChangeResult.invalidPassword,
    );
    expect(
      await notifier.setPassword('a' * 129),
      PrivacyPasswordChangeResult.invalidPassword,
    );
    expect(state().hasPassword, isFalse);
  });

  test('清密需验证：错误密码不清除，正确后 hasPassword=false、enabled 保持', () async {
    final notifier = await boot();
    await notifier.setPassword('pw');
    await notifier.setEnabled(true);
    await notifier.unlock('pw');
    expect(
      await notifier.clearPassword(password: 'bad'),
      PrivacyClearPasswordResult.passwordWrong,
    );
    expect(
      await notifier.clearPassword(password: ''),
      PrivacyClearPasswordResult.passwordWrong,
    );
    expect(state().hasPassword, isTrue);
    expect(await api.privacyHasPassword(), isTrue);

    expect(
      await notifier.clearPassword(password: 'pw'),
      PrivacyClearPasswordResult.success,
    );
    expect(state().hasPassword, isFalse);
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
    expect(state().enabled, isTrue, reason: 'Notifier 保持 enabled，由设置页提示关闭');
    expect(await api.privacyHasPassword(), isFalse);
  });

  test('只验不授权：verifyPasswordOnly 成功不置会话/启动标记', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot();
    expect(await notifier.verifyPasswordOnly('bad'), isFalse);
    expect(await notifier.verifyPasswordOnly('pw'), isTrue);
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
  });

  test('清密失败分类：API 删除异常归为 failure 且凭据保持不变', () async {
    final failing = _FailingClearApi();
    await failing.privacySetPassword('pw');
    final notifier = await boot(overrideApi: failing);
    expect(
      await notifier.clearPassword(password: 'pw'),
      PrivacyClearPasswordResult.failure,
    );
    expect(state().hasPassword, isTrue);
    expect(await failing.privacyVerifyPassword('pw'), isTrue);
  });

  test('AppSession：后台任意时长不失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'app_session',
      },
    );
    await notifier.unlock('pw');
    final base = DateTime(2026, 11, 9, 10);
    notifier.handleLifecycleState(AppLifecycleState.paused, now: base);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: base.add(const Duration(days: 1)),
    );
    expect(state().sessionUnlocked, isTrue);
  });

  test('UntilBackground 宽限 0：回到前台立即失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 0,
      },
    );
    await notifier.unlock('pw');
    final base = DateTime(2026, 11, 9, 10);
    notifier.handleLifecycleState(AppLifecycleState.paused, now: base);
    notifier.handleLifecycleState(AppLifecycleState.resumed, now: base);
    expect(state().sessionUnlocked, isFalse);
  });

  test('UntilBackground 宽限 30s：未超时保持，超时失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 30,
      },
    );
    final base = DateTime(2026, 11, 9, 10);
    await notifier.unlock('pw');
    notifier.handleLifecycleState(AppLifecycleState.paused, now: base);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: base.add(const Duration(seconds: 29)),
    );
    expect(state().sessionUnlocked, isTrue);

    final second = base.add(const Duration(minutes: 1));
    notifier.handleLifecycleState(AppLifecycleState.paused, now: second);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: second.add(const Duration(seconds: 31)),
    );
    expect(state().sessionUnlocked, isFalse);
    expect(state().appStartVerified, isFalse);
  });

  test('凭据读取失败 fail-closed：记错误且不当作无密码，重试成功后恢复', () async {
    final flaky = _FlakyCredentialApi();
    await flaky.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
      },
      overrideApi: flaky,
    );
    expect(state().loaded, isTrue);
    expect(state().credentialError, '无法读取隐私凭据');
    expect(state().hasPassword, isFalse, reason: '失败时不把凭据状态写成 false');
    expect(state().enabled, isTrue, reason: '失败时不擅自关闭已启用开关');

    flaky.failHasPassword = false;
    await notifier.retryCredentialCheck();
    expect(state().credentialError, isNull);
    expect(state().hasPassword, isTrue);
    expect(state().needsAppStartLock, isTrue);
  });

  test('成功读到无密码但 enabled=true：回落关闭，避免无凭据锁死', () async {
    await boot(prefs: {PrefKeys.privateEnabled: true});
    expect(state().hasPassword, isFalse);
    expect(state().enabled, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.privateEnabled), isFalse);
  });

  test('UntilBackground hidden→resumed 同样按宽限失效', () async {
    await api.privacySetPassword('pw');
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 30,
      },
    );
    await notifier.unlock('pw');
    final base = DateTime(2026, 11, 9, 10);
    notifier.handleLifecycleState(AppLifecycleState.hidden, now: base);
    notifier.handleLifecycleState(
      AppLifecycleState.resumed,
      now: base.add(const Duration(seconds: 31)),
    );
    expect(state().sessionUnlocked, isFalse);
  });

  test('策略单键类型错误：policyError 非空，不按默认策略继续', () async {
    await boot(prefs: {PrefKeys.privateVerifyOnEnterGroup: 'not-bool'});
    expect(state().loaded, isTrue);
    expect(state().policyError, '无法读取隐私设置');
    expect(state().credentialError, isNull);
  });

  test('策略 store 抛错：policyError 非空，重试成功后恢复策略', () async {
    await api.privacySetPassword('pw');
    final store = _FlakyPolicyStore();
    final notifier = await boot(
      prefs: {
        PrefKeys.privateEnabled: true,
        PrefKeys.privateVerifyOnAppStart: true,
        PrefKeys.privateUnlockScope: 'until_background',
        PrefKeys.privateBackgroundGraceSeconds: 120,
      },
      store: store,
    );
    expect(state().policyError, '无法读取隐私设置');
    expect(state().credentialError, isNull);

    store.failRead = false;
    await notifier.retryCredentialCheck();
    expect(state().policyError, isNull);
    expect(state().enabled, isTrue);
    expect(state().verifyOnAppStart, isTrue);
    expect(state().unlockScope, PrivacyUnlockScope.untilBackground);
    expect(state().backgroundGraceSeconds, 120);
  });

  test('策略写入失败：setter 返回 false 并回滚内存状态', () async {
    final notifier = await boot(store: const _FailingWriteStore());
    expect(await notifier.setVerifyOnEnterGroup(false), isFalse);
    expect(state().verifyOnEnterGroup, isTrue);
    expect(
      await notifier.setUnlockScope(PrivacyUnlockScope.untilBackground),
      isFalse,
    );
    expect(state().unlockScope, PrivacyUnlockScope.appSession);
    expect(await notifier.setBackgroundGraceSeconds(30), isFalse);
    expect(state().backgroundGraceSeconds, 0);

    await notifier.setPassword('pw');
    expect(await notifier.setEnabled(true), isFalse);
    expect(state().enabled, isFalse);
  });

  test('备份口径：仅 private_enabled 排除，其余策略随 appPrefs 往返', () async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.privateEnabled: true,
      PrefKeys.privateVerifyOnEnterGroup: false,
      PrefKeys.privateVerifyOnOpenBook: false,
      PrefKeys.privateVerifyOnAppStart: true,
      PrefKeys.privateUnlockScope: 'until_background',
      PrefKeys.privateBackgroundGraceSeconds: 120,
    });
    final collected = await RestoreIgnorePrefs.collectForBackup(const {});
    expect(collected.containsKey(PrefKeys.privateEnabled), isFalse);
    expect(collected[PrefKeys.privateVerifyOnEnterGroup], isFalse);
    expect(collected[PrefKeys.privateVerifyOnOpenBook], isFalse);
    expect(collected[PrefKeys.privateVerifyOnAppStart], isTrue);
    expect(collected[PrefKeys.privateUnlockScope], 'until_background');
    expect(collected[PrefKeys.privateBackgroundGraceSeconds], 120);

    expect(
      RestoreIgnorePrefs.alwaysIgnoreKeys,
      contains(PrefKeys.privateEnabled),
    );
    expect(
      RestoreIgnorePrefs.alwaysIgnoreKeys,
      isNot(contains(PrefKeys.privateVerifyOnEnterGroup)),
    );

    SharedPreferences.setMockInitialValues({});
    await RestoreIgnorePrefs.applyFromBackup(collected, const {});
    final restored = await SharedPreferences.getInstance();
    expect(restored.containsKey(PrefKeys.privateEnabled), isFalse);
    expect(restored.getBool(PrefKeys.privateVerifyOnEnterGroup), isFalse);
    expect(restored.getBool(PrefKeys.privateVerifyOnOpenBook), isFalse);
    expect(restored.getBool(PrefKeys.privateVerifyOnAppStart), isTrue);
    expect(restored.getString(PrefKeys.privateUnlockScope), 'until_background');
    expect(restored.getInt(PrefKeys.privateBackgroundGraceSeconds), 120);
  });

  // ===== [批9d] 生物识别状态机 =====

  group('批9d 生物识别', () {
    test('启动加载：configured 与平台能力进入状态', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      await boot(biometricService: fake);
      final s = state();
      expect(s.hasPassword, isTrue);
      expect(s.biometricConfigured, isTrue);
      expect(s.biometricStatus?.available, isTrue);
      expect(s.biometricUsable, isTrue);
    });

    test('无密码冷启动→设密：平台能力加载，开关可用', () async {
      final fake = _FakeBiometricService();
      final notifier = await boot(biometricService: fake);
      expect(state().hasPassword, isFalse);
      expect(state().biometricStatus, isNull, reason: '无密码时不需要查询平台能力');

      expect(
        await notifier.setPassword('pw'),
        PrivacyPasswordChangeResult.success,
      );
      await Future<void>.delayed(Duration.zero);
      final s = state();
      expect(s.hasPassword, isTrue);
      expect(s.biometricStatus?.available, isTrue);
      expect(s.biometricConfigured, isFalse);
      // 开关可用性判据：有密码 + 平台可用 + 未配置时允许开启
      expect(s.biometricStatus != null && s.biometricStatus!.available, isTrue);
    });

    test('无密码时 re-reload 不清空已加载的平台能力', () async {
      final fake = _FakeBiometricService();
      final notifier = await boot(biometricService: fake);
      await notifier.refreshBiometricStatus();
      expect(state().biometricStatus?.available, isTrue);

      await notifier.retryCredentialCheck();
      await Future<void>.delayed(Duration.zero);
      expect(
        state().biometricStatus?.available,
        isTrue,
        reason: '无密码的 _reload 不得把已加载状态置空（首次设密后仍要可用）',
      );
    });

    test('平台不可用时仍可关闭已配置的快捷解锁', () async {
      final fake = _FakeBiometricService()
        ..status = const PrivacyBiometricStatus(
          available: false,
          reason: PrivacyBiometricErrorCode.noHardware,
        );
      await seedBiometric();
      final notifier = await boot(biometricService: fake);
      expect(state().biometricConfigured, isTrue);
      expect(state().biometricUsable, isFalse);

      expect(await notifier.disableBiometric(), isTrue);
      expect(state().biometricConfigured, isFalse);
      expect(
        await api.privacyBiometricVerify(_FakeBiometricService.defaultToken),
        isFalse,
      );
    });

    test('外部清空 Rust 三键：解锁返回 notConfigured 并关闭开关', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(biometricService: fake);
      expect(state().biometricConfigured, isTrue);

      await api.privacyBiometricClear();
      final outcome = await notifier.unlockWithBiometric(appStart: true);
      expect(outcome.error, PrivacyBiometricCommandError.notConfigured);
      expect(state().biometricConfigured, isFalse);
      expect(state().sessionUnlocked, isFalse);
    });

    test('enable 成功：生成 32B 令牌、写 Rust、状态点亮', () async {
      final fake = _FakeBiometricService();
      await api.privacySetPassword('pw');
      final notifier = await boot(biometricService: fake);

      final outcome = await notifier.enableBiometric();
      expect(outcome.isSuccess, isTrue);
      expect(fake.enableCalls, 1);
      expect(base64Decode(fake.lastEnabledToken!).length, 32);
      expect(state().biometricConfigured, isTrue);
      expect(state().biometricUsable, isTrue);
      expect(
        await api.privacyBiometricVerify(fake.lastEnabledToken!),
        isTrue,
        reason: 'Rust/Mock 存入的摘要应能校验平台解封令牌',
      );
    });

    test('enable 无密码 → noPassword，不触平台', () async {
      final fake = _FakeBiometricService();
      final notifier = await boot(biometricService: fake);
      final outcome = await notifier.enableBiometric();
      expect(outcome.error, PrivacyBiometricCommandError.noPassword);
      expect(fake.enableCalls, 0);
      expect(state().biometricConfigured, isFalse);
    });

    test('enable 取消：不点亮且能力仍可用', () async {
      final fake = _FakeBiometricService()
        ..enableError = PrivacyBiometricErrorCode.cancelled;
      await api.privacySetPassword('pw');
      final notifier = await boot(biometricService: fake);
      final outcome = await notifier.enableBiometric();
      expect(outcome.error, PrivacyBiometricCommandError.cancelled);
      expect(state().biometricConfigured, isFalse);
      expect(state().biometricStatus?.available, isTrue);
    });

    test('enable 无硬件：不点亮且开关置灰（状态记录原因）', () async {
      final fake = _FakeBiometricService()
        ..enableError = PrivacyBiometricErrorCode.noHardware;
      await api.privacySetPassword('pw');
      final notifier = await boot(biometricService: fake);
      final outcome = await notifier.enableBiometric();
      expect(outcome.error, PrivacyBiometricCommandError.noHardware);
      expect(state().biometricConfigured, isFalse);
      expect(state().biometricStatus?.available, isFalse);
      expect(
        state().biometricStatus?.reason,
        PrivacyBiometricErrorCode.noHardware,
      );
      expect(state().biometricUsable, isFalse);
    });

    test('单次失败不置灰；锁定类错误才反映到能力状态', () async {
      final fake = _FakeBiometricService()
        ..enableError = PrivacyBiometricErrorCode.failed;
      await api.privacySetPassword('pw');
      final notifier = await boot(biometricService: fake);

      var outcome = await notifier.enableBiometric();
      expect(outcome.error, PrivacyBiometricCommandError.failed);
      expect(state().biometricStatus?.available, isTrue);

      fake.enableError = PrivacyBiometricErrorCode.lockedOut;
      outcome = await notifier.enableBiometric();
      expect(outcome.error, PrivacyBiometricCommandError.lockedOut);
      expect(state().biometricStatus?.available, isFalse);
      expect(
        state().biometricStatus?.reason,
        PrivacyBiometricErrorCode.lockedOut,
      );
    });

    test('enable Rust 拒绝（IV 长度非法）：销毁原生密钥且不点亮', () async {
      final fake = _FakeBiometricService()
        ..ivOverride = base64Encode(List<int>.filled(11, 1));
      await api.privacySetPassword('pw');
      final notifier = await boot(biometricService: fake);
      final outcome = await notifier.enableBiometric();
      expect(outcome.error, PrivacyBiometricCommandError.failed);
      expect(state().biometricConfigured, isFalse);
      expect(fake.deleteCalls, 1);
    });

    test('disable：清 Rust 三键 + 销毁原生密钥 + 状态关闭', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(biometricService: fake);
      expect(state().biometricConfigured, isTrue);

      expect(await notifier.disableBiometric(), isTrue);
      expect(state().biometricConfigured, isFalse);
      expect(fake.deleteCalls, 1);
      expect(
        await api.privacyBiometricVerify(_FakeBiometricService.defaultToken),
        isFalse,
      );
    });

    test('key_invalidated：自动清 Rust 三键并关闭开关', () async {
      final fake = _FakeBiometricService()
        ..unlockError = PrivacyBiometricErrorCode.keyInvalidated;
      await seedBiometric();
      final notifier = await boot(biometricService: fake);

      final outcome = await notifier.unlockWithBiometric(appStart: true);
      expect(outcome.error, PrivacyBiometricCommandError.keyInvalidated);
      expect(state().biometricConfigured, isFalse);
      expect(state().sessionUnlocked, isFalse);
      expect(
        await api.privacyBiometricVerify(_FakeBiometricService.defaultToken),
        isFalse,
        reason: 'Rust 三键应被清除',
      );
    });

    test('令牌不匹配：不授权且保持配置（可回退密码）', () async {
      final fake = _FakeBiometricService()
        ..unlockTokenOverride = base64Encode(List<int>.filled(32, 8));
      await seedBiometric();
      final notifier = await boot(biometricService: fake);

      final outcome = await notifier.unlockWithBiometric(appStart: true);
      expect(outcome.error, PrivacyBiometricCommandError.failed);
      expect(state().sessionUnlocked, isFalse);
      expect(state().appStartVerified, isFalse);
      expect(state().biometricConfigured, isTrue);
    });

    test('verifyOnly：只验不授权（设置页语义）', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(
        biometricService: fake,
        prefs: {
          PrefKeys.privateEnabled: true,
          PrefKeys.privateUnlockScope: 'every_time',
        },
      );

      final outcome = await notifier.unlockWithBiometric(
        verifyOnly: true,
        bookUrl: 'https://a/1',
        groupId: 4,
      );
      expect(outcome.isSuccess, isTrue);
      expect(state().sessionUnlocked, isFalse);
      expect(state().appStartVerified, isFalse);
      expect(state().grantedBookUrls, isEmpty);
      expect(state().grantedGroupIds, isEmpty);
    });

    test('EveryTime：只授权目标书/分组，不置会话解锁', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(
        biometricService: fake,
        prefs: {
          PrefKeys.privateEnabled: true,
          PrefKeys.privateUnlockScope: 'every_time',
        },
      );

      expect(state().unlockScope, PrivacyUnlockScope.everyTime);
      final outcome = await notifier.unlockWithBiometric(
        bookUrl: 'https://a/1',
        groupId: 4,
      );
      expect(outcome.isSuccess, isTrue);
      expect(state().sessionUnlocked, isFalse);
      expect(state().grantedBookUrls, {'https://a/1'});
      expect(state().grantedGroupIds, {4});
      expect(
        state().isTargetGranted(bookUrl: 'https://a/1', groupId: 4),
        isTrue,
      );
      expect(state().isTargetGranted(bookUrl: 'https://a/2'), isFalse);
    });

    test('AppSession：会话级授权（书/分组全部放行）', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(
        biometricService: fake,
        prefs: {PrefKeys.privateEnabled: true},
      );

      final outcome = await notifier.unlockWithBiometric();
      expect(outcome.isSuccess, isTrue);
      expect(state().sessionUnlocked, isTrue);
      expect(state().appStartVerified, isTrue);
      expect(state().contentSessionUnlocked, isTrue);
      expect(state().isTargetGranted(bookUrl: 'https://any'), isTrue);
      expect(
        fake.lastUnlockEnvelope,
        _FakeBiometricService.defaultEnvelope,
        reason: '平台解锁必须收到 Rust stateGet 返回的同一信封',
      );
      expect(
        fake.lastUnlockIv,
        _FakeBiometricService.defaultIv,
        reason: '平台解锁必须收到 Rust stateGet 返回的同一 IV',
      );
    });

    test('启动闸门 appStart：EveryTime 也置会话/启动标记（仅证明进得来）', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(
        biometricService: fake,
        prefs: {
          PrefKeys.privateEnabled: true,
          PrefKeys.privateUnlockScope: 'every_time',
        },
      );

      expect(state().unlockScope, PrivacyUnlockScope.everyTime);
      final outcome = await notifier.unlockWithBiometric(appStart: true);
      expect(outcome.isSuccess, isTrue);
      expect(state().sessionUnlocked, isTrue);
      expect(state().appStartVerified, isTrue);
      expect(
        state().contentSessionUnlocked,
        isFalse,
        reason: 'EveryTime 下启动解锁不代表内容授权',
      );
      expect(state().isTargetGranted(bookUrl: 'https://any'), isFalse);
    });

    test('未配置时解锁 → notConfigured，不发平台请求', () async {
      final fake = _FakeBiometricService();
      await api.privacySetPassword('pw');
      final notifier = await boot(biometricService: fake);
      final outcome = await notifier.unlockWithBiometric(appStart: true);
      expect(outcome.error, PrivacyBiometricCommandError.notConfigured);
      expect(fake.enableCalls, 0);
    });

    test('改密成功：清空生物状态并销毁原生密钥', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(biometricService: fake);
      expect(state().biometricConfigured, isTrue);

      expect(
        await notifier.setPassword('new-pass', oldPassword: 'pw'),
        PrivacyPasswordChangeResult.success,
      );
      expect(state().biometricConfigured, isFalse);
      expect(fake.deleteCalls, 1);
      expect(state().biometricStatus?.hasKey, isFalse);
    });

    test('清密成功：清空生物状态并销毁原生密钥', () async {
      final fake = _FakeBiometricService();
      await seedBiometric();
      final notifier = await boot(biometricService: fake);

      expect(
        await notifier.clearPassword(password: 'pw'),
        PrivacyClearPasswordResult.success,
      );
      expect(state().hasPassword, isFalse);
      expect(state().biometricConfigured, isFalse);
      expect(fake.deleteCalls, 1);
    });
  });
}
