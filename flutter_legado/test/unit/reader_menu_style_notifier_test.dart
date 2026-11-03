// [批3a] 阅读器菜单样式 Provider 测试
//
// 覆盖：启动加载、旧键 readBarStyleFollowPage 迁移、setter 即时落盘、
// 防陈旧加载覆盖、恢复默认、备份忽略列表纳入。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/reader/reader_menu_style_notifier.dart';
import 'package:flutter_legado/src/services/restore_ignore_prefs.dart';
import 'package:flutter_legado/src/services/settings_service.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_style.dart';

/// 延迟 readBarStyle 读取的服务：用于制造「加载在途 → 用户改配置」竞态
class _SlowReadBarStyleSettings extends SettingsService {
  final Completer<int?> gate = Completer<int?>();

  @override
  Future<int?> getIntPrefOrNull(String key) {
    if (key == PrefKeys.readBarStyle) return gate.future;
    return super.getIntPrefOrNull(key);
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('未持久化时先返回默认值，异步加载后仍为默认', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      container.read(readerMenuStyleProvider).toJson(),
      ReaderMenuStyle.defaults().toJson(),
    );
    await pumpEventQueue();
    expect(
      container.read(readerMenuStyleProvider).toJson(),
      ReaderMenuStyle.defaults().toJson(),
    );
  });

  test('启动加载全部键（含 clamp）', () async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readMenuIconShowText: true,
      PrefKeys.readMenuIconItemsPerRow: 99,
      PrefKeys.readMenuIconRowCount: 2,
      PrefKeys.readMenuIconStyle: 1,
      PrefKeys.readMenuFloatingBottomBar: false,
      PrefKeys.readMenuBottomCornerRadius: 12,
      PrefKeys.readBarStyle: 2,
      PrefKeys.readMenuColorMode: 0,
      PrefKeys.readMenuPaletteStyle: 'vibrant',
      PrefKeys.readMenuBgColor: 0xFF112233,
      PrefKeys.readMenuBgColorNight: 0xFF223344,
      PrefKeys.readMenuAccentColor: 0xFF334455,
      PrefKeys.readMenuAccentColorNight: 0xFF445566,
      PrefKeys.readMenuContainerColor: 0xFF556677,
      PrefKeys.readMenuContainerColorNight: 0xFF667788,
      PrefKeys.readMenuTextColor: 0xFF778899,
      PrefKeys.readMenuTextColorNight: 0xFF8899AA,
      PrefKeys.readMenuTopBarTitleCapsule: true,
      PrefKeys.titleBarMode: '2',
      PrefKeys.readMenuTopBarMergeButtons: true,
      PrefKeys.titleBarIconStyle: 2,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(readerMenuStyleProvider);
    await pumpEventQueue();

    final style = container.read(readerMenuStyleProvider);
    expect(style.showIconText, isTrue);
    expect(style.itemsPerRow, 8);
    expect(style.rowCount, 2);
    expect(style.iconStyle, 1);
    expect(style.floatingBottomBar, isFalse);
    expect(style.bottomCornerRadius, 12);
    expect(style.readBarStyle, 2);
    expect(style.colorMode, 0);
    expect(style.paletteStyle, 'vibrant');
    expect(style.bgColor, 0xFF112233);
    expect(style.bgColorNight, 0xFF223344);
    expect(style.accentColor, 0xFF334455);
    expect(style.accentColorNight, 0xFF445566);
    expect(style.containerColor, 0xFF556677);
    expect(style.containerColorNight, 0xFF667788);
    expect(style.textColor, 0xFF778899);
    expect(style.textColorNight, 0xFF8899AA);
    expect(style.titleCapsule, isTrue);
    expect(style.titleBarMode, '2');
    expect(style.mergeButtons, isTrue);
    expect(style.titleIconStyle, 2);
  });

  group('旧键 readBarStyleFollowPage 迁移', () {
    test('仅旧键 true → readBarStyle=1，并写新键', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyleFollowPage: true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(readerMenuStyleProvider);
      await pumpEventQueue();

      expect(container.read(readerMenuStyleProvider).readBarStyle, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.readBarStyle), 1);
      // 旧键保留（任务允许保留，不删除历史配置）
      expect(prefs.getBool(PrefKeys.readBarStyleFollowPage), isTrue);
    });

    test('仅旧键 false → readBarStyle=0', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyleFollowPage: false,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(readerMenuStyleProvider);
      await pumpEventQueue();

      expect(container.read(readerMenuStyleProvider).readBarStyle, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.readBarStyle), 0);
    });

    test('新旧键均缺失 → 保留默认 1（不得把缺失当 false 迁移）', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(readerMenuStyleProvider);
      await pumpEventQueue();

      expect(container.read(readerMenuStyleProvider).readBarStyle, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(PrefKeys.readBarStyle), isNull);
    });

    test('新键存在时旧键不参与（新键优先）', () async {
      SharedPreferences.setMockInitialValues({
        PrefKeys.readBarStyle: 2,
        PrefKeys.readBarStyleFollowPage: true,
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(readerMenuStyleProvider);
      await pumpEventQueue();

      expect(container.read(readerMenuStyleProvider).readBarStyle, 2);
    });
  });

  test('setter 即时更新状态并落盘（clamp 后写值）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(readerMenuStyleProvider);
    await pumpEventQueue();
    final notifier = container.read(readerMenuStyleProvider.notifier);

    notifier.setShowIconText(true);
    notifier.setItemsPerRow(99);
    notifier.setRowCount(0);
    notifier.setIconStyle(2);
    notifier.setFloatingBottomBar(false);
    notifier.setBottomCornerRadius(40);
    notifier.setReadBarStyle(2);
    notifier.setColorMode(0);
    notifier.setPaletteStyle('vibrant');
    notifier.setBgColor(0x00112233, isNight: false);
    notifier.setBgColor(0xFF223344, isNight: true);
    notifier.setAccentColor(0xFF334455, isNight: false);
    notifier.setAccentColor(0xFF445566, isNight: true);
    notifier.setTextColor(0xFF556677, isNight: false);
    notifier.setTitleCapsule(true);
    notifier.setTitleBarMode('9');
    notifier.setMergeButtons(true);
    notifier.setTitleIconStyle(3);
    await pumpEventQueue();

    final style = container.read(readerMenuStyleProvider);
    expect(style.itemsPerRow, 8);
    expect(style.rowCount, 1);
    expect(style.bottomCornerRadius, 32);
    expect(style.titleBarMode, '0');
    expect(style.titleIconStyle, 2);
    expect(style.bgColor, 0xFF112233, reason: 'alpha=0 的纯 RGB 不透明化');
    expect(style.bgColorNight, 0xFF223344);
    expect(style.accentColor, 0xFF334455);
    expect(style.accentColorNight, 0xFF445566);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PrefKeys.readMenuIconShowText), isTrue);
    expect(prefs.getInt(PrefKeys.readMenuIconItemsPerRow), 8);
    expect(prefs.getInt(PrefKeys.readMenuIconRowCount), 1);
    expect(prefs.getInt(PrefKeys.readMenuIconStyle), 2);
    expect(prefs.getBool(PrefKeys.readMenuFloatingBottomBar), isFalse);
    expect(prefs.getInt(PrefKeys.readMenuBottomCornerRadius), 32);
    expect(prefs.getInt(PrefKeys.readBarStyle), 2);
    expect(prefs.getInt(PrefKeys.readMenuColorMode), 0);
    expect(prefs.getString(PrefKeys.readMenuPaletteStyle), 'vibrant');
    expect(prefs.getInt(PrefKeys.readMenuBgColor), 0xFF112233);
    expect(prefs.getInt(PrefKeys.readMenuBgColorNight), 0xFF223344);
    expect(prefs.getInt(PrefKeys.readMenuAccentColor), 0xFF334455);
    expect(prefs.getInt(PrefKeys.readMenuTextColor), 0xFF556677);
    expect(prefs.getBool(PrefKeys.readMenuTopBarTitleCapsule), isTrue);
    expect(prefs.getString(PrefKeys.titleBarMode), '0');
    expect(prefs.getBool(PrefKeys.readMenuTopBarMergeButtons), isTrue);
    expect(prefs.getInt(PrefKeys.titleBarIconStyle), 2);
  });

  test('加载在途时用户修改：陈旧加载不得覆盖（generation 防竞态）', () async {
    SharedPreferences.setMockInitialValues({});
    final fake = _SlowReadBarStyleSettings();
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);
    container.read(readerMenuStyleProvider);
    // 加载尚未完成（readBarStyle 读取被 gate 挂起），用户先改一项
    container.read(readerMenuStyleProvider.notifier).setItemsPerRow(3);
    await pumpEventQueue();

    fake.gate.complete(2);
    await pumpEventQueue();

    final style = container.read(readerMenuStyleProvider);
    expect(style.itemsPerRow, 3, reason: '本次修改必须保留');
    expect(style.readBarStyle, 1, reason: '陈旧加载被丢弃，保持默认');
  });

  test('restoreDefaults 恢复默认并整体落盘', () async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readBarStyle: 2,
      PrefKeys.readMenuIconItemsPerRow: 2,
      PrefKeys.readMenuTopBarMergeButtons: true,
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(readerMenuStyleProvider);
    await pumpEventQueue();

    await container.read(readerMenuStyleProvider.notifier).restoreDefaults();
    await pumpEventQueue();

    expect(
      container.read(readerMenuStyleProvider).toJson(),
      ReaderMenuStyle.defaults().toJson(),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PrefKeys.readBarStyle), 1);
    expect(prefs.getInt(PrefKeys.readMenuIconItemsPerRow), 5);
    expect(prefs.getBool(PrefKeys.readMenuTopBarMergeButtons), isFalse);
  });

  test('新键全部纳入「忽略阅读配置」过滤列表', () {
    const keys = [
      PrefKeys.readMenuIconShowText,
      PrefKeys.readMenuIconItemsPerRow,
      PrefKeys.readMenuIconRowCount,
      PrefKeys.readMenuIconStyle,
      PrefKeys.readMenuFloatingBottomBar,
      PrefKeys.readMenuBottomCornerRadius,
      PrefKeys.readBarStyle,
      PrefKeys.readMenuColorMode,
      PrefKeys.readMenuPaletteStyle,
      PrefKeys.readMenuBgColor,
      PrefKeys.readMenuBgColorNight,
      PrefKeys.readMenuAccentColor,
      PrefKeys.readMenuAccentColorNight,
      PrefKeys.readMenuContainerColor,
      PrefKeys.readMenuContainerColorNight,
      PrefKeys.readMenuTextColor,
      PrefKeys.readMenuTextColorNight,
      PrefKeys.readMenuTopBarTitleCapsule,
      PrefKeys.titleBarMode,
      PrefKeys.readMenuTopBarMergeButtons,
      PrefKeys.titleBarIconStyle,
    ];
    for (final key in keys) {
      expect(
        RestoreIgnorePrefs.readPrefKeys,
        contains(key),
        reason: '$key 应随「忽略阅读配置」过滤',
      );
    }
  });

  test('新键默认随 appPrefs 备份，勾选忽略阅读配置时被过滤', () async {
    SharedPreferences.setMockInitialValues({
      PrefKeys.readMenuIconShowText: true,
      PrefKeys.readBarStyle: 2,
      PrefKeys.titleBarMode: '2',
    });
    final backup = await RestoreIgnorePrefs.collectForBackup(const {});
    expect(backup[PrefKeys.readMenuIconShowText], isTrue);
    expect(backup[PrefKeys.readBarStyle], 2);
    expect(backup[PrefKeys.titleBarMode], '2');

    final ignored = await RestoreIgnorePrefs.collectForBackup(const {
      'readConfig': true,
    });
    expect(ignored.containsKey(PrefKeys.readMenuIconShowText), isFalse);
    expect(ignored.containsKey(PrefKeys.readBarStyle), isFalse);
    expect(ignored.containsKey(PrefKeys.titleBarMode), isFalse);
  });
}
