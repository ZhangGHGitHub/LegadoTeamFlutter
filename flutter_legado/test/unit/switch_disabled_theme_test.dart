// [批2b-2a P3 | 2026-11-03] 禁用 Switch 置灰主题回归
//
// 背景：AppTheme 显式声明 SwitchThemeData 时只判断 selected，导致
// `onChanged:null` 的选中开关仍显示 primary（启用）配色。导航 Sheet 中
// 书架/我的「始终显示」开关因此看起来可用。本测试锁定 disabled 优先。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/theme/app_theme.dart';

void main() {
  test('disabled 选中态使用置灰 thumb/track，启用的选中态仍为 primary', () {
    for (final theme in <ThemeData>[AppTheme.light, AppTheme.dark]) {
      final switchTheme = theme.switchTheme;
      final cs = theme.colorScheme;
      final disabledStates = <WidgetState>{
        WidgetState.disabled,
        WidgetState.selected,
      };

      expect(
        switchTheme.thumbColor!.resolve(disabledStates),
        cs.onSurface.withValues(alpha: 0.38),
      );
      expect(
        switchTheme.trackColor!.resolve(disabledStates),
        cs.onSurface.withValues(alpha: 0.12),
      );

      // 启用态不受影响
      expect(
        switchTheme.thumbColor!.resolve(const <WidgetState>{
          WidgetState.selected,
        }),
        cs.onPrimary,
      );
      expect(
        switchTheme.trackColor!.resolve(const <WidgetState>{
          WidgetState.selected,
        }),
        cs.primary,
      );
    }
  });
}
