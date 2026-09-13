// [D2 缺陷回归 | full-stack-engineer + UI + QA]
//
// 缺陷 D2（轻微，设备验收批）：替换规则编辑页「作用范围」三勾选行
// （标题 / 书源（暂不支持）/ 正文）在 360dp 机型 + 系统字体放大
// （约 1.3 倍）时右溢出 18px（调试黄纹）。
// 根因：Row 内三个固定宽度子项（含长标签「书源（暂不支持）」）总宽
// 超出可用宽度，Row 无法收缩。
// 修复：Row → Wrap，按可用空间重排（宽屏单行形态不变，窄屏换行）。
//
// 本测试在 360dp 画布 + textScaleFactor 1.3（对齐设备系统字体放大档）
// 下打开整页编辑器，断言：
// 1. 布局无 RenderFlex 溢出异常（修复前此处捕获
//    「A RenderFlex overflowed by N pixels to the right」）；
// 2. 三勾选与禁用标注全部在位（换行后仍完整呈现）；
// 3. 勾选交互正常（默认勾选的「正文」点击后取消）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/replace_rule_edit_screen.dart';

import '../mocks/mocks.dart';

void main() {
  late MockRustApi mockApi;

  setUpAll(registerFallbacks);

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getReplaceRules()).thenAnswer((_) async => []);
  });

  group('D2 回归：作用范围三勾选行 360dp + 字体放大不溢出', () {
    testWidgets('窄屏 + 放大：无溢出异常，三勾选在位且可交互',
        (tester) async {
      // 360dp 画布（对齐 MuMu 设备逻辑宽度 360x740）
      await tester.binding.setSurfaceSize(const Size(360, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 系统字体放大 1.3 倍（对齐设备字体放大档，复现 18px 溢出条件）
      final testBinding = tester.binding;
      testBinding.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(
          testBinding.platformDispatcher.clearTextScaleFactorTestValue);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [bookApiProvider.overrideWithValue(mockApi)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    key: const Key('openBtn'),
                    onPressed: () => ReplaceRuleEditScreen.open(context),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('openBtn')));
      await tester.pumpAndSettle();

      // ① 无 RenderFlex 溢出（修复前此断言捕获溢出异常）
      expect(tester.takeException(), isNull,
          reason: '360dp + 字体放大 1.3 下不应出现布局溢出');

      // ② 三勾选全部在位（Wrap 换行后仍完整呈现，不裁切）
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('书源（暂不支持）'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);

      // ③ 仍可交互：「正文」勾选（默认 true）点击后取消。
      // 页内另有「使用正则表达式」勾选（同样默认 true），故按所在行定位：
      // 勾选行 = 含同标签 Text 的 Row，其下唯一 Checkbox 即目标
      Finder scopeCheckbox(String label) => find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is Row &&
                  w.children.any((c) => c is Text && c.data == label),
            ),
            matching: find.byType(Checkbox),
          );

      final bodyCheckbox = scopeCheckbox('正文');
      expect(bodyCheckbox, findsOneWidget, reason: '「正文」勾选应在位');
      expect(tester.widget<Checkbox>(bodyCheckbox).value, isTrue,
          reason: '「正文」默认勾选');
      await tester.tap(bodyCheckbox);
      await tester.pump();
      expect(
        tester.widget<Checkbox>(bodyCheckbox).value,
        isFalse,
        reason: '点击后「正文」应取消勾选（交互正常）',
      );
      expect(tester.takeException(), isNull, reason: '交互后不应有异常');
    });
  });
}
