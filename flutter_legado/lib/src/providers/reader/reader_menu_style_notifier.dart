// 阅读器菜单样式加载/保存（批3a）
//
// 持久化键逐字对齐参考版 `PreferKey`（见 PrefKeys 批3a 段落）；
// 随 Flutter JSON 备份 `appPrefs` 往返，并加入
// `RestoreIgnorePrefs.readPrefKeys`（「忽略阅读配置」过滤）。
//
// 竞态防护沿用 ReaderTopBarActionsNotifier 的 generation/lifecycle 写法：
// - lifecycle：Riverpod invalidate 后同一个 Notifier 实例会重建，旧的
//   `_load` 必须识别自己已不是当前生命周期；
// - generation：异步加载返回前用户已改配置时，丢弃旧持久化值。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;

import '../../constants/pref_keys.dart';
import '../../providers/providers.dart' show settingsProvider;
import '../../services/settings_service.dart';
import '../../widgets/reader/reader_menu_style.dart';

/// 阅读器菜单样式 Notifier：启动异步加载 + 修改即时保存
class ReaderMenuStyleNotifier extends Notifier<ReaderMenuStyle> {
  /// 变更代数：异步加载返回时若用户已改配置，丢弃旧值
  int _generation = 0;

  /// 构建生命周期序号（同 ReaderTopBarActionsNotifier）
  int _lifecycle = 0;

  /// 当前生命周期是否仍存活
  bool _alive = false;

  @override
  ReaderMenuStyle build() {
    final lifecycle = ++_lifecycle;
    _alive = true;
    ref.onDispose(() {
      if (lifecycle != _lifecycle) return;
      _alive = false;
      _lifecycle++;
    });
    // 捕获调度时代数：microtask 执行前用户若已改配置，加载结果必须丢弃
    final generation = _generation;
    Future.microtask(() => _load(lifecycle, generation));
    return ReaderMenuStyle.defaults();
  }

  bool _isAlive(int lifecycle) => _alive && lifecycle == _lifecycle;

  SettingsService get _settings => ref.read(settingsProvider);

  Future<void> _load(int lifecycle, int generation) async {
    if (!_isAlive(lifecycle)) return;
    final settings = _settings;

    // 旧键迁移：仅当新键缺失时读取 readBarStyleFollowPage（true→1/false→0）；
    // 旧键未设置则保留默认（1），不得把「缺失」误判为 false→0。
    var readBarStyle = await settings.getIntPrefOrNull(PrefKeys.readBarStyle);
    if (readBarStyle == null) {
      final legacy = await settings.getBoolPrefOrNull(
        PrefKeys.readBarStyleFollowPage,
      );
      if (legacy != null) {
        readBarStyle = legacy
            ? ReaderMenuBarStyle.followPage
            : ReaderMenuBarStyle.system;
        await settings.setIntPref(PrefKeys.readBarStyle, readBarStyle);
      }
    }

    final style = ReaderMenuStyle(
      showIconText:
          await settings.getBoolPrefOrNull(PrefKeys.readMenuIconShowText) ??
          false,
      itemsPerRow:
          await settings.getIntPrefOrNull(PrefKeys.readMenuIconItemsPerRow) ??
          5,
      rowCount:
          await settings.getIntPrefOrNull(PrefKeys.readMenuIconRowCount) ?? 1,
      iconStyle:
          await settings.getIntPrefOrNull(PrefKeys.readMenuIconStyle) ?? 0,
      floatingBottomBar:
          await settings.getBoolPrefOrNull(
            PrefKeys.readMenuFloatingBottomBar,
          ) ??
          true,
      bottomCornerRadius:
          await settings.getIntPrefOrNull(
            PrefKeys.readMenuBottomCornerRadius,
          ) ??
          32,
      readBarStyle: readBarStyle ?? ReaderMenuBarStyle.followPage,
      colorMode:
          await settings.getIntPrefOrNull(PrefKeys.readMenuColorMode) ?? 1,
      paletteStyle: await settings.getStringPref(
        PrefKeys.readMenuPaletteStyle,
        defaultValue: '',
      ),
      bgColor: await settings.getIntPrefOrNull(PrefKeys.readMenuBgColor) ?? 0,
      bgColorNight:
          await settings.getIntPrefOrNull(PrefKeys.readMenuBgColorNight) ?? 0,
      accentColor:
          await settings.getIntPrefOrNull(PrefKeys.readMenuAccentColor) ?? 0,
      accentColorNight:
          await settings.getIntPrefOrNull(PrefKeys.readMenuAccentColorNight) ??
          0,
      containerColor:
          await settings.getIntPrefOrNull(PrefKeys.readMenuContainerColor) ?? 0,
      containerColorNight:
          await settings.getIntPrefOrNull(
            PrefKeys.readMenuContainerColorNight,
          ) ??
          0,
      textColor:
          await settings.getIntPrefOrNull(PrefKeys.readMenuTextColor) ?? 0,
      textColorNight:
          await settings.getIntPrefOrNull(PrefKeys.readMenuTextColorNight) ?? 0,
      titleCapsule:
          await settings.getBoolPrefOrNull(
            PrefKeys.readMenuTopBarTitleCapsule,
          ) ??
          false,
      titleBarMode: await settings.getStringPref(
        PrefKeys.titleBarMode,
        defaultValue: ReaderMenuTitleBarMode.inTopBar,
      ),
      mergeButtons:
          await settings.getBoolPrefOrNull(
            PrefKeys.readMenuTopBarMergeButtons,
          ) ??
          false,
      titleIconStyle:
          await settings.getIntPrefOrNull(PrefKeys.titleBarIconStyle) ?? 0,
    );

    if (!_isAlive(lifecycle) || generation != _generation) return;
    state = style;
  }

