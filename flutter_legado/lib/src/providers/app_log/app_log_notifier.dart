import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../bridge/ffi.dart';
import '../providers.dart';
import 'app_log_state.dart';

export 'app_log_state.dart';

/// 应用日志页 Riverpod Notifier
///
/// [审计修复 §1.2 第二批] 接通契约 §2.38 appLog* 五方法 — Qoder
///
/// 职责严格限定（对齐 UI_RESTRUCTURE_PLAN.md §0.2 铁律）：
/// - 调用 BookApi.appLog* → 接收纯数据 → 更新 immutable State
/// - JSON 解析在本层完成（UI 层仅消费类型化的 [AppLogEntry]）
/// - 对齐 Android 原版 AppLogDialog：message / crash / http 三级分页
class AppLogNotifier extends Notifier<AppLogState> {
  /// 支持的日志级别（对齐 Android AppLog.LOG_MESSAGE/LOG_CRASH/LOG_HTTP）
  static const levels = ['message', 'crash', 'http'];

  @override
  AppLogState build() => const AppLogState();

  /// 加载指定级别的日志列表（最新在前，由 Rust 侧保证）
  Future<void> load(String level) async {
    state = state.copyWith(
      currentLevel: level,
      isLoading: true,
      clearError: true,
    );
    try {
      final raw = await ref.read(bookApiProvider).appLogList(level: level);
      final list = _decode(raw);
      state = state.copyWith(logs: list, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        logs: const [],
        isLoading: false,
        error: _mapError(e),
      );
    }
  }

  /// 清空当前级别的日志，成功后刷新列表
  Future<void> clearCurrentLevel() async {
    final level = state.currentLevel;
    try {
      await ref.read(bookApiProvider).appLogClear(level: level);
      await load(level);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 清空全部级别日志（对齐 #543 清空确认后的 AppLog.clear + HttpLogStore.clear）
  Future<void> clearAll() async {
    try {
      await ref.read(bookApiProvider).appLogClearAll();
      await load(state.currentLevel);
    } catch (e) {
      state = state.copyWith(error: _mapError(e));
    }
  }

  /// 导出全部日志为格式化文本（时间升序，Rust 侧 64_000 字符截断）
  Future<String> export() async {
    return ref.read(bookApiProvider).appLogExport();
  }

  /// 解析日志 JSON 数组（容错：非法条目跳过）
  List<AppLogEntry> _decode(String raw) {
    if (raw.isEmpty || raw == 'null') return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(AppLogEntry.fromJson)
        .toList();
  }

  /// 统一错误映射
  String _mapError(Object e) {
    if (e is BridgeError) return e.message;
    return e.toString();
  }
}

/// 应用日志 Notifier 全局 Provider
///
/// 使用方式：
/// ```dart
/// final state = ref.watch(appLogNotifierProvider);
/// ref.read(appLogNotifierProvider.notifier).load('message');
/// ```
final appLogNotifierProvider = NotifierProvider<AppLogNotifier, AppLogState>(
  AppLogNotifier.new,
);
