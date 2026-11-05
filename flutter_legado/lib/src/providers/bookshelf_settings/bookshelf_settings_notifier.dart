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
    final prefs = await SharedPreferences.getInstance();
    final stored = <String, Object?>{
      for (final key in BookshelfSettings.prefKeys)
        if (prefs.containsKey(key)) key: prefs.get(key),
    };
    var loaded = BookshelfSettings.fromPrefMap(stored);

    // 旧 bool 键一次性迁移：两个新方向键都不存在才执行
    final hasNewDirectionKeys =
        prefs.containsKey(BookshelfSettings.keyBookshelfLayoutModePortrait) ||
            prefs.containsKey(
                BookshelfSettings.keyBookshelfLayoutModeLandscape);
    if (!hasNewDirectionKeys) {
      final legacy = prefs.getBool(BookshelfSettings.legacyLayoutKey) ??
          prefs.getBool(BookshelfSettings.legacyAndroidLayoutKey);
      if (legacy != null) {
        final mode = legacy ? 1 : 0;
        loaded = loaded.copyWith(
          bookshelfLayoutModePortrait: mode,
          bookshelfLayoutModeLandscape: mode,
        );
        // 横竖两套都写，之后用户再改任一方向互不影响
        await prefs.setInt(
            BookshelfSettings.keyBookshelfLayoutModePortrait, mode);
        await prefs.setInt(
            BookshelfSettings.keyBookshelfLayoutModeLandscape, mode);
      }
    }
    state = loaded;
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
