// [GLOBALCOMP B3] 输入框形态回归：参考版实测「填充盒 + 底部指示线」。
//
// 裁决依据（QA 参考版实测 + 主代理像素复核，2026-10-01）：
// - 未聚焦：填充盒 + 深色细底线（实测 (75,71,57) ≈ 调色板 onSurfaceVariant，
//   而非浅色的 outlineVariant）；
// - 聚焦：底线变主题色、加粗约 2dp；
// - 填充盒顶角 4dp 圆、底角直角；四边（含顶边）无描边。
//
// Flutter 侧对应 UnderlineInputBorder（只画底线，borderRadius 同时定义填充
// 盒形状）。本测试锁死该形态：任何把 focusedBorder 改回 OutlineInputBorder
// （四边整圈描边，即 B3 要修掉的偏离形态）的改动都会红。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/theme/app_theme.dart';

void main() {
  /// 参考版实测的填充盒形状：顶角 4dp 圆、底角直角。
  const expectedRadius = BorderRadius.vertical(top: Radius.circular(4));

  final themes = <String, ThemeData>{
    'light': AppTheme.light,
    'dark': AppTheme.dark,
  };

  for (final MapEntry(key: label, value: theme) in themes.entries) {
    final deco = theme.inputDecorationTheme;
    final scheme = theme.colorScheme;

    group('inputDecorationTheme B3 形态（$label）', () {
      test('填充盒：filled + surfaceContainerHighest 底', () {
        expect(deco.filled, isTrue);
        expect(deco.fillColor, scheme.surfaceContainerHighest);
      });

      test('未聚焦（border/enabledBorder）：深色细底线，四边无描边', () {
        for (final (name, border) in [
          ('border', deco.border),
          ('enabledBorder', deco.enabledBorder),
        ]) {
          expect(
            border,
            isA<UnderlineInputBorder>(),
            reason: '$name 应为只画底线的 UnderlineInputBorder',
          );
          expect(
            border,
            isNot(isA<OutlineInputBorder>()),
            reason: '$name 不得是四边整圈描边的 OutlineInputBorder',
          );
          final underline = border! as UnderlineInputBorder;
          expect(
            underline.borderSide.color,
            scheme.onSurfaceVariant,
            reason: '$name 未聚焦底线应为深色 onSurfaceVariant（参考版实测）',
          );
          expect(underline.borderSide.width, 1, reason: '$name 未聚焦底线为 1dp 细线');
          expect(
            underline.borderRadius,
            expectedRadius,
            reason: '$name 形状应为上圆下直',
          );
        }
      });

      test('聚焦（focusedBorder）：主题色 2dp 底线，顶圆底直', () {
        final border = deco.focusedBorder;
        expect(border, isA<UnderlineInputBorder>());
        expect(
          border,
          isNot(isA<OutlineInputBorder>()),
          reason: '聚焦态不得回到四边描边（B3 核心偏离项）',
        );
        final underline = border! as UnderlineInputBorder;
        expect(underline.borderSide.color, scheme.primary);
        expect(underline.borderSide.width, 2);
        expect(underline.borderRadius.topLeft, const Radius.circular(4));
        expect(underline.borderRadius.topRight, const Radius.circular(4));
        expect(underline.borderRadius.bottomLeft, Radius.zero);
        expect(underline.borderRadius.bottomRight, Radius.zero);
      });

      test('生效链：无局部覆盖的字段解析为底线式（isOutline=false）', () {
        final merged = const InputDecoration(hintText: 'h').applyDefaults(deco);
        expect(merged.border, isA<UnderlineInputBorder>());
        expect(
          merged.border!.isOutline,
          isFalse,
          reason: 'isOutline=false 才走 M3 填充式标签上浮/内缩定位',
        );
        expect(
          (merged.border! as UnderlineInputBorder).borderRadius,
          expectedRadius,
        );
      });

      testWidgets('经 MaterialApp 落到真实字段：未聚焦解析出深色底线', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: const Scaffold(body: TextField()),
          ),
        );
        final context = tester.element(find.byType(TextField));
        final resolved = Theme.of(context).inputDecorationTheme;
        expect(resolved.enabledBorder, isA<UnderlineInputBorder>());
        expect(
          (resolved.enabledBorder! as UnderlineInputBorder).borderSide.color,
          Theme.of(context).colorScheme.onSurfaceVariant,
        );
      });
    });
  }
}
