import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../../models/models.dart';
import '../providers.dart';
import 'source_login_state.dart';

export 'source_login_state.dart';

/// 书源登录页 Riverpod Notifier
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 登录凭据（Token/Cookies/Headers）经 BookApi.getConfig/setConfig 持久化到
///   Rust 配置库，键为 `source_login_<sourceUrl>`，不再使用 SharedPreferences。
/// - 管理 UI 状态（loading/saving/error + 凭据列表）。
/// - 不含任何业务逻辑（凭据仅为透传存储）。
class SourceLoginNotifier extends Notifier<SourceLoginState> {
  /// 配置键前缀
  static const _keyPrefix = 'source_login_';

  @override
  SourceLoginState build() => const SourceLoginState();

  /// 加载指定书源已保存的登录信息
  Future<void> load(String sourceUrl) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final raw =
          await ref.read(bookApiProvider).getConfig(_keyPrefix + sourceUrl);
      if (raw == null || raw.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }
      final data = jsonDecode(raw) as Map<String, dynamic>;
      state = state.copyWith(
        token: data['token'] as String? ?? '',
        cookies: _parseEntries(data['cookies']),
        headers: _parseEntries(data['headers']),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 设置 Token
  void setToken(String token) {
    state = state.copyWith(token: token);
  }

  /// 添加 Cookie
  void addCookie(String name, String value) {
    state = state.copyWith(
      cookies: [...state.cookies, LoginKeyValue(name: name, value: value)],
    );
  }

  /// 删除指定下标的 Cookie
  void removeCookie(int index) {
    if (index < 0 || index >= state.cookies.length) return;
    final list = [...state.cookies]..removeAt(index);
    state = state.copyWith(cookies: list);
  }

  /// 添加 Header
  void addHeader(String name, String value) {
    state = state.copyWith(
      headers: [...state.headers, LoginKeyValue(name: name, value: value)],
    );
  }

  /// 删除指定下标的 Header
  void removeHeader(int index) {
    if (index < 0 || index >= state.headers.length) return;
    final list = [...state.headers]..removeAt(index);
    state = state.copyWith(headers: list);
  }

  /// 清空所有凭据（仅清状态，需配合 [save] 持久化）
  void clear() {
    state = state.copyWith(token: '', cookies: [], headers: []);
  }

  /// 保存登录信息到 Rust 配置库
  ///
  /// 失败时抛出异常，由 UI 侧展示错误提示。
  Future<void> save({
    required String sourceUrl,
    required String sourceName,
  }) async {
    state = state.copyWith(isSaving: true, error: null);
    try {
      final data = {
        'sourceUrl': sourceUrl,
        'sourceName': sourceName,
        'token': state.token,
        'cookies': state.cookies
            .map((e) => {'name': e.name, 'value': e.value})
            .toList(),
        'headers': state.headers
            .map((e) => {'name': e.name, 'value': e.value})
            .toList(),
        'savedAt': DateTime.now().toIso8601String(),
      };
      await ref
          .read(bookApiProvider)
          .setConfig(_keyPrefix + sourceUrl, jsonEncode(data));
      state = state.copyWith(isSaving: false);
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isSaving: false);
      rethrow;
    }
  }

  /// 解析键值对列表
  List<LoginKeyValue> _parseEntries(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .map(LoginKeyValue.fromJson)
        .toList();
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 书源登录 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(sourceLoginNotifierProvider);
/// ref.read(sourceLoginNotifierProvider.notifier).load(sourceUrl);
/// ```
final sourceLoginNotifierProvider =
    NotifierProvider<SourceLoginNotifier, SourceLoginState>(
  SourceLoginNotifier.new,
);
