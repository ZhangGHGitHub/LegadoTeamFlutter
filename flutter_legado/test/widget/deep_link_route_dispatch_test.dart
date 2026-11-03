// [M3 我的页 | full-stack-engineer + UI | 2026-11-03]
// 外部深链路由分流 widget 测试
//
// 覆盖（docs/MY_PAGE_ALIGNMENT_PLAN_20261103.md 批 M3）：
// 1. `legado://dict` / `legado://dict_rule` 在导入分流前识别为应用内路由；
// 2. `yuedu://`、带/不带三斜杠、带 query 的变体同目标；
// 3. `legado://import/...` 既有导入语义不变（仍弹关联导入确认框）；
// 4. 未知 host 仍按导入语义处理；
// 5. 冷启动（getInitialLink + 闪屏等待）与热路径（onLink 通道）均生效；
// 6. 去重：同一 URI 在页面存续期内只 push 一次，pop 后可再次打开。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/association_import_dialog.dart';
import 'package:flutter_legado/src/services/deep_link_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

/// 记录关联导入 bootstrap（导入语义不变的证据）
class _RecordingAssociationNotifier extends AssociationNotifier {
  ImportType? bootstrappedType;
  String? bootstrappedUrl;
  int bootstrapCalls = 0;

  @override
  AssociationState build() => const AssociationState();

  @override
  Future<void> bootstrapFromDeepLink({
    ImportType? type,
    required String srcUrl,
  }) async {
    bootstrapCalls++;
    bootstrappedType = type;
    bootstrappedUrl = srcUrl;
    state = AssociationState(
      type: type ?? ImportType.bookSource,
      items: const [
        AssociationItem(
          raw: {'name': '测试条目', 'bookSourceUrl': 'https://a'},
          name: '测试条目',
          status: ImportItemStatus.isNew,
        ),
      ],
    );
  }
}

/// 记录命名路由 push（断言深链落点与去重）
class _RouteRecorder extends NavigatorObserver {
  final List<String?> pushed = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
    super.didPush(route, previousRoute);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('legado/deep_link');
  const codec = StandardMethodCodec();

  late _RecordingAssociationNotifier notifier;
  late _RouteRecorder recorder;
  late GlobalKey<NavigatorState> navKey;

  setUp(() {
    notifier = _RecordingAssociationNotifier();
    recorder = _RouteRecorder();
    navKey = GlobalKey<NavigatorState>();
    DeepLinkService.instance
      ..navigatorKey = navKey
      ..isSplashVisible = null
      ..debugResetDedup();
  });

