// MD3 调色板数据校验 + 12×亮暗全矩阵 WCAG AA 对比度自动化（UI_MD3_PLAN.md 第十三节）
//
// md3_colors.dart 由 tool/gen_md3_colors.py 从参考仓库
// HapeLee/legado-with-MD3@6dc297221a22e532354810fb2804592dd08e5a9d
// 的 colors.xml / colors_night.xml 生成，本测试固化锚点防止数据漂移。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/theme/md3_colors.dart';

/// WCAG 相对亮度（sRGB）
double _luminance(Color c) {
  double f(double v) =>
      v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

/// WCAG 对比度
double contrastRatio(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('Md3Palettes 数据完整性', () {
    test('共 12 套内置调色板，id 唯一且非空', () {
      expect(Md3Palettes.all.length, 12);
      final ids = Md3Palettes.all.map((p) => p.id).toSet();
      expect(ids.length, 12);
      for (final p in Md3Palettes.all) {
        expect(p.id, isNotEmpty);
        expect(p.label, isNotEmpty);
      }
    });

    test('默认调色板为 WH（UI_MD3_PLAN.md 第十六节）', () {
      expect(Md3Palettes.defaultId, 'wh');
      expect(Md3Palettes.all.first.id, 'wh');
      expect(Md3Palettes.byId('wh').id, 'wh');
    });

    test('未知 id 回退默认 WH（第九节回滚路径）', () {
      expect(Md3Palettes.byId('not_exists').id, 'wh');
      expect(Md3Palettes.byId('').id, 'wh');
    });

    test('seed 锚点 = 参考仓库亮色 colorPrimary', () {
      expect(Md3Palettes.wh.seed, 0xFF5C5C5C);
      expect(Md3Palettes.gr.seed, 0xFF4C662B);
      expect(Md3Palettes.koharu.seed, 0xFF8F4A4D);
      expect(Md3Palettes.sora.seed, 0xFF3B608F);
      for (final p in Md3Palettes.all) {
        expect(p.seed, p.light.primary);
      }
    });

    test('计划文档色值锚点（UI_MD3_PLAN.md 第五节表格）', () {
      // wh：DAY primary #5C5C5C / surface #F8F8F8 / onSurface #1C1B1B
      expect(Md3Palettes.wh.light.primary, 0xFF5C5C5C);
      expect(Md3Palettes.wh.light.surface, 0xFFF8F8F8);
      expect(Md3Palettes.wh.light.onSurface, 0xFF1C1B1B);
      // koharu：DAY primary #8F4A4D / surface #FFF8F7 / NIGHT surface #1A1111
      expect(Md3Palettes.koharu.light.primary, 0xFF8F4A4D);
      expect(Md3Palettes.koharu.light.surface, 0xFFFFF8F7);
      expect(Md3Palettes.koharu.dark.surface, 0xFF1A1111);
      expect(Md3Palettes.koharu.dark.onSurface, 0xFFF0DEDE);
      // sora：DAY primary #3B608F / surface #F8F9FF；NIGHT surface 深蓝调
      expect(Md3Palettes.sora.light.primary, 0xFF3B608F);
      expect(Md3Palettes.sora.light.surface, 0xFFF8F9FF);
      expect(Md3Palettes.sora.dark.surface, 0xFF111318);
    });

    test('各套亮/暗 primary 可辨（elink 墨水屏锚点为纯黑，登记例外）', () {
      for (final p in Md3Palettes.all) {
        // 亮暗 primary 不同（transparent 表面全透明，锚点恒黑，豁免）
        if (p.id != 'transparent') {
          expect(
            p.light.primary,
            isNot(equals(p.dark.primary)),
            reason: '${p.id} 亮暗 primary 不应完全相同',
          );
        }
      }
      // 10 套彩色主题亮色 primary 互不相同（防复制粘贴串色）；
      // elink（墨水屏）锚点即纯黑 #000000，与 transparent 相同，豁免。
      final colorful = Md3Palettes.all
          .where((p) => p.id != 'elink' && p.id != 'transparent')
          .map((p) => p.light.primary)
          .toSet();
      expect(colorful.length, 10);
    });
  });

  group('ColorScheme 构建', () {
    test('亮色 scheme primary 等于 seed，brightness 正确', () {
      for (final p in Md3Palettes.all) {
        final s = md3LightScheme(p);
        expect(s.brightness, Brightness.light);
        expect(s.primary.toARGB32(), p.seed);
        expect(s.surface.toARGB32(), p.light.surface);
        expect(s.onSurface.toARGB32(), p.light.onSurface);
      }
    });

    test('暗色 scheme 着色暗面（非纯黑 surface；elink/transparent 豁免）', () {
      for (final p in Md3Palettes.all) {
        // elink：墨水屏主题按参考仓库即为纯黑暗面（AMOLED 语义）；
        // transparent：表面全透明配合背景图。均豁免「着色非纯黑」断言。
        if (p.id == 'elink' || p.id == 'transparent') continue;
        final s = md3DarkScheme(p);
        expect(s.brightness, Brightness.dark);
        expect(
          s.surface,
          isNot(equals(const Color(0xFF000000))),
          reason: '${p.id} 暗面应为着色深灰（tonal，非纯黑）',
        );
      }
      // elink 暗面锚点固化：纯黑
      expect(
        md3DarkScheme(Md3Palettes.elink).surface,
        const Color(0xFF000000),
      );
    });
  });

  group('12×亮暗 WCAG AA 对比度全矩阵', () {
    // transparent 主题表面为全透明（配合背景图使用），对比度无意义，豁免；
    // 其余 11 套 × 亮/暗 = 22 个组合全量断言。
    final opaque = Md3Palettes.all.where((p) => p.id != 'transparent');

    /// 正文文本对（AA 4.5:1）
    void expectAA(Color on, Color bg, String tag) {
      expect(
        contrastRatio(on, bg),
        greaterThanOrEqualTo(4.5),
        reason: '$tag 对比度 ${contrastRatio(on, bg).toStringAsFixed(2)} < 4.5',
      );
    }

    for (final p in opaque) {
      test('${p.id} 亮色文本 role ≥ AA 4.5', () {
        final s = md3LightScheme(p);
        expectAA(s.onSurface, s.surface, '${p.id}/light onSurface-surface');
        expectAA(
          s.onSurfaceVariant,
          s.surface,
          '${p.id}/light onSurfaceVariant-surface',
        );
        expectAA(s.onPrimary, s.primary, '${p.id}/light onPrimary-primary');
        expectAA(
          s.onPrimaryContainer,
          s.primaryContainer,
          '${p.id}/light onPrimaryContainer-primaryContainer',
        );
        expectAA(
          s.onTertiaryContainer,
          s.tertiaryContainer,
          '${p.id}/light onTertiaryContainer-tertiaryContainer',
        );
        expectAA(
          s.onErrorContainer,
          s.errorContainer,
          '${p.id}/light onErrorContainer-errorContainer',
        );
        expectAA(
          s.onInverseSurface,
          s.inverseSurface,
          '${p.id}/light inverseOnSurface-inverseSurface',
        );
        for (final container in [
          s.surfaceContainerLowest,
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
          s.surfaceContainerHighest,
        ]) {
          expectAA(s.onSurface, container, '${p.id}/light onSurface-container');
        }
      });

      test('${p.id} 暗色文本 role ≥ AA 4.5', () {
        final s = md3DarkScheme(p);
        expectAA(s.onSurface, s.surface, '${p.id}/dark onSurface-surface');
        expectAA(
          s.onSurfaceVariant,
          s.surface,
          '${p.id}/dark onSurfaceVariant-surface',
        );
        expectAA(s.onPrimary, s.primary, '${p.id}/dark onPrimary-primary');
        expectAA(
          s.onPrimaryContainer,
          s.primaryContainer,
          '${p.id}/dark onPrimaryContainer-primaryContainer',
        );
        expectAA(
          s.onTertiaryContainer,
          s.tertiaryContainer,
          '${p.id}/dark onTertiaryContainer-tertiaryContainer',
        );
        expectAA(
          s.onErrorContainer,
          s.errorContainer,
          '${p.id}/dark onErrorContainer-errorContainer',
        );
        expectAA(
          s.onInverseSurface,
          s.inverseSurface,
          '${p.id}/dark inverseOnSurface-inverseSurface',
        );
        for (final container in [
          s.surfaceContainerLowest,
          s.surfaceContainerLow,
          s.surfaceContainer,
          s.surfaceContainerHigh,
          s.surfaceContainerHighest,
        ]) {
          expectAA(s.onSurface, container, '${p.id}/dark onSurface-container');
        }
      });
    }

    test('elink onSecondaryContainer 达 AA-large 3.0（参考仓库原始值 3.95，登记例外）', () {
      // 参考仓库 elink（墨水屏灰阶）secondaryContainer 对为 3.95，低于 4.5；
      // 逐字保留参考数据，按 AA-large/图标 3.0 下限守护。
      for (final mode in [md3LightScheme, md3DarkScheme]) {
        final s = mode(Md3Palettes.elink);
        expect(
          contrastRatio(s.onSecondaryContainer, s.secondaryContainer),
          greaterThanOrEqualTo(3.0),
        );
        expect(
          contrastRatio(s.onSecondaryContainer, s.secondaryContainer),
          lessThan(4.5),
        );
      }
    });

    test('其余 10 套 onSecondaryContainer ≥ AA 4.5', () {
      final others = opaque.where((p) => p.id != 'elink');
      for (final p in others) {
        for (final mode in [md3LightScheme, md3DarkScheme]) {
          final s = mode(p);
          expectAA(
            s.onSecondaryContainer,
            s.secondaryContainer,
            '${p.id} onSecondaryContainer-secondaryContainer',
          );
        }
      }
    });
  });
}
