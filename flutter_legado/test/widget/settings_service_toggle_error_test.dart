/// 「我的」页服务开关失败态错误文案 widget 测试
///
/// [2026-10-06 iOS 实测修复] 用户实测：点击 MCP 服务开关 → SnackBar
/// 「MCP 服务切换失败: Instance of BridgeError」——`$e` 裸插值吞掉了 Rust 侧
/// 可读原因。本测锁定：
/// - MCP 开关失败 → SnackBar 显示 BridgeError.message 原文（不再是 Instance of）
/// - BridgeError 无 message → 兜底文案（不留空）
/// - Web 开关失败 → 同规则（该展示点同批修复，先例 S28「数据库未初始化」）
/// - MCP 卡片在未配置访问令牌时副题给出前置条件提示（Rust 启动守卫要求）
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart'
    hide Provider, ChangeNotifierProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_legado/src/bridge/ffi.dart';
import 'package:flutter_legado/src/providers/providers.dart';
import 'package:flutter_legado/src/screens/settings_screen.dart';
import 'package:flutter_legado/src/services/web_keep_alive_service.dart';
import 'package:flutter_legado/src/widgets/ios_widgets.dart';

import '../mocks/mocks.dart';

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
    WebKeepAliveService.instance.debugReset();
  });

  Widget wrap() {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SettingsScreen()),
    );
  }

  /// 按配置键返回（未列出的键返回 null，等价未配置）
  void stubConfigs({String? mcpPort, String? token}) {
    when(() => mockApi.getConfig(any())).thenAnswer((inv) async {
      final key = inv.positionalArguments.first as String;
      return switch (key) {
        'mcpPort' => mcpPort,
        'jsSourceApiToken' => token,
        _ => null,
      };
    });
  }

  Future<void> dragTo(WidgetTester tester, String text) {
    return tester.dragUntilVisible(
      find.text(text),
      find.byType(ListView),
      const Offset(0, -100),
    );
  }

  /// 直接触发 SwitchRow 的 onChanged（等价用户点开关；NestedScrollView 下
  /// tap 易被折叠头遮挡，沿用 settings_test.dart 既有做法）
  void toggleRow(WidgetTester tester, String title, bool value) {
    final row = find.widgetWithText(SettingSwitchRow, title);
    expect(row, findsOneWidget, reason: '应找到「$title」开关行');
    tester.widget<SettingSwitchRow>(row).onChanged!(value);
  }

  /// 让 SnackBar 自动关闭计时器走完，避免用例结束残留 pending timer
  Future<void> settleSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  group('MCP 服务开关失败态', () {
    testWidgets('SnackBar 显示 BridgeError.message 原文（非 Instance of）', (tester) async {
      stubConfigs();
      when(() => mockApi.setMcpPort(any())).thenAnswer(
        (_) async => throw const BridgeError(
          message: '独立 MCP 服务启动失败：请先在「设置 → 高级 → 其他设置」配置'
              '「Web 书源访问令牌」（config:jsSourceApiToken）',
        ),
      );

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'MCP 服务');
      await tester.pumpAndSettle();

      toggleRow(tester, 'MCP 服务', true);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('MCP 服务切换失败: 独立 MCP 服务启动失败'),
        findsOneWidget,
        reason: '应显示 Rust 侧可读原因（iOS 实测原为 Instance of BridgeError）',
      );
      // 卡片副题也含「Web 书源访问令牌」（前置条件提示），断言限定 SnackBar 内
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.textContaining('Web 书源访问令牌'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Instance of'), findsNothing);

      await settleSnackBar(tester);
    });

    testWidgets('BridgeError 无 message → 兜底文案（不留空）', (tester) async {
      stubConfigs();
      when(
        () => mockApi.setMcpPort(any()),
      ).thenAnswer((_) async => throw const BridgeError(message: ''));

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'MCP 服务');
      await tester.pumpAndSettle();

      toggleRow(tester, 'MCP 服务', true);
      await tester.pumpAndSettle();

      expect(find.text('MCP 服务切换失败: 未知错误'), findsOneWidget);
      expect(find.textContaining('Instance of'), findsNothing);

      await settleSnackBar(tester);
    });

    testWidgets('端口占用失败同样可读（Internal 文案不丢）', (tester) async {
      stubConfigs(mcpPort: '1236');
      when(() => mockApi.setMcpPort(any())).thenAnswer(
        (_) async => throw const BridgeError(
          message: '独立 MCP 服务端口 1236 绑定失败: Address already in use',
        ),
      );

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'MCP 服务');
      await tester.pumpAndSettle();

      toggleRow(tester, 'MCP 服务', true);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('独立 MCP 服务端口 1236 绑定失败'),
        findsOneWidget,
      );

      await settleSnackBar(tester);
    });
  });

  group('MCP 卡片前置条件提示', () {
    testWidgets('未配置访问令牌 → 副题提示需先配置（不必点开关撞错误）', (tester) async {
      stubConfigs();

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'MCP 服务');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('需先配置「Web 书源访问令牌」'),
        findsOneWidget,
      );
    });

    testWidgets('已配置访问令牌 → 保持原副题（不误报）', (tester) async {
      stubConfigs(token: 'test-mcp-token');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'MCP 服务');
      await tester.pumpAndSettle();

      expect(find.text('带令牌保护的书源开发工具'), findsOneWidget);
      expect(find.textContaining('需先配置'), findsNothing);
    });

    testWidgets('服务已开启 → 副题显示端口（提示不抢占运行态文案）', (tester) async {
      stubConfigs(mcpPort: '1236');

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'MCP 服务');
      await tester.pumpAndSettle();

      expect(find.text('端口 1236（带令牌保护的书源开发工具）'), findsOneWidget);
    });
  });

  group('Web 服务开关失败态', () {
    testWidgets('SnackBar 显示 BridgeError.message 原文（同批修复）', (tester) async {
      stubConfigs();
      when(
        () => mockApi.startServer(port: any(named: 'port')),
      ).thenAnswer(
        (_) async => throw const BridgeError(
          message: 'Web 服务启动失败：数据库未初始化，请先调用 db_open',
        ),
      );

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await dragTo(tester, 'Web 服务');
      await tester.pumpAndSettle();

      final card = find
          .ancestor(of: find.text('Web 服务'), matching: find.byType(Row))
          .first;
      final switchFinder = find.descendant(
        of: card,
        matching: find.byType(Switch),
      );
      tester.widget<Switch>(switchFinder).onChanged!(true);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Web 服务切换失败: Web 服务启动失败：数据库未初始化'),
        findsOneWidget,
      );
      expect(find.textContaining('Instance of'), findsNothing);

      await settleSnackBar(tester);
    });
  });
}
