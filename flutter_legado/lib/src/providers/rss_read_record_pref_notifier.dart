// RSS 阅读记录全局开关（批29）
//
// 对齐原版 `AppConfig.enableRssReadRecord`（`AppConfig.kt:631-635`，默认 true）：
// 关闭后 RSS 已读写入全部停止（`ReadRss.kt:51` 的写入前判定），已有记录保留，
// 重新开启恢复写入。持久化经 SharedPreferences（键
// `PrefKeys.enableRssReadRecord`），随既有备份 `appPrefs` 机制往返；
// 不新增 FFI/DB 契约（开关仅在 Dart 写入入口判定）。
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../constants/pref_keys.dart';
import '../services/settings_service.dart';

/// RSS 阅读记录开关 Notifier
///
/// 默认 true；[build] 同步返回默认值并异步加载持久化值（与
/// `MainPrefsNotifier` 同款加载模式）。
///
/// 写入门控必须用 [resolved]（等待异步加载完成）而不是直接读 `state`：
/// 进程首启后第一次打开文章时，`build` 的同步默认值 true 尚未被持久化的
/// false 覆盖，直接读 `state` 会漏判开关、多写一条记录。
class RssReadRecordPrefNotifier extends Notifier<bool> {
  final SettingsService _settings = SettingsService();

  /// 异步加载中的持久化值（[resolved] 等待它）
  Future<void>? _loading;

  /// 用户已显式设置过开关：加载完成时不得用旧持久化值覆盖
  bool _dirty = false;

  @override
  bool build() {
    _loading = _load();
    return true;
  }

  Future<void> _load() async {
    final loaded = await _settings.getBoolPref(
      PrefKeys.enableRssReadRecord,
      defaultValue: true,
    );
    if (!_dirty) state = loaded;
  }

  /// 解析实际开关值（异步加载未完成时先等待）
  ///
  /// 写入门控入口统一等待本方法，保证关闭态在进程首启时也不会漏判。
  Future<bool> resolved() async {
    final loading = _loading;
    if (loading != null) {
      await loading;
    }
    return state;
  }

  /// 设置开关并持久化
  Future<void> setEnabled(bool enabled) async {
    _dirty = true;
    state = enabled;
    await _settings.setBoolPref(PrefKeys.enableRssReadRecord, enabled);
  }
}

/// RSS 阅读记录开关全局 Provider（默认 true）
final rssReadRecordPrefProvider =
    NotifierProvider<RssReadRecordPrefNotifier, bool>(
  RssReadRecordPrefNotifier.new,
);
