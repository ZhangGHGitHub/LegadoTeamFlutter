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
/// - 登录凭据经 BookApi.putLoginInfo/putLoginHeader 持久化到 Rust
///   `source_login_cache`（`userInfo_<url>` / `loginHeader_<url>`），
///   请求路径自动合并 loginHeader（对齐原版 BaseSource.getHeaderMap 语义）。
///   —— 2026-08-14 发现页修复 R1：原 config 键 `source_login_<url>` 无消费方，
///   已改存 source_login_cache（旧 config 键数据在 load 时回退迁移）。
/// - 管理 UI 状态（loading/saving/error + 凭据列表）。
/// - 不含任何业务逻辑（凭据仅为透传存储）。
class SourceLoginNotifier extends Notifier<SourceLoginState> {
  /// 旧配置键前缀（历史数据回退迁移用）
  static const _keyPrefix = 'source_login_';

  @override
  SourceLoginState build() => const SourceLoginState();

  /// 加载指定书源已保存的登录信息
  ///
  /// 优先读 `source_login_cache`（userInfo_/loginHeader_）；为空时回退
  /// 旧 config 键 `source_login_<url>`（历史数据迁移）。
  Future<void> load(String sourceUrl) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final api = ref.read(bookApiProvider);
      var infoJson = await api.getLoginInfo(sourceUrl);
      var headerJson = await api.getLoginHeader(sourceUrl);
      if (infoJson.isEmpty && headerJson.isEmpty) {
        // 回退旧 config 键（历史数据迁移）
        final raw = await api.getConfig(_keyPrefix + sourceUrl);
        if (raw != null && raw.isNotEmpty) {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          final migratedToken = data['token'] as String? ?? '';
          final migratedHeaders = <String, String>{
            for (final e in _parseEntries(data['headers'])) e.name: e.value,
          };
          final cookieStr = _parseEntries(data['cookies'])
              .map((e) => '${e.name}=${e.value}')
              .join('; ');
          if (cookieStr.isNotEmpty) migratedHeaders['Cookie'] = cookieStr;
          if (migratedToken.isNotEmpty) {
            infoJson = jsonEncode({'token': migratedToken});
          }
          headerJson = jsonEncode(migratedHeaders);
        }
      }
      if (infoJson.isEmpty && headerJson.isEmpty) {
        state = state.copyWith(isLoading: false);
        return;
      }
      state = state.copyWith(
        token: _extractToken(infoJson),
        cookies: _extractCookies(headerJson),
        headers: _extractHeaders(headerJson),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(error: _mapError(e), isLoading: false);
    }
  }

  /// 从 userInfo JSON 提取 token（含 token 字段则取之，否则原样作为 token）
  String _extractToken(String infoJson) {
    if (infoJson.isEmpty) return '';
    try {
      final info = jsonDecode(infoJson);
      if (info is Map<String, dynamic> && info['token'] is String) {
        return info['token'] as String;
      }
      return infoJson;
    } catch (_) {
      return infoJson;
    }
  }

  /// 从 loginHeader JSON 拆出 Cookie 键值对列表
  List<LoginKeyValue> _extractCookies(String headerJson) {
    if (headerJson.isEmpty) return const [];
    try {
      final map = jsonDecode(headerJson) as Map<String, dynamic>;
      final cookieStr = map.entries
          .firstWhere(
            (e) => e.key.toLowerCase() == 'cookie',
            orElse: () => const MapEntry('', ''),
          )
          .value
          .toString();
      if (cookieStr.isEmpty) return const [];
      return cookieStr
          .split(';')
          .map((pair) => pair.trim())
          .where((pair) => pair.contains('='))
          .map((pair) {
            final idx = pair.indexOf('=');
            return LoginKeyValue(
              name: pair.substring(0, idx).trim(),
              value: pair.substring(idx + 1).trim(),
            );
          })
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 从 loginHeader JSON 提取非 Cookie 的 header 键值对列表
  List<LoginKeyValue> _extractHeaders(String headerJson) {
    if (headerJson.isEmpty) return const [];
    try {
      final map = jsonDecode(headerJson) as Map<String, dynamic>;
      return map.entries
          .where((e) => e.key.toLowerCase() != 'cookie')
          .map((e) => LoginKeyValue(name: e.key, value: e.value.toString()))
          .toList();
    } catch (_) {
      return const [];
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

  /// 保存登录信息到 Rust `source_login_cache`
  ///
  /// - token → `userInfo_<url>`（putLoginInfo，供 JS getLoginInfo 读取）
  /// - headers + Cookie → `loginHeader_<url>`（putLoginHeader，请求路径自动合并，
  ///   对齐原版 BaseSource.putLoginHeader 语义）
  ///
  /// 失败时抛出异常，由 UI 侧展示错误提示。
  /// — DeepSeek Harness + UI（2026-08-14 发现页修复 R1）
  Future<void> save({
    required String sourceUrl,
    required String sourceName,
  }) async {
    state = state.copyWith(isSaving: true, error: null);
    try {
      final api = ref.read(bookApiProvider);

      // loginHeader：手动 headers + Cookie 合并（对齐原版 putLoginHeader map 格式）
      final headerMap = <String, String>{
        for (final e in state.headers)
          if (e.name.isNotEmpty) e.name: e.value,
      };
      final cookieStr = state.cookies
          .map((e) => '${e.name}=${e.value}')
          .join('; ');
      if (cookieStr.isNotEmpty) {
        headerMap['Cookie'] = cookieStr;
      }
      await api.putLoginHeader(sourceUrl, jsonEncode(headerMap));

      // userInfo：token 落库（对齐原版 putLoginInfo）
      await api.putLoginInfo(sourceUrl, jsonEncode({'token': state.token}));

      // 清理旧 config 键（迁移完成）
      try {
        await api.setConfig(_keyPrefix + sourceUrl, '');
      } catch (_) {}

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
