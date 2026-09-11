// 替换规则整页编辑器 widget 测试
//
// [A3 形态对齐 | full-stack-engineer + UI] 验证整页编辑器（对标原版
// ReplaceEditActivity + activity_replace_edit.xml）：
// - 整页渲染全部字段（名称/分组/匹配规则/替换为/作用范围勾选/特定范围/
//   排除范围/超时/预览输入输出）与顶栏（保存 + ⋮ 菜单）
// - 保存新规则时全字段传递给数据层并返回上一页
// - 正则语法校验拦截
// - 编辑模式回填已有规则
// - 复制规则 JSON / 粘贴规则填充表单（剪贴板通道 mock）
// - 预览防抖计算（非正则字面替换）
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:flutter_legado/src/models/models.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/providers/replace_rule/replace_rule_notifier.dart';
import 'package:flutter_legado/src/screens/replace_rule_edit_screen.dart';

import '../mocks/mocks.dart';

/// 按 decoration labelText 定位输入框（当前 flutter_test 未提供
/// find.byLabel，以 byWidgetPredicate 等价实现）
Finder byLabel(String label) {
  return find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
}

void main() {
  late MockRustApi mockApi;

  setUpAll(() {
    registerFallbacks();
  });

  setUp(() {
    mockApi = MockRustApi();
    when(() => mockApi.getReplaceRules()).thenAnswer((_) async => []);
  });

  /// 泵送宿主页并打开整页编辑器（Navigator push，与真实入口一致）
  Future<void> pumpEdit(
    WidgetTester tester, {
    ReplaceRule? rule,
    String? prefillPattern,
  }) async {
    // 高画布：整页字段较多，避免 ListView 懒加载裁掉下方字段
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [bookApiProvider.overrideWithValue(mockApi)],
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const Key('openBtn'),
                  onPressed: () => ReplaceRuleEditScreen.open(
                    context,
                    rule: rule,
                    prefillPattern: prefillPattern,
                  ),
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
  }

  /// mock 系统剪贴板通道（getData 返回 [clipboardText]；
  /// setData 记录写入文本）
  List<String> mockClipboard(
    WidgetTester tester, {
    String clipboardText = '',
  }) {
    final written = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        switch (call.method) {
          // SDK 3.44 的 Clipboard 通道方法名为 Clipboard.*（旧版为
          // SystemClipboard.*）；getData 返回 Map{'text': ...}（null=空）
          case 'Clipboard.setData':
            final args = call.arguments as Map<Object?, Object?>;
            written.add(args['text'] as String);
            return null;
          case 'Clipboard.getData':
            return clipboardText.isEmpty
                ? null
                : <String, dynamic>{'text': clipboardText};
          default:
            return null;
        }
      },
    );
    return written;
  }

  /// 打开顶栏 ⋮ 菜单并点击 [item]
  Future<void> tapMenu(WidgetTester tester, String item) async {
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await tester.pumpAndSettle();
  }

  group('ReplaceRuleEditScreen 整页编辑器', () {
    testWidgets('新建页渲染全部字段与顶栏', (tester) async {
      await pumpEdit(tester);

      // 顶栏与保存按钮
      expect(find.text('添加替换规则'), findsOneWidget);
      expect(find.text('保存'), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);
      // 字段（顺序对齐原版 layout：名称/分组/匹配规则/替换为/勾选/范围/排除/超时/预览）
      for (final label in const [
        '规则名称',
        '分组',
        '匹配规则',
        '使用正则表达式',
        '替换为',
        '书源（暂不支持）',
        '特定范围',
        '排除范围',
        '超时时间（毫秒）',
        '预览输入',
        '预览输出',
      ]) {
        expect(find.text(label), findsOneWidget, reason: '缺少字段：$label');
      }
      // 作用范围三勾选（书源禁用）
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('正文'), findsOneWidget);
      // 分组下拉默认「（无分组）」
      expect(find.text('（无分组）'), findsOneWidget);
      // 超时诚实标注（[A3 写链路补齐 2026-09-11] 超时已可编辑并随保存落库）
      expect(
        find.text('匹配/替换执行超时，空或非法输入回退 3000 毫秒'),
        findsOneWidget,
      );
      // ⋮ 菜单项（对标原版 menu：全屏编辑/复制规则/粘贴规则）
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      for (final item in const ['全屏编辑', '复制规则', '粘贴规则']) {
        expect(find.text(item), findsOneWidget, reason: '缺少菜单项：$item');
      }
    });

    testWidgets('保存新规则时全字段传递给数据层并返回上一页', (tester) async {
      when(() => mockApi.addReplaceRule(any())).thenAnswer(
        (inv) async =>
            (inv.positionalArguments[0] as ReplaceRule).copyWith(id: 1),
      );
      await pumpEdit(tester);

      // 按字段 label 定位输入（顶栏无 TextField，表单从名称起）
      await tester.enterText(byLabel('规则名称'), '去广告');
      await tester.enterText(byLabel('匹配规则'), '广告');
      await tester.enterText(byLabel('替换为'), '【广告】');
      await tester.enterText(byLabel('特定范围'), '某书');
      await tester.enterText(byLabel('排除范围'), '排除书');
      await tester.enterText(byLabel('预览输入'), 'AAAA广告');
      await tester.pumpAndSettle();

      // 「保存」按 FilledButton 语义节点点击（槽位包裹后 Text 零宽，
      // find.text('保存') 会触发 would-not-hit-test 告警）
      await tester.tap(find.byWidgetPredicate((w) => w is FilledButton));
      await tester.pumpAndSettle();

      final captured =
          verify(() => mockApi.addReplaceRule(captureAny())).captured.single
              as ReplaceRule;
      expect(captured.name, '去广告');
      expect(captured.pattern, '广告');
      expect(captured.isRegex, isTrue); // 默认勾选
      expect(captured.replacement, '【广告】');
      expect(captured.scope, '某书');
      expect(captured.excludeScope, '排除书');
      expect(captured.scopeTitle, isFalse);
      expect(captured.scopeContent, isTrue);
      expect(captured.timeoutMillisecond, 3000); // 新建默认值
      // 保存成功后返回上一页（整页已 pop）
      expect(find.text('保存'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
    });

    // [A3 写链路补齐 | 2026-09-11] 分组/标题·正文范围/排除范围/超时
    // 保存落库后经 notifier（load → getReplaceRules）读回与输入一致
    testWidgets('保存后全字段经 notifier 读回与输入一致（写链路落库）',
        (tester) async {
      // 内存「数据库」：add 存对象、get 回读，模拟 Rust 侧 add 全字段
      // 持久化 + get 回读链路
      final stored = <ReplaceRule>[];
      when(() => mockApi.addReplaceRule(any())).thenAnswer((inv) async {
        final r = (inv.positionalArguments[0] as ReplaceRule).copyWith(id: 9);
        stored.add(r);
        return r;
      });
      when(() => mockApi.getReplaceRules())
          .thenAnswer((_) async => List.of(stored));

      await pumpEdit(tester);

      // 匹配规则为必填（对标原版 checkValid：pattern 为空拦截保存），
      // 先填合法值，保存才会真正走 add 写链路
      await tester.enterText(byLabel('匹配规则'), '广告');
      // 分组：下拉选「自定义…」并输入组名
      await tester.tap(find.text('（无分组）'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义…'));
      await tester.pumpAndSettle();
      await tester.enterText(byLabel('输入分组名'), '净化组_9');
      // 作用范围：勾选「标题」（树序 Checkbox：0 正则 / 1 标题 / 2 书源(禁用) / 3 正文）
      await tester.tap(find.byType(Checkbox).at(1));
      // 排除范围 / 超时：直接输入
      await tester.enterText(byLabel('排除范围'), '排除书_9');
      await tester.enterText(byLabel('超时时间（毫秒）'), '4321');
      await tester.pumpAndSettle();

      // 顶栏「保存」是文字 FilledButton：经 TopBarActionStyler 36dp 槽位
      // 包裹后，内部 Text 被挤压为零宽（hit-test 中心落在按钮 padding 上，
      // find.text('保存') 会触发 would-not-hit-test 告警）。按按钮语义节点
      // 定位点击，稳定命中且无告警
      await tester.tap(find.byWidgetPredicate((w) => w is FilledButton));
      await tester.pumpAndSettle();

      // 经 notifier 读回：宿主页取同一 ProviderScope 容器，load() 走
      // getReplaceRules 重读数据层（等价于落库后重新读库）
      final container = ProviderScope.containerOf(
        tester.element(find.byKey(const Key('openBtn'))),
      );
      await container.read(replaceRuleNotifierProvider.notifier).load();
      final saved = container
          .read(replaceRuleNotifierProvider)
          .rules
          .singleWhere((r) => r.id == 9);
      expect(saved.group, '净化组_9');
      expect(saved.scopeTitle, isTrue);
      expect(saved.scopeContent, isTrue);
      expect(saved.excludeScope, '排除书_9');
      expect(saved.timeoutMillisecond, 4321);
    });

    testWidgets('正则模式下非法正则拦截保存', (tester) async {
      await pumpEdit(tester);

      await tester.enterText(byLabel('匹配规则'), '(');
      await tester.pumpAndSettle();

      // 「保存」按 FilledButton 语义节点点击（槽位包裹后 Text 零宽，
      // find.text('保存') 会触发 would-not-hit-test 告警）
      await tester.tap(find.byWidgetPredicate((w) => w is FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('正则语法错误或不支持'), findsOneWidget);
      verifyNever(() => mockApi.addReplaceRule(any()));
      // 未保存成功，仍停留在编辑页
      expect(find.text('保存'), findsOneWidget);
    });

    testWidgets('匹配规则为空时拦截保存', (tester) async {
      await pumpEdit(tester);

      // 「保存」按 FilledButton 语义节点点击（槽位包裹后 Text 零宽，
      // find.text('保存') 会触发 would-not-hit-test 告警）
      await tester.tap(find.byWidgetPredicate((w) => w is FilledButton));
      await tester.pumpAndSettle();

      expect(find.text('匹配规则不能为空'), findsOneWidget);
      verifyNever(() => mockApi.addReplaceRule(any()));
    });

    testWidgets('编辑模式回填已有规则全字段', (tester) async {
      const rule = ReplaceRule(
        id: 1,
        name: '去广告',
        group: '净化',
        pattern: '广告',
        replacement: '',
        scope: '某书',
        scopeTitle: true,
        scopeContent: false,
        excludeScope: '排除书',
        isRegex: false,
        isEnabled: true,
        timeoutMillisecond: 5000,
      );
      when(() => mockApi.getReplaceRules()).thenAnswer((_) async => [rule]);
      when(() => mockApi.updateReplaceRule(any())).thenAnswer((_) async {});
      await pumpEdit(tester, rule: rule);

      // 标题切换为编辑态
      expect(find.text('编辑替换规则'), findsOneWidget);
      // 文本字段回填
      final nameField = tester.widget<TextField>(byLabel('规则名称'));
      expect(nameField.controller?.text, '去广告');
      final patternField = tester.widget<TextField>(byLabel('匹配规则'));
      expect(patternField.controller?.text, '广告');
      final scopeField = tester.widget<TextField>(byLabel('特定范围'));
      expect(scopeField.controller?.text, '某书');
      final excludeField =
          tester.widget<TextField>(byLabel('排除范围'));
      expect(excludeField.controller?.text, '排除书');
      final timeoutField =
          tester.widget<TextField>(byLabel('超时时间（毫秒）'));
      expect(timeoutField.controller?.text, '5000');
      // 分组回填（「净化」为现有规则分组，命中下拉项）
      expect(find.text('净化'), findsWidgets);
      // 勾选状态回填（树序：使用正则表达式/标题/书源(禁用恒 false)/正文）
      final checks =
          tester.widgetList<Checkbox>(find.byType(Checkbox)).toList();
      expect(checks, hasLength(4));
      expect(checks[0].value, isFalse, reason: 'isRegex=false 未勾选');
      expect(checks[1].value, isTrue, reason: 'scopeTitle=true 勾选');
      expect(checks[3].value, isFalse, reason: 'scopeContent=false 未勾选');
      // 保存走 update 链路
      // 「保存」按 FilledButton 语义节点点击（槽位包裹后 Text 零宽，
      // find.text('保存') 会触发 would-not-hit-test 告警）
      await tester.tap(find.byWidgetPredicate((w) => w is FilledButton));
      await tester.pumpAndSettle();
      final captured =
          verify(() => mockApi.updateReplaceRule(captureAny())).captured.single
              as ReplaceRule;
      expect(captured.id, 1);
      expect(captured.name, '去广告');
      expect(captured.scopeTitle, isTrue);
      expect(captured.scopeContent, isFalse);
      // [A3 写链路补齐 2026-09-11] 回填值随表单解析落库（写接口已支持覆盖）
      expect(captured.timeoutMillisecond, 5000);
    });

    testWidgets('新建时 pattern 预填（阅读器选中文本入口）', (tester) async {
      await pumpEdit(tester, prefillPattern: '选中词');
      final patternField = tester.widget<TextField>(byLabel('匹配规则'));
      expect(patternField.controller?.text, '选中词');
    });

    testWidgets('复制规则：规则 JSON 写入剪贴板（含预览样本 previewText）',
        (tester) async {
      final written = mockClipboard(tester);
      when(() => mockApi.addReplaceRule(any()))
          .thenAnswer((inv) async => const ReplaceRule());
      await pumpEdit(tester);

      await tester.enterText(byLabel('规则名称'), '去广告');
      await tester.enterText(byLabel('匹配规则'), '广告');
      await tester.enterText(byLabel('预览输入'), 'AAAA广告');
      await tester.pumpAndSettle();

      await tapMenu(tester, '复制规则');

      expect(find.text('规则已复制到剪贴板'), findsOneWidget);
      expect(written, hasLength(1));
      final exported = jsonDecode(written.single) as Map<String, dynamic>;
      expect(exported['name'], '去广告');
      expect(exported['pattern'], '广告');
      expect(exported['previewText'], 'AAAA广告'); // 对标原版导出含预览样本
    });

    testWidgets('粘贴规则：剪贴板 JSON 填充表单', (tester) async {
      final ruleJson = const JsonEncoder().convert({
        'name': '粘贴规则',
        'pattern': 'pasted',
        'replacement': 'P',
        'isRegex': false,
        'scopeTitle': true,
        'scopeContent': true,
        'scope': 'scope书',
        'excludeScope': 'ex书',
        'previewText': 'prev',
      });
      mockClipboard(tester, clipboardText: ruleJson);
      await pumpEdit(tester);

      await tapMenu(tester, '粘贴规则');

      expect(find.text('已粘贴规则「粘贴规则」'), findsOneWidget);
      final nameField = tester.widget<TextField>(byLabel('规则名称'));
      expect(nameField.controller?.text, '粘贴规则');
      final patternField = tester.widget<TextField>(byLabel('匹配规则'));
      expect(patternField.controller?.text, 'pasted');
      final replacementField =
          tester.widget<TextField>(byLabel('替换为'));
      expect(replacementField.controller?.text, 'P');
      final scopeField = tester.widget<TextField>(byLabel('特定范围'));
      expect(scopeField.controller?.text, 'scope书');
      final excludeField = tester.widget<TextField>(byLabel('排除范围'));
      expect(excludeField.controller?.text, 'ex书');
      // previewText 回填预览输入框
      final previewField = tester.widget<TextField>(byLabel('预览输入'));
      expect(previewField.controller?.text, 'prev');
    });

    testWidgets('粘贴空剪贴板提示', (tester) async {
      mockClipboard(tester);
      await pumpEdit(tester);

      await tapMenu(tester, '粘贴规则');

      expect(find.text('剪贴板为空'), findsOneWidget);
    });

    testWidgets('粘贴非法内容提示格式错误', (tester) async {
      mockClipboard(tester, clipboardText: '不是 JSON');
      await pumpEdit(tester);

      await tapMenu(tester, '粘贴规则');

      expect(find.text('剪贴板内容不是有效的替换规则 JSON'), findsOneWidget);
    });

    testWidgets('预览：非正则模式字面替换（250ms 防抖后输出）',
        (tester) async {
      await pumpEdit(tester);

      // 取消「使用正则表达式」勾选（树序首个 Checkbox）→ 字面替换
      await tester.tap(find.byType(Checkbox).first);
      await tester.pump();

      await tester.enterText(byLabel('匹配规则'), '广告');
      await tester.enterText(byLabel('替换为'), '【广告】');
      await tester.enterText(byLabel('预览输入'), 'AAAA广告');
      // 推进防抖定时器（250ms）
      await tester.pump(const Duration(milliseconds: 300));

      final outputField = tester.widget<TextField>(byLabel('预览输出'));
      expect(outputField.controller?.text, 'AAAA【广告】');
    });

    testWidgets('预览：正则模式替换（含捕获组引用）', (tester) async {
      await pumpEdit(tester);

      // 捕获组引用：$1 展开为第 1 个捕获组（对标 Java Matcher.replaceAll
      // 的组语义；Dart replaceAll 为字面替换，由 _expandGroups 手动展开）
      await tester.enterText(byLabel('匹配规则'), r'(\d+)');
      await tester.enterText(byLabel('替换为'), r'[$1]');
      await tester.enterText(byLabel('预览输入'), 'abc123def456');
      await tester.pump(const Duration(milliseconds: 300));

      final outputField = tester.widget<TextField>(byLabel('预览输出'));
      expect(outputField.controller?.text, 'abc[123]def[456]');
    });
  });
}