  /// 更新状态并记录代数（阻止在途加载覆盖）
  void _apply(ReaderMenuStyle next) {
    _generation++;
    state = next;
  }

  Future<void> _saveBool(String key, bool value) =>
      _settings.setBoolPref(key, value);

  Future<void> _saveInt(String key, int value) =>
      _settings.setIntPref(key, value);

  Future<void> _saveString(String key, String value) =>
      _settings.setStringPref(key, value);

  void setShowIconText(bool value) {
    _apply(state.copyWith(showIconText: value));
    unawaited(_saveBool(PrefKeys.readMenuIconShowText, value));
  }

  void setItemsPerRow(int value) {
    final next = state.copyWith(itemsPerRow: value);
    _apply(next);
    unawaited(_saveInt(PrefKeys.readMenuIconItemsPerRow, next.itemsPerRow));
  }

  void setRowCount(int value) {
    final next = state.copyWith(rowCount: value);
    _apply(next);
    unawaited(_saveInt(PrefKeys.readMenuIconRowCount, next.rowCount));
  }

  void setIconStyle(int value) {
    final next = state.copyWith(iconStyle: value);
    _apply(next);
    unawaited(_saveInt(PrefKeys.readMenuIconStyle, next.iconStyle));
  }

  void setFloatingBottomBar(bool value) {
    _apply(state.copyWith(floatingBottomBar: value));
    unawaited(_saveBool(PrefKeys.readMenuFloatingBottomBar, value));
  }

  void setBottomCornerRadius(int value) {
    final next = state.copyWith(bottomCornerRadius: value);
    _apply(next);
    unawaited(
      _saveInt(PrefKeys.readMenuBottomCornerRadius, next.bottomCornerRadius),
    );
  }

  void setReadBarStyle(int value) {
    final next = state.copyWith(readBarStyle: value);
    _apply(next);
    unawaited(_saveInt(PrefKeys.readBarStyle, next.readBarStyle));
  }

  void setColorMode(int value) {
    final next = state.copyWith(colorMode: value);
    _apply(next);
    unawaited(_saveInt(PrefKeys.readMenuColorMode, next.colorMode));
  }

  void setPaletteStyle(String value) {
    _apply(state.copyWith(paletteStyle: value));
    unawaited(_saveString(PrefKeys.readMenuPaletteStyle, value));
  }

  void setBgColor(int value, {required bool isNight}) {
    final next = isNight
        ? state.copyWith(bgColorNight: value)
        : state.copyWith(bgColor: value);
    _apply(next);
    unawaited(
      _saveInt(
        isNight ? PrefKeys.readMenuBgColorNight : PrefKeys.readMenuBgColor,
        next.bgColorFor(isNight),
      ),
    );
  }

  void setAccentColor(int value, {required bool isNight}) {
    final next = isNight
        ? state.copyWith(accentColorNight: value)
        : state.copyWith(accentColor: value);
    _apply(next);
    unawaited(
      _saveInt(
        isNight
            ? PrefKeys.readMenuAccentColorNight
            : PrefKeys.readMenuAccentColor,
        next.accentColorFor(isNight),
      ),
    );
  }

