import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/routes.dart' show AppRoutes;
import 'package:flutter_legado/src/screens/dict_rule_screen.dart';

import '../mocks/mocks.dart';

/// 字典规则管理页 widget 测试
///
/// [C2 批2 | full-stack-engineer + UI] 覆盖：列表渲染 / 开关切换 /
/// 空态 / 错误重试 / FAB 新增（名称必填校验）/ 长按多选批量禁用与
/// 批量删除（确认框）/ 菜单导入默认。
void main() {
  late MockRustApi mockApi;
  late ProviderContainer container;

  setUpAll(registerFallbacks);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApi = MockRustApi();
    container = ProviderContainer(
      overrides: [bookApiProvider.overrideWithValue(mockApi)],
    );
    addTearDown(container.dispose);
  });

  Widget wrap(Widget child) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: child),
    );
  }

  /// 三条样例规则（id/name/urlRule/showRule/enabled/sortNumber）
  List<Map<String, dynamic>> sampleRows() => [
        {
          'id': 1,
          'name': '海词中文',
          'urlRule': 'https://www.haiyachax.com/search/{{key}}',
          'showRule': 'css:.result p',
          'enabled': true,
          'sortNumber': 0,
        },
        {
          'id': 2,
          'name': '百度汉语',
          'urlRule': 'https://hanyu.baidu.com/s?word={{key}}',
          'showRule': '',
          'enabled': false,
          'sortNumber': 1,
        },
        {
          'id': 3,
          'name': '有道词典',
          'urlRule': 'https://fanyi.youdao.com/result?word={{key}}&q={{key}}',
          'showRule': 'css:#phons',
          'enabled': true,
          'sortNumber': 2,
        },
      ];

  group('DictRuleScreen', () {
    testWidgets('加载并显示规则列表（名称 + urlRule 副行 + 开关）',
        (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      expect(find.text('字典规则管理'), findsOneWidget);
      expect(find.text('海词中文'), findsOneWidget);
      expect(find.text('百度汉语'), findsOneWidget);
      expect(find.text('有道词典'), findsOneWidget);
      // urlRule 副行（单行截断）
      expect(
        find.text('https://www.haiyachax.com/search/{{key}}'),
        findsOneWidget,
      );
      // 每行一个 Switch（3 行 3 个）
      expect(find.byType(Switch), findsNWidgets(3));
      // 拖拽把手（ReorderableDragStartListener 内图标）
      expect(find.byIcon(Symbols.drag_indicator_rounded), findsNWidgets(3));
      // FAB 新增
      expect(find.text('新增规则'), findsOneWidget);
    });

    testWidgets('切换开关调用 dictRuleSetEnabled 并乐观更新', (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());
      when(() => mockApi.dictRuleSetEnabled(id: 2, enabled: true))
          .thenAnswer((_) async => true);

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      // 百度汉语初始禁用（enabled=false）→ 找到第 2 个 Switch 打开
      final switches = find.byType(Switch);
      expect(switches.evaluate().length, 3);
      await tester.tap(switches.at(1));
      await tester.pumpAndSettle();

      verify(() => mockApi.dictRuleSetEnabled(id: 2, enabled: true))
          .called(1);
      // 乐观更新后开关呈开启态
      final sw = tester.widget<Switch>(switches.at(1));
      expect(sw.value, true);
    });

    testWidgets('空列表显示空态', (tester) async {
      when(() => mockApi.dictRuleList()).thenAnswer((_) async => []);

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      expect(find.text('暂无字典规则'), findsOneWidget);
      expect(find.text('点击右下角按钮添加，或从右上角菜单导入'), findsOneWidget);
    });

    testWidgets('加载失败显示错误与重试', (tester) async {
      when(() => mockApi.dictRuleList())
          .thenThrow(Exception('ffi dictRuleList'));

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      // _errMsg 对非 BridgeError 走 toString（Exception 带 "Exception: " 前缀）
      expect(find.text('Exception: ffi dictRuleList'), findsOneWidget);
      expect(find.byIcon(Symbols.refresh_rounded), findsWidgets);
    });

    testWidgets('FAB 新增：名称为空时校验拦截，填写后调用 dictRuleAdd',
        (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());
      when(() => mockApi.dictRuleAdd(
            name: '新词典',
            urlRule: 'https://example.com/dict?q={{key}}',
            showRule: '',
          ))
          .thenAnswer((_) async => 4);

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      // 打开新增弹层
      await tester.tap(find.text('新增规则'));
      await tester.pumpAndSettle();
      expect(find.text('添加字典规则'), findsOneWidget);

      // 名称为空直接保存 → 校验拦截（errorText 展示，不调用 add）
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('规则名称不能为空'), findsOneWidget);
      verifyNever(() => mockApi.dictRuleAdd(
          name: any(named: 'name'),
          urlRule: any(named: 'urlRule'),
          showRule: any(named: 'showRule')));

      // 填写名称后保存（url 字段已预填默认查询地址）
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.labelText ?? '') == '规则名称',
        ),
        '新词典',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      verify(() => mockApi.dictRuleAdd(
            name: '新词典',
            urlRule: 'https://example.com/dict?q={{key}}',
            showRule: '',
          ))
          .called(1);
      // 保存后重载并提示
      expect(find.text('已添加规则「新词典」'), findsOneWidget);
    });

    testWidgets('长按进入多选：批量禁用调用 dictRuleSetEnabled(false)',
        (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());
      when(() => mockApi.dictRuleSetEnabled(id: 1, enabled: false))
          .thenAnswer((_) async => true);

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      // 长按第一行进入多选
      await tester.longPress(find.text('海词中文'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);

      // 顶栏「禁用选中」
      await tester.tap(find.byTooltip('禁用选中'));
      await tester.pumpAndSettle();

      verify(() => mockApi.dictRuleSetEnabled(id: 1, enabled: false))
          .called(1);
      expect(find.text('已禁用 1 条规则'), findsOneWidget);
      // 退出多选模式
      expect(find.text('已选 1 项'), findsNothing);
    });

    testWidgets('长按多选：批量删除需确认并调用 dictRuleDelete',
        (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());
      when(() => mockApi.dictRuleDelete(2)).thenAnswer((_) async => true);

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      // 长按第二行（百度汉语）进入多选
      await tester.longPress(find.text('百度汉语'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1 项'), findsOneWidget);

      // 顶栏「删除选中」
      await tester.tap(find.byTooltip('删除选中'));
      await tester.pumpAndSettle();
      // 确认框出现
      expect(find.text('删除规则'), findsOneWidget);

      // 先取消 → 不删除
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      verifyNever(() => mockApi.dictRuleDelete(2));
      expect(find.text('百度汉语'), findsOneWidget);

      // 再次触发并确认
      await tester.tap(find.byTooltip('删除选中'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      verify(() => mockApi.dictRuleDelete(2)).called(1);
      expect(find.text('已删除 1 条规则'), findsOneWidget);
      expect(find.text('百度汉语'), findsNothing);
    });

    testWidgets('菜单「导入默认」调用 dictRuleImport(kind: text)',
        (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());
      when(() => mockApi.dictRuleImport(
            jsonOrUrl: any(named: 'jsonOrUrl'),
            kind: 'text',
          ))
          .thenAnswer((_) async => 5);

      await tester.pumpWidget(wrap(const DictRuleScreen()));
      await tester.pumpAndSettle();

      // 打开右上角菜单
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('导入默认'), findsOneWidget);

      await tester.tap(find.text('导入默认'));
      await tester.pumpAndSettle();

      final captured = verify(
        () => mockApi.dictRuleImport(
          jsonOrUrl: captureAny(named: 'jsonOrUrl'),
          kind: 'text',
        ),
      ).captured;
      expect(captured.single, isA<String>());
      expect(captured.single as String, contains('海词中文'));
      expect(find.text('已导入 5 条默认字典规则'), findsOneWidget);
    });

    testWidgets('菜单「扫码导入」：桩路由返回内容时按 kind=text 调用 dictRuleImport',
        (tester) async {
      const qrPayload =
          '[{"name":"扫码词典","urlRule":"https://qr.example.com/dict?q={{key}}","showRule":""}]';
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());
      when(() => mockApi.dictRuleImport(
            jsonOrUrl: qrPayload,
            kind: 'text',
          ))
          .thenAnswer((_) async => 1);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: const DictRuleScreen(),
            // 桩路由：替代真实 QrcodeScreen，首帧后 pop 固定扫码内容
            routes: {
              AppRoutes.qrcode: (_) =>
                  const _StubQrcodePage(result: qrPayload),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 打开右上角菜单，确认「扫码导入」在位
      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('扫码导入'), findsOneWidget);

      // 触发扫码导入：桩路由 pop 固定内容 → 按 kind='text' 导入
      await tester.tap(find.text('扫码导入'));
      await tester.pumpAndSettle();

      verify(() => mockApi.dictRuleImport(
            jsonOrUrl: qrPayload,
            kind: 'text',
          ))
          .called(1);
      expect(find.text('已导入 1 条字典规则'), findsOneWidget);
    });

    testWidgets('菜单「扫码导入」：取消（pop null）不调用导入且提示',
        (tester) async {
      when(() => mockApi.dictRuleList())
          .thenAnswer((_) async => sampleRows());

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: const DictRuleScreen(),
            // 桩路由：模拟扫码页取消（pop 无值 → null）
            routes: {
              AppRoutes.qrcode: (_) => const _StubQrcodePage(),
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('扫码导入'));
      await tester.pumpAndSettle();

      verifyNever(() => mockApi.dictRuleImport(
            jsonOrUrl: any(named: 'jsonOrUrl'),
            kind: any(named: 'kind'),
          ));
      expect(find.text('未获取到扫码内容'), findsOneWidget);
    });
  });
}

/// 桩扫码页：首帧后自动 pop [result]（result 为 null 时模拟取消）
class _StubQrcodePage extends StatefulWidget {
  const _StubQrcodePage({this.result});

  final String? result;

  @override
  State<_StubQrcodePage> createState() => _StubQrcodePageState();
}

class _StubQrcodePageState extends State<_StubQrcodePage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(widget.result);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
