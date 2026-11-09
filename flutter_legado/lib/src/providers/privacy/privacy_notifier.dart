// 隐私/应用锁 Notifier（设置批9b；审查回修 P1-1/P2-3/P3）
//
// 职责：
// - 加载/持久化隐私策略（键名逐字对齐参考版 PreferKey）并读取
//   Rust `privacyHasPassword`（凭据 salt/verifier 由 Rust 保管）；
// - 提供解锁（`unlock`）、只校验（`verifyPasswordOnly`）与会话锁定
//   （`lock`），供启动闸门、设置页验证闸门与 9c 阅读闸门复用；
// - 生命周期钩子：untilBackground 模式在离开后台超过宽限后自动 `lock`；
// - 设置/改密/清密：改密必须验旧密码；清密先验证再删除凭据。
//
// **fail-closed**：
// - 策略读取失败（store 异常/单键类型不符）记录 [PrivacyState.policyError]，
//   不回落默认值放行——启动闸门只显示「无法读取隐私设置」+ 重试；
// - `privacyHasPassword` 读取失败记录 [PrivacyState.credentialError]，启动
//   闸门只显示「无法读取隐私凭据」+ 重试；
// - 成功读到「无密码」时才回落关闭 enabled（避免无凭据锁死）。
//
// 编写：全栈工程师（设置批9b） ｜ 2026-11-09（审查回修同日）
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../constants/pref_keys.dart';
import '../providers.dart';
import 'privacy_state.dart';

/// 隐私设置 Provider
final privacyNotifierProvider = NotifierProvider<PrivacyNotifier, PrivacyState>(
  PrivacyNotifier.new,
);

/// 隐私策略持久化通道（可注入，便于测试写入/读取失败）
///
/// 读取严格按 key 判定类型：键缺失走默认值；键存在但类型不符/读取异常
/// 直接抛出，由 Notifier 记录 policyError（fail-closed），不静默回落默认。
class PrivacyPolicyStore {
  const PrivacyPolicyStore();

  Future<PrivacyPolicy> read() async {
    final prefs = await SharedPreferences.getInstance();
    final rawScope = _readString(prefs, PrefKeys.privateUnlockScope);
    final rawGrace = _readInt(prefs, PrefKeys.privateBackgroundGraceSeconds);
    return PrivacyPolicy(
      enabled: _readBool(prefs, PrefKeys.privateEnabled, false),
      verifyOnEnterGroup: _readBool(
        prefs,
        PrefKeys.privateVerifyOnEnterGroup,
        true,
      ),
      verifyOnOpenBook: _readBool(
        prefs,
        PrefKeys.privateVerifyOnOpenBook,
        true,
      ),
      verifyOnAppStart: _readBool(
        prefs,
        PrefKeys.privateVerifyOnAppStart,
        false,
      ),
      unlockScope: rawScope == null
          ? PrivacyUnlockScope.appSession
          : PrivacyUnlockScope.fromStorage(rawScope),
      backgroundGraceSeconds: rawGrace == null
          ? 0
          : (kPrivacyBackgroundGraceOptions.contains(rawGrace) ? rawGrace : 0),
    );
  }

  Future<bool> writeBool(String key, bool value) =>
      _write((prefs) => prefs.setBool(key, value));

  Future<bool> writeString(String key, String value) =>
      _write((prefs) => prefs.setString(key, value));

  Future<bool> writeInt(String key, int value) =>
      _write((prefs) => prefs.setInt(key, value));

  Future<bool> _write(
    Future<bool> Function(SharedPreferences prefs) action,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return await action(prefs);
    } catch (e) {
      debugPrint('[隐私] 写入隐私策略失败：$e');
      return false;
    }
  }

  static bool _readBool(SharedPreferences prefs, String key, bool fallback) {
    if (!prefs.containsKey(key)) return fallback;
    final value = prefs.get(key);
    if (value is bool) return value;
    throw FormatException('隐私策略 $key 类型不符：$value');
  }

  static String? _readString(SharedPreferences prefs, String key) {
    if (!prefs.containsKey(key)) return null;
    final value = prefs.get(key);
    if (value is String) return value;
    throw FormatException('隐私策略 $key 类型不符：$value');
  }

  static int? _readInt(SharedPreferences prefs, String key) {
    if (!prefs.containsKey(key)) return null;
    final value = prefs.get(key);
    if (value is int) return value;
    throw FormatException('隐私策略 $key 类型不符：$value');
  }
}

