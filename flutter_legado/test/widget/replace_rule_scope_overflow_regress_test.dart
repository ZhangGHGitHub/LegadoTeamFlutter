// [D2 缺陷回归 | full-stack-engineer + UI + QA]
//
// 缺陷 D2（轻微，设备验收批）：替换规则编辑页「作用范围」三勾选行
// （标题 / 书源（暂不支持）/ 正文）在 360dp 机型 + 系统字体放大
// （约 1.3 倍）时右溢出 18px（调试黄纹）。
// 根因：Row 内三个固定宽度子项（含长标签「书源（暂不支持）」）总宽
// 超出可用宽度，Row 无法收缩。
// 修复：Row → Wrap，按可用空间重排（宽屏单行形态不变，窄屏换行）。
// [B2-C2 2-9] 作用范围由勾选框改为 chips（Wrap + FilterChip）后同步本回归：
// 防溢出语义不变（Wrap 仍在），断言改查 chip 在位与选中态切换。
//
// 本测试在 360dp 画布 + textScaleFactor 1.3（对齐设备系统字体放大档）
// 下打开整页编辑器，断言：
// 1. 布局无 RenderFlex 溢出异常（修复前此处捕获
//    「A RenderFlex overflowed by N pixels to the right」）；
// 2. 三 chips 全部在位（换行后仍完整呈现；「书源」已于 2026-09-13 由
//    禁用标注改为可读写，见 [书源作用域]）；
// 3. chip 交互正常（默认选中的「正文」点击后取消）。
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

  group('D2 回归：作用范围 chips 360dp + 字体放大不溢出', () {
    testWidgets('窄屏 + 放大：无溢出异常，三 chips 在位且可交互',
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
      // [书源作用域 | 2026-09-13] 「书源」勾选已由禁用标注解除，
      // 标签由「书源（暂不支持）」改为「书源」（可读写并随保存落库）
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('书源'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);

      // ③ 仍可交互：「正文」chip（默认选中）点击后取消。
      // [B2-C2 2-9] 作用范围改 chips：按 FilterChip 标签定位断言 selected
      Finder scopeChip(String label) => find.byWidgetPredicate(
            (w) => w is FilterChip &&
                w.label is Text &&
                (w.label as Text).data == label,
          );

      final bodyChip = scopeChip('正文');
      expect(bodyChip, findsOneWidget, reason: '「正文」chip 应在位');
      expect(tester.widget<FilterChip>(bodyChip).selected, isTrue,
          reason: '「正文」默认选中');
      await tester.tap(bodyChip);
      await tester.pump();
      expect(
        tester.widget<FilterChip>(bodyChip).selected,
        isFalse,
        reason: '点击后「正文」应取消选中（交互正常）',
      );
      expect(tester.takeException(), isNull, reason: '交互后不应有异常');
    });
  });
}
