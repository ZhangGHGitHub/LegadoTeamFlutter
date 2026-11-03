// [P2-E1 ｜ full-stack-engineer + UI ｜ 2026-11-03]
// 冷启动导入深链等待闪屏 widget 测试
//
// 根因：`DeepLinkService.handleUrl` 导入分支原实现直接调用
// `showAssociationImportDialog`，冷启动闪屏 `/welcome` 仍在栈顶时，
// `WelcomeScreen.pushReplacementNamed(home)` 会把确认框连同闪屏一起替换
// （干净进程冷启动投递 `legado://import/...` 或未知 host → 不弹框、落书架）。
// 修复：导入分支复用 [isSplashVisible] 逐帧等待（上限 90 帧）+ Navigator
// 装配重试 + 去重标志在确认框真正展示时设置、关闭后清理。
//
// 覆盖：
// 1. 冷启动闪屏未退出 → 不弹；闪屏退出后弹且仅弹一次；
// 2. 未知 host 冷启动同样等待后按导入语义弹框；
// 3. 热路径（闪屏已退出）→ 立即弹；
// 4. Navigator 未装配 → 逐帧重试，装配后弹；
// 5. 等待有界：超过 90 帧不再无限重试（nav 恒 null 时放弃；闪屏恒在时强制展示）；
// 6. 去重：弹窗存续期同一 URL 不重复弹，关闭后可再次打开；
// 7. `legado://dict` 不被导入等待器拦截（路由深链语义不变）。
import 'package:flutter/material.dart';
import 'package:flutter_legado/src/providers/association/association_notifier.dart';
import 'package:flutter_legado/src/routes.dart';
import 'package:flutter_legado/src/screens/association_import_dialog.dart';
import 'package:flutter_legado/src/services/deep_link_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide Provider;
import 'package:flutter_test/flutter_test.dart';

/// 记录关联导入 bootstrap（确认框是否真正打开及其入参）
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

