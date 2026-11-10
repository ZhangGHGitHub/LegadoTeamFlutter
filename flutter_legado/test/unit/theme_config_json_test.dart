// [批13 回修 | 2026-11-10] 主题 JSON 导出→导入往返单测 — 全栈工程师 + UI
//
// 覆盖审查要求的「export→import 新字段往返」：导出 payload 经 JSON 编码/
// 解码后走导入解码 + applyColors，断言 12 槽字段值真实传递（不只键名一致），
// 并覆盖旧 JSON 缺字段、非数值容错、themeMode 往返与 0=未设置清除口径。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/constants/pref_keys.dart';
import 'package:flutter_legado/src/providers/theme/theme_colors_notifier.dart';
import 'package:flutter_legado/src/services/theme_config_json.dart';

const _source = ThemeColorsState(
  primary: 0xFF010203,
  accent: 0xFF040506,
  background: 0xFF070809,
  bottomBackground: 0xFF0A0B0C,
  primaryNight: 0xFF0D0E0F,
  accentNight: 0xFF101112,
  backgroundNight: 0xFF131415,
  bottomBackgroundNight: 0xFF161718,
  primaryTextColor: 0xFF191A1B,
  secondaryTextColor: 0xFF1C1D1E,
  primaryTextColorNight: 0xFF1F2021,
  secondaryTextColorNight: 0xFF222324,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<ProviderContainer> loadedContainer() async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(themeColorsProvider);
    await pumpEventQueue();
    return container;
  }

  test('导出→JSON 编解码→导入：12 槽字段值真实往返', () async {
    final payload = ThemeConfigJson.buildExportPayload(
      colors: _source,
      paletteId: 'koharu',
      themeMode: ThemeMode.dark,
    );
    // 模拟真实文件往返：JsonEncoder → 字符串 → jsonDecode
    final decoded = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    expect(decoded['paletteId'], 'koharu');
    expect(decoded['themeMode'], 'dark');

    final container = await loadedContainer();
    await container
        .read(themeColorsProvider.notifier)
        .applyColors(ThemeConfigJson.decodeColors(decoded));
    final state = container.read(themeColorsProvider);

    expect(state.primary, _source.primary);
    expect(state.accent, _source.accent);
    expect(state.background, _source.background);
    expect(state.bottomBackground, _source.bottomBackground);
    expect(state.primaryNight, _source.primaryNight);
    expect(state.accentNight, _source.accentNight);
    expect(state.backgroundNight, _source.backgroundNight);
    expect(state.bottomBackgroundNight, _source.bottomBackgroundNight);
    expect(state.primaryTextColor, _source.primaryTextColor);
    expect(state.secondaryTextColor, _source.secondaryTextColor);
    expect(state.primaryTextColorNight, _source.primaryTextColorNight);
    expect(state.secondaryTextColorNight, _source.secondaryTextColorNight);

    // 解析后的有效值也必须一致（夜间独立值优先）
    expect(
      state.effectivePrimaryTextColor(Brightness.light),
      _source.primaryTextColor,
    );
    expect(
      state.effectivePrimaryTextColor(Brightness.dark),
      _source.primaryTextColorNight,
    );
  });

  test('旧版主题 JSON（无字体色字段）解码为 null → 按 0 清除，不报错', () {
    final decoded = <String, dynamic>{
      'paletteId': 'def',
      'themeMode': 'light',
      'day': <String, dynamic>{
        'primary': 0xFF112233,
        'accent': 0xFF223344,
        'background': 0xFFF5F5F5,
        'bottomBackground': 0xFFEEEEEE,
      },
      'night': <String, dynamic>{
        'primary': 0xFF332211,
        'accent': 0xFF443322,
        'background': 0xFF101010,
        'bottomBackground': 0xFF202020,
      },
    };
    final colors = ThemeConfigJson.decodeColors(decoded);
    expect(colors[PrefKeys.cPrimary], 0xFF112233);
    expect(colors[PrefKeys.cPrimaryText], isNull);
    expect(colors[PrefKeys.cSecondaryText], isNull);
    expect(colors[PrefKeys.cNPrimaryText], isNull);
    expect(colors[PrefKeys.cNSecondaryText], isNull);
  });

  test('缺组/非数值/浮点数容错：null 或截断，不抛异常', () {
    final colors = ThemeConfigJson.decodeColors(<String, dynamic>{
      'day': <String, dynamic>{'primary': 3.9, 'primaryText': 'not-a-color'},
      // night 组整体缺失
    });
    expect(colors[PrefKeys.cPrimary], 3);
    expect(colors[PrefKeys.cPrimaryText], isNull);
    expect(colors[PrefKeys.cNPrimary], isNull);
    expect(colors[PrefKeys.cNSecondaryText], isNull);
    expect(ThemeConfigJson.asInt(null), isNull);
    expect(ThemeConfigJson.asInt('x'), isNull);
  });

  test('themeMode 三种合法值与未知值', () {
    for (final mode in <ThemeMode>[
      ThemeMode.system,
      ThemeMode.light,
      ThemeMode.dark,
    ]) {
      final name = ThemeConfigJson.themeModeName(mode);
      expect(ThemeConfigJson.themeModeFromName(name), mode);
    }
    expect(ThemeConfigJson.themeModeName(ThemeMode.dark), 'dark');
    expect(ThemeConfigJson.themeModeFromName('sepia'), isNull);
    expect(ThemeConfigJson.themeModeFromName(null), isNull);
  });

  test('导出 0 值 → 导入解码 → applyColors 清除（0=未设置）', () async {
    const cleared = ThemeColorsState(
      primaryTextColor: 0,
      secondaryTextColor: 0,
      primaryTextColorNight: 0,
      secondaryTextColorNight: 0,
    );
    final payload = ThemeConfigJson.buildExportPayload(
      colors: cleared,
      paletteId: 'def',
      themeMode: ThemeMode.system,
    );
    final decoded = jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    final container = await loadedContainer();
    final notifier = container.read(themeColorsProvider.notifier);
    await notifier.applyColors(<String, int?>{
      PrefKeys.cPrimaryText: 0xFF2196F3,
      PrefKeys.cSecondaryText: 0xFF445566,
    });
    expect(container.read(themeColorsProvider).primaryTextColor, 0xFF2196F3);

    await notifier.applyColors(ThemeConfigJson.decodeColors(decoded));
    final state = container.read(themeColorsProvider);
    expect(state.primaryTextColor, 0);
    expect(state.secondaryTextColor, 0);
    expect(
      state.effectivePrimaryTextColor(Brightness.light),
      ThemeColorsState.defaultPrimaryTextColor,
    );
  });
}