/// 隐私策略读取结果
@immutable
class PrivacyPolicy {
  const PrivacyPolicy({
    required this.enabled,
    required this.verifyOnEnterGroup,
    required this.verifyOnOpenBook,
    required this.verifyOnAppStart,
    required this.unlockScope,
    required this.backgroundGraceSeconds,
  });

  final bool enabled;
  final bool verifyOnEnterGroup;
  final bool verifyOnOpenBook;
  final bool verifyOnAppStart;
  final PrivacyUnlockScope unlockScope;
  final int backgroundGraceSeconds;
}

/// 策略持久化通道 Provider（测试可覆写为失败实现）
final privacyPolicyStoreProvider = Provider<PrivacyPolicyStore>(
  (ref) => const PrivacyPolicyStore(),
);

/// 隐私/应用锁 Notifier
class PrivacyNotifier extends Notifier<PrivacyState> {
  Future<void>? _loading;
  bool _disposed = false;

  /// 进入后台的时间（paused/hidden 首次触发时记录；resumed 判定后清空）
  DateTime? _backgroundedAt;

  PrivacyPolicyStore get _store => ref.read(privacyPolicyStoreProvider);

  @override
  PrivacyState build() {
    _disposed = false;
    ref.onDispose(() => _disposed = true);
    // build 内不能读 state（尚未初始化）；显式传入默认态作为读取基底
    _loading ??= _reload(const PrivacyState());
    return const PrivacyState();
  }

  /// 等待首次加载完成（测试与启动闸门重试可显式调用）
  Future<void> ensureLoaded() => _loading ??= _reload(state);

  void _set(PrivacyState next) {
    if (_disposed) return;
    state = next;
  }

  /// 读取策略 + 凭据（启动加载与错误页重试共用）
  Future<void> _reload(PrivacyState current) async {
    var next = current;
    String? policyError;
    String? credentialError;

    try {
      final policy = await _store.read();
      next = next.copyWith(
        enabled: policy.enabled,
        verifyOnEnterGroup: policy.verifyOnEnterGroup,
        verifyOnOpenBook: policy.verifyOnOpenBook,
        verifyOnAppStart: policy.verifyOnAppStart,
        unlockScope: policy.unlockScope,
        backgroundGraceSeconds: policy.backgroundGraceSeconds,
      );
    } catch (e) {
      // 策略未知：保留当前值并由启动闸门 fail-closed，绝不按默认值放行
      debugPrint('[隐私] 读取隐私策略失败（fail-closed）：$e');
      policyError = '无法读取隐私设置';
    }

    if (_disposed) return;
    try {
      final hasPassword = await ref.read(bookApiProvider).privacyHasPassword();
      next = next.copyWith(hasPassword: hasPassword);
      // 仅当策略成功读取且确实无密码时回落关闭 enabled；凭据读取失败会
      // 直接进入下方 catch（不改动开关，由启动闸门 fail-closed 拦截）。
      if (policyError == null && next.enabled && !hasPassword) {
        next = next.copyWith(enabled: false);
        await _store.writeBool(PrefKeys.privateEnabled, false);
      }
    } catch (e) {
      debugPrint('[隐私] 读取隐私凭据失败（fail-closed）：$e');
      credentialError = '无法读取隐私凭据';
    }

    _set(
      next.copyWith(
        policyError: policyError,
        credentialError: credentialError,
        loaded: true,
      ),
    );
  }

  /// 重读策略与凭据（启动闸门错误页的「重试」）
  ///
  /// 成功后清除对应错误标记；策略读取失败时保留当前策略值但持续
  /// [PrivacyState.policyError]，启动闸门继续 fail-closed。
  Future<void> retryCredentialCheck() => _reload(state);

  // ===== 解锁 / 锁定 =====