  void setContainerColor(int value, {required bool isNight}) {
    final next = isNight
        ? state.copyWith(containerColorNight: value)
        : state.copyWith(containerColor: value);
    _apply(next);
    unawaited(
      _saveInt(
        isNight
            ? PrefKeys.readMenuContainerColorNight
            : PrefKeys.readMenuContainerColor,
        next.containerColorFor(isNight),
      ),
    );
  }

  void setTextColor(int value, {required bool isNight}) {
    final next = isNight
        ? state.copyWith(textColorNight: value)
        : state.copyWith(textColor: value);
    _apply(next);
    unawaited(
      _saveInt(
        isNight ? PrefKeys.readMenuTextColorNight : PrefKeys.readMenuTextColor,
        next.textColorFor(isNight),
      ),
    );
  }

  void setTitleCapsule(bool value) {
    _apply(state.copyWith(titleCapsule: value));
    unawaited(_saveBool(PrefKeys.readMenuTopBarTitleCapsule, value));
  }

  void setTitleBarMode(String value) {
    final next = state.copyWith(titleBarMode: value);
    _apply(next);
    unawaited(_saveString(PrefKeys.titleBarMode, next.titleBarMode));
  }

  void setMergeButtons(bool value) {
    _apply(state.copyWith(mergeButtons: value));
    unawaited(_saveBool(PrefKeys.readMenuTopBarMergeButtons, value));
  }

  void setTitleIconStyle(int value) {
    final next = state.copyWith(titleIconStyle: value);
    _apply(next);
    unawaited(_saveInt(PrefKeys.titleBarIconStyle, next.titleIconStyle));
  }

  /// 恢复默认并整体落盘
  Future<void> restoreDefaults() async {
    final defaults = ReaderMenuStyle.defaults();
    _apply(defaults);
    final settings = _settings;
    await settings.setBoolPref(
      PrefKeys.readMenuIconShowText,
      defaults.showIconText,
    );
    await settings.setIntPref(
      PrefKeys.readMenuIconItemsPerRow,
      defaults.itemsPerRow,
    );
    await settings.setIntPref(PrefKeys.readMenuIconRowCount, defaults.rowCount);
    await settings.setIntPref(PrefKeys.readMenuIconStyle, defaults.iconStyle);
    await settings.setBoolPref(
      PrefKeys.readMenuFloatingBottomBar,
      defaults.floatingBottomBar,
    );
    await settings.setIntPref(
      PrefKeys.readMenuBottomCornerRadius,
      defaults.bottomCornerRadius,
    );
    await settings.setIntPref(PrefKeys.readBarStyle, defaults.readBarStyle);
    await settings.setIntPref(PrefKeys.readMenuColorMode, defaults.colorMode);
    await settings.setStringPref(
      PrefKeys.readMenuPaletteStyle,
      defaults.paletteStyle,
    );
    await settings.setIntPref(PrefKeys.readMenuBgColor, defaults.bgColor);
    await settings.setIntPref(
      PrefKeys.readMenuBgColorNight,
      defaults.bgColorNight,
    );
    await settings.setIntPref(
      PrefKeys.readMenuAccentColor,
      defaults.accentColor,
    );
    await settings.setIntPref(
      PrefKeys.readMenuAccentColorNight,
      defaults.accentColorNight,
    );
    await settings.setIntPref(
      PrefKeys.readMenuContainerColor,
      defaults.containerColor,
    );
    await settings.setIntPref(
      PrefKeys.readMenuContainerColorNight,
      defaults.containerColorNight,
    );
    await settings.setIntPref(PrefKeys.readMenuTextColor, defaults.textColor);
    await settings.setIntPref(
      PrefKeys.readMenuTextColorNight,
      defaults.textColorNight,
    );
    await settings.setBoolPref(
      PrefKeys.readMenuTopBarTitleCapsule,
      defaults.titleCapsule,
    );
    await settings.setStringPref(PrefKeys.titleBarMode, defaults.titleBarMode);
    await settings.setBoolPref(
      PrefKeys.readMenuTopBarMergeButtons,
      defaults.mergeButtons,
    );
    await settings.setIntPref(
      PrefKeys.titleBarIconStyle,
      defaults.titleIconStyle,
    );
  }
}

/// 阅读器菜单样式 Provider
final readerMenuStyleProvider =
    NotifierProvider<ReaderMenuStyleNotifier, ReaderMenuStyle>(
      ReaderMenuStyleNotifier.new,
    );
