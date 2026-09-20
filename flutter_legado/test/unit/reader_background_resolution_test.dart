// [M1 深色态默认修复] 阅读背景默认解析纯函数单测
//
// 覆盖任务要求的四条行为：
// - 深色主题（未显式设置）→ 纯黑 0xFF000000（主题默认，对齐参考实测；
//   夜间预设 ReaderBackground.dark 0xFF1A1A1A 保留为显式选项）
// - 亮色主题（未显式设置）→ 白（原默认，行为不变）
// - 用户显式选择（自定义色 / 有效预设索引）→ 一律保留，不随主题变
// - 越界/负数索引视为「未设置」，回落到主题默认
//
// 纯函数无状态、无依赖，不需要 WidgetsBinding / SharedPreferences mock。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/providers/reader/reader_notifier.dart';

void main() {
  const custom = Color(0xFF232323);

  group('resolveReaderBackground 背景默认解析', () {
    test('深色主题 + 从未显式设置 → 深色默认（纯黑，对齐参考）', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.dark,
        storedBgIndex: null,
        customBgColor: null,
      );
      expect(resolved, equals(const Color(0xFF000000)));
    });

    test('亮色主题 + 从未显式设置 → 白色（原默认不变）', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.light,
        storedBgIndex: null,
        customBgColor: null,
      );
      expect(resolved, equals(ReaderBackground.white));
    });

    test('深色主题 + 显式预设索引 1 → 保留 green', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.dark,
        storedBgIndex: 1,
        customBgColor: null,
      );
      expect(resolved, equals(ReaderBackground.green));
    });

    test('亮色主题 + 显式预设索引 4（夜间）→ 保留 dark（尊重显式选择）',
        () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.light,
        storedBgIndex: 4,
        customBgColor: null,
      );
      expect(resolved, equals(ReaderBackground.dark));
    });

    test('显式索引 0（白色）在深色主题下 → 保留 white（显式 0 ≠ 未设置）',
        () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.dark,
        storedBgIndex: 0,
        customBgColor: null,
      );
      expect(resolved, equals(ReaderBackground.white));
    });

    test('深色主题 + 自定义背景色 → custom 优先', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.dark,
        storedBgIndex: null,
        customBgColor: custom,
      );
      expect(resolved, equals(custom));
    });

    test('自定义色与显式索引并存 → 自定义优先', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.dark,
        storedBgIndex: 1,
        customBgColor: custom,
      );
      expect(resolved, equals(custom));
    });

    test('深色主题 + 越界索引 99 → 视为未设置，回落深色默认（纯黑）', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.dark,
        storedBgIndex: 99,
        customBgColor: null,
      );
      expect(resolved, equals(const Color(0xFF000000)));
    });

    test('亮色主题 + 负数索引 → 视为未设置，回落白色', () {
      final resolved = resolveReaderBackground(
        themeBrightness: Brightness.light,
        storedBgIndex: -1,
        customBgColor: null,
      );
      expect(resolved, equals(ReaderBackground.white));
    });
  });

  group('themeBrightnessFor 主题模式 → 有效亮度', () {
    test('ThemeMode.light → light（无视平台亮度）', () {
      expect(
        themeBrightnessFor(ThemeMode.light, Brightness.dark),
        equals(Brightness.light),
      );
    });

    test('ThemeMode.dark → dark（无视平台亮度）', () {
      expect(
        themeBrightnessFor(ThemeMode.dark, Brightness.light),
        equals(Brightness.dark),
      );
    });

    test('ThemeMode.system → 透传平台亮度（dark）', () {
      expect(
        themeBrightnessFor(ThemeMode.system, Brightness.dark),
        equals(Brightness.dark),
      );
    });

    test('ThemeMode.system → 透传平台亮度（light）', () {
      expect(
        themeBrightnessFor(ThemeMode.system, Brightness.light),
        equals(Brightness.light),
      );
    });
  });
}
