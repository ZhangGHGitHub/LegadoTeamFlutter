// [GLOBALCOMP B3 尾项] 刻意无边框输入场的三态防渗入回归。
//
// 背景：B3 把输入框主题改为 filled 底线式（UnderlineInputBorder 三态，
// 见 input_theme_b3_test.dart）。只写 `border: InputBorder.none` 的字段，
// 其 enabled/focused 态会回退到主题 enabledBorder/focusedBorder——即
// 「未聚焦多一条细底线、聚焦底线加粗」。对刻意无边框的沉浸/胶囊/行内
// 字段（代码编辑、顶栏/弹层搜索、目录跳转等），必须显式声明
// border / enabledBorder / focusedBorder 三态均无边框。
//
// 本测试锁定补全模式：
// 1. 三个代表场（编辑区、沉浸搜索框、搜索胶囊）经真实渲染与解析链后，
//    enabled/focused/disabled/error 全态有效 border 均为 InputBorder.none；
// 2. 真实 SearchBarWidget（沉浸搜索胶囊）已显式三态无边框；
// 3. 对照组证明渗入面真实存在：仅写 border 的旧写法会回退主题底线式。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_legado/src/theme/app_theme.dart';
import 'package:flutter_legado/src/widgets/search_bar_widget.dart';

/// 补全后的三态无边框装饰器（10 处沉浸场的统一补法）。
const InputDecoration _sealedNone = InputDecoration(
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
);

/// 有效 border 解析顺序与 SDK InputDecorator `_getBorder` 一致：
/// error → disabled → focused → enabled，逐级回退到 border。
/// 在此复刻用于断言「全态解析结果」，不依赖 SDK 私有实现。
InputBorder _effectiveBorder(
  InputDecoration decoration, {
  bool focused = false,
  bool disabled = false,
  bool error = false,
}) {
  final InputBorder border = decoration.border!;
  if (error) {
    if (focused) {
      return decoration.focusedErrorBorder ?? decoration.errorBorder ?? border;
    }
    return decoration.errorBorder ?? border;
  }
  if (disabled) return decoration.disabledBorder ?? border;
  if (focused) return decoration.focusedBorder ?? border;
  return decoration.enabledBorder ?? border;
}

void main() {
  final themes = <String, ThemeData>{
    'light': AppTheme.light,
    'dark': AppTheme.dark,
  };

  for (final MapEntry(key: label, value: theme) in themes.entries) {
    group('刻意无边框场防渗入（$label）', () {
      testWidgets('三个代表场：真实渲染后有效 border 全态无边框', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: Column(
                children: [
                  // 场 1：代码/JS 编辑区（自造圆角底 + 无边框多行输入）
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const SizedBox(
                      height: 80,
                      child: TextField(
                        maxLines: null,
                        decoration: _sealedNone,
                      ),
                    ),
                  ),
                  // 场 2：顶栏/弹层沉浸搜索框（单行 dense）
                  const TextField(
                    decoration: InputDecoration(
                      hintText: '搜索',
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                  ),
                  // 场 3：搜索胶囊（圆角 24 容器内嵌输入）
                  Container(
                    height: 48,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: const TextField(
                      decoration: InputDecoration(
                        hintText: '搜索',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(vertical: 8),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );

        final decorators =
            tester.widgetList<InputDecorator>(find.byType(InputDecorator));
        expect(decorators.length, 3, reason: '三个代表场应各有一个输入装饰器');
        for (final decorator in decorators) {
          final resolved =
              decorator.decoration.applyDefaults(theme.inputDecorationTheme);
          for (final (state, border) in [
            ('enabled', _effectiveBorder(resolved)),
            ('focused', _effectiveBorder(resolved, focused: true)),
            ('disabled', _effectiveBorder(resolved, disabled: true)),
            ('error', _effectiveBorder(resolved, error: true)),
          ]) {
            expect(
              border,
              InputBorder.none,
              reason: '$state 态不得回退主题底线式/描边',
            );
          }
        }
      });

      testWidgets('真实 SearchBarWidget：胶囊输入三态显式无边框', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(body: SearchBarWidget(onChanged: (_) {})),
          ),
        );
        final decorator =
            tester.widget<InputDecorator>(find.byType(InputDecorator));
        final resolved =
            decorator.decoration.applyDefaults(theme.inputDecorationTheme);
        expect(resolved.border, InputBorder.none);
        expect(resolved.enabledBorder, InputBorder.none);
        expect(resolved.focusedBorder, InputBorder.none);
      });

      test('渗入面对照：仅写 border 的旧写法会回退主题底线式', () {
        const onlyBorder = InputDecoration(border: InputBorder.none);
        final resolved = onlyBorder.applyDefaults(theme.inputDecorationTheme);
        expect(resolved.enabledBorder, isA<UnderlineInputBorder>());
        expect(resolved.focusedBorder, isA<UnderlineInputBorder>());
      });
    });
  }
}