  /// 校验密码并解锁本次会话
  ///
  /// 成功：`sessionUnlocked = appStartVerified = true`；失败/异常：返回 false，
  /// 不改变既有解锁状态（防爆破不额外泄露信息）。
  Future<bool> unlock(String password) async {
    if (password.isEmpty) return false;
    bool ok;
    try {
      ok = await ref.read(bookApiProvider).privacyVerifyPassword(password);
    } catch (e) {
      debugPrint('[隐私] 校验密码异常（保持锁定）：$e');
      return false;
    }
    if (!ok) return false;
    _set(state.copyWith(sessionUnlocked: true, appStartVerified: true));
    return true;
  }

  /// 只校验密码，不改变会话/启动解锁标记（设置页验证闸门专用）
  ///
  /// 失败或异常返回 false；不写入任何状态，避免「进入设置页」被当成
  /// 已授权私密内容。
  Future<bool> verifyPasswordOnly(String password) async {
    if (password.isEmpty) return false;
    try {
      return await ref.read(bookApiProvider).privacyVerifyPassword(password);
    } catch (e) {
      debugPrint('[隐私] 设置页校验密码异常：$e');
      return false;
    }
  }

  /// 清除本次会话解锁状态（启动闸门后台失效、9c 离开阅读器时复用）
  void lock() {
    if (!state.sessionUnlocked && !state.appStartVerified) return;
    _set(state.copyWith(sessionUnlocked: false, appStartVerified: false));
  }

