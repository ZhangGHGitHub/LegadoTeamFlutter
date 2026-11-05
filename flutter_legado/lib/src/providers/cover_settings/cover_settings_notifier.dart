// 封面设置 Notifier（设置批6b-1）
//
// 单一数据源：封面设置页与 BookCover 渲染均读取本 Provider 的镜像
// [coverSettingsListenable]；写入即持久化到 SharedPreferences
// （键名逐字对齐参考版 PreferKey），随既有 JSON 备份 `appPrefs` 往返，
// 并受「忽略封面配置」恢复项过滤（`RestoreIgnorePrefs.coverPrefKeys`）。
//
// 与既有 UiSettings 的关系：「限制封面比例」键（coverRestrictRatio）在
// 批39 已由 UiSettings 消费（书架/发现/详情页封面自适应）。本 Notifier
// 复用同一个偏好键，并在变更时同步 UiSettingsNotifier（状态 + 全局
// ValueListenable + 持久化），避免两个内存态分叉；读取时同时把值镜像到
// [uiSettingsListenable]，保证无 ProviderScope 的通用组件（BookCover）
// 也能立即拿到正确值。
//
// 编写：全栈工程师（设置批6b-1） ｜ 2026-11-06
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/cover_settings.dart';
import '../ui_settings/ui_settings_notifier.dart';

/// 全局封面设置监听通道
///
/// BookCover 在大量列表/测试宿主中渲染，不要求外层存在 ProviderScope；
/// 经此 ValueListenable 订阅设置变化（与 [uiSettingsListenable] 同构）。
final ValueNotifier<CoverSettings> coverSettingsListenable =
    ValueNotifier<CoverSettings>(CoverSettings.defaults);

/// 封面设置 Notifier
///
/// [build] 同步返回参考版默认值，异步加载持久化值（加载完成后才允许
/// [update] 写入，避免首帧用户操作与加载竞态互相覆盖）。
class CoverSettingsNotifier extends Notifier<CoverSettings> {
  Future<void>? _loading;

  @override
  CoverSettings build() {
    _loading = _load();
    return CoverSettings.defaults;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = <String, Object?>{
        for (final key in CoverSettings.prefKeys)
          if (prefs.containsKey(key)) key: prefs.get(key),
      };
      final loaded = CoverSettings.fromPrefMap(stored);
      state = loaded;
      _sync();
    } catch (e) {
      // 偏好损坏/平台插件异常 → 回落参考默认值，保证书架可渲染
      debugPrint('[CoverSettingsNotifier] 加载失败，回落默认值: $e');
      state = CoverSettings.defaults;
      _sync();
    }
  }

  void _sync() {
    coverSettingsListenable.value = state;
    // 限制比例同时镜像到既有 UiSettings 监听通道（BookCover/书架/发现
    // 已消费该值；两个 Provider 读同一偏好键，此处只保证内存态一致）。
    final ui = uiSettingsListenable.value;
    if (ui.restrictCoverRatio != state.restrictCoverRatio) {
      uiSettingsListenable.value = ui.copyWith(
        restrictCoverRatio: state.restrictCoverRatio,
      );
    }
  }

  /// 等待持久化值加载完成（写入门控/测试用）
  Future<void> waitForLoad() async {
    final loading = _loading;
    if (loading != null) await loading;
  }

  /// 重新读取持久化值（备份恢复后同会话生效）
  Future<void> reload() async {
    _loading = _load();
    await _loading;
  }

  /// 原子更新并持久化发生变化的键
  Future<void> update(
    CoverSettings Function(CoverSettings current) transform,
  ) async {
    await waitForLoad();
    final previous = state;
    final next = transform(previous).normalized();
    if (next == previous) return;
    state = next;
    _sync();

    final prefs = await SharedPreferences.getInstance();
    final before = previous.toPrefMap();
    final after = next.toPrefMap();
    for (final entry in after.entries) {
      if (before[entry.key] == entry.value) continue;
      final value = entry.value;
      if (value is bool) {
        await prefs.setBool(entry.key, value);
      } else if (value is int) {
        await prefs.setInt(entry.key, value);
      } else if (value is String) {
        await prefs.setString(entry.key, value);
      }
    }

    // 限制比例：继续走 UiSettings 既有 setter（同步 provider 状态 +
    // ValueListenable + 持久化），使两处内存态不出现分叉。
    if (previous.restrictCoverRatio != next.restrictCoverRatio) {
      final ui = ref.read(uiSettingsProvider);
      if (ui.restrictCoverRatio != next.restrictCoverRatio) {
        await ref
            .read(uiSettingsProvider.notifier)
            .setRestrictCoverRatio(next.restrictCoverRatio);
      }
    }
  }

  /// 单字段便捷入口（设置页用；语义同 [update]）
  Future<void> setValue(
    CoverSettings Function(CoverSettings current) transform,
  ) => update(transform);
}

/// 封面设置 Provider（默认参考版默认值）
final coverSettingsProvider =
    NotifierProvider<CoverSettingsNotifier, CoverSettings>(
      CoverSettingsNotifier.new,
    );
