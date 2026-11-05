// 书架布局配置 Notifier（设置批6a-1）
//
// 单一数据源：书架页面与配置 Sheet 均 watch 本 Provider；写入即持久化
// 到 SharedPreferences（键名逐字对齐参考版 PreferKey），随既有 JSON
// 备份 `appPrefs` 往返，并受「忽略书架布局」恢复项过滤。
//
// 旧键迁移：`bookshelf_layout`（我方历史 bool）或 `bookshelfLayout`
// （参考版旧 Android bool）仅在两个新方向键都缺失时读取一次：
// true → 网格 / false → 列表，横竖屏同时写入，随后不再读取旧键。
//
// 编写：全栈工程师（设置批6a-1） ｜ 2026-11-06
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/bookshelf_settings.dart';

/// 书架布局配置 Notifier
///
/// [build] 同步返回参考版默认值，异步加载持久化值（加载完成后才允许
/// [update] 写入，避免首帧用户操作与加载竞态互相覆盖）。
class BookshelfSettingsNotifier extends Notifier<BookshelfSettings> {
  Future<void>? _loading;

  @override
  BookshelfSettings build() {
    _loading = _load();
    return BookshelfSettings.defaults;
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = <String, Object?>{
        for (final key in BookshelfSettings.prefKeys)
          if (prefs.containsKey(key)) key: prefs.get(key),
      };
      var loaded = BookshelfSettings.fromPrefMap(stored);

      // [审查 P2] 旧键按方向逐一迁移（仅该方向新键缺失时）：
      // 兼容历史 bool / 0-1 int / "true"/"false" 字符串，避免旧备份
      // 类型不同导致 getBool 抛错或迁移被静默跳过。
      final legacy = _legacyBool(
            prefs.get(BookshelfSettings.legacyLayoutKey),
          ) ??
          _legacyBool(
            prefs.get(BookshelfSettings.legacyAndroidLayoutKey),
          );
      if (legacy != null) {
        final mode = legacy ? 1 : 0;
        final writes = <String, int>{};
        if (!prefs.containsKey(
            BookshelfSettings.keyBookshelfLayoutModePortrait)) {
          writes[BookshelfSettings.keyBookshelfLayoutModePortrait] = mode;
        }
        if (!prefs.containsKey(
            BookshelfSettings.keyBookshelfLayoutModeLandscape)) {
          writes[BookshelfSettings.keyBookshelfLayoutModeLandscape] = mode;
        }
        if (writes.containsKey(
            BookshelfSettings.keyBookshelfLayoutModePortrait)) {
          loaded = loaded.copyWith(bookshelfLayoutModePortrait: mode);
        }
        if (writes.containsKey(
            BookshelfSettings.keyBookshelfLayoutModeLandscape)) {
          loaded = loaded.copyWith(bookshelfLayoutModeLandscape: mode);
        }
        for (final entry in writes.entries) {
          await prefs.setInt(entry.key, entry.value);
        }
      }
      state = loaded;
    } catch (e) {
      // 偏好损坏/平台插件异常 → 回落参考默认值，保证书架可渲染
      debugPrint('[BookshelfSettingsNotifier] 加载失败，回落默认值: $e');
      state = BookshelfSettings.defaults;
    }
  }

  /// 旧布局键宽松布尔解析（bool / int / string，无法识别返回 null）
  static bool? _legacyBool(Object? value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case '1':
          return true;
        case 'false':
        case '0':
          return false;
      }
    }
    return null;
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
      BookshelfSettings Function(BookshelfSettings current) transform) async {
    await waitForLoad();
    final previous = state;
    final next = transform(previous).normalized();
    if (next == previous) return;
    state = next;

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
      }
    }
  }

  /// 单字段便捷入口（配置 Sheet 用；语义同 [update]）
  Future<void> setValue(
          BookshelfSettings Function(BookshelfSettings current) transform) =>
      update(transform);
}

/// 书架布局配置 Provider（默认参考版默认值）
final bookshelfSettingsProvider =
    NotifierProvider<BookshelfSettingsNotifier, BookshelfSettings>(
  BookshelfSettingsNotifier.new,
);
