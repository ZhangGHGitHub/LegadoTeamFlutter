// [应用字体入口 | 2026-11-11] 应用界面字体状态（启动加载 / 导入 / 清除 /
// 失败回退） — 全栈工程师
//
// 与阅读正文字体完全分离：本 Notifier 只读写 [PrefKeys.appFontPath]，
// `reader_font_family` 由 ReaderPageView / FontScreen 自行管理。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../services/app_font_store.dart';

/// 应用字体状态（不可变）
class AppFontState {
  /// 相对 Support 目录的可迁移标识（null/空 = 未设置）
  final String? stored;

  /// 当前字体显示文件名（未设置时 null）
  final String? displayName;

  /// 已注册到引擎的字体族名（null = 使用系统默认字体）
  final String? family;

  /// 是否正在读取/加载（用于 UI 忙态）
  final bool loading;

  /// 是否已完成首次偏好读取（false = 启动加载中，避免把「已设置」
  /// 短暂显示成「未设置」）
  final bool initialized;

  /// 最近一次加载失败的中文提示（成功时为 null）
  final String? errorMessage;

  const AppFontState({
    this.stored,
    this.displayName,
    this.family,
    this.loading = false,
    this.initialized = false,
    this.errorMessage,
  });

  /// 是否已配置字体（文件可能加载失败）
  bool get isSet => stored != null && stored!.isNotEmpty;

  /// 自定义字体是否已成功生效
  bool get isActive => family != null && family!.isNotEmpty;
}

/// 导入结果（取消 / 成功 / 失败三态，供 UI 决定是否提示）
class AppFontImportOutcome {
  final bool canceled;
  final String? error;

  const AppFontImportOutcome._(this.canceled, this.error);

  const AppFontImportOutcome.canceled() : this._(true, null);

  const AppFontImportOutcome.success() : this._(false, null);

  const AppFontImportOutcome.failed(String message) : this._(false, message);
}

/// 应用字体 Notifier
class AppFontNotifier extends Notifier<AppFontState> {
  AppFontNotifier({this.loadTimeout = AppFontStore.defaultLoadTimeout});

  /// 单次加载超时（测试可注入短超时，避免真实等待 5s）
  final Duration loadTimeout;

  bool _disposed = false;

  /// 用户操作代数：异步加载返回时若代数已变化，丢弃旧结果，避免
  /// 「启动加载覆盖用户刚选的字体」/「清除后又被旧加载结果复活」。
  int _generation = 0;

  @override
  AppFontState build() {
    ref.onDispose(() => _disposed = true);
    final generation = _generation;
    Future.microtask(() => _initialize(generation));
    return const AppFontState();
  }

  Future<void> _initialize(int generation) async {
    String? stored;
    try {
      stored = await AppFontStore.readStoredIdentifier();
    } catch (_) {
      // 偏好不可用（测试环境/平台通道异常）：按未设置处理，不干扰界面
      if (!_disposed && generation == _generation) {
        state = const AppFontState(initialized: true);
      }
      return;
    }
    if (_disposed || generation != _generation) return;
    if (stored == null || stored.isEmpty) {
      state = const AppFontState(initialized: true);
      return;
    }
    await _load(stored, generation: generation);
  }

  /// 读取并加载指定字体；返回错误提示（成功为 null）
  Future<String?> _load(String stored, {required int generation}) async {
    final displayName = AppFontStore.displayNameOf(stored);
    state = AppFontState(
      stored: stored,
      displayName: displayName,
      loading: true,
      initialized: true,
    );
    final result = await AppFontStore.load(stored, timeout: loadTimeout);
    if (_disposed || generation != _generation) return null;
    if (result.isSuccess) {
      state = AppFontState(
        stored: stored,
        displayName: displayName,
        family: result.family,
        initialized: true,
      );
      return null;
    }
    state = AppFontState(
      stored: stored,
      displayName: displayName,
      errorMessage: result.errorMessage,
      initialized: true,
    );
    return result.errorMessage;
  }

  /// 选择并导入字体文件。取消返回 [AppFontImportOutcome.canceled]；
  /// 校验/选择失败返回 failed（旧字体保持不变）；成功返回 success。
  Future<AppFontImportOutcome> pickAndImport() async {
    AppFontPick? picked;
    try {
      picked = await AppFontStore.pick();
    } on FormatException catch (e) {
      return AppFontImportOutcome.failed(e.message);
    } on AppFontPickException catch (e) {
      return AppFontImportOutcome.failed(e.message);
    } catch (_) {
      return const AppFontImportOutcome.failed('无法打开系统文件选择器，请重试');
    }
    if (picked == null) return const AppFontImportOutcome.canceled();

    String stored;
    try {
      stored = await AppFontStore.importBytes(
        picked.bytes,
        originalName: picked.name,
      );
    } on FormatException catch (e) {
      return AppFontImportOutcome.failed(e.message);
    } catch (_) {
      return const AppFontImportOutcome.failed('字体导入失败，请重试');
    }
    final generation = ++_generation;
    final error = await _load(stored, generation: generation);
    return error == null
        ? const AppFontImportOutcome.success()
        : AppFontImportOutcome.failed(error);
  }

  /// 清除应用字体：删除自有文件 + 清偏好 + 立即回退默认字体
  Future<void> clear() async {
    final generation = ++_generation;
    final stored = state.stored;
    await AppFontStore.clear(stored: stored);
    if (_disposed || generation != _generation) return;
    state = const AppFontState(initialized: true);
  }

  /// 重新读取并加载（测试/调试用）
  Future<void> reload() async {
    final generation = ++_generation;
    final stored = await AppFontStore.readStoredIdentifier();
    if (_disposed || generation != _generation) return;
    if (stored == null || stored.isEmpty) {
      state = const AppFontState(initialized: true);
      return;
    }
    await _load(stored, generation: generation);
  }
}

/// 应用字体 Provider（MaterialApp 与外观页共同 watch）
final appFontProvider = NotifierProvider<AppFontNotifier, AppFontState>(
  AppFontNotifier.new,
);