  tearDown(() async {
    DeepLinkService.instance
      ..navigatorKey = null
      ..isSplashVisible = null
      ..debugResetDedup();
    await DeepLinkService.instance.detach();
    // attach 注册的入站 handler 为进程级：显式清空，避免跨用例串扰
    channel.setMethodCallHandler(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [associationNotifierProvider.overrideWith(() => notifier)],
        child: MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [recorder],
          routes: {
            AppRoutes.dict: (_) => const Scaffold(body: Text('字典查询页')),
            AppRoutes.dictRule: (_) => const Scaffold(body: Text('字典规则页')),
          },
          home: const Scaffold(body: Text('首页')),
        ),
      ),
    );
    await tester.pump();
  }

  int pushCount(String? name) => recorder.pushed.where((n) => n == name).length;

  group('外部深链路由分流', () {
    testWidgets('legado://dict → 字典查询页，不弹关联导入框', (tester) async {
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl('legado://dict');
      await tester.pumpAndSettle();

      expect(pushCount(AppRoutes.dict), 1);
      expect(find.text('字典查询页'), findsOneWidget);
      expect(
        find.byType(AssociationImportDialog),
        findsNothing,
        reason: '路由深链不弹导入框',
      );
      expect(notifier.bootstrapCalls, 0, reason: '不做任何导入拉取');
    });

    testWidgets('legado://dict_rule → 字典规则管理页', (tester) async {
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl('legado://dict_rule');
      await tester.pumpAndSettle();

      expect(pushCount(AppRoutes.dictRule), 1);
      expect(find.text('字典规则页'), findsOneWidget);
      expect(notifier.bootstrapCalls, 0);
    });

    testWidgets('yuedu:// / 三斜杠 / query / 末尾斜杠变体均识别', (tester) async {
      await pumpApp(tester);

      const variants = [
        'yuedu://dict_rule',
        'legado:///dict_rule',
        'legado://dict_rule?src=https://example.com/x.json',
        'legado://dict_rule/',
      ];
      var expected = 0;
      for (final url in variants) {
        await DeepLinkService.instance.handleUrl(url);
        await tester.pumpAndSettle();
        expected++;
        expect(
          pushCount(AppRoutes.dictRule),
          expected,
          reason: '变体「$url」应导航到字典规则页',
        );
        expect(find.text('字典规则页'), findsOneWidget);
        navKey.currentState!.pop();
        await tester.pumpAndSettle();
      }
      expect(notifier.bootstrapCalls, 0);
    });

    testWidgets('legado://import/... 导入语义不变（仍弹关联导入）', (tester) async {
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(
        'legado://import/bookSource?src=https://example.com/sources.json',
      );
      await tester.pumpAndSettle();

      expect(notifier.bootstrapCalls, 1);
      expect(notifier.bootstrappedType, ImportType.bookSource);
      expect(notifier.bootstrappedUrl, 'https://example.com/sources.json');
      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(pushCount(AppRoutes.dict), 0);
      expect(pushCount(AppRoutes.dictRule), 0);
    });

    testWidgets('未知 host 仍按导入语义处理', (tester) async {
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(
        'legado://mystery?src=https://example.com/x.json',
      );
      await tester.pumpAndSettle();

      expect(notifier.bootstrapCalls, 1);
      expect(notifier.bootstrappedType, isNull, reason: '未知类型交用户自选');
      expect(notifier.bootstrappedUrl, 'https://example.com/x.json');
      expect(pushCount(AppRoutes.dict), 0);
      expect(pushCount(AppRoutes.dictRule), 0);
    });

    testWidgets('去重：页面存续期内同一 URI 只 push 一次，pop 后可再次打开', (tester) async {
      await pumpApp(tester);
      const url = 'legado://dict';

      await DeepLinkService.instance.handleUrl(url);
      await tester.pumpAndSettle();
      await DeepLinkService.instance.handleUrl(url);
      await tester.pumpAndSettle();

      expect(pushCount(AppRoutes.dict), 1, reason: '重复投递不叠栈');
      expect(find.text('字典查询页'), findsOneWidget);

      navKey.currentState!.pop();
      await tester.pumpAndSettle();
      await DeepLinkService.instance.handleUrl(url);
      await tester.pumpAndSettle();

      expect(pushCount(AppRoutes.dict), 2, reason: '页面 pop 后去重标记清空');
    });

    testWidgets('冷启动 getInitialLink：闪屏退出后才 push（避免被替换）', (tester) async {
      var splashVisible = true;
      DeepLinkService.instance.isSplashVisible = () => splashVisible;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getInitialLink') return 'legado://dict_rule';
        return null;
      });

      await pumpApp(tester);
      await DeepLinkService.instance.attach(navKey);

      // 闪屏存续期：逐帧等待，不 push（pushReplacementNamed(home) 会替换栈顶）
      await tester.pump();
      await tester.pump();
      expect(pushCount(AppRoutes.dictRule), 0,
          reason: '闪屏仍在栈顶时不得 push');

      splashVisible = false;
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      expect(pushCount(AppRoutes.dictRule), 1);
      expect(find.text('字典规则页'), findsOneWidget);
    });

    testWidgets('热路径 onLink 通道：同一分流（Activity 存活时）', (tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      await pumpApp(tester);
      // 注册 legado/deep_link 入站 handler（getInitialLink 等返回 null）
      await DeepLinkService.instance.attach(navKey);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('onLink', 'legado://dict')),
        (_) {},
      );
      await tester.pumpAndSettle();

      expect(pushCount(AppRoutes.dict), 1);
      expect(find.text('字典查询页'), findsOneWidget);
      expect(notifier.bootstrapCalls, 0);
    });
  });
}
