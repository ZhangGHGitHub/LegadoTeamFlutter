// [批3a] 阅读器菜单样式模型 / 配色解析单元测试
//
// 覆盖：默认值、范围 clamp、encode/decode 往返、颜色三档
//（系统 / 跟随阅读背景 / 自定义）、自定义两来源（种子 / 自定义主题色）、
// 日夜分支、回落规则与 alpha 修正。
//
// 编写：全栈工程师（批3a） ｜ 2026-11-04
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/theme/theme_engine_parameterized.dart';
import 'package:flutter_legado/src/widgets/reader/reader_menu_style.dart';

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF6750A4));

  group('ReaderMenuStyle 默认值与 clamp', () {
    test('默认值对齐参考版 ReadSettings（titleBarMode 按批3a 口径为 0）', () {
      final style = ReaderMenuStyle.defaults();
      expect(style.showIconText, isFalse);
      expect(style.itemsPerRow, 5);
      expect(style.rowCount, 1);
      expect(style.iconStyle, 0);
      expect(style.floatingBottomBar, isTrue);
      expect(style.bottomCornerRadius, 32);
      expect(style.readBarStyle, 1);
      expect(style.colorMode, 1);
      expect(style.paletteStyle, '');
      expect(style.bgColor, 0);
      expect(style.accentColor, 0);
      expect(style.containerColor, 0);
      expect(style.textColor, 0);
      expect(style.titleCapsule, isFalse);
      expect(style.titleBarMode, '0');
      expect(style.mergeButtons, isFalse);
      expect(style.titleIconStyle, 0);
      expect(style.pageSize, 5);
    });

    test('越界值收敛到合法区间 / 非法标题模式回落 0', () {
      final style = ReaderMenuStyle(
        itemsPerRow: 99,
        rowCount: 0,
        iconStyle: 9,
        bottomCornerRadius: -3,
        readBarStyle: 7,
        colorMode: 9,
        titleIconStyle: -1,
        titleBarMode: '9',
      );
      expect(style.itemsPerRow, 8);
      expect(style.rowCount, 1);
      expect(style.iconStyle, 2);
      expect(style.bottomCornerRadius, 0);
      expect(style.readBarStyle, 2);
      expect(style.colorMode, 1);
      expect(style.titleIconStyle, 0);
      expect(style.titleBarMode, '0');

      final low = ReaderMenuStyle(
        itemsPerRow: 1,
        rowCount: -1,
        iconStyle: -4,
        bottomCornerRadius: 99,
        readBarStyle: -1,
        colorMode: -1,
        titleIconStyle: 3,
      );
      expect(low.itemsPerRow, 2);
      expect(low.rowCount, 1);
      expect(low.iconStyle, 0);
      expect(low.bottomCornerRadius, 32);
      expect(low.readBarStyle, 0);
      expect(low.colorMode, 0);
      expect(low.titleIconStyle, 2);
    });

    test('copyWith 同样走 clamp', () {
      final style = ReaderMenuStyle.defaults().copyWith(
        itemsPerRow: 100,
        rowCount: 5,
        bottomCornerRadius: -1,
      );
      expect(style.itemsPerRow, 8);
      expect(style.rowCount, 2);
      expect(style.bottomCornerRadius, 0);
    });
  });

  group('序列化', () {
    test('encode/decode 往返保持全部字段', () {
      final style = ReaderMenuStyle(
        showIconText: true,
        itemsPerRow: 3,
        rowCount: 2,
        iconStyle: 2,
        floatingBottomBar: false,
        bottomCornerRadius: 12,
        readBarStyle: 2,
        colorMode: 0,
        paletteStyle: 'vibrant',
        bgColor: 0xFF112233,
        bgColorNight: 0xFF223344,
        accentColor: 0xFF334455,
        accentColorNight: 0xFF445566,
        containerColor: 0xFF556677,
        containerColorNight: 0xFF667788,
        textColor: 0xFF778899,
        textColorNight: 0xFF8899AA,
        titleCapsule: true,
        titleBarMode: '2',
        mergeButtons: true,
        titleIconStyle: 1,
      );
      final decoded = decodeReaderMenuStyle(encodeReaderMenuStyle(style));
      expect(decoded.toJson(), style.toJson());
      expect(decoded.titleBarMode, '2');
      expect(decoded.itemsPerRow, 3);
      expect(decoded.showIconText, isTrue);
    });

    test('fromJson 宽松兼容字符串/布尔/数值', () {
      final style = ReaderMenuStyle.fromJson({
        'readMenuIconItemsPerRow': '4',
        'readMenuIconRowCount': 3,
        'readMenuIconShowText': 'true',
        'readBarStyle': '2',
        'readMenuTopBarMergeButtons': 1,
        'titleBarMode': '3',
      });
      expect(style.itemsPerRow, 4);
      expect(style.rowCount, 2);
      expect(style.showIconText, isTrue);
      expect(style.readBarStyle, 2);
      expect(style.mergeButtons, isTrue);
      expect(style.titleBarMode, '3');
    });

    test('空串/非法 JSON 回落默认', () {
      expect(
        decodeReaderMenuStyle(null).toJson(),
        ReaderMenuStyle.defaults().toJson(),
      );
      expect(
        decodeReaderMenuStyle('not-json').toJson(),
        ReaderMenuStyle.defaults().toJson(),
      );
    });
  });

  group('颜色规范化', () {
    test('0 保留为未设置；alpha=0 的纯 RGB 视为不透明；半透明拉满', () {
      expect(normalizeReaderMenuColor(0), 0);
      expect(normalizeReaderMenuColor(0x00112233), 0xFF112233);
      expect(normalizeReaderMenuColor(0x80112233), 0xFF112233);
      expect(normalizeReaderMenuColor(0xFF112233), 0xFF112233);
      expect(ReaderMenuStyle(bgColor: 0x00112233).bgColor, 0xFF112233);
    });

    test('paletteStyle 归一化（大小写/空串/未知）', () {
      expect(normalizeReaderMenuPaletteStyle(''), 'tonalSpot');
      expect(normalizeReaderMenuPaletteStyle('Vibrant'), 'vibrant');
      expect(normalizeReaderMenuPaletteStyle('fruitSalad'), 'fruitSalad');
      expect(normalizeReaderMenuPaletteStyle('FruitSalad'), 'fruitSalad');
      expect(normalizeReaderMenuPaletteStyle('unknown'), 'tonalSpot');
    });
  });

  group('resolveReaderMenuColors', () {
    test('readBarStyle=0：全部取系统 scheme', () {
      final style = ReaderMenuStyle(readBarStyle: 0);
      final colors = resolveReaderMenuColors(
        style: style,
        isDark: false,
        scheme: scheme,
        pageBackgroundColor: const Color(0xFF000000),
        pageTextColor: const Color(0xFFFFFFFF),
      );
      expect(colors.background, scheme.surfaceContainerHigh);
      expect(colors.container, scheme.surfaceContainerLow);
      expect(colors.accent, scheme.primary);
      expect(colors.text, scheme.onSurface);
      expect(colors.onSurface, scheme.onSurface);
      expect(colors.onSurfaceVariant, scheme.onSurfaceVariant);
    });

    test('readBarStyle=1：背景/容器/文字跟随阅读页，强调取主题 primary', () {
      final style = ReaderMenuStyle(readBarStyle: 1);
      const pageBg = Color(0xFF1A1A1A);
      const pageText = Color(0xFFCCCCCC);
      final colors = resolveReaderMenuColors(
        style: style,
        isDark: true,
        scheme: scheme,
        pageBackgroundColor: pageBg,
        pageTextColor: pageText,
      );
      expect(colors.background, pageBg);
      expect(
        colors.container,
        Color.alphaBlend(pageText.withValues(alpha: 0.08), pageBg),
        reason: '跟随阅读背景档容器 = 文字色 8% 混入背景（让色调底衬可见）',
      );
      expect(colors.text, pageText);
      expect(colors.onSurface, pageText);
      expect(colors.accent, scheme.primary);
    });

    test('readBarStyle=1 对比度不足时改用白字（WCAG < 4.5）', () {
      const text = Color(0xFF333333);
      for (final argb in [
        0xFF1A1A1A,
        0xFF263238,
        0xFF37474F,
        0xFF616161,
      ]) {
        final background = Color(argb);
        final colors = resolveReaderMenuColors(
          style: ReaderMenuStyle(readBarStyle: 1),
          isDark: true,
          scheme: scheme,
          pageBackgroundColor: background,
          pageTextColor: text,
        );
        expect(colors.text, const Color(0xFFFFFFFF), reason: '$background');
        final ratio = _contrastRatio(colors.text, background);
        expect(ratio, greaterThan(4.5), reason: '$background 对比度 $ratio');
      }
    });

    test('readBarStyle=1 棕/蓝灰预设保留 #333333（对比度达标不回退）', () {
      const text = Color(0xFF333333);
      // ReaderBackground.brown #D4A574（5.68:1）与 #90A4AE（4.88:1）
      for (final argb in [0xFFD4A574, 0xFF90A4AE]) {
        final background = Color(argb);
        final colors = resolveReaderMenuColors(
          style: ReaderMenuStyle(readBarStyle: 1),
          isDark: false,
          scheme: scheme,
          pageBackgroundColor: background,
          pageTextColor: text,
        );
        expect(colors.text, text, reason: '$background 应保留原文字色');
        expect(
          _contrastRatio(colors.text, background),
          greaterThanOrEqualTo(4.5),
          reason: '$background 对比度不得回退',
        );
      }
    });

    test('readBarStyle=1 亮底亮字同样改用黑字', () {
      final colors = resolveReaderMenuColors(
        style: ReaderMenuStyle(readBarStyle: 1),
        isDark: false,
        scheme: scheme,
        pageBackgroundColor: const Color(0xFFF5F5DC),
        pageTextColor: const Color(0xFFFFF9C4),
      );
      expect(colors.text, const Color(0xFF000000));
      expect(
        _contrastRatio(colors.text, const Color(0xFFF5F5DC)),
        greaterThan(4.5),
      );
    });

    test('readBarStyle=1 无阅读页色时回落系统样式', () {
      final colors = resolveReaderMenuColors(
        style: ReaderMenuStyle(readBarStyle: 1),
        isDark: false,
        scheme: scheme,
      );
      expect(colors.background, scheme.surfaceContainerHigh);
      expect(colors.text, scheme.onSurface);
    });

    test('readBarStyle=1 无阅读页文字色时按背景对比色', () {
      final colors = resolveReaderMenuColors(
        style: ReaderMenuStyle(readBarStyle: 1),
        isDark: false,
        scheme: scheme,
        pageBackgroundColor: const Color(0xFF000000),
      );
      expect(colors.text, const Color(0xFFFFFFFF));
    });

    test('readBarStyle=2 + 自定义：日/夜分别取对应键，0 回落', () {
      final style = ReaderMenuStyle(
        readBarStyle: 2,
        colorMode: 1,
        bgColor: 0x00112233,
        bgColorNight: 0xFFDDEEFF,
        accentColor: 0,
        textColor: 0,
      );
      final day = resolveReaderMenuColors(
        style: style,
        isDark: false,
        scheme: scheme,
      );
      expect(day.background, const Color(0xFF112233));
      expect(day.container, const Color(0xFF112233), reason: '容器 0 回落背景');
      expect(day.accent, scheme.primary, reason: '强调 0 回落主题 primary');
      expect(day.text, const Color(0xFFFFFFFF), reason: '深底用白字');

      final night = resolveReaderMenuColors(
        style: style,
        isDark: true,
        scheme: scheme,
      );
      expect(night.background, const Color(0xFFDDEEFF));
      expect(night.text, const Color(0xFF000000), reason: '浅底用黑字');
    });

    test('readBarStyle=2 + 自定义：独立容器/强调/文字色生效', () {
      final style = ReaderMenuStyle(
        readBarStyle: 2,
        colorMode: 1,
        bgColor: 0xFF101010,
        accentColor: 0xFF00AA00,
        containerColor: 0xFF202020,
        textColor: 0xFFEEEEEE,
      );
      final colors = resolveReaderMenuColors(
        style: style,
        isDark: false,
        scheme: scheme,
      );
      expect(colors.background, const Color(0xFF101010));
      expect(colors.container, const Color(0xFF202020));
      expect(colors.accent, const Color(0xFF00AA00));
      expect(colors.text, const Color(0xFFEEEEEE));
    });

    test('readBarStyle=2 + 种子色：按 palette 生成对应明暗 roles', () {
      const seed = 0xFF6750A4;
      final style = ReaderMenuStyle(
        readBarStyle: 2,
        colorMode: 0,
        paletteStyle: 'vibrant',
        accentColor: seed,
        accentColorNight: seed,
      );
      final expected = buildParameterizedRoles(
        style: 'vibrant',
        seed: seed,
        contrastLevel: 0,
      );
      final light = resolveReaderMenuColors(
        style: style,
        isDark: false,
        scheme: scheme,
      );
      expect(light.background, Color(expected.light.surfaceContainerHigh));
      expect(light.container, Color(expected.light.surfaceContainerLow));
      expect(light.accent, Color(expected.light.primary));
      expect(light.text, Color(expected.light.onSurface));

      final dark = resolveReaderMenuColors(
        style: style,
        isDark: true,
        scheme: scheme,
      );
      expect(dark.background, Color(expected.dark.surfaceContainerHigh));
      expect(dark.container, Color(expected.dark.surfaceContainerLow));
      expect(dark.accent, Color(expected.dark.primary));
      expect(dark.text, Color(expected.dark.onSurface));
    });

    test("paletteStyle='' 跟随应用 palette；非空用户选择优先", () {
      const seed = 0xFF6750A4;
      final style = ReaderMenuStyle(
        readBarStyle: 2,
        colorMode: 0,
        paletteStyle: '',
        accentColor: seed,
        accentColorNight: seed,
      );
      final appExpected = buildParameterizedRoles(
        style: 'vibrant',
        seed: seed,
        contrastLevel: 0,
      );
      final followed = resolveReaderMenuColors(
        style: style,
        isDark: false,
        scheme: scheme,
        appPaletteStyle: 'vibrant',
      );
      expect(
        followed.background,
        Color(appExpected.light.surfaceContainerHigh),
        reason: "paletteStyle='' 使用应用调色板 vibrant",
      );

      // 'none' / 未知值归一为 tonalSpot
      final tonalExpected = buildParameterizedRoles(
        style: 'tonalSpot',
        seed: seed,
        contrastLevel: 0,
      );
      final none = resolveReaderMenuColors(
        style: style,
        isDark: false,
        scheme: scheme,
        appPaletteStyle: 'none',
      );
      expect(none.background, Color(tonalExpected.light.surfaceContainerHigh));

      // 用户显式选择优先于应用调色板
      final userStyle = style.copyWith(paletteStyle: 'neutral');
      final neutralExpected = buildParameterizedRoles(
        style: 'neutral',
        seed: seed,
        contrastLevel: 0,
      );
      final user = resolveReaderMenuColors(
        style: userStyle,
        isDark: false,
        scheme: scheme,
        appPaletteStyle: 'vibrant',
      );
      expect(user.background, Color(neutralExpected.light.surfaceContainerHigh));
    });

    test('readBarStyle=2 自定义背景 0 时回落阅读页底色', () {
      final colors = resolveReaderMenuColors(
        style: ReaderMenuStyle(readBarStyle: 2, colorMode: 1),
        isDark: false,
        scheme: scheme,
        pageBackgroundColor: const Color(0xFFF5F5DC),
      );
      expect(colors.background, const Color(0xFFF5F5DC));
    });
  });
}

/// WCAG 对比度（1.0..21.0）
double _contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}