/// 记录命名路由 push（断言字典路由落点与去重）
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

  const importUrl =
      'legado://import/bookSource?src=https://example.com/sources.json';
  const unknownHostUrl = 'legado://mystery?src=https://example.com/x.json';

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

  tearDown(() {
    DeepLinkService.instance
      ..navigatorKey = null
      ..isSplashVisible = null
      ..debugResetDedup();
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
          },
          home: const Scaffold(body: Text('首页')),
        ),
      ),
    );
    await tester.pump();
  }

  /// 关闭关联导入确认框（取消），并等待去重标志清理
  Future<void> dismissDialog(WidgetTester tester) async {
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  }

  group('P2-E1 冷启动导入深链等待闪屏', () {
    testWidgets('闪屏未退出不弹框，退出后弹一次且入参正确', (tester) async {
      var splashVisible = true;
      DeepLinkService.instance.isSplashVisible = () => splashVisible;
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(importUrl);
      await tester.pump();
      await tester.pump();

      expect(
        find.byType(AssociationImportDialog),
        findsNothing,
        reason: '闪屏仍在栈顶时弹框会被 pushReplacementNamed(home) 替换',
      );
      expect(notifier.bootstrapCalls, 0);

      splashVisible = false;
      await tester.pumpAndSettle();

      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1, reason: '只弹一次，不叠框');
      expect(notifier.bootstrappedType, ImportType.bookSource);
      expect(notifier.bootstrappedUrl, 'https://example.com/sources.json');

      await dismissDialog(tester);
      expect(find.byType(AssociationImportDialog), findsNothing);
    });

    testWidgets('未知 host 冷启动同样等待闪屏后按导入语义弹框', (tester) async {
      var splashVisible = true;
      DeepLinkService.instance.isSplashVisible = () => splashVisible;
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(unknownHostUrl);
      await tester.pump();
      await tester.pump();
      expect(find.byType(AssociationImportDialog), findsNothing);

      splashVisible = false;
      await tester.pumpAndSettle();

      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrappedType, isNull, reason: '未知类型交用户自选');
      expect(notifier.bootstrappedUrl, 'https://example.com/x.json');

      await dismissDialog(tester);
    });

    testWidgets('热路径（闪屏已退出）立即弹框', (tester) async {
      var splashVisible = false;
      DeepLinkService.instance.isSplashVisible = () => splashVisible;
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(importUrl);
      await tester.pumpAndSettle();

      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1);

      await dismissDialog(tester);
    });

    testWidgets('Navigator 未装配时逐帧重试，装配后弹框', (tester) async {
      await DeepLinkService.instance.handleUrl(importUrl);

      // 尚未 pumpWidget：navigatorKey.currentState 为 null，逐帧重试
      await tester.pump();
      await tester.pump();
      expect(notifier.bootstrapCalls, 0);

      await pumpApp(tester);
      await tester.pumpAndSettle();

      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1);

      await dismissDialog(tester);
    });

    testWidgets('等待有界：Navigator 恒未装配时超限放弃，不无限重试', (tester) async {
      await DeepLinkService.instance.handleUrl(importUrl);

      // 90 帧上限：逐帧推进到超限后等待链终止
      for (var i = 0; i < 95; i++) {
        await tester.pump();
      }
      expect(notifier.bootstrapCalls, 0);

      // 超限后即使 Navigator 装配也不再补弹（等待链已放弃）
      await pumpApp(tester);
      await tester.pumpAndSettle();
      expect(find.byType(AssociationImportDialog), findsNothing);
      expect(notifier.bootstrapCalls, 0);

      // 新一轮投递（用户/系统再次拉起）仍可正常打开
      await DeepLinkService.instance.handleUrl(importUrl);
      await tester.pumpAndSettle();
      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1);

      await dismissDialog(tester);
    });

    testWidgets('等待有界：闪屏恒在时超限仍强制展示（不静默丢弃），并记录日志', (tester) async {
      DeepLinkService.instance.isSplashVisible = () => true;
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(importUrl);
      // 上限内（85 帧）不展示
      for (var i = 0; i < 85; i++) {
        await tester.pump();
      }
      expect(find.byType(AssociationImportDialog), findsNothing);

      // 越过 90 帧上限：强制展示
      for (var i = 0; i < 10; i++) {
        await tester.pump();
      }
      await tester.pumpAndSettle();

      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1);

      await dismissDialog(tester);
    });

    testWidgets('去重：弹窗存续期同 URL 不重复，关闭后可再开', (tester) async {
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl(importUrl);
      await tester.pumpAndSettle();
      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1);

      // 弹窗存续期重复投递：不叠第二个框
      await DeepLinkService.instance.handleUrl(importUrl);
      await tester.pumpAndSettle();
      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 1);

      // 关闭后去重标志清理，可再次打开
      await dismissDialog(tester);
      await DeepLinkService.instance.handleUrl(importUrl);
      await tester.pumpAndSettle();
      expect(find.byType(AssociationImportDialog), findsOneWidget);
      expect(notifier.bootstrapCalls, 2);

      await dismissDialog(tester);
    });

    testWidgets('legado://dict 不被导入等待器拦截（路由语义不变）', (tester) async {
      var splashVisible = true;
      DeepLinkService.instance.isSplashVisible = () => splashVisible;
      await pumpApp(tester);

      await DeepLinkService.instance.handleUrl('legado://dict');
      await tester.pump();
      await tester.pump();
      expect(find.byType(AssociationImportDialog), findsNothing);
      expect(notifier.bootstrapCalls, 0);

      splashVisible = false;
      await tester.pumpAndSettle();

      expect(find.text('字典查询页'), findsOneWidget);
      expect(
        recorder.pushed.where((name) => name == AppRoutes.dict).length,
        1,
      );
      expect(find.byType(AssociationImportDialog), findsNothing);
      expect(notifier.bootstrapCalls, 0, reason: '路由深链不做导入拉取');
    });
  });
}