  /// 生命周期钩子（由启动闸门转发）
  ///
  /// - paused/hidden：记录进入后台时间（多次事件保留最早时间）；
  /// - resumed：仅 untilBackground 模式且已解锁时判定；宽限 0 立即锁定，
  ///   否则离台时长达到宽限后锁定；AppSession 模式后台不失效。
  ///
  /// [now] 仅测试注入虚拟时间；生产不传。
  void handleLifecycleState(AppLifecycleState lifecycleState, {DateTime? now}) {
    final at = now ?? DateTime.now();
    switch (lifecycleState) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        _backgroundedAt ??= at;
      case AppLifecycleState.resumed:
        final backgroundedAt = _backgroundedAt;
        _backgroundedAt = null;
        if (backgroundedAt == null) return;
        if (state.unlockScope != PrivacyUnlockScope.untilBackground) return;
        if (!state.sessionUnlocked) return;
        final graceSeconds = state.backgroundGraceSeconds;
        final elapsed = at.difference(backgroundedAt);
        if (graceSeconds <= 0 || elapsed >= Duration(seconds: graceSeconds)) {
          lock();
        }
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // inactive（来电/通知中心短暂失焦）不触发宽限计时
        break;
    }
  }

  // ===== 策略写入 =====

  /// 启用/关闭私密功能
  ///
  /// 开启前必须已有隐私密码（否则返回 false，由 UI 引导先设置密码）；
  /// 关闭只改开关，不清凭据与验证策略。写盘失败回滚内存状态并返回 false。
  Future<bool> setEnabled(bool value) async {
    if (value && !state.hasPassword) return false;
    if (state.enabled == value) return true;
    return _applyPolicy(
      state.copyWith(enabled: value),
      () => _store.writeBool(PrefKeys.privateEnabled, value),
    );
  }

  Future<bool> setVerifyOnEnterGroup(bool value) async {
    if (state.verifyOnEnterGroup == value) return true;
    return _applyPolicy(
      state.copyWith(verifyOnEnterGroup: value),
      () => _store.writeBool(PrefKeys.privateVerifyOnEnterGroup, value),
    );
  }

  Future<bool> setVerifyOnOpenBook(bool value) async {
    if (state.verifyOnOpenBook == value) return true;
    return _applyPolicy(
      state.copyWith(verifyOnOpenBook: value),
      () => _store.writeBool(PrefKeys.privateVerifyOnOpenBook, value),
    );
  }

  Future<bool> setVerifyOnAppStart(bool value) async {
    if (state.verifyOnAppStart == value) return true;
    return _applyPolicy(
      state.copyWith(verifyOnAppStart: value),
      () => _store.writeBool(PrefKeys.privateVerifyOnAppStart, value),
    );
  }

  Future<bool> setUnlockScope(PrivacyUnlockScope scope) async {
    if (state.unlockScope == scope) return true;
    return _applyPolicy(
      state.copyWith(unlockScope: scope),
      () => _store.writeString(PrefKeys.privateUnlockScope, scope.storageValue),
    );
  }

  Future<bool> setBackgroundGraceSeconds(int seconds) async {
    final normalized = kPrivacyBackgroundGraceOptions.contains(seconds)
        ? seconds
        : 0;
    if (state.backgroundGraceSeconds == normalized) return true;
    return _applyPolicy(
      state.copyWith(backgroundGraceSeconds: normalized),
      () => _store.writeInt(PrefKeys.privateBackgroundGraceSeconds, normalized),
    );
  }

  /// 乐观写入：写盘失败回滚到写入前状态并返回 false（UI 提示保存失败）
  Future<bool> _applyPolicy(
    PrivacyState next,
    Future<bool> Function() persist,
  ) async {
    final previous = state;
    _set(next);
    final ok = await persist();
    if (!ok) _set(previous);
    return ok;
  }

  // ===== 密码设置 / 修改 / 清除 =====

  /// 设置或修改隐私密码
  ///
  /// 已有凭据时 [oldPassword] 必须匹配（缺失/错误归为
  /// [PrivacyPasswordChangeResult.oldPasswordWrong]）；成功后置
  /// `hasPassword=true` 并清除会话/启动标记（改密后需重新解锁）。
  Future<PrivacyPasswordChangeResult> setPassword(
    String newPassword, {
    String? oldPassword,
  }) async {
    final trimmed = newPassword.trim();
    if (trimmed.isEmpty || trimmed.runes.length > 128) {
      return PrivacyPasswordChangeResult.invalidPassword;
    }
    final api = ref.read(bookApiProvider);
    final hadPassword = state.hasPassword;
    if (hadPassword) {
      final old = oldPassword ?? '';
      if (old.isEmpty) return PrivacyPasswordChangeResult.oldPasswordWrong;
      bool oldOk;
      try {
        oldOk = await api.privacyVerifyPassword(old);
      } catch (e) {
        debugPrint('[隐私] 校验旧密码异常：$e');
        return PrivacyPasswordChangeResult.failure;
      }
      if (!oldOk) return PrivacyPasswordChangeResult.oldPasswordWrong;
    }

    bool ok;
    try {
      ok = await api.privacySetPassword(
        newPassword,
        oldPassword: hadPassword ? oldPassword : null,
      );
    } catch (e) {
      debugPrint('[隐私] 设置密码异常：$e');
      return PrivacyPasswordChangeResult.failure;
    }
    if (!ok) return PrivacyPasswordChangeResult.failure;

    _set(
      state.copyWith(
        hasPassword: true,
        sessionUnlocked: false,
        appStartVerified: false,
      ),
    );
    return PrivacyPasswordChangeResult.success;
  }

  /// 清除隐私密码（先验证当前密码，再删除两键）
  ///
  /// 成功后 `hasPassword=false` 并清除会话解锁标记；**enabled 保持原值**，
  /// 由设置页提示并调用 [setEnabled] 关闭（避免无凭据锁死）。密码错误与
  /// API/写入失败分开返回，供 UI 区分提示。
  Future<PrivacyClearPasswordResult> clearPassword({
    required String password,
  }) async {
    if (password.isEmpty) {
      return PrivacyClearPasswordResult.passwordWrong;
    }
    final api = ref.read(bookApiProvider);
    bool verified;
    try {
      verified = await api.privacyVerifyPassword(password);
    } catch (e) {
      debugPrint('[隐私] 清除密码前校验异常：$e');
      return PrivacyClearPasswordResult.failure;
    }
    if (!verified) return PrivacyClearPasswordResult.passwordWrong;
    try {
      await api.privacyClearPassword();
    } catch (e) {
      debugPrint('[隐私] 清除密码异常：$e');
      return PrivacyClearPasswordResult.failure;
    }
    _set(
      state.copyWith(
        hasPassword: false,
        sessionUnlocked: false,
        appStartVerified: false,
      ),
    );
    return PrivacyClearPasswordResult.success;
  }
}
